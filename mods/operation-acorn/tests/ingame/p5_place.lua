-- P5 placing: every machine kind put down on free ground east of the character, the footprint it takes (2x1, 2x2, 1x1),
-- the state on the anchor only, the other squares pointing to it, turning, taking up (refused with a part in, the part
-- out with its wear, nothing left after), the furniture tool, and breaking one part (the whole machine goes). Setup:
-- single player, standing in open ground with a clear patch 20 x 20 to the east and south, no roof (the cistern needs
-- rain). Gives itself the items; P5_CLEAN() removes what is left. Lines are tagged "[p5place]", each "ok" or "BAD".
RUN("p5_lib.lua")
local say = P5T.say("p5place")
local function check(...) return P5T.check(say, ...) end
local M = P5T.machines()
local Data = M.Data

local SIZE = { shredBench = { 2, 1 }, bulkShredder = { 2, 1 }, cutter = { 2, 1 }, woodSaw = { 2, 1 }, researchStorage = { 2, 1 },
    researchCrate = { 1, 1 }, propaneRefiner = { 2, 2 }, oilRefiner = { 2, 2 }, rainStorage = { 2, 2 }, lure = { 1, 1 } }

local function checkKind(kind, column, row)
    local object, reason = P5T.place(kind, column, row, "S")
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
    if kind ~= "lure" then
        -- a machine's parts count as contents: with them in it is not taken up, with them out it is
        local hasParts = false
        for _ in pairs(state.parts or {}) do hasParts = true end
        if hasParts then
            check(kind .. " pick up refused while its parts are in", M.canPickUp(object) == nil)
            for slot in pairs(state.parts) do M.removePart(object, slot, getPlayer()) end
        end
        check(kind .. " pick up allowed when empty", M.canPickUp(object) ~= nil, select(2, M.canPickUp(object)))
    end
end

-- two columns of kinds (x 3 and 6), three rows apart: it stays within the squares loaded around the character
for i, kind in ipairs(Data.ORDER) do
    local half = math.ceil(#Data.ORDER / 2)
    local column = i <= half and 3 or 6
    checkKind(kind, column, 2 + ((i - 1) % half) * 3)
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

-- Taking up (the game's furniture tool takes the pieces; Moveables.lua): refused while a part is in, the worn part comes
-- out with its wear, then allowed; the machine gone, nothing is left on its squares nor in the registry. The tool's own
-- take-up, a piece a tile, is done by hand.
do
    local object = P5T.place("woodSaw", 14, 2, "S")
    if object then
        local state = M.state(object)
        state.parts.blade.cond = 61
        local x, y, z = state.x, state.y, state.z
        local why = select(2, M.canPickUp(object))
        check("taking up refused while the blade is in", why == "hasParts", why)
        local inv = getPlayer():getInventory()
        local before = inv:getItems():size()
        check("the blade comes out", M.removePart(object, "blade", getPlayer()))
        local blade = inv:getItems():size() > before and inv:getItems():get(inv:getItems():size() - 1) or nil
        check("the worn blade keeps its wear", blade ~= nil and blade:getCondition() == 61, blade and blade:getCondition())
        for slot in pairs(state.parts) do M.removePart(object, slot, getPlayer()) end
        check("taking up allowed once empty", M.canPickUp(object) == true, select(2, M.canPickUp(object)))
        M.remove(object)
        local gone = M.at(getCell():getGridSquare(x, y, z)) == nil and M.at(getCell():getGridSquare(x + 1, y, z)) == nil
        check("every square is clear again", gone)
        check("registry entry gone", M.list()[state.id] == nil)
        if blade and blade:getContainer() then blade:getContainer():Remove(blade) end
    end
end

-- Taking the rain storage away: its anchor is an entity (the fluid container), the game's removal must take it too
-- (found in game: a 2x2 SpriteConfig made the game refuse, so the anchor stayed and the item came back as well).
do
    local object = P5T.place("rainStorage", 10, 5, "S")
    if check("rain storage placed for the pick up", object ~= nil) then
        local state = M.state(object)
        local x, y, z = state.x, state.y, state.z
        check("an empty rain storage may be taken up", M.canPickUp(object) == true, select(2, M.canPickUp(object)))
        M.remove(object)
        local left = 0
        for dy = 0, 1 do
            for dx = 0, 1 do
                local objects = getCell():getGridSquare(x + dx, y + dy, z):getObjects()
                for i = 0, objects:size() - 1 do
                    if M.isMachineObject(objects:get(i)) then left = left + 1 end
                end
            end
        end
        check("no rain storage object is left on its four squares", left == 0, left)
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

-- The furniture tool (Moveables.lua): every piece of a machine is furniture to it; taking up is refused while a part
-- is in, allowed once it is out.
do
    local object = P5T.place("cutter", 14, 8, "S")
    if object and ISMoveableSpriteProps then
        local props = ISMoveableSpriteProps.fromObject(object)
        check("the anchor is furniture to the tool", props ~= nil and props.isMoveable == true)
        local square = object:getSquare()
        local player = getPlayer()
        check("the tool refuses it while a part is in", props ~= nil and not props:canPickUpMoveable(player, square, object))
        for slot in pairs(M.state(object).parts) do M.removePart(object, slot, player) end
        check("the tool takes it once empty", props ~= nil and props:canPickUpMoveable(player, square, object) == true)
        local state = M.state(object)
        local objects = getCell():getGridSquare(state.x + 1, state.y, state.z):getObjects()
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            if M.anchorMark(o) then
                local p2 = ISMoveableSpriteProps.fromObject(o)
                check("a part is furniture to the tool", p2 ~= nil and p2.isMoveable == true)
            end
        end
    end
end

say("done; look at the machines east of you: the tiles line up and each 2x1 / 2x2 reads as one piece; P5_CLEAN() takes them away")
