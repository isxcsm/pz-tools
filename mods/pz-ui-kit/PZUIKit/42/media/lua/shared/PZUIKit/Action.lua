-- The common part of a mod's timed action at a square: the character faces the middle of the square the action is at
-- (self.x, self.y: the square's own coordinates), and loots low; it takes so many ticks when given (else the action has
-- its own getDuration), one with the game's instant actions on.
require "TimedActions/ISBaseTimedAction"
PZUIKit = PZUIKit or {}
local Action = {}
PZUIKit.Action = Action

-- A getDuration of so many ticks.
function Action.fixedDuration(ticks)
    return function(self)
        if self.character:isTimedActionInstant() then return 1 end
        return ticks
    end
end

-- A new timed action class: `name`, `ticks` (or nil), `anim` (the action's animation, "Loot" by default).
function Action.base(name, ticks, anim)
    local action = ISBaseTimedAction:derive(name)
    if ticks then action.getDuration = Action.fixedDuration(ticks) end
    function action:waitToStart()
        self.character:faceLocation(self.x + 0.5, self.y + 0.5)
        return self.character:shouldBeTurning()
    end
    function action:update() self.character:faceLocation(self.x + 0.5, self.y + 0.5) end
    function action:start()
        self:setActionAnim(anim or "Loot")
        self.character:SetVariable("LootPosition", "Low")
    end
    function action:perform() ISBaseTimedAction.perform(self) end
    return action
end
