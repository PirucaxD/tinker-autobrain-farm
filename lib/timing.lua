---@meta
---lib/timing.lua - predictive cast-window math.
---
---Tier 2 helper for predicting *future* invuln / dispel / out-of-game
---states. Replaces `Target.WillBeInvulnIn` v1, which read currently-active
---state durations only.
---
---**Pure helpers** - no game-state mutation. Callers feed in:
---  - The target entity.
---  - A look-ahead window in seconds.
---Returns one of `"safe"` / `"will_be_invuln"` / `"likely_dispel"` /
---`"now"` (already in the state).
---
---v1 covers the most common 7.41C cases. Add ability/modifier names as
---new heroes ship.

local Timing = {}

local MS = Enum.ModifierState

-- v6.15.2 M1: removed the empty INFLIGHT_INVULN table + its dead pairs loop
-- below. Repopulate when in-flight modifier observation is available.

-- Items the target may activate this tick to escape. Cooldown ≤ window
-- means "could fire". Maps item internal name to its CAST POINT - we add
-- this to the cooldown check so we know the order can resolve within the
-- prediction window. v6.15.2 C4: dropped `item_eul_scepter` (not a real
-- internal name in 7.41C - canonical is item_cyclone for the base Eul item).
-- v6.15.2 H4: Aeon Disk has `passive = true` so the predictor gates on
-- target HP being below the 70% trigger threshold instead of treating it
-- like an active cast (which would always say "yes Aeon will pop").
local ESCAPE_ACTIVES = {
    item_black_king_bar = { cast_point = 0.0,  effect = "magic_immune" },
    item_manta          = { cast_point = 0.1,  effect = "dispel_basic" },
    item_cyclone        = { cast_point = 0.0,  effect = "invuln" },
    item_wind_waker     = { cast_point = 0.0,  effect = "invuln" },
    item_aeon_disk      = { cast_point = 0.0,  effect = "invuln",
                            passive = true, hp_trigger_frac = 0.70 },
    item_lotus_orb      = { cast_point = 0.0,  effect = "reflect" },
    item_satanic        = { cast_point = 0.0,  effect = "dispel_basic" },
}

---Currently in an invuln-class state? (Predicts nothing - just reads.)
---@param entity userdata|nil
---@return boolean
function Timing.IsInvulnNow(entity)
    if not entity or not Entity.IsNPC(entity) then return false end
    if NPC.HasState(entity, MS.MODIFIER_STATE_INVULNERABLE) then return true end
    if NPC.HasState(entity, MS.MODIFIER_STATE_OUT_OF_GAME) then return true end
    if NPC.HasState(entity, MS.MODIFIER_STATE_MAGIC_IMMUNE) then return true end
    return false
end

---Will the target be invuln / magic-immune / dispel-active within the
---window? Returns a tuple of (boolean, reason_string|nil).
---@param entity         userdata|nil
---@param window_seconds number
---@return boolean, string|nil
function Timing.WillBeInvulnIn(entity, window_seconds)
    if not entity or not Entity.IsNPC(entity) then return false, nil end
    if Timing.IsInvulnNow(entity) then return true, "now" end

    -- Read ALL state durations once; many states return a positive number
    -- when the entity is currently subject to a debuff/buff.
    local d_invuln = NPC.GetStatesDuration and
        NPC.GetStatesDuration(entity, MS.MODIFIER_STATE_INVULNERABLE) or 0
    local d_oog    = NPC.GetStatesDuration and
        NPC.GetStatesDuration(entity, MS.MODIFIER_STATE_OUT_OF_GAME) or 0
    local d_mi     = NPC.GetStatesDuration and
        NPC.GetStatesDuration(entity, MS.MODIFIER_STATE_MAGIC_IMMUNE) or 0
    if d_invuln > 0 or d_oog > 0 or d_mi > 0 then
        return true, "state_active"
    end

    -- v6.15.2 M1: in-flight cast modifier loop removed (table was empty).

    -- Item-active prediction: any escape-active off CD or about to come off
    -- within (window - its cast point) counts. Mana-gated: skip if the
    -- target lacks the item's mana cost. v6.15.2 H4: passive-trigger items
    -- (Aeon Disk) also require HP to be below the trigger threshold.
    local target_mana = NPC.GetMana(entity) or 0
    local hp     = Entity.GetHealth(entity) or 0
    local hp_max = Entity.GetMaxHealth(entity) or 1
    local hp_frac = (hp_max > 0) and (hp / hp_max) or 1
    for item_name, info in pairs(ESCAPE_ACTIVES) do
        local it = NPC.GetItem(entity, item_name, true)
        if it then
            -- Passive trigger: HP must be below threshold for it to fire.
            if info.passive then
                if hp_frac > (info.hp_trigger_frac or 0.70) then
                    -- HP too high - won't trigger this commit. Skip.
                else
                    local cd = Ability.GetCooldown(it) or 999
                    if cd <= window_seconds then return true, item_name end
                end
            else
                local mana_cost = Ability.GetManaCost(it) or 0
                if mana_cost <= target_mana then
                    local cd = Ability.GetCooldown(it) or 999
                    local effective_window = window_seconds - (info.cast_point or 0)
                    if cd <= effective_window then
                        return true, item_name
                    end
                end
            end
        end
    end

    return false, nil
