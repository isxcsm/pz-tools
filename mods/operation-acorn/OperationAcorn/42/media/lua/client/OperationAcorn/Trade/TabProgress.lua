-- The record tab's progress screen (DESIGN-terminal 2.3): the trust road laid across, nine nodes (the five stages,
-- the levels 6, 7, 8 after them and every level from the ninth), filled up to where the player is. Under each node two
-- lanes say what the level opens: on every terminal (shop goods, missions, serums) and on the field terminal only (the
-- research team's goods, special requests, how many upgrades). The crude terminal's field lane is dimmed under a
-- padlock, with a band that says how to get one from the 2nd stage on. Below, the chosen level's full list in three
-- columns. A node or a cell is chosen with a click; a cell's tooltip lists its goods with their prices.
require "OperationAcorn/Trade/StatusDraw"
require "OperationAcorn/Trade/StatusModel"
local OA = OperationAcorn
local Trade, Text = OA.Trade, OA.Trade.Text
local Draw, M, Orders = Trade.Draw, Trade.StatusModel, Trade.Orders
local Shop, Trust = OA.Shop, OA.Trust

OATabProgress = OAStatusView:derive("OATabProgress")

-- A level's goods as rows: { type, name, price }. The field tools are one row (how many, the cheapest and the dearest),
-- where the first of them stands.
local function goods(entries, record)
    local out = {}
    local tools
    for _, e in ipairs(entries) do
        local price = Shop.price(e, record)
        if e.group == M.TOOLS then
            if not tools then
                tools = { id = e.id, type = M.entryType(e), n = 0, low = price, high = price }
                out[#out + 1] = tools
            end
            tools.n = tools.n + 1
            tools.low, tools.high = math.min(tools.low, price), math.max(tools.high, price)
        else
            out[#out + 1] = { id = e.id, type = M.entryType(e), name = Orders.nameOf(e), price = Text.credits(price) }
        end
    end
    if tools then
        tools.name = getText("IGUI_OA_Status_Tools", tools.n)
        tools.price = tools.low == tools.high and Text.credits(tools.low)
            or (Text.credits(tools.low) .. "~" .. Text.credits(tools.high))
    end
    return out
end

function OATabProgress:model(record)
    local cur, frac = M.roadPosition(record)
    local levels = {}
    local lanes = M.lanes(record)
    for t = 1, M.LEVELS do
        levels[t] = {
            t = t, node = M.nodeName(t, cur), name = M.levelName(t, cur),
            itemsA = goods(lanes[t].all, record), itemsB = goods(lanes[t].field, record),
            chipsA = M.chipsA(t, cur), chipsB = M.chipsB(t), moreA = M.moreA(t, cur), ups = M.upgradeLines(t),
            nUps = #M.upgradesOpening(t), note = M.detailNote(record, t),
        }
    end
    local terminal = Shop.entry("field_terminal")
    -- The level entered since the screen was last looked at stays lit while the window is open (the window keeps it
    -- as seen at once, and the sub-tab's dot goes with that).
    self.fresh = M.roadFresh(record) or self.fresh
    return {
        cur = cur, frac = frac, levels = levels, field = self.window.tier == "field", fresh = self.fresh,
        cta = self.window.tier ~= "field" and Trust.tier(record) >= 2,
        ctaPrice = terminal and Text.credits(Shop.price(terminal, record)) or nil,
        terminalType = Shop.TYPES.fieldTerminal,
    }
end

-- One lane's cell: icons as many as fit (the rest counted; `first`, a good's id, put first), then the short words
-- under them.
local function cell(L, x, y, w, h, items, chips, a, locked, first)
    local p = L.p
    local per = math.max(1, math.floor((w + 2) / 18))
    local list = items
    if first then
        list = {}
        for _, it in ipairs(items) do if it.id == first then table.insert(list, 1, it) else list[#list + 1] = it end end
    end
    local shown = #list <= per and #list or per - 1
    local ix = x
    for i = 1, shown do
        local it = list[i]
        Draw.item(L, it.type, ix, y, 16, a)
        ix = ix + 18
    end
    if shown < #list then Draw.text(L, "+" .. (#list - shown), ix, y, p.dim, nil, a) end
    local cy = y + (#list > 0 and 18 or 0)
    for _, s in ipairs(chips) do
        if cy + 14 > y + h + 2 then break end
        Draw.fit(L, s, x, cy, w, locked and p.warn or p.text, nil, a)
        cy = cy + 14
    end
    if #list == 0 and #chips == 0 then Draw.rect(L, x + math.floor(w / 2) - 4, y + 8, 8, 1, p.border, a) end
end

-- A cell's tooltip: every good with its price, then what else the level opens there.
local function cellTip(p, d, lv, lane)
    local lines = {}
    local head = lane == "A" and getText("IGUI_OA_Status_Lane_All") or getText("IGUI_OA_Status_Col_Team")
    lines[1] = { s = lv.name .. Text.DOT .. head, c = p.head }
    for _, it in ipairs(lane == "A" and lv.itemsA or lv.itemsB) do lines[#lines + 1] = it.name .. Text.DOT .. it.price end
    if lane == "A" then
        for _, s in ipairs(lv.moreA) do lines[#lines + 1] = s end
    else
        if lv.t == 2 then lines[#lines + 1] = getText("IGUI_OA_Status_Chip_special") end
        if lv.t >= M.LEVELS then lines[#lines + 1] = lv.chipsB[1] end
        if lv.nUps > 0 then
            lines[#lines + 1] = "-"
            lines[#lines + 1] = getText("IGUI_OA_Status_Tip_UpCount", lv.nUps)
        end
        if not d.field then lines[#lines + 1] = { s = getText("IGUI_OA_Status_Tip_NeedField"), c = p.warn } end
    end
    if #lines == 1 then lines[2] = { s = getText("IGUI_OA_Status_Nothing"), c = p.dim } end
    return Draw.tip(p, lines)
end

function OATabProgress:build(L, w, h)
    local d, p, fh = self.data, L.p, L.fh
    local crude = not d.field
    local R = M.roadLayout(w, h)
    local lx, colw = R.lx, R.colw
    local half = math.floor(colw / 2)
    local cur = d.cur
    local sel = OA.clamp(self.sel or math.min(cur + 1, M.LEVELS), 1, M.LEVELS)
    local function cx(t) return lx + (t - 1) * colw end
    -- The lanes' names.
    Draw.fit(L, getText("IGUI_OA_Status_Lane_All"), 0, R.ya + 6, lx - 2, p.text)
    Draw.fit(L, getText("IGUI_OA_Status_Lane_AllSub"), 0, R.ya + 6 + fh, lx - 2, p.dim)
    if crude then
        Draw.lock(L, 0, R.yb + 9, p.warn)
        Draw.fit(L, getText("IGUI_OA_Terminal_Field"), 12, R.yb + 6, lx - 14, p.warn)
    else
        Draw.fit(L, getText("IGUI_OA_Terminal_Field"), 0, R.yb + 6, lx - 2, p.value)
    end
    Draw.fit(L, getText("IGUI_OA_Status_Lane_FieldSub"), 0, R.yb + 6 + fh, lx - 2, p.dim)
    -- The road: a line through the nodes, dashed after the stages, filled up to where the player is.
    local ly = 8
    local start, finish = cx(1) + half, cx(M.LEVELS) + half
    Draw.rect(L, start, ly + 4, 4 * colw, 1, p.border)
    for k = cx(5) + half, finish - 1, 6 do Draw.rect(L, k, ly + 4, 3, 1, p.border) end
    Draw.rect(L, cx(6), 0, 1, R.trackH, p.border, 0.6)
    local fill = crude and p.sel or p.value
    if cur >= 1 then
        local doneTo = math.min(finish, cx(cur) + half + math.floor(colw * d.frac))
        Draw.rect(L, start, ly + 3, doneTo - start, 3, fill, 0.9)
    end
    for t = 1, M.LEVELS do
        local lv = d.levels[t]
        local x = cx(t)
        local mid = x + half
        local past, now = t < cur, t == cur
        if t == d.fresh then
            -- The level just entered (DESIGN-terminal 11.1 priority 4): amber box and a small mark by the name.
            Draw.box(L, x + 2, 0, colw - 4, R.trackH, p.warn, 0.08, p.warn, 0.9)
            Draw.rect(L, x + colw - 10, 4, 4, 4, p.warn)
        end
        if t == sel then
            Draw.box(L, x + 2, 0, colw - 4, R.trackH, p.sel, 0.10, p.sel, 0.9)
        elseif now then
            Draw.rect(L, x + 2, 0, colw - 4, R.trackH, p.sel, 0.05)
        end
        if past or now then
            Draw.rect(L, mid - 5, ly, 10, 10, fill)
        else
            Draw.box(L, mid - 5, ly, 10, 10, p.bg, 1, t == sel and p.text or p.border)
        end
        if now then Draw.frame(L, mid - 7, ly - 2, 14, 14, p.bright) end
        Draw.fit(L, lv.node, x, 19, colw, (now or t == sel) and p.bright or (past and p.dim or p.text), nil, 1, "centre")
        local a = past and 0.45 or 1
        cell(L, x + 5, R.ya + 4, colw - 10, R.laneH - 6, lv.itemsA, lv.chipsA, a, false,
            crude and t == 2 and "field_terminal" or nil)
        cell(L, x + 5, R.yb + 4, colw - 10, R.laneH - 6, lv.itemsB, lv.chipsB, crude and 0.35 or a, crude)
        local node = Draw.hit(L, x, 0, colw, R.ya, "level")
        node.level = t
        local hitA = Draw.hit(L, x, R.ya, colw, R.yb - R.ya, "level", cellTip(p, d, lv, "A"))
        hitA.level = t
        local hitB = Draw.hit(L, x, R.yb, colw, R.trackH - R.yb, "level", cellTip(p, d, lv, "B"))
        hitB.level = t
    end
    Draw.rect(L, lx, R.ya, w - lx, 1, p.border, 0.5)
    Draw.rect(L, lx, R.yb - 2, w - lx, 1, p.border, 0.5)
    Draw.rect(L, lx, R.trackH + 2, w - lx, 1, p.border, 0.5)
    local yy = R.trackH + 10
    if d.cta then
        local bh = R.roomy and 28 or 24
        self:buildCta(L, 0, yy, w, bh)
        yy = yy + bh + 6
    end
    self:buildDetail(L, 0, yy, w, h - yy, sel)
end

-- The crude terminal's band from the 2nd stage: what the field terminal opens, where to get it, and a button there.
function OATabProgress:buildCta(L, x, y, w, h)
    local d, p = self.data, L.p
    Draw.box(L, x, y, w, h, p.warn, 0.10, p.warn, 0.9)
    local ty = y + math.floor((h - L.fh) / 2)
    Draw.item(L, d.terminalType, x + 8, y + math.floor((h - 16) / 2), 16)
    local parts = { { s = getText("IGUI_OA_Status_Cta") .. " ", c = p.warn } }
    for _, part in ipairs(Draw.styled(L, M.parts("IGUI_OA_Status_CtaWhere", d.ctaPrice or "?"), p.dim, p.text)) do
        parts[#parts + 1] = part
    end
    Draw.run(L, parts, x + 32, ty, w - 150)
    Draw.button(L, x + w - 108, y + 3, 100, h - 6, getText("IGUI_OA_Status_ShowInShop"), "strong", nil, "shop")
end

-- The chosen level's list: every terminal's goods and other things, the team's goods, the upgrades it opens.
function OATabProgress:buildDetail(L, x, y, w, h, t)
    local d, p, fh, nf = self.data, L.p, L.fh, L.p.numberFont
    local crude = not d.field
    local lv = d.levels[t]
    local past = t <= d.cur
    Draw.panel(L, x, y, w, h)
    local noteW = Draw.runWidth(Draw.styled(L, lv.note, p.dim, p.text))
    Draw.fit(L, getText("IGUI_OA_Status_Opens", lv.name), x + 10, y + 5, w - 30 - noteW, p.head)
    Draw.run(L, Draw.styled(L, lv.note, p.dim, p.text), x + 10, y + 5, w - 20, "right")
    local gw = math.floor((w - 20 - 16) / 3)
    local top = y + 26
    local rows = math.max(2, math.floor((h - 26 - 4) / 17))
    local function head(hx, s, c, locked)
        if locked then
            Draw.lock(L, hx, top + 4, p.warn)
            hx = hx + 12
        end
        Draw.fit(L, s, hx, top, gw - (locked and 12 or 0), c)
    end
    local function column(cx, items, extra, dim)
        local yy = top + 18
        local lines = {}
        for _, it in ipairs(items) do lines[#lines + 1] = { item = it } end
        for _, s in ipairs(extra) do lines[#lines + 1] = { text = s } end
        local show = #lines <= rows - 1 and #lines or rows - 2
        local tc = dim and p.dim or p.text
        for i = 1, show do
            local line = lines[i]
            if line.item then
                Draw.item(L, line.item.type, cx, yy, 16, dim and 0.5 or 1)
                local pw = Draw.textRight(L, line.item.price, cx + gw - 4, yy, tc, nf)
                Draw.fit(L, line.item.name, cx + 20, yy, gw - 30 - pw, tc)
            else
                Draw.bullet(L, cx + 6, yy - 1, tc)
                Draw.fit(L, line.text, cx + 20, yy, gw - 24, tc)
            end
            yy = yy + 17
        end
        if show < #lines then
            Draw.fit(L, getText("IGUI_OA_Status_MoreRows", #lines - show), cx + 20, yy, gw - 24, p.dim)
            local all = {}
            for _, line in ipairs(lines) do
                all[#all + 1] = line.item and (line.item.name .. Text.DOT .. line.item.price) or line.text
            end
            Draw.hit(L, cx, top, gw, h - 26, nil, Draw.tip(p, all))
        end
    end
    local gx = x + 10
    head(gx, getText("IGUI_OA_Status_Lane_All"), p.text)
    column(gx, lv.itemsA, lv.moreA, past)
    gx = gx + gw + 8
    Draw.rect(L, gx - 5, top, 1, h - 26 - 8, p.border, 0.5)
    head(gx, getText("IGUI_OA_Status_Col_Team"), crude and p.warn or p.value, crude)
    column(gx, lv.itemsB, t == 2 and { getText("IGUI_OA_Status_Chip_special") } or {}, crude or past)
    gx = gx + gw + 8
    Draw.rect(L, gx - 5, top, 1, h - 26 - 8, p.border, 0.5)
    head(gx, getText("IGUI_OA_Status_Col_Up"), crude and p.warn or p.value, crude)
    column(gx, {}, lv.ups, crude or past)
end

function OATabProgress:onHit(hit)
    if hit.id == "level" then
        self.sel = hit.level
        self:layout()
    elseif hit.id == "shop" then
        self.window:showShopEntry("field_terminal")
    end
end
