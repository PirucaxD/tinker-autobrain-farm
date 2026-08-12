---@meta
---lib/schedule.lua - timing-anchored shove-cycle controller. Hero-agnostic, PURE: no engine calls, no
---clock, no loop. The hero assembles plain data (from lib/lane records + engine reads) and passes it in.
---Mirrors lib/route / lib/lane. See Tinker/TINKER_SCHEDULE_DESIGN.md.
local Schedule = {}

---hybrid clear-time: compute the cast COUNT from wave eff-HP / March damage (self-adjusting), with
---calibrated wall-clock per-cast durations. Pure.
---BOUNDARY: this is the WAVE clear model (round-NEAREST - allied creeps + the live wave-clear exit
---finish sub-half remainders). CAMPS use Farm.ClearBudget (ceil-style, capped) - no allies help
---there, so under-budgeting strands creeps. Two models on purpose; do not unify.
---@param eff_hp number   the mid wave's effective HP (visible sum, or ExpectedWave when fogged)
---@param cal table { march_dmg_per_cast, cast_dur, robot_kill, rearm_channel }
---@return table { casts, t_clear }
function Schedule.ClearTime(eff_hp, cal)
    cal = cal or {}
    local dmg = cal.march_dmg_per_cast or 1
    if dmg <= 0 then dmg = 1 end
    -- Round to NEAREST (v0.1.99 revert of the v0.1.97 ceil): the ceil cast a wasteful extra W. The
    -- trailing ranged creep was surviving NOT from a damage shortfall but because the SHOVE cast aimed at
    -- the melee-weighted COUNT centroid, leaving the back ranged just outside the footprint's front edge
    -- ("almost hit"). v0.1.99 fixes the AIM (the shove casts at the span-center-led point that covers the
    -- ranged), so 2 casts + our clashing creeps clear the wave with NO extra W. A genuine sub-half-cast
    -- remainder is finished by allied creeps + the live wave-clear early-exit in the engage.
    local casts = math.max(1, math.floor((eff_hp or 0) / dmg + 0.5))
    -- CADENCE + ONE robot tail (2026-07-01 lib review, aligned with the MEASURED camp model:
    -- engage_done dur ~8.1 vs the old per-cast estimate 10.0). The robots deliver over ~6s and keep
    -- killing DURING the Rearm channel, so charging robot_kill per cast double-counted the overlap;
    -- only the LAST cast's robots finishing (one tail) is sequential cost on top of the cast cadence.
    local t_clear = casts * (cal.cast_dur or 0)
                  + (casts - 1) * (cal.rearm_channel or 0)
                  + (cal.robot_kill or 0)
    return { casts = casts, t_clear = t_clear }
end

---Next time a wave reaches the mid meeting point, on a period grid at a phase. The phase is
---the MEASURED rhythm (last_wave_t % period) when last_wave_t is fresh (we shoved recently),
---else the calibrated spawn-clock `phase` - so anticipation never breaks when mid is fogged or
---after a missed wave. Always strictly > now. PURE.
---CONTRACT (F1, 2026-07-01 deep review): `last_wave_t` must be an ARRIVAL time. The old glue fed
---the wave's DEATH time (engage_done), biasing the measured phase LATE by the clear time (~3-5s) -
---the WAVE_PHASE=17 guess partly compensated, hiding it. Feed the arrival (waveEta at engage).
---@param now number  @param period number  @param phase number  @param last_wave_t number|nil  @param fresh_window number|nil
---@return number arrival
function Schedule.NextWaveArrival(now, period, phase, last_wave_t, fresh_window)
    period = period or 30
    local ph
    if last_wave_t and (now - last_wave_t) <= (fresh_window or 2 * period) then
        ph = last_wave_t % period
    else
        ph = (phase or 0) % period
    end
    return Schedule.NextOnGrid(now, period, ph)
end

-- ---- the Dota clock (general scheduling; 2026-07-01, Liquipedia-verified) ----------------------
-- Anything on the game clock schedules through ONE table + one lookup: rune grabs (bottle refills),
-- lotus picks, tormentor timing, night-caution windows, respawn/stack timing. Grid events carry
-- { period, phase [, first] }; one-shots carry { times }; kill-anchored carry { first,
-- respawn_after } (the caller passes the last kill time). Wisdom runes were REMOVED in 7.38
-- (Shrines of Wisdom) - deliberately absent.

