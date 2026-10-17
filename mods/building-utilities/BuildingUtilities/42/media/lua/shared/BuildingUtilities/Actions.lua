-- Timed actions: laying and taking away lines, upgrading a box, putting in a pipe, throwing its lever, learning its
-- design and taking one apart, brushing snow off a solar panel, replacing a filter's media, reconditioning a battery. A device, a unit or a
-- producer is wired in and out at itself, with the tool of its utility in hand (Actions.work).
-- Each names panels and squares, not objects, and checks again as it completes, where the world is decided
-- (BU.Changes).
require "TimedActions/ISBaseTimedAction"
require "BuildingUtilities/Changes"
require "BuildingUtilities/Costs"
local BU = BuildingUtilities
local Store, Panels, Units, Changes, Costs, Links = BU.Store, BU.Panels, BU.Units, BU.Changes, BU.Costs, BU.Links
local Actions = {}
BU.Actions = Actions

local function giveItem(character, itemType)
    local inventory = character:getInventory()
    local item = inventory:AddItem(itemType)
    if item then sendAddItemToContainer(inventory, item) end
end

-- What a line costs, or nil with a reason (and the tier that reaches, for "needsTier") when it cannot be laid; then
-- what it is laid for and where it hangs (Links.placeOn). kind: "producer" (a square of the panel's utility),
-- "outside" (a device, x, y, z and its sprite), "unit" (a unit at x, y, z, its id extra; priced as a producer's line
-- of its utility, and only the tool for one in the zone), "rehang" (a cut branch's first line, its ref extra, hung on
-- again: a line of its utility).
function Actions.lineCost(kind, panel, utility, x, y, z, extra)
    if not panel then return nil, "noPanel" end
    if kind == "producer" then
        if not BU.enabled(utility) then return nil, "disabled" end
        if Links.get(Links.producerRef(x, y, z)) then return nil, "connectedElsewhere" end
        local square = getCell():getGridSquare(x, y, z)
        if square and Panels.producerOn(square) ~= utility then return nil, "noProducer" end
        local place, reason, tier = Links.placeOn(panel, utility, x, y, z)
        if not place then return nil, reason, tier end
        return Costs.producer(utility, place.length), nil, place
    elseif kind == "outside" then
        return Actions.outsideCost(panel, utility, Panels.device(panel, utility, BU.thingKey(x, y, z, extra))
            or Panels.deviceAt(utility, x, y, z, extra))
    elseif kind == "unit" then
        local unit = Store.unit(extra)
        if not unit then return nil, "noUnit" end
        local place, reason, tier = Units.canConnect(unit, panel)
        if not place then return nil, reason, tier end
        if place.length == 0 then return Costs.tool(Units.utility(unit)), unit, place end
        return Costs.producer(Units.utility(unit), place.length), unit, place
    elseif kind == "rehang" then
        local line = Links.get(extra)
        if not line or Links.cutHead(extra) ~= line then return nil, "notCut" end
        local except = {}
        for _, each in ipairs(Links.branch(extra)) do except[each.ref] = true end
        local place, reason, tier = Links.placeOn(panel, line.utility, x, y, z, Links.isRelay(extra), except)
        if not place then return nil, reason, tier end
        local unit = Links.unitOf(extra)
        if unit and BU.RELAY_KINDS[unit.kind] then
            local ok, why = BU.Relays.canHang(unit, panel)
            if not ok then return nil, why end
        end
        return Costs.producer(line.utility, place.length), line, place
    end
    return nil, "noPanel"
end

-- What wiring a device or a unit out takes: the tool of its utility.
function Actions.workCost(utility) return Costs.tool(utility) end

-- The work at a device: facing it, the tool of its utility in hand (a screwdriver, a pipe wrench).
function Actions.work(action, utility)
    action:setActionAnim("VehicleWorkOnMid")
    local tag = ItemTag[utility == "water" and "PIPE_WRENCH" or "SCREWDRIVER"]
    local tool = tag and action.character:getInventory():getFirstTagRecurse(tag)
    if tool then action:setOverrideHandModels(tool, nil) end
end

-- What the line of a device outside costs, from the device as Panels.devices (or Panels.deviceAt) gives it (a menu
-- or a window that has the panel's devices already does not ask the API for them again); nil with a reason (and a
-- tier) when it cannot be laid; then the device and where its line hangs.
function Actions.outsideCost(panel, utility, device)
    if not device or device.inside then return nil, "noDevice" end
    if device.state == "other" then return nil, "connectedElsewhere" end
    if device.wired then return nil, "connected" end
    if utility == "power" and not BU.exteriorPower() then return nil, "exteriorOff" end
    local entry = device.entry
    local place, reason, tier = Links.placeOn(panel, utility, entry.x, entry.y, entry.z)
    if not place then return nil, reason, tier end
    return Costs.outside(utility, place.length), device, place
end

-- How long laying a line takes: longer the farther it goes.
local function lineDuration(character, steps)
    if character:isTimedActionInstant() then return 1 end
    return math.min(1000, 100 + 15 * (steps or 0))
end

-- A getDuration of so many ticks; one for a character whose actions are instant.
local function fixedDuration(ticks)
    return function(self)
        if self.character:isTimedActionInstant() then return 1 end
        return ticks
    end
end

-- The common part: the character faces the square the action is at, and loots low; it takes so many ticks, when
-- given (else the action has its own getDuration).
local function base(name, ticks)
    local action = ISBaseTimedAction:derive(name)
    if ticks then action.getDuration = fixedDuration(ticks) end
    function action:waitToStart()
        self.character:faceLocation(self.x, self.y)
        return self.character:shouldBeTurning()
    end
    function action:update() self.character:faceLocation(self.x, self.y) end
    function action:start()
        self:setActionAnim("Loot")
        self.character:SetVariable("LootPosition", "Low")
    end
    function action:perform() ISBaseTimedAction.perform(self) end
    return action
end

-- Laying a line: a producer, an outside device, a unit, or a cut branch's first line hung on again (see
-- Actions.lineCost). The cost is worked out as the action is made; each tick only checks that nothing took the place
-- meanwhile (not the character's inventory), and complete checks it all.
ISBUConnect = base("ISBUConnect")

function ISBUConnect:cost()
    return Actions.lineCost(self.kind, Store.get(self.panelId), self.utility, self.x, self.y, self.z, self.extra)
end

function ISBUConnect:isValid()
    local panel = Store.get(self.panelId)
    if not panel or not self.costNow then return false end
    if self.kind == "producer" then return Links.get(Links.producerRef(self.x, self.y, self.z)) == nil end
    if self.kind == "outside" then return Store.inclusionOwner(self.utility, BU.thingKey(self.x, self.y, self.z, self.extra)) == nil end
    if self.kind == "rehang" then return Links.get(self.extra) ~= nil end
    local unit = Store.unit(self.extra)
    return unit ~= nil and Links.get(Links.unitRef(unit)) == nil
end

function ISBUConnect:start() Actions.work(self, self.utility) end

function ISBUConnect:complete()
    local panel = Store.get(self.panelId)
    local cost, other, place = self:cost()
    if not cost or not Costs.affords(self.character, cost) then return false end
    local paid = Costs.take(self.character, cost)
    if self.kind == "producer" then Changes.connectProducer(panel, self.utility, self.x, self.y, self.z, paid, place)
    elseif self.kind == "outside" then Changes.includeOutside(panel, self.utility, other, paid, place)
    elseif self.kind == "rehang" then Changes.rehang(self.extra, panel, place, paid)
    else Changes.connectUnit(other, panel, paid, place) end
    -- Wiring teaches; plumbing has no skill of its own. Two for each piece of wire the line takes.
    if self.utility == "power" then BU.giveXp(self.character, 2 * Costs.count(cost, Costs.WIRE)) end
    return true
end

function ISBUConnect:getDuration()
    return lineDuration(self.character, self.steps)
end

function ISBUConnect:new(character, kind, panel, utility, x, y, z, extra)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.panelId, o.utility, o.x, o.y, o.z, o.extra = kind, panel.id, utility, x, y, z, extra
    local cost, _, place = o:cost()
    o.costNow, o.steps = cost, place and place.length or 0
    o.maxTime = o:getDuration()
    return o
end

-- Taking a line away, with a share of what it took back, with the tool of its utility.
ISBUDisconnect = base("ISBUDisconnect", 120)

-- The line taken away: of a producer, a device outside or a unit (its ref), of the box or of none any more (a cut
-- branch whose box is gone: panelId nil).
function ISBUDisconnect:ref()
    if self.kind == "producer" then return Links.producerRef(self.x, self.y, self.z) end
    if self.kind == "outside" then return Links.deviceRef(BU.thingKey(self.x, self.y, self.z, self.extra)) end
    local unit = Store.unit(self.extra)
    return unit and Links.unitRef(unit) or nil
end

function ISBUDisconnect:connected()
    local line = Links.get(self:ref())
    return line ~= nil and line.panel == self.panelId and line.utility == self.utility
end

function ISBUDisconnect:isValid()
    if not Costs.affords(self.character, Actions.workCost(self.utility)) then return false end
    return self:connected()
end

function ISBUDisconnect:start() Actions.work(self, self.utility) end

function ISBUDisconnect:complete()
    if not self:connected() then return false end
    Costs.refund(self.character, Changes.unlay(self:ref()))
    return true
end

-- panel: the box the line is of, or nil for a cut branch's whose box is gone.
function ISBUDisconnect:new(character, kind, panel, utility, x, y, z, extra)
    local o = ISBaseTimedAction.new(self, character)
    o.kind, o.panelId, o.utility, o.x, o.y, o.z, o.extra = kind, panel and panel.id, utility, x, y, z, extra
    o.maxTime = o:getDuration()
    return o
end

-- Upgrading a box to carry more. What it takes is checked as it is queued and as it completes, not each tick.
ISBUUpgradePanel = base("ISBUUpgradePanel", 400)

function ISBUUpgradePanel:cost()
    local panel = Store.get(self.panelId)
    return panel and Costs.upgrade((panel.tier or 1) + 1) or nil
end

function ISBUUpgradePanel:isValid() return self:cost() ~= nil end

function ISBUUpgradePanel:complete()
    local cost = self:cost()
    if not cost or not Costs.affords(self.character, cost) then return false end
    Costs.take(self.character, cost)
    local panel = Store.get(self.panelId)
    Changes.upgrade(panel)
    BU.giveXp(self.character, 15 * (panel.tier - 1))
    BU.Sync.title(self.character, "tier", panel.tier)
    return true
end

function ISBUUpgradePanel:new(character, panel)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId, o.x, o.y = panel.id, panel.x, panel.y
    o.maxTime = o:getDuration()
    return o
end

-- A new pipe put in at the box: the next colour (BU.Water.nextPipe). What it takes is checked as it is queued and as
-- it completes, not each tick.
ISBUAddPipe = base("ISBUAddPipe", 200)

function ISBUAddPipe:isValid()
    local panel = Store.get(self.panelId)
    return panel ~= nil and BU.Water.nextPipe(panel) ~= nil
end

function ISBUAddPipe:start()
    Actions.work(self, "water")
end

function ISBUAddPipe:complete()
    local panel = Store.get(self.panelId)
    if not panel or not BU.Water.nextPipe(panel) or not Costs.affords(self.character, Costs.addPipe()) then return false end
    Changes.addPipe(panel, Costs.take(self.character, Costs.addPipe()))
    return true
end

function ISBUAddPipe:new(character, panel)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId, o.x, o.y = panel.id, panel.x, panel.y
    o.maxTime = o:getDuration()
    return o
end

-- A pipe taken out at the box, a pipe wrench in hand: what was on it goes on the first (Changes.removePipe), and the
-- sandbox's share of the pipes it took comes back (as a line's, Costs.refund).
ISBURemovePipe = base("ISBURemovePipe", 200)

