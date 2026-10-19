-- The story's one timed action: the character crouches to take a soil sample, or looks over a survey stake, and at the
-- end tells the server (the server decides; the action only takes the time and plays the animation).
require "TimedActions/ISBaseTimedAction"
require "OperationAcorn/Core"
require "OperationAcorn/Sync"
require "OperationAcorn/Say"
require "OperationAcorn/Sounds"
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

-- A stake's date read by the character (its mod data keeps the dates read): true the first time one is unlike a date
-- read before (the character remarks on it once).
OA.Say.define("StakeDiff", {})
function ISOAStoryAction.stakeDate(character, date)
    if type(date) ~= "number" then return false end
    local md = character:getModData()
    md.OA_StakeDates = md.OA_StakeDates or {}
    local dates = md.OA_StakeDates
    local unlike = false
    for d in pairs(dates) do
        if d ~= date then unlike = true end
    end
    dates[date] = true
    if not unlike or md.OA_StakeDiffSaid then return false end
    md.OA_StakeDiffSaid = true
    return true
end

function ISOAStoryAction:perform()
    if self.kind == "soil" then
        OA.Sync.send(self.character, "story_soil", {})
    elseif self.kind == "stake" then
        OA.Sync.send(self.character, "story_stake", { stake = self.detail.stake })
        local unlike = ISOAStoryAction.stakeDate(self.character, self.detail.date)
        if OA.StoryViewer then
            local character = self.character
            OA.StoryViewer.open(character, { { stake = self.detail.stake, date = self.detail.date, id = "stake", noRecord = true } },
                unlike and function() OA.Say.say(character, "StakeDiff") end or nil)
        end
    end
    ISBaseTimedAction.perform(self)
end

-- Soil taken up by hand is heard; a stake looked over is not (OA.Sounds).
PZUIKit.Sound.timed(ISOAStoryAction, function(action) return action.kind == "soil" and "oa.action.soil" or nil end)
