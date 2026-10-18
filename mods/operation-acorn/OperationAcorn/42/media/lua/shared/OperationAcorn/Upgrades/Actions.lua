-- The timed actions of the upgrades: injecting a serum (or using a cure serum, or a delay drug, or a test kit), prying a
-- locked door, window or car door open with a pry bar, picking its lock with a paper clip and a screwdriver (which cuts
-- its alarm too), and cutting the alarm alone, the lock left as it is (자물쇠 따기 with 경보 읽기). Each checks again as it
-- completes, where the world is decided (complete runs on the server).
require "TimedActions/ISBaseTimedAction"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Upgrades/Serums"
require "OperationAcorn/Upgrades/First"
require "OperationAcorn/Sounds"
local OA = OperationAcorn
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

-- ---- alarms ------------------------------------------------------------------------------------------------------
-- A house's alarm sounds when a character is in one of its rooms or a window of it is broken
-- (IsoGameCharacter.updateInternal, IsoWindow.handleAlarm); a car's when a door, its trunk or its hood is first opened
-- without its key (ISOpenVehicleDoor; once opened, the car is "previously entered" and does not sound). The game has no
-- way for a player to take one off: picking a lock does, and with 경보 읽기 cutting it alone does.

-- The building a door or a window belongs to: its square's, or the square's across it (a wall's door or window sits on
-- the square inside or outside, at its north or west edge).
function Actions.entryBuilding(sq, obj)
    local building = sq:getBuilding()
    if building then return building end
    local x, y = sq:getX(), sq:getY()
    if obj:getNorth() then y = y - 1 else x = x - 1 end
    local other = getCell():getGridSquare(x, y, sq:getZ())
    return other and other:getBuilding()
end

-- Whether a car's alarm can still sound: alarmed, and not opened yet.
function Actions.carAlarmed(vehicle)
    return vehicle:isAlarmed() and not vehicle:isPreviouslyEntered()
end

-- The alarm the target is on: "house" and the building's def, "car" and the vehicle, or nil.
function Actions.alarmOf(target)
    if instanceof(target, "VehiclePart") then
        local vehicle = target:getVehicle()
        if vehicle and Actions.carAlarmed(vehicle) then return "car", vehicle end
        return nil
    end
    if instanceof(target, "IsoDoor") or instanceof(target, "IsoWindow") then
        local sq = target:getSquare()
        local building = sq and Actions.entryBuilding(sq, target)
        local def = building and building:getDef()
        if def and def:isAlarmed() then return "house", def end
    end
    return nil
end

-- Takes the target's alarm off; returns what it was on ("house", "car") or nil when it had none.
function Actions.disarm(target)
    local kind, what = Actions.alarmOf(target)
    if not kind then return nil end
    what:setAlarmed(false)
    if kind == "car" then what:transmitAlarmed() end
    return kind
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
    return OA.inInventory(self.item, self.character)
end

-- The job text on the item while the action runs, by the item's kind (the menu's words for it; a serum of a tree, or a
-- shared one, is injected).
local JOB_TEXT = { cure = "ContextMenu_OA_Tree_UseCure", delay = "ContextMenu_OA_Tree_TakeDelay",
    reversal = "ContextMenu_OA_Tree_UseReversal", test = "ContextMenu_OA_Tree_UseTest" }

