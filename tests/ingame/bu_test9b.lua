-- Zones and power: A (with the generator) takes one room, B (no producer) the rest of its floor. "[bu9b]" lines.
local BU = BuildingUtilities
local MD = ModData.getOrCreate("BU9TEST")
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu9b] " .. table.concat(parts, " "))
end
local steps, current, waitTicks = {}, 1, 0
local function pause(ticks) waitTicks = ticks end
local function A() return BU.Store.get(MD.a) end
local building, rooms

local function powered(room)
    local rect = room.rects[1]
    local result = {}
    for x = rect.x, rect.x + rect.w - 1 do
        local q = getCell():getGridSquare(x, rect.y, room.level)
        result[#result + 1] = q and (q:haveElectricity() and "1" or "0") or "-"
    end
    return table.concat(result)
end

local function freeSquareIn(room)
    for _, rect in ipairs(room.rects) do
        for x = rect.x, rect.x + rect.w - 1 do for y = rect.y, rect.y + rect.h - 1 do
            local q = getCell():getGridSquare(x, y, room.level)
            if q and q:getObjects():size() == 1 and q:isFree(false) then return q end
        end end
    end
end

local function report(label)
    local s = BU.Networks.state(A(), "power")
    say(label, "A supplied", s.supplied, "load", string.format("%.2f", s.load or 0), "tripped", A().tripped,
        "room1", powered(rooms[1]), "room2", powered(rooms[2]), "upstairs", powered(rooms[5]))
end

steps[#steps + 1] = function()
    local a = A()
    building = BU.Panels.building(a)
    rooms = BU.Panels.rooms(building)
    while (a.tier or 1) < BU.TIERS do BU.Changes.upgrade(a) end
    if a.tripped then BU.Changes.resetBreaker(a) end
    pause(90)
end
steps[#steps + 1] = function()
    report("whole")
    BU.Changes.setZone(A(), { rooms[1].id })
    pause(90)
end
steps[#steps + 1] = function()
    report("A room1 only")
    local corner = rooms[1].rects[1]
    local _, reason = BU.Panels.canInstall(getCell():getGridSquare(corner.x, corner.y, rooms[1].level))
    say("box in A's room:", reason)
    local b = BU.Changes.install(freeSquareIn(rooms[2]), BU.PANEL_SPRITES[1])
    MD.b = b.id
    pause(90)
end
steps[#steps + 1] = function()
    report("B takes floor 0 rest")
    local b = BU.Store.get(MD.b)
    while (b.tier or 1) < BU.TIERS do BU.Changes.upgrade(b) end
    BU.Changes.link(b, A(), {})
    pause(90)
end
steps[#steps + 1] = function()
    report("B linked to A")
    say("B parent", BU.Store.get(MD.b).parent)
    say("done")
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
