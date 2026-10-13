-- The mod's rules, as questions: a breaker box per building, or per zone of one (a large building's); producers
-- outside within a range of its outline; the devices of its building (or zone), with those of rooms built onto it,
-- connected unless excluded; devices near it, outside any building, connected only on their own. Nothing here changes
-- anything: BU.Changes does.
require "BuildingUtilities/Networks"
require "BuildingUtilities/Geometry"
require "BuildingUtilities/Switches"
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
local buildingCache, roomsCache, zoneCache = {}, {}, {}
local NO_BUILDING = {}

local function squareKey(x, y, z) return (z * 100000 + y) * 100000 + x end

-- Forgets what was kept when the API's version changed; the API, or nil without it.
local function current()
    local api = BU.api()
    if not api then return nil end
    local version = api.buildings.version()
    if version ~= cacheVersion then
        cacheVersion, buildingCache, roomsCache, zoneCache = version, {}, {}, {}
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

-- A room's square for the saved zones: the north-west one of its own rectangles (the first by y, then by x).
local function roomKey(room, count)
    local best
    for i = 1, count do
        local rect = room.rects[i]
        if not best or rect.y < best.y or rect.y == best.y and rect.x < best.x then best = rect end
    end
    return best and BU.placeKey(best.x, best.y, room.level)
end