Schedule.EVENTS = {
    wave_spawn      = { period = 30,  phase = 0 },
    neutral_respawn = { period = 60,  phase = 0 },                 -- spawn-box check at each :00
    bounty_rune     = { period = 240, phase = 0 },                 -- jungle spots; river extras from 4:00
    power_rune      = { period = 120, phase = 0, first = 360 },    -- first at 6:00, then every 2:00
    water_rune      = { times = { 120, 240 } },                    -- 2:00 + 4:00 only, then gone
    lotus           = { period = 180, phase = 0, first = 180 },    -- one per 3:00 per pool, cap 6
    tormentor       = { first = 1200, respawn_after = 600 },       -- 20:00; respawn = kill + 10:00
    day_start       = { period = 600, phase = 0 },
    night_start     = { period = 600, phase = 300 },
}

---next time on a period grid at a phase, strictly > now. The generic core NextWaveArrival uses. Pure.
function Schedule.NextOnGrid(now, period, phase)
    local ph = (phase or 0) % period
    local arrival = ph + math.ceil((now - ph) / period) * period
    if arrival <= now then arrival = arrival + period end
    return arrival
end

---next occurrence of a named clock event (Schedule.EVENTS). `last` = the last kill/consume time for
---kill-anchored events (tormentor). nil = unknown event, expired one-shot, or kill-anchored with no
---known kill (alive/untracked). Pure.
---@return number|nil arrival
function Schedule.NextEvent(name, now, last)
    local e = Schedule.EVENTS[name]
    if not e then return nil end
    now = now or 0
    if e.times then
        for _, t in ipairs(e.times) do if t > now then return t end end
        return nil
    end
    if e.respawn_after then
        if now < e.first then return e.first end
        return last and (last + e.respawn_after) or nil
    end
    local nxt = Schedule.NextOnGrid(now, e.period, e.phase)
    if e.first and nxt < e.first then return e.first end
    return nxt
end

---does a SEQUENCE of durations fit before `deadline`? The ability/channel scheduling primitive:
---keen+rearm before leave_by; a combo inside a stun window; a save sequence before a projectile
---lands. Pure.
---@return table { fits, total, start_by }  -- start_by = the latest start that still fits
function Schedule.SeqFits(durations, deadline, now)
    local total = 0
    for i = 1, #(durations or {}) do total = total + (durations[i] or 0) end
    local start_by = (deadline or 0) - total
    return { fits = start_by >= (now or 0), total = total, start_by = start_by }
end

