#!/usr/bin/env lua
-- tools/run_tests.lua - pure-Lua test runner for hero-brain lib helpers.
--
-- Runs unit tests on the lib/ modules that are pure (no game state):
--   - lib/threat_data.lua's SaveCounters / SeverityOf / CategoryOf / etc.
--   - lib/target.lua's NotClone (with stub NPC)
--   - lib/timing.lua's EscapeReadiness (with stub APIs)
--
-- Game-side APIs are stubbed at the top so the libs load without errors.
-- Run with:  lua tools/run_tests.lua

----------------------------------------------------------------------------
-- API STUBS (so the libs can be required without a running game)
----------------------------------------------------------------------------

-- Most lib code reads game globals (Entity, NPC, Ability, etc.). For pure
-- helpers we provide no-op stubs; for predicate-helpers we provide minimal
-- behavior. Tests that need real game state are not runnable here.

NPC = NPC or {}
NPC.IsIllusion       = function() return false end
NPC.IsMeepoClone     = function() return false end
NPC.HasModifier      = function() return false end
NPC.HasState         = function() return false end
NPC.GetItem          = function() return nil end
NPC.GetMana          = function() return 100 end
NPC.GetStatesDuration= function() return 0 end
NPC.IsRunning        = function() return false end
NPC.IsAttacking      = function() return false end
NPC.GetAttackRange   = function() return 550 end
NPC.FindRotationAngle= function() return 0 end

Entity = Entity or {}
Entity.IsNPC         = function() return true end
Entity.IsAlive       = function() return true end
Entity.IsSameTeam    = function(a, b) return false end
Entity.GetIndex      = function(e) return e and e.idx or 0 end
Entity.GetAbsOrigin  = function(e) return e and e.pos or { x = 0, y = 0, z = 0 } end
Entity.GetHealth     = function() return 1000 end
Entity.GetMaxHealth  = function() return 1000 end
Entity.IsEntity      = Entity.IsEntity or function(e) return e ~= nil end
-- v0.5.108.1: do NOT stub a global `Target` here. Target is a PROJECT lib
-- (require("lib.target")), not a framework global -- stubbing it globally is
-- what hid the v0.5.108 missing-require crash. lib/item_saves requires
-- lib.target itself; the test loads the real module (its IsAlive resolves
-- against the Entity stubs above), so a future missing-require regresses LOUD.

Ability = Ability or {}
Ability.IsReady      = function() return false end
Ability.GetCooldown  = function() return 999 end
Ability.GetManaCost  = function() return 0 end
Ability.GetLevel     = function() return 0 end

Hero = Hero or {}
Hero.GetLastVisibleTime = function() return nil end

GlobalVars = GlobalVars or {}
GlobalVars.GetCurTime = function() return 0 end

Enum = Enum or {}
Enum.ModifierState = setmetatable({}, { __index = function(_, k) return k end })
Enum.UnitOrder     = setmetatable({}, { __index = function(_, k) return k end })  -- v0.5.16x Phase B: UO for the escape safe_issue path

-- v0.5.82: Vector stub for lib/farm pure-geometry tests. farm only reads
-- .x / .y and constructs Vector(x, y, z) for aim points; no Vector methods.
Vector = Vector or function(x, y, z) return { x = x, y = y, z = z } end

-- Patch package.path so requires from lib/ resolve.
package.path = "./?.lua;./?/init.lua;" .. package.path

----------------------------------------------------------------------------
-- TEST FRAMEWORK
----------------------------------------------------------------------------

local pass, fail = 0, 0
local fails = {}
local function it(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print("  pass  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name); fails[#fails + 1] = { name = name, err = err }
    end
end
local function describe(group, fn)
    print("[" .. group .. "]")
    fn()
end
local function assert_eq(a, b, msg)
    if a ~= b then error((msg or "expected eq") .. ": got " .. tostring(a)
        .. ", want " .. tostring(b), 2) end
end
local function assert_true(v, msg) if not v then error(msg or "expected true", 2) end end
local function assert_false(v, msg) if v then error(msg or "expected false", 2) end end

----------------------------------------------------------------------------
-- TESTS
----------------------------------------------------------------------------

local TD = require("lib.threat_data")

describe("lib/threat_data - SAVE_KIND data integrity", function()
    it("SAVE_KIND populated", function()
        local n = 0
        for _ in pairs(TD.SAVE_KIND) do n = n + 1 end
        assert_true(n > 10, "fewer than 10 SAVE_KIND entries")
    end)
    it("ESCAPE_ITEM_NAMES derived at load", function()
        assert_true(type(TD.ESCAPE_ITEM_NAMES) == "table", "ESCAPE_ITEM_NAMES not table")
        assert_true(#TD.ESCAPE_ITEM_NAMES > 0, "empty escape list")
    end)
    it("ESCAPE_ITEM_NAMES includes BKB", function()
        local found = false
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            if TD.ESCAPE_ITEM_NAMES[i] == "item_black_king_bar" then found = true; break end
        end
        assert_true(found, "BKB missing from ESCAPE_ITEM_NAMES")
    end)
    it("ESCAPE_ITEM_NAMES includes strong-dispel-only items (Disperser)", function()
        -- dispel_strong supersets dispel_basic, so a strong-dispel item must
        -- still count as an escape item (regression guard for the v0.5.x
        -- dispel_strong vocab split, which moved Disperser off dispel_basic).
        local found = false
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            if TD.ESCAPE_ITEM_NAMES[i] == "item_disperser" then found = true; break end
        end
        assert_true(found, "strong-dispel item dropped out of ESCAPE_ITEM_NAMES")
    end)
    it("ESCAPE_ITEM_NAMES excludes non-item saves", function()
        for i = 1, #TD.ESCAPE_ITEM_NAMES do
            local s = TD.ESCAPE_ITEM_NAMES[i]
            assert_true(s:sub(1, 5) == "item_", "non-item in escape list: " .. s)
        end
    end)
end)

describe("lib/threat_data - SaveCounters", function()
    it("BKB counters Bane Nightmare (magic_immune)", function()
        assert_true(TD.SaveCounters("item_black_king_bar", "modifier_bane_nightmare"))
    end)
    it("Force Staff does NOT counter Doom (no displacement_perp on Doom)", function()
        -- modifier_doom_bringer_doom has counter {invuln, magic_immune, reflect_target}
        assert_false(TD.SaveCounters("item_force_staff", "modifier_doom_bringer_doom"))
    end)
    it("Pike DOES counter Pudge hook (displacement_perp)", function()
        assert_true(TD.SaveCounters("item_hurricane_pike", "modifier_pudge_meat_hook"))
    end)
    it("Cyclone does NOT counter Pudge hook in-flight (v6.14.1 M3 fix)", function()
        -- modifier_pudge_meat_hook should NOT have `invuln` in THREAT_COUNTER.
        assert_false(TD.SaveCounters("item_cyclone", "modifier_pudge_meat_hook"))
    end)
end)

describe("lib/threat_data - SeverityOf / CategoryOf", function()
    it("SeverityOf returns low/medium/high for known threats", function()
        local sev = TD.SeverityOf("modifier_bane_nightmare")
        assert_true(sev == "low" or sev == "medium" or sev == "high",
            "got severity=" .. tostring(sev))
    end)
    it("Axe Call severity is medium post-v6.14.1 M4", function()
        assert_eq(TD.SeverityOf("modifier_axe_berserkers_call"), "medium")
    end)
    it("Pudge hook is high severity (a connecting hook is a lethal pull, not low/sidesteppable for an auto-defending brain)", function()
        -- v0.5.147.x hook cast-poll demo: severity 'low' made the low_severity_high_hp
        -- gate withhold WW (the only owned save) at full HP. THREAT_PROFILE already says
        -- severity='lethal'; align the tier table with it. Matches rattletrap_hookshot.
        assert_eq(TD.SeverityOf("modifier_pudge_meat_hook"), "high")
    end)
    it("Rattletrap hookshot is high severity (lethal pull, matches Pudge hook)", function()
        assert_eq(TD.SeverityOf("modifier_rattletrap_hookshot"), "high")
    end)
    it("Power Cogs trap marker + push are medium severity (not low; keeps the WW/Eul eat-time saves off the low_severity_high_hp gate)", function()
        assert_eq(TD.SeverityOf("modifier_rattletrap_cog_marker"), "medium")
        assert_eq(TD.SeverityOf("modifier_rattletrap_cog_push"), "medium")
    end)
    it("Techies mines + sticky + M.A.D. are all low-severity chip (sticky downranked from medium so the low_severity_high_hp gate withholds saves at full HP)", function()
        assert_eq(TD.SeverityOf("modifier_techies_land_mine_burn"), "low")
        assert_eq(TD.SeverityOf("modifier_techies_sticky_bomb_slow"), "low")
        assert_eq(TD.SeverityOf("modifier_techies_mutually_assured_destruction"), "low")
    end)
    it("Techies Blast Off! is a high-severity leap answered by the airborne/displacement/BKB close_gap chain", function()
        -- Blast Off (techies_suicide) leaps onto Lina and detonates the mine/sticky combo on
        -- landing; arm on the in-flight modifier_techies_suicide_leap (modseen-confirmed on the
        -- caster) like Slark/Huskar. high -> NOT withheld by low_severity_high_hp.
        assert_eq(TD.SeverityOf("modifier_techies_suicide_leap"), "high")
        assert_eq(TD.CategoryOf("modifier_techies_suicide_leap"), "close_gap")
        assert_true(TD.SaveCounters("item_cyclone", "modifier_techies_suicide_leap"), "Eul/WW (invuln/airborne) dodges the leap landing")
        assert_true(TD.SaveCounters("item_blink", "modifier_techies_suicide_leap"), "Blink out of the 400 AoE")
        assert_true(TD.SaveCounters("item_black_king_bar", "modifier_techies_suicide_leap"), "BKB (magical, no spell-immunity pierce) eats it")
    end)
    it("Techies Minefield Sign (Aghs) -> Blink, then BKB, then WW last (the only 3 escapes; zone outlasts cyclone, 1000r field)", function()
        -- 1000-radius "damages moving units" aura. BLINK (1200u) leads -- the only clean full-clear.
        -- Then BKB (immune, walk out). WW LAST: untargetable 2.5s but the 10s minefield OUTLASTS the
        -- cyclone so she lands back in it -- a last resort. NOT Eul (same outlast) and NOT Force/Pike
        -- (600u cannot clear a 1000r field). medium -> not withheld at full HP.
        assert_eq(TD.SeverityOf("modifier_techies_minefield_sign_scepter_aura"), "medium")
        local rs = TD.RECOMMENDED_SAVES["modifier_techies_minefield_sign_scepter_aura"]
        assert_true(rs ~= nil, "Minefield Sign has a RECOMMENDED_SAVES list")
        assert_eq(table.concat(rs, ","), "item_blink,item_black_king_bar,item_wind_waker")
    end)
    it("close_gap backbone puts item_blink 3rd (after the two airborne saves) so leaps/zones get a clean full-exit", function()
        -- v0.5.149: blink bumped ahead of the invis tier + BKB (was 8th). SaveCounters still
        -- filters it out for charges (re-homes) + physical_chase; leaps/lines/zones keep it.
        assert_eq(TD.CATEGORY_CHAINS.close_gap[1], "item_wind_waker")
        assert_eq(TD.CATEGORY_CHAINS.close_gap[2], "item_cyclone")
        assert_eq(TD.CATEGORY_CHAINS.close_gap[3], "item_blink")
    end)
end)

describe("lib/threat_data - ENEMY_BUFF_THREATS", function()
    it("contains expected entries", function()
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_sven_gods_strength"] ~= nil)
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_ursa_enrage"] ~= nil)
        assert_true(TD.ENEMY_BUFF_THREATS["modifier_troll_warlord_battle_trance"] ~= nil)
    end)
end)

local Target = require("lib.target")

describe("lib/target - pure predicates", function()
    it("NotClone is true for nil-safe", function() assert_false(Target.NotClone(nil)) end)
    -- More target.lua tests need richer NPC stubs (per-entity behavior) - defer.
end)

describe("lib/target - cannot-kill predicates (v0.5.152)", function()
    local e = { idx = 1 }

    it("HasUnkillableModifier: shallow grave + false promise; pruned _timer not matched", function()
        NPC.HasModifier = function(_, m) return m == "modifier_dazzle_shallow_grave" end
        assert_true(Target.HasUnkillableModifier(e))
        NPC.HasModifier = function(_, m) return m == "modifier_oracle_false_promise" end
        assert_true(Target.HasUnkillableModifier(e))
        NPC.HasModifier = function(_, m) return m == "modifier_oracle_false_promise_timer" end
        assert_false(Target.HasUnkillableModifier(e))  -- pruned: bare modifier confirmed to land (modseen 2026-06-17)
        NPC.HasModifier = function() return false end
        assert_false(Target.HasUnkillableModifier(e))
    end)

    it("WillReincarnate: WK + Reincarnation leveled + off CD; false otherwise", function()
        local s_name, s_ab, s_lvl, s_rdy = NPC.GetUnitName, NPC.GetAbility, Ability.GetLevel, Ability.IsReady
        NPC.GetUnitName  = function() return "npc_dota_hero_skeleton_king" end
        NPC.GetAbility   = function() return { reinc = true } end
        Ability.GetLevel = function() return 1 end
        Ability.IsReady  = function() return true end
        assert_true(Target.WillReincarnate(e))
        Ability.IsReady  = function() return false end                  -- on CD -> false
        assert_false(Target.WillReincarnate(e))
        Ability.IsReady  = function() return true end
        Ability.GetLevel = function() return 0 end                      -- unleveled -> false
        assert_false(Target.WillReincarnate(e))
        Ability.GetLevel = function() return 1 end
        NPC.GetUnitName  = function() return "npc_dota_hero_sniper" end  -- not WK -> false
        assert_false(Target.WillReincarnate(e))
        NPC.GetUnitName, NPC.GetAbility, Ability.GetLevel, Ability.IsReady = s_name, s_ab, s_lvl, s_rdy
    end)

    it("IsUnkillableNow: true if modifier OR reincarnation, else false", function()
        NPC.HasModifier = function(_, m) return m == "modifier_dazzle_shallow_grave" end
        assert_true(Target.IsUnkillableNow(e))
        NPC.HasModifier = function() return false end
        assert_false(Target.IsUnkillableNow(e))   -- no mod + GetUnitName unstubbed (not WK)
    end)
end)

local Timing = require("lib.timing")

describe("lib/timing - EscapeReadiness", function()
    it("returns 0 for entity without items", function()
        local r = Timing.EscapeReadiness({ idx = 1 }, 2.0)
        assert_eq(r, 0)
    end)
end)

local Farm = require("lib.farm")
local Map  = require("lib.map")
local Lane = require("lib.lane")
local Route = require("lib.lane").Route      -- v0.1.395: absorbed into lane (phase 1)
local Nav = require("lib.map").Nav            -- v0.1.396: absorbed into map (phase 2)
local Schedule = require("lib.lane").Schedule -- v0.1.395: absorbed into lane (phase 1)

describe("lib/farm , pure geometry (v0.5.82)", function()
    local function u(x, y, hp) return { pos = { x = x, y = y, z = 0 }, hp = hp or 100 } end
    local origin = { x = 0, y = 0, z = 0 }

    it("WorthCasting respects min_count", function()
        assert_true(Farm.WorthCasting(3, 3))
        assert_false(Farm.WorthCasting(2, 3))
        assert_true(Farm.WorthCasting(1))
        assert_false(Farm.WorthCasting(0, 1))
    end)

    it("BestLineAim picks the densest direction", function()
        local units = { u(200, 0), u(400, 0), u(600, 0), u(0, 400) }
        local aim, hit = Farm.BestLineAim(origin, units, 1075, 110)
        assert_eq(hit, 3, "expected 3 hits on the +x line")
        assert_true(aim ~= nil and aim.x > aim.y, "aim should point +x")
    end)

    it("BestLineAim tie-break prefers the closer pack (v0.5.81)", function()
        local near = u(300, 0, 100)
        local far  = u(0, 900, 100)
        local aim, hit = Farm.BestLineAim(origin, { far, near }, 1075, 110)
        assert_eq(hit, 1)
        assert_true(aim.x > aim.y, "tie-break should favor the nearer (+x) unit")
    end)

    it("BestPointAim finds the densest cluster center", function()
        local units = { u(0, 0), u(50, 0), u(60, 30), u(1000, 1000) }
        local center, hit = Farm.BestPointAim(units, 250)
        assert_eq(hit, 3, "cluster of 3 within 250")
        assert_true(center ~= nil)
    end)

    it("empty / degenerate inputs are safe", function()
        local aim, h1 = Farm.BestLineAim(origin, {}, 1000, 100)
        assert_true(aim == nil and h1 == 0)
        local c, h2 = Farm.BestPointAim({}, 250)
        assert_true(c == nil and h2 == 0)
    end)
end)

describe("lib/farm -- BestLineAim hero-clip bonus (v0.5.111)", function()
    local function u(x, y, hp) return { pos = { x = x, y = y, z = 0 }, hp = hp or 100 } end
    local origin = { x = 0, y = 0, z = 0 }
    -- Layout A: +x lane = 3 creeps with a hero behind them; +y lane = 5 creeps.
    local CREEPS_A = { u(200, 0), u(400, 0), u(600, 0),
                       u(0, 150), u(0, 300), u(0, 450), u(0, 600), u(0, 750) }
    local HERO_A   = { u(900, 0) }

    it("back-compat: no opts -> raw densest line (+y, 5 creeps)", function()
        local aim, hit = Farm.BestLineAim(origin, CREEPS_A, 1075, 110)
        assert_eq(hit, 5)
        assert_true(aim.y > aim.x, "no-opts pick must ignore the hero")
    end)
    it("weighted: hero-clip line wins when both qualify", function()
        local aim, hit, _, bn = Farm.BestLineAim(origin, CREEPS_A, 1075, 110,
            { bonus_units = HERO_A, bonus_weight = 3, min_hits = 3 })
        assert_eq(hit, 3, "primary hit count stays creeps-only")
        assert_eq(bn, 1, "bonus hits returned 4th")
        assert_true(aim.x > aim.y, "hero-clip (+x) line must win: 3 + 3 > 5")
    end)
    it("equal creeps: hero-clip beats the closer-pack tie-break", function()
        -- two 2-creep lanes; the +y pack is nearer (the v0.5.81 tie-break
        -- alone would pick +y); the hero behind +x must flip the pick.
        local creeps = { u(300, 0), u(500, 0), u(0, 150), u(0, 350) }
        local aim, hit, _, bn = Farm.BestLineAim(origin, creeps, 1075, 110,
            { bonus_units = HERO_A, bonus_weight = 3 })
        assert_eq(hit, 2)
        assert_eq(bn, 1)
        assert_true(aim.x > aim.y, "hero bonus must beat the closer-pack tie-break")
    end)
    it("min_hits protection: under-threshold hero line loses to a qualifying line", function()
        -- +x = 2 creeps + 2 heroes (score 8 but NOT qualified at min 3);
        -- +y = 5 creeps (score 5, qualified) -> +y wins.
        local creeps = { u(200, 0), u(400, 0),
                         u(0, 150), u(0, 300), u(0, 450), u(0, 600), u(0, 750) }
        local heroes = { u(700, 0), u(900, 0) }
        local aim, hit = Farm.BestLineAim(origin, creeps, 1075, 110,
            { bonus_units = heroes, bonus_weight = 3, min_hits = 3 })
        assert_eq(hit, 5)
        assert_true(aim.y > aim.x, "qualified pool must beat unqualified score")
    end)
    it("no qualified line -> best raw fallback (caller gate then rejects)", function()
        local creeps = { u(300, 0), u(500, 0) }
        local aim, hit = Farm.BestLineAim(origin, creeps, 1075, 110,
            { bonus_units = HERO_A, bonus_weight = 3, min_hits = 3 })
        assert_true(aim ~= nil)
        assert_eq(hit, 2, "falls back to the raw best so WorthCasting can reject")
    end)
    it("pure-bonus bearing rejected: a line must hit at least one creep", function()
        local creeps = { u(0, 200), u(0, 400) }
        local hero_far = { u(800, -300) }  -- bearing toward it clips zero creeps
        local aim, hit, _, bn = Farm.BestLineAim(origin, creeps, 1075, 110,
            { bonus_units = hero_far, bonus_weight = 99 })
        assert_eq(hit, 2)
        assert_eq(bn, 0)
        assert_true(aim.y > aim.x, "creep line wins; hero-only bearing is not wave-clear")
    end)
end)

describe("lib/farm -- PairClearClass (Tinker tight-pair 'best distance' model, task B)", function()
    -- disc model: camp = creep disc radius `disc` at d/2 from the cast. half=march_len/2.
    -- clean: d/2+disc <= half (one March clears both). clip: d/2-disc <= half (outer creeps
    -- clip, finish with extra marches + aggro-pull). none: even the nearest creep is outside.
    local OPTS = { march_len = 1800, disc = 200 }   -- half=900 -> clean<=1400, clip<=2200

    it("clean when both full discs fit (d <= 2*(half-disc))", function()
        assert_eq(Farm.PairClearClass(1000, OPTS).class, "clean")
        assert_eq(Farm.PairClearClass(1400, OPTS).class, "clean")   -- boundary: full_margin=0
    end)

    it("clip when the centre is reachable but outer creeps spill out", function()
        assert_eq(Farm.PairClearClass(1500, OPTS).class, "clip")
        assert_eq(Farm.PairClearClass(1800, OPTS).class, "clip")
        assert_eq(Farm.PairClearClass(2200, OPTS).class, "clip")   -- boundary: clip_margin=0
    end)

    it("none when even the nearest creep is outside coverage (d > 2*(half+disc))", function()
        assert_eq(Farm.PairClearClass(2300, OPTS).class, "none")
    end)

    it("returns the full + clip margins (calibration readout)", function()
        local r = Farm.PairClearClass(1500, OPTS)
        assert_true(math.abs(r.full_margin - (-50)) < 1e-6, "full_margin = half-(d/2+disc) = -50")
        assert_true(math.abs(r.clip_margin - 350) < 1e-6, "clip_margin = half-(d/2-disc) = 350")
    end)

    it("a bigger real footprint (march_len) promotes tight pairs from clip to clean", function()
        -- the user's manual d=1854 clear implies the real MARCH_LEN ~1900-2000, not 1800.
        assert_eq(Farm.PairClearClass(1780, { march_len = 1800, disc = 200 }).class, "clip")
        assert_eq(Farm.PairClearClass(1780, { march_len = 2400, disc = 200 }).class, "clean") -- half=1200 -> clean<=2000
    end)

    it("degenerate / nil distance -> none, no crash", function()
        assert_eq(Farm.PairClearClass(0, OPTS).class, "none")
        assert_eq(Farm.PairClearClass(nil, OPTS).class, "none")
    end)
end)

describe("lib/farm -- GreedyPairs (merged-pair matching, #2/#3)", function()
    it("pairs each camp with its nearest free neighbor; lone camp stays single", function()
        local pts = { {x=0,y=0}, {x=300,y=0}, {x=1000,y=0}, {x=1300,y=0}, {x=5000,y=0} }
        local g = Farm.GreedyPairs(pts, 500)
        assert_eq(#g, 3)
        assert_eq(g[1].a, 1); assert_eq(g[1].b, 2)      -- 1<->2 (d=300)
        assert_eq(g[2].a, 3); assert_eq(g[2].b, 4)      -- 3<->4 (d=300)
        assert_eq(g[3].a, 5); assert_eq(g[3].b, nil)    -- 5 too far -> single
    end)
    it("never double-assigns a camp", function()
        local pts = { {x=0,y=0}, {x=300,y=0}, {x=350,y=0} }   -- 1-2 d=300, 2-3 d=50(<min), 1-3 d=350
        local g = Farm.GreedyPairs(pts, 500)
        assert_eq(#g, 2)
        assert_eq(g[1].a, 1); assert_eq(g[1].b, 2)       -- 1 takes its nearest (2)
        assert_eq(g[2].a, 3); assert_eq(g[2].b, nil)     -- 3's only free neighbor is gone -> single
    end)
    it("min_sep drops coincident/too-close pairs", function()
        local g = Farm.GreedyPairs({ {x=0,y=0}, {x=100,y=0} }, 500, 200)
        assert_eq(#g, 2); assert_eq(g[1].b, nil); assert_eq(g[2].b, nil)  -- d=100 < 200 -> two singles
    end)
    it("mutual-nearest: a camp pairs with its TRUE nearest, not whoever grabs it first (anti-orphan)", function()
        -- A(0) B(1000) C(1300): B's nearest is C (300), not A (1000). The old greedy paired A-B (A first)
        -- and orphaned C; mutual-nearest pairs B-C and leaves A single -> stable + symmetric.
        local g = Farm.GreedyPairs({ {x=0,y=0}, {x=1000,y=0}, {x=1300,y=0} }, 1500)
        assert_eq(#g, 2)
        local pair, single
        for _, grp in ipairs(g) do if grp.b then pair = grp else single = grp end end
        assert_eq(pair.a, 2); assert_eq(pair.b, 3)   -- B-C are mutual nearest
        assert_eq(single.a, 1)                        -- A's nearest (B) is taken -> A single
    end)
    it("allow predicate force-pairs a specific over-range pair, else single", function()
        local pts = { {x=0,y=0}, {x=1854,y=0} }                        -- d=1854 > pair_max 1800
        assert_eq(#Farm.GreedyPairs(pts, 1800), 2)                     -- no allow -> two singles
        local g = Farm.GreedyPairs(pts, 1800, 200, function() return true end)
        assert_eq(#g, 1); assert_eq(g[1].a, 1); assert_eq(g[1].b, 2); assert_eq(g[1].d, 1854)  -- whitelisted -> pair
    end)
end)

describe("lib/farm -- WaveAimCenter (ranged-creep coverage)", function()
    it("aims at the along-lane span center, not the melee-weighted centroid", function()
        -- 3 melee near x=400 + 1 ranged trailing at x=0, axis (1,0). mean x = 300;
        -- proj rel mean = {100,120,80,-300}; (lo+hi)/2 = (-300+120)/2 = -90; center.x = 210.
        -- (the count centroid is x=300, melee-biased; the span center 210 covers the ranged.)
        local pts = { {x=400,y=0}, {x=420,y=10}, {x=380,y=-10}, {x=0,y=0} }
        local c = Farm.WaveAimCenter(pts, 1, 0)
        assert_true(math.abs(c.x - 210) < 1, "span center x ~210, got " .. tostring(c.x))
        assert_true(math.abs(c.y - 0) < 1, "lateral stays mean ~0, got " .. tostring(c.y))
    end)
    it("empty -> nil", function()
        assert_true(Farm.WaveAimCenter({}, 1, 0) == nil, "empty -> nil")
    end)
end)

describe("lib/farm -- PathRisk (route-risk sampler for laning)", function()
    -- risk_at: a hot zone around x=1000 (danger corridor) that safe endpoints miss.
    local function risk_at(p) return (math.abs(p.x - 1000) < 250) and 0.9 or 0.0 end
    it("catches danger mid-route that both endpoints miss", function()
        local mx = Farm.PathRisk({ x = 0, y = 0 }, { x = 2000, y = 0 }, risk_at, { step = 100 })
        assert_true(math.abs(mx - 0.9) < 1e-9, "the hot corridor is sampled")
    end)
    it("endpoint-only check would have read safe", function()
        assert_eq(risk_at({ x = 0, y = 0 }), 0); assert_eq(risk_at({ x = 2000, y = 0 }), 0)
    end)
    it("all-safe route -> 0; zero-length -> endpoint risk", function()
        assert_eq((Farm.PathRisk({ x = 0, y = 0 }, { x = 100, y = 0 }, function() return 0 end)), 0)
        assert_true(math.abs(Farm.PathRisk({ x = 1000, y = 0 }, { x = 1000, y = 0 }, risk_at) - 0.9) < 1e-9, "degenerate segment samples the point")
    end)
    it("worst_point is returned alongside the max", function()
        local _, wp = Farm.PathRisk({ x = 0, y = 0 }, { x = 2000, y = 0 }, risk_at, { step = 100 })
        assert_true(risk_at(wp) == 0.9, "worst point is inside the hot zone")
    end)
end)

describe("lib/nav -- SafeDest (lane movement clamp, Piece 0)", function()
    local function safe_x(pt) return pt.x <= 1000 end   -- safe on/left of x=1000 (a 'tower' to the right)
    it("already-safe dest passes through unclamped", function()
        local pt, cl = Nav.SafeDest({ x = 500, y = 0 }, { x = -1, y = 0 }, safe_x)
        assert_eq(pt.x, 500); assert_eq(pt.y, 0); assert_true(not cl, "not clamped")
    end)
    it("unsafe dest clamps back along retreat to the nearest safe step", function()
        local pt, cl = Nav.SafeDest({ x = 1450, y = 0 }, { x = -1, y = 0 }, safe_x)
        assert_true(cl, "clamped")
        assert_true(pt.x <= 1000, "on the safe side")
        assert_true(pt.x >= 950, "nearest safe step (1450-5*100=950), not over-retreated")
    end)
    it("never-safe returns the max-back point, clamped (degraded, caller reports)", function()
        local pt, cl = Nav.SafeDest({ x = 0, y = 0 }, { x = 1, y = 0 },
                                     function() return false end, { step = 100, max_steps = 5 })
        assert_true(cl, "clamped"); assert_eq(pt.x, 500)
    end)
end)

describe("lib/nav -- Ladder (transport eligibility, Piece 0)", function()
    it("far + keen ready -> keen first, walk last", function()
        local r = Nav.Ladder(3000, { keen_ready = true, keen_min_gain = 800 })
        assert_eq(r[1], "keen"); assert_eq(r[#r], "walk")
    end)
    it("far + keen on cd -> rearm rung replaces keen (a safe Rearm resets Keen)", function()
        local r = Nav.Ladder(3000, { keen_ready = false, keen_min_gain = 800 })
        assert_eq(r[1], "rearm")
    end)
    it("already keened this spot -> no keen/rearm rung", function()
        local r = Nav.Ladder(3000, { keened = true, keen_ready = true, keen_min_gain = 800 })
        assert_true(r[1] ~= "keen" and r[1] ~= "rearm", "keen family suppressed")
    end)
    it("short leg -> walking beats spending the keen", function()
        local r = Nav.Ladder(500, { keen_ready = true, keen_min_gain = 800 })
        assert_eq(r[1], "walk")
    end)
    it("blink eligible only inside its band", function()
        local ctx = { keened = true, blink_ready = true, blink_min = 800, blink_max = 1160 }
        assert_eq(Nav.Ladder(1000, ctx)[1], "blink")
        assert_eq(Nav.Ladder(500,  ctx)[1], "walk")
        assert_eq(Nav.Ladder(2000, ctx)[1], "walk")
    end)
    it("empty ctx -> just walk", function()
        local r = Nav.Ladder(0, {})
        assert_eq(#r, 1); assert_eq(r[1], "walk")
    end)
end)

describe("lib/nav -- Stuck (progress supervision)", function()
    it("improving legs never read stuck and rebaseline", function()
        local tr, st = Nav.Stuck(nil, 2000, 10)
        assert_true(not st)
        tr, st = Nav.Stuck(tr, 1500, 12)                    -- real progress -> rebaseline
        assert_true(not st); assert_eq(tr.best_d, 1500)
        tr, st = Nav.Stuck(tr, 900, 20)                     -- still improving, even much later
        assert_true(not st)
    end)
    it("a frozen hero reads stuck after the window", function()
        local tr = select(1, Nav.Stuck(nil, 1000, 10))
        local st
        tr, st = Nav.Stuck(tr, 990, 12); assert_true(not st, "jitter under eps, inside window")
        tr, st = Nav.Stuck(tr, 995, 13.1); assert_true(st, "no eps-progress for >= 3s")
    end)
    it("moving AWAY reads stuck too (regression is not progress)", function()
        local tr = select(1, Nav.Stuck(nil, 1000, 0))
        local st
        tr, st = Nav.Stuck(tr, 1400, 3.5)
        assert_true(st)
    end)
    it("the WALL-CLOCK gap: an untouched track charges time nobody observed", function()
        -- v0.1.355, the shape of the bug this pins. Stuck compares t - best_t; it cannot tell
        -- "the hero stood still for 3.1s" from "nobody called me for 3.1s". Tinker's tick()
        -- returns on is_channeling ABOVE the FSM dispatch, so a Rearm L1 channel (3.09s) is
        -- exactly such a gap, and the first call after it reported stuck -> a LIVE camp got
        -- retired until respawn. This is CORRECT lib behaviour, deliberately pinned: the fix
        -- belongs at the caller, and anyone changing Stuck to time-out differently must see
        -- this test and read TINKER_CHANNEL_WATCHDOG_DESIGN.md first.
        local tr = select(1, Nav.Stuck(nil, 5000, 100.0))
        local st
        tr, st = Nav.Stuck(tr, 5000, 103.1)                 -- one call, 3.1s later, unmoved
        assert_true(st, "a single post-gap call must report stuck on the full elapsed span")
    end)
    it("clearing the track to nil re-baselines, however far the clock has run", function()
        -- The property the v0.1.355 fix rests on: the tick() channel guard sets
        -- State.moveTrack = nil every tick it holds orders, so the next no_progress call
        -- starts a FULL fresh NO_PROGRESS_S window instead of inheriting the channel.
        local _, st = Nav.Stuck(nil, 5000, 103.1)           -- same instant as the case above
        assert_true(not st, "a nil track must never report stuck on its first call")
        local tr = select(1, Nav.Stuck(nil, 5000, 103.1))
        local st2
        tr, st2 = Nav.Stuck(tr, 5000, 105.0)                -- 1.9s of REAL observed stillness
        assert_true(not st2, "under the 3.0s window after the reset, still not stuck")
        tr, st2 = Nav.Stuck(tr, 5000, 106.2)                -- now 3.1s genuinely observed
        assert_true(st2, "a genuinely unreachable stand must STILL trip the watchdog")
    end)
end)

describe("lib/nav -- TreeHideSpot (tree-blink landing)", function()
    local function grid(cx, cy, n)                          -- n trees clustered ~60u apart around (cx,cy)
        local t = {}
        for i = 1, n do t[#t + 1] = { x = cx + (i % 3) * 60, y = cy + math.floor(i / 3) * 60 } end
        return t
    end
    local hero, wave = { x = 0, y = 0 }, { x = 1200, y = 0 }
    it("picks the densest qualifying cluster", function()
        local trees = {}
        for _, p in ipairs(grid(-700, 0, 6)) do trees[#trees + 1] = p end    -- dense, safe side
        for _, p in ipairs(grid(500, -700, 3)) do trees[#trees + 1] = p end  -- sparse
        local s = Nav.TreeHideSpot(trees, hero, wave, { blink_max = 950, min_trees = 4 })
        assert_true(s ~= nil and s.x < -500, "the dense far-side cluster wins")
    end)
    it("rejects clusters out of blink range or too close to the threat", function()
        local far   = grid(-2000, 0, 6)                      -- dense but unreachable
        local close = grid(900, 0, 6)                        -- dense but on top of the wave
        assert_true(Nav.TreeHideSpot(far, hero, wave, { blink_max = 950, min_trees = 4 }) == nil)
        assert_true(Nav.TreeHideSpot(close, hero, wave, { blink_max = 950, min_trees = 4, threat_min = 800 }) == nil)
    end)
    it("nil on no trees / thin cover", function()
        assert_true(Nav.TreeHideSpot({}, hero, wave, {}) == nil)
        assert_true(Nav.TreeHideSpot(grid(-500, 0, 2), hero, wave, { min_trees = 4 }) == nil)
    end)
end)

describe("lib/farm -- StructuralRisk (Note 3 position-based risk)", function()
    local of = { x = -7456, y = -6938 }   -- radiant fountain
    local ef = { x = 7408, y = 6848 }     -- dire fountain
    local opts = { our_fountain = of, enemy_fountain = ef, half_weight = 0.6,       -- matches K.RISK_HALF_WEIGHT
                   zones = { { x = -4797, y = -104, radius = 700, bump = 0.08 },   -- radiant ancient (contested)
                             { x = 4099, y = 63, radius = 700, bump = 0.08 } } }   -- dire ancient (contested)

    it("rises toward the enemy fountain", function()
        local near = Farm.StructuralRisk({ x = -6000, y = -5500 }, opts)   -- deep radiant
        local far  = Farm.StructuralRisk({ x = 5000, y = 4500 }, opts)     -- deep dire
        assert_true(far > near, "enemy-half camp is riskier")
    end)

    it("a contested mid ancient outranks a same-axis safelane camp via the explicit bump", function()
        local safelane = Farm.StructuralRisk({ x = -1512, y = -3458 }, opts)   -- radiant safelane large
        local ancient  = Farm.StructuralRisk({ x = -4797, y = -104 }, opts)    -- radiant ancient (tagged)
        assert_true(ancient > safelane, "the tagged contested ancient is riskier than the safe safelane camp")
    end)

    it("the dire ancient exceeds the hard-risk veto (0.45)", function()
        assert_true(Farm.StructuralRisk({ x = 4099, y = 63 }, opts) >= 0.45, "deep + tagged -> vetoed")
    end)

    it("clamps to [0,1] and is 0 with no fountains", function()
        assert_eq(Farm.StructuralRisk({ x = 0, y = 0 }, {}), 0)
        assert_true(Farm.StructuralRisk(ef, opts) <= 1)
    end)
end)

describe("lib/lane -- aggregate helpers", function()
    local function c(x, y, hp, gold) return { pos = { x = x, y = y }, hp = hp or 100, gold = gold or 40 } end

    it("_centroid averages member positions; nil on empty", function()
        local m = { c(0, 0), c(100, 0), c(0, 300) }
        local ce = Lane._centroid(m)
        assert_true(math.abs(ce.x - 100/3) < 1e-6 and math.abs(ce.y - 100) < 1e-6, "centroid")
        assert_true(Lane._centroid({}) == nil, "empty -> nil")
    end)

    it("_hp / _gold sum members (missing -> 0)", function()
        local m = { c(0,0,100,40), c(0,0,250,55), { pos = {x=0,y=0} } }
        assert_eq(Lane._hp(m), 350)
        assert_eq(Lane._gold(m), 95)
    end)

    it("_strength defaults to summed hp; strength_fn overrides", function()
        local m = { c(0,0,100), c(0,0,200) }
        assert_eq(Lane._strength(m), 300)
        assert_eq(Lane._strength(m, { strength_fn = function(g) return #g end }), 2)
    end)

    it("_front picks the member furthest along push_dir", function()
        local m = { c(0,0), c(500,500), c(1000,1000) }
        local f = Lane._front(m, { x = 1, y = 1 })   -- toward +x+y
        assert_true(math.abs(f.x - 1000) < 1e-6 and math.abs(f.y - 1000) < 1e-6, "furthest +xy")
        local f2 = Lane._front(m, { x = -1, y = -1 })
        assert_true(math.abs(f2.x) < 1e-6 and math.abs(f2.y) < 1e-6, "furthest -xy")
    end)
end)

describe("lib/lane -- _cluster (single-link proximity)", function()
    local function c(x, y) return { pos = { x = x, y = y }, hp = 100, gold = 40 } end

    it("groups near creeps, separates far ones", function()
        local creeps = { c(0,0), c(100,0), c(200,0),    -- chain within 600
                         c(3000,0), c(3100,0) }          -- a second pack
        local cl = Lane._cluster(creeps, 600)
        assert_eq(#cl, 2, "two clusters")
        local sizes = { #cl[1], #cl[2] }
        table.sort(sizes)
        assert_eq(sizes[1], 2); assert_eq(sizes[2], 3)
    end)

    it("single-link is transitive (a chain is one cluster)", function()
        local creeps = { c(0,0), c(500,0), c(1000,0), c(1500,0) }   -- each 500 from the next
        assert_eq(#Lane._cluster(creeps, 600), 1)
    end)

    it("empty input -> no clusters", function()
        assert_eq(#Lane._cluster({}, 600), 0)
    end)
end)

describe("lib/lane -- _assign_lane (mid-diagonal band)", function()
    it("classifies by x-y vs the mid band", function()
        local o = { mid_band = 2500 }
        assert_eq(Lane._assign_lane({ x = 5000, y = 0 }, o), "bot")   -- x-y = 5000 > band
        assert_eq(Lane._assign_lane({ x = 0, y = 5000 }, o), "top")   -- x-y = -5000 < -band
        assert_eq(Lane._assign_lane({ x = 1000, y = 1000 }, o), "mid")-- on the diagonal
        assert_eq(Lane._assign_lane({ x = 0, y = 0 }, o), "mid")
    end)

    it("default band when opts omitted", function()
        assert_eq(Lane._assign_lane({ x = 6000, y = 0 }), "bot")
    end)
end)

describe("lib/lane -- DetectWaves", function()
    local function c(x, y, team, hp, gold) return { pos = {x=x,y=y}, team = team or 3, hp = hp or 100, gold = gold or 40 } end

    it("one bot-lane wave with full granularity", function()
        local creeps = { c(5000,0,3,100,40), c(5100,0,3,200,55), c(5200,0,3,300,38) }
        local waves = Lane.DetectWaves(creeps, { x = -1, y = -1 }, { cluster_radius = 600, mid_band = 2500 })
        assert_eq(#waves, 1)
        local w = waves[1]
        assert_eq(w.lane, "bot"); assert_eq(w.team, 3)
        assert_eq(w.count, 3); assert_eq(w.hp, 600); assert_eq(w.gold, 133)
        assert_eq(w.strength, 600)               -- default = summed hp
        assert_eq(#w.creeps, 3)                  -- members retained (each creep's life/gold)
        assert_true(math.abs(w.front.x - 5000) < 1e-6, "front = furthest toward -x-y (the enemy base)")
    end)

    it("splits two packs in different lanes", function()
        local creeps = { c(5000,0,3), c(5100,0,3),      -- bot pack
                         c(0,5000,3), c(100,5000,3) }    -- top pack
        local waves = Lane.DetectWaves(creeps, { x = -1, y = -1 }, {})
        assert_eq(#waves, 2)
        local lanes = { waves[1].lane, waves[2].lane }
        table.sort(lanes)
        assert_eq(lanes[1], "bot"); assert_eq(lanes[2], "top")
    end)

    it("empty -> no waves", function()
        assert_eq(#Lane.DetectWaves({}, { x = 1, y = 1 }, {}), 0)
    end)
end)

describe("lib/lane -- PredictClash", function()
    local function wave(team, frontx, fronty, strength)
        return { team = team, front = { x = frontx, y = fronty }, strength = strength }
    end
    local OPTS = { drift_coeff = 0.5, horizon = 6, creep_speed = 300, move_threshold = 0.1, tower_weight = 4000 }

    it("even strengths -> not moving, settle == contact", function()
        local e = wave(3, 100, 0, 500)
        local a = wave(2, -100, 0, 500)
        local cl = Lane.PredictClash(e, a, {}, OPTS)
        assert_eq(cl.pushing, "even"); assert_false(cl.moving)
        assert_true(math.abs(cl.contact.x) < 1e-6, "contact at the midpoint x=0")
        assert_true(math.abs(cl.settle.x - cl.contact.x) < 1e-6, "settle == contact")
        assert_eq(cl.settle_eta, 0)
    end)

    it("stronger enemy pushes toward the ally front", function()
        local e = wave(3, 100, 0, 1000)   -- enemy at +x, ally at -x
        local a = wave(2, -100, 0, 200)
        local cl = Lane.PredictClash(e, a, {}, OPTS)
        assert_eq(cl.pushing, "enemy"); assert_true(cl.moving)
        assert_true(cl.drift_dir.x < 0, "drift toward the ally side (-x)")
        assert_true(cl.settle.x < cl.contact.x, "settle moved -x")
    end)

    it("a defending tower in the drift path clamps the settle to its line", function()
        -- enemy(2000) strongly out-pushes ally(100): drift toward -x. An ally tower at (-800,0),
        -- OUTSIDE the contact's tower range (so it adds no weight, only clamps), holds the line ->
        -- settle clamps to it. (A tower WITHIN range of the contact instead adds tower_weight to
        -- its side, which is the separate "a tower at the clash defends" effect.)
        local e = wave(3, 100, 0, 2000)
        local a = wave(2, -100, 0, 100)
        local towers = { { pos = { x = -800, y = 0 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_eq(cl.pushing, "enemy")
        assert_true(cl.settle.x <= -799 and cl.settle.x >= -801, "clamped to the tower line ~-800, got " .. cl.settle.x)
    end)

    it("a tower INSIDE contact range strengthens ITS OWN side (pins the team attribution)", function()
        -- MUTATION-DRIVEN: every sibling test deliberately parks its tower OUTSIDE contact
        -- range so it only CLAMPS the settle, leaving the in-range arm - the one that adds
        -- tower_weight to a side - completely unexercised. Swapping `we` and `wa` in
        -- lib/lane.lua left the whole suite green, so a tower could strengthen the WRONG side
        -- and ship. Equal waves plus one tower sitting on the contact: whoever owns it wins.
        local e = wave(3, 100, 0, 1000)
        local a = wave(2, -100, 0, 1000)
        local cl = Lane.PredictClash(e, a, { { pos = { x = 0, y = 0 }, team = 3, range = 700, alive = true } }, OPTS)
        assert_eq(cl.pushing, "enemy", "an ENEMY-team tower at the contact must push enemy")
        local cl2 = Lane.PredictClash(e, a, { { pos = { x = 0, y = 0 }, team = 2, range = 700, alive = true } }, OPTS)
        assert_eq(cl2.pushing, "ally", "an ALLY-team tower at the contact must push ally")
    end)
    it("uncontested push (no ally wave) drifts fully toward the enemy base", function()
        local e = wave(3, 100, 0, 800)
        local cl = Lane.PredictClash(e, nil, {}, OPTS)
        assert_eq(cl.pushing, "enemy"); assert_true(cl.moving)
        assert_true(cl.contact.x == 100 and cl.contact.y == 0, "contact = the lone front")
    end)

    it("no waves -> nil", function()
        assert_true(Lane.PredictClash(nil, nil, {}, OPTS) == nil)
    end)

    it("flags crashing when the wave pushes into a defending tower", function()
        -- enemy(2000) out-pushes ally(100): drift toward -x; an ally tower at (-800,0) (outside the
        -- contact's range, so it adds no weight) sits in the drift path -> the wave crashes into it.
        local e = wave(3, 100, 0, 2000)
        local a = wave(2, -100, 0, 100)
        local towers = { { pos = { x = -800, y = 0 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_true(cl.crashing, "crashing into the defending tower")
        assert_true(cl.crash_tower ~= nil and cl.crash_tower.team == 2, "crash tower is the ally (defending) tower")
    end)

    it("no crash when the settle does not reach a tower", function()
        local e = wave(3, 100, 0, 600)    -- mild push
        local a = wave(2, -100, 0, 400)
        local towers = { { pos = { x = -3000, y = 0 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_false(cl.crashing, "settle short of the tower -> not crashing")
    end)

    -- v0.1.383 regression trio. The pick scored ONLY the projection along drift_dir with no
    -- perpendicular bound, so a tower anywhere sideways won on a tiny projection. The travel
    -- budget is drift_coeff * |b| * creep_speed * horizon, so `along` can never exceed ~975 at
    -- shipped constants - yet the logged contact-to-tower distance ran a median 3212 (g380) and
    -- 96.8-97.2% of every crash stamp in the two most recent games named a tower the drift
    -- cannot physically reach. The corrected rule is one proximity test: the tower must lie
    -- within its OWN attack range of the drift segment [contact, settle].
    it("a tower OFF the drift axis is not in the path however small its projection", function()
        local e = wave(3, 100, 0, 2000)   -- contact (0,0), drift (-1,0), travel budget ~814
        local a = wave(2, -100, 0, 100)
        -- along = 100 (inside the budget, so the old rule selected it) but 5000 units sideways.
        -- Kept 5001 from the contact so it adds no tower_weight and cannot flip the push.
        local towers = { { pos = { x = -100, y = 5000 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_eq(cl.pushing, "enemy", "scenario intact: enemy still pushing")
        assert_false(cl.crashing, "a tower 5000 units off the drift axis is not crashed into")
        assert_true(cl.crash_tower == nil, "and it must not be named as the crash tower")
        assert_true(cl.settle.x < -800, "settle must NOT be clamped to the off-axis tower line, got " .. cl.settle.x)
    end)

    it("a tower BESIDE the drift path, inside its own range, still crashes", function()
        -- guards the fix against over-tightening: perp 400 <= range 700 -> still in the path.
        local e = wave(3, 100, 0, 2000)
        local a = wave(2, -100, 0, 100)
        local towers = { { pos = { x = -700, y = 400 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_true(cl.crashing, "wave passes within the tower's attack range -> crashing")
        assert_true(cl.settle.x <= -699 and cl.settle.x >= -701, "clamped to the tower line ~-700, got " .. cl.settle.x)
    end)

    it("a tower just past the settle, inside its own range, crashes without dragging the settle", function()
        -- a wave crashes a tower when it enters that tower's ATTACK RANGE, not when it reaches the
        -- tower's exact point. Budget ~814, tower at 1200 -> within 700 of the settle.
        local e = wave(3, 100, 0, 2000)
        local a = wave(2, -100, 0, 100)
        local towers = { { pos = { x = -1200, y = 0 }, team = 2, range = 700, alive = true } }
        local cl = Lane.PredictClash(e, a, towers, OPTS)
        assert_true(cl.crashing, "settle lands inside the tower's range -> crashing")
        assert_true(cl.settle.x >= -815 and cl.settle.x <= -813,
            "settle stays at the travel budget, never dragged past it, got " .. cl.settle.x)
    end)
end)

describe("lib/lane -- InterceptETA + NearestTeleportAnchor", function()
    local tp = { channel = 3 }

    it("teleport beats walking when an anchor is near the target", function()
        local from = { x = 0, y = 0 }
        local target = { x = 6000, y = 0 }
        local anchors = { { pos = { x = 5800, y = 0 }, ready = true, kind = "building" } }
        local r = Lane.InterceptETA(from, anchors, 300, tp, target, 9999)
        -- walk = 6000/300 = 20s; tp = 3 + 200/300 = 3.67s
        assert_true(math.abs(r.eta - (3 + 200/300)) < 1e-6, "tp eta")
        assert_true(r.best_anchor ~= nil, "anchor chosen")
        assert_true(r.reachable, "reachable within window")
    end)

    it("plain walk wins when no anchor helps; reachable boundary respected", function()
        local from = { x = 0, y = 0 }
        local target = { x = 600, y = 0 }    -- walk = 2s
        local r = Lane.InterceptETA(from, {}, 300, tp, target, 1.5)
        assert_true(r.best_anchor == nil, "walk")
        assert_true(math.abs(r.eta - 2.0) < 1e-6)
        assert_false(r.reachable, "2.0 > 1.5 window")
    end)

    it("works from an arbitrary from_pos (next-lane reuse)", function()
        local r = Lane.InterceptETA({ x = 1000, y = 1000 }, {}, 300, tp, { x = 1000, y = 1300 }, nil)
        assert_true(math.abs(r.eta - 1.0) < 1e-6, "300/300 = 1s")
        assert_true(r.reachable, "nil window -> always reachable")
    end)

    it("NearestTeleportAnchor filters by allowed kind + ready", function()
        local anchors = {
            { pos = { x = 100, y = 0 }, ready = true, kind = "ally" },
            { pos = { x = 50, y = 0 }, ready = false, kind = "building" },
            { pos = { x = 300, y = 0 }, ready = true, kind = "building" },
        }
        local a = Lane.NearestTeleportAnchor({ x = 0, y = 0 }, anchors, { "building" })
        assert_true(a ~= nil and math.abs(a.pos.x - 300) < 1e-6, "nearest READY building (50 is not ready)")
    end)
end)

describe("lib/lane -- PredictMeeting (one expression, all three lanes)", function()
    it("mid: equal spawn distance + equal speed -> midpoint, eta = gap/650", function()
        local m = Lane.PredictMeeting({ pos = {x=-3000,y=-3000}, speed = 325 },
                                      { pos = {x= 3000,y= 3000}, speed = 325 })
        assert_true(math.abs(m.point.x) < 1e-9 and math.abs(m.point.y) < 1e-9, "meets at the midpoint (0,0)")
        local gap = math.sqrt((6000)^2 + (6000)^2)
        assert_true(math.abs(m.eta - gap/650) < 1e-6, "eta = gap / closing speed 650")
    end)
    it("side lane: +30%/-35% speed split -> meeting off-centre toward the faster side", function()
        -- one side boosted (422.5), the other slowed (211.25); 1000 apart on a straight axis.
        local m = Lane.PredictMeeting({ pos = {x=0,y=0}, speed = 422.5 },
                                      { pos = {x=1000,y=0}, speed = 211.25 })
        -- the boosted wave covers 422.5/633.75 = 2/3 of the gap before they meet.
        assert_true(math.abs(m.point.x - 2000/3) < 1e-6, "meeting at 2/3 toward the slow side")
        assert_true(math.abs(m.eta - 1000/633.75) < 1e-6, "eta = gap / 633.75")
    end)
    it("not closing (both speed 0) -> nil", function()
        assert_true(Lane.PredictMeeting({ pos={x=0,y=0}, speed=0 }, { pos={x=10,y=0}, speed=0 }) == nil)
    end)
end)

describe("lib/lane -- MeetingPoint", function()
    it("both fronts visible -> midpoint of the two fronts", function()
        local m = Lane.MeetingPoint({ front = {x=0,y=0} }, { front = {x=1000,y=1000} }, {x=500,y=500})
        assert_eq(m.x, 500); assert_eq(m.y, 500)
    end)
    it("fogged enemy (no front) -> midpoint of our front and the lane centre", function()
        local m = Lane.MeetingPoint({ front = {x=200,y=200} }, { estimated = true }, {x=0,y=0})
        assert_eq(m.x, 100); assert_eq(m.y, 100)
    end)
    it("neither front -> the lane centre", function()
        local m = Lane.MeetingPoint(nil, { estimated = true }, {x=7,y=9})
        assert_eq(m.x, 7); assert_eq(m.y, 9)
    end)
    it("BUG 3: closing pair (enemy front still ahead of ours) -> midpoint", function()
        local push = { x = 1, y = 0 }                            -- toward the enemy = +x
        local m = Lane.MeetingPoint({ front = {x=-500,y=0} }, { front = {x=500,y=0} }, {x=0,y=0}, push)
        assert_eq(m.x, 0); assert_eq(m.y, 0)                     -- they are closing -> midpoint
    end)
    it("BUG 3: passed pair (our front overran past the enemy front) -> lane centre, not the deep midpoint", function()
        local push = { x = 1, y = 0 }
        local m = Lane.MeetingPoint({ front = {x=1500,y=0} }, { front = {x=-200,y=0} }, {x=0,y=0}, push)
        assert_eq(m.x, 0); assert_eq(m.y, 0)                     -- not closing -> fall back to mid (not 650)
    end)
    it("BUG 3: push_dir nil keeps the old midpoint behavior (back-compat)", function()
        local m = Lane.MeetingPoint({ front = {x=1500,y=0} }, { front = {x=-200,y=0} }, {x=0,y=0})
        assert_eq(m.x, 650)                                      -- no closure check -> midpoint
    end)
end)

describe("lib/lane -- engaged (most-advanced) wave selection", function()
    local function c(x, y, team) return { pos = {x=x,y=y}, team = team, hp = 100, gold = 40 } end
    it("picks the most-advanced front, NOT the biggest cluster", function()
        -- us = team 2, ally_push toward (+,+). A bigger FRESH pack deep at our base (~-4000) and a
        -- smaller ENGAGED pack forward near mid (~0): the forward one must be chosen (fixes notes 1/2/3).
        local creeps = {
            c(-4000,-4000,2), c(-4100,-4000,2), c(-4000,-4100,2), c(-4100,-4100,2),  -- 4: fresh, deep own
            c(-100,-100,2), c(-200,-200,2),                                          -- 2: engaged, near mid
        }
        local mid = Lane.BuildLaneStates(creeps, {}, {},
            { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1} }).mid
        assert_true(mid.ally_wave ~= nil, "ally wave on mid")
        assert_eq(mid.ally_wave.count, 2, "the forward engaged pack wins over the bigger fresh pack")
    end)
end)

describe("lib/lane -- BuildLaneStates", function()
    local function c(x, y, team, hp, gold) return { pos = {x=x,y=y}, team = team, hp = hp or 100, gold = gold or 40 } end

    it("assembles per-lane state with enemy/ally waves, gold, hero counts", function()
        -- team 2 (us). Enemy(3) + ally(2) clash in bot lane near (5000,0).
        local creeps = {
            c(5000,0,3,100,40), c(5100,0,3,100,40), c(5200,0,3,100,40),   -- enemy bot wave
            c(4600,0,2,100,40), c(4700,0,2,100,40),                       -- ally bot wave
        }
        local towers = { { pos = {x=4000,y=0}, team = 2, range = 700, alive = true } }
        local heroes = { { pos = {x=4850,y=0}, team = 3 }, { pos = {x=4850,y=0}, team = 2 } }
        local opts = { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1},
                       cluster_radius = 600, mid_band = 2500, hero_radius = 1200 }
        local lanes = Lane.BuildLaneStates(creeps, towers, heroes, opts)
        local bot = lanes.bot
        assert_true(bot.enemy_wave ~= nil and bot.ally_wave ~= nil, "both waves on bot")
        assert_eq(bot.enemy_wave.count, 3); assert_eq(bot.ally_wave.count, 2)
        assert_eq(bot.gold, 120, "lane gold = enemy wave gold (3*40)")
        assert_eq(bot.enemy_heroes, 1); assert_eq(bot.ally_heroes, 1)
        assert_true(bot.clash ~= nil, "clash predicted")
        assert_true(lanes.top ~= nil and lanes.mid ~= nil, "all three lanes present")
    end)

    it("crash tower comes from THIS lane, not a nearer-projecting off-lane tower", function()
        -- v0.1.375 regression. PredictClash clamps the drift at the nearest defending tower AHEAD,
        -- scored by projection ALONG drift_dir with no perpendicular bound. Passing the full tower
        -- list let a tower in another lane win purely by projecting closer, which is how 60-77% of
        -- every real game's crash stamps named an off-lane tower (g374: 156 of 224).
        local creeps = {
            c(5000,0,3), c(5100,0,3), c(5200,0,3),   -- enemy bot wave (stronger -> drift toward ally front)
            c(4600,0,2), c(4700,0,2),                -- ally bot wave
        }
        -- Geometry: contact=(4850,0), drift=(-1,0), travel budget 195. Selection scores ONLY the
        -- projection along drift, with no perpendicular bound, so this tower wins on along=100 while
        -- sitting 7000 units OFF the lane axis. That is exactly the real signature: ctd (the
        -- contact->tower EUCLIDEAN distance) reads median 8087 in g374 while travel can never exceed
        -- ~975, so the selected tower is nowhere near the wave.
        -- NOTE the tower must stay far from contact: PredictClash also adds opts.tower_weight (4000)
        -- to a NEARBY tower's own team strength, and a close ally tower flips b negative, making the
        -- ENEMY the defending team and voiding the whole scenario. 7000 out is safely past that.
        local offLane = { pos = {x=4750,y=7000}, team = 2, range = 700, alive = true }  -- x-y=-2250 -> mid
        local opts = { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1},
                       cluster_radius = 600, mid_band = 2500, hero_radius = 1200 }
        local bot = Lane.BuildLaneStates(creeps, { offLane }, {}, opts).bot
        assert_true(bot.clash ~= nil, "clash predicted on bot")
        local ct = bot.clash.crash_tower
        assert_true(ct == nil or Lane._assign_lane(ct.pos, opts) == "bot",
            "bot lane may only crash into a BOT tower; got one in lane " ..
            (ct and Lane._assign_lane(ct.pos, opts) or "-"))
    end)

    it("computes intercept when anchors + kinematics are supplied", function()
        local creeps = { c(5000,0,3), c(5100,0,3) }
        local opts = { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1},
                       anchors = { { pos = {x=4900,y=0}, ready = true, kind = "building" } },
                       allowed_kinds = { "building" }, hero_pos = {x=0,y=0}, move_speed = 300,
                       tp = { channel = 3 }, clear_window = 5 }
        local lanes = Lane.BuildLaneStates(creeps, {}, {}, opts)
        assert_true(lanes.bot.intercept ~= nil, "intercept computed")
        assert_true(lanes.bot.intercept.best_anchor ~= nil, "anchor used (near the clash)")
    end)

    it("empty creeps -> three empty lanes, no crash", function()
        local lanes = Lane.BuildLaneStates({}, {}, {}, { team = 2 })
        assert_true(lanes.top and lanes.mid and lanes.bot, "lanes present")
        assert_true(lanes.bot.enemy_wave == nil and lanes.bot.clash == nil, "empty bot")
    end)
end)

describe("lib/lane -- ExpectedWave (Liquipedia-validated wave model)", function()
    it("t=0: 3 melee + 1 ranged, cycle 0", function()
        local w = Lane.ExpectedWave(0, {})
        assert_eq(w.wave, 1); assert_eq(w.cycle, 0)
        assert_eq(w.melee, 3); assert_eq(w.ranged, 1); assert_eq(w.siege, 0); assert_eq(w.flagbearer, 0)
        assert_eq(w.count, 4); assert_eq(w.hp, 1950); assert_eq(w.gold, 169)   -- gold = sum GetGoldBountyMax (3*39 + 52)
    end)
    it("flagbearer wave (2:00, wave 5) replaces a melee + adds area gold", function()
        local w = Lane.ExpectedWave(120, {})
        assert_eq(w.flagbearer, 1); assert_eq(w.melee, 2); assert_eq(w.count, 4)
        -- Piece 1.5 fix: the flagbearer BOUNTY is already in the base sum; the area term adds ONLY
        -- the +10 area gold (the old 218 double-counted the bounty: base 39 + area(10+39)).
        assert_eq(w.gold, 179)   -- 2*39 + 52 + 39(flag) + 10(area)
    end)
    it("siege wave (5:00, wave 11) adds a siege creep (also a flagbearer wave)", function()
        local w = Lane.ExpectedWave(300, {})
        assert_eq(w.siege, 1); assert_eq(w.flagbearer, 1); assert_eq(w.melee, 2); assert_eq(w.count, 5)
    end)
    it("upgrade cycle scales hp + gold (7:30 = cycle 1, plain wave 16)", function()
        local w = Lane.ExpectedWave(450, {})
        assert_eq(w.cycle, 1); assert_eq(w.hp, 1998); assert_eq(w.gold, 175)   -- 3*(39+1) + (52+3)
    end)
    it("composition scales by time (16:30, wave 34 -> 4 melee, even wave = no flag/siege)", function()
        local w = Lane.ExpectedWave(990, {})
        assert_eq(w.wave, 34); assert_eq(w.melee, 4); assert_eq(w.ranged, 1)
        assert_eq(w.siege, 0); assert_eq(w.flagbearer, 0)
    end)
    it("super creeps swap stats, no flagbearer", function()
        local w = Lane.ExpectedWave(0, { super = true })
        assert_eq(w.flagbearer, 0); assert_eq(w.melee, 3); assert_eq(w.ranged, 1)
        assert_eq(w.hp, 2575); assert_eq(w.gold, 103)   -- super 3*26 + 25
    end)
    it("nil/negative time -> wave 1, no crash", function()
        local w = Lane.ExpectedWave(nil, {})
        assert_eq(w.wave, 1); assert_eq(w.melee, 3)
    end)
end)

describe("lib/lane -- BuildLaneStates fog-fill (ExpectedWave estimate)", function()
    local function c(x, y, team) return { pos = {x=x,y=y}, team = team, hp = 100, gold = 40 } end

    it("a fogged enemy lane gets an ExpectedWave estimate when game_time is given", function()
        local creeps = { c(4600,0,2), c(4700,0,2) }   -- only the ally bot wave is visible
        local opts = { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1}, game_time = 0 }
        local bot = Lane.BuildLaneStates(creeps, {}, {}, opts).bot
        assert_true(bot.enemy_wave ~= nil and bot.enemy_wave.estimated, "fogged enemy wave estimated")
        assert_eq(bot.enemy_wave.count, 4); assert_eq(bot.gold, 169)   -- GetGoldBountyMax basis
        assert_true(bot.enemy_wave.centroid == nil, "estimate has no position")
    end)
    it("no game_time -> fogged lane stays empty (no estimate)", function()
        local bot = Lane.BuildLaneStates({ c(4600,0,2) }, {}, {},
            { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1} }).bot
        assert_true(bot.enemy_wave == nil, "no estimate without game_time")
    end)
    it("a VISIBLE enemy wave is used as-is, not estimated", function()
        local creeps = { c(5000,0,3), c(5100,0,3) }   -- real enemy bot wave (team 3)
        local bot = Lane.BuildLaneStates(creeps, {}, {},
            { team = 2, enemy_push = {x=-1,y=-1}, ally_push = {x=1,y=1}, game_time = 0 }).bot
        assert_true(bot.enemy_wave ~= nil and not bot.enemy_wave.estimated, "real wave, not an estimate")
        assert_eq(bot.enemy_wave.count, 2)
    end)
end)

describe("lib/lane -- polyline utils (Piece 1.5)", function()
    local L = { { x = 0, y = 0 }, { x = 1000, y = 0 }, { x = 1000, y = 1000 } }   -- L-shape, len 2000
    it("PathLength sums the segments", function()
        assert_eq(Lane.PathLength(L), 2000)
    end)
    it("PointAtArc walks the polyline (and clamps both ends)", function()
        local p = Lane.PointAtArc(L, 500);  assert_eq(p.x, 500);  assert_eq(p.y, 0)
        p = Lane.PointAtArc(L, 1500);       assert_eq(p.x, 1000); assert_eq(p.y, 500)
        p = Lane.PointAtArc(L, -50);        assert_eq(p.x, 0);    assert_eq(p.y, 0)
        p = Lane.PointAtArc(L, 99999);      assert_eq(p.x, 1000); assert_eq(p.y, 1000)
    end)
    it("ArcOfPoint projects onto the nearest segment", function()
        assert_true(math.abs(Lane.ArcOfPoint(L, { x = 600, y = 50 }) - 600) < 1e-6, "off-lane point projects to arc 600")
        assert_true(math.abs(Lane.ArcOfPoint(L, { x = 1100, y = 500 }) - 1500) < 1e-6, "second segment, arc 1500")
    end)
    it("PathTangent = unit dir of the nearest segment (glue rebuild item 3)", function()
        local t = Lane.PathTangent(L, { x = 600, y = 50 })          -- nearest = first segment (+x)
        assert_eq(t.x, 1); assert_eq(t.y, 0)
        t = Lane.PathTangent(L, { x = 1100, y = 500 })              -- nearest = second segment (+y)
        assert_eq(t.x, 0); assert_eq(t.y, 1)
        assert_true(Lane.PathTangent({ { x = 0, y = 0 } }, { x = 1, y = 1 }) == nil, "degenerate path -> nil")
        assert_true(Lane.PathTangent(nil, { x = 1, y = 1 }) == nil, "nil path -> nil")
    end)
end)

describe("lib/lane -- BuildLanePaths (real map_data towers + spawns)", function()
    local MapData = require("lib.map_data")
    local paths = Lane.BuildLanePaths(MapData.TOWERS, MapData.SPAWNS)
    it("mid = 6 towers ordered good T3 -> bad T3 (no mid spawns captured)", function()
        assert_eq(#paths.mid, 6)
        assert_eq(paths.mid[1].x, -4640); assert_eq(paths.mid[1].y, -4144)
        assert_eq(paths.mid[6].x, 4272);  assert_eq(paths.mid[6].y, 3759)
    end)
    it("top = spawn + 6 towers + spawn, Radiant end first", function()
        assert_eq(#paths.top, 8)
        assert_eq(paths.top[1].x, -6608); assert_eq(paths.top[1].y, -4064)   -- Radiant top creep spawn
        assert_eq(paths.top[8].x, 3173);  assert_eq(paths.top[8].y, 5761)    -- Dire top creep spawn
    end)
    it("bot = spawn + 6 towers + spawn, Radiant end first", function()
        assert_eq(#paths.bot, 8)
        assert_eq(paths.bot[1].x, -3600); assert_eq(paths.bot[1].y, -6152)
        assert_eq(paths.bot[8].x, 6272);  assert_eq(paths.bot[8].y, 3648)
    end)
end)

describe("lib/lane -- MirrorWave (arc-length fogged estimate)", function()
    local A = { { x = 0, y = 0 },    { x = 4000, y = 0 } }      -- our role-paired lane
    local B = { { x = 0, y = 2000 }, { x = 4000, y = 2000 } }   -- the fogged enemy's lane
    local function wave(fx, fy, speed)
        return { front = { x = fx, y = fy }, centroid = { x = fx - 100, y = fy },
                 creeps = { { pos = { x = fx, y = fy }, speed = speed } } }
    end
    it("team 2: our wave s from the START -> enemy estimate s from the END of its lane", function()
        local m = Lane.MirrorWave(wave(500, 0, 422), A, B, 2)
        assert_true(math.abs(m.front.x - 3500) < 1e-6, "arc 500 from the Dire end = x 3500")
        assert_eq(m.front.y, 2000)
        assert_eq(m.speed, 422)
    end)
    it("team 3: symmetric (our end is the path END)", function()
        local m = Lane.MirrorWave(wave(3500, 0, 325), A, B, 3)
        assert_true(math.abs(m.front.x - 500) < 1e-6, "arc 500 from the Radiant end = x 500")
    end)
    it("centroid mirrors too; missing front -> nil", function()
        local m = Lane.MirrorWave(wave(500, 0, 400), A, B, 2)
        assert_true(math.abs(m.centroid.x - 3600) < 1e-6, "centroid arc 400 -> 3600 from their end")
        assert_true(Lane.MirrorWave({ creeps = {} }, A, B, 2) == nil, "no front -> no estimate")
    end)
end)

describe("lib/lane -- BuildLaneStates fog-fill MIRROR (Piece 1.5)", function()
    local paths = {
        top = { { x = 0, y = 5000 },  { x = 4000, y = 5000 } },
        mid = { { x = 0, y = 0 },     { x = 4000, y = 4000 } },
        bot = { { x = 0, y = -5000 }, { x = 4000, y = -5000 } },
    }
    local function c(x, y, team, speed) return { pos = { x = x, y = y }, team = team, hp = 100, gold = 40, speed = speed } end
    it("a fogged enemy lane mirrors our role-paired wave (position + speed)", function()
        -- our SAFE (bot, team 2) wave visible at arc ~3000; enemy TOP (their safe) is fogged.
        local creeps = { c(2900, -5000, 2, 422), c(3000, -5000, 2, 422) }
        local lanes = Lane.BuildLaneStates(creeps, {}, {}, {
            team = 2, enemy_push = { x = -1, y = 0 }, ally_push = { x = 1, y = 0 },
            game_time = 0, paths = paths,
        })
        local ew = lanes.top.enemy_wave
        assert_true(ew and ew.estimated, "estimated")
        assert_eq(ew.est_src, "mirror")
        assert_true(math.abs(ew.front.x - 1000) < 1e-6, "our arc 3000 -> 1000 from their end")
        assert_eq(ew.front.y, 5000)
        assert_eq(ew.speed, 422)
    end)
    it("no role-paired wave -> clock fallback (composition only, no position)", function()
        local creeps = { c(2900, -5000, 2, 422) }   -- only bot; MID enemy fogged, our mid dead
        local lanes = Lane.BuildLaneStates(creeps, {}, {}, {
            team = 2, enemy_push = { x = -1, y = 0 }, ally_push = { x = 1, y = 0 },
            game_time = 0, paths = paths,
        })
        local ew = lanes.mid.enemy_wave
        assert_true(ew and ew.estimated, "estimated")
        assert_eq(ew.est_src, "clock")
        assert_true(ew.front == nil, "clock estimate has no position")
    end)
    it("vision-edge clamp: a fogged front is never placed inside our same-lane sight", function()
        -- our TOP wave pushed to arc 2400 (x-y=-2600 -> top band); the bot-mirrored top estimate
        -- (arc 1000 from our end) would sit BEHIND our own front = inside our creeps' vision =
        -- impossible while fogged -> floored to our front + 800.
        local creeps = { c(2900, -5000, 2, 422), c(3000, -5000, 2, 422), c(2400, 5000, 2, 400) }
        local lanes = Lane.BuildLaneStates(creeps, {}, {}, {
            team = 2, enemy_push = { x = -1, y = 0 }, ally_push = { x = 1, y = 0 },
            game_time = 0, paths = paths,
        })
        local ew = lanes.top.enemy_wave
        assert_eq(ew.est_src, "mirror")
        assert_true(math.abs(ew.front.x - 3200) < 1e-6, "floored to our front (2400) + vis (800)")
    end)
end)

describe("lib/lane -- SimFight (attrition combat sim; imbalance = damage, not just life)", function()
    local function melee(n) local t = {} for i = 1, n do t[i] = { hp = 550, dmg = 21, atk = 1, armor = 2, atype = "basic" } end return t end
    it("3v2 equal creeps -> the extra creep COMPOUNDS: 2 survivors, not 1", function()
        local f = Lane.SimFight(melee(3), melee(2), { dt = 0.25 })
        assert_eq(f.winner, "a")
        assert_eq(#f.remnant_a, 2, "Lanchester compounding: the +1 advantage preserves ~2 survivors")
        assert_true(f.t > 15 and f.t < 25, "fight duration ~19s")
    end)
    it("pierce multiplier matters: 1 melee beats 1 ranged head-to-head (ranged is squishier)", function()
        local ranged = { { hp = 300, dmg = 23.5, atk = 1, armor = 0, atype = "pierce" } }
        local f = Lane.SimFight(ranged, melee(1), { dt = 0.25 })
        assert_eq(f.winner, "b", "the melee outlasts (550hp vs 300) despite pierce 1.5x")
    end)
    it("an untargetable support attacker (tower) swings the fight", function()
        local f = Lane.SimFight(melee(1), melee(1), { dt = 0.25, support_b = { { dmg = 110, atk = 1, atype = "siege" } } })
        assert_eq(f.winner, "b"); assert_true(f.t < 8, "tower support ends it fast")
    end)
    it("empty sides -> draw, no crash", function()
        local f = Lane.SimFight({}, {}, {})
        assert_eq(f.winner, "draw")
    end)
end)

describe("lib/lane -- WaveCombatants + PushForecast (lane balance)", function()
    it("an ESTIMATED wave builds full-hp combat records from its composition", function()
        local est = Lane.ExpectedWave(0, {})
        local c = Lane.WaveCombatants(est, 0)
        assert_eq(#c, 4, "3 melee + 1 ranged at 0:00")
        local nr = 0
        for _, u in ipairs(c) do if u.atype == "pierce" then nr = nr + 1 end end
        assert_eq(nr, 1, "one ranged (pierce)")
    end)
    it("a REAL wave uses LIVE hp + per-member kind", function()
        local w = { creeps = { { hp = 120, kind = "ranged" }, { hp = 400, kind = "melee" } } }
        local c = Lane.WaveCombatants(w, 0)
        assert_eq(#c, 2)
        local hp = {}
        for _, u in ipairs(c) do hp[#hp + 1] = u.hp end
        table.sort(hp); assert_eq(hp[1], 120); assert_eq(hp[2], 400)
    end)
    it("PushForecast: equal waves ~balance 0; a 4v3 wave reads positive bal + winner a", function()
        local even = Lane.PushForecast(Lane.ExpectedWave(0, {}), Lane.ExpectedWave(0, {}), { rounds = 1 })
        assert_true(math.abs(even.bal or 99) <= 1, "equal waves near-zero balance")
        local big = { melee = 4, ranged = 1, siege = 0, flagbearer = 0 }
        local small = { melee = 3, ranged = 1, siege = 0, flagbearer = 0 }
        local pf = Lane.PushForecast(big, small, { rounds = 2 })
        assert_true((pf.bal or 0) > 0, "the extra melee wins the balance")
        assert_eq(pf.rounds[1].winner, "a")
        assert_eq(#pf.rounds, 2)
        assert_true((pf.first_t or 0) > 0, "fight duration reported (peta basis)")
    end)
end)

describe("lib/lane -- ClampBeyondSight (fog absence-of-vision floor)", function()
    local P = { { x = 0, y = 0 }, { x = 4000, y = 0 } }
    it("team 2: an estimate inside our sight moves to our front + vis", function()
        local p = Lane.ClampBeyondSight({ x = 1500, y = 0 }, { x = 2500, y = 0 }, P, 2, 800)
        assert_true(math.abs(p.x - 3300) < 1e-6, "2500 + 800")
    end)
    it("an estimate already beyond sight is untouched", function()
        local p = Lane.ClampBeyondSight({ x = 3600, y = 0 }, { x = 2500, y = 0 }, P, 2, 800)
        assert_eq(p.x, 3600)
    end)
    it("team 3: symmetric (our end is the path END)", function()
        local p = Lane.ClampBeyondSight({ x = 2500, y = 0 }, { x = 1500, y = 0 }, P, 3, 800)
        assert_true(math.abs(p.x - 700) < 1e-6, "their arc floor mirrored: 4000-(2500+800)")
    end)
end)

describe("lib/schedule -- Plan low_hp dispatch gate (case-file #2)", function()
    local CAL = { march_dmg_per_cast = 300, cast_dur = 0.5, robot_kill = 1.5, rearm_channel = 1.25, lead = 1 }
    local function base(over)
        local c = { now = 100, wave = { arrival = 100, eff_hp = 450, present = true },
                    cal = CAL, travel_to_mid = 3, mana = 500, shove_cost = 200, safe = true }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end
    it("a due shove below the hp bar recovers first (run-72 t=445: panic on arrival)", function()
        local d = Schedule.Plan(base({ hp_frac = 0.35, min_hp_frac = 0.50 }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "low_hp")
    end)
    it("healthy hp dispatches unchanged; nil ctx fields = rule inactive (back-compat)", function()
        local d = Schedule.Plan(base({ hp_frac = 0.80, min_hp_frac = 0.50 }))
        assert_eq(d.action, "shove")
        local d2 = Schedule.Plan(base({}))
        assert_eq(d2.action, "shove")
    end)
end)

describe("lib/schedule -- WaveCycleCost + CycleFill (THE CYCLE ARC, v0.1.339)", function()
    it("cycle cost = 2*(W + rearm + keen); nil-safe", function()
        assert_eq(Schedule.WaveCycleCost({ w = 160, rearm = 225, keen = 75 }), 920)
        assert_eq(Schedule.WaveCycleCost({}), 0)
        assert_eq(Schedule.WaveCycleCost(nil), 0)
    end)
    it("g340 fixture: pool 452 vs cycle 920 -> fountain, need capped at max pool 747", function()
        local f = Schedule.CycleFill({ pool = 452, max_pool = 747, cycle_cost = 920, broke_bar = 460 })
        assert_eq(f.fill, "fountain"); assert_eq(f.need, 747)
    end)
    it("g340 fixture: funded pool 870 with no farm fill -> park, no need", function()
        local f = Schedule.CycleFill({ pool = 870, max_pool = 1023, cycle_cost = 860, broke_bar = 460 })
        assert_eq(f.fill, "park"); assert_eq(f.need, nil)
    end)
    it("boundary: pool == cycle_cost -> park (not unfunded)", function()
        assert_eq(Schedule.CycleFill({ pool = 920, max_pool = 1023, cycle_cost = 920, broke_bar = 460 }).fill, "park")
    end)
    it("the .296 broke floor keeps authority when cycle_cost reads low", function()
        local f = Schedule.CycleFill({ pool = 300, max_pool = 747, cycle_cost = 0, broke_bar = 460 })
        assert_eq(f.fill, "fountain"); assert_eq(f.need, 460)
    end)
    it("nil ctx = park (inert default, no crash)", function()
        assert_eq(Schedule.CycleFill(nil).fill, "park")
    end)
    it("g341 re-calibration (v0.1.340): a pool above the broke bar PARKS even under the cycle cost - the trigger is the broke floor only", function()
        assert_eq(Schedule.CycleFill({ pool = 577, max_pool = 747, cycle_cost = 630, broke_bar = 460 }).fill, "park")
    end)
    it("split semantics (v0.1.340): a broke pool triggers via the bar but FILLS to the cycle cost", function()
        local f = Schedule.CycleFill({ pool = 435, max_pool = 747, cycle_cost = 670, broke_bar = 460 })
        assert_eq(f.fill, "fountain"); assert_eq(f.need, 670)
    end)
end)

describe("lib/channel_gate -- DisableRange (ARC E1)", function()
    local CG = require("lib.channel_gate")
    local AD = { CastRange = function(n) return ({ lion_impale = 750, lion_voodoo = 525, generic_nuke = 800 })[n] end }
    local TD = { ABILITY_TO_THREAT = { lion_impale = "m_impale", lion_voodoo = "m_hex",
                                       pudge_dismember = "m_dis", generic_nuke = "m_nuke" },
                 THREATS_ON_SELF = { m_impale = { role = "hard_disable" }, m_hex = { role = "hard_disable" },
                                     m_dis = { role = "channel_on_me" }, m_nuke = { role = "magic_burst" } } }
    it("max cast range over the disable kit", function()
        assert_eq(CG.DisableRange({ "lion_impale", "lion_voodoo", "generic_nuke" }, AD, TD), 750)
    end)
    it("channel_on_me counts; unknown/short range floors at 250 (melee disables break on arrival)", function()
        assert_eq(CG.DisableRange({ "pudge_dismember" }, AD, TD), 250)
    end)
    it("no disable kit -> nil (never gates)", function()
        assert_eq(CG.DisableRange({ "generic_nuke" }, AD, TD), nil)
    end)
    it("nil-safe on missing inputs", function()
        assert_eq(CG.DisableRange(nil, AD, TD), nil)
        assert_eq(CG.DisableRange({ "lion_impale" }, nil, TD), nil)
    end)
end)

describe("lib/channel_gate -- Breakers + stamps (ARC E2)", function()
    local CG = require("lib.channel_gate")
    local AD = { CastRange = function(n) return ({ lion_impale = 750, lion_voodoo = 525, generic_nuke = 800 })[n] end }
    local TD = { ABILITY_TO_THREAT = { lion_impale = "m_impale", lion_voodoo = "m_hex",
                                       pudge_dismember = "m_dis", generic_nuke = "m_nuke" },
                 THREATS_ON_SELF = { m_impale = { role = "hard_disable" }, m_hex = { role = "hard_disable" },
                                     m_dis = { role = "channel_on_me" }, m_nuke = { role = "magic_burst" } } }
    it("Breakers lists each channel-breaking ability with its range", function()
        local br = CG.Breakers({ "lion_impale", "lion_voodoo", "generic_nuke" }, AD, TD)
        assert_eq(#br, 2)                        -- impale + voodoo break; the nuke does not
        local seen, mods = {}, {}
        for _, b in ipairs(br) do seen[b.ability] = b.range; mods[b.ability] = b.mod end
        assert_eq(seen["lion_impale"], 750)
        assert_eq(seen["lion_voodoo"], 525)                                 -- non-max entry keeps its own range
        assert_eq(mods["lion_impale"], "m_impale")                          -- modifier name carried through
        assert_eq(math.max(seen["lion_impale"], seen["lion_voodoo"]), 750)  -- matches DisableRange
    end)
    it("Breakers returns nil for a kit with no breakers", function()
        assert_eq(CG.Breakers({ "generic_nuke" }, AD, TD), nil)
    end)
    it("LevelCleared: ability level is THE check for every breaker (run-83 user rule)", function()
        local basic, ult = { ability = "lina_lsa" }, { ability = "necro_scythe", ult = true }
        -- fresh ability-level-0 observation clears ANY breaker (basic or ult)
        assert_true(CG.LevelCleared(basic, { abil = { lvl = 0, t = 100 } }, 110), "fresh lvl0 basic cleared")
        assert_true(CG.LevelCleared(ult, { abil = { lvl = 0, t = 100 } }, 110), "fresh lvl0 ult cleared")
        -- a skilled ability never clears; a STALE lvl-0 observation never clears (they can
        -- spend a banked point invisibly)
        assert_false(CG.LevelCleared(basic, { abil = { lvl = 1, t = 110 } }, 110), "skilled not cleared")
        assert_false(CG.LevelCleared(basic, { abil = { lvl = 0, t = 100 } }, 140), "stale lvl0 not cleared")
        -- the ult fact ages at the fastest-leveling bound (25s/level): hero seen lvl2 60s
        -- ago reads at most ~4.4 -> cleared; lvl5 seen 30s ago could be 6 -> NOT cleared
        assert_true(CG.LevelCleared(ult, { hero = { lvl = 2, t = 40 } }, 100), "young hero ult cleared")
        assert_false(CG.LevelCleared(ult, { hero = { lvl = 5, t = 70 } }, 100), "near-6 hero not cleared")
        -- hero level NEVER clears a basic (Lina LSA / Zeus Bolt class), and no obs = assume ready
        assert_false(CG.LevelCleared(basic, { hero = { lvl = 1, t = 100 } }, 100), "hero lvl never clears basics")
        assert_false(CG.LevelCleared(basic, nil, 100), "no observation = assume ready")
    end)
    it("Breakers flags ultimates (run-83: a pre-6 Necro cannot have Scythe)", function()
        local AD3 = { CastRange = function(n) return ({ necro_scythe = 600, lion_impale = 750 })[n] end,
                      Get = function(n) return ({ necro_scythe = { type = "ultimate" },
                                                  lion_impale = { type = "basic" } })[n] end }
        local TD3 = { ABILITY_TO_THREAT = { necro_scythe = "m_scythe", lion_impale = "m_impale" },
                      THREATS_ON_SELF = { m_scythe = { role = "hard_disable" }, m_impale = { role = "hard_disable" } } }
        local br = CG.Breakers({ "necro_scythe", "lion_impale" }, AD3, TD3)
        local ult = {}
        for _, b in ipairs(br) do ult[b.ability] = b.ult end
        assert_true(ult["necro_scythe"] == true, "ultimate flagged")
        assert_true(not ult["lion_impale"], "basic not flagged")
    end)
    it("breaks_channel-tagged entries gate regardless of role (E3c)", function()
        local AD2 = { CastRange = function(n) return ({ ministun_bolt = 700, plain_nuke = 800 })[n] end }
        local TD2 = { ABILITY_TO_THREAT = { ministun_bolt = "m_bolt", plain_nuke = "m_nuke" },
                      THREATS_ON_SELF = { m_bolt = { role = "magic_burst", breaks_channel = true },
                                          m_nuke = { role = "magic_burst" } } }
        local br = CG.Breakers({ "ministun_bolt", "plain_nuke" }, AD2, TD2)
        assert_eq(#br, 1)                       -- only the tagged ministun gates; the plain nuke does not
        assert_eq(br[1].ability, "ministun_bolt")
        assert_eq(br[1].range, 700)
    end)
    it("Stamp + ReadyAt: stamped ability reads not-ready until expiry", function()
        local st = {}
        CG.Stamp(st, "npc_dota_hero_lion", "lion_impale", 100, 12)
        assert_eq(st["npc_dota_hero_lion"]["lion_impale"], 112)                    -- table shape + t+cd arithmetic
        assert_true(not CG.ReadyAt(st, "npc_dota_hero_lion", "lion_impale", 105))  -- 5s in, cd 12
        assert_true(not CG.ReadyAt(st, "npc_dota_hero_lion", "lion_impale", 111.9))
        assert_true(CG.ReadyAt(st, "npc_dota_hero_lion", "lion_impale", 112))      -- >= boundary reads ready
        assert_true(CG.ReadyAt(st, "npc_dota_hero_lion", "lion_impale", 112.5))    -- past expiry
        assert_true(CG.ReadyAt(st, "npc_dota_hero_lion", "lion_voodoo", 105))      -- unstamped = assume ready
        assert_true(CG.ReadyAt(st, "npc_dota_hero_pudge", "lion_impale", 105))     -- other caster = assume ready
    end)
end)

describe("lib/schedule -- StackWindow (v0.1.224)", function()
    it("mid-minute before the window targets THIS minute", function()
        local w = Schedule.StackWindow(120 + 30, { aggro_sec = 54 })
        assert_eq(w.aggro_at, 174)
        assert_eq(w.done, 180.5)
        assert_true(w.from < w.aggro_at and w.to > w.done, "from/to bracket the maneuver")
    end)
    it("past the miss slack rolls to the NEXT minute", function()
        local w = Schedule.StackWindow(120 + 57, { aggro_sec = 54, miss_slack = 1.5 })
        assert_eq(w.aggro_at, 234)
        assert_eq(w.done, 240.5)
    end)
    it("timeline semantics: start at aggro collects, a late start overruns to", function()
        local w = Schedule.StackWindow(60, { aggro_sec = 54, miss_slack = 1.5 })
        assert_true(w.aggro_at + w.clear_t <= w.to, "on-time start finishes inside the window")
        assert_true((w.aggro_at + 3) + w.clear_t > w.to, "a 3s-late start overruns")
    end)
    it("minute-0 window rolls past the first neutral spawn (run-66: 40s walk to an unspawned camp)", function()
        local w = Schedule.StackWindow(30, { aggro_sec = 54 })
        assert_eq(w.aggro_at, 114)                          -- 0:54 targets nothing (spawn at 1:00) -> 1:54
        assert_eq(w.done, 120.5)
        local w2 = Schedule.StackWindow(70, { aggro_sec = 54 })
        assert_eq(w2.aggro_at, 114)                         -- minute 1 unaffected
    end)
end)

describe("lib/route -- _leg_time", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }

    it("walk leg = distance / move_speed when no anchors help", function()
        local t = Route._leg_time({ x = 0, y = 0 }, { pos = { x = 900, y = 0 } }, hs)
        assert_true(math.abs(t - 3.0) < 1e-6, "900/300 = 3s")
    end)

    it("a ready anchor near the target beats walking (tp.channel + short hop)", function()
        local hs2 = { pos = { x = 0, y = 0 }, move_speed = 300, tp = { channel = 3 },
                      anchors = { { pos = { x = 5800, y = 0 }, ready = true, kind = "building" } } }
        local t = Route._leg_time({ x = 0, y = 0 }, { pos = { x = 6000, y = 0 } }, hs2)
        assert_true(math.abs(t - (3 + 200 / 300)) < 1e-6, "tp 3 + 200/300")
    end)
end)

describe("lib/route -- _timeline", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }
    local function tgt(x, value, clear_t, window) return { pos = { x = x, y = 0 }, value = value, clear_t = clear_t, window = window } end

    it("collects reachable targets and sums gold; time = elapsed", function()
        local seq = { tgt(900, 60, 3), tgt(1800, 40, 1) }   -- legs 3 + clear 3 = 6; leg 3 + clear 1 = 10
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 2)
        assert_eq(tl.gold, 100)
        assert_true(math.abs(tl.time - 10) < 1e-6, "finish at t=10")
    end)

    it("waits until window.from before clearing (a not-yet-spawned wave)", function()
        local seq = { tgt(900, 180, 2, { from = 20, to = 999 }) }   -- arrive 3, wait to 20, clear 2 -> 22
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(tl.gold, 180)
        assert_true(math.abs(tl.time - 22) < 1e-6, "waited to window.from then cleared")
    end)

    it("stops at the first target that overruns the horizon", function()
        local seq = { tgt(900, 60, 3), tgt(9000, 40, 1) }   -- second: leg 9000-900=8100/300=27 -> way past 30
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 1, "only the first fits")
        assert_eq(tl.gold, 60)
    end)

    it("drops a target that finishes after window.to", function()
        local seq = { tgt(900, 50, 3, { from = 0, to = 4 }) }   -- finish 6 > to 4
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 0)
    end)
end)

describe("lib/route -- _score", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }
    local function tgt(x, value, clear_t, risk) return { pos = { x = x, y = 0 }, value = value, clear_t = clear_t, risk = risk } end

    it("score = gold - risk_weight * sum(risk) over collected", function()
        local seq = { tgt(900, 100, 3, 0.5), tgt(1800, 100, 1, 0.0) }
        local sc = Route._score(seq, hs, { now = 0, horizon_s = 30, risk_weight = 40 })
        assert_eq(sc.gold, 200)
        assert_true(math.abs(sc.score - (200 - 40 * 0.5)) < 1e-6, "200 - 20 = 180")
        assert_eq(#sc.collected, 2)
    end)

    it("risk on an UNcollected target does not count", function()
        local seq = { tgt(900, 60, 3, 0.0), tgt(9000, 100, 1, 1.0) }   -- 2nd overruns horizon
        local sc = Route._score(seq, hs, { now = 0, horizon_s = 30, risk_weight = 40 })
        assert_eq(sc.gold, 60)
        assert_true(math.abs(sc.score - 60) < 1e-6, "the far risky target was never collected")
    end)

    it("step_decay discounts later steps in the SCORE, gold stays the true sum (v0.1.212)", function()
        local seq = { tgt(900, 100, 3, 0.0), tgt(1800, 200, 1, 0.0) }
        local sc = Route._score(seq, hs, { now = 0, horizon_s = 30, risk_weight = 0, step_decay = 0.6 })
        assert_eq(sc.gold, 300)
        assert_true(math.abs(sc.score - (100 + 0.6 * 200)) < 1e-6, "100 + 120 = 220")
    end)

    it("step_decay makes Plan bank the big node FIRST (pair-first over single-first)", function()
        -- single near (value 85), pair far (value 245): undecayed, [single, pair] = 330 beats
        -- [pair, single] = 330 only on time; decayed, front-loading the pair wins the score.
        local single = { pos = { x = 900,  y = 0 }, value = 85,  clear_t = 3, risk = 0 }
        local pair   = { pos = { x = 2400, y = 0 }, value = 245, clear_t = 3, risk = 0 }
        local plan = Route.Plan({ single, pair }, hs,
            { now = 0, horizon_s = 60, max_steps = 2, step_decay = 0.6 })
        assert_eq(plan.steps[1].value, 245, "the pair is banked first under step_decay")
        local plain = Route.Plan({ single, pair }, hs,
            { now = 0, horizon_s = 60, max_steps = 2 })
        assert_eq(plain.gold, 330, "undecayed still collects both")
    end)
end)

describe("lib/route -- Plan + Select", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }

    it("plans the triangle: camp now, wave when it spawns, tie-break by time", function()
        local A = { kind = "camp", pos = { x = 900,  y = 0 }, value = 60,  clear_t = 3 }
        local W = { kind = "wave", pos = { x = 1800, y = 0 }, value = 180, clear_t = 2, window = { from = 20, to = 999 } }
        local plan = Route.Plan({ W, A }, hs, { now = 0, horizon_s = 30, max_steps = 4, risk_weight = 0 })
        assert_eq(plan.gold, 240, "both collected")
        assert_eq(#plan.steps, 2)
        assert_true(plan.steps[1] == A, "camp first (the wave is not up yet -> farm the camp meanwhile)")
        assert_true(plan.steps[2] == W, "wave second, when it has spawned")
    end)

    it("respects the horizon (drops a target that cannot finish in time)", function()
        local A = { kind = "camp", pos = { x = 900,  y = 0 }, value = 60,  clear_t = 3 }
        local W = { kind = "wave", pos = { x = 1800, y = 0 }, value = 180, clear_t = 2, window = { from = 20, to = 999 } }
        local plan = Route.Plan({ W, A }, hs, { now = 0, horizon_s = 10, max_steps = 4, risk_weight = 0 })
        assert_eq(#plan.steps, 1, "only the camp fits in a 10s horizon")
        assert_true(plan.steps[1] == A)
        assert_eq(plan.gold, 60)
    end)

    it("vetoes risk >= risk_hard and skips contested targets", function()
        local good = { kind = "camp", pos = { x = 600, y = 0 }, value = 50, clear_t = 1 }
        local risky = { kind = "camp", pos = { x = 300, y = 0 }, value = 999, clear_t = 1, risk = 0.9 }
        local owned = { kind = "wave", pos = { x = 450, y = 0 }, value = 999, clear_t = 1, contested = true }
        local plan = Route.Plan({ risky, owned, good }, hs, { now = 0, horizon_s = 30, max_steps = 4, risk_weight = 0, risk_hard = 0.45 })
        for _, s in ipairs(plan.steps) do
            assert_true(s ~= risky and s ~= owned, "risky/contested excluded")
        end
        assert_true(plan.steps[1] == good, "the safe, uncontested target is chosen")
    end)

    it("max_leg_s drops an unreachable far camp (the far-camp stuck guard)", function()
        local near = { kind = "camp", pos = { x = 600,  y = 0 }, value = 50, clear_t = 1 }
        local far  = { kind = "camp", pos = { x = 9000, y = 0 }, value = 999, clear_t = 1 }  -- 9000/300 = 30s > 20
        local plan = Route.Plan({ far, near }, hs, { now = 0, horizon_s = 60, max_steps = 4, risk_weight = 0, max_leg_s = 20 })
        for _, s in ipairs(plan.steps) do assert_true(s ~= far, "far/unreachable camp excluded despite huge value") end
        assert_true(plan.steps[1] == near)
    end)

    it("Select returns the first leg; empty input -> nil / empty plan", function()
        local A = { kind = "camp", pos = { x = 600, y = 0 }, value = 50, clear_t = 1 }
        assert_true(Route.Select({ A }, hs, { now = 0, horizon_s = 30 }) == A)
        local empty = Route.Plan({}, hs, { now = 0, horizon_s = 30 })
        assert_eq(#empty.steps, 0); assert_eq(empty.gold, 0)
        assert_true(Route.Select({}, hs, { now = 0, horizon_s = 30 }) == nil)
    end)

    it("round-trip: return_pos drops a camp it cannot walk back from in time (v0.1.93)", function()
        local near = { kind = "camp", pos = { x = 600,  y = 0 }, value = 100, clear_t = 2 }
        local far  = { kind = "camp", pos = { x = 2000, y = 0 }, value = 200, clear_t = 2 }
        -- without return_pos the higher-value far camp fits the 12s horizon (reach+clear ~8.7s).
        local without = Route.Plan({ near, far }, hs, { now = 0, horizon_s = 12, risk_weight = 0 })
        local has_far = false
        for _, s in ipairs(without.steps) do if s == far then has_far = true end end
        assert_true(has_far, "without return_pos: far camp is collectable")
        -- with return_pos: far finish ~8.7s + walk back 2000/300 ~6.7s = ~15.3s > 12 -> excluded.
        local withrp = Route.Plan({ near, far }, hs,
            { now = 0, horizon_s = 12, risk_weight = 0, return_pos = { x = 0, y = 0 }, return_speed = 300 })
        assert_eq(#withrp.steps, 1, "only the near camp survives the round-trip check")
        assert_true(withrp.steps[1] == near, "near camp kept")
        assert_eq(withrp.gold, 100, "gold = near camp only")
    end)

    it("round-trip: keen-aware return (return_anchors) keeps a far camp a ready anchor can cover (v0.1.125 BUG 2)", function()
        local hs2 = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }
        local far = { kind = "camp", pos = { x = 2000, y = 0 }, value = 200, clear_t = 2 }
        -- walk-only return: camp->mid walk 2000/300 ~6.7s; finish ~8.7 + 6.7 = 15.3 > 12 -> excluded.
        local walk = Route.Plan({ far }, hs2,
            { now = 0, horizon_s = 12, risk_weight = 0, return_pos = { x = 0, y = 0 }, return_speed = 300 })
        assert_eq(#walk.steps, 0, "walk-back return excludes the far camp")
        -- keen-aware: a ready anchor AT mid makes the return ~0 (channel 0) -> finish ~8.7 < 12 -> kept.
        local anchors = { { pos = { x = 0, y = 0 }, ready = true, kind = "building" } }
        local keen = Route.Plan({ far }, hs2,
            { now = 0, horizon_s = 12, risk_weight = 0, return_pos = { x = 0, y = 0 },
              return_speed = 300, return_anchors = anchors, return_tp = { channel = 0 } })
        assert_eq(#keen.steps, 1, "keen-aware return keeps the far camp (cheap anchor return)")
        assert_true(keen.steps[1] == far, "the far camp is kept")
    end)
end)

describe("lib/route -- resource gating (Note 4)", function()
    -- hero with mana so a hop costs mana; no anchors so legs are plain walk (dist/300).
    local function hsr(over)
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {},
                     mana = 200, max_mana = 400, mana_regen = 0, reserve_mana = 0, hp_floor = 0 }
        for k, v in pairs(over or {}) do hs[k] = v end
        return hs
    end
    local function ctg(x, value, clear_t, mana_cost, hp_cost)
        return { pos = { x = x, y = 0 }, value = value, clear_t = clear_t, mana_cost = mana_cost, hp_cost = hp_cost }
    end

    it("no resource fields -> gating is inert (back-compat)", function()
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }
        local seq = { { pos = { x = 900, y = 0 }, value = 60, clear_t = 3, mana_cost = 9999 } }
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 1, "no hero.mana -> mana_cost ignored")
    end)

    it("breaks the chain at the first unaffordable hop (mana)", function()
        local seq = { ctg(900, 60, 1, 120), ctg(1800, 60, 1, 120) }   -- 200 -> 80 after first; 80 < 120
        local tl = Route._timeline(seq, hsr(), { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 1, "second hop unaffordable")
        assert_eq(tl.gold, 60)
    end)

    it("reserve_mana is kept untouched", function()
        local seq = { ctg(900, 60, 1, 120) }   -- need 120 + reserve 100 = 220 > 200
        local tl = Route._timeline(seq, hsr({ reserve_mana = 100 }), { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 0, "cannot dip into the escape reserve")
    end)

    it("regen during travel lifts an otherwise-unaffordable hop", function()
        -- mana 100, cost 130; leg 900/300 = 3s; regen 20/s -> 100 + 60 = 160 >= 130
        local seq = { ctg(900, 60, 1, 130) }
        local tl = Route._timeline(seq, hsr({ mana = 100, mana_regen = 20 }), { now = 0, horizon_s = 30 })
        assert_eq(#tl.collected, 1, "regen made it affordable")
    end)

    it("HP gate trips only below the floor, not on a safe (hp_cost~0) hop", function()
        local safe = { ctg(900, 60, 1, 0, 0) }
        local hurt = { ctg(900, 60, 1, 0, 300) }   -- hp 250 - 300 = -50 < floor 100
        local hs = hsr({ hp = 250, max_hp = 600, hp_regen = 0, hp_floor = 100 })
        assert_eq(#Route._timeline(safe, hs, { now = 0, horizon_s = 30 }).collected, 1, "safe hop ok")
        assert_eq(#Route._timeline(hurt, hs, { now = 0, horizon_s = 30 }).collected, 0, "hp would drop below floor")
    end)
end)

describe("lib/route -- refill node (Note 4)", function()
    local function hsr(over)
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {},
                     mana = 100, max_mana = 400, mana_regen = 0, reserve_mana = 0 }
        for k, v in pairs(over or {}) do hs[k] = v end
        return hs
    end

    it("a refill node tops mana to refill_frac*max and adds no gold", function()
        -- start mana 100; cost-200 hop unaffordable; refill (frac 1.0) -> 400; then affordable
        local refill = { pos = { x = 300, y = 0 }, value = 0, clear_t = 2, restore = true }
        local ancient = { pos = { x = 600, y = 0 }, value = 160, clear_t = 3, mana_cost = 200 }
        local nofill = Route._timeline({ ancient }, hsr(), { now = 0, horizon_s = 60, refill_frac = 1 })
        assert_eq(#nofill.collected, 0, "unaffordable without a refill")
        local withfill = Route._timeline({ refill, ancient }, hsr(), { now = 0, horizon_s = 60, refill_frac = 1 })
        assert_eq(#withfill.collected, 2, "refill then ancient")
        assert_eq(withfill.gold, 160, "refill adds 0 gold; ancient adds 160")
    end)

    it("refill is COST-AWARE: tops up past refill_frac to the NEXT target's need (ancient arc)", function()
        local refill = { pos = { x = 300, y = 0 }, value = 0, clear_t = 0, restore = true }
        local hop = { pos = { x = 600, y = 0 }, value = 50, clear_t = 0, mana_cost = 300 }
        -- frac 0.7 -> 400*0.7 = 280 < 300, but the refill sees the next node needs 300 -> fills to 300
        local tl = Route._timeline({ refill, hop }, hsr(), { now = 0, horizon_s = 60, refill_frac = 0.7 })
        assert_eq(#tl.collected, 2, "refill fills to the next target's cost; hop affordable")
    end)

    it("cost-aware refill includes the reserve and caps at max_mana", function()
        local refill = { pos = { x = 300, y = 0 }, value = 0, clear_t = 0, restore = true }
        local hop = { pos = { x = 600, y = 0 }, value = 50, clear_t = 0, mana_cost = 350 }
        -- need = 350 + reserve 60 = 410 > max 400 -> capped at 400 < 410 -> still unaffordable
        local tl = Route._timeline({ refill, hop }, hsr({ reserve_mana = 60 }),
                                   { now = 0, horizon_s = 60, refill_frac = 0.7 })
        assert_eq(#tl.collected, 1, "pool cannot cover cost+reserve even full: only the refill")
        -- reserve 40 -> need 390 <= 400 -> fills to 390, hop affordable
        local tl2 = Route._timeline({ refill, hop }, hsr({ reserve_mana = 40 }),
                                    { now = 0, horizon_s = 60, refill_frac = 0.7 })
        assert_eq(#tl2.collected, 2, "fills to cost+reserve within the pool")
    end)
end)

describe("lib/route -- Plan with refill node (Note 4)", function()
    local function hsr(over)
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {},
                     mana = 120, max_mana = 400, mana_regen = 0, reserve_mana = 0 }
        for k, v in pairs(over or {}) do hs[k] = v end
        return hs
    end

    it("inserts the refill when it unlocks a downstream prize", function()
        local near    = { kind = "camp", pos = { x = 300, y = 0 }, value = 40, clear_t = 1, mana_cost = 60 }
        local ancient = { kind = "camp", pos = { x = 900, y = 0 }, value = 200, clear_t = 2, mana_cost = 200 }
        local refill  = { kind = "refill", pos = { x = 0, y = 0 }, value = 0, clear_t = 2, restore = true }
        local plan = Route.Plan({ near, ancient, refill }, hsr(),
                                { now = 0, horizon_s = 120, max_steps = 4, risk_weight = 0, refill_frac = 1 })
        local hasRefill = false
        for _, s in ipairs(plan.steps) do if s.restore then hasRefill = true end end
        assert_true(hasRefill, "refill routed in to unlock the ancient")
        assert_true(plan.gold >= 240, "near 40 + ancient 200 collected after refill")
    end)

    it("omits the refill when the chain is already affordable", function()
        local a = { kind = "camp", pos = { x = 300, y = 0 }, value = 40, clear_t = 1, mana_cost = 30 }
        local b = { kind = "camp", pos = { x = 600, y = 0 }, value = 40, clear_t = 1, mana_cost = 30 }
        local refill = { kind = "refill", pos = { x = 0, y = 0 }, value = 0, clear_t = 2, restore = true }
        local plan = Route.Plan({ a, b, refill }, hsr({ mana = 400 }),
                                { now = 0, horizon_s = 120, max_steps = 4, risk_weight = 0, refill_frac = 1 })
        for _, s in ipairs(plan.steps) do assert_true(not s.restore, "no wasteful refill") end
    end)

    it("the refill node survives the pool_cap trim even with value 0", function()
        local hs = hsr({ mana = 50 })
        local targets = { { kind = "refill", pos = { x = 0, y = 0 }, value = 0, clear_t = 1, restore = true } }
        for i = 1, 15 do   -- 15 cheap normals + 1 refill, pool_cap default 10
            targets[#targets + 1] = { kind = "camp", pos = { x = 200 + i * 50, y = 0 }, value = 10, clear_t = 1, mana_cost = 200 }
        end
        local plan = Route.Plan(targets, hs, { now = 0, horizon_s = 120, max_steps = 4, risk_weight = 0, refill_frac = 1 })
        -- with mana 50 every camp (cost 200) needs a refill first; if the trim dropped the refill, gold would be 0
        local hasRefill = false
        for _, s in ipairs(plan.steps) do if s.restore then hasRefill = true end end
        assert_true(hasRefill, "refill retained through the trim")
    end)

    it("#3: the pool_cap trim ranks by risk-adjusted value (a close risky camp does not crowd out a safer one)", function()
        local hs = { pos = { x = 0, y = 0 }, move_speed = 300 }
        local targets = {}
        for i = 1, 11 do   -- 11 close high-value RISKY camps: net = 100 - 70*0.3 = 79
            targets[i] = { kind = "camp", pos = { x = 300 + i * 20, y = 0 }, value = 100, risk = 0.3, clear_t = 25 }
        end                -- + 1 safe lower-value camp: net = 90. 12 > pool_cap 10 -> trim; clear_t 25 -> only one fits 30s.
        targets[12] = { kind = "camp", pos = { x = 320, y = 0 }, value = 90, clear_t = 25 }
        local plan = Route.Plan(targets, hs, { now = 0, horizon_s = 30, max_steps = 4, risk_weight = 70 })
        assert_eq(#plan.steps, 1, "only one camp fits the horizon")
        -- value-only trim would drop the value-90 safe camp (all value-100 risky rank higher) and pick a
        -- risky one; the risk-adjusted trim keeps the safe camp (net 90 > 79) so it wins the single slot.
        assert_true((plan.steps[1].risk or 0) == 0, "the safer camp survived the trim and won on risk-adjusted value")
    end)
end)

describe("lib/route -- time-decay value (wave urgency)", function()
    local hs = { pos = { x = 0, y = 0 }, move_speed = 300, tp = nil, anchors = {} }

    it("a decaying target is worth less collected later (age from born)", function()
        local seq = { { pos = { x = 900, y = 0 }, value = 100, clear_t = 0, decay_per_s = 8, value_floor = 50, born = 0 } }
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 30 })   -- leg 3s -> 100 - 8*3 = 76
        assert_true(math.abs(tl.gold - 76) < 1e-6, "100 - 8*3 = 76 at collection t=3")
    end)

    it("the planner orders a decaying wave BEFORE a constant camp", function()
        local camp = { kind = "camp", pos = { x = 300, y = 0 }, value = 100, clear_t = 1 }
        local wave = { kind = "wave", pos = { x = 300, y = 0 }, value = 100, clear_t = 1, decay_per_s = 20, value_floor = 0, born = 0 }
        local plan = Route.Plan({ camp, wave }, hs, { now = 0, horizon_s = 30, max_steps = 4, risk_weight = 0 })
        assert_true(plan.steps[1] == wave, "take the decaying wave first; the camp keeps its value")
    end)

    it("decay floors at value_floor for a stale target", function()
        local seq = { { pos = { x = 9000, y = 0 }, value = 100, clear_t = 0, decay_per_s = 50, value_floor = 30, born = 0 } }
        local tl = Route._timeline(seq, hs, { now = 0, horizon_s = 60 })   -- leg 30s -> 100-1500 floored 30
        assert_eq(tl.gold, 30)
    end)
end)

describe("lib/escape - BlinkInLanding", function()
    Vector = Vector or function(x, y, z) return { x = x, y = y, z = z } end
    Heroes = Heroes or {}
    Heroes.GetAll = function() return {} end
    Heroes.InRadius = function() return {} end
    -- Entity.GetTeamNum is called by FogSnapshot; stub so it returns a team
    -- number without erroring. Heroes.GetAll returns {} so no enemy loop runs.
    Entity.GetTeamNum = Entity.GetTeamNum or function() return 2 end
    local Escape = require("lib.escape")
    local me = { pos = { x = 0, y = 0, z = 0 } }

    it("lands at the near edge of engage range, reachable, within blink range", function()
        local aim = { x = 1000, y = 0, z = 0 }
        local landing, risk, reachable = Escape.BlinkInLanding(me, aim, 1200, 700, { margin = 50 })
        assert_true(reachable, "should be reachable")
        assert_true(type(risk) == "number", "risk is a number")
        assert_true(math.abs(landing.x - 350) < 1, "landing.x near 350, got " .. tostring(landing.x))
        assert_true(landing.x <= 1200, "within blink range")
    end)

    it("target beyond blink+engage reach -> not reachable", function()
        local aim = { x = 3000, y = 0, z = 0 }
        local landing, _, reachable = Escape.BlinkInLanding(me, aim, 1200, 700, {})
        assert_false(reachable, "should NOT be reachable")
        assert_true(math.abs(landing.x - 1200) < 1, "lands at max blink reach 1200")
    end)

    it("nil args -> nil landing, not reachable", function()
        local landing, _, reachable = Escape.BlinkInLanding(me, nil, 1200, 700, {})
        assert_true(landing == nil, "nil landing")
        assert_false(reachable, "not reachable")
    end)
end)

describe("lib/escape - SafestSpotNear dual-winner (Phase B)", function()
    local Escape = require("lib.escape")
    local me = {}   -- Entity.GetAbsOrigin stub returns {0,0,0} for a posless entity
    -- Drive a deterministic risk field + terrain mask; restore globals after.
    local function with_field(scores, blocked, fn)
        local s_ars, s_fs, s_grid = Escape.AdvanceRiskScore, Escape.FogSnapshot, GridNav
        Escape.FogSnapshot      = function() return { heroes = {} } end
        Escape.AdvanceRiskScore = function(_me, p) return scores(p) end
        GridNav = { IsTraversableFromTo = function(_a, b) return not blocked(b) end }
        local ok, err = pcall(fn)
        Escape.AdvanceRiskScore, Escape.FogSnapshot, GridNav = s_ars, s_fs, s_grid
        if not ok then error(err, 2) end
    end

    it("terrain-locked spot is safest -> best_pos locked, info reports it", function()
        with_field(function(p) return (p.x > 600) and 1 or 100 end,
                   function(p) return p.x > 600 end, function()
            local best, score, info = Escape.SafestSpotNear(me, 700)
            assert_true(best.x > 600, "best_pos is the locked safe spot")
            assert_true(info.locked, "info.locked true")
            assert_false(info.traversable, "best not traversable")
            assert_true(info.walkable_score >= 100, "walkable best is safe-less ground")
            assert_true((info.walkable_score - score) >= 20, "locked is margin-safer")
        end)
    end)

    it("all-walkable -> best_pos == walkable, not locked", function()
        with_field(function(p) return (p.y > 600) and 1 or 50 end,
                   function() return false end, function()
            local best, _score, info = Escape.SafestSpotNear(me, 700)
            assert_false(info.locked, "not locked")
            assert_true(info.traversable, "traversable")
            assert_true(best.x == info.walkable_pos.x and best.y == info.walkable_pos.y,
                        "best_pos == walkable_pos")
        end)
    end)

    it("nil args -> nil, huge, nil", function()
        local best, score, info = Escape.SafestSpotNear(nil, 700)
        assert_true(best == nil and info == nil, "nil best + info")
        assert_true(score == math.huge, "huge score")
    end)
end)

describe("lib/escape - PostAirborneMoveTick recompute_dest (Phase B)", function()
    local Escape = require("lib.escape")
    local me = { pos = { x = 0, y = 0, z = 0 } }
    local s_hasmod = NPC.HasModifier
    NPC.HasModifier = function() return true end   -- FC modifier present (airborne window)
    local function make_cfg(cap)
        return { now = function() return 100.0 end, hero_key = "lina", layer = "def",
                 safe_issue = function(o) cap.pos = o.position end, tlog = nil }
    end

    it("recompute_dest overrides the dest each reissue", function()
        local cap = {}
        local pending = {
            dest = Vector(500, 0, 0), modifier_name = "modifier_lina_flame_cloak",
            moves_during_airborne = true, deadline = 107, intent = "fc_escape",
            observed_airborne = false, last_reissue_t = 0, reissue_seq = 0,
            recompute_dest = function() return Vector(900, 0, 0) end,
        }
        local p = Escape.PostAirborneMoveTick(me, pending, make_cfg(cap))
        assert_true(p ~= nil, "still pending")
        assert_true(cap.pos and cap.pos.x == 900,
            "reissued to recomputed dest, got " .. tostring(cap.pos and cap.pos.x))
    end)

    it("no recompute_dest, no threat_caster -> dest frozen", function()
        local cap = {}
        local pending = {
            dest = Vector(500, 0, 0), modifier_name = "modifier_lina_flame_cloak",
            moves_during_airborne = true, deadline = 107, intent = "ww",
            observed_airborne = false, last_reissue_t = 0, reissue_seq = 0,
        }
        Escape.PostAirborneMoveTick(me, pending, make_cfg(cap))
        assert_true(cap.pos and cap.pos.x == 500, "dest unchanged (frozen)")
    end)

    NPC.HasModifier = s_hasmod   -- restore the global stub after the block
end)

describe("lib/escape - ChaseWindow (Phase C)", function()
    Vector = Vector or function(x, y, z) return { x = x, y = y, z = z } end
    local Escape = require("lib.escape")
    local me  = { x = 0,   y = 0, z = 0 }
    local tgt = { x = 400, y = 0, z = 0 }   -- 400u east of Lina

    it("catch-ETA = straight dist / fly_speed", function()
        local w = Escape.ChaseWindow(me, tgt, { x = 0, y = 0 }, { fly_speed = 400, kill_reach = 2000 })
        assert_true(math.abs(w.catch_eta - 1.0) < 1e-6, "400u / 400ms = 1.0s, got " .. tostring(w.catch_eta))
    end)

    it("out-of-reach ETA: target fleeing east exits kill_reach", function()
        -- target at 400, fleeing +x at 300/s, kill_reach 1000 from me(0): exits at (1000-400)/300 = 2.0s
        local w = Escape.ChaseWindow(me, tgt, { x = 300, y = 0 }, { fly_speed = 400, kill_reach = 1000 })
        assert_true(math.abs(w.escape_eta - 2.0) < 1e-6, "out-of-reach 2.0s, got " .. tostring(w.escape_eta))
    end)

    it("protection ETA wins when a tower is closer than out-of-reach", function()
        -- tower at (700,0) range 300 -> target reaches its rim (700-300=400) at (400-400)/300 = 0.0s? place tower farther:
        -- tower center (1300,0) range 300 -> rim at 1000; target reaches 1000 at (1000-400)/300 = 2.0s; out-of-reach 2000 -> later
        local w = Escape.ChaseWindow(me, tgt, { x = 300, y = 0 },
            { fly_speed = 400, kill_reach = 5000, tower_circles = { { pos = { x = 1300, y = 0 }, range = 300 } } })
        assert_true(math.abs(w.escape_eta - 2.0) < 1e-6, "protection 2.0s, got " .. tostring(w.escape_eta))
    end)

    it("stationary target never out of reach -> escape_eta huge", function()
        local w = Escape.ChaseWindow(me, tgt, { x = 0, y = 0 }, { fly_speed = 400, kill_reach = 1000 })
        assert_true(w.escape_eta == math.huge, "no flee -> never escapes, got " .. tostring(w.escape_eta))
    end)

    it("nil args -> nil", function()
        assert_true(Escape.ChaseWindow(nil, tgt, { x = 0, y = 0 }, {}) == nil, "nil me -> nil")
    end)
end)

describe("lib/escape - CutoffLock (Phase C2)", function()
    local Escape = require("lib.escape")
    local me = { x = 0, y = 0, z = 0 }
    local ip = { x = 1000, y = 0, z = 0 }   -- straight = 1000

    it("big detour walk -> locked", function()
        local path = { { x = 0, y = 0 }, { x = 0, y = 900 }, { x = 1000, y = 900 }, { x = 1000, y = 0 } } -- 900+1000+900=2800
        local r = Escape.CutoffLock(me, ip, path, { ratio = 1.3, min_gain = 250 })
        assert_true(r.locked, "walk 2800 vs straight 1000 should lock, got walk=" .. tostring(r.walk))
    end)

    it("straight walk -> not locked", function()
        local r = Escape.CutoffLock(me, ip, { { x = 0, y = 0 }, { x = 1000, y = 0 } }, { ratio = 1.3, min_gain = 250 })
        assert_true(not r.locked, "walk == straight must not lock")
    end)

    it("short detour under min_gain -> not locked", function()
        -- me->(100,0): walk (0,0)->(0,80)->(100,80)->(100,0) = 80+100+80=260; straight 100; ratio 2.6 but gain 160 < 250
        local r = Escape.CutoffLock(me, { x = 100, y = 0 },
            { { x = 0, y = 0 }, { x = 0, y = 80 }, { x = 100, y = 80 }, { x = 100, y = 0 } },
            { ratio = 1.3, min_gain = 250 })
        assert_true(not r.locked, "gain 160 < min 250 must not lock")
    end)

    it("nil walk_path -> not locked", function()
        local r = Escape.CutoffLock(me, ip, nil, {})
        assert_true(not r.locked, "no path -> not locked")
    end)

    it("nil me_pos -> not locked (safe)", function()
        local r = Escape.CutoffLock(nil, ip, { { x = 0, y = 0 }, { x = 1, y = 0 } }, {})
        assert_true(not r.locked, "nil me -> not locked")
    end)
end)

describe("lib/escape - MissingCount", function()
    local E = require("lib.escape")
    it("counts fogged (visible=false) enemies", function()
        local snap = { heroes = { { visible = true }, { visible = false }, { visible = false } } }
        assert_eq(E.MissingCount(snap), 2)
    end)
    it("all visible -> 0", function()
        assert_eq(E.MissingCount({ heroes = { { visible = true }, { visible = true } } }), 0)
    end)
    it("empty / nil -> 0", function()
        assert_eq(E.MissingCount({}), 0); assert_eq(E.MissingCount(nil), 0)
    end)
end)

describe("lib/escape - ReachableFog", function()
    local E = require("lib.escape")
    local O = { radius = 1000, reach_cap = 450, fresh_s = 1.5 }
    it("counts a FRESH fogged enemy whose capped disc reaches pos", function()
        -- age 1.0 <= 1.5; disc min(550,450)=450; d 1400 - 450 = 950 <= 1000
        local snap = { heroes = { { visible = false, age = 1.0, probable_radius = 550, pos = { x = 1400, y = 0 } } } }
        assert_eq(E.ReachableFog(snap, { x = 0, y = 0 }, O), 1)
    end)
    it("EXCLUDES a stale fogged enemy (age > fresh_s)", function()
        local snap = { heroes = { { visible = false, age = 3.0, probable_radius = 1650, pos = { x = 1400, y = 0 } } } }
        assert_eq(E.ReachableFog(snap, { x = 0, y = 0 }, O), 0)
    end)
    it("EXCLUDES a fresh enemy too far even with the disc", function()
        -- d 2000 - min(275,450)=275 = 1725 > 1000
        local snap = { heroes = { { visible = false, age = 0.5, probable_radius = 275, pos = { x = 2000, y = 0 } } } }
        assert_eq(E.ReachableFog(snap, { x = 0, y = 0 }, O), 0)
    end)
    it("ignores VISIBLE enemies (they are not fog)", function()
        local snap = { heroes = { { visible = true, pos = { x = 100, y = 0 } } } }
        assert_eq(E.ReachableFog(snap, { x = 0, y = 0 }, O), 0)
    end)
    it("nil-safe", function()
        assert_eq(E.ReachableFog(nil, { x = 0, y = 0 }, O), 0)
        assert_eq(E.ReachableFog({}, { x = 0, y = 0 }, O), 0)
    end)
end)

describe("lib/escape - FogProximityRisk", function()
    local Escape = require("lib.escape")
    -- Vector stub with Distance2D (the file's base Vector stub lacks it).
    local function Vec(x, y)
        return { x = x, y = y, z = 0,
                 Distance2D = function(self, o)
                     local dx, dy = self.x - o.x, self.y - o.y
                     return math.sqrt(dx * dx + dy * dy)
                 end }
    end
    local OPTS = { risk_radius = 1400, fog_ms = 550, fog_spread = 900, age_cap = 5 }
    local function snap(heroes) return { t = 0, heroes = heroes } end

    it("no enemies -> 0", function()
        assert_eq(Escape.FogProximityRisk(snap({}), Vec(0, 0), OPTS), 0)
    end)

    it("visible enemy == (1 - d/risk_radius)^2 (continuity)", function()
        local pt = Vec(0, 0)
        local h = { pos = Vec(700, 0), age = 0, probable_radius = 0, visible = true }
        local r = 1 - 700 / 1400
        assert_true(math.abs(Escape.FogProximityRisk(snap({ h }), pt, OPTS) - r * r) < 1e-9,
            "visible must match the plain proximity falloff")
    end)

    it("recently-fogged enemy near pt scores high", function()
        -- last seen 400u away 2s ago: disc radius 1100 reaches well past pt,
        -- edge = max(0, 400 - 1100) = 0 -> base 1; conf = 900/(900+1100) = 0.45
        local h = { pos = Vec(400, 0), age = 2, probable_radius = 0, visible = false }
        local got = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS)
        assert_true(got > 0.4, "near recent fog should score high, got " .. got)
    end)

    it("stale (but within cap) fog scores lower than fresh (decay bites)", function()
        local near = Vec(400, 0)
        local fresh = { pos = near, age = 1, probable_radius = 0, visible = false }
        local stale = { pos = near, age = 5, probable_radius = 0, visible = false }
        local rf = Escape.FogProximityRisk(snap({ fresh }), Vec(0, 0), OPTS)
        local rs = Escape.FogProximityRisk(snap({ stale }), Vec(0, 0), OPTS)
        assert_true(rs < rf, "older fog must decay below fresher, fresh=" .. rf .. " stale=" .. rs)
    end)

    it("weight_fn scales a hero's risk (0.5 halves it)", function()
        local h = { pos = Vec(700, 0), age = 0, probable_radius = 0, visible = true }
        local plain = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS)
        local opts2 = { risk_radius = 1400, fog_ms = 550, fog_spread = 900, age_cap = 5,
                        weight_fn = function(_) return 0.5 end }
        local weighted = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), opts2)
        assert_true(math.abs(weighted - plain * 0.5) < 1e-9, "weight 0.5 must halve, got " .. weighted)
    end)
    it("absent weight_fn is unchanged (regression guard)", function()
        local h = { pos = Vec(700, 0), age = 0, probable_radius = 0, visible = true }
        local r = 1 - 700 / 1400
        assert_true(math.abs(Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS) - r * r) < 1e-9,
            "no weight_fn must equal the plain falloff")
    end)

    it("age beyond age_cap contributes 0", function()
        local h = { pos = Vec(100, 0), age = 6, probable_radius = 0, visible = false }
        assert_eq(Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS), 0)
    end)

    it("takes the max over enemies", function()
        local far = { pos = Vec(1300, 0), age = 0, probable_radius = 0, visible = true }
        local near = { pos = Vec(200, 0), age = 0, probable_radius = 0, visible = true }
        local both = Escape.FogProximityRisk(snap({ far, near }), Vec(0, 0), OPTS)
        local solo = Escape.FogProximityRisk(snap({ near }), Vec(0, 0), OPTS)
        assert_true(math.abs(both - solo) < 1e-9, "max enemy must dominate")
    end)

    ------------------------------------------------------------------------
    -- COMMIT RISK v2, GROUP A: the mechanism assumptions this feature rests on.
    --
    -- The commit-risk feature is RADIUS WIDENING: r_eff = risk_radius + widen,
    -- expressed purely as a larger opts.risk_radius passed into this UNMODIFIED
    -- function, so lib/escape.lua gains zero modified lines. That makes Group A
    -- guard rails rather than tests of the diff: no mutation of the commit-risk
    -- code can fail them. They exist because the alternative mechanism
    -- (edge subtraction, `edge - widen`) is the one that was measured to stop
    -- the bot farming, and nothing in the reverted v0.1.357 suite could tell
    -- the two apart. They also kill mutations of FogProximityRisk itself, which
    -- IS live code a later edit can break.
    --
    -- NOT WRITTEN, deliberately (design 7 A6): `assert(risk <= 1.0)`. That
    -- assertion is both vacuous and FALSE. weight_fn is applied unbounded at
    -- lib/escape.lua:910, so d = 0 with weight 1.15 scores exactly 1.150 and
    -- the docstring's "@return number risk 0..1" at :873 is already inaccurate.
    -- v0.1.357 shipped that assertion and counted it as mutation-verified.
    -- A2's grid pins 1.15 at d = 0 instead, which is the same fact with teeth.
    ------------------------------------------------------------------------

    it("A1 widen 0 is bit-identical to today: risk_radius 1400 == 1400 + 0 (ZERO KILL POWER, disclosed)", function()
        -- The formal statement of inertness for the 21 reads that pass no widen.
        -- Exactness is structural (IEEE-754 x + 0.0 == x for every finite x), so
        -- an epsilon here would be weaker than the code deserves. This is what
        -- makes COMMIT_APPROACH_SPEED = 0 a genuine no-code-edit rollback.
        --
        -- VACUOUS BY CONSTRUCTION, and titled so it cannot be miscounted (the
        -- same rule TV-4 applies to B8). `1400` and `1400 + 0` are the identical
        -- Lua value and subtype, so this is f(x) == f(x): a 28-mutation harness
        -- run tied it to nothing, and nothing can. The property it states lives
        -- in Tinker.lua, not here, and B15 is where a mutation of it dies.
        local w0 = { risk_radius = 1400 + 0, fog_ms = 550, fog_spread = 900, age_cap = 5 }
        local hs = {
            { pos = Vec(0, 0),    age = 0, probable_radius = 0, visible = true },
            { pos = Vec(713, 91), age = 0, probable_radius = 0, visible = true },
            { pos = Vec(-1200, 400), age = 2.5, probable_radius = 0, visible = false },
            { pos = Vec(2600, -1700), age = 0, probable_radius = 0, visible = true },
        }
        for i = 1, #hs do
            for _, pt in ipairs({ Vec(0, 0), Vec(500, 500), Vec(-900, 1200), Vec(3000, 3000) }) do
                local a = Escape.FogProximityRisk(snap({ hs[i] }), pt, OPTS)
                local b = Escape.FogProximityRisk(snap({ hs[i] }), pt, w0)
                assert_true(a == b, "widen 0 must be bit-identical, got " .. a .. " vs " .. b)
            end
        end
    end)

    it("A2 visible closed form over d x widen x weight: (1 - d/(1400+W))^2 * w", function()
        -- Kills MECH_edge_sub (which pins 1.0 across the whole near field),
        -- MECH_divisor_only, MECH_guard_only, MECH_sign_flip, RISK_clamped_to_1
        -- (the d=0 / weight 1.15 cell is exactly 1.15, above 1.0) and
        -- WEIGHT_fn_dropped.
        for _, d in ipairs({ 0, 200, 400, 700, 1000, 1400, 2000, 3000 }) do
            for _, W in ipairs({ 0, 300, 1400, 3500 }) do
                for _, wt in ipairs({ 1, 0.6, 1.15 }) do
                    local r_eff = 1400 + W
                    local want = 0
                    if d < r_eff then
                        local r = 1 - d / r_eff
                        want = r * r * wt
                    end
                    local o = { risk_radius = r_eff, fog_ms = 550, fog_spread = 900, age_cap = 5,
                                weight_fn = function(_) return wt end }
                    local h = { pos = Vec(d, 0), age = 0, probable_radius = 0, visible = true }
                    local got = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), o)
                    assert_true(math.abs(got - want) < 1e-12,
                        ("d=%d W=%d w=%s: got %.17g want %.17g"):format(d, W, tostring(wt), got, want))
                end
            end
        end
    end)

    it("A3 SATURATION GUARD: widening never flattens the near field", function()
        -- THE test that discriminates radius widening from edge subtraction, and
        -- the one the reverted suite did not have. Under `edge - widen` at W=3500
        -- every one of these distances scores exactly 1.000: monotone-but-equal,
        -- veto everywhere, zero ranking information (measured: 1 distinct value
        -- over d = 0..1400 in 10u steps, against 141 for radius widening).
        -- srisk ranks mid vs side off this number, so a flat near field breaks
        -- ranking as well as vetoing.
        -- Kept even though A2 strictly implies it: A2 is a closed form that any
        -- legitimate future model change forces someone to rewrite, and the
        -- temptation then is to loosen it. A3 asserts a property that survives
        -- ANY monotone falloff.
        local o = { risk_radius = 1400 + 3500, fog_ms = 550, fog_spread = 900, age_cap = 5 }
        local function risk_at(d)
            local h = { pos = Vec(d, 0), age = 0, probable_radius = 0, visible = true }
            return Escape.FogProximityRisk(snap({ h }), Vec(0, 0), o)
        end
        local ds = { 0, 200, 700, 1400, 2000 }
        local point_blank = risk_at(0)
        local prev
        for i = 1, #ds do
            local r = risk_at(ds[i])
            if prev then
                assert_true(prev - r > 0.01,
                    ("adjacent distances must stay DISTINGUISHABLE: d=%d %.4f vs d=%d %.4f")
                        :format(ds[i - 1], prev, ds[i], r))
            end
            if ds[i] > 0 then
                assert_true(r < point_blank,
                    ("d=%d must stay strictly BELOW point-blank: %.4f vs %.4f")
                        :format(ds[i], r, point_blank))
            end
            prev = r
        end
    end)

    it("A4 fog closed form over d x age x widen: the widening never touches the edge", function()
        -- radius = age*fog_ms is a POSITION correction (where the enemy could be
        -- now); risk_radius is the kernel BANDWIDTH (how far away an enemy still
        -- matters). Putting the widen into the edge double-counts it as a
        -- position and saturates, which is edge subtraction under another name.
        -- conf depends only on age and fog_ms, neither of which the widen
        -- touches, so it must ride along multiplicatively and unchanged.
        -- Kills WIDEN_visible_only, WIDEN_fogged_only, WIDEN_into_conf.
        for _, d in ipairs({ 0, 400, 1000, 1400, 2000, 3000 }) do
            for _, age in ipairs({ 0, 0.5, 2, 5 }) do
                for _, W in ipairs({ 0, 300, 1400, 3500 }) do
                    local r_eff = 1400 + W
                    local radius = age * 550
                    local edge = d - radius
                    if edge < 0 then edge = 0 end
                    local base = 0
                    if edge < r_eff then
                        local r = 1 - edge / r_eff
                        base = r * r
                    end
                    local want = base * (900 / (900 + radius))
                    local o = { risk_radius = r_eff, fog_ms = 550, fog_spread = 900, age_cap = 5 }
                    local h = { pos = Vec(d, 0), age = age, probable_radius = 0, visible = false }
                    local got = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), o)
                    assert_true(math.abs(got - want) < 1e-12,
                        ("d=%d age=%s W=%d: got %.17g want %.17g"):format(d, tostring(age), W, got, want))
                end
            end
        end
    end)

    it("A5 the widen must reach BOTH the guard and the divisor: risk(1500) > 0 at W=1400", function()
        -- The one-line-change trap. risk_radius is read at exactly two live
        -- sites, the guard at :905 and the divisor at :906. Widen only the
        -- divisor and every edge in [1400, r_eff) still takes base = 0, so the
        -- widening does nothing past 1400u: the exact defect being fixed,
        -- surviving with a green near-field suite. Kills MECH_divisor_only.
        local o = { risk_radius = 1400 + 1400, fog_ms = 550, fog_spread = 900, age_cap = 5 }
        local h = { pos = Vec(1500, 0), age = 0, probable_radius = 0, visible = true }
        local got = Escape.FogProximityRisk(snap({ h }), Vec(0, 0), o)
        assert_true(got > 0, "an enemy at 1500u must score above 0 once the radius is widened to 2800")
        assert_eq(Escape.FogProximityRisk(snap({ h }), Vec(0, 0), OPTS), 0,
            "and must still score exactly 0 unwidened (that IS the defect)")
    end)
end)

describe("lib/escape - CommitWiden (commit risk v2, group B)", function()
    local Escape = require("lib.escape")
    local CW = Escape.CommitWiden

    it("B1 nominal: 50 u/s over travel 4.4 + stand 4.0 is exactly 420u", function()
        -- The shipped median shove commit (travel= 4.4 is the keened clamp, on
        -- 25 of 73 g356 commits). Kills a wrong speed factor, either term being
        -- dropped, and a cap inversion (math.max(cap, ...) instead of min).
        assert_eq(CW(4.4, 4.0, 50, 2000), 420)
    end)

    it("B2 TRANSIT sample: stand 0 keeps the travel term and only the travel term", function()
        -- Kills TRAVEL_term_dropped (the second call would read 0) and
        -- ADDITIVE_floor (a `math.max(floor, w)` would lift the first off 0).
        assert_eq(CW(0, 0, 50, 2000), 0)
        assert_eq(CW(10, 0, 50, 2000), 500)
    end)

    it("B3 STAND only: travel 0 still widens by the stand term (arrival, not transit)", function()
        assert_eq(CW(0, 4.0, 50, 2000), 200)   -- kills STAND_term_dropped
    end)

    it("B4 nil travel coalesces to 0, it does not throw", function()
        assert_eq(CW(nil, 4.0, 50, 2000), 200) -- kills TRAVEL_nilcoalesce_dropped
    end)

    it("B5 nil stand coalesces to 0, it does not throw", function()
        -- 50 * 4.4 is 220.00000000000002842 in IEEE-754 doubles, measured on the
        -- deployed Lua 5.4, so the design's `== 220` is not attainable and the
        -- epsilon is the float, not a loosened assertion. Kill power is
        -- unaffected: STAND_nilcoalesce_dropped is an arithmetic-on-nil throw,
        -- not a small numeric drift.
        assert_true(math.abs(CW(4.4, nil, 50, 2000) - 220) < 1e-9,
            "nil stand must coalesce to 0, got " .. tostring(CW(4.4, nil, 50, 2000)))
    end)

    it("B6 nil approach_speed reads as OFF, not as an arithmetic error", function()
        assert_eq(CW(4.4, 4.0, nil, 2000), 0)  -- kills SPEED_nilcoalesce_dropped
    end)

    it("B7 NEGATIVE approach_speed is clamped to 0, never to a SHRINKING widen", function()
        -- The case the reverted build left uncovered. "approach_speed 0 disables
        -- it" cannot fail on the `<= 0` guard because 0 * exposure is 0 anyway
        -- (see B8); a NEGATIVE speed is the input that has teeth, because an
        -- unguarded -50 gives widen -420, r_eff = 1400 + widen SHRINKS every
        -- danger radius, and the bot goes blind rather than cautious, silently
        -- and exactly backwards.
        --
        -- THE GUARD IS KILLABLE AND THE FOURTH SIGN CELL IS WHAT KILLS IT.
        -- Earlier revisions of this comment recorded the guard as an EQUIVALENT
        -- MUTANT ("no test can kill it through the return value") because
        -- math.max(0, w) absorbs a negative product and `or 0` absorbs nil.
        -- That is true of three of the four sign cells and false of the fourth:
        -- with speed AND exposure both negative the product turns POSITIVE,
        -- math.max passes it through untouched, and the guard is the only thing
        -- refusing it. Measured against the harness, not argued:
        --      shipped                        -> 0
        --      `<= 0` mutated to `== 0`       -> 420.0   (suite 854/1, FAIL B7)
        --      guard deleted outright         -> 420.0   (suite 854/1, FAIL B7)
        -- Re-measured after the cap sanitise landed; the totals track the suite
        -- size (they read 852/1 when it was 853 tests), the 420.0 and the FAIL
        -- do not. The kill is NOT a side effect of sanitising the cap either:
        -- the killing cell passes the perfectly valid cap 2000, so the sanitise
        -- is a no-op on it and the fourth sign cell alone does the work.
        -- The wrong comment was the more dangerous half: it instructed the next
        -- reader that the hole could not be closed, so it would not have been.
        -- The redundancy pair is still covered from both sides: B12 kills the
        -- clamp alone, B7 kills guard-and-clamp dropped together.
        assert_eq(CW(4.4, 4.0, -50, 2000), 0)
        assert_eq(CW(4.4, 4.0, -1e-9, 2000), 0)
        assert_eq(CW(-4.4, -4.0, 50, 2000), 0)   -- negative EXPOSURE, the clamp's own path
        assert_eq(CW(-4.4, -4.0, -50, 2000), 0)  -- 4th sign cell: neg x neg = +420 past the clamp
        assert_eq(CW(-10, 0, -50, 2000), 0)      -- same, single term
        assert_true(CW(4.4, 4.0, -50, 2000) >= 0, "widen must never be negative")
    end)

    it("B8 zero approach_speed is the no-code-edit kill switch (ZERO KILL POWER, disclosed)", function()
        -- 0 * exposure is 0 with or without the guard, so NO mutation of the
        -- guard can fail this test. It is a contract statement pinning the
        -- documented rollback path, and it must never be counted toward a
        -- mutation-verified claim. Recorded here because v0.1.357 counted it.
        assert_eq(CW(5000, 4.0, 0, 2000), 0)
    end)

    it("B9 the cap binds when exposure runs past it", function()
        assert_eq(CW(100, 0, 50, 2000), 2000)  -- kills CAP_dropped
    end)

    it("B10 nil cap is UNCAPPED and cap 0 is ZERO widen (not the v0.1.357 footgun)", function()
        -- v0.1.357 shipped `widen_max = 0 means uncapped`, so a config typo of 0
        -- produced an unbounded widen: a footgun pointing the dangerous way.
        -- `widen_max or math.huge` makes nil uncapped and 0 zero, which is what
        -- the parameter name says. (The design's B10 row asserts > 100000 on
        -- args that yield 50000; the arithmetic there is a slip. Pinned exactly
        -- instead, plus "past the shipped cap", which is the property meant.)
        assert_eq(CW(1000, 0, 50, nil), 50000)
        assert_true(CW(1000, 0, 50, nil) > 2000, "nil cap must not fall back to the shipped cap")
        assert_eq(CW(1000, 0, 50, 0), 0)       -- kills CAP_uncapped_broken
    end)

    it("B11 the cap does NOT bind inside the normal operating range", function()
        -- Findings section 3's trap, twice-bitten: WIDEN_MAX silently becomes
        -- the OPERATING value if it sits inside the normal range, and then the
        -- travel term stops mattering entirely (cap 1400 / APPROACH 175 binds at
        -- d = 0; cap 3500 / APPROACH 300 binds at d = 1173u). 35s exposure is
        -- 6s past the largest observed shove exposure (29.0s).
        assert_true(CW(31, 4.0, 50, 2000) < 2000, "35s exposure must not be cap-bound")
        assert_true(CW(25, 4.0, 50, 2000) > CW(10, 4.0, 50, 2000) + 100,
            "travel must still move the widen inside the operating range")
    end)

    it("B12 a NaN exposure clamps to 0, NOT to the maximum widening", function()
        -- The clamp ORDER is load-bearing. Measured on the deployed Lua 5.4:
        --   math.max(0, nan) = 0        math.min(2000, nan) = 2000
        --   math.min(2000, math.max(0, nan)) = 0     <- shipped
        --   math.max(0, math.min(2000, nan)) = 2000  <- reversed, silently maximal
        -- Kills CLAMP_order_reversed, and also CLAMP_negative_dropped (dropping
        -- math.max(0, .) leaves min(2000, nan) = 2000). Without this test a NaN
        -- widen ships as the widest possible radius, and CO-1's other half
        -- (r_eff = NaN makes `edge < r_eff` false for every enemy, so every
        -- destination reads safe) is the exact defect being fixed arriving
        -- silently through the fix.
        local nan = 0 / 0
        assert_true(nan ~= nan, "0/0 must actually be NaN on this Lua")
        assert_eq(CW(nan, 4.0, 50, 2000), 0)
        assert_eq(CW(4.4, nan, 50, 2000), 0)
    end)

    it("B12b a NEGATIVE or NaN CAP is sanitised, it is not passed through", function()
        -- The clamp order defends the EXPOSURE argument (B12) and nothing else:
        -- min(cap, max(0, w)) hands a bad `cap` straight to the caller, so CO-1
        -- survives its own fix through the other parameter. Both cells measured
        -- against the pre-sanitise function: cap -500 returned -500 (a negative
        -- widen SHRINKS r_eff = the bot goes blind, exactly backwards, which is
        -- the failure the approach_speed guard exists to prevent) and a NaN cap
        -- returned NaN (`edge < NaN` is false for every enemy at every distance,
        -- so every destination reads safe). Unreachable from the two shipped
        -- call sites, which both pass K.COMMIT_WIDEN_MAX; pinned because this is
        -- public API on a lib file three heroes load, and the @return contract
        -- says "always finite and >= 0 for every input".
        assert_eq(CW(4.4, 4.0, 50, -500), 0)
        local nan = 0 / 0
        assert_eq(CW(4.4, 4.0, 50, nan), 0)
        assert_eq(CW(4.4, 4.0, 50, math.huge), 420)   -- an infinite cap is still just uncapped
    end)

    it("B13 CONFIG LINT: WIDEN_MAX >= APPROACH_SPEED * 35, and both integral, in the real Tinker.lua", function()
        -- B11 hardcodes 50/4.0/2000 and therefore CANNOT see the shipped
        -- constants: retune the speed to 300, leave the cap at 3500, and B11
        -- stays green while the cap binds at 1173u. This reads the live values
        -- out of the source text so editing one constant without the other
        -- fails here. Kills ZERO code mutants by design: it is a config lint,
        -- not an implementation test. Precedent for reading Tinker.lua as text
        -- is the fog probe contract block below.
        local f = io.open("Tinker/Tinker.lua", "r")
        if not f then
            -- 2026-08-22: the sniper repo deliberately gitignores Tinker/ ("not part of the
            -- Sniper repo"), so a clean checkout there has no hero source. This block is a
            -- TEXT CONTRACT against that source; without it there is nothing to lint - skip
            -- loudly rather than abort the suite (which must stay green from that tree).
            print("  SKIP  hero-source contract block: Tinker/Tinker.lua not present in this tree")
            return
        end
        local src = f:read("*a"); f:close()
        local function num(name)
            local v = src:match(name .. "%s*=%s*(%-?[%d%.]+)")
            -- The load-bearing row: a text test that silently extracts nothing
            -- IS the vacuous test that shipped twice on this project.
            assert_true(v ~= nil, "constant " .. name .. " not found in Tinker/Tinker.lua "
                .. "(renamed? then this lint is dead and the coupling is unguarded)")
            local n = tonumber(v)
            assert_true(n ~= nil, "constant " .. name .. " parsed as non-numeric: " .. tostring(v))
            return n
        end
        local speed = num("COMMIT_APPROACH_SPEED")
        local stand = num("COMMIT_STAND_S")
        local cap   = num("COMMIT_WIDEN_MAX")
        assert_true(stand >= 0, "COMMIT_STAND_S must not be negative, got " .. stand)

        -- INTEGRALITY: the VALUE half of the crash path B14 guards from the
        -- FORMAT half. `%d` throws "number has no integer representation" on a
        -- fractional argument, and that string.format runs at the emitter on
        -- the decide path, BEFORE logline's pcall and inside a decide that
        -- OnUpdateEx does not pcall, i.e. the v0.1.247 stuck-in-DECIDE freeze at
        -- roughly 50 errors/s. These two constants are the only commit_risk
        -- fields fed straight from a TUNING KNOB, so a config edit alone is the
        -- whole reproduction. The cap invariant below does NOT see it: speed
        -- 50.5 with cap 2000 honours `cap >= speed * 35` and passes today.
        -- Asserted with the real conversion rather than `n % 1 == 0` because
        -- the throw, not the arithmetic, is the failure being pinned. Costs
        -- nothing anyone intends: the documented tightening ladder is
        -- 50/75/100 and 2000/3000/3500, integral at every rung. COMMIT_STAND_S
        -- is deliberately excluded, it is 4.0 and prints under %.1f.
        assert_true((pcall(string.format, "%d", speed)),
            "COMMIT_APPROACH_SPEED must be integral, got " .. speed
                .. " (a %d conversion on it throws on the decide path)")
        assert_true((pcall(string.format, "%d", cap)),
            "COMMIT_WIDEN_MAX must be integral, got " .. cap
                .. " (a %d conversion on it throws on the decide path)")

        assert_true(cap >= speed * 35,
            ("COMMIT_WIDEN_MAX %d must be >= COMMIT_APPROACH_SPEED %d * 35 = %d, or the cap "
             .. "becomes the operating value and the travel term stops mattering")
                :format(cap, speed, speed * 35))
    end)

    it("B14 LOGLINE CONTRACT: commit_risk parses under the analyzer's own kv pattern", function()
        -- A silent gate reads exactly like a dead one. This repo has shipped a
        -- born-dead instrument twice (v0.1.348 walk_leg, v0.1.346 keen probe),
        -- both times because the emitter and the analyzer pattern were coupled
        -- by nothing. Read BOTH out of the real sources and prove they agree.
        local function slurp(p)
            local f = assert(io.open(p, "r"), "cannot open " .. p .. " (run the suite from the repo root)")
            local s = f:read("*a"); f:close(); return s
        end
        local tf = io.open("Tinker/Tinker.lua", "r")
        if not tf then
            print("  SKIP  fog-probe contract block: Tinker/Tinker.lua not present in this tree")
            return
        end
        tf:close()
        local tinker = slurp("Tinker/Tinker.lua")
        local parser = slurp("tools/parse_debuglog.lua")

        -- The format is written as adjacent literals glued by `..`, so a single
        -- '"(commit_risk[^"]+)"' match would truncate it at the first closing
        -- quote and this test would then pass on half a line. Splice the chain.
        local function fmt_from(src, head)
            local i = src:find('"' .. head, 1, true)
            if not i then return nil end
            local out, pos = nil, i
            while true do
                local _, e, lit = src:find('^"([^"]*)"', pos)
                if not e then break end
                out = (out or "") .. lit
                pos = e + 1
                local _, ce = src:find("^%s*%.%.%s*", pos)
                if not ce then break end
                pos = ce + 1
            end
            return out
        end
        local fmt = fmt_from(tinker, "commit_risk ")
        local kv_pat = parser:match('kvs:gmatch%("([^"]+)"%)')
        assert_true(fmt ~= nil, "no commit_risk format string found in Tinker.lua")
        assert_true(kv_pat ~= nil, "no kv pattern found in parse_debuglog.lua")

        -- The two fields that echo TUNING CONSTANTS must tolerate a fractional
        -- value. string.format runs at the emitter's call site, BEFORE logline's
        -- pcall (Tinker.lua:73-77) and inside a decide that OnUpdateEx does not
        -- pcall, so a %d conversion against COMMIT_APPROACH_SPEED = 62.5 (a
        -- plausible rung between the documented 50 and 75) throws "number has no
        -- integer representation" every decide: a CONFIG EDIT ALONE reproduces
        -- the v0.1.247 stuck-in-DECIDE crash, with the diag slider offering no
        -- protection. wcap/v1/chg/nh keep %d correctly - they take `and 1 or 0`
        -- and a `#` length, which are integers by construction.
        for _, key in ipairs({ "ap", "wmax" }) do
            -- %f[%w] frontier, not a bare find: "wcap=%d" CONTAINS "ap=", so an
            -- unanchored match reads wcap's conversion and reports it as ap's.
            local conv = fmt:match("%f[%w]" .. key .. "=(%%[-+ #0-9.]*%a)")
            assert_true(conv ~= nil, "no conversion found for " .. key .. "= in the commit_risk format")
            assert_true((pcall(string.format, conv, 62.5)),
                ("%s= uses %s, which throws on a fractional tuning constant inside the risk path")
                    :format(key, conv))
        end

        -- Build a real line from the real format: derive one argument per
        -- conversion so the test survives a field reorder but not a field drop.
        local args = {}
        for conv in fmt:gsub("%%%%", ""):gmatch("%%[-+ #0-9.]*(%a)") do
            args[#args + 1] = (conv == "s") and "mid" or 1
        end
        local line = string.format(fmt, table.unpack(args))

        local kv = {}
        for k, v in line:gmatch(kv_pat) do kv[k] = v end
        -- br= joined the contract in v0.1.359 (the early-return arm): every commit-gated call now
        -- emits, naming which of lane_unsafe's five returns it took, so a branch that never logs
        -- provably never ran. The count below is the teeth: it fails BOTH on a dropped field and on
        -- a silently added one, which is how it caught br= arriving.
        for _, key in ipairs({ "t", "site", "br", "exp", "st", "wd", "wcap", "ap", "wmax",
                               "r0", "r1", "g", "v1", "chg", "ne", "nh" }) do
            assert_true(kv[key] ~= nil, "field " .. key .. "= missing from the parsed commit_risk line: " .. line)
        end
        -- No value may contain a space, or (%S+)=(%S+) silently swallows the
        -- next field. Every whitespace token past the event name must be a k=v.
        local n = 0
        for tok in line:gmatch("%S+") do
            if tok ~= "commit_risk" then
                assert_true(tok:find("=", 1, true) ~= nil,
                    "stray token with no '=' (a unit suffix or a space inside a value): " .. tok)
                n = n + 1
            end
        end
        assert_eq(n, 16, "commit_risk must carry exactly the 16 contracted fields")
    end)

    it("B15 HERO LINT: the two load-bearing hero-side lines are still wired", function()
        -- Design 7.1 item 3 files the whole feature's one changed line as
        -- "untestable hero-side" and routes it to a FIELD signature (r0 == r1 on
        -- every logged line). A harness run made that unacceptable: deleting
        -- `+ (widen or 0)` from enemy_risk_at leaves the ENTIRE suite green, so
        -- the only guard on the one line the feature IS would be one column of a
        -- log that does not exist yet, read after a game has already been played.
        -- Same class, and worse because the field signature MISREADS it: making
        -- the verdict fall back to the un-widened read while still computing and
        -- logging r1 emits r1 > r0 with chg=0, which design 6.4's table calls
        -- "live and correctly inert, the expected first-game outcome".
        --
        -- A text lint is the laziest thing that can fail on either. Same idiom
        -- and same TV-6 nil-guard rule as B13/B14: it asserts the pattern was
        -- FOUND, so a rename fails loudly here instead of silently extracting
        -- nothing. It pins semantics, not layout - anything may move around it.
        local f = io.open("Tinker/Tinker.lua", "r")
        if not f then
            -- 2026-08-22: the sniper repo deliberately gitignores Tinker/ ("not part of the
            -- Sniper repo"), so a clean checkout there has no hero source. This block is a
            -- TEXT CONTRACT against that source; without it there is nothing to lint - skip
            -- loudly rather than abort the suite (which must stay green from that tree).
            print("  SKIP  hero-source contract block: Tinker/Tinker.lua not present in this tree")
            return
        end
        local src = f:read("*a"); f:close()
        assert_true(src:find("risk_radius%s*=%s*K%.RISK_RADIUS%s*%+%s*%(%s*widen%s+or%s+0%s*%)") ~= nil,
            "enemy_risk_at no longer adds the widen to risk_radius: THE feature is gone, and the "
            .. "21 unwidened reads need the `or 0` to stay bit-identical (dropping it throws on them)")
        assert_true(src:find("local%s+r1%s*=%s*enemy_risk_at%s*%(%s*p%s*,%s*w%s*%)") ~= nil,
            "lane_unsafe no longer computes r1 from the widened read")
        assert_true(src:find("local%s+unsafe%s*=%s*r1%s*>=%s*K%.SHOVE_SAFE_RISK") ~= nil,
            "lane_unsafe's VERDICT no longer comes from r1: the gate has silently reverted to the "
            .. "un-widened read while the instrument keeps logging r1, which reads as healthy")
        -- The side producer's throttle key must be the LANE, never a literal.
        -- eval_side_lanes runs side_wave_ctx for both {"top","bot"} in ONE decide
        -- at ONE now(), so a shared "side" key gives DiagGate dt = 0 on the
        -- second lane and bot never logs, systematically (the loop order is
        -- fixed). This one has no field signature at all: analyzer A1 still sees
        -- 2 distinct sites and still prints PASS, and the logline carries no lane
        -- field, so nothing post-hoc recovers it. Offline text is the only place
        -- it can be caught, which is why it is pinned rather than trusted.
        assert_true(src:find('site%s*=%s*lane,%s*travel%s*=%s*travel') ~= nil,
            "the side shove gate no longer tags its site with the lane: top and bot share one "
            .. "throttle stamp again (v0.1.357 failure 1 at half scope)")
    end)
end)

describe("lib/escape - DiagGate (commit risk v2, group C)", function()
    local Escape = require("lib.escape")
    local DG = Escape.DiagGate

    it("C1 the FIRST call emits, even at t = 0 exactly", function()
        -- Not academic: now() is GameRules.GetDOTATime(false, false), which
        -- `negative=false` pins at exactly 0.0 for the first ~102 real seconds
        -- of every match (measured, g356). `or 0` instead of `or -math.huge`
        -- would silence the instrument for that whole window.
        local s = {}
        assert_true(DG(s, "a", 0, 2), "first call at t=0 must emit")
    end)

    it("C2 the same key inside the window is suppressed", function()
        local s = {}
        DG(s, "a", 0, 2)
        assert_false(DG(s, "a", 1, 2), "1s into a 2s window must suppress")
    end)

    it("C3 exactly at the window boundary emits", function()
        local s = {}
        DG(s, "a", 0, 2)
        assert_true(DG(s, "a", 2, 2), "dt == window must emit (kills `dt <= window`)")
    end)

    it("C4 a DIFFERENT key inside the window still EMITS (keys never starve each other)", function()
        -- THE test that would have caught v0.1.357 failure 1: a single shared
        -- stamp aliases to whichever call site ran first, so hundreds of calls
        -- per decide sampled only that one and the log could sit empty while
        -- another site actively vetoed. site=mid and site=side must be
        -- independent, and nothing else in the log reveals it if they are not.
        local s = {}
        DG(s, "mid", 0, 2)
        assert_true(DG(s, "side", 1, 2), "a distinct key must not be throttled by another key's stamp")
        assert_false(DG(s, "mid", 1, 2), "and the first key must still be throttled")
    end)

    it("C5 the stamp advances ONLY on emit", function()
        -- Failure 1's literal mechanism: moving `stamps[key] = t` above the
        -- `return false` re-stamps on every suppressed call, so a call every
        -- frame pushes the deadline forever and the line never emits again.
        local s = {}
        assert_true(DG(s, "a", 0, 2), "emit at t=0")
        assert_false(DG(s, "a", 1, 2), "suppress at t=1")
        assert_true(DG(s, "a", 2, 2), "MUST emit at t=2: the suppressed call must not have re-stamped")
    end)

    it("C6 a BACKWARDS clock EMITS and rewinds the stamp, it does not go silent", function()
        -- An instrument's failure direction must be noisy, never silent. A
        -- backwards now() is possible on a match transition without a script
        -- reload (UCZone's reload behaviour at a match boundary is not
        -- documented, and State.hero is never nilled), and `dt >= 0` makes the
        -- answer not matter. NOTE the pre-stamp: on a FRESH table the stamp is
        -- -math.huge, dt is +inf, and the test would pass with the guard
        -- removed. It has to start from a stamped future to have kill power.
        local s = {}
        assert_true(DG(s, "a", 100, 2), "stamp the future first")
        assert_true(DG(s, "a", -5, 2), "a backwards jump must EMIT (kills the `dt >= 0` guard)")
        assert_eq(s["a"], -5, "and must rewind the stamp, or the gate stays wedged until t catches up")
        assert_false(DG(s, "a", -4, 2), "normal throttling resumes from the rewound stamp")
    end)
end)

describe("lib/escape - NearestEnemyEdge (commit risk v2, group D)", function()
    local Escape = require("lib.escape")
    local NEE = Escape.NearestEnemyEdge
    -- Plain {x,y} tables on purpose: pt crosses the hero->lib boundary and both
    -- snap_walkable and Farm.PathRisk build plain tables, while origin() and
    -- Map.CampCenter return engine Vectors. A pt:Distance2D in here is the
    -- v0.1.247 stuck-in-DECIDE crash, so the tests never provide the method.
    local function P(x, y) return { x = x, y = y } end

    it("D1 a VISIBLE enemy contributes plain distance", function()
        local snap = { heroes = { { pos = P(900, 1200), age = 0, visible = true } } }
        assert_eq(NEE(snap, P(0, 0)), 1500)  -- 3/4/5 triangle
    end)

    it("D1b takes the NEAREST over several enemies", function()
        local snap = { heroes = {
            { pos = P(3000, 0), age = 0, visible = true },
            { pos = P(700, 0),  age = 0, visible = true },
            { pos = P(1600, 0), age = 0, visible = true },
        } }
        assert_eq(NEE(snap, P(0, 0)), 700)
    end)

    it("D2 a FOGGED enemy subtracts the age disc and floors at 0", function()
        -- Same edge rule as FogProximityRisk:897-901. age * fog_ms is the
        -- probable-position disc; the widen never enters here.
        local far = { heroes = { { pos = P(2000, 0), age = 1, visible = false } } }
        assert_eq(NEE(far, P(0, 0)), 2000 - 550)
        local covered = { heroes = { { pos = P(400, 0), age = 2, visible = false } } }
        assert_eq(NEE(covered, P(0, 0)), 0)   -- disc 1100 covers pt: floors, never negative
        local tuned = { heroes = { { pos = P(2000, 0), age = 2, visible = false } } }
        assert_eq(NEE(tuned, P(0, 0), { fog_ms = 300 }), 2000 - 600)
    end)

    it("D3 an EMPTY snapshot returns math.huge, not 0", function()
        -- The sentinel. Without it "no enemies" logs as ne=0 and reads as
        -- "enemy standing on top of me", which inverts every calibration read
        -- this field exists to provide.
        assert_eq(NEE({ heroes = {} }, P(0, 0)), math.huge)
        assert_eq(NEE(nil, P(0, 0)), math.huge)
        assert_eq(NEE({ heroes = { { pos = P(0, 0), age = 0, visible = true } } }, P(0, 0)), 0,
            "and a real enemy at 0u must still read 0, so the two stay distinguishable")
    end)

    it("D4 agrees with the risk kernel: risk == (1 - ne/r_eff)^2 * w", function()
        -- A divergence between the two edge rules would silently make every
        -- ne= in the log wrong, and ne= is the field the whole calibration
        -- ladder is read off. Checked against the real FogProximityRisk.
        for _, d in ipairs({ 0, 300, 900, 1400, 2600 }) do
            for _, W in ipairs({ 0, 420, 1400 }) do
                local r_eff = 1400 + W
                local snap = { heroes = { { pos = P(d, 0), age = 0, probable_radius = 0, visible = true } } }
                local o = { risk_radius = r_eff, fog_ms = 550, fog_spread = 900, age_cap = 5 }
                local ne = NEE(snap, P(0, 0), o)
                assert_eq(ne, d, "edge must be plain distance for a visible enemy")
                local want = 0
                if ne < r_eff then local r = 1 - ne / r_eff; want = r * r end
                assert_true(math.abs(Escape.FogProximityRisk(snap, P(0, 0), o) - want) < 1e-12,
                    ("d=%d W=%d: the kernel and ne= must use the same edge"):format(d, W))
            end
        end
    end)

    it("D5 opts.age_cap drops STALE ghosts entirely (v0.1.412, the flip's armed shrink)", function()
        -- The v0.1.410 flip made h.age real; without a cap a 30s ghost's disc (16500u)
        -- zeroed the edge from anywhere (g404/g405: ne= p50 collapsed 1400 -> 0). With
        -- the cap, a ghost STALER than age_cap stops pricing (the kernel's drop rule);
        -- fresher ghosts keep the exact D2 shrink; visible enemies are never dropped.
        local snap = { heroes = {
            { pos = P(2000, 0), age = 0,  visible = true },     -- visible at 2000
            { pos = P(1000, 0), age = 10, visible = false },    -- stale ghost: dropped under cap 5
        } }
        assert_eq(NEE(snap, P(0, 0), { age_cap = 5 }), 2000, "the stale ghost must not price")
        assert_eq(NEE(snap, P(0, 0)), 0, "nil age_cap keeps the old uncapped behaviour")
        local fresh = { heroes = { { pos = P(2000, 0), age = 3, visible = false } } }
        assert_eq(NEE(fresh, P(0, 0), { age_cap = 5 }), 2000 - 3 * 550, "fresh-fog shrink unchanged")
        local vis_old = { heroes = { { pos = P(700, 0), age = 40, visible = true } } }
        assert_eq(NEE(vis_old, P(0, 0), { age_cap = 5 }), 700, "a VISIBLE hero is never dropped whatever its age field says")
    end)
end)

local HV = require("lib.hero_value")

describe("lib/hero_value -- FarmPriority", function()
    it("maps role 1..5 to a strictly descending priority (carry highest)", function()
        local p1 = HV.FarmPriority({ role = 1 })
        local p3 = HV.FarmPriority({ role = 3 })
        local p5 = HV.FarmPriority({ role = 5 })
        assert_true(p1 > p3 and p3 > p5, "pos1 > pos3 > pos5")
        assert_true(p1 <= 1.0 and p5 >= 0.0, "within 0..1")
    end)

    it("role nil -> normalized hero_value, clamped to 0..1", function()
        local hi = HV.FarmPriority({ role = nil, value = 1.6 })   -- a max-value carry
        local lo = HV.FarmPriority({ role = nil, value = 0.27 })  -- a low support
        assert_true(math.abs(hi - 1.0) < 1e-6, "1.6 / 1.6 = 1.0")
        assert_true(lo > 0 and lo < hi, "support below carry, still positive")
        assert_true(HV.FarmPriority({ role = nil, value = 5.0 }) <= 1.0, "clamped at 1.0")
        assert_eq(HV.FarmPriority({}), HV.FarmPriority({ value = HV.DEFAULT_VALUE }))
    end)
end)

describe("lib/hero_value -- base (KV-tag derive + override)", function()
    it("Carry primary tag -> 1.0 (antimage)", function()
        assert_eq(HV.base("npc_dota_hero_antimage"), 1.00)
    end)
    it("Support primary tag -> 0.45 (crystal_maiden)", function()
        assert_eq(HV.base("npc_dota_hero_crystal_maiden"), 0.45)
    end)
    it("unknown hero -> default 0.5", function()
        assert_eq(HV.base("npc_dota_hero_does_not_exist"), 0.50)
    end)
    it("nil name -> default", function()
        assert_eq(HV.base(nil), 0.50)
    end)
    it("override beats the KV-tag derive", function()
        HV.HERO_VALUE_OVERRIDE["npc_dota_hero_antimage"] = 0.33
        assert_eq(HV.base("npc_dota_hero_antimage"), 0.33)
        HV.HERO_VALUE_OVERRIDE["npc_dota_hero_antimage"] = nil
    end)
    it("seeded override applies (doom_bringer offlane 0.70)", function()
        assert_eq(HV.base("npc_dota_hero_doom_bringer"), 0.70)
    end)
end)

describe("lib/hero_value -- KillThreat", function()
    it("lethal cataloged ability -> HI (pudge)", function()
        assert_eq(HV.KillThreat("npc_dota_hero_pudge"), HV.KILL_W_HI)
    end)
    it("Initiator with no cataloged lethal -> HI (axe)", function()
        assert_eq(HV.KillThreat("npc_dota_hero_axe"), HV.KILL_W_HI)
    end)
    it("support, no lethal, not initiator -> LO (dazzle)", function()
        assert_eq(HV.KillThreat("npc_dota_hero_dazzle"), HV.KILL_W_LO)
    end)
    it("core nuker without cataloged lethal -> BASE (sniper)", function()
        assert_eq(HV.KillThreat("npc_dota_hero_sniper"), HV.KILL_W_BASE)
    end)
    it("unknown hero -> BASE", function()
        assert_eq(HV.KillThreat("npc_dota_hero_nonexistent"), HV.KILL_W_BASE)
    end)
end)

describe("lib/hero_value -- live_mult (peer-relative stats->level)", function()
    local E, P1, P2 = { id = "E" }, { id = "P1" }, { id = "P2" }
    local function restore(s) NPC.GetPlayerOwner, Player, NPC.GetCurrentLevel = s.po, s.pl, s.cl end
    local function snapshot() return { po = NPC.GetPlayerOwner, pl = Player, cl = NPC.GetCurrentLevel } end

    it("level fallback: fed enemy above peer mean clamps to HI 1.6", function()
        local s = snapshot()
        NPC.GetPlayerOwner = function() return nil end      -- force the level path
        local LV = { [E] = 25, [P1] = 10, [P2] = 10 }       -- mean 15; 25/15 = 1.667 -> 1.6
        NPC.GetCurrentLevel = function(u) return LV[u] end
        assert_true(math.abs(HV.live_mult(E, { E, P1, P2 }) - 1.6) < 1e-9, "clamp HI")
        restore(s)
    end)
    it("level fallback: within band, unclamped", function()
        local s = snapshot()
        NPC.GetPlayerOwner = function() return nil end
        local LV = { [E] = 18, [P1] = 12, [P2] = 12 }       -- mean 14; 18/14 = 1.2857
        NPC.GetCurrentLevel = function(u) return LV[u] end
        assert_true(math.abs(HV.live_mult(E, { E, P1, P2 }) - (18/14)) < 1e-9, "ratio")
        restore(s)
    end)
    it("stats preferred when they read for the whole set", function()
        local s_str, s_agi, s_int = Hero.GetStrengthTotal, Hero.GetAgilityTotal, Hero.GetIntellectTotal
        local s_cl = NPC.GetCurrentLevel
        local ST = { [E] = 600, [P1] = 300, [P2] = 300 }     -- mean 400; 600/400 = 1.5
        Hero.GetStrengthTotal  = function(u) return ST[u] end
        Hero.GetAgilityTotal   = function() return 0 end
        Hero.GetIntellectTotal = function() return 0 end
        NPC.GetCurrentLevel    = function() return 1 end      -- level would give 1.0; proves stats win
        assert_true(math.abs(HV.live_mult(E, { E, P1, P2 }) - 1.5) < 1e-9, "stats ratio")
        Hero.GetStrengthTotal, Hero.GetAgilityTotal, Hero.GetIntellectTotal = s_str, s_agi, s_int
        NPC.GetCurrentLevel = s_cl
    end)
    it("fewer than 2 peers sampled -> 1.0", function()
        local s = snapshot()
        NPC.GetPlayerOwner = function() return nil end
        NPC.GetCurrentLevel = function(u) return (u == E) and 20 or nil end
        assert_eq(HV.live_mult(E, { E }), 1.0)
        restore(s)
    end)
    it("nil args -> 1.0", function()
        assert_eq(HV.live_mult(nil, { E }), 1.0)
        assert_eq(HV.live_mult(E, nil), 1.0)
    end)
end)

describe("lib/hero_value -- of (base x live_mult)", function()
    local E, P1, P2 = { id = "E" }, { id = "P1" }, { id = "P2" }
    it("of = base * mult", function()
        local s_un, s_po, s_cl = NPC.GetUnitName, NPC.GetPlayerOwner, NPC.GetCurrentLevel
        NPC.GetUnitName = function() return "npc_dota_hero_antimage" end   -- base 1.0 (Carry tag)
        NPC.GetPlayerOwner = function() return nil end
        local LV = { [E] = 18, [P1] = 12, [P2] = 12 }          -- mult 18/14
        NPC.GetCurrentLevel = function(u) return LV[u] end
        assert_true(math.abs(HV.of(E, { E, P1, P2 }) - (1.0 * 18/14)) < 1e-9, "of value")
        NPC.GetUnitName, NPC.GetPlayerOwner, NPC.GetCurrentLevel = s_un, s_po, s_cl
    end)
    it("nil enemy -> 0", function() assert_eq(HV.of(nil, { E }), 0) end)
    it("debug_reads returns raw networth/level for the eval log", function()
        local s_po, s_cl = NPC.GetPlayerOwner, NPC.GetCurrentLevel
        NPC.GetPlayerOwner = function() return nil end
        NPC.GetCurrentLevel = function() return 17 end
        local nw, lvl = HV.debug_reads(E)
        assert_true(nw == nil, "no networth -> nil")
        assert_eq(lvl, 17)
        NPC.GetPlayerOwner, NPC.GetCurrentLevel = s_po, s_cl
    end)
end)

describe("lib/hero_value -- best_cluster (D3b cluster value tie-break)", function()
    it("exact count tie -> higher value wins; pure = first max-count", function()
        local b, p = HV.best_cluster({ 3, 3 }, { 1.0, 2.0 })
        assert_eq(b, 2, "value breaks the count tie")
        assert_eq(p, 1, "pure pick = first max-count")
    end)
    it("strictly more bodies always wins, value ignored", function()
        local b, p = HV.best_cluster({ 4, 3 }, { 0.1, 9.0 })
        assert_eq(b, 1, "4 bodies beats 3 regardless of value")
        assert_eq(p, 1)
    end)
    it("full tie (equal count + equal value) -> first index", function()
        local b, p = HV.best_cluster({ 2, 2 }, { 1.0, 1.0 })
        assert_eq(b, 1)
        assert_eq(p, 1)
    end)
    it("value tie-break picks the higher-value cluster among three", function()
        local b, p = HV.best_cluster({ 2, 3, 3 }, { 5.0, 1.0, 2.0 })
        assert_eq(b, 3, "among the two 3-clusters, higher value (idx 3) wins")
        assert_eq(p, 2, "pure = first 3-cluster")
    end)
    it("single element", function()
        local b, p = HV.best_cluster({ 5 }, { 0.3 })
        assert_eq(b, 1); assert_eq(p, 1)
    end)
    it("empty -> nil, nil", function()
        local b, p = HV.best_cluster({}, {})
        assert_true(b == nil and p == nil, "empty is safe")
    end)
end)

local ItemSaves = require("lib.item_saves")

describe("lib/item_saves - cyclone_launch_decision", function()
    it("nil cp_t -> proceed (fire)", function()
        assert_eq(ItemSaves.cyclone_launch_decision(nil, false), "fire")
        assert_eq(ItemSaves.cyclone_launch_decision(nil, true), "fire")
    end)
    it("mid-cast (cp_t>-0.05) + marker -> defer", function()
        assert_eq(ItemSaves.cyclone_launch_decision(0.50, true), "defer")
    end)
    it("mid-cast + no marker -> instant", function()
        assert_eq(ItemSaves.cyclone_launch_decision(0.50, false), "instant")
    end)
    it("post-launch (cp_t<=-0.05) + marker -> fire", function()
        assert_eq(ItemSaves.cyclone_launch_decision(-0.20, true), "fire")
    end)
    it("post-launch + no marker -> skip", function()
        assert_eq(ItemSaves.cyclone_launch_decision(-0.20, false), "skip")
    end)
    it("boundary cp_t==-0.05 counts as post-launch", function()
        assert_eq(ItemSaves.cyclone_launch_decision(-0.05, true), "fire")
    end)
end)

describe("lib/item_saves - tier 1 bare casts", function()
    -- stub cfg that records the last issue call + whether a guard fired.
    local function mk_cfg(opts)
        opts = opts or {}
        local rec = { calls = {}, logs = {} }
        local cfg = {
            self_npc = function() return { idx = 1 } end,
            -- NOTE: `opts.no_item and nil or {..}` would be the Lua ternary
            -- trap (nil or X always yields X), so branch explicitly.
            item = function(_) if opts.no_item then return nil end; return { idx = 9 } end,
            -- mirror the real hero issue_* wrappers: no-op + false on a nil
            -- item handle (so builders that pass cfg.item(name) straight
            -- through get the same false-on-missing-item behavior).
            issue_self      = function(i, it) if not it then return false end; rec.calls[#rec.calls+1] = "self";      return true end,
            issue_target    = function(i, it, t) if not it then return false end; rec.calls[#rec.calls+1] = "target"; return true end,
            issue_position  = function(i, it, p) if not it then return false end; rec.calls[#rec.calls+1] = "position"; return true end,
            issue_no_target = function(i, it) if not it then return false end; rec.calls[#rec.calls+1] = "no_target"; return true end,
            tlog = function(_, name, _) rec.logs[#rec.logs+1] = name end,
            uname = function(_) return "x" end,
            dist_to = function(_) return 9999 end,
        }
        return cfg, rec
    end
    _G.__mk_cfg = mk_cfg  -- shared with later describe blocks

    it("BKB: not guarded -> no_target cast + save_fire_invoked log", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        local ok = m.item_black_king_bar.fire("intent")
        assert_true(ok, "bkb fired")
        assert_eq(rec.calls[1], "no_target")
        assert_eq(rec.logs[1], "save_fire_invoked")
    end)
    it("Manta: bare no_target, NO log", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        m.item_manta.fire("intent")
        assert_eq(rec.calls[1], "no_target")
        assert_eq(#rec.logs, 0, "manta must not log save_fire_invoked")
    end)
    it("Ethereal-self: self cast, NO log", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        m.item_ethereal_blade_self.fire("intent")
        assert_eq(rec.calls[1], "self")
        assert_eq(#rec.logs, 0)
    end)
    it("missing item handle -> false, no cast", function()
        local cfg, rec = mk_cfg({ no_item = true })
        local m = ItemSaves.build(cfg)
        local ok = m.item_manta.fire("intent")
        assert_false(ok, "no item -> false")
        assert_eq(#rec.calls, 0)
    end)
end)

describe("lib/item_saves - lotus", function()
    local mk_cfg = _G.__mk_cfg
    it("gate true -> self cast", function()
        local cfg, rec = mk_cfg()
        cfg.lotus_gate = function(_) return true end
        local m = ItemSaves.build(cfg)
        local ok = m.item_lotus_orb.fire("intent", nil, "modifier_lion_finger_of_death")
        assert_true(ok)
        assert_eq(rec.calls[1], "self")
    end)
    it("gate false -> no cast, skip log", function()
        local cfg, rec = mk_cfg()
        cfg.lotus_gate = function(_) return false end
        local m = ItemSaves.build(cfg)
        local ok = m.item_lotus_orb.fire("intent", nil, "modifier_doom_bringer_doom")
        assert_false(ok)
        assert_eq(#rec.calls, 0)
        assert_eq(rec.logs[1], "lotus_dmg_gate_skip")
    end)
    it("no hook -> legacy default skips at full HP / unknown threat", function()
        local cfg, rec = mk_cfg()  -- no lotus_gate hook; stub HP = 1000/1000
        local m = ItemSaves.build(cfg)
        local ok = m.item_lotus_orb.fire("intent", nil, "modifier_unknown")
        assert_false(ok, "legacy 0.85 gate skips at full HP")
    end)
end)

describe("lib/item_saves - cyclones", function()
    local mk_cfg = _G.__mk_cfg
    it("WW guarded (already airborne) -> false", function()
        local cfg, rec = mk_cfg()
        NPC.HasModifier = function(_, m) return m == "modifier_wind_waker" end
        local m = ItemSaves.build(cfg)
        local ok = m.item_wind_waker.fire("intent", nil, nil)
        NPC.HasModifier = function() return false end  -- restore
        assert_false(ok)
        assert_eq(rec.logs[1], "save_fire_invoked")
    end)
    it("WW no gate, no target -> self cast + post_move", function()
        local cfg, rec = mk_cfg()
        local moved = { n = 0 }
        cfg.queue_post_move = function() moved.n = moved.n + 1 end
        local m = ItemSaves.build(cfg)
        local ok = m.item_wind_waker.fire("intent", nil, nil)
        assert_true(ok)
        assert_eq(rec.calls[1], "self")
        assert_eq(moved.n, 1, "WW must queue a post-airborne move")
    end)
    it("Eul no gate, no target -> self cast, NO post_move", function()
        local cfg, rec = mk_cfg()
        local moved = { n = 0 }
        cfg.queue_post_move = function() moved.n = moved.n + 1 end
        local m = ItemSaves.build(cfg)
        local ok = m.item_cyclone.fire("intent", nil, nil)
        assert_true(ok)
        assert_eq(rec.calls[1], "self")
        assert_eq(moved.n, 0, "Eul must NOT post-move")
    end)
    it("situational target present -> target cast + cyclone_harasser_target log", function()
        local cfg, rec = mk_cfg()
        cfg.cyclone_target = function() return { idx = 7 } end
        local m = ItemSaves.build(cfg)
        local ok = m.item_cyclone.fire("intent", { idx = 7 }, "lina_committed_attacker_ranged")
        assert_true(ok)
        assert_eq(rec.calls[1], "target")
        local found = false
        for _, n in ipairs(rec.logs) do if n == "cyclone_harasser_target" then found = true end end
        assert_true(found, "harasser-target log emitted")
    end)
    it("launch gate defer (mid-cast + marker) -> false + wait log", function()
        local cfg, rec = mk_cfg()
        cfg.armed_cp_t = function() return 0.50 end
        cfg.armed_threat_mod = function() return "modifier_sniper_assassinate" end
        NPC.HasModifier = function(_, m) return m == "modifier_sniper_assassinate" end
        local m = ItemSaves.build(cfg)
        local ok = m.item_wind_waker.fire("intent", nil, "modifier_sniper_assassinate")
        NPC.HasModifier = function() return false end
        assert_false(ok)
        local found = false
        for _, n in ipairs(rec.logs) do if n == "cyclone_wait_for_launch" then found = true end end
        assert_true(found, "wait-for-launch log emitted")
    end)
end)

describe("lib/item_saves - displacement", function()
    local mk_cfg = _G.__mk_cfg
    it("Force -> self_push delegated", function()
        local cfg = mk_cfg()
        local pushed = { n = 0 }
        cfg.self_push = function() pushed.n = pushed.n + 1; return true end
        local m = ItemSaves.build(cfg)
        local ok = m.item_force_staff.fire("intent", { idx = 3 })
        assert_true(ok)
        assert_eq(pushed.n, 1)
    end)
    it("Force no self_push hook -> bare self cast fallback", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        local ok = m.item_force_staff.fire("intent", { idx = 3 })
        assert_true(ok)
        assert_eq(rec.calls[1], "self")
    end)
    it("Blink: recent damage broken -> false + skip log", function()
        local cfg, rec = mk_cfg()
        cfg.recent_damage = function(_) return 50 end
        cfg.compute_safe_dest = function() return nil, { x = 1, y = 2 } end
        local m = ItemSaves.build(cfg)
        local ok = m.item_blink.fire("intent", { idx = 3 })
        assert_false(ok)
        assert_eq(rec.logs[1], "blink_skip_broken")
    end)
    it("Blink: clean + landing -> position cast + escape log", function()
        local cfg, rec = mk_cfg()
        cfg.recent_damage = function(_) return 0 end
        cfg.compute_safe_dest = function() return nil, { x = 5, y = 6 } end
        local m = ItemSaves.build(cfg)
        local ok = m.item_blink.fire("intent", { idx = 3 })
        assert_true(ok)
        assert_eq(rec.calls[1], "position")
        assert_eq(rec.logs[1], "blink_escape")
    end)
    it("Pike: enemy in range -> target cast + after_target_fire", function()
        local cfg, rec = mk_cfg()
        cfg.pike_enemy_range = function() return 425 end
        cfg.dist_to = function(_) return 300 end       -- inside range
        local primed = { n = 0 }
        cfg.pike_after_target_fire = function(_) primed.n = primed.n + 1 end
        local m = ItemSaves.build(cfg)
        local ok = m.item_hurricane_pike.fire("intent", { idx = 3 }, nil)
        assert_true(ok)
        assert_eq(rec.calls[1], "target")
        assert_eq(primed.n, 1)
    end)
    it("Pike: enemy out of range -> self_push fallback", function()
        local cfg = mk_cfg()
        cfg.pike_enemy_range = function() return 425 end
        cfg.dist_to = function(_) return 900 end        -- out of range
        local pushed = { n = 0 }
        cfg.self_push = function() pushed.n = pushed.n + 1; return true end
        local m = ItemSaves.build(cfg)
        local ok = m.item_hurricane_pike.fire("intent", { idx = 3 }, nil)
        assert_true(ok)
        assert_eq(pushed.n, 1)
    end)
end)

describe("lib/item_saves -- expansion: diffusal blade", function()
    local mk_cfg = _G.__mk_cfg
    it("enemy in range -> target cast", function()
        local cfg, rec = mk_cfg()
        cfg.dist_to = function(_) return 400 end       -- inside 600
        local m = ItemSaves.build(cfg)
        assert_eq(m.item_diffusal_blade.short, "diffusal")
        assert_true(m.item_diffusal_blade.fire("intent", { idx = 3 }))
        assert_eq(rec.calls[1], "target")
    end)
    it("enemy out of range -> no cast", function()
        local cfg, rec = mk_cfg()
        cfg.dist_to = function(_) return 900 end        -- outside 600
        local m = ItemSaves.build(cfg)
        assert_false(m.item_diffusal_blade.fire("intent", { idx = 3 }))
        assert_eq(#rec.calls, 0)
    end)
    it("no caster -> no cast", function()
        local cfg, rec = mk_cfg()
        local m = ItemSaves.build(cfg)
        assert_false(m.item_diffusal_blade.fire("intent", nil))
        assert_eq(#rec.calls, 0)
    end)
end)

describe("lib/item_saves -- expansion: blink variants", function()
    local mk_cfg = _G.__mk_cfg
    for _, c in ipairs({ { key = "item_swift_blink",        short = "swiftblink" },
                         { key = "item_arcane_blink",       short = "arcaneblink" },
                         { key = "item_overwhelming_blink", short = "overwhelmingblink" } }) do
        it(c.key .. " -> position cast + escape log", function()
            local cfg, rec = mk_cfg()
            cfg.recent_damage = function(_) return 0 end
            cfg.compute_safe_dest = function() return nil, { x = 5, y = 6 } end
            local m = ItemSaves.build(cfg)
            assert_eq(m[c.key].short, c.short)
            assert_true(m[c.key].fire("intent", { idx = 3 }))
            assert_eq(rec.calls[1], "position")
            assert_eq(rec.logs[1], "blink_escape")
        end)
    end
    it("item_blink still works (default opts)", function()
        local cfg, rec = mk_cfg()
        cfg.recent_damage = function(_) return 0 end
        cfg.compute_safe_dest = function() return nil, { x = 1, y = 2 } end
        local m = ItemSaves.build(cfg)
        assert_eq(m.item_blink.short, "blink")
        assert_true(m.item_blink.fire("intent", { idx = 3 }))
        assert_eq(rec.calls[1], "position")
    end)
end)

describe("lib/item_saves -- expansion: UNIT_TARGET self", function()
    local mk_cfg = _G.__mk_cfg
    for _, c in ipairs({ { key = "item_solar_crest", short = "solar" },
                         { key = "item_disperser",   short = "disperser" } }) do
        it(c.key .. " -> self cast", function()
            local cfg, rec = mk_cfg()
            local m = ItemSaves.build(cfg)
            assert_eq(m[c.key].short, c.short)
            assert_true(m[c.key].fire("intent"))
            assert_eq(rec.calls[1], "self")
        end)
        it(c.key .. " missing item -> false", function()
            local cfg, rec = mk_cfg({ no_item = true })
            local m = ItemSaves.build(cfg)
            assert_false(m[c.key].fire("intent"))
            assert_eq(#rec.calls, 0)
        end)
    end
end)

describe("lib/item_saves -- expansion: NO_TARGET bare casts", function()
    local mk_cfg = _G.__mk_cfg
    local cases = {
        { key = "item_ghost",          short = "ghost" },
        { key = "item_satanic",        short = "satanic" },
        { key = "item_pipe",           short = "pipe" },
        { key = "item_crimson_guard",  short = "crimson" },
        { key = "item_blade_mail",     short = "blademail" },
        { key = "item_phase_boots",    short = "phase" },
    }
    for _, c in ipairs(cases) do
        it(c.key .. " -> no_target cast, short=" .. c.short, function()
            local cfg, rec = mk_cfg()
            local m = ItemSaves.build(cfg)
            assert_true(m[c.key] ~= nil, c.key .. " builder missing")
            assert_eq(m[c.key].short, c.short)
            local ok = m[c.key].fire("intent")
            assert_true(ok)
            assert_eq(rec.calls[1], "no_target")
            assert_eq(#rec.logs, 0, c.key .. " must be silent (no save_fire_invoked)")
        end)
        it(c.key .. " missing item -> false", function()
            local cfg, rec = mk_cfg({ no_item = true })
            local m = ItemSaves.build(cfg)
            assert_false(m[c.key].fire("intent"))
            assert_eq(#rec.calls, 0)
        end)
    end
end)

describe("lib/threat_data -- pipe name fix", function()
    local function scan_for(needle)
        local hits = 0
        for _, tbl in ipairs({ TD.RECOMMENDED_SAVES, TD.CATEGORY_CHAINS }) do
            for _, chain in pairs(tbl or {}) do
                if type(chain) == "table" then
                    for _, name in ipairs(chain) do
                        if name == needle then hits = hits + 1 end
                    end
                end
            end
        end
        return hits
    end
    it("the dead item_pipe_of_insight name is gone", function()
        assert_eq(scan_for("item_pipe_of_insight"), 0)
    end)
    it("real item_pipe is referenced instead", function()
        assert_true(scan_for("item_pipe") > 0, "item_pipe missing from chains")
    end)
end)

----------------------------------------------------------------------------
-- v0.5.114 precise charge-ramp kinematics (lib/threat_data.lua)
----------------------------------------------------------------------------

describe("lib/threat_data -- RampTravel / RampImpactT (v0.5.114)", function()
    local function near(got, want, tol, msg)
        assert_true(math.abs(got - want) <= (tol or 0.5),
                    (msg or "near") .. ": got " .. tostring(got)
                    .. ", want " .. tostring(want))
    end
    it("constant speed (accel 0) -> live * T", function()
        near(TD.RampTravel(400, 0, 0, 2.0), 800)
    end)
    it("full-ramp window integrates 0.5*a*t^2", function()
        -- lvl-4 Bara mid-ramp: live 556, accel 212.5, 1.5s ramp left, 0.95s lead
        near(TD.RampTravel(556, 212.5, 1.5, 0.95), 624.1, 1.0)
    end)
    it("ramp ending mid-window goes constant after rem", function()
        -- 0.4s of ramp left, then constant at live + accel*0.4
        near(TD.RampTravel(556, 212.5, 0.4, 0.95), 591.9, 1.0)
    end)
    it("rem 0 -> already at peak, constant", function()
        near(TD.RampTravel(700, 212.5, 0, 1.0), 700)
    end)
    it("horizon 0 -> 0", function()
        assert_eq(TD.RampTravel(556, 212.5, 1.5, 0), 0)
    end)
    it("RampImpactT constant-speed inverse", function()
        near(TD.RampImpactT(500, 0, 0, 1000), 2.0, 0.001)
    end)
    it("RampImpactT inverts RampTravel inside the ramp", function()
        local d = TD.RampTravel(556, 212.5, 1.5, 0.6)
        near(TD.RampImpactT(556, 212.5, 1.5, d), 0.6, 0.001)
    end)
    it("RampImpactT inverts RampTravel past the ramp", function()
        local d = TD.RampTravel(556, 212.5, 0.5, 2.0)
        near(TD.RampImpactT(556, 212.5, 0.5, d), 2.0, 0.001)
    end)
    it("dist 0 -> 0; dead inputs -> nil", function()
        assert_eq(TD.RampImpactT(556, 212.5, 1.5, 0), 0)
        assert_eq(TD.RampImpactT(0, 0, 0, 500), nil)
    end)
end)

describe("lib/threat_data -- ChargeRampKinematics (v0.5.114)", function()
    local ENTRY = {
        ramp_accel = 213, ramp_windup_s = 1.5, speed_fallback = 700,
        kv_ability = "spirit_breaker_charge_of_darkness",
    }
    local KV = function(ab, key, fb)
        return ({ movement_speed = 425, min_movespeed_bonus_pct = 25,
                  windup_time = 1.5 })[key] or fb
    end
    it("KV path: per-level accel from movement_speed * 0.75 / windup", function()
        NPC.GetMoveSpeed = function() return 556 end
        NPC.GetAbility   = function() return { ab = true } end
        local live, accel, rem = TD.ChargeRampKinematics(ENTRY, { idx = 1 }, KV, 0.5)
        assert_eq(live, 556)
        assert_true(math.abs(accel - 212.5) < 0.1, "accel from KV")
        assert_true(math.abs(rem - 1.0) < 0.001, "rem = windup - elapsed")
    end)
    it("no kv_lookup -> entry.ramp_accel fallback, unknown elapsed -> full windup", function()
        NPC.GetMoveSpeed = function() return 556 end
        local live, accel, rem = TD.ChargeRampKinematics(ENTRY, { idx = 1 }, nil, nil)
        assert_eq(live, 556)
        assert_eq(accel, 213)
        assert_true(math.abs(rem - 1.5) < 0.001, "worst-case still-ramping")
    end)
    it("elapsed past windup -> rem clamps to 0", function()
        NPC.GetMoveSpeed = function() return 740 end
        local _, _, rem = TD.ChargeRampKinematics(ENTRY, { idx = 1 }, KV, 3.0)
        assert_eq(rem, 0)
    end)
end)

----------------------------------------------------------------------------
-- v0.5.110 chain composition (lib/defense.lua)
----------------------------------------------------------------------------

local Defense = require("lib.defense")

describe("lib/defense -- ShouldDeferDodge (Note-1)", function()
    it("immediate save ready -> no defer (Ghost/E-blade fires now)", function()
        assert_false(Defense.ShouldDeferDodge(true, 1000, 450))
        assert_false(Defense.ShouldDeferDodge(true, 10, 450))
    end)
    it("no immediate + HP at/above floor -> defer (accept first strike)", function()
        assert_true(Defense.ShouldDeferDodge(false, 450, 450))
        assert_true(Defense.ShouldDeferDodge(false, 451, 450))
    end)
    it("no immediate + HP below floor -> no defer (dodge at cast to survive)", function()
        assert_false(Defense.ShouldDeferDodge(false, 449, 450))
    end)
    it("nil hp defaults 0 -> no defer", function()
        assert_false(Defense.ShouldDeferDodge(false, nil, 450))
    end)
end)

describe("lib/defense -- ComposeChain truth table", function()
    local function chain_eq(got, want)
        assert_eq(#got, #want, "length")
        for i = 1, #want do assert_eq(got[i], want[i], "slot " .. i) end
    end
    it("head anchor -> position 1", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "x", anchor = "head" } }, nil),
                 { "x", "a", "b", "c" })
    end)
    it("tail anchor -> appended", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "x", anchor = "tail" } }, nil),
                 { "a", "b", "c", "x" })
    end)
    it("before=b -> immediately before b", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "x", anchor = { before = "b" } } }, nil),
                 { "a", "x", "b", "c" })
    end)
    it("after=b -> immediately after b", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "x", anchor = { after = "b" } } }, nil),
                 { "a", "b", "x", "c" })
    end)
    it("before target absent -> tail (never dropped)", function()
        chain_eq(Defense.ComposeChain({ "a", "b" },
                 { { save = "x", anchor = { before = "zz" } } }, nil),
                 { "a", "b", "x" })
    end)
    it("after target absent -> tail (never dropped)", function()
        chain_eq(Defense.ComposeChain({ "a", "b" },
                 { { save = "x", anchor = { after = "zz" } } }, nil),
                 { "a", "b", "x" })
    end)
    it("nil anchor -> tail", function()
        chain_eq(Defense.ComposeChain({ "a" }, { { save = "x" } }, nil),
                 { "a", "x" })
    end)
    it("exclusion removes a backbone item", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" }, nil, { b = true }),
                 { "a", "c" })
    end)
    it("exclusion naming an absent item is a no-op", function()
        chain_eq(Defense.ComposeChain({ "a", "b" }, nil, { zz = true }),
                 { "a", "b" })
    end)
    it("dedupe first-wins: head-injecting an existing item moves it", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "c" },
                 { { save = "b", anchor = "head" } }, nil),
                 { "b", "a", "c" })
    end)
    it("multi-injection: later anchor can reference an earlier injection", function()
        chain_eq(Defense.ComposeChain({ "a", "b" },
                 { { save = "x", anchor = "head" },
                   { save = "y", anchor = { after = "x" } } }, nil),
                 { "x", "y", "a", "b" })
    end)
    it("nil injections + nil exclusions -> backbone copy, new table", function()
        local backbone = { "a", "b" }
        local got = Defense.ComposeChain(backbone, nil, nil)
        chain_eq(got, { "a", "b" })
        assert_false(rawequal(got, backbone), "must be a NEW table")
    end)
    it("never mutates the backbone", function()
        local backbone = { "a", "b", "c" }
        Defense.ComposeChain(backbone,
            { { save = "x", anchor = "head" } }, { b = true })
        chain_eq(backbone, { "a", "b", "c" })
    end)
    it("pre-existing backbone duplicate is deduped", function()
        chain_eq(Defense.ComposeChain({ "a", "b", "a" }, nil, nil), { "a", "b" })
    end)
    it("empty backbone + injection -> injection only", function()
        chain_eq(Defense.ComposeChain({},
                 { { save = "x", anchor = "head" } }, nil), { "x" })
    end)
end)

describe("lib/defense -- ResolveSaveOrder tier 3 (composed)", function()
    local TD_STUB = {
        CategoryOf = function(mod)
            return ({ modifier_stub_gap   = "close_gap",
                      modifier_stub_burst = "targeted_burst",
                      modifier_stub_weird = "weird_cat" })[mod]
        end,
        CATEGORY_CHAINS = {
            close_gap      = { "item_p", "item_f", "item_g" },
            targeted_burst = { "item_l", "item_e", "item_pi" },
        },
    }
    local PATCHED_CLOSE_GAP = { "item_patched" }
    local function mk(opts)
        opts = opts or {}
        return Defense.New {
            anim_save_overrides = {},
            hero_save_overrides = opts.hero or {},
            patched_recommended = opts.recommended or {},
            category_chains     = { close_gap = PATCHED_CLOSE_GAP,
                                    weird_cat = { "item_weird" } },
            default_chain       = { "item_default" },
            TD                  = TD_STUB,
            tlog                = function() end,
            tlog_level          = function() return 0 end,
            now                 = function() return 0 end,
            ability_injections  = opts.injections,
            exclusions          = opts.exclusions,
        }
    end
    local INJ = {
        { save = "hero_w",  categories = { "close_gap" },      anchor = "head" },
        { save = "hero_fc", categories = { "targeted_burst" }, anchor = "tail" },
    }
    it("composed: injection at head + raw backbone, authoritative", function()
        local d = mk({ injections = INJ })
        local chain, auth = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_true(auth, "composed must be authoritative")
        assert_eq(chain[1], "hero_w")
        assert_eq(chain[2], "item_p")
        assert_eq(chain[4], "item_g")
        assert_eq(#chain, 4)
    end)
    it("exclusion removes the item from the composed chain", function()
        local d = mk({ injections = INJ,
                       exclusions = { targeted_burst = { item_e = true } } })
        local chain = d:ResolveSaveOrder("modifier_stub_burst", nil, nil, nil)
        for i = 1, #chain do
            assert_true(chain[i] ~= "item_e", "item_e must be excluded")
        end
        assert_eq(chain[#chain], "hero_fc")
        assert_eq(#chain, 3)
    end)
    it("categories filter: close_gap injection absent from burst chain", function()
        local d = mk({ injections = INJ })
        local chain = d:ResolveSaveOrder("modifier_stub_burst", nil, nil, nil)
        for i = 1, #chain do
            assert_true(chain[i] ~= "hero_w", "hero_w is close_gap-only")
        end
    end)
    it("categories='*' applies everywhere", function()
        local d = mk({ injections = {
            { save = "hero_any", categories = "*", anchor = "tail" } } })
        local c1 = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        local c2 = d:ResolveSaveOrder("modifier_stub_burst", nil, nil, nil)
        assert_eq(c1[#c1], "hero_any")
        assert_eq(c2[#c2], "hero_any")
    end)
    it("NO composition cfg -> tier-4 chain IDENTITY, non-authoritative", function()
        local d = mk({})
        local chain, auth = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_true(rawequal(chain, PATCHED_CLOSE_GAP),
                    "tier-4 identity (Sniper additivity proof)")
        assert_false(auth, "tier 4 is non-authoritative")
    end)
    it("hero_save_overrides still beats tier 3", function()
        local OVERRIDE = { "item_override" }
        local d = mk({ injections = INJ,
                       hero = { modifier_stub_gap = OVERRIDE } })
        local chain, auth = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_true(rawequal(chain, OVERRIDE), "tier 2 wins")
        assert_true(auth, "overrides stay authoritative")
    end)
    it("patched_recommended is bypassed when composition is on", function()
        local d = mk({ injections = INJ,
                       recommended = { modifier_stub_gap = { "item_reco" } } })
        local chain = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_eq(chain[1], "hero_w", "composed wins over lib_patched")
    end)
    it("category_hint alone (nil threat_mod) composes", function()
        local d = mk({ injections = INJ })
        local chain, auth = d:ResolveSaveOrder(nil, "close_gap", nil, nil)
        assert_eq(chain[1], "hero_w")
        assert_true(auth)
    end)
    it("category without a lib backbone falls through to tier 4/5", function()
        local d = mk({ injections = INJ })
        local chain, auth = d:ResolveSaveOrder("modifier_stub_weird", nil, nil, nil)
        assert_eq(chain[1], "item_weird", "falls to c.category_chains")
        assert_false(auth)
    end)
    it("memoized: same (category, threat) returns the same table", function()
        local d = mk({ injections = INJ })
        local c1 = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        local c2 = d:ResolveSaveOrder("modifier_stub_gap", nil, nil, nil)
        assert_true(rawequal(c1, c2), "same threat+category should reuse cached table")
    end)
end)

describe("lib/defense -- composition proof cases (spec sec 5 shapes)", function()
    -- Pins the CHAIN_COMPOSITION_DESIGN.md sec 5 compositions against the
    -- REAL lib close_gap backbone, as pure ComposeChain regression tests.
    -- NOTE: v0.5.110.1 reverted Lina's LIVE committed chains to hand-curated
    -- literals (lethal-only item rule; user demo feedback), so these no
    -- longer mirror Lina's runtime chains -- they remain the canonical
    -- ComposeChain-over-real-data pins. The deferred backbone-enrichment
    -- follow-up will add items to TD.CATEGORY_CHAINS; when it does, update
    -- these exact lists DELIBERATELY in the same change.
    local function chain_eq(got, want)
        assert_eq(#got, #want, "length")
        for i = 1, #want do assert_eq(got[i], want[i], "slot " .. i) end
    end
    -- v0.5.x: derive expected from the LIVE backbone so enrichment growth does
    -- not re-break these. They pin the ComposeChain anchor/dedupe behavior, not
    -- a frozen item list.
    it("committed melee = W head + full close_gap backbone (in order)", function()
        local bb = TD.CATEGORY_CHAINS.close_gap
        local want = { "lina_w_anti_gap" }
        for i = 1, #bb do want[#want + 1] = bb[i] end  -- W not in bb: no dedupe
        chain_eq(
            Defense.ComposeChain(bb, { { save = "lina_w_anti_gap", anchor = "head" } }, nil),
            want)
    end)
    it("committed ranged = cyclones to head over the same backbone", function()
        local bb = TD.CATEGORY_CHAINS.close_gap
        -- cyclone + WW injected at head; their original backbone slots dedupe away
        local want = { "item_cyclone", "item_wind_waker" }
        for i = 1, #bb do
            local it = bb[i]
            if it ~= "item_cyclone" and it ~= "item_wind_waker" then want[#want + 1] = it end
        end
        chain_eq(
            Defense.ComposeChain(bb,
                { { save = "item_cyclone",    anchor = "head" },
                  { save = "item_wind_waker", anchor = { after = "item_cyclone" } } },
                nil),
            want)
    end)
    it("committed base = backbone copy (displacement-first, no injection)", function()
        local got = Defense.ComposeChain(TD.CATEGORY_CHAINS.close_gap, nil, nil)
        chain_eq(got, TD.CATEGORY_CHAINS.close_gap)
        assert_false(rawequal(got, TD.CATEGORY_CHAINS.close_gap),
                     "copy, not the shared lib table")
    end)
    it("targeted_burst + FC tail injection: Pipe present, FC last", function()
        local got = Defense.ComposeChain(TD.CATEGORY_CHAINS.targeted_burst,
            { { save = "lina_flame_cloak", anchor = "tail" } },
            { item_ethereal_blade_self = true })
        assert_eq(got[#got], "lina_flame_cloak")
        local has_pipe = false
        for i = 1, #got do if got[i] == "item_pipe" then has_pipe = true end end
        assert_true(has_pipe, "item_pipe must be in the composed burst chain")
    end)
end)

describe("close-gap redesign Slice 1 -- composed close_gap chain", function()
    local function has(set, k)
        for _, x in ipairs(set) do if x == k then return true end end
        return false
    end
    -- Mirrors ResolveSaveOrder tier-3: SaveCounters-filter the RAW close_gap
    -- backbone, then inject lina_w_anti_gap at head (Lina CH.ABILITY_INJECTIONS).
    local function composed_close_gap(mod)
        local bb = TD.CATEGORY_CHAINS.close_gap
        local filtered = {}
        for i = 1, #bb do
            if TD.SaveCounters(bb[i], mod) then filtered[#filtered + 1] = bb[i] end
        end
        return Defense.ComposeChain(filtered,
            { { save = "lina_w_anti_gap", anchor = "head" } }, nil)
    end

    it("item_blink is in the close_gap backbone", function()
        assert_true(has(TD.CATEGORY_CHAINS.close_gap, "item_blink"),
            "close_gap backbone must carry item_blink (leap gap-closers escape via blink)")
    end)
    it("item_glimmer_cape is in the close_gap backbone", function()
        assert_true(has(TD.CATEGORY_CHAINS.close_gap, "item_glimmer_cape"),
            "close_gap backbone must carry item_glimmer_cape (physical-chase invis)")
    end)

    -- PHYSICAL CHASE (PA, delivery=attack): facts give ghost/invis/displacement,
    -- correctly drop BKB. The axis withholds blink from attack-delivery (decided),
    -- so the composed chain has NO blink -- documented here.
    it("PA composed: W head + ghost/glimmer/invis/displacement, drops bkb AND blink", function()
        local c = composed_close_gap("modifier_phantom_assassin_phantom_strike_target")
        assert_eq(c[1], "lina_w_anti_gap", "W heads close_gap")
        for _, k in ipairs({ "item_ghost", "item_glimmer_cape", "item_silver_edge",
                             "item_invis_sword", "item_force_staff", "item_hurricane_pike" }) do
            assert_true(has(c, k), "PA chain should keep " .. k)
        end
        assert_false(has(c, "item_black_king_bar"), "PA is physical -> drop BKB")
        assert_false(has(c, "item_blink"),
            "axis withholds blink from attack-delivery (charge re-homes rule is delivery-scoped)")
    end)

    -- LEAP (Slark): derives invuln + displacement_blink -> keeps airborne + blink.
    it("Slark composed: W head + airborne (WW/cyclone) + blink + displacement", function()
        local c = composed_close_gap("modifier_slark_pounce")
        assert_eq(c[1], "lina_w_anti_gap", "W heads close_gap")
        for _, k in ipairs({ "item_cyclone", "item_wind_waker", "item_blink",
                             "item_force_staff", "item_hurricane_pike", "item_black_king_bar" }) do
            assert_true(has(c, k), "Slark chain should keep " .. k)
        end
    end)

    -- CHARGE (Bara, homing_charge): axis withholds invuln (latched) AND blink
    -- (re-homes) -> composed loses the validated WW airborne intercept. This is
    -- why Bara/Tusk STAY overrides (kept mechanical exceptions, not migrated).
    it("Bara composed LACKS airborne+blink -> documents why charges stay overrides", function()
        local c = composed_close_gap("modifier_spirit_breaker_charge_of_darkness")
        assert_false(has(c, "item_wind_waker"),
            "charge: latched -> no invuln -> WW filtered -> composed cannot reproduce the validated intercept")
        assert_false(has(c, "item_cyclone"), "ditto (Eul/cyclone)")
        assert_false(has(c, "item_blink"), "charge re-homes on blink (axis decision)")
        for _, k in ipairs({ "item_black_king_bar", "item_force_staff", "item_hurricane_pike" }) do
            assert_true(has(c, k), "Bara composed still keeps " .. k)
        end
    end)
end)

describe("lib/defense -- v0.5.127 CD-aware lock release", function()
    -- White-box test of the general re-engage structure: a HELD in-flight lock
    -- is released early (before its resolved TTL) once the fired save is
    -- confirmed spent, so a re-engage dispatch advances to the NEXT ready save.
    -- We drive TryAcquireLock directly and stamp save_short the way Dispatch
    -- does on a successful fire (the lock entry is a public field on the
    -- dispatcher object). ent indices are plain numbers (ent_idx treats numeric
    -- inputs as already-an-index).
    local function make_disp(item_on_cd, coalesce, giveup)
        local clock = { t = 0 }
        local d = Defense.New({
            tlog               = function() end,
            now                = function() return clock.t end,
            entity_index       = function(e) return e end,
            item_on_cd         = item_on_cd,   -- nil => opt-out (full TTL)
            lock_cd_coalesce_s = coalesce,     -- nil => lib default 0.30
            lock_cd_giveup_s   = giveup,       -- nil => lib default 0.60
        })
        return d, clock
    end
    -- Acquire a lock at t=0 and stamp save_short like Dispatch's success path.
    local function armed(d, target, mod, caster, ttl, save_short)
        d:TryAcquireLock(target, mod, caster, ttl)
        d.in_flight_locks[target][mod][caster].save_short = save_short
    end

    it("opt-out (no item_on_cd): a live lock blocks for its full TTL", function()
        local d, clock = make_disp(nil)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.5  -- well past any coalesce floor, far short of the 2.0 TTL
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_false(ok, "without item_on_cd the lock holds for the resolved TTL (v0.5.40)")
    end)

    it("within the coalesce floor: blocks even when on CD (single-spend)", function()
        local d, clock = make_disp(function() return true end)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.10  -- < 0.30 floor: same-instance multi-path dispatch
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_false(ok, "must block within the coalesce floor to coalesce one instance")
    end)

    it("past floor + save confirmed on CD: releases so the re-engage proceeds", function()
        local d, clock = make_disp(function() return true end)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.35  -- > 0.30 floor, spent
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_true(ok, "a spent save past the floor releases (chain skips it, fires next)")
    end)

    it("past floor, not on CD, within give-up: still blocks (confirming the cast)", function()
        local d, clock = make_disp(function() return false end)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.40  -- > floor 0.30, < give-up 0.60
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_false(ok, "not-yet-on-CD within the give-up window holds to confirm the fire")
    end)

    it("past give-up + still not on CD: releases for re-attempt", function()
        local d, clock = make_disp(function() return false end)
        armed(d, 1, "modifier_x", 2, 2.0, "item_hurricane_pike")
        clock.t = 0.65  -- > give-up 0.60
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_true(ok, "never-on-CD past the give-up window releases so the chain re-attempts")
    end)

    it("thunk save_short keeps the full TTL (not CD-checkable)", function()
        local d, clock = make_disp(function() return true end)
        armed(d, 1, "modifier_x", 2, 2.0, "thunk")
        clock.t = 0.50
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_false(ok, "offensive thunk fires are unnameable -> full TTL")
    end)

    it("TTL backstop still frees the lock regardless of the CD logic", function()
        local d, clock = make_disp(function() return false end)
        armed(d, 1, "modifier_x", 2, 0.4, "item_hurricane_pike")
        clock.t = 0.50  -- past fire_t+ttl (0.4): lazy expiry frees it
        local ok = d:TryAcquireLock(1, "modifier_x", 2, 2.0)
        assert_true(ok, "an expired lock frees via lazy expiry independent of item_on_cd")
    end)

    it("custom windows are honoured (coalesce 0.5 / give-up 1.0)", function()
        local d, clock = make_disp(function() return true end, 0.5, 1.0)
        armed(d, 1, "modifier_x", 2, 3.0, "item_hurricane_pike")
        clock.t = 0.40  -- < custom 0.5 floor, even though on CD
        assert_false(d:TryAcquireLock(1, "modifier_x", 2, 3.0), "below custom floor: hold")
        clock.t = 0.55  -- > custom floor, on CD
        assert_true(d:TryAcquireLock(1, "modifier_x", 2, 3.0), "above custom floor + on CD: release")
    end)
end)

describe("fog probe <-> analyzer format contract (v0.1.353)", function()
    -- The probe's format string lives in Tinker/Tinker.lua (which this suite cannot load:
    -- it needs the engine) and its ONLY consumer is a Lua pattern in
    -- tools/parse_debuglog.lua. Nothing couples them, so editing one silently breaks the
    -- other and the failure surfaces as a MISSING section in the report AFTER a game has
    -- been spent. This repo has shipped that exact failure twice (the v0.1.348 walk_leg
    -- instrument that was born dead, and the v0.1.346 keen probe that lied), so pin the
    -- contract by reading BOTH out of the real sources and proving they still agree.
    local function slurp(p)
        local f = assert(io.open(p, "r"), "cannot open " .. p .. " (run the suite from the repo root)")
        local s = f:read("*a"); f:close(); return s
    end
    local tf0 = io.open("Tinker/Tinker.lua", "r")
    if not tf0 then
        print("  SKIP  fog-probe<->analyzer contract: Tinker/Tinker.lua not present in this tree")
        return
    end
    tf0:close()
    local tinker = slurp("Tinker/Tinker.lua")
    local parser = slurp("tools/parse_debuglog.lua")

    local hero_fmt = tinker:match('"(fog_hero raw=[^"]+)"')
    local hero_pat = parser:match('"(fog_hero raw=[^"]+)"')
    local probe_fmt = tinker:match('"(fog_probe t=[^"]+)"')
    local probe_pat = parser:match('"(fog_probe [^"]+)"')

    it("both sides of the contract are still present in the sources", function()
        assert_true(hero_fmt ~= nil, "no fog_hero format string found in Tinker.lua")
        assert_true(hero_pat ~= nil, "no fog_hero pattern found in parse_debuglog.lua")
        assert_true(probe_fmt ~= nil, "no fog_probe format string found in Tinker.lua")
        assert_true(probe_pat ~= nil, "no fog_probe pattern found in parse_debuglog.lua")
    end)

    it("a normal fog_hero line the probe emits is parsed by the analyzer", function()
        local line = string.format(hero_fmt, "200.0", "-100.0", "3.4", 900, "npc_dota_hero_pudge")
        local raw, areal, d, nm = line:match(hero_pat)
        assert_eq(raw, "200.0")
        assert_eq(areal, "3.4")
        assert_eq(d, "900")
        assert_eq(nm, "npc_dota_hero_pudge")
    end)

    it("a NEGATIVE d is parsed: the probe emits d=-1 when the hero origin is unreadable", function()
        -- enemy_snapshot sets `local d = -1` when origin(State.hero) returns nil, which is
        -- reachable (Entity.GetAbsOrigin throws on a stale handle at game teardown - the
        -- v0.1.258 pcall guard exists for exactly that). A pattern demanding %d+ drops the
        -- line silently, undercounting `reads` and corrupting the nil-share denominator.
        local line = string.format(hero_fmt, "nil", "nil", "nil", -1, "npc_dota_hero_lion")
        local raw, _, d = line:match(hero_pat)
        assert_eq(raw, "nil")
        assert_eq(d, "-1")
    end)

    it("a nil raw and an unknown name still parse", function()
        local line = string.format(hero_fmt, "nil", "nil", "nil", 4000, "?")
        local raw, _, d, nm = line:match(hero_pat)
        assert_eq(raw, "nil")
        assert_eq(d, "4000")
        assert_eq(nm, "?")
    end)

    it("the fog_probe line parses, including a negative offset", function()
        -- v0.1.354 added vtrack/vev/vtypes AFTER off=, so the format takes 7 args now.
        -- This test failed the moment those fields were added, which is exactly its job:
        -- the probe and its parser live in different files with nothing else coupling them.
        -- v0.1.409 added vsh= (8th arg). This test failing on the field add is exactly its job.
        local line = string.format(probe_fmt, 100.0, -103.4, 1, 2, 3, 4, "1:5", 2)
        -- the analyzer pattern captures t FIRST (added when the pregame outlier was excluded),
        -- so off is the SECOND capture. This test caught that change the moment it was made.
        local _t, off = line:match(probe_pat)
        assert_eq(off, "-103.4")
    end)
end)

describe("tools/parse_debuglog --fog-shadow contracts (v0.1.409)", function()
    -- The mode's patterns EXTRACTED from the analyzer source, never duplicated literals
    -- (same idiom as the B14 fog-probe contract: read both real files and prove they
    -- agree). An analyzer-side pattern edit that stops matching these emitter-shaped
    -- fixtures fails here; a duplicated literal could not see such an edit.
    local parser do
        local f = io.open("tools/parse_debuglog.lua", "r")
        if f then parser = f:read("*a"); f:close() end
    end
    local function pat_of(name)
        return parser and parser:match('local%s+' .. name .. '%s*=%s*"([^"]+)"') or nil
    end
    local p_live, p_sh = pat_of("p_live_pat"), pat_of("p_sh_pat")
    local c_live, c_sh = pat_of("c_live_pat"), pat_of("c_sh_pat")
    local age_pat, vsh_pat = pat_of("age_pat"), pat_of("vsh_pat")

    it("all six mode patterns extract from parse_debuglog.lua (renamed = contract dead)", function()
        assert_true(parser ~= nil, "cannot open tools/parse_debuglog.lua (run from the repo root)")
        for nm, v in pairs({ p_live_pat = p_live, p_sh_pat = p_sh, c_live_pat = c_live,
                             c_sh_pat = c_sh, age_pat = age_pat, vsh_pat = vsh_pat }) do
            assert_true(v ~= nil, "pattern " .. nm .. " not found in parse_debuglog.lua")
        end
    end)

    it("a farm row with both prisk fields pairs in EITHER field order", function()
        -- the emitter walks the kv table with pairs(), so a real line can print the
        -- shadow rider first; the shadow-first fixture also pins that "prisk=" does
        -- not false-match inside "prisk_sh=" (it would read 0.00 here, not 0.43)
        for _, ln in ipairs({
            "[INFO] [Tinker] farm | gpm=400 | prisk=0.43 | t=524.3 | prisk_sh=0.00 | cap=10",
            "[INFO] [Tinker] farm | gpm=400 | prisk_sh=0.00 | t=524.3 | prisk=0.43 | cap=10",
        }) do
            assert_eq(ln:match(p_live), "0.43"); assert_eq(ln:match(p_sh), "0.00")
        end
    end)

    it("a camp row with both crisk fields pairs in EITHER field order", function()
        for _, ln in ipairs({
            "[INFO] [Tinker] farm | cval=170 | crisk=0.26 | crisk_sh=0.91 | t=546.7",
            "[INFO] [Tinker] farm | cval=170 | crisk_sh=0.91 | crisk=0.26 | t=546.7",
        }) do
            assert_eq(ln:match(c_live), "0.26"); assert_eq(ln:match(c_sh), "0.91")
        end
    end)

    it("a live-only row reads live but yields no shadow (counts live-only, never a pair)", function()
        local ln = "[INFO] [Tinker] farm | cval=170 | crisk=0.26 | t=546.7"
        assert_eq(ln:match(c_live), "0.26"); assert_true(ln:match(c_sh) == nil)
    end)

    it("a numeric age_real parses; the nil form does not (never-seen stays excluded)", function()
        assert_eq(("fog_hero raw=nil age_now=nil age_real=7.4 d=1200 name=x"):match(age_pat), "7.4")
        assert_true(("fog_hero raw=nil age_now=nil age_real=nil d=1200 name=x"):match(age_pat) == nil)
    end)

    it("the vsh health read captures fog count and shadow count together", function()
        local tinker = io.open("Tinker/Tinker.lua"):read("a")
        local probe_fmt = tinker:match('"(fog_probe t=[^"]+)"')
        assert_true(probe_fmt ~= nil and probe_fmt:find("vsh=%%d") ~= nil, "the emitter must carry vsh=")
        local ln = string.format(probe_fmt, 10.0, -1.0, 1, 3, 0, 40, "0/false:2", 3)
        local fog, vsh = ln:match(vsh_pat)
        assert_eq(fog, "3"); assert_eq(vsh, "3")
    end)
end)

describe("lib/escape.Vision -- shared last-seen tracker (v0.1.354; absorbed at v0.1.399)", function()
    local Vision = require("lib.escape").Vision
    -- The lib OWNS its clock (reading GlobalVars.GetCurTime), so tests drive time by
    -- replacing that stub rather than injecting a clock - no test-only API in production
    -- code. Same idiom as the lib/defense modifier tests. The harness stub is restored at
    -- the end of this block, since `describe` runs its body inline and later suites read it.
    local function at(t) GlobalVars.GetCurTime = function() return t end end
    local HERO, CREEP = { id = "hero" }, { id = "creep" }
    local _vsav = { ih = NPC.IsHero, dm = Entity.IsDormant, ct = GlobalVars.GetCurTime }
    local function with_engine(dormant_set)
        NPC.IsHero = function(e) return e ~= CREEP end
        Entity.IsDormant = function(e) return dormant_set[e] == true end
    end

    it("a hero going dormant is stamped, and Age grows with the clock", function()
        local d = { [HERO] = true }
        with_engine(d); at(100)
        Vision.OnSetDormant_handler(HERO, 1)
        at(106)
        local a = Vision.Age(HERO)
        assert_true(a ~= nil and math.abs(a - 6.0) < 1e-6, "expected 6.0, got " .. tostring(a))
    end)

    it("a VISIBLE hero reads age 0 regardless of any stamp", function()
        local d = { [HERO] = true }
        with_engine(d); at(100)
        Vision.OnSetDormant_handler(HERO, 1)
        d[HERO] = false                       -- came back into vision
        at(200)
        assert_eq(Vision.Age(HERO), 0)
    end)

    it("SAFETY VALVE: a never-observed hero returns nil so callers keep today's behaviour", function()
        -- THE pin that makes a three-hero blast radius survivable. nil (not 0) lets each
        -- consumer apply its own default; escape.lua's `or 0` then reproduces the exact
        -- pre-vision behaviour. If this ever returns 0, an empty tracker would silently
        -- become a real signal.
        -- the real valve case: DORMANT (so we cannot see it) and never observed going
        -- dormant, so there is no stamp. A hero that is merely VISIBLE is age 0, and that
        -- is correct - the first draft of this test got that wrong and the pin caught it.
        local UNSEEN = { id = "unseen" }
        with_engine({ [UNSEEN] = true })
        assert_true(Vision.Age(UNSEEN) == nil, "dormant + never observed must be nil, not 0")
        local VIS = { id = "visible_unseen" }
        with_engine({})
        assert_eq(Vision.Age(VIS), 0, "a VISIBLE hero is age 0 even if never stamped")
    end)

    it("non-heroes are ignored (creeps enter and leave fog constantly)", function()
        local d = { [CREEP] = true }
        with_engine(d); at(100)
        Vision.OnSetDormant_handler(CREEP, 1)
        at(200)
        assert_true(Vision.Age(CREEP) == nil, "a creep must never be tracked")
    end)

    it("the dtype is the gate now: an unknown value is recorded but never trusted", function()
        -- v0.1.410 flip: the dtype IS the trusted gate (g401: 73 windows, zero
        -- contradictions). The handler-time Entity.IsDormant read stamps NOTHING any more -
        -- g401 proved it reads false inside the callback - so an unknown dtype must not
        -- stamp even when the probe read says dormant. The probe still records the value.
        local U999 = { id = "unknown_dtype" }
        local d = { [U999] = true }
        with_engine(d); at(50)
        Vision.OnSetDormant_handler(U999, 999)
        at(55)
        assert_true(Vision.Age(U999) == nil,
            "an unknown dtype must never stamp; got " .. tostring(Vision.Age(U999)))
        assert_true(Vision.Stats().types["999/true"] ~= nil,
            "the probe must still record the 999/true key")
    end)

    it("Wire chains onto an existing handler and is idempotent per table", function()
        local hits = 0
        local cbs = { OnSetDormant = function() hits = hits + 1 end }
        Vision.Wire(cbs); Vision.Wire(cbs)     -- the second call must not double-chain
        with_engine({}); at(10)
        cbs.OnSetDormant(HERO, 1)
        assert_eq(hits, 1, "the pre-existing handler must run exactly once")
    end)

    it("Wire adds ONLY OnSetDormant - no marker field leaks into the callbacks table", function()
        -- hero scripts do `for k, fn in pairs(callbacks) do callbacks[k] = wrap(fn) end` and
        -- then hand the table to UCZone to register. A marker field would be wrapped as if
        -- it were a callback and registered as one, so the wired-set lives inside the lib.
        local cbs = {}
        Vision.Wire(cbs)
        local keys = {}
        for k, v in pairs(cbs) do keys[#keys + 1] = k
            assert_eq(type(v), "function", "every entry must be callable: " .. tostring(k)) end
        assert_eq(#keys, 1, "exactly one key expected, got " .. #keys)
        assert_eq(keys[1], "OnSetDormant")
    end)

    it("Stats reports events and records the observed type values", function()
        local d = { [HERO] = true }
        with_engine(d); at(10)
        local before = Vision.Stats().events
        Vision.OnSetDormant_handler(HERO, 7)
        local s = Vision.Stats()
        assert_eq(s.events, before + 1)
        -- v0.1.355: the key is `<type>/<what Entity.IsDormant returned>`. The second half is
        -- the whole point of the diagnostic - g354 showed events=584 / tracked=0, and only the
        -- verbatim return distinguishes "the CNPC handle was rejected" (nil) from "it really
        -- read not-dormant at handler time" (false).
        assert_true(s.types["7/true"] ~= nil, "type AND the IsDormant return must be recorded")
    end)

    it("the IsDormant return is recorded verbatim: false and nil must not collapse", function()
        -- THE g354 BUG SHAPE. `x and f(x) or nil` maps a `false` return to nil, which would
        -- erase the one distinction the next log has to make. Both must survive to the key.
        with_engine({ [HERO] = false }); at(10)          -- present, reads NOT dormant
        Vision.OnSetDormant_handler(HERO, 3)
        local saved = Entity.IsDormant
        Entity.IsDormant = function() return nil end     -- the "handle rejected" shape
        Vision.OnSetDormant_handler(HERO, 3)
        Entity.IsDormant = saved
        local s = Vision.Stats()
        assert_true(s.types["3/false"] ~= nil, "a false return must record as false, not nil")
        assert_true(s.types["3/nil"] ~= nil, "a nil return must record as nil, not false")
    end)

    -- restore every global this block overrode, for the suites that follow
    NPC.IsHero, Entity.IsDormant = _vsav.ih, _vsav.dm
    GlobalVars.GetCurTime = _vsav.ct or function() return 0 end
end)

describe("lib/escape.Vision -- SHADOW tracker (v0.1.409 build 1, kept as self-check through the v0.1.410 build 2 flip, TINKER_FOG_TRACKER_DESIGN)", function()
    local Vision = require("lib.escape").Vision
    local function at(t) GlobalVars.GetCurTime = function() return t end end
    local SH1, SH2, SH3, SH4, SHCREEP = { id = "sh1" }, { id = "sh2" }, { id = "sh3" }, { id = "sh4" }, { id = "shcreep" }
    local _sav = { ih = NPC.IsHero, dm = Entity.IsDormant, ct = GlobalVars.GetCurTime }
    local dormant = {}
    local function with_engine()
        NPC.IsHero = function(e) return e ~= SHCREEP end
        Entity.IsDormant = function(e) return dormant[e] == true end
    end

    it("the REAL engine shape now stamps BOTH trackers (the v0.1.410 flip)", function()
        -- g401 proved the callback fires BEFORE the engine applies the dormancy flag
        -- (vtypes reads 0/false and 1/false, never nil), so IsDormant is false HERE.
        -- Build 1 stamped only the shadow off the dtype; the flip rides the SAME gate for
        -- the live table, so a fogged enemy finally gets a real live age. This is the pin
        -- for the defect the whole arc existed to fix.
        with_engine(); at(100)
        Vision.OnSetDormant_handler(SH1, 1)
        dormant[SH1] = true          -- the engine applies the flag AFTER the callback
        at(107)
        local a = Vision.Age(SH1)
        assert_true(a ~= nil and math.abs(a - 7.0) < 1e-6, "live age expected 7.0, got " .. tostring(a))
        local ash = Vision.AgeShadow(SH1)
        assert_true(ash ~= nil and math.abs(ash - 7.0) < 1e-6, "shadow age expected 7.0, got " .. tostring(ash))
    end)

    it("dtype 0 (LEAVING dormancy) does not stamp the shadow", function()
        with_engine(); at(100)
        Vision.OnSetDormant_handler(SH2, 0)
        dormant[SH2] = true
        at(105)
        assert_true(Vision.AgeShadow(SH2) == nil, "dtype 0 must not stamp")
    end)

    it("a stringable dtype stamps too (tostring compare), live and shadow alike", function()
        with_engine(); at(200)
        Vision.OnSetDormant_handler(SH3, "1")
        dormant[SH3] = true
        at(203)
        local a = Vision.AgeShadow(SH3)
        assert_true(a ~= nil and math.abs(a - 3.0) < 1e-6, "string dtype expected 3.0, got " .. tostring(a))
        local al = Vision.Age(SH3)
        assert_true(al ~= nil and math.abs(al - 3.0) < 1e-6,
            "the flipped live gate must stamp on a string dtype too, got " .. tostring(al))
    end)

    it("AgeShadow is 0 for a hero visible NOW, even if stamped earlier", function()
        with_engine(); at(300)
        Vision.OnSetDormant_handler(SH4, 1)
        dormant[SH4] = false         -- back in vision
        at(310)
        assert_eq(Vision.AgeShadow(SH4), 0)
    end)

    it("a creep is never shadow-tracked", function()
        with_engine(); at(400)
        Vision.OnSetDormant_handler(SHCREEP, 1)
        dormant[SHCREEP] = true
        assert_true(Vision.AgeShadow(SHCREEP) == nil, "creeps must never be tracked")
    end)

    it("Stats reports the shadow count", function()
        local s = Vision.Stats()
        assert_true(type(s.tracked_sh) == "number", "tracked_sh missing from Stats")
        assert_true(s.tracked_sh >= 3, "SH1, SH3, SH4 were stamped above; got " .. tostring(s.tracked_sh))
    end)

    NPC.IsHero = _sav.ih; Entity.IsDormant = _sav.dm
    GlobalVars.GetCurTime = _sav.ct or function() return 0 end
end)

describe("lib/escape.Vision -- shadow store migrates an OLD-shape store (FUTURE-FIELDS rule)", function()
    -- A mid-session lib upgrade attaches to a store created by a PRE-v0.1.409 escape.lua,
    -- which has no last_seen_sh. The attach-time default must add it, never crash.
    local _sav = { ih = NPC.IsHero, dm = Entity.IsDormant, ct = GlobalVars.GetCurTime }
    it("attach adds last_seen_sh to a store that lacks it", function()
        local store = package.loaded["__LIB_VISION_STORE"]
        assert_true(store ~= nil, "the store must exist after the requires above")
        store.last_seen_sh = nil                    -- simulate the old shape
        package.loaded["lib.escape"] = nil          -- force the chunk to re-run and re-attach
        local V2 = require("lib.escape").Vision
        assert_true(type(package.loaded["__LIB_VISION_STORE"].last_seen_sh) == "table",
            "attach must default last_seen_sh")
        local MH = { id = "mig" }
        local dormant = {}
        NPC.IsHero = function() return true end
        Entity.IsDormant = function(e) return dormant[e] == true end
        GlobalVars.GetCurTime = function() return 500 end
        V2.OnSetDormant_handler(MH, 1)
        dormant[MH] = true
        GlobalVars.GetCurTime = function() return 504 end
        local a = V2.AgeShadow(MH)
        assert_true(a ~= nil and math.abs(a - 4.0) < 1e-6, "re-attached module must stamp; got " .. tostring(a))
    end)
    NPC.IsHero = _sav.ih; Entity.IsDormant = _sav.dm
    GlobalVars.GetCurTime = _sav.ct or function() return 0 end
end)

describe("lib/escape.Vision.ShadowAges -- shadow-aged snapshot copy (v0.1.409 build 1)", function()
    local Vision = require("lib.escape").Vision
    local _sav = { ih = NPC.IsHero, dm = Entity.IsDormant, ct = GlobalVars.GetCurTime }
    local dormant = {}
    NPC.IsHero = function() return true end
    Entity.IsDormant = function(e) return dormant[e] == true end
    local function at(t) GlobalVars.GetCurTime = function() return t end end
    local FA, FB = { id = "fa" }, { id = "fb" }

    it("re-ages fogged rows from the shadow tracker; visible rows stay age 0; input untouched", function()
        at(100); Vision.OnSetDormant_handler(FB, 1); dormant[FB] = true
        at(104)
        local snap = { t = 104, heroes = {
            { entity = FA, pos = { x = 1, y = 2 }, age = 0, visible = true },
            { entity = FB, pos = { x = 3, y = 4 }, age = 0, visible = false, probable_radius = 0 },
        } }
        local sh = Vision.ShadowAges(snap)
        assert_eq(sh.t, 104)
        assert_eq(sh.heroes[1].age, 0)
        assert_true(math.abs(sh.heroes[2].age - 4.0) < 1e-6, "fogged row expected 4.0, got " .. tostring(sh.heroes[2].age))
        assert_eq(sh.heroes[2].pos.x, 3)
        assert_eq(snap.heroes[2].age, 0, "the INPUT snapshot must never be mutated")
    end)

    it("clamps a stale shadow age exactly like FogSnapshot clamps live ages (30s)", function()
        at(100 + 200)   -- FB stamped at 100 above; 200s later
        local snap = { t = 300, heroes = { { entity = FB, pos = { x = 0, y = 0 }, age = 0, visible = false } } }
        local sh = Vision.ShadowAges(snap)
        assert_eq(sh.heroes[1].age, 30)
    end)

    it("a never-stamped fogged hero reads age 0 (the nil safety valve, same as live)", function()
        local NEVER = { id = "fnever" }
        dormant[NEVER] = true
        local snap = { t = 1, heroes = { { entity = NEVER, pos = { x = 0, y = 0 }, age = 0, visible = false } } }
        assert_eq(Vision.ShadowAges(snap).heroes[1].age, 0)
    end)

    it("nil and hero-less snapshots pass through", function()
        assert_true(Vision.ShadowAges(nil) == nil)
        local empty = { t = 5 }
        assert_true(Vision.ShadowAges(empty) == empty)
    end)

    NPC.IsHero = _sav.ih; Entity.IsDormant = _sav.dm
    GlobalVars.GetCurTime = _sav.ct or function() return 0 end
end)

describe("lib/escape -- FogSnapshot consumes the Vision section (v0.1.354)", function()
    local Escape = require("lib.escape")
    local Vision = Escape.Vision
    local ME    = { id = "me" }
    local ENEMY = { id = "enemy" }
    -- SAVE every global this block overrides. A previous draft replaced
    -- Entity.GetAbsOrigin with a PLAIN TABLE and did not restore it, so a later geometry
    -- test called :Distance2D on it and died - the type-boundary class, self-inflicted via
    -- test pollution. Restored at the end of the block.
    local _sav = { ga = Heroes.GetAll, tn = Entity.GetTeamNum, dm = Entity.IsDormant,
                   ao = Entity.GetAbsOrigin, mh = Hero.GetLastMaphackPos,
                   ih = NPC.IsHero, ct = GlobalVars.GetCurTime }

    -- FogSnapshot's real dependency set, stubbed so the AGE PATH actually runs. The existing
    -- suite only ever stubbed FogSnapshot itself, so this branch had no coverage at all -
    -- which is part of why a dead getter sat in it unnoticed.
    local function with_engine(dormant, now_t)
        Heroes.GetAll        = function() return { ENEMY } end
        Entity.GetTeamNum    = function(e) return e == ME and 2 or 3 end
        Entity.IsDormant     = function(e) return e == ENEMY and dormant or false end
        Entity.GetAbsOrigin  = function() return { x = 0, y = 0, z = 0 } end
        Hero.GetLastMaphackPos = function() return { x = 100, y = 0, z = 0 } end
        NPC.IsHero           = function() return true end
        GlobalVars.GetCurTime = function() return now_t end
    end

    it("SAFETY VALVE end to end: an unobserved fogged enemy snapshots at age 0", function()
        -- Vision.Age returns nil (never observed going dormant) -> escape's `or 0` -> age 0
        -- -> probable_radius 0 -> full confidence. That is byte-for-byte the behaviour every
        -- hero had BEFORE lib/vision existed, which is what makes shipping this to three
        -- heroes at once survivable.
        with_engine(true, 500)
        local snap = Escape.FogSnapshot(ME, { max_ms = 550 })
        assert_eq(#snap.heroes, 1)
        assert_false(snap.heroes[1].visible)
        assert_eq(snap.heroes[1].age, 0, "unobserved must read age 0, not a real age")
        assert_eq(snap.heroes[1].probable_radius, 0)
    end)

    it("a TRACKED fogged enemy now snapshots with a REAL age and a grown disc", function()
        -- the whole point of the arc: this was impossible before, because
        -- Hero.GetLastVisibleTime returned nil on 405/405 reads.
        with_engine(true, 100)
        Vision.OnSetDormant_handler(ENEMY, 1)      -- stamped at t=100
        with_engine(true, 104)                     -- 4s later, still fogged
        local snap = Escape.FogSnapshot(ME, { max_ms = 550 })
        assert_eq(#snap.heroes, 1)
        assert_true(math.abs(snap.heroes[1].age - 4.0) < 1e-6,
            "expected age 4.0, got " .. tostring(snap.heroes[1].age))
        assert_true(math.abs(snap.heroes[1].probable_radius - 4.0 * 550) < 1e-6,
            "the probable disc must grow with the real age")
    end)

    it("a VISIBLE enemy is age 0 with no disc, whatever the tracker holds", function()
        with_engine(false, 900)                    -- back in vision, stamp from the test above
        local snap = Escape.FogSnapshot(ME, { max_ms = 550 })
        assert_true(snap.heroes[1].visible)
        assert_eq(snap.heroes[1].age, 0)
        assert_eq(snap.heroes[1].probable_radius, 0)
    end)

    -- restore EVERY override, or the next suite inherits plain-table origins
    Heroes.GetAll, Entity.GetTeamNum, Entity.IsDormant = _sav.ga, _sav.tn, _sav.dm
    Entity.GetAbsOrigin, Hero.GetLastMaphackPos, NPC.IsHero = _sav.ao, _sav.mh, _sav.ih
    GlobalVars.GetCurTime = _sav.ct or function() return 0 end
end)

describe("lib/escape.Vision -- the anchored store survives a cache-clear re-require (v0.1.399)", function()
    -- THE phase-3 judge-5 pin. Tinker.lua AND Lina.lua both nil package.loaded['lib.escape']
    -- at load; without the package.loaded-pseudo-key anchor each hero would fork an EMPTY tracker with every gate
    -- green, and Lina/Sniper would read eternally-empty fog ages. This suite does exactly what
    -- the heroes do and asserts the state survives.
    local Escape = require("lib.escape")
    local _sav = { ih = NPC.IsHero, dm = Entity.IsDormant, ct = GlobalVars.GetCurTime }
    NPC.IsHero = function() return true end
    Entity.IsDormant = function() return true end
    local HERO = { id = "reload_hero" }

    it("a stamp written before the cache-clear re-require is readable after it", function()
        GlobalVars.GetCurTime = function() return 1000 end
        Escape.Vision.OnSetDormant_handler(HERO, 1)
        package.loaded["lib.escape"] = nil                 -- what both hero scripts do at load
        local Escape2 = require("lib.escape")
        assert_true(Escape2 ~= Escape, "the re-require must build a FRESH module instance")
        GlobalVars.GetCurTime = function() return 1006 end
        local a = Escape2.Vision.Age(HERO)
        assert_true(a ~= nil and math.abs(a - 6.0) < 1e-6,
            "the age must survive the reload; got " .. tostring(a))
    end)

    it("Wire idempotence survives the reload: the wired-set lives in the store", function()
        -- the detectable contract is NO RE-WRAP: a second Wire on an already-wired table must
        -- leave the handler IDENTITY untouched. (Counting the pre-existing handler's hits
        -- cannot catch a double-wrap - the original still runs once inside the outer wrapper.)
        local cbs = { OnSetDormant = function() end }
        require("lib.escape").Vision.Wire(cbs)
        local wrapped = cbs.OnSetDormant
        package.loaded["lib.escape"] = nil
        require("lib.escape").Vision.Wire(cbs)             -- a FRESH instance wires the SAME table
        assert_true(cbs.OnSetDormant == wrapped,
            "a second Wire across a reload must not re-wrap: the wired-set forked")
    end)

    NPC.IsHero, Entity.IsDormant = _sav.ih, _sav.dm
    GlobalVars.GetCurTime = _sav.ct or function() return 0 end
end)

describe("lib/defense -- modifier remaining-time reads (v0.1.352 phantom-API fix)", function()
    -- NPC.GetModifierRemaining DOES NOT EXIST in the UCZone API. The documented path is
    -- NPC.GetModifier -> Modifier.GetDieTime, differenced against GameRules.GetGameTime.
    -- These pins did not exist before: the whole resolver family had ZERO coverage, which
    -- is why a call to a non-existent function survived unnoticed.
    local Defense = require("lib.defense")
    local UNIT = { id = "unit" }

    -- install a fake engine for the modifier path; returns a restore function
    local function with_engine(die_time, game_time, has_mod)
        local oldNPCget, oldMod, oldGR = NPC.GetModifier, Modifier, GameRules
        NPC.GetModifier = function(_, _) return (has_mod ~= false) and { m = true } or nil end
        Modifier = { GetDieTime = function(_) return die_time end }
        GameRules = { GetGameTime = function() return game_time end }
        return function() NPC.GetModifier, Modifier, GameRules = oldNPCget, oldMod, oldGR end
    end

    it("Remaining returns the REAL remaining seconds, not the floor", function()
        local restore = with_engine(107.5, 100.0)          -- 7.5s left
        local r = Defense.EtaResolvers.Remaining("modifier_bane_fiends_grip", nil, 0.1)
        local v = r(nil, UNIT, nil, nil, 0)
        restore()
        assert_true(math.abs(v - 7.5) < 1e-6, "expected 7.5, got " .. tostring(v))
    end)

    it("Remaining still honours cap_s and floor_s around the real read", function()
        local restore = with_engine(110.0, 100.0)          -- 10s left
        local capped = Defense.EtaResolvers.Remaining("m", 2.0, 0.1)(nil, UNIT, nil, nil, 0)
        restore()
        assert_true(math.abs(capped - 2.0) < 1e-6, "cap_s must clamp the real read")
        local restore2 = with_engine(100.01, 100.0)        -- 0.01s left
        local floored = Defense.EtaResolvers.Remaining("m", nil, 0.5)(nil, UNIT, nil, nil, 0)
        restore2()
        assert_true(math.abs(floored - 0.5) < 1e-6, "floor_s must still apply")
    end)

    it("a missing modifier falls back to the floor (unchanged behaviour)", function()
        local restore = with_engine(107.5, 100.0, false)   -- GetModifier returns nil
        local v = Defense.EtaResolvers.Remaining("m", nil, 0.5)(nil, UNIT, nil, nil, 0)
        restore()
        assert_true(math.abs(v - 0.5) < 1e-6, "no modifier: floor, never a guess")
    end)

    it("a CLOCK MISMATCH degrades to the floor instead of inventing a long lock", function()
        -- the fog-age bug in this codebase was exactly a cross-clock subtraction; a die time
        -- on one clock minus a now on another yields nonsense. Both directions must be refused.
        local neg = with_engine(90.0, 100.0)               -- already expired -> negative
        local v1 = Defense.EtaResolvers.Remaining("m", nil, 0.5)(nil, UNIT, nil, nil, 0)
        neg()
        assert_true(math.abs(v1 - 0.5) < 1e-6, "negative remaining must not pass through")
        local huge = with_engine(1000.0, 100.0)            -- 900s: a pregame-offset style mismatch
        local v2 = Defense.EtaResolvers.Remaining("m", nil, 0.5)(nil, UNIT, nil, nil, 0)
        huge()
        assert_true(math.abs(v2 - 0.5) < 1e-6, "an implausible remaining must not become the lock")
    end)

    it("no Modifier/GameRules bindings at all: floor, no crash", function()
        local oldMod, oldGR, oldGet = Modifier, GameRules, NPC.GetModifier
        Modifier, GameRules, NPC.GetModifier = nil, nil, nil
        local ok, v = pcall(function()
            return Defense.EtaResolvers.Remaining("m", nil, 0.5)(nil, UNIT, nil, nil, 0)
        end)
        Modifier, GameRules, NPC.GetModifier = oldMod, oldGR, oldGet
        assert_true(ok, "an absent modifier API must never throw")
        assert_true(math.abs(v - 0.5) < 1e-6, "absent API: floor")
    end)

    it("the generic resolver's no-catalog arm reads the real remaining, capped by lock_cap_s", function()
        local TD = { THREAT_ARRIVAL_TIMING = {} }          -- no catalog entry: the 168-modifier path
        local restore = with_engine(105.0, 100.0)          -- 5s left, lock_cap_s default 1.7
        local v = Defense.MakeGenericEtaResolver(TD)(nil, UNIT, nil, nil, 0, "modifier_x")
        restore()
        assert_true(math.abs(v - 1.7) < 1e-6, "expected the 1.7 cap, got " .. tostring(v))
    end)

    it("an EXPIRED modifier reads as unreadable, not as a tiny lock (pins the rem<=0 guard)", function()
        -- without the lower guard a negative remaining reaches site 1 and is silently
        -- floored, and site 3 returns 0.1 instead of nil - both look plausible in a log.
        local TD = { THREAT_ARRIVAL_TIMING = {} }
        local restore = with_engine(95.0, 100.0)           -- died 5s ago
        local v = Defense.MakeGenericEtaResolver(TD)(nil, UNIT, nil, nil, 0, "modifier_x")
        restore()
        assert_true(v == nil, "an expired modifier must yield nil, got " .. tostring(v))
    end)

    it("NaN is refused by the sanity band (it passes every comparison)", function()
        -- NaN <= 0 and NaN > MAX are BOTH false, so a subtraction-form guard would let it
        -- through; it then propagates through clamp_ttl into a lock that never expires.
        local TD = { THREAT_ARRIVAL_TIMING = {} }
        local restore = with_engine(0 / 0, 100.0)
        local v = Defense.MakeGenericEtaResolver(TD)(nil, UNIT, nil, nil, 0, "modifier_x")
        restore()
        assert_true(v == nil, "NaN must be refused, got " .. tostring(v))
        local restore2 = with_engine(0 / 0, 100.0)
        local v2 = Defense.EtaResolvers.Remaining("m", nil, 0.5)(nil, UNIT, nil, nil, 0)
        restore2()
        assert_true(v2 == 0.5, "NaN at site 1 must floor, got " .. tostring(v2))
    end)

    it("the generic resolver returns nil (-> caller's fallback) when the read is unavailable", function()
        local TD = { THREAT_ARRIVAL_TIMING = {} }
        local restore = with_engine(105.0, 100.0, false)   -- no modifier on the unit
        local v = Defense.MakeGenericEtaResolver(TD)(nil, UNIT, nil, nil, 0, "modifier_x")
        restore()
        assert_true(v == nil, "unreadable must stay nil so resolve_ttl uses fallback_lock_ttl_s")
    end)

    it("channel_at_caster reads the CASTER side, and falls through to cast_point when unreadable", function()
        local TD = { THREAT_ARRIVAL_TIMING = { modifier_x = { kind = "channel_at_caster", cast_point = 0.4 } } }
        local restore = with_engine(101.0, 100.0)          -- 1.0s left on the caster
        local v = Defense.MakeGenericEtaResolver(TD)(UNIT, nil, nil, nil, 0, "modifier_x")
        restore()
        assert_true(math.abs(v - 1.0) < 1e-6, "caster-side remaining wins, got " .. tostring(v))
        local restore2 = with_engine(101.0, 100.0, false)  -- unreadable -> cast_point arm
        local v2 = Defense.MakeGenericEtaResolver(TD)(UNIT, nil, nil, nil, 0, "modifier_x")
        restore2()
        assert_true(math.abs(v2 - 0.4) < 1e-6, "must fall through to cast_point, got " .. tostring(v2))
    end)
end)

describe("SAVE_KIND dispel vocabulary", function()
    local TD = require("lib.threat_data")
    it("strong-dispel items carry dispel_strong, not dispel_basic", function()
        for _, item in ipairs({ "item_aeon_disk", "item_disperser" }) do
            local kinds = TD.SAVE_KIND[item]
            local has_strong, has_basic = false, false
            for _, k in ipairs(kinds) do
                if k == "dispel_strong" then has_strong = true end
                if k == "dispel_basic" then has_basic = true end
            end
            assert_true(has_strong, item .. " must carry dispel_strong")
            assert_false(has_basic, item .. " must NOT carry dispel_basic")
        end
    end)
    it("basic-dispel items keep dispel_basic only", function()
        for _, item in ipairs({ "item_manta", "item_diffusal_blade", "item_satanic" }) do
            local kinds = TD.SAVE_KIND[item]
            local has_basic = false
            for _, k in ipairs(kinds) do if k == "dispel_basic" then has_basic = true end end
            assert_true(has_basic, item .. " must keep dispel_basic")
        end
    end)
end)

describe("DeriveCounters magical/pure/universal", function()
    local TD = require("lib.threat_data")
    local function has(set, k) for _,x in ipairs(set) do if x==k then return true end end return false end
    it("no-damage magical disable -> magic_immune via school, not damage_type", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="none",
            pierces_spell_immunity=false, dispellable="strong", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"magic_immune"), "BKB blocks the disable application")
        assert_false(has(d,"magic_barrier"), "no damage -> no barrier")
    end)
    it("pure + pierces -> no magic_immune, no barrier (Doom class)", function()
        local d = TD.DeriveCounters({ school="pure", damage_type="pure",
            pierces_spell_immunity=true, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="disable" })
        assert_false(has(d,"magic_immune"), "Doom pierces BKB")
        assert_false(has(d,"magic_barrier"), "pure ignores barrier")
    end)
    it("partial pierce still gets magic_immune", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity="partial", dispellable="none", delivery="homing_charge",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"magic_immune"), "only literal true suppresses")
    end)
    it("magic_barrier only when primary_harm == damage", function()
        local nuke = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage" })
        assert_true(has(nuke,"magic_barrier"))
        local disable = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="homing_charge",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_false(has(disable,"magic_barrier"), "token-damage disable: no barrier")
    end)
end)

describe("DeriveCounters physical/dispel/reflect", function()
    local TD = require("lib.threat_data")
    local function has(set, k) for _,x in ipairs(set) do if x==k then return true end end return false end
    it("physical attack chase -> phys_immune, damage_block, invis, self-push", function()
        local d = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="basic", delivery="attack",
            targeted=false, timing="pre_cast", primary_harm="damage",
            forced_leash=false, debuff_sticks_to_self=false })
        for _,k in ipairs({"physical_immune","damage_block","invis","displacement_far","displacement_perp"}) do
            assert_true(has(d,k), "expected "..k)
        end
        assert_false(has(d,"damage_return"), "damage_return is per-entry opt-in only")
    end)
    it("forced_leash suppresses invis + displacement (Duel)", function()
        local d = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="none", delivery="attack",
            targeted=false, timing="pre_cast", primary_harm="damage", forced_leash=true })
        assert_false(has(d,"invis")); assert_false(has(d,"displacement_far"))
    end)
    it("strong-only dispel -> dispel_strong only; basic -> both", function()
        local strong = TD.DeriveCounters({ school="magical", damage_type="none",
            pierces_spell_immunity=false, dispellable="strong", delivery="spell",
            targeted=true, timing="reactive", primary_harm="disable" })
        assert_true(has(strong,"dispel_strong")); assert_false(has(strong,"dispel_basic"))
        local basic = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="basic", delivery="channel",
            targeted=false, timing="mid_channel", primary_harm="disable" })
        assert_true(has(basic,"dispel_basic")); assert_true(has(basic,"dispel_strong"))
    end)
    it("dispel suppressed at at_impact (debuff not present yet)", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="strong", delivery="projectile_line",
            targeted=false, timing="at_impact", primary_harm="damage" })
        assert_false(has(d,"dispel_strong"), "no debuff at impact window")
    end)
    it("reflect only for cast-time single-target spell harm", function()
        local yes = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage", lotus_reflectable=true })
        assert_true(has(yes,"reflect_target"))
        local no = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="channel",
            targeted=true, timing="mid_channel", primary_harm="disable" })
        assert_false(has(no,"reflect_target"), "channels are not reflected")
    end)
end)

describe("DeriveCounters displacement + overrides", function()
    local TD = require("lib.threat_data")
    local function has(set, k) for _,x in ipairs(set) do if x==k then return true end end return false end
    it("homing_charge -> at_source+perp, NOT blink/far", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity="partial", dispellable="none", delivery="homing_charge",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"displacement_at_source")); assert_true(has(d,"displacement_perp"))
        assert_false(has(d,"displacement_blink"), "charge re-homes on blink")
        assert_false(has(d,"displacement_far"), "self-push delay-only vs homing")
    end)
    it("leap -> perp+blink+invuln, NOT at_source", function()
        local d = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="leap",
            targeted=true, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"displacement_perp")); assert_true(has(d,"displacement_blink"))
        assert_true(has(d,"invuln"), "leap is dodged by the airborne save (WW/Eul)")
        assert_false(has(d,"displacement_at_source"))
    end)
    it("leap keeps invuln at ANY timing (explicit rule, v0.5.143)", function()
        -- A leap lands ON the target, so untargetable/invuln at impact whiffs it
        -- (DEMO-PROVEN v0.5.142: Lina WW-dodged Huskar Life Break, the _slow never
        -- landed). The universal invuln rule only fires for pre_cast/at_impact;
        -- the explicit leap branch must add invuln for any other timing too, so the
        -- airborne save never silently drops. timing=post_apply skips the universal.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="leap",
            targeted=true, timing="post_apply", primary_harm="damage" })
        assert_true(has(d,"invuln"), "explicit leap rule keeps the airborne save regardless of timing")
    end)
    it("forced_leash leap drops invuln (cyclone cannot break a leash)", function()
        -- guard: a leashing leap is NOT dodged by going airborne (the leash
        -- reapplies), matching the universal rule's forced_leash exclusion.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="leap",
            targeted=true, timing="post_apply", primary_harm="disable",
            forced_leash=true })
        assert_false(has(d,"invuln"), "forced_leash leap keeps invuln out")
    end)
    it("projectile_line -> perp+far+blink; projectile_homing -> blink only", function()
        local line = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="none", delivery="projectile_line",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_true(has(line,"displacement_far")); assert_true(has(line,"displacement_perp"))
        local hom = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="projectile_homing",
            targeted=false, timing="at_impact", primary_harm="damage" })
        assert_true(has(hom,"displacement_blink"))
        assert_false(has(hom,"displacement_far"), "homing missile re-targets")
    end)
    it("channel -> channel_break + at_source + tether displacement", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="basic", delivery="channel",
            targeted=true, timing="mid_channel", primary_harm="disable", positional=false })
        assert_true(has(d,"channel_break")); assert_true(has(d,"displacement_at_source"))
        assert_true(has(d,"displacement_far"))
    end)
    it("positional AoE -> perp+far+blink; barrier zone -> no blink", function()
        local zone = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=false, timing="pre_cast", primary_harm="damage", positional=true,
            blocks_forced_movement=false })
        assert_true(has(zone,"displacement_far")); assert_true(has(zone,"displacement_blink"))
        local wall = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="spell",
            targeted=false, timing="reactive", primary_harm="disable", positional=true,
            blocks_forced_movement=true })
        assert_true(has(wall,"displacement_perp"))
        assert_false(has(wall,"displacement_blink"), "barrier blocks blink")
    end)
    it("drop_kinds / add_kinds applied last", function()
        local d = TD.DeriveCounters({ school="pure", damage_type="pure",
            pierces_spell_immunity=true, dispellable="none", delivery="projectile_line",
            targeted=false, timing="at_impact", primary_harm="disable",
            drop_kinds={"invuln"}, add_kinds={"displacement_far"} })
        assert_false(has(d,"invuln"), "drop_kinds removed it")
        assert_true(has(d,"displacement_far"))
    end)
end)

describe("DeriveCounters gate coverage (suppression paths)", function()
    local TD = require("lib.threat_data")
    local function has(set, k) for _,x in ipairs(set) do if x==k then return true end end return false end

    it("mid_channel suppresses magic_immune (Fiend's Grip class)", function()
        -- BKB cannot strip an already-active channel debuff.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="basic", delivery="channel",
            targeted=true, timing="mid_channel", primary_harm="disable" })
        assert_false(has(d,"magic_immune"), "no BKB out of an active channel")
    end)
    it("enemy_self_buff suppresses dispel (Ursa Overpower class)", function()
        local d = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="attack",
            targeted=false, timing="reactive", primary_harm="disable",
            enemy_self_buff=true })
        assert_false(has(d,"dispel_basic"), "cannot dispel a buff on the enemy")
        assert_false(has(d,"dispel_strong"))
    end)
    it("attack_enabler suppresses dispel (PA Strike marker class)", function()
        local d = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="attack",
            targeted=false, timing="reactive", primary_harm="disable",
            attack_enabler=true })
        assert_false(has(d,"dispel_basic"), "dispelling the marker does not stop the attacks")
    end)
    it("displacement primary_harm suppresses dispel (cannot dispel a knockback)", function()
        local d = TD.DeriveCounters({ school="none", damage_type="none",
            pierces_spell_immunity=false, dispellable="basic", delivery="leap",
            targeted=true, timing="reactive", primary_harm="displacement" })
        assert_false(has(d,"dispel_basic"), "no dispel for pure displacement")
    end)
    it("line_charge -> perp+far+blink (same as projectile_line)", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="line_charge",
            targeted=false, timing="pre_cast", primary_harm="disable" })
        assert_true(has(d,"displacement_perp")); assert_true(has(d,"displacement_far"))
        assert_true(has(d,"displacement_blink"))
    end)
    it("positional channel -> channel_break + zone displacement, no tether-only far via channel branch double", function()
        -- A positional AoE channel (targeted=false): channel branch adds
        -- channel_break + at_source (and NOT the tether far/perp/blink because
        -- positional); the positional-AoE branch then adds perp+far+blink.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="channel",
            targeted=false, timing="mid_channel", primary_harm="damage",
            positional=true, blocks_forced_movement=false })
        assert_true(has(d,"channel_break")); assert_true(has(d,"displacement_at_source"))
        assert_true(has(d,"displacement_far")); assert_true(has(d,"displacement_blink"))
    end)
    it("lotus_reflectable=false suppresses reflect_target", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage",
            lotus_reflectable=false })
        assert_false(has(d,"reflect_target"), "explicitly un-reflectable")
    end)
    it("already_locked_channel suppresses invis (Omnislash class)", function()
        local d = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="none", delivery="attack",
            targeted=false, timing="mid_channel", primary_harm="damage",
            already_locked_channel=true })
        assert_true(has(d,"physical_immune"), "Ghost still works")
        assert_false(has(d,"invis"), "invis useless under a locked channel")
    end)
    it("debuff_sticks_to_self suppresses physical self-push (Open Wounds class)", function()
        local d = TD.DeriveCounters({ school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="basic", delivery="attack",
            targeted=false, timing="reactive", primary_harm="damage",
            debuff_sticks_to_self=true })
        assert_false(has(d,"displacement_far"), "pushing away does not shed the debuff")
        assert_false(has(d,"displacement_perp"))
    end)
    it("severity=survivable adds magic_resist cushion", function()
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage",
            severity="survivable" })
        assert_true(has(d,"magic_resist"), "Glimmer/Solar cushion for survivable magic")
    end)
    it("positional branch is nil-safe: omitted targeted (nil) still fires displacement", function()
        -- Profiles omit default-false booleans, so a non-targeted positional zone
        -- has targeted==nil. The positional branch must use `not p.targeted`, not
        -- `== false` (nil == false is false in Lua). Regression for the LSA/
        -- Freezing-Field displacement_far drop.
        local d = TD.DeriveCounters({ school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            timing="pre_cast", primary_harm="damage", positional=true })
            -- NOTE: targeted intentionally OMITTED (nil)
        assert_true(has(d,"displacement_far"), "positional zone must give displacement_far even when targeted is nil")
        assert_true(has(d,"displacement_perp"))
    end)
end)

describe("tier-3 compose-time counter filter", function()
    local Defense = require("lib.defense")
    local TD = require("lib.threat_data")

    local function mk()
        TD.THREAT_PROFILE = TD.THREAT_PROFILE or {}
        TD.THREAT_PROFILE["test_phys_chase"] = { school="physical", damage_type="physical",
            pierces_spell_immunity=false, dispellable="none", delivery="attack",
            targeted=false, timing="pre_cast", primary_harm="damage" }
        TD.THREAT_PROFILE["test_magic_nuke"] = { school="magical", damage_type="magical",
            pierces_spell_immunity=false, dispellable="none", delivery="spell",
            targeted=true, timing="pre_cast", primary_harm="damage" }
        TD.THREAT_COUNTER["test_phys_chase"] = TD.DeriveCounters(TD.THREAT_PROFILE["test_phys_chase"])
        TD.THREAT_COUNTER["test_magic_nuke"] = TD.DeriveCounters(TD.THREAT_PROFILE["test_magic_nuke"])
        TD.CATEGORY_CHAINS.test_cat = { "item_ghost", "item_blade_mail", "item_pipe", "item_hurricane_pike" }
        local d = Defense.New({
            TD = TD,
            ability_injections = { { save="hero_ability_x", categories={"test_cat"}, anchor="head" } },
            hero_save_overrides = {}, anim_save_overrides = {}, patched_recommended = {},
            category_chains = {}, default_chain = {},
            tlog = function() end,
        })
        -- v0.1.399 hygiene: TD IS the shared require("lib.threat_data") module, so this stub
        -- must be restored in the cleanup test below or an in-process suite RE-RUN fails
        -- (found when double-running became the natural check for the anchored vision store).
        _td_real_categoryof = _td_real_categoryof or d.cfg.TD.CategoryOf
        d.cfg.TD.CategoryOf = function() return "test_cat" end
        return d
    end
    local function inchain(chain, x) for _,c in ipairs(chain) do if c==x then return true end end return false end

    it("magic nuke keeps pipe (magic_barrier), drops ghost/blade_mail/pike", function()
        local d = mk()
        local chain = d:ResolveSaveOrder("test_magic_nuke", nil, nil, nil)
        assert_eq(chain[1], "hero_ability_x")  -- injected ability survives the filter
        assert_true(inchain(chain, "item_pipe"), "magic_barrier counters a magic nuke")
        assert_false(inchain(chain, "item_ghost"), "physical_immune does not counter magic")
        assert_false(inchain(chain, "item_hurricane_pike"), "displacement does not counter a target-locked nuke")
    end)
    it("phys chase keeps ghost + pike, drops pipe", function()
        local d = mk()
        local chain = d:ResolveSaveOrder("test_phys_chase", nil, nil, nil)
        assert_true(inchain(chain, "item_ghost"), "physical_immune counters a physical chase")
        assert_true(inchain(chain, "item_hurricane_pike"), "self-push counters a chase")
        assert_false(inchain(chain, "item_pipe"), "magic_barrier useless vs physical")
    end)
    it("cache key is per (category, threat) not per category", function()
        local d = mk()
        d:ResolveSaveOrder("test_magic_nuke", nil, nil, nil)
        d:ResolveSaveOrder("test_phys_chase", nil, nil, nil)
        assert_true(d._composed_cache["test_cat|test_magic_nuke"] ~= nil, "magic-nuke key missing")
        assert_true(d._composed_cache["test_cat|test_phys_chase"] ~= nil, "phys-chase key missing")
    end)
    -- cleanup so test fixtures don't leak into other describe-blocks
    it("cleanup test fixtures", function()
        TD.CATEGORY_CHAINS.test_cat = nil
        TD.THREAT_PROFILE["test_phys_chase"] = nil
        TD.THREAT_PROFILE["test_magic_nuke"] = nil
        TD.THREAT_COUNTER["test_phys_chase"] = nil
        TD.THREAT_COUNTER["test_magic_nuke"] = nil
        if _td_real_categoryof then TD.CategoryOf = _td_real_categoryof end   -- v0.1.399 hygiene
        assert_true(true)
    end)
end)

describe("migration correctness (42 known threats)", function()
    local TD = require("lib.threat_data")
    local function set_eq(got, want)
        local sg, sw = {}, {}
        for _,x in ipairs(got) do sg[x]=true end
        for _,x in ipairs(want) do sw[x]=true end
        for k in pairs(sg) do if not sw[k] then return false, k.." extra" end end
        for k in pairs(sw) do if not sg[k] then return false, k.." missing" end end
        return true
    end
    local EXPECT = {
        ["modifier_abyssal_underlord_pit_of_malice_ensare"] = { "magic_immune", "displacement_perp", "displacement_far", "dispel_basic", "dispel_strong" },
        ["modifier_axe_berserkers_call"] = { "physical_immune", "damage_block" },
        ["modifier_bane_fiends_grip"] = { "invuln", "dispel_strong", "channel_break", "displacement_at_source" },
        ["modifier_bane_nightmare"] = { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_crystal_maiden_freezing_field"] = { "magic_immune", "magic_barrier", "channel_break", "displacement_at_source", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_disruptor_kinetic_field"] = { "displacement_perp", "displacement_far" },
        ["modifier_disruptor_static_storm_thinker"] = { "magic_immune", "magic_barrier", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_doom_bringer_doom"] = { "invuln", "reflect_target" },
        ["modifier_earth_spirit_rolling_boulder"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_earthshaker_echo_slam"] = { "invuln", "magic_immune", "magic_barrier" },
        ["modifier_enigma_black_hole"] = { "channel_break", "displacement_at_source", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kez_grappling_claw_slow"] = { "invuln", "physical_immune", "damage_block", "displacement_far", "displacement_perp", "displacement_blink", "reflect_target" },
        ["modifier_legion_commander_duel"] = { "physical_immune", "damage_block" },
        ["modifier_life_stealer_open_wounds"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_lina_laguna_blade"] = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
        ["modifier_lina_light_strike_array"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_lion_finger_of_death"] = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
        ["modifier_lion_mana_drain"] = { "invuln", "magic_immune", "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_lion_voodoo"] = { "invuln", "magic_immune", "reflect_target", "dispel_strong" },
        ["modifier_magnataur_reverse_polarity_stun"] = { "invuln" },
        ["modifier_magnataur_skewer"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_mirana_arrow"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_naga_siren_ensnare"] = { "magic_immune", "displacement_blink", "invuln", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_phantom_assassin_phantom_strike_target"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp" },
        ["modifier_pudge_dismember"] = { "invuln", "dispel_strong", "channel_break", "displacement_at_source" },
        ["modifier_pudge_dismember_pull"] = { "invuln", "dispel_strong", "channel_break", "displacement_at_source" },
        ["modifier_pudge_meat_hook"] = { "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_pugna_life_drain"] = { "invuln", "magic_immune", "magic_barrier", "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_razor_static_link_debuff"] = { "invuln", "reflect_target" },
        ["modifier_shadow_shaman_shackles"] = { "invuln", "magic_immune", "dispel_strong", "channel_break", "displacement_at_source" },
        ["modifier_shadow_shaman_voodoo"] = { "invuln", "magic_immune", "reflect_target", "dispel_strong" },
        ["modifier_slark_pounce"] = { "invuln", "magic_immune", "displacement_perp", "displacement_blink" },
        ["modifier_spirit_breaker_charge_of_darkness"] = { "magic_immune", "displacement_at_source", "displacement_perp" },
        ["modifier_sven_storm_bolt"] = { "invuln", "magic_immune", "reflect_target", "displacement_blink" },
        ["modifier_tidehunter_ravage"] = { "invuln", "magic_immune" },
        ["modifier_treant_overgrowth"] = { "dispel_basic", "dispel_strong", "displacement_perp", "displacement_far" },
        ["modifier_tusk_ice_shards_thinker"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_tusk_snowball_movement"] = { "magic_immune", "magic_barrier", "displacement_at_source", "displacement_perp" },
        ["modifier_ursa_overpower"] = { "invuln", "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp" },
        ["modifier_witch_doctor_death_ward"] = { "invuln", "invis", "channel_break", "displacement_at_source", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_zuus_lightning_bolt"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_zuus_thundergods_wrath"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_alchemist_unstable_concoction"] = { "magic_immune" },
        ["modifier_ancient_apparition_bone_chill_debuff"] = { "magic_immune" },
        ["modifier_ancientapparition_coldfeet_freeze"] = { "magic_immune", "dispel_strong" },
        ["modifier_arc_warden_flux"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_batrider_flaming_lasso"] = { "reflect_target" },
        ["modifier_beastmaster_primal_roar"] = { "invuln", "reflect_target" },
        ["modifier_blinding_light_knockback"] = { "invuln", "magic_immune" },
        ["modifier_bloodseeker_rupture"] = { "invuln", "reflect_target" },
        ["modifier_bounty_hunter_shuriken_toss"] = { "invuln", "magic_immune" },
        ["modifier_brewmaster_cinder_brew"] = { "dispel_basic", "dispel_strong", "magic_immune" },
        ["modifier_bristleback_viscous_nasal_goo"] = { "dispel_basic", "dispel_strong", "magic_immune" },
        ["modifier_broodmother_sticky_snare"] = { "dispel_basic", "dispel_strong", "magic_immune", "magic_barrier" },
        ["modifier_chaos_knight_chaos_bolt"] = { "invuln", "magic_immune", "reflect_target", "dispel_strong" },
        ["modifier_chaos_knight_reality_rift"] = { "dispel_basic" },
        ["modifier_chen_penitence"] = { "dispel_basic", "dispel_strong", "magic_immune" },
        ["modifier_chilling_touch_slow"] = { "dispel_basic", "dispel_strong" },
        ["modifier_chilling_touch_super_slow"] = { "dispel_basic", "dispel_strong" },
        ["modifier_cold_feet"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_crystal_maiden_frostbite"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_dark_seer_ion_shell"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_dark_seer_vacuum"] = { "invuln", "magic_immune" },
        ["modifier_dark_willow_bramble_maze"] = { "magic_immune", "dispel_basic", "dispel_strong", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_dark_willow_cursed_crown"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_dark_willow_terrorize"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_dawnbreaker_celestial_hammer"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_dazzle_poison_touch"] = { "dispel_basic", "dispel_strong" },
        ["modifier_death_prophet_silence"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_doom_bringer_infernal_blade"] = { "invuln", "magic_immune" },
        ["modifier_dragon_knight_dragon_tail"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_drow_ranger_frost_arrows_slow"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp", "dispel_basic", "dispel_strong" },
        ["modifier_earth_spirit_rolling_boulder_caster"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_earthshaker_earthsplitter"] = { "invuln", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_earthshaker_fissure_stun"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink", "dispel_strong" },
        ["modifier_ember_spirit_sleight_of_fist_caster"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp", "invuln" },
        ["modifier_enigma_malefice"] = { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_faceless_void_chronosphere"] = { "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_faceless_void_chronosphere_freeze"] = { "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_faceless_void_time_dilation_distortion"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_faceless_void_timelock_freeze"] = { "dispel_strong" },
        ["modifier_furion_sprout"] = { "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_grimstroke_ink_creature"] = { "invuln", "magic_immune" },
        ["modifier_grimstroke_soul_chain"] = { "displacement_blink" },
        ["modifier_gyrocopter_call_down_slow"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_gyrocopter_homing_missile"] = { "invuln", "magic_immune", "displacement_blink" },
        ["modifier_hoodwink_bushwhack"] = { "invuln", "magic_immune" },
        ["modifier_huskar_life_break_charge"] = { "invuln", "displacement_perp", "displacement_blink", "magic_barrier" },
        ["modifier_ice_blast"] = { "invuln", "magic_barrier" },
        ["modifier_ice_vortex"] = { "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_invoker_cold_snap"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_jakiro_ice_path"] = { "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_jakiro_macropyre_thinker"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_juggernaut_omni_slash"] = { "physical_immune", "damage_block" },
        ["modifier_keeper_of_the_light_blinding_light"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_keeper_of_the_light_radiant_bind"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_keeper_of_the_light_will_o_wisp"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kez_raptor_dance"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kunkka_torrent_stun"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kunkka_torrent_thinker"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_kunkka_x_marks_the_spot"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_largo_catchy_lick"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_largo_catchy_lick_knockback"] = { "invuln", "magic_immune" },
        ["modifier_largo_croak_of_genius_debuff"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_largo_frogstomp_debuff"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_legion_commander_intimidate_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_leshrac_split_earth"] = { "invuln", "magic_immune" },
        ["modifier_lich_chain_frost"] = { "magic_immune", "magic_barrier", "dispel_basic", "dispel_strong" },
        ["modifier_lich_sinister_gaze"] = { "dispel_basic", "dispel_strong", "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_lone_druid_spirit_bear_entangle_effect"] = { "dispel_basic", "dispel_strong" },
        ["modifier_magnataur_shockwave_pull"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_magnataur_skewer_impact"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink", "magic_immune" },
        ["modifier_magnataur_skewer_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_maledict"] = { "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_maledict_dot"] = { "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_marci_grapple"] = { "invuln", "magic_immune" },
        ["modifier_mars_arena_of_blood"] = { "magic_immune", "displacement_perp", "displacement_far" },
        ["modifier_mars_gods_rebuke"] = { "invuln", "damage_block" },
        ["modifier_mars_spear"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_medusa_gorgon_grasp"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_medusa_mystic_snake"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_meepo_earthbind"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_monkey_king_wukongs_command_aura"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp" },
        ["modifier_morphling_adaptive_strike_agi"] = { "magic_immune", "displacement_blink" },
        ["modifier_muerta_dead_shot"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink", "dispel_basic", "dispel_strong" },
        ["modifier_naga_siren_song_of_the_siren"] = { "invuln", "magic_immune" },
        ["modifier_necrolyte_heartstopper_aura_effect"] = { "magic_barrier", "magic_resist" },
        ["modifier_necrolyte_reapers_scythe"] = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
        ["modifier_nevermore_requiem"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_night_stalker_void"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_nyx_assassin_impale"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_nyx_assassin_vendetta"] = { "invuln" },
        ["modifier_obsidian_destroyer_astral_imprisonment"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_obsidian_destroyer_sanity_eclipse"] = { "invuln", "magic_immune", "magic_barrier" },
        ["modifier_ogre_magi_fireblast"] = { "invuln", "magic_immune", "reflect_target", "dispel_strong" },
        ["modifier_omniknight_hammer_of_purity"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp", "dispel_basic", "dispel_strong" },
        ["modifier_oracle_fortunes_end_channel_target"] = { "dispel_basic", "dispel_strong", "channel_break", "displacement_at_source", "invuln", "magic_immune" },
        ["modifier_oracle_fortunes_end_purge"] = { "dispel_basic", "dispel_strong" },
        ["modifier_oracle_purifying_flames"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "reflect_target" },
        ["modifier_pangolier_gyroshell"] = { "displacement_at_source", "displacement_perp" },
        ["modifier_pangolier_swashbuckle"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_phantom_assassin_stiflingdagger"] = { "invuln", "displacement_blink" },
        ["modifier_phantom_lancer_spirit_lance"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_blink" },
        ["modifier_phoenix_sun_ray"] = { "magic_barrier", "magic_resist", "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_primal_beast_onslaught"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_primal_beast_pulverize"] = { "channel_break", "displacement_at_source", "displacement_far", "displacement_perp", "displacement_blink" },
        ["modifier_puck_dream_coil"] = { "magic_immune" },
        ["modifier_puck_waning_rift"] = { "invuln", "magic_immune" },
        ["modifier_rattletrap_hookshot"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_razor_eye_of_the_storm_armor"] = {  },
        ["modifier_razor_plasma_field_slow"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_razor_storm_surge_slow"] = { "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_riki_smoke_screen"] = { "magic_immune" },
        ["modifier_ringmaster_impalement"] = { "invuln", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink", "magic_immune" },
        ["modifier_ringmaster_the_box"] = {  },
        ["modifier_ringmaster_wheel"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_rubick_fade_bolt_debuff"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_rubick_telekinesis_stun"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_sand_king_epicenter"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_sandking_burrowstrike"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_shadow_demon_demonic_purge"] = { "invuln", "magic_barrier", "reflect_target" },
        ["modifier_shadow_demon_disruption"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_shredder_chakram"] = { "invuln", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_silencer_last_word"] = { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_skeleton_king_reincarnate_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_skeleton_king_reincarnation_spawn_skeletons"] = {  },
        ["modifier_skywrath_mage_ancient_seal"] = { "invuln", "magic_immune", "reflect_target", "dispel_basic", "dispel_strong" },
        ["modifier_skywrath_mage_concussive_shot_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_skywrath_mage_mystic_flare_thinker"] = { "invuln", "magic_immune", "magic_barrier", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_skywrath_mystic_flare_aura_effect"] = { "invuln", "magic_immune", "magic_barrier", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_slardar_amplify_damage"] = { "invuln", "reflect_target" },
        ["modifier_slardar_slithereen_crush"] = { "invuln" },
        ["modifier_snapfire_lil_shredder_debuff"] = { "physical_immune", "damage_block", "invis", "displacement_far", "displacement_perp" },
        ["modifier_snapfire_magma_burn_slow"] = { "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_snapfire_mortimer_kisses"] = { "magic_immune", "magic_barrier", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_snapfire_scatterblast_slow"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_sniper_assassinate"] = { "invuln", "magic_immune", "magic_barrier", "reflect_target" },
        ["modifier_spectre_spectral_dagger"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_spectre_spectral_dagger_in_path"] = { "magic_immune", "dispel_basic", "dispel_strong", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_spirit_breaker_nether_strike"] = { "invuln", "displacement_perp", "displacement_blink" },
        ["modifier_templar_assassin_psionic_trap"] = { "magic_immune", "dispel_basic", "dispel_strong", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_tinker_laser"] = { "invuln", "reflect_target" },
        ["modifier_tiny_avalanche"] = { "invuln", "magic_immune", "magic_barrier" },
        ["modifier_tiny_avalanche_stun"] = { "invuln", "magic_immune" },
        ["modifier_tiny_toss"] = { "invuln", "magic_immune", "magic_barrier" },
        ["modifier_troll_warlord_whirling_axes_slow"] = { "invuln", "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_tusk_snowball_target"] = { "magic_immune", "displacement_at_source", "displacement_perp" },
        ["modifier_tusk_tag_team_attack_slow"] = {  },
        ["modifier_tusk_tag_team_slow"] = {  },
        ["modifier_tusk_walrus_punch_air_time"] = { "dispel_basic", "dispel_strong" },
        ["modifier_tusk_walrus_punch_slow"] = { "dispel_basic", "dispel_strong" },
        ["modifier_undying_decay"] = { "invuln", "magic_immune", "magic_barrier", "magic_resist" },
        ["modifier_vengefulspirit_nether_swap"] = { "invuln" },
        ["modifier_vengefulspirit_retribution_tracker"] = {  },
        ["modifier_venomancer_venomous_gale"] = { "magic_immune", "magic_barrier", "magic_resist", "dispel_basic", "dispel_strong" },
        ["modifier_viper_corrosive_skin_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_viper_nethertoxin"] = { "magic_immune", "magic_barrier", "magic_resist", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_viper_nethertoxin_mute"] = { "magic_immune", "displacement_perp", "displacement_far", "displacement_blink" },
        ["modifier_viper_poison_attack_slow"] = { "magic_immune", "dispel_basic", "dispel_strong" },
        ["modifier_visage_grave_chill"] = { "invuln", "magic_immune", "reflect_target" },
        ["modifier_void_spirit_aether_remnant"] = { "invuln", "magic_immune" },
        ["modifier_void_spirit_astral_step"] = { "invuln", "magic_barrier", "magic_resist" },
        ["modifier_weaver_swarm_debuff"] = {  },
        ["modifier_windrunner_shackleshot"] = { "invuln", "magic_immune", "dispel_strong", "displacement_blink" },
        ["modifier_winter_wyvern_winters_curse"] = { "invuln", "reflect_target" },
        ["modifier_witch_doctor_maledict"] = { "magic_immune", "magic_barrier", "magic_resist" },
    }
    local mods = {}                       -- sorted: pairs() order is unspecified, so registering
    for mod in pairs(EXPECT) do mods[#mods + 1] = mod end   -- straight off the hash made the
    table.sort(mods)                      -- suite's OUTPUT ORDER vary run to run (not diffable)
    for _, mod in ipairs(mods) do
        local want = EXPECT[mod]
        it("derives correct set for "..mod, function()
            local prof = TD.THREAT_PROFILE[mod]
            assert_true(prof ~= nil, "no profile for "..mod)
            local ok, why = set_eq(TD.DeriveCounters(prof), want)
            assert_true(ok, mod..": "..tostring(why))
        end)
    end
    it("THREAT_COUNTER assembled for every profiled threat", function()
        for mod in pairs(TD.THREAT_PROFILE) do
            assert_true(TD.THREAT_COUNTER[mod] ~= nil, "not assembled: "..mod)
        end
    end)
end)

describe("enriched backbones filter correctly (Task 8)", function()
    local TD = require("lib.threat_data")
    local function survivors(chain, mod)
        local k = {}
        for _, it in ipairs(chain) do if TD.SaveCounters(it, mod) then k[#k + 1] = it end end
        return k
    end
    local function has(lst, x) for _, v in ipairs(lst) do if v == x then return true end end return false end

    it("trap vs barrier/root traps keeps knockback (Force/Pike), drops blink", function()
        for _, m in ipairs({ "modifier_disruptor_kinetic_field",
                             "modifier_abyssal_underlord_pit_of_malice_ensare" }) do
            local s = survivors(TD.CATEGORY_CHAINS.trap, m)
            assert_true(#s > 0, "trap composed empty for " .. m)
            assert_true(has(s, "item_force_staff") or has(s, "item_hurricane_pike"),
                "no knockback survives for " .. m)
            assert_false(has(s, "item_blink"),
                "blink must be filtered (blocks_forced_movement) for " .. m)
        end
    end)
    it("channel_on_self vs Omnislash keeps physical answers (Ghost)", function()
        local s = survivors(TD.CATEGORY_CHAINS.channel_on_self, "modifier_juggernaut_omni_slash")
        assert_true(#s > 0, "Omnislash composed empty")
        assert_true(has(s, "item_ghost"), "Ghost (physical_immune) must survive vs Omnislash")
    end)
    it("close_gap vs a magic charge drops physical-only items, keeps the magic answers", function()
        -- Spirit Breaker Charge: magical disable, does not pierce.
        local s = survivors(TD.CATEGORY_CHAINS.close_gap, "modifier_spirit_breaker_charge_of_darkness")
        assert_false(has(s, "item_blade_mail"), "damage_return does not counter a magical charge")
        assert_false(has(s, "item_ghost"), "physical_immune does not counter a magical charge")
        assert_true(has(s, "item_black_king_bar"), "BKB counters a non-piercing magical disable")
    end)
    it("no category composes to empty for any threat that HAS counters", function()
        local bycat = {}
        for mod, c in pairs(TD.THREAT_CATEGORY or {}) do
            bycat[c] = bycat[c] or {}; table.insert(bycat[c], mod)
        end
        for c, chain in pairs(TD.CATEGORY_CHAINS) do
            for _, m in ipairs(bycat[c] or {}) do
                local ctr = TD.THREAT_COUNTER[m]
                if ctr and #ctr > 0 then
                    assert_true(#survivors(chain, m) > 0,
                        "category " .. c .. " composes empty for " .. m
                        .. " (counters exist: " .. table.concat(ctr, ",") .. ")")
                end
            end
        end
    end)
end)

local Geometry = require("lib.geometry")

describe("lib/geometry -- DiscReachPoint / BestReachLanding (Keen/BoT reach landing)", function()
    it("lands ON the target when it is inside the reach disc", function()
        local lx, ly, res = Geometry.DiscReachPoint(0, 0, 700, 300, 0)
        assert_eq(lx, 300); assert_eq(ly, 0); assert_eq(res, 0)
    end)
    it("lands on the disc edge toward the target when it is beyond reach", function()
        local lx, ly, res = Geometry.DiscReachPoint(0, 0, 700, 1000, 0)   -- edge (700,0), residual 300
        assert_eq(lx, 700); assert_eq(ly, 0); assert_eq(res, 300)
    end)
    it("picks the anchor whose landing is nearest the target (both beyond reach)", function()
        local anchors = { { pos = {x=0,y=0}, r=300 }, { pos = {x=600,y=0}, r=100 } }
        local b = Geometry.BestReachLanding(anchors, {x=1000,y=0})
        -- a1 edge (300,0) res 700 ; a2 edge (700,0) res 300 -> a2 wins
        assert_eq(b.anchor.pos.x, 600); assert_eq(b.lx, 700); assert_eq(b.residual, 300)
    end)
    it("prefers an anchor that covers the target (residual 0) over a nearer-centre one", function()
        local anchors = { { pos = {x=0,y=0}, r=300 }, { pos = {x=1200,y=0}, r=250 } }
        local b = Geometry.BestReachLanding(anchors, {x=1000,y=0})   -- a2 covers (d=200<250) -> land on target
        assert_eq(b.anchor.pos.x, 1200); assert_eq(b.lx, 1000); assert_eq(b.residual, 0)
    end)
    it("accept filter rejects the nearer landing, falls back to a farther accepted one", function()
        local anchors = { { pos = {x=0,y=0}, r=300, ok=false }, { pos = {x=600,y=0}, r=100, ok=true } }
        local b = Geometry.BestReachLanding(anchors, {x=1000,y=0}, { accept = function(_, _, a) return a.ok end })
        assert_eq(b.anchor.pos.x, 600)
    end)
    it("returns nil when nothing is accepted", function()
        local b = Geometry.BestReachLanding({ { pos = {x=0,y=0}, r=700 } }, {x=10,y=0}, { accept = function() return false end })
        assert_eq(b, nil)
    end)
end)

describe("lib/geometry -- BestAoeCenter anchored cover-both (v0.5.175)", function()
    -- BestAoeCenter needs Vector:Distance2D; the file's plain Vector stub has no
    -- methods. Install a richer Vector for this block, then restore. With no
    -- SampleVelocities history and lead_s=0, PredictPos returns each unit's origin,
    -- so the geometry is deterministic.
    local saved_vector = Vector
    local function Vec(x, y, z)
        return { x = x, y = y, z = z or 0,
            Distance2D = function(self, o)
                local dx, dy = self.x - o.x, self.y - o.y
                return math.sqrt(dx * dx + dy * dy)
            end }
    end
    Vector = function(x, y, z) return Vec(x, y, z) end
    local function unit(x, y, idx) return { idx = idx, pos = Vec(x, y, 0) } end

    it("catchable pair: BOTH covered, far unit INSIDE the radius with margin (d=480, r=250)", function()
        local A = unit(0, 0, 1)      -- anchor (must_cover)
        local B = unit(480, 0, 2)    -- 480u away: catchable (<= 2*radius)
        local center, covered = Geometry.BestAoeCenter({ A, B }, 250, 0, A)
        assert_true(center ~= nil, "expected a center")
        assert_eq(covered, 2, "both must be covered")
        -- The far unit must sit INSIDE the radius with margin (midpoint placement),
        -- not pinned to the 250 rim (the v<=0.5.174 rim placement put it at exactly
        -- 250, which floating-point could drop just outside -> boundary miss).
        local d_far = center:Distance2D(B.pos)
        assert_true(d_far <= 245, "far unit must be inside radius-5, got " .. tostring(d_far))
        assert_true(center:Distance2D(A.pos) <= 250, "anchor must stay covered")
    end)

    it("comfortable pair both covered (d=300, r=250)", function()
        local A, B = unit(0, 0, 1), unit(300, 0, 2)
        local _, covered = Geometry.BestAoeCenter({ A, B }, 250, 0, A)
        assert_eq(covered, 2, "300u apart fits one 250 AoE")
    end)

    it("pair too far for one AoE -> single (d=600, r=250)", function()
        local A, B = unit(0, 0, 1), unit(600, 0, 2)
        local _, covered = Geometry.BestAoeCenter({ A, B }, 250, 0, A)
        assert_eq(covered, 1, "600u > 2*radius cannot fit; only the anchor")
    end)

    it("margin via reduced radius: double within threshold (d=442, r'=225)", function()
        -- w_aim passes W_AOE - K.W_COVER_MARGIN = 250 - 25 = 225 so a committed
        -- double is a guaranteed hit. 442 <= 2*225 -> still a double.
        local A, B = unit(0, 0, 1), unit(442, 0, 2)
        local _, covered = Geometry.BestAoeCenter({ A, B }, 225, 0, A)
        assert_eq(covered, 2, "442u within 2*225 must double")
    end)

    it("margin via reduced radius: single past threshold (d=482, r'=225)", function()
        -- 482 > 2*225 (450): too far to GUARANTEE both -> single-target the priority.
        local A, B = unit(0, 0, 1), unit(482, 0, 2)
        local _, covered = Geometry.BestAoeCenter({ A, B }, 225, 0, A)
        assert_eq(covered, 1, "482u past the margin threshold must single-target")
    end)

    Vector = saved_vector
end)

describe("lib/farm , valuation GoldValue/EffectiveHP (R3/R4)", function()
    it("GoldValue sums gold, missing gold counts 0", function()
        assert_eq(Farm.GoldValue({ {gold=43}, {gold=56}, {} }), 99)
    end)
    it("GoldValue nil-safe", function() assert_eq(Farm.GoldValue(nil), 0) end)
    it("EffectiveHP sums hp, missing hp counts 0", function()
        assert_eq(Farm.EffectiveHP({ {hp=300}, {hp=550}, {} }), 850)
    end)
    it("EffectiveHP nil-safe", function() assert_eq(Farm.EffectiveHP(nil), 0) end)
end)

describe("lib/farm , ClearBudget (R3)", function()
    it("ClearBudget: 1-stack ehp keeps the validated base count", function()
        assert_eq(Farm.ClearBudget(4, 1000, 960), 4)   -- need ceil(1.04)=2 < base 4
    end)
    it("ClearBudget: a stacked ehp raises the count above base", function()
        assert_eq(Farm.ClearBudget(4, 5000, 960), 6)   -- need ceil(5.2)=6 > base 4
    end)
    it("ClearBudget: zero ehp / zero dmg are safe (return base)", function()
        assert_eq(Farm.ClearBudget(3, 0, 960), 3)
        assert_eq(Farm.ClearBudget(3, 1000, 0), 3)
    end)
end)

describe("lib/farm , IsContestedByAlly (R2)", function()
    local mid = { x = 0, y = 0 }
    it("core ally within radius contests", function()
        assert_true(Farm.IsContestedByAlly(mid, { {pos={x=200,y=0}, value=1.0} }, {radius=600, min_value=0.7}))
    end)
    it("support ally does not contest", function()
        assert_false(Farm.IsContestedByAlly(mid, { {pos={x=200,y=0}, value=0.45} }, {radius=600, min_value=0.7}))
    end)
    it("core ally outside radius does not contest", function()
        assert_false(Farm.IsContestedByAlly(mid, { {pos={x=1000,y=0}, value=1.0} }, {radius=600, min_value=0.7}))
    end)
    it("nil args not contested", function()
        assert_false(Farm.IsContestedByAlly(nil, nil))
        assert_false(Farm.IsContestedByAlly(mid, nil))
    end)
end)

describe("lib/map , pure geometry", function()
    it("_center_of_box returns the midpoint", function()
        local c = Map._center_of_box({ min={x=0,y=0,z=0}, max={x=10,y=20,z=0} })
        assert_eq(c.x, 5); assert_eq(c.y, 10)
    end)
    it("_center_of_box nil-safe", function() assert_eq(Map._center_of_box(nil), nil) end)
    it("_in_box_xy true inside, false outside", function()
        local box = { min={x=0,y=0}, max={x=10,y=10} }
        assert_true(Map._in_box_xy({x=5,y=5}, box))
        assert_false(Map._in_box_xy({x=15,y=5}, box))
    end)
    it("_filter_in_box keeps only units inside", function()
        local box = { min={x=0,y=0}, max={x=10,y=10} }
        local units = { {p={x=5,y=5}}, {p={x=50,y=50}}, {p={x=1,y=9}} }
        local kept = Map._filter_in_box(units, box, function(uu) return uu.p end)
        assert_eq(#kept, 2)
    end)
end)

describe("lib/map , nearest anchor (pure)", function()
    local items = {
        { pos = { x = 0,   y = 0 } },
        { pos = { x = 100, y = 0 } },
        { pos = { x = 500, y = 500 } },
    }
    local function pos_of(a) return a.pos end
    it("picks the anchor closest to the target", function()
        assert_true(Map._nearest({ x = 90, y = 0 }, items, pos_of) == items[2])
    end)
    it("empty list returns nil", function()
        assert_true(Map._nearest({ x = 0, y = 0 }, {}, pos_of) == nil)
    end)
end)

describe("lib/farm -- CrashCast (geometry; condensed from lib/shove)", function()
    local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end
    it("stand sits standback toward the fountain from the centroid", function()
        local r = Farm.CrashCast({ x = 0, y = 0 }, { x = 1, y = 0 },
            { standback = 900, fountain = { x = -3000, y = 0 } })
        assert_true(near(r.stand.x, -900, 1) and near(r.stand.y, 0, 1), "stand 900 toward fountain")
    end)
    it("stand clamps to the fountain distance when closer than standback", function()
        local r = Farm.CrashCast({ x = 0, y = 0 }, { x = 1, y = 0 },
            { standback = 900, fountain = { x = -500, y = 0 } })
        assert_true(near(r.stand.x, -500, 1), "clamped to 500")
    end)
end)

describe("lib/schedule -- ClearTime (hybrid)", function()
    local CAL = { march_dmg_per_cast = 300, cast_dur = 0.5, robot_kill = 1.5, rearm_channel = 1.25 }
    it("small wave -> 1 cast, no rearm gap", function()
        local r = Schedule.ClearTime(250, CAL)
        assert_eq(r.casts, 1); assert_eq(r.t_clear, 2.0)        -- 1*(0.5+1.5) + 0*1.25
    end)
    it("1.5x damage -> 2 casts with one rearm gap", function()
        local r = Schedule.ClearTime(450, CAL)
        -- Piece 2 lib review: cadence + ONE robot tail (the measured camp model, engage_done dur~8.1 vs
        -- the per-cast-robot_kill estimate 10.0) - robots deliver DURING the rearm channel, so charging
        -- robot_kill per cast double-counted the overlap.
        assert_eq(r.casts, 2); assert_eq(r.t_clear, 3.75)       -- 2*0.5 + 1*1.25 + 1.5(one tail)
    end)
    it("rounds to nearest (v0.1.99): a sub-half remainder buys no extra W - the aim fix + allied creeps finish it", function()
        assert_eq(Schedule.ClearTime(400, CAL).casts, 1)        -- 1.33 -> 1
        assert_eq(Schedule.ClearTime(500, CAL).casts, 2)        -- 1.67 -> 2
        assert_eq(Schedule.ClearTime(2012, { march_dmg_per_cast = 450 }).casts, 4)  -- 4.47 -> 4
    end)
    it("exactly one cast worth -> 1 cast", function()
        assert_eq(Schedule.ClearTime(300, CAL).casts, 1)
    end)
    it("zero / nil eff_hp -> at least 1 cast, no NaN", function()
        assert_eq(Schedule.ClearTime(0, CAL).casts, 1)
        assert_eq(Schedule.ClearTime(nil, CAL).casts, 1)
    end)
    it("dmg <= 0 guarded (no div by zero)", function()
        local r = Schedule.ClearTime(500, { march_dmg_per_cast = 0 })
        assert_true(r.casts >= 1, "casts >=1"); assert_true(r.t_clear == r.t_clear, "t_clear not NaN")
    end)
end)

describe("lib/schedule -- NextWaveArrival", function()
    it("fresh last_wave_t -> next arrival on the MEASURED phase, strictly > now", function()
        -- last_wave_t=100 (phase 10 of period 30), now=115 -> next grid point >115 = 130
        local a = Schedule.NextWaveArrival(115, 30, 22, 100, 120)
        assert_eq(a, 130); assert_true(a > 115, "strictly ahead")
    end)
    it("stale last_wave_t -> falls back to the WAVE_PHASE grid", function()
        -- last_wave_t=100 but now=400 (stale > 2*period) -> phase=22 grid: ...382,412 -> >400 = 412
        assert_eq(Schedule.NextWaveArrival(400, 30, 22, 100, 120), 412)
    end)
    it("nil last_wave_t -> WAVE_PHASE grid", function()
        -- phase 22, period 30, now=50 -> 22,52,... -> >50 = 52
        assert_eq(Schedule.NextWaveArrival(50, 30, 22, nil), 52)
    end)
    it("rolls forward when a grid point equals now", function()
        -- phase 22, now=52 (a grid point) -> next is 82
        assert_eq(Schedule.NextWaveArrival(52, 30, 22, nil), 82)
    end)
    it("early game now < phase -> the first grid point", function()
        assert_eq(Schedule.NextWaveArrival(5, 30, 22, nil), 22)
    end)
    -- v0.1.366: THE INVARIANT THE LANE CLOCK NOW RESTS ON. Tinker stamps State.laneWaveT with
    -- `NextOnGrid(now, P, ph) - P` (the most recent grid tick) instead of a hero-derived time.
    -- NextWaveArrival consumes the stamp as a PHASE, so the stamp's phase MUST equal K.WAVE_PHASE
    -- at every `now` - that identity is what makes the fresh branch and the fallback branch agree
    -- and stops a hero-derived phase entering the wave clock. If this breaks, the clock silently
    -- goes back to being stamped by where Tinker happened to be standing.
    it("the grid-aligned stamp carries EXACTLY the calibrated phase, at every now", function()
        local P, PH = 30, 21
        for now = 0, 300, 0.7 do
            local stamp = Schedule.NextOnGrid(now, P, PH) - P
            assert_true(math.abs(stamp % P - PH) < 1e-9,
                string.format("stamp phase %.3f ~= %d at now=%.1f", stamp % P, PH, now))
            assert_true(stamp <= now, "the stamp is the most recent tick, never a future one")
            assert_true(now - stamp < P, "and never more than one period stale, so it stays 'fresh'")
        end
    end)
    it("a grid-aligned stamp makes the fresh branch agree with the WAVE_PHASE fallback", function()
        local P, PH = 30, 21
        for now = 0, 300, 1.3 do
            local stamp = Schedule.NextOnGrid(now, P, PH) - P
            assert_eq(Schedule.NextWaveArrival(now, P, PH, stamp), Schedule.NextWaveArrival(now, P, PH, nil))
        end
    end)
end)

describe("lib/schedule -- Plan (cycle decision)", function()
    local CAL = { march_dmg_per_cast = 300, cast_dur = 0.5, robot_kill = 1.5, rearm_channel = 1.25, lead = 1 }
    local function base(over)
        local c = { now = 100, wave = { arrival = 100, eff_hp = 450, present = true },
                    cal = CAL, travel_to_mid = 3, mana = 500, shove_cost = 200, safe = true }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end
    it("slack <= 0 (wave due) -> shove", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 } }))  -- leave_by=96 < now 100
        assert_eq(d.action, "shove"); assert_eq(d.reason, "due"); assert_eq(d.casts, 2)
    end)
    it("slack > 0 -> jungle with the slack value", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 } }))  -- leave_by=126; slack=26
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "slack"); assert_eq(d.slack, 26)
    end)
    it("mana < shove_cost -> recover (even with slack)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100 }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "mana")
    end)
    it("not safe -> recover (takes precedence)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100, safe = false }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "unsafe")
    end)

    -- ---- v0.1.360 lane-phase full-clear top-up (shove_cost_full) ----
    -- Two Marches clear a wave; one leaks creeps. With time in hand, top up rather than jungle so
    -- the wave is cleared in two. Every assertion below is written to FAIL if the term is removed
    -- or if the branch is moved above the due-wave arm.
    it("v0.1.360 slack + cannot fund the FULL clear + refill fits -> recover/mana (top up now)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 },
                                       mana = 300, shove_cost_full = 500, recover_s = 20 }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "mana")
        assert_true(d.recover_fits, "26s slack >= 20s round trip")
    end)
    it("v0.1.360 the refill must FIT the slack, else keep jungling", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 },
                                       mana = 300, shove_cost_full = 500, recover_s = 40 }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "slack")
    end)
    it("v0.1.360 A DUE WAVE IS NEVER ABANDONED for the full-clear price", function()
        -- the load-bearing one. A shove verdict is only ever reached at slack <= 0, so refusing it
        -- for mana cannot buy a refill that arrives in time - it just loses the wave. Half-clearing
        -- banks 3 of 4 last hits (the v0.1.200 argument), and that must survive inside lane phase.
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 },
                                       mana = 300, shove_cost_full = 500, recover_s = 1 }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "due")
    end)
    it("v0.1.360 funded for the full clear -> unchanged jungle/slack", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 },
                                       mana = 600, shove_cost_full = 500, recover_s = 20 }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "slack")
    end)
    it("v0.1.360 nil shove_cost_full (deep era / pre-Rearm) -> byte-identical to v0.1.359", function()
        -- the hero fills shove_cost_full ONLY while the enemy mid T1 stands and Rearm level >= 1,
        -- so the deep era and the pre-ultimate game must be untouched.
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 300, recover_s = 20 }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "slack")
    end)
    it("v0.1.360 a DEFEND is never dropped for the full-clear price", function()
        -- reason=="mana" is one of three verdicts defend_crash may not override (v0.1.337), so
        -- without the exemption a wave crashing OUR tower would vanish at fundable mana.
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 },
                                       mana = 300, shove_cost_full = 500, recover_s = 20,
                                       defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash")
    end)
    it("v0.1.360 the one-hop mana verdict still outranks it", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 },
                                       mana = 100, shove_cost = 200, shove_cost_full = 500, recover_s = 20 }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "mana")
        assert_true(math.abs(d.mana_at_leave_by - 100) < 1e-9, "regen 0: the OLD gate fired, not the new one")
    end)
    it("leave_by + casts passed through", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 250 } }))
        assert_eq(d.leave_by, 126); assert_eq(d.casts, 1); assert_eq(d.deadline, 130)
    end)

    -- ---- Plan v2 (2026-07-01): the hero veto cascade absorbed as lib rules ----
    it("F2 regen gate: mana at leave_by covers the cost -> no needless fountain trip", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100, mana_regen = 10 }))
        assert_eq(d.action, "jungle", "100 + 10*26 = 360 >= 200 at leave_by")
        assert_true(math.abs(d.mana_at_leave_by - 360) < 1e-9)
    end)
    it("F3 recover_fits: a mana-recover reports whether the round trip fits the slack", function()
        local d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100, recover_s = 40 }))
        assert_eq(d.action, "recover"); assert_true(not d.recover_fits, "26s slack < 40s round trip")
        d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, mana = 100, recover_s = 20 }))
        assert_true(d.recover_fits)
    end)
    it("far_dead veto: far travel + near-dead wave -> jungle deep_skip", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 300 },
                                       travel_to_mid = 13, far_travel_s = 12, min_wave_ehp = 400 }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "deep_skip")
    end)
    it("thin veto is VISIBLE-only (fogged estimates stay anticipatory)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 300, visible = true }, thin_ehp = 400 }))
        assert_eq(d.reason, "thin_wave")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 300, visible = false }, thin_ehp = 400 }))
        assert_eq(d.action, "shove", "fogged never thin")
    end)
    it("covers=false -> no_safe_stand; covers=nil -> not applicable", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, covers = false }))
        assert_eq(d.reason, "no_safe_stand")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 } }))
        assert_eq(d.action, "shove")
    end)
    it("bal gate: the push sim vetoes a losing fight", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, bal = -3, bal_min = -2 }))
        assert_eq(d.reason, "losing_fight")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, bal = -1, bal_min = -2 }))
        assert_eq(d.action, "shove", "mildly behind is still a shove")
    end)
    it("INVARIANT (BUG-1): a VETOED jungle never resurrects through the filler", function()
        local d = Schedule.Plan(base({ wave = { arrival = 103, eff_hp = 300, visible = true }, thin_ehp = 400,
                                       filler = { min_camp_slack = 10, min_fountain_slack = 6 } }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "thin_wave", "no near_due resurrection")
    end)
    it("INVARIANT (BUG-1) actually pins its guard: a VETOED jungle cannot convert via suppressed", function()
        -- MUTATION-DRIVEN. The sibling BUG-1 test above STILL PASSES when the
        -- `reason == "slack"` guard is deleted from lib/schedule.lua, because its near_due
        -- path re-runs shove_vetoes and is vetoed straight back to thin_wave: the invariant
        -- holds there by a DIFFERENT mechanism, leaving the guard itself unpinned. The
        -- SUPPRESSED branch has no second veto, so that is where the guard is load bearing.
        -- SUBTLETY that made this easy to miss: slack must be <= 0, or the initial action is
        -- already jungle/slack, shove_vetoes early-returns (it only runs when the action is
        -- "shove"), and the guard passes legitimately instead of blocking.
        local d = Schedule.Plan(base({ wave = { arrival = 103, eff_hp = 300, visible = true }, thin_ehp = 400,
                                       suppressed = true,
                                       filler = { min_camp_slack = 10, min_fountain_slack = 6 } }))
        assert_eq(d.action, "jungle", "a THIN-vetoed jungle must not convert to recover")
        assert_eq(d.reason, "thin_wave", "the veto reason must survive the filler")
        -- and the guard must not OVER-block: a genuine slack-jungle still converts
        local d2 = Schedule.Plan(base({ wave = { arrival = 110, eff_hp = 450 }, suppressed = true,
                                        filler = { min_camp_slack = 10, min_fountain_slack = 6 } }))
        assert_eq(d2.action, "recover", "a GENUINE slack-jungle must still convert")
        assert_eq(d2.reason, "shove_stuck")
    end)
    it("filler: a genuine tight slack-jungle converts (recharge when needed+fits, else near_due)", function()
        local c = base({ wave = { arrival = 110, eff_hp = 450 } })     -- leave_by=106; slack=6; 6-3=3 < 10
        c.filler = { min_camp_slack = 10, min_fountain_slack = 6, need_recharge = true }
        local d = Schedule.Plan(c)
        assert_eq(d.action, "recover"); assert_eq(d.reason, "recharge")
        c.filler.need_recharge = false
        d = Schedule.Plan(c)
        assert_eq(d.action, "shove"); assert_eq(d.reason, "near_due")
        c.suppressed = true
        d = Schedule.Plan(c)
        assert_eq(d.action, "recover"); assert_eq(d.reason, "shove_stuck")
    end)
    it("INVARIANT (v0.1.197, BUG-1 sibling): the filler's near_due conversion passes the shove vetoes", function()
        -- run-26 t=220.4: slack>0 made the initial action jungle/slack, so the vetoes never saw
        -- the wave; the filler flipped it to shove/near_due at a covers=false stand 1086 deep ->
        -- a 2435u walk + a 19s-early deep wait. The conversion must re-run the veto chain.
        local c = base({ wave = { arrival = 110, eff_hp = 1650, visible = true }, covers = false })
        c.filler = { min_camp_slack = 10, min_fountain_slack = 6 }   -- slack 6 - travel 3 < 10 -> filler window
        local d = Schedule.Plan(c)
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "no_safe_stand", "no near_due at an illegal stand")
        c.covers = nil; c.gone = true
        d = Schedule.Plan(c)
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "gone_by_arrival", "no near_due at a dead wave")
    end)
    it("INVARIANT (v0.1.198): defend_crash never overrides covers=false (no defense at an illegal stand)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 },
                                       covers = false, defend_crash = true }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "no_safe_stand")
        d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 }, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash", "a legal defense still fires")
    end)
    it("defend_crash forces the shove over any veto - EXCEPT unsafe (v2 deliberate fix)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 300, visible = true },
                                       thin_ehp = 400, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, safe = false, defend_crash = true }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "unsafe", "never forced into a gank")
    end)
    it("defend_crash never overrides the mana verdict (v0.1.337, the g337 240-mana raid)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 },
                                       mana = 100, defend_crash = true }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "mana", "an unfundable defense recovers first")
    end)
    it("defend_crash never dispatches below the hp bar (v0.1.337.1, case-file #2 both halves)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 },
                                       hp_frac = 0.35, min_hp_frac = 0.50, defend_crash = true }))
        assert_eq(d.action, "recover"); assert_eq(d.reason, "low_hp", "the due-shove flip-back half")
        d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 },
                                 hp_frac = 0.35, min_hp_frac = 0.50, defend_crash = true }))
        assert_eq(d.action, "jungle", "the slack-verdict half: defend must not force a shove under the bar")
        d = Schedule.Plan(base({ wave = { arrival = 130, eff_hp = 450 },
                                 hp_frac = 0.80, min_hp_frac = 0.50, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash", "healthy hp defends as before")
    end)
    it("LAW (v0.1.78-83 graveyard): the deadline is ALWAYS the current wave - no defer path exists", function()
        for _, over in ipairs({ {}, { covers = false }, { bal = -9, bal_min = -2 } }) do
            local c = base({ wave = { arrival = 137, eff_hp = 450 } })
            for k, v in pairs(over) do c[k] = v end
            assert_eq(Schedule.Plan(c).deadline, 137)
        end
    end)
    it("far_wave (Risk v2 axis 2): round-trip travel beyond camp_alt_s -> jungle", function()
        -- travel 20 -> RT 40 > 30: the walk out-costs ~2 camp clears
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, travel_to_mid = 20, camp_alt_s = 30 }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "far_wave")
        -- travel 12 -> RT 24 <= 30: the normal mid trip stays a shove
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, travel_to_mid = 12, camp_alt_s = 30 }))
        assert_eq(d.action, "shove")
        -- no camp_alt_s -> rule inactive (back-compat)
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, travel_to_mid = 20 }))
        assert_eq(d.action, "shove")
    end)
    it("far_wave: defend_crash still overrides (never skip defending our tower)", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, travel_to_mid = 20,
                                       camp_alt_s = 30, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash")
    end)
    it("gone_by_arrival (run-21): the enemy wave dies to ours before we can arrive -> jungle", function()
        local d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, gone = true }))
        assert_eq(d.action, "jungle"); assert_eq(d.reason, "gone_by_arrival")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 } }))
        assert_eq(d.action, "shove", "nil gone = rule inactive")
        d = Schedule.Plan(base({ wave = { arrival = 100, eff_hp = 450 }, gone = true, defend_crash = true }))
        assert_eq(d.action, "shove"); assert_eq(d.reason, "defend_crash", "a wave crashing OUR tower is never gone")
    end)
end)

describe("lib/farm -- DepthPoints (Risk v2 axis 1, the user point system)", function()
    it("zero at and inside the T1 line", function()
        assert_eq(Farm.DepthPoints(0, {}), 0)
        assert_eq(Farm.DepthPoints(-500, {}), 0)
        assert_eq(Farm.DepthPoints(nil, {}), 0)
    end)
    it("accrues past the line; the alive T1 doubles, each standing side T1 adds 25%", function()
        assert_eq(Farm.DepthPoints(1000, {}), 1000)
        assert_eq(Farm.DepthPoints(1000, { line_alive = true }), 2000)
        assert_eq(Farm.DepthPoints(1000, { side_t1_up = 2 }), 1500)
        assert_eq(Farm.DepthPoints(1000, { line_alive = true, side_t1_up = 2 }), 3000)
    end)
    it("the Keen shave subtracts flat and floors at zero", function()
        assert_eq(Farm.DepthPoints(1100, { side_t1_up = 2, shave = 1500 }), 150)   -- 1650 - 1500
        assert_eq(Farm.DepthPoints(200, { shave = 1500 }), 0)
    end)
end)

describe("lib/schedule -- EVENTS + NextEvent (the Dota clock, general scheduling)", function()
    it("grid events: power rune honors its first spawn, then the 2:00 grid", function()
        assert_eq(Schedule.NextEvent("power_rune", 100), 360)     -- before the 6:00 first spawn
        assert_eq(Schedule.NextEvent("power_rune", 400), 480)
    end)
    it("one-shot events: water runes expire after 4:00", function()
        assert_eq(Schedule.NextEvent("water_rune", 130), 240)
        assert_true(Schedule.NextEvent("water_rune", 300) == nil)
    end)
    it("kill-anchored events: tormentor first at 20:00, then kill + 10:00 (caller passes the kill)", function()
        assert_eq(Schedule.NextEvent("tormentor", 100), 1200)
        assert_true(Schedule.NextEvent("tormentor", 1300) == nil, "alive/unknown: no grid")
        assert_eq(Schedule.NextEvent("tormentor", 1600, 1500), 2100)
    end)
    it("day/night phases on the 10:00 grid", function()
        assert_eq(Schedule.NextEvent("night_start", 100), 300)
        assert_eq(Schedule.NextEvent("night_start", 400), 900)
        assert_eq(Schedule.NextEvent("day_start", 400), 600)
    end)
    it("unknown event -> nil; NextOnGrid is strictly future", function()
        assert_true(Schedule.NextEvent("roshan_dance", 0) == nil)
        assert_eq(Schedule.NextOnGrid(90, 30, 0), 120)
        assert_eq(Schedule.NextOnGrid(120, 30, 0), 150)           -- exactly on the boundary -> next
    end)
end)

describe("lib/schedule -- SeqFits (ability/channel sequence fitting)", function()
    it("keen + rearm before leave_by: fits with start_by reported", function()
        local r = Schedule.SeqFits({ 2.93, 2.69 }, 110, 100)
        assert_true(r.fits); assert_true(math.abs(r.total - 5.62) < 1e-9)
        assert_true(math.abs(r.start_by - 104.38) < 1e-9)
    end)
    it("a combo that does not fit the window reports fits=false", function()
        local r = Schedule.SeqFits({ 0.45, 0.3, 0.55, 1.7 }, 101, 100)   -- 3.0s combo, 1s window
        assert_true(not r.fits)
    end)
    it("empty sequence always fits, start_by = deadline", function()
        local r = Schedule.SeqFits({}, 50, 10)
        assert_true(r.fits); assert_eq(r.start_by, 50)
    end)
end)

describe("lib/farm -- stand predicates (condensed from lib/farm_decide)", function()
    it("MarchCovers: meeting within reach -> true, beyond -> false", function()
        assert_true(Farm.MarchCovers({x=0,y=0}, {x=1100,y=0}))          -- 1100 < 1200 reach
        assert_true(not Farm.MarchCovers({x=0,y=0}, {x=1300,y=0}))      -- 1300 > 1200
        assert_true(Farm.MarchCovers({x=0,y=0}, {x=500,y=0}, 600))      -- custom reach
        assert_true(not Farm.MarchCovers({x=0,y=0}, {x=700,y=0}, 600))
        assert_true(not Farm.MarchCovers(nil, {x=0,y=0}))
    end)
    it("OutsideTowerRange: inside 700 -> false, outside -> true, margin respected", function()
        local towers = { { x = 0, y = 0 } }
        assert_true(not Farm.OutsideTowerRange({x=600,y=0}, towers))    -- 600 < 700
        assert_true(Farm.OutsideTowerRange({x=800,y=0}, towers))        -- 800 > 700
        assert_true(not Farm.OutsideTowerRange({x=800,y=0}, towers, 700, 150))  -- 800 < 850
        assert_true(Farm.OutsideTowerRange({x=900,y=0}, {}))            -- no towers -> safe
    end)
end)

local MD = require("lib.map_data")

describe("lib/map -- pure helpers", function()
    -- box shape: {min={x,y,z?}, max={x,y,z?}}  (engine AABB from Camp.GetCampBox)
    -- NOT the flat {minx,miny,maxx,maxy} used by map_data.CAMPS

    it("_center_of_box: midpoint on xy, z defaults to 0 when absent", function()
        local c = Map._center_of_box({ min = { x = 0, y = 0 }, max = { x = 10, y = 20 } })
        assert_true(c ~= nil, "non-nil result")
        assert_eq(c.x, 5)
        assert_eq(c.y, 10)
        assert_eq(c.z, 0)
    end)

    it("_center_of_box: z included when both min.z and max.z are present", function()
        local c = Map._center_of_box({ min = { x = 0, y = 0, z = 100 }, max = { x = 10, y = 20, z = 200 } })
        assert_eq(c.z, 150)
    end)

    it("_center_of_box: nil/bad input -> nil", function()
        assert_true(Map._center_of_box(nil) == nil)
        assert_true(Map._center_of_box({}) == nil)
        assert_true(Map._center_of_box({ min = { x = 0 } }) == nil)
    end)

    it("_in_box_xy: inside returns true", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        assert_true(Map._in_box_xy({ x = 50, y = 50 }, box))
    end)

    it("_in_box_xy: on the boundary returns true (inclusive)", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        assert_true(Map._in_box_xy({ x = 0, y = 0 }, box))
        assert_true(Map._in_box_xy({ x = 100, y = 100 }, box))
    end)

    it("_in_box_xy: outside returns false", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        assert_false(Map._in_box_xy({ x = 101, y = 50 }, box))
        assert_false(Map._in_box_xy({ x = 50, y = -1 }, box))
    end)

    it("_in_box_xy: nil pos/box -> false", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        assert_false(Map._in_box_xy(nil, box))
        assert_false(Map._in_box_xy({ x = 50, y = 50 }, nil))
    end)

    it("_filter_in_box: keeps units inside, drops units outside", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        local units = { { pos = { x = 50, y = 50 } }, { pos = { x = 200, y = 50 } }, { pos = { x = 10, y = 10 } } }
        local out = Map._filter_in_box(units, box, function(u) return u.pos end)
        assert_eq(#out, 2)
    end)

    it("_filter_in_box: nil list -> empty table, no crash", function()
        local box = { min = { x = 0, y = 0 }, max = { x = 100, y = 100 } }
        local out = Map._filter_in_box(nil, box, function(u) return u end)
        assert_eq(#out, 0)
    end)

    it("_nearest: picks the closest item by xy distance", function()
        local items = { { pos = { x = 10, y = 0 } }, { pos = { x = 100, y = 0 } }, { pos = { x = 3, y = 0 } } }
        local best, dist = Map._nearest({ x = 0, y = 0 }, items, function(i) return i.pos end)
        assert_true(best ~= nil)
        assert_eq(best.pos.x, 3)
        assert_true(math.abs(dist - 3) < 1e-6)
    end)

    it("_nearest: returns both item and euclidean distance", function()
        local items = { { pos = { x = 3, y = 4 } } }
        local _, dist = Map._nearest({ x = 0, y = 0 }, items, function(i) return i.pos end)
        assert_true(math.abs(dist - 5) < 1e-6, "3-4-5 triangle, got " .. tostring(dist))
    end)

    it("_nearest: empty list -> nil, nil", function()
        local best, dist = Map._nearest({ x = 0, y = 0 }, {}, function(i) return i.pos end)
        assert_true(best == nil and dist == nil)
    end)

    it("_nearest: nil target -> nil", function()
        local items = { { pos = { x = 10, y = 0 } } }
        local best = Map._nearest(nil, items, function(i) return i.pos end)
        assert_true(best == nil)
    end)
end)

describe("lib/map_data -- structure self-check", function()
    it("at least 18 camps", function()
        assert_true(#MD.CAMPS >= 18, "expected >= 18 camps, got " .. #MD.CAMPS)
    end)
    it("at least 22 towers", function()
        assert_true(#MD.TOWERS >= 22, "expected >= 22 towers, got " .. #MD.TOWERS)
    end)
    it("every camp has center and a 4-element box", function()
        for i, c in ipairs(MD.CAMPS) do
            assert_true(c.center ~= nil, "camp " .. i .. " missing center")
            assert_true(c.box ~= nil, "camp " .. i .. " missing box")
            -- ponytail: box is a flat {minx,miny,maxx,maxy} array, not a struct
            assert_true(c.box[1] ~= nil and c.box[2] ~= nil, "camp " .. i .. " box missing elements")
        end
    end)
    it("at least 2 mid-T1 towers (goodguys + badguys)", function()
        local n = 0
        for _, t in ipairs(MD.TOWERS) do
            if t.name:find("tower1_mid") then n = n + 1 end
        end
        assert_true(n >= 2, "expected >= 2 tower1_mid entries, got " .. n)
    end)
end)

describe("lib/lane -- TrackFrontSpeed: measured front displacement (arc B)", function()
    local L = require("lib.lane")
    it("steady march measures ~stat", function()
        local tr, spd = L.TrackFrontSpeed({}, "mid:enemy", { x = 0, y = 0 }, 100)
        assert_eq(spd, nil, "first sample has no dt")
        tr, spd = L.TrackFrontSpeed(tr, "mid:enemy", { x = 650, y = 0 }, 102)     -- 325 u/s
        tr, spd = L.TrackFrontSpeed(tr, "mid:enemy", { x = 1300, y = 0 }, 104)
        assert_true(spd and spd > 300 and spd < 350, "expected ~325, got " .. tostring(spd))
    end)
    it("a held wave decays toward 0 and recovers within ~2 samples", function()
        local tr, spd = L.TrackFrontSpeed({}, "k", { x = 0, y = 0 }, 100)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 102)             -- marching
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 104)             -- held
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 106)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 655, y = 0 }, 108)
        assert_true(spd and spd < 80, "held wave should read <80, got " .. tostring(spd))
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 1305, y = 0 }, 110)            -- released
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 1955, y = 0 }, 112)
        assert_true(spd and spd > 200, "release should recover within ~2 samples, got " .. tostring(spd))
    end)
    it("a front JUMP (new wave replaced the old) resets the measurement", function()
        local tr, spd = L.TrackFrontSpeed({}, "k", { x = 0, y = 0 }, 100)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 102)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 4000, y = 0 }, 104)            -- 1675 u/s = a jump
        assert_eq(spd, nil, "jump resets; no speed until a fresh dt")
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 4650, y = 0 }, 106)
        assert_true(spd and spd > 300, "fresh measurement after the reset")
    end)
    it("stale sample returns nil (fog)", function()
        local tr, spd = L.TrackFrontSpeed({}, "k", { x = 0, y = 0 }, 100)
        tr, spd = L.TrackFrontSpeed(tr, "k", { x = 650, y = 0 }, 102)
        assert_true(spd ~= nil)
        local _, spd2 = L.TrackFrontSpeed(tr, "k", nil, 112)                      -- no front for 10s
        assert_eq(spd2, nil)
    end)
end)

describe("lib/towers -- registry: alive flag + measured hp-slope death eta", function()
    local TW = require("lib.map").Towers
    local KEY = "tower1_mid@3"
    it("melt extrapolation: eta ~= hp/rate", function()
        local st = TW.Track({}, { { key = KEY, hp = 1800, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 1700, alive = true } }, 102)   -- 50 hp/s
        st = TW.Track(st, { { key = KEY, hp = 1600, alive = true } }, 104)
        local eta = TW.DeathEta(st, KEY, 104)
        assert_true(eta > 25 and eta < 40, "eta ~32s expected, got " .. tostring(eta))
    end)
    it("undamaged tower predicts huge", function()
        local st = TW.Track({}, { { key = KEY, hp = 1800, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 1800, alive = true } }, 102)
        assert_eq(TW.DeathEta(st, KEY, 102), math.huge)
    end)
    it("dead latch is permanent (towers never revive)", function()
        local st = TW.Track({}, { { key = KEY, hp = 500, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, alive = false } }, 102)
        st = TW.Track(st, { { key = KEY, hp = 1800, alive = true } }, 104)   -- mis-key/noise: ignored
        assert_eq(TW.Alive(st, KEY), false)
        assert_eq(TW.DeathEta(st, KEY, 104), 0)
    end)
    it("stale sample disables the prediction (fog decays to OFF)", function()
        local st = TW.Track({}, { { key = KEY, hp = 1800, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 1600, alive = true } }, 102)
        assert_true(TW.DeathEta(st, KEY, 103) < math.huge, "fresh melt should predict")
        assert_eq(TW.DeathEta(st, KEY, 112), math.huge)   -- 10s stale > stale_s 6
    end)
    it("never-sampled key: Alive nil, eta huge", function()
        local st = {}
        assert_eq(TW.Alive(st, KEY), nil)
        assert_eq(TW.DeathEta(st, KEY, 100), math.huge)
    end)
    it("EMA smooths a noisy rate", function()
        local st = TW.Track({}, { { key = KEY, hp = 2000, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 1900, alive = true } }, 102)   -- 50 hp/s
        st = TW.Track(st, { { key = KEY, hp = 1900, alive = true } }, 104)   -- 0 hp/s
        local eta = TW.DeathEta(st, KEY, 104)
        assert_true(eta < math.huge, "EMA slope (~25 hp/s) should still predict, got " .. tostring(eta))
    end)
    it("heal/backdoor regen resets the melt read", function()
        local st = TW.Track({}, { { key = KEY, hp = 1000, alive = true } }, 100)
        st = TW.Track(st, { { key = KEY, hp = 900, alive = true } }, 102)
        st = TW.Track(st, { { key = KEY, hp = 1100, alive = true } }, 104)   -- healing up
        assert_eq(TW.DeathEta(st, KEY, 104), math.huge)
    end)
end)

describe("lib/lane -- Depth (S2 per-lane ruler, the side-parity fix)", function()
    local LN = require("lib.lane")
    local MD = require("lib.map_data")
    local r2 = LN.DepthRuler(MD.TOWERS, MD.FOUNTAINS, 2)   -- Radiant
    local r3 = LN.DepthRuler(MD.TOWERS, MD.FOUNTAINS, 3)   -- Dire
    it("zeros at each lane's T1 midpoint, both teams", function()
        for _, ln in ipairs({ "mid", "top", "bot" }) do
            local z = r2.zero[ln]
            assert_true(z ~= nil, ln .. " zero exists")
            assert_true(math.abs(LN.Depth(r2, z, ln)) < 1, ln .. " centre reads 0 (Radiant)")
            assert_true(math.abs(LN.Depth(r3, z, ln)) < 1, ln .. " centre reads 0 (Dire)")
        end
    end)
    it("own mid T1 ~-1459, enemy mid T1 ~+1459, both teams", function()
        local rT1 = { x = -1544, y = -1408 }   -- Radiant mid T1 (map_data)
        local dT1 = { x = 524, y = 652 }       -- Dire mid T1
        assert_true(math.abs(LN.Depth(r2, rT1, "mid") - -1458) < 10, "Radiant: own T1 depth")
        assert_true(math.abs(LN.Depth(r2, dT1, "mid") - 1458) < 10, "Radiant: enemy T1 depth")
        assert_true(math.abs(LN.Depth(r3, dT1, "mid") - -1458) < 10, "Dire: own T1 depth")
        assert_true(math.abs(LN.Depth(r3, rT1, "mid") - 1458) < 10, "Dire: enemy T1 depth")
    end)
    it("documents the healed defect: the old zero (fountain mid) sits ~583 DIRE-ward of the lane centre", function()
        local fm = { x = (7408 - 7456) / 2, y = (6848 - 6938) / 2 }   -- the old ruler's zero
        -- consequence on the OLD ruler: Dire read the lane centre at +583 (past WALK_DEPTH_MAX 550
        -- = could not even dispatch to its own meet), Radiant read it at -583 (band reached
        -- centre+1133). The new per-lane zero + WALK_DEPTH_MAX 1100 gives BOTH sides centre+1100.
        assert_true(math.abs(LN.Depth(r3, fm, "mid") - -583) < 15, "Dire: the old zero sat ~583 OWN-side of the lane centre")
        assert_true(math.abs(LN.Depth(r2, fm, "mid") - 583) < 15, "Radiant: the old zero sat ~583 ENEMY-side of the lane centre")
    end)
    it("team antisymmetry on mid", function()
        for _, p in ipairs({ { x = 0, y = 0 }, { x = -900, y = -750 }, { x = 476, y = 352 } }) do
            local a, b = LN.Depth(r2, p, "mid"), LN.Depth(r3, p, "mid")
            assert_true(math.abs(a + b) < 1, string.format("Depth2(%d,%d) == -Depth3", p.x, p.y))
        end
    end)
end)

describe("lib/lane -- CreepStats (W-GEOM-2 sim input)", function()
    local Lane = require("lib.lane")
    it("melee at t=0 reads base stats", function()
        local s = Lane.CreepStats("melee", 0)
        assert_eq(s.hp, 550); assert_eq(s.gold, 39)
    end)
    it("ranged scales per 450s cycle", function()
        local s = Lane.CreepStats("ranged", 900)          -- cycle 2
        assert_eq(s.hp, 324); assert_eq(s.gold, 58)
    end)
    it("unknown kind -> nil", function()
        assert_eq(Lane.CreepStats("courier", 0), nil)
    end)
end)

describe("lib/march_sim -- cast geometry (W-GEOM-2)", function()
    local MS = require("lib.march_sim")
    it("straight cast: point clamped to 300 toward aim, facing hero->aim", function()
        local c = MS.Cast({ x = 0, y = 0 }, { x = 810, y = 0 }, 0)
        assert_true(math.abs(c.cx - 300) < 1 and math.abs(c.cy) < 1, "cast point at 300,0")
        assert_true(math.abs(c.fx - 1) < 0.001 and math.abs(c.fy) < 0.001, "facing +x")
    end)
    it("theta rotates the facing off the aim axis", function()
        local c = MS.Cast({ x = 0, y = 0 }, { x = 810, y = 0 }, 30)
        assert_true(math.abs(c.fx - math.cos(math.rad(30))) < 0.001, "fx = cos30")
        assert_true(math.abs(c.fy - math.sin(math.rad(30))) < 0.001, "fy = sin30")
    end)
    it("behind cast: 60u backstep flip, spawn edge at hero+840 along the axis", function()
        local c = MS.Cast({ x = 0, y = 0 }, { x = 810, y = 0 }, 0, true)
        assert_true(math.abs(c.fx + 1) < 0.001, "facing flipped (-x)")
        -- spawn edge = cast - 900*facing = (-60) - 900*(-1) = +840
        assert_true(math.abs((c.cx - 900 * c.fx) - 840) < 1, "spawn edge +840")
    end)
end)

describe("lib/march_sim -- attrition sim (W-GEOM-2)", function()
    local MS = require("lib.march_sim")
    local Lane = require("lib.lane")

    it("spawns 144 robots per cast; a centered stationary creep dies", function()
        local r = MS.Simulate({
            hero = { x = 0, y = 0 },
            creeps = { { x = 600, y = 0, hp = 80, kind = "melee" } },
            wave_speed = 0, dmg = 40,
            casts = { { t = 0, theta = 0 } },
        })
        assert_eq(r.robots, 144)
        assert_true(r.creeps[1].died_at ~= nil, "centered creep dies")
        assert_true(r.cleared, "wave cleared")
    end)
    it("creep outside the corridor is untouched", function()
        local r = MS.Simulate({
            hero = { x = 0, y = 0 },
            creeps = { { x = 600, y = 0, hp = 80, kind = "ranged" },   -- the aim anchor
                       { x = 600, y = 1200, hp = 80, kind = "melee" } },
            wave_speed = 0, dmg = 40,
            casts = { { t = 0, theta = 0 } },
        })
        assert_true(r.creeps[2].died_at == nil and r.creeps[2].hp == 80, "off-corridor creep untouched")
    end)
    it("screening: the front creep on the same lane dies before the rear one", function()
        local r = MS.Simulate({
            hero = { x = 0, y = 0 },
            creeps = { { x = 500, y = 0, hp = 400, kind = "melee" },
                       { x = 900, y = 0, hp = 400, kind = "ranged" } },   -- 400 apart: no splash bleed
            wave_speed = 0, dmg = 40,
            casts = { { t = 0, theta = 0 } },
        })
        local front, rear = r.creeps[1], r.creeps[2]
        assert_true(front.died_at ~= nil, "front dies")
        assert_true(rear.died_at == nil or rear.died_at > front.died_at, "rear outlives the screen")
    end)
    it("splash: a neighbor within 150 of the impact takes damage", function()
        local r = MS.Simulate({
            hero = { x = 0, y = 0 },
            creeps = { { x = 600, y = 0, hp = 5000, kind = "melee" },
                       { x = 600, y = 100, hp = 5000, kind = "melee" } },
            wave_speed = 0, dmg = 40,
            casts = { { t = 0, theta = 0 } },
        })
        assert_true(r.creeps[2].hp < 5000, "splash neighbor damaged")
    end)
    -- THE W-GEOM-2 GATE (verdict pinned; see tools/w_geom_report.lua for the matrix + CS
    -- sweep): NARROW X arms (+-20..30) keep both streams' melee shadows aligned on the
    -- ranged - it survives the static fight at W lvl2. WIDE asymmetric arms (user-corrected
    -- pro X, e.g. 45/-90) decorrelate the shadows: the ranged dies, and on the jittered
    -- last-hit-race sweep the wide X and today's front+behind are gold-equivalent. The
    -- angle question is settled by physics: wide or don't bother.
    local function stand_wave(gt)
        return MS.MakeWave({
            ranged = { x = 810, y = 0 }, walk = { x = -1, y = 0 },
            melee_hp = Lane.CreepStats("melee", gt).hp,
            ranged_hp = Lane.CreepStats("ranged", gt).hp,
        })
    end
    local function ranged_of(r)
        for _, c in ipairs(r.creeps) do if c.kind == "ranged" then return c end end
    end
    it("walking wave at the 810 stand: ranged dies within 2 casts (today AND X 20/30/45)", function()
        local pats = { { { t = 0, theta = 0 }, { t = 3.5, behind = true } } }
        for _, th in ipairs({ 20, 30, 45 }) do pats[#pats + 1] = { { t = 0, theta = th }, { t = 3.5, theta = -th } } end
        for pi, casts in ipairs(pats) do
            local r = MS.Simulate({ hero = { x = 0, y = 0 }, creeps = stand_wave(600),
                                    walk = { x = -1, y = 0 }, wave_speed = 325, dmg = 40, casts = casts })
            local rg = ranged_of(r)
            assert_true(rg.died_at and rg.died_cast <= 2, "pattern " .. pi .. ": ranged dies within 2 casts")
        end
    end)
    it("walking wave at the 400 stand (v0.1.326 forward pre-position): ranged dies within 2 casts", function()
        -- the fogged pre-position moves from meeting-810 to meeting-W_PRE_STAND_BACK (400):
        -- same kill bar as the 810 test, wave arriving at the closer stand, all patterns.
        local pats = { { { t = 0, theta = 0 }, { t = 3.5, behind = true } } }
        for _, th in ipairs({ 20, 30, 45 }) do pats[#pats + 1] = { { t = 0, theta = th }, { t = 3.5, theta = -th } } end
        for pi, casts in ipairs(pats) do
            local r = MS.Simulate({ hero = { x = 0, y = 0 },
                                    creeps = MS.MakeWave({ ranged = { x = 400, y = 0 }, walk = { x = -1, y = 0 },
                                                           melee_hp = Lane.CreepStats("melee", 600).hp,
                                                           ranged_hp = Lane.CreepStats("ranged", 600).hp }),
                                    walk = { x = -1, y = 0 }, wave_speed = 325, dmg = 40, casts = casts })
            local rg = ranged_of(r)
            assert_true(rg.died_at and rg.died_cast <= 2, "pattern " .. pi .. ": ranged dies within 2 casts at the 400 stand")
        end
    end)
    it("last-hit race: bg_dps kills attribute to the own wave, robot kills to us (cs)", function()
        local r = MS.Simulate({
            hero = { x = 0, y = 0 },
            creeps = { { x = 600, y = 0, hp = 80, kind = "melee" },        -- in-corridor: robots race the bg
                       { x = 600, y = 1400, hp = 50, kind = "melee" } },   -- off-corridor: only bg touches it
            wave_speed = 0, dmg = 40, bg_dps = 20,
            casts = { { t = 0, theta = 0 } },
        })
        assert_eq(r.creeps[1].died_to, "robot", "in-corridor creep last-hit by a robot")
        assert_eq(r.creeps[2].died_to, "bg", "off-corridor creep dies to the own wave")
        assert_eq(r.cs, 1, "cs counts only robot kills")
    end)
    it("STATIC early wave: narrow X leaves the ranged screened; behind AND wide X kill it", function()
        local function run(casts)
            return MS.Simulate({ hero = { x = 0, y = 0 }, creeps = stand_wave(300),
                                 wave_speed = 0, dmg = 22, casts = casts })
        end
        local today = run({ { t = 0, theta = 0 }, { t = 3.5, behind = true } })
        assert_true(ranged_of(today).died_at ~= nil, "front+behind kills the static ranged")
        local x20 = run({ { t = 0, theta = 20 }, { t = 3.5, theta = -20 } })
        assert_true(ranged_of(x20).died_at == nil, "narrow X20: shadows aligned, ranged survives")
        local wide = run({ { t = 0, theta = 45 }, { t = 3.5, theta = -90 } })
        assert_true(ranged_of(wide).died_at ~= nil, "wide X 45/-90: shadows decorrelated, ranged dies")
    end)
end)

describe("lib/farm , observed-farmer camp clearing (v0.1.332, sustained per-hero dwell v0.1.349)", function()
    local C = { { key = "10,10", cx = 1000, cy = 1000 }, { key = "20,20", cx = 2000, cy = 2000 } }
    -- window = the max GAP that keeps ONE hero's sighting run unbroken; min_dwell =
    -- the CONTINUOUS presence that means farming. The gap alone confirmed nothing
    -- but "somebody was seen twice", which both a single walk-through (2 scans while
    -- crossing the 1200u circle) and a RELAY of heroes satisfy - hence per-hero runs.
    local OPT = function(t) return { radius = 600, window = 4.0, min_dwell = 6.0, now = t } end
    local function H(id, x, y) return { id = id, x = x, y = y } end
    -- drive one hero's sighting run at the given times; returns the marks of the LAST call
    local function run_at(dwell, pt, camps, times)
        local m
        for _, t in ipairs(times) do
            m = Farm.ObservedFarmers({ pt }, camps, dwell, OPT(t))
        end
        return m
    end

    it("one sighting never marks (walk-through)", function()
        local dwell = {}
        local m = Farm.ObservedFarmers({ H("A", 1100, 1000) }, C, dwell, OPT(10))
        assert_eq(#m, 0)
        assert_eq(dwell["10,10"].first, 10)
        assert_eq(dwell["10,10"].last, 10)
        assert_eq(dwell["10,10"].who, "A")
    end)

    it("two sightings 2s apart do NOT confirm (THE walk-through, g349)", function()
        local dwell = {}
        Farm.ObservedFarmers({ H("A", 1100, 1000) }, C, dwell, OPT(10))
        local m = Farm.ObservedFarmers({ H("A", 1050, 1000) }, C, dwell, OPT(12))
        assert_eq(#m, 0)
        assert_eq(dwell["10,10"].first, 10)   -- the run continued, it did not restart
        assert_eq(dwell["10,10"].last, 12)
    end)

    it("min_dwell of continuous presence confirms", function()
        local dwell = {}
        local m = run_at(dwell, H("A", 1100, 1000), C, { 10, 12, 14, 16 })
        assert_eq(#m, 1)
        assert_eq(m[1], "10,10")
    end)

    it("a gap wider than the window restarts the dwell clock", function()
        local dwell = {}
        run_at(dwell, H("A", 1100, 1000), C, { 10, 12, 14 })      -- 4s of dwell, not yet enough
        local m = Farm.ObservedFarmers({ H("A", 1100, 1000) }, C, dwell, OPT(20))   -- gap 6 > 4
        assert_eq(#m, 0)
        assert_eq(dwell["10,10"].first, 20)   -- run restarted, the earlier 4s does not carry
        local m2 = run_at(dwell, H("A", 1100, 1000), C, { 22, 24 })                 -- only 4s again
        assert_eq(#m2, 0)
        local m3 = Farm.ObservedFarmers({ H("A", 1100, 1000) }, C, dwell, OPT(26))
        assert_eq(#m3, 1)
    end)

    it("confirming RETIRES the run, so no latch can go stale across the respawn", function()
        local dwell = {}
        local m = run_at(dwell, H("A", 1100, 1000), C, { 0, 2, 4, 6 })
        assert_eq(#m, 1)
        assert_true(dwell["10,10"] == nil)    -- no {marked} latch survives the confirm
        local m2 = run_at(dwell, H("A", 1100, 1000), C, { 8, 10, 12 })
        assert_eq(#m2, 0)                     -- the fresh run must earn min_dwell again
        local m3 = Farm.ObservedFarmers({ H("A", 1100, 1000) }, C, dwell, OPT(14))
        assert_eq(#m3, 1)                     -- a camp farmed past its respawn re-confirms (v0.1.332 intent)
    end)

    it("a RELAY of heroes never confirms, overlapping crossings (v0.1.349 review)", function()
        local dwell = {}
        local A, B = H("A", 1100, 1000), H("B", 1100, 1000)
        Farm.ObservedFarmers({ A }, C, dwell, OPT(0))            -- A inside [0,4]
        Farm.ObservedFarmers({ A, B }, C, dwell, OPT(2))         -- B enters [2,6]
        Farm.ObservedFarmers({ A, B }, C, dwell, OPT(4))
        local m = Farm.ObservedFarmers({ B }, C, dwell, OPT(6))  -- A has left
        assert_eq(#m, 0)                      -- neither hero was present for 6s
        assert_eq(dwell["10,10"].who, "B")    -- the run restarted on the new owner
        assert_eq(dwell["10,10"].first, 6)
    end)

    it("a RELAY separated by an empty scan never confirms (v0.1.349 review)", function()
        local dwell = {}
        run_at(dwell, H("A", 1100, 1000), C, { 0, 2, 4 })
        Farm.ObservedFarmers({}, C, dwell, OPT(6))               -- nobody: an empty scan must not extend a run
        local m = Farm.ObservedFarmers({ H("B", 1100, 1000) }, C, dwell, OPT(8))
        assert_eq(#m, 0)                      -- B arriving 4s later must not inherit A's 4s
        assert_eq(dwell["10,10"].who, "B")
        assert_eq(dwell["10,10"].first, 8)
    end)

    it("a passer-by does not restart the resident's run", function()
        local dwell = {}
        local A = H("A", 1100, 1000)
        Farm.ObservedFarmers({ A }, C, dwell, OPT(0))
        -- B is listed FIRST, so a naive first-match would hand the run to the passer-by
        Farm.ObservedFarmers({ H("B", 1000, 1000), A }, C, dwell, OPT(2))
        Farm.ObservedFarmers({ H("B", 1000, 1000), A }, C, dwell, OPT(4))
        local m = Farm.ObservedFarmers({ A }, C, dwell, OPT(6))
        assert_eq(#m, 1)                      -- A's 6s run is intact
        assert_eq(m[1], "10,10")
    end)

    it("radius is a hard edge", function()
        local dwell = {}
        local m = run_at(dwell, H("A", 1000, 1601), C, { 10, 12, 14, 16 })
        assert_eq(#m, 0)
        assert_true(dwell["10,10"] == nil)
        local m3 = run_at(dwell, H("A", 1000, 1600), C, { 20, 22, 24, 26 })
        assert_eq(#m3, 1)
    end)

    it("same-tick and regressed-clock sightings restart the run (dt > 0)", function()
        local dwell = {}
        local A = H("A", 1100, 1000)
        run_at(dwell, A, C, { 10, 12 })                          -- an ESTABLISHED run, so the branch matters
        local m = Farm.ObservedFarmers({ A }, C, dwell, OPT(12))
        assert_eq(#m, 0)
        assert_eq(dwell["10,10"].first, 12)   -- same tick restarts; under dt >= 0 first would stay 10
        local m2 = Farm.ObservedFarmers({ A }, C, dwell, OPT(8))
        assert_eq(#m2, 0)
        assert_eq(dwell["10,10"].first, 8)    -- the regressed clock starts a fresh run
    end)

    it("a hero within radius of two camps confirms both", function()
        local near = { { key = "a", cx = 0, cy = 0 }, { key = "b", cx = 800, cy = 0 } }
        local dwell = {}
        local m = run_at(dwell, H("A", 400, 0), near, { 1, 3, 5, 7 })
        assert_eq(#m, 2)
    end)

    it("min_dwell 0 restores the pre-v0.1.349 confirm threshold", function()
        local dwell = {}
        local O = function(t) return { radius = 600, window = 4.0, min_dwell = 0, now = t } end
        local A = H("A", 1100, 1000)
        Farm.ObservedFarmers({ A }, C, dwell, O(10))
        local m = Farm.ObservedFarmers({ A }, C, dwell, O(12))
        assert_eq(#m, 1)
    end)

    it("no heroes means no dwell writes", function()
        local dwell = {}
        local m = Farm.ObservedFarmers({}, C, dwell, OPT(10))
        assert_eq(#m, 0)
        assert_true(next(dwell) == nil)
    end)
end)

describe("lib/farm , jungle-aware lane contest (v0.1.333)", function()
    local CAMPS = { { x = 4000, y = -5100 }, { x = 4700, y = -4000 } }
    local CRASH = { x = 5565, y = -4310 }
    local function core(x, y) return { pos = { x = x, y = y }, value = 1, core = true } end

    it("core at an adjacent camp within jungle_r contests as jungle (the g332 t=425.9 case)", function()
        local c, why = Farm.IsContestedByAlly(CRASH, { core(4000, -5100) },
            { radius = 1200, camps = CAMPS, jungle_r = 2600 })
        assert_true(c)
        assert_eq(why, "jungle")
    end)

    it("no camps opt = old semantics (back-compat)", function()
        local c = Farm.IsContestedByAlly(CRASH, { core(4000, -5100) }, { radius = 1200 })
        assert_false(c)
    end)

    it("on-wave core still contests, branch = wave", function()
        local c, why = Farm.IsContestedByAlly(CRASH, { core(5400, -4300) },
            { radius = 1200, camps = CAMPS, jungle_r = 2600 })
        assert_true(c)
        assert_eq(why, "wave")
    end)

    it("core at a camp beyond jungle_r of the crash does not contest", function()
        local far_crash = { x = 6800, y = -1200 }
        local c = Farm.IsContestedByAlly(far_crash, { core(4000, -5100) },
            { radius = 1200, camps = CAMPS, jungle_r = 2600 })
        assert_false(c)
    end)

    it("core in transit (near neither wave nor any camp) does not contest", function()
        local c = Farm.IsContestedByAlly(CRASH, { core(3200, -4550) },
            { radius = 1200, camps = CAMPS, jungle_r = 2600 })
        assert_false(c)
    end)
end)

describe("lib/timing , arrival watchdog (v0.1.334)", function()
    local K334 = { grace = 8, hold_t = 10, hold_max = 15 }
    local Timing = require("lib.timing")
    local function real(eta) return { est = false, reach = true, eta = eta } end
    local function estd(eta) return { est = true, reach = true, eta = eta } end

    it("inside grace always holds, whatever the scan", function()
        local v = Timing.ArrivalWatchdog(107.9, 100, nil, K334)
        assert_eq(v, "hold")
        local v2 = Timing.ArrivalWatchdog(105.0, 100, estd(2), K334)
        assert_eq(v2, "hold")
    end)

    it("fog: no scan past grace releases why=fog (at-stand tier math; g332 t=358 rides the tethered tier in game)", function()
        local v, why, over = Timing.ArrivalWatchdog(108.1, 100, nil, K334)
        assert_eq(v, "release")
        assert_eq(why, "fog")
        assert_true(over > 8)
    end)

    it("estimate churn never pins: est=y past grace releases why=fog (at-stand tier math; g334 t=205 rides the tethered tier in game)", function()
        local v, why = Timing.ArrivalWatchdog(109.0, 100, estd(0.4), K334)
        assert_eq(v, "release")
        assert_eq(why, "fog")
    end)

    it("a real imminent read holds past grace (the flickering fight, pre-cap)", function()
        local v = Timing.ArrivalWatchdog(110.0, 100, real(2.9), K334)
        assert_eq(v, "hold")
        local v2 = Timing.ArrivalWatchdog(114.9, 100, real(4.7), K334)
        assert_eq(v2, "hold")
    end)

    it("the cap ends the lie: real imminent read past hold_max releases why=flicker (g334 t=446/620)", function()
        local v, why, over = Timing.ArrivalWatchdog(115.1, 100, real(1.5), K334)
        assert_eq(v, "release")
        assert_eq(why, "flicker")
        assert_true(over > 15)
    end)

    it("a real non-imminent read releases why=slow at wake (the g334 t=532 window, the approved tradeoff)", function()
        local v, why = Timing.ArrivalWatchdog(108.5, 100, real(11.4), K334)
        assert_eq(v, "release")
        assert_eq(why, "slow")
    end)

    it("unreachable or eta-less reads count as fog, not slow", function()
        local v, why = Timing.ArrivalWatchdog(109.0, 100, { est = false, reach = false, eta = 3 }, K334)
        assert_eq(v, "release")
        assert_eq(why, "fog")
        local v2, why2 = Timing.ArrivalWatchdog(109.0, 100, { est = false, reach = true, eta = nil }, K334)
        assert_eq(v2, "release")
        assert_eq(why2, "fog")
    end)

    it("the tethered tier (grace=cap) holds any fogged shape to the cap then releases (the shipped g332 t=358 / g334 t=205 behavior)", function()
        local KT = { grace = 15, hold_t = 10, hold_max = 15 }
        assert_eq(Timing.ArrivalWatchdog(112.0, 100, nil, KT), "hold")
        assert_eq(Timing.ArrivalWatchdog(114.9, 100, { est = true, reach = true, eta = 0.4 }, KT), "hold")
        local v, why = Timing.ArrivalWatchdog(115.1, 100, nil, KT)
        assert_eq(v, "release")
        assert_eq(why, "fog")
    end)

    it("held reports the overshoot past the promise", function()
        local _, _, over = Timing.ArrivalWatchdog(112.0, 100, real(3), K334)
        assert_true(over == 12)
    end)

    it("over exactly at grace still holds (the strict-> house idiom)", function()
        local v = Timing.ArrivalWatchdog(108.0, 100, nil, K334)
        assert_eq(v, "hold")
    end)

    it("over exactly at hold_max with a real imminent read still holds", function()
        local v = Timing.ArrivalWatchdog(115.0, 100, { est = false, reach = true, eta = 2 }, K334)
        assert_eq(v, "hold")
    end)
end)

----------------------------------------------------------------------------
-- REPORT
----------------------------------------------------------------------------

-- v0.1.379: the observed-lane helpers. These gate a match-level position label, and a wrong label
-- flips IsCore, so the two guards (minimum samples, dominant share) are the load-bearing part.
describe("lib/position_data -- observed lane", function()
    local Pos = require("lib.map").Positions

    it("needs sustained samples: below the minimum count returns nil", function()
        assert_true(Pos.ObservedLane({ top = 11, mid = 0, bot = 0, n = 11 }) == nil,
            "n=11 is under the 12 floor and must not resolve")
    end)

    it("needs dominance: a split tally returns nil even with plenty of samples", function()
        assert_true(Pos.ObservedLane({ top = 11, mid = 9, bot = 0, n = 20 }) == nil,
            "55% share is under the 0.60 bar (a support passing through mid must not win it)")
    end)

    it("resolves a dominant lane", function()
        assert_eq(Pos.ObservedLane({ top = 16, mid = 4, bot = 0, n = 20 }), "top")
    end)

    it("maps lanes to slots per team: safelane is bot for Radiant, top for Dire", function()
        assert_true(Pos.LaneSlots("bot", 2)[1] and Pos.LaneSlots("bot", 2)[5], "Radiant bot = safelane {1,5}")
        assert_true(Pos.LaneSlots("top", 3)[1] and Pos.LaneSlots("top", 3)[5], "Dire top = safelane {1,5}")
        assert_true(Pos.LaneSlots("bot", 3)[3] and Pos.LaneSlots("bot", 3)[4], "Dire bot = offlane {3,4}")
        assert_true(Pos.LaneSlots("mid", 2)[2], "mid = {2}")
    end)

    it("g378: the observed offlane promotes Earthshaker to a core-side residual", function()
        -- Tinker is Dire, so bot is the offlane. Earthshaker's draft residual {3,4} intersected with
        -- the offlane slots stays {3,4}: both on the core side of the 3/4 line under the ship policy.
        local slots, kept = Pos.LaneSlots("bot", 3), {}
        for _, v in ipairs({ 3, 4 }) do if slots[v] then kept[#kept + 1] = v end end
        assert_eq(#kept, 2, "offlane keeps {3,4}")
    end)

    it("a contradiction narrows to EMPTY, which must read undetermined not not-core", function()
        -- Dazzle is {5} but was observed in the offlane {3,4}: the intersection is empty. The
        -- consumer contract is that empty means UNDETERMINED and falls through to today's path.
        local slots, kept = Pos.LaneSlots("bot", 3), {}
        for _, v in ipairs({ 5 }) do if slots[v] then kept[#kept + 1] = v end end
        assert_eq(#kept, 0, "empty residual, caller must treat as undetermined")
    end)
end)

print()
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
    print()
    for i = 1, #fails do
        print("FAIL: " .. fails[i].name)
        print("  " .. tostring(fails[i].err))
    end
    os.exit(1)
end
os.exit(0)
