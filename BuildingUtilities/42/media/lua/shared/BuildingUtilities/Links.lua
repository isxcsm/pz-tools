-- The lines of the boxes: what a box reaches past its zone, as a tree out from its zone's walls. A line is laid from a
-- thing to what it hangs on: the nearest wall square of a box's zone (an outdoor box's own square), a relay (a pole
-- for power, a yard hydrant for water: BU.RELAY_KINDS), or a device already on a line that uses the utility outside
-- (a lamp, a sprinkler: one that carries the line on). Producers, water storage, machines and racks only end a line.
--
-- Lines are kept apart from the boxes (Store.lines), by the thing's ref: "p:x,y,z" a producer (a generator, water
-- storage), "u:<id>" a unit (a relay among them), "t:<thing key>" a device outside. A line: { panel (the box it is of;
-- nil once that box is gone), utility, via (the ref it hangs on; nil from the wall), wall (the wall square, BU.placeKey,
-- for one from the wall), seq (the order lines were laid), length (squares, a floor counting BU.tilesPerFloor), paid
-- (what it took), x, y, z (where the thing is) }. A relay taken up, a box taken down or a wall's room out of the zone
-- leaves what hung there cut, its lines laid, until its first line is hung on again (Changes.rehang): the whole branch
-- then is the box's it hangs on.
--
-- What a box's lines supply is worked out from their shape now, not from how they were laid (Links.state): out from
-- the walls, fewest lines first, then by when each was laid, a relay counts toward the box's limit (BU.relayLimit), a
-- device toward the CHAIN_LIMIT of its head (the device hung on a wall or relay its branch starts from), and a line from
-- a wall must be within the box's range (BU.connectRange). What is past a limit, or behind something that is, is cut
-- with a reason; it comes back of itself when the limit grows (an upgrade) or the shape changes.
require "BuildingUtilities/Panels"
local BU = BuildingUtilities
local Store, Panels, Geometry = BU.Store, BU.Panels, BU.Geometry
local Links = {}
BU.Links = Links

-- The reasons a line supplies nothing: "cut" (what it hangs on is gone, or not of the box), "relays" (past the box's
-- relays), "chain" (past its head's devices), "far" (a line from the wall longer than the box's range).
Links.REASONS = { "cut", "relays", "chain", "far" }

function Links.producerRef(x, y, z) return "p:" .. BU.placeKey(x, y, z) end
function Links.unitRef(unit) return "u:" .. unit.id end
function Links.deviceRef(key) return "t:" .. key end

function Links.all() return Store.data().lines end
function Links.get(ref) return ref and Store.data().lines[ref] or nil end

-- The unit a ref names, or nil.
function Links.unitOf(ref)
    local id = ref and ref:match("^u:(.+)$")
    return id and Store.unit(id) or nil
end

-- Whether a line's thing is a relay, and whether it carries the line on to more (a relay, a device outside, a
-- sprinkler).
function Links.isRelay(ref)
    local unit = Links.unitOf(ref)
    return unit ~= nil and BU.RELAY_KINDS[unit.kind] ~= nil
end

function Links.carries(ref)
    if ref:sub(1, 2) == "t:" then return true end
    local unit = Links.unitOf(ref)
    return unit ~= nil and (BU.RELAY_KINDS[unit.kind] ~= nil or unit.kind == "sprinkler")
end

-- Where two lines side by side go across one going dx, dy: half of `gap` across it, one each way (0, 0 for no
-- length). A machine's inlet and outlet pipes run so (Water.linePipes).
function Links.besideOffset(dx, dy, gap)
    local length = math.sqrt(dx * dx + dy * dy)
    if length <= 0 then return 0, 0 end
    return -dy / length * gap / 2, dx / length * gap / 2
end

-- A line's length between two squares: steps on the ground (a diagonal one), and BU.tilesPerFloor a floor.
function Links.length(x, y, z, tx, ty, tz)
    return math.max(math.abs(x - tx), math.abs(y - ty)) + math.abs(z - tz) * BU.tilesPerFloor()
end

-- The lines of each box, by panel id, and the lines hanging on each ref; kept while they are the same.
local indexToken, byPanel, children

local function index()
    local token = Store.linkVersion()
    if indexToken == token then return end
    indexToken, byPanel, children = token, {}, {}
    for ref, line in pairs(Links.all()) do
        line.ref = ref
        if line.panel then
            byPanel[line.panel] = byPanel[line.panel] or {}
            table.insert(byPanel[line.panel], line)
        end
        if line.via then
            children[line.via] = children[line.via] or {}
            table.insert(children[line.via], line)
        end
    end
    local function bySeq(a, b) return (a.seq or 0) < (b.seq or 0) end
    for _, list in pairs(byPanel) do table.sort(list, bySeq) end
    for _, list in pairs(children) do table.sort(list, bySeq) end
