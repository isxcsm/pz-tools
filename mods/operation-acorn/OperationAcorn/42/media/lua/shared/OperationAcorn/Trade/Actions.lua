-- Timed actions of the trade part: putting a thing (the terminal, a delivery box, a crate) down, using the terminal, sealing a
-- box, dismantling an abandoned one and opening a sealed crate. Each names squares and kinds, not objects, and checks
-- again as it completes, where the world is decided (Trade.Things).
require "TimedActions/ISBaseTimedAction"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Things"
local OA = OperationAcorn
local Trade = OA.Trade
local Objects, Things = Trade.Objects, Trade.Things
local Actions = {}
Trade.Actions = Actions

-- The record of the character doing it (made when missing: the server may meet a character before its hello).
local function recordOf(character)
    local id = OA.Store.idOf(character)
    local name = character.getUsername and character:getUsername() or nil
    return OA.Store.ensure(id, name)
end
Actions.recordOf = recordOf

-- A refusal told to the player: a translation key of IGUI_OA_Trade_Reason_<reason>.
local function refuse(character, reason)
    OA.Sync.notice(OA.Store.idOf(character), "IGUI_OA_Trade_Reason_" .. tostring(reason))
end

local function fixedDuration(ticks)
    return function(self)
        if self.character:isTimedActionInstant() then return 1 end
        return ticks
    end
end

-- The common part: the character faces the square and works low; ticks of the action.
local function base(name, ticks, anim)
    local action = ISBaseTimedAction:derive(name)
    if ticks then action.getDuration = fixedDuration(ticks) end
    function action:waitToStart()
        self.character:faceLocation(self.x, self.y)
        return self.character:shouldBeTurning()
    end
    function action:update() self.character:faceLocation(self.x, self.y) end
    function action:start()
        self:setActionAnim(anim or "Loot")
        self.character:SetVariable("LootPosition", "Low")
    end
    function action:perform() ISBaseTimedAction.perform(self) end
    return action
end

local function squareOf(self)
    return getCell():getGridSquare(self.x, self.y, self.z)
end

-- Puts a carried thing down (kind terminal, box or crate) on a square. `facing` is S, E, N or W (a terminal's).
ISOAPlaceThing = base("ISOAPlaceThing", 150)

function ISOAPlaceThing:isValid()
    local square = squareOf(self)
    if not square or not OA.inInventory(self.item, self.character) then return false end
    if self.kind == Objects.DELIVERY_BOX then return Objects.clearSquare(square) end
    return Objects.free(square)
end

function ISOAPlaceThing:complete()
    local square = squareOf(self)
    if not square then return false end
    local ok, why
    if self.kind == Objects.TERMINAL then
        ok, why = Things.placeTerminal(self.character, square, self.facing, self.item, recordOf(self.character))
    else
        ok, why = Things.placeBox(self.character, recordOf(self.character), square, self.item)
    end
    if not ok then refuse(self.character, why) end
    return true
end

function ISOAPlaceThing:new(character, kind, item, square, facing)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.item, o.facing = kind, item, facing
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = o:getDuration()
    return o
end

-- Using the terminal: the window opens when the action is done (on the player's side).
ISOAUseTerminal = base("ISOAUseTerminal", 1, "Loot")

function ISOAUseTerminal:isValid()
    local square = squareOf(self)
    return square ~= nil and Objects.find(square, Objects.TERMINAL) ~= nil
end

function ISOAUseTerminal:perform()
    ISBaseTimedAction.perform(self)
    if OA.Terminal and OA.Terminal.open then OA.Terminal.open(self.character, self.x, self.y, self.z) end
end

function ISOAUseTerminal:complete() return true end

function ISOAUseTerminal:new(character, square)
    local o = ISBaseTimedAction.new(self, character)
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = 1
    return o
end

-- Sealing a box, once the player has confirmed the estimate.
ISOASeal = base("ISOASeal", 80)

function ISOASeal:isValid()
    local square = squareOf(self)
    local object = square and Objects.find(square, Objects.DELIVERY_BOX)
    return object ~= nil and not object:getModData()[Objects.SEALED]
end

function ISOASeal:complete()
    local object = Objects.find(squareOf(self), Objects.DELIVERY_BOX)
    if not object then return false end
    -- (true and the entries sealed, or false and why not)
    local ok, result = Things.seal(self.character, recordOf(self.character), object)
    if not ok then
        refuse(self.character, result)
    else
        local count = 0
        for _, e in ipairs(result) do count = count + e.count end
        OA.Sync.notice(OA.Store.idOf(self.character), "IGUI_OA_Trade_Notice_Sealed", { count })
    end
    return true
end

function ISOASeal:new(character, square)
    local o = ISBaseTimedAction.new(self, character)
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = o:getDuration()
    return o
end

-- Dismantling an abandoned box (its owner's character died).
ISOADismantleBox = base("ISOADismantleBox", 200)

function ISOADismantleBox:isValid()
    local square = squareOf(self)
    local object = square and Objects.find(square, Objects.DELIVERY_BOX)
    return object ~= nil and Objects.abandoned(object)
end

function ISOADismantleBox:complete()
    local object = Objects.find(squareOf(self), Objects.DELIVERY_BOX)
    if not object then return false end
    local ok, why = Things.dismantleBox(self.character, object)
    if not ok then refuse(self.character, why) end
    return true
end

function ISOADismantleBox:new(character, square)
    local o = ISBaseTimedAction.new(self, character)
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = o:getDuration()
    return o
end

-- Opening a sealed crate: much quicker with a crowbar.
ISOAUnseal = base("ISOAUnseal", nil)

function ISOAUnseal:isValid()
    local square = squareOf(self)
    local object = square and Objects.find(square, Objects.CRATE)
    return object ~= nil and object:getModData()[Objects.SEALED] == true
end

function ISOAUnseal:complete()
    local object = Objects.find(squareOf(self), Objects.CRATE)
    if not object then return false end
    local ok, why = Things.unseal(self.character, object, recordOf(self.character))
    if not ok then refuse(self.character, why) end
    return true
end

function ISOAUnseal:new(character, square, withCrowbar)
    local o = ISBaseTimedAction.new(self, character)
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = character:isTimedActionInstant() and 1 or (withCrowbar and 120 or 450)
    return o
end

return Actions
