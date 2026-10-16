-- Where the kits meet the game's screens: the right-click entries (fit a kit to an item, redeem the handover voucher,
-- fit a kit to a vehicle from the mechanics window), the lines about the team's gear and fitted kits in an item's
-- tooltip, the notices, and the writing of a character's kits into the game when it starts. Other mods' menus and
-- tooltips are wrapped, never replaced. The entries go on top of the game's menu; the kits a character
-- carries are only counted at a right-click (the game counts them by item type), the one the player picks is fetched
-- when the entry is picked, and only a kit's own menu lists the items it can go to.
require "ISUI/ISToolTip"
require "ISUI/ISToolTipInv"
require "ISUI/ISInventoryPaneContextMenu"
require "Vehicles/ISUI/ISVehicleMechanics"
require "OperationAcorn/Client"
require "OperationAcorn/Titles"
require "OperationAcorn/TipLines"
require "OperationAcorn/Gear/Gear"
require "OperationAcorn/Gear/Actions"
local OA = OperationAcorn
local Gear = OA.Gear
local Rules = Gear.Rules
local Menu = {}
Gear.Menu = Menu

local function tip(option, text)
    local t = ISToolTip:new()
    t:initialise()
    t:setVisible(false)
    t.description = text
    option.toolTip = t
end

local function unavailable(option, text)
    option.notAvailable = true
    tip(option, text)
end

-- ---- texts ----------------------------------------------------------------------------------------------------

local function join(lines)
    return table.concat(lines, " <LINE> ")
end

-- ---- the tooltip of the team's gear and of a kit ---------------------------------------------------------------

