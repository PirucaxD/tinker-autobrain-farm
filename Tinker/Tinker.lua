---@meta
---Tinker brain (farm-first). The auto-farm subsystem (Layer F) on the Lina/Sniper
---brain skeleton. See Tinker/FARM_PATTERN.md (the Layer F spec),
---Tinker/TINKER_BRAIN_SKELETON.md (the shell), Tinker/BRIDGE_TINKER_NEW_HERO.md.
---
---F0: the scope-A farm FSM re-homed onto the skeleton, NO farm-behavior change.
---Shell = cache-clear+require, Logger/tlog telemetry, the State table, setup_menu
---(Find-then-Create under Heroes/Hero List/Tinker/Brain), callbacks.OnUpdateEx
---layered dispatch, the hero-gate wrapper, return callbacks. The order chokepoint
---stays direct issue() (V2-confirmed issuer/flags that fire the point casts);
---now() stays GameRules.GetGameTime() to avoid a timing change in the re-home.
---Jungle only; lane/split-push/stacking + the farm-button (F5) + defense/offense
---are later phases. UNVERIFIED in-engine: F1 = in-client calibration.

if package and package.loaded then
    -- v0.1.394 (phase 0 hygiene): the list had drifted to 15 of the 22 required libs, so a
    -- mid-session hot-reload gave SEVEN modules (timing, towers, hero_data, ability_data,
    -- threat_data, draw, vision) a fresh wrapper over a stale cached dependency. Known since the
    -- Tier-6 audit; fixed at CURRENT names before any consolidation renames land on top.
    for _, m in ipairs({ "lib.map", "lib.farm", "lib.lane",
                         "lib.escape", "lib.hero_value", "lib.geometry", "lib.map_data", "lib.channel_gate",
                         "lib.defense", "lib.item_saves", "lib.target",
                         "lib.timing", "lib.hero_data", "lib.ability_data",
                         "lib.threat_data", "lib.draw" }) do   -- lib.vision entry dropped at v0.1.399: absorbed
                         -- into lib.escape (whose entry STAYS); the tracker state is store-anchored so this clear
                         -- refreshes the module without wiping the shared last-seen store.
        package.loaded[m] = nil
    end
end
local Map       = require("lib.map")
local Farm      = require("lib.farm")
local Timing    = require("lib.timing")   -- v0.1.334: the arrival-watchdog ruler
local HeroValue = require("lib.hero_value")
local MapData   = require("lib.map_data")   -- static positions fallback (camps/towers/outposts/fountains)
local Lane      = require("lib.lane")        -- lane intel (waves + clash + intercept), Task C foundation
-- (lib.shove + lib.farm_decide were CONDENSED into lib.farm 2026-07-01 - cohesive domain libs, like
-- C's math.h: Farm.CrashCast / Farm.MarchCovers / Farm.OutsideTowerRange.)
local Escape    = require("lib.escape")        -- fog-aware proximity risk (COR-1)
local Geometry  = require("lib.geometry")      -- pure geometry: teleport reach-disc landing (Keen/BoT)
local HeroData    = require("lib.hero_data")    -- ARC E1: enemy kits (which laner carries a channel-breaking disable)
local AbilityData = require("lib.ability_data") -- ARC E1: disable cast ranges (static, per level)
local ThreatData  = require("lib.threat_data")  -- ARC E1: ability -> threat modifier -> role classification
local ChannelGate = require("lib.channel_gate") -- ARC E1: the pure kit-aware channel-gate predicate
local Defense   = require("lib.defense")      -- ARC E2: the save dispatcher (Lina-proven, byte-identical)
local ItemSaves = require("lib.item_saves")   -- ARC E2: hero-agnostic defensive item save bodies (requires lib.target itself; no item_data dependency)
local Target    = require("lib.target")       -- ARC E2: enemy-hero test for the harvest filter (also loaded transitively by item_saves/escape)
local Draw      = require("lib.draw")         -- v0.1.324 headroom lift wave 1: screen-space drawing/debug rendering (Font/W2S/Text/WorldText/Ring/Line/Seg/OBox)
-- (lib.vision was ABSORBED into lib.escape at v0.1.399, consolidation phase 3: the tracker is
-- Escape.Vision now, its state anchored in a package.loaded pseudo-key store so cache-clearing
-- lib.escape cannot fork it per hero.)

-- Logger is a callable TABLE (not a function); construct via pcall, else a
-- type=="function" guard silences all logging. Writes [INFO] [Tinker] to
-- C:\Umbrella\debug.log (same channel as Lina/Sniper).
-- v0.1.399: DECLARED ABOVE THE TRIPWIRE BLOCK BELOW, which logs through it. It used to sit
-- below, so the tripwire's `LOG` read resolved as a nil GLOBAL and the guard was permanently
-- false - the STALE SHARED LIB line could NEVER print, silently, since v0.1.388 (found by the
-- phase-3 adversarial review; same definition-below-caller class as the v0.1.398 abil_mana fix).
local LOG
do local ok, l = pcall(function() return Logger("Tinker") end); if ok then LOG = l end end

-- ── SHARED-LIB TRIPWIRE (v0.1.388) ───────────────────────────────────────────
-- C:/Umbrella/scripts/lib is ONE directory shared by every hero package a user installs, so a
-- second package can overwrite a lib with an OLDER copy and strip functions this hero calls. The
-- failure mode is terrible: `attempt to call a nil value (field 'DepthRuler')` thrown from inside
-- OnUpdateEx EVERY DECIDE, with a traceback that names Tinker.lua and blames the wrong file.
-- REPORTED IN THE FIELD (user jonat): the public dota-hero-brains package ships lib/lane.lua at
-- 410 lines against this tree's 930, and 18 of the 26 libs the two packages share DIFFER. That one
-- install is missing 25 functions across 5 libs (lane: BuildLanePaths/Depth/DepthRuler/
-- PredictMeeting/PushForecast/TrackFrontSpeed, farm: CrashCast/DepthPoints/GreedyPairs/MarchCovers/
-- ObservedFarmers/OutsideTowerRange/PathRisk, escape: CommitWiden/DiagGate/FogProximityRisk/
-- MissingCount/NearestEnemyEdge/ReachableFog, schedule: CycleFill/NextOnGrid/StackWindow/
-- WaveCycleCost, geometry: BestReachLanding/DiscReachPoint), so fixing one symbol just uncovers
-- the next. It is a PACKAGING fault, not a code fault, and no amount of reading Tinker.lua finds it.
-- This is a SENTINEL, not a contract: one or two of the newest exports per shared lib, which is
-- what a stale copy loses first. It is LOG-ONLY and deliberately does not disable the brain - the
-- point is to put one actionable line at the top of the log instead of a per-tick traceback.
do
    local need = {
        -- v0.1.395: lane absorbed route+schedule (phase 1 of the consolidation). The lane entry
        -- carries ABSORBED-LIB sentinels (dotted paths, resolved below) so a restored PRE-merge
        -- lane.lua - which passes the flat sentinels by design - fails loudly at load instead of
        -- nil-crashing the hero every decide.
        ["lib/lane.lua"]          = { Lane,     "Lane",     { "DepthRuler", "PushForecast", "Route.Plan", "Schedule.CycleFill" } },
        ["lib/farm.lua"]          = { Farm,     "Farm",     { "CrashCast", "ObservedFarmers" } },
        -- v0.1.399: escape absorbed vision (phase 3, the only THREE-HERO file). Dotted sentinel so
        -- a restored PRE-merge escape.lua fails loudly at load instead of nil-crashing every decide.
        -- v0.1.409: Vision.ShadowAges added (build 1 of the fog-tracker arc). A pre-.409
        -- escape.lua still has Vision.Wire, so without this sentinel a stale copy would pass
        -- the tripwire and then nil-crash at the first shadow-risk read.
        ["lib/escape.lua"]        = { Escape,   "Escape",   { "CommitWiden", "NearestEnemyEdge", "Vision.Wire", "Vision.ShadowAges" } },
        ["lib/geometry.lua"]      = { Geometry, "Geometry", { "DiscReachPoint" } },
        -- v0.1.396: map absorbed nav+towers+position_data (phase 2). Dotted sentinels so a
        -- restored PRE-merge map.lua fails loudly at load, naming the missing symbol.
        ["lib/map.lua"]           = { Map,      "Map",      { "TowersInRadius", "Nav.SafeDest", "Towers.Track", "Positions.Shadow" } },
    }
    local bad = {}
    for file, spec in pairs(need) do
        local mod, name, fns = spec[1], spec[2], spec[3]
        if type(mod) ~= "table" then
            bad[#bad + 1] = file .. " (module did not load)"
        else
            for _, fn in ipairs(fns) do
                local cur = mod
                for part in fn:gmatch("[^%.]+") do cur = (type(cur) == "table") and cur[part] or nil end
                if type(cur) ~= "function" then
                    bad[#bad + 1] = file .. " is missing " .. name .. "." .. fn
                end
            end
        end
    end
    if #bad > 0 and LOG then
        table.sort(bad)
        LOG:info("Tinker STALE SHARED LIB: " .. table.concat(bad, "; ")
            .. ". Another hero package in scripts/lib has overwritten a lib with an older copy. "
            .. "Tinker will throw a nil-value error every decide until the WHOLE lib directory is "
            .. "replaced with the one shipped alongside this Tinker.lua. Fixing a single file is "
            .. "not enough: the stale set is missing many functions and you will just hit the next.")
    end
end
-- (lib.dedup require DROPPED at Task 3 review: the dispatcher's in_flight_locks
-- subsume the responded-dedup role per lib/defense.lua:22-26.)

local UO = Enum.UnitOrder
local HERO_KEY = "tinker"

-- Forward-declared module state; telemetry + helpers capture it as an upvalue.
local State = {}

----------------------------------------------------------------- telemetry --
-- (LOG is declared ABOVE the shared-lib tripwire block near the top of the file - it must
-- already exist when the tripwire fires at load. See the v0.1.399 note there.)

local function v_level()
    if State.menu and State.menu.diag then return State.menu.diag:Get() end
    return 1
end

-- Verbosity-gated structured logging: "event | k=v | k=v". level 0=err 1..2=info 3=trace.
local function tlog(level, event, kv)
    if not LOG then return end
    if level > v_level() then return end
    local parts = { event }
    if kv then
        for k, v in pairs(kv) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    end
    local msg = table.concat(parts, " | ")
    if     level == 0 then pcall(function() LOG:error(msg) end)
    elseif level <= 2 then pcall(function() LOG:info(msg) end)
    else                   pcall(function() LOG:debug(msg) end)
    end
end

-- Legacy line logger: routes the scope-A logline(string) calls through tlog at
-- level 1 so they stay verbosity-gated. New code calls tlog(level, event, kv).
local function logline(s) tlog(1, s) end

-- ── tuning (all calibratable; March extents confirmed only in-game) ──────────
local K = {
    MARCH_LEN       = 1800, MARCH_HALFWIDTH = 900, MARCH_CAST_RANGE = 300,   -- coverage = rectangle CENTRED on the cast point: +/- MARCH_LEN/2 along facing, +/- HALFWIDTH perpendicular (Liquipedia: target = area centre; robots spawn at the back edge behind Tinker). CALIBRATED in-client 2026-06-24: the real sweep is a ~SQUARE box (HALFWIDTH 900, was a too-thin 450); MARCH_LEN kept canonical 1800 (the real footprint reads slightly longer but that's likely item/level/just visual).
    ARRIVE_DIST     = 120,   -- must be THIS close to the computed stand before casting W (so the cast point at the camp centre is within cast range)
    MARCHES         = { [0] = 2, [1] = 2, [2] = 2, [3] = 4 },  -- per camp tier 0=small 1=medium 2=large 3=ancient (0-indexed). v0.1.183 user-calibrated PLANNING floors (per-creep damage model): small/medium/large 2 (big camps clear in 2, at most 3 - the live execution budget tops up the occasional 3rd from the on-arrival ehp; Bottle/regen cover its mana), ancient 4 (user: 3-4, Dragon ~5 self-corrects live).
    STACK_AGGRO_SEC = 54.0,                       -- v0.1.224 STACKING (user: LARGE camps only, 2x cap, GPM-first): aggro second-of-minute (Liquipedia: most camps ~:54-55, varies by box) - the old creeps cross the :00 respawn and the camp doubles. Calibrate off stack_done -> next-cycle cstk=2.
    STACK_STAND_DIST = 450,                       -- stand this far from the camp centre toward our fountain for the aggro attack (Tinker attack range 500)
    STACK_FLEE_DIST  = 700,                       -- after the aggro, drag the creeps this far past the stand until :00 (out of the spawn box)
    STACK_NEAR_R     = 2000,                      -- v0.1.338 (user doctrine, g339): a stack node EMITS only with the hero ALREADY this close to the camp - stacking is a convenience when we are at/near the camp on time, NEVER a dispatched trip (g339: keen jump 5938 + 26s walk for a 63g node that won an empty plan)
    STACK_AGGRO_DWELL_S = 0.7,                    -- v0.1.338 (g339, the .224 machinery's first live fire): hold after the aggro ATTACK order until the attack LANDS (Tinker attack point ~0.35 + margin) - the drag move_to used to fire 0.1s later and CANCEL the attack: no aggro, no chase, no stack
    STACK_VALUE_FRAC = 0.6,                       -- planner value of a stack node = the camp's gold x this (the extra gold lands NEXT cycle; same discount spirit as ROUTE_STEP_DECAY)
    MAX_CLEAR_MARCHES = 6,                                    -- cap on Marches to clear ONE camp. A camp is a candidate iff clearable within this (ceil(ehp/per-cast dmg) <= this); the same cap bounds the valuation + execution count. Unifies candidacy with execution (was: candidacy used a fixed tier count while execution added Marches -> tanky/stacked/low-March-level camps wrongly excluded). Calibrate.
    PER_MARCH_DMG   = { 13, 22, 31, 40 },                     -- detonate dmg per robot per March level (7.41c)
    ROBOTS_EFFECTIVE = 24,                                    -- robots that realistically detonate on a clustered camp (CALIBRATE; max 144)
    CAMP_MR         = { [0] = 0.0, [1] = 0.0, [2] = 0.0, [3] = 0.30 }, -- coarse fallback by tier; live per-unit MR read is primary
    REARM_CHANNEL   = { 2.69, 1.93, 1.20 },                  -- channel time per Rearm level (IN-CLIENT v0.1.130 capture; was 2.75/2/1.25)
    CHANNEL_PAD     = 0.20,                                   -- timer backstop beyond the channel
    KEEN_CHANNEL    = 2.93,                                   -- Keen channel, FLAT all levels (IN-CLIENT v0.1.130 capture; was a padded 4.0 -> overestimated keen-travel ~1s on every timing decision). Also the InterceptETA travel cost.
    KEEN_LAND_STRUCTURE = 700,                                -- Keen reach radius around a tower/building: we can land ANYWHERE within this of it (user-confirmed 700, not the KV 800). We cast at the point in this disc nearest the stand, so travel ~= 0 when a tower covers the stand.
    KEEN_LAND_OUTPOST   = 250,                                -- ... and this of an outpost/watch-tower
    KEEN_CREEP_MIN_HP   = 300,                                -- v0.1.215: a keen-anchor creep must survive the ~3s channel (a dying one cancels the keen + burns the cd). Rear units (ranged/siege) are preferred structurally; this floors the rest. Calibrate.
    KEEN_CREEP_DRIFT_S  = 3.5,                                -- v0.1.228/236 (user rule, motion-aware): creep-anchor exclusion around ALIVE enemy towers = TOWER_RISK_RADIUS 900 + measured lane wave speed x this (the cast->teleport window: KEEN_CHANNEL + pad + order latency). Marching wave 325 -> ~2040 (the v0.1.228 worst case); stalled tower fight -> rear creeps eligible again (run-54 over-exclusion fix). Calibrate.
    KEEN_WAIT_MARGIN    = 4.0,                                -- v0.1.232 wait-for-keen rung: hold for the keen cd only when cd + channel + this margin still beats the walk (short walks keep walking). Calibrate.
    KEEN_CREEP_CLEAR    = 250,                                -- reject a keen landing with an ALLIED lane creep within this (Keen L2 auto-conveys to the nearest ally -> the creep would hijack the landing + cancel when it moves/dies). Jungle has none; matters near lanes. Calibrate.
    KEEN_TREE_CLEAR     = 140,                                -- a keen landing needs no TREE within this (GridNav.IsTraversable does NOT flag trees, so a disc-edge point can land in a grove -> stuck). The landing is nudged toward the anchor onto clear ground. Calibrate (hero radius + tree hull).
    KEEN_LAND_SAFE_RISK = 0.35,                               -- TRAVEL-BLINK landing gate: don't blink to a landing whose fog-aware risk + tower risk is >= this (a blink is instant, no en-route abort). The KEEN landing moved to the count-aware lane_unsafe gate at v0.1.157 (glue review F5; the raw gate rejected every landing near a healthy 1v1).
    KEEN_DEPTH_MARGIN   = 150,                                -- HARD STOP for the keen LANDING: a keen lands at the ANCHOR, not the (depth-capped) stand, so it could jump PAST the safe stand under the enemy tower (v0.1.143 capped the stand only). Reject any anchor whose stand_depth is more than this past the safe stand's depth (small margin for the keen's landing scatter). Calibrate.
    FOUNTAIN_WALK_IN    = 1200,                               -- note 5: when within this of the fountain but lacking the regen buff, WALK in (keen lands 70-800 NEAR it, often outside the zone) instead of re-keening outside.
    RETURN_RESUME_FRAC  = 0.70,                               -- note 2 (over-return): abort the trip home + resume farming when mana AND hp recover to this fraction of max EN ROUTE and it's safe (regen/Bottle often refill before we arrive; we were teleporting to base at 70% mana).
    ESCAPE_MANA     = 150,
    REFILL_FRAC     = 0.70,                         -- leave base + Keen back to the farm at THIS fraction of max HP AND mana (was ~full); do not idle at base to 100%.
    PANIC_HP        = 0.40, PANIC_ARM = 0.25,
    CONTEST_RADIUS  = 700,
    CONTEST_LANE_R  = 1200,                        -- v0.1.312 (user): a side lane is YIELDED only when a CORE ally is within this of THAT wave's crash point (he is farming it now); absent = the wave is free. Replaces the coarse x-y diagonal band that marked a lane contested for any core anywhere in the map half. Calibrate: too small = we crash into the carry; too large = we skip free waves he left.
    HERO_FARM_R     = 600,                         -- observed-farmer camp clearing (v0.1.332): a hero within this of a camp centre counts as a sighting. Calibrate: too small misses edge-attackers, too large marks lane-adjacent camps from laning heroes.
    FARMER_DWELL_S  = 4.0,                         -- CONTINUITY GAP, not a confirm window (v0.1.349 correction): a sighting more than this after the previous one starts a NEW dwell run. At the 2s scan cadence one dropped scan still keeps the run.
    FARMER_DWELL_MIN_S = 6.0,                      -- v0.1.349: CONTINUOUS presence BY ONE HERO that means FARMING. The gap alone confirmed nothing but "seen twice", which a hero CROSSING the 1200u circle satisfies (~4s at 300 MS, ~3s at 400 MS) - that walk-through retired 14 live camps in g349. Per-hero because a RELAY of crossers otherwise sums to a dwell nobody served (adversarial review, reproduced). g349 measured its own camp clears at 7.8-12.5s of casting alone, so 6.0 sits above every crossing and below every real clear. 0 restores the pre-.349 confirm threshold.
    CONTEST_JUNGLE_R = 2600,                       -- v0.1.333 jungle-aware lane contest: a CORE ally within 600 of a camp centre AND within this of the wave crash contests the lane (g332 measured the carry 1753 from the bot crash at the false ok:0.00; the deepest triangle camp wants ~2500). Too small re-opens the 7:10 collision; too large yields lanes whose jungle-farmer is not actually coming.
    ARRIVAL_GRACE_S    = 8,                        -- v0.1.334 arrival watchdog: seconds past the ORIGINAL promise before the watchdog wakes (the promise is s.arrivalPromise0, latched before any extend can roll it)
    ARRIVAL_HOLD_T     = 10,                       -- a REAL reachable scan eta <= this counts as imminent and may hold the stand (estimates never hold - the .241 spirit)
    ARRIVAL_HOLD_MAX_S = 15,                       -- hard cap, measured FROM THE PROMISE: past this the stand releases even while the scan claims imminence (g334 t=620: the live eta lied 1-6s for 40 straight seconds while the meet crawled away)
    FARMER_CORE_MARKS  = 2,                        -- v0.1.336 observed-farmer = core: an ALLY attributed this many .332 camp confirms is contest-worthy for the rest of the game (no decay; the g336 offlaner had 4+ by mid-game). Raise to 3 if a two-stray-camps support over-blocks lanes.
    CONTEST_CORE_BASE = 0.55,                      -- a lane wave is YIELDED to a CORE ally: role 1-3 (if a role API exists) OR role-tag base value >= this (carry/nuker/pusher/initiator/durable/disabler/escape >= 0.55; jungler/support/default below). Tunable.
    RISK_RADIUS     = 1400, RISK_HARD = 0.34,   -- camp-selection veto: a camp with risk >= this is NOT picked. Lowered 0.45->0.34 (v0.1.90) so DIRE-side / contested camps (a Radiant Tinker was farming dire camps at risk 0.36-0.44 under the old 0.45) are vetoed; own jungle + own ancient (~0.29-0.32) + up to the river still farm. Tight boundary (own ancient ~0.32 vs dire camp ~0.36); calibrate.
    GANK_RADIUS     = 1000,                      -- v0.1.95: lane_unsafe counts a GANK (>=2 enemies) only within this of the point - 2 DISTANT enemies (the v0.1.94 log recovered at risk 0.06 with enH=2 ~1057u away) are not a gank. Tighter than RISK_RADIUS. ponytail ceiling.
    GANK_FOG_REACH  = 600,                       -- v0.1.158 (F4 recalibration): cap on how far a FOGGED enemy's probable disc extends its gank reach (~1.1s of fog) - the raw disc hits 2750u at the age cap and matched stale enemies from half a screen away (risk-0.14 aborts). v0.1.317 SUPERSEDED by FOG_REACH_CAP 450 (lane_unsafe and raid_gank_ok pass THAT as Escape.ReachableFog's reach_cap): K.GANK_FOG_REACH has ZERO readers file-wide, the NAME is retained because the FOG_REACH_CAP def comment and the lane_unsafe fog-threat note both cite it as what they replaced.
    TOWER_ALIVE_R     = 300,                       -- v0.1.105 lane-prioritization: an enemy tower this near a static T1 spot = that T1 is alive (towers don't move; T1<->T2 mid are ~2200u apart so no cross-match). ponytail ceiling.
    TOWER_DYING_MARGIN_S = 3,                      -- v0.1.246 (TINKER_TOWER_DEATH_DESIGN.md): a crash tower predicted dead before our arrival + this margin excludes the wave this decide (cwhy/verdict tower_dying) - the wave lingers briefly after the fall, so arrival within eta+margin is still farmable.
    HELD_CLOSING_MIN     = 80,                     -- v0.1.256 (arc B re-applied): an enemy wave whose MEASURED speed reads at/below this is HELD/frozen (asrc=held trace tag; the honest eta already does the excluding). Run-64/71: real laners froze mid <100 u/s for long stretches.
    TOWER_RISK_RADIUS = 1050, TOWER_RISK_WEIGHT = 0.7, TOWER_ATTACK_RANGE = 900,   -- v0.1.310 (user OBSERVED the tower attacking Tinker: "Tower Range is 900 not 850"): the real attack range is 900, not the 700 the v0.1.148/.76 calibration assumed. ATTACK_RANGE = full WEIGHT inside the real range, tapering to 0 by RADIUS 1050. WEIGHT 0.7 > SHOVE_SAFE_RISK 0.35 so lane_unsafe + the W2 step-in gate now trip within ~975 (was ~800 = INSIDE real range = the observed tower attacks).
    TOWER_SAFE_MARGIN = 100,                       -- note 1 / option A (v0.1.159): a STAND must sit at least ATTACK_RANGE + this from every alive enemy tower = 1000 (v0.1.310: 100 past the real 900 range). March reach (1200) still covers 200 past the tower from 1000, so the tower-border W-farm is intact. The stand clamp (tower_safe binary) and the taper gates now agree: everything outside real range.
    FOG_MS = 550, FOG_SPREAD = 900, FOG_AGE_CAP = 5,        -- COR-1: fogged-enemy disc growth (Liquipedia move cap) / confidence decay length / drop fog staler than this (s). Tune off the `sched ... risk=` log.
    FARM_SAFE_RISK  = 0.42,                                 -- Part A (N3): abort a COMMITTED camp trip (move/engage) when LIVE fog-aware risk at the stand hits this; mark cleared + recover so the planner picks elsewhere (no churn). Note: FARM_SAFE_RISK 0.42 sits ABOVE RISK_HARD 0.34 (v0.1.90 lowered RISK_HARD) - a committed camp aborts at 0.42 while selection vetoes at 0.34 = a deliberate hysteresis band (no select/abort flip-flop).
    STAND_RING      = 250, STAND_STEP = 30,    -- stand THIS far from the camp CENTRE (< March cast range 300) so W lands on the creep cluster + the hero has vision. The old box-corner ring (cluster_radius+margin) put the stand ~800 out (box half-diag ~737), past cast range, casting short into fog.
    PAIR_RADIUS     = 1800,                       -- pair an assumed-occupied partner within this. The centred March covers up to MARCH_LEN apart, so set ~= MARCH_LEN; 1500 wrongly excluded the river/lane pairs at d=1500-1800. Lower to skip far/edge-clipping pairs. (Specific over-range pairs are whitelisted via K.FORCE_PAIRS.)
    CREEP_DISC      = 200,                        -- creep disc radius for the pair clear-class (Farm.PairClearClass): clean if d/2+CREEP_DISC <= MARCH_LEN/2 (one March clears both), else clip. Feeds the lean-in clip budget + the calibration overlay; calibrate off the overlay.
    CLIP_EXTRA_MARCHES = 2,                       -- lean-in: a 'clip' pair (far camp's outer creeps spill outside one March) gets THIS many extra Marches at the midpoint to finish them as the aggro'd creeps chase inward. Calibrate in-client.
    CAMP_CACHE_S    = 60,                          -- F1: a fogged camp uses its last-seen real value for this long, then reverts to TIER_EST (we cannot know if an ally cleared it; bounded staleness, UCZone has the same blind spot).
    MARCH_PAIR_OFFSET = 0,                        -- nudge of the pair cast point along the A->B axis off the MIDPOINT (0 = midpoint; + = toward the far camp). Calibrate off the overlay.
    -- WHITELIST: specific camp pairs allowed to merge even though they exceed PAIR_RADIUS. Each entry is
    -- { {x1,y1}, {x2,y2} } (camp centres, matched by camp_key = 100-unit bucket). Use the "Mark pairable
    -- here" bind to find the two camps, then add the pair. NOT a global pair_max change - only these pairs.
    FORCE_PAIRS = {
        -- (empty) The -769,-7685 + -2480,-8400 d=1854 pair was removed: it DOES pair, but the midpoint stand
        -- path is blocked by woods -> move-stuck (3 in-client), doing more harm than good for ~one camp.
    },
    MOVE_TIMEOUT    = 25.0,                       -- abandon a stand we cannot reach in this many seconds
    WAVE_HOLD_EPS   = 150,                        -- v0.1.153: within this of the wave stand = ARRIVED; issue NO movement orders while holding (re-issuing move_to every tick made Tinker twitch in place)
    WAVE_HOLD_NEXT  = 12.0,                       -- v0.1.153: when the hold deadline expires with no wave, KEEP holding if the measured rhythm puts the next wave within this many seconds (a window this small is never worth a camp trip; ~MIN_CAMP_SLACK at zero travel)
    WAIT_PROTECT_AHEAD = 350,                     -- note 3: wait this far from the structure TOWARD the stand (inside its cover, facing the lane)
    WAIT_BACKOFF       = 600,                     -- note 3: no structure in scan range -> wait this far back from the stand toward our fountain
    WAIT_STEP_BACK     = 200,                     -- v0.1.343: the between-wave idle steps THIS far back from the cast stand toward our fountain (idle_wait_spot). LOAD-BEARING BOUND: must stay < W_PRE_STAND_R 600 so the hero at the wait spot is still inside the FOGGED lead pre-cast's radius of the stand (that gate still rules on W_PRE_STAND_R; v0.1.374 moved the LIVE W1 lead gate to W_PRE_LEAD_R 1100) = the pre-cast fires. NOT an engage-range bound (dref is measured live to the moving wave and closes as it marches in; the wait sits ~1010 > WAVE_ENGAGE_RANGE 950 and that is fine). g343 stalled idling ~1000 back = beyond W_PRE_STAND_R, which blocked the lead cast. Distinct from the stand (user doctrine: wait != cast). Tunable up to ~500 (smaller = tighter engage timing); calibrate from watched behavior.
    STEP_OUT_LEAD      = 1.5,                     -- task #12 (anchor tether): leave the tether this many s BEFORE eta_live - walk_time (turn + hold-eps + cast setup). LIVE branch only since v0.1.322 (the fogged step-out reserves the pre-cast window below). Calibrate off --cycle-report.
    STEP_OUT_PRECAST_S = 6.0,                     -- v0.1.322 (user doctrine: clear ASAP = be in the right place EARLY, pre-cast W1 so the wave walks into it, W2 in sequence): the FOGGED step-out arrives this many s before eta_live - the PRE-CAST window = W_LEAD_FOG_S 3.5 + cast setup ~1.5 + landing margin ~1.0. eta-1.5 (the old engage lead) sat INSIDE the W1 lead = in place too late to pre-cast. GPM-law "pre-position ~8s early" (step-out ~eta-10 with keen transit, land ~eta-6). Calibrate off the fog-timing sub-line (land ~eta-6) + shove_pre tarr~3.5.
    DEPTH_POINT_BUDGET = 600,                     -- Risk v2 axis 1 (task #11, user point system): a shove stand whose Farm.DepthPoints exceed this reads covers=false -> no_safe_stand -> jungle. DECIDE-only (never a movement veto). Run-13 anchors: dead-T1 meeting ~1100 past x1.5 side-T1s = 1650 (excluded at L1); with the keen shave 150 (allowed at L2). Calibrate off ft.dpts.
    DEPTH_KEEN_SHAVE   = 1500,                    -- axis 1: flat point shave when Keen L2 is READY (the escape capability; "having keen can shave off points"). Sized so typical post-T1 meetings (~1000-1400 past, 1.5x) pass at L2 while T2-deep territory (2500+ past) still busts even with keen.
    WAVE_CAMP_ALT_S    = 30,                      -- Risk v2 axis 2: a shove whose ROUND-TRIP travel exceeds this jungles instead (reason=far_wave) - the walk out-costs ~2 camp clears. The fed travel is raid-aware (L2 creep-keen collapses it), so deep waves re-qualify at Keen L2 automatically. Run-13: deep walks RT ~40 (skip at L1), river meetings RT ~25 (keep).
    SIDE_STAMP_MAX_S   = 60,                      -- PHASE 2 (TINKER_SIDE_ANTICIPATION_DESIGN.md): a side lane's cadence stamp is FRESH for this long (2 wave periods) - fresh = fogged side anticipation dispatches like mid (asrc=stamp); staler = verdict stale, not a candidate. Calibrate off ssrc=stamp arrival eta_err.
    GONE_BAL_MIN       = 2,                       -- gone-by-arrival (run-21): our wave wins by >= this (push-sim bal) AND the fight ends before we can arrive -> nothing to farm, jungle. bal=1 marginal keeps the shove. Calibrate off reason=gone_by_arrival vs arrivals that DID have creeps.
    WALK_DEPTH_MAX     = 1100,                    -- v0.1.327 RE-ZEROED with the S2 per-lane depth (was 550 in the fountain-mid frame): depth 0 is now the LANE's T1 midpoint (the meet ground), and 1100 preserves the .324 RADIANT REFERENCE behavior exactly - the old Radiant frame effectively allowed centre+1133 (550 + the 583 zero offset), and that is the posture the user validated; Dire now gets the SAME band for the first time (its old effective edge was centre-33 = could not reach its own meet). Semantics unchanged otherwise (v0.1.193 EXCLUSION not clamp: deeper natural stand -> covers=false -> Plan jungles it; never clamps movement). KEEN-TO-CREEP (raid/deep_ok) EXEMPT pre-T1-drop; T1DOWN_LEASH binds after (v0.1.201). The depth-audit uses the SAME lib ruler + this value.
    T1DOWN_LEASH       = 3000,                    -- v0.1.201 (user, run-29): after the enemy mid T1 DROPS, max lane-position distance from our foremost alive mid tower. Exclusion (covers -> jungle), never a movement clamp; forward-only (positions behind the tower never bind). UNGANKABLE creep-keen raids exempt (v0.1.202). v0.1.204 (user MAP-MEASURED): our T1 -> river center ~2000-2200; the expected post-T1 equilibrium ~3000 = the END OF THE STEPS (matches code geometry: T1 depth -2041 + 3000 reaches ~depth +950; the stairs line 550 still governs walking stands, so the leash trims off-axis/deep cases). Calibrate per the leash standing rule (careful analysis first).
    ENGAGE_EMPTY_GRACE = 1.2,                      -- tolerate this many seconds of occupancy=false at the camp (creeps chasing out of the box) before bailing
    MIN_CASTS_BEFORE_EMPTY = 2,                     -- A: require at least this many fired Marches before honouring an "empty" read (a 1-cast occupancy flicker as creeps aggro out was bailing with got=6)
    KEEN_TRAVEL_MIN = 1600,                       -- only Keen out if the stand is at least this far
    KEEN_GAIN_MIN   = 800,                        -- the anchor must be >= this much closer to the stand than we are
    RAID_RESID_MAX  = 1200,                       -- v0.1.252: a RAID keen to a NON-creep anchor beyond this residual is not a raid transport (run-67 t=922: bldg residual 3016 -> 13s ghost walk into a resolved wave); creep anchors exempt (riding the incoming wave is the design, residuals 1000-2500 legit)
    RAID_HOP_CREEP_MAX = 3000,                    -- v0.1.253 (decide-time raid_hop_ok): a creep anchor counts as a usable hop within this of the crash point (v0.1.175 ride-the-wave residuals 1000-2500 + margin); farther = the ride itself is the walk being avoided
    DECIDE_GAP      = 0.4, ORDER_GAP = 0.05,
    MOVE_DEDUP_DIST = 75,                         -- v0.1.161 (flicker): a MOVE to within this of the last issued move target is a re-issue, not a new destination - skip it (bigger than the per-tick live-stand drift ~10-20u, smaller than a meaningful target change)
    MOVE_DEDUP_S    = 0.5,                        -- v0.1.161: re-assert an unchanged MOVE this often anyway (a swallowed order self-heals; twitch needs ~20/s, 2/s is invisible)
    TEST_OVERLAY_SEC = 120,                       -- how long the "Test all pairs" overlay stays up (seconds)
    AUTO_WAVESCAN_S = 2.0,                         -- v0.1.92: automatic all-lanes wavescan LOG cadence (the bind still arms the visual overlay)
    ROUTE_HORIZON_S = 30,                          -- planner time budget (the dead-time window)
    MAX_CAMP_TRAVEL_S = 20,                         -- reachability: don't pick a camp whose reach ETA (walk / ready keen) exceeds this - Tinker would time out en route (the move stuck d=9338 far-camp). Under MOVE_TIMEOUT (25) with margin. Keen-L2 creep-reach will relax this later. Calibrate.
    ROUTE_MAX_STEPS = 4,                           -- max planned sequence length
    ROUTE_STEP_DECAY = 0.6,                        -- v0.1.212 (run-35 census: plans promised [single, PAIR] but the pair step NEVER executed - real clear cost ~2x the planned mana_cost broke every tail at the replan): later plan steps execute with p<1, so their value is discounted in the SCORE (0.6^i). Makes [pair NOW] beat [single now, pair promised]. 1 = off. Calibrate off the plan= vs real= census line.
    ROUTE_POOL_CAP = 16,                            -- #3: DFS candidate cap (was the lib default 10). Raised so a far high-value camp is not trimmed by the one-step rate before the planner weighs it. Own-side reachable jungle is ~13 camps; the DFS is cheap at this n (the 30s horizon caps collectable depth to ~2-3, so the effective branching is small).
    ROUTE_RISK_WEIGHT = 70,                        -- gold penalty per unit risk in the planner score. Raised 40->70 so low-value ENEMY-side camps lose to safe own-jungle/lane (Note 2: Tinker was dipping into enemy jungle for a value-101 camp).
    HOME_LANE       = "mid",                        -- Tinker's lane: never yielded to allies (Note 3), so he returns to farm his own waves.
    WAVE_STANDBACK  = 900,                          -- Tinker Marches a wave from RANGE: the wave STAND (+ its risk) sits THIS far back toward our fountain from the creep cluster (Note 2: ~900u from the wave so it stays safe + March's forward sweep still covers it). Calibrate.
    ANTICIP_RANGED_REACH = 810,                     -- W-GEOM-1 THE STANDARD CAST POSITION (user design, TINKER_W_GEOMETRY_STUDY.md sec 3): 900 box-half x 0.9 = the max distance the robots CERTAINLY hit the trailing ranged (-10% safety). Both the anticipation AND the live contested stand anchor the RANGED at this (the old contested fallback stood 900 from the ranged = the 100% coverage edge = the missed-by-a-little class). A disabler behind their wave must now walk the robot corridor to reach a channel. v0.1.371: THIS IS NOW THE LEAD RULER ZERO TOO, not only a stand distance. TWO consumers now read it as the point the W1 lead is measured TO (the shove_pre fire gate's tarr and the w_lead_reject diagnostic's tarr_d; v0.1.400 collapsed that diagnostic's three inline copies, the lead_bar guard plus the tarr= and eff= log fields, into the one local), matching tools/w_timing_sweep.lua:14 STAND=810. So recalibrating it moves the W1 LEAD as well as the stand - the two are deliberately one number.
    STAND_KITE_EPS       = 100,                     -- W-GEOM-1: the ENGAGE maintains the standard position - when the advancing wave closes the gap below ANTICIP_RANGED_REACH - this, step back to the (receding) live stand between casts. The position SHIFTS with the wave (user: "this position should shift").
    WAVE_LEAD       = 150,                           -- Note 5: lead the WAVE aim this far toward the TRAILING ranged creep (the side away from our fountain) so the March footprint spans it. Waves only (camps unaffected). Calibrate in-client.
    W_LEAD_S        = 4.75,                         -- v0.1.277 W-GEOM-3 (lib/march_sim lead sweep, study sec 9): fire the FIRST W when the closing wave is this many seconds from the stand - the robot stream and the wave meet AT the stand. Sweep: each lead second saves ~1s of engage below 4s, saturates 4.5-5.5, reverses past ~6. Replaces the v0.1.221 W_FRONT_MAX edge hold (the instant-AOE compensation). Calibrate DOWN first if casts whiff. v0.1.371: this is a lead to the STAND, not to the hero, and the 4.5-5.5 band it cites came from tools/w_timing_sweep.lua measured to a stand 810 out. After the ruler fix it binds only when close < (dref-810)/4.75, about 227 u/s at the observed fire distance, so it is now a SLOW-WAVE VALVE rather than the primary trigger; W_LEAD_CAP 1900 is the effective flat trigger. Geometric ideal lead to the stand is 3.70s (lib/march_sim stream front: 300u at 2.93s, 1200u at 4.00s, cliff 1273).
    W_LEAD_CAP      = 1900,                         -- v0.1.277: never lead-cast a wave farther than this (325 speed x ~5.5s + margin; a faster-closing wave is capped by geometry, not time). v0.1.371: the old "325 speed x ~5.5s + margin" derivation is DELETED - it dropped the same 810 the lead ruler did. The measured fact instead: 1900 coincides within about 7u with the hero own settle-and-warm point (the closing EMA resets on self-motion >30u; reset measured at dref ~1928, wgN>=2 arms ~2 ticks later at ~1907), so post-fix this is the effective flat trigger and it delivers 3.38s against the 3.70s ideal. RAISING IT IS REFUTED (TINKER_W_TIMING_DESIGN.md 9.4): 2330 would deliver 4.75s, 1.05s PAST the ideal, burning the stream front on empty ground, and it is a no-op anyway (0 of 21 reject rows in (1900,2400] are armed).
    W_CLOSING_MIN   = 80,                           -- v0.1.277: the commit-local closing EMA must read at least this (u/s) for the lead cast - held/receding waves never preempt (they get the normal arrival cast). Mirrors arc-B HELD_CLOSING_MIN.
    W_LEAD_FOG_S    = 3.5,                          -- v0.1.279 (run-87 "too early"): the FOG preempt's own lead - cadence-stamp arrivals read +1..+5s LATE vs eta, so the fog cast's effective lead = this + the drift, landing in the sweep's 4.5-5.5 saturation band. Calibrate against fog=y -> eta_err.
    MISS_FREE       = 1,                            -- E3a (v0.1.313) threshold for hiding enemies (Escape.MissingCount, visible==false). v0.1.316: the raidcap veto using this was REMOVED (confirmation run - the global veto killed deep/near-tower keen-raids whenever 2+ enemies were merely off-screen); RETAINED for the proximity-aware refit that will re-gate only when a hiding enemy can reach the landing. Currently unused by raidcap.
    FOG_FRESH_S     = 1.5,                          -- v0.1.317 fog-threat: a fogged enemy older than this is too stale to count as a specific gank (reachable_fog freshness gate). Calibrate.
    FOG_REACH_CAP   = 450,                          -- v0.1.317: cap the fog probable-disc reach for the gank count (was the untouched GANK_FOG_REACH 600). Tighter = fewer phantom-gank aborts. Calibrate DOWN if the jungle-drift persists, UP if deaths appear.
    W_PRE_MIN_N     = 3,                            -- v0.1.280 (run-88: a W preempted onto a creeps=1 straggler): minimum LIVE creeps for a lead cast; thinner remnants take the normal arrival flow (its budget prices them honestly).
    W_CAST_REACH    = 700,                          -- v0.1.305 re-applied .291 (run-99 user: casts vs a FIGHTING wave still missed the ranged, "give it more room, about 10 to 15%"): 800 -> 700. The .286-era 800 also sat INSIDE the 810 stand = a held-wave dead band; the step-in closes the gap. FIRST cast only (W2+ ungated, the consecutive principle).
    W_WAIT_RELEASE_S = 4.0,                         -- v0.1.305 re-applied .288: max casts=0 in-engage wait for the wave to close into cast reach; longer = held/receding -> release to the jungle window (suppress SHOVE_STUCK_S, re-competes next decide).
    W_PRE_STAND_R   = 600,                          -- v0.1.282 (run-90 user: "moving forward to meet the wave... makes zero sense for a 900-coverage skill - just time it and cast"): the wave approach STOPS this far from the computed stand and the preempt/prearm/timed gates accept it - the box half (900) covers the gap and the wave walks in; standing short = farther from the meet = safer. The exact stand was positioning theater for a 1800 box. v0.1.374: this now owns the APPROACH-STOP (the stand-hold truncation and the live-wave approach walk-stop, both in fsm_move_wave), the FOG pre-cast (march_aim fog=y) and the TIMED arrival trigger (wave_engage_arrived trig=time, target lead ZERO by design). The W1 lead pair (fire gate + prearm) moved to W_PRE_LEAD_R. Raising THIS is refuted: the live-wave approach is the walk-stop, so raising it parks the hero 1100 short of the stand, 1910 from the ranged creep, outside MARCH_REACH 1150.
    FIGHT_CONTACT_R     = 300,                       -- v0.1.393: creep fronts within this of each other = the wave is IN A FIGHT and its arrival is unknowable; the W1 lead defers. Corpus predicate: recall 19-23 of 28-32 bad leads, FP 6-10 of 105-112 landed (two independent joins), every FP converting to an at-arrival cast, never a lost wave.
    FIGHT_HOLD_S        = 3.0,                       -- v0.1.393: freshness TTL on the fight stamp (1.5x AUTO_WAVESCAN_S 2.0, guards a stalled scan). Expired stamp = no defer, fail-open.
    PREARM_CD_FLOOR     = 4.0,                       -- v0.1.392: minimum March cd_remaining for the marchCasts==0 prearm path. Below it the CD expires before the lead window anyway and a Rearm (~225 mana + a ~2s channel) would be wasted. Precheck over g377-g386: at 4.0 the addressable class is 4 episodes (gaps 6/6/12/26s, one wave fully castless) and the waste class is ZERO.
    W_PRE_LEAD_R    = 1100,                         -- v0.1.374: the W1 LEAD pair's own hero-to-stand bound, decoupled from W_PRE_STAND_R. Read at EXACTLY THREE sites and they must move together: the fire gate (march_aim src=shove_pre), its diagnostic mirror (w_lead_reject why=stand_far), and prearm_w2. WHY THE PREARM IS IN THE PAIR: the v0.1.307 REARM DANCE block returns BEFORE the live-wave approach walk, and the only movers inside it are a threat-gated step-back and a delivery walk behind ready(State.march), so leaving prearm at 600 would fire W1 at dstand ~1090 with NOTHING walking the hero the remaining 490u. Three independent measurements of that frozen closure disagreed (287-455 u/s, 304-313 u/s, and ~0), i.e. the W2 delay would be somewhere between zero and unbounded; moving all three preserves today's invariant (prearm true the instant W1 fires) and is the SMALLER behavioural delta. WHY 600 WAS WRONG: it capped the effective lead at 600/close = 1.85s at creep speed 325, which made the v0.1.371 ruler fix inert on ordinary waves (g374 EFFLEAD median 1.90 at close>=280 vs a 2.02 pre-fix baseline) while it genuinely bought the slow-wave band. WHY 1100 AND NOT A TUNED NUMBER: 1090 = W_LEAD_CAP 1900 - ANTICIP_RANGED_REACH 810 is the exact saturation on a COLLINEAR UNCLAMPED stand; 1100, 1200 and 1500 are behaviourally identical across the whole corpus, so this is the tightest bound at saturation, retained as an off-axis tail guard because W_PRE_LEAD_R is the only hero-to-stand bound in the fire gate (four cap-legal corpus rows sit at dstand 1227-1538). The operative bound is really min(W_PRE_LEAD_R, W_LEAD_CAP - gap, 810 + W_LEAD_S*close) and 1100 is rarely the binding term: that is the design, not a defect. COVERAGE IS NOT AT RISK: the meet is timed 810 forward of the CAST POINT (the dref - ANTICIP_RANGED_REACH numerator of tarr) and the cast clamps to 280 from the hero (march_cross_target maxr), and 810 < MARCH_HALFWIDTH 900, so meet coverage does not depend on hero-to-stand distance. CALIBRATE DOWN if casts whiff.
    WAVE_MAX_W      = 2,                            -- DEFAULT for the "Marches: lane wave (max W)" menu slider: HARD CAP on W (March) casts per LANE-wave clear (the engage budget). shoveCasts from ClearTime(eff_hp) is capped to it so a big/over-estimated wave can't burn endless W under the tower. Applies to the wave being ENGAGED (visible or an arrived incoming one); waiting casts nothing. Camps have their own budget. Live-tunable on the HUD.
    LANE_MEET_TTL      = 90,                      -- v0.1.303 LANE-CLOCK: an observed arrival ground (State.laneMeet) anchors fogged dispatches for this long (3 wave periods); older -> the lane midpoint fallback (s.meeting).
    LANE_ANCHOR_BACK   = 600,                     -- v0.1.307 THE ANCHOR FLOOR (run-112 vs Lina): the fogged dispatch ground never sits deeper OUR-side than this past the river - pushed waves arrive at our tower and would teach the clock to wait there ("the end of the tower as the cast anchor"). Meet waves FORWARD; the pre-casts clear them before the tower; the live ranged owns precision once visible.
    INTERCEPT_FWD_R    = 600,                     -- v0.1.323 BEST-POSITION CASTING (user doctrine 2026-07-20): advance the committed MID meeting this far UP-LANE before the band clamp, so the wave is met - and W1 lands - as far forward as the walk law allows instead of at the tower-band crash. clamp_intercept caps the ratchet (WALK_DEPTH_MAX / LANE_ANCHOR_BACK); safe_stand_for + tower_safe + risk gates own per-stand legality; the Lane-Clock re-anchors on the observed forward ground within ~1-2 waves. Calibrate: tighten FIRST if a death traces to forward exposure.
    WAVE_TRACK_RADIUS  = 1600,                      -- read enemy lane creeps within this of the wave's last-known point to TRACK the moving wave (recompute the live centroid each tick); generous so a pushing wave is not lost.
    WAVE_ENGAGE_RANGE  = 950,                       -- ENGAGE while within this of the AIM (T0 collapsed the centroid trig: the trigger is dref = hero-to-standSpot.aim in fsm_move_wave), keep Marching while within this + 250 of the LIVE centroid (fsm_engage_wave's reposition bound) (~= WAVE_STANDBACK; March's ~300 cast + ~900 forward sweep still covers it). Calibrate (Note 2: stand ~900u from the wave).
    DEEP_THIN_EFFHP    = 1150,                       -- v0.1.195/196 (user, deep era = lane-phase timing): in the T1-DEAD era ONLY (the lane phase is perfect, untouched), a VISIBLE wave past the stairs line must be ~3+ creeps (full wave 1950, 2-creep remnant ~1100) to justify the raid trip; thinner -> jungle, the next FULL predicted wave gets the timed raid. Fogged ExpectedWave estimates are full waves and pass untouched.
    NC_GRACE_S         = 3.0,                        -- v0.1.195 (run-25): a live nocover wave gets this long to prove it is CLOSING before the commit bails - nocover fired on an INBOUND wave (their push crashing our tower) whose current position read deep, and the abort+suppress walked him to our T1 as the full wave arrived.
    NC_CLOSE_EPS       = 100,                        -- v0.1.195: dWave must drop this much to re-arm the nocover grace (a closing wave covers it in ~0.3s at 325; a held fight wobbles less).
    NC_HOLD_NEAR       = 1600,                       -- v0.1.274 (CASE-FILE 3, run-83): a HELD nocover wave within this keeps the frozen stand (a near locked fight resolves fast and the 950 engage trigger sits just under it); farther bails to the jungle window as before. Calibrate.
    WAVE_VIS_DEBOUNCE_S = 0.7,                       -- v0.1.275 (run-84 "frenetic back and forward"): the live/fogged wave-branch switch needs the contrary visibility to persist this long - a vision-edge flicker alternated the protected hold and the stand re-approach every tick. Costs at most this much engage delay on a real arrival mid-fog.
    PROT_CLEAR_S        = 2.0,                       -- v0.1.276 (run-85: the flap survived .275 - the REAL flicker was the fogged wait's enemy-near predicate, the enemy disc aging in/out at the vision edge): the protected-hold latch releases only after the hold reads enemy-clear this long straight. ON is instant (safety).
    W_X_ARM_A          = 45,                         -- v0.1.270-271 W-GEOM-2 (user design): THE CROSS - two cast lines 90 deg apart, the pair rotated 45 off the hero->aim axis. Arm A rotation (deg). v0.1.271 fixed the misread arm B: the user's "then turn 90 the other way" is RELATIVE to arm A (+45 - 90 = -45), not -90 absolute (run-82 showed the -90 arm casting perpendicular across the lane). Calibrate by pat= census if kills read off.
    W_X_ARM_B          = -45,                        -- v0.1.271: arm B = the cross's other line. Sim note (study sec 8): the mutual-90 cross partially decorrelates the melee shadows - marginal on the static early wave at W lvl2 (ranged ~80 hp short in the model), clean at lvl 4; watch early-lane clears.
    TETHER_MAX_HOLD_S  = 10.0,                       -- v0.1.208 (run-33 "eternal waiting"): a tether whose step-out is farther out than this releases to the planner (shove suppressed for the wait) - a raid's keen transit (~4s) makes long closes pure idle at the hold spot; the window fits a camp. Calibrate.
    LIVE_STALL_S       = 15.0,                       -- v0.1.330 THE STALLED-LIVE RELEASE (g328: 124+51+47s statues): a committed wave that is LIVE but beyond engage range and NOT closing (wgClose < W_CLOSING_MIN or unwarmed) for this many seconds straight releases the window (suppress this long, redecide) - the state [spent-or-waiting commit + far-stalled wave] had NO exit (arrival needs dref<=950; phantom-bail needs invisible; tether release is pre-step-out; MOVE_TIMEOUT is refreshed by the ENGAGE->MOVE reposition ping-pong). moveSince-INDEPENDENT by design. Calibrate off stall_release lines vs genuine slow closes.
    TETHER_WALK_MAX_S  = 6.0,                        -- v0.1.194 F2 (run-24): a raid-capable tether leg WALKS only when the hold is this close (v0.1.188's keen-preservation case); farther rides the keen ladder - the step-out re-arms (rearm-reset -> keen) for the raid hop anyway (v0.1.175), while the walk-always rule marched him 8-10k from the fountain.
    STUCK_TELEPORT_S   = 4.0,                        -- v0.1.121 (note 3, user): GLOBAL stuck-breaker - if the hero is moving toward a target (MOVE/RETURN), is FAR from it, and his position has not changed for this long, he is physically blocked -> TELEPORT (keen home) to unstick. Last-resort backstop over the per-state watchdogs.
    STUCK_FROZEN_DIST  = 60,                         -- v0.1.121: position moved LESS than this over the window = "not moving" (frozen).
    STUCK_FAR_DIST     = 400,                        -- v0.1.121: only count as stuck if this far from the move target (else he is legitimately standing AT the stand/target waiting - do not teleport).
    BLINK_RANGE        = 1200,                      -- item_blink cast range (regular dagger; arcane=1400). ponytail: const, not lib/item_data (no extra deploy) since Tinker buys regular blink. Read item_data if he ever buys arcane/overwhelming.
    BLINK_CLAMP        = 960,                       -- max landing distance (blink_range_clamp); overshoot beyond this lands at the clamp
    BLINK_TRAVEL_MIN   = 400,                       -- v0.1.209 (user FINAL blink doctrine: "use blink whenever it is safe... no chances of getting jumped"): the dagger is NOT rationed by distance anymore - the fog-aware risk gates own the only veto (jump risk), Eureka refunds the cd. This floor is order-sanity only (a <400u blink is a twitch, not travel). Was 800 ("protect the escape") - that protection is the risk gate's job now.
    BLINK_DEBOUNCE     = 0.5,                       -- min seconds between blinks (downloaded-script idiom)
    -- Note 4 (mana/HP-aware routing): per-hop cost gating + refill-as-node. Costs are read LIVE via
    -- Ability.GetManaCost (level-scaled); these _FB are the Liquipedia fallbacks if the read fails.
    HP_FLOOR_FRAC       = 0.35,                     -- next-hop HP gate: keep projected HP above this fraction of max HP
    HP_RISK_DMG         = 600,                      -- expected HP lost on a hop = enemy_risk * this (jungle risk ~0 -> ~0 cost). Calibrate.
    KEEN_MANA_FB        = 75,                        -- Keen Conveyance mana (Liquipedia, flat)
    MARCH_MANA_FB       = 120,                       -- March of the Machines mana per cast (Liquipedia 100/120/140/160)
    REARM_MANA_FB       = 225,                       -- Rearm mana (Liquipedia 150/225/300)
    REARM_CANCEL_BACKOFF_S = 6,                      -- v0.1.254 (Defense case-file #1): after an OBSERVED rearm cancel (stun/hex broke the channel, mana spent), hold further rearms this long (fountain exempt) - stops the consecutive-rearm mana drain vs hard-disable laners; inert with no enemies (cancels cannot happen)
    CAMP_UNSAFE_SUPPRESS_S = 20,                     -- E0 (B8): an unsafe-aborted camp is suppressed this long (was: marked CLEARED until respawn - one roamer deleted the jungle pool without fighting)
    CHANNEL_GATE_MARGIN = 500,                       -- ARC E1: a channel start is deferred when a disabler-kit enemy is within its max disable cast range + this (they close ground during the 1.2-2.93s channel; calibrate off channel_defer vs missed-rearm idle)
    CHANNEL_GATE_HORIZON = 3.0,                      -- E2 final review: readiness is judged at now()+this (covers the 2.93s Keen channel) - a breaker coming off cd DURING our channel still breaks it
    CHANNEL_DEFER_BAIL_S = 4.0,                      -- run-75: a wave engage whose Rearm the gate has deferred this long (parked disabler) bails + suppresses instead of standing (the .239 never-hold law)
    TOWER_THREAT_R       = 1100,                     -- v0.1.385: an enemy wave front within this of one of OUR live HOME-lane towers, with no ally hero in the lane, counts as a crash the clash model cannot see. 0 disables the whole rule with no code edit. CALIBRATION RECORD CORRECTED at v0.1.387 after adversarial review: the v0.1.385 claim that 1100 reproduces all THREE watched g382 episodes was FALSE. It reproduces TWO. The third (t=554-566) reads alH=1 on every row and so is excluded by the rule's own no-ally-hero term at ANY radius. R of 1000, 1100 and 1300 give BIT-IDENTICAL firing sets on the corpus, so 1100 is not uniquely determined; 700 catches only a single scan fragment inside episode 1 and neither tabulated episode (833u and 944u are both outside it).
    TOWER_THREAT_MINC    = 3,                        -- v0.1.385: minimum enemy creep count for the tower-threat stamp. CORRECTED at v0.1.387: the claim that 4 misses an episode was FALSE. At MINC 4 BOTH catchable g382 episodes still fire; all 4 drops is one scan fragment INSIDE episode 1. So 3 is not a calibrated floor, it is simply the looser of two settings that behave the same on the corpus. The real over-fire control is the v0.1.387 strength guard below, not this count.
    CRASH_STICKY_S       = 10.0,                  -- run-76: a crash-our-tower flag seen by the 2s scan counts as crashing for this long (the instantaneous flag flickers mid-fight; decides sampled false instants and the 415g bot T2 wave went undefended)
    REARM_STEPBACK_S     = 4.0,                      -- run-78: a wave engage whose Rearm the gate blocks walks OUT of the gating enemy's reach for up to this long to rearm there (keeps the wave); expiry falls through to the .262 bail
    DISPATCH_HP_MIN     = 0.50,                      -- case-file #2 (run-72 t=445): a due shove below this HP fraction recovers first - PANIC_HP 0.40 fires on arrival otherwise (keen + ~50s donated); fed to Lane.Schedule.Plan as ctx.min_hp_frac
    LASER_MANA_FB       = 95,                         -- Laser mana fallback (Liquipedia ~95-120); abil_mana reads the real cost, this is only used if that read fails
    LASER_DMG           = { 75, 150, 225, 300 },      -- pure damage per Laser level (lib/ability_data, KV/Liquipedia-verified). PURE = ignores armor + magic resist, so a neutral is last-hittable iff its CURRENT hp <= this.
    MANA_REGEN_FALLBACK = 4.0,                       -- if NPC.GetManaRegen read fails
    HP_REGEN_FALLBACK   = 6.0,                       -- if NPC.GetHealthRegen read fails
    FOUNTAIN_MANA_PCT_S = 0.06, FOUNTAIN_HP_PCT_S = 0.05,   -- fountain regen rates (fraction of max per second; IN-CLIENT v0.1.130 capture) - drives the deficit-based refill duration (v0.1.162; replaced the flat REFILL_WAIT 4.0, which under/over-priced the trip and skewed camp-vs-refill choices)
    -- Note 3 (structural risk): position-based risk added to the live enemy-proximity risk so an own-side
    -- safelane camp ranks safer than a contested mid camp even with no enemy on the minimap.
    RISK_HALF_WEIGHT    = 0.75,                         -- gradient weight: risk rises 0 (our fountain) -> half_weight (enemy fountain). 0.75 so deep-enemy camps cross RISK_HARD and are VETOED (N3: stop farming the enemy-outpost ancients = deaths). The t>~0.6 and the 0.375-is-farmable arithmetic here were written against the PRE-v0.1.90 RISK_HARD 0.45: at the shipped 0.34 the gradient alone crosses at t~0.45, so a t=0.5 mid camp (0.375) is now vetoed on structure alone, and it is the own-jungle camps (own pair gradient ~0.27, see RISK_CONTESTED_BUMP) that stay farmable.
    RISK_CONTESTED_BUMP = 0.05,                          -- + this for a camp in a tagged contested zone. SMALL nudge only: at 0.18 it inverted the order (tagged radiant ancient out-risked a deeper untagged dire camp); at 0.08 the own-ancient PAIR midpoint (gradient ~0.27) hit 0.35 > RISK_HARD 0.34 = a hard VETO, so the close own ancient was never farmed even at max March. 0.05 keeps the deprioritizing nudge (own pair -> 0.32, farmable when safe; a live enemy near it still tips >0.34) while the ENEMY ancient stays vetoed by its gradient (~0.49) + reach anyway. Only affects the 2 tagged ancients.
    RISK_CONTESTED_RADIUS = 700,                         -- contested-zone radius around a tagged camp centre
    RISK_CONTESTED_CAMPS = { { -4797, -104 }, { 4099, 63 } },   -- the mid-river ancients, contested by both teams (calibrate from the overlay)
    -- Note 1 (lane-wave timing + crash/push):
    WAVE_PERIOD         = 30,                            -- creep waves spawn every 30s (Liquipedia)
    WAVE_PHASE          = 21,                             -- v0.1.366 RECALIBRATED 14 -> 21 (TINKER_LANE_CLOCK_V3_PLAN.md task 4, redirected). The old 14 came from n=8 arrivals in one game; `--lane-report` has printed "observed spawn-grid phase: median 18.4-19.6 (K.WAVE_PHASE calibration; current 14)" on EVERY log since, and nobody moved the constant. Re-measured over 527 mid arrivals in 30 logs: median 18.6, and top/bot agree (19.3/18.3), so ONE constant is right for all three lanes. WHY 21 AND NOT 18.9: Lane.Schedule.NextOnGrid returns strictly > now, so a phase set EARLY of the true arrival rolls a WHOLE 30s period (catastrophic) while one set LATE is wrong only by the offset (cheap) - the cost is asymmetric, so the constant sits ~2s late of the median. Leave-one-out over 495 arrivals (each game scored with the OTHER games' median, never its own): phase 14 -> 79% of predictions >10s wrong, median |err| 23.2s; phase ~21 -> 17%, median |err| 2.1s. ponytail: a fixed constant beats a per-lane EMA here because arrival jitter (p10-p90 spread 8.9s on mid, far worse on the sides) is larger than the drift it would track - a single observation is a noisy sample of a metronome. Upgrade path if the sides ever need their own: per-lane phases, measured the same way.
    WAVE_WAIT_GRACE     = 8,
    WAVE_WAIT_GRACE_VIS = 4,                               -- v0.1.222: AT the stand (vision up-lane) an arriving wave shows ~4s before eta - an invisible one past eta+this is a phantom; bail early. Calibrate vs the prediction-late median (~3-7s).                               -- at the wave stand, wait until waveEta + this for the creeps to arrive before re-asking the schedule. Calibrate.
    -- P0 move watchdog: bail a stand we are not closing toward (bad keen landing / unwalkable), so a far
    -- keen anchor (d2stand large) cannot lock Tinker walking-in-place at a camp he can never reach.
    NO_PROGRESS_S       = 3.0,                               -- backstop only now: with area-engage the hero engages from the coverage band, so this rarely fires (true can't-get-within-range)
    PROGRESS_EPS        = 60,                                -- "improved" = closed at least this many units
    SHOVE_STUCK_S       = 6,                                 -- Note 1: after a shove crash stand proved unreachable (keen landed on tower high ground), suppress re-picking the shove for this long (recover instead) so Tinker does not loop re-keening the same unwalkable spot
    ENGAGE_COVER_DIST   = 450,                               -- AREA engage: within THIS of the cast aim, March's square already covers the camp -> engage (no exact-point requirement). MARCH_CAST_RANGE 300 + ~150 slack; cast clamps 280 ahead, the square reaches well past. Calibrate vs clear quality.
    MULTI_W_OFFSET      = 50,                                 -- W cast offset FROM TINKER in the (90-deg-rotated) target direction. Small: the ~1800 box covers the cluster from right next to Tinker, so casting close (in-range, robots sweep THROUGH the creeps) beats pushing the box 300 off-centre. Calibrate.
    MARCH_REACH         = 1150,                               -- a camp is March-coverable from here if within this (cast clamps 280 ahead + the square reaches ~900 more). Used by the river-fallback pair engage + the watchdog.
    -- THE BOX = a THIN RECTANGLE aligned to the camp-connecting (A->B) axis, centred on the midpoint.
    -- ALONG the axis is the CRITICAL direction (moving unbalances the two camp distances) so it is tight;
    -- PERPENDICULAR keeps both camps ~symmetric so the hero may shift more there. More precise than a disc.
    BOX_ALONG           = 50,                                 -- half-extent ALONG the camp axis (the WIDTH, the critical direction - moving along unbalances the two camp distances). v0.1.107 (user note 1): halved 100->50 (the "cut the width in half" that was asked; v0.1.101 wrongly cut the perpendicular/length instead).
    BOX_PERP            = 300,                                -- half-extent PERPENDICULAR to the camp axis (the LENGTH, roomy - both camps stay ~symmetric when shifting here). v0.1.107 (user note 1): restored 150->300 (v0.1.101 had halved this by mistake).
    -- Shove gates (TINKER_SCHEDULE_DESIGN.md):
    SHOVE_SAFE_RISK     = 0.35,                               -- skip a shove when the 900u-stand risk is >= this. Calibrate.
    -- (the depth-veto patch family - DEPTH_AT_LINE/DEPTH_PAST_LINE/DEPTH_DIVE_MARGIN/SHOVE_MAX_DEPTH/
    -- SAFE_DEPTH_MARGIN/ENEMY_MS/DIVE_ESCAPE_S + depth_line_risk/enemy_eta_to + the too_deep/deep-cap
    -- gates - was REMOVED 2026-07-01: layered under-tower patches, wrong direction. Tower safety will
    -- live ONCE in the unified order/movement layer for the lane foundation rebuild.)
    SHOVE_MANA_RESERVE  = 0,                                  -- extra mana floor beyond the per-hop cost for shove + escape (0 = just the hop). Calibrate.
    SHOVE_FAR_TRAVEL    = 12.0,                               -- v0.1.93 deep-shove guard: a shove whose crash point is THIS far (s, travel_to_mid) AND...
    SHOVE_MIN_EFFHP     = 400,                               -- ...whose wave eff_hp is below this (a near-dead, already-pushed wave) is NOT worth the long keen -> hold near mid + let allies/tower finish it. ponytail ceiling: tune both off clean data (caught the v0.1.92 log's 21.8s keen for 300hp).
    LANE_TRADE_HP       = 0.40,                              -- v0.1.94 lane risk: a 1v1 is a TRADE, not a death - DON'T flee a single visible enemy unless HP fraction is below this (then a burst could kill). 2+ visible = a gank = flee regardless. ponytail ceiling.
    SHOVE_THIN_EFFHP    = 400,                               -- v0.1.102 (note 1): skip a shove when the VISIBLE mid enemy wave is below this eff_hp (a lone creep, ~1 ranged 300) - not worth a keen-to-mid, our creeps + tower handle it. Fogged uses the full ExpectedWave estimate so anticipation is unaffected. ponytail ceiling.
    SHOVE_THIN_CREEPS   = 1,                                 -- v0.1.345 FIX B: a VISIBLE enemy wave of at most this many creeps is thin WHATEVER its eff_hp - do not keen for one creep, stated as a COUNT because HP cannot express it. CREEP_STATS (lib/lane.lua, Liquipedia-validated): melee hp 550 gold 39, ranged hp 300 gold 52, siege hp 935 gold 72 (siege never upgrades); melee+ranged gain only +12 HP per 450s from 7:30. So the 400 bar above, calibrated on the RANGED creep, has NEVER covered a lone melee or siege in any patch since v0.1.102 - it did not go stale. g346 t=339.3 keened 8621u for ONE siege remnant (gold=72 throughout, eff_hp 533 = 57 pct of 935, at game clock 5:39 = upgrade cycle 0). Raising the HP bar cannot fix it: any bar above a lone siege (935) also vetoes a healthy melee+ranged pair (850). MUST be paired with THIN_CREEPS_HOLD_S below - the raw count is the NON-DORMANT slice and lies at the vision edge. ponytail ceiling: still DISTANCE-BLIND - a lone creep is refused at travel=1.7 exactly as at travel=10.6; a travel-relative bar is the real ceiling. CALIBRATION KNOB: 0 disables FIX B with no code edit (a visible wave always has count >= 1); raise to 2 only if 2-creep keens persist.
    WALK_LEG_MIN        = 800,                               -- v0.1.347: a walk leg at least this long gets NAMED in the log (walk_leg d= why=). Was a hardcoded 2000, which logged only 4 legs in g348 while walking was 29.4% of the run - the user's watched "useless walks / unneeded long walks to keen" could not be measured at all. 800 = roughly 2.5s at base 325 MS, i.e. the shortest leg worth a cause. The 2s debounce in log_walk_leg still bounds volume. Raise if the log gets noisy; this is DIAGNOSTIC ONLY, no behaviour reads it.
    THIN_CREEPS_HOLD_S  = 2.0,                               -- v0.1.345 FIX B PERSISTENCE (adversarial-review find, CONFIRMED): ew.count counts only NON-DORMANT creeps (lib/lane.lua _read_lane_creeps skips Entity.IsDormant), so a partially-fogged FULL wave whose visible slice is one creep momentarily reads count=1 and would be vetoed as thin - newly killing waves the 400 HP bar passed. That is the v0.1.80 partial-fog class ("false-fired when the enemy wave was partially fogged, strength undercounted"). So the lone read must PERSIST this long before it may veto: a genuine remnant holds count=1 for tens of seconds, while a vision-edge read resolves within ~1s as the wave closes. STAMPED IN THREE PLACES (State.loneSince): the unconditional 2s run_lane_scan (covers lanes no producer evaluated) AND both producers at the 0.4s decide cadence - scan-only stamping was a 2-sample test at 0.5Hz that discarded contradicting decide reads and left 2-4s of veto latency, inside which the g346 dispatch still fired (second-review finds 1+2). ANY not-lone read from ANY source restarts the hold; an ESTIMATED (fogged) read counts as not-lone. CALIBRATED ON THE REAL INCIDENT: g346 mid read e=1 est=n from t=336.9 (after an est=y estimate cleared it at 334.9), so the hold matures by ~338.9 and the bad t=339.3 keen IS vetoed. FAILS SAFE: below the hold the old v0.1.344 behaviour stands. Raise if partial-fog vetoes appear; 0 makes the count veto instantaneous (the reviewed-unsafe shape).
    MIN_CAMP_SLACK      = 10.0,                               -- v0.1.108 lane-first: only commit to a camp when the working budget (slack minus the reserved return-to-mid) is at least this. Below it a camp gets left half-done / walked back from (note 2), so do a fountain trip or hold at mid instead. ponytail ceiling, calibrate.
    MIN_FOUNTAIN_SLACK  = 6.0,                                -- v0.1.108 lane-first: minimum slack to fit a fountain recharge round-trip (keen home + top off + keen back) and still return for the fresh wave; below this just hold at mid. ponytail ceiling, calibrate.
    -- Timing scheduler (TINKER_SCHEDULE_DESIGN.md) calibration:
    MARCH_DMG_PER_CAST  = 450,                               -- effective wave damage one March cast deals (in-client v0.1.59: mid waves eff_hp ~1500-2000 clear in ~3-5 casts, so ~450/cast; was 300 -> casts 6-7 too high)
    MARCH_CAST_DUR      = 0.53,                              -- March cast point (Liquipedia 7.41c; was 0.5)
    ROBOT_KILL          = 1.5,                               -- robot sweep-to-kill duration (wave cal only; camp uses ROBOT_TAIL)
    ROBOT_TAIL          = 1.5,                               -- camp clear: per-clear overhead beyond nominal March cadence (approach wind-up + fire-verification lag). NOT a robot-death tail: Tinker leaves at the March budget and the robots finish autonomously while he walks off, so clear_t models COMMITMENT time (arrival -> last cast -> leave) = the quantity the planner schedules against. Calibrated off engage_done dur ~8.1 vs cadence 6.97 (3-cast Rearm-L1 clean pairs, v0.1.151); raw fit ~1.1, +0.4 margin for the unsampled operating points (singles/ancients/L2-L3 rearm).
    SCHED_LEAD          = 1.5,                               -- safety lead subtracted from leave_by so Tinker arrives early
    BOTTLE_MANA         = 200,                               -- drink Bottle when mana below this (and safe + not channeling)
    SOUL_RING_MANA      = 170,                               -- mana engine part 3 (Liquipedia 7.41c): Sacrifice = +170 TEMP mana (10s window - spend immediately), costs 170 HP, cd 30
    SR_HP_FRAC_MIN      = 0.55,                              -- never Sacrifice below this hp fraction (the 170 HP must be safe to pay)
    ARCANE_MANA         = 150,                               -- Arcane Boots Replenish: +150 mana, cd 55, free (Liquipedia)
    BOTTLE_HP_FRAC      = 0.55,                              -- drink Bottle when hp fraction below this
    BOTTLE_MANA_PER_CHARGE = 60,                             -- mana restored per Bottle charge (v0.1.130 capture, Liquipedia): effective-mana term in the shove afford gate
    PATH_RISK_MAX       = 0.42,                              -- item 6 (Farm.PathRisk): worst fog-aware enemy risk allowed along the hero->stand corridor; = FARM_SAFE_RISK (the live-abort threshold) so decide and abort agree. Calibrate off ft.prisk.
    -- COMMIT RISK v2 (TINKER_COMMIT_RISK_DESIGN_V2.md): enemy_risk_at scores danger RIGHT NOW and
    -- returns EXACTLY 0 past RISK_RADIUS 1400, but a shove commit spends travel plus a stand getting
    -- there, so a hero 1500-3000u out scores a clean zero and then walks in (g356 t=1095.0 commit:
    -- risk=0.00 prisk=0.00 enH=0 travel=4.4, then enH=4 prisk=0.60 at +4.2s, dead at +7s). The fix is
    -- RADIUS WIDENING - r_eff = RISK_RADIUS + APPROACH_SPEED * (travel_s + STAND_S) capped at WIDEN_MAX -
    -- which is monotone and never saturates, so risk stays a RANKING signal (edge subtraction pins every
    -- enemy inside 1400u at 1.000 and would veto essentially every destination). Reaches ONLY
    -- lane_unsafe's nv==0 fall-through, from the two shove producers, via opts.commit.
    COMMIT_APPROACH_SPEED = 50,    -- u/s an unseen enemy is assumed to close at. CALIBRATION: at the g356 MEDIAN shove exposure 8.4s (keen-aware travel 4.4 + stand 4.0) widen = 420, moving the veto radius 572u -> 743u at weight 1.0 and 628u -> 816u at KILL_W_HI 1.15 (Skywrath class), +30% either way; expected cost 1-3 newly refused shove commits a game, all in the band that already read 0.19-0.27. 0 = OFF, the no-code-edit KILL SWITCH: CommitWiden returns 0, r_eff == RISK_RADIUS bit-identical (IEEE-754 x+0.0 == x), and the commit_risk logline KEEPS FLOWING with ap=0 wd=0 chg=0, because a kill switch that also silences its own instrument is a new failure by construction. Tightening ladder, one validated game per step: 50/2000 -> 75/3000 -> 100/3500, and 100 is the CEILING for this scope (its MEDIAN widen 840 pushes the veto radius past GANK_RADIUS 1000, where lane_unsafe's visible-count branch and its proximity ruler start disagreeing at 999u vs 1001u). NOTE that ceiling is about the median, not the boundary: the CO-6 inversion starts at widen 831 (w=1.15) / 1049 (w=1.0), i.e. travel 12.6s / 17.0s at THIS speed, so a long-travel commit crosses it at the shipped 50 too. Analyzer A6 counting a few inversions on a ship build is expected and errs safe (the 1001u side refuses, the 999u side is pre-existing behaviour); it is not evidence the calibration is off.
    COMMIT_STAND_S        = 4.0,   -- s standing at the shove stand after arrival. NOT "how long the maneuver takes": the gate re-runs off a fresh enemy_snapshot every decide, so a "safe" answer only commits to ONE evaluation period. g356 measured the blind window (March->March cadence) at med 3.1 / p90 3.9 (predicted 0.53 + 2.69 = 3.22 at Rearm L1) and the shove stand (W1->W2->leave) at med 4.0, so 4.0 covers p90 of one and is the exact median of the other: one constant, both sites, no plumbing. The residual tail to the worst observed cycle (5.4) is not an unguarded window - the HP panic path still runs during channels.
    COMMIT_WIDEN_MAX      = 2000,  -- u cap on the widening. INVARIANT: >= COMMIT_APPROACH_SPEED * 35, pinned by a config lint that reads these constants out of this file as text. WHY IT IS AN INVARIANT: a cap sitting INSIDE the normal operating range silently BECOMES the operating value and the travel term stops mattering at all - that bit the reverted v0.1.357 attempt twice (cap 1400 / APPROACH 175 binds at d=0, i.e. the knob does nothing at any distance; cap 3500 / APPROACH 300 binds at d=1173u). At 50/2000 the cap binds at exposure 40s, 11s past the largest observed shove exposure, so it binds nowhere in the measured distribution. Raise it WITH the speed, never alone; wcap=1 on the commit_risk line is the field proof against the real distance distribution.
}

-- (Adjacent-camp pairing is computed LIVE in pair_spot_for below; the old static
-- CAMP_PAIRS table + tools/gen_camp_pairs.lua are retired.)

----------------------------------------------------------------- state ----
State.fsm          = "DECIDE"
State.laneWaveT    = {}    -- PHASE 2 (TINKER_SIDE_ANTICIPATION_DESIGN.md): per-lane cadence anchors {mid=,top=,bot=} - game-time a wave was last cleared at that lane's shove point. Mid consumers read .mid (the old lastWaveT, unchanged semantics); side entries feed side_wave_ctx stamp anticipation. v0.1.303 D-B: ALSO stamped at every wave_engage_arrived (arrivals were only stamped by 2 of ~6 exits - one imperfect wave regressed the clock to kinest).
State.laneMeet     = {}    -- v0.1.303 LANE-CLOCK D-A (TINKER_LANE_SCHEDULING_STUDY.md): per-lane last OBSERVED arrival ground {x=,y=,t=}, stamped at wave_engage_arrived. THE fogged anchor: a fogged lane-phase wave dispatches to where waves actually arrive, never to the mirror-kinematic guess (err 300-1400u = 40 geometry-vetoes runs 104-107 + 3/5 baseline misses run-108).
State.shoveLeaveBy = nil   -- leave-by deadline set by Lane.Schedule.Plan when a camp is picked (preemption)
State.schedSlack   = nil   -- slack budget handed to the jungle planner
State.marchCasts   = 0
State.nextDecide   = 0
State.nextOrder    = 0
State.panicUntil   = 0
State.channelUntil = 0
State.keenedSpot   = false   -- one Keen hop per committed spot, then walk
State.cyclePark    = nil     -- v0.1.339 THE CYCLE ARC: a committed park window { untilT, x, y } - fsm_decide short-circuits to this posture until the scheduler wants action (terminal gate right after Lane.Schedule.Plan); set only in the none block on a funded reason=slack window
State.shoveSuppress = { mid = 0, top = 0, bot = 0 }  -- Note 1 + ALL-LANES v0.1.225: after a shove got stuck (crash stand unreachable / tether release), recover instead of re-keening THAT LANE until this time; per-lane so a stuck side stand never suppresses mid
State.releaseSuppress = { mid = 0, top = 0, bot = 0 }  -- v0.1.252: tags a suppression as TETHER-RELEASE-created; release_cancel may only undo THESE (run-65: it canceled UNSAFE-abort safety windows -> shove/abort ping-pong vs 2 heroes; run-67: 2 of 3 cancels undid BUDGET delivery windows = the v0.1.197 3rd-W class)
State.dumped       = false   -- one-shot position-dump guard
State.cleared      = {}      -- camp_key -> game-time the camp re-opens (next xx:00 spawn)
State.campSeen     = {}      -- F1: camp_key -> { gold, ehp, seen_at }: last-seen REAL value (stacks included), used while fogged
State.loneSince    = {}      -- v0.1.345 FIX B: lane -> time the REAL (non-estimated) enemy wave first read <= SHOVE_THIN_CREEPS creeps (nil = not lone now). Written by the 2s run_lane_scan AND by both producers at the 0.4s decide cadence; any not-lone read from any source clears it, so a vision-edge count=1 must survive THIN_CREEPS_HOLD_S continuously before it may veto.
State.campDwell    = {}      -- v0.1.332: camp_key -> the OPEN per-hero dwell run { who, first, last } since v0.1.349, cleared on confirm (Farm.ObservedFarmers owns the shape; bounded by camp count)
State.allyFarmers  = {}      -- v0.1.336: ally unitname -> attributed camp-confirm count (>= FARMER_CORE_MARKS = contest-worthy core for the game; <= 4 ally names + a defensive ? sentinel, bounded)
-- nil by default: hero, player, team, march, rearm, keen, laser, spot, menu,
-- lowHpSince, moveSince, pendingVerify, cands, frame_t

------------------------------------------------------- helpers + pipeline --
-- On-screen DOTA clock (0:00 = first spawn), so next_respawn()/is_cleared align to
-- the real xx:00 neutral respawn (GetGameTime carries the ~90s pregame offset).
-- Falls back to the proven GetGameTime if GetDOTATime is absent.
local function now()
    if GameRules.GetDOTATime then return GameRules.GetDOTATime(false, false) end
    return (GameRules.GetGameTime and GameRules.GetGameTime()) or 0
end

-- Occupancy is VISION-limited (the neutral scan only returns camps in sight), so
-- the bot ASSUMES a camp is occupied unless it recently visited it and found it
-- empty / did its march budget. Cleared camps re-open at the next xx:00 spawn.
-- Fogged camps are valued from a per-tier estimate (TINKER_JUNGLE_REF midpoints).
local TIER_EST = {
    [0] = { gold = 55,  hp = 1400 },   -- small
    [1] = { gold = 85,  hp = 1900 },   -- medium
    [2] = { gold = 105, hp = 2400 },   -- large
    [3] = { gold = 160, hp = 3600 },   -- ancient (raw midpoint; v0.1.183 reverts the 4300 MR bump - the tier FLOOR owns the planning count now, and the sum-ceil only binds for stacks where raw totals are the honest input)
}
local function next_respawn() return (math.floor(now() / 60) + 1) * 60 end   -- next xx:00 (neutral spawn)
local function is_cleared(key)
    local t = State.cleared and State.cleared[key]
    return t ~= nil and now() < t
end
local function mark_cleared(key, until_t)   -- E0 (B8): optional short expiry for CONTESTED (not cleared) camps
    if key then State.cleared = State.cleared or {}; State.cleared[key] = until_t or next_respawn() end
end
-- Clear the chosen spot. For a PAIR, mark BOTH camps: the centred March (+ the extra clip
-- Marches) cleared both, and from the midpoint both centres are in vision so the occupancy
-- read that triggered this was valid. (Night + a very wide clip pair could put the far camp
-- out of vision -> a rare false-clear that self-heals at the next xx:00 respawn.)
local function mark_spot_cleared(s, until_t)
    if not s then return end
    mark_cleared(s.key, until_t)
    local ss = s.standSpot
    if ss and ss.paired and ss.partner then mark_cleared(Map.CampKey(ss.partner), until_t) end
end

local function marches_for(t)   -- tier 0=small 1=medium 2=large 3=ancient
    local m = State.menu
    if t == 0 then return m.mSmall:Get() elseif t == 1 then return m.mMedium:Get()
    elseif t == 2 then return m.mLarge:Get() elseif t == 3 then return m.mAncient:Get() end
    return 2
end

-- Do camp centres a,b match a K.FORCE_PAIRS whitelist entry (either order)? Matched by camp_key (100-unit
-- bucket, robust to rounding). Feeds Farm.GreedyPairs' `allow` so ONLY these pairs may exceed PAIR_RADIUS.
local function forced_pair(a, b)
    if not (a and b) then return false end
    local ka, kb = Map.CampKey(a), Map.CampKey(b)
    for _, f in ipairs(K.FORCE_PAIRS or {}) do
        local k1 = Map.CampKey({ x = f[1][1], y = f[1][2] })
        local k2 = Map.CampKey({ x = f[2][1], y = f[2][2] })
        if (ka == k1 and kb == k2) or (ka == k2 and kb == k1) then return true end
    end
    return false
end

local function refresh_handles(h)
    State.march = NPC.GetAbility(h, "tinker_march_of_the_machines")
    State.rearm = NPC.GetAbility(h, "tinker_rearm")
    State.keen  = NPC.GetAbility(h, "tinker_keen_teleport")  -- KV name (Liquipedia: "Keen Conveyance")
    State.laser = NPC.GetAbility(h, "tinker_laser")
end

local function ready(ab) return ab and Ability.CanBeExecuted(ab) == -1 end
local function mana() return NPC.GetMana(State.hero) or 0 end

-- EFFECTIVE mana for the shove afford gate = raw + Bottle charges (review #3: Tinker with charges
-- kept trekking home at ~70% mana because the gate only read raw mana; the charges ARE spendable).
local function effective_mana()
    local h = State.hero
    local bt = NPC.GetItem(h, "item_bottle", true)
    local ch = (bt and Item.GetCurrentCharges and Item.GetCurrentCharges(bt)) or 0
    local m = mana() + ch * K.BOTTLE_MANA_PER_CHARGE
    -- mana engine part 3 (2026-07-04): READY mana items are spendable on demand mid-clear, the
    -- same way charges are - counting them here is what lets the planner take a camp the raw
    -- pool cannot pay, instead of a fountain trip (17 trips/24min in run-19 = the top time sink).
    local ab = NPC.GetItem(h, "item_arcane_boots", true)
    if ab and Ability.CanBeExecuted(ab) == -1 then m = m + K.ARCANE_MANA end
    local sr = NPC.GetItem(h, "item_soul_ring", true)
    if sr and Ability.CanBeExecuted(sr) == -1
       and (Entity.GetHealth(h) or 0) >= (Entity.GetMaxHealth(h) or 1) * K.SR_HP_FRAC_MIN then
        m = m + K.SOUL_RING_MANA
    end
    return m
end

-- ── gold tracking (camp value via ACTUAL gold gained + GPM; camps respawn each xx:00) ──────────
-- Player.GetTotalGold (gitbook Player class) = the player's total gold. We track POSITIVE deltas as
-- "earned" (for GPM, so item spending does not skew it). Camp REMAINING value is NOT derived from these
-- deltas (they are contaminated by passive/lane/kill gold); it comes from the live alive-creep bounty
-- (gather_candidates + the fsm_engage cache refresh), so per-camp gold attribution lives there, not here.
local function total_gold()
    local ok, g = pcall(function() return Player.GetTotalGold and Player.GetTotalGold(State.player) end)
    return (ok and type(g) == "number") and g or nil
end

local function gold_tick()
    local g = total_gold()
    if g == nil then return end
    if State.goldPrev == nil then State.goldPrev = g; State.gpmT0 = now() end
    local delta = g - State.goldPrev
    State.goldPrev = g
    if delta > 0 then State.earned = (State.earned or 0) + delta end   -- GPM only (sum of positive deltas)
end

-- gold per minute over the run (earned = sum of positive deltas).
local function gpm()
    local mins = (now() - (State.gpmT0 or now())) / 60
    return (mins > 0.05) and ((State.earned or 0) / mins) or 0
end
local function origin(e) return Entity.GetAbsOrigin(e) end

-- True while the Rearm/Keen channel must be protected: the live channel read OR
-- the timer backstop. Panic runs before this gate, so a save can still break it.
-- v0.1.351: cd_remaining MUST be defined ABOVE is_channeling. It is called at the top of
-- is_channeling (the rearmPending reset-observed test), and a Lua local is not in scope
-- before its definition - down there the call resolved as a GLOBAL, i.e. nil. It never
-- crashed only because the guard in front of it (rp.mcd > 4) is itself always false while
-- cd_remaining degrades to a binary 0/0.1; repairing the cooldown read would have made that
-- guard true and turned the next tick into a nil-call. Found by the v0.1.350 code review.
local function cd_remaining(ab)
    if not ab then return 0 end
    local ok, cd = pcall(function() return Ability.GetCooldownTimeRemaining and Ability.GetCooldownTimeRemaining(ab) end)
    if ok and type(cd) == "number" and cd > 0 then return cd end
    return ready(ab) and 0 or 0.1
end

local function is_channeling()
    if NPC.IsChannellingAbility and NPC.IsChannellingAbility(State.hero) then return true end
    -- v0.1.253 (run-69 t=1064/1303, "walked from fountain to safelane"): CHANNEL_PAD 0.2 does
    -- not cover the issue->execute delay + cast point, so the timer expired a beat BEFORE the
    -- keen teleport landed - the fountain chain-drink's cast then canceled the ~99% channel
    -- (cd + 75 mana burned, hero still at the fountain), and the blink rung ran in the 0.3s gap
    -- before keenPending.due, moving him off-origin so keen_cancel_check's parked-at-origin
    -- signature stayed silent -> an 11k WALK to bot. Protect a pending keen to its OWN due; the
    -- landing test self-clears the moment the teleport arrives (no post-landing stall).
    local kp = State.keenPending
    if kp then
        -- v0.1.258 (run-73 game transition): a stale hero handle at game teardown made
        -- GetAbsOrigin throw here every tick until the next self_acquire; pcall-guard it.
        local okm, me = pcall(origin, State.hero)
        if not okm then me = nil end
        if me and kp.land and me:Distance(kp.land) < 600 then
            State.keenPending = nil                        -- teleport landed: free immediately
        elseif now() < (kp.due or 0) then
            return true
        end
    end
    -- E0 (C1): Rearm gets the same due-protection (run-69 proved CHANNEL_PAD misses the
    -- issue->execute delay + cast point; a bottle/March order through the expired gate would
    -- break the ~95% Rearm tail, and the .254 detector would then blame an ENEMY for our own
    -- cancel). Self-clears the moment the reset is OBSERVED, so a completed channel never stalls.
    local rp = State.rearmPending
    if rp then
        if (rp.mcd and rp.mcd > 4 and cd_remaining(State.march) < 0.5)
           or (rp.kcd and rp.kcd > 4 and cd_remaining(State.keen) < 0.5) then
            State.rearmPending = nil                       -- reset observed: channel completed, free
        elseif now() < (rp.due or 0) then
            return true
        end
    end
    return now() < (State.channelUntil or 0)
end

-- cast-fired verification (cooldown jump): an ISSUED order only counts as FIRED if
-- the ability stops being ready / goes on cooldown shortly after.
local function verify_cast(name, ab, extra)
    State.pendingVerify = { name = name, ab = ab, baseCD = cd_remaining(ab), expire = now() + 0.6, extra = extra }
end
local function process_verify()
    local v = State.pendingVerify
    if not v then return end
    if (not ready(v.ab)) or cd_remaining(v.ab) > v.baseCD + 0.05 then
        logline(v.name .. " FIRED" .. (v.extra or "")); State.pendingVerify = nil
    elseif now() > v.expire then
        logline(v.name .. " issued_NOT_fired"); State.pendingVerify = nil
        -- E0 (B6): a swallowed keen/rearm ORDER must not leave a ~3s PHANTOM channel window -
        -- channelUntil was armed at issue, so chain-disables interleaved real disable windows
        -- with self-imposed do-nothing windows. The live read confirms nothing is channeling.
        if (v.name == "keen" or v.name == "keen_home" or v.name == "rearm")
           and not (NPC.IsChannellingAbility and NPC.IsChannellingAbility(State.hero)) then
            State.channelUntil = 0
            if v.name == "rearm" then State.rearmPending = nil else State.keenPending = nil end
        end
    end
end

-- THE single PrepareUnitOrders site (unthrottled core). V2-confirmed
-- issuer/flags that PROVABLY fire the point casts; lib/order migration is
-- deferred until its issuer/flags are confirmed in-client. ARC E2: defense
-- saves call this DIRECTLY (via SAVE_CFG) - a save landing within ORDER_GAP
-- (50ms) of a farm order must not be swallowed (the .234 order-swallow class;
-- the dispatcher reads a false return as fire_returned_false and fails the
-- WHOLE chain walk). It still WRITES State.nextOrder, so the next farm order
-- defers to the save, never the other way around. Everything else goes
-- through the rate-gated issue() wrapper below.
local function issue_def(order, ability, target, pos)
    Player.PrepareUnitOrders(State.player, order, target, pos, ability,
        Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_HERO_ONLY, State.hero,
        false, false, false, true, false, false)   -- V2-confirmed (matches Autofarm V2)
    State.nextOrder = now() + K.ORDER_GAP
    return true
end
-- single farm-order chokepoint: the ORDER_GAP rate gate over the core.
local function issue(order, ability, target, pos)
    if now() < State.nextOrder then return false end
    return issue_def(order, ability, target, pos)
end
-- Movement dedup (v0.1.161, user: flickering movement = orders issued one after another): the live
-- re-stand drifts a few units per tick with the creeps, so callers re-issued MOVE to a near-identical
-- point up to 20x/s (ORDER_GAP 0.05) - each re-issue restarts pathing/turning = the visible twitch.
-- ONE guard at the chokepoint covers every caller: skip when the target is within MOVE_DEDUP_DIST of
-- the last issued move AND that order is younger than MOVE_DEDUP_S (re-assert ~2x/s so a swallowed
-- order self-heals; a genuinely NEW destination >75u away still issues immediately).
local function move_to(pos, src)
    local lm = State.lastMove
    if lm and now() - lm.t < K.MOVE_DEDUP_S then
        local dx, dy = pos.x - lm.x, pos.y - lm.y
        if dx * dx + dy * dy <= K.MOVE_DEDUP_DIST * K.MOVE_DEDUP_DIST then return true end   -- already moving there
    end
    if issue(UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION, nil, nil, pos) then
        -- src (v0.1.242) names the producer; kept as documentation + for any future move-level
        -- diagnosis (the v0.1.244 flicker took two instrument versions to name - never again).
        State.lastMove = { x = pos.x, y = pos.y, t = now(), src = src }
        return true
    end
    return false
end
local function cast_pos(ab, pos) return issue(UO.DOTA_UNIT_ORDER_CAST_POSITION, ab, nil, pos) end
local function cast_no_target(ab) return issue(UO.DOTA_UNIT_ORDER_CAST_NO_TARGET, ab, nil, nil) end
local function cast_target(ab, ent) return issue(UO.DOTA_UNIT_ORDER_CAST_TARGET, ab, ent, nil) end

-- friendly fountain position from the static table (team-matched).
local function friendly_fountain_pos()
    for _, f in ipairs(MapData.FOUNTAINS or {}) do
        if f.team == State.team and f.pos then return Vector(f.pos[1], f.pos[2], f.pos[3]) end
    end
    return nil
end
local function enemy_fountain_pos()
    for _, f in ipairs(MapData.FOUNTAINS or {}) do
        if f.team ~= State.team and f.pos then return { x = f.pos[1], y = f.pos[2] } end
    end
    return nil
end

-- v0.1.327 S2 PER-LANE DEPTH (user-approved tree review; the side-parity root fix): signed depth
-- of `pos` in the LANE frame - zero at the LANE's T1 midpoint (mid (-510,-378) = the observed meet
-- ground; top/bot theirs), + = enemy side, axis unchanged (own fountain -> enemy fountain). The old
-- zero (the FOUNTAIN midpoint) sits ~583 lane-units toward DIRE of the mid centre, so Dire read the
-- lane centre at +583 (past the old 550 band = could not dispatch to its OWN meet -> the under-tower
-- posture, the whole 2026-07-20 arc) while Radiant's band reached centre+1133. Lane.DepthRuler /
-- Lane.Depth are pure lib fns (offline-tested, 753/0) consumed by the brain AND the depth-audit -
-- the auditor can never drift from the brain again. `lane` defaults to mid; relative comparisons
-- (pos-vs-tower) cancel the zero under any lane. Ceiling: S4 arc-length depth, same contract.
local function stand_depth(pos, lane)
    if not pos then return 0 end
    State.depthRuler = State.depthRuler or (State.team and Lane.DepthRuler(MapData.TOWERS, MapData.FOUNTAINS, State.team)) or nil
    if not State.depthRuler then return 0 end
    return Lane.Depth(State.depthRuler, pos, lane)
end
-- v0.1.315 THE TWO-SIDED INTERCEPT CLAMP: a FOGGED lane-phase crash is clamped to the
-- walk-farmable lane band [ -LANE_ANCHOR_BACK (our side) .. WALK_DEPTH_MAX (enemy side) ]
-- along the fountain axis. v0.1.307's anchor floor clamped ONLY the too-deep-our-side case
-- (tower-pushed arrivals teaching the clock to wait at our tower); the too-deep-ENEMY case
-- (s.meeting skewing deep when laneMeet is empty/stale, run-115) dispatched a deep stand
-- that estimates-never-veto passed [covers=true] but the movement walk-law then deep_rejected
-- = the shove_stuck flutter + jungle-preference + stuck-at-our-tower regressions. Meet the
-- fogged wave in the lane; the live re-stand owns precision once it shows.
local function clamp_intercept(cp, fwd, lane)
    if not cp then return cp end
    -- v0.1.323 BEST-POSITION CASTING (user doctrine): optional fwd pushes the meeting UP-LANE
    -- (toward the enemy fountain, the same axis the clamp pulls on) BEFORE the band clamp -
    -- the band caps the ratchet; computed per decide = frozen by construction (bug #5).
    -- Folded INTO the clamp: the main chunk sits at Lua's 200-local limit, no new top-level locals.
    if (fwd or 0) ~= 0 then
        local fp0, ep0 = friendly_fountain_pos(), enemy_fountain_pos()
        if fp0 and ep0 then
            local fx, fy = ep0.x - fp0.x, ep0.y - fp0.y
            local fl = math.sqrt(fx * fx + fy * fy)
            if fl > 1 then cp = { x = cp.x + fx / fl * fwd, y = cp.y + fy / fl * fwd } end
        end
    end
    local d = stand_depth(cp, lane)
    local target = (d < -K.LANE_ANCHOR_BACK and -K.LANE_ANCHOR_BACK)
                or (d > K.WALK_DEPTH_MAX and K.WALK_DEPTH_MAX) or nil
    if not target then return cp end
    local fp, ep = friendly_fountain_pos(), enemy_fountain_pos()
    if not (fp and ep) then return cp end
    local ux, uy = ep.x - fp.x, ep.y - fp.y
    local ul = math.sqrt(ux * ux + uy * uy)
    if ul <= 1 then return cp end
    local pull = target - d
    return { x = cp.x + ux / ul * pull, y = cp.y + uy / ul * pull }
end
-- Note 3: opts for Farm.StructuralRisk (fountains + the tagged contested-camp zones).
local function risk_opts()
    local of, ef = friendly_fountain_pos(), enemy_fountain_pos()
    -- F3 deep-farm relax REVERTED (v0.1.88): it opened contested enemy-side camps (a Dire Tinker
    -- farming radiant camps at risk ~0.36 that are ~0.45 = vetoed without the relax). Back to the
    -- conservative static veto: enemy-territory camps stay vetoed by RISK_HARD.
    local zones = {}
    for _, c in ipairs(K.RISK_CONTESTED_CAMPS or {}) do
        zones[#zones + 1] = { x = c[1], y = c[2], radius = K.RISK_CONTESTED_RADIUS, bump = K.RISK_CONTESTED_BUMP }
    end
    return { our_fountain = of and { x = of.x, y = of.y } or nil, enemy_fountain = ef,
             half_weight = K.RISK_HALF_WEIGHT, zones = zones }
end
-- Keen home = CAST_POSITION at the friendly fountain (CAST_NO_TARGET self-cast was
-- issued-but-never-fired; CAST_POSITION is the order type that actually fires).
local function keen_home(purpose)
    local fp = friendly_fountain_pos()
    if not fp then return false end
    if cast_pos(State.keen, fp) then
        State.channelUntil = now() + K.KEEN_CHANNEL + K.CHANNEL_PAD
        -- keen-efficiency arc: purpose (return/panic/unstick) + from + mana ride the FIRED line
        -- so --keen-report can tell a refill trip from a panic/unstick home (the home-cycle question)
        local me = State.hero and origin(State.hero)
        verify_cast("keen_home", State.keen, string.format(" purpose=%s from=(%.0f,%.0f) mana=%.0f",
            purpose or "?", me and me.x or 0, me and me.y or 0, mana()))
        return true
    end
    return false
end
-- ARC E1 forward declaration: the kit-aware channel gate needs the fog-snapshot machinery
-- defined further down; try_rearm reads the same local slot at call time.
local channel_threat_near

local function near_fountain()
    local fp = friendly_fountain_pos()
    local me = State.hero and origin(State.hero)
    return (fp and me and me:Distance(Vector(fp.x, fp.y, me.z)) < 1200) and true or false
end

-- Rearm if ready and affordable (reserves escape mana); sets the channel timer + verify.
local function try_rearm()
    if not ready(State.rearm) then return false end
    -- v0.1.254 CANCEL BACKOFF (Defense case-file #1, user: "vs hard disables tinker rearms close
    -- to the enemy -> consecutive rearms -> mana dry"): a stun/hex breaks the channel with the
    -- mana already SPENT, and nothing detected it - March stays on cd, so the very next tick
    -- re-channeled next to the same disabler (lane_unsafe's 1v1-trade rule correctly stays for
    -- FARMING, but channeling converts the trade into a guaranteed mana burn). After an OBSERVED
    -- cancel (rearm_cancel_check), hold further rearms briefly - one cancel costs one burn, not
    -- five. Fountain-adjacent rearms are exempt (regen covers them; nothing disables us there in
    -- the demo baseline, and the backoff self-arms only when a cancel actually happened).
    if State.rearmCancelT and now() - State.rearmCancelT < K.REARM_CANCEL_BACKOFF_S
       and not near_fountain() then return false end
    -- ARC E1 (case-file #1 ROOT FIX, the .254 backoff's proactive half): never START a Rearm
    -- within a disabler-kit enemy's reach - the backoff paid one burn per episode to LEARN;
    -- the gate skips the tuition. Readiness stamps arrive with E2; assume-ready until then.
    if channel_threat_near and not near_fountain() then
        local thr = channel_threat_near(origin(State.hero))
        if thr then
            -- run-75 t=619 bail input: stamp when the defer STARTED so consumers can
            -- tell a persisting defer (parked disabler) from a transient one.
            State.chanDeferSince = State.chanDeferSince or now()
            if now() - (State.chanDeferLogT or 0) > 2.0 then
                State.chanDeferLogT = now()
                logline("channel_defer rearm threat=" .. thr)
            end
            return false
        end
        State.chanDeferSince = nil   -- gate clear: reach broke or the kit went on cd
    end
    local rcost = (Ability.GetManaCost and Ability.GetManaCost(State.rearm)) or K.REARM_MANA_FB   -- v0.1.97: was a hardcoded 150 (Rearm fallback is 225)
    -- v0.1.384 PROBE (log-only, nothing gates on it). THIS REFUSAL IS SILENT, and it is the one
    -- place the two rearm-fundability rulers disagree (bug class 3). The callers pre-check
    -- effective_mana() = raw + Bottle charges + Arcane + Soul Ring, with NO escape reserve (the `engage_bail reason=rearm_unfundable` site
    -- bails only below rearm+march); this spends RAW against the 150 reserve. Between the two bars
    -- the hero neither bails nor rearms, and sits in ENGAGE until the v0.1.377 castless watchdog
    -- releases it ~4s later. The band is reachable on paper - raw 345..375 with no items at all at
    -- L2 costs, and wider when counted Bottle charges are never converted because bottle_tick only
    -- drinks below K.BOTTLE_MANA 200 - but it has NEVER been measured: `engage_bail
    -- reason=rearm_unfundable` is 0 across five games and this site logs nothing at all.
    -- IF `rearm_nofund` SHOWS A REAL RATE, the fix is to make the callers test the SAME quantity
    -- this does (raw + reserve), so the bail is honest instead of a stall. IF IT STAYS AT ZERO,
    -- CLOSE THE ITEM: the mismatch is unreachable in play and the reserve is safety-critical.
    local need = State.menu.escapeMana:Get() + rcost
    if mana() < need then
        -- v0.1.386: hand the gap to bottle_tick. UNTHROTTLED (the logline below is throttled and
        -- must not gate behaviour) and stamped every refusal, so the drink decision sees the CURRENT
        -- shortfall rather than a stale one.
        State.rearmNoFundT, State.rearmNoFundGap = now(), need - mana()
        if now() - (State.rearmNoFundLogT or 0) > 1.0 then
            State.rearmNoFundLogT = now()
            logline(string.format("rearm_nofund raw=%.0f eff=%.0f need=%.0f rcost=%.0f gap=%.0f fsm=%s",
                mana(), effective_mana(), need, rcost, need - mana(), tostring(State.fsm)))
        end
        return false
    end
    if not cast_no_target(State.rearm) then return false end
    local lvl = (Ability.GetLevel and Ability.GetLevel(State.rearm)) or 1
    State.channelUntil = now() + (K.REARM_CHANNEL[lvl] or K.REARM_CHANNEL[1]) + K.CHANNEL_PAD
    verify_cast("rearm", State.rearm)
    -- v0.1.254 cancel detector stash (the keen_cancel_check twin): a successful Rearm RESETS the
    -- basic cds at channel end - judge at due whether the on-cd ability actually reset.
    State.rearmPending = { due = State.channelUntil + 0.2,
                           mcd = cd_remaining(State.march), kcd = cd_remaining(State.keen) }
    return true
end

-- ── safety: enemy sampling + risk ────────────────────────────────────────────
-- Per-decide fog snapshot (COR-1): visible enemies at true pos + recently-fogged
-- enemies as a last-seen pos + age, consumed by FogProximityRisk. Replaces the
-- old enemy_positions() which froze fog enemies at a stale point (no disc).
local function enemy_snapshot()
    local snap = Escape.FogSnapshot(State.hero, { max_ms = K.FOG_MS, now = now })
    -- v0.1.353 LOG-ONLY fog-clock probe (TINKER_FOG_CLOCK_DESIGN.md). ZERO behaviour: the
    -- snapshot above is returned untouched, this block only OBSERVES it. Why it exists: the
    -- age inside that snapshot is computed from TWO DIFFERENT CLOCKS - the `now` injected on
    -- the line above is GameRules.GetDOTATime, while Hero.GetLastVisibleTime is stamped on
    -- the ENGINE clock (Escape.FogSnapshot defaults to GlobalVars.GetCurTime and escape.lua's
    -- EscapeCfg documents the field as such). So FogSnapshot SUBTRACTED across clocks, the result
    -- is about -90 to -103, the next line clamps it to 0, and EVERY enemy fogged for under
    -- ~100s is scored as a full-confidence VISIBLE enemy. Five constants (FOG_MS, FOG_SPREAD,
    -- FOG_AGE_CAP, FOG_FRESH_S, FOG_REACH_CAP) have therefore never influenced a decision.
    -- raw= is the LOAD-BEARING field: a nil GetLastVisibleTime is deliberately treated as
    -- "fresh visible" (lib/escape.lua FogSnapshot), producing a byte-identical symptom, so if raw
    -- is always nil the clock fix is a NO-OP. 2.0s debounce matches log_walk_leg/camp_scan.
    if now() - (State.fogProbeT or -99) >= 2.0 then
        State.fogProbeT = now()
        local cur = (GlobalVars and GlobalVars.GetCurTime and GlobalVars.GetCurTime()) or -1
        local vis, fog = 0, 0
        for i = 1, #snap.heroes do
            if snap.heroes[i].visible then vis = vis + 1 else fog = fog + 1 end
        end
        -- v0.1.354: Vision stats ride along. vev= is THE field to read first next game:
        -- if it is 0 the OnSetDormant callback never fired for enemy heroes, the tracker is
        -- inert, and every hero is behaving exactly as it did before lib/vision existed.
        -- vtypes= records the undocumented Enum.DormancyType values so the enum is learned
        -- from a real log instead of guessed.
        local vs = Escape.Vision.Stats()
        local tks = {}
        for k, n in pairs(vs.types) do tks[#tks + 1] = k .. ":" .. n end
        table.sort(tks)
        logline(string.format("fog_probe t=%.1f off=%.1f vis=%d fog=%d vtrack=%d vev=%d vtypes=%s vsh=%d",
            now(), cur - now(), vis, fog, vs.tracked, vs.events,
            (#tks > 0) and table.concat(tks, ",") or "-", (vs.tracked_sh or 0)))
        local me = origin(State.hero)
        for i = 1, #snap.heroes do
            local h = snap.heroes[i]
            if not h.visible then
                local raw                                  -- UNMODIFIED getter return
                if Hero.GetLastVisibleTime and h.entity then
                    local ok, v = pcall(Hero.GetLastVisibleTime, h.entity)
                    if ok and type(v) == "number" then raw = v end
                end
                local d = -1
                if me and h.pos then
                    local dx, dy = me.x - h.pos.x, me.y - h.pos.y   -- component math: h.pos may be a plain table
                    d = math.sqrt(dx * dx + dy * dy)
                end
                local nm = "?"
                if h.entity and NPC.GetUnitName then
                    local ok2, n2 = pcall(NPC.GetUnitName, h.entity)
                    if ok2 and type(n2) == "string" then nm = n2 end
                end
                -- age_now is logged WITHOUT escape.lua's `if age < 0 then age = 0` clamp on
                -- purpose: the negative number IS the evidence.
                -- v0.1.409: age_real now carries the SHADOW age (the dtype-gated tracker), the
                -- raw material for the offline age_cap sweep. raw/age_now stay wired to
                -- Hero.GetLastVisibleTime as standing evidence that THAT getter is dead.
                local ash = Escape.Vision.AgeShadow(h.entity)
                logline(string.format("fog_hero raw=%s age_now=%s age_real=%s d=%.0f name=%s",
                    raw and string.format("%.1f", raw) or "nil",
                    raw and string.format("%.1f", now() - raw) or "nil",
                    ash and string.format("%.1f", ash) or "nil",
                    d, nm))
            end
        end
    end
    return snap
end

-- Blink+Threat pt2: weight a fogged/visible enemy's proximity risk by its KILL-THREAT
-- kit (lethal -> 1.4, harmless support -> 0.6) so a fogged Pudge near mid reads riskier
-- than a fogged support. Every safety consumer (shove gate, camp abort, rearm, blink
-- escape/travel) reads enemy_risk_at, so all become threat-aware. pcall: NPC.GetUnitName
-- throws on a non-NPC entity (Lina idiom); snapshot entries are heroes so it is safe.
local function kill_threat_w(h)
    local ok, name = pcall(function() return NPC.GetUnitName and NPC.GetUnitName(h.entity) end)
    if not (ok and name) then return 1 end
    return HeroValue.KillThreat(name)
end

-- ARC E1 (Defense case-file #1 root fix): the kit-aware channel gate. A channel started
-- within a disabler's reach is a guaranteed loss (the stun breaks it, mana spent), and
-- lane_unsafe's 1v1-trade rule - correct for FARMING next to a lone laner - can never gate
-- channels. Fogged snapshot entries count with their probable-radius disc: a disabler that
-- just slipped into trees is MORE dangerous.
-- E1 static half + E2 readiness: cache the full breaker LIST per enemy name (ability +
-- range each), not just the max range - the gate can then skip breakers that are
-- stamped/observed on cooldown (false = no disable kit).
local function enemy_breakers(name)
    local c = State.disableRange; if not c then c = {}; State.disableRange = c end
    local v = c[name]
    if v == nil then
        local hd = HeroData.Get and HeroData.Get(name)
        v = ChannelGate.Breakers(hd and hd.abilities, AbilityData, ThreatData) or false
        c[name] = v
    end
    return v
end
do
    -- E2 live cooldown reads on VISIBLE enemies. The gitbook documents Ability.GetCooldown
    -- but not enemy-applicability -> pcall; each outcome probe-logs ONCE (ok/nil) but a
    -- failed read never disables the path - it degrades that one call to stamps-only and
    -- keeps trying (the read only runs for visible enemies within breaker reach during a
    -- gate sweep, so the retry is cheap). Block-scoped (not per-call, not a chunk local):
    -- the gate runs per tick in try_rearm/keen/return paths.
    -- v0.1.272-273 (run-83, user rule: "the disable ability level has to be checked no
    -- matter the hero level"): a breaker is CLEARED when it provably cannot fire. The
    -- ABILITY level is the ground truth for every breaker (Lina LSA / Zeus Bolt are
    -- basics - the ult shortcut never helps them); the hero-level ult fact only covers
    -- unreadable/fogged ults, aged at the fastest-leveling bound (the .272 max-seen check
    -- had a staleness hole: a Necro seen at 4 can be 6 after a long fog). Live reads on
    -- visible enemies stamp observations (State.enObs); fogged heroes consume the fresh
    -- stamps via ChannelGate.LevelCleared. Pre-6 Necro deferring every laning Rearm into
    -- a 500u stepback round trip was the class this kills, at the one chokepoint.
    local function read_breaker(ent, ability)   -- live level + cd, nil-safe (E2 probe style)
        local ok, lvl, cd = pcall(function()
            local h = NPC.GetAbility and NPC.GetAbility(ent, ability)
            if not h then return nil, nil end
            return Ability.GetLevel and Ability.GetLevel(h),
                   Ability.GetCooldown and Ability.GetCooldown(h)
        end)
        if not ok then return nil, nil end
        lvl = (type(lvl) == "number") and lvl or nil
        cd = (type(cd) == "number") and cd or nil
        if lvl and not State.enLvlProbeOk then State.enLvlProbeOk = true; logline("en_lvl_probe ok") end
        if cd then if not State.enCdProbeOk then State.enCdProbeOk = true; logline("en_cd_probe ok") end
        elseif not State.enCdProbeNil then State.enCdProbeNil = true; logline("en_cd_probe nil") end
        return lvl, cd
    end
    channel_threat_near = function(pt)
        if not pt then return nil end
        local snap = State.fog or enemy_snapshot()
        -- E2 fix: snapshot entries live under .heroes ({t=, heroes=}); E1's ipairs(snap)
        -- walked the empty array part, so the gate never saw anyone.
        for _, h in ipairs((snap and snap.heroes) or {}) do
            local ok, name = pcall(function() return NPC.GetUnitName and NPC.GetUnitName(h.entity) end)
            local br = ok and name and enemy_breakers(name)
            if br and h.pos then
                State.enObs = State.enObs or {}
                local obs = State.enObs[name]; if not obs then obs = { abil = {} }; State.enObs[name] = obs end
                if h.visible then
                    local ok2, hl = pcall(function() return NPC.GetCurrentLevel and NPC.GetCurrentLevel(h.entity) end)   -- the lib/hero_value-proven read
                    if ok2 and type(hl) == "number" and hl > 0 then obs.hero = { lvl = hl, t = now() } end
                end
                local dx, dy = h.pos.x - pt.x, h.pos.y - pt.y
                local d = math.sqrt(dx * dx + dy * dy)
                for _, b in ipairs(br) do
                    local cd
                    if h.visible then
                        local lvl
                        lvl, cd = read_breaker(h.entity, b.ability)
                        if lvl then obs.abil[b.ability] = { lvl = lvl, t = now() } end
                    end
                    -- readiness judged at now()+horizon: a stamp expiring (or a live cd
                    -- ending) DURING our 1.2-2.93s channel is a ready breaker for it.
                    -- Only a cd longer than the horizon clears; level observations clear
                    -- via LevelCleared (fresh ability-level-0, or the aged ult fact).
                    -- v0.1.412: ZERO THE STALE GHOST'S DISC, keep its raw-distance catch (the
                    -- v0.1.410 flip armed this term). Pre-flip, Vision never stamped, so h.age
                    -- was 0 and probable_radius 0 on EVERY fogged row: the gate fired on raw
                    -- d <= range + margin for ALL fogged disablers, whatever their real fog
                    -- time. Post-flip a long-fogged disabler carried a disc of up to 30s x
                    -- FOG_MS = 16500u, and range + 500 + that covered the whole map: g405
                    -- watched a Bane fogged 42-66s at 10-17k units veto EVERY keen cast site
                    -- (a 26.7s walk) and a fogged Tiny across the map defer rearms. The fix
                    -- keeps the fresh-fog disc (<= 5s x 550 = 2750u) and zeroes the disc for
                    -- ghosts past FOG_AGE_CAP, WITHOUT dropping them: a stale lurker whose
                    -- last-known position is inside raw reach (trees next to the stand) still
                    -- gates, which is exactly the pre-flip catch. (A first cut dropped stale
                    -- ghosts outright; the adversarial review caught that it removed the
                    -- near-lurker catch no other layer covers - FogProximityRisk drops them,
                    -- ReachableFog wants age <= 1.5s, lane_unsafe counts visible only.)
                    if not ChannelGate.LevelCleared({ ability = b.ability, ult = b.ult },
                                                    { abil = obs.abil[b.ability], hero = obs.hero }, now())
                       and not (cd and cd > K.CHANNEL_GATE_HORIZON)
                       and d <= b.range + K.CHANNEL_GATE_MARGIN
                               + (((h.age or 0) <= K.FOG_AGE_CAP) and (h.probable_radius or 0) or 0)
                       and ChannelGate.ReadyAt(State.castStamps or {}, name, b.ability, now() + K.CHANNEL_GATE_HORIZON) then
                        return name, h.pos    -- a plausibly-READY breaker is in reach: gate the channel (pos: v0.1.267 step-back aiming)
                    end
                end
            end
        end
        return nil
    end
end

-- COMMIT RISK v2 (TINKER_COMMIT_RISK_DESIGN_V2.md section 3.2): the optional `widen` is a KERNEL
-- BANDWIDTH term, in units, added to the falloff radius only ("over the next `exposure` seconds an
-- enemy this far away becomes relevant"). It is NOT a position correction, which is why it must
-- never reach the fog disc: FogProximityRisk's `radius = age * fog_ms` genuinely relocates the
-- enemy, while subtracting the widen from the edge instead saturates (once widen >= edge the risk
-- pins at 1.000 and every destination is vetoed). Expressed here as a bigger `risk_radius` on the
-- UNMODIFIED lib function, verified bit-identical to a lib-side opts.widen over 1.2M hero
-- evaluations, so lib/escape.lua takes zero modified lines and Lina/Sniper cannot be touched.
-- 21 of the 22 reads pass nothing: `widen or 0` keeps them bit-identical (x + 0.0 == x).
local function enemy_risk_at(pt, widen, shadow)
    if not pt then return 0 end
    local snap = State.fog or enemy_snapshot()   -- per-decide snapshot (set in fsm_decide); avoids rebuilding it ~40x
    if shadow then
        -- v0.1.409 build 1 (TINKER_FOG_TRACKER_DESIGN.md): the SHADOW twin of this read - same
        -- constants, same weight_fn, ages from the dtype-gated shadow tracker instead of the
        -- never-stamping live one. LOG-ONLY: the only callers passing shadow=true are the
        -- prisk_sh/crisk_sh riders, and no decision reads their output. Cached per live
        -- snapshot IDENTITY: all per-decide reads reuse one copy, and every State.fog
        -- assignment site invalidates it automatically (new identity, recompute).
        -- No new-match reset needed for the same reason.
        if State.fogShSrc ~= snap then
            State.fogShSrc, State.fogSh = snap, Escape.Vision.ShadowAges(snap)
        end
        snap = State.fogSh
    end
    -- v0.1.247 CRASH FIX (found by a tester of the public mirror, field-verified): several
    -- callers pass a PLAIN {x,y} table (safe_stand_for's raid_safe stand from Map.Nav.SafeDest/
    -- Map.SnapWalkable, lane_unsafe's pos, lane_go dests) while FogProximityRisk calls
    -- pt:Distance2D - engine-Vector only. With any hero in the snapshot (visible OR fresh-
    -- fogged) that threw inside escape.lua EVERY decide -> fsm_decide aborts before picking ->
    -- FSM frozen in DECIDE at ~50 errors/s. Our demo runs never saw it (no enemy heroes =
    -- empty snapshot = the loop never ran). Normalize ONCE here, the same idiom as
    -- enemy_tower_risk - one guard at the chokepoint covers every caller.
    local p = Vector(pt.x, pt.y, 0)
    return Escape.FogProximityRisk(snap, p, {
        risk_radius = K.RISK_RADIUS + (widen or 0), fog_ms = K.FOG_MS,
        fog_spread = K.FOG_SPREAD, age_cap = K.FOG_AGE_CAP, now = now,
        weight_fn = kill_threat_w })
end

-- Deep 1 (v0.1.76): risk from a live ENEMY tower near a point. PLATEAU model - full inside the
-- tower's attack range, linear taper to 0 at TOWER_RISK_RADIUS. The shove gate's positional veto
-- + (v0.1.87) the keen/blink landing safety. Ganks are caught by enemy_risk_at; this catches the
-- tower itself. Enumerate-then-filter by team (robust to the API's team default).
local function enemy_tower_risk(pos)
    local R, rng = K.TOWER_RISK_RADIUS, K.TOWER_ATTACK_RANGE
    local best = 0
    local p = Vector(pos.x, pos.y, 0)
    for _, t in ipairs(Map.TowersInRadius(p, R) or {}) do
        if Entity.GetTeamNum(t) ~= State.team and Entity.IsAlive(t) then
            local d = origin(t):Distance(p)
            local f = (d <= rng) and 1 or (d < R and (R - d) / (R - rng) or 0)
            if f > best then best = f end
        end
    end
    return best * K.TOWER_RISK_WEIGHT
end

-- v0.1.105 LANE PRIORITIZATION: the enemy T1 of a LANE from the static map (name+team) + whether it
-- is still ALIVE (any alive enemy tower within TOWER_ALIVE_R of its static spot). Drives the
-- tower-aware shove veto (supersedes the crude SHOVE_MAX_DEPTH depth proxy). Returns ({x,y} or nil),
-- alive. ALL-LANES v0.1.225: lane-parameterized (absorbs enemy_mid_t1 - one producer for the crash
-- clamp + the leash trigger on every lane).
local function enemy_lane_t1(lane)
    local pos
    local key = "tower1_" .. (lane or K.HOME_LANE)
    for _, t in ipairs(MapData.TOWERS or {}) do
        if t.team ~= State.team and t.pos and t.name and t.name:find(key, 1, true) then
            pos = { x = t.pos[1], y = t.pos[2] }; break
        end
    end
    if not pos then return nil, false end
    for _, t in ipairs(Map.TowersInRadius(Vector(pos.x, pos.y, 0), K.TOWER_ALIVE_R) or {}) do
        if Entity.GetTeamNum(t) ~= State.team and Entity.IsAlive(t) then return pos, true end
    end
    return pos, false
end

-- v0.1.246 (TINKER_TOWER_DEATH_DESIGN.md): resolve a tower position to its registry key
-- (the nearest static spot within TOWER_ALIVE_R). nil when no spot matches.
local function tower_key_near(pos)
    if not pos then return nil end
    local best, bd
    for _, t in ipairs(MapData.TOWERS or {}) do
        if t.pos then
            local dx, dy = t.pos[1] - pos.x, t.pos[2] - pos.y
            local d = dx * dx + dy * dy
            if d <= K.TOWER_ALIVE_R * K.TOWER_ALIVE_R and (not bd or d < bd) then
                bd, best = d, t.name .. "@" .. tostring(t.team)
            end
        end
    end
    return best
end

-- v0.1.201 (user directive, run-29): after the enemy mid T1 DROPS, lane positioning is LEASHED to
-- our foremost ALIVE mid tower: max K.T1DOWN_LEASH (3000 since v0.1.204 map-measured the post-T1 equilibrium; the old 1100 = tower range 700 + ~400 derivation is DEAD)
-- from it, for anything FORWARD of that tower. Run-29 sighting: a deep raid stand (depth 1672)
-- arrived at 148 mana and WALKED home through enemy ground; the fix is an EXCLUSION at the same
-- sites as the stairs line (covers / lane_go tripwire / step-in), RAIDS INCLUDED in the deep era -
-- the deep meeting is excluded so Plan jungles instead of walking/waiting deep (the user's "right
-- decision"). Pre-drop: inert (the lane phase stays untouched). Positions BEHIND the anchor tower
-- (retreats, holds at T2, own jungle) never bind - the leash is a forward cap, not a bubble.
-- Optional slop widens the radius for tripwire-style callers.
-- ALL-LANES v0.1.225: lane-parameterized (trigger = THAT lane's enemy T1; anchor = our alive towers
-- of that lane); radius shared = T1DOWN_LEASH (a calibration knob for the side lanes; cwhy=leash
-- names any miscalibration in the farm/swave trace).
local function lane_leash_ok(pos, slop, lane)
    lane = lane or K.HOME_LANE
    local _, t1alive = enemy_lane_t1(lane)
    if t1alive then return true end
    local anchor
    for _, nm in ipairs({ "tower1_" .. lane, "tower2_" .. lane, "tower3_" .. lane }) do
        for _, t in ipairs(MapData.TOWERS or {}) do
            if t.team == State.team and t.pos and t.name and t.name:find(nm, 1, true) then
                for _, e in ipairs(Map.TowersInRadius(Vector(t.pos[1], t.pos[2], 0), K.TOWER_ALIVE_R) or {}) do
                    if Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
                        anchor = { x = t.pos[1], y = t.pos[2] }; break
                    end
                end
            end
            if anchor then break end
        end
        if anchor then break end
    end
    if not anchor then return true end   -- no mid tower left: no anchor (base defense is not farm's problem)
    if stand_depth(pos) <= stand_depth(anchor) then return true end   -- behind the tower = home territory
    local dx, dy = pos.x - anchor.x, pos.y - anchor.y
    local r = K.T1DOWN_LEASH + (slop or 0)
    return dx * dx + dy * dy <= r * r
end

-- per-lane shove suppression (ALL-LANES v0.1.225): set on stuck stands / tether releases, consumed
-- by the lane's own dispatch gate only - no cross-lane poisoning (a stuck side stand must never
-- convert a due MID shove to recover).
local function suppress_shove(lane, untilT, why)
    lane = lane or K.HOME_LANE
    State.shoveSuppress[lane] = untilT
    -- v0.1.367 INSTRUMENT (log-only): NAME THE ARMING SITE. `shove_stuck` is ONE label over 17
    -- call sites and has been read as a defect for the life of this project. g370 logged 213
    -- shove_stuck rows, but those are DECIDE SAMPLES of a latch: they collapse to 24 episodes
    -- (1.52/min, 9th of 33 logs, corpus median 1.43), and 57.7% of them are the DESIGNED
    -- post-clear budget cooldown (the v0.1.197 guard that stops a 3rd W on a wave already paid
    -- for). The site the NAME derives from (keen landed on unwalkable ground) armed 0 times in
    -- g370 and exactly once in all 33 corpus logs.
    -- d.reason is deliberately NOT renamed: it is compared against the literal "shove_stuck" at
    -- three sites, so changing it would be BEHAVIOURAL. This line is the instrument instead -
    -- pair it with the decide that follows.
    logline(string.format("shove_suppress ln=%s why=%s for=%.1f", lane, why or "?", untilT - now()))
end
local function shove_suppressed(lane)
    return now() < (State.shoveSuppress[lane or K.HOME_LANE] or 0)
end

-- Risk v2 axis 1 inputs (task #11, the user POINT SYSTEM): for a lane position, the NEAREST static
-- enemy tier-1 spot (= the depth zero-line), whether THAT tower still stands, and how many of their
-- OTHER tier-1s do. Feeds Farm.DepthPoints at DECIDE time only (schedule exclusion via covers ->
-- no_safe_stand -> jungle) - NEVER a movement/landing veto (hard vetoes froze/idled the hero).
local function enemy_t1_points_info(pos)
    local best, bd, others_up, best_alive = nil, nil, 0, false
    for _, t in ipairs(MapData.TOWERS or {}) do
        if t.team ~= State.team and t.pos and t.name and t.name:find("tower1_", 1, true) then
            local alive = false
            for _, e in ipairs(Map.TowersInRadius(Vector(t.pos[1], t.pos[2], 0), K.TOWER_ALIVE_R) or {}) do
                if Entity.GetTeamNum(e) ~= State.team and Entity.IsAlive(e) then alive = true; break end
            end
            local dx, dy = t.pos[1] - pos.x, t.pos[2] - pos.y
            local d = dx * dx + dy * dy
            if not bd or d < bd then
                if best and best_alive then others_up = others_up + 1 end   -- the displaced nearest counts as "other"
                bd, best, best_alive = d, { x = t.pos[1], y = t.pos[2] }, alive
            elseif alive then
                others_up = others_up + 1
            end
        end
    end
    if not best then return nil end
    return { depth_past = stand_depth(pos) - stand_depth(best), line_alive = best_alive, others_up = others_up }
end

-- v0.1.94: enemy_risk_at scores DISTANCE - a single mid laner at trading range reads ~0.5-0.7, which
-- made Tinker FLEE a normal healthy 1v1 (wave move/engage abort) AND blocked safe_rearm so he stood
-- IDLE in ENGAGE (March on cd + an enemy near -> no rearm -> wait). Laning is a TRADE: a 1v1 + the odd
-- hit is normal, not a death. So the "leave the lane / don't rearm" call is COUNT + HP aware:
--   >=2 visible enemies near the point -> a gank -> flee;
--   1 visible -> a trade -> STAY unless HP fraction < LANE_TRADE_HP (then a burst could kill);
--   0 visible -> keep the COR-1 fogged-proximity gate (don't keen into a fog gank).
-- Under an enemy tower always flees. LANE paths only (shove gate, wave move/engage abort, safe_rearm);
-- camps keep plain enemy_risk_at (jungle context).
local can_bail   -- v0.1.317 escape-gate; ASSIGNED after can_blink (below - lane_unsafe precedes the blink primitives). Forward-declared here.
local function lane_unsafe(pos, opts)
    local p = Vector(pos.x, pos.y, 0)
    -- v0.1.359 THE EARLY-RETURN ARM of the instrument. g358's analyzer A2 ("the instrument
    -- survived") FAILED on a healthy build: it reads a silence gap as unexplained when a decide ran
    -- inside it and nothing was logged, but FOUR of lane_unsafe's five returns fire BEFORE the nv==0
    -- fall-through that carries the logline, so a commit-gated call can legitimately log nothing.
    -- enH is therefore an INCOMPLETE proxy - the tower gate below runs before any enemy counting, so
    -- it produces silence at enH=0 too - and no analyzer-only refinement can close that. The hero
    -- has to NAME the branch, which is br=. ONE emitter, ONE logline, ONE throttle: every return
    -- routes through here, so "commit-gated and silent" now means only "the producer never called",
    -- which is the one thing A2 actually wants to detect. Closure is built per call (cheaper than the
    -- Vector one line up) and the commit guard lives INSIDE it, so the 10 non-commit callers cannot
    -- emit by a call site forgetting the test; its result is discarded at every site.
    local function cr(br, v1, r0, r1, chg, ne, nh)
        if not (opts and opts.commit) then return end
        -- SENTINEL -1 = "not computed on this branch", never omitted: the analyzer asserts a FIXED
        -- key set, so a missing key is a parse failure while a missing VALUE must stay readable.
        -- Unambiguous because every real value here is non-negative (risks and g are >= 0,
        -- ne is an edge distance floored at 0, nh a count, chg/v1 are 0/1). The early paths do NOT
        -- get these back-filled on purpose: enemy_risk_at/NearestEnemyEdge/enemy_snapshot are work
        -- the branch did not do, and running them for a log would put new computation on the gate
        -- path (the exact class of edit that made v0.1.357 unshippable).
        r0, r1, chg, ne, nh = r0 or -1, r1 or -1, chg or -1, ne or -1, nh or -1
        local site, w = opts.site or "?", opts.commit    -- w == the fall-through's (opts.commit or 0): we only get here when commit is set, and commit==0 (the kill switch) is truthy in Lua
        State.crT = State.crT or {}
        -- THROTTLE KEY: the widen path keeps its shipped key EXACTLY (site, + "!" on a verdict flip),
        -- so the calibrated line is bit-identical to v0.1.358. Early returns take their OWN key,
        -- site.."/"..br, deliberately NOT the site key: sharing it would let a persistent tower
        -- refusal eat that site's 10s slot and starve the widen heartbeat, i.e. the fix would
        -- manufacture the same silence it exists to explain, and a site alternating tower/widen would
        -- show whichever branch happened to win the window. Per-branch keys make silence legible in
        -- the only way A2 can use: a branch that never logs never ran. Volume is bounded at 5 keys x
        -- 3 sites per 10s (mid, top, bot - g358 logged 45/23/23), and only 1-2 branches are live
        -- per site in practice. No flip suffix on the
        -- early keys: chg is n/a there (nothing was widened), so there is no flip to detect.
        local key, iv = site .. "/" .. br, 10.0
        if br == "widen" then key, iv = site .. ((chg == 1) and "!" or ""), (chg == 1) and 2.0 or 10.0 end
        if Escape.DiagGate(State.crT, key, now(), iv) then
            -- ne/nh are computed HERE, INSIDE the throttle, never as call arguments. Lua evaluates
            -- arguments before entering the callee, so passing NearestEnemyEdge(...) into cr() ran
            -- it on EVERY commit-gated call instead of once per window: measured 100 calls against
            -- 5 over a 50s replica. It is pure and its result was discarded, so it was never a
            -- verdict change, but putting unthrottled O(#heroes) work with a sqrt per hero and a
            -- table allocation on the gate path is the exact class of edit that made v0.1.357
            -- unshippable. The widen site passes the SNAPSHOT in this slot and it is resolved here.
            if type(ne) == "table" then
                -- v0.1.412: age_cap added (the v0.1.410 flip armed the shrink term; ne= p50
                -- collapsed ~1400 -> 0 in g404/g405 as stale ghosts zeroed the edge). Log-only
                -- field, but it is THE commit-risk payload measurement, so it stays honest.
                ne, nh = Escape.NearestEnemyEdge(ne, p, { fog_ms = K.FOG_MS, age_cap = K.FOG_AGE_CAP }), #(ne.heroes or {})
            end
            logline(string.format(
                -- ap/wmax are %g, NOT the design's %d: string.format runs HERE, at the call site,
                -- before logline's pcall (:73-77) and inside a decide that OnUpdateEx does not
                -- pcall, so a FRACTIONAL tuning constant (62.5 on the 50->75->100 ladder) throws
                -- "number has no integer representation" every decide = the v0.1.247 stuck-in-DECIDE
                -- shape, from a config edit alone. %g renders every integer identically (50, 2000),
                -- prints no space, and keeps the exact value for the stale-deploy check. The -1
                -- sentinels are integers, so they are safe under %d/%.0f for the same reason.
                "commit_risk t=%.1f site=%s br=%s exp=%.1f st=%.1f wd=%.0f wcap=%d ap=%g wmax=%g " ..
                "r0=%.2f r1=%.2f g=%.2f v1=%d chg=%d ne=%.0f nh=%d",
                now(), site, br, (opts.travel or 0) + K.COMMIT_STAND_S, K.COMMIT_STAND_S, w,
                (w >= K.COMMIT_WIDEN_MAX) and 1 or 0, K.COMMIT_APPROACH_SPEED, K.COMMIT_WIDEN_MAX,
                r0, r1, K.SHOVE_SAFE_RISK, v1, chg, ne, nh))
        end
    end
    if enemy_tower_risk(p) >= K.SHOVE_SAFE_RISK then
        cr("tower", 1)                              -- BEFORE any enemy counting: this is the branch that fakes a dead gate at enH=0
        return true
    end
    -- CLEANUP(review#2): depth is now MEASUREMENT-only here (logged via srisk + ft.depth). The deep
    -- decision moved to the guard (rule 2): T1 dead + deep -> keen-to-creep DIVE if Keen L2 + safe, else
    -- jungle. A hard lane_unsafe depth veto would recover BEFORE the guard, blocking the dive, so it was
    -- removed. (The crash-clamp already keeps a T1-alive stand in front of the tower.)
    local snap = State.fog or enemy_snapshot()
    -- v0.1.317 fog-threat (reachability + OPT-IN escape-gate): a FOGGED enemy augments the
    -- gank count only when FRESH + its capped disc actually reaches p (Escape.ReachableFog);
    -- and a 1-visible + reachable-fog "2-man" is tolerated when opts.bail is set AND Tinker
    -- can BAIL (blink|keen + HP). Replaces the v0.1.157/.158 fixed GANK_FOG_REACH augmentation
    -- that aborted full-HP 1v1 mids on any stale fog blip (the .316 jungle-drift). The
    -- escape-gate is OPT-IN (shove sites only) so RAID callers (raid_safe/keen-landing) stay
    -- strict until arc 2 gives them a blink-only bail (a raid spends keen). 2 VISIBLE always
    -- bails; the nv==1 pure trade and nv==0 fogged-proximity branches are unchanged.
    local nv = 0
    for _, h in ipairs(snap.heroes or {}) do
        if h.pos and h.visible then
            local dx, dy = h.pos.x - p.x, h.pos.y - p.y
            if math.sqrt(dx * dx + dy * dy) <= K.GANK_RADIUS then nv = nv + 1 end
        end
    end
    if nv >= 2 then                                 -- 2 VISIBLE = committed gank, always bail
        cr("nv2", 1)                                -- nv is not a field: br=nv2 IS nv>=2, br=fog is nv==1+rf>=1, br=trade is nv==1+rf==0
        return true
    end
    local rf = Escape.ReachableFog(snap, { x = p.x, y = p.y },
        { radius = K.GANK_RADIUS, reach_cap = K.FOG_REACH_CAP, fresh_s = K.FOG_FRESH_S })
    if nv >= 1 and nv + rf >= 2 then                -- 1 visible + a REACHABLE fresh fog = uncertain 2-man
        local bail = (opts and opts.bail) and can_bail()
        if (opts and opts.bail) and now() - (State.fogGateLogT or -9) > 2 then
            State.fogGateLogT = now()
            logline(string.format("fog_gate nv=%d rf=%d bail=%s -> %s", nv, rf,
                tostring(bail), bail and "shove" or "abort"))
        end
        cr("fog", bail and 0 or 1)                  -- v1 mirrors `not bail`; can_bail() is NOT re-run, the latched local is read
        return not bail                             -- opt-in + healthy + escape up -> shove through
    end
    if nv == 1 then                                 -- pure 1v1 trade (no reachable fog) - unchanged
        local h0 = State.hero
        local hpf = (Entity.GetHealth(h0) or 1) / math.max(1, Entity.GetMaxHealth(h0) or 1)
        cr("trade", (hpf < K.LANE_TRADE_HP) and 1 or 0)   -- pure re-read of two numbers already in hand, no HP re-fetch
        return hpf < K.LANE_TRADE_HP
    end
    -- 0 visible: fogged-proximity COR-1 gate. COMMIT RISK v2: this fall-through is reachable IFF
    -- nv == 0 (independent of rf), which is exactly the g356 shape at both deaths, so opts.commit
    -- from the shove producers lands precisely where the defect is. The visible-count branches
    -- above stay instantaneous on purpose: GANK_RADIUS 1000 < RISK_RADIUS 1400, so they only fire
    -- when an enemy is already inside the un-widened radius. Every other caller passes no commit
    -- and reads bit-identically to before.
    local w = (opts and opts.commit) or 0
    local r1 = enemy_risk_at(p, w)
    local unsafe = r1 >= K.SHOVE_SAFE_RISK
    -- The instrument (design section 6). A silent gate reads exactly like a dead one, which is how
    -- four arcs on this project closed negative. NO OnDraw guard, deliberately: all 12 lane_unsafe
    -- callers were enumerated and none is a draw function (draw_pair_debug calls enemy_risk_at
    -- direct, un-widened), so the latch that stuck true for a whole session in v0.1.357 has nothing
    -- to guard. Throttle key is PER SITE (+ "!" on a verdict flip) so mid and side cannot starve
    -- each other and a flip can never be throttled out by that site's own heartbeats; heartbeats at
    -- 10s are MANDATORY because with flip-only logging an empty log means both "correctly inert"
    -- and "dead", and this ships expecting almost no flips. ne= is the payload: FogProximityRisk
    -- returns exactly 0 past its radius, so r1=0.00 alone cannot tell "widen too small" from
    -- "nobody there" - that censored 45% of g356's destination reads and forced the last
    -- calibration to quote a strict worst case instead of a distribution.
    -- v0.1.359: the emit MOVED into cr (top of the function) so the four early returns above share
    -- it; this guard, the r0/chg work it wraps and the key/interval it produces are unchanged, so a
    -- br=widen line is byte-identical to a v0.1.358 line except for the added br= field. r0/ne stay
    -- INSIDE the guard: enemy_risk_at and NearestEnemyEdge must not run for the 10 non-commit callers.
    if opts and opts.commit then
        local r0 = enemy_risk_at(p)                  -- same function, not a near-twin: keeps the comparison like-for-like
        local chg = unsafe ~= (r0 >= K.SHOVE_SAFE_RISK)
        -- snap goes in the ne slot ON PURPOSE: cr resolves it to a distance INSIDE the throttle
        -- (p is the normalized Vector; the lib reads .x/.y componentwise, never :Distance, v0.1.247).
        cr("widen", unsafe and 1 or 0, r0, r1, chg and 1 or 0, snap)
    end
    return unsafe
end

-- REBUILD: clear of EVERY alive enemy tower's attack range + a real margin = no tower damage AND no
-- barely-outside anxiety. note 1 / option A (v0.1.159): the old risk<SHOVE_SAFE_RISK gate stopped the
-- Map.Nav.SafeDest clamp at ~800 from tower center (attack range 700 + the taper edge), which put stands
-- 100u outside the tower 3+ times a game. Now a stand needs ATTACK_RANGE + TOWER_SAFE_MARGIN (1000);
-- March reach (1200) still covers 200 past the tower, so the tower-border W-farm is intact. STRICTER
-- than the live abort (lane_unsafe trips ~975) is the safe direction of the v0.1.148 consistency rule:
-- every stand tower_safe accepts, lane_unsafe accepts too (the old bug was the reverse band).
local function tower_safe(pos)
    if not pos then return false end
    local rr = K.TOWER_ATTACK_RANGE + K.TOWER_SAFE_MARGIN
    local p = Vector(pos.x, pos.y, 0)
    for _, t in ipairs(Map.TowersInRadius(p, rr + 100) or {}) do
        if Entity.GetTeamNum(t) ~= State.team and Entity.IsAlive(t) and origin(t):Distance(p) < rr then
            return false
        end
    end
    return true
end

-- ONE lane-position predicate for the movement/stand/landing chokepoints. DEPTH VETOES REMOVED
-- (user directive 2026-07-03, run-12 evidence: 29 of 33 idle decides were no_safe_stand - the
-- v0.1.164 frontier cap + v0.1.168 T1-line-without-L2 gate turned every deep meeting into dead
-- time instead of farm; "stop vetoing how far it can go in lane - it goes as far as it SHOULD").
-- What remains owns each concern: tower_safe = don't stand in tower fire (kept here, not a
-- distance rule); the TETHER owns WHEN he is deep (arrival-timed visits, waits at anchors);
-- lane_unsafe/PathRisk/gank own enemies; the none-idle frontier retreat owns never-IDLE-deep.
-- The "when it SHOULDN'T go" question belongs to the Risk v2 POINT SYSTEM (task #11 direction:
-- cumulative depth points past the dead-T1 position, Keen shaves points, thresholds gate).
-- THE WALK-PATH CENSUS (v0.1.192) found the four walk producers; v0.1.193 (user, run-23) moved
-- the STAIRS line OFF them: clamping movement/stands at the line was a hard positional veto -
-- it parked the hero AT the line for 22-25s waits (the exact freeze the point-system doctrine
-- forbids). The line is now an EXCLUSION input: safe_stand_for composes the NATURAL stand and
-- reports covers=false when that stand sits past WALK_DEPTH_MAX (non-raid), so Lane.Schedule.Plan
-- routes the wave to jungle (no_safe_stand / gone_by_arrival). Movement itself is never
-- depth-clamped again - a committed stand is always legal or the commit never happened.
-- (lane_pos_ok deleted at v0.1.193: with the depth term gone it was a tower_safe alias.)

-- Rearm only where it is SAFE (Note 3): never channel Rearm into a gank/under-tower, but a 1v1 trade
-- is fine (a blanket enemy-proximity gate left him idle between Marches in lane). lane_unsafe gates it.
local function safe_rearm()
    if lane_unsafe(origin(State.hero)) then return false end
    return try_rearm()
end

-- ── blink dagger (escape + travel) ───────────────────────────────────────────
-- Hero-agnostic via NPC.GetItem: every path no-ops if the player did not buy a blink.
local function blink_item() return NPC.GetItem(State.hero, "item_blink", true) end

-- Blink-broken gate: the dagger is disabled ~3s after enemy damage. Damage.GetRecentDamage
-- is the proven idiom (Lina recent_damage); pcall-guarded -> not-broken if the API is absent.
local function blink_broken()
    if not (Damage and Damage.GetRecentDamage) then return false end
    local ok, d = pcall(Damage.GetRecentDamage, State.hero, 3.0)
    return ok and type(d) == "number" and d > 0
end

-- kind = "escape" | "travel": menu on + item present/ready + not broken + not channeling + debounce.
local function can_blink(kind)
    local sw = (kind == "travel") and State.menu.blinkTravel or State.menu.blinkEscape
    if not (sw and sw:Get()) then return false end
    local it = blink_item()
    if not (it and ready(it)) then return false end
    if blink_broken() or is_channeling() then return false end
    if now() - (State.lastBlinkT or -99) < K.BLINK_DEBOUNCE then return false end
    return true
end

-- v0.1.317 escape-gate: Tinker tolerates a REACHABLE fog threat (the fog-uncertain 2-man,
-- shove sites only via opts.bail) only if he can bail - blink OR keen ready AND not
-- burstable (HP >= the trade bar). can_blink already gates item+cd+blink-broken+channel
-- (a damaged blink is NOT a bail). RAID callers do NOT pass opts.bail: a raid spends keen,
-- so its bail is blink-only (arc 2). Assigns the forward-declared local above lane_unsafe.
can_bail = function()
    local h = State.hero
    local hpf = (Entity.GetHealth(h) or 1) / math.max(1, Entity.GetMaxHealth(h) or 1)
    if hpf < K.LANE_TRADE_HP then return false end
    return can_blink("bail") or ready(State.keen)
end

-- v0.1.318 raid escape-gate: after a keen-DIVE keen is SPENT, so a raid's bail is
-- blink-only (+ HP bar). Distinct from can_bail (which also counts keen).
local function can_bail_raid()
    local h = State.hero
    local hpf = (Entity.GetHealth(h) or 1) / math.max(1, Entity.GetMaxHealth(h) or 1)
    return hpf >= K.LANE_TRADE_HP and can_blink("bail")
end

-- v0.1.318 E3a PROXIMITY-REFIT (arc 2): the .313 raid veto (global missN, removed
-- in .316) re-gated as PROXIMITY-aware - a raid to `dest` is vetoed only when a
-- FRESH fogged enemy can actually reach the landing (Escape.ReachableFog) AND
-- Tinker can NOT blink-bail. Closes the run-114 keen-into-fogged-enemies death
-- without the global veto's predicate-hit-rate crippling. Reuses the lane fog
-- constants to start - a deep dive may want a wider reach; watch keen-into-fog
-- deaths and calibrate. Throttled raid_gate log.
local function raid_gank_ok(dest)
    local rf = Escape.ReachableFog(State.fog or enemy_snapshot(), dest,
        { radius = K.GANK_RADIUS, reach_cap = K.FOG_REACH_CAP, fresh_s = K.FOG_FRESH_S })
    if rf == 0 then return true end
    local bail = can_bail_raid()
    if now() - (State.raidGateLogT or -9) > 2 then
        State.raidGateLogT = now()
        logline(string.format("raid_gate rf=%d bail=%s -> %s", rf, tostring(bail), bail and "ok" or "veto"))
    end
    return bail
end

-- Cast blink toward dest, clamped into range so it FIRES (a cast beyond cast_range is issued-not-fired).
-- Blink is instantaneous so cast-verify is light: the caller logs + debounces; a mis-fire degrades to
-- the walk/keen fallback next tick. Returns true if issued.
local function do_blink(dest)
    local it = blink_item(); if not (it and dest) then return false end
    local me = origin(State.hero)
    local dx, dy = dest.x - me.x, dest.y - me.y
    local d = math.sqrt(dx * dx + dy * dy)
    local maxr = K.BLINK_RANGE - 50
    local tgt = (d > maxr) and Vector(me.x + dx / d * maxr, me.y + dy / d * maxr, me.z) or Vector(dest.x, dest.y, me.z)
    if cast_pos(it, tgt) then State.lastBlinkT = now(); return true end
    return false
end

-- Proactive escape blink: flee to the safest walkable spot within blink clamp BEFORE the burst
-- (damage_cooldown 3 makes it useless once hit). Primary escape; the caller falls back to walk/keen.
-- Tree-blink (glue rebuild item 5): prefer hiding in the densest standing-tree cluster away from
-- the nearest threat (Map.Nav.TreeHideSpot on Map.TreesInRadius) - breaks vision AND pathing; the open
-- safest-spot pick stays the fallback when no cluster qualifies.
local function try_escape_blink()
    -- v0.1.404 census (the v0.1.214 blink_skip lesson, never applied to this twin): this
    -- function logged ONLY on success, so every refusal was invisible and the 0 firings across
    -- 25 logs could not be told apart from a broken gate. Distinct token `esc_skip`, NOT
    -- `blink_skip` (that is the TRAVEL census and mixing them would corrupt both populations)
    -- and not `blink_escape*` (that is the SUCCESS line). Same 2.0s throttle, own stamp.
    local function skip(why)
        if now() - (State.lastEscSkipLog or -99) > 2.0 then
            State.lastEscSkipLog = now()
            logline("esc_skip why=" .. why)
        end
        return false
    end
    if not can_blink("escape") then
        local it = blink_item()
        -- same order and labels as the travel census so the two are comparable. NOTE
        -- broken_damage cannot currently fire: lib.damage is not required by this hero, so
        -- blink_broken() is permanently false (bridge Q2). The arm is kept so it starts
        -- working the moment Q2 is fixed.
        -- WHY THE SECOND is_channeling() CALL IS SAFE (can_blink already made one): both of its
        -- mutations sit behind `if State.keenPending`/`if State.rearmPending` guards, so once the
        -- first call has cleared a latch the second skips that block entirely and returns the
        -- same value. Idempotent within a tick. The labels are right for the same reason: true
        -- here means can_blink refused ON the channel, false means it fell through to debounce.
        return skip((not (State.menu.blinkEscape and State.menu.blinkEscape:Get())) and "menu_off"
            or (not it) and "no_item"
            or (not ready(it)) and "item_cd"
            or blink_broken() and "broken_damage"
            or is_channeling() and "channeling"
            or "debounce")
    end
    State.fog = State.fog or enemy_snapshot()
    local me = origin(State.hero)
    local threat, bestd
    for _, h in ipairs((State.fog and State.fog.heroes) or {}) do
        if h.pos then
            local d = me:Distance(Vector(h.pos.x, h.pos.y, me.z))
            if not bestd or d < bestd then bestd, threat = d, { x = h.pos.x, y = h.pos.y } end
        end
    end
    -- v0.1.201 (run-29 t~796 "random blink on outpost"): NO enemy hero known near = nothing a
    -- 200u tree hop escapes (the panic was NEUTRAL damage at the ancient pair; the blink burned
    -- the dagger, hid nowhere, and the keen-home right after covers the actual escape). Blink
    -- only when a hero threat is plausibly in reach.
    if not threat then return skip("no_threat") end
    if bestd > K.RISK_RADIUS then return skip("threat_far") end
    local trees = {}
    for _, t in ipairs(Map.TreesInRadius(me, K.BLINK_CLAMP) or {}) do
        local tp = Entity.GetAbsOrigin(t)
        if tp then trees[#trees + 1] = { x = tp.x, y = tp.y } end
    end
    local hide = Map.Nav.TreeHideSpot(trees, { x = me.x, y = me.y }, threat, { blink_max = K.BLINK_CLAMP })
    if hide then
        hide = Map.SnapWalkable(hide, { x = me.x, y = me.y })       -- nearest GridNav-walkable point to the
        -- cluster. It is TREE-BLIND (GridNav.IsTraversable does not flag trees, see KEEN_TREE_CLEAR), so this
        -- can land INSIDE the grove. That is the intent here, the grove is the vision cover we are blinking to;
        -- it is the opposite of clear_landing, which needs tree-FREE ground and tests trees explicitly.
        if do_blink(Vector(hide.x, hide.y, me.z)) then
            logline(string.format("blink_escape tree dest=(%.0f,%.0f)", hide.x, hide.y))
            return true
        end
    end
    local dest = Escape.SafestSpotNear(State.hero, K.BLINK_CLAMP, { snapshot = State.fog, now = now })
    if dest and do_blink(dest) then
        logline(string.format("blink_escape dest=(%.0f,%.0f)", dest.x, dest.y))
        return true
    end
    -- both pickers declined. trees= names whether the cluster search even had candidates, which
    -- separates a thin forest from a picker that refuses a forest it can see.
    return skip((not hide) and string.format("no_cluster trees=%d", #trees)
        or (not dest) and "no_spot"
        or "cast_failed")
end

-- Travel blink: close a medium gap to the farm stand faster than walking, when SAFE (reserve the
-- dagger for escape if a threat is near). Blinks STRAIGHT at the aim, clamped into range (Escape.BlinkInLanding is NOT used; see the picker note below).
local function try_travel_blink(aim)
    -- v0.1.214 census instrument (the offlane-camp blink survived FOUR fixes because the failing
    -- gate was never NAMED in the log): every refusal logs blink_skip why=, throttled to 1/2s.
    local function skip(why)
        if now() - (State.lastBlinkSkipLog or -99) > 2.0 then
            State.lastBlinkSkipLog = now()
            logline("blink_skip why=" .. why)
        end
        return false
    end
    if not aim then return false end
    -- v0.1.216 (user: "checked, blink was NOT on cooldown"): cd_or_off conflated five gates; name
    -- the real one. blink_broken (damage in the last 3s - an ENGINE rule, invisible on the icon)
    -- is the expected culprit on camp legs: the neutrals hit him exactly as he leaves a camp.
    if not can_blink("travel") then
        local it = blink_item()
        local why = (not (State.menu.blinkTravel and State.menu.blinkTravel:Get())) and "menu_off"
            or (not it) and "no_item"
            or (not ready(it)) and "item_cd"
            or blink_broken() and "broken_damage"
            or is_channeling() and "channeling"
            or "debounce"
        return skip(why)
    end
    -- v0.1.213 (run-36, user: "farm side camp on offlane is not blinking into position", the
    -- 3-patch one): the hero-side gate was REARM_SAFE_RISK (0.20) - a rearm-exposure bar, not the
    -- blink doctrine. Mid-game ambient fog risk (enemies missing a few seconds anywhere near the
    -- offlane jungle) reads 0.2-0.3 CONSTANTLY, so offlane camp residuals never blinked (run-36:
    -- keened residual 1284-2242 then WALKED, 4+ trips). The doctrine bar = SHOVE_SAFE_RISK (0.35),
    -- the same fog-aware level every other jump-risk gate uses (landing, raid_safe, shove).
    if enemy_risk_at(origin(State.hero)) >= K.SHOVE_SAFE_RISK then return skip("risk_me") end   -- a real jump read: keep the dagger for the escape
    local me = origin(State.hero)
    local d = me:Distance(aim)
    -- v0.1.205 (user: "we are under-using blink... shaving even 3 seconds can mean one more camp"):
    -- the far cap is GONE - a dest beyond blink range gets a max-range hop TOWARD it (the landing
    -- checks below run on the clamped point) and the walk continues from there. Only the too-short
    -- floor remains (a <800u gap is ~2.7s walk = the user's "even 3 seconds" bar). The ONLY veto is
    -- jump risk: the fog-aware risk gates here + on the landing (Eureka refunds the cd fast, the
    -- dagger is not precious when no player can jump us).
    if d < K.BLINK_TRAVEL_MIN then return false end
    -- Blink STRAIGHT at the stand (do_blink clamps into range so it fires). The escape picker
    -- Escape.BlinkInLanding optimizes for SAFETY, not the destination, so it landed off-target
    -- (sometimes the WRONG direction) for a travel hop; we are already gated safe (enemy_risk <
    -- SHOVE_SAFE_RISK above), so a straight blink to the chosen (walkable) farm stand is right.
    local dest = Vector(aim.x, aim.y, me.z)
    -- Note 4: check the LANDING (clamped like do_blink), not just our current pos. A travel-blink
    -- is a committed teleport with no en-route abort, so it must not land UNDER the enemy tower
    -- (enemy_tower_risk) or into enemies (enemy_risk_at) or on unwalkable ground. Same gate as the
    -- keen landing (v0.1.85/86). If unsafe, skip the blink -> the caller keens/walks (safety-gated).
    local dx, dy = dest.x - me.x, dest.y - me.y
    local dl = math.sqrt(dx * dx + dy * dy)
    local maxr = K.BLINK_RANGE - 50
    local land = (dl > maxr) and { x = me.x + dx / dl * maxr, y = me.y + dy / dl * maxr }
                              or { x = dest.x, y = dest.y }
    if Map.Walkable and Map.GroundPos then
        local ok, walk = pcall(function() return Map.Walkable(Map.GroundPos(land.x, land.y)) end)
        if ok and not walk then
            -- v0.1.217 (user: the offlane trip comes FROM THE FOUNTAIN a couple of times - NOT
            -- broken_damage; the 8x land_unwalkable is the real one: the fixed anchor->stand line
            -- clips the TREELINE at the clamp point, deterministically, every trip): SNAP the
            -- landing back toward the hero onto walkable ground (castable by construction - a
            -- slightly shorter hop + a short walk) instead of refusing the whole blink.
            land = Map.SnapWalkable(land, { x = me.x, y = me.y })
            local ok2, walk2 = pcall(function() return Map.Walkable(Map.GroundPos(land.x, land.y)) end)
            if not (ok2 and walk2) then return skip("land_unwalkable") end
        end
    end
    -- v0.1.214 (run-37, the deterministic offlane-camp case: the clamped landing toward the dire
    -- bot camps passes near the LIVE enemy tower -> the old tower term refused every blink there):
    -- the WALK crosses the exact same ground, and a tower does not JUMP - blinking past it is
    -- strictly LESS exposure time. The travel landing gate is PLAYER risk only; tower safety is
    -- owned by the movement clamp + the tower-safe stand composition, as everywhere else.
    if enemy_risk_at(Vector(land.x, land.y, 0)) >= K.KEEN_LAND_SAFE_RISK then
        return skip("land_risk")
    end
    -- v0.1.217: blink to the CHECKED landing (the snapped point when snapping happened; identical
    -- to do_blink's own clamp otherwise) - the point we validated is the point we land on.
    if do_blink(Vector(land.x, land.y, me.z)) then
        logline(string.format("blink_travel d=%.0f dest=(%.0f,%.0f)", d, land.x, land.y))
        return true
    end
    return false
end

-- ── ARC E2: Defense phase (TINKER_DEFENSE_WIRING_DESIGN.md) ──────────────────
-- SAVE_CFG: cast primitives + policy hooks for the hero-agnostic item save
-- bodies (lib/item_saves.lua is the contract). Lina-specific hooks are LEFT
-- ABSENT (nil) on purpose; the lib degrades safely on each:
--   armed_cp_t / armed_threat_mod: cyclone launch-in-vain gate inert (fires immediately)
--   cyclone_target:               WW/Eul always self-cast, never target a harasser
--   queue_post_move:              no during-airborne WW move
--   self_push:                    Force/Pike fall back to plain self-cast
--   pike_enemy_range:             0 -> Pike never enemy-targets, self-push only
--   pike_after_target_fire:       no reissue bookkeeping (needs pike hook anyway)
--   lotus_gate:                   default 0.85 HP-fraction gate in the lib
-- LIVE since Task 3: SAVE_FIRE feeds defense_dispatcher, fired from OnModifierCreate's threat-on-self branch.
local function def_uname(u)
    local ok, n = pcall(function() return NPC.GetUnitName and NPC.GetUnitName(u) end)
    return (ok and n) or "?"
end
-- Cast primitives route through issue_def (the UNTHROTTLED PrepareUnitOrders
-- core next to issue()): defense orders must not lose to the farm-order rate
-- guard. See the issue_def comment for the .234 order-swallow rationale.
local SAVE_CFG = {
    self_npc        = function() return State.hero end,
    item            = function(n) if not State.hero then return nil end return NPC.GetItem(State.hero, n, true) end,
    issue_self      = function(intent, it) return issue_def(UO.DOTA_UNIT_ORDER_CAST_TARGET, it, State.hero) end,
    issue_target    = function(intent, it, t) return issue_def(UO.DOTA_UNIT_ORDER_CAST_TARGET, it, t) end,
    issue_position  = function(intent, it, p) return issue_def(UO.DOTA_UNIT_ORDER_CAST_POSITION, it, nil, p) end,
    issue_no_target = function(intent, it) return issue_def(UO.DOTA_UNIT_ORDER_CAST_NO_TARGET, it) end,
    tlog            = tlog,
    uname           = def_uname,
    dist_to         = function(u)
        local okm, me = pcall(origin, State.hero)
        local oku, p  = pcall(origin, u)
        if not (okm and me and oku and p) then return 1e9 end
        return me:Distance(p)
    end,
    compute_safe_dest = function(caster, dist)
        -- Tinker's own escape geometry (NOT Lina's): full push distance away
        -- from the caster, Map.Nav.SafeDest stepping BACK toward the hero (retreat
        -- = -dir: shorter pushes stay in cast range and still away from the
        -- caster; stepping outward would exceed range and get engine-clamped
        -- onto the unsafe point). SafeDest's max-back degraded case is still
        -- unsafe and indistinguishable via its returns, so the RETURNED point
        -- is re-checked; tower-unsafe -> nil, nil (the save skips). Returns
        -- (escape_dir, landing) -- the item_saves blink builder reads the
        -- SECOND return, matching Escape.ComputeSafeDest's shape.
        local okm, me = pcall(origin, State.hero)
        if not (okm and me) then return nil, nil end
        local ok, cp = pcall(origin, caster)
        local dirx, diry = 0, 0
        if ok and cp then
            local dx, dy = me.x - cp.x, me.y - cp.y
            local dl = math.sqrt(dx * dx + dy * dy)
            if dl > 1 then dirx, diry = dx / dl, dy / dl end
        end
        if dirx == 0 and diry == 0 then return nil, nil end   -- no caster / on top of us: no honest direction
        local d = dist or 600
        -- max_steps caps the walk-back BEFORE the hero: steps at/past floor(d/100)
        -- land on/behind me toward the caster (Task 2 review); the capped degraded
        -- point then fails the tower_safe re-check below and the save skips cleanly.
        local pt = Map.Nav.SafeDest({ x = me.x + dirx * d, y = me.y + diry * d },
                                { x = -dirx, y = -diry }, tower_safe,
                                { max_steps = math.floor(d / 100) - 1 })
        if not (pt and tower_safe(pt)) then return nil, nil end
        return Vector(dirx, diry, 0), Vector(pt.x, pt.y, 0)
    end,
    recent_damage   = function(s)
        if Damage and Damage.GetRecentDamage then
            local ok, d = pcall(Damage.GetRecentDamage, State.hero, s)
            if ok and type(d) == "number" then return d end
        end
        return 0
    end,
}
local SAVE_FIRE = ItemSaves.build(SAVE_CFG)   -- fresh table per build; no merge needed

local function save_is_ready(save_name)
    -- SAVE_FIRE key -> real item name (the one alias in the roster), then the
    -- file's verified castable idiom (CanBeExecuted==-1, see the bottle code).
    if not State.hero then return false end
    local n = (save_name == "item_ethereal_blade_self") and "item_ethereal_blade" or save_name
    local it = NPC.GetItem(State.hero, n, true)
    return (it and ready(it)) and true or false
end
-- v0.1.356: feeds lib/defense's not_owned vs not_ready split. Same lookup as save_is_ready
-- minus the cooldown test, so "the item is not in the inventory" stops masquerading as "the
-- item is on cooldown" in every post-mortem.
local function save_is_owned(save_name)
    if not State.hero then return false end
    local n = (save_name == "item_ethereal_blade_self") and "item_ethereal_blade" or save_name
    return NPC.GetItem(State.hero, n, true) and true or false
end
local function self_can_cast_abilities()
    -- Tinker registers no ability saves (ability_saves = {}), so this is
    -- currently never consulted per save; kept for the cfg contract shape.
    local me = State.hero
    if not me then return false end
    if NPC.IsSilenced and NPC.IsSilenced(me) then return false end
    return true
end

-- Terminal fallback chain for threats with no override / category resolution.
-- Item-only (hero-agnostic); same list as Lina's CH.DEFAULT_SAVE_CHAIN.
local DEFAULT_SAVE_CHAIN = {
    "item_wind_waker", "item_cyclone", "item_lotus_orb", "item_manta",
    "item_glimmer_cape", "item_invis_sword", "item_silver_edge",
    "item_hurricane_pike", "item_force_staff",
    "item_black_king_bar",
}

local defense_dispatcher = Defense.New {
    anim_save_overrides     = {},            -- anim arming = E3+ territory
    hero_save_overrides     = {},            -- no Tinker per-mod overrides yet
    -- ResolveSaveOrder indexes these three unconditionally (crash on nil):
    -- raw lib tables, Tinker patches nothing (Lina passes patched copies).
    patched_recommended     = ThreatData.RECOMMENDED_SAVES,
    category_chains         = ThreatData.CATEGORY_CHAINS,
    default_chain           = DEFAULT_SAVE_CHAIN,
    save_fire               = SAVE_FIRE,
    ability_saves           = {},            -- Tinker has no self-save ability
    self_displacement_saves = { item_force_staff = true, item_hurricane_pike = true },
    save_is_ready           = save_is_ready,
    save_is_owned           = save_is_owned,   -- v0.1.356: splits not_owned out of not_ready
    self_can_cast_abilities = self_can_cast_abilities,
    TD                      = ThreatData,
    threats_on_self         = ThreatData.THREATS_ON_SELF,
    reaction_window         = 0.1,           -- Lina's proven value (K.LAYER2_REACTION_WINDOW); the plan's 1.5 would throttle multi-threat responses
    reserve_skip_floor      = -20,           -- Lina's value (state.RESERVE_SKIP_FLOOR)
    concurrent_penalty      = 15,            -- Lina's value (state.CONCURRENT_PENALTY)
    throttle_state          = State,         -- lib lazily writes last_save_t onto it
    armed_threats           = {},            -- anim arming = E3+ territory
    now                     = now,
    tlog                    = tlog,
    tlog_level              = v_level,       -- lets ResolveSaveOrder skip its level-3 diag alloc
    dist_to                 = SAVE_CFG.dist_to,
    defense_enabled         = function()
        return (State.menu and State.menu.defenseOn and State.menu.defenseOn:Get()) and true or false
    end,
    canonicalize_mod        = ThreatData.CanonicalMod,
    eta_resolver            = {},            -- no per-mod resolvers yet; generic fallback below
    eta_resolver_default    = Defense.MakeGenericEtaResolver(ThreatData),
    lock_buffer_s           = 0.3,
    fallback_lock_ttl_s     = 2.0,
    -- REQUIRED for the lock domain: Lina v0.5.40.1 hotfix showed a missing
    -- self_npc makes TrySaveSelf resolve target=nil -> every lock silently
    -- bypassed (double-save regression class).
    self_npc                = SAVE_CFG.self_npc,
    -- nil (not 0) on failure: nil falls through to the lib's unlocked path;
    -- a 0 sentinel would bucket-collide all unresolvable entities on one key.
    entity_index            = function(ent)
        if not ent then return nil end
        if Entity.IsEntity and not Entity.IsEntity(ent) then return nil end
        local ok, idx = pcall(Entity.GetIndex, ent)
        if ok and type(idx) == "number" then return idx end
        return nil
    end,
    ability_handle          = function(ability_name)
        if not ability_name or not State.hero then return nil end
        local ok, h = pcall(NPC.GetAbility, State.hero, ability_name)
        if ok then return h end
        return nil
    end,
}

-- ── decision funnel (R1-R4) ──────────────────────────────────────────────────
-- Effective HP vs March (Magical): prefer the live per-unit magic damage
-- multiplier (= 1 - MR); fall back to the coarse per-tier table.
local function creep_eff_hp(c, camp_type)
    local hp = Entity.GetMaxHealth(c) or 0
    local mult
    if NPC.GetMagicalArmorDamageMultiplier then
        local ok, m = pcall(NPC.GetMagicalArmorDamageMultiplier, c)
        if ok and type(m) == "number" and m > 0 then mult = m end
    end
    if not mult then mult = 1 - (K.CAMP_MR[camp_type] or 0) end
    return hp / math.max(0.05, mult)
end

local function camp_creep_list(camp, camp_type, neutrals)
    local out = {}
    for _, c in ipairs(Map.CampCreeps(camp, neutrals)) do
        out[#out + 1] = { entity = c, pos = origin(c),
                          hp = creep_eff_hp(c, camp_type), gold = NPC.GetGoldBountyMax(c) or 0 }
    end
    return out
end

-- Per-March EFFECTIVE magic damage to a clustered target, LEVEL-AWARE. Liquipedia:
-- March spawns 144 robots over ~6s (0.4s intervals), each detonating 13/22/31/40 magic
-- by ability level; ROBOTS_EFFECTIVE = the ~count that actually detonate on a clustered
-- camp/wave over that sweep (the damage is delivered OVER TIME, not instantly). This is
-- the ONE damage model for both camp feasibility and the shove cast count - the old flat
-- MARCH_DMG_PER_CAST (level-blind ~450) under-counted late game (one March really does
-- ~960 at L4), inflating the cast count -> a wasteful extra W on a corpse (N5 follow-up).
local function effective_march_dmg()
    local lvl = (State.march and Ability.GetLevel(State.march)) or 0
    if lvl < 1 then return 0 end
    local per = K.PER_MARCH_DMG[lvl] or 0
    -- v0.1.187 (user: read the ACTUAL skill damage from the API): the per-robot damage live via
    -- Ability.GetLevelSpecialValueFor (gitbook-verified; -1 = current level). Patch-proof: a
    -- balance change flows in automatically. The KV special is expected under "damage"; 0/absent
    -- (our own KV dump had damage=0 for March, hence the table) -> the Liquipedia table stands.
    -- One-shot march_per_dmg log says which source won (in-client verification).
    local okv, live = pcall(function()
        return Ability.GetLevelSpecialValueFor and Ability.GetLevelSpecialValueFor(State.march, "damage", -1)
    end)
    if okv and type(live) == "number" and live > 0 then per = live end
    if State.marchPerLogged ~= per then
        State.marchPerLogged = per
        logline(string.format("march_per_dmg per=%d src=%s lvl=%d", per,
            (okv and type(live) == "number" and live > 0) and "live" or "table", lvl))
    end
    local d = per * K.ROBOTS_EFFECTIVE
    -- v0.1.186 (user: account magic-amp items): SPELL AMP (Kaya +10%, Y&K/K&S, talents) scales
    -- March. NPC.GetBaseSpellAmp is the only amp read the API exposes (gitbook-verified name);
    -- whether it aggregates ITEM amp is UNVERIFIED in-client - pcall-guarded, 0-fallback, and the
    -- ft.dmg trace shows the result (buy Kaya -> dmg= should read ~1056 at L4; if it stays 960 the
    -- read does not see items and this needs a modifier-property read instead). Percent-vs-
    -- fraction ambiguity handled (10 -> 0.10; 0.10 stays).
    local ok, amp = pcall(function() return NPC.GetBaseSpellAmp and NPC.GetBaseSpellAmp(State.hero) end)
    if ok and type(amp) == "number" and amp > 0 then
        d = d * (1 + (amp > 1 and amp / 100 or amp))
    end
    return d
end

-- ONE clear-cost model for candidacy + valuation (execution keeps its live ClearBudget cap + early
-- exit). v0.1.183 (USER DAMAGE MODEL, run-18 correction): March hits EVERY creep in the box AT
-- ONCE - each creep intercepts its own robots - so comparing total March damage to the SUM of camp
-- HP was the wrong constraint and INFLATED planning counts (a large pair read 3+ casts ~1005 mana =
-- the camp drought's real root). The EMPIRICAL counts are the model (user): pairs <= 3 W except
-- ancients; big camps 2 at most 3; ancients 3-4 (Dragon ~5 = the exception; the on-arrival live ehp
-- budget + the empty early-exit self-correct it). The tier FLOORS own the planning count; the
-- sum-ceil applies ONLY to STACKS (2x+ creep count is a genuine throughput constraint, v0.1.100).
local function clear_marches(camp_type, ehp, stacks)
    local m = marches_for(camp_type)
    if (stacks or 1) >= 2 then
        local emd = effective_march_dmg()
        if emd > 0 and (ehp or 0) > m * emd then m = math.ceil(ehp / emd) end
    end
    return math.min(K.MAX_CLEAR_MARCHES, m)
end
-- Is a camp clearable within the cap? ceil(ehp/dmg) <= MAX_CLEAR_MARCHES. No March yet (emd 0) -> assume yes.
local function camp_clearable(ehp)
    local emd = effective_march_dmg()
    return emd <= 0 or (ehp or 0) <= emd * K.MAX_CLEAR_MARCHES
end

-- Current Rearm channel time by the ability's LEARNED level (2.69/1.93/1.20 by level). The clear-time
-- model (camp clear_t + the shove cal) rearms BETWEEN Marches, so using the L1 channel (2.69s) at Rearm
-- L2/L3 overestimated every multi-March clear -> the planner rejected camps it could actually finish
-- before the wave, and the shove slack was off. Timing is the farm's backbone; a per-clear error this
-- size is re-applied every decide, so it compounds all game. lvl 0 (pre-6, no Rearm) keeps the L1 value.
local function rearm_channel()
    local lvl = (State.rearm and Ability.GetLevel and Ability.GetLevel(State.rearm)) or 0
    return K.REARM_CHANNEL[lvl] or K.REARM_CHANNEL[1] or 1.25
end

-- LADDER-AWARE teleport pricing (v0.1.230): the tp fed to EVERY InterceptETA / route leg.
-- InterceptETA prices a hop at tp.channel, but the ladder's REAL cost when Keen is on cd
-- is rearm-first (the v0.1.211 raid-transit formula, generalized): ready keen = the bare
-- channel; keen down + rearm ready = rearm channel + keen channel; neither = nil (walk
-- pricing - the decide re-runs every 0.4s and re-prices when a reset comes back). The old
-- flat { channel = KEEN_CHANNEL } underpriced trips whenever Keen was down (run-49 t=176:
-- a commit walked in on keen-priced travel, the wave resolved first, and the exit paid
-- the full rearm+keen it was never charged for). ONE producer - all feed sites use this.
local function keen_tp()
    local kl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
    if kl < 1 then return { channel = 1e9 } end   -- unskilled: walking IS the only transport (honest)
    if ready(State.keen) then return { channel = K.KEEN_CHANNEL } end
    local rl = (State.rearm and Ability.GetLevel and Ability.GetLevel(State.rearm)) or 0
    if rl >= 1 and ready(State.rearm) then return { channel = rearm_channel() + K.KEEN_CHANNEL } end
    -- both on cd: the trip's real cost is the WAIT until the ladder can keen, not a walk
    -- (v0.1.230's 1e9 here walk-flipped the pricing world for the whole keen cd - the
    -- run-51 fountain-walk regression). cd read is in-code verified (verify_cast).
    local kcd = (Ability.GetCooldownTimeRemaining and Ability.GetCooldownTimeRemaining(State.keen)) or 5
    local wait = kcd
    if rl >= 1 then
        local rcd = (Ability.GetCooldownTimeRemaining and Ability.GetCooldownTimeRemaining(State.rearm)) or 5
        wait = math.min(kcd, rcd + rearm_channel())
    end
    return { channel = wait + K.KEEN_CHANNEL }
end

-- v0.1.162 (schedule audit): the AT-FOUNTAIN refill duration from the ACTUAL deficit at the captured
-- regen rates (6% mana/s + 5% hp/s to REFILL_FRAC) + the rearm-reset-keen at base. Replaces the flat
-- REFILL_WAIT 4.0: at a 60% mana deficit the real wait is ~10s, near-full it is ~1s - the constant
-- skewed the planner's camp-vs-refill choice both ways. Travel to/from base is priced by the caller.
local function refill_wait()
    local h = State.hero
    local mmax = (NPC.GetMaxMana and NPC.GetMaxMana(h)) or 1
    local hmax = Entity.GetMaxHealth(h) or 1
    local tm = math.max(0, K.REFILL_FRAC * mmax - mana()) / math.max(1, K.FOUNTAIN_MANA_PCT_S * mmax)
    local th = math.max(0, K.REFILL_FRAC * hmax - (Entity.GetHealth(h) or 0)) / math.max(1, K.FOUNTAIN_HP_PCT_S * hmax)
    return math.max(tm, th) + rearm_channel()
end

-- F1: can OUR team see this camp centre right now? Distinguishes "fogged" (no
-- vision) from "in vision but empty" (someone cleared it). pcall-guarded: if the
-- FogOfWar API is absent, returns false so behaviour degrades to cache-or-estimate.
local function camp_visible(center)
    if not (FogOfWar and FogOfWar.IsPointVisible) then return false end
    local ok, v = pcall(FogOfWar.IsPointVisible, Vector(center.x, center.y, center.z or 0))
    return ok and v == true
end

-- F1: how many stacks a camp's value implies (real gold / one-stack tier gold).
local function camp_stacks(gold, ctype)
    local base = (TIER_EST[ctype] or TIER_EST[1]).gold or 1
    local n = math.floor((gold or 0) / base + 0.5)
    return (n < 1) and 1 or n
end

local function gather_candidates()
    local cands = {}
    local total, vis, est, seen, cleared = 0, 0, 0, 0, 0
    if not State.menu.kindJungle:Get() then State.funnel = {}; return cands end
    -- v0.1.269 (run-81 t=26: a camp trip arrived BEFORE the 1:00 first spawn and read
    -- arrive_empty): neutrals do not exist yet - no camp is a candidate. Generalizes the
    -- .252 minute-0 STACK clamp to regular picks; 58 leaves the travel legal just before.
    if now() < 58 then State.funnel = { total = 28, prespawn = true }; return cands end
    local neutrals = Map.AllNeutrals()                                      -- enumerate neutrals ONCE; box-filter per camp (was a full-map scan per camp)
    for _, cd in ipairs(Map.Camps()) do
        total = total + 1
        local key = Map.CampKey(cd.center)
        if is_cleared(key) then                                            -- recently visited/cleared: skip until respawn
            cleared = cleared + 1
        else
            local creeps = camp_creep_list(cd.camp, cd.type, neutrals)     -- real creeps if in vision
            if #creeps == 0 and camp_visible(cd.center) then               -- F1: in vision + EMPTY -> someone cleared it
                mark_cleared(key); State.campSeen[key] = nil               -- Note 2: do not assume-occupy a camp we can SEE is empty
                cleared = cleared + 1
            else
                local gold, ehp, estimated, source
                if #creeps > 0 then                                        -- in vision + occupied: real value, cache it
                    vis = vis + 1; estimated, source = false, "live"
                    gold, ehp = Farm.GoldValue(creeps), Farm.EffectiveHP(creeps)
                    State.campSeen[key] = { gold = gold, ehp = ehp, seen_at = now() }
                else                                                       -- fogged: last-seen cache if fresh, else TIER_EST
                    local c = State.campSeen[key]
                    if c and (now() - c.seen_at) < K.CAMP_CACHE_S then
                        gold, ehp, estimated, source = c.gold, c.ehp, true, "seen"; seen = seen + 1
                    else
                        local e = TIER_EST[cd.type] or TIER_EST[1]
                        gold, ehp, estimated, source = e.gold, e.hp, true, "est"; est = est + 1
                    end
                end
                if camp_clearable(ehp) then                                -- clearable within MAX_CLEAR_MARCHES (same model as valuation + execution)
                    cands[#cands + 1] = { camp = cd.camp, center = cd.center, type = cd.type, box = cd.box,
                                          creeps = creeps, gold = gold, ehp = ehp, key = key,
                                          estimated = estimated, source = source }
                end
            end
        end
    end
    State.funnel = { total = total, vis = vis, est = est, seen = seen, cleared = cleared, cands = #cands }
    return cands
end

-- Snap a point onto walkable ground by stepping from it toward `toward` (returns {x,y}).
-- Used to keep a keen landing / shove stand off unwalkable terrain (a tower's high ground).
-- (the local snap_walkable is GONE: this is Map.SnapWalkable, called by try_escape_blink and safe_stand_for.)

-- REBUILD: the safe stand for a wave MEETING. Start WAVE_STANDBACK back toward our fountain, then push
-- FURTHER back until OUTSIDE enemy tower range = the tower-border W-farm (Tinker takes no tower damage but
-- March still reaches the under-tower wave). Returns (stand, covers, safe):
--   covers = tower-safe AND March from the stand reaches the meeting (within MARCH_CAST_RANGE+HALFWIDTH).
--            covers=false means the wave is too deep to W from safety -> not farmable now (wait/jungle).
--   safe   = not lane_unsafe(stand) (no gank). A non-covering stand is still the safe place to WAIT.
-- (the walkable snap it calls is Map.SnapWalkable, a lib field: no definition-order constraint here.)
local function safe_stand_for(meeting, forward, deep_ok, lane)
    local fp = friendly_fountain_pos()
    if not (fp and meeting) then return nil, false, false end
    local dx, dy = fp.x - meeting.x, fp.y - meeting.y
    local dl = math.sqrt(dx * dx + dy * dy); if dl < 1 then return nil, false, false end
    -- Glue rebuild item 2: ONE stand = lib composition. Farm.CrashCast places the back-toward-
    -- fountain offset (forward = anticipation: closer so March catches the wave early + lands on the
    -- trailing ranged; contested = the safe 900 back-off), Map.Nav.SafeDest clamps it tower-safe (never
    -- sits in tower range), Map.SnapWalkable keeps it off ridges. Replaces the hand-rolled push-back
    -- loop; schedule_ctx's raw-offset duplicates route here too.
    local back = forward and K.ANTICIP_RANGED_REACH or K.WAVE_STANDBACK
    local g = Farm.CrashCast(meeting, nil, { standback = back, fountain = { x = fp.x, y = fp.y } })
    -- v0.1.193 (user, run-23): the stairs line is an EXCLUSION, not a clamp. v0.1.192 clamped the
    -- stand to the line BEFORE the covers test, which legalized commits to line-parked stands
    -- ~1000u short of the fight = the 22-25s stands in enemy territory. Now the stand composes
    -- NATURALLY (tower_safe only); a meeting whose natural stand sits past WALK_DEPTH_MAX is not
    -- walk-farmable -> covers=false -> Plan no_safe_stand/gone_by_arrival -> jungle (the exclusion
    -- lands in the SCHEDULE, per the point-system doctrine). deep_ok (raid-capable) exempts: that
    -- transit is a creep-keen, not a walk. tower_safe always holds.
    local stand = Map.Nav.SafeDest(g.stand, { x = dx / dl, y = dy / dl }, tower_safe)
    stand = Map.SnapWalkable(stand, meeting)
    local reach  = (K.MARCH_CAST_RANGE or 300) + (K.MARCH_HALFWIDTH or 900)
    -- v0.1.201: the deep era leashes lane positions to our mid tower (T1DOWN_LEASH).
    -- v0.1.202 (user, run-30: "skipped an obvious keen on creep on a 5-6 creep wave, no way to get
    -- ganked"): an UNGANKABLE raid is exempt from the leash again - deep_ok (Keen L2 shove) + no
    -- gank read at the stand (count+HP-aware lane_unsafe + the fog-aware risk under the shove bar).
    -- Run-30 t=974-1100: visible e=5-6 waves (eff_hp up to 3500, enH=0) idled as no_safe_stand.
    -- The gankable deep case stays excluded (the run-29 148-mana walk-home cannot recur unfunded:
    -- the hop gate prices the entry, v0.1.200).
    local raid_safe = deep_ok and not lane_unsafe(stand) and enemy_risk_at(stand) < K.SHOVE_SAFE_RISK
    -- v0.1.203 (user, standing rule): leash-era anomalies must be ANALYZABLE, not inferred - the
    -- covers=false CAUSE is discriminated (cwhy) and surfaced in the farm trace, so a future
    -- "strange behavior around the leash" reads directly from the log instead of a guess chain
    -- (run-30's diagnosis had to infer which term killed covers).
    local covers, cwhy = false, nil
    if not tower_safe(stand) then cwhy = "tower"
    elseif not Farm.MarchCovers(stand, meeting, reach) then cwhy = "cover"
    elseif not (deep_ok or stand_depth(stand, lane) <= K.WALK_DEPTH_MAX) then cwhy = "depth"
    elseif not (lane_leash_ok(stand, nil, lane) or raid_safe) then cwhy = "leash"
    else covers = true end
    return stand, covers, (not lane_unsafe(stand)), cwhy
end

-- note 3 (v0.1.160, user): the PROTECTED wait spot - when an enemy hero is on the lane, wait out
-- a hold near OUR tower (inside its cover, facing the lane) instead of tanking harass at the
-- forward stand. Nearest alive friendly structure to the stand (any distance), offset
-- WAIT_PROTECT_AHEAD toward the stand; no structure -> the stand pulled WAIT_BACKOFF toward our
-- fountain. The wave's arrival (live creeps) switches back to the normal approach automatically.
local function protected_wait_spot(stand)
    -- v0.1.175 (run-13): the WAIT_PROTECT_SCAN 2500 bound predates depth-free stands - a deep
    -- stand near their T2 found NO structure in range and fell back to stand-600 = a fake anchor
    -- DEEP in enemy territory (the tether then keened there, wasting the keen the raid needed).
    -- The wait spot is the nearest alive friendly structure, whatever the distance.
    local best, bestd
    for _, e in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}) do
        if Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
            local p = Entity.GetAbsOrigin(e)
            if p then
                local d = p:Distance(Vector(stand.x, stand.y, p.z))
                if not bestd or d < bestd then best, bestd = p, d end
            end
        end
    end
    if best then
        local dx, dy = stand.x - best.x, stand.y - best.y
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then
            return Map.SnapWalkable({ x = best.x + dx / dl * K.WAIT_PROTECT_AHEAD,
                                       y = best.y + dy / dl * K.WAIT_PROTECT_AHEAD },
                                     { x = stand.x, y = stand.y })
        end
        return { x = best.x, y = best.y }
    end
    local fp = friendly_fountain_pos()
    if fp then
        local dx, dy = fp.x - stand.x, fp.y - stand.y
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then
            return Map.SnapWalkable({ x = stand.x + dx / dl * K.WAIT_BACKOFF,
                                       y = stand.y + dy / dl * K.WAIT_BACKOFF },
                                     { x = stand.x, y = stand.y })
        end
    end
    return { x = stand.x, y = stand.y }
end

-- v0.1.343 THE ONE IDLE PRODUCER (TINKER_WAIT_CAST_DESIGN.md): the single between-wave wait
-- target, called by BOTH idle sites so the oscillator dies structurally. `stand` is the fresh
-- cast stand, or nil when none is fresh (post-fountain / respawn / >60s side-farm). A real
-- disable threat in reach -> the protected structure pocket (kit-checked .305 doctrine),
-- anchored on the stand when we have one else on the hero, latched PROT_CLEAR_S like the commit
-- path (ON instant, OFF only after 2s clean) so a juking disabler cannot flicker the target the
-- way the deleted hero-anchored enemy_hero_near/frontier_excess boundary did. Otherwise, with a
-- stand: a MODEST step-back toward our fountain, WAIT_STEP_BACK (200). THE LOAD-BEARING BOUND is
-- WAIT_STEP_BACK < W_PRE_STAND_R (600) - that keeps the hero inside the FOG pre-cast gate's radius
-- of the stand so the pre-cast still fires. It is NOT an engage-range bound: dref is
-- measured LIVE to the MOVING wave and closes into range as the wave marches in, so the
-- wait sitting ~1010 (>950) from the crash is fine. g343 stalled because idling ~1000 back
-- exceeded W_PRE_STAND_R and BLOCKED the lead cast (not because of engage range). With NO stand
-- and no threat -> nil (nothing to pre-position to; the reactive flee/panic/save layers own
-- safety, the scheduler owns the next action). Reuses Geometry.DiscReachPoint (radius-WAIT_STEP_BACK
-- point from the stand toward the fountain; scalar component math, no Vector crossing).
local function idle_wait_spot(stand)
    local anchor = stand
    if not anchor then local m = origin(State.hero); anchor = { x = m.x, y = m.y } end
    if channel_threat_near(anchor) then State.idleProtUntil = now() + K.PROT_CLEAR_S end
    if State.idleProtUntil and now() < State.idleProtUntil then
        return protected_wait_spot(anchor)
    end
    if not stand then return nil end
    local fp = friendly_fountain_pos()
    if not fp then return { x = stand.x, y = stand.y } end
    local wx, wy = Geometry.DiscReachPoint(stand.x, stand.y, K.WAIT_STEP_BACK, fp.x, fp.y)
    return Map.SnapWalkable({ x = wx, y = wy }, { x = stand.x, y = stand.y })
end

-- Keen anchor candidates: friendly buildings (live) + friendly outposts (static,
-- map_data team-matched). Outposts are central and reach the mid camps no building
-- is near (Note 3: those were skipped when only buildings counted as anchors).
local function anchor_candidates(include_creeps)
    local out = {}
    for _, e in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}) do
        if Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
            local p = Entity.GetAbsOrigin(e)
            if p then out[#out + 1] = { pos = p, r = K.KEEN_LAND_STRUCTURE, name = "bldg" } end
        end
    end
    for _, o in ipairs(MapData.OUTPOSTS or {}) do
        if o.team == State.team and o.pos then
            out[#out + 1] = { pos = Vector(o.pos[1], o.pos[2], o.pos[3]),
                              r = K.KEEN_LAND_OUTPOST, name = o.name or "outpost" }
        end
    end
    -- review #2 part 2: allied lane creeps as keen anchors ONLY for a DEEP DIVE (Keen L2, T1 dead) so
    -- Tinker teleports IN to the deep meeting instead of WALKING through enemy territory (user model).
    -- The v0.1.88 revert removed creeps GLOBALLY (they caused weird enemy-side routing during normal
    -- farming + a death); re-added SCOPED to the dive + still filtered by KEEN_LAND_SAFE_RISK in
    -- keen_to_anchor (the landing-safety gate = the death-scar fix). Off by default.
    if include_creeps then
        State.creepExcl = 0   -- v0.1.236: per-pass tower-drift exclusion count (cexcl= on the keen lines)
        -- v0.1.215 (user, run-38: "teleported on creep, ended up under the tower" + "lost keen to
        -- a dying creep... better to keen on ranged creeps since they are the last to die"): the
        -- anchor is chosen at CAST time but the creep moves/dies during the ~3s channel - a
        -- front-line melee walks INTO tower range and a low-HP one dies and cancels the keen.
        -- Prefer REAR units (ranged/siege: trail the wave, die last) and skip creeps too hurt to
        -- survive the channel; melee only when no rear unit qualifies.
        local rear, melee = {}, {}
        for _, c in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
            if Entity.GetTeamNum(c) == State.team and Entity.IsAlive(c) and not Entity.IsDormant(c)
               and (Entity.GetHealth(c) or 0) >= K.KEEN_CREEP_MIN_HP then
                local p = Entity.GetAbsOrigin(c)
                -- v0.1.221 -> v0.1.228 -> v0.1.236 (user: "if we predict that a creep will be
                -- under the enemy tower or is under it, don't keen to it"): every gate in this
                -- chain is CAST-time, but Keen conveys to the UNIT ~3s later. v0.1.228 used the
                -- worst-case straight-at drift (325 x 3.5s, flat ~2050 exclusion) - CONFIRMED
                -- over-excluding in run-54: at a DEEP equilibrium the wave lives near their
                -- alive T2, so every creep (incl. the rear ranged) sat inside 2050 and 9 keens
                -- went to buildings with 1171-3799u residual walks (the user's "should be on
                -- creep, was on tower"). The drift is MOTION-AWARE now: the creep's lane's
                -- MEASURED ally-wave speed (State.laneScan, 2s cache) x KEEN_CREEP_DRIFT_S -
                -- a wave STALLED fighting at the tower exposes its rear creeps again; a
                -- marching wave (325) keeps the full exclusion; unknown speed = worst case.
                -- Floor 100: a stalled fight can break and surge during the ~3s channel.
                if p then
                    local spd = 325
                    local scan = State.laneScan and State.laneScan[Lane._assign_lane({ x = p.x, y = p.y })]
                    local aw = scan and scan.ally_wave
                    if aw then
                        local s2 = aw.speed_measured or aw.speed   -- v0.1.256 arc B: the DISPLACEMENT when tracked (the .236 intent - aw.speed was the stat all along)
                        if not s2 then
                            for _, cc in ipairs(aw.creeps or {}) do
                                if cc.speed and (not s2 or cc.speed > s2) then s2 = cc.speed end
                            end
                        end
                        if s2 then spd = math.max(100, s2) end
                    end
                    local r = K.TOWER_RISK_RADIUS + spd * K.KEEN_CREEP_DRIFT_S
                    for _, tw in ipairs(Map.TowersInRadius(Vector(p.x, p.y, 0), r) or {}) do
                        if Entity.GetTeamNum(tw) ~= State.team and Entity.IsAlive(tw) then
                            State.creepExcl = (State.creepExcl or 0) + 1   -- v0.1.236: the exclusion names itself (cexcl= on the keen lines)
                            p = nil; break
                        end
                    end
                end
                if p then
                    local nm = (NPC.GetUnitName and NPC.GetUnitName(c)) or ""
                    local a = { pos = p, r = K.KEEN_LAND_STRUCTURE, name = "creep" }
                    if nm:find("ranged", 1, true) or nm:find("siege", 1, true) then
                        rear[#rear + 1] = a
                    else
                        melee[#melee + 1] = a
                    end
                end
            end
        end
        local pick = (#rear > 0) and rear or melee
        for i = 1, #pick do out[#out + 1] = pick[i] end
    end
    return out
end

-- Any ALLIED lane creep within `r` of (x,y)? Keen L2+ auto-conveys to the NEAREST ally, so an allied creep
-- near the cast point hijacks the landing and cancels when it moves/dies. Jungle has none; matters near lanes.
local function allied_lane_creep_near(x, y, r)
    local r2 = r * r
    for _, c in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
        if Entity.GetTeamNum(c) == State.team and Entity.IsAlive(c) and not Entity.IsDormant(c) then
            local p = Entity.GetAbsOrigin(c)
            if p then local dx, dy = p.x - x, p.y - y; if dx * dx + dy * dy <= r2 then return true end end
        end
    end
    return false
end

-- Nudge a keen landing from (lx,ly) toward the anchor (ax,ay) onto WALKABLE + TREE-FREE (+ optionally
-- CREEP-CLEAR) ground: trees block a landing but GridNav.IsTraversable does NOT flag them, and at Keen
-- L2+ an allied lane creep near the cast point hijacks the convey. Steps from the point nearest the
-- stand toward the anchor (a tower = clear ground, away from the creep line) and returns the first
-- clear {x,y}, keeping the CLOSE tower (small residual bump) instead of falling back to a far anchor.
-- note 1 (v0.1.160): the creep check used to REJECT the whole anchor after the nudge - our own wave
-- marching through the near-anchor disc discarded T1 entirely, so Tinker keened to T2/T3 and walked
-- 1400-3400u to the lane. Folding it into the step loop keeps the near anchor. nil if all blocked.
local function clear_landing(lx, ly, ax, ay, avoid_creeps)
    for i = 0, 6 do
        local f = i / 6
        local x, y = lx + (ax - lx) * f, ly + (ay - ly) * f
        if Map.WalkablePt(x, y)
           and not (avoid_creeps and allied_lane_creep_near(x, y, K.KEEN_CREEP_CLEAR)) then
            local ok, trees = pcall(function() return Map.TreesInRadius(Map.GroundPos(x, y), K.KEEN_TREE_CLEAR) end)
            if (not ok) or (not trees) or #trees == 0 then return { x = x, y = y } end
        end
    end
    return nil
end

-- live (level-scaled) ability mana cost with the Liquipedia fallback (mirrors the rearm-cost read).
-- v0.1.398: MUST stay ABOVE keen_to_anchor - its affordability gate calls it, and a definition
-- below the caller resolves as a nil GLOBAL at runtime (the v0.1.351 cd_remaining class; 945
-- crashes in g392 killed every outbound keen while it sat 600 lines down).
local function abil_mana(abil, fb)
    local ok, c = pcall(function() return Ability.GetManaCost and Ability.GetManaCost(abil) end)
    return (ok and type(c) == "number" and c > 0) and c or fb
end

-- Keen to the point in a friendly STRUCTURE's reach disc (tower r=700 / outpost r=250) NEAREST the stand.
-- Keen Conveyance is ground-targeted and drops us AT the cast point as long as a valid ally (a building at
-- L1) is within reach, so when a tower covers the stand we land ON the stand (travel ~= 0) instead of on
-- the building + a long walk (which shrinks the camp time budget). lib/geometry.BestReachLanding does the
-- pure disc geometry; the `accept` predicate carries the VALIDATED safety gates (enemy_risk / tower_safe /
-- depth - now checked on the REAL landing) + the allied-creep-clear. Structures only; the creep/BoT reach
-- landing is a later pass on the SAME picker (only the anchor list + accept differ). include_creeps keeps
-- the old deep-dive anchors (provisional under the structure disc until the dedicated creep pass lands).
local function keen_to_anchor(stand, include_creeps)
    local anchors = anchor_candidates(include_creeps)
    local me = origin(State.hero)
    local sdepth = stand_depth(stand)
    -- note 1 (v0.1.160): the creep-hijack only EXISTS at Keen L2+ (L1 conveys to buildings/outposts
    -- only), so L1 skips the creep avoidance entirely; L2+ nudges off creeps inside clear_landing.
    local kl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
    local avoid_creeps = (not include_creeps) and kl >= 2
    -- v0.1.233 keen_skip instrument (TINKER_TRANSPORT_STUDY.md G1, the blink_skip lesson
    -- replayed): keen_to_anchor had FOUR silent return-false exits, and one silent refusal
    -- poisons keenedSpot into a full walk (run-52 t=238: a legal own-side dispatch walked
    -- 31.9s; every reconstructable gate passed on paper - the real gate is UNNAMED). Tally
    -- every rejection; name the exit. NAMING ONLY, zero behavior change.
    local rej = { clear = 0, unsafe = 0, tower = 0, overshoot = 0, walklaw = 0 }
    local accept = function(lx, ly, a)
        local cl = clear_landing(lx, ly, a.pos.x, a.pos.y, avoid_creeps)            -- nudge onto walkable + tree-free (+ creep-clear) ground
        if not cl then rej.clear = rej.clear + 1; return false end
        local land = Vector(cl.x, cl.y, 0)
        -- glue review F5 (v0.1.157): the landing danger gate is lane_unsafe - the SAME count+HP-aware
        -- policy that judges the stand itself (gank/fog/low-HP-1v1 reject; a healthy 1v1 trade does
        -- not force a walk to the lane anymore). The old raw enemy_risk_at >= 0.35 rejected every
        -- landing near a single laner (~0.5-0.7 at trade range). tower_safe + the depth cap keep the
        -- instant-teleport conservatism; KEEN_LAND_SAFE_RISK still gates the travel-blink landing.
        if lane_unsafe({ x = cl.x, y = cl.y }) then rej.unsafe = rej.unsafe + 1; return false end
        if not tower_safe({ x = cl.x, y = cl.y }) then rej.tower = rej.tower + 1; return false end   -- v0.1.193: landings are tower-gated only (the stairs line moved to the decide-time exclusion); the depth-vs-stand check below still caps enemy-side overshoot
        if stand_depth(land) > 0 and stand_depth(land) > sdepth + K.KEEN_DEPTH_MARGIN then rej.overshoot = rej.overshoot + 1; return false end  -- cap ENEMY-SIDE overshoot only (don't reject an our-side jungle landing just for being toward mid vs a deep-corner camp -> the "keen to far T3 instead of close T2" bug)
        if not include_creeps and stand_depth(land) > K.WALK_DEPTH_MAX then rej.walklaw = rej.walklaw + 1; return false end  -- v0.1.198 audit HOLE C: a non-raid hop obeys the walk law too - the stand+margin cap alone allowed landings ~700 deep at klvl=1 (legal stand 550 + margin 150)
        a._land = cl                                                                -- stash the cleared cast point for the pick (creep avoidance folded into clear_landing, note 1)
        return true
    end
    local function keen_skip(why, extra)
        logline(string.format("keen_skip why=%s anchors=%d cexcl=%d rej=clear:%d,unsafe:%d,tower:%d,over:%d,walklaw:%d%s",
            why, #anchors, State.creepExcl or 0, rej.clear, rej.unsafe, rej.tower, rej.overshoot, rej.walklaw, extra or ""))
        return false, why   -- v0.1.234: the caller latches (or not) by the NAMED reason
    end
    -- ARC E1: the keen channel (2.93s) is the easiest disable target of all, and the cast
    -- SITE was never gated (only landings were). Within a disabler-kit enemy's reach the
    -- channel is a donation - skip the rung; the ladder walks/blinks the leg instead and
    -- the fsm's live checks re-open the keen the moment the reach breaks.
    if channel_threat_near then
        local thr = channel_threat_near({ x = me.x, y = me.y })
        if thr then
            -- v0.1.258 I1: disabler refusals no longer latch (transient threat), so this
            -- rung retries every tick while the disabler stays in reach - throttle the log.
            if now() - (State.kSkipDisLogT or 0) > 2 then
                State.kSkipDisLogT = now()
                return keen_skip("disabler", " threat=" .. thr)
            end
            return false, "disabler"
        end
    end
    -- v0.1.397 THE AFFORDABILITY GATE (g360 keen-audit finding #10, re-armed by the two g391
    -- castless statues at t=353/t=386: keened in at raw 214, post-jump ~139, below March cost,
    -- stood ~15s casting NOTHING). A commit that cannot fund its March on arrival is unaffordable
    -- BEFORE it leaves. Wave arm (raids get the full-chain arm below, v0.1.411); TRANSIENT refusal (both callers' whitelists retry it next
    -- tick without latching keenedSpot into a walk); and it defers ONLY when the Bottle can close
    -- the gap - stamping keenNoFund lets bottle_tick drink ABOVE its 200 floor (the v0.1.386
    -- machinery, keen flavour), so raw rises ~60/charge and the keen fires 1-2 ticks later funded.
    -- If no charges can close it, TODAY'S behaviour stands (no new veto, no regression path).
    -- Precheck over 15 logs: fires 0.67/game, 7 of 10 are the statue class, 3 of 10 cost one tick
    -- plus a drink on commits that were fine anyway.
    -- v0.1.411 RAID ARM (TINKER_RAID_READINESS_DESIGN.md; g403 operator-watched: 5 raid-era
    -- keens with ZERO W casts in 176s while keen_defer fired 0 times - the gate above exempted
    -- raids entirely via `if not include_creeps`). A raid keen now prices the FULL CHAIN TO
    -- FIRST CAST, not just March:
    --   March ready:  short = mc - (mana() - kc)                        (parity with the wave arm)
    --   March on cd:  short = max(reserve + rc, rc + mc) - (mana() - kc)
    -- The max() of the TWO bars is load-bearing (the v0.1.384 ruler-mismatch class: a predicate
    -- that agrees with only ONE downstream bar leaves a band where the hero neither bails nor
    -- casts). g403 statued against each bar separately: t=643.9 post-jump 230 vs try_rearm's
    -- reserve+rc bar 300 (the plain March check would have PASSED it, 230 >= 160); t=685.4
    -- post-jump 309 passed the 300 bar but rearm spends 150 leaving 159 < March 160, one mana
    -- short of rc+mc. reserve reads the SAME source try_rearm spends against
    -- (State.menu.escapeMana:Get()), so the two rulers cannot drift apart again.
    -- Refusals: a Bottle-closable gap defers exactly like the wave arm (transient, the v0.1.386
    -- drink closes it in 1-2 ticks); an unclosable gap returns "raid_broke" and lane_go
    -- redecides through the planner (the v0.1.252 raid_far shape). No walk path on either.
    -- ponytail: no March-CD-expiring-soon arm (design section 2, YAGNI) - add only if watched
    -- games show raids deferred while March comes off cd under ~3s.
    do
        local kc = abil_mana(State.keen, K.KEEN_MANA_FB)
        local mc = abil_mana(State.march, K.MARCH_MANA_FB)
        local short, chain
        if not include_creeps then
            short = mc - (mana() - kc)
        else
            local rc = abil_mana(State.rearm, K.REARM_MANA_FB)
            local reserve = State.menu.escapeMana:Get()
            chain = ready(State.march) and mc or math.max(reserve + rc, rc + mc)
            short = chain - (mana() - kc)
        end
        if short > 0 then
            local bt = NPC.GetItem(State.hero, "item_bottle", true)
            local ch = (bt and Ability.CanBeExecuted(bt) == -1 and Item.GetCurrentCharges
                        and Item.GetCurrentCharges(bt)) or 0
            if ch * K.BOTTLE_MANA_PER_CHARGE >= short then
                State.keenNoFundT, State.keenNoFundGap = now(), short
                if include_creeps then
                    logline(string.format("keen_defer why=mana raid=y raw=%.0f chain=%.0f short=%.0f ch=%d", mana(), chain, short, ch))
                else
                    logline(string.format("keen_defer why=mana raw=%.0f short=%.0f ch=%d", mana(), short, ch))
                end
                return false, "mana_defer"
            elseif include_creeps then
                return false, "raid_broke"   -- unclosable: no log here, lane_go's raid_broke branch logs the redecide
            end
        end
    end
    local best = Geometry.BestReachLanding(anchors, { x = stand.x, y = stand.y }, { accept = accept })
    if not best then return keen_skip("no_landing") end
    local cl = best.anchor._land or { x = best.lx, y = best.ly }                    -- the cleared (tree-free) landing
    local resid = math.sqrt((cl.x - stand.x) ^ 2 + (cl.y - stand.y) ^ 2)
    -- v0.1.252 (run-67 t=922: raid dispatch priced as a creep hop, but the creeps were tower-
    -- excluded [cexcl=2] and the keen fell back to a BUILDING 3016 from the stand -> a 13s walk
    -- into a wave that resolved before arrival). A raid whose transport is NOT a creep hop and
    -- whose residual exceeds the landing-walk budget is off-design ("the step-out creep keen IS
    -- the transport" - v0.1.206); refuse BEFORE spending the keen and let the caller redecide.
    -- Creep anchors are EXEMPT at any residual (landing on the incoming wave mid-lane and riding
    -- it is the designed raid shape, v0.1.175).
    if include_creeps and best.anchor.name ~= "creep" and resid > K.RAID_RESID_MAX then
        return keen_skip("raid_far", string.format(" resid=%.0f", resid))
    end
    -- gain gate on the REAL residual (post-keen walk): only keen if it saves meaningful walk vs going direct.
    if me:Distance(Vector(stand.x, stand.y, me.z)) - resid < K.KEEN_GAIN_MIN then
        return keen_skip("gain", string.format(" d=%.0f resid=%.0f", me:Distance(Vector(stand.x, stand.y, me.z)), resid))
    end
    local finalPos = Vector(cl.x, cl.y, stand.z or me.z)
    if cast_pos(State.keen, finalPos) then
        State.channelUntil = now() + K.KEEN_CHANNEL + K.CHANNEL_PAD
        -- v0.1.216 (user: "when keen is lost due to a creep dying there is no process to
        -- recover... it tries to walk"): a canceled channel (the anchor died mid-cast) burns the
        -- cd WITHOUT teleporting, but keenedSpot stays true so the ladder never re-keens - the
        -- leg degrades to a deep walk. Stash the expected landing; keen_cancel_check() compares
        -- after the channel window and re-arms the ladder (rearm -> keen) on a miss.
        State.keenPending = { land = finalPos, origin = { x = me.x, y = me.y },
                              due = now() + K.KEEN_CHANNEL + K.CHANNEL_PAD + 0.3 }
        verify_cast("keen", State.keen)
        if not State.anchorsLogged then
            State.anchorsLogged = true
            local nb, no = 0, 0
            for _, a in ipairs(anchors) do if a.name == "bldg" then nb = nb + 1 else no = no + 1 end end
            logline(string.format("anchors buildings=%d outposts=%d", nb, no))
        end
        -- keen-efficiency arc: jump (pre-cast hero pos -> landing) makes keen-vs-walk economics
        -- judgeable from the log (the camp long-walk class rode unjudgeable residuals without it)
        logline(string.format("keen_to_anchor anchor=%s land=(%.0f,%.0f) residual=%.0f cexcl=%d jump=%.0f mana=%.0f",
            best.anchor.name, cl.x, cl.y, resid, State.creepExcl or 0, me:Distance(finalPos), mana()))
        -- v0.1.345 D1 KEEN-INVESTMENT LATCH (log-only, no behaviour): remember WHAT this keen was
        -- spent on. The outcome is scored at the next fsm_decide (reaching DECIDE means the commit
        -- that spent it has ended); casts==0 there = the keen bought nothing -> keen_waste. This
        -- MEASURES the incident-C rate (a fogged dispatch spends the keen on the approach, the wave
        -- then reads real, covers fails on depth, and the trip is abandoned) instead of inferring it
        -- from the keen-report's outcome classes, which cannot see WHY a trip died.
        -- asrc IS the fogged-vs-real signal (stamp|grid|kinest = a PREDICTION; vis|kin|held = a real
        -- read; sim = the bal<0 fight-end defer), so no separate vis field is needed - and the shove
        -- spot carries no `visible` anyway.
        do
            local sp = State.spot
            State.keenInvest = { t = now(), resid = resid,
                                 lane = sp and sp.lane, kind = sp and sp.kind,
                                 asrc = sp and sp.waveAsrc }
        end
        return true
    end
    -- v0.1.400: the comment here used to blame "channeling/silence/mana at fire time", which is
    -- PROVABLY IMPOSSIBLE and sent readers hunting the wrong cause for 18 logs. issue() has
    -- EXACTLY ONE false path - the ORDER_GAP rate guard - because issue_def below it has
    -- no false return at all. So cast_failed means one thing: another order (classically the
    -- fountain chain-drink bottle) shared this 0.05s tick and swallowed ours. That is transient
    -- and retries fine, which is exactly why the kwhy ~= "cast_failed" guards in lane_go and
    -- fsm_move exempt it from the State.keenedSpot don't-retry latch.
    return keen_skip("cast_failed")   -- v0.1.233: the 4th silent exit (order swallowed by the ORDER_GAP rate guard)
end

-- v0.1.253: the DECIDE half of the .252 raid_far gate (run-69: 19 raid_rejects = the raid-capped
-- transit priced creep hops that did not exist - dispatch -> reject -> 6s suppress -> the same
-- lane re-wins the compete -> reject again, 112 shove_stuck recovers of 249 decides). Before the
-- ladder-aware raid cap may price a ~4-6s transit, check the SAME anchor set the execution will
-- use (anchor_candidates(true) applies the tower/HP creep exclusions = cexcl): a creep anchor
-- within ride range of the target, or a structure anchor within the raid residual budget
-- (+standback slack: the target here is the crash point, the stand sits ~900 back). No hop ->
-- honest walk-class transit -> far_wave/no_fit exclude the wave cleanly, no dispatch, no churn.
local function raid_hop_ok(target)
    if not target then return false end
    for _, a in ipairs(anchor_candidates(true)) do
        local d = math.sqrt((a.pos.x - target.x) ^ 2 + (a.pos.y - target.y) ^ 2)
        if a.name == "creep" then
            if d <= K.RAID_HOP_CREEP_MAX then return true end
        elseif d <= K.RAID_RESID_MAX + K.WAVE_STANDBACK then return true end
    end
    return false
end

-- ── best March stand-spot ────────────────────────────────────────────────────
-- Two camps, one March. March's coverage is a rectangle CENTRED on the CAST POINT
-- (Liquipedia: the target point is the centre of the area; robots spawn at the back
-- edge BEHIND Tinker's facing and sweep forward), reaching ~MARCH_LEN/2 each way along
-- facing x ~MARCH_HALFWIDTH each side. So to clear an adjacent pair, cast at the
-- MIDPOINT: the centred rectangle then covers both camps (each ~d/2 from the centre,
-- within MARCH_LEN/2). pair_spot_for returns stand = aim = the MIDPOINT, unshifted, and the cast
-- point is NOT built off it: march_cast_point_multi anchors MULTI_W_OFFSET off TINKER's LIVE
-- position in a per-cast 90-deg-rotated direction, reading ss.aim only for the base axis and z.
-- RETIRED, do not go looking for them: the along-axis STAND_RING standback, and the lib/farm
-- PairStandCandidates off-axis search (no definition left in lib/farm.lua, no caller here,
-- comments only). MARCH_PAIR_OFFSET does not nudge the cast either: it is 0, and its only live
-- use is the MARCH_LEN - 2*|offset| pair_max cap. nil -> single-camp ring search.
local function pair_spot_for(cand)
    State.pairSkip = nil   -- why pairing did NOT fire (read by the decide log when paired=false)
    local A = cand.center
    if not A then State.pairSkip = "no_center"; return nil end
    -- Scan the FULL static camp list, NOT Camps.InRadius: the latter is VISION-limited
    -- (the v0.1.5 occupancy lesson), so a fogged partner reads as no_partner - the Dire
    -- pair's partner (enemy side) was missed while the Radiant pairs' (own side) were
    -- found. gather_candidates already uses the full Map.Camps() (funnel total=28 every
    -- decide); pairing must too (assume-occupied unless is_cleared).
    -- Accept a partner only within the distance the centred March can actually cover:
    -- PAIR_RADIUS capped by the offset-shrunk reach MARCH_LEN-2*|MARCH_PAIR_OFFSET| (the
    -- lib's feasibility bound far_long=d/2+|off| <= MARCH_LEN/2). At offset 0 this is just
    -- PAIR_RADIUS; a nonzero offset (calibration) shrinks it so the gate never accepts a
    -- partner PairStandCandidates will always reject (which would log infeasible every decide).
    local pair_max = math.min(K.PAIR_RADIUS, K.MARCH_LEN - 2 * math.abs(K.MARCH_PAIR_OFFSET))
    local partner, pd = nil, math.huge   -- nearest assumed-occupied partner within pair_max
    for _, cd in ipairs(Map.Camps() or {}) do
        if cd.camp ~= cand.camp and cd.center then
            local d = A:Distance(cd.center)
            if d > 200 and d <= pair_max
               and not is_cleared(Map.CampKey(cd.center)) and d < pd then
                partner, pd = cd, d
            end
        end
    end
    if not partner then State.pairSkip = "no_partner"; return nil end
    local B = partner.center
    local pc = Farm.PairClearClass(pd, { march_len = K.MARCH_LEN, disc = K.CREEP_DISC })  -- disc-model clear class (clean/clip) -> drives the lean-in budget
    -- PERPENDICULAR-cast model: ALWAYS stand at the MIDPOINT (aim = midpoint) and cast perpendicular to the
    -- camp line - the W's WIDTH (+/- MARCH_HALFWIDTH) spans BOTH camps regardless of terrain. The thin-box
    -- engage has perpendicular room, so a slightly-unwalkable midpoint still works from a nearby walkable
    -- spot; a truly-blocked one is skipped by the move watchdog. (Retired the along-axis PairStandCandidates
    -- + the walkable-midpoint/candidate fallback, which produced the inconsistent 'circle' fallback stand.)
    local mid = Vector((A.x + B.x) / 2, (A.y + B.y) / 2, A.z)
    if enemy_risk_at(mid) >= K.RISK_HARD then
        State.pairSkip = string.format("risk pd=%.0f pcamp=(%.0f,%.0f)", pd, B.x, B.y); return nil
    end
    return { stand = mid, aim = mid, paired = true, partner = B,
             partnerCamp = partner.camp, partnerType = partner.type, clear = pc.class, pd = pd }
end

-- Single-camp stand (pairing is decided upstream in gather_route_targets now, so this is single-only;
-- pair_spot_for is retained for the run_pair_test diagnostic). Stand WITHIN March's cast range of the
-- camp CENTRE and cast W onto it: neutrals cluster at the spawn point (~centre), so March's spawn covers
-- them and the hero has vision (valid engage occupancy read). Search a few small rings x angles for a
-- walkable, low-risk spot; ring order breaks ties toward the closest.
local function best_stand_spot(cand)
    local center = cand.center
    local best = nil
    for _, ring in ipairs({ K.STAND_RING, K.STAND_RING + 50, K.STAND_RING - 60 }) do
        for ang = 0, 360 - K.STAND_STEP, K.STAND_STEP do
            local rad = math.rad(ang)
            local s = Vector(center.x + ring * math.cos(rad),
                             center.y + ring * math.sin(rad), center.z)
            if Map.Walkable(s) then
                local score = -enemy_risk_at(s) * 5   -- safest spot; ring order prefers the closest on ties
                if not best or score > best.score then
                    best = { stand = s, aim = center, score = score }
                end
            end
        end
    end
    return best
end

-- (march_cast_point - the single-aim clamp - was deleted, glue review F3a: no callers,
-- march_cast_point_multi is the one cast-point builder.)

-- Standardized W cast: the March box is a ~1800 SQUARE centred on the cast point (no facing), so coverage
-- depends only on WHERE we cast. Successive casts ROTATE the offset 90 deg (a +/cross around the cluster
-- centre) to spread the robot-spawn area over the creeps for max hits, instead of stacking identical boxes.
-- The offset (MULTI_W_OFFSET << the 900 box half) keeps the cluster covered from every point; a wide pair
-- just gets each camp favoured on alternate casts + aggro pulls the rest in. Base axis: pair -> the camp
-- line (A->B), single -> perpendicular to hero->camp. Clamped to March cast range so the order fires.
local function march_cast_point_multi(s, idx)
    local ss = s.standSpot
    local me = origin(State.hero)
    local aim = ss.aim or s.center                                          -- the cluster (camp centre / pair midpoint)
    -- base direction: pair -> the camp line (A->B); single -> Tinker toward the camp.
    local ux, uy
    if ss.paired and ss.partner then
        ux, uy = ss.partner.x - aim.x, ss.partner.y - aim.y
    else
        ux, uy = aim.x - me.x, aim.y - me.y
    end
    local ul = math.sqrt(ux * ux + uy * uy)
    if ul < 1 then ux, uy = 1, 0 else ux, uy = ux / ul, uy / ul end
    local ang = math.rad(90 * idx)                                          -- rotate the direction 90 deg per cast (+/cross)
    local ca, sa = math.cos(ang), math.sin(ang)
    local rx, ry = ux * ca - uy * sa, ux * sa + uy * ca
    -- cast CLOSE to Tinker in that (rotated) direction: the ~1800 box covers the cluster from right next to
    -- Tinker, so a small offset is reliable (in cast range, robots sweep THROUGH the camp) vs a 300 off-centre push.
    local target = Vector(me.x + rx * K.MULTI_W_OFFSET, me.y + ry * K.MULTI_W_OFFSET, aim.z)
    local maxr = (K.MARCH_CAST_RANGE or 300) - 20
    if me:Distance(target) > maxr then return me + (target - me):Normalized() * maxr end
    return target
end

-- ── one-press pair test ──────────────────────────────────────────────────────
-- The funnel only visits ~3 high-value camps per run, so this evaluates EVERY camp's
-- pairing NOW (real walkability + the full-list partner search) and logs + overlays the
-- result, checking all pairs in one keypress. Ignores is_cleared (tests regardless of
-- recent farming); restores it after. pcall-guarded so one bad camp can't abort the pass.
local function run_pair_test()
    State.fog = enemy_snapshot()                       -- fresh risk snapshot for the test
    local saved = State.cleared; State.cleared = {}
    local results, nPair, nSkip, nClean, nClip = {}, 0, 0, 0, 0
    for _, cd in ipairs(Map.Camps() or {}) do
        local cand = { camp = cd.camp, center = cd.center, type = cd.type, box = cd.box }
        local ok, ps = pcall(pair_spot_for, cand)
        local r = { center = cd.center, tier = cd.type }
        if ok and ps then
            nPair = nPair + 1
            r.paired, r.partner, r.stand, r.cast = true, ps.partner, ps.stand, ps.aim
            local pd = cd.center:Distance(ps.partner)                              -- disc-model clear class (calibration readout)
            local pc = Farm.PairClearClass(pd, { march_len = K.MARCH_LEN, disc = K.CREEP_DISC })
            r.clear, r.fullm, r.pd = pc.class, pc.full_margin, pd
            if pc.class == "clean" then nClean = nClean + 1 else nClip = nClip + 1 end
            logline(string.format("pairtest %s (%.0f,%.0f) PAIR clear=%s fullm=%.0f d=%.0f pcamp=(%.0f,%.0f) stand=(%.0f,%.0f) cast=(%.0f,%.0f)",
                tostring(cd.type), cd.center.x, cd.center.y, pc.class, pc.full_margin, pd, ps.partner.x, ps.partner.y,
                ps.stand.x, ps.stand.y, ps.aim.x, ps.aim.y))
        else
            nSkip = nSkip + 1
            r.paired = false; r.reason = (not ok) and "error" or (State.pairSkip or "?")
            logline(string.format("pairtest %s (%.0f,%.0f) SKIP %s",
                tostring(cd.type), cd.center.x, cd.center.y, tostring(r.reason)))
        end
        results[#results + 1] = r
    end
    State.cleared = saved
    State.pairTestResults, State.pairTestUntil = results, now() + K.TEST_OVERLAY_SEC
    logline(string.format("pairtest SUMMARY camps=%d paired=%d (clean=%d clip=%d) skipped=%d", #results, nPair, nClean, nClip, nSkip))
end

-- Mark the CURRENT hero position as "a pair IS farmable from here" (for a camp pair the tool flags single).
-- Records the hero pos + the TWO nearest camps (the pair being asserted) + their inter-distance, logs it,
-- and drops a persistent magenta marker (draw_pair_marks). Feeds a pair_max / pairing recalibration.
local function mark_pairable()
    local me = origin(State.hero)
    local c1, d1, c2, d2 = nil, math.huge, nil, math.huge     -- two camps nearest the hero
    for _, cd in ipairs(Map.Camps() or {}) do
        if cd.center then
            local d = cd.center:Distance(me)
            if d < d1 then c2, d2, c1, d1 = c1, d1, cd, d
            elseif d < d2 then c2, d2 = cd, d end
        end
    end
    State.pairMarks = State.pairMarks or {}
    local d12 = (c1 and c2) and c1.center:Distance(c2.center) or -1
    State.pairMarks[#State.pairMarks + 1] = { pos = { x = me.x, y = me.y, z = me.z },
        c1 = c1 and c1.center, t1 = c1 and c1.type, c2 = c2 and c2.center, t2 = c2 and c2.type, d12 = d12 }
    local pair_max = math.min(K.PAIR_RADIUS, K.MARCH_LEN - 2 * math.abs(K.MARCH_PAIR_OFFSET))
    logline(string.format("pairmark #%d hero=(%.0f,%.0f) camp1=(%.0f,%.0f) t1=%s camp2=(%.0f,%.0f) t2=%s d12=%.0f pair_max=%.0f",
        #State.pairMarks, me.x, me.y,
        (c1 and c1.center.x) or 0, (c1 and c1.center.y) or 0, tostring(c1 and c1.type),
        (c2 and c2.center.x) or 0, (c2 and c2.center.y) or 0, tostring(c2 and c2.type), d12, pair_max))
end

-- ── lane scan (Wave-scan diagnostic; consumes lib/lane, no farm behaviour) ────
-- Keen Conveyance allowed teleport kinds by ability level (the only Tinker-specific gate;
-- user-stated lvl gates, confirm vs KV in-client). buildings/outposts always; +creep at L2;
-- +ally at L3. Isolated here so a wrong gate is a one-line fix, never a lib change.
local function keen_allowed_kinds()
    local lvl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
    local kinds = { "building", "outpost" }
    if lvl >= 2 then kinds[#kinds + 1] = "creep" end
    if lvl >= 3 then kinds[#kinds + 1] = "ally" end
    return kinds
end

-- static teleport anchors: friendly buildings (live) + friendly outposts (map_data). lib/lane
-- augments these with creep/ally anchors from its own scan per allowed_kinds.
local function static_anchors()
    local out = {}
    for _, e in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}) do
        if Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
            local p = Entity.GetAbsOrigin(e)
            if p then out[#out + 1] = { pos = { x = p.x, y = p.y }, ready = true, kind = "building" } end
        end
    end
    for _, o in ipairs(MapData.OUTPOSTS or {}) do
        if o.team == State.team and o.pos then
            out[#out + 1] = { pos = { x = o.pos[1], y = o.pos[2] }, ready = true, kind = "outpost" }
        end
    end
    return out
end

-- (keen_anchor_set - static anchors + allied creeps at Keen L2 for travel ETAs - was deleted,
-- glue review F3b: built for the creep-keen reach but never wired to a consumer. Re-add WITH
-- its consumer when the creep/BoT reach landing feature lands; the shape is in git history.)

-- push directions toward the enemy base (constant per team) from the static fountains.
local function lane_push_dirs()
    local ours, theirs
    for _, f in ipairs(MapData.FOUNTAINS or {}) do
        if f.team == State.team then ours = f.pos else theirs = f.pos end
    end
    if not (ours and theirs) then return { x = 1, y = 1 }, { x = -1, y = -1 } end
    local ally_push  = { x = theirs[1] - ours[1], y = theirs[2] - ours[2] }   -- our creeps push to the enemy base
    local enemy_push = { x = ours[1] - theirs[1], y = ours[2] - theirs[2] }   -- enemy creeps push to our base
    return enemy_push, ally_push
end

-- Piece 1.5: lane axis polylines (static towers + captured spawns), built ONCE (statics don't move).
-- Fed to ScanLanes for the arc-length fogged-wave mirror + drawn on the wavescan overlay.
local function lane_paths()
    State.lanePaths = State.lanePaths or Lane.BuildLanePaths(MapData.TOWERS, MapData.SPAWNS)
    return State.lanePaths
end

-- v0.1.256 arc B: stamp measured front speeds onto the wave records of a fresh scan. Only
-- REAL fronts are tracked (a mirrored estimate's front derives from OUR wave - measuring it
-- is circular); the measurement is capped at the stat (noise cannot exceed the possible).
local function annotate_measured(lanes)
    if not lanes then return lanes end
    for _, ln in ipairs({ "top", "mid", "bot" }) do
        local s = lanes[ln]
        if s then
            for side, w in pairs({ enemy = s.enemy_wave, ally = s.ally_wave }) do
                if w and w.front and not w.estimated then
                    local spd
                    State.frontTrack, spd = Lane.TrackFrontSpeed(State.frontTrack, ln .. ":" .. side, w.front, now())
                    if spd then
                        local stat = w.speed
                        if not stat then
                            for _, cc in ipairs(w.creeps or {}) do if cc.speed and (not stat or cc.speed > stat) then stat = cc.speed end end
                        end
                        w.speed_measured = math.min(spd, stat or 325)
                    end
                end
            end
        end
    end
    return lanes
end

-- arm_overlay: true (from the bind) keeps the visual overlay up for TEST_OVERLAY_SEC; the automatic
-- caller passes false so it LOGS the all-lanes wavescan every tick-cadence without forcing the overlay on.
local function run_lane_scan(arm_overlay)
    local enemy_push, ally_push = lane_push_dirs()
    local me = origin(State.hero)
    local lanes = Lane.ScanLanes({
        team = State.team, enemy_push = enemy_push, ally_push = ally_push,
        anchors = static_anchors(), allowed_kinds = keen_allowed_kinds(),
        hero_pos = { x = me.x, y = me.y },
        move_speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320,
        tp = keen_tp(),   -- v0.1.230: ladder-aware (rearm-first when keen is down; nil = walk pricing)
        game_time = now(),   -- fog-fill: ExpectedWave estimate for unseen lanes. NOTE now()=GameRules.GetGameTime(); confirm it is the GAME CLOCK (0:00=first wave) vs engine time in-client (affects wave parity).
        paths = lane_paths(),   -- Piece 1.5: fogged enemy waves get position/speed via the arc-length mirror
    })
    annotate_measured(lanes)   -- v0.1.256 arc B: measured front speeds ride the records
    State.laneScan = lanes
    if arm_overlay then State.laneScanUntil = now() + K.TEST_OVERLAY_SEC end
    -- v0.1.246 tower registry feed (TINKER_TOWER_DEATH_DESIGN.md): one sampling pass per
    -- 2s scan over the static spots. Buildings are always visible, so a spot with no alive
    -- entity AFTER having been seen alive = the tower is gone (the lib latches it forever).
    do
        local samples = {}
        for _, t in ipairs(MapData.TOWERS or {}) do
            if t.pos and t.name and t.team then
                local key = t.name .. "@" .. tostring(t.team)
                local ent
                for _, e in ipairs(Map.TowersInRadius(Vector(t.pos[1], t.pos[2], 0), K.TOWER_ALIVE_R) or {}) do
                    if Entity.GetTeamNum(e) == t.team and Entity.IsAlive(e) then ent = e; break end
                end
                if ent then
                    samples[#samples + 1] = { key = key, hp = Entity.GetHealth(ent), alive = true }
                elseif Map.Towers.Alive(State.towerTrack, key) then
                    samples[#samples + 1] = { key = key, alive = false }
                end
            end
        end
        State.towerTrack = Map.Towers.Track(State.towerTrack, samples, now())
    end
    -- Piece 1 (lane instruments, TINKER_LANE_NAV_DESIGN.md roadmap): CLEAN k=v rows + the truth
    -- fields (fronts/meeting/hp/prediction) so the offline `--lane-report` can measure each wave
    -- instrument against observed reality: arrival timing vs NextWaveArrival (+ the real spawn-grid
    -- phase), ExpectedWave hp truth at est->real transitions, and meeting drift. The old prose
    -- format was not machine-parseable (the analyzer splits strict k=v); the overlay is unaffected
    -- (it draws from State.laneScan).
    local pred = Lane.Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT.mid)
    -- Piece 1.5: KINEMATIC arrival candidate on trial next to the spawn-grid pred. With the mirror,
    -- both mid fronts (real or mirrored) + live-read speeds exist, so the meeting ETA is pure
    -- kinematics - no spawn-clock guess. --lane-report judges pred vs kpred head-to-head; the
    -- decision input only switches after the data says so (Piece 2).
    local kpred = -1
    do
        local s = lanes.mid
        local ew, aw = s.enemy_wave, s.ally_wave
        local espd, aspd = Lane.WaveSpeed(ew), Lane.WaveSpeed(aw)
        if ew and ew.front and aw and aw.front and espd and aspd then
            local pm = Lane.PredictMeeting({ pos = ew.front, speed = espd }, { pos = aw.front, speed = aspd })
            if pm then kpred = now() + pm.eta end
        end
    end
    logline(string.format("wavescan SCAN t=%.1f wave=%d pred=%.1f kpred=%.1f lastw=%s",
        now(), math.floor(now() / 30) + 1, pred or -1, kpred,
        State.laneWaveT.mid and string.format("%.1f", State.laneWaveT.mid) or "-"))
    local function pt(p) return p and string.format("%.0f;%.0f", p.x, p.y) or "-" end
    for _, ln in ipairs({ "top", "mid", "bot" }) do
        local s = lanes[ln]
        local ew, aw = s.enemy_wave, s.ally_wave
        -- v0.1.345 FIX B PERSISTENCE: ew.count is the NON-DORMANT slice (lib/lane.lua _read_lane_creeps skips
        -- IsDormant), so a partially-fogged FULL wave can momentarily read 1 at the vision edge -
        -- vetoing on that raw read is the v0.1.80 partial-fog class. This 2s scan runs
        -- unconditionally, so stamp when the lone read STARTS and clear it the instant the count
        -- rises; the producers require the stamp to have held THIN_CREEPS_HOLD_S. A genuine
        -- remnant stays count=1 for tens of seconds; a vision-edge read resolves within ~1s.
        if ew and not ew.estimated and (ew.count or 0) > 0
           and (ew.count or 0) <= K.SHOVE_THIN_CREEPS then
            State.loneSince[ln] = State.loneSince[ln] or now()
        else
            State.loneSince[ln] = nil
        end
        local comp = (ew and ew.estimated)
            and string.format("m%dr%ds%df%d", ew.melee or 0, ew.ranged or 0, ew.siege or 0, ew.flagbearer or 0)
            or "-"
        local push = s.clash and (s.clash.pushing .. (s.clash.moving and "" or "/hold")) or "none"
        local crash = "-"
        if s.clash and s.clash.crashing and s.clash.crash_tower then
            crash = (s.clash.crash_tower.team == State.team) and "allyTwr" or "enemyTwr"
            -- v0.1.263 STICKY CRASH MEMORY (run-76 t~1860: an 8-9 creep ~415g wave ate our
            -- bot T2 while every DECIDE sampled a crash=- instant - the flag flickers as the
            -- creep fight moves the settle; swbot read slack/no_fit, defend never fired =
            -- the run-58 watch item come true). This 2s scan runs unconditionally, so the
            -- stamp remembers a crash BETWEEN decides; the defend conditions consume it.
            if crash == "allyTwr" then
                State.crashSeen = State.crashSeen or {}
                State.crashSeen[ln] = now()
            end
        end
        -- v0.1.385 TOWER-THREAT STAMP. USER-WATCHED (g382): three jungle trips while a wave sat on
        -- our own mid T1. THE CLASH MODEL CANNOT SEE THIS, in two independent ways, and BOTH
        -- PREDATE v0.1.383, which only ever narrowed WHICH tower gets named:
        --   1. `crashing` is computed ONLY inside `if moving then` (lib/lane.lua), and `moving`
        --      needs |b| >= move_threshold 0.1. A wave PARKED at our tower reads push=even/hold,
        --      which is the most dangerous state there is - it is eating the tower - and it is
        --      therefore structurally unflaggable. Two of the three g382 episodes are this.
        --   2. When the contact DOES sit inside a tower's range, opts.tower_weight 4000 is added to
        --      THAT tower's own side, flipping b and making defend_team the OTHER team, so our
        --      tower excludes itself. The third episode is this.
        -- g382 logged allyTwr=0 for the ENTIRE game while e=4 hp=1933 sat 833u off our mid T1 and
        -- e=6 hp=2408 push=enemy sat 944u off it, both with alH=0, and Tinker took camps at
        -- t=412.7 and t=496.2. This asks the question the scheduler actually needs straight from
        -- geometry, and feeds the EXISTING sticky-crash hook instead of inventing a second defend
        -- pathway - every consumer and CRASH_STICKY_S already work. Consumers, by SHAPE not line
        -- number (they shift): the two defend_crash conditions, and crash_fresh_any, which is NOT a
        -- defend - it terminates the v0.1.339 cycle park and it iterates ALL lanes, so a mid stamp
        -- kills a park. That consumer is unmeasured; see the queue.
        -- HOME LANE ONLY, DELIBERATELY. Calibrated over six logs the same rule fires mid 11 / top 7
        -- / bot 9, and a side-lane defend is a TRIP AWAY FROM MID, which is the v0.1.312 direction
        -- that costs games (g376 alone would add 7 bot trips). On MID a defend is very nearly the
        -- shove he already owed, so the cost is near zero. Widen only after this validates.
        -- Requires a LIVE tower: MapData is static, so a destroyed tower's ground would otherwise
        -- keep firing for the rest of the game. Same alive idiom as enemy_lane_t1 and the tower registry feed.
        -- v0.1.387 STRENGTH GUARD (adversarial review of v0.1.385, CONFIRMED defect). The v0.1.385
        -- trigger was count + geometry ONLY, with nothing about wave POWER or direction, and it fed
        -- defend_crash, which Lane.Schedule.Plan runs LAST over thin_wave / far_wave / gone_by_arrival
        -- and therefore overrides every economic veto. Measured on g383: 12 logged firings, of which
        -- ONE was a 3-creep wave holding 66 HP in total, and NINE read push=ally, meaning our own
        -- side was winning at the tower - the opposite of a threat. At t=822.7 a stamp on
        -- e=3 hp=1104 push=ally bal=3 became the game's only defend 6.3s later and pulled Tinker
        -- 3.8s across the map, straight off a finished top shove, to March two dying creeps
        -- (eff_hp 285, under the SHOVE_THIN_EFFHP 400 bar that had correctly vetoed it).
        -- So: a wave under the thin bar is not a threat, and a wave our side is actively pushing
        -- AWAY is not a threat. `even/hold` is deliberately KEPT - a wave parked at the tower is
        -- the dangerous state and is exactly what v0.1.385 was built to see.
        -- VERIFIED OFFLINE BEFORE SHIPPING, unlike the v0.1.385 calibration: on g382 this holds
        -- both watched episodes (the parked e=4 hp=1933 and the e=6 hp=2408 push=enemy) while
        -- dropping 11 stamps to 8; on g383 it drops 19 stamps to 4, all four push=enemy at hp
        -- 1351-1466, which brings the fire rate back inside the intended band.
        -- v0.1.390 RULER FIX (review finding, CONFIRMED, bug class 3). The threat is measured
        -- TOWER-to-wave-front, but the no-ally gate used s.ally_heroes, which lib/lane.lua counts
        -- within hero_radius 1200 of clash.CONTACT - the midpoint of the two fronts, a different
        -- place. When our own wave sits far back the contact slides thousands of units behind the
        -- threatened tower: measured 2163u and 1616u apart on real g383 rows, so an ally standing
        -- ON the tower was invisible to the gate and the stamp fired anyway. That is the operator's
        -- own stated revert trigger. Second half: lib/lane.lua _read_heroes does NOT filter the
        -- local hero, so ally_heroes counted TINKER, and the stamp stopped refreshing the moment he
        -- arrived, dropping the defend pin CRASH_STICKY_S later, mid-defence.
        -- Both are fixed by asking the question where it actually matters: is another ALLY hero
        -- near THIS TOWER. Hero-local on purpose - s.ally_heroes is shared-lib and feeds other
        -- consumers, so it is left alone.
        -- ally_near_tower is evaluated per candidate tower below, inside the range branch.
        if ln == K.HOME_LANE and K.TOWER_THREAT_R > 0 and ew and not ew.estimated and ew.front
           and (ew.count or 0) >= K.TOWER_THREAT_MINC
           and (ew.hp or 0) >= K.SHOVE_THIN_EFFHP
           and not (s.clash and s.clash.pushing == "ally") then
            for _, t in ipairs(MapData.TOWERS or {}) do
                if t.team == State.team and t.pos and t.name and t.name:find("_" .. ln, 1, true) then
                    local dx, dy = t.pos[1] - ew.front.x, t.pos[2] - ew.front.y
                    if dx * dx + dy * dy <= K.TOWER_THREAT_R * K.TOWER_THREAT_R then
                        -- is another ALLY hero (never Tinker himself) near THE TOWER?
                        local allyNear = false
                        for _, hh in ipairs(Heroes.GetAll() or {}) do
                            if hh ~= State.hero and Entity.IsAlive(hh)
                               and Entity.GetTeamNum(hh) == State.team
                               and (not NPC.IsIllusion or not NPC.IsIllusion(hh)) then
                                local hp2 = (not Entity.IsDormant(hh)) and Entity.GetAbsOrigin(hh)
                                            or (Hero.GetLastMaphackPos and Hero.GetLastMaphackPos(hh))
                                if hp2 then
                                    local ax, ay = hp2.x - t.pos[1], hp2.y - t.pos[2]
                                    if ax * ax + ay * ay <= K.TOWER_THREAT_R * K.TOWER_THREAT_R then
                                        allyNear = true; break
                                    end
                                end
                            end
                        end
                        local live = not allyNear
                        if not allyNear then
                            live = false
                            for _, te in ipairs(Map.TowersInRadius(Vector(t.pos[1], t.pos[2], 0), K.TOWER_ALIVE_R) or {}) do
                                if Entity.GetTeamNum(te) == State.team and Entity.IsAlive(te) then live = true; break end
                            end
                        end
                        if live then
                            State.crashSeen = State.crashSeen or {}
                            State.crashSeen[ln] = now()
                            -- v0.1.391: THROTTLE REMOVED. It was 2.0s against a ~2.0s scan, so it
                            -- hid about 37% of stamps, and this count is load-bearing: it is the
                            -- denominator for every conversion rate on this arc and the correction
                            -- that makes the analyzer's miss counts an upper bound. Real volume is
                            -- ~19 lines/game at the worst observed rate, which is nothing.
                            do
                                -- oldgate = what the retired contact-centred, self-counting gate
                                -- would have said. differ=1 means the two rulers disagreed on this
                                -- row; that is the measurement this fix exists to make.
                                local oldg = (s.ally_heroes or 0) == 0
                                logline(string.format(
                                    "tower_threat ln=%s e=%d hp=%d d=%.0f twr=%s modelcrash=%s alH=%d oldgate=%s differ=%d",
                                    ln, ew.count or 0, math.floor(ew.hp or 0),
                                    math.sqrt(dx * dx + dy * dy), t.name, crash,
                                    s.ally_heroes or -1, tostring(oldg), oldg and 0 or 1))
                            end
                            break
                        end
                    end
                end
            end
        end
        -- Piece 1.5 push model: per-lane BALANCE from the attrition sim (bal = net survivors of the
        -- current fight, + = OUR lane pushes; peta = predicted fight-end time). Instrumentation on
        -- trial: --lane-report judges bal against the OBSERVED front movement in the same log.
        local bal, peta = "-", "-"
        -- v0.1.393 THE FIGHT STAMP (4b-A, USER-WATCHED twice). Clear-then-restamp = freshest-read
        -- semantics: any scan without contact (fronts apart, wave gone, fogged) clears the lane.
        State.fightSeen = State.fightSeen or {}
        State.fightSeen[ln] = nil
        if ew and aw then
            local pf = Lane.PushForecast(aw, ew, { cycle = math.min(30, math.floor(now() / 450)),
                                                   game_time = now(), rounds = 1 })
            bal  = string.format("%d", pf.bal or 0)
            peta = string.format("%.1f", now() + (pf.first_t or 0))
            -- The stamp: a REAL read (est=n), both fronts present, in contact, AND the sim says the
            -- fight outlasts the lead horizon. pf.first_t is SIM output admitted ONLY as a trim
            -- that NARROWS the defer set (contact must independently hold; absent/false sim yields
            -- today's behaviour bit-identically) - never a veto of an engage, never a clock, so the
            -- v0.1.241 estimates-never-veto law is untouched. COUPLING, deliberate: the threshold
            -- reuses K.W_LEAD_S, so a future W_LEAD_S recalibration silently moves the defer set -
            -- revisit this line if W_LEAD_S ever changes.
            if not ew.estimated and ew.front and aw.front
               and (ew.front.x - aw.front.x) ^ 2 + (ew.front.y - aw.front.y) ^ 2
                   <= K.FIGHT_CONTACT_R * K.FIGHT_CONTACT_R
               and (pf.first_t or 0) > K.W_LEAD_S then
                State.fightSeen[ln] = now()
            end
        end
        -- v0.1.363 INSTRUMENT (log-only): NAME THE CRASH TOWER AND ITS DISTANCE FROM THE CONTACT.
        -- crash=allyTwr is the predicate behind defend_crash, the most absolute verdict in the
        -- scheduler (it overrides every veto at Lane.Schedule.Plan and skips the round-trip
        -- window fit), and the tower it names has NEVER been logged: crashTwrPos is set
        -- only when cl.crash_tower.team ~= State.team (schedule_ctx, side_wave_ctx), so tower_key_near never sees
        -- the ally one. Offline reconstruction over 29 logs says the pick is wrong - flagged rows
        -- sit a median 2186u from the nearest ally tower against 2186u for unflagged ones, 0.0 pct
        -- within 700u against 4.5 pct of the control, and the named tower is in a DIFFERENT LANE on
        -- 64 pct of stamps - because lib/lane.lua PredictClash minimised the projection along drift_dir
        -- with NO perpendicular bound, over the full 24-tower list BuildLaneStates passed THEN
        -- (SINCE FIXED at lib/lane.lua v0.1.375, which passes towers_by_lane[lane] instead).
        -- ctp/ctd turn that reconstruction into a direct reading. NOTHING GATES ON THESE FIELDS.
        -- THE TOWER RECORD CARRIES NO NAME. lib/lane.lua _read_towers builds it from the LIVE engine
        -- (the ENGINE global Towers.GetAll), not from MapData.TOWERS, as { pos = {x,y}, team, range, alive } - so
        -- ct.key and ct.name are both nil and a key field would print "?" on every line and look
        -- like a working instrument. The POSITION is the identity: MapData.TOWERS names it offline.
        -- ctd IS THE MEASUREMENT. It is contact-to-tower, the SAME pair PredictClash projects, so
        -- the field and the gated quantity are one ruler (bug class 3). No fallback to s.meeting:
        -- crash_tower is non-nil only when that loop ran, and that loop dereferences contact, so a
        -- nil contact here is unreachable and a fallback could only ever switch rulers silently.
        -- ctr is the tower's attack range. It reads 700 on effectively every row (the engine value
        -- and the _read_towers fallback agree), so it is NOT a discriminator: it is there only to
        -- catch the day an engine read returns something else and quietly moves the bar.
        local ctp, ctd, ctr = "-", "-", "-"
        local ct = s.clash and s.clash.crash_tower
        if ct and ct.pos then
            ctp = pt(ct.pos)
            ctr = string.format("%.0f", ct.range or 0)
            local cpt = s.clash.contact
            if cpt then
                local dx, dy = ct.pos.x - cpt.x, ct.pos.y - cpt.y
                ctd = string.format("%.0f", math.sqrt(dx * dx + dy * dy))
            end
        end
        logline(string.format(
            "wavescan ln=%s e=%d est=%s src=%s comp=%s a=%d hp=%d gold=%d push=%s crash=%s ctp=%s ctd=%s ctr=%s bal=%s peta=%s eta=%s reach=%s enH=%d alH=%d ef=%s af=%s meet=%s",
            ln, ew and ew.count or 0, (ew and ew.estimated) and "y" or "n",
            (ew and ew.est_src) or "-", comp,
            aw and aw.count or 0, math.floor((ew and ew.hp) or 0), math.floor(s.gold or 0), push, crash, ctp, ctd, ctr, bal, peta,
            s.intercept and string.format("%.1f", s.intercept.eta) or "-",
            tostring(s.intercept and s.intercept.reachable), s.enemy_heroes, s.ally_heroes,
            pt(ew and ew.front), pt(aw and aw.front), pt(s.meeting)))
    end
end

-- ── route scan (Stage 0 diagnostic; consumes lib/route, NO farm behaviour) ────
-- Build the unified FarmTarget list (camps + visible lane waves) + run the planner, for the
-- "Route scan" overlay/log. The FSM is NOT touched: this only computes + shows the plan.
-- the hero's kinematic state for the planner (pos + move speed + Keen tp + static anchors).
-- mana to ENGAGE the next target = reach (Keen) + one March (gets value). The opportunistic Rearm +
-- 2nd March are NOT gated here: gating the full 2-March+Rearm clear (~540) would exceed early Tinker's
-- whole mana pool (~459), so no hop would ever be affordable -> the planner would loop on the refill
-- node. Running out mid-clear is handled by the in-engage mana bail.
-- v0.1.360: `full_clear` is OPT-IN and only the two SHOVE producers pass it. The third caller is
-- NOT a commit gate at all - it is the fountain TRIGGER (broke_bar -> Lane.Schedule.CycleFill), and
-- repricing it here would raise that trigger from the one-hop bar to the full-clear bar, which is
-- the v0.1.339 change this project measured at GPM 489 -> 356 and reverted with v0.1.340. Offline
-- replay of the first cut: 30-44% of lane-phase PARK decides flipped to a fountain trip, against a
-- shipped rule that fires twice in 26 logs. A parameter, not a new local: the main chunk is at the
-- 200-local ceiling.
local function hop_mana_cost(full_clear)
    local c = abil_mana(State.keen, K.KEEN_MANA_FB) + abil_mana(State.march, K.MARCH_MANA_FB)
    -- v0.1.200 (run-28 t=474.4): a shove committed right after a camp clear with March ON COOLDOWN
    -- at ~360 effective - the engage had to Rearm FIRST to get March back (225), landed at 48 mana,
    -- cast ZERO W and walked home; the wave waited ~25s for its Marches. When March is on cd the
    -- FIRST W costs a Rearm too, so the hop gate prices the true entry.
    -- v0.1.211: same for KEEN on cd (the ladder-aware raid transit rearms to reset it) - ONE
    -- Rearm resets both, so the term is added once.
    if (State.march and not ready(State.march)) or (State.keen and not ready(State.keen)) then
        c = c + abil_mana(State.rearm, K.REARM_MANA_FB)
    end
    -- v0.1.360 LANE-PHASE FULL-CLEAR PRICING (user doctrine, 2026-07-30: "using two Ws is the main
    -- idea because it makes more likely to not lose any creep. If we have time to refill, there is
    -- no reason to not do it on lane phase").
    -- THE DEFECT THIS FIXES, measured over 26 logs: 507 wave arrivals, 105 (20.7%) never cast a
    -- single March, and 32 (6.3%) took over 10s to start - and 32 of 32 of those slow starts had
    -- fired Rearm first. The shape is always the same: commit the trip at a price that covers ONE
    -- March, arrive, spend 225 on the Rearm that unlocks it, and find the March itself unaffordable
    -- (observed landing at 119 and 94 mana), so walk home with the wave unfarmed for ~28s. The
    -- v0.1.200 comment above describes this exact sequence at run-28 and priced the ENTRY Rearm to
    -- stop it; it did not price the SECOND March, so the trip is still committed too cheap.
    -- THE ERA IS THE RULER, NOT THE MANA POOL (user, same day: "early game or not early game is not
    -- the metric, lane phase and after lane phase is, and it depends on if enemy t1 is dead or
    -- not"). While their mid T1 stands the wave is the whole point and a refill is cheap; once it
    -- falls, deep farm is gold-per-time and a half-clear beats a fountain trip, which is what the
    -- v0.1.200 pricing already delivers. Same boundary the rest of the file calls deep_era.
    local rlvl = (Ability.GetLevel and State.rearm and Ability.GetLevel(State.rearm)) or 0
    if full_clear and rlvl >= 1 then
        -- Rearm is the ULTIMATE: below level 6 there is no 2-cast plan to price at all, and
        -- abil_mana would happily return the 225 fallback for an ability he does not own.
        if State.eraT ~= now() then
            -- memoised per decide: enemy_lane_t1 walks MapData.TOWERS and Map.TowersInRadius, and
            -- hop_mana_cost is called from three producers in the same decide.
            -- (folded inline rather than given its own helper: the main chunk is at Lua's
            -- 200-local ceiling, so a new top-level local is a compile failure, not a nit.)
            local _, t1alive = enemy_lane_t1(K.HOME_LANE)
            State.eraT, State.eraLane = now(), (t1alive == true)
        end
        if State.eraLane then
            local mcost = abil_mana(State.march, K.MARCH_MANA_FB)
            local rcost = abil_mana(State.rearm, K.REARM_MANA_FB)
            -- the 2-cast clear: March, Rearm, March - plus an ENTRY Rearm when March is on cd
            -- the disjunct MIRRORS the entry price above (v0.1.211): ONE Rearm resets both March and Keen, so an
            -- entry Rearm is owed whenever EITHER is down, not only March.
            local rearms = 1 + ((((State.march and not ready(State.march))
                                  or (State.keen and not ready(State.keen))) and 1) or 0)
            local full = abil_mana(State.keen, K.KEEN_MANA_FB) + 2 * mcost + rearms * rcost
            -- FEASIBILITY GUARD, and it is not an "early game" test: if the full clear costs more
            -- than the hero's MAXIMUM mana then no amount of refilling can ever satisfy it, and
            -- demanding it would loop the planner on the refill node forever - the deadlock the
            -- v0.1.200 comment warns about. Only require what a full pool could actually pay.
            local mmax = (NPC.GetMaxMana and NPC.GetMaxMana(State.hero)) or 0
            if mmax >= full + K.SHOVE_MANA_RESERVE and full > c then c = full end
        end
    end
    return c
end
local function mana_regen_read()
    local ok, v = pcall(function() return NPC.GetManaRegen and NPC.GetManaRegen(State.hero) end)
    return (ok and type(v) == "number" and v > 0) and v or K.MANA_REGEN_FALLBACK
end
local function hp_regen_read()
    local ok, v = pcall(function() return NPC.GetHealthRegen and NPC.GetHealthRegen(State.hero) end)
    return (ok and type(v) == "number" and v > 0) and v or K.HP_REGEN_FALLBACK
end

local function route_hero_state()
    local me = origin(State.hero)
    local h  = State.hero
    return {
        pos = { x = me.x, y = me.y },
        move_speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320,
        tp = keen_tp(),   -- v0.1.230: ladder-aware (the old .ready field was never consumed by InterceptETA)
        anchors = static_anchors(),
        -- live resources for the predictive next-hop gate (Note 4).
        -- v0.1.181 (mana review): EFFECTIVE mana (raw + Bottle charges), same as the SHOVE gate -
        -- the glue rebuild made charges count for shoves but the camp pipeline stayed raw, so a
        -- camp could read unaffordable while 1-3 drinkable charges (+60-180) covered it.
        -- v0.1.199 (run-27 refill-churn census): UNCAPPED. The v0.1.181 min(effective, max) cap made
        -- charges/items invisible exactly at full pool - the whole 663-pool era read a8/ok0 at FULL
        -- mana while 3 charges (+180) covered the 2-March+Rearm price (~675+reserve), freezing the
        -- jungle for ~2 min and feeding the fountain loop. Charges spend fine across a multi-cast
        -- clear (cast below max, then drink), so the honest planner number is raw + headroom.
        -- max_mana carries the SAME headroom so lib/route's regen/refill-node caps don't strip it
        -- (the fountain refills charges too, so the post-refill ceiling is honest).
        mana = effective_mana(),
        max_mana = (NPC.GetMaxMana(h) or 1) + math.max(0, effective_mana() - mana()),
        hp = Entity.GetHealth(h) or 1, max_hp = Entity.GetMaxHealth(h) or 1,
        mana_regen = mana_regen_read(), hp_regen = hp_regen_read(),
        reserve_mana = abil_mana(State.keen, K.KEEN_MANA_FB),   -- always retain Keen-home escape/return mana
        hp_floor = (Entity.GetMaxHealth(h) or 1) * K.HP_FLOOR_FRAC,
    }
end

-- planner opts (calibratable; now() is the game clock for the target windows).
local function route_opts()
    return { now = now(), horizon_s = K.ROUTE_HORIZON_S, max_steps = K.ROUTE_MAX_STEPS,
             risk_weight = K.ROUTE_RISK_WEIGHT, risk_hard = K.RISK_HARD, refill_frac = K.REFILL_FRAC,
             pool_cap = K.ROUTE_POOL_CAP,        -- #3: raise the DFS candidate cap off the lib default 10
             step_decay = K.ROUTE_STEP_DECAY,    -- v0.1.212: front-load value (bank the pair FIRST; later steps execute with p<1)
             max_leg_s = K.MAX_CAMP_TRAVEL_S }   -- #2: reachability guard (drop unreachable far camps)
end

local function our_farm_priority()
    local peers = {}
    for _, e in ipairs(Heroes.GetAll() or {}) do peers[#peers + 1] = e end
    local v = HeroValue.of(State.hero, peers)
    return HeroValue.FarmPriority({ role = nil, value = v })   -- role read = later flagged verify
end

-- Allies for the contest: pos + a FarmPriority value (camp value-contest) + a CORE flag (carry/mid/
-- offlane via HeroValue.IsCore = role-first, role-tag-base fallback). The lane contest yields to a
-- core ally or 2+ allies (Note 2); a lone support no longer blocks Tinker's lane.
-- v0.1.378 THE ALLY-POSITION CLASSIFIER. NO LONGER INERT as of v0.1.382: it writes State.posShadow and
-- two log lines and NOTHING ELSE READS EITHER. The live `core =` in ally_farm_priorities now READS State.posFinal. Its whole job
-- is to pre-register, before any behaviour ships, exactly which contest verdicts WOULD flip.
--
-- WHY IT EXISTS: HeroValue.role() is a stub returning nil (lib/hero_value.lua:222-224), so IsCore
-- falls through to the KV primary tag, and BOTH Earthshaker and Dazzle key Support 0.45 against
-- K.CONTEST_CORE_BASE 0.55. In g378 that left Juggernaut the only ally reading core, the Dire offlane
-- read `contested` 0 times in 28 evaluations (band elsewhere 35-73%), and Tinker made 8 bot
-- dispatches, 4 of them zero-cast, burning ~164s of a 678s window for 0 gold.
--
-- TWO SOURCES, PRIMARY FIRST (operator's architecture):
--  P1 the ENGINE: Player.GetTeamPlayer(p).starting_position, documented at
--     uczone-api-v2.0/game-components/core/player.md:142. NEVER CALLED BY THIS PROJECT, so the probe
--     below is the whole point: if it is populated, the elimination fallback is dead code and this
--     becomes a three-line read. JOIN VIA Players.GetAll + Player.GetAssignedHero, both documented -
--     NOT via NPC.GetPlayerOwner, which is undocumented and whose own note says it returns nil for AI
--     bots, i.e. exactly our games. That undocumented join is how the old "networth reads nil"
--     finding became unattributable: two unknowns collapsed into one conclusion.
--  P2 the FALLBACK: constraint elimination over lib/map.lua's Map.Positions PLAYABLE sets.
--
-- THE MID PIN: Tinker holds K.HOME_LANE, so position 2 is struck from every ally pool. That is an
-- ASSERTION, not a measurement, and it is logged so a mismatch is visible.
--
-- THE CORE BIT, and this is the part that matters: the consumer never wants a POSITION. `a.core` has
-- exactly two readers (eval_side_lanes, fsm_move_wave) and both hand the list to Farm.IsContestedByAlly, a first-match
-- OR of per-ally distance tests that never reads a hero name. So the question is only "does the whole
-- residual sit on one side of the 3/4 line". That answers the entire {4,5} class without resolving
-- anything, which is 99.0% of all unresolvable pairs.
-- AN EMPTY RESIDUAL IS UNDETERMINED, NEVER "not core" (elimination contradiction, ~5% of drafts).
-- v0.1.379 THE OBSERVED-LANE TALLY (LIVE since v0.1.382, via the stage-2 commit). The operator's own rule, and the half v0.1.378 did not
-- build: "if a hero is on mid on lane phase alone we can be certain that hero is being played as mid
-- on that match (this doesn't mean the hero is usually played on mid)".
-- WHY IT IS NOT OPTIONAL, operator 2026-08-13: "depending on the type of the match it will come
-- populated and depending it will not. We have both types of match on dota, this is why we've built a
-- fallback. So we need to have both anyways." A populated starting_position in ONE match type proves
-- nothing about the types that do not populate it, so the observed path is a permanent peer of the
-- engine path, not a contingency.
-- SAMPLING WINDOW t=60..300. NOT earlier: creeps meet around 0:40-1:00 and before that allies are
-- still walking out, sitting on runes or warding, so a 0:30 snapshot reads travel, not lane. NOT
-- later: by ~10:00 lane phase is dissolving and a pos-5 starts roaming, which is exactly the drift
-- that makes a match-level label go stale.
-- SUSTAINED OCCUPANCY, NOT A SNAPSHOT. Lane._assign_lane is a coarse diagonal band that accepts about
-- 38 pct of the map and whose mid region contains the ROSHAN PIT and the river centre, so a warding
-- or Rosh-watching support accumulates mid samples. A single sample is therefore worthless and only a
-- dominant share over many samples means anything. That same coarseness is why this feeds POSITION
-- PINNING ONLY and must never reach the contest veto directly - that conflation is the v0.1.312
-- regression (74 false contested verdicts).
-- NOTE ON PLACEMENT (v0.1.379): the observed-lane helpers live in lib/map.lua as
-- Map.Positions.ObservedLane and Map.Positions.LaneSlots, and the per-tick tally is INLINED into ally_farm_priorities
-- below. That is not stylistic. The main chunk sits AT Lua's 200-local ceiling and adding three more
-- top-level `local function`s threw "too many local variables (limit is 200)" at luac. Pure position
-- logic belongs in the lib anyway; only the tally needs hero-local State/now/Lane, and it is four
-- lines at the one site that already has both the ally name and its position in scope.
-- HEADROOM LIFT WAVE 2 (refactor-only, zero behaviour change): the residual-set solver that used to
-- sit right here as a top-level `pos_shadow` moved to lib/map.lua as Map.Positions.Shadow, for the
-- same ceiling reason and to join the two helpers above.

-- one-shot engine probe: is starting_position actually populated? pcall'd because every call here is
-- documented but UNEXERCISED by this project, and a nil-index in the decide path would cost a tick.
local function pos_probe()
    if State.posProbed then return end
    State.posProbed = true
    local ok, err = pcall(function()
        for _, p in ipairs((Players and Players.GetAll and Players.GetAll()) or {}) do
            local h  = Player.GetAssignedHero and Player.GetAssignedHero(p)
            local nm = h and NPC.GetUnitName and NPC.GetUnitName(h) or "-"
            local tp = Player.GetTeamPlayer and Player.GetTeamPlayer(p)
            logline(string.format("apos_probe hero=%s team=%s sp=%s lh=%s nw=%s",
                tostring(nm),
                tostring(h and Entity.GetTeamNum and Entity.GetTeamNum(h) or "-"),
                tostring(tp and tp.starting_position or "nil"),
                tostring(tp and tp.lasthit_count or "nil"),
                tostring(tp and tp.networth or "nil")))
            -- v0.1.380: keep the ENGINE answer when it is real, so the commit below can prefer it.
            -- A starting_position of 0 or nil means this match type does not ship one.
            local sp = tonumber(tp and tp.starting_position)
            if nm ~= "-" and sp and sp >= 1 and sp <= 5 then
                State.posEngine = State.posEngine or {}
                State.posEngine[nm] = sp
            end
        end
    end)
    if not ok then logline("apos_probe FAILED err=" .. tostring(err)) end
end

-- v0.1.380 THE COMMIT LATCH. Operator: "since we know that the position remains the same for the
-- rest of the match we have to check, set and not change afterwards." So the assignment is
-- WRITE-ONCE. State.posFinal is set exactly once per match and every later call is a no-op; there is
-- no revision path, deliberately, because a label that can flip mid-match is worse than a stale one
-- (a consumer would see the contest verdict for a lane change under it with no event to explain it).
-- SOURCE PRECEDENCE: engine starting_position beats the observed+draft fallback, because it is ground
-- truth where it exists. The fallback is NOT a contingency - the operator's point is that some match
-- types ship the field and some do not, so both paths are permanent.
-- LIVE AS OF v0.1.382: State.posFinal IS READ by the core= expression in ally_farm_priorities.
-- This is no longer an observation-only structure; a wrong bit here now changes lane contest.
-- v0.1.382: PER-ALLY write-once, not all-or-nothing. Each ally latches the first time its bit is
-- DETERMINED and is never rewritten; allies still undetermined stay open for a later stage.
-- WHAT ACTUALLY ENFORCES the operator's set-and-never-change rule: THE nil-GUARD BELOW, nothing else.
-- CORRECTION, and read this before relaxing anything here. An earlier version of this comment argued
-- that stage 2 intersects the observed lane INTO the stage-1 residual, so R2 is a subset of R1 and a
-- determined bit can never reverse. THAT PROOF IS FALSE. `local resid = Map.Positions.Shadow(names)` runs FRESH
-- at BOTH stages and R1 is never stored anywhere, so the real relation is
-- R2 = Shadow(names@stage2) intersect LaneSlots, and R2 subset R1 holds only if
-- Shadow(names@stage2) subset Shadow(names@stage1). Nothing in the code enforces that.
-- It is nevertheless SAFE, for a different and weaker reason: Shadow is a PURE function of `names`
-- (lib/map.lua, static lookups, no clock/State/engine), so an unchanged roster recomputes
-- R1 exactly. Measured offline over ~16.1k stable-roster ally-cases: ZERO contradictions of a
-- stage-1 determined bit. Every contradiction found required the ROSTER to change between stages,
-- and there the guard below simply keeps the stage-1 answer - which is the better-informed one,
-- because a shrunk roster means FEWER elimination constraints, i.e. a WIDER residual.
-- So: the reversal-proofing is the write-once guard, NOT a subset relation. Do not "revise the latch
-- when the observed lane is strong" on the strength of the old argument - the code cannot support it.
-- Straddles are still held back to stage 2, because the policy defaults them to CORE while the
-- observed lane may resolve them to support, and that IS a real flip.
-- WHY IT MATTERS: the commit used to land only at stage 2, t>=300. The g378 defect episodes this
-- whole arc exists to fix ran at t=52.4, 142.8, 408.6 and 661.5, so a t=300 latch would have missed
-- HALF of them. Determined-at-stage-1 covers the early lane phase, which in g380 was all four allies.
local function pos_commit(src, bits)
    State.posFinal = State.posFinal or {}
    local parts = {}
    for n, v in pairs(bits) do
        if State.posFinal[n] == nil then
            State.posFinal[n] = v
            parts[#parts + 1] = n .. "=" .. tostring(v)
        end
    end
    if #parts == 0 then return end
    table.sort(parts)
    logline(string.format("pos_commit src=%s n=%d %s", src, #parts, table.concat(parts, " ")))
end

local function ally_farm_priorities()
    local out, peers = {}, {}
    for _, e in ipairs(Heroes.GetAll() or {}) do peers[#peers + 1] = e end
    for _, e in ipairs(Heroes.GetAll() or {}) do
        if e ~= State.hero and Entity.GetTeamNum(e) == State.team and Entity.IsAlive(e) then
            local p = (not Entity.IsDormant(e)) and origin(e) or Hero.GetLastMaphackPos(e)
            if p then
                local name = (NPC.GetUnitName and NPC.GetUnitName(e)) or nil
                -- v0.1.382: hoisted out of the constructor so this is a plain lookup per ally, not a
                -- closure built every decide tick.
                local pc = State.posFinal and State.posFinal[name]
                if pc == nil then pc = HeroValue.IsCore(e, name, K.CONTEST_CORE_BASE) end
                out[#out + 1] = {
                    pos = p,
                    value = HeroValue.FarmPriority({ role = HeroValue.role(e), value = HeroValue.of(e, peers) }),
                    -- v0.1.382 THE WIRING. This is the one behavioural line of the position arc.
                    -- PRECEDENCE: committed position bit, else today's KV-tag path, then the
                    -- observed-farmer OR on top of whichever answered.
                    -- WHY THE POSITION BIT WINS: HeroValue.role() is a stub returning nil, so IsCore
                    -- falls through to the KV primary tag, and that tag is wrong for exactly the
                    -- heroes that cost us games - g378's Earthshaker keyed Support 0.45 against
                    -- CONTEST_CORE_BASE 0.55 while genuinely playing the offlane, the Dire offlane
                    -- read contested 0 times in 28 evaluations, and Tinker made 8 bot dispatches, 4
                    -- of them zero-cast, for 0 gold.
                    -- EXPLICIT nil TEST, NEVER THE and/or IDIOM. `(pc ~= nil and pc) or IsCore(...)`
                    -- is WRONG: with pc == false, `true and false` is false and the expression falls
                    -- through to the tag, so the DEMOTION half would silently never fire. That trap
                    -- already shipped once in this arc (v0.1.381 fixed the same idiom in the shadow
                    -- bit, where it made SUPPORT unrepresentable), so it is spelled out here.
                    -- UNDETERMINED IS A LEGAL ANSWER and means "no opinion": nil falls through to
                    -- exactly today's behaviour, so an unclassified ally can never be worse than
                    -- v0.1.381. The observed-farmer OR is kept unconditionally because it is MEASURED
                    -- behaviour (camp confirms), not a label.
                    core = pc or ((State.allyFarmers[name] or 0) >= K.FARMER_CORE_MARKS),
                }
                out[#out].name = name                -- v0.1.378: read by the shadow log AND the commit below
                -- v0.1.379: the observed-lane tally, inlined here because this is the one site
                -- that already holds both the ally name and its position, and because the main chunk
                -- is at the 200-local ceiling (see the NOTE ON PLACEMENT above pos_probe).
                if name and now() >= 60 and now() <= 300 then
                    State.posLaneTally = State.posLaneTally or {}
                    local h = State.posLaneTally[name] or { top = 0, mid = 0, bot = 0, n = 0 }
                    local ln = Lane._assign_lane({ x = p.x, y = p.y }, { mid_band = 2500 })
                    if h[ln] then h[ln] = h[ln] + 1; h.n = h.n + 1 end
                    State.posLaneTally[name] = h
                end
            end
        end
    end
    -- v0.1.378 SHADOW LOG + COMMIT. Fires ONCE per game, when 4 allies have enumerated (roster
    -- completeness, not a dwell), or at t>=180 on whatever enumerated. Writes log lines only; the
    -- `core` field above is already built and is NOT modified here.
    -- v0.1.379: TWO checkpoints now. Stage 1 at t>=30 is DRAFT ONLY (elimination over the playable
    -- sets plus the Tinker-holds-mid assertion). Stage 2 at t>=300 re-runs it with the OBSERVED lane
    -- tally intersected in, which is the operator's own rule and the only path that works in match
    -- types where the engine ships no starting_position. Logging both is the whole point: the differ
    -- columns show which source would have changed which verdict, before any of it moves the hero.
    -- v0.1.382 NEW-MATCH RESET. There is NO OnGameStart/OnGameEnd hook anywhere in this script
    -- (grep: 0 hits), so nothing clears match-scoped State when a second game starts on the same
    -- script load. That was harmless while all of this was observation-only, but State.posFinal is
    -- LOAD-BEARING now: a stale commit from the previous match would classify a completely different
    -- roster, and State.posLogged being latched would stop the classifier ever re-running. Both
    -- failures are silent. GetDOTATime restarts near 0 each match, so a large BACKWARD jump is the
    -- available new-match signal. 30s of slack because the clock is negative during pre-game and the
    -- first samples land after the horn.
    if State.posT and now() < State.posT - 30 then
        State.posFinal, State.posLogged = nil, nil
        State.posEngine, State.posLaneTally, State.posProbed = nil, nil, nil
        -- v0.1.389: this reset exists BECAUSE there is no OnGameStart/OnGameEnd hook anywhere in the
        -- script, and v0.1.385/.386 then added match-scoped latches without extending it. crashSeen
        -- is the one that matters: it gates defend_crash, the verdict that outranks every economic
        -- veto, and the tower-threat stamp is what makes it reliably non-empty at match end.
        State.crashSeen = nil
        State.rearmNoFundT, State.rearmNoFundGap, State.rearmNoFundLogT = nil, nil, nil
        State.keenNoFundT, State.keenNoFundGap = nil, nil   -- v0.1.397
        State.fightSeen = nil   -- v0.1.393 (the scan's clear-then-restamp self-heals this within 2s anyway; cleared here per the match-scoped-latch rule)
        logline("pos_reset new_match")
    end
    State.posT = now()
    local stage = ((not State.posLogged) and now() >= 30) and 1
                  or ((State.posLogged == 1 and now() >= 300) and 2 or nil)
    if stage then
        local names = {}
        for _, a in ipairs(out) do if a.name then names[#names + 1] = a.name end end
        if #names >= 4 or now() >= 180 then
            State.posLogged = stage
            if stage == 1 then pos_probe() end
            -- v0.1.380: if the engine shipped starting_position for this match type, COMMIT NOW from
            -- ground truth and never revisit. Positions 1-3 are the cores; 4-5 the supports.
            if stage == 1 and State.posEngine then
                local bits, n = {}, 0
                for _, nm in ipairs(names) do
                    local sp = State.posEngine[nm]
                    if sp then bits[nm] = (sp <= 3); n = n + 1 end
                end
                if n >= #names then pos_commit("engine", bits) end
            end
            local resid = Map.Positions.Shadow(names)
            if stage == 2 then
                -- intersect the observed lane's slot set into each residual. INTERSECT, never
                -- replace: an odd lineup then narrows to EMPTY and reads UNDETERMINED rather than
                -- confidently wrong, which is the failure direction this whole arc exists to avoid.
                for _, nm in ipairs(names) do
                    local h = (State.posLaneTally or {})[nm]
                    local ln, share = Map.Positions.ObservedLane(h)
                    logline(string.format("pos_lane name=%s top=%d mid=%d bot=%d n=%d obs=%s share=%.2f",
                        nm, (h and h.top) or 0, (h and h.mid) or 0, (h and h.bot) or 0,
                        (h and h.n) or 0, tostring(ln), share or 0))
                    if ln and resid[nm] then
                        local slots = Map.Positions.LaneSlots(ln, State.team)
                        for v in pairs(resid[nm]) do if not slots[v] then resid[nm][v] = nil end end
                    end
                end
            end
            local commitBits = {}
            for _, a in ipairs(out) do
                if a.name then
                    local raw, rs = Map.Positions.Of(a.name), {}
                    for v in pairs(resid[a.name] or {}) do rs[#rs + 1] = v end
                    table.sort(rs)
                    -- one-sided test; empty residual is UNDETERMINED, never "not core".
                    -- v0.1.381 BUG FIX, caught by this very log (g379). The previous form was
                    --   (hasS and not hasC) and false or nil
                    -- which CANNOT EVER YIELD false: `true and false` is false, and `false or nil`
                    -- is nil. So every SUPPORT read nil, the policy turned nil into CORE, and the
                    -- classifier marked the WHOLE TEAM core - precisely the failure that kills
                    -- side-lane farming. g379 shows it live: Lich resolved to a clean {4} and Bane
                    -- to a clean {5}, both unambiguous supports, and both still logged bit=nil
                    -- pol=true. EXPLICIT IF-CHAIN, never the and/or idiom, for any expression whose
                    -- legitimate value is `false`. This is the same trap the design notes flagged on
                    -- the eventual `core =` wiring, and it was written here anyway.
                    local hasC, hasS = false, false
                    for _, v in ipairs(rs) do if v <= 3 then hasC = true else hasS = true end end
                    local bit
                    if #rs == 0 then bit = nil
                    elseif hasC and not hasS then bit = true
                    elseif hasS and not hasC then bit = false
                    else bit = nil end
                    -- the shipped policy defaults a STRADDLING residual to CORE (measured: on g378
                    -- that kills the 8 bad bot dispatches and costs nothing, because the other
                    -- straddler sat in a lane Juggernaut already made contested). An EMPTY residual
                    -- stays undetermined and must NOT become core.
                    local pol
                    if bit ~= nil then pol = bit
                    elseif #rs > 0 then pol = true
                    else pol = nil end
                    logline(string.format(
                        "pos_shadow stage=%d name=%s set=%s resid=%s bit=%s pol=%s today=%s differ=%d n=%d",
                        stage, a.name, table.concat(raw, "/"), (#rs > 0) and table.concat(rs, "/") or "-",
                        tostring(bit), tostring(pol), tostring(a.core and true or false),
                        ((pol and true or false) ~= (a.core and true or false)) and 1 or 0, #names))
                    -- v0.1.382: stage 1 commits ONLY DETERMINED bits (see pos_commit: a determined
                    -- bit cannot reverse at stage 2, a straddle can). Stage 2 commits whatever is
                    -- still open, applying the straddle policy.
                    if stage == 1 then
                        if bit ~= nil then commitBits[a.name] = bit end
                    elseif pol ~= nil then
                        commitBits[a.name] = pol
                    end
                end
            end
            pos_commit(stage == 1 and "draft" or "observed", commitBits)
        end
    end
    return out
end

-- tally allies per lane region (Lane._assign_lane): n = all allies, c = CORE allies (carry/mid/offlane).
-- The wave contest yields a lane to a CORE ally (c>=1) OR 2+ allies (n>=2, XP split); a lone support
-- (not core, n<2) does NOT block the lane - fixes Tinker abandoning his own lane to a support (Note 2).
-- (v0.1.312: ally_lane_tally DELETED - its coarse Lane._assign_lane band marked a lane
-- contested for a core anywhere in the map half; eval_side_lanes uses Farm.IsContestedByAlly
-- proximity to the wave now, per the user's "don't farm what he is farming AT THE MOMENT".)

local function gather_route_targets(allies, our_pri)
    local out = {}
    local ropts = risk_opts()                                                    -- Note 3 structural risk (once per build)
    local camp_cands = gather_candidates()
    -- #4: a camp's REMAINING value = its live alive-creep bounty. c.gold already IS that: gather_candidates
    -- reads the box in vision (dead creeps excluded) and caches the last-seen alive bounty while fogged, and
    -- fsm_engage refreshes that cache THROUGH the clear. So no gold-delta subtraction (the old campGained
    -- double-subtracted dead creeps for an in-vision camp and was contaminated by passive/lane/kill gold).
    local function eff_gold(c) return c.gold or 0 end
    local function marches_life(tier, ehp, gold) return clear_marches(tier, ehp, camp_stacks(gold, tier)) end   -- shared capped clear-cost model (#1); stacks from the gold read (v0.1.183: the sum-ceil is stack-only)
    -- clear TIME + mana for `marches` casts. A PAIR clears with ONE perpendicular W spanning both camps,
    -- so a pair uses the TANKIER camp's count (MAX life), not the sum: two camps' gold for ~one camp's
    -- cost (v0.1.103). Real per-March time = cast + robot-kill + a level-aware Rearm channel between casts.
    local function clear_time(marches)
        -- CADENCE + one TAIL: casting the Marches (cast + Rearm channel between) is the sequential cost;
        -- the robots deliver over 6s and overlap the Rearm channel, so the kills happen DURING the cadence
        -- we already count - add only ONE tail for the last March's robots finishing (not per-March).
        return marches * K.MARCH_CAST_DUR + math.max(0, marches - 1) * rearm_channel() + K.ROBOT_TAIL
    end
    local function mana_for(marches)
        -- keen in + N Marches + the (N-1) REARMS between them (each Rearm resets March but costs ~225 mana).
        -- The old model omitted Rearm mana, so the planner under-costed a camp by ~half -> it committed to
        -- camps it could not afford -> mana-starved mid-clear and went home before finishing (no engage_done,
        -- the "mana starve without Bottle" bug). clear_t already counts the Rearm TIME; this counts its mana.
        return abil_mana(State.keen, K.KEEN_MANA_FB) + marches * abil_mana(State.march, K.MARCH_MANA_FB)
               + math.max(0, marches - 1) * abil_mana(State.rearm, K.REARM_MANA_FB)
    end
    local function emit_single(c)
        local marches = marches_life(c.type, c.ehp, c.gold)
        local sr = Farm.StructuralRisk({ x = c.center.x, y = c.center.y }, ropts)
        local crisk = math.min(1, enemy_risk_at(c.center) + sr)
        local crisk_sh = math.min(1, enemy_risk_at(c.center, nil, true) + sr)   -- v0.1.409 SHADOW rider (StructuralRisk is fog-independent, computed once)
        out[#out + 1] = {
            kind = "camp", lane = "jungle", pos = { x = c.center.x, y = c.center.y },
            value = eff_gold(c), clear_t = clear_time(marches), risk = crisk, risk_sh = crisk_sh,
            contested = Farm.IsContestedByAlly(c.center, allies, { radius = K.CONTEST_RADIUS, min_value = our_pri }),
            ref = c, mana_cost = mana_for(marches), hp_cost = crisk * K.HP_RISK_DMG,
        }
    end
    -- #2/#3: greedy-pair the CANDIDATES (clearable camps only) so a feasible pair is ONE planner node
    -- (value = SUM of both golds, cost = the TANKIER camp), decided ONCE here. Old code emitted BOTH camps
    -- of a pair, each carrying the pair bonus -> the multi-step plan double-counted a pair; and the
    -- execution-time partner search (pair_spot_for over ALL Map.Camps) could disagree with this valuation.
    -- Now one node = one farm action, and the pairing that is valued is exactly the one that executes.
    -- A pair whose MIDPOINT is unsafe (enemy_risk >= RISK_HARD) is split back to two singles, so each camp
    -- can still be farmed from its own safe stand (the single fallback the old pair_spot_for gave).
    local pts = {}
    for i = 1, #camp_cands do pts[i] = { x = camp_cands[i].center.x, y = camp_cands[i].center.y } end
    local pair_max = math.min(K.PAIR_RADIUS, K.MARCH_LEN - 2 * math.abs(K.MARCH_PAIR_OFFSET))
    local allow = function(i, j) return forced_pair(camp_cands[i].center, camp_cands[j].center) end   -- whitelist over-range pairs
    for _, g in ipairs(Farm.GreedyPairs(pts, pair_max, nil, allow)) do
        local a = camp_cands[g.a]
        local b = g.b and camp_cands[g.b] or nil
        local midv = b and Vector((a.center.x + b.center.x) / 2, (a.center.y + b.center.y) / 2, a.center.z) or nil
        local er = midv and enemy_risk_at(midv) or 1
        local er_sh = midv and enemy_risk_at(midv, nil, true) or 1   -- v0.1.409 SHADOW rider
        -- v0.1.189 (user economics, FINAL): a pair costs the TANKIER camp's marches = the SAME
        -- mana as clearing that camp alone, for TWO camps' gold - the pair STRICTLY DOMINATES.
        -- Never split one: the v0.1.182 fundable->singles degrade (obsolete since the v0.1.183
        -- floors made non-ancient pair cost == single cost) only ever fired on ANCIENT pairs,
        -- where clearing the cheap partner solo condemned the ancient to a full-price solo clear
        -- later. An unfundable pair now simply WAITS (both camps intact) for the refill chain /
        -- pool growth. Singles exist only for genuinely partnerless camps or an unsafe midpoint.
        if b and er < K.RISK_HARD then
            local mid = { x = midv.x, y = midv.y }
            local marches = math.max(marches_life(a.type, a.ehp, a.gold), marches_life(b.type, b.ehp, b.gold))
            local sr = Farm.StructuralRisk(mid, ropts)
            local crisk = math.min(1, er + sr)
            local crisk_sh = math.min(1, er_sh + sr)   -- v0.1.409 SHADOW rider
            local pc = Farm.PairClearClass(g.d, { march_len = K.MARCH_LEN, disc = K.CREEP_DISC })
            out[#out + 1] = {
                kind = "camp", lane = "jungle", pos = mid, value = eff_gold(a) + eff_gold(b),
                clear_t = clear_time(marches), risk = crisk, risk_sh = crisk_sh,
                contested = Farm.IsContestedByAlly(mid, allies, { radius = K.CONTEST_RADIUS, min_value = our_pri }),
                ref = a, partnerRef = b, pairClass = pc.class, pairPd = g.d,
                mana_cost = mana_for(marches), hp_cost = crisk * K.HP_RISK_DMG,
            }
        else
            emit_single(a); if b then emit_single(b) end
        end
    end
    -- v0.1.224 STACKING (user: GPM-first, LARGE camps only, cap 2x): a large camp gets a
    -- timed-aggro node in the ~:54 window - the maneuver walks the old creeps across the :00
    -- respawn and DOUBLES the camp; the stack-aware clear model (camp_stacks + the sum-ceil)
    -- already prices and clears the result next cycle for ~the same mana = the pair economics
    -- again. The window's to-deadline makes a late start uncollectable (timeline-exact); the
    -- wave's Tier-1 dispatch + leave_by preempt outrank the maneuver (waves always win).
    if State.menu.stackLarge and State.menu.stackLarge:Get() then
        local win = Lane.Schedule.StackWindow(now(), { aggro_sec = K.STACK_AGGRO_SEC })
        -- v0.1.338 (user doctrine, g339): stacking is a CONVENIENCE, not a necessity - the node
        -- emits only when the hero is ALREADY near the camp (component math: c.center is a plain
        -- table, the type-boundary law). g339's cross-map dispatch (an empty plan's only node)
        -- dies at emission; a hero clearing the pair partner when the window opens still stacks.
        local hpos = State.hero and origin(State.hero) or nil
        for _, c in ipairs(camp_cands) do
            local near = hpos and ((hpos.x - c.center.x) ^ 2 + (hpos.y - c.center.y) ^ 2 <= K.STACK_NEAR_R * K.STACK_NEAR_R)
            if near and c.type == 2 and camp_stacks(c.gold, c.type) < 2 then
                local crisk = math.min(1, enemy_risk_at(c.center) + Farm.StructuralRisk({ x = c.center.x, y = c.center.y }, ropts))
                out[#out + 1] = {
                    kind = "stack", lane = "jungle", pos = { x = c.center.x, y = c.center.y },
                    value = eff_gold(c) * K.STACK_VALUE_FRAC, clear_t = win.clear_t,
                    risk = crisk, window = { from = win.from, to = win.to },
                    contested = Farm.IsContestedByAlly(c.center, allies, { radius = K.CONTEST_RADIUS, min_value = our_pri }),
                    ref = c, stackWin = win, mana_cost = 0,
                }
            end
        end
    end
    -- Note 4: the fountain refill as an optimised routed node (the planner inserts it only when it
    -- unlocks enough downstream gold). _timeline restores mana/hp to refill_frac*max on this step.
    local fpos = friendly_fountain_pos()
    if fpos then
        out[#out + 1] = { kind = "refill", lane = "base", pos = { x = fpos.x, y = fpos.y },
                          value = 0, clear_t = refill_wait(), risk = 0, restore = true }
    end
    return out
end

-- live enemy lane creeps within `radius` of `pos` (for the wave March aim + the cleared check).
-- Mirrors lib/lane's lane-creep read; returns the minimal { pos } the engage needs.
local function enemy_lane_creeps_near(pos, radius)
    local out, r2 = {}, radius * radius
    for _, n in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
        if Entity.GetTeamNum(n) ~= State.team and Entity.IsAlive(n) and not Entity.IsDormant(n)
           and not (NPC.IsWaitingToSpawn and NPC.IsWaitingToSpawn(n)) then
            local p = Entity.GetAbsOrigin(n)
            if p then
                local dx, dy = p.x - pos.x, p.y - pos.y
                if dx * dx + dy * dy <= r2 then out[#out + 1] = { pos = p } end
            end
        end
    end
    return out
end

local function run_route_scan()
    State.fog = enemy_snapshot()                  -- fresh risk snapshot
    local allies = ally_farm_priorities()          -- FarmPriority-scaled (matches our_pri)
    local our_pri = our_farm_priority()
    local targets = gather_route_targets(allies, our_pri)
    local plan = Lane.Route.Plan(targets, route_hero_state(), route_opts())
    State.routeScan = { plan = plan, targets = targets, our_pri = our_pri }
    State.routeScanUntil = now() + K.TEST_OVERLAY_SEC
    logline(string.format("routescan our_pri=%.2f cands=%d steps=%d gold=%.0f time=%.1f",
        our_pri, #targets, #plan.steps, plan.gold or 0, plan.time or 0))
    for i, s in ipairs(plan.steps) do
        logline(string.format("routestep %d kind=%s pos=(%.0f,%.0f) value=%.0f clear=%.1f risk=%.2f",
            i, s.kind, s.pos.x, s.pos.y, s.value or 0, s.clear_t or 0, s.risk or 0))
    end
    -- dump EVERY candidate (not just chosen steps) + the reason it was/wasn't picked, so a skipped
    -- lane is explained in text without the overlay (Note 2): CHOSEN, skip=contested, skip=risk
    -- (>= RISK_HARD veto), or not-picked (eligible but the planner found a better sequence).
    local chosen = {}
    for _, st in ipairs(plan.steps) do chosen[st] = true end
    for _, t in ipairs(targets) do
        local why = chosen[t] and "CHOSEN"
            or (t.contested and "skip=contested")
            or (((t.risk or 0) >= K.RISK_HARD) and "skip=risk")
            or "not-picked"
        logline(string.format("routecand kind=%s lane=%s pos=(%.0f,%.0f) value=%.0f risk=%.2f contested=%s %s",
            t.kind, t.lane or "-", t.pos.x, t.pos.y, t.value or 0, t.risk or 0, tostring(t.contested or false), why))
    end
end

-- ── FSM ──────────────────────────────────────────────────────────────────────
-- Loop-guard + diagnostic, run on EVERY engage exit. We Marched the camp, so it is empty now: ALWAYS mark
-- it cleared until the next respawn (the cleared flag, tied to next_respawn, is the re-pick gate - a
-- fogged camp we cannot see is not re-picked). Waves are not is_cleared-tracked (they respawn every 30s),
-- so camps only.
local function mark_engage_result()
    local s = State.spot
    if s and s.kind == "camp" and (State.marchCasts or 0) > 0 then
        mark_spot_cleared(s)
        -- v0.1.212 COST-TRUTH CENSUS (run-35: plans price ~2 casts, execution ran casts=3 budget=3
        -- everywhere -> the real spend ~2x the planned mana_cost -> every multi-step plan's tail
        -- broke at the replan and the PAIR step never executed = the recurring lonely-single).
        -- real= is the raw mana delta over the clear (bottle drinks make it read LOW, never high),
        -- so real >> plan on this line is the model gap, measured. Feeds the pricing recalibration.
        local real = State.engageMana and math.max(0, State.engageMana - mana()) or -1
        logline(string.format("camp_value key=%s gold=%d cleared=true(eng) casts=%d plan=%d real=%d",
            tostring(s.key), math.floor(s.gold or 0), State.marchCasts or 0,
            math.floor(s.planCost or -1), math.floor(real)))
        -- v0.1.347 FIX: this reset runs on EVERY successful camp-engage exit, BEFORE fsm_decide -
        -- so the v0.1.346 keen_waste probe read marchCasts==0 and called every CLEARED camp a
        -- wasted keen (g348: 9 of 10 kind=camp keen_waste events were successful clears with 2-4
        -- casts; census - all 9 camp_value cleared=true(eng) lines sat 1-3 lines above one). Latch
        -- the fact that this commit DID cast before the counter is zeroed.
        if State.keenInvest then State.keenInvest.spent = true end
        State.marchCasts = 0   -- once-per-engage: panic calls go_return every tick; without this the
                               -- loop-guard + camp_value log re-fire ~45x per panic episode.
    end
end

-- return to the fountain to refill (mana-bail / panic / the planner's refill node).
local function go_return()
    mark_engage_result()
    -- v0.1.356: the keen_waste latch MUST NOT survive a RETURN. It is scored at the next
    -- fsm_decide on the premise that "reaching DECIDE means the commit that spent the keen
    -- has ended" - but a tick() escapeMana bail, an engage_bail or a panic goes straight to
    -- RETURN WITHOUT passing DECIDE, so the latch outlived the whole fountain round trip and
    -- the next decide charged it to the keen. g356: 4 of 15 keen_waste events were fountain
    -- trips = 91.2s of the 182.9s total, the single largest class (g355 had 1 more, 30.4s).
    -- The keen was not wasted on a bad wave, the PLAN CHANGED - a different fact that does
    -- not belong in this counter. Same family as the v0.1.347 camp fix, wave-path edition.
    State.keenInvest = nil
    State.fsm = "RETURN"
end

-- Note 4: a farm target finished and we may be able to chain - re-plan instead of always returning to
-- base. The resource-aware planner decides the next step: another farm target (chain), or its refill
-- node when nothing is affordable (-> the refill branch in fsm_decide sets RETURN).
local function engage_replan()
    mark_engage_result()
    State.spot = nil
    State.fsm  = "DECIDE"
end

-- ── ARC E2 Task 3: flee glue + readiness stamps ──────────────────────────────
-- Placed HERE (not next to the dispatcher block at ~L1206) because
-- mark_engage_result is a local declared just above; the dispatcher region
-- sits earlier in the chunk and cannot see it. ONE local table (not five
-- locals): the main chunk sits against Lua's 200-locals-per-function limit.
local E2 = {
    -- flee-worthy roles (reaction not conditional on owning a save)
    -- E3b: line_projectile added - a LANDED hook/skewer/burrowstrike-class stun on
    -- self (recognized via the catalog or the sandking_impale alias) breaks contact
    -- after, same as any landed disable. The pre-impact dodge stays Lina territory.
    FLEE_ROLES = { hard_disable = true, channel_on_me = true, line_projectile = true },
    -- E3b: Tinker-LOCAL threat entries the SHARED catalog deliberately omits.
    -- modifier_stunned = the engine-generic landed stun: SK Burrowstrike aliases to
    -- its canonical mod, but Venge Magic Missile and boulder-class hits land ONLY
    -- this (run-75 harvest x13). The Lina line keeps it OUT of the shared table on
    -- doctrine (reactively uncatchable - you are already stunned; her answer is
    -- pre-arming). For Tinker the FLEE half is the whole value: escape-then-redecide
    -- the moment it ends. extra=true skips the dispatcher (no phantom save chain).
    EXTRA_THREATS = { modifier_stunned = { role = "hard_disable", extra = true } },
    -- modifier -> ability reverse map (built once, below)
    THREAT_TO_ABILITY = {},
}
do
    -- Collision-aware (several abilities can stamp the same modifier, e.g.
    -- ogre fireblast/unrefined): keep the SHORTER min-level cd so a stamp
    -- never over-claims unreadiness (ReadyAt's unstamped default is
    -- assume-ready, the safe direction). Name tie-break = deterministic
    -- across pairs() orders.
    local function min_cd(ab) return tonumber(AbilityData.Cooldown and AbilityData.Cooldown(ab, 1)) or math.huge end
    for ab, mod in pairs(ThreatData.ABILITY_TO_THREAT or {}) do
        local prev = E2.THREAT_TO_ABILITY[mod]
        if not prev or min_cd(ab) < min_cd(prev)
           or (min_cd(ab) == min_cd(prev) and ab < prev) then
            E2.THREAT_TO_ABILITY[mod] = ab
        end
    end
end
State.castStamps = State.castStamps or {}

-- E2 flee (user decision: ESCAPE THEN RE-DECIDE). Break contact with the
-- existing escape chain, kill the current commit, and let the next decide run
-- the normal planner against a FRESH fog snapshot (the risk gates then steer
-- away while the threat is near). No forced RETURN; recover/refill only when
-- the planner itself picks it. Mitigate-not-offense: no capitalize hooks.
function E2.defense_flee(threat_mod, caster)
    if now() - (State.lastFleeT or -10) < 1.0 then return end   -- save-fired + role-flee double-call guard
    State.lastFleeT = now()
    State.fog = enemy_snapshot()                      -- the escape must see the CURRENT gank (E0 B5)
    try_escape_blink()                                -- best-effort; no-op without dagger / when broken
    if State.spot then
        suppress_shove(State.spot.lane, now() + K.SHOVE_STUCK_S, "defense_flee")
        mark_engage_result()
    end
    State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
    logline(string.format("defense_flee mod=%s caster=%s", tostring(threat_mod), def_uname(caster)))
end

-- Signature = the lib's real call shape (lib/defense.lua run_chain_walk, matches Lina's
-- record_save): on_save_fired(intent, short, threat_mod, threat_caster).
function E2.on_save_fired(intent, save_short, threat_mod, threat_caster)
    tlog(1, "save_fired", { intent = intent, save = save_short, mod = threat_mod,
                            caster = def_uname(threat_caster) })
    -- The lib does NOT MarkFired on its own (defense.lua Dispatcher:Dispatch); the hero's
    -- callback owns the reaction-window throttle bookkeeping.
    defense_dispatcher:MarkFired(threat_caster)
    -- E2 final review: a dispatcher-fired blink bypasses do_blink, so stamp the
    -- debounce here or the flee path's try_escape_blink can double-order the
    -- dagger within the same event (second order overwrites the first's dest).
    if save_short and tostring(save_short):find("blink", 1, true) then State.lastBlinkT = now() end
    E2.defense_flee(threat_mod, threat_caster)
end

function E2.stamp_enemy_cast(mod_name, caster)
    local ab = E2.THREAT_TO_ABILITY[mod_name]
    if not ab then return end
    local cname = def_uname(caster)
    if cname == "?" then return end
    -- SHORTEST cd across levels = conservative toward safety: never treats a
    -- ready disabler as unready. E2 final review: disable cds DECREASE with
    -- level (Voodoo 24/20/16/12), so level 1 is the LONGEST - stamping it
    -- over-claimed unreadiness for up to 12s (the case-file #1 loss mode).
    local cd = math.huge
    for lvl = 1, 4 do
        local c = tonumber(AbilityData.Cooldown and AbilityData.Cooldown(ab, lvl))
        if c and c > 0 and c < cd then cd = c end
    end
    if cd == math.huge then return end
    ChannelGate.Stamp(State.castStamps, cname, ab, now(), cd)
    tlog(2, "cast_stamp", { caster = cname, ability = ab, cd = cd })
end

local function handle_panic()
    local h = State.hero
    local frac = (Entity.GetHealth(h) or 1) / math.max(1, Entity.GetMaxHealth(h) or 1)
    if frac < K.PANIC_HP then
        State.lowHpSince = State.lowHpSince or now()
        if now() - State.lowHpSince >= K.PANIC_ARM then
            State.panicUntil = now() + 1.0
            State.fog = enemy_snapshot()                -- E0 (B5): the escape must see the CURRENT gank, not the last decide's snapshot
            try_escape_blink()                          -- best-effort (usually broken once bursted); keen_home is the panic fallback
            go_return()
            return true
        end
    else
        State.lowHpSince = nil
    end
    return now() < State.panicUntil
end

-- Build the Lane.Schedule.Plan ctx for the HOME lane from a lib/lane lanes table. crash/shove point (visible
-- centroid -> clash contact -> stable mid ref), wave eff-HP, wave arrival (visible -> now; fogged ->
-- measured cadence lastWaveT + WAVE_PERIOD), travel-to-mid via InterceptETA (Keen), safety/mana gates.
-- Returns { plan, crash_pos, stand, aim, visible, risk } or nil if no home lane / no reference point.
-- Note 1 root: the standback toward our fountain (below) can land the shove stand on a
-- backline tower's HIGH GROUND (unwalkable) -> the keen+walk gets stuck (the v0.1.64
-- watchdog then only recovers). Pull the stand in toward the (walkable, lane) crash point
-- until it sits on walkable ground, so the shove stand is reachable in the first place.
local function schedule_ctx(lanes)
    local s = lanes and lanes[K.HOME_LANE]
    if not s then return nil end
    local cl = s.clash or {}
    local ew = s.enemy_wave
    local visible = (ew and not ew.estimated and ew.centroid) and true or false

    -- AIM at the wave MEETING point: the midpoint of the two ENGAGED fronts (lib/lane.MeetingPoint,
    -- fog-aware). Replaces the old enemy-wave-centroid / clash-contact aim, which chased the
    -- freshly-spawned wave back near a tower -> deep-own (fogged) or deep-enemy (visible) stands (notes
    -- 1/2/3). lib/lane now also selects the engaged (most-advanced) wave, not the biggest cluster.
    -- Piece 2 (TINKER_LANE_STAND_DESIGN.md): the KINEMATIC meeting is the anchor. PredictMeeting from
    -- the current fronts + LIVE speeds (real, or MIRRORED when fogged - Piece 1.5) gives WHERE the
    -- fronts collide (.point -> crash_pos) and WHEN (now + .eta -> arrival). Measured: kpred within
    -- ~1s over 2 runs; the old current-fronts-midpoint anchor drifted 1430u median per approach.
    local awv = s.ally_wave
    local pm
    do
        local espd, aspd = Lane.WaveSpeed(ew), Lane.WaveSpeed(awv)
        if ew and ew.front and awv and awv.front and espd and aspd then
            pm = Lane.PredictMeeting({ pos = ew.front, speed = espd }, { pos = awv.front, speed = aspd })
        end
    end
    -- v0.1.303 LANE-CLOCK D-A (user-approved design, TINKER_LANE_SCHEDULING_STUDY.md): a FOGGED
    -- lane-phase wave is a CLOCK event - it dispatches to the last OBSERVED arrival ground
    -- (State.laneMeet, stamped at every real arrival) or the lane's front-tower midpoint
    -- (s.meeting), NEVER to the mirror-kinematic meeting guess. The guess (err 300-1400u,
    -- the v0.1.170 mirror study) fed the covers cascade and produced the fogged geometry-veto
    -- class: 40 jungle-instead-of-lane picks across runs 104-107 and 3/5 misses in the .286
    -- baseline itself (run-108, vetoes 1-2s before REAL arrivals). Visible waves keep the
    -- kinematic meeting and every veto. Deep era (T1 down) keeps the old path entirely.
    local t1m, t1malive = enemy_lane_t1(K.HOME_LANE)
    local deep_era = not t1malive       -- v0.1.196: the DEEP-FARM era = their mid T1 DOWN. While it stands the lane phase owns everything (crash clamp, thin 400) - 100% untouched, per the user.
    local crash_pos
    if not visible and not deep_era then
        local lm = State.laneMeet[K.HOME_LANE]
        crash_pos = (lm and (now() - lm.t) <= K.LANE_MEET_TTL and { x = lm.x, y = lm.y })
                    or s.meeting
        crash_pos = clamp_intercept(crash_pos, K.INTERCEPT_FWD_R)   -- v0.1.315 two-sided clamp + v0.1.323 forward intercept: meet the wave UP-LANE inside the walk-farmable band (never past the stairs line, never deep our-side); the live re-stand corrects once it shows.
    else
        crash_pos = (pm and pm.point) or s.meeting
    end
    if not crash_pos then return nil end
    -- CRASH CLAMP (user model): the meeting is BOUNDED by the enemy T1. If the estimate lands at/behind
    -- the (alive) enemy mid T1, our wave crashes the TOWER - aim AT the tower (Tinker stands WAVE_STANDBACK
    -- in front of it), never PAST it. This crashes the tower (the goal) AND stops the deep dives (note 2:
    -- walking under/past the tower). T1 dead -> no clamp; the depth/time gate (rule 2) decides the dive.
    local crashTwrPos                                       -- v0.1.246: the wave's tower terminus, when one exists
    if t1malive and t1m and stand_depth(crash_pos) > stand_depth(t1m) then
        crash_pos = { x = t1m.x, y = t1m.y }
        crashTwrPos = t1m
    end
    local eff_hp = (ew and ew.hp) or 0
    -- v0.1.345 FIX B: the COUNT axis. ew.count is set by Lane.DetectWaves (lane.lua:253, real waves)
    -- and by Lane.ExpectedWave (fogged estimates). count 0 = no data = never vetoes. The count is the
    -- NON-DORMANT slice, so it must ALSO have held for THIN_CREEPS_HOLD_S (State.loneSince, stamped
    -- by the 2s scan) before it may veto - a vision-edge read on a partially-fogged FULL wave
    -- resolves within ~1s, a genuine remnant holds for tens of seconds.
    local ecount = (ew and ew.count) or 0
    -- Stamp/clear HERE TOO, at the 0.4s DECIDE cadence - not only at the 2s scan (review finds 1+2):
    -- scan-only stamping made the hold a 2-sample test at 0.5Hz on a signal sampled at 2.5Hz (a
    -- contradicting decide read was discarded), and pushed veto latency to 2-4s, inside which the
    -- g346 dispatch still fired. Any read saying NOT-lone restarts the hold, from either source.
    if ew and not ew.estimated and ecount > 0 and ecount <= K.SHOVE_THIN_CREEPS then
        State.loneSince[K.HOME_LANE] = State.loneSince[K.HOME_LANE] or now()
    else
        State.loneSince[K.HOME_LANE] = nil
    end
    local lsince = State.loneSince[K.HOME_LANE]
    local lone   = (lsince and (now() - lsince) >= K.THIN_CREEPS_HOLD_S) and true or false
    local present = visible

    -- arrival, CLOCK-INDEPENDENT (now + relative ETA so now cancels in slack): a VISIBLE wave is
    -- here (~now) -> shove it. Fogged -> Lane.Schedule.NextWaveArrival predicts the next wave on the
    -- period grid: the MEASURED phase when lastWaveT is fresh, else the spawn-clock WAVE_PHASE - so
    -- anticipation stays reliable even after a missed wave (smart-laning: stop losing imminent waves).
    -- Piece 2 arrival: kpred primary (also fixes the visible-but-FAR wave, which used to read
    -- arrival=now() -> lying slack); grid at the MEASURED phase 14 only when fronts/speeds missing.
    local arrival, asrc
    if pm and visible then
        arrival, asrc = now() + pm.eta, "kin"
        -- v0.1.256 arc B: a held/frozen enemy wave names itself (the measured-speed eta is
        -- already honest - huge - so the far_wave/slack economics own the exclusion).
        if (Lane.WaveSpeed(ew) or 325) <= K.HELD_CLOSING_MIN then asrc = "held" end
    elseif visible then
        arrival, asrc = now(), "vis"          -- visible but front/speed incomplete: it is here
    elseif State.laneWaveT.mid then
        -- fogged + stamped rhythm: the measured cadence beats the MIRROR kinematics (run-8,
        -- TINKER_ANCHOR_REACH_STUDY.md root cause B: mirror-kin ran 8-12s early on every fogged
        -- decide; the stamped grid err ~0 once lastWaveT existed).
        arrival, asrc = Lane.Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT.mid), "stamp"
    elseif pm and deep_era then
        arrival, asrc = now() + pm.eta, "kinest"   -- mirror kinematics, unstamped: DEEP-ERA only (v0.1.303 D-B: kinest timing ran 8-12s early, run-8; the lane phase trusts the spawn-clock grid)
    else
        arrival, asrc = Lane.Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT.mid), "grid"
    end

    -- item 7 REWORKED (user, v0.1.154): the push sim is a TIMING input, not a veto. bal +
    -- first_t (round-1 fight duration) predict WHEN the current creep fight resolves = when
    -- the lane MOVES. Losing fight (bal < 0): the farmable moment is the fight END - the
    -- enemy remnant emerges at the meeting - so arrival pushes out to it; the scheduler
    -- jungles the exact slack and the frozen waveEta makes the timed W fire on the remnant
    -- the moment it resolves (farm the lane perfectly, no idle watching creeps whittle).
    -- Winning / no data: farm at the meeting as before (the wave dies to creeps + W during
    -- the fight = fastest clear). REAL waves only (the mirrored fogged estimate reads
    -- bal=-4 every between-waves lull - the v0.1.152-run misfire).
    local bal, gone_fight_rel
    if awv and ew and not ew.estimated then
        local pf = Lane.PushForecast(awv, ew, { cycle = math.min(30, math.floor(now() / 450)),
                                                game_time = now(), rounds = 1 })
        bal = pf and pf.bal
        -- v0.1.344: the bal<0 defer (arrival -> fight_end -> jungle slack) is TREK-AVOIDANCE for
        -- a FAR losing push. A REACHABLE wave has no trek and Tinker's W clears it regardless of
        -- the creep balance, so skip the defer -> arrival stays ~now -> Lane.Schedule.Plan shoves it
        -- (its unsafe/mana/thin/covers vetoes still gate). Only far waves defer (+ the frozen-eta
        -- remnant timing). A reachable held wave keeps asrc=held -> the .305 walk-in casts it.
        -- See TINKER_HELD_WAVE_DESIGN.md (g345 incident 2).
        if bal and bal < 0 and pf.first_t and not (s.intercept and s.intercept.reachable) then
            local fight_end = now() + math.max(0, (pm and pm.eta) or 0) + pf.first_t
            if fight_end > arrival then arrival, asrc = fight_end, "sim" end
        end
        -- gone-by-arrival capture (v0.1.191): OUR wave clearly wins -> their wave dies at
        -- ~meeting + fight time; the COMPARISON against travel happens below, AFTER the raid
        -- cap (a creep-keen arriving in ~4s beats the fight ending = the wave is NOT gone).
        if bal and bal >= K.GONE_BAL_MIN and pf.first_t and pm then
            gone_fight_rel = pm.eta + pf.first_t
        end
    end

    -- F2 (forward-meeting / next-wave defer) REVERTED at v0.1.83: every variant
    -- (v0.1.78 strength ratio, v0.1.80 crashing-only, v0.1.81 pushing-forward,
    -- v0.1.82 regen wait) regressed lane handling (skipped / then missed all lanes:
    -- deferring the shove to a future wave lowers presence + self-feeds via stale
    -- lastWaveT). Back to the validated v0.1.76 behavior: always target the CURRENT
    -- wave (shove when due, jungle the slack). Revisit smart-lane-farming from here.

    local me = origin(State.hero)
    local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
    local itc = Lane.InterceptETA({ x = me.x, y = me.y }, static_anchors(), ms,
                                  { channel = K.KEEN_CHANNEL }, crash_pos, nil)   -- v0.1.231: the SCHEDULER's transit is keen-calibrated ON PURPOSE (leave_by/near_due were validated on keen-class transit runs 44-50; ladder-aware pricing here made near_due dispatch ~12s early and WALK from the fountain onto fogged predictions - run-51's two sightings). Economy sites (route legs/returns/window fits) keep keen_tp().
    local travel_to_mid = (itc and itc.eta) or (me:Distance(Vector(crash_pos.x, crash_pos.y, me.z)) / math.max(150, ms))
    -- Risk v2 axis 2 rider: the anchor-based ETA reads ~20s for a deep meeting the L2 creep-keen
    -- crosses in ~4s. Cap the fed travel when raid-capable so leave_by AND the far_wave rule price
    -- the REAL transit (deep waves re-qualify at L2 by the math, per the doctrine). v0.1.191: the
    -- cap also requires OUR WAVE to be ALIVE (awv creeps > 0) - the raid keens onto OUR creeps;
    -- pricing the creep transit with no creep on the lane committed walks the raid could not save
    -- (the user's structural point: our prior wave dies at their tower before the next exists).
    -- v0.1.192: raid-capable ONCE per decide (keen L2 + ready + OUR wave alive to ride) - drives
    -- the travel cap here AND the stairs-cap exemption on the stand below.
    -- v0.1.211 (user GPM-FIRST doctrine: "if we know our wave will meet their wave and we can
    -- keen before it meets in a way that GPM don't go down and we are under the safe rules, we
    -- totally should - lanes = fast gold + enemies must come back to their tower"): raid
    -- capability is LADDER-aware, not ready(keen)-only. Keen L2's ~40s cd meant keen was almost
    -- always down at the 0.4s decide, raidcap read false, travel fell back to WALK (15-20s) and
    -- gone_by_arrival wrote off every pre-emptable wave (run-34: zero klvl2 engages). A ready
    -- Rearm resets Keen in ~1.2-1.9s, so the true raid transit = (rearm channel if keen down) +
    -- keen channel + landing. The GPM guard is the DEEP_THIN_EFFHP bar (bad remnants = nono);
    -- the safety rules are unchanged (raid_safe / lane_unsafe / landing gates).
    local raidcap = ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
                    and (ready(State.keen) or ready(State.rearm)) and awv and (awv.count or 0) > 0
                    and raid_gank_ok(crash_pos)   -- v0.1.318 E3a PROXIMITY-REFIT (arc 2): raid vetoed only when a FRESH fogged enemy reaches the landing AND no blink-bail (replaces the .313 global missN veto removed in .316; closes run-114 without the hit-rate crippling)
                    and raid_hop_ok(crash_pos)   -- v0.1.253: the cap is only legal when the hop it prices actually exists (run-69 churn)
    if raidcap then
        local transit = (ready(State.keen) and 0 or rearm_channel()) + K.KEEN_CHANNEL + 1.5
        travel_to_mid = math.min(travel_to_mid, transit)
    end
    -- (gone-by-arrival moved BELOW the stand block at v0.1.193: it needs the FINAL covers value.)

    -- stand: ONE composition for both toggle branches (glue rebuild item 2). ON = adaptive
    -- forward/back (lane anticipation: forward when the lane is clear so March W's the wave early,
    -- back on a contested lane); OFF = the baseline 900-back through the SAME path, now also
    -- tower-clamped at DECIDE time (deliberate delta: lane_go clamped it at movement time anyway,
    -- so decide and execution finally agree; every removed "lane_go clamp" line = a bad stand
    -- fixed at the source).
    local stand, covers, cwhy
    do
        -- T0 COLLAPSED (v0.1.177): the "Lane anticipation (A/B)" toggle is gone - ON was the only
        -- tested path through the whole v0.1.152-176 arc. Forward on a clear lane, back contested.
        local fwd = not lane_unsafe({ x = crash_pos.x, y = crash_pos.y })   -- 0 enemies in gank radius -> forward; contested -> back
        local _safe
        stand, covers, _safe, cwhy = safe_stand_for(crash_pos, fwd, raidcap, K.HOME_LANE)
        if not stand then stand = Map.SnapWalkable({ x = crash_pos.x, y = crash_pos.y }, crash_pos) end
    end
    -- Risk v2 axis 1 (task #11, user POINT SYSTEM): graded depth points for the STAND, consumed
    -- HERE at decide time only - a busted budget reads covers=false -> Plan no_safe_stand ->
    -- jungle. Movement/tether/landings never check points (hard positional vetoes froze/idled).
    local dpts = 0
    do
        local info = stand and enemy_t1_points_info(stand)
        if info then
            local kl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
            dpts = Farm.DepthPoints(info.depth_past, {
                line_alive = info.line_alive, side_t1_up = info.others_up,
                shave = (kl >= 2 and ready(State.keen)) and K.DEPTH_KEEN_SHAVE or 0,
            })
            if dpts > K.DEPTH_POINT_BUDGET then covers = false; cwhy = "dpts" end
        end
    end
    -- v0.1.303 LANE-CLOCK D-A: ESTIMATES NEVER VETO (the v0.1.241 thin law, extended to the
    -- whole chain). The fogged lane-phase dispatch ground is observed/equilibrium and composed
    -- tower-safe + walkable above - the cascade verdicts (tower/cover/depth/leash/dpts) were
    -- evaluating a position GUESS. Real reads keep full authority: tower_dying below, the live
    -- re-stand once the wave shows, and every veto on VISIBLE waves.
    if not visible and not deep_era and stand then covers, cwhy = true, nil end

    -- gone-by-arrival BIDIRECTIONAL (v0.1.193, user: "the fight sim should calculate on either
    -- direction"). bal < 0 pushed arrival to fight-end above (asrc=sim, their remnant emerges);
    -- the WINNING direction was incomplete: bal >= GONE_BAL_MIN means their wave DIES at the
    -- meeting and never reaches a stand, so it is farmable ONLY by legally covering the fight
    -- itself before it resolves. The old travel-only test (fight_rel < travel) could not fire
    -- once the hero already stood near the line (run-23 t=207: travel 3.4s vs fight ~10s ->
    -- "not gone" -> commit -> 25s stand-and-wait for a wave that never came). Now: gone unless
    -- a legal covering stand exists AND we get there before the fight ends.
    local gone = (gone_fight_rel and not (covers and travel_to_mid < gone_fight_rel)) and true or false

    -- v0.1.246 (TINKER_TOWER_DEATH_DESIGN.md): the crash tower is MELTING - predicted dead
    -- before we can arrive (+margin). The wave terminus vanishes with it (the wave pushes
    -- past), so a dispatch/hold on it becomes the 25s stale stand. Exclude THIS decide
    -- (the gone_by_arrival shape, re-evaluated every 0.4s); once the tower actually falls,
    -- deep_era owns the lane exactly as today. Undamaged/fogged towers predict math.huge
    -- (the lib's conservative default) = zero behavior change outside an active melt.
    if not crashTwrPos and cl and cl.crashing and cl.crash_tower and cl.crash_tower.team ~= State.team then
        crashTwrPos = { x = cl.crash_tower.pos.x, y = cl.crash_tower.pos.y }
    end
    local crash_twr_key = tower_key_near(crashTwrPos)
    if crash_twr_key and covers
       and Map.Towers.DeathEta(State.towerTrack, crash_twr_key, now()) < travel_to_mid + K.TOWER_DYING_MARGIN_S then
        covers, cwhy = false, "tower_dying"
    end

    -- v0.1.76: the shove gate = enemy HEROES (fog-aware) + enemy-TOWER range ONLY.
    -- StructuralRisk (depth) was REMOVED here: a winning mid shove stands forward at the
    -- same depth as an under-tower dive, so depth vetoed EVERY legit shove (v0.1.75
    -- fountain-stuck). enemy_tower_risk catches the genuine under-tower / deep-dive case
    -- (incl. the v0.1.73 death stand at 791u -> 0.38); enemy_risk_at catches ganks.
    local srisk = enemy_risk_at(Vector(stand.x, stand.y, 0)) + enemy_tower_risk(stand)
    if srisk > 1 then srisk = 1 end
    -- glue rebuild item 6 (Farm.PathRisk): a stand can read safe while the only route to it walks a
    -- gank corridor; sample the straight hero->stand route and treat a hot corridor as unsafe too.
    local prisk = Farm.PathRisk({ x = me.x, y = me.y }, stand,
        function(pt) return enemy_risk_at(Vector(pt.x, pt.y, 0)) end)
    -- v0.1.409 SHADOW rider (build 1, TINKER_FOG_TRACKER_DESIGN.md): the same corridor priced
    -- with shadow ages. Log-only; nothing reads it but the trace.
    local prisk_sh = Farm.PathRisk({ x = me.x, y = me.y }, stand,
        function(pt) return enemy_risk_at(Vector(pt.x, pt.y, 0), nil, true) end)
    -- COMMIT RISK v2 (mid producer): the exposure term is travel_to_mid, the KEEN-AWARE
    -- Lane.InterceptETA above (raid-capped to KEEN_CHANNEL + 1.5). The load-bearing claim is that
    -- NO NEW dist/move_speed is computed inside the risk path, not that this value is never walk
    -- time: Lane.InterceptETA seeds `eta` with the plain walk baseline dist/ms (lib/lane.lua)
    -- and returns it when no ready anchor beats it, which is the ~1-in-5 non-keened commit. What
    -- was measured on g356's 58 recovered trips is that recomputing exposure as dist/305 instead of
    -- reading travel= raises the MEDIAN exposure from 12.4s to 32.6s (2.6x; 5.6x on the travel term
    -- alone, 24.6s vs 4.4s, since 46 of 58 commits are keened) and at APPROACH_SPEED 50 vetoes
    -- 16 of 19 in-band commits = a farming shutdown on game one. Passing it also keeps every hazard
    -- out of the risk path: no origin() read, no dist(), no move-speed divisor, no inf/NaN made here.
    local shove_safe = (not lane_unsafe(stand, { bail = true, site = "mid", travel = travel_to_mid,
        commit = Escape.CommitWiden(travel_to_mid, K.COMMIT_STAND_S, K.COMMIT_APPROACH_SPEED, K.COMMIT_WIDEN_MAX) }))
        and prisk < K.PATH_RISK_MAX   -- v0.1.94 count+HP aware; v0.1.317 bail=true (mid shove site): the fog-uncertain escape-gate
    local emd = effective_march_dmg()                       -- N5: live LEVEL-AWARE per-March damage (not the flat MARCH_DMG_PER_CAST)
    local cal = { march_dmg_per_cast = (emd > 0 and emd) or K.MARCH_DMG_PER_CAST, cast_dur = K.MARCH_CAST_DUR,
                  robot_kill = K.ROBOT_KILL, rearm_channel = rearm_channel(), lead = K.SCHED_LEAD }
    -- shove mana gate = one hop (Keen + 1 March). DELIBERATELY low: gating on the full ceil'd clear
    -- (Keen + N Marches) would make Tinker REFILL instead of shoving a big wave at moderate mana ->
    -- the wave goes unshoved (stolen) + an extra fountain trip, both worse than half-clearing it (a
    -- farm bot still banks 3 of 4 last-hits). The ceil'd cast count kills the trailing ranged WHEN
    -- mana allows (engage_bail=0 historically = there is usually headroom); if not, the in-engage mana
    -- bail degrades to the prior half-clear, no worse. So: better clear, no steal/refill regression.
    -- v2 rich ctx (TINKER_LANE_GLUE_DESIGN.md item 1): the whole veto cascade + lane-first filler
    -- live in Lane.Schedule.Plan now; the glue only feeds facts. Deliberate deltas (lib-test-pinned):
    -- defend_crash never overrides unsafe or the mana verdict (v0.1.337), the mana gate is regen-aware (mana AT leave_by), and
    -- mana is EFFECTIVE (raw + Bottle charges) so charges count before a fountain trek.
    local hh = State.hero
    local hpf  = (Entity.GetHealth(hh) or 1) / math.max(1, Entity.GetMaxHealth(hh) or 1)
    local mmax = (NPC.GetMaxMana and NPC.GetMaxMana(hh)) or 0
    local mpf  = (mmax > 0) and (mana() / mmax) or 1
    local covers_ctx = (covers == true)                     -- T0 collapsed: the no_safe_stand rule is always live
    return {
        plan = { now = now(),
                 wave = { arrival = arrival, eff_hp = eff_hp, present = present, visible = visible },
                 cal = cal, travel_to_mid = travel_to_mid,
                 mana = effective_mana(), shove_cost = hop_mana_cost() + K.SHOVE_MANA_RESERVE,
                 -- v0.1.360: the FULL 2-cast price, carried SEPARATELY. shove_cost keeps the
                 -- v0.1.200 one-hop value so the mana verdict at schedule.lua:153 - which routes
                 -- to RETURN and abandons the wave - is byte-identical. The full price is only
                 -- consulted in the SLACK branch, where there is still time to top up.
                 shove_cost_full = hop_mana_cost(true) + K.SHOVE_MANA_RESERVE,
                 safe = shove_safe,
                 mana_regen = mana_regen_read(),
                 recover_s = refill_wait() + K.KEEN_CHANNEL + travel_to_mid,   -- refill_wait includes the base rearm (v0.1.162)
                 far_travel_s = K.SHOVE_FAR_TRAVEL, min_wave_ehp = K.SHOVE_MIN_EFFHP,
                 camp_alt_s = K.WAVE_CAMP_ALT_S,     -- Risk v2 axis 2: RT walk vs ~2 camp clears (raid-aware travel above)
                 gone = gone,                        -- v0.1.191: their wave dies to ours before we can arrive -> jungle
                 -- v0.1.195/196 (user, ~3rd ask): the DEEP-FARM era works like the lane phase -
                 -- predict the meetings, take FULL waves (safe creep-keen in-and-out at L2),
                 -- jungle the rest. STRICTLY the T1-DEAD era (v0.1.196 review: the lane phase
                 -- is perfect and stays 100% untouched - the depth-only gate would have caught
                 -- the T1-alive crash clamp, whose crash_pos sits AT the alive T1 ~876 deep):
                 -- their mid T1 down AND the meeting past the stairs line raises the visible
                 -- thin bar to DEEP_THIN_EFFHP - a 1-2-creep remnant is never worth the trip,
                 -- while the fogged ExpectedWave estimate (a FULL predicted wave) passes and
                 -- gets the timed raid. thin_wave -> jungle; the stamped grid owns the timing.
                 -- v0.1.345 FIX B: a single VISIBLE creep is thin whatever it weighs. math.huge
                 -- = "always thin"; Lane.Schedule.Plan's thin_wave rule keeps its own wave.visible
                 -- gate, so fogged ExpectedWave anticipation is untouched, and defend_crash still
                 -- outranks thin (pinned) so an over-strict bar costs FARM, never a tower.
                 thin_ehp = (lone and math.huge)
                            or ((deep_era and stand_depth(crash_pos) > K.WALK_DEPTH_MAX)
                                and K.DEEP_THIN_EFFHP or K.SHOVE_THIN_EFFHP),
                 covers = covers_ctx,
                 -- (bal/bal_min deliberately NOT fed: the losing_fight veto was the wrong shape for
                 -- the push sim - it is a TIMING input, folded into `arrival` above. Plan's rule
                 -- stays lib-side, inactive, for a consumer that wants a genuine go/no-go.)
                 -- v0.1.180 (run-16: 4 false "defenses" walked 20s to THEIR T2, reason=defend_crash
                 -- bypassing far_wave/points): a defense happens at OUR tower - the crash projection
                 -- (sim horizon) can flag our tower while the CURRENT meeting/stand still reads deep
                 -- enemy-side. Qualify on the stand being our-side (dpts == 0); when the wave really
                 -- approaches, the meeting recomputes near our tower and the defense fires there.
                 -- v0.1.263: OR the sticky stamp (crash seen by the 2s scan within
                 -- CRASH_STICKY_S) - the instantaneous flag flickers mid-fight and every
                 -- decide can sample a false instant (run-76 bot T2).
                 defend_crash = (((cl.crashing and cl.crash_tower and cl.crash_tower.team == State.team)
                                  or (State.crashSeen and now() - (State.crashSeen[K.HOME_LANE] or -1e9) < K.CRASH_STICKY_S))
                                 and dpts == 0) and true or false,
                 suppressed = shove_suppressed(K.HOME_LANE),
                 -- case-file #2 (run-72 t=445): the filler's need_recharge only converts SLACK
                 -- jungles; a DUE shove bypassed it and dispatched at <40% HP - panic on arrival
                 -- donated the keen + a ~50s round trip. Self-state is a dispatch precondition.
                 hp_frac = hpf, min_hp_frac = K.DISPATCH_HP_MIN,
                 filler = { min_camp_slack = K.MIN_CAMP_SLACK, min_fountain_slack = K.MIN_FOUNTAIN_SLACK,
                            need_recharge = hpf < K.REFILL_FRAC or mpf < K.REFILL_FRAC } },
        crash_pos = crash_pos, stand = stand, aim = crash_pos, visible = visible, risk = srisk,
        deep_era = deep_era,                                -- INCREMENT 2 (v0.1.229): their mid T1 down = the deep-era priority-flattening trigger
        dpts = dpts,                                        -- Risk v2 axis 1: the stand's depth points (ft.dpts calibration)
        thin1 = lone or nil,                                -- v0.1.345 FIX B signature (-> ft.thin1)
        path_risk = prisk,                                  -- item 6: worst enemy risk along hero->stand (calibrate PATH_RISK_MAX)
        path_risk_sh = prisk_sh,                            -- v0.1.409 SHADOW rider (log-only)
        bal = bal,                                          -- item 7: push-sim balance (trace only; timing folded into arrival/asrc=sim)
        covers = covers,                                    -- ON (anticipation): safe_stand_for found a covering stand; nil when OFF
        cwhy = cwhy,                                        -- v0.1.203: WHY covers failed (tower|cover|depth|leash|dpts) - the leash-era analyzability rule
        wave_eta = arrival, asrc = asrc,                    -- Piece 2: the arrival deadline + its source (kin|held|vis|stamp|kinest|sim|grid)
        -- v0.1.213 TIMED MEETING RAID: when THEIR wave reaches the meeting (fight start) = the
        -- pre-empt target. v0.1.216 (run-39 t=890: a bal=-4 commit stepped out at meet=0.1 while
        -- the scheduler had pushed arrival to the fight END (+12s, asrc=sim) -> landed mid-fight,
        -- 1 W of scraps = the user's "went to farm nothing on mid"): the pre-empt applies only
        -- when OUR side would eat their wave (bal >= 0); a LOSING fight's farmable moment is the
        -- fight end (their remnant emerges) - the arrival the scheduler already set.
        meet_eta = (pm and (bal or 0) >= 0) and (now() + math.max(0, pm.eta)) or nil,
        clash = cl,                                         -- v0.1.105: settle = the wave MEETING point for the tower-aware veto
        crash_tower_key = crash_twr_key,                    -- v0.1.246: rides the spot for the hold tripwire
    }
end

-- ALL-LANES Tier-1.5 (TINKER_ALLLANES_DESIGN.md): slim per-lane ctx for the SAME pure
-- Lane.Schedule.Plan. Phase-1 rules: a side wave must be VISIBLE or mirror-kinematic (no
-- fogged anticipation - no stamp/grid arrivals, no blind side keens); stands own-side/
-- equilibrium (crash clamp at the lane's T1 + the depth budget); distance-ruled pre-L2
-- (camp_alt_s vs per-lane raid-aware travel). Returns (ctx_bundle, nil) or (nil, verdict)
-- where verdict names the snub for the swave trace.
local function side_wave_ctx(lane, s)
    if not s then return nil, "off" end
    if shove_suppressed(lane) then return nil, "suppressed" end
    local ew, awv = s.enemy_wave, s.ally_wave
    local visible = (ew and not ew.estimated and ew.centroid) and true or false
    local pm
    do
        local espd, aspd = Lane.WaveSpeed(ew), Lane.WaveSpeed(awv)
        if ew and ew.front and awv and awv.front and espd and aspd then
            pm = Lane.PredictMeeting({ pos = ew.front, speed = espd }, { pos = awv.front, speed = aspd })
        end
    end
    -- PHASE 2: a FRESH lane cadence stamp makes a fogged side lane dispatchable like mid
    -- (asrc=stamp; run-8: the stamped grid beats mirror kinematics). Stale stamp = named snub.
    local stampT = State.laneWaveT[lane]
    local stamp_fresh = (stampT and (now() - stampT) <= K.SIDE_STAMP_MAX_S) and true or false
    if not (visible or pm or stamp_fresh) then
        return nil, (stampT and "stale" or "fogged")
    end
    -- v0.1.303 LANE-CLOCK D-A, side twin (see mid): fogged lane-phase ground = observed
    -- arrival (laneMeet) or the lane midpoint, never the mirror guess.
    local st1, st1alive = enemy_lane_t1(lane)
    local crash_pos
    if not visible and st1alive then
        local lm = State.laneMeet[lane]
        crash_pos = (lm and (now() - lm.t) <= K.LANE_MEET_TTL and { x = lm.x, y = lm.y })
                    or s.meeting
        crash_pos = clamp_intercept(crash_pos, nil, lane)   -- v0.1.315 two-sided intercept clamp (see mid); v0.1.327 the SIDE lane's own depth zero
    else
        crash_pos = (pm and pm.point) or s.meeting
    end
    if not crash_pos then return nil, "fogged" end
    local crashTwrPos                                        -- v0.1.246: the wave's tower terminus, when one exists
    if st1alive and st1 and stand_depth(crash_pos, lane) > stand_depth(st1, lane) then   -- crash clamp at THIS lane's alive enemy T1 (same rule as mid; v0.1.327 the lane's own zero, relative so it cancels anyway)
        crash_pos = { x = st1.x, y = st1.y }
        crashTwrPos = st1
    end
    local eff_hp = (ew and ew.hp) or 0
    -- v0.1.345 FIX B (mid twin, v0.1.207 twin-producer rule): the COUNT axis + the same
    -- THIN_CREEPS_HOLD_S persistence (the raw count is the NON-DORMANT slice and lies at the
    -- vision edge; see the mid site and the K comment).
    local ecount = (ew and ew.count) or 0
    -- stamp/clear at DECIDE cadence too (see the mid site).
    if ew and not ew.estimated and ecount > 0 and ecount <= K.SHOVE_THIN_CREEPS then
        State.loneSince[lane] = State.loneSince[lane] or now()
    else
        State.loneSince[lane] = nil
    end
    local lsince = State.loneSince[lane]
    local lone   = (lsince and (now() - lsince) >= K.THIN_CREEPS_HOLD_S) and true or false
    -- PHASE 2: thin fires on REAL reads only (Lane.Schedule.Plan's own thin rule is already
    -- visible-gated). A mirror estimate copies OUR paired lane's composition - a remnant
    -- there must not veto a possibly-healthy fogged wave here; estimates never veto.
    -- v0.1.345: the "thin1" token is the FIX B signature and rides the existing verdict path
    -- into ft.swtop / ft.swbot. This PRE-FILTER IS DELIBERATELY KEPT (not replaced by feeding
    -- thin_ehp): letting a thin side wave reach Lane.Schedule.Plan would open a NEW path where a
    -- side defend_crash overrides thin - a path that does not exist today.
    if visible and (lone or eff_hp < K.SHOVE_THIN_EFFHP) then
        return nil, lone and "thin1" or "thin"
    end
    local arrival, asrc
    if pm and visible then
        arrival, asrc = now() + pm.eta, ((Lane.WaveSpeed(ew) or 325) <= K.HELD_CLOSING_MIN) and "held" or "kin"   -- v0.1.256 arc B: frozen sides name themselves too
    elseif visible then arrival, asrc = now(), "vis"
    elseif stamp_fresh then                                  -- PHASE 2: measured cadence beats the unstamped mirror (mid ladder parity, run-8)
        arrival, asrc = Lane.Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, stampT), "stamp"
    elseif not st1alive then arrival, asrc = now() + pm.eta, "kinest"   -- unstamped mirror kinematics: DEEP-ERA only (v0.1.303 D-B, same as mid)
    else arrival, asrc = Lane.Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, stampT), "grid" end
    local bal, gone_fight_rel
    if awv and ew and not ew.estimated then                  -- REAL waves only (the mirrored-estimate bal misfire, v0.1.153)
        local pf = Lane.PushForecast(awv, ew, { cycle = math.min(30, math.floor(now() / 450)),
                                                game_time = now(), rounds = 1 })
        bal = pf and pf.bal
        -- v0.1.344: reachable waves skip the bal<0 defer (see the mid site / TINKER_HELD_WAVE_DESIGN.md).
        if bal and bal < 0 and pf.first_t and not (s.intercept and s.intercept.reachable) then
            local fight_end = now() + math.max(0, (pm and pm.eta) or 0) + pf.first_t
            if fight_end > arrival then arrival, asrc = fight_end, "sim" end
        end
        if bal and bal >= K.GONE_BAL_MIN and pf.first_t and pm then
            gone_fight_rel = pm.eta + pf.first_t
        end
    end
    -- travel: keen-aware ETA; the v0.1.211 ladder-aware raid cap requires OUR wave alive ON THIS LANE
    local me = origin(State.hero)
    local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
    local itc = Lane.InterceptETA({ x = me.x, y = me.y }, static_anchors(), ms,
                                  { channel = K.KEEN_CHANNEL }, crash_pos, nil)   -- v0.1.231: the SCHEDULER's transit is keen-calibrated ON PURPOSE (leave_by/near_due were validated on keen-class transit runs 44-50; ladder-aware pricing here made near_due dispatch ~12s early and WALK from the fountain onto fogged predictions - run-51's two sightings). Economy sites (route legs/returns/window fits) keep keen_tp().
    local travel = (itc and itc.eta) or (me:Distance(Vector(crash_pos.x, crash_pos.y, me.z)) / math.max(150, ms))
    local raidcap = ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
                    and (ready(State.keen) or ready(State.rearm)) and awv and (awv.count or 0) > 0
                    and raid_gank_ok(crash_pos)   -- v0.1.318 E3a proximity-refit (see mid)
                    and raid_hop_ok(crash_pos)   -- v0.1.253: the cap is only legal when the hop it prices actually exists (run-69 churn)
    if raidcap then
        local transit = (ready(State.keen) and 0 or rearm_channel()) + K.KEEN_CHANNEL + 1.5
        travel = math.min(travel, transit)
    end
    -- v0.1.246 (TINKER_TOWER_DEATH_DESIGN.md): a MELTING crash tower dies before we arrive -
    -- the terminus (and the wave with it) is gone by then; named snub, re-competes next decide.
    if not crashTwrPos and s.clash and s.clash.crashing and s.clash.crash_tower
       and s.clash.crash_tower.team ~= State.team then
        crashTwrPos = { x = s.clash.crash_tower.pos.x, y = s.clash.crash_tower.pos.y }
    end
    local crash_twr_key = tower_key_near(crashTwrPos)
    if crash_twr_key
       and Map.Towers.DeathEta(State.towerTrack, crash_twr_key, now()) < travel + K.TOWER_DYING_MARGIN_S then
        return nil, "tower_dying"
    end
    -- stand: the SAME safe composition, leash keyed to this lane; per-lane depth points
    local fwd = not lane_unsafe({ x = crash_pos.x, y = crash_pos.y })
    local stand, covers, _safe, cwhy = safe_stand_for(crash_pos, fwd, raidcap, lane)
    if not stand then return nil, "no_stand" end
    if not visible and st1alive then covers, cwhy = true, nil end   -- v0.1.303 D-A: estimates never veto (side twin; dpts below still measures)
    local dpts = 0
    do
        local info = enemy_t1_points_info(stand)   -- nearest enemy T1 = this lane's, by construction
        if info then
            local kl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0
            dpts = Farm.DepthPoints(info.depth_past, {
                line_alive = info.line_alive, side_t1_up = info.others_up,
                shave = (kl >= 2 and ready(State.keen)) and K.DEPTH_KEEN_SHAVE or 0,
            })
            if dpts > K.DEPTH_POINT_BUDGET and not (not visible and st1alive) then covers = false; cwhy = "dpts" end   -- v0.1.303: the dpts veto is a REAL-stand read but keyed off an estimated ground when fogged - lane phase bypasses (mid parity)
        end
    end
    local gone = (gone_fight_rel and not (covers and travel < gone_fight_rel)) and true or false
    local srisk = enemy_risk_at(Vector(stand.x, stand.y, 0)) + enemy_tower_risk(stand)
    if srisk > 1 then srisk = 1 end
    local prisk = Farm.PathRisk({ x = me.x, y = me.y }, stand,
        function(pt) return enemy_risk_at(Vector(pt.x, pt.y, 0)) end)
    -- site = lane, NOT the literal "side" the design's 3.2 table specifies: eval_side_lanes runs
    -- side_wave_ctx for BOTH {"top","bot"} inside ONE decide at ONE now(), so a shared "side" key
    -- gives DiagGate dt = 0 on the second lane (0 >= 0 and 0 < 10.0 = suppress) and bot never logs
    -- a heartbeat all game, systematically, because the loop order is fixed. That is v0.1.357
    -- failure 1 at half scope, and analyzer A1 passes anyway (2 distinct sites). The logline carries
    -- no lane field, so it is not recoverable post-hoc either. A1 groups on whatever string arrives.
    local shove_safe = (not lane_unsafe(stand, { bail = true, site = lane, travel = travel,
        commit = Escape.CommitWiden(travel, K.COMMIT_STAND_S, K.COMMIT_APPROACH_SPEED, K.COMMIT_WIDEN_MAX) }))
        and prisk < K.PATH_RISK_MAX   -- v0.1.317 bail=true (side shove site); COMMIT RISK v2: exposure = this lane's KEEN-AWARE travel (see the mid producer)
    local emd = effective_march_dmg()
    local cal = { march_dmg_per_cast = (emd > 0 and emd) or K.MARCH_DMG_PER_CAST, cast_dur = K.MARCH_CAST_DUR,
                  robot_kill = K.ROBOT_KILL, rearm_channel = rearm_channel(), lead = K.SCHED_LEAD }
    return {
        plan = { now = now(),
                 wave = { arrival = arrival, eff_hp = eff_hp, present = visible, visible = visible },
                 cal = cal, travel_to_mid = travel,
                 mana = effective_mana(), shove_cost = hop_mana_cost() + K.SHOVE_MANA_RESERVE,
                 -- v0.1.360: the FULL 2-cast price, carried SEPARATELY. shove_cost keeps the
                 -- v0.1.200 one-hop value so the mana verdict at schedule.lua:153 - which routes
                 -- to RETURN and abandons the wave - is byte-identical. The full price is only
                 -- consulted in the SLACK branch, where there is still time to top up.
                 shove_cost_full = hop_mana_cost(true) + K.SHOVE_MANA_RESERVE,
                 safe = shove_safe,
                 mana_regen = mana_regen_read(),
                 far_travel_s = K.SHOVE_FAR_TRAVEL, min_wave_ehp = K.SHOVE_MIN_EFFHP,
                 camp_alt_s = K.WAVE_CAMP_ALT_S,   -- THE pre-L2 distance rule: RT walk vs ~2 camps; the raid cap collapses it at L2
                 gone = gone,
                 thin_ehp = K.SHOVE_THIN_EFFHP,    -- phase 1: no deep-era side farming, plain bar. v0.1.345: the pre-filter above owns the FIX B count rule; adding it here too would be unreachable.
                 covers = (covers == true),
                 -- v0.1.240 (run-55, user: "big waves crashing into our tower on top, 242-300
                 -- gold... easy and safe... happened several times" - 18 episodes counted, up
                 -- to 410g, missed on slack/no_fit verdicts): SIDE defends are live now, same
                 -- qualification as mid (our tower + our-side stand = dpts 0). Plan's defend
                 -- rule outranks slack/far/gone but never unsafe/covers=false, unchanged.
                 -- v0.1.263: OR the sticky stamp (see run_lane_scan) - run-76's bot crash
                 -- flickered between decides and the defend never fired.
                 defend_crash = (((s.clash and s.clash.crashing and s.clash.crash_tower
                                   and s.clash.crash_tower.team == State.team)
                                  or (State.crashSeen and now() - (State.crashSeen[lane] or -1e9) < K.CRASH_STICKY_S))
                                 and dpts == 0) and true or false,
                 -- deliberately NOT fed (nil = rule inactive): filler (mid's lane-first
                 -- filler must not convert a SIDE near_due / force fountain trips),
                 -- suppressed (checked above, per-lane), recover_s (a side lane never owns
                 -- the recover decision).
               },
        crash_pos = crash_pos, stand = stand, aim = crash_pos, visible = visible,
        risk = srisk, dpts = dpts, wave_eta = arrival, asrc = asrc,
        meet_eta = (pm and (bal or 0) >= 0) and (now() + math.max(0, pm.eta)) or nil,
        travel = travel, gold = (ew and ew.gold) or 0, cwhy = cwhy,
        defend = (((s.clash and s.clash.crashing and s.clash.crash_tower
                    and s.clash.crash_tower.team == State.team)
                   or (State.crashSeen and now() - (State.crashSeen[lane] or -1e9) < K.CRASH_STICKY_S))
                  and dpts == 0) and true or false,   -- v0.1.263: sticky OR, same as ctx.defend_crash above
        crash_tower_key = crash_twr_key,                    -- v0.1.246: rides the spot for the hold tripwire
    }
end

-- ONE shove-spot producer for all lanes (ALL-LANES v0.1.226; the v0.1.207 twin-producer
-- lesson: a fix must sweep all producers - prevented by having exactly one).
-- sc must carry { aim, stand, wave_eta, meet_eta, asrc }; ref = the lane's scan state.
local function dispatch_shove(lane, sc, casts, ref)
    local z = origin(State.hero).z
    State.spot = {
        kind = "wave", shove = true, lane = lane, ref = ref,
        center = Vector(sc.aim.x, sc.aim.y, z), refPoint = Vector(sc.aim.x, sc.aim.y, z),
        standSpot = { stand = Vector(sc.stand.x, sc.stand.y, z),
                      aim = Vector(sc.aim.x, sc.aim.y, z), paired = false },
        shoveCasts = casts,                           -- casts-bounded engage (replaces SHOVE_MARCH_CAP)
        waveEta = sc.wave_eta,                        -- Piece 2: the kinematic deadline (frozen with the stand)
        meetEta = sc.meet_eta,                        -- v0.1.213: the meeting/fight-start time (pre-empt raids fire for THIS, not stand-closing)
        waveAsrc = sc.asrc,                           -- v0.1.218: the arrival's source - asrc=sim means waveEta IS the fight end (the bal<0 farmable moment)
        crashTowerKey = sc.crash_tower_key,           -- v0.1.246: the wave's tower terminus; dies mid-commit -> the fsm_move_wave tripwire redecides
    }
    if (lane or K.HOME_LANE) == K.HOME_LANE then
        State.lastWaveStand = { x = sc.stand.x, y = sc.stand.y, t = now() }   -- v0.1.328: the idle pre-position home (the none-state holds HERE, not wherever it froze; side shoves do not move the home)
    end
    State.marchCasts, State.fsm = 0, "MOVE"
    State.keenedSpot = false   -- v0.1.286 (run-94 1:30 cross-map walks): a NEW commit is a NEW leg - the stale latch skipped the keen rung and walked 7700+ (why=latched)
    State.moveSince = now(); State.moveTrack = nil
    State.keenedSpot = false; State.marchPending = nil; State.emptySince = nil
    State.rearmStepback = nil; State.chanDeferSince = nil   -- v0.1.314 (bug hunt): a step-back / channel-defer belongs to the OLD commit's engage - the camp commit already clears rearmStepback, the wave commit leaked both onto the next wave
end

-- ALL-LANES side-lane evaluation (extracted v0.1.229 - ONE producer for the Tier-1.5
-- slack window AND the deep-era compete): evaluates top/bot through side_wave_ctx ->
-- contest -> Lane.Schedule.Plan -> the `window` fit, writes the swave verdicts into ft, and
-- returns (best {lane, risk, gold, casts}, bestCtx) or nil. Selection = lowest composed
-- stand risk, gold tiebreak (the validated v0.1.227 rule).
local function eval_side_lanes(lanes, allies, window, ft)
    -- v0.1.314 (bug hunt finding: the v0.1.312 contest gated on a.value >= CONTEST_CORE_BASE,
    -- but a.value = FarmPriority = base * live_mult / 1.6 [role() returns nil], so the test was
    -- effectively base*live_mult >= 0.88 = only a CARRY at even stats; every other core
    -- [nuker/pusher/durable/disabler] under-fired -> Tinker crashed their lane. The CORRECT
    -- predicate a.core = IsCore [base >= CONTEST_CORE_BASE] is already computed - use it.)
    local core_allies = {}
    for _, a in ipairs(allies or {}) do if a.core then core_allies[#core_allies + 1] = a end end
    -- v0.1.333: camp centres for the jungle-aware contest (a core farming beside the wave)
    local camp_centers = {}
    for _, cd in ipairs(Map.Camps()) do if cd.center then camp_centers[#camp_centers + 1] = cd.center end end
    local best, bestCtx = nil, nil
    local sw = { top = { v = "off", r = -1 }, bot = { v = "off", r = -1 } }
    for _, ln in ipairs({ "top", "bot" }) do
        local verdict
        local sctx, why = side_wave_ctx(ln, lanes[ln])
        local cj, cwhy = false, nil
        if sctx then
            cj, cwhy = Farm.IsContestedByAlly(sctx.crash_pos, core_allies,
                { radius = K.CONTEST_LANE_R, camps = camp_centers, camp_r = K.HERO_FARM_R, jungle_r = K.CONTEST_JUNGLE_R })
        end
        if not sctx then verdict = why
        -- v0.1.312 (user, run-114: the safe lane was EMPTY, wave free at the tower, but read
        -- contested): the old ally_lane_tally used Lane._assign_lane = a coarse x-y DIAGONAL
        -- BAND covering the whole map half, so a core ANYWHERE in the bottom half (jungle,
        -- base, Roshan) marked the safe lane contested. User's doctrine: "not stealing carry
        -- farm = don't farm what he is farming AT THE MOMENT" - contest is PROXIMITY to THIS
        -- wave's ground, not a lane label. A core ally within CONTEST_LANE_R of the crash
        -- point = he is on this wave -> yield; absent = take it.
        elseif cj then verdict = (cwhy == "jungle") and "contested_j" or "contested"   -- v0.1.314 cores pre-filtered (a.core); v0.1.333 the jungle branch logs its own token
        else
            local sd = Lane.Schedule.Plan(sctx.plan)
            if sd.action ~= "shove" then
                verdict = (sd.reason == "far_wave" and "far")
                       or (sd.reason == "gone_by_arrival" and "gone")
                       or (sd.reason == "thin_wave" and "thin")
                       or (sd.reason == "no_safe_stand" and "no_stand")
                       or sd.reason               -- unsafe/mana/deep_skip pass through named
            else
                -- the window bound: round trip (travel + clear + return) must fit
                local ret = Lane.InterceptETA(sctx.stand, static_anchors(),
                    (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320,
                    keen_tp(),   -- v0.1.230: ladder-aware pricing
                    State.shoveReturnPos or sctx.stand, nil)
                local trip = sctx.travel + (sd.t_clear or 0) + ((ret and ret.eta) or 0)
                -- v0.1.240: a DEFEND (their wave crashing OUR tower) bypasses the window fit -
                -- the tower does half the clear, the stand is the safest on the map, and the
                -- run-55 no_fit verdicts left 250g+ crashes unfarmed. Mid's leave_by preempt
                -- still yanks the engage if mid is genuinely due.
                if trip > window and sd.reason ~= "defend_crash" then verdict = "no_fit"
                elseif best and best.risk <= sctx.risk
                       and not (best.risk == sctx.risk and sctx.gold > best.gold) then
                    verdict = "risk_lost"       -- both eligible: lowest risk wins, gold tiebreak
                else
                    if best then sw[best.lane].v = "risk_lost" end   -- displaced winner named too
                    best, bestCtx, verdict = { lane = ln, risk = sctx.risk, gold = sctx.gold,
                                               casts = sd.casts }, sctx,
                                             (sd.reason == "defend_crash") and "defend" or "ok"
                end
            end
        end
        sw[ln] = { v = verdict, r = (sctx and sctx.risk) or -1 }
    end
    ft.swtop = string.format("%s:%.2f", sw.top.v, sw.top.r)   -- written AFTER the loop: a
    ft.swbot = string.format("%s:%.2f", sw.bot.v, sw.bot.r)   -- displaced winner reads risk_lost
    return best, bestCtx
end

local function fsm_decide()
    if now() < State.nextDecide then return end
    State.nextDecide = now() + K.DECIDE_GAP
    -- v0.1.345 D1 KEEN-INVESTMENT OUTCOME (log-only): fsm_decide only runs in State.fsm=="DECIDE",
    -- so reaching here means the commit that spent the keen has ENDED. marchCasts==0 = it cast
    -- NOTHING, i.e. the keen bought nothing. cwhy on the NEXT decide names why the stand died
    -- (g347 t=429.7: fogged stamp dispatch -> keen -> wave read real -> cwhy=depth -> abandoned,
    -- then a rearm+keen elsewhere). Pair keen_waste with that cwhy to size incident C honestly.
    if State.keenInvest then
        local ki = State.keenInvest
        -- ki.spent = a camp engage already banked its casts and zeroed the counter (v0.1.347).
        if (State.marchCasts or 0) == 0 and not ki.spent then
            logline(string.format("keen_waste lane=%s kind=%s asrc=%s resid=%.0f held=%.1f",
                tostring(ki.lane or "-"), tostring(ki.kind or "-"),
                tostring(ki.asrc or "-"), ki.resid or -1, now() - ki.t))
        end
        State.keenInvest = nil
    end
    State.fog = enemy_snapshot()             -- snapshot enemies ONCE per decide (enemy_risk_at reads it)
    State.refillNeed = nil                   -- cost-aware refill: valid only for the trip its dispatch starts (re-set below when the pick is refill; a stale need must never inflate an unrelated RETURN)

    -- E3a MISSINGCOUNT (v0.1.313 CORRECTED - the bug hunt proved the v0.1.311 re-apply was
    -- INERT on both axes): use the tested pure lever Escape.MissingCount = enemies in the
    -- snapshot marked visible==false (HIDING with a known last-position = the classic
    -- missing-on-the-map gank signal, the pro "<=1 of 5 missing is safe to deep-farm"
    -- doctrine). The v0.1.311 roster-diff counted the WRONG set: a fogged hero STAYS in the
    -- snapshot as visible=false and was counted as "seen", so missN only rose for DEAD or
    -- never-seen enemies = zero signal in the everyone-hiding case, and +risk in the wrong
    -- direction after a team wipe. And its additive prisk bump (max 0.24) could never cross
    -- the 0.42 gate on a clean corridor. Now the count GATES the RAID directly (below).
    State.missN = Escape.MissingCount(State.fog)

    -- v0.1.91 instrument: ONE consolidated `farm` trace per decide. Supersedes the piecemeal
    -- sched/jungle/funnel/decide-pick string logs - this single event ALONE explains each choice and
    -- feeds the offline per-wave accounting (tools/parse_debuglog.lua --farm-report). Logging-only.
    local ft = { t = string.format("%.1f", now()), miss = State.missN }
    -- (ft.fb A/B tag retired with the T0 collapse - one engine now)
    local function emit_farm(pick) ft.pick = pick; tlog(1, "farm", ft) end
    local stuckWindow = false   -- v0.1.158: a suppressed shove falls through to the planner with a capped horizon
    -- quality-review item 2: ONE crash-freshness sweep shared by site A's terminal and site B's
    -- latch gate (was duplicated inline at both - a fresh crashSeen with the side defend vetoed
    -- re-latched at site B every decide while site A cleared next tick, ~2.5Hz spurious churn).
    local function crash_fresh_any()
        if not State.crashSeen then return false end
        for _, ln in ipairs({ "mid", "top", "bot" }) do
            if now() - (State.crashSeen[ln] or -1e9) < K.CRASH_STICKY_S then return true end
        end
        return false
    end

    -- Tier-1 timing scheduler: decide shove / jungle(slack) / recover before the jungle planner.
    -- (allies/our_pri hoisted above the Tier-1 block at v0.1.227: the Tier-1.5 side-lane
    -- cascade needs allies/our_pri; the jungle planner below reuses them unchanged.)
    local allies  = ally_farm_priorities()
    local our_pri = our_farm_priority()
    State.schedSlack, State.shoveLeaveBy, State.shoveTravel = nil, nil, nil
    if State.menu.kindLane:Get() then   -- lane/shove farming; toggle OFF = jungle-only (skip the whole shove decision, schedSlack stays nil -> jungle runs full-horizon)
        local me0 = origin(State.hero)
        local enemy_push, ally_push = lane_push_dirs()       -- correct front detection per team (Radiant/Dire)
        local lanes = Lane.ScanLanes({
            team = State.team, enemy_push = enemy_push, ally_push = ally_push,
            anchors = static_anchors(), allowed_kinds = keen_allowed_kinds(),
            hero_pos = { x = me0.x, y = me0.y },
            move_speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320,
            tp = keen_tp(), game_time = now(),   -- v0.1.230: ladder-aware pricing
            paths = lane_paths(),   -- Piece 1.5: mirrored fogged waves (position/speed) for the meeting/decide reads
        })
        annotate_measured(lanes)   -- v0.1.256 arc B: measured front speeds for the meeting math
        local sc = schedule_ctx(lanes)
        local d = sc and Lane.Schedule.Plan(sc.plan) or nil
        -- v0.1.339 THE CYCLE ARC (TINKER_CYCLE_MACHINE_DESIGN.md sec 4): a committed PARK
        -- window short-circuits the decide - no Tier-2 re-plan, no none-flutter (g340 F1:
        -- 8-decide plan=0 bursts at 0.4s). TERMINAL = the scheduler itself wanting anything
        -- but a slack-jungle (near_due/due shove, recover/unsafe, recover/mana, defend flip
        -- all break the park through the SAME Plan ruler - no second clock), the untilT
        -- backstop, or a fresh crash-our-tower sighting (the side-defend cascade lives in
        -- the skipped Tier-1.5 block, so the sticky crashSeen must break the park here).
        if State.cyclePark then
            if now() >= State.cyclePark.untilT or not d or d.action ~= "jungle" or crash_fresh_any() then
                State.cyclePark = nil          -- terminal: fall through to the full decide
            else
                -- v0.1.343: the park target now shares idle_wait_spot with the none site
                -- (one producer) - a modest step-back from the frozen park stand, retreating
                -- to the protected pocket only on a real disable threat (latched). The park
                -- STAND itself stays frozen at latch (bug class 5); idle_wait_spot derives
                -- the tick's target from it.
                local w = idle_wait_spot({ x = State.cyclePark.x, y = State.cyclePark.y })
                local pv = Vector(w.x, w.y, me0.z)
                if me0:Distance(pv) > K.WAVE_HOLD_EPS then move_to(pv, "cycle_park") end
                State.waitInfo = { why = "cycle park", t = now() }
                return
            end
        end
        -- (the old near_due flip - jungle when slack<travel_to_mid -> shove - is folded into the
        -- v0.1.108 lane-first filler gate below, which also handles the medium-window fountain trip.)
        if d and d.action == "shove" and (d.reason ~= "due" or sc.visible) and shove_suppressed(K.HOME_LANE) then
            -- Note 1: the crash stand just proved unreachable; recover briefly instead of
            -- re-keening it. v0.1.339 (F2, g340: t=541 leave_by passed while suppressed ->
            -- +4.1s median late arrivals): a FOGGED reason=due verdict is EXEMPT - fogged
            -- arrivals ride the rolled STAMP (schedule_ctx), so a fogged due inside
            -- the 6s guard can only be the NEXT wave in the degenerate late-clear window
            -- where dispatching IS correct. A VISIBLE due keeps the flip: post-budget the
            -- just-paid remnant stays visible at eta~0 (arrival = now + pm.eta)
            -- and reads due - dispatching it is exactly the .197 3rd-W burn this guard
            -- exists for (quality-review catch: 21 of g340s 35 flips were visible-wave
            -- re-picks; only the fogged subset was the F2 late-dispatch cost).
            d.action, d.reason = "recover", "shove_stuck"
        end
        -- capture the scheduler decision + HOME-lane wave state into the consolidated trace.
        do
            local s = lanes[K.HOME_LANE]
            local ew, aw, cl = s and s.enemy_wave, s and s.ally_wave, s and s.clash
            local push = "none"
            if cl then
                push = cl.pushing .. (cl.moving and "" or "/hold")
                if cl.crashing and cl.crash_tower then
                    push = push .. (cl.crash_tower.team == State.team and ">allyTwr" or ">enemyTwr")
                end
            end
            ft.e, ft.a = ew and ew.count or 0, aw and aw.count or 0
            ft.push, ft.enH, ft.alH = push, s and s.enemy_heroes or 0, s and s.ally_heroes or 0
            ft.mana = string.format("%.0f", mana())
            ft.gpm  = string.format("%.0f", gpm())          -- A/B metric (both paths log it)
            ft.klvl = (State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0   -- v0.1.173: raid-gate diagnosis (run-11 fired ONE raid keen all game - was Keen even L2?)
            if d then
                ft.act, ft.reason = d.action, d.reason
                ft.slack   = string.format("%.1f", d.slack)
                ft.leaveby = string.format("%.0f", d.leave_by)
                ft.dl      = string.format("%.0f", d.deadline)
                ft.casts   = d.casts
                ft.eff_hp  = string.format("%.0f", sc.plan.wave.eff_hp)
                ft.dmg     = string.format("%.0f", (sc.plan.cal and sc.plan.cal.march_dmg_per_cast) or 0)
                ft.travel  = string.format("%.1f", sc.plan.travel_to_mid)
                ft.vis     = sc.visible and "y" or "n"
                ft.asrc    = sc.asrc or "-"                 -- Piece 2: arrival source (kin|held|vis|stamp|kinest|sim|grid)
                ft.risk    = string.format("%.2f", sc.risk)
                ft.dpts    = string.format("%.0f", sc.dpts or 0)   -- Risk v2 axis 1: depth points (calibrate DEPTH_POINT_BUDGET/KEEN_SHAVE)
                ft.cwhy    = sc.cwhy                               -- v0.1.203: covers-fail cause (leash-era analyzability)
                ft.deep    = sc.deep_era and 1 or 0                -- v0.1.360: the ERA the whole full-clear price is gated on. A silent gate reads exactly like a dead one (the v0.1.359 banner's own lesson), and every corpus measurement so far split lane phase on the klvl>=2 PROXY, which is not this boundary
                ft.scfull  = sc.plan and sc.plan.shove_cost_full and string.format("%.0f", sc.plan.shove_cost_full) or nil  -- v0.1.360: the full 2-cast bar in force. scfull == the one-hop cost means the full pricing did NOT apply (deep era, Rearm unlevelled, or the feasibility guard suppressed it) - that equality is how you read the guard, and it is also why the new rule can never double-fire with the one-hop verdict above it
                ft.thin1   = sc.thin1 and K.HOME_LANE or nil       -- v0.1.345 FIX B signature
                ft.recfits = d.recover_fits and "y" or "n"  -- Plan v2 recover fit (calibration only)
                ft.prisk   = string.format("%.2f", sc.path_risk or 0)   -- item 6: corridor risk
                ft.prisk_sh = sc.path_risk_sh and string.format("%.2f", sc.path_risk_sh) or nil   -- v0.1.409 SHADOW rider
                if sc.bal then ft.bal = string.format("%d", sc.bal) end   -- item 7: push-sim balance (asrc=sim when it set the deadline)
            end
        end
        -- The veto cascade (far_dead/deep_skip, thin_wave, no_safe_stand, the lane-first filler,
        -- defend_crash) lives in Lane.Schedule.Plan v2 now - ordered lib rules with the hard-won
        -- invariants PINNED BY TESTS (BUG-1: a vetoed jungle never resurrects through the filler;
        -- the defer LAW: the deadline is always the CURRENT wave). schedule_ctx feeds the facts.
        -- History/rationale: TINKER_LANE_GLUE_DESIGN.md item 1 + the pre-rebuild git history.
        if d and d.action == "shove" then
            -- INCREMENT 2 (v0.1.229, user: "not prioritizing mid after their T1 fell - lane
            -- phase is over"): in the DEEP ERA a farmable mid wave no longer auto-wins - it
            -- competes against the side lanes under the same risk-then-gold rule (run-49:
            -- deep-era side waves earned 456-593 g/min vs mid's 307). defend_crash stays
            -- ABSOLUTE (a defense is not a farm choice). Pre-deep: byte-identical dispatch.
            if sc.deep_era and d.reason ~= "defend_crash"
               and State.menu.sideLanes and State.menu.sideLanes:Get() then
                local best, bestCtx = eval_side_lanes(lanes, allies, K.ROUTE_HORIZON_S, ft)
                local mid_gold = (lanes[K.HOME_LANE] and lanes[K.HOME_LANE].enemy_wave
                                  and lanes[K.HOME_LANE].enemy_wave.gold) or 0
                if best and (best.risk < sc.risk
                             or (best.risk == sc.risk and best.gold > mid_gold)) then
                    dispatch_shove(best.lane, bestCtx, math.min(best.casts or 2, 2), lanes[best.lane])
                    ft.lane, ft.dpick = best.lane, string.format("%s:%.2f", best.lane, best.risk)
                    ft.seff, ft.sgold, ft.ssrc = string.format("%.0f", bestCtx.plan.wave.eff_hp or 0), string.format("%.0f", bestCtx.gold or 0), bestCtx.asrc or "?"   -- v0.1.240 seff/sgold; PHASE 2 ssrc=vis|kin|kinest|stamp
                    ft.sx, ft.sy = string.format("%.0f", bestCtx.stand.x), string.format("%.0f", bestCtx.stand.y)
                    ft.ax, ft.ay = string.format("%.0f", bestCtx.aim.x), string.format("%.0f", bestCtx.aim.y)
                    emit_farm("shove")
                    return
                end
                if best or ft.swtop then ft.dpick = string.format("mid:%.2f", sc.risk) end   -- the compete ran, mid won
            end
            dispatch_shove(K.HOME_LANE, sc, d.casts, lanes[K.HOME_LANE])
            ft.lane = K.HOME_LANE                             -- ALL-LANES: every shove pick names its lane (analyzer symmetry)
            ft.sx, ft.sy = string.format("%.0f", sc.stand.x), string.format("%.0f", sc.stand.y)
            ft.ax, ft.ay = string.format("%.0f", sc.aim.x), string.format("%.0f", sc.aim.y)
            emit_farm("shove")
            return
        elseif d and d.action == "recover" and d.reason ~= "unsafe" and d.reason ~= "shove_stuck" then
            State.spot = nil; State.fsm = "RETURN"          -- reason=mana/recharge: genuinely go home
            emit_farm("recover")
            return
        end
        -- jungle, OR an UNSAFE/SUPPRESSED shove: fall through to the jungle planner and farm a
        -- SAFE camp instead of idling home. unsafe = Note 2 (fountain-stuck fix). shove_stuck =
        -- v0.1.158: a 6s stand-suppression used to dispatch RETURN, so every 0.4s decide in the
        -- window keened Tinker HOME (one abort at t=535 kept 217+ mana walking to base; 61 of 139
        -- decides churned recover/shove_stuck + the fountain DECIDE<->RETURN bounce = the slow
        -- teleports / walk-from-fountain / long-wait notes). Neither carries the shove leave-by:
        -- the shove is abandoned; the next decide re-checks and shoves once the window clears.
        if d and d.action == "recover" then
            State.schedSlack, State.shoveLeaveBy, State.shoveTravel, State.shoveReturnPos = nil, nil, nil, nil
            stuckWindow = (d.reason == "shove_stuck")
            -- act=recover reason=unsafe/shove_stuck stays in ft; the eventual pick shows where the fallback landed.
        else
            -- v0.1.210 (run-34 single-camp ROOT CAUSE, the okp= instrument paid off): the slack
            -- cap + return-leg reservation applied to EVERY act=jungle, including VETOED waves
            -- (gone_by_arrival / thin_wave / deep_skip / far_wave / no_safe_stand). A dead wave's
            -- slack squeezed the planner horizon and reserved a return leg FOR A SHOVE THAT DOES
            -- NOT EXIST - pairs (clear + return would not fit) dropped out and the nearest lonely
            -- SINGLE won (run-34: paired=false picks with okp=2-4 affordable pairs, all on
            -- gone_by_arrival decides). Only a GENUINE slack-jungle (reason=slack) carries the
            -- window; vetoed waves get the full ROUTE_HORIZON_S like any pure jungle decide.
            State.schedSlack   = (d and d.reason == "slack") and d.slack or nil
            -- v0.1.127 (Notes 2/4/5 stuck-at-camp churn): carry the shove leave-by ONLY for a GENUINE
            -- slack-jungle (d.reason=="slack") - then the camp engage is correctly preempted to return and
            -- shove the NEXT wave. A VETOED shove (dive_infeasible / too_deep / deep_skip / thin_wave) is
            -- ABANDONED; its leave_by is the CURRENT overdue wave's, already in the PAST, so carrying it
            -- made the camp engage preempt INSTANTLY at casts=0 EVERY decide -> Tinker keened to a (deep)
            -- camp, never farmed it (138x casts=0 this game), re-vetoed, and churned at a deep outpost
            -- (stuck + death). Clearing it lets the vetoed-jungle camp actually farm; next decide (every
            -- DECIDE_GAP) re-evaluates the wave and shoves once it is feasible.
            -- CORRECTION (v0.1.405): that re-evaluation only happens while the hero is STILL in
            -- DECIDE (pick=none). A camp/stack dispatch sets fsm=MOVE, and fsm_move has NO leave_by
            -- check of any kind, so a committed camp is blind to the lane clock for the whole
            -- travel+clear leg. Do NOT read the line above as a claim that the wave is safe during
            -- a commit. MEASURED: engage_preempt has fired ZERO times in 43 logs, so this whole
            -- preemption path is dead code, not a working feature withheld from veto-jungles.
            State.shoveLeaveBy = (d and d.reason == "slack") and d.leave_by or nil
            State.shoveTravel  = d and sc.plan.travel_to_mid or nil   -- to-mid ETA; folds into the horizon (BUG 2)
            State.shoveReturnPos = sc and sc.crash_pos or nil          -- BUG 2: where the camp planner must return to (mid meeting)

            -- ALL-LANES Tier-1.5 (v0.1.227, TINKER_ALLLANES_DESIGN.md; mid > SIDE > jungle):
            -- mid said jungle (slack or vetoed wave) - offer the window to the side lanes
            -- before camps. An eligible side shove must fit ITS window: mid's leave_by on a
            -- genuine slack-jungle, else the same 30s horizon camps get (a side trip must
            -- never eat the NEXT mid wave). Selection is risk-ruled: lowest composed stand
            -- risk wins, gold breaks ties. The recover branch (unsafe/shove_stuck) never
            -- reaches here - live pressure falls back to safe camps, not another lane.
            -- INCREMENT 2 (v0.1.229, deep era): the window is the generic 30s and a side
            -- dispatch drops mid's leave_by - full flattening, no mid preempt; the next
            -- decide re-runs the competition and mid re-wins when genuinely best.
            if State.menu.sideLanes and State.menu.sideLanes:Get() then
                local deep = sc and sc.deep_era or false     -- sc can be nil (no home-lane scan state)
                local window = (not deep and State.shoveLeaveBy and (State.shoveLeaveBy - now()))
                               or K.ROUTE_HORIZON_S
                local best, bestCtx = eval_side_lanes(lanes, allies, window, ft)
                if best then
                    dispatch_shove(best.lane, bestCtx, math.min(best.casts or 2, 2), lanes[best.lane])
                    if deep then State.shoveLeaveBy = nil end   -- full flattening: no mid preempt on a deep-era side win
                    ft.lane = best.lane
                    ft.seff, ft.sgold, ft.ssrc = string.format("%.0f", bestCtx.plan.wave.eff_hp or 0), string.format("%.0f", bestCtx.gold or 0), bestCtx.asrc or "?"   -- v0.1.240: the SIDE wave's own numbers (ft.eff_hp is mid's); PHASE 2 ssrc
                    ft.sx, ft.sy = string.format("%.0f", bestCtx.stand.x), string.format("%.0f", bestCtx.stand.y)
                    ft.ax, ft.ay = string.format("%.0f", bestCtx.aim.x), string.format("%.0f", bestCtx.aim.y)
                    emit_farm("shove")
                    return
                end
            end
        end
    end

    -- unified candidates (camps + visible waves) + the plan (same builder as the Route-scan diag).
    -- (allies/our_pri computed above the Tier-1 block since v0.1.227.)
    local targets = gather_route_targets(allies, our_pri)
    local ropts = route_opts()
    if stuckWindow then
        -- v0.1.158: a suppressed shove only frees the suppression window - cap the horizon so
        -- only what FITS it is picked; never a far keen-to-camp trek. v0.1.208: the window is
        -- the ACTUAL remaining suppression (a tether release suppresses for up to ~25s = a real
        -- camp window), floored at the old SHOVE_STUCK_S for the classic 6s stuck cases.
        local win = math.max(K.SHOVE_STUCK_S, (State.shoveSuppress[K.HOME_LANE] or 0) - now())
        ropts.horizon_s = math.min(ropts.horizon_s, win)
    end
    if State.schedSlack and State.schedSlack > 0 then    -- jungle only in the slack before the next shove
        -- v0.1.125 (BUG 2): the horizon is the time until the wave ARRIVES at mid = schedSlack + the
        -- to-mid travel (leave_by already subtracted travel, so schedSlack alone undercounts the window by
        -- one trip). The per-camp RETURN to mid is reserved INSIDE Route via return_pos (KEEN-aware
        -- InterceptETA over the same static anchors as the outbound ETA), so a far camp whose camp->mid
        -- return won't fit before the wave is dropped - the RIGHT leg (camp->mid), per-camp. Replaces the
        -- old wrong-leg double-subtract (budget = slack - hero->mid travel, which counted the to-mid trip
        -- twice and reserved the hero's distance, not the camp's). The keen-aware return avoids the v0.1.93
        -- pure-walk over-exclusion; the leave_by preempt (fsm_engage) bounds any return under-estimate.
        local horizon = State.schedSlack + (State.shoveTravel or 0)
        ropts.horizon_s = math.min(ropts.horizon_s, math.max(0, horizon))
        if State.shoveReturnPos then
            ropts.return_pos     = State.shoveReturnPos
            ropts.return_anchors = static_anchors()
            ropts.return_speed   = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
            ropts.return_tp      = keen_tp()   -- v0.1.230: ladder-aware pricing
        end
        ft.reserve = string.format("%.1f", State.shoveTravel or 0)
        ft.horizon = string.format("%.1f", ropts.horizon_s)
    end
    State.routePlan = Lane.Route.Plan(targets, route_hero_state(), ropts)
    -- v0.1.181 camp-drought instrument (run-16: plan=0 at FULL mana from base, 37 none-idles, the
    -- killer stage invisible): tally WHERE camp targets die, mirroring Lane.Route.Plan's pool filter +
    -- the afford gate. ft.rej = contested / risk-veto / leg-cap / afford / ok. Remove once the
    -- drought is root-caused off one run.
    do
        local hs = route_hero_state()
        local nC, nR, nL, nA, nF, nFp, need = 0, 0, 0, 0, 0, 0, nil
        for _, tg in ipairs(targets) do
            if tg.kind == "camp" then
                if tg.contested then nC = nC + 1
                elseif (tg.risk or 0) >= K.RISK_HARD then nR = nR + 1
                elseif K.MAX_CAMP_TRAVEL_S and Lane.Route._leg_time(hs.pos, tg, hs) > K.MAX_CAMP_TRAVEL_S then nL = nL + 1
                else
                    -- v0.1.199: track the CHEAPEST price among camps that reach the afford stage, so
                    -- --farm-audit can machine-check the gate (ok>0 <=> pm >= need) and flag refills
                    -- that cannot unlock any camp even at the ceiling (need > cap).
                    local price = (tg.mana_cost or 0) + (hs.reserve_mana or 0)
                    if not need or price < need then need = price end
                    if hs.mana < price then nA = nA + 1
                    else
                        nF = nF + 1
                        if tg.partnerRef then nFp = nFp + 1 end   -- v0.1.205: pair nodes among ok (singles-vs-pairs analyzability)
                    end
                end
            end
        end
        ft.rej = string.format("c%d/r%d/l%d/a%d/ok%d", nC, nR, nL, nA, nF)
        ft.okp = string.format("%d", nFp)                          -- v0.1.205: how many of ok are PAIR nodes
        ft.need = need and string.format("%.0f", need) or nil
        ft.pm   = string.format("%.0f", hs.mana)
        ft.cap  = string.format("%.0f", hs.max_mana)
    end
    local cfill   -- v0.1.339 THE CYCLE ARC: the fill decision for an empty window (Task-4 park consumes it too)
    if #State.routePlan.steps == 0 then
        -- Run-6 fix history: when nothing is affordable the right move IS the refill (the gated
        -- plan often cannot fit refill + camp inside a slack-capped horizon, so it comes back
        -- empty rather than proposing the trip). v0.1.339 (TINKER_CYCLE_MACHINE_DESIGN.md,
        -- the ledgered .296+.302 re-apply) replaced the v0.1.165 70%-of-max rule here;
        -- v0.1.340 (the g341 re-calibration) SPLIT trigger from fill: fountain iff the pool
        -- sits under the .296 broke floor ONLY (cannot fund the NEXT WAVE - the cycle-cost
        -- trigger read stricter than the old rule at Keen L1 and ate the forward tether
        -- posture, g341: tether 21.6 -> 6.8 pct, GPM 489 -> 356); the refill NEED still
        -- fills to the cycle cost (the .302 semantics). HP keeps its own refill trigger
        -- unchanged (health is not mana economics). Funded + healthy -> park (Task 4).
        local h = State.hero
        local mmax = (NPC.GetMaxMana and NPC.GetMaxMana(h)) or 1
        local hmax = Entity.GetMaxHealth(h) or 1
        local ccost = Lane.Schedule.WaveCycleCost({
            w = abil_mana(State.march, K.MARCH_MANA_FB),
            rearm = abil_mana(State.rearm, K.REARM_MANA_FB),
            keen = abil_mana(State.keen, K.KEEN_MANA_FB),
        })
        cfill = Lane.Schedule.CycleFill({
            pool = effective_mana(),
            max_pool = mmax,
            cycle_cost = ccost,
            broke_bar = hop_mana_cost() + K.SHOVE_MANA_RESERVE,
        })
        if cfill.fill == "fountain" or (Entity.GetHealth(h) or hmax) < hmax * K.REFILL_FRAC then
            if cfill.fill == "fountain" then
                State.refillNeed = cfill.need
                logline(string.format("cycle_fill fill=fountain window=%.1f need=%.0f cost=%.0f pool=%.0f",
                    State.schedSlack or -1, cfill.need or 0, ccost, effective_mana()))
            end
            State.spot = nil
            State.fsm  = "RETURN"
            emit_farm("refill")
            return
        end
    end
    -- keep the camp candidates for the debug overlay (draw_debug reads c.type/c.ehp/c.gold).
    local camps = {}
    for _, t in ipairs(targets) do if t.kind == "camp" then camps[#camps + 1] = t.ref end end
    State.cands = camps
    local f = State.funnel or {}   -- funnel breakdown: vis=in-sight, est=fogged-assumed, cleared=skipped
    ft.total, ft.fvis, ft.est, ft.fseen, ft.fcleared = f.total, f.vis, f.est, f.seen, f.cleared
    ft.plan, ft.gpm = #State.routePlan.steps, string.format("%.0f", gpm())
    -- v0.1.205 (singles-vs-pairs analyzability): the plan's first two steps, kind:value:paired -
    -- a lonely-single pick is machine-distinguishable from a pair snub without guessing.
    for i = 1, 2 do
        local st = State.routePlan.steps[i]
        ft["p" .. i] = st and string.format("%s:%.0f:%s", st.kind, st.value or 0,
                                            st.partnerRef and "y" or "n") or nil
    end

    local first = State.routePlan.steps[1]
    if not first then
        -- v0.1.210 (run-34 t=956-964: a tether release at wait=10.1 suppressed into an EMPTY
        -- window = 18 none-flutter decides in 8s, strictly worse than holding): a suppressed
        -- window the planner cannot fill is USELESS - cancel the suppression so the next decide
        -- re-commits the shove and tethers properly, and block re-releasing for one hold period
        -- (else release->empty->cancel would ping-pong at decide cadence).
        -- v0.1.252: only a TETHER-RELEASE suppression may be canceled here. The old unconditional
        -- cancel also undid UNSAFE-abort safety windows (run-65: shove -> abort unsafe -> cancel ->
        -- re-shove toward 2 heroes, every decide) and BUDGET delivery windows (run-67: 2 of 3
        -- cancels; re-shoving a paid wave = the v0.1.197 3rd-W class). Safety/budget/stuck windows
        -- are short (SHOVE_STUCK_S) and must run out; the protected none-idle owns the wait.
        if stuckWindow and shove_suppressed(K.HOME_LANE)
           and now() < (State.releaseSuppress[K.HOME_LANE] or 0) then
            State.shoveSuppress[K.HOME_LANE] = 0
            State.releaseSuppress[K.HOME_LANE] = 0
            State.releaseBlockUntil = now() + K.TETHER_MAX_HOLD_S
            logline("release_cancel empty_window -> re-tether")
            State.spot = nil; emit_farm("none"); return
        end
        -- v0.1.339 THE CYCLE ARC: a funded, healthy, genuine slack window that nothing fits
        -- = the PARK fill (user decision 2026-07-23: being early IS the value). Latch ONCE;
        -- the short-circuit above owns every subsequent tick until the scheduler wants
        -- action. Only reason=slack windows park: State.schedSlack IS the verdict proxy
        -- (set ONLY on slack jungles per the .209/.210 contract, nil-reset each decide; the
        -- lane block's `local d` is block-scoped and unreachable here - the spec-review
        -- catch), so vetoed-wave jungles (no schedSlack) stay on the old per-tick posture,
        -- bounded + rare.
        -- The park stand = the .328 idle pre-position home (frozen at latch - bug class 5).
        if not stuckWindow and cfill and cfill.fill == "park" and not crash_fresh_any() then   -- shared sweep: kills the site A/B latch-clear ping-pong (quality-review item 2)
            local lw = State.lastWaveStand
            if lw and (now() - (lw.t or 0)) < 60 and State.schedSlack and State.schedSlack > 0 then
                State.cyclePark = { untilT = now() + math.min(State.schedSlack, K.WAVE_PERIOD),
                                    x = lw.x, y = lw.y }
                logline(string.format("cycle_fill fill=park window=%.1f pool=%.0f",
                    State.schedSlack, effective_mana()))
            end
        end
        -- v0.1.343 THE ONE-PRODUCER WAIT (TINKER_WAIT_CAST_DESIGN.md): idle at a modest
        -- step-back from the last cast stand - kept < W_PRE_STAND_R of the stand so the W1
        -- lead-cast gate stays open and the pre-cast still fires (NOT an engage-range bound;
        -- see idle_wait_spot). Retreat to the protected pocket ONLY on a real disable threat
        -- (idle_wait_spot, latched). Replaces the .328/.160 two-target flip (idle_prepos vs
        -- idle_retreat) whose hero-anchored enemy/frontier boundary was the A-B-A oscillator
        -- (.283 census 73 flaps). One target, one src -> no flip. The step-back IS the user's
        -- "back before the next wave" / "step back after W2" posture, emergent from the target.
        -- A stale/absent stand (>60s, or pre-first-shove) still gets the disabler retreat via
        -- idle_wait_spot(nil); a nil return = nothing fits -> hold (reactive layers own safety).
        local me = origin(State.hero)
        local lw = State.lastWaveStand
        local lwFresh = lw and (now() - (lw.t or 0)) < 60
        local w = idle_wait_spot(lwFresh and lw or nil)
        if w then
            local wv = Vector(w.x, w.y, me.z)
            if me:Distance(wv) > K.WAVE_HOLD_EPS then move_to(wv, "idle_wait") end
        end
        -- v0.1.163 (user): the none-idle is a deliberate wait too (suppression / no target fits)
        State.waitInfo = { why = stuckWindow and "suppressed" or "window", t = now() }
        State.spot = nil; emit_farm("none"); return
    end

    if first.kind == "stack" then               -- v0.1.224: the timed-aggro maneuver (large camps, 2x cap)
        local c = first.ref
        local fp = friendly_fountain_pos()
        local sx, sy = c.center.x, c.center.y
        if fp then
            local dx, dy = fp.x - c.center.x, fp.y - c.center.y
            local dl = math.sqrt(dx * dx + dy * dy); if dl < 1 then dl = 1 end
            sx, sy = c.center.x + dx / dl * K.STACK_STAND_DIST, c.center.y + dy / dl * K.STACK_STAND_DIST
        end
        local st = Map.SnapWalkable({ x = sx, y = sy }, { x = c.center.x, y = c.center.y })
        c.kind = "stack"
        c.standSpot = { stand = Vector(st.x, st.y, c.center.z), aim = Vector(st.x, st.y, c.center.z) }
        c.aggroAt, c.fleeUntil, c.aggroed = first.stackWin.aggro_at, first.stackWin.done, false
        c.clearEst, c.planCost = first.clear_t or 0, 0
        State.spot, State.marchCasts, State.fsm = c, 0, "MOVE"
        State.keenedSpot = false   -- v0.1.286 (run-94 1:30 cross-map walks): a NEW commit is a NEW leg - the stale latch skipped the keen rung and walked 7700+ (why=latched)
        State.moveSince = now()
        -- v0.1.408: this commit cleared ONLY keenedSpot and moveSince, while its CAMP sibling
        -- clears five per-spot latches. A stack leg therefore entered fsm_move carrying the
        -- PREVIOUS spot state, contradicting the invariant stated at the no_progress definition
        -- (State.moveTrack resets per committed spot) and able to false-trip that watchdog on
        -- arrival. Bug class 2, stale state at a commit site.
        -- MEASURED DORMANT, which is why this is behaviourally free: pick=stack occurs 0 times in
        -- 45 logs, and stackWin/aggroAt, written ONLY in this block, appear 0 times in any log.
        -- The gate is first.kind == stack and the route planner has never returned one.
        -- SEPARATE OPEN QUESTION, do not conflate: whether the v0.1.224 timed-aggro stack
        -- maneuver is reachable AT ALL. This fix only makes the block correct for the day it runs.
        State.moveTrack = nil        -- reset the P0 no-progress watchdog for the new spot
        State.rearmStepback = nil    -- v0.1.267: a step-back belongs to the OLD spot engage
        State.marchPending = nil
        State.emptySince = nil
        ft.ctype, ft.cgold = c.type, math.floor(c.gold or 0)
        ft.sx, ft.sy = string.format("%.0f", st.x), string.format("%.0f", st.y)
        emit_farm("stack")
        return
    end
    if first.restore then                       -- Note 4: the planner chose to refill -> hand off to RETURN
        -- COST-AWARE refill (ancient arc): remember what the NEXT planned step needs so the
        -- fountain wait fills to it (mana_cost + keen reserve, capped in fsm_return). Without
        -- this the 0.70 leave un-funds the exact target the refill was inserted to enable.
        local nxt = State.routePlan.steps[2]
        State.refillNeed = (nxt and not nxt.restore and nxt.mana_cost)
            and (nxt.mana_cost + abil_mana(State.keen, K.KEEN_MANA_FB)) or nil
        if State.refillNeed then ft.rneed = string.format("%.0f", State.refillNeed) end
        State.spot = nil
        State.fsm  = "RETURN"
        emit_farm("refill")
        return
    end

    -- first.kind is always "camp" here: gather_route_targets emits camps + the refill node only
    -- (handled above). The old non-shove route-wave branch was DELETED (glue review F2) - waves
    -- are owned by the Tier-1 shove dispatch above.
    local c = first.ref                                   -- the camp candidate (gather_candidates record)
    if first.partnerRef then                              -- #2/#3: pairing decided at valuation; build the pair stand directly (no re-search)
        local A, B = c.center, first.partnerRef.center
        c.standSpot = { stand = Vector((A.x + B.x) / 2, (A.y + B.y) / 2, A.z),
                        aim   = Vector((A.x + B.x) / 2, (A.y + B.y) / 2, A.z),
                        paired = true, partner = B,
                        partnerCamp = first.partnerRef.camp, partnerType = first.partnerRef.type,
                        clear = first.pairClass, pd = first.pairPd }
    else
        c.standSpot = best_stand_spot(c)                  -- single-camp ring search
        -- v0.1.189 instrument (user: "we shouldn't get singles from pairs"): a SINGLE pick logs
        -- its nearest live candidate's distance - nnd <= PAIR_RADIUS on a single = a pairable
        -- partner existed and GreedyPairs/the cleared-flag left it out -> dig that. nnd above =
        -- genuinely partnerless (isolated / partner cleared this cycle). Read it off pick=camp
        -- paired=false lines next run.
        local nnd
        for _, o in ipairs(State.cands or {}) do
            if o ~= c and o.center then
                local d = c.center:Distance(o.center)
                if not nnd or d < nnd then nnd = d end
            end
        end
        ft.nnd = nnd and string.format("%.0f", nnd) or "-"
    end
    if not c.standSpot then State.spot = nil; emit_farm("none"); return end
    c.kind = "camp"
    c.clearEst = first.clear_t or 0                       -- timing calib: the planner's clear_t estimate for this camp/pair
    c.planCost = first.mana_cost or 0                     -- v0.1.212 cost-truth census: planned mana vs the real clear (logged at engage exit)
    local spot = c

    State.spot, State.marchCasts, State.fsm = spot, 0, "MOVE"
    State.keenedSpot = false   -- v0.1.286 (run-94 1:30 cross-map walks): a NEW commit is a NEW leg - the stale latch skipped the keen rung and walked 7700+ (why=latched)
    State.moveSince = now()
    State.moveTrack = nil   -- reset the P0 no-progress watchdog for the new spot
    State.rearmStepback = nil   -- v0.1.267: a step-back belongs to the OLD spot's engage
    State.keenedSpot = false
    State.marchPending = nil
    State.emptySince = nil

    local ss = spot.standSpot
    ft.ctype, ft.cgold, ft.cstk = spot.type, math.floor(spot.gold or 0), camp_stacks(spot.gold, spot.type)
    ft.csrc, ft.cval = spot.source or "est", math.floor(first.value or 0)
    ft.crisk = string.format("%.2f", first.risk or 0)
    ft.crisk_sh = first.risk_sh and string.format("%.2f", first.risk_sh) or nil   -- v0.1.409 SHADOW rider (camp nodes only; wave/refill nodes carry no risk_sh)
    ft.ncreep, ft.paired = #(spot.creeps or {}), tostring(ss.paired or false)
    ft.cx, ft.cy = math.floor(spot.center.x), math.floor(spot.center.y)
    ft.sx, ft.sy = math.floor(ss.stand.x), math.floor(ss.stand.y)
    if ss.partner then ft.pcx, ft.pcy = math.floor(ss.partner.x), math.floor(ss.partner.y)
    elseif State.pairSkip then ft.pairskip = State.pairSkip end
    emit_farm("camp")
end

-- Track the LIVE wave: read enemy lane creeps near the wave's last-known point, advance s.refPoint (the
-- count centroid, for distance/engage-range), re-aim s.standSpot.aim at the moving wave so the March
-- lands on it, AND re-derive s.standSpot.stand from the live wave through the SAFE stand composition
-- (v0.1.155). History: T4a froze the stand because the old recompute was an UNCLAMPED raw offset that
-- slid under towers on a deep wave; the composed stand (CrashCast + Map.Nav.SafeDest(tower_safe) + snap)
-- cannot, and the freeze itself proved to be a stuck-bug (a fogged decide's estimate froze a stand
-- outside both engage triggers -> the hero stood at it forever while the real wave fought 1240u away).
-- Returns { cx, cy, n } of the live cluster, or nil when the wave is gone (no enemy creeps near).
local function update_wave_spot(s)
    local creeps = enemy_lane_creeps_near(s.refPoint, K.WAVE_TRACK_RADIUS)
    if #creeps == 0 then return nil end
    local cx, cy = 0, 0
    for _, c in ipairs(creeps) do cx = cx + c.pos.x; cy = cy + c.pos.y end
    cx, cy = cx / #creeps, cy / #creeps
    local z = origin(State.hero).z
    s.refPoint = Vector(cx, cy, z)                 -- live tracker = count centroid (distance/stand math)
    -- ON (anticipation): anchor the AIM on the TRAILING RANGED creep (the deepest enemy creep = furthest
    -- from our fountain), so the March footprint lands on it (Note 1) instead of falling short of the
    -- melee-front centroid. The STAND is NOT frozen: v0.1.155 re-derives it from the LIVE wave through safe_stand_for (tower-safe +
    -- depth-capped) in BOTH branches below, so this fn re-aims AND re-stands.
    do   -- T0 collapsed: the ranged-anchored live aim/stand is the only path (span-center below stays as the fallback)
        local fp0 = friendly_fountain_pos()
        local ranged, bestd = nil, -1
        if fp0 then
            for _, c in ipairs(creeps) do
                local dx, dy = c.pos.x - fp0.x, c.pos.y - fp0.y
                local dd = dx * dx + dy * dy
                if dd > bestd then bestd, ranged = dd, c.pos end
            end
        end
        if ranged then
            -- ON: anchor the AIM on the trailing ranged creep (the cast lands on it) AND re-derive the
            -- STAND from the LIVE wave through the SAFE composition (v0.1.155): the decide-time stand
            -- froze 900-back of a possibly-lying estimate (fogged mirror ~400u off), leaving the hero
            -- outside BOTH engage triggers forever (dref ~1240 > 950/1150 = the completely-stuck lane).
            -- The freeze existed because the OLD recompute was an unclamped raw offset that slid under
            -- towers; safe_stand_for is CrashCast + Map.Nav.SafeDest(tower_safe) + snap now, so live
            -- tracking is safe. Not coverable -> fall through to the OFF span-center aim.
            -- glue review F19 (v0.1.157): forward is CONTESTED-AWARE, same as the decide-time stand
            -- (forward 850 only on a clear lane; a live-appearing enemy backs the stand to 900).
            -- v0.1.192: mid-commit deep_ok = shove + Keen L2 (NO ready requirement - after the raid
            -- keen lands deep, keen is on cd; requiring ready would clamp the live stand back to
            -- the stairs and walk him out of his own engage).
            local dok = s.shove and ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
            -- W-GEOM-1 (was: forward = not lane_unsafe(ranged), the F19 contested flag): the live
            -- stand ALWAYS anchors the ranged at the standard 810. The old contested fallback stood
            -- 900 from the ranged = the exact coverage edge (casts at 100% reach = the ranged
            -- surviving "by a little"). Contested safety is owned by the risk gates (lane_unsafe
            -- aborts the engage; enemy_risk gates the shove), not by 90u past guaranteed coverage.
            local st, cov = safe_stand_for(ranged, true, dok, s.lane)
            if st and cov then
                s.standSpot.aim = Vector(ranged.x, ranged.y, z)
                s.standSpot.stand = Vector(st.x, st.y, z)
                return { cx = cx, cy = cy, n = #creeps }
            end
        end
        -- no fountain / not coverable: fall through to the OFF logic
    end
    -- along-lane axis = centroid -> our fountain (the dir enemy creeps push; melee lead, ranged trail).
    local fp = friendly_fountain_pos()
    local ax, ay = 0, 0
    if fp then
        local dx, dy = fp.x - cx, fp.y - cy
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then ax, ay = dx / dl, dy / dl end
    end
    -- AIM at the along-lane SPAN CENTER (covers melee front + ranged back), not the melee-weighted
    -- count centroid -> the March clears the trailing ranged creep instead of leaving it for an extra W.
    local pts = {}
    for _, c in ipairs(creeps) do pts[#pts + 1] = { x = c.pos.x, y = c.pos.y } end
    local aimc = ((ax ~= 0 or ay ~= 0) and Farm.WaveAimCenter(pts, ax, ay)) or { x = cx, y = cy }
    if (ax ~= 0 or ay ~= 0) and K.WAVE_LEAD ~= 0 then    -- Note 5: lead toward the trailing ranged creep (-axis = away from our fountain), so the footprint spans it
        aimc = { x = aimc.x - ax * K.WAVE_LEAD, y = aimc.y - ay * K.WAVE_LEAD }
    end
    s.standSpot.aim = Vector(aimc.x, aimc.y, z)
    -- v0.1.155: the STAND tracks the live wave through the SAFE composition too (see the ON-branch
    -- note). The old T4 freeze guarded against the UNCLAMPED raw offset sliding under towers; the
    -- composed stand is tower-clamped + walkable, so live tracking is safe and the engage triggers
    -- stay geometrically reachable when the decide-time meeting estimate was off.
    local st, cov = safe_stand_for({ x = aimc.x, y = aimc.y }, false,
        s.shove and ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2, s.lane)   -- v0.1.192: same mid-commit deep_ok
    -- v0.1.193: NO illegal live stands. Both branches failing legality (past the stairs line /
    -- tower-blocked, non-raid) = the live wave is not walk-farmable from here -> flag it so the
    -- MOVE layer bails to a redecide NOW instead of holding the frozen stand until MOVE_TIMEOUT
    -- (the run-23 22-25s waits). The frozen decide-time stand stays for the ENGAGE aim clamp.
    if st and cov then s.standSpot.stand = Vector(st.x, st.y, z) end
    return { cx = cx, cy = cy, n = #creeps, nocover = (st and not cov) or nil }
end

-- Shared no-progress watchdog (Note 1): a Keen can land on terrain we cannot path to the stand
-- from (e.g. a tower's high ground), so move_to spins forever and never times out. True when
-- distance-to-target has not improved by PROGRESS_EPS within NO_PROGRESS_S (Map.Nav.Stuck, the lib
-- home of the watchdog family). Caller decides the recovery (camp marks cleared; a shove just
-- re-decides). State.moveTrack resets per committed spot. Only for STATIC stands; the live-wave
-- stand moves with the cluster (use MOVE_TIMEOUT there).
local function no_progress(d)
    local stuck
    State.moveTrack, stuck = Map.Nav.Stuck(State.moveTrack, d, now(),
        { eps = K.PROGRESS_EPS, window = K.NO_PROGRESS_S })
    return stuck
end

-- v0.1.216: did the last keen actually TELEPORT? A channel canceled by its dying anchor leaves
-- the hero in place with the cd burned; reset keenedSpot so the movement ladder recovers via
-- rearm -> keen instead of walking the whole leg. Called at the MOVE fsm heads (camp + wave).
local function keen_cancel_check()
    local kp = State.keenPending
    if not kp or now() < kp.due then return end
    State.keenPending = nil
    -- v0.1.219 (run-42: 17 keen_canceled, most FALSE POSITIVES - e.g. t=504 fired 2s after a
    -- fresh cast, i.e. judging a STALE pending from an earlier SUCCESSFUL keen; the fsm had gone
    -- MOVE->ENGAGE before due so the check never ran, and the next MOVE trip read the hero far
    -- from the old landing -> phantom cancel -> a re-keen+rearm burned ~375 mana each, 17x =
    -- the run's fountain/coverage regression): the walked-away-vs-canceled judgment is only
    -- valid FRESH - a genuine cancel keeps the hero parked at the cast spot with MOVE ticking
    -- every 0.4s, so the check runs within a tick of due. Anything older just clears.
    if now() > kp.due + 1.5 then return end
    -- v0.1.221 (run-44: 14 keen_canceled remained, mostly CREEP keens - the teleport arrives at
    -- the creep's CURRENT position, which moved during the ~3s channel, so the landing-distance
    -- test misfires on fast waves): the true cancel signature is STILL STANDING AT THE CAST
    -- ORIGIN with the channel over - a rooted channel cannot walk away, and any teleport (to the
    -- planned landing OR the moved creep) leaves the origin.
    local me = origin(State.hero)
    if kp.origin and me:Distance(Vector(kp.origin.x, kp.origin.y, me.z)) < 600 then
        State.keenedSpot = false
        logline("keen_canceled -> re-ladder")
    end
end

-- Piece 0 (TINKER_LANE_NAV_DESIGN.md): the LANE movement chokepoint. Every lane move routes here:
-- ONE structural safety policy (Map.Nav.SafeDest clamp toward our fountain + report) + ONE transport
-- ladder (Map.Nav.Ladder: keen -> rearm-reset -> blink -> walk, executed via the existing gated
-- primitives, falling through on primitive failure). Jungle keeps its own paths (separate layer);
-- dynamic danger (enemies) stays with the FSM live aborts. The clamp log is the Piece-1 instrument:
-- every "lane_go clamp" line is evidence of an upstream bad-stand bug.
-- `raid` (Phase 2, TINKER_ANCHOR_TETHER_DESIGN.md R1): allow allied lane CREEPS as keen anchors
-- for this leg - the L2 in-and-out. Only the shove STAND approaches pass it (holds/tether waits
-- stay structure-anchored); every landing still runs the full gate set in keen_to_anchor
-- (lane_unsafe + tower_safe + depth-vs-stand cap + clear_landing), so an unsafe creep landing degrades
-- to a building anchor = the tether path (R3: no gate relaxed). The user's risk POINT SYSTEM
-- (2026-07-03 directive) slots here when it lands: points gate the raid instead of the L2 binary.
-- v0.1.258 I2 (TINKER_TRANSPORT_ECONOMICS.md sec 6): every walk leg > 2000u names its
-- cause - measures the walk-share split (and the dagger experiment). ZERO behavior.
local function log_walk_leg(dist, why)
    -- v0.1.347: the threshold was a hardcoded 2000, which hid almost every walk - g348 logged only
    -- FOUR walk_leg lines while WALKING was 29.4% of the run (224s of 761s), so the user's watched
    -- "useless walks / unneeded long walks" were unmeasurable. K.WALK_LEG_MIN names the mid-range
    -- legs too; the 2s debounce still bounds the volume (~1 line per 2s worst case).
    if dist <= K.WALK_LEG_MIN or now() - (State.walkLegLogT or 0) < 2 then return end
    State.walkLegLogT = now()
    -- v0.1.348: log the KEEN COOLDOWN and the walk's own cost AT THE DECISION. Without them
    -- `why=no_keen` is unjudgeable - waiting beats walking only when cd + KEEN_CHANNEL +
    -- KEEN_WAIT_MARGIN < walk_s, and g349 had 8 no_keen legs averaging 20s while the v0.1.232
    -- wait_keen rung fired ZERO times, with no way to tell whether that was correct or a dead rung.
    -- v0.1.350: the read was Ability.GetCooldownTimeRemaining, WHICH DOES NOT EXIST in the
    -- UCZone API (gitbook-verified: Ability.GetCooldown = time REMAINING before it can be cast,
    -- Ability.GetCooldownLength = the total). The `and` chain short-circuited on the nil field,
    -- so this took its -1 fallback on all 39 legs in g350 and the .348 instrument was born dead.
    -- kcd = -1 now means ONLY "no handle / the call returned nil"; a ready ability reads 0.
    -- kr = ready() (CanBeExecuted == -1, documented), logged so the next read can tell a broken
    -- call (kr=0 kcd=-1, i.e. nil while on cooldown) from a merely ready one.
    local kcd = (State.keen and Ability.GetCooldown and Ability.GetCooldown(State.keen)) or -1
    local ms  = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
    logline(string.format("walk_leg d=%.0f why=%s kcd=%.1f kr=%d walk=%.1f",
        dist, why, kcd, ready(State.keen) and 1 or 0, dist / math.max(150, ms)))
end

local function lane_go(dest, raid)
    if not dest then return nil end
    local me = origin(State.hero)
    local fp = friendly_fountain_pos()
    local retreat = { x = 0, y = 0 }
    if fp then
        local dx, dy = fp.x - dest.x, fp.y - dest.y
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then retreat = { x = dx / dl, y = dy / dl } end
    end
    -- v0.1.198 audit HOLE D - THE DEEP TRIPWIRE (assertion, not a clamp): after the census every
    -- legit caller feeds a legal destination (decide covers-exclusion, gated live re-stand,
    -- structure-anchored holds, gated step-in, capped landings), so a non-raid dest past the
    -- walk line here is BY DEFINITION an upstream producer bug. Do NOT walk it and do NOT park
    -- at the line (the v0.1.192 freeze): reject the whole action, force a redecide (Plan then
    -- excludes the target properly), suppress the flutter, and log LOUDLY - every deep_reject
    -- line in a log is a bug report with the caller's coordinates in it.
    if not raid and (stand_depth(dest, State.spot and State.spot.lane) > K.WALK_DEPTH_MAX + 50 or not lane_leash_ok(dest, 50, State.spot and State.spot.lane)) then   -- v0.1.202: raid legs exempt from the leash too (ungankable raids re-sanctioned; the dispatch is covers-gated upstream)
        logline(string.format("lane_go deep_reject (%.0f,%.0f) depth=%.0f -> redecide (UPSTREAM BUG)",
            dest.x, dest.y, stand_depth(dest)))
        suppress_shove(State.spot and State.spot.lane, now() + K.SHOVE_STUCK_S, "deep_reject")
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        return nil
    end
    local sdest, clamped = Map.Nav.SafeDest({ x = dest.x, y = dest.y }, retreat, tower_safe)   -- v0.1.193: movement is tower-clamped ONLY; the stairs line is a decide-time exclusion (covers/gone), never a movement clamp
    if clamped then
        logline(string.format("lane_go clamp (%.0f,%.0f) -> (%.0f,%.0f)", dest.x, dest.y, sdest.x, sdest.y))
    end
    sdest = Map.SnapWalkable(sdest, dest)
    local sv = Vector(sdest.x, sdest.y, me.z)
    -- v0.1.286 (run-94 9:34/10:50/15:00, user: a blink followed by a keen is a wasted
    -- dagger - "plausible only when returning to base"): a leg whose keen is still
    -- COMING (exists, leveled, not yet spent/refused for this spot) never travel-blinks;
    -- the keen is global, the blink buys nothing. keenedSpot latches on spend AND on
    -- geometry refusals, so the blink stays available when the keen truly cannot serve
    -- the leg. A mana-short keen counts as coming (the .232 case: funding arrives
    -- mid-leg via bottle/regen). Return-path blinks (fsm_return) are untouched.
    -- v0.1.351: the gate above also blocked every leg the ladder never OFFERS a keen for.
    -- Map.Nav.Ladder emits keen/rearm only when d > keen_min_gain (K.KEEN_TRAVEL_MIN 1600),
    -- and keenedSpot latches ONLY inside that rung, so on a sub-1600 lane leg keenedSpot
    -- can never become true and blink_ok() was permanently false - the dagger was unusable
    -- on short lane legs while the camp path (fsm_move) blinks identical distances. The
    -- v0.1.286 rationale ("a leg whose keen is still COMING never travel-blinks") does not
    -- apply here: on a sub-1600 leg the keen is not coming, the ladder excluded it by
    -- DISTANCE. No floor is added - try_travel_blink already refuses below
    -- K.BLINK_TRAVEL_MIN 400 and owns the jump-risk veto, so this clause can only ADD a
    -- try_travel_blink call; every veto stays downstream and worst case is a no-op.
    -- SIZE IS UNMEASURED, DO NOT QUOTE ONE: g351 showed 13 why=short legs (13910u/45.5s)
    -- but ALL of them predate the Blink Dagger purchase (log line 11942, t=814), so the
    -- realised g351 saving of this clause is ZERO. The instrument cannot size it either -
    -- log_walk_leg samples per TICK with one global 2s debounce (3 of those 13 are repeat
    -- samples of a continuing leg) and its K.WALK_LEG_MIN 800 floor hides the whole
    -- 400-800u band this clause newly blinks. Ship reason is the STRUCTURAL defect, not a
    -- measured prize. The d=/latched= fields on the lane_go blink line size it next game.
    local function blink_ok()
        return State.keenedSpot
            or (((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) < 1)
            or me:Distance(sv) <= K.KEEN_TRAVEL_MIN
    end
    -- v0.1.205 (user directive, REVERSES the v0.1.158 note 6 "no blink in lane"): blink IS a lane
    -- travel rung now - the walking-distance-only usage under-used the dagger ("shaving even 3
    -- seconds can mean one more camp or clear the lane"). The jump-risk veto lives INSIDE
    -- try_travel_blink (fog-aware risk on hero + landing + tower); with a player threat around the
    -- dagger stays reserved for the escape, which was the whole v0.1.158 concern. Keen still
    -- outranks it (full teleport); blink fires when keen can't.
    -- v0.1.232 WAIT-FOR-KEEN rung (run-52, user: "still walking back to the lane"): at
    -- Keen L1 there is no Rearm to reset it, so a just-used keen left the ladder WALKING
    -- 30s+ lane returns while the cd came back in seconds (t=238: walked ~32s from base
    -- with keen due in ~9s). When waiting out the cd + channel clearly beats the walk,
    -- HOLD in place (watchdogs fed; the fsm's live risk re-checks keep running; at base
    -- the hold is regen time) and let a later tick take the keen rung. Mana-short keen
    -- reads cd 0 -> walks (no deadlock); the margin keeps short walks walking.
    local kfail   -- v0.1.258 I2: this call's keen refusal reason (feeds walk_leg's why=)
    local function walk_or_wait()
        if not State.keenedSpot and State.keen and not ready(State.keen)
           and ((Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 1 then
            local kcd = (Ability.GetCooldownTimeRemaining and Ability.GetCooldownTimeRemaining(State.keen)) or 0
            local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
            local walk_s = me:Distance(sv) / math.max(150, ms)
            if kcd > 0 and kcd + K.KEEN_CHANNEL + K.KEEN_WAIT_MARGIN < walk_s then
                State.waitInfo = { why = string.format("keen cd %ds", math.ceil(kcd)), t = now() }
                State.moveSince = now(); State.moveTrack = nil   -- intentional hold: feed the watchdogs
                if now() - (State.waitKeenLogT or 0) > 2 then
                    State.waitKeenLogT = now()
                    logline(string.format("lane_go wait_keen cd=%.1f walk=%.0fs", kcd, walk_s))
                end
                return "wait_keen"
            end
        end
        -- v0.1.244 THE AT-DESTINATION SHUFFLE FIX (run-61, named by the .242/.243 instruments +
        -- the platform order log): already within the arrival epsilon = issue NOTHING. The old
        -- 0.5s same-target re-assert kept a stale MOVE order alive at the stand (51 identical
        -- orders to one spot, mv gap=0 age=0.53 drumbeats), and the engine RESUMES that stale
        -- order after every cast completes (ext_move ages 2.87-3.2s = the rearm+cast cycle) -
        -- the user's ~1Hz "issue a movement and cancel it" while waiting in lane.
        local wd = me:Distance(sv)
        if wd <= K.WAVE_HOLD_EPS then return "walk" end
        log_walk_leg(wd, raid and "raid"
            or (kfail == "no_landing" and "no_anchor") or (kfail == "disabler" and "safety") or kfail
            or (State.keenedSpot and "latched")
            or (wd <= K.KEEN_TRAVEL_MIN and "short") or "no_keen")
        move_to(sv, "lane_walk"); return "walk"
    end
    local rungs = Map.Nav.Ladder(me:Distance(sv), {
        keened = State.keenedSpot, keen_ready = ready(State.keen), keen_min_gain = K.KEEN_TRAVEL_MIN,
    })
    for _, r in ipairs(rungs) do
        if r == "keen" then
            local kok, kwhy = keen_to_anchor(sv, raid)
            if kok then State.keenedSpot = true; logline(raid and "lane_go keen raid" or "lane_go keen"); return "keen" end
            -- v0.1.252 (run-67 t=922): a raid whose transport degrades to a far non-creep hop is
            -- a ghost trip in the making - do NOT fall down the ladder into the 3000u walk it was
            -- supposed to replace; abandon the commit (the deep_reject pattern: suppress briefly
            -- so the immediate redecide jungles the window; the lane re-competes next decide).
            -- v0.1.411: raid_broke (the full-chain affordability refusal, Bottle cannot close
            -- the gap) takes the same exit - the raid cannot fund its first cast, so walking
            -- the leg would statue on arrival; redecide and let the fountain refill node price
            -- the recovery (TINKER_RAID_READINESS_DESIGN.md section 3).
            if kwhy == "raid_far" or kwhy == "raid_broke" then
                local tag = kwhy == "raid_far" and "raid_reject" or "raid_broke"
                logline(string.format("lane_go %s (%.0f,%.0f) -> redecide", tag, dest.x, dest.y))
                suppress_shove(State.spot and State.spot.lane, now() + K.SHOVE_STUCK_S, tag)
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                return nil
            end
            -- v0.1.234 (run-53: keen_skip NAMED it - why=cast_failed, all gates clean): the
            -- issue() ORDER_GAP rate guard swallowed the keen when the fountain chain-drink
            -- bottle order shared the tick. PURELY TRANSIENT (retries fine 0.05s later), but
            -- the unconditional don't-retry latch turned it into a cross-map walk (runs
            -- 52+53). Only geometry-stable refusals (no_landing / gain) latch now.
            -- v0.1.258 I1: "disabler" is transient too (the threat leaves; the E1 gate
            -- re-opens the moment reach breaks) - latching it walked the whole leg.
            if kwhy ~= "cast_failed" and kwhy ~= "disabler" and kwhy ~= "mana_defer" then State.keenedSpot = true end   -- no safe landing: don't retry this spot (mana_defer v0.1.397: transient, the bottle is closing the gap)
            kfail = kwhy
        elseif r == "rearm" then
            -- v0.1.209 (user FINAL: safe = blink, no distance gate): a NON-raid leg blinks before
            -- any rearm-reset. A RAID leg stays blink-free - the creep hop at step-out IS the
            -- transport (global keen), and a partial blink toward a deep stand would walk him
            -- forward into the lane (never-wait-forward).
            -- v0.1.212 (run-35: a raid keen landed residual=2242 at the far allied bldg and WALKED
            -- it, 4x - the user's "keen to T2 did not blink on position"): the raid blink-exclusion
            -- applies only BEFORE the leg's keen (the creep hop IS the transport); once the keen is
            -- spent (State.keenedSpot) the residual is an ordinary sanctioned walk - blink it.
            if blink_ok() and (not raid or me:Distance(sv) >= 800) and try_travel_blink(sv) then logline(string.format("lane_go blink d=%.0f latched=%s", me:Distance(sv), tostring(State.keenedSpot))); return "blink" end
            if safe_rearm() then logline("lane_go rearm_reset_keen"); return "rearm" end
        else
            -- v0.1.209 review fix + v0.1.212: same raid rule (pre-keen only) as the rearm rung.
            if blink_ok() and (not raid or me:Distance(sv) >= 800) and try_travel_blink(sv) then logline(string.format("lane_go blink d=%.0f latched=%s", me:Distance(sv), tostring(State.keenedSpot))); return "blink" end
            return walk_or_wait()
        end
    end
    if blink_ok() and (not raid or me:Distance(sv) >= 800) and try_travel_blink(sv) then logline(string.format("lane_go blink d=%.0f latched=%s", me:Distance(sv), tostring(State.keenedSpot))); return "blink" end
    return walk_or_wait()
end

-- W-GEOM-2/3 shared cross-arm cast target (v0.1.277): ONE builder for the engage cast and
-- the preemptive lead cast. Returns the clamped cast point + the arm's theta; the CALLER
-- flips State.wArm only on cast success (the v0.1.176 latch lesson).
local function march_cross_target(me, aim)
    local maxr = (K.MARCH_CAST_RANGE or 300) - 20
    local theta = (State.wArm == 2) and K.W_X_ARM_B or K.W_X_ARM_A
    local dx, dy = aim.x - me.x, aim.y - me.y
    local dl = math.sqrt(dx * dx + dy * dy)
    local tgt
    if dl > 1 then
        local th = math.rad(theta)
        local ct, st = math.cos(th), math.sin(th)
        local ux, uy = dx / dl, dy / dl
        local d = math.min(maxr, dl)
        tgt = Vector(me.x + (ux * ct - uy * st) * d, me.y + (ux * st + uy * ct) * d, aim.z)
    else
        tgt = Vector(aim.x, aim.y, aim.z)
    end
    return (me:Distance(tgt) > maxr) and (me + (tgt - me):Normalized() * maxr) or tgt, theta
end

-- Wave MOVE: track the live wave (re-aim the stand at the moving cluster), close the distance via
-- Keen/walk, and switch to ENGAGE as soon as the hero is within WAVE_ENGAGE_RANGE of the LIVE AIM, the trailing ranged (T0: dref reads standSpot.aim, not the centroid)
-- (close enough to cover it with March), NOT a fixed stand the wave has since left. Bails to re-decide
-- if the wave is gone or unreachable in time. Rearm-to-reset-Keen is SAFE-gated (Note 3).
local function fsm_move_wave(s)
    keen_cancel_check()   -- v0.1.216: a canceled keen re-arms the ladder (rearm -> keen), never a deep walk
    State.fog = enemy_snapshot()                       -- fresh risk for safe_rearm + the reposition check
    -- v0.1.246 HOLD TRIPWIRE (TINKER_TOWER_DEATH_DESIGN.md): the committed wave's tower
    -- terminus DIED - the wave pushes past it and nothing arrives at this stand. The run-57
    -- law: geometry changes REDECIDE, never hold (this kills the 25s stale stand even when
    -- the melt prediction missed the dispatch).
    if s.crashTowerKey and Map.Towers.Alive(State.towerTrack, s.crashTowerKey) == false then
        logline("tower_died -> redecide lane=" .. tostring(s.lane or K.HOME_LANE))
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        return
    end
    -- Note 3: a committed shove/wave walk had NO live risk re-check (Part A was camp-only), so it kept
    -- walking forward into a gank as risk rose (death at a decide-gate stand risk 0.31 that climbed past
    -- 0.42 during the long keen-to-mid-T1 + 1936u walk). Re-check the HERO's live fog-aware risk each
    -- tick and bail+recover when it turns dangerous; suppress re-shoving the same spot briefly.
    local hrisk = enemy_risk_at(origin(State.hero))
    -- (the v0.1.123 live too_deep abort was REMOVED 2026-07-01 with the depth-veto patch family.)
    if lane_unsafe(origin(State.hero), { bail = true }) then   -- v0.1.94: 2+ enemies / under-tower / low-HP 1v1; v0.1.317 bail=true: the fog-uncertain escape-gate (the .316 jungle-drift)
        try_escape_blink()                              -- primary: flee by blink BEFORE the burst; recover regardless
        suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "wave_move_unsafe")
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        logline(string.format("wave_move abort reason=unsafe risk=%.2f", hrisk)); return
    end
    -- v0.1.329 THE CONTEST ARRIVAL RE-CHECK (user order; the .312 law enforced IN-FLIGHT):
    -- the decide-time contest passes when the carry is >CONTEST_LANE_R from the wave or
    -- arrives during Tinker's travel - g328: 2 top picks swtop=ok, then 79s top for 43g with
    -- the user's carry there. SIDE lanes only (mid = HOME, never yielded to allies);
    -- PRE-INVESTMENT only (marchCasts 0, no pending - a paid wave finishes W2 and banks via
    -- the budget exit); ~1s throttle (an ally scan per tick is waste). Contested -> the
    -- established brief-suppress + redecide pattern (same as overdue_convert); the next wave
    -- re-competes fresh at the decide's own contest gate.
    if s.shove and s.lane and s.lane ~= K.HOME_LANE
       and (State.marchCasts or 0) == 0 and not State.marchPending
       and now() - (s.contestT or 0) >= 1.0 then
        s.contestT = now()
        local cores = {}
        for _, a in ipairs(ally_farm_priorities()) do
            if a.core then cores[#cores + 1] = a end
        end
        local ground = s.refPoint or (s.standSpot and s.standSpot.aim)
        -- v0.1.333: the arrival re-check consumes the same jungle-aware predicate as decide time
        local acc = {}
        for _, cd in ipairs(Map.Camps()) do if cd.center then acc[#acc + 1] = cd.center end end
        local cj, cwhy = false, nil
        if #cores > 0 and ground then
            cj, cwhy = Farm.IsContestedByAlly({ x = ground.x, y = ground.y }, cores,
                { radius = K.CONTEST_LANE_R, camps = acc, camp_r = K.HERO_FARM_R, jungle_r = K.CONTEST_JUNGLE_R })
        end
        if cj then
            logline(string.format("contest_abandon lane=%s why=%s", tostring(s.lane), tostring(cwhy)))
            suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "contest_abandon")
            State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
            State.marchPending = nil
            return
        end
    end
    local live = update_wave_spot(s)
    -- v0.1.275 (run-84 user sighting: "going back and forward in a frenetic way while
    -- waiting"): a wave FLICKERING at the vision edge alternated the FOGGED branch (enemy
    -- near the stand -> protected hold toward the tower) with the LIVE branch (re-approach
    -- the stand) EVERY TICK - two lane_go destinations ~1700 apart, order for order
    -- (run-84 t=221/282/430/697, flip period ~0.3s). Debounce the branch: the contrary
    -- visibility state must persist WAVE_VIS_DEBOUNCE_S before the switch; transient
    -- contrary ticks issue NOTHING (the standing posture's last order keeps walking, the
    -- engage triggers resume within the debounce). Both flip directions guarded.
    do
        local rawLive = live and true or false
        if s.visState == nil then s.visState = rawLive end
        if rawLive ~= s.visState then
            s.visPendT = s.visPendT or now()
            if now() - s.visPendT < K.WAVE_VIS_DEBOUNCE_S then return end
            s.visState, s.visPendT = rawLive, nil
        else
            s.visPendT = nil
        end
    end
    -- note 2 (v0.1.160): the wave OBSERVED arriving after an empty wait = the REAL arrival - stamp it
    -- for the cadence anchor. waveEta alone lied on fogged anticipatory shoves (the mirror reads "due
    -- now" up to ~13s early), so lastWaveT inherited the bias and the measured rhythm scheduled camp
    -- keens right into real arrivals. A commit with the remnant already present never sets emptySince
    -- and keeps the (accurate, kin-from-real-fronts) waveEta stamp.
    if live and State.emptySince and not s.waveLiveT then s.waveLiveT = now() end
    -- RAID (Phase 2, spec R1): at Keen L2+ a shove-stand approach may keen onto an allied CREEP
    -- near the stand (the in-and-out; landing fully gated in keen_to_anchor, degrades to a
    -- building anchor when unsafe = the tether path). Shared by both branches (v0.1.173).
    local raidok = s.shove and ((State.keen and Ability.GetLevel and Ability.GetLevel(State.keen)) or 0) >= 2
    -- v0.1.280 THE IMMEDIATE W2 REARM (user directive, run-88: "cast first W and rearm
    -- directly if it is safe, then when the wave is visible cast the next W" - the old
    -- flow started the 2.75s channel only at ARRIVAL, pure delay). Resolve the in-flight
    -- preempt here (was engage-only; the cd jump proves the cast fired), then rearm
    -- straight away, safe-gated (channel gate + backoff inside safe_rearm) and at-stand
    -- only (the hold-still keeps the channel unbroken; a walking rearm self-cancels).
    do
        local mp = State.marchPending
        if mp and (not ready(State.march) or cd_remaining(State.march) > mp.cdBefore + 0.05) then
            State.marchCasts = (State.marchCasts or 0) + 1; State.marchPending = nil
            logline("march cast=" .. State.marchCasts)
        elseif mp and now() > mp.expire then
            State.marchPending = nil   -- v0.1.314 (bug hunt A4): a cast_pos-true-but-unfired pending was cleared only by the ENGAGE resolver - in MOVE it stalled every subsequent W block until arrival. Same expire clear as ENGAGE now.
        end
        local me1 = origin(State.hero)
        -- v0.1.392: ALSO admit marchCasts==0 when March is on MEANINGFUL cooldown. A commit that
        -- STARTS CD-down (marchCasts resets to 0 at dispatch; the spend was a camp pair or the
        -- previous wave's W2) had NO rearm producer at all: this gate and the pocket twin both
        -- required ==1 and the tether prearm is keen-only. Corpus: ~1.6 in-band march_cd episodes
        -- per game, 4 of them the fresh>4s class this opens (one wave ended CASTLESS), ~4.2 s/game.
        -- The CD floor keeps the ==0 path off waves whose March returns before the lead window
        -- (precheck: zero such waste at 4.0). Mana gate + safe_rearm carry over unchanged.
        if (State.marchCasts or 0) <= 1 and not State.marchPending and not ready(State.march)
           and ((State.marchCasts or 0) == 1 or cd_remaining(State.march) > K.PREARM_CD_FLOOR)
           and (me1:Distance(s.standSpot.stand) <= K.W_PRE_LEAD_R   -- v0.1.374: MOVES WITH THE FIRE GATE. If this stayed at W_PRE_STAND_R 600 while the gate fired at 1100, W1 would go out and the rearm would not arm, with nothing in the .307 REARM DANCE block (rearm_stepback, W2 delivery) walking the hero the remaining 490u.
                or channel_threat_near({ x = s.standSpot.stand.x, y = s.standSpot.stand.y }))   -- v0.1.307 the rearm dance: a disabler forced the step-back beyond the stand ring - rearm wherever the gate clears
           and effective_mana() >= abil_mana(State.rearm, K.REARM_MANA_FB) + abil_mana(State.march, K.MARCH_MANA_FB)
           and safe_rearm() then
            logline("prearm_w2"); return
        end
    end
    -- v0.1.334 THE ARRIVAL WATCHDOG (TINKER_ARRIVAL_WATCHDOG_DESIGN.md): promise-relative
    -- release for the committed PRE-CAST wait, all observabilities (fogged tether-slide,
    -- estimate churn, visible receding fight). The ORIGINAL promise is latched here before
    -- the .222 extends can roll s.waveEta; the live 2s laneScan adjudicates; the release is
    -- the stall_release shape. Runs FIRST each tick: the older exits (overdue_convert at
    -- eta+4 at-stand-invisible, stall_release in the spent/MOVE family) stay as backstops
    -- and whichever fires first clears the commit.
    if s.waveEta and s.standSpot and (State.marchCasts or 0) == 0 and not State.marchPending then
        s.arrivalPromise0 = s.arrivalPromise0 or math.max(s.waveEta, now())   -- v0.1.337: a promise already past (stale stamp) or degenerate (vis arrival=now) floors to the first tick - the watchdog arms from HERE for those
        local me0 = origin(State.hero)
        local at_stand = me0:Distance(s.standSpot.stand) <= K.WAVE_ENGAGE_RANGE
        do   -- v0.1.337: NO state exclusion - every pre-cast wave commit is covered (the .334 live-far carve-out swallowed real cases: g337 t=658, an 11334-jump raid onto a wave gone by arrival, watchdog silent; the degenerate-vis concern is handled by the latch floor above). at_stand still picks the tier below.
            local sc = State.laneScan and State.laneScan[s.lane or K.HOME_LANE]
            local scan = sc and {
                est = (sc.enemy_wave and sc.enemy_wave.estimated) and true or false,
                reach = (sc.intercept and sc.intercept.reachable) and true or false,
                eta = sc.intercept and sc.intercept.eta or nil } or nil
            -- two-tier ruler: AT THE STAND the full grace/hold/cap; everywhere else grace = the
            -- cap, so ONE legitimate one-cadence wave_wait extend (<= WAVE_HOLD_NEXT 12s) stays
            -- reachable and only CHAINS die at promise+15. v0.1.337: this now covers live-far
            -- commits too (promise floored at latch); a >15s live walk-in releasing just before
            -- arrival re-competes next decide (bounded: far_wave veto caps travel ~15s one-way).
            local kk = at_stand
                and { grace = K.ARRIVAL_GRACE_S,    hold_t = K.ARRIVAL_HOLD_T, hold_max = K.ARRIVAL_HOLD_MAX_S }
                or  { grace = K.ARRIVAL_HOLD_MAX_S, hold_t = K.ARRIVAL_HOLD_T, hold_max = K.ARRIVAL_HOLD_MAX_S }
            local verdict, why, held = Timing.ArrivalWatchdog(now(), s.arrivalPromise0, scan, kk)
            if verdict == "release" then
                logline(string.format("arrival_release lane=%s why=%s held=%.1f at_stand=%s",
                    tostring(s.lane or K.HOME_LANE), tostring(why), held, at_stand and "y" or "n"))
                -- v0.1.370: DO NOT BLOCKADE A LIVE LANE FOR 15s ON A TRANSIENT VERDICT. This armed a
                -- flat K.LIVE_STALL_S 15.0 for EVERY release reason. why="flicker" is the CAP
                -- tripping (lib/timing.lua:176, over > hold_max) - the wave is still there and the
                -- promise merely expired; "slow" and "fog" are the genuinely stalled/unseen cases
                -- LIVE_STALL_S was written for (v0.1.330, the g328 124+51+47s statues).
                -- MEASURED IN g371: 2 flicker events armed 15.0s twice and produced 33 of 134
                -- (24.6%) of the whole game shove_stuck decides. One of them is the SECOND half of
                -- the user-watched ~11:30 incident: after refill_done at t=705.2 with mana=940 and
                -- mid FULL (e=4 hp=1998 gold=175, rej=c0/r10/l0/a0/ok5 = five candidates OK, zero
                -- rejected), 11 consecutive decides read pick=none act=recover reason=shove_stuck,
                -- and the shove fired at t=709.8 the instant the latch expired. The wave decayed
                -- hp 1998->1173 in those 4.6s of pure idle. NOTHING changed except the latch.
                -- So flicker now takes the SHORT window (SHOVE_STUCK_S 6): that still breaks an
                -- immediate re-pick loop, which is all the suppression was ever for here, without
                -- gagging a live lane for 15s. Zero new constants.
                if s.shove then
                    suppress_shove(s.lane, now() + ((why == "flicker") and K.SHOVE_STUCK_S or K.LIVE_STALL_S),
                                   "arrival_release")
                end
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                State.marchPending = nil
                return
            end
        end
    end
    if not live then
        -- A shove heads toward the predicted crash point even while fogged, but NEVER waits forward
        -- (task #12, TINKER_ANCHOR_TETHER_DESIGN.md): hold TETHERED at the protected spot (nearest
        -- alive friendly structure toward the stand) and step out arrival-timed on the STAMPED
        -- cadence, so the walk arrives as the wave does. No stamp (first wave / lost rhythm) -> no
        -- walk-out on a guess; the wave walks into vision and the live branch engages near the
        -- anchor (which also stamps lastWaveT for the next cycle).
        local me0 = origin(State.hero)
        local d0 = me0:Distance(s.standSpot.stand)
        State.emptySince = State.emptySince or now()   -- fogged wait started (also arms the waveLiveT observed-arrival stamp)
        -- Piece 2 hold expiry (runs tethered OR at the stand): the committed waveEta can lie by
        -- seconds (fogged = the mirrored-front estimate). On expiry, re-ask the MEASURED rhythm
        -- (NextWaveArrival on the arrival-stamped lastWaveT): next wave within WAVE_HOLD_NEXT ->
        -- extend the deadline (this also CORRECTS s.waveEta to the stamped value); genuinely far
        -- -> redecide, and the scheduler fills the real window.
        -- v0.1.222 (user, run-45: two ~20s stand-waits for PHANTOM waves - t=756 step_out ->
        -- t=776 no_wave): standing AT the stand gives ~1200-1800 vision up-lane, so a genuinely
        -- arriving wave is VISIBLE ~4s before eta. At the stand, an INVISIBLE wave past
        -- eta + WAVE_WAIT_GRACE_VIS is a phantom (died deep / never spawned as predicted) - bail
        -- to the planner early. Tethered/far holds keep the full grace (no vision claim there).
        local grace = (d0 <= K.WAVE_ENGAGE_RANGE) and K.WAVE_WAIT_GRACE_VIS or K.WAVE_WAIT_GRACE
        local due = (s.waveEta and (s.waveEta + grace)) or (State.emptySince + K.WAVE_WAIT_GRACE)
        if now() > due then
            -- v0.1.256 arc B3 re-applied (run-64 14-18s stands; run-71 FIVE 22-60s stands on
            -- waves the enemy laner HELD): AT THE STAND an overdue wave CONVERTS to jungle
            -- instead of extending - suppress briefly so the planner takes a near camp; the
            -- lane re-competes every decide and re-dispatches the moment the wave shows or the
            -- freeze releases (the measured-speed read normalizes within ~2 scans).
            -- Tethered/far holds keep the extend below (their step-out clocks own lateness).
            if d0 <= K.WAVE_ENGAGE_RANGE then
                logline(string.format("overdue_convert lane=%s over=%.1f", tostring(s.lane or K.HOME_LANE),
                    now() - (s.waveEta or State.emptySince or now())))
                if s.shove then suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "overdue_convert") end
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                State.marchPending = nil   -- v0.1.278: a fog-preempt on a no-show wave must not leak into the next engage's count
                return
            end
            local nxt = Lane.Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT[s.lane or K.HOME_LANE])   -- PHASE 2: the hold's own lane cadence (side holds used MID's stamp before - wrong lane phase)
            if nxt and (nxt - now()) <= K.WAVE_HOLD_NEXT then
                s.waveEta = nxt
                logline(string.format("wave_wait extend eta=%.1f", nxt))
            else
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                State.marchPending = nil   -- v0.1.278: same pending-leak guard as overdue_convert
                logline("shove_move no_wave -> redecide"); return
            end
        end
        -- TETHER: latch on step-out (s.steppedOut) - once out, stay out; a late wave rolls eta_live
        -- +30s and re-tethering would walk him back just as it shows. The expiry above owns lateness.
        if not s.steppedOut then
            local eta_live = State.laneWaveT[s.lane or K.HOME_LANE]
                and Lane.Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT[s.lane or K.HOME_LANE]) or nil   -- PHASE 2: per-lane
            -- v0.1.213 TIMED MEETING RAID: the pre-empt target is the EARLIER of the cadence eta
            -- and the sim's meeting time (fight start) - land as the waves collide.
            if s.meetEta and (raidok or not eta_live) then eta_live = eta_live and math.min(eta_live, s.meetEta) or s.meetEta end   -- v0.1.321: the min-PULL to meetEta is RAID-ONLY (raid pre-empt target = the sim's meet_eta; fogged mirror-kin runs 8-12s early, asrc=kinest, the stamp is the accurate clock), but the NO-STAMP bootstrap (eta_live nil -> meetEta) stays for ALL shoves (.318-validated; .320 gated both and left the pre-stamp step-out dead: tether eta=-, zero step_out lines that run)
            local ms = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
            local walk_s = d0 / math.max(150, ms)
            -- KEEN TRANSIT (not the full d0 walk): a keen approach transits by keen (~channel + a
            -- short landing walk); pricing it as the walk lands him seconds early, idling at the
            -- stand (v0.1.320: the fogged near_due idle - the collapse was raid-only, but a
            -- lane-approach keen [resid=0] is priced the same, matching the keen-calibrated
            -- scheduler). Keen AND rearm down -> the real walk stands.
            -- v0.1.211: ladder-aware (keen down + rearm ready = rearm channel + keen channel).
            local tr = ready(State.keen) and (K.KEEN_CHANNEL + 1.0)
                       or (ready(State.rearm) and rearm_channel() + K.KEEN_CHANNEL + 1.0 or nil)
            if tr then walk_s = math.min(walk_s, tr) end
            if d0 <= K.WAVE_ENGAGE_RANGE then
                s.steppedOut = true                        -- committed already near the stand: no tether leg
            elseif eta_live and now() >= eta_live - walk_s - K.STEP_OUT_PRECAST_S then   -- v0.1.322: arrive with the PRE-CAST window in hand, not the engage lead
                s.steppedOut = true
                State.keenedSpot = false                   -- v0.1.175: the tether leg may have SPENT the keen reaching the anchor; re-arm the ladder (rearm-reset -> keen) so the step-out leg can RAID (run-13: keenedSpot=true made every deep step-out walk 3000u+)
                logline(string.format("step_out eta=%.1f walk=%.1f d=%.0f", eta_live, walk_s, d0))
            else
                -- v0.1.208 (run-33 "eternal waiting"): a LONG wait until step-out is a JUNGLE
                -- WINDOW, not a hold - the v0.1.207 local holds parked him at the fountain-side
                -- spot for 30s+ (the raid keen transit ~4s pushes step-out to the last seconds).
                -- Release to the planner with the shove suppressed for the wait; the re-decide
                -- after suppression re-commits the shove in time to step out.
                local wait_s = eta_live and (eta_live - now() - walk_s - K.STEP_OUT_PRECAST_S) or nil   -- v0.1.322: same window as the threshold (tether-release economics consistent)
                if wait_s and wait_s > K.TETHER_MAX_HOLD_S and now() >= (State.releaseBlockUntil or 0) then
                    suppress_shove(s.lane, now() + math.min(wait_s - 2, 25), "tether_release")
                    State.releaseSuppress[s.lane or K.HOME_LANE] = State.shoveSuppress[s.lane or K.HOME_LANE]   -- v0.1.252: mark as release-created (cancellable)
                    State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                    logline(string.format("tether release wait=%.1f -> jungle window", wait_s))
                    return
                end
                -- (review v0.1.178: tether spot cached per commit, same as the live branch)
                if not s.tetherSpot then
                    -- v0.1.305 (user, run-110 "fixed under the tower... good option when the
                    -- enemy has a disable, which is not this case - check the LIVE skills"):
                    -- the pocket is for DISABLERS. The kit-checked read (channel_threat_near
                    -- over hero_data x threat_data, fog-aware) decides: disable threat in
                    -- reach of the stand -> the protected structure pocket; none -> wait AT
                    -- THE STAND (the preemptive position - lead W1 + consecutive W2 fire on
                    -- time). The tether release economics are unchanged (long waits still
                    -- become jungle windows).
                    s.tetherSpot = channel_threat_near({ x = s.standSpot.stand.x, y = s.standSpot.stand.y })
                                   and protected_wait_spot({ x = s.standSpot.stand.x, y = s.standSpot.stand.y })
                                   or { x = s.standSpot.stand.x, y = s.standSpot.stand.y }
                    -- v0.1.206 (user: "if we are raiding, just keen direct on the creep"): the raid
                    -- keen is GLOBAL - transiting to a far hold buys NOTHING, and the v0.1.194 keen
                    -- ladder on far raid legs re-created keen->structure -> rearm -> keen->creep
                    -- (~375 mana + the T1 trip, the run-30/31 sightings). A far hold on a
                    -- raid-capable shove is replaced by a protected spot near the HERO; the
                    -- step-out keens straight onto the creep from wherever he waited.
                    local msT = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
                    if raidok and me0:Distance(Vector(s.tetherSpot.x, s.tetherSpot.y, me0.z))
                                  / math.max(150, msT) > K.TETHER_WALK_MAX_S then
                        s.tetherSpot = protected_wait_spot({ x = me0.x, y = me0.y })
                    end
                end
                local hv = Vector(s.tetherSpot.x, s.tetherSpot.y, me0.z)
                if not s.tetherLogged then
                    s.tetherLogged = true
                    logline(string.format("tether hold=(%.0f,%.0f) d=%.0f eta=%s", s.tetherSpot.x, s.tetherSpot.y, d0,
                        eta_live and string.format("%.1f", eta_live) or "-"))
                end
                State.waitInfo = { why = string.format("tether %s", eta_live
                    and string.format("%ds", math.max(0, math.floor(eta_live - now()))) or "wave?"), t = now() }
                -- v0.1.214 (run-37 t=764: a wave committed with Keen down WALKED ~6000 from the
                -- outpost - the exposed field rearm is risk-blocked at 0.20, correctly): the tether
                -- hold IS the protected low-risk window, so pre-arm Keen HERE; the step-out then
                -- always has the hop ready and never falls to the walk rung.
                if raidok and not ready(State.keen) and safe_rearm() then
                    logline("tether prearm_rearm"); return
                end
                -- v0.1.188 (run-20 user note: keen->structure->rearm->keen->creep): when the RAID
                -- will spend the keen at step-out, the tether leg must WALK - the raid keen
                -- teleports to the creep from ANYWHERE, so reaching the wait anchor buys nothing
                -- and the structure hop burned keen+rearm AND corrupted the step-out pricing
                -- (keen on cd -> walk_s read 11s instead of ~4).
                if me0:Distance(hv) > K.WAVE_HOLD_EPS then
                    -- v0.1.206: a raid-capable leg ALWAYS walks (the hold is local by construction
                    -- above; the keen is preserved for the direct creep hop). Non-raid legs keep
                    -- the ladder (their engage is a walk-in, the keen is not needed later).
                    if raidok then move_to(hv, "tether_hold") else lane_go(hv) end
                end
                return
            end
        end
        -- v0.1.283 THE 950-BOUNDARY OSCILLATOR, the real frenetic-flap root (runs 84-91,
        -- survived .275 AND .276 because both guarded the wrong doors): the protected hold
        -- sits ~1300 from the stand = OUTSIDE the d0<=950 at-stand gate below. Choosing it
        -- walked him back across the boundary, the APPROACH branch took over and walked him
        -- forward, across, prot hold again - a two-section oscillator inside ONE commit
        -- (run-91 t~175: flap until the stuck watchdog killed the commit at d=954). FIX:
        -- the protection latch is evaluated FIRST and OWNS the tick - while latched, hold
        -- at the protected spot (tight eps) and never fall through to the approach; the W2
        -- prearm runs here too (the pocket IS the safety posture - the run-91 5:30 W1-then-
        -- tower-walk now rearms AT the pocket, W2 ready on return). Prot clears after
        -- PROT_CLEAR_S clean -> normal approach resumes.
        if channel_threat_near({ x = s.standSpot.stand.x, y = s.standSpot.stand.y }) then   -- v0.1.305 (user): the protection latch is KIT-CHECKED - only a live disable threat pockets the wait; a no-disable laner leaves the preemptive stand alone
            s.protUntil = now() + K.PROT_CLEAR_S
        end
        if s.protUntil and now() < s.protUntil then
            local w = protected_wait_spot({ x = s.standSpot.stand.x, y = s.standSpot.stand.y })
            local hv = Vector(w.x, w.y, me0.z)
            State.waitInfo = { why = string.format("wave %ds @tower", math.max(0, math.floor((s.waveEta or now()) - now()))), t = now() }
            if (State.marchCasts or 0) <= 1 and not State.marchPending and not ready(State.march)
               and ((State.marchCasts or 0) == 1 or cd_remaining(State.march) > K.PREARM_CD_FLOOR)   -- v0.1.392: same widen as the MOVE gate (textually-identical twins, one change)
               and me0:Distance(hv) <= K.WAVE_HOLD_EPS
               and effective_mana() >= abil_mana(State.rearm, K.REARM_MANA_FB) + abil_mana(State.march, K.MARCH_MANA_FB)
               and safe_rearm() then
                logline("prearm_w2"); return
            end
            -- v0.1.285 (run-93): ARM 2 FROM THE POCKET - W2 is prearmed; fire it on the
            -- cadence lead from here, up-lane, so the stream meets the wave BEFORE the
            -- tower (waiting for the arrival gate meant W2 under the tower, tower CS).
            if (State.marchCasts or 0) == 1 and not State.marchPending and ready(State.march)
               and effective_mana() >= abil_mana(State.march, K.MARCH_MANA_FB) then
                -- v0.1.306 THE CONSECUTIVE W2 reaches the POCKET (run-111 t~504: the fog W1's
                -- W2 waited for the NEXT cadence window ~25s out = "one preemptive W, returned
                -- to tower, then cast 2"): W2 follows the rearm while the committed wave is
                -- still current - the cadence-lead gate times W1, never W2 (.304 principle).
                -- v0.1.314 (bug hunt D13): carry the same near-bound + drift the at-stand fog
                -- W2 got in .306/.309 - a rolled s.waveEta could fire the POCKET W2 a full
                -- cadence early (teta ~30) against a wave 30s out; the guard only landed on the
                -- at-stand twin, not here.
                local w2drift = (State.etaDrift and State.etaDrift[s.lane or K.HOME_LANE]) or 0
                if s.waveEta and (s.waveEta - now()) <= 8 and now() <= s.waveEta + w2drift + K.WAVE_WAIT_GRACE then
                    local fp2 = friendly_fountain_pos()
                    local aim2 = s.standSpot.aim
                    if fp2 then
                        local ux, uy = s.standSpot.stand.x - fp2.x, s.standSpot.stand.y - fp2.y
                        local ul = math.sqrt(ux * ux + uy * uy)
                        if ul > 1 then aim2 = Vector(s.standSpot.stand.x + ux / ul * 700, s.standSpot.stand.y + uy / ul * 700, me0.z) end
                    end
                    local cp2, th2 = march_cross_target(me0, aim2)
                    if cast_pos(State.march, cp2) then
                        State.marchPending = { cdBefore = cd_remaining(State.march), expire = now() + 1.5 }
                        State.wArm = (State.wArm == 2) and 1 or 2
                        logline(string.format("march_aim src=shove_w2 fog=y pat=x%d lane=%s cast=(%.0f,%.0f) aim=(%.0f,%.0f) pocket=y",
                            th2, tostring(s.lane), cp2.x, cp2.y, aim2.x, aim2.y))
                    end
                end
            end
            if me0:Distance(hv) > K.WAVE_HOLD_EPS then lane_go(hv, raidok) end
            return
        end
        if d0 > K.WAVE_ENGAGE_RANGE then
            if no_progress(d0) then                    -- Note 1: keen landed where the stand is unreachable (tower high ground) -> recover, and suppress re-shoving the same spot
                suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "move_stuck")
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                logline(string.format("shove_move stuck d=%.0f -> recover (suppress shove %ds)", d0, K.SHOVE_STUCK_S)); return
            end
            lane_go(s.standSpot.stand, raidok); return -- Piece 0: clamp + keen/rearm/blink/walk ladder (+ creep anchors on a raid)
        end
        -- at the stand, waiting for the wave to close (post step-out this window is ~STEP_OUT_PRECAST_S
        -- since v0.1.322 - the PRE-CAST window: shove_pre fires W1 here on the W-GEOM-3 lead).
        -- note 3 (v0.1.160, user): an enemy hero on the lane harasses a forward wait - the
        -- protected hold above owns that case now (v0.1.283); from here down the wait is
        -- UNPROTECTED (no enemy near) at the stand ring.
        local hold = s.standSpot.stand
        local prot = false
        -- v0.1.278 W-GEOM-3b THE FOG PREEMPT (user-approved upgrade to the .277 lead cast):
        -- the visible-only preempt loses its window when vision is short (night, uphill,
        -- trees - the wave can enter sight inside the 950 arrival trigger). When the
        -- STAMPED per-lane cadence (the measured rhythm; NEVER the mirror estimate, the
        -- .160 liar) puts the next arrival within W_LEAD_S and the wait is UNCONTESTED
        -- (no protection latch = no enemy near to hold the wave), fire arm 1 into the fog
        -- along the frozen aim: the stream meets the wave as it walks into vision, and the
        -- live branch's arrival flow (rearm + arm 2) takes over unchanged. Whiff cost on a
        -- frozen lane = one W; the phantom/overdue machinery owns the no-show redecide
        -- (which now also clears the pending stamp so the next engage cannot inherit it).
        -- v0.1.279 (run-87 user sighting "casted in the wrong place or too early", both
        -- confirmed in the placements): (a) AT-STAND GATE - the .278 fog cast could fire
        -- up to 950 from the stand (straight off the keen landing, cast B at ~1000+ from
        -- the meet); same gate as the live preempt now. (b) UP-LANE AIM - the frozen
        -- standSpot.aim is the MEET point, at/near the stand, so the cross arms rotated
        -- around a degenerate axis and the stream direction came out arbitrary; the fog
        -- cast now aims up-lane (away from our fountain through the stand), the direction
        -- the wave actually comes from. (c) OWN LEAD - arrival stamps read +1..+5s LATE vs
        -- the cadence eta (run-87 eta_err), stretching the effective lead past the sweep's
        -- saturation; the fog lead is its own smaller knob.
        if (State.marchCasts or 0) <= 1 and not State.marchPending and ready(State.march)
           and not prot and State.laneWaveT[s.lane or K.HOME_LANE]
           and me0:Distance(s.standSpot.stand) <= K.W_PRE_STAND_R
           and effective_mana() >= abil_mana(State.march, K.MARCH_MANA_FB) + ((State.marchCasts or 0) == 0 and abil_mana(State.rearm, K.REARM_MANA_FB) or 0) then
            local nxt = Lane.Schedule.NextWaveArrival(now(), K.WAVE_PERIOD, K.WAVE_PHASE, State.laneWaveT[s.lane or K.HOME_LANE])
            local lead = nxt and (nxt - now())
            -- v0.1.306: the cadence-lead window times W1 ONLY; W2 is CONSECUTIVE (the .304
            -- principle in the fogged branch) - after a fog W1 the wave is ~3.5s out, the
            -- rearm takes ~3s, so W2 at rearm-done lands right on it. Waiting for the next
            -- window orphaned fog engages (run-111 t~504) and stretched W2 gaps to 5.7-6.3s.
            local w2turn = (State.marchCasts or 0) == 1
            -- v0.1.309: the fog clock is DRIFT-CORRECTED (.293 re-applied; arrivals ran +3..+10
            -- late = fog W1s early); the fog W2 additionally requires the wave NEAR on its own
            -- eta (run-113: a rolled s.waveEta let a fog W2 fire at teta=29.7 = wasted robots).
            local drift = (State.etaDrift and State.etaDrift[s.lane or K.HOME_LANE]) or 0
            if (w2turn and s.waveEta and (s.waveEta - now()) <= 8
                and now() <= s.waveEta + drift + K.WAVE_WAIT_GRACE)
               or (not w2turn and lead and (lead + drift) > 0 and (lead + drift) <= K.W_LEAD_FOG_S) then
                local fogAim = s.standSpot.aim
                local fp = friendly_fountain_pos()
                if fp then
                    local ux, uy = s.standSpot.stand.x - fp.x, s.standSpot.stand.y - fp.y
                    local ul = math.sqrt(ux * ux + uy * uy)
                    if ul > 1 then
                        fogAim = Vector(s.standSpot.stand.x + ux / ul * 700,
                                        s.standSpot.stand.y + uy / ul * 700, me0.z)
                    end
                end
                local cp, theta = march_cross_target(me0, fogAim)
                if cast_pos(State.march, cp) then
                    State.marchPending = { cdBefore = cd_remaining(State.march), expire = now() + 1.5 }
                    State.wArm = (State.wArm == 2) and 1 or 2
                    -- v0.1.362 INSTRUMENT: `teta` prints the RAW `lead`, which is NOT what either
                    -- branch gates on. W1 gates on `lead + drift <= K.W_LEAD_FOG_S` and W2
                    -- gates on `s.waveEta - now()`, so on the W2 branch teta is a different
                    -- clock entirely: NextWaveArrival rolls a full WAVE_PERIOD the instant now()
                    -- crosses the arrival, which is EXACTLY when W2 is meant to fire, so a correctly
                    -- timed W2 prints teta near 30 and reads as one wave period early. That artifact
                    -- sat at the top of the ranked defect list for three sessions on 4 observations,
                    -- all 4 of which were healthy (g365's two W2s landed within 0.1s of the wave).
                    -- gl= and wte= are the quantities the two branches ACTUALLY test. teta stays so
                    -- older logs remain comparable.
                    logline(string.format("march_aim src=%s fog=y pat=x%d lane=%s teta=%.1f gl=%.1f wte=%s cast=(%.0f,%.0f) aim=(%.0f,%.0f)",
                        w2turn and "shove_w2" or "shove_pre", theta, tostring(s.lane), lead or -1,
                        (lead or 0) + drift,
                        s.waveEta and string.format("%.1f", s.waveEta - now()) or "nil",
                        cp.x, cp.y, fogAim.x, fogAim.y))
                end
            end
        end
        -- v0.1.163 (user): this IS a deliberate wait - say so (HUD reads WAIT, not MOVE).
        State.waitInfo = { why = string.format("wave %ds%s", math.max(0, math.floor((s.waveEta or now()) - now())),
                                               prot and " @tower" or ""), t = now() }
        -- Piece 0 clamp + ladder; HOLD-STILL (v0.1.153): at the hold spot, stop re-issuing orders
        -- v0.1.235 (run-53 t=842, the deep-dive's corrected verdict): the hold IS the raid
        -- stand on a raid commit, but this caller DROPPED the raid flag - a legally-deep
        -- drifted hold hit the non-raid tripwire (deep_reject "UPSTREAM BUG", the one false
        -- positive). Pass raidok like the approach leg above; the tripwire label is honest again.
        -- v0.1.282: the STAND hold truncates at W_PRE_STAND_R (the box covers the gap and
        -- the wave walks in - no forward positioning theater); the PROTECTED hold keeps
        -- the tight eps (it is a small safe pocket, being IN it is the point).
        if me0:Distance(hold) > (prot and K.WAVE_HOLD_EPS or K.W_PRE_STAND_R) then lane_go(hold, raidok) end
        return
    end
    local me = origin(State.hero)
    local dWave = me:Distance(s.refPoint)
    -- v0.1.193: the live wave's legal stand no longer covers it (drifted past the stairs line or
    -- tower-blocked, and this commit cannot raid it) - standing here is the run-23 22-25s wait.
    -- v0.1.195 (run-25 t=63): bail only when the wave is NOT CLOSING - nocover fired on an
    -- INBOUND wave (their push crashing our tower) whose CURRENT position read deep, and the
    -- abort+suppress+none-idle walked him back to our T1 exactly as the full wave arrived. A
    -- closing wave keeps the frozen (legal) stand and engages normally; a held/receding deep
    -- wave bails after NC_GRACE_S and Plan's covers/gone exclusion jungles the window.
    if live.nocover then
        if not s.ncT then s.ncT, s.ncD = now(), dWave
        elseif dWave < s.ncD - K.NC_CLOSE_EPS then s.ncT, s.ncD = now(), dWave   -- closing: re-arm the grace
        elseif now() - s.ncT > K.NC_GRACE_S then
            -- CASE-FILE 3 (v0.1.274, run-83, user go): a NEAR, HELD (not receding), FUNDABLE
            -- wave keeps the frozen legal stand instead of bailing - the old unconditional
            -- bail fed the Plan's recover<->resume flap (two tower round trips, 15s of
            -- pick=none) while the wave arrived anyway. Falling through keeps the engage
            -- triggers, the live tether, and the MOVE_TIMEOUT guillotine live, so the hold
            -- is bounded (25s + wave-eta grace). Receding, FAR, or unfundable waves bail
            -- exactly as before (Plan jungles the window) - the run-23/25 classes stay cured.
            local receding = dWave > (s.ncD or dWave) + K.NC_CLOSE_EPS
            local fundable = effective_mana() >= abil_mana(State.march, K.MARCH_MANA_FB)
                                                 + abil_mana(State.rearm, K.REARM_MANA_FB)
            if receding or dWave > K.NC_HOLD_NEAR or not fundable then
                suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "nocover")
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                logline("wave_move abort reason=nocover"); return
            end
            if not s.ncHeld then
                s.ncHeld = true
                logline(string.format("nocover_hold dWave=%.0f", dWave))
            end
            State.waitInfo = { why = "nocover hold", t = now() }
        end
    else
        s.ncT, s.ncD = nil, nil
    end
    -- v0.1.121 REVERTED the v0.1.119 preemptive engage: it fired when the wave was MARCH_LEAD from the
    -- MEETING but still ~1600 from TINKER (he stands 900 back), so the engage immediately repositioned
    -- (dWave > 1200) -> MOVE -> preempt again = a CHASE LOOP that walked Tinker under the tower (note 1)
    -- + set shove_stuck (notes 3/4). The reactive engage below already casts March at the aim (meeting)
    -- as the wave arrives within range, which is near-preemptive without the chase. A correct preemptive
    -- W needs a stand-still cast that does NOT trigger the reposition - deferred to a careful redesign.
    -- ON (anticipation): engage when the hero is within W-reach of the AIM = the TRAILING RANGED creep we
    -- anchor on, so the cast (clamped to hero + MARCH_CAST_RANGE) from the ~850-back stand LANDS on the
    -- ranged. The old reach(1200)-on-the-CENTROID trig engaged ~1160 from the wave, where the clamped cast
    -- fell ~900 short -> the ranged miss. OFF: the baseline centroid trig. Both use WAVE_ENGAGE_RANGE.
    local eref = s.standSpot.aim                            -- T0 collapsed: engage measures to the AIM (the trailing ranged)
    local dref = me:Distance(eref)
    -- W-GEOM-3 THE PREEMPTIVE LEAD CAST (v0.1.277; user design - the prediction owns the
    -- timing - + the lib/march_sim lead sweep, study sec 9: below lead ~4s every second of
    -- fire lead saves ~1s of engage; saturation 4.5-5.5s; the old at-arrival fire cleared
    -- +7s AFTER the wave reached the stand). With Tinker AT the stand and the wave CLOSING
    -- (commit-local EMA), fire the FIRST W when the wave is W_LEAD_S out: the robot stream
    -- and the wave MEET at the stand instead of the robots starting when the wave is
    -- already here. Supersedes the W_FRONT_MAX edge hold (the instant-AOE compensation,
    -- deleted from the engage) and realizes the v0.1.121 deferred design: a stand-still
    -- cast that never touches the FSM = the chase loop cannot form by construction. The
    -- ENGAGE (arrival trigger below, unchanged) then rearms and fires arm 2 as the wave
    -- lands - the W->rearm->W cycle overlaps the approach instead of following it.
    -- v0.1.280 (run-88 "terrible W casts": close read 627 and 1688 - the hero's OWN
    -- approach speed polluted the rate, dref shrinks from both motions): the EMA history
    -- RESETS whenever the hero moved this tick, so it only accumulates while standing -
    -- a clean wave-only closure, warm ~2 ticks after arrival.
    if s.wgHx and (math.abs(me.x - s.wgHx) + math.abs(me.y - s.wgHy)) > 30 then
        s.wgD, s.wgClose, s.wgN = nil, nil, nil
    end
    s.wgHx, s.wgHy = me.x, me.y
    if s.wgD and s.wgT and now() > s.wgT then               -- closing EMA (stationary ticks only)
        local rate = (s.wgD - dref) / (now() - s.wgT)
        -- v0.1.281 (run-89: close=627 SURVIVED the stationary fix, repeatably): the AIM
        -- ANCHOR jumps a creep-spacing forward when a trailing creep dies - a ~600 u/s
        -- spike that is re-anchoring, not motion. Samples beyond physical closure are
        -- rejected (the EMA keeps its last honest value).
        if math.abs(rate) <= 450 then
            s.wgClose = s.wgClose and (s.wgClose * 0.6 + rate * 0.4) or rate
            s.wgN = (s.wgN or 0) + 1   -- v0.1.309: warm-EMA counter (reset with the history on self-motion)
        end
    end
    s.wgD, s.wgT = dref, now()
    -- v0.1.304 THE CONSECUTIVE W2 (user design, run-109: the arm-2-waits-for-arrival flow
    -- chased the receding live stand under the tower - the .292 class on the .286 base):
    -- W1 is PREDICTIVE, so W2 simply follows the rearm - "even if W1 is a bit early, W2
    -- will for sure hit since it is after". No closing gate, no reach gate, no stand gate:
    -- fire the other cross arm at the live ranged the moment March is back. The budget
    -- exit then banks the wave and the planner keens him away (nothing left to wait for,
    -- nothing to chase; the receding-wave trap cannot form at casts>=1 by construction).
    if (State.marchCasts or 0) == 1 and not State.marchPending and ready(State.march)
       and effective_mana() >= abil_mana(State.march, K.MARCH_MANA_FB) then
        -- v0.1.307 W2 DELIVERY DISCIPLINE (run-112 vs Lina: shove_w2 fired at dref 1333-1374,
        -- ~500 past the 45-deg arm's true reach = the ranged survived; user: "the anchor
        -- should be the ranged creep"): W2 fires only within real coverage of the aim; when
        -- beyond it after a rearm step-back, WALK BACK IN with W2 in hand (the user's dance:
        -- position - W1 - step back - rearm - back in position - recast; delivery, not a
        -- chase - the approach block below allows post-cast movement exactly for this).
        if dref <= K.MARCH_REACH then
            local cp, theta = march_cross_target(me, eref)
            if cast_pos(State.march, cp) then
                State.marchPending = { cdBefore = cd_remaining(State.march), expire = now() + 1.5 }
                State.wArm = (State.wArm == 2) and 1 or 2
                logline(string.format("march_aim src=shove_w2 pat=x%d lane=%s cast=(%.0f,%.0f) dref=%.0f",
                    theta, tostring(s.lane), cp.x, cp.y, dref))
            end
        end
    end
    -- v0.1.280 rider (run-88: a W preempted onto a creeps=1 straggler): the wave must
    -- still be WORTH a lead cast at fire time - stragglers get the normal arrival flow.
    -- (v0.1.304: this block is the W1 LEAD only now - W2 is the consecutive cast above.)
    -- v0.1.368 INSTRUMENT (log-only, ZERO behaviour): WHY THE W1 LEAD DID NOT FIRE.
    -- The gate below is 8 conjuncts plus the tarr bar, and the shipped log records only the
    -- SUCCESS (march_aim src=shove_pre) - so the corpus is TRUNCATED AT THE BAR BY CONSTRUCTION:
    -- 208 of 283 fires sit at tarr 4.6-4.7 and nothing in any log says whether a LARGER lead
    -- would have fired at all. That is the one unknown blocking both proposed changes.
    -- READ IT LIKE THIS: why=lead_bar with tarr in 4.75..5.5 SIZES the W_LEAD_S 4.75->5.5 bump;
    -- why=stand_far or why=wg_cold dominating means POSITION/warmth is binding and NEITHER lead
    -- change can help (the lever would be step-out timing instead).
    -- eff = the same lead on the SWEEP's ruler, (dref-810)/close. tools/w_timing_sweep.lua:14
    -- measured t_arrive to a STAND 810 out while this gate measures to the HERO (dref->0), a
    -- 2.53s gap at close 320 - which is why 0 of 283 shipped fires have EVER landed inside the
    -- 4.5-5.5 band W_LEAD_S is named for. eff is what the one-line ruler fix would deliver.
    -- Throttled to 1.0s GLOBALLY. Never dereferences a nil standSpot: a diagnostic must not crash
    -- the brain (bug class 1).
    do
        local ds = (s.standSpot and s.standSpot.stand) and me:Distance(s.standSpot.stand) or -1
        local cl = s.wgClose or 0
        -- v0.1.400 (LOG-ONLY): tarr is computed ONCE, on the SAME ruler as the gate it explains.
        -- It used to be guarded by `cl > 0` while every real consumer gates on
        -- `wgClose >= W_CLOSING_MIN` (the fire path, stall_release, wave_walkin) - bug class 3, the exact
        -- defect the stand_far line below warns about. The closing EMA (x0.6 per tick with
        -- rate 0) DECAYS GEOMETRICALLY toward zero on a stationary wave without ever reaching it,
        -- so a held wave printed tarr from a 1e-15 divisor: g394 logged tarr=6.7e27 and g391/g392
        -- the same shape, escalating ~1e5 per tick. `close=%.0f` rendered that divisor as "0",
        -- which is why the rows read as a divide-by-zero that the code does not contain. NOTHING
        -- BEHAVIOURAL EVER CONSUMED IT: the fire gate clears W_CLOSING_MIN before it divides, so
        -- no cast was ever made on a garbage lead. -1 is the established not-applicable sentinel.
        local tarr_d = (cl >= K.W_CLOSING_MIN) and ((dref - K.ANTICIP_RANGED_REACH) / cl) or -1
        local why
        if (State.marchCasts or 0) ~= 0 then why = "cast_done"
        elseif State.marchPending then why = "pending"
        elseif not ready(State.march) then why = "march_cd"
        elseif (live.n or 0) < K.W_PRE_MIN_N then why = "thin"
        elseif dref <= K.WAVE_ENGAGE_RANGE then why = "inside_engage"
        elseif dref > K.W_LEAD_CAP then why = "cap"
        elseif cl < K.W_CLOSING_MIN then why = "slow"
        elseif (s.wgN or 0) < 2 then why = "wg_cold"
        elseif ds < 0 then why = "no_stand"
        elseif ds > K.W_PRE_LEAD_R then why = "stand_far"   -- v0.1.374: MIRRORS the fire gate's own bound. A diagnostic on a different ruler than the gate it explains is bug class 3, and this row is the only instrument that names why the lead refused.
        elseif effective_mana() < abil_mana(State.march, K.MARCH_MANA_FB) + abil_mana(State.rearm, K.REARM_MANA_FB) then why = "mana"
        elseif State.fightSeen and State.fightSeen[s.lane] and now() - State.fightSeen[s.lane] <= K.FIGHT_HOLD_S then why = "fight"   -- v0.1.393: the defer, named - THE acceptance signal
        elseif tarr_d > K.W_LEAD_S then why = "lead_bar"   -- unchanged in effect: `slow` above already owns every cl < W_CLOSING_MIN, and the -1 sentinel cannot exceed the bar
        end
        -- v0.1.371 SHIP 0 (log-only): also emit the row the tick the closing EMA ARMS. s.wgN
        -- passes through exactly 2 once per warm-up episode (nil->1->2, reset wholesale at
        -- the wgHx/wgHy guard on any self-motion >30u), so this adds about 5-8 rows/game and closes the
        -- ARMED FRONTIER bracket: without it the corpus cannot say what dref looked like at the
        -- moment the gate first became eligible. Side effect, accepted: the extra emit stamps
        -- State.wLeadLogT, delaying the next throttled row by up to 1.0s.
        if why and (now() >= (State.wLeadLogT or 0) or (s.wgN or 0) == 2) then
            State.wLeadLogT = now() + 1.0
            logline(string.format(
                "w_lead_reject why=%s ln=%s tarr=%.2f eff=%.2f dref=%.0f close=%.3f dstand=%.0f n=%d wgn=%d",
                why, tostring(s.lane), tarr_d, tarr_d, dref, cl, ds, live.n or 0, s.wgN or 0))
        end
    end
    if (State.marchCasts or 0) == 0 and not State.marchPending and ready(State.march)
       and live.n >= K.W_PRE_MIN_N
       and dref > K.WAVE_ENGAGE_RANGE and dref <= K.W_LEAD_CAP
       and (s.wgClose or 0) >= K.W_CLOSING_MIN and (s.wgN or 0) >= 2   -- v0.1.309 (run-113 2:30, W1 "100% off" on a non-moving wave): ONE post-reset EMA sample read 305 on a held wave (anchor-jump noise); the lead needs a WARM read
       and me:Distance(s.standSpot.stand) <= K.W_PRE_LEAD_R   -- v0.1.374: W_PRE_LEAD_R 1100, NOT W_PRE_STAND_R 600 - at 600 this conjunct algebraically capped the effective lead at 600/close (1.85s at creep speed 325) and made the v0.1.371 ruler fix inert on ordinary waves. Moves in lockstep with prearm_w2 and the w_lead_reject stand_far row. See the K.W_PRE_LEAD_R note.
       and effective_mana() >= abil_mana(State.march, K.MARCH_MANA_FB) + abil_mana(State.rearm, K.REARM_MANA_FB)
       -- v0.1.393 (4b-A): NO lead pre-cast while the wave is locked in a fresh-stamped creep fight
       -- (g387 t=307: W1 on tarr=3.8, wave arrived +15.8s late, robots expired by the tower, the
       -- 2-cast budget closed leaving 862hp/130g to the tower). Defer-the-cast, never the engage:
       -- the at-arrival flow below is untouched and owns every deferred wave. nil lane or nil
       -- stamp = no defer, fail-open.
       and not (State.fightSeen and State.fightSeen[s.lane] and now() - State.fightSeen[s.lane] <= K.FIGHT_HOLD_S) then
        -- v0.1.371 THE RULER FIX (D1). tools/w_timing_sweep.lua:14 measured the lead to a STAND
        -- 810 out (:30 t_arrive = (D0-STAND)/v) while this gate measured to the HERO, dref->0, so
        -- every fire has been about 2.5s short of the band K.W_LEAD_S is NAMED for: measured
        -- effective lead 2.02s over 311 fires, 0 of them ever inside 4.5-5.5. THE DECIDING
        -- MEASUREMENT: probing lib/march_sim, the robot STREAM FRONT reaches the 810 stand 3.70s
        -- after the cast order (300u at 2.93s, 1200u at 4.00s, cliff at 1273), so at 2.02s the
        -- robots arrive 1.68s AFTER the wave already passed the stand, wave 538u beyond it.
        -- With W_LEAD_CAP HELD at 1900 this delivers 3.38s, within 0.32s of that geometric ideal,
        -- and no tuning constant is touched. NUMERATOR POSITIVITY IS LOAD-BEARING and guaranteed
        -- by this gate's own conjunct (dref > K.WAVE_ENGAGE_RANGE 950 > 810), so the minimum is 140.
        -- Both operands are plain numbers (bug class 1 clear).
        local tarr = (dref - K.ANTICIP_RANGED_REACH) / s.wgClose
        if tarr <= K.W_LEAD_S then
            local cp, theta = march_cross_target(me, eref)
            if cast_pos(State.march, cp) then
                State.marchPending = { cdBefore = cd_remaining(State.march), expire = now() + 1.5 }
                State.wArm = (State.wArm == 2) and 1 or 2
                -- v0.1.371 rider: dref direct. The fix changes the reconstruction identity from
                -- dref = tarr*close to dref = tarr*close + 810, so the historical formula goes
                -- 810u wrong on every post-fix log. This is CORPUS CONTINUITY, not precision (the
                -- old reconstruction was +-16u against a 106u noise floor) and NOT the acceptance
                -- criterion. parse_debuglog.lua prefers dWave, so analyzer output is unchanged.
                -- v0.1.374 rider (LOG-ONLY, appended so the analyzer's kv parse is unaffected): dstand.
                -- It is the ONLY field that separates "the new W_PRE_LEAD_R bound fired this cast" from
                -- "the stand was tower-clamped this game" - the gap dref-dstand runs 808-1881 in g374 and
                -- 810-1196 in g373, so dstand CANNOT be reconstructed as dref-810 (max error 1420u) and
                -- without it the next log cannot attribute the change. Same operands as the fire gate's
                -- W_PRE_LEAD_R conjunct (bug class 1 clear).
                logline(string.format("march_aim src=shove_pre pat=x%d lane=%s tarr=%.1f close=%.0f cast=(%.0f,%.0f) dWave=%.0f dref=%.0f dstand=%.0f",
                    theta, tostring(s.lane), tarr, s.wgClose, cp.x, cp.y, dWave, dref, me:Distance(s.standSpot.stand)))
            end
        end
    end
    -- Piece 2 TIME-SCHEDULED first W: also engage when the wave is DUE (waveEta) and Tinker is holding
    -- at the frozen stand with the live wave already inside March's reach. Strictly EARLIER than the
    -- distance trigger and whiff/chase-safe by construction: dWave <= MARCH_REACH (1150) sits under
    -- fsm_engage_wave's reposition bound (WAVE_ENGAGE_RANGE + 250 = 1200), and the clamped cast
    -- (~280 ahead + ~900 sweep) covers the wave from here. The distance trigger stays as base/fallback.
    -- (The spec's ENGAGE_LEAD is already realized by SCHED_LEAD - the scheduler leaves early; no new const.)
    -- v0.1.284 (run-92: trig=time fired at eta_err +27.5 - the >= condition is a LATCH
    -- that stays true forever once the eta passes; a stale committed eta then "arrives"
    -- any live wave instantly): the timed trigger is a WINDOW around the eta, not a
    -- latch. Past the window the distance trigger owns arrival honestly.
    local timed = s.waveEta and now() >= s.waveEta - K.MARCH_CAST_DUR
                  and now() <= s.waveEta + 2.0
                  and me:Distance(s.standSpot.stand) <= K.W_PRE_STAND_R
                  and dWave <= K.MARCH_REACH
    if dref <= K.WAVE_ENGAGE_RANGE or timed then
        State.fsm = "ENGAGE"; State.moveSince = nil; State.emptySince = nil
        -- v0.1.303 LANE-CLOCK D-B: the ARRIVAL is the observation - stamp the cadence clock AND
        -- the arrival GROUND here, not only at the 2 lucky exits (budget/wave_clear). One
        -- imperfect wave used to regress the next decide to kinest geometry (run-107 t=95->126).
        local ln = s.lane or K.HOME_LANE
        -- v0.1.366: STAMP THE GRID TICK WE SERVED, NOT THE MOMENT TINKER ARRIVED. This site fires on
        -- dref <= WAVE_ENGAGE_RANGE where dref = me:Distance(eref) is HERO-to-aim, so `now()` here is
        -- when TINKER showed up, not when the WAVE did - and NextWaveArrival consumes the stamp as a
        -- PHASE (last_wave_t % period), so a hero-derived time injects a hero-derived phase into the
        -- wave clock. Measured: it lands 0.9-5.2s early of each game's own observed arrival phase,
        -- and an early phase ROLLS a full 30s period under NextOnGrid's strictly-greater rule (65%
        -- of arrivals over 495 samples). Grid-aligning keeps the stamp NON-NIL (every downstream
        -- gate and the whole tether chain still arm - run-9 stays closed) while its phase becomes
        -- the calibrated K.WAVE_PHASE. Do NOT "repair" this by subtracting the 950u engage range:
        -- that divides a HERO distance by a CREEP speed (bug class 3, ruler mismatch).
        State.laneWaveT[ln] = Lane.Schedule.NextOnGrid(now(), K.WAVE_PERIOD, K.WAVE_PHASE) - K.WAVE_PERIOD
        State.laneMeet[ln] = { x = eref.x, y = eref.y, t = now() }
        -- v0.1.309 re-applied .293 (ledger; run-113 evidence: eta_err +3..+10 all game -> fog
        -- W1s fired early and the whole chain read "W2 late"): stamp the per-lane arrival
        -- DRIFT (EMA, clamped 0..6) so the fog casts fire on the CORRECTED clock.
        if s.waveEta then
            local drift = math.max(0, math.min(6, now() - s.waveEta))
            State.etaDrift = State.etaDrift or {}
            State.etaDrift[ln] = State.etaDrift[ln] and (State.etaDrift[ln] * 0.5 + drift * 0.5) or drift
        end
        -- v0.1.338 (g339: 3/3 waves exited casts=1 - decide-time held/thin reads 713-1018 rounded
        -- the budget to 1, and engage 1 ARRIVED at creeps=4 with W2 already prearmed, still quit
        -- after W1): the arrival re-reads the LIVE wave, like camps have since v0.1.199 - a
        -- multi-creep arrival funds at least 2 casts. The HUD slider + the .190 absolute cap
        -- still bound it ABOVE at the engage (min(s.shoveCasts, maxw, 2)), so slider=1 is
        -- respected; the wave_clear/dead exit still ends a wave that dies to W1 early.
        if live.n >= 2 and (s.shoveCasts or 2) < 2 then s.shoveCasts = 2 end
        logline(string.format("wave_engage_arrived dWave=%.0f dref=%.0f creeps=%d trig=%s eta_err=%s",
            dWave, dref, live.n, timed and "time" or "dist",
            s.waveEta and string.format("%+.1f", now() - s.waveEta) or "-")); return
    end
    -- v0.1.330 THE STALLED-LIVE RELEASE (user un-parked g328 item 1: 124+51+47s = 222s of
    -- statues): [committed + at/near the stand + wave LIVE but beyond engage range + NOT
    -- closing] had no exit - the arrival trigger needs dref<=950, the phantom-bail needs
    -- INVISIBLE, the tether release is pre-step-out only, and MOVE_TIMEOUT below is refreshed
    -- by the ENGAGE->MOVE reposition flip so it never ages during the ping-pong (g328
    -- t=521: timed-engage fired W1, reposition bounced back, W2 went out consecutive, then the
    -- SPENT commit sat 124s with the wave stalled at ~1200+). This exit consults REALITY only
    -- (the .325 lesson): live wave, far, closure EMA dead or unwarmed for LIVE_STALL_S straight
    -- -> release the window (suppress LIVE_STALL_S so the lane re-competes when the stalemate
    -- resolves). Closing or near resets the clock: a normally-walking wave can never trip this
    -- (EMA warms in ~2 stationary ticks and reads 300+; the post-step-out self-motion transient
    -- is ~2-6s << 15). s.stallT lives on the commit and survives the ENGAGE<->MOVE flips.
    if dref > K.WAVE_ENGAGE_RANGE and ((s.wgClose or 0) < K.W_CLOSING_MIN or (s.wgN or 0) < 2) then
        s.stallT = s.stallT or now()
        if now() - s.stallT > K.LIVE_STALL_S then
            logline(string.format("stall_release lane=%s dref=%.0f close=%s casts=%d held=%.1f",
                tostring(s.lane or K.HOME_LANE), dref, tostring(s.wgClose), State.marchCasts or 0,
                now() - s.stallT))
            if s.shove then suppress_shove(s.lane, now() + K.LIVE_STALL_S, "stall_release") end
            State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
            State.marchPending = nil
            return
        end
    else
        s.stallT = nil
    end
    if State.moveSince and now() - State.moveSince > K.MOVE_TIMEOUT then
        -- v0.1.194 F3 (run-24 t=707/769): a tether with a CONCRETE step-out shortly ahead is not
        -- a stall - the 25s guillotine kept killing ~21s scheduled holds right at their step-out.
        -- Extend to the committed wave eta + grace, HARD-CAPPED one wave period past the normal
        -- timeout so a rolling eta can never re-create the v0.1.178 idle trap.
        local eta = (not s.steppedOut) and s.tetherSpot and s.waveEta or nil
        local cap = State.moveSince + K.MOVE_TIMEOUT + K.WAVE_PERIOD
        if not (eta and now() < math.min(eta + K.WAVE_WAIT_GRACE, cap)) then
            State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
            logline("wave_move timeout -> redecide"); return
        end
    end
    -- LIVE TETHER (v0.1.173, run-11 "stuck high in the lane waiting for the next waves"): parked
    -- at a deep stand Tinker SELF-PROVIDES vision, so the next wave is always visible, the fogged
    -- tether never engages, and the at-stand hold waited 25s+ per wave in enemy territory. Same
    -- doctrine here: when the wave needs longer to close to engage range than the walk to the
    -- stand, wait at the protected spot and step out arrival-timed. 325 = base lane-creep speed
    -- (Liquipedia); ignoring our own approach speed errs a touch early, bounded by STEP_OUT_LEAD.
    if not s.steppedOut then
        local ms0 = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
        local walk_s = me:Distance(s.standSpot.stand) / math.max(150, ms0)
        -- v0.1.211: ladder-aware raid transit (see the fogged twin above).
        if raidok then
            local tr = ready(State.keen) and (K.KEEN_CHANNEL + 1.0)
                       or (ready(State.rearm) and rearm_channel() + K.KEEN_CHANNEL + 1.0 or nil)
            if tr then walk_s = math.min(walk_s, tr) end
        end
        -- v0.1.369 CLOSE THE LOOP (the user-watched ~11:30 hold in g371, t=677.8). This priced the
        -- wave approach OPEN-LOOP on the hard-coded 325 base creep speed, while the brain ALREADY
        -- measures the real closing EMA in the same struct (s.wgClose, printed as close=
        -- by the v0.1.368 instrument). In a STALLED lane fight those two disagree by 13x: the
        -- incident logged eff=live+14.6 (exactly (5679-950)/325 = 14.551) while the measured EMA
        -- read 0, 0, 281, -79, -131, -0, -0 and the front actually closed at ~25 u/s. The hero then
        -- stood 12.3s watching a 175g wave die to our own creeps, hp 1909 -> 41.
        -- BOTH MITIGATIONS WRITTEN FOR THIS CASE NO-OP: meet_s needs s.meetEta, which is nil when
        -- bal < 0 (the meet_eta gate) and is snapshotted once by dispatch_shove so the later bal flip cannot revive
        -- it; sim_s needs waveAsrc=="sim" and asrc was "held". So eff_s WAS close_s alone.
        -- THE TRIGGER IS A RULER MISMATCH: close_s is priced on the WALKING ruler while walk_s just
        -- above is capped by the KEEN ruler (min(15.3, 3.93)), so 14.55 > 5.43 holds; on one ruler
        -- it would have been 14.55 > 16.8 = step out at once. Bug class 3.
        -- WITH THE LOOP CLOSED a stalled wave yields math.huge -> wait_s > TETHER_MAX_HOLD_S ->
        -- the EXISTING tether-release valve fires and the window buys a camp. That is what
        -- the valve was written for; it never fired here only because 325 fabricated a believable
        -- ~14s. The valve is live (14 firings elsewhere in g371), so this reuses it, adds nothing.
        -- FAILS SAFE: below the warm-read bar (wgN>=2, the v0.1.309 anchor-jump guard) or on a
        -- receding/parked front we return huge, i.e. RELEASE rather than hold. Do NOT "fix" this by
        -- lowering TETHER_MAX_HOLD_S: neither g371 hold is caught by any threshold (predicted waits
        -- 9.1s and 4.2s) and lowering it would release well-behaved short tethers.
        -- v0.1.373 REVERTS v0.1.369. That build made this return math.huge whenever the closing
        -- EMA was not warm, intending "a stalled wave releases the tether". IT FIRED ON EVERY
        -- APPROACH INSTEAD, because s.wgClose/s.wgN is a STATIONARY-ONLY estimator: the s.wgHx/s.wgHy guard
        -- wipes the history on any self-motion over 30u in a tick, and this live-tether branch
        -- runs while the hero is STILL WALKING to the stand, so wgN is 0 for the whole approach.
        -- Both written fallbacks are nil in exactly that case (meet_s nil when bal<0, sim_s needs
        -- waveAsrc=="sim"), so eff_s became inf, wait_s inf > TETHER_MAX_HOLD_S, and the commit
        -- SUPPRESSED ITS OWN LANE FOR 25s ON THE TICK IT WAS MADE. g373 t=163.6: mid committed at
        -- eff_hp=1650, released the same tick, locked mid 25s, and took an 85g unpaired camp while
        -- the scan read mid e=4 hp=1950 gold=169 eta=3.4 reach=true. Pre-.369 the same decide
        -- computes wait_s = 1.30s and holds. "tether release wait=inf" by game: ZERO across five
        -- pre-.369 games, then 6 of 6 in g372 and 6 of 6 in g373, with releases roughly doubled.
        -- IT ALSO CRASHED THE TICK: the tether waitInfo does math.floor(eff_s) and math.floor(math.huge) has no
        -- integer representation in Lua 5.4 - 158 throws in g372, 20 in g373, each killing one
        -- whole tick (no decide, no order, no save layer). Reverting kills the crash by
        -- construction: a finite close_s makes eff_s finite.
        -- COST OF THE REVERT, stated honestly: the g371 11:30 watched defect returns (a genuinely
        -- stalled wave is priced on the open loop and can hold ~12s). The correct fix is to split
        -- COLD from STALLED - fall back to this open loop when wgN < 2, and return huge only when
        -- the EMA is WARM and reads below K.W_CLOSING_MIN - and it is queued, not shipped here,
        -- because this build is a revert and must carry exactly one change.
        local close_s = math.max(0, dref - K.WAVE_ENGAGE_RANGE) / 325
        -- v0.1.213 THE TIMED MEETING RAID (3-patch klvl2 lane starvation, run-36 census): close_s
        -- models THEIR wave walking to OUR stand at 325, but at the deep meeting the fight STALLS
        -- it (measured advance ~130) - it never "closes", the tether releases forever, and the wave
        -- dies unseen to our creeps during the windows. The sim's meeting time (s.meetEta = when
        -- their wave reaches the collision point = fight start) is the GPM-first pre-empt target:
        -- step out for the EARLIER of close-to-stand or the meeting, so the raid keen lands as the
        -- waves collide, before our creeps eat the farm.
        local meet_s = s.meetEta and math.max(0, s.meetEta - now()) or nil
        -- v0.1.218 (run-41 tail t=760-796: releases with NO raids after, all commits bal<0 - the
        -- v0.1.216 gate correctly dropped meet_s for LOSING fights, but close_s STALLS during the
        -- fight and the scheduler's own fight-end arrival [asrc=sim = the bal<0 farmable moment,
        -- their remnant emerges] was never consulted by the live tether): eff_s = the earliest of
        -- close-to-stand / the meeting (winning) / the fight end (losing).
        -- v0.1.376: WIDEN THE GATE FROM "sim" TO THE REAL-READ SET. The g371 11:30 defect (12.3s stood
        -- still while a 175g mid wave died in view, hp 1998 -> 41) is the hole where ALL THREE
        -- estimators are nil-or-wrong at once: close_s on the wrong ruler, meet_s nil'd by bal=-3 in
        -- schedule_ctx, and sim_s refused because asrc was "held". This obeys the arrival the SCHEDULER
        -- ALREADY COMMITTED TO (s.waveEta is d.deadline frozen by dispatch_shove) instead of
        -- re-deriving one. At the incident it injects 1.8s (dl=680 against t=677.8) versus
        -- walk_s+LEAD 5.43, so the branch steps out instead of holding.
        -- SPELLED kin/held, NOT "any real read": keenInvest calls `vis` a real read too, but the ctx builders set
        -- arrival = now() for vis, so admitting it makes this term IDENTICALLY 0, and 0 > walk_s+1.5
        -- is never true = a silent, total, information-free disable of the whole branch. Measured
        -- 13 vis rows in 1407 asrc-bearing rows across 7 logs, all in g374, 0 decision changes - rare
        -- but the failure mode is absolute, so it is excluded by name.
        -- CANNOT REPRODUCE EITHER PRIOR FAILURE AT THIS SITE, by construction rather than by care:
        -- eff_s is a math.min and both gates (STEP_OUT_LEAD, TETHER_MAX_HOLD_S) are monotone increasing in it, so a new
        -- term can only SHRINK eff_s and can only delete holds/releases, never create one. v0.1.369
        -- failed by making close_s LARGER (math.huge), and it read the stationary-only EMA; this
        -- reads neither. s.waveEta is an absolute game time so eff_s stays finite and the
        -- math.floor(eff_s) cannot throw.
        -- THIS IS MITIGATION, NOT A RULER REPAIR, and the distinction is load-bearing for whoever
        -- reads this next: close_s stays wrong for stamp/grid commits. THE STRUCTURAL DEFECT IS THAT
        -- THIS BRANCH HAS NO COHERENT TRIGGER AT ALL - safe_stand_for composes the stand exactly
        -- ANTICIP_RANGED_REACH 810 back from the aim and 810 < WAVE_ENGAGE_RANGE 950, so the
        -- honest "seconds until the wave is castable from my stand" is ZERO permanently. Measured over
        -- 735 committed wave stands the aim-to-stand gap is median 811, max 1000, and ZERO exceed
        -- 1437, so a coherent (G-950)/325 is 0 on 99.3% of commits and ceilinged at 0.31s against a
        -- 1.5s bar. Its own arc; do not "improve the estimate" here again without reading that first.
        -- HIT RATE, measured before shipping (20 logs, banner-excluded, takeovers excised): 33 of 44
        -- live holds flip to an immediate step-out (75%), 19 of 22 attributable releases blocked
        -- (86%), median ~2 changed decisions per game, range 0-13, and SIX of eighteen games change
        -- nothing. g375 and g376 flip ZERO holds, so a quiet next game proves nothing.
        local sim_s = (s.waveAsrc == "sim" or s.waveAsrc == "kin" or s.waveAsrc == "held")
                      and s.waveEta and math.max(0, s.waveEta - now()) or nil
        local eff_s = math.min(close_s, meet_s or math.huge, sim_s or math.huge)
        if eff_s > walk_s + K.STEP_OUT_LEAD then
            -- v0.1.208: same release as the fogged tether (run-33: the last log event was THIS
            -- hold at the fountain with eta=live+32.8 - an eternal wait; the window fits a camp).
            -- v0.1.213: the wait is against the PRE-EMPT time (eff_s), so a release window always
            -- ends before the meeting step-out, not before the (stalling) close-to-stand.
            local wait_s = eff_s - walk_s - K.STEP_OUT_LEAD
            if wait_s > K.TETHER_MAX_HOLD_S and now() >= (State.releaseBlockUntil or 0) then
                suppress_shove(s.lane, now() + math.min(wait_s - 2, 25), "tether_release")
                State.releaseSuppress[s.lane or K.HOME_LANE] = State.shoveSuppress[s.lane or K.HOME_LANE]   -- v0.1.252: mark as release-created (cancellable)
                State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
                logline(string.format("tether release wait=%.1f -> jungle window", wait_s))
                return
            end
            -- (review v0.1.178: tether spot cached per commit - the nearest friendly structure
            -- cannot change within one; the per-tick full-structure scan was pure waste. And NO
            -- moveSince refresh here: MOVE_TIMEOUT is the live branch's only long-stall exit - a
            -- far stalemate creep fight held close_s high FOREVER, and refreshing moveSince made
            -- the tether an idle trap; after 25s the redecide re-plans the window (maybe a camp).)
            if not s.tetherSpot then
                s.tetherSpot = channel_threat_near({ x = s.standSpot.stand.x, y = s.standSpot.stand.y })
                               and protected_wait_spot({ x = s.standSpot.stand.x, y = s.standSpot.stand.y })
                               or { x = s.standSpot.stand.x, y = s.standSpot.stand.y }   -- v0.1.305: kit-checked pocket, same as the fogged twin (no disabler = wait at the preemptive stand)
                -- v0.1.207 (run-32 t=828: the keen->structure->rearm->keen->creep chain SURVIVED
                -- v0.1.206 because only the FOGGED tether was fixed - this LIVE tether is its twin
                -- and kept the v0.1.194 far-leg keen ladder): same cure - the raid keen is GLOBAL,
                -- a far hold buys nothing; wait at a protected spot near the HERO and keen straight
                -- onto the creep at step-out.
                local msT = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero)) or 320
                if raidok and me:Distance(Vector(s.tetherSpot.x, s.tetherSpot.y, me.z))
                              / math.max(150, msT) > K.TETHER_WALK_MAX_S then
                    s.tetherSpot = protected_wait_spot({ x = me.x, y = me.y })
                end
            end
            local hv = Vector(s.tetherSpot.x, s.tetherSpot.y, me.z)
            if not s.tetherLogged then
                s.tetherLogged = true
                logline(string.format("tether hold=(%.0f,%.0f) d=%.0f eta=live+%.1f", s.tetherSpot.x, s.tetherSpot.y,
                    me:Distance(s.standSpot.stand), close_s))
            end
            -- v0.1.223 (user overlay sighting): the label showed close_s (~36s) for holds that
            -- step out in ~5s on the meeting/fight-end clock - display the EFFECTIVE wait.
            State.waitInfo = { why = string.format("tether %ds", math.floor(eff_s)), t = now() }
            -- v0.1.214: same pre-arm as the fogged twin (the hold is the protected rearm window).
            if raidok and not ready(State.keen) and safe_rearm() then
                logline("tether prearm_rearm"); return
            end
            -- v0.1.188: same as the fogged tether - a raid-capable hold WALKS (preserve keen+rearm
            -- for the creep hop at step-out; the teleport goes there from anywhere).
            if me:Distance(hv) > K.WAVE_HOLD_EPS then
                -- v0.1.207: raid legs ALWAYS walk (local by construction above; keen preserved
                -- for the direct creep hop). Non-raid legs keep the ladder.
                if raidok then move_to(hv, "tether_hold_live") else lane_go(hv) end
            end
            return
        end
        s.steppedOut = true
        State.keenedSpot = false                             -- v0.1.175: same re-arm as the fogged step-out (the tether leg may have spent the keen)
        logline(string.format("step_out live close=%.1f meet=%s sim=%s walk=%.1f", close_s,
            meet_s and string.format("%.1f", meet_s) or "-",
            sim_s and string.format("%.1f", sim_s) or "-", walk_s))
    end
    -- Piece 0: clamp + ladder own the whole leg. HOLD-STILL (v0.1.153): once AT the stand
    -- (watching the wave close), issue NO more movement - re-ordering move_to every tick
    -- twitched Tinker in place (move, cancel, move).
    -- v0.1.282 (run-90 user): the approach stops W_PRE_STAND_R short of the stand - the
    -- box covers the gap, the wave walks in, the preempt/timed gates accept it; walking
    -- the last 600 was positioning theater and delayed the EMA (which needs stillness).
    -- v0.1.304 THE POST-CAST FREEZE (the .292 fix re-applied per the ledger - its evidence
    -- arrived in run-109: after W1 our robots push their wave back, the live-tracked stand
    -- ADVANCES, and the approach chased it under the tower for W2): once this wave's first
    -- cast is spent, the approach never advances - the consecutive W2 above fires from
    -- here, and the fight comes back through the corridor. MOVE_TIMEOUT bounds the hold.
    -- v0.1.305 re-applied .295/.301 (the held-wave walk-in): the .282 stop-short premise is
    -- a CLOSING wave; a wave HELD in a fight (decide stamp or the warm EMA's held band)
    -- never walks the last 600 in, parking dref outside every trigger - walk to the exact
    -- stand instead (dref = 810 by construction = arrival fires). Held BAND only: receding
    -- waves are the .304 consecutive-W2's business, not a chase.
    if not s.walkIn and dref > K.WAVE_ENGAGE_RANGE
       and ((s.waveAsrc == "held")
            or ((s.wgClose or math.huge) < K.W_CLOSING_MIN
                and (s.wgClose or -math.huge) > -K.W_CLOSING_MIN))
       and enemy_tower_risk(s.standSpot.aim) <= 0 then   -- v0.1.309 (run-113 "stepped inside the tower": the walk-in to the exact stand of a tower-pushed wave lands at the ~850 legal edge): tower-adjacent aims keep the 600-park; the corridor + step-in (tower-gated) cover from range
        s.walkIn = true
        logline(string.format("wave_walkin dref=%.0f asrc=%s close=%s", dref, tostring(s.waveAsrc),
            s.wgClose and string.format("%.0f", s.wgClose) or "-"))
    end
    -- v0.1.307 THE REARM DANCE, MOVE side (user design vs disablers: "go to the correct
    -- position, cast W1, go a little back, rearm, go back in position and recast"): with W1
    -- spent and March down, a channel-gated rearm (disabler in reach - Lina LSA class) steps
    -- BACK toward the protected spot and retries every tick; the prearm fires the moment the
    -- gate clears. With W2 IN HAND and the aim beyond coverage, walk BACK IN (delivery - the
    -- .292 freeze stays for the waiting case only: never advance while NOT ready).
    if (State.marchCasts or 0) >= 1 and not State.marchPending then
        if not ready(State.march) then
            local thr, tpos = channel_threat_near(origin(State.hero))
            if thr and tpos
               and effective_mana() >= abil_mana(State.rearm, K.REARM_MANA_FB) + abil_mana(State.march, K.MARCH_MANA_FB) then
                -- v0.1.308 (user): NOT the protected spot - just OUT OF RANGE, minimally.
                -- One short step per tick straight away from the gating threat; the prearm
                -- retries every tick and the rearm fires the moment the gate clears. If she
                -- follows to keep the gate on us, she walks into W1's robot corridor.
                local dx, dy = me.x - tpos.x, me.y - tpos.y
                local dl = math.sqrt(dx * dx + dy * dy)
                if dl > 1 then
                    move_to(Vector(me.x + dx / dl * 300, me.y + dy / dl * 300, me.z), "rearm_stepback")
                end
            end
        elseif dref > K.MARCH_REACH and me:Distance(s.standSpot.stand) > K.WAVE_HOLD_EPS then
            -- v0.1.315 REVERTED the v0.1.314 A2 depth guard: it blocked W2 delivery whenever the
            -- hero was parked short of the stand (the .282 stop-short = shallower than the stand),
            -- which is the NORMAL post-W1 posture, so a held/far wave never got its W2 = "only 1 W
            -- without waves about to arrive" (run-115). A2's receding-chase concern was speculative
            -- + bounded by MOVE_TIMEOUT; the delivery walk targets the tower-safe stand (no death).
            lane_go(s.standSpot.stand, raidok)   -- W2 delivery: back into position, the W2 block fires once inside coverage
        end
        return
    end
    if (State.marchCasts or 0) == 0 and not State.marchPending
       and me:Distance(s.standSpot.stand) > (s.walkIn and K.WAVE_HOLD_EPS or K.W_PRE_STAND_R) then
        -- RAID (Phase 2 R1): the LIVE-wave approach is where the run-10 deep walks lived (visible
        -- commits, travel 15-19s, residual 2300+) - at Keen L2 keen onto a creep near the stand.
        lane_go(s.standSpot.stand, raidok)
    else
        State.waitInfo = { why = string.format("wave closing %d", math.floor(dref)), t = now() }   -- v0.1.163: at the stand, waiting for reach
    end
end

-- Part A (N3): a committed camp trip does not re-check enemy risk en route, so an
-- enemy rotating onto a normally-safe camp could catch Tinker (HP panic is too late
-- vs burst). Refresh the LIVE fog-aware snapshot and bail+skip if the stand turned
-- dangerous. Only camps: the wave/shove paths are gated by the schedule (COR-1).
local function camp_unsafe_abort(s, where)
    local ss = s.standSpot
    local pt = (ss and ss.stand) or s.center
    if not pt then return false end
    State.fog = enemy_snapshot()                            -- live (the decide-time snapshot is stale by now)
    local r = enemy_risk_at(pt)
    if r >= K.FARM_SAFE_RISK then
        try_escape_blink()                              -- primary: flee by blink BEFORE the burst; recover regardless
        -- E0 (B8): a threatened camp is CONTESTED, not cleared - the until-respawn mark let one
        -- roaming enemy serially delete camps from the pool for up to 60s each (farm denial).
        -- Suppress briefly instead; the camp re-competes once the roamer moves on.
        mark_spot_cleared(s, now() + K.CAMP_UNSAFE_SUPPRESS_S); go_return()
        logline(string.format("%s abort reason=unsafe risk=%.2f (suppress %ds)", where, r, K.CAMP_UNSAFE_SUPPRESS_S))
        return true
    end
    return false
end

local function fsm_move()
    keen_cancel_check()   -- v0.1.216: a canceled keen re-arms the ladder (rearm -> keen), never a deep walk
    local s = State.spot
    if not s then State.fsm = "DECIDE"; State.moveSince = nil; return end
    if s.kind == "wave" then return fsm_move_wave(s) end
    if camp_unsafe_abort(s, "move") then return end
    local ss = s.standSpot
    local stand = ss.stand
    local me0 = origin(State.hero)
    local d = me0:Distance(stand)
    local aim = ss.aim or s.center                           -- the March cast point (pair midpoint / camp centre)
    local dCast = me0:Distance(aim)
    -- AREA, not a point: the valid stand is the whole zone from which March's square covers the camp. ENGAGE
    -- as soon as that holds (no exact-point requirement - that was the "stuck" cause). For a PAIR, require
    -- BOTH camps within March reach (R1) so standing in the MIDDLE covers both, not just the near one.
    local engage_ok
    if ss.paired and ss.partner then
        -- THE BOX = a THIN RECTANGLE aligned to the camp axis (A->B), centred on the midpoint: tight ALONG
        -- the axis (moving there shifts the perpendicular W's width off a camp), roomy PERPENDICULAR (the
        -- cast direction; both camps stay covered). Same for every pair now (no walkable/fallback split).
        local ux, uy = ss.partner.x - s.center.x, ss.partner.y - s.center.y
        local ul = math.sqrt(ux * ux + uy * uy); if ul < 1 then ul = 1 end
        ux, uy = ux / ul, uy / ul
        local ox, oy = me0.x - aim.x, me0.y - aim.y
        local along = math.abs(ox * ux + oy * uy)
        local perp  = math.abs(-ox * uy + oy * ux)
        engage_ok = d <= K.ARRIVE_DIST or (along <= K.BOX_ALONG and perp <= K.BOX_PERP)
    else
        engage_ok = d <= K.ARRIVE_DIST or dCast <= K.ENGAGE_COVER_DIST
    end
    if engage_ok then
        State.fsm = "ENGAGE"; State.moveSince = nil
        State.emptySince = nil
        State.engageStart = now()                   -- timing calib: mark the clear start (vs clearEst)
        State.engageMana  = mana()                  -- v0.1.212 cost-truth census: raw mana at clear start
        logline(string.format("engage_arrived t=%.1f d=%.0f dCast=%.0f", now(), d, dCast)); return
    end
    -- P0 watchdog: are we actually closing toward the stand? A far keen landing (d2stand large) onto
    -- terrain we cannot path through leaves the hero walking in place -> never arrives, never times out
    -- in time. If distance has not improved for NO_PROGRESS_S, treat the stand as unreachable: mark the
    -- camp cleared (skip until respawn) and re-decide.
    -- v0.1.259 (run-74 t=559.8) put an is_channeling guard HERE - deliberate channel stillness
    -- must not be judged as no-progress. v0.1.355 moved it to the tick() early return
    -- above the FSM dispatch: this function is not called at all during a channel, so the guard was dead for
    -- 96 versions while the bug it was written for kept retiring live camps. Do not re-add it
    -- here; see TINKER_CHANNEL_WATCHDOG_DESIGN.md.
    if no_progress(d) then
        mark_spot_cleared(s)
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        logline(string.format("move stuck d=%.0f -> redecide+cleared", d)); return
    end
    if State.moveSince and now() - State.moveSince > K.MOVE_TIMEOUT then  -- can't reach: re-decide
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil; return
    end
    -- ONE Keen hop toward the camp (if a closer anchor exists), THEN walk the rest.
    local kfail   -- v0.1.258 I2: this tick's keen refusal reason (feeds walk_leg's why=)
    if d > K.KEEN_TRAVEL_MIN and not State.keenedSpot then
        if ready(State.keen) then
            local kok, kwhy = keen_to_anchor(stand)
            if kok then
                State.keenedSpot = true; logline("move keen_to_anchor"); return
            end
            -- v0.1.258 I1 (the lane_go .234/.258 latch rule, same shape): transient
            -- refusals (cast_failed order-gap, disabler in reach) retry next tick.
            -- v0.1.411: "raid_broke" cannot reach here - this caller never passes include_creeps (camp/move legs are not raids), so the raid arm never runs for it.
            if kwhy ~= "cast_failed" and kwhy ~= "disabler" and kwhy ~= "mana_defer" then State.keenedSpot = true end   -- no useful anchor hop: just walk from here (mana_defer v0.1.397: transient)
            kfail = kwhy
        elseif try_travel_blink(stand) then
            -- v0.1.209 (user FINAL: "use blink whenever it is safe"): NO distance gate - Keen on
            -- cd means blink NOW (shaves ~1150 instantly); if the trek is still long the next
            -- tick's rearm-reset continues it, and for gaps under ~3500 the blink+walk REPLACES
            -- the whole rearm(~375 mana)+keen transit outright.
            return
        elseif safe_rearm() then               -- Keen on cd: Rearm once to reset it (safe: not under enemy pressure)
            logline("move rearm_reset_keen"); return
        end
    end
    if try_travel_blink(stand) then return end   -- blink the remaining gap when safe + ready
    if origin(State.hero):Distance(stand) <= K.WAVE_HOLD_EPS then return end   -- v0.1.244: at the stand = no order (the at-destination shuffle fix, same as lane_walk)
    log_walk_leg(d, (kfail == "no_landing" and "no_anchor") or (kfail == "disabler" and "safety") or kfail
        or (State.keenedSpot and "latched")
        or (d <= K.KEEN_TRAVEL_MIN and "short") or "no_keen")
    move_to(stand, "move_stand")
end

-- Wave ENGAGE: Tinker Marches the LIVE creep cluster from the safe stand. Re-track the wave each tick
-- (it moves); if it drifts out of March reach go back to MOVE to reposition; if it is gone, bail after
-- a brief grace. Same fire-gated March budget as camps, but Rearm is SAFE-gated (Note 3) and the aim
-- follows the live centroid clamped to cast range (Note 2). (Notes 1-3.)
local function fsm_engage_wave(s)
    State.fog = enemy_snapshot()                       -- fresh risk for safe_rearm
    local live = update_wave_spot(s)
    if not live then                                    -- wave gone (cleared / left): brief grace then done
        -- v0.1.242 W-CANCEL (user feature): a March still WINDING UP (order issued, cast not
        -- fired - the turn + 0.53s cast point window) would land on nothing now that the last
        -- creep died. Cancel the order (a move to self interrupts the wind-up) and keep the
        -- ~160-190 mana. Already-fired = uncancelable (robots out): resolve the count as usual.
        -- issue() swallowed by ORDER_GAP -> pending stays, retry next tick (the .234 lesson).
        local mp0 = State.marchPending
        if mp0 then
            if (not ready(State.march)) or cd_remaining(State.march) > mp0.cdBefore + 0.05 then
                State.marchCasts = State.marchCasts + 1; State.marchPending = nil
                logline("march cast=" .. State.marchCasts)
            else
                local me0 = origin(State.hero)
                if issue(UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION, nil, nil, me0) then   -- bypass move_to: the dedup must not eat the cancel
                    State.marchPending = nil
                    logline("march_cancel reason=empty src=wave")
                end
            end
        end
        State.emptySince = State.emptySince or now()
        if now() - State.emptySince > K.ENGAGE_EMPTY_GRACE then
            -- cadence anchor: NextWaveArrival treats this as the ARRIVAL phase. Best source first:
            -- the OBSERVED arrival (waveLiveT, note 2) > the frozen kinematic estimate (waveEta;
            -- accurate for real fronts, ~13s early for fogged mirrors) > the death time (F1 bias).
            -- v0.1.362 INSTRUMENT (log-only): WHICH of the three sources won is never recorded, and
            -- the three are not interchangeable - the comment right above says waveEta runs ~13s
            -- early on fogged mirrors, and `now()` is the F1 death-time bias the lib CONTRACT
            -- on Lane.Schedule.NextWaveArrival exists to forbid. This stamp feeds it on ~20% of
            -- decides, roughly 10x the reach of K.WAVE_PHASE, and the corpus stamp phase reads 15.8
            -- against a measured true arrival phase of 18.5. Naming the winner is how that gets
            -- attributed to a source instead of guessed.
            -- v0.1.367: WAS A LYING INSTRUMENT. v0.1.366 made all three writers store the GRID
            -- TICK, so waveLiveT/waveEta/now stopped reaching State.laneWaveT entirely - yet this
            -- line kept naming one of them (g370 emitted live 10 / eta 10, 20 claims about a source
            -- no code reads). It now reports what is actually written.
            local ssrc = "gridtick"
            if s.shove then State.laneWaveT[s.lane or K.HOME_LANE] = Lane.Schedule.NextOnGrid(now(), K.WAVE_PERIOD, K.WAVE_PHASE) - K.WAVE_PERIOD end   -- v0.1.366: the GRID TICK served, not waveLiveT/waveEta/now - the stamp is consumed as a PHASE and those three carry a hero-derived one. PHASE 2 per-lane slot is unchanged (the .225 shared-slot corruption stays gone).
            logline("engage_done reason=wave_clear casts=" .. tostring(State.marchCasts)
                    .. (s.shove and (" stampsrc=" .. ssrc) or ""))
            engage_replan()
            return
        end
        return
    end
    State.emptySince = nil
    local me = origin(State.hero)
    -- Note 5: live-risk ABORT in the ENGAGE (the MOVE path got this in v0.1.67; the engage did not).
    -- When March is on cd AND an enemy collapses, safe_rearm is blocked by proximity, so Tinker would
    -- stand in ENGAGE doing nothing until killed. Flee by blink BEFORE the burst, then recover.
    local erisk = enemy_risk_at(me)
    -- (the v0.1.123 live too_deep abort was REMOVED 2026-07-01 with the depth-veto patch family.)
    if lane_unsafe(me) then                             -- v0.1.94: count+HP aware (a healthy 1v1 keeps farming, not flees)
        logline(string.format("wave_engage abort reason=unsafe risk=%.2f", erisk))
        try_escape_blink()
        if s.shove then suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "engage_unsafe") end
        go_return(); return
    end
    -- v0.1.267 STEP-BACK REARM driver (run-78: vs a laning Lina every wave went W1 +
    -- channel_defer x4s + bail - the gate is right per-channel, but the wave STAND sits
    -- permanently inside the laner's gate reach, so the .262 bail turned a mana guard into
    -- a GPM leak; user picked step-back over the alternatives). While armed: hold the
    -- engage (the reposition flip below must not steal the walk), keep walking OUT of the
    -- gating enemy's reach, and re-try the rearm each tick - it fires the moment the gate
    -- clears; the normal reposition then walks back in for W2. Deadline -> the .262 bail.
    do
        local sb = State.rearmStepback
        if sb then
            if now() > sb.deadline or ready(State.march) then
                State.rearmStepback = nil
            elseif safe_rearm() then
                State.rearmStepback = nil
                logline("rearm_stepback fired"); return
            else
                move_to(sb.spot, "rearm_stepback")
                State.moveSince = now()                -- intentional walk: feed the watchdogs
                return
            end
        end
    end
    if me:Distance(s.refPoint) > K.WAVE_ENGAGE_RANGE + 250 then   -- wave drifted out of reach: reposition
        State.fsm = "MOVE"; State.moveSince = now(); State.keenedSpot = false
        logline("wave_engage reposition dWave=" .. math.floor(me:Distance(s.refPoint))); return
    end
    if mana() < State.menu.escapeMana:Get() then
        logline("engage_bail reason=mana mana=" .. math.floor(mana())); go_return(); return
    end
    -- run-75 t=619 (E1's first live exercise): the engage stood 24s at the stand while the
    -- channel gate deferred every Rearm next to a PARKED Venge - a hold can never resolve a
    -- parked disabler (the .239 law). Defer persisting with March down = bail + suppress;
    -- the planner farms away from the disabler and the lane re-competes next decide.
    -- v0.1.267: the step-back gets its try first (not State.rearmStepback).
    if State.chanDeferSince and now() - State.chanDeferSince > K.CHANNEL_DEFER_BAIL_S
       and not State.rearmStepback and not ready(State.march) then
        logline("engage_bail reason=channel_defer")
        suppress_shove(State.spot and State.spot.lane, now() + K.SHOVE_STUCK_S, "channel_defer")
        State.chanDeferSince = nil
        engage_replan(); return
    end
    local mp = State.marchPending                       -- resolve a March in flight (fire-gate, as camps)
    if mp then
        if (not ready(State.march)) or cd_remaining(State.march) > mp.cdBefore + 0.05 then
            State.marchCasts = State.marchCasts + 1; State.marchPending = nil
            logline("march cast=" .. State.marchCasts)
        elseif now() > mp.expire then
            State.marchPending = nil; logline("march issued_NOT_fired_retry")
        else
            return
        end
    end
    -- D3: a shove exits at its computed casts (Lane.Schedule.ClearTime); the wave-clear exit above covers dead.
    -- "Marches: lane wave (max W)" HUD slider caps the per-clear W count so a big / over-estimated lane
    -- wave can't burn endless March. Live-read; falls back to K.WAVE_MAX_W if the menu isn't ready.
    local maxw = (State.menu and State.menu.waveMaxW and State.menu.waveMaxW:Get()) or K.WAVE_MAX_W
    -- v0.1.190 (user HARD RULE): waves cap at 2 casts ABSOLUTE - a 3rd W was observed killing
    -- nothing (per the per-creep model, 2 casts + the rear sweep + allied creeps finish any wave).
    -- Clamped in code so a stale persisted slider value can never exceed it.
    local wbudget = math.min(s.shoveCasts or maxw, maxw, 2)
    if State.marchCasts >= wbudget then
        -- cadence anchor on the BUDGET exit too (v0.1.171): our creeps finish the remnant, so a
        -- healthy game can end EVERY shove on budget and never reach the wave_clear stamp below -
        -- run-9 had 17/17 budget exits, lastWaveT stayed nil all game, and the whole tether chain
        -- (asrc=stamp accurate slack -> camps fit; step_out) never armed. Same source order.
        if s.shove then State.laneWaveT[s.lane or K.HOME_LANE] = Lane.Schedule.NextOnGrid(now(), K.WAVE_PERIOD, K.WAVE_PHASE) - K.WAVE_PERIOD end   -- v0.1.366: the GRID TICK served, not waveLiveT/waveEta/now - the stamp is consumed as a PHASE and those three carry a hero-derived one. PHASE 2 per-lane slot is unchanged (the .225 shared-slot corruption stays gone).
        -- v0.1.197 (run-26 t=21.9, user: "you broke the hard limit for 2 W on waves"): the robots
        -- from the 2 budget casts deliver over ~6s, so at the instant redecide the SAME wave still
        -- reads near-full (eff_hp 1461) -> re-picked -> Rearm resets March -> a 3rd W + a ~225
        -- rearm burned on a wave already paid for (mana hit 44 -> fountain). Suppress the re-shove
        -- for the delivery window; the wave dies to the in-flight robots + allied creeps, and the
        -- planner farms the gap. The 2-cast clamp is per-WAVE now, not per-engage.
        if s.shove then suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "budget_delivery") end
        -- v0.1.362 INSTRUMENT: same stampsrc as the wave_clear twin above. THIS is the site that
        -- matters most - run-9 ended 17/17 shoves on budget and never reached the wave_clear stamp
        -- at all, so on a healthy game nearly every cadence anchor in the log is written HERE.
        logline(string.format("engage_done reason=budget casts=%d lane=%s shove%s",
            State.marchCasts, tostring(s.lane),
            s.shove and " stampsrc=gridtick" or ""))   -- v0.1.367: see the wave_clear twin - this named a source v0.1.366 stopped reading
        engage_replan()
        return
    end
    -- v0.1.377 THE CASTLESS-ENGAGE WATCHDOG, HOISTED OUT OF THE MARCH-READY BRANCH.
    -- WHY: the castless-wait release below used to live INSIDE `if ready(State.march)`, so when
    -- March was on cooldown the timer never even STARTED and ENGAGE had no time-based exit at all.
    -- Every other stall exit is elsewhere: MOVE_TIMEOUT and the arrival watchdog live in
    -- fsm_move_wave, and STUCK_TELEPORT is gated to MOVE/RETURN in tick(). g377 t=605.4 (the operator
    -- watched it at 10:10): a top keen raid arrived with BOTH March charges spent on the camp he had
    -- just finished, so `w_lead_reject why=march_cd` on both the commit and the arrival, and the hero
    -- stood 13.4s in ENGAGE issuing ZERO orders for 13.97s, leaving only when the wave died to our
    -- own creeps (engage_done reason=wave_clear casts=0, keen_waste lane=top held=17.6).
    -- PROVEN TO FIRE ON THAT DEFECT: at the arrival dref0=848 > W_CAST_REACH 700 with live.n=4, so
    -- the qualifier was satisfied on the FIRST tick; the release lands ~t=612.7 instead of 622.9,
    -- about 10s recovered, and the existing suppress-and-replan path sends him to a camp (the same
    -- path that behaved correctly at t=561.2, wait_end dur=4.1).
    -- SCOPE IS DELIBERATELY UNCHANGED: same qualifier, same K.W_WAIT_RELEASE_S 4.0, same
    -- suppress+logline, no new constant, no new state field, and `engage_release reason=w_wait`
    -- already exists so this is self-reporting. The step-in and the waitInfo stay in the March-ready
    -- branch below because they are about POSITIONING FOR A CAST, which is meaningless with March
    -- down. When March IS ready this runs first and, if it does not release, falls through to
    -- exactly the old behaviour.
    -- BLAST RADIUS, measured over 83 wave engages that arrived with zero marches cast across
    -- g370-g377: 65 cast within ~4s and are untouched; 6 cast later (6.0, 22.0, 38.3, 42.3, 46.0s)
    -- and would be cut, four of which are themselves pathological 22-46s engages; 6 never cast at
    -- all with span > 4s, including g371's 32.0s stall and g377's 14.1s. About one changed engage
    -- per game. live is non-nil here (guarded by `if not live` above) and me is the function-level origin.
    do
        local wwRef = me:Distance(s.standSpot.aim)
        if (State.marchCasts or 0) == 0 and (wwRef > K.W_CAST_REACH or live.n < 2) then
            s.wwT = s.wwT or now()
            if now() - s.wwT > K.W_WAIT_RELEASE_S then
                if s.shove then suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "w_wait") end
                logline(string.format("engage_release reason=w_wait dref=%.0f n=%d casts=%d", wwRef, live.n, State.marchCasts or 0))
                engage_replan(); return
            end
        end
    end
    if ready(State.march) then
        -- THE lane W pattern, W-GEOM-2 (v0.1.270/.271, user design, study sec 8): THE CROSS -
        -- ONE builder (march_cross_target), two arms 90 deg apart rotated 45 off the
        -- hero->aim axis, alternating per cast via the State.wArm global latch (flips only
        -- on success, the v0.1.176 lesson). The crossed arms see DIFFERENT projections of
        -- the wave, so the melee screen cannot shadow the trailing ranged in both casts,
        -- and there is no rear-sweep eligibility hole. Camps unchanged.
        -- W-GEOM-3 (v0.1.277): the v0.1.221 W_FRONT_MAX edge hold is DELETED - it was the
        -- instant-AOE model's compensation (fire late so the box lands on the wave). The
        -- wavefront model owns timing now: the FIRST W fires preemptively from MOVE at
        -- W_LEAD_S (see fsm_move_wave); by the time the engage casts, the wave is at most
        -- ~950 out and closing = robots meet it mid-corridor (sim-validated at far longer
        -- leads than this).
        -- v0.1.281 (run-89 t~2:20, user: "cast the second W under the tower and
        -- teleported"): THE ARRIVAL GATE - the engage's cast waits for the wave to
        -- actually arrive (dref <= WAVE_ENGAGE_RANGE) and be worth it (2+ creeps; a lone
        -- straggler dies to the allied wave, wave_clear exits at casts=0). All early
        -- casting belongs to the MOVE preempt.
        -- v0.1.284 (run-92: BOTH arms fired with the wave 1100-1400 out): the .281 arm-2+
        -- exemption ("the wave is on us by then") went false the moment prearm_w2 made W
        -- ready BEFORE arrival; combined with the stale-eta timed latch, arm 2 fired the
        -- tick the engage entered. The gate applies to EVERY cast now - arm 2 waits for
        -- the wave exactly like arm 1 (the user rule: "when the wave is visible cast the
        -- next W" - visible AND arrived).
        do
            local dref0 = me:Distance(s.standSpot.aim)
            -- v0.1.286 (run-94 4:30, user: "casted W too far and didn't hit the ranged
            -- creep"). v0.1.372 CORRECTION: the old "(280+900)*cos45 ~ 834 along the aim
            -- axis" reasoning here was WRONG by about 400u. (CAST_RANGE + HALF) * cos45 is the
            -- arm TIP projected onto the aim axis, and that tip is ALSO 834u OFF the axis, so it
            -- was never a coverage test. MEASURED envelope (lib/march_sim probe, MARCH_HALFWIDTH
            -- 900 per the K table): FULL coverage 400 to 1200, 5 hits at 1300, ZERO at 1400. Analytic
            -- lateral bound 900/sin(theta) = 1273 at 45 deg; travel bound (1800-600)/cos45 = 1697.
            -- THE LATERAL BOUND BINDS. STANDING NOTE, and it is the important half: the envelope
            -- is FLAT from 400 to 1200 with AND without a melee screen, so geometry CANNOT
            -- distinguish 700 from 1200 and this correction LICENSES NO CHANGE to K.W_CAST_REACH.
            -- That constant was set twice by WATCHED BEHAVIOUR (v0.1.286 run-94, v0.1.305 run-99)
            -- whose mechanism is still unidentified - do not "fix" it from geometry.
            -- The gate allowed casts at dref up to 950 and the trailing ranged sat outside the
            -- corridor. The ARRIVAL cast waits to the arm's reach
            -- (the old W_FRONT_MAX 800 was right for arrival casts all along); lead
            -- casts are unaffected (their waves walk in).
            -- v0.1.305 (user, run-110 t=349: a locked even/hold fight sat 46s in this W-wait;
            -- the ledger's held-wave unit [.291+.295+.298+.288] re-applied, unified with the
            -- .304 consecutive-W2 principle): the reach gate applies to the FIRST cast ONLY -
            -- W2+ follows the rearm unconditionally (prediction guarantees it lands after).
            -- A held first cast STEPS IN to the gate (tower + walk-law checked; never when
            -- receding); a casts=0 wait past W_WAIT_RELEASE_S releases to the jungle window
            -- (half-engaged waves are never dumped - the .301 lesson).
            if (State.marchCasts or 0) == 0 and (dref0 > K.W_CAST_REACH or live.n < 2) then
                s.wwD = math.min(s.wwD or dref0, dref0)
                if dref0 > K.W_CAST_REACH and live.n >= 2 and dref0 <= (s.wwD or dref0) + 100 then
                    local sdx, sdy = s.standSpot.aim.x - me.x, s.standSpot.aim.y - me.y
                    local sdl = math.sqrt(sdx * sdx + sdy * sdy)
                    if sdl > 1 then
                        local step = dref0 - K.W_CAST_REACH + 30
                        local tgt = Vector(me.x + sdx / sdl * step, me.y + sdy / sdl * step, me.z)
                        -- v0.1.310: the step-in obeys tower_safe (d >= 1000, outside the real
                        -- 900 range) - the SAME binary that clamps every stand, so it can never
                        -- walk him into tower range for a W2 (the user's observed attack).
                        if tower_safe({ x = tgt.x, y = tgt.y })
                           and stand_depth({ x = tgt.x, y = tgt.y }) <= K.WALK_DEPTH_MAX + 50 then
                            move_to(tgt, "w_stepin")
                        end
                    end
                end
                -- v0.1.377: the s.wwT start and the W_WAIT_RELEASE_S release that used to sit HERE
                -- are hoisted above `if ready(State.march)` (see the watchdog block there). Removing
                -- them from this branch is what makes the timer run with March on cooldown; leaving
                -- a second copy would double-start nothing but would hide the hoist from a reader.
                State.waitInfo = { why = string.format("W wait %d n=%d c=%d", math.floor(dref0), live.n, State.marchCasts or 0), t = now() }
                return
            end
            s.wwT, s.wwD = nil, nil
        end
        local cp, theta = march_cross_target(me, s.standSpot.aim)
        if cast_pos(State.march, cp) then
            State.marchPending = { cdBefore = cd_remaining(State.march), expire = now() + 1.5 }
            State.wArm = (State.wArm == 2) and 1 or 2
            logline(string.format("march_aim src=shove pat=x%d lane=%s wave=(%.0f,%.0f) cast=(%.0f,%.0f) creeps=%d dWave=%.0f",
                theta, tostring(s.lane), live.cx, live.cy, cp.x, cp.y, live.n, me:Distance(s.refPoint)))
        end
    elseif effective_mana() < abil_mana(State.rearm, K.REARM_MANA_FB) + abil_mana(State.march, K.MARCH_MANA_FB) then
        -- v0.1.200 guard (run-28 t=483, belt to the hop-gate fix): in a WAVE engage Rearm exists
        -- only to reset March, so rearming when the FOLLOW-UP March is not fundable (even with
        -- charges) burns ~225 and strands him castless. Bail with the trip home still funded.
        logline(string.format("engage_bail reason=rearm_unfundable mana=%.0f", effective_mana()))
        if s.shove then suppress_shove(s.lane, now() + K.SHOVE_STUCK_S, "rearm_unfundable") end
        go_return()
    elseif safe_rearm() then
        logline("rearm")
    elseif not State.rearmStepback then
        -- v0.1.267 STEP-BACK REARM arming: the rearm was refused and by here the blockers
        -- are Rearm not ready (cd, or unleveled pre-6), the backoff, a cast fail, or THE CHANNEL GATE (lane_unsafe aborted the
        -- whole engage above; the previous elseif bails on effective_mana, try_rearm refuses on RAW+reserve). Test the
        -- gate directly: a gating enemy in reach = walk straight AWAY from it to the first
        -- spot the gate clears and rearm there (driver at the top of this function).
        local thr, tpos = channel_threat_near(me)
        if thr and tpos then
            local dx, dy = me.x - tpos.x, me.y - tpos.y
            local dl = math.sqrt(dx * dx + dy * dy)
            if dl > 1 then
                for _, step in ipairs({ 500, 800, 1100 }) do
                    local cand = Map.SnapWalkable({ x = me.x + dx / dl * step, y = me.y + dy / dl * step }, me)
                    if cand and not channel_threat_near(cand) then
                        State.rearmStepback = { spot = Vector(cand.x, cand.y, 0), deadline = now() + K.REARM_STEPBACK_S }
                        logline(string.format("rearm_stepback out d=%d threat=%s", step, thr))
                        break
                    end
                end
            end
        end
        -- W-GEOM-1 KITE (falls through when no gating enemy blocked the rearm): the wave
        -- ADVANCES while we cast+rearm, and nothing above ever steps the hero BACK - he
        -- parks while the wave (and the laner behind it) envelops him. Maintain the
        -- standard position: the live stand (re-derived from the ranged at 810 every tick
        -- by update_wave_spot) recedes with the wave; follow it between casts.
        if not State.rearmStepback and not State.marchPending
           and me:Distance(s.standSpot.aim) < K.ANTICIP_RANGED_REACH - K.STAND_KITE_EPS then
            move_to(s.standSpot.stand, "wave_kite")
        end
    end
end

-- F1: live effective HP of the engaged camp (+ its pair partner) for the stack-
-- aware budget. Summed from the in-vision creeps, so stacks are included.
local function live_camp_ehp(s, neutrals)
    local e = Farm.EffectiveHP(camp_creep_list(s.camp, s.type, neutrals))
    local ss = s.standSpot
    if ss and ss.paired and ss.partnerCamp then
        -- one perpendicular W spans BOTH camps, so the clear budget is the TANKIER camp (MAX), NOT the sum
        -- (the v0.1.103 pair model, which the valuation already uses). Summing over-budgeted the execution
        -- -> extra Marches = wasted mana + time (bug: more marches than needed / mana starve without Bottle).
        -- The clip lean-in (CLIP_EXTRA_MARCHES on `base`) still covers a far camp whose outer creeps spill.
        local ep = Farm.EffectiveHP(camp_creep_list(ss.partnerCamp, ss.partnerType or s.type, neutrals))
        e = math.max(e, ep)
    end
    return e
end

-- Is this engage an ANCIENT camp (itself or its pair partner)? Ancients = tier 3.
local function ancient_engage(s)
    if s.type == 3 then return true end
    local ss = s.standSpot
    return ss and ss.paired and ss.partnerType == 3 or false
end

-- Laser target (v0.1.201, user): ONLY the ancient camp's TOUGHEST creep (highest MAX HP - the one
-- that outlives the March budget), and only as a FINISHER (current hp <= killhp = one-shot range).
-- The old any-killable-creep last-hit fired 33x on 104-216hp small fry in run-29 (~4k mana across
-- the game) - March's sweep kills those for free; the laser saved nothing and drained every
-- ancient clear. Pure damage -> killhp is the flat per-level value, no armor/MR adjust.
local function laser_lasthit_target(s, neutrals, killhp)
    local best, bestmax = nil, -1
    local function scan(camp)
        for _, c in ipairs(Map.CampCreeps(camp, neutrals) or {}) do
            local hp = (Entity.GetHealth and Entity.GetHealth(c)) or 0
            local mhp = (Entity.GetMaxHealth and Entity.GetMaxHealth(c)) or 0
            if hp > 0 and mhp > bestmax then bestmax, best = mhp, c end
        end
    end
    if s.type == 3 then scan(s.camp) end
    if s.standSpot.paired and s.standSpot.partnerType == 3 and s.standSpot.partnerCamp then
        scan(s.standSpot.partnerCamp)
    end
    local hp = best and ((Entity.GetHealth and Entity.GetHealth(best)) or 0) or 0
    return (best and hp > 0 and hp <= killhp) and best or nil
end

-- v0.1.224 STACK engage (user: large camps, 2x, GPM-first): hold at the stand until the aggro
-- second, ATTACK one camp creep (they chase), drag them toward our fountain until just past the
-- :00 respawn, then release to the planner. No mark_cleared (the camp respawns STACKED; the
-- stack-aware budget clears it next visit). The fsm_engage leave_by preempt runs BEFORE this
-- (waves always win); camp_unsafe_abort covers live danger.
local function fsm_engage_stack(s)
    State.fog = enemy_snapshot()
    if camp_unsafe_abort(s, "stack") then return end
    local me = origin(State.hero)
    if now() >= s.fleeUntil then
        logline(string.format("stack_done key=%s", tostring(s.key)))
        State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
        return
    end
    if now() < s.aggroAt then
        State.waitInfo = { why = string.format("stack %ds", math.max(0, math.floor(s.aggroAt - now()))), t = now() }
        if me:Distance(s.standSpot.stand) > K.WAVE_HOLD_EPS then move_to(s.standSpot.stand, "engage_hold") end
        return
    end
    if not s.aggroed then
        local tgt
        for _, c in ipairs(Map.CampCreeps(s.camp, Map.AllNeutrals()) or {}) do tgt = c; break end
        if not tgt then
            logline("stack_abort empty")
            State.spot = nil; State.fsm = "DECIDE"; State.moveSince = nil
            return
        end
        if issue(UO.DOTA_UNIT_ORDER_ATTACK_TARGET, nil, tgt, nil) then
            s.aggroed = true
            s.dragAt = now() + K.STACK_AGGRO_DWELL_S   -- v0.1.338: let the attack LAND first (g339 order log: the drag fired +0.1s after the attack ORDER and canceled it - no aggro ever happened; stack_done is only the flee timer, not success)
            logline(string.format("stack_aggro key=%s sec=%.1f", tostring(s.key), now() % 60))
        end
        return
    end
    if s.dragAt and now() < s.dragAt then
        State.waitInfo = { why = "stack aggro", t = now() }
        return
    end
    -- dragging: away from the camp toward our fountain until the respawn tick passes
    local fp = friendly_fountain_pos()
    if fp then
        local dx, dy = fp.x - s.center.x, fp.y - s.center.y
        local dl = math.sqrt(dx * dx + dy * dy); if dl < 1 then dl = 1 end
        local r = K.STACK_STAND_DIST + K.STACK_FLEE_DIST
        move_to(Vector(s.center.x + dx / dl * r, s.center.y + dy / dl * r, me.z), "stack_drag")
    end
    State.waitInfo = { why = "stack drag", t = now() }
end

local function fsm_engage()
    local s = State.spot
    if not s then go_return(); return end
    if s.kind == "wave" then return fsm_engage_wave(s) end
    -- Note 3: preempt to mid the moment the shove leave-by passes - UNCONDITIONAL (was only checked
    -- after a March resolved, so a stalled/long camp never bailed -> Tinker missed the wave / lost
    -- the lane). Heading to mid on time keeps the lane served.
    if State.shoveLeaveBy and now() >= State.shoveLeaveBy then
        logline("engage_preempt reason=leave_by casts=" .. tostring(State.marchCasts or 0))
        engage_replan(); return
    end
    if s.kind == "stack" then return fsm_engage_stack(s) end   -- v0.1.224 (after the leave_by preempt: waves always win)
    if camp_unsafe_abort(s, "engage") then return end
    -- Occupancy debounce: do NOT abandon the camp the instant occupancy reads false.
    -- The hero now stands ~STAND_RING from the centre (in vision), but creeps move
    -- and die so occupancy still flickers; bail only on SUSTAINED emptiness (really
    -- cleared / gone), low mana, or the budget being done. Log the bail reason.
    -- Pair-aware occupancy: enumerate neutrals ONCE, then box-check both camps. A pair is
    -- "done empty" only when BOTH camps are empty (from the midpoint both centres are in
    -- vision, so the reads are valid); a single spot just checks s.camp. This keeps the lean-in
    -- clip Marches firing instead of bailing the instant the near camp empties first.
    local neutrals = Map.AllNeutrals()
    -- #4: refresh the value cache from the LIVE box each tick, so a camp left partially farmed then fogged
    -- carries its true remaining bounty (alive creeps) with NO contaminated gold-delta. gather_candidates
    -- only reads at DECIDE; this closes the DURING-engage gap (kill 2 creeps -> keen home -> fog before the
    -- next decide would leave the cache at the pre-engage value).
    local function refresh_value(camp, ctype, center)
        local list = camp_creep_list(camp, ctype, neutrals)
        State.campSeen[Map.CampKey(center)] = { gold = Farm.GoldValue(list), ehp = Farm.EffectiveHP(list), seen_at = now() }
    end
    refresh_value(s.camp, s.type, s.center)
    if s.standSpot.paired and s.standSpot.partnerCamp then
        refresh_value(s.standSpot.partnerCamp, s.standSpot.partnerType or s.type, s.standSpot.partner)
    end
    local occupied = #Map.CampCreeps(s.camp, neutrals) > 0
    if s.standSpot.paired and s.standSpot.partnerCamp then
        occupied = occupied or #Map.CampCreeps(s.standSpot.partnerCamp, neutrals) > 0
    end
    if occupied then
        State.emptySince = nil
        s.campEhp = s.campEhp or live_camp_ehp(s, neutrals)   -- F1: snapshot the FULL (stacked) ehp once for the stack-aware budget
    else
        State.emptySince = State.emptySince or now()
        -- v0.1.259 ARRIVAL-EMPTY ZERO-CAST EXIT (run-74: manually/ally-cleared camps re-farmed;
        -- the MIN_CASTS debounce forced 2-3 W + interleaved Rearms into visibly-empty boxes,
        -- ~470-770 mana + 8-14s per phantom trip). No March fired or in flight yet + EVERY
        -- committed box in vision + empty = nothing to debounce (the flicker guard exists for
        -- creeps aggro'd out MID-engage). Hold the first cast while the read settles, then exit
        -- with zero casts. A fogged partner box keeps the old 2-cast path (conservative).
        if (State.marchCasts or 0) == 0 and not State.marchPending then
            local ve = camp_visible(s.center)
            if ve and s.standSpot.paired and s.standSpot.partner then
                ve = camp_visible(s.standSpot.partner)
            end
            if ve then
                if now() - State.emptySince > K.ENGAGE_EMPTY_GRACE then
                    mark_spot_cleared(s)
                    logline(string.format("engage_done reason=empty casts=0 dur=%.1f est=%.1f arrive_empty",
                        now() - (State.engageStart or now()), s.clearEst or 0)); engage_replan(); return
                end
                return   -- visibly empty, no cast spent yet: hold the March until the read settles
            end
        end
        -- v0.1.242 W-CANCEL (camps, user feature): same as the wave cancel, but only past the
        -- MIN_CASTS_BEFORE_EMPTY debounce - creeps aggro OUT of the box after the first cast
        -- (the A-flicker below), and canceling on that false empty would drop a real W.
        local mp0 = State.marchPending
        if mp0 and (State.marchCasts or 0) >= K.MIN_CASTS_BEFORE_EMPTY then
            if (not ready(State.march)) or cd_remaining(State.march) > mp0.cdBefore + 0.05 then
                State.marchCasts = State.marchCasts + 1; State.marchPending = nil
                logline(string.format("march cast=%d t=%.1f", State.marchCasts or 0, now()))
            else
                local me0 = origin(State.hero)
                if issue(UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION, nil, nil, me0) then   -- bypass move_to: the dedup must not eat the cancel
                    State.marchPending = nil
                    logline("march_cancel reason=empty src=camp")
                end
            end
        end
        -- A: don't abort on the FIRST occupancy flicker. Creeps aggro out of the camp box right after the
        -- first March, so a 1-cast read=empty bailed with the creeps still alive (got=6). Require at least
        -- MIN_CASTS_BEFORE_EMPTY fired Marches before honouring "empty" (a genuinely empty camp just wastes
        -- one extra cast, then clears out as before).
        if now() - State.emptySince > K.ENGAGE_EMPTY_GRACE and (State.marchCasts or 0) >= K.MIN_CASTS_BEFORE_EMPTY then
            mark_spot_cleared(s)   -- verified empty: skip until the next respawn so we spread, not loop
            logline(string.format("engage_done reason=empty casts=%d dur=%.1f est=%.1f", State.marchCasts or 0,
                now() - (State.engageStart or now()), s.clearEst or 0)); engage_replan(); return
        end
    end
    if mana() < State.menu.escapeMana:Get() then
        logline("engage_bail reason=mana mana=" .. math.floor(mana())); go_return(); return
    end
    -- Resolve a March in flight: count it ONLY when it verifiably FIRED (cooldown
    -- jump / no longer ready), and never re-issue mid-wind-up (a re-issue restarts
    -- March's cast point and can cancel it). The scope-A loop incremented on ISSUE
    -- and re-issued every ~0.05s, so the budget raced ahead of the real casts (3
    -- phantom marches before one fired) and the camp was abandoned to RETURN before
    -- Rearm ever fired. With fire-gating, Rearm fires between Marches.
    local mp = State.marchPending
    if mp then
        if (not ready(State.march)) or cd_remaining(State.march) > mp.cdBefore + 0.05 then
            State.marchCasts = State.marchCasts + 1
            State.marchPending = nil
            logline(string.format("march cast=%d t=%.1f", State.marchCasts or 0, now()))
            -- (leave-by preempt now checked unconditionally at the top of fsm_engage, note 3)
        elseif now() > mp.expire then
            State.marchPending = nil
            logline("march issued_NOT_fired_retry")
        else
            return   -- still winding up: wait, do not re-issue
        end
    end
    -- N4 (COR-03 remaining half): budget on the TANKIER of the two camps. The pair midpoint
    -- cast covers both, but a tanky ANCIENT partner needs more Marches than the near camp's
    -- tier; keying to s.type alone under-budgeted it, so the ancient never cleared (got~0).
    local btype = s.type
    if s.standSpot.paired and s.standSpot.partnerType and s.standSpot.partnerType > btype then
        btype = s.standSpot.partnerType
    end
    local base = marches_for(btype)
    if s.standSpot.paired and s.standSpot.clear == "clip" then
        base = base + K.CLIP_EXTRA_MARCHES   -- lean-in: extra Marches to finish a clip pair's spilled outer creeps
    end
    -- F1: stack-aware. The pair's live ehp (stacks included) can need more Marches than
    -- the per-tier base; ClearBudget raises the count for a stacked camp but NEVER below
    -- `base` (no regression on a normal camp).
    -- #1: cap the clear at MAX_CLEAR_MARCHES (+ the clip lean-in) so a huge live stack can't grind forever
    -- (candidacy already gated est-ehp within the cap; a bigger live ehp part-clears then re-opens at respawn).
    local budget = math.min(K.MAX_CLEAR_MARCHES + K.CLIP_EXTRA_MARCHES, Farm.ClearBudget(base, s.campEhp or 0, effective_march_dmg()))
    if State.marchCasts >= budget then
        mark_spot_cleared(s)   -- did the budget here: move on (re-open at the next respawn), do not re-pick it
        logline(string.format("engage_done reason=budget casts=%d budget=%d dur=%.1f est=%.1f%s", State.marchCasts, budget,
            now() - (State.engageStart or now()), s.clearEst or 0,
            (s.standSpot.paired and (" pair=" .. tostring(s.standSpot.clear))) or "")); engage_replan(); return
    end
    -- ANCIENT: LAST-HIT ONLY (user). March AoEs the whole camp; Laser is single-target, so only fire it to
    -- FINISH a creep already in one-shot range (hp <= LASER_DMG) rather than spamming a full-HP tank. On a
    -- tanky ancient March leaves creeps low, so this still saves Marches, without the wasted early casts.
    if ancient_engage(s) and ready(State.laser)
       and mana() >= State.menu.escapeMana:Get() + abil_mana(State.laser, K.LASER_MANA_FB) then
        local killhp = K.LASER_DMG[(State.laser and Ability.GetLevel(State.laser)) or 0] or 0
        -- v0.1.187: live KV read (special "laser_damage", gitbook GetLevelSpecialValueFor) beats
        -- the table when present - patch-proof, same pattern as the March per-robot read.
        local okv, lv = pcall(function()
            return Ability.GetLevelSpecialValueFor and Ability.GetLevelSpecialValueFor(State.laser, "laser_damage", -1)
        end)
        if okv and type(lv) == "number" and lv > 0 then killhp = lv end
        local tgt = killhp > 0 and laser_lasthit_target(s, neutrals, killhp) or nil
        if tgt and cast_target(State.laser, tgt) then
            logline(string.format("laser lasthit hp=%.0f", (Entity.GetHealth and Entity.GetHealth(tgt)) or 0)); return
        end
    end
    if ready(State.march) then
        local cp = march_cast_point_multi(s, State.marchCasts)   -- multi-W: alternate sides for even coverage
        if cast_pos(State.march, cp) then
            State.marchPending = { cdBefore = cd_remaining(State.march), expire = now() + 1.5 }
            local me = origin(State.hero)
            logline(string.format("march_aim src=%s stand=(%.0f,%.0f) cast=(%.0f,%.0f) hero=(%.0f,%.0f) camp=(%.0f,%.0f)%s",
                (s.standSpot.paired and "pair" or "single"),
                s.standSpot.stand.x, s.standSpot.stand.y, cp.x, cp.y, me.x, me.y, s.center.x, s.center.y,
                s.standSpot.partner and string.format(" pcamp=(%.0f,%.0f)", s.standSpot.partner.x, s.standSpot.partner.y) or ""))
        end
    elseif try_rearm() then                                                       -- March on cd -> Rearm to reset it, then March again
        logline("rearm")
    end
end

local function has_fountain_buff()
    local m = NPC.GetModifier(State.hero, "modifier_fountain_aura_buff")  -- V2-confirmed
    return m ~= nil
end

-- v0.1.254 (Defense case-file #1, the keen_cancel_check twin): a Rearm whose channel got broken
-- (stun/hex from a laner - attack damage does NOT break channels) burned its mana WITHOUT
-- resetting the cds, and nothing noticed: March still on cd -> the next tick re-channeled next
-- to the same disabler -> consecutive burns -> mana dry (user sighting, disable-lane bot game).
-- Judge at due: whichever basic cd was meaningfully running at cast time must have RESET.
-- cd_remaining's 0.1 not-ready fallback errs toward "reset" = false negatives only (safe).
local function rearm_cancel_check()
    local p = State.rearmPending
    if not p or now() < p.due then return end
    State.rearmPending = nil
    if now() > p.due + 1.5 then return end          -- stale (the keen_cancel freshness rule)
    local canceled = false
    if p.mcd and p.mcd > 4 then canceled = cd_remaining(State.march) > 0.5
    elseif p.kcd and p.kcd > 4 then canceled = cd_remaining(State.keen) > 0.5 end
    if canceled then
        State.rearmCancelT = now()
        logline(string.format("rearm_canceled mana=%.0f -> backoff %ds", mana(), K.REARM_CANCEL_BACKOFF_S))
    end
end

local function fsm_return()   -- REFILL: Keen home -> Rearm to reset Keen -> wait HP+mana >= REFILL_FRAC -> DECIDE
    local h = State.hero
    State.fog = enemy_snapshot()   -- E0 (B5): RETURN ran on the last decide's snapshot - the en-route resume gate and every risk read below predated the walk by 10-20s (a rotating enemy was invisible; the resume could turn him back INTO the gank)
    if has_fountain_buff() then
        -- v0.1.202/212 (the EXTERNAL 2_ItemsManager.lua auto-bottle cancels our Rearm channel at
        -- the fountain; .202 moved the rearm AFTER the fill, run-35 still showed occasional
        -- cancels at the mthresh level = the manager's bar is above ours). v0.1.212 (user's idea):
        -- rearm attempts start AT LANDING and run DURING the fill - the fill is the critical path,
        -- a canceled channel's mana refills concurrently - capped at 2 attempts, and refill_done
        -- NEVER waits on keen: a failed reset degrades to the field ladder (rearm away from the
        -- manager's bottle) or the natural cd.
        if not ready(State.keen) and (State.fountainRearms or 0) < 2 then
            if try_rearm() then
                State.fountainRearms = (State.fountainRearms or 0) + 1
                return
            end
        end
        local mmax = NPC.GetMaxMana(h) or 1
        -- refill at least to REFILL_FRAC, but never below the escape floor (else tick() bounces us
        -- straight back to RETURN -> a refill loop if the user sets escape mana above 0.70*max). Clamp
        -- to max so an escape floor > max mana can still complete (waits for full instead of forever).
        local esc = (State.menu and State.menu.escapeMana and State.menu.escapeMana:Get()) or K.ESCAPE_MANA
        -- COST-AWARE refill (ancient arc): the planner's refill step may be ENABLING a big-ticket
        -- next target (State.refillNeed = its mana_cost + keen reserve, set at dispatch) - wait for
        -- that level, capped at max. Otherwise the 0.70 tempo leave stands.
        local mthresh = math.min(mmax, math.max(mmax * K.REFILL_FRAC, esc, State.refillNeed or 0))
        local hpFull = (Entity.GetHealth(h) or 0) >= (Entity.GetMaxHealth(h) or 1) * K.REFILL_FRAC
        local mpFull = mana() >= mthresh
        if hpFull and mpFull then
            State.fsm = "DECIDE"; State.refillNeed = nil; State.fountainRearms = nil
            logline("refill_done")
        end
        return
    end
    State.fountainRearms = nil   -- v0.1.212: en route (not in the buff yet) = a fresh visit's counter
    -- Note 2 (over-return): resources often recover EN ROUTE (passive regen + Bottle), so ABORT the
    -- trip home and resume farming instead of walking/teleporting all the way to base (we were
    -- teleporting in at ~70% mana with a wave up). Only when SAFE - never abort a threat retreat.
    local mmax, hpmax = NPC.GetMaxMana(h) or 1, Entity.GetMaxHealth(h) or 1
    -- cost-aware refill: a big-ticket trip (refillNeed above the resume level) must reach the
    -- fountain - the 0.70 en-route resume would strand the ancient plan under-funded forever.
    if (not State.refillNeed or State.refillNeed <= mmax * K.RETURN_RESUME_FRAC)
       and mana() >= mmax * K.RETURN_RESUME_FRAC
       and (Entity.GetHealth(h) or 0) >= hpmax * K.RETURN_RESUME_FRAC
       and enemy_risk_at(origin(h)) < K.FARM_SAFE_RISK then
        State.fsm, State.spot = "DECIDE", nil
        if now() - (State.lastResumeLog or -99) > 2.0 then State.lastResumeLog = now(); logline("return resume mana_ok") end
        return
    end
    local fpf = friendly_fountain_pos()
    -- Note 5: keen lands 70-800u NEAR the fountain, often OUTSIDE the regen zone, so re-keening
    -- re-teleports him outside again ("teleported outside the fountain"). When already close,
    -- WALK the last bit into the fountain instead of re-keening.
    if fpf and origin(h):Distance2D(fpf) <= K.FOUNTAIN_WALK_IN then
        move_to(Vector(fpf.x, fpf.y, origin(h).z), "fountain_walkin")
        if now() - (State.lastWalkHomeLog or -99) > 2.0 then State.lastWalkHomeLog = now(); logline("return walk_in_fountain") end
        return
    end
    -- self-cast Keen auto-conveys to fountain when >1500 away (V2-confirmed idiom).
    -- E0 (B2): a return triggered by a THREAT used to open a 2-3s channel in the face of the very
    -- enemies that caused the abort (keen_home ungated, try_rearm raw) = a free cancel for any
    -- disabler. Under pressure (lane_unsafe at the hero) both channel rungs are skipped and the
    -- walk/blink branch runs; the gate re-reads every tick, so the keen fires the moment the
    -- chase breaks. Unpressured returns are byte-identical.
    -- E0 (B2) gank pressure OR ARC E1 a lone disabler in reach: both make the 2-3s return
    -- channel a donation - walk until the reach breaks, then the keen rung re-opens.
    local mepos = origin(h)
    local pressured = lane_unsafe(mepos)
                      or (channel_threat_near and channel_threat_near(mepos) ~= nil)
    if pressured and now() - (State.pressuredLogT or 0) > 2.0 then
        State.pressuredLogT = now(); logline("return pressured -> walk")
    end
    if not pressured and ready(State.keen) then
        if keen_home("return") then logline("return keen_base") end
    elseif not pressured and try_rearm() then                   -- Keen on cd in the field: Rearm to reset it
        logline("return rearm_reset_keen")
    else
        -- Note 2: Keen on cd AND can't Rearm (low mana after a shove) -> Tinker stood IDLE in the field
        -- with no walk-home fallback and no watchdog = the silent stuck. Walk toward the fountain instead.
        local fp = friendly_fountain_pos()
        if fp then
            -- v0.1.222 (user, run-45 t=346-360: walked home 14s with the dagger in the bag while
            -- mana climbed 85->227 - Keen was on CD and Rearm unaffordable, but the BLINK doctrine
            -- says a safe walk is a blinkable walk): hop toward the fountain, walk the rest.
            if not try_travel_blink(Vector(fp.x, fp.y, origin(h).z)) then
                move_to(Vector(fp.x, fp.y, origin(h).z), "walk_home")
            end
            if now() - (State.lastWalkHomeLog or -99) > 2.0 then   -- throttle: was logged every tick (632x); the over-return root is a separate (designed) fix
                State.lastWalkHomeLog = now()
                -- note 2 diag: why walk home instead of bottle-sustain? log mana + bottle charges + risk.
                local bt = NPC.GetItem(State.hero, "item_bottle", true)
                local bch = (bt and Item.GetCurrentCharges and Item.GetCurrentCharges(bt)) or -1
                logline(string.format("return walk_home mana=%.0f bottle=%d risk=%.2f", mana(), bch,
                    enemy_risk_at(origin(h))))
            end
        end
    end
end

-- Bottle sustain: drink when low + safe + NOT channeling, so it never interrupts a Rearm/Keen channel.
-- API idioms verified from deployed prior-art scripts (NPC.GetItem by-name, CanBeExecuted==-1 = castable,
-- Item.GetCurrentCharges, no_target cast). Bottle regen breaks on enemy hero/tower damage -> safe-gated.
local function bottle_tick()
    local bottle = NPC.GetItem(State.hero, "item_bottle", true)
    if not bottle or Ability.CanBeExecuted(bottle) ~= -1 or Item.GetCurrentCharges(bottle) <= 0 then return end
    if NPC.HasModifier(State.hero, "modifier_bottle_regeneration") then return end   -- already drinking: don't waste charges
    if is_channeling() then return end                                       -- HARD RULE: never interrupt Rearm/Keen
    local h = State.hero
    -- v0.1.220 (user: THE Tinker item function = a fully automatic Bottle - life, mana, channel
    -- aware, and FOUNTAIN-ACCELERATED): at the fountain the charges refill instantly, so
    -- CHAIN-DRINKING stacks the bottle's regen ON TOP of the fountain's = measurably shorter
    -- visits (the #1 non-engage time sink), at zero charge cost. Any real hp/mana deficit
    -- qualifies there (the modifier gate above paces one drink per regen window). Field
    -- drinking keeps the low thresholds + the risk gate (bottle regen breaks on enemy damage).
    -- With this owning the bottle end-to-end, the external ItemsManager's auto-bottle (the old
    -- Rearm-cancel source) can be disabled by the user.
    if has_fountain_buff() then
        local needm = mana() < ((NPC.GetMaxMana and NPC.GetMaxMana(h)) or 1) - 5
        local needh = (Entity.GetHealth(h) or 0) < (Entity.GetMaxHealth(h) or 1) - 5
        if (needm or needh) and cast_no_target(bottle) then logline("bottle drink fountain") end
        return
    end
    local lowm = mana() < K.BOTTLE_MANA
    local lowh = (Entity.GetHealth(h) or 1) < (Entity.GetMaxHealth(h) or 1) * K.BOTTLE_HP_FRAC
    -- v0.1.386 THE CONVERSION RUNG (queue item 2, MEASURED not reasoned). effective_mana() counts
    -- Bottle charges as spendable and the callers gate on it, but try_rearm spends RAW against the
    -- escape reserve, and this function only ever drank below K.BOTTLE_MANA 200 - so in the whole
    -- band above 200 the counted charges were UNREACHABLE and the hero refused a rearm he could
    -- actually pay for. g383 measured 87 refusals: 63 had eff >= need with raw < need, 67 sat at
    -- raw >= 200 where no drink could ever fire, mean 106 mana (about two charges) left in the
    -- bottle, and 29 were in ENGAGE. Fountain time was 15.1% of that game.
    -- So: a rearm refused for mana in the last second, whose gap the charges would actually close,
    -- counts as low mana. This REUSES the whole existing bottle path - the regen-modifier pacing,
    -- the channel guard above, and the risk gate below all still apply, and nothing else changes.
    -- It does not force a rearm; it only makes the mana effective_mana() already promised real.
    local ch = (Item.GetCurrentCharges and Item.GetCurrentCharges(bottle)) or 0
    -- v0.1.389: the freshness test is TWO-SIDED. It was `now() - stamp < 1.0`, upper bound only,
    -- and now() restarts near zero on a second match in one script load, so a stamp of ~900 from the
    -- previous game evaluates as -900 < 1.0 = TRUE for the WHOLE new match instead of for one second.
    -- Identical inside a single match (age is never negative there), so this cannot move a live game.
    local rnfAge = State.rearmNoFundT and (now() - State.rearmNoFundT) or nil
    -- v0.1.411 REPAIR OF A v0.1.397 LINE SLIP (found by the raid-gate adversarial review,
    -- verified against the c732d96 diff): the wantKeen insertion landed BETWEEN wantRearm's
    -- first line and its gap-closability continuation, silently capturing that clause into
    -- wantKeen's expression. Consequence, measured: wantKeen also required a small
    -- rearmNoFundGap (nil reads math.huge = false), so `bottle drink why=keen` fired ZERO
    -- times in 48 logs, and wantRearm drank on ANY refusal regardless of whether the charges
    -- close the gap. Each flavour now owns exactly its OWN gap clause, the shape v0.1.386
    -- validated at g384/g385. The raid arm's mana_defer path depends on the keen flavour
    -- actually firing, which is why the repair ships with the raid gate.
    local wantRearm = rnfAge ~= nil and rnfAge >= 0 and rnfAge < 1.0
                      and (State.rearmNoFundGap or math.huge) <= ch * K.BOTTLE_MANA_PER_CHARGE
    -- v0.1.397: the keen flavour of the same rung (a lane keen was just deferred for mana the
    -- charges can cover). Two-sided age per the v0.1.389 rule.
    local knfAge = State.keenNoFundT and (now() - State.keenNoFundT) or nil
    local wantKeen = knfAge ~= nil and knfAge >= 0 and knfAge < 1.0
                     and (State.keenNoFundGap or math.huge) <= ch * K.BOTTLE_MANA_PER_CHARGE
    if not (lowm or lowh or wantRearm or wantKeen) then return end
    if enemy_risk_at(origin(State.hero)) >= K.SHOVE_SAFE_RISK then return end -- bottle breaks on enemy damage
    -- v0.1.386: name the cause. `why=rearm` is the NEW rung and is the acceptance signal for the
    -- conversion fix; lowm/lowh are the pre-existing behaviour and must not change rate.
    if cast_no_target(bottle) then
        logline(string.format("bottle drink why=%s raw=%.0f ch=%d gap=%s",
            (lowm and "lowm") or (lowh and "lowh") or (wantRearm and "rearm") or "keen", mana(), ch,
            (wantRearm and string.format("%.0f", State.rearmNoFundGap or 0))
                or (wantKeen and string.format("%.0f", State.keenNoFundGap or 0)) or "-"))
    end
end

-- Mana engine part 3 (2026-07-04, Liquipedia-verified): pump the pool from ITEMS before the
-- deficit forces a fountain trip. Arcane Replenish is free (+150, cd 55): pop on any real
-- deficit. Soul Ring Sacrifice (+170 for 10s, -170 HP, cd 30): only when casts are IMMINENT
-- (ENGAGE - the temp mana must be spent inside its window) and HP is healthy. Inventory-driven:
-- no purchase logic, the brain exploits whatever the build carries (item choice = the user's).
local function mana_items_tick()
    local h = State.hero
    if is_channeling() then return end                                       -- never clip a Rearm/Keen channel
    local mmax = NPC.GetMaxMana(h) or 0
    local deficit = mmax - mana()
    if deficit >= K.ARCANE_MANA then
        local ab = NPC.GetItem(h, "item_arcane_boots", true)
        if ab and Ability.CanBeExecuted(ab) == -1 then
            if cast_no_target(ab) then logline("arcane replenish"); return end
        end
    end
    if State.fsm == "ENGAGE" and deficit >= K.SOUL_RING_MANA
       and (Entity.GetHealth(h) or 0) >= (Entity.GetMaxHealth(h) or 1) * K.SR_HP_FRAC_MIN then
        local sr = NPC.GetItem(h, "item_soul_ring", true)
        if sr and Ability.CanBeExecuted(sr) == -1 then
            if cast_no_target(sr) then logline("soul_ring sacrifice") end
        end
    end
end

local function tick()
    process_verify()
    gold_tick()
    rearm_cancel_check()                 -- E0 (C4): judge BEFORE panic can starve it - the stun+burst gank is exactly when the backoff must arm (the old post-guard call never ran while panic re-armed every tick)
    if handle_panic() then
        if has_fountain_buff() then State.panicUntil = 0 end
        -- only issue keen_home if not already conveying: panic runs every tick, and re-issuing the
        -- Keen channel each tick CANCELS the in-flight teleport (the hero never gets home).
        if not is_channeling() and not has_fountain_buff() then
            if ready(State.keen) then
                keen_home("panic")
            else
                -- E0 (B1): keen down (stun-canceled / on cd) used to mean NO ORDERS AT ALL - a
                -- standing-still death while panic re-armed every tick and fsm_return never ran.
                -- Walk toward the fountain; move_to's dedup absorbs the per-tick re-issue.
                local fp = friendly_fountain_pos()
                local me = origin(State.hero)
                if fp and me then move_to(Vector(fp.x, fp.y, me.z), "panic_walk") end
            end
        end
        return
    end
    if is_channeling() then
        -- v0.1.355: FEED THE MOVE WATCHDOGS, then hold orders. This is the v0.1.259 guard,
        -- relocated from fsm_move where it could NEVER run: this early return sits
        -- ABOVE the FSM dispatch, so fsm_move is not called at all during a channel. And
        -- Map.Nav.Stuck is WALL-CLOCK (t - best_t >= window, Nav.Stuck in lib/map.lua), so it does not care
        -- that nobody called it meanwhile - the first post-channel call charges the entire
        -- channel to "no progress". At Rearm L1 that is REARM_CHANNEL 2.69 + CHANNEL_PAD 0.20
        -- + rearmPending 0.20 = 3.09s, just over NO_PROGRESS_S 3.0, so the watchdog fired
        -- deterministically and mark_spot_cleared retired a LIVE camp (and its pair partner)
        -- until respawn. g354: 5 of 5 no-progress firings in the game were this, none genuine.
        -- Clearing the track re-baselines the next Map.Nav.Stuck call, so a channel costs the
        -- watchdog nothing and it only ever accumulates over time it actually observed - which
        -- is the invariant it always meant to enforce. Covers BOTH no_progress callers (the
        -- camp path and the shove path share State.moveTrack).
        State.moveSince = now(); State.moveTrack = nil
        return
    end
    -- v0.1.121 (note 3, user-requested repeatedly): GLOBAL stuck-breaker. While moving toward a target
    -- (MOVE/RETURN) and FAR from it, if the distance to it has not improved for STUCK_TELEPORT_S he is
    -- blocked -> TELEPORT (keen home; rearm-reset-keen if on cd) to unstick + re-decide. Only when FAR
    -- from the target, so legitimately STANDING at the stand/fountain (waiting for a wave, etc.) never
    -- triggers it. A last-resort backstop over the per-state no_progress / MOVE_TIMEOUT watchdogs.
    -- Glue rebuild item 4: Map.Nav.Stuck (signal upgrade from position-frozen to no-distance-improvement:
    -- orbiting without approaching now counts as stuck, which is correct).
    -- v0.1.194 F1 (run-24): a DELIBERATE wait (tether hold / protected wait / hold-still) is
    -- frozen-far-from-target BY DESIGN - the watchdog read it as stuck and keened him home mid-
    -- tether (STUCK at our T1 d=3287 -> teleport unstick, 2x). waitInfo is stamped fresh every
    -- waiting tick (the HUD uses the same 1s recency), so it is the exact "intentional" signal.
    local deliberate_wait = State.waitInfo and now() - (State.waitInfo.t or 0) < 1.0
    if (State.fsm == "MOVE" or State.fsm == "RETURN") and not has_fountain_buff()
       and not deliberate_wait then
        local p = origin(State.hero)
        local tgt = (State.fsm == "RETURN") and friendly_fountain_pos()
                    or (State.spot and State.spot.standSpot and State.spot.standSpot.stand)
        local dist = tgt and p:Distance(Vector(tgt.x, tgt.y, p.z))
        if dist and dist > K.STUCK_FAR_DIST then
            local stuck
            State.stuckTrack, stuck = Map.Nav.Stuck(State.stuckTrack, dist, now(),
                { eps = K.STUCK_FROZEN_DIST, window = K.STUCK_TELEPORT_S })
            if stuck then
                -- v0.1.362 INSTRUMENT (log-only, no new state: fsm, tgt and State.lastMove all
                -- already exist here). `d=` ALONE forced two load-bearing readings to be INFERRED
                -- rather than read, and TINKER_UNSTICK_LOOP_FINDINGS.md records what that cost: the
                -- MOVE-vs-RETURN split was guessed from the magnitude of d, and the "he arrived
                -- exactly where he was ordered and stopped" mechanism turned out to cover only 4 of
                -- the 8 g366 MOVE-leg firings, which is not visible without the order itself.
                -- osrc NAMES THE PRODUCER that parked him, which is the whole question.
                -- dord = hero to the order target: near 0 means he ARRIVED and stopped, so the
                -- watchdog is right about no-progress and wrong about intent; dord close to d means
                -- he never got there and the block is real. The two want opposite fixes.
                -- TYPE BOUNDARY (bug class 1): tgt may be a plain {x,y}, which is why the dist line
                -- above rebuilds a Vector from its components. Component math only, no :Distance.
                local lm = State.lastMove
                local dox, doy = lm and (p.x - lm.x) or 0, lm and (p.y - lm.y) or 0
                logline(string.format(
                    "STUCK at (%.0f,%.0f) d=%.0f fsm=%s tgt=(%.0f,%.0f) ord=%s osrc=%s oage=%s dord=%s -> teleport unstick",
                    p.x, p.y, dist, tostring(State.fsm), tgt.x, tgt.y,
                    lm and string.format("(%.0f,%.0f)", lm.x, lm.y) or "nil",
                    lm and tostring(lm.src) or "nil",
                    lm and string.format("%.1f", now() - lm.t) or "nil",
                    -- dord at %.1f, NOT %.0f: the whole signal is sub-unit. In g366 the four
                    -- arrived-where-ordered cases sit at 0.3, 0.4, 0.5 and 0.6 units, which %.0f
                    -- renders as 0/0/1/1 and makes indistinguishable from a genuine 1-unit miss.
                    lm and string.format("%.1f", math.sqrt(dox * dox + doy * doy)) or "nil"))
                -- E0 (B3): never channel an unstick next to enemies - a body-blocking enemy got a
                -- free keen cancel (cd+75) then a free rearm cancel (~225), repeatable every 4s.
                -- Blocked-and-threatened just redecides; the escape layers own the enemies.
                if not lane_unsafe(p) then
                    if ready(State.keen) then keen_home("unstick") elseif ready(State.rearm) then try_rearm() end
                end
                State.spot = nil; State.fsm = "DECIDE"; State.nextDecide = 0; State.stuckTrack = nil
            end
        else
            State.stuckTrack = nil                     -- at target / no target: not a stuck candidate
        end
    else
        State.stuckTrack = nil
    end
    bottle_tick()                        -- sustain (only when not channeling, per the guard above)
    mana_items_tick()                    -- mana engine part 3: Arcane/Soul Ring pump the pool before a fountain trip
    if mana() < State.menu.escapeMana:Get() and State.fsm ~= "RETURN" then go_return() end
    if     State.fsm == "DECIDE" then fsm_decide()
    elseif State.fsm == "MOVE"   then fsm_move()
    elseif State.fsm == "ENGAGE" then fsm_engage()
    elseif State.fsm == "RETURN" then fsm_return() end
end

-- ── debug overlay (calibration view) ─────────────────────────────────────────
-- v0.1.324 headroom lift wave 1: the screen-space drawing family (dbg_font/w2s/dbg_text/
-- world_text/world_ring/world_line/world_seg/world_obox) moved to lib/draw.lua as
-- Draw.Font/W2S/Text/WorldText/Ring/Line/Seg/OBox - bodies unchanged, the font cache
-- lives in the module now (DBG.font retired). Net -7 main-chunk locals (the 200 limit).

-- one-press pair-test overlay: green ring = camp pairs (line to partner + yellow cast dot),
-- red ring + reason = camp does not pair. Shows for K.TEST_OVERLAY_SEC after the Test key.
local function draw_pair_test()
    if not State.pairTestResults or now() > (State.pairTestUntil or 0) then return end
    local sz  = Render.ScreenSize()
    local hdr = "PAIR TEST  (green=clean  amber=clip  red=skip)"
    local hw  = Render.TextSize(Draw.Font(), 18, hdr)
    Render.Text(Draw.Font(), 18, hdr, Vec2(sz.x * 0.5 - hw.x * 0.5, sz.y * 0.12), Color(255, 230, 120, 255))
    for _, r in ipairs(State.pairTestResults) do
        if r.paired then
            local clean = (r.clear == "clean")                       -- disc-model clear class -> ring colour
            local ringC = clean and Color(120, 255, 150, 255) or Color(255, 200, 80, 255)
            local lineC = clean and Color(120, 255, 150, 150) or Color(255, 200, 80, 150)
            Draw.Ring(r.center, 120, ringC, 2.2)
            if r.partner then Draw.Line(r.center, r.partner, lineC, 1.6) end
            local cp = r.cast and Draw.W2S(r.cast)
            if cp then Render.FilledCircle(cp, 5, Color(255, 200, 0, 255)) end
            Draw.WorldText(r.center, string.format("%s %d", r.clear or "?", math.floor(r.fullm or 0)), ringC, 8, -10)
        else
            Draw.Ring(r.center, 120, Color(255, 110, 110, 255), 2.0)
            Draw.WorldText(r.center, r.reason or "skip", Color(255, 150, 150, 255), 8, -10)
        end
    end
end

-- LIVE merged-pair debug (toggle "Pair debug"). Runs the ACTUAL new pairing (Farm.GreedyPairs over
-- non-cleared camps) each frame so it works with auto-farm off: MERGED pair = green rings + line +
-- midpoint; a pair whose midpoint is unsafe (would split back to singles) = amber; a camp with no
-- partner in range = red single. The camp NEAREST the hero is ringed WHITE and its verdict is logged
-- (throttled) - walk Tinker to a camp to confirm an unpaired one is genuinely unpairable (its true
-- nearest_neighbor > pair_max) or only split by midpoint risk.
local function draw_pair_debug()
    if not (State.menu.pairDbg and State.menu.pairDbg:Get()) then return end
    State.fog = enemy_snapshot()                       -- live risk for the merged/split test (works with auto-farm off)
    local camps = {}
    for _, cd in ipairs(Map.Camps() or {}) do
        if cd.center and not is_cleared(Map.CampKey(cd.center)) then camps[#camps + 1] = cd end
    end
    local pts = {}
    for i = 1, #camps do pts[i] = { x = camps[i].center.x, y = camps[i].center.y } end
    local pair_max = math.min(K.PAIR_RADIUS, K.MARCH_LEN - 2 * math.abs(K.MARCH_PAIR_OFFSET))
    local allow = function(i, j) return forced_pair(camps[i].center, camps[j].center) end   -- whitelist over-range pairs (overlay reflects the live logic)
    local groups = Farm.GreedyPairs(pts, pair_max, nil, allow)

    local sz  = Render.ScreenSize()
    local hdr = string.format("PAIR DEBUG  green=merged  amber=split(unsafe mid)  red=single  magenta=your marks   pair_max=%d", math.floor(pair_max))
    local hw  = Render.TextSize(Draw.Font(), 18, hdr)
    Render.Text(Draw.Font(), 18, hdr, Vec2(sz.x * 0.5 - hw.x * 0.5, sz.y * 0.12), Color(255, 230, 120, 255))

    local me = origin(State.hero)
    local nearest, nd = nil, math.huge
    for i = 1, #camps do local d = camps[i].center:Distance(me); if d < nd then nd, nearest = d, i end end

    for _, g in ipairs(groups) do
        local A = camps[g.a].center
        if g.b then
            local B = camps[g.b].center
            local mid = Vector((A.x + B.x) / 2, (A.y + B.y) / 2, A.z)
            local merged = enemy_risk_at(mid) < K.RISK_HARD
            local col = merged and Color(120, 255, 150, 255) or Color(255, 200, 80, 255)
            Draw.Ring(A, 110, col, 2.0); Draw.Ring(B, 110, col, 2.0)
            Draw.Line(A, B, col, 1.8); Draw.Ring(mid, 26, col, 2.0)
            Draw.WorldText(mid, string.format("%s d=%.0f", merged and "MERGED" or "split", g.d), col, 8, -10)
        else
            Draw.Ring(A, 110, Color(255, 110, 110, 255), 2.0)
            Draw.WorldText(A, "single", Color(255, 150, 150, 255), 8, -10)
        end
    end

    if not nearest then return end
    Draw.Ring(camps[nearest].center, 150, Color(255, 255, 255, 255), 2.6)   -- the camp you are inspecting
    local c   = camps[nearest].center
    local key = Map.CampKey(c)
    if key == State.pairDbgKey and now() - (State.pairDbgT or 0) < 2.0 then return end   -- throttle: log on approach / every 2s
    State.pairDbgKey, State.pairDbgT = key, now()
    local verdict = "single reason=no_partner_in_range"
    for _, g in ipairs(groups) do
        if g.a == nearest or g.b == nearest then
            if g.b then
                local other = camps[(g.a == nearest) and g.b or g.a].center
                local mid  = Vector((c.x + other.x) / 2, (c.y + other.y) / 2, c.z)
                local risk = enemy_risk_at(mid)
                verdict = string.format("%s pcamp=(%.0f,%.0f) d=%.0f mid_risk=%.2f%s",
                    (risk < K.RISK_HARD) and "PAIRED" or "split_unsafe_mid(risk>=RISK_HARD)", other.x, other.y, g.d, risk,
                    forced_pair(c, other) and " [forced]" or "")
            end
            break
        end
    end
    if verdict:find("no_partner") then                    -- show the TRUE nearest neighbor so you can see it exceeds pair_max
        local nn = math.huge
        for i = 1, #camps do if i ~= nearest then local d = camps[i].center:Distance(c); if d < nn then nn = d end end end
        verdict = string.format("%s nearest_neighbor=%.0f pair_max=%.0f", verdict, (nn < math.huge) and nn or -1, pair_max)
    end
    logline(string.format("pairdbg hero=(%.0f,%.0f) camp=(%.0f,%.0f) tier=%s verdict=%s",
        me.x, me.y, c.x, c.y, tostring(camps[nearest].type), verdict))
end

-- Persistent user "pairable here" markers (the Mark bind). Magenta ring at the marked hero pos + lines to
-- the two nearest camps it recorded, labelled with the index + their inter-distance. Always drawn (even
-- with the Pair-debug toggle off) so marks stay visible; cleared on script reload.
local function draw_pair_marks()
    local marks = State.pairMarks
    if not marks or #marks == 0 then return end
    local col = Color(255, 90, 255, 255)
    for i, m in ipairs(marks) do
        local p = Vector(m.pos.x, m.pos.y, m.pos.z)
        Draw.Ring(p, 60, col, 2.4)
        if m.c1 then Draw.Line(p, m.c1, col, 1.4) end
        if m.c2 then Draw.Line(p, m.c2, col, 1.4) end
        Draw.WorldText(p, string.format("MARK#%d d12=%.0f", i, m.d12 or -1), col, 8, 12)
    end
end

-- one-press wave-scan overlay: per lane, blue ring = enemy wave, green ring = ally wave (count +
-- gold), yellow dot = predicted clash settle (+ drift line when moving), with pushing/eta/reach.
local LANE_SCAN_NAMES = { "top", "mid", "bot" }
local function draw_lane_scan()
    if not State.laneScan or now() > (State.laneScanUntil or 0) then return end
    local sz  = Render.ScreenSize()
    local hdr = "WAVE SCAN  (blue=enemy wave  green=ally wave  orange=MIRRORED est  yellow=clash)"
    local hw  = Render.TextSize(Draw.Font(), 18, hdr)
    Render.Text(Draw.Font(), 18, hdr, Vec2(sz.x * 0.5 - hw.x * 0.5, sz.y * 0.16), Color(255, 230, 120, 255))
    -- Piece 1.5: draw the lane polylines (dim) so the mirrored estimates can be eyeballed ON the lane.
    for _, path in pairs(lane_paths()) do
        for i = 2, #path do
            Draw.Seg(Vector(path[i - 1].x, path[i - 1].y, 0), Vector(path[i].x, path[i].y, 0),
                      Color(150, 150, 170, 90))
        end
    end
    for _, ln in ipairs(LANE_SCAN_NAMES) do
        local s = State.laneScan[ln]
        if s then
            local function wave_ring(w, col)
                if not (w and w.centroid) then return end
                -- a MIRRORED estimate draws ORANGE with its source tag, so estimate-vs-real is visible
                local c = w.estimated and Color(255, 165, 60, 255) or col
                Draw.Ring(Vector(w.centroid.x, w.centroid.y, 0), 130, c, 2.0)
                Draw.WorldText(Vector(w.centroid.x, w.centroid.y, 0),
                    string.format("%s x%d  g%d%s", ln, w.count, math.floor(w.gold or 0),
                        w.estimated and (" ~" .. (w.est_src or "est")) or ""), c, 8, -10)
            end
            wave_ring(s.enemy_wave, Color(120, 190, 255, 255))
            wave_ring(s.ally_wave, Color(120, 255, 150, 255))
            if s.clash and s.clash.contact then
                local cw = Vector(s.clash.settle.x, s.clash.settle.y, 0)
                local crash = s.clash.crashing
                local cp, cvis = Draw.W2S(cw)
                if cvis then Render.FilledCircle(cp, 6, crash and Color(255, 80, 80, 255) or Color(255, 210, 0, 255)) end
                if s.clash.moving then   -- drift arrow contact -> settle
                    Draw.Line(Vector(s.clash.contact.x, s.clash.contact.y, 0), cw, Color(255, 210, 0, 200), 2.0)
                end
                if crash and s.clash.crash_tower then   -- red line to the tower the wave crashes into
                    Draw.Line(cw, Vector(s.clash.crash_tower.pos.x, s.clash.crash_tower.pos.y, 0), Color(255, 80, 80, 220), 2.0)
                end
                local reach = s.intercept and s.intercept.reachable
                Draw.WorldText(cw, string.format("%s%s%s eta=%s %s",
                    s.clash.pushing, s.clash.moving and "" or "/hold", crash and " CRASH" or "",
                    s.intercept and string.format("%.1f", s.intercept.eta) or "-",
                    reach and "OK" or "x"),
                    reach and Color(120, 255, 150, 255) or Color(255, 150, 150, 255), 8, 10)
            end
        end
    end
end

-- one-press route-scan overlay: every candidate as a ring (kind/value/risk, dimmed if
-- contested/risk-vetoed), and the chosen plan as a numbered path 1->2->3 (leg-1 highlighted).
local function draw_route_scan()
    if not State.routeScan or now() > (State.routeScanUntil or 0) then return end
    local sz  = Render.ScreenSize()
    local hdr = "ROUTE SCAN  (cyan=camp  blue=wave  green=plan path; dim=skipped)"
    local hw  = Render.TextSize(Draw.Font(), 18, hdr)
    Render.Text(Draw.Font(), 18, hdr, Vec2(sz.x * 0.5 - hw.x * 0.5, sz.y * 0.20), Color(255, 230, 120, 255))
    for _, t in ipairs(State.routeScan.targets or {}) do
        local skipped = t.contested or (t.risk or 0) >= K.RISK_HARD
        local base = (t.kind == "wave") and Color(120, 190, 255, 255) or Color(120, 230, 230, 255)
        local col  = skipped and Color(150, 150, 150, 160) or base
        Draw.Ring(Vector(t.pos.x, t.pos.y, 0), 120, col, 1.8)
        Draw.WorldText(Vector(t.pos.x, t.pos.y, 0),
            string.format("%s g%.0f r%.2f%s", t.kind, t.value or 0, t.risk or 0, t.contested and " owned" or ""),
            col, 8, -10)
    end
    local steps = State.routeScan.plan and State.routeScan.plan.steps or {}
    local prev = origin(State.hero)
    for i, s in ipairs(steps) do
        local hereW = Vector(s.pos.x, s.pos.y, 0)
        Draw.Line(prev, hereW, Color(120, 255, 150, 220), i == 1 and 3.0 or 2.0)
        Draw.Ring(hereW, 135, Color(120, 255, 150, 255), i == 1 and 3.0 or 1.8)
        Draw.WorldText(hereW, string.format("#%d", i), Color(120, 255, 150, 255), -16, -12)
        prev = hereW
    end
end

local DBG_TIER = { [0] = "small", [1] = "med", [2] = "large", [3] = "ancient" }
local function draw_debug()
    if not State.menu.debug:Get() or not State.hero then return end
    local chosen = State.spot
    for _, c in ipairs(State.cands or {}) do
        local isChosen = chosen and c.camp == chosen.camp
        local col = isChosen and Color(120, 255, 150, 255) or Color(255, 210, 120, 215)
        Draw.Ring(c.center, 110, col, isChosen and 2.4 or 1.3)
        Draw.WorldText(c.center, string.format("%s  ehp %d  g %d  x%d %s",
            DBG_TIER[c.type] or "?", math.floor(c.ehp or 0), math.floor(c.gold or 0),
            camp_stacks(c.gold, c.type), c.source or "est"), col, 8, -10)
    end
    if chosen and chosen.standSpot and chosen.kind ~= "wave" then
        local ss = chosen.standSpot
        local z  = ss.stand.z
        -- THE STAND BOX (green): a THIN RECTANGLE aligned to the camp axis for a pair (tight along, roomy
        -- perpendicular); a disc for a single camp. This is the region Tinker must be inside to cast W well.
        if ss.paired and ss.partner then
            local ux, uy = ss.partner.x - chosen.center.x, ss.partner.y - chosen.center.y
            local ul = math.sqrt(ux * ux + uy * uy); if ul < 1 then ul = 1 end
            Draw.OBox(ss.aim, ux / ul, uy / ul, K.BOX_ALONG, K.BOX_PERP, Color(60, 230, 120, 235))
        else
            Draw.Ring(ss.aim, K.ENGAGE_COVER_DIST, Color(60, 230, 120, 235), 2.6)
        end
        Draw.WorldText(ss.aim, "STAND BOX", Color(60, 230, 120, 255), 8, -8)
        -- ACTUAL W coverage: the 1800x1800 square is CENTRED ON THE REAL CAST POINT (clamped 280 ahead of
        -- the hero), NOT on the camp - so you can SEE whether a camp ends up at the square's far edge (a
        -- miss). One square per cast (multi-W: near + far). Yellow dot = the real cast point.
        local hpos = origin(State.hero)
        for idx = 0, 1 do
            local cp = march_cast_point_multi(chosen, idx)
            local dx, dy = cp.x - hpos.x, cp.y - hpos.y                       -- the W sweeps along hero->cast
            local dl = math.sqrt(dx * dx + dy * dy); if dl < 1 then dl = 1 end
            Draw.OBox(cp, dx / dl, dy / dl, K.MARCH_LEN * 0.5, K.MARCH_HALFWIDTH, Color(120, 200, 255, 150))
            local sp = Draw.W2S(cp); if sp then Render.FilledCircle(sp, 4, Color(255, 200, 0, 255)) end
        end
        -- camp markers (orange): the targets the W must actually cover
        local ca = Draw.W2S(chosen.center); if ca then Render.FilledCircle(ca, 6, Color(255, 140, 60, 255)) end
        if ss.paired and ss.partner then
            local cb = Draw.W2S(Vector(ss.partner.x, ss.partner.y, z)); if cb then Render.FilledCircle(cb, 6, Color(255, 140, 60, 255)) end
        end
        local st = Draw.W2S(ss.stand); if st then Render.FilledCircle(st, 6, Color(60, 230, 60, 255)) end
    end
    local hs, vis = Draw.W2S(origin(State.hero))
    if vis then
        local txt = string.format("%s | mana %d/%d (esc %d)%s",
            State.fsm, math.floor(mana()), math.floor(NPC.GetMaxMana(State.hero) or 0),
            State.menu.escapeMana:Get(), is_channeling() and " [CHANNEL]" or "")
        Draw.Text(Vec2(hs.x + 12, hs.y - 26), txt, Color(255, 255, 255, 255))
    end
end

-- ── status text: on-screen indicator while auto farm is ON ───────────────────
local function draw_status()
    if not State.menu.enable:IsToggled() or not State.hero or not Engine.IsInGame() then return end
    local ss   = Render.ScreenSize()
    -- v0.1.163 (user): a deliberate WAIT must READ as a wait, not as MOVE. State.waitInfo is set by
    -- the hold paths (wave hold / protected wait / suppression idle) and IGNORED when stale (>1s recency; nothing ever clears it).
    local st = State.fsm
    if State.waitInfo and now() - (State.waitInfo.t or 0) < 1.0 then
        st = "WAIT " .. State.waitInfo.why
    end
    local txt  = string.format("TINKER FARM: ON  [%s]", st)
    local ts   = Render.TextSize(Draw.Font(), 18, txt)
    local x, y = ss.x * 0.5 - ts.x * 0.5, ss.y * 0.085
    Render.FilledRect(Vec2(x - 10, y - 5), Vec2(x + ts.x + 10, y + ts.y + 5), Color(0, 0, 0, 150), 6)
    Render.Text(Draw.Font(), 18, txt, Vec2(x, y), Color(120, 255, 150, 255))
end

-- ── camp-population diagnostic (answers "do camps populate?" via debug.log) ────
local dbgScanAt = 0
local function debug_camp_scan()
    local t = now()
    if t < dbgScanAt + 2.0 then return end
    dbgScanAt = t
    local all = Map.Camps()
    local neutrals = Map.AllNeutrals()
    local occ, first = 0, nil
    for _, cd in ipairs(all) do
        if #Map.CampCreeps(cd.camp, neutrals) > 0 then occ = occ + 1 end
        if not first and cd.center then first = cd end
    end
    local detail = ""
    if first then
        detail = string.format(" first=(%.0f,%.0f) type=%s",
            first.center.x, first.center.y, tostring(first.type))
    end
    logline(string.format("camp_scan camps=%d occupied=%d%s", #all, occ, detail))
    -- observed-farmer camp clearing (v0.1.332): any live, currently-visible hero except us
    -- dwelling at a camp marks it cleared until the next xx:00 (the planner/pairing already
    -- skip is_cleared camps; the mark self-heals at the respawn like our own clears).
    -- Dormant heroes are skipped: a stale last-seen position must never mark a camp.
    local hpts, cands = {}, {}
    for _, e in ipairs(Heroes.GetAll() or {}) do
        if e ~= State.hero and Entity.IsAlive(e) and not Entity.IsDormant(e) then
            local p = origin(e)
            if p then hpts[#hpts + 1] = { x = p.x, y = p.y, e = e } end   -- v0.1.336: entity rides along for farmer attribution (the lib reads only x/y)
        end
    end
    if #hpts > 0 then
        for _, cd in ipairs(all) do
            if cd.center then
                local key = Map.CampKey(cd.center)
                if not is_cleared(key) then
                    cands[#cands + 1] = { key = key, cx = cd.center.x, cy = cd.center.y }
                end
            end
        end
        for _, key in ipairs(Farm.ObservedFarmers(hpts, cands, State.campDwell,
                { radius = K.HERO_FARM_R, window = K.FARMER_DWELL_S,
                  min_dwell = K.FARMER_DWELL_MIN_S, now = t })) do
            mark_cleared(key)
            logline("camp_farmer_seen key=" .. key .. " -> cleared")
            -- v0.1.336 observed-farmer = core (TINKER_FARMER_CORE_DESIGN.md): attribute the
            -- confirm to the ALLIED heroes at this camp; at FARMER_CORE_MARKS total confirms
            -- the ally is contest-worthy for the game (ally_farm_priorities ORs the flag in).
            -- Team-filtered here: enemies mark camps (the .332 sensor is hero-agnostic) but
            -- never gain the flag. Hero unitnames are match-stable keys; entities are not.
            for _, cnd in ipairs(cands) do
                if cnd.key == key then
                    local r2 = K.HERO_FARM_R * K.HERO_FARM_R
                    for _, h in ipairs(hpts) do
                        if h.e and Entity.GetTeamNum(h.e) == State.team
                           and (not NPC.IsIllusion or not NPC.IsIllusion(h.e)) then   -- illusions share the owner name+team (lib/lane.lua idiom); evidence must come from the real hero
                            local dx, dy = h.x - cnd.cx, h.y - cnd.cy
                            if dx * dx + dy * dy <= r2 then
                                local nm = (NPC.GetUnitName and NPC.GetUnitName(h.e)) or "?"
                                local nmk = (State.allyFarmers[nm] or 0) + 1
                                State.allyFarmers[nm] = nmk
                                if nmk == K.FARMER_CORE_MARKS then
                                    logline("ally_farmer name=" .. nm .. " marks=" .. nmk)
                                end
                            end
                        end
                    end
                    break
                end
            end
        end
    end
end

-- ── one-shot position dump (build the static fallback table from debug.log) ────
local function dump_uname(e)
    local ok, n = pcall(function() return Entity.GetUnitName and Entity.GetUnitName(e) end)
    if ok and type(n) == "string" then return n end
    local ok2, n2 = pcall(function() return NPC.GetUnitName and NPC.GetUnitName(e) end)
    if ok2 and type(n2) == "string" then return n2 end
    return "?"
end
local function dump_positions()
    local camps = Map.Camps()
    logline("=== DUMP BEGIN camps=" .. #camps .. " ===")
    for i, cd in ipairs(camps) do
        local c = cd.center
        local mnx, mny, mxx, mxy = 0, 0, 0, 0
        if cd.box and cd.box.min and cd.box.max then
            mnx, mny, mxx, mxy = cd.box.min.x, cd.box.min.y, cd.box.max.x, cd.box.max.y
        end
        logline(string.format("camp i=%d type=%s center=(%.0f,%.0f,%.0f) box=(%.0f,%.0f)..(%.0f,%.0f)",
            i, tostring(cd.type), c and c.x or 0, c and c.y or 0, c and c.z or 0, mnx, mny, mxx, mxy))
    end
    local structs = NPCs.GetAll(Enum.UnitTypeFlags.TYPE_STRUCTURE) or {}
    logline("=== DUMP structures=" .. #structs .. " ===")
    for i, e in ipairs(structs) do
        local p = Entity.GetAbsOrigin(e)
        logline(string.format("struct i=%d team=%s name=%s pos=(%.0f,%.0f,%.0f)",
            i, tostring(Entity.GetTeamNum(e)), dump_uname(e),
            p and p.x or 0, p and p.y or 0, p and p.z or 0))
    end
    logline("=== DUMP END ===")
end

-- v0.1.113 (temporary, diagnostic-only): validate the wave-meeting MATH vs REALITY. Logs one per-lane ally
-- creep's ENGINE move/base speed (NPC.GetMoveSpeed / GetBaseSpeed - gitbook-confirmed for any unit incl.
-- lane creeps) + the MEASURED centroid velocity (delta-pos / delta-t) + the role-paired enemy centroid and their midpoint C.
-- Expectation while the wave MARCHES freely (before it meets the enemy): measured ~ api ~ base ~ 325 and
-- C holds constant -> confirms 325 + the spawn->meeting timing. Once confirmed, the model uses
-- the ENGINE base speed (not a hardcoded 325). Run with all-vision + Debug on from early game.
local function sample_creep_speed()
    if now() < (State.nextSpeedSample or 0) then return end
    State.nextSpeedSample = now() + 0.5
    -- LANE-AGNOSTIC: bucket every lane creep by lib/lane's classifier, per team. Logs our/enemy
    -- centroid + C=midpoint + the engine speed PER LANE, so the mirror (C constant) and the speed
    -- (incl. top/bot's first-15-wave +30%/-35% split) are validated on all three lanes the same way.
    local L = { top = {}, mid = {}, bot = {} }
    for _, ln in pairs(L) do ln.ox, ln.oy, ln.on, ln.ex, ln.ey, ln.en = 0, 0, 0, 0, 0, 0 end
    for _, c in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
        if Entity.IsAlive(c) and not Entity.IsDormant(c) then
            local p = Entity.GetAbsOrigin(c)
            if p then
                local ln = L[Lane._assign_lane({ x = p.x, y = p.y })]            -- same lane classifier as lib/lane
                if Entity.GetTeamNum(c) == State.team then
                    ln.ox, ln.oy, ln.on = ln.ox + p.x, ln.oy + p.y, ln.on + 1
                    if not ln.base then                                          -- one our-creep's engine speed per lane (catches the side-lane modifiers)
                        local ok, v = pcall(function() return NPC.GetMoveSpeed and NPC.GetMoveSpeed(c) end); if ok and type(v) == "number" then ln.api = v end
                        local ok2, b = pcall(function() return NPC.GetBaseSpeed and NPC.GetBaseSpeed(c) end); if ok2 and type(b) == "number" then ln.base = b end
                    end
                else
                    ln.ex, ln.ey, ln.en = ln.ex + p.x, ln.ey + p.y, ln.en + 1
                end
            end
        end
    end
    -- ROLE-MIRROR pairing (team-aware): a wave mirrors the enemy wave of the SAME ROLE, which sits on
    -- the OPPOSITE side of the map. Radiant safe=bot/off=top; Dire safe=top/off=bot. So mid<->mid,
    -- our safe<->enemy safe (opposite lane), our off<->enemy off. C=midpoint(our, role-paired enemy)
    -- should be the per-role symmetry center if the mirror holds (enemy wave = reflect(our role wave)).
    local rad = (State.team == 2)
    local roles = {
        { role = "mid",  ours = "mid",                  theirs = "mid" },
        { role = "safe", ours = rad and "bot" or "top", theirs = rad and "top" or "bot" },
        { role = "off",  ours = rad and "top" or "bot", theirs = rad and "bot" or "top" },
    }
    State.lastSpd = State.lastSpd or {}
    for _, r in ipairs(roles) do
        local o, e = L[r.ours], L[r.theirs]
        if o.on > 0 then
            local ocx, ocy = o.ox / o.on, o.oy / o.on
            local measured, last = nil, State.lastSpd[r.role]
            if last then local dt = now() - last.t; if dt > 0 then measured = math.sqrt((ocx - last.x) ^ 2 + (ocy - last.y) ^ 2) / dt end end
            State.lastSpd[r.role] = { x = ocx, y = ocy, t = now() }
            local line = string.format("creepspd t=%.1f role=%s ourlane=%s on=%d our=(%.0f,%.0f) api=%s base=%s measured=%s",
                now(), r.role, r.ours, o.on, ocx, ocy, o.api and string.format("%.0f", o.api) or "nil",
                o.base and string.format("%.0f", o.base) or "nil", measured and string.format("%.0f", measured) or "nil")
            if e.en > 0 then
                local ecx, ecy = e.ex / e.en, e.ey / e.en
                line = line .. string.format(" enlane=%s en=%d enemy=(%.0f,%.0f) C=(%.0f,%.0f)", r.theirs, e.en, ecx, ecy, (ocx + ecx) / 2, (ocy + ecy) / 2)
            end
            logline(line)
        else
            State.lastSpd[r.role] = nil
        end
    end
end


------------------------------------------------------------------ menu ------
local function setup_menu()
    local m = {}
    -- Menu.Find-then-Create so a script reload reuses the existing tabs instead
    -- of erroring on a duplicate Create.
    local function group(name)
        return Menu.Find("Heroes", "Hero List", "Tinker", "Brain", name)
            or Menu.Create("Heroes", "Hero List", "Tinker", "Brain", name)
    end
    local gFarm = group("Farm")
    local gDef  = group("Defense")
    local gDiag = group("Diagnostics")

    m.enable     = gFarm:Bind("Auto farm", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f11c}")
    m.kindJungle = gFarm:Switch("Farm jungle camps", true, "\u{f1bb}")
    m.kindLane   = gFarm:Switch("Farm lane (shove)", true, "\u{f0e7}")   -- OFF = never shove/farm the lane, jungle only
    -- ("Prioritize high-value camps" was deleted, glue review F3d: the switch was read nowhere -
    -- value priority lives in the planner objective.)
    m.mSmall     = gFarm:Slider("Marches: small", 1, 5, K.MARCHES[0], "%d")
    m.mMedium    = gFarm:Slider("Marches: medium", 1, 5, K.MARCHES[1], "%d")
    m.mLarge     = gFarm:Slider("Marches: large", 1, 5, K.MARCHES[2], "%d")
    m.mAncient   = gFarm:Slider("Marches: ancient", 1, 5, K.MARCHES[3], "%d")
    m.waveMaxW   = gFarm:Slider("Marches: lane wave (max W)", 1, 2, K.WAVE_MAX_W, "%d")   -- cap on W casts per lane-wave clear (v0.1.190 user hard rule: 2 absolute - the 3rd W killed nothing; code clamps too)
    m.escapeMana = gFarm:Slider("Escape mana reserve", 0, 400, K.ESCAPE_MANA, "%d")
    m.blinkEscape= gFarm:Switch("Use Blink: escape", true, "\u{f0e7}")   -- proactive flee blink (no-op without a dagger)
    m.blinkTravel= gFarm:Switch("Use Blink: travel", true, "\u{f124}")   -- blink to close farm-stand gaps when safe
    m.stackLarge = gFarm:Switch("Stack large camps", true)   -- v0.1.224: timed ~:54 aggro on route-near LARGE camps (2x cap; waves always win the window)
    m.sideLanes  = gFarm:Switch("Side-lane waves", true)   -- ALL-LANES v0.1.227 phase 1: top/bot waves fill the slack (mid > side > jungle); the swave trace names every snub

    m.defenseOn  = gDef:Switch("Defense (saves)", true, "\u{f132}")   -- ARC E2: item-save dispatcher master switch (read by defense_dispatcher's defense_enabled and the OnModifierCreate gate)

    m.diag       = gDiag:Slider("Verbosity (0=err 1=key 2=info 3=trace)", 0, 3, 1, "%d")
    m.debug      = gDiag:Switch("Debug overlay", true, "\u{f108}")   -- default ON during calibration: draws the STAND BOX + W coverage squares
    m.timeCap    = gDiag:Switch("Timing capture (log)", false, "\u{f017}")   -- measure REAL keen/rearm channel + cd + mana + fountain regen for the rebuild; default OFF
    -- ("Lane anticipation (A/B)" Switch RETIRED at v0.1.177: the T0 collapse - ON was the only
    -- tested path since the glue rebuild; the OFF branches are deleted from the code.)
    m.pairDbg    = gDiag:Switch("Pair debug (merged, live)", false, "\u{f0e8}")   -- live merged-pair overlay (new GreedyPairs logic) + logs the camp nearest the hero; walk Tinker to a camp to verify its pairing verdict
    m.markPair   = gDiag:Bind("Mark pairable here (key)", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f05b}")   -- press where a pair IS farmable but flagged single: logs hero pos + 2 nearest camps + drops a magenta marker
    m.testPairs  = gDiag:Bind("Test all pairs (overlay+log)", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f0c3}")
    m.scanLanes  = gDiag:Bind("Wave scan (overlay+log)", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f041}")
    m.scanRoute  = gDiag:Bind("Route scan (overlay+log)", Enum.ButtonCode.BUTTON_CODE_NONE, "\u{f018}")

    State.menu = m
    return m
end

-- TIMING CAPTURE (diagnostic, default OFF). Measures the REAL per-cast channel/cooldown/mana on this
-- patch + the fountain regen rate, so the rebuild's timing math uses ground truth instead of the flaky
-- web-summarized values. Run ~6 cast cycles (keen + rearm) + sit in the fountain, then read the
-- `timecap` + `fountregen` log lines (median the ~6 samples). Pure observation; no farm behaviour change.
local function tcap_sample()
    if not State.tcapArmed then State.tcapArmed = true; tlog(1, "timecap", { ARMED = "cast Keen/Rearm (manual or bot); sit in fountain not-full for regen" }) end
    local me = origin(State.hero)
    -- CHANNEL-transition detector: cooldown-INDEPENDENT (works in a no-cooldown demo AND for manual casts).
    -- Keen + Rearm are channeled; measure each channel (false -> true -> false) directly. Identify the
    -- ability by EFFECT: Keen teleports (a big position jump at channel end), Rearm does not.
    local chan = NPC.IsChannellingAbility and NPC.IsChannellingAbility(State.hero) == true
    local st = State.tcapChan
    if chan and not (st and st.active) then
        State.tcapChan = { active = true, t0 = now(), last = now(), p0 = { x = me.x, y = me.y } }
    elseif chan and st and st.active then
        st.last = now()
    elseif (not chan) and st and st.active then
        local dur   = (st.last or now()) - st.t0
        local moved = math.sqrt((me.x - st.p0.x) ^ 2 + (me.y - st.p0.y) ^ 2)
        local name  = (moved > 400) and "keen" or "rearm"          -- Keen teleports; Rearm channels in place
        local ab    = (name == "keen") and State.keen or State.rearm
        tlog(1, "timecap", { ab = name,
            lvl   = (ab and Ability.GetLevel and Ability.GetLevel(ab)) or 0,
            chan  = string.format("%.2f", dur),
            mana  = string.format("%.0f", (ab and Ability.GetManaCost and Ability.GetManaCost(ab)) or 0),
            moved = string.format("%.0f", moved) })
        st.active = false
    end
    -- fountain regen rate (per second + % of max) while inside the fountain aura (radius 1200).
    local fp = friendly_fountain_pos()
    if fp then
        local me = origin(State.hero)
        local dx, dy = me.x - fp.x, me.y - fp.y
        if dx * dx + dy * dy < 1200 * 1200 then
            local mn, hn = mana(), Entity.GetHealth(State.hero) or 0
            local s = State.fountSamp
            if s and (now() - s.t) >= 1.0 then
                local dt = now() - s.t
                local dm, dh = mn - s.m, hn - s.h
                if dm > 0 or dh > 0 then
                    local maxm = (NPC.GetMaxMana and NPC.GetMaxMana(State.hero)) or 1
                    local maxh = (Entity.GetMaxHealth and Entity.GetMaxHealth(State.hero)) or 1
                    tlog(1, "fountregen", {
                        dmana_s = string.format("%.0f", dm / dt), dhp_s = string.format("%.0f", dh / dt),
                        pct_m = string.format("%.2f", 100 * dm / maxm / dt),
                        pct_h = string.format("%.2f", 100 * dh / maxh / dt),
                        maxm = string.format("%.0f", maxm), maxh = string.format("%.0f", maxh) })
                end
                State.fountSamp = { t = now(), m = mn, h = hn }
            elseif not s then
                State.fountSamp = { t = now(), m = mn, h = hn }
            end
        else
            State.fountSamp = nil
        end
    end
end

--------------------------------------------------------------- callbacks ----
local callbacks = {}

function callbacks.OnUpdateEx()
    State.frame_t = now()   -- skeleton universal per-frame sample. UNREAD BY TINKER, whose tick
                            -- functions call now() directly; retained for skeleton conformance and
                            -- for the deferred GetGameTime to GlobalVars.GetCurTime clock rewire.
    if not Engine.IsInGame() then return end
    if not State.hero then
        local h = Heroes.GetLocal()
        if h then
            State.hero = h
            State.player = Players.GetLocal()
            State.team = Entity.GetTeamNum(h)
            tlog(1, "self_acquired", { team = State.team })
        end
    end
    if not State.hero then return end
    if not (State.march and State.rearm and State.keen and State.laser) then
        refresh_handles(State.hero)   -- bind ability handles only until all present (stable after)
    end
    -- v0.1.347 WAIT-EPISODE INSTRUMENTATION (log-only). State.waitInfo already carries the CAUSE of
    -- every deliberate wait (13 producers) but was read only by the HUD and the stuck-teleport gate - never logged - so the
    -- user's watched "tons of useless waiting" was unmeasurable: g348 showed wait+idle+tether+post =
    -- 196s of 761s (25.7%) yet only FIVE holds >10s, i.e. the waiting is MANY SHORT episodes that the
    -- >10s view cannot see. Close an episode when its cause changes or the wait ends, and log the
    -- duration. Runs in the tick, NOT in draw_status (the HUD path must never log). The cause is
    -- normalised to its leading words so a counting-down "tether 12s"/"tether 11s" stays ONE episode.
    do
        local wi = State.waitInfo
        local waiting = (wi and (now() - (wi.t or 0) < 1.0)) and true or false
        local why
        if waiting then
            local raw = wi.why or "?"
            why = raw:match("^[%a_ ]+") or raw     -- "tether 12s" -> "tether " (a countdown is ONE episode)
            why = why:gsub("%s+$", "")
        end
        local ep = State.waitEp
        if ep and (not waiting or ep.why ~= why) then
            logline(string.format("wait_end why=%s dur=%.1f", ep.why, now() - ep.t0))
            State.waitEp, ep = nil, nil
        end
        if waiting and not ep then State.waitEp = { why = why, t0 = now() } end
    end
    if State.menu.timeCap:Get() then tcap_sample() end                       -- timing-capture diagnostic (default off; no creepspd spam)
    debug_camp_scan()                                                        -- occupancy scan at level 1 (throttled 2s); no Debug toggle needed
    if State.menu.debug:Get() then
        if not State.dumped then dump_positions(); State.dumped = true end   -- full structure dump (needs the Debug switch)
        sample_creep_speed()                                                 -- v0.1.113: validate creep speed/distance/timing vs the math
    end
    if State.menu.testPairs:IsToggled() then                                 -- one-press "test all pairs" (works whether or not auto-farm is on)
        if not State.testKeyDown then State.testKeyDown = true; run_pair_test() end
    else
        State.testKeyDown = false
    end
    if State.menu.markPair:IsToggled() then                                  -- one-press "mark pairable here" (log the hero pos + 2 nearest camps; drop a marker)
        if not State.markKeyDown then State.markKeyDown = true; mark_pairable() end
    else
        State.markKeyDown = false
    end
    if now() >= (State.nextAutoScan or 0) then                               -- v0.1.92: automatic all-lanes wavescan LOG (no overlay; whether or not auto-farm is on)
        State.nextAutoScan = now() + K.AUTO_WAVESCAN_S
        run_lane_scan(false)
    end
    if State.menu.scanLanes:IsToggled() then                                 -- the bind now just ARMS the visual overlay (the log is automatic above)
        if not State.scanKeyDown then State.scanKeyDown = true; run_lane_scan(true) end
    else
        State.scanKeyDown = false
    end
    if State.menu.scanRoute:IsToggled() then                                 -- one-press "route scan" (planner diagnostic; no farm behaviour)
        if not State.routeKeyDown then State.routeKeyDown = true; run_route_scan() end
    else
        State.routeKeyDown = false
    end
    -- v0.1.356 DEATH LOG (log-only). NOTHING in this log recorded the single most important
    -- event in a game. There is no death string at all, so every analyzer reported a death as
    -- STILLNESS (g356's 54.6s death read as `camp hold=51.0s reason=unsafe` in --time-report)
    -- and three sessions of "0 deaths" were greps for a token that never appears whatever
    -- happens. The alive check below has always been here; it simply never said anything.
    -- The only reliable prior signature was "the scan loop keeps ticking while ExecuteOrder
    -- stops for 45-55s", which no report looked for.
    -- The save census is the load-bearing field: `save_chain_skip reason=not_ready` conflated
    -- NOT OWNED with ON COOLDOWN, so a death looked like a total save failure when Tinker
    -- simply owns one escape. Only items actually in the inventory are listed, each :up or
    -- :cd - so "force_staff:cd" and "no saves owned" become distinguishable at a glance.
    -- DETECTION SITS ABOVE THE ENABLE GATE ON PURPOSE. The first draft put it below, so a death
    -- during a MANUAL TAKEOVER (autofarm toggled OFF) logged nothing - and a takeover is exactly
    -- when a human gets caught out. Worse, that death would then reappear as an unexplained
    -- 45-55s order gap and get misread as a BRAIN death. The control flow below is untouched:
    -- only the observation moved, so an autofarm-OFF tick still returns at the enable gate.
    local alive = Entity.IsAlive(State.hero)
    if State.wasAlive == nil then State.wasAlive = alive end
    if alive ~= State.wasAlive then
        State.wasAlive = alive
        if not alive then
            State.deathT = now()
            local saves = {}
            local okp, p = pcall(origin, State.hero)   -- a dead hero's origin can throw
            -- v0.1.406: ready() is Ability.CanBeExecuted, and on a DEAD hero it has NEVER RUN in
            -- production: all 7 DEATH lines in the 44-log corpus read NONE_OWNED, so the loop
            -- below always found nil and never reached the readiness call. NPC.GetItem IS proven
            -- safe there (about 70 dead-hero calls, all returning nil, no throw), but the origin
            -- guard on the line above exists precisely because SOME dead-hero reads throw. So the
            -- readiness read is pcall-guarded and prints `:?` when the call itself fails, which is
            -- honest rather than fabricating `:cd`. A throw here would kill the whole OnUpdate
            -- tick on the one event the instrument exists to record.
            local function up_or_cd(ab)
                local okr, r = pcall(ready, ab)
                if not okr then return ":?" end
                return r and ":up" or ":cd"
            end
            for _, n in ipairs(DEFAULT_SAVE_CHAIN) do
                local it = NPC.GetItem(State.hero, n, true)
                if it then saves[#saves + 1] = n:gsub("^item_", "") .. up_or_cd(it) end
            end
            -- v0.1.406: the dagger is censused SEPARATELY and on purpose. DEFAULT_SAVE_CHAIN is the
            -- DISPATCHER's list and correctly contains no item_blink (the dispatcher must not treat
            -- a travel/escape dagger as a chain save), but Tinker's ENTIRE escape doctrine IS the
            -- dagger. So a hero who died holding only a blink logged saves=NONE_OWNED, which is
            -- exactly the "he had nothing" misreading the v0.1.356 instrument was built to abolish,
            -- and it corrupts the evidence base of every deaths question. Observation only: nothing
            -- dispatches off this. DO NOT "simplify" it by adding item_blink to DEFAULT_SAVE_CHAIN,
            -- that list is walked by the save dispatcher and would be a behaviour change.
            local okb, bl = pcall(blink_item)
            if okb and bl then saves[#saves + 1] = "blink" .. up_or_cd(bl) end
            logline(string.format("DEATH t=%.1f fsm=%s spot=%s mana=%.0f pos=%s saves=%s",
                now(), tostring(State.fsm), tostring(State.spot and State.spot.kind), mana(),
                (okp and p) and string.format("(%.0f,%.0f)", p.x, p.y) or "?",
                (#saves > 0) and table.concat(saves, ",") or "NONE_OWNED"))
        else
            logline(string.format("RESPAWN t=%.1f down=%.1fs", now(), now() - (State.deathT or now())))
        end
    end
    -- v0.1.335: edge-triggered enable trace - a manual-takeover window (toggle OFF) silently
    -- parks the fsm while scans keep logging, which reads as a ghost statue in the offline
    -- analyzers (the g335 t=238 hunt: 47s attributed to a commit the gate had destroyed).
    -- Two lines per manual episode make every takeover self-documenting.
    local en = State.menu.enable:IsToggled() and true or false
    if State.lastEnableState ~= en then
        State.lastEnableState = en
        logline(string.format("autofarm %s fsm=%s spot=%s", en and "ON" or "OFF",
            tostring(State.fsm), tostring(State.spot and State.spot.kind)))
    end
    if not en then                                                          -- on (re)enable, start by refilling
        State.fsm = "RETURN"; State.spot = nil; return
    end
    if not alive then State.fsm = "RETURN"; State.spot = nil; return end
    tick()
end

-- ARC E2: threat events. The modifier_tinker_ name guard is a PERF early-out
-- for our own high-frequency self-mods (no Tinker modifier is in
-- THREATS_ON_SELF, and the caster==hero guard below already covers
-- self-casts); known blind spot: an enemy Tinker's modifiers (mirror matchup)
-- skip harvest. Recognized on SELF -> dispatcher; recognized on OTHERS ->
-- readiness stamp only; unrecognized ENEMY-HERO on SELF -> harvest log (the
-- E3 case file). Toggle OFF or no hero = fully inert.
function callbacks.OnModifierCreate(npc, modifier)
    if not State.hero or not modifier then return end
    if not (State.menu and State.menu.defenseOn and State.menu.defenseOn:Get()) then return end
    local mod_name = Modifier.GetName(modifier)
    if not mod_name then return end
    if mod_name:find("modifier_tinker_", 1, true) == 1 then return end   -- perf early-out (see above)
    local canon = (ThreatData.CanonicalMod and ThreatData.CanonicalMod(mod_name)) or mod_name
    local entry = ThreatData.THREATS_ON_SELF[canon] or E2.EXTRA_THREATS[canon]   -- E3b: hero-local extras
    local is_self = (npc == State.hero)
    if not entry and not is_self then return end
    -- GetCaster deferred to here: one engine call saved on the common
    -- irrelevant-modifier path; the self-cast guard still precedes ANY use.
    local caster = Modifier.GetCaster(modifier)
    if caster == State.hero then return end                              -- self-cast guard
    if entry then
        E2.stamp_enemy_cast(canon, caster)                               -- observed cast anywhere visible
        if is_self then
            if not entry.extra then                                      -- E3b: extras skip the dispatcher (no shared-catalog chain to resolve)
                defense_dispatcher:TrySaveSelf("threat_on_self", canon, caster,
                                               nil, E2.THREAT_TO_ABILITY[canon], E2.on_save_fired)
            end
            if E2.FLEE_ROLES[entry.role] then E2.defense_flee(canon, caster) end   -- reaction not conditional on owning a save
        end
    else   -- (not entry) and is_self, by the early-return above
        -- harvest: uncatalogued ENEMY-HERO threat landed on us -> the E3 case
        -- file. The filter (Lina's validated harvest shape, Lina.lua:13471)
        -- keeps ally buffs / neutral auras / rune mods out of the log;
        -- accepted tradeoff: fogged/nil-caster threats go unharvested.
        local okh, eh = pcall(function()
            return caster and Entity.IsEntity(caster) and Target.IsEnemyHero(caster, State.hero)
        end)
        if not (okh and eh) then return end
        State.harvestLogT = State.harvestLogT or {}
        if now() - (State.harvestLogT[mod_name] or -10) > 2 then
            State.harvestLogT[mod_name] = now()
            tlog(1, "threat_unrecognized", { mod = mod_name, caster = def_uname(caster) })
        end
    end
end

function callbacks.OnDraw()
    draw_status()
    draw_debug()
    draw_pair_test()
    draw_pair_debug()
    draw_pair_marks()
    draw_lane_scan()
    draw_route_scan()
end

----------------------------------------------------------------- wiring -----
setup_menu()

-- Hero gate: UCZone loads every scripts/*.lua for every match regardless of the
-- picked hero. Wrap every callback so it no-ops on non-Tinker heroes.
State.is_our_hero = function()
    local h = Heroes.GetLocal()
    if not h or not Entity.IsEntity(h) or not Entity.IsNPC(h) then return false end
    return NPC.GetUnitName(h) == "npc_dota_hero_" .. HERO_KEY
end
-- v0.1.354: the shared last-seen tracker (Escape.Vision since the v0.1.399 phase-3 merge).
-- Wired BEFORE the hero gate below on purpose, so its OnSetDormant handler is gated exactly
-- like every other callback and only tracks while we are actually playing Tinker. That also
-- prevents double-counting when another hero brain (Lina/Sniper) is loaded in the same Lua
-- state: the tracker state is a store shared by every lib.escape instance, so
-- both scripts share one tracker, and gating means only the active hero's handler stamps.
Escape.Vision.Init()
Escape.Vision.Wire(callbacks)

for cb_name, cb_fn in pairs(callbacks) do
    callbacks[cb_name] = function(...)
        if not State.is_our_hero() then return end
        return cb_fn(...)
    end
end

if LOG then LOG:info('Tinker brain v0.1.412 (FOG BLAST-RADIUS CAPS, a regression fix of the v0.1.410 flip found by the g405 hunt. The flip made fog ages real, which armed two dormant consumers that had only ever seen age zero: the channel-threat disabler gate added an UNCAPPED probable-radius disc of up to 16500 units, so a Bane fogged over 40 seconds vetoed every keen cast site from across the map and forced 8000-unit walks, and the nearest-enemy-edge shrink zeroed the commit-risk payload measurement on most commits. Both now apply the risk kernel rule: a ghost staler than the fog age cap stops pricing, the fresh-fog disc stays, visible threats unchanged. The raid readiness gate from the previous build remains deployed and is still UNEXERCISED because that game never reached Keen level two; its validation carries forward. REVERT on a channel broken by a disabler that was fogged just outside the cap, or on any return of the map-wide keen veto.)') end

return callbacks
