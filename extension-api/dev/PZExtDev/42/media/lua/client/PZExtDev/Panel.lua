-- PZ Extension API Dev (a dev mod, never published): one debug window for every mod that registers a section in it.
-- The window has a tab per section (this mod's own "API" section, and those of the mods' own dev mods), and each
-- section a tab per page. A page shows the game's state at its top, kept up while it shows, and its controls below.
-- Opened by a small button on the screen and by a key (F8 unless changed in the mod options). Debug mode only.
--
-- A mod's dev mod registers its section once, as its file loads:
--   PZExtDev.section({ id = "OA", title = getText("..."), order = 30, pages = {
--       { id = "Trade", title = getText("..."), build = function(page, ui) ... end }, ... } })
-- build makes the page's controls with the ui helpers below and may set page.refresh, called while the page shows.
-- Mod Lua holds no letters past ASCII (the game reads them as U+FFFD): every text comes from translation keys.
if not isDebugEnabled() then return end
require "ISUI/ISPanel"
require "ISUI/ISLabel"
require "ISUI/ISButton"
require "ISUI/ISTickBox"
require "ISUI/ISComboBox"
require "ISUI/ISTabPanel"
require "ISUI/ISCollapsableWindow"
require "RadioCom/ISUIRadio/ISSliderPanel"

PZExtDev = PZExtDev or {}
local Dev = PZExtDev

local MOD_ID = "PZExtDev"
local PAD, GAP = 10, 6
local WIDTH = 600
local REFRESH_MS = 400

local sections = {}     -- the registered sections, by order
local window = nil      -- the window of this game
local openButton = nil  -- the small button on the screen

local function T(key, ...)
    return getText("IGUI_PZExtDev_" .. key, ...)
end

