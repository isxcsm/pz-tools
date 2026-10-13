-- P3: pry open and lock picking on a locked door, window or car.
-- Setup: a single-player world, the mod on; the script gives a crowbar, a paperclip and a screwdriver. Stand next to a
-- locked door and a locked window, and (separately) a locked car. Changes the record (the ranks).
-- Prints "[p3actions]" lines; then right-click the locked thing: the two options show their chance in the name, a
-- tooltip with the tool or the reason, and starting one runs the timed action.
RUN("p3_lib.lua")
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Actions = OA.Upgrades.Actions
local say = P3T.say("p3actions")
local record, player, u = P3T.record()

P3T.points(u, "survival", 12)
for _, id in ipairs({ "crowbar", "crowbar", "lock", "lock" }) do
    local ok, why = Rules.buy(u, id)
    if not ok then say("could not buy", id, why) end
end
P3T.changed(record)
P3T.give("Base.Crowbar")
P3T.give("Base.Paperclip")
P3T.give("Base.Screwdriver")
say("pry bar found", tostring(Actions.pryBar(player)))
local clip, driver = Actions.pickTools(player)
say("pick tools", tostring(clip), tostring(driver))
say("chances: pry", Rules.crowbarChance(u), "pick", Rules.lockChance(u), "pick time factor", Rules.lockTime(u))
local square = player:getCurrentSquare()
local found = 0
for dx = -2, 2 do
    for dy = -2, 2 do
        local sq = getCell():getGridSquare(square:getX() + dx, square:getY() + dy, square:getZ())
        if sq then
            local objects = sq:getObjects()
            for i = 0, objects:size() - 1 do
                local o = objects:get(i)
                if instanceof(o, "IsoDoor") or instanceof(o, "IsoWindow") then
                    found = found + 1
                    say("object", tostring(o:getSprite():getName()), "locked", tostring(Actions.isLocked(o)),
                        "reinforced", tostring(Actions.isReinforced(o)))
                end
            end
        end
    end
end
say("doors and windows within 2 tiles", found)
say("a reinforced door (forceLocked) needs rank 2: with rank 1 the option is greyed with a tooltip")