---the cycle decision, v2 (2026-07-01 deep review): the whole shove/jungle/recover POLICY lives
---here - the old hero-side "veto cascade" (8 sequential action mutations, the T4 fragile tangle)
---is absorbed as ordered, declared rules. CLOCK-INDEPENDENT: arrival must be `now + relative ETA`
---so `now` cancels in slack. ALL v2 inputs are OPTIONAL - a minimal ctx behaves exactly like v1.
---ctx = {
---  now, cal, travel_to_mid, mana, shove_cost, safe,
---  wave = { arrival, eff_hp, present, visible },
---  -- v2 (each nil = rule inactive):
---  mana_regen,                  -- mana/s: gate on mana AT leave_by, not instantaneous (F2 -
---                               --   the v0.1.82 idea, done in isolation this time)
---  recover_s,                   -- fountain round-trip estimate -> output recover_fits (F3)
---  far_travel_s, min_wave_ehp,  -- far+near-dead economy veto        -> jungle "deep_skip"
---  thin_ehp,                    -- VISIBLE thin-wave veto (fogged never thin) -> "thin_wave"
---  covers,                      -- false = no tower-safe covering stand -> "no_safe_stand"
---  bal, bal_min,                -- push-sim balance: bal <= bal_min  -> jungle "losing_fight"
---  defend_crash,                -- enemy wave crashing OUR tower -> force the shove (defend +
---                               --   free farm); v2 deliberate fix: NEVER overrides unsafe
---  suppressed,                  -- the mid stand recently proved unreachable (shove_stuck)
---  filler = { min_camp_slack, min_fountain_slack, need_recharge },   -- the lane-first filler
---}
---INVARIANTS (pinned by tests): a VETOED jungle never resurrects through the filler (BUG-1,
---v0.1.124 - only reason=="slack" may convert); the deadline is ALWAYS the CURRENT wave's arrival -
---defer-to-next-wave is a proven dead end (v0.1.78-83, every variant reverted) and NO rule may
---reintroduce it.
---@return table { action, reason, deadline, leave_by, slack, casts, t_clear, mana_at_leave_by,
---                recover_fits }
function Schedule.Plan(ctx)
    ctx = ctx or {}
    local wave = ctx.wave or {}
    local cl = Schedule.ClearTime(wave.eff_hp, ctx.cal)
    local lead = (ctx.cal and ctx.cal.lead) or 0
    local arrival = wave.arrival or 0
    local leave_by = arrival - (ctx.travel_to_mid or 0) - lead
    local slack = leave_by - (ctx.now or 0)
    local mana_at = (ctx.mana or 0) + (ctx.mana_regen or 0) * math.max(0, slack)

    local action, reason
    if not ctx.safe then                                action, reason = "recover", "unsafe"
    elseif mana_at < (ctx.shove_cost or 0) then         action, reason = "recover", "mana"
    elseif slack <= 0 then                              action, reason = "shove", "due"
    -- v0.1.360 TOP UP WHILE THERE IS TIME (user: "using two Ws is the main idea because it makes
    -- more likely to not lose any creep. If we have time to refill, there is no reason to not do it
    -- on lane phase"). Two Marches clear a full wave; one leaks creeps.
    -- WHY IT LIVES HERE AND NOWHERE ELSE. A "shove" verdict is only ever reached at slack <= 0, i.e.
    -- the wave is ALREADY DUE - so refusing a shove for mana cannot buy a refill that arrives in
    -- time, it just abandons the wave, and reason=="mana" routes the hero to RETURN. The ONLY moment
    -- the user's "if we have time" condition can be true is this slack branch, where the wave is not
    -- due yet and the hero would otherwise go jungle. So: top up now, arrive funded, clear it in two.
    -- BOUNDED THREE WAYS so it cannot become a fountain loop or a farming stall:
    --   * ctx.shove_cost_full is nil outside lane phase (the hero only fills it while the enemy mid
    --     T1 stands) and nil below Rearm level 1, so the deep era and the pre-ultimate game are
    --     byte-identical to before;
    --   * the refill must FIT the slack (recover_s), the same predicate recover_fits reports below;
    --   * shove_cost itself is untouched, so the pre-existing mana verdict above is unchanged.
    --   * and NEVER on a defend: reason=="mana" is one of the three verdicts defend_crash may not
    --     override (v0.1.337 at :228), so without this clause a wave crashing OUR tower - zero
    --     travel, zero depth risk, free farm - would be silently dropped at mana levels that fund a
    --     Rearm and a March comfortably. A defend needs no Keen and no trip, so the two-cast TRIP
    --     price is simply the wrong price for it.
    elseif ctx.shove_cost_full and mana_at < ctx.shove_cost_full
           and not ctx.defend_crash
           and (ctx.recover_s == nil or slack >= ctx.recover_s) then
                                                        action, reason = "recover", "mana"
    else                                                action, reason = "jungle", "slack" end

    -- shove vetoes, in the validated hero-cascade order. A FUNCTION since v0.1.197: the filler's
    -- near_due conversion below must pass the SAME vetoes - run-26 t=220.4 walked 2435u to a
    -- covers=false stand 1086 deep because slack>0 made the initial action "jungle", so the
    -- vetoes (gated on action=="shove") never saw the wave before the filler flipped it to
    -- shove/near_due. BUG-1 stopped the filler resurrecting VETOED shoves; this is its sibling:
    -- a slack-jungle was never vetoed at all.
    local function shove_vetoes(a, r)
        if a ~= "shove" then return a, r end
        if ctx.far_travel_s and (ctx.travel_to_mid or 0) > ctx.far_travel_s
           and (wave.eff_hp or 0) < (ctx.min_wave_ehp or 0) then
            return "jungle", "deep_skip"                  -- far + near-dead: not worth the trek
        elseif ctx.camp_alt_s and 2 * (ctx.travel_to_mid or 0) > ctx.camp_alt_s then
            -- Risk v2 axis 2 (task #11, user 2026-07-04): the ROUND-TRIP walk out-costs the camp
            -- alternative ("we can clear 2 or 3 camps with the time tinker is walking"). GRADED
            -- economics, not a positional veto: the hero feeds a raid-aware travel (an L2
            -- creep-keen collapses it to ~the channel), so deep waves naturally re-qualify at
            -- Keen L2 and the window goes to the jungle otherwise. nil = rule inactive.
            return "jungle", "far_wave"
        elseif ctx.gone then
            -- gone-by-arrival (run-21, user: "farming empty waves that are deep"): the hero's
            -- push sim says OUR wave clearly wins and the fight resolves BEFORE we can arrive -
            -- there will be nothing to farm; the trek is pure GPM loss. Precise timing, NOT a
            -- defer (the deadline stays the current wave; the window jungles). nil = inactive.
            return "jungle", "gone_by_arrival"
        elseif ctx.thin_ehp and wave.visible and (wave.eff_hp or 0) < ctx.thin_ehp then
            return "jungle", "thin_wave"                  -- a lone creep: tower + allies handle it
        elseif ctx.covers == false then
            return "jungle", "no_safe_stand"              -- no tower-safe covering stand exists
        elseif ctx.bal and ctx.bal_min and ctx.bal <= ctx.bal_min then
            return "jungle", "losing_fight"               -- the push sim says we lose this fight
        end
        return a, r
    end
    action, reason = shove_vetoes(action, reason)

    -- lane-first filler: ONLY a GENUINE slack-jungle may convert (BUG-1), and the near_due
    -- conversion passes the same shove vetoes (v0.1.197) - a hold at an illegal/gone/thin wave
    -- is exactly the deep walk-and-wait the vetoes exist to prevent.
    local f = ctx.filler
    if f and action == "jungle" and reason == "slack"
       and (slack - (ctx.travel_to_mid or 0)) < (f.min_camp_slack or 0) then
        if f.need_recharge and slack >= (f.min_fountain_slack or 0) then
            action, reason = "recover", "recharge"        -- fountain trip, back for the fresh wave
        elseif ctx.suppressed then
            action, reason = "recover", "shove_stuck"     -- the stand just proved unreachable
        else
            action, reason = shove_vetoes("shove", "near_due")   -- hold at mid, W the wave ASAP - IF a shove is legal here at all
        end
    end

    -- Defense case-file #2 (run-72 t=445): a DUE shove at low HP dispatched legally (no enemy
    -- visible at decide), then HP panic fired on arrival = the keen + a ~50s fountain round
    -- trip donated. Mana always had recover gates; HP had only the filler's need_recharge,
    -- which a due shove (slack <= 0) bypasses entirely. Self-state is a dispatch
    -- precondition: below the bar, recover first - the wave re-competes after the refill.
    -- nil ctx fields = rule inactive (back-compatible).
    if action == "shove" and ctx.hp_frac and ctx.min_hp_frac and ctx.hp_frac < ctx.min_hp_frac then
        action, reason = "recover", "low_hp"
    end

    -- defend: the enemy wave is crashing OUR tower - clear it (our safe side, defend + free farm).
    -- Runs LAST over any veto, code-faithful to the cascade order - EXCEPT unsafe (v2 deliberate
    -- fix: the old cascade could force a shove into a detected gank; safety keeps the last word)
    -- AND covers==false (v0.1.198 audit HOLE B: a real defense happens at OUR tower where a legal
    -- covering stand always exists; overriding no_safe_stand could commit a stand past the walk
    -- line that dpts==0 cannot see - depth points only count past the enemy T1 spot).
    -- v0.1.337: nor the MANA verdict (g337 t=627: a 240-mana defend raid keened in, cast
    -- NOTHING, keened home - an unfundable defense recovers first and re-fires next decide).
    -- v0.1.337.1 (final-review find): nor BELOW THE HP BAR - the hp predicate is checked HERE,
    -- not via reason, because a jungle/slack verdict skips the :213 low_hp rule entirely
    -- (action ~= shove there) and a reason-only exception would cover just the flip-back half.
    if ctx.defend_crash and action ~= "shove" and reason ~= "unsafe"
       and reason ~= "mana" and ctx.covers ~= false
       and not (ctx.hp_frac and ctx.min_hp_frac and ctx.hp_frac < ctx.min_hp_frac) then
        action, reason = "shove", "defend_crash"
    end

    return { action = action, reason = reason,
             deadline = arrival, leave_by = leave_by, slack = slack,
             casts = cl.casts, t_clear = cl.t_clear,
             mana_at_leave_by = mana_at,
             recover_fits = (action ~= "recover") or (ctx.recover_s == nil) or slack >= ctx.recover_s }
end

---THE CYCLE ARC (v0.1.339, TINKER_CYCLE_MACHINE_DESIGN.md; the .302 resurrect): what the
---NEXT full wave cycle costs - two casts with their rearms and the keens out+home. Pure.
---c = { w, rearm, keen }  (live per-level mana values, hero-read)
function Schedule.WaveCycleCost(c)
    c = c or {}
    return 2 * ((c.w or 0) + (c.rearm or 0) + (c.keen or 0))
end

---the fountain-vs-park decision for a window no farm fill claimed (design sec 3; the
---v0.1.340 g341 re-calibration): the TRIGGER is the .296 broke floor ONLY - fountain iff
---the pool cannot fund the NEXT WAVE (hop cost + reserve). The FILL keeps the .302
---semantics: need = the cycle cost floored at the broke bar, capped at max_pool - when he
---goes, he fills for the full next cycle. HISTORY: v0.1.339 used the cycle cost as the
---TRIGGER too, which read STRICTER at Keen L1 than the old 70-percent rule (630-670 vs
---~460-520) - pools 577-642 that used to hold the forward tether posture fountained
---instead (g341: home-refills 25 -> 31, fountain 16.6 -> 22.3 pct, tether 21.6 -> 6.8
---pct, GPM 489 -> 356). Trigger on survival, fill for the cycle. Park otherwise.
---ctx = { pool, max_pool, cycle_cost, broke_bar }
function Schedule.CycleFill(ctx)
    ctx = ctx or {}
    local pool = ctx.pool or 0
    if pool < (ctx.broke_bar or 0) then
        local need = math.max(ctx.cycle_cost or 0, ctx.broke_bar or 0)
        return { fill = "fountain", need = math.min(need, ctx.max_pool or need) }
    end
    return { fill = "park" }
end

---Stacking window (v0.1.224): neutral camps respawn at each game-clock minute when the box is
---empty, so aggroing at ~:54 walks the old creeps across the :00 boundary and doubles the camp.
---Returns absolute times on the caller's clock for the nearest still-makeable opportunity:
---  aggro_at = when to aggro (base + opts.aggro_sec, next minute if this one is past),
---  from     = when the maneuver effectively starts (aggro_at - 0.5; arriving earlier waits),
---  to       = the latest acceptable FINISH (done + opts.to_slack) - a late start overruns it,
---  done     = just past the :00 respawn (maneuver complete).
---Pure; opts: aggro_sec (default 54), miss_slack (default 1.5, how late the aggro may start),
---to_slack derived so start <= aggro_at + miss_slack collects and anything later does not.
function Schedule.StackWindow(now, opts)
    opts = opts or {}
    local aggro = opts.aggro_sec or 54
    local slack = opts.miss_slack or 1.5
    local base = math.floor(now / 60) * 60
    local aggro_at = base + aggro
    if now > aggro_at + slack then aggro_at = aggro_at + 60 end
    -- neutrals first spawn at 1:00 (opts.first_spawn): a minute-0 window (aggro 0:54) targets a
    -- camp that does not exist yet - run-66 walked 40s to stack_abort empty on it. Roll forward.
    local first = opts.first_spawn or 60
    if aggro_at < first then aggro_at = aggro_at + 60 end
    local done = (math.floor(aggro_at / 60) + 1) * 60 + 0.5
    return { aggro_at = aggro_at, from = aggro_at - 0.5, done = done,
             clear_t = done - aggro_at + 0.5, to = done + slack + 0.5 }
end

return Schedule
