---@meta
---lib/lane.lua - lane intelligence (creep waves, equilibrium, intercept). Hero-agnostic.
---Pure analysis core (offline-tested) + thin engine wrappers (verified in-game), mirroring
---lib/map.lua. Pure functions use scalar math (read .x/.y, build {x,y}); only the wrappers
---touch the engine, and NOTHING calls the engine at load time. See Tinker/TINKER_LANE_DESIGN.md.
local Lane = {}

-- ---- pure helpers --------------------------------------------------------

---centroid {x,y} of a member list (nil if empty).
local function _centroid(members)
    local sx, sy, n = 0, 0, #members
    if n == 0 then return nil end
    for i = 1, n do sx = sx + members[i].pos.x; sy = sy + members[i].pos.y end
    return { x = sx / n, y = sy / n }
end
Lane._centroid = _centroid

---summed hp over members (missing hp = 0).
local function _hp(members)
    local h = 0
    for i = 1, #members do h = h + (members[i].hp or 0) end
    return h
end
Lane._hp = _hp

---summed gold bounty over members (missing gold = 0).
function Lane._gold(members)
    local g = 0
    for i = 1, #members do g = g + (members[i].gold or 0) end
    return g
end

---push weight of a wave: default summed hp; opts.strength_fn(members) overrides.
function Lane._strength(members, opts)
    if opts and opts.strength_fn then return opts.strength_fn(members) end
    return _hp(members)
end

---front {x,y}: the member furthest along push_dir (a vector toward the enemy base; need not be
---normalized, argmax of the projection is scale-invariant). nil if empty.
function Lane._front(members, push_dir)
    local best, bestp = nil, -math.huge
    for i = 1, #members do
        local p = members[i].pos
        local proj = p.x * push_dir.x + p.y * push_dir.y
        if proj > bestp then best, bestp = p, proj end
    end
    return best and { x = best.x, y = best.y } or nil
end

-- ---- cluster / lane assignment / wave detection --------------------------

