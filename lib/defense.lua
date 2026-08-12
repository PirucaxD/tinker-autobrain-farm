---@meta
---lib/defense.lua - generic Layer-2 save dispatcher (Tier-2 extraction).
---
---Pulls the chain-resolution + chain-walk + throttle bookkeeping out of the
---per-hero defense layer. The DATA (chain tables, SAVE_FIRE map, override
---tables, filter sets) stays hero-side; the ALGORITHM lives here. Each hero
---calls Defense.New{cfg} once at init and keeps thin adapters around the
---returned dispatcher.
---
---No cross-hero state. Each dispatcher captures one cfg and operates only on
---the throttle_state / armed_threats refs the hero passes in.
---
---Audit-trail of equivalence vs the pre-extraction inline path:
---  - ResolveSaveOrder mirrors Lina pre-v0.5.0 resolve_save_order (anim ->
---    hero -> patched_recommended -> category -> default; first hit wins).
---  - TrySaveSelf mirrors the chain walk: same skip reasons, same order,
---    same reserve-penalty + concurrent-threat math, same tlog event names
---    so log greps keep working unchanged.
---  - CanFire / MarkFired match the inline LAYER2_REACTION_WINDOW gate.
---
---v0.5.40 TIER 0 (dispatcher unification):
---  - Dispatcher.in_flight_locks / in_flight_locks_ally: per-threat lock map
---    keyed [target_idx][canonical_mod][caster_idx]. Enforces the v0.5.7 E13
---    single-save-per-engagement invariant structurally; replaces the
---    Dedup.threat_already_responded 2.0s window that misses slow-travel
---    threats (Bara WW+Pike, Sniper Assassinate D-key double-fire).
---  - TryAcquireLock / ReleaseLock / ForceNextDispatch: identity-by-handle
---    lock primitives. Lock key tuple (target_idx, canonical_mod, caster_idx)
---    distinguishes casters per v0.5.14 BL-A5/BL-B7 (two casters arming the
---    same modifier are two concurrent threats).
---  - Dispatch / DispatchAlly: new top-level entries that wrap chain-walk in
---    a lock-acquire / on-success-hold cycle. Self-domain and ally-domain
---    locks live in separate maps (Lotus-on-self does NOT block Glimmer-on-
---    ally for the same threat).
---  - TrySaveSelf is now a thin compat wrapper around Dispatch for existing
---    Lina call sites; the Routing phase migrates direct callers.
---  - ResolveSaveOrder gains an optional ctx table for GAP-3 (FC chain
---    demotion under fs_shard_window). Hero populates ctx; lib reads it.
---  - cfg.canonicalize_mod (mod -> string) and cfg.eta_resolver
---    (canonical_mod -> resolver_fn) are new hero-supplied accessors. Both
---    optional; absence falls through to behavioural-neutral defaults
---    (identity canonicalization, 2.0s fallback lock TTL).
---
---See Lina/LIB_DEFENSE_EXTRACTION.md for design + Sniper migration plan.

local Defense = {}

---v0.5.53 Phase 3 slice 3: public lib helper for the per-save fire-window
---math. Generalized from Lina's v0.5.51 state.compute_save_fire_window so
---the dispatcher's per-save catalog gate (in run_chain_walk) and any
---hero-side preview can share one source of truth.
---
---@param threat_entry table|nil  catalog entry (THREAT_ARRIVAL_TIMING[mod])
---@param speed number|nil        effective threat speed (avg-during-prep)
---@param save_entry table|nil    SAVE_FIRE[name] entry (must have prep_time)
---@return number lower, number upper
function Defense.ComputeSaveFireWindow(threat_entry, speed, save_entry)
    local prep = (save_entry and save_entry.prep_time) or 0
    local UPPER_TOLERANCE = 0.10
    if threat_entry then
        local k = threat_entry.kind or ""
        -- channel_at_caster (WD) + cast_point_targeted (Lion / Lina /
        -- Sniper Assassinate): preserve v0.5.51 behavior of always-open
        -- window; fire-timing handled by other paths in v0.5.53. Slice 4
        -- (v0.5.54) will revisit when cast-point-armed branches consume
        -- catalog cast_point.
        if k == "channel_at_caster" or k == "cast_point_targeted" then
            return 0, math.huge
        end
        -- AoE-catch saves on homing kinds: upper is geometric
        -- (catch_radius / speed). W has catch_radius=225; other saves
        -- leave it nil and fall through to tight tolerance.
        if (k == "homing_charge" or k == "homing_carry")
           and save_entry and save_entry.catch_radius
           and speed and speed > 0 then
            return prep, prep + save_entry.catch_radius / speed
        end
    end
    -- Default: tight tolerance (D3 from v0.5.51: singular fire moment
    -- per spec "fire moment as impact_t - prep_t", small upper margin
    -- for frame-rate slack only).
    return prep, prep + UPPER_TOLERANCE
end

-- v0.5.39 P3-LOW-magic: reserve-skip / concurrent-penalty thresholds are
-- passed in via cfg (cfg.reserve_skip_floor / cfg.concurrent_penalty) rather
-- than baked in here, so heroes can tune them independently. The hero-side
-- source of truth lives in the hero file's module-level constants (e.g. Lina:
-- state.RESERVE_SKIP_FLOOR / state.CONCURRENT_PENALTY). The hero file's
-- chain-peek helper (armed_chain_peek in Lina.lua) MUST mirror these same
-- values when previewing the dispatcher's gate; v0.5.39 M1 routed the count
-- itself through Dispatcher:CountConcurrentExcluding so peek+dispatch share
-- one method, but the thresholds still need to be kept in lock-step.
local Dispatcher = {}
Dispatcher.__index = Dispatcher

-- v0.5.40 TIER 0 defaults. lock_buffer_s default per design lock_ttl_math:
-- reaction_window (0.1s) + engine_apply_slack (0.2s) = 0.3s. Hard cap 6.0s
-- and floor 0.4s clamp every resolver result. fallback_lock_ttl_s default
-- 2.0s matches legacy Dedup.THREAT_WINDOW for behaviour-neutral fallback on
-- uncatalogued canonical_mods.
local DEFAULT_LOCK_BUFFER_S      = 0.3
local DEFAULT_FALLBACK_LOCK_TTL  = 2.0
local LOCK_TTL_HARD_CAP_S        = 6.0
local LOCK_TTL_FLOOR_S           = 0.4
-- v0.5.127 CD-aware early release (opt-in via cfg.item_on_cd). A held lock is
-- released BEFORE its resolved TTL on a re-engage dispatch, but never sooner
-- than the coalesce floor (so a single threat-instance's anim + modcreate +
-- armed dispatch paths still collapse to ONE save -- the v0.5.40 single-spend
-- invariant). Past the floor a new dispatch is a genuine re-engage: release
-- once the fired save is confirmed spent (on CD) so the chain advances to the
-- next ready save, OR after the give-up window if it never entered CD (the
-- issue did not take) so the chain can re-attempt. The resolved TTL stays the
-- unconditional upper backstop -- this only ever releases SOONER, never later.
local DEFAULT_LOCK_CD_COALESCE_S = 0.30
local DEFAULT_LOCK_CD_GIVEUP_S   = 0.60

----------------------------------------------------------------------------
-- v0.5.110 CHAIN COMPOSITION (Lina/CHAIN_COMPOSITION_DESIGN.md)
----------------------------------------------------------------------------

