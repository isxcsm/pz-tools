-- The base machines' timed actions: putting a machine down and taking it up, putting a part in and taking it out,
-- shredding by hand at the bench. The work is done in complete(), where the world is decided (on a server, there);
-- an action names machines by id and items by id, not by object.
require "TimedActions/ISBaseTimedAction"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
local Data, Logic = Machines.Data, Machines.Logic
local Actions = {}
Machines.Actions = Actions

-- Ticks for so many game minutes of work (a tick is about 1/30 s; a game minute takes dayLength / 24 seconds).
function Actions.ticksForMinutes(minutes)
    local day = 60
    if getSandboxOptions and getSandboxOptions().getDayLengthMinutes then
        day = getSandboxOptions():getDayLengthMinutes() or 60
    end
    return math.max(10, math.floor(minutes * day * 1.25))
end
-- The most one shredding action takes: more items are left for the next one.
Actions.MAX_TICKS = 2400

-- An item of a character's inventory by id (inside bags too), or nil.
function Actions.findItem(character, id)
    if not id then return nil end
    local inventory = character:getInventory()
    local item = inventory:getItemWithIDRecursiv(id)
    if item then return item end
    return inventory:getItemById(id)
end

local function fixedDuration(ticks)
    return function(self)
        if self.character:isTimedActionInstant() then return 1 end
        return ticks
    end
end

-- The common part: the character faces the square the action is at, and loots low; it takes `ticks` (when given).
local function base(name, ticks)
    local action = ISBaseTimedAction:derive(name)
    if ticks then action.getDuration = fixedDuration(ticks) end
    function action:waitToStart()
        self.character:faceLocation(self.x + 0.5, self.y + 0.5)
        return self.character:shouldBeTurning()
    end
    function action:update() self.character:faceLocation(self.x + 0.5, self.y + 0.5) end
    function action:start()
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Low")
    end
    function action:perform() ISBaseTimedAction.perform(self) end
    return action
end

local function removeFromInventory(item)
    local container = item:getContainer()
    if container then
        container:Remove(item)
        sendRemoveItemFromContainer(container, item)
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Putting a machine down

ISOAMachinePlace = base("ISOAMachinePlace", 150)

function ISOAMachinePlace:isValid()
    local item = Actions.findItem(self.character, self.itemId)
    return item ~= nil and Machines.canPlace(self.kind, self.square, self.dir) ~= nil
end

function ISOAMachinePlace:complete()
    local item = Actions.findItem(self.character, self.itemId)
    local square = getCell():getGridSquare(self.x, self.y, self.z)
    if not item or not square or not Machines.canPlace(self.kind, square, self.dir) then return false end
    if self.character.removeFromHands then self.character:removeFromHands(item) end
    Machines.place(self.kind, square, self.character, item, self.dir)
    removeFromInventory(item)
    return true
end

-- dir: the facing the machine is put down with (Machines.facing at the time of the click).
function ISOAMachinePlace:new(character, square, item, kind, dir)
    local o = ISBaseTimedAction.new(self, character)
    o.square, o.kind, o.itemId, o.dir = square, kind, item:getID(), dir or "S"
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = o:getDuration()
    return o
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Taking a machine up

ISOAMachinePickUp = base("ISOAMachinePickUp", 200)

function ISOAMachinePickUp:isValid()
    local object = Machines.find(self.machineId)
    return object ~= nil and Machines.canPickUp(object) ~= nil
end

function ISOAMachinePickUp:complete()
    local object = Machines.find(self.machineId)
    if not object or not Machines.canPickUp(object) then return false end
    Machines.pickUp(object, self.character)
    return true
end

function ISOAMachinePickUp:new(character, id, x, y, z)
    local o = ISBaseTimedAction.new(self, character)
    o.machineId, o.x, o.y, o.z = id, x, y, z
    o.maxTime = o:getDuration()
    return o
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Parts

ISOAMachinePartIn = base("ISOAMachinePartIn", 150)

function ISOAMachinePartIn:isValid()
    local object = Machines.find(self.machineId)
    local item = Actions.findItem(self.character, self.itemId)
    return object ~= nil and item ~= nil and Machines.canInstall(object, self.slot, item) ~= nil
end

function ISOAMachinePartIn:complete()
    local object = Machines.find(self.machineId)
    local item = Actions.findItem(self.character, self.itemId)
    if not object or not item then return false end
    return Machines.installPart(object, self.slot, item, self.character)
end

function ISOAMachinePartIn:new(character, id, x, y, z, slot, item)
    local o = ISBaseTimedAction.new(self, character)
    o.machineId, o.x, o.y, o.z, o.slot, o.itemId = id, x, y, z, slot, item:getID()
    o.maxTime = o:getDuration()
    return o
end

ISOAMachinePartOut = base("ISOAMachinePartOut", 100)

function ISOAMachinePartOut:isValid()
    local object = Machines.find(self.machineId)
    local state = object and Machines.state(object)
    return state ~= nil and state.parts[self.slot] ~= nil
end

function ISOAMachinePartOut:complete()
    local object = Machines.find(self.machineId)
    if not object then return false end
    return Machines.removePart(object, self.slot, self.character)
end

function ISOAMachinePartOut:new(character, id, x, y, z, slot)
    local o = ISBaseTimedAction.new(self, character)
    o.machineId, o.x, o.y, o.z, o.slot = id, x, y, z, slot
    o.maxTime = o:getDuration()
    return o
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The hand bench

ISOAMachineShred = base("ISOAMachineShred")

function ISOAMachineShred:isValid()
    return Machines.find(self.machineId) ~= nil
end

function ISOAMachineShred:complete()
    if not Machines.find(self.machineId) then return false end
    local items = {}
    for _, id in ipairs(self.itemIds) do
        local item = Actions.findItem(self.character, id)
        if item then items[#items + 1] = item end
    end
    local record = OA.Store.ensure(self.playerId, self.character.getUsername and self.character:getUsername() or nil)
    Machines.shredByHand(self.character, record, items)
    OA.Sync.changed("shred", self.playerId)
    return true
end

function ISOAMachineShred:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return self.ticks
end

-- entries: the bench candidates ({ item, data = info }) to shred in this action. Returns the action.
function ISOAMachineShred:new(character, id, x, y, z, entries)
    local o = ISBaseTimedAction.new(self, character)
    o.machineId, o.x, o.y, o.z = id, x, y, z
    o.playerId = OA.Store.idOf(character)
    o.itemIds = {}
    for _, entry in ipairs(entries) do o.itemIds[#o.itemIds + 1] = entry.item:getID() end
    o.ticks = Actions.ticksForMinutes(Machines.benchMinutesFor(entries))
    o.maxTime = o:getDuration()
    return o
end

-- How many of the candidates (in order) fit in one action: their time is under MAX_TICKS, and at least one.
function Actions.fit(entries)
    local picked, minutes = {}, 0
    for _, entry in ipairs(entries) do
        local more = Logic.benchMinutes(math.max(entry.data.weight or 0, 0))
        if #picked > 0 and Actions.ticksForMinutes(minutes + more) > Actions.MAX_TICKS then break end
        picked[#picked + 1] = entry
        minutes = minutes + more
    end
    return picked
end

return Actions
