-- Operation Acorn Dev: the debug panel. A window of the game's own widgets (window, tabs, buttons, tick boxes, a slider,
-- combo boxes) opened by a small button on the screen and by a key (F8 by default, a key bind in the mod options;
-- none of the game's own or of the keys bound in keysB42.ini is used). Every control calls a function of
-- OperationAcorn.Dev (Dev.lua), the same functions the command channel (tools/pzdev.py) runs. Debug mode only.
-- Mod Lua holds no letters past ASCII (the game reads them as U+FFFD): every text comes from IGUI_OADev_* keys.
if not isDebugEnabled() then return end
require "ISUI/ISPanel"
require "ISUI/ISLabel"
require "ISUI/ISButton"
require "ISUI/ISTickBox"
require "ISUI/ISComboBox"
require "ISUI/ISTabPanel"
require "ISUI/ISCollapsableWindow"
require "RadioCom/ISUIRadio/ISSliderPanel"
require "OperationAcorn/Core"
require "OperationAcorn/Dev/Dev"
local OA = OperationAcorn
local Dev = OA.Dev
local Panel = {}
OA.DevPanel = Panel

local MOD_ID = "OperationAcornDev"
local PAD, GAP = 10, 6
local WIDTH = 470
local REFRESH_MS = 400

local FH, ROW = 0, 0   -- the font's height and a control row's, read when the window is made
local window = nil      -- the panel's window of this game
local openButton = nil  -- the small button on the screen

local function T(key, ...)
    return getText("IGUI_OADev_" .. key, ...)
end

-- ---- the widgets -------------------------------------------------------------------------------------------------

-- What a control does goes through here: an error is shown on the panel's status line (and printed) instead of
-- breaking into the debugger in the middle of a click.
local function act(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            print("[dev] panel: " .. tostring(err))
            if window then window:say(T("Failed") .. " " .. tostring(err)) end
        end
    end
end

local function label(page, text, x, y, r, g, b)
    local l = ISLabel:new(x, y, FH, text, r or 0.9, g or 0.9, b or 0.9, 1, UIFont.Small, true)
    l:initialise()
    l:instantiate()
    page:addChild(l)
    return l
end

-- A button at x, y of at least w wide; returns it and the x after it.
local function button(page, text, x, y, w, fn)
    local width = math.max(w or 0, getTextManager():MeasureStringX(UIFont.Small, text) + 16)
    local b = ISButton:new(x, y, width, ROW, text, page, act(function(_, btn) fn(btn) end))
    b:initialise()
    b:instantiate()
    page:addChild(b)
    return b, x + width + GAP
end

-- A tick box with one option; fn gets its state. Returns it (box:setSelected(1, state) sets it without calling fn).
local function tick(page, text, x, y, fn)
    local box = ISTickBox:new(x, y, 20, ROW, "", page, act(function(_, _, selected) fn(selected) end))
    box:initialise()
    box:instantiate()
    box:addOption(text)
    box:setWidthToFit()
    page:addChild(box)
    return box
end

local function slider(page, x, y, w, min, max, step, shift, fn)
    local s = ISSliderPanel:new(x, y, w, ROW - 4, page, act(function(_, value) fn(value) end))
    s:initialise()
    s:instantiate()
    s:setValues(min, max, step, shift, true)
    s:setCurrentValue(min, true)
    page:addChild(s)
    return s
end

-- A combo box of { text, data } items; fn gets the chosen data.
local function combo(page, x, y, w, items, fn)
    local c = ISComboBox:new(x, y, w, ROW, page, act(function(_, box) if fn then fn(box:getSelectedData()) end end))
    c:initialise()
    c:instantiate()
    for _, item in ipairs(items) do c:addOptionWithData(item[1], item[2]) end
    page:addChild(c)
    return c
end

local function newPage(w, h)
    local p = ISPanel:new(0, 0, w, h)
    p:initialise()
    p:instantiate()
    p.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    p.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    return p
end

local function rowY(n)
    return PAD + (n - 1) * (ROW + GAP)
end

local function treeName(tree)
    local texts = OA.Upgrades and OA.Upgrades.Texts
    return texts and texts.treeName(tree) or tree
end

local function hourText(hour)
    local h = math.floor(hour)
    local m = math.floor((hour - h) * 60 + 0.5)
    if m >= 60 then
        h = h + 1
        m = 0
    end
    local function two(n) return n < 10 and ("0" .. string.format("%.0f", n)) or string.format("%.0f", n) end
    return two(h) .. ":" .. two(m)
end

-- ---- the pages ---------------------------------------------------------------------------------------------------
-- Each builds its controls on a page and gives the page a refresh (called while the page shows): the controls follow
-- the game's state.

local function timePage(page, w)
    local y = rowY(1)
    label(page, T("Time_Hour"), PAD, y + 2)
    local hourLabel = label(page, "", w - PAD - 60, y + 2)
    local hourSlider = slider(page, PAD, rowY(2), w - 2 * PAD, 0, 24, 0.25, 1, function(value)
        Dev.time(value)
        hourLabel:setName(hourText(value))
    end)
    local frozen = tick(page, T("Time_Freeze"), PAD, rowY(3), function(on) Dev.freeze(on) end)

    label(page, T("Time_Speed"), PAD, rowY(4) + 2)
    local x = PAD
    local speeds = { { "||", 0 }, { "1x", 1 }, { "2x", 2 }, { "3x", 3 }, { "4x", 4 } }
    for _, s in ipairs(speeds) do
        local _, nx = button(page, s[1], x, rowY(5), 40, function() Dev.speed(s[2]) end)
        x = nx
    end

    label(page, T("Weather"), PAD, rowY(6) + 2)
    local _, x2 = button(page, T("Weather_Clear"), PAD, rowY(7), 0, function() Dev.clearWeather() end)
    local _, x3 = button(page, T("Weather_Rain"), x2, rowY(7), 0, function() Dev.rain(3) end)
    button(page, T("Weather_Storm"), x3, rowY(7), 0, function() Dev.storm(3) end)

    page.refresh = function()
        local hour = Dev.hour()
        hourLabel:setName(hourText(hour))
        if not hourSlider.dragInside then hourSlider:setCurrentValue(hour, true) end
        frozen:setSelected(1, Dev.frozen())
    end
end

local function treeItems(withBoard)
    local Data = OA.Upgrades.Data
    local items = {}
    for _, tree in ipairs(Data.TREES) do items[#items + 1] = { treeName(tree), tree } end
    if withBoard then items[#items + 1] = { treeName(Data.BOARD), Data.BOARD } end
    return items
end

-- The nodes of a tree, or of the second board (by column, then row).
local function nodesOf(tree)
    local Data = OA.Upgrades.Data
    if tree ~= Data.BOARD then return Data.treeNodes(tree) end
    local list = {}
    for _, n in ipairs(Data.nodes) do
        if n.board then list[#list + 1] = n end
    end
    return list
end

local function mostNodes()
    local Data = OA.Upgrades.Data
    local most = #nodesOf(Data.BOARD)
    for _, tree in ipairs(Data.TREES) do most = math.max(most, #Data.treeNodes(tree)) end
    return most
end

local function upgradesPage(page, w)
    local Data = OA.Upgrades.Data
    local texts = OA.Upgrades.Texts
    local night = tick(page, T("Up_NightSight"), PAD, rowY(1), function(on) Dev.nightSight(on) end)

    label(page, T("Up_Tree"), PAD, rowY(4) + 2)
    local current = Data.TREES[1]
    local rows = {}
    local function fill()
        local list = nodesOf(current)
        local hasRecord = Dev.record() ~= nil
        for i, row in ipairs(rows) do
            local node = hasRecord and list[i] or nil
            row.node = node
            for _, control in ipairs(row.controls) do control:setVisible(node ~= nil) end
            if node then
                row.name:setName(texts and texts.nodeName(node.id) or node.id)
                local rank = Dev.rank(node.id)
                row.rank:setName(tostring(rank) .. "/" .. (node.ranks and tostring(node.ranks) or "-"))
            end
        end
        local window = Panel.window()
        if window and window.fitPage then window:fitPage() end
    end

    label(page, T("Up_Points"), PAD, rowY(2) + 2)
    local pointItems = treeItems(false)
    pointItems[#pointItems + 1] = { T("Up_Shared"), "shared" }
    local pointBox = combo(page, PAD + 110, rowY(2), 160, pointItems)
    local _, px = button(page, "+1", PAD + 280, rowY(2), 36, function() Dev.points(pointBox:getSelectedData(), 1) end)
    button(page, "+5", px, rowY(2), 36, function() Dev.points(pointBox:getSelectedData(), 5) end)
    button(page, T("Up_Reset"), PAD, rowY(3), 0, function()
        Dev.clearResearch()
        fill()
    end)

    combo(page, PAD + 70, rowY(4), 200, treeItems(true), function(tree)
        current = tree
        fill()
    end)

    local nameW = 220
    for i = 1, mostNodes() do
        local y = rowY(4 + i)
        local row = { controls = {} }
        row.name = label(page, "", PAD, y + 2)
        local minus = button(page, "-", PAD + nameW, y, 26, function()
            if row.node then Dev.setRank(row.node.id, math.max(0, Dev.rank(row.node.id) - 1)) fill() end
        end)
        row.rank = label(page, "", PAD + nameW + 34, y + 2)
        local plus = button(page, "+", PAD + nameW + 90, y, 26, function()
            local node = row.node
            if node then Dev.setRank(node.id, math.min(node.ranks or 99, Dev.rank(node.id) + 1)) fill() end
        end)
        row.controls = { row.name, minus, row.rank, plus }
        rows[i] = row
    end

    page.refresh = function()
        if Dev.record() then night:setSelected(1, Dev.nightSightOn()) end
        fill()
    end
    return 4 + #rows
end

local function effectsPage(page, w)
    label(page, T("Up_Tree"), PAD, rowY(1) + 2)
    local treeBox = combo(page, PAD + 70, rowY(1), 200, treeItems(false))
    local function tree() return treeBox:getSelectedData() end
    button(page, T("Fx_Capstone"), PAD, rowY(2), 0, function() Dev.title("capstone", tree()) end)
    button(page, T("Fx_TreeOpened"), PAD, rowY(3), 0, function() Dev.title("tree", tree()) end)
    button(page, T("Fx_BoardOpened"), PAD, rowY(4), 0, function() Dev.title("board") end)
    button(page, T("Fx_LineOpened"), PAD, rowY(5), 0, function() Dev.title("line") end)
    button(page, T("Fx_NewRequest"), PAD, rowY(6), 0, function() Dev.title("request") end)
    button(page, T("Fx_Take"), PAD, rowY(7), 0, function() Dev.replayTake() end)
    label(page, T("Fx_TakeHint"), PAD, rowY(8) + 2, 0.7, 0.7, 0.7)
end

local function missionPage(page, w)
    local info = label(page, "", PAD, rowY(1) + 2)
    local place = label(page, "", PAD, rowY(2) + 2)
    local scene = label(page, "", PAD, rowY(3) + 2)
    local zombies = label(page, "", PAD, rowY(4) + 2)
    local counted = nil
    button(page, T("Ms_Goto"), PAD, rowY(6), 0, function() Dev.gotoMission() end)
    button(page, T("Ms_Build"), PAD, rowY(7), 0, function()
        Dev.buildScene()
        counted = nil
    end)
    button(page, T("Ms_Count"), PAD, rowY(8), 0, function()
        local n, found = Dev.zombiesInBuilding()
        counted = found and n or -1
    end)

    page.refresh = function()
        local m, piece = Dev.mission()
        if not m then
            info:setName(T("Ms_None"))
            place:setName("")
            scene:setName("")
        else
            info:setName(T("Ms_Line") .. ": " .. tostring(m.place) .. " (" .. tostring(m.state) .. ")")
            local x, y, z = Dev.missionPlace()
            local where = T("Ms_NoPiece")
            if piece then where = x and (tostring(x) .. ", " .. tostring(y) .. ", " .. tostring(z)) or T("Ms_NotPlaced") end
            place:setName(T("Ms_Piece") .. ": " .. where)
            local sc = m.scene
            local state = T("Ms_NoScene")
            if sc then state = sc.built and T("Ms_Built") or T("Ms_Planned") end
            scene:setName(T("Ms_Scene") .. ": " .. state)
        end
        if counted == nil then
            zombies:setName("")
        elseif counted < 0 then
            zombies:setName(T("Ms_NoBuilding"))
        else
            zombies:setName(T("Ms_Zombies") .. ": " .. string.format("%.0f", counted))
        end
    end
end

local function zombiesPage(page, w)
    label(page, T("Z_Count"), PAD, rowY(1) + 2)
    local countItems = {}
    for _, n in ipairs({ 1, 5, 10, 25, 50 }) do countItems[#countItems + 1] = { tostring(n), n } end
    local countBox = combo(page, PAD + 90, rowY(1), 100, countItems)

    label(page, T("Z_Outfit"), PAD, rowY(2) + 2)
    local outfits = { { T("Z_Any"), false }, { "Generic01", "Generic01" }, { "Survivalist", "Survivalist" },
        { "Police", "Police" }, { "Fireman", "Fireman" }, { "Doctor", "Doctor" }, { "ArmyCamoGreen", "ArmyCamoGreen" } }
    local outfitBox = combo(page, PAD + 90, rowY(2), 180, outfits)
    local harmless = tick(page, T("Z_Harmless"), PAD, rowY(3), function() end)
    harmless:setSelected(1, true)
    button(page, T("Z_Spawn"), PAD, rowY(4), 0, function()
        local outfit = outfitBox:getSelectedData()
        Dev.spawn(countBox:getSelectedData(), outfit or nil, harmless:isSelected(1))
    end)
    local _, x = button(page, T("Z_Clear30"), PAD, rowY(5), 0, function() Dev.clearZombies(30) end)
    button(page, T("Z_ClearAll"), x, rowY(5), 0, function() Dev.clearZombies() end)

    -- alarms, for the alarm reading node: the marks show over alarmed houses and cars within 30 squares
    local alarms = label(page, "", PAD, rowY(7) + 2)
    local _, ax = button(page, T("Z_AlarmHouse"), PAD, rowY(8), 0, function() Dev.alarmHouse() end)
    local _, bx = button(page, T("Z_AlarmCar"), ax, rowY(8), 0, function() Dev.alarmCar() end)
    button(page, T("Z_AlarmClear"), bx, rowY(8), 0, function() Dev.clearAlarms() end)
    label(page, T("Z_AlarmHint"), PAD, rowY(9) + 2, 0.7, 0.7, 0.7)

    -- searched buildings, for 철저한 수색 and the searched bonus
    button(page, T("Z_SearchReset"), PAD, rowY(10), 0, function() Dev.resetSearch() end)
    label(page, T("Z_SearchResetHint"), PAD, rowY(11) + 2, 0.7, 0.7, 0.7)
    page.refresh = function()
        local houses, cars = Dev.alarmsNear()
        alarms:setName(T("Z_Alarms") .. ": " .. string.format("%.0f", houses) .. " / " .. string.format("%.0f", cars))
    end
end

local function playerPage(page, w)
    local god = tick(page, T("P_God"), PAD, rowY(1), function(on) Dev.godMode(on) end)
    local invisible = tick(page, T("P_Invisible"), PAD, rowY(2), function(on) Dev.invisible(on) end)
    local noClip = tick(page, T("P_NoClip"), PAD, rowY(3), function(on) Dev.noClip(on) end)
    button(page, T("P_Heal"), PAD, rowY(4), 0, function() Dev.heal() end)
    page.refresh = function()
        local g, i, n = Dev.flags()
        god:setSelected(1, g)
        invisible:setSelected(1, i)
        noClip:setSelected(1, n)
    end
end

local PAGES = {
    { id = "Time", build = timePage },
    { id = "Upgrades", build = upgradesPage },
    { id = "Effects", build = effectsPage },
    { id = "Mission", build = missionPage },
    { id = "Zombies", build = zombiesPage },
    { id = "Player", build = playerPage },
}

-- ---- the window --------------------------------------------------------------------------------------------------

local Window = ISCollapsableWindow:derive("OADevWindow")

-- Rows the tallest page needs (the research page: its nodes and the rows around them).
local function heightFor(title)
    -- and at least the zombies page's 11 (its alarm and search rows)
    local rows = math.max(mostNodes() + 5, 11)
    return title + 26 + rows * (ROW + GAP) + PAD + FH + 12
end

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    local title = self:titleBarHeight()
    local tabs = ISTabPanel:new(0, title, self.width, self.height - title - FH - 10)
    tabs:initialise()
    tabs:instantiate()
    tabs.equalTabWidth = false
    tabs.tabPadX = 14
    self:addChild(tabs)
    self.tabs = tabs
    local pageH = tabs.height - tabs.tabHeight
    for _, def in ipairs(PAGES) do
        local page = newPage(self.width, pageH)
        def.build(page, self.width)
        tabs:addView(T("Tab_" .. def.id), page)
    end
    self.statusLabel = ISLabel:new(PAD, self.height - FH - 6, FH, "", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self.statusLabel:instantiate()
    self:addChild(self.statusLabel)
    tabs.target = self
    tabs.onActivateView = function(window) window:fitPage() end
    self:fitPage()
end

-- The window as tall as the page that shows (the upgrades page is far taller than the others).
function Window:fitPage()
    local view = self.tabs and self.tabs:getActiveView()
    if not view or not self.statusLabel then return end
    local bottom = 0
    for _, child in pairs(view.children) do
        if child:isVisible() then bottom = math.max(bottom, child:getY() + child:getHeight()) end
    end
    local title = self:titleBarHeight()
    local h = title + self.tabs.tabHeight + bottom + PAD + FH + 12
    self:setHeight(h)
    self.tabs:setHeight(h - title - FH - 10)
    self.statusLabel:setY(h - FH - 6)
end

-- A line at the bottom of the window: what was done, or what failed.
function Window:say(text)
    if self.statusLabel then self.statusLabel:setName(text) end
end

-- The controls of the page that shows follow the game.
function Window:refresh()
    local view = self.tabs and self.tabs:getActiveView()
    if view and view.refresh then
        local ok, err = pcall(view.refresh)
        if not ok then self:say(T("Failed") .. " " .. tostring(err)) end
    end
end

function Window:prerender()
    ISCollapsableWindow.prerender(self)
    local now = getTimestampMs()
    if now - (self.refreshedAt or 0) >= REFRESH_MS then
        self.refreshedAt = now
        self:refresh()
    end
end

function Window:close()
    self:setVisible(false)
end

function Window:new(x, y, w, h)
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.title = T("Title")
    o.resizable = false
    -- Nearly opaque: the panel is mostly opened over the mod's own windows, which showed through and blurred its text.
    o.backgroundColor = { r = 0.04, g = 0.05, b = 0.06, a = 0.94 }
    return o
end

-- ---- opening it ----------------------------------------------------------------------------------------------------

-- The panel's window of this game, or nil before it was first opened.
function Panel.window()
    return window
end

function Panel.toggle()
    if not getPlayer() then return end
    if not window then
        FH = getTextManager():getFontHeight(UIFont.Small)
        ROW = FH + 8
        local title = math.max(16, getTextManager():getFontHeight(UIFont.Small) + 1)
        window = Window:new(60, 90, WIDTH, heightFor(title))
        window:initialise()
        window:instantiate()
        window:addToUIManager()
        window:setVisible(false)
    end
    if window:getIsVisible() then
        window:setVisible(false)
    else
        window:setVisible(true)
        window:addToUIManager()
        window:bringToTop()
        window:refresh()
    end
end

local function makeButton()
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local label = T("Button")
    local width = getTextManager():MeasureStringX(UIFont.Small, label) + 16
    openButton = ISButton:new(getCore():getScreenWidth() - width - 8, 4, width, fh + 6, label, nil,
        function() Panel.toggle() end)
    openButton:initialise()
    openButton:instantiate()
    openButton.backgroundColor = { r = 0.1, g = 0.2, b = 0.3, a = 0.8 }
    openButton:addToUIManager()
    openButton:setVisible(true)
end

local function onGameStart()
    -- the game's screens are gone with the last game: both are made again
    window, openButton = nil, nil
    makeButton()
end
Events.OnGameStart.Add(onGameStart)

-- The key: a key bind in the mod options when the game has them (F8 unless changed), else F8.
local options = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.create
    and (PZAPI.ModOptions:getOptions(MOD_ID) or PZAPI.ModOptions:create(MOD_ID, T("OptionsTitle")))
local bind = options and options:addKeyBind("openPanel", T("OpenKey"), Keyboard.KEY_F8)

local function onKeyPressed(key)
    if key == nil or key == 0 then return end
    local wanted = bind and bind:getValue() or Keyboard.KEY_F8
    if key == wanted then Panel.toggle() end
end
Events.OnKeyPressed.Add(onKeyPressed)

return Panel