---single-link proximity clustering of a creep list: members within `radius` of ANY current
---member join the cluster (transitive). O(n^2) per component; n (lane creeps) is small.
---@return table clusters list of member-lists
function Lane._cluster(creeps, radius)
    local r2 = radius * radius
    local n = #creeps
    local seen, clusters = {}, {}
    for i = 1, n do
        if not seen[i] then
            local stack, group = { i }, {}
            seen[i] = true
            while #stack > 0 do
                local k = stack[#stack]; stack[#stack] = nil
                group[#group + 1] = creeps[k]
                local pk = creeps[k].pos
                for j = 1, n do
                    if not seen[j] then
                        local pj = creeps[j].pos
                        local dx, dy = pk.x - pj.x, pk.y - pj.y
                        if dx * dx + dy * dy <= r2 then seen[j] = true; stack[#stack + 1] = j end
                    end
                end
            end
            clusters[#clusters + 1] = group
        end
    end
    return clusters
end

---lane region of a point. The mid lane runs along the SW->NE diagonal (y=x); top hugs the
---upper-left (y>x), bot the lower-right (x>y). `opts.mid_band` = half-width of the mid band
---(default 2500). The precise bent-lane polyline path is a deferred refinement (design sec 7).
function Lane._assign_lane(point, opts)
    local band = (opts and opts.mid_band) or 2500
    local d = point.x - point.y
    if d > band then return "bot"
    elseif d < -band then return "top"
    else return "mid" end
end

-- ---- lane polylines + arc-length mirror (Piece 1.5, TINKER_LANE_MIRROR_DESIGN.md) ------------
-- Fair-game symmetry (user model): both sides' role-paired waves share spawn cadence, travel
-- distance, and speed. So fogged enemy waves are never MODELED - they are our own always-visible
-- waves MIRRORED by arc length along the lane polylines. Visible lanes are read directly.

---total arc length of a polyline { {x,y}, ... }. Pure.
function Lane.PathLength(path)
    local len = 0
    for i = 2, #(path or {}) do
        local dx, dy = path[i].x - path[i - 1].x, path[i].y - path[i - 1].y
        len = len + math.sqrt(dx * dx + dy * dy)
    end
    return len
end

---point at arc-distance `s` from the START of the polyline, clamped to [0, length]. Pure.
function Lane.PointAtArc(path, s)
    if not path or #path == 0 then return nil end
    if s <= 0 then return { x = path[1].x, y = path[1].y } end
    for i = 2, #path do
        local dx, dy = path[i].x - path[i - 1].x, path[i].y - path[i - 1].y
        local seg = math.sqrt(dx * dx + dy * dy)
        if s <= seg and seg > 0 then
            local t = s / seg
            return { x = path[i - 1].x + dx * t, y = path[i - 1].y + dy * t }
        end
        s = s - seg
    end
    return { x = path[#path].x, y = path[#path].y }
end

---arc-distance from the polyline START to the projection of `p` onto its nearest segment. Pure.
function Lane.ArcOfPoint(path, p)
    local best, bestArc, acc = math.huge, 0, 0
    for i = 2, #(path or {}) do
        local ax, ay = path[i - 1].x, path[i - 1].y
        local dx, dy = path[i].x - ax, path[i].y - ay
        local seg2 = dx * dx + dy * dy
        local t = 0
        if seg2 > 0 then t = math.max(0, math.min(1, ((p.x - ax) * dx + (p.y - ay) * dy) / seg2)) end
        local qx, qy = ax + dx * t, ay + dy * t
        local d2 = (p.x - qx) ^ 2 + (p.y - qy) ^ 2
        local seg = math.sqrt(seg2)
        if d2 < best then best, bestArc = d2, acc + seg * t end
        acc = acc + seg
    end
    return bestArc
end

---unit tangent of the polyline at the segment nearest to `p` (the CREEP LINE direction at a lane
---point: the real crash-cast axis, where the fountain axis is only an approximation). Direction
---sign follows path order (team-2 end -> team-3 end); callers that only need the axis (e.g. a
---perpendicular) can ignore the sign. nil for a degenerate path. Pure.
---@return table|nil { x, y }
function Lane.PathTangent(path, p)
    if not (path and #path >= 2 and p) then return nil end
    local best, bi = math.huge, nil
    for i = 2, #path do
        local ax, ay = path[i - 1].x, path[i - 1].y
        local dx, dy = path[i].x - ax, path[i].y - ay
        local seg2 = dx * dx + dy * dy
        local t = 0
        if seg2 > 0 then t = math.max(0, math.min(1, ((p.x - ax) * dx + (p.y - ay) * dy) / seg2)) end
        local qx, qy = ax + dx * t, ay + dy * t
        local d2 = (p.x - qx) ^ 2 + (p.y - qy) ^ 2
        if seg2 > 0 and d2 < best then best, bi = d2, i end
    end
    if not bi then return nil end
    local dx, dy = path[bi].x - path[bi - 1].x, path[bi].y - path[bi - 1].y
    local l = math.sqrt(dx * dx + dy * dy)
    return { x = dx / l, y = dy / l }
end

---lane axis polylines from the STATIC towers (+ captured side-lane creep spawns): one path per
---lane, ordered from the team-2 (Radiant) end to the team-3 (Dire) end. Waypoints = [spawn,] T3,
---T2, T1, enemy T1, T2, T3 [, spawn]; forts/T4s excluded (base, off-lane). Accepts pos as {x,y}
---or a {x,y,z} array (map_data). mid_band defaults 2000 here (not _assign_lane's 2500: the corner
---T3s - good bot (-3952,-6112) d=2160, bad top (3552,5776) d=-2224 - fall inside the 2500 band and
---would misassign to mid). Pure.
function Lane.BuildLanePaths(towers, spawns, opts)
    local band = { mid_band = (opts and opts.mid_band) or 2000 }
    local function xy(p) return { x = p.x or p[1], y = p.y or p[2] } end
    local paths   = { top = {}, mid = {}, bot = {} }
    local buckets = { top = {}, mid = {}, bot = {} }
    for _, t in ipairs(towers or {}) do
        local tier = t.name and tonumber(t.name:match("tower(%d)"))
        if tier and tier <= 3 and t.pos then
            local p = xy(t.pos)
            local ln = Lane._assign_lane(p, band)
            buckets[ln][#buckets[ln] + 1] = { p = p, tier = tier, team = t.team }
        end
    end
    for ln, list in pairs(buckets) do
        table.sort(list, function(a, b)
            if a.team ~= b.team then return a.team < b.team end   -- team-2 side first
            if a.team == 2 then return a.tier > b.tier end        -- T3 -> T1 toward the river
            return a.tier < b.tier                                -- then T1 -> T3 to the Dire end
        end)
        for _, e in ipairs(list) do paths[ln][#paths[ln] + 1] = e.p end
    end
    for _, s in ipairs(spawns or {}) do                           -- creep spawns cap the lane ends
        if s.lane and paths[s.lane] then
            if s.team == 2 then table.insert(paths[s.lane], 1, xy(s.pos))
            else paths[s.lane][#paths[s.lane] + 1] = xy(s.pos) end
        end
    end
    return paths
end

---fogged-wave estimate by ARC-LENGTH MIRROR: our role-paired wave at arc-distance `s` from OUR end
---of its lane => the fogged enemy wave at `s` from THEIR end of its lane. Speed is READ from our
---wave's creeps (role symmetry guarantees theirs matches), never modeled. Paths are ordered
---team-2 end -> team-3 end; `team` picks which end is ours. Pure.
---@return table|nil { front, centroid, speed }  (nil without a usable our-side front)
function Lane.MirrorWave(our_wave, our_path, enemy_path, team)
    if not (our_wave and our_wave.front and our_path and enemy_path) then return nil end
    local olen, elen = Lane.PathLength(our_path), Lane.PathLength(enemy_path)
    local function mirror(p)
        if not p then return nil end
        local s = Lane.ArcOfPoint(our_path, p)                        -- arc from the team-2 end
        if team == 3 then s = olen - s end                            -- Dire's own end is the path END
        return Lane.PointAtArc(enemy_path, team == 2 and (elen - s) or s)   -- `s` from THEIR end
    end
    local speed
    for _, cc in ipairs(our_wave.creeps or {}) do
        if cc.speed and (not speed or cc.speed > speed) then speed = cc.speed end
    end
    return { front = mirror(our_wave.front), centroid = mirror(our_wave.centroid), speed = speed }
end

---Piece 1 measured finding (mirror position error 1407u median): the raw mirror can place a fogged
---front where our own creeps would SEE it - impossible. Absence of vision is data: a fogged enemy
---front must be at least `vis` beyond OUR same-lane front along the lane (arc space). Returns the
---(possibly moved) point; est/our front missing -> unchanged. Pure.
function Lane.ClampBeyondSight(est_front, our_front, path, team, vis)
    if not (est_front and our_front and path) then return est_front end
    vis = vis or 800
    local len = Lane.PathLength(path)
    local function from_our_end(p)
        local a = Lane.ArcOfPoint(path, p)
        return (team == 3) and (len - a) or a
    end
    local ae, ao = from_our_end(est_front), from_our_end(our_front)
    if ae >= ao + vis then return est_front end
    local a = math.min(len, ao + vis)
    return Lane.PointAtArc(path, (team == 3) and (len - a) or a)
end

---build wave structs from a creep list (one team's creeps) given the team's push direction
---(toward the enemy base). Clusters, assigns lanes, computes count/hp/gold/strength + front,
---retains the member list. Pure.
function Lane.DetectWaves(creeps, push_dir, opts)
    opts = opts or {}
    local radius = opts.cluster_radius or 600
    local waves = {}
    for _, group in ipairs(Lane._cluster(creeps, radius)) do
        local centroid = _centroid(group)
        waves[#waves + 1] = {
            team = group[1].team, lane = Lane._assign_lane(centroid, opts), centroid = centroid,
            front = Lane._front(group, push_dir), count = #group,
            hp = _hp(group), gold = Lane._gold(group), strength = Lane._strength(group, opts),
            creeps = group,
        }
    end
    return waves
end

---the point where the two engaged waves MEET. Both sides spawn at the same place and move at the
---same speed, so the fronts close SYMMETRICALLY -> the meeting is the MIDPOINT of the two fronts
---(speed cancels). A fogged enemy wave (an ExpectedWave estimate, no front) is assumed to hold the
---lane centre, so the meeting is between our front and `mid_point`. With neither front -> the lane
---centre. This replaces aiming at the biggest-cluster centroid (which chased the freshly-spawned
---wave back near a tower). Pure.
function Lane.MeetingPoint(ally_wave, enemy_wave, mid_point, push_dir)
    local of = ally_wave and ally_wave.front
    local ef = enemy_wave and enemy_wave.front          -- a fogged estimate has no front
    if of and ef then
        -- BUG 3: a real meeting needs the two fronts to be CLOSING. The enemy front must still be ahead
        -- of ours along OUR push (toward the enemy). If our front has already PASSED the enemy front (our
        -- wave overran, or a fresh enemy wave is far back), the midpoint of those fronts is NOT where they
        -- collide - it lands deep in enemy territory and spuriously trips the depth gate. Fall back to the
        -- lane centre there. push_dir nil -> skip the check (back-compat with the old midpoint behavior).
        if push_dir and mid_point then
            local closing = (ef.x - of.x) * push_dir.x + (ef.y - of.y) * push_dir.y
            if closing <= 0 then return { x = mid_point.x, y = mid_point.y } end
        end
        return { x = (of.x + ef.x) * 0.5, y = (of.y + ef.y) * 0.5 }
    end
    if of and mid_point then return { x = (of.x + mid_point.x) * 0.5, y = (of.y + mid_point.y) * 0.5 } end
    if ef and mid_point then return { x = (ef.x + mid_point.x) * 0.5, y = (ef.y + mid_point.y) * 0.5 } end
    return mid_point or of or ef
end

---kinematic meeting of two waves closing along the line between them. a / b = { pos = {x,y}, speed }.
---They move toward each other; the gap closes at a.speed + b.speed, so they meet after gap/(va+vb)
---seconds at the point a has covered va/(va+vb) of the gap. ONE expression for all three lanes:
---  - mid: equal spawn distance + equal speed -> va/(va+vb) = 0.5 -> the midpoint (the T1 midpoint
---    when fed the spawns), meeting ETA = gap/650.
---  - side lanes: unequal spawn distance and/or the first-15-wave +30%/-35% speed split -> the
---    fraction is not 0.5, so the meeting is off-centre, toward the faster/closer side. Correct by
---    construction, same formula.
---Feed CURRENT positions for visible waves; spawn + speed*elapsed for fogged ones. Pure.
---@return table|nil { point = {x,y}, eta }  (nil if the two are not closing)
function Lane.PredictMeeting(a, b)
    if not (a and b and a.pos and b.pos) then return nil end
    local va, vb = a.speed or 325, b.speed or 325
    local close = va + vb
    if close <= 0 then return nil end
    local dx, dy = b.pos.x - a.pos.x, b.pos.y - a.pos.y
    local gap = math.sqrt(dx * dx + dy * dy)
    local f = va / close                                  -- fraction of the gap covered by a
    return { point = { x = a.pos.x + dx * f, y = a.pos.y + dy * f }, eta = gap / close }
end

-- max live member speed of a wave (est waves carry .speed from the mirror; real waves from members).
function Lane.WaveSpeed(w)
    if not w then return nil end
    -- v0.1.256 arc B re-applied (TINKER_LANE_FREEZE_STUDY.md): the MEASURED displacement beats
    -- the stat - a body-blocked wave reads 325 by stat while standing still (run-64: mid moved
    -- <100 u/s for 25% of the run; run-71: five 22-60s stand waits on held waves). Floor 20
    -- keeps PredictMeeting alive (close > 0), so a HELD wave yields an honest HUGE eta and the
    -- existing far_wave/slack economics jungle it - no new veto.
    if w.speed_measured then return math.max(20, w.speed_measured) end
    if w.speed then return w.speed end
    local s
    for _, cc in ipairs(w.creeps or {}) do if cc.speed and (not s or cc.speed > s) then s = cc.speed end end
    return s
end

---MEASURED front speed (arc B, the lane-freeze study): real lanes get held/frozen by the
---enemy laner - a body-blocked wave's stat speed (NPC.GetMoveSpeed) reads 325 while its
---displacement is ~0, so every stat-fed meeting eta is optimistic by the whole freeze.
---Pure state-in/state-out tracker (the Towers.Track pattern): EMA of the front's
---displacement per key across scan ticks. A front JUMP beyond opts.jump (700 u/s) = a new
---wave replaced the old -> the measurement resets. A sample staler than opts.stale_s (6)
---or a nil front (fog) returns nil - the caller falls back to the stat.
---@return table track, number|nil speed
function Lane.TrackFrontSpeed(track, key, front, now, opts)
    track = track or {}
    local e = track[key]
    if front then
        if e and e.t and now > e.t then
            local dx, dy = front.x - e.x, front.y - e.y
            local inst = math.sqrt(dx * dx + dy * dy) / (now - e.t)
            if inst > ((opts and opts.jump) or 700) then
                track[key] = { x = front.x, y = front.y, t = now }   -- new wave: reset
            else
                local a = (opts and opts.ema) or 0.5
                e.ema = e.ema and (a * e.ema + (1 - a) * inst) or inst
                e.x, e.y, e.t = front.x, front.y, now
            end
        elseif not e then
            track[key] = { x = front.x, y = front.y, t = now }
        end
        e = track[key]
    end
    if e and e.ema and e.t and now - e.t <= ((opts and opts.stale_s) or 6) then
        return track, e.ema
    end
    return track, nil
end

-- ---- clash equilibrium + intercept ---------------------------------------

---equilibrium + movement prediction for a lane. contact = where the fronts meet; each side's
---weight = wave strength + opts.tower_weight per friendly tower within range of the contact; the
---clash drifts toward the weaker side at a rate proportional to the imbalance, clamped at the
---nearest defending tower line. opts: drift_coeff, horizon, creep_speed, move_threshold,
---tower_weight (all calibratable). Pure.
function Lane.PredictClash(enemy_wave, ally_wave, towers, opts)
    opts = opts or {}
    local tower_weight = opts.tower_weight or 4000
    local drift_coeff  = opts.drift_coeff or 0.5
    local horizon      = opts.horizon or 6
    local creep_speed  = opts.creep_speed or 325
    local move_thresh  = opts.move_threshold or 0.1

    local ef = enemy_wave and enemy_wave.front
    local af = ally_wave and ally_wave.front
    local contact
    if ef and af then contact = { x = (ef.x + af.x) * 0.5, y = (ef.y + af.y) * 0.5 }
    elseif ef then contact = { x = ef.x, y = ef.y }
    elseif af then contact = { x = af.x, y = af.y }
    else return nil end

    local we = (enemy_wave and enemy_wave.strength) or 0
    local wa = (ally_wave and ally_wave.strength) or 0
    for _, t in ipairs(towers or {}) do
        if t.alive ~= false and t.pos then
            local dx, dy = t.pos.x - contact.x, t.pos.y - contact.y
            local rng = t.range or 0
            if dx * dx + dy * dy <= rng * rng then
                if enemy_wave and t.team == enemy_wave.team then we = we + tower_weight
                elseif ally_wave and t.team == ally_wave.team then wa = wa + tower_weight end
            end
        end
    end

    local total = we + wa
    local b = (total > 0) and (we - wa) / total or 0
    local moving = math.abs(b) >= move_thresh
    local pushing = (not moving) and "even" or (b > 0 and "enemy" or "ally")
    -- drift toward the losing side's front: enemy stronger (b>0) -> toward the ally front; else
    -- toward the enemy front. Uncontested push (only one front) -> away from contact toward it.
    local toward = (b > 0) and (af or ef) or (ef or af)
    local drift_dir = { x = 0, y = 0 }
    if toward then
        local dx, dy = toward.x - contact.x, toward.y - contact.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then drift_dir = { x = dx / len, y = dy / len } end
    end

    local settle, settle_eta = { x = contact.x, y = contact.y }, 0
    local crashing, crash_tower = false, nil
    if moving then
        local rate = drift_coeff * math.abs(b) * creep_speed
        local travel = rate * horizon
        local defend_team = (b > 0) and (ally_wave and ally_wave.team) or (enemy_wave and enemy_wave.team)
        -- v0.1.383: the pick is a PROXIMITY test, not an unbounded ray. It scored ONLY the
        -- projection along drift_dir, so a tower anywhere sideways won on a tiny projection.
        -- `along` cannot exceed drift_coeff * creep_speed * horizon (~975 at shipped constants),
        -- yet the logged contact-to-tower distance ran a median 3212 in g380 and 96.8-97.2% of
        -- every crash stamp in g379/g380 named a tower the drift cannot physically reach. Those
        -- stamps set State.crashSeen (Tinker.lua:2536) and CRASH_STICKY_S carries them 10s into a
        -- decide where defend_crash skips the round-trip window check. A wave crashes a tower when
        -- it comes within that tower's ATTACK RANGE of the drift segment - bounded sideways AND
        -- ahead, both by the tower's own range, which the strength loop above already reads.
        local best_along
        for _, t in ipairs(towers or {}) do        -- nearest defending tower whose range the drift enters
            if t.alive ~= false and t.pos and t.team == defend_team then
                local tx, ty = t.pos.x - contact.x, t.pos.y - contact.y
                local along  = tx * drift_dir.x + ty * drift_dir.y
                local perp   = math.abs(tx * drift_dir.y - ty * drift_dir.x)
                local rng    = t.range or 700
                if along > 0 and along <= travel + rng and perp <= rng
                   and (best_along == nil or along < best_along) then
                    best_along, crash_tower = along, t
                end
            end
        end
        if best_along then travel = math.min(best_along, travel) end   -- never dragged past the budget
        crashing = crash_tower ~= nil                -- the wave pushes up to a defending tower (crashes into it)
        settle = { x = contact.x + drift_dir.x * travel, y = contact.y + drift_dir.y * travel }
        settle_eta = (rate > 0) and (travel / rate) or 0
    end

    return { contact = contact, settle = settle, drift_dir = drift_dir, settle_eta = settle_eta,
             w_enemy = we, w_ally = wa, pushing = pushing, moving = moving,
             crashing = crashing, crash_tower = crash_tower }
end

---ETA to reach `target` from `from_pos`, via the best ready teleport anchor or plain walk. Used
---both for "can I reach this wave now" (from_pos = hero) and "ETA to the next lane" (from_pos =
---a lane's settle point). Generic anchor list; the hero's Keen-level rules are applied upstream.
function Lane.InterceptETA(from_pos, anchors, move_speed, tp, target, clearable_until)
    local ms = math.max(150, move_speed or 300)
    local function dist(a, b) local dx, dy = a.x - b.x, a.y - b.y; return math.sqrt(dx * dx + dy * dy) end
    local channel = (tp and tp.channel) or 0
    local eta, best = dist(from_pos, target) / ms, nil   -- plain walk baseline
    for _, a in ipairs(anchors or {}) do
        if a.ready and a.pos then
            local e = channel + dist(a.pos, target) / ms
            if e < eta then eta, best = e, a end
        end
    end
    return { best_anchor = best, eta = eta,
             reachable = (clearable_until == nil) or (eta <= clearable_until) }
end

---nearest READY anchor of an allowed kind to `point` (nil allowed_kinds = any kind).
---@return table|nil anchor
---@return number|nil distance
function Lane.NearestTeleportAnchor(point, anchors, allowed_kinds)
    local allow
    if allowed_kinds then allow = {}; for _, k in ipairs(allowed_kinds) do allow[k] = true end end
    local best, bestd2 = nil, math.huge
    for _, a in ipairs(anchors or {}) do
        if a.ready and a.pos and (not allow or allow[a.kind]) then
            local dx, dy = a.pos.x - point.x, a.pos.y - point.y
            local d2 = dx * dx + dy * dy
            if d2 < bestd2 then best, bestd2 = a, d2 end
        end
    end
    return best, best and math.sqrt(bestd2) or nil
end

-- ---- assembler -----------------------------------------------------------

---compose the full per-lane state from plain inputs. Splits creeps by team, detects waves per
---side (with each team's push direction from opts.enemy_push / opts.ally_push), picks the biggest
---wave per lane per side, predicts the clash, counts heroes near it, and (if anchors + kinematics
---are present) computes the intercept to the clash settle point. Pure.
function Lane.BuildLaneStates(creeps, towers, heroes, opts)
    opts = opts or {}
    local team = opts.team
    local enemy_push = opts.enemy_push or { x = 1, y = 1 }
    local ally_push  = opts.ally_push or { x = -1, y = -1 }

    local mine, theirs = {}, {}
    for _, cc in ipairs(creeps or {}) do
        if cc.team == team then mine[#mine + 1] = cc else theirs[#theirs + 1] = cc end
    end
    local enemy_waves = Lane.DetectWaves(theirs, enemy_push, opts)
    local ally_waves  = Lane.DetectWaves(mine, ally_push, opts)

    -- the ENGAGED wave per lane = the cluster whose front is FURTHEST ADVANCED along the team's push
    -- direction (nearest the lane equilibrium), NOT the biggest cluster. The biggest is usually the
    -- freshly-spawned wave back near a tower, so aiming at it sent the shove to a base (notes 1/2/3).
    local function engaged_by_lane(waves, push)
        local by, bestp = {}, {}
        for _, w in ipairs(waves) do
            local f = w.front
            if f then
                local proj = f.x * push.x + f.y * push.y
                if by[w.lane] == nil or proj > bestp[w.lane] then by[w.lane] = w; bestp[w.lane] = proj end
            end
        end
        return by
    end
    local eByLane, aByLane = engaged_by_lane(enemy_waves, enemy_push), engaged_by_lane(ally_waves, ally_push)

    local towers_by_lane = { top = {}, mid = {}, bot = {} }
    for _, t in ipairs(towers or {}) do
        if t.pos then local ln = Lane._assign_lane(t.pos, opts); towers_by_lane[ln][#towers_by_lane[ln] + 1] = t end
    end

    local hero_r2 = (opts.hero_radius or 1200) ^ 2
    local lanes = {}
    for _, lane in ipairs({ "top", "mid", "bot" }) do
        local ew, aw = eByLane[lane], aByLane[lane]
        -- v0.1.375: THIS LANE's towers, not all 24. PredictClash clamps the drift at the nearest
        -- defending tower AHEAD (:397-402), scoring each by its projection ALONG drift_dir with NO
        -- perpendicular bound, so any tower anywhere on the map with a positive projection could win
        -- and become the crash target. Measured on 5 logs: 60-77% of every game's crash stamps named
        -- an OFF-LANE tower (g374 156/224, ctd median 8087 against ctr=700, max 15431; one named a
        -- bot-side tower at (4860,-6379) as TOP's crash target). Those stamps set State.crashSeen
        -- (Tinker.lua:2573-2576) and CRASH_STICKY_S 10.0 carries them 10s forward into a decide,
        -- where the defend_crash bypass (Tinker.lua:3741) skips the round-trip window check: g374
        -- t=345.8 spent ~10.2s and a Keen on a top trip worth 0 gold on exactly that path.
        -- towers_by_lane is already built above (:483-486) and already used correctly at :545/:561;
        -- this was the one consumer still reading the unfiltered list. A lane's wave crashes that
        -- lane's towers. ACCEPTED NARROWING: base/T4 towers sit near the diagonal and _assign_lane
        -- (:86) puts them in "mid", so a side-lane wave pushing into the enemy base no longer reports
        -- crashing - out of scope for the farm layer's defend, which is about OUR lane towers.
        local clash = (ew or aw) and Lane.PredictClash(ew, aw, towers_by_lane[lane], opts) or nil  -- clash from VISIBLE positions only
        if not ew and opts.game_time then            -- fog-fill: estimate the unseen enemy wave (fogged ONLY)
            local est = Lane.ExpectedWave(opts.game_time, { super = opts.super, mega = opts.mega })
            est.lane, est.estimated = lane, true
            est.team = (opts.team == 2) and 3 or 2
            -- Piece 1.5 MIRROR: the fogged enemy's role-paired wave = OUR wave in the paired lane
            -- (their safe walks the lane our off walks: top<->bot, mid<->mid; same spawn cadence,
            -- travel, and speed modifier by fair-game symmetry). Position + speed come from the
            -- arc-length mirror of our always-visible wave; composition/hp/gold stay the clock
            -- model. No paired wave visible -> clock-only (composition, no position), as before.
            local PAIR = { top = "bot", mid = "mid", bot = "top" }
            local ow = opts.paths and aByLane[PAIR[lane]]
            local m = ow and Lane.MirrorWave(ow, opts.paths[PAIR[lane]], opts.paths[lane], team)
            if m and m.front then
                -- vision-edge floor (Piece 1 measured): our SAME-lane wave bounds the estimate -
                -- a fogged front cannot sit where our creeps would see it.
                local same = aByLane[lane]
                if same and same.front then
                    m.front    = Lane.ClampBeyondSight(m.front, same.front, opts.paths[lane], team, opts.creep_vision)
                    m.centroid = m.centroid and Lane.ClampBeyondSight(m.centroid, same.front, opts.paths[lane], team, opts.creep_vision)
                end
                est.front, est.centroid, est.speed, est.est_src = m.front, m.centroid, m.speed, "mirror"
            else
                est.est_src = "clock"
            end
            ew = est                                 -- a mirrored estimate HAS a front -> MeetingPoint works fogged
        end

        local en, an = 0, 0
        if clash then
            for _, h in ipairs(heroes or {}) do
                local dx, dy = h.pos.x - clash.contact.x, h.pos.y - clash.contact.y
                if dx * dx + dy * dy <= hero_r2 then
                    if h.team == team then an = an + 1 else en = en + 1 end
                end
            end
        end

        local intercept = nil
        if clash and opts.anchors and opts.hero_pos and opts.move_speed then
            local anchors = {}
            for _, a in ipairs(opts.anchors) do anchors[#anchors + 1] = a end
            local allow = {}
            for _, k in ipairs(opts.allowed_kinds or {}) do allow[k] = true end
            if allow.creep then for _, cc in ipairs(mine) do anchors[#anchors + 1] = { pos = cc.pos, ready = true, kind = "creep" } end end
            if allow.ally then for _, h in ipairs(heroes or {}) do if h.team == team then anchors[#anchors + 1] = { pos = h.pos, ready = true, kind = "ally" } end end end
            local clearable_until = (clash.settle_eta or 0) + (opts.clear_window or 5)
            intercept = Lane.InterceptETA(opts.hero_pos, anchors, opts.move_speed, opts.tp, clash.settle, clearable_until)
        end

        -- lane centre = midpoint of each side's FRONT (most-advanced) tower in this lane = a stable
        -- geometric anchor (no tower names) used as the meeting fallback when a side is fogged.
        local own_t1, enemy_t1, op, ep
        for _, t in ipairs(towers_by_lane[lane]) do
            if t.pos then
                if t.team == team then
                    local pr = t.pos.x * ally_push.x + t.pos.y * ally_push.y
                    if not own_t1 or pr > op then own_t1, op = t.pos, pr end
                else
                    local pr = t.pos.x * enemy_push.x + t.pos.y * enemy_push.y
                    if not enemy_t1 or pr > ep then enemy_t1, ep = t.pos, pr end
                end
            end
        end
        local mid_point = (own_t1 and enemy_t1)
            and { x = (own_t1.x + enemy_t1.x) * 0.5, y = (own_t1.y + enemy_t1.y) * 0.5 } or nil

        lanes[lane] = {
            lane = lane, enemy_wave = ew, ally_wave = aw,
            gold = (ew and ew.gold) or 0, towers = towers_by_lane[lane],
            enemy_heroes = en, ally_heroes = an, clash = clash, intercept = intercept,
            meeting = Lane.MeetingPoint(aw, ew, mid_point, ally_push),   -- where the two engaged waves collide (the shove aim); ally_push gates closure (BUG 3)
        }
    end
    return lanes
end

-- ---- expected wave by game time (Liquipedia-validated parametrization) ----
-- Composition + per-cycle scaling for fog estimates + gold valuation. game_time in seconds on the
-- GAME CLOCK (0 = the first wave at 00:00). See Tinker/TINKER_LANE_DESIGN.md + Liquipedia Lane_Creeps.

-- base melee/ranged by time threshold (ascending); siege/flagbearer handled by wave cadence below.
local WAVE_COMP = {
    { 0, 3, 1 }, { 900, 4, 1 }, { 1800, 5, 1 }, { 2400, 5, 2 }, { 2700, 6, 2 },
}
-- per-creep { hp, gold, hpc = hp/cycle, goldc = gold/cycle } at cycle 0 (cycle = floor(t/450), max 30).
-- gold = the MAX bounty of the range, to match the visible path (sums NPC.GetGoldBountyMax) + the
-- camp-farm convention, so fogged-vs-visible lane gold is apples-to-apples.
-- COMBAT fields (Piece 1.5 push model, Liquipedia Lane_Creeps-verified 2026-07-01): dmg = avg attack
-- damage, dmgc = +dmg per 7:30 upgrade cycle, atk = BAT seconds, armor, atype = attack type.
local CREEP_STATS = {
    melee   = { hp = 550,  gold = 39, hpc = 12, goldc = 1,   dmg = 21,    dmgc = 1, atk = 1, armor = 2, atype = "basic" },
    ranged  = { hp = 300,  gold = 52, hpc = 12, goldc = 3,   dmg = 23.5,  dmgc = 2, atk = 1, armor = 0, atype = "pierce" },
    siege   = { hp = 935,  gold = 72, hpc = 0,  goldc = 0,   dmg = 40.5,  dmgc = 0, atk = 3, armor = 0, atype = "siege" },   -- siege does not upgrade per-cycle
    smelee  = { hp = 700,  gold = 26, hpc = 19, goldc = 1.5, dmg = 40,    dmgc = 2, atk = 1, armor = 3, atype = "basic" },   -- super (post-barracks)
    sranged = { hp = 475,  gold = 25, hpc = 18, goldc = 6,   dmg = 43.5,  dmgc = 3, atk = 1, armor = 1, atype = "pierce" },
    mmelee  = { hp = 1270, gold = 26, hpc = 0,  goldc = 0,   dmg = 100,   dmgc = 0, atk = 1, armor = 3, atype = "basic" },   -- mega (base-only; end-game)
    mranged = { hp = 1015, gold = 25, hpc = 0,  goldc = 0,   dmg = 133.5, dmgc = 0, atk = 1, armor = 1, atype = "pierce" },
}
local function _stat_hp(s, cyc)   return s.hp + s.hpc * cyc end
local function _stat_gold(s, cyc) return s.gold + s.goldc * cyc end

---per-creep expected stats at `game_time` (seconds, game clock). Pure. kind in
---melee|ranged|siege|smelee|sranged|mmelee|mranged (see CREEP_STATS).
---@return table|nil { hp, gold, dmg, atk, armor, atype }
function Lane.CreepStats(kind, game_time)
    local s = CREEP_STATS[kind]
    if not s then return nil end
    local cyc = math.min(30, math.floor(math.max(0, game_time or 0) / 450))
    return { hp = _stat_hp(s, cyc), gold = _stat_gold(s, cyc),
             dmg = s.dmg + s.dmgc * cyc, atk = s.atk, armor = s.armor, atype = s.atype }
end

---expected wave composition + value at `game_time` (seconds, game clock). opts.super / opts.mega
---swap regular melee/ranged for super/mega stats (barracks state; default regular). Pure.
---@return table { wave, cycle, melee, ranged, siege, flagbearer, count, hp, gold, strength }
function Lane.ExpectedWave(game_time, opts)
    opts = opts or {}
    local t = math.max(0, game_time or 0)
    local wave = math.floor(t / 30) + 1
    local cyc = math.min(30, math.floor(t / 450))

    local melee, ranged = 3, 1
    for i = 1, #WAVE_COMP do
        if t >= WAVE_COMP[i][1] then melee, ranged = WAVE_COMP[i][2], WAVE_COMP[i][3] end
    end

    local siege = 0                                       -- every 10th wave from wave 11; 1 -> 2 (30:00) -> 3 (60:00)
    if wave >= 11 and (wave - 11) % 10 == 0 then
        siege = (t >= 3600 and 3) or (t >= 1800 and 2) or 1
    end
    local flagbearer = 0                                  -- every 2nd wave from wave 5; replaces a melee (regular only)
    if not (opts.super or opts.mega) and wave >= 5 and (wave - 5) % 2 == 0 then
        flagbearer = 1; melee = melee - 1
    end

    local ms = (opts.mega and CREEP_STATS.mmelee) or (opts.super and CREEP_STATS.smelee) or CREEP_STATS.melee
    local rs = (opts.mega and CREEP_STATS.mranged) or (opts.super and CREEP_STATS.sranged) or CREEP_STATS.ranged
    local fs, ss = CREEP_STATS.melee, CREEP_STATS.siege   -- flagbearer = melee stats (regular waves only)

    local hp = melee * _stat_hp(ms, cyc) + ranged * _stat_hp(rs, cyc)
             + siege * _stat_hp(ss, cyc) + flagbearer * _stat_hp(fs, cyc)
    local gold = melee * _stat_gold(ms, cyc) + ranged * _stat_gold(rs, cyc)
             + siege * _stat_gold(ss, cyc) + flagbearer * _stat_gold(fs, cyc)
    -- Piece 1.5 fix: the flagbearer's BOUNTY is already in the base sum above; the area term adds
    -- ONLY the +10 area gold. The old `10 + bounty` term double-counted the bounty (218 vs real 179).
    if flagbearer > 0 then gold = gold + flagbearer * 10 end

    return { wave = wave, cycle = cyc, melee = melee, ranged = ranged, siege = siege,
             flagbearer = flagbearer, count = melee + ranged + siege + flagbearer,
             hp = hp, gold = gold, strength = hp }
end

-- ---- lane combat sim + push forecast (Piece 1.5: lanes push each other) ---------------------
-- User model: an imbalance of 1 creep gives more DAMAGE, not only life - attrition COMPOUNDS
-- (the extra creep both soaks and keeps shooting while the enemy's dps shrinks). So the push is
-- SIMULATED per attacker, never inferred from an hp-pool comparison.

-- attack-type vs BASIC (creep) armor multipliers. VERIFY: Liquipedia does not publish the attack-
-- type table (Armor page has only the armor formula, 3 pages checked 2026-07-01); values are the
-- standard KV-documented table. pierce 1.5x vs creeps is the one that matters here (why ranged
-- creeps shred creeps); a wrong value shows up as systematic bias in the --lane-report push judge.
local ATK_VS_BASIC = { basic = 1.0, pierce = 1.5, siege = 1.0, hero = 1.0 }
local function _armor_mult(armor) return 1 - (0.06 * armor) / (1 + 0.06 * math.abs(armor)) end

---discrete attrition sim between two combatant lists ({ hp, dmg, atk, armor, atype } each; list
---order = focus order, front-most first). Both sides FOCUS the first living foe; damage lands
---simultaneously per tick (razor-edge mutual kills resolve as mutual). opts.support_a/support_b =
---untargetable attackers (towers). Pure, deterministic.
---@return table { winner = "a"|"b"|"draw", t, remnant_a, remnant_b }
function Lane.SimFight(a, b, opts)
    opts = opts or {}
    local dt, tmax = opts.dt or 0.25, opts.t_max or 90
    local function prep(list)
        local out = {}
        for i, u in ipairs(list or {}) do
            out[i] = { hp = u.hp or 0, dmg = u.dmg or 0, atk = u.atk or 1,
                       armor = u.armor or 0, atype = u.atype or "basic", next_at = 0 }
        end
        return out
    end
    local A, B   = prep(a), prep(b)
    local sA, sB = prep(opts.support_a), prep(opts.support_b)
    local function first_alive(t) for i = 1, #t do if t[i].hp > 0 then return t[i] end end end
    local function volley(side, sup, tgt, t)
        if not tgt then return 0 end
        local d = 0
        local function swing(u, targetable)
            if targetable and u.hp <= 0 then return end
            if u.next_at <= t then
                d = d + u.dmg * (ATK_VS_BASIC[u.atype] or 1) * _armor_mult(tgt.armor)
                u.next_at = u.next_at + u.atk
            end
        end
        for i = 1, #side do swing(side[i], true) end
        for i = 1, #sup do swing(sup[i], false) end
        return d
    end
    local t = 0
    while t < tmax do
        local ta, tb = first_alive(B), first_alive(A)   -- A focuses ta; B focuses tb
        if not (ta and tb) then break end
        local da = volley(A, sA, ta, t)
        local db = volley(B, sB, tb, t)
        ta.hp = ta.hp - da                              -- simultaneous application: deaths resolve together
        tb.hp = tb.hp - db
        t = t + dt
    end
    local function rem(side)
        local out = {}
        for i = 1, #side do if side[i].hp > 0 then out[#out + 1] = side[i] end end
        return out
    end
    local ra, rb = rem(A), rem(B)
    local winner = (#ra > 0 and #rb == 0 and "a") or (#rb > 0 and #ra == 0 and "b") or "draw"
    return { winner = winner, t = t, remnant_a = ra, remnant_b = rb }
end

-- kind -> stats key (flagbearer fights as a melee creep) + focus order (front-most first).
local KIND_STATS = { melee = "melee", flagbearer = "melee", ranged = "ranged", siege = "siege" }
local KIND_ORDER = { melee = 1, flagbearer = 2, siege = 3, ranged = 4 }

---combat records from a wave: a REAL wave uses LIVE member hp + per-member kind (classified from
---the unit name by the read wrapper); an ESTIMATED wave / plain composition table builds full-hp
---records from its melee/ranged/siege/flagbearer counts. `cycle` scales dmg/hp per 7:30. Pure.
function Lane.WaveCombatants(wave, cycle, opts)
    local cyc = cycle or 0
    local out = {}
    local function rec(kind, hp)
        local s = CREEP_STATS[KIND_STATS[kind] or "melee"]
        out[#out + 1] = { hp = hp or _stat_hp(s, cyc), dmg = s.dmg + s.dmgc * cyc,
                          atk = s.atk, armor = s.armor, atype = s.atype, kind = kind }
    end
    if wave and wave.creeps and #wave.creeps > 0 then
        for _, cc in ipairs(wave.creeps) do rec(cc.kind or "melee", cc.hp) end
    elseif wave then
        for _ = 1, wave.melee or 0 do rec("melee") end
        for _ = 1, wave.flagbearer or 0 do rec("flagbearer") end
        for _ = 1, wave.ranged or 0 do rec("ranged") end
        for _ = 1, wave.siege or 0 do rec("siege") end
    end
    table.sort(out, function(x, y) return (KIND_ORDER[x.kind] or 1) < (KIND_ORDER[y.kind] or 1) end)
    return out
end

---iterated push forecast: SimFight the current waves; each following round the LOSER's side is a
---fresh full wave (30s cadence) while the winner carries its remnant + a fresh wave - the snowball
---trend across rounds is the push. Output: bal = round-1 net survivors (signed lane balance, + = a
---wins), first_t = round-1 fight duration (the peta basis), rounds = {{winner, t, net}}.
---(Front-position trajectory / crash_eta = deferred until the merge model is judged in-client -
---the --lane-report push judge scores bal against OBSERVED front movement, which needs no model.)
function Lane.PushForecast(ally_wave, enemy_wave, opts)
    opts = opts or {}
    local n = opts.rounds or 2
    local A = Lane.WaveCombatants(ally_wave, opts.cycle)
    local B = Lane.WaveCombatants(enemy_wave, opts.cycle)
    local fresh = Lane.WaveCombatants(Lane.ExpectedWave(opts.game_time or 0, {}), opts.cycle)
    local out = { rounds = {} }
    for r = 1, n do
        local f = Lane.SimFight(A, B, opts)
        out.rounds[r] = { winner = f.winner, t = f.t, net = #f.remnant_a - #f.remnant_b }
        if r == 1 then out.bal, out.first_t = out.rounds[1].net, f.t end
        if r < n then                                     -- both sides reinforce; the winner keeps its remnant
            local function merge(remnant)
                local m = {}
                for i = 1, #remnant do m[#m + 1] = remnant[i] end
                for i = 1, #fresh do m[#m + 1] = { hp = fresh[i].hp, dmg = fresh[i].dmg, atk = fresh[i].atk,
                                                   armor = fresh[i].armor, atype = fresh[i].atype, kind = fresh[i].kind } end
                return m
            end
            A, B = merge(f.remnant_a), merge(f.remnant_b)
        end
    end
    return out
end

-- ---- engine wrappers (verified in-game; nothing runs at load) -------------
-- Lane-creep enumeration uses the TYPE_LANE_CREEP unit-type flag (confirmed prior-art: the
-- AutofarmV2 script + our own TYPE_STRUCTURE idiom). Pure-core tests never call these.

local function _read_lane_creeps()
    local out = {}
    for _, n in ipairs(NPCs.GetAll(Enum.UnitTypeFlags.TYPE_LANE_CREEP) or {}) do
        if Entity.IsAlive(n) and not Entity.IsDormant(n)
           and not (NPC.IsWaitingToSpawn and NPC.IsWaitingToSpawn(n)) then
            local p = Entity.GetAbsOrigin(n)
            if p then
                -- Piece 1.5: kind from the unit NAME (npc_dota_creep_*_melee/ranged/siege/flagbearer)
                -- for the combat sim (creep attack damage is NOT engine-readable - stats table by kind).
                local nm = (NPC.GetUnitName and NPC.GetUnitName(n)) or ""
                local kind = (nm:find("flagbearer", 1, true) and "flagbearer")
                          or (nm:find("ranged", 1, true) and "ranged")
                          or (nm:find("siege", 1, true) and "siege") or "melee"
                out[#out + 1] = { pos = { x = p.x, y = p.y }, team = Entity.GetTeamNum(n),
                                  hp = Entity.GetHealth(n) or 0, max_hp = Entity.GetMaxHealth(n) or 0,
                                  gold = (NPC.GetGoldBountyMax and NPC.GetGoldBountyMax(n)) or 0,
                                  kind = kind,
                                  -- Piece 1.5: live EFFECTIVE speed (includes the first-15-wave
                                  -- side-lane modifier) - the mirror READS it, never models it.
                                  speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(n)) or nil }
            end
        end
    end
    return out
end

local function _read_towers()
    local out = {}
    for _, t in ipairs(Towers.GetAll() or {}) do
        local p = Entity.GetAbsOrigin(t)
        if p then out[#out + 1] = { pos = { x = p.x, y = p.y }, team = Entity.GetTeamNum(t),
                                    range = (NPC.GetAttackRange and NPC.GetAttackRange(t)) or 700,
                                    alive = Entity.IsAlive(t) } end
    end
    return out
end

local function _read_heroes()
    local out = {}
    for _, h in ipairs(Heroes.GetAll() or {}) do
        if Entity.IsAlive(h) and (not NPC.IsIllusion or not NPC.IsIllusion(h)) then
            local p = (not Entity.IsDormant(h)) and Entity.GetAbsOrigin(h) or Hero.GetLastMaphackPos(h)
            if p then out[#out + 1] = { pos = { x = p.x, y = p.y }, team = Entity.GetTeamNum(h) } end
        end
    end
    return out
end

---read the live map and return per-lane state. opts.team defaults to the local hero's team; all
---calibration/anchor opts pass straight through to BuildLaneStates.
function Lane.ScanLanes(opts)
    opts = opts or {}
    if opts.team == nil then
        local me = Heroes.GetLocal and Heroes.GetLocal()
        opts.team = me and Entity.GetTeamNum(me) or nil
    end
    return Lane.BuildLaneStates(_read_lane_creeps(), _read_towers(), _read_heroes(), opts)
end

-- ---- S2 per-lane depth ruler (v0.1.327, the side-parity fix) ---------------
-- The old depth zero (the FOUNTAIN midpoint) sits ~580 lane-units toward Radiant
-- of the mid lane's true centre (the T1 midpoint = where waves actually meet), so
-- every absolute depth threshold was ~580 stricter for Dire and ~580 looser for
-- Radiant on mid. The ruler zeroes per lane instead; the axis stays the fountain
-- axis (vs the mid chord it differs by < 2 degrees). Pure functions - the hero
-- brain AND tools/parse_debuglog's depth-audit consume THESE, so the auditor can
-- never drift from the brain. Ceiling (S4, the tree review 2026-07-20):
-- arc-length depth along BuildLanePaths if side-lane precision ever needs it -
-- same contract, internal swap.

---build the per-team depth ruler from static map data. towers/fountains are
---map_data-shaped lists ({name=, team=, pos={x,y,z}}); team = the OWN team id.
---Returns { ax, ay (unit axis own->enemy), zero = { mid={x,y}, top=..., bot=... } }
---or nil when the inputs are unusable.
function Lane.DepthRuler(towers, fountains, team)
    local fp, ep
    for _, f in ipairs(fountains or {}) do
        if f.pos then
            if f.team == team then fp = f.pos else ep = f.pos end
        end
    end
    if not (fp and ep) then return nil end
    local ax, ay = ep[1] - fp[1], ep[2] - fp[2]
    local al = math.sqrt(ax * ax + ay * ay)
    if al < 1 then return nil end
    local acc = {}
    for _, t in ipairs(towers or {}) do
        local ln = t.name and t.name:match("tower1_(%w+)")
        if ln and t.pos then
            acc[ln] = acc[ln] or {}
            table.insert(acc[ln], t.pos)
        end
    end
    local zero = {}
    for ln, ps in pairs(acc) do
        if #ps == 2 then
            zero[ln] = { x = (ps[1][1] + ps[2][1]) * 0.5, y = (ps[1][2] + ps[2][2]) * 0.5 }
        end
    end
    if not zero.mid then return nil end
    return { ax = ax / al, ay = ay / al, zero = zero }
end

---signed lane-frame depth of pos ({x,y} or Vector) for `lane` (defaults to mid;
---an unknown lane falls back to mid). 0 = the lane's T1 midpoint (the meet
---ground); + = enemy side; own mid T1 reads ~-1459, enemy mid T1 ~+1459.
function Lane.Depth(ruler, pos, lane)
    if not (ruler and pos) then return 0 end
    local z = ruler.zero[lane or "mid"] or ruler.zero.mid
    return (pos.x - z.x) * ruler.ax + (pos.y - z.y) * ruler.ay
end

return Lane