---Compose a final save chain from a lib item backbone + hero ability
---injections + hero item exclusions. PURE: no engine calls, no dispatcher
---state, safe at hero load time. Used TWO ways: automatically by
---ResolveSaveOrder tier 3 for category-resolved threats, and directly by
---heroes to build bespoke chains at load (e.g. Lina's committed-attacker
---variants). NEVER mutates item_chain (it is typically the shared
---TD.CATEGORY_CHAINS entry); always returns a new table.
---
---Algorithm (design sec 3.1):
---  1. filtered = item_chain minus any name in exclusions.
---  2. each injection, in declared order, splices injection.save at anchor:
---     "head" -> position 1; "tail" -> append; {before="X"} -> immediately
---     before the first X; {after="X"} -> immediately after the first X;
---     before/after target absent (or anchor nil/unrecognized) -> tail. The
---     save is ALWAYS placed, never dropped.
---  3. dedupe, first occurrence wins. An injected save already in the
---     backbone therefore MOVES to its anchor when anchored earlier (the
---     committed-ranged cyclone-to-head case relies on this).
---@param item_chain string[]|nil  category item backbone
---@param injections table[]|nil   list of { save = string, anchor = "head"|"tail"|{before=string}|{after=string} }
---@param exclusions table<string, boolean>|nil  item names removed from the backbone
---@return string[] composed       a NEW list table
function Defense.ComposeChain(item_chain, injections, exclusions)
    local out = {}
    if item_chain then
        for i = 1, #item_chain do
            local name = item_chain[i]
            if not (exclusions and exclusions[name]) then
                out[#out + 1] = name
            end
        end
    end
    if injections then
        for i = 1, #injections do
            local inj = injections[i]
            if inj and inj.save then
                local anchor, pos = inj.anchor, nil
                if anchor == "head" then
                    pos = 1
                elseif type(anchor) == "table" then
                    local ref = anchor.before or anchor.after
                    for j = 1, #out do
                        if out[j] == ref then
                            pos = anchor.before and j or (j + 1)
                            break
                        end
                    end
                end
                if pos then
                    table.insert(out, pos, inj.save)
                else
                    out[#out + 1] = inj.save  -- "tail" / absent anchor target
                end
            end
        end
    end
    local seen, deduped = {}, {}
    for i = 1, #out do
        if not seen[out[i]] then
            seen[out[i]] = true
            deduped[#deduped + 1] = out[i]
        end
    end
    return deduped
end

---Create a dispatcher bound to one hero's defense config.
---@param cfg table see Lina/LIB_DEFENSE_EXTRACTION.md for the cfg field list
---  v0.5.40 TIER 0 additions (all optional, backward-compatible):
---    cfg.canonicalize_mod   fun(mod:string|nil):string|nil
---        Hero-supplied alias collapser. Maps modifier_pudge_dismember_pull and
---        modifier_pudge_dismember to one canonical string. nil/missing means
---        identity (the mod string IS the canonical key).
---    cfg.eta_resolver       table<string, fun(caster, target, armed_entry, ability_handle, now_t):number>
---        Map canonical_mod -> resolver_fn returning seconds_until_resolution
---        (>=0). Missing entry triggers cfg.eta_resolver_default; missing both
---        triggers fallback_lock_ttl_s.
---    cfg.eta_resolver_default fun(caster, target, armed_entry, ability_handle, now_t):number
---        Fallback resolver for any canonical_mod not in cfg.eta_resolver.
---    cfg.lock_buffer_s      number  (default 0.3)
---        Buffer added to resolver eta before the lock expiry timestamp.
---        Covers cfg.reaction_window throttle (~0.1) + engine apply slack
---        (~0.2). See design lock_ttl_math note.
---    cfg.fallback_lock_ttl_s number  (default 2.0)
---        Used when neither eta_resolver[mod] nor eta_resolver_default
---        produces a value. Matches legacy Dedup.THREAT_WINDOW.
---    cfg.ability_handle     fun(ability_name:string|nil):any|nil
---        Optional. Returns the engine ability handle for an ability_name so
---        resolvers can read GetCastPoint / GetChannelTime live. nil-tolerant.
---    cfg.post_pick_filter   fun(picked:table, ctx:table|nil, threat_mod:string|nil, authoritative:boolean):table?, boolean?
---        v0.5.41 GAP-3-GENERIC. Optional chain-rewrite hook called by
---        ResolveSaveOrder after chain resolution, before returning. Receives
---        the resolved (picked, ctx, threat_mod, authoritative); may return a
---        new (picked, authoritative) tuple to substitute. Return nil for
---        picked to keep the resolved chain. Lib applies new_auth only when
---        non-nil so a hook returning just a new chain preserves the
---        original authoritative flag. nil hook = passthrough.
---  v0.5.53 Phase 3 slice 3 additions (all optional, opt-in):
---    cfg.threat_catalog     table|nil
---        Map threat_mod -> catalog entry (kind / speed_source / catch_radius
---        / etc.). When registered AND cfg.compute_arrival_time is registered,
---        run_chain_walk applies a per-save catalog gate before firing each
---        save with cfg.save_fire[name].prep_time > 0. Hero passes the same
---        THREAT_ARRIVAL_TIMING table its own compute_arrival_time consumes.
---        nil = no lib-side catalog gate (Sniper today; legacy behavior).
---    cfg.compute_arrival_time fun(threat_mod:string, caster:any, target:any):number?, any, table?, number?
---        Returns (impact_t, impact_pos, cat_entry, eff_speed). Used by the
---        per-save catalog gate to compute fire windows. Same signature as
---        Lina's state.compute_arrival_time. nil = no lib-side catalog gate.
---    cfg.self_npc           fun():any|nil
---        Returns the hero's own NPC handle (used as the catalog target).
---        Already used by TrySaveSelf; now also consumed by the per-save
---        catalog gate in run_chain_walk.
---  v0.5.110 chain-composition additions (all optional, opt-in; spec
---  Lina/CHAIN_COMPOSITION_DESIGN.md):
---    cfg.ability_injections table[]|nil
---        List of { save = string, categories = string[]|"*", anchor =
---        "head"|"tail"|{before=string}|{after=string} }. When this OR
---        cfg.exclusions is registered, ResolveSaveOrder gains tier 3:
---        any threat resolving to a category (TD.CategoryOf(threat_mod)
---        or category_hint) gets Defense.ComposeChain(raw
---        TD.CATEGORY_CHAINS backbone, matching injections,
---        exclusions[category]) as an AUTHORITATIVE chain, ahead of
---        patched_recommended / category_chains. MUST stay static after
---        Defense.New: composed chains memoize per category.
---    cfg.exclusions         table<string, table<string, boolean>>|nil
---        Map category -> { item_name = true }: items removed from that
---        category's composed backbone. Same static-after-load rule.
---  v0.5.127 CD-aware lock release additions (all optional, opt-in; general
---  re-engage structure, NOT tied to the full fixed TTL):
---    cfg.item_on_cd         fun(save_short:string):boolean|nil
---        Returns true if the named save's item/ability is currently on
---        cooldown (= it actually fired / was spent). When registered, a HELD
---        lock is released early on a re-engage dispatch once its fired save is
---        confirmed spent, so the chain advances to the NEXT ready save (e.g.
---        Pike spent -> WW) instead of staying locked for the whole TTL.
---        nil = no early release (Sniper); the lock holds for its resolved TTL
---        exactly as v0.5.40. The lib pcall-wraps it; a throw keeps the lock.
---    cfg.lock_cd_coalesce_s number  (default 0.30)
---        Minimum hold before ANY CD-aware release. Coalesces a single threat
---        instance's multiple dispatch paths (anim + modcreate + armed, all
---        within a few frames) into ONE save so the single-spend invariant
---        survives. A new dispatch past this floor is treated as a re-engage.
---    cfg.lock_cd_giveup_s   number  (default 0.60)
---        If the fired save never enters cooldown by this point (the issue did
---        not take, or a no-cooldown save), release anyway so the chain can
---        re-attempt rather than waiting out the full TTL.
---@return table dispatcher
function Defense.New(cfg)
    local self = setmetatable({ cfg = cfg }, Dispatcher)
    -- v0.5.40 TIER 0: lock domains. Self-domain blocks Lina-on-Lina double
    -- saves (Bara WW+Pike, Sniper Assassinate D). Ally-domain is isolated so
    -- a self-save (Lotus) does NOT silence a same-threat ally-save (Glimmer
    -- on ally). Structure: [target_idx][canonical_mod][caster_idx] = entry.
    self.in_flight_locks      = {}
    self.in_flight_locks_ally = {}
    -- v0.5.40 TIER 0: per-(target,mod,caster) one-shot bypass flag. Set by
    -- Dispatcher:ForceNextDispatch and consumed inside Dispatch on the next
    -- attempt against that key. Replaces the panic-key last_save_t=0 hack
    -- that the v0.5.37 panic_override_until window used.
    self._force_bypass        = {}
    -- v0.5.110 chain composition: per-category memo of composed chains.
    -- Valid because cfg.ability_injections / cfg.exclusions are static
    -- after load (documented in the cfg docblock above).
    self._composed_cache      = {}
    return self
end

---Resolve the effective save chain for a (threat_mod, category_hint,
---ability_name) tuple. Returns (chain, is_authoritative); authoritative
---chains bypass the kind/tether filters during the walk.
---v0.5.40 GAP-3 / v0.5.41 GAP-3-GENERIC: optional ctx table lets the hero
---pass live context that influences chain ordering. ctx is forwarded to
---cfg.post_pick_filter (when registered) so the hero decides what keys it
---cares about. The lib treats ctx as opaque. Behavior-neutral when the hook
---is nil or returns nil. Lina's registration consumes ctx.fs_shard_window
---to demote 'lina_flame_cloak' to chain tail during the 5s post-R Aghs
---Shard window; see Lina/Lina.lua Defense.New cfg.post_pick_filter.
---@param threat_mod string|nil
---@param category_hint string|nil
---@param ability_name string|nil
---@param ctx table|nil  v0.5.40 GAP-3 context hooks; currently fs_shard_window
---@return table chain, boolean is_authoritative
function Dispatcher:ResolveSaveOrder(threat_mod, category_hint, ability_name, ctx)
    local c = self.cfg
    -- v0.5.83 perf: build the per-pick level-3 diagnostic table only when
    -- level-3 logging is actually live. ResolveSaveOrder runs per armed threat
    -- during an approach window; at default verbosity the kv-literal at each
    -- return branch was a guaranteed wasted alloc (c.tlog only drops it by level
    -- AFTER it is built). diag_on defaults TRUE when cfg.tlog_level is absent, so
    -- a hero that does not register the accessor (e.g. Sniper) keeps the exact
    -- prior always-build behaviour. pick_log centralizes the gated emit.
    local diag_on = (c.tlog_level == nil) or (c.tlog_level() >= 3)
    local function pick_log(source, head)
        if diag_on then
            c.tlog(3, "resolve_save_order_pick",
                   { mod = threat_mod, source = source, head = head })
        end
    end
    -- v0.5.13 E4 (HI-3 / PE04-OVERRIDE-WORKS): emit a single diagnostic tlog at
    -- each return point so operators can read the resolved chain HEAD directly
    -- from the log. PE04-OVERRIDE-WORKS confirmed LINA_SAVE_OVERRIDES is being
    -- consulted (BKB > Manta > Eul > Aeon on Duel) but the level-1
    -- threat_on_self line was reporting the static lib `save=` hint, which
    -- operators kept reading as the resolved head and concluding the override
    -- was unconsulted. No behavioural change to the resolver itself; this is
    -- diagnostic_only. The companion Lina.lua threat_on_self tlog will drop /
    -- demote that misleading `save = entry.save` field in a sibling patch.
    local picked, authoritative
    if ability_name then
        local ao = c.anim_save_overrides[ability_name]
        if ao then
            pick_log("anim_override", ao[1] or "-")
            picked, authoritative = ao, true
        end
    end
    if not picked and threat_mod then
        local hero = c.hero_save_overrides[threat_mod]
        if hero then
            pick_log("hero_override", hero[1] or "-")
            picked, authoritative = hero, true
        end
    end
    -- v0.5.110 tier 3 (Lina/CHAIN_COMPOSITION_DESIGN.md sec 3.2): COMPOSED
    -- category chain. Fires only for heroes that registered composition
    -- cfg (cfg.ability_injections and/or cfg.exclusions); heroes without
    -- it (Sniper) skip this block entirely and resolve exactly as before
    -- (additive). The backbone is the RAW lib TD.CATEGORY_CHAINS entry,
    -- NOT c.category_chains: hero category patches stay a tier-4/5
    -- fallback, while composed resolutions express hero preference via
    -- injections/exclusions only (spec sec 5 proof case). Composed chains
    -- are AUTHORITATIVE: the hero declared its anchors deliberately, so
    -- they bypass the kind/tether filters exactly like hand-curated
    -- overrides. Composition inputs are static after load, so the result
    -- memoizes per category in self._composed_cache (ResolveSaveOrder
    -- runs per armed threat per tick; composing every call would be the
    -- per-tick alloc class the v0.5.83 pass removed from this function).
    if not picked and (c.ability_injections or c.exclusions) then
        local category = (threat_mod and c.TD.CategoryOf and c.TD.CategoryOf(threat_mod))
                         or category_hint
        local backbone = category and c.TD.CATEGORY_CHAINS
                         and c.TD.CATEGORY_CHAINS[category]
        if backbone then
            local cache_key = category .. "|" .. (threat_mod or "")
            local composed = self._composed_cache[cache_key]
            if not composed then
                -- counter-filter the ITEM backbone by the live threat. Hero
                -- ability injections are spliced AFTER and are never filtered.
                local filtered = {}
                for i = 1, #backbone do
                    if (not c.TD.SaveCounters)
                       or c.TD.SaveCounters(backbone[i], threat_mod) then
                        filtered[#filtered + 1] = backbone[i]
                    end
                end
                local inj
                if c.ability_injections then
                    inj = {}
                    for i = 1, #c.ability_injections do
                        local e = c.ability_injections[i]
                        local cats, match = e.categories, false
                        if cats == "*" then match = true
                        elseif type(cats) == "table" then
                            for j = 1, #cats do
                                if cats[j] == category then match = true; break end
                            end
                        end
                        if match then inj[#inj + 1] = e end
                    end
                end
                composed = Defense.ComposeChain(
                    filtered, inj, c.exclusions and c.exclusions[category])
                self._composed_cache[cache_key] = composed
            end
            if #composed > 0 then
                pick_log("composed", composed[1] or "-")
                picked, authoritative = composed, true
            else
                -- whole backbone excluded + no injections: mirror the
                -- lib_patched_empty fall-through (tiers 4-6 still run).
                pick_log("composed_empty", "-")
            end
        end
    end
    if not picked and threat_mod then
        -- v0.5.14 E8 (BL-B2 / BL-B6): split the old single "category_default" head-source
        -- label into three distinct values (category_default / category_hint / default_chain)
        -- so operators can tell apart CategoryOf(threat_mod) hits, caller-passed
        -- category_hint hits, and the terminal default_chain fallthrough. Also adds a
        -- lib_patched_empty tlog for KFR/Pit-style intentionally-empty RECOMMENDED entries
        -- that previously fell through silently.
        local td = c.patched_recommended[threat_mod]
        if td and #td > 0 then
            pick_log("lib_patched", td[1] or "-")
            picked, authoritative = td, false
        elseif td then
            pick_log("lib_patched_empty", "-")
        end
        if not picked then
            local category = c.TD.CategoryOf and c.TD.CategoryOf(threat_mod) or nil
            if category and c.category_chains[category] then
                pick_log("category_default", c.category_chains[category][1] or "-")
                picked, authoritative = c.category_chains[category], false
            end
        end
    end
    if not picked and category_hint and c.category_chains[category_hint] then
        pick_log("category_hint", c.category_chains[category_hint][1] or "-")
        picked, authoritative = c.category_chains[category_hint], false
    end
    if not picked then
        pick_log("default_chain", c.default_chain[1] or "-")
        picked, authoritative = c.default_chain, false
    end

    -- v0.5.41 GAP-3-GENERIC: hero-supplied chain-rewrite hook. Replaces the
    -- v0.5.40 hardcoded lina_flame_cloak demotion that used to live here.
    -- Hero registers cfg.post_pick_filter(picked, ctx, threat_mod,
    -- authoritative) -> (picked, authoritative); nil hook returns chain
    -- as-is (behavior-neutral). Lina's registration replicates the v0.5.40
    -- FC demotion under fs_shard_window; other heroes can reorder chains
    -- on live ctx without editing the lib. Builds a NEW chain table inside
    -- the hook so cfg override / category / default tables stay untouched.
    if c.post_pick_filter then
        local new_picked, new_auth = c.post_pick_filter(picked, ctx, threat_mod, authoritative)
        if new_picked then
            picked = new_picked
            if new_auth ~= nil then authoritative = new_auth end
        end
    end

    return picked, authoritative
end

---Throttle gate. Returns true iff defense is enabled AND the reaction window
---has elapsed since the last save dispatch.
---@return boolean
function Dispatcher:CanFire()
    local c = self.cfg
    if not c.defense_enabled() then return false end
    if (c.now() - (c.throttle_state.last_save_t or 0)) < c.reaction_window then
        return false
    end
    return true
end

---Mark a save as just-fired (writes throttle_state.last_save_t). Idempotent.
---v0.5.39 P1-LAST-SAVE-TGT: the throttle_state.last_save_target write has been
---removed (Sniper-port orphan; no Lina-side reader, see Lina.lua state-decl
---comment near state.last_save_t for history). Method signature preserved.
---@param threat_caster any  may be nil (kept for signature compatibility)
function Dispatcher:MarkFired(threat_caster)
    local c = self.cfg
    c.throttle_state.last_save_t = c.now()
end

-- Local helpers for the chain walk. Operate on the cfg so the dispatcher
-- table itself stays empty besides self.cfg / methods.

local function save_counters_ok(c, save_name, threat_mod)
    if not threat_mod or not c.TD.SaveCounters then return true end
    return c.TD.SaveCounters(save_name, threat_mod)
end

local function tether_breaks_ok(c, save_name, threat_mod, threat_caster)
    if not threat_mod or not c.TD.WillTetherBreak then return true end
    local d = (threat_caster and c.dist_to and c.dist_to(threat_caster)) or math.huge
    return c.TD.WillTetherBreak(save_name, threat_mod, d)
end

---v0.5.39 M1 (Option A): count armed_threats rows excluding `armed_entry` by
---entry-handle identity. Single source of truth for the reserve/concurrent
---penalty math; Lina armed_chain_peek delegates here so the per-hero peek
---and the lib chain-walk cannot drift. Pass the live armed_entry on the
---armed-fire path (Lina.lua armed_threats_tick L1528) so peek+dispatch agree
---on n=0 for the typical single-armed-threat case. Non-armed call sites
---(events / persistent / threat_on_self / lotus / line_intercept) pass nil
---and count all armed rows (legacy behaviour preserved).
---Entry-handle identity is the correct semantics per v0.5.14 BL-A5/BL-B7:
---two different casters arming the same modifier must NOT collapse.
---@param armed_entry table|nil
---@return integer
function Dispatcher:CountConcurrentExcluding(armed_entry)
    local c = self.cfg
    local n = 0
    for _, e2 in pairs(c.armed_threats) do
        if e2 ~= armed_entry then
            n = n + 1
        end
    end
    return n
end

-- ============================================================================
-- v0.5.40 TIER 0: per-threat lock primitives + Dispatch entry points.
--
-- Lock domain shape (self.in_flight_locks, self.in_flight_locks_ally):
--   locks[target_idx][canonical_mod][caster_idx] = {
--       fire_t       = number,   -- cfg.now() at acquire
--       ttl          = number,   -- seconds; expiry = fire_t + ttl
--       save_short   = string|nil, -- save name that fired (populated by Dispatch on success)
--       intent       = string|nil, -- top-level intent passed to Dispatch
--       armed_entry  = table|nil,  -- armed_threats row, if armed-fire path
--   }
--
-- Lazy expiry: TryAcquireLock checks fire_t+ttl < now() and overwrites stale
-- entries silently. Cheaper than a tick sweep; for v0.5.40's expected lock
-- population (<10 concurrent in any pathological case) the overhead is nil.
-- ============================================================================

-- Local helper: extract entity index in a nil-tolerant way. cfg.entity_index
-- is the hero-supplied accessor (Entity.GetIndex wrapper). Falls back to
-- treating numeric inputs as already-an-index, anything else returns nil so
-- TryAcquireLock can short-circuit to the unlocked v0.5.39 path.
local function ent_idx(c, ent)
    if ent == nil then return nil end
    if type(ent) == "number" then return ent end
    if c.entity_index then
        local ok, idx = pcall(c.entity_index, ent)
        if ok and type(idx) == "number" then return idx end
    end
    return nil
end

-- Local helper: canonicalize via cfg.canonicalize_mod (hero-supplied alias
-- collapser). Falls through to identity when cfg.canonicalize_mod is nil
-- (preserves v0.5.39 behaviour for callers that haven't migrated yet).
local function canon(c, mod)
    if mod == nil then return nil end
    if c.canonicalize_mod then
        local ok, canonical = pcall(c.canonicalize_mod, mod)
        if ok and type(canonical) == "string" then return canonical end
    end
    return mod
end

-- Local helper: compose the lock key tuple. Returns three values
-- (target_idx, canonical_mod, caster_idx) or nil when any leg is
-- unresolvable. Per v0.5.14 BL-A5/BL-B7 the caster leg is REQUIRED to
-- distinguish two casters arming the same modifier; nil caster falls
-- through to the unlocked path (matches the v0.5.39 line-intercept and
-- fog-projectile behaviour the design doc preserves).
-- v0.5.40 verifier fix: also reject empty-string canonical so a hero-side
-- canonicalize_mod that collapses unknowns to "" never bucket-collides
-- unrelated mods on the same target.
local function lock_key(c, target_unit, canonical_mod, caster_unit)
    if not canonical_mod or canonical_mod == "" then return nil end
    local t_idx = ent_idx(c, target_unit)
    if not t_idx then return nil end
    local k_idx = ent_idx(c, caster_unit)
    if not k_idx then return nil end
    return t_idx, canonical_mod, k_idx
end

-- Local helper: fetch a live lock entry from a domain map, expiring stale
-- entries lazily. Returns the entry table (alive) or nil (none / expired).
-- Removes expired entries from the map as a side effect.
local function get_live_lock(c, domain, t_idx, canonical_mod, k_idx)
    local by_target = domain[t_idx]
    if not by_target then return nil end
    local by_mod = by_target[canonical_mod]
    if not by_mod then return nil end
    local entry = by_mod[k_idx]
    if not entry then return nil end
    if (entry.fire_t + entry.ttl) <= c.now() then
        by_mod[k_idx] = nil
        return nil
    end
    return entry
end

-- Local helper (v0.5.127): decide whether a HELD lock should be released early
-- so an incoming (re-engage) dispatch can proceed. Opt-in -- returns false
-- unless cfg.item_on_cd is registered, so heroes that do not register it
-- (Sniper) keep the v0.5.40 full-TTL behaviour byte-for-byte.
--
-- Lifecycle after a successful fire stamped entry.save_short:
--   elapsed < coalesce floor               -> false (coalesce same-instance paths)
--   past floor, save confirmed on CD        -> true  (spent; re-dispatch skips it
--                                                      via not_ready, fires next save)
--   past give-up window, still not on CD    -> true  (issue never took; re-attempt)
--   past floor, not on CD, within give-up   -> false (still confirming the cast)
-- The resolved TTL (lazy expiry in get_live_lock) is the unconditional upper
-- backstop, so a lock is never held LONGER than v0.5.40 -- only released sooner.
local function lock_cd_released(c, entry, now_t)
    if not c.item_on_cd then return false end
    local short = entry and entry.save_short
    -- Unnameable fires (offensive thunk co-cast, or a fire that never stamped
    -- save_short) are not CD-checkable; they keep the full resolved TTL.
    if not short or short == "thunk" then return false end
    local elapsed = now_t - (entry.fire_t or now_t)
    local coalesce = c.lock_cd_coalesce_s or DEFAULT_LOCK_CD_COALESCE_S
    if elapsed < coalesce then return false end
    local ok, on_cd = pcall(c.item_on_cd, short)
    if ok and on_cd then return true end
    local giveup = c.lock_cd_giveup_s or DEFAULT_LOCK_CD_GIVEUP_S
    if elapsed >= giveup then return true end
    return false
end

-- Local helper: clamp resolver eta to [FLOOR, CAP], then add lock_buffer.
-- v0.5.40 verifier fix: removed the c.reaction_window intermediate fallback
-- so the documented cfg.lock_buffer_s default (0.3) is honoured. The earlier
-- chain silently shrank the buffer to cfg.reaction_window (0.1 in Lina),
-- under-budgeting engine apply slack and risking premature lock release.
local function clamp_ttl(c, eta)
    local capped = math.min(math.max(eta or 0, 0), LOCK_TTL_HARD_CAP_S)
    local buf    = c.lock_buffer_s or DEFAULT_LOCK_BUFFER_S
    local ttl    = capped + buf
    if ttl < LOCK_TTL_FLOOR_S then ttl = LOCK_TTL_FLOOR_S end
    return ttl
end

-- Local helper: resolve the lock TTL for a (canonical_mod, threat_caster,
-- target, armed_entry, ability_name) bundle via cfg.eta_resolver chain.
-- Order: cfg.eta_resolver[canonical_mod] -> cfg.eta_resolver_default ->
-- cfg.fallback_lock_ttl_s -> DEFAULT_FALLBACK_LOCK_TTL. Emits
-- eta_resolver_fallback tlog at v=1 when the canonical_mod has no catalog
-- entry (operators add proper entries during play).
-- v0.5.72: resolver is now called with canonical_mod as the 6th arg so a
-- generic default resolver can look up per-mod data from a lib catalog
-- (Lina's _lina_eta_default consumes this to read THREAT_ARRIVAL_TIMING).
-- Backwards-compatible: per-mod resolvers that take only 5 args ignore
-- the extra parameter.
local function resolve_ttl(c, canonical_mod, threat_caster, target_unit, armed_entry, ability_name)
    local resolver
    if c.eta_resolver and canonical_mod then
        resolver = c.eta_resolver[canonical_mod]
    end
    if not resolver then resolver = c.eta_resolver_default end
    if resolver then
        local ability_handle
        if c.ability_handle and ability_name then
            local ok, h = pcall(c.ability_handle, ability_name)
            if ok then ability_handle = h end
        end
        local ok, eta = pcall(resolver, threat_caster, target_unit, armed_entry, ability_handle, c.now(), canonical_mod)
        if ok and type(eta) == "number" then
            return clamp_ttl(c, eta)
        end
    end
    local fallback = c.fallback_lock_ttl_s or DEFAULT_FALLBACK_LOCK_TTL
    c.tlog(1, "eta_resolver_fallback", {
        mod = canonical_mod,
        caster_idx = ent_idx(c, threat_caster),
        ttl = string.format("%.2f", fallback),
    })
    return clamp_ttl(c, fallback)
end

---v0.5.40 TIER 0: attempt to acquire a per-threat lock for the (target,
---canonical_mod, caster) tuple. Identity-by-handle for caster_unit matches
---v0.5.14 BL-A5/B7 (two different casters arming the same modifier are two
---distinct concurrent threats). Returns (true, nil) on acquire,
---(false, existing_entry) when a live lock blocks. Returns (true, nil) with
---NO lock written when the key is unresolvable (nil canonical_mod / nil
---target / nil caster) to preserve the v0.5.39 unlocked path for
---lotus_pending: / line_intercept: / fog-projectile callers.
---@param target_unit any
---@param canonical_mod string|nil
---@param caster_unit any
---@param ttl number  seconds until expiry
---@return boolean ok, table|nil existing_lock_info
function Dispatcher:TryAcquireLock(target_unit, canonical_mod, caster_unit, ttl)
    return self:_TryAcquireLockOnDomain(self.in_flight_locks, target_unit, canonical_mod, caster_unit, ttl, false)
end

---Internal: domain-parameterised lock acquire. ally_domain flag flips the
---tlog event suffix and the _force_bypass key prefix so self/ally locks
---log distinguishably without colliding bypass flags.
---@param domain table
---@param target_unit any
---@param canonical_mod string|nil
---@param caster_unit any
---@param ttl number
---@param ally_domain boolean
---@return boolean ok, table|nil existing
function Dispatcher:_TryAcquireLockOnDomain(domain, target_unit, canonical_mod, caster_unit, ttl, ally_domain)
    local c = self.cfg
    local t_idx, mod_key, k_idx = lock_key(c, target_unit, canonical_mod, caster_unit)
    if not t_idx then
        c.tlog(2, "lock_key_unresolvable", { mod = canonical_mod, domain = ally_domain and "ally" or "self" })
        return true, nil
    end
    -- One-shot bypass consume (panic key). Bypass key prefix isolates self
    -- and ally domains so a panic on self does not unlock an ally-domain
    -- pending fire on the same tuple.
    local bypass_prefix = ally_domain and "ally:" or "self:"
    local bypass_id = bypass_prefix .. t_idx .. ":" .. (mod_key or "") .. ":" .. k_idx
    local bypassed = false
    if self._force_bypass[bypass_id] then
        self._force_bypass[bypass_id] = nil
        bypassed = true
        c.tlog(2, "force_next_consumed", {
            domain = ally_domain and "ally" or "self",
            target_idx = t_idx, mod = mod_key, caster_idx = k_idx,
        })
    end
    if not bypassed then
        local existing = get_live_lock(c, domain, t_idx, mod_key, k_idx)
        if existing then
            -- v0.5.127: CD-aware early release. Past the coalesce floor a new
            -- dispatch on the same tuple is a genuine re-engage; drop the lock
            -- when the fired save is confirmed spent (or the give-up window
            -- elapsed without it entering CD) so THIS dispatch proceeds and the
            -- chain walker fires the next ready save (e.g. Pike spent -> WW).
            -- Opt-in via cfg.item_on_cd; no-op otherwise -> v0.5.40 behaviour.
            if lock_cd_released(c, existing, c.now()) then
                domain[t_idx][mod_key][k_idx] = nil
                c.tlog(2, "lock_cd_released", {
                    domain     = ally_domain and "ally" or "self",
                    target_idx = t_idx, mod = mod_key, caster_idx = k_idx,
                    save       = existing.save_short or "-",
                    held_s     = string.format("%.2f", c.now() - (existing.fire_t or c.now())),
                })
                -- fall through to acquire a fresh lock below
            else
                return false, existing
            end
        end
    end
    -- Acquire. Build nested tables lazily.
    local by_target = domain[t_idx]
    if not by_target then by_target = {}; domain[t_idx] = by_target end
    local by_mod = by_target[mod_key]
    if not by_mod then by_mod = {}; by_target[mod_key] = by_mod end
    local entry = {
        fire_t      = c.now(),
        ttl         = ttl,
        save_short  = nil,
        intent      = nil,
        armed_entry = nil,
    }
    by_mod[k_idx] = entry
    c.tlog(2, "lock_acquired", {
        domain = ally_domain and "ally" or "self",
        target_idx = t_idx, mod = mod_key, caster_idx = k_idx,
        ttl = string.format("%.2f", ttl),
    })
    return true, nil
end

---v0.5.40 TIER 0: release a lock for (target, canonical_mod, caster). nil
---when no lock is held; idempotent. Emits lock_released tlog. Typical
---callers: ForceNextDispatch (drops, then bypass+re-acquire), explicit
---resolver-failed paths (rare; lazy expiry covers the normal case).
---@param target_unit any
---@param canonical_mod string|nil
---@param caster_unit any
function Dispatcher:ReleaseLock(target_unit, canonical_mod, caster_unit)
    self:_ReleaseLockOnDomain(self.in_flight_locks, target_unit, canonical_mod, caster_unit, false)
end

---Internal: domain-parameterised release.
function Dispatcher:_ReleaseLockOnDomain(domain, target_unit, canonical_mod, caster_unit, ally_domain)
    local c = self.cfg
    local t_idx, mod_key, k_idx = lock_key(c, target_unit, canonical_mod, caster_unit)
    if not t_idx then return end
    local by_target = domain[t_idx]
    if not by_target then return end
    local by_mod = by_target[mod_key]
    if not by_mod then return end
    if by_mod[k_idx] then
        by_mod[k_idx] = nil
        c.tlog(2, "lock_released", {
            domain = ally_domain and "ally" or "self",
            target_idx = t_idx, mod = mod_key, caster_idx = k_idx,
        })
    end
end

---v0.5.40 TIER 0: schedule a one-shot bypass for the NEXT Dispatch call on
---the (target, canonical_mod, caster) tuple. Drops the bypass flag inside
---Dispatch via TryAcquireLock, then re-acquires a fresh lock normally on a
---successful fire. Replaces the panic-key throttle_state.last_save_t=0 hack
---that v0.5.37 panic_override_until used; same semantics (one threat skip,
---next save re-locks normally).
---@param target_unit any
---@param canonical_mod string|nil
---@param caster_unit any
function Dispatcher:ForceNextDispatch(target_unit, canonical_mod, caster_unit)
    local c = self.cfg
    local t_idx, mod_key, k_idx = lock_key(c, target_unit, canonical_mod, caster_unit)
    if not t_idx then
        c.tlog(2, "force_next_unresolvable", { mod = canonical_mod })
        return
    end
    -- Self-domain by convention; panic key is self-save. Ally-domain panic
    -- would need a sibling ForceNextDispatchAlly which Tier 0 does not ship.
    local bypass_id = "self:" .. t_idx .. ":" .. (mod_key or "") .. ":" .. k_idx
    self._force_bypass[bypass_id] = true
    c.tlog(2, "force_next_armed", {
        target_idx = t_idx, mod = mod_key, caster_idx = k_idx,
    })
end

-- Local helper: the chain-walk body extracted from the v0.5.39 TrySaveSelf
-- so Dispatch can call it as the default fire path. Behaviour MUST stay
-- byte-equivalent to the v0.5.39 walk (same skip reasons, same order, same
-- tlog event names) so log greps and the v0.5.7 E13 invariant survive. The
-- only structural change is that the lock acquisition wraps the OUTSIDE of
-- this call (in Dispatch), not the INSIDE.
local function run_chain_walk(self, intent, threat_mod, threat_caster,
                              category_hint, ability_name, on_save_fired,
                              armed_entry, ctx)
    local c = self.cfg
    if not self:CanFire() then
        c.tlog(3, "layer2_window_throttle", { intent = intent })
        return false
    end

    local order, is_authoritative = self:ResolveSaveOrder(threat_mod, category_hint, ability_name, ctx)
    local severity = (c.TD.SeverityOf and c.TD.SeverityOf(threat_mod)) or "medium"
    local homing = threat_mod and c.threats_on_self
                   and c.threats_on_self[threat_mod]
                   and c.threats_on_self[threat_mod].homing or false

    for _, save_name in ipairs(order) do
        local fire_entry = c.save_fire[save_name]
        -- v0.5.55: removed the v0.5.53 per-save catalog gate. Chain walker
        -- returns to its pre-v0.5.53 dumb-walk shape per the refactor that
        -- matches Sniper's proven single-chain pattern. Hero .fire bodies
        -- handle their own timing (Lina's lina_w_anti_gap.fire now does
        -- the impact_t window check internally). Defense.ComputeSaveFireWindow
        -- stays as a public helper for hero .fire bodies that want the math.
        --
        -- v0.5.70: opt-in catalog impact_t defer + severity-aware skip for
        -- high-CD saves (Lotus / BKB / Aeon). Hero registers
        -- cfg.high_cd_saves + cfg.compute_arrival_time + cfg.self_hp_fraction
        -- to enable. Without these registrations the chain walker is
        -- byte-equivalent to pre-v0.5.70 behaviour.
        --   - catalog_defer: if the threat has a THREAT_ARRIVAL_TIMING entry
        --     and impact_t > cfg.cast_point_defer_threshold (default 0.5s),
        --     skip the high-CD save with reason=cast_point_too_early. The
        --     armed-threats tick re-evaluates each frame; the save fires
        --     when impact_t crosses the threshold.
        --   - severity_skip: if severity == "low" AND HP fraction >
        --     cfg.severity_skip_hp_threshold (default 0.75), skip with
        --     reason=low_severity_high_hp. Avoids burning a 60s BKB on a
        --     CM Frostbite when Lina is at full HP.
        local is_high_cd = fire_entry and c.high_cd_saves
                           and c.high_cd_saves[save_name] or false
        local catalog_defer_t
        if is_high_cd and c.compute_arrival_time and threat_mod
           and threat_caster and c.self_npc then
            local me = c.self_npc()
            if me then
                local impact_t = c.compute_arrival_time(threat_mod, threat_caster, me)
                if impact_t and impact_t > (c.cast_point_defer_threshold or 0.5) then
                    catalog_defer_t = impact_t
                end
            end
        end
        local sev_skip_hp
        if is_high_cd and not catalog_defer_t
           and severity == "low" and c.self_hp_fraction then
            local hp_frac = c.self_hp_fraction()
            local threshold = c.severity_skip_hp_threshold or 0.75
            if hp_frac and hp_frac > threshold then
                sev_skip_hp = hp_frac
            end
        end
        if not fire_entry then
            c.tlog(3, "save_chain_skip", { save = save_name, reason = "no_entry" })
        elseif c.ability_saves[save_name] and not c.self_can_cast_abilities() then
            c.tlog(3, "save_chain_skip", { save = save_name, reason = "ability_muted" })
        elseif homing and c.self_displacement_saves[save_name] then
            c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "homing_no_displacement" })
        elseif not is_authoritative and not save_counters_ok(c, save_name, threat_mod) then
            c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "kind_mismatch" })
        elseif not is_authoritative and not tether_breaks_ok(c, save_name, threat_mod, threat_caster) then
            c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "tether_unreachable" })
        elseif not c.save_is_ready(save_name) then
            -- v0.1.356: "not_ready" conflated NOT OWNED with ON COOLDOWN, which made post-mortems
            -- read backwards. A Tinker death showed 9 saves `not_ready` and looked like a total
            -- save-layer failure; in truth he owns ONE escape and it was on cooldown - the other
            -- eight were never in the inventory. Optional hook, so a hero that does not supply
            -- `save_is_owned` logs exactly what it logged before.
            local owned = c.save_is_owned and c.save_is_owned(save_name)
            c.tlog(3, "save_chain_skip", {
                save = fire_entry.short,
                reason = (c.save_is_owned and not owned) and "not_owned" or "not_ready" })
        elseif catalog_defer_t then
            c.tlog(3, "save_chain_skip", {
                save = fire_entry.short, reason = "cast_point_too_early",
                impact_t = string.format("%.2f", catalog_defer_t),
                threshold = string.format("%.2f", c.cast_point_defer_threshold or 0.5),
            })
        elseif sev_skip_hp then
            c.tlog(3, "save_chain_skip", {
                save = fire_entry.short, reason = "low_severity_high_hp",
                hp = string.format("%.2f", sev_skip_hp),
                threshold = string.format("%.2f", c.severity_skip_hp_threshold or 0.75),
            })
        else
            local penalty = (c.TD.SaveReservePenalty and c.TD.SaveReservePenalty(save_name, threat_mod)) or 0
            local concurrent = self:CountConcurrentExcluding(armed_entry)
            if concurrent >= 1 then penalty = penalty + c.concurrent_penalty end
            if penalty < c.reserve_skip_floor then
                c.tlog(3, "save_chain_skip", {
                    save = fire_entry.short, reason = "reserved",
                    severity = severity, concurrent = concurrent,
                })
            else
                local issue_intent = intent .. "_" .. fire_entry.short
                if fire_entry.fire(issue_intent, threat_caster, threat_mod) then
                    if on_save_fired then
                        on_save_fired(intent, fire_entry.short, threat_mod, threat_caster)
                    end
                    return true, fire_entry.short
                end
                c.tlog(3, "save_chain_skip", { save = fire_entry.short, reason = "fire_returned_false" })
            end
        end
    end

    if threat_mod then
        c.tlog(1, "no_effective_save_for_threat", { intent = intent, threat = threat_mod })
    else
        c.tlog(2, "layer2_no_save_available", { intent = intent })
    end
    return false
