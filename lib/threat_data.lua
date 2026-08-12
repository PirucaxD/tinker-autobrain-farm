---@meta
---lib/threat_data.lua - universal threat / save classification data.
---
---Data-only Tier 2 extraction. The tables and pure helpers in this module
---don't change per hero - Pike's push distance is 425u for everyone, Bane
---Nightmare is countered by invuln/magic_immune/dispel/reflect regardless
---of who's defending against it.
---
---**Scope intentionally narrow.** This module owns:
---  - Save-item kind classification         (SAVE_KIND)
---  - Threat counter-effectiveness map      (THREAT_COUNTER)
---  - Displacement push distances           (SAVE_PUSH_DISTANCE)
---  - Tether-channel ranges                 (THREAT_TETHER_RANGE)
---  - Threat-on-self whitelist + roles      (THREATS_ON_SELF)
---  - Lotus-reflect-worthy incoming ults    (LOTUS_WORTHY_INCOMING)
---  - Enemy channel modifiers for Layer 1.5 (ENEMY_CHANNEL_MODIFIERS)
---  - Ability-name → threat-modifier map    (ABILITY_TO_THREAT)
---  - SaveCounters() predicate              (pure set intersection)
---  - WillTetherBreak() predicate           (pure geometry)
---
---**Does NOT own (stays per-hero):**
---  - Save chain execution order
---  - Hero-specific save abilities (Sniper's grenade-self, etc.)
---  - try_save_self, armed_threats_tick - these are logic that we'll
---    extract to `lib/defense.lua` once a second hero proves the API shape
---    (project's "two-hero rule").
---
---Usage in a hero script:
---```lua
---local TD = require("lib.threat_data")
---if TD.SaveCounters("item_cyclone", "modifier_bane_nightmare") then
---    -- Eul counters Nightmare; fire it
---end
---if TD.WillTetherBreak("item_hurricane_pike",
---                      "modifier_bane_fiends_grip",
---                      dist_bane_to_self) then
---    -- Pike's 425u push will break the 875u tether from this distance
---end
---```

local ThreatData = {}

-- v6.15.208 (KV-derivation): item_data.lua's generated SAVE_GEOMETRY table is
-- the single source of truth for save-item push/blink distances. sg() pulls a
-- numeric field from it with a patch-stable literal fallback. item_data is a
-- pure data module (no API calls / callbacks) and requires nothing back, so
-- there is no cycle and no load-order risk.
local ItemData = require("lib.item_data")
local function sg(name, field, fallback)
    local g = ItemData.SAVE_GEOMETRY and ItemData.SAVE_GEOMETRY[name]
    local v = g and g[field]
    return (type(v) == "number" and v) or fallback
end

-- v0.5.74: lib/target needed by ThreatData.ComputeArrivalTime (lifted from
-- Lina.lua state.compute_arrival_time, which had Target as an upvalue from
-- the hero script). Same lesson v0.5.61 taught with lib/escape: lib modules
-- do NOT inherit hero-script upvalues; explicit require keeps the function
-- self-contained.
--
-- v0.5.75.1 hotfix: REQUIRE IS LAZY because lib/target.lua:271 has its own
-- eager `require("lib.threat_data")` (for ESCAPE_ITEM_NAMES). An eager
-- require here closes the cycle -> infinite recursion -> C stack overflow
-- on cold game load. v0.5.74 only "worked" because Lina.lua's hot-reload
-- cache-clear at the top only clears lib/defense + lib/escape, NOT
-- lib/target or lib/threat_data, so a hot Lina reload kept both cached
-- from a prior successful (pre-v0.5.74) load. Game restart killed the
-- hot cache and the cycle bit. Resolve Target on first ComputeArrivalTime
-- call instead; by then both modules are fully loaded and require returns
-- the cached Target table immediately.
local Target  -- resolved lazily inside ComputeArrivalTime; see v0.5.75.1 note above

----------------------------------------------------------------------------
-- SAVE_KIND - every save item / ability classified by what it does
----------------------------------------------------------------------------

---Save-effect categories. A save is "effective" against a threat iff any of
---its kinds appears in the threat's counter list.
---
---Kind meanings:
---  invuln                   - caster goes invuln (Eul cyclone, Aeon trigger,
---                             Wind Waker cyclone)
---  dispel_basic             - applies basic dispel (Eul exit, Manta split,
---                             Satanic active, Diffusal purge)
---  dispel_strong            - applies strong dispel; supersets basic dispel
---                             (Aeon trigger, Disperser purge, Wind Waker).
---                             DeriveCounters emits dispel_strong for every
---                             dispellable threat, so a strong-dispel item
---                             counters both basic- and strong-only debuffs.
---  magic_immune             - magic immunity (BKB)
---  magic_barrier            - absorbs magic damage via barrier (Eternal
---                             Shroud, Pipe of Insight)
---  magic_resist             - passive flat magic resist buff (Glimmer)
---  reflect_target           - Lotus Orb reflects single-target enemy casts
---  invis                    - invisibility breaks attack target-lock
---                             (Glimmer, Silver Edge wind-walk, Solar Crest)
---  damage_block             - flat physical damage reduction (Crimson
---                             Guard active barrier)
---  damage_return            - reflects physical damage back (Blade Mail)
---  physical_immune          - immune to physical attacks (Ghost active)
---  displacement_perp        - perpendicular 400-500u (Pike, Force,
---                             Grenade-self) - works vs LINE projectiles +
---                             DELAYED-AOE
---  displacement_far         - 500u+ displacement (Pike, Force) - works vs
---                             TETHER channels that break at range
---  displacement_blink       - instant 1200u teleport (Blink Dagger and
---                             variants) - breaks any tether
---  displacement_at_source   - knocks the THREAT CASTER off their position
---                             (grenade-at-caster) - breaks Bara Charge,
---                             Tusk Snowball via forced movement
---  channel_break            - interrupts enemy channel via ROOT_DISABLES
---                             (grenade-at-caster, hex, stun on caster)
---  phase                    - phase movement, walks through units
---                             (Phase Boots active) - minor save
---@type table<string, string[]>
ThreatData.SAVE_KIND = {
    -- Self-protection items
    item_cyclone            = { "invuln", "dispel_basic" },     -- 2.5s cyclone
    item_wind_waker         = { "invuln", "dispel_basic" },     -- 2.5s cyclone, basic dispel on cast (Liquipedia 7.41), can act during cyclone
    -- v6.7: Aeon Disk applies STRONG dispel on trigger (Liquipedia 7.41).
    -- Strong dispel supersets basic dispel: mechanically it can remove
    -- Nightmare/Ensnare/etc even after they land. SaveCounters realizes this
    -- once threats are profiled (DeriveCounters emits dispel_strong for every
    -- dispellable threat; until the threat-profile migration lands, a threat's
    -- counter list may still carry only dispel_basic).
    item_aeon_disk          = { "invuln", "dispel_strong" },    -- auto-trigger 1.5s invuln + strong dispel at <=80% HP
    item_lotus_orb          = { "reflect_target" },
    item_glimmer_cape       = { "invis", "magic_resist" },
    item_solar_crest        = { "invis", "magic_resist" },      -- self-cast: 6s invis + armor buff
    -- v6.7 (2026-05-11): BKB now applies basic dispel on cast (7.41 change
    -- per Liquipedia). Useful against Naga Ensnare and other dispel-only
    -- counterable threats.
    item_black_king_bar     = { "magic_immune", "dispel_basic" },
    -- v6.7: item_eternal_shroud was REMOVED in 7.41 - entry deleted.
    item_pipe    = { "magic_barrier" },              -- AoE magic barrier on team
    item_crimson_guard      = { "damage_block" },               -- AoE flat damage block + team barrier
    item_blade_mail         = { "damage_return" },
    item_ghost              = { "physical_immune" },            -- 4s ghost form: immune physical, takes 40% more magic
    -- Dispel-on-self items
    item_satanic            = { "dispel_basic" },
    item_manta              = { "dispel_basic" },
    item_disperser          = { "dispel_strong" },              -- self-cast strong dispel + slow split (Liquipedia 7.41)
    item_diffusal_blade     = { "dispel_basic" },               -- target enemy: purge + slow
    item_invis_sword        = { "invis" },                      -- Shadow Blade: wind-walk breaks attack target-lock
    item_silver_edge        = { "invis" },                      -- wind-walk + break (attack target-lock)
    -- Displacement items
    item_hurricane_pike     = { "displacement_far", "displacement_perp" },
    item_force_staff        = { "displacement_far", "displacement_perp" },
    item_blink              = { "displacement_blink" },
    item_swift_blink        = { "displacement_blink" },
    item_arcane_blink       = { "displacement_blink" },
    item_overwhelming_blink = { "displacement_blink" },
    item_phase_boots        = { "phase" },                      -- minor save: pass through units
    -- Sniper hero-specific (registered here so the kind-intersection filter
    -- works; hero file owns the fire closures via its SAVE_FIRE table).
    grenade_self            = { "displacement_perp" },          -- 475u radial from cast point
    grenade_at_caster       = { "channel_break", "displacement_at_source" },
}

----------------------------------------------------------------------------
-- THREAT_COUNTER - which kinds actually counter each threat
----------------------------------------------------------------------------

---Threat modifier → list of save-kind names that effectively counter it.
---Threats not listed are unconstrained (any save kind is allowed).
---@type table<string, string[]>
----------------------------------------------------------------------------
-- THREAT_PROFILE -- per-threat Liquipedia+KV facts (Lina/THREAT_COUNTER_AXIS_DESIGN.md).
-- THREAT_COUNTER is ASSEMBLED from these via DeriveCounters (below SaveCounters'
-- sibling, after the function is defined). Facts are KV-grounded (damage_type/
-- pierces/dispellable from lib/ability_data.lua) + Liquipedia-verified judgment
-- fields. Each `note` records the source/rationale + any KV-vs-Liquipedia conflict.
----------------------------------------------------------------------------
ThreatData.THREAT_PROFILE = {
    ["modifier_abyssal_underlord_pit_of_malice_ensare"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", blocks_forced_movement=true, lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="Placed recurring-root zone, primary_harm=disable (root dominant; token 20-50 magical dmg) -> no magic_barrier (rule problem #10). zone_outlasts_cyc..." },
    ["modifier_axe_berserkers_call"] = { school="physical", damage_type="none", pierces_spell_immunity=true, dispellable="none", delivery="attack", primary_harm="disable", timing="reactive", forced_leash=true, lotus_reflectable=false, severity="lethal",
        note="Taunt = forced-leash equivalent (you are locked attacking Axe and exposed to his team). KV routes it INFORMATIONAL because it pierces BKB and is un..." },
    ["modifier_bane_fiends_grip"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="strong", delivery="channel", primary_harm="disable", timing="mid_channel", severity="lethal", drop_kinds={"displacement_far", "displacement_perp", "displacement_blink"}, add_kinds={"invuln"},
        note="CONFLICT: KV dispellable=yes_strong but Liquipedia says 'Dispellable by any Dispel sources' (i.e. basic). Kept KV strong per authoritative-KV rule...." },
    ["modifier_bane_nightmare"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="CONFLICT: none. KV note flagged 'VERIFY enemy-side'; Liquipedia confirms Nightmare does NOT pierce spell immunity on enemies, so pierces='false' st..." },
    ["modifier_crystal_maiden_freezing_field"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="channel", positional=true, primary_harm="damage", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true,
        note="CONFLICT: KV crystal_maiden_freezing_field has no dispellable field (=none); Liquipedia notes the SLOW debuff is dispellable by any dispel. The bra..." },
    ["modifier_disruptor_kinetic_field"] = { school="none", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", blocks_forced_movement=true, lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: KV damage_type=none and the ability is terrain-like; set school=none (not magical) because Liquipedia confirms Kinetic Field functions as..." },
    ["modifier_disruptor_static_storm_thinker"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="lethal",
        note="Placed AoE silence+damage dome (point cast, targeted=false, positional). 350 DPS over 6s -> severity=lethal so magic_resist excluded; magic_barrier..." },
    ["modifier_doom_bringer_doom"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="none", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="lethal",
        note="CONFLICT: none. KV (dt=pure, pierces=true=enemies_yes, disp=none) matches Liquipedia exactly. This is the rule-review's confirmed example (drop mag..." },
    ["modifier_earth_spirit_rolling_boulder"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="line_charge", primary_harm="disable", timing="at_impact", lotus_reflectable=false,
        note="KV: magical / enemies_no (no pierce) / yes_strong. This is the de-hallucination case: a prior agent claimed pure+pierces; KV and Liquipedia both co..." },
    ["modifier_earthshaker_echo_slam"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="pre_cast", lotus_reflectable=false, drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"},
        note="No-target instant burst centered on Earthshaker: initial magical damage + echo magical damage per nearby unit, no stun. Liquipedia confirms: magica..." },
    ["modifier_enigma_black_hole"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="none", delivery="channel", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true,
        note="Liquipedia confirms: point-target channelled AoE (420 inner radius) that pulls+disables, 4s max channel (zone_outlasts_cyclone=true, >2.5s), PURE d..." },
    ["modifier_enigma_black_hole_pull"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="none", delivery="channel", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true,
        note="Liquipedia confirms: point-target channelled AoE (420 inner radius) that pulls+disables, 4s max channel (zone_outlasts_cyclone=true, >2.5s), PURE d..." },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks
    ["modifier_kez_grappling_claw_slow"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="none", delivery="attack", primary_harm="damage", timing="at_impact", severity="survivable", drop_kinds={"invis"}, add_kinds={"displacement_blink", "reflect_target"},
        note="CONFLICT: Batch KV listed dt as 'none (PHYSICAL hit - VERIFY)'; Liquipedia + ability_data.lua (line 617, behavior unit_target, instant attack on ar..." },
    ["modifier_legion_commander_duel"] = { school="physical", damage_type="none", pierces_spell_immunity=true, dispellable="none", delivery="attack", primary_harm="disable", timing="reactive", forced_leash=true, lotus_reflectable=false, severity="lethal",
        note="Forced-leash attack-driven ult. school=physical + delivery=attack drives the physical branch: physical_immune + damage_block (Ghost/Ethereal makes ..." },
    ["modifier_life_stealer_open_wounds"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="post_apply", debuff_sticks_to_self=true, severity="survivable",
        note="Sticky self-debuff slow, damage_type=none so no magic_barrier. school=magical (Liquipedia: does not pierce debuff immunity -> BKB prevents it) so m..." },
    ["modifier_lina_laguna_blade"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="lethal",
        note="CONFLICT: none for the base ability. KV (dt=magical, pierces=false, disp=none, damage scaling 380/565/750) matches base Laguna. (Note: shard conver..." },
    ["modifier_lina_light_strike_array"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false,
        note="Area-target placed ground AoE with a 0.5s arming/effect delay, 250 radius, 1.2-2.4s stun, 80-200 magical token damage. LIQUIPEDIA_REF.md confirms: ..." },
    ["modifier_lion_finger_of_death"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="lethal",
        note="CONFLICT: Liquipedia's auto-summary on the standalone Finger_of_Death page wrongly claimed 'pierces spell immunity' AND 'pure damage' AND 'magical ..." },
    ["modifier_lion_mana_drain"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="channel", primary_harm="disable", timing="mid_channel", severity="survivable", add_kinds={"invuln", "magic_immune"},
        note="CONFLICT: none (KV damage_type=none / enemies_no / dispellable=no all match Liquipedia). 'Only dispellable by Death' => dispellable none in our tax..." },
    ["modifier_lion_voodoo"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="strong", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable", add_kinds={"dispel_strong"},
        note="CONFLICT: none. KV (dt=none, pierces=false, disp=strong) matches Liquipedia exactly. | Magical no-damage hex => school=magical, damage_type=none, p..." },
    ["modifier_magnataur_reverse_polarity_stun"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="strong", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"},
        note="No-target instant AoE lock (375 radius) that pulls all enemies to Magnus and stuns 2.0-3.5s. Liquipedia confirms: PIERCES debuff immunity (affects ..." },
    ["modifier_magnataur_skewer"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="line_charge", primary_harm="displacement", timing="at_impact", lotus_reflectable=false,
        note="KV: magical / enemies_no (no pierce) / yes=basic. Liquipedia confirms Skewer is a point/line charge in which Magnus dashes and DRAGS affected enemi..." },
    ["modifier_mirana_arrow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false,
        note="KV: magical / enemies_no (no pierce) / yes_strong. Liquipedia confirms Sacred Arrow is a traveling line skillshot (dodgeable in flight at 900 speed..." },
    ["modifier_naga_siren_ensnare"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_homing", targeted=true, primary_harm="disable", timing="at_impact", blocks_forced_movement=true, severity="survivable", add_kinds={"invuln", "reflect_target", "dispel_basic", "dispel_strong"},
        note="CONFLICT: none. KV (dt=none, pierces=false=enemies_no, disp=yes/basic, projectile-style net) matches Liquipedia. Scepter (has_scepter=1) adds condi..." },
    ["modifier_phantom_assassin_phantom_strike_target"] = { school="physical", damage_type="physical", pierces_spell_immunity=true, dispellable="basic", delivery="attack", primary_harm="damage", timing="reactive", enemy_self_buff=true, attack_enabler=true, severity="lethal",
        note="CONFLICT: none (KV spell_immunity=enemies_yes => pierces=true; dispellable=yes => basic; behavior 'blink + attack-speed buff = attack enabler' matc..." },
    ["modifier_pudge_dismember"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="strong", delivery="channel", primary_harm="disable", timing="mid_channel", severity="lethal", drop_kinds={"displacement_far", "displacement_perp", "displacement_blink"}, add_kinds={"invuln"},
        note="CONFLICT: none (KV magical/pierces=true/strong matches Liquipedia). Lotus reflects at cast only (not modeled by reflect_target, delivery=channel). ..." },
    ["modifier_pudge_dismember_pull"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="strong", delivery="channel", primary_harm="disable", timing="mid_channel", severity="lethal", drop_kinds={"displacement_far", "displacement_perp", "displacement_blink"}, add_kinds={"invuln"},
        note="CONFLICT: none. KV row pudge_dismember_pull shares ability pudge_dismember (magical/pierces=true/strong). | The pull is the displacement sub-modifi..." },
    ["modifier_pudge_meat_hook"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="none", delivery="projectile_line", primary_harm="displacement", timing="at_impact", lotus_reflectable=false, severity="lethal", drop_kinds={"invuln"},
        note="KV: pure / enemies_yes (pierces) / none. Liquipedia confirms Meat Hook deals PURE damage, pierces debuff immunity, stun is only-dispellable-by-deat..." },
    ["modifier_pugna_life_drain"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="channel", primary_harm="damage", timing="mid_channel", severity="lethal", add_kinds={"invuln", "magic_immune"},
        note="CONFLICT: Liquipedia says 'Pierces Debuff Immunity sources' for Life Drain, but KV spell_immunity=enemies_no (does NOT pierce). Per the authoritati..." },
    ["modifier_razor_static_link_debuff"] = { school="magical", damage_type="none", pierces_spell_immunity=true, dispellable="none", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="CONFLICT: Old file comment said 'pierces BKB' vs an agent's 'partial'; KV spell_immunity=enemies_yes => pierces=true and Liquipedia confirms the ha..." },
    ["modifier_shadow_shaman_shackles"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="channel", primary_harm="disable", timing="mid_channel", severity="lethal", drop_kinds={"displacement_far", "displacement_perp", "displacement_blink"}, add_kinds={"invuln", "magic_immune"},
        note="CONFLICT: Liquipedia 'Pierces Debuff Immunity sources conditionally' vs KV enemies_no. Resolved: the conditional pierce is Aghanim's Scepter only; ..." },
    ["modifier_shadow_shaman_voodoo"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="strong", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable", add_kinds={"dispel_strong"},
        note="CONFLICT: none. KV (dt=none, pierces=false, disp=strong) matches Liquipedia. Mechanically identical to Lion Hex. | Same class as Lion Voodoo: magic..." },
    ["modifier_techies_suicide_leap"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="leap", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="lethal",
        note="v0.5.149 Blast Off! (techies_suicide, KV ID 5601). POINT+AOE, magical, spell_immunity enemies_no (=> pierces=false), dispellable yes (basic). cast_point 1.0 then a FIXED 0.75s leap (KV duration 0.75), 400 radius, 200/300/400/500 magical + 0.8-1.4s stun + 20% self hp_cost. The COMBO TRIGGER (Land Mines + Sticky Bomb detonate with the landing) so THREAT_SEVERITY=high (not withheld by low_severity_high_hp). delivery=leap => DeriveCounters keeps invuln (WW/Eul, v0.5.143 leap rule) + displacement (Force/Pike/Blink, out of the 400 AoE) + magic_immune (BKB eats the magical burst + the stun). modseen-confirmed: modifier_techies_suicide_leap is created on Techies in-flight (demo closing 496->239u) => OnModifierCreate arms it by proximity like Slark/Huskar. NOTE: an already-LATCHED Sticky Bomb still rides Force/Pike/WW (log _windwaker variant); BKB/Eul-invuln answer that, but the leap itself is fully dodged here." },
    ["modifier_slark_pounce"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="leap", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none (KV damage_type=magical but pounce_damage=0 so primary_harm=disable not damage; spell_immunity=enemies_no => pierces=false matches L..." },
    ["modifier_slark_pounce_leash"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="leap", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none (KV damage_type=magical but pounce_damage=0 so primary_harm=disable not damage; spell_immunity=enemies_no => pierces=false matches L..." },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks
    ["modifier_spirit_breaker_charge_of_darkness"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="homing_charge", primary_harm="disable", timing="at_impact", severity="lethal",
        note="CONFLICT: Liquipedia phrases spell immunity as 'pierces Debuff Immunity conditionally', but KV spell_immunity=enemies_no => pierces=false and the r..." },
    ["modifier_sven_storm_bolt"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_homing", targeted=true, primary_harm="disable", timing="at_impact", add_kinds={"invuln", "reflect_target"},
        note="KV: magical / enemies_no (no pierce) / yes_strong; behavior unit_target+aoe homing projectile. Liquipedia: unit-targeted projectile launched at the..." },
    ["modifier_tidehunter_ravage"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"},
        note="No-target instant PBAoE stun (1250 radius), 2.0-2.4s stun, 275-475 magical token damage. KV (ability_data.lua L1847): damage_type=magical, spell_im..." },
    ["modifier_treant_overgrowth"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="reactive", lotus_reflectable=false, drop_kinds={"displacement_blink"},
        note="No-target PBAoE root (800 radius) around Treant, 3-5s root, 95/s magical DoT. KV (ability_data.lua L1877): damage_type=magical, spell_immunity=enem..." },
    ["modifier_tusk_ice_shards_thinker"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false,
        note="KV: magical / enemies_no (no pierce) / no dispellable field (=none). Liquipedia confirms Ice Shards is a point/line projectile that damages on impa..." },
    ["modifier_tusk_snowball_movement"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="homing_charge", primary_harm="damage", timing="at_impact", severity="lethal",
        note="CONFLICT: none (KV damage_type=magical, spell_immunity=enemies_no => pierces=false, dispellable=no all match Liquipedia: harmful payload does not p..." },
    ["modifier_ursa_overpower"] = { school="physical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="attack", primary_harm="damage", timing="pre_cast", lotus_reflectable=false, enemy_self_buff=true, severity="lethal",
        note="Enemy self-buff (buff is ON Ursa). enemy_self_buff=true -> dispel branch suppressed (your dispel cannot remove Ursa's self-buff; only diffusal-on-h..." },
    ["modifier_witch_doctor_death_ward"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="none", delivery="channel", positional=true, primary_harm="damage", timing="mid_channel", severity="lethal", add_kinds={"invuln", "invis"},
        note="CONFLICT: none (KV pure / pierces=true / dispellable absent => none matches). Lotus interaction not documented as reflectable in the harmful sense;..." },
    ["modifier_zuus_lightning_bolt"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="survivable",
        note="CONFLICT: KV dispellable=none for the bolt modifier; Liquipedia says the 0.35s ministun is Strong-dispellable. KV wins for save purposes: the linge..." },
    ["modifier_zuus_thundergods_wrath"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="Global no-target magical nuke. targeted=false (no single-target cast) and lotus_reflectable=false (a global no-target ult is not reflected by Lotus..." },

    -- ===== Task 7: previously-unconstrained catalogued threats (164) =====
    ["modifier_alchemist_unstable_concoction"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="projectile_homing", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable", drop_kinds={"displacement_blink"},
        note="Concoction Throw is a unit-target latching projectile (KV unit_target+aoe, projectile_speed 900). KV throw row has no damage_type (dt nil => damage..." },
    ["modifier_ancient_apparition_bone_chill_debuff"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: Liquipedia says Bone Chill is 'Dispellable by any Dispel sources' (basic), but the authoritative modifier KV line gives disp=nil => dispe..." },
    ["modifier_ancientapparition_coldfeet_freeze"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="strong", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: KV slot for this modifier was empty (unmapped). Resolved ability ancient_apparition_cold_feet has dt=magical, si=enemies_no, disp=yes(bas..." },
    ["modifier_arc_warden_flux"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="survivable",
        note="Flux is a single-target magical DoT (+isolation slow), Liquipedia: unit-targeted, primary harm is magical damage over time, basic-dispellable (matc..." },
    ["modifier_batrider_flaming_lasso"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="strong", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", forced_leash=true, severity="survivable",
        note="CONFLICT: Liquipedia describes the lasso debuff as 'Only dispellable by Death', but authoritative KV gives disp=yes_strong => dispellable=strong. K..." },
    ["modifier_beastmaster_primal_roar"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="strong", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="Primal Roar is a long single-target stun (3-4s) that pierces debuff immunity (KV enemies_yes) with only token magical damage. pierces=true suppress..." },
    ["modifier_blinding_light_knockback"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="displacement", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: KV slot for this modifier was empty (unmapped). Resolved ability keeper_of_the_light_blinding_light: dt=magical, si=enemies_no, disp=yes(..." },
    ["modifier_bloodseeker_rupture"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="lethal",
        note="Rupture deals pure movement-based damage, pierces debuff immunity (KV enemies_yes), and is not dispellable (KV disp=no => none; 'only dispellable b..." },
    ["modifier_bounty_hunter_shuriken_toss"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="disable", timing="at_impact", severity="survivable",
        note="Unit-target non-homing magical projectile that applies only a 0.35s 100% slow (no meaningful damage; modeled damage_type=none, primary_harm=disable..." },
    ["modifier_brewmaster_cinder_brew"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Area ground-cast that drenches enemies with a dispellable magical slow debuff (24-36% for 5s); collision damage is incidental so the countered modi..." },
    ["modifier_bristleback_viscous_nasal_goo"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Hairball is a point-target projectile that erupts and applies a slow debuff. KV dt=nil => damage_type=none; this slow modifier carries no damage. s..." },
    ["modifier_broodmother_sticky_snare"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable", add_kinds={"magic_barrier"},
        note="Aghanim placed web trap: roots for ~2.75s and deals 100 magical DPS (~300 over 3s). KV magical + enemies_no(no-pierce) + disp yes(basic). Primary h..." },
    ["modifier_broodmother_sticky_snare_root"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable", add_kinds={"magic_barrier"},
        note="Aghanim placed web trap: roots for ~2.75s and deals 100 magical DPS (~300 over 3s). KV magical + enemies_no(no-pierce) + disp yes(basic). Primary h..." },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks
    ["modifier_chaos_knight_chaos_bolt"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="lethal", add_kinds={"dispel_strong"},
        note="Unit-target parabolic projectile, random stun 1.25-3.25s (primary_harm=disable) + random magical damage. KV magical + enemies_no(no-pierce) + disp ..." },
    ["modifier_chaos_knight_reality_rift"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="displacement", timing="post_apply", severity="survivable", drop_kinds={"magic_immune"}, add_kinds={"dispel_basic"},
        note="CONFLICT: KV beh lists root_disables but Liquipedia confirms Reality Rift does NOT root or disarm the target after the pull; the flag reflects the ..." },
    ["modifier_chaos_knight_reality_rift_debuff"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="displacement", timing="post_apply", severity="survivable", drop_kinds={"magic_immune"}, add_kinds={"dispel_basic"},
        note="CONFLICT: KV beh lists root_disables but Liquipedia confirms Reality Rift does NOT root or disarm the target after the pull; the flag reflects the ..." },  -- 2026-07-28: VPK-verified alias (_debuff = the VICTIM-side name); bare key absent from all 664 paks
    ["modifier_chen_penitence"] = { school="pure", damage_type="pure", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="post_apply", severity="survivable", add_kinds={"magic_immune"},
        note="Unit-target debuff: slow (12-30%) + damage amplification for 5-8s, plus a small pure-damage instance on cast. KV pure + enemies_no(no-pierce) + dis..." },
    ["modifier_chilling_touch_slow"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="attack", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: KV dt=magical refers to the attack's bonus magic damage; this modifier_chilling_touch_slow carries no damage, only the brief movement slo..." },
    ["modifier_chilling_touch_super_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="attack", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: ab unmapped in KV; resolved to ancient_apparition_chilling_touch (slow=100). KV dt=magical/si=enemies_no/disp=yes used authoritatively. |..." },
    ["modifier_cold_feet"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="post_apply", severity="survivable",
        note="CONFLICT: none; KV dt=magical/si=enemies_no/disp=yes match Liquipedia (basic dispel). | Cold Feet applies instantly (no projectile) and the threat ..." },
    ["modifier_crystal_maiden_frostbite"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="post_apply", severity="survivable",
        note="CONFLICT: none; KV dt=magical/si=enemies_no/disp=yes match Liquipedia (root, basic dispel). | Frostbite is an instant single-target root debuff (pr..." },
    ["modifier_dark_seer_ion_shell"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="damage", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none; KV dt=magical/si=enemies_no/disp=yes match Liquipedia (magic DoT, basic dispel). | When cast on the defender, Ion Shell is a persis..." },
    ["modifier_dark_seer_vacuum"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", primary_harm="displacement", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none; KV dt=magical/si=enemies_no/disp=yes_strong match Liquipedia (BKB blocks it, strong dispel). | Vacuum's dominant harm is the forced..." },
    ["modifier_dark_willow_bramble_maze"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="post_apply", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none; KV dt=magical/si=enemies_no/disp=yes match Liquipedia (root + magic DoT, basic dispel). | Placed persistent AoE zone (positional=tr..." },
    ["modifier_dark_willow_cursed_crown"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="post_apply", severity="survivable",
        note="CONFLICT: KV dt=nil => damage_type=none (Cursed Crown deals no damage, consistent with Liquipedia). si=enemies_no/disp=yes used authoritatively. sc..." },
    ["modifier_dark_willow_terrorize"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: KV dt=magical but Terrorize lists no damage value => modeled damage_type=none (fear/no-damage). si=enemies_no/disp=yes used authoritative..." },
    ["modifier_dawnbreaker_celestial_hammer"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_line", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="Point-target line projectile (projectile_line), magical no-pierce damage+slow, basic dispel. invuln (at_impact, non-homing) + magic_immune (school=..." },
    ["modifier_dazzle_poison_touch"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="damage", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: KV behavior=unit_target but current Liquipedia Poison Touch is a cone; immaterial to derivation (delivery=spell either way, not Lotus-rel..." },
    ["modifier_death_prophet_silence"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="No-damage magical silence delivered as an area projectile at impact => school=magical, damage_type=none, primary_harm=disable. invuln (at_impact, n..." },
    ["modifier_doom_bringer_infernal_blade"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="attack", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable", add_kinds={"magic_immune"},
        note="Attack-driven magical stun+burn. delivery=attack, school=magical. invuln fires (at_impact, non-homing) -> dodging/avoiding the attack avoids it. ma..." },
    ["modifier_dragon_knight_dragon_tail"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="Unit-target instant magical stun (disable-primary, token damage), strong-dispel only, no-pierce. invuln (pre_cast) + magic_immune (school=magical, ..." },
    ["modifier_drow_ranger_frost_arrows_slow"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="basic", delivery="attack", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Attack-driven physical orb that kites via a slow-on-hit. school=physical, delivery=attack => physical branch: physical_immune + damage_block (BKB/G..." },
    ["modifier_earth_spirit_rolling_boulder_caster"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="line_charge", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: Prior pass HALLUCINATED 'pure+pierces -> drop magic_immune'; KV is magical/enemies_no (no-pierce), so magic_immune is CORRECT here per th..." },
    ["modifier_earthshaker_earthsplitter"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="basic", delivery="spell", positional=true, primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: Modifier name 'modifier_earthshaker_earthsplitter' is MISLABELED: it maps to elder_titan_earth_splitter (lib/ability_data.lua line 393), ..." },
    ["modifier_earthshaker_fissure_stun"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="lethal", add_kinds={"dispel_strong"},
        note="CONFLICT: none - batch KV (magical / enemies_no / yes_strong) matches lib/ability_data.lua line 389 earthshaker_fissure | Fissure is a non-piercing..." },
    ["modifier_ember_spirit_sleight_of_fist_caster"] = { school="physical", damage_type="physical", pierces_spell_immunity=true, dispellable="none", delivery="attack", primary_harm="damage", timing="at_impact", lotus_reflectable=false, enemy_self_buff=true, severity="survivable",
        note="CONFLICT: none - batch KV (physical / enemies_yes / nil) matches lib/ability_data.lua line 409 ember_spirit_sleight_of_fist | This modifier is Embe..." },
    ["modifier_enigma_malefice"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="CONFLICT: none - batch KV (magical / enemies_no / yes) matches lib/ability_data.lua line 421 enigma_malefice | Malefice is a single-target instant ..." },
    ["modifier_faceless_void_chronosphere"] = { school="magical", damage_type="none", pierces_spell_immunity=true, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="lethal",
        note="CONFLICT: none - batch KV (nil dmg / enemies_yes / no) matches lib/ability_data.lua line 428 faceless_void_chronosphere | Chronosphere pierces spel..." },
    ["modifier_faceless_void_chronosphere_freeze"] = { school="magical", damage_type="none", pierces_spell_immunity=true, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="lethal",
        note="CONFLICT: none - same ability as chronosphere; batch KV (nil dmg / enemies_yes / no) matches lib/ability_data.lua line 428 faceless_void_chronosphe..." },
    ["modifier_faceless_void_time_dilation_distortion"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none - batch KV (magical / enemies_no / yes) matches lib/ability_data.lua line 430 faceless_void_time_dilation | Low-impact AoE slow / co..." },
    ["modifier_faceless_void_timelock_freeze"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="strong", delivery="attack", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: RESOLVED - batch KV labelled this nil/nil/nil because the auto-mapper queried 'faceless_void_timelock'; the real KV ability is 'faceless_..." },
    ["modifier_furion_sprout"] = { school="none", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none on dispel - the modifier_furion_sprout KV (lib/ability_data.lua line 464) has no spell_immunity and no dispellable field, so per the..." },
    ["modifier_furion_sprout_entangle"] = { school="none", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none on dispel - the modifier_furion_sprout KV (lib/ability_data.lua line 464) has no spell_immunity and no dispellable field, so per the..." },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks
    ["modifier_grimstroke_ink_creature"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="projectile_homing", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable", drop_kinds={"displacement_blink"}, add_kinds={"invuln"},
        note="KV: magical, si enemies_no (no pierce), disp no, behavior unit_target. Phantom's Embrace summons a phantom projectile (speed 1150) that travels to ..." },
    ["modifier_grimstroke_soul_chain"] = { school="magical", damage_type="none", pierces_spell_immunity=true, dispellable="none", delivery="spell", targeted=true, primary_harm="disable", timing="post_apply", forced_leash=true, lotus_reflectable=false, severity="survivable", add_kinds={"displacement_blink"},
        note="KV dt nil/si enemies_yes(pierce)/disp no. Soulbind: forced leash, pierces, undispellable. Blink Dagger BREAKS the chain (Force does NOT) -> add_kinds displacement_blink (rule has no targeted-leash-blink branch)." },
    ["modifier_gyrocopter_call_down_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="damage", timing="post_apply", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable", drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"},
        note="KV: magical, si enemies_no (no pierce), disp yes (basic), behavior point+aoe. Call Down drops two delayed aerial missiles on a target AREA (point-t..." },
    ["modifier_gyrocopter_homing_missile"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_homing", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable", add_kinds={"invuln"},
        note="KV: magical, si enemies_no (no pierce), disp yes_strong (strong), behavior unit_target. Homing Missile fires a slow accelerating projectile that SE..." },
    ["modifier_hoodwink_bushwhack"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", positional=true, primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable", drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"}, add_kinds={"invuln"},
        note="KV: magical, si nil (=> pierces false, debuff-immune enemies are explicitly NOT affected per Liquipedia), disp yes_strong (strong), behavior point+..." },
    ["modifier_huskar_life_break_charge"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="basic", delivery="leap", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="lethal", add_kinds={"magic_barrier"},
        note="KV: magical, si enemies_yes (=> pierces true), disp yes (basic dispel, but it is applied on HUSKAR himself on cast, not on the victim), behavior un..." },
    ["modifier_ice_blast"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="none", delivery="projectile_line", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="lethal", drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"},
        note="KV: magical, si enemies_yes (=> pierces true), disp no (none), behavior point+aoe. Ice Blast launches a tracer along a path that is RELEASED to det..." },
    ["modifier_ice_vortex"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="at_impact", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable", drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"},
        note="KV: magical, si enemies_no (no pierce), disp no (none), behavior aoe+point. Ice Vortex places a persistent ground zone (duration 6-12s) that slows ..." },
    ["modifier_invoker_cold_snap"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="damage", timing="post_apply", debuff_sticks_to_self=true, severity="survivable",
        note="CONFLICT: Liquipedia changelog text surfaced via WebSearch claims Cold Snap was 'fixed to no longer be dispellable.' Authoritative KV lib/ability_d..." },
    ["modifier_jakiro_ice_path"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="strong", delivery="spell", positional=true, primary_harm="disable", timing="at_impact", zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none (KV damage=0 => damage_type=none consistent with Liquipedia 'stun is the core mechanic'; dispellable=yes_strong consistent). | No-da..." },
    ["modifier_jakiro_macropyre_thinker"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="at_impact", zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none for base ability (KV damage_type=magical, dispellable=no). Note: Aghanim's Scepter converts to pure (KV pure_damage_type flag); base..." },
    ["modifier_juggernaut_omni_slash"] = { school="physical", damage_type="physical", pierces_spell_immunity=true, dispellable="none", delivery="attack", primary_harm="damage", timing="at_impact", forced_leash=true, lotus_reflectable=false, already_locked_channel=true, severity="lethal",
        note="CONFLICT: none (KV damage_type=physical, spell_immunity=enemies_yes => pierces=true, dispellable=no => none, all consistent). | Attack-driven physi..." },
    ["modifier_keeper_of_the_light_blinding_light"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="damage", timing="pre_cast", severity="survivable",
        note="CONFLICT: none (KV damage_type=magical, dispellable=yes => basic, spell_immunity=enemies_no => no-pierce, consistent). | Instant AoE magic nuke wit..." },
    ["modifier_keeper_of_the_light_radiant_bind"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="post_apply", debuff_sticks_to_self=true, severity="survivable",
        note="CONFLICT: none (KV damage_type=nil => none, dispellable=yes => basic, spell_immunity=enemies_no => no-pierce, consistent). No-damage magical disabl..." },
    ["modifier_keeper_of_the_light_will_o_wisp"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="damage", timing="at_impact", zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none (KV damage_type=magical, dispellable=yes => basic, spell_immunity=enemies_no => no-pierce, consistent). | Persistent placed magical ..." },
    ["modifier_kez_raptor_dance"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="pre_cast", lotus_reflectable=false, severity="lethal",
        note="CONFLICT: none (KV damage_type=pure, spell_immunity=enemies_yes => pierces=true, dispellable=nil => none, consistent). Note KV basic_dispel=1 is th..." },
    ["modifier_kunkka_torrent_stun"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="Torrent is a placed ground AoE (250 radius) with a 1.6s arming delay that erupts to knock up + stun 1.4s + slow + damage. Liquipedia confirms place..." },
    ["modifier_kunkka_torrent_thinker"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="The thinker is the placed-AoE timer entity that arms the Torrent before eruption; it represents the same incoming Torrent threat as the stun sub-mo..." },
    ["modifier_kunkka_x_marks_the_spot"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="displacement", timing="pre_cast", severity="survivable", add_kinds={"reflect_target"},
        note="X Marks marks an enemy and teleports them back to the X after ~3s; no damage, no disable -> primary_harm=displacement, damage_type=none, school=mag..." },
    ["modifier_largo_catchy_lick"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="survivable",
        note="Catchy Lick is a single-target unit-targeted magical nuke (85-340) that also yanks the target a short distance toward Largo and applies a basic dis..." },
    ["modifier_largo_catchy_lick_knockback"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="displacement", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="The knockback sub-modifier is the short forced pull (235-325u toward Largo, locks facing per Liquipedia). It deals no damage of its own (the damage..." },
    ["modifier_largo_croak_of_genius_debuff"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="damage", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Croak of Genius is cast on a friendly ally (buff); this debuff is the ENEMY-side reverberate effect: when the buffed ally deals spell damage, the e..." },
    ["modifier_largo_frogstomp_debuff"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="Frogstomp is a point/area-targeted placed AoE (350 radius) that tosses froglings dealing magical damage over 4-7 stomp ticks at 1s intervals (zone ..." },
    ["modifier_legion_commander_intimidate_slow"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: Auto-map points ab to legion_commander_press_the_attack, but the slow actually comes from the innate legion_commander_intimidate (lib/abi..." },
    ["modifier_leshrac_split_earth"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", primary_harm="disable", timing="pre_cast", lotus_reflectable=false, severity="lethal",
        note="Ground-targeted point AoE that stuns for 2s and deals magical damage with a ~0.35s arming delay after the cast animation, so you can react before t..." },
    ["modifier_lich_chain_frost"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_homing", primary_harm="damage", timing="at_impact", severity="lethal", drop_kinds={"displacement_blink"}, add_kinds={"dispel_basic", "dispel_strong"},
        note="Bouncing ice projectile that re-targets between units (up to 10 bounces, 600 range) => delivery=projectile_homing. KV magical/enemies_no => school=..." },
    ["modifier_lich_sinister_gaze"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="channel", targeted=true, primary_harm="disable", timing="mid_channel", severity="survivable",
        note="Unit-target channelled disable: applies Cannot Act, hypnotizes the target and forces it to move toward a midpoint between Lich and target while dra..." },
    ["modifier_lone_druid_spirit_bear_entangle_effect"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="basic", delivery="attack", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Attack-triggered passive root (after 5 stacks) that immobilizes and deals magical DoT (damage always sourced to Lone Druid). KV ab=lone_druid_spiri..." },
    ["modifier_magnataur_shockwave_pull"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="projectile_line", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="Traveling line shockwave that nudges hit enemies ~150 units toward the wave centerline (a soft knockback-pull) and applies magical damage + slow. K..." },
    ["modifier_magnataur_skewer_impact"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="line_charge", primary_harm="displacement", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: ab field was empty; resolved to magnataur_skewer (lib/ability_data.lua line 736): damage_type=magical, spell_immunity=enemies_no, dispell..." },
    ["modifier_magnataur_skewer_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none (magnataur_skewer: magical, enemies_no, dispellable=yes) | The post-drag movement slow applied by Skewer. KV magical/enemies_no => s..." },
    ["modifier_maledict"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Point-target AoE curse: applies a magical DoT to all enemy heroes in radius, with bonus bursts every 4s scaled to HP lost since the curse began. KV..." },
    ["modifier_maledict_dot"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="post_apply", debuff_sticks_to_self=true, lotus_reflectable=false, severity="survivable",
        note="CONFLICT: Batch KV listed dt/si/disp as nil because ab was empty (unmapped). Resolved via lib/ability_data.lua witch_doctor_maledict (id 5140): dam..." },
    ["modifier_marci_grapple"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="displacement", timing="pre_cast", severity="survivable",
        note="CONFLICT: None. KV (marci_grapple): damage_type=magical, spell_immunity=enemies_no (pierces=false), dispellable=yes (basic), behavior=unit_target. ..." },
    ["modifier_mars_arena_of_blood"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", blocks_forced_movement=true, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: None. KV (mars_arena_of_blood): damage_type=magical, spell_immunity=enemies_no (pierces=false), behavior=point+aoe. dispellable nil => no..." },
    ["modifier_mars_gods_rebuke"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="pre_cast", lotus_reflectable=false, severity="lethal", add_kinds={"damage_block"},
        note="CONFLICT: None. KV (mars_gods_rebuke): damage_type=physical, behavior=point+normal_when_stolen, si/disp nil. school=physical, damage_type=physical,..." },
    ["modifier_mars_spear"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="lethal",
        note="CONFLICT: Minor: Liquipedia tooltip says 'dispellable only by death' for the pin, but KV (mars_spear) dispellable=yes_strong governs => dispellable..." },
    ["modifier_mars_spear_stun"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="lethal",
        note="CONFLICT: Minor: Liquipedia tooltip says 'dispellable only by death' for the pin, but KV (mars_spear) dispellable=yes_strong governs => dispellable..." },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks
    ["modifier_medusa_gorgon_grasp"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, severity="survivable", add_kinds={"magic_immune"},
        note="CONFLICT: None. KV (medusa_gorgon_grasp): damage_type=physical, spell_immunity=enemies_no (pierces=false), dispellable=yes (basic), behavior=aoe+po..." },
    ["modifier_medusa_gorgon_grasp_root"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, severity="survivable", add_kinds={"magic_immune"},
        note="CONFLICT: None. KV (medusa_gorgon_grasp): damage_type=physical, spell_immunity=enemies_no (pierces=false), dispellable=yes (basic), behavior=aoe+po..." },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks
    ["modifier_medusa_mystic_snake"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="survivable",
        note="CONFLICT: None. KV (medusa_mystic_snake): damage_type=magical, spell_immunity=enemies_no (pierces=false), behavior=unit_target. dispellable nil => ..." },
    ["modifier_meepo_earthbind"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: None. KV (meepo_earthbind): damage_type nil (no damage => damage_type=none, school=magical for the no-damage magical root), spell_immunit..." },
    ["modifier_monkey_king_wukongs_command_aura"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="none", delivery="attack", positional=true, primary_harm="damage", timing="reactive", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="KV: physical, no si (physical attacks do not pierce), no dispel. Liquipedia: placed self-centered ring of soldiers (300/750 radius) that auto-attac..." },
    ["modifier_morphling_adaptive_strike_agi"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="projectile_homing", primary_harm="disable", timing="at_impact", severity="survivable",
        note="CONFLICT: KV disp=nil (none); Liquipedia notes stun is strong-dispellable, but authoritative KV is used so dispellable=none. | KV: magical, enemies..." },
    ["modifier_muerta_dead_shot"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_line", primary_harm="damage", timing="at_impact", severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="KV: magical, enemies_no (no pierce), disp=yes (basic), vector_targeting. Liquipedia: vector-targeted line trickshot (speed 2000) dealing 100-325 ma..." },
    ["modifier_muerta_dead_shot_fear"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_line", primary_harm="damage", timing="at_impact", severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="KV: magical, enemies_no (no pierce), disp=yes (basic), vector_targeting. Liquipedia: vector-targeted line trickshot (speed 2000) dealing 100-325 ma..." },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks
    ["modifier_naga_siren_song_of_the_siren"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="disable", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: KV disp=no (none); Liquipedia text says sleep is dispellable, but authoritative KV (dispellable=no) is used, so dispellable=none and no d..." },
    ["modifier_necrolyte_heartstopper_aura_effect"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="none", delivery="spell", primary_harm="damage", timing="reactive", lotus_reflectable=false, severity="survivable",
        note="KV: magical, enemies_yes (PIERCES spell immunity), disp=no. Liquipedia confirms it pierces debuff immunity and is only dispellable by death. Low-im..." },
    ["modifier_necrolyte_reapers_scythe"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="lethal",
        note="KV: magical, enemies_no (no pierce), disp=no. Liquipedia: unit-targeted single-target nuke, 1.5s stun, magical damage scaling with MISSING health (..." },
    ["modifier_nevermore_requiem"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="damage", timing="pre_cast", lotus_reflectable=false, severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="CONFLICT: Batch line listed empty fields, but the real ability_data.lua entry 'nevermore_requiem' (line 852) has damage_type=magical, spell_immunit..." },
    ["modifier_night_stalker_void"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="KV: magical, enemies_no (no pierce), disp=yes (basic), unit_target. Liquipedia: unit-targeted instant nuke (80-320 magical) + 50% MS/AS slow (+0.1s..." },
    ["modifier_nyx_assassin_impale"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none. KV magical / enemies_no (no pierce) / yes_strong matches Liquipedia. | Magical line skillshot, stun-dominant (primary_harm=disable ..." },
    ["modifier_nyx_assassin_vendetta"] = { school="pure", damage_type="pure", pierces_spell_immunity=true, dispellable="none", delivery="spell", primary_harm="damage", timing="pre_cast", lotus_reflectable=false, severity="lethal",
        note="CONFLICT: none. KV pure / enemies_yes (pierces) / none / immediate+no_target matches Liquipedia self-cast alpha-strike. | Self-buff invisibility wh..." },
    ["modifier_obsidian_destroyer_astral_imprisonment"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="CONFLICT: none. KV magical / enemies_no (no pierce) / dispellable=no (=none) matches Liquipedia. | Single-target instant banish-disable. primary_ha..." },
    ["modifier_obsidian_destroyer_sanity_eclipse"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="pre_cast", lotus_reflectable=false, severity="lethal",
        note="CONFLICT: none. KV magical / enemies_no (no pierce) / disp=nil (=none) matches Liquipedia point-AoE burst. | Instant point-AoE magical burst (no li..." },
    ["modifier_ogre_magi_fireblast"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable", add_kinds={"dispel_strong"},
        note="CONFLICT: none. KV magical / enemies_no (no pierce) / yes_strong matches Liquipedia. | Single-target instant stun (primary_harm=disable -> no magic..." },
    ["modifier_omniknight_hammer_of_purity"] = { school="physical", damage_type="pure", pierces_spell_immunity=true, dispellable="basic", delivery="attack", targeted=true, primary_harm="damage", timing="reactive", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none. KV pure / enemies_yes (pierces) / yes (=basic) / autocast+attack+ignore_silence matches Liquipedia attack-modifier. | Attack-delive..." },
    ["modifier_oracle_fortunes_end_channel_target"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="channel", primary_harm="disable", timing="mid_channel", lotus_reflectable=false, severity="survivable", drop_kinds={"displacement_far", "displacement_perp", "displacement_blink"}, add_kinds={"invuln", "magic_immune"},
        note="CONFLICT: KV spell_immunity=enemies_no (harmful root does NOT pierce) vs Liquipedia 'pierces conditionally' (True-Sight-only). KV is authoritative ..." },
    ["modifier_oracle_fortunes_end_purge"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable", drop_kinds={"magic_immune"},
        note="CONFLICT: none for save purposes. KV row is empty (ab=''); inherits parent ability oracle_fortunes_end: magical / enemies_no (no pierce) / yes (=ba..." },
    ["modifier_oracle_purifying_flames"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="survivable",
        note="KV magical/enemies_no(no-pierce)/basic-dispel/unit_target. Single-target instant magical nuke -> delivery=spell, targeted, pre_cast. invuln (pre_ca..." },
    ["modifier_pangolier_gyroshell"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="none", delivery="homing_charge", primary_harm="disable", timing="at_impact", severity="survivable",
        note="KV physical/enemies_no/disp=no/no_target ult. Harm comes from a steerable pursuing roll that bounces and re-acquires -> delivery=homing_charge, tim..." },
    ["modifier_pangolier_swashbuckle"] = { school="physical", damage_type="physical", pierces_spell_immunity=true, dispellable="none", delivery="line_charge", primary_harm="damage", timing="at_impact", severity="survivable",
        note="KV physical/enemies_yes(PIERCES)/disp=nil(none)/point+vector_targeting dash. Self-displacing line dash that strikes along a line -> delivery=line_c..." },
    ["modifier_phantom_assassin_stiflingdagger"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_homing", primary_harm="damage", timing="at_impact", severity="survivable", add_kinds={"invuln"},
        note="CONFLICT: KV dispellable=yes (basic), si=nil so does NOT pierce (false) - both consistent with Liquipedia; no conflict. | KV physical/no-pierce/bas..." },
    ["modifier_phantom_lancer_spirit_lance"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_homing", targeted=true, primary_harm="damage", timing="at_impact", severity="survivable",
        note="KV magical/enemies_no(no-pierce)/basic-dispel/unit_target. Unit-target homing magical projectile -> delivery=projectile_homing, at_impact, primary_..." },
    ["modifier_phoenix_sun_ray"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="channel", primary_harm="damage", timing="mid_channel", severity="survivable",
        note="CONFLICT: KV behavior lacks an explicit channelled flag (listed as point), but Liquipedia confirms it is a sustained, interruptible beam; modeled a..." },
    ["modifier_primal_beast_onslaught"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="basic", delivery="line_charge", primary_harm="disable", timing="at_impact", severity="survivable",
        note="CONFLICT: Liquipedia summary phrased the stun as 'Strong Dispel'; KV is authoritative and says dispellable=yes (basic). Resolved to basic. Moot for..." },
    ["modifier_primal_beast_pulverize"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="none", delivery="channel", targeted=true, primary_harm="disable", timing="mid_channel", severity="lethal",
        note="KV magical/enemies_yes(PIERCES)/disp=nil(none)/channelled+unit_target. Single-target lockdown channel -> delivery=channel, timing=mid_channel, prim..." },
    ["modifier_puck_dream_coil"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", forced_leash=true, lotus_reflectable=false, zone_outlasts_cyclone=true, severity="lethal", drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"},
        note="KV: magical, enemies_no (no pierce), disp=no. Liquipedia: placed AoE coil that leashes all heroes in radius and stuns only if you move 600+ away (f..." },
    ["modifier_puck_waning_rift"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="KV: magical, enemies_no (no pierce), disp=yes (basic). Liquipedia: instant self-blink AoE silence + damage, no persistent zone. primary_harm=disabl..." },
    ["modifier_rattletrap_hookshot"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="strong", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="lethal",
        note="KV: magical, enemies_yes (PIERCES), disp=yes_strong. Liquipedia: a line hook (point-targeted skillshot) that latches the first enemy hit, pulls Clo..." },
    ["modifier_razor_eye_of_the_storm_armor"] = { school="physical", damage_type="physical", pierces_spell_immunity=true, dispellable="none", delivery="spell", primary_harm="damage", timing="post_apply", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="KV: physical, enemies_yes (PIERCES), disp=no, no_target+immediate. This modifier is the per-strike armor-reduction debuff. Liquipedia: persistent ~..." },
    ["modifier_razor_plasma_field_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="damage", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="KV: magical, enemies_no (no pierce), disp=yes (basic). This is the slow debuff modifier. Liquipedia: self-centered expanding/contracting wave (~2.2..." },
    ["modifier_razor_storm_surge_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="reactive", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: ab KV has si=nil and disp=nil; per the rules nil spell_immunity defaults to no-pierce (pierces=false) and nil dispellable => none. No con..." },
    ["modifier_riki_smoke_screen"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="pre_cast", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable", drop_kinds={"displacement_perp", "displacement_far", "displacement_blink"},
        note="KV: dt=nil (no damage), enemies_no (no pierce), disp=no. Liquipedia: placed AoE smoke cloud, persistent ~6s (zone_outlasts_cyclone), silence + miss..." },
    ["modifier_ringmaster_impalement"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_line", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="KV: magical, enemies_no (no pierce), disp=yes (basic), behavior=point. Liquipedia: line dagger skillshot (directional projectile) that hits the fir..." },
    ["modifier_ringmaster_the_box"] = { school="none", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, enemy_self_buff=true, severity="survivable",
        note="Escape Act / The Box (ringmaster_the_box, KV target_team={friendly}, dt=nil, si=enemies_no, disp=yes, beh=unit_target+ignore_backswing) is cast ONL..." },
    ["modifier_ringmaster_wheel"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="post_apply", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="Wheel of Wonder (ringmaster_wheel, KV dt=magical, si=enemies_no, disp=no, beh=point+aoe): point-cast wheel rolls to a location then leaves a persis..." },
    ["modifier_ringmaster_wheel_debuff"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="post_apply", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="Wheel of Wonder (ringmaster_wheel, KV dt=magical, si=enemies_no, disp=no, beh=point+aoe): point-cast wheel rolls to a location then leaves a persis..." },  -- 2026-07-28: VPK-verified alias (_debuff = the VICTIM-side name); bare key absent from all 664 paks
    ["modifier_rubick_fade_bolt_debuff"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="damage", timing="post_apply", severity="survivable",
        note="Fade Bolt (rubick_fade_bolt, KV dt=magical, si=enemies_no, disp=yes=basic, beh=unit_target): unit-targeted projectile that bounces between enemies,..." },
    ["modifier_rubick_telekinesis_stun"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="strong", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="lethal",
        note="Telekinesis (rubick_telekinesis, KV dt=nil=none, si=enemies_no -> does NOT pierce, disp=yes_strong, beh=ignore_backswing+unit_target): instant unit..." },
    ["modifier_sand_king_epicenter"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="post_apply", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="Epicenter (sandking_epicenter, KV dt=magical, si=enemies_no, disp=no, beh=no_target+ignore_backswing): no-target self-centered persistent pulsing A..." },
    ["modifier_sandking_burrowstrike"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="lethal",
        note="Burrowstrike (sandking_burrowstrike, KV dt=magical, si=enemies_no -> does NOT pierce, disp=yes_strong, beh=point+root_disables+alt_castable): point..." },
    ["modifier_shadow_demon_demonic_purge"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="lethal",
        note="CONFLICT: KV modifier disp=no (debuff not self-dispellable) while some guides note Demonic Purge applies a basic dispel and the slow is dispellable..." },
    ["modifier_shadow_demon_disruption"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="Disruption (shadow_demon_disruption, KV dt=nil=none, si=enemies_no -> does NOT pierce, disp=no, beh=unit_target+dont_resume_attack): instant unit-t..." },
    ["modifier_shredder_chakram"] = { school="pure", damage_type="pure", pierces_spell_immunity=false, dispellable="none", delivery="projectile_line", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="Pure damage (KV dt=pure) -> no magic_immune, no magic_barrier (decoupled magical branches do not fire). Not dispellable (disp=no) -> no dispel. Poi..." },
    ["modifier_shredder_chakram_debuff"] = { school="pure", damage_type="pure", pierces_spell_immunity=false, dispellable="none", delivery="projectile_line", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="Pure damage (KV dt=pure) -> no magic_immune, no magic_barrier (decoupled magical branches do not fire). Not dispellable (disp=no) -> no dispel. Poi..." },  -- 2026-07-28: VPK-verified alias (_debuff = the VICTIM-side name); bare key absent from all 664 paks
    ["modifier_silencer_last_word"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="Unit-targeted magical disable (silence) with token damage -> primary_harm=disable, so magic_barrier correctly suppressed (gated on primary_harm==da..." },
    ["modifier_skeleton_king_reincarnate_slow"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="No-damage movement/attack slow -> school=magical (BKB blocks per enemies_no, like other no-damage magical disables), damage_type=none (so no magic_..." },
    ["modifier_skeleton_king_reincarnation_spawn_skeletons"] = { school="none", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: empty-ab: KV ab field was empty (not auto-mapped). Resolved via skeleton_king_reincarnation (id 5089) shard_skeleton_count; this modifier..." },
    ["modifier_skywrath_mage_ancient_seal"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable", add_kinds={"dispel_basic", "dispel_strong"},
        note="No-damage unit-targeted silence/magic-amp -> school=magical, damage_type=none (so no magic_barrier, correctly). magic_immune (school=magical + deli..." },
    ["modifier_skywrath_mage_concussive_shot_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_homing", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable", drop_kinds={"displacement_blink"},
        note="Homing projectile that re-acquires -> delivery=projectile_homing, no_target -> targeted=false (not Lotus-reflectable). Modifier is the slow debuff ..." },
    ["modifier_skywrath_mage_mystic_flare_thinker"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="lethal",
        note="Placed persistent magical-damage AoE zone -> positional=true, targeted=false, delivery=spell, primary_harm=damage. Zone duration 2s < 2.5s cyclone ..." },
    ["modifier_skywrath_mystic_flare_aura_effect"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="lethal",
        note="Same Mystic Flare zone as the thinker modifier (identical KV: magical, enemies_no, point+aoe). Persistent magical-damage zone -> positional=true, t..." },
    ["modifier_slardar_amplify_damage"] = { school="magical", damage_type="none", pierces_spell_immunity=true, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="CONFLICT: none. KV dt=nil/si=enemies_yes/disp=yes matches Liquipedia (no-damage debuff, pierces immunity, basic dispel). | No-damage magical disabl..." },
    ["modifier_slardar_slithereen_crush"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", primary_harm="disable", timing="at_impact", severity="survivable",
        note="CONFLICT: none. KV dt=physical/si=enemies_no/disp=yes_strong matches Liquipedia (physical self-AoE stun, no pierce, strong dispel). | Instant no-ta..." },
    ["modifier_snapfire_lil_shredder_debuff"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="none", delivery="attack", primary_harm="disable", timing="reactive", enemy_self_buff=true, attack_enabler=true, severity="survivable",
        note="CONFLICT: none. KV dt=physical/si=nil/disp=nil matches Liquipedia (physical attack-driven, no pierce, non-dispellable armor-shred). si=nil treated ..." },
    ["modifier_snapfire_magma_burn_slow"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="post_apply", zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none for this modifier. KV (the slow component) dt=nil/si=nil/disp=nil => damage_type=none, pierces=false (si=nil=>enemies_no), dispellab..." },
    ["modifier_snapfire_mortimer_kisses"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="damage", timing="at_impact", zone_outlasts_cyclone=true, severity="lethal",
        note="CONFLICT: none. KV dt=magical/si=enemies_no/disp=yes matches Liquipedia (magical AoE bombardment, no pierce, basic dispel). | Repositionable area b..." },
    ["modifier_snapfire_scatterblast_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_line", primary_harm="damage", timing="at_impact", severity="survivable",
        note="CONFLICT: none. KV dt=magical/si=enemies_no/disp=yes matches Liquipedia (magical cone nuke+slow, no pierce, basic dispel). | Directional cone/line ..." },
    ["modifier_sniper_assassinate"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="lethal",
        note="CONFLICT: Liquipedia notes 'Pierces Debuff Immunity conditionally', but KV si=enemies_no is authoritative => pierces_spell_immunity=false (base Ass..." },
    ["modifier_spectre_spectral_dagger"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_line", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none. KV dt=magical/si=nil/disp=yes matches Liquipedia (magical damage+slow, no pierce since si=nil=>enemies_no, basic dispel). lotus_ref..." },
    ["modifier_spectre_spectral_dagger_in_path"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="post_apply", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none. KV (ability spectre_spectral_dagger): damage_type=magical, no spell_immunity field (default no-pierce), dispellable=yes(basic). Mat..." },
    ["modifier_spirit_breaker_nether_strike"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="strong", delivery="leap", targeted=true, primary_harm="disable", timing="pre_cast", severity="lethal",
        note="CONFLICT: none. KV (spirit_breaker_nether_strike): damage_type=magical, spell_immunity=enemies_yes (pierces), dispellable=yes_strong (strong). Used..." },
    ["modifier_templar_assassin_psionic_trap"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", positional=true, primary_harm="disable", timing="post_apply", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none. KV (templar_assassin_psionic_trap): damage_type=magical, spell_immunity=enemies_no (no-pierce), dispellable=yes(basic). Matches Liq..." },
    ["modifier_tinker_laser"] = { school="pure", damage_type="pure", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="damage", timing="pre_cast", severity="survivable",
        note="CONFLICT: none. KV (tinker_laser): damage_type=pure, spell_immunity=enemies_no (no-pierce), dispellable=yes(basic). Matches Liquipedia (pure + refl..." },
    ["modifier_tiny_avalanche"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="lethal",
        note="CONFLICT: none on consumed fields. KV (tiny_avalanche): damage_type=magical, spell_immunity=enemies_no, dispellable=yes_strong. dispellable=strong ..." },
    ["modifier_tiny_avalanche_stun"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="strong", delivery="spell", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: KV-vs-Liquipedia FLAG: KV dispellable=yes_strong but Liquipedia states the avalanche stun is 'only dispellable by Death' (no strong dispe..." },
    ["modifier_tiny_toss"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="displacement", timing="pre_cast", lotus_reflectable=false, severity="lethal", add_kinds={"magic_barrier"},
        note="CONFLICT: none on consumed fields. KV (tiny_toss): damage_type=magical, no spell_immunity field on ability (default no-pierce; Liquipedia 'pierces ..." },
    ["modifier_troll_warlord_whirling_axes_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="projectile_line", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none. KV (troll_warlord_whirling_axes_ranged): damage_type=magical, spell_immunity=enemies_no (no-pierce), dispellable=yes(basic). Matche..." },
    ["modifier_tusk_snowball_target"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="homing_charge", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="Snowball is a homing charge (Tusk rolls TO the unit-targeted enemy and stops). KV: magical, enemies_no (does NOT pierce) => BKB blocks the stun (ma..." },
    ["modifier_tusk_tag_team_attack_slow"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Tag Team's attack-speed slow is a low-impact, non-dispellable physical debuff applied by a no-target aura. KV: physical, enemies_no, dispellable=no..." },
    ["modifier_tusk_tag_team_slow"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Same family as the attack_slow: a brief (0.5s) non-dispellable physical movement slow from a no-target aura. KV: physical, enemies_no, dispellable=..." },
    ["modifier_tusk_walrus_punch_air_time"] = { school="physical", damage_type="none", pierces_spell_immunity=true, dispellable="basic", delivery="attack", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable", drop_kinds={"physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp"},
        note="KV: spell_immunity=enemies_yes => Walrus Punch air time PIERCES spell immunity, so BKB does NOT save (pierces=true blocks magic_immune, and damage_..." },
    ["modifier_tusk_walrus_punch_slow"] = { school="physical", damage_type="none", pierces_spell_immunity=true, dispellable="basic", delivery="attack", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable", drop_kinds={"physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp"},
        note="Walrus Punch slow component, same mechanics as the air_time modifier. KV: enemies_yes => PIERCES BKB (no magic_immune; damage_type=nil=>none so no ..." },
    ["modifier_undying_decay"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="KV: magical, enemies_no (does NOT pierce), dispellable=no. Instant point-target AoE => delivery=spell, targeted=false (AoE, not a single-unit refle..." },
    ["modifier_undying_decay_debuff"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="KV: magical, enemies_no (does NOT pierce), dispellable=no. Instant point-target AoE => delivery=spell, targeted=false (AoE, not a single-unit refle..." },  -- 2026-07-28: VPK-verified alias (_debuff = the VICTIM-side name); bare key absent from all 664 paks
    ["modifier_vengefulspirit_nether_swap"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="basic", delivery="spell", targeted=true, primary_harm="displacement", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="KV: magical, enemies_yes => PIERCES BKB, dispellable=yes=>basic. The dominant threat is the forced position swap (being teleported into the enemy t..." },
    ["modifier_vengefulspirit_retribution_tracker"] = { school="none", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="Retribution is an innate passive (behavior passive+not_learnable+innate_ui), not a real-time cast you defend against. KV: damage_type=nil=>none, sp..." },
    ["modifier_venomancer_venomous_gale"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="damage", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_no/yes(basic) matches Liquipedia. | Survivable magical DoT+slow. Modeled at the applied-debuff layer (delivery=..." },
    ["modifier_viper_corrosive_skin_slow"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_no/yes(basic) matches. damage_type=none used because this specific modifier is the attack-speed slow (the damag..." },
    ["modifier_viper_nethertoxin"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="damage", timing="at_impact", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_no/nil(none)/point+aoe matches. dispellable=none (KV nil) so no dispel offered. | Placed persistent magical-DoT..." },
    ["modifier_viper_nethertoxin_mute"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="none", delivery="spell", positional=true, primary_harm="disable", timing="at_impact", lotus_reflectable=false, zone_outlasts_cyclone=true, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_no/nil(none) matches. damage_type=none because this modifier is the no-damage mute/break component. | No-damage..." },
    ["modifier_viper_poison_attack_slow"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="disable", timing="post_apply", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_no/yes(basic) matches. Modeled at debuff layer (delivery=spell) rather than delivery=attack: the threat is the ..." },
    ["modifier_visage_grave_chill"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="CONFLICT: none - KV nil(damage_type=none)/enemies_no/yes(basic)/unit_target matches. dt=nil => school=magical (it is a magical spell) with damage_t..." },
    ["modifier_visage_grave_chill_debuff"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="basic", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="CONFLICT: none - KV nil(damage_type=none)/enemies_no/yes(basic)/unit_target matches. dt=nil => school=magical (it is a magical spell) with damage_t..." },  -- 2026-07-28: VPK-verified alias (_debuff = the VICTIM-side name); bare key absent from all 664 paks
    ["modifier_void_spirit_aether_remnant"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="displacement", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_no/yes(basic)/vector_targeting matches. pierces=false (the harmful pull does not pierce; only the True-Sight se..." },
    ["modifier_void_spirit_aether_remnant_pull"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="basic", delivery="spell", primary_harm="displacement", timing="pre_cast", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_no/yes(basic)/vector_targeting matches. pierces=false (the harmful pull does not pierce; only the True-Sight se..." },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks
    ["modifier_void_spirit_astral_step"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="none", delivery="spell", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_YES(pierces)/nil(none) matches. si=enemies_yes => pierces_spell_immunity=true, so magic_immune correctly does N..." },
    ["modifier_void_spirit_astral_step_debuff"] = { school="magical", damage_type="magical", pierces_spell_immunity=true, dispellable="none", delivery="spell", primary_harm="damage", timing="at_impact", lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none - KV magical/enemies_YES(pierces)/nil(none) matches. si=enemies_yes => pierces_spell_immunity=true, so magic_immune correctly does N..." },  -- 2026-07-28: VPK-verified alias (_debuff = the VICTIM-side name); bare key absent from all 664 paks
    ["modifier_weaver_swarm_debuff"] = { school="physical", damage_type="physical", pierces_spell_immunity=false, dispellable="none", delivery="projectile_line", primary_harm="damage", timing="at_impact", debuff_sticks_to_self=true, lotus_reflectable=false, severity="survivable", drop_kinds={"invuln", "displacement_perp", "displacement_far", "displacement_blink"},
        note="CONFLICT: none. KV physical / enemies_no / disp=no all consistent with Liquipedia (physical, no BKB pierce, undispellable). beh point+ignore_backsw..." },
    ["modifier_windrunner_shackleshot"] = { school="magical", damage_type="none", pierces_spell_immunity=false, dispellable="strong", delivery="projectile_homing", primary_harm="disable", timing="at_impact", lotus_reflectable=false, severity="survivable", add_kinds={"invuln", "dispel_strong"},
        note="CONFLICT: none. KV dt=nil (damage_type=none, no-damage magical disable => school=magical), enemies_no=>pierces false, disp=yes_strong=>strong, beha..." },
    ["modifier_winter_wyvern_winters_curse"] = { school="magical", damage_type="none", pierces_spell_immunity=true, dispellable="none", delivery="spell", targeted=true, primary_harm="disable", timing="pre_cast", severity="survivable",
        note="CONFLICT: none. KV dt=nil (no-damage => damage_type=none, school=magical), enemies_yes=>pierces true (Liquipedia 'pierces debuff immunity condition..." },
    ["modifier_witch_doctor_maledict"] = { school="magical", damage_type="magical", pierces_spell_immunity=false, dispellable="none", delivery="spell", primary_harm="damage", timing="post_apply", debuff_sticks_to_self=true, lotus_reflectable=false, severity="survivable",
        note="CONFLICT: none. KV magical / enemies_no / disp=no / behavior aoe+point all match Liquipedia (magical damage, no BKB pierce, undispellable, AoE cast..." },
}

----------------------------------------------------------------------------
-- SAVE_PUSH_DISTANCE - how far each displacement save moves the user
----------------------------------------------------------------------------

---Save key → push distance in units. Non-displacement saves omitted
---(treated as 0 and not constrained by tether geometry).
---@type table<string, number>
-- Pike-on-enemy push = 425. Pike pushes radially outward from caster - both
-- caster and enemy move apart. Pike-on-self push = 600 but direction =
-- Sniper's facing (often toward threat). The brain prefers Pike-on-enemy
-- whenever the enemy is in 425u cast range; otherwise falls back to
-- Pike-on-self. The conservative value used here is the enemy-target mode
-- (enemy_push) since that's the reliable-direction case for tether breaks.
-- v6.15.208 (KV-derivation): the item entries derive from
-- item_data.SAVE_GEOMETRY (the generated table item_data's docstring
-- designates as the grounding source for SAVE_PUSH_DISTANCE) - displacement
-- items take enemy_push, blink items take range. The literal in each sg()
-- call is a patch-stable fallback only. grenade_self stays literal: it is a
-- Sniper ability (npc_abilities KV), not an item, so SAVE_GEOMETRY has no
-- entry for it.
ThreatData.SAVE_PUSH_DISTANCE = {
    item_hurricane_pike     = sg("item_hurricane_pike",     "enemy_push", 425),
    item_force_staff        = sg("item_force_staff",        "enemy_push", 600),
    grenade_self            = 475,
    -- Blink variants: instant teleport. Always breaks any tether.
    item_blink              = sg("item_blink",              "range", 1200),
    item_swift_blink        = sg("item_swift_blink",        "range", 1200),
    item_arcane_blink       = sg("item_arcane_blink",       "range", 1400),
    item_overwhelming_blink = sg("item_overwhelming_blink", "range", 1200),
}

----------------------------------------------------------------------------
-- THREAT_TETHER_RANGE - distance at which a tether channel breaks
----------------------------------------------------------------------------

---Threat modifier → tether range in units. Sniper-to-caster distance plus
---displacement push must exceed this for the displacement save to actually
---break the channel. Threats without listed ranges are unconstrained.
---@type table<string, number>
-- v6.7 (2026-05-11): cross-checked against Liquipedia 7.41C.
-- Static Link 900 → 800, Mana Drain 850 → 1000, Death Ward 1100 → 650.
-- Death Ward "tether" was way off - actual ward attack range is 650 at
-- level 3 (was using a fictional 1100). Old value caused over-saves where
-- the brain thought Death Ward reached farther than it does.
-- Shaman Shackles 800 is a HEURISTIC - Liquipedia documents no actual
-- distance-break for Shackles (channel only breaks via stun/silence/
-- disjoint). Kept for the displacement save's geometry score but flagged.
-- Bane Fiend Grip 875 is unverified by Liquipedia text (cast range 625;
-- typical Dota tether allows ~200 buffer). Keep 875 pending in-game verify.
ThreatData.THREAT_TETHER_RANGE = {
    modifier_bane_fiends_grip          = 875,
    modifier_pudge_dismember_pull           = 200,
    modifier_shadow_shaman_shackles    = 800,    -- HEURISTIC; no real distance-break (verify in-game)
    modifier_razor_static_link_debuff         = 800,
    modifier_lion_mana_drain           = 1000,
    modifier_witch_doctor_death_ward   = 650,    -- ward attack range at level 3
    modifier_pugna_life_drain          = 1100,   -- v6.7 vpk: typical channel tether
}

----------------------------------------------------------------------------
-- THREATS_ON_SELF - modifier names hero scripts react to via OnModifierCreate
----------------------------------------------------------------------------

---Modifier → { role, save } metadata. `role` drives the dispatch path in the
---hero script; `save` is human-readable shorthand for diagnostics. Hero scripts
---will typically also pass the modifier name through to the save chain as the
---threat-mod filter input.
---@type table<string, { role:string, save:string }>
ThreatData.THREATS_ON_SELF = {
    modifier_bane_nightmare              = { role = "hard_disable",  save = "eul_or_bkb" },
    modifier_lion_voodoo                 = { role = "hard_disable",  save = "pre_arm" },
    -- v6.15.262: Lion Mana Drain (channel modifier on Sniper). Catalog gap
    -- caught by v6.15.261 demo log: anim_channel_start fires correctly but
    -- OnModifierCreate skips because THREATS_ON_SELF lookup returns nil ->
    -- threat_unrecognized event, no save dispatched. At 1000u tether range,
    -- Lion can drain Sniper from outside grenade_at_caster's 600u cast
    -- range, so Layer 1.5 grenade-on-source also fails -- the reactive
    -- self-save chain is the only one that fires. Force-self (600u) and
    -- pike-self (425u) push Sniper toward the tether-break radius;
    -- grenade-self is the 475u-push fallback.
    modifier_lion_mana_drain             = { role = "drain",         save = "force_or_pike" },
    modifier_shadow_shaman_shackles      = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_pudge_dismember_pull             = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_bane_fiends_grip            = { role = "channel_on_me", save = "bkb_or_grenade_source" },
    modifier_doom_bringer_doom           = { role = "hard_disable",  save = "bkb_or_lotus" },
    modifier_razor_static_link_debuff           = { role = "drain",         save = "force_or_pike" },
    modifier_ursa_overpower              = { role = "physical_burst",save = "glimmer_or_pike" },
    modifier_legion_commander_duel       = { role = "lockdown",      save = "satanic_or_grenade_self" },
    -- Naga Ensnare: physical root, BKB-piercing. Modifier name verified via
    -- VPK binary-grep on pak01_009.vpk (2026-06-01, per lesson 13). All sibling
    -- tables already cataloged the modifier (ABILITY_TO_THREAT, RECOMMENDED_SAVES,
    -- THREAT_TIMING pre_cast, CATEGORY_OVERRIDES targeted_disable, SeverityOf
    -- medium, COUNTER_LAYERS invuln+dispel_basic+reflect_target). THREATS_ON_SELF
    -- was the missing entry: surfaced via v0.5.23 A3b Lina demo as
    -- `threat_unrecognized | mod=modifier_naga_siren_ensnare`. Role=lockdown
    -- matches LC Duel (also BKB-piercing physical). Counters: cyclone-airborne
    -- (Eul/WW phase out of root), basic dispel (Manta/Disperser), Lotus reflect.
    modifier_naga_siren_ensnare          = { role = "lockdown",      save = "manta_or_eul" },
    modifier_axe_berserkers_call         = { role = "taunt",         save = "informational" },
    modifier_phantom_assassin_phantom_strike_target = { role = "gap_close", save = "glimmer_or_pike" },
    modifier_spirit_breaker_charge_of_darkness      = { role = "gap_close", save = "pike_or_grenade" },
    modifier_tusk_snowball_movement                 = { role = "gap_close", save = "pike_or_grenade" },
    modifier_kez_grappling_claw_slow                     = { role = "gap_close", save = "pike_or_grenade" },  -- v6.15.162 vpk - Kez Grappling Claw
    -- v6.15.163 batch 1 - modern hero pool (verify modifier names via modseen)
    modifier_ringmaster_impalement                  = { role = "line_projectile", save = "perp_displacement" },
    modifier_marci_grapple                          = { role = "gap_close",       save = "pike_or_grenade" },
    modifier_muerta_dead_shot                       = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_primal_beast_onslaught                 = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_dawnbreaker_celestial_hammer           = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_hoodwink_bushwhack                     = { role = "delayed_aoe",      save = "displacement" },
    modifier_snapfire_mortimer_kisses               = { role = "delayed_aoe",      save = "displacement" },
    modifier_void_spirit_aether_remnant             = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_mars_spear                             = { role = "line_projectile",  save = "perp_displacement" },
    modifier_grimstroke_ink_creature                = { role = "hard_disable",     save = "dispel_or_bkb" },
    modifier_pangolier_swashbuckle                  = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_dark_willow_cursed_crown               = { role = "hard_disable",     save = "eul_or_bkb" },
    -- v6.15.164 batch 2 - older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere_freeze             = { role = "delayed_aoe",      save = "blink_or_bkb" },
    modifier_batrider_flaming_lasso                 = { role = "hard_disable",     save = "bkb_or_eul" },
    modifier_tiny_toss                              = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_vengefulspirit_nether_swap             = { role = "hard_disable",     save = "bkb_or_eul" },
    modifier_chaos_knight_reality_rift              = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_rattletrap_hookshot                    = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_rattletrap_cog_marker                  = { role = "trap",             save = "displace_or_airborne" },  -- v0.5.147.x Power Cogs trap marker (PRIMARY victim landing; demo-confirmed) -- WW/Eul eat time, Force/Pike push out
    modifier_rattletrap_cog_push                    = { role = "trap",             save = "displace_or_airborne" },  -- v0.5.147.x cog contact knockback (sibling; lands if Lina walks into a cog)
    modifier_techies_land_mine_burn                 = { role = "nuke",             save = "bkb_or_none" },           -- v0.5.149 coverage: mine burst (reactive-only; invisible mines, no pre-empt)
    modifier_techies_sticky_bomb_slow               = { role = "nuke",             save = "dispel_or_bkb" },         -- v0.5.149 coverage: attached bomb slow + magical nuke
    modifier_techies_suicide_leap                   = { role = "gap_close",        save = "force_or_pike" },        -- v0.5.149 Blast Off! leap (combo trigger); armed pre-impact via THREAT_ARRIVAL_TIMING -> composed close_gap
    modifier_techies_mutually_assured_destruction   = { role = "nuke",             save = "bkb_or_none" },          -- v0.5.149 M.A.D. innate magical nuke (1.5s delay); low chip, BKB-only
    modifier_techies_minefield_sign_scepter_aura    = { role = "trap",             save = "blink_or_bkb" },         -- v0.5.149 Minefield Sign (Aghs aura, 1000r, 300 magical per 200u moved); escape = WW/blink/BKB only (zone outlasts cyclone; 600u Force/Pike cannot clear 1000r)
    modifier_spirit_breaker_nether_strike           = { role = "gap_close",        save = "bkb_or_pike" },
    modifier_huskar_life_break_charge                      = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_sandking_burrowstrike                  = { role = "line_projectile",  save = "perp_displacement" },
    modifier_nyx_assassin_impale                    = { role = "line_projectile",  save = "perp_displacement" },
    -- batch 3-4 (defense catalog refresh, 2026-05-17)
    modifier_necrolyte_reapers_scythe               = { role = "magic_burst",      save = "bkb_or_lotus", breaks_channel = true },  -- E3c sweep: targeted ult, 1.5s stun
    modifier_obsidian_destroyer_sanity_eclipse      = { role = "magic_burst",      save = "bkb_or_lotus" },
    modifier_lich_chain_frost                       = { role = "magic_burst",      save = "bkb_or_lotus" },
    modifier_skywrath_mystic_flare_aura_effect             = { role = "delayed_aoe",      save = "displacement" },
    modifier_mars_gods_rebuke                       = { role = "physical_burst",   save = "glimmer_or_ghost", breaks_channel = true },  -- E3c sweep: KV 0.3s knockback
    modifier_snapfire_scatterblast_slow                  = { role = "magic_burst",      save = "bkb_or_displacement" },
    modifier_bloodseeker_rupture                    = { role = "magic_burst",      save = "dispel" },
    modifier_obsidian_destroyer_astral_imprisonment = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_skywrath_mage_ancient_seal             = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_chaos_knight_chaos_bolt                = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_beastmaster_primal_roar                = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_shadow_demon_disruption                = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_shadow_demon_demonic_purge             = { role = "hard_disable",     save = "bkb_or_eul" },
    modifier_winter_wyvern_winters_curse            = { role = "hard_disable",     save = "bkb_or_eul" },
    modifier_enigma_malefice                        = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_windrunner_shackleshot                 = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_morphling_adaptive_strike_agi          = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_puck_waning_rift                       = { role = "hard_disable",     save = "eul_or_bkb" },
    modifier_lich_sinister_gaze                     = { role = "channel_on_me",    save = "bkb_or_grenade" },
    modifier_primal_beast_pulverize                 = { role = "channel_on_me",    save = "bkb_or_grenade" },
    modifier_grimstroke_soul_chain                  = { role = "channel_on_me",    save = "bkb_or_eul" },
    -- E3c (Tinker run-77, user-sighted: Lina broke Rearm with LSA repeatedly): the
    -- catalog was built from Lina's OWN perspective, so her kit never got
    -- THREATS_ON_SELF entries - a blind spot for every OTHER hero brain. Profile +
    -- ABILITY_TO_THREAT existed; this completes the triple. Landed stun arrives as
    -- generic modifier_stunned (harvested), so this entry serves the CHANNEL GATE
    -- (kit-awareness) + pre-impact recognition, not the reactive path.
    modifier_lina_light_strike_array                = { role = "delayed_aoe",      save = "displacement", breaks_channel = true },

    -- E3c COVERAGE SWEEP (2026-07-14, tools/gen_channel_breaker_audit.py over the
    -- KV: 50 kit abilities carried stun/ministun/knockback evidence invisible to
    -- the channel gate). Tier-1 additions: unambiguous ACTIVE cast stuns and
    -- knockbacks. Victim-side mod names follow the modifier_<ability> convention
    -- and are UNVERIFIED unless noted - they serve the GATE (kit walk); if the
    -- real landed mod differs, the harvest log names it for fixup. DELIBERATE
    -- SKIPS (documented in the audit tool + bridge): gap_close role class
    -- (onslaught/charge/gyroshell/snowball/suicide - E1 design exclusion),
    -- anywhere-landing ults (solar_guardian, gyro missile), situational triggers
    -- (nyx carapace, hoodwink decoy, phoenix egg, spark wraith zones), passives/
    -- summon procs (greater bash, repulsion, lycan wolves), facet/marginal
    -- (glacier 0.1s, meepo fling, muerta slug, horn toss), line skillshots kept
    -- on the armed-threat path (mars spear, rolling boulder).
    modifier_centaur_hoof_stomp                     = { role = "hard_disable", breaks_channel = true },  -- E3c sweep: KV stun 1.6-2.2s aoe
    modifier_earthshaker_fissure                    = { role = "hard_disable", breaks_channel = true },  -- E3c sweep: KV stun 1.0-1.6s line (instant, not dodgeable while channeling)
    modifier_monkey_king_boundless_strike           = { role = "hard_disable", breaks_channel = true },
    modifier_monkey_king_boundless_strike_stun           = { role = "hard_disable", breaks_channel = true },  -- 2026-07-28: VPK-verified alias, the bare key above does not exist in any of the 664 paks  -- E3c sweep: KV stun 0.7-1.3s line
    modifier_skeleton_king_hellfire_blast           = { role = "hard_disable", breaks_channel = true },  -- E3c sweep: KV stun 1.0-1.6s targeted (WK)
    modifier_snapfire_firesnap_cookie               = { role = "hard_disable", breaks_channel = true },  -- E3c sweep: KV impact stun 1.0-2.2s
    modifier_primal_beast_rock_throw                = { role = "hard_disable", breaks_channel = true },  -- E3c sweep: KV stun 1.4s
    modifier_kunkka_ghostship                       = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV stun 1.2s at impact
    modifier_antimage_mana_void                     = { role = "magic_burst", breaks_channel = true },  -- E3c sweep: KV ministun 0.3s targeted ult
    modifier_luna_lucent_beam                       = { role = "magic_burst", breaks_channel = true },  -- E3c sweep: KV stun 0.6s targeted (verify: may be facet/ult-gated)
    modifier_invoker_deafening_blast                = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV knockback 1.1-2.1s (knockbacks interrupt)
    modifier_queenofpain_sonic_wave                 = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV knockback 1.4s cone ult
    modifier_drow_ranger_wave_of_silence            = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV knockback 0.6-0.9s
    modifier_huskar_inner_fire                      = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV knockback 1.0s radial
    modifier_batrider_flamebreak                    = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV stun 0.5s + knockback 0.35s
    modifier_bounty_hunter_wind_walk                = { role = "hard_disable", breaks_channel = true },  -- E3c sweep: KV invis-strike stun 1.0-1.6s (fogged-disc covers the invis; melee floor range)
    modifier_warlock_rain_of_chaos                  = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV stun 0.8s at golem landing
    modifier_dawnbreaker_fire_wreath                = { role = "hard_disable", breaks_channel = true },  -- E3c sweep: KV smash stun 0.6-1.2s melee arc
    modifier_visage_stone_form_self_cast            = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV stun 0.8-1.2s radial on landing
    modifier_elder_titan_echo_stomp                 = { role = "delayed_aoe", breaks_channel = true },  -- E3c sweep: KV initial stun 0.2s + sleep
    modifier_kez_shodo_sai                          = { role = "hard_disable", breaks_channel = true },  -- E3c sweep: KV stun 0.5-0.8s (verify: new hero, mechanics evolving)
    -- E3c (run-77 harvest x4): Fissure's LANDED victim-side stun is a separate mod
    -- with its OWN profile (severity=lethal at :327) - an alias would shadow that
    -- profile, so it gets its own entry (the recognition + landed-disable flee).
    modifier_earthshaker_fissure_stun               = { role = "hard_disable",     save = "displacement" },
    modifier_puck_dream_coil                        = { role = "delayed_aoe",      save = "displacement", breaks_channel = true },  -- E3c sweep: KV initial 0.5s stun on coil cast
    modifier_leshrac_split_earth                    = { role = "delayed_aoe",      save = "displacement" },
    modifier_jakiro_ice_path                        = { role = "delayed_aoe",      save = "displacement", breaks_channel = true },  -- E3c: 1.25-2s stun (Liquipedia) - breaks Rearm/Keen channels (Tinker run-77)
    modifier_mars_arena_of_blood                    = { role = "delayed_aoe",      save = "blink_or_bkb" },
    modifier_sand_king_epicenter                     = { role = "delayed_aoe",      save = "displacement" },
    modifier_templar_assassin_psionic_trap          = { role = "trapped",          save = "displacement" },
    modifier_naga_siren_song_of_the_siren           = { role = "delayed_aoe",      save = "bkb_or_displacement" },
    modifier_dark_willow_terrorize                  = { role = "delayed_aoe",      save = "displacement" },
    modifier_dark_willow_bramble_maze               = { role = "delayed_aoe",      save = "displacement" },
    modifier_ringmaster_the_box                     = { role = "trapped",          save = "knockback_or_blink" },
    modifier_ringmaster_wheel                       = { role = "delayed_aoe",      save = "displacement", breaks_channel = true },  -- E3c sweep: KV 0.35s knockback (knockbacks interrupt channels)
    modifier_kez_raptor_dance                       = { role = "delayed_aoe",      save = "displacement" },
    modifier_void_spirit_astral_step                = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_pangolier_gyroshell                    = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_nyx_assassin_vendetta                  = { role = "gap_close",        save = "pike_or_grenade" },
    modifier_slark_pounce                = { role = "gap_close", save = "force_or_pike" },
    -- v6.15.258 zero-coverage fill batch 1: single-target stuns / silences
    -- from heroes Sniper actually faces. All modifier names are vpk --
    -- guessed from KV ability names; demos will confirm via threat_unrecognized.
    modifier_dragon_knight_dragon_tail   = { role = "hard_disable",  save = "eul_or_bkb" },         -- (verify) - 0.45 cast, 1.7-2.75s stun
    modifier_night_stalker_void          = { role = "hard_disable",  save = "eul_or_bkb" },         -- vpk - 0.3 cast, mini-stun + slow (full stun at night)
    modifier_ogre_magi_fireblast         = { role = "hard_disable",  save = "eul_or_bkb" },         -- vpk - 0.45 cast, 1.5-2.4s stun
    modifier_rubick_telekinesis_stun          = { role = "hard_disable",  save = "eul_or_bkb" },         -- vpk - 0.1 cast, lift+land stun
    modifier_silencer_last_word          = { role = "silence_on_me", save = "bkb_or_dispel" },      -- vpk - silence on cast / 4s timer
    modifier_death_prophet_silence       = { role = "silence_on_me", save = "bkb_or_dispel" },      -- vpk - point-AOE 5-6s silence
    -- v6.15.263 zero-coverage fill batch 2: AOE delayed killers + single-target
    -- bursts Sniper actually faces. Anim-path detection is primary for abilities
    -- without a Sniper-side modifier (Mana Void, Sunder).
    modifier_cold_feet     = { role = "hard_disable", save = "eul_or_bkb" },        -- vpk - 4s timer, stun if Sniper hasn't moved 715u
    modifier_ice_blast     = { role = "magic_burst",  save = "bkb_or_lotus" },      -- vpk - frost mark, executes <12% HP. BKB blocks (SPELL_IMMUNITY_ENEMIES_YES)
    modifier_gyrocopter_homing_missile        = { role = "line_projectile", save = "perp_displacement" },  -- vpk - homing target debuff, missile is dodgeable
    modifier_gyrocopter_call_down_slow        = { role = "kiting_slow",  save = "informational" },     -- vpk - per-rocket slow proc
    modifier_kunkka_torrent_thinker           = { role = "delayed_aoe",  save = "displacement", breaks_channel = true },      -- (verify) - geyser warning placed, hits ~1.5s later  -- E3c sweep: KV stun 1.4s at splash (delay 1.6 < the 2.7-2.93s channels)
    modifier_kunkka_torrent_stun              = { role = "hard_disable", save = "eul_or_bkb" },        -- (verify) - stun applied at geyser impact
    modifier_kunkka_x_marks_the_spot          = { role = "hard_disable", save = "bkb_or_dispel" },     -- vpk - drag-back debuff, removable by dispel
    modifier_nevermore_requiem                = { role = "magic_burst",  save = "bkb_or_lotus" },      -- vpk - fear + magic damage radial
    -- v6.15.265 zero-coverage fill batch 3: mid-game mixed threats
    modifier_doom_bringer_infernal_blade      = { role = "hard_disable", save = "eul_or_bkb" },        -- vpk - autocast mini-stun + damage on Doom right-clicks
    modifier_furion_sprout                    = { role = "hard_disable", save = "bkb_or_dispel" },     -- vpk - root cage; basic dispel (Manta) removes the trees
    modifier_visage_grave_chill               = { role = "hard_disable", save = "bkb_or_dispel" },     -- vpk - slow + silence steal
    modifier_venomancer_venomous_gale         = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - slow + dot line; dispel removes
    modifier_spectre_spectral_dagger          = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - slow + can-chase-through-walls debuff
    -- v6.15.266 zero-coverage fill batch 4: carry / active threats
    modifier_juggernaut_omni_slash            = { role = "channel_on_me", save = "bkb_or_eul" },       -- (verify) - 4s channel, target locked + massive damage; BKB / Aeon / Manta dispel
    modifier_phantom_lancer_spirit_lance      = { role = "kiting_slow",  save = "informational" },     -- vpk - slow + damage proc, recoverable
    modifier_meepo_earthbind                  = { role = "hard_disable", save = "bkb_or_dispel" },     -- vpk - 2s root delayed AoE, dispel removes
    modifier_monkey_king_wukongs_command_aura = { role = "delayed_aoe",  save = "displacement" },      -- (verify) - cage area, clones attack inside
    modifier_slardar_amplify_damage           = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - armor reduction debuff, dispellable
    modifier_slardar_slithereen_crush         = { role = "hard_disable", save = "eul_or_bkb" },        -- (verify) - AoE stun around Slardar
    modifier_bristleback_viscous_nasal_goo        = { role = "kiting_slow",  save = "informational" },     -- vpk - line of goo slows, recoverable
    -- v6.15.267 zero-coverage fill batch 5: reactive-detectable threats
    modifier_invoker_cold_snap         = { role = "hard_disable", save = "bkb_or_dispel" },     -- vpk - recurring mini-stun on damage; dispel removes
    modifier_riki_smoke_screen                = { role = "silence_on_me", save = "bkb_or_dispel" },    -- vpk - AoE silence + miss chance
    modifier_lone_druid_spirit_bear_entangle_effect       = { role = "hard_disable", save = "bkb_or_dispel" },     -- vpk - bear-attack root proc (1.5s)
    modifier_undying_decay                    = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - STR drain debuff (reduces Sniper max HP)
    modifier_dazzle_poison_touch              = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - slow + delayed stun if not removed
    modifier_weaver_swarm_debuff              = { role = "kiting_slow",  save = "informational" },     -- vpk-confirmed (was modifier_weaver_swarm_debuff); armor/DoT debuff, death-only dispel -> recoverable, no save
    -- v6.15.268 zero-coverage fill batch 6: stuns + snares + nukes
    modifier_alchemist_unstable_concoction    = { role = "hard_disable", save = "eul_or_bkb" },        -- vpk - variable stun (1-4s based on charge), instant when thrown
    modifier_broodmother_sticky_snare         = { role = "hard_disable", save = "bkb_or_dispel" },     -- vpk - 2s root from placed snare; dispellable
    modifier_medusa_gorgon_grasp              = { role = "hard_disable", save = "eul_or_bkb" },        -- vpk - point-AOE stun
    modifier_medusa_mystic_snake              = { role = "kiting_slow",  save = "informational" },     -- vpk - bouncing damage + mana drain, recoverable
    modifier_troll_warlord_whirling_axes_slow = { role = "kiting_slow", save = "informational" }, -- vpk-confirmed (was _ranged); 40% slow + blind, NOT silence -> recoverable
    modifier_dark_seer_vacuum                 = { role = "hard_disable", save = "bkb_or_dispel" },     -- vpk - pulls Sniper to vacuum point; BKB blocks
    modifier_dark_seer_ion_shell              = { role = "kiting_slow",  save = "informational" },     -- vpk - area damage aura around target; doesn't stop kiting
    modifier_ember_spirit_sleight_of_fist_caster = { role = "kiting_slow", save = "informational" }, -- vpk - Ember in untargetable phase; informational
    -- v6.15.269 zero-coverage fill batch 7: remaining mid-impact threats
    modifier_bounty_hunter_shuriken_toss      = { role = "kiting_slow",  save = "informational" },     -- (verify) - slow + damage proc, recoverable
    modifier_brewmaster_cinder_brew           = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - POINT-AOE slow + dot, ignites on damage; dispel removes
    modifier_phoenix_sun_ray                  = { role = "kiting_slow",  save = "informational" },     -- vpk - line beam damage + slow (Phoenix channels)
    modifier_shredder_chakram                 = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - chakram line slow + disarm
    modifier_arc_warden_flux                  = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - damage-when-isolated debuff; dispel breaks the lone-target check
    -- v6.15.270 zero-coverage final mop-up
    modifier_chen_penitence                   = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- vpk - slow + damage amp on Sniper
    modifier_omniknight_hammer_of_purity      = { role = "kiting_slow",  save = "informational" },     -- vpk - autocast purity attack proc, single-target damage
    modifier_largo_catchy_lick                = { role = "kiting_slow",  save = "informational" },     -- vpk - Largo lick debuff, single-target proc
    -- v6.15.271 ranked-match harvest: real modifier names verified from
    -- threat_unrecognized log lines in a 100k-line live match.
    modifier_tusk_snowball_target             = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-24: root + delivery debuff on Sniper after snowball impact
    modifier_tusk_walrus_punch_air_time       = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-24: knockup stun phase (1.6s+)
    modifier_tusk_walrus_punch_slow           = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-24: post-punch slow
    modifier_tusk_tag_team_attack_slow        = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-24: passive proc slow on Tusk attacks
    modifier_tusk_tag_team_slow               = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-24: paired-attack slow
    modifier_tiny_avalanche_stun              = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-24: Avalanche stun (POINT-AOE, 1.5-1.8s)
    -- (Skywrath Mystic Flare: the bare `modifier_skywrath_mage_mystic_flare`
    -- entries throughout this file were renamed to the actual harvested
    -- name `modifier_skywrath_mystic_flare_aura_effect` in v6.15.271. No
    -- new entry needed -- the existing role/timing/category/severity
    -- stay as they were under the new key.)
    modifier_skywrath_mage_concussive_shot_slow = { role = "kiting_slow", save = "informational" },    -- harvested 2026-05-24: Concussive Shot slow proc
    modifier_keeper_of_the_light_blinding_light = { role = "hard_disable", save = "bkb_or_dispel" },   -- harvested 2026-05-24: miss-chance debuff on Sniper (devastating to a right-clicker)
    modifier_blinding_light_knockback         = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-24: knockback marker from Blinding Light
    modifier_keeper_of_the_light_will_o_wisp  = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-24: delayed AoE stun ult
    modifier_keeper_of_the_light_radiant_bind = { role = "hard_disable", save = "bkb_or_dispel" },     -- harvested 2026-05-24: anti-ranged-attack disable via facet -- HIGH PRIORITY for Sniper
    modifier_legion_commander_intimidate_slow = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-24: newer LC ability slow
    -- v6.15.272 second-match harvest: Faceless Void / Largo / Razor / Rubick
    modifier_faceless_void_timelock_freeze    = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: passive proc mini-stun on attack, recoverable
    modifier_faceless_void_time_dilation_distortion = { role = "kiting_slow", save = "bkb_or_dispel" }, -- harvested 2026-05-25: slow + ability CD stall
    modifier_largo_frogstomp_debuff           = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-25: POINT-AOE stomp stun
    modifier_largo_croak_of_genius_debuff     = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: damage/debuff
    modifier_largo_catchy_lick_knockback      = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: knockback marker
    modifier_razor_plasma_field_slow          = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: Plasma Field ring slow
    modifier_razor_storm_surge_slow           = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: ms-trade facet
    modifier_razor_eye_of_the_storm_armor     = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: ult armor reduction
    modifier_rubick_fade_bolt_debuff          = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: damage debuff
    -- v6.15.273 third-match harvest: AA / Magnus / Snapfire / Spectre / WD
    modifier_ancientapparition_coldfeet_freeze = { role = "hard_disable", save = "bkb_or_dispel" },    -- harvested 2026-05-25: AA Cold Feet freeze phase (hero prefix written ancientapparition with no underscore!)
    modifier_ancient_apparition_bone_chill_debuff = { role = "kiting_slow", save = "bkb_or_dispel" }, -- harvested 2026-05-25: AA Bone Chill stacking slow
    modifier_chilling_touch_slow              = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: AA Chilling Touch attack slow proc (no hero prefix!)
    modifier_chilling_touch_super_slow        = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: AA Chilling Touch upgraded variant
    modifier_ice_vortex                       = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: AA Ice Vortex slow (no hero prefix!)
    modifier_magnataur_skewer_impact          = { role = "hard_disable", save = "eul_or_bkb" },         -- harvested 2026-05-25: Skewer impact stun
    modifier_magnataur_skewer_slow            = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: Skewer post-impact slow
    modifier_magnataur_shockwave_pull         = { role = "hard_disable", save = "bkb_or_dispel" },     -- harvested 2026-05-25: Shockwave pull-back (newer ability?)
    modifier_snapfire_lil_shredder_debuff     = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: Lil' Shredder attack-replacement debuff
    modifier_snapfire_magma_burn_slow         = { role = "kiting_slow",  save = "informational" },     -- harvested 2026-05-25: Magma burn slow proc
    modifier_spectre_spectral_dagger_in_path  = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: Spectre in-path-of-dagger chase marker
    modifier_maledict                         = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: WD Maledict mark (no hero prefix!)
    modifier_maledict_dot                     = { role = "kiting_slow",  save = "bkb_or_dispel" },     -- harvested 2026-05-25: WD Maledict periodic damage tick
    -- v6.7 extrapolation (2026-05-11). Modifier names marked vpk need
    -- in-game confirmation via :FindAllModifiers() print before relying on.
    modifier_shadow_shaman_voodoo        = { role = "hard_disable",  save = "lotus_or_eul" },           -- vpk - Hex
    modifier_zuus_lightning_bolt         = { role = "magic_burst",   save = "bkb_or_lotus", breaks_channel = true },  -- (verify) E3c: 0.35s ministun interrupts channels (Liquipedia; tester-reported vs Tinker)
    modifier_zuus_thundergods_wrath      = { role = "magic_burst",   save = "bkb_or_pipe" },           -- (verify) - global ult, 2s cast point
    modifier_tidehunter_ravage           = { role = "delayed_aoe",   save = "bkb_or_blink" },          -- vpk
    modifier_earthshaker_echo_slam       = { role = "delayed_aoe",   save = "bkb_or_blink" },          -- (verify)
    modifier_magnataur_reverse_polarity_stun  = { role = "delayed_aoe",   save = "bkb_or_blink", breaks_channel = true },          -- vpk - 1700u radius  -- E3c sweep: KV hero stun 2.5-3.5s
    modifier_disruptor_static_storm_thinker = { role = "delayed_aoe", save = "displacement_or_bkb" },  -- vpk - channel
    modifier_treant_overgrowth           = { role = "delayed_aoe",   save = "blink_or_manta" },        -- vpk - AoE root
    modifier_magnataur_skewer            = { role = "line_projectile", save = "perp_displacement" },   -- vpk - pre_cast save
    modifier_sven_storm_bolt             = { role = "line_projectile", save = "perp_displacement", breaks_channel = true },   -- (verify)  -- E3c sweep: targeted (undodgeable) 1.0-1.6s stun
    modifier_earth_spirit_rolling_boulder= { role = "line_projectile", save = "perp_displacement" },   -- vpk
    modifier_life_stealer_open_wounds    = { role = "physical_burst", save = "manta_or_pike" },        -- vpk - debuff
    modifier_pugna_life_drain            = { role = "drain",         save = "force_or_pike" },         -- vpk - channel
    -- v6.15.10: Disruptor Kinetic Field - trapped. Only knockback escapes.
    modifier_disruptor_kinetic_field = { role = "trapped",   save = "knockback_only" },         -- vpk
    -- v6.15.256: Underlord Pit of Malice - same trapped pattern as Kinetic
    -- Field. Snare ticks ~3.6s for 12s; escape via displacement breaks the
    -- root and removes Sniper from the 400u pit area.
    modifier_abyssal_underlord_pit_of_malice_ensare = { role = "trapped",   save = "knockback_only" },         -- vpk
    -- v6.15.198 harvest - modifier names captured from threat_unrecognized
    -- across three bot matches (post v6.15.194 / .195 / .197). All names
    -- below are HARVESTED (observed in real logs), not guessed; remove the
    -- vpk caveat for any entry that's confirmed via repeat hits.
    -- Most are kiting / DOT threats Sniper just tanks (save="informational")
    -- - they exist in the catalog so threat_unrecognized stops re-logging
    -- them and so the brain's score-bonus / save-chain dispatcher knows
    -- the kind. Genuine R-blockers (silence, channel-on-me, dispel) get
    -- a real save mapping.
    modifier_phantom_assassin_stiflingdagger    = { role = "light_slow",       save = "informational" },  -- harvested 2026-05-19: brief slow + minor dmg; Sniper just tanks
    modifier_drow_ranger_frost_arrows_slow      = { role = "kiting_slow",      save = "bkb_or_dispel"  },  -- harvested 2026-05-19: per-auto slow, accumulates while Drow chases
    modifier_oracle_fortunes_end_channel_target = { role = "channel_on_me",    save = "bkb_or_dispel"  },  -- harvested 2026-05-20: 2.6s channel pre-dispel marker
    modifier_oracle_fortunes_end_purge          = { role = "dispel_on_me",     save = "informational"  },  -- harvested 2026-05-20: basic dispel landed (BKB/Pike/Aether already gone)
    modifier_oracle_purifying_flames            = { role = "dot",              save = "informational"  },  -- harvested 2026-05-20: damage then heal-over-time (net minor)
    modifier_skeleton_king_reincarnate_slow     = { role = "aura_slow",        save = "informational"  },  -- harvested 2026-05-20: slow on enemies near WK's revival
    modifier_skeleton_king_reincarnation_spawn_skeletons = { role = "aux",     save = "informational"  },  -- harvested 2026-05-20: spawn marker; the skeletons are a separate threat
    modifier_viper_corrosive_skin_slow          = { role = "attacker_slow",    save = "informational"  },  -- harvested 2026-05-20: slow on Viper's attackers; counter is to stop attacking
    modifier_viper_nethertoxin                  = { role = "zone_dot",         save = "informational"  },  -- harvested 2026-05-20: AoE zone DOT; counter is to leave the zone
    modifier_viper_nethertoxin_mute             = { role = "silence_on_me",    save = "bkb_or_dispel"  },  -- harvested 2026-05-20: silence at full Nethertoxin stacks - REAL R-blocker
    modifier_viper_poison_attack_slow           = { role = "kiting_slow",      save = "bkb_or_dispel"  },  -- harvested 2026-05-20: Viper Q applied via auto, slow + DOT
    modifier_necrolyte_heartstopper_aura_effect = { role = "aura_dot",         save = "informational"  },  -- harvested 2026-05-20: %-max-HP aura DOT; counter is move out of range (~1500u)
    modifier_vengefulspirit_retribution_tracker = { role = "tracker",          save = "informational"  },  -- harvested 2026-05-20: VS shard/talent tracker; no direct threat

    -- 2026-07-27 g356 RUNTIME HARVEST. These are the names the ENGINE reported through
    -- threat_unrecognized in a live match, and two of them DISAGREE with the spellings already
    -- in this table - which means those entries have NEVER MATCHED and the threats were
    -- invisible. Both spellings are kept: a dead key costs nothing, a missing key is a real miss.
    --
    -- DROW. The table carried modifier_drow_ranger_wave_of_silence; the engine (and the VPK)
    -- say modifier_drowranger_wave_of_silence, with the knockback split into its own modifier.
    -- The old entry was role="delayed_aoe" i.e. knockback-only, which UNDERSTATED it badly:
    -- Liquipedia has Gust silencing 3/4/5/6s (knockback 0.4-0.9s), and a 6s silence on Tinker
    -- means no Rearm and no March. Classified as the silence it is, matching death_prophet.
    modifier_drowranger_wave_of_silence           = { role = "silence_on_me", save = "bkb_or_dispel", breaks_channel = true },
    modifier_drowranger_wave_of_silence_knockback = { role = "delayed_aoe",   save = "informational", breaks_channel = true },
    -- DEATH PROPHET. Engine says modifier_deathprophet_silence_debuff. The VPK on disk still
    -- carries only modifier_death_prophet_silence, so the VPK is STALE here and the live name
    -- wins - worth remembering the next time a VPK grep contradicts a real log.
    modifier_deathprophet_silence_debuff          = { role = "silence_on_me", save = "bkb_or_dispel" },
    -- The rest are NOT threats to us. They are classified only so they stop being reported as
    -- unrecognized: Weave is Dazzle's innate armor swing, the arcane bolt lifesteal is a buff on
    -- SKYWRATH rather than a debuff on us, and the degen aura is a small movement-speed slow.
    modifier_omniknight_degen_aura_effect         = { role = "aura_slow",     save = "informational" },
    modifier_dazzle_innate_weave_armor            = { role = "aux",           save = "informational" },
    modifier_dazzle_innate_weave_armor_counter    = { role = "aux",           save = "informational" },
    modifier_skywrath_mage_arcane_bolt_lifesteal  = { role = "aux",           save = "informational" },

    -- 2026-07-28 g357 runtime harvest. Same source of truth as the g356 batch: names the ENGINE
    -- reported through threat_unrecognized. All three are minor - two recoverable slows and a
    -- vision marker - so they are classified only to stop the noise, not because they threaten us.
    -- `modifier_truesight` is worth noting as a specimen of the GENERIC class (no hero prefix at
    -- all), the same family as modifier_stunned / _rooted / _silence that no per-ability rename
    -- can ever reach. See THREAT_DEAD_KEY_AUDIT.txt.
    modifier_lich_frostnova_slow                  = { role = "kiting_slow",  save = "informational" },
    modifier_zuus_static_field_slow               = { role = "kiting_slow",  save = "informational" },
    modifier_truesight                            = { role = "aux",          save = "informational" },

    -- 2026-07-28 demo-2 harvest. Only one of the two matters, and it PROVED THE METHOD:
    -- `modifier_visage_grave_chill_debuff` is handled above as a VPK alias, and this demo caught
    -- the engine emitting exactly that name - the first runtime confirmation that the `_debuff`
    -- suffix is the VICTIM-side marker. The first suffix whitelist omitted `_debuff` and so
    -- rejected Grave Chill (a HARD DISABLE) as unfixable; six more aliases came back once it was
    -- added. Keep `_debuff` in mind before trusting any future suffix filter.
    modifier_beastmaster_axe_stack_counter        = { role = "aux",          save = "informational" },
}

----------------------------------------------------------------------------
-- LOTUS_WORTHY_INCOMING - single-target enemy ults Lotus reflects
----------------------------------------------------------------------------

---@type table<string, boolean>
ThreatData.LOTUS_WORTHY_INCOMING = {
    modifier_lina_laguna_blade    = true,
    modifier_lion_finger_of_death = true,
}

----------------------------------------------------------------------------
-- CAST_POINT_THREATS - pre-cast-armed threats with sub-second windows
----------------------------------------------------------------------------
--
-- v0.5.39 BUG-3: enemy ults / nukes that have a meaningful cast-point window
-- during which the brain should ARM (record the threat and the caster's
-- live cast point) and FIRE the save AT THE END of the cast point (via
-- SAVE_ETA_TRIGGER on the chain head save), NOT immediately on detection.
-- Mirrors the v0.5.6/0.5.7 SAVE_ETA_TRIGGER design used for homing close-gap
-- threats (Bara Charge, Tusk Snowball) but extends it to cast-point ults
-- whose impact lands at end-of-cast-point rather than via flight-time.
--
-- Entry shape:
--   ability      KV-stable ability name (used to resolve the live cast point
--                via Ability.GetCastPoint, and as the reverse-lookup key for
--                anim-path arming - on_hard_disable / on_channel_start).
--   cp_default   fallback cast point (seconds) when Ability.GetCastPoint is
--                unavailable. KV-derivation: matches npc_abilities CastPoint.
--   category     THREAT_CATEGORY-compatible string. Drives the save chain
--                via Dispatcher:ResolveSaveOrder when the brain arms.
--   max_dist     proximity gate (DOTA units). If dist(self, caster) exceeds
--                this at any tick after arming, the entry is GC'd with a
--                cast_point_threat_abort_dist event. Use a large sentinel
--                (e.g. 99999) for global-range threats (Sniper Assassinate,
--                Zeus Thundergod's Wrath, AA Ice Blast).
--
-- Roster v0.5.39 (user-approved):
--   - sniper_assassinate         single-target magical execute, ~2.0s cast
--   - lion_finger_of_death       single-target nuke, 0.6s cast, 600u range
--   - lina_laguna_blade          single-target nuke, 0.45s cast, 750u range.
--                                Hero brains MUST skip self-arming when the
--                                caster is OUR Lina (mirror artifacts).
--   - ancient_apparition_ice_blast frost mark + execute, ~0.5s cast, global
--   - obsidian_destroyer_sanity_eclipse AoE mana-based magic, ~1.7s cast
--   - tinker_laser               single-target stun + nuke, 0.45s cast
--   - zuus_thundergods_wrath     global AoE ult, 0.6s effective windup
--   - doom_bringer_doom          single-target 12s silence. MIGRATED from
--                                LINA_INSTANT_DISABLE_MODS -> CAST_POINT.
--                                Doom's cast is INSTANT in-game (0.5s cast
--                                point but no projectile flight); the brain
--                                now waits ~0.5s before firing BKB/Lotus so
--                                the save lands at modifier-impact time
--                                rather than burning at-cast-start.
--
-- Hero brains pull this table into a module-local upvalue and consult it
-- in OnModifierCreate (catch-all entry) and in their anim subscribers
-- (anim is the primary entry; OnModifierCreate is fallback). The arm-key
-- convention is "castpt:<mod>:<caster_idx>" so concurrent casters of the
-- same ult don't collide.
---@type table<string, { ability:string, cp_default:number, category:string, max_dist:number }>
ThreatData.CAST_POINT_THREATS = {
    modifier_sniper_assassinate                = { ability = "sniper_assassinate",                cp_default = 2.0,  category = "targeted_burst",  max_dist = 99999 },
    modifier_lion_finger_of_death              = { ability = "lion_finger_of_death",              cp_default = 0.6,  category = "targeted_burst",  max_dist = 600   },
    modifier_lina_laguna_blade                 = { ability = "lina_laguna_blade",                 cp_default = 0.45, category = "targeted_burst",  max_dist = 750   },
    modifier_ice_blast                         = { ability = "ancient_apparition_ice_blast",      cp_default = 0.5,  category = "targeted_burst",  max_dist = 99999 },
    modifier_obsidian_destroyer_sanity_eclipse = { ability = "obsidian_destroyer_sanity_eclipse", cp_default = 1.7,  category = "delayed_aoe",     max_dist = 600   },
    modifier_tinker_laser                      = { ability = "tinker_laser",                      cp_default = 0.45, category = "targeted_burst",  max_dist = 550   },
    modifier_zuus_thundergods_wrath            = { ability = "zuus_thundergods_wrath",            cp_default = 0.6,  category = "targeted_burst",  max_dist = 99999 },
    modifier_doom_bringer_doom                 = { ability = "doom_bringer_doom",                 cp_default = 0.5,  category = "targeted_disable", max_dist = 600  },
    modifier_sand_king_epicenter               = { ability = "sandking_epicenter",                cp_default = 2.0,  category = "delayed_aoe",     max_dist = 1900  },
}

----------------------------------------------------------------------------
-- ENEMY_CHANNEL_MODIFIERS - Layer 1.5 channel-punish / TP-interrupt triggers
----------------------------------------------------------------------------

---@type table<string, boolean>
ThreatData.ENEMY_CHANNEL_MODIFIERS = {
    modifier_bane_fiends_grip              = true,
    modifier_pudge_dismember_pull               = true,
    modifier_witch_doctor_death_ward       = true,
    modifier_crystal_maiden_freezing_field = true,
    modifier_enigma_black_hole             = true,
    modifier_teleporting                   = true,  -- TP-out interrupt
    -- v6.7 (verify modifier names):
    modifier_disruptor_static_storm_thinker = true,
    modifier_pugna_life_drain              = true,
}

----------------------------------------------------------------------------
-- WORTHY_CHANNEL_ABILITIES - allowlist for the channel-interrupt bonus
----------------------------------------------------------------------------
-- Keyed by the CHANNELLING ability name (what GetChannellingAbility +
-- Ability.GetName returns on the casting hero), NOT the modifier name -- the
-- channel modifiers above often live on the victim, not the channelling
-- caster. A long-cast nuke ult (Sniper Assassinate, ~2s) is only worth
-- burning to interrupt a channel that will still be active when it lands.
-- This list is the curated set of long, high-value channels worth that
-- trade. A generic channel detector (NPC.GetChannellingAbility) catches
-- EVERY channel, including low-value player-releasable ones (Keeper of the
-- Light Illuminate releases on command and finishes before a 2s cast
-- lands), so the interrupt bonus must gate on this allowlist rather than
-- firing on any channel. A killable channeler still draws the ult via the
-- kill bonus -- this list governs only the interrupt-for-its-own-sake bonus.
---@type table<string, boolean>
ThreatData.WORTHY_CHANNEL_ABILITIES = {
    bane_fiends_grip              = true,
    pudge_dismember               = true,
    witch_doctor_death_ward       = true,
    crystal_maiden_freezing_field = true,
    enigma_black_hole             = true,
    disruptor_static_storm        = true,
    pugna_life_drain              = true,
}

----------------------------------------------------------------------------
-- ABILITY_TO_THREAT - ability name (from anim events) → threat modifier
----------------------------------------------------------------------------

---@type table<string, string|nil>
ThreatData.ABILITY_TO_THREAT = {
    bane_nightmare                      = "modifier_bane_nightmare",
    bane_fiends_grip                    = "modifier_bane_fiends_grip",
    bane_brain_sap                      = nil,   -- instant nuke, no incoming-side save
    pudge_dismember                     = "modifier_pudge_dismember_pull",
    pudge_meat_hook                     = "modifier_pudge_meat_hook",
    spirit_breaker_charge_of_darkness   = "modifier_spirit_breaker_charge_of_darkness",
    spirit_breaker_nether_strike        = "modifier_spirit_breaker_nether_strike",  -- v6.15.164 vpk - promoted from nil: blink-strike ult
    tusk_snowball                       = "modifier_tusk_snowball_movement",
    kez_grappling_claw                  = "modifier_kez_grappling_claw_slow",       -- v6.15.162 vpk - Kez gap-close swing
    -- v6.15.163 - defense catalog refresh, batch 1: the modern hero pool.
    -- KV exposes no modifier names, so every modifier_<ability> below is a
    -- best-effort vpk guess - confirm via the threat_unrecognized harvest
    -- log and correct any wrong suffix.
    ringmaster_impalement               = "modifier_ringmaster_impalement",
    marci_grapple                       = "modifier_marci_grapple",
    muerta_dead_shot                    = "modifier_muerta_dead_shot",
    primal_beast_onslaught              = "modifier_primal_beast_onslaught",
    dawnbreaker_celestial_hammer        = "modifier_dawnbreaker_celestial_hammer",
    hoodwink_bushwhack                  = "modifier_hoodwink_bushwhack",
    snapfire_mortimer_kisses            = "modifier_snapfire_mortimer_kisses",
    void_spirit_aether_remnant          = "modifier_void_spirit_aether_remnant",
    mars_spear                          = "modifier_mars_spear",
    grimstroke_ink_creature             = "modifier_grimstroke_ink_creature",
    pangolier_swashbuckle               = "modifier_pangolier_swashbuckle",
    dark_willow_cursed_crown            = "modifier_dark_willow_cursed_crown",
    -- v6.15.164 - batch 2: older-hero kidnaps / gap-closes / catches.
    faceless_void_chronosphere          = "modifier_faceless_void_chronosphere_freeze",
    batrider_flaming_lasso              = "modifier_batrider_flaming_lasso",
    tiny_toss                           = "modifier_tiny_toss",
    vengefulspirit_nether_swap          = "modifier_vengefulspirit_nether_swap",
    chaos_knight_reality_rift           = "modifier_chaos_knight_reality_rift",
    rattletrap_hookshot                 = "modifier_rattletrap_hookshot",
    rattletrap_power_cogs               = "modifier_rattletrap_cog_marker", -- v0.5.147.x cast-poll trap save (NO_TARGET); the trap marker that lands on the victim (demo-confirmed; VPK grep missed it)
    techies_land_mines                  = "modifier_techies_land_mine_burn",   -- v0.5.149 coverage: mine burst (reactive-only; demo-harvest the real victim mod)
    techies_sticky_bomb                 = "modifier_techies_sticky_bomb_slow",  -- v0.5.149 coverage: attached bomb slow + magical nuke (reactive)
    techies_suicide                     = "modifier_techies_suicide_leap",       -- v0.5.149 Blast Off! leap (combo trigger); arms via THREAT_ARRIVAL_TIMING
    techies_mutually_assured_destruction = "modifier_techies_mutually_assured_destruction",  -- v0.5.149 M.A.D. innate nuke (reactive)
    techies_minefield_sign              = "modifier_techies_minefield_sign_scepter_aura",  -- v0.5.149 Minefield Sign (Aghs Scepter aura)
    huskar_life_break                   = "modifier_huskar_life_break_charge",
    sandking_burrowstrike               = "modifier_sandking_burrowstrike",
    nyx_assassin_impale                 = "modifier_nyx_assassin_impale",
    -- batch 3-4 (defense catalog refresh, 2026-05-17): executes, targeted
    -- disables, channels, delayed-AoE / traps, gap-close secondaries.
    -- modifier_<ability> guesses, all vpk - corrected via threat_unrecognized.
    necrolyte_reapers_scythe            = "modifier_necrolyte_reapers_scythe",
    obsidian_destroyer_sanity_eclipse   = "modifier_obsidian_destroyer_sanity_eclipse",
    lich_chain_frost                    = "modifier_lich_chain_frost",
    skywrath_mage_mystic_flare          = "modifier_skywrath_mystic_flare_aura_effect",
    mars_gods_rebuke                    = "modifier_mars_gods_rebuke",
    snapfire_scatterblast               = "modifier_snapfire_scatterblast_slow",
    bloodseeker_rupture                 = "modifier_bloodseeker_rupture",
    obsidian_destroyer_astral_imprisonment = "modifier_obsidian_destroyer_astral_imprisonment",
    skywrath_mage_ancient_seal          = "modifier_skywrath_mage_ancient_seal",
    chaos_knight_chaos_bolt             = "modifier_chaos_knight_chaos_bolt",
    beastmaster_primal_roar             = "modifier_beastmaster_primal_roar",
    shadow_demon_disruption             = "modifier_shadow_demon_disruption",
    shadow_demon_demonic_purge          = "modifier_shadow_demon_demonic_purge",
    winter_wyvern_winters_curse         = "modifier_winter_wyvern_winters_curse",
    enigma_malefice                     = "modifier_enigma_malefice",
    windrunner_shackleshot              = "modifier_windrunner_shackleshot",
    morphling_adaptive_strike_agi       = "modifier_morphling_adaptive_strike_agi",
    puck_waning_rift                    = "modifier_puck_waning_rift",
    lich_sinister_gaze                  = "modifier_lich_sinister_gaze",
    primal_beast_pulverize              = "modifier_primal_beast_pulverize",
    grimstroke_soul_chain               = "modifier_grimstroke_soul_chain",
    puck_dream_coil                     = "modifier_puck_dream_coil",
    leshrac_split_earth                 = "modifier_leshrac_split_earth",
    jakiro_ice_path                     = "modifier_jakiro_ice_path",

    -- E3c coverage sweep (gate-serving; mod names by convention, see THREATS_ON_SELF note)
    centaur_hoof_stomp                  = "modifier_centaur_hoof_stomp",
    earthshaker_fissure                 = "modifier_earthshaker_fissure",
    monkey_king_boundless_strike        = "modifier_monkey_king_boundless_strike",
    skeleton_king_hellfire_blast        = "modifier_skeleton_king_hellfire_blast",
    snapfire_firesnap_cookie            = "modifier_snapfire_firesnap_cookie",
    primal_beast_rock_throw             = "modifier_primal_beast_rock_throw",
    kunkka_ghostship                    = "modifier_kunkka_ghostship",
    antimage_mana_void                  = "modifier_antimage_mana_void",
    luna_lucent_beam                    = "modifier_luna_lucent_beam",
    invoker_deafening_blast             = "modifier_invoker_deafening_blast",
    queenofpain_sonic_wave              = "modifier_queenofpain_sonic_wave",
    drow_ranger_wave_of_silence         = "modifier_drow_ranger_wave_of_silence",
    huskar_inner_fire                   = "modifier_huskar_inner_fire",
    batrider_flamebreak                 = "modifier_batrider_flamebreak",
    bounty_hunter_wind_walk             = "modifier_bounty_hunter_wind_walk",
    warlock_rain_of_chaos               = "modifier_warlock_rain_of_chaos",
    dawnbreaker_fire_wreath             = "modifier_dawnbreaker_fire_wreath",
    visage_stone_form_self_cast         = "modifier_visage_stone_form_self_cast",
    elder_titan_echo_stomp              = "modifier_elder_titan_echo_stomp",
    kez_shodo_sai                       = "modifier_kez_shodo_sai",
    mars_arena_of_blood                 = "modifier_mars_arena_of_blood",
    sandking_epicenter                  = "modifier_sand_king_epicenter",
    templar_assassin_psionic_trap       = "modifier_templar_assassin_psionic_trap",
    naga_siren_song_of_the_siren        = "modifier_naga_siren_song_of_the_siren",
    dark_willow_terrorize               = "modifier_dark_willow_terrorize",
    dark_willow_bramble_maze            = "modifier_dark_willow_bramble_maze",
    ringmaster_the_box                  = "modifier_ringmaster_the_box",
    ringmaster_wheel                    = "modifier_ringmaster_wheel",
    kez_raptor_dance                    = "modifier_kez_raptor_dance",
    void_spirit_astral_step             = "modifier_void_spirit_astral_step",
    pangolier_gyroshell                 = "modifier_pangolier_gyroshell",
    nyx_assassin_vendetta               = "modifier_nyx_assassin_vendetta",
    tusk_ice_shards                     = "modifier_tusk_ice_shards_thinker",
    lion_voodoo                         = "modifier_lion_voodoo",
    lion_finger_of_death                = "modifier_lion_finger_of_death",
    lion_impale                         = nil,   -- line, instant landing
    lion_mana_drain                     = "modifier_lion_mana_drain",
    lina_laguna_blade                   = "modifier_lina_laguna_blade",
    lina_light_strike_array             = "modifier_lina_light_strike_array",
    naga_siren_ensnare                  = "modifier_naga_siren_ensnare",
    phantom_assassin_phantom_strike     = "modifier_phantom_assassin_phantom_strike_target",
    slark_pounce                        = "modifier_slark_pounce",
    shadow_shaman_shackles              = "modifier_shadow_shaman_shackles",
    witch_doctor_death_ward             = "modifier_witch_doctor_death_ward",
    enigma_black_hole                   = "modifier_enigma_black_hole",
    crystal_maiden_freezing_field       = "modifier_crystal_maiden_freezing_field",
    mirana_arrow                        = "modifier_mirana_arrow",
    -- v6.7 extrapolation (2026-05-11). Modifier names with vpk need
    -- in-game confirmation via :FindAllModifiers() before relying on the
    -- exact suffix. Mobility-only abilities map to nil (no save target;
    -- they're informational pre-threats indicating the followup is coming).
    faceless_void_time_walk             = nil,   -- mobility only
    storm_spirit_ball_lightning         = nil,   -- mobility only
    antimage_blink                      = nil,   -- mobility only
    queenofpain_blink                   = nil,   -- mobility only
    magnataur_skewer                    = "modifier_magnataur_skewer",                 -- vpk
    magnataur_reverse_polarity          = "modifier_magnataur_reverse_polarity_stun",       -- vpk
    earth_spirit_rolling_boulder        = "modifier_earth_spirit_rolling_boulder",     -- vpk
    sven_storm_bolt                     = "modifier_sven_storm_bolt",                  -- (verify)
    shadow_shaman_voodoo                = "modifier_shadow_shaman_voodoo",             -- vpk - Hex
    zuus_lightning_bolt                 = "modifier_zuus_lightning_bolt",              -- (verify)
    zuus_thundergods_wrath              = "modifier_zuus_thundergods_wrath",           -- (verify)
    tidehunter_ravage                   = "modifier_tidehunter_ravage",                -- vpk
    earthshaker_echo_slam               = "modifier_earthshaker_echo_slam",            -- (verify)
    disruptor_static_storm              = "modifier_disruptor_static_storm_thinker",   -- vpk
    treant_overgrowth                   = "modifier_treant_overgrowth",                -- vpk
    life_stealer_open_wounds            = "modifier_life_stealer_open_wounds",         -- vpk
    pugna_life_drain                    = "modifier_pugna_life_drain",                 -- vpk
    disruptor_kinetic_field             = "modifier_disruptor_kinetic_field",  -- vpk - v6.15.10
    abyssal_underlord_pit_of_malice     = "modifier_abyssal_underlord_pit_of_malice_ensare",   -- vpk - v6.15.256
    -- v6.15.258 zero-coverage fill batch 1
    dragon_knight_dragon_tail           = "modifier_dragon_knight_dragon_tail",          -- (verify) - v6.15.258
    night_stalker_void                  = "modifier_night_stalker_void",                 -- vpk - v6.15.258
    ogre_magi_fireblast                 = "modifier_ogre_magi_fireblast",                -- vpk - v6.15.258
    ogre_magi_unrefined_fireblast       = "modifier_ogre_magi_fireblast",                -- vpk - v6.15.258 (shares modifier with fireblast)
    rubick_telekinesis                  = "modifier_rubick_telekinesis_stun",                 -- vpk - v6.15.258
    silencer_last_word                  = "modifier_silencer_last_word",                 -- vpk - v6.15.258
    death_prophet_silence               = "modifier_death_prophet_silence",              -- vpk - v6.15.258
    -- v6.15.263 zero-coverage fill batch 2: AOE delayed killers
    ancient_apparition_cold_feet        = "modifier_cold_feet",       -- vpk - v6.15.263
    ancient_apparition_ice_blast        = "modifier_ice_blast",       -- vpk - v6.15.263
    antimage_mana_void                  = nil,                                            -- v6.15.263: no Sniper modifier (instant burst); anim-path only
    gyrocopter_homing_missile           = "modifier_gyrocopter_homing_missile",          -- vpk - v6.15.263
    gyrocopter_call_down                = "modifier_gyrocopter_call_down_slow",          -- vpk - v6.15.263
    kunkka_torrent                      = "modifier_kunkka_torrent_thinker",             -- (verify) - v6.15.263 (thinker entity for AOE warning)
    kunkka_x_marks_the_spot             = "modifier_kunkka_x_marks_the_spot",            -- vpk - v6.15.263
    nevermore_requiem_of_souls          = "modifier_nevermore_requiem",                  -- vpk - v6.15.263
    terrorblade_sunder                  = nil,                                            -- v6.15.263: no Sniper modifier (instant HP swap); anim-path only
    -- v6.15.265 zero-coverage fill batch 3
    doom_bringer_infernal_blade         = "modifier_doom_bringer_infernal_blade",        -- vpk - v6.15.265
    furion_sprout                       = "modifier_furion_sprout",                       -- vpk - v6.15.265
    visage_grave_chill                  = "modifier_visage_grave_chill",                  -- vpk - v6.15.265
    visage_soul_assumption              = nil,                                            -- v6.15.265: no Sniper modifier (instant burst); anim-path only
    venomancer_venomous_gale            = "modifier_venomancer_venomous_gale",            -- vpk - v6.15.265
    luna_lucent_beam                    = nil,                                            -- v6.15.265: no Sniper modifier (instant mini-stun); anim-path only
    spectre_spectral_dagger             = "modifier_spectre_spectral_dagger",             -- vpk - v6.15.265
    -- v6.15.266 zero-coverage fill batch 4
    juggernaut_omni_slash               = "modifier_juggernaut_omni_slash",               -- (verify) - v6.15.266
    juggernaut_swift_slash              = nil,                                            -- v6.15.266: no Sniper modifier (gap-close attacks); anim-path only
    phantom_lancer_spirit_lance         = "modifier_phantom_lancer_spirit_lance",         -- vpk - v6.15.266
    meepo_earthbind                     = "modifier_meepo_earthbind",                     -- vpk - v6.15.266
    meepo_poof                          = nil,                                            -- v6.15.266: no Sniper modifier (caster gap-close channel); anim-path only
    monkey_king_wukongs_command         = "modifier_monkey_king_wukongs_command_aura",    -- (verify) - v6.15.266
    slardar_slithereen_crush            = "modifier_slardar_slithereen_crush",            -- (verify) - v6.15.266
    slardar_amplify_damage              = "modifier_slardar_amplify_damage",              -- vpk - v6.15.266
    bristleback_hairball                = "modifier_bristleback_viscous_nasal_goo",           -- vpk - v6.15.266
    -- v6.15.267 zero-coverage fill batch 5
    invoker_cold_snap                   = "modifier_invoker_cold_snap",            -- vpk - v6.15.267
    invoker_sun_strike                  = nil,                                            -- v6.15.267: no Sniper modifier (delayed AoE burst); needs OnParticleCreate
    invoker_emp                         = nil,                                            -- v6.15.267: no Sniper modifier (delayed AoE mana burn); needs OnParticleCreate
    riki_smoke_screen                   = "modifier_riki_smoke_screen",                   -- vpk - v6.15.267
    riki_blink_strike                   = nil,                                            -- v6.15.267: no Sniper modifier (gap-close); anim path
    lone_druid_spirit_bear_entangle     = "modifier_lone_druid_spirit_bear_entangle_effect",          -- vpk - v6.15.267 (bear passive root proc)
    lone_druid_savage_roar              = nil,                                            -- v6.15.267: no Sniper modifier (NO_TARGET fear AoE); anim path
    undying_decay                       = "modifier_undying_decay",                       -- vpk - v6.15.267
    dazzle_poison_touch                 = "modifier_dazzle_poison_touch",                 -- vpk - v6.15.267
    weaver_the_swarm                    = "modifier_weaver_swarm_debuff",                    -- vpk - v6.15.267
    centaur_double_edge                 = nil,                                            -- v6.15.267: no Sniper modifier (instant burst); anim path
    phoenix_launch_fire_spirit          = nil,                                            -- v6.15.267: no Sniper modifier (line projectile); anim path (ACT_INVALID -- may not fire)
    -- v6.15.268 zero-coverage fill batch 6
    alchemist_unstable_concoction_throw = "modifier_alchemist_unstable_concoction",      -- vpk - v6.15.268
    broodmother_sticky_snare            = "modifier_broodmother_sticky_snare",            -- vpk - v6.15.268
    medusa_gorgon_grasp                 = "modifier_medusa_gorgon_grasp",                 -- vpk - v6.15.268
    medusa_mystic_snake                 = "modifier_medusa_mystic_snake",                 -- vpk - v6.15.268
    troll_warlord_whirling_axes_ranged  = "modifier_troll_warlord_whirling_axes_slow",  -- vpk - v6.15.268
    dark_seer_vacuum                    = "modifier_dark_seer_vacuum",                    -- vpk - v6.15.268
    dark_seer_ion_shell                 = "modifier_dark_seer_ion_shell",                 -- vpk - v6.15.268
    ember_spirit_sleight_of_fist        = "modifier_ember_spirit_sleight_of_fist_caster", -- vpk - v6.15.268 (caster-side phase marker)
    -- v6.15.269 zero-coverage fill batch 7
    bounty_hunter_shuriken_toss         = "modifier_bounty_hunter_shuriken_toss",        -- (verify) - v6.15.269
    brewmaster_cinder_brew              = "modifier_brewmaster_cinder_brew",              -- vpk - v6.15.269
    phoenix_sun_ray                     = "modifier_phoenix_sun_ray",                     -- vpk - v6.15.269
    shredder_chakram                    = "modifier_shredder_chakram",                    -- vpk - v6.15.269
    arc_warden_flux                     = "modifier_arc_warden_flux",                     -- vpk - v6.15.269
    -- v6.15.270 final mop-up
    abaddon_aphotic_shield              = nil,                                            -- v6.15.270: cast on ALLY; explosion AOE damage is the threat but no Sniper modifier
    -- v0.5.14 E9 (BL-B5): duplicate centaur_double_edge = nil removed (live entry preserved earlier in file at v6.15.267 block; this v6.15.270 duplicate was an editing trap)
    chen_penitence                      = "modifier_chen_penitence",                      -- vpk - v6.15.270
    enchantress_impetus                 = nil,                                            -- v6.15.270: autocast passive proc damage; no specific modifier (raw projectile damage)
    omniknight_hammer_of_purity         = "modifier_omniknight_hammer_of_purity",         -- vpk - v6.15.270
    largo_catchy_lick                   = "modifier_largo_catchy_lick",                   -- vpk - v6.15.270
    -- v0.5.14 E9 (BL-B5): duplicate largo_frogstomp / largo_croak_of_genius nil placeholders removed; the live string-valued entries in the v6.15.272 second-match harvest block below are authoritative
    -- v6.15.271 ranked-match harvest
    tusk_walrus_punch                   = "modifier_tusk_walrus_punch_air_time",          -- harvested 2026-05-24
    tusk_tag_team                       = "modifier_tusk_tag_team_attack_slow",           -- harvested 2026-05-24 (passive proc)
    tiny_avalanche                      = "modifier_tiny_avalanche_stun",                 -- harvested 2026-05-24
    skywrath_mage_concussive_shot       = "modifier_skywrath_mage_concussive_shot_slow",  -- harvested 2026-05-24
    keeper_of_the_light_blinding_light  = "modifier_keeper_of_the_light_blinding_light",  -- harvested 2026-05-24
    keeper_of_the_light_will_o_wisp     = "modifier_keeper_of_the_light_will_o_wisp",     -- harvested 2026-05-24
    keeper_of_the_light_radiant_bind    = "modifier_keeper_of_the_light_radiant_bind",    -- harvested 2026-05-24 (anti-ranged disable)
    legion_commander_press_the_attack   = "modifier_legion_commander_intimidate_slow",    -- harvested 2026-05-24 (verify ability name)
    -- v6.15.272 second-match harvest
    faceless_void_timelock              = "modifier_faceless_void_timelock_freeze",       -- harvested 2026-05-25 (passive)
    faceless_void_time_dilation         = "modifier_faceless_void_time_dilation_distortion", -- harvested 2026-05-25
    largo_frogstomp                     = "modifier_largo_frogstomp_debuff",              -- harvested 2026-05-25 (was nil placeholder in v6.15.270)
    largo_croak_of_genius               = "modifier_largo_croak_of_genius_debuff",        -- harvested 2026-05-25 (was nil placeholder in v6.15.270)
    razor_plasma_field                  = "modifier_razor_plasma_field_slow",             -- harvested 2026-05-25
    razor_storm_surge                   = "modifier_razor_storm_surge_slow",              -- harvested 2026-05-25
    razor_eye_of_the_storm              = "modifier_razor_eye_of_the_storm_armor",        -- harvested 2026-05-25
    rubick_fade_bolt                    = "modifier_rubick_fade_bolt_debuff",             -- harvested 2026-05-25
    -- v6.15.273 third-match harvest
    ancient_apparition_chilling_touch   = "modifier_chilling_touch_slow",                 -- harvested 2026-05-25
    ancient_apparition_ice_vortex       = "modifier_ice_vortex",                          -- harvested 2026-05-25
    ancient_apparition_bone_chill       = "modifier_ancient_apparition_bone_chill_debuff", -- harvested 2026-05-25
    magnataur_shockwave                 = "modifier_magnataur_shockwave_pull",            -- harvested 2026-05-25 (verify ability name)
    snapfire_lil_shredder               = "modifier_snapfire_lil_shredder_debuff",        -- harvested 2026-05-25
    snapfire_magma_burn                 = "modifier_snapfire_magma_burn_slow",            -- harvested 2026-05-25 (verify ability name)
    witch_doctor_maledict               = "modifier_maledict",                            -- harvested 2026-05-25
    -- v6.15.198 harvest - anim-route mappings for the threats harvested
    -- into THREATS_ON_SELF this version. Where one ability lands MULTIPLE
    -- modifiers on the victim (PA Stifling Dagger, Viper Nethertoxin
    -- variants, SK Reincarnation variants), we route the ability to the
    -- PRIMARY threat-modifier - the actively-debuffing one - since the
    -- score-bonus / save-chain dispatcher reads from one name. The
    -- secondary modifier names are still in THREATS_ON_SELF so the
    -- threat_unrecognized harvest loop doesn't re-flag them.
    phantom_assassin_stifling_dagger    = "modifier_phantom_assassin_stiflingdagger",      -- harvested
    drow_ranger_frost_arrows            = "modifier_drow_ranger_frost_arrows_slow",         -- harvested (passive on-attack)
    oracle_fortunes_end                 = "modifier_oracle_fortunes_end_channel_target",    -- harvested - channel marker is primary
    oracle_purifying_flames             = "modifier_oracle_purifying_flames",               -- harvested
    skeleton_king_reincarnation         = "modifier_skeleton_king_reincarnate_slow",        -- harvested - slow aura is the on-Sniper effect
    viper_corrosive_skin                = "modifier_viper_corrosive_skin_slow",              -- harvested (passive on-attack)
    viper_nethertoxin                   = "modifier_viper_nethertoxin_mute",                 -- harvested - silence variant is the R-blocker
    viper_poison_attack                 = "modifier_viper_poison_attack_slow",               -- harvested (passive on-attack)
    necrolyte_heartstopper_aura         = "modifier_necrolyte_heartstopper_aura_effect",     -- harvested (passive aura)
    vengefulspirit_retribution          = "modifier_vengefulspirit_retribution_tracker",     -- harvested (shard tracker)
}

----------------------------------------------------------------------------
-- RECOMMENDED_SAVES - best-to-worst save priority per threat
--
-- The default chain order (Eul → Lotus → Manta → Satanic → Glimmer → Pike →
-- Force → Grenade-self → BKB → Aeon) is generic. For specific threats,
-- different items are clearly better. Examples:
--
--  - **Pudge Dismember (200u tether)**: Pike or grenade-self breaks it
--    instantly. Eul (2.5s cyclone) works but locks Sniper out of attacks for
--    longer than the break needs. BKB doesn't help (Dismember pierces magic
--    immunity). Recommended: Pike → grenade-self → Force → Eul → Manta.
--
--  - **Bara Charge (homing stun)**: Pike/Force/grenade-self are useless
--    (homing re-targets). BKB blocks the stun on impact. Eul invuln spans the
--    impact. Recommended: BKB → Eul → Lotus → Manta.
--
--  - **Bane Nightmare (entity-targeted sleep)**: Eul (invuln cyclone fizzles
--    the cast) is best. BKB blocks during cast point. Manta dispels after.
--    Recommended: Eul → Lotus → Manta → BKB.
--
-- This list lets each hero get the OPTIMAL save per threat instead of always
-- firing the first chain entry that happens to qualify. Hero scripts can
-- ADD hero-specific saves (like Sniper's grenade-self) by extending the list
-- via their own HERO_SAVE_OVERRIDES table.
--
-- Names match SAVE_KIND keys (item_* or generic ability identifiers).
----------------------------------------------------------------------------

---@type table<string, string[]>
ThreatData.RECOMMENDED_SAVES = {
    -- Entity-targeted spells: best = invuln / magic_immune / reflect.
    -- Wind Waker is a strict Eul upgrade (3.5s vs 2.5s, can-act-during).
    modifier_bane_nightmare = {
        "item_cyclone", "item_wind_waker", "item_lotus_orb", "item_manta",
        "item_black_king_bar",
    },
    modifier_lion_voodoo = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
    },
    modifier_lion_finger_of_death = {
        -- magic_barrier (Pipe of Insight) absorbs a lot of the burst.
        -- v6.7: Eternal Shroud removed in 7.41 - was previously listed here.
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
         "item_pipe",
    },
    modifier_lina_laguna_blade = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
         "item_pipe",
    },
    modifier_naga_siren_ensnare = {
        -- pierces BKB
        "item_cyclone", "item_wind_waker", "item_lotus_orb", "item_manta",
        "item_satanic", "item_disperser",
    },
    modifier_doom_bringer_doom = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
    },
    -- Channel-tethers: prefer cheap displacement, fall through to dispel/invuln.
    -- Blink always works (1200u >> any tether).
    modifier_pudge_dismember_pull = {
        -- v6.15.261: hero-agnostic; hero brains insert their own knockback
        -- saves via *_THREAT_PATCHES if applicable. Sniper prepends grenade_self.
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_swift_blink", "item_arcane_blink", "item_overwhelming_blink",
        "item_cyclone", "item_wind_waker", "item_manta", "item_disperser",
    },
    modifier_bane_fiends_grip = {
        -- 875u tether (HEURISTIC - Liquipedia doesn't document explicit leash);
        -- Pike push 425u only breaks when Bane is >450u away.
        -- Blink ALWAYS works. Eul/Manta are most reliable dispels.
        -- BKB does NOT work (pierces).
        "item_cyclone", "item_wind_waker", "item_manta", "item_satanic",
        "item_disperser", "item_blink", "item_arcane_blink",
        "item_hurricane_pike", "item_force_staff",
    },
    modifier_shadow_shaman_shackles = {
        -- v6.15.261: hero-agnostic.
        "item_cyclone", "item_wind_waker", "item_manta", "item_satanic",
        "item_disperser", "item_blink",
        "item_hurricane_pike", "item_force_staff",
    },
    modifier_witch_doctor_death_ward = {
        -- v6.7: ward attack range is 650 at level 3 (was using fictional 1100).
        -- Pike (425) / Force (600) sometimes break; Blink always breaks.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe",
    },
    -- Homing charges: displacement USELESS on self (re-targets). Need
    -- invuln/immune at impact. grenade_at_caster knocks the charger and
    -- cancels the modifier - that's the cheap option for Sniper.
    modifier_spirit_breaker_charge_of_darkness = {
        "item_black_king_bar", "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_ghost",
    },
    modifier_tusk_snowball_movement = {
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_manta",
    },
    -- v6.15.162: Kez Grappling Claw. The 80% slow is the danger (Sniper
    -- can't kite). Eul / Wind Waker fully dodge the swing-in + the landing
    -- hit; BKB blocks the slow and keeps Sniper attacking; Pike / grenade
    -- push the caster off (Kez is not displacement-immune).
    modifier_kez_grappling_claw_slow = {
        -- v6.15.261: hero-agnostic.
        "item_cyclone", "item_wind_waker", "item_black_king_bar",
        "item_hurricane_pike", "item_force_staff",
        "item_manta",
    },
    -- Delayed AoEs: displacement works (target the EFFECT, not the entity)
    modifier_lina_light_strike_array = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_wind_waker", "item_black_king_bar",
        "item_manta",
    },
    modifier_enigma_black_hole = {
        "item_black_king_bar", "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_arcane_blink", "item_overwhelming_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
    },
    modifier_crystal_maiden_freezing_field = {
        -- v6.15.261: hero-agnostic.
        "item_black_king_bar", "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_pipe",
    },
    -- Line projectiles: perpendicular displacement
    modifier_pudge_meat_hook = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_wind_waker",
    },
    -- v6.14.1 M9: Tusk Ice Shards - slow-moving line projectile, perp
    -- displacement / blink avoids. Mirrors hook ordering.
    modifier_tusk_ice_shards_thinker = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_wind_waker",
    },
    modifier_slark_pounce = {
        -- v6.15.261: hero-agnostic.
        "item_force_staff", "item_hurricane_pike", "item_blink",
        "item_cyclone", "item_wind_waker", "item_manta", "item_black_king_bar",
    },
    modifier_techies_suicide_leap = {
        -- v0.5.149: Blast Off! leap (fallback chain for non-composing heroes; Lina
        -- resolves the composed close_gap tier). Airborne first, then BLINK (full exit
        -- of the 400 AoE -- bumped ahead of displacement per the demo), then Force/Pike,
        -- then BKB eats the magical burst & stun.
        "item_wind_waker", "item_cyclone", "item_blink", "item_force_staff",
        "item_hurricane_pike", "item_black_king_bar",
    },
    modifier_techies_minefield_sign_scepter_aura = {
        -- v0.5.149: Minefield Sign (Aghs aura, 1000 radius, 300 magical per 200u moved).
        -- ONLY 3 escapes (user-verified). BLINK leads -- the only clean full-clear (1200u
        -- out of the 1000r field); on CD -> BKB (magic-immune, walk out) then Wind Waker
        -- LAST (untargetable 2.5s but the 10s minefield OUTLASTS the cyclone -> lands back
        -- in it, a last resort). NOT Eul (same outlast) and NOT Force/Pike (600u cannot
        -- clear a 1000r field; forced movement IS movement = damage). No category -> this
        -- list resolves directly (tier 4).
        "item_blink", "item_black_king_bar", "item_wind_waker",
    },
    modifier_mirana_arrow = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone",
    },
    -- Physical chase: invis breaks target-lock; BKB doesn't help. Ghost makes
    -- attacks miss entirely. Blade Mail returns damage. Crimson blocks.
    modifier_phantom_assassin_phantom_strike_target = {
        -- v6.15.261: hero-agnostic.
        "item_glimmer_cape", "item_ghost", "item_blade_mail",
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_crimson_guard", "item_solar_crest",
    },
    modifier_ursa_overpower = {
        "item_glimmer_cape", "item_ghost", "item_blade_mail",
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_cyclone", "item_crimson_guard", "item_solar_crest",
    },
    -- Drain: pierces BKB
    modifier_razor_static_link_debuff = {
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_blink",
    },
    modifier_lion_mana_drain = {
        -- v6.15.261: hero-agnostic.
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_blink",
    },
    -- Lockdown - Satanic for lifesteal-tank, Blade Mail returns Duel damage
    modifier_legion_commander_duel = {
        "item_satanic", "item_blade_mail", "item_cyclone", "item_wind_waker",
        "item_manta",
    },
    -- Misc
    -- v6.15.203 (audit D5): the comment claim "BKB ignores taunt" is
    -- WRONG - Berserker's Call PIERCES spell immunity (Liquipedia). Blade
    -- Mail returns the post-armor attack damage Sniper deals to Axe at
    -- FULL strength against Sniper's own armor - net loss. Entry kept
    -- for documentation but never consumed: THREATS_ON_SELF tags
    -- save="informational" and the v6.15.202 D1 dispatcher catch-all
    -- correctly no-ops on that.
    modifier_axe_berserkers_call = {
        "item_black_king_bar", "item_blade_mail",
    },
    -- v6.7 extrapolation entries
    modifier_shadow_shaman_voodoo = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
         "item_manta",
    },
    modifier_zuus_lightning_bolt = {
        "item_lotus_orb", "item_black_king_bar", "item_cyclone", "item_wind_waker",
         "item_pipe",
    },
    modifier_zuus_thundergods_wrath = {
        -- Global ult, 2s cast point. NOT reflectable (AoE, not single-target).
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe",
    },
    modifier_tidehunter_ravage = {
        "item_black_king_bar", "item_blink", "item_arcane_blink", "item_swift_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_pipe",
    },
    modifier_earthshaker_echo_slam = {
        "item_black_king_bar", "item_blink", "item_arcane_blink",
        "item_hurricane_pike", "item_force_staff", "item_cyclone",
        "item_wind_waker", "item_pipe",
    },
    modifier_magnataur_reverse_polarity_stun = {
        -- 1700u radius. Only Blink (1200-1400) reliably escapes; BKB / Aeon
        -- carry through the stun.
        "item_blink", "item_arcane_blink", "item_black_king_bar",
        "item_cyclone", "item_wind_waker",
    },
    modifier_disruptor_static_storm_thinker = {
        "item_hurricane_pike", "item_force_staff", "item_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe",
    },
    -- v6.15.10: Disruptor Kinetic Field. Wall blocks forced movement, blink,
    -- and cyclone displacement. Only KNOCKBACK crosses -- which no item
    -- provides, only hero-specific abilities (Sniper Concussive Grenade,
    -- etc.). v6.15.261: lib entry is empty (no item works); hero brains
    -- inject knockback via *_THREAT_PATCHES. The dispatcher falls through to
    -- the trap category chain (blinks) if no patch is registered -- blinks
    -- also do not work against KF in practice, but the failure is silent.
    modifier_disruptor_kinetic_field = {},
    -- v6.15.256: Underlord Pit of Malice. Same trap escape posture as
    -- Kinetic Field; only hero-knockback escapes the snare reliably.
    -- v6.15.261: hero-agnostic empty chain; hero patches inject knockback.
    modifier_abyssal_underlord_pit_of_malice_ensare = {},
    modifier_treant_overgrowth = {
        "item_black_king_bar", "item_blink", "item_swift_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
    },
    modifier_magnataur_skewer = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_black_king_bar", "item_cyclone",
    },
    modifier_sven_storm_bolt = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_cyclone",
    },
    modifier_earth_spirit_rolling_boulder = {
        -- v6.15.261: hero-agnostic.
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_cyclone",
    },
    modifier_life_stealer_open_wounds = {
        "item_glimmer_cape", "item_ghost", "item_blade_mail", "item_manta",
        "item_hurricane_pike", "item_force_staff", "item_satanic",
        "item_crimson_guard",
    },
    modifier_pugna_life_drain = {
        -- v6.15.261: hero-agnostic.
        "item_cyclone", "item_wind_waker", "item_manta", "item_blink",
        "item_hurricane_pike", "item_force_staff",
    },
}

----------------------------------------------------------------------------
-- CATEGORY_CHAINS - per-category fallback save chains
----------------------------------------------------------------------------

---Default save chain per THREAT_CATEGORY. Used by the resolver when a threat
---has no entry in RECOMMENDED_SAVES and no hero-side override. These are the
---chains validated on the tested heroes; new threats with a known category
---get the canonical response for their behavioral class without per-modifier
---tuning.
---
---v6.15.259: extracted from Sniper/Sniper.lua so other hero brains can
---consume the same category-keyed defaults.
---v6.15.260: HERO-AGNOSTIC -- no per-hero save names appear in any chain.
---Hero brains insert their own abilities via per-hero category-patch tables
---(Sniper uses SNIPER_CATEGORY_PATCHES with {prepend, insert_after, append}
---semantics). The lib chain is the items-only baseline; the hero patch
---adds hero-specific saves around the baseline.
---@type table<string, string[]>
ThreatData.CATEGORY_CHAINS = {
    -- Chase / gap-close (Bara, Tusk, PA Strike, Slark Pounce, Storm Ball
    -- Lightning, Magnus Skewer/RP-prep, anything homing toward the hero).
    -- Pike-on-enemy radial-pushes them, Force pushes self, BKB blocks damage.
    -- v0.5.x counter-axis enrichment: every defensive item poured in by
    -- mechanic; the compose-time SaveCounters filter (defense.lua tier 3)
    -- + run_chain_walk keep only the items that actually counter the live
    -- threat, so over-listing is harmless. Order = priority within category.
    close_gap = {
        -- v0.5.136.1 redesign: AIRBORNE-FIRST priority (Order = priority within
        -- category). A gap-closer (leap / charge / blink) is best answered by an
        -- airborne dodge (untargetable -> the attack/leash whiffs), then a BLINK
        -- reposition (v0.5.149: bumped ahead of invis/BKB -- a full exit of a leap/
        -- line/zone AoE, e.g. Techies Blast Off), then invis / lock-break vs a
        -- physical chaser, then magic-immunity, then physical answers (ghost/
        -- blademail/crimson), and finally displacement (pike/force keep-away) as the
        -- FALLBACK. This mirrors the
        -- hand-curated CH.GAP_CLOSE_SAVES priority the composed path replaces, so a
        -- migrated gap-closer fires WW-first, not pike-first (the pre-reorder
        -- displacement-first order would have led with Pike after W skips).
        -- item_blink (v0.5.134): survives SaveCounters only for gap-closers whose
        -- DeriveCounters emits displacement_blink (leaps/lines/homing/non-barrier
        -- zones; charges withhold it -- "re-homes"). item_glimmer_cape (v0.5.134):
        -- in the invis tier so a physical-chase composed chain (PA) keeps Glimmer.
        "item_wind_waker", "item_cyclone", "item_blink",
        "item_glimmer_cape", "item_solar_crest", "item_silver_edge", "item_invis_sword",
        "item_black_king_bar",
        "item_ghost", "item_blade_mail", "item_crimson_guard",
        "item_hurricane_pike", "item_force_staff",
        "item_lotus_orb", "item_manta", "item_phase_boots",
    },
    -- Tether channels on the hero (Pudge Dismember, Bane Grip, Shaman
    -- Shackles, WD Death Ward, Legion Duel, Pugna Life Drain -- anything
    -- that locks the hero at range from the caster). Force/Pike push breaks
    -- the tether; Manta/Satanic dispel some; BKB blocks damage.
    channel_on_self = {
        "item_hurricane_pike",
        "item_force_staff",
        "item_blink", "item_swift_blink", "item_arcane_blink",
        "item_manta", "item_satanic", "item_disperser", "item_diffusal_blade",
        "item_cyclone", "item_wind_waker",
        -- physical "channels" (Omnislash, attack-driven locks): invuln misses,
        -- attack-immunity / block / invis are the real answers.
        "item_ghost", "item_crimson_guard", "item_blade_mail",
        "item_glimmer_cape", "item_solar_crest",
    },
    -- Line projectiles (Mirana Arrow, Pudge Hook, Magnus Skewer, Sven Bolt,
    -- Earth Spirit Boulder). Perpendicular displacement breaks the line.
    line_projectile = {
        "item_force_staff", "item_hurricane_pike",
        "item_blink", "item_swift_blink", "item_arcane_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_black_king_bar", "item_lotus_orb",
    },
    -- Single-target hard disable (Hex, Doom debuff cast, Lion Voodoo,
    -- Shaman Voodoo). Instant-cast invuln (Eul/Wind Waker/Lotus) ideal.
    targeted_disable = {
        "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_disperser", "item_black_king_bar",
        "item_blink", "item_swift_blink", "item_arcane_blink",
    },
    -- AoE lockdown ults (Tide Ravage, ES Echo Slam, Magnus RP, Naga Siren,
    -- Treant Overgrowth, Disruptor Static Storm). Blink/Pike out, BKB the
    -- damage, Aeon trigger on health drop.
    delayed_aoe = {
        "item_hurricane_pike", "item_force_staff",
        "item_blink", "item_arcane_blink", "item_swift_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
        "item_pipe", "item_glimmer_cape", "item_solar_crest",
    },
    -- Area-deny traps (Disruptor Kinetic Field, Underlord Pit of Malice,
    -- Faceless Void Chrono edge). Forced movement blocked -- only knockback
    -- and blink escape. Hero-specific knockback abilities patch in via
    -- per-hero CATEGORY_PATCHES.
    -- Area-deny traps. Barrier/root traps (Kinetic Field, Pit) set
    -- blocks_forced_movement, so blink is FILTERED and only knockback
    -- (Force/Pike perp/far) crosses -- they MUST lead. Non-blocking traps
    -- keep blink.
    trap = {
        "item_force_staff", "item_hurricane_pike",
        "item_blink", "item_arcane_blink", "item_swift_blink",
        "item_black_king_bar", "item_cyclone", "item_wind_waker",
    },
    -- Drain channels (Pugna Life Drain, Lion Mana Drain). Force/Pike
    -- breaks tether.
    drain = {
        "item_force_staff", "item_hurricane_pike",
        "item_blink", "item_swift_blink", "item_arcane_blink",
        "item_cyclone", "item_wind_waker", "item_manta",
        "item_satanic", "item_disperser", "item_diffusal_blade",
    },
    -- Physical-chase debuffs (Lifestealer Open Wounds, Slark Essence Shift).
    -- Pike pushes chaser, Glimmer/Ghost break attack target-lock.
    physical_chase = {
        "item_hurricane_pike", "item_force_staff",
        "item_ghost", "item_glimmer_cape", "item_solar_crest",
        "item_silver_edge", "item_invis_sword",
        "item_blade_mail", "item_crimson_guard",
        "item_manta", "item_black_king_bar",
    },
    -- Lockdown buffs on enemy (Bristleback turn, Troll trance, Ursa Enrage).
    -- The enemy is now extra-tanky -- defensive items rather than displacement.
    lockdown = {
        "item_cyclone", "item_wind_waker", "item_lotus_orb",
        "item_manta", "item_black_king_bar",
        -- enemy becomes a tanky physical threat (Duel, Enrage, Battle Trance):
        -- attack-immunity / block / return are the real answers.
        "item_ghost", "item_crimson_guard", "item_blade_mail",
    },
    -- Single-target burst (Lina Laguna, Lion Finger, Zeus Bolt, single-target
    -- nukes). Lotus reflects, BKB blocks, magic_barrier eats.
    targeted_burst = {
        "item_lotus_orb",
        "item_black_king_bar", "item_pipe",
        "item_cyclone", "item_wind_waker", "item_glimmer_cape",
        "item_manta",
    },
}

---Look up the default save chain for a category. Returns nil if no entry.
---@param category string|nil
---@return string[]|nil
function ThreatData.CategoryChain(category)
    if not category then return nil end
    return ThreatData.CATEGORY_CHAINS[category]
end

---v0.5.48 Phase 2: per-threat arrival-timing catalog. Data-only entries
---giving the inputs needed to compute "when does this threat actually
---hit the target" precisely. Hero-side code combines an entry with the
---live caster/target positions + (optionally) KV reads to derive
---impact_t and impact_pos. Used by Lina W .fire for precise pre-fire
---timing (W has 1.12s prep so it needs accurate impact_t to land at
---arrival). Future Sniper opt-in via the same catalog.
---
---Entry fields:
---  - kind            : descriptive tag (homing_charge / homing_carry /
---                      instant_blink / channel_at_caster /
---                      cast_point_targeted). Informational; not consumed
---                      by the compute helper.
---  - speed_source    : how to derive travel speed.
---      'live_or_fallback' = max(NPC.GetMoveSpeed(caster), speed_fallback)
---      'kv_or_fallback'   = read KV (kv_ability + kv_speed_key) else
---                           speed_fallback
---      'instant'          = no travel time (cast point + post-cast delay
---                           only)
---  - speed_fallback  : numeric u/s used when live/KV unavailable.
---  - kv_ability      : KV ability name (e.g. 'tusk_snowball') for KV
---                      lookups. Modifier.GetAbility(mod_handle) provides
---                      the live ability handle.
---  - kv_speed_key    : KV special value key for travel speed.
---  - cast_point      : seconds before the threat physically lands after
---                      the modifier-create event. For blinks / charges
---                      this is 0 (modifier IS the impact arming). For
---                      cast-point-armed threats (Lion Finger, Sniper
---                      Assassinate) this is the cast point duration.
---  - post_cast_delay : seconds AFTER cast point during which the threat
---                      lands. Most threats are 0; some have a baked-in
---                      delay between cast finish and impact.
---  - impact_pos      : 'self' (defender's current position) or 'caster'
---                      (threat caster's current position). Determines
---                      where defensive AoE saves should be aimed.
---
---Compute helper (hero-side):
---```lua
---local impact_t, impact_pos = state.compute_arrival_time(
---    threat_mod, caster, self_npc, modifier_handle)
---if impact_t and impact_t <= W_PREP + slack then fire_W_now() end
---```
-- v0.5.147 lib-first lift (line-intercept): the line-projectile intercept
-- CATALOG, lifted from Lina.lua's hero-local LINE_PROJECTILE_INTERCEPTS so the
-- general item-save mechanism lives in the shared lib (only ability injection
-- stays hero-local). Consumed by Dispatcher:HandleLineProjectile (lib/defense.lua),
-- which a hero wires from its OnLinearProjectileCreate. Keyed on the projectile
-- SOURCE unit name. threat_mod = the canonical victim modifier (nilable; nil ->
-- the "<ability>_incoming" synthetic dedup key) so the pre-impact line dispatch
-- and the reactive handle_threat_on_self save collapse to ONE single-spend lock.
-- hit_radius = the projectile collision/latch width on the victim (1.0 hull);
-- the +75 code buffer (in HandleLineProjectile) covers victim jitter while the
-- displacement order resolves.
ThreatData.LINE_PROJECTILE_INTERCEPTS = {
    -- src_unit_name              ability_name                threat_mod (nilable, canonical)              hit_radius
    npc_dota_hero_pudge         = { ability = "pudge_meat_hook",        threat_mod = "modifier_pudge_meat_hook",     hit_radius = 130 },
    npc_dota_hero_mirana        = { ability = "mirana_arrow",           threat_mod = "modifier_mirana_arrow",        hit_radius = 115 },
    npc_dota_hero_magnataur     = { ability = "magnataur_skewer",       threat_mod = "modifier_magnataur_skewer",    hit_radius = 125 },
    -- v0.5.147.1 REMOVED Sven Storm Bolt + ES Fissure: OnLinearProjectileCreate
    -- cannot fire for them -- Storm Bolt is a HOMING/tracking projectile (not a
    -- linear skillshot) and Fissure is a wall+stun (not a traveling projectile).
    -- The v0.5.147 demo confirmed only mirana + magnataur ever reached the
    -- geometry. Their mitigation lives in the reactive composed save (Eul/WW
    -- disjoint + BKB + Lotus for Storm Bolt; escape for Fissure), not this path.
    -- v0.5.146 Clockwerk Hookshot: POINT linear projectile (KV latch_radius 125,
    -- speed 4000/5000/6000, pierces BKB; latches the first unit in-path, so
    -- displacement out of the line breaks it). Lifted to lib at v0.5.147.
    npc_dota_hero_rattletrap    = { ability = "rattletrap_hookshot",    threat_mod = "modifier_rattletrap_hookshot", hit_radius = 125 },
}

ThreatData.THREAT_ARRIVAL_TIMING = {

    -- Bara Charge of Darkness: homing close-gap. Bara's MS during charge
    -- reflects the modifier's MS boost; NPC.GetMoveSpeed returns the live
    -- modified value (typically 500-700 with phase boots + level + talents,
    -- up to ~1100 max). speed_fallback=1000 for the case where the live
    -- read fails. impact_pos=self because Bara STOPS at the target on hit.
    -- v0.5.50: ramp model from Liquipedia (replaces v0.5.49.x flat
    -- acceleration_buffer). Bara Charge of Darkness:
    --   Min MS bonus: 68.75 / 81.25 / 93.75 / 106.25 per skill level
    --   Max MS bonus: 275 / 325 / 375 / 425 per skill level
    --   Wind-up: 1.5s linear ramp from min to max
    --   Status: flat MS bonus (ramping) + removed MS cap + no unit collision
    --
    -- NPC.GetMoveSpeed at fire moment reflects the CURRENT ramped speed
    -- (base_MS + min_bonus + ramp_fraction * (max_bonus - min_bonus)).
    -- Catalog impact_t = d / live_speed underestimates Bara's progress
    -- because Bara CONTINUES to ramp during W's 1.12s prep window.
    --
    -- Ramp acceleration per level (max - min) / wind_up:
    --   lvl 1: (275 - 68.75) / 1.5  = 137 u/s^2
    --   lvl 2: (325 - 81.25) / 1.5  = 163 u/s^2
    --   lvl 3: (375 - 93.75) / 1.5  = 188 u/s^2
    --   lvl 4: (425 - 106.25) / 1.5 = 213 u/s^2  (catalog default)
    --
    -- v0.5.114: ComputeArrivalTime now integrates the ramp EXACTLY
    -- (RampImpactT closed form over the REMAINING wind-up) instead of the
    -- v0.5.50 avg extrapolation. accel resolves per-LEVEL at runtime via
    -- the kv_* keys below (movement_speed 275/325/375/425, min bonus =
    -- min_movespeed_bonus_pct 25 percent of max, windup_time 1.5 --
    -- Liquipedia re-verified 2026-06-12, talent changes flow through the
    -- KV read); ramp_accel stays the lvl-4 FALLBACK for unreadable KV.
    -- The remaining wind-up comes from opts.elapsed_s (the hero stamps
    -- armed_t at charge-modifier create); unknown elapsed assumes the
    -- full windup remains (overestimates speed = fires earlier = safe).
    -- peak_speed_cap is retained as documentation but no longer consulted:
    -- the ramp DURATION bounds the end speed, and talent builds exceed the
    -- 800 guess (clamping re-introduced exactly the error this removes).
    modifier_spirit_breaker_charge_of_darkness = {
        kind                 = "homing_charge",
        speed_source         = "live_with_ramp",
        speed_fallback       = 700,   -- if NPC.GetMoveSpeed fails
        ramp_accel           = 213,   -- u/s^2 fallback (lvl 4) when KV unreadable
        ramp_windup_s        = 1.5,   -- KV windup_time fallback
        kv_ability           = "spirit_breaker_charge_of_darkness",
        kv_max_speed_key     = "movement_speed",
        kv_min_pct_key       = "min_movespeed_bonus_pct",
        kv_windup_key        = "windup_time",
        peak_speed_cap       = 800,   -- LEGACY (unused since v0.5.114)
        cast_point           = 0,
        post_cast_delay      = 0,
        impact_pos           = "self",
    },

    -- Tusk Snowball: homing carry. The snowball is a separate entity that
    -- travels at a fixed KV speed; Tusk's hero MS (NPC.GetMoveSpeed = ~310
    -- during snowball) does NOT reflect the snowball's travel speed.
    -- Canonical KV: tusk_snowball.snowball_movement_speed = 1675 (per
    -- liquipedia + KV). speed_fallback=1675 used if KV unavailable.
    -- impact_pos=self because the snowball PICKS UP the target at the
    -- target's position (does not deposit them past).
    modifier_tusk_snowball_movement = {
        kind            = "homing_carry",
        speed_source    = "kv_or_fallback",
        kv_ability      = "tusk_snowball",
        kv_speed_key    = "snowball_movement_speed",
        speed_fallback  = 1675,
        cast_point      = 0,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- PA Phantom Strike: instant blink to target. The cast point ~0.25s
    -- is the animation lock before the blink resolves; the impact (PA at
    -- target) is effectively at modifier-create. impact_pos=self because
    -- PA blinks ONTO the target and stays at melee.
    modifier_phantom_assassin_phantom_strike_target = {
        kind            = "instant_blink",
        speed_source    = "instant",
        speed_fallback  = 0,
        cast_point      = 0,  -- modifier appears post-blink; treat as instant
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- v0.5.136.1 Slice 2B realignment: Slark Pounce (leap). KV pounce_speed 933,
    -- distance 700. This catalog entry drives BOTH the generalized armer (kind=
    -- leap -> proximity fire) AND, with the hero override removed, the composed
    -- close_gap selection. modseen-confirmed: the base modifier_slark_pounce is
    -- created on Slark himself in-flight, so OnModifierCreate arms it (no anim
    -- path needed). cast_point 0 (no_target leap; the modifier IS the in-flight
    -- signal).
    modifier_slark_pounce = {
        kind            = "leap",
        speed_source    = "kv_or_fallback",
        kv_ability      = "slark_pounce",
        kv_speed_key    = "pounce_speed",
        speed_fallback  = 933,
        cast_point      = 0,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- v0.5.138 Slice 2B / v0.5.140 FIX: Huskar Life Break (leap). KV charge_speed
    -- 1200, cast range 550 (Liquipedia-verified: 1200 leap speed; pierces debuff
    -- immunity). v0.5.138 keyed this on the GUESSED name modifier_huskar_life_break
    -- and assumed the on_gap_close ANIM path would arm it (UNIT_TARGET -> target_self).
    -- The v0.5.139 DEMO DISPROVED both: `anim_gap_close_on_me` NEVER fired (the anim
    -- arming path is dead), and modseen showed the real IN-FLIGHT modifier on Huskar
    -- is modifier_huskar_life_break_CHARGE (the bare guessed name matched nothing).
    -- v0.5.140 RE-KEYS every Huskar table to _charge (the real in-flight modifier,
    -- on the ENEMY) so OnModifierCreate arms it BY PROXIMITY exactly like Slark
    -- (modifier_slark_pounce). No hero override to drop; resolves the composed
    -- close_gap chain (the _charge profile, renamed with it, drops BKB since Life
    -- Break pierces spell immunity). NOTE: the W (~0.95s lead) is inherently late for
    -- a fast short leap -- the AIRBORNE saves (WW/Eul, airborne-first backbone) are
    -- the real counter; tune the W-head injection if it mistimes. impact_pos=self
    -- (Huskar lands AT Lina); cast_point 0.3 = the leap windup.
    modifier_huskar_life_break_charge = {
        kind            = "leap",
        speed_source    = "kv_or_fallback",
        kv_ability      = "huskar_life_break",
        kv_speed_key    = "charge_speed",
        speed_fallback  = 1200,
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- v0.5.139 Slice 2B / v0.5.140 FIX: Kez Grappling Claw (pull-to-target). KV
    -- grapple_speed 1800 (Kez throws a claw projectile [3000] at an enemy; on hit he
    -- is PULLED to them at 1800). UNIT_TARGET, cast range 650-950. v0.5.139 keyed
    -- this on the VICTIM modifier modifier_kez_grappling_claw_slow (which lands on
    -- LINA -> the armer's IsEnemyHero gate fails -> it NEVER armed; the demo showed 0
    -- gap_closer_armed for kez, only a reactive _slow save -- "seems ok" but late).
    -- v0.5.140 re-keys to the real IN-FLIGHT modifier modifier_kez_grappling_claw_
    -- MOVEMENT (modseen-confirmed on Kez during the pull) so OnModifierCreate arms it
    -- on the ENEMY by proximity. The _slow profile/category stay (reactive backup); a
    -- CANONICAL_MOD_ALIAS _movement -> _slow coalesces them into ONE save (the
    -- single-spend lock) so no pre-impact + reactive double-fire. cast_point 0;
    -- impact_pos=self (Kez ends AT Lina). The projectile delay is absorbed by the
    -- proximity gate (Kez is stationary until the claw connects, then pulls in).
    modifier_kez_grappling_claw_movement = {
        kind            = "leap",
        speed_source    = "kv_or_fallback",
        kv_ability      = "kez_grappling_claw",
        kv_speed_key    = "grapple_speed",
        speed_fallback  = 1800,
        cast_point      = 0,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- v0.5.149: Techies Blast Off! (techies_suicide, KV ID 5601). KV: POINT+AOE,
    -- magical, spell_immunity enemies_no, cast_point 1.0 then a FIXED 0.75s leap
    -- (KV duration 0.75; NOT speed-based), 400 radius, 200/300/400/500 + 0.8-1.4s
    -- stun, 20% self hp_cost. The in-flight modifier_techies_suicide_leap is created
    -- on Techies at leap-start (modseen, demo closing 496->239u) -> OnModifierCreate
    -- arms it by proximity like Slark/Huskar. There is NO leap-speed KV (fixed
    -- duration), so kv_speed_key falls through to speed_fallback, set high to fire the
    -- instant airborne save EARLY inside the 0.75s window (erring early is safe for
    -- WW/Eul/Blink). Demo-tune speed_fallback from the fire distance. Resolves the
    -- composed close_gap chain (WW/Eul/Force/Pike/Blink + BKB).
    modifier_techies_suicide_leap = {
        kind            = "leap",
        speed_source    = "kv_or_fallback",
        kv_ability      = "techies_suicide",
        kv_speed_key    = "jump_speed",
        speed_fallback  = 1500,
        cast_point      = 0,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- WD Death Ward: channel at caster. 8s channel; the ward auto-attacks
    -- the target with magical damage but WD himself is stationary at his
    -- summoning position. Interrupting WD (stun) ends the channel. impact
    -- _pos=caster so the defensive W AoE is aimed at WD to stun him mid-
    -- channel. cast_point=0.5s (WD's Death Ward summon cast point).
    modifier_witch_doctor_death_ward = {
        kind            = "channel_at_caster",
        speed_source    = "instant",
        speed_fallback  = 0,
        cast_point      = 0.5,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Lion Finger of Death: cast-point-targeted single-target nuke. Cast
    -- point 0.6s (per KV / liquipedia). impact_pos=self because the
    -- damage resolves on the target.
    modifier_lion_finger_of_death = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "lion_finger_of_death",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.6,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Sniper Assassinate: cast-point-targeted ult. Cast point 2.0s (per
    -- v0.5.39 BUG-3 catalog). The 2.0s is interruptible via stun on
    -- Sniper. impact_pos=self for the damage application; defensive
    -- saves that interrupt the cast should target Sniper instead (handled
    -- separately by the existing Lotus / BKB / Aeon chain front).
    modifier_sniper_assassinate = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "sniper_assassinate",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 2.0,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Lina Laguna Blade: cast-point-targeted ult mirror to Sniper Assassinate.
    -- Cast point 0.45s (per liquipedia / KV). For Lina defending against
    -- ENEMY Lina mirror matchups. impact_pos=self.
    modifier_lina_laguna_blade = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "lina_laguna_blade",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.45,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- v0.5.66 Phase 4 slice 1: catalog the 6 CAST_POINT_THREATS modifiers
    -- previously absent from THREAT_ARRIVAL_TIMING. All cast_point_targeted
    -- shape; cast_point values mirror the CAST_POINT_THREATS.cp_default
    -- already in this file (and re-validated against liquipedia where the
    -- comment notes a check date). The v0.5.56 sync block below will dedupe
    -- cp_default from these new entries automatically.

    -- Doom: cast-point-targeted single-target silence + dot. Cast point
    -- 0.5s (KV AbilityCastPoint, liquipedia). 16s undispellable silence
    -- on the target; Lotus / BKB / Lina W stun must fire BEFORE doom lands.
    -- impact_pos=self.
    modifier_doom_bringer_doom = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "doom_bringer_doom",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.5,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- AA Ice Blast: cast-point-targeted, GLOBAL frost mark + execute.
    -- Cast point 0.5s. The mark itself lands at cast_point + projectile
    -- travel from AA to target, but at global cast range projectile time
    -- dominates -- treat as cast_point for the brain's pre-impact window
    -- since the projectile is on its own dispatch (modifier_ice_blast
    -- applies on hit). Lotus reflect / BKB pre-fire on the projectile.
    -- impact_pos=self.
    modifier_ice_blast = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "ancient_apparition_ice_blast",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.5,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- OD Sanity Eclipse: cast-point-targeted, AoE around target, mana-based
    -- magic damage. Cast point 1.7s. impact_pos=self (Lina is the catch
    -- point for the AoE; BKB / Lotus protect self).
    modifier_obsidian_destroyer_sanity_eclipse = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "obsidian_destroyer_sanity_eclipse",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 1.7,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Tinker Laser: cast-point-targeted, single-target stun + nuke + miss
    -- chance debuff. Cast point 0.45s. Range 700 base (cast range bonuses
    -- apply). impact_pos=self.
    modifier_tinker_laser = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "tinker_laser",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.45,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Zeus Thundergod's Wrath: global ult, hits every visible enemy hero.
    -- Cast point 0.6s. impact_pos=self (the damage application point is
    -- the target; defensive Lotus / BKB protect self). Side mark removes
    -- invisibility for 4s on each target.
    modifier_zuus_thundergods_wrath = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "zuus_thundergods_wrath",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.6,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Sand King Epicenter: channeled AoE expanding from SK's cast position
    -- over 2.0s (KV AbilityCastPoint, KV epicenter_radius growing per
    -- pulse). impact_pos=caster -- the AoE expands FROM Sand King's
    -- standing position, so defensive aim (e.g. Lina W stun on SK to
    -- cancel the channel) targets SK. Lotus reflect / self-BKB fire on
    -- self though; aim is a save-specific concern, this field is the
    -- "where does the threat originate" hint.
    modifier_sand_king_epicenter = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "sandking_epicenter",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 2.0,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- v0.5.67 Phase 4 slice 2: channel modifiers + fast cast-point
    -- targeted disables. Cast point values from common Dota knowledge;
    -- consumers are not yet wired (no per-mod pre-fire timing on save
    -- items), so precise values can be tuned when consumers come online.
    -- Channel modifiers use the CASTER-side modifier name (matching WD
    -- Death Ward pattern); the channel itself is what compute_arrival_time
    -- is asked about. impact_pos=caster so defensive interrupts (stun the
    -- channeler) aim at the caster.

    -- Bane Fiend's Grip: single-target channel, locks both Bane and Lina.
    -- Cast point 0.3s. 5.0/5.0/5.0s channel (longer with talent / scepter).
    -- Stunning Bane breaks the channel; Lotus reflects the projectile but
    -- not the channel itself; BKB on Lina blocks the magic damage but not
    -- the disable. impact_pos=caster (aim interrupt at Bane).
    modifier_bane_fiends_grip = {
        kind            = "channel_at_caster",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "bane_fiends_grip",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Pugna Life Drain: single-target channel, dispellable. Cast point
    -- 0.3s. Stun on Pugna ends the channel. impact_pos=caster.
    modifier_pugna_life_drain = {
        kind            = "channel_at_caster",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "pugna_life_drain",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Pudge Dismember: single-target channel, lifts the target. Cast point
    -- 0.3s. Stun on Pudge ends the channel. impact_pos=caster.
    modifier_pudge_dismember = {
        kind            = "channel_at_caster",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "pudge_dismember",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Crystal Maiden Freezing Field: PBAoE channel around CM. Cast point
    -- 0.3s. Stun on CM ends the channel. impact_pos=caster.
    modifier_crystal_maiden_freezing_field = {
        kind            = "channel_at_caster",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "crystal_maiden_freezing_field",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Enigma Black Hole: PBAoE channel around Enigma, single-disable
    -- multi-target. Cast point 0.45s. Stun on Enigma ends the channel.
    -- impact_pos=caster.
    modifier_enigma_black_hole = {
        kind            = "channel_at_caster",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "enigma_black_hole",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.45,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Disruptor Static Storm: AoE silence + damage from a thinker entity
    -- at the cast position. Disruptor himself does NOT channel post-cast;
    -- the thinker handles the AoE for 6.0s. Cast point 0.3s. The catalog
    -- key uses the THINKER modifier name (matching ENEMY_CHANNEL_MODIFIERS
    -- which lists modifier_disruptor_static_storm_thinker). Stun on
    -- Disruptor during cast point cancels; once thinker is placed it's
    -- uninterruptible. impact_pos=caster (the thinker position = where
    -- Disruptor was at cast time).
    modifier_disruptor_static_storm_thinker = {
        kind            = "channel_at_caster",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "disruptor_static_storm",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Lion Voodoo (Hex): cast-point-targeted single-target transform.
    -- Cast point 0.3s (low because Lion's other ults are 0.6s; Hex is
    -- snappy). 2.0/2.75/3.5s sheep. impact_pos=self (Lina is the target).
    modifier_lion_voodoo = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "lion_voodoo",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Bane Nightmare: cast-point-targeted single-target sleep. Cast point
    -- 0.3s. Wakes up on damage. impact_pos=self.
    modifier_bane_nightmare = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "bane_nightmare",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Faceless Void Chronosphere: AoE-at-ground stop-time. Cast point
    -- 0.4s. 4-5s freeze for everyone inside except FV (and his allies
    -- with Aghs). Defensive interrupts (stun FV during cast point) cancel
    -- the sphere. impact_pos=caster -- the sphere is centered on FV's
    -- cast position (he's typically at the center inside). Kind is
    -- cast_point_targeted as approximation; a future cast_point_aoe kind
    -- could distinguish (Sand King Epicenter is the other AoE-at-caster
    -- entry that doesn't perfectly fit this kind).
    modifier_faceless_void_chronosphere = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "faceless_void_chronosphere",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.4,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- v0.5.68 Phase 4 slice 3: homing projectiles + AoE-at-ground. 10 new
    -- entries covering common stuns / nukes / displacements that Lina's
    -- save chains care about. Cast point values from common Dota
    -- knowledge; modifier names follow canonical patterns but may need
    -- VPK-grep verification (see reference_dota_modifier_names_vpk_grep
    -- memory) when a consumer comes online. Projectiles are modeled as
    -- cast_point_targeted with cast_point covering the caster's cast
    -- point only; projectile travel is on its own dispatch (the modifier
    -- applies on hit). AoE-at-ground / AoE-at-caster keep the
    -- cast_point_targeted + impact_pos=caster workaround until a
    -- dedicated cast_point_aoe kind is added.

    -- Earthshaker Fissure: line stun emanating from ES. Cast point 0.46s.
    -- impact_pos=self (the line stun applies to targets along the line;
    -- Lina catches it if she's in it).
    modifier_earthshaker_fissure_stun = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "earthshaker_fissure",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.46,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Earthshaker Echo Slam: PBAoE stun + damage around ES, with
    -- secondary echo damage per hero hit. Cast point 0.5s. impact_pos=
    -- caster (centered on ES). Lotus reflect / pre-fire BKB protect self.
    modifier_earthshaker_echo_slam = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "earthshaker_echo_slam",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.5,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Earthshaker Earth Splitter: long-line AoE with delayed damage. Cast
    -- point 0.5s, then a ~3s post-cast delay before the line damage
    -- resolves. Aghs increases the damage tracking. impact_pos=caster
    -- (line emanates from ES). Brain has plenty of time to react during
    -- the post-cast delay; this is a rare case where post_cast_delay
    -- actually matters for save timing.
    modifier_earthshaker_earthsplitter = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "earthshaker_earth_splitter",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.5,
        post_cast_delay = 3.0,
        impact_pos      = "caster",
    },

    -- Magnus Skewer: line displacement; Magnus charges through targets
    -- pulling them with him. Cast point 0.3s. impact_pos=self (Lina is
    -- displaced if hit). Brain's pre-cast window saves are BKB / Lotus
    -- (Lotus reflect on the dispel? actually Skewer isn't dispellable so
    -- Lotus does nothing). Self-WW or Eul can dodge during cast point.
    modifier_magnataur_skewer = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "magnataur_skewer",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Magnus Reverse Polarity: PBAoE pull + 4s stun. Cast point 0.55s.
    -- impact_pos=caster (pulls all hit targets to Magnus). Pre-cast saves
    -- must fire during the 0.55s window: BKB blocks the stun; Lotus
    -- doesn't reflect; WW / Eul dodge.
    modifier_magnataur_reverse_polarity_stun = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "magnataur_reverse_polarity",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.55,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Sven Storm Bolt: homing projectile that stuns + damages target.
    -- Cast point 0.5s. Projectile travel ~1100 u/s on top of cast point.
    -- impact_pos=self. Modeled as cast_point_targeted; projectile travel
    -- is post-cast and the brain treats the threat as armed at end of
    -- cast point (mirrors AA Ice Blast pattern).
    modifier_sven_storm_bolt = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "sven_storm_bolt",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.5,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Slardar Slithereen Crush: PBAoE stun + damage around Slardar. Cast
    -- point 0.3s. impact_pos=caster.
    modifier_slardar_slithereen_crush = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "slardar_slithereen_crush",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },

    -- Lich Chain Frost: bouncing projectile, initial target + jumps. Cast
    -- point 0.45s. impact_pos=self (initial target = Lina if she's
    -- targeted). Bounces are on their own dispatch.
    modifier_lich_chain_frost = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "lich_chain_frost",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.45,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Lina Light Strike Array: delayed AoE-at-ground. Cast point 0.55s
    -- then 0.5s explosion delay (the visible "ground glow" wind-up).
    -- impact_pos=self (Lina catches it if she's in the AoE; brain may
    -- defer / dodge during the combined ~1.05s window).
    modifier_lina_light_strike_array = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "lina_light_strike_array",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.55,
        post_cast_delay = 0.5,
        impact_pos      = "self",
    },

    -- Tiny Avalanche: line/AoE damage at ground over duration. Cast point
    -- 0.3s. impact_pos=self.
    modifier_tiny_avalanche = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "tiny_avalanche",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- v0.5.69 Phase 4 slice 4: more projectiles + late-stage threats.
    -- 8 new entries. Same cast_point_targeted approximation pattern as
    -- slices 1-3 (kind taxonomy still lacks projectile_homing /
    -- cast_point_aoe variants). Cast point + modifier names from common
    -- Dota knowledge; refine when a consumer comes online and demo
    -- evidence is available.

    -- Pudge Meat Hook: skill-shot projectile that drags hit target back
    -- to Pudge. Cast point 0.3s. impact_pos=self (Lina is hooked).
    -- Pre-cast saves: BKB blocks the magic damage but NOT the drag (the
    -- hook is undispellable). Lotus reflect doesn't work. Eul / WW dodge
    -- via airborne. Best save is the W stun on Pudge during the cast
    -- point or the hook flight.
    modifier_pudge_meat_hook = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "pudge_meat_hook",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Mirana Sacred Arrow: long-range straight-line projectile, stun +
    -- damage that scales with travel distance. Cast point 0.3s.
    -- impact_pos=self (Lina is the target). BKB blocks; Lotus doesn't
    -- reflect; airborne dodge works.
    modifier_mirana_arrow = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "mirana_arrow",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Skywrath Mystic Flare: AoE-at-ground thinker that does massive
    -- damage over 2s (split across targets, full damage if alone). Cast
    -- point 0.5s. impact_pos=self (the AoE catches Lina if she's in it).
    -- Best save: BKB during cast point, OR move out of the radius
    -- (375u) during the 2s damage window.
    modifier_skywrath_mage_mystic_flare_thinker = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "skywrath_mage_mystic_flare",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.5,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Ogre Magi Fireblast: single-target projectile stun + damage. Cast
    -- point 0.4s. impact_pos=self. Multicast doubles / triples the
    -- effect on chance. BKB blocks; airborne dodge works.
    modifier_ogre_magi_fireblast = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "ogre_magi_fireblast",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.4,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Crystal Maiden Frostbite: single-target root + DoT. Cast point
    -- 0.3s. impact_pos=self. Lotus reflect works (it's a debuff).
    -- BKB blocks the magic damage AND the root.
    modifier_crystal_maiden_frostbite = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "crystal_maiden_frostbite",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Jakiro Macropyre: long line of fire damage from a thinker entity.
    -- Cast point 0.5s. impact_pos=self (Lina catches the line damage if
    -- she's in it). Move out of the line during the 7-9s damage window.
    modifier_jakiro_macropyre_thinker = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "jakiro_macropyre",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.5,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Witch Doctor Maledict: single-target curse + delayed damage burst
    -- at every 4s tick based on HP lost. Cast point 0.3s. impact_pos=
    -- self. The dispellable curse can be cleansed (BKB / Lotus / Manta);
    -- the damage bursts are the real threat and they're prophylactic.
    modifier_witch_doctor_maledict = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "witch_doctor_maledict",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Dazzle Poison Touch: chain stun + slow + damage starting on
    -- single-target. Cast point 0.3s. impact_pos=self. Dispel removes
    -- (Manta / Lotus reflect on initial cast); BKB blocks.
    modifier_dazzle_poison_touch = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "dazzle_poison_touch",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.3,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- v0.5.71 Phase 4 slice 6: Beastmaster Primal Roar + Tide Ravage.
    -- Both are LINA_SAVE_OVERRIDES targets (high-impact hard-disable ults
    -- that previously fell through to the generic lockdown chain). Adding
    -- them here so the v0.5.70 cast_point_too_early defer gate covers
    -- them with the precise catalog cast_point rather than the coarse
    -- CAST_POINT_THREATS.cp_default fallback (which neither has anyway).

    -- Beastmaster Primal Roar: line skillshot, primary target 4s stun +
    -- cone 2s slow. Cast point 0.4s. impact_pos=self (Lina is the primary
    -- target if she's at the line center). BKB blocks; airborne dodges.
    -- v0.5.73 name fix: was modifier_beastmaster_primal_roar_stun (with
    -- _stun suffix) in v0.5.71; canonical per lib THREATS_ON_SELF L417 +
    -- ABILITY_TO_THREAT L761 is the bare modifier_beastmaster_primal_roar.
    modifier_beastmaster_primal_roar = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "beastmaster_primal_roar",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.4,
        post_cast_delay = 0,
        impact_pos      = "self",
    },

    -- Tide Ravage: PBAoE 4s stun + damage centered on Tide. Cast point
    -- 0.55s. impact_pos=caster (the AoE radiates from Tide's position).
    -- BKB blocks; airborne dodges.
    modifier_tidehunter_ravage = {
        kind            = "cast_point_targeted",
        speed_source    = "instant",
        speed_fallback  = 0,
        kv_ability      = "tidehunter_ravage",
        kv_cast_point_key = "AbilityCastPoint",
        cast_point      = 0.55,
        post_cast_delay = 0,
        impact_pos      = "caster",
    },
}

-- v0.5.56: cast_point single source of truth.
-- The compute_arrival_time catalog (THREAT_ARRIVAL_TIMING) is the
-- authoritative static cast_point per threat. CAST_POINT_THREATS.cp_default
-- (the fallback used by Lina's arming sites when Ability.GetCastPoint
-- returns 0 / unavailable) is synced from there at load time so future
-- catalog edits propagate without touching two tables.
-- v0.5.66: catalog now covers all 9 CAST_POINT_THREATS entries (Phase 4
-- slice 1 added Doom + AA Ice Blast + OD Sanity Eclipse + Tinker Laser +
-- Zeus Thundergods + Sand King Epicenter, all cast_point_targeted, same
-- shape as Lion/Sniper/Lina). The sync loop now writes back to ALL nine
-- cp_default fields; no more "absent from catalog keep their literal"
-- carve-out.

---v0.5.74 lift from Lina.lua state.compute_arrival_time. Hero-agnostic;
---takes the optional kv_lookup callback for the "kv_or_fallback" speed_source
---branch (only Tusk Snowball uses it today). Heroes without a kv_lookup pass
---nil. Returns nil for any threat without a THREAT_ARRIVAL_TIMING entry;
---callers MUST fall back to legacy logic (the catalog is intentionally
---narrow; ~42 entries cover the prep-time-save-relevant subset).
---
---Why catalog over stamped (live-reactive ETA): "We have to calculate
---defensive item usage correctly when the threat is about to hit. Skills
---have a charge timing and this should be on threat data." So timing
---inputs live here as data; the math is one function call away for any
---hero that wants it.
---@param threat_mod string canonical modifier name
---@param caster userdata enemy caster
---@param target userdata defender (typically state.self_npc)
---@param modifier_handle userdata|nil  Source 2 modifier handle (for KV reads)
---@param kv_lookup fun(handle, key, fallback):any|nil  for kv_or_fallback speed
---@return number? impact_t  seconds from now until the threat lands
---@return userdata? impact_pos  where defensive AoE saves should be aimed
---@return table? entry        the catalog row
---@return number? speed       effective travel speed used in the computation
----------------------------------------------------------------------------
-- v0.5.114 precise charge-ramp kinematics (Liquipedia + KV verified)
----------------------------------------------------------------------------

---Distance a ramping charge covers over `horizon` seconds. PURE closed-form
---integration of the Charge-of-Darkness speed profile (Liquipedia: linear
---wind-up from the min bonus to the max bonus over windup_time seconds FROM
---CHARGE START, then constant; the MS cap is removed during the charge, so
---a live NPC.GetMoveSpeed read is the true ramped value):
---  speed(t) = live + accel * min(t, rem_ramp)
---  dist(T)  = live*t1 + 0.5*accel*t1^2 + (live + accel*rem_ramp)*(T - t1)
---             where t1 = min(T, rem_ramp)
---@param live     number current (ramped) speed, u/s
---@param accel    number ramp acceleration, u/s^2
---@param rem_ramp number seconds of wind-up REMAINING (0 = at peak)
---@param horizon  number seconds to integrate over
---@return number distance in units
function ThreatData.RampTravel(live, accel, rem_ramp, horizon)
    live, accel = live or 0, accel or 0
    rem_ramp = math.max(0, rem_ramp or 0)
    horizon  = math.max(0, horizon or 0)
    local t1 = math.min(horizon, rem_ramp)
    local dist = live * t1 + 0.5 * accel * t1 * t1
    if horizon > t1 then
        dist = dist + (live + accel * t1) * (horizon - t1)
    end
    return dist
end

---Exact arrival time for a ramping charge to cover `dist` units: the
---closed-form inverse of RampTravel (quadratic solve inside the ramp,
---linear after it). Returns nil when the inputs cannot ever arrive
---(zero speed and zero acceleration).
---@param live     number current (ramped) speed, u/s
---@param accel    number ramp acceleration, u/s^2
---@param rem_ramp number seconds of wind-up remaining
---@param dist     number units to cover
---@return number|nil seconds
function ThreatData.RampImpactT(live, accel, rem_ramp, dist)
    live, accel = live or 0, accel or 0
    rem_ramp = math.max(0, rem_ramp or 0)
    dist = math.max(0, dist or 0)
    if dist == 0 then return 0 end
    if live <= 0 and accel <= 0 then return nil end
    local d_ramp = live * rem_ramp + 0.5 * accel * rem_ramp * rem_ramp
    if accel > 0 and rem_ramp > 0 and dist <= d_ramp then
        -- inside the ramp: solve 0.5*a*t^2 + live*t - dist = 0 for t > 0
        return (math.sqrt(live * live + 2 * accel * dist) - live) / accel
    end
    local v_end = live + accel * rem_ramp
    if v_end <= 0 then return nil end
    return rem_ramp + (dist - d_ramp) / v_end
end

---Resolve the live ramp kinematics for a `live_with_ramp` catalog entry:
---(live, accel, rem_ramp). live = NPC.GetMoveSpeed (true ramped value; cap
---removed during charge), falling back to entry.speed_fallback. accel =
---per-LEVEL KV when resolvable: max_bonus = kv_lookup(ability,
---entry.kv_max_speed_key), min = max * min_movespeed_bonus_pct/100, accel =
---(max - min) / windup_time -- for Charge of Darkness this yields
---137.5/162.5/187.5/212.5 u/s^2 at levels 1-4 (matching the Liquipedia
---68.75->275 ... 106.25->425 wind-up over 1.5s; talents that raise the max
---bonus flow through the KV read). Falls back to entry.ramp_accel.
---rem_ramp = windup - elapsed_s clamped at 0; UNKNOWN elapsed assumes the
---full windup remains (worst case still-ramping: overestimates speed, so
---consumers fire earlier = the safe direction).
---@param entry      table  the THREAT_ARRIVAL_TIMING entry
---@param caster     any    charge caster handle
---@param kv_lookup  fun(abil, key, fallback):number|nil
---@param elapsed_s  number|nil seconds since the charge began
---@return number live, number accel, number rem_ramp
function ThreatData.ChargeRampKinematics(entry, caster, kv_lookup, elapsed_s)
    local live = (NPC.GetMoveSpeed and caster and NPC.GetMoveSpeed(caster)) or 0
    if not live or live <= 0 then live = entry.speed_fallback or 0 end
    local accel  = entry.ramp_accel or 0
    local windup = entry.ramp_windup_s or 1.5
    if kv_lookup and entry.kv_ability and NPC.GetAbility and caster then
        local okab, ab = pcall(NPC.GetAbility, caster, entry.kv_ability)
        if okab and ab then
            local maxb = kv_lookup(ab, entry.kv_max_speed_key or "movement_speed", 0)
            if maxb and maxb > 0 then
                local minpct = kv_lookup(ab, entry.kv_min_pct_key or "min_movespeed_bonus_pct", 25)
                local wkv    = kv_lookup(ab, entry.kv_windup_key or "windup_time", windup)
                if wkv and wkv > 0 then windup = wkv end
                accel = (maxb * (1 - (minpct or 25) / 100)) / windup
            end
        end
    end
    local rem = windup
    if elapsed_s and elapsed_s >= 0 then
        rem = math.max(0, windup - elapsed_s)
    end
    return live, accel, rem
end

function ThreatData.ComputeArrivalTime(threat_mod, caster, target, modifier_handle, kv_lookup, opts)
    if not (threat_mod and caster and target) then return nil end
    if not (ThreatData.THREAT_ARRIVAL_TIMING and ThreatData.THREAT_ARRIVAL_TIMING[threat_mod]) then
        return nil
    end
    if not (Entity.IsEntity and Entity.IsEntity(caster) and Entity.IsEntity(target)) then
        return nil
    end
    -- v0.5.75.1: lazy-resolve Target to break the lib/threat_data <-> lib/target
    -- circular require (see note at top-of-module forward-decl).
    Target = Target or require("lib.target")
    if not (Target.IsAlive and Target.IsAlive(caster) and Target.IsAlive(target)) then
        return nil
    end
    local entry = ThreatData.THREAT_ARRIVAL_TIMING[threat_mod]

    -- Derive effective travel speed.
    local speed = entry.speed_fallback or 0
    local ramp_live, ramp_accel_v, ramp_rem  -- v0.5.114 precise-ramp stash
    if entry.speed_source == "live_or_fallback" then
        local live = NPC.GetMoveSpeed and NPC.GetMoveSpeed(caster)
        if live and live > 0 then speed = live end
    elseif entry.speed_source == "live_with_ramp" then
        -- v0.5.114 precise ramp (replaces the v0.5.50 avg extrapolation,
        -- which carried its own stale W_LEAD=1.12 horizon, a flat lvl-4
        -- accel and a guessed peak cap): resolve the LIVE kinematics
        -- (current speed + per-level KV accel + REMAINING wind-up from
        -- opts.elapsed_s) and let the travel section below invert the
        -- exact integral (RampImpactT). The ramp DURATION bounds the end
        -- speed naturally, so the peak_speed_cap guess is no longer
        -- consulted (talent builds exceed it and clamping re-introduced
        -- the error this rewrite removes).
        ramp_live, ramp_accel_v, ramp_rem = ThreatData.ChargeRampKinematics(
            entry, caster, kv_lookup, opts and opts.elapsed_s)
        if ramp_live and ramp_live > 0 then speed = ramp_live end
    elseif entry.speed_source == "kv_or_fallback" then
        local abil
        if modifier_handle and Modifier and Modifier.GetAbility then
            local ok, a = pcall(Modifier.GetAbility, modifier_handle)
            if ok then abil = a end
        end
        if abil and entry.kv_speed_key and kv_lookup then
            speed = kv_lookup(abil, entry.kv_speed_key, speed)
        end
    elseif entry.speed_source == "instant" then
        speed = 0
    end

    -- Travel time = dist(caster, target) / speed (0 for instant kinds).
    -- v0.5.114: ramp kinds invert the exact integral instead (RampImpactT);
    -- the returned eff_speed becomes d / impact_t, the consistent average
    -- over the TRUE arrival horizon.
    local travel_t = 0
    if ramp_live then
        local cpos = Entity.GetAbsOrigin(caster)
        local tpos = Entity.GetAbsOrigin(target)
        if cpos and tpos then
            local dx = (cpos.x or 0) - (tpos.x or 0)
            local dy = (cpos.y or 0) - (tpos.y or 0)
            local d  = math.sqrt(dx * dx + dy * dy)
            local t  = ThreatData.RampImpactT(ramp_live, ramp_accel_v, ramp_rem, d)
            if t and t > 0 then
                travel_t = t
                speed    = d / t
            elseif speed > 0 then
                travel_t = d / speed
            end
        end
    elseif speed > 0 then
        local cpos = Entity.GetAbsOrigin(caster)
        local tpos = Entity.GetAbsOrigin(target)
        if cpos and tpos then
            local dx = (cpos.x or 0) - (tpos.x or 0)
            local dy = (cpos.y or 0) - (tpos.y or 0)
            local d  = math.sqrt(dx * dx + dy * dy)
            travel_t = d / speed
        end
    end

    -- Cast point (optionally KV-driven).
    local cast_pt = entry.cast_point or 0
    if entry.kv_cast_point_key then
        local abil
        if modifier_handle and Modifier and Modifier.GetAbility then
            local ok, a = pcall(Modifier.GetAbility, modifier_handle)
            if ok then abil = a end
        end
        if abil and Ability.GetCastPoint then
            local ok, v = pcall(Ability.GetCastPoint, abil, true)
            if ok and type(v) == "number" and v > 0 then cast_pt = v end
        end
    end

    local impact_t = cast_pt + travel_t + (entry.post_cast_delay or 0)

    local impact_pos
    if entry.impact_pos == "self" then
        impact_pos = Entity.GetAbsOrigin(target)
    elseif entry.impact_pos == "caster" then
        impact_pos = Entity.GetAbsOrigin(caster)
    end

    return impact_t, impact_pos, entry, speed
end
for _mod, _t in pairs(ThreatData.THREAT_ARRIVAL_TIMING) do
    local _cp_entry = ThreatData.CAST_POINT_THREATS[_mod]
    if _cp_entry and _t.cast_point and _t.cast_point > 0 then
        _cp_entry.cp_default = _t.cast_point
    end
end

----------------------------------------------------------------------------
-- THREAT_TIMING - when to fire the save relative to the threat
----------------------------------------------------------------------------

---When the hero should fire its save. Values:
---  `pre_cast`     - fire during the cast point window, BEFORE modifier lands
---                   (target invuln/immune at impact = cast fizzles)
---  `at_impact`    - fire just before threat impact (homing charges; the
---                   armed-ETA system handles this in the brain)
---  `mid_channel`  - fire any time during the channel (Dismember tick by tick)
---  `reactive`     - fire after modifier lands; the save dispels or escapes
---  `prophylactic` - pre-arm before threat manifests (rare; Doom is unfixable
---                   post-cast, so saves are pre-cast or none)
---
---These describe WHEN to fire. See THREAT_CATEGORY below for WHAT KIND of
---response is best (anti-close-gap vs threat-stopper vs etc.). Timing and
---category are independent axes - a `close_gap` threat is dispatched via
---`at_impact` timing, a `channel_on_self` threat via `mid_channel`.
---@type table<string, string>
ThreatData.THREAT_TIMING = {
    modifier_bane_nightmare              = "pre_cast",
    modifier_bane_fiends_grip            = "pre_cast",
    modifier_lion_voodoo                 = "pre_cast",
    modifier_lion_finger_of_death        = "pre_cast",
    modifier_lina_laguna_blade           = "pre_cast",
    modifier_lina_light_strike_array     = "pre_cast",   -- 0.5s delayed; act in cast point
    modifier_naga_siren_ensnare          = "pre_cast",
    modifier_doom_bringer_doom           = "pre_cast",
    modifier_pudge_dismember_pull             = "mid_channel",
    modifier_shadow_shaman_shackles      = "mid_channel",
    modifier_witch_doctor_death_ward     = "mid_channel",
    modifier_enigma_black_hole           = "mid_channel",
    modifier_crystal_maiden_freezing_field = "mid_channel",
    modifier_spirit_breaker_charge_of_darkness = "at_impact",
    modifier_tusk_snowball_movement      = "at_impact",
    modifier_kez_grappling_claw_slow          = "at_impact",  -- v6.15.162 vpk - fire as Kez swings in
    -- v6.15.163 batch 1 - modern hero pool
    modifier_ringmaster_impalement       = "pre_cast",
    modifier_marci_grapple               = "at_impact",
    modifier_muerta_dead_shot            = "pre_cast",
    modifier_primal_beast_onslaught      = "at_impact",
    modifier_dawnbreaker_celestial_hammer = "at_impact",
    modifier_hoodwink_bushwhack          = "pre_cast",
    modifier_snapfire_mortimer_kisses    = "pre_cast",
    modifier_void_spirit_aether_remnant  = "pre_cast",
    modifier_mars_spear                  = "pre_cast",
    modifier_grimstroke_ink_creature     = "reactive",
    modifier_pangolier_swashbuckle       = "at_impact",
    modifier_dark_willow_cursed_crown    = "pre_cast",
    -- v6.15.164 batch 2 - older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere_freeze  = "pre_cast",
    modifier_batrider_flaming_lasso      = "reactive",
    modifier_tiny_toss                   = "pre_cast",
    modifier_vengefulspirit_nether_swap  = "reactive",
    modifier_chaos_knight_reality_rift   = "at_impact",
    modifier_rattletrap_hookshot         = "at_impact",
    modifier_spirit_breaker_nether_strike = "at_impact",
    modifier_huskar_life_break_charge           = "at_impact",
    modifier_sandking_burrowstrike       = "pre_cast",
    modifier_nyx_assassin_impale         = "pre_cast",
    -- batch 3-4 (defense catalog refresh, 2026-05-17)
    modifier_necrolyte_reapers_scythe               = "pre_cast",
    modifier_obsidian_destroyer_sanity_eclipse      = "pre_cast",
    modifier_lich_chain_frost                       = "pre_cast",
    modifier_skywrath_mystic_flare_aura_effect             = "pre_cast",
    modifier_mars_gods_rebuke                       = "pre_cast",
    modifier_snapfire_scatterblast_slow                  = "pre_cast",
    modifier_bloodseeker_rupture                    = "pre_cast",
    modifier_obsidian_destroyer_astral_imprisonment = "pre_cast",
    modifier_skywrath_mage_ancient_seal             = "pre_cast",
    modifier_chaos_knight_chaos_bolt                = "pre_cast",
    modifier_beastmaster_primal_roar                = "pre_cast",
    modifier_shadow_demon_disruption                = "pre_cast",
    modifier_shadow_demon_demonic_purge             = "pre_cast",
    modifier_winter_wyvern_winters_curse            = "pre_cast",
    modifier_enigma_malefice                        = "reactive",
    modifier_windrunner_shackleshot                 = "pre_cast",
    modifier_morphling_adaptive_strike_agi          = "pre_cast",
    modifier_puck_waning_rift                       = "reactive",
    modifier_lich_sinister_gaze                     = "mid_channel",
    modifier_primal_beast_pulverize                 = "mid_channel",
    modifier_grimstroke_soul_chain                  = "pre_cast",
    modifier_puck_dream_coil                        = "pre_cast",
    modifier_leshrac_split_earth                    = "pre_cast",
    modifier_jakiro_ice_path                        = "pre_cast",
    modifier_mars_arena_of_blood                    = "pre_cast",
    modifier_sand_king_epicenter                     = "pre_cast",
    modifier_templar_assassin_psionic_trap          = "reactive",
    modifier_naga_siren_song_of_the_siren           = "pre_cast",
    modifier_dark_willow_terrorize                  = "pre_cast",
    modifier_dark_willow_bramble_maze               = "pre_cast",
    modifier_ringmaster_the_box                     = "reactive",
    modifier_ringmaster_wheel                       = "pre_cast",
    modifier_kez_raptor_dance                       = "pre_cast",
    modifier_void_spirit_astral_step                = "at_impact",
    modifier_pangolier_gyroshell                    = "at_impact",
    modifier_nyx_assassin_vendetta                  = "at_impact",
    modifier_pudge_meat_hook             = "at_impact",  -- when hook is in flight
    modifier_slark_pounce                = "at_impact",
    modifier_techies_suicide_leap        = "at_impact",  -- v0.5.149 Blast Off! leap
    modifier_mirana_arrow                = "at_impact",
    modifier_razor_static_link_debuff           = "reactive",
    modifier_lion_mana_drain             = "reactive",
    modifier_phantom_assassin_phantom_strike_target = "reactive",  -- already blinked
    modifier_ursa_overpower              = "reactive",
    modifier_legion_commander_duel       = "reactive",
    modifier_tusk_ice_shards_thinker     = "pre_cast",
    -- v6.7 extrapolation
    modifier_shadow_shaman_voodoo        = "pre_cast",
    modifier_zuus_lightning_bolt         = "pre_cast",
    modifier_zuus_thundergods_wrath      = "pre_cast",  -- 2s cast point - plenty of time
    modifier_tidehunter_ravage           = "pre_cast",
    modifier_earthshaker_echo_slam       = "pre_cast",
    modifier_magnataur_reverse_polarity_stun  = "pre_cast",
    modifier_disruptor_static_storm_thinker = "mid_channel",
    modifier_treant_overgrowth           = "pre_cast",
    modifier_magnataur_skewer            = "pre_cast",  -- save fires during Magnus's cast point; once grabbed, perp is useless
    modifier_sven_storm_bolt             = "at_impact",
    modifier_earth_spirit_rolling_boulder = "at_impact",
    modifier_life_stealer_open_wounds    = "reactive",
    modifier_pugna_life_drain            = "reactive",
    modifier_disruptor_kinetic_field = "reactive",  -- v6.15.10 - fires once trapped
    modifier_abyssal_underlord_pit_of_malice_ensare = "reactive",  -- v6.15.256 - fires once snared
}

----------------------------------------------------------------------------
-- THREAT_CATEGORY - semantic classification of what KIND of response wins
--
-- This is the "anti-close-gap vs threat-stopper" axis the user asked about,
-- broken out as data so the brain logs it and per-hero overrides can tune
-- by category. The flat RECOMMENDED_SAVES list still drives selection - but
-- the category tells us at a glance what RESPONSE PROFILE matters:
--
--  `close_gap`         - homing approach (Bara Charge, Tusk Snowball).
--                        Best response: cancel-on-caster (grenade-at-caster,
--                        Pike-on-Bara forced movement). Save fires during
--                        approach via armed_threats_tick.
--  `channel_on_self`   - enemy channels on Sniper (Dismember, Fiend Grip,
--                        Shackles, Death Ward). Best response: break channel
--                        (grenade-at-caster ROOT_DISABLES) OR self-dispel
--                        (Manta, Eul). Fires pre-cast via anim or reactive
--                        via OnModifierCreate.
--  `targeted_disable`  - pre-cast hard CC (Nightmare, Hex, Ensnare, Doom).
--                        Best response: invuln/immune during cast point so
--                        the cast fizzles or the modifier never lands.
--  `targeted_burst`    - high-damage targeted ult (Finger, Laguna). Best
--                        response: invuln / magic_barrier / reflect to
--                        absorb or bounce.
--  `delayed_aoe`       - AoE landing after a delay (LSA, Black Hole,
--                        Freezing Field). Best response: displacement
--                        (Pike, Force, Blink, grenade-self) - get out.
--  `line_projectile`   - dodgeable line shot (Hook, Pounce, Ice Shards,
--                        Arrow). Best response: perpendicular displacement.
--  `physical_chase`    - sustained physical pressure (PA Strike, Ursa
--                        Overpower). Best response: invis breaks target-
--                        lock, Ghost/Crimson/Blade Mail reduce/return.
--  `drain`             - resource/HP drain channels (Static Link, Mana
--                        Drain). Best response: dispel or move out of
--                        tether range.
--  `lockdown`          - forced attack-only or taunt (Duel, Berserker's
--                        Call). Best response: Satanic lifesteal-through
--                        or Blade Mail return-damage.
--
-- For the user's "separate section" question: this categorization PROVIDES
-- the separation in data without splitting code paths. Each save-issue site
-- (armed_threats_tick / anim_channel_start / OnModifierCreate / etc.) still
-- goes through `try_save_self` - the per-threat overrides in each hero's
-- SAVE_OVERRIDES table express the category-appropriate preferences.
----------------------------------------------------------------------------

---@type table<string, string>
ThreatData.THREAT_CATEGORY = {
    -- Close-gap (homing)
    modifier_spirit_breaker_charge_of_darkness = "close_gap",
    modifier_tusk_snowball_movement            = "close_gap",
    modifier_kez_grappling_claw_slow                = "close_gap",       -- v6.15.162 vpk - Kez Grappling Claw
    -- v6.15.163 batch 1 - modern hero pool
    modifier_ringmaster_impalement             = "line_projectile",
    modifier_marci_grapple                     = "close_gap",
    modifier_muerta_dead_shot                  = "targeted_disable",
    modifier_primal_beast_onslaught            = "close_gap",
    modifier_dawnbreaker_celestial_hammer      = "close_gap",
    modifier_hoodwink_bushwhack                = "delayed_aoe",
    modifier_snapfire_mortimer_kisses          = "delayed_aoe",
    modifier_void_spirit_aether_remnant        = "targeted_disable",
    modifier_mars_spear                        = "line_projectile",
    modifier_grimstroke_ink_creature           = "targeted_disable",
    modifier_pangolier_swashbuckle             = "close_gap",
    modifier_dark_willow_cursed_crown          = "targeted_disable",
    -- v6.15.164 batch 2 - older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere_freeze        = "delayed_aoe",
    modifier_batrider_flaming_lasso            = "targeted_disable",
    modifier_tiny_toss                         = "targeted_disable",
    modifier_vengefulspirit_nether_swap        = "targeted_disable",
    modifier_chaos_knight_reality_rift         = "close_gap",
    modifier_rattletrap_hookshot               = "close_gap",
    modifier_spirit_breaker_nether_strike      = "close_gap",
    modifier_huskar_life_break_charge                 = "close_gap",
    modifier_sandking_burrowstrike             = "line_projectile",
    modifier_nyx_assassin_impale               = "line_projectile",
    -- batch 3-4 (defense catalog refresh, 2026-05-17)
    modifier_necrolyte_reapers_scythe               = "targeted_burst",
    modifier_obsidian_destroyer_sanity_eclipse      = "targeted_burst",
    modifier_lich_chain_frost                       = "targeted_burst",
    modifier_skywrath_mystic_flare_aura_effect             = "delayed_aoe",
    modifier_mars_gods_rebuke                       = "targeted_burst",
    modifier_snapfire_scatterblast_slow                  = "targeted_burst",
    modifier_bloodseeker_rupture                    = "targeted_burst",
    modifier_obsidian_destroyer_astral_imprisonment = "targeted_disable",
    modifier_skywrath_mage_ancient_seal             = "targeted_disable",
    modifier_chaos_knight_chaos_bolt                = "targeted_disable",
    modifier_beastmaster_primal_roar                = "targeted_disable",
    modifier_shadow_demon_disruption                = "targeted_disable",
    modifier_shadow_demon_demonic_purge             = "targeted_disable",
    modifier_winter_wyvern_winters_curse            = "targeted_disable",
    modifier_enigma_malefice                        = "targeted_disable",
    modifier_windrunner_shackleshot                 = "targeted_disable",
    modifier_morphling_adaptive_strike_agi          = "targeted_disable",
    modifier_puck_waning_rift                       = "targeted_disable",
    modifier_lich_sinister_gaze                     = "channel_on_self",
    modifier_primal_beast_pulverize                 = "channel_on_self",
    modifier_grimstroke_soul_chain                  = "channel_on_self",
    modifier_puck_dream_coil                        = "delayed_aoe",
    modifier_leshrac_split_earth                    = "delayed_aoe",
    modifier_jakiro_ice_path                        = "delayed_aoe",
    modifier_mars_arena_of_blood                    = "delayed_aoe",
    modifier_sand_king_epicenter                     = "delayed_aoe",
    modifier_templar_assassin_psionic_trap          = "trap",
    modifier_naga_siren_song_of_the_siren           = "delayed_aoe",
    modifier_dark_willow_terrorize                  = "delayed_aoe",
    modifier_dark_willow_bramble_maze               = "delayed_aoe",
    modifier_ringmaster_the_box                     = "trap",
    modifier_ringmaster_wheel                       = "delayed_aoe",
    modifier_kez_raptor_dance                       = "delayed_aoe",
    modifier_void_spirit_astral_step                = "close_gap",
    modifier_pangolier_gyroshell                    = "close_gap",
    modifier_nyx_assassin_vendetta                  = "close_gap",
    modifier_phantom_assassin_phantom_strike_target = "close_gap",  -- already landed, but the chase profile is gap-close
    modifier_slark_pounce                      = "close_gap",       -- gap-close + leash
    modifier_techies_suicide_leap              = "close_gap",       -- v0.5.149 Blast Off! leap (combo trigger)
    -- Channel on self
    modifier_pudge_dismember_pull                   = "channel_on_self",
    modifier_bane_fiends_grip                  = "channel_on_self",
    modifier_shadow_shaman_shackles            = "channel_on_self",
    modifier_witch_doctor_death_ward           = "channel_on_self",
    -- Targeted disable (pre-cast)
    modifier_bane_nightmare                    = "targeted_disable",
    modifier_lion_voodoo                       = "targeted_disable",
    modifier_naga_siren_ensnare                = "targeted_disable",
    modifier_doom_bringer_doom                 = "targeted_disable",
    -- Targeted burst
    modifier_lion_finger_of_death              = "targeted_burst",
    modifier_lina_laguna_blade                 = "targeted_burst",
    -- Delayed AoE
    modifier_lina_light_strike_array           = "delayed_aoe",
    modifier_enigma_black_hole                 = "delayed_aoe",
    modifier_crystal_maiden_freezing_field     = "delayed_aoe",
    -- Line projectile
    modifier_pudge_meat_hook                   = "line_projectile",
    modifier_tusk_ice_shards_thinker           = "line_projectile",
    modifier_mirana_arrow                      = "line_projectile",
    -- Physical chase
    modifier_ursa_overpower                    = "physical_chase",
    -- Drain
    modifier_razor_static_link_debuff                 = "drain",
    modifier_lion_mana_drain                   = "drain",
    -- Lockdown
    modifier_legion_commander_duel             = "lockdown",
    modifier_axe_berserkers_call               = "lockdown",
    -- v6.7 extrapolation
    modifier_shadow_shaman_voodoo              = "targeted_disable",
    modifier_zuus_lightning_bolt               = "targeted_burst",
    modifier_zuus_thundergods_wrath            = "targeted_burst",
    modifier_tidehunter_ravage                 = "delayed_aoe",
    modifier_earthshaker_echo_slam             = "delayed_aoe",
    modifier_magnataur_reverse_polarity_stun        = "delayed_aoe",
    modifier_disruptor_static_storm_thinker    = "delayed_aoe",
    modifier_treant_overgrowth                 = "delayed_aoe",
    modifier_magnataur_skewer                  = "line_projectile",
    modifier_sven_storm_bolt                   = "line_projectile",
    modifier_earth_spirit_rolling_boulder      = "line_projectile",
    modifier_life_stealer_open_wounds          = "physical_chase",
    modifier_pugna_life_drain                  = "drain",
    modifier_disruptor_kinetic_field   = "trap",         -- v6.15.10
    modifier_abyssal_underlord_pit_of_malice_ensare   = "trap",         -- v6.15.256
    -- v6.15.258 zero-coverage fill batch 1
    modifier_dragon_knight_dragon_tail         = "targeted_disable",  -- v6.15.258
    modifier_night_stalker_void                = "targeted_disable",  -- v6.15.258
    modifier_ogre_magi_fireblast               = "targeted_disable",  -- v6.15.258
    modifier_rubick_telekinesis_stun                = "targeted_disable",  -- v6.15.258
    modifier_silencer_last_word                = "targeted_disable",  -- v6.15.258 (silence is a disable)
    modifier_death_prophet_silence             = "targeted_disable",  -- v6.15.258 (silence)
    -- v6.15.263 zero-coverage fill batch 2
    modifier_cold_feet      = "targeted_disable",  -- v6.15.263 (delayed stun)
    modifier_ice_blast      = "targeted_burst",    -- v6.15.263 (frost mark + magic burst, executes low HP)
    modifier_gyrocopter_homing_missile         = "line_projectile",   -- v6.15.263 (homing but dodgeable)
    modifier_kunkka_torrent_thinker            = "delayed_aoe",       -- v6.15.263 (geyser warning)
    modifier_kunkka_torrent_stun               = "targeted_disable",  -- v6.15.263 (stun applied at impact)
    modifier_kunkka_x_marks_the_spot           = "targeted_disable",  -- v6.15.263 (drag-back debuff)
    modifier_nevermore_requiem                 = "delayed_aoe",       -- v6.15.263 (fear radial)
    -- v6.15.264: ES Rolling Boulder caster-side -- routed via ENEMY_BUFF_THREATS
    modifier_earth_spirit_rolling_boulder_caster = "line_projectile",  -- v6.15.264
    -- v6.15.265 zero-coverage fill batch 3
    modifier_doom_bringer_infernal_blade       = "targeted_disable",  -- v6.15.265 (mini-stun)
    modifier_furion_sprout                     = "targeted_disable",  -- v6.15.265 (root cage)
    modifier_visage_grave_chill                = "targeted_disable",  -- v6.15.265 (slow + silence)
    modifier_venomancer_venomous_gale          = "line_projectile",   -- v6.15.265 (line aoe slow+dot)
    modifier_spectre_spectral_dagger           = "line_projectile",   -- v6.15.265 (gap-close debuff)
    -- v6.15.266 zero-coverage fill batch 4
    modifier_juggernaut_omni_slash             = "channel_on_self",   -- v6.15.266 (target-locked channel)
    modifier_phantom_lancer_spirit_lance       = "kiting_slow",       -- v6.15.266 (slow + damage proc)
    modifier_meepo_earthbind                   = "targeted_disable",  -- v6.15.266 (delayed AoE root)
    modifier_monkey_king_wukongs_command_aura  = "delayed_aoe",       -- v6.15.266 (cage area)
    modifier_slardar_amplify_damage            = "kiting_slow",       -- v6.15.266 (armor reduction setup)
    modifier_slardar_slithereen_crush          = "targeted_disable",  -- v6.15.266 (AoE stun)
    modifier_bristleback_viscous_nasal_goo         = "kiting_slow",       -- v6.15.266 (slow line)
    -- v6.15.267 zero-coverage fill batch 5
    modifier_invoker_cold_snap          = "targeted_disable",  -- v6.15.267 (recurring mini-stun)
    modifier_riki_smoke_screen                 = "targeted_disable",  -- v6.15.267 (AoE silence)
    modifier_lone_druid_spirit_bear_entangle_effect        = "targeted_disable",  -- v6.15.267 (bear attack root proc)
    modifier_undying_decay                     = "kiting_slow",       -- v6.15.267 (STR drain)
    modifier_dazzle_poison_touch               = "kiting_slow",       -- v6.15.267 (slow + dot + delayed stun)
    modifier_weaver_swarm_debuff                  = "kiting_slow",       -- v6.15.267 (armor reduction + attack proc)
    -- v6.15.268 zero-coverage fill batch 6
    modifier_alchemist_unstable_concoction     = "targeted_disable",  -- v6.15.268 (variable stun on hit)
    modifier_broodmother_sticky_snare          = "targeted_disable",  -- v6.15.268 (placed snare root)
    modifier_medusa_gorgon_grasp               = "targeted_disable",  -- v6.15.268 (point-AOE stun)
    modifier_medusa_mystic_snake               = "kiting_slow",       -- v6.15.268 (bouncing damage)
    modifier_troll_warlord_whirling_axes_slow = "targeted_disable", -- v6.15.268 (multi-axe silence)
    modifier_dark_seer_vacuum                  = "targeted_disable",  -- v6.15.268 (pull AoE)
    modifier_dark_seer_ion_shell               = "kiting_slow",       -- v6.15.268 (damage aura around target)
    modifier_ember_spirit_sleight_of_fist_caster = "kiting_slow",     -- v6.15.268 (caster phase marker)
    -- v6.15.269 zero-coverage fill batch 7
    modifier_bounty_hunter_shuriken_toss       = "kiting_slow",       -- v6.15.269 (slow + damage)
    modifier_brewmaster_cinder_brew            = "kiting_slow",       -- v6.15.269 (slow + dot AoE)
    modifier_phoenix_sun_ray                   = "kiting_slow",       -- v6.15.269 (line beam DoT)
    modifier_shredder_chakram                  = "kiting_slow",       -- v6.15.269 (line slow + disarm)
    modifier_arc_warden_flux                   = "kiting_slow",       -- v6.15.269 (isolated-target debuff)
    -- v6.15.270 final mop-up
    modifier_chen_penitence                    = "kiting_slow",       -- v6.15.270 (slow + dmg amp)
    modifier_omniknight_hammer_of_purity       = "kiting_slow",       -- v6.15.270 (autocast nuke)
    modifier_largo_catchy_lick                 = "kiting_slow",       -- v6.15.270 (Largo lick debuff)
    -- v6.15.271 ranked-match harvest
    modifier_tusk_snowball_target              = "targeted_disable",  -- v6.15.271 (root + delivery debuff)
    modifier_tusk_walrus_punch_air_time        = "targeted_disable",  -- v6.15.271 (knockup stun)
    modifier_tusk_walrus_punch_slow            = "kiting_slow",       -- v6.15.271 (post-punch slow)
    modifier_tusk_tag_team_attack_slow         = "kiting_slow",       -- v6.15.271 (passive proc slow)
    modifier_tusk_tag_team_slow                = "kiting_slow",       -- v6.15.271 (paired-attack slow)
    modifier_tiny_avalanche_stun               = "targeted_disable",  -- v6.15.271 (POINT-AOE stun)
    modifier_skywrath_mage_concussive_shot_slow = "kiting_slow",      -- v6.15.271 (slow proc)
    modifier_keeper_of_the_light_blinding_light = "targeted_disable", -- v6.15.271 (miss chance)
    modifier_blinding_light_knockback          = "line_projectile",   -- v6.15.271 (knockback marker)
    modifier_keeper_of_the_light_will_o_wisp   = "delayed_aoe",       -- v6.15.271 (delayed AoE stun ult)
    modifier_keeper_of_the_light_radiant_bind  = "targeted_disable",  -- v6.15.271 (anti-ranged disable, critical for Sniper)
    modifier_legion_commander_intimidate_slow  = "kiting_slow",       -- v6.15.271 (newer LC ability slow)
    -- v6.15.272 second-match harvest
    modifier_faceless_void_timelock_freeze     = "kiting_slow",       -- v6.15.272 (passive mini-stun proc)
    modifier_faceless_void_time_dilation_distortion = "kiting_slow",  -- v6.15.272 (slow + CD stall)
    modifier_largo_frogstomp_debuff            = "targeted_disable",  -- v6.15.272 (stomp stun)
    modifier_largo_croak_of_genius_debuff      = "kiting_slow",       -- v6.15.272
    modifier_largo_catchy_lick_knockback       = "line_projectile",   -- v6.15.272 (knockback marker)
    modifier_razor_plasma_field_slow           = "kiting_slow",       -- v6.15.272
    modifier_razor_storm_surge_slow            = "kiting_slow",       -- v6.15.272
    modifier_razor_eye_of_the_storm_armor      = "kiting_slow",       -- v6.15.272 (armor reduction)
    modifier_rubick_fade_bolt_debuff           = "kiting_slow",       -- v6.15.272
    -- v6.15.273 third-match harvest
    modifier_ancientapparition_coldfeet_freeze = "targeted_disable",  -- v6.15.273 (Cold Feet freeze phase)
    modifier_ancient_apparition_bone_chill_debuff = "kiting_slow",    -- v6.15.273 (stacking slow)
    modifier_chilling_touch_slow               = "kiting_slow",       -- v6.15.273 (attack proc slow)
    modifier_chilling_touch_super_slow         = "kiting_slow",       -- v6.15.273 (upgraded)
    modifier_ice_vortex                        = "kiting_slow",       -- v6.15.273 (AoE slow zone)
    modifier_magnataur_skewer_impact           = "targeted_disable",  -- v6.15.273 (impact stun)
    modifier_magnataur_skewer_slow             = "kiting_slow",       -- v6.15.273 (post-impact slow)
    modifier_magnataur_shockwave_pull          = "targeted_disable",  -- v6.15.273 (pull-back disable)
    modifier_snapfire_lil_shredder_debuff      = "kiting_slow",       -- v6.15.273
    modifier_snapfire_magma_burn_slow          = "kiting_slow",       -- v6.15.273
    modifier_spectre_spectral_dagger_in_path   = "kiting_slow",       -- v6.15.273 (chase marker)
    modifier_maledict                          = "kiting_slow",       -- v6.15.273 (WD Maledict mark)
    modifier_maledict_dot                      = "kiting_slow",       -- v6.15.273 (WD Maledict tick)
}

---@param threat_mod string|nil
---@return string  -- the category name, defaulting to "reactive" for unmapped
function ThreatData.CategoryOf(threat_mod)
    if not threat_mod then return "reactive" end
    return ThreatData.THREAT_CATEGORY[threat_mod] or "reactive"
end

----------------------------------------------------------------------------
-- THREAT_SEVERITY - drives CD-tier reservation logic
----------------------------------------------------------------------------

---How dangerous is this threat? Low-severity threats shouldn't burn high-CD
---saves (BKB, Aeon Disk); save those for high-severity. Values: low/medium/high.
---@type table<string, string>
ThreatData.THREAT_SEVERITY = {
    -- High: lethal disable or burst that requires a top-tier save
    modifier_bane_fiends_grip            = "high",  -- 7s lockdown + heavy damage
    modifier_bane_nightmare              = "high",  -- 7s sleep + Fiend Grip follow-up
    modifier_lion_finger_of_death        = "high",  -- 575+ magic damage
    modifier_lina_laguna_blade           = "high",
    modifier_doom_bringer_doom           = "high",  -- 12s silence
    modifier_spirit_breaker_charge_of_darkness = "high",  -- 1.7s stun + team setup
    modifier_enigma_black_hole           = "high",  -- 4s AoE channel
    modifier_legion_commander_duel       = "high",
    -- Medium: significant but recoverable
    modifier_pudge_dismember_pull             = "medium",  -- breakable channel
    modifier_lion_voodoo                 = "medium",  -- 1.5s hex
    modifier_lina_light_strike_array     = "medium",
    modifier_naga_siren_ensnare          = "medium",
    modifier_shadow_shaman_shackles      = "medium",
    modifier_tusk_snowball_movement      = "medium",
    modifier_kez_grappling_claw_slow          = "medium",  -- v6.15.162 vpk - gap-close + 80% slow + lifesteal hit
    -- v6.15.163 batch 1 - modern hero pool
    modifier_ringmaster_impalement       = "medium",
    modifier_marci_grapple               = "high",
    modifier_muerta_dead_shot            = "medium",
    modifier_primal_beast_onslaught      = "high",
    modifier_dawnbreaker_celestial_hammer = "medium",
    modifier_hoodwink_bushwhack          = "medium",
    modifier_snapfire_mortimer_kisses    = "high",
    modifier_void_spirit_aether_remnant  = "high",
    modifier_mars_spear                  = "high",
    modifier_grimstroke_ink_creature     = "medium",
    modifier_pangolier_swashbuckle       = "medium",
    modifier_dark_willow_cursed_crown    = "medium",
    -- v6.15.164 batch 2 - older-hero kidnaps / gap-closes / catches
    modifier_faceless_void_chronosphere_freeze  = "high",
    modifier_batrider_flaming_lasso      = "high",
    modifier_tiny_toss                   = "medium",
    modifier_vengefulspirit_nether_swap  = "high",
    modifier_chaos_knight_reality_rift   = "medium",
    modifier_rattletrap_hookshot         = "high",
    modifier_rattletrap_cog_marker       = "medium",  -- v0.5.147.x Power Cogs trap marker (PRIMARY). NOT "low" so the low_severity_high_hp gate never withholds the WW/Eul eat-time saves at full HP.
    modifier_rattletrap_cog_push         = "medium",  -- v0.5.147.x cog contact knockback (sibling); same tier.
    modifier_techies_land_mine_burn      = "low",     -- v0.5.149: a single mine is chip; "low" so the low_severity_high_hp gate withholds high-CD saves at full HP.
    modifier_techies_sticky_bomb_slow    = "low",     -- v0.5.149: downranked medium->low; a latched bomb is a setup slow + small nuke (not a kill alone), so low_severity_high_hp withholds WW/Eul/BKB at full HP (was burning WW reactively, and the latched slow rode the cyclone -> log _windwaker).
    modifier_techies_suicide_leap        = "high",    -- v0.5.149: Blast Off! leap is the COMBO TRIGGER (mines/sticky detonate on landing); high so it is NOT withheld -> the close_gap save fires by proximity pre-impact.
    modifier_techies_mutually_assured_destruction = "low",  -- v0.5.149: M.A.D. innate nuke chip (1.5s delay).
    modifier_techies_minefield_sign_scepter_aura  = "medium",  -- v0.5.149: Minefield Sign (Aghs) zone; medium so the escape (WW/blink/BKB) is not withheld at full HP.
    modifier_pudge_meat_hook             = "high",   -- connecting hook = lethal pull (was "low"; aligns with profile severity="lethal" + the cast-poll save). The low_severity_high_hp gate was withholding WW at full HP.
    modifier_spirit_breaker_nether_strike = "high",
    modifier_huskar_life_break_charge           = "high",
    modifier_sandking_burrowstrike       = "medium",
    modifier_nyx_assassin_impale         = "medium",
    -- batch 3-4 (defense catalog refresh, 2026-05-17)
    modifier_necrolyte_reapers_scythe               = "high",
    modifier_obsidian_destroyer_sanity_eclipse      = "high",
    modifier_lich_chain_frost                       = "high",
    modifier_skywrath_mystic_flare_aura_effect             = "high",
    modifier_mars_gods_rebuke                       = "medium",
    modifier_snapfire_scatterblast_slow                  = "medium",
    modifier_bloodseeker_rupture                    = "high",
    modifier_obsidian_destroyer_astral_imprisonment = "high",
    modifier_skywrath_mage_ancient_seal             = "medium",
    modifier_chaos_knight_chaos_bolt                = "medium",
    modifier_beastmaster_primal_roar                = "high",
    modifier_shadow_demon_disruption                = "medium",
    modifier_shadow_demon_demonic_purge             = "high",
    modifier_winter_wyvern_winters_curse            = "high",
    modifier_enigma_malefice                        = "medium",
    modifier_windrunner_shackleshot                 = "medium",
    modifier_morphling_adaptive_strike_agi          = "medium",
    modifier_puck_waning_rift                       = "medium",
    modifier_lich_sinister_gaze                     = "medium",
    modifier_primal_beast_pulverize                 = "high",
    modifier_grimstroke_soul_chain                  = "high",
    modifier_puck_dream_coil                        = "medium",
    modifier_leshrac_split_earth                    = "medium",
    modifier_jakiro_ice_path                        = "medium",
    modifier_mars_arena_of_blood                    = "high",
    modifier_sand_king_epicenter                     = "high",
    modifier_templar_assassin_psionic_trap          = "medium",
    modifier_naga_siren_song_of_the_siren           = "medium",
    modifier_dark_willow_terrorize                  = "medium",
    modifier_dark_willow_bramble_maze               = "medium",
    modifier_ringmaster_the_box                     = "medium",
    modifier_ringmaster_wheel                       = "high",
    modifier_kez_raptor_dance                       = "medium",
    modifier_void_spirit_astral_step                = "medium",
    modifier_pangolier_gyroshell                    = "high",
    modifier_nyx_assassin_vendetta                  = "medium",
    modifier_witch_doctor_death_ward     = "medium",
    modifier_crystal_maiden_freezing_field = "medium",
    modifier_phantom_assassin_phantom_strike_target = "medium",
    -- Low: annoyance, save items shouldn't burn for these alone
    -- (modifier_pudge_meat_hook moved to "high" above: a connecting hook is a lethal pull)
    modifier_slark_pounce                = "low",
    modifier_mirana_arrow                = "low",
    modifier_razor_static_link_debuff           = "low",   -- escape-by-running often viable
    modifier_lion_mana_drain             = "low",
    modifier_ursa_overpower              = "low",
    -- v6.14.1 M4: bumped to medium so the BKB-first RECOMMENDED_SAVES entry
    -- isn't reserve-penalized below the firing threshold. Berserker's Call
    -- locks a Sniper for 3s of attack-forced - BKB is the genuine answer.
    modifier_axe_berserkers_call         = "medium",
    modifier_tusk_ice_shards_thinker     = "low",
    -- v6.7 extrapolation
    modifier_zuus_thundergods_wrath      = "high",   -- global ult, can finish low-HP heroes
    modifier_tidehunter_ravage           = "high",   -- 2.5s AoE stun
    modifier_earthshaker_echo_slam       = "high",   -- AoE stun + damage scales with units in radius
    modifier_magnataur_reverse_polarity_stun  = "high",   -- 3.75s AoE stun, 1700u radius
    modifier_treant_overgrowth           = "high",   -- 5s AoE root
    modifier_disruptor_static_storm_thinker = "medium", -- channel, can walk out
    modifier_shadow_shaman_voodoo        = "medium", -- 3-4s hex
    modifier_zuus_lightning_bolt         = "low",    -- v0.5.149: low-priority nuke + ministun; "low" so the low_severity_high_hp gate withholds the high-CD saves (WW/BKB) at full HP (user: not a major skill to advert; only saves when low/lethal)
    modifier_magnataur_skewer            = "medium", -- 2.25s stun + grab
    modifier_sven_storm_bolt             = "low",    -- 1.75s stun
    modifier_earth_spirit_rolling_boulder= "medium", -- line stun, hard to dodge close-range
    modifier_life_stealer_open_wounds    = "medium", -- chase enabler; depends on Naix HP
    modifier_pugna_life_drain            = "medium", -- HP drain channel
    modifier_disruptor_kinetic_field = "high", -- v6.15.10 trap usually paired with Static Storm
    modifier_abyssal_underlord_pit_of_malice_ensare = "medium", -- v6.15.256 1.5-1.8s root, recurring; less lethal than KF
    -- v6.15.258 zero-coverage fill batch 1
    modifier_dragon_knight_dragon_tail   = "medium",  -- v6.15.258 1.7-2.75s stun, recoverable
    modifier_night_stalker_void          = "medium",  -- v6.15.258 1-2.5s stun (longer at night)
    modifier_ogre_magi_fireblast         = "medium",  -- v6.15.258 1.5-2.4s stun
    modifier_rubick_telekinesis_stun          = "medium",  -- v6.15.258 lift+land ~2.5s total disable
    modifier_silencer_last_word          = "low",     -- v6.15.258 silence -- annoying but not lethal alone
    modifier_death_prophet_silence       = "low",     -- v6.15.258 silence AOE -- locks BKB but not lethal alone
    -- v6.15.263 zero-coverage fill batch 2
    modifier_cold_feet = "medium", -- v6.15.263 4s stun if not moved
    modifier_ice_blast = "high",   -- v6.15.263 executes low-HP, hard to remove
    modifier_gyrocopter_homing_missile    = "medium", -- v6.15.263 3s stun + damage if not destroyed
    modifier_kunkka_torrent_thinker       = "medium", -- v6.15.263 1.5s warning + delayed stun
    modifier_kunkka_x_marks_the_spot      = "low",    -- v6.15.263 mostly setup for combo, dispellable
    modifier_nevermore_requiem            = "high",   -- v6.15.263 high magic damage + fear
    -- v6.15.264
    modifier_earth_spirit_rolling_boulder_caster = "medium", -- v6.15.264 1.5-2s stun on hit
    -- v6.15.265
    modifier_doom_bringer_infernal_blade  = "low",    -- v6.15.265 0.4s mini-stun per autocast
    modifier_furion_sprout                = "medium", -- v6.15.265 3-5s root, dispellable
    modifier_visage_grave_chill           = "medium", -- v6.15.265 4s slow+silence
    modifier_venomancer_venomous_gale     = "low",    -- v6.15.265 slow + dot
    modifier_spectre_spectral_dagger      = "low",    -- v6.15.265 slow + chase debuff
    -- v6.15.266
    modifier_juggernaut_omni_slash        = "high",   -- v6.15.266 4s invuln + massive damage, kill threat
    modifier_phantom_lancer_spirit_lance  = "low",    -- v6.15.266 instant slow proc
    modifier_meepo_earthbind              = "medium", -- v6.15.266 2s AoE root sets up Poof gank
    modifier_monkey_king_wukongs_command_aura = "high", -- v6.15.266 cage prevents leaving + clones attack
    modifier_slardar_amplify_damage       = "low",    -- v6.15.266 armor debuff alone, setup-only
    modifier_slardar_slithereen_crush     = "medium", -- v6.15.266 AoE stun around Slardar
    modifier_bristleback_viscous_nasal_goo    = "low",    -- v6.15.266 slow + damage line, recoverable
    -- v6.15.267
    modifier_invoker_cold_snap     = "medium", -- v6.15.267 mini-stun per damage instance
    modifier_riki_smoke_screen            = "medium", -- v6.15.267 AOE silence + miss
    modifier_lone_druid_spirit_bear_entangle_effect   = "low",    -- v6.15.267 1.5s root on bear attack proc
    modifier_undying_decay                = "low",    -- v6.15.267 temporary STR drain
    modifier_dazzle_poison_touch          = "low",    -- v6.15.267 slow + dot, dispellable
    modifier_weaver_swarm_debuff             = "low",    -- v6.15.267 armor reduction, dispellable
    -- v6.15.268
    modifier_alchemist_unstable_concoction = "high",  -- v6.15.268 4-5s stun at full charge, kill setup
    modifier_broodmother_sticky_snare      = "medium",-- v6.15.268 2s root, dispellable
    modifier_medusa_gorgon_grasp           = "medium",-- v6.15.268 point-AOE stun
    modifier_medusa_mystic_snake           = "low",   -- v6.15.268 bouncing damage, recoverable
    modifier_troll_warlord_whirling_axes_slow = "medium", -- v6.15.268 silence prevents BKB
    modifier_dark_seer_vacuum              = "medium",-- v6.15.268 pull sets up combo
    modifier_dark_seer_ion_shell           = "low",   -- v6.15.268 aura damage
    modifier_ember_spirit_sleight_of_fist_caster = "low", -- v6.15.268 informational
    -- v6.15.269
    modifier_bounty_hunter_shuriken_toss   = "low",  -- v6.15.269 slow + minor damage
    modifier_brewmaster_cinder_brew        = "low",  -- v6.15.269 slow + dot, dispel removes
    modifier_phoenix_sun_ray               = "low",  -- v6.15.269 line beam DoT, Phoenix channels
    modifier_shredder_chakram              = "low",  -- v6.15.269 slow + disarm line
    modifier_arc_warden_flux               = "low",  -- v6.15.269 isolated-target debuff
    -- v6.15.270 final mop-up
    modifier_chen_penitence                = "low",  -- v6.15.270 slow + dmg amp, dispellable
    modifier_omniknight_hammer_of_purity   = "low",  -- v6.15.270 autocast nuke proc
    modifier_largo_catchy_lick             = "low",  -- v6.15.270 lick debuff
    -- v6.15.271 ranked-match harvest
    modifier_tusk_snowball_target          = "medium", -- v6.15.271 root + setup
    modifier_tusk_walrus_punch_air_time    = "high",   -- v6.15.271 long knockup, kill setup
    modifier_tusk_walrus_punch_slow        = "low",    -- v6.15.271 post-punch slow
    modifier_tusk_tag_team_attack_slow     = "low",    -- v6.15.271 passive proc
    modifier_tusk_tag_team_slow            = "low",    -- v6.15.271
    modifier_tiny_avalanche_stun           = "medium", -- v6.15.271 1.5-1.8s stun
    modifier_skywrath_mage_concussive_shot_slow = "low",  -- v6.15.271 slow proc
    modifier_keeper_of_the_light_blinding_light = "high", -- v6.15.271 miss chance destroys Sniper right-clicks
    modifier_blinding_light_knockback      = "low",    -- v6.15.271 informational
    modifier_keeper_of_the_light_will_o_wisp = "high", -- v6.15.271 delayed AoE stun ult
    modifier_keeper_of_the_light_radiant_bind = "high", -- v6.15.271 anti-ranged disable, anti-Sniper
    modifier_legion_commander_intimidate_slow = "low", -- v6.15.271 slow proc
    -- v6.15.272 second-match harvest
    modifier_faceless_void_timelock_freeze     = "low",    -- v6.15.272 passive proc
    modifier_faceless_void_time_dilation_distortion = "medium", -- v6.15.272 CD stall + slow
    modifier_largo_frogstomp_debuff            = "medium", -- v6.15.272 stomp stun
    modifier_largo_croak_of_genius_debuff      = "low",    -- v6.15.272
    modifier_largo_catchy_lick_knockback       = "low",    -- v6.15.272
    modifier_razor_plasma_field_slow           = "low",    -- v6.15.272
    modifier_razor_storm_surge_slow            = "low",    -- v6.15.272 ms-trade
    modifier_razor_eye_of_the_storm_armor      = "low",    -- v6.15.272 armor reduction
    modifier_rubick_fade_bolt_debuff           = "low",    -- v6.15.272
    -- v6.15.273 third-match harvest
    modifier_ancientapparition_coldfeet_freeze = "medium", -- v6.15.273 freeze phase stun
    modifier_ancient_apparition_bone_chill_debuff = "low", -- v6.15.273
    modifier_chilling_touch_slow               = "low",    -- v6.15.273
    modifier_chilling_touch_super_slow         = "low",    -- v6.15.273
    modifier_ice_vortex                        = "low",    -- v6.15.273
    modifier_magnataur_skewer_impact           = "high",   -- v6.15.273 long stun, kill setup
    modifier_magnataur_skewer_slow             = "low",    -- v6.15.273
    modifier_magnataur_shockwave_pull          = "medium", -- v6.15.273
    modifier_snapfire_lil_shredder_debuff      = "low",    -- v6.15.273
    modifier_snapfire_magma_burn_slow          = "low",    -- v6.15.273
    modifier_spectre_spectral_dagger_in_path   = "low",    -- v6.15.273
    modifier_maledict                          = "medium", -- v6.15.273 setup for pickoff burst
    modifier_maledict_dot                      = "low",    -- v6.15.273
}

----------------------------------------------------------------------------
-- SAVE_COOLDOWN_TIER - reserve-the-good-stuff logic
----------------------------------------------------------------------------

---Save items by CD tier. High-tier saves (long CD, big effect) get a -score
---penalty when the threat is low-severity, so the brain reserves them for
---genuine emergencies. low/medium/high.
---@type table<string, string>
-- v6.7 (2026-05-11): cooldown tier audit against Liquipedia 7.41C.
--   Wind Waker 60s → 19s (low tier now, was medium)
--   Blade Mail 16s → 25s (medium tier now, was low)
--   item_eternal_shroud REMOVED from game in 7.41 - entry deleted.
--   Lotus Orb "limited charges" comment stale (charge system removed; 15s CD).
ThreatData.SAVE_COOLDOWN_TIER = {
    -- Existing self-protection / dispel
    item_cyclone        = "low",     -- 23s CD
    item_glimmer_cape   = "low",     -- 15s CD
    item_force_staff    = "low",     -- 19s CD
    item_hurricane_pike = "low",     -- 19s CD
    grenade_self        = "low",     -- 10s CD (Sniper grenade)
    grenade_at_caster   = "low",     -- shares grenade slot (10s CD)
    item_manta          = "medium",  -- 34s CD
    item_lotus_orb      = "medium",  -- 15s CD (no charge system in 7.41)
    item_satanic        = "medium",  -- 30s CD
    item_black_king_bar = "high",    -- 95s CD (7.41B)
    item_aeon_disk      = "high",    -- 105/125/145/165s scaling
    -- New items
    item_wind_waker     = "low",     -- 19s CD (was 60s in earlier patch)
    item_pipe = "medium", -- 60s CD, team buff
    item_crimson_guard  = "medium",  -- 40s CD
    item_blade_mail     = "medium",  -- 25s CD, 5.5s duration, 85% reflect
    item_ghost          = "low",     -- 22s CD
    item_solar_crest    = "low",     -- 16s CD
    item_disperser      = "low",     -- 12s CD
    item_diffusal_blade = "low",     -- 12s CD
    item_blink          = "low",     -- 12s CD
    item_swift_blink    = "low",     -- 15s CD
    item_arcane_blink   = "low",     -- 12s CD
    item_overwhelming_blink = "low", -- 15s CD
    item_phase_boots    = "low",     -- 5s CD
}

----------------------------------------------------------------------------
-- Pure helpers - no side effects, no entity introspection
----------------------------------------------------------------------------

---Returns true iff `save_name`'s kinds intersect the threat's counter list.
---When `threat_mod` is nil (no filter requested) returns true.
---Unknown saves / threats also return true (allow rather than reject -
---defensive default for not-yet-mapped cases).
---@param save_name  string   key into SAVE_KIND
---@param threat_mod string|nil  modifier name (key into THREAT_COUNTER)
---@return boolean
---Derive the set of counter-kinds from a threat profile (pure; no game APIs).
---Implements Lina/THREAT_COUNTER_AXIS_RULE_REVIEW.md "corrected DeriveCounters rule set".
---Facts: school(magical|physical|pure), damage_type, pierces_spell_immunity
---(true|false|"partial"), dispellable(none|basic|strong), delivery(spell|channel|
---projectile_line|projectile_homing|homing_charge|leap|line_charge|attack), targeted,
---positional, primary_harm(damage|disable|displacement), timing(pre_cast|at_impact|
---mid_channel|reactive|post_apply), forced_leash, debuff_sticks_to_self,
---blocks_forced_movement, lotus_reflectable(default true). Optional per-entry:
---zone_outlasts_cyclone, already_locked_channel, enemy_self_buff, attack_enabler,
---severity, drop_kinds, add_kinds.
---@param p table profile
---@return string[] kinds (insertion-ordered, deduped)
function ThreatData.DeriveCounters(p)
    local set, order = {}, {}
    local function add(k) if not set[k] then set[k] = true; order[#order + 1] = k end end
    local function drop(k)
        if set[k] then
            set[k] = nil
            for i = #order, 1, -1 do if order[i] == k then table.remove(order, i) end end
        end
    end

    local pierces_full = (p.pierces_spell_immunity == true)  -- 'partial'/false do NOT suppress
    local spell_set = { spell = true, channel = true, projectile_line = true,
        projectile_homing = true, homing_charge = true, leap = true, line_charge = true }

    -- UNIVERSAL: invuln only, gated off latched / already-applied threats
    local latched = (p.delivery == "projectile_homing" or p.delivery == "homing_charge")
    local zone_outlasts = (p.positional and p.zone_outlasts_cyclone)
    if p.timing == "pre_cast" or (p.timing == "at_impact" and not latched) then
        if not zone_outlasts and not p.forced_leash then add("invuln") end
    end

    -- MAGICAL-SCHOOL MITIGATION (decoupled from damage_type)
    if p.school == "magical" and spell_set[p.delivery] then
        if not pierces_full and p.timing ~= "mid_channel" then add("magic_immune") end
    end
    if p.damage_type == "magical" and p.primary_harm == "damage" then
        add("magic_barrier")
        if p.severity == "survivable" then add("magic_resist") end
    end
    -- PURE: no damage-mitigation kind (dodge/dispel/reflect from sibling branches)

    -- PHYSICAL (attack-delivered)
    if p.school == "physical" and p.delivery == "attack" then
        add("physical_immune"); add("damage_block")
        if not p.forced_leash and not p.already_locked_channel then add("invis") end
        -- damage_return: per-entry add_kinds only (net loss vs self-attack ults)
        if not p.forced_leash and not p.debuff_sticks_to_self then
            add("displacement_far"); add("displacement_perp")
        end
    end

    -- REMOVAL (dispel) -- only when the debuff is present at the save window.
    -- The spec's primary_harm filter {disable,dot,slow,silence,root} collapses
    -- to "not displacement" under our coarse 3-value primary_harm enum: dispel
    -- helps for disable AND damage (DoTs are removable), but cannot counter a
    -- knockback/pull (primary_harm=="displacement"). Pure instant burst is
    -- already excluded since it leaves no dispellable residual (dispellable=
    -- "none"); per-threat drop_kinds covers any remaining edge case.
    local debuff_present = (p.timing == "mid_channel" or p.timing == "reactive"
                            or p.timing == "post_apply")
    local dispel_ok = (p.dispellable ~= "none" and p.dispellable ~= nil
        and debuff_present and p.primary_harm ~= "displacement"
        and not p.enemy_self_buff and not p.attack_enabler)
    if dispel_ok then
        if p.dispellable == "basic" then add("dispel_basic"); add("dispel_strong")
        elseif p.dispellable == "strong" then add("dispel_strong") end
    end

    -- REFLECT (Lotus) -- cast-time single-target spell harm only
    if p.targeted and (p.lotus_reflectable ~= false) and p.delivery == "spell"
       and (p.school == "magical" or p.school == "pure")
       and (p.primary_harm == "damage" or p.primary_harm == "disable")
       and p.timing == "pre_cast" then
        add("reflect_target")
    end

    -- DELIVERY-SPECIFIC DODGE / DISPLACEMENT
    if p.delivery == "projectile_line" or p.delivery == "line_charge" then
        add("displacement_perp"); add("displacement_far"); add("displacement_blink")
    elseif p.delivery == "projectile_homing" then
        add("displacement_blink")
    elseif p.delivery == "homing_charge" then
        add("displacement_at_source"); add("displacement_perp")
    elseif p.delivery == "leap" then
        -- v0.5.143: a leap lands ON the target, so being untargetable/invulnerable
        -- at impact whiffs it -- DEMO-PROVEN hero-agnostically (v0.5.142: Lina
        -- WW-dodged Huskar Life Break; modifier_huskar_life_break_slow never
        -- landed). add("invuln") EXPLICITLY here so EVERY leap keeps the airborne
        -- save (WW/Eul) for EVERY hero, regardless of timing -- the universal rule
        -- above only adds invuln for pre_cast/at_impact, so a future leap with any
        -- other timing would silently lose the dodge. Guarded by not forced_leash
        -- (a leashing leap is not escaped by going airborne; the leash reapplies),
        -- matching the universal rule's exclusion so current leap profiles stay
        -- byte-equal. displacement_perp (sidestep) + displacement_blink
        -- (distance-cancel: Liquipedia "distance > leap range cancels the leap")
        -- are the displacement nullifiers.
        if not p.forced_leash then add("invuln") end
        add("displacement_perp"); add("displacement_blink")
    end

    if p.delivery == "channel" then
        add("channel_break"); add("displacement_at_source")
        if not p.positional then
            add("displacement_far"); add("displacement_perp"); add("displacement_blink")
        end
    end

    -- positional / placed AoE zones (incl. AoE channels). Use `not p.targeted`
    -- (nil-safe) NOT `== false`: profiles omit default-false booleans, so a
    -- non-targeted threat has p.targeted == nil, and `nil == false` is false.
    if (p.delivery == "spell" or p.delivery == "channel")
       and not p.targeted and p.positional then
        add("displacement_perp"); add("displacement_far")
        if not p.blocks_forced_movement then add("displacement_blink")
        else add("displacement_perp") end
    end

    -- per-entry overrides applied LAST
    if p.drop_kinds then for _, k in ipairs(p.drop_kinds) do drop(k) end end
    if p.add_kinds  then for _, k in ipairs(p.add_kinds)  do add(k)  end end
    return order
end


-- Assemble THREAT_COUNTER from THREAT_PROFILE via the pure DeriveCounters. Runs at
-- module load AFTER DeriveCounters is defined and BEFORE `return ThreatData`, so any
-- consumer that captures `TD.THREAT_COUNTER` at require-time (e.g. Sniper.lua) gets the
-- fully populated table. Threats with a profile are constrained; those without remain
-- unlisted (unconstrained) exactly as before.
ThreatData.THREAT_COUNTER = {}
for _mod, _profile in pairs(ThreatData.THREAT_PROFILE) do
    ThreatData.THREAT_COUNTER[_mod] = ThreatData.DeriveCounters(_profile)
end

function ThreatData.SaveCounters(save_name, threat_mod)
    if not threat_mod then return true end
    local kinds = ThreatData.SAVE_KIND[save_name]
    local needs = ThreatData.THREAT_COUNTER[threat_mod]
    if not kinds or not needs then return true end
    for _, k in ipairs(kinds) do
        for _, n in ipairs(needs) do
            if k == n then return true end
        end
    end
    return false
end

---Returns true iff a displacement save will plausibly break the tether,
---given the current sniper-to-caster distance. Best case assumes the push
---is directly away from the caster (the chain's job is to issue the right
---direction). For non-displacement saves (push distance not registered)
---or threats without tether ranges, returns true (not constrained).
---@param save_name string         key into SAVE_KIND / SAVE_PUSH_DISTANCE
---@param threat_mod string|nil    modifier name (key into THREAT_TETHER_RANGE)
---@param distance number|nil      current dist(caster, self) in units
---@return boolean
function ThreatData.WillTetherBreak(save_name, threat_mod, distance)
    local push = ThreatData.SAVE_PUSH_DISTANCE[save_name]
    if not push or push == 0 then return true end
    local tether = ThreatData.THREAT_TETHER_RANGE[threat_mod or ""]
    if not tether then return true end
    if not distance then return true end  -- distance unknown → allow (conservative)
    return (distance + push) > tether
end

---Returns the recommended save-priority list for a threat, or nil if the
---threat has no specific recommendation (caller falls back to its default
---chain).
---@param threat_mod string|nil
---@return string[]|nil
function ThreatData.RecommendedSaves(threat_mod)
    if not threat_mod then return nil end
    return ThreatData.RECOMMENDED_SAVES[threat_mod]
end

---Returns the timing classification for a threat (`pre_cast`, `at_impact`,
---`mid_channel`, `reactive`, `prophylactic`). Default `reactive` for unmapped.
---@param threat_mod string|nil
---@return string
function ThreatData.TimingFor(threat_mod)
    if not threat_mod then return "reactive" end
    return ThreatData.THREAT_TIMING[threat_mod] or "reactive"
end

---Returns the severity classification (`low`, `medium`, `high`). Default
---`medium` for unmapped.
---@param threat_mod string|nil
---@return string
function ThreatData.SeverityOf(threat_mod)
    if not threat_mod then return "medium" end
    return ThreatData.THREAT_SEVERITY[threat_mod] or "medium"
end

---Score-penalty for firing a high-CD save against a low-severity threat.
---Returns a negative number to subtract from save score. Brain combines
---this with the kind-match bonus to pick the optimal save.
---@param save_name string
---@param threat_mod string|nil
---@return number  -- 0, -10, or -25
function ThreatData.SaveReservePenalty(save_name, threat_mod)
    local tier = ThreatData.SAVE_COOLDOWN_TIER[save_name]
    if not tier then return 0 end
    local sev = ThreatData.SeverityOf(threat_mod)
    if tier == "high" and sev == "low" then return -25 end
    if tier == "high" and sev == "medium" then return -10 end
    if tier == "medium" and sev == "low" then return -5 end
    return 0
end

----------------------------------------------------------------------------
-- v6.13 Defense F#12 - ENEMY_BUFF_THREATS
--
-- Buffs that the ENEMY casts on themselves which threaten Sniper. Distinct
-- from THREATS_ON_SELF (debuffs on Sniper). OnModifierCreate routes here
-- when `npc != self` and the modifier name matches. The brain then fires
-- a Sniper-side defensive response (typically physical-chase counters:
-- Ghost form, Blade Mail, Crimson Guard, Glimmer, displacement).
--
-- `category`: free-form tag for diagnostic logs.
-- `role`: which counter-kinds to prefer (drives RECOMMENDED_SAVES override).
-- `severity`: scales reserve penalty just like THREATS_ON_SELF entries.
--
-- Modifier names are guess-extrapolated from npc_abilities.json suffix
-- conventions; flag as `verify=true` until in-game `:FindAllModifiers()`
-- confirms (use the v6.13 `modseen` diagnostic at verbosity 3).
----------------------------------------------------------------------------
ThreatData.ENEMY_BUFF_THREATS = {
    modifier_bristleback_quill_spray_stack = {
        category = "physical_chase_buff", role = "physical_burst",
        severity = "medium", verify = true,
    },
    modifier_sven_gods_strength = {
        category = "physical_chase_buff", role = "physical_burst",
        severity = "high",   verify = true,
    },
    modifier_troll_warlord_battle_trance = {
        category = "physical_chase_buff", role = "physical_burst",
        severity = "high",   verify = true,
    },
    modifier_ursa_enrage = {
        category = "physical_chase_buff", role = "physical_burst",
        severity = "high",   verify = true,
    },
    -- Silver Edge break = passive (Headshot) disabled. Informational -
    -- offense DPS estimate over-counts when broken; no defense action.
    modifier_item_silver_edge_debuff = {
        category = "passive_break", role = "informational",
        severity = "low",    verify = true,
    },
    -- v6.15.264: Earth Spirit Rolling Boulder. The caster-side modifier
    -- appears on ES when the boulder is rolling. Sniper-side modifier
    -- from boulder hit is generic modifier_stunned (uncatchable). The
    -- anim path doesn't fire reliably (POINT cast with 0 cast point, no
    -- AbilityCastAnimation slot). Caster-side modifier dispatch is the
    -- only reliable detector -- when ES is rolling, fire the
    -- line_projectile chain (force / pike / grenade-self) to evade
    -- regardless of whether Sniper is currently in the boulder line.
    -- Worst case is wasted CD if the boulder rolls elsewhere; the
    -- alternative is getting stunned with no save.
    modifier_earth_spirit_rolling_boulder_caster = {
        category = "line_projectile", role = "line_projectile",
        severity = "medium",
    },
    -- v6.15.270: Centaur Stampede + Lycan Howl. Team-buff ults that
    -- enable enemy team to gank Sniper (Stampede: global MS + phasing;
    -- Howl: team damage buff). Sniper response: defensive item or
    -- reposition; informational-grade since saves don't directly cancel
    -- the buff, but the brain should be on alert.
    modifier_centaur_stampede = {
        category = "team_mobility_buff", role = "informational",
        severity = "medium", verify = true,
    },
    modifier_lycan_howl = {
        category = "team_damage_buff", role = "informational",
        severity = "medium", verify = true,
    },
}

----------------------------------------------------------------------------
-- v6.13 Cross F#7 - derived ESCAPE_ITEM_NAMES
--
-- Single source of truth: a target's "escape items" are exactly the items
-- in SAVE_KIND that carry one of {invuln, dispel_basic, dispel_strong,
-- reflect_target, magic_immune}. Previously lib/target.lua hardcoded a
-- parallel list that
-- drifted when SAVE_KIND changed (v6.7 BKB gained dispel_basic; Diffusal/
-- Disperser carry dispel_basic but weren't in target.lua's list).
--
-- Derived at module-load time. SAVE_KIND is data - adding a new save here
-- automatically updates the escape-window detection.
----------------------------------------------------------------------------
do
    local ESCAPE_KINDS = {
        invuln = true, dispel_basic = true, dispel_strong = true,
        reflect_target = true, magic_immune = true,
    }
    local names = {}
    for save_name, kinds in pairs(ThreatData.SAVE_KIND) do
        if save_name:sub(1, 5) == "item_" then
            for _, k in ipairs(kinds) do
                if ESCAPE_KINDS[k] then
                    names[#names + 1] = save_name
                    break
                end
            end
        end
    end
    ThreatData.ESCAPE_ITEM_NAMES = names
end

-- Pudge Dismember puts TWO modifiers on the victim: modifier_pudge_dismember
-- and modifier_pudge_dismember_pull (the pull component). A field test showed
-- both land, so the catalog (keyed on the harvested _pull name) must also
-- answer to the bare name. Mirror every modifier-keyed table entry onto it.
for _, t in pairs(ThreatData) do
    if type(t) == "table" and t.modifier_pudge_dismember_pull ~= nil then
        t.modifier_pudge_dismember = t.modifier_pudge_dismember_pull
    end
end

-- v0.5.35: Target-side spell-deflect modifiers. When the R target has any of
-- these active, the brain MUST refuse R (the cast reflects damage back). This
-- is OFFENSIVE-side guarding (hero-as-attacker), distinct from THREATS_ON_SELF
-- (hero-as-defender). Lotus stays out of this table - Target.HasReadyLotus is
-- engine-side and already filtered by r_target_blocked (Lina.lua:2178).
-- Add a new entry only when (a) the modifier name is VPK-verified per lesson
-- 13, and (b) the effect reflects damage back to the caster (not merely
-- absorbs or dispels - those are separate concerns).
ThreatData.SPELL_DEFLECT_MODIFIERS = {
    modifier_nyx_assassin_spiked_carapace = true,
}

-- v0.5.152: targets that CANNOT be killed right now, so the brain must not waste a
-- kill combo on them and should prefer a killable target. Modifier-on-target rules
-- only (WK Reincarnation has NO off-cooldown modifier; it is an ability-readiness
-- check in lib/target.lua Target.WillReincarnate). Verified: modifier_dazzle_shallow_grave
-- is VPK-confirmed (sets min HP to 1). The bare modifier_oracle_false_promise is
-- C++-only (no VPK KV string) but DOES land on the target -- modseen-confirmed
-- 2026-06-17 (unit=sniper mod=modifier_oracle_false_promise caster=oracle), so the
-- redundant _timer variant was pruned. Iterated by Target.HasUnkillableModifier.
ThreatData.UNKILLABLE_MODIFIERS = {
    modifier_dazzle_shallow_grave = true,
    modifier_oracle_false_promise = true,
}

----------------------------------------------------------------------------
-- v0.5.40 TIER 0 (A2): canonical-modifier-name resolution
--
-- The Dispatcher's per-threat lock domain (lib/defense.lua v0.5.40) keys on
-- the tuple (target_idx, canonical_mod, caster_idx) per v0.5.14 BL-A5/BL-B7.
-- An engine threat often ships SIBLING modifiers that name the same threat
-- instance (Bara Charge applies both modifier_spirit_breaker_charge_of_darkness
-- on the caster AND modifier_spirit_breaker_charge_of_darkness_vision /
-- _target on the victim; Tusk Snowball stamps _movement on the carrier AND
-- _target on the victim; PA Phantom Strike stamps _target on the victim while
-- the catalog keys on _target itself). Two different sibling names landing
-- within the lock window for the SAME engagement must hash to the SAME lock
-- key, or the second sibling silently bypasses the lock and double-fires.
--
-- v0.5.39 demo failure modes that motivated this:
--   (1) Bara Charge double-fire (WW via on_gap_close anim hits with the bare
--       canonical name, Pike via armed_threats_tick homing branch hits with
--       _vision). With sibling-collapse both route through the same
--       (target_idx, modifier_spirit_breaker_charge_of_darkness, caster_idx)
--       lock; the second arm sees dispatcher_lock_skip.
--   (2) Sniper Assassinate second-save: the lotus_pending:* slot and the
--       castpt:* slot in armed_threats_tick reference the same engagement; if
--       a sibling spelling ever leaked the locks would diverge.
--
-- Canonical names match the existing CATALOG KEYS (LINA_SAVE_OVERRIDES,
-- CAST_POINT_THREATS, THREATS_ON_SELF, RECOMMENDED_SAVES). Aliases are the
-- sibling modifiers that should fold INTO the catalog key for lock-domain
-- purposes. The catalog keys themselves are identity entries (covered by the
-- nil-fallback in CanonicalMod -- no need to enumerate them).
--
-- Source-of-truth markers in comments:
--   vpk     -- confirmed via grep against pak01_*.vpk
--   audit   -- LINA_DEFER_TO_ARMED (Lina.lua L728-741) or other in-tree usage
--   manual  -- known-pair from threat catalog ownership, no separate VPK hit
----------------------------------------------------------------------------

---@type table<string, string>
ThreatData.CANONICAL_MOD_ALIASES = {
    -- Spirit Breaker Charge of Darkness. Canonical = the bare name (matches
    -- LINA_SAVE_OVERRIDES key and ABILITY_TO_THREAT value).
    -- vpk: pak01_009 ships modifier_spirit_breaker_charge_of_darkness,
    --      _debuff, _target as engine-visible names.
    -- audit: Lina.lua LINA_DEFER_TO_ARMED L730 maps _vision -> "bara_charge",
    --        confirming _vision is a real victim-side sibling the brain sees.
    modifier_spirit_breaker_charge_of_darkness_vision = "modifier_spirit_breaker_charge_of_darkness",  -- audit
    modifier_spirit_breaker_charge_of_darkness_target = "modifier_spirit_breaker_charge_of_darkness",  -- vpk
    modifier_spirit_breaker_charge_of_darkness_debuff = "modifier_spirit_breaker_charge_of_darkness",  -- vpk

    -- Tusk Snowball. Canonical = _movement (LINA_SAVE_OVERRIDES key,
    -- ABILITY_TO_THREAT value, RECOMMENDED_SAVES key). _target is the
    -- victim-side root-on-impact debuff; _movement_friendly is the carried-ally
    -- variant (Lina-as-ally; lock-domain irrelevant but folded for safety).
    -- audit: Lina.lua LINA_DEFER_TO_ARMED L729 maps _target -> "tusk_snowball".
    -- vpk: pak01_009 ships _movement_friendly. Canonical _movement itself is
    -- field-validated (THREATS_ON_SELF, ABILITY_TO_THREAT) rather than direct
    -- VPK-grep-validated; engine-vs-VPK distinction documented per verifier.
    modifier_tusk_snowball_target              = "modifier_tusk_snowball_movement",  -- audit
    modifier_tusk_snowball                     = "modifier_tusk_snowball_movement",  -- manual (bare-name guard)

    -- Sand King Burrowstrike. Canonical = modifier_sandking_burrowstrike
    -- (THREATS_ON_SELF, ABILITY_TO_THREAT value). The LANDED victim-side stun
    -- keeps the pre-rework legacy name modifier_sandking_impale (harvested
    -- 2026-07-13, Tinker run-75 threat_unrecognized x11; KV has NO
    -- sandking_impale ability - the kit ability is sandking_burrowstrike, so
    -- the mod name is a Valve legacy leftover). Folding it buckets the
    -- projectile-phase and landed-phase locks correctly (a save fired on the
    -- line intercept suppresses a double dispatch when the stun lands).
    modifier_sandking_impale                   = "modifier_sandking_burrowstrike",  -- harvest + KV-absence

    -- Jakiro Ice Path. Canonical = modifier_jakiro_ice_path (THREATS_ON_SELF,
    -- ABILITY_TO_THREAT value; the zone/delay mod). The LANDED victim-side stun
    -- is _stun (harvested 2026-07-14, Tinker run-77 x10; no dedicated profile,
    -- so the fold inherits the canonical's - same threat, two phases).
    modifier_jakiro_ice_path_stun              = "modifier_jakiro_ice_path",       -- harvest

    -- v0.5.140 Kez Grappling Claw. Canonical = _slow (the victim-side debuff that
    -- carries the harm profile + categorized close_gap + works reactively). The
    -- IN-FLIGHT _movement modifier (on Kez during the pull, modseen-confirmed) is
    -- what OnModifierCreate ARMS (THREAT_ARRIVAL_TIMING keyed on _movement), so
    -- alias it to _slow -> the pre-impact armed dispatch + the reactive _slow save
    -- share ONE single-spend lock (no double-fire).
    modifier_kez_grappling_claw_movement       = "modifier_kez_grappling_claw_slow",  -- v0.5.140 in-flight -> victim canonical
    modifier_tusk_snowball_movement_friendly   = "modifier_tusk_snowball_movement",  -- vpk

    -- PA Phantom Strike. Canonical = _target (catalog key, anim-stamp target).
    -- audit: Lina.lua LINA_DEFER_TO_ARMED L740 maps _target -> instant_blink arm,
    -- confirming _target IS the canonical the brain reasons in.
    -- The bare modifier_phantom_assassin_phantom_strike does NOT exist as a
    -- separate engine modifier (pak01 grep returns only the aghsfort variant);
    -- entry kept as defensive guard for any future engine rename.
    modifier_phantom_assassin_phantom_strike   = "modifier_phantom_assassin_phantom_strike_target",  -- manual

    -- Pudge Dismember. Canonical = _pull (LINA_SAVE_OVERRIDES key, the pull
    -- component is what the brain saves against). The legacy bare-name folder
    -- earlier in this file (the `for _, t in pairs(ThreatData)` loop targeting
    -- modifier_pudge_dismember_pull at L2144) handles catalog mirroring; here
    -- we collapse the lock-domain side too.
    -- vpk: pak01 ships modifier_pudge_dismember (bare) and _pull.
    modifier_pudge_dismember                   = "modifier_pudge_dismember_pull",    -- vpk

    -- Bane Fiends Grip. Canonical = bare. VPK sweep (pak01_009) finds the
    -- bare canonical; no _cast_illusion sibling reproducible in the current
    -- build. No fold today; add here with a 'manual' marker if the engine
    -- grows an illusion-side stamp.

    -- Legion Commander Duel. Canonical = bare. _damage_boost is the post-duel
    -- winner stamp (caster-side); only present here so an accidental brain-side
    -- detector folds correctly.
    -- vpk: pak01_009 ships _damage_boost.
    modifier_legion_commander_duel_damage_boost = "modifier_legion_commander_duel",  -- vpk

    -- Earthshaker Fissure (modifier_earthshaker_fissure_stun +
    -- modifier_fissure_rooted, both ship in pak01_009): NOT a Lina-defended
    -- threat today (no THREATS_ON_SELF entry, no RECOMMENDED_SAVES chain).
    -- An alias-only pairing would strand the lock_key; catalog the canonical
    -- first, then re-add the _rooted alias here.

    -- Magnataur Skewer. Canonical = _impact (the impact stun). _slow is the
    -- separate post-impact slow that the brain treats independently in
    -- RECOMMENDED_SAVES; we do NOT alias _slow -> _impact (different threats,
    -- different save preferences). Documenting the deliberate omission here so
    -- a future contributor doesn't fold them by mistake.
    -- (no entry: _impact and _slow are siblings of the SAME ability but distinct
    -- threats in the catalog; the dispatcher's caster_idx in the lock tuple is
    -- enough to keep them from racing.)

    -- Lion Finger of Death. Canonical = bare (CAST_POINT_THREATS key).
    -- vpk: pak01_009 ships _delay and _kill_counter siblings.
    modifier_lion_finger_of_death_delay        = "modifier_lion_finger_of_death",    -- vpk
    modifier_lion_finger_of_death_kill_counter = "modifier_lion_finger_of_death",    -- vpk

    -- Tinker Laser. Canonical = bare (CAST_POINT_THREATS key). _blind is the
    -- miss-chance debuff sibling.
    -- vpk: pak01_009 ships _blind.
    modifier_tinker_laser_blind                = "modifier_tinker_laser",            -- vpk

    -- OD Sanity Eclipse. Canonical = bare (CAST_POINT_THREATS key).
    -- vpk: pak01_009 ships _charge (caster-side mana-charge stack).
    modifier_obsidian_destroyer_sanity_eclipse_charge = "modifier_obsidian_destroyer_sanity_eclipse",  -- vpk

    -- Doom. Canonical = modifier_doom_bringer_doom (CAST_POINT_THREATS key).
    -- VPK sweep (pak01_009) found only the bare canonical; no _aura_enemy /
    -- _aura_self siblings reproducible in the current build. No fold today;
    -- add here with a 'manual' marker if a future engine version introduces
    -- a victim-side aura modifier the brain detects.

    -- Disruptor Static Storm. Canonical = _thinker (the channel-on-thinker
    -- mod; THREATS_ON_SELF + ENEMY_CHANNEL_MODIFIERS key). The bare name lives
    -- on the victim during the channel; fold so a victim-side detector also
    -- routes to the thinker-keyed lock.
    -- audit: lib/threat_data.lua ENEMY_CHANNEL_MODIFIERS keys on _thinker; the
    --        bare name is a real engine sibling per pak01_009 grep.
    modifier_disruptor_static_storm            = "modifier_disruptor_static_storm_thinker",  -- vpk
}

----------------------------------------------------------------------------
-- ThreatData.CanonicalMod(mod_name) -- alias-fold a modifier name to its
-- canonical lock-domain key.
--
-- Signature:
--   (mod_name: string|nil) -> string|nil
--
-- Semantics:
--   - nil / empty / non-string -> nil (caller must treat as "unresolvable";
--     defense.lua falls through to the v0.5.39 unlocked path on nil).
--   - alias in CANONICAL_MOD_ALIASES -> the canonical string.
--   - everything else -> identity (already canonical OR uncatalogued; the
--     dispatcher will tlog 'eta_resolver_fallback' on uncatalogued mods so
--     they get added to CANONICAL_MOD_ALIASES on the next iteration).
--
-- Pure: no side-effects, table lookups only.
--
-- Caller contract (lib/defense.lua Dispatcher:_LockKey):
--   local canon = c.TD.CanonicalMod(threat_mod)
--   if not canon then return nil end   -- unlocked path
--   return string.format('%d:%s:%d', target_idx, canon, caster_idx)
----------------------------------------------------------------------------
function ThreatData.CanonicalMod(mod_name)
    if type(mod_name) ~= "string" or mod_name == "" then
        return nil
    end
    local canon = ThreatData.CANONICAL_MOD_ALIASES[mod_name]
    if canon then
        return canon
    end
    return mod_name
end

-- Exported alias under the longer name used in the audit doc. Both names
-- resolve to the same function so Lina.lua / lib/defense.lua can pick whichever
-- reads better at call site without an extra indirection.
ThreatData.CanonicalizeThreatMod = ThreatData.CanonicalMod
-- Third alias under the bare 'Canonicalize' spelling: zero-cost defensive
-- shim so any future doc / call site that references the shorter name finds
-- the same closure (v0.5.40 verifier optional finding).
ThreatData.Canonicalize          = ThreatData.CanonicalMod

----------------------------------------------------------------------------
-- ThreatData.AbilityToCanonical(ability_name) -- compose ABILITY_TO_THREAT
-- with CanonicalMod. Used by lib/defense.lua when the anim-path fires before
-- any modifier is on the victim (line projectiles: hook, arrow, storm bolt)
-- and the lock_key must be derived from the ability name alone.
--
-- Signature:
--   (ability_name: string|nil) -> string|nil
--
-- Returns the canonical modifier name the ability stamps, or nil if the
-- ability is unmapped / its threat_modifier is nil (mobility-only abilities
-- like queenofpain_blink that map to nil in ABILITY_TO_THREAT).
----------------------------------------------------------------------------
function ThreatData.AbilityToCanonical(ability_name)
    if type(ability_name) ~= "string" or ability_name == "" then
        return nil
    end
    local mod = ThreatData.ABILITY_TO_THREAT[ability_name]
    if not mod then
        return nil
    end
    return ThreatData.CanonicalMod(mod)
end

return ThreatData
