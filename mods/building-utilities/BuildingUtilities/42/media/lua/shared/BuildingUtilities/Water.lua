-- A panel's water as networks of the API. Its water runs in pipes, each a colour (at most Water.MAX_PIPES; blue, the
-- first, always there, and nothing says "pipe" while it is the only one). Every water thing is on one pipe: a tank,
-- a fixture, a sprinkler; a pump's outlet; a filter's and a booster pump's inlet and outlet. In the zone's rooms the
-- pipes run in the walls: a fixture there is on its room's pipe (blue unless the player chose another for the room),
-- or on one the player chose for it. A thing outside is on its line (BU.Links), which runs to a wall of the zone.
--
-- Water runs down, never up: a fixture takes water from its pipe's tanks on its floor and above in its own building,
-- the lowest first (the higher ones feed more floors); and from the tanks of the zone's other buildings (reached by a
-- relay standing in them) only as high as the lines between them cross (Water.crossings), the lowest first. So the
-- API has, per pipe, building and floor, a tank network (that floor's tanks, no parents: what is filled, a floor at a
-- time) and a use network (the rooms and fixtures there, no tanks), whose parents are the tank networks it reaches, in
-- the order it draws from them (the API's "nearest" policy: each parent in turn). Pumps, filters and booster pumps
-- move water from an inlet to an outlet (server/BuildingUtilities/WaterRun.lua): out of a use network or tank
-- networks, into the outlet pipe's tank networks of their building, the highest floor they reach first.
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Store = BU.Store
local Water = {}
BU.Water = Water

Water.FIRST = 1
Water.MAX_PIPES = 8
-- The pipes' colours, by id: blue, green, orange, purple, red, yellow, teal, brown. The id is the colour; its name
-- the translation IGUI_BU_Pipe_<name>.
Water.COLOURS = { { 0.35, 0.6, 1 }, { 0.35, 0.85, 0.45 }, { 1, 0.62, 0.25 }, { 0.72, 0.5, 1 }, { 1, 0.35, 0.35 },
    { 0.95, 0.85, 0.3 }, { 0.3, 0.85, 0.85 }, { 0.72, 0.52, 0.32 } }
Water.COLOUR_NAMES = { "Blue", "Green", "Orange", "Purple", "Red", "Yellow", "Teal", "Brown" }

function Water.aboveOnly() return BU.sandbox("WaterFromAboveOnly", false) == true end

-- Freezing (a risk, off by default): pipes freeze after FREEZE_HOURS below FREEZE_BELOW degrees at the box, and thaw
-- after THAW_HOURS above THAW_ABOVE.
Water.FREEZE_BELOW, Water.FREEZE_HOURS, Water.THAW_ABOVE, Water.THAW_HOURS = -5, 6, 0, 2
function Water.freezeEnabled() return BU.sandbox("RiskPipesFreeze", false) == true end

-- The temperature the box's pipes have: its square's air (BU.airAt, loaded or not).
function Water.pipeTemperature(panel) return BU.airAt(panel) end

-- Floors a booster pump lifts water above its own (the sandbox's BoosterLift).
function Water.boostFloors() return BU.sandbox("BoosterLift", 5) end

-- Pipes.

function Water.pipes(panel) return panel.water.pipes end

function Water.pipe(panel, id)
    for _, pipe in ipairs(Water.pipes(panel)) do
        if pipe.id == id then return pipe end
    end
    return nil
end

-- Whether the panel shows its pipes: it has more than the first.
function Water.shown(panel) return #Water.pipes(panel) > 1 end

function Water.colour(id) return Water.COLOURS[id] or Water.COLOURS[Water.FIRST] end

-- A pipe's name: the player's, else its colour's, with its number for those who cannot tell colours apart.
function Water.pipeName(panel, id)
    local pipe = Water.pipe(panel, id)
    if pipe and pipe.name and pipe.name ~= "" then return pipe.name end
    return getText("IGUI_BU_Pipe_" .. (Water.COLOUR_NAMES[id] or Water.COLOUR_NAMES[1]), id)
end

-- The colour a new pipe takes: the first unused, nil with all in use.
function Water.nextPipe(panel)
    for id = 1, Water.MAX_PIPES do
        if not Water.pipe(panel, id) then return id end
    end
    return nil
end

-- One of the panel's pipes, or the first: what a thing whose pipe is gone (or never set) is on.
local function valid(panel, id)
    if id and Water.pipe(panel, id) then return id end
    return Water.FIRST
end
Water.valid = valid

-- A room's pipe, by the room's key (its square, BU.placeKey).
function Water.roomPipe(panel, key)
    return valid(panel, key and panel.water.roomPipe and panel.water.roomPipe[key])
end

-- The pipe the player chose for a fixture (by any of its parts' keys), or nil: then it is on its room's, or the first
-- outside.
function Water.chosenPipe(panel, keys)
    for _, key in ipairs(keys) do
        local id = panel.water.pipeOf and panel.water.pipeOf[key]
        if id and Water.pipe(panel, id) then return id end
    end
    return nil
end

-- A tank's pipe.
function Water.producerPipe(panel, at) return valid(panel, at.pipe) end

-- The floor whose tank network a tank joins: its own, or the one below with the sandbox's "water from above only".
function Water.producerLevel(at) return Water.aboveOnly() and at.z - 1 or at.z end

-- A water unit's inlet and outlet pipes: a pump has an outlet only, a sprinkler (either kind) an inlet only; a filter's and a
-- booster pump's outlet is their inlet unless the player chose another.
function Water.unitPipes(panel, unit)
    local inlet = valid(panel, unit.pipe)
    local outlet = unit.out and Water.pipe(panel, unit.out) and unit.out or inlet
    if unit.kind == "pump" then return nil, inlet end
    if unit.kind == "sprinkler" or unit.kind == "firesprinkler" then return inlet, nil end
    return inlet, outlet
end

-- Buildings. A water thing is in a building: its room's (the zone's rooms, with their shells: BU.Links.homeRoom), or
-- for one outside, the building its line enters: a relay's that stands in one, else its wall's. An outdoor box and
-- what hangs on it are one building of their own, OUTDOOR.
Water.OUTDOOR = "outdoor"

-- The building of a line's thing: up its line to a relay standing in a building or to the wall; nil for a cut line.
local function lineBuilding(panel, ref)
    local Links, Panels = BU.Links, BU.Panels
    local seen = {}
    local line = Links.get(ref)
    while line and not seen[line.ref or ref] do
        seen[line.ref or ref] = true
        local unit = Links.unitOf(line.ref)
        if unit and BU.RELAY_KINDS[unit.kind] then
            local building = Panels.buildingAt(unit.x, unit.y, unit.z)
            if building then return building.key end
        end
        if line.wall then
            if panel.outdoor then return Water.OUTDOOR end
            local x, y, z = BU.parsePlace(line.wall)
            local building = x and Panels.buildingAt(x, y, z)
            return building and building.key or nil
        end
        line = line.via and Links.get(line.via) or nil
    end
    return nil
end

-- The building of a water thing at a square, and its floor: by its line (ref) when it has one (its own floor), else
-- its room's (the room's floor: a fixture on the roof or the outer wall's ring is its room's, as the API has it). Nil
-- when it is in neither.
function Water.placeOf(panel, x, y, z, ref)
    if ref and BU.Links.get(ref) then
        local key = lineBuilding(panel, ref)
        return key, z
    end
    if panel.outdoor then return Water.OUTDOOR, z end
    local room = BU.Links.homeRoom(panel, x, y, z)
    if not room then return nil, z end
    return room.building, room.level
end

-- Where a water device of Panels.devices is, kept on it: pipe (the one it is on), pipeChosen (the player chose it, not
-- its room), roomKey (its room's, in the zone), building and level (Water.placeOf; nil building when neither a room of
-- the zone nor a live line has it). roomsById: the zone's rooms by id (Panels.zoneRooms), when the caller has them.
function Water.placeDevice(panel, device, roomsById)
    local entry = device.entry
    local x, y, z = entry.x, entry.y, entry.z
    local chosen = Water.chosenPipe(panel, device.keys)
    local ref = not device.inside and panel.water.included[device.key] and BU.Links.deviceRef(device.key) or nil
    local building, level, room
    if ref then
        if BU.Links.live(panel, ref) then building, level = Water.placeOf(panel, x, y, z, ref) end
    elseif device.inside and not panel.outdoor then
        room = roomsById and roomsById[device.roomId] or BU.Links.homeRoom(panel, x, y, z)
        if room then building, level = room.building, room.level end
    end
    device.roomKey = room and room.key or nil
    device.pipe = chosen or (room and Water.roomPipe(panel, room.key)) or Water.FIRST
    device.pipeChosen = chosen ~= nil
    device.building, device.level = building, level
end

-- The pipes a water line carries, by its thing: a tank's, a fixture's (the one the player chose, else the first), a
-- unit's inlet (a pump's outlet), and a machine's outlet too when it differs from its inlet (a filter or a booster
-- outside runs both to the wall, side by side: the line is drawn as two; changing a pipe is a valve's turn, so the
-- second pipe costs nothing more); nil for a relay's.
function Water.linePipes(panel, line)
    local kind = line.ref:sub(1, 1)
    if kind == "p" then
        for _, at in ipairs(panel.water.producers) do
            if at.x == line.x and at.y == line.y and at.z == line.z then return Water.producerPipe(panel, at) end
        end
        return Water.FIRST
    elseif kind == "t" then
        return Water.chosenPipe(panel, { line.ref:sub(3) }) or Water.FIRST
    end
    local unit = BU.Links.unitOf(line.ref)
    if not unit or BU.RELAY_KINDS[unit.kind] then return nil end
    local inlet, outlet = Water.unitPipes(panel, unit)
    if inlet and outlet and inlet ~= outlet then return inlet, outlet end
    return inlet or outlet
