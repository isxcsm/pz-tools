-- The context menus of the base machines. In the world: open a machine's window (switching it is there; the bench's
-- is where things are shredded by hand), take a lure back. In the inventory: install, on top of the item's menu, the one way to put a machine down (the lure with
-- its own placing cursor, a machine's furniture pieces with the game's furniture cursor). And the halo notes for worn
-- parts. A menu is built from the thing that was clicked: nothing here searches the inventory for it.
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/ISInventoryPaneContextMenu"
require "ISUI/ISInventoryPane"
require "ISUI/ISMoveableContextMenu"
require "OperationAcorn/Core"
require "OperationAcorn/Sync"
require "OperationAcorn/Titles"
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/Actions"
require "OperationAcorn/Machines/Window"
require "OperationAcorn/Machines/BenchWindow"
require "PZUIKit/Menu"
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

-- A lure is taken back while it works (with the hours it has left) or cleared away once it is spent; a machine is taken
-- up with the game's furniture tool (Moveables.lua). It goes to the menu's end, over the game's destroy line
-- (PZUIKit.Menu).
local function lureOption(menu, playerObj, object)
    local option
    if Machines.canTakeLure(object) then
        option = menu:addOption(getText("ContextMenu_OA_Machine_TakeLure"), playerObj, onTakeLure, object)
    else
        option = menu:addOption(getText("ContextMenu_OA_Machine_RemoveShell"), playerObj, onPickUp, object)
    end
    PZUIKit.Menu.beforeTail(menu, { option })
end

-- The game's water submenu for a machine that is also a fluid container (the rain storage), or nil: the one whose
-- options act on the machine's container (the game names it after the sprite, not after Machines.name).
local function fluidSubMenu(context, object)
    local fluid = object:getFluidContainer()
    if not fluid then return nil end
    for _, option in ipairs(context.options) do
        local sub = option.subOption and context:getSubMenu(option.subOption)
        if sub then
            for _, o in ipairs(sub.options) do
                if o.param1 == fluid then return sub end
            end
        end
    end
    return nil
end

-- A machine with a window is one option, its name, that opens the window: switching it, the bench's shredding and the
-- rest are there. What is done to it by hand (a lure's taking back) is an option of its own. A machine without a window
-- has none (the research storage: a container, opened from the inventory).
local function addMachineOptions(context, playerObj, object)
    local state = Machines.state(object)
    local kind = state.kind
    if not Data.hasWindow(kind) then return end
    -- a fluid container already has its name over the game's water submenu: the window is opened from in there, and
    -- takes the place of the game's container info (the window shows all of it and more)
    local water = fluidSubMenu(context, object)
    if water then
        water:removeOptionByName(getText("Fluid_Show_Info"))
        local manage = water:addOptionOnTop(getText("ContextMenu_OA_Machine_Manage"), playerObj, onOpen, object)
        tooltip(manage, getText("Tooltip_OA_Machine_" .. kind))
        return
    end
    if kind == "lure" then lureOption(context, playerObj, object) end
    local open = context:addOptionOnTop(Machines.name(kind), playerObj, onOpen, object)
    tooltip(open, getText("Tooltip_OA_Machine_" .. kind))
end

function Menu.fill(player, context, worldobjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(player)
    local square = clickedSquare(worldobjects)
    if not playerObj or not square then return end
    local object = Machines.at(square)
    if object then addMachineOptions(context, playerObj, object) end
end

OA.on("OnFillWorldObjectContextMenu", Menu.fill)

local function addOnce(list, object)
    for _, v in ipairs(list) do
        if v == object then return end
    end
    list[#list + 1] = object
end

-- The game looks for a fluid container on the clicked object only (its feeding troughs aside), and a machine's
-- container is on its anchor alone: a click on any of its other squares hands the anchor to the game's water menu
-- before the menu is made, so every square gets the same menu, on the one container.
function Menu.preFill(player, context, worldobjects, test)
    local fetch = ISWorldObjectContextMenu.fetchVars
    if not fetch or not fetch.fluidcontainer then return end
    local square = clickedSquare(worldobjects)
    local anchor = square and Machines.at(square)
    if not anchor or not anchor:getFluidContainer() then return end
    addOnce(fetch.fluidcontainer, anchor)
    if anchor:hasFluid() and fetch.storeWater then addOnce(fetch.storeWater, anchor) end
end

OA.on("OnPreFillWorldObjectContextMenu", Menu.preFill)

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

-- Takes out of the menu the game's own "place" option for a piece (it opens the same cursor; only this mod's stays). The
-- option itself is taken out: removeOptionByName takes the first option of that name, which may be another one's.
local function dropGamesOwn(context, item)
    local name = getText("IGUI_PlaceObject")
    for _, option in ipairs(context.options) do
        if option.name == name and option.target == item and option.onSelect == ISMoveableContextMenu.openMovableCursor then
            -- renamed to itself, a name no other option has (a pooled option is given its fields again when reused)
            option.name = option
            context:removeOptionByName(option)
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
    for _, item in ipairs(OA.menuItems(items)) do
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

OA.on("OnFillInventoryObjectContextMenu", Menu.fillInventory)

-- The notes the machines send (worn and broken parts): a brief title for the character they are for, wherever it is
-- (amber for a part worn, red for one broken).
OA.Sync.listen("notice", function(playerId, detail)
    if type(detail) ~= "table" or type(detail.key) ~= "string" then return end
    if not string.find(detail.key, "^IGUI_OA_Machine_") then return end
    local player = getPlayer()
    if not player or OA.Store.idOf(player) ~= playerId then return end
    local args = detail.args or {}
    OA.Titles.brief(playerId, detail.key, args, detail.key == "IGUI_OA_Machine_PartBroken" and "red" or "amber")
end)

return Menu
