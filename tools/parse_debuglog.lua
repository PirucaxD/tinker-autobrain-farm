#!/usr/bin/env lua
-- tools/parse_debuglog.lua - turn debug.log into a per-frame timeline.
--
-- Usage (from a terminal with Lua 5.1+ available):
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --hero=Sniper
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --grep=layer1_dispatch
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --since=120 --until=180
--   lua tools/parse_debuglog.lua C:\Umbrella\debug.log --summary
--
-- Output: one event per line, formatted as a compact timeline. Events with
-- a `_t` or `t=` field are sorted by that timestamp; lines without are kept
-- in source order.
--
-- This is a READ-ONLY tool - no game-state mutation. Safe to run while
-- a match is in progress (file is read-locked briefly).

local function usage()
    io.stderr:write([[
parse_debuglog.lua <path-to-debug.log> [options]

Options:
  --hero=Name            Filter to one hero's events (default: all)
  --grep=substring       Filter to events whose name matches
  --since=N              Skip events before relative-time N seconds
  --until=N              Skip events after relative-time N seconds
  --summary              Print event-name → count summary instead of timeline
  --modseen              Print modseen_summary + first 50 unique modifiers
  --postmortem           Print death_postmortem lines + surrounding context
  --aggression-report    Parse cast_outcome → R-kill rate, damage-per-R, false-positive commits
  --defense-report       Parse save_outcome → survival rate per threat, HP nadir, save latency
  --farm-report          Parse `farm` trace → per-wave coverage, prediction accuracy, risk/veto/cadence
  --lane-report          Parse the 2s `wavescan` series → arrival timing vs NextWaveArrival + real
                         spawn-grid phase, ExpectedWave hp truth (est->real), meeting drift (Piece 1)
  --cycle-report         Per-shove-cycle timeline (decide -> keen -> tether -> step_out -> engage):
                         transit share, tether/idle time, early timed casts. Task #12 instrument.
  --time-report          Full-run TIME accounting (every second classified per decide segment:
                         engage/walk/wait/tether/fountain/idle) + GOLD accounting per pick type
                         (from the cumulative gpm field) + all holds > 10s. GPM-study instrument.
  --depth-audit          THE WALK-LAW VERIFIER: flags every positional event (stand commit, keen
                         landing, tether hold, W cast) past the stairs line while Keen < L2.
                         Zero violations = the invariant held. Run after EVERY session.
  --farm-audit           THE CAMP-ECONOMICS VERIFIER (v0.1.199): per farm decide, checks the afford
                         gate against its own numbers (ok>0 <=> pm >= need) and flags illegal
                         singles (paired=false pick with a partner in pair range, nnd<=1800).
                         Zero violations = the gate + pair rule held. Run after EVERY session.
  --keen-report          THE KEEN-EFFICIENCY LEDGER: every keen (keen_to_anchor + keen_home)
                         classified by outcome - bounce (re-keen <15s, nothing farmed), long-walk
                         (residual > 1000), home-cycle (keen_home outside a refill/recover pick),
                         home-refill, raid, productive (cast/farm followed), short-hop (rest) -
                         with caller (lane_go variant), nearest decide's pick/mana/klvl, and
                         estimated keen mana per class (Keen 75 flat; rearm_reset rungs +~225).
  --commit-risk          THE COMMIT-RISK VERIFIER (TINKER_COMMIT_RISK_DESIGN_V2.md 6.6): per-site
                         counts as an explicit PASS/FAIL (A1, the anti-aliasing check nothing else
                         in the log reveals), instrument gaps against the heartbeat and DEATH lines
                         (A2), the wcap=1 fraction (A3, the cap-became-the-operating-value trap that
                         bit this arc twice), the full nearest-enemy ne= distribution with an offline
                         COMMIT_APPROACH_SPEED re-score (A4, the calibration payload), the live
                         constants (A5) and the GANK_RADIUS inversion count (A6) - then every chg=1
                         commit listed individually for the human read the acceptance bar requires.
  --clock-report         THE LANE-CLOCK LEDGER: the arc's headline acceptance metric. Every
                         completed `engage_done lane=mid` stamped by the running `| t=`, printed as
                         a cadence timeline with the gap to the previous clear, split at Keen L2
                         (lane phase vs raid era, from `| klvl=`), and the PASS/FAIL: any
                         lane-phase gap over 90s, with what the bot was doing inside it (camp
                         trips, refills, death, user takeover) so an excused hole is not read as a
                         defect. Pass SEVERAL logs for a one-row-per-log corpus table.
  --stuck-report         THE UNSTICK LEDGER: every `STUCK -> teleport unstick` classified
                         ARRIVED-AND-STOPPED (dord near 0: he reached the point he was ORDERED to
                         and halted, so the producer named by osrc parked him off the stand and the
                         fix belongs THERE, not in the watchdog) versus GENUINE-BLOCK (dord near d:
                         he never got there, the teleport is working). The two want OPPOSITE fixes,
                         which is why the split leads and the raw count does not. Also prints the
                         osrc producer census and the prearm_w2 / channel_defer precedence. Needs
                         the v0.1.362 fields; older logs read UNKNOWN, never zero. Background:
                         Tinker/TINKER_UNSTICK_LOOP_FINDINGS.md.

]])
end

-- Brain log format from `tlog()`:
--   [LEVEL] [Hero] event_name | k=v k2=v2 k3=v3
-- LEVEL is one of [INFO] [WARN] [ERROR]. Hero is the brain name. Parse with
-- a permissive regex so future hero names just work.
local function parse_line(line)
    -- strip a leading UTF-8 BOM: it only ever appears on line 1, which in the older single-banner
    -- logs IS the version banner, so the `^%[` anchor below dropped exactly the line every banner
    -- consumer needs (the DEATHS gate here and death_log at :2286 both went blind on g328).
    line = line:gsub("^\239\187\191", "")
    local level, hero, body = line:match("^%[(%w+)%]%s*%[([^%]]+)%]%s*(.+)$")
    if not level or not hero then return nil end
    local event, kvs = body:match("^(%S+)%s*|?%s*(.*)$")
    if not event then return nil end
    local kv = {}
    for k, v in kvs:gmatch("(%S+)=(%S+)") do
        kv[k] = v
    end
    return { level = level, hero = hero, event = event, kv = kv, raw = line }
end

-- ---- arg parsing ----
local path
local paths = {}   -- v0.1.360: EVERY positional arg. Extra ones used to fall through the flag chain
                   -- and vanish; --clock-report ranks a whole corpus from them (one row per log).