end

---v0.5.40 TIER 0: unified top-level Dispatch entry. Acquires a per-threat
---lock keyed (target_idx, canonical_mod, caster_idx), then fires either the
---supplied fire_thunk (covers Layer-1 FC offensive sites and lotus-direct
---paths) or the default chain-walk (covers Layer-2 TrySaveSelf migration).
---On a successful fire the lock is HELD (not released) so sibling fires
---against the same threat are blocked until the lock TTL expires. On block,
---emits dispatch_blocked tlog with the existing lock info. The lib does NOT
---call MarkFired; the hero's on_save_fired callback chain owns that (matches
---v0.5.39 contract noted at L165-167 of the v0.5.39 file).
---@param intent string
---@param threat_mod string|nil
---@param threat_caster any
---@param target_unit any
---@param fire_thunk fun(intent:string, threat_mod:string|nil, threat_caster:any):boolean|nil
---@param category_hint string|nil
---@param ability_name string|nil
---@param armed_entry table|nil
---@param on_save_fired fun(intent:string, short:string, mod:string|nil, caster:any)|nil
---@param ctx table|nil  v0.5.40 GAP-3 chain-resolver context
---@return boolean fired
function Dispatcher:Dispatch(intent, threat_mod, threat_caster, target_unit,
                             fire_thunk, category_hint, ability_name,
                             armed_entry, on_save_fired, ctx)
    local c = self.cfg
    -- v0.5.98 BKB-bypass fix: hero-supplied veto for a threat a self-defense is
    -- wasted on (Lina: one the active BKB fully absorbs). This is the SINGLE
    -- self-save chokepoint (TrySaveSelf routes through Dispatch), so vetoing here
    -- covers EVERY route -- the direct Dispatch callers (anim / modcreate / armed /
    -- line-intercept / lotus) AND TrySaveSelf -- instead of only the hero's
    -- try_save_self wrapper. Opt-in: heroes that do not register
    -- cfg.threat_fully_blocked (Sniper) are byte-unaffected. Checked BEFORE the lock
    -- acquire so a vetoed threat takes no lock slot. Offensive thunk co-casts pass a
    -- threat_mod the hero predicate does not recognise, so they are naturally exempt.
    if c.threat_fully_blocked and threat_mod
       and c.threat_fully_blocked(threat_mod, target_unit) then
        c.tlog(1, "dispatch_veto", { intent = intent, mod = tostring(threat_mod),
            reason = "threat_fully_blocked" })
        return false
    end
    local canonical_mod = canon(c, threat_mod)
    local ttl = resolve_ttl(c, canonical_mod, threat_caster, target_unit, armed_entry, ability_name)
    local ok, existing = self:_TryAcquireLockOnDomain(
        self.in_flight_locks, target_unit, canonical_mod, threat_caster, ttl, false)
    if not ok then
        c.tlog(2, "dispatch_blocked", {
            domain        = "self",
            intent        = intent,
            mod           = canonical_mod,
            caster_idx    = ent_idx(c, threat_caster),
            target_idx    = ent_idx(c, target_unit),
            existing_save = existing and existing.save_short or "-",
            existing_intent = existing and existing.intent or "-",
            ttl_remaining = existing and string.format("%.2f", (existing.fire_t + existing.ttl) - c.now()) or "0.00",
        })
        return false
    end
    -- Fire path. fire_thunk supplied -> Layer-1 / lotus-direct; else default
    -- chain walk. run_chain_walk returns (true, save_short) on success so we
    -- can stamp the lock entry's save_short / intent for dispatch_blocked
    -- diagnostics on subsequent sibling fires.
    -- v0.5.40 verifier fix: thunk branch now passes CanFire gate before
    -- pcall so Layer-1 FC offensive callers do not bypass the v0.5.39
    -- LAYER2_REACTION_WINDOW (E13 cross-threat throttle, lib-doc L19).
    local fired, save_short
    if fire_thunk then
        if not self:CanFire() then
            c.tlog(3, "layer2_window_throttle", { intent = intent, source = "thunk" })
            self:_ReleaseLockOnDomain(self.in_flight_locks, target_unit, canonical_mod, threat_caster, false)
            return false
        end
        local thunk_ok, thunk_ret = pcall(fire_thunk, intent, threat_mod, threat_caster)
        fired = thunk_ok and thunk_ret and true or false
        save_short = "thunk"
    else
        fired, save_short = run_chain_walk(self, intent, threat_mod, threat_caster,
                                           category_hint, ability_name, on_save_fired,
                                           armed_entry, ctx)
    end
    if fired then
        -- Stamp diagnostic fields on the lock entry. Lock is HELD; release
        -- happens via lazy expiry inside the next TryAcquireLock check.
        local t_idx, mod_key, k_idx = lock_key(c, target_unit, canonical_mod, threat_caster)
        if t_idx then
            local entry = self.in_flight_locks[t_idx]
                        and self.in_flight_locks[t_idx][mod_key]
                        and self.in_flight_locks[t_idx][mod_key][k_idx]
            if entry then
                entry.save_short  = save_short or entry.save_short
                entry.intent      = intent
                entry.armed_entry = armed_entry
            end
        end
        return true
    end
    -- Failed fire: release the lock so a sibling attempt within the same
    -- tick (different chain head, retry path) is not silenced. Matches
    -- v0.5.39 semantics where a fire_returned_false fall-through leaves no
    -- bookkeeping behind.
    self:_ReleaseLockOnDomain(self.in_flight_locks, target_unit, canonical_mod, threat_caster, false)
    return false
