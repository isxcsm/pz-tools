-- The terminal's status tab (DESIGN-terminal 2): a fixed strip at the top (which terminal this is, the trust level
-- and its bar, the balance) and under it four sub-tabs, one screen each: the helicopter, progress, upgrades and the
-- record. The window opens on it, at the helicopter.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/TabHeli"
require "OperationAcorn/Economy/Trust"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Trust = OA.Trust

OATabStatus = OATab:derive("OATabStatus")

-- The strip's height, and where the sub-tab row and the sub-tab's screen start.
OATabStatus.TOP_H = 60
OATabStatus.SUB_Y = 66
OATabStatus.BODY_Y = 96

OATabStatus.SUBS = { "heli", "progress", "upgrades", "records" }

-- The sub-tabs' screens: the helicopter's is the trade part's; the others come with their units (DESIGN-terminal 14).
local SUB_VIEWS = {
    heli = function(x, y, w, h, window) return OATabHeli:new(x, y, w, h, window) end,
}

function OATabStatus:createChildren()
    self.sub = "heli"
    self.subTabs = OASubTabs:new(0, OATabStatus.SUB_Y, self.width, self:palette(), self, OATabStatus.onSub)
    self.subTabs:initialise()
    self.subTabs.anchorRight = true
    self:addChild(self.subTabs)
    self.subViews = {}
    self:showSub("heli")
end

function OATabStatus:subView(id)
    local view = self.subViews[id]
    if view then return view end
    local y = OATabStatus.BODY_Y
    local make = SUB_VIEWS[id]
    view = make and make(0, y, self.width, self.height - y, self.window) or OATab:new(0, y, self.width, self.height - y, self.window)
    view:initialise()
    view:instantiate()
    view.anchorRight = true
    view.anchorBottom = true
    self:addChild(view)
    self.subViews[id] = view
    return view
end

function OATabStatus:showSub(id)
    for sid, view in pairs(self.subViews) do view:setVisible(sid == id) end
    self.sub = id
    self:subView(id):setVisible(true)
    self:refresh()
end

function OATabStatus.onSub(self, id)
    if id ~= self.sub then self:showSub(id) end
end

function OATabStatus:refresh()
    local record = self:record()
    if not record then return end
    local crude = self.window.tier ~= "field"
    local items = {}
    for _, id in ipairs(OATabStatus.SUBS) do
        items[#items + 1] = { id = id, label = getText("IGUI_OA_Terminal_Sub_" .. id), lock = id == "upgrades" and crude }
    end
    self.subTabs:setItems(items, self.sub)
    self.top = self:topLines(record)
    local view = self.subViews[self.sub]
    if view and view.refresh then view:refresh() end
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
        UI.text(el, part[1], x, y, part[2], part[3])
        x = x + UI.textWidth(part[1], part[3])
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
    run(self, x0, 40, { { t.trust, p.text, nf }, { " / ", p.dim }, { t.to, p.dim, nf }, { " · " .. t.next .. " ", p.dim },
        { t.left, p.text, nf } })
    local unit = " " .. getText("IGUI_OA_Terminal_Credits")
    local right = w
    if t.debt then
        UI.textRight(self, getText("IGUI_OA_Terminal_Debt"), right, 3, p.bad)
        local uw = UI.textWidth(unit)
        UI.textRight(self, unit, right, 21, p.bad)
        UI.textRight(self, t.balance, right - uw, 21, p.bad, nf)
    else
        UI.textRight(self, getText("IGUI_OA_Terminal_Balance"), right, 3, p.dim)
        local uw = UI.textWidth(unit)
        UI.textRight(self, unit, right, 21, p.dim)
        if field then
            UI.textRight(self, t.balance, right - uw, 17, p.value, UIFont.Medium)
        else
            UI.textRight(self, t.balance, right - uw, 21, p.text, nf)
        end
    end
    UI.fill(self, 0, OATabStatus.TOP_H, w, 1, p.border, 0.8)
end

-- The tab's dot: red while the balance is a debt (DESIGN-terminal 11.1).
OA.Terminal.addTab("status", function(x, y, w, h, window)
    return OATabStatus:new(x, y, w, h, window)
end, {
    mark = function(record) return Trade.inDebt(record) and "bad" or nil end,
})
