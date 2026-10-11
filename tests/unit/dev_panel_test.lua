-- The developer sub-mod (OperationAcornDev): its debug panel built on fake game widgets, every control driving a
-- function of OperationAcorn.Dev (the panel and tools/pzdev.py run the same code), and the helpers the panel added to
-- Dev with a fake world: the clock held, the mission's scene made without the distance rule.
isDebugEnabled = function() return true end
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Scene"
require "OperationAcorn/Upgrades/Texts"
local OA = OperationAcorn
local Data = OA.Upgrades.Data

-- ---------------------------------------------------------------------------------------------------------------------
-- Fake widgets: they keep what they were made with and their children, and can be clicked, ticked, moved and chosen.

local function noop() end
local function class(parent)
    local c = {}
    c.__index = c
    if parent then setmetatable(c, { __index = parent }) end
    function c:derive() return class(self) end
    function c:new(x, y, w, h, ...)
        local o = setmetatable({ x = x, y = y, width = w, height = h, args = { ... }, children = {}, visible = true }, self)
        if self.made then self.made(o) end
        return o
    end
    return c
end

local Widget = class()
for _, name in ipairs({ "initialise", "setWidth", "setHeight", "setY", "addToUIManager", "bringToTop", "removeFromUIManager",
    "setWidthToFit", "setValues", "createChildren" }) do
    Widget[name] = noop