end

---v0.5.40 TIER 0: ally-domain Dispatch. Separate lock map so Lotus-on-self
---does NOT block Glimmer-on-ally for the same canonical_mod. Hero-supplied
---ally_chain optionally overrides cfg.default_chain for the walk; pass nil
---to use the standard resolver (the hero's ally-save layer typically
---supplies a dedicated chain via hero_save_overrides or a category_hint).
---@param intent string
---@param threat_mod string|nil
---@param threat_caster any
---@param ally_unit any
---@param fire_thunk fun(intent:string, threat_mod:string|nil, threat_caster:any):boolean|nil
---@param ally_chain table|nil  optional override chain for ally walk
---@param category_hint string|nil
---@param ability_name string|nil
---@param armed_entry table|nil
---@param on_save_fired fun(intent:string, short:string, mod:string|nil, caster:any)|nil
---@param ctx table|nil
---@return boolean fired
function Dispatcher:DispatchAlly(intent, threat_mod, threat_caster, ally_unit,
                                 fire_thunk, ally_chain, category_hint,
                                 ability_name, armed_entry, on_save_fired, ctx)
    local c = self.cfg
    local canonical_mod = canon(c, threat_mod)
    local ttl = resolve_ttl(c, canonical_mod, threat_caster, ally_unit, armed_entry, ability_name)
    local ok, existing = self:_TryAcquireLockOnDomain(
        self.in_flight_locks_ally, ally_unit, canonical_mod, threat_caster, ttl, true)
    if not ok then
        c.tlog(2, "dispatch_blocked", {
            domain        = "ally",
            intent        = intent,
            mod           = canonical_mod,
            caster_idx    = ent_idx(c, threat_caster),
            target_idx    = ent_idx(c, ally_unit),
            existing_save = existing and existing.save_short or "-",
            existing_intent = existing and existing.intent or "-",
            ttl_remaining = existing and string.format("%.2f", (existing.fire_t + existing.ttl) - c.now()) or "0.00",
        })
        return false
    end
    -- v0.5.40 verifier fixes for ally path:
    --   (a) thunk branch CanFire gate (same rationale as self-domain).
    --   (b) ally_chain hot-swap pcall-wrap so a save_fire throw cannot leak
    --       ally_chain into cfg.default_chain (would corrupt every later
    --       Dispatch / TrySaveSelf walk for the rest of the script run).
    local fired, save_short = false, nil
    if fire_thunk then
        if not self:CanFire() then
            c.tlog(3, "layer2_window_throttle", { intent = intent, source = "thunk_ally" })
            self:_ReleaseLockOnDomain(self.in_flight_locks_ally, ally_unit, canonical_mod, threat_caster, true)
            return false
        end
        local thunk_ok, thunk_ret = pcall(fire_thunk, intent, threat_mod, threat_caster)
        fired = thunk_ok and thunk_ret and true or false
        save_short = "thunk"
    else
        -- For ally walks the standard chain-walk is reused but with an
        -- optional ally_chain override threaded as a synthetic
        -- category_hint shim. Heroes that need a true override should pass
        -- the ally_chain via cfg.hero_save_overrides / cfg.category_chains
        -- before init; ally_chain here is the runtime-fast path.
        if ally_chain then
            local saved_default = c.default_chain
            c.default_chain = ally_chain
            local pcall_ok, f_or_err, s_or_nil = pcall(run_chain_walk, self, intent, threat_mod, threat_caster,
                                                       category_hint, ability_name, on_save_fired,
                                                       armed_entry, ctx)
            c.default_chain = saved_default
            if not pcall_ok then
                c.tlog(1, "dispatch_ally_walk_error", { intent = intent, err = tostring(f_or_err) })
                fired, save_short = false, nil
            else
                fired, save_short = f_or_err, s_or_nil
            end
        else
            fired, save_short = run_chain_walk(self, intent, threat_mod, threat_caster,
                                               category_hint, ability_name, on_save_fired,
                                               armed_entry, ctx)
        end
    end
    if fired then
        local t_idx, mod_key, k_idx = lock_key(c, ally_unit, canonical_mod, threat_caster)
        if t_idx then
            local entry = self.in_flight_locks_ally[t_idx]
                        and self.in_flight_locks_ally[t_idx][mod_key]
                        and self.in_flight_locks_ally[t_idx][mod_key][k_idx]
            if entry then
                entry.save_short  = save_short or entry.save_short
                entry.intent      = intent
                entry.armed_entry = armed_entry
            end
        end
        return true
    end
    self:_ReleaseLockOnDomain(self.in_flight_locks_ally, ally_unit, canonical_mod, threat_caster, true)
    return false