-- Registers a mod's section (see the top). A section registered again by its id replaces the first; the window is
-- made again the next time it opens.
function Dev.section(def)
    if type(def) ~= "table" or type(def.id) ~= "string" or type(def.pages) ~= "table" then
        error("PZExtDev.section: a table with id and pages", 2)
    end
    for i, s in ipairs(sections) do
        if s.id == def.id then table.remove(sections, i) break end
    end
    sections[#sections + 1] = def
    table.sort(sections, function(a, b) return (a.order or 50) < (b.order or 50) end)
    if window then
        window:setVisible(false)
        window:removeFromUIManager()
        window = nil
    end
end

-- ---- the helpers a page is built with -------------------------------------------------------------------------------

local ui = { PAD = PAD, GAP = GAP, W = WIDTH }
Dev.ui = ui

-- What a control does goes through here: an error is shown on the window's status line (and printed) instead of
-- breaking into the debugger in the middle of a click.
function ui.act(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            print("[PZExtDev] " .. tostring(err))
            ui.say(T("Failed") .. " " .. tostring(err))
        end
    end
end

-- A line at the bottom of the window: what was done, or what failed.
function ui.say(text)
    if window and window.statusLabel then window.statusLabel:setName(tostring(text)) end
end

-- The y of a page's row n (1 is the first).
function ui.row(n)
    return PAD + (n - 1) * (ui.ROW + GAP)
end

function ui.label(page, text, x, y, r, g, b)
    local l = ISLabel:new(x, y, ui.FH, text or "", r or 0.9, g or 0.9, b or 0.9, 1, UIFont.Small, true)
    l:initialise()
    l:instantiate()
    page:addChild(l)
    return l
end

-- A heading over a group of controls, at row n.
function ui.heading(page, text, n)
    return ui.label(page, text, PAD, ui.row(n) + 2, 0.55, 0.8, 1)
end

-- A dim hint line at row n.
function ui.hint(page, text, n)
    return ui.label(page, text, PAD, ui.row(n) + 2, 0.6, 0.6, 0.6)
end

-- A button at x, y of at least w wide; returns it and the x after it.
function ui.button(page, text, x, y, w, fn)
    local width = math.max(w or 0, getTextManager():MeasureStringX(UIFont.Small, text) + 16)
    local b = ISButton:new(x, y, width, ui.ROW, text, page, ui.act(function(_, btn) fn(btn) end))
    b:initialise()
    b:instantiate()
    page:addChild(b)
    return b, x + width + GAP
end

-- Buttons { { text, fn }, ... } from row n on, as many to a row as fit the page. Returns the rows they took.
function ui.buttons(page, n, list)
    local x, rows = PAD, 1
    for _, entry in ipairs(list) do
        local width = getTextManager():MeasureStringX(UIFont.Small, entry[1]) + 16
        if x > PAD and x + width > ui.W - PAD then
            x = PAD
            rows = rows + 1
        end
        local _, nx = ui.button(page, entry[1], x, ui.row(n + rows - 1), 0, entry[2])
        x = nx
    end
    return rows
end

-- A tick box with one option; fn gets its state. Returns it (box:setSelected(1, state) sets it without calling fn).
function ui.tick(page, text, x, y, fn)
    local box = ISTickBox:new(x, y, 20, ui.ROW, "", page, ui.act(function(_, _, selected) fn(selected) end))
    box:initialise()
    box:instantiate()
    box:addOption(text)
    box:setWidthToFit()
    page:addChild(box)
    return box
end

function ui.slider(page, x, y, w, min, max, step, shift, fn)
    local s = ISSliderPanel:new(x, y, w, ui.ROW - 4, page, ui.act(function(_, value) fn(value) end))
    s:initialise()
    s:instantiate()
    s:setValues(min, max, step, shift, true)
    s:setCurrentValue(min, true)
    page:addChild(s)
    return s
end

-- A combo box of { text, data } items; fn gets the chosen data.
function ui.combo(page, x, y, w, items, fn)
    local c = ISComboBox:new(x, y, w, ui.ROW, page, ui.act(function(_, box) if fn then fn(box:getSelectedData()) end end))
    c:initialise()
    c:instantiate()
    -- nil while the list is empty (a list not loaded yet, or cleared): the game's indexes the missing option and throws
    function c:getSelectedData()
        local option = self.options[self.selected]
        return option and option.data
    end
    for _, item in ipairs(items) do c:addOptionWithData(item[1], item[2]) end
    page:addChild(c)
    return c
end

-- Lines of state from row n on: lines:set({ "a", "b" }) shows them (the rest of the count blank).
function ui.lines(page, n, count, r, g, b)
    local list = {}
    for i = 1, count do list[i] = ui.label(page, "", PAD, ui.row(n + i - 1) + 2, r or 0.75, g or 0.95, b or 0.75) end
    return {
        set = function(_, texts)
            for i, l in ipairs(list) do l:setName(texts[i] and tostring(texts[i]) or "") end
        end,
    }
end

-- A number as text without a decimal point when whole ("%" is not used: Kahlua's breaks on large values).
function ui.num(value, decimals)
    if type(value) ~= "number" then return tostring(value) end
    if not decimals or value == math.floor(value) then return string.format("%.0f", value) end
    return string.format("%." .. tostring(decimals) .. "f", value)
end

-- The window as tall as the page that shows (a page calls it when it shows or hides controls).
function ui.fit()
    if window then window:fitPage() end
end

-- A page: past what the screen leaves the window its controls scroll (the wheel, or the bar at its right).
local Page = ISPanel:derive("PZExtDevPage")

function Page:prerender()
    self:setStencilRect(0, 0, self:getWidth(), self:getHeight())
    ISPanel.prerender(self)
end

function Page:render()
    ISPanel.render(self)
    self:clearStencilRect()
end

function Page:onMouseWheel(del)
    if self:getScrollHeight() <= self:getHeight() then return false end
    self:setYScroll(self:getYScroll() - del * 40)
    return true
end

local function newPage(w, h)
    local p = Page:new(0, 0, w, h)
    p:initialise()
    p:instantiate()
    p.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    p.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    p:setScrollChildren(true)
    p:addScrollBars()
    return p
end

local function newTabs(x, y, w, h)
    local tabs = ISTabPanel:new(x, y, w, h)
    tabs:initialise()
    tabs:instantiate()
    tabs.equalTabWidth = false
    tabs.tabPadX = 12
    return tabs
end

-- ---- the window --------------------------------------------------------------------------------------------------

local Window = ISCollapsableWindow:derive("PZExtDevWindow")

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    local title = self:titleBarHeight()
    local outer = newTabs(0, title, self.width, self.height - title - ui.FH - 10)
    self:addChild(outer)
    self.tabs = outer
    for _, section in ipairs(sections) do
        local inner = newTabs(0, 0, self.width, outer.height - outer.tabHeight)
        for _, def in ipairs(section.pages) do
            local page = newPage(self.width, 400)
            local ok, err = pcall(def.build, page, ui)
            if not ok then
                print("[PZExtDev] " .. section.id .. "/" .. tostring(def.id) .. ": " .. tostring(err))
                ui.label(page, T("Failed") .. " " .. tostring(err), PAD, PAD, 1, 0.5, 0.5)
            end
            inner:addView(def.title or def.id, page)
        end
        inner.target = self
        inner.onActivateView = function(win) win:showPage() end
        outer:addView(section.title or section.id, inner)
    end
    self.statusLabel = ISLabel:new(PAD, self.height - ui.FH - 6, ui.FH, "", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self.statusLabel:instantiate()
    self:addChild(self.statusLabel)
    outer.target = self
    outer.onActivateView = function(win) win:showPage() end
    self:fitPage()
end

-- A page comes up: its state first (what it shows and hides), then the window to its height, in the same frame.
function Window:showPage()
    self:refresh()
    self:fitPage()
end

-- The section and page that show.
function Window:activePage()
    local inner = self.tabs and self.tabs:getActiveView()
    return inner, inner and inner.getActiveView and inner:getActiveView()
end

-- The window as tall as the page that shows, as far as the screen below it allows; past that the page scrolls.
function Window:fitPage()
    local inner, view = self:activePage()
    if not view or not self.statusLabel then return end
    local bottom = 0
    for _, child in pairs(view.children) do
        if child ~= view.vscroll and child:isVisible() then
            bottom = math.max(bottom, child:getY() + child:getHeight())
        end
    end
    local title = self:titleBarHeight()
    local around = title + self.tabs.tabHeight + inner.tabHeight + ui.FH + 12
    local contentH = bottom + PAD
    local pageH = math.min(contentH, math.max(200, getCore():getScreenHeight() - self:getY() - around - 20))
    view:setHeight(pageH)
    view:setScrollHeight(contentH)
    inner:setHeight(inner.tabHeight + pageH)
    local h = around + pageH
    if h == self.height then return end
    self:setHeight(h)
    self.tabs:setHeight(h - title - ui.FH - 10)
    self.statusLabel:setY(h - ui.FH - 6)
end

function Window:refresh()
    self.refreshedAt = getTimestampMs()
    local _, view = self:activePage()
    if view and view.refresh then
        local ok, err = pcall(view.refresh)
        if not ok then ui.say(T("Failed") .. " " .. tostring(err)) end
    end
end

function Window:prerender()
    ISCollapsableWindow.prerender(self)
    if getTimestampMs() - (self.refreshedAt or 0) >= REFRESH_MS then self:refresh() end
end

function Window:close()
    self:setVisible(false)
end

function Window:new(x, y, w, h)
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.title = T("Title")
    o.resizable = false
    -- Nearly opaque: the window is mostly opened over the mods' own windows, which showed through and blurred its text.
    o.backgroundColor = { r = 0.04, g = 0.05, b = 0.06, a = 0.94 }
    return o
end

-- ---- opening it ----------------------------------------------------------------------------------------------------

function Dev.window()
    return window
end

function Dev.toggle()
    if not getPlayer() then return end
    if not window then
        ui.FH = getTextManager():getFontHeight(UIFont.Small)
        ui.ROW = ui.FH + 8
        window = Window:new(60, 90, WIDTH, 300)
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
        window:showPage()
    end
end

local function makeButton()
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local label = T("Button")
    local width = getTextManager():MeasureStringX(UIFont.Small, label) + 16
    openButton = ISButton:new(getCore():getScreenWidth() - width - 8, 4, width, fh + 6, label, nil,
        function() Dev.toggle() end)
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
    if key == wanted then Dev.toggle() end
end
Events.OnKeyPressed.Add(onKeyPressed)

return Dev
