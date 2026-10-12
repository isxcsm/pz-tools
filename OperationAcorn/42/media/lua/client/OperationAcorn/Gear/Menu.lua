-- Where the kits meet the game's screens: the right-click entries (fit a kit to a bag, redeem the handover voucher, fit
-- a kit to a vehicle from the mechanics window), the lines about fitted kits in a bag's tooltip, the notices, and the
-- writing of a character's kits into the game when it starts. Other mods' menus and tooltips are wrapped, never
-- replaced. The entries go on top of the game's menu; the bags and kits a character carries are not searched for at a
-- right-click but read from Gear.carried, which keeps them while the inventory is the same.
require "ISUI/ISToolTip"
require "ISUI/ISToolTipInv"
require "ISUI/ISInventoryPaneContextMenu"
require "Vehicles/ISUI/ISVehicleMechanics"
require "OperationAcorn/Client"
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

-- ---- the tooltip of a bag with kits and of a kit --------------------------------------------------------------

-- The items of the gear package whose tooltip text is Tooltip_OA_Gear_<item name>.
Menu.TEXTS = {
    TeamBackpack = true, FuelCanMk1 = true, FuelCanMk2 = true, FuelCanMk3 = true,
    KitBagCapacity = true, KitBagWeight = true, KitTrunk = true, KitEngine = true,
}

-- The line that says what a kit was ordered for. Finding the bag or the vehicle looks through the inventory or the
-- cell, so the line is kept for a minute of game time per kit (a tooltip is drawn every frame it is shown).
local lineCache = setmetatable({}, { __mode = "k" })

function Menu.kitForLine(kit, kind)
    local now = OA.hours()
    local hit = lineCache[kit]
    if hit and math.abs(now - hit.at) < 1 / 60 then return hit.text end
    local text = getText("Tooltip_OA_Gear_KitFor", Gear.targetName(kind, Gear.targetOf(kit), getPlayer()))
    lineCache[kit] = { at = now, text = text }
    return text
end