end

---Walk the resolved chain and fire the first eligible save. First-success-wins
---(lesson 3). Homing close-gap threats skip self-displacement saves (lesson 5).
---On a successful fire, `on_save_fired(intent, fire_short, threat_mod,
---threat_caster)` is called. The hero's callback OWNS throttle bookkeeping
---(typically chains through to dispatcher:MarkFired via the hero's record_save
---and mark_layer2_fired adapters); the lib does NOT mark fired on its own here,
---to avoid double-writing the throttle state when the hero already does so.
---Direct callers that bypass TrySaveSelf (lotus-first / ally-save) call
---MarkFired through the same hero chain.
---
---v0.5.40 TIER 0: TrySaveSelf is now a thin compat wrapper around Dispatch
---so existing Lina call sites (armed_threats_tick, persistent_threats_tick,
---events) keep working unchanged while the Routing phase migrates them to
---Dispatch directly. Behaviour: identical to v0.5.39 for callers that do
---NOT supply ctx and do NOT trigger lock contention (the common case);
---callers that hit a live lock get a dispatch_blocked tlog + false return.
---@param intent string
---@param threat_mod string|nil
---@param threat_caster any
---@param category_hint string|nil
---@param ability_name string|nil
---@param on_save_fired fun(intent:string, short:string, mod:string|nil, caster:any)|nil
---@param armed_entry table|nil
---@param ctx table|nil  v0.5.40 GAP-3 ResolveSaveOrder context (optional)
---@return boolean fired
function Dispatcher:TrySaveSelf(intent, threat_mod, threat_caster,
                                category_hint, ability_name, on_save_fired,
                                armed_entry, ctx)
    local c = self.cfg
    local target_unit = c.self_npc and c.self_npc() or nil
    return self:Dispatch(intent, threat_mod, threat_caster, target_unit,
                         nil, category_hint, ability_name,
                         armed_entry, on_save_fired, ctx)
