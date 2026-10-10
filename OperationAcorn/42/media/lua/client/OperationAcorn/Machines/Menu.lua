-- The context menus of the base machines. In the world: open a machine's window (switching it is there), shred by hand
-- at the bench, take a lure back. In the inventory: install, on top of the item's menu, the one way to put a machine down (the lure with
-- its own placing cursor, a machine's furniture pieces with the game's furniture cursor). And the halo notes for worn
-- parts. A menu is built from the thing that was clicked: nothing here searches the inventory for it.
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/ISInventoryPaneContextMenu"
require "ISUI/ISInventoryPane"
require "ISUI/ISMoveableContextMenu"
require "OperationAcorn/Sync"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Actions"
require "OperationAcorn/Machines/Window"
local OA = OperationAcorn
local Machines = OA.Machines
local Data = Machines.Data
local Sprites = OA.Sprites
local Menu = {}
Machines.Menu = Menu

local function tooltip(option, description)
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip.description = description
    option.toolTip = tip
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

-- The window opens once the character has walked up to the machine (it closes again when they walk away).
local function onOpen(playerObj, object)
    local state = Machines.state(object)
    local square = Machines.nearSquare(object, playerObj)
    queueAt(playerObj, square, ISOAMachineOpen:new(playerObj, state.id, square:getX(), square:getY(), square:getZ()))
end

local function onPickUp(playerObj, object)
    local state = Machines.state(object)
    local square = Machines.nearSquare(object, playerObj)
    queueAt(playerObj, square, ISOAMachinePickUp:new(playerObj, state.id, square:getX(), square:getY(), square:getZ()))
end

local function onTakeLure(playerObj, object)
    local state = Machines.state(object)
    local square = Machines.nearSquare(object, playerObj)
    queueAt(playerObj, square, ISOAMachineTakeLure:new(playerObj, state.id, square:getX(), square:getY(), square:getZ()))
end

-- Queues shredding of entries at the bench, an action an item.
local function onShred(playerObj, object, entries)
    local state = Machines.state(object)
    local square = Machines.nearSquare(object, playerObj)
    if not luautils.walkAdj(playerObj, square, true) then return end
    for _, entry in ipairs(entries) do
        ISTimedActionQueue.add(
            ISOAMachineShred:new(playerObj, state.id, square:getX(), square:getY(), square:getZ(), entry))
    end
end

