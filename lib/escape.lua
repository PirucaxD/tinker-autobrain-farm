---@meta
---lib/escape.lua - danger-aware escape destination picking.
---
---Hero-agnostic. All functions take entity / vector args explicitly
---(no implicit hero-state reads), matching the lib/geometry.lua
---convention.
---
---Extracted from Sniper.lua during Lina Phase 5 (positioning
---intelligence for self-displacement saves). The three helpers form
---a small module:
---  - Escape.DangerAtPos(me, pos)
---  - Escape.SafePushDestination(me, dest, threat_hint)
---  - Escape.PickDir(me, me_pos, toward, push, threat_hint, filter?)
---
---Sniper.lua reaches them via thin state.* wrappers so its existing
---call sites do not change. Lina.lua's Phase 5 .fire bodies (Pike
---first, then Force / EUL / WW) call them directly.
---
---No engine API surprises beyond the two already-documented gotchas:
---  - NPC.FindRotationAngle returns RADIANS (math.deg before any
---    deg-based compare). NOT used inside this module - the angle
---    math is in the callers' turn-then-fire harness.
---  - First cast of a freshly-acquired item silently dropped. Also
---    a caller concern (Sniper's pike_prime + Lina's pike_reissue).
---
---v0.5.61 fix: require lib/target here. The original v0.5.57 extraction
---left Target as a global ref expecting it to be available in the lib's
---scope, but lib modules do not inherit the hero script's upvalues.
---Latent bug bit EUL on first self-cast (v0.5.60 demo log L2712:
---'attempt to index a nil value (global Target)' inside
---Escape.SafePushDestination). The Pike / Force code path would have
---crashed identically; v0.5.58 demo never triggered Pike's self-cast
---branch (all Pike fires went enemy-target via the unchanged primary
---branch) so it stayed latent.
---
---v0.5.75 lift (lib-first audit bucket B + C + D): three more helpers
---moved out of Lina.lua into this module so future heroes (Sniper next)
---pick them up via require with zero rewrite:
---  - Escape.ComputeSafeDest (stateless): toward = caster-or-centroid,
---    then PickDir. Returns (escape_dir, landing) or (nil, nil).
---  - Escape.TrySelfPush + Escape.SelfPushTick: the turn-then-fire
---    harness Pike + Force self-cast both use. Stateful via a caller-
---    owned pending struct (return-the-pending pattern, matches v0.5.74's
---    ThreatData.ComputeArrivalTime closure shape: lib stays stateless,
---    hero owns the slot + ticks once per frame).
---  - Escape.QueueSafePostMove + Escape.PostAirborneMoveTick: the
---    re-issue-while-airborne harness EUL + WW use to walk Lina toward
---    a danger-aware landing during / after airborne. Same return-the-
---    pending shape.
---
---All five stateful entry points take a cfg table with hero-side
---callbacks (safe_issue, issue_item_self, tlog, now, uname, item_get,
---item_ready, on_self_cast) so the lib never imports a hero's wrappers
---directly. cfg shape documented above each function. Sniper migration
---is a separate slice (replace state.compute_safe_dest / pick_escape_dir
---/ pending_pike_self / pending_pike_self_tick call sites with Escape.*
---calls passing his own cfg); Sniper.lua is intentionally untouched in
---v0.5.75.

local Target = require("lib.target")

-- ============================================================================
-- VISION section (v0.1.399 consolidation phase 3: lib/vision.lua absorbed;
-- TINKER_LIB_CONSOLIDATION_PLAN.md - the LAST merge and the only THREE-HERO
-- file). Mounted as Escape.Vision below, ABOVE every use (Vision.Age in
-- FogSnapshot) - a definition below its caller resolves as a nil global at
-- runtime, the class that broke v0.1.397. ONE DELIBERATE EDIT vs the absorbed
-- file, mandated by the phase-3 review: module state lives in an ANCHORED
-- STORE (package.loaded pseudo-key; see the store block below for why NOT
-- _G), not in section locals. Tinker.lua AND Lina.lua both cache-clear
-- lib.escape at load, so per-instance locals would fork an EMPTY tracker per
-- hero - only the last-wired instance would stamp, and the other heroes would
-- read eternally-empty fog ages with every gate green. find-or-create once;
-- every re-require aliases the SAME tables.
-- ============================================================================

---(absorbed lib/vision.lua) - shared last-seen tracker for HEROES.
---
---WHY THIS EXISTS: `Hero.GetLastVisibleTime` is DEAD - measured nil on 405 of 405 fogged
---reads across all five enemy heroes in one 895s match (Tinker g353, Umbrella build 831).
---The method exists and is documented nilable; it simply never yields a value, so every
---fog-age model built on it is inert (FogSnapshot below, lib/target.lua). No
---other API returns a last-seen timestamp - `FogOfWar.IsPointVisible` answers "is this
---POINT visible now", not "when did I last see this hero" - so the timestamp has to be
---built. See Tinker/TINKER_VISION_LIB_DESIGN.md.
---
---THIS TRACKER OWNS ITS CLOCK. Callers never pass one for age math: the stamp and the read
---both come from `clock()` below. That is not stylistic. A caller-supplied clock is exactly
---the defect that made the preceding fog arc a red herring - Tinker injected
---`GameRules.GetDOTATime` into a subtraction against an engine-clock timestamp, so `age`
---went negative and clamped to 0 for 275+ versions. Owning the clock makes that class of
---bug structurally impossible here.
---
---SINGLETON: the STORE below is the singleton, not the module. A Lua module is only a
---singleton while it stays in package.loaded, and two heroes cache-clear lib.escape at
---every load - so the shared state is anchored under a package.loaded pseudo-key and
---survives any re-require; stamps are written once and read by every hero in the same Lua
---state. KNOWN CEILING: the store also survives ACROSS matches in one client session, so
---a recycled entity handle can inherit a stale stamp (a LARGE age). Per consumer that
---cuts BOTH WAYS: FogProximityRisk SKIPS an enemy aged past its cap (LESS caution), while
---AdvanceRiskScore keeps a huge probable disc in reach and inflates the fog score (MORE
---caution for Lina's FC gates). Pre-merge, each script load began with an empty tracker.

local Vision = {}

-- the anchored store (find-or-create ONCE). THE ANCHOR IS package.loaded UNDER A
-- PSEUDO-MODULE KEY, NOT _G: UCZone's sandbox does not expose _G (lib/signal.lua's
-- v6.15.3 hotfix note - "attempt to index a nil value (global '_G')" MEASURED at module
-- load), so a rawget(_G, ...) here would crash all three heroes at load. package.loaded
-- is proven in-engine on every axis this needs: shared across hero scripts in one Lua
-- state (lib/signal.lua's registry rests on exactly that), writable (every hero's
-- cache-clear list assigns into it at every load), and never cleared at THIS key (the
-- clear lists are explicit lib.* name lists; nothing requires or nils a pseudo-key).
-- If package.loaded is somehow absent, fall back to a module-local store: per-instance
-- state = the pre-merge per-load behaviour, a safe valve, never a crash.
-- FUTURE STORE FIELDS: default them ON ATTACH (_vstore.f = _vstore.f or init), never only
-- in the create branch - an old-shape store survives a mid-session lib upgrade.
-- Table fields are aliased below - the aliases share the store's tables by reference; the
-- two SCALARS (events, inited) have no alias and must be read/written through the store.
local _vreg = package and package.loaded
local _vstore = _vreg and _vreg["__LIB_VISION_STORE"]
if not _vstore then
    _vstore = { last_seen = {}, events = 0, types = {}, inited = false,
                wired = setmetatable({}, { __mode = "k" }) }
    if _vreg then _vreg["__LIB_VISION_STORE"] = _vstore end
end
-- v0.1.409 build 1 (TINKER_FOG_TRACKER_DESIGN.md): the SHADOW stamp table. Defaulted ON
-- ATTACH per the FUTURE-STORE-FIELDS rule above, never only in the create branch, so an
-- old-shape store surviving a mid-session lib upgrade gains the field instead of nil-crashing.
_vstore.last_seen_sh = _vstore.last_seen_sh or {}
local last_seen = _vstore.last_seen     -- entity -> monotonic seconds at which it went dormant
local last_seen_sh = _vstore.last_seen_sh   -- entity -> clock() at the dtype-1 (ENTER dormancy) callback
local types = _vstore.types             -- probe counters: the callback surface is UNPROVEN

---Monotonic seconds. `GlobalVars.GetCurTime` is what the FogSnapshot note documents as the
---engine clock; `GameRules.GetGameTime` is the fallback. NEVER `GetDOTATime` - that is the
---on-screen clock, and mixing the two is the bug this tracker exists downstream of.
local function clock()
    if GlobalVars and GlobalVars.GetCurTime then return GlobalVars.GetCurTime() end
    if GameRules and GameRules.GetGameTime then return GameRules.GetGameTime() end
    return 0
end