-- A test kit is a short wait with a swab's sound; a cure serum is a long dose, with a line of the character's at its
-- start (the same whether or not there is an infection to cure). self.kind is the item's kind (Serums.kind).
function ISOAUseSerum:start()
    if isClient() and self.item then
        self.item = self.character:getInventory():getItemById(self.item:getID())
    end
    self.item:setJobDelta(0.0)
    self.item:setJobType(getText(JOB_TEXT[self.kind] or "ContextMenu_OA_Tree_Inject"))
    if self.kind == "test" then
        -- the wait for a result: working at the kit, a swab's sound until it is over
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Mid")
        self.character:reportEvent("EventLootItem")
        self:setOverrideHandModels(nil, nil)
        self.sound = PZUIKit.Sound.on("oa.serum.test", self.character)
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
    -- At the lock's height, standing: a car's door as the game works on a car's part at waist height
    -- (ISInstallVehiclePart), a door or window's as the game takes broken glass out of a window (ISRemoveBrokenGlass);
    -- prying a door or window as the game pries a barricade off (ISUnbarricadeAction). The tool the menu equipped
    -- (startLock) is in the hand, as the game's own.
    function action:start()
        local tool = self.character:getPrimaryHandItem()
        if instanceof(self.target, "VehiclePart") then
            self:setActionAnim("VehicleWorkOnMid")
        elseif name == "ISOAPryOpen" then
            self:setActionAnim("RemoveBarricade")
        else
            self:setActionAnim("Loot")
            self.character:SetVariable("LootPosition", "Mid")
        end
        self:setOverrideHandModels(tool, nil)
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

-- One try with the clip and the screwdriver (the character has both): quiet; true when it worked, else the clip is
-- bent (lost) and the character says so.
local function pickTry(action, u, clip)
    makeNoise(action.character, action.target, Actions.PICK_NOISE[1], Actions.PICK_NOISE[2])
    if roll(Rules.lockChance(u)) then return true end
    local container = clip:getContainer()
    if container then
        container:DoRemoveItem(clip)
        if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, clip) end
    end
    OA.Sync.notice(action.oaId, "IGUI_OA_Tree_PickFail", {})
    return false
end

local function pickDuration(action)
    if action.character:isTimedActionInstant() then return 1 end
    local record = OA.Store.player(action.oaId)
    local mult = record and Rules.lockTime(Rules.section(record)) or 1
    return math.floor(Actions.PICK_TICKS * mult)
end

local function pickNew(class, character, target)
    local o = ISBaseTimedAction.new(class, character)
    o.target = target
    o.oaId = OA.Store.idOf(character)
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    return o
end

-- Picking with a paper clip and a screwdriver: slow, quiet, usually works. A failure bends the clip (it is lost). A lock
-- picked on an alarmed house or car cuts its alarm too.
ISOAPickLock = lockAction("ISOAPickLock")

function ISOAPickLock:complete()
    local record = OA.Store.ensure(self.oaId, nil)
    local u = Rules.section(record)
    local rank = Rules.rank(u, "lock")
    local clip, driver = Actions.pickTools(self.character)
    if rank < 1 or not clip or not driver then return false end
    if Actions.isReinforced(self.target) and rank < 2 then return false end
    if not pickTry(self, u, clip) then return false end
    Actions.unlock(self.target, false)
    local alarm = Actions.disarm(self.target)
    OA.Sync.notice(self.oaId, alarm and "IGUI_OA_Tree_PickDisarmed" or "IGUI_OA_Tree_PickSuccess", {})
    return true
end

function ISOAPickLock:getDuration() return pickDuration(self) end
function ISOAPickLock:new(character, target) return pickNew(self, character, target) end

-- Cutting the alarm of a door, window or car door alone, locked or not (the lock is left as it is): 자물쇠 따기 with
-- 경보 읽기, the same tools, time, chance and failure as picking, on any door (a reinforced one too: the lock is not worked).
ISOADisarm = lockAction("ISOADisarm")

function ISOADisarm:isValid()
    return stillThere(self.target) and Actions.alarmOf(self.target) ~= nil
end

function ISOADisarm:complete()
    local record = OA.Store.ensure(self.oaId, nil)
    local u = Rules.section(record)
    local clip, driver = Actions.pickTools(self.character)
    if Rules.rank(u, "lock") < 1 or Rules.rank(u, "alarm") < 1 or not clip or not driver then return false end
    if not Actions.alarmOf(self.target) or not pickTry(self, u, clip) then return false end
    Actions.disarm(self.target)
    OA.Sync.notice(self.oaId, "IGUI_OA_Tree_Disarmed", {})
    return true
end

function ISOADisarm:getDuration() return pickDuration(self) end
function ISOADisarm:new(character, target) return pickNew(self, character, target) end

return Actions
