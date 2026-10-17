-- Whose a delivery box is: a character's own, an abandoned one (its owner's character died), another living one's. Only
-- an own box takes items, is sealed or taken up; an abandoned one is dismantled.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Handlers"
local OA = OperationAcorn
local Objects, Things = OA.Trade.Objects, OA.Trade.Things

local function character(id)
    local data = { OA_Id = id }
    return { getModData = function() return data end }
end

local function box(owner, sealed)
    local data = { [Objects.OWNER] = owner, [Objects.KIND] = Objects.DELIVERY_BOX, [Objects.SEALED] = sealed }
    return { getModData = function() return data end }
end

test("a box is the character's own, abandoned or another's by its owner's record", function()
    OA.Store.ensure("me", "Me")
    OA.Store.ensure("you", "You")
    local gone = OA.Store.ensure("gone", "Gone")
    OA.Store.retire(gone)
    local me = character("me")
    eq(Things.boxSide(me, box("me"):getModData()), "own")
    eq(Things.boxSide(me, box(nil):getModData()), "own", "a box made by hand")
    eq(Things.boxSide(me, box("nobody"):getModData()), "own", "an owner no record has")
    eq(Things.boxSide(me, box("you"):getModData()), "other")
    eq(Things.boxSide(me, box("gone"):getModData()), "abandoned")
    eq(Objects.abandoned(box("gone")), true)
    eq(Objects.abandoned(box("you")), false)
    eq(Objects.abandoned(box("gone"):getModData()), true, "a box item's mod data")
    eq(Objects.abandoned(nil), false)
end)

test("an abandoned box takes nothing; the others' rule is the team's", function()
    local gone = OA.Store.ensure("gone2", "Gone")
    OA.Store.retire(gone)
    local container = { getParent = function() return box("gone2") end }
    eq(Objects.acceptItem(container, {}), false)
end)

test("another's or an abandoned box is not sealed, taken up or put down", function()
    OA.Store.ensure("me3", "Me")
    local gone = OA.Store.ensure("gone3", "Gone")
    OA.Store.retire(gone)
    local me = character("me3")
    local ok, why = Things.takeBox(me, box("gone3"))
    eq(ok, false)
    eq(why, "notOwner")
    ok, why = Things.placeBox(me, OA.Store.player("me3"), {}, box("gone3"))
    eq(ok, false)
    eq(why, "notOwner")
    local object = box("gone3")
    Objects.kindOf = function(o) return o:getModData()[Objects.KIND] end
    ok, why = Things.seal(me, OA.Store.player("me3"), object)
    eq(ok, false)
    eq(why, "notOwner")
    ok, why = Things.dismantleBox(me, box("me3"))
    eq(ok, false, "an own box is not dismantled")
    eq(why, "notOwner")
end)

test("a box holding nothing the team takes is not sealed: it would go up empty", function()
    local record = OA.Store.ensure("me4", "Me")
    local placed = OA.Trade.Boxes.add(record, { state = "placed", x = 10, y = 20, z = 0 })
    local refusedItem = {}
    local container = { getItems = function()
        return { size = function() return 1 end, get = function() return refusedItem end }
    end }
    local object = box("me4")
    object:getModData()[Objects.BOX] = placed.id
    object.getContainer = function() return container end
    object.getSquare = function() return { getX = function() return 10 end, getY = function() return 20 end } end
    local me = character("me4")
    me.getX, me.getY = function() return 10.5 end, function() return 21 end
    local value = OA.Value
    OA.Value = { info = function() return {} end, accepts = function() return false end }
    Objects.kindOf = function(o) return o:getModData()[Objects.KIND] end
    local ok, why = Things.seal(me, record, object)
    OA.Value = value
    eq(ok, false)
    eq(why, "nothing")
    eq(object:getModData()[Objects.SEALED], nil, "left open")
end)
