-- The world context menu: install, open, upgrade and take down a breaker box and reset its breaker; lay and take
-- away the lines of generators, water containers and outside devices; switch a device of the building.
require "ISUI/ISWorldObjectContextMenu"
require "BuildingUtilities/Actions"
local BU = BuildingUtilities
local Store, Panels, Costs, Actions, Sync = BU.Store, BU.Panels, BU.Costs, BU.Actions, BU.Sync
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
    local name = panel.tripped and getText("IGUI_BU_NameTripped", Panels.name(panel)) or Panels.name(panel)
    local option = context:addOptionOnTop(name, nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    local open = sub:addOption(getText("ContextMenu_BU_Open"), playerObj, onOpen, panel)
    if not BU.api() then unavailable(open, apiMissingText()) end
    if panel.tripped then sub:addOption(getText("ContextMenu_BU_ResetBreaker"), playerObj, onReset, panel) end
    if (panel.tier or 1) < BU.TIERS then
        local upgrade = sub:addOption(getText("ContextMenu_BU_Upgrade", (panel.tier or 1) + 1), playerObj, onUpgrade, panel)
        costed(upgrade, playerObj, Costs.upgrade((panel.tier or 1) + 1),
            getText("IGUI_BU_UpgradeNote", string.format("%.2f", BU.capacity((panel.tier or 1) + 1))))
    end
    local remove = sub:addOption(getText("ContextMenu_BU_Remove"), playerObj, onRemove, panel)
    if refundNote() then tooltip(remove, refundNote()) end
end

local function addInstallOption(context, playerObj, square)
    local item = playerObj:getInventory():getFirstTypeRecurse(BU.PANEL_ITEM)
    if not item then return end
    local option = context:addOption(getText("ContextMenu_BU_Install"), playerObj, onInstall, square, item)
    local building, reason = Panels.canInstall(square)
    if not building then
        unavailable(option, reason == "noApi" and apiMissingText() or getText("IGUI_BU_Reason_" .. reason))
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
    local option = context:addOption(getText("ContextMenu_BU_ConnectTo"), nil, nil)
    local candidates = Panels.inProducerRange(x, y, z)
    if #candidates == 0 then
        unavailable(option, getText("IGUI_BU_NoPanelInRange", BU.producerRange()))
        return
    end
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, candidate in ipairs(candidates) do
        local panel = candidate.panel
        local choice = sub:addOption(getText("IGUI_BU_PanelChoice", Panels.name(panel), Panels.where(panel, x, y)),
            playerObj, onConnect, "producer", panel, utility, x, y, z)
        local cost, reason = Actions.lineCost("producer", panel, utility, x, y, z)
        if cost then costed(choice, playerObj, cost) else unavailable(choice, getText("IGUI_BU_Reason_" .. reason)) end
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
        local cost, reason = Actions.lineCost("outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
        if cost then costed(option, playerObj, cost) else unavailable(option, getText("IGUI_BU_Reason_" .. reason)) end
    end
end

local function addDeviceOptions(context, playerObj, square)
    local seen = {}
    for _, object in ipairs(squareObjects(square)) do
        for _, utility in ipairs(BU.UTILITIES) do
            local uses = utility == "power" and object:couldBePoweredByGenerator()
                or utility == "water" and object:getProperties() and object:getProperties():has(IsoFlagType.waterPiped)
            if uses then
                local panel, device = Panels.deviceOf(object, utility)
                if panel and not seen[device.key .. utility] then
                    seen[device.key .. utility] = true
                    addDeviceOption(context, playerObj, utility, panel, device)
                end
            end
        end
    end
end

function ContextMenu.fill(player, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    local playerObj = getSpecificPlayer(player)
    local square = clickedSquare(worldobjects)
    if not playerObj or not square then return end
    for _, object in ipairs(squareObjects(square)) do
        local panel = Panels.ofObject(object)
        if panel then addPanelOptions(context, playerObj, panel) end
    end
    addInstallOption(context, playerObj, square)
    if not BU.api() then return end
    addProducerOptions(context, playerObj, square)
    addDeviceOptions(context, playerObj, square)
end

Events.OnFillWorldObjectContextMenu.Add(ContextMenu.fill)

return ContextMenu
