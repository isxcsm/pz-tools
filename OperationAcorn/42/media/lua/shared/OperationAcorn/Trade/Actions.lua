-- Timed actions of the trade part: putting the terminal, a delivery box and a crate down and taking them up, opening
-- the terminal, sealing a box, loading a box in bulk, opening and breaking a crate. Each names squares and kinds, not
-- objects, and checks again as it completes, where the world is decided (Trade.Things).
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
    if not square or not self.character:getInventory():contains(self.item) then return false end
    if self.kind == Objects.DELIVERY_BOX then return Objects.clearSquare(square) end
    return Objects.free(square)
end

function ISOAPlaceThing:complete()
    local square = squareOf(self)
    if not square then return false end
    local ok, why
    if self.kind == Objects.TERMINAL then
        ok, why = Things.placeTerminal(self.character, square, self.facing, self.item, recordOf(self.character))
    elseif self.kind == Objects.DELIVERY_BOX then
        ok, why = Things.placeBox(self.character, recordOf(self.character), square, self.item)
    else
        ok, why = Things.placeCrate(self.character, square, self.item)
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

-- Takes a thing up to carry it (or breaks a crate down with `breakDown`).
ISOATakeThing = base("ISOATakeThing", 120)

function ISOATakeThing:isValid()
    local square = squareOf(self)
    return square ~= nil and Objects.find(square, self.kind) ~= nil
end

function ISOATakeThing:complete()
    local object = Objects.find(squareOf(self), self.kind)
    if not object then return false end
    local ok, why
    if self.kind == Objects.TERMINAL then
        ok, why = Things.takeTerminal(self.character, object)
    elseif self.kind == Objects.DELIVERY_BOX then
        ok, why = Things.takeBox(self.character, object)
    elseif self.breakDown then
        ok, why = Things.breakCrate(self.character, object)
    else
        ok, why = Things.takeCrate(self.character, object)
    end
    if not ok then refuse(self.character, why) end
    return true
end

function ISOATakeThing:new(character, kind, square, breakDown)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.breakDown = kind, breakDown
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = breakDown and 200 or o:getDuration()
    if character:isTimedActionInstant() then o.maxTime = 1 end
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
    local ok, why, entries = Things.seal(self.character, recordOf(self.character), object)
    if not ok then
        refuse(self.character, why)
    else
        local count = 0
        for _, e in ipairs(entries) do count = count + e.count end
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

-- Loading a box from the containers and the trunk around it: one action for all the items.
ISOABulkLoad = base("ISOABulkLoad", nil)

function ISOABulkLoad:isValid()
    local square = squareOf(self)
    local object = square and Objects.find(square, Objects.DELIVERY_BOX)
    return object ~= nil and not object:getModData()[Objects.SEALED]
end

function ISOABulkLoad:complete()
    local object = Objects.find(squareOf(self), Objects.DELIVERY_BOX)
    if not object then return false end
    local moved = Things.bulkLoad(self.character, object)
    OA.Sync.notice(OA.Store.idOf(self.character), "IGUI_OA_Trade_Notice_Loaded", { moved })
    return true
end

-- A load takes longer for more items: 40 ticks and 2 more for each item, no more than 600.
function ISOABulkLoad:new(character, square, count)
    local o = ISBaseTimedAction.new(self, character)
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = character:isTimedActionInstant() and 1 or math.min(600, 40 + 2 * (count or 0))
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
    local ok, why = Things.unseal(self.character, object)
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
