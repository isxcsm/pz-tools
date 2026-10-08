-- The story's one timed action: the character crouches to take a soil sample, or looks over a survey stake, and at the
-- end tells the server (the server decides; the action only takes the time and plays the animation).
require "TimedActions/ISBaseTimedAction"
require "OperationAcorn/Core"
require "OperationAcorn/Sync"
local OA = OperationAcorn

ISOAStoryAction = ISBaseTimedAction:derive("ISOAStoryAction")

-- kind: "soil" | "stake". `detail` is what the finish needs (for a stake: { stake = n, date = i }).
function ISOAStoryAction:new(character, kind, detail, time)
    local o = ISBaseTimedAction.new(self, character)
    o.kind = kind
    o.detail = detail or {}
    o.maxTime = (character:isTimedActionInstant() and 1) or time or 100
    o.stopOnWalk = true
    o.stopOnRun = true
    return o
end

function ISOAStoryAction:isValid()
    return self.character ~= nil and not self.character:isDead()
end

function ISOAStoryAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
end

function ISOAStoryAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISOAStoryAction:perform()
    if self.kind == "soil" then
        OA.Sync.send(self.character, "story_soil", {})
    elseif self.kind == "stake" then
        OA.Sync.send(self.character, "story_stake", { stake = self.detail.stake })
        if OA.StoryViewer then
            OA.StoryViewer.open(self.character, { { stake = self.detail.stake, date = self.detail.date, id = "stake", noRecord = true } })
        end
    end
    ISBaseTimedAction.perform(self)
end