end

----------------------------------------------------------------------------
-- Dispatcher:HandleLineProjectile (v0.5.147 lib-first lift)
----------------------------------------------------------------------------
-- Line-projectile intercept: the general item-save mechanism for hooks /
-- arrows / bolts that travel in a straight line and grab/stun the FIRST unit
-- in their path (Pudge Hook, Mirana Arrow, Magnus Skewer, Sven Bolt, ES
-- Fissure, Clockwerk Hookshot). Fires a perpendicular-distance displacement
-- save (Force / Pike / Blink / WW via the line_projectile chain) in the
-- projectile-create -> arrival window so the victim is pushed OUT of the line
-- BEFORE it connects (OnModifierCreate fires only after the grab is committed).
-- Byte-equivalent port of Lina's former hero-local OnLinearProjectileCreate body
-- (same gates, same tlog stream, same Dispatch); only the data (opts.catalog =
-- ThreatData.LINE_PROJECTILE_INTERCEPTS) + hero glue arrive via opts. Engine
-- globals Entity / NPC / string are used directly (in lib scope); Target /
-- NPCLib are project libs NOT in this module's scope, so is_enemy_hero / origin
-- come via opts. The fire is self:Dispatch (this dispatcher). Opt-in: a hero
-- gets this only by calling it from its OnLinearProjectileCreate (Sniper keeps
-- its own duplicate until separately migrated).
--
-- opts = {
--   me, catalog, tlog3 (bool), enabled()->bool, subsystem_on()->bool,
--   origin(npc)->pos, uname(npc)->str, is_enemy_hero(src,me)->bool,
--   dedup_responded(src,mod)->bool, dedup_mark(src,mod), record_save,
--   fs_shard_window()->bool,
-- }
function Dispatcher:HandleLineProjectile(data, opts)
    local c   = self.cfg
    local tl3 = opts and opts.tlog3
    local me  = opts and opts.me
    -- v0.5.147.1 DIAGNOSTIC (temporary): unconditional entry log to settle
    -- whether the framework delivers each projectile to OnLinearProjectileCreate.
    -- The v0.5.147 demo showed only mirana/magnus reached line_projectile_seen,
    -- but the skip reasons are level-3 (hidden if verbosity dropped < 3), so
    -- absence of a log was NOT proof the callback never fired. This logs EVERY
    -- invocation + raw src at level 1 (rare event -- the demo had ~4 total).
    -- Remove once the hook-detection question is settled.
    do
        local s = data and data.source
        local sn = "?"
        if s and Entity.IsEntity(s) and Entity.IsNPC and Entity.IsNPC(s) then
            sn = (opts and opts.uname and opts.uname(s)) or "?"
        end
        c.tlog(1, "olpc_entered", { src = sn })
    end
    if not me or not data then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "no_self_or_data" }) end
        return
    end
    if opts.enabled and not opts.enabled() then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "defense_off" }) end
        return
    end
    if opts.subsystem_on and not opts.subsystem_on() then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "subsystem_off" }) end
        return
    end
    local src = data.source
    if not src or not Entity.IsEntity(src) or not Entity.IsNPC(src) then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "src_not_npc" }) end
        return
    end
    if not (opts.is_enemy_hero and opts.is_enemy_hero(src, me)) then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "src_not_enemy" }) end
        return
    end
    local src_name = NPC.GetUnitName(src)
    local entry = opts.catalog and opts.catalog[src_name]
    if not entry then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "src_not_hook_caster" }) end
        return
    end
    local me_pos   = opts.origin and opts.origin(me)
    local origin   = data.origin or (opts.origin and opts.origin(src))
    local velocity = data.velocity
    if not me_pos or not origin or not velocity then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "missing_geometry", src = opts.uname(src) }) end
        return
    end
    local vel_len = velocity:Length2D()
    if vel_len < 1 then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "zero_velocity", src = opts.uname(src) }) end
        return
    end
    local dir   = velocity:Normalized()
    local to_me = me_pos - origin
    local along = to_me:Dot(dir)
    -- Heading-toward gate: origin behind us along travel axis -> reject; also
    -- prevents firing on a projectile already past us (Sniper's along<0 gate).
    if along < 0 then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "heading_away", src = opts.uname(src) }) end
        return
    end
    local perp = (to_me - dir * along):Length2D()
    if tl3 then
        c.tlog(3, "line_projectile_seen", {
            src   = opts.uname(src),
            vel   = string.format("%.0f", vel_len),
            perp  = string.format("%.0f", perp),
            along = string.format("%.0f", along),
        })
    end
    local fire_floor = entry.hit_radius + 75
    if perp >= fire_floor then
        if tl3 then
            c.tlog(3, "line_projectile_skip", {
                src    = opts.uname(src),
                reason = "perp_over_floor",
                perp   = string.format("%.0f", perp),
                floor  = tostring(fire_floor),
            })
        end
        return
    end
    -- Dedup key: prefer the canonical mod (matches OnModifierCreate's eventual
    -- mark so the modifier-lands path no-ops); fissure (no mod) falls back to
    -- "<ability>_incoming" -- unique per cast, no catalog-mod collision.
    local dedup_mod = entry.threat_mod or (entry.ability .. "_incoming")
    if opts.dedup_responded and opts.dedup_responded(src, dedup_mod) then
        if tl3 then c.tlog(3, "projectile_skip", { reason = "dedup_hit", src = opts.uname(src), mod = dedup_mod }) end
        return
    end
    c.tlog(1, "line_projectile_intercepted", {
        src     = opts.uname(src),
        ability = entry.ability,
        perp    = string.format("%.0f", perp),
        along   = string.format("%.0f", along),
        floor   = tostring(fire_floor),
    })
    -- Mark dedup BEFORE the dispatch (and after the geometry gate), so a
    -- no-save-available result still throttles the next per-projectile event
    -- within THREAT_WINDOW (the v0.5.14 BL-A6 convention). Dispatch then routes
    -- the displacement chain via category_hint="line_projectile" (the lock tuple
    -- is (me, canonical(threat_mod), src); nil src/threat_mod collapse the lock
    -- leg and fall through to the unlocked path, safe for fog projectiles).
    if opts.dedup_mark then opts.dedup_mark(src, dedup_mod) end
    self:Dispatch("line_intercept_" .. entry.ability,
                  entry.threat_mod, src,
                  me, nil,
                  "line_projectile", entry.ability, nil,
                  opts.record_save,
                  { fs_shard_window = opts.fs_shard_window and opts.fs_shard_window() or false })