-- The lines of an item's tooltip that this part adds (none for most items).
local function extraLines(item)
    local own = item:getModule() == OA.MOD and Menu.TEXTS[item:getType()]
    local bag = item:IsInventoryContainer() and item:hasModData()
    if not own and not bag then return nil end
    local lines = {}
    if own then
        lines[#lines + 1] = getText("Tooltip_OA_Gear_" .. item:getType())
        local kind = Gear.kindOfItem(item)
        if kind then lines[#lines + 1] = Menu.kitForLine(item, kind) end
    end
    if bag then
        for _, line in ipairs(Gear.bagLines(item) or {}) do lines[#lines + 1] = line end
    end
    return lines
end

local originalRender = ISToolTipInv.render

-- The lines are put on the item while its tooltip is drawn and taken off after, so nothing else sees them.
function ISToolTipInv:render()
    local item = self.item
    local lines = item and extraLines(item)
    if lines and #lines > 0 then
        local old = item:getTooltip()
        local text = join(lines)
        if old and old ~= "" then text = getText(old) .. " <LINE> " .. text end
        item:setTooltip(OA.tooltipText(text))
        local ok, err = pcall(originalRender, self)
        item:setTooltip(old)
        if not ok then error(err, 0) end
        return
    end
    originalRender(self)
end

-- ---- the inventory menu ---------------------------------------------------------------------------------------

-- The kits of a kind a character has that may go to a target called `key`, the ones ordered for it first.
local function kitsFor(player, kind, key)
    local exact, any = {}, {}
    for _, kit in ipairs(Gear.carried(player).kits[kind] or {}) do
        local target = Gear.targetOf(kit)
        if target == "" then any[#any + 1] = kit elseif target == key then exact[#exact + 1] = kit end
    end
    for _, kit in ipairs(any) do exact[#exact + 1] = kit end
    return exact
end

local function fitBag(player, kit, bag)
    ISInventoryPaneContextMenu.transferIfNeeded(player, kit)
    ISTimedActionQueue.add(ISOAFitBagKit:new(player, kit, bag))
end

local function describeBag(bag)
    local lines = Gear.bagLines(bag)
    return lines and join(lines) or getText("Tooltip_OA_Gear_NoKits")
end

-- The entry on a bag kit: fit it to one of the bags the character has that it was ordered for.
local function addBagKitMenu(context, player, kit)
    local kind = Gear.kindOfItem(kit)
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Gear_FitBag"), nil, nil)
    local target = Gear.targetOf(kit)
    local fits = {}
    for _, bag in ipairs(Gear.carried(player).bags) do
        if bag ~= kit and Rules.matches(target, Gear.bagKey(bag)) then fits[#fits + 1] = bag end
    end
    if #fits == 0 then
        unavailable(option, getText("Tooltip_OA_Gear_NoBag", Gear.targetName(kind, target, player)))
        return
    end
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, bag in ipairs(fits) do
        local entry = sub:addOption(bag:getDisplayName(), player, fitBag, kit, bag)
        tip(entry, describeBag(bag))
    end
end

-- The entry on a vehicle kit: it is fitted from the vehicle's mechanics window.
local function addVehicleKitHint(context, kit)
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Gear_FitVehicle"), nil, nil)
    unavailable(option, getText("Tooltip_OA_Gear_FitVehicle", Gear.targetName(Gear.kindOfItem(kit), Gear.targetOf(kit), getPlayer())))
end

local function redeem(player, voucher, kind)
    OA.Sync.send(player, "gear.redeem", { item = voucher:getID(), kind = kind })
end

-- The entry on the handover voucher: one kit of the kind chosen, for any target, not counted in the shop's price.
local function addVoucherMenu(context, player, voucher)
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Gear_Redeem"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, kind in ipairs(OA.Shop.KIT_ORDER) do
        sub:addOption(getItemNameFromFullType(Rules.kitType(kind)), player, redeem, voucher, kind)
    end
    tip(option, getText("Tooltip_OA_Gear_RedeemInfo"))
end

-- The entry on a bag: fit one of the bag kits the character has.
local function addFitKitMenu(context, player, bag)
    if not bag:getContainer() then return end
    local entries = {}
    for _, kind in ipairs({ "bagCapacity", "bagWeight" }) do
        local kits = kitsFor(player, kind, Gear.bagKey(bag))
        if #kits > 0 then entries[#entries + 1] = { kind = kind, kit = kits[1], count = #kits } end
    end
    if #entries == 0 then return end
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Gear_FitKit"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, e in ipairs(entries) do
        local entry = sub:addOption(getText("ContextMenu_OA_Gear_FitKitOf", getItemNameFromFullType(Rules.kitType(e.kind)),
            tostring(e.count)), player, fitBag, e.kit, bag)
        tip(entry, describeBag(bag))
    end
end

local function onFillInventory(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local done = {}
    -- the entries go on top, so they are added from the last of the selection to keep its order
    local adders = {}
    for _, item in ipairs(ISInventoryPane.getActualItems(items)) do
        local fullType = item:getFullType()
        if item:getModule() == OA.MOD and fullType == Gear.VOUCHER and not done.voucher then
            done.voucher = true
            adders[#adders + 1] = function() addVoucherMenu(context, player, item) end
        elseif item:getModule() == OA.MOD and Gear.kindOfItem(item) and not done.kit then
            done.kit = true
            adders[#adders + 1] = function()
                if Rules.SCOPE[Gear.kindOfItem(item)] == "bag" then
                    addBagKitMenu(context, player, item)
                else
                    addVehicleKitHint(context, item)
                end
            end
        elseif item:IsInventoryContainer() and not done.bag then
            done.bag = true
            -- a bag that was fitted before is written again from its kits (the API may have come or gone since)
            if item:hasModData() then pcall(Gear.refreshBag, item) end
            if Gear.isBackpack(item) then adders[#adders + 1] = function() addFitKitMenu(context, player, item) end end
        end
    end
    for i = #adders, 1, -1 do adders[i]() end
end
Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)

-- ---- the mechanics window -------------------------------------------------------------------------------------

local function fitVehicle(player, kit, part)
    if player:getVehicle() then ISVehicleMenu.onExit(player) end
    ISInventoryPaneContextMenu.transferIfNeeded(player, kit)
    ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, part:getVehicle(), part:getArea()))
    ISTimedActionQueue.add(ISOAFitVehicleKit:new(player, kit, part:getVehicle()))
end

-- Adds the entry of one kind of kit to a part's menu: enabled with a kit the character has for this vehicle.
local function addPartEntry(context, player, part, kind, labelKey, lines)
    local vehicle = part:getVehicle()
    local kits = kitsFor(player, kind, Gear.vehicleKey(vehicle))
    local option = context:addOptionOnTop(getText(labelKey), player, fitVehicle, kits[1], part)
    local text = lines and join(lines) or getText("Tooltip_OA_Gear_NoKits")
    if #kits == 0 then
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
    elseif part:isContainer() then
        for _, name in ipairs(Gear.TRUNK_PARTS) do
            if id == name then
                Gear.refreshVehicle(vehicle)
                addPartEntry(context, player, part, "trunk", "ContextMenu_OA_Gear_FitTrunk", Gear.trunkLines(vehicle))
            end
        end
    end
    -- the game hides a menu it found nothing for; this has put something in
    if before == 1 and context.numOptions > 1 then context:setVisible(true) end
end

local originalPartMenu = ISVehicleMechanics.doPartContextMenu

function ISVehicleMechanics:doPartContextMenu(part, x, y)
    self.context = nil
    originalPartMenu(self, part, x, y)
    local ok, err = pcall(addPartOptions, self, part)
    if not ok then OA.log("gear: the part menu failed:", tostring(err)) end
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
    else
        HaloTextHelper.addGoodText(player, getText(detail.key, args[1], args[2], args[3]))
    end
end
OA.Sync.listen("notice", onNotice)

-- ---- the game starts ------------------------------------------------------------------------------------------

-- The character's fitted bags are written again from their counts (the API may have come or gone since they were
-- fitted), once, when the game starts.
local function onGameStart()
    local player = getPlayer()
    if not player then return end
    local ok, err = pcall(Gear.refreshAll, player)
    if not ok then OA.log("gear: refreshing the bags failed:", tostring(err)) end
end
Events.OnGameStart.Add(onGameStart)

-- A vehicle the character gets into is written again from its kits (cheap, and once per getting in).
local function onEnterVehicle(character)
    if not character or not character.isLocalPlayer or not character:isLocalPlayer() then return end
    local vehicle = character:getVehicle()
    if vehicle then pcall(Gear.refreshVehicle, vehicle) end
end
Events.OnEnterVehicle.Add(onEnterVehicle)

return Menu
