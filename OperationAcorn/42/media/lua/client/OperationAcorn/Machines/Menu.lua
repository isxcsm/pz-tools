-- The world context menu of the base machines: put a machine down from the inventory, open its window, switch it,
-- shred by hand at the bench, take it up. And the halo notes for worn parts.
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/ISInventoryPaneContextMenu"
require "OperationAcorn/Sync"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Actions"
require "OperationAcorn/Machines/Window"
local OA = OperationAcorn
local Machines = OA.Machines
local Data = Machines.Data
local Menu = {}
Machines.Menu = Menu

local function tooltip(option, description)
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip.description = description
    option.toolTip = tip
end

local function unavailable(option, description)
    option.notAvailable = true
    tooltip(option, description)
end

local function clickedSquare(worldobjects)
    for _, object in ipairs(worldobjects) do
        local square = object:getSquare()
        if square then return square end
    end
    return nil
end

-- Walks next to a square, then does the action.
local function queueAt(playerObj, square, action)
    if square and luautils.walkAdj(playerObj, square, true) then ISTimedActionQueue.add(action) end
end

local function onPlace(playerObj, square, item, kind, dir)
    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
    queueAt(playerObj, square, ISOAMachinePlace:new(playerObj, square, item, kind, dir))
end

local function onOpen(playerObj, object)
    OAMachineWindow.open(playerObj, object)
end

local function onSwitch(playerObj, object, on)
    local state = Machines.state(object)
    OA.Sync.send(playerObj, "machineSwitch", { machine = state.id, on = on })
end

local function onPickUp(playerObj, object)
    local state = Machines.state(object)
    local square = object:getSquare()
    queueAt(playerObj, square, ISOAMachinePickUp:new(playerObj, state.id, square:getX(), square:getY(), square:getZ()))
end

local function onTakeLure(playerObj, object)
    local state = Machines.state(object)
    local square = object:getSquare()
    queueAt(playerObj, square, ISOAMachineTakeLure:new(playerObj, state.id, square:getX(), square:getY(), square:getZ()))
end

-- Queues shredding of entries at the bench, an action an item.
local function onShred(playerObj, object, entries)
    local state = Machines.state(object)
    local square = object:getSquare()
    if not luautils.walkAdj(playerObj, square, true) then return end
    for _, entry in ipairs(entries) do
        ISTimedActionQueue.add(
            ISOAMachineShred:new(playerObj, state.id, square:getX(), square:getY(), square:getZ(), entry))
    end
end

-- The bench's submenu: what the character carries that can be shredded, by kind of item, and all of it.
local function addShredMenu(context, playerObj, object)
    local option = context:addOption(getText("ContextMenu_OA_Machine_Shred"), nil, nil)
    local entries = Machines.benchCandidates(playerObj, 300)
    if #entries == 0 then
        unavailable(option, getText("IGUI_OA_Machine_Reason_nothingToShred"))
        return
    end
    local groups, order = {}, {}
    for _, entry in ipairs(entries) do
        local key = entry.item:getFullType()
        if not groups[key] then
            groups[key] = {}
            order[#order + 1] = key
        end
        table.insert(groups[key], entry)
    end
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    sub:addOption(getText("ContextMenu_OA_Machine_ShredAll", #entries), playerObj, onShred, object, entries)
    for i = 1, math.min(#order, 15) do
        local group = groups[order[i]]
        sub:addOption(getText("ContextMenu_OA_Machine_ShredKind", group[1].item:getName(), #group), playerObj,
            onShred, object, group)
    end
end

local function addMachineOptions(context, playerObj, object)
    local state = Machines.state(object)
    local kind = state.kind
    local option = context:addOptionOnTop(Machines.name(kind), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)

    if Data.hasWindow(kind) then
        sub:addOption(getText("ContextMenu_OA_Machine_Open"), playerObj, onOpen, object)
    end
    if Data.processes(kind) then
        local off = state.on == false
        local switch = sub:addOption(getText(off and "ContextMenu_OA_Machine_SwitchOn" or "ContextMenu_OA_Machine_SwitchOff"),
            playerObj, onSwitch, object, off)
        if off then
            local ok, why = Machines.canSwitchOn(object)
            if not ok then unavailable(switch, why) end
        end
    end
    if Data.KINDS[kind].hand then addShredMenu(sub, playerObj, object) end

    -- a machine is taken up with the game's furniture tool (Moveables.lua); a lure is taken back while it works (with
    -- the hours it has left) or cleared away once it is spent
    if kind == "lure" then
        if Machines.canTakeLure(object) then
            sub:addOption(getText("ContextMenu_OA_Machine_TakeLure"), playerObj, onTakeLure, object)
        else
            sub:addOption(getText("ContextMenu_OA_Machine_RemoveShell"), playerObj, onPickUp, object)
        end
    end
    -- what the machine is, on the first option of its submenu (on the machine's own option it would cover the submenu)
    local first = sub.options and sub.options[1]
    if first and not first.toolTip then tooltip(first, getText("Tooltip_OA_Machine_" .. kind)) end
end

-- The lure is put down from its item; the machines are furniture, put down with the game's furniture tool.
local PLACED_FROM_ITEM = { "lure" }

local function addPlaceOptions(context, playerObj, square)
    local inventory = playerObj:getInventory()
    for _, kind in ipairs(PLACED_FROM_ITEM) do
        local item = inventory:getFirstTypeRecurse(Machines.itemFullType(kind))
        if item then
            local dir = Machines.facing(square, playerObj)
            local option = context:addOption(getText("ContextMenu_OA_Machine_Place", Machines.name(kind)), playerObj,
                onPlace, square, item, kind, dir)
            local ok, reason = Machines.canPlace(kind, square, dir)
            if not ok then unavailable(option, getText("IGUI_OA_Machine_Reason_" .. reason))
            else tooltip(option, getText("Tooltip_OA_Machine_" .. kind)) end
        end
    end
end

function Menu.fill(player, context, worldobjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(player)
    local square = clickedSquare(worldobjects)
    if not playerObj or not square then return end
    local object = Machines.at(square)
    if object then addMachineOptions(context, playerObj, object) end
    addPlaceOptions(context, playerObj, square)
end

Events.OnFillWorldObjectContextMenu.Add(Menu.fill)

-- The notes the machines send (worn and broken parts): shown over the character they are for.
OA.Sync.listen("notice", function(playerId, detail)
    if type(detail) ~= "table" or type(detail.key) ~= "string" then return end
    if not string.find(detail.key, "^IGUI_OA_Machine_") then return end
    local player = getPlayer()
    if not player or OA.Store.idOf(player) ~= playerId then return end
    local args = detail.args or {}
    player:setHaloNote(getText(detail.key, args[1], args[2]))
end)

return Menu