end

----------------------------------------------------------------------------
-- ETA resolver factories (v0.5.74 lift from Lina LINA_ETA_RESOLVERS)
----------------------------------------------------------------------------
--
-- Generic factories that build per-mod ETA-resolver closures compatible with
-- the resolve_ttl signature (caster, target, armed_entry, ability_handle,
-- now_t, canonical_mod). Heroes opt in by populating cfg.eta_resolver with
-- entries built by these factories. All four are stateless and engine-only;
-- no hero state leaks into the closures.
--
-- Lifted from Lina.lua's _lina_eta_make_{cast_point,remaining,dist_speed,line}
-- per the v0.5.74 lib-first audit. Each is pure data + engine calls; building
-- the resolver table is then just `EtaR.CastPoint(0.5)`, `EtaR.Remaining(
-- "modifier_lion_voodoo", nil, 0.5)`, etc. Sniper picks them up for free
-- once it migrates to a Defense-cfg dispatcher.

Defense.EtaResolvers = {}

-- Distance helper inlined to keep lib/defense.lua dependency-free
-- (lib/geometry has dist_between but introducing a require would couple two
-- libs that have been independent so far). Two-line copy is fine.
local function _dist2d(a_unit, b_unit)
    if not a_unit or not b_unit then return 0 end
    if Entity.IsEntity and (not Entity.IsEntity(a_unit) or not Entity.IsEntity(b_unit)) then
        return 0
    end
    local a_ok, a = pcall(Entity.GetAbsOrigin, a_unit)
    local b_ok, b = pcall(Entity.GetAbsOrigin, b_unit)
    if not (a_ok and b_ok and a and b) then return 0 end
    local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

-- Remaining seconds on a named modifier, or nil when it cannot be read.
--
-- v0.1.352: every reader in this file used to call `NPC.GetModifierRemaining`,
-- WHICH DOES NOT EXIST in the UCZone API (gitbook-verified: the NPC page documents
-- GetModifier / GetModifiers / HasModifier / HasAnyModifier / GetModifierByIndex /
-- GetModifierProperty / GetModifierPropertyHighest, and no remaining-duration
-- reader). Each call site guarded on the field before calling it, so the guard was
-- ALWAYS false, the pcall never ran, and every site silently took its own default
-- forever. Confirmed live in g352: 5 x `eta_resolver_fallback ... ttl=2.00`.
--
-- The documented path is NPC.GetModifier -> Modifier.GetDieTime, differenced
-- against GameRules.GetGameTime; both are "game time" per the docs, so the
-- subtraction is same-clock.
--
-- SANITY BAND, and it is load-bearing: a result outside (0, MOD_REMAINING_MAX_S]
-- is treated as UNREADABLE and returns nil, so every caller degrades to exactly
-- its pre-fix default rather than inventing a lock. This codebase has already paid
-- for the opposite choice once - the fog-age model differenced two DIFFERENT clocks,
-- went negative, clamped to zero, and silently disabled five constants for 275
-- versions. If GetDieTime ever turns out to sit on another clock, this fix goes
-- quiet instead of locking saves out for a minute and a half.
local MOD_REMAINING_MAX_S = 30      -- Doom (16s) is the longest debuff worth locking on; a
                                    -- pregame-offset mismatch reads ~90s and is refused
local function _mod_remaining(unit, mod_name)
    if not (unit and mod_name) then return nil end
    if Entity.IsEntity and not Entity.IsEntity(unit) then return nil end
    if not (NPC.GetModifier and Modifier and Modifier.GetDieTime
            and GameRules and GameRules.GetGameTime) then return nil end
    local ok, rem = pcall(function()
        local m = NPC.GetModifier(unit, mod_name)
        if not m then return nil end
        local die = Modifier.GetDieTime(m)
        if type(die) ~= "number" then return nil end
        return die - GameRules.GetGameTime()
    end)
    if not ok or type(rem) ~= "number" then return nil end
    -- POSITIVE form, deliberately: `rem <= 0 or rem > MAX` lets NaN through, because every
    -- NaN comparison is false. A NaN would reach clamp_ttl, survive math.min/math.max
    -- (which propagate it), and stamp a lock whose expiry test is never true - a lock that
    -- never releases. Phrasing it as "must be inside the band" refuses NaN for free.
    if not (rem > 0 and rem <= MOD_REMAINING_MAX_S) then return nil end
    return rem
