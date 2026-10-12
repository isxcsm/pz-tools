-- The world context menu: install a breaker box, and open its window (one line, no submenu: what a box does is in
-- its window); put down solar panels and battery racks (a rack's batteries go in and out in the loot window). A
-- device of the box's building is the box's without a line: switched on or off there at once, as at the box. A device
-- outside, a unit or a producer is wired in and out at itself, with the tool of its utility (Actions.work); the box's
-- window lists it once it is wired. A box and the units are taken up with the game's furniture tool (BU.Moveables).
-- The inventory menu: recondition a battery.
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

-- A device's line moved up to its object: right under the options for that object at the top of the menu (another
-- mod's "use" put on top), else on top. A mod whose options come later and go on top still lands above it.
local function placeByObject(context, option, object)
    local options = context.options
    local at, from, leading = 1, nil, true
    for index, other in ipairs(options) do
        if other == option then
            from = index
        elseif leading and other.target == object then
            at = index + 1
        else
            leading = false
        end
    end
    if not from or from == at then return end
    table.remove(options, from)
    if at > from then at = at - 1 end
    table.insert(options, at, option)
    for index, other in ipairs(options) do other.id = index end
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

local function onOpen(playerObj, panel) queueAt(playerObj, panel.x, panel.y, panel.z, ISBUOpenPanel:new(playerObj, panel)) end

local function onConnect(playerObj, kind, panel, utility, x, y, z, extra)
    queueAt(playerObj, x, y, z, ISBUConnect:new(playerObj, kind, panel, utility, x, y, z, extra))
end

local function onDisconnect(playerObj, kind, panel, utility, x, y, z, extra)
    queueAt(playerObj, x, y, z, ISBUDisconnect:new(playerObj, kind, panel, utility, x, y, z, extra))
end

-- "Disconnect from <box>": what it takes (the tool), and not available without it.
local function addDisconnectOption(context, playerObj, panel, kind, utility, x, y, z, extra)
    local option = context:addOption(getText("ContextMenu_BU_DisconnectFrom", Panels.name(panel)), playerObj, onDisconnect,
        kind, panel, utility, x, y, z, extra)
    costed(option, playerObj, Actions.workCost(utility))
end

-- "Connect to <box>" for a device outside or a unit: what its line takes, or why it cannot be laid.
local function addLineConnect(context, playerObj, panel, kind, utility, x, y, z, extra)
    local option = context:addOption(getText("ContextMenu_BU_ConnectToPanel", Panels.name(panel), Panels.where(panel, x, y)),
        playerObj, onConnect, kind, panel, utility, x, y, z, extra)
    local cost, reason = Actions.lineCost(kind, panel, utility, x, y, z, extra)
    if cost then costed(option, playerObj, cost) else unavailable(option, getText("IGUI_BU_Reason_" .. reason)) end
end

-- A device of the box's building switched at once, as its tick in the window.
local function onSwitchInside(playerObj, panel, utility, key, on)
    Sync.send(playerObj, "setInside", { panel = panel.id, utility = utility, key = key, on = on })
end

-- The box's line: its name (a tripped breaker told), which walks there and opens its window. The breaker, the main
-- switch, the source, the upgrade and the lines are all in the window.
local function addPanelOptions(context, playerObj, panel)
    -- The breaker is power's: with power off in the sandbox it is not told.
    local tripped = panel.tripped and BU.enabled("power")
    local name = tripped and getText("IGUI_BU_NameTripped", Panels.name(panel)) or Panels.name(panel)
    local option = context:addOptionOnTop(name, playerObj, onOpen, panel)
    if not BU.api() then unavailable(option, apiMissingText()) end
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

-- "Connect to a panel": a line a panel in reach of the top tier (Panels.producerCandidates), each with what its line
-- costs, or why not; a sub-panel named with the main panel it takes the line on to. A producer's line (kind
-- "producer") or a unit's ("unit", extra its id). No submenu: there are seldom more than one or two.
local function addConnectOption(context, playerObj, kind, utility, x, y, z, extra)
    local candidates = Panels.producerCandidates(x, y, z)
    if #candidates == 0 then
        local option = context:addOption(getText("ContextMenu_BU_ConnectTo"), nil, nil)
        unavailable(option, getText("IGUI_BU_NoPanelInRange", BU.producerRange(BU.TIERS)))
        return
    end
    for _, candidate in ipairs(candidates) do
        local panel = candidate.panel
        local root = Panels.root(panel)
        local name = root ~= panel and getText("IGUI_BU_PanelVia", Panels.name(panel), Panels.name(root)) or Panels.name(panel)
        local choice = context:addOption(getText("ContextMenu_BU_ConnectToPanel", name, Panels.where(panel, x, y)),
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
        addDisconnectOption(context, playerObj, owner, "producer", ownedUtility, x, y, z)
        return
    end
    addConnectOption(context, playerObj, "producer", utility, x, y, z)
end

-- Units.

local function onInstallUnit(playerObj, kind, square, item)
    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
    queueAt(playerObj, square:getX(), square:getY(), square:getZ(), ISBUInstallUnit:new(playerObj, kind, square, item))
end

local function onUnitAction(playerObj, unit, action) queueAt(playerObj, unit.x, unit.y, unit.z, action(playerObj, unit)) end

local function onOpenRack(playerObj, unit) queueAt(playerObj, unit.x, unit.y, unit.z, ISBUOpenRack:new(playerObj, unit)) end

-- A unit's lines, no submenu: its name and state, which opens the window of the box it is wired to (a rack's own
-- window, BU.RackWindow); what its kind offers now (Units.define: clearing snow, a new filter charge); wired, taking
-- its line away; not wired, the boxes in reach it can be wired to. The unit is taken up with the furniture tool. One
-- of a kind that is off (BU.enabled) is only named.
local function addUnitOptions(context, playerObj, unit)
    local definition = Units.definition(unit.kind)
    local on = BU.enabled(unit.kind)
    local panel = Store.get(unit.panel)
    local title = Units.name(unit)
    if on and definition.title then title = definition.title(unit, title) end
    title = panel and getText("IGUI_BU_UnitWired", title, Panels.name(panel)) or title
    if not on then title = getText("IGUI_BU_UnitOff", title) end
    if unit.kind == "rack" and on then
        -- A rack opens its own window, wired or not (BU.RackWindow).
        context:addOptionOnTop(title, playerObj, onOpenRack, unit)
    else
        local option = context:addOptionOnTop(title, panel and playerObj or nil, panel and onOpen or nil, panel)
        if panel and not BU.api() then unavailable(option, apiMissingText()) end
    end
    if not on then return end
    for _, entry in ipairs(definition.options and definition.options(unit, playerObj) or {}) do
        local choice = context:addOption(entry.text, playerObj, onUnitAction, unit, entry.action)
        if entry.reason then unavailable(choice, entry.reason) end
    end
    if not BU.api() then return end
    local utility = Units.utility(unit)
    if panel then
        addDisconnectOption(context, playerObj, panel, "unit", utility, unit.x, unit.y, unit.z, unit.id)
        return
    end
    local candidates = Units.candidates(unit)
    if #candidates == 0 then
        unavailable(context:addOption(getText("ContextMenu_BU_ConnectTo"), nil, nil),
            getText("IGUI_BU_NoPanelInRange", BU.producerRange(BU.TIERS)))
    end
    for _, candidate in ipairs(candidates) do
        addLineConnect(context, playerObj, candidate.panel, "unit", utility, unit.x, unit.y, unit.z, unit.id)
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
        return option
    end
    local on = device.state == "on"
    local text = getText(on and "ContextMenu_BU_DeviceOff" or "ContextMenu_BU_DeviceOn", name, label, Panels.name(panel))
    if device.inside then
        return context:addOption(text, playerObj, onSwitchInside, panel, utility, device.key, not on)
    elseif on then
        local option = context:addOption(text, playerObj, onDisconnect, "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
        costed(option, playerObj, Actions.workCost(utility))
        return option
    else
        local option = context:addOption(text, playerObj, onConnect, "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
        local cost, reason = Actions.lineCost("outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
        if cost then costed(option, playerObj, cost) else unavailable(option, getText("IGUI_BU_Reason_" .. reason)) end
        return option
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
                    result[#result + 1] = { panel = panel, device = device, utility = utility, object = object }
                end
            end
        end
    end
    return result
end

local function addDeviceOptions(context, playerObj, square)
    for _, found in ipairs(squareDevices(square)) do
        placeByObject(context, addDeviceOption(context, playerObj, found.utility, found.panel, found.device), found.object)
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
