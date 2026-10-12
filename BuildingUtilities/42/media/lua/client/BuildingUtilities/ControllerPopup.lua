-- The charge controller's settings (BU.Energy, from tier 3), opened from the bank's Settings button in the power tab:
-- a small panel in the box's palette at the mouse. At its top the bank's charge as a bar, with a mark at each level
-- the controller acts on, in the colour of its line below; then a line per setting, what it does in words and its
-- value in a drop-down (PZUICombo). A choice goes to the server at once. It closes with its button, a click outside
-- it, or its box's window.
require "ISUI/ISPanel"
require "PZUIKit/UI"
require "PZUIKit/Button"
require "PZUIKit/Combo"
require "BuildingUtilities/PanelUi"
local BU = BuildingUtilities
local Energy, Sync = BU.Energy, BU.Sync
local Ui = BU.PanelUi
local UI, P = Ui.UI, Ui.PALETTE

ISBUControllerPopup = ISPanel:derive("ISBUControllerPopup")

-- Sizes (design units): the width, the margin, the bar's height, a drop-down's width.
ISBUControllerPopup.WIDTH, ISBUControllerPopup.PAD = 380, 10
ISBUControllerPopup.BAR_H, ISBUControllerPopup.COMBO_W = 12, 100
-- How often (real ms) it reads the box again.
ISBUControllerPopup.READ_MS = 500

-- The settings in order: its words, its colour on the bar (none for the hours), and whether the box's tier has it.
local SETTINGS = {
    { name = "start", text = "IGUI_BU_Controller_Start", colour = P.warn },
    { name = "stop", text = "IGUI_BU_Controller_Stop", colour = P.good },
    { name = "quiet", text = "IGUI_BU_Controller_Quiet" },
    { name = "protect", text = "IGUI_BU_Controller_Protect", colour = P.bad, smart = true },
}

local function quietText(pair)
    if pair[1] == pair[2] then return getText("IGUI_BU_QuietNone") end
    return getText("IGUI_BU_QuietHours", pair[1], pair[2])
end