end

---Probability-style readiness for an escape (not a boolean). Returns 0..1.
---0  = no escape items / all on very-long CD.
---0.3 = at least one item within 2× window.
---0.6 = at least one item within 1× window.
---1.0 = at least one item ready RIGHT NOW.
---@param entity         userdata|nil
---@param window_seconds number
---@return number
function Timing.EscapeReadiness(entity, window_seconds)
    if not entity or not Entity.IsNPC(entity) then return 0 end
    if Timing.IsInvulnNow(entity) then return 1.0 end
    local target_mana = NPC.GetMana(entity) or 0
    -- v6.15.2 H4: Aeon HP gate.
    local hp     = Entity.GetHealth(entity) or 0
    local hp_max = Entity.GetMaxHealth(entity) or 1
    local hp_frac = (hp_max > 0) and (hp / hp_max) or 1
    local best = 0
    for item_name, info in pairs(ESCAPE_ACTIVES) do
        local it = NPC.GetItem(entity, item_name, true)
        if it then
            if info.passive then
                if hp_frac <= (info.hp_trigger_frac or 0.70) then
                    if Ability.IsReady(it) then return 1.0 end
                    local cd = Ability.GetCooldown(it) or 999
                    if cd <= window_seconds then best = math.max(best, 0.6)
                    elseif cd <= window_seconds * 2 then best = math.max(best, 0.3)
                    end
                end
            else
                local mana_cost = Ability.GetManaCost(it) or 0
                if mana_cost <= target_mana then
                    if Ability.IsReady(it) then return 1.0 end
                    local cd = Ability.GetCooldown(it) or 999
                    local effective_window = window_seconds - (info.cast_point or 0)
                    if cd <= effective_window then best = math.max(best, 0.6)
                    elseif cd <= effective_window * 2 then best = math.max(best, 0.3)
                    end
                end
            end
        end
    end
    return best
end

---The arrival watchdog ruler (v0.1.334, TINKER_ARRIVAL_WATCHDOG_DESIGN.md):
---promise-relative overdue adjudication for a committed, PRE-CAST wave wait.
---The live eta is NOT the ruler (a sliding promise never ages - g334 t=620 read
---"~2s away" for 40 straight seconds); time past the ORIGINAL promise is.
---A REAL, reachable, imminent scan read may extend the stand up to the cap;
---estimates never pin (the .241 law's spirit). why on release: fog = no real
---read; slow = real read but not imminent at wake; flicker = the cap tripped
---while the scan still claimed imminence.
---@param now number
---@param promise0 number   the ORIGINAL committed arrival, never rolled
---@param scan table|nil    { est=boolean, reach=boolean, eta=number|nil } latest lane read
---@param k table           { grace=number, hold_t=number, hold_max=number }
---@return string verdict   "hold" | "release"
---@return string|nil why   set on release
---@return number over      seconds past the promise (the logline held= value)
function Timing.ArrivalWatchdog(now, promise0, scan, k)
    local over = now - promise0
    if over <= k.grace then return "hold", nil, over end
    local real_eta = scan and (not scan.est) and scan.reach and scan.eta or nil
    if real_eta and real_eta <= k.hold_t then
        if over > k.hold_max then return "release", "flicker", over end
        return "hold", nil, over
    end
    if real_eta then return "release", "slow", over end
    return "release", "fog", over
end

return Timing
