-- The status tab's upgrades screen (DESIGN-terminal 2.6, 운항 지원 신청): the group buttons (helicopter, trade), a card
-- for each upgrade of the group with its value now, the next one and a pip for each level, the chosen upgrade's
-- column (what it does, every level with its price and when it opens, the button that asks for the next or takes the
-- request back) and the request form at the bottom with what was asked for and the stamp. The crude terminal shows
-- the same, its buttons off, and a band in the form's place that says where requests are made.
require "OperationAcorn/Trade/StatusDraw"
require "OperationAcorn/Trade/StatusModel"
require "OperationAcorn/Trade/TabProgress"
require "OperationAcorn/Trade/Confirm"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Draw, M = Trade.Draw, Trade.StatusModel
local Shop, Trust, Support = OA.Shop, OA.Trust, OA.Support

OATabUpgrades = OAStatusView:derive("OATabUpgrades")

function OATabUpgrades:model(record)
    local field = self.window.tier == "field"
    local cards = {}
    for _, u in ipairs(Support.LIST) do
        local cur, nxt, state = M.upgradeState(record, u.id, field)
        local step = nxt and Support.step(u.id, nxt)
        local values = {}
        for k = 1, #u.steps do values[k] = M.valueText(u.id, u.steps[k][1]) end
        cards[#cards + 1] = {
            id = u.id, group = u.group, name = getText(Support.nameKey(u.id)), cur = cur, nxt = nxt, state = state,
            value = M.valueText(u.id, Support.step(u.id, cur).value),
            nextValue = step and M.valueText(u.id, step.value), nextPrice = step and Text.credits(step.price),
            nextTier = step and step.tier, steps = #u.steps, endless = u.endless ~= nil, values = values,
            effect = getText("IGUI_OA_Status_Effect_" .. u.id), ladder = M.ladder(u.id, cur),
        }
    end
    local counts = {}
    for _, g in ipairs(Support.GROUPS) do counts[g] = field and M.countAvail(record, true, g) or 0 end
    local requests = M.requests(record)
    local total = 0
    for _, r in ipairs(requests) do total = total + r.price end
    local terminal = Shop.entry("field_terminal")
    return {
        field = field, tier = Trust.tier(record), cards = cards, counts = counts, requests = requests,
        total = Text.credits(total), terminalPrice = terminal and Text.credits(Shop.price(terminal, record)) or "?",
    }
end

