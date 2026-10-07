-- The world context menu: install, open and remove a breaker box; connect generators and water containers to one;
-- connect or disconnect a device.
require "ISUI/ISWorldObjectContextMenu"
require "BuildingUtilities/Actions"
local BU = BuildingUtilities
local Store, Panels = BU.Store, BU.Panels
local ContextMenu = {}
BU.ContextMenu = ContextMenu

local function unavailable(option, text)
    option.notAvailable = true
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip.description = text
    option.toolTip = tooltip
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

local function onInstall(playerObj, square, item)
    if luautils.walkAdj(playerObj, square) then ISTimedActionQueue.add(ISBUInstallPanel:new(playerObj, square, item)) end
end

local function onRemove(playerObj, panel)
    local object = Panels.object(panel)
    if object and luautils.walkAdj(playerObj, object:getSquare()) then
        ISTimedActionQueue.add(ISBURemovePanel:new(playerObj, panel))
    end
end

local function onOpen(playerObj, panel) BU.PanelWindow.open(playerObj, panel) end

local function onConnectProducer(playerObj, panel, utility, square)
    local ok, reason = Panels.connectProducer(panel, utility, square:getX(), square:getY(), square:getZ())
    if ok then HaloTextHelper.addGoodText(playerObj, getText("IGUI_BU_Connected", Panels.name(panel)))
    else HaloTextHelper.addBadText(playerObj, getText("IGUI_BU_Reason_" .. reason)) end
    BU.PanelWindow.refreshAll()
end

local function onDisconnectProducer(playerObj, panel, utility, index)
    Panels.disconnectProducer(panel, utility, index)
    HaloTextHelper.addText(playerObj, getText("IGUI_BU_Disconnected", Panels.name(panel)))
    BU.PanelWindow.refreshAll()
end

local function onDevice(playerObj, panel, utility, device, connected)
    local ok, reason = Panels.setDevice(panel, utility, device, connected)
    if not ok then HaloTextHelper.addBadText(playerObj, getText("IGUI_BU_Reason_" .. reason)) end
    BU.PanelWindow.refreshAll()
end

local function addPanelOptions(context, playerObj, panel)
    local option = context:addOptionOnTop(Panels.name(panel), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    local open = sub:addOption(getText("ContextMenu_BU_Open"), playerObj, onOpen, panel)
    if not BU.api() then unavailable(open, apiMissingText()) end
    sub:addOption(getText("ContextMenu_BU_Remove"), playerObj, onRemove, panel)
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
    local owner, ownedUtility, index = Store.producerOwner(square:getX(), square:getY(), square:getZ())
    if owner then
        context:addOption(getText("ContextMenu_BU_DisconnectFrom", Panels.name(owner)), playerObj, onDisconnectProducer,
            owner, ownedUtility, index)
        return
    end
    local option = context:addOption(getText("ContextMenu_BU_ConnectTo"), nil, nil)
    if not BU.api() then unavailable(option, apiMissingText()); return end
    local candidates = Panels.inProducerRange(square:getX(), square:getY(), square:getZ())
    if #candidates == 0 then
        unavailable(option, getText("IGUI_BU_NoPanelInRange", BU.producerRange()))
        return
    end
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, candidate in ipairs(candidates) do
        local panel = candidate.panel
        sub:addOption(getText("IGUI_BU_PanelChoice", Panels.name(panel), Panels.where(panel, square:getX(), square:getY())),
            playerObj, onConnectProducer, panel, utility, square)
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
                    local name = BU.displayName(device.entry.x, device.entry.y, device.entry.z, device.entry.sprite)
                    local label = getText("ContextMenu_BU_Utility_" .. utility)
                    if device.state == "on" then
                        context:addOption(getText("ContextMenu_BU_DeviceOff", name, label, Panels.name(panel)), playerObj,
                            onDevice, panel, utility, device, false)
                    elseif device.state == "off" then
                        context:addOption(getText("ContextMenu_BU_DeviceOn", name, label, Panels.name(panel)), playerObj,
                            onDevice, panel, utility, device, true)
                    else
                        local option = context:addOption(getText("ContextMenu_BU_DeviceOn", name, label, Panels.name(panel)), nil, nil)
                        local other = Store.inclusionOwner(utility, device.key)
                        unavailable(option, getText("IGUI_BU_ConnectedTo", other and Panels.name(other) or ""))
                    end
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
