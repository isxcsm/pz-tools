-- The timed actions of the upgrades: injecting a serum (or using a cure serum, or a delay drug, or a test kit), prying a
-- locked door, window or car door open with a pry bar, picking its lock with a paper clip and a screwdriver. Each checks
-- again as it completes, where the world is decided (complete runs on the server).
require "TimedActions/ISBaseTimedAction"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Upgrades/Serums"
require "OperationAcorn/Upgrades/First"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Serums = OA.Upgrades.Serums
local First = OA.Upgrades.First
local Actions = {}
OA.Upgrades.Actions = Actions

-- Sprite names of reinforced doors this mod's tiles add (the sprites with the forceLocked property are reinforced
-- too, whoever made them). Filled by the parts that add such doors.
Actions.REINFORCED_SPRITES = {}

-- Prying: how long (ticks), the noise it makes (radius, volume), the effort a failure costs.
Actions.PRY_TICKS = 90
Actions.PRY_NOISE = { 22, 40 }
Actions.PRY_QUIET = { 12, 22 }
Actions.PRY_ENDURANCE = 0.06
Actions.PRY_FATIGUE = 0.02
-- Using a serum: how long (ticks). The cure serum takes the longest (DESIGN-terminal 17.6), the test kit is a short wait
-- for the result.
Actions.USE_TICKS = 120
Actions.CURE_TICKS = 300
Actions.TEST_TICKS = 90
-- The game's sound of wiping with an alcohol wipe (ISDisinfect plays it), for the wait of a test.
Actions.TEST_SOUND = "FirstAidApplyAlcoholWipes"
-- Picking: how long (ticks) at rank 1 (rank 2 halves it), and how quiet.
Actions.PICK_TICKS = 300
Actions.PICK_NOISE = { 3, 4 }

local function notBroken(item) return not item:isBroken() end

-- The tools. The pry bar is any item with the crowbar or pry bar tag; the pick is a paper clip with a screwdriver.
function Actions.pryBar(character)
    local inventory = character:getInventory()
    return inventory:getFirstTagEvalRecurse(ItemTag.CROWBAR, notBroken)
        or inventory:getFirstTagEvalRecurse(ItemTag.PRY_BAR, notBroken)
end

function Actions.pickTools(character)
    local inventory = character:getInventory()
    local clip = inventory:getFirstTypeRecurse("Base.Paperclip")
    local driver = inventory:getFirstTagEvalRecurse(ItemTag.SCREWDRIVER, notBroken)
    return clip, driver
end