function ISBUControllerPopup:new(window)
    local F = ISBUControllerPopup
    local o = ISPanel.new(self, 0, 0, F.WIDTH, 100)
    o.window, o.panel, o.playerObj = window, window.panel, window.playerObj
    o.palette = P
    o.background = false
    o.lines = {}
    o.titleText = getText("IGUI_BU_Controller_Title")
    local textW = F.WIDTH - 3 * F.PAD - F.COMBO_W
    for _, setting in ipairs(SETTINGS) do
        if not setting.smart or (o.panel.tier or 1) >= BU.SMART_TIER then
            o.lines[#o.lines + 1] = { setting = setting, words = UI.wrap(getText(setting.text), textW) }
        end
    end
    local fh, bh = UI.fontHeight(), UI.buttonHeight()
    local y = F.PAD + fh + F.PAD + F.BAR_H + 4 + fh + F.PAD
    for _, line in ipairs(o.lines) do
        line.y = y
        line.h = math.max(bh, #line.words * fh)
        y = y + line.h + F.PAD
    end
    o.closeY = y
    o.height = y + bh + F.PAD
    return o
end

function ISBUControllerPopup:createChildren()
    local F = ISBUControllerPopup
    local bh = UI.buttonHeight()
    for _, line in ipairs(self.lines) do
        local name = line.setting.name
        local combo = PZUICombo:new(self.width - F.PAD - F.COMBO_W, line.y + (line.h - bh) / 2, F.COMBO_W, bh, P,
            self, ISBUControllerPopup.onChoice)
        combo.setting = name
        for _, choice in ipairs(Energy.CHOICES[name]) do
            combo:addOptionWithData(name == "quiet" and quietText(choice) or BU.percent(choice), choice)
        end
        combo:initialise()
        combo:instantiate()
        self:addChild(combo)
        line.combo = combo
    end
    local close = PZUIButton:new((self.width - 100) / 2, self.closeY, 100, bh, getText("UI_Close"), P, self,
        ISBUControllerPopup.close)
    close:initialise()
    close:instantiate()
    self:addChild(close)
end

-- Each drop-down on the value the box has (the server's answer to a choice comes back this way).
function ISBUControllerPopup:showSettings(settings)
    for _, line in ipairs(self.lines) do
        local combo = line.combo
        if combo and not combo.list then
            for i, option in ipairs(combo.options) do
                local data = option.data
                local current = line.setting.name == "quiet"
                    and data[1] == settings.quietFrom and data[2] == settings.quietTo
                    or data == settings[line.setting.name]
                if current then combo.selected = i end
            end
        end
    end
end

function ISBUControllerPopup:onChoice(combo)
    local value = combo:getSelectedData()
    local args = { panel = self.panel.id }
    if combo.setting == "quiet" then args.quietFrom, args.quietTo = value[1], value[2]
    else args[combo.setting] = value end
    Sync.send(self.playerObj, "setController", args)
end

-- What the box has, read again a few times a second (a choice comes back from the server; the charge moves): the
-- drop-downs' values, the charge, and the marks on the bar with their labels (placed in design units).
function ISBUControllerPopup:read()
    local F = ISBUControllerPopup
    local settings = Energy.settings(self.panel)
    self:showSettings(settings)
    local bank = Energy.bank(self.panel)
    self.charge = bank and bank.capacity > 0 and bank.energy / bank.capacity or 0
    self.nowText = getText("IGUI_BU_Controller_Now", BU.percent(self.charge * 100))
    local x, w = F.PAD, self.width - 2 * F.PAD
    local marks = {}
    for _, line in ipairs(self.lines) do
        local setting = line.setting
        local level = setting.colour and settings[setting.name]
        if level then
            local mx = x + math.floor(w * level / 100)
            local label = BU.percent(level)
            local lw = UI.textWidth(label)
            marks[#marks + 1] = { x = mx, label = label, labelX = math.max(x, math.min(x + w - lw, mx - lw / 2)),
                colour = setting.colour }
        end
    end
    self.marks = marks
end

function ISBUControllerPopup:prerender()
    local window = self.window
    if not window:isReallyVisible() or window.uiGone then return self:close() end
    local F, fh = ISBUControllerPopup, UI.fontHeight()
    local now = getTimestampMs()
    if not self.readAt or now - self.readAt > F.READ_MS then
        self.readAt = now
        self:read()
    end
    UI.fill(self, 0, 0, self.width, self.height, P.bg, 0.97)
    UI.frame(self, 0, 0, self.width, self.height, P.border)
    UI.text(self, self.titleText, F.PAD, F.PAD, P.bright)
    -- the bank's charge, and the levels the controller acts on
    local x, w, y = F.PAD, self.width - 2 * F.PAD, F.PAD + fh + F.PAD
    UI.fill(self, x, y, w, F.BAR_H, P.inset)
    UI.fill(self, x, y, math.floor(w * self.charge), F.BAR_H, P.value, 0.6)
    UI.frame(self, x, y, w, F.BAR_H, P.border)
    UI.textRight(self, self.nowText, x + w, F.PAD, P.value)
    for _, mark in ipairs(self.marks) do
        UI.fill(self, mark.x - 1, y - 2, 2, F.BAR_H + 4, mark.colour)
        UI.text(self, mark.label, mark.labelX, y + F.BAR_H + 4, mark.colour)
    end
    -- each setting's words, by the colour of its mark
    for _, line in ipairs(self.lines) do
        local tx = F.PAD
        if line.setting.colour then
            UI.fill(self, tx, line.y + (fh - 8) / 2 + 1, 8, 8, line.setting.colour)
        end
        tx = tx + 14
        for i, words in ipairs(line.words) do
            UI.text(self, words, tx, line.y + (line.h - #line.words * fh) / 2 + (i - 1) * fh, P.text)
        end
    end
end

function ISBUControllerPopup:onMouseDownOutside()
    if self.gone then return end
    for _, line in ipairs(self.lines) do
        -- a choice in an open list is a click outside this panel
        if line.combo and line.combo.list then return end
    end
    self:close()
end

function ISBUControllerPopup:close()
    if self.gone then return end
    self.gone = true
    for _, line in ipairs(self.lines) do
        if line.combo then line.combo:closeList() end
    end
    if self.window.controllerPopup == self then self.window.controllerPopup = nil end
    self.window.controllerClosedAt = getTimestampMs()
    UI.fadeOut(self)
end

UI.scaled(ISBUControllerPopup, ISPanel)

-- Opens the popup for a box's window at the mouse, inside the screen. A second click on Settings closes it: the click
-- outside the popup closed it just before (within SAME_CLICK_MS), and it does not open again.
function ISBUControllerPopup.open(window)
    local shown = window.controllerPopup
    if shown then return shown:close() end
    local closed = window.controllerClosedAt
    if closed and getTimestampMs() - closed < PZUICombo.SAME_CLICK_MS then return nil end
    UI.refreshScale()
    local popup = ISBUControllerPopup:new(window)
    local screenW, screenH = UI.dp(getCore():getScreenWidth()), UI.dp(getCore():getScreenHeight())
    popup.x = math.max(0, math.min(UI.dp(getMouseX()) - popup.width + 20, screenW - popup.width))
    popup.y = math.max(0, math.min(UI.dp(getMouseY()) + 12, screenH - popup.height))
    popup:initialise()
    popup:addToUIManager()
    popup:bringToTop()
    UI.fadeIn(popup)
    window.controllerPopup = popup
    return popup
end
