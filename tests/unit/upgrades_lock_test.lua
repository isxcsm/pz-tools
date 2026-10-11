-- 자물쇠 따기 and alarms: a lock picked on an alarmed house or car cuts its alarm, and with 경보 읽기 an alarmed door,
-- window or car door that is not locked can be worked on for its alarm alone, with the same tools, chance and failure.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Api"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules

-- The actions file, loaded without the game's timed actions.
local function loadActions()
    local real = require
    ISBaseTimedAction = { derive = function(self) return setmetatable({}, { __index = self }) end,
                          new = function(self) return setmetatable({}, { __index = self }) end }
    require = function(name)
        if string.find(name, "^TimedActions/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Actions")
    require = real
    if not ok then error(err, 0) end
    return OA.Upgrades.Actions
end

local function listen()
    local told = {}
    OA.Sync.listen("notice", function(_, detail) told[#told + 1] = detail.key end)
    return told
end

-- A door of a building (its square's), alarmed or not; a car door of a car, alarmed, opened before or not.
local function house(alarmed)
    local def = { alarmed = alarmed }
    function def:isAlarmed() return self.alarmed end
    function def:setAlarmed(on) self.alarmed = on end
    local building = { getDef = function() return def end }
    local square = { getBuilding = function() return building end, getX = function() return 5 end,
                     getY = function() return 5 end, getZ = function() return 0 end }
    local door = { kind = "IsoDoor", locked = true, getSquare = function() return square end,
                   getNorth = function() return false end, getObjectIndex = function() return 1 end }
    return door, def
end

local function car(alarmed, entered)
    local vehicle = { alarmed = alarmed, sent = 0, getX = function() return 3 end, getY = function() return 3 end,
                      getZ = function() return 0 end }
    function vehicle:isAlarmed() return self.alarmed end
    function vehicle:setAlarmed(on) self.alarmed = on end
    function vehicle:isPreviouslyEntered() return entered end
    function vehicle:transmitAlarmed() self.sent = self.sent + 1 end
    local part = { kind = "VehiclePart", getVehicle = function() return vehicle end, getDoor = function() return {} end }
    return part, vehicle
end

local function setup(ranks, chance)
    local Actions = loadActions()
    instanceof = function(o, kind) return type(o) == "table" and o.kind == kind end
    addSound = function() end
    OA.random = function() return chance end
    Actions.unlock = function(target) target.locked = false end
    Actions.isReinforced = function() return false end
    local clip = { getContainer = function() return nil end }
    Actions.pickTools = function() return clip, {} end
    getCell = function() return { getGridSquare = function() return nil end } end
    local record = OA.Store.ensure("lk", "tester")
    local u = Rules.section(record)
    for id, rank in pairs(ranks) do u.ranks[id] = rank end
    local body = { getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }
    return Actions, body
end

local function act(class, target, body)
    return setmetatable({ oaId = "lk", target = target, character = body }, { __index = class })
end

test("a lock picked on an alarmed house cuts its alarm, and the character says so", function()
    local Actions, body = setup({ lock = 1 }, 1)
    local told = listen()
    local door, def = house(true)
    eq(Actions.alarmOf(door), "house")
    eq(act(ISOAPickLock, door, body):complete(), true)
    eq(door.locked, false)
    eq(def.alarmed, false, "the alarm is cut")
    eq(told[#told], "IGUI_OA_Tree_PickDisarmed")
    local plain = house(false)
    act(ISOAPickLock, plain, body):complete()
    eq(told[#told], "IGUI_OA_Tree_PickSuccess", "no alarm: the plain line")
end)

test("a failed pick leaves the alarm, a pried lock too", function()
    local Actions, body = setup({ lock = 1, crowbar = 1 }, 100)
    local told = listen()
    local door, def = house(true)
    eq(act(ISOAPickLock, door, body):complete(), false)
    eq(def.alarmed, true)
    eq(told[#told], "IGUI_OA_Tree_PickFail")
    OA.random = function() return 1 end
    Actions.pryBar = function() return {} end
    body.getStats = function() return {} end
    eq(act(ISOAPryOpen, door, body):complete(), true)
    eq(def.alarmed, true, "the pry bar does not touch the alarm")
end)

test("a car's alarm is cut and sent; one opened before has none to cut", function()
    local Actions, body = setup({ lock = 1 }, 1)
    local part, vehicle = car(true, false)
    eq(act(ISOAPickLock, part, body):complete(), true)
    eq(vehicle.alarmed, false)
    eq(vehicle.sent, 1, "the change is sent, as the game's own setAlarmed command does")
    local opened = car(true, true)
    eq(Actions.alarmOf(opened), nil, "a car opened once does not sound again")
end)

test("cutting an alarm alone needs lock picking and alarm reading, works on a door not locked, and fails as a pick", function()
    local Actions, body = setup({ lock = 1 }, 1)
    local told = listen()
    local door, def = house(true)
    door.locked = false
    eq(act(ISOADisarm, door, body):complete(), false, "without alarm reading")
    eq(def.alarmed, true)
    Rules.section(OA.Store.ensure("lk", "tester")).ranks.alarm = 1
    local action = act(ISOADisarm, door, body)
    eq(action:isValid(), true)
    eq(action:complete(), true)
    eq(def.alarmed, false)
    eq(told[#told], "IGUI_OA_Tree_Disarmed")
    eq(action:isValid(), false, "nothing left to cut")
    local other, otherDef = house(true)
    OA.random = function() return 100 end
    eq(act(ISOADisarm, other, body):complete(), false)
    eq(otherDef.alarmed, true)
    eq(told[#told], "IGUI_OA_Tree_PickFail", "a failure bends the clip as a pick's does")
end)
