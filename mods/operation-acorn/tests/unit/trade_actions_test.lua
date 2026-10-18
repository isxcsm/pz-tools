-- The trade part's timed actions (shared/Trade/Actions): what they tell the player as they complete.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
local OA = OperationAcorn

local function load()
    local Base = {}
    Base.__index = Base
    function Base:derive(name) local c = setmetatable({}, { __index = self }); c.__index = c; c.Type = name; return c end
    function Base.new(class, character) return setmetatable({ character = character }, class) end
    ISBaseTimedAction = Base
    local real = require
    require = function(file)
        if file == "TimedActions/ISBaseTimedAction" then return true end
        return real(file)
    end
    local ok, err = pcall(real, "OperationAcorn/Trade/Actions")
    require = real
    if not ok then error(err, 0) end
end

test("a box sealed tells how many things it took, counted from the entries sealed", function()
    load()
    local Trade = OA.Trade
    local realSeal, realFind, realCell = Trade.Things.seal, Trade.Objects.find, getCell
    local object = { getModData = function() return {} end }
    Trade.Objects.find = function() return object end
    getCell = function() return { getGridSquare = function() return {} end } end
    Trade.Things.seal = function() return true, { { count = 2 }, { count = 3 } }, { taken = {} } end
    local told = {}
    OA.Sync.listen("notice", function(id, detail) told[#told + 1] = detail end)
    local character = { getModData = function() return { OA_Id = "a1" } end, getUsername = function() return "A" end }
    character.isTimedActionInstant = function() return true end
    local square = { getX = function() return 1 end, getY = function() return 2 end, getZ = function() return 0 end }
    local action = ISOASeal:new(character, square)
    action:complete()
    eq(told[#told].key, "IGUI_OA_Trade_Notice_Sealed")
    eq(told[#told].args[1], 5)
    Trade.Things.seal = function() return false, "nothing" end
    action:complete()
    eq(told[#told].key, "IGUI_OA_Trade_Reason_nothing")
    Trade.Things.seal, Trade.Objects.find, getCell = realSeal, realFind, realCell
end)
