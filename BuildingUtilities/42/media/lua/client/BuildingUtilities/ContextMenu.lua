-- The world context menu: a box's line, which opens its window (no submenu: what a box does is in its window), and a
-- unit's (a rack's batteries go in and out in the loot window). A device of the box's building is the box's without a
-- line: switched on or off there at once, as at the box. A device outside, a unit or a producer is wired in and out at
-- itself, with the tool of its utility (Actions.work); the box's window lists it once it is wired. What is done with
-- the thing itself (a box's or a rack's window, a unit's state and work) goes to the top of the menu; tying it to a
-- box and taking a line away go to its end, over the game's destroy and walk lines (PZUIKit.Menu), the ties first. A
-- box and the units are taken up with the game's furniture tool (BU.Moveables).
-- The inventory menu: put a box or a unit down (the game's furniture cursor, Moveables.lua), recondition a battery.
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/ISMoveableContextMenu"
require "BuildingUtilities/Actions"
require "BuildingUtilities/Moveables"
require "PZUIKit/Menu"
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

-- An option that ties a thing to a box, or takes a line away: placed at the menu's end (ContextMenu.fill). The game
-- wipes a menu's options when it reuses them.
local function tie(option) option.buPlace = "tie"; return option end
local function removal(option) option.buPlace = "removal"; return option end

-- An option that lays a line or upgrades: what it needs, and not available when the player lacks it.
local function costed(option, playerObj, cost, note)
    local text = Costs.describe(playerObj, cost)
    if note then text = note .. (text ~= "" and " <LINE> " .. text or "") end
    tooltip(option, text)
    if not Costs.affords(playerObj, cost) then option.notAvailable = true end
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

-- The objects on the square clicked, and with each object of several tiles (a sprite grid: a large rain collector, a
-- double fridge, a machine) the objects of its other tiles, each once: a click on any tile of it offers what its one
-- tile with the container, the power or the box's record would.
local function squareObjects(square)
    local result, seen = {}, {}
    local function add(object)
        if seen[object] then return end
        seen[object] = true
        result[#result + 1] = object
    end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do add(objects:get(i)) end
    local cell, z = getCell(), square:getZ()
    for index = 1, #result do
        local object = result[index]
        local sprite = object:getSprite()
        local grid = sprite and sprite:getSpriteGrid()
        if grid then
            local left = object:getSquare():getX() - grid:getSpriteGridPosX(sprite)
            local top = object:getSquare():getY() - grid:getSpriteGridPosY(sprite)
            for gx = 0, grid:getWidth() - 1 do
                for gy = 0, grid:getHeight() - 1 do
                    local other = cell:getGridSquare(left + gx, top + gy, z)
                    local list = other and other ~= square and other:getObjects()
                    for i = 0, list and list:size() - 1 or -1 do
                        local part = list:get(i)
                        local partSprite = part:getSprite()
                        if partSprite and partSprite:getSpriteGrid() == grid then add(part) end
                    end
                end
            end
        end
    end
    return result
end

-- Walks next to the square, then does the action there.
function ContextMenu.queueAt(playerObj, x, y, z, action)
    local square = getCell():getGridSquare(x, y, z)
    if square and luautils.walkAdj(playerObj, square, true) then ISTimedActionQueue.add(action) end
end

local function queueAt(playerObj, x, y, z, action) ContextMenu.queueAt(playerObj, x, y, z, action) end

local function onOpen(playerObj, panel) queueAt(playerObj, panel.x, panel.y, panel.z, ISBUOpenPanel:new(playerObj, panel)) end

local function onConnect(playerObj, kind, panel, utility, x, y, z, extra)
    queueAt(playerObj, x, y, z, ISBUConnect:new(playerObj, kind, panel, utility, x, y, z, extra))
end

local function onDisconnect(playerObj, kind, panel, utility, x, y, z, extra)
    queueAt(playerObj, x, y, z, ISBUDisconnect:new(playerObj, kind, panel, utility, x, y, z, extra))
end

-- "Disconnect from <box>": what it takes (the tool), and not available without it.
local function addDisconnectOption(context, playerObj, panel, kind, utility, x, y, z, extra)
    local option = removal(context:addOption(getText("ContextMenu_BU_DisconnectFrom", Panels.name(panel)), playerObj,
        onDisconnect, kind, panel, utility, x, y, z, extra))
    costed(option, playerObj, Actions.workCost(utility))
end

-- "Connect to <box>" for a device outside or a unit: what its line takes, or why it cannot be laid.
local function addLineConnect(context, playerObj, panel, kind, utility, x, y, z, extra)
    local option = tie(context:addOption(getText("ContextMenu_BU_ConnectToPanel", Panels.name(panel),
        Panels.where(panel, x, y)), playerObj, onConnect, kind, panel, utility, x, y, z, extra))
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

-- "Connect to a panel": a line a panel in reach of the top tier (Panels.producerCandidates), each with what its line
-- costs, or why not; a sub-panel named with the main panel it takes the line on to. A producer's line (kind
-- "producer") or a unit's ("unit", extra its id). No submenu: there are seldom more than one or two.
local function addConnectOption(context, playerObj, kind, utility, x, y, z, extra)
    local candidates = Panels.producerCandidates(x, y, z)
    if #candidates == 0 then
        local option = tie(context:addOption(getText("ContextMenu_BU_ConnectTo"), nil, nil))
        unavailable(option, getText("IGUI_BU_NoPanelInRange", BU.connectRange(BU.TIERS)))
        return
    end
    for _, candidate in ipairs(candidates) do
        local panel = candidate.panel
        local root = Panels.root(panel)
        local name = root ~= panel and getText("IGUI_BU_PanelVia", Panels.name(panel), Panels.name(root)) or Panels.name(panel)
        local choice = tie(context:addOption(getText("ContextMenu_BU_ConnectToPanel", name, Panels.where(panel, x, y)),
            playerObj, onConnect, kind, panel, utility, x, y, z, extra))
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

-- The producer among the objects (Panels.producerOn of their squares), with its square.
local function producerAmong(objects)
    local checked = {}
    for _, object in ipairs(objects) do
        local square = object:getSquare()
        if square and not checked[square] then
            checked[square] = true
            local utility = Panels.producerOn(square)
            if utility then return utility, square end
        end
    end
    return nil
end

local function addProducerOptions(context, playerObj, objects)
    local utility, square = producerAmong(objects)
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

local function onUnitAction(playerObj, unit, action) queueAt(playerObj, unit.x, unit.y, unit.z, action(playerObj, unit)) end

local function onOpenRack(playerObj, unit) queueAt(playerObj, unit.x, unit.y, unit.z, ISBUOpenRack:new(playerObj, unit)) end

-- A unit's lines, no submenu: a rack's name, which opens its window (BU.RackWindow); another's state, when its kind
-- shows one (Units.define title); what its kind offers now (Units.define: clearing snow, a new filter charge); wired,
-- taking its line away; not wired, the boxes in reach it can be wired to. The unit is taken up with the furniture
-- tool. One of a kind that is off (BU.enabled) is only named.
local function addUnitOptions(context, playerObj, unit)
    local definition = Units.definition(unit.kind)
    local on = BU.enabled(unit.kind)
    local panel = Store.get(unit.panel)
    local name = Units.name(unit)
    local title = on and definition.title and definition.title(unit, name) or name
    if not on then
        context:addOptionOnTop(getText("IGUI_BU_UnitOff", name), nil, nil).isDisabled = true
    elseif unit.kind == "rack" then
        -- A rack opens its own window, wired or not (BU.RackWindow).
        context:addOptionOnTop(panel and getText("IGUI_BU_UnitWired", title, Panels.name(panel)) or title, playerObj,
            onOpenRack, unit)
    elseif title ~= name then
        -- What it is doing (snow on it, running, its filter's charge); the box it is wired to is in the line below.
        context:addOptionOnTop(title, nil, nil).isDisabled = true
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
        unavailable(tie(context:addOption(getText("ContextMenu_BU_ConnectTo"), nil, nil)),
            getText("IGUI_BU_NoPanelInRange", BU.connectRange(BU.TIERS)))
    end
    for _, candidate in ipairs(candidates) do
        addLineConnect(context, playerObj, candidate.panel, "unit", utility, unit.x, unit.y, unit.z, unit.id)
    end
end

local function addDeviceOption(context, playerObj, utility, panel, device)
    local entry = device.entry
    local name = BU.displayName(entry.x, entry.y, entry.z, entry.sprite)
    local label = getText("ContextMenu_BU_Utility_" .. utility)
    if device.state == "other" then
        local option = tie(context:addOption(getText("ContextMenu_BU_DeviceOn", name, label, Panels.name(panel)), nil, nil))
        local other = Store.inclusionOwner(utility, device.key)
        unavailable(option, getText("IGUI_BU_ConnectedTo", other and Panels.name(other) or ""))
        return option
    end
    local on = device.state == "on"
    local text = getText(on and "ContextMenu_BU_DeviceOff" or "ContextMenu_BU_DeviceOn", name, label, Panels.name(panel))
    if device.wired then
        local option = tie(context:addOption(text, playerObj, onSwitchInside, panel, utility, device.key, not on))
        if not device.inside then
            local line = removal(context:addOption(getText("ContextMenu_BU_LineRemove", name, label, Panels.name(panel)),
                playerObj, onDisconnect, "outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite))
            costed(line, playerObj, Actions.workCost(utility))
        end
        return option
    else
        local option = tie(context:addOption(text, playerObj, onConnect, "outside", panel, utility, entry.x, entry.y, entry.z,
            entry.sprite))
        local cost, reason = Actions.lineCost("outside", panel, utility, entry.x, entry.y, entry.z, entry.sprite)
        if cost then costed(option, playerObj, cost) else unavailable(option, getText("IGUI_BU_Reason_" .. reason)) end
        return option
    end
end

local function uses(object, utility)
    if utility == "power" then return object:couldBePoweredByGenerator() end
    return object:getProperties() ~= nil and object:getProperties():has(IsoFlagType.waterPiped)
end

-- The objects that are devices of a panel, each once: { panel, device, utility }. The panels near each object's square
-- and their devices are found once for the menu (Panels.deviceOf).
local function squareDevices(objects)
    local result, seen, cache = {}, {}, {}
    for _, object in ipairs(objects) do
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

local function addDeviceOptions(context, playerObj, objects)
    for _, found in ipairs(squareDevices(objects)) do
        addDeviceOption(context, playerObj, found.utility, found.panel, found.device)
    end
end

-- Whether the menu has an option of this mod for the square, without building it: the controller's test pass.
local function hasOptions(objects)
    for _, object in ipairs(objects) do
        if Panels.ofObject(object) or Units.ofObject(object) then return true end
    end
    if not BU.api() then return false end
    return producerAmong(objects) ~= nil or #squareDevices(objects) > 0
end

-- The options the mod added to the menu (those not in `before`, the options it had) in their places: what is done with
-- the thing itself to the top in their order (the game puts its own and other mods' before them), the ties and then the
-- removals over the menu's end (PZUIKit.Menu).
local function placeAdded(context, before)
    local options = context.options
    local added, others, ends, removals = {}, {}, {}, {}
    for _, option in ipairs(options) do
        if before[option] then others[#others + 1] = option
        elseif option.buPlace == "tie" then ends[#ends + 1] = option
        elseif option.buPlace == "removal" then removals[#removals + 1] = option
        else added[#added + 1] = option end
    end
    if #added > 0 then
        for index = #options, 1, -1 do options[index] = nil end
        for _, option in ipairs(added) do options[#options + 1] = option end
        for _, option in ipairs(ends) do options[#options + 1] = option end
        for _, option in ipairs(removals) do options[#options + 1] = option end
        for _, option in ipairs(others) do options[#options + 1] = option end
        for index, option in ipairs(options) do option.id = index end
    end
    for _, option in ipairs(removals) do ends[#ends + 1] = option end
    PZUIKit.Menu.beforeTail(context, ends)
end

function ContextMenu.fill(player, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    local playerObj = getSpecificPlayer(player)
    local square = clickedSquare(worldobjects)
    if not playerObj or not square then return end
    if test then
        if hasOptions(squareObjects(square)) then return ISWorldObjectContextMenu.setTest() end
        return
    end
    local objects = squareObjects(square)
    local before = {}
    for _, option in ipairs(context.options) do before[option] = true end
    for _, object in ipairs(objects) do
        local panel = Panels.ofObject(object)
        if panel then addPanelOptions(context, playerObj, panel) end
        local unit = Units.ofObject(object)
        if unit then addUnitOptions(context, playerObj, unit) end
    end
    if BU.api() then
        addProducerOptions(context, playerObj, objects)
        addDeviceOptions(context, playerObj, objects)
    end
    placeAdded(context, before)
end

Events.OnFillWorldObjectContextMenu.Add(ContextMenu.fill)

-- Putting a box or a unit down from the inventory: its item is the game's furniture (Moveables.lua), put down with the
-- game's furniture cursor in its place mode, turned with its rotate key.
local function onPlace(playerObj, item)
    BU.giveTile(item)
    ISMoveableContextMenu.openMovableCursor(item, playerObj)
end

-- What an item puts down: "panel" for a box, a unit's kind, or nil.
local function placedKind(item)
    local fullType = item:getFullType()
    if fullType == BU.PANEL_ITEM then return "panel" end
    for _, kind in ipairs(Units.KINDS) do
        if Units.definition(kind).item == fullType then return kind end
    end
    return nil
end

-- Takes out of the menu the game's own place option for the item (it opens the same cursor; this mod's stays).
local function dropGamesOwn(context, item)
    local name = getText("IGUI_PlaceObject")
    for _, option in ipairs(context.options) do
        if option.name == name and option.target == item and option.onSelect == ISMoveableContextMenu.openMovableCursor then
            context:removeOptionByName(name)
            return
        end
    end
end

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
    if not item then return end
    -- The game offers placing only from the inventory proper and not from the hands (ISMoveableContextMenu); so here.
    local kind = placedKind(item)
    if kind then
        dropGamesOwn(context, item)
        if BU.enabled(kind) and item:getContainer() == playerObj:getInventory()
            and playerObj:getPrimaryHandItem() ~= item and playerObj:getSecondaryHandItem() ~= item then
            local text = getText(kind == "panel" and "ContextMenu_BU_Install" or "ContextMenu_BU_Install_" .. kind)
            local option = context:addOptionOnTop(text, playerObj, onPlace, item)
            option.itemForTexture = item
            if not BU.api() then unavailable(option, apiMissingText()) end
        end
    end
    if not Rack.isBattery(item) or not BU.enabled("rack") then return end
    local option = context:addOptionOnTop(getText("ContextMenu_BU_ReviveBattery"), playerObj, onRevive, item)
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