function ISBURemovePipe:isValid()
    local panel = Store.get(self.panelId)
    return panel ~= nil and self.pipe ~= BU.Water.FIRST and BU.Water.pipe(panel, self.pipe) ~= nil
end

function ISBURemovePipe:start()
    Actions.work(self, "water")
end

function ISBURemovePipe:complete()
    local panel = Store.get(self.panelId)
    local pipe = panel and BU.Water.pipe(panel, self.pipe)
    if not pipe or self.pipe == BU.Water.FIRST or not Costs.affords(self.character, Costs.removePipe()) then return false end
    local paid = pipe.paid
    Changes.removePipe(panel, self.pipe)
    Costs.refund(self.character, paid)
    return true
end

function ISBURemovePipe:new(character, panel, pipe)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId, o.pipe, o.x, o.y = panel.id, pipe, panel.x, panel.y
    o.maxTime = o:getDuration()
    return o
end

-- Brushing the snow off a solar panel.
ISBUClearSnow = base("ISBUClearSnow", 120)

function ISBUClearSnow:isValid()
    local unit = Store.unit(self.unitId)
    return unit ~= nil and BU.Energy.snowOf(unit) > 0
end

function ISBUClearSnow:complete()
    local unit = Store.unit(self.unitId)
    if unit then
        Changes.clearSnow(unit)
        Units.show(unit)
    end
    return unit ~= nil
