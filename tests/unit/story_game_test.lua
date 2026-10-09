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