---OnSetDormant handler. The signature is `(npc, type)` where `type` is an
---`Enum.DormancyType` the docs describe only as "the type of change". The enum was
---LEARNED FROM DATA, not guessed: g401 diffed the recorded type counters against the
---probe's fog census over 73 windows with zero contradictions - dtype 1 = ENTERING
---dormancy, 0 = LEAVING. As of v0.1.410 the dtype IS the trusted stamp gate;
---`Entity.IsDormant` is probed here ONLY for the types diagnostic, because g401 also
---proved it reads false INSIDE this callback (the engine applies the flag after it), which
---is why the original if-dorm gate stamped nothing across 46 logs. This codebase has been
---burned three times by assuming API semantics (NPC.GetAttackDamage,
---Ability.GetCooldownTimeRemaining, NPC.GetModifierRemaining); the recorded-then-derive
---approach here is the counterexample that worked.
---@param npc userdata
---@param dtype any
function Vision.OnSetDormant_handler(npc, dtype)
    if not npc then return end
    if NPC and NPC.IsHero and not NPC.IsHero(npc) then return end   -- heroes only: creeps fog constantly
    _vstore.events = _vstore.events + 1
    -- v0.1.355 DIAGNOSTIC (log-only, zero behaviour): g354 measured events=584 but tracked=0,
    -- so this gate was falsy on every single call while the SAME `Entity.IsDormant` reported
    -- fog=1..3 on the same probe line for handles out of `Heroes.GetAll`. The gitbook types
    -- them differently - `Entity.IsDormant(entity: CEntity)` vs `OnSetDormant(npc: CNPC)` - so
    -- the open question is whether the call is REJECTED (returns nil) or genuinely reads
    -- not-dormant at handler time (fires before the flag is applied). `false or nil` collapses
    -- exactly that distinction, so the result is captured in a local BEFORE any boolean op and
    -- recorded verbatim in the type key: the next log prints e.g. `0/nil:290` and answers it.
    local dorm
    if Entity and Entity.IsDormant then dorm = Entity.IsDormant(npc) end
    local k = tostring(dtype) .. "/" .. tostring(dorm)
    types[k] = (types[k] or 0) + 1
    -- v0.1.410 BUILD 2, THE FLIP (TINKER_FOG_TRACKER_DESIGN.md section 6): the LIVE stamp now
    -- rides the dtype, exactly like the shadow that validated it (g402+g403: tracker stamped
    -- both games, DISSOLVED 1 >= NEW-VETO 0, zero fresh-fog vetoes). dtype 1 = ENTERING
    -- dormancy, derived from g401 data with zero contradictions in 73 windows. The old
    -- if-dorm gate is DELETED: g401 proved Entity.IsDormant reads false inside this callback
    -- (the engine applies the flag after it), so it stamped nothing across 46 logs. dorm stays
    -- probed above ONLY for the types diagnostic, which is the instrument that would reveal an
    -- engine patch changing either surface. The shadow table keeps stamping so the build-1
    -- riders become a live self-check: prisk_sh must now EQUAL prisk on every logged pair.
    if tostring(dtype) == "1" then
        last_seen_sh[npc] = clock()
        last_seen[npc] = clock()
    end
end

---Seconds since this hero was last visible.
---nil is THE SAFETY VALVE: consumers apply their own default, and FogSnapshot's existing
---`or 0` turns nil into "fresh visible" - byte-for-byte the pre-vision behaviour. So an
---empty tracker (e.g. if OnSetDormant never fires) changes nothing anywhere.
---@param e userdata
---@return number|nil 0 when visible now; seconds since last seen; nil when never observed
function Vision.Age(e)
    if not e then return nil end
    if Entity and Entity.IsDormant and not Entity.IsDormant(e) then return 0 end
    local t = last_seen[e]
    if not t then return nil end
    local a = clock() - t
    return (a < 0) and 0 or a
end

---Raw stamp, diagnostics only.
---@param e userdata
---@return number|nil
function Vision.LastSeen(e)
    if not e then return nil end
    return last_seen[e]
end

---SHADOW twin of Age (v0.1.409 build 1): same contract, reading the dtype-gated shadow
---table. Consumed ONLY by Tinker's shadow-risk riders; Lina/Sniper never call it. KEPT
---through the v0.1.410 flip's validation as a live self-check (both tables now stamp on
---the same gate, so shadow must equal live on every logged pair); deletion candidate
---after v0.1.410 validates.
---@param e userdata
---@return number|nil 0 when visible now; seconds since the shadow stamp; nil when never seen
function Vision.AgeShadow(e)
    if not e then return nil end
    if Entity and Entity.IsDormant and not Entity.IsDormant(e) then return 0 end
    local t = last_seen_sh[e]
    if not t then return nil end
    local a = clock() - t
    return (a < 0) and 0 or a
end

---@return table { tracked = number, tracked_sh = number, events = number, types = table }
---`events` is the field that proves whether OnSetDormant fires at all. If it stays 0 in a
---real game, this whole facility is inert and every consumer is unchanged. tracked_sh
---(v0.1.409) is the SHADOW count: the build-1 health check that must climb with fog activity.
function Vision.Stats()
    local n = 0
    for _ in pairs(last_seen) do n = n + 1 end
    local nsh = 0
    for _ in pairs(last_seen_sh) do nsh = nsh + 1 end
    return { tracked = n, tracked_sh = nsh, events = _vstore.events, types = types }
end

---Idempotent; mirrors lib/damage.lua's Init contract.
function Vision.Init()
    if _vstore.inited then return end
    _vstore.inited = true
end

---Tables already wired. Weak keys so a dead hero table cannot pin memory. Lives in the
---STORE (aliased here) so wiring stays idempotent per table ACROSS cache-clear re-requires;
---and it lives lib-side rather than as a marker field on the caller's table on purpose:
---hero scripts iterate `pairs(callbacks)` to wrap every entry in a hero gate and then hand
---the table to UCZone for registration, so a stray non-function field would be wrapped as
---though it were a callback and registered as one.
local wired = _vstore.wired

---Chain the handler onto a hero's callbacks table, preserving any handler already there.
---Idempotent PER TABLE: three heroes wiring their own tables is correct and intended (the
---store singleton means they share the tracker, not the table), but wiring the SAME table
---twice must not double-fire.
---@param callbacks table
function Vision.Wire(callbacks)
    if not callbacks or wired[callbacks] then return end
    wired[callbacks] = true
    local prev = callbacks.OnSetDormant
    callbacks.OnSetDormant = function(...)
        if prev then prev(...) end
        Vision.OnSetDormant_handler(...)
    end
end

-- ============================================================================
-- (end of the VISION section; the escape module proper follows)
-- ============================================================================

local UO = Enum.UnitOrder

local Escape = {}

---Stateless danger score at a world position. Proximity-weighted
---count of visible enemy heroes near pos, with a turn-cost factor
---that biases toward landings forcing the enemy to TURN far from
---their current facing (the turn delay during chase is "free"
---distance for the defender).
---
---Per-enemy contribution:
---  base = (1 - d / 1400) * 30
---  turn_factor in [0, 1] (1 = enemy facing 180deg away from landing)
---  score += base * (1 - turn_factor * 0.5)   -- cap reduction at 50%
---
---Towers intentionally not counted - no clean enemy-tower-in-radius
---API and the hero-only term closes the documented blind spot.
---
---@param me userdata defender entity (for team lookup)
---@param pos userdata world position to score
---@return number score (higher = more dangerous; lower is safer)
function Escape.DangerAtPos(me, pos)
    if not me or not pos then return 0 end
    local list = Heroes.InRadius(pos, 1400, Entity.GetTeamNum(me),
                                 Enum.TeamType.TEAM_ENEMY)
    if not list then return 0 end
    local score = 0
    for i = 1, #list do
        local e = list[i]
        if e and Target.IsAlive(e) and Target.NotIllusion(e) then
            local ep = Entity.GetAbsOrigin(e)
            if ep then
                local d = pos:Distance2D(ep)
                if d < 1400 then
                    local base = (1 - d / 1400) * 30
                    local turn_factor = 0
                    if NPC.GetForwardVector then
                        local fwd = NPC.GetForwardVector(e)
                        if fwd then
                            local cdx, cdy = pos.x - ep.x, pos.y - ep.y
                            local clen = math.sqrt(cdx * cdx + cdy * cdy)
                            if clen > 1 then
                                local nx, ny = cdx / clen, cdy / clen
                                local dot = fwd.x * nx + fwd.y * ny
                                turn_factor = (1 - dot) * 0.5
                                if turn_factor < 0 then
                                    turn_factor = 0
                                elseif turn_factor > 1 then
                                    turn_factor = 1
                                end
                            end
                        end
                    end
                    score = score + base * (1 - turn_factor * 0.5)
                end
            end
        end
    end
    return score
end

---Validate a candidate landing as a save target. Checks:
---  (1) terrain traversability via GridNav.IsTraversableFromTo
---  (2) when a specific threat is known, dest must INCREASE distance
---      from that threat (avoids pushing the defender into the very
---      threat the save is meant to escape)
---  (3) centroid fallback via DangerAtPos when no specific threat is
---      known: a destination meaningfully more dangerous than the
---      current spot is rejected (margin = 12 against a ~30/enemy
---      scale, avoids flapping on a marginal diff).
---
---@param me userdata defender entity
---@param dest_pos userdata candidate landing
---@param threat_caster_hint userdata|nil specific threat caster, if known
---@param danger_now number|nil v0.5.83: precomputed DangerAtPos(me, me_pos),
---       supplied by PickDir once across all candidates so the current-spot
---       scan is not repeated per candidate. Falls back to a local scan if nil.
---@return userdata|nil dest_pos if safe, nil otherwise
---@return number|nil d_land v0.5.83: the landing danger computed by the
---       centroid branch, so PickDir can rank without re-scanning. nil on the
---       threat-hint branch (which does no danger scan).
function Escape.SafePushDestination(me, dest_pos, threat_caster_hint, danger_now)
    if not me or not dest_pos then return nil end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil end
    if not GridNav.IsTraversableFromTo(me_pos, dest_pos) then return nil end

    if threat_caster_hint and Entity.IsEntity(threat_caster_hint)
       and Target.IsAlive(threat_caster_hint) then
        local cp = Entity.GetAbsOrigin(threat_caster_hint)
        if not cp then return dest_pos end
        local d_now  = me_pos:DistanceSqr2D(cp)
        local d_dest = dest_pos:DistanceSqr2D(cp)
        if d_dest <= d_now then return nil end
        return dest_pos   -- threat-hint branch does no danger scan; d_land = nil
    end

    -- v0.5.83: compute the landing danger ONCE and return it so PickDir reuses
    -- it for ranking (it was re-scanning DangerAtPos(landing) a second time per
    -- candidate). danger_now (current-spot danger) is hoisted by the caller
    -- across all candidates; fall back to a local scan when not supplied.
    local d_land = Escape.DangerAtPos(me, dest_pos)
    local d_cur  = danger_now or Escape.DangerAtPos(me, me_pos)
    if d_land > d_cur + 12 then
        return nil
    end
    return dest_pos, d_land