-- A building's rooms as plain tables: { id, key, name, level, building (its key), rects = { { x, y, w, h } } }, key
-- the room's square for a saved zone (roomKey). The rooms built onto the
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
            result[#result + 1] = { id = room.id, name = room.name, level = room.level, rects = rects,
                building = building.key }
        end
        for _, room in ipairs(result) do room.key = roomKey(room, #room.rects) end
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
function Panels.forgetRooms() buildingCache, roomsCache, zoneCache = {}, {}, {} end

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

-- The relays whose lines are a box's (units of BU.RELAY_KINDS), supplied or cut.
function Panels.relaysOf(panel)
    local result = {}
    for _, unit in ipairs(Store.unitList(nil, panel.id)) do
        if BU.RELAY_KINDS[unit.kind] then result[#result + 1] = unit end
    end
    return result
end

-- What is worked out of the boxes' buildings and relays, kept while the lines, the boxes and the API's buildings are
-- the same (Store.linkVersion, the API's version).
local claimToken, claimIndex, zoneBuildingsOf, zoneListOf

local function claims()
    current()
    local token = Store.linkVersion() .. "|" .. tostring(cacheVersion)
    if claimToken == token then return claimIndex end
    claimToken, claimIndex, zoneBuildingsOf, zoneListOf = token, {}, {}, {}
    for _, panel in ipairs(Store.list()) do
        local seen, buildings = {}, {}
        local function add(building)
            if building and not seen[building.key] then
                seen[building.key] = true
                buildings[#buildings + 1] = building
                claimIndex[building.key] = claimIndex[building.key] or {}
                table.insert(claimIndex[building.key], panel)
            end
        end
        add(Panels.building(panel))
        for _, relay in ipairs(Panels.relaysOf(panel)) do add(Panels.buildingAt(relay.x, relay.y, relay.z)) end
        zoneBuildingsOf[panel.id] = buildings
    end
    return claimIndex
end

-- The panels whose zone can have rooms of a building, by its key: those in it, and those with a relay in it.
function Panels.ofBuilding(key)
    return claims()[key] or {}
end

-- The buildings a box's zone can have rooms of: its own (none outdoors), then those its relays stand in.
function Panels.zoneBuildings(panel)
    claims()
    return zoneBuildingsOf[panel.id] or {}
end

-- Every room of those buildings, one list (kept as the buildings are).
local function zoneRoomList(panel)
    claims()
    local list = zoneListOf[panel.id]
    if list then return list end
    list = {}
    for _, building in ipairs(Panels.zoneBuildings(panel)) do
        for _, room in ipairs(Panels.rooms(building)) do list[#list + 1] = room end
    end
    zoneListOf[panel.id] = list
    return list
end
Panels.zoneRoomList = zoneRoomList

-- Zones. A box takes its whole building, or only some of its rooms, so that a large building, an apartment block,
-- can have a box per flat or floor. A zone is saved as a square of each room (panel.zone, a set of BU.placeKey: the
-- room's key when it was taken), not as the room's id: the game numbers the rooms of a cell again whenever a player's
-- building there is built, changed or taken down, and a square stays. A room merged with another keeps the zone's
-- square, so the whole is in it; a room split leaves the part with the square in it; a square no longer in a room
-- leaves the zone.
Panels.LARGE_LEVELS, Panels.LARGE_ROOMS = 5, 30

-- The room of a list (Panels.rooms) that has a square, or nil.
function Panels.roomHaving(rooms, x, y, z)
    for _, room in ipairs(rooms) do
        if room.level == z then
            for _, rect in ipairs(room.rects) do
                if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then return room end
            end
        end
    end
    return nil
end

-- The room ids of a box's zone now, a set: each saved square to the room of its buildings that has it now; without a
-- saved zone (panel.zone nil), every room of its own building. Kept with the rooms.
function Panels.zoneIds(panel)
    local zone = panel.zone
    local rooms = zoneRoomList(panel)
    local kept = zoneCache[panel.id]
    if kept and kept.zone == zone and kept.rooms == rooms then return kept.ids end
    local ids = {}
    if zone then
        for key in pairs(zone) do
            local x, y, z = BU.parsePlace(key)
            local room = x and Panels.roomHaving(rooms, x, y, z)
            if room then ids[room.id] = true end
        end
    else
        local own = Panels.building(panel)
        for _, room in ipairs(rooms) do
            if own and room.building == own.key then ids[room.id] = true end
        end
    end
    zoneCache[panel.id] = { zone = zone, rooms = rooms, ids = ids }
    return ids
end

function Panels.inZone(panel, roomId) return Panels.zoneIds(panel)[roomId] == true end

-- The rooms of a box's zone now, as Panels.rooms has them.
function Panels.zoneRooms(panel)
    local ids, result = Panels.zoneIds(panel), {}
    for _, room in ipairs(zoneRoomList(panel)) do
        if ids[room.id] then result[#result + 1] = room end
    end
    return result
end

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

-- The lowest and the highest floor of a box's zone in its own building, or nil for the whole building or when the
-- building is not known now.
function Panels.zoneFloors(panel)
    local building = panel.zone and Panels.building(panel)
    if not building then return nil end
    local ids = Panels.zoneIds(panel)
    local low, high
    for _, room in ipairs(Panels.rooms(building)) do
        if ids[room.id] then low, high = math.min(low or room.level, room.level), math.max(high or room.level, room.level) end
    end
    return low, high
end

-- Whether a box's zone can take rooms of a level of its own building, by its tier.
function Panels.reachesLevel(panel, level)
    local low, high = Panels.floorsReached(panel.z, panel.tier)
    return not low or level >= low and level <= high
end

-- Whether a box's zone can take rooms of a level of a building (by its key): of its own, the floors its tier reaches
-- (Panels.reachesLevel); of any, BU.RELAY_FLOORS above and below a relay of it standing in that building.
function Panels.reaches(panel, key, level)
    local own = Panels.building(panel)
    if own and own.key == key and Panels.reachesLevel(panel, level) then return true end
    for _, relay in ipairs(Panels.relaysOf(panel)) do
        local building = Panels.buildingAt(relay.x, relay.y, relay.z)
        if building and building.key == key and math.abs(relay.z - level) <= BU.RELAY_FLOORS then return true end
    end
    return false
end

-- The rooms a relay put in a building takes into its box's zone as it joins: in a small building, the free rooms of
-- the floors it reaches (BU.RELAY_FLOORS), else the free rooms of its own floor. A set of room keys.
function Panels.relayZone(panel, building, level)
    local rooms = Panels.rooms(building)
    local small, boxes = not Panels.isLarge(rooms), Panels.ofBuilding(building.key)
    local result = {}
    for _, room in ipairs(rooms) do
        local take = small and math.abs(room.level - level) <= BU.RELAY_FLOORS or room.level == level
        if take and not Panels.roomOwner(building.key, room.id, panel, boxes) then result[room.key] = true end
    end
    return result
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
        if take and not Panels.roomOwner(building.key, room.id, nil, boxes) then zone[room.key] = true end
    end
    return zone, small
end

-- Whether a box can take its whole building as its zone: the building's one box (no other box's relay there either),
-- reaching all its floors, with no relay of its own in another building.
function Panels.canTakeWhole(panel, building)
    return building ~= nil and #Panels.ofBuilding(building.key) == 1 and #Panels.zoneBuildings(panel) == 1
        and reachesAll(Panels.rooms(building), panel.z, panel.tier)
end

-- The zone a box keeps within the floors it reaches (Panels.reachesLevel): its rooms on those floors (for the whole
-- building, every room there), or the free rooms of its own level if none is left. Returns the zone and whether it
-- differs; the zone it has when the building is not known now.
function Panels.zoneInReach(panel)
    local building = Panels.building(panel)
    if not panel.zone and (not building or not BU.floorReach(panel.tier)
            or reachesAll(Panels.rooms(building), panel.z, panel.tier)) then
        return nil, false
    end
    local zone, changed, any, kept = {}, panel.zone == nil, false, false
    for _, room in ipairs(zoneRoomList(panel)) do
        if Panels.inZone(panel, room.id) then
            if Panels.reaches(panel, room.building, room.level) then zone[room.key] = true; any = true else changed = true end
        end
    end
    if not changed then return panel.zone, false end
    if not any and building then
        local rooms = Panels.rooms(building)
        local boxes = Panels.ofBuilding(building.key)
        for _, room in ipairs(rooms) do
            if room.level == panel.z and not Panels.roomOwner(building.key, room.id, panel, boxes) then
                zone[room.key], changed, kept = true, true, true
            end
        end
        -- Nothing it can take: its zone stays as it is rather than none (a zone has a room at least).
        if not kept then return panel.zone, false end
    elseif not any then
        return panel.zone, false
    end
    return zone, changed
end

-- Each room (of the box's zone buildings, as Panels.rooms has them) to the plan: "mine", "free", "far" (free, on a
-- floor the box does not reach) or "taken", with the panel that has it.
function Panels.zoneStates(panel, building, rooms)
    local result = {}
    for _, room in ipairs(rooms) do
        if Panels.inZone(panel, room.id) then
            result[room.id] = { state = "mine", owner = panel }
        else
            local owner = Panels.roomOwner(room.building, room.id, panel)
            local state = owner and "taken" or Panels.reaches(panel, room.building, room.level) and "free" or "far"
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

-- Whether a box can go on a square: with a utility on (BU.enabled), in a room no box's zone has (its own, or one its
-- relay took), or outside any building (an outdoor box). Returns the building or true outdoors, or nil and a reason.
function Panels.canInstall(square)
    if not BU.enabled("panel") then return nil, "disabled" end
    if not square then return nil, "noSquare" end
    if not BU.api() then return nil, "noApi" end
    local building = Panels.buildingAt(square:getX(), square:getY(), square:getZ())
    if not building then return true end
    local owner = Panels.roomOwner(building.key, building.roomId)
    if owner then return nil, owner.zone and "roomTaken" or "wholeTaken" end
    return building
end

-- A box item's tier: its type's (BU.PANEL_ITEMS).
function Panels.itemTier(item) return BU.PANEL_ITEM_TIER[item:getFullType()] or 1 end

-- The box's recipe: not known at first (a box is found first), learned by opening one up (ISBUReverseEngineer).
Panels.RECIPE = "MakeBreakerBox"

-- Why a character cannot learn the box's design at one now, or nil: "known" (they know it), "tool" (no screwdriver:
-- Costs.reverseEngineer), "dark" (too dark to see inside, as to read).
function Panels.reverseEngineerProblem(character)
    if character:isRecipeActuallyKnown(Panels.RECIPE) then return "known" end
    if not BU.Costs.affords(character, BU.Costs.reverseEngineer()) then return "tool" end
    if character:tooDarkToRead() then return "dark" end
    return nil
end

-- Whether a box cuts its devices one by one at the box: from BU.CUT_TIER. Below it, everything it reaches is
-- supplied; a device is switched at itself, and one outside taken off by its line.
function Panels.cuts(panel) return (panel.tier or 1) >= BU.CUT_TIER end

-- What a box carries before its breaker trips.
function Panels.capacity(panel) return BU.capacity(panel.tier) end

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
    if tier == BU.CUT_TIER then lines[#lines + 1] = getText("IGUI_BU_CutNote") end
    if power and tier == BU.TIMER_TIER then lines[#lines + 1] = getText("IGUI_BU_TimerNote") end
    if power and BU.enabled("rack") and BU.Energy and tier == BU.Energy.BYPASS_TIER then
        lines[#lines + 1] = getText("IGUI_BU_BypassNote")
    end
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

-- Steps from a square to a box: to the nearest room of its zone, or to the box's own square (outdoors), a diagonal step
-- counting as one.
function Panels.steps(panel, x, y)
    local best = math.max(math.abs(x - panel.x), math.abs(y - panel.y))
    for _, room in ipairs(Panels.zoneRooms(panel)) do
        for _, rect in ipairs(room.rects) do best = math.min(best, Geometry.toRect(x, y, rect)) end
    end
    return best
end

-- The lowest tier whose range (BU.connectRange and the like) reaches so many squares; nil when none does.
function Panels.tierReaching(range, steps)
    for tier = 1, BU.TIERS do
        if steps <= range(tier) then return tier end
    end
    return nil
end

-- What a box could take that has no line, each { x, y, z, sprite } (a generator or water storage) or { x, y, z,
-- unit }: the producers in its building and around it within its connect range (the API's buildings.producers, read in
-- Java; none with an API from before it), and the units, that a line could hang on the box from (BU.Links.placeOn).
-- None while the utility is off.
-- Whether what the API lists as a producer is one a box takes: a generator; for water a storage the game fills
-- (BU.isWaterContainer), not anything that holds a little (a cup left on a sink).
function Panels.storageAt(utility, entry)
    if utility ~= "water" then return true end
    if entry.type == "IsoWorldInventoryObject" then return false end
    local square = getCell():getGridSquare(entry.x, entry.y, entry.z)
    local objects = square and square:getObjects()
    for i = 0, objects and objects:size() - 1 or -1 do
        if BU.isWaterContainer(objects:get(i)) then return true end
    end
    return false
end

function Panels.unwiredProducers(panel, utility)
    local result = {}
    if not BU.enabled(utility) then return result end
    local Links = BU.Links
    local api = BU.api()
    local building = Panels.building(panel)
    local find = api and api.buildings.producers
    if building and find then
        local list = find(building.key, math.min(32, BU.connectRange(panel.tier)), utility)
        for i = 1, list and #list or 0 do
            local entry = list[i]
            if not Links.get(Links.producerRef(entry.x, entry.y, entry.z)) and Panels.storageAt(utility, entry)
                    and Links.placeOn(panel, utility, entry.x, entry.y, entry.z) then
                result[#result + 1] = { x = entry.x, y = entry.y, z = entry.z, sprite = entry.sprite }
            end
        end
    end
    local Units = BU.Units
    for _, unit in ipairs(Store.unitList(nil, nil)) do
        if not Links.get(Links.unitRef(unit)) and Units.utility(unit) == utility and BU.enabled(unit.kind)
                and Units.canConnect(unit, panel) then
            result[#result + 1] = { x = unit.x, y = unit.y, z = unit.z, unit = unit }
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
-- pending (not yet in the networks, BU.Changes.syncAttached); and for power: schedule (BU.SCHEDULES) and
-- held ("timer" while the box keeps it off; "exterior" for one outside while the game
-- keeps generators from powering things outside, BU.exteriorPower; or nil); and for power switchOn, its own switch
-- where it has one and is loaded (BU.Switches: true, false; nil without). A utility that is off (BU.enabled) has
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
    if not api then return result, false end
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
                    group = { keys = keys, entries = {}, inside = inside, built = built, object = object }
                    for _, part in ipairs(keys) do groupOf[part] = group end
                    groupOf[key] = group
                    order[#order + 1] = group
                end
                group.entries[#group.entries + 1] = { entry = entry, key = key }
            end
        end
    end
    local insideComplete, outsideComplete, builtComplete = true, true, true
    -- The rooms of the zone in each building it has rooms of (its own; those its relays stand in).
    for _, each in ipairs(Panels.zoneBuildings(panel)) do
        local inside, complete = api.buildings.objects(each.key, utility)
        insideComplete = insideComplete and complete
        collect(inside, true)
    end
    if building then
        -- The devices of built-on rooms are the API's attachedObjects, each with its space's host as its room. The
        -- API lists them among those outside too: the others are sought within the range of the outline with the
        -- rooms, as far as the rooms reach past the map's rooms the API counts from.
        local reach = BU.connectRange(panel.tier)
        local spaces = Panels.attached(building)
        local extent = 0
        for _, space in ipairs(spaces or {}) do extent = math.max(extent, space.extent) end
        local listed
        listed, outsideComplete = api.buildings.near(building.key, math.min(32, reach + extent), utility)
        local outside, built = listed, nil
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
        collect(built, true, true)
        collect(outside, false)
    end
    -- The devices whose lines are the box's, wherever they are (hung on a relay far off).
    local far = {}
    for key in pairs(data.included) do
        if not groupOf[key] then
            local x, y, z, sprite = BU.parseThing(key)
            if x then far[#far + 1] = { x = x, y = y, z = z, sprite = sprite } end
        end
    end
    table.sort(far, function(a, b) return BU.thingKey(a.x, a.y, a.z, a.sprite) < BU.thingKey(b.x, b.y, b.z, b.sprite) end)
    collect(far, false)
    -- Water: the zone's rooms by id, for each device's room (BU.Water.placeDevice), made once.
    local zoneRoomsById
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
            -- Its line supplies nothing: why (BU.Links).
            if owner == panel and data.included[first.key] then
                local ref = BU.Links.deviceRef(first.key)
                device.cut = BU.Links.reason(panel, ref)
                -- the room or relay it hangs from: it is switched with that room, and listed under it
                device.hangsOn = BU.Links.hangsOn(panel, ref)
            end
        end
        if utility == "water" then
            if not zoneRoomsById then
                zoneRoomsById = {}
                for _, room in ipairs(Panels.zoneRooms(panel)) do zoneRoomsById[room.id] = room end
            end
            BU.Water.placeDevice(panel, device, zoneRoomsById)
        end
        if utility == "power" and group.object then device.switchOn = BU.Switches.state(group.object) end
        if utility == "power" and device.state == "on" then
            device.schedule = data.schedule[device.key] or "always"
            -- held: on at the box, yet given nothing (its line cut, no power outside, its timer).
            device.held = device.cut and "cut" or not device.inside and not BU.exteriorPower() and "exterior"
                or data.timed[device.key] and "timer" or nil
        end
        result[#result + 1] = device
    end
    return result, insideComplete and outsideComplete and builtComplete
end

-- A device outside as one object of a utility at a square (x, y, z, its sprite) is, for one no box lists: { entry,
-- key, keys, inside = false, wired, state } as Panels.devices has them, wired when a box connected it (owner, its
-- box). Nil when no such object is there (its square not loaded).
function Panels.deviceAt(utility, x, y, z, sprite)
    local object = BU.objectsWithSprite(x, y, z, sprite)[1]
    if not object then return nil end
    local keys = BU.partKeys(object)
    table.sort(keys)
    local owner = inclusionOwner(utility, keys)
    return { entry = { x = x, y = y, z = z, sprite = sprite }, key = keys[1] or BU.thingKey(x, y, z, sprite),
        keys = #keys > 0 and keys or { BU.thingKey(x, y, z, sprite) }, inside = false, wired = owner ~= nil,
        state = owner and "other" or "off", owner = owner }
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
-- has charge (Energy.boost). `bank`: the panel's, when the caller has it (else it is looked up).
function Panels.limit(panel, bank)
    local capacity = Panels.capacity(panel)
    if not BU.Energy then return capacity end
    if bank == nil then bank = BU.Energy.bank(panel) end
    return capacity + BU.Energy.boost(panel, bank or nil)
end

-- The breaker holds an overload for a while, as a real one heats: its gauge (1 full, panel.power.breaker) drains at
-- (r - 1)^2 / BREAKER_K an hour, r the load over the limit (105% in two hours, 110% in half an hour, 150% in a little
-- over a minute), and empties at once from BREAKER_INSTANT. Under the limit it fills again in BREAKER_FILL_HOURS.
Panels.BREAKER_K, Panels.BREAKER_INSTANT, Panels.BREAKER_FILL_HOURS = 0.005, 2, 2

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
    local result, seen = {}, {}
    for _, panel in ipairs(building and Panels.ofBuilding(building.key) or {}) do
        seen[panel] = true
        result[#result + 1] = panel
    end
    for _, panel in ipairs(Store.list()) do
        local own = Panels.building(panel)
        local steps = own and Geometry.toBuilding(x, y, Panels.rooms(own))
        if not seen[panel] and steps and steps <= BU.connectRange(panel.tier) then result[#result + 1] = panel end
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

-- A place relative to a panel's building (an outdoor box's square): "12 NE".
function Panels.where(panel, x, y)
    local building = Panels.building(panel)
    local steps, cx, cy
    if building then
        steps = Geometry.toBuilding(x, y, Panels.rooms(building)) or 0
        cx, cy = Geometry.centre(building)
    else
        steps, cx, cy = math.max(math.abs(x - panel.x), math.abs(y - panel.y)), panel.x, panel.y
    end
    local point = Geometry.direction(cx, cy, x, y)
    local side = point and getText("IGUI_BU_Dir_" .. point) or ""
    if steps == 0 then return getText("IGUI_BU_WhereBeside", side) end
    return getText("IGUI_BU_Where", steps, side)
end

return Panels