end
function Widget:instantiate() self.javaObject = true self:createChildren() end
function Widget:addChild(child) self.children[#self.children + 1] = child end
function Widget:setVisible(on) self.visible = on end
function Widget:getIsVisible() return self.visible end
function Widget:isVisible() return self.visible ~= false end
function Widget:getY() return 0 end
function Widget:getHeight() return 0 end
function Widget:titleBarHeight() return 16 end

ISPanel = class(Widget)
ISLabel = class(Widget)
ISLabel.made = function(o) o.name = o.args[1] end
function ISLabel:setName(name) self.name = name end
ISButton = class(Widget)
ISButton.made = function(o) o.title = o.args[1] end
function ISButton:click() self.args[3](self.args[2], self) end
ISTickBox = class(Widget)
ISTickBox.made = function(o) o.state = false o.options = {} end
function ISTickBox:addOption(text) self.options[#self.options + 1] = text end
function ISTickBox:setSelected(_, on) self.state = on end
function ISTickBox:isSelected() return self.state end
function ISTickBox:tick(on)
    self.state = on
    self.args[3](self.args[2], 1, on)
end
ISSliderPanel = class(Widget)
function ISSliderPanel:setCurrentValue(value) self.value = value end
function ISSliderPanel:move(value)
    self.value = value
    self.args[2](self.args[1], value, self)
end
ISComboBox = class(Widget)
ISComboBox.made = function(o) o.items = {} o.selected = 1 end
function ISComboBox:addOptionWithData(text, data) self.items[#self.items + 1] = { text = text, data = data } end
function ISComboBox:getSelectedData() return self.items[self.selected].data end
function ISComboBox:choose(i)
    self.selected = i
    self.args[2](self.args[1], self)
end
ISTabPanel = class(Widget)
ISTabPanel.made = function(o) o.tabHeight = 20 o.views = {} end
function ISTabPanel:addView(name, view)
    self.views[#self.views + 1] = { name = name, view = view }
    self.children[#self.children + 1] = view
end
function ISTabPanel:getActiveView() return self.active or self.views[1].view end
ISCollapsableWindow = class(Widget)
ISCollapsableWindow.prerender = noop

UIFont = { Small = 1 }
Keyboard = { KEY_F8 = 66 }
getTextManager = function()
    return { getFontHeight = function() return 14 end, MeasureStringX = function(_, _, text) return 7 * #tostring(text) end }
end
getCore = function() return { getScreenWidth = function() return 1920 end } end
local player = { mod = { OA_Id = "p1" } }
function player:getModData() return self.mod end
getPlayer = function() return player end

require "OperationAcorn/Dev/Dev"
local Dev = OA.Dev
do
    local real = require
    require = function(file)
        if string.find(file, "^ISUI/") or string.find(file, "^RadioCom/") then return true end
        return real(file)
    end
    require "OperationAcorn/Dev/Panel"
    require = real
end
local Panel = OA.DevPanel

-- every control by walking the window
local function all(root, kind)
    local found = {}
    local function walk(w)
        for _, child in ipairs(w.children or {}) do
            if child.visible ~= false then
                if getmetatable(child) == kind then found[#found + 1] = child end
                walk(child)
            end
        end
    end
    walk(root)
    return found
end

local function buttonNamed(window, title)
    for _, b in ipairs(all(window, ISButton)) do
        if b.title == title then return b end
    end
    error("no button " .. title)
end

-- Dev's functions the panel calls, replaced by recorders; `calls` lists them as "name(args)".
local calls
local function record(name, result)
    Dev[name] = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        calls[#calls + 1] = name .. "(" .. table.concat(parts, ",") .. ")"
        return result
    end
end
local function fakeDev()
    calls = {}
    for _, name in ipairs({ "time", "freeze", "speed", "clearWeather", "rain", "storm", "nightSight", "setRank", "points",
        "clearResearch", "title", "replayTake", "gotoMission", "buildScene", "spawn", "clearZombies", "godMode",
        "invisible", "noClip", "heal" }) do
        record(name)
    end
    record("zombiesInBuilding")
    local counted = Dev.zombiesInBuilding
    Dev.zombiesInBuilding = function(...)
        counted(...)
        return 7, true
    end
    Dev.record = function() return { id = "p1" } end
    Dev.rank = function() return 0 end
    Dev.hour = function() return 12.5 end
    Dev.frozen = function() return false end
    Dev.nightSightOn = function() return false end
    Dev.flags = function() return false, true, false end
    Dev.mission = function() return nil, nil end
    Dev.missionPlace = function() return nil end
end

test("the panel opens from the key (F8) and shuts from it", function()
    fakeDev()
    TEST.fire("OnGameStart")
    TEST.fire("OnKeyPressed", 66)
    local window = Panel.window()
    truthy(window and window:getIsVisible(), "opened")
    TEST.fire("OnKeyPressed", 66)
    eq(window:getIsVisible(), false, "shut")
    TEST.fire("OnKeyPressed", 12)
    eq(window:getIsVisible(), false, "another key does nothing")
end)

test("six pages, each following the game when it is refreshed", function()
    fakeDev()
    Panel.toggle()
    local window = Panel.window()
    eq(#window.tabs.views, 6)
    for i, v in ipairs(window.tabs.views) do
        window.tabs.active = v.view
        window:refresh()
    end
end)

test("time page: the slider, the freeze, the speeds and the weather", function()
    fakeDev()
    Panel.toggle()
    local window = Panel.window()
    all(window, ISSliderPanel)[1]:move(21)
    all(window, ISTickBox)[1]:tick(true)
    buttonNamed(window, "2x"):click()
    buttonNamed(window, "||"):click()
    buttonNamed(window, "IGUI_OADev_Weather_Clear"):click()
    buttonNamed(window, "IGUI_OADev_Weather_Rain"):click()
    buttonNamed(window, "IGUI_OADev_Weather_Storm"):click()
    eq(table.concat(calls, " "), "time(21) freeze(true) speed(2) speed(0) clearWeather() rain(3) storm(3)")
end)

test("upgrades page: night sight, a node's rank by - and +, points, reset", function()
    fakeDev()
    Panel.toggle()
    local window = Panel.window()
    local page = window.tabs.views[2].view
    window.tabs.active = page
    window:refresh()
    local ticks = all(page, ISTickBox)
    ticks[1]:tick(true)
    local first = Data.treeNodes("scout")[1]
    local plus
    for _, b in ipairs(all(page, ISButton)) do
        if b.title == "+" and not plus then plus = b end
    end
    plus:click()
    buttonNamed(page, "+5"):click()
    buttonNamed(page, "IGUI_OADev_Up_Reset"):click()
    eq(table.concat(calls, " "), "nightSight(true) setRank(" .. first.id .. ",1) points(scout,5) clearResearch()")
end)

test("upgrades page: the second board lists its own nodes, and a - at rank 0 stays at 0", function()
    fakeDev()
    Panel.toggle()
    local window = Panel.window()
    local page = window.tabs.views[2].view
    window.tabs.active = page
    all(page, ISComboBox)[2]:choose(4)  -- the points combo comes first, then the tree
    local minus
    for _, b in ipairs(all(page, ISButton)) do
        if b.title == "-" and not minus then minus = b end
    end
    minus:click()
    local boardFirst
    for _, n in ipairs(Data.nodes) do
        if n.board and not boardFirst then boardFirst = n.id end
    end
    eq(calls[1], "setRank(" .. boardFirst .. ",0)")
end)

test("effects page: each title kind and the take", function()
    fakeDev()
    Panel.toggle()
    local window = Panel.window()
    local page = window.tabs.views[3].view
    all(page, ISComboBox)[1]:choose(2)
    buttonNamed(page, "IGUI_OADev_Fx_Capstone"):click()
    buttonNamed(page, "IGUI_OADev_Fx_TreeOpened"):click()
    buttonNamed(page, "IGUI_OADev_Fx_BoardOpened"):click()
    buttonNamed(page, "IGUI_OADev_Fx_Take"):click()
    eq(table.concat(calls, " "), "title(capstone,load) title(tree,load) title(board) replayTake()")
end)

test("mission page: go, build, count, and the count shows", function()
    fakeDev()
    Panel.toggle()
    local window = Panel.window()
    local page = window.tabs.views[4].view
    window.tabs.active = page
    buttonNamed(page, "IGUI_OADev_Ms_Goto"):click()
    buttonNamed(page, "IGUI_OADev_Ms_Build"):click()
    buttonNamed(page, "IGUI_OADev_Ms_Count"):click()
    eq(table.concat(calls, " "), "gotoMission() buildScene() zombiesInBuilding()")
    Dev.mission = function() return { place = "clinic", state = "open", scene = { built = false } },
        { placed = true, at = { x = 5, y = 6, z = 0 } } end
    Dev.missionPlace = function() return 5, 6, 0 end
    window:refresh()
    local text = {}
    for _, l in ipairs(all(page, ISLabel)) do text[#text + 1] = l.name end
    local joined = table.concat(text, "|")
    truthy(string.find(joined, "clinic", 1, true), "the mission")
    truthy(string.find(joined, "5, 6, 0", 1, true), "its place")
    truthy(string.find(joined, "IGUI_OADev_Ms_Zombies: 7", 1, true), "the count: " .. joined)
end)

test("zombies page: spawn with the count, outfit and harmless; clear", function()
    fakeDev()
    Panel.toggle()
    local window = Panel.window()
    local page = window.tabs.views[5].view
    local combos = all(page, ISComboBox)
    combos[1]:choose(3)
    buttonNamed(page, "IGUI_OADev_Z_Spawn"):click()
    combos[2]:choose(3)
    all(page, ISTickBox)[1]:tick(false)
    buttonNamed(page, "IGUI_OADev_Z_Spawn"):click()
    buttonNamed(page, "IGUI_OADev_Z_Clear30"):click()
    buttonNamed(page, "IGUI_OADev_Z_ClearAll"):click()
    eq(table.concat(calls, " "), "spawn(10,nil,true) spawn(10,Survivalist,false) clearZombies(30) clearZombies()")
end)

test("player page: the toggles follow the character and drive Dev", function()
    fakeDev()
    Panel.toggle()
    local window = Panel.window()
    local page = window.tabs.views[6].view
    window.tabs.active = page
    window:refresh()
    local ticks = all(page, ISTickBox)
    eq(ticks[2].state, true, "invisible is on in the fake")
    ticks[1]:tick(true)
    ticks[3]:tick(true)
    buttonNamed(page, "IGUI_OADev_P_Heal"):click()
    eq(table.concat(calls, " "), "godMode(true) noClip(true) heal()")
end)

test("a failing control shows on the status line instead of breaking the click", function()
    fakeDev()
    Dev.heal = function() error("boom") end
    Panel.toggle()
    local window = Panel.window()
    buttonNamed(window.tabs.views[6].view, "IGUI_OADev_P_Heal"):click()
    truthy(string.find(window.statusLabel.name, "boom", 1, true), "status: " .. tostring(window.statusLabel.name))
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- Dev's helpers with a fake world

test("freeze holds the clock at the hour it had, Dev.time moves the held hour, release lets go", function()
    local hour = 13
    getGameTime = function()
        return { getTimeOfDay = function() return hour end, setTimeOfDay = function(_, h) hour = h end }
    end
    Dev.freeze(true)
    hour = 14.5
    TEST.fire("OnTick")
    eq(hour, 13, "held")
    Dev.time(22)
    eq(hour, 22, "set")
    hour = 23
    TEST.fire("OnTick")
    eq(hour, 22, "held at the new hour")
    Dev.time(24)
    eq(hour, 23.99, "24 is the last minute of the day")
    Dev.freeze(false)
    hour = 5
    TEST.fire("OnTick")
    eq(hour, 5, "released")
end)

test("the scene is made without the distance rule, and the rule is back after", function()
    local made = {}
    OA.Store.players()["p1"] = { id = "p1" }
    local record = OA.Store.player("p1")
    local piece = { x1 = 1, x2 = 6, y1 = 1, y2 = 6, placed = true, at = { x = 3, y = 3, z = 0 } }
    record.missions = { active = { id = 1, place = "clinic", state = "open", items = { piece },
        scene = { arrived = false, built = false, props = { { type = "x" } }, guards = { {} } } } }
    OA.Scene.game = {
        loaded = function() return true end,
        placeProps = function() made[#made + 1] = "props" end,
        spawnGuards = function() made[#made + 1] = "guards" end,
        spawnSurvivor = function() made[#made + 1] = "survivor" end,
    }
    local before = OA.Scene.READY
    player.getX = function() return 5000 end
    player.getY = function() return 5000 end
    eq(Dev.buildScene(), true, "made far away from the piece")
    eq(table.concat(made, " "), "props guards")
    eq(OA.Scene.READY, before, "the rule is back")
    eq(record.missions.active.scene.built, true)
end)

test("the scene is not made, and says why, when the building is not loaded", function()
    OA.Store.players()["p1"] = { id = "p1" }
    local record = OA.Store.player("p1")
    local piece = { x1 = 1, x2 = 6, y1 = 1, y2 = 6, placed = true, at = { x = 3, y = 3, z = 0 } }
    record.missions = { active = { id = 1, place = "clinic", state = "open", items = { piece },
        scene = { arrived = false, built = false } } }
    OA.Scene.game = { loaded = function() return false end }
    player.getX = function() return 5000 end
    player.getY = function() return 5000 end
    eq(Dev.buildScene(), false)
    eq(record.missions.active.scene.built, false, "still to be built")
    eq(OA.Scene.READY, 40, "the rule is back")
end)
