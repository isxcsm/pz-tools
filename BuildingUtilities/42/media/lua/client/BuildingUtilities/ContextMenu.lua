-- The world context menu: install, open, upgrade and take down a breaker box and reset its breaker; lay and take
-- away the lines of generators, water containers, units and outside devices; switch a device of the building; put
-- down and take up solar panels and battery racks (a rack's batteries go in and out in the loot window). The
-- inventory menu: recondition a battery.
require "ISUI/ISWorldObjectContextMenu"
require "BuildingUtilities/Actions"
local BU = BuildingUtilities
local Store, Panels, Units, Rack, Costs, Actions, Sync = BU.Store, BU.Panels, BU.Units, BU.Rack, BU.Costs, BU.Actions,
    BU.Sync
local ContextMenu = {}
BU.ContextMenu = ContextMenu

local function tooltip(option, text)
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip.description = text
    option.toolTip = tip
end

local function unavailable(option, text)
    option.notAvailable = true
    tooltip(option, text)
end

-- An option that lays a line or upgrades: what it needs, and not available when the player lacks it.
local function costed(option, playerObj, cost, note)
    local text = Costs.describe(playerObj, cost)
    if note then text = note .. (text ~= "" and " <LINE> " .. text or "") end
    tooltip(option, text)
    if not Costs.affords(playerObj, cost) then option.notAvailable = true end
end

local function refundNote()
    return BU.costsEnabled() and getText("IGUI_BU_RefundNote", BU.refundPercent()) or nil
end

local function apiMissingText()
    local _, reason = BU.api()
    return getText(reason == "version" and "IGUI_BU_ApiVersion" or "IGUI_BU_ApiMissing")
end

local function clickedSquare(worldobjects)
    for _, object in ipairs(worldobjects) do
        local square = object:getSquare()
        if square then return square end
    end
    return nil
end

local function squareObjects(square)
    local result = {}
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do result[#result + 1] = objects:get(i) end
    return result
end

-- Walks next to the square, then does the action there.
function ContextMenu.queueAt(playerObj, x, y, z, action)
    local square = getCell():getGridSquare(x, y, z)
    if square and luautils.walkAdj(playerObj, square, true) then ISTimedActionQueue.add(action) end
end

local function queueAt(playerObj, x, y, z, action) ContextMenu.queueAt(playerObj, x, y, z, action) end

local function onInstall(playerObj, square, item)
    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
    queueAt(playerObj, square:getX(), square:getY(), square:getZ(), ISBUInstallPanel:new(playerObj, square, item))
end

local function onRemove(playerObj, panel) queueAt(playerObj, panel.x, panel.y, panel.z, ISBURemovePanel:new(playerObj, panel)) end
local function onUpgrade(playerObj, panel) queueAt(playerObj, panel.x, panel.y, panel.z, ISBUUpgradePanel:new(playerObj, panel)) end
local function onOpen(playerObj, panel) BU.PanelWindow.open(playerObj, panel) end
local function onReset(playerObj, panel) Sync.send(playerObj, "resetBreaker", { panel = panel.id }) end

local function onConnect(playerObj, kind, panel, utility, x, y, z, extra)
    queueAt(playerObj, x, y, z, ISBUConnect:new(playerObj, kind, panel, utility, x, y, z, extra))
end

local function onDisconnect(playerObj, kind, panel, utility, x, y, z, extra)
    queueAt(playerObj, x, y, z, ISBUDisconnect:new(playerObj, kind, panel, utility, x, y, z, extra))
end

local function onInside(playerObj, panel, utility, device, connected)
    Sync.send(playerObj, "setInside", { panel = panel.id, utility = utility, key = device.key, on = connected })
end

local function addPanelOptions(context, playerObj, panel)
    -- The breaker is power's: with power off in the sandbox it is not told.
    local tripped = panel.tripped and BU.enabled("power")
    local name = tripped and getText("IGUI_BU_NameTripped", Panels.name(panel)) or Panels.name(panel)
    local option = context:addOptionOnTop(name, nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    local open = sub:addOption(getText("ContextMenu_BU_Open"), playerObj, onOpen, panel)
    if not BU.api() then unavailable(open, apiMissingText()) end
    if tripped then sub:addOption(getText("ContextMenu_BU_ResetBreaker"), playerObj, onReset, panel) end
    if (panel.tier or 1) < BU.TIERS then
        local upgrade = sub:addOption(getText("ContextMenu_BU_Upgrade", (panel.tier or 1) + 1), playerObj, onUpgrade, panel)
        costed(upgrade, playerObj, Costs.upgrade((panel.tier or 1) + 1), Panels.upgradeNote((panel.tier or 1) + 1))
    end
    local remove = sub:addOption(getText("ContextMenu_BU_Remove"), playerObj, onRemove, panel)
    if refundNote() then tooltip(remove, refundNote()) end
end

local function addInstallOption(context, playerObj, square)
    local item = BU.enabled("panel") and playerObj:getInventory():getFirstTypeRecurse(BU.PANEL_ITEM)
    if not item then return end
    local option = context:addOption(getText("ContextMenu_BU_Install"), playerObj, onInstall, square, item)
    local building, reason = Panels.canInstall(square)
    if not building then
        unavailable(option, reason == "noApi" and apiMissingText() or getText("IGUI_BU_Reason_" .. reason))
    end
end

-- "Connect to a panel": the main panels in reach of the top tier (Panels.producerCandidates), each with what its
-- line costs, or why not. A producer's line (kind "producer") or a unit's ("unit", extra its id).
local function addConnectOption(context, playerObj, kind, utility, x, y, z, extra)
    local option = context:addOption(getText("ContextMenu_BU_ConnectTo"), nil, nil)
    local candidates = Panels.producerCandidates(x, y, z)
    if #candidates == 0 then
        unavailable(option, getText("IGUI_BU_NoPanelInRange", BU.producerRange(BU.TIERS)))
        return
    end
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, candidate in ipairs(candidates) do
        local panel = candidate.panel
        local choice = sub:addOption(getText("IGUI_BU_PanelChoice", Panels.name(panel), Panels.where(panel, x, y)),
            playerObj, onConnect, kind, panel, utility, x, y, z, extra)
        local cost, reason = Actions.lineCost(kind, panel, utility, x, y, z, extra)
        if not candidate.inRange then
            unavailable(choice, getText("IGUI_BU_NeedsTier", candidate.tier))
        elseif cost then
            costed(choice, playerObj, cost)
        else
            unavailable(choice, getText("IGUI_BU_Reason_" .. reason))
        end
    end
end

local function addProducerOptions(context, playerObj, square)
    local utility = Panels.producerOn(square)
    if not utility then return end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local owner, ownedUtility = Store.producerOwner(x, y, z)
    if owner then
        local option = context:addOption(getText("ContextMenu_BU_DisconnectFrom", Panels.name(owner)), playerObj, onDisconnect,
            "producer", owner, ownedUtility, x, y, z)
        if refundNote() then tooltip(option, refundNote()) end
        return
    end
    addConnectOption(context, playerObj, "producer", utility, x, y, z)
end

-- Units.

local function onInstallUnit(playerObj, kind, square, item)
    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
    queueAt(playerObj, square:getX(), square:getY(), square:getZ(), ISBUInstallUnit:new(playerObj, kind, square, item))
end

local function onRemoveUnit(playerObj, unit) queueAt(playerObj, unit.x, unit.y, unit.z, ISBURemoveUnit:new(playerObj, unit)) end

local function onUnitAction(playerObj, unit, action) queueAt(playerObj, unit.x, unit.y, unit.z, action(playerObj, unit)) end

-- A unit's line and its submenu: what its kind offers (Units.define), its line to a panel, taking it down. One of a
-- kind that is off (BU.enabled) is only taken down.
local function addUnitOptions(context, playerObj, unit)
    local definition = Units.definition(unit.kind)
    local on = BU.enabled(unit.kind)
    local panel = Store.get(unit.panel)
    local title = Units.name(unit)
    if on and definition.title then title = definition.title(unit, title) end
    title = panel and getText("IGUI_BU_UnitWired", title, Panels.name(panel)) or title
    if not on then title = getText("IGUI_BU_UnitOff", title) end
    local option = context:addOptionOnTop(title, nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, entry in ipairs(on and definition.options and definition.options(unit, playerObj) or {}) do
        local choice = sub:addOption(entry.text, playerObj, onUnitAction, unit, entry.action)
        if entry.reason then unavailable(choice, entry.reason) end
    end
    if on and BU.api() then
        if panel then
            local disconnect = sub:addOption(getText("ContextMenu_BU_DisconnectFrom", Panels.name(panel)), playerObj, onDisconnect,
                "unit", panel, Units.utility(unit), unit.x, unit.y, unit.z, unit.id)
            if refundNote() then tooltip(disconnect, refundNote()) end
        else
            addConnectOption(sub, playerObj, "unit", Units.utility(unit), unit.x, unit.y, unit.z, unit.id)
        end
    end
    local remove = sub:addOption(getText("ContextMenu_BU_Remove"), playerObj, onRemoveUnit, unit)
    if not Units.isEmpty(unit) then
        unavailable(remove, getText(definition.notEmptyReason))
    elseif refundNote() and unit.paid then
        tooltip(remove, refundNote())
    end
end

local function addInstallUnitOptions(context, playerObj, square)
    for _, kind in ipairs(Units.KINDS) do
        local item = BU.enabled(kind) and playerObj:getInventory():getFirstTypeRecurse(Units.definition(kind).item)
        if item then
            local option = context:addOption(getText("ContextMenu_BU_Install_" .. kind), playerObj, onInstallUnit, kind, square, item)
            local ok, reason = Units.canInstall(kind, square)
            if not ok then
                unavailable(option, reason == "noApi" and apiMissingText() or getText("IGUI_BU_Reason_" .. reason))
            end
        end
    end
end

local function addDeviceOption(context, playerObj, utility, panel, device)
    local entry = device.entry
    local name = BU.displayName(entry.x, entry.y, entry.z, entry.sprite)
    local label = getText("ContextMenu_BU_Utility_" .. utility)
    if device.state == "other" then
        local option = context:addOption(getText("ContextMenu_BU_DeviceOn", name, label, Panels.name(panel)), nil, nil)
        local other = Store.inclusionOwner(utility, device.key)
        unavailable(option, getText("IGUI_BU_ConnectedTo", other and Panels.name(other) or ""))
    elseif device.inside then
        local connected = device.state == "on"
        context:addOption(getText(connected and "ContextMenu_BU_DeviceOff" or "ContextMenu_BU_DeviceOn", name, label, Panels.name(panel)),
            playerObj, onInside, panel, utility, device, not connected)
    elseif device.state == "on" then
        local option = context:addOption(getText("ContextMenu_BU_DeviceOff", name, label, Panels.name(panel)), playerObj, onDisconnect,
            "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
        if refundNote() then tooltip(option, refundNote()) end
    else
        local option = context:addOption(getText("ContextMenu_BU_DeviceOn", name, label, Panels.name(panel)), playerObj, onConnect,
            "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
        local cost, reason = Actions.outsideCost(panel, utility, device)
        if cost then costed(option, playerObj, cost) else unavailable(option, getText("IGUI_BU_Reason_" .. reason)) end
    end
end

local function uses(object, utility)
    if utility == "power" then return object:couldBePoweredByGenerator() end
    return object:getProperties() ~= nil and object:getProperties():has(IsoFlagType.waterPiped)
end

-- The square's objects that are devices of a panel, each once: { panel, device, utility }. The panels near the square
-- and their devices are found once for the menu (Panels.deviceOf).
local function squareDevices(square)
    local result, seen, cache = {}, {}, {}
    for _, object in ipairs(squareObjects(square)) do
        for _, utility in ipairs(BU.UTILITIES) do
            if uses(object, utility) then
                local panel, device = Panels.deviceOf(object, utility, cache)
                if panel and not seen[device.key .. utility] then
                    seen[device.key .. utility] = true
                    result[#result + 1] = { panel = panel, device = device, utility = utility }
                end
            end
        end
    end
    return result
end

local function addDeviceOptions(context, playerObj, square)
    for _, found in ipairs(squareDevices(square)) do
        addDeviceOption(context, playerObj, found.utility, found.panel, found.device)
    end
end

-- Whether the menu has an option of this mod for the square, without building it: the controller's test pass.
local function hasOptions(playerObj, square)
    for _, object in ipairs(squareObjects(square)) do
        if Panels.ofObject(object) or Units.ofObject(object) then return true end
    end
    local inventory = playerObj:getInventory()
    if BU.enabled("panel") and inventory:getFirstTypeRecurse(BU.PANEL_ITEM) then return true end
    for _, kind in ipairs(Units.KINDS) do
        if BU.enabled(kind) and inventory:getFirstTypeRecurse(Units.definition(kind).item) then return true end
    end
    if not BU.api() then return false end
    return Panels.producerOn(square) ~= nil or #squareDevices(square) > 0
end

function ContextMenu.fill(player, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    local playerObj = getSpecificPlayer(player)
    local square = clickedSquare(worldobjects)
    if not playerObj or not square then return end
    if test then
        if hasOptions(playerObj, square) then return ISWorldObjectContextMenu.setTest() end
        return
    end
    for _, object in ipairs(squareObjects(square)) do
        local panel = Panels.ofObject(object)
        if panel then addPanelOptions(context, playerObj, panel) end
        local unit = Units.ofObject(object)
        if unit then addUnitOptions(context, playerObj, unit) end
    end
    addInstallOption(context, playerObj, square)
    addInstallUnitOptions(context, playerObj, square)
    if not BU.api() then return end
    addProducerOptions(context, playerObj, square)
    addDeviceOptions(context, playerObj, square)
end

Events.OnFillWorldObjectContextMenu.Add(ContextMenu.fill)

-- Reconditioning a car battery (Rack.canRevive), from the inventory.
local function reviveReason(reason)
    if reason == "revivedOut" then return getText("IGUI_BU_Reason_revivedOut", Rack.REVIVE_TIMES) end
    if reason == "notWorn" then return getText("IGUI_BU_Reason_notWorn", Rack.REVIVE_BELOW) end
    if reason == "skill" then return getText("IGUI_BU_Reason_skill", Rack.REVIVE_SKILL) end
    return getText("IGUI_BU_Reason_" .. reason)
end

local function onRevive(playerObj, item)
    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
    ISTimedActionQueue.add(ISBUReviveBattery:new(playerObj, item))
end

function ContextMenu.fillInventory(player, context, items)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or #items ~= 1 then return end
    local item = items[1]
    if not instanceof(item, "InventoryItem") then item = item.items and item.items[1] end
    if not Rack.isBattery(item) or not BU.enabled("rack") then return end
    local option = context:addOption(getText("ContextMenu_BU_ReviveBattery"), playerObj, onRevive, item)
    local ok, reason = Rack.canRevive(playerObj, item)
    if ok then
        local left = Rack.REVIVE_TIMES - (item:getModData()[Rack.REVIVED] or 0)
        tooltip(option, getText("IGUI_BU_ReviveNote", Rack.REVIVE_GAIN, left))
    else
        unavailable(option, reviveReason(reason))
    end
end

Events.OnFillInventoryObjectContextMenu.Add(ContextMenu.fillInventory)

return ContextMenu