end

function ISBUClearSnow:new(character, unit)
    local o = ISBaseTimedAction.new(self, character)
    o.unitId, o.x, o.y = unit.id, unit.x, unit.y
    o.maxTime = o:getDuration()
    return o
end

-- A filter's media replaced: the charcoal and cloth a charge takes (BU.WaterUnits.MEDIA) used up; whether the
-- character has them is checked as it completes, not each tick.
ISBUReplaceMedia = base("ISBUReplaceMedia", 200)

function ISBUReplaceMedia:isValid()
    local unit = Store.unit(self.unitId)
    return unit ~= nil and BU.WaterUnits.mediaLeft(unit) < 1
end

function ISBUReplaceMedia:complete()
    local unit = Store.unit(self.unitId)
    if not unit or not BU.WaterUnits.hasMedia(self.character) then return false end
    local inventory = self.character:getInventory()
    for _, need in ipairs(BU.WaterUnits.MEDIA) do
        for _ = 1, need.count do
            local item = BU.WaterUnits.mediaItem(inventory, need)
            if item then
                local container = item:getContainer()
                container:DoRemoveItem(item)
                sendRemoveItemFromContainer(container, item)
            end
        end
    end
    Changes.replaceMedia(unit)
    Units.show(unit)
    return true
end

function ISBUReplaceMedia:new(character, unit)
    local o = ISBaseTimedAction.new(self, character)
    o.unitId, o.x, o.y = unit.id, unit.x, unit.y
    o.maxTime = o:getDuration()
    return o