end

-- The lines of a box, in the order they were laid.
function Links.of(panel)
    index()
    return byPanel[panel.id] or {}
end

-- The lines hanging on a ref, in the order they were laid.
function Links.childrenOf(ref)
    index()
    return children[ref] or {}
end

-- The lines of a branch: the line of a ref and every line hanging on it, down; each once.
function Links.branch(ref)
    local result, seen = {}, {}
    local function walk(line)
        if seen[line.ref] then return end
        seen[line.ref] = true
        result[#result + 1] = line
        for _, child in ipairs(Links.childrenOf(line.ref)) do walk(child) end
    end
    local line = Links.get(ref)
    if line then
        index()
        walk(line)
    end
    return result
end

-- Whether a wall square is still the box's: in a room of its zone (an outdoor box's own square, while it stands).
function Links.wallHolds(panel, wall)
    if not wall then return false end
    if wall == BU.placeKey(panel.x, panel.y, panel.z) then return true end
    local x, y, z = BU.parsePlace(wall)
    return x ~= nil and Panels.roomHaving(Panels.zoneRooms(panel), x, y, z) ~= nil
end

-- What a box's lines supply now: { live = { [ref] = true }, reason = { [ref] = a Links.REASONS }, head = { [ref] =
-- the head's ref }, chained = { [head ref] = how many hang below it }, relays (how many supply), depth = { [ref] =
-- lines out from the wall } }. Kept while the lines, the box's tier and the buildings are the same.
local states = {}

