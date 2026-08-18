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

return Map
