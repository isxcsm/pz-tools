-- The terminal's place cursor (server/Trade/PlaceCursor): it faces the player until the player turns it as the game's
-- furniture is (the building cursor's nSprite: the rotate key, the bumper, a drag), then keeps the facing chosen.
require "OperationAcorn/Core"
local OA = OperationAcorn

local function load()
    -- the game's building cursor, as far as the cursor uses it
    local Base = {}
    Base.__index = Base
    function Base:derive(name) local c = setmetatable({}, { __index = self }); c.__index = c; c.Type = name; return c end
    function Base:init() self.nSprite = 1 end
    function Base:setSprite(s) self.sprite = s end
    function Base:setNorthSprite(s) self.northSprite = s end
    function Base:rotateKey() self.nSprite = self.nSprite % 4 + 1 end
    ISBuildingObject = Base
    require "OperationAcorn/Sprites"
    OA.Trade = OA.Trade or {}
    OA.Trade.Objects = { TERMINAL = "terminal", DELIVERY_BOX = "box", ITEMS = { field = "OperationAcorn.FieldTerminal" } }
    local real = require
    require = function(file)
        if file == "BuildingObjects/ISBuildingObject" or file == "OperationAcorn/Trade/Actions" then return true end
        return real(file)
    end
    local ok, err = pcall(real, "OperationAcorn/Trade/PlaceCursor")
    require = real
    if not ok then error(err, 0) end
end

local function square(x, y) return { getX = function() return x end, getY = function() return y end } end

test("the terminal faces the player until turned, then keeps the facing turned to", function()
    load()
    local character = { x = 10.5, y = 12.5, getX = function(c) return c.x end, getY = function(c) return c.y end,
        getPlayerNum = function() return 0 end }
    local cursor = ISOAPlaceCursor:new(character, "terminal", nil)
    cursor.square = square(10, 10)
    cursor:getSprite()
    eq(cursor.facing, "S", "the player stands south of it")
    character.x, character.y = 7.5, 10.5
    cursor:getSprite()
    eq(cursor.facing, "W", "it follows the player")
    cursor:rotateKey()
    cursor:getSprite()
    eq(cursor.facing, "N", "turned once from W")
    character.x, character.y = 13.5, 10.5
    cursor:getSprite()
    eq(cursor.facing, "N", "the player moving does not turn it back")
    cursor:rotateKey()
    cursor:getSprite()
    eq(cursor.facing, "E")
    eq(cursor:getSprite(), OA.Sprites.terminal("E", false, false))
end)
