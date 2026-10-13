-- The base machines' timed actions: putting a machine down and taking it up, putting a part in and taking it out,
-- shredding by hand at the bench. The work is done in complete(), where the world is decided (on a server, there);
-- an action names machines by id and items by id, not by object.
require "TimedActions/ISBaseTimedAction"
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
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

-- An item of a character's inventory by id (inside bags too), or nil. A search of the whole inventory: for the moment an
-- action completes, not for the checks that run every tick (those use heldItem).
function Actions.findItem(character, id)
    if not id then return nil end
    local inventory = character:getInventory()
    local item = inventory:getItemWithIDRecursiv(id)
    if item then return item end
    return inventory:getItemById(id)
end

-- The item an action works on, for the checks that run every tick (isValid, update): the object the action was made
-- with, as long as it is in the character's inventory (a walk up from its container, no search). Only when the action
-- has no object (made again from its ids) or the object left the inventory is the inventory searched, once; what that
-- finds is kept.
function Actions.heldItem(action)
    local item = action.item
    if item and OA.inInventory(item, action.character) then return item end
    -- oa-scan: ok (an action made from ids, or the item moved: once, and kept)
    item = Actions.findItem(action.character, action.itemId)
    action.item = item
    return item
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
    local item = Actions.heldItem(self)
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
    o.square, o.kind, o.item, o.itemId, o.dir = square, kind, item, item:getID(), dir or "S"
    o.x, o.y, o.z = square:getX(), square:getY(), square:getZ()
    o.maxTime = o:getDuration()
    return o
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Opening a machine's window, once the character has walked up to it (the window is the client's).

ISOAMachineOpen = base("ISOAMachineOpen", 1)

function ISOAMachineOpen:isValid()
    return Machines.find(self.machineId) ~= nil
end

function ISOAMachineOpen:perform()
    ISBaseTimedAction.perform(self)
    local object = Machines.find(self.machineId)
    if object and OAMachineWindow and OAMachineWindow.open then OAMachineWindow.open(self.character, object) end
end

function ISOAMachineOpen:complete() return true end

function ISOAMachineOpen:new(character, id, x, y, z)
    local o = ISBaseTimedAction.new(self, character)
    o.machineId, o.x, o.y, o.z = id, x, y, z
    o.maxTime = 1
    return o
end

-- Taking a machine up

ISOAMachinePickUp = base("ISOAMachinePickUp", 200)

function ISOAMachinePickUp:isValid()
    local object = Machines.find(self.machineId)
    return object ~= nil and Machines.canPickUp(object) ~= nil
end

function ISOAMachinePickUp:complete()
    local object = Machines.find(self.machineId)
    if not object or not Machines.canPickUp(object) then return false end
    Machines.pickUp(object)
    return true
end

function ISOAMachinePickUp:new(character, id, x, y, z)
    local o = ISBaseTimedAction.new(self, character)
    o.machineId, o.x, o.y, o.z = id, x, y, z
    o.maxTime = o:getDuration()
    return o
end

-- Taking a working lure back as its item (with the hours it has left).
ISOAMachineTakeLure = base("ISOAMachineTakeLure", 100)

function ISOAMachineTakeLure:isValid()
    local object = Machines.find(self.machineId)
    return object ~= nil and Machines.canTakeLure(object)
end

function ISOAMachineTakeLure:complete()
    local object = Machines.find(self.machineId)
    if not object then return false end
    Machines.takeLure(object, self.character)
    return true
end

function ISOAMachineTakeLure:new(character, id, x, y, z)
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
    local item = Actions.heldItem(self)
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
    o.machineId, o.x, o.y, o.z, o.slot, o.item, o.itemId = id, x, y, z, slot, item, item:getID()
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
    return Machines.find(self.machineId) ~= nil and Actions.heldItem(self) ~= nil
end

function ISOAMachineShred:complete()
    if not Machines.find(self.machineId) then return false end
    local item = Actions.findItem(self.character, self.itemId)
    if not item then return false end
    local record = OA.Store.ensure(self.playerId, self.character.getUsername and self.character:getUsername() or nil)
    Machines.shredByHand(self.character, record, { item })
    OA.Sync.changed("shred", self.playerId)
    return true
end

-- The item shows the action on its row, as the game's actions show on the item they work.
function ISOAMachineShred:update()
    self.character:faceLocation(self.x + 0.5, self.y + 0.5)
    local item = self.item
    if item then
        item:setJobType(getText("IGUI_OA_Machine_Job_shred"))
        item:setJobDelta(self:getJobDelta())
    end
end

function ISOAMachineShred:stop()
    local item = self.item
    if item then item:setJobDelta(0) end
    ISBaseTimedAction.stop(self)
end

function ISOAMachineShred:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return self.ticks
end

-- One item an action (as the game rips clothes one by one): it goes the moment its bar is full and the next starts.
-- entry: a bench candidate ({ item, data = info }). Returns the action.
function ISOAMachineShred:new(character, id, x, y, z, entry)
    local o = ISBaseTimedAction.new(self, character)
    o.machineId, o.x, o.y, o.z = id, x, y, z
    o.playerId = OA.Store.idOf(character)
    o.item, o.itemId = entry.item, entry.item:getID()
    o.ticks = Actions.ticksForMinutes(Machines.benchMinutesFor({ entry }))
    o.maxTime = o:getDuration()
    return o
end

return Actions