-- Whether a door, window or car door part is locked, and whether it is reinforced (forceLocked, or on the list of
-- this mod's reinforced sprites; a window locked for good counts too).
function Actions.isLocked(target)
    if instanceof(target, "IsoDoor") then return target:isLocked() or target:isLockedByKey() end
    if instanceof(target, "IsoWindow") then return target:isLocked() or target:isPermaLocked() end
    if instanceof(target, "VehiclePart") then
        local door = target:getDoor()
        return door ~= nil and door:isLocked()
    end
    return false
end

function Actions.isReinforced(target)
    if instanceof(target, "IsoDoor") then
        local sprite = target:getSprite()
        if target:getProperties():has("forceLocked") then return true end
        local name = sprite and sprite:getName()
        return name ~= nil and Actions.REINFORCED_SPRITES[name] == true
    end
    if instanceof(target, "IsoWindow") then return target:isPermaLocked() end
    return false
end

-- Unlocks the target: a door with the doors it is one half of (double and garage doors open together), a window, a
-- car door (its lock stays broken when it was pried).
function Actions.unlock(target, broken)
    if instanceof(target, "IsoDoor") then
        local all = { target }
        for _, other in ipairs(buildUtil.getDoubleDoorObjects(target)) do all[#all + 1] = other end
        for _, other in ipairs(buildUtil.getGarageDoorObjects(target)) do all[#all + 1] = other end
        for _, door in ipairs(all) do
            door:setLockedByKey(false)
            door:setLocked(false)
        end
    elseif instanceof(target, "IsoWindow") then
        target:setPermaLocked(false)
        target:setIsLocked(false)
    elseif instanceof(target, "VehiclePart") then
        local vehicle = target:getVehicle()
        target:getDoor():setLocked(false)
        if broken then target:getDoor():setLockBroken(true) end
        vehicle:transmitPartDoor(target)
    end
end

-- The square the action is at, for facing it and for the noise.
local function where(target, character)
    if instanceof(target, "VehiclePart") then
        local v = target:getVehicle()
        return v:getX(), v:getY(), v:getZ()
    end
    local square = target:getSquare()
    if square then return square:getX(), square:getY(), square:getZ() end
    return character:getX(), character:getY(), character:getZ()
end

local function faceTarget(character, target)
    if instanceof(target, "VehiclePart") then
        character:faceThisObject(target:getVehicle())
    else
        character:faceThisObject(target)
    end
end

local function stillThere(target)
    if instanceof(target, "VehiclePart") then return target:getDoor() ~= nil end
    return target:getObjectIndex() ~= -1
end

-- ---- serums ---------------------------------------------------------------------------------------------------

ISOAUseSerum = ISBaseTimedAction:derive("ISOAUseSerum")

function ISOAUseSerum:isValid()
    if isClient() and self.item then
        return self.character:getInventory():containsID(self.item:getID())
    end
    return self.character:getInventory():contains(self.item)
end

-- A test kit is a short wait with a swab's sound; a cure serum is a long dose, with a line of the character's at its
-- start (the same whether or not there is an infection to cure). self.kind is the item's kind (Serums.kind).
function ISOAUseSerum:start()
    if isClient() and self.item then
        self.item = self.character:getInventory():getItemById(self.item:getID())
    end
    self.item:setJobDelta(0.0)
    self.item:setJobType(getText("ContextMenu_OA_Tree_Inject"))
    if self.kind == "test" then
        -- the wait for a result: working at the kit, a swab's sound until it is over
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Mid")
        self.character:reportEvent("EventLootItem")
        self:setOverrideHandModels(nil, nil)
        self.sound = self.character:playSound(Actions.TEST_SOUND)
    elseif self.kind == "cure" and self.character:isLocalPlayer() then
        OA.Say.say(self.character, "CureStart")
    end
end

function ISOAUseSerum:update()
    self.item:setJobDelta(self:getJobDelta())
    if self.kind ~= "test" then self:setActionAnim(CharacterActionAnims.TakePills) end
end

function ISOAUseSerum:stopSound()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:stopOrTriggerSound(self.sound)
    end
    self.sound = nil
end

function ISOAUseSerum:stop()
    self:stopSound()
    ISBaseTimedAction.stop(self)
    self.item:setJobDelta(0.0)
end

function ISOAUseSerum:perform()
    self:stopSound()
    self.item:setJobDelta(0.0)
    ISBaseTimedAction.perform(self)
end

function ISOAUseSerum:complete()
    return Serums.use(self.character, self.item, self.oaId)
end

function ISOAUseSerum:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    if self.kind == "cure" then return Actions.CURE_TICKS end
    if self.kind == "test" then return Actions.TEST_TICKS end
    return Actions.USE_TICKS
end

function ISOAUseSerum:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.kind = Serums.kind(item:getType())
    o.oaId = OA.Store.idOf(character)
    o.stopOnWalk = false
    o.stopOnRun = true
    o.stopOnAim = false
    o.maxTime = o:getDuration()
    return o
end

-- ---- prying and picking -----------------------------------------------------------------------------------------

-- The common part of both: face the lock, work low, check the target is still locked and still there.
local function lockAction(name)
    local action = ISBaseTimedAction:derive(name)
    function action:isValid()
        return stillThere(self.target) and Actions.isLocked(self.target)
    end
    function action:waitToStart()
        faceTarget(self.character, self.target)
        return self.character:shouldBeTurning()
    end
    function action:update()
        faceTarget(self.character, self.target)
    end
    function action:start()
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Low")
    end
    function action:perform() ISBaseTimedAction.perform(self) end
    return action
end

local function makeNoise(character, target, radius, volume)
    local x, y, z = where(target, character)
    addSound(character, x, y, z, radius, volume)
end

local function roll(chance)
    return OA.random(1, 100) <= math.floor(chance * 100 + 0.5)
end

-- Prying with a pry bar: quick and loud, and it often fails. A failure costs endurance and fatigue.
ISOAPryOpen = lockAction("ISOAPryOpen")

function ISOAPryOpen:complete()
    local record = OA.Store.ensure(self.oaId, nil)
    local u = Rules.section(record)
    local rank = Rules.rank(u, "crowbar")
    if rank < 1 or not Actions.pryBar(self.character) then return false end
    if Actions.isReinforced(self.target) and rank < 2 then return false end
    local noise = rank >= 2 and Actions.PRY_QUIET or Actions.PRY_NOISE
    makeNoise(self.character, self.target, noise[1], noise[2])
    if roll(Rules.crowbarChance(u)) then
        Actions.unlock(self.target, true)
        OA.Sync.notice(self.oaId, "IGUI_OA_Tree_PrySuccess", {})
        First.grant(record, "crowbar")
        return true
    end
    local stats = self.character:getStats()
    stats:remove(CharacterStat.ENDURANCE, Actions.PRY_ENDURANCE)
    stats:set(CharacterStat.FATIGUE, math.min(1, stats:get(CharacterStat.FATIGUE) + Actions.PRY_FATIGUE))
    OA.Sync.notice(self.oaId, "IGUI_OA_Tree_PryFail", {})
    return false
end

function ISOAPryOpen:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return Actions.PRY_TICKS
end

function ISOAPryOpen:new(character, target)
    local o = ISBaseTimedAction.new(self, character)
    o.target = target
    o.oaId = OA.Store.idOf(character)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end

-- Picking with a paper clip and a screwdriver: slow, quiet, usually works. A failure bends the clip (it is lost).
ISOAPickLock = lockAction("ISOAPickLock")

function ISOAPickLock:complete()
    local record = OA.Store.ensure(self.oaId, nil)
    local u = Rules.section(record)
    local rank = Rules.rank(u, "lock")
    local clip, driver = Actions.pickTools(self.character)
    if rank < 1 or not clip or not driver then return false end
    if Actions.isReinforced(self.target) and rank < 2 then return false end
    makeNoise(self.character, self.target, Actions.PICK_NOISE[1], Actions.PICK_NOISE[2])
    if roll(Rules.lockChance(u)) then
        Actions.unlock(self.target, false)
        OA.Sync.notice(self.oaId, "IGUI_OA_Tree_PickSuccess", {})
        return true
    end
    local container = clip:getContainer()
    if container then
        container:DoRemoveItem(clip)
        if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, clip) end
    end
    OA.Sync.notice(self.oaId, "IGUI_OA_Tree_PickFail", {})
    return false
end

function ISOAPickLock:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    local record = OA.Store.player(self.oaId)
    local mult = record and Rules.lockTime(Rules.section(record)) or 1
    return math.floor(Actions.PICK_TICKS * mult)
end

function ISOAPickLock:new(character, target)
    local o = ISBaseTimedAction.new(self, character)
    o.target = target
    o.oaId = OA.Store.idOf(character)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end

return Actions