end

---7-angle danger-aware escape destination picker. Tries angles
---{0, -35, 35, -65, 65, -90, 90} (degrees) off straight-away from
---toward_threat. Each candidate is gated by SafePushDestination +
---optional per-candidate filter, then ranked by DangerAtPos (lower
---is safer). Ties favor 0deg (straight-away baseline) via strict
---less-than - a marginal angle does not win over straight-away
---unless meaningfully safer.
---
---Returns (escape_dir, landing) where escape_dir is the unit vector
---FROM defender TO the chosen landing; (nil, nil) if every candidate
---failed terrain or the threat-distance gate.
---
---filter_fn(esc_dir, landing) -> bool runs AFTER SafePushDestination
---so callers' extra constraints (Sniper grenade's 120deg facing gate
---to a cast_point) only see candidates that already pass terrain +
---threat-distance. Returning false drops the candidate.
---
---@param me userdata defender entity
---@param me_pos userdata defender's current position
---@param toward_threat userdata unit vector FROM defender TOWARD threat
---@param push_distance number how far the save moves the defender
---@param threat_caster_hint userdata|nil specific threat, if known
---@param filter_fn fun(esc_dir:userdata, landing:userdata):boolean|nil
---@return userdata|nil escape_dir (unit vector)
---@return userdata|nil landing
function Escape.PickDir(me, me_pos, toward_threat, push_distance,
                        threat_caster_hint, filter_fn)
    if not me or not me_pos or not toward_threat or not push_distance then
        return nil, nil
    end
    -- v0.5.83: hoist the current-spot danger once (SafePushDestination was
    -- recomputing DangerAtPos(me_pos) for every candidate) and reuse the
    -- landing danger it now returns (was a 2nd DangerAtPos(landing) scan per
    -- candidate). Drops the no-hint path from ~21 to ~8 DangerAtPos scans for
    -- 7 candidates; threat-hint path is bit-identical (it returns no d_land,
    -- so ranking there still uses a direct DangerAtPos scan, as before).
    local danger_now = Escape.DangerAtPos(me, me_pos)
    local best_dir, best_landing, best_danger
    for _, deg in ipairs({ 0, -35, 35, -65, 65, -90, 90 }) do
        local rad = math.rad(deg)
        local c, s = math.cos(rad), math.sin(rad)
        local rx = toward_threat.x * c - toward_threat.y * s
        local ry = toward_threat.x * s + toward_threat.y * c
        local esc_dir = Vector(-rx, -ry, 0)
        local landing = me_pos + esc_dir * push_distance
        local safe, d_land = Escape.SafePushDestination(me, landing,
                                                         threat_caster_hint, danger_now)
        if safe and (not filter_fn or filter_fn(esc_dir, landing)) then
            local dng = d_land or Escape.DangerAtPos(me, landing)
            if not best_danger or dng < best_danger then
                best_danger, best_dir, best_landing = dng, esc_dir, landing
            end
        end
    end
    return best_dir, best_landing
end

---Derive a danger-aware escape destination for a self-displacement save.
---toward = unit-vector defender -> threat caster if known and alive;
---otherwise unit-vector defender -> centroid of enemy heroes within
---1500u. PickDir then picks the best of 7 angles off straight-away.
---
---Returns (escape_dir, landing) where landing = me_pos + escape_dir *
---push_dist. (nil, nil) when no toward direction exists (no caster, no
---nearby enemies) or when PickDir rejects every candidate.
---
---@param me userdata defender entity
---@param threat_caster userdata|nil specific threat, if known
---@param push_distance number how far the save moves the defender
---@return userdata|nil escape_dir
---@return userdata|nil landing
function Escape.ComputeSafeDest(me, threat_caster, push_distance, threat_pos)
    if not me or not push_distance then return nil, nil end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil, nil end
    local toward
    -- v0.5.130: threat_pos (optional Vector) is a PREDICTED threat position the
    -- hero supplies (state.predict_target_pos / smoothed velocity) so the escape
    -- pushes away from where a moving/charging threat is HEADING, not where it
    -- currently is -- else "away from a unit charging at me" points along its
    -- charge = TOWARD where it lands (the v0.5.129 WW lesson, generalised). A
    -- stationary threat predicts ~its current pos so this is a no-op for it.
    -- nil threat_pos -> live origin (Sniper + the WW recompute path: unchanged).
    local alive_caster = threat_caster and Entity.IsEntity(threat_caster)
                         and Target.IsAlive(threat_caster) or nil
    local cp = alive_caster and (threat_pos or Entity.GetAbsOrigin(threat_caster)) or nil
    if cp then
        local diff = cp - me_pos
        if diff:Length2DSqr() < 1 then return nil, nil end
        toward = diff:Normalized()
    else
        local enemies = Heroes.InRadius(me_pos, 1500, Entity.GetTeamNum(me),
                                        Enum.TeamType.TEAM_ENEMY)
        if enemies and #enemies > 0 then
            local cx, cy, n = 0, 0, 0
            for i = 1, #enemies do
                local ep = Entity.GetAbsOrigin(enemies[i])
                if ep then cx, cy, n = cx + ep.x, cy + ep.y, n + 1 end
            end
            if n > 0 then
                local cen = Vector(cx / n, cy / n, me_pos.z)
                local diff = cen - me_pos
                if diff:Length2DSqr() > 1 then toward = diff:Normalized() end
            end
        end
    end
    if not toward then return nil, nil end
    local escape_dir = Escape.PickDir(me, me_pos, toward, push_distance,
                                      threat_caster)
    if not escape_dir then return nil, nil end
    local landing = me_pos + escape_dir * push_distance
    return escape_dir, landing
end

