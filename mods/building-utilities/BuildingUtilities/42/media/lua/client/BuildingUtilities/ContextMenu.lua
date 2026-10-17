-- The world context menu: a box's line, which opens its window (no submenu: what a box does is in its window), and a
-- unit's (a rack's batteries go in and out in the loot window). A device of the box's building is the box's without a
-- line: switched on or off there at once, as at the box. A device outside, a unit or a producer is wired in and out at
-- itself, with the tool of its utility (Actions.work): its line hangs on a box's wall, a relay (a junction box or a
-- yard hydrant) or a device already on a line (BU.Links), each box in reach offered with where it would hang. A thing
-- whose line supplies nothing says why; a cut branch is hung on again at its first line, on any box in reach, and a
-- line whose box is gone is taken up. The box's window lists what is wired. What is done with
-- the thing itself (a box's or a rack's window, a unit's state and work) goes to the top of the menu; tying it to a
-- box and taking a line away go to its end, over the game's destroy and walk lines (PZUIKit.Menu), the ties first. A
-- box and the units are taken up with the game's furniture tool (BU.Moveables).
-- The inventory menu: put a box or a unit down (the game's furniture cursor, Moveables.lua), take a box apart,
-- recondition a battery. A box's line offers learning its design while its recipe is not known.
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/ISMoveableContextMenu"
require "BuildingUtilities/Actions"
require "BuildingUtilities/Moveables"
require "BuildingUtilities/Manual"
require "PZUIKit/Menu"
local BU = BuildingUtilities
local Store, Panels, Units, Rack, Costs, Actions, Sync, Links = BU.Store, BU.Panels, BU.Units, BU.Rack, BU.Costs,
    BU.Actions, BU.Sync, BU.Links
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

local function onActivate(playerObj, x, y, z) queueAt(playerObj, x, y, z, ISBUActivateBox:new(playerObj, x, y, z)) end

local function onTakeBox(playerObj, x, y, z) queueAt(playerObj, x, y, z, ISBUTakeBox:new(playerObj, x, y, z)) end

-- A box taken up in both hands (ISBUTakeBox), with the options that take things away at the menu's end.
local function addTakeOption(context, playerObj, x, y, z)
    removal(context:addOption(getText("ContextMenu_BU_TakeBox"), playerObj, onTakeBox, x, y, z))
end

local function onReverseEngineer(playerObj, panel)
    queueAt(playerObj, panel.x, panel.y, panel.z, ISBUReverseEngineer:new(playerObj, panel))
end

local function onConnect(playerObj, kind, panel, utility, x, y, z, extra)
    queueAt(playerObj, x, y, z, ISBUConnect:new(playerObj, kind, panel, utility, x, y, z, extra))
end

local function onDisconnect(playerObj, kind, panel, utility, x, y, z, extra)
    queueAt(playerObj, x, y, z, ISBUDisconnect:new(playerObj, kind, panel, utility, x, y, z, extra))
end

-- Why a line cannot be laid there, for the player: a reason of Actions.lineCost (and the tier, for "needsTier").
local function reasonText(reason, tier, panel)
    if reason == "needsTier" then return getText("IGUI_BU_NeedsTier", tier) end
    if reason == "relays" then
        local limit = BU.relayLimit(panel.tier)
        if (panel.tier or 1) < BU.TIERS then
            return getText("IGUI_BU_Reason_relaysMore", limit, BU.relayLimit((panel.tier or 1) + 1))
        end
        return getText("IGUI_BU_Reason_relays", limit)
    end
    if reason == "chain" then return getText("IGUI_BU_Reason_chain", BU.CHAIN_LIMIT) end
    return getText("IGUI_BU_Reason_" .. reason)
end

-- Where a line hangs, for its option: its length to the wall, a relay or the device it hangs on (and how many that
-- line then carries); none in the zone.
local function placeNote(panel, place)
    if place.from == "wall" then
        if place.length == 0 then return getText("IGUI_BU_HangsInZone") end
        return getText("IGUI_BU_HangsOn_wall", place.length)
    end
    if place.from == "relay" then return getText("IGUI_BU_HangsOn_relay", place.length) end
    local state = Links.state(panel)
    local head = state.head[place.via] or place.via
    return getText("IGUI_BU_HangsOn_chain", place.length, (state.chained[head] or 0) + 1, BU.CHAIN_LIMIT)
end

-- Whether the character knows of the boxes: has learned their design, read a box's manual, or a box stands in the
-- world. A box is found first: before that a generator, a rain barrel or a unit found in the loot says nothing of one.
local function knowsBoxes(playerObj)
    if playerObj:isRecipeActuallyKnown(Panels.RECIPE) or BU.Manual.state(playerObj, "connect") ~= nil then return true end
    for _ in pairs(Store.panels()) do return true end
    return false
end

-- The boxes a line could hang on (Links.offers), each an option with what its line takes and where it hangs, or why
-- not; the nearest first; none in reach is told only to a character who knows of the boxes (knowsBoxes). kind and
-- extra as Actions.lineCost; label(panel) the option's text; relay and except as Links.placeOn. Offers worked out by
-- the caller may be given.
local function addConnectOptions(context, playerObj, kind, utility, x, y, z, extra, label, relay, except, offers)
    offers = offers or Links.offers(utility, x, y, z, relay, except)
    if #offers == 0 then
        if not knowsBoxes(playerObj) then return end
        unavailable(tie(context:addOption(label and label(nil) or getText("ContextMenu_BU_ConnectTo"), nil, nil)),
            getText("IGUI_BU_NoPanelInReach"))
        return
    end
    for _, offer in ipairs(offers) do
        local panel = offer.panel
        local text = label and label(panel) or getText(kind == "rehang" and "ContextMenu_BU_Rehang" or "ContextMenu_BU_ConnectToPanel",
            Panels.name(panel), Panels.where(panel, x, y, z))
        local option = tie(context:addOption(text, playerObj, onConnect, kind, panel, utility, x, y, z, extra))
        local cost, second, third = Actions.lineCost(kind, panel, utility, x, y, z, extra)
        if cost then costed(option, playerObj, cost, placeNote(panel, third))
        else unavailable(option, reasonText(second, third, panel)) end
    end
end

-- "Disconnect from <box>", or with its box gone "Take the line up": what it takes (the tool), not available without it.
local function addDisconnectOption(context, playerObj, panel, kind, utility, x, y, z, extra, text)
    text = text or (panel and getText("ContextMenu_BU_DisconnectFrom", Panels.name(panel)) or getText("ContextMenu_BU_LineTakeUp"))
    local option = removal(context:addOption(text, playerObj, onDisconnect, kind, panel, utility, x, y, z, extra))
    costed(option, playerObj, Actions.workCost(utility))
end

-- A thing with a line (ref): why it supplies nothing (cut, past a limit; BU.Links), hanging its cut branch on again
-- at its first line (on any box in reach), and taking the line up. removeText: the take-up option's text, when not
-- the plain one.
local function addLineOptions(context, playerObj, kind, ref, x, y, z, extra, removeText)
    local line = Links.get(ref)
    local panel = Store.get(line.panel)
    -- (a line that supplies has no reason: `panel and nil or "cut"` would call it cut)
    local reason = "cut"
    if panel then reason = Links.reason(panel, ref) end
    if reason == "cut" and Links.cutHead(ref) == line then
        local except = {}
        for _, each in ipairs(Links.branch(ref)) do except[each.ref] = true end
        addConnectOptions(context, playerObj, "rehang", line.utility, x, y, z, ref, nil, Links.isRelay(ref), except)
    elseif reason then
        tooltip(tie(context:addOption(getText("IGUI_BU_LineNotSupplied"), nil, nil)), Links.reasonText(panel, ref))
    end
    addDisconnectOption(context, playerObj, panel, kind, line.utility, x, y, z, extra, removeText)
end

-- A device of the box's building switched at once, as its tick in the window.
local function onSwitchInside(playerObj, panel, utility, key, on)
    Sync.send(playerObj, "setInside", { panel = panel.id, utility = utility, key = key, on = on })
end

-- The box's line: its name (a tripped breaker told), which walks there and opens its window. The breaker, the main
-- switch, the source, the upgrade and the lines are all in the window.
-- A box's design, learned at it while the recipe is not known (Panels.reverseEngineerProblem): at a box's record or a
-- bare box's place ({ x, y, z }).
local function addLearnOption(context, playerObj, at)
    local problem = Panels.reverseEngineerProblem(playerObj)
    if problem == "known" then return end
    local learn = context:addOption(getText("ContextMenu_BU_ReverseEngineer"), playerObj, onReverseEngineer, at)
    if problem == "dark" then
        unavailable(learn, getText("IGUI_BU_Reason_dark"))
    else
        costed(learn, playerObj, Costs.reverseEngineer(), getText("IGUI_BU_ReverseEngineerNote"))
    end
end

local function addPanelOptions(context, playerObj, panel)
    -- The breaker is power's: with power off in the sandbox it is not told.
    local tripped = panel.tripped and BU.enabled("power")
    local name = tripped and getText("IGUI_BU_NameTripped", Panels.name(panel)) or Panels.name(panel)
    local option = context:addOptionOnTop(name, playerObj, onOpen, panel)
    if not BU.api() then unavailable(option, apiMissingText()) end
    addLearnOption(context, playerObj, panel)
    addTakeOption(context, playerObj, panel.x, panel.y, panel.z)
end

-- A bare box (Panels.isBare): made a box where it stands (ISBUActivateBox, where a box may be put: Panels.canInstall),
-- and its design to learn. It can also be taken up with the game's furniture tool (Moveables) and put down elsewhere.
local function addBareOptions(context, playerObj, object)
    local square = object:getSquare()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local option = context:addOptionOnTop(getText("ContextMenu_BU_ActivateBox"), playerObj, onActivate, x, y, z)
    local ok, reason = Panels.canInstall(square)
    if not BU.api() then
        unavailable(option, apiMissingText())
    elseif not ok then
        unavailable(option, getText("IGUI_BU_Reason_" .. (reason or "blocked")))
    else
        tooltip(option, getText("IGUI_BU_ActivateBoxTip"))
    end
    addLearnOption(context, playerObj, { x = x, y = y, z = z })
    addTakeOption(context, playerObj, x, y, z)
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
    local ref = Links.producerRef(x, y, z)
    if Links.get(ref) then
        addLineOptions(context, playerObj, "producer", ref, x, y, z)
        return
    end
    addConnectOptions(context, playerObj, "producer", utility, x, y, z)
end

-- Units.

local function onUnitAction(playerObj, unit, action) queueAt(playerObj, unit.x, unit.y, unit.z, action(playerObj, unit)) end

local function onOpenRack(playerObj, unit) queueAt(playerObj, unit.x, unit.y, unit.z, ISBUOpenRack:new(playerObj, unit)) end

-- A unit's lines, no submenu: a rack's name, which opens its window (BU.RackWindow); another's state, when its kind
-- shows one (Units.define title); what its kind offers now (Units.define: clearing snow, a new filter charge); with a
-- line, why it supplies nothing and taking it up; without, the boxes its line can hang on. The unit is taken up with
-- the furniture tool. One of a kind that is off (BU.enabled) is only named.
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
    local ref = Links.unitRef(unit)
    if Links.get(ref) then
        addLineOptions(context, playerObj, "unit", ref, unit.x, unit.y, unit.z, unit.id)
        return
    end
    addConnectOptions(context, playerObj, "unit", Units.utility(unit), unit.x, unit.y, unit.z, unit.id, nil,
        BU.RELAY_KINDS[unit.kind] ~= nil)
end

-- A device: in a box's zone, switched at that box (free) from the tier that cuts devices (Panels.cuts); outside, by its
-- line: with one, switched at its box the same way, why it supplies nothing and taking it up; without, the boxes its
-- line can hang on.
local function addDeviceOption(context, playerObj, utility, panel, device, offers)
    local entry = device.entry
    local name = BU.displayName(entry.x, entry.y, entry.z, entry.sprite)
    local label = getText("ContextMenu_BU_Utility_" .. utility)
    if device.inside then
        if not Panels.cuts(panel) then return nil end
        local on = device.state == "on"
        return tie(context:addOption(getText(on and "ContextMenu_BU_DeviceOff" or "ContextMenu_BU_DeviceSwitchOn", name,
            label, Panels.name(panel)), playerObj, onSwitchInside, panel, utility, device.key, not on))
    end
    local ref
    for _, key in ipairs(device.keys) do
        if Links.get(Links.deviceRef(key)) then ref = Links.deviceRef(key) break end
    end
    if not ref then
        if utility == "power" and not BU.exteriorPower() then
            unavailable(tie(context:addOption(getText("ContextMenu_BU_DeviceOn", name, label, ""), nil, nil)),
                getText("IGUI_BU_Reason_exteriorOff"))
            return nil
        end
        addConnectOptions(context, playerObj, "outside", utility, entry.x, entry.y, entry.z, entry.sprite,
            function(each) return getText("ContextMenu_BU_DeviceOn", name, label, each and Panels.name(each) or "") end,
            nil, nil, offers)
        return nil
    end
    local line = Links.get(ref)
    local owner = Store.get(line.panel)
    if owner and Panels.cuts(owner) and Links.live(owner, ref) then
        local on = not owner[utility].excluded[line.ref:sub(3)]
        tie(context:addOption(getText(on and "ContextMenu_BU_DeviceOff" or "ContextMenu_BU_DeviceSwitchOn", name, label,
            Panels.name(owner)), playerObj, onSwitchInside, owner, utility, line.ref:sub(3), not on))
    end
    addLineOptions(context, playerObj, "outside", ref, entry.x, entry.y, entry.z, entry.sprite,
        owner and getText("ContextMenu_BU_LineRemove", name, label, Panels.name(owner)) or nil)
    return nil
end

local function uses(object, utility)
    if utility == "power" then return object:couldBePoweredByGenerator() end
    return object:getProperties() ~= nil and object:getProperties():has(IsoFlagType.waterPiped)
end

-- The objects that are devices of a panel, each once: { panel, device, utility, offers }: one in a box's zone or near
-- its building as the box lists it (Panels.deviceOf: the panels near each square and their devices found once for the
-- menu); one outside any building that no box lists, when it has a line or a box its line can hang on (offers).
local function squareDevices(objects)
    local result, seen, cache = {}, {}, {}
    for _, object in ipairs(objects) do
        for _, utility in ipairs(BU.UTILITIES) do
            if BU.enabled(utility) and uses(object, utility) then
                local panel, device = Panels.deviceOf(object, utility, cache)
                local offers
                local square = object:getSquare()
                local sprite = BU.objectName(object)
                if not device and square and sprite and not Panels.buildingAt(square:getX(), square:getY(), square:getZ()) then
                    device = Panels.deviceAt(utility, square:getX(), square:getY(), square:getZ(), sprite)
                    if device and not device.owner and not Links.get(Links.deviceRef(device.key)) then
                        offers = Links.offers(utility, square:getX(), square:getY(), square:getZ())
                        if #offers == 0 then device = nil end
                    end
                end
                if device and not seen[device.key .. utility] then
                    seen[device.key .. utility] = true
                    result[#result + 1] = { panel = panel, device = device, utility = utility, object = object,
                        offers = offers }
                end
            end
        end
    end
    return result
end

local function addDeviceOptions(context, playerObj, objects)
    for _, found in ipairs(squareDevices(objects)) do
        addDeviceOption(context, playerObj, found.utility, found.panel, found.device, found.offers)
    end
end

-- Whether the menu has an option of this mod for the square, without building it: the controller's test pass.
local function hasOptions(objects)
    for _, object in ipairs(objects) do
        if Panels.ofObject(object) or Panels.isBare(object) or Units.ofObject(object) then return true end
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
        if panel then addPanelOptions(context, playerObj, panel)
        elseif Panels.isBare(object) then addBareOptions(context, playerObj, object) end
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
    if BU.PANEL_ITEM_TIER[fullType] then return "panel" end
    for _, kind in ipairs(Units.KINDS) do
        if Units.definition(kind).item == fullType then return kind end
    end
    return nil
end

-- Takes out of the menu the game's own place option for the item (it opens the same cursor; this mod's stays). The
-- game removes an option by its name, the first with it, which another item's or mod's could be: the option found is
-- given a name of its own for that.
local DROPPED = "BuildingUtilities.dropped"
local function dropGamesOwn(context, item)
    local name = getText("IGUI_PlaceObject")
    for _, option in ipairs(context.options) do
        if option.name == name and option.target == item and option.onSelect == ISMoveableContextMenu.openMovableCursor then
            option.name = DROPPED
            context:removeOptionByName(DROPPED)
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

local function onTakeApart(playerObj, item)
    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
    ISTimedActionQueue.add(ISBUTakeApartBox:new(playerObj, item))
end

-- Taking a box apart for its control boards (Costs.takeApart), from the inventory.
local function addTakeApart(context, playerObj, item)
    local option = context:addOption(getText("ContextMenu_BU_TakeApart"), playerObj, onTakeApart, item)
    costed(option, playerObj, Costs.takeApart(),
        getText("IGUI_BU_TakeApartNote", Costs.boardsIn(Panels.itemTier(item))))
end

function ContextMenu.fillInventory(player, context, items)
    local playerObj = getSpecificPlayer(player)
    if not playerObj or #items ~= 1 then return end
    local item = items[1]
    if not instanceof(item, "InventoryItem") then item = item.items and item.items[1] end
    if not item then return end
    -- The game offers placing only from the inventory proper and not from the hands (ISMoveableContextMenu); so here.
    -- A box is carried in both hands (a heavy item: BU.Moveables) and put down from there; one lying about (on the
    -- floor, in a crate) is taken up into them first, as a generator is.
    local kind = placedKind(item)
    if kind then
        dropGamesOwn(context, item)
        local held = playerObj:getPrimaryHandItem() == item or playerObj:getSecondaryHandItem() == item
        if kind == "panel" and not held then
            context:addOptionOnTop(getText("ContextMenu_BU_TakeBox"), playerObj, ISInventoryPaneContextMenu.equipHeavyItem,
                item).itemForTexture = item
        end
        if BU.enabled(kind) and item:getContainer() == playerObj:getInventory() and (kind == "panel" or not held) then
            local text = getText(kind == "panel" and "ContextMenu_BU_Install" or "ContextMenu_BU_Install_" .. kind)
            local option = context:addOptionOnTop(text, playerObj, onPlace, item)
            option.itemForTexture = item
            if not BU.api() then unavailable(option, apiMissingText()) end
        end
        if kind == "panel" and BU.enabled("panel") then addTakeApart(context, playerObj, item) end
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
