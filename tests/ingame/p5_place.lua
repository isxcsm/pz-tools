-- P5 placing: every machine kind put down on free ground east of the character, the footprint it takes (2x1, 2x2, 1x1),
-- the state on the anchor only, the other squares pointing to it, turning, picking up (one item back, every part gone),
-- and breaking one part (the whole machine goes). Setup: single player, standing in open ground with a clear patch
-- 20 x 20 to the east and south, no roof (the cistern needs rain). Gives itself the items; P5_CLEAN() removes what
-- is left. Lines are tagged "[p5place]", each "ok" or "BAD".
RUN("p5_lib.lua")
local say = P5T.say("p5place")
local function check(...) return P5T.check(say, ...) end
local M = P5T.machines()
local Data = M.Data

local SIZE = { shredBench = { 2, 1 }, bulkShredder = { 2, 1 }, cutter = { 2, 1 }, woodSaw = { 2, 1 }, researchStorage = { 2, 1 },
    propaneRefiner = { 2, 2 }, oilRefiner = { 2, 2 }, rainStorage = { 2, 2 }, lure = { 1, 1 } }

local function checkKind(kind, row)
    local object, reason = P5T.place(kind, 3, row, "S")
    if not check(kind .. " placed", object ~= nil, reason) then return end
    local state = M.state(object)
    local w, h = M.footprint(kind, "S")
    check(kind .. " footprint " .. SIZE[kind][1] .. "x" .. SIZE[kind][2], w == SIZE[kind][1] and h == SIZE[kind][2], w .. "x" .. h)
    local ax, ay, az = state.x, state.y, state.z
    local resolved, parts = 0, 0
    for dy = 0, h - 1 do
        for dx = 0, w - 1 do
            local square = getCell():getGridSquare(ax + dx, ay + dy, az)
            if M.at(square) == object then resolved = resolved + 1 end
            if (dx ~= 0 or dy ~= 0) and square then
                for i = 0, square:getObjects():size() - 1 do
                    local mark = M.anchorMark(square:getObjects():get(i))
                    if mark and mark.id == state.id then parts = parts + 1 end
                end
            end
        end
    end
    check(kind .. " every square resolves to the anchor", resolved == w * h, resolved)
    check(kind .. " the other squares carry the anchor mark", parts == w * h - 1, parts)
    local def = Data.KINDS[kind]
    local got = 0
    for _, which in ipairs(def.containers) do
        if M.container(object, which) then got = got + 1 end
    end
    check(kind .. " containers on the anchor", got == #def.containers, got .. "/" .. #def.containers)
    if kind ~= "lure" then check(kind .. " pick up allowed when empty", M.canPickUp(object) ~= nil) end
end

local row = 2
for _, kind in ipairs(Data.ORDER) do
    checkKind(kind, row)
    row = row + 3
end

-- Turning: the cutter facing east is one wide and two long.
do
    local object = P5T.place("cutter", 10, 2, "E")
    if check("cutter facing E placed", object ~= nil) then
        local w, h = M.footprint("cutter", "E")
        check("cutter facing E is 1x2", w == 1 and h == 2, w .. "x" .. h)
        local state = M.state(object)
        local below = getCell():getGridSquare(state.x, state.y + 1, state.z)
        check("cutter facing E covers the square to the south", M.at(below) == object)
        local ok, reason = M.canPlace("lure", below, "S")
        check("a square under a part of a machine is taken", ok == nil and reason == "taken", reason)
    end
end

-- Picking up: one item back with the parts, nothing left on the squares.
do
    local object = P5T.place("woodSaw", 14, 2, "S")
    if object then
        local state = M.state(object)
        state.parts.blade.cond = 61
        local x, y, z = state.x, state.y, state.z
        local item = M.pickUp(object, getPlayer())
        check("pick up gives the item", item ~= nil and item:getFullType() == "OperationAcorn.LogSaw")
        check("the worn blade travels with the item", item ~= nil and item:getModData().OA_Machine.parts.blade.cond == 61)
        local gone = M.at(getCell():getGridSquare(x, y, z)) == nil and M.at(getCell():getGridSquare(x + 1, y, z)) == nil
        check("every square is clear again", gone)
        check("registry entry gone", M.list()[state.id] == nil)
        if item and item:getContainer() then item:getContainer():Remove(item) end
    end
end

-- Breaking one part: the machine goes. (The destroy handler is called directly, as the engine event would.)
do
    local object = P5T.place("bulkShredder", 14, 5, "S")
    if object then
        local state = M.state(object)
        local objects = getCell():getGridSquare(state.x + 1, state.y, state.z):getObjects()
        local partObject
        for i = 0, objects:size() - 1 do
            if M.anchorMark(objects:get(i)) then partObject = objects:get(i) end
        end
        if check("found the part object", partObject ~= nil) then
            partObject:getSquare():transmitRemoveItemFromSquare(partObject)
            M.forget(partObject)
            check("the anchor goes with the part", M.at(getCell():getGridSquare(state.x, state.y, state.z)) == nil)
            check("the registry forgets it", M.list()[state.id] == nil)
        end
    end
end

-- The vanilla move is not offered for the anchor or a part.
do
    local object = P5T.place("cutter", 14, 8, "S")
    if object and ISMoveableSpriteProps then
        local props = ISMoveableSpriteProps.fromObject(object)
        check("vanilla move blocked on the anchor", props == nil or props.isMoveable == false)
        local state = M.state(object)
        local objects = getCell():getGridSquare(state.x + 1, state.y, state.z):getObjects()
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            if M.anchorMark(o) then
                local p2 = ISMoveableSpriteProps.fromObject(o)
                check("vanilla move blocked on a part", p2 == nil or p2.isMoveable == false)
            end
        end
    end
end

say("done; look at the machines east of you: the tiles line up and each 2x1 / 2x2 reads as one piece; P5_CLEAN() takes them away")
