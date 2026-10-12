-- The terminal's status tab (DESIGN-terminal 2): a fixed strip at the top (which terminal this is, the trust level
-- and its bar, the balance) and under it four sub-tabs, one screen each: the helicopter, progress, upgrades and the
-- record. The window opens on it, at the helicopter. A field terminal opened for the first time shows the board of
-- what it opened, after the window's long boot (DESIGN-terminal 12).
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/StatusDraw"
require "OperationAcorn/Trade/StatusModel"
require "OperationAcorn/Trade/TabHeli"
require "OperationAcorn/Trade/TabProgress"
require "OperationAcorn/Trade/TabUpgrades"
require "OperationAcorn/Trade/TabRecords"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Say"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Trust = OA.Trust
local Draw, M = Trade.Draw, Trade.StatusModel

OATabStatus = OATab:derive("OATabStatus")

-- The character's lines at the end of a field terminal's first boot (DESIGN-terminal 18: 정식 단말 첫 켬, 3 lines).
OA.Say.define("TerminalFirst", {})

-- The strip's height, and where the sub-tab row and the sub-tab's screen start.
OATabStatus.TOP_H = 60
OATabStatus.SUB_Y = 66
OATabStatus.BODY_Y = M.BODY_Y

OATabStatus.SUBS = { "heli", "progress", "upgrades", "records" }

local SUB_VIEWS = {
    heli = OATabHeli, progress = OATabProgress, upgrades = OATabUpgrades, records = OATabRecords,
}

function OATabStatus:createChildren()
    self.sub = "heli"
    self.subTabs = PZUISubTabs:new(0, OATabStatus.SUB_Y, self.width, self:palette(), self, OATabStatus.onSub)
    self.subTabs:initialise()
    self.subTabs:setAnchorRight(true)
    self:addChild(self.subTabs)
    -- All four screens now, so that the boot screen added after them lies over them.
    self.subViews = {}
    for _, id in ipairs(OATabStatus.SUBS) do self:subView(id) end
    self:startBoot()
    self:showSub("heli")
    self:refresh()
end

function OATabStatus:subView(id)
    local view = self.subViews[id]
    if view then return view end
    local y = OATabStatus.BODY_Y
    local class = SUB_VIEWS[id] or OATab
    view = class:new(0, y, self.width, self.height - y, self.window)
    view:initialise()
    view:instantiate()
    view:setAnchorRight(true)
    view:setAnchorBottom(true)
    view:setVisible(false)
    self:addChild(view)
    self.subViews[id] = view
    return view
end

function OATabStatus:showSub(id)
    for sid, view in pairs(self.subViews) do view:setVisible(sid == id) end
    self.sub = id
    self:subView(id):setVisible(true)
end

-- A sub-tab clicked: its screen comes up (OATerminalWindow:reveal) and the window redraws (the marks follow what is on
-- show, and what the screen shows is seen).
function OATabStatus.onSub(self, id)
    if id == self.sub then return end
    self:showSub(id)
    self.window:reveal(self.subViews[id])
    self.window:refresh()
end

