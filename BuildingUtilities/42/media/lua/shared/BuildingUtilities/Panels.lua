-- The mod's rules, as questions: a breaker box per building, or per zone of one (a large building's); producers
-- outside within a range of its outline; the devices of its building (or zone) connected unless excluded; devices
-- near it, outside any building, connected only on their own; another box as a sub-panel. Nothing here changes anything: BU.Changes does.
require "BuildingUtilities/Networks"
require "BuildingUtilities/Geometry"
local BU = BuildingUtilities
local Store, Networks, Geometry = BU.Store, BU.Networks, BU.Geometry
local Panels = {}
BU.Panels = Panels

Panels.MODDATA = "BuildingUtilitiesPanel"

-- The building of a square now, as the API describes it, or nil.
function Panels.buildingAt(x, y, z)
    local api = BU.api()
    return api and api.buildings.at(x, y, z) or nil
end

function Panels.building(panel) return Panels.buildingAt(panel.x, panel.y, panel.z) end

-- A building's rooms as plain tables: { id, name, level, rects = { { x, y, w, h } } }, kept a second: windows and the
-- water layout ask for them often.
local roomsCache = {}
function Panels.rooms(building)
    if not building then return {} end
    local cached = roomsCache[building.key]
    local now = getTimestampMs()
    if cached and now - cached.at < 1000 then return cached.rooms end
    local api = BU.api()
    local list = api and building and api.buildings.rooms(building.key)
    local result = {}
    if not list then return result end
    for i = 1, #list do
        local room = list[i]
        local rects = {}
        for j = 1, #room.rects do
            local rect = room.rects[j]
            rects[#rects + 1] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
        end
        result[#result + 1] = { id = room.id, name = room.name, level = room.level, rects = rects }
    end
    roomsCache[building.key] = { at = now, rooms = result }
    return result
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
    local zone, changed, any = {}, panel.rooms == nil, false
    for _, room in ipairs(rooms) do
        if Panels.inZone(panel, room.id) then
            if Panels.reachesLevel(panel, room.level) then zone[room.id] = true; any = true else changed = true end
        end
    end
    if not any then
        local boxes = Panels.ofBuilding(building.key)
        for _, room in ipairs(rooms) do
            if room.level == panel.z and not Panels.roomOwner(building.key, room.id, panel, boxes) then
                zone[room.id], changed = true, true
            end
        end
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
-- units' source, the nearest unit), a sub-panel's from its main panel. The pieces of wire it took and the percent of the load it loses; nil without one.
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

-- How far a box of a tier reaches, for the player: producers, outside devices, sub-panels.
function Panels.rangesText(tier)
    local text = getText("IGUI_BU_Ranges", BU.producerRange(tier), BU.exteriorRange(tier), BU.subPanelRange(tier))
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

-- The lowest tier whose range (BU.producerRange and the like) reaches so many squares; nil when none does.
function Panels.tierReaching(range, steps)
    for tier = 1, BU.TIERS do
        if steps <= range(tier) then return tier end
    end
    return nil
end

-- The panels a producer square could be connected to: on a level of their building or on the ground, within the
-- producer range of the top tier from its outline. Each with its distance, its line's length (Panels.wire) and the
-- tier that reaches it; the shortest line first. A sub-panel takes the line on to its main panel (Panels.root), whose producer it is: a producer near a
-- sub-panel, up a tall building or by another building, needs no line of its own all the way to the main box.
function Panels.producerCandidates(x, y, z)
    local result = {}
    for _, panel in ipairs(Store.list()) do
        local building = Panels.building(panel)
        if building and (z == 0 or z >= building.minLevel and z <= building.maxLevel) then
            local steps = Geometry.toBuilding(x, y, Panels.rooms(building))
            local tier = steps and Panels.tierReaching(BU.producerRange, steps)
            if tier then
                result[#result + 1] = { panel = panel, steps = steps, building = building, tier = tier,
                    inRange = tier <= (panel.tier or 1), wire = Panels.wire(panel, x, y, z) or steps }
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

-- Devices.

-- The devices of a panel for one utility: those of its building (connected unless excluded) and those near it
-- outside any building (connected only when this panel added them; "other" when another panel did). An object that
-- covers several squares is one device, as the API switches it whole: its entry is that of its listed part with the
-- smallest key, which is its key; keys are all its parts'; power is what its parts draw together. Each has entry,
-- key, keys, power, inside and state ("on", "off" or "other": the player's choice), and for power: essential,
-- schedule (BU.SCHEDULES) and held ("shed", "saving", "blackout" or "timer" while the box keeps it off, or nil). A
-- utility that is off (BU.enabled) has none.
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

function Panels.devices(panel, utility)
    local api = BU.api()
    local building = Panels.building(panel)
    local result = {}
    if not BU.enabled(utility) then return result, true end
    if not api or not building then return result, false end
    local data = panel[utility]
    -- The listed parts by object: each part's key leads to its object's group.
    local groups, order, groupOf = {}, {}, {}
    local function collect(list, inside)
        for i = 1, list and #list or 0 do
            local entry = list[i]
            -- Of the building, only the rooms of the panel's zone.
            if not inside or Panels.inZone(panel, entry.roomId) then
                local key = BU.thingKey(entry.x, entry.y, entry.z, entry.sprite)
                local group = groupOf[key]
                if not group then
                    local object = BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)[1]
                    local keys = object and BU.partKeys(object) or { key }
                    group = { keys = keys, entries = {}, inside = inside }
                    for _, part in ipairs(keys) do groupOf[part] = group end
                    groupOf[key] = group
                    order[#order + 1] = group
                end
                group.entries[#group.entries + 1] = { entry = entry, key = key }
            end
        end
    end
    local inside, insideComplete = api.buildings.objects(building.key, utility)
    local outside, outsideComplete = api.buildings.near(building.key, BU.exteriorRange(panel.tier), utility)
    collect(inside, true)
    collect(outside, false)
    for _, group in ipairs(order) do
        table.sort(group.entries, function(a, b) return a.key < b.key end)
        local first = group.entries[1]
        local power
        for _, part in ipairs(group.entries) do
            if part.entry.power then power = (power or 0) + part.entry.power end
        end
        local device = { entry = first.entry, key = first.key, keys = group.keys, power = power, inside = group.inside,
            roomId = group.inside and (first.entry.roomId or "") or nil }
        if group.inside then
            device.state = anyKey(data.excluded, group.keys) and "off" or "on"
        else
            local owner = inclusionOwner(utility, group.keys)
            device.state = owner == panel and "on" or owner and "other" or "off"
        end
        if utility == "water" then device.group = BU.Water.deviceGroup(panel, group.keys) end
        if utility == "power" and device.state == "on" then
            device.essential = data.essential[device.key] == true
            device.schedule = data.schedule[device.key] or "always"
            device.held = data.shed[device.key] and "shed" or data.saving[device.key] and "saving"
                or data.blackout[device.key] and "blackout" or data.timed[device.key] and "timer" or nil
        end
        result[#result + 1] = device
    end
    return result, insideComplete and outsideComplete
end

-- Overload.

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
        if own and (building and own.key == building.key or steps and steps <= BU.exteriorRange(panel.tier)) then
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
    local sprite = object:getSprite() and object:getSprite():getName()
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
-- there (excluded inside, not added outside, or its network, otherState, without supply), else nil; nil too while
-- the other is off (BU.enabled).
function Panels.missingOther(panel, utility, device, otherState)
    local entry = device.entry
    if not (entry.power and entry.water) then return nil end
    local other = utility == "power" and "water" or "power"
    if not BU.enabled(other) then return nil end
    local excluded, included = false, false
    for _, key in ipairs(device.keys) do
        excluded = excluded or device.inside and panel[other].excluded[key] ~= nil
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

-- The lights a blackout switches off: the panel's connected power devices that are light switches or lamps on
-- loaded squares, but those essential at a tier that sheds.
function Panels.blackoutLights(panel)
    local keys = {}
    local essential = (panel.tier or 1) >= BU.SMART_TIER
    for _, device in ipairs(Panels.devices(panel, "power")) do
        if device.state == "on" and not (essential and device.essential) then
            local entry = device.entry
            local object = BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)[1]
            if object and instanceof(object, "IsoLightSwitch") then keys[#keys + 1] = device.key end
        end
    end
    return keys
end

-- Whether a panel can take its supply from another: a main panel in another building or another zone of its own,
-- of a tier that gives supply (BU.LINK_TIER) and whose sub-panel range reaches its own building, with no producers
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
    local tier = Panels.tierReaching(BU.subPanelRange, steps)
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
    table.sort(result, function(a, b) return a.steps < b.steps end)
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

-- Kept a few seconds by panel: the tooltip over a box and the windows ask for names often, and each name asks the API
-- for every unnamed panel's building and rooms.
local autoNames, AUTO_NAME_MS = {}, 5000
function Panels.autoName(panel)
    local now = getTimestampMs()
    local cached = autoNames[panel.id]
    if cached and now - cached.at < AUTO_NAME_MS then return cached.name end
    local building = Panels.building(panel)
    local best, area = nil, 0
    for _, room in ipairs(Panels.rooms(building)) do
        local size = 0
        for _, rect in ipairs(room.rects) do size = size + rect.w * rect.h end
        if room.name and room.name ~= "" and size > area then best, area = room.name, size end
    end
    local name = best and getText("IGUI_BU_PanelOf", BU.roomName(best)) or getText("IGUI_BU_PanelDefault")
    autoNames[panel.id] = { at = now, name = name }
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