end

---Pre-cast / cast-point class. Returns a resolver that prefers
---armed.cast_point + armed.arm_t (stamped at arm-time, drift-free); falls
---back to a pcall-wrapped live `Ability.GetCastPoint(handle, true)`, then
---cp_default. Result clamped to >= floor_s (default 0.1).
---@param cp_default number  fallback cast-point seconds
---@param floor_s number?  lower clamp on returned ETA (default 0.1)
function Defense.EtaResolvers.CastPoint(cp_default, floor_s)
    floor_s = floor_s or 0.1
    return function(_caster, _target, armed, ab, now_t)
        if armed and armed.cast_point and armed.arm_t then
            local rem = armed.cast_point - ((now_t or 0) - armed.arm_t)
            if rem < floor_s then rem = floor_s end
            return rem
        end
        if ab and Ability.GetCastPoint then
            local ok, cp = pcall(Ability.GetCastPoint, ab, true)
            if ok and type(cp) == "number" and cp > 0 then
                if cp < floor_s then cp = floor_s end
                return cp
            end
        end
        local d = cp_default or 0.5
        if d < floor_s then d = floor_s end
        return d
    end
end

---Active-debuff class. Returns a resolver that reads the target's remaining
---time on `mod_name` via `_mod_remaining` (NPC.GetModifier -> Modifier.GetDieTime
---minus GameRules.GetGameTime; see its header for why the obvious-looking
---`NPC.GetModifierRemaining` is NOT used - it does not exist). cap_s clamps so the
---periodic re-fire pattern (persistent_threats_tick) can re-acquire before the
---lock TTL elapses. An unreadable modifier leaves rem at 0 and floors to floor_s
---(safe, minimal lock) - i.e. exactly the pre-v0.1.352 behaviour.
---@param mod_name string  target-side modifier to read remaining-time from
---@param cap_s number?  upper clamp (default unlimited)
---@param floor_s number?  lower clamp (default 0.1)
function Defense.EtaResolvers.Remaining(mod_name, cap_s, floor_s)
    floor_s = floor_s or 0.1
    return function(_caster, target, _armed, _ab, _now_t)
        local rem = _mod_remaining(target, mod_name) or 0
        if cap_s and rem > cap_s then rem = cap_s end
        if rem < floor_s then rem = floor_s end
        return rem
    end
end

---Armed-chain / instant-blink class. Returns d/speed using the armed entry's
---stamped eta_speed when present, else default_speed. blink_cap clamps the
---result for blink classes (e.g., PA Phantom Strike, QoP Blink); nil means
---no cap. Result floored at 0.05s.
---@param default_speed number  fallback travel speed (u/s)
---@param blink_cap number?  upper clamp (typical 2.0s for blinks)
function Defense.EtaResolvers.DistSpeed(default_speed, blink_cap)
    return function(caster, target, armed, _ab, _now_t)
        local v = (armed and armed.eta_speed) or default_speed
        if not v or v <= 0 then v = default_speed end
        local d = _dist2d(caster, target)
        local eta = d / v
        if blink_cap and eta > blink_cap then eta = blink_cap end
        if eta < 0.05 then eta = 0.05 end
        return eta
    end
end

---Line-projectile class (meat hook, mirana arrow, sven bolt). Returns
---d/speed when caster + target both exist; falls back to armed.eta_trigger
---or fog_fallback when caster is in FoW (caster nil).
---@param speed number  projectile speed (u/s)
---@param fog_fallback number?  fallback when caster invisible (default 1.0)
function Defense.EtaResolvers.Line(speed, fog_fallback)
    return function(caster, target, armed, _ab, _now_t)
        if not caster or not target or (Entity.IsEntity and not Entity.IsEntity(caster)) then
            local fb = (armed and armed.eta_trigger) or fog_fallback or 1.0
            if fb < 0.1 then fb = 0.1 end
            return fb
        end
        local d = _dist2d(caster, target)
        local eta = d / (speed or 1100)
        if eta < 0.1 then eta = 0.1 end
        return eta
    end
end

---Generic catalog-aware fallback. Returns a closure bound to the supplied
---TD (so the lib doesn't take a circular dependency on threat_data). The
---closure consumes the canonical_mod 6th arg from resolve_ttl and looks up
---the catalog's THREAT_ARRIVAL_TIMING entry. Branches by entry.kind:
---  channel_at_caster -> caster-side remaining (_mod_remaining), else cast_point
---  cast_point_*      -> cast_point + post_cast_delay
---  homing kinds      -> dist(caster, target) / speed_fallback
---  no catalog        -> target-side remaining (_mod_remaining)
---  no data           -> nil (lib falls back to cfg.fallback_lock_ttl_s)
---@param TD table  ThreatData module (lib.threat_data)
---@param opts table?  { lock_cap_s = number }  default 1.7s
function Defense.MakeGenericEtaResolver(TD, opts)
    opts = opts or {}
    local lock_cap_s = opts.lock_cap_s or 1.7
    return function(caster, target, _armed, _ab, _now_t, mod_name)
        if not (mod_name and TD and TD.THREAT_ARRIVAL_TIMING) then return nil end
        local entry = TD.THREAT_ARRIVAL_TIMING[mod_name]
        if entry then
            if entry.kind == "channel_at_caster" then
                local rem = _mod_remaining(caster, mod_name) or 0
                if rem > 0 then
                    if rem > lock_cap_s then rem = lock_cap_s end
                    if rem < 0.1 then rem = 0.1 end
                    return rem
                end
                -- fall through to cast_point if remaining unavailable
            end
            if entry.cast_point and entry.cast_point > 0 then
                local total = entry.cast_point + (entry.post_cast_delay or 0)
                if total < 0.1 then total = 0.1 end
                return total
            end
            if entry.speed_fallback and entry.speed_fallback > 0
               and (entry.kind == "homing_charge" or entry.kind == "homing_carry"
                    or entry.kind == "instant_blink") then
                local d = _dist2d(caster, target)
                local eta = d / entry.speed_fallback
                if eta < 0.05 then eta = 0.05 end
                return eta
            end
        end
        local rem = _mod_remaining(target, mod_name)
        if rem then
            if rem > lock_cap_s then rem = lock_cap_s end
            if rem < 0.1 then rem = 0.1 end
            return rem
        end
        return nil
    end
end

----------------------------------------------------------------------------
-- Deferred-dodge timing (v0.5.160.3 Note-1 lib-first lift)
----------------------------------------------------------------------------
-- General "accept the first strike, then dodge mid-channel" timing for an enemy
-- multi-strike ult the target negates by going untargetable (cyclone-class: Wind
-- Waker / Eul) but which REFUNDS if the target is untargetable at cast yet WASTES if
-- the target vanishes after it commits -- canonically Juggernaut Omnislash (dodging
-- in the ~0.3s cast point cancels+refunds; dodging mid-ult whiffs the rest of the
-- strikes -> Jugg loses the ult). Hero-agnostic: any hero with an untargetable dodge
-- opts in by calling these from its own channel-anim handler + per-frame tick. The
-- hero owns the trigger, the save chain, and the menu; the lib owns the DECISION +
-- the defer state machine. Engine globals Entity / NPC run lib-side; the fire is the
-- hero's dispatch closure (its own chain).

-- Pure decision: defer the untargetable dodge iff NO immediate save (attack-immune
-- but still TARGETABLE, e.g. Ghost / Ethereal -- these do not cancel the cast) is
-- ready AND the target has the HP to safely eat the first strike. Below the floor,
-- dodge at cast to SURVIVE (the caster keeps the ult, the target lives). Offline-tested.
function Defense.ShouldDeferDodge(immediate_ready, cur_hp, min_hp)
    return (not immediate_ready) and ((cur_hp or 0) >= (min_hp or 0))
end

-- Arm a pending deferred dodge (one at a time). cfg = { caster, watch_modifier,
-- fire_at (absolute time), min_hp }. Call only when ShouldDeferDodge is true.
function Dispatcher:ArmDodgeDefer(cfg)
    self._dodge_defer = cfg
end

-- Per-frame tick. opts = { me, now (number), dispatch(caster, via, hp) }. Fires the
-- hero's dispatch mid-channel (now >= fire_at) OR early if a strike dropped the
-- target below min_hp (via="hp_bail"); clears when the channel ends (watch_modifier
-- left the caster) or the target dies. The hero's dispatch runs its own save chain.
function Dispatcher:DodgeDeferTick(opts)
    local d = self._dodge_defer
    if not d then return end
    local me = opts and opts.me
    if not (me and Entity.IsAlive and Entity.IsAlive(me)) then self._dodge_defer = nil; return end
    local caster = d.caster
    if not (caster and Entity.IsEntity and Entity.IsEntity(caster)) then self._dodge_defer = nil; return end
    local now_t   = (opts and opts.now) or 0
    local cur_hp  = (Entity.GetHealth and Entity.GetHealth(me)) or 0
    local hp_bail = cur_hp < (d.min_hp or 0)
    -- WAIT through the caster's cast point: the ult modifier lands at cast-COMPLETE, so
    -- it is NOT on the caster during the cast point right after arm -- do NOT clear on a
    -- missing modifier here (that was the v0.5.160.3 "didn't land" bug: the tick cleared
    -- every frame of the ~0.3s cast point before the ult committed). Hold until fire_at,
    -- unless a strike already dropped the target to the floor (bail early).
    if now_t < (d.fire_at or 0) and not hp_bail then return end
    -- Due (or HP-critical): dodge ONLY if the ult actually committed (watch_modifier
    -- present = mid-ult). If absent, the cast was cancelled/refunded or already ended ->
    -- nothing to dodge; clear (the normal reactive save path covers anything else).
    if NPC.HasModifier and NPC.HasModifier(caster, d.watch_modifier) and opts.dispatch then
        opts.dispatch(caster, hp_bail and "hp_bail" or "mid_ult", cur_hp)
    end
    self._dodge_defer = nil
end

return Defense