local opt_hero, opt_grep, opt_since, opt_until = nil, nil, nil, nil
local opt_fog_recalc = nil     -- v0.1.353: "AGE_CAP,FRESH_S" to re-score a log offline
local opt_with_takeover = false   -- v0.1.345: keep events inside autofarm OFF..ON (default = excise them)
local mode = "timeline"  -- timeline | summary | modseen | postmortem
local mode_count = 0     -- v6.15.2 M7: warn on multiple mode flags
for i = 1, #arg do
    local a = arg[i]
    if not a:match("^%-%-") then
        paths[#paths + 1] = a
        path = path or a
    elseif a:match("^%-%-hero=") then opt_hero = a:sub(8)
    elseif a:match("^%-%-grep=") then opt_grep = a:sub(8)
    elseif a:match("^%-%-since=") then opt_since = tonumber(a:sub(9))
    elseif a:match("^%-%-until=") then opt_until = tonumber(a:sub(9))
    elseif a == "--summary" then mode = "summary"; mode_count = mode_count + 1
    elseif a == "--modseen" then mode = "modseen"; mode_count = mode_count + 1
    elseif a == "--postmortem" then mode = "postmortem"; mode_count = mode_count + 1
    elseif a == "--aggression-report" then mode = "aggression_report"; mode_count = mode_count + 1
    elseif a == "--defense-report" then mode = "defense_report"; mode_count = mode_count + 1
    elseif a == "--farm-report" then mode = "farm_report"; mode_count = mode_count + 1
    elseif a == "--lane-report" then mode = "lane_report"; mode_count = mode_count + 1
    elseif a == "--cycle-report" then mode = "cycle_report"; mode_count = mode_count + 1
    elseif a == "--time-report" then mode = "time_report"; mode_count = mode_count + 1
    elseif a == "--depth-audit" then mode = "depth_audit"; mode_count = mode_count + 1
    elseif a == "--cast-report" then mode = "cast_report"; mode_count = mode_count + 1
    elseif a == "--convert-report" then mode = "convert_report"; mode_count = mode_count + 1
    elseif a == "--farm-audit" then mode = "farm_audit"; mode_count = mode_count + 1
    elseif a == "--keen-report" then mode = "keen_report"; mode_count = mode_count + 1
    elseif a == "--commit-risk" then mode = "commit_risk"; mode_count = mode_count + 1
    elseif a == "--clock-report" then mode = "clock_report"; mode_count = mode_count + 1
    elseif a == "--state-report" then mode = "state_report"; mode_count = mode_count + 1
    elseif a == "--fog-report" then mode = "fog_report"; mode_count = mode_count + 1
    elseif a == "--stuck-report" then mode = "stuck_report"; mode_count = mode_count + 1
    elseif a == "--crash-report" then mode = "crash_report"; mode_count = mode_count + 1
    elseif a == "--mana-report" then mode = "mana_report"; mode_count = mode_count + 1
    elseif a == "--fog-shadow" then mode = "fog_shadow"; mode_count = mode_count + 1
    elseif a:match("^%-%-fog%-recalc=") then opt_fog_recalc = a:match("^%-%-fog%-recalc=(.+)$")
    elseif a == "--with-takeover" then opt_with_takeover = true
    elseif a == "--help" or a == "-h" then usage(); os.exit(0)
    end
end
if not path then usage(); os.exit(1) end
if mode_count > 1 then
    io.stderr:write("warning: multiple mode flags passed; using --" .. mode .. "\n")
end

-- ---- read ----
-- v6.15.2 H7: --since / --until previously dead options. Wire them in.
-- Events expose a relative timestamp via `t=` or `_t=` kv field set by tlog().
-- Filter inclusively: keep if (no since OR ts >= since) AND (no until OR ts <= until).
-- v0.1.360: the reader is a FUNCTION so --clock-report's corpus mode loads 22 logs through this
-- exact path - takeover excision included - instead of growing a second reader that drifts from
-- it. Body is the old top-level code verbatim; the single-log call below reproduces it.
-- v0.1.345 TOOLING: EXCISE USER-TAKEOVER WINDOWS AUTOMATICALLY.
-- The .335 tracer brackets manual play with `autofarm OFF` .. `autofarm ON`; anything inside is
-- the USER, not the brain. STEP 0 has always said to excise these BY HAND, and every analyzer
-- silently included them when you forgot - which is exactly how a g347 keen got read as "wasted,
-- farmed nothing for 24s" when the user had in fact taken over and cast W1/Rearm/W2 by hand
-- (the W orders read `ExecuteOrder [ USER ]`, not `[ SCRIPT ]`). Now it is automatic and counted.
-- `--with-takeover` keeps the old raw behaviour.
-- takeover_spans = { {t0=<last ts before OFF>, t1=<first ts after ON>}, ... } so the KEEN report can
-- mark a keen whose outcome window overlaps manual play as class "takeover" instead of scoring it
-- as brain waste (the keen itself may fire BEFORE the bracket - the g347 t=273.0 case).
local function load_log(p)
    local f = io.open(p, "r")
    if not f then io.stderr:write("cannot open " .. p .. "\n"); os.exit(2) end
    local evs, counts, spans = {}, {}, {}
    local in_takeover, excised, takeover_windows = false, 0, 0
    -- DEATHs dropped by the takeover filter are kept HERE, not thrown away: excising them from
    -- `evs` is correct (a death while autofarm is OFF is the USER dying, not the brain), but
    -- dropping them silently makes "DEATHS: 0" unreadable - it cannot be told apart from "no
    -- death happened". g364 carries exactly this case: a DEATH at t=825.3 inside an autofarm OFF
    -- at line 9848 that never closes, so the window runs to EOF and the death vanished entirely.
    local excised_deaths = {}
    local last_ts, pending_end = nil, nil
    for line in f:lines() do
        if line:find("autofarm OFF", 1, true) then
            if not in_takeover then
                takeover_windows = takeover_windows + 1
                spans[#spans + 1] = { t0 = last_ts or 0, t1 = math.huge }
            end
            in_takeover = true
        elseif line:find("autofarm ON", 1, true) then
            if in_takeover then pending_end = spans[#spans] end
            in_takeover = false
        end
        local e = parse_line(line)
        if e then
            local ts = tonumber(e.kv.t or e.kv._t)
            if ts then
                last_ts = ts
                if pending_end then pending_end.t1 = ts; pending_end = nil end   -- first stamped event after autofarm ON closes the span
            end
            local time_ok = (not opt_since or (ts and ts >= opt_since))
                        and (not opt_until or (ts and ts <= opt_until))
            if (not opt_hero or e.hero == opt_hero)
               and (not opt_grep or e.event:find(opt_grep, 1, true))
               and time_ok then
                if in_takeover and not opt_with_takeover then
                    excised = excised + 1
                    if e.event == "DEATH" then excised_deaths[#excised_deaths + 1] = e end
                else
                    evs[#evs + 1] = e
                    counts[e.event] = (counts[e.event] or 0) + 1
                end
            end
        end
    end
    f:close()
    if excised > 0 then
        io.stderr:write(string.format(
            "note: excised %d event(s) inside %d user-takeover window(s) (autofarm OFF..ON). Use --with-takeover to keep them.\n",
            excised, takeover_windows))
    elseif takeover_windows > 0 and opt_with_takeover then
        io.stderr:write(string.format("note: %d user-takeover window(s) KEPT (--with-takeover).\n", takeover_windows))
    end
    return evs, counts, spans, excised_deaths
end
local events, summary_counts, takeover_deaths
events, summary_counts, takeover_spans, takeover_deaths = load_log(path)

-- ONE definition of the spawn-grid mirror for the whole tool (Tinker K.WAVE_PERIOD / K.WAVE_PHASE).
-- It used to be a farm_report-local pair plus a hand-typed "current 17" in the lane_report prose,
-- and the two drifted: K has read 14 since Piece 1 measured it. No mode types this value by hand now.
local WAVE_PERIOD, WAVE_PHASE = 30, 21   -- mirror Tinker K. v0.1.366: 14 -> 21 WITH the hero. THE MIRROR GOING STALE IS HOW THE BUG HID: this tool printed "observed spawn-grid phase: median 18.4-19.6 (K.WAVE_PHASE calibration; current 14)" on every log for dozens of builds, and because the mirror agreed with the stale hero constant the "grid pred error" line kept measuring the wrong grid instead of flagging it. If K.WAVE_PHASE moves in Tinker.lua, MOVE IT HERE IN THE SAME COMMIT.

-- ---- render ----
if mode == "summary" then
    -- sort by count desc
    local pairs_arr = {}
    for k, v in pairs(summary_counts) do pairs_arr[#pairs_arr + 1] = { k, v } end
    -- name tie-break: table.sort is not stable and pairs() order is unspecified, so equal
    -- counts would otherwise print in a different order every run.
    table.sort(pairs_arr, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    print("event\tcount")
    for i = 1, #pairs_arr do
        print(pairs_arr[i][1] .. "\t" .. pairs_arr[i][2])
    end
    os.exit(0)
elseif mode == "modseen" then
    print("--- modseen_summary (unique modifier names observed) ---")
    local seen = {}
    for i = 1, #events do
        local e = events[i]
        if e.event == "modseen" or e.event == "modseen_entry" then
            local key = (e.kv.unit or "?") .. ":" .. (e.kv.mod or e.kv.key or "?")
            if not seen[key] then
                seen[key] = e.kv.caster or "-"
                print(key .. "\tcaster=" .. (e.kv.caster or "-"))
            end
        end
    end
    os.exit(0)
elseif mode == "postmortem" then
    print("--- death_postmortem entries ---")
    for i = 1, #events do
        local e = events[i]
        if e.event == "death_postmortem" then
            print(e.raw)
            -- context: previous 5 events
            for j = math.max(1, i - 5), i - 1 do
                print("  ctx -" .. (i - j) .. ": " .. events[j].raw)
            end
        end
    end
    os.exit(0)
elseif mode == "aggression_report" then
    -- v6.15.58 (G15): aggression report.
    -- v6.15.86 (CRITICAL fix - user feedback): the prior report counted
    -- cast_outcome events as "R casts" - that's WRONG. cast_outcome tracks
    -- target HP delta in a 5s window after `issued`, but doesn't verify
    -- R actually fired. In the v6.15.85 log, EVERY R cast_verify showed
    -- fired=n (engine cancelled R via native interference) - yet the
    -- report claimed 75% kill rate because the cast_outcome window caught
    -- damage from autos/Q that landed independently. Ground truth must be
    -- cast_verify fired=y. Now:
    --   1. First pass: build per-intent map of LATEST cast_verify fired status
    --   2. Second pass: cast_outcome only counts when verified fired=y
    --   3. Report shows BOTH verified count and raw count so the user can
    --      see the gap if cast cancellation is happening.
    print("--- aggression report ---")
    local last_verify = {}        -- intent → latest fired status ("y"/"n")
    local fire_count_per_intent = {}  -- intent → count of fired=y verifies
    local double_fail_per_intent = {} -- intent → count of double_fail events
    for i = 1, #events do
        local e = events[i]
        if e.event == "cast_verify" then
            local intent = e.kv.intent or "?"
            last_verify[intent] = e.kv.fired
            if e.kv.fired == "y" then
                fire_count_per_intent[intent] = (fire_count_per_intent[intent] or 0) + 1
            end
        elseif e.event == "cast_verify_double_fail" then
            local intent = e.kv.intent or "?"
            double_fail_per_intent[intent] = (double_fail_per_intent[intent] or 0) + 1
            last_verify[intent] = "n"  -- explicit fail
        end
    end
    local n_total, n_kill, n_alive, n_respawn = 0, 0, 0, 0
    local n_raw_outcome, n_bogus_outcome = 0, 0
    local sum_hp_delta_pct = 0
    local per_intent = {}        -- intent → {casts, kills}
    local per_target = {}        -- target → {casts, kills}
    local hp_delta_buckets = { [0]=0, [25]=0, [50]=0, [75]=0, [100]=0 }
    -- Track per-intent last verify dynamically as we iterate (events are
    -- in source order; cast_verify precedes cast_outcome for any one issue).
    local rolling_verify = {}
    for i = 1, #events do
        local e = events[i]
        if e.event == "cast_verify" then
            rolling_verify[e.kv.intent or "?"] = e.kv.fired
        elseif e.event == "cast_verify_double_fail" then
            rolling_verify[e.kv.intent or "?"] = "n"
        elseif e.event == "cast_outcome" then
            n_raw_outcome = n_raw_outcome + 1
            local intent = e.kv.intent or "?"
            -- v6.15.86: REJECT if the most recent cast_verify for this
            -- intent shows R didn't actually fire. The cast_outcome HP
            -- delta is then attributable to autos/Q/headshot, not R.
            if rolling_verify[intent] ~= "y" then
                n_bogus_outcome = n_bogus_outcome + 1
                goto continue
            end
            n_total = n_total + 1
            local alive = e.kv.alive == "y"
            local respawn = e.kv.respawn == "y"
            local target = e.kv.target or "?"
            local hp_dp = tonumber(e.kv.hp_delta_pct) or 0
            sum_hp_delta_pct = sum_hp_delta_pct + (hp_dp > 0 and hp_dp or 0)
            per_intent[intent] = per_intent[intent] or { casts = 0, kills = 0 }
            per_intent[intent].casts = per_intent[intent].casts + 1
            per_target[target] = per_target[target] or { casts = 0, kills = 0 }
            per_target[target].casts = per_target[target].casts + 1
            if respawn then
                n_respawn = n_respawn + 1
                n_kill = n_kill + 1
                per_intent[intent].kills = per_intent[intent].kills + 1
                per_target[target].kills = per_target[target].kills + 1
            elseif not alive then
                n_kill = n_kill + 1
                per_intent[intent].kills = per_intent[intent].kills + 1
                per_target[target].kills = per_target[target].kills + 1
            else
                n_alive = n_alive + 1
            end
            -- HP delta bucket
            local b = 0
            if hp_dp >= 100 then b = 100
            elseif hp_dp >= 75 then b = 75
            elseif hp_dp >= 50 then b = 50
            elseif hp_dp >= 25 then b = 25 end
            hp_delta_buckets[b] = hp_delta_buckets[b] + 1
            ::continue::
        end
    end
    -- v6.15.86: surface verified R fires and double-fails specifically for
    -- R steps (intent ending in "_r" - snipe_e_r_r, snipe_q_r_r, etc.).
    -- Counts Q/E/D fires don't help diagnose "did R actually go off".
    local verified_R = 0
    local double_fail_R = 0
    for intent, n in pairs(fire_count_per_intent) do
        if intent:sub(-2) == "_r" then verified_R = verified_R + n end
    end
    for intent, n in pairs(double_fail_per_intent) do
        if intent:sub(-2) == "_r" then double_fail_R = double_fail_R + n end
    end
    print(string.format("  cast_outcome events (raw):       %d", n_raw_outcome))
    print(string.format("  bogus outcomes (R never fired):  %d  ← cast_verify fired=n",
                        n_bogus_outcome))
    print(string.format("  verified R fires (fired=y on _r intents):  %d", verified_R))
    print(string.format("  R double-fails (engine cancelled cast):    %d", double_fail_R))
    if verified_R == 0 and n_raw_outcome > 0 then
        print("")
        print("  ** WARNING: R never actually fired in this session.")
        print("  ** All cast_outcome 'kills' are autos/Q/headshot - bogus attribution.")
        print("  ** Investigate cast_verify_double_fail events + r_cast_protect_veto.")
    end
    print("")
    if n_total == 0 then
        print("  (no verified R fires - see above warning)")
        os.exit(0)
    end
    local kill_rate = (n_kill / n_total) * 100
    local avg_dmg = sum_hp_delta_pct / n_total
    print(string.format("  verified R casts:   %d", n_total))
    print(string.format("  kills:              %d (%.1f%%)", n_kill, kill_rate))
    print(string.format("  alive after (FP):   %d", n_alive))
    print(string.format("  respawn-attributed: %d", n_respawn))
    print(string.format("  avg damage per R:   %.1f%% of target max HP", avg_dmg))
    print("")
    print("  hp_delta_pct distribution:")
    for _, b in ipairs({0, 25, 50, 75, 100}) do
        local label = (b == 100) and ">=100%" or string.format("%d-%d%%", b, b + 24)
        if b == 0 then label = "0-24%" end
        print(string.format("    %-9s %d", label, hp_delta_buckets[b] or 0))
    end
    print("")
    print("  per-intent kill rates:")
    local intent_keys = {}
    for k in pairs(per_intent) do intent_keys[#intent_keys + 1] = k end
    table.sort(intent_keys)
    for _, k in ipairs(intent_keys) do
        local v = per_intent[k]
        local r = v.casts > 0 and (v.kills / v.casts * 100) or 0
        print(string.format("    %-30s %d casts, %d kills (%.0f%%)",
            k, v.casts, v.kills, r))
    end
    print("")
    print("  per-target kill rates:")
    local target_keys = {}
    for k in pairs(per_target) do target_keys[#target_keys + 1] = k end
    table.sort(target_keys)
    for _, k in ipairs(target_keys) do
        local v = per_target[k]
        local r = v.casts > 0 and (v.kills / v.casts * 100) or 0
        print(string.format("    %-20s %d casts, %d kills (%.0f%%)",
            k, v.casts, v.kills, r))
    end
    os.exit(0)
elseif mode == "defense_report" then
    -- v6.15.58 (G15): defense report. Parse save_outcome events into
    -- survival rate per threat, HP nadir distribution, save latency.
    print("--- defense report ---")
    local n_total, n_alive, n_no_save = 0, 0, 0
    local per_threat = {}        -- threat → {events, alive, no_save, sum_hp_pct_min, sum_latency}
    local per_save = {}          -- save → count
    local latency_buckets = { [0]=0, [100]=0, [250]=0, [500]=0, [1000]=0 }
    local hp_nadir_buckets = { [0]=0, [25]=0, [50]=0, [75]=0, [100]=0 }
    for i = 1, #events do
        local e = events[i]
        if e.event == "save_outcome" then
            n_total = n_total + 1
            local alive = e.kv.alive == "y"
            local save_fired = e.kv.save and e.kv.save ~= "-"
            local threat = e.kv.threat or "?"
            local lat = tonumber(e.kv.latency_ms) or -1
            local hp_pct = tonumber(e.kv.hp_pct_min) or 100
            if alive then n_alive = n_alive + 1 end
            if not save_fired then n_no_save = n_no_save + 1 end
            per_threat[threat] = per_threat[threat] or {
                events = 0, alive = 0, no_save = 0,
                sum_hp_pct_min = 0, sum_latency = 0, lat_count = 0,
            }
            local t = per_threat[threat]
            t.events = t.events + 1
            if alive then t.alive = t.alive + 1 end
            if not save_fired then t.no_save = t.no_save + 1 end
            t.sum_hp_pct_min = t.sum_hp_pct_min + hp_pct
            if lat >= 0 then
                t.sum_latency = t.sum_latency + lat
                t.lat_count = t.lat_count + 1
            end
            if save_fired then
                per_save[e.kv.save] = (per_save[e.kv.save] or 0) + 1
            end
            -- Latency bucket (only if save fired)
            if lat >= 0 then
                local b = 0
                if lat >= 1000 then b = 1000
                elseif lat >= 500 then b = 500
                elseif lat >= 250 then b = 250
                elseif lat >= 100 then b = 100 end
                latency_buckets[b] = latency_buckets[b] + 1
            end
            -- HP nadir bucket
            local hb = 0
            if hp_pct >= 100 then hb = 100
            elseif hp_pct >= 75 then hb = 75
            elseif hp_pct >= 50 then hb = 50
            elseif hp_pct >= 25 then hb = 25 end
            hp_nadir_buckets[hb] = hp_nadir_buckets[hb] + 1
        end
    end
    if n_total == 0 then
        print("  (no save_outcome events found)")
        os.exit(0)
    end
    local survive = (n_alive / n_total) * 100
    print(string.format("  total threats:      %d", n_total))
    print(string.format("  survived:           %d (%.1f%%)", n_alive, survive))
    print(string.format("  no save fired:      %d", n_no_save))
    print("")
    print("  per-threat outcomes:")
    local threat_keys = {}
    for k in pairs(per_threat) do threat_keys[#threat_keys + 1] = k end
    table.sort(threat_keys)
    for _, k in ipairs(threat_keys) do
        local t = per_threat[k]
        local s = t.events > 0 and (t.alive / t.events * 100) or 0
        local avg_hp = t.events > 0 and (t.sum_hp_pct_min / t.events) or 100
        local avg_lat = t.lat_count > 0 and (t.sum_latency / t.lat_count) or -1
        print(string.format(
            "    %-50s %d events, %d alive (%.0f%%), %d no-save, avg hp_min %.0f%%, avg lat %d ms",
            k, t.events, t.alive, s, t.no_save, avg_hp, avg_lat))
    end
    print("")
    print("  per-save usage:")
    local save_keys = {}
    for k in pairs(per_save) do save_keys[#save_keys + 1] = k end
    table.sort(save_keys)
    for _, k in ipairs(save_keys) do
        print(string.format("    %-25s %d", k, per_save[k]))
    end
    print("")
    print("  save latency distribution (ms, only fired saves):")
    local lat_labels = {
        [0]    = "0-99ms",
        [100]  = "100-249ms",
        [250]  = "250-499ms",
        [500]  = "500-999ms",
        [1000] = ">=1000ms",
    }
    for _, b in ipairs({0, 100, 250, 500, 1000}) do
        print(string.format("    %-12s %d", lat_labels[b], latency_buckets[b] or 0))
    end
    print("")
    print("  HP nadir distribution (% of max HP at lowest point during threat):")
    for _, b in ipairs({0, 25, 50, 75, 100}) do
        local label = (b == 100) and ">=100%" or string.format("%d-%d%%", b, b + 24)
        if b == 0 then label = "0-24% (NEAR DEATH)" end
        print(string.format("    %-22s %d", label, hp_nadir_buckets[b] or 0))
    end
    os.exit(0)
elseif mode == "farm_report" then
    -- v0.1.91: per-wave accounting + scheduler diagnostics from the consolidated `farm` trace.
    -- Answers the bug-hunt KEY QUESTIONS: lane coverage (of N waves, how many shoved + where the
    -- misses went), prediction accuracy (NextWaveArrival vs actual), risk abandonment, camp veto,
    -- decide cadence (rearm holds). Each number is log-backed - the point is to stop eyeballing.
    local farm = {}
    for i = 1, #events do
        if events[i].event == "farm" then farm[#farm + 1] = events[i] end
    end
    if #farm == 0 then
        print("  (no `farm` events found - need a v0.1.91+ log with diag verbosity >= 1)")
        os.exit(0)
    end
    table.sort(farm, function(a, b) return (tonumber(a.kv.t) or 0) < (tonumber(b.kv.t) or 0) end)
    local function med(t) return #t > 0 and t[math.ceil(#t / 2)] or 0 end  -- t must be pre-sorted
    local t0, t1 = tonumber(farm[1].kv.t) or 0, tonumber(farm[#farm].kv.t) or 0
    print(string.format("--- farm report --- %d decides over %.0fs (t %.1f .. %.1f)", #farm, t1 - t0, t0, t1))
    -- 2026-07-28 NORMALISATION (user). Every count below is meaningless across games until it is
    -- divided by duration, and our games run 461s to 1212s - a 2.6x spread. Quoting raw counts
    -- produced three wrong readings in one session: "keen_waste 15 -> 4" is -73% raw but only
    -- -30% per minute; "wasted trips 9 -> 7" is -22% raw but +102% PER MINUTE, i.e. it got
    -- WORSE; and "deaths 2 -> 0" is not an improvement at all, because at the earlier rate a
    -- 7.7-minute game expects 0.76 deaths, so zero is simply the most likely outcome.
    -- The rate block below is printed FIRST so it is read before any raw number.
    do
        local mins = math.max(0.01, (t1 - t0) / 60)
        local n_kw, n_death = 0, 0
        for _, e in ipairs(events) do
            if e.event == "keen_waste" then n_kw = n_kw + 1
            elseif e.event == "DEATH" then n_death = n_death + 1 end
        end
        print(string.format("    game length %.1f min -- COMPARE RATES, NOT COUNTS, across games", mins))
        print(string.format("    rates/min:  decides %.1f   keen_waste %.2f   deaths %.3f%s",
            #farm / mins, n_kw / mins, n_death / mins,
            (n_death == 0 and mins < 15) and "  <- 0 deaths in a SHORT game is weak evidence" or ""))
    end
    print("")

    -- 1) pick + scheduler-action distribution
    local pick_n, act_n, recover_reason = {}, {}, {}
    for _, e in ipairs(farm) do
        pick_n[e.kv.pick or "?"] = (pick_n[e.kv.pick or "?"] or 0) + 1
        act_n[e.kv.act or "?"] = (act_n[e.kv.act or "?"] or 0) + 1
        if e.kv.act == "recover" then recover_reason[e.kv.reason or "?"] = (recover_reason[e.kv.reason or "?"] or 0) + 1 end
    end
    local function dump(title, tbl, indent)
        print(title)
        local ks = {}; for k in pairs(tbl) do ks[#ks + 1] = k end; table.sort(ks)
        for _, k in ipairs(ks) do print(string.format("%s%-14s %d", indent, k, tbl[k])) end
    end
    dump("pick distribution (final FSM action per decide):", pick_n, "    ")
    dump("scheduler action (Tier-1 Schedule.Plan):", act_n, "    ")
    if next(recover_reason) then dump("  recover reasons:", recover_reason, "      ") end
    print("")

    -- 2) per-wave coverage (spawn grid): for each predicted mid arrival, was there a shove near it?
    local first_wave = WAVE_PHASE + math.ceil((t0 - WAVE_PHASE) / WAVE_PERIOD) * WAVE_PERIOD
    local n_wave, n_shoved, miss = 0, 0, {}
    for A = first_wave, t1, WAVE_PERIOD do
        n_wave = n_wave + 1
        local lo, hi = A - WAVE_PERIOD / 2, A + WAVE_PERIOD / 2
        local shoved, pc = false, {}
        for _, e in ipairs(farm) do
            local t = tonumber(e.kv.t) or -1
            if t >= lo and t < hi then
                -- ALL-LANES: only a MID shove counts as mid-wave coverage; a side-lane
                -- shove is a miss destination for the mid grid (it farmed elsewhere).
                if e.kv.pick == "shove" and (e.kv.lane or "mid") == "mid" then shoved = true
                else
                    local key = e.kv.pick or "?"
                    if key == "shove" then key = "side:" .. (e.kv.lane or "?")
                    elseif key == "camp" or key == "wave" then key = "jungle"
                    elseif key == "recover" then key = "recover:" .. (e.kv.reason or "?") end
                    pc[key] = (pc[key] or 0) + 1
                end
            end
        end
        if shoved then n_shoved = n_shoved + 1
        else
            -- ATTRIBUTION RULE (read this before quoting a miss-destination number):
            -- a missed wave is attributed to the MODAL destination of its window, i.e. the
            -- key with the most farm decides in [A-15, A+15). The rule is total:
            --   exactly one key at the max -> that key
            --   several keys at the max    -> "tie:a+b" (sorted, joined by +). The bot did
            --                                 several things in that window and there is no
            --                                 fact of the matter about where the wave "went";
            --                                 picking one would be a coin flip, not a finding.
            --   window empty               -> "no_data" (a telemetry gap, NOT the real
            --                                 pick=none, which is a genuine destination here)
            -- pairs() order is unspecified and reseeded per process, so the max is collected
            -- order-independently and the tie list is sorted. Do not reintroduce a
            -- "first c > bn wins" argmax: that printed a different answer on every run.
            local bn, tied = -1, {}
            for k, c in pairs(pc) do
                if c > bn then bn, tied = c, { k }
                elseif c == bn then tied[#tied + 1] = k end
            end
            table.sort(tied)
            local best = (#tied == 0 and "no_data")
                or (#tied == 1 and tied[1])
                or ("tie:" .. table.concat(tied, "+"))
            miss[best] = (miss[best] or 0) + 1
        end
    end
    print(string.format("per-wave coverage (spawn grid phase=%d period=%d - CALIBRATION ASSUMPTION):", WAVE_PHASE, WAVE_PERIOD))
    print(string.format("    waves in window:  %d", n_wave))
    print(string.format("    shoved:           %d (%.0f%%)", n_shoved, n_wave > 0 and n_shoved / n_wave * 100 or 0))
    print(string.format("    missed:           %d", n_wave - n_shoved))
    if next(miss) then dump("    miss destinations:", miss, "        ") end
    print("")

    -- 3) prediction accuracy: on a vis n->y rising edge (mid wave appears), actual t vs last predicted dl.
    local errs, prev_vis, prev_dl = {}, nil, nil
    for _, e in ipairs(farm) do
        if e.kv.vis == "y" and prev_vis == "n" and prev_dl then
            local actual = tonumber(e.kv.t)
            if actual then errs[#errs + 1] = actual - prev_dl end
        end
        if e.kv.vis == "n" then prev_dl = tonumber(e.kv.dl) end
        prev_vis = e.kv.vis
    end
    print("prediction accuracy (actual mid-wave appearance vs predicted NextWaveArrival dl):")
    if #errs == 0 then print("    (no vis n->y transitions captured)")
    else
        table.sort(errs)
        local sum = 0; for _, x in ipairs(errs) do sum = sum + x end
        print(string.format("    samples: %d  median: %.1fs  mean: %.1fs  min: %.1f  max: %.1f",
            #errs, med(errs), sum / #errs, errs[1], errs[#errs]))
        print("    (positive = wave appeared LATER than predicted; negative = EARLIER)")
    end
    local shove_blind = 0
    for _, e in ipairs(farm) do if e.kv.pick == "shove" and e.kv.vis == "n" and (e.kv.lane or "mid") == "mid" then shove_blind = shove_blind + 1 end end
    print(string.format("    shoves toward a FOGGED (predicted) wave (pick=shove vis=n): %d", shove_blind))

    -- ALL-LANES: side-lane picks + swave verdict tallies (phase-1 validation view)
    local spick, sverd = { top = 0, bot = 0 }, {}
    for _, e in ipairs(farm) do
        local ln = e.kv.lane
        if e.kv.pick == "shove" and (ln == "top" or ln == "bot") then spick[ln] = spick[ln] + 1 end
        for _, k in ipairs({ "swtop", "swbot" }) do
            local v = e.kv[k]
            if v then
                local verdict = v:match("^([^:]+)")
                if verdict then sverd[verdict] = (sverd[verdict] or 0) + 1 end
            end
        end
    end
    print("")
    print(string.format("side-lane picks: top=%d bot=%d", spick.top, spick.bot))
    if next(sverd) then dump("side-lane swave verdicts:", sverd, "    ") end

    -- v0.1.230 WASTED-TRIP instrument (the run-49 t=176 signature): a pick=shove decide
    -- with real travel that never cast a single W before the next decide = the trip's
    -- transport was pure loss. Evidence base for the deferred gone-by-STAND-arrival rule.
    -- 2026-07-27, TWO MEASUREMENT BUGS FIXED. Both inflated this number, and it was quoted
    -- as the largest waste in the game for several sessions on that inflated basis (g355
    -- read 19 trips / 176s; the truth is 13 / 49s).
    --   1. `e.kv.src == "shove"` was an EXACT match, but the shove family emits FOUR src
    --      values - `shove` (:5449), `shove_pre` (:4901/:4763) and `shove_w2` (:4687/:4881)
    --      are ALL genuine March casts on a shove trip. Exact-matching counted only the
    --      first, so a trip that pre-cast W1 (the GPM-first fast-shove doctrine) or
    --      delivered W2 was scored "zero W". In g355 that over-counted by 6 of 19.
    --   2. `travel` is the PREDICTED travel at decide time, not time actually spent. Eight
    --      of g355's 13 trips were re-decided within 0.5s, so that prediction was never
    --      paid. Summing it turned 49s of real elapsed time into a reported 176s. Both are
    --      printed now; ACTUAL is the one to reason about.
    --   3. 2026-07-27, THE THIRD BUG: a legitimate TETHER pre-position scored as waste
    --      whenever the decide boundary landed inside the hold. Pre-positioning early and
    --      waiting for the wave is GPM-first DOCTRINE, not loss. It was the single largest
    --      class left after fixes 1 and 2: g356 had 6 such trips worth 69.7s of the 154s, and
    --      g355's biggest survivor (16.2s, `tether hold=... eta=live+10.8`) was one too. A
    --      `tether` event inside the window now disqualifies the trip, and held trips are
    --      counted separately so the exclusion stays visible instead of silently shrinking
    --      the number.
    local wasted, wtravel, wactual, cur_shove, cast_seen = {}, 0, 0, nil, false
    local wheld, wheld_s = 0, 0
    local tether_seen = false
    for _, e in ipairs(events) do
        if e.event == "farm" then
            if cur_shove and not cast_seen and (tonumber(cur_shove.kv.travel) or 0) > 2 then
                local el = math.max(0, (tonumber(e.kv.t) or 0) - (tonumber(cur_shove.kv.t) or 0))
                if tether_seen then
                    wheld = wheld + 1; wheld_s = wheld_s + el
                else
                    local ln = cur_shove.kv.lane or "mid"
                    wasted[ln] = (wasted[ln] or 0) + 1
                    wtravel = wtravel + (tonumber(cur_shove.kv.travel) or 0)
                    wactual = wactual + el
                end
            end
            cur_shove = (e.kv.pick == "shove") and e or nil
            cast_seen = false
            tether_seen = false
        elseif e.event == "march_aim" and tostring(e.kv.src or ""):match("^shove") then
            cast_seen = true
        elseif e.event == "tether" then
            tether_seen = true          -- a deliberate pre-position hold, not a wasted trip
        end
    end
    local wn = 0
    for _, c in pairs(wasted) do wn = wn + c end
    if wn > 0 then
        local parts = {}
        for ln, c in pairs(wasted) do parts[#parts + 1] = string.format("%s=%d", ln, c) end
        table.sort(parts)   -- pairs() order is unspecified; stable print once >1 lane contributes
        print(string.format("wasted shove trips (travel>2s, zero W, NOT a tether hold): %d (%s)",
            wn, table.concat(parts, " ")))
        print(string.format("    ACTUAL elapsed %.0fs  (est travel %.0fs - the ESTIMATE is not what was spent; reason about ACTUAL)",
            wactual, wtravel))
        do  -- 2026-07-28: normalised, because the raw count misled across a 461s vs 1212s pair
            local mins = math.max(0.01, (t1 - t0) / 60)
            print(string.format("    NORMALISED: %.2f trips/min, %.1f%% of game time  <- compare THESE across games",
                wn / mins, 100 * wactual / math.max(1, t1 - t0)))
        end
    else
        print("wasted shove trips (travel>2s, zero W, NOT a tether hold): 0")
    end
    if wheld > 0 then
        print(string.format("    excluded: %d trip(s), %.0fs, that were a deliberate TETHER pre-position (doctrine, not waste)",
            wheld, wheld_s))
    end
    print("")

    -- 3b) DEATHS. 2026-07-27: nothing here ever reported a death, so they surfaced as
    -- STILLNESS in --time-report (g356's 54.6s death printed as `camp hold=51.0s
    -- reason=unsafe`) and three sessions of "0 deaths" came from grepping a token the log
    -- never contained. v0.1.356 emits DEATH/RESPAWN; logs older than that have neither, so
    -- the fallback message says UNKNOWN rather than 0 - absence of the line is not evidence.
    local deaths, downtime = {}, 0
    for _, e in ipairs(events) do
        if e.event == "DEATH" then deaths[#deaths + 1] = e
        -- the extra paren pair is load-bearing: gsub returns (string, count), and as the last
        -- argument both are passed, so tonumber got the REPLACEMENT COUNT as its BASE and
        -- `--with-takeover` aborted with "base out of range" on any log carrying a RESPAWN.
        elseif e.event == "RESPAWN" then downtime = downtime + (tonumber(((e.kv.down or ""):gsub("s$", ""))) or 0) end
    end
    local function death_row(d)
        return string.format("    t=%-7s fsm=%-7s spot=%-6s mana=%-5s pos=%-14s saves=%s",
            d.kv.t or "?", d.kv.fsm or "?", d.kv.spot or "?", d.kv.mana or "?",
            d.kv.pos or "?", d.kv.saves or "?")
    end
    if #deaths > 0 then
        print(string.format("DEATHS: %d  (downtime %.0fs)", #deaths, downtime))
        for _, d in ipairs(deaths) do print(death_row(d)) end
    else
        -- THE VERSION GATE. Was a literal `v0%.1%.35[6-9]`, which stopped matching at v0.1.360
        -- and printed "predates v0.1.356" for g364, g365 and g366 - three consecutive logs whose
        -- build DOES carry the instrument. Parse the number instead, the same test :2286 already
        -- uses, so this cannot rot again at v0.1.400. The old `e.kv.brain` disjunct went with it:
        -- `brain=` occurs zero times in all 26 corpus logs, so it never fired.
        -- the two reasons for UNKNOWN are different problems and want different fixes, and we
        -- can tell them apart: an OLD build cannot be helped, a MISSING banner can (re-run raw).
        local seen_v, banner = nil, false
        for _, e in ipairs(events) do
            local bv = tonumber((e.raw or ""):match("Tinker brain v0%.1%.(%d+)") or "")
            if bv then
                seen_v = math.max(seen_v or 0, bv)
                if bv >= 356 then banner = true; break end
            end
        end
        if banner then
            print("DEATHS: 0 brain-owned")
        elseif seen_v then
            print(string.format("DEATHS: UNKNOWN - build v0.1.%d predates the v0.1.356 DEATH log "
                                .. "(absence is NOT zero)", seen_v))
        else
            print("DEATHS: UNKNOWN - no Tinker banner in this input (absence is NOT zero).\n"
                  .. "    A hand-SPLIT log cuts the banner off: re-run on the RAW file.")
        end
    end
    -- excised deaths are the USER dying mid-takeover, never the brain - but say so out loud,
    -- because a silent drop is indistinguishable from no death at all.
    if takeover_deaths and #takeover_deaths > 0 then
        print(string.format("    (+%d DEATH(s) inside user-takeover windows, NOT brain-owned:)", #takeover_deaths))
        for _, d in ipairs(takeover_deaths) do print(death_row(d)) end
    end
    print("")

    -- 4) mid abandonment on risk
    -- 2026-07-27 RULER MISMATCH FIXED. This reported `risk` (the LOCAL read at the hero)
    -- while the unsafe verdict is driven by `prisk` (the PATH risk to the target). That is
    -- what produced the long-standing "low-risk unsafe recover" anomaly - g345's "15 unsafe
    -- recovers, median risk 0.02" and g356's "median 0.06" were never a bot defect, just the
    -- wrong column. In g356 the pairs read prisk 0.49/0.75/0.55/0.98/0.74/0.60 against risk
    -- 0.00/0.13/0.32/0.23/0.02: the decision was consistently right. Both print now, prisk
    -- first, because prisk is the one the gate actually consults.
    local urisk, uprisk = {}, {}
    for _, e in ipairs(farm) do
        if e.kv.act == "recover" and e.kv.reason == "unsafe" then
            local r = tonumber(e.kv.risk); if r then urisk[#urisk + 1] = r end
            local p = tonumber(e.kv.prisk); if p then uprisk[#uprisk + 1] = p end
        end
    end
    print("mid abandonment on risk (act=recover reason=unsafe):")
    if #urisk == 0 and #uprisk == 0 then print("    (none)")
    else
        table.sort(urisk); table.sort(uprisk)
        if #uprisk > 0 then
            print(string.format("    count: %d  median PRISK: %.2f  min: %.2f  max: %.2f   <- the field the gate uses",
                #uprisk, med(uprisk), uprisk[1], uprisk[#uprisk]))
        end
        if #urisk > 0 then
            print(string.format("    (local risk at the hero, NOT the trigger: median %.2f  min %.2f  max %.2f)",
                med(urisk), urisk[1], urisk[#urisk]))
        end
    end
    print("")

    -- 5) camp veto proximity + reserve-vs-budget (lost-lane)
    local crisks, under_reserve, camp_n = {}, 0, 0
    for _, e in ipairs(farm) do
        if e.kv.pick == "camp" then
            camp_n = camp_n + 1
            local r = tonumber(e.kv.crisk); if r then crisks[#crisks + 1] = r end
            local b, rsv = tonumber(e.kv.budget), tonumber(e.kv.reserve)
            if b and rsv and b < rsv then under_reserve = under_reserve + 1 end
        end
    end
    print(string.format("camp picks: %d", camp_n))
    if #crisks > 0 then
        table.sort(crisks)
        print(string.format("    crisk median: %.2f  max: %.2f  (RISK_HARD veto = 0.34)", med(crisks), crisks[#crisks]))
        local near = 0; for _, x in ipairs(crisks) do if x >= 0.30 then near = near + 1 end end
        print(string.format("    camps picked at crisk >= 0.30 (near veto): %d", near))
    end
    print(string.format("    camps taken with camp-time budget < return reserve (lost-lane risk): %d", under_reserve))
    print("")

    -- 6) decide cadence (rearm holds) + gpm trend
    local gaps = {}
    for i = 2, #farm do
        local d = (tonumber(farm[i].kv.t) or 0) - (tonumber(farm[i - 1].kv.t) or 0)
        if d >= 0 then gaps[#gaps + 1] = d end
    end
    table.sort(gaps)
    -- NOTE: fsm_decide only re-decides when the FSM needs a NEW target (after a shove/camp
    -- finishes), so a "gap" is the DURATION of one farm action, NOT a stall. A burst of < 0.6s
    -- gaps means plan=0 flutter (no affordable spot) or a same-wave shove follow-up, not a hang.
    local flutter = 0; for _, g in ipairs(gaps) do if g < 0.6 then flutter = flutter + 1 end end
    print("decide cadence (gap = duration of one farm action; NOT a per-tick stall):")
    if #gaps > 0 then
        local span = t1 - t0
        print(string.format("    decides: %d over %.0fs (%.1f/min)  median action: %.1fs  max: %.1fs  rapid re-decides (<0.6s, plan=0 flutter / same-wave): %d",
            #farm, span, span > 0 and #farm / span * 60 or 0, med(gaps), gaps[#gaps], flutter))
    end
    local first_gpm, last_gpm
    for _, e in ipairs(farm) do if e.kv.gpm then first_gpm = first_gpm or e.kv.gpm; last_gpm = e.kv.gpm end end
    if first_gpm then print(string.format("    gpm: %s -> %s", first_gpm, last_gpm)) end
    os.exit(0)
elseif mode == "lane_report" then
    -- Piece 1 (lane foundation): measure the WAVE INSTRUMENTS against observed reality, from the 2s
    -- auto-wavescan series (clean k=v format). Every number is log-backed: arrival timing vs
    -- NextWaveArrival + the REAL spawn-grid phase (the WAVE_PHASE calibration), ExpectedWave hp truth
    -- at est->real transitions, and meeting drift (how far the early meeting estimate moved by arrival).
    local function pt(s)
        if not s or s == "-" then return nil end
        local x, y = s:match("^(%-?%d+);(%-?%d+)$")
        return x and { x = tonumber(x), y = tonumber(y) } or nil
    end
    local function dist(p, q)
        if not (p and q) then return nil end
        local dx, dy = p.x - q.x, p.y - q.y
        return math.sqrt(dx * dx + dy * dy)
    end
    local scans, hdr = {}, nil
    for i = 1, #events do
        local e = events[i]
        if e.event == "wavescan" then
            if e.kv.t and not e.kv.ln then
                hdr = e.kv
            elseif e.kv.ln == "mid" and hdr then
                local kp = tonumber(hdr.kpred)
                scans[#scans + 1] = {
                    t = tonumber(hdr.t) or 0, pred = tonumber(hdr.pred),
                    kpred = (kp and kp >= 0) and kp or nil,   -- Piece 1.5: kinematic candidate (-1 = unavailable)
                    e = tonumber(e.kv.e) or 0, est = e.kv.est == "y",
                    src = e.kv.src, hp = tonumber(e.kv.hp) or 0,
                    bal = tonumber(e.kv.bal),                 -- Piece 1.5: sim balance (+ = our lane pushes)
                    ef = pt(e.kv.ef), af = pt(e.kv.af), meet = pt(e.kv.meet),
                }
            end
        end
    end
    if #scans == 0 then
        print("  (no k=v wavescan events - need the Piece-1 format + diag verbosity >= 1)")
        os.exit(0)
    end
    table.sort(scans, function(a, b) return a.t < b.t end)
    local function med(t) table.sort(t); return #t > 0 and t[math.ceil(#t / 2)] or 0 end
    print(string.format("--- lane instruments report --- %d mid scans over %.0fs (t %.1f .. %.1f)",
        #scans, scans[#scans].t - scans[1].t, scans[1].t, scans[#scans].t))
    local real = 0
    for _, s in ipairs(scans) do if s.e > 0 and not s.est then real = real + 1 end end
    print(string.format("  vision coverage: %d/%d scans see a REAL enemy mid wave (rest fogged-est/empty)", real, #scans))
    print("")

    -- 1) ARRIVALS: a REAL enemy front within ARRIVE_D of the meeting = an observed arrival.
    --    CYCLE GATE (v2): in a continuous lane battle the enemy front sits near the meeting the whole
    --    time, so a naive proximity+dedup trigger re-fires every dedup window (the first run showed
    --    impossible ~22s inter-arrivals on a 30s spawn grid = engagement re-detections). A NEW arrival
    --    only counts after the front has first RETREATED beyond RESET_D from the meeting (the fresh
    --    wave spawning far) - one event per genuine approach cycle.
    --    err = pred (from the scan just before) - actual t. Median observed PHASE = the true WAVE_PHASE.
    local ARRIVE_D, RESET_D = 400, 1200
    local arrivals, armed = {}, true
    for i = 1, #scans do
        local s = scans[i]
        local d = (not s.est) and s.e > 0 and dist(s.ef, s.meet) or nil
        if d and d > RESET_D then armed = true end
        if armed and d and d <= ARRIVE_D then
            local prev = scans[i - 1]
            arrivals[#arrivals + 1] = { t = s.t, phase = s.t % 30, i = i,
                                        pred = (prev and prev.pred) or s.pred,
                                        kpred = (prev and prev.kpred) or s.kpred }
            armed = false
        end
    end
    print(string.format("wave ARRIVALS observed (real enemy front within %du of the meeting): %d", ARRIVE_D, #arrivals))
    local errs, kerrs, phases = {}, {}, {}
    for _, a in ipairs(arrivals) do
        local err  = a.pred and (a.pred - a.t) or nil
        local kerr = a.kpred and (a.kpred - a.t) or nil
        if err  then errs[#errs + 1] = err end
        if kerr then kerrs[#kerrs + 1] = kerr end
        phases[#phases + 1] = a.phase
        print(string.format("    t=%.1f phase=%.1f pred=%s err=%s kpred=%s kerr=%s", a.t, a.phase,
            a.pred and string.format("%.1f", a.pred) or "-",
            err and string.format("%+.1f", err) or "-",
            a.kpred and string.format("%.1f", a.kpred) or "-",
            kerr and string.format("%+.1f", kerr) or "-"))
    end
    if #phases > 0 then
        print(string.format("  observed spawn-grid phase: median %.1f (K.WAVE_PHASE calibration; current %d)", med(phases), WAVE_PHASE))
    end
    if #errs > 0 then
        print(string.format("  grid pred error (pred-actual): median %+.1fs over %d arrivals (+late/-early; ~+25 means the phase is ~5s EARLY, grid rolled)", med(errs), #errs))
    end
    if #kerrs > 0 then
        print(string.format("  KINEMATIC kpred error: median %+.1fs over %d arrivals (Piece 1.5 candidate; wins -> replaces the grid in Piece 2)", med(kerrs), #kerrs))
    end
    print("")

    -- 2) estimate truth at est->real transitions (<=6s apart): hp (ExpectedWave clock model) and,
    --    when the estimate carried a MIRRORED front, position error (the Piece 1.5 mirror on trial).
    local pairs_n, hp_errs, pos_errs = 0, {}, {}
    for i = 2, #scans do
        local p, s = scans[i - 1], scans[i]
        if p.est and p.hp > 0 and (not s.est) and s.e > 0 and s.hp > 0 and (s.t - p.t) <= 6 then
            pairs_n = pairs_n + 1
            hp_errs[#hp_errs + 1] = (p.hp - s.hp) / s.hp * 100
            local pe = dist(p.ef, s.ef)
            if pe then pos_errs[#pos_errs + 1] = pe end
        end
    end
    print(string.format("estimate truth (est->real transitions <=6s apart): %d pairs", pairs_n))
    if pairs_n > 0 then
        print(string.format("  est-vs-real hp error: median %+.0f%% (positive = estimate runs HIGH)", med(hp_errs)))
    end
    if #pos_errs > 0 then
        local mx = 0
        for _, d in ipairs(pos_errs) do if d > mx then mx = d end end
        print(string.format("  MIRROR position error (mirrored front vs first real front): median %.0fu, max %.0fu over %d", med(pos_errs), mx, #pos_errs))
    else
        print("  (no mirrored-front transitions captured - mirror position unjudged this run)")
    end
    print("")

    -- 3) MEETING DRIFT: the meeting estimate at the START of each approach cycle vs at arrival - how
    --    far the aim (and so the stand computed from it) moved while the wave closed.
    local drifts = {}
    for _, a in ipairs(arrivals) do
        local firstMeet
        for j = a.i - 1, 1, -1 do
            local s = scans[j]
            if a.t - s.t > 25 then break end
            if s.e > 0 and s.meet then firstMeet = s.meet end   -- keep walking back to the cycle start
        end
        local d = dist(firstMeet, scans[a.i].meet)
        if d then drifts[#drifts + 1] = d end
    end
    print(string.format("meeting drift (estimate at cycle start vs at arrival): %d cycles", #drifts))
    if #drifts > 0 then
        local mx = 0
        for _, d in ipairs(drifts) do if d > mx then mx = d end end
        print(string.format("  drift: median %.0fu, max %.0fu (large = the early aim/stand was computed from a lying meeting)", med(drifts), mx))
    end
    print("")

    -- 4) PUSH BALANCE judge (Piece 1.5 sim on trial): a scan's bal (net survivors, + = our lane
    --    pushes) should predict the direction the front MIDPOINT moves over the next ~8-14s. dir =
    --    unit(ef - af) (toward the enemy side); delta = (mid_later - mid_now) . dir; bal > 0 should
    --    give delta > 0. Sign-match rate over all judgeable samples, DEAD_D deadband on tiny moves.
    local DEAD_D, match, miss, nsamp = 60, 0, 0, 0
    for i = 1, #scans do
        local s = scans[i]
        if s.bal and s.bal ~= 0 and (not s.est) and s.ef and s.af then
            for j = i + 1, #scans do
                local u = scans[j]
                if u.t - s.t > 14 then break end
                if u.t - s.t >= 8 and (not u.est) and u.ef and u.af then
                    local dx, dy = s.ef.x - s.af.x, s.ef.y - s.af.y
                    local dl = math.sqrt(dx * dx + dy * dy)
                    if dl > 1 then
                        local mx0, my0 = (s.ef.x + s.af.x) / 2, (s.ef.y + s.af.y) / 2
                        local mx1, my1 = (u.ef.x + u.af.x) / 2, (u.ef.y + u.af.y) / 2
                        local delta = ((mx1 - mx0) * dx + (my1 - my0) * dy) / dl
                        if math.abs(delta) > DEAD_D then
                            nsamp = nsamp + 1
                            if (s.bal > 0) == (delta > 0) then match = match + 1 else miss = miss + 1 end
                        end
                    end
                    break
                end
            end
        end
    end
    print(string.format("push-balance judge (sim bal sign vs observed front-midpoint movement 8-14s later): %d samples", nsamp))
    if nsamp > 0 then
        print(string.format("  sign-match rate: %d%% (%d match / %d miss; >70%% = the sim earns decision duty)",
            math.floor(match / nsamp * 100 + 0.5), match, miss))
    end
    os.exit(0)
elseif mode == "cycle_report" then
    -- Task #12 (TINKER_ANCHOR_REACH_STUDY.md): per-shove-cycle walk/wait accounting. Reconstructs
    -- decide -> keen -> tether -> step_out -> engage from the ordered stream; `now` interpolates
    -- from any event with kv.t (farm decides + the 2s wavescan SCAN series).
    local now_t = 0
    local cyc, cycles = nil, {}
    for _, e in ipairs(events) do
        local ts = tonumber(e.kv.t)
        if ts then now_t = ts end
        if e.event == "farm" and e.kv.pick == "shove" then
            cyc = { t0 = now_t, sx = e.kv.sx or "?", sy = e.kv.sy or "?",
                    travel = e.kv.travel, asrc = e.kv.asrc }
            cycles[#cycles + 1] = cyc
        elseif cyc then
            if e.event == "lane_go" and e.raw:find("lane_go keen") then
                cyc.keen_t = cyc.keen_t or now_t
            elseif e.event == "keen_to_anchor" then
                cyc.residual = tonumber(e.kv.residual)
                cyc.anchor = e.kv.anchor              -- Phase 2: anchor=creep marks a RAID keen
            elseif e.event == "tether" then
                cyc.tether_t = cyc.tether_t or now_t
            elseif e.event == "step_out" then
                cyc.out_t = now_t; cyc.out_eta = e.kv.eta; cyc.out_walk = e.kv.walk
            elseif e.event == "wave_engage_arrived" and not cyc.arr_t then
                cyc.arr_t = now_t
                cyc.trig, cyc.dwave = e.kv.trig, tonumber(e.kv.dWave)
                cyc.eta_err = e.kv.eta_err
            end
        end
    end
    print(string.format("--- cycle report --- %d shove cycles", #cycles))
    print(string.format("%-7s %-16s %-6s %-7s %-7s %-8s %-8s %-7s %-7s %-7s %-6s %-7s",
        "t0", "stand", "asrc", "travel", "anchor", "residual", "tether_s", "out_t", "arr_t", "dWave", "trig", "eta_err"))
    local transit, tether_s, n, early = 0, 0, 0, 0
    for _, c in ipairs(cycles) do
        local walk = (c.arr_t and c.keen_t) and (c.arr_t - c.keen_t) or nil
        local teth = (c.tether_t and (c.out_t or c.arr_t)) and ((c.out_t or c.arr_t) - c.tether_t) or nil
        if walk then transit = transit + walk; n = n + 1 end
        if teth then tether_s = tether_s + teth end
        -- run-10 lesson: a timed cast at dWave ~1140 with eta_err ~0 is the DESIGNED sweep of an
        -- arriving wave (robots deliver over 6s); true earliness = the cast firing well before eta.
        local ee = tonumber(c.eta_err)
        if c.trig == "time" and ee and ee > 3 then early = early + 1 end
        print(string.format("%-7s %-16s %-6s %-7s %-7s %-8s %-8s %-7s %-7s %-7s %-6s %-7s",
            c.t0, "(" .. c.sx .. "," .. c.sy .. ")", c.asrc or "-", c.travel or "-",
            c.anchor or "-", c.residual or "-", teth and string.format("%.1f", teth) or "-",
            c.out_t or "-", c.arr_t or "-", c.dwave or "-", c.trig or "-", c.eta_err or "-"))
    end
    local t0 = tonumber(cycles[1] and cycles[1].t0) or 0
    local t1 = now_t
    local span = math.max(1, t1 - t0)
    print(string.format("\nkeen->engage transit: %.0fs over %d cycles (%.1fs avg, %.0f%% of %.0fs span)",
        transit, n, n > 0 and transit / n or 0, 100 * transit / span, span))
    print(string.format("tether time: %.0fs   early timed casts (trig=time eta_err>+3s): %d", tether_s, early))
    print("targets: transit share < 10%, early timed casts = 0, tether lines present on fogged cycles")
    os.exit(0)
elseif mode == "keen_report" then
    -- Keen-efficiency arc STEP 1 (bridge 2026-07-20): every keen classified by outcome.
    -- Events: keen_to_anchor (fields: anchor/land/residual) + keen_home (bare). The lane_go
    -- line logs AFTER the keen helper returns -> stamp it onto the latest unstamped anchor.
    -- Clock interpolates from kv.t (decides + 2s wavescan), same as cycle_report.
    -- Known log gaps (instrumentation candidates if the classes look wrong): no from-position
    -- on any keen (jump length unknowable -> "walk was comparable" is judged by residual only),
    -- keen_home has no coords/purpose, no mana on cast lines (nearest decide's mana= stands in).
    local now_t, t_first = 0, nil
    local keens, acts, dec, pending = {}, {}, nil, nil
    for seq, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        if e.event == "farm" and e.kv.pick then
            t_first = t_first or now_t
            dec = { t = now_t, pick = e.kv.pick, mana = e.kv.mana, klvl = e.kv.klvl,
                    reason = e.kv.reason, act = e.kv.act,
                    -- v0.1.345: a keen dispatched into a tower DEFENSE is not farm waste even when
                    -- no cast follows (g347 t=623.4 keened 12200 to bot where the next scan read
                    -- crash=allyTwr; it scored "bounce"). Either the Plan reason or a side verdict
                    -- of `defend` marks it.
                    defend = (e.kv.reason == "defend_crash")
                             or (e.kv.swtop or ""):find("defend", 1, true) ~= nil
                             or (e.kv.swbot or ""):find("defend", 1, true) ~= nil }
        elseif e.event == "keen_to_anchor" then
            local k = { t = now_t, seq = seq, kind = "anchor", anchor = e.kv.anchor,
                residual = tonumber(e.kv.residual), dec = dec,
                jump = tonumber(e.kv.jump), cmana = e.kv.mana }   -- v0.1.331 instrumentation
            -- rearm_reset_keen logs BEFORE its keen (the rearm channel sits between) and is a
            -- mana fact (rearm burned on top), not the purpose: flag it, let lane_go name the purpose
            if pending and now_t - pending.t <= 8 then k.rearm = true end
            pending = nil
            keens[#keens + 1] = k
        elseif e.event == "keen_home" and e.raw:find("FIRED", 1, true) then
            -- FIRED only: an issued_NOT_fired line is a swallowed order, not a teleport (g331 t=318.9)
            keens[#keens + 1] = { t = now_t, seq = seq, kind = "home", dec = dec,
                purpose = e.kv.purpose, cmana = e.kv.mana }       -- v0.1.331 instrumentation
            pending = nil
        elseif e.event == "lane_go" then
            local variant = e.raw:match("lane_go%s+(.+)$")
            local k = keens[#keens]
            if variant and variant:find("keen") then
                if k and k.kind == "anchor" and not k.caller and now_t - k.t <= 5 then
                    k.caller = variant          -- lane_go keen / keen raid log AFTER the cast
                else
                    pending = { variant = variant, t = now_t }
                end
            end
        elseif e.event == "march_aim" or e.event == "engage_done" or e.event == "refill_done" then
            acts[#acts + 1] = { t = now_t, seq = seq, what = e.event }
        end
    end
    -- stream order (seq), not clock, decides before/after: the 2s interpolated clock ties a
    -- same-window cast to its keen (raids cast ~2s after landing) and a > test dropped them;
    -- seq1 (the next keen) bounds the other side so a tied-clock act never double-attributes
    local function farmed_between(seq0, t1, seq1)
        for _, a in ipairs(acts) do
            if a.seq > seq0 and a.t <= t1 and (not seq1 or a.seq < seq1) then return a.what end
        end
        return nil
    end
    local BOUNCE_S, PROD_S, LONGWALK_R = 15, 25, 1000
    -- v0.1.345: a keen whose OUTCOME WINDOW overlaps manual play is unscoreable - the brain is off,
    -- so "nothing farmed" says nothing about the brain. The keen itself often fires just BEFORE the
    -- bracket (g347 t=273.0: keened, then the user took over and cast W1/Rearm/W2 by hand), so
    -- excising takeover EVENTS is not enough - the window must be checked here.
    local function takeover_overlap(t0, t1)
        for _, sp in ipairs(takeover_spans or {}) do
            if t0 <= sp.t1 and t1 >= sp.t0 then return true end
        end
        return false
    end
    local order = { "bounce", "home-cycle", "long-walk", "short-hop", "home-refill", "raid", "productive", "defend", "takeover" }
    local classes = {}
    for _, c in ipairs(order) do classes[c] = { n = 0, resid = 0, residn = 0, mana = 0 } end
    local callers = {}
    for i, k in ipairs(keens) do
        local nxt = keens[i + 1]
        k.ndt = nxt and (nxt.t - k.t) or nil
        local horizon = math.min(k.t + PROD_S, nxt and nxt.t or (k.t + PROD_S))
        k.farmed = farmed_between(k.seq, horizon, nxt and nxt.seq)
        if k.kind == "home" then
            -- purpose= (v0.1.331) is the truth when present: the transport layer's low-mana
            -- return fires BETWEEN decides (g331: purpose=return castmana=75-183 with a stale
            -- camp/shove decide attached - legit refills the old decide-pick heuristic miscalled)
            local genuine
            if k.purpose then genuine = (k.purpose == "return")
            else genuine = k.dec and (k.dec.pick == "refill" or k.dec.act == "recover") end
            k.class = genuine and "home-refill" or "home-cycle"
        elseif k.caller and k.caller:find("raid") and k.farmed then
            -- v0.1.351 tools fix (g352, USER-WATCHED TWICE): this arm used to fire on the
            -- CALLER alone, so a "keen raid" that farmed NOTHING was scored as a designed
            -- use and never counted as waste. g352 t=698.0 and t=838.8 are exactly that -
            -- creep-anchor raids, residual=0, zero W, both spotted by the user while the
            -- report claimed 1 wasted keen out of 64. The whole point of a raid is to farm
            -- a deep creep, so an empty raid IS waste and must fall through to the outcome
            -- classes below (both land in "bounce": re-keen within BOUNCE_S, nothing
            -- farmed). NOTE the sibling arm at "defend" is deliberately NOT outcome-gated -
            -- a tower defense is a designed use even with no cast (the v0.1.345/.346
            -- lesson, where legitimate defends were being mis-scored as bounces).
            k.class = "raid"
        elseif takeover_overlap(k.t, horizon) then
            k.class = "takeover"          -- manual play covered the outcome window: UNSCOREABLE, not waste
        elseif k.dec and k.dec.defend then
            k.class = "defend"            -- a tower defense is a designed use even with no cast
        elseif k.ndt and k.ndt <= BOUNCE_S and not farmed_between(k.seq, nxt.t, nxt.seq) then
            k.class = "bounce"
        elseif k.residual and k.residual > LONGWALK_R then
            k.class = "long-walk"
        elseif k.farmed then
            k.class = "productive"
        else
            k.class = "short-hop"
        end
        local c = classes[k.class]
        c.n = c.n + 1
        c.mana = c.mana + 75 + (k.rearm and 225 or 0)
        if k.residual then c.resid = c.resid + k.residual; c.residn = c.residn + 1 end
        local cal = k.kind == "home" and "home" or ((k.rearm and "rearm+" or "") .. (k.caller or "-"))
        callers[cal] = (callers[cal] or 0) + 1
    end
    local span = math.max(1, now_t - (t_first or 0))
    print(string.format("--- keen report --- %d keens in %.0fs of farm (one every %.1fs)", #keens, span, span / math.max(1, #keens)))
    print(string.format("%-7s %-7s %-17s %-6s %-6s %-6s %-12s %-11s %s",
        "t", "kind", "caller/purpose", "resid", "jump", "next", "farmed", "class", "decide[pick mana klvl reason]"))
    for _, k in ipairs(keens) do
        local d = k.dec or {}
        print(string.format("%-7.1f %-7s %-17s %-6s %-6s %-6s %-12s %-11s %s %s klvl=%s %s%s",
            k.t, k.kind == "home" and "home" or ("a=" .. tostring(k.anchor)),
            k.kind == "home" and (k.purpose or "-") or ((k.rearm and "rearm+" or "") .. (k.caller or "-")),
            k.residual and string.format("%d", k.residual) or "-",
            k.jump and string.format("%d", k.jump) or "-",
            k.ndt and string.format("%.0fs", k.ndt) or "-",
            k.farmed or "-", k.class,
            d.pick or "?", d.mana and ("mana=" .. d.mana) or "mana=?", d.klvl or "?", d.reason or "",
            k.cmana and (" castmana=" .. k.cmana) or ""))
    end
    print("\nclass                n   est_mana  avg_resid")
    local tot_mana = 0
    for _, cname in ipairs(order) do
        local c = classes[cname]
        tot_mana = tot_mana + c.mana
        if c.n > 0 then
            print(string.format("%-18s %3d   %6d    %s", cname, c.n, c.mana,
                c.residn > 0 and string.format("%.0f", c.resid / c.residn) or "-"))
        end
    end
    print(string.format("total est keen mana: %d (Keen 75 flat; +225 per rearm_reset rung, level estimate)", tot_mana))
    local cal_parts = {}
    for cal, n in pairs(callers) do cal_parts[#cal_parts + 1] = cal .. "=" .. n end
    table.sort(cal_parts)
    print("callers: " .. table.concat(cal_parts, " "))
    print("classes: bounce = re-keen <" .. BOUNCE_S .. "s with nothing farmed | home-cycle = fountain TP outside a refill/recover pick")
    print("         long-walk = residual >" .. LONGWALK_R .. " (the keen bought a long walk anyway) | short-hop = no farm evidence within " .. PROD_S .. "s")
    print("         home-refill / raid / productive / defend = the designed uses")
    print("         takeover = the user was playing during this keen's outcome window (autofarm OFF..ON) - UNSCOREABLE, never counted as waste")
    os.exit(0)
elseif mode == "time_report" then
    -- GPM study instrument: classify the WHOLE run. A segment = one farm decide's action
    -- (decide -> next decide); the clock interpolates from any kv.t event (farm decides + the
    -- 2s wavescan series), same as cycle_report. Sub-phases from ordered markers:
    --   shove/camp: walk (capped at the planner's travel estimate) / wait (excess stillness
    --   before engage) / tether / engage (arrived -> engage_done) / post (done -> next decide)
    --   refill -> fountain, recover -> recover, none/hold -> idle.
    -- GOLD: farm's gpm field is a cumulative average -> cum_gold = gpm*t/60; the delta between
    -- consecutive decide boundaries is attributed to the earlier segment's pick.
    local now_t = 0
    local segs, cur = {}, nil
    local function close(t)
        if cur then cur.t1 = t; segs[#segs + 1] = cur; cur = nil end
    end
    local last_scan = nil  -- pre-position diagnosis: most-recent wavescan SCAN (grid pred vs kin kpred)
    for _, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        if e.event == "wavescan" and e.kv.pred and not e.kv.ln then
            last_scan = { pred = tonumber(e.kv.pred), kpred = tonumber(e.kv.kpred),
                          lastw = tonumber(e.kv.lastw), t = ts }
        elseif e.event == "farm" then
            close(now_t)
            cur = { t0 = now_t, pick = e.kv.pick or "?", reason = e.kv.reason or "-",
                    travel = tonumber(e.kv.travel) or 0, gpm = tonumber(e.kv.gpm),
                    -- pre-position fog-timing capture (near_due idle diagnosis): the decide's own
                    -- predicted arrival + slack, and the grid/kin estimates in force at decide time
                    dl = tonumber(e.kv.dl), slack = tonumber(e.kv.slack), asrc = e.kv.asrc, scan = last_scan,
                    -- ALL-LANES: a side shove segment keys its time/gold as shove:top|bot
                    key = (e.kv.pick == "shove" and e.kv.lane and e.kv.lane ~= "mid")
                          and ("shove:" .. e.kv.lane) or (e.kv.pick or "?") }
        elseif cur then
            if e.event == "tether" then cur.teth0 = cur.teth0 or now_t
            elseif e.event == "step_out" or e.event == "wave_engage_arrived" or e.event == "engage_arrived" then
                if cur.teth0 then cur.teth = (cur.teth or 0) + (now_t - cur.teth0); cur.teth0 = nil end
                if e.event ~= "step_out" then cur.arr = cur.arr or now_t
                elseif e.kv.eta then  -- keen/anchor step_out (has eta/walk/d), not the "live" close/meet form
                    cur.eta = tonumber(e.kv.eta); cur.walk_s = tonumber(e.kv.walk); cur.dstep = tonumber(e.kv.d)
                end
            elseif e.event == "keen_to_anchor" then cur.residual = tonumber(e.kv.residual)
            elseif e.event == "engage_done" or e.event == "refill_done" then
                cur.done = cur.done and math.max(cur.done, now_t) or now_t
            end
        end
    end
    close(now_t)
    if #segs == 0 then print("  (no `farm` events found)"); os.exit(0) end

    -- USER-TAKEOVER SECONDS ARE NOT BRAIN SECONDS. load_log excises takeover EVENTS but not the
    -- TIME, and the brain does not decide while autofarm is OFF (it returns at the enable gate), so
    -- no `farm` line can close the running segment and the whole OFF..ON window is billed to the
    -- pick that was live when the user grabbed the mouse. Same overlap subtraction --clock-report's
    -- tko_s column and --keen-report already use, so the reports cannot disagree about one game.
    -- Each duration loses the overlap of the interval IT measures, never a segment-wide number
    -- applied to a sub-phase: the window lands inside [arr, done) as readily as in the pre-arrival
    -- stillness. THE GOLD LEDGER STAYS ON THE RAW CLOCK on purpose (see time_by below): gpm is a
    -- CUMULATIVE average, so the delta across a straddling segment cannot say which gold the user
    -- earned, and netting only the denominator manufactures a g/min that never happened.
    -- ponytail: nets regardless of --with-takeover, exactly as --clock-report's tko_s already does
    -- (that flag keeps takeover EVENTS, it does not re-inflate the clock). Gate on
    -- `not opt_with_takeover` if the two ever need to differ.
    local function tko_of(a, b)
        local s = 0
        for _, sp in ipairs(takeover_spans or {}) do
            local lo, hi = math.max(a, sp.t0), math.min(b, sp.t1)
            if hi > lo then s = s + (hi - lo) end
        end
        return s
    end
    local B, order = {}, { "engage", "walk", "wait", "tether", "post", "fountain", "recover", "idle" }
    local function add(k, v) B[k] = (B[k] or 0) + v end
    local gold_by, time_by = {}, {}
    local holds = {}
    for i, s in ipairs(segs) do
        local tko = tko_of(s.t0, s.t1)
        local raw = math.max(0, s.t1 - s.t0)
        local dur = math.max(0, raw - tko)
        local hold_s = 0
        if s.pick == "shove" or s.pick == "camp" or s.pick == "wave" then
            local teth = s.teth or 0
            local a0 = s.arr or s.t1
            local d0 = (s.arr and s.done) and math.max(s.arr, s.done) or nil
            local pre = math.max(0, a0 - s.t0 - tko_of(s.t0, a0))
            local walk = math.min(s.travel, math.max(0, pre - teth))
            local wait = math.max(0, pre - teth - walk)
            local eng = s.arr and math.max(0, (s.done or s.t1) - s.arr - tko_of(s.arr, s.done or s.t1)) or 0
            -- post = engage_done -> next decide, so with NO engage_done there is no post window:
            -- the segment was preempted while still engaging (engage_bail, never engage_done). The
            -- old `s.done or s.arr` fallback made post = t1 - arr, the SAME interval `eng` already
            -- holds one line up, so those seconds landed in TWO buckets at once and are what drove
            -- the residual row below negative.
            local post = d0 and math.max(0, s.t1 - d0 - tko_of(d0, s.t1)) or 0
            add("walk", walk); add("wait", wait); add("tether", teth)
            add("engage", eng); add("post", post)
            hold_s = wait + teth
            s.phases = string.format("walk=%.0f wait=%.0f tether=%.0f engage=%.0f post=%.0f",
                walk, wait, teth, eng, post)
        elseif s.pick == "refill" then add("fountain", dur); hold_s = dur
        elseif s.pick == "recover" then add("recover", dur); hold_s = dur
        elseif s.pick == "none" or s.pick == "hold" then add("idle", dur); hold_s = dur
        -- test BEFORE add: add() creates B[s.pick], so the old post-add test was never true and an
        -- unlisted pick never reached `order` - neither printed nor summed into acc, so its seconds
        -- silently read as "unattributed" (pick=stack is the live case).
        else if not B[s.pick] then order[#order + 1] = s.pick end; add(s.pick, dur)
        end
        local gkey = s.key or s.pick   -- ALL-LANES: shove:top/shove:bot split; time buckets (B) stay pick-shaped
        time_by[gkey] = (time_by[gkey] or 0) + raw   -- RAW on purpose: keeps the gold ledger's `over Xs` on the same wall clock as its cum-gpm numerator
        -- gold delta: this segment's cum vs the next decide's cum
        local nxt = segs[i + 1]
        if s.gpm and nxt and nxt.gpm then
            local d = nxt.gpm * nxt.t0 / 60 - s.gpm * s.t0 / 60
            if d > -50 then gold_by[gkey] = (gold_by[gkey] or 0) + math.max(0, d) end
        end
        if hold_s > 10 then
            holds[#holds + 1] = { t0 = s.t0, pick = s.pick, reason = s.reason, dur = dur,
                hold = hold_s, phases = s.phases, tko = tko,
                eta = s.eta, walk_s = s.walk_s, residual = s.residual,
                dl = s.dl, slack = s.slack, dtravel = s.travel, scan = s.scan }
        end
    end
    local t0, t1 = segs[1].t0, segs[#segs].t1
    local tko_span = tko_of(t0, t1)
    local span = math.max(1, t1 - t0 - tko_span)
    print(string.format("--- time report --- %d segments over %.0fs%s (t %.1f .. %.1f)", #segs, span,
        tko_span > 0.05 and string.format(" of %.0fs raw, %.0fs user-takeover removed", t1 - t0, tko_span) or "",
        t0, t1))
    print("\ntime buckets (every second of the run classified):")
    local acc = 0
    for _, k in ipairs(order) do
        if B[k] then
            print(string.format("    %-10s %6.0fs  (%4.1f%%)", k, B[k], 100 * B[k] / span))
            acc = acc + B[k]
        end
    end
    -- RESIDUAL, not "unattributed time", and NOT comparable to --state-report's UNATTRIBUTED, which
    -- is a share of decide-SILENCE seconds (a different denominator entirely). Segments tile the span
    -- by construction: close() hands each t1 to the next segment's t0, and every branch above splits
    -- that segment's duration, so this row is 0 whenever the arithmetic holds. Kept as the self-check
    -- and deliberately NOT clamped: negative means one second reached two buckets, positive means a
    -- bucket is missing from `order`.
    local resid = span - acc
    if math.abs(resid) < 1e-6 then resid = 0 end   -- IEEE summation noise, not a real gap
    print(string.format("    %-10s %6.1fs  (%4.1f%%)  %s",
        "residual", resid, 100 * resid / span,
        resid == 0 and "(0 by construction: the buckets above tile the span)"
                    or "<<< TOOL BUG: buckets do not tile the span"))

    print("\ngold accounting (cum gpm deltas attributed to the running segment's pick; `over Xs` is RAW wall clock, NOT takeover-netted, so gold and time keep one clock):")
    local picks = {}
    for k in pairs(time_by) do picks[#picks + 1] = k end
    table.sort(picks, function(a, b)   -- name tie-break: equal gold must not print in pairs() order
        local ga, gb = gold_by[a] or 0, gold_by[b] or 0
        return ga > gb or (ga == gb and a < b)
    end)
    local gtot = 0; for _, g in pairs(gold_by) do gtot = gtot + g end
    for _, k in ipairs(picks) do
        local g, tt = gold_by[k] or 0, time_by[k] or 0
        print(string.format("    %-8s %5.0fg (%4.1f%%)  over %5.0fs  = %5.1f g/min",
            k, g, gtot > 0 and 100 * g / gtot or 0, tt, tt > 0 and g / tt * 60 or 0))
    end
    print(string.format("    total attributed: %.0fg over the span (end gpm %s)", gtot,
        tostring(segs[#segs].gpm or "?")))

    print(string.format("\nholds > 10s (stillness that is not engage/walk): %d", #holds))
    table.sort(holds, function(a, b) return a.hold > b.hold end)
    for i = 1, math.min(15, #holds) do
        local h = holds[i]
        print(string.format("    t=%-6.1f %-7s hold=%5.1fs seg=%5.1fs reason=%-14s %s%s",
            h.t0, h.pick, h.hold, h.dur, h.reason, h.phases or "",
            h.tko > 0.05 and string.format(" (%.1fs user-takeover removed)", h.tko) or ""))
        if h.eta then  -- pre-position fog-timing: mechanically pair step_out eta vs decide dl vs wavescan pred/kpred
            local sc = h.scan or {}
            local idle = h.dl and (h.dl - h.eta) or nil
            print(string.format("             fog-timing: eta=%.1f (out+%.1f, keen resid=%s) walk_s=%s | decide[dl=%s slack=%s trav=%s] wavescan[pred=%s kpred=%s] -> idle(dl-eta)=%s",
                h.eta, h.eta - h.t0, tostring(h.residual or "?"), tostring(h.walk_s or "?"),
                tostring(h.dl or "?"), tostring(h.slack or "?"), tostring(h.dtravel or "?"),
                tostring(sc.pred or "?"), tostring(sc.kpred or "?"),
                idle and string.format("%.1f", idle) or "?"))
        end
    end
    os.exit(0)
elseif mode == "convert_report" then
    -- THE CONVERT-CONTEXT INSTRUMENT (churn arc entry, 2026-07-20): per overdue_convert,
    -- reconstruct what every clock believed at the abandon - the committed deadline (the
    -- decide's dl + the frozen kinematic s.waveEta family), the live scanner (SCAN
    -- pred/kpred + the per-lane ln eta), casts already spent - and when the real wave
    -- materialized AFTER the bail (the abandon error). Resolves the over~15-17 mystery
    -- (which quantity `over` measures) and sizes the false-abandon rate for the fix.
    local now_t, ev_t = 0, {}
    for i, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        ev_t[i] = now_t
    end
    local n, errs = 0, {}
    for i, e in ipairs(events) do
        if e.event == "overdue_convert" then
            n = n + 1
            local lane = e.kv.lane or "mid"
            local tc = ev_t[i]
            -- backward: last same-lane shove commit, last SCAN, last ln= scan, casts since commit
            local commit, scan, lscan, casts = nil, nil, nil, 0
            for j = i - 1, 1, -1 do
                local p = events[j]
                if not commit and p.event == "farm" and p.kv.pick == "shove" and (p.kv.lane or "mid") == lane then
                    commit = { t = ev_t[j], dl = tonumber(p.kv.dl), asrc = p.kv.asrc,
                               slack = p.kv.slack, vis = p.kv.vis }
                end
                if not scan and p.event == "wavescan" and p.kv.pred and not p.kv.ln then
                    scan = { pred = tonumber(p.kv.pred), kpred = tonumber(p.kv.kpred) }
                end
                if not lscan and p.event == "wavescan" and p.kv.ln == lane then
                    lscan = { eta = tonumber(p.kv.eta), est = p.kv.est, reach = p.kv.reach }
                end
                if not commit and p.event == "march_aim"
                   and (p.kv.src == "shove" or p.kv.src == "shove_pre" or p.kv.src == "shove_w2") then
                    casts = casts + 1
                end
                if commit and scan and lscan then break end
                if tc - ev_t[j] > 60 then break end
            end
            -- forward: when did the real wave show (arrival event, real ln scan, or vis=y decide)
            local treal = nil
            for j = i + 1, #events do
                local p = events[j]
                if p.event == "wave_engage_arrived" or p.event == "engage_arrived"
                   or (p.event == "wavescan" and p.kv.ln == lane and p.kv.est == "n")
                   or (p.event == "farm" and (p.kv.lane or "mid") == lane and p.kv.vis == "y") then
                    treal = ev_t[j]; break
                end
                if ev_t[j] - tc > 40 then break end
            end
            print(string.format("convert #%d t=%.1f lane=%s over=%s", n, tc, lane, e.kv.over or "?"))
            if commit then
                print(string.format("    commit t=%.1f dl=%s asrc=%s slack=%s vis=%s | conv-commit=%.1f conv-dl=%s casts_since=%d",
                    commit.t, tostring(commit.dl), tostring(commit.asrc), tostring(commit.slack), tostring(commit.vis),
                    tc - commit.t, commit.dl and string.format("%+.1f", tc - commit.dl) or "?", casts))
            end
            if scan or lscan then
                print(string.format("    scanner: SCAN kpred%s pred%s | ln eta=%s est=%s reach=%s",
                    scan and scan.kpred and string.format("=now%+.1f", scan.kpred - tc) or "=?",
                    scan and scan.pred and string.format("=now%+.1f", scan.pred - tc) or "=?",
                    lscan and tostring(lscan.eta) or "?", lscan and tostring(lscan.est) or "?",
                    lscan and tostring(lscan.reach) or "?"))
            end
            if treal then
                errs[#errs + 1] = treal - tc
                print(string.format("    real wave materialized %+.1fs after the abandon", treal - tc))
            else
                print("    no wave materialized within 40s (a TRUE phantom)")
            end
        end
    end
    if n == 0 then print("(no overdue_convert events)") end
    if #errs > 0 then
        table.sort(errs)
        print(string.format("\nconverts: %d | wave materialized after: %d (median %+.1fs) | true phantoms: %d",
            n, #errs, errs[math.ceil(#errs / 2)], n - #errs))
    end
    os.exit(0)
elseif mode == "cast_report" then
    -- THE CAST-OUTCOME INSTRUMENT (step-2 brainstorm 2026-07-20): pair every lane W cast
    -- with what the wave actually did next, so "the pre-casts whiff" is a MEASURED rate,
    -- not an impression (the .322 mirror-misattribution lesson). Classes:
    --   shove_pre live (tarr=)  - the W-GEOM-3 lead cast on a VISIBLE closing wave
    --   shove_pre/w2 fog (teta=) - the stamp-timed fog preempt (fog=y)
    --   shove_w2 (dref=)        - the consecutive W2 (judged by reach, MARCH_REACH 1150)
    --   shove (dWave=)          - the at-arrival cast (baseline, always on the wave)
    -- Outcome scan (+25s or the next farm decide): first arrival event vs the cast's own
    -- lead -> HIT (arr <= lead+2), PARTIAL (<= lead+6, robots still sweeping), LATE, or
    -- GONE (convert/no_wave/nothing = the wave never came). Timestamps interpolate from
    -- the 2s wavescan cadence (+-2s is fine for a 6s robot sweep).
    -- Ends with the wasted-trip recount so the whiff cost sizes against the churn.
    local now_t, ev_t, casts = 0, {}, {}
    for i, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        ev_t[i] = now_t
        if e.event == "march_aim" then
            local src = e.kv.src
            if src == "shove_pre" or src == "shove_w2" or src == "shove" then
                casts[#casts + 1] = { i = i, t = now_t, src = src, fog = (e.kv.fog == "y"),
                    lead = tonumber(e.kv.tarr) or tonumber(e.kv.teta),
                    dw = tonumber(e.kv.dWave) or tonumber(e.kv.dref) }
            end
        end
    end
    for _, c in ipairs(casts) do
        local lead = math.max(c.lead or 0, 0)
        for j = c.i + 1, #events do
            local e, te = events[j], ev_t[j]
            if te > c.t + 25 or (e.event == "farm" and te > c.t + 1) then break end
            if e.event == "wave_engage_arrived" or e.event == "engage_arrived" then
                c.arr = c.arr or te
            elseif e.event == "engage_done" then c.done = te; break
            elseif e.event == "overdue_convert" or (e.event == "shove_move" and (e.raw or ""):find("no_wave", 1, true)) then
                c.gone = te; break
            end
        end
        if c.src == "shove" then c.class = "arrival"
        elseif c.src == "shove_w2" then
            c.class = (not c.fog) and ((c.dw or 0) <= 1150 and "w2_in_reach" or "w2_BEYOND") or "w2_fog"
        elseif c.arr and c.arr <= c.t + lead + 2 then c.class = "HIT"
        elseif c.arr and c.arr <= c.t + lead + 6 then c.class = "PARTIAL"
        elseif c.arr then c.class = "LATE"
        else c.class = "GONE" end
    end
    local function med(t) table.sort(t); return #t > 0 and t[math.ceil(#t / 2)] or 0 end
    print(string.format("--- cast report --- %d lane W casts", #casts))
    local groups = {}
    for _, c in ipairs(casts) do
        local g = (c.src == "shove_pre") and (c.fog and "fog_pre" or "live_pre") or c.src
        groups[g] = groups[g] or {}
        table.insert(groups[g], c)
    end
    for _, gname in ipairs({ "live_pre", "fog_pre", "shove_w2", "shove" }) do
        local list = groups[gname]
        if list then
            local cls, dws, lags = {}, {}, {}
            for _, c in ipairs(list) do
                cls[c.class] = (cls[c.class] or 0) + 1
                if c.dw then dws[#dws + 1] = c.dw end
                if c.arr and c.lead then lags[#lags + 1] = c.arr - (c.t + c.lead) end
            end
            local parts = {}
            for k, v in pairs(cls) do parts[#parts + 1] = string.format("%s=%d", k, v) end
            table.sort(parts)
            print(string.format("  %-9s n=%-3d dW/dref med=%-5.0f arr-lag med=%+.1fs  [%s]",
                gname, #list, med(dws), med(lags), table.concat(parts, " ")))
        end
    end
    -- wasted-trip recount (same rule as farm-report) for the size comparison
    local wasted, wtravel, cur, cast_seen = 0, 0, nil, false
    for _, e in ipairs(events) do
        if e.event == "farm" then
            if cur and not cast_seen and (tonumber(cur.kv.travel) or 0) > 2 then
                wasted = wasted + 1; wtravel = wtravel + (tonumber(cur.kv.travel) or 0)
            end
            cur = (e.kv.pick == "shove") and e or nil
            cast_seen = false
        elseif e.event == "march_aim" and (e.kv.src == "shove" or e.kv.src == "shove_pre" or e.kv.src == "shove_w2") then
            cast_seen = true
        end
    end
    print(string.format("  vs churn: wasted shove trips %d (est travel %.0fs)", wasted, wtravel))
    os.exit(0)
elseif mode == "depth_audit" then
    -- THE WALK-LAW VERIFIER (v0.1.198, after 5+ hours of manual deep-walk hunting): the invariant
    -- is "no lane position past the stairs line (stand_depth > WALK_DEPTH_MAX) without Keen L2".
    -- Reconstructs the klvl timeline from farm decides and checks every positional event against
    -- the line. Team read from self_acquired; fountains from map_data (mirrored). Thresholds:
    --   stands / keen landings / tether holds:  depth > 600  (line 550 + 50 slop)
    --   W casts (cast point <= ~300 ahead of the hero): depth > 910 (550 + 300 + 60)
    -- klvl >= 2 events are reported separately (raid-era; legal by the keen rule).
    -- v0.1.327 S2 PER-LANE DEPTH: the audit consumes THE SAME lib ruler as the brain
    -- (Lane.DepthRuler/Lane.Depth, zero = each lane's T1 midpoint) so auditor-brain drift is
    -- impossible. WALK_MAX re-zeroed 550 -> 1100 with the frame (preserves the .324 Radiant
    -- reference; Dire gains the identical band). Events carry no lane -> nearest-zero pick.
    local LN, MD = require("lib.lane"), require("lib.map_data")
    local WALK_MAX = 1100
    -- v0.1.258: LAST self_acquired wins - debug.log can hold several script loads (run-73:
    -- a team-2 setup session before the team-3 real game); the first one mis-teamed the audit.
    local team = 2
    for _, e in ipairs(events) do
        if e.event == "self_acquired" then team = tonumber(e.kv.team) or team end
    end
    local ruler = LN.DepthRuler(MD.TOWERS, MD.FOUNTAINS, team)
    if not ruler then io.stderr:write("depth-audit: no ruler (map_data)\n"); os.exit(2) end
    local zlist = {}
    for ln, z in pairs(ruler.zero) do zlist[#zlist + 1] = { ln = ln, x = z.x, y = z.y } end
    local function depth(x, y)
        local best, bd
        for _, z in ipairs(zlist) do
            local dd = (x - z.x) * (x - z.x) + (y - z.y) * (y - z.y)
            if not bd or dd < bd then bd, best = dd, z.ln end
        end
        return LN.Depth(ruler, { x = x, y = y }, best)
    end

    local now_t, klvl = 0, 1
    local viol, raid_deep, checked = {}, {}, 0
    local function check(kind, x, y, bar, extra)
        x, y = tonumber(x), tonumber(y)
        if not (x and y) then return end
        checked = checked + 1
        local d = depth(x, y)
        if d > bar then
            local row = { t = now_t, kind = kind, x = x, y = y, d = d, klvl = klvl, extra = extra or "" }
            if klvl >= 2 then raid_deep[#raid_deep + 1] = row else viol[#viol + 1] = row end
        end
    end
    for _, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        if e.event == "farm" then
            klvl = tonumber(e.kv.klvl) or klvl
            if e.kv.pick == "shove" then check("stand", e.kv.sx, e.kv.sy, WALK_MAX + 50) end
        elseif e.event == "keen_to_anchor" then
            local lx, ly = (e.raw or ""):match("land=%((%-?%d+),(%-?%d+)%)")
            check("keen_land", lx, ly, WALK_MAX + 50, "anchor=" .. tostring(e.kv.anchor))
        elseif e.event == "tether" then
            local hx, hy = (e.raw or ""):match("hold=%((%-?%d+),(%-?%d+)%)")
            check("tether_hold", hx, hy, WALK_MAX + 50)
        elseif e.event == "march_aim" and e.kv.src == "shove" then
            local cx2, cy2 = (e.raw or ""):match("cast=%((%-?%d+),(%-?%d+)%)")
            check("w_cast", cx2, cy2, WALK_MAX + 360, "pat=" .. tostring(e.kv.pat))
        elseif e.event == "lane_go" and (e.raw or ""):find("deep_reject") then
            viol[#viol + 1] = { t = now_t, kind = "TRIPWIRE", x = 0, y = 0, d = 0, klvl = klvl,
                                extra = e.raw:match("deep_reject.*") or "" }
        end
    end
    print(string.format("--- depth audit --- team=%d  line=%d  events checked: %d", team, WALK_MAX, checked))
    print(string.format("\nVIOLATIONS (deep without Keen L2): %d %s", #viol,
        #viol == 0 and "- THE INVARIANT HELD" or "<<< BUGS, each row names the producer"))
    for _, v in ipairs(viol) do
        print(string.format("    t=%-7.1f %-11s (%.0f,%.0f) depth=%-5.0f klvl=%d %s",
            v.t, v.kind, v.x, v.y, v.d, v.klvl, v.extra))
    end
    print(string.format("\nraid-era deep events (klvl>=2, legal by the keen rule): %d", #raid_deep))
    for i = 1, math.min(10, #raid_deep) do
        local v = raid_deep[i]
        print(string.format("    t=%-7.1f %-11s (%.0f,%.0f) depth=%-5.0f %s",
            v.t, v.kind, v.x, v.y, v.d, v.extra))
    end
    os.exit(0)
elseif mode == "farm_audit" then
    -- THE CAMP-ECONOMICS VERIFIER (v0.1.199, run-27 refill-churn census). Two machine checks
    -- over the farm trace's own numbers (need = cheapest camp price incl. reserve among camps
    -- that reached the afford stage; pm = planner mana incl. Bottle/item headroom, i.e. exactly
    -- the quantity the afford gate at Tinker.lua:4012 reads; fields ship at v0.1.199 - older
    -- logs degrade to the nnd check only):
    --   1. GATE CONSISTENCY: rej okN>0 <=> pm >= need. A mismatch = the rej mirror or the gate
    --      drifted (the run-27 lesson: a wrong mirror hides the real gate for a whole session).
    --   2. ILLEGAL SINGLE: pick=camp paired=false with nnd <= 1800 (a partner IS in pair range;
    --      v0.1.189 pair-dominance says a single may appear only when partnerless/unsafe).
    -- DELETED, do not re-add: the POINTLESS REFILL check (pick=refill with need > cap). NEITHER
    -- refill site compares mana to need. Tinker.lua:4052 fires on Schedule.CycleFill's fountain
    -- verdict (pool < hop cost + SHOVE_MANA_RESERVE, i.e. cannot fund the next WAVE) or on
    -- HP < REFILL_FRAC; Tinker.lua:4162 fires because Route.Plan put a restore node first. The
    -- check tested a relationship the brain never evaluates. cap is not the post-refill ceiling
    -- either: Tinker.lua:2693 is raw max plus the CURRENT Bottle/item headroom and the trip
    -- refills the Bottle, so the verdict flipped on charges alone (g341 t=62.3 need=770 cap=747
    -- flagged vs t=110.3 need=770 cap=807 clean: same pool, same price, same rej mirror).
    local PAIR_RANGE = 1800
    local mism, illegal = {}, {}
    local n_farm, n_fielded = 0, 0
    for _, e in ipairs(events) do
        if e.event == "farm" then
            n_farm = n_farm + 1
            local t = tonumber(e.kv.t) or 0
            local ok = tonumber((e.kv.rej or ""):match("ok(%d+)"))
            local need, pm = tonumber(e.kv.need), tonumber(e.kv.pm)
            if ok and need and pm then
                n_fielded = n_fielded + 1
                local should = (pm >= need)
                if should ~= (ok > 0) then
                    mism[#mism + 1] = { t = t, rej = e.kv.rej, need = need, pm = pm }
                end
            end
            local nnd = tonumber(e.kv.nnd)
            if e.kv.pick == "camp" and e.kv.paired == "false" and nnd and nnd <= PAIR_RANGE then
                illegal[#illegal + 1] = { t = t, nnd = nnd, cval = e.kv.cval }
            end
        end
    end
    print(string.format("--- farm audit --- decides: %d  with need/pm fields: %d%s",
        n_farm, n_fielded, n_fielded == 0 and "  (pre-v0.1.199 log: gate checks skipped)" or ""))
    print(string.format("\nGATE MISMATCHES (ok>0 <=> pm>=need violated): %d %s", #mism,
        #mism == 0 and "- THE GATE HELD" or "<<< mirror/gate drift, fix before trusting rej"))
    for i = 1, math.min(15, #mism) do
        local v = mism[i]
        print(string.format("    t=%-7.1f rej=%s need=%d pm=%d", v.t, v.rej, v.need, v.pm))
    end
    print(string.format("\nILLEGAL SINGLES (paired=false pick with nnd <= %d): %d %s", PAIR_RANGE,
        #illegal, #illegal == 0 and "- pair dominance held" or "<<< v0.1.189 rule violated"))
    for _, v in ipairs(illegal) do
        print(string.format("    t=%-7.1f nnd=%d cval=%s", v.t, v.nnd, tostring(v.cval)))
    end
    os.exit(0)
elseif mode == "commit_risk" then
    -- THE COMMIT-RISK VERIFIER (TINKER_COMMIT_RISK_DESIGN_V2.md section 6.6). The radius-widening
    -- gate is invisible from every other line in the log, and a silent gate reads EXACTLY like a
    -- dead one - which is how four arcs on this project closed negative. Everything below is a
    -- fact no unit test can establish: which sites actually fired, whether the throttle aliased,
    -- whether the cap quietly became the operating value, and the ne= payload that makes any other
    -- COMMIT_APPROACH_SPEED re-scorable offline from ONE game instead of one game per rung.
    -- BANNER: the banner quotes these very tokens (site=, wcap=, chg=) and has inflated counts in
    -- three separate sessions. parse_line() names it event="Tinker" (its body starts "Tinker brain
    -- v..."), so keying on e.event == "commit_risk" already excludes it; the raw find() is the same
    -- belt fog_report uses at :2114, kept because a future banner wording is not under our control.
    -- TAKEOVER: events inside autofarm OFF..ON are excised upstream (:168-173) so this report reads
    -- the brain only, and A2's gap scan additionally consults takeover_spans - otherwise the hole
    -- the excision leaves behind reads as a dead instrument.
    local HEARTBEAT_S, GAP_BAR = 10.0, 20.0   -- design 6.2 heartbeat window; bar = 2x it (section 10)
    local WCAP_BAR = 0.20                     -- design 6.6 A3
    local FLIP_WINDOW_S = 2.0                 -- design 6.2: the "!" key's throttle, used to fold chg=1 samples into episodes
    local RISK_RADIUS, GANK_RADIUS = 1400, 1000   -- K.RISK_RADIUS (Tinker.lua:128), K.GANK_RADIUS (:129)
    local SPEEDS = { 0, 50, 75, 100, 150 }    -- the tightening ladder (design 4.4) plus one rung past it
    local cr, deaths, farms, shove_lane, camp_scan = {}, {}, {}, {}, 0
    -- DEATH..RESPAWN spans. Tinker.lua:6783 returns ABOVE tick(), so the brain does not decide at
    -- all while dead and commit_risk CANNOT emit for the whole window - the exact opposite of what
    -- design 6.5 F-D predicts ("cadence unchanged through the death and respawn"). Without these
    -- spans A2 counts a death as a gap AND annotates it as the failure-2 signature, i.e. the one
    -- check meant to prove the instrument survived names a HEALTHY build as the failure it exists
    -- to catch, on the first validation game that contains a death. v0.1.356 brackets it exactly.
    local death_spans, log_end = {}, nil
    for _, e in ipairs(events) do
        if e.event == "commit_risk" and not (e.raw or ""):find("Tinker brain v", 1, true) then
            local k = e.kv
            cr[#cr + 1] = {
                t = tonumber(k.t) or 0, site = k.site or "?",
                exp = tonumber(k.exp), st = tonumber(k.st), wd = tonumber(k.wd),
                wcap = tonumber(k.wcap) or 0, ap = k.ap, wmax = k.wmax,
                r0 = tonumber(k.r0), r1 = tonumber(k.r1), g = tonumber(k.g),
                v1 = tonumber(k.v1) or 0, chg = tonumber(k.chg) or 0,
                -- ne= prints math.huge as "inf" and tonumber("inf") is nil in Lua 5.4, so a nil ne
                -- is the EMPTY-SNAPSHOT sentinel (design 5.2 D3), never "enemy at 0u". Keep the raw
                -- string so the chg listing can show what was logged rather than a fabricated 0.
                ne = tonumber(k.ne), ne_raw = k.ne, nh = tonumber(k.nh) or 0,
                -- v0.1.359: which lane_unsafe branch this commit-gated call took (tower/nv2/fog/
                -- trade/widen). nil on EVERY log written before that build, g358 included, which is
                -- the only validated log this arc has - so nothing below may require it.
                br = k.br,
            }
        elseif e.event == "DEATH" then
            deaths[#deaths + 1] = tonumber(e.kv.t) or 0
            death_spans[#death_spans + 1] = { t0 = tonumber(e.kv.t) or 0, t1 = math.huge }
        elseif e.event == "RESPAWN" then
            -- close the open span; an unclosed one (log ends dead) stays math.huge, which is right
            local sp = death_spans[#death_spans]
            if sp and sp.t1 == math.huge then sp.t1 = tonumber(e.kv.t) or math.huge end
        elseif e.event == "camp_scan" then camp_scan = camp_scan + 1
        elseif e.event == "farm" then
            -- act= is the SCHEDULER's action, pick= the FSM's final one. A2 keys on act= because the
            -- two producers hang off the scheduler's shove path (see A2). Both are kept: the gap rows
            -- quote both, and a divergence between them is itself worth seeing. parse_line's
            -- (%S+)=(%S+) walks whole space-separated tokens, so `dpick=mid:0.00` keys `dpick` and
            -- cannot bleed into `pick` the way a raw pick=(%a+) find over the line does.
            -- act= is the SCHEDULER's action, pick= the FSM's final one. act is stored RAW, with NO
            -- `or "?"` default: its PRESENCE is the load-bearing signal (see decide_inside), and a
            -- default would make the field never nil and silently turn that proof into "any decide".
            farms[#farms + 1] = { t = tonumber(e.kv.t) or 0, pick = e.kv.pick or "?", act = e.kv.act }
            if e.kv.pick == "shove" then
                local ln = e.kv.lane or "mid"
                shove_lane[ln] = (shove_lane[ln] or 0) + 1
            end
        end
        local et = tonumber(e.kv.t)
        if et and (not log_end or et > log_end) then log_end = et end
    end
    -- Design 6.4's free discriminator, with no new code in the brain: camp_scan is emitted ABOVE
    -- the enable gate (called at Tinker.lua:6705), so its presence proves logging is on. Without it
    -- "no commit_risk lines" means both "correctly inert" and "dead" and the arc cannot be judged.
    if #cr == 0 then
        print("--- commit-risk report --- NO commit_risk lines in this log")
        print(string.format("    camp_scan lines: %d", camp_scan))
        print(camp_scan > 0
            and "    -> camp_scan is unthrottled by the diag toggle, so LOGGING IS ON: the gate GENUINELY NEVER EXECUTED (dead). Design 6.4."
            or  "    -> no camp_scan either: the diag slider is 0 and logging is OFF. This says NOTHING about the gate. Design 6.4.")
        os.exit(0)
    end
    table.sort(cr, function(a, b) return a.t < b.t end)
    local t0, t1 = cr[1].t, cr[#cr].t
    local mins = math.max(0.01, (t1 - t0) / 60)
    local function tally(t, k) if k ~= nil then t[k] = (t[k] or 0) + 1 end end
    local function show(t)   -- keys arrive as strings (ap, wmax) AND numbers (g), so carry the count along
        local out = {}
        for k, n in pairs(t) do out[#out + 1] = string.format("%s(%d)", tostring(k), n) end
        table.sort(out)
        return table.concat(out, " "), #out
    end
    print(string.format("--- commit-risk report --- %d commit_risk lines over %.0fs (t %.1f .. %.1f)",
        #cr, t1 - t0, t0, t1))
    -- 2026-07-28 NORMALISATION (user, standing rule): raw counts across games of 461s to 1212s are
    -- not comparable and a whole session's conclusions were retracted for exactly that. Rate first.
    print(string.format("    game length %.1f min -- COMPARE RATES, NOT COUNTS, across games", mins))
    -- COUNT chg == 1, never SUM chg. The four early-return branches back-fill chg = -1 (they
    -- compute no verdict, so there is no flip to report), and summing turned 5 real flips plus 15
    -- sentinels into -10, printing a NEGATIVE rate of -0.88/min on g359. A rate that can go
    -- negative is self-evidently wrong, which is the only reason it was caught.
    print(string.format("    rates/min:  commit_risk %.1f   chg=1 %.2f", #cr / mins,
        (function() local n = 0; for _, c in ipairs(cr) do if c.chg == 1 then n = n + 1 end end; return n end)() / mins))
    -- A5: the live constants, echoed. ap=0 is the kill switch saying "I am off" out loud, and two
    -- distinct values in one log is a mid-game reload or a stale C:/Umbrella/scripts/ copy.
    local ap_t, wm_t, g_t = {}, {}, {}
    for _, c in ipairs(cr) do tally(ap_t, c.ap); tally(wm_t, c.wmax); tally(g_t, c.g) end
    local ap_s, ap_n = show(ap_t)
    local wm_s, wm_n = show(wm_t)
    local g_s = show(g_t)
    print(string.format("    A5 CONSTANTS:  ap=%s  wmax=%s  g=%s", ap_s, wm_s, g_s))
    print((ap_n == 1 and wm_n == 1)
        and "        constant all game - compare against Tinker.lua K to catch a stale C:/Umbrella/scripts/ deploy"
        or  "        <<< NOT CONSTANT: two builds in one log or a mid-game reload. Split the log before reading anything below.")
    -- Design 6.4's named signature for the one hero-side mutation the offline suite structurally
    -- cannot reach (section 7.1 item 3): dropping `+ widen` leaves r0 exactly equal to r1 forever.
    -- A line only WITNESSES the term if it has an enemy inside r_eff AND prints a non-zero risk:
    -- past r_eff both reads are legitimately 0, and just inside it both can round to 0.00 at the
    -- logged 2dp (the fixture's ne=2000 wd=650 line does exactly that). The verdict is therefore
    -- "ALL of them read r0==r1", which is the form design 6.4 states and the only false-positive-free
    -- one at this precision; a minority of equal pairs is a rounding artefact, printed not flagged.
    local widened, equal, witness = 0, 0, 0
    for _, c in ipairs(cr) do
        if c.r0 and c.r1 and (c.wd or 0) > 0 and c.ne and c.ne < RISK_RADIUS + c.wd
           and (c.r0 > 0 or c.r1 > 0) then
            witness = witness + 1
            if c.r1 > c.r0 then widened = widened + 1 else equal = equal + 1 end
        end
    end
    print(string.format("    WIDEN TERM LIVE:  %d/%d witnessing lines show r1>r0%s", widened, witness,
        (witness > 0 and widened == 0)
            and "  <<< EVERY witnessing line reads r0==r1: the `+ widen` term was DROPPED (design 6.4 signature)"
        or (witness == 0 and "  (no witnessing line: nothing could show the term either way - ap=0 kill switch, or every commit was clean)"
        or (equal > 0 and string.format("  (%d equal pair(s): a 2dp rounding artefact near r_eff, not the dropped-term signature)", equal) or ""))))

    -- ---- A1: every lane that was actually shoved logged under its OWN site= ----
    -- Failure 1 (v0.1.357): one shared throttle stamp, so hundreds of calls per decide sampled only
    -- whichever site ran first and the log could sit empty while another site actively vetoed.
    -- NOTHING ELSE IN THE LOG REVEALS IT, which is why this is an explicit verdict line.
    -- THE BAR IS COVERAGE, NOT A COUNT. The side producer now passes its lane name, so site= reads
    -- mid/top/bot where it used to read mid/side - and under three producers "2 distinct values"
    -- stops proving anything: mid+top clears that bar while the bot producer aliases into top,
    -- which is failure 1 again with one lane fewer. The farm trace already names every lane that
    -- was actually shoved, so the question this verdict answers is "did each of them log under its
    -- own tag", which is exactly the aliasing question and needs no magic number. Logs predating
    -- the split emit site=side for BOTH side lanes, so there top/bot fold into `side` and the old
    -- reading is preserved verbatim rather than turning every archived log into a false FAIL.
    local site_n, sites = {}, {}
    for _, c in ipairs(cr) do site_n[c.site] = (site_n[c.site] or 0) + 1 end
    for s in pairs(site_n) do sites[#sites + 1] = s end
    table.sort(sites)
    local legacy_side = site_n["side"] ~= nil   -- pre-split log: one tag for both side lanes
    local expect, n_expect, missing = {}, 0, {}
    for ln, n in pairs(shove_lane) do
        local tag = (legacy_side and ln ~= "mid") and "side" or ln
        if not expect[tag] then n_expect = n_expect + 1 end
        expect[tag] = (expect[tag] or 0) + n
    end
    for tag in pairs(expect) do if not site_n[tag] then missing[#missing + 1] = tag end end
    table.sort(missing)
    -- UNPROVEN, not FAIL, when only one lane was ever shoved: nothing could have aliased with
    -- nothing. A missing tag for a lane the farm trace SHOWS being shoved is the real failure.
    local a1 = (#missing > 0) and "FAIL" or ((#sites >= 2) and "PASS" or "UNPROVEN")
    print("")
    print(string.format("A1 EVERY SHOVED LANE LOGGED ITS OWN site=: %s  (%d distinct site= value(s) covering %d shoved lane(s)%s)",
        a1, #sites, n_expect, legacy_side and ", pre-split `side` tag folds top+bot" or ""))
    for _, s in ipairs(sites) do
        print(string.format("    %-6s %4d  (%4.1f%%)  %.1f/min", s, site_n[s], 100 * site_n[s] / #cr, site_n[s] / mins))
    end
    if a1 ~= "PASS" then
        -- The two causes of a thin site= set are opposite verdicts, so name which one this log
        -- shows: an aliased throttle is a bug, a game that never shoved a second lane is an unrun test.
        local parts = {}
        for ln, n in pairs(shove_lane) do parts[#parts + 1] = string.format("%s=%d", ln, n) end
        table.sort(parts)
        print(string.format("    cross-check, farm trace shove lanes: %s",
            #parts > 0 and table.concat(parts, " ") or "(no farm events in this log)"))
        print(#missing > 0
            and string.format("    <<< SHOVED yet never logged a site= of its own: %s - v0.1.357 failure 1 recurred (one stamp aliasing to whichever site runs first)",
                    table.concat(missing, " "))
            or  "    -> only one lane was ever shoved, so one site= is EXPECTED here. A1 is UNPROVEN, not failed: replay long enough to shove a second lane (design 6.5 F-C).")
    end

    -- ---- BRANCH CENSUS: which lane_unsafe branch the commit-gated call took (v0.1.359 br=) ----
    -- New information, not a verdict, and printed ABOVE A2 because A2's verdict word depends on
    -- whether br= exists at all. NOTHING has ever measured how often a shove commit is refused by an
    -- INSTANT visible-count branch versus reaching the widened fall-through the whole gate exists to
    -- tune: the four early returns leave lane_unsafe ABOVE the instrument (Tinker.lua:1056 tower,
    -- :1077 nv>=2, :1080 fog 2-man, :1089 nv==1 trade), so before br= every one of them was
    -- indistinguishable from silence, and the calibration ladder in A4 was being read as if `widen`
    -- were the only branch. Rates as well as counts, per the 2026-07-28 normalisation rule above.
    local BR_WHAT = {
        tower = "  enemy tower (Tinker.lua:1056; fires BEFORE any enemy counting, so it is silent even at enH=0)",
        nv2   = "  2 visible inside GANK_RADIUS = committed gank (:1077)",
        fog   = "  1 visible + a reachable fresh fog blip, bail-gated (:1080)",
        trade = "  pure 1v1 trade, HP-gated (:1089)",
        widen = "  reached the widened read: the ONLY branch the `+ widen` term can act on (:1114)",
    }
    local br_n, brs, br_any = {}, {}, 0
    for _, c in ipairs(cr) do
        if c.br then br_n[c.br] = (br_n[c.br] or 0) + 1; br_any = br_any + 1 end
    end
    for b in pairs(br_n) do brs[#brs + 1] = b end
    table.sort(brs)
    print("")
    print(string.format("BRANCH CENSUS -- which lane_unsafe branch the commit-gated call took: %d/%d line(s) carry br=", br_any, #cr))
    if br_any == 0 then
        print("    (no br= anywhere: a pre-v0.1.359 log. The four early returns are SILENT on that build, so the census")
        print("     cannot be taken from it and A2 below degrades to REVIEW - see its note. This is expected, not a fault.)")
    else
        for _, b in ipairs(brs) do
            print(string.format("    %-6s %4d  (%4.1f%%)  %5.2f/min%s", b, br_n[b], 100 * br_n[b] / br_any,
                br_n[b] / mins, BR_WHAT[b] or "  (unknown branch tag: newer brain than this analyzer)"))
        end
        local widen_n = br_n.widen or 0
        print(string.format("    -> %d/%d = %.1f%% of commit-gated calls never reached the widened read (refused by an instant branch first);",
            br_any - widen_n, br_any, 100 * (br_any - widen_n) / br_any))
        print(string.format("       the other %.1f%% are the population A3/A4/A6 and the offline re-score actually describe.",
            100 * widen_n / br_any))
        if br_any < #cr then
            print(string.format("    <<< %d line(s) carry NO br=: two builds in one log or a mid-game reload. Split it, same read as A5.",
                #cr - br_any))
        end
    end

    -- ---- A2: did the instrument DIE, i.e. is there silence the log cannot explain ----
    -- A RAW gap bar cannot answer that, and shipping one would have burned the acceptance bar on
    -- the first validation game. Two measured reasons, both hero-side control flow the design did
    -- not check:
    --   1. commit_risk emits ONLY from lane_unsafe's nv==0 fall-through, reached only from the two
    --      shove producers, which live in fsm_decide. Tinker.lua:6781/6783 return above tick() when
    --      the toggle is off or the hero is dead, and fsm_decide runs only in State.fsm=="DECIDE"
    --      (:6114), so nothing emits during a camp clear, a walk, a fountain trip or a death. The
    --      10s window is a RATE CAP, not a heartbeat. Measured on the real g356 log, the gaps
    --      between consecutive per-decide `farm` traces (a strict LOWER bound on commit_risk gaps,
    --      since its timestamps are a subset of those decides) run med 0.5 / p90 15.5 / max 54.6s,
    --      with 13 of 253 past this 20s bar. A correct build cannot meet a raw bar.
    --   2. A gap scan reads only the space BETWEEN surviving lines, so an instrument that dies at
    --      t=600 in a 1250s game shrinks the report's own window to t=600 and looks HEALTHY. That
    --      is v0.1.357 failure 2 exactly, and the raw bar could not see it at all.
    -- So: a gap is UNEXPLAINED only when a decide that PROVABLY REACHED THE PRODUCER ran inside it
    -- more than one heartbeat after it started and still nothing was logged. That proof is the mere
    -- PRESENCE of act=, and the reasoning is in decide_inside below.
    --   A NARROWER `act == "shove"` RULE WAS TRIED AND REVERTED: it is factually wrong (52% of
    -- g358's commit_risk lines were emitted on a non-shove decide) and it made A2 print PASS over a
    -- provably dead 102.3s window. Do not reintroduce it. (Read act= off the parsed kv table, never
    -- with a find over the raw line: a naive pick=(%a+) also matches inside `dpick=mid` and silently
    -- misclassifies most decides, which happened once already in this arc.)
    --   RESIDUAL, and it is why the verdict word is three-state below. lane_unsafe ALSO returns early
    -- at the tower gate (:1056, ABOVE any enemy counting, so it is silent even at enH=0), at nv>=2
    -- (:1077), at the fog 2-man (:1080) and at the nv==1 trade (:1089). On a pre-v0.1.359 log a
    -- commit-gated call can therefore legitimately log nothing, and enH= is an INCOMPLETE proxy for
    -- which of those happened - g358's one surviving row at t=776.3 is exactly that shape (act=shove,
    -- enH=2, and act= present). No analyzer-only refinement can close that: the hero has to name the branch it took,
    -- which is what br= does, so with br= live "a producer-reaching decide ran and NOTHING of any kind was
    -- logged" leaves no legal control-flow path and is a real death. Without it the row stays a
    -- "go read it". The TAIL gets its own verdict below, because it has no closing commit_risk line
    -- to pair with and so cannot be a gap at all.
    -- MEASURED exclusion, not whole-gap discard. A boolean "does this window touch an excluded
    -- span" test throws the ENTIRE window away the moment it clips one, and the longer the window
    -- the likelier it clips: on fixture_gate_dies_at_600.log a 660s hole straddling two
    -- DEATH..RESPAWN windows worth 95s combined was discarded whole, so the dead-gate fixture
    -- printed a verdict identical to the healthy one. Subtracting the covered seconds keeps the
    -- other 565s visible, which is the entire point of the check. The spans are disjoint by
    -- construction (a DEATH cannot open while one is unclosed, likewise autofarm OFF), so summing
    -- the clipped overlaps is exact rather than an approximation.
    local function dead_s(a, b)
        local s = 0
        for _, list in ipairs({ takeover_spans, death_spans }) do
            for _, sp in ipairs(list) do
                local lo, hi = math.max(a, sp.t0), math.min(b, sp.t1)
                if hi > lo then s = s + (hi - lo) end
            end
        end
        return s
    end
    -- STRICT inequalities, unlike keen_report's takeover_overlap at :1075. A span's t0 is the last
    -- stamped event BEFORE the OFF, so an inclusive test also swallows the healthy decide that
    -- merely LANDS where the takeover begins.
    local function in_span(t)
        for _, list in ipairs({ takeover_spans, death_spans }) do
            for _, sp in ipairs(list) do
                if t > sp.t0 and t < sp.t1 then return true end
            end
        end
        return false
    end
    -- A decide in the STRICT interior, past one heartbeat from the start and not itself inside an
    -- excluded span: by then the throttle had reopened and the brain was provably deciding, so had
    -- the gate run it would have logged and ended the silence. Scanning `fe.t <= gp.t2` instead
    -- picks the decide that BROKE the silence - by construction the one that ended the gap - and
    -- then annotates the row with the reason the NEXT window was quiet, contradicting the row it
    -- describes. Shared with the tail check so both windows are judged by one rule.
    -- `shove_only` is OPT-IN and only A2's gap scan passes it. The tail check is deliberately left on
    -- the broad "any decide" rule: it is the half that catches a gate which actually died and never
    -- came back, narrowing it would make a dead gate HARDER to catch (a build that latches off can
    -- also stop shoving, and then a shove-only tail sees nothing at all), and it passed honestly on
    -- g358 with the broad rule. A false positive there costs one read of the tail; a false negative
    -- costs the whole failure-2 check. Different job, different rule, stated so it does not read as
    -- an oversight.
    -- THE PREDICATE IS "act= IS PRESENT", NOT "act == shove". An earlier round narrowed this to
    -- shove and it was a STRAIGHT REGRESSION that made A2 print PASS over a provably dead gate:
    -- measured on g358, 47 of 91 commit_risk lines (52%) were emitted on a decide whose act is NOT
    -- shove, so the narrow filter explains away real silence. Per site: mid 28 of 45 non-shove,
    -- bot 19 of 46. Root cause, both producers:
    --   MID  schedule_ctx (Tinker.lua:3015) is called UNCONDITIONALLY at :3711 and Schedule.Plan
    --        does not run until :3712, so at the moment the mid producer fires at :3266 d.action
    --        DOES NOT EXIST YET. It cannot be gated on the result either: :3749 rewrites
    --        d.action to "recover"/"shove_stuck" AFTER the producer already logged, which is
    --        exactly the 24 act=recover lines.
    --   SIDE eval_side_lanes is called from :3800 AND :3873, and :3873 sits in the else of
    --        `if d and d.action == "recover"`, i.e. the jungle / vetoed-shove branch = 19 lines.
    -- Why act-PRESENCE is nonetheless EXACT rather than merely broad: ft.act is written only
    -- `if d` (:3768); d needs sc; sc non-nil needs schedule_ctx to have passed `if not s` (:3017)
    -- and `if not crash_pos` (:3057) and reached its `return {` (:3287), which is AFTER the
    -- commit-gated call at :3266. So "this decide carries an act= field" PROVES the mid producer
    -- ran with commit set. That is the discriminator; br= is what explains the outcome.
    -- Residual, stated because it is real: the State.cyclePark short-circuit (:3720-3733) returns
    -- without emit_farm, so a producer call can occur with no farm line at all. Pre-existing, and
    -- it makes "no decide inside" a lower bound in either direction.
    local function decide_inside(a, b)
        for _, fe in ipairs(farms) do
            if fe.t > a + HEARTBEAT_S and fe.t < b and not in_span(fe.t)
               and fe.act ~= nil then return fe end
        end
        return nil
    end
    local gaps, worst, skipped, excl_s = {}, nil, 0, 0
    for i = 2, #cr do
        local a, b = cr[i - 1].t, cr[i].t
        local dead = dead_s(a, b)
        local d = (b - a) - dead
        excl_s = excl_s + dead
        if d <= 0 then
            if b > a then skipped = skipped + 1 end   -- real elapsed time, all of it dead or taken over
        else
            if not worst or d > worst.d then worst = { d = d, t = a, t2 = b } end
            if d > GAP_BAR then
                gaps[#gaps + 1] = { d = d, t = a, t2 = b, dead = dead, inside = decide_inside(a, b) }
            end
        end
    end
    local unexplained = 0
    for _, gp in ipairs(gaps) do if gp.inside then unexplained = unexplained + 1 end end
    -- THREE-STATE, and the middle state is the point. The comment above has always said an
    -- unexplained gap is "a go read it, not a proof of death", and then the code printed FAIL for
    -- one - which on a pre-br log is a verdict the check cannot support, and printing an unsupported
    -- FAIL on a healthy build is precisely how a reader learns to skim past A2 and miss the real one.
    -- FAIL is now reserved for the case that actually proves the instrument stopped: br= live (so
    -- every branch of lane_unsafe emits) AND a shove decide inside the silence AND nothing logged.
    -- Anything short of that evidence is REVIEW, which is a row to read, not a build to reject.
    local a2 = (unexplained == 0) and "PASS" or ((br_any > 0) and "FAIL" or "REVIEW")
    print("")
    print(string.format("A2 THE INSTRUMENT SURVIVED: %s  (%d unexplained gap(s); largest LIVE gap %.1fs at t=%.1f, bar %.1fs = 2x the %.1fs rate cap)",
        a2, unexplained, worst and worst.d or 0, worst and worst.t or 0, GAP_BAR, HEARTBEAT_S))
    if a2 == "REVIEW" then
        print("    -> REVIEW, not FAIL: this log carries no br=, so an early return (tower gate / nv>=2 / fog 2-man / nv==1 trade)")
        print("       is indistinguishable from a dead gate in it. Read the row(s) below by hand; re-run on a v0.1.359+ log to get a verdict.")
    elseif a2 == "FAIL" then
        print("    <<< FAIL, and it is load-bearing: br= is live, so EVERY branch of lane_unsafe emits. A shove decide inside the")
        print("    <<< silence with nothing at all logged leaves no legal control-flow path. Find what latched the gate off.")
    end
    -- EVERY unexplained gap prints; only the explained ones are capped, and the cap says how many
    -- it swallowed. A blanket top-15 can hide the one actionable row behind fifteen legitimate
    -- jungle legs and leave a FAIL verdict with nothing on screen to justify it, which is the same
    -- "the report silently shrinks its own evidence" shape as failure 2 itself.
    local shown, omitted = 0, 0
    for _, gp in ipairs(gaps) do
        if gp.inside or shown < 15 then
            shown = shown + 1
            -- Failure 2's signature is silence that starts at a death and does not end. v1 has no
            -- OnDraw state at all, so a DEATH inside an UNEXPLAINED gap means the "no OnDraw
            -- reachability" claim (design 7.1 item 5) has been invalidated by an edit. A death alone
            -- explains nothing now: its seconds are subtracted above, because the brain provably
            -- does not decide while dead.
            local dth
            for _, td in ipairs(deaths) do if td >= gp.t - 2.0 and td <= gp.t2 then dth = td end end
            print(string.format("    t=%-7.1f .. %-7.1f  %5.1fs live%s  %s", gp.t, gp.t2, gp.d,
                gp.dead > 0.05 and string.format(" (%.0fs dead/takeover removed)", gp.dead) or "",
                gp.inside
                  and string.format("<<< UNEXPLAINED: a SHOVE decide ran at t=%.1f (act=shove pick=%s), %.1fs into the silence, and the gate logged nothing%s%s",
                        gp.inside.t, gp.inside.pick, gp.inside.t - gp.t,
                        br_any > 0 and "" or " (no br= on this build: an early return would look identical)",
                        dth and string.format(" - AND a DEATH at t=%.1f sits inside it: the failure-2 shape, named", dth) or "")
                  or "(no decide carrying act= inside it: schedule_ctx returned early, so the mid producer never ran - legitimate silence)"))
        else
            omitted = omitted + 1
        end
    end
    if omitted > 0 then
        print(string.format("    (+%d more EXPLAINED gap(s) over the bar, not listed; every unexplained one is above)", omitted))
    end
    if excl_s > 0.05 then
        print(string.format("    (%.0fs of autofarm OFF..ON takeover and DEATH..RESPAWN time subtracted across all gaps%s: the brain was off or dead, not broken)",
            excl_s, skipped > 0 and string.format(", %d gap(s) lying ENTIRELY inside one", skipped) or ""))
    end
    if #death_spans == 0 and #deaths == 0 then
        print("    (no DEATH lines in this log: on a pre-v0.1.356 build the death windows cannot be excluded and will read as unexplained gaps)")
    end

    -- ---- A2-TAIL: was the instrument still alive when the log ENDED ----
    -- The check A2 structurally cannot make. A gap scan reads only the space BETWEEN surviving
    -- lines, so an instrument that dies at t=600 in a 1250s game silently SHRINKS the report's own
    -- window to t=600 - and every number above then describes the healthy first half while the
    -- banner truthfully reports "72 lines over 549s". That is v0.1.357 failure 2 exactly ("the
    -- latch killed the log for the session"), and it is invisible to the pair scan by construction:
    -- the hole has no closing commit_risk line to pair with. Measured on fixture_gate_dies_at_600
    -- .log, which printed a verdict indistinguishable from the healthy fixture's until this block
    -- existed. Dead and takeover seconds come off exactly as they do for a gap, so a log that ends
    -- while the hero is dead or the user is playing does not read as a dead gate.
    local cr_last = cr[#cr].t
    local t_end = log_end or cr_last
    local tail_raw = math.max(0, t_end - cr_last)
    local tail_dead = dead_s(cr_last, t_end)
    local tail_live = tail_raw - tail_dead
    local tail_dec = decide_inside(cr_last, t_end)
    local tail_ok = not (tail_live > GAP_BAR and tail_dec)
    print("")
    print(string.format("A2-TAIL THE INSTRUMENT WAS STILL ALIVE AT THE END: %s  (last commit_risk t=%.1f, last stamped event t=%.1f, tail %.1fs live%s, bar %.1fs)",
        tail_ok and "PASS" or "FAIL", cr_last, t_end, tail_live,
        tail_dead > 0.05 and string.format(" of %.1fs raw, %.0fs dead/takeover removed", tail_raw, tail_dead) or "",
        GAP_BAR))
    if not tail_ok then
        print(string.format("    <<< THE GATE DIED AT t=%.1f AND NEVER CAME BACK: %.0fs of live game ran with the instrument silent,",
            cr_last, tail_live))
        print(string.format("    <<< and a decide ran at t=%.1f (pick=%s), %.1fs into that hole, so the brain WAS deciding and the gate logged nothing.",
            tail_dec.t, tail_dec.pick, tail_dec.t - cr_last))
        print(string.format("    <<< Every check above describes only t=%.1f..%.1f, because the report's window shrank with the log. Read none of them",
            t0, t1))
        print("    <<< as a verdict on the whole game. This is v0.1.357 failure 2 (design 6.4): find what latched the gate off.")
    elseif tail_live > GAP_BAR then
        print(string.format("    (%.0fs of tail with no decide in it: the brain was not in DECIDE after the last commit, so the gate could not run - legitimate silence)",
            tail_live))
    end

    -- ---- A3: the cap is not the operating value ----
    -- Findings section 3, which bit this arc TWICE: WIDEN_MAX silently becomes the operating value
    -- if it sits inside the normal range, and the travel term then stops mattering entirely.
    local ncap = 0
    for _, c in ipairs(cr) do if c.wcap == 1 then ncap = ncap + 1 end end
    local cfrac = ncap / #cr
    print("")
    print(string.format("A3 THE CAP IS NOT THE OPERATING VALUE: %s  (wcap=1 on %d/%d = %.1f%%, bar %.0f%%)",
        cfrac <= WCAP_BAR and "PASS" or "FAIL", ncap, #cr, cfrac * 100, WCAP_BAR * 100))
    if cfrac > WCAP_BAR then
        print("    <<< WIDEN_MAX is the operating value: the travel term has stopped mattering and every long commit gets an IDENTICAL widen.")
        print("    <<< Raise COMMIT_WIDEN_MAX *with* the speed (invariant: >= COMMIT_APPROACH_SPEED * 35), never the speed alone.")
    end

    -- ---- A4: the payload ----
    -- ONLY br=widen LINES CARRY REAL MEASUREMENTS. The four early-return branches never compute
    -- r0/r1/ne/nh (running them for a log would put new work on the gate path, the exact class of
    -- edit that made v0.1.357 unshippable), so the hero back-fills -1 as a sentinel. Those -1s are
    -- NOT data and must never reach a quantile: unfiltered they moved g358's ne median from 1642
    -- to 1161 and drove min/p10/p25 to -1, i.e. they corrupt THE PAYLOAD, the one number this
    -- whole build exists to produce. A pre-v0.1.359 log has no br= at all and every line is a
    -- widen line, so `c.br == nil` must count as measurable for backward compatibility.
    local nes, exps, wds, no_enemy, r0n, r1n, nh0, meas = {}, {}, {}, 0, 0, 0, 0, 0
    for _, c in ipairs(cr) do
        -- exp/wd ARE valid on every branch (both derive from opts.commit/travel, which the caller
        -- computed before lane_unsafe was entered), so they aggregate over all lines.
        if c.exp then exps[#exps + 1] = c.exp end
        if c.wd then wds[#wds + 1] = c.wd end
        if c.br == nil or c.br == "widen" then
            meas = meas + 1
            if c.ne then nes[#nes + 1] = c.ne else no_enemy = no_enemy + 1 end
            if (c.r0 or 0) > 0 then r0n = r0n + 1 end
            if (c.r1 or 0) > 0 then r1n = r1n + 1 end
            if c.nh == 0 then nh0 = nh0 + 1 end
        end
    end
    table.sort(nes); table.sort(exps); table.sort(wds)
    local function qt(s, p) return #s > 0 and s[math.max(1, math.ceil(p * #s))] or 0 end
    print("")
    print(string.format("A4 THE PAYLOAD -- nearest-enemy edge at every commit: %d line(s) with a distance, %d with ne=inf (EMPTY snapshot, no enemy hero at all)",
        #nes, no_enemy))
    if #nes > 0 then
        print(string.format("    ne=  min %.0f  p10 %.0f  p25 %.0f  med %.0f  p75 %.0f  p90 %.0f  max %.0f",
            nes[1], qt(nes, 0.10), qt(nes, 0.25), qt(nes, 0.50), qt(nes, 0.75), qt(nes, 0.90), nes[#nes]))
        local inband = 0
        for _, d in ipairs(nes) do if d >= RISK_RADIUS then inband = inband + 1 end end
        print(string.format("    %d of %d (%.0f%%) sit BEYOND K.RISK_RADIUS %d, i.e. censored to risk 0.00 by today's model - this field is what uncensors them",
            inband, #nes, 100 * inband / #nes, RISK_RADIUS))
    end
    print(string.format("    exp= min %.1f  med %.1f  max %.1f s      wd= min %.0f  med %.0f  max %.0f u",
        #exps > 0 and exps[1] or 0, qt(exps, 0.50), #exps > 0 and exps[#exps] or 0,
        #wds > 0 and wds[1] or 0, qt(wds, 0.50), #wds > 0 and wds[#wds] or 0))
    print(string.format("    r0 > 0 on %d/%d lines;  r1 > 0 on %d/%d;  nh=0 (empty snapshot, gate trivially inert) on %d",
        r0n, #cr, r1n, #cr, nh0))
    -- OFFLINE RE-SCORE. FogProximityRisk returns the MAX over heroes of weight*(1-edge/r_eff)^2 and
    -- ne is the NEAREST hero's edge, so w = r/(1-ne/r_eff)^2 is that maximum expressed at the nearest
    -- edge. When the argmax hero IS the nearest one (the ordinary case) it is the real weight_fn
    -- value; when it is not, the recovered w reads HIGH, so every veto count below is an UPPER bound.
    -- That is the honest direction for a "would this collapse farming" question.
    -- CEILING: one enemy per line. A commit refused by the second-nearest hero alone is not modelled;
    -- fixing that needs a per-hero ne list in the logline, which is a bigger line for a rarer case.
    local function recover_w(c)
        if c.ne and (c.r0 or 0) > 0 and c.ne < RISK_RADIUS then
            local r = 1 - c.ne / RISK_RADIUS
            return c.r0 / (r * r)
        end
        if c.ne and (c.r1 or 0) > 0 and c.ne < RISK_RADIUS + (c.wd or 0) then
            local reff = RISK_RADIUS + (c.wd or 0)
            local r = 1 - c.ne / reff
            return c.r1 / (r * r)
        end
        return nil
    end
    local scorable, defaulted, v1n = 0, 0, 0
    for _, c in ipairs(cr) do
        if c.ne and c.exp and c.g then
            scorable = scorable + 1
            if not recover_w(c) then defaulted = defaulted + 1 end
        end
        v1n = v1n + c.v1
    end
    print("")
    print(string.format("    OFFLINE RE-SCORE -- what another COMMIT_APPROACH_SPEED would have vetoed, from THIS game (%d scorable line(s))", scorable))
    print(string.format("    (w recovered from (r0,ne) or (r1,ne); w=1.00 assumed on %d line(s) where both read 0. cap = speed*40, which honours the WIDEN_MAX >= speed*35 invariant.)", defaulted))
    print("      speed    vetoed   of scorable   cap bound")
    for _, sp in ipairs(SPEEDS) do
        local vet, bound = 0, 0
        for _, c in ipairs(cr) do
            if c.ne and c.exp and c.g then
                local cap = sp * 40
                local wd = math.min(cap, sp * c.exp)
                if sp > 0 and wd >= cap then bound = bound + 1 end
                local reff = RISK_RADIUS + wd
                local w = recover_w(c) or 1.0
                local risk = 0
                if c.ne < reff then local r = 1 - c.ne / reff; risk = w * r * r end
                if risk >= c.g then vet = vet + 1 end
            end
        end
        print(string.format("      %5d    %6d      %5.1f%%      %6d", sp, vet,
            scorable > 0 and 100 * vet / scorable or 0, bound))
    end
    print(string.format("    logged verdicts for comparison: v1=1 on %d/%d line(s). A large divergence from the shipped speed's row means", v1n, #cr))
    print("    the single-nearest-enemy model above is not capturing the argmax hero, and the re-score should be read as a bound only.")

    -- ---- A6 + the chg=1 roll call ----
    local chg, inversions = {}, 0
    for _, c in ipairs(cr) do
        if c.chg == 1 then
            chg[#chg + 1] = c
            if c.ne and c.ne > GANK_RADIUS then inversions = inversions + 1 end
        end
    end
    print("")
    print(string.format("A6 GANK_RADIUS RULER INVERSION (chg=1 with ne > %d): %d %s", GANK_RADIUS, inversions,
        inversions == 0 and "- no inversion" or "<<< refused a stand at ne>1000 while the nv==1 branch accepts the same enemy at 999u (design 4.4 / CO-6)"))
    if inversions > 0 then
        -- Design 4.4 reads as if the inversion arrives at SPEED 100. That is about the MEDIAN
        -- widen; the boundary is widen 831 (w=1.15) / 1049 (w=1.0), which at the shipped 50 is
        -- travel 12.6s / 17.0s, inside the observed g356 distribution. A few inversions on a ship
        -- build are EXPECTED. The 1001u side errs safe and the 999u side is pre-existing shipped
        -- behaviour, so the cost is farming, not life: read this as an inconsistency to price, not
        -- as evidence the calibration is wrong.
        print("    (expected at ap=50 on long-travel commits: the boundary is widen 831 at w=1.15, i.e. travel 12.6s, not a SPEED-100-only effect)")
    end
    -- chg=1 counts THROTTLED SAMPLES, not decisions, and the difference is the whole acceptance
    -- bar. The flip key is site.."!" on a 2.0s window while fsm_decide re-evaluates every
    -- DECIDE_GAP 0.4s, so ONE flip condition that PERSISTS (an enemy parked near a stand while the
    -- producer keeps re-proposing the same lane) emits a line every 2.0s for as long as it lasts:
    -- 10s of persistence is 5 lines, 60s is 30, against a bar of "0 to about 4 over a full game".
    -- One sustained flip therefore blows the bar with no second distinct decision anywhere in the
    -- game. Fold consecutive same-site samples no more than one throttle window apart into ONE
    -- episode and judge the bar on episodes. The key is the site tag, which is what the hero
    -- throttles on, so this follows the mid/top/bot split automatically. Both numbers print: the
    -- raw sample count is still the honest volume the instrument produced.
    local episodes, last_by_site = 0, {}
    for _, c in ipairs(chg) do
        local prev = last_by_site[c.site]
        if not prev or (c.t - prev) > FLIP_WINDOW_S * 1.5 then episodes = episodes + 1 end
        last_by_site[c.site] = c.t
    end
    print("")
    print(string.format("chg=1 COMMITS -- %d EPISODE(S) (%.2f/min), from %d throttled SAMPLE(S): every decision the widening actually changed",
        episodes, episodes / mins, #chg))
    print(string.format("    (episodes, not lines, are what design section 10's bar counts: the \"!\" key re-emits every %.1fs while a flip PERSISTS,", FLIP_WINDOW_S))
    print("     so one enemy parked between the two veto radii can print dozens of samples of a single decision)")
    print("    THE ACCEPTANCE BAR IS HUMAN: read each row with its ne= and travel= and agree the destination was worth refusing.")
    print("    (design section 10: 0 to about 4 EPISODES over a full game; more than that means the calibration is off for this scope, not that the feature works)")
    for _, c in ipairs(chg) do
        print(string.format("    t=%-7.1f site=%-5s ne=%-6s travel=%-5s exp=%-5s wd=%-5s r0=%.2f -> r1=%.2f  g=%.2f  v1=%d  nh=%d%s",
            c.t, c.site, c.ne_raw or "-",
            (c.exp and c.st) and string.format("%.1f", c.exp - c.st) or "-",   -- design 6.3: exp - st recovers travel
            c.exp and string.format("%.1f", c.exp) or "-",
            c.wd and string.format("%.0f", c.wd) or "-",
            c.r0 or 0, c.r1 or 0, c.g or 0, c.v1, c.nh,
            (c.ne and c.ne > GANK_RADIUS) and "  <<< A6 inversion" or ""))
    end
    if #chg == 0 then
        print("    (none: live and correctly inert is the EXPECTED first-game outcome at ap=50 - design 6.4, section 10)")
    end
    os.exit(0)
elseif mode == "clock_report" then
    -- THE LANE-CLOCK LEDGER (TINKER_LANE_CLOCK_DESIGN.md): the arc's headline acceptance metric,
    -- which had no analyzer - and measuring it by hand is exactly what produced the retired
    -- "a thin verdict costs one full wave cycle (54.4/59.6s)" figure.
    -- WHAT IT MEASURES, AND WHY NOT THE OBVIOUS THING. `act=` / `reason=` / per-wave coverage are
    -- DECIDE-SAMPLED: fsm_decide runs under 10% of game time, and the coverage number correlates
    -- only r=0.45 with unconditional served-wave measures. So nothing below reads a decide. The
    -- only fact used is the COMPLETED engage: `engage_done ... lane=mid`, which is the wave
    -- actually served, and the user's defect is stated in exactly those terms ("losing mid waves").
    -- STAMPING. engage_done carries NO timestamp, so it inherits the last kv.t seen (the :994-996
    -- running-clock idiom). kv.t comes from parse_line's whole-token split, so it can only ever be
    -- a real `| t=` field; a bare `t=` regex over the raw line matches inside `est=7.0` and stamps
    -- garbage, which is the trap the controller hit. That clock ticks every ~2s (the wavescan
    -- series), where a decide-only clock ticks every ~5-15s: the hand-built timeline this arc has
    -- been quoting is 5-23s STALE per clear, so the holes print a few seconds SHORTER here (g358
    -- 202.7 not 207, g359 106.3 not 122). Same holes, tighter ruler - and the g359 error was not
    -- even constant (23s on one clear, 7s on the next), which is precisely why a hand-stamped gap
    -- cannot be trusted to a second.
    -- PHASE. Keen L2 (`| klvl=` >= 2) ends lane phase. The user's model is phase-dependent: lane
    -- phase must run like a clock, raid-era decline is CORRECT, so a raid-era gap is NOT a defect
    -- and is never counted toward the verdict.
    local HOLE_S = 90.0        -- the acceptance bar: a lane-phase gap past this is the defect
    local EXCUSE_F = 0.5       -- a hole is excused when death/takeover covers this much of it

    -- One log -> the clock facts. The detail view and the corpus row both read this table, so the
    -- headline number cannot differ between the two views of the same game.
    local function analyse(evs, spans)
        local now, keen2 = 0, nil
        local clears, camp_go, camp_done, refills, deaths, t_first = {}, {}, {}, {}, {}, nil
        local death_log, back = false, 0
        -- SU-0 state.
        --   lastw_*    : the second anchor (see the step detector below)
        --   budget_mid : the :5531 exits alone, ANDed on lane=mid - the phantom census's E1.
        --                Never key E1 on `reason=budget` alone: :5877 emits that token too, for a
        --                CAMP exit that does not suppress (376 corpus = 311 lane + 65 camp = 17.3%
        --                over-attribution).
        --   aim_lane   : the running `march_aim ... lane=` hint that resolves a :5439 wave_clear's
        --                lane, which the format does not carry.
        local lastw_ev, lastw_v, lastw_back = {}, nil, {}
        local arrivals, decides, budget_mid = {}, {}, {}
        local disp_lane, wc_mid, wc_side, wave0 = nil, 0, 0, nil
        for _, e in ipairs(evs) do
            -- THE BANNER IS PROSE, NOT DATA. Its release note contains English like "from t=327 to
            -- t=655", which parse_line keys as t=655 exactly like a real field - and being line 35
            -- of the file it became the FIRST stamp, moving g356's t0 from 0.0 to 655.0 and
            -- printing a lane phase of -115s. commit-risk guards the same line at :1665 for the
            -- same reason. Take the build number off it and read nothing else.
            local bv = (e.raw or ""):match("Tinker brain v0%.1%.(%d+)")
            if bv then
                -- v0.1.356 is the first build that emits DEATH at all. Below it "0 deaths" is not
                -- a fact (farm-report:729 states the same rule), so an unexplained hole must stay
                -- UNKNOWN rather than be blamed on the brain.
                if tonumber(bv) >= 356 then death_log = true end
            else
                local ts = tonumber(e.kv.t)
                if ts then
                    if ts < now - 1 then back = back + 1 end   -- ran backwards: two games in one file
                    now = ts; t_first = t_first or ts
                end
                local kl = tonumber(e.kv.klvl)
                if kl and kl >= 2 and not keen2 then keen2 = now end
            end
            -- the banner parses as event="Tinker", so it can never reach the dispatch below
            if e.event == "engage_done" then
                -- SU-0 CHANGE 1, THE ANCHOR. The old test read `lane == "mid"` as the lane exit and
                -- `not lane` as a camp, under a comment asserting "lane= is emitted ONLY by the lane
                -- shove". THAT COMMENT WAS FALSE. engage_done has FIVE emit sites and only ONE
                -- (Tinker.lua:5531) carries lane=. :5439 `reason=wave_clear` sits inside
                -- fsm_engage_wave() - verified at source - so it is a LANE exit, and the old test
                -- filed all 23 of them (corpus count, re-derived twice) as camp completions: counted
                -- as a camp AND punching a mid-clear hole, both wrong, from one line.
                -- SPLIT ON FIELD SHAPE, NOT ON lane=. The three CAMP sites (:5803 :5831 :5877) each
                -- carry dur=; the two LANE sites (:5439 :5531) never do. Corpus partition is exact
                -- and closed: 433 events = 311 lane-only + 99 dur-only + 23 NEITHER, and BOTH = 0.
                -- `reason=` does NOT separate - :5877 emits `reason=budget` for a camp.
                -- POSITIVE test, not "absence of dur=". `lane=` is unique to :5531 and
                -- `reason=wave_clear` is unique to :5439, so {wave_clear} u {lane= present} is
                -- EXACTLY the 334 lane events and its complement EXACTLY the 99 camp events - the
                -- same partition, but stated as what a thing IS. An absence test fails silently in
                -- the worst direction: drop dur= from a camp site one day and every camp exit
                -- becomes a lane exit and inflates the mid-clear count. This way a new emit site
                -- that matches neither shows up as a miscount instead of a fake mid clear.
                if e.kv.lane then
                    if e.kv.lane == "mid" then
                        clears[#clears + 1] = now; budget_mid[#budget_mid + 1] = now
                    end
                elseif e.kv.reason == "wave_clear" then
                    -- a :5439 exit: a LANE exit whose lane the format does not print. Resolve from
                    -- the DISPATCH that created the engage, NOT from a march_aim hint: 11 of the 23
                    -- corpus wave_clears fire with casts=0, so no march_aim was emitted inside that
                    -- engage at all and the hint necessarily belongs to the PREVIOUS one (g336
                    -- t=744.5 is mislabelled exactly that way). Every wave spot comes from
                    -- dispatch_shove (Tinker.lua:3557, the sole kind="wave" constructor), all three
                    -- call sites set ft.lane and then emit_farm("shove") in the next statement, and
                    -- engage_replan always returns to DECIDE - so exactly one
                    -- `farm | pick=shove | lane=` precedes every wave engage. Correct by
                    -- construction rather than by correlation.
                    if disp_lane == "mid" then
                        clears[#clears + 1] = now; wc_mid = wc_mid + 1
                    else
                        -- nil (unresolvable) counts as NOT-mid: the conservative default for an
                        -- anchor this report advertises as an UPPER bound on gaps. Inserting a
                        -- speculative mid service would SHORTEN a gap and could hide a hole.
                        wc_side = wc_side + 1
                    end
                else camp_done[#camp_done + 1] = now end
            elseif e.event == "wavescan" and e.kv.lastw then
                -- SU-0 CHANGE 2, THE SECOND ANCHOR. `lastw=` is State.laneWaveT.mid verbatim
                -- (Tinker.lua:2530), MID only, emitted every 2.0s by the SCAN row all game - dense
                -- where engage_done is sparse - and it is the quantity the SCHEDULER consumes at
                -- :3111-3119, so a stale lastw IS the brain's own clock breaking.
                -- CLOCK: the service time is the SCAN row's OWN `t=`, never the lastw VALUE.
                -- This matters and it is not a preference. At g359 SCAN t=427.3 the field reads
                -- lastw=443.2 - a value 15.9s IN THE FUTURE of its own emit - because the budget
                -- exit at :5523 stamps s.waveEta, a PREDICTION (defect D3). A "value clock" is
                -- therefore not a service clock at all: it shortens every hole that closes on an
                -- exit write. The SCAN row carries its own t= as a whole token, so parse_line keys
                -- it correctly and nothing is inherited here.
                local v = tonumber(e.kv.lastw)     -- reads "-" while the slot is nil
                if v then
                    -- T9 OFF-BY-ONE, FIXED. Every surviving script did `if prev ~= nil`, so the
                    -- first real read only initialised state and the opening gap ran to the SECOND
                    -- step. Cost of that bug: the opening gap is inflated in all 23 logs, median
                    -- +20.1s, and it manufactures 2 phantom opening holes. The first non-"-" read
                    -- IS the first stamp, so it IS a service.
                    -- A STEP IS ANY CHANGE, NOT FORWARD-ONLY. The series is non-monotone by
                    -- construction (the exit writes hold earlier quantities than the arrival write
                    -- at :5084; g358 goes 45.3 then 43.0), and a backward write is still a
                    -- completed shove exit, i.e. still a service. Dropping it under-counts, which
                    -- is the wrong direction for an anchor whose job is to be a LOWER bound on
                    -- gaps. ANY-change also reproduces the published census to the digit
                    -- (20 holes / 2825s / 9 of 23 at zero); forward-only gives 21 / 2930 and
                    -- invents a g330 hole.
                    if lastw_v == nil or v ~= lastw_v then
                        lastw_ev[#lastw_ev + 1] = now
                        -- record the TIME of each backward step, not a running count: the printout
                        -- pairs it with a lane-phase denominator, and a whole-game counter against
                        -- a lane-phase total can print "23 events, 25 of which stepped backwards".
                        if lastw_v ~= nil and v < lastw_v then lastw_back[#lastw_back + 1] = now end
                        lastw_v = v
                    end
                end
            elseif e.event == "wavescan" and e.kv.ln == "mid" and not wave0 then
                -- The first REAL mid wave: the zero for the opening interval. Before a wave exists
                -- there is nothing to serve, so charging the brain from a.t0 (routinely t=0.0,
                -- pregame) is a wrong zero.
                -- est=n IS LOAD-BEARING HERE. The very first scan of every log already prints
                -- `ln=mid e=4 est=y src=clock` - that is the CLOCK MODEL asserting a wave, not an
                -- observation, and keying on it put wave0 at 0.0 and changed nothing. Only a real
                -- read (est=n) proves a wave existed.
                local ec = tonumber(e.kv.e)
                if e.kv.est == "n" and ec and ec >= 1 then wave0 = now end
            elseif e.event == "wave_engage_arrived" then arrivals[#arrivals + 1] = now
            elseif e.event == "farm" then
                -- Kept for the phantom census only. `pick` is one of
                -- shove|recover|refill|none|stack|camp (emit_farm, Tinker.lua:3690) and `lane=` is
                -- written ONLY on pick=shove (:3816/:3826/:3887), so its ABSENCE IS NOT "mid".
                -- EVERY field here is DECIDE-SAMPLED (fsm_decide runs at 8-9% of game time), so
                -- these may bound a window or count an EVENT, and may never produce a rate over
                -- time. Counting dispatch events is legitimate; dividing them by game seconds is
                -- not.
                decides[#decides + 1] = { t = now, pick = e.kv.pick, lane = e.kv.lane }
                if e.kv.pick == "shove" and e.kv.lane then disp_lane = e.kv.lane end
                if e.kv.pick == "camp" then camp_go[#camp_go + 1] = now end
            elseif e.event == "refill_done" then refills[#refills + 1] = now
            elseif e.event == "DEATH" then
                -- same DEATH..RESPAWN span shape the commit-risk report builds at :1682: the brain
                -- returns above tick() while dead, so a hole spanning one is not a farm decision
                deaths[#deaths + 1] = { t0 = tonumber(e.kv.t) or now, t1 = math.huge }
            elseif e.event == "RESPAWN" then
                local sp = deaths[#deaths]
                if sp and sp.t1 == math.huge then sp.t1 = tonumber(e.kv.t) or math.huge end
            end
        end
        -- CAMP SPANS. `pick=camp` is ONE decide, not a duration, so a pick COUNT cannot say whether
        -- camp cost a hole 8s or 80s. Bound each dispatch from events analyse already collects: it
        -- ends at the camp exit that closes it (the engage_done filed into camp_done) or, if the
        -- engage never happened or was abandoned, at the NEXT decide of any pick (fsm_decide only
        -- re-decides when the FSM wants a new target, so the next decide IS the moment the camp
        -- commitment ended). Ends are capped by the next decide and camp picks ARE decides, so the
        -- spans are strictly non-overlapping and `overlap`, which SUMS, stays correct. The walk TO
        -- the camp is inside the span, the walk BACK is not, so this is a LOWER bound on camp cost,
        -- which is the safe direction for a number whose job is to decide whether camp is to blame.
        local camp_spans = {}
        for _, ct in ipairs(camp_go) do
            local ce = now
            for _, d in ipairs(camp_done) do if d > ct then ce = math.min(ce, d); break end end
            for _, d in ipairs(decides) do if d.t > ct then ce = math.min(ce, d.t); break end end
            if ce > ct then camp_spans[#camp_spans + 1] = { t0 = ct, t1 = ce } end
        end
        return { clears = clears, camp_go = camp_go, camp_done = camp_done, refills = refills,
                 camp_spans = camp_spans,
                 deaths = deaths, spans = spans or {}, keen2 = keen2, back = back,
                 t0 = t_first or 0, t1 = now, death_log = death_log,
                 lastw = lastw_ev, lastw_back = lastw_back, lastw_first = lastw_first,
                 arrivals = arrivals, decides = decides, budget_mid = budget_mid,
                 wc_mid = wc_mid, wc_side = wc_side, wave0 = wave0 }
    end

    -- count_in and overlap are hoisted above the SU-0 helpers, which call them (they used to sit
    -- below `analyse` with the other span utilities; lost_of needs overlap for excuse subtraction)
    local function count_in(list, a, b)
        local n = 0
        for _, t in ipairs(list) do if t > a and t <= b then n = n + 1 end end
        return n
    end
    local function overlap(list, a, b)   -- seconds of [a,b] covered by any span (t1 may be huge)
        local s = 0
        for _, sp in ipairs(list) do
            local lo, hi = math.max(a, sp.t0), math.min(b, sp.t1)
            if hi > lo then s = s + (hi - lo) end
        end
        return s
    end

    -- ---- SU-0 CHANGES 3 AND 4 --------------------------------------------------------------
    -- Both read only tables `analyse` already built, so the corpus view and the single-log view
    -- can never disagree about one game.

    local WAVE_S, SLACK_F = 30.0, 1.5
    -- WAVE PRICE. 169 is the MODE, not a mean, and the difference is a real trap: lib/lane.lua
    -- :583-584 give melee 39 / ranged 52, so a cycle-0 4-creep wave is 3x39+52 = 169 - but
    -- :623-625 add a FLAGBEARER on every 2nd wave from wave 5 (+10 at :638), so alternate waves are
    -- 179 and the alternation mean is exactly (169+179)/2 = 174.0. That is where the "~174g" in
    -- TINKER_LANE_CLOCK_DESIGN.md:492 came from: it is the alternation mean, NOT the arithmetic
    -- slip it was filed as. Both under-price lane phase, whose true model mean over the 22 waves
    -- spawning in t=0..650 is 181.5 g/wave (the flagbearer plus the wave-11/21 siege spike).
    -- So: report LOST WAVES as the price-free primary and bracket the gold. Never print 174 alone.
    local GOLD_MODE, GOLD_MEAN = 169.0, 181.5

    -- CHANGE 3: lost_s. THE ACCEPTANCE METRIC THAT REPLACES THE HOLE COUNT.
    -- The >90s hole COUNT must not be a bar, for two independent reasons. (1) BASE RATE: 9 of 23
    -- unmodified logs already pass it, so one game against it is close to a coin flip (rule 9.1.5).
    -- (2) IT IS NOT MONOTONE IN WAVES LOST: g360 scores ZERO holes while a single ~96s
    -- takeover-net window loses 3-4 mid waves. A cadence that serves one wave in four never trips
    -- a gap threshold. lost_s has neither defect - continuous, monotone in waves lost, and a share
    -- of lane phase so it self-normalises across a corpus running 140s to 1262s.
    -- Opening AND closing gaps are INCLUDED: 3 of 20 corpus holes are openings (no mid wave served
    -- in the first ~118s - exactly the watched failure, and no camp rule touches them), and the
    -- corpus's worst gap is a CLOSING one (g328 300.7s), so excluding either deletes the evidence.
    -- EXCUSED TIME IS NOT LOST TIME. The hole count this metric replaces excuses death and user
    -- takeover (EXCUSE_F in rows_of); lost_s must too, or it silently punishes the brain for
    -- seconds it did not own and the "replacement" is harsher than the thing replaced on exactly
    -- the games with a death or a takeover. load_log excises takeover EVENTS but not TIME, so an
    -- excised window still presents as a service gap. `a` carries both span lists and `overlap`
    -- already exists; subtract per segment, before the slack, so an excused window cannot create
    -- lost seconds on its own.
    local function lost_of(a, svc, t0, k2)
        local lost, prev, n, exc = 0.0, t0, 0, 0.0
        local function bill(lo, hi)
            local e = overlap(a.spans, lo, hi) + overlap(a.deaths, lo, hi)
            exc = exc + e
            lost = lost + math.max(0, (hi - lo) - e - SLACK_F * WAVE_S)
        end
        for _, t in ipairs(svc) do
            if t >= k2 then break end
            bill(prev, t); prev = t; n = n + 1
        end
        bill(prev, k2)                                  -- the closing gap is a gap
        local lane_s = math.max(0.01, k2 - t0)
        return { s = lost, share = lost / lane_s, waves = lost / WAVE_S, svc = n, exc = exc }
    end

    -- CHANGE 4: the CORRECTED phantom census.
    -- V2 DEFINES THIS TWICE, INCONSISTENTLY, AND THAT IS THE WHOLE STORY. Its section 6b says
    -- "no lastw step" (-> the published 53%) and made "phantom below 45%" the primary acceptance
    -- bar; its section 8a says "no lastw step AND no wave_engage_arrived" (-> 19%). So what is
    -- corrected here is V2's NUMBER, not its DEFINITION - the 8a definition was right all along
    -- and its own published figure never matched it.
    -- WHY THE 53% BAR IS UNUSABLE, and this is decisive: it is SIGN-INVERTED. A completed 2-cast
    -- shove stamps laneWaveT at :5523 and then suppresses the mid re-shove at :5530 (the v0.1.197
    -- delivery clamp, a user HARD RULE and a SUCCESS path), so the next 0.4s decide redirects up to
    -- 2.0s before the 2.0s SCAN reveals the stamp. Adding one SUCCESSFUL shove therefore moves the
    -- V2 rate 49.76% -> 49.88%. A bar that RISES when the behaviour improves cannot be acceptance.
    -- (That reveal-cadence blind spot is the arc's eighth metric error, and the first about HOW
    -- OFTEN a field is emitted rather than WHERE.)
    local function phantom_of(a, k2)
        local d = a.decides
        local n_disp, n_ep, n_v2, n_e1, n_e3, n_short, dur = 0, 0, 0, 0, 0, 0, {}
        local i = 1
        while i <= #d do
            local e = d[i]
            if e.pick == "shove" and e.lane == "mid" and e.t < k2 then
                -- COUNT EPISODES, NOT DECIDES. A run of consecutive mid dispatches is ONE
                -- commitment held across several 0.4s decides; they all share the same `stop`, so
                -- charging each of them separately multiplied one failure into several (10 of 75
                -- corpus-wide, and 3 of 6 in g360). Collapse the run first.
                local last = i
                while last + 1 <= #d and d[last + 1].pick == "shove" and d[last + 1].lane == "mid"
                      and d[last + 1].t < k2 do last = last + 1 end
                n_disp = n_disp + (last - i + 1)
                n_ep = n_ep + 1
                -- WINDOW: [first dispatch of the run, the first later farm line that is NOT a mid
                -- dispatch], clamped to the end of lane phase. That instant is the moment the
                -- brain provably changed its mind.
                local stop = (d[last + 1] and math.min(d[last + 1].t, k2)) or k2
                local lo = e.t - 0.05
                local e1 = count_in(a.budget_mid, lo, stop) > 0   -- completed mid budget exit
                local e2 = count_in(a.lastw, lo, stop) > 0        -- a lastw step (V2's only test)
                local e3 = count_in(a.arrivals, lo, stop) > 0     -- wave_engage_arrived, LANE-BLIND
                if not e2 then
                    n_v2 = n_v2 + 1
                    if e1 then n_e1 = n_e1 + 1
                    elseif e3 then n_e3 = n_e3 + 1
                    elseif stop - e.t < 2.0 then
                        -- UNMEASURABLE, not phantom. A window shorter than one SCAN reveal period
                        -- (K.AUTO_WAVESCAN_S 2.0) cannot contain the evidence that would clear it,
                        -- so calling it a phantom would apply to this census the exact blind spot
                        -- it indicts V2 for - merely moved from the evidence test to the window
                        -- length. Bucket it separately and let the reader see the size.
                        n_short = n_short + 1
                    else dur[#dur + 1] = stop - e.t end
                end
                i = last + 1
            else i = i + 1 end
        end
        table.sort(dur)
        local sum = 0; for _, x in ipairs(dur) do sum = sum + x end
        return { disp = n_disp, ep = n_ep, v2 = n_v2, e1 = n_e1, e3 = n_e3, real = #dur,
                 short = n_short,
                 -- lane_certain drops E3, which carries no lane= and so may be a side-lane
                 -- arrival. Corpus-wide E1-and-not-E3 is ZERO windows, i.e. E1 adds nothing over
                 -- E3; the two bars differ only by E3's lane-blindness. Print both, and any
                 -- acceptance bar must NAME which one it is set against.
                 lane_certain = #dur + n_e3,
                 rate = n_ep > 0 and #dur / n_ep or 0,
                 v2rate = n_ep > 0 and n_v2 / n_ep or 0,
                 secs = sum, med = #dur > 0 and dur[math.ceil(#dur / 2)] or 0 }
    end
    local function med(t) return #t > 0 and t[math.ceil(#t / 2)] or 0 end  -- t must be pre-sorted

    -- The gap ledger. One row per clear (gap = time since the previous clear, or since the first
    -- stamped event for the opening row), plus a closing row for the tail the log ends on - without
    -- that tail a game that simply STOPS clearing at t=300 and runs to t=500 scores zero holes,
    -- which is the "report shrinks its own evidence" failure this file has been bitten by twice.
    -- A gap belongs to the phase it STARTS in, and only the part before Keen L2 is charged to the
    -- lane clock: g358's last lane clear is followed by 497.6s of nothing, but 202.7s of that is
    -- lane phase and the rest is legitimate raid-era decline.
    local function rows_of(a)
        local k2 = a.keen2 or math.huge      -- no klvl>=2 anywhere: the whole log is lane phase
        local rows = {}
        for i = 1, #a.clears + 1 do
            -- OPENING ROW FIX. The opening interval used to start at a.t0, which is whatever the
            -- log first stamped - routinely t=0.0, i.e. PREGAME. No mid wave exists then, so the
            -- brain cannot serve one, and every opening gap was inflated by that unserviceable
            -- prefix. It is not an off-by-one and there is no phantom clear at t=0.0 (g332's first
            -- clear really is at 117.5); it is a wrong ZERO. Start the clock instead at the first
            -- moment a mid wave was OBSERVED (a.wave0, the first `wavescan ln=mid` carrying
            -- creeps - unconditional, and observed rather than assumed). It matters: g332 117.5
            -- and run64 112.8 both sit near enough the 90s bar for a ~30s prefix to decide them.
            local prev = (i == 1) and math.max(a.t0, a.wave0 or a.t0) or a.clears[i - 1]
            local here = a.clears[i]                        -- nil on the closing row
            local stop = here or a.t1
            if not (i == #a.clears + 1 and stop - prev <= 0) then
                local charged = math.min(stop, k2)
                -- RIGHT-CENSORING. Two rows do not observe their own end: the closing row (the log
                -- stopped) and any row whose gap STRADDLES Keen L2 (we charge k2 - prev to lane
                -- phase, but the service that would have closed it lands in the raid era, so the
                -- lane figure is "at least this long", never "this long"). Reporting either as an
                -- observed interval injects a guaranteed-large value into the lane distribution.
                -- Keep their SECONDS (they are genuinely unserved lane time, so lost_s must bill
                -- them) but do not let them count as completed holes for the verdict.
                local censored = (here == nil) or (prev < k2 and stop > k2)
                rows[#rows + 1] = {
                    n = here and i or nil, t = here, prev = prev, gap = stop - prev,
                    lane_gap = (prev < k2) and (charged - prev) or nil,
                    phase = (prev < k2) and "lane" or "raid",
                    open = (here == nil),                   -- log ended here, no clear closed it
                    censored = censored,
                }
            end
        end
        for _, r in ipairs(rows) do
            local a0, b0 = r.prev, r.prev + (r.lane_gap or r.gap)
            r.camp_go, r.camp_done = count_in(a.camp_go, a0, b0), count_in(a.camp_done, a0, b0)
            r.camp_s = overlap(a.camp_spans, a0, b0)
            r.refill = count_in(a.refills, a0, b0)
            r.dead, r.tko = overlap(a.deaths, a0, b0), overlap(a.spans, a0, b0)
            -- a censored row is not a completed observation, so it cannot be a counted hole
            r.hole = (r.phase == "lane") and (r.lane_gap or 0) > HOLE_S and not r.censored
            local len = math.max(1, r.lane_gap or r.gap)
            -- CAUSE IS TIME-WEIGHTED, AND SAYS SO. The old test was `camp_go > 0 or camp_done > 0`,
            -- a PICK COUNT off a decide-sampled field, so ONE decide that merely named camp
            -- relabelled a whole hole as camp-caused. Charge camp the way death and takeover are
            -- already charged, against the same EXCUSE_F share of the window, and print the share in
            -- BOTH branches so a hole camp barely touched can never read like one camp ate. Camp
            -- stays a DEFECT and stays ahead of the death-log test: a camp span is directly observed
            -- and needs no DEATH instrument.
            local camp_f = r.camp_s / len
            r.cause = (r.tko >= EXCUSE_F * len and "EXCUSED:takeover")
                   or (r.dead >= EXCUSE_F * len and "EXCUSED:dead")
                   or (r.camp_s >= EXCUSE_F * len
                       and string.format("DEFECT:camp (camp %.1fs = %.0f%% of the window)", r.camp_s, camp_f * 100))
                   or ((a.death_log and "DEFECT:idle" or "UNKNOWN:no-death-log")
                       .. (r.camp_s > 0
                           and string.format(" (camp only %.1fs = %.0f%%, %d pick(s): not the cause)",
                               r.camp_s, camp_f * 100, r.camp_go)
                           or ""))
        end
        return rows
    end

    -- ---- corpus mode: one row per log, so the noise floor for THIS metric can be established ----
    if #paths > 1 then
        print(string.format("--- clock report --- CORPUS, %d logs, POST-SU-0 (widened anchor + lastw + lost_s + phantom)", #paths))
        print(string.format("%-32s %-6s %-6s %-5s %-7s %-5s %-7s %-7s %-6s %-6s %-5s %-5s %s",
            "log", "dur_s", "keenL2", "lane", "lane/mn", "holes", "wrstgap", "lw_wrst", "lost%", "lostW", "epis", "ph%", "verdict"))
        local ranked = {}
        -- These accumulators ARE the baseline the next behavioural run is judged against, so they
        -- must come from a committed tool. Dossier section 8.5 exists because the previous set of
        -- baselines came from scratchpad scripts that no longer exist, and its own recorded
        -- precedent is a published "+64.4s" that reproduces nowhere.
        local A_lost, A_worst, A_lw, A_wave = {}, {}, {}, {}
        local A_disp, A_real, A_v2, A_zero, A_holes, A_certain = 0, 0, 0, 0, 0, 0
        local A_short, A_nohole = 0, 0
        for _, p in ipairs(paths) do
            local evs, _, spans = load_log(p)
            local a = analyse(evs, spans)
            local rows = rows_of(a)
            local k2 = a.keen2 or a.t1
            local lane_n, raid_n, lg = 0, 0, {}
            for _, t in ipairs(a.clears) do if t < k2 then lane_n = lane_n + 1 else raid_n = raid_n + 1 end end
            for _, r in ipairs(rows) do if r.phase == "lane" and r.n then lg[#lg + 1] = r.lane_gap end end
            table.sort(lg)
            local holes, worst, verdict = 0, 0, "PASS"
            local worst_gap = 0    -- UNCONDITIONAL worst lane gap. `worst` below is a worst-HOLE
                                   -- and reads 0 when a log has no hole, which is not a gap of 0 -
                                   -- printing it against the lastw column made four logs show an
                                   -- "upper bound" of 0 beside a lower bound of 56-66.
            for _, r in ipairs(rows) do
                if r.phase == "lane" and (r.lane_gap or 0) > worst_gap then worst_gap = r.lane_gap end
                if r.hole then
                    holes = holes + 1
                    if (r.lane_gap or 0) > worst then worst = r.lane_gap end
                    -- UNKNOWN IS NOT EXCUSED. Time-weighted camp moves the camp-minority holes of a
                    -- pre-DEATH build (below v0.1.356) out of DEFECT, and the old two-way fold
                    -- printed every one of them as EXCUSED, i.e. "a death or a takeover explains it",
                    -- on a log that cannot observe a death at all. Precedence FAIL > UNKNOWN >
                    -- EXCUSED > PASS: a log carrying an unattributable hole must not outrank one
                    -- whose holes are all accounted for.
                    if r.cause:match("^DEFECT") then verdict = "FAIL"
                    elseif r.cause:match("^UNKNOWN") then if verdict ~= "FAIL" then verdict = "UNKNOWN" end
                    elseif verdict == "PASS" then verdict = "EXCUSED" end
                end
            end
            local lane_s = math.max(0.01, k2 - a.t0)
            -- the lastw anchor, closing gap included (the corpus worst gap IS a closing one)
            local lw_worst, prev_l = 0, a.t0
            for _, t in ipairs(a.lastw) do
                if t >= k2 then break end
                if t - prev_l > lw_worst then lw_worst = t - prev_l end
                prev_l = t
            end
            if k2 - prev_l > lw_worst then lw_worst = k2 - prev_l end
            local L = lost_of(a, a.lastw, a.t0, k2)   -- the LOWER bound = the honest baseline
            local ph = phantom_of(a, k2)
            A_lost[#A_lost + 1] = L.share; A_worst[#A_worst + 1] = worst_gap; A_lw[#A_lw + 1] = lw_worst
            A_wave[#A_wave + 1] = L.waves
            A_disp = A_disp + ph.ep; A_real = A_real + ph.real; A_v2 = A_v2 + ph.v2
            A_certain = A_certain + ph.lane_certain; A_holes = A_holes + holes
            A_short = A_short + ph.short
            if ph.real == 0 then A_zero = A_zero + 1 end
            if holes == 0 then A_nohole = A_nohole + 1 end
            ranked[#ranked + 1] = {
                key = p,
                line = string.format("%-32s %-6.0f %-6s %-5d %-7.2f %-5d %-7.0f %-7.0f %-6.1f %-6.1f %-5d %-5.0f %s",
                    (p:match("([^/\\]+)$") or p):sub(1, 32), a.t1 - a.t0,
                    a.keen2 and string.format("%.0f", a.keen2) or "-",
                    lane_n, lane_n / (lane_s / 60), holes, worst_gap, lw_worst,
                    L.share * 100, L.waves, ph.ep, ph.rate * 100,
                    verdict .. (a.back > 0 and "  <<< NON-MONOTONIC CLOCK, >1 game in this file" or "")),
                worst = worst_gap, dur = a.t1 - a.t0,
            }
        end
        local dmin, dmax = math.huge, 0
        for _, r in ipairs(ranked) do dmin = math.min(dmin, r.dur); dmax = math.max(dmax, r.dur) end
        -- worst-first, filename as the tie-break: the ranking must not depend on argv order or on
        -- any pairs() walk (this file shipped that bug once already)
        table.sort(ranked, function(x, y)
            if x.worst ~= y.worst then return x.worst > y.worst end
            return x.key < y.key
        end)
        for _, r in ipairs(ranked) do print(r.line) end
        local function pct(t, q)
            if #t == 0 then return 0 end
            table.sort(t); return t[math.max(1, math.min(#t, math.ceil(q * #t)))]
        end
        print("")
        print("ranked worst-first by wrstgap = the largest LANE-PHASE gap on the engage_done anchor")
        print("(UNCONDITIONAL, not hole-gated, so a log with no hole still shows its real worst gap).")
        print("lw_wrst is the largest lane-phase gap on the LASTW anchor - NOT necessarily the same")
        print("window; on some logs the two anchors' worst gaps are disjoint. lost%/lostW use lastw and")
        print(string.format("are the CONSERVATIVE reading. Games run %.0fs to %.0fs: compare shares and rates, never counts.", dmin, dmax))
        print("")
        print("CORPUS BASELINE - the re-derivable replacement for the lost scratchpad numbers:")
        print(string.format("    lost_s share of lane phase : median %4.1f%%   p25 %4.1f%%   p75 %4.1f%%   (n=%d logs)",
            pct(A_lost, 0.5) * 100, pct(A_lost, 0.25) * 100, pct(A_lost, 0.75) * 100, #A_lost))
        print(string.format("      (slack = %.0fs = %.1f wave cycles; excused death/takeover time already subtracted)",
            SLACK_F * WAVE_S, SLACK_F))
        print(string.format("    lost WAVES per game        : median %4.1f   p25 %4.1f   p75 %4.1f",
            pct(A_wave, 0.5), pct(A_wave, 0.25), pct(A_wave, 0.75)))
        print(string.format("    worst lane gap, engage_done: median %3.0fs   max %3.0fs", pct(A_worst, 0.5), pct(A_worst, 1.0)))
        print(string.format("    worst lane gap, lastw      : median %3.0fs   max %3.0fs", pct(A_lw, 0.5), pct(A_lw, 1.0)))
        local z_lw = 0
        for _, w in ipairs(A_lw) do if w <= HOLE_S then z_lw = z_lw + 1 end end
        print(string.format("    holes >%.0fs, engage_done   : %d total = %.2f per log; %d of %d logs score ZERO (%.0f%%)",
            HOLE_S, A_holes, A_holes / #paths, A_nohole, #paths, A_nohole / #paths * 100))
        print(string.format("    logs with NO lastw gap >%.0fs: %d of %d (%.0f%%)   <- BASE RATES DIFFER PER ANCHOR.",
            HOLE_S, z_lw, #paths, z_lw / #paths * 100))
        print("      Quote the one belonging to the bar you are setting; they are not interchangeable.")
        print(string.format("    phantom EPISODES           : %d    V2-6b test %d = %.0f%%    TRUE phantom %d = %.0f%% (%.1f/log)",
            A_disp, A_v2, A_disp > 0 and A_v2 / A_disp * 100 or 0,
            A_real, A_disp > 0 and A_real / A_disp * 100 or 0, A_real / #paths))
        print(string.format("    lane-CERTAIN phantom       : %d = %.0f%%   (drops the lane-blind wave_engage_arrived)",
            A_certain, A_disp > 0 and A_certain / A_disp * 100 or 0))
        print(string.format("    windows under one 2.0s SCAN: %d  (UNMEASURABLE, excluded from TRUE phantom)", A_short))
        print(string.format("    logs with ZERO true phantom: %d of %d", A_zero, #paths))
        print("")
        print("READ THE BASELINE, NOT JUST A ROW. Rule 9.1.5: never accept an acceptance bar that the")
        print("unmodified corpus already passes, and state the base rate beside every threshold - from")
        print("the anchor that bar is computed on. The hole count is a coarse quantisation of lostW that")
        print("saturates: logs scoring zero holes still lose waves, so prefer lostW as the bar.")
        os.exit(0)
    end

    -- ---- single log: the full ledger ----
    local a = analyse(events, takeover_spans)
    if #a.clears == 0 then
        print("--- clock report --- no `engage_done` LANE exit resolved to mid in this log: nothing served mid, or a pre-engage_done build")
        os.exit(0)
    end
    local rows = rows_of(a)
    local k2 = a.keen2 or a.t1
    local mins = math.max(0.01, (a.t1 - a.t0) / 60)
    print(string.format("--- clock report --- %d mid clears over %.0fs (t %.1f .. %.1f)", #a.clears, a.t1 - a.t0, a.t0, a.t1))
    print(string.format("    game length %.1f min -- COMPARE RATES, NOT COUNTS, across games", mins))
    if a.keen2 then
        print(string.format("    KEEN L2 at t=%.1f  ->  lane phase t=%.1f..%.1f (%.0fs)   raid era t=%.1f..%.1f (%.0fs)",
            a.keen2, a.t0, a.keen2, a.keen2 - a.t0, a.keen2, a.t1, a.t1 - a.keen2))
    else
        print("    KEEN L2 never reached (no klvl>=2 in the log): the WHOLE log is scored as lane phase")
    end
    if a.back > 0 then
        print(string.format("    <<< THE CLOCK RAN BACKWARDS %d time(s): this file holds more than one game. Split it at the", a.back))
        print("        last `self_acquired` before reading anything below - every gap across the seam is fiction.")
    end
    print("")

    -- ANCHOR, POST-SU-0. This comment used to carry a remembered `lastw` cross-check - "g358's
    -- worst lane gap at 50s where this anchor showed 207s, and g359's at 125s against 106s here".
    -- ALL THREE OF THOSE NUMBERS WERE WRONG, and the 50s had already produced one published wrong
    -- conclusion ("g358 IS FINE"; g358 is in fact the worse game on BOTH anchors). Re-derived:
    --   g358 worst lane-phase gap on lastw = 162.5s (last step t=459.7 -> Keen L2 t=622.2)
    --   g359                               = 108.3s (t=319.0 -> t=427.3, fully interior)
    --   this anchor prints 202.7 for g358, never 207.
    -- The 50s is g358's largest gap with BOTH endpoints inside lane phase on a forward-only
    -- detector (50.4s), i.e. it silently drops the CLOSING gap - and g358's worst hole IS a closing
    -- gap. The 125s is near g359's "value clock" reading (124.6s), but a value clock is not a
    -- service clock: at g359 SCAN t=427.3 the field reads lastw=443.2, a value 15.9s in the FUTURE
    -- of its own emit, because :5523 stamps a prediction. Both are retracted.
    -- NOTHING IS REMEMBERED HERE ANY MORE. The LASTW block below computes both anchors from this
    -- log on every run and NAMES ITS CLOCK, so there is no number left to go stale.
    print("MID-CLEAR CADENCE (engage_done LANE exits, stamped by the running `| t=`):")
    print("    ANCHOR WIDENED (SU-0): a lane exit is `engage_done` with NO dur=, which restores the")
    print("    :5439 wave_clear exits the old lane==\"mid\" test filed as camp completions. Gaps here")
    print("    are still an UPPER BOUND; the LASTW block below is the lower bound. Read both.")
    print("    gap = seconds since the previous clear. lanegap = the part of it before Keen L2, which is")
    print("    what the lane clock is judged on. camp/cdone/camp_s/refill/dead_s/tko_s cover the")
    print("    LANEGAP window. camp = camp PICKS (decide-sampled, a COUNT of decides, NOT a duration);")
    print("    camp_s = seconds committed to camps in the window (dispatch to the camp exit, or to the")
    print("    next decide when the camp was abandoned; the walk BACK is excluded, so it is a lower")
    print("    bound). The cause column is charged on camp_s, never on the pick count.")
    print(string.format("    %-4s %-8s %-8s %-8s %-6s %-5s %-6s %-7s %-6s %-6s %-6s %s",
        "#", "t", "gap", "lanegap", "phase", "camp", "cdone", "camp_s", "refill", "dead_s", "tko_s", "note"))
    for _, r in ipairs(rows) do
        print(string.format("    %-4s %-8s %-8.1f %-8s %-6s %-5d %-6d %-7.1f %-6d %-6.0f %-6.0f %s",
            r.n and tostring(r.n) or "-",
            r.t and string.format("%.1f", r.t) or "(end)",
            r.gap, r.lane_gap and string.format("%.1f", r.lane_gap) or "-",
            r.phase, r.camp_go, r.camp_done, r.camp_s, r.refill, r.dead, r.tko,
            (r.hole and string.format("<<< HOLE %.1fs of lane phase, %s", r.lane_gap, r.cause) or "")
                .. (r.open and " (log ended; no clear closed this gap)" or "")))
    end
    if not a.death_log then
        print("    dead_s is UNKNOWN, not 0, on this log: DEATH/RESPAWN arrived in v0.1.356 and this build predates it.")
    end
    print("")

    -- phase-split cadence. The lane-phase median is the number the user's "runs like a clock"
    -- judgement is about; the raid-era one is printed to be READ, not judged.
    local lg, rg = {}, {}
    for _, r in ipairs(rows) do
        if r.n then
            if r.phase == "lane" then lg[#lg + 1] = r.lane_gap else rg[#rg + 1] = r.gap end
        end
    end
    table.sort(lg); table.sort(rg)
    local lane_n, raid_n = 0, 0
    for _, t in ipairs(a.clears) do if t < k2 then lane_n = lane_n + 1 else raid_n = raid_n + 1 end end
    local lane_s, raid_s = math.max(0.01, k2 - a.t0), math.max(0.01, a.t1 - k2)
    local function gapstat(g) return #g == 0 and "(no gap starts in this phase)"
        or string.format("median gap %.1fs   max %.1fs", med(g), g[#g]) end
    print("CADENCE BY PHASE (rates per minute of THAT phase - the phases are not the same length):")
    print(string.format("    lane phase: %d clears in %.0fs = %.2f/min   %s",
        lane_n, lane_s, lane_n / (lane_s / 60), gapstat(lg)))
    if a.keen2 then
        print(string.format("    raid era:   %d clears in %.0fs = %.2f/min   %s   (declining here is CORRECT)",
            raid_n, raid_s, raid_n / (raid_s / 60), gapstat(rg)))
    else
        print("    raid era:   never entered (Keen never hit L2), so there is nothing to compare the lane phase against")
    end
    print("")

    -- THE HEADLINE
    local holes, worst, worst_at, worst_cause, defect, unknown = 0, 0, nil, nil, 0, 0
    for _, r in ipairs(rows) do
        if r.hole then
            holes = holes + 1
            if r.cause:match("^DEFECT") then defect = defect + 1
            elseif r.cause:match("^UNKNOWN") then unknown = unknown + 1 end
            if r.lane_gap > worst then worst, worst_at, worst_cause = r.lane_gap, r.prev, r.cause end
        end
    end
    print(string.format("HEADLINE - lane-phase mid-clear gaps over %.0fs:", HOLE_S))
    -- UNKNOWN IS NOT EXCUSED. `holes - defect` folded the unattributable holes of a pre-DEATH build
    -- into "excused by death/takeover" on logs that cannot observe a death at all, and time-weighting
    -- camp puts more holes there. Count the three classes apart.
    print(string.format("    holes: %d   (the brain owns %d, %d excused by death/takeover, %d unattributable)",
        holes, defect, holes - defect - unknown, unknown))
    if holes > 0 then
        print(string.format("    largest: %.1fs  starting at the clear at t=%.1f  cause %s", worst, worst_at, worst_cause))
    end
    print(string.format("    VERDICT: %s",
        (defect > 0 and "FAIL - the lane clock broke while the brain had control")
        or (unknown > 0 and "UNKNOWN - holes left that this build cannot attribute (no DEATH instrument below v0.1.356)")
        or (holes == 0 and "PASS - lane phase ran like a clock")
        or "PASS (excused) - every hole was a death or a user takeover"))
    -- SU-0 deliberately does NOT change this verdict. A "FAIL only if the hole survives BOTH
    -- anchors" rule was specified and then MEASURED before shipping: it flips 5 of 23 games
    -- FAIL -> PASS (g330 g336 g340 g341 g360), and g360 is precisely the game that loses 3-4 mid
    -- waves while scoring zero holes. A rule that passes that game is backwards. Not shipped.
    print("    ^ THE HOLE COUNT IS A COARSE QUANTISATION OF lost_s BELOW, AND IT SATURATES. It")
    print("      correlates with lost waves but only loosely, so it is not wrong - it is blunt: the")
    print("      logs that score ZERO holes still lose waves too, and g360 shows one hole")
    print("      here while showing NONE on the lastw anchor (worst 80.2s). Base rates differ per")
    print("      anchor and must be quoted per anchor - see the corpus block, which prints both.")
    print("      Judge on lost_s - and on WATCHED BEHAVIOUR above every number in this report.")
    print("")

    -- ---- SU-0: THE SECOND ANCHOR, lost_s, AND THE CORRECTED PHANTOM CENSUS -------------------
    local lw, lwl, prev_l = a.lastw, {}, a.t0
    for _, t in ipairs(lw) do
        if t >= k2 then break end
        lwl[#lwl + 1] = t - prev_l; prev_l = t
    end
    local lw_worst, lw_at = k2 - prev_l, prev_l          -- the closing gap is a gap
    for i, g in ipairs(lwl) do
        if g > lw_worst then lw_worst, lw_at = g, (i == 1 and a.t0 or lw[i - 1]) end
    end
    local lws = {}
    for _, g in ipairs(lwl) do lws[#lws + 1] = g end
    table.sort(lws)
    print("LASTW ANCHOR (State.laneWaveT.mid via `wavescan SCAN lastw=`, revealed every 2.0s):")
    print("    CLOCK = THE SCAN ROW'S OWN `t=` (the reveal clock), never the lastw VALUE, because a")
    print("    PREDICTION IS NOT AN OBSERVATION: :5523 stamps s.waveEta, so the value can even sit")
    print("    in the FUTURE of its own emit (g359 t=427.3 reads lastw=443.2, +15.9s). That is")
    print("    defect D3. The two conventions disagree by up to 16s on ONE hole - a future-valued")
    print("    stamp LENGTHENS the hole closing on it, a past-valued exit write SHORTENS it - so")
    print("    naming the clock is mandatory, and no prior document ever did.")
    print(string.format("    %d stamp events in lane phase, %d of which stepped BACKWARDS (the exit writes at",
        #lwl, count_in(a.lastw_back, a.t0 - 1, k2)))
    print("    :5438/:5523 hold earlier quantities than the arrival write at :5084 - three writers,")
    print("    three quantities, one slot). A step is ANY change: a backward write is still a")
    print("    completed shove exit, so dropping it would under-count an anchor meant to over-count.")
    print(string.format("    median gap %.1fs   worst lane-phase gap %.1fs, starting at t=%.1f",
        #lws > 0 and lws[math.ceil(#lws / 2)] or 0, lw_worst, lw_at))
    if a.wc_mid + a.wc_side > 0 then
        print(string.format("    (%d `wave_clear` lane exit(s) carry no lane=; resolved from the DISPATCH that created",
            a.wc_mid + a.wc_side))
        print(string.format("     the engage: %d mid, %d side/unresolved.)", a.wc_mid, a.wc_side))
    end
    print("    BRACKET: engage_done UNDER-counts services so its gaps are an UPPER bound; lastw")
    print("    OVER-counts (it stamps at arrival even when the wave is never served) so its gaps")
    print("    are a LOWER bound. A hole surviving BOTH is real. The bracket is on SERVICE COUNT")
    print("    and gap POPULATION, never on one second: the 2.0s reveal quantisation means a lastw")
    print("    gap can read ~2s LONGER than the same engage_done gap while still counting more")
    print("    services. That is expected, not a broken bracket.")
    print("")

    local L1, L2 = lost_of(a, a.clears, a.t0, k2), lost_of(a, lw, a.t0, k2)
    print(string.format("LOST_S - lane-phase seconds beyond %.0fs (%.1f wave cycles) of any mid service,",
        SLACK_F * WAVE_S, SLACK_F))
    print(string.format("         net of %.0fs excused by user-takeover%s:", L2.exc,
        a.death_log and " and death" or " (DEATH DATA ABSENT - see below)"))
    if not a.death_log then
        -- DEATH/RESPAWN shipped in v0.1.356 and this build predates it, so a.deaths is EMPTY and
        -- the subtraction above silently removed ZERO. That is "treat unknown as zero", which is
        -- the exact error the ledger's own dead_s column warns about. Stated, not hidden.
        -- Corpus note, verified: there are currently NO DEATH lines in ANY log, and
        -- debug.g356_TWO_DEATHS.log - the log named for its two deaths - banners v0.1.355, one
        -- version below the instrument. Any "excused by death" arithmetic anywhere in this arc is
        -- reading a sentinel, not a measurement.
        print("         ^ this build predates DEATH/RESPAWN (v0.1.356): death seconds are UNKNOWN,")
        print("           NOT zero, so lost_s here is an UPPER bound on brain-owned lost time.")
    end
    print(string.format("    engage_done anchor : %6.1fs = %4.1f%% of lane phase = %4.1f waves   (upper bound)",
        L1.s, L1.share * 100, L1.waves))
    print(string.format("    lastw anchor       : %6.1fs = %4.1f%% of lane phase = %4.1f waves   (LOWER bound)",
        L2.s, L2.share * 100, L2.waves))
    print(string.format("    priced %.0f to %.0f g GROSS on the lastw anchor: %.0f g is the MODAL wave, %.1f g the",
        L2.waves * GOLD_MODE, L2.waves * GOLD_MEAN, GOLD_MODE, GOLD_MEAN))
    print("    lane-phase model MEAN (lib/lane.lua:623-625 adds a flagbearer to every 2nd wave from")
    print("    wave 5, and waves 11/21 are siege). Quoting any ONE price as THE price is the error.")
    print("    GROSS is load-bearing: nothing subtracts the camp gold banked during the hole, so")
    print("    this is not a break-even and none is computable from a log. Note the slack window is")
    print("    itself a dead zone - a cadence that never quite breaches 45s bills zero.")
    print("    Lost WAVES is the price-free number; prefer it.")
    print("")

    local ph = phantom_of(a, k2)
    print("PHANTOM MID DISPATCH (lane phase) - the brain picks mid, commits, and serves nothing.")
    print("EPISODES, not decides: a run of consecutive mid dispatches is ONE commitment held across")
    print("several 0.4s decides, and charging each separately multiplies one failure into several.")
    print(string.format("    mid dispatch decides %d, collapsing to %d EPISODES", ph.disp, ph.ep))
    print(string.format("    V2 section-6b test (no lastw step)          %4d = %2.0f%% of episodes",
        ph.v2, ph.v2rate * 100))
    print(string.format("      of those, window holds a completed mid budget exit       %4d", ph.e1))
    print(string.format("      of those, window holds a wave_engage_arrived, no exit    %4d", ph.e3))
    print(string.format("      of those, window under one 2.0s SCAN period: UNMEASURABLE %4d", ph.short))
    print(string.format("    TRUE PHANTOM (no service evidence at all)   %4d = %2.0f%%   %.0fs, median %.1fs",
        ph.real, ph.rate * 100, ph.secs, ph.med))
    print(string.format("    lane-CERTAIN variant (drops the lane-blind wave_engage_arrived)  %4d", ph.lane_certain))
    print("    WHY V2's 6b TEST IS NOT USABLE AS A BAR: a completed 2-cast shove stamps laneWaveT")
    print("    (:5523) and then suppresses the mid re-shove (:5530, the v0.1.197 delivery clamp, a")
    print("    user HARD RULE and a SUCCESS path), so the next 0.4s decide redirects up to 2.0s")
    print("    BEFORE the 2.0s SCAN can reveal the stamp. The test therefore misses a real service")
    print("    in a large share of the windows that hold a completed mid budget exit - see the")
    print("    per-log counts above - and it is nearly blind to the very behaviour it measures.")
    print("    This corrected test is arithmetically IDENTICAL to V2's OWN section-8a definition:")
    print("    what is being corrected is V2's published NUMBER, not its wording. Corpus baselines")
    print("    are printed by the corpus mode; they are deliberately not frozen into this block.")
    os.exit(0)
elseif mode == "state_report" then
    -- ---- FSM-OCCUPANCY RECONSTRUCTOR -------------------------------------------------------
    -- WHY THIS EXISTS. A median 90% of the seconds inside a lane-phase hole carry NO `farm`
    -- decide at all, and the brain's FSM state is not logged anywhere: `State.fsm` appears in the
    -- log ONLY on the `autofarm` toggle line. So every analysis of the lane-clock arc so far has
    -- reasoned about a window it could not observe. The state is unlogged, but most TRANSITIONS
    -- are logged, and every one of them is on the unconditional list. This mode brackets each
    -- silence between consecutive decides and attributes it to the transition that opened it.
    --
    -- THE OUTPUT THAT DECIDES THE NEXT STEP is the UNATTRIBUTED share. If it is small, the silences
    -- are explained by events already in the format and no new log line is needed. If it is large,
    -- the honest next move is a log-only ship: emit State.fsm as one token on the existing 2.0s
    -- `wavescan SCAN` row, which costs no behaviour and turns this into a sampled occupancy series.
    --
    -- POLLERS ARE NOT TRANSITIONS. wavescan / fog_probe / fog_hero / camp_scan / creepspd run on
    -- their own timers and say nothing about what the hero is doing; a silence "opened by" a
    -- wavescan is really opened by whatever preceded it. They are excluded from openers and
    -- counted separately as filler, because a silence containing ONLY pollers is the interesting
    -- case: it means the brain emitted nothing at all.
    local SILENCE_S = 8.0
    local POLLER = { wavescan = true, fog_probe = true, fog_hero = true, camp_scan = true,
                     creepspd = true, commit_risk = true }

    local function state_of(p)
        local evs, _, spans = load_log(p)
        local now, t0, k2 = 0, nil, nil
        local seq, decides, clears, dlane = {}, {}, {}, nil
        for _, e in ipairs(evs) do
            if (e.raw or ""):match("Tinker brain v0%.1%.") then goto skip end
            do
                local ts = tonumber(e.kv.t)
                if ts then now = ts; t0 = t0 or ts end
                local kl = tonumber(e.kv.klvl)
                if kl and kl >= 2 and not k2 then k2 = now end
                -- MANY loglines are `event BARE_TOKEN` (e.g. `move keen_to_anchor`,
                -- `move rearm_reset_keen`, `keen FIRED`), and parse_line only keys k=v pairs, so
                -- the bare token is dropped entirely. Without it every movement collapses to one
                -- opener called "move", which is the single most enriched bucket inside holes and
                -- therefore the one label that must NOT stay opaque. Recover it from the raw line.
                local tag = e.kv.src or e.kv.reason or e.kv.why
                if not tag then
                    local rest = (e.raw or ""):match("^%[%w+%]%s*%[[^%]]+%]%s*%S+%s+(%S+)")
                    if rest and not rest:find("=", 1, true) and rest ~= "|" then tag = rest end
                end
                -- keen_home is the largest opener bucket in most logs and it is TWO behaviours: an
                -- ordinary refill/return trip and an UNSTICK teleport out of a wedged walk. purpose=
                -- is a string literal handed in by the caller (Tinker.lua:651/659, three call sites:
                -- return/panic/unstick), so the token printed IS the branch taken, and no other event
                -- in the corpus carries that key. Logs older than v0.1.331 have no purpose= and keep
                -- the unsplit label.
                if e.event == "keen_home" and e.kv.purpose then
                    tag = (tag and (tag .. " ") or "") .. tostring(e.kv.purpose)
                end
                seq[#seq + 1] = { t = now, ev = e.event, src = tag }
                if e.event == "farm" then
                    decides[#decides + 1] = now
                    if e.kv.pick == "shove" and e.kv.lane then dlane = e.kv.lane end
                elseif e.event == "engage_done" then
                    -- the SAME lane/camp split the clock report uses (SU-0): lane= present, else
                    -- reason=wave_clear resolved from the dispatch that created the engage.
                    if e.kv.lane == "mid" then clears[#clears + 1] = now
                    elseif e.kv.reason == "wave_clear" and dlane == "mid" then clears[#clears + 1] = now end
                end
            end
            ::skip::
        end
        return { seq = seq, decides = decides, clears = clears,
                 t0 = t0 or 0, t1 = now, k2 = k2, spans = spans or {} }
    end

    local function report(p)
        local s = state_of(p)
        local lane_end = s.k2 or s.t1
        -- silences = inter-decide gaps over SILENCE_S that START inside lane phase
        local sil, tot_sil, tot_lane = {}, 0.0, math.max(0.01, lane_end - s.t0)
        for i = 2, #s.decides do
            local a, b = s.decides[i - 1], s.decides[i]
            if a < lane_end and b - a > SILENCE_S then
                local hi = math.min(b, lane_end)
                sil[#sil + 1] = { a = a, b = hi, d = hi - a }
                tot_sil = tot_sil + (hi - a)
            end
        end
        -- THE SPLIT THAT MATTERS: is this silence inside a lane-phase HOLE (a mid-service gap over
        -- HOLE_S) or outside one? Comparing the two is the whole point - an opener that fills
        -- silence everywhere explains nothing about holes specifically. Rule 7: always quote the
        -- outside rate beside the inside one.
        local holes, prev_c = {}, s.t0
        for _, c in ipairs(s.clears) do
            if prev_c < lane_end then
                local hi = math.min(c, lane_end)
                if hi - prev_c > 90.0 then holes[#holes + 1] = { a = prev_c, b = hi } end
            end
            prev_c = c
        end
        if prev_c < lane_end and lane_end - prev_c > 90.0 then
            holes[#holes + 1] = { a = prev_c, b = lane_end, censored = true }
        end
        local hole_s = 0.0
        for _, h in ipairs(holes) do hole_s = hole_s + (h.b - h.a) end
        -- v0.1.367 FIX: was classify-by-OVERLAP then credit the FULL duration, so any silence
        -- straddling a hole boundary billed all of its seconds to in-hole. Measured cost: g370
        -- inflated by 21.40s, which flipped ALL SILENCE from 1.17x ENRICHED to 0.87x DEPLETED;
        -- 25 of 26 hole-bearing logs affected, 47 windows, 419.2s total, and six logs printed an
        -- in/min above the physical ceiling of 60 s/min. Now split the actual overlapped seconds.
        -- ponytail: holes are disjoint gaps between consecutive clears, so no double-count.
        for _, w in ipairs(sil) do
            w.in_s = 0.0
            for _, h in ipairs(holes) do
                local lo, hi = math.max(w.a, h.a), math.min(w.b, h.b)
                if hi > lo then w.in_s = w.in_s + (hi - lo) end
            end
            w.in_hole = w.in_s > 0
        end

        -- attribute each silence to the last NON-POLLER event at or before its start, and record
        -- what filled it
        local by, unattr, filler = {}, 0.0, {}
        local by_in, by_out, sil_in, sil_out = {}, {}, 0.0, 0.0
        for _, w in ipairs(sil) do
            local opener, inside = nil, {}
            for _, e in ipairs(s.seq) do
                if e.t <= w.a + 0.05 and not POLLER[e.ev] and e.ev ~= "farm" then
                    opener = e.ev .. (e.src and (" " .. tostring(e.src)) or "")
                elseif e.t > w.a and e.t < w.b then
                    inside[e.ev] = (inside[e.ev] or 0) + 1
                    if not POLLER[e.ev] and e.ev ~= "farm" then
                        filler[e.ev] = (filler[e.ev] or 0) + 1
                    end
                end
            end
            local only_pollers = true
            for k in pairs(inside) do if not POLLER[k] then only_pollers = false break end end
            local key = opener and (opener .. (only_pollers and "  [poller-only]" or "")) or nil
            if key then
                by[key] = (by[key] or 0) + w.d
                -- v0.1.367: split at the boundary instead of billing the whole window one way.
                local din = math.min(w.in_s or 0, w.d)
                local dout = w.d - din
                if din > 0 then by_in[key] = (by_in[key] or 0) + din; sil_in = sil_in + din end
                if dout > 0 then by_out[key] = (by_out[key] or 0) + dout; sil_out = sil_out + dout end
            else unattr = unattr + w.d end
            w.only_pollers = only_pollers
        end
        return s, sil, by, unattr, tot_sil, tot_lane, filler,
               { holes = holes, hole_s = hole_s, by_in = by_in, by_out = by_out,
                 sil_in = sil_in, sil_out = sil_out, lane_end = lane_end }
    end

    if #paths > 1 then
        print(string.format("--- state report --- CORPUS, %d logs. Silence = an inter-decide gap > %.0fs starting in lane phase.", #paths, SILENCE_S))
        print(string.format("%-32s %-7s %-7s %-7s %-7s %-8s %s", "log", "lane_s", "sil_s", "sil%", "n_sil", "longest", "poller-only n / s"))
        local A_share, A_pon = {}, 0.0
        local ENR, NHOLE = {}, 0          -- opener -> list of per-log enrichment ratios
        for _, p in ipairs(paths) do
            local _, sil, _, _, tot_sil, tot_lane, _, H = report(p)
            local longest, pon, pos = 0, 0, 0.0
            for _, w in ipairs(sil) do
                if w.d > longest then longest = w.d end
                if w.only_pollers then pon = pon + 1; pos = pos + w.d end
            end
            A_share[#A_share + 1] = tot_sil / tot_lane; A_pon = A_pon + pos
            print(string.format("%-32s %-7.0f %-7.0f %-7.1f %-7d %-8.1f %d / %.0fs",
                (p:match("([^/\\]+)$") or p):sub(1, 32), tot_lane, tot_sil,
                tot_sil / tot_lane * 100, #sil, longest, pon, pos))
            -- per-log opener enrichment, only for logs that HAVE a hole to compare against
            if H.hole_s > 0 then
                NHOLE = NHOLE + 1
                local out_s = math.max(0.01, tot_lane - H.hole_s)
                local seen = {}
                for k in pairs(H.by_in) do seen[k] = true end
                for k in pairs(H.by_out) do seen[k] = true end
                for k in pairs(seen) do
                    local ri = (H.by_in[k] or 0) / (H.hole_s / 60)
                    local ro = (H.by_out[k] or 0) / (out_s / 60)
                    ENR[k] = ENR[k] or {}
                    ENR[k][#ENR[k] + 1] = { ri = ri, ro = ro }
                end
            end
        end
        table.sort(A_share)
        print("")
        print(string.format("CORPUS: median %.1f%% of lane phase sits inside a decide-silence over %.0fs.",
            A_share[math.ceil(#A_share / 2)] * 100, SILENCE_S))
        print(string.format("        %.0fs of that is POLLER-ONLY silence: the brain emitted nothing but timers.", A_pon))
        print("")

        -- ---- THE DECIDING TEST: does an opener systematically fill (or vacate) holes? ----
        -- Per log, per opener, compare seconds-of-silence per lane-minute INSIDE the holes against
        -- the SAME log's rate outside them, then sign-test the direction across logs. Paired
        -- within log, so game length, lineup and operator all cancel - the confounds that killed
        -- the n=4 duration and Keen-L2 contrasts. A raw corpus total would not do this.
        local function binom_p(k, n)      -- two-sided exact sign test, p=0.5
            if n == 0 then return 1.0 end
            local function C(a, b)
                local r = 1.0
                for i = 1, b do r = r * (a - b + i) / i end
                return r
            end
            local lo = math.min(k, n - k)
            local s = 0.0
            for i = 0, lo do s = s + C(n, i) end
            local p = 2 * s / 2 ^ n
            return p > 1 and 1 or p
        end
        local rows = {}
        for k, list in pairs(ENR) do
            local up, dn, present = 0, 0, 0
            local ratios = {}
            for _, e in ipairs(list) do
                if e.ri > 0 or e.ro > 0 then
                    present = present + 1
                    if e.ri > e.ro then up = up + 1 elseif e.ri < e.ro then dn = dn + 1 end
                    if e.ro > 0.01 then ratios[#ratios + 1] = e.ri / e.ro end
                end
            end
            if present >= 4 then
                table.sort(ratios)
                rows[#rows + 1] = { k = k, up = up, dn = dn, n = present,
                                    med = #ratios > 0 and ratios[math.ceil(#ratios / 2)] or nil,
                                    p = binom_p(math.min(up, dn), up + dn) }
            end
        end
        table.sort(rows, function(x, y)
            if x.p ~= y.p then return x.p < y.p end
            return x.k < y.k
        end)
        print(string.format("OPENER ENRICHMENT INSIDE LANE HOLES, paired within log, %d logs have a hole:", NHOLE))
        print(string.format("    %-34s %5s %5s %5s %9s %9s", "opener", "logs", "up", "down", "med x", "sign p"))
        for _, r in ipairs(rows) do
            print(string.format("    %-34s %5d %5d %5d %9s %9.4f", r.k:sub(1, 34), r.n, r.up, r.dn,
                r.med and string.format("%.2f", r.med) or "-", r.p))
        end
        print("    up = logs where this opener fills MORE silence per lane-minute inside the hole than")
        print("    outside it; down = fewer. `med x` is the median ratio over logs where both are")
        print("    non-zero. Openers appearing in under 4 logs are omitted - too few to sign-test.")
        print("    READ THE DIRECTION AND THE n, NOT THE p ALONE: with this many openers tested, a")
        print("    single p under 0.05 is expected by chance. A claim needs a mechanism as well.")
        os.exit(0)
    end

    local s, sil, by, unattr, tot_sil, tot_lane, filler, H = report(path)
    print(string.format("--- state report --- %s", (path:match("([^/\\]+)$") or path)))
    print(string.format("    lane phase %.0fs (t %.1f .. %.1f%s)", tot_lane, s.t0,
        s.k2 or s.t1, s.k2 and string.format(", Keen L2 at %.1f", s.k2) or ", Keen L2 never reached"))
    print(string.format("    decides %d; silences over %.0fs: %d, totalling %.0fs = %.1f%% of lane phase",
        #s.decides, SILENCE_S, #sil, tot_sil, tot_sil / tot_lane * 100))
    print("")
    print("WHAT OPENED EACH SILENCE (the last non-poller event at or before it began):")
    local ranked = {}
    for k, v in pairs(by) do ranked[#ranked + 1] = { k = k, v = v } end
    table.sort(ranked, function(x, y) if x.v ~= y.v then return x.v > y.v end return x.k < y.k end)
    for _, r in ipairs(ranked) do
        print(string.format("    %-46s %6.0fs  %4.1f%% of silence", r.k, r.v, r.v / math.max(0.01, tot_sil) * 100))
    end
    if unattr > 0 then
        print(string.format("    %-46s %6.0fs  %4.1f%%  <<< NO opener in the log at all",
            "UNATTRIBUTED", unattr, unattr / math.max(0.01, tot_sil) * 100))
    end
    print("")
    print(string.format("    ATTRIBUTED %.1f%%   UNATTRIBUTED %.1f%%",
        (tot_sil - unattr) / math.max(0.01, tot_sil) * 100, unattr / math.max(0.01, tot_sil) * 100))
    print("    The acceptance question for this instrument: if UNATTRIBUTED is small the silences are")
    print("    already explained by the shipped format. If it is large, the cheap next step is a")
    print("    LOG-ONLY change - emit State.fsm on the 2.0s `wavescan SCAN` row - not a behavioural one.")
    print("")
    if H.hole_s > 0 then
        local out_s = math.max(0.01, tot_lane - H.hole_s)
        print(string.format("INSIDE vs OUTSIDE the %d lane-phase hole(s) over 90s (%.0fs in / %.0fs out).",
            #H.holes, H.hole_s, out_s))
        print("Rates are seconds of silence per lane-minute, so the two windows are comparable:")
        print(string.format("    %-40s %10s %10s %8s", "opener", "in/min", "out/min", "enrich"))
        local keys, seen = {}, {}
        for k in pairs(H.by_in) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
        for k in pairs(H.by_out) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
        -- the name tie-break is NOT optional: keys arrive from pairs(), so rows with equal in-hole
        -- seconds (very common at 0.0) would otherwise print in a per-process-random order. This
        -- file has shipped that exact bug before, in the --farm-report argmax.
        table.sort(keys, function(x, y)
            local a, b = H.by_in[x] or 0, H.by_in[y] or 0
            if a ~= b then return a > b end
            return x < y
        end)
        for _, k in ipairs(keys) do
            local ri = (H.by_in[k] or 0) / (H.hole_s / 60)
            local ro = (H.by_out[k] or 0) / (out_s / 60)
            print(string.format("    %-40s %10.1f %10.1f %8s", k:sub(1, 40), ri, ro,
                ro > 0.01 and string.format("%.2fx", ri / ro) or (ri > 0 and "inf" or "-")))
        end
        print(string.format("    %-40s %10.1f %10.1f", "ALL SILENCE", H.sil_in / (H.hole_s / 60), H.sil_out / (out_s / 60)))
        print("    ENRICHMENT is the number to read, never the raw seconds: the largest bucket inside a")
        print("    hole is usually just the largest bucket everywhere. Anything at or below ~1.0x is")
        print("    DEPLETED inside holes and cannot be what fills them.")
        print("")
    else
        print("No lane-phase mid-service gap over 90s in this log, so there is no inside/outside split.")
        print("")
    end
    print("THE LONGEST SILENCES, and what ran inside them:")
    local byd = {}
    for _, w in ipairs(sil) do byd[#byd + 1] = w end
    table.sort(byd, function(x, y) return x.d > y.d end)
    for i = 1, math.min(6, #byd) do
        local w = byd[i]
        local inside = {}
        for _, e in ipairs(s.seq) do
            if e.t > w.a and e.t < w.b then inside[e.ev] = (inside[e.ev] or 0) + 1 end
        end
        local parts = {}
        for k, v in pairs(inside) do parts[#parts + 1] = { k = k, v = v } end
        table.sort(parts, function(x, y) if x.v ~= y.v then return x.v > y.v end return x.k < y.k end)
        local str = {}
        for j = 1, math.min(8, #parts) do str[#str + 1] = parts[j].k .. " " .. parts[j].v end
        print(string.format("    t=%7.1f .. %7.1f  %5.1fs  %s%s", w.a, w.b, w.d,
            w.only_pollers and "[POLLER-ONLY] " or "", table.concat(str, ", ")))
    end
    os.exit(0)
elseif mode ~= "fog_report" and mode ~= "stuck_report" and mode ~= "crash_report" and mode ~= "mana_report" and mode ~= "fog_shadow" then   -- v0.1.353/v0.1.362/v0.1.383/v0.1.409: fog_report, stuck_report, crash_report and fog_shadow are handled in their own blocks at the end of the file, so the timeline fallback must not also fire for them
    -- timeline mode. v6.15.2 low: sort kv keys deterministically per-line
    -- so diff-tooling output is stable between runs.
    for i = 1, #events do
        local e = events[i]
        local s_t = e.kv.t or e.kv._t or "-"
        local keys = {}
        for k in pairs(e.kv) do
            if k ~= "t" and k ~= "_t" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        local parts = {}
        for j = 1, #keys do
            parts[#parts + 1] = keys[j] .. "=" .. tostring(e.kv[keys[j]])
        end
        print(string.format("[%s] %s.%-25s %s", s_t, e.hero, e.event,
            table.concat(parts, " ")))
    end
end

-- v0.1.353: appended as its own top-level block rather than spliced into the mode
-- if-chain above. The chain simply matches no arm when mode == "fog_report", so this
-- is equivalent and does not depend on that 1300-line chain staying shaped as it is.
if mode == "fog_report" then
    -- v0.1.353 (TINKER_FOG_CLOCK_DESIGN.md): score the fog-clock probe offline.
    -- Reads RAW lines rather than the kv event table because the probe is emitted through
    -- logline() as plain text. The counterfactual is deliberately NOT a re-implementation of
    -- FogProximityRisk's curve: a second copy of that model here could drift from the lib and
    -- would then be a new source of truth to debug. The decisive question is binary and exact -
    -- how many sightings count at FULL confidence today but would be DROPPED after the fix,
    -- while close enough to matter.
    local age_cap, fresh_s, risk_radius = 5.0, 1.5, 1400
    if opt_fog_recalc then
        local a_s, f_s = opt_fog_recalc:match("^([%d%.]+),([%d%.]+)$")
        if a_s and f_s then
            age_cap, fresh_s = tonumber(a_s), tonumber(f_s)
        else
            io.stderr:write("bad --fog-recalc, expected AGE_CAP,FRESH_S\n")
            os.exit(2)
        end
    end
    local ff = io.open(path, "r")
    if not ff then io.stderr:write("cannot open " .. path .. "\n"); os.exit(2) end
    local offs, reads, nils, flips, gank_flips, in_cap, out_cap = {}, 0, 0, 0, 0, 0, 0
    local pregame_skipped = 0
    local by_name = {}
    for ln in ff:lines() do
        if not ln:find("Tinker brain v", 1, true) then      -- the banner quotes its own tokens
            -- PREGAME OUTLIER: GetDOTATime reads ~0 through the horn phase while the engine
            -- clock already runs, so a probe at t~0 reports a SMALLER offset than steady state
            -- (g353: 124.3 at t=0.0, then 149.4 flat all game). Including it reported
            -- "UNSTABLE, investigate" for a perfectly constant offset.
            local pt, off = ln:match("fog_probe t=([%d%.]+) .-off=([%-%d%.]+)")
            if off and tonumber(pt) >= 10 then offs[#offs + 1] = tonumber(off)
            elseif off then pregame_skipped = pregame_skipped + 1 end
            local raw, areal, d, nm = ln:match("fog_hero raw=(%S+) age_now=%S+ age_real=(%S+) d=(%-?%d+) name=(%S+)")
            if raw then
                reads = reads + 1
                by_name[nm] = by_name[nm] or { n = 0, nil_n = 0 }
                by_name[nm].n = by_name[nm].n + 1
                if raw == "nil" then
                    nils = nils + 1
                    by_name[nm].nil_n = by_name[nm].nil_n + 1
                else
                    -- v0.1.409 decoupled age_real from raw: a raw-numeric line can now carry
                    -- age_real=nil, so guard before arithmetic; a nil age_real is excluded.
                    local a, dist = tonumber(areal), tonumber(d)
                    if a then
                        if a <= age_cap then in_cap = in_cap + 1 else out_cap = out_cap + 1 end
                        -- d < 0 means the probe could not read the hero origin (origin() nil at
                        -- teardown). Distance is UNKNOWN, so it still counts as a read but must not
                        -- be scored as a flip: we cannot claim it was inside RISK_RADIUS.
                        if dist >= 0 and dist <= risk_radius then
                            if a > age_cap then flips = flips + 1 end
                            if a > fresh_s then gank_flips = gank_flips + 1 end
                        end
                    end
                end
            end
        end
    end
    ff:close()
    local lo, hi, sum = math.huge, -math.huge, 0
    for _, o in ipairs(offs) do lo, hi, sum = math.min(lo, o), math.max(hi, o), sum + o end
    print(string.format("--- fog report --- %d probes, %d fogged reads", #offs, reads))
    if #offs > 0 then
        local note = "  (UNSTABLE - not a fixed pregame offset, investigate)"
        if (hi - lo) < 1.0 then note = "  (STABLE - a constant offset is the clock bug)" end
        print(string.format("clock offset: mean %.1f  min %.1f  max %.1f  spread %.1f%s%s",
            sum / #offs, lo, hi, hi - lo, note,
            pregame_skipped > 0 and string.format("  [%d pregame probe(s) at t<10 excluded]", pregame_skipped) or ""))
    else
        print("no fog_probe lines: either the build predates v0.1.353 or no enemy was ever fogged")
    end
    local nil_note = ""
    if reads > 0 and nils == reads then
        nil_note = "  *** ALWAYS NIL: the clock fix is a NO-OP, stop here ***"
    end
    print(string.format("raw GetLastVisibleTime nil: %d/%d (%.0f pct)%s", nils, reads,
        reads > 0 and (nils / reads * 100) or 0, nil_note))
    print(string.format("real fog age vs FOG_AGE_CAP %.1f: %d inside, %d outside",
        age_cap, in_cap, out_cap))
    print(string.format("FLIP COUNT (inside RISK_RADIUS %d and past the cap): %d", risk_radius, flips))
    print(string.format("  gank-count flips (past FOG_FRESH_S %.1f): %d", fresh_s, gank_flips))
    print("  a flip = scored full-confidence today, dropped entirely after the fix")
    if reads > 0 and flips == 0 then
        print("  ZERO FLIPS: the defect is real in code but changes no decision - close the arc")
    end
    local names = {}
    for k in pairs(by_name) do names[#names + 1] = k end
    table.sort(names)
    if #names > 0 then
        print("per-hero fogged reads (nil share):")
        for _, k in ipairs(names) do
            print(string.format("    %-32s %3d reads, %3d nil", k, by_name[k].n, by_name[k].nil_n))
        end
    end
end


-- v0.1.362: appended as its own top-level block, following the fog_report precedent above -
-- the mode chain simply matches no arm for "stuck_report", so this does not depend on the
-- shape of that 1300-line chain.
if mode == "stuck_report" then
    -- THE UNSTICK LEDGER (Tinker/TINKER_UNSTICK_LOOP_FINDINGS.md). `STUCK -> teleport unstick`
    -- fired 10 times in 589s of g366, costing ~14% of brain-active time in fountain round trips,
    -- and NOTHING in this file read the line: the whole class was hand-grepped. v0.1.362 added
    -- fsm/tgt/ord/osrc/oage/dord to it, so the two shapes can finally be told apart:
    --   dord ~ 0   he ARRIVED exactly where he was ordered and stopped. The watchdog is right
    --              about no-progress and WRONG about intent. Fix belongs at the producer (osrc).
    --   dord ~ d   he never got there. A genuine block, and the teleport is doing its job.
    -- They want OPPOSITE fixes, which is why the split is the headline and the raw count is not.
    local stucks, unsticks, prearm, defer = {}, {}, {}, {}
    local now_t = 0
    for _, e in ipairs(events) do
        local ts = tonumber(e.kv.t); if ts then now_t = ts end
        if e.event == "STUCK" then
            stucks[#stucks + 1] = { t = now_t, d = tonumber(e.kv.d), dord = tonumber(e.kv.dord),
                                    fsm = e.kv.fsm, osrc = e.kv.osrc, oage = tonumber(e.kv.oage),
                                    raw = e.raw }
        elseif e.event == "prearm_w2" then prearm[#prearm + 1] = now_t
        elseif e.event == "channel_defer" then defer[#defer + 1] = { t = now_t, th = e.kv.threat }
        elseif e.event == "keen_home" and (e.raw or ""):find("purpose=unstick", 1, true) then
            unsticks[#unsticks + 1] = now_t
        end
    end
    local span = now_t > 0 and now_t or 1
    print(string.format("--- stuck report --- %d STUCK over %.0fs (%.2f/min)", #stucks, span, #stucks / (span / 60)))
    if #stucks == 0 then
        print("    no STUCK events. On a Zeus-free lineup that is the NORMAL state: the corpus")
        print("    base rate is 0.000 to 0.237/min on 27 of 29 logs, so zero here is not evidence")
        print("    that anything was fixed. See TINKER_UNSTICK_LOOP_FINDINGS.md.")
        os.exit(0)
    end
    -- pre-v0.1.362 logs carry only `d=`. Absence of dord is NOT dord=0, and saying so is the
    -- whole lesson of the DEATHS gate that read UNKNOWN as zero for three builds.
    local instrumented = 0
    for _, s in ipairs(stucks) do if s.dord then instrumented = instrumented + 1 end end
    if instrumented == 0 then
        print("    THIS LOG PREDATES v0.1.362: no dord=/osrc= on the STUCK line, so the")
        print("    arrived-vs-blocked split is UNKNOWN, not zero. Only the census below is valid.")
    elseif instrumented < #stucks then
        print(string.format("    %d of %d carry dord= (mixed-build log)", instrumented, #stucks))
    end
    print("")
    print("    t        fsm     d       dord    osrc            oage   verdict")
    local arrived, blocked, partial = 0, 0, 0
    for _, s in ipairs(stucks) do
        local v = "UNKNOWN(pre-.362)"
        if s.dord and s.d then
            -- 5u is a hair over the sub-unit arrivals seen in g366 (0.3 to 0.6) and far under the
            -- smallest genuine miss (259u). Nothing in the corpus lands in between, so the bar is
            -- not doing fine discrimination and is not tuned to a threshold.
            if s.dord <= 5 then v = "ARRIVED-AND-STOPPED"; arrived = arrived + 1
            elseif s.dord >= s.d * 0.9 then v = "GENUINE-BLOCK"; blocked = blocked + 1
            else v = "PARTIAL"; partial = partial + 1 end
        end
        print(string.format("    %-8.1f %-7s %-7.0f %-7s %-15s %-6s %s", s.t, s.fsm or "?",
            s.d or 0, s.dord and string.format("%.1f", s.dord) or "-", s.osrc or "-",
            s.oage and string.format("%.1f", s.oage) or "-", v))
    end
    if instrumented > 0 then
        print("")
        print(string.format("SPLIT: arrived-and-stopped %d | genuine block %d | partial %d",
            arrived, blocked, partial))
        print("    arrived-and-stopped means the PRODUCER parked him off the stand, so the fix")
        print("    belongs at osrc, NOT in the watchdog. A genuine block is the watchdog working.")
        local by = {}
        for _, s in ipairs(stucks) do
            if s.osrc then by[s.osrc] = (by[s.osrc] or 0) + 1 end
        end
        local arr = {}
        for k, v in pairs(by) do arr[#arr + 1] = { k, v } end
        table.sort(arr, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
        if #arr > 0 then
            print("    producer census (osrc):")
            for _, kv in ipairs(arr) do print(string.format("        %-20s %d", kv[1], kv[2])) end
        end
    end
    -- PRECEDENCE. In g366 8 of 8 MOVE-leg STUCKs were preceded by prearm_w2 and 6 of 8 by a
    -- channel_defer, while prearm_w2 itself is FLAT across the corpus (0 to 15) - the denominator
    -- did not move, the conversion did. That ratio is the finding, so it is computed, not implied.
    local pre_hit, def_hit, def_threat = 0, 0, {}
    for _, s in ipairs(stucks) do
        for _, pt in ipairs(prearm) do if pt <= s.t and s.t - pt <= 30 then pre_hit = pre_hit + 1; break end end
        for _, dv in ipairs(defer) do
            if dv.t <= s.t and s.t - dv.t <= 30 then
                def_hit = def_hit + 1
                if dv.th then def_threat[dv.th] = (def_threat[dv.th] or 0) + 1 end
                break
            end
        end
    end
    print("")
    print(string.format("PRECEDENCE (within 30s before each STUCK): prearm_w2 %d/%d | channel_defer %d/%d",
        pre_hit, #stucks, def_hit, #stucks))
    print(string.format("    prearm_w2 total in log: %d (corpus range 0 to 15, essentially FLAT -", #prearm))
    print("    so a high conversion here is the signal, never the raw prearm count)")
    if next(def_threat) then
        local ts = {}
        for k, v in pairs(def_threat) do ts[#ts + 1] = { k, v } end
        table.sort(ts, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
        io.write("    channel threat:")
        for _, kv in ipairs(ts) do io.write(string.format(" %s(%d)", kv[1]:gsub("^npc_dota_hero_", ""), kv[2])) end
        print("")
        print("    THE MATCHUP IS THE TRIGGER: the only 2 corpus logs where zuus is the SOLE channel")
        print("    threat (g328 0.523/min, g366 1.019/min) are the only 2 with an elevated rate, 33")
        print("    builds apart. A non-zuus game cannot measure any fix to this class.")
    end
    print("")
    print(string.format("COST: %d keen_home purpose=unstick round trip(s).", #unsticks))
    print("    Cross-check the seconds against --state-report, whose `keen_home FIRED unstick`")
    print("    bucket measures the same trips from the silence side (g366: 128s = 26.5%).")
    os.exit(0)

-- v0.1.391 PARSER NOTE (verified against g385): `wait_end why=` values CONTAIN SPACES. The hero
-- normaliser emits `why=wave closing`, `why=cycle park`, `why=tether wave`, `why=W wait`. A generic
-- (%S+)=(%S+) kv parse SILENTLY TRUNCATES those to wave / cycle / tether / W, which merges distinct
-- causes into one bucket and invents a `wave` bucket that is really `wave closing`. Any mode reading
-- this field must match `why=(.-) dur=`, never a bare (%S+). g385: 23 `wave closing`, 12 `tether`,
-- 11 `suppressed`, 9 `wave`, 5 `W wait`, 2 `window`, 2 `tether wave`.
elseif mode == "mana_report" then
    -- v0.1.391: the ACCEPTANCE READ for the v0.1.386 bottle conversion rung. The hero has logged
    -- every field since v0.1.384 and this tool read NONE of it (0 hits for rearm_nofund and bottle),
    -- so the arc was judged by hand greps - which is exactly how the g382 counts came out
    -- banner-contaminated (17/16 reported, 15/14 real). Events come from the parsed stream, which
    -- cannot see the banner, so these counts are contamination-proof by construction.
    -- why=rearm is the NEW rung and the acceptance signal. why=lowm / why=lowh are PRE-EXISTING and
    -- their RATE MUST NOT MOVE; if it does, the change leaked.
    print("--- mana report --- rearm refusals and Bottle conversion (v0.1.386 acceptance)")
    print("    baselines, per minute: rearm_nofund 6.2 pre-fix (g383), 1.67 (g384), 2.82 (g385)")
    print("")
    for _, p in ipairs(paths) do
        local evs = load_log(p)
        local dur, nf, fsm, mism, above = 0, 0, {}, 0, 0
        local drinks, rearm_t, drink_t = {}, {}, {}
        for _, e in ipairs(evs) do
            local t = tonumber(e.kv and e.kv.t)
            if t and t > dur then dur = t end
            if e.event == "rearm_nofund" then
                nf = nf + 1
                local f = e.kv.fsm or "?"
                fsm[f] = (fsm[f] or 0) + 1
                local raw, eff, need = tonumber(e.kv.raw), tonumber(e.kv.eff), tonumber(e.kv.need)
                if raw and eff and need then
                    if eff >= need and raw < need then mism = mism + 1 end
                    if raw >= 200 then above = above + 1 end
                end
            elseif e.event == "bottle" then
                -- a why-less bottle event is the FOUNTAIN chain-drink branch, which logs
                -- "bottle drink fountain" with no why= and is doctrine, not a rung. Name it, so it
                -- cannot be misread as an unexplained bucket.
                local w = (e.kv and e.kv.why) or "fountain(no-why)"
                drinks[w] = (drinks[w] or 0) + 1
                if w == "rearm" then drink_t[#drink_t + 1] = tonumber(e.kv._t or e.kv.t) or 0 end
            elseif e.event == "rearm" then rearm_t[#rearm_t + 1] = 0 end
        end
        local mins = (dur > 0) and (dur / 60) or 1
        print(string.format("== %-22s  %5.0fs / %.1f min", p:gsub("^.*/", ""), dur, mins))
        print(string.format("   rearm_nofund: %-4d = %.2f/min", nf, nf / mins))
        if nf > 0 then
            local parts = {}
            for k, v in pairs(fsm) do parts[#parts + 1] = string.format("%s %d", k, v) end
            table.sort(parts)
            print("     by fsm: " .. table.concat(parts, "  "))
            print(string.format("     eff>=need but raw<need (THE mismatch): %d (%.0f%%)   raw>=BOTTLE_MANA 200 (no drink could fire pre-fix): %d",
                mism, 100 * mism / nf, above))
        end
        local dk = {}
        for k, v in pairs(drinks) do dk[#dk + 1] = string.format("%s=%d", k, v) end
        table.sort(dk)
        print("   bottle drinks: " .. (#dk > 0 and table.concat(dk, "  ") or "(none)"))
        local nr = drinks.rearm or 0
        if nr > 0 then
            print(string.format("   VERDICT: the new rung FIRED %d time(s). Cross-check the revert trigger by hand:", nr))
            print("            a why=rearm drink must be followed by a rearm, else it burned a charge.")
        else
            print("   VERDICT: why=rearm did NOT fire. Either no qualifying refusal occurred, or the rung is dead.")
            print("            Check rearm_nofund above: a high count with zero why=rearm means DEAD, not quiet.")
        end
        print("")
    end
    print("REMINDER: why=lowm / why=lowh are PRE-EXISTING rungs. Their rate must NOT change.")
    os.exit(0)

elseif mode == "crash_report" then
    -- v0.1.383 ACCEPTANCE INSTRUMENT for the crash-model proximity fix.
    -- THE BAR IS ARITHMETIC, NOT A CALIBRATED THRESHOLD. PredictClash clamps the drift at a
    -- defending tower scored by its projection ALONG drift_dir, and the travel budget is
    -- drift_coeff * |b| * creep_speed * horizon. Tinker passes NO clash opts (there is no
    -- drift_coeff / horizon / creep_speed / tower_weight anywhere in Tinker.lua), so the lib
    -- defaults apply and the ceiling at |b| = 1 is 0.5 * 325 * 6 = 975. ctd is the contact-to-tower
    -- EUCLIDEAN distance and ctd >= along ALWAYS, so a stamp with ctd > 975 named a tower the drift
    -- could not physically reach in the horizon. That share IS the defect rate: it needs no
    -- calibration, no control game, and no baseline year.
    -- IF THOSE CONSTANTS EVER MOVE (a clash opts table in the hero, or new lib defaults), MOVE THEM
    -- HERE IN THE SAME COMMIT - a stale mirror here silently turns the bar into the wrong question,
    -- which is exactly how WAVE_PHASE hid for dozens of builds (see the mirror note above).
    -- BASELINES on the CEILING bar, this tool, takeover windows excised. Quote these, not a raw
    -- grep: a hand grep includes user-takeover play, which is the g347 measurement error.
    --   pre-fix : g374 84.2%  g376 44.4%  g377 55.7%  g379 76.7%  g380 71.4%
    --   post-fix: g381 0.0% (0/30, max ctd 1313)  <- v0.1.383, the first build with the bound
    -- The SECOND number is the one that actually convinced: episodes whose ctd SHRINKS, i.e. the
    -- flag tracking a real approach instead of flickering. Pre-fix 8/59, 1/14, 0/14, 0/8, 1/11
    -- (2-14%); g381 3/4 (75%), each naming ONE consistent tower with ctd falling monotonically.
    -- DO NOT SCORE A FALLING STAMP COUNT AS SUCCESS. The fix necessarily cuts the count, so the
    -- count falling is true by construction. Two things matter, and the second is the risky one:
    -- the unreachable share must go to ZERO, and crash stamps must still EXIST. A game with zero
    -- defend verdicts is RED (the run-76 precedent: a ~415 gold wave ate our T2).
    -- CORRECTION, g381: THE FIRST VERSION OF THIS BAR WAS WRONG AND PRINTED A FALSE FAIL.
    -- It tested ctd > MAXTRAVEL (975), which is the envelope of the OLD rule (`along < travel`).
    -- v0.1.383 ships `along <= travel + rng` AND `perp <= rng`, so the shipped rule can legitimately
    -- name a tower out to sqrt((975+700)^2 + 700^2) = 1815. Judging the new rule against the old
    -- rule's envelope scored a clean g381 (max ctd 1313, i.e. 30/30 inside 1815) as 53.3% FAIL.
    -- That is the same species of error as the "0% off-lane" identity: the bar must be derived from
    -- the rule ACTUALLY RUNNING, not the one it replaced. Both numbers are printed below - CEILING
    -- is the verdict, MAXTRAVEL is kept only to compare against pre-fix logs on their own terms.
    local DRIFT_COEFF, CREEP_SPEED, HORIZON, RNG = 0.5, 325, 6, 700
    local MAXTRAVEL = DRIFT_COEFF * 1.0 * CREEP_SPEED * HORIZON
    local CEILING = math.sqrt((MAXTRAVEL + RNG) ^ 2 + RNG ^ 2)
    local function pctl(t, q)
        if #t == 0 then return 0 end
        return t[math.max(1, math.min(#t, math.ceil(q / 100 * #t)))]
    end
    local function build_of(p)
        local f = io.open(p, "r"); if not f then return "?" end
        for line in f:lines() do
            local v = line:match("Tinker brain (v[%d%.]+)")
            if v then f:close(); return v end
        end
        f:close(); return "NO BANNER"
    end

    print(string.format("--- crash report --- THE BAR: ctd > %.0f = a tower the SHIPPED rule cannot reach", CEILING))
    print(string.format("    ceiling = sqrt((travel %.0f + range %d)^2 + range %d^2), travel = drift_coeff %.2f * creep_speed %d * horizon %d at |b|=1",
        MAXTRAVEL, RNG, RNG, DRIFT_COEFF, CREEP_SPEED, HORIZON))
    print(string.format("    (the pre-v0.1.383 rule had no range extension and no perp bound; its own envelope was %.0f,", MAXTRAVEL))
    print("     reported below as a second line so pre-fix logs can still be read on their own terms)")
    print("")
    for _, p in ipairs(paths) do
        local evs = load_log(p)
        local n_ally, n_enemy, n_none = 0, 0, 0
        local ctds, ctds_ally = {}, {}
        local over, over_ally, legacy_over = 0, 0, 0
        local ctr_odd = 0
        local open, eps = {}, {}
        local dur = 0
        for _, e in ipairs(evs) do
            if e.event == "wavescan" then
                if e.kv.t and not e.kv.ln then dur = math.max(dur, tonumber(e.kv.t) or 0) end
                local ln, crash = e.kv.ln, e.kv.crash
                if ln and crash then
                    if crash == "allyTwr" then n_ally = n_ally + 1
                    elseif crash == "enemyTwr" then n_enemy = n_enemy + 1
                    else n_none = n_none + 1 end
                    local d = tonumber(e.kv.ctd)
                    if crash ~= "-" and d then
                        ctds[#ctds + 1] = d
                        if d > CEILING then over = over + 1 end
                        if d > MAXTRAVEL then legacy_over = legacy_over + 1 end
                        if crash == "allyTwr" then
                            ctds_ally[#ctds_ally + 1] = d
                            if d > CEILING then over_ally = over_ally + 1 end
                        end
                        if (tonumber(e.kv.ctr) or 700) ~= 700 then ctr_odd = ctr_odd + 1 end
                    end
                    -- allyTwr EPISODES. The point is not how many stamps but whether the flag
                    -- TRACKS AN APPROACH: a real crash closes on the tower, so ctd shrinks across
                    -- the episode. Pre-fix it shrank in 2 of 49 episodes over four games, which is
                    -- what refuted the "the model goes blind for the last 700 units" story.
                    if crash == "allyTwr" then
                        local o = open[ln]
                        if not o then o = { first = d, n = 0, lane = ln }; open[ln] = o end
                        o.n, o.last = o.n + 1, d
                    elseif open[ln] then
                        eps[#eps + 1] = open[ln]; open[ln] = nil
                    end
                end
            end
        end
        for _, o in pairs(open) do eps[#eps + 1] = o end
        table.sort(ctds); table.sort(ctds_ally)
        local shrink, scans = 0, {}
        for _, ep in ipairs(eps) do
            if ep.first and ep.last and ep.last < ep.first then shrink = shrink + 1 end
            scans[#scans + 1] = ep.n
        end
        table.sort(scans)
        local n_st = #ctds
        local share = n_st > 0 and 100 * over / n_st or 0

        print(string.format("== %-26s %-9s  %5.0fs   scans allyTwr=%d enemyTwr=%d none=%d",
            p:match("[^/\\]+$"), build_of(p), dur, n_ally, n_enemy, n_none))
        -- v0.1.389 (review, CONFIRMED, bug class 3): this tested n_st, which counts allyTwr AND
        -- enemyTwr, while the rule it enforces is about DEFEND verdicts. Only allyTwr reaches the
        -- defend path (the hero stamps State.crashSeen on allyTwr alone), so a game with zero
        -- defends but plenty of enemyTwr stamps graded PASS. Test the right counter.
        if #ctds_ally == 0 then
            print(string.format("   NO allyTwr stamps at all (%d enemyTwr). RED, not a pass: only", n_enemy))
            print("   allyTwr reaches the defend path, so the defend path could not have fired.")
        else
            print(string.format("   UNREACHABLE (ctd > %.0f): %d/%d = %.1f%%   [allyTwr %d/%d = %.1f%%]   <<< THE BAR",
                CEILING, over, n_st, share, over_ally, #ctds_ally,
                #ctds_ally > 0 and 100 * over_ally / #ctds_ally or 0))
            print(string.format("   beyond the OLD un-extended budget (ctd > %.0f): %d/%d = %.1f%%  (context only, NOT the verdict)",
                MAXTRAVEL, legacy_over, n_st, 100 * legacy_over / n_st))
            print(string.format("   ctd: min=%.0f p25=%.0f p50=%.0f p75=%.0f max=%.0f",
                ctds[1], pctl(ctds, 25), pctl(ctds, 50), pctl(ctds, 75), ctds[#ctds]))
            print(string.format("   allyTwr episodes: %d   median scans=%d   ctd SHRANK across %d of them (a real approach shrinks)",
                #eps, #scans > 0 and pctl(scans, 50) or 0, shrink))
            if ctr_odd > 0 then
                print(string.format("   NOTE: %d stamp(s) carry ctr ~= 700. The bar assumes the tower range the strength", ctr_odd))
                print("         loop and the pick both read; re-derive it before trusting this run.")
            end
            local verdict = (share <= 5) and "PASS" or "FAIL"
            print(string.format("   VERDICT: %s   episodes tracking an approach: %d/%d  (pre-fix 0/8 and 1/11; a real crash SHRINKS)",
                verdict, shrink, #eps))
        end
        print("")
    end
    -- ---- THE FALSE-NEGATIVE SIDE: crashes the model MISSED ------------------------------------
    -- Everything above measures whether a FLAGGED tower was reachable. It cannot see a real crash
    -- the model stayed silent on, and that is the expensive direction: the run-76 regression was a
    -- ~415g wave eating our T2 while the flag read "-". This block is MODEL-INDEPENDENT: it asks
    -- only whether the enemy wave FRONT is physically inside one of OUR tower's range, using
    -- MapData.TOWERS, and then reports what the model said on that same row.
    -- CAVEAT, and it is real: MapData.TOWERS is STATIC, so a destroyed tower still counts and its
    -- ground keeps generating "crash situations" forever. Read this on lane-phase logs (Keen L2 not
    -- reached, towers mostly up) and treat a late-game log with suspicion.
    -- Two bands because the two rulers disagree: the ENGINE reports 700 (ctr=700 on every row and
    -- the model gates on it) while the operator OBSERVED 900 in game (the .310 standing law).
    print("--- MISSED CRASHES (model-independent: enemy front inside OUR tower range, per MapData) ---")
    print("    static tower table, so a DEAD tower still counts: read this on lane-phase logs.")
    print("    the run-76 shape is the UNDEFENDED column: no ally hero AND ally creeps a<=1, i.e.")
    print("    nothing left between the wave and the tower. A wave at our tower WITH our creeps")
    print("    still alive is ordinary lane phase, not an emergency.")
    local MD2 = require("lib.map_data")
    for _, p in ipairs(paths) do
        local evs = load_log(p)
        -- v0.1.389 (review, CONFIRMED): since v0.1.385 the brain stamps State.crashSeen through a
        -- SECOND channel, the tower-threat rule in run_lane_scan, which leaves the wavescan row's
        -- crash field at "-". Every such row was scored a MISS. Count that channel and say so.
        -- Bands also gained 1100 to match the shipped K.TOWER_THREAT_R; 700/900 predate it.
        local tt = 0
        for _, e in ipairs(evs) do if e.event == "tower_threat" then tt = tt + 1 end end
        -- v0.1.387 (adversarial review, CONFIRMED): `team` used to default to 2 with NO not-found
        -- path, so a log missing self_acquired silently measured every enemy wave against the
        -- ENEMY team's towers and invented run-76-shaped emergencies with nothing on screen saying
        -- the read had failed. Verified: strip the self_acquired lines from the Dire log g381 and
        -- the block flips from "18 near, 0 UNDEFENDED" to "42 near, 5 UNDEFENDED" naming Radiant
        -- towers. Say so instead, the way build_of already prints NO BANNER.
        local team = nil
        for _, e in ipairs(evs) do
            if e.event == "self_acquired" then team = tonumber(e.kv.team) or team end
        end
        if not team then
            print(string.format("  %-26s NO self_acquired: team unknown, block SKIPPED (it would measure",
                (p:gsub("^.*/", ""))))
            print("                             enemy waves against the WRONG team's towers and invent emergencies)")
            goto continue_missed
        end
        local mine = {}
        for _, t in ipairs(MD2.TOWERS or {}) do
            if t.team == team and t.pos then mine[#mine + 1] = { x = t.pos[1], y = t.pos[2], name = t.name } end
        end
        local function nearest(px, py)
            local bd, bn = math.huge, nil
            for _, t in ipairs(mine) do
                local dx, dy = t.x - px, t.y - py
                local d = math.sqrt(dx * dx + dy * dy)
                if d < bd then bd, bn = d, t.name end
            end
            return bd, bn
        end
        local sit, hit, miss, miss_alone = { [700]=0,[900]=0,[1100]=0 }, { [700]=0,[900]=0,[1100]=0 },
                                           { [700]=0,[900]=0,[1100]=0 }, { [700]=0,[900]=0,[1100]=0 }
        local worst = nil
        for _, e in ipairs(evs) do
            if e.event == "wavescan" and e.kv.ln and e.kv.est == "n" and e.kv.ef and e.kv.ef ~= "-" then
                local fx, fy = e.kv.ef:match("^(%-?%d+);(%-?%d+)$")
                local cnt = tonumber(e.kv.e) or 0
                if fx and cnt >= 3 then
                    local d, nm = nearest(tonumber(fx), tonumber(fy))
                    local alh = tonumber(e.kv.alH) or 0
                    for _, band in ipairs({ 700, 900, 1100 }) do
                        if d <= band then
                            sit[band] = sit[band] + 1
                            if e.kv.crash == "allyTwr" then hit[band] = hit[band] + 1
                            else
                                miss[band] = miss[band] + 1
                                -- THE RUN-76 SHAPE, and the ally HERO count is not enough to find it.
                                -- A wave sitting at our tower is ordinary lane phase for as long as
                                -- OUR CREEPS are there fighting it: the tower only actually takes
                                -- damage once the ally wave is gone. So the dangerous class is
                                -- ally creeps a<=1 AND no ally hero. Without the a<=1 term this
                                -- proxy over-counts by roughly 5x and would justify a fix that
                                -- makes defend_crash, the most absolute verdict in the scheduler,
                                -- fire through most of the laning phase.
                                local aw = tonumber(e.kv.a) or 0
                                if alh == 0 and aw <= 1 then
                                    miss_alone[band] = miss_alone[band] + 1
                                    if band == 700 and (not worst or cnt > worst.e) then
                                        worst = { e = cnt, hp = tonumber(e.kv.hp) or 0, d = d,
                                                  twr = nm, ln = e.kv.ln, crash = e.kv.crash, a = aw }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        io.write(string.format("  %-26s team=%d  ", p:match("[^/\\]+$"), team))
        for _, band in ipairs({ 700, 900, 1100 }) do
            io.write(string.format("[<=%d: %d near, %d flagged, %d missed, %d UNDEFENDED]  ",
                band, sit[band], hit[band], miss[band], miss_alone[band]))
        end
        print(string.format("      tower_threat stamps this log: %d  (a SECOND crashSeen channel that the", tt))
        print("      crash= field never shows, so the miss counts above are an UPPER BOUND)")
        if worst then
            print(string.format("      worst UNDEFENDED: ln=%s e=%d hp=%d a=%d  %.0fu from %s  crash=%s",
                worst.ln, worst.e, worst.hp, worst.a, worst.d, worst.twr, worst.crash))
        end
        ::continue_missed::
    end
    print("")
    print("REMINDER: a falling stamp COUNT is true by construction once the pick is a proximity")
    print("test, so it is not evidence. Read the unreachable share AND whether defends still fire.")
    os.exit(0)

elseif mode == "fog_shadow" then
    -- --fog-shadow (v0.1.409, TINKER_FOG_TRACKER_DESIGN.md): reads the build-1 shadow riders.
    -- Three sections per log:
    --   RISK PAIRS: every line carrying prisk= AND prisk_sh= (same for crisk); counts of
    --     rows, rows where |live - shadow| > 0.05, DISSOLVED verdicts (live >= 0.42 > shadow)
    --     and NEW-VETO verdicts (live < 0.42 <= shadow), plus the per-side medians. 0.42 is
    --     K.PATH_RISK_MAX and K.FARM_SAFE_RISK; camps also report the 0.34 RISK_HARD split.
    --   GHOST AGES: the age_real distribution from fog_hero (n, p50, p90, max, share > 5s,
    --     share > 8s) - the age_cap sweep material.
    --   TRACKER HEALTH: max vsh, probes with fog > 0 and vsh == 0 (should go to ~0 after the
    --     first fog episode; a large count means the stamp is not firing).
    -- The flip gate (design section 5) reads DISSOLVED >= NEW-VETO pooled over the corpus.
    -- The pattern literals below are extracted as source text by the --fog-shadow contract
    -- describe in run_tests.lua and exercised against emitter-shaped fixtures (pair lines in
    -- both field orders): an edit here that stops matching those shapes fails that block.
    -- A line with only the live field counts as live-only (live present, shadow genuinely
    -- absent), never inferred into a pair: side-producer prisk reaches no log line and
    -- wave/refill picks carry crisk without a shadow BY DESIGN.
    -- Pairing is ORDER-INDEPENDENT: the emitter walks the kv table with pairs() (Tinker.lua
    -- tlog), so prisk_sh can print before prisk on a real line; each field gets its own
    -- single-field match. "prisk=" cannot false-match inside "prisk_sh=" because an
    -- underscore, not "=", follows prisk there (verified:
    -- ("prisk_sh=0.77"):match("prisk=([%d%.]+)") == nil); same for crisk.
    local p_live_pat = "prisk=([%d%.]+)"
    local p_sh_pat   = "prisk_sh=([%d%.]+)"
    local c_live_pat = "crisk=([%d%.]+)"
    local c_sh_pat   = "crisk_sh=([%d%.]+)"
    local age_pat   = "fog_hero raw=%S+ age_now=%S+ age_real=([%d%.]+)"
    local vsh_pat   = "fog_probe .-fog=(%d+).-vsh=(%d+)"
    local THRESH, RISK_HARD = 0.42, 0.34   -- K.PATH_RISK_MAX = K.FARM_SAFE_RISK; camp-selection veto
    local function pctl(t, q)              -- t sorted ascending, q a fraction; guard n == 0
        if #t == 0 then return 0 end
        return t[math.max(1, math.min(#t, math.ceil(q * #t)))]
    end
    local function build_of(p)
        local f = io.open(p, "r"); if not f then return "?" end
        for line in f:lines() do
            local v = line:match("Tinker brain (v[%d%.]+)")
            if v then f:close(); return v end
        end
        f:close(); return "NO BANNER"
    end
    local function split_counts(rows, bar)   -- rows = { {live, shadow}, ... }
        local div, dis, nv = 0, 0, 0
        for _, r in ipairs(rows) do
            if math.abs(r[1] - r[2]) > 0.05 then div = div + 1 end
            if r[1] >= bar and r[2] < bar then dis = dis + 1
            elseif r[1] < bar and r[2] >= bar then nv = nv + 1 end
        end
        return div, dis, nv
    end
    local function medians(rows)
        local lv, sh = {}, {}
        for _, r in ipairs(rows) do lv[#lv + 1] = r[1]; sh[#sh + 1] = r[2] end
        table.sort(lv); table.sort(sh)
        return pctl(lv, 0.5), pctl(sh, 0.5)
    end
    local function print_pairs(label, rows, unpaired, unpaired_note)
        print(string.format("   RISK PAIRS %-18s %d pairs, %d live-only%s", label, #rows, unpaired, unpaired_note))
        if #rows > 0 then
            local div, dis, nv = split_counts(rows, THRESH)
            local ml, ms = medians(rows)
            print(string.format("     diverged >0.05: %d   DISSOLVED: %d   NEW-VETO: %d   median live=%.2f shadow=%.2f",
                div, dis, nv, ml, ms))
        end
    end

    print(string.format("--- fog-shadow report --- build-1 riders; verdict bar %.2f (PATH_RISK_MAX = FARM_SAFE_RISK), camps also split at RISK_HARD %.2f",
        THRESH, RISK_HARD))
    print("    DISSOLVED = live >= bar > shadow (a ghost-priced veto that real ages would lift)")
    print("    NEW-VETO  = live < bar <= shadow (a veto only real ages would raise)")
    print("    NOTE on v0.1.410+ logs (the FLIP): live == shadow is the CONTRACT, so any nonzero")
    print("    diverged/DISSOLVED/NEW-VETO count is a SELF-CHECK FAILURE (revert-grade), not calibration data.")
    print("")
    local corp = { prows = {}, crows = {}, ages = {} }
    for _, p in ipairs(paths) do
        local evs = load_log(p)   -- the shared reader: takeover excision included
        local prows, crows, ages = {}, {}, {}
        local unpair_p, unpair_c = 0, 0
        local probes, vsh_max, fog_nosh = 0, 0, 0
        for _, e in ipairs(evs) do
            local raw = e.raw or ""
            if not raw:find("brain v", 1, true) then   -- every hero's banner quotes its own tokens
                local a, b = raw:match(p_live_pat), raw:match(p_sh_pat)
                if a and b then prows[#prows + 1] = { tonumber(a), tonumber(b) }
                elseif a then unpair_p = unpair_p + 1 end
                local ca, cb = raw:match(c_live_pat), raw:match(c_sh_pat)
                if ca and cb then crows[#crows + 1] = { tonumber(ca), tonumber(cb) }
                elseif ca then unpair_c = unpair_c + 1 end
                local ar = raw:match(age_pat)
                if ar then ages[#ages + 1] = tonumber(ar) end
                local fog, vsh = raw:match(vsh_pat)
                if fog then
                    probes = probes + 1
                    local f, v = tonumber(fog), tonumber(vsh)
                    if v > vsh_max then vsh_max = v end
                    if f > 0 and v == 0 then fog_nosh = fog_nosh + 1 end
                end
            end
        end
        table.sort(ages)
        for _, r in ipairs(prows) do corp.prows[#corp.prows + 1] = r end
        for _, r in ipairs(crows) do corp.crows[#corp.crows + 1] = r end
        for _, a2 in ipairs(ages) do corp.ages[#corp.ages + 1] = a2 end

        local bld = build_of(p)
        local bv = tonumber(bld:match("^v0%.1%.(%d+)") or "")
        print(string.format("== %-26s %s", p:match("[^/\\]+$"), bld))
        -- probes counts only vsh-carrying fog_probe lines, so it is the instrument detector:
        -- a pre-.409 log has fog_probe without vsh= and reads 0 here even with heavy fog.
        if probes == 0 and #prows == 0 and #crows == 0 then
            if bv and bv < 409 then
                print(string.format("   SHADOW: UNKNOWN - build v0.1.%d predates the v0.1.409 shadow riders.", bv))
                print("   The zeros below are a missing instrument, NOT measurements.")
            elseif bld == "NO BANNER" then
                print("   SHADOW: UNKNOWN - no Tinker banner in this input (absence is NOT zero).")
                print("   A hand-SPLIT log cuts the banner off: re-run on the RAW file.")
            end
        end
        print_pairs("(corridor prisk):", prows, unpair_p, "  (live-only should be 0 on a .409 log: mid is the only prisk emitter)")
        print_pairs("(camp crisk):", crows, unpair_c, "  (live-only EXPECTED: wave/refill picks carry no shadow by design)")
        if #crows > 0 then
            local _, dis34, nv34 = split_counts(crows, RISK_HARD)
            print(string.format("     at RISK_HARD %.2f (camp-selection veto): DISSOLVED %d   NEW-VETO %d", RISK_HARD, dis34, nv34))
        end
        local n = #ages
        print(string.format("   GHOST AGES (fog_hero age_real): n=%d%s", n,
            n == 0 and "  (numeric age_real only; never-seen prints nil and stays excluded)" or ""))
        if n > 0 then
            local over5, over8 = 0, 0
            for _, a2 in ipairs(ages) do
                if a2 > 5 then over5 = over5 + 1 end
                if a2 > 8 then over8 = over8 + 1 end
            end
            print(string.format("     p50=%.1f p90=%.1f max=%.1f   share>5s %d/%d (%.0f%%)   share>8s %d/%d (%.0f%%)",
                pctl(ages, 0.5), pctl(ages, 0.9), ages[n], over5, n, 100 * over5 / n, over8, n, 100 * over8 / n))
        end
        if probes > 0 then
            print(string.format("   TRACKER HEALTH: %d probes, max vsh=%d, probes with fog>0 and vsh=0: %d  (a large count = the stamp is not firing)",
                probes, vsh_max, fog_nosh))
        else
            print("   TRACKER HEALTH: no vsh-carrying fog_probe lines in this log")
        end
        print("")
    end
    if #paths > 1 then
        table.sort(corp.ages)
        print(string.format("--- CORPUS (%d logs, pooled) ---", #paths))
        local _, dis, nv = split_counts(corp.prows, THRESH)
        local _, cdis, cnv = split_counts(corp.crows, THRESH)
        print(string.format("   corridor pairs=%d DISSOLVED=%d NEW-VETO=%d   camp pairs=%d DISSOLVED=%d NEW-VETO=%d",
            #corp.prows, dis, nv, #corp.crows, cdis, cnv))
        if #corp.ages > 0 then
            print(string.format("   ghost ages pooled: n=%d p50=%.1f p90=%.1f max=%.1f",
                #corp.ages, pctl(corp.ages, 0.5), pctl(corp.ages, 0.9), corp.ages[#corp.ages]))
        end
        if #corp.prows == 0 then
            print(string.format("   FLIP GATE (design section 5): UNKNOWN - no corridor pairs in the corpus, nothing to gate on"))
        else
            print(string.format("   FLIP GATE (design section 5, corridor pairs at %.2f): DISSOLVED %d %s NEW-VETO %d -> %s",
                THRESH, dis, (dis >= nv) and ">=" or "<", nv,
                (dis >= nv) and "gate 2 of 3 PASSES (gates 1 and 3 are read by hand)"
                             or "gate 2 FAILS - stay in shadow and re-read"))
        end
    end
    os.exit(0)
end
