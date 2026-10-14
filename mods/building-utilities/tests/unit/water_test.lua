-- Water as pipes (BU.Water): the layout of tank and use networks per pipe, building and floor, what each use network
-- draws from and in what order, the height between buildings, pipes put in and taken away, and the machines
-- (BU.WaterRun) moving water from their inlet to their outlet. The API's networks are a recording stand-in that holds
-- tanks' litres.
require "BuildingUtilities/Changes"
require "BuildingUtilities/WaterRun"
local BU = BuildingUtilities
local Store, Changes, Networks, Water, WaterRun, WaterUnits = BU.Store, BU.Changes, BU.Networks, BU.Water, BU.WaterRun,
    BU.WaterUnits

-- A house at (x, y), 5 by 5, a room a floor.
local function building(key, x, y, levels)
    local api = TEST.api
    local rooms = {}
    for level = 0, levels - 1 do
        rooms[#rooms + 1] = { id = key .. "-" .. level, name = "room", level = level,
            rects = { { x = x, y = y, w = 5, h = 5 } } }
    end
    api.buildingsByKey[key] = {
        building = { key = key, playerBuilt = false, minLevel = 0, maxLevel = levels - 1, minX = x, minY = y,
            maxX = x + 4, maxY = y + 4, room = "room", roomId = key .. "-0" },
        rooms = rooms,
    }
    for level = 0, levels - 1 do
        for dx = 0, 4 do
            for dy = 0, 4 do api.squares[(x + dx) .. "," .. (y + dy) .. "," .. level] = key end
        end
    end
end

-- The API's networks, recording: each defined network's producers, parents, rooms, rules and switches; tanks (by
-- "x,y,z": { amount, capacity, fluid }) give state, draws and fills.
-- Whether the game's mains run, as the API's state tells it.
local mainsRun = false