end

-- Learning the box's design at one (Panels.reverseEngineerProblem): the cover opened and the wiring looked into with
-- a screwdriver. The box stays as it is. A bare box (Panels.isBare) has no record: its tile at x, y, z is looked for.
ISBUReverseEngineer = base("ISBUReverseEngineer", 600)

local function learnedFrom(action)
    if action.panelId then return Store.get(action.panelId) end
    local square = getCell():getGridSquare(action.x, action.y, action.z)
    return square and Panels.bareOn(square) or nil
end

function ISBUReverseEngineer:isValid() return learnedFrom(self) ~= nil end

function ISBUReverseEngineer:start() Actions.work(self, "power") end

function ISBUReverseEngineer:complete()
    if not learnedFrom(self) or Panels.reverseEngineerProblem(self.character) then return false end
    self.character:learnRecipe(Panels.RECIPE)
    BU.giveXp(self.character, 10)
    self.character:Say(getText("IGUI_BU_SayLearnedBox"))
    return true
end

-- panel: a box's record, or a bare box's place ({ x, y, z }).
function ISBUReverseEngineer:new(character, panel)
    local o = ISBaseTimedAction.new(self, character)
    o.panelId, o.x, o.y, o.z = panel.id, panel.x, panel.y, panel.z
    o.maxTime = o:getDuration()
    return o
