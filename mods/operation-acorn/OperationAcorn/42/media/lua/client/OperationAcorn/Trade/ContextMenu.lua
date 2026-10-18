-- The right-click menus of the trade part: on the terminal, the delivery box and the supply crate in the world, and on
-- their items, the manifest and the manual in the inventory. Each option goes on top of the game's menu (the thing the
-- player clicked comes first); nothing here searches the inventory to build a menu (what a crowbar would change is
-- told in the tooltip, and the box's nearby items are looked for when the player picks the option).
require "ISUI/ISContextMenu"
require "OperationAcorn/Trade/Actions"
require "OperationAcorn/Trade/Reader"
require "OperationAcorn/Trade/Estimate"
require "PZUIKit/Confirm"
require "PZUIKit/Menu"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Objects, Things = Trade.Objects, Trade.Things
local Menus = {}
Trade.Menus = Menus

-- The item types by name (module-less) that open a crate with a crowbar's help.
local CROWBARS = { "Crowbar", "CrowbarForged" }

local function tooltip(option, text)
    local tip = ISInventoryPaneContextMenu.addToolTip()
    tip.description = text
    option.toolTip = tip
end

-- The crowbar a character carries, looked for when the player picks "break the seal", not when the menu is built.
local function crowbarOf(character)
    local inventory = character:getInventory()
    for _, name in ipairs(CROWBARS) do
        local item = inventory:getFirstTypeRecurse(name)
        if item then return item end
    end
    return nil
end

-- Doing things at a square ------------------------------------------------------------------------------------------

function Menus.use(object, player)
    local character = getSpecificPlayer(player)
    local square = object:getSquare()
    if luautils.walkAdj(character, square) then
        ISTimedActionQueue.add(ISOAUseTerminal:new(character, square))
    end
end

function Menus.unseal(object, player)
    local character = getSpecificPlayer(player)
    local square = object:getSquare()
    if luautils.walkAdj(character, square) then
        local crowbar = crowbarOf(character)
        if crowbar then ISInventoryPaneContextMenu.equipWeapon(crowbar, true, false, player) end
        ISTimedActionQueue.add(ISOAUnseal:new(character, square, crowbar ~= nil))
    end
end


-- The words of a seal confirmation: what is in the box, what it would earn (a mission's item: its reward, paid at the
-- settlement), how full it goes (a box sealed half empty is the player's call, shown, not stopped), and what the team
-- will not take (which goes back to the player's inventory).
function Menus.sealText(character, plan)
    local record = OA.Client.record(character)
    local estimate = Trade.Estimate.infos(record, plan.infos)
    local sealing = OA.Missions and OA.Missions.sealing(record, plan.infos) or {}
    local lines = {}
    -- (a box of a mission's items alone: its reward's line says what it earns)
    if estimate and (estimate.credits > 0 or estimate.trust > 0 or #sealing == 0) then
        lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Worth", #plan.taken, Text.credits(estimate.credits), Text.credits(estimate.trust))
    else
        lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Count", #plan.taken)
    end
    for _, s in ipairs(sealing) do
        if s.credits then
            lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Mission", Text.credits(s.credits), Text.credits(s.trust))
        else
            lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_MissionLater")
        end
    end
    lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Fill", string.format("%.1f", plan.weight),
        tostring(Objects.capacityFor(record)))
    if #plan.refused > 0 then
        lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Refused", #plan.refused)
        for i = 1, math.min(#plan.refused, 4) do lines[#lines + 1] = "  " .. plan.refused[i]:getDisplayName() end
    end
    lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Final")
    return table.concat(lines, " \n ")
end

function Menus.seal(object, player)
    local character = getSpecificPlayer(player)
    local container = object:getContainer()
    if not container then return end
    local plan = Things.sealable(container)
    -- only what the team will not take: nothing would go up (the server refuses it too)
    if #plan.taken == 0 then
        OA.Sync.notice(OA.Client.id(character), "IGUI_OA_Trade_Reason_nothing")
        return
    end
    UI.confirm(character, Menus.sealText(character, plan), nil, function()
        local square = object:getSquare()
        if square and luautils.walkAdj(character, square) then
            ISTimedActionQueue.add(ISOASeal:new(character, square))
        end
    end)
end

-- The world menu ------------------------------------------------------------------------------------------------------

local function terminalOptions(context, object, player)
    local square = object:getSquare()
    local use = context:addOptionOnTop(getText("ContextMenu_OA_Trade_UseTerminal"), object, Menus.use, player)
    local record = OA.Client and OA.Client.record(getSpecificPlayer(player))
    if not Objects.powered(square, object) then
        use.notAvailable = true
        tooltip(use, getText("ContextMenu_OA_Trade_NeedPower"))
    elseif record and not Trade.registered(record) then
        -- a terminal another character left, before this one's first supply has brought its number (CANON S19)
        use.notAvailable = true
        tooltip(use, getText("ContextMenu_OA_Trade_NoNumber"))
    end
    -- taken up with the game's furniture tool (Trade/Moveables.lua)
end

function Menus.dismantle(object, player)
    local character = getSpecificPlayer(player)
    local square = object:getSquare()
    if square and luautils.walkAdj(character, square) then
        ISTimedActionQueue.add(ISOADismantleBox:new(character, square))
    end
end

local function boxOptions(context, object, player)
    local md = object:getModData()
    local side = Things.boxSide(getSpecificPlayer(player), md)
    if side ~= "own" then
        -- the name on top; taking an abandoned box apart at the menu's end, over the game's destroy line
        if side == "abandoned" then
            local dismantle = context:addOption(getText("ContextMenu_OA_Trade_DismantleBox"), object, Menus.dismantle, player) -- oa-menu: bottom
            PZUIKit.Menu.beforeTail(context, { dismantle })
        end
        local info = context:addOptionOnTop(getText(side == "abandoned" and "ContextMenu_OA_Trade_BoxAbandoned"
            or "ContextMenu_OA_Trade_BoxOther"), nil, nil)
        info.notAvailable = true
        tooltip(info, getText(side == "abandoned" and "ContextMenu_OA_Trade_BoxAbandonedTip" or "ContextMenu_OA_Trade_BoxOtherTip"))
        return
    end
    if md[Objects.SEALED] then
        local info = context:addOptionOnTop(getText("ContextMenu_OA_Trade_BoxSealed"), nil, nil)
        info.notAvailable = true
        tooltip(info, getText("ContextMenu_OA_Trade_BoxSealedTip"))
        return
    end
    local seal = context:addOptionOnTop(getText("ContextMenu_OA_Trade_SealBox"), object, Menus.seal, player)
    local container = object:getContainer()
    if not container or container:isEmpty() then
        seal.notAvailable = true
        tooltip(seal, getText("IGUI_OA_Trade_Reason_nothing"))
    end
end

local function crateOptions(context, object, player)
    local md = object:getModData()
    if md[Objects.SEALED] then
        local option = context:addOptionOnTop(getText("ContextMenu_OA_Trade_Unseal"), object, Menus.unseal, player)
        tooltip(option, getText("ContextMenu_OA_Trade_UnsealTip"))
    end
end

local function onFillWorld(player, context, worldobjects, test)
    if test then return end
    local character = getSpecificPlayer(player)
    if not character or character:getVehicle() then return end
    local seen = {}
    for _, object in ipairs(worldobjects) do
        local kind = Objects.kindOf(object)
        if kind and not seen[object] then
            seen[object] = true
            if kind == Objects.TERMINAL then terminalOptions(context, object, player)
            elseif kind == Objects.DELIVERY_BOX then boxOptions(context, object, player)
            elseif kind == Objects.CRATE then crateOptions(context, object, player) end
        end
    end
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorld)

-- The inventory menu ------------------------------------------------------------------------------------------------

local PLACE_KEY = {
    [Objects.ITEMS.terminal] = { kind = Objects.TERMINAL, key = "ContextMenu_OA_Trade_PlaceTerminal" },
    [Objects.ITEMS.field] = { kind = Objects.TERMINAL, key = "ContextMenu_OA_Trade_PlaceFieldTerminal" },
    [Objects.ITEMS.box] = { kind = Objects.DELIVERY_BOX, key = "ContextMenu_OA_Trade_PlaceBox" },
}

-- The cursor (server/OperationAcorn/Trade/PlaceCursor.lua) derives from ISBuildingObject, which the game loads with
-- the server folder after the client one, so it is looked up when used, not required here.
function Menus.place(character, kind, item)
    ISOAPlaceCursor.start(character, kind, item)
end

-- Placing from the inventory menu: an item in a container on the floor or in a bag is brought to the main
-- inventory first (the placing takes it from there).
function Menus.placeFrom(character, kind, item)
    ISInventoryPaneContextMenu.transferIfNeeded(character, item)
    Menus.place(character, kind, item)
end

local function onFillInventory(player, context, items)
    local character = getSpecificPlayer(player)
    if not character then return end
    -- only the first item of the selection gets entries
    local item = OA.menuItems(items)[1]
    if not item then return end
    local fullType = item:getFullType()
    local place = PLACE_KEY[fullType]
    if place then
        -- Put down from where it lies (brought into the inventory first), or carried in both hands first (the
        -- game's own "equip in both hands" is off a heavy thing's menu: PZUIKit.Heavy); the putting down on top.
        PZUIKit.Heavy.carryOption(context, character, item, getText("ContextMenu_OA_Trade_Carry"))
        local option = context:addOptionOnTop(getText(place.key), character, Menus.placeFrom, place.kind, item)
        if character:getVehicle() then option.notAvailable = true end
    elseif fullType == "OperationAcorn.SupplyManifest" then
        context:addOptionOnTop(getText("ContextMenu_OA_Trade_ReadManifest"), character, Trade.Reader.manifest, item)
    elseif fullType == "OperationAcorn.TerminalManual" then
        context:addOptionOnTop(getText("ContextMenu_OA_Trade_LastPage"), character, Trade.Reader.lastPage)
    end
end
Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)

-- The game's sledgehammer passes over a sealed delivery box or supply crate: what is in it lives in the record or on
-- the crate's data, not in a container, so breaking it would only lose it (a box's goods before the helicopter comes,
-- a crate's cargo before it is opened). A box is taken up or dismantled, a crate opened; fire and the like still take
-- them, and the record forgets them then (Things.destroyed). ISDestroyCursor loads after this file (server folder).
Events.OnGameStart.Add(function()
    local canDestroy = ISDestroyCursor and ISDestroyCursor.canDestroy
    if not canDestroy then return end
    function ISDestroyCursor:canDestroy(object)
        local kind = object and Objects.kindOf(object)
        if (kind == Objects.DELIVERY_BOX or kind == Objects.CRATE) and object:getModData()[Objects.SEALED] then
            return false
        end
        return canDestroy(self, object)
    end
end)

return Menus