function OATabStatus:refresh()
    local record = self:record()
    if not record then return end
    local field = self.window.tier == "field"
    local marks = M.subMarks(record, field, self.sub)
    local items = {}
    for _, id in ipairs(OATabStatus.SUBS) do
        local item = { id = id, label = getText("IGUI_OA_Terminal_Sub_" .. id) }
        if id == "progress" then item.dot = marks.progress end
        if id == "upgrades" then
            if not field then
                item.lock = true
            elseif marks.avail > 0 then
                item.badge = getText("IGUI_OA_Status_Avail", marks.avail)
            end
        end
        items[#items + 1] = item
    end
    self.subTabs:setItems(items, self.sub)
    self.top = self:topLines(record)
    local view = self.subViews[self.sub]
    if view and view.refresh then view:refresh() end
    if self.boot then self.boot:refresh() end
end

-- The trust level's words: "신뢰도 2단계 · 분류" up to the 5th stage, the bare number after it, the handover at 8.
function OATabStatus.levelText(tier)
    if tier <= 0 then return getText("IGUI_OA_Terminal_LevelStart") end
    if tier <= Trust.STAGES then return getText("IGUI_OA_Terminal_Level", tier, getText(Trust.stageNameKey(tier))) end
    if tier == Trust.STAGES + 3 then return getText("IGUI_OA_Terminal_Level", tier, getText("IGUI_OA_Terminal_LevelHandover")) end
    return getText("IGUI_OA_Terminal_LevelPlain", tier)
end

-- What the strip shows, worked out when the record changes (the frames only draw it).
function OATabStatus:topLines(record)
    local account = Trade.account(record)
    local tier = Trust.tier(record)
    local pr = Trust.progress(record)
    local span = math.max(1, pr.to - pr.from)
    return {
        level = OATabStatus.levelText(tier),
        frac = math.max(0, math.min(1, (pr.trust - pr.from) / span)),
        trust = Text.credits(pr.trust),
        to = Text.credits(pr.to),
        next = getText("IGUI_OA_Terminal_ToLevel", tier + 1),
        left = Text.credits(math.max(0, pr.to - pr.trust)),
        debt = account.credits < 0,
        balance = Text.credits(math.abs(account.credits)),
    }
end

-- Draws texts one after another from x; each { text, colour, font }. Returns the x after the last.
local function run(el, x, y, parts)
    for _, part in ipairs(parts) do
        local before, more = UI.spaceGaps(part[1], part[3])
        UI.text(el, part[1], x + before, y, part[2], part[3])
        x = x + UI.textWidth(part[1], part[3]) + more
    end
    return x
end

function OATabStatus:prerender()
    local t = self.top
    if not t then return end
    local p = self:palette()
    local w = self.width
    local field = self.window.tier == "field"
    local badge = getText(field and "IGUI_OA_Terminal_Field" or "IGUI_OA_Terminal_Crude")
    if field then
        UI.fill(self, 0, 4, 76, 20, p.tabStrip)
        UI.textCentre(self, badge, 38, 6, p.value)
    else
        UI.frame(self, 0, 4, 76, 20, p.dim)
        UI.textCentre(self, badge, 38, 6, p.dim)
    end
    local x0, balW = 88, 150
    UI.text(self, t.level, x0, 1, p.bright, UIFont.Medium)
    local barW = w - x0 - balW - 14
    UI.fill(self, x0, 31, barW, 7, p.dim, 0.35)
    UI.fill(self, x0, 31, math.floor(barW * t.frac + 0.5), 7, field and p.value or p.sel)
    UI.frame(self, x0, 31, barW, 7, p.border)
    local nf = p.numberFont
    run(self, x0, 40, { { t.trust, p.text, nf }, { " / ", p.dim }, { t.to, p.dim, nf }, { Text.DOT .. t.next .. " ", p.dim },
        { t.left, p.text, nf } })
    local unit = UI.creditsUnit()
    local right = w
    if t.debt then
        UI.textRight(self, getText("IGUI_OA_Terminal_Debt"), right, 3, p.bad)
        local uw = UI.textWidth(unit) + UI.UNIT_GAP
        UI.textRight(self, unit, right, 21, p.bad)
        UI.textRight(self, t.balance, right - uw, 21, p.bad, nf)
    else
        UI.textRight(self, getText("IGUI_OA_Terminal_Balance"), right, 3, p.dim)
        local uw = UI.textWidth(unit) + UI.UNIT_GAP
        UI.textRight(self, unit, right, 21, p.dim)
        if field then
            UI.textRight(self, t.balance, right - uw, 17, p.value, UIFont.Medium)
        else
            UI.textRight(self, t.balance, right - uw, 21, p.text, nf)
        end
    end
    UI.fill(self, 0, OATabStatus.TOP_H, w, 1, p.border, 0.8)
end

-- The first open of a field terminal (DESIGN-terminal 12) ----------------------------------------------------------
-- Once per terminal object (its modData OA_Booted, which the window claims as it opens): the window's long boot
-- sequence, then the board of what the field terminal opened, over the status tab. The board is made with the tab and
-- lies under the boot console; the board's button closes it, and the shop and missions tabs blink until they are
-- looked at.

function OATabStatus:startBoot()
    if not self.window.firstBoot then return end
    local boot = OAStatusBoot:new(0, 0, self.width, self.height, self)
    boot:initialise()
    boot:instantiate()
    boot:setAnchorRight(true)
    boot:setAnchorBottom(true)
    self:addChild(boot)
    self.boot = boot
end

-- The window's console is over and the tabs fade in: the board is on show, and the character says a line.
function OATabStatus:consoleOver()
    if self.boot then OA.Say.say(self.window.character, "TerminalFirst") end
end

function OATabStatus:bootDone()
    if self.boot then
        self:removeChild(self.boot)
        self.boot = nil
    end
    self.window:blinkTab("shop")
    self.window:blinkTab("missions")
end

OAStatusBoot = ISPanel:derive("OAStatusBoot")

function OAStatusBoot:new(x, y, width, height, tab)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.tab = tab
    o.background = false
    return o
end

-- The board's words, worked out again when the record changes.
function OAStatusBoot:refresh()
    local record = self.tab:record()
    if record then self.news = M.news(record) end
    self.list = nil
end

function OAStatusBoot:layoutBoard()
    local p = self.tab:palette()
    if not self.news then self:refresh() end
    local L = Draw.list(p)
    local fh = L.fh
    local bw = math.min(400, self.width - 40)
    -- The height first: the title, each section's head and lines, the button.
    local lines = {}
    for _, s in ipairs(self.news or {}) do
        local wrapped = {}
        for _, line in ipairs(s.lines) do
            for _, part in ipairs(Draw.wrap(line, bw - 44)) do wrapped[#wrapped + 1] = part end
        end
        lines[#lines + 1] = { head = s.head, lines = wrapped }
    end
    local bh = 46
    for _, s in ipairs(lines) do bh = bh + 18 + fh * #s.lines + 8 end
    bh = bh + 40
    local bx = math.floor((self.width - bw) / 2)
    local by = math.max(0, math.floor((self.height - bh) / 2))
    Draw.rect(L, -10, -10, self.width + 20, self.height + 20, { 0, 0, 0 }, 0.45)
    Draw.box(L, bx, by, bw, bh, p.panel or p.bg, 1, p.value)
    Draw.text(L, getText("IGUI_OA_Status_News"), bx + 16, by + 12, p.value, UIFont.Medium)
    local yy = by + 46
    for _, s in ipairs(lines) do
        Draw.bullet(L, bx + 18, yy, p.value)
        Draw.fit(L, s.head, bx + 28, yy, bw - 44, p.bright)
        yy = yy + 18
        for _, line in ipairs(s.lines) do
            Draw.text(L, line, bx + 28, yy, p.text)
            yy = yy + fh
        end
        yy = yy + 8
    end
    Draw.button(L, bx + bw - 112, by + bh - 34, 96, 24, getText("IGUI_OA_Status_Ok"), "strong", nil, "ok")
    self.list = L
    self.laidW, self.laidH = self.width, self.height
end

function OAStatusBoot:prerender()
    if not self.list or self.laidW ~= self.width or self.laidH ~= self.height then self:layoutBoard() end
    Draw.paint(self, self.list)
end

function OAStatusBoot:render()
    if not self.list or not self:isMouseOver() then return end
    local hit = Draw.hitAt(self.list, self:getMouseX(), self:getMouseY())
    if hit and hit.button then
        local p = self.tab:palette()
        self:drawRect(hit.x + 1, hit.y + 1, hit.w - 2, hit.h - 2, 0.10, p.sel[1], p.sel[2], p.sel[3])
    end
end

function OAStatusBoot:onMouseDown(x, y)
    local hit = Draw.hitAt(self.list, x, y)
    if hit and hit.id == "ok" then self.tab:bootDone() end
    return true
end

function OAStatusBoot:onMouseWheel()
    return true
end

UI.scaled(OAStatusBoot, ISPanel)

-- The tab's dot: red while the balance is a debt, or there is an infection or a wound not tested (DESIGN-terminal
-- 11.1 priority 1). The new level of the progress screen is seen when that screen is on show (priority 4); the dots of
-- the sub-tabs are M.subMarks.
OA.Terminal.addTab("status", function(x, y, w, h, window)
    return OATabStatus:new(x, y, w, h, window)
end, {
    mark = function(record) return M.statusMark(record) end,
    seen = function(record, window)
        if window and window:subOn("status") == "progress" then return "road", Trust.tier(record) end
        return nil
    end,
})
