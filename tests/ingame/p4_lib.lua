-- Helpers the P4 (missions and story) checks share. Each check runs RUN("p4_lib.lua") first.
P4T = {}

function P4T.say(tag)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        print("[" .. tag .. "] " .. table.concat(parts, " "))
    end
end

-- Prints "ok" or "BAD" with the label; returns the condition.
function P4T.check(say, label, condition, detail)
    say(label, condition and "ok" or "BAD", detail ~= nil and tostring(detail) or "")
    return condition and true or false
end

-- The local character and its record (made by the first hello), or nil.
function P4T.record()
    local player = getPlayer()
    local id = player:getModData().OA_Id
    local record = id and OperationAcorn.Store.player(id)
    return record, player
end

-- Sets the record's trade numbers as if the stage were reached (the story part sees it at its next ten-minute tick,
-- or at once through OA.Story.onStage).
function P4T.setStage(record, stage, milestones)
    record.trade = record.trade or {}
    record.trade.stage = stage
    record.trade.milestones = milestones or 0
    OperationAcorn.Story.onStage(record, stage, milestones or 0)
end

-- Moves the character to a place (x, y, z), as the debug teleport does.
function P4T.go(x, y, z)
    local p = getPlayer()
    p:setX(x + 0.5); p:setY(y + 0.5); p:setZ(z or 0)
    p:setLx(x + 0.5); p:setLy(y + 0.5); p:setLz(z or 0)
end

-- Every item of a mission (by OA_Mission, with or without a '#piece') in the loaded squares of a building box.
-- Returns a list of { x, y, z, container, item }.
function P4T.scan(id, x1, y1, x2, y2, z1, z2)
    local found = {}
    local cell = getCell()
    for z = z1, z2 do
        for x = x1, x2 do
            for y = y1, y2 do
                local sq = cell:getGridSquare(x, y, z)
                if sq then
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local c = objs:get(i):getContainer()
                        if c then
                            local items = c:getItems()
                            for j = 0, items:size() - 1 do
                                local it = items:get(j)
                                local md = it:hasModData() and it:getModData().OA_Mission
                                if md and string.find(md, id, 1, true) == 1 then
                                    found[#found + 1] = { x = x, y = y, z = z, container = c:getType(), item = it:getFullType() }
                                end
                            end
                        end
                    end
                    local wi = sq:getWorldObjects()
                    for i = 0, wi:size() - 1 do
                        local it = wi:get(i):getItem()
                        local md = it and it:hasModData() and it:getModData().OA_Mission
                        if md and string.find(md, id, 1, true) == 1 then
                            found[#found + 1] = { x = x, y = y, z = z, container = "floor", item = it:getFullType() }
                        end
                    end
                end
            end
        end
    end
    return found
end