---@class EscapeCfg
---@field safe_issue        fun(spec:table):boolean        @order.Issue wrapper with dedup + cast-verify
---@field issue_item_self   fun(intent:string, layer:string, item:userdata):boolean
---@field tlog              fun(level:integer, name:string, kv:table)
---@field now               fun():number                   @monotonic seconds (GlobalVars.GetCurTime in UCZone)
---@field uname             fun(ent:userdata):string       @short entity name for logs
---@field hero_key          string                         @"lina" / "sniper" / ...
---@field layer             string|nil                     @"def" if omitted
---@field item_get          fun(me:userdata, item_name:string):userdata|nil  @NPCLib.item adapter
---@field item_ready        fun(me:userdata, item_name:string):boolean       @NPCLib.item_ready adapter
---@field on_self_cast      fun(item_name:string, me:userdata)|nil           @optional post-cast hook (Pike's pike_reissue stamp)

---Shared self-push harness used by Pike + Force self-cast saves.
---Computes a danger-aware destination and either:
---  - fires the item immediately (Lina already facing within 30 deg of
---    the escape direction) and returns (nil, ok) - no pending to stash
---  - turns toward away_pt then arms a pending struct the caller stores
---    and feeds to Escape.SelfPushTick each frame. Returns (pending, ok)
---    where ok is the result of the turn MOVE issue.
---
---The 30 deg gate is on facing angle, not landing distance. NPC.FindRot-
---ationAngle returns RADIANS (see reference_uczone_api_gotchas); math.deg
---before the gate.
---
---Pike-specific behaviour (item_name == "item_hurricane_pike"): when
---cfg.on_self_cast is provided it fires right after a successful issue,
---so heroes that need the first-cast-drop pike_reissue stamp can install
---it without the lib knowing about Pike internals.
---
---@param me userdata defender entity
---@param intent string intent string for safe_issue dedup / cast_verify
---@param item userdata item ability handle
---@param item_name string canonical item_* name (controls tlog short name)
---@param push_dist number distance the cast will push (typically 600)
---@param threat_caster userdata|nil specific threat, if known
---@param cfg EscapeCfg hero-side callbacks
---@param threat_pos userdata|nil v0.5.130: optional PREDICTED threat position
---       (hero-supplied) so the push aims away from where a charging threat is
---       HEADING, not where it is. nil -> the caster's live origin (unchanged).
---@return table|nil pending struct to stash (nil = immediate fire or skip)
---@return boolean ok did the harness issue an action (cast OR turn)
function Escape.TrySelfPush(me, intent, item, item_name, push_dist,
                            threat_caster, cfg, threat_pos)
    if not (me and item and cfg) then return nil, false end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil, false end
    local escape_dir, _ = Escape.ComputeSafeDest(me, threat_caster, push_dist, threat_pos)
    if not escape_dir then return nil, false end
    local away_pt = Vector(me_pos.x + escape_dir.x * 400,
                           me_pos.y + escape_dir.y * 400, me_pos.z)
    local angle_ok, angle_rad = pcall(NPC.FindRotationAngle, me, away_pt)
    local angle = (angle_ok and angle_rad)
                  and math.deg(math.abs(angle_rad)) or 0
    local short = (item_name == "item_hurricane_pike") and "pike_self"
                  or "force_self"
    local tlog = cfg.tlog
    local layer = cfg.layer or "def"
    if angle <= 30 then
        local ok = cfg.issue_item_self(intent, layer, item)
        if ok and cfg.on_self_cast then cfg.on_self_cast(item_name, me) end
        if tlog then
            tlog(1, short .. "_fired", {
                angle = string.format("%.0f", angle), phase = "immediate",
            })
        end
        return nil, ok
    end
    local moved = cfg.safe_issue {
        hero = cfg.hero_key, layer = layer,
        intent = intent .. "_turnaway",
        order_type = UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        unit = me, position = away_pt,
    }
    local pending = {
        caster    = threat_caster,
        away_pt   = away_pt,
        deadline  = cfg.now() + 0.7,
        intent    = intent,
        item_name = item_name,
    }
    if tlog then
        tlog(1, short .. "_turnaway", {
            angle = string.format("%.0f", angle),
            caster = (threat_caster and cfg.uname
                      and cfg.uname(threat_caster)) or "centroid",
        })
    end
    return pending, moved
end

---Tick the self-push pending struct armed by Escape.TrySelfPush. Call
---once per frame from OnUpdateEx. Returns the updated pending (nil when
---fired / timed out / caster gone). Caller stashes the result back into
---its slot.
---
---Three exit paths from a non-nil pending:
---  - deadline elapsed -> emit *_turnaway_timeout, return nil
---  - caster died / TP'd -> silent drop, return nil
---  - facing within 30 deg AND item ready -> fire + emit *_fired, return nil
---  - facing still > 30 deg -> return pending (keep waiting)
---
---@param me userdata defender entity
---@param pending table|nil current pending struct (nil = nothing armed)
---@param cfg EscapeCfg hero-side callbacks
---@return table|nil updated pending (nil = consumed)
function Escape.SelfPushTick(me, pending, cfg)
    if not pending then return nil end
    if not me or not Target.IsAlive(me) then return nil end
    local short = (pending.item_name == "item_hurricane_pike")
                  and "pike_self" or "force_self"
    local tlog = cfg.tlog
    if cfg.now() > pending.deadline then
        if tlog then tlog(2, short .. "_turnaway_timeout", {}) end
        return nil
    end
    if pending.caster and not (Entity.IsEntity(pending.caster)
                               and Target.IsAlive(pending.caster)) then
        return nil
    end
    local angle_ok, angle_rad = pcall(NPC.FindRotationAngle, me,
                                       pending.away_pt)
    local angle = (angle_ok and angle_rad)
                  and math.deg(math.abs(angle_rad)) or 0
    if angle > 30 then return pending end
    local it = cfg.item_get and cfg.item_get(me, pending.item_name) or nil
    if it and cfg.item_ready and cfg.item_ready(me, pending.item_name) then
        local intent = (pending.intent or short) .. "_aligned"
        if cfg.issue_item_self(intent, cfg.layer or "def", it) then
            if cfg.on_self_cast then
                cfg.on_self_cast(pending.item_name, me)
            end
            if tlog then
                tlog(1, short .. "_fired", {
                    angle = string.format("%.0f", angle), phase = "turned",
                })
            end
        end
    end
    return nil
end

---Queue a danger-aware MOVE_TO_POSITION to land Lina at a safe spot
---after an airborne save (EUL, WW). Cast happens BEFORE this call;
---this only stages the post-cast movement.
---
---Two layers of survival against baseline orbwalker preemption:
---  1. Belt: queue=true MOVE_TO_POSITION issued here. If the engine
---     honours it across airborne, Lina starts walking the instant she
---     lands.
---  2. Suspenders: returns a pending struct the caller feeds to
---     Escape.PostAirborneMoveTick. The tick re-issues MOVE_TO_POSITION
---     every ~100ms with a unique intent (bypasses safe_issue dedup) so
---     the brain's order dominates the most-recent-order tiebreaker
---     against baseline USER MOVEs.
---
---moves_during_airborne switches tick semantics:
---  true (WW per Liquipedia: 300 MS fixed, free pathing) -> reissue
---       WHILE the modifier is present; Lina travels mid-lift.
---  false (EUL per Liquipedia: full disable, no horizontal movement)
---        -> defer reissues until the modifier clears; orders during
---        the disable would no-op.
---
---Returns nil when no safe destination exists (Lina lands in place;
---the save still served its purpose by surviving the threat).
---
---@param me userdata defender entity
---@param intent string intent prefix (intent .. "_post_move" is the tlog)
---@param push_dist number distance the post-airborne walk should cover
---@param threat_caster userdata|nil specific threat, if known
---@param modifier_name string airborne modifier (e.g. "modifier_eul_cyclone")
---@param moves_during_airborne boolean see above
---@param cfg EscapeCfg hero-side callbacks
---@return table|nil pending struct to stash (nil = no safe dest)
function Escape.QueueSafePostMove(me, intent, push_dist, threat_caster,
                                  modifier_name, moves_during_airborne, cfg)
    if not (me and cfg) then return nil end
    local _, landing = Escape.ComputeSafeDest(me, threat_caster, push_dist)
    if not landing then return nil end
    cfg.safe_issue {
        hero = cfg.hero_key, layer = cfg.layer or "def",
        intent = intent .. "_post_move",
        order_type = UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        unit = me, position = landing,
        queue = true,
    }
    local pending = {
        dest                  = landing,
        modifier_name         = modifier_name,
        moves_during_airborne = moves_during_airborne or false,
        deadline              = cfg.now() + 7.0,
        intent                = intent,
        observed_airborne     = false,
        last_reissue_t        = 0,
        reissue_seq           = 0,
        -- v0.5.129: retained so PostAirborneMoveTick can RECOMPUTE the dest from
        -- the threat's live position each re-issue (the cast-time `landing` is a
        -- snapshot -- wrong for a through-dash like Primal Onslaught; see the tick).
        threat_caster         = threat_caster,
        push_dist             = push_dist,
    }
    if cfg.tlog then
        cfg.tlog(1, intent .. "_post_move", {
            x = string.format("%.0f", landing.x),
            y = string.format("%.0f", landing.y),
            caster = (threat_caster and cfg.uname
                      and cfg.uname(threat_caster)) or "centroid",
            movable = (moves_during_airborne and "y") or "n",
        })
    end
    return pending
end

