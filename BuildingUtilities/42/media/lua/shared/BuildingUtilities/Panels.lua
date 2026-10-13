-- The mod's rules, as questions: a breaker box per building, or per zone of one (a large building's); producers
-- outside within a range of its outline; the devices of its building (or zone), with those of rooms built onto it,
-- connected unless excluded; devices near it, outside any building, connected only on their own; another box as a
-- sub-panel. Nothing here changes anything: BU.Changes does.
require "BuildingUtilities/Networks"
require "BuildingUtilities/Geometry"
local BU = BuildingUtilities
local Store, Networks, Geometry = BU.Store, BU.Networks, BU.Geometry
local Panels = {}
BU.Panels = Panels

Panels.MODDATA = "BuildingUtilitiesPanel"

-- What is kept here of buildings (a square's building, a building's rooms and the rooms built onto it) goes with the
-- API's version of the buildings (buildings.version): the same while no building, nor the game's region data, can have
-- changed. The API changes it as the game swaps in new region data, which is how walls, doors, roofs and player-built
-- buildings come into the map's data. So nothing is kept by time, and nothing is read again while it holds.
local cacheVersion
local buildingCache, roomsCache = {}, {}
local NO_BUILDING = {}

local function squareKey(x, y, z) return (z * 100000 + y) * 100000 + x end

-- Forgets what was kept when the API's version changed; the API, or nil without it.
local function current()
    local api = BU.api()
    if not api then return nil end
    local version = api.buildings.version()
    if version ~= cacheVersion then
        cacheVersion, buildingCache, roomsCache = version, {}, {}
    end
    return api
end

-- The building of a square now, as the API describes it, or nil. A table to read, never to change: it is kept.
function Panels.buildingAt(x, y, z)
    local api = current()
    if not api then return nil end
    local key = squareKey(x, y, z)
    local building = buildingCache[key]
    if building == nil then
        building = api.buildings.at(x, y, z) or NO_BUILDING
        buildingCache[key] = building
    end
    return building ~= NO_BUILDING and building or nil
end

function Panels.building(panel) return Panels.buildingAt(panel.x, panel.y, panel.z) end

