-- P4: the team's own radio channel. Checks the frequency is saved, that no other channel shares it, and that the
-- channel is in the script manager. Header setup: none. To hear it, tune a radio to the printed frequency at game
-- hour 7, 13 or 19.
RUN("p4_lib.lua")
local say = P4T.say("p4radio")
local f = getGameTime():getModData().OA_RadioFrequency
P4T.check(say, "a frequency is saved", f ~= nil, f)
if not f then return end
local list = getZomboidRadio():getScriptManager():getChannelsList()
local same, mine = 0, false
for i = 0, list:size() - 1 do
    local ch = list:get(i)
    if ch:GetFrequency() == f then
        same = same + 1
        if ch:getGUID() == "OAK-2B-4417" then mine = true end
    end
end
P4T.check(say, "our channel is registered", mine)
P4T.check(say, "no other channel on the frequency", same == 1, same)
say("frequency", f, OperationAcorn.StoryRadio.frequencyText(), "MHz")