-- What the character carries that can be shredded, by kind of item, and all of it: a menu at the mouse, made when the
-- player picks "shred by hand" (looking through the inventory for it is not done while the machine's menu is built).
local function onShredMenu(playerObj, object)
    local entries = Machines.benchCandidates(playerObj, 300)
    if #entries == 0 then
        HaloTextHelper.addBadText(playerObj, getText("IGUI_OA_Machine_Reason_nothingToShred"))
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
    local menu = ISContextMenu.get(playerObj:getPlayerNum(), getMouseX(), getMouseY())
    menu:addOption(getText("ContextMenu_OA_Machine_ShredAll", #entries), playerObj, onShred, object, entries)
    for i = 1, math.min(#order, 15) do
        local group = groups[order[i]]
        menu:addOption(getText("ContextMenu_OA_Machine_ShredKind", group[1].item:getName(), #group), playerObj,
            onShred, object, group)
    end
end

-- A lure is taken back while it works (with the hours it has left) or cleared away once it is spent; a machine is taken
-- up with the game's furniture tool (Moveables.lua).
local function lureOption(menu, playerObj, object, onTop)
    local add = onTop and menu.addOptionOnTop or menu.addOption
    if Machines.canTakeLure(object) then
        add(menu, getText("ContextMenu_OA_Machine_TakeLure"), playerObj, onTakeLure, object)
    else
        add(menu, getText("ContextMenu_OA_Machine_RemoveShell"), playerObj, onPickUp, object)
    end
end

-- A machine with a window is one option, its name, that opens the window: switching it and the rest are there. What is
-- done to it by hand (a lure's taking back) is an option of its own under it. A machine without a window keeps its
-- name with the things done to it in a submenu, and none at all when nothing is done to it by hand (the research
-- storage: a container, opened from the inventory).
local function addMachineOptions(context, playerObj, object)
    local state = Machines.state(object)
    local kind = state.kind
    if Data.hasWindow(kind) then
        -- added from the last, each on top: the name comes first
        if kind == "lure" then lureOption(context, playerObj, object, true) end
        local open = context:addOptionOnTop(Machines.name(kind), playerObj, onOpen, object)
        tooltip(open, getText("Tooltip_OA_Machine_" .. kind))
        return
    end
    if not Data.KINDS[kind].hand and kind ~= "lure" then return end
    local option = context:addOptionOnTop(Machines.name(kind), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    if Data.KINDS[kind].hand then
        sub:addOption(getText("ContextMenu_OA_Machine_Shred"), playerObj, onShredMenu, object)
    end
    if kind == "lure" then lureOption(sub, playerObj, object, false) end
    -- what the machine is, on the first option of its submenu (on the machine's own option it would cover the submenu)
    local first = sub.options and sub.options[1]
    if first and not first.toolTip then tooltip(first, getText("Tooltip_OA_Machine_" .. kind)) end
end

function Menu.fill(player, context, worldobjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(player)
    local square = clickedSquare(worldobjects)
    if not playerObj or not square then return end
    local object = Machines.at(square)
    if object then addMachineOptions(context, playerObj, object) end
end

Events.OnFillWorldObjectContextMenu.Add(Menu.fill)

-- ---------------------------------------------------------------------------------------------------------------------
-- Installing, from the item in the inventory

-- The lure's placing cursor (server/OperationAcorn/Machines/PlaceCursor.lua, looked up when used: the game loads the
-- server folder after this one).
local function onInstallLure(playerObj, item)
    ISOAMachineCursor.start(playerObj, "lure", item)
end

-- A machine's furniture piece: the game's furniture cursor, in its place mode, begun with this piece.
local function onInstallPiece(playerObj, item)
    ISMoveableContextMenu.openMovableCursor(item, playerObj)
end

-- The machine kind a furniture piece in the inventory belongs to, or nil (the game's Moveable items: a machine bought
-- or taken up is delivered as one piece a tile).
local function pieceKind(item)
    if not instanceof(item, "Moveable") then return nil end
    local sprite = item:getWorldSprite()
    if not sprite or string.sub(sprite, 1, #Sprites.MACHINES + 1) ~= Sprites.MACHINES .. "_" then return nil end
    return Machines.kindOfSprite(sprite)
end

-- Takes out of the menu the game's own "place" option for a piece (it opens the same cursor; only this mod's stays).
local function dropGamesOwn(context, item)
    local name = getText("IGUI_PlaceObject")
    for _, option in ipairs(context.options) do
        if option.name == name and option.target == item and option.onSelect == ISMoveableContextMenu.openMovableCursor then
            context:removeOptionByName(name)
            return
        end
    end
end

-- "Install" on top of the menu of the clicked lure or machine piece. The game offers a piece placing only from the
-- inventory proper and not from the hands (ISMoveableContextMenu.createMenu); the same holds here.
function Menu.fillInventory(player, context, items)
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end
    local lure, piece, kind = nil, nil, nil
    local lureType = Machines.itemFullType("lure")
    for _, item in ipairs(ISInventoryPane.getActualItems(items)) do
        if not lure and item:getFullType() == lureType then
            lure = item
        elseif not piece then
            local k = pieceKind(item)
            if k then piece, kind = item, k end
        end
    end
    if piece then
        dropGamesOwn(context, piece)
        if piece:getContainer() == playerObj:getInventory() and playerObj:getPrimaryHandItem() ~= piece
            and playerObj:getSecondaryHandItem() ~= piece then
            local option = context:addOptionOnTop(getText("ContextMenu_OA_Machine_Install"), playerObj, onInstallPiece, piece)
            option.itemForTexture = piece
            tooltip(option, getText("Tooltip_OA_Machine_" .. kind))
        end
    end
    if lure then
        local option = context:addOptionOnTop(getText("ContextMenu_OA_Machine_Install"), playerObj, onInstallLure, lure)
        option.itemForTexture = lure
        tooltip(option, getText("Tooltip_OA_Machine_lure"))
    end
end

Events.OnFillInventoryObjectContextMenu.Add(Menu.fillInventory)

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