function Links.state(panel)
    local api = BU.api()
    local token = Store.linkVersion() .. "|" .. (panel.tier or 1) .. "|" .. tostring(api and api.buildings.version())
        .. "|" .. tostring(panel.zone)
    local kept = states[panel.id]
    if kept and kept.token == token then return kept end
    local lines = Links.of(panel)
    local state = { token = token, live = {}, reason = {}, head = {}, chained = {}, relays = 0, depth = {} }
    local mine = {}
    for _, line in ipairs(lines) do mine[line.ref] = line end
    -- The first lines: those from a wall, and those whose line hangs on nothing of the box (cut).
    local level, range, limit = {}, BU.connectRange(panel.tier), BU.relayLimit(panel.tier)
    for _, line in ipairs(lines) do
        if not line.via then
            level[#level + 1] = line
            if not Links.wallHolds(panel, line.wall) then state.reason[line.ref] = "cut"
            elseif (line.length or 0) > range then state.reason[line.ref] = "far" end
        elseif not mine[line.via] then
            state.reason[line.ref] = "cut"
        end
    end
    local depth = 0
    while #level > 0 do
        local nextLevel = {}
        for _, line in ipairs(level) do
            local ref = line.ref
            state.depth[ref] = depth
            local parent = line.via
            local reason = state.reason[ref]
            if not reason and parent then reason = state.reason[parent] end
            if not reason then
                if Links.isRelay(ref) then
                    if state.relays < limit then state.relays = state.relays + 1 else reason = "relays" end
                else
                    local head = parent and not Links.isRelay(parent) and state.head[parent] or ref
                    state.head[ref] = head
                    if head ~= ref then
                        state.chained[head] = (state.chained[head] or 0) + 1
                        if state.chained[head] > BU.CHAIN_LIMIT then reason = "chain" end
                    end
                end
            end
            if reason then state.reason[ref] = reason else state.live[ref] = true end
            for _, child in ipairs(Links.childrenOf(ref)) do
                if mine[child.ref] and state.depth[child.ref] == nil then nextLevel[#nextLevel + 1] = child end
            end
        end
        table.sort(nextLevel, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
        level = nextLevel
        depth = depth + 1
    end
    -- Lines of the box reached from no first line (a loop of lines, which laying never makes): cut.
    for _, line in ipairs(lines) do
        if state.depth[line.ref] == nil and not state.reason[line.ref] then state.reason[line.ref] = "cut" end
    end
    -- What hangs below a cut line is cut too (the first lines' reasons spread down above).
    for _, line in ipairs(lines) do
        if state.reason[line.ref] == "cut" and state.depth[line.ref] == nil then
            for _, below in ipairs(Links.branch(line.ref)) do
                if mine[below.ref] then
                    state.live[below.ref] = nil
                    state.reason[below.ref] = state.reason[below.ref] or "cut"
                end
            end
        end
    end
    states[panel.id] = state
    return state
end

-- Whether a ref's line supplies: of the box, and live.
function Links.live(panel, ref)
    local line = Links.get(ref)
    return line ~= nil and line.panel == panel.id and Links.state(panel).live[ref] == true
end

-- Why a ref's line of a box supplies nothing, or nil.
function Links.reason(panel, ref) return Links.state(panel).reason[ref] end

-- The room of a box's zone a square counts as in: the room it is in; else, with no room of its own there, the room
-- the building's shell gives it: right below it (on a roof, a balcony), or beside it on its floor (the ring of squares
-- round the walls: the four sides first, then the corners), the first square of any building's room in that order.
-- As the API counts it (Buildings.shellStep), so that a square against two buildings is one's. Nil when that room is
-- not the zone's.
local SHELL = { { 0, 0, -1 }, { 0, -1, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { -1, 0, 0 }, { 1, -1, 0 }, { 1, 1, 0 },
    { -1, 1, 0 }, { -1, -1, 0 } }
function Links.homeRoom(panel, x, y, z)
    local rooms = Panels.zoneRooms(panel)
    local room = Panels.roomHaving(rooms, x, y, z)
    if room then return room, x, y, z end
    if Panels.buildingAt(x, y, z) then return nil end
    for _, step in ipairs(SHELL) do
        local tx, ty, tz = x + step[1], y + step[2], z + step[3]
        if Panels.buildingAt(tx, ty, tz) then
            room = Panels.roomHaving(rooms, tx, ty, tz)
            if room then return room, tx, ty, tz end
            return nil
        end
    end
    return nil
end

-- Where a thing at a square of a utility could hang on a box: { via (a ref, nil for the wall), wall, length, from
-- ("wall", "relay" or "chain"), x, y, z (the place it hangs on) } for the nearest, or nil and a reason ("tooFar",
-- "relays", "chain", or "needsTier" and the tier whose range reaches). relay: it is a relay itself (it hangs on a wall
-- or a relay only, and needs one of the box's relays free); except: refs it may not hang on (its own branch's). A
-- thing in the zone (Links.homeRoom) hangs on the wall where it is: no line to lay, length 0.
function Links.placeOn(panel, utility, x, y, z, relay, except)
    local state = Links.state(panel)
    if relay and state.relays >= BU.relayLimit(panel.tier) then return nil, "relays" end
    local best, why, needsTier
    local function offer(candidate)
        if not best or candidate.length < best.length
                or candidate.length == best.length and candidate.rank < best.rank then
            best = candidate
        end
    end
    local _, hx, hy, hz = Links.homeRoom(panel, x, y, z)
    if hx then
        return { wall = BU.placeKey(hx, hy, hz), length = 0, from = "wall", rank = 1, x = hx, y = hy, z = hz }
    end
    -- The wall: the nearest square of the zone's rooms (of those as near in steps, the straightest); an outdoor box's
    -- own square.
    local wallLength, wallX, wallY, wallZ, wallStraight
    local rooms = Panels.zoneRooms(panel)
    for _, room in ipairs(rooms) do
        for _, rect in ipairs(room.rects) do
            local cx = math.max(rect.x, math.min(rect.x + rect.w - 1, x))
            local cy = math.max(rect.y, math.min(rect.y + rect.h - 1, y))
            local length = Links.length(x, y, z, cx, cy, room.level)
            local straight = (cx - x) * (cx - x) + (cy - y) * (cy - y)
            if not wallLength or length < wallLength or length == wallLength and straight < wallStraight then
                wallLength, wallX, wallY, wallZ, wallStraight = length, cx, cy, room.level, straight
            end
        end
    end
    if panel.outdoor or #rooms == 0 then
        local length = Links.length(x, y, z, panel.x, panel.y, panel.z)
        if not wallLength or length < wallLength then wallLength, wallX, wallY, wallZ = length, panel.x, panel.y, panel.z end
    end
    if wallLength then
        if wallLength <= BU.connectRange(panel.tier) then
            offer({ wall = BU.placeKey(wallX, wallY, wallZ), length = wallLength, from = "wall", rank = 1, x = wallX,
                y = wallY, z = wallZ })
        else
            local tier = Panels.tierReaching(BU.connectRange, wallLength)
            if tier and tier > (panel.tier or 1) then needsTier = tier end
        end
    end
    -- The box's relays and the devices that carry its lines on: live, of the utility.
    for _, line in ipairs(Links.of(panel)) do
        local ref = line.ref
        if line.utility == utility and state.live[ref] and Links.carries(ref) and not (except and except[ref]) then
            local isRelay = Links.isRelay(ref)
            if isRelay or not relay then
                local length = Links.length(x, y, z, line.x, line.y, line.z)
                if length <= (isRelay and BU.relayRange() or BU.chainRange()) then
                    local head = not isRelay and (state.head[ref] or ref)
                    if head and (state.chained[head] or 0) >= BU.CHAIN_LIMIT then
                        why = "chain"
                    else
                        offer({ via = ref, length = length, from = isRelay and "relay" or "chain",
                            rank = isRelay and 2 or 3, x = line.x, y = line.y, z = line.z })
                    end
                end
            end
        end
    end
    if best then return best end
    if needsTier then return nil, "needsTier", needsTier end
    return nil, why or "tooFar"
end

-- The boxes a thing at a square could hang on, each { panel, place (Links.placeOn's, or nil), reason, tier }: those
-- with a place first, the shortest line first; then those that cannot, with why. Only boxes whose zone, relays or
-- lines are within the longest reach of the top tier.
function Links.offers(utility, x, y, z, relay, except)
    local result = {}
    for _, panel in ipairs(Store.list()) do
        local place, reason, tier = Links.placeOn(panel, utility, x, y, z, relay, except)
        if place or reason == "needsTier" or reason == "relays" or reason == "chain" then
            result[#result + 1] = { panel = panel, place = place, reason = reason, tier = tier }
        end
    end
    table.sort(result, function(a, b)
        if (a.place ~= nil) ~= (b.place ~= nil) then return a.place ~= nil end
        if a.place and b.place and a.place.length ~= b.place.length then return a.place.length < b.place.length end
        return tonumber(a.panel.id:sub(2)) < tonumber(b.panel.id:sub(2))
    end)
    return result
end

-- The first line of a cut branch a ref is in: the line whose own hold is gone (what it hangs on, or its wall), or nil
-- when the ref's line is not cut so.
function Links.cutHead(ref)
    local line = Links.get(ref)
    local seen = {}
    while line and not seen[line.ref or ""] do
        seen[line.ref or ""] = true
        local panel = Store.get(line.panel)
        if not panel then return line end
        if not line.via then return not Links.wallHolds(panel, line.wall) and line or nil end
        local parent = Links.get(line.via)
        if not parent or parent.panel ~= line.panel then return line end
        line = parent
    end
    return nil
end

-- Where a line runs to from its thing: the thing of the line it hangs on, or the face of its wall square toward the
-- thing (a square's x, y and half a square more or less: drawn at +0.5 as a square's centre, it stops at the wall);
-- nil when what it hangs on is gone. x, y, z.
function Links.endOf(line)
    if line.via then
        local parent = Links.get(line.via)
        if parent then return parent.x, parent.y, parent.z end
        return nil
    end
    local wx, wy, wz = BU.parsePlace(line.wall or "")
    if not wx then return nil end
    return math.max(wx - 0.5, math.min(wx + 0.5, line.x)), math.max(wy - 0.5, math.min(wy + 0.5, line.y)), wz
end

-- The first lines of a box's branches that supply nothing, each with the reason what hangs below shares, by when they
-- were laid.
function Links.deadHeads(panel)
    local state, result = Links.state(panel), {}
    for _, line in ipairs(Links.of(panel)) do
        if not state.live[line.ref] then
            local parent = line.via and Links.get(line.via)
            if not parent or parent.panel ~= panel.id or state.live[parent.ref] then result[#result + 1] = line end
        end
    end
    table.sort(result, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
    return result
end

-- Why a ref's line supplies nothing, for the player, or nil while it supplies: where its branch is cut (here, at its
-- own line), or the box's limit it is past.
function Links.reasonText(panel, ref)
    local line = Links.get(ref)
    if not line then return nil end
    local reason = "cut"
    if panel then reason = Links.reason(panel, ref) end
    if not reason then return nil end
    if reason == "relays" then return getText("IGUI_BU_LineCut_relays", BU.relayLimit(panel.tier)) end
    if reason == "chain" then return getText("IGUI_BU_LineCut_chain", BU.CHAIN_LIMIT) end
    if reason == "far" then return getText("IGUI_BU_LineCut_far", BU.connectRange(panel.tier)) end
    local head = Links.cutHead(ref)
    if not head or head == line then return getText("IGUI_BU_LineCut_here") end
    local steps = math.max(math.abs(head.x - line.x), math.abs(head.y - line.y))
    local point = Geometry.direction(line.x, line.y, head.x, head.y)
    return getText("IGUI_BU_LineCut_cut", getText("IGUI_BU_Where", steps, point and getText("IGUI_BU_Dir_" .. point) or ""))
end

return Links
