---@meta
---lib/map.lua - live map/location layer over the UCZone API v2.0. Hero-agnostic.
---
---Engine-touching: the public queries are thin wrappers over Camps/Camp/Towers/
---Trees/GridNav/World/NPCs/Entity (see Tinker/TINKER_API_STUDY.md). The pure
---geometry helpers (_center_of_box / _in_box_xy / _filter_in_box) are split out
---and exported so they are offline-testable; the wrappers are verified in-game
---via the debug overlay. NOTHING here calls the engine at load time.

local Map = {}

---pure: center of an AABB box { min = Vector, max = Vector }.
---@return userdata|nil
local function _center_of_box(box)
    if not (box and box.min and box.max) then return nil end
    return Vector((box.min.x + box.max.x) * 0.5,
                  (box.min.y + box.max.y) * 0.5,
                  ((box.min.z or 0) + (box.max.z or 0)) * 0.5)
end

---pure: is pos inside the AABB box on the xy plane?
local function _in_box_xy(pos, box)
    if not (pos and box and box.min and box.max) then return false end
    return pos.x >= box.min.x and pos.x <= box.max.x
       and pos.y >= box.min.y and pos.y <= box.max.y
end

---pure: filter a unit list to those whose origin (via origin_of(unit) -> pos)
---is inside box on xy. Engine-free so it is testable.
local function _filter_in_box(units, box, origin_of)
    local out = {}
    if not units then return out end
    for i = 1, #units do
        local p = origin_of(units[i])
        if p and _in_box_xy(p, box) then out[#out + 1] = units[i] end
    end
    return out
end

---pure: nearest item in `list` to `target` by xy distance, via origin_of(item)->pos.
---@return any|nil item
---@return number|nil distance
local function _nearest(target, list, origin_of)
    if not (target and list) then return nil end
    local best, bestd2 = nil, math.huge
    for i = 1, #list do
        local p = origin_of(list[i])
        if p then
            local dx, dy = p.x - target.x, p.y - target.y
            local d2 = dx * dx + dy * dy
            if d2 < bestd2 then best, bestd2 = list[i], d2 end
        end
    end
    if not best then return nil end
    return best, math.sqrt(bestd2)
end

-- exported for offline tests
Map._center_of_box = _center_of_box
Map._in_box_xy     = _in_box_xy
Map._filter_in_box = _filter_in_box
Map._nearest       = _nearest

-- ---- camps (R1 occupancy) ------------------------------------------------

---Center of a camp (box midpoint).
function Map.CampCenter(camp)
    return _center_of_box(Camp.GetCampBox(camp))
end

---pure: stable identity key for a camp centre - a 100-unit bucket, so the same camp read from
---slightly different engine samples (or from a hand-written pair whitelist) hashes to one key.
function Map.CampKey(c)
    return string.format("%d,%d", math.floor((c and c.x or 0) / 100), math.floor((c and c.y or 0) / 100))
end

local function _camp_desc(c)
    return { camp = c, center = Map.CampCenter(c), type = Camp.GetType(c), box = Camp.GetCampBox(c) }
end

---All neutral camps as descriptors { camp, center, type, box }.
function Map.Camps()
    local out = {}
    for _, c in ipairs(Camps.GetAll() or {}) do out[#out + 1] = _camp_desc(c) end
    return out
end

---Neutral camps near a position, same descriptor shape.
function Map.CampsInRadius(pos, r)
    local out = {}
    for _, c in ipairs(Camps.InRadius(pos, r) or {}) do out[#out + 1] = _camp_desc(c) end
    return out
end

---Live neutral creeps currently inside the camp's box (R1 primitive). Alive,
---non-dormant, not waiting to spawn. The hero reads .hp / .gold off these.
local CAMP_BOX_PAD = 150   -- idle neutrals mill just outside the spawn box; pad so they still count (stabilizes occupancy)
---All live, non-dormant, non-spawning neutral creeps on the map. Enumerate ONCE,
---then box-filter per camp via Map.CampCreeps(camp, neutrals) to avoid a full-map
---scan per camp when valuing many camps in one pass.
function Map.AllNeutrals()
    return NPCs.GetAll(function(n)
        return Entity.IsAlive(n) and NPC.IsNeutral(n)
           and not NPC.IsWaitingToSpawn(n) and not Entity.IsDormant(n)
    end) or {}
end
function Map.CampCreeps(camp, neutrals)
    local box = Camp.GetCampBox(camp)
    if not box then return {} end
    local pb = { min = { x = box.min.x - CAMP_BOX_PAD, y = box.min.y - CAMP_BOX_PAD },
                 max = { x = box.max.x + CAMP_BOX_PAD, y = box.max.y + CAMP_BOX_PAD } }
    return _filter_in_box(neutrals or Map.AllNeutrals(), pb, function(n) return Entity.GetAbsOrigin(n) end)
end

---R1: does the camp currently have live creeps?
function Map.CampOccupied(camp)
    return #Map.CampCreeps(camp) > 0
end

---Nearest anchor entity to `target` from a caller-supplied list (friendly
---buildings/creeps the hero enumerates). origin_of defaults to Entity.GetAbsOrigin.
---Hero-agnostic: the math is pure (_nearest); only the default reader touches the engine.
---@return any|nil anchor
---@return number|nil distance
function Map.NearestAnchor(target, anchors)
    return _nearest(target, anchors, function(a) return Entity.GetAbsOrigin(a) end)
end

-- ---- towers / trees / pathing / ground -----------------------------------

---Towers near a position. teamType defaults to enemy inside the API, so
---omitting it returns enemy towers (split-push targets).
function Map.TowersInRadius(pos, r, teamNum, teamType)
    return Towers.InRadius(pos, r, teamNum, teamType) or {}
end

---Standing (active) trees near a position: tree-blink candidates.
function Map.TreesInRadius(pos, r)
    return Trees.InRadius(pos, r, true) or {}
end

---Nearest standing tree to pos within radius r (default 1200). Returns (tree, pos).
function Map.NearestTree(pos, r)
    local best, bestpos, bestd = nil, nil, math.huge
    for _, t in ipairs(Map.TreesInRadius(pos, r or 1200)) do
        local tp = Entity.GetAbsOrigin(t)
        if tp then
            local dx, dy = tp.x - pos.x, tp.y - pos.y
            local d = dx * dx + dy * dy
            if d < bestd then best, bestpos, bestd = t, tp, d end
        end
    end
    return best, bestpos
end

---World ground position at (x, y) with the correct Z.
function Map.GroundPos(x, y)
    return Vector(x, y, World.GetGroundZ(x, y))
end

---Real pathfinding waypoints from start to dest (GridNav.BuildPath).
function Map.Path(start, dest)
    return GridNav.BuildPath(start, dest) or {}
end

---Is there a walkable path from start to dest?
function Map.PathExists(start, dest)
    return GridNav.IsTraversableFromTo(start, dest) == true
end

---Is a single position walkable?
function Map.Walkable(pos)
    return GridNav.IsTraversable(pos) == true
end

-- Is (x,y) walkable ground? Coerces IsTraversable (may return a truthy INT, not a bool); API absent or a
-- read error -> treat as walkable (don't over-reject a real landing).
function Map.WalkablePt(x, y)
    if not (Map.Walkable and Map.GroundPos) then return true end
    local ok, w = pcall(function() return Map.Walkable(Map.GroundPos(x, y)) end)
    return (not ok) or (w ~= false)
end

-- Walkable snap: try the point, then step toward `toward` until walkable (Note 1 root fix home;
-- shared by the stand composition, the cast points, and the tree-blink landing).
function Map.SnapWalkable(p, toward)
    if not (Map.Walkable and Map.GroundPos) then return { x = p.x, y = p.y } end
    for i = 0, 5 do
        local f = 1 - i * 0.2                          -- the point first, then step toward `toward`
        local qx = toward.x + (p.x - toward.x) * f
        local qy = toward.y + (p.y - toward.y) * f
        local ok, walk = pcall(function() return Map.Walkable(Map.GroundPos(qx, qy)) end)
        if ok and walk then return { x = qx, y = qy } end
    end
    return { x = toward.x, y = toward.y }              -- fall back to `toward` (lane = walkable)
end

-- ============================================================================
-- NAV section (v0.1.396 consolidation phase 2: lib/nav.lua absorbed VERBATIM;
-- TINKER_LIB_CONSOLIDATION_PLAN.md). Movement POLICY over this world model:
-- SafeDest clamps, the transport ladder, stuck detection, tree hides. Mounted
-- as Map.Nav below.
-- ============================================================================

---@meta
---lib/nav.lua - movement-destination policy + transport selection for a per-layer movement
---chokepoint. PURE + hero-agnostic: no engine reads - the caller injects the safety predicate
---and capability flags. Built for the Tinker lane rebuild Piece 0 (TINKER_LANE_NAV_DESIGN.md);
---reusable by any hero/layer that wants one clamp + one transport ladder.
local Nav = {}

---Clamp a destination to the nearest safe point toward `retreat`.
---@param dest table { x, y } desired destination
---@param retreat table { x, y } UNIT vector toward safety (lane: toward own fountain)
---@param safe fun(pt: table): boolean injected structural predicate (e.g. tower_safe)
---@param opts table|nil { step = 100, max_steps = 40 }
---@return table pt, boolean clamped  -- dest itself when already safe (clamped=false); the first
---safe stepped-back point (clamped=true); or the max-back point when never safe (clamped=true,
---degraded - the caller reports).
function Nav.SafeDest(dest, retreat, safe, opts)
    opts = opts or {}
    local step, max_steps = opts.step or 100, opts.max_steps or 40
    if safe(dest) then return dest, false end
    local pt = dest
    for i = 1, max_steps do
        pt = { x = dest.x + retreat.x * step * i, y = dest.y + retreat.y * step * i }
        if safe(pt) then return pt, true end
    end
    return pt, true
end

---Transport rungs eligible for a leg of distance `d`, in try-order. The caller executes the first
---rung whose gated primitive succeeds and FALLS THROUGH on failure (e.g. keen finds no safe
---landing); "walk" is always last and always eligible. Pure decision only.
---@param d number distance to the (clamped) destination
---@param ctx table { keened, keen_ready, keen_min_gain, blink_ready, blink_min, blink_max }
---@return table rungs array of "keen"|"rearm"|"blink"|"walk"
function Nav.Ladder(d, ctx)
    ctx = ctx or {}
    d = d or 0
    local rungs = {}
    if not ctx.keened and d > (ctx.keen_min_gain or 0) then
        if ctx.keen_ready then rungs[#rungs + 1] = "keen"
        else rungs[#rungs + 1] = "rearm" end       -- keen on cd: a (safe) Rearm resets it
    end
    if ctx.blink_ready and d >= (ctx.blink_min or 0) and d <= (ctx.blink_max or math.huge) then
        rungs[#rungs + 1] = "blink"
    end
    rungs[#rungs + 1] = "walk"
    return rungs
end

---progress/stuck supervision for a movement leg: feed the CURRENT distance-to-destination each
---tick; stuck = no improvement of at least opts.eps for opts.window seconds. Pure state-in/state-out
---(the caller keeps `track` per leg; pass nil to start one). Unifies the hero-side watchdog family
---(no_progress / shove stuck-suppress / stuck-teleport) at the glue rebuild - same logic, one home.
---@param track table|nil { best_d, best_t }
---@param d number current distance to the destination
---@param t number current time
---@param opts table|nil { eps = 60, window = 3.0 }
---@return table track, boolean stuck
function Nav.Stuck(track, d, t, opts)
    opts = opts or {}
    local eps, window = opts.eps or 60, opts.window or 3.0
    if not track or d < track.best_d - eps then
        return { best_d = d, best_t = t }, false          -- (re)baseline on real progress
    end
    return track, (t - track.best_t) >= window
end

---best tree-hide blink landing (the pure half of the lane tree-blink feature): the tree whose
---standing-tree CLUSTER is densest, within blink range of `from`, and at least opts.threat_min from
---`threat`. Score = cluster size; ties -> farther from the threat. nil when nothing qualifies.
---trees = { {x,y}, ... } (the caller reads the standing trees near the hero via Map.TreesInRadius).
---@param opts table|nil { blink_max = 950, cluster_r = 250, min_trees = 4, threat_min = 800 }
---@return table|nil { x, y }
function Nav.TreeHideSpot(trees, from, threat, opts)
    opts = opts or {}
    local bmax  = opts.blink_max or 950
    local cr2   = (opts.cluster_r or 250) ^ 2
    local minn  = opts.min_trees or 4
    local tmin2 = (opts.threat_min or 800) ^ 2
    local best, bestn, besttd = nil, 0, -1
    for i = 1, #(trees or {}) do
        local c = trees[i]
        local dx, dy = c.x - from.x, c.y - from.y
        if dx * dx + dy * dy <= bmax * bmax then
            local tdx, tdy = c.x - (threat and threat.x or 1e9), c.y - (threat and threat.y or 1e9)
            local td2 = tdx * tdx + tdy * tdy
            if (not threat) or td2 >= tmin2 then
                local n = 0
                for j = 1, #trees do
                    local ex, ey = trees[j].x - c.x, trees[j].y - c.y
                    if ex * ex + ey * ey <= cr2 then n = n + 1 end
                end
                if n >= minn and (n > bestn or (n == bestn and td2 > besttd)) then
                    best, bestn, besttd = { x = c.x, y = c.y }, n, td2
                end
            end
        end
    end
    return best
end

-- ============================================================================
-- TOWERS section (v0.1.396 phase 2: lib/towers.lua absorbed VERBATIM). The
-- tower alive/death-ETA registry (the Towers.Track state-in/state-out pattern).
-- >>> NAME HAZARD, READ BEFORE REORDERING ANYTHING IN THIS FILE. <<< The ENGINE
-- also exposes a global `Towers` (Towers.InRadius, Towers.GetAll, the v2.0 tower
-- API). The `local Towers` declared just below shadows it ONLY FROM ITS OWN
-- DECLARATION LINE ONWARD. Map.TowersInRadius is defined ABOVE that line, so it
-- binds the ENGINE global, which is correct and is what it has always done
-- (pre-v0.1.396 this file had no local of that name at all). THE TRAP: this local
-- registry provides Track/Alive/DeathEta and NO InRadius, so hoisting the local
-- above Map.TowersInRadius, or moving that function below it, silently turns every
-- tower query into a nil-call at runtime. luac cannot catch it. lib/lane.lua's
-- _read_towers sees the engine global too. Mounted as Map.Towers below.
-- ============================================================================

---lib/towers.lua - per-tower registry: alive flag + measured hp-slope death prediction.
---Pure state-in/state-out; the hero injects samples (no engine reads here). Key = any
---stable string (the hero uses MapData name .. "@" .. team). Towers never revive, so an
---alive=false sample latches `dead` permanently. The death ETA is a MEASURED read (the
---same doctrine as the v0.1.236 wave speed): hp / EMA hp-slope while the tower is
---actively melting; an undamaged, healing, or fog-stale tower predicts math.huge =
---no behavior change anywhere. Spec: Tinker/TINKER_TOWER_DEATH_DESIGN.md.
local Towers = {}

local FLOOR   = 20    -- hp/s: below this the tower is not "melting", no prediction
local STALE_S = 6     -- s: a sample older than this decays the prediction to OFF
local EMA     = 0.5   -- slope smoothing (two-sample memory; creep waves hit steadily)

---Update the registry from one sampling pass. samples = { { key, hp, alive } ... }
---(alive == false means the spot's tower is confirmed gone). Returns the state table.
function Towers.Track(state, samples, now)
    state = state or {}
    for _, s in ipairs(samples or {}) do
        local e = state[s.key]
        if not e then e = {}; state[s.key] = e end
        if s.alive == false then
            e.dead = true
        elseif not e.dead and s.hp then
            if e.hp and e.t and now > e.t then
                local inst = (e.hp - s.hp) / (now - e.t)   -- damage taken, hp/s
                if inst < 0 then
                    e.slope = nil                          -- healing/glyph: the melt read resets
                else
                    e.slope = e.slope and (EMA * e.slope + (1 - EMA) * inst) or inst
                end
            end
            e.hp, e.t, e.seen = s.hp, now, true
        end
    end
    return state
end

---The alive flag: true / false (dead latch) / nil (never sampled).
function Towers.Alive(state, key)
    local e = state and state[key]
    if not e then return nil end
    if e.dead then return false end
    return e.seen and true or nil
end

---Seconds until predicted death from `now`: 0 when dead; hp/slope minus the sample age
---while actively melting on a fresh sample; math.huge otherwise (unknown/undamaged/
---healing/stale = conservative OFF).
function Towers.DeathEta(state, key, now, opts)
    local e = state and state[key]
    if not e then return math.huge end
    if e.dead then return 0 end
    if not (e.slope and e.hp and e.t) then return math.huge end
    if e.slope < ((opts and opts.floor) or FLOOR) then return math.huge end
    local age = now - e.t
    if age > ((opts and opts.stale_s) or STALE_S) then return math.huge end
    return math.max(0, e.hp / e.slope - age)
end

-- ============================================================================
-- POSITIONS section (v0.1.396 phase 2: lib/position_data.lua absorbed
-- VERBATIM). >>> HAZARD, READ FIRST: this is DATA plus a pure shadow
-- classifier, read by the ally-position logic and by NOTHING that moves the
-- hero. Keep it that way - anything consuming it to move the hero needs its
-- own design pass (the v0.1.382 arc). <<< Hand-curated (dota2protracker 7k,
-- period 8), code-cadence, NOT generator-owned - which is why it lives here
-- and map_data (generator-written by path) does not. Mounted as Map.Positions.
-- ============================================================================

---@meta
---lib/position_data.lua - playable Dota position (1-5) sets per hero.
---
---TINKER-ONLY. Nothing else requires this file. It is deliberately NOT in
---lib/hero_value.lua: that module is shared with Lina (Lina.lua:55 reads it
---for the Flame Cloak flip sum) and its tables are scalars feeding a number
---contract, which a set-valued entry would break.
---
---Data-only Tier 2, no API calls, no callbacks, no side effects.
---
---=== THE HAZARD, READ THIS BEFORE EDITING ===
---A WRONG NARROW ENTRY IS WORSE THAN A MISSING ONE.
---A missing hero returns ALL from Of(), the classifier fails to resolve, and
---the caller falls back to today's HeroValue.IsCore path - i.e. exactly
---current behaviour, never worse. A wrong NARROW entry instead produces a
---CONFIDENT assignment that flips IsCore, which is the precise defect class
---this data exists to remove. Worse, the consumer resolves positions by
---constraint elimination, so one bad entry can mis-assign the whole team,
---not one hero. WHEN UNSURE, WIDEN. Never trim a set to make elimination
---resolve more often.
---
---=== SOURCE ===
---dota2protracker.com/meta, mmr=7000, period=8, patch 7.41, harvested
---2026-08-13. Five separate per-position meta lists (pos 1..5), joined to
---lib/hero_data.lua keys via d2pt's own npc field (exact join, nothing
---inferred). Membership rule: hero appears in position P's set iff it has
--->= 200 games at P in that sample (~0.25% of the ~79,170 games per
---position). 200 is not a taste call: d2pt hard-truncates the pos-2 and
---pos-3 lists at 200 and the tail below could not be retrieved, so 200 is
---the only floor applicable uniformly to all five positions. At that floor
---the harvest still captures 97.7% / 100% / 100% / 96.4% / 97.1% of the
---games played at positions 1/2/3/4/5 respectively.
---
---HAND-CURATED AND META-DRIFTING. No tool in tools/ regenerates this. The
---position a hero is played at is a property of the patch and the meta, not
---of the KV data - it is provably NOT derivable from KV: grouping heroes by
---Bot.LaningInfo (SoloDesire, RequiresFarm, RequiresBabysit) puts Dazzle and
---Earthshaker in the same bucket. Re-curate by hand after a big patch. The
---trailing comment on each row is that hero's raw pos1/pos2/pos3/pos4/pos5
---match counts from the snapshot, kept so a later editor can see the
---evidence rather than re-guess it.
---
---=== MARKED ROWS ===
---  WIDENED  - a position was ADDED that the harvest did not show, because
---             d2pt truncated the pos-2 / pos-3 lists at 200 games and a 0
---             there means "unknown", not "never". Only interior gaps are
---             filled (the hero already plays both a lower AND a higher
---             position), and only at 2 and 3. Positions 1/4/5 were
---             harvested complete, so a low count there is an observation
---             and is left alone. Widening is the cheap direction: it costs
---             resolving power, never correctness.
---  OPERATOR - supplied directly by the operator and kept even where the
---             harvest disagrees. The disagreement is printed on the row.
---
---=== NOT COVERED ===
---Heroes with no row here get ALL from Of(). That is a legal, safe answer,
---not a bug. Absence from a d2pt list means "under 200 games at that
---position in this snapshot", never "cannot play that position", so absence
---is never read as a hard exclusion. npc_dota_hero_chen is deliberately
---left out: its only harvested play is 189 pos-5 and 26 pos-4 games, both
---under the floor, and writing a support-only set from below-floor evidence
---is exactly the wrong-narrow move.
---
---Usage:
---```lua
---local PositionData = require("lib.position_data")
---local cand = PositionData.Of(ally_name)   -- always a non-empty {ints}
---```

local PositionData = {}

---Every position, in ascending order. The answer for any hero this table
---does not cover. Never nil, never {}.
PositionData.ALL = { 1, 2, 3, 4, 5 }

---Positions a hero is actually played at, ascending ints in 1..5.
---Trailing comment = raw pos1/pos2/pos3/pos4/pos5 match counts (see header).
PositionData.PLAYABLE = {
    npc_dota_hero_abaddon                    = { 5             },  -- 46/0/0/100/607
    npc_dota_hero_abyssal_underlord          = { 3             },  -- 0/0/2725/13/15
    npc_dota_hero_alchemist                  = { 1             },  -- 438/0/0/78/76
    npc_dota_hero_ancient_apparition         = { 4, 5          },  -- 0/0/0/313/1257
    npc_dota_hero_antimage                   = { 1             },  -- 1737/0/0/12/6
    npc_dota_hero_arc_warden                 = { 2             },  -- 38/1127/0/17/12
    npc_dota_hero_axe                        = { 3             },  -- 0/0/5155/83/56
    npc_dota_hero_bane                       = { 4, 5          },  -- 0/0/0/777/3009
    npc_dota_hero_batrider                   = { 3             },  -- 0/0/466/155/69
    npc_dota_hero_beastmaster                = { 2, 3          },  -- 50/238/1651/5/5
    npc_dota_hero_bloodseeker                = { 1             },  -- 269/0/0/4/12
    npc_dota_hero_bounty_hunter              = { 4, 5          },  -- 0/0/0/3713/439
    npc_dota_hero_brewmaster                 = { 3             },  -- 0/0/1604/20/8
    npc_dota_hero_bristleback                = { 3             },  -- 102/0/923/7/3
    npc_dota_hero_broodmother                = { 2             },  -- 176/313/0/5/1
    npc_dota_hero_centaur                    = { 3             },  -- 21/0/2995/13/16
    npc_dota_hero_chaos_knight               = { 1, 2, 3       },  -- 336/0/440/25/18           WIDENED +2
    npc_dota_hero_clinkz                     = { 1, 2          },  -- 1352/218/0/19/3
    npc_dota_hero_crystal_maiden             = { 4, 5          },  -- 0/0/0/502/2453
    npc_dota_hero_dark_seer                  = { 3             },  -- 0/0/3159/11/2
    npc_dota_hero_dark_willow                = { 4, 5          },  -- 0/0/0/2052/725
    npc_dota_hero_dawnbreaker                = { 2, 3          },  -- 30/214/5726/117/93
    npc_dota_hero_dazzle                     = { 5             },  -- 0/0/0/182/1405            OPERATOR (harvest said {5})
    npc_dota_hero_death_prophet              = { 2, 3          },  -- 0/575/759/48/105
    npc_dota_hero_disruptor                  = { 4, 5          },  -- 0/0/0/484/3070
    npc_dota_hero_doom_bringer               = { 3             },  -- 142/0/3251/71/27
    npc_dota_hero_dragon_knight              = { 2, 3          },  -- 80/365/332/7/0
    npc_dota_hero_drow_ranger                = { 1             },  -- 2843/0/0/5/8
    npc_dota_hero_earth_spirit               = { 2, 3, 4, 5    },  -- 0/3198/565/1956/252
    npc_dota_hero_earthshaker                = { 2, 3, 4, 5    },  -- 0/2115/1187/1252/142      UNION of operator {3,4,5} and harvest {2,3,4}. Both sources carry real evidence (2115 observed pos-2 games; the operator asserts he is also played support), so the WIDEN rule applies rather than picking a side. COSTS NOTHING IN THE NORMAL CASE: with Tinker pinned to mid, 2 is struck by elimination and this reduces to exactly the operator {3,4,5}; it is only different, and only better, when Tinker is NOT mid.
    npc_dota_hero_elder_titan                = { 5             },  -- 0/0/0/107/437
    npc_dota_hero_ember_spirit               = { 2             },  -- 60/6557/0/30/9
    npc_dota_hero_enchantress                = { 3, 4, 5       },  -- 0/0/222/490/1003
    npc_dota_hero_enigma                     = { 3             },  -- 0/0/2982/93/65
    npc_dota_hero_faceless_void              = { 1             },  -- 2499/0/0/12/13
    npc_dota_hero_furion                     = { 1, 2, 3, 4, 5 },  -- 934/443/346/430/255
    npc_dota_hero_grimstroke                 = { 4, 5          },  -- 0/0/0/1537/1328
    npc_dota_hero_gyrocopter                 = { 1, 2, 3, 4, 5 },  -- 656/0/0/284/234           WIDENED +2,3
    npc_dota_hero_hoodwink                   = { 4, 5          },  -- 0/0/0/4832/1474
    npc_dota_hero_huskar                     = { 2             },  -- 65/1064/0/27/40
    npc_dota_hero_invoker                    = { 2, 3, 4       },  -- 0/6884/0/772/194          WIDENED +3
    npc_dota_hero_jakiro                     = { 4, 5          },  -- 0/0/0/271/1028
    npc_dota_hero_juggernaut                 = { 1             },  -- 2555/0/0/7/5
    npc_dota_hero_keeper_of_the_light        = { 2, 3, 4, 5    },  -- 0/2984/0/2146/330         WIDENED +3
    npc_dota_hero_kez                        = { 1, 2          },  -- 2042/751/0/7/6
    npc_dota_hero_kunkka                     = { 2, 3          },  -- 33/449/761/22/7
    npc_dota_hero_largo                      = { 3, 4, 5       },  -- 0/0/1314/343/356
    npc_dota_hero_legion_commander           = { 3             },  -- 0/0/2180/11/0
    npc_dota_hero_leshrac                    = { 1, 2          },  -- 206/1133/0/48/23
    npc_dota_hero_lich                       = { 4, 5          },  -- 0/0/0/651/3353
    npc_dota_hero_life_stealer               = { 1             },  -- 4351/0/0/5/12
    npc_dota_hero_lina                       = { 1, 2, 3, 4    },  -- 1130/8046/0/251/104       WIDENED +3
    npc_dota_hero_lion                       = { 2, 3, 4, 5    },  -- 0/522/0/3012/2643         WIDENED +3
    npc_dota_hero_lone_druid                 = { 1, 2          },  -- 1231/438/0/6/13
    npc_dota_hero_luna                       = { 1             },  -- 6930/0/0/6/6
    npc_dota_hero_lycan                      = { 3             },  -- 0/0/1474/22/3
    npc_dota_hero_magnataur                  = { 2, 3, 4, 5    },  -- 59/643/2194/474/286
    npc_dota_hero_marci                      = { 2, 3, 4, 5    },  -- 98/516/501/368/483
    npc_dota_hero_mars                       = { 3             },  -- 0/0/2017/40/16
    npc_dota_hero_medusa                     = { 1             },  -- 575/0/0/3/3
    npc_dota_hero_meepo                      = { 1, 2          },  -- 231/597/0/2/3
    npc_dota_hero_mirana                     = { 4, 5          },  -- 58/0/0/3823/2579
    npc_dota_hero_monkey_king                = { 1, 2          },  -- 652/499/0/71/17
    npc_dota_hero_morphling                  = { 1             },  -- 1926/0/0/3/4
    npc_dota_hero_muerta                     = { 1, 2, 3, 4    },  -- 1371/0/0/213/60           WIDENED +2,3
    npc_dota_hero_naga_siren                 = { 1             },  -- 465/0/0/4/16
    npc_dota_hero_necrolyte                  = { 1, 2, 3       },  -- 2032/1928/2237/5/9
    npc_dota_hero_nevermore                  = { 1, 2          },  -- 6737/2174/0/21/16
    npc_dota_hero_night_stalker              = { 3             },  -- 22/0/4777/71/16
    npc_dota_hero_nyx_assassin               = { 4, 5          },  -- 0/0/0/2060/252
    npc_dota_hero_obsidian_destroyer         = { 2             },  -- 97/2002/0/63/32
    npc_dota_hero_ogre_magi                  = { 2, 3, 4, 5    },  -- 0/206/282/383/1483
    npc_dota_hero_omniknight                 = { 3, 5          },  -- 0/0/223/82/563
    npc_dota_hero_oracle                     = { 4, 5          },  -- 0/0/0/264/1959
    npc_dota_hero_pangolier                  = { 2, 3          },  -- 0/1872/897/8/2
    npc_dota_hero_phantom_assassin           = { 1             },  -- 1507/0/0/2/3
    npc_dota_hero_phantom_lancer             = { 1             },  -- 6241/0/0/2/10
    npc_dota_hero_phoenix                    = { 2, 3, 4, 5    },  -- 0/485/763/1017/992
    npc_dota_hero_primal_beast               = { 2, 3          },  -- 0/691/1299/14/5
    npc_dota_hero_puck                       = { 2             },  -- 0/4011/0/8/3
    npc_dota_hero_pudge                      = { 2, 3, 4, 5    },  -- 176/582/2417/3963/2627
    npc_dota_hero_pugna                      = { 4, 5          },  -- 0/0/0/506/549
    npc_dota_hero_queenofpain                = { 2             },  -- 25/2901/0/166/42
    npc_dota_hero_rattletrap                 = { 4, 5          },  -- 0/0/0/1587/1960
    npc_dota_hero_razor                      = { 1, 2, 3       },  -- 340/214/828/31/29
    npc_dota_hero_riki                       = { 1, 2          },  -- 360/327/0/88/15
    npc_dota_hero_ringmaster                 = { 4, 5          },  -- 0/0/0/2249/2658
    npc_dota_hero_rubick                     = { 2, 3, 4, 5    },  -- 0/867/0/6577/1504         WIDENED +3
    npc_dota_hero_sand_king                  = { 2, 3          },  -- 0/421/491/14/2
    npc_dota_hero_shadow_demon               = { 4, 5          },  -- 0/0/0/539/627
    npc_dota_hero_shadow_shaman              = { 4, 5          },  -- 0/0/0/1049/1682
    npc_dota_hero_shredder                   = { 2, 3          },  -- 0/264/2954/22/5
    npc_dota_hero_silencer                   = { 4, 5          },  -- 0/0/0/566/1613
    npc_dota_hero_skeleton_king              = { 1, 2, 3       },  -- 488/0/663/9/4             WIDENED +2
    npc_dota_hero_skywrath_mage              = { 2, 3, 4, 5    },  -- 0/291/0/2547/621          WIDENED +3
    npc_dota_hero_slardar                    = { 2, 3          },  -- 0/493/2061/19/9
    npc_dota_hero_slark                      = { 1             },  -- 2539/0/0/121/41
    npc_dota_hero_snapfire                   = { 2, 3, 4, 5    },  -- 23/2245/985/2851/1658
    npc_dota_hero_sniper                     = { 2             },  -- 165/1371/0/103/57
    npc_dota_hero_spectre                    = { 1             },  -- 5863/0/0/15/17
    npc_dota_hero_spirit_breaker             = { 3, 4, 5       },  -- 0/0/317/4808/671
    npc_dota_hero_storm_spirit               = { 2             },  -- 82/3347/0/6/7
    npc_dota_hero_sven                       = { 1             },  -- 3554/0/0/14/18
    npc_dota_hero_techies                    = { 4, 5          },  -- 0/0/0/2522/970
    npc_dota_hero_templar_assassin           = { 1             },  -- 1455/0/0/1/1
    npc_dota_hero_terrorblade                = { 1             },  -- 2797/0/0/11/5
    npc_dota_hero_tidehunter                 = { 3             },  -- 0/0/2751/25/16
    npc_dota_hero_tinker                     = { 2             },  -- 36/2026/0/42/20
    npc_dota_hero_tiny                       = { 1, 2, 3, 4    },  -- 1967/534/0/558/73         WIDENED +3
    npc_dota_hero_treant                     = { 4, 5          },  -- 0/0/0/860/7383
    npc_dota_hero_troll_warlord              = { 1             },  -- 569/0/0/5/0
    npc_dota_hero_tusk                       = { 4, 5          },  -- 0/0/0/1720/3168
    npc_dota_hero_undying                    = { 3, 4, 5       },  -- 0/0/1601/968/4928
    npc_dota_hero_ursa                       = { 1             },  -- 1353/0/0/3/9
    npc_dota_hero_vengefulspirit             = { 1, 2, 3, 4, 5 },  -- 1161/0/732/393/541        WIDENED +2
    npc_dota_hero_venomancer                 = { 4, 5          },  -- 0/0/0/420/731
    npc_dota_hero_viper                      = { 2, 3          },  -- 64/1141/831/53/77
    npc_dota_hero_visage                     = { 2, 3          },  -- 0/396/644/153/73
    npc_dota_hero_void_spirit                = { 2, 3          },  -- 45/2533/291/46/6
    npc_dota_hero_warlock                    = { 5             },  -- 0/0/0/106/1244
    npc_dota_hero_weaver                     = { 1, 2, 3, 4    },  -- 538/0/0/530/168           WIDENED +2,3
    npc_dota_hero_windrunner                 = { 1, 2, 3, 4, 5 },  -- 2139/697/1304/2199/458
    npc_dota_hero_winter_wyvern              = { 3, 4, 5       },  -- 0/0/855/959/2724
    npc_dota_hero_wisp                       = { 1, 2, 3, 4, 5 },  -- 835/981/287/520/1395
    npc_dota_hero_witch_doctor               = { 4, 5          },  -- 0/0/0/475/1856
    npc_dota_hero_zuus                       = { 2, 3, 4, 5    },  -- 0/887/0/2256/1072         WIDENED +3
}

---The single position the hero is played at MOST in the snapshot - the
---operator's tie-breaker when elimination stalls. Always a member of the
---hero's PLAYABLE set. For an OPERATOR row it is the most-played position
---*inside the operator's set*, not the global argmax.
PositionData.PREFERRED = {
    npc_dota_hero_abaddon                    = 5,
    npc_dota_hero_abyssal_underlord          = 3,
    npc_dota_hero_alchemist                  = 1,
    npc_dota_hero_ancient_apparition         = 5,
    npc_dota_hero_antimage                   = 1,
    npc_dota_hero_arc_warden                 = 2,
    npc_dota_hero_axe                        = 3,
    npc_dota_hero_bane                       = 5,
    npc_dota_hero_batrider                   = 3,
    npc_dota_hero_beastmaster                = 3,
    npc_dota_hero_bloodseeker                = 1,
    npc_dota_hero_bounty_hunter              = 4,
    npc_dota_hero_brewmaster                 = 3,
    npc_dota_hero_bristleback                = 3,
    npc_dota_hero_broodmother                = 2,
    npc_dota_hero_centaur                    = 3,
    npc_dota_hero_chaos_knight               = 3,
    npc_dota_hero_clinkz                     = 1,
    npc_dota_hero_crystal_maiden             = 5,
    npc_dota_hero_dark_seer                  = 3,
    npc_dota_hero_dark_willow                = 4,
    npc_dota_hero_dawnbreaker                = 3,
    npc_dota_hero_dazzle                     = 5,
    npc_dota_hero_death_prophet              = 3,
    npc_dota_hero_disruptor                  = 5,
    npc_dota_hero_doom_bringer               = 3,
    npc_dota_hero_dragon_knight              = 2,
    npc_dota_hero_drow_ranger                = 1,
    npc_dota_hero_earth_spirit               = 2,
    npc_dota_hero_earthshaker                = 4,
    npc_dota_hero_elder_titan                = 5,
    npc_dota_hero_ember_spirit               = 2,
    npc_dota_hero_enchantress                = 5,
    npc_dota_hero_enigma                     = 3,
    npc_dota_hero_faceless_void              = 1,
    npc_dota_hero_furion                     = 1,
    npc_dota_hero_grimstroke                 = 4,
    npc_dota_hero_gyrocopter                 = 1,
    npc_dota_hero_hoodwink                   = 4,
    npc_dota_hero_huskar                     = 2,
    npc_dota_hero_invoker                    = 2,
    npc_dota_hero_jakiro                     = 5,
    npc_dota_hero_juggernaut                 = 1,
    npc_dota_hero_keeper_of_the_light        = 2,
    npc_dota_hero_kez                        = 1,
    npc_dota_hero_kunkka                     = 3,
    npc_dota_hero_largo                      = 3,
    npc_dota_hero_legion_commander           = 3,
    npc_dota_hero_leshrac                    = 2,
    npc_dota_hero_lich                       = 5,
    npc_dota_hero_life_stealer               = 1,
    npc_dota_hero_lina                       = 2,
    npc_dota_hero_lion                       = 4,
    npc_dota_hero_lone_druid                 = 1,
    npc_dota_hero_luna                       = 1,
    npc_dota_hero_lycan                      = 3,
    npc_dota_hero_magnataur                  = 3,
    npc_dota_hero_marci                      = 2,
    npc_dota_hero_mars                       = 3,
    npc_dota_hero_medusa                     = 1,
    npc_dota_hero_meepo                      = 2,
    npc_dota_hero_mirana                     = 4,
    npc_dota_hero_monkey_king                = 1,
    npc_dota_hero_morphling                  = 1,
    npc_dota_hero_muerta                     = 1,
    npc_dota_hero_naga_siren                 = 1,
    npc_dota_hero_necrolyte                  = 3,
    npc_dota_hero_nevermore                  = 1,
    npc_dota_hero_night_stalker              = 3,
    npc_dota_hero_nyx_assassin               = 4,
    npc_dota_hero_obsidian_destroyer         = 2,
    npc_dota_hero_ogre_magi                  = 5,
    npc_dota_hero_omniknight                 = 5,
    npc_dota_hero_oracle                     = 5,
    npc_dota_hero_pangolier                  = 2,
    npc_dota_hero_phantom_assassin           = 1,
    npc_dota_hero_phantom_lancer             = 1,
    npc_dota_hero_phoenix                    = 4,
    npc_dota_hero_primal_beast               = 3,
    npc_dota_hero_puck                       = 2,
    npc_dota_hero_pudge                      = 4,
    npc_dota_hero_pugna                      = 5,
    npc_dota_hero_queenofpain                = 2,
    npc_dota_hero_rattletrap                 = 5,
    npc_dota_hero_razor                      = 3,
    npc_dota_hero_riki                       = 1,
    npc_dota_hero_ringmaster                 = 5,
    npc_dota_hero_rubick                     = 4,
    npc_dota_hero_sand_king                  = 3,
    npc_dota_hero_shadow_demon               = 5,
    npc_dota_hero_shadow_shaman              = 5,
    npc_dota_hero_shredder                   = 3,
    npc_dota_hero_silencer                   = 5,
    npc_dota_hero_skeleton_king              = 3,
    npc_dota_hero_skywrath_mage              = 4,
    npc_dota_hero_slardar                    = 3,
    npc_dota_hero_slark                      = 1,
    npc_dota_hero_snapfire                   = 4,
    npc_dota_hero_sniper                     = 2,
    npc_dota_hero_spectre                    = 1,
    npc_dota_hero_spirit_breaker             = 4,
    npc_dota_hero_storm_spirit               = 2,
    npc_dota_hero_sven                       = 1,
    npc_dota_hero_techies                    = 4,
    npc_dota_hero_templar_assassin           = 1,
    npc_dota_hero_terrorblade                = 1,
    npc_dota_hero_tidehunter                 = 3,
    npc_dota_hero_tinker                     = 2,
    npc_dota_hero_tiny                       = 1,
    npc_dota_hero_treant                     = 5,
    npc_dota_hero_troll_warlord              = 1,
    npc_dota_hero_tusk                       = 5,
    npc_dota_hero_undying                    = 5,
    npc_dota_hero_ursa                       = 1,
    npc_dota_hero_vengefulspirit             = 1,
    npc_dota_hero_venomancer                 = 5,
    npc_dota_hero_viper                      = 2,
    npc_dota_hero_visage                     = 3,
    npc_dota_hero_void_spirit                = 2,
    npc_dota_hero_warlock                    = 5,
    npc_dota_hero_weaver                     = 1,
    npc_dota_hero_windrunner                 = 4,
    npc_dota_hero_winter_wyvern              = 5,
    npc_dota_hero_wisp                       = 5,
    npc_dota_hero_witch_doctor               = 5,
    npc_dota_hero_zuus                       = 4,
}

----------------------------------------------------------------------------
-- Of(name)
--
-- The playable-position set for a hero, or ALL when the hero is not covered.
-- NEVER returns nil and NEVER returns an empty table - an uncovered hero must
-- degrade to "could be anything", which leaves the caller at today's
-- behaviour rather than a confident wrong answer.
--
-- The returned table is shared, not a copy. Treat it as read-only.
--
-- Signature: (name: string|nil) -> { int, ... }  (1 <= #result <= 5)
----------------------------------------------------------------------------
function PositionData.Of(name)
    if type(name) ~= "string" then
        return PositionData.ALL
    end
    return PositionData.PLAYABLE[name] or PositionData.ALL
end

----------------------------------------------------------------------------
-- PreferredOf(name)
--
-- The tie-breaker position, or nil when the hero is not covered. nil here is
-- deliberate and legal: no evidence means no preference, and the caller must
-- fall through rather than invent one.
--
-- Signature: (name: string|nil) -> int|nil
----------------------------------------------------------------------------
function PositionData.PreferredOf(name)
    if type(name) ~= "string" then
        return nil
    end
    return PositionData.PREFERRED[name]
end

-- ---- observed-lane helpers (v0.1.379) ---------------------------------------------------------
-- Pure. They live here rather than in Tinker.lua because the main chunk sits AT Lua's 200-local
-- ceiling (three more top-level `local function`s threw "too many local variables"), and because
-- position logic belongs with the position data. The per-tick TALLY stays hero-side: it needs
-- State/now/Lane and it is four lines at the one site that already has the ally name and position.

---Resolve a per-ally lane tally { top, mid, bot, n } to an observed lane, or nil.
---Requires BOTH a minimum sample count AND a dominant share. A single sample is worthless:
---Lane._assign_lane is a coarse diagonal band accepting ~38% of the map whose mid region contains
---the ROSHAN PIT and the river centre, so a warding or Rosh-watching support accumulates mid
---samples. Only sustained dominance means anything.
---@return string|nil lane, number share
function PositionData.ObservedLane(h, min_n, min_share)
    if not h or (h.n or 0) < (min_n or 12) then return nil, 0 end
    local best, bn = nil, -1
    for _, ln in ipairs({ "top", "mid", "bot" }) do
        if (h[ln] or 0) > bn then best, bn = ln, (h[ln] or 0) end
    end
    local share = bn / math.max(1, h.n)
    if share < (min_share or 0.60) then return nil, share end
    return best, share
end

---The position set a lane can hold, from the point of view of `team` (2 = Radiant, 3 = Dire).
---Radiant safelane is BOT, Dire safelane is TOP. Standard layout: safelane {1,5}, offlane {3,4},
---mid {2}. INTERSECT this with the hero's playable set, never substitute it - so a genuinely odd
---lineup narrows to EMPTY and reads UNDETERMINED rather than confidently wrong.
---@return table set  keyed by position number
function PositionData.LaneSlots(lane, team)
    if lane == "mid" then return { [2] = true } end
    local safe = (team == 2) and "bot" or "top"
    if lane == safe then return { [1] = true, [5] = true } end
    return { [3] = true, [4] = true }
end

---Residual playable-position sets for a list of ally names, narrowed by naked-single elimination.
---HERO ASSUMPTION (kept verbatim from the Tinker main chunk, which is the only caller): position 2
---is struck from every ally set because Tinker holds mid himself. That is why this lives in a file
---whose header already declares itself TINKER-ONLY.
---@return table cand  name -> set of still-possible positions (keyed by position number)
function PositionData.Shadow(names)
    local cand = {}
    for _, n in ipairs(names) do
        local s = {}
        for _, v in ipairs(PositionData.Of(n)) do s[v] = true end
        s[2] = nil                                  -- the mid pin: Tinker owns 2
        cand[n] = s
    end
    local changed = true                            -- naked singles to fixpoint
    while changed do
        changed = false
        for n, s in pairs(cand) do
            local cnt, only = 0, nil
            for v in pairs(s) do cnt = cnt + 1; only = v end
            if cnt == 1 then
                for n2, s2 in pairs(cand) do
                    if n2 ~= n and s2[only] then s2[only] = nil; changed = true end
                end
            end
        end
    end
    return cand
end

-- the consolidation mounts (phase 2): one file, one require, one returned table.
Map.Nav = Nav
Map.Towers = Towers
Map.Positions = PositionData

return Map
