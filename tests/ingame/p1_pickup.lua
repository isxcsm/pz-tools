-- P1: the pickup hook. Drops a hammer and a bag with a notebook on the floor at your feet, picks them up the way
-- the game does (ISTransferAction:transferItem from the floor container), and checks the cell tag (OA_Cell) and
-- the codex entry. CHANGES THE RECORD (the codex learns the test kinds; use a throwaway save).
-- Prints "[p1pick]" lines.
RUN("p1_lib.lua")
local OA = OperationAcorn
local say = P1T.say("p1pick")
local record, player = P1T.record()
if not record then say("no record yet: wait for the first hello"); return end
local inv = player:getInventory()
local square = player:getCurrentSquare()
if not square then say("no square"); return end

P1T.check(say, "the economy wiring is loaded", OA.Economy ~= nil and OA.Economy.hookTransfers ~= nil)

local function onFloor(type)
    local item = inv:AddItem(type)
    inv:Remove(item)
    square:AddWorldInventoryItem(item, 0.5, 0.5, 0)
    return item
end

-- The game's own move: the class function with the floor "container" every character's window uses.
local function pickUp(item)
    local floor = ISInventoryPage.GetFloorContainer(player:getPlayerNum())
    ISTransferAction:transferItem(player, item, floor, inv, square)
end

local hammer = onFloor("Base.Hammer")
local bag = onFloor("Base.Bag_ALICEpack")
local book = bag:getInventory():AddItem("Base.Notebook")
local kindsBefore = OA.Codex.section(record).n
local hadHammer = OA.Codex.section(record).kinds.Hammer ~= nil

local ok1, err1 = pcall(pickUp, hammer)
P1T.check(say, "the hammer pickup ran", ok1, err1)
local ok2, err2 = pcall(pickUp, bag)
P1T.check(say, "the bag pickup ran", ok2, err2)

local cell = OA.Value.cellKey(square:getX(), square:getY())
P1T.check(say, "the hammer is in the inventory", inv:contains(hammer))
P1T.check(say, "the hammer carries this cell (" .. tostring(cell) .. ")", hammer:getModData().OA_Cell == cell,
    tostring(hammer:getModData().OA_Cell))
P1T.check(say, "the bag and the notebook inside carry it", bag:getModData().OA_Cell == cell and
    book:getModData().OA_Cell == cell, tostring(book:getModData().OA_Cell))
P1T.check(say, "the codex knows Hammer", OA.Codex.section(record).kinds.Hammer ~= nil)
P1T.check(say, "the notebook in the bag entered the codex", OA.Codex.section(record).kinds.Notebook ~= nil)
say("codex kinds", kindsBefore, "->", OA.Codex.section(record).n, hadHammer and "(Hammer was already known)" or "")

-- A move inside your own inventory is not a pickup.
local pocket = inv:AddItem("Base.Pencil")
pcall(function() ISTransferAction:transferItem(player, pocket, inv, bag:getInventory(), square) end)
P1T.check(say, "a move into your own bag is not tagged", pocket:getModData().OA_Cell == nil,
    tostring(pocket:getModData().OA_Cell))

for _, item in ipairs({ hammer, bag, pocket }) do
    local c = item:getContainer()
    if c then c:Remove(item) end
end
say("done")
