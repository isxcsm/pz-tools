-- The right-click menus of the mod's parts, with a fake context menu: every option the mod adds goes on top of what the
-- game's menu holds, in the order the part means (first option first), and no menu is built by a search of the
-- inventory (a search is made when the player picks the option). The game's UI classes are stand-ins, the character's
-- inventory refuses to be searched.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
local OA = OperationAcorn

-- ---------------------------------------------------------------------------------------------------------------------
-- Fakes

local UI = { "ISPanel", "ISPanelJoypad", "ISButton", "ISToolTip", "ISToolTipInv", "ISModalDialog", "ISContextMenu",
    "ISCharacterInfoWindow", "ISWorldObjectContextMenu", "ISInventoryTransferAction", "ISInventoryPaneContextMenu",
    "ISBaseTimedAction", "ISInventoryPane", "ISMoveableContextMenu", "ISCollapsableWindow", "ISLabel",
    "ISScrollingListBox", "ISRichTextPanel", "ISVehicleMechanics" }

-- A UI class whose members are all functions that do nothing, and whose derived classes are the same (kept in
-- `derived`, for a test that wants the class a file made).
local derived = {}
local function stubClass()
    local c = {}
    c.derive = function()
        local d = stubClass()
        derived[#derived + 1] = d
        return d
    end
    return setmetatable(c, { __index = function() return function() end end })
end

-- A menu that adds as the game's does: at the bottom, or on top. `names()` reads the options top to bottom.
local function newMenu()
    local menu = { options = {}, numOptions = 1 }
    local function option(name, target, fn, a, b)
        return { name = name, target = target, onSelect = fn, param1 = a, param2 = b }
    end
    function menu:addOption(name, target, fn, a, b)
        local o = option(name, target, fn, a, b)
        self.options[#self.options + 1] = o
        self.bottom = (self.bottom or 0) + 1
        return o
    end
    function menu:addOptionOnTop(name, target, fn, a, b)
        local o = option(name, target, fn, a, b)
        table.insert(self.options, 1, o)
        return o
    end
    function menu:addSubMenu(o, sub) o.subOption = sub end
    function menu:removeOptionByName(name)
        for i, o in ipairs(self.options) do
            if o.name == name then table.remove(self.options, i) return end
        end
    end
    function menu:names()
        local list = {}
        for _, o in ipairs(self.options) do list[#list + 1] = o.name end
        return table.concat(list, ",")
    end
    return menu
end

-- Loads a file of the mod with the UI stand-ins (the game's own files are not here), then takes them away again.
local function loadFile(name, skip)
    for _, class in ipairs(UI) do _G[class] = stubClass() end
    ISContextMenu.getNew = function() return newMenu() end
    ISContextMenu.get = function() TEST.opened = newMenu() return TEST.opened end
    ISInventoryPane.getActualItems = function(items) return items end
    ISToolTip.new = function() return { initialise = function() end, setVisible = function() end } end
    ISWorldObjectContextMenu.addToolTip = function() return {} end
    ISInventoryPaneContextMenu.addToolTip = function() return {} end
    ISMoveableContextMenu.openMovableCursor = function(item, player) TEST.cursor = { item, player } end
    UIFont = setmetatable({}, { __index = function() return 1 end })
    getTextManager = function()
        return setmetatable({}, { __index = function() return function() return 10 end end })
    end
    getMouseX = function() return 0 end
    getMouseY = function() return 0 end
    HaloTextHelper = { addBadText = function(_, text) TEST.halo = text end }
    local real = require
    require = function(file)
        if string.find(file, "^ISUI/") or string.find(file, "^XpSystem/") or string.find(file, "^TimedActions/")
            or string.find(file, "^Vehicles/") or string.find(file, "^Moveables/") or (skip and skip[file]) then
            return true
        end
        return real(file)
    end
    local ok, err = pcall(real, name)
    require = real
    if not ok then error(err, 0) end
end

-- A character whose inventory must not be searched: any call on it fails.
local function character(id)
    local c = { md = { OA_Id = id or "p1" } }
    function c:getModData() return self.md end
    function c:getVehicle() return nil end
    function c:getPlayerNum() return 0 end
    function c:getPrimaryHandItem() return nil end
    function c:getSecondaryHandItem() return nil end
    c.inventory = setmetatable({}, { __index = function(_, key)
        return function() error("the inventory was searched: " .. tostring(key)) end
    end })
    function c:getInventory() return self.inventory end
    return c
end

local player
local function setup()
    TEST.halo, TEST.opened, TEST.cursor = nil, nil, nil
    player = character("p1")
    getSpecificPlayer = function() return player end
    getPlayer = function() return player end
    instanceof = function(o, class) return type(o) == "table" and o.classes ~= nil and o.classes[class] == true end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The trade part

local function thing(kind, md)
    md = md or {}
    md.OA_Kind = kind
    local square = { haveElectricity = function() return true end, hasGridPower = function() return false end }
    return { hasModData = function() return true end, getModData = function() return md end,
        getSquare = function() return square end }
end

test("the terminal's option is on top of the world menu", function()
    setup()
    loadFile("OperationAcorn/Trade/ContextMenu")
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { thing("terminal") }, false)
    eq(menu:names(), "ContextMenu_OA_Trade_UseTerminal,Vanilla")
end)

test("a delivery box's seal and load options go on top in that order, and nothing nearby is searched for them", function()
    setup()
    loadFile("OperationAcorn/Trade/ContextMenu")
    OA.Trade.Things.bulkPlan = function() error("the box's surroundings were searched for the menu") end
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { thing("box") }, false)
    eq(menu:names(), "ContextMenu_OA_Trade_SealBox,ContextMenu_OA_Trade_LoadBox,Vanilla")
    -- picking "load" looks, and says so when nothing is there
    OA.Trade.Things.bulkPlan = function() return { count = 0, moves = {}, weight = 0 } end
    local loadOption = menu.options[2]
    loadOption.onSelect(loadOption.target, loadOption.param1)
    eq(TEST.halo, "ContextMenu_OA_Trade_LoadNothing")
end)

test("breaking a crate's seal is on top, its tip does not depend on a crowbar being carried", function()
    setup()
    loadFile("OperationAcorn/Trade/ContextMenu")
    local menu = newMenu()
    menu:addOption("Vanilla")
    local crate = thing("crate", { OA_Sealed = true })
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { crate }, false)
    eq(menu:names(), "ContextMenu_OA_Trade_Unseal,Vanilla")
    eq(menu.options[1].toolTip.description, "ContextMenu_OA_Trade_UnsealTip")
end)

test("the manifest is read from the top of the inventory menu", function()
    setup()
    loadFile("OperationAcorn/Trade/ContextMenu")
    player.isItemInBothHands = function() return false end
    local item = { getFullType = function() return "OperationAcorn.SupplyManifest" end }
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillInventoryObjectContextMenu", 0, menu, { item })
    eq(menu:names(), "ContextMenu_OA_Trade_ReadManifest,Vanilla")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- The story

test("the stake comes first and the soil sample second, both on top of the world menu", function()
    setup()
    OA.Client = { record = function() return nil end, id = function() return "p1" end }
    loadFile("OperationAcorn/Story/Menus", { ["OperationAcorn/Client"] = true })
    -- a mission that wants the soil, near enough, and a stake in the clicked things
    local mission = { soil = { variant = "ground" }, state = "open" }
    OA.StoryView.live = function() return { mission } end
    OA.Client.record = function() return { missions = { active = mission } } end
    local square = { isOutside = function() return true end, getFloor = function() return {} end }
    local stake = { getModData = function() return { OA_StakeNo = 3 } end, getSquare = function() return square end }
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { stake }, false)
    eq(menu:names(), "ContextMenu_OA_Story_ReadStake,ContextMenu_OA_Story_TakeSoil,Vanilla")
end)

test("the field call and leaving the sample case ask first: nothing is sent until the answer is yes", function()
    setup()
    OA.Client = { record = function() return nil end, id = function() return "p1" end }
    loadFile("OperationAcorn/Story/Menus", { ["OperationAcorn/Client"] = true })
    local mission = { field = {}, swap = { stage = "needcase" }, state = "open" }
    OA.StoryView.live = function() return { mission } end
    OA.Client.record = function() return { missions = { active = mission } } end
    local asked, sent = {}, {}
    OA.Trade.UI.confirm = function(_, text, target, onYes) asked[#asked + 1] = { text = text, yes = function() onYes(target) end } end
    local send = OA.Sync.send
    OA.Sync.send = function(_, command) sent[#sent + 1] = command end
    local function item(name)
        return { getFullType = function() return "OperationAcorn." .. name end, getModData = function() return {} end }
    end
    local menu = newMenu()
    TEST.fire("OnFillInventoryObjectContextMenu", 0, menu, { item("FieldCallDevice"), item("SampleCase") })
    eq(menu:names(), "ContextMenu_OA_Story_FieldCall,ContextMenu_OA_Story_LeaveCase")
    for _, o in ipairs(menu.options) do o.onSelect(o.target) end
    eq(#asked, 2); eq(#sent, 0, "nothing sent before the answer")
    eq(asked[1].text, "IGUI_OA_Story_FieldCallAsk"); eq(asked[2].text, "IGUI_OA_Story_LeaveCaseAsk")
    asked[1].yes(); asked[2].yes()
    OA.Sync.send = send
    eq(table.concat(sent, ","), "story_field,story_swap")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- The upgrades: locked doors

local function lockedDoor()
    return { classes = { IsoDoor = true }, isLocked = function() return true end, isLockedByKey = function() return false end,
        getSprite = function() return nil end, getProperties = function() return { has = function() return false end } end,
        getSquare = function() return nil end }
end

test("the pry and pick options go on top in that order and do not search the inventory for the tools", function()
    setup()
    loadFile("OperationAcorn/Upgrades/Hooks")
    local record = OA.Store.ensure("p1", "P")
    record.upgrades = { ranks = { crowbar = 1, lock = 1 } }
    IsoObjectPicker = { Instance = { PickVehicle = function() return nil end } }
    getMouseXScaled = function() return 0 end
    getMouseYScaled = function() return 0 end
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { lockedDoor() }, false)
    eq(#menu.options, 3)
    truthy(string.find(menu.options[1].name, "ContextMenu_OA_Tree_Pry", 1, true), menu.options[1].name)
    truthy(string.find(menu.options[2].name, "ContextMenu_OA_Tree_Pick", 1, true), menu.options[2].name)
    eq(menu.options[3].name, "Vanilla")
    truthy(not menu.options[1].notAvailable, "a missing tool is not known by the menu")
end)

test("picking the pry option without a pry bar says what is missing", function()
    setup()
    loadFile("OperationAcorn/Upgrades/Hooks")
    local record = OA.Store.ensure("p1", "P")
    record.upgrades = { ranks = { crowbar = 1 } }
    IsoObjectPicker = { Instance = { PickVehicle = function() return nil end } }
    getMouseXScaled = function() return 0 end
    getMouseYScaled = function() return 0 end
    local menu = newMenu()
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { lockedDoor() }, false)
    -- the tools are looked for when the option is picked: here, none
    player.inventory = {
        getFirstTagEvalRecurse = function() return nil end,
        getFirstTypeRecurse = function() return nil end,
    }
    ItemTag = { CROWBAR = "crowbar", PRY_BAR = "prybar", SCREWDRIVER = "screwdriver" }
    local pry = menu.options[1]
    pry.onSelect(pry.target, pry.param1, pry.param2)
    eq(TEST.halo, "Tooltip_OA_Tree_NeedPryBar")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- The machines

test("install is on top of the menu of the lure and of a machine's piece, and the game's own place option goes", function()
    setup()
    loadFile("OperationAcorn/Machines/Menu")
    local Machines = OA.Machines
    ISOAMachineCursor = { start = function(character, kind, item) TEST.started = { character, kind, item } end }
    local lure = { getFullType = function() return Machines.itemFullType("lure") end }
    local sprite = Machines.spriteName("bulkShredder", "S", false)
    local piece = { classes = { Moveable = true }, getFullType = function() return "Moveables.Piece" end,
        getWorldSprite = function() return sprite end, getContainer = function() return player.inventory end }
    -- the lure: its option opens the placing cursor
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillInventoryObjectContextMenu", 0, menu, { lure })
    eq(menu:names(), "ContextMenu_OA_Machine_Install,Vanilla")
    local install = menu.options[1]
    install.onSelect(install.target, install.param1)
    eq(TEST.started[2], "lure")
    eq(TEST.started[3], lure)
    -- the piece: the game offers its own, which is taken out; ours opens the same furniture cursor
    local own = newMenu()
    own:addOption("Vanilla")
    own:addOption(getText("IGUI_PlaceObject"), piece, ISMoveableContextMenu.openMovableCursor, player)
    TEST.fire("OnFillInventoryObjectContextMenu", 0, own, { piece })
    eq(own:names(), "ContextMenu_OA_Machine_Install,Vanilla")
    local ours = own.options[1]
    ours.onSelect(ours.target, ours.param1)
    eq(TEST.cursor[1], piece)
    eq(TEST.cursor[2], player)
    -- some other furniture is left alone
    local couch = { classes = { Moveable = true }, getFullType = function() return "Moveables.Couch" end,
        getWorldSprite = function() return "furniture_seating_01_0" end, getContainer = function() return player.inventory end }
    local other = newMenu()
    other:addOption(getText("IGUI_PlaceObject"), couch, ISMoveableContextMenu.openMovableCursor, player)
    TEST.fire("OnFillInventoryObjectContextMenu", 0, other, { couch })
    eq(other:names(), "IGUI_PlaceObject")
end)

test("the ground menu offers no placing, and a machine's menu is built without searching for what to shred", function()
    setup()
    loadFile("OperationAcorn/Machines/Menu")
    local Machines = OA.Machines
    local object = {}
    local square = { getObjects = function() return { size = function() return 0 end } end }
    local clicked = { getSquare = function() return square end }
    Machines.at = function() return object end
    Machines.state = function() return { kind = "shredBench", id = "m1", on = true } end
    Machines.benchCandidates = function() error("the inventory was searched for the menu") end
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { clicked }, false)
    eq(menu:names(), "IGUI_OA_Machine_Name_shredBench,Vanilla", "the machine's, on top; no place option for the lure")
    local sub = menu.options[1].subOption
    local shred
    for _, o in ipairs(sub.options) do
        if o.name == "ContextMenu_OA_Machine_Shred" then shred = o end
    end
    truthy(shred, "the shred option is there")
    -- picking it looks for what the character carries, and lists it
    local entries = {}
    for i = 1, 3 do
        entries[i] = { item = { getFullType = function() return "Base.Pliers" end, getName = function() return "Pliers" end } }
    end
    Machines.benchCandidates = function() return entries end
    shred.onSelect(shred.target, shred.param1)
    eq(#TEST.opened.options, 2, "all of it, and the one kind")
    eq(TEST.opened.options[1].name, "ContextMenu_OA_Machine_ShredAll 3")
    -- and with nothing to shred, it says so
    Machines.benchCandidates = function() return {} end
    shred.onSelect(shred.target, shred.param1)
    eq(TEST.halo, "IGUI_OA_Machine_Reason_nothingToShred")
end)

test("a machine with a window is one option, its name, that opens the window; a lure's taking back is its own", function()
    setup()
    loadFile("OperationAcorn/Machines/Menu")
    local Machines = OA.Machines
    local object = {}
    local square = { getObjects = function() return { size = function() return 0 end } end }
    local clicked = { getSquare = function() return square end }
    Machines.at = function() return object end
    local kind = "bulkShredder"
    Machines.state = function() return { kind = kind, id = "m1", on = true } end
    Machines.canTakeLure = function() return true end
    Machines.nearSquare = function(o) return o:getSquare() end
    OAMachineWindow.open = function(character, machine) TEST.window = { character, machine } end
    local menu = newMenu()
    menu:addOption("Vanilla")
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { clicked }, false)
    eq(menu:names(), "IGUI_OA_Machine_Name_bulkShredder,Vanilla", "no switch, no submenu")
    local open = menu.options[1]
    eq(open.subOption, nil)
    truthy(open.toolTip, "what the machine is, on its option")
    -- picking it walks up to the machine first; the window opens when that is done
    local queued = {}
    luautils = luautils or {}
    luautils.walkAdj = function() return true end
    ISTimedActionQueue = { add = function(action) queued[#queued + 1] = action end }
    ISBaseTimedAction.new = function(class) return setmetatable({}, { __index = class }) end
    square.getX = function() return 10 end
    square.getY = function() return 20 end
    square.getZ = function() return 0 end
    object.getSquare = function() return square end
    open.onSelect(open.target, open.param1)
    eq(TEST.window, nil, "not before the walk")
    eq(#queued, 1)
    eq(queued[1].machineId, "m1")
    Machines.find = function() return object end
    queued[1]:perform()
    eq(TEST.window[2], object, "the window opens on the machine")

    kind = "lure"
    menu = newMenu()
    TEST.fire("OnFillWorldObjectContextMenu", 0, menu, { clicked }, false)
    eq(menu:names(), "IGUI_OA_Machine_Name_lure,ContextMenu_OA_Machine_TakeLure")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- The research window's fragment count

test("the research window counts the fragments again only when the inventory changed", function()
    setup()
    loadFile("OperationAcorn/Upgrades/Window", { ["OperationAcorn/Client"] = true })
    local View
    for _, class in ipairs(derived) do
        if rawget(class, "countFragments") then View = class end
    end
    truthy(View, "the window's class")
    local searches, items, weight = 0, 5, 10
    local inventory = {
        getItems = function() return { size = function() return items end } end,
        getContentsWeight = function() return weight end,
        getCountTypeRecurse = function() searches = searches + 1 return 7 end,
    }
    local view = { player = { getInventory = function() return inventory end } }
    getTimestampMs = function() return 1000 end
    View.countFragments(view)
    eq(searches, 1)
    eq(view.fragments, 7)
    View.countFragments(view)
    View.countFragments(view)
    eq(searches, 1, "the same inventory: not searched again")
    items = 6
    View.countFragments(view)
    eq(searches, 2, "an item came: searched")
    weight = 11
    View.countFragments(view)
    eq(searches, 3, "the weight changed: searched")
    View.countFragments(view, true)
    eq(searches, 4, "asked for: searched")
end)