-- Rooms built onto a building. In vanilla a room the player builds against a map building belongs to no building: the
-- game drops a player-built building that touches a map one (WorldRegionToMetaGrid), so its squares have no room and
-- the API has no building there. A box takes such a room as part of the building it touches, as one of its rooms: its
-- devices are inside, not outside. The API finds them (buildings.attached): a space is such a room, or rooms joined by
-- doors as the game's regions have them, enclosed and at least half roofed, as a player-built building needs to be,
-- and sharing a side with a room of the building on the same floor. A space is { level, host (the id of the
-- building's room it touches most, which it counts as part of), count (squares), rects (its squares as rectangles)
-- and extent (the larger side of its box) }. Without the game's region data, or where a space grows past a size no
-- room has, none are found (nil) and boxes take such devices as outside, as before.
local attachedFailed = false

local function attachedFor(api, building)
    if building.playerBuilt then return {} end
    local ok, list = pcall(api.buildings.attached, building.key)
    if not ok then
        if not attachedFailed then BU.log("rooms built onto a building cannot be found:", list) end
        attachedFailed = true
        return nil
    end
    if not list then return nil end
    local spaces = {}
    for i = 1, #list do
        local space = list[i]
        local rects = {}
        for j = 1, #space.rects do
            local rect = space.rects[j]
            rects[#rects + 1] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
        end
        spaces[#spaces + 1] = { level = space.level, host = space.host, count = space.count, extent = space.extent,
            rects = rects }
    end
    return spaces
end

-- A building's rooms as plain tables: { id, name, level, rects = { { x, y, w, h } } }. The rooms built onto the
-- building (Panels.attached) are rectangles added to the room each touches most, after the room's own (own: how
-- many), so that the first is always a square of the map's room, and the box's name is still that of the largest room
-- of the map. Kept for the API's version (above): windows, the water layout and each minute's work ask often.
function Panels.rooms(building)
    if not building then return {} end
    local api = current()
    if not api then return {} end
    local cached = roomsCache[building.key]
    if cached then return cached.rooms end
    local list = api.buildings.rooms(building.key)
    local result, spaces = {}, nil
    if list then
        for i = 1, #list do
            local room = list[i]
            local rects = {}
            for j = 1, #room.rects do
                local rect = room.rects[j]
                rects[#rects + 1] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
            end
            result[#result + 1] = { id = room.id, name = room.name, level = room.level, rects = rects }
        end
        spaces = attachedFor(api, building)
        for _, space in ipairs(spaces or {}) do
            for _, room in ipairs(result) do
                if room.id == space.host then
                    room.own = room.own or #room.rects
                    for _, rect in ipairs(space.rects) do
                        room.rects[#room.rects + 1] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
                    end
                end
            end
        end
    end
    roomsCache[building.key] = { rooms = result, spaces = spaces or false }
    return result
end

-- What was kept of the buildings, their rooms and the rooms built onto them, forgotten: looked at again at the next
-- ask (for a check that wants a fresh look whatever the API's version says).
function Panels.forgetRooms() buildingCache, roomsCache = {}, {} end

-- The rooms built onto a building (see above): a list of spaces (none for a building the player built), or nil when
-- they cannot be found now.
function Panels.attached(building)
    if not building then return nil end
    if building.playerBuilt then return {} end
    Panels.rooms(building)
    local cached = roomsCache[building.key]
    return cached and cached.spaces or nil
end

-- The space of a list (Panels.attached) that has a square, or nil.
function Panels.attachedAt(spaces, x, y, z)
    for _, space in ipairs(spaces or {}) do
        if space.level == z then
            for _, rect in ipairs(space.rects) do
                if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then return space end
            end
        end
    end
    return nil
end

-- How many squares the rooms built onto a building have: changes when they do, for what is kept by building.
function Panels.attachedSize(building)
    local count = 0
    for _, space in ipairs(Panels.attached(building) or {}) do count = count + space.count end
    return count
end

-- The panels of a building, by its key.
function Panels.ofBuilding(key)
    local result = {}
    for _, panel in ipairs(Store.list()) do
        local building = Panels.building(panel)
        if building and building.key == key then result[#result + 1] = panel end
    end
    return result
end

-- Zones. A box takes its whole building, or only some of its rooms (panel.rooms, a set of room ids), so that a
-- large building, an apartment block, can have a box per flat or floor.
Panels.LARGE_LEVELS, Panels.LARGE_ROOMS = 5, 30

function Panels.inZone(panel, roomId) return panel.rooms == nil or panel.rooms[roomId] == true end

-- The panel of the building whose zone has the room, other than one; nil when the room is free. boxes, the
-- building's panels (Panels.ofBuilding), saves finding them again for each room.
function Panels.roomOwner(key, roomId, except, boxes)
    for _, panel in ipairs(boxes or Panels.ofBuilding(key)) do
        if panel ~= except and Panels.inZone(panel, roomId) then return panel end
    end
    return nil
end

-- Many floors (more than a house with a cellar and an attic) or many rooms: a box there takes its own floor at
-- first.
function Panels.isLarge(rooms)
    local levels, count = {}, 0
    for _, room in ipairs(rooms) do
        if not levels[room.level] then levels[room.level] = true; count = count + 1 end
    end
    return count >= Panels.LARGE_LEVELS or #rooms > Panels.LARGE_ROOMS
end

-- The floors a box of a tier on a level takes rooms of (BU.floorReach): the lowest and the highest, or nil for all.
function Panels.floorsReached(level, tier)
    local reach = BU.floorReach(tier)
    if not reach then return nil end
    return level - reach, level + reach
end

-- The floors of a building a box reaches, as players see them: the lowest and the highest of its levels the box's
-- zone can take rooms of.
function Panels.floorsInReach(panel, building)
    local low, high = Panels.floorsReached(panel.z, panel.tier)
    return math.max(low or building.minLevel, building.minLevel), math.min(high or building.maxLevel, building.maxLevel)
end

-- The lowest and the highest floor of a box's zone, or nil for the whole building or when the building is not known
-- now.
function Panels.zoneFloors(panel)
    local building = panel.rooms and Panels.building(panel)
    if not building then return nil end
    local low, high
    for _, room in ipairs(Panels.rooms(building)) do
        if panel.rooms[room.id] then low, high = math.min(low or room.level, room.level), math.max(high or room.level, room.level) end
    end
    return low, high
end

-- Whether a box's zone can take rooms of a level.
function Panels.reachesLevel(panel, level)
    local low, high = Panels.floorsReached(panel.z, panel.tier)
    return not low or level >= low and level <= high
end

-- Whether a box on a level, of a tier, reaches every floor of rooms.
local function reachesAll(rooms, level, tier)
    local low, high = Panels.floorsReached(level, tier)
    if not low then return true end
    for _, room in ipairs(rooms) do
        if room.level < low or room.level > high then return false end
    end
    return true
end

-- The zone a new box (tier 1) on a level of a building takes: nil (the whole building) in a small building without
-- boxes whose floors it all reaches, the rooms of the floors it reaches in one it does not (and true for that);
-- else the free rooms of its level.
function Panels.defaultZone(building, level)
    local rooms, boxes = Panels.rooms(building), Panels.ofBuilding(building.key)
    local low, high = Panels.floorsReached(level, 1)
    local small = #boxes == 0 and not Panels.isLarge(rooms)
    if small and reachesAll(rooms, level, 1) then return nil end
    local zone = {}
    for _, room in ipairs(rooms) do
        local take = small and room.level >= low and room.level <= high or room.level == level
        if take and not Panels.roomOwner(building.key, room.id, nil, boxes) then zone[room.id] = true end
    end
    return zone, small
end

-- Whether a box can take its whole building as its zone: the building's one box, reaching all its floors.
function Panels.canTakeWhole(panel, building)
    return building ~= nil and #Panels.ofBuilding(building.key) == 1
        and reachesAll(Panels.rooms(building), panel.z, panel.tier)
end

-- The zone a box keeps within the floors it reaches (Panels.reachesLevel): its rooms on those floors (for the whole
-- building, every room there), or the free rooms of its own level if none is left. Returns the zone and whether it
-- differs; the zone it has when the building is not known now.
function Panels.zoneInReach(panel)
    local building = Panels.building(panel)
    if not building or not BU.floorReach(panel.tier) then return panel.rooms, false end
    local rooms = Panels.rooms(building)
    if not panel.rooms and reachesAll(rooms, panel.z, panel.tier) then return nil, false end
    local zone, changed, any, kept = {}, panel.rooms == nil, false, false
    for _, room in ipairs(rooms) do
        if Panels.inZone(panel, room.id) then
            if Panels.reachesLevel(panel, room.level) then zone[room.id] = true; any = true else changed = true end
        end
    end
    if not any then
        local boxes = Panels.ofBuilding(building.key)
        for _, room in ipairs(rooms) do
            if room.level == panel.z and not Panels.roomOwner(building.key, room.id, panel, boxes) then
                zone[room.id], changed, kept = true, true, true
            end
        end
        -- Nothing it can take: its zone stays as it is rather than none (a zone has a room at least).
        if not kept then return panel.rooms, false end
    end
    return zone, changed
end

-- Each room of the panel's building to the plan: "mine", "free", "far" (free, on a floor the box does not reach) or
-- "taken", with the panel that has it.
function Panels.zoneStates(panel, building, rooms)
    local result = {}
    local boxes = building and Panels.ofBuilding(building.key) or {}
    for _, room in ipairs(rooms) do
        if Panels.inZone(panel, room.id) then
            result[room.id] = { state = "mine", owner = panel }
        else
            local owner = building and Panels.roomOwner(building.key, room.id, panel, boxes)
            local state = owner and "taken" or Panels.reachesLevel(panel, room.level) and "free" or "far"
            result[room.id] = { state = state, owner = owner }
        end
    end
    return result
end

-- The box object of a panel on its loaded square, or nil.
function Panels.object(panel)
    local square = getCell():getGridSquare(panel.x, panel.y, panel.z)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:getModData()[Panels.MODDATA] == panel.id then return object end
    end
    return nil
end

-- The panel a world object is the box of, or nil.
function Panels.ofObject(object)
    local id = object and object:getModData()[Panels.MODDATA]
    return id and Store.get(id) or nil
end

-- Whether a box can go on a square: with a utility on (BU.enabled), inside a building, in a room no other box's zone
-- has. Returns the building, or nil and a reason.
function Panels.canInstall(square)
    if not BU.enabled("panel") then return nil, "disabled" end
    if not square then return nil, "noSquare" end
    if not BU.api() then return nil, "noApi" end
    local building = Panels.buildingAt(square:getX(), square:getY(), square:getZ())
    if not building then return nil, "notInBuilding" end
    local owner = Panels.roomOwner(building.key, building.roomId)
    if owner then return nil, owner.rooms and "roomTaken" or "wholeTaken" end
    return building
end

-- What a box carries before its breaker trips.
function Panels.capacity(panel) return BU.capacity(panel.tier) end

-- The power line into a box: a main panel's from its producer in use (state.producer; else its first; for the
-- units' source, the nearest unit), a sub-panel's from its main panel. The pieces of wire it took and the percent of
-- the load it loses; nil without one.
function Panels.powerLine(panel, state)
    local steps
    if panel.parent then
        local parent = Store.get(panel.parent)
        steps = parent and Panels.linkWire(panel, parent)
    else
        local at = state and state.producer or panel.power.producers[1]
        if at and at.source then steps = BU.Energy.lineSteps(panel)
        elseif at then
            -- The state's producer is the API's: the save's says which sub-panel its line runs through.
            local via
            for _, own in ipairs(panel.power.producers) do
                if own.x == at.x and own.y == at.y and own.z == at.z then via = own.via end
            end
            steps = Panels.routeWire(panel, at.x, at.y, at.z, via)
        else steps = BU.Energy.lineSteps(panel) end
    end
    if not steps then return nil end
    local pieces = BU.Costs.pieces(steps)
    return pieces, pieces * BU.lossPerPiece(panel.tier)
end

-- How far a box of a tier reaches, for the player: devices outside, producers and other boxes alike.
function Panels.rangesText(tier)
    local text = getText("IGUI_BU_Ranges", BU.connectRange(tier))
    local floors = BU.floorReach(tier)
    if floors then text = text .. " " .. getText("IGUI_BU_FloorReach", floors) end
    return text
end

-- What upgrading to a tier gives, one line each: the load it carries, the ranges when they grow, what it can do; only
-- what the features on (BU.enabled) have. Plain lines for a button tooltip, rich text otherwise.
function Panels.upgradeNote(tier, plain)
    local power = BU.enabled("power")
    local lines = {}
    if power then lines[1] = getText("IGUI_BU_UpgradeNote", string.format("%.2f", BU.capacity(tier))) end
    if Panels.rangesText(tier) ~= Panels.rangesText(tier - 1) then
        lines[#lines + 1] = Panels.rangesText(tier)
    end
    if power and BU.lossPerPiece(tier) < BU.lossPerPiece(tier - 1) then
        lines[#lines + 1] = getText("IGUI_BU_LossNote", string.format("%.1f", BU.lossPerPiece(tier)))
    end
    if power and tier == BU.TIMER_TIER then lines[#lines + 1] = getText("IGUI_BU_TimerNote") end
    if tier == BU.LINK_TIER then lines[#lines + 1] = getText("IGUI_BU_LinkNote") end
    if BU.enabled("rack") and tier == BU.BANK_TIER then lines[#lines + 1] = getText("IGUI_BU_BankNote") end
    if BU.enabled("controller") and tier == BU.CONTROLLER_TIER then lines[#lines + 1] = getText("IGUI_BU_ControllerNote") end
    if power and tier == BU.SMART_TIER then lines[#lines + 1] = getText("IGUI_BU_SmartNote") end
    if BU.enabled("controller") and tier == BU.SMART_TIER then lines[#lines + 1] = getText("IGUI_BU_ProtectNote") end
    return table.concat(lines, plain and "\n" or " <LINE> ")
end

-- Producers.

-- How far a generator is heard while it runs, as the game has it: its item's sound radius (20 without one), half
-- that inside a room; and whether it runs now. One not loaded is taken as the plain one (its room is the map's), and
-- as running when its box uses it.
local NOISE_RADIUS = 20
function Panels.generatorNoise(x, y, z, inUse)
    local square = getCell():getGridSquare(x, y, z)
    local generator = square and square:getGenerator()
    local radius, inside, running = NOISE_RADIUS, false, inUse == true
    if generator then
        local item = ScriptManager.instance:getItem(generator:getGeneratorItemType())
        if item and item:getSoundRadius() > 0 then radius = item:getSoundRadius() end
        inside, running = square:getRoom() ~= nil, generator:isActivated()
    else
        inside = getWorld():getMetaGrid():getRoomAt(x, y, z) ~= nil
    end
    if inside then radius = math.floor(radius / 2) end
    return radius, running
end

-- What a square can produce: "power" for a generator, "water" for a water container, while that utility is on
-- (BU.enabled); with the object.
function Panels.producerOn(square)
    if not square then return nil end
    local generator = BU.enabled("power") and square:getGenerator()
    if generator then return "power", generator end
    if not BU.enabled("water") then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if BU.isWaterContainer(object) then return "water", object end
    end
    return nil
end

-- Steps from a square to a panel's building outline, or nil when the building is not known now.
function Panels.steps(panel, x, y)
    local building = Panels.building(panel)
    return building and Geometry.toBuilding(x, y, Panels.rooms(building)) or nil
end

-- The length of a line from a square to a panel's box: the steps to its building's outline, and BU.tilesPerFloor a
-- floor up or down; nil when the building is not known now.
function Panels.wire(panel, x, y, z)
    local steps = Panels.steps(panel, x, y)
    return steps and steps + math.abs((z or panel.z) - panel.z) * BU.tilesPerFloor() or nil
end

-- The main panel a panel takes its supply from at last, up its links: itself for a main panel.
function Panels.root(panel)
    local seen = {}
    while panel.parent and not seen[panel.id] do
        seen[panel.id] = true
        local parent = Store.get(panel.parent)
        if not parent then break end
        panel = parent
    end
    return panel
end

-- Whether the panel named by an id is a panel, or one of its sub-panels at any depth.
function Panels.passesThrough(id, panel)
    local at, seen = Store.get(id), {}
    while at and not seen[at.id] do
        if at == panel then return true end
        seen[at.id] = true
        at = Store.get(at.parent)
    end
    return false
end

-- The length of the links from a panel up to its main panel (Panels.linkWire each): 0 for a main panel, nil when a
-- building on the way is not known now.
function Panels.feedWire(panel)
    local total, seen = 0, {}
    while panel.parent and not seen[panel.id] do
        seen[panel.id] = true
        local parent = Store.get(panel.parent)
        if not parent then break end
        local wire = Panels.linkWire(panel, parent)
        if not wire then return nil end
        total, panel = total + wire, parent
    end
    return total
end

-- The length of a producer's or a unit's line into its main panel: through the sub-panel it is wired to (via, its
-- id) and up that one's links, or straight to the box.
function Panels.routeWire(panel, x, y, z, via)
    local through = via and Store.get(via)
    if through and through ~= panel and Panels.root(through) == panel then
        local wire, feed = Panels.wire(through, x, y, z), Panels.feedWire(through)
        return wire and feed and wire + feed or nil
    end
    return Panels.wire(panel, x, y, z)
end

-- The lowest tier whose range (BU.connectRange and the like) reaches so many squares; nil when none does.
function Panels.tierReaching(range, steps)
    for tier = 1, BU.TIERS do
        if steps <= range(tier) then return tier end
    end
    return nil
end

-- The panels a producer square could be connected to: on a level of their building or on the ground, within the
-- connect range of the top tier from its outline on the square's own level, as a device outside is reached (the whole
-- outline where that level has no rooms, as on a roof). Each with its distance, its line's length (Panels.wire) and
-- the tier that reaches it; the shortest line first. A sub-panel takes the line on to its main panel (Panels.root),
-- whose producer it is: a producer near a sub-panel, up a tall building or by another building, needs no line of its
-- own all the way to the main box.
function Panels.producerCandidates(x, y, z)
    local result = {}
    for _, panel in ipairs(Store.list()) do
        local building = Panels.building(panel)
        if building and (z == 0 or z >= building.minLevel and z <= building.maxLevel) then
            local rooms = Panels.rooms(building)
            local steps = Geometry.toLevel(x, y, z, rooms) or Geometry.toBuilding(x, y, rooms)
            local tier = steps and Panels.tierReaching(BU.connectRange, steps)
            if tier then
                result[#result + 1] = { panel = panel, steps = steps, building = building, tier = tier,
                    inRange = tier <= (panel.tier or 1), wire = steps + math.abs(z - panel.z) * BU.tilesPerFloor() }
            end
        end
    end
    table.sort(result, function(a, b)
        if a.wire ~= b.wire then return a.wire < b.wire end
        return a.steps < b.steps
    end)
    return result
end

-- Of those, the ones whose own tier reaches the square.
function Panels.inProducerRange(x, y, z)
    local result = {}
    for _, candidate in ipairs(Panels.producerCandidates(x, y, z)) do
        if candidate.inRange then result[#result + 1] = candidate end
    end
    return result
end

-- Whether a producer can be connected to a panel. True, or false and a reason.
function Panels.canConnectProducer(panel, utility, x, y, z)
    if not BU.enabled(utility) then return false, "disabled" end
    if Store.producerOwner(x, y, z) then return false, "connectedElsewhere" end
    local square = getCell():getGridSquare(x, y, z)
    if square and Panels.producerOn(square) ~= utility then return false, "noProducer" end
    for _, candidate in ipairs(Panels.inProducerRange(x, y, z)) do
        if candidate.panel == panel then return true end
    end
    return false, "tooFar"
end

-- What a main box could take that no box has, each { x, y, z, sprite } (a generator or water storage) or { x, y, z,
-- unit }: the producers in its building and around it within its connect range (the API's buildings.producers, read in
-- Java; none with an API from before it) that Panels.canConnectProducer allows, and the units no box has that this box
-- reaches. None for a sub-panel (what is near it goes to its main box) or while the utility is off.
function Panels.unwiredProducers(panel, utility)
    local result = {}
    if panel.parent or not BU.enabled(utility) then return result end
    local api = BU.api()
    local building = Panels.building(panel)
    local find = api and api.buildings.producers
    if building and find then
        local list = find(building.key, math.min(32, BU.connectRange(panel.tier)), utility)
        for i = 1, list and #list or 0 do
            local entry = list[i]
            if Panels.canConnectProducer(panel, utility, entry.x, entry.y, entry.z) then
                result[#result + 1] = { x = entry.x, y = entry.y, z = entry.z, sprite = entry.sprite }
            end
        end
    end
    local Units = BU.Units
    for _, unit in ipairs(Store.unitList(nil, nil)) do
        if not unit.panel and Units.utility(unit) == utility and BU.enabled(unit.kind) then
            for _, candidate in ipairs(Panels.inProducerRange(unit.x, unit.y, unit.z)) do
                if candidate.panel == panel then
                    result[#result + 1] = { x = unit.x, y = unit.y, z = unit.z, unit = unit }
                    break
                end
            end
        end
    end
    return result
end

-- Devices.

-- The devices of a panel for one utility: those of its building, with those in rooms built onto it (Panels.attached),
-- and those near it outside any building (connected only when this panel added them; "other" when another panel
-- did). A device in a built-on room is inside, in the room it touches: connected unless excluded, with no line. One
-- that another panel took, or that this panel connected outside before the room was built, stays outside. An object
-- that covers several squares is one device, as the API switches it whole: its entry is that of its listed part with
-- the smallest key, which is its key; keys are all its parts'; power is what its parts draw together. Each has entry,
-- key, keys, power, inside and state ("on", "off" or "other": the player's choice); attached (in a built-on room) and
-- pending (not yet in the networks, BU.Changes.syncAttached); and for power: essential, schedule (BU.SCHEDULES) and
-- held ("shed", "saving" or "timer" while the box keeps it off; "exterior" for one outside while the game
-- keeps generators from powering things outside, BU.exteriorPower; or nil). A utility that is off (BU.enabled) has
-- none.
local function anyKey(set, keys)
    for _, key in ipairs(keys) do
        if set[key] then return set[key] end
    end
    return nil
end

local function inclusionOwner(utility, keys)
    for _, key in ipairs(keys) do
        local owner = Store.inclusionOwner(utility, key)
        if owner then return owner end
    end
    return nil
end

-- Whether a device in a built-on room is another panel's, or was connected outside by any panel.
local function claimedElsewhere(panel, utility, keys)
    for _, key in ipairs(keys) do
        if Store.includedOwner(utility, key) or Store.attachedOwner(utility, key, panel) then return true end
    end
    return false
end

function Panels.devices(panel, utility)
    local api = BU.api()
    local building = Panels.building(panel)
    local result = {}
    if not BU.enabled(utility) then return result, true end
    if not api or not building then return result, false end
    local data = panel[utility]
    -- The listed parts by object: each part's key leads to its object's group.
    local groups, order, groupOf = {}, {}, {}
    local function collect(list, inside, built)
        for i = 1, list and #list or 0 do
            local entry = list[i]
            -- Of the building, only the rooms of the panel's zone.
            if not inside or Panels.inZone(panel, entry.roomId) then
                local key = BU.thingKey(entry.x, entry.y, entry.z, entry.sprite)
                local group = groupOf[key]
                if not group then
                    local object = BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)[1]
                    local keys = object and BU.partKeys(object) or { key }
                    group = { keys = keys, entries = {}, inside = inside, built = built }
                    for _, part in ipairs(keys) do groupOf[part] = group end
                    groupOf[key] = group
                    order[#order + 1] = group
                end
                group.entries[#group.entries + 1] = { entry = entry, key = key }
            end
        end
    end
    local inside, insideComplete = api.buildings.objects(building.key, utility)
    -- The devices of built-on rooms are the API's attachedObjects, each with its space's host as its room. The API
    -- lists them among those outside too: the others are sought within the range of the outline with the rooms, as far
    -- as the rooms reach past the map's rooms the API counts from.
    local reach = BU.connectRange(panel.tier)
    local spaces = Panels.attached(building)
    local extent = 0
    for _, space in ipairs(spaces or {}) do extent = math.max(extent, space.extent) end
    local listed, outsideComplete = api.buildings.near(building.key, math.min(32, reach + extent), utility)
    local outside, built, builtComplete = listed, nil, true
    if extent > 0 then
        built, builtComplete = api.buildings.attachedObjects(building.key, utility)
        if listed then
            local rooms = Panels.rooms(building)
            outside = {}
            for i = 1, #listed do
                local entry = listed[i]
                if not Panels.attachedAt(spaces, entry.x, entry.y, entry.z) then
                    local steps = Geometry.toLevel(entry.x, entry.y, entry.z, rooms)
                    if steps and steps <= reach then outside[#outside + 1] = entry end
                end
            end
        end
    end
    collect(inside, true)
    collect(built, true, true)
    collect(outside, false)
    for _, group in ipairs(order) do
        if group.built and claimedElsewhere(panel, utility, group.keys) then group.inside = false end
        table.sort(group.entries, function(a, b) return a.key < b.key end)
        local first = group.entries[1]
        local power
        for _, part in ipairs(group.entries) do
            if part.entry.power then power = (power or 0) + part.entry.power end
        end
        local device = { entry = first.entry, key = first.key, keys = group.keys, power = power, inside = group.inside,
            roomId = group.inside and (first.entry.roomId or "") or nil }
        if group.built and group.inside then
            device.attached = true
            device.pending = not (data.attached and data.attached[first.key])
        end
        -- wired: the box reaches it (one of the building always, one outside by its line); its state is whether the
        -- box supplies it ("on", "off"), or "other" when another box's line is laid to it
        if group.inside then
            device.wired = true
            device.state = anyKey(data.excluded, group.keys) and "off" or "on"
        else
            local owner = inclusionOwner(utility, group.keys)
            device.wired = owner == panel
            if owner == panel then device.state = anyKey(data.excluded, group.keys) and "off" or "on"
            else device.state = owner and "other" or "off" end
        end
        if utility == "water" then device.group = BU.Water.deviceGroup(panel, group.keys) end
        if utility == "power" and device.state == "on" then
            device.essential = data.essential[device.key] == true
            device.schedule = data.schedule[device.key] or "always"
            device.held = not device.inside and not BU.exteriorPower() and "exterior" or data.shed[device.key] and "shed"
                or data.saving[device.key] and "saving"
                or data.timed[device.key] and "timer" or nil
        end
        result[#result + 1] = device
    end
    return result, insideComplete and outsideComplete and builtComplete
end

-- The keys of a panel's devices of a utility in the rooms built onto its building (those Panels.devices marks
-- attached), from those rooms' objects alone (buildings.attachedObjects), without reading the whole building and its
-- surroundings as Panels.devices does: asked each minute (BU.Changes.syncAttached). Nil when an object there has a
-- part the rooms' objects do not list (on another square, or that uses no such utility): Panels.devices tells then.
function Panels.attachedKeys(panel, utility, building)
    local api = BU.api()
    local entries = api and building and api.buildings.attachedObjects(building.key, utility)
    if not entries then return nil end
    local listed = {}
    for i = 1, #entries do
        local entry = entries[i]
        listed[BU.thingKey(entry.x, entry.y, entry.z, entry.sprite)] = true
    end
    local groups, groupOf = {}, {}
    for i = 1, #entries do
        local entry = entries[i]
        if Panels.inZone(panel, entry.roomId) then
            local key = BU.thingKey(entry.x, entry.y, entry.z, entry.sprite)
            local group = groupOf[key]
            if not group then
                local object = BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)[1]
                local keys = object and BU.partKeys(object) or { key }
                for _, part in ipairs(keys) do
                    if not listed[part] then return nil end
                end
                group = { keys = keys, key = key }
                for _, part in ipairs(keys) do groupOf[part] = group end
                groupOf[key] = group
                groups[#groups + 1] = group
            elseif key < group.key then
                group.key = key
            end
        end
    end
    local result = {}
    for _, group in ipairs(groups) do
        if not claimedElsewhere(panel, utility, group.keys) then result[group.key] = true end
    end
    return result
end

-- Overload.

-- What a box carries before it overloads: its own share (Panels.capacity) and what its bank's batteries add while it
-- has charge (Energy.boost; a main panel's). `bank`: the panel's, when the caller has it (else it is looked up).
function Panels.limit(panel, bank)
    local capacity = Panels.capacity(panel)
    if panel.parent or not BU.Energy then return capacity end
    if bank == nil then bank = BU.Energy.bank(panel) end
    return capacity + BU.Energy.boost(panel, bank or nil)
end

-- The breaker holds an overload for a while, as a real one heats: its gauge (1 full, panel.power.breaker) drains at
-- (r - 1)^2 / BREAKER_K an hour, r the load over the limit (105% in two hours, 110% in half an hour, 150% in a little
-- over a minute), and empties at once from BREAKER_INSTANT. Under the limit it fills again in BREAKER_FILL_HOURS. A
-- box that sheds turns devices off as the gauge reaches BREAKER_SHED_AT, and on again once it is back to
-- BREAKER_RESTORE_AT.
Panels.BREAKER_K, Panels.BREAKER_INSTANT, Panels.BREAKER_FILL_HOURS = 0.005, 2, 2
Panels.BREAKER_SHED_AT, Panels.BREAKER_RESTORE_AT = 0.5, 0.9

-- Whether the box's lever is up: its breaker holds and its main switch is on (Changes.setLever).
function Panels.leverUp(panel) return not (panel.tripped or panel.switchedOff) end

-- The breaker's gauge now (1 full).
function Panels.breaker(panel) return panel.power.breaker or 1 end

-- What the gauge loses an hour at a load so many times the limit (0 at or under it; math.huge from INSTANT).
function Panels.breakerDrain(ratio)
    if ratio <= 1 then return 0 end
    if ratio >= Panels.BREAKER_INSTANT then return math.huge end
    return (ratio - 1) * (ratio - 1) / Panels.BREAKER_K
end

-- The game hours the gauge lasts at that ratio from where it is, down to `to` (0: the trip); nil when it does not drain.
function Panels.breakerHoursLeft(gauge, ratio, to)
    local drain = Panels.breakerDrain(ratio)
    if drain <= 0 then return nil end
    return math.max(0, gauge - (to or 0)) / drain
end

-- Whether a box sheds devices under overload before its breaker trips.
function Panels.sheds(panel) return BU.overloadEnabled() and (panel.tier or 1) >= BU.SMART_TIER end

-- Which devices a box sheds to draw less by at least excess: connected and on, not essential, the largest first, so
-- that few go off. Nil when shedding all it may does not do; else their keys, and what each draws by key.
function Panels.shedPlan(panel, excess)
    local candidates = {}
    for _, device in ipairs(Panels.devices(panel, "power")) do
        local power = device.power or 0
        if device.state == "on" and not device.held and not device.essential and power > 0 then
            candidates[#candidates + 1] = { key = device.key, power = power }
        end
    end
    table.sort(candidates, function(a, b) return a.power > b.power end)
    local keys, powers, total = {}, {}, 0
    for _, candidate in ipairs(candidates) do
        if total >= excess - 1e-6 then break end
        keys[#keys + 1] = candidate.key
        powers[candidate.key] = candidate.power
        total = total + candidate.power
    end
    if total < excess - 1e-6 then return nil end
    return keys, powers
end

-- Which shed devices fit again within room: the smallest first, by what each drew as it was shed (BU.Changes.shed).
-- A device shed by an older version, kept without it, has the building's devices looked at.
function Panels.restorePlan(panel, room)
    local candidates = {}
    for key, power in pairs(panel.power.shed) do
        if type(power) ~= "number" then candidates = nil; break end
        candidates[#candidates + 1] = { key = key, power = power }
    end
    if not candidates then
        candidates = {}
        for _, device in ipairs(Panels.devices(panel, "power")) do
            if device.held == "shed" then candidates[#candidates + 1] = { key = device.key, power = device.power or 0 } end
        end
    end
    table.sort(candidates, function(a, b) return a.power < b.power end)
    local keys, total = {}, 0
    for _, candidate in ipairs(candidates) do
        if total + candidate.power > room + 1e-6 then break end
        keys[#keys + 1] = candidate.key
        total = total + candidate.power
    end
    return keys
end

-- One device of a panel by the key of any of its parts, or nil.
function Panels.device(panel, utility, key)
    for _, device in ipairs(Panels.devices(panel, utility)) do
        for _, part in ipairs(device.keys) do
            if part == key then return device end
        end
    end
    return nil
end

-- The panels a square can be a device of: those of its building, and those whose outside range reaches it. The
-- steps are to the building's rooms on any level, never more than buildings.near counts on the square's own, so
-- none that has it is left out; a square far from every box asks the API for no devices.
local function devicePanels(x, y, z)
    local building = Panels.buildingAt(x, y, z)
    local result = {}
    for _, panel in ipairs(Store.list()) do
        local own = Panels.building(panel)
        local steps = own and Geometry.toBuilding(x, y, Panels.rooms(own))
        if own and (building and own.key == building.key or steps and steps <= BU.connectRange(panel.tier)) then
            result[#result + 1] = panel
        end
    end
    return result
end

-- A panel's devices of a utility by the key of each of their parts.
local function devicesByKey(panel, utility)
    local result = {}
    for _, device in ipairs(Panels.devices(panel, utility)) do
        for _, part in ipairs(device.keys) do result[part] = device end
    end
    return result
end

-- The panel and device entry for a world object, for the context menu: the panel of its building, or a panel in
-- whose outside range it stands. Nil when it is no device of a panel. cache, a table kept for one menu, saves
-- finding the panels near a square and their devices again for each object and utility.
function Panels.deviceOf(object, utility, cache)
    local square = object:getSquare()
    if not square then return nil end
    local sprite = BU.objectName(object)
    if not sprite then return nil end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local key = BU.thingKey(x, y, z, sprite)
    cache = cache or {}
    cache.near, cache.devices = cache.near or {}, cache.devices or {}
    local at = x .. "," .. y .. "," .. z
    cache.near[at] = cache.near[at] or devicePanels(x, y, z)
    for _, panel in ipairs(cache.near[at]) do
        local slot = panel.id .. "|" .. utility
        cache.devices[slot] = cache.devices[slot] or devicesByKey(panel, utility)
        local device = cache.devices[slot][key]
        if device then return panel, device end
    end
    return nil
end

-- For a device that uses both power and water and is connected for one utility: the other when the panel lacks it
-- there (its supply cut, no line outside, or its network, otherState, without supply), else nil; nil too while the
-- other is off (BU.enabled).
function Panels.missingOther(panel, utility, device, otherState)
    local entry = device.entry
    if not (entry.power and entry.water) then return nil end
    local other = utility == "power" and "water" or "power"
    if not BU.enabled(other) then return nil end
    local excluded, included = false, false
    for _, key in ipairs(device.keys) do
        excluded = excluded or panel[other].excluded[key] ~= nil
        included = included or not device.inside and panel[other].included[key] ~= nil
    end
    if excluded or (not device.inside and not included) or not (otherState and otherState.supplied) then return other end
    return nil
end

-- Sub-panels.

-- Steps between two panels' buildings, or nil when one is not known now.
function Panels.linkSteps(child, parent)
    local childBuilding, parentBuilding = Panels.building(child), Panels.building(parent)
    if not childBuilding or not parentBuilding then return nil end
    if childBuilding.key == parentBuilding.key then return 0 end
    return Geometry.betweenBuildings(Panels.rooms(childBuilding), Panels.rooms(parentBuilding))
end

-- The length of the line between two panels: the steps between their buildings, and BU.tilesPerFloor a floor up or
-- down between their boxes (a sub-panel on another floor of the same building); nil when one is not known now.
function Panels.linkWire(child, parent)
    local steps = Panels.linkSteps(child, parent)
    return steps and steps + math.abs(child.z - parent.z) * BU.tilesPerFloor() or nil
end

-- Whether a panel can take its supply from another: a main panel in another building or another zone of its own,
-- of a tier that gives supply (BU.LINK_TIER) and whose connect range reaches its own building, with no producers
-- or units of its own, and not one of its own sub-panels. Returns true, or false and a reason; for "lowTier" also the distance and the tier needed.
function Panels.canLink(child, parent)
    if child == parent then return false, "self" end
    if child.parent then return false, "isSubPanel" end
    for _, utility in ipairs(BU.UTILITIES) do
        if #child[utility].producers > 0 then return false, "hasProducers" end
    end
    if #Store.unitList(nil, child.id) > 0 then return false, "hasProducers" end
    local above = parent
    while above do
        if above == child then return false, "cycle" end
        above = Store.get(above.parent)
    end
    local steps = Panels.linkSteps(child, parent)
    if not steps then return false, "noBuilding" end
    local tier = Panels.tierReaching(BU.connectRange, steps)
    if not tier then return false, "tooFar" end
    tier = math.max(tier, BU.LINK_TIER)
    if (parent.tier or 1) < tier then return false, "lowTier", steps, tier end
    return true
end

-- The panels a panel could take its supply from, nearest first, with their distances and their lines' lengths
-- (Panels.linkWire): those it can now, and those it could once they are of a higher tier (with the tier needed), for
-- the player to see what an upgrade gives.
function Panels.linkCandidates(child)
    local result = {}
    for _, panel in ipairs(Store.list()) do
        if panel ~= child then
            local ok, reason, steps, tier = Panels.canLink(child, panel)
            if ok then
                result[#result + 1] = { panel = panel, steps = Panels.linkSteps(child, panel), wire = Panels.linkWire(child, panel) }
            elseif reason == "lowTier" then
                result[#result + 1] = { panel = panel, steps = steps, wire = Panels.linkWire(child, panel), tier = tier }
            end
        end
    end
    -- The shortest line first: in one building the steps are none, the floors tell.
    table.sort(result, function(a, b)
        if (a.wire or a.steps) ~= (b.wire or b.steps) then return (a.wire or a.steps) < (b.wire or b.steps) end
        return a.steps < b.steps
    end)
    return result
end

-- Names.

-- What players call each room of a building, by id: its name, and where names repeat its floor, its side of the
-- building and at last a number. "Hall (2F, N)".
function Panels.roomTitles(building)
    local rooms = Panels.rooms(building)
    local byName = {}
    for _, room in ipairs(rooms) do
        local name = room.name or ""
        byName[name] = byName[name] or {}
        table.insert(byName[name], room)
    end
    local cx, cy
    if building then cx, cy = Geometry.centre(building) end
    local titles = {}
    for name, same in pairs(byName) do
        local base = name == "" and getText("IGUI_BU_NoRoom") or BU.roomName(name)
        if #same == 1 then
            titles[same[1].id] = base
        else
            local levels = {}
            for _, room in ipairs(same) do levels[room.level] = true end
            local manyLevels = false
            for level in pairs(levels) do if level ~= same[1].level then manyLevels = true end end
            local seen = {}
            for _, room in ipairs(same) do
                local parts = {}
                if manyLevels then parts[#parts + 1] = BU.floorName(room.level) end
                local rx, ry, area = 0, 0, 0
                for _, rect in ipairs(room.rects) do
                    local size = rect.w * rect.h
                    rx, ry, area = rx + (rect.x + rect.w / 2) * size, ry + (rect.y + rect.h / 2) * size, area + size
                end
                local point = area > 0 and cx and Geometry.direction(cx, cy, rx / area, ry / area)
                if point then parts[#parts + 1] = getText("IGUI_BU_Dir_" .. point) end
                local qualifier = table.concat(parts, ", ")
                seen[qualifier] = (seen[qualifier] or 0) + 1
                if seen[qualifier] > 1 then qualifier = (qualifier ~= "" and qualifier .. " " or "") .. seen[qualifier] end
                titles[room.id] = qualifier ~= "" and getText("IGUI_BU_RoomQualified", base, qualifier) or base
            end
        end
    end
    return titles
end

-- The panel's name: the player's, or its building's largest room and a number among panels of the same name.
function Panels.name(panel)
    if panel.name and panel.name ~= "" then return panel.name end
    local base = Panels.autoName(panel)
    local count = 0
    for _, other in ipairs(Store.list()) do
        if not (other.name and other.name ~= "") and Panels.autoName(other) == base then
            count = count + 1
            if other == panel then break end
        end
    end
    return count > 1 and (base .. " " .. count) or base
end

-- Kept by panel for the API's version of the buildings (as Panels.rooms) and the box's square: the tooltip over a box
-- and the windows ask for names often, and each name asks for every unnamed panel's building and rooms.
local autoNames = {}
function Panels.autoName(panel)
    local api = BU.api()
    local version = api and api.buildings.version()
    local cached = autoNames[panel.id]
    if cached and version ~= nil and cached.version == version and cached.x == panel.x and cached.y == panel.y
            and cached.z == panel.z then
        return cached.name
    end
    local building = Panels.building(panel)
    local best, area = nil, 0
    for _, room in ipairs(Panels.rooms(building)) do
        local size = 0
        for index = 1, room.own or #room.rects do
            local rect = room.rects[index]
            size = size + rect.w * rect.h
        end
        if room.name and room.name ~= "" and size > area then best, area = room.name, size end
    end
    local name = best and getText("IGUI_BU_PanelOf", BU.roomName(best)) or getText("IGUI_BU_PanelDefault")
    autoNames[panel.id] = { version = version, x = panel.x, y = panel.y, z = panel.z, name = name }
    return name
end

-- A place relative to a panel's building: "12 NE".
function Panels.where(panel, x, y)
    local building = Panels.building(panel)
    if not building then return "" end
    local steps = Geometry.toBuilding(x, y, Panels.rooms(building)) or 0
    local cx, cy = Geometry.centre(building)
    local point = Geometry.direction(cx, cy, x, y)
    return getText("IGUI_BU_Where", steps, point and getText("IGUI_BU_Dir_" .. point) or "")
end

return Panels