end

-- How high water crosses into each building of the zone: a line leaves the box's building at its wall square and
-- enters another at the relay standing in it, and water from or to that building passes no higher than the lower of
-- the two. By building key; the box's own building (and an outdoor box's) has none (math.huge). With several relays
-- in a building, its best.
function Water.crossings(panel)
    local Links, Panels = BU.Links, BU.Panels
    local result = {}
    local own = panel.outdoor and Water.OUTDOOR or (Panels.building(panel) and Panels.building(panel).key)
    if own then result[own] = math.huge end
    for _, relay in ipairs(Panels.relaysOf(panel)) do
        local building = Panels.buildingAt(relay.x, relay.y, relay.z)
        if building and building.key ~= own and Links.live(panel, Links.unitRef(relay)) then
            local height = relay.z
            local line, seen = Links.get(Links.unitRef(relay)), {}
            while line and not seen[line.ref] do
                seen[line.ref] = true
                if line.wall then
                    local _, _, z = BU.parsePlace(line.wall)
                    if z then height = math.min(height, z) end
                end
                line = line.via and Links.get(line.via) or nil
            end
            if not result[building.key] or height > result[building.key] then result[building.key] = height end
        end
    end
    return result
end

-- How high water passes between two buildings of a zone: the lower of their crossings.
local function head(crossings, a, b)
    if a == b then return math.huge end
    return math.min(crossings[a] or -math.huge, crossings[b] or -math.huge)