---Tick the post-airborne move pending struct armed by Escape.QueueSafe-
---PostMove. Call once per frame from OnUpdateEx. Three phases:
---  1. Wait for the airborne modifier to appear at least once (cast
---     takes a few frames to resolve into the modifier; without this
---     latch the tick fires MOVE before the cast lands).
---  2. While airborne AND moves_during_airborne=false -> defer.
---  3. Airborne ended OR moves_during_airborne=true -> reissue MOVE_TO_
---     POSITION every ~100ms until Lina is within 100u of dest OR the
---     7s deadline expires. Unique intent each call (intent .. "_post_
---     move_fire_" .. seq) bypasses safe_issue's identifier dedup.
---
---Returns the updated pending (nil when arrived / expired / Lina died).
---
---@param me userdata defender entity
---@param pending table|nil current pending struct (nil = nothing armed)
---@param cfg EscapeCfg hero-side callbacks
---@return table|nil updated pending (nil = consumed)
function Escape.PostAirborneMoveTick(me, pending, cfg)
    if not pending then return nil end
    if not me or not Target.IsAlive(me) then return nil end
    local tlog = cfg.tlog
    if cfg.now() > pending.deadline then
        if tlog then
            tlog(2, pending.intent .. "_post_move_expired",
                 { reissues = pending.reissue_seq or 0 })
        end
        return nil
    end
    local airborne = NPC.HasModifier
                     and NPC.HasModifier(me, pending.modifier_name) or false
    if airborne then
        pending.observed_airborne = true
        if not pending.moves_during_airborne then return pending end
    elseif not pending.observed_airborne then
        return pending
    elseif pending.moves_during_airborne then
        -- v0.5.131: WW (moves_during_airborne) airborne has ENDED -> STOP. The
        -- reposition happens DURING the cyclone; once it lapses, continuing to
        -- re-issue MOVE on the ground drags Lina under brain control toward a
        -- (recompute-drifting) dest for up to the 7s deadline, overriding the
        -- player long after WW is gone (user-reported; the v0.5.129 recompute
        -- made the dest rarely "arrive" so it ran to the deadline). Hand control
        -- back now -- the normal escape/combo logic resumes next tick. Eul
        -- (moves_during_airborne=false) still falls through to its single
        -- post-airborne reposition move (it cannot move while airborne).
        if tlog then
            tlog(1, pending.intent .. "_post_move_landed",
                 { reissues = pending.reissue_seq or 0 })
        end
        return nil
    end
    local me_pos = Entity.GetAbsOrigin(me)
    if me_pos then
        local dx = me_pos.x - pending.dest.x
        local dy = me_pos.y - pending.dest.y
        if (dx * dx + dy * dy) < (100 * 100) then
            if tlog then
                tlog(1, pending.intent .. "_post_move_arrived", {
                    reissues = pending.reissue_seq or 0,
                    x = string.format("%.0f", me_pos.x),
                    y = string.format("%.0f", me_pos.y),
                })
            end
            return nil
        end
    end
    if (cfg.now() - (pending.last_reissue_t or 0)) < 0.1 then
        return pending
    end
    pending.last_reissue_t = cfg.now()
    pending.reissue_seq    = (pending.reissue_seq or 0) + 1
    -- v0.5.129: recompute the safe dest from the threat's LIVE position each
    -- re-issue. The cast-time dest is a snapshot; for a THROUGH-dash (Primal
    -- Onslaught) the caster is mid-approach at WW-cast, so "away from his current
    -- position" points along the dash = toward where he LANDS, sending Lina
    -- TOWARD him (user-reported). Recomputing self-corrects: once the dasher
    -- passes Lina and lands, the away-direction flips and Lina retreats from his
    -- final position. Lina is airborne (untargetable) the whole window, so the
    -- brief pre-flip drift is harmless. nil (threat dead / degenerate / on top of
    -- Lina) keeps the prior dest. Only Lina drives this tick (Sniper uses
    -- TrySelfPush), so this does not touch Sniper.
    -- v0.5.16x Phase B: pluggable recompute. A hero-supplied recompute_dest (FC-escape
    -- uses SafestSpotNear, terrain-aware) overrides the default ComputeSafeDest
    -- directional recompute. Back-compat: WW/Eul set neither, so the elseif path is
    -- unchanged for them.
    if pending.recompute_dest then
        local nd = pending.recompute_dest()
        if nd then pending.dest = nd end
    elseif pending.threat_caster and pending.push_dist then
        local _, new_dest = Escape.ComputeSafeDest(me, pending.threat_caster, pending.push_dist)
        if new_dest then pending.dest = new_dest end
    end
    cfg.safe_issue {
        hero = cfg.hero_key, layer = cfg.layer or "def",
        intent = pending.intent .. "_post_move_fire_" .. pending.reissue_seq,
        order_type = UO.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        unit = me, position = pending.dest,
    }
    if pending.reissue_seq == 1 and tlog then
        tlog(1, pending.intent .. "_post_move_fired", {
            x = string.format("%.0f", pending.dest.x),
            y = string.format("%.0f", pending.dest.y),
        })
    end
    return pending
end

----------------------------------------------------------------------------
-- v0.5.76: PIKE-ADVANCE RISK ANALYSIS (offensive counterpart to ComputeSafeDest)
----------------------------------------------------------------------------
---
---ComputeSafeDest answers "where should I escape TO" (away from threat).
---ComputeAdvanceDest answers the inverse: "is it safe to push TOWARD this
---enemy, and where do I land if I do". Built for Pike self-cast offensive
---use (push 600u along facing-toward-target) but the geometry helper is
---reusable for any directional push (Force Staff offensive, etc).
---
---Risk includes BOTH visible enemies near the landing AND fog enemies whose
---probable-position cone (last-known-pos + max travel since last seen)
---overlaps the landing. The fog component answers the user's specific ask:
---"check up for possible heroes on the fog might be on PI last seen
---enemies". Uses Hero.GetLastMaphackPos + Hero.GetLastVisibleTime per
---API_GOTCHAS: nil GetLastVisibleTime means never-fogged (fresh visible),
---treated as age=0.

---Max enemy move speed cap for fog probable-radius growth. 700 = generous
---ceiling for any hero with movement items / talents / haste. Going much
---higher just makes the cone meaningless (after 10s any fog enemy could be
---"anywhere within 7000u" which scores every landing identically). 30s cap
---on age keeps the radius bounded even for very-stale-fog enemies.
local PROBE_MAX_MS = 700
local PROBE_MAX_AGE_S = 30

---v0.5.77: shared per-call snapshot of ALL enemy heroes (visible + fog).
---Extracted from NearbyEnemiesIncludingFog so multiple consumers (Pike-
---advance risk, gank-inbound check, rotation tracker, initiator probe,
---safest-spot grid picker) reuse one scan instead of each running their
---own. Callers can pass opts.snapshot to consumer functions to share a
---snapshot across calls within a frame.
---
---For visible enemies: pos = Entity.GetAbsOrigin (true current), age = 0,
---probable_radius = 0, visible = true.
---
---For fog enemies: pos = Hero.GetLastMaphackPos (last known), age =
---now - Hero.GetLastVisibleTime (clamped to [0, 30s]), probable_radius =
---age * max_ms (700 cap), visible = false. last_pos_known = false when
---Hero.GetLastMaphackPos returns nil (never-seen hero; the entry is
---excluded since we have no position to reason about).
---
---API gotcha (per API_GOTCHAS): Hero.GetLastVisibleTime returns nil for
---never-fogged heroes (demo bots, freshly spawned). nil is NOT a veto;
---treated as age = 0 "fresh visible".
---
---Dormant check: Entity.IsDormant(e) is the canonical "currently not
---visible to our team" predicate. Falls back to "no entry in
---Heroes.InRadius's omitDormant=true scan" if Entity.IsDormant absent.
---
---@param me userdata
---@param opts table|nil {max_ms=700, now=fn()->seconds}
---@return table snapshot {t = number, heroes = {{entity, pos, age, probable_radius, visible}}}
function Escape.FogSnapshot(me, opts)
    opts = opts or {}
    local max_ms = opts.max_ms or PROBE_MAX_MS
    local now_fn = opts.now or function() return GlobalVars.GetCurTime() end
    local t = now_fn()
    if not me then return { t = t, heroes = {} } end
    local team = Entity.GetTeamNum(me)
    local heroes = {}
    if not Heroes.GetAll then return { t = t, heroes = heroes } end
    local all = Heroes.GetAll() or {}
    for i = 1, #all do
        local e = all[i]
        if e and Entity.GetTeamNum(e) ~= team
           and Target.IsAlive(e) and Target.NotIllusion(e) then
            local visible
            if Entity.IsDormant then
                visible = not Entity.IsDormant(e)
            else
                visible = true  -- conservative: assume visible if API missing
            end
            local pos
            if visible then
                pos = Entity.GetAbsOrigin(e)
            else
                pos = Hero.GetLastMaphackPos and Hero.GetLastMaphackPos(e) or nil
            end
            if pos then
                local age, probable_radius = 0, 0
                if not visible then
                    -- v0.1.354: was `Hero.GetLastVisibleTime`, which is DEAD - measured nil
                    -- on 405 of 405 fogged reads in one 895s match (Tinker g353), so this
                    -- line produced age 0 ALWAYS and the whole COR-1 decay below it has
                    -- never run. The Vision section above owns its clock, so the old cross-clock
                    -- subtraction against `t` is gone with it (that mismatch - DOTA clock
                    -- minus engine clock - was the red herring that consumed a whole arc).
                    -- nil still means "never observed", and `or 0` turns that into
                    -- "fresh visible": byte-for-byte the pre-vision behaviour, so an inert
                    -- tracker changes nothing for any hero.
                    age = Vision.Age(e) or 0
                    if age < 0 then age = 0 end
                    if age > PROBE_MAX_AGE_S then age = PROBE_MAX_AGE_S end
                    probable_radius = age * max_ms
                end
                heroes[#heroes + 1] = {
                    entity = e,
                    pos = pos,
                    age = age,
                    probable_radius = probable_radius,
                    visible = visible,
                }
            end
        end
    end
    return { t = t, heroes = heroes }
end

---SHADOW-AGED copy of a FogSnapshot (v0.1.409 build 1, TINKER_FOG_TRACKER_DESIGN.md):
---same rows, same positions, ages re-read from the dtype-gated shadow tracker with the
---same PROBE_MAX_AGE_S clamp as the live path above. Defined HERE, below the Vision
---section banner, so the clamp constant is shared instead of duplicated. probable_radius
---is deliberately NOT carried: FogProximityRisk recomputes radius from age (its own doc
---says so) and nothing else consumes the shadow copy. The input snapshot is never
---mutated. KEPT through the v0.1.410 flip's validation as a live self-check alongside
---AgeShadow; deletion candidate after v0.1.410 validates.
---@param snap table  a FogSnapshot return value
---@return table      { t, heroes = { {entity, pos, age, visible} } }
function Vision.ShadowAges(snap)
    if not snap or not snap.heroes then return snap end
    local heroes = {}
    for i = 1, #snap.heroes do
        local h = snap.heroes[i]
        local age = 0
        if not h.visible then
            age = Vision.AgeShadow(h.entity) or 0
            if age < 0 then age = 0 end
            if age > PROBE_MAX_AGE_S then age = PROBE_MAX_AGE_S end
        end
        heroes[i] = { entity = h.entity, pos = h.pos, age = age, visible = h.visible }
    end
    return { t = snap.t, heroes = heroes }
end

---Enumerate enemy heroes whose CURRENT possible position could be within
---`radius` of `pos`. Visible enemies always count (age = 0, probable_radius
---= 0). Fogged enemies count when (probable_radius + dist(last_pos, pos))
---<= radius, i.e. the probable-position circle reaches the engage zone.
---
---v0.5.77 refactor: now consumes Escape.FogSnapshot. Pass
---opts.snapshot to share a snapshot across multiple calls in one frame
---(SafestSpotNear uses this to run 9 grid samples against one scan).
---External API unchanged.
---
---Returns a unified list so callers can score visible and fog with
---different weights (see AdvanceRiskScore).
---
---@param me userdata defender / advancer entity (team-membership lookup only)
---@param pos userdata position to score around
---@param radius number engagement radius (e.g. 800 for Pike landing risk)
---@param opts table|nil {max_ms=700, now=fn, snapshot=table}
---@return integer visible_count
---@return integer fog_count
---@return table list of {entity, last_pos, age, probable_radius, visible}
function Escape.NearbyEnemiesIncludingFog(me, pos, radius, opts)
    if not (me and pos and radius) then return 0, 0, {} end
    opts = opts or {}
    local snap = opts.snapshot or Escape.FogSnapshot(me, opts)
    local out, v_cnt, f_cnt = {}, 0, 0
    for i = 1, #snap.heroes do
        local h = snap.heroes[i]
        local d = pos:Distance2D(h.pos)
        if h.visible then
            if d <= radius then
                v_cnt = v_cnt + 1
                out[#out + 1] = {
                    entity = h.entity, last_pos = h.pos, age = 0,
                    probable_radius = 0, visible = true,
                }
            end
        else
            if d <= h.probable_radius + radius then
                f_cnt = f_cnt + 1
                out[#out + 1] = {
                    entity = h.entity, last_pos = h.pos,
                    age = h.age, probable_radius = h.probable_radius,
                    visible = false,
                }
            end
        end
    end
    return v_cnt, f_cnt, out
end

---Count FOGGED enemies whose FRESH probable-disc reaches within opts.radius of
---`pos`. Tighter than NearbyEnemiesIncludingFog: only enemies seen within
---opts.fresh_s count, and the disc reach is capped at opts.reach_cap (a stale
---blip's huge disc is rejected, not trusted). Pure: component math on pos.x/.y,
---so plain {x,y} tables work (the type-boundary law).
---@param snapshot table {heroes = {{pos, age, probable_radius, visible}}}
---@param pos table {x, y}
---@param opts table {radius=1000, reach_cap=450, fresh_s=1.5}
---@return integer count
function Escape.ReachableFog(snapshot, pos, opts)
    local hs = snapshot and snapshot.heroes
    if not (hs and pos) then return 0 end
    opts = opts or {}
    local radius  = opts.radius or 1000
    local cap     = opts.reach_cap or 450
    local fresh_s = opts.fresh_s or 1.5
    local n = 0
    for i = 1, #hs do
        local h = hs[i]
        if h.visible == false and (h.age or 0) <= fresh_s and h.pos then
            local dx, dy = (h.pos.x or 0) - (pos.x or 0), (h.pos.y or 0) - (pos.y or 0)
            local d = math.sqrt(dx * dx + dy * dy)
            local disc = math.min(h.probable_radius or 0, cap)
            if d - disc <= radius then n = n + 1 end
        end
    end
    return n
end

---Composite risk score for a candidate landing position. Lower is safer;
---0 = no enemies in or near the engage radius.
---
---Components:
---  visible_score: for each visible enemy in engage_radius, add
---    (1 - dist/engage_radius) * 30  -- max 30 per enemy at zero distance
---  fog_score: 15 per fog enemy whose probable-position circle overlaps
---    engage_radius (half-weighted -- uncertainty discount).
---
---Default engage_radius = 800u (typical Pike-landing follow-up range).
---Suggested threshold: <= 30 safe-to-advance, 30-60 risky-but-survivable,
--->60 abort. Caller picks the threshold; lib only scores.
---
---@param me userdata
---@param landing userdata candidate position
---@param opts table|nil {engage_radius=800, max_ms=700, now=fn}
---@return number score
---@return table breakdown {visible_score, fog_score, visible_count, fog_count, engage_radius, enemies}
function Escape.AdvanceRiskScore(me, landing, opts)
    if not (me and landing) then
        return math.huge, { visible_score = 0, fog_score = 0,
                            visible_count = 0, fog_count = 0,
                            engage_radius = 0, enemies = {} }
    end
    opts = opts or {}
    local engage_radius = opts.engage_radius or 800
    -- v0.5.77: opts.snapshot propagates through so SafestSpotNear can
    -- run 9 grid samples against one shared snapshot. If not provided,
    -- NearbyEnemiesIncludingFog computes its own.
    local v_cnt, f_cnt, list =
        Escape.NearbyEnemiesIncludingFog(me, landing, engage_radius, opts)
    local visible_score, fog_score = 0, 0
    for i = 1, #list do
        local e = list[i]
        if e.visible then
            local d = landing:Distance2D(e.last_pos)
            local frac = d / engage_radius
            if frac > 1 then frac = 1 end
            visible_score = visible_score + (1 - frac) * 30
        else
            fog_score = fog_score + 15
        end
    end
    return visible_score + fog_score, {
        visible_score = visible_score,
        fog_score     = fog_score,
        visible_count = v_cnt,
        fog_count     = f_cnt,
        engage_radius = engage_radius,
        enemies       = list,
    }
end

---Count enemies currently fogged (alive but not visible) in a FogSnapshot. The
---pro "is a deep raid safe" lever: <=1 missing of 5 -> safe. PURE.
---@param snapshot table|nil  FogSnapshot result { heroes = {...} }
---@return number
function Escape.MissingCount(snapshot)
    local hs = snapshot and snapshot.heroes
    if not hs then return 0 end
    local n = 0
    for i = 1, #hs do if hs[i].visible == false then n = n + 1 end end
    return n
end

---v0.x (COR-1): continuous fog-aware proximity risk in [0,1] = the max over
---enemies of a distance falloff. A recently-fogged enemy is modeled as a
---growing-but-decaying reachable disc: the disc radius grows with age
---(reachability) while the risk it contributes decays as it spreads
---(uncertainty). Visible enemies and just-vanished fog (age 0) reduce to
---(1 - dist/risk_radius)^2 -- identical to a plain nearest-enemy proximity
---risk, so consumers see no change for visible foes.
---
---@param snapshot_or_me table|userdata a FogSnapshot ({heroes=...}) to reuse,
---  or an entity (FogSnapshot is then called internally)
---@param pt userdata position to score (needs :Distance2D)
---@param opts table|nil {risk_radius=1400, fog_ms=550, fog_spread=900,
---  age_cap=5, now, max_ms}. fog_ms = disc-growth rate (Liquipedia move cap);
---  radius is recomputed from age here (NOT the snapshot's probable_radius) so
---  fog_ms and the snapshot's max_ms cannot silently diverge.
---@return number risk 0..1
function Escape.FogProximityRisk(snapshot_or_me, pt, opts)
    if not pt then return 0 end
    opts = opts or {}
    local risk_radius = opts.risk_radius or 1400
    local fog_ms      = opts.fog_ms or 550
    local fog_spread  = opts.fog_spread or 900
    local age_cap     = opts.age_cap or 5
    local snap
    if type(snapshot_or_me) == "table" and snapshot_or_me.heroes then
        snap = snapshot_or_me
    else
        snap = Escape.FogSnapshot(snapshot_or_me, opts)
    end
    -- component math, not pt:Distance2D: pt crosses the hero->lib boundary and callers have
    -- passed plain {x,y} tables (the v0.1.247 stuck-in-DECIDE crash, found by a field tester);
    -- .x/.y math accepts both plain tables and engine Vectors, and keeps this fn engine-free.
    local function d2(a, b) local dx, dy = a.x - b.x, a.y - b.y return math.sqrt(dx * dx + dy * dy) end
    local best = 0
    for i = 1, #snap.heroes do
        local h = snap.heroes[i]
        local edge, conf
        if h.visible then
            edge, conf = d2(pt, h.pos), 1
        elseif h.age <= age_cap then
            local radius = h.age * fog_ms
            edge = d2(pt, h.pos) - radius
            if edge < 0 then edge = 0 end
            conf = fog_spread / (fog_spread + radius)
        end
        if edge then
            local base = 0
            if edge < risk_radius then
                local r = 1 - edge / risk_radius
                base = r * r
            end
            local risk_e = base * conf
            if opts.weight_fn then risk_e = risk_e * (opts.weight_fn(h) or 1) end
            if risk_e > best then best = risk_e end
        end
    end
    return best
end

---Deterministic Pike self-cast landing for an OFFENSIVE advance: Lina
---fires Pike facing toward target_pos, lands push_dist units along that
---facing. Geometry is the same for any directional self-push item (Force
---Staff offensive, future displacement items). Pike push_dist is 600u.
---
---Returns nil when me_pos == target_pos (zero direction; can't pick a
---facing).
---
---@param me_pos userdata defender position
---@param target_pos userdata target position to advance toward
---@param push_dist number distance the item will push (Pike = 600)
---@return userdata|nil landing
function Escape.PikeAdvanceLanding(me_pos, target_pos, push_dist)
    if not (me_pos and target_pos and push_dist and push_dist > 0) then
        return nil
    end
    local diff = target_pos - me_pos
    if diff:Length2DSqr() < 1 then return nil end
    local dir = diff:Normalized()
    return me_pos + dir * push_dist
end

---Pike-advance pick: compute landing for a self-cast Pike toward `target`,
---score risk, return (landing, score, breakdown) for caller to decide
---fire / skip. Returns (nil, nil, nil) when target invalid or zero
---direction. Lib does NOT issue any orders -- this is a pure decision-
---support primitive.
---
---target may be a hero entity (userdata, IsAlive-checked) or a Vector
---world position; the function dispatches accordingly.
---
---Pairs naturally with the AdvanceRiskScore threshold check:
---  local landing, score, brk = Escape.ComputeAdvanceDest(me, hero, 600)
---  if landing and score <= 30 then  -- caller-chosen threshold
---      fire_pike_self()
---  end
---
---@param me userdata
---@param target userdata|userdata entity (hero) OR Vector position
---@param push_dist number typically 600 for Pike
---@param opts table|nil see AdvanceRiskScore
---@return userdata|nil landing
---@return number|nil score
---@return table|nil breakdown
function Escape.ComputeAdvanceDest(me, target, push_dist, opts)
    if not (me and target and push_dist) then return nil, nil, nil end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil, nil, nil end
    local target_pos
    if type(target) == "userdata"
       and Entity.IsEntity and Entity.IsEntity(target) then
        if not (Target.IsAlive and Target.IsAlive(target)) then
            return nil, nil, nil
        end
        target_pos = Entity.GetAbsOrigin(target)
    else
        target_pos = target
    end
    if not target_pos then return nil, nil, nil end
    local landing = Escape.PikeAdvanceLanding(me_pos, target_pos, push_dist)
    if not landing then return nil, nil, nil end
    local score, breakdown = Escape.AdvanceRiskScore(me, landing, opts)
    return landing, score, breakdown
end

-- v0.5.16x Phase C: pure chase window. Given Lina pos, the target pos + velocity, and gathered
-- protection circles, return the straight-line catch-ETA and the escape-ETA (min of out-of-kill-reach
-- and reaching protection). Hero-agnostic, no engine calls (positions/vel passed in) -> offline-tested.
-- FC grants no speed bonus (Liquipedia): fly_speed = the chaser's base MS; the value is the terrain shortcut.
--   me_pos, target_pos: {x,y,z}; vel: {x,y} world units/sec; opts = { fly_speed, kill_reach, tower_circles }
-- Returns { catch_eta, escape_eta, intercept, reason } or nil.
local function _exit_radius_eta(p, v, c, R)
    -- earliest t>=0 with |p + v t - c| = R, growing past R. Quadratic |d + v t|^2 = R^2, d = p - c.
    local dx, dy = p.x - c.x, p.y - c.y
    local a = v.x * v.x + v.y * v.y
    if a < 1e-9 then return math.huge end          -- not moving -> never exits
    local b = 2 * (dx * v.x + dy * v.y)
    local cc = dx * dx + dy * dy - R * R
    if cc >= 0 then return 0 end                    -- already outside
    local disc = b * b - 4 * a * cc
    if disc < 0 then return math.huge end
    local t = (-b + math.sqrt(disc)) / (2 * a)      -- larger root = the outward crossing
    return (t >= 0) and t or math.huge
end
local function _enter_radius_eta(p, v, c, R)
    -- earliest t>=0 with |p + v t - c| <= R (entering). Smaller root.
    local dx, dy = p.x - c.x, p.y - c.y
    if dx * dx + dy * dy <= R * R then return 0 end  -- already inside
    local a = v.x * v.x + v.y * v.y
    if a < 1e-9 then return math.huge end
    local b = 2 * (dx * v.x + dy * v.y)
    local cc = dx * dx + dy * dy - R * R
    local disc = b * b - 4 * a * cc
    if disc < 0 then return math.huge end
    local t = (-b - math.sqrt(disc)) / (2 * a)       -- smaller root = the inward crossing
    return (t >= 0) and t or math.huge
end
function Escape.ChaseWindow(me_pos, target_pos, vel, opts)
    if not (me_pos and target_pos and vel and opts) then return nil end
    local fly_speed = opts.fly_speed or 300
    if fly_speed < 1e-6 then return nil end
    local dx, dy = target_pos.x - me_pos.x, target_pos.y - me_pos.y
    local catch_eta = math.sqrt(dx * dx + dy * dy) / fly_speed
    local escape_eta = _exit_radius_eta(target_pos, vel, me_pos, opts.kill_reach or 1000)
    if opts.tower_circles then
        for i = 1, #opts.tower_circles do
            local tc = opts.tower_circles[i]
            local e = _enter_radius_eta(target_pos, vel, tc.pos, tc.range)
            if e < escape_eta then escape_eta = e end
        end
    end
    return { catch_eta = catch_eta, escape_eta = escape_eta, intercept = target_pos, reason = "ok" }
end

-- v0.5.163 Phase C2: pure cutoff discriminator. Given the chaser pos, the intercept, and the WALK path
-- (a GridNav.BuildPath result passed in -> engine-free, offline-testable), decide whether the straight FC
-- flight is a meaningful shortcut over the walk that detours around terrain/trees. The straight flight is
-- the whole value of FC chase (FC = unobstructed movement at base MS, no speed).
--   me_pos, intercept: {x,y[,z]}; walk_path: array of {x,y} waypoints (>=2) or nil.
--   opts = { ratio (default 1.3), min_gain (default 250) }.
-- Returns { locked, walk, straight, ratio }.
function Escape.CutoffLock(me_pos, intercept, walk_path, opts)
    opts = opts or {}
    local ratio_thresh = opts.ratio or 1.3
    local min_gain = opts.min_gain or 250
    if not (me_pos and intercept) then return { locked = false, walk = 0, straight = 0, ratio = 0 } end
    local sdx, sdy = intercept.x - me_pos.x, intercept.y - me_pos.y
    local straight = math.sqrt(sdx * sdx + sdy * sdy)
    if not (walk_path and #walk_path >= 2) then
        return { locked = false, walk = straight, straight = straight, ratio = 1 }
    end
    local walk = 0
    for i = 1, #walk_path - 1 do
        local a, b = walk_path[i], walk_path[i + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        walk = walk + math.sqrt(dx * dx + dy * dy)
    end
    local r = (straight > 1e-6) and (walk / straight) or 1
    local locked = (walk >= straight * ratio_thresh) and ((walk - straight) >= min_gain)
    return { locked = locked, walk = walk, straight = straight, ratio = r }
end

----------------------------------------------------------------------------
-- v0.5.77: FOG-AWARE CONSUMERS (gank / rotation / initiator / safest-spot)
----------------------------------------------------------------------------
---
---All four consumers read from FogSnapshot. Caller may pass opts.snapshot
---to share one scan across calls. None of them issue orders -- pure
---decision support. Hero scripts thin-alias these via state.* for HUD /
---combo gates / future auto-actions.

---List enemy heroes who could be at `pos` within `eta_s` seconds.
---Each entry: time_to_reach computed as:
---  visible: dist / max_ms                       (walks straight at max speed)
---  fog:     max(0, dist / max_ms - age)         (already moved closer for `age` seconds worst-case)
---
---Sorted by eta_seconds ascending so summary.soonest_eta = result.gankers[1].eta_seconds.
---
---Default opts: max_ms = 700 (matches FogSnapshot). Caller-overridable.
---
---@param me userdata
---@param pos userdata position to evaluate (typically me's position or a candidate destination)
---@param eta_s number arrival horizon in seconds (gank-window)
---@param opts table|nil {max_ms=700, now=fn, snapshot=table}
---@return table result {gankers={{entity, eta_seconds, dist, visibility, age}}, summary={count, soonest_eta, eta_s, max_ms}}
function Escape.PossibleGankers(me, pos, eta_s, opts)
    if not (me and pos and eta_s) then
        return { gankers = {}, summary = { count = 0,
                 soonest_eta = math.huge, eta_s = eta_s or 0,
                 max_ms = (opts and opts.max_ms) or PROBE_MAX_MS } }
    end
    opts = opts or {}
    local max_ms = opts.max_ms or PROBE_MAX_MS
    local snap = opts.snapshot or Escape.FogSnapshot(me, opts)
    local gankers = {}
    for i = 1, #snap.heroes do
        local h = snap.heroes[i]
        local d = pos:Distance2D(h.pos)
        local time_to_reach
        if h.visible then
            time_to_reach = d / max_ms
        else
            time_to_reach = d / max_ms - h.age
            if time_to_reach < 0 then time_to_reach = 0 end
        end
        if time_to_reach <= eta_s then
            gankers[#gankers + 1] = {
                entity      = h.entity,
                eta_seconds = time_to_reach,
                dist        = d,
                visibility  = h.visible and "visible" or "fog",
                age         = h.age,
            }
        end
    end
    table.sort(gankers, function(a, b) return a.eta_seconds < b.eta_seconds end)
    local soonest = (gankers[1] and gankers[1].eta_seconds) or math.huge
    return {
        gankers = gankers,
        summary = {
            count       = #gankers,
            soonest_eta = soonest,
            eta_s       = eta_s,
            max_ms      = max_ms,
        },
    }
end

---Convenience predicate: are at least `min_count` enemies arrivable at
---`pos` within `eta_s` seconds. Default min_count = 2 (common "2-man gank"
---signal). Returns the boolean + the ganker list so the caller can read
---the breakdown for HUD / tlog purposes.
---
---@param me userdata
---@param pos userdata
---@param eta_s number
---@param min_count integer|nil default 2
---@param opts table|nil same as PossibleGankers
---@return boolean imminent
---@return table gankers list (sorted by eta)
function Escape.GankImminent(me, pos, eta_s, min_count, opts)
    local result = Escape.PossibleGankers(me, pos, eta_s, opts)
    return result.summary.count >= (min_count or 2), result.gankers
end

---Rotation tracker: list of enemy heroes who have been off-minimap for
---at least `min_age_s` seconds. Returns {entity, age, last_pos} sorted
---by age descending (longest-missing first). Useful for "mid is missing
---5s, defend tier-2" heuristics + HUD chips.
---
---Default min_age_s = 5.0. Visible enemies excluded (age = 0).
---
---@param me userdata
---@param min_age_s number|nil default 5.0
---@param opts table|nil {max_ms=700, now=fn, snapshot=table}
---@return table missing list {{entity, age, last_pos}} sorted by age desc
function Escape.MissingFromMap(me, min_age_s, opts)
    if not me then return {} end
    opts = opts or {}
    local threshold = min_age_s or 5.0
    local snap = opts.snapshot or Escape.FogSnapshot(me, opts)
    local missing = {}
    for i = 1, #snap.heroes do
        local h = snap.heroes[i]
        if (not h.visible) and h.age >= threshold then
            missing[#missing + 1] = {
                entity   = h.entity,
                age      = h.age,
                last_pos = h.pos,
            }
        end
    end
    table.sort(missing, function(a, b) return a.age > b.age end)
    return missing
end

---Initiator-accounted-for predicate: given a list of enemy unit names
---(canonical npc_dota_hero_*), report which are currently VISIBLE and
---which are missing (fog or absent from match). Used to gate combo
---decisions ("is Magnus visible? if not, defer initiation"). Tiny lib
---helper -- main cost is NPC.GetUnitName per hero in the snapshot.
---
---Returns:
---  {accounted = {[name] = true/false},
---   missing   = {names of those NOT visible},
---   visible   = {names of those visible},
---   unmatched = {names not present in the match at all}}
---
---@param me userdata
---@param initiator_names table list of npc_dota_hero_* names
---@param opts table|nil {snapshot=table}
---@return table result
function Escape.InitiatorAccountedFor(me, initiator_names, opts)
    if not (me and initiator_names) then
        return { accounted = {}, missing = {}, visible = {}, unmatched = {} }
    end
    opts = opts or {}
    local snap = opts.snapshot or Escape.FogSnapshot(me, opts)
    local by_name = {}
    for i = 1, #snap.heroes do
        local h = snap.heroes[i]
        if NPC.GetUnitName then
            local name = NPC.GetUnitName(h.entity)
            if name then by_name[name] = h end
        end
    end
    local accounted, missing, visible, unmatched = {}, {}, {}, {}
    for i = 1, #initiator_names do
        local n = initiator_names[i]
        local h = by_name[n]
        if h then
            if h.visible then
                accounted[n] = true
                visible[#visible + 1] = n
            else
                accounted[n] = false
                missing[#missing + 1] = n
            end
        else
            accounted[n] = false
            unmatched[#unmatched + 1] = n
        end
    end
    return {
        accounted = accounted,
        missing   = missing,
        visible   = visible,
        unmatched = unmatched,
    }
end

---Safest-spot grid picker: sample me_pos + 8 cardinal-and-diagonal points
---on a circle of `radius`, score each via AdvanceRiskScore, return the
---position with the lowest score. Shares one FogSnapshot across all 9
---scores (passes opts.snapshot through).
---
---Useful for retreat / repositioning decisions where the brain wants
---"where near me is least dangerous given current fog state". Subsumes a
---simpler form of ComputeSafeDest (which picks a single direction); this
---is grid-search style.
---
---@param me userdata
---@param radius number sample circle radius (typical 600-900)
---@param opts table|nil same as AdvanceRiskScore opts (engage_radius, max_ms, now)
---@return userdata|nil best_pos best OVERALL spot (may be terrain-locked)
---@return number best_score
---@return table|nil info {traversable, locked, walkable_pos, walkable_score} (v0.5.16x Phase B)
function Escape.SafestSpotNear(me, radius, opts)
    if not (me and radius) then return nil, math.huge, nil end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil, math.huge, nil end
    opts = opts or {}
    -- Single snapshot used for all 9 scores (avoid 9x Heroes.GetAll scans).
    local sub_opts = {}
    for k, v in pairs(opts) do sub_opts[k] = v end
    sub_opts.snapshot = sub_opts.snapshot or Escape.FogSnapshot(me, opts)
    -- v0.5.16x Phase B (design 6.1): track TWO winners in one scan -- the best
    -- WALKABLE spot and the best OVERALL spot (incl. terrain-locked samples). The
    -- 3rd return `info` lets a caller distinguish "the safest spot is across terrain"
    -- (fly) from "the safest spot is walkable" (just walk). me_pos is always
    -- traversable so it seeds both. Additive 3rd return: 2-return callers unaffected.
    local me_score = Escape.AdvanceRiskScore(me, me_pos, sub_opts)
    local best_pos, best_score, best_locked = me_pos, me_score, false
    local walk_pos, walk_score = me_pos, me_score
    for deg = 0, 315, 45 do
        local rad = math.rad(deg)
        local p = Vector(me_pos.x + math.cos(rad) * radius,
                          me_pos.y + math.sin(rad) * radius,
                          me_pos.z)
        local traversable = true
        if GridNav and GridNav.IsTraversableFromTo then
            traversable = GridNav.IsTraversableFromTo(me_pos, p)
        end
        local s = Escape.AdvanceRiskScore(me, p, sub_opts)
        if s < best_score then best_pos, best_score, best_locked = p, s, (not traversable) end
        if traversable and s < walk_score then walk_pos, walk_score = p, s end
    end
    return best_pos, best_score, {
        traversable    = not best_locked,
        locked         = best_locked,
        walkable_pos   = walk_pos,
        walkable_score = walk_score,
    }
end

---Offensive Blink-in landing. Pick a point to blink to so `aim_pos` ends up
---within `engage_range` of `me`, diving as little as possible (near edge), and
---never beyond `blink_range` from `me`. Pure geometry + a fog/proximity risk
---score (Escape.AdvanceRiskScore). Hero-agnostic; Lina + any blink carrier.
---@param me userdata
---@param aim_pos table Vector {x,y,z} (target or cluster center)
---@param blink_range number max blink travel (e.g. 1200)
---@param engage_range number desired distance to aim_pos at landing (e.g. W range)
---@param opts table|nil { margin=50, max_ms, now, snapshot }
---@return table|nil landing, number risk_score, boolean reachable
function Escape.BlinkInLanding(me, aim_pos, blink_range, engage_range, opts)
    if not (me and aim_pos and blink_range and engage_range) then
        return nil, math.huge, false
    end
    local me_pos = Entity.GetAbsOrigin(me)
    if not me_pos then return nil, math.huge, false end
    opts = opts or {}
    local margin = opts.margin or 50
    local dx, dy = me_pos.x - aim_pos.x, me_pos.y - aim_pos.y
    local d_aim = math.sqrt(dx * dx + dy * dy)
    if d_aim < 1e-3 then
        return me_pos, Escape.AdvanceRiskScore(me, me_pos, opts), true
    end
    local ux, uy = dx / d_aim, dy / d_aim
    local edge = math.max(0, engage_range - margin)
    local landing = Vector(aim_pos.x + ux * edge, aim_pos.y + uy * edge, me_pos.z)
    local ldx, ldy = landing.x - me_pos.x, landing.y - me_pos.y
    local reachable = true
    if math.sqrt(ldx * ldx + ldy * ldy) > blink_range then
        local fx, fy = -ux, -uy
        landing = Vector(me_pos.x + fx * blink_range, me_pos.y + fy * blink_range, me_pos.z)
        local adx, ady = aim_pos.x - landing.x, aim_pos.y - landing.y
        reachable = (math.sqrt(adx * adx + ady * ady) <= engage_range)
    end
    return landing, Escape.AdvanceRiskScore(me, landing, opts), reachable
end

---Commit-risk exposure -> a radius WIDENING distance, in units.
---travel_s is SUPPLIED BY THE CALLER (Tinker feeds the keen-aware
---Lane.InterceptETA travel_to_mid it already computes), so there is no
---distance, no move-speed divisor and no division at all in here: that is
---what keeps 0/0, inf and NaN out of the result at the source.
---approach_speed <= 0 returns 0 = the documented no-code-edit kill switch,
---and the <= (not ==) is the guard that matters: a NEGATIVE speed without it
---yields a negative widen, which SHRINKS every danger radius and makes the
---bot blind rather than cautious, silently and exactly backwards.
---The clamp is math.min(cap, math.max(0, w)) IN THAT ORDER. Measured on the
---deployed Lua 5.4: math.max(0, nan) = 0 while math.min(cap, nan) = cap, so
---this ordering sends a NaN to 0 (today's behaviour) rather than to the
---maximum widening. The reverse order returns cap.
---@param travel_s number|nil seconds to reach the point (0 for a transit sample)
---@param stand_s number|nil seconds standing there after arrival
---@param approach_speed number|nil u/s an unseen enemy is assumed to close at
---@param widen_max number|nil cap in units; nil = UNCAPPED (0 means zero widen,
---  which is what the parameter name says; v0.1.357 shipped 0 = uncapped and
---  that asymmetry is a footgun in the dangerous direction). A NEGATIVE or NaN
---  cap is sanitised to 0: the clamp order defends the exposure argument only,
---  and min(cap, .) passes a bad cap straight through, so a mis-signed cap is
---  the SAME "blind rather than cautious" failure as a negative speed arriving
---  through the other parameter (a negative widen SHRINKS the danger radius;
---  a NaN one makes `edge < r_eff` false for every enemy at every distance, so
---  every destination reads safe - the exact defect being fixed, arriving
---  silently through the fix). `not (cap >= 0)` catches both in one comparison.
---@return number widen, always finite and >= 0 for every input
function Escape.CommitWiden(travel_s, stand_s, approach_speed, widen_max)
    approach_speed = approach_speed or 0
    if approach_speed <= 0 then return 0 end
    local cap = widen_max or math.huge
    if not (cap >= 0) then cap = 0 end
    local w = approach_speed * ((travel_s or 0) + (stand_s or 0))
    return math.min(cap, math.max(0, w))
end

---Keyed throttle for a diagnostic line. Returns true if the caller should
---emit, and stamps ONLY THEN. Distinct keys never starve each other: a single
---shared stamp aliases to whichever call site runs first, which is the
---v0.1.357 trap where hundreds of calls per decide sampled only the first.
---A BACKWARDS clock (match transition, or the measured ~102s pregame plateau
---where GetDOTATime is pinned at exactly 0.0) emits rather than suppressing:
---an instrument's failure direction must be noisy, never silent.
function Escape.DiagGate(stamps, key, t, window)
    local dt = t - (stamps[key] or -math.huge)
    if dt >= 0 and dt < window then return false end
    stamps[key] = t
    return true
end

---Nearest enemy EDGE distance to pt, using the SAME edge rule as
---FogProximityRisk (visible = plain distance; fogged = distance minus the
---age disc, floored at 0). INSTRUMENT ONLY, never gates anything.
---FogProximityRisk returns exactly 0 for everything past its radius, so a
---logged risk of 0.00 cannot distinguish "widen too small" from "nobody
---there". 45% of g356's destination reads (91 of 204, and 43 of 73 commits)
---are censored that way, which is why the last calibration had to quote a
---strict worst case instead of a distribution. Returns math.huge on an empty
---snapshot so "no enemies" is distinguishable from "enemy at 0u".
---
---Deliberately carries NO age_cap gate, unlike the risk kernel at :897: the
---kernel drops a stale ghost because it refuses to SCORE it, but an
---instrument that drops the same ghost logs ne=inf next to r1=0.00 and the
---calibration hole this field exists to fill reopens. It reports geometry,
---the kernel decides what geometry is worth.
---
---Component math on .x/.y, never pt:Distance2D: pt crosses the hero->lib
---boundary and callers pass plain {x,y} tables as well as engine Vectors
---(the v0.1.247 stuck-in-DECIDE crash), the same type-boundary law as
---FogProximityRisk's local d2 at :890 and ReachableFog at :784.
---@param snap table|nil FogSnapshot result { heroes = {{pos, age, visible}} }
---@param pt table|nil {x, y} plain table or engine Vector
---@param opts table|nil {fog_ms=550} disc-growth rate, matches FogProximityRisk
---@return number edge distance in units, math.huge when there is nobody to measure
function Escape.NearestEnemyEdge(snap, pt, opts)
    local hs = snap and snap.heroes
    if not (hs and pt) then return math.huge end
    local fog_ms = (opts and opts.fog_ms) or 550
    local best = math.huge
    for i = 1, #hs do
        local h = hs[i]
        if h and h.pos then
            local dx, dy = (h.pos.x or 0) - (pt.x or 0), (h.pos.y or 0) - (pt.y or 0)
            local edge = math.sqrt(dx * dx + dy * dy)
            if not h.visible then
                edge = edge - (h.age or 0) * fog_ms
                if edge < 0 then edge = 0 end
            end
            if edge < best then best = edge end
        end
    end
    return best
end

-- the consolidation mount (phase 3): one file, one require, one returned table.
Escape.Vision = Vision

return Escape