function OATabUpgrades:groupCards(group)
    local list = {}
    for _, c in ipairs(self.data.cards) do if c.group == group then list[#list + 1] = c end end
    return list
end

function OATabUpgrades:build(L, w, h)
    local d, p = self.data, L.p
    self.selected = self.selected or {}
    local group = self.group or Support.GROUPS[1]
    local cards = self:groupCards(group)
    local selId = self.selected[group] or (cards[1] and cards[1].id)
    local lay = M.upgradesLayout(w, h, #cards)
    -- The group buttons.
    local gx = 0
    for _, g in ipairs(Support.GROUPS) do
        local label = getText("IGUI_OA_Status_Group_" .. g)
        if d.counts[g] > 0 then label = getText("IGUI_OA_Status_GroupCount", label, d.counts[g]) end
        local bw = UI.textWidth(label) + 26
        if g == group then
            Draw.box(L, gx, 0, bw, 20, p.sel, 0.2, p.sel)
        else
            if p.panel then Draw.box(L, gx, 0, bw, 20, p.panel, 1, p.border) else Draw.frame(L, gx, 0, bw, 20, p.border) end
        end
        Draw.textCentre(L, label, gx + math.floor(bw / 2), 2, g == group and p.bright or p.text)
        local hit = Draw.hit(L, gx, 0, bw, 20, "group")
        hit.group, hit.hover = g, g ~= group
        gx = gx + bw + 4
    end
    -- The cards, two columns, scrolled (in pixels, a row at a time) when they do not fit.
    local sel
    local maxScroll = math.max(0, lay.contentH - lay.areaH)
    local first = OA.clamp(self.cardScroll or 0, 0, maxScroll)
    self.cardScroll = first
    self.cardBox = lay.scroll and { y = lay.top, h = lay.areaH, step = lay.ch + M.CARD_GAP, max = maxScroll } or nil
    local bottom = lay.top + lay.areaH
    if lay.scroll then Draw.clip(L, 0, lay.top, lay.lw, lay.areaH) end
    for i, c in ipairs(cards) do
        local x = OA.remainder(i - 1, 2) * (lay.cw + M.CARD_GAP)
        local y = lay.top + math.floor((i - 1) / 2) * (lay.ch + M.CARD_GAP) - first
        if y + lay.ch > lay.top and y < bottom then
            self:buildCard(L, x, y, lay.cw, lay.ch, c, c.id == selId)
            -- the part of the card in the area takes the clicks
            local hy = math.max(y, lay.top)
            local hit = Draw.hit(L, x, hy, lay.cw, math.min(y + lay.ch, bottom) - hy, "card")
            hit.card, hit.hover = c.id, c.id ~= selId
        end
        if c.id == selId then sel = c end
    end
    if lay.scroll then
        Draw.unclip(L)
        Draw.scrollbar(L, lay.lw - 6, lay.top, lay.areaH, first / math.max(1, maxScroll), lay.areaH / lay.contentH)
    end
    if sel then self:buildDetail(L, lay.lw + 8, 0, lay.rw, h - lay.formH - 6, sel) end
    self.detailBox = { x = lay.lw + 8, y = 0, w = lay.rw, h = h - lay.formH - 6 }
    self:buildForm(L, 0, h - lay.formH, w, lay.formH)
end

-- The pip colours of level k of a card.
local function pipStyle(p, c, k)
    local done = p.panel and p.value or p.sel
    if k <= c.cur then return "fill", done, p.text end
    if c.state == "pending" and k == c.nxt then return "half", p.warn, p.warn end
    if k == c.nxt and c.state == "avail" then return "line", p.good, p.good end
    if k == c.nxt and (c.state == "field" or c.state == "debt") then return "line", p.warn, p.warn end
    return "dim", p.border, p.dim
end

local function pip(L, kind, x, y, w, h, c)
    if kind == "fill" then
        Draw.rect(L, x, y, w, h, c)
    elseif kind == "half" then
        Draw.rect(L, x, y, w, h, c, 0.45)
        Draw.frame(L, x, y, w, h, c)
    elseif kind == "line" then
        Draw.frame(L, x, y, w, h, c)
    else
        Draw.frame(L, x, y, w, h, c, 0.8)
    end
end

function OATabUpgrades:buildCard(L, x, y, w, h, c, selected)
    local p, fh, nf = L.p, L.fh, L.p.numberFont
    Draw.panel(L, x, y, w, h)
    if selected then
        Draw.frame(L, x, y, w, h, p.sel)
        Draw.frame(L, x + 1, y + 1, w - 2, h - 2, p.sel, 0.6)
    end
    local tall = h >= 60
    -- Right: what comes next and what it takes.
    local right = w - 8
    local tagY = tall and 22 or 19
    local rw = 0
    if c.state == "max" then
        rw = Draw.textRight(L, getText("IGUI_OA_Status_Up_Max"), x + right, y + tagY, p.dim)
    else
        local col = ({ avail = p.good, pending = p.warn, field = p.text, debt = p.text, locked = p.dim })[c.state]
        rw = Draw.run(L, { { arrow = true, c = p.dim }, { s = c.nextValue, c = col } }, x, y + (tall and 5 or 4), right, "right")
        local tag
        if c.state == "avail" then tag = { s = c.nextPrice, c = p.text, font = nf }
        elseif c.state == "pending" then tag = { s = getText("IGUI_OA_Status_Up_Pending"), c = p.warn }
        elseif c.state == "field" then tag = { s = getText("IGUI_OA_Terminal_Field"), c = p.warn }
        elseif c.state == "debt" then tag = { s = getText("IGUI_OA_Terminal_Debt"), c = p.bad }
        else tag = { s = M.fromText(c.nextTier), c = p.dim } end
        Draw.run(L, { tag }, x, y + tagY, right, "right")
    end
    Draw.fit(L, c.name, x + 8, y + 4, w - 22 - rw, p.text)
    if tall then
        Draw.fit(L, c.value, x + 8, y + 19, w - 90, p.panel and p.value or p.bright, UIFont.Medium)
    else
        Draw.fit(L, c.value, x + 8, y + 19, w - 90, p.bright)
    end
    -- A tall card says what the upgrade does (its first sentence) and writes each level's value under its pip.
    if h - 34 - 46 >= fh then Draw.fit(L, M.firstSentence(c.effect), x + 8, y + 46, w - 16, p.dim) end
    local n = c.steps
    if h >= 84 then
        local px0, pw = x + 8, w - 16
        local sw = math.floor((pw - (c.endless and 12 or 0) - 3 * (n - 1)) / n)
        local py = y + h - 34
        for k = 1, n do
            local px = px0 + (k - 1) * (sw + 3)
            local kind, colour, tc = pipStyle(p, c, k)
            pip(L, kind, px, py, sw, 8, colour)
            Draw.fit(L, c.values[k], px, py + 10, sw, tc, nil, 1, "centre")
        end
        if c.endless then Draw.text(L, "+", px0 + pw - 10, py - 4, p.dim) end
    else
        local py = y + h - 13
        for k = 1, n do
            local kind, colour = pipStyle(p, c, k)
            pip(L, kind, x + 8 + (k - 1) * 17, py, 14, 7, colour)
        end
        if c.endless then Draw.text(L, "+", x + 8 + n * 17, py - 5, p.dim) end
    end
end

-- The chosen upgrade: what it does, every level, and the button.
function OATabUpgrades:buildDetail(L, x, y, w, h, c)
    local d, p, fh, nf = self.data, L.p, L.fh, L.p.numberFont
    local crude = not d.field
    Draw.panel(L, x, y, w, h)
    local levels = c.cur <= c.steps and getText("IGUI_OA_Status_Levels", c.cur, c.steps) or getText(Trust.MILESTONE_NAME_KEY, c.cur)
    local lvW = Draw.textRight(L, levels, x + w - 10, y + 8, p.dim)
    Draw.fit(L, c.name, x + 10, y + 4, w - 26 - lvW, p.bright, UIFont.Medium)
    local lines = Draw.wrap(c.effect, w - 20)
    local yy = y + 28
    for _, line in ipairs(lines) do
        Draw.text(L, line, x + 10, yy, p.text)
        yy = yy + fh
    end
    yy = yy + 8
    Draw.rect(L, x + 10, yy, w - 20, 1, p.border, 0.6)
    yy = yy + 6
    -- The ladder: every level with its price and when it opens; the next one shaded.
    local rh = 17
    local bottom = y + h - 40
    local rows = c.ladder
    local show = #rows
    if yy + rh * show > bottom then show = math.max(1, math.floor((bottom - yy) / rh)) end
    local done = p.panel and p.value or p.sel
    for i = 1, show do
        local r = rows[i]
        local k = r.level
        local st, col = "", p.dim
        if r.more then
            st = getText("IGUI_OA_Status_BoxEach", r.tier)
        elseif k == 0 then
            st = getText("IGUI_OA_Status_Row_Start")
        elseif k <= c.cur then
            st = getText("IGUI_OA_Status_Got")
        elseif c.state == "pending" and k == c.nxt then
            st, col = getText("IGUI_OA_Status_Up_Pending"), p.warn
        elseif r.tier and r.tier > d.tier then
            st = M.fromText(r.tier)
        elseif k == c.nxt then
            if crude then st, col = getText("IGUI_OA_Terminal_Field"), p.warn
            elseif c.state == "debt" then st, col = getText("IGUI_OA_Terminal_Debt"), p.bad
            else st, col = getText("IGUI_OA_Status_Row_Now"), p.good end
        end
        local here = k == c.nxt and not r.more
        if here then Draw.rect(L, x + 4, yy - 1, w - 8, rh, p.sel, 0.12) end
        if k <= c.cur and not r.more then
            Draw.rect(L, x + 10, yy + 5, 7, 7, done)
        else
            Draw.frame(L, x + 10, yy + 5, 7, 7, here and col or p.border)
        end
        local vc = here and p.bright or (k > c.cur and p.text or p.dim)
        Draw.fit(L, r.value, x + 24, yy, 56, vc)
        if r.more then
            Draw.textRight(L, getText("IGUI_OA_Status_PerStep", Text.credits(r.step)), x + 142, yy, p.dim)
        elseif r.price and r.price > 0 then
            Draw.textRight(L, Text.credits(r.price), x + 142, yy, k > c.cur and p.text or p.dim, nf)
        end
        Draw.fit(L, st, x + 146, yy, w - 156, col, nil, 1, "right")
        yy = yy + rh
    end
    if show < #rows then Draw.text(L, getText("IGUI_OA_Status_MoreLevels", #rows - show), x + 24, yy, p.dim) end
    -- The button.
    local bx, by, bw = x + 10, y + h - 32, w - 20
    if c.state == "max" then
        Draw.button(L, bx, by, bw, 24, getText("IGUI_OA_Status_AllDone"), "disabled")
    elseif c.state == "pending" then
        local hit = Draw.button(L, bx, by, bw, 24, getText("IGUI_OA_Status_Cancel"), "normal", nil, "cancel")
        hit.card = c.id
    elseif c.state == "locked" then
        Draw.button(L, bx, by, bw, 24, getText("IGUI_OA_Status_ApplyFrom", c.nextTier), "disabled")
    elseif c.state == "field" then
        Draw.button(L, bx, by, bw, 24, nil, "disabled")
        local label = getText("IGUI_OA_Status_ApplyField")
        local tw = UI.textWidth(label) + 14
        local lx = bx + math.floor((bw - tw) / 2)
        Draw.lock(L, lx, by + 7, p.warn)
        Draw.text(L, label, lx + 14, by + math.floor((24 - fh) / 2), p.warn)
    elseif c.state == "debt" then
        Draw.button(L, bx, by, bw, 24, getText("IGUI_OA_Support_Why_debt"), "disabled")
    else
        local hit = Draw.button(L, bx, by, bw, 24, getText("IGUI_OA_Status_Apply", c.nextPrice), "strong", nil, "apply")
        hit.card, hit.level = c.id, c.nxt
    end
end

-- 운항 지원 신청서: the requests waiting for the next settlement, with the stamp. The crude terminal's band instead.
function OATabUpgrades:buildForm(L, x, y, w, h)
    local d, p, fh, nf = self.data, L.p, L.fh, L.p.numberFont
    if not d.field then
        Draw.box(L, x, y, w, h, p.warn, 0.10, p.warn, 0.9)
        Draw.lock(L, x + 10, y + math.floor(h / 2) - 5, p.warn)
        local parts = { { s = getText("IGUI_OA_Status_FormFieldOnly") .. " ", c = p.warn } }
        for _, part in ipairs(Draw.styled(L, M.parts("IGUI_OA_Status_FormFieldWhere", d.terminalPrice), p.dim, p.text)) do
            parts[#parts + 1] = part
        end
        Draw.run(L, parts, x + 24, y + math.floor((h - fh) / 2), w - 140)
        Draw.button(L, x + w - 108, y + 6, 100, h - 12, getText("IGUI_OA_Status_ShowInShop"), "strong", nil, "shop")
        return
    end
    if p.panel then Draw.box(L, x, y, w, h, { 0.93, 0.90, 0.80 }, 0.06, p.border) else Draw.frame(L, x, y, w, h, p.border) end
    local headW = Draw.text(L, getText("IGUI_OA_Status_Form"), x + 10, y + 4, p.head)
    Draw.fit(L, getText("IGUI_OA_Status_FormWhen"), x + 10, y + h - fh - 3, w - 200, p.dim)
    local xx = x + math.max(150, headW + 24)
    if #d.requests == 0 then
        Draw.fit(L, getText("IGUI_OA_Status_FormEmpty"), xx, y + 4, x + w - 10 - xx, p.dim)
        return
    end
    local limit = x + w - 84
    for _, r in ipairs(d.requests) do
        if xx >= limit then break end
        local used = Draw.run(L, { { s = r.name .. " " .. r.from, c = p.text }, { arrow = true, c = p.dim }, { s = r.to, c = p.warn },
            { s = Text.DOT, c = p.dim }, { s = Text.credits(r.price), c = p.text, font = nf } }, xx, y + 4, limit - xx)
        xx = xx + used + 16
    end
    Draw.run(L, { { s = getText("IGUI_OA_Status_FormTotal") .. " ", c = p.dim }, { s = d.total, c = p.value, font = nf },
        { s = UI.creditsUnit(), c = p.dim, pad = UI.UNIT_GAP } }, x + 10, y + h - fh - 5, w - 20, "right")
    -- The stamp: what the settlement turns into 반영 (told by the title then).
    Draw.frame(L, x + w - 74, y + 4, 64, 18, p.warn)
    Draw.fit(L, getText("IGUI_OA_Status_Stamp"), x + w - 74, y + 5, 64, p.warn, nil, 1, "centre")
end

function OATabUpgrades:onHit(hit)
    if hit.id == "group" then
        if hit.group == (self.group or Support.GROUPS[1]) then return end
        self.group = hit.group
        self:layout()
        -- the group's cards and detail come up (the row of the groups stays)
        self.window:reveal(self, 0, 22, self.width, self.height - 22)
    elseif hit.id == "card" then
        self.selected = self.selected or {}
        local group = self.group or Support.GROUPS[1]
        if self.selected[group] == hit.card then return end
        self.selected[group] = hit.card
        self:layout()
        local b = self.detailBox
        if b then self.window:reveal(self, b.x, b.y, b.w, b.h) end
    elseif hit.id == "apply" then
        self:send("tradeUpgrade", { upgrade = hit.card, level = hit.level })
    elseif hit.id == "cancel" then
        UI.confirm(self:character(), getText("IGUI_OA_Status_CancelAsk"), self, OATabUpgrades.doCancel, hit.card)
    elseif hit.id == "shop" then
        self.window:showShopEntry("field_terminal")
    end
end

-- The wheel over the cards scrolls them a row at a time.
function OATabUpgrades:onMouseWheel(del)
    local b = self.cardBox
    if not b then return false end
    local my = self:getMouseY()
    if my < b.y or my >= b.y + b.h then return false end
    self.cardScroll = OA.clamp((self.cardScroll or 0) + (del > 0 and b.step or -b.step), 0, b.max)
    self:layout()
    return true
end

function OATabUpgrades:doCancel(id)
    self:send("tradeUpgradeCancel", { upgrade = id })
end