end

-- Network ids: "bu-p3-water-c2-b100_200_0-L1-T". A building's key with its commas as "_".
local function buildingTag(key) return key == Water.OUTDOOR and "o" or tostring(key):gsub(",", "_") end

function Water.networkId(panel, pipe, building, level, kind)
    return BU.networkId(panel.id, "water") .. "-c" .. pipe .. "-b" .. buildingTag(building) .. "-L" .. level .. "-" .. kind
end

-- The water things of a panel's layout, each { key, pipe, building, level }: the zone's rooms (by their pipe), the
-- fixtures on a pipe not their room's, those outside on a line, the inlets of its units. Tanks apart.
local function uses(panel)
    local Panels, Links = BU.Panels, BU.Links
    local result = {}
    for _, room in ipairs(Panels.zoneRooms(panel)) do
        result[#result + 1] = { room = room, pipe = Water.roomPipe(panel, room.key), building = room.building, level = room.level }
    end
    local data = panel.water
    local keys = {}
    for _, set in ipairs({ data.included, data.attached or {}, data.pipeOf or {} }) do
        for key in pairs(set) do keys[key] = true end
    end
    for key in pairs(keys) do
        local x, y, z = BU.parseThing(key)
        local ref = data.included[key] and Links.deviceRef(key) or nil
        if x and (not ref or Links.live(panel, ref)) then
            local building, level = Water.placeOf(panel, x, y, z, ref)
            if building then
                local room = not ref and Links.homeRoom(panel, x, y, z) or nil
                local pipe = Water.chosenPipe(panel, { key }) or (room and Water.roomPipe(panel, room.key)) or Water.FIRST
                result[#result + 1] = { key = key, pipe = pipe, building = building, level = level }
            end
        end
    end
    if BU.Units then
        for _, unit in ipairs(BU.Units.working(panel)) do
            if BU.Units.utility(unit) == "water" then
                local inlet = Water.unitPipes(panel, unit)
                local building, level = Water.placeOf(panel, unit.x, unit.y, unit.z, Links.unitRef(unit))
                if inlet and building then
                    result[#result + 1] = { unit = unit, pipe = inlet, building = building, level = level }
                end
            end
        end
    end
    return result
end

-- What a panel's water networks are now:
--   networks, a list of { id, kind ("T" tanks, "U" use), pipe, building, level, producers (tank networks: a list of
--     { x, y, z }), rooms (use networks: the zone's rooms on it, as Panels.rooms has them), parents (use networks: the
--     tank networks it reaches, in the order it draws from them) };
--   tanks, by pipe and building, the floors with tanks, lowest first;
--   use, by "pipe|building|level", the use network's id;
--   crossings (Water.crossings).
-- A use network for every place something takes water: a room, a fixture, a unit's inlet.
function Water.layout(panel)
    local Links = BU.Links
    local crossings = Water.crossings(panel)
    local networks, tanks, tankIds, use = {}, {}, {}, {}
    for _, at in ipairs(panel.water.producers) do
        if Links.live(panel, Links.producerRef(at.x, at.y, at.z)) then
            local building = Water.placeOf(panel, at.x, at.y, at.z, Links.producerRef(at.x, at.y, at.z))
            if building then
                local pipe, level = Water.producerPipe(panel, at), Water.producerLevel(at)
                local id = Water.networkId(panel, pipe, building, level, "T")
                local network = tankIds[id]
                if not network then
                    network = { id = id, kind = "T", pipe = pipe, building = building, level = level, producers = {} }
                    tankIds[id] = network
                    networks[#networks + 1] = network
                    tanks[pipe] = tanks[pipe] or {}
                    tanks[pipe][building] = tanks[pipe][building] or {}
                    table.insert(tanks[pipe][building], level)
                end
                table.insert(network.producers, { x = at.x, y = at.y, z = at.z })
            end
        end
    end
    for _, byBuilding in pairs(tanks) do
        for _, levels in pairs(byBuilding) do table.sort(levels) end
    end
    local useIds = {}
    for _, each in ipairs(uses(panel)) do
        local id = Water.networkId(panel, each.pipe, each.building, each.level, "U")
        local network = useIds[id]
        if not network then
            network = { id = id, kind = "U", pipe = each.pipe, building = each.building, level = each.level, rooms = {} }
            useIds[id] = network
            use[each.pipe .. "|" .. each.building .. "|" .. each.level] = id
            -- Its own building's tanks at its floor and above, lowest first; then each other building's that the
            -- crossings let down to it, the building whose lowest such floor is lowest first.
            local parents, others = {}, {}
            for building, levels in pairs(tanks[each.pipe] or {}) do
                local reach = {}
                for _, level in ipairs(levels) do
                    if level >= each.level then reach[#reach + 1] = level end
                end
                if #reach > 0 then
                    if building == each.building then
                        for _, level in ipairs(reach) do
                            parents[#parents + 1] = Water.networkId(panel, each.pipe, building, level, "T")
                        end
                    elseif head(crossings, building, each.building) >= each.level then
                        others[#others + 1] = { building = building, levels = reach }
                    end
                end
            end
            table.sort(others, function(a, b)
                if a.levels[1] ~= b.levels[1] then return a.levels[1] < b.levels[1] end
                return tostring(a.building) < tostring(b.building)
            end)
            for _, other in ipairs(others) do
                for _, level in ipairs(other.levels) do
                    parents[#parents + 1] = Water.networkId(panel, each.pipe, other.building, level, "T")
                end
            end
            network.parents = parents
            networks[#networks + 1] = network
        end
        if each.room then table.insert(network.rooms, each.room) end
    end
    table.sort(networks, function(a, b) return a.id < b.id end)
    return { networks = networks, tanks = tanks, use = use, crossings = crossings }
end

-- The use network of a pipe at a building's floor, or nil (nothing takes water there).
function Water.useId(layout, pipe, building, level)
    return building and layout.use[pipe .. "|" .. building .. "|" .. level] or nil
end

-- The tank networks a machine's outlet fills on a pipe in its building: those of the floors from `top` down to
-- `bottom` (nil: every floor below), highest first.
function Water.fillTargets(panel, layout, pipe, building, top, bottom)
    local result = {}
    local levels = layout.tanks[pipe] and layout.tanks[pipe][building] or {}
    for index = #levels, 1, -1 do
        local level = levels[index]
        if level <= top and (not bottom or level >= bottom) then
            result[#result + 1] = Water.networkId(panel, pipe, building, level, "T")
        end
    end
    return result
end

-- The tank networks of a pipe in a building at a floor and below, the floor itself first: what a booster pump's inlet
-- draws on its own pipe.
function Water.belowTargets(panel, layout, pipe, building, level)
    return Water.fillTargets(panel, layout, pipe, building, level, nil)
end

-- The pipes as a diagram (the window's schematic: floors up, pipes across) for the box's own building, an outdoor
-- box's own: what each pipe has on each floor, what moves water, and where water comes in from the zone's other
-- buildings. From a layout (Water.layout) and `stateOf(id)`, a tank network's state ({ amount, capacity }) or nil:
--   pipes, the pipe ids in order; low and high, the floors shown (the box's, and every floor with something);
--   cells[level][pipe] = { tanks (their squares), amount, capacity, uses (places taking water there), dry (one of
--     them reaches no water storage) };
--   machines, each { unit, kind ("pump", "filter", "booster"), level, inlet, outlet, top (the highest floor a booster
--     lifts to) };
--   arrivals, each { pipe, building, level (the highest floor its water comes in at: its highest storage, or as high as
--     the lines between the buildings cross) }.
function Water.schematic(panel, layout, stateOf)
    local Panels, Links = BU.Panels, BU.Links
    local building = Panels.building(panel)
    local own = panel.outdoor and Water.OUTDOOR or (building and building.key)
    local result = { pipes = {}, cells = {}, machines = {}, arrivals = {}, low = panel.z, high = panel.z }
    for _, pipe in ipairs(Water.pipes(panel)) do result.pipes[#result.pipes + 1] = pipe.id end
    local function cell(level, pipe)
        result.low, result.high = math.min(result.low, level), math.max(result.high, level)
        local row = result.cells[level] or {}
        result.cells[level] = row
        local each = row[pipe]
        if not each then
            each = { tanks = {}, amount = 0, capacity = 0, uses = 0 }
            row[pipe] = each
        end
        return each
    end
    for _, network in ipairs(layout.networks) do
        if network.building == own then
            local each = cell(network.level, network.pipe)
            if network.kind == "T" then
                for _, at in ipairs(network.producers) do each.tanks[#each.tanks + 1] = at end
                local state = stateOf and stateOf(network.id)
                if state then
                    each.amount = each.amount + (state.amount or 0)
                    each.capacity = each.capacity + (state.capacity or 0)
                end
            else
                each.uses = each.uses + 1
                if #(network.parents or {}) == 0 then each.dry = true end
            end
        end
    end
    for _, unit in ipairs(BU.Units and BU.Units.working(panel) or {}) do
        local kind = unit.kind
        if kind == "pump" or kind == "filter" or kind == "booster" then
            local place, level = Water.placeOf(panel, unit.x, unit.y, unit.z, Links.unitRef(unit))
            local inlet, outlet = Water.unitPipes(panel, unit)
            if place == own and outlet then
                local machine = { unit = unit, kind = kind, level = level, inlet = inlet, outlet = outlet }
                if kind == "booster" then machine.top = level + Water.boostFloors() end
                cell(level, outlet)
                if inlet then cell(level, inlet) end
                result.machines[#result.machines + 1] = machine
            end
        end
    end
    for pipe, byBuilding in pairs(layout.tanks) do
        for other, levels in pairs(byBuilding) do
            local cross = other ~= own and #levels > 0 and head(layout.crossings, other, own) or nil
            if cross and cross > -math.huge then
                result.arrivals[#result.arrivals + 1] = { pipe = pipe, building = other,
                    level = math.min(levels[#levels], cross) }
            end
        end
    end
    table.sort(result.arrivals, function(a, b)
        if a.pipe ~= b.pipe then return a.pipe < b.pipe end
        return a.level > b.level
    end)
    return result
end

-- Whether a use network reaches any tank: else what takes water there has none ("too high").
function Water.reachesTank(layout, id)
    for _, network in ipairs(layout.networks) do
        if network.id == id then return #(network.parents or {}) > 0 end
    end
    return false
end

return Water
