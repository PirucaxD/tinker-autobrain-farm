---@meta
---lib/vision.lua - shared last-seen tracker for HEROES.
---
---WHY THIS EXISTS: `Hero.GetLastVisibleTime` is DEAD - measured nil on 405 of 405 fogged
---reads across all five enemy heroes in one 895s match (Tinker g353, Umbrella build 831).
---The method exists and is documented nilable; it simply never yields a value, so every
---fog-age model built on it is inert (lib/escape.lua's FogSnapshot, lib/target.lua). No
---other API returns a last-seen timestamp - `FogOfWar.IsPointVisible` answers "is this
---POINT visible now", not "when did I last see this hero" - so the timestamp has to be
---built. See Tinker/TINKER_VISION_LIB_DESIGN.md.
---
---THIS LIB OWNS ITS CLOCK. Callers never pass one for age math: the stamp and the read both
---come from `clock()` below. That is not stylistic. A caller-supplied clock is exactly the
---defect that made the preceding fog arc a red herring - Tinker injected
---`GameRules.GetDOTATime` into a subtraction against an engine-clock timestamp, so `age`
---went negative and clamped to 0 for 275+ versions. Owning the clock makes that class of
---bug structurally impossible here.
---
---MODULE SINGLETON: a Lua module is a singleton across `require` calls in one Lua state
---(see lib/signal.lua's note on the same property), so every hero that requires this shares
---ONE tracker - stamps are written once and read by all.

local Vision = {}

local last_seen = {}                    -- entity -> monotonic seconds at which it went dormant
local events, types = 0, {}             -- probe counters: the callback surface is UNPROVEN

---Monotonic seconds. `GlobalVars.GetCurTime` is what lib/escape.lua:289 documents as the
---engine clock; `GameRules.GetGameTime` is the fallback. NEVER `GetDOTATime` - that is the
---on-screen clock, and mixing the two is the bug this lib exists downstream of.
local function clock()
    if GlobalVars and GlobalVars.GetCurTime then return GlobalVars.GetCurTime() end
    if GameRules and GameRules.GetGameTime then return GameRules.GetGameTime() end
    return 0
end

---OnSetDormant handler. The signature is `(npc, type)` where `type` is an
---`Enum.DormancyType` the docs describe only as "the type of change" - they do NOT say
---which value means ENTERING dormancy, nor whether the callback fires for enemy heroes at
---all. So `type` is RECORDED but never trusted for logic; the documented
---`Entity.IsDormant` decides. This codebase has been burned three times by assuming API
---semantics (NPC.GetAttackDamage, Ability.GetCooldownTimeRemaining,
---NPC.GetModifierRemaining), so the recorded values teach us the enum from a real log
---instead of a guess.
---@param npc userdata
---@param dtype any
function Vision.OnSetDormant_handler(npc, dtype)
    if not npc then return end
    if NPC and NPC.IsHero and not NPC.IsHero(npc) then return end   -- heroes only: creeps fog constantly
    events = events + 1
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
    if dorm then
        last_seen[npc] = clock()        -- the moment it left vision IS the last-seen time
    end
end

---Seconds since this hero was last visible.
---nil is THE SAFETY VALVE: consumers apply their own default, and escape.lua's existing
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

---@return table { tracked = number, events = number, types = table }
---`events` is the field that proves whether OnSetDormant fires at all. If it stays 0 in a
---real game, this whole facility is inert and every consumer is unchanged.
function Vision.Stats()
    local n = 0
    for _ in pairs(last_seen) do n = n + 1 end
    return { tracked = n, events = events, types = types }
end

local inited = false

---Idempotent; mirrors lib/damage.lua's Init contract.
function Vision.Init()
    if inited then return end
    inited = true
end

---Tables already wired. Weak keys so a dead hero table cannot pin memory. This lives HERE
---rather than as a marker field on the caller's table on purpose: hero scripts iterate
---`pairs(callbacks)` to wrap every entry in a hero gate and then hand the table to UCZone
---for registration, so a stray non-function field would be wrapped as though it were a
---callback and registered as one.
local wired = setmetatable({}, { __mode = "k" })

---Chain the handler onto a hero's callbacks table, preserving any handler already there.
---Idempotent PER TABLE: three heroes wiring their own tables is correct and intended (the
---module singleton means they share the tracker, not the table), but wiring the SAME table
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

return Vision