local function fakeNetworks()
    local nets, tanks = {}, {}
    mainsRun = false
    local function tankOf(at) return tanks[at.x .. "," .. at.y .. "," .. at.z] end
    -- A network's tanks in the order it draws: its own, then each parent's.
    local function chain(id)
        local result = {}
        local net = nets[id]
        if not net then return result end
        for _, at in ipairs(net.producers) do result[#result + 1] = tankOf(at) end
        for _, parent in ipairs(net.parents) do
            for _, tank in ipairs(chain(parent)) do result[#result + 1] = tank end
        end
        return result
    end
    local api = {
        define = function(_, id) nets[id] = { producers = {}, parents = {}, rooms = {}, rules = {}, purify = true } end,
        remove = function(_, id) nets[id] = nil end,
        -- As the API: a tank is a producer of one network at a time.
        setProducers = function(_, id, list)
            for _, at in ipairs(list) do
                for other, net in pairs(nets) do
                    for _, held in ipairs(other ~= id and net.producers or {}) do
                        if held.x == at.x and held.y == at.y and held.z == at.z then
                            error(at.x .. "," .. at.y .. "," .. at.z .. " is a producer of the network " .. other)
                        end
                    end
                end
            end
            nets[id].producers = list
        end,
        setParents = function(_, id, list) nets[id].parents = list or {} end,
        addRoom = function(_, id, x, y, z) nets[id].rooms[x .. "," .. y .. "," .. z] = true end,
        removeRoom = function(_, id, x, y, z) nets[id].rooms[x .. "," .. y .. "," .. z] = nil end,
        include = function(_, id, x, y, z, sprite) nets[id].rules[BU.thingKey(x, y, z, sprite)] = "include" end,
        exclude = function(_, id, x, y, z, sprite) nets[id].rules[BU.thingKey(x, y, z, sprite)] = "exclude" end,
        reset = function(_, id, x, y, z, sprite) nets[id].rules[BU.thingKey(x, y, z, sprite)] = nil end,
        setEnabled = function(_, id, on) nets[id].enabled = on end,
        setPurify = function(_, id, on) nets[id].purify = on end,
        setGridFirst = function(_, id, on) nets[id].gridFirst = on end,
        setExtraLoad = function() end,
        setSource = function() end,
        addBuilding = function() end,
        state = function(id)
            if id:find("power", 1, true) then return { supplied = true, enabled = true } end
            local net = nets[id]
            if not net then return nil end
            local amount, capacity = 0, 0
            for _, tank in ipairs(chain(id)) do
                amount, capacity = amount + tank.amount, capacity + tank.capacity
            end
            local producers = {}
            for _, at in ipairs(net.producers) do
                local tank = tankOf(at)
                producers[#producers + 1] = { x = at.x, y = at.y, z = at.z, amount = tank.amount,
                    capacity = tank.capacity, foreign = tank.foreign }
            end
            return { amount = amount, capacity = capacity, supplied = amount > 0, enabled = net.enabled ~= false,
                purify = net.purify, producers = producers, gridFirst = net.gridFirst == true, mains = mainsRun }
        end,
        fill = function(_, id, litres, fluid)
            local filled = 0
            for _, tank in ipairs(chain(id)) do
                local take = math.min(litres - filled, tank.capacity - tank.amount)
                if take > 0 then
                    tank.amount = tank.amount + take
                    tank.fluids[fluid] = (tank.fluids[fluid] or 0) + take
                    filled = filled + take
                end
            end
            return filled
        end,
        draw = function(_, id, litres)
            local drawn, mix = 0, {}
            for _, tank in ipairs(chain(id)) do
                local take = math.min(litres - drawn, tank.amount)
                if take > 0 then
                    -- What it holds, in its shares.
                    for fluid, amount in pairs(tank.fluids) do
                        local part = take * amount / tank.amount
                        tank.fluids[fluid] = amount - part
                        mix[fluid] = (mix[fluid] or 0) + part
                    end
                    tank.amount = tank.amount - take
                    drawn = drawn + take
                end
            end
            return drawn, mix
        end,
    }
    TEST.api.table.networks = api
    return nets, function(x, y, z, capacity, amount, fluid)
        tanks[x .. "," .. y .. "," .. z] = { amount = amount or 0, capacity = capacity,
            fluids = { [fluid or "Water"] = amount or 0 } }
        return tanks[x .. "," .. y .. "," .. z]
    end
end

-- A box in house A (three floors) with water on, and the recording networks.
local function scene(levels)
    building("A", 100, 100, levels or 3)
    local nets, tank = fakeNetworks()
    local panel = Store.newPanel(102, 102, 0, "box")
    panel.tier = 4
    return panel, nets, tank
end

local function tankAt(panel, tank, x, y, z, capacity, amount, fluid)
    local held = tank(x, y, z, capacity, amount, fluid)
    Changes.connectProducer(panel, "water", x, y, z, {})
    return held
end

local function idOf(panel, pipe, building, level, kind) return Water.networkId(panel, pipe, building, level, kind) end

local function parentsOf(layout, id)
    for _, network in ipairs(layout.networks) do
        if network.id == id then return table.concat(network.parents or {}, " ") end
    end
    return nil
end

test("a floor's use network draws on its building's tanks at its floor and above, the lowest first", function()
    local panel, nets, tank = scene(3)
    tankAt(panel, tank, 101, 101, 0, 100)
    tankAt(panel, tank, 101, 101, 2, 100)
    local layout = Networks.waterLayout(panel)
    local t0, t2 = idOf(panel, 1, "A", 0, "T"), idOf(panel, 1, "A", 2, "T")
    eq(layout.tanks[1].A[1], 0)
    eq(layout.tanks[1].A[2], 2)
    eq(parentsOf(layout, idOf(panel, 1, "A", 0, "U")), t0 .. " " .. t2, "the ground floor: its own, then the roof's")
    eq(parentsOf(layout, idOf(panel, 1, "A", 1, "U")), t2, "the first floor: only the one above")
    eq(parentsOf(layout, idOf(panel, 1, "A", 2, "U")), t2)
    -- The API has them so: tanks on tank networks, rooms on use networks.
    eq(#nets[t0].producers, 1)
    eq(nets[t0].parents[1], nil, "a tank network has no parents")
    eq(nets[idOf(panel, 1, "A", 1, "U")].parents[1], t2)
    eq(nets[idOf(panel, 1, "A", 1, "U")].rooms["100,100,1"], true, "the room by its square")
    truthy(Water.reachesTank(layout, idOf(panel, 1, "A", 1, "U")))
end)

test("every water network leaves to the mains what they reach while they run, and the state tells when they do", function()
    local panel, nets, tank = scene(2)
    tankAt(panel, tank, 101, 101, 0, 100, 40)
    local layout = Networks.waterLayout(panel)
    for _, network in ipairs(layout.networks) do eq(nets[network.id] and nets[network.id].gridFirst, true, network.id) end
    eq(Networks.state(panel, "water").mains, false)
    mainsRun = true
    eq(Networks.state(panel, "water").mains, true, "the mains run")
end)

test("a tank above every fixture's floor is only for the floors below; none above: too high", function()
    local panel, _, tank = scene(3)
    tankAt(panel, tank, 101, 101, 0, 100)
    local layout = Networks.waterLayout(panel)
    eq(Water.reachesTank(layout, idOf(panel, 1, "A", 0, "U")), true)
    eq(Water.reachesTank(layout, idOf(panel, 1, "A", 1, "U")), false, "the floor above the only tank")
end)

test("a pipe put in, a room and a tank put on it, then taken away: all back on the first", function()
    local panel, nets, tank = scene(2)
    local held = tankAt(panel, tank, 101, 101, 1, 100)
    eq(Water.shown(panel), false, "one pipe: none shown")
    local pipe = Changes.addPipe(panel)
    eq(pipe, 2, "green, the next colour")
    eq(Water.shown(panel), true)
    local roomKey = BU.Panels.zoneRooms(panel)[1].key
    Changes.setRoomPipe(panel, roomKey, pipe)
    Changes.setProducerPipe(panel, 1, pipe)
    local layout = Networks.waterLayout(panel)
    local green0 = idOf(panel, 2, "A", 0, "U")
    eq(parentsOf(layout, green0), idOf(panel, 2, "A", 1, "T"), "the green room draws on the green tank")
    eq(nets[idOf(panel, 1, "A", 1, "T")], nil, "no blue tank network left")
    eq(held.capacity, 100)
    Changes.removePipe(panel, pipe)
    eq(#Water.pipes(panel), 1)
    eq(panel.water.producers[1].pipe, nil)
    eq(panel.water.roomPipe[roomKey], nil)
    eq(nets[green0], nil, "the green networks gone")
    eq(#nets[idOf(panel, 1, "A", 1, "T")].producers, 1, "the tank on blue again")
    eq(Water.nextPipe(panel), 2)
end)

test("a tank shut at the box is out of its pipe; a unit switched off there does not work", function()
    local panel, nets, tank = scene(1)
    tankAt(panel, tank, 101, 101, 0, 100, 50)
    local id = idOf(panel, 1, "A", 0, "T")
    truthy(nets[id] ~= nil)
    Changes.setProducerOn(panel, 1, false)
    eq(nets[id], nil, "shut: no tank network")
    Changes.setProducerOn(panel, 1, true)
    truthy(nets[id] ~= nil, "open again")
    local sprinkler = Store.newUnit("sprinkler", 103, 103, 0, WaterUnits.SPRINKLER_SPRITES.idle)
    Changes.connectUnit(sprinkler, panel, {})
    eq(#BU.Units.working(panel, "sprinkler"), 1)
    Changes.setUnitOn(sprinkler, false)
    eq(#BU.Units.working(panel, "sprinkler"), 0, "off")
    Changes.setUnitOn(sprinkler, true)
    eq(#BU.Units.working(panel, "sprinkler"), 1, "on again")
end)

test("a pipe keeps what it took, for the refund as it is taken out", function()
    local panel = scene(1)
    local pipe = Changes.addPipe(panel, { ["Base.Pipe"] = 2 })
    eq(Water.pipe(panel, pipe).paid["Base.Pipe"], 2)
    eq(Water.pipe(panel, Changes.addPipe(panel)).paid, nil, "put in free (a scene): nothing back")
end)

test("a fixture on its own pipe: excluded from its room's use network, included in its pipe's", function()
    local panel, nets, tank = scene(1)
    tankAt(panel, tank, 101, 101, 0, 100)
    local pipe = Changes.addPipe(panel)
    local key = BU.thingKey(103, 103, 0, "sink")
    local device = { key = key, keys = { key }, inside = true, entry = { x = 103, y = 103, z = 0, sprite = "sink" } }
    Changes.setDevicePipe(panel, device, pipe)
    eq(nets[idOf(panel, 1, "A", 0, "U")].rules[key], "exclude")
    eq(nets[idOf(panel, 2, "A", 0, "U")].rules[key], "include")
    Water.placeDevice(panel, device)
    eq(device.pipe, pipe)
    eq(device.pipeChosen, true)
    Changes.setDevicePipe(panel, device, nil)
    eq(nets[idOf(panel, 1, "A", 0, "U")].rules[key], nil, "back on its room's pipe")
    Water.placeDevice(panel, device)
    eq(device.pipe, Water.FIRST)
    -- One on the roof is its room's, on the room's floor.
    local roofKey = BU.thingKey(102, 102, 1, "sink")
    local roof = { key = roofKey, keys = { roofKey }, inside = true, entry = { x = 102, y = 102, z = 1, sprite = "sink" } }
    Changes.setDevicePipe(panel, roof, pipe)
    eq(nets[idOf(panel, 2, "A", 0, "U")].rules[roofKey], "include")
    Water.placeDevice(panel, roof)
    eq(roof.level, 0)
end)

test("another building's tanks reach down only as high as the lines between the buildings cross", function()
    local panel, _, tank = scene(3)
    building("B", 108, 100, 3)
    local junction = Store.newUnit("junction", 109, 101, 0, BU.Relays.SPRITES.junction)
    Changes.connectUnit(junction, panel, {})
    eq(BU.Links.reason(panel, BU.Links.unitRef(junction)), nil, "the junction's line supplies")
    local crossings = Water.crossings(panel)
    eq(crossings.A, math.huge)
    eq(crossings.B, 0, "the junction stands on B's ground floor")
    tankAt(panel, tank, 109, 102, 2, 100)
    local layout = Networks.waterLayout(panel)
    local tB = idOf(panel, 1, "B", 2, "T")
    eq(parentsOf(layout, idOf(panel, 1, "A", 0, "U")), tB, "down to A's ground floor")
    eq(parentsOf(layout, idOf(panel, 1, "A", 1, "U")), "", "not up to A's first floor")
    eq(parentsOf(layout, idOf(panel, 1, "B", 1, "U")), tB, "B's own floors below it")
end)

test("a pump fills its pipe's tanks on its floor and below, the highest first", function()
    local panel, _, tank = scene(3)
    local low = tankAt(panel, tank, 101, 101, 0, 100)
    local high = tankAt(panel, tank, 101, 103, 2, 10)
    local top = tankAt(panel, tank, 103, 101, 2, 0)
    local pump = Store.newUnit("pump", 103, 103, 2, WaterUnits.PUMP_SPRITES.E)
    Changes.connectUnit(pump, panel, {})
    pump.fluid = "Water"
    WaterRun.machines(panel, 60)
    eq(pump.running, true)
    eq(pump.moved, WaterUnits.PUMP_RATE)
    eq(high.amount, 10, "the top floor first")
    eq(low.amount, 10, "then the one below")
    eq(top.amount, 0)
    eq(panel.extraLoads.pumps, WaterUnits.PUMP_LOAD)
end)

test("a booster pump on one pipe lifts its floor's water to the floors above, as far as it lifts", function()
    local panel, _, tank = scene(3)
    local low = tankAt(panel, tank, 101, 101, 0, 100, 50)
    local high = tankAt(panel, tank, 101, 101, 2, 100)
    local booster = Store.newUnit("booster", 103, 103, 0, WaterUnits.BOOSTER_SPRITES.S)
    Changes.connectUnit(booster, panel, {})
    WaterRun.machines(panel, 60)
    eq(booster.running, true)
    eq(high.amount, WaterUnits.BOOSTER_RATE, "lifted")
    eq(low.amount, 50 - WaterUnits.BOOSTER_RATE)
    WaterRun.machines(panel, 60)
    eq(low.amount, 0)
    eq(high.amount, 50, "what was left")
    WaterRun.machines(panel, 60)
    eq(booster.running, nil)
    eq(booster.idle, "noWater")
    eq(panel.extraLoads.boosters or 0, 0)
end)

test("a filter between two pipes passes its inlet's water on, clean while the pipes leave it tainted", function()
    local panel, nets, tank = scene(1)
    SandboxVars.BuildingUtilities = { RiskPlumbingUnpurified = true }
    local raw = tankAt(panel, tank, 101, 101, 0, 100, 60, "TaintedWater")
    local pipe = Changes.addPipe(panel)
    local clean = tankAt(panel, tank, 103, 101, 0, 100)
    Changes.setProducerPipe(panel, 2, pipe)
    local filter = Store.newUnit("filter", 103, 103, 0, WaterUnits.FILTER_SPRITES.across)
    filter.media = WaterUnits.FILTER_HOURS
    Changes.connectUnit(filter, panel, {})
    Changes.setUnitPipes(filter, Water.FIRST, pipe)
    WaterRun.machines(panel, 60)
    eq(filter.running, true)
    eq(clean.amount, WaterUnits.FILTER_RATE)
    eq(clean.fluids.Water, WaterUnits.FILTER_RATE, "made clean")
    eq(raw.amount, 60 - WaterUnits.FILTER_RATE)
    eq(filter.media, WaterUnits.FILTER_HOURS - 1, "its media worn by the hour")
    eq(nets[idOf(panel, 1, "A", 0, "U")].purify, false, "the raw pipe's use network unpurified")
    filter.media = 0
    WaterRun.machines(panel, 60)
    eq(filter.running, nil, "spent: passes nothing")
    eq(clean.amount, WaterUnits.FILTER_RATE)
end)

test("a filter on one pipe purifies it while it has media", function()
    local panel, nets, tank = scene(1)
    SandboxVars.BuildingUtilities = { RiskPlumbingUnpurified = true }
    tankAt(panel, tank, 101, 101, 0, 100, 60, "TaintedWater")
    local filter = Store.newUnit("filter", 103, 103, 0, WaterUnits.FILTER_SPRITES.across)
    filter.media = 2
    Changes.connectUnit(filter, panel, {})
    WaterRun.machines(panel, 60)
    eq(filter.running, true)
    eq(nets[idOf(panel, 1, "A", 0, "U")].purify, true)
    WaterRun.machines(panel, 60)
    WaterRun.machines(panel, 60)
    eq(filter.running, nil, "spent")
    eq(nets[idOf(panel, 1, "A", 0, "U")].purify, false)
end)

test("a sprinkler draws from its pipe until it is empty", function()
    local panel, _, tank = scene(1)
    local held = tankAt(panel, tank, 101, 101, 0, 100, 30)
    local sprinkler = Store.newUnit("sprinkler", 103, 103, 0, WaterUnits.SPRINKLER_SPRITES.idle)
    Changes.connectUnit(sprinkler, panel, {})
    local plant = { state = "seeded", waterLvl = 20, waterNeeded = 50, waterNeededMax = 80 }
    function plant:water(_, uses) self.waterLvl = self.waterLvl + uses * 10 end
    SFarmingSystem = { instance = { getLuaObjectAt = function(_, x, y)
        if x == 104 and y == 103 then return plant end
    end } }
    RainManager = { isRaining = function() return false end }
    WaterRun.sprinklers(panel)
    eq(plant.waterLvl, 70, "five uses")
    truthy(held.amount < 30)
    held.amount = 0
    plant.waterLvl = 20
    WaterRun.sprinklers(panel)
    eq(plant.waterLvl, 20, "empty: none")
end)

-- Fires on squares ({ x, y, z } each): the game's list of the burning, each fire's square loaded, burning.
local function burn(...)
    local fires = {}
    for _, at in ipairs({ ... }) do
        local key = at[1] .. "," .. at[2] .. "," .. at[3]
        TEST.squares[key] = TEST.squares[key] or { room = at[4] }
        TEST.squares[key].flags = { burning = true }
        fires[#fires + 1] = { getSquare = function() return getCell():getGridSquare(at[1], at[2], at[3]) end }
    end
    IsoFireManager = { FireStack = TEST_javaList(fires) }
end

local function burning(x, y, z)
    local square = TEST.squares[x .. "," .. y .. "," .. z]
    return square ~= nil and square.flags ~= nil and square.flags.burning == true
end

test("a fire sprinkler puts out the fires it reaches in its room, 20 L each, with no power", function()
    local panel, _, tank = scene(1)
    local held = tankAt(panel, tank, 101, 101, 0, 100, 50)
    TEST.squares["102,103,0"] = { room = "hall" }
    local head = Store.newUnit("firesprinkler", 102, 103, 0, WaterUnits.FIRE_SPRITES.hung.waiting)
    Changes.connectUnit(head, panel, {})
    -- three squares off on its floor in its room; four off; in another room; a floor up
    burn({ 105, 106, 0, "hall" }, { 106, 103, 0, "hall" }, { 103, 103, 0, "kitchen" }, { 102, 103, 1, "hall" })
    WaterRun.fires()
    eq(burning(105, 106, 0), false, "within reach: out")
    eq(burning(106, 103, 0), true, "four squares off: burning")
    eq(burning(103, 103, 0), true, "another room: burning")
    eq(burning(102, 103, 1), true, "another floor: burning")
    eq(held.amount, 30, "20 L")
    eq(head.sprayedAt, TEST.hours)
    truthy(WaterUnits.spraying(head))
    -- 10 L left: less than a square takes
    held.amount = 10
    burn({ 104, 104, 0, "hall" })
    WaterRun.fires()
    eq(burning(104, 104, 0), true, "too little water: burning")
    eq(held.amount, 10)
    -- frozen pipes put out nothing
    held.amount = 50
    panel.water.frozen = true
    WaterRun.fires()
    eq(burning(104, 104, 0), true, "frozen: burning")
    panel.water.frozen = nil
    WaterRun.fires()
    eq(burning(104, 104, 0), false)
    IsoFireManager = { FireStack = TEST_javaList({}) }
end)

test("a fire sprinkler outside reaches the squares of no room; one off or cut reaches none", function()
    local panel, _, tank = scene(1)
    local held = tankAt(panel, tank, 101, 101, 0, 100, 100)
    TEST.squares["110,110,0"] = {}
    local head = Store.newUnit("firesprinkler", 110, 110, 0, WaterUnits.FIRE_SPRITES.standing.waiting)
    Changes.connectUnit(head, panel, {})
    burn({ 112, 110, 0 }, { 111, 111, 0, "hall" })
    WaterRun.fires()
    eq(burning(112, 110, 0), false, "outside: out")
    eq(burning(111, 111, 0), true, "a room's square: burning")
    SandboxVars.BuildingUtilities = { EnableFireSprinklers = false }
    burn({ 112, 110, 0 })
    WaterRun.fires()
    eq(burning(112, 110, 0), true, "the feature off: burning")
    SandboxVars.BuildingUtilities = {}
    IsoFireManager = { FireStack = TEST_javaList({}) }
end)

test("a fire sprinkler hangs where the square over it lets no rain through, else stands", function()
    TEST.squares["120,120,0"] = { room = "hall" }
    eq(WaterUnits.fireSprite(getCell():getGridSquare(120, 120, 0), false), WaterUnits.FIRE_SPRITES.standing.waiting,
        "nothing over it: a hole in the roof, the open")
    TEST.squares["120,120,1"] = { roof = true }
    eq(WaterUnits.fireSprite(getCell():getGridSquare(120, 120, 0), false), WaterUnits.FIRE_SPRITES.hung.waiting)
    eq(WaterUnits.fireSprite(getCell():getGridSquare(120, 120, 0), true), WaterUnits.FIRE_SPRITES.hung.spraying)
    TEST.squares["120,120,1"] = { roof = false }
    eq(WaterUnits.fireSprite(getCell():getGridSquare(120, 120, 0), false), WaterUnits.FIRE_SPRITES.standing.waiting,
        "a square over it with no floor")
end)

test("a network id names its panel, pipe, building, floor and kind", function()
    local panel = scene(1)
    local id = Water.networkId(panel, 3, "100,200,0", -1, "U")
    local owner, utility, pipe, building, level, kind = Networks.owner(id)
    eq(owner, panel)
    eq(utility, "water")
    eq(pipe, 3)
    eq(building, "100_200_0")
    eq(level, -1)
    eq(kind, "U")
end)

test("a machine's line carries its inlet and its outlet when they differ, one pipe else", function()
    local panel = scene(1)
    local pipe = Changes.addPipe(panel)
    local filter = Store.newUnit("filter", 103, 103, 0, WaterUnits.FILTER_SPRITES.across)
    Changes.connectUnit(filter, panel, {})
    local line = { ref = BU.Links.unitRef(filter), x = 103, y = 103, z = 0 }
    Changes.setUnitPipes(filter, Water.FIRST, pipe)
    local inlet, outlet = Water.linePipes(panel, line)
    eq(inlet, Water.FIRST)
    eq(outlet, pipe)
    Changes.setUnitPipes(filter, pipe, pipe)
    inlet, outlet = Water.linePipes(panel, line)
    eq(inlet, pipe)
    eq(outlet, nil, "one pipe")
    local ox, oy = BU.Links.besideOffset(3, 0, 0.2)
    eq(ox, 0)
    eq(oy, 0.1, "side by side, half the gap each way")
end)

test("the schematic: each pipe's storage and use on each floor, where none reaches, and the machines", function()
    local panel, _, tank = scene(3)
    tankAt(panel, tank, 101, 101, 1, 100, 40)
    local pipe = Changes.addPipe(panel)
    local booster = Store.newUnit("booster", 103, 103, 0, WaterUnits.BOOSTER_SPRITES.S)
    Changes.connectUnit(booster, panel, {})
    Changes.setUnitPipes(booster, Water.FIRST, pipe)
    local layout = BU.Networks.waterLayout(panel)
    local states = {}
    for _, network in ipairs(layout.networks) do
        if network.kind == "T" then states[network.id] = { amount = 40, capacity = 100 } end
    end
    local scheme = Water.schematic(panel, layout, function(id) return states[id] end)
    eq(#scheme.pipes, 2)
    eq(scheme.low, 0)
    eq(scheme.high, 2)
    local stored = scheme.cells[1][Water.FIRST]
    eq(#stored.tanks, 1, "the storage on the second floor")
    eq(stored.amount, 40)
    eq(stored.capacity, 100)
    eq(scheme.cells[0][Water.FIRST].dry, nil, "the ground floor reaches the storage above it")
    eq(scheme.cells[2][Water.FIRST].dry, true, "the top floor is above it")
    eq(#scheme.machines, 1)
    local machine = scheme.machines[1]
    eq(machine.kind, "booster")
    eq(machine.inlet, Water.FIRST)
    eq(machine.outlet, pipe)
    eq(machine.top, Water.boostFloors())
    eq(#scheme.arrivals, 0, "one building")
end)
