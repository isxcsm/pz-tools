-- The status tab's helicopter screen (DESIGN-terminal 2.2). On the left the helicopter: its state and what follows
-- from it, the arrival bar while it flies, the infection box, the four values the upgrades raise, the last settlement,
-- the supply crates still lying around, the card of a new guide document (DESIGN-terminal 11.1) and the buttons that
-- call it or ask for a new delivery box. On the right this flight's waybill: what goes up, what comes down, and the
-- settlement's sums pinned to the bottom like the foot of a receipt. The words come from Trade/StatusModel; this lays
-- them out (mockups/terminal/gen/status.py hero, waybill).
require "OperationAcorn/Trade/StatusDraw"
require "OperationAcorn/Trade/StatusModel"
require "OperationAcorn/Story/Folder"
require "PZUIKit/Confirm"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Draw, M, Estimate = Trade.Draw, Trade.StatusModel, Trade.Estimate
local Folder = OA.StoryFolder

OATabHeli = OAStatusView:derive("OATabHeli")

-- Rows of the waybill's "comes down" list.
OATabHeli.ROW = 18

function OATabHeli:model(record)
    local c = self:character()
    local now = OA.hours()
    local flight = Estimate.flight(record)
    return {
        now = now,
        heli = M.heli(record, now, getGameTime():getTimeOfDay()),
        spec = M.spec(record),
        last = M.lastSettle(record, now),
        crates = M.crates(record.heli and record.heli.markers, c:getX(), c:getY()),
        infection = M.infection(M.infectionState(record)),
        guide = Folder.newGuide(record),
        waybill = M.waybill(record, flight),
        reissueCost = OA.reissueCost(),
    }
end

function OATabHeli:build(L, w, h)
    local lw = M.heroWidth(w)
    self:buildHero(L, 0, 0, lw, h)
    self:buildWaybill(L, lw + 8, 0, w - lw - 8, h)
end

