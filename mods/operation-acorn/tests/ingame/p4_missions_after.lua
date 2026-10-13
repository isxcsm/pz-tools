-- P4: second half of p4_missions.lua. Run it after the character has stood at the mission item's place for a few
-- seconds: counts the item's copies in the building (exactly one per piece), and tells what to look at for the
-- evidence room (a locked door, the key in the same building).
-- Duplicate check: walk 300 squares away, come back, run it again: the count must still be one.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4after")
local record, player = P4T.record()
local m = record and OA.Missions.active(record)
if not m then say("no active mission"); return end
for _, it in ipairs(m.items) do
    -- a tagged piece by its own tag (the mission id, '#piece' when there are several); the room's key by its type
    -- and key id (it carries no tag)
    local match
    if it.plain then
        match = function(item) return item:getFullType() == it.type and item:getKeyId() == it.keyId end
    else
        local id = OA.Missions.itemId(m, it.key)
        match = function(item)
            local md = item:hasModData() and item:getModData().OA_Mission
            return md == id or md == m.id
        end
    end
    local found = P4T.scan(m.id, it.x1, it.y1, it.x2, it.y2, it.z1, it.z2, match)
    for _, f in ipairs(found) do say("found", f.item, f.container, f.x, f.y, f.z) end
    P4T.check(say, "piece " .. it.key .. " found once", #found == 1, #found)
    P4T.check(say, "piece " .. it.key .. " marked placed", it.placed == true, tostring(it.placed))
    if it.lock and it.at then
        -- the doors of the room it went into are locked with the building's key (the KEY piece)
        local sq = getCell():getGridSquare(it.at.x, it.at.y, it.at.z)
        local room = sq and sq:getRoom()
        local doors, locked = 0, 0
        if room then
            local squares = room:getSquares()
            for i = 0, squares:size() - 1 do
                local objects = squares:get(i):getObjects()
                for j = 0, objects:size() - 1 do
                    local o = objects:get(j)
                    if instanceof(o, "IsoDoor") then
                        doors = doors + 1
                        if o:isLockedByKey() then locked = locked + 1 end
                    end
                end
            end
        end
        P4T.check(say, "the room's doors are locked", locked > 0, locked .. " of " .. doors .. " doors")
    end
end