end

-- A bare box made a box where it stands (Changes.activate), where a box may be put (Panels.canInstall): as if taken up
-- and put down again, so nothing is needed but the time. Its tile at x, y, z is looked for.
ISBUActivateBox = base("ISBUActivateBox", 150)

local function bareAt(action)
    local square = getCell():getGridSquare(action.x, action.y, action.z)
    return square and Panels.bareOn(square) or nil, square
end

function ISBUActivateBox:isValid() return bareAt(self) ~= nil end

function ISBUActivateBox:complete()
    local object, square = bareAt(self)
    if not object or not Panels.canInstall(square) then return false end
    BU.Changes.activate(object)
    BU.giveXp(self.character, 5)
    return true
end

function ISBUActivateBox:new(character, x, y, z)
    local o = ISBaseTimedAction.new(self, character)
    o.x, o.y, o.z = x, y, z
    o.maxTime = o:getDuration()
    return o
end

-- Taking a box apart, as an item (Costs.takeApart): its control boards (Costs.boardsIn its tier), some wire and parts.
ISBUTakeApartBox = ISBaseTimedAction:derive("ISBUTakeApartBox")
ISBUTakeApartBox.getDuration = fixedDuration(300)

function ISBUTakeApartBox:isValid() return self.character:getInventory():contains(self.item) end

function ISBUTakeApartBox:start()
    self:setActionAnim(CharacterActionAnims.Craft)
end

function ISBUTakeApartBox:perform() ISBaseTimedAction.perform(self) end

function ISBUTakeApartBox:complete()
    local inventory = self.character:getInventory()
    if not inventory:contains(self.item) or not Costs.affords(self.character, Costs.takeApart()) then return false end
    local boards = Costs.boardsIn(Panels.itemTier(self.item))
    inventory:Remove(self.item)
    sendRemoveItemFromContainer(inventory, self.item)
    for _ = 1, boards do giveItem(self.character, Costs.BOARD) end
    for _, part in ipairs(Costs.TAKE_APART) do
        for _ = 1, part[2] do giveItem(self.character, part[1]) end
    end
    BU.giveXp(self.character, 5)
    return true
end

function ISBUTakeApartBox:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.maxTime = o:getDuration()
    return o
end

-- Reconditioning a worn battery with baking soda (Rack.canRevive): better by Rack.REVIVE_GAIN, a few times.
ISBUReviveBattery = ISBaseTimedAction:derive("ISBUReviveBattery")
ISBUReviveBattery.getDuration = fixedDuration(400)

-- The baking soda is looked for as it completes, not each tick.
function ISBUReviveBattery:isValid() return self.character:getInventory():contains(self.item) end

function ISBUReviveBattery:start()
    self:setActionAnim(CharacterActionAnims.Craft)
end

function ISBUReviveBattery:perform() ISBaseTimedAction.perform(self) end

function ISBUReviveBattery:complete()
    if not BU.Rack.canRevive(self.character, self.item) then return false end
    -- The uses it takes (Rack.REVIVE_SODA), from one box after another.
    local left = BU.Rack.REVIVE_SODA
    for _, box in ipairs((BU.Rack.bakingSoda(self.character:getInventory()))) do
        local take = math.min(left, box:getCurrentUses())
        for _ = 1, take do box:UseAndSync() end
        left = left - take
        if left <= 0 then break end
    end
    local item = self.item
    item:setCondition(math.min(item:getConditionMax(), item:getCondition() + BU.Rack.REVIVE_GAIN))
    item:getModData()[BU.Rack.REVIVED] = (item:getModData()[BU.Rack.REVIVED] or 0) + 1
    item:syncItemFields()
    BU.giveXp(self.character, 10)
    return true
end

function ISBUReviveBattery:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.maxTime = o:getDuration()
    return o
end

return Actions