function OATabHeli:buildHero(L, x, y, w, h)
    local d, p, fh = self.data, L.p, L.fh
    local H = d.heli
    Draw.panel(L, x, y, w, h)
    Draw.text(L, getText("IGUI_OA_Trade_Heli_Title"), x + 10, y + 6, p.dim)
    Draw.fit(L, H.state, x + 10, y + 20, w - 20, p[H.colour] or p.bright, UIFont.Medium)
    local subs = {}
    for _, s in ipairs(H.subs) do
        for _, line in ipairs(Draw.wrap(s.text, w - 20)) do subs[#subs + 1] = { line, p[s.colour] or p.text } end
    end
    local top = #subs * fh + (H.eta and 14 or 0) + (d.infection and 46 or 0)
    local roomy, gap, showSpec, showFacts = M.heroSpacing(h, top, 2, d.guide ~= nil)
    local yy = y + 46
    for _, s in ipairs(subs) do
        Draw.text(L, s[1], x + 10, yy, s[2])
        yy = yy + fh
    end
    self.eta = nil
    if H.eta then
        -- On its way: from the call to the arrival, filled by the time gone (moved on by update).
        local bw = w - 20
        Draw.rect(L, x + 10, yy + 4, bw, 5, p.border, 0.30)
        local fill = { Draw.RECT, x + 10, yy + 4, 0, 5, p.panel and p.value or p.sel, 0.95 }
        L.ops[#L.ops + 1] = fill
        Draw.frame(L, x + 9, yy + 3, bw + 2, 7, p.border)
        self.eta = { op = fill, w = bw, from = H.eta.from, to = H.eta.to }
        self:moveEta()
        yy = yy + 14
    end
    if d.infection then
        -- Infected or a wound not tested: what holds it and the fee on deliveries.
        yy = yy + 4
        Draw.box(L, x + 10, yy, w - 20, 38, p.warn, 0.08, p.warn, 0.8)
        Draw.fit(L, d.infection[1], x + 18, yy + 3, w - 36, p.warn)
        if d.infection[2] then Draw.fit(L, d.infection[2], x + 18, yy + 3 + fh, w - 36, p.dim) end
        yy = yy + 42
    end
    yy = yy + gap
    if showSpec then
        -- 헬기 사양: the four values the upgrades sub-tab raises.
        Draw.text(L, getText("IGUI_OA_Status_Spec"), x + 10, yy, p.dim)
        Draw.fit(L, getText("IGUI_OA_Status_SpecHint"), x + 10, yy, w - 20, p.dim, nil, 0.8, "right")
        yy = yy + 18
        local cw = math.floor((w - 20) / 2)
        for i, s in ipairs(d.spec) do
            local col, row = OA.remainder(i - 1, 2), math.floor((i - 1) / 2)
            Draw.run(L, { { s = s.label .. " ", c = p.dim }, { s = s.value, c = p.text } }, x + 10 + col * cw, yy + row * fh,
                cw - 4)
        end
        yy = yy + 2 * fh + 4 + gap
    end
    if showFacts then self:buildFacts(L, x, yy, w, roomy) end
    if d.guide then self:buildGuide(L, x + 10, y + h - 66 - M.GUIDE_GAP - M.GUIDE_H, w - 20) end
    -- The buttons, at the bottom.
    Draw.button(L, x + 10, y + h - 66, w - 20, 30, getText("IGUI_OA_Trade_Heli_Call"), H.callable and "strong" or "disabled",
        UIFont.Medium, "call", not H.callable and H.callWhy and Draw.tip(p, { H.callWhy }) or nil)
    Draw.button(L, x + 10, y + h - 31, w - 20, 22, getText("IGUI_OA_Status_Reissue", Text.credits(d.reissueCost)),
        H.reissue and "strong" or "disabled", nil, "reissue", not H.reissue and H.reissueWhy and Draw.tip(p, { H.reissueWhy }) or nil)
end

-- The last settlement and the crates under a rule from yy: a label line and a value line each, or one line each when
-- short.
function OATabHeli:buildFacts(L, x, yy, w, roomy)
    local d, p, fh = self.data, L.p, L.fh
    Draw.rect(L, x + 10, yy - 4, w - 20, 1, p.border, 0.6)
    yy = yy + 4
    local facts = {
        { getText("IGUI_OA_Status_LastSettle"), d.last and Draw.styled(L, d.last, p.text, p.value,
            { [1] = { p.text, UIFont.Small }, [3] = { p.text, p.numberFont } })
            or { { s = getText("IGUI_OA_Status_LastSettleNone"), c = p.dim } } },
        { getText("IGUI_OA_Status_Crates"), d.crates and { { s = d.crates, c = p.text } }
            or { { s = getText("IGUI_OA_Status_CratesNone"), c = p.dim } } },
    }
    local labelW = 0
    for _, f in ipairs(facts) do labelW = math.max(labelW, UI.textWidth(f[1])) end
    local vx = math.max(58, labelW + 10)
    for _, f in ipairs(facts) do
        Draw.text(L, f[1], x + 10, yy, p.dim)
        if roomy then
            Draw.run(L, f[2], x + 10, yy + fh, w - 20)
            yy = yy + 2 * fh + 4
        else
            Draw.run(L, f[2], x + vx, yy, w - vx - 10)
            yy = yy + fh + 2
        end
    end
end

-- The new guide document's card (DESIGN-terminal 11.1 priority 2), amber: "새 문서" over the document's title, and a
-- button that opens it in the folder. It goes when the document is read.
function OATabHeli:buildGuide(L, x, y, w)
    local d, p, fh = self.data, L.p, L.fh
    local H = M.GUIDE_H
    Draw.box(L, x, y, w, H, p.warn, 0.08, p.warn, 0.9)
    local bw = 56
    Draw.text(L, getText("IGUI_OA_Status_Guide_New"), x + 8, y + 3, p.warn)
    Draw.fit(L, d.guide.title, x + 8, y + 3 + fh, w - bw - 24, p.bright)
    Draw.button(L, x + w - bw - 6, y + math.floor((H - 24) / 2), bw, 24, getText("IGUI_OA_Status_Guide_Read"), "strong", nil,
        "guide")
end

function OATabHeli:buildWaybill(L, x, y, w, h)
    local d, p, fh, nf = self.data, L.p, L.fh, L.p.numberFont
    local W = d.waybill
    Draw.panel(L, x, y, w, h)
    Draw.text(L, getText("IGUI_OA_Status_Waybill"), x + 10, y + 6, p.head)
    Draw.run(L, Draw.styled(L, M.parts("IGUI_OA_Status_Serial", W.serial), p.dim, p.dim), x + 10, y + 6, w - 20, "right")
    Draw.rect(L, x + 10, y + 26, w - 20, 1, p.border, 0.7)
    local yy = y + 32
    local function section(title)
        local tw = Draw.text(L, title, x + 10, yy, p.dim)
        Draw.rect(L, x + 18 + tw, yy + 8, w - 28 - tw, 1, p.border, 0.35)
        yy = yy + 18
    end
    -- What goes up.
    section(getText("IGUI_OA_Status_Send"))
    for _, s in ipairs(W.send) do
        if s.icon then Draw.item(L, s.icon, x + 14, yy, 16) end
        local right = 0
        if s.worth then
            right = Draw.run(L, { { s = getText("IGUI_OA_Status_SendWorth") .. " ", c = p.dim }, { s = s.worth, c = p.value, font = nf } },
                x + 10, yy, w - 22, "right")
        end
        Draw.fit(L, s.name, x + 36, yy, w - 50 - right - 8, s.warn and p.warn or p.text)
        yy = yy + fh
        if s.sub then
            Draw.fit(L, s.sub, x + 36, yy, w - 50, p.dim)
            yy = yy + fh
        end
        yy = yy + 2
    end
    yy = yy + 4
    -- What comes down: the orders, then the flight support requests (an amber tag instead of an icon).
    section(getText("IGUI_OA_Status_Recv"))
    local calcH = fh * #W.calc + 8 + 26
    local room = h - calcH - (yy - y) - 6
    local row = OATabHeli.ROW
    self.recvRows, self.recvBox = 0, nil
    if W.recvNone then
        Draw.fit(L, W.recvNone, x + 14, yy, w - 28, p.dim)
    else
        local n = #W.recv
        local show = n
        if row * n > room then show = math.max(1, math.floor(room / row)) end
        local first = OA.clamp(self.recvScroll or 0, 0, n - show)
        self.recvScroll = first
        self.recvRows, self.recvShow = n, show
        local scrolled = show < n
        local priceR = w - (scrolled and 28 or 20)
        local top = yy
        for i = first + 1, first + show do
            local r = W.recv[i]
            local priceText, priceFont, priceC = r.price, nf, p.text
            if r.waits then priceText, priceFont, priceC = getText("IGUI_OA_Status_SupportWaits"), UIFont.Small, p.dim end
            local pw = UI.textWidth(priceText, priceFont)
            if r.kind == "plan" then
                Draw.frame(L, x + 12, yy + 1, 52, 15, p.warn)
                Draw.fit(L, getText("IGUI_OA_Status_Support_Tag"), x + 12, yy, 52, p.warn, nil, 1, "centre")
                Draw.run(L, { { s = r.label .. " " .. r.from, c = p.text }, { arrow = true, c = p.dim }, { s = r.to, c = p.warn } },
                    x + 70, yy, priceR - pw - 78)
            else
                if r.type then Draw.item(L, r.type, x + 14, yy, 16) end
                Draw.fit(L, r.name, x + 36, yy, priceR - pw - 44, p.text)
            end
            Draw.text(L, priceText, x + priceR - pw, yy, priceC, priceFont)
            yy = yy + row
        end
        if scrolled then
            Draw.scrollbar(L, x + w - 14, top, row * show, first / math.max(1, n - show), show / n)
            self.recvBox = { x = x, y = top, w = w, h = row * show }
        end
    end
    -- The sums, pinned to the bottom.
    local cy = y + h - calcH
    Draw.rect(L, x + 10, cy - 4, w - 20, 1, p.border, 0.7)
    for _, c in ipairs(W.calc) do
        Draw.fit(L, c.label, x + 14, cy, w - 120, p.dim)
        Draw.textRight(L, c.amount, x + w - 12, cy, p[c.colour] or p.text, nf)
        cy = cy + fh
    end
    cy = cy + 2
    Draw.rect(L, x + math.floor(w / 2), cy, math.floor(w / 2) - 12, 1, p.text, 0.6)
    cy = cy + 4
    Draw.text(L, getText("IGUI_OA_Status_Calc_After"), x + 14, cy + 3, p.text)
    local big = p.panel and UIFont.Medium or nf
    Draw.run(L, { { s = W.total.amount, c = p[W.total.colour] or p.value, font = big },
        { s = UI.creditsUnit(), c = p.dim, pad = UI.UNIT_GAP } }, x + 10, cy + (p.panel and 0 or 3), w - 22, "right")
end

-- The arrival bar's fill for the time now.
function OATabHeli:moveEta()
    local e = self.eta
    if not e then return end
    local span = math.max(0.01, e.to - e.from)
    e.op[4] = math.floor(e.w * OA.clamp((OA.hours() - e.from) / span, 0, 1))
    Draw.bakeOp(e.op)
end

-- Real time (ms) between the arrival bar's moves.
OATabHeli.LOOK_MS = 1000

-- Every second or so: the arrival bar moves on; the screen is worked out again once the next call is possible and
-- every game hour (the time since the last settlement, the drug's hours left).
function OATabHeli:update()
    ISPanel.update(self)
    self.looked = self.looked or {}
    if not OA.due(self.looked, "arrival", getTimestampMs(), OATabHeli.LOOK_MS) then return end
    local d = self.data
    if not d then return end
    local now = OA.hours()
    if (d.heli.nextAt and now >= d.heli.nextAt) or now - d.now >= 1 then return self:refresh() end
    self:moveEta()
end

function OATabHeli:onMouseWheel(del)
    local b = self.recvBox
    if not b or (self.recvRows or 0) <= (self.recvShow or 0) then return false end
    local my = self:getMouseY()
    if my < b.y or my >= b.y + b.h then return false end
    self.recvScroll = (self.recvScroll or 0) + (del > 0 and 1 or -1)
    self:layout()
    return true
end

function OATabHeli:onHit(hit)
    if hit.id == "call" then self:onCall()
    elseif hit.id == "reissue" then self:onReissue()
    elseif hit.id == "guide" then self:onGuide() end
end

-- '읽기' on the new-document card: the folder opens on that document (the missions tab; reading it clears it).
function OATabHeli:onGuide()
    local guide = self.data and self.data.guide
    if guide and OA.StoryTabs then OA.StoryTabs.openDocument(self.window, guide.key) end
end

function OATabHeli:onCall()
    local d = self.data
    local W = d.waybill
    local text = getText("IGUI_OA_Trade_Heli_ConfirmCall", W.boxes, Text.credits(W.gain))
    -- the orders' line only when there are some
    if (W.orders or 0) > 0 then
        text = text .. "\n" .. getText("IGUI_OA_Trade_Heli_ConfirmOrders", Text.credits(W.orders))
    end
    text = text .. "\n" .. getText("IGUI_OA_Trade_Heli_ConfirmAfter", Text.credits(W.total.after))
    if d.heli.night then text = text .. "\n" .. getText("IGUI_OA_Status_Heli_Night") end
    text = string.gsub(text, "\\n", "\n")
    UI.confirm(self:character(), text, self, OATabHeli.doCall)
end

function OATabHeli:doCall()
    self:send("tradeCall", { kind = "normal" })
end

function OATabHeli:onReissue()
    local text = getText("IGUI_OA_Trade_Heli_ConfirmReissue", Text.credits(self.data.reissueCost))
    UI.confirm(self:character(), text, self, OATabHeli.doReissue)
end

function OATabHeli:doReissue()
    self:send("tradeCall", { kind = "reissue" })
end
