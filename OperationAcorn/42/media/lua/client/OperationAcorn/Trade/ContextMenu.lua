-- The right-click menus of the trade part: on the terminal, the delivery box and the supply crate in the world, and on
-- their items, the manifest and the manual in the inventory.
require "ISUI/ISContextMenu"
require "OperationAcorn/Trade/Actions"
require "OperationAcorn/Trade/Reader"
require "OperationAcorn/Trade/Estimate"
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

function Menus.breakCrate(object, player)
    local character = getSpecificPlayer(player)
    local square = object:getSquare()
    if luautils.walkAdj(character, square) then
        ISTimedActionQueue.add(ISOABreakCrate:new(character, square))
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

function Menus.bulk(object, player)
    local character = getSpecificPlayer(player)
    local square = object:getSquare()
    local plan = Things.bulkPlan(character, object)
    if plan.count == 0 then return end
    if luautils.walkAdj(character, square) then
        ISTimedActionQueue.add(ISOABulkLoad:new(character, square, plan.count))
    end
end

-- The words of a seal confirmation: what is in the box, what it would earn, and what the team will not take (which
-- goes back to the player's inventory).
function Menus.sealText(character, object)
    local record = OA.Client.record(character)
    local container = object:getContainer()
    local plan = Things.sealable(container)
    local estimate = Trade.Estimate.infos(record, plan.infos)
    local lines = {}
    if estimate then
        lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Worth", #plan.taken, Text.credits(estimate.credits), Text.credits(estimate.trust))
    else
        lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Count", #plan.taken)
    end
    if #plan.refused > 0 then
        lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Refused", #plan.refused)
        for i = 1, math.min(#plan.refused, 4) do lines[#lines + 1] = "  " .. plan.refused[i]:getDisplayName() end
    end
    lines[#lines + 1] = getText("IGUI_OA_Trade_Seal_Final")
    return table.concat(lines, " \n ")
end

function Menus.seal(object, player)
    local character = getSpecificPlayer(player)
    UI.confirm(character, Menus.sealText(character, object), nil, function()
        local square = object:getSquare()
        if square and luautils.walkAdj(character, square) then
            ISTimedActionQueue.add(ISOASeal:new(character, square))
        end
    end)
end

-- The world menu ------------------------------------------------------------------------------------------------------

local function terminalOptions(context, object, player)
    local square = object:getSquare()
    local use = context:addOption(getText("ContextMenu_OA_Trade_UseTerminal"), object, Menus.use, player)
    if not Objects.powered(square) then
        use.notAvailable = true
        tooltip(use, getText("ContextMenu_OA_Trade_NeedPower"))
    end
    -- taken up with the game's furniture tool (Trade/Moveables.lua)
end

local function boxOptions(context, object, player)
    local character = getSpecificPlayer(player)
    local md = object:getModData()
    if md[Objects.SEALED] then
        local info = context:addOption(getText("ContextMenu_OA_Trade_BoxSealed"), nil, nil)
        info.notAvailable = true
        tooltip(info, getText("ContextMenu_OA_Trade_BoxSealedTip"))
        return
    end
    context:addOption(getText("ContextMenu_OA_Trade_SealBox"), object, Menus.seal, player)
    local plan = Things.bulkPlan(character, object)
    local load = context:addOption(getText("ContextMenu_OA_Trade_LoadBox", plan.count), object, Menus.bulk, player)
    if plan.count == 0 then
        load.notAvailable = true
        tooltip(load, getText("ContextMenu_OA_Trade_LoadNothing"))
    end
end

local function crateOptions(context, object, player)
    local md = object:getModData()
    if md[Objects.SEALED] then
        local crowbar = crowbarOf(getSpecificPlayer(player))
        local option = context:addOption(getText("ContextMenu_OA_Trade_Unseal"), object, Menus.unseal, player)
        tooltip(option, getText(crowbar and "ContextMenu_OA_Trade_UnsealFast" or "ContextMenu_OA_Trade_UnsealSlow"))
        return
    end
    if Things.crateEmpty(object) then
        context:addOption(getText("ContextMenu_OA_Trade_BreakCrate"), object, Menus.breakCrate, player)
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
    [Objects.ITEMS.box] = { kind = Objects.DELIVERY_BOX, key = "ContextMenu_OA_Trade_PlaceBox" },
    [Objects.ITEMS.crate] = { kind = Objects.CRATE, key = "ContextMenu_OA_Trade_PlaceCrate" },
}

-- The cursor (server/OperationAcorn/Trade/PlaceCursor.lua) derives from ISBuildingObject, which the game loads with
-- the server folder after the client one, so it is looked up when used, not required here.
function Menus.place(character, kind, item)
    ISOAPlaceCursor.start(character, kind, item)
end

local function onFillInventory(player, context, items)
    local character = getSpecificPlayer(player)
    if not character then return end
    for _, item in ipairs(ISInventoryPane.getActualItems(items)) do
        local fullType = item:getFullType()
        local place = PLACE_KEY[fullType]
        if place then
            if character:isItemInBothHands(item) then
                context:addOption(getText(place.key), character, Menus.place, place.kind, item)
            else
                local option = context:addOption(getText("ContextMenu_OA_Trade_Carry"), character, ISInventoryPaneContextMenu.equipHeavyItem, item)
                if character:getVehicle() then option.notAvailable = true end
            end
        elseif fullType == "OperationAcorn.SupplyManifest" then
            context:addOption(getText("ContextMenu_OA_Trade_ReadManifest"), character, Trade.Reader.manifest, item)
        elseif fullType == "OperationAcorn.TerminalManual" then
            context:addOption(getText("ContextMenu_OA_Trade_LastPage"), character, Trade.Reader.lastPage)
        end
        return
    end
end
Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)

return Menus
