---@meta
---lib/farm.lua - stateless farming geometry + cast-worthiness policy.
---
---Hero-agnostic. Every function takes explicit inputs (a world origin and a
---caller-supplied list of units); NONE of them call the engine API. The hero
---script owns the actual creep/neutral enumeration (which engine calls vary by
---framework version) and passes a plain unit list in. That keeps this module
---pure math: fully testable, zero runtime-API risk, reusable by any hero with
---an AoE / line nuke (Lina Dragon Slave, Jakiro Macropyre, etc.).
---
---v0.5.78: created for Lina's HOLD wave-clear (mana + stack aware). The
---line/point AoE-count optimizers are general enough that offensive W/Q aim
---could later consume them too; left here under "farm" for cohesion with the
---WorthCasting policy. Could lift the pure optimizers to lib/geometry.lua if a
---second non-farm consumer appears.
---
---Unit list contract (each entry):
---  { pos = <Vector>, hp = <number?>, is_neutral = <boolean?>, entity = <any?> }
---Only `pos` (with .x / .y) is required. `hp` is used as a tie-break weight.

local Farm = {}

---Count units whose center falls inside a line segment of `length` and
---half-width `half_width`, starting at (ox, oy) heading along the UNIT vector
---(dx, dy). Internal scalar form (no Vector allocation).
---@return integer count
---@return table hits subset of `units`
local function _count_in_line(ox, oy, dx, dy, length, half_width, units)
    local n, hits, sumt = 0, {}, 0
    local hw2 = half_width * half_width
    for i = 1, #units do
        local p = units[i].pos
        if p then
            local rx, ry = p.x - ox, p.y - oy
            local t = rx * dx + ry * dy           -- projection onto dir
            if t >= 0 and t <= length then
                local perpx = rx - t * dx
                local perpy = ry - t * dy
                local pd2 = perpx * perpx + perpy * perpy
                if pd2 <= hw2 then
                    n = n + 1
                    hits[#hits + 1] = units[i]
                    sumt = sumt + t              -- accumulate projection for the
                                                 -- closer-pack tie-break (v0.5.81)
                end
            end
        end
    end
    return n, hits, sumt
end

---Sum of hp over a unit list (tie-break weight). Missing hp counts as 0.
local function _sum_hp(units)
    local s = 0
    for i = 1, #units do s = s + (units[i].hp or 0) end
    return s
end

---Find the line-nuke aim that hits the most units. Candidate directions are
---taken toward each unit (a line nuke's optimum always points at some unit's
---bearing). Ties broken by greater summed hp, then by a nearer cluster
---(shorter mean projection), so a denser/closer pack wins over a marginal far
---one.
---
---v0.5.111 hero-clip bonus (opts, all optional; opts nil = behavior identical
---to pre-v0.5.111):
---  opts.bonus_units  second unit list (same contract). Units hit by a
---                    candidate line add bonus_weight each to that line's
---                    SCORE, and their bearings join the candidate set
---                    (so a line can be aimed THROUGH the wave at a hero
---                    standing behind it). The returned hit_count stays
---                    PRIMARY units only, so caller cast-thresholds keep
---                    their meaning.
---  opts.bonus_weight score per bonus hit (default 3: a hero outbids up
---                    to 3 creeps when choosing between lines).
---  opts.min_hits     primary-hit qualification threshold. Lines meeting
---                    it form the QUALIFIED pool and always beat any
---                    unqualified line regardless of score, so a
---                    bonus-heavy line can never drag the pick below the
---                    caller's cast gate while a qualifying line exists.
---                    When NO line qualifies, the raw best is returned
---                    and the caller's gate rejects it exactly as today.
---A candidate must hit at least one PRIMARY unit (a hero-only bearing is
---not a wave-clear line).
---
---Returns (aim_pos, hit_count, hits, bonus_hit_count) where aim_pos =
---origin + best_dir * length (a point defining the cast line for
---issue_cast_position). (nil, 0, {}, 0) when no unit is hittable.
---@param origin userdata Vector cast origin (hero pos)
---@param units table unit list (see contract)
---@param length number line length
---@param half_width number half the line width
---@param opts table|nil { bonus_units?, bonus_weight?, min_hits? }
---@return userdata|nil aim_pos
---@return integer hit_count       primary hits on the chosen line
---@return table hits              primary hit subset
---@return integer bonus_hit_count bonus hits on the chosen line
function Farm.BestLineAim(origin, units, length, half_width, opts)
    if not (origin and units and #units > 0 and length and half_width) then
        return nil, 0, {}, 0
    end
    local bonus    = opts and opts.bonus_units
    local bweight  = (opts and opts.bonus_weight) or 3
    local min_hits = opts and opts.min_hits
    if bonus and #bonus == 0 then bonus = nil end
    local ox, oy, oz = origin.x, origin.y, origin.z
    local best_score, best_hp, best_proj = -1, -1, nil
    local best_q = false
    local best_n, best_bn = 0, 0
    local best_dx, best_dy, best_hits = nil, nil, {}
    local function consider(px, py)
        local dx, dy = px - ox, py - oy
        local len = math.sqrt(dx * dx + dy * dy)
        if len <= 1 then return end
        dx, dy = dx / len, dy / len
        local n, hits, sumt = _count_in_line(ox, oy, dx, dy, length,
                                             half_width, units)
        if n == 0 then return end  -- must clear creeps; hero-only is not wave-clear
        local bn = 0
        if bonus then
            bn = _count_in_line(ox, oy, dx, dy, length, half_width, bonus)
        end
        local score = n + bn * bweight
        local qual  = (min_hits == nil) or (n >= min_hits)
        local hp = _sum_hp(hits)
        local mean_proj = sumt / n   -- closer pack = lower mean t
        -- Selection ladder: qualified pool first (see opts.min_hits), then
        -- score (primary + weighted bonus; == raw hit count when opts is
        -- nil), then summed hp, then nearer cluster (shorter mean
        -- projection) so a denser/closer pack wins over an equally-scoring
        -- marginal far one (v0.5.81).
        if (qual and not best_q)
           or (qual == best_q and (score > best_score
               or (score == best_score and hp > best_hp)
               or (score == best_score and hp == best_hp
                   and (best_proj == nil or mean_proj < best_proj)))) then
            best_q, best_score, best_hp, best_proj = qual, score, hp, mean_proj
            best_n, best_bn = n, bn
            best_dx, best_dy, best_hits = dx, dy, hits
        end
    end
    for i = 1, #units do
        local p = units[i].pos
        if p then consider(p.x, p.y) end
    end
    if bonus then
        for i = 1, #bonus do
            local p = bonus[i].pos
            if p then consider(p.x, p.y) end
        end
    end
    if not best_dx then return nil, 0, {}, 0 end
    local aim_pos = Vector(ox + best_dx * length, oy + best_dy * length, oz)
    return aim_pos, best_n, best_hits, best_bn
end

---Find the AoE-circle center (of `radius`) that catches the most units. Centers
---are sampled at each unit position (an optimal circle can always be slid until
---a unit sits on its rim, and unit-centered candidates are a strong, cheap
---approximation). Ties broken by greater summed hp.
---
---Returns (center, hit_count, hits) or (nil, 0, {}).
---@param units table unit list (see contract)
---@param radius number AoE radius
---@param opts table|nil reserved
---@return userdata|nil center
---@return integer hit_count
---@return table hits
function Farm.BestPointAim(units, radius, opts)
    if not (units and #units > 0 and radius) then return nil, 0, {} end
    local r2 = radius * radius
    local best_n, best_hp, best_center, best_hits = 0, -1, nil, {}
    for i = 1, #units do
        local c = units[i].pos
        if c then
            local n, hits = 0, {}
            for j = 1, #units do
                local p = units[j].pos
                if p then
                    local dx, dy = p.x - c.x, p.y - c.y
                    if (dx * dx + dy * dy) <= r2 then
                        n = n + 1
                        hits[#hits + 1] = units[j]
                    end
                end
            end
            local hp = _sum_hp(hits)
            if n > best_n or (n == best_n and hp > best_hp) then
                best_n, best_hp, best_center, best_hits = n, hp, c, hits
            end
        end
    end
    if not best_center then return nil, 0, {} end
    return best_center, best_n, best_hits
end

---Policy predicate: is a cast worth it given how many units it would hit.
---@param hit_count integer|nil
---@param min_count integer|nil default 1
---@return boolean
function Farm.WorthCasting(hit_count, min_count)
    return (hit_count or 0) >= (min_count or 1)
end

---Tight-pair clear classification ("best distance" model): given the inter-camp
---distance `d`, how well does one centred March (cast at ~the midpoint) clear BOTH
---camps? Models each camp as a creep disc of radius `disc` centred d/2 from the cast.
---  clean: d/2 + disc <= half  -> the whole far disc is inside +/- march_len/2, one
---         March clears both.
---  clip : d/2 - disc <= half  -> the centre spills out but the NEAR creeps still clip
---         the rectangle; finish with extra Marches + the camp aggro-pulling in.
---  none : even the nearest creep is outside -> not a viable pair (farm single).
---Pure; the hero/diagnostic passes march_len + the calibrated disc. Returns the class
---plus both margins (>=0 = inside) for the calibration readout. (R4 / pairing policy)
---@param d number|nil inter-camp distance
---@param opts table|nil { march_len?, disc? }
---@return table { class = "clean"|"clip"|"none", full_margin = number, clip_margin = number }
function Farm.PairClearClass(d, opts)
    opts = opts or {}
    local half = (opts.march_len or 1800) * 0.5
    local disc = opts.disc or 200
    if not d or d <= 0 then
        return { class = "none", full_margin = -math.huge, clip_margin = -math.huge }
    end
    local full_margin = half - (d * 0.5 + disc)   -- outer creep spare; >=0 => clean
    local clip_margin = half - (d * 0.5 - disc)   -- nearest creep spare; >=0 => at least clips
    local class = (full_margin >= 0 and "clean") or (clip_margin >= 0 and "clip") or "none"
    return { class = class, full_margin = full_margin, clip_margin = clip_margin }
end

---Adjacent-camp pairing by MUTUAL-NEAREST matching: pair i-j iff each is the OTHER's nearest ELIGIBLE
---partner in (`min_sep`, `pair_max`]. Symmetric + order-independent + STABLE: a camp can never orphan its
---partner by grabbing a closer one (the greedy bug where the same two camps read pair-from-one-side /
---single-from-the-other, depending on candidate order). A matched pair becomes ONE planner node (SUM
---value, MAX-life cost); a camp whose nearest is taken (not mutual) stays single. `min_sep` (default 200)
---drops coincident/degenerate pairs. Pure + deterministic. (Name kept for call-site stability.)
---@param points table array of { x, y } (array index = id)
---@param pair_max number max inter-point distance to pair
---@param min_sep number|nil min inter-point distance (default 200)
---@param allow function|nil optional allow(i, j) -> bool: force-permit a pair beyond pair_max (still > min_sep).
---@return table groups array of { a = i } (single) or { a = i, b = j, d = dist } (pair)
function Farm.GreedyPairs(points, pair_max, min_sep, allow)
    local n = points and #points or 0
    local lo = min_sep or 200
    local hi = pair_max or 0
    -- each point's nearest ELIGIBLE partner (index + distance)
    local nb = {}
    for i = 1, n do
        local bj, bd = nil, math.huge
        if points[i] then
            for j = 1, n do
                if j ~= i and points[j] then
                    local dx = points[j].x - points[i].x
                    local dy = points[j].y - points[i].y
                    local d = math.sqrt(dx * dx + dy * dy)
                    if d > lo and (d <= hi or (allow and allow(i, j))) and d < bd then bj, bd = j, d end
                end
            end
        end
        nb[i] = { j = bj, d = bd }
    end
    local groups, used = {}, {}
    for i = 1, n do
        if not used[i] then
            local j = nb[i].j
            if j and not used[j] and nb[j].j == i then          -- mutual nearest -> stable pair
                used[i], used[j] = true, true
                groups[#groups + 1] = { a = i, b = j, d = nb[i].d }
            else
                used[i] = true
                groups[#groups + 1] = { a = i }
            end
        end
    end
    return groups
end

--- Observed-farmer camp clearing (v0.1.332, TINKER_CAMP_FARMER_CLEAR_DESIGN.md,
--- sustained per-hero dwell AMENDMENT v0.1.349): ONE hero present inside `radius`
--- of a camp centre CONTINUOUSLY for `min_dwell` seconds is FARMING it - the camp
--- is as good as cleared until the next xx:00. `window` is only the max GAP that
--- keeps that hero's sighting RUN unbroken; on its own it does NOT mean farming.
--- BOTH halves are load-bearing, and each killed a real false mark:
---   * without min_dwell, a hero CROSSING the circle (1200u at radius 600, ~4s at
---     300 MS) trips a 2-sighting test - 14 live camps retired that way in g349;
---   * without per-hero runs, a RELAY of crossers does the same thing between
---     them (A inside [0,4] hands off to B inside [2,6] = a 6s "dwell" nobody
---     served), which is routine traffic on path-adjacent camps.
--- Identity comes from h.id or h.e (the caller's entity); the run restarts when
--- the owner changes, and a hero already owning the run keeps it against any
--- passer-by. Confirming RETIRES the run, so no latch survives to go stale across
--- the camp's respawn (the caller has already retired the camp itself).
--- Pure: the caller supplies positions ({x=,y=,id=/e=}), camps ({key=,cx=,cy=}),
--- the persistent dwell table (key -> {who,first,last}), and the clock via opts.now.
--- Returns the camp keys confirmed farmed by THIS call.
function Farm.ObservedFarmers(hero_pts, camps, dwell, opts)
    local r = (opts and opts.radius) or 600
    local r2 = r * r
    local gap = (opts and opts.window) or 4.0
    local need = (opts and opts.min_dwell) or 6.0
    local t = (opts and opts.now) or 0
    local marks = {}
    for _, c in ipairs(camps) do
        local d = dwell[c.key]
        local who = nil                             -- a hero inside, PREFERRING the one who owns the open run
        for _, h in ipairs(hero_pts) do
            local dx, dy = h.x - c.cx, h.y - c.cy   -- component math: camp centres are plain tables
            if dx * dx + dy * dy <= r2 then
                local id = h.id or h.e or h
                if d and d.who == id then who = id; break end   -- the resident is still here
                if who == nil then who = id end                 -- else the first newcomer opens a run
            end
        end
        if who ~= nil then
            local dt = d and (t - d.last)
            if d and d.who == who and dt > 0 and dt <= gap then  -- SAME hero, run unbroken
                d.last = t
                if (t - d.first) >= need then
                    marks[#marks + 1] = c.key
                    dwell[c.key] = nil              -- confirmed: retire the run, never latch it
                end
            else                                    -- new owner, or continuity broken (incl. dt <= 0)
                dwell[c.key] = { who = who, first = t, last = t }
            end
        end
    end
    return marks
end

-- Tinker farm: valuation / clear-feasibility / scoring / ally-respect helpers.
-- Hero-agnostic and PURE: the hero precomputes per-creep hp (Entity.GetHealth),
-- gold (NPC.GetGoldBountyMax), and ally values (lib/hero_value), passing plain
-- tables/numbers in. No engine calls here. See Tinker/TINKER_FARM_DESIGN.md.
-- Creep-list contract: { { hp = <number?>, gold = <number?> }, ... }

Farm.DEFAULT_CONTEST_RADIUS = 700   -- an allied core this close "owns" the spot

---Sum precomputed gold over a creep list. Missing gold counts as 0. (R4 input)
---@param creeps table|nil
---@return number
function Farm.GoldValue(creeps)
    local g = 0
    if not creeps then return 0 end
    for i = 1, #creeps do g = g + (creeps[i].gold or 0) end
    return g
end

---Risk v2 axis 1 (task #11 increment 1, the user POINT SYSTEM, 2026-07-04): graded depth risk
---past the enemy T1 line - GRADED economics for the schedule decision, never a positional veto
---(hard vetoes made the hero freeze/idle; a busted budget just loses the pick and the window
---goes to the jungle). `depth_past` = units past the STATIC nearest enemy tier-1 spot on the
---fountain axis (<= 0 -> 0 points). Accrual: 1 pt/unit, x2 while THAT tower still stands (the
---hostile tower zone), x(1 + 0.25 per OTHER standing enemy tier-1) - their remaining towers keep
---the territory hostile; as they fall the same ground cheapens. `shave` = flat subtraction for
---escape capability (the hero passes it when Keen L2 is ready), floored at 0. Consumers compare
---against a budget at DECIDE time only. Pure.
---@param depth_past number|nil  @param opts table|nil { line_alive, side_t1_up, shave }
---@return number points
function Farm.DepthPoints(depth_past, opts)
    opts = opts or {}
    if not depth_past or depth_past <= 0 then return 0 end
    local rate = (opts.line_alive and 2 or 1) * (1 + 0.25 * (opts.side_t1_up or 0))
    return math.max(0, depth_past * rate - (opts.shave or 0))
end

---Sum hp over a creep list. Missing hp counts as 0. (R3 denominator)
---@param creeps table|nil
---@return number
function Farm.EffectiveHP(creeps)
    local h = 0
    if not creeps then return 0 end
    for i = 1, #creeps do h = h + (creeps[i].hp or 0) end
    return h
end

---Marches needed to clear a camp, stack-aware. `base` is the validated per-tier
---count (caller's marches_for + clip); `ehp` is the live effective HP of the camp
---(stacks included); `per_cast_dmg` is one March's effective damage. Returns
---max(base, ceil(ehp/per_cast_dmg)): never below the validated base (no regression
---on a normal camp), only ADDS marches when a stacked/tanky camp's ehp needs them.
---ceil (not round): a camp has no allied wave to finish a remainder. Guards a
---missing/zero dmg by returning base.
---@param base integer validated per-tier march count
---@param ehp number live effective HP of the camp
---@param per_cast_dmg number one March's effective damage
---@return integer
function Farm.ClearBudget(base, ehp, per_cast_dmg)
    base = base or 1
    if not per_cast_dmg or per_cast_dmg <= 0 then return base end
    local need = math.ceil((ehp or 0) / per_cast_dmg)
    return (need > base) and need or base
end

---Is `pos` contested by an allied core, so the farm bot should not steal it?
---The hero passes allies with PRECOMPUTED value (from lib/hero_value); this lib
---never calls hero_value, staying pure. (R2)
---v0.1.333 (jungle-aware lane contest): with opts.camps, an ally FARMING the
---jungle beside `pos` (within camp_r of a camp centre AND within jungle_r of
---`pos`) also contests. The second return names the branch for verdict logging.
---No camps opt = the pre-.333 semantics exactly.
---@param pos table|nil { x, y }
---@param allies table|nil { { pos = {x,y}, value = number }, ... }
---@param opts table|nil { radius=number?, min_value=number?, camps={ {x,y}, ... }?, camp_r=number?, jungle_r=number? }
---@return boolean contested
---@return string|nil branch "wave" | "jungle"
function Farm.IsContestedByAlly(pos, allies, opts)
    if not (pos and allies) then return false end
    local radius = (opts and opts.radius) or Farm.DEFAULT_CONTEST_RADIUS
    local minval = (opts and opts.min_value) or 0
    local camps = opts and opts.camps
    local camp_r = (opts and opts.camp_r) or 600
    local jungle_r = (opts and opts.jungle_r) or 2600
    local r2, c2, j2 = radius * radius, camp_r * camp_r, jungle_r * jungle_r
    for i = 1, #allies do
        local a = allies[i]
        if a and a.pos and (a.value or 0) >= minval then
            local dx, dy = a.pos.x - pos.x, a.pos.y - pos.y
            local d2 = dx * dx + dy * dy
            if d2 <= r2 then return true, "wave" end
            if camps and d2 <= j2 then
                for k = 1, #camps do
                    local cx, cy = a.pos.x - camps[k].x, a.pos.y - camps[k].y
                    if cx * cx + cy * cy <= c2 then return true, "jungle" end
                end
            end
        end
    end
    return false
end

---Structural (position-based) farm risk in [0,1]: a gradient that rises toward the enemy fountain
---(camps deeper on the enemy half are more exposed) PLUS explicit per-zone bumps for known-contested
---camps the gradient alone cannot separate (e.g. a mid-river ancient at the same axis-distance as a
---safe own-jungle camp). Pure; the hero passes its fountains + contested-zone tags. Independent of
---live enemy vision, so it ranks an own-side safelane camp safer than a contested mid camp even when
---no enemy is on the minimap.
---@param pos table { x, y }
---@param opts table|nil { our_fountain={x,y}, enemy_fountain={x,y}, half_weight=number?, zones={ {x,y,radius,bump}, ... }? }
---@return number risk 0..1
function Farm.StructuralRisk(pos, opts)
    opts = opts or {}
    local r = 0
    local of, ef = opts.our_fountain, opts.enemy_fountain
    if of and ef and pos then
        local ax, ay = ef.x - of.x, ef.y - of.y
        local denom = ax * ax + ay * ay
        if denom > 1 then
            local t = ((pos.x - of.x) * ax + (pos.y - of.y) * ay) / denom   -- 0 our fountain .. 1 enemy fountain
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            r = (opts.half_weight or 0.5) * t
        end
    end
    if pos then
        for i = 1, #(opts.zones or {}) do
            local z = opts.zones[i]
            local dx, dy = pos.x - z.x, pos.y - z.y
            local rad = z.radius or 0
            if dx * dx + dy * dy <= rad * rad then r = r + (z.bump or 0) end
        end
    end
    if r < 0 then r = 0 elseif r > 1 then r = 1 end
    return r
end

---Aim point that best covers a creep cluster along a lane axis: the MEAN point
---shifted along the (already-unit) axis (ax, ay) to the projection-span midpoint, so
---an AoE footprint spans front (melee) to back (ranged) instead of sitting on the
---count-weighted mass center (melee outnumber ranged, so the mean is melee-biased and
---the trailing ranged creep falls outside the footprint). Lateral coord stays the mean
---(lanes are narrow). `points`: array of { x, y }. Returns { x, y }, or nil if empty.
function Farm.WaveAimCenter(points, ax, ay)
    local n = points and #points or 0
    if n == 0 then return nil end
    local mx, my = 0, 0
    for i = 1, n do mx = mx + points[i].x; my = my + points[i].y end
    mx, my = mx / n, my / n
    local lo, hi = math.huge, -math.huge
    for i = 1, n do
        local t = (points[i].x - mx) * ax + (points[i].y - my) * ay   -- projection onto the axis, relative to mean
        if t < lo then lo = t end
        if t > hi then hi = t end
    end
    local shift = (lo + hi) * 0.5
    return { x = mx + ax * shift, y = my + ay * shift }
end

-- ------------------------------- shove (crash-push cast geometry) -------------------------------
-- Condensed from lib/shove.lua (2026-07-01, user call: libs are cohesive domain units like C's
-- math.h - a 1-function lib is an artifact, not a library). Same function, same tests.

---pure geometry for the crash-push March. stand = the enemy-wave centroid offset back toward the
---fountain by `standback` (matches update_wave_spot).
---`creep_line_dir` is vestigial: it fed the `perp` / `cast_point` outputs, which no hero ever read
---(dropped with them). Kept in the signature so the one call site and its tests stay untouched.
---@param clash_centroid table {x,y}
---@param creep_line_dir table|nil  unused
---@param opts table|nil { standback?, fountain? }
---@return table { stand{x,y} }
function Farm.CrashCast(clash_centroid, creep_line_dir, opts)
    opts = opts or {}
    local standback = opts.standback or 900
    local c = clash_centroid

    local stand = { x = c.x, y = c.y }
    local fo = opts.fountain
    if fo then
        local dx, dy = fo.x - c.x, fo.y - c.y
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl > 1 then
            local back = math.min(standback, dl)
            stand = { x = c.x + dx / dl * back, y = c.y + dy / dl * back }
        end
    end

    return { stand = stand }
end

-- ------------------------------- farm_decide (stand predicates) ---------------------------------
-- Condensed from lib/farm_decide.lua (same call). The two survivors of the retired decision tree.

---does a March cast from `stand` cover `meeting`? (cast clamp + footprint reach as one radius)
function Farm.MarchCovers(stand, meeting, reach)
    if not (stand and meeting) then return false end
    local dx, dy = meeting.x - stand.x, meeting.y - stand.y
    local r = reach or 1200
    return dx * dx + dy * dy <= r * r
end

---is `pos` outside every tower's attack range (+margin)? towers = { {x,y}, ... }
function Farm.OutsideTowerRange(pos, towers, range, margin)
    if not pos then return false end
    local r = (range or 700) + (margin or 0)
    for i = 1, #(towers or {}) do
        local t = towers[i]
        local dx, dy = pos.x - t.x, pos.y - t.y
        if dx * dx + dy * dy < r * r then return false end
    end
    return true
end

-- ------------------------------- route risk ------------------------------------------------------

---Worst enemy risk sampled ALONG the straight route from->to, not just at the endpoints. A target whose
---stand reads safe can still be reachable only by walking through a dangerous corridor; sampling the path
---catches that. Hero-agnostic: the caller passes `risk_at(point) -> number` (e.g. a fog-aware enemy-risk
---closure), so this lib only walks the geometry. Samples every `opts.step` units, INCLUSIVE of both ends.
---PURE. Returns (max_risk, worst_point).
---@param from table { x, y }
---@param to table { x, y }
---@param risk_at fun(pt: table): number
---@param opts table|nil { step = 550 }
---@return number max_risk, table worst_point
function Farm.PathRisk(from, to, risk_at, opts)
    opts = opts or {}
    local step = opts.step or 550
    local fx, fy = from.x or 0, from.y or 0
    local dx, dy = (to.x or 0) - fx, (to.y or 0) - fy
    local dist = math.sqrt(dx * dx + dy * dy)
    local n = math.max(1, math.ceil(dist / math.max(1, step)))   -- n segments -> n+1 sample points
    local worst, wp = -math.huge, from
    for i = 0, n do
        local t = i / n
        local p = { x = fx + dx * t, y = fy + dy * t }
        local r = risk_at(p) or 0
        if r > worst then worst, wp = r, p end
    end
    return worst, wp
end

return Farm