-- The items of the gear package whose tooltip text is Tooltip_OA_Gear_<text> (the waist bag's two sides share one).
Menu.TEXTS = {
    TeamBackpack = "TeamBackpack", TeamWaistBagFront = "TeamWaistBag", TeamWaistBagBack = "TeamWaistBag",
    TeamFuelCan = "TeamFuelCan", KitCapacity = "KitCapacity", KitLightening = "KitLightening",
    KitReinforcement = "KitReinforcement", KitEngine = "KitEngine",
}

-- The tooltip text of an item of this mod or the team's welder, or nil.
local function ownText(item, target)
    if target == "tool" then return "Tooltip_OA_Gear_FieldTool" end
    if target == "welder" then return "Tooltip_OA_Gear_TeamWelder" end
    local text = item:getModule() == OA.MOD and Menu.TEXTS[item:getType()]
    return text and ("Tooltip_OA_Gear_" .. text) or nil
end

-- The lines of an item's tooltip that this part adds (none for most items), for TipLines.
local function extraLines(item)
    local target = Gear.targetOf(item)
    local own = ownText(item, target)
    if not own and not (target and item:hasModData()) then return nil end
    local lines = {}
    if own then lines[#lines + 1] = getText(own) end
    for _, line in ipairs(target and Gear.itemLines(item) or {}) do lines[#lines + 1] = line end
    -- a lightened team item: what it weighs as carried (the game's weight line above is the scale's)
    local _, light = Gear.itemKits(item)
    local carried = target and target ~= "bag" and light > 0 and Gear.applies(Gear.CARRY_POINT) and Gear.carriedWeight(item)
    if carried then lines[#lines + 1] = getText("Tooltip_OA_Gear_Carried", string.format("%.2f", carried)) end
    return #lines > 0 and lines or nil
end

OA.TipLines.add("gear", extraLines)

-- ---- the inventory menu ---------------------------------------------------------------------------------------

-- Fits a kit to an item: the kit the entry was made on, or the first of its kind the character carries (looked for
-- here, when the entry is picked).
local function fitItem(player, kind, kit, item)
    kit = kit or Gear.firstKit(player, kind)
    if not kit then return end
    ISInventoryPaneContextMenu.transferIfNeeded(player, kit)
    ISTimedActionQueue.add(ISOAFitItemKit:new(player, kit, item))
end

local function describe(item)
    local lines = Gear.itemLines(item)
    return lines and join(lines) or getText("Tooltip_OA_Gear_NoKits")
end

-- An entry that fits a kit of `kind` to `item` (`kit`: the one it is made on, or nil), or says why it cannot.
local function addFitEntry(menu, player, kind, kit, item, label)
    local entry = menu:addOption(label, player, fitItem, kind, kit, item)
    local why = kit and Gear.refusal(kit, item) or Gear.refusalFor(kind, item)
    if why then
        unavailable(entry, getText("IGUI_OA_Gear_Reason_" .. why) .. " <LINE> " .. describe(item))
    else
        tip(entry, describe(item))
    end
end

-- The entry on a kit fitted to items: fit it to one of the items the character has that it fits. An expansion kit also
-- fits a vehicle's storage, from the mechanics window: the hint says so.
local function addItemKitMenu(context, player, kit)
    local kind = Gear.kindOfItem(kit)
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Gear_FitItem"), nil, nil)
    local fits = {}
    for _, item in ipairs(Gear.targets(player)) do
        if Rules.fits(kind, Gear.targetOf(item)) then fits[#fits + 1] = item end
    end
    if #fits == 0 then
        local text = getText("Tooltip_OA_Gear_NoTarget_" .. kind)
        if Rules.fits(kind, "storage") then text = text .. " <LINE> " .. getText("Tooltip_OA_Gear_FitVehicle") end
        unavailable(option, text)
        return
    end
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, item in ipairs(fits) do addFitEntry(sub, player, kind, kit, item, item:getDisplayName()) end
    if Rules.fits(kind, "storage") then tip(option, getText("Tooltip_OA_Gear_FitVehicle")) end
end

-- The entry on a vehicle kit: it is fitted from the vehicle's mechanics window.
local function addVehicleKitHint(context)
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Gear_FitVehicle"), nil, nil)
    unavailable(option, getText("Tooltip_OA_Gear_FitVehicle"))
end

local function redeem(player, voucher, kind)
    OA.Sync.send(player, "gear.redeem", { item = voucher:getID(), kind = kind })
end

-- The entry on the handover voucher: one kit of the kind chosen, not counted in the shop's price.
local function addVoucherMenu(context, player, voucher)
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Gear_Redeem"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, kind in ipairs(OA.Shop.KIT_ORDER) do
        sub:addOption(getItemNameFromFullType(Rules.kitType(kind)), player, redeem, voucher, kind)
    end
    tip(option, getText("Tooltip_OA_Gear_RedeemInfo"))
end

-- The entry on a kit target (a bag, the fuel can, the welder, a field tool): fit one of the kits the character has
-- that fit it.
local function addFitKitMenu(context, player, item)
    if not item:getContainer() then return end
    local target = Gear.targetOf(item)
    local entries = {}
    for _, kind in ipairs(OA.Shop.KIT_ORDER) do
        local count = Rules.fits(kind, target) and Gear.kitCount(player, kind) or 0
        if count > 0 then entries[#entries + 1] = { kind = kind, count = count } end
    end
    if #entries == 0 then return end
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Gear_FitKit"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, e in ipairs(entries) do
        addFitEntry(sub, player, e.kind, nil, item, getText("ContextMenu_OA_Gear_FitKitOf",
            getItemNameFromFullType(Rules.kitType(e.kind)), tostring(e.count)))
    end
end

local function onFillInventory(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local done = {}
    -- the entries go on top, so they are added from the last of the selection to keep its order
    local adders = {}
    for _, item in ipairs(OA.menuItems(items)) do
        local fullType = item:getFullType()
        if item:getModule() == OA.MOD and fullType == Gear.VOUCHER and not done.voucher then
            done.voucher = true
            adders[#adders + 1] = function() addVoucherMenu(context, player, item) end
        elseif item:getModule() == OA.MOD and Gear.kindOfItem(item) and not done.kit then
            done.kit = true
            adders[#adders + 1] = function()
                if Rules.onItems(Gear.kindOfItem(item)) then
                    addItemKitMenu(context, player, item)
                else
                    addVehicleKitHint(context)
                end
            end
        elseif not done.target and Gear.targetOf(item) then
            done.target = true
            -- an item that was fitted before is written again from its kits (the API may have come or gone since)
            if item:hasModData() then OA.try("gear: refreshing an item", Gear.refreshItem, item) end
            adders[#adders + 1] = function() addFitKitMenu(context, player, item) end
        end
    end
    for i = #adders, 1, -1 do adders[i]() end
end
Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)

-- ---- the mechanics window -------------------------------------------------------------------------------------

local function fitVehicle(player, kind, part)
    local kit = Gear.firstKit(player, kind)
    if not kit then return end
    if player:getVehicle() then ISVehicleMenu.onExit(player) end
    ISInventoryPaneContextMenu.transferIfNeeded(player, kit)
    ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, part:getVehicle(), part:getArea()))
    ISTimedActionQueue.add(ISOAFitVehicleKit:new(player, kit, part))
end

-- Adds the entry of one kind of kit to a part's menu: enabled with a kit of the kind the character has.
local function addPartEntry(context, player, part, kind, labelKey, lines)
    local option = context:addOptionOnTop(getText(labelKey), player, fitVehicle, kind, part)
    local text = lines and join(lines) or getText("Tooltip_OA_Gear_NoKits")
    if Gear.kitCount(player, kind) == 0 then
        unavailable(option, getText("Tooltip_OA_Gear_NoVehicleKit", getItemNameFromFullType(Rules.kitType(kind))) ..
            " <LINE> " .. text)
    else
        tip(option, text)
    end
end

local function addPartOptions(window, part)
    local context = window.context
    if not context then return end
    local player = getSpecificPlayer(window.playerNum)
    local vehicle = part:getVehicle()
    if not player or not vehicle then return end
    local id = part:getId()
    local before = context.numOptions
    if id == Gear.ENGINE_PART then
        Gear.refreshEngine(vehicle)
        addPartEntry(context, player, part, "engine", "ContextMenu_OA_Gear_FitEngine", Gear.engineLines(vehicle))
    elseif Gear.isStoragePart(part) then
        Gear.refreshStorage(vehicle, part)
        addPartEntry(context, player, part, "capacity", "ContextMenu_OA_Gear_FitStorage", Gear.storageLines(part))
    end
    -- the game hides a menu it found nothing for; this has put something in
    if before == 1 and context.numOptions > 1 then context:setVisible(true) end
end

local originalPartMenu = ISVehicleMechanics.doPartContextMenu

local function partOptionsAdded(self, part, ...)
    OA.try("gear: the part menu", addPartOptions, self, part)
    return ...
end

function ISVehicleMechanics:doPartContextMenu(part, ...)
    self.context = nil
    return partOptionsAdded(self, part, originalPartMenu(self, part, ...))
end

-- ---- notices --------------------------------------------------------------------------------------------------

local function onNotice(playerId, detail)
    if type(detail) ~= "table" or type(detail.key) ~= "string" then return end
    if not string.find(detail.key, "^IGUI_OA_Gear_") then return end
    local player = getPlayer()
    if not player then return end
    if playerId and OA.Client.id(player) ~= playerId then return end
    local args = detail.args or {}
    if detail.key == "IGUI_OA_Gear_Failed" or detail.key == "IGUI_OA_Gear_RedeemFailed" then
        local text = getText(detail.key, getText("IGUI_OA_Gear_Reason_" .. tostring(args[1])))
        HaloTextHelper.addBadText(player, text)
    elseif detail.key == "IGUI_OA_Gear_Redeemed" then
        OA.Titles.notice(playerId, { key = "IGUI_OA_Title_KitRedeemed" }, detail.key, args)
    elseif string.find(detail.key, "^IGUI_OA_Gear_Fitted_") then
        -- a kit fitted: the event's title, what it made of the target under it
        OA.Titles.notice(playerId, { key = "IGUI_OA_Title_KitFitted" }, detail.key, args)
    else
        HaloTextHelper.addGoodText(player, getText(detail.key, args[1], args[2], args[3]))
    end
end
OA.Sync.listen("notice", onNotice)

-- ---- the game starts ------------------------------------------------------------------------------------------

-- The team items' keys are declared to the API, and the character's fitted items written again from their counts (the
-- API may have come or gone since they were fitted; a lightened item's weight is not saved), once, when the game
-- starts.
local function onGameStart()
    Gear.declare()
    local player = getPlayer()
    if not player then return end
    OA.try("gear: refreshing the kits", Gear.refreshAll, player)
end
Events.OnGameStart.Add(onGameStart)

-- The waist bag worn the other way is a new item with the old one's modData and the script's capacity: its kits are
-- written into it as soon as it is put on (only the two waist bag places are looked at).
local function onClothingUpdated(character)
    if not character or not character.isLocalPlayer or not character:isLocalPlayer() or not ItemBodyLocation then return end
    for _, place in ipairs({ ItemBodyLocation.FANNY_PACK_FRONT, ItemBodyLocation.FANNY_PACK_BACK }) do
        local item = place and character:getWornItem(place)
        if item and item:hasModData() and Gear.targetOf(item) == "bag" then
            OA.try("gear: refreshing a worn bag", Gear.refreshItem, item)
        end
    end
end
Events.OnClothingUpdated.Add(onClothingUpdated)

-- A vehicle the character gets into is written again from its kits (cheap, and once per getting in).
local function onEnterVehicle(character)
    if not character or not character.isLocalPlayer or not character:isLocalPlayer() then return end
    local vehicle = character:getVehicle()
    if vehicle then OA.try("gear: refreshing a vehicle", Gear.refreshVehicle, vehicle) end
end
Events.OnEnterVehicle.Add(onEnterVehicle)

return Menu
