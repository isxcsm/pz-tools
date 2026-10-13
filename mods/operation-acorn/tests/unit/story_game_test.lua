-- The story's game adapter (Story/Game) where it reads plain item tables: whether an item is a mission's piece.
require "OperationAcorn/Core"
require "OperationAcorn/Story/Game"
local OA = OperationAcorn
local Game = OA.StoryGame

function instanceof(object, class)
    return object ~= nil and object.classes ~= nil and object.classes[class] == true
end

-- A fake item: modData, and for a bag its inventory's recursive search with a predicate.
local function item(data, contents)
    local it = { data = data or {}, classes = {} }
    it.getModData = function() return it.data end
    if contents then
        it.classes.InventoryContainer = true
        it.getInventory = function()
            local inv = {}
            function inv:getFirstEvalArgRecurse(predicate, arg)
                local function walk(list)
                    for _, inner in ipairs(list) do
                        if predicate(inner, arg) then return inner end
                        if inner.contents then
                            local found = walk(inner.contents)
                            if found then return found end
                        end
                    end
                    return nil
                end
                return walk(contents)
            end
            return inv
        end
        it.contents = contents
    end
    return it
end

test("an item holds a mission's piece when it is one, or has one inside", function()
    eq(Game.holds(item({ OA_Mission = "M1-1" }), "M1-1"), true)
    eq(Game.holds(item({ OA_Mission = "M1-1#A" }), "M1-1"), true, "a keyed piece")
    eq(Game.holds(item({ OA_Mission = "M1-10" }), "M1-1"), false, "another mission's id that starts the same")
    eq(Game.holds(item({}), "M1-1"), false)
    local deep = item({}, { item({}, { item({ OA_Mission = "M1-1" }) }) })
    eq(Game.holds(deep, "M1-1"), true, "inside bags")
    eq(Game.holds(item({}, { item({ OA_Mission = "M2-1" }) }), "M1-1"), false)
end)

-- A character whose inventory counts its searches. The items know their container, which is the inventory.
local function carrier(items)
    local searches = 0
    local weight = 1
    local inv = {}
    function inv:getFirstEvalArgRecurse(predicate, arg)
        searches = searches + 1
        for _, it in ipairs(items) do
            if predicate(it, arg) then return it end
        end
        return nil
    end
    function inv:getItems() return { size = function() return #items end } end
    function inv:getContentsWeight() return weight end
    for _, it in ipairs(items) do it.getContainer = function() return inv end end
    local p = { getInventory = function() return inv end, getModData = function() return { OA_Id = "p1" } end }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return p end
    return p, function() return searches end, function(w) weight = w end, inv
end

test("the mission's item is searched for once, then kept, and a miss is not searched again until the inventory changes", function()
    local cooler = item({ OA_Mission = "M1-1" })
    local items = { item({}), cooler }
    local p, searches, setWeight = carrier(items)
    local record = { id = "p1" }
    eq(Game.findItem(record, "M1-1"), cooler)
    eq(searches(), 1)
    eq(Game.findItem(record, "M1-1"), cooler)
    eq(Game.findItem(record, "M1-1"), cooler)
    eq(searches(), 1, "the item kept is checked in a few steps")
    -- it leaves the inventory: searched, not found
    cooler.getContainer = function() return nil end
    items[2] = item({})
    eq(Game.findItem(record, "M1-1"), nil)
    eq(searches(), 2)
    eq(Game.findItem(record, "M1-1"), nil)
    eq(Game.findItem(record, "M1-1"), nil)
    eq(searches(), 2, "a miss under the same signature: not searched again")
    -- something changed in the inventory: searched again
    setWeight(2)
    eq(Game.findItem(record, "M1-1"), nil)
    eq(searches(), 3)
end)
