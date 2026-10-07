-- Zones: two boxes in one building, each with its own rooms. "[bu9]" lines. BU9_CLEANUP takes the boxes away.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU9TEST")
local player = getPlayer()
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu9] " .. table.concat(parts, " "))
end
local GAS_STATION, GENERATOR = { 3570, 10891, 0 }, { 3573, 10908, 0 }
local steps, current, waitTicks = {}, 1, 0
local function pause(ticks) waitTicks = ticks end
local function A() return BU.Store.get(MD.a) end
local function B() return BU.Store.get(MD.b) end

local function freeSquareIn(room)
    for _, rect in ipairs(room.rects) do
        for x = rect.x, rect.x + rect.w - 1 do for y = rect.y, rect.y + rect.h - 1 do
            local q = getCell():getGridSquare(x, y, room.level)
            if q and q:getObjects():size() == 1 and q:isFree(false) then return q end
        end end
    end
end

local function zoneText(panel)
    if not panel.rooms then return "whole" end
    local ids = {}
    for id in pairs(panel.rooms) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

local function insideCount(panel)
    local count, rooms = 0, {}
    for _, device in ipairs(BU.Panels.devices(panel, "power")) do
        if device.inside then count = count + 1; rooms[device.roomId] = true end
    end
    local ids = {}
    for id in pairs(rooms) do ids[#ids + 1] = id end
    table.sort(ids)
    return count, table.concat(ids, ",")
end

local function powered(room)
    local rect = room.rects[1]
    local q = getCell():getGridSquare(rect.x, rect.y, room.level)
    return q and q:haveElectricity()
end

local building, rooms
if BU9_CLEANUP then
    steps[#steps + 1] = function()
        for _, w in ipairs({ MD.a, MD.b }) do
            if w and BU.PanelWindow.isOpen(w) then BU.PanelWindow.open(player, BU.Store.get(w)):close() end
        end
        if B() then BU.Changes.remove(B()) end
        if A() then BU.Changes.remove(A()) end
        local g = getCell():getGridSquare(GENERATOR[1], GENERATOR[2], 0):getGenerator()
        if MD.fuel then g:setFuel(MD.fuel) end
        g:setActivated(MD.wasOn == true)
        ModData.remove("BU9TEST")
        say("cleaned", #BU.Store.list())
    end
else
    steps[#steps + 1] = function()
        player:setGodMod(true)
        player:setInvisible(true)
        player:teleportTo(GAS_STATION[1] + 0.5, GAS_STATION[2] + 0.5, 0)
        pause(60)
    end
    steps[#steps + 1] = function()
        -- isLarge, from made-up rooms.
        local made = {}
        for level = 0, 3 do made[#made + 1] = { id = "m" .. level, level = level, rects = {} } end
        say("large 4 levels", BU.Panels.isLarge(made))
        made[#made + 1] = { id = "m4", level = 4, rects = {} }
        say("large 5 levels", BU.Panels.isLarge(made))
        building = BU.Panels.buildingAt(GAS_STATION[1], GAS_STATION[2], 0)
        rooms = BU.Panels.rooms(building)
        local names = {}
        for _, room in ipairs(rooms) do names[#names + 1] = room.id .. "/" .. tostring(room.name) .. "@" .. room.level end
        say("building", building.key, "rooms", #rooms, table.concat(names, " "))
        say("boxes in it before", #BU.Panels.ofBuilding(building.key))
        if #rooms < 2 then say("FAIL need two rooms"); return end
        -- A: the building's first box, small building: the whole of it.
        local a = BU.Changes.install(freeSquareIn(rooms[1]), BU.PANEL_SPRITES[1])
        MD.a = a.id
        local g = getCell():getGridSquare(GENERATOR[1], GENERATOR[2], 0):getGenerator()
        MD.fuel, MD.wasOn = g:getFuel(), g:isActivated()
        g:setFuel(10)
        g:setActivated(true)
        BU.Changes.connectProducer(a, "power", GENERATOR[1], GENERATOR[2], 0, {})
        say("A zone", zoneText(a), "inside", insideCount(a))
        local _, reason = BU.Panels.canInstall(freeSquareIn(rooms[2]))
        say("second box while A takes it whole:", reason)
        pause(30)
    end
    steps[#steps + 1] = function()
        local a = A()
        building = BU.Panels.building(a)
        rooms = BU.Panels.rooms(building)
        say("A whole: room1 powered", powered(rooms[1]), "room2 powered", powered(rooms[2]))
        -- Exclude a device of room 2, then give A only room 1: the exclusion goes with the room.
        local excluded
        for _, device in ipairs(BU.Panels.devices(a, "power")) do
            if device.inside and device.roomId == rooms[2].id and not excluded then
                excluded = device.key
                BU.Changes.setInside(a, "power", device, false)
            end
        end
        say("excluded in room2", excluded, a.power.excluded[excluded or ""])
        MD.excluded = excluded
        local ok = BU.Changes.setZone(a, { rooms[1].id })
        say("A zone room1", ok, zoneText(a), "inside", insideCount(a), "exclusion kept", excluded and a.power.excluded[excluded])
        say("empty zone refused", BU.Changes.setZone(a, {}), "unknown room refused", BU.Changes.setZone(a, { "nope" }), zoneText(a))
        pause(60)
    end
    steps[#steps + 1] = function()
        local a = A()
        say("A room1 only: room1 powered", powered(rooms[1]), "room2 powered", powered(rooms[2]))
        local _, reason = BU.Panels.canInstall(freeSquareIn(rooms[1]))
        say("box in A's room:", reason)
        local square = freeSquareIn(rooms[2])
        local okHere = BU.Panels.canInstall(square)
        say("box in a free room allowed", okHere ~= nil)
        local b = BU.Changes.install(square, BU.PANEL_SPRITES[1])
        MD.b = b.id
        say("B zone", zoneText(b), "inside", insideCount(b), "boxes", #BU.Panels.ofBuilding(building.key))
        say("B cannot take A's room", BU.Changes.setZone(b, { rooms[1].id }), zoneText(b))
        say("whole refused with two boxes", BU.Changes.setZone(a, nil), zoneText(a))
        local states = BU.Panels.zoneStates(a, building, rooms)
        say("states for A", states[rooms[1].id].state, states[rooms[2].id].state, BU.Panels.name(states[rooms[2].id].owner))
        say("B can link to A", BU.Panels.canLink(b, a))
        pause(60)
    end
    steps[#steps + 1] = function()
        say("B has no producer: room2 powered", powered(rooms[2]), "room1 powered", powered(rooms[1]))
        -- The plan of A, edited: room 2 is B's, so a click there does nothing; the floor menu sends what is free.
        BU.PanelWindow.planShown = true
        local w = BU.PanelWindow.open(player, A())
        w:setZoneEditing(true)
        local zone = w.plan.data.zone
        say("plan zone", zone[rooms[1].id].state, zone[rooms[2].id].state, zone[rooms[2].id].owner, "edit", w.plan.data.zoneEdit,
            "legend", #w.plan.legend, "dim cells", (function() local n = 0 for _, c in ipairs(w.plan.cells) do if c.dim then n = n + 1 end end return n end)())
        w:toggleZoneRoom(rooms[2].id)
        say("toggle B's room: A", zoneText(A()))
        w:setZoneEditing(false)
        local dim = 0
        for _, c in ipairs(w.plan.cells) do if c.dim then dim = dim + 1 end end
        say("normal plan dim cells", dim, "of", #w.plan.cells)
        -- B taken down: its room is free; A takes the whole building again.
        w:close()
        BU.Changes.remove(B())
        MD.b = nil
        say("after B removed: whole", BU.Changes.setZone(A(), nil), zoneText(A()), "inside", insideCount(A()))
        pause(60)
    end
    steps[#steps + 1] = function()
        say("A whole again: room1 powered", powered(rooms[1]), "room2 powered", powered(rooms[2]))
        say("done")
    end
end

local function tick()
    if waitTicks > 0 then waitTicks = waitTicks - 1; return end
    local step = steps[current]
    if not step then Events.OnTick.Remove(tick); return end
    current = current + 1
    local ok, problem = pcall(step)
    if not ok then say("FAIL in step", current - 1, problem) end
end
Events.OnTick.Add(tick)
