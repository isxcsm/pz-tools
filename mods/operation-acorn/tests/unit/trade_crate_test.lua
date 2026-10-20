-- A sealed supply crate taken out of the world by something other than the mod (a sledgehammer, a fire): its cargo
-- falls out on its square as items, the delivery box among them with its id (nothing it brought is lost); an opened
-- one, or another kind of object, is left as it is.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Things"
local OA = OperationAcorn
local Things, Objects = OA.Trade.Things, OA.Trade.Objects

local function item(fullType)
    local md = {}
    return { fullType = fullType, getModData = function() return md end, md = md }
end

local function crate(md)
    local fell = {}
    local square = { getX = function() return 10 end, getY = function() return 20 end,
        AddWorldInventoryItem = function(_, it) fell[#fell + 1] = it end }
    return { hasModData = function() return true end, getModData = function() return md end,
        getSquare = function() return square end }, fell
end

test("a sealed crate taken out drops its cargo where it stood, the box with its id", function()
    local realItem = instanceItem
    instanceItem = item
    local md = { [Objects.KIND] = Objects.CRATE, [Objects.SEALED] = true, [Objects.CARGO] = {
        { type = "OperationAcorn.CommTerminal", count = 1 },
        { type = "OperationAcorn.HarvestKit", count = 2 },
        { type = "OperationAcorn.DeliveryBox", count = 1, mod = { OA_Box = "1156-4", OA_Owner = "1156" } },
    } }
    local object, fell = crate(md)
    eq(Things.crateLost(object), 4)
    eq(#fell, 4)
    eq(fell[1].fullType, "OperationAcorn.CommTerminal")
    eq(fell[4].md.OA_Box, "1156-4", "the box keeps its id")
    eq(md[Objects.CARGO], nil, "dropped once")
    eq(Things.crateLost(object), 0, "nothing twice")
    -- an opened one: the game's own (its container) is left to the game
    local opened, none = crate({ [Objects.KIND] = Objects.CRATE })
    eq(Things.crateLost(opened), 0)
    eq(#none, 0)
    instanceItem = realItem
end)
