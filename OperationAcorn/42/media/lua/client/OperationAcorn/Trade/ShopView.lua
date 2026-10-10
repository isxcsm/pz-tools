-- What the terminal's shop tab (DESIGN-terminal 4) decides without drawing anything: which entries stand on the serum
-- shelf and in which order, the sections, why a card is locked, how the cards, the detail and the cart are laid out
-- for a body size, the cart's totals, and a word wrap. Plain functions over tables, so they are tested outside the game;
-- the tab (TabShop.lua) asks for them when the record changes and only draws the answers.
require "OperationAcorn/Core"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Economy/Shop"
local OA = OperationAcorn
local ShopView = {}
OA.Trade.ShopView = ShopView

-- The serum shelf (DESIGN-terminal 4.1) in its fixed order: the treatments, then the upgrade serums. An id the
-- catalog does not have is skipped; any other entry of the serum group, or that is a serum, is
-- put after them in the catalog's order.
ShopView.TREAT_IDS = { "cure_serum", "reversal", "delay_long", "delay_drug", "test_kit" }
ShopView.ENHANCE_IDS = { "serum_scout", "serum_load", "serum_survival" }

-- Sizes (DESIGN-terminal 4.1, 4.2, 1.2).
ShopView.CAT_W = 104        -- the left column
ShopView.SERUM_H = 48       -- the serum box on top of it
ShopView.CAT_TOP = 74       -- where the section rows start
ShopView.CAT_ROW = 22
ShopView.CARD_H = 58
ShopView.ROW_H = 64         -- a row of two cards, with the gap under it
ShopView.HEAD_H = 22        -- a block's head line
ShopView.BLOCK_GAP = 4      -- extra room after a block
ShopView.CART_ROW = 42
-- The detail's icon (design units: no icon of ours is laid out larger, Trade/StatusDraw itemTexture) and where its
-- text and its quantity row start.
ShopView.DETAIL_ICON, ShopView.DETAIL_TEXT = 32, 52
ShopView.WIDE = 680         -- from this body width on the cart is 200 wide, below it 176

-- Entries the shop tab never lists: the box reissue is bought with the status tab's button.
function ShopView.listed(entry)
    return entry.special ~= "reissue"
end

-- On the serum shelf: the serum group, and any entry that is a serum.
function ShopView.onShelf(entry)
    return entry.group == "serum" or entry.special == "serum"
end

local function isEnhance(entry)
    return entry.special == "serum"
end

-- The shelf as two blocks { { id = "treat", entries }, { id = "enhance", entries } } from a catalog (a list of entries).
function ShopView.shelf(catalog)
    local byId, shelf = {}, {}
    for _, e in ipairs(catalog) do
        byId[e.id] = e
        if ShopView.listed(e) and ShopView.onShelf(e) then shelf[e.id] = e end
    end
    local blocks = { { id = "treat", entries = {} }, { id = "enhance", entries = {} } }
    local placed = {}
    local function put(block, id)
        local e = shelf[id]
        if e and not placed[id] then
            placed[id] = true
            table.insert(block.entries, e)
        end
    end
    for _, id in ipairs(ShopView.TREAT_IDS) do put(blocks[1], id) end
    for _, id in ipairs(ShopView.ENHANCE_IDS) do put(blocks[2], id) end
    for _, e in ipairs(catalog) do
        if shelf[e.id] and not placed[e.id] then put(isEnhance(e) and blocks[2] or blocks[1], e.id) end
    end
    return blocks
end

-- How many entries the shelf has (the box's "치료 · 강화 8종").
function ShopView.shelfCount(blocks)
    local n = 0
    for _, b in ipairs(blocks) do n = n + #b.entries end
    return n
end

-- The entries of the sections (everything but the shelf and the reissue) in catalog order: { all = list, groups = { id
-- ... in the order they first appear }, byGroup = { [id] = list } }.
function ShopView.sections(catalog)
    local out = { all = {}, groups = {}, byGroup = {} }
    for _, e in ipairs(catalog) do
        if ShopView.listed(e) and not ShopView.onShelf(e) then
            table.insert(out.all, e)
            if not out.byGroup[e.group] then
                out.byGroup[e.group] = {}
                table.insert(out.groups, e.group)
            end
            table.insert(out.byGroup[e.group], e)
        end
    end
    return out
end

-- Whether an entry is for the field terminal only (the research team's), by the shop's own rule.
function ShopView.fieldOnly(entry)
    return OA.Shop.fieldOnly(entry)
end

-- A section whose every entry is field-only, seen from the crude terminal: it is marked with a padlock and the gate
-- band comes over its cards (DESIGN-terminal 4.1).
function ShopView.sectionLocked(entries, crude)
    if not crude or #entries == 0 then return false end
    for _, e in ipairs(entries) do
        if not ShopView.fieldOnly(e) then return false end
    end
    return true
end

-- The band over the cards: "debt" (red) first, else "gate" (amber) in a locked section; nil for none.
function ShopView.band(cat, entries, ctx)
    if ctx.debt then return "debt" end
    if cat ~= "serums" and cat ~= "all" and ShopView.sectionLocked(entries, ctx.crude) then return "gate" end
    return nil
end

-- What a card says and how (DESIGN-terminal 4.2). `avail` is what the shop answers for the record: { n (how many may
-- be bought, 0 for none), why (a translation key), reopen (the world age it opens again), serumN (which serum of its
-- tree the next would be) }. `ctx`: { crude, tier (trust), debt, whenText(hours) }.
-- Returns { open, key, args, tone ("dim" | "warn" | "bad" | "timer"), lock (a padlock before the text), reason (the
-- translation key a refused order gives), n (how many at most) }.
function ShopView.state(entry, avail, ctx)
    local n, why = avail.n or 0, avail.why
    local s = { open = false, tone = "dim", lock = true, args = {}, n = n }
    if why == "IGUI_OA_Econ_Shop_NotStocked" then
        s.key, s.reason = why, why
    elseif ctx.debt and not entry.allowDebt then
        s.key, s.tone, s.reason = "IGUI_OA_Terminal_Shop_Debt", "bad", "IGUI_OA_Econ_Shop_Debt"
    elseif ctx.crude and ShopView.fieldOnly(entry) then
        s.tone, s.reason = "warn", "IGUI_OA_Trade_Reason_fieldOnly"
        if entry.tier > ctx.tier then
            s.key, s.args = "IGUI_OA_Terminal_Shop_FieldTier", { entry.tier }
        else
            s.key = "IGUI_OA_Terminal_Shop_FieldNeeded"
        end
    elseif entry.tier > ctx.tier then
        s.key, s.args, s.reason = "IGUI_OA_Terminal_Shop_Tier", { entry.tier }, "IGUI_OA_Econ_Shop_Locked"
    elseif why == "IGUI_OA_Econ_Shop_KitsOff" then
        s.key, s.reason = why, why
    elseif why == "IGUI_OA_Econ_Shop_Limit" then
        s.tone, s.lock, s.reason = "timer", false, why
        if avail.reopen and ctx.whenText then
            s.key, s.args = "IGUI_OA_Terminal_Shop_LimitFrom", { ctx.whenText(avail.reopen) }
        else
            s.key = why
        end
    elseif n > 0 then
        s.open, s.lock, s.reason = true, false, nil
        if entry.week then
            s.key, s.args = "IGUI_OA_Terminal_Shop_WeekLeft", { n, entry.week }
        elseif entry.special == "serum" then
            s.key, s.args = "IGUI_OA_Terminal_Shop_Nth", { avail.serumN or 1 }
        else
            s.key = "IGUI_OA_Terminal_Shop_Ready"
        end
    else
        s.key, s.reason = why or "IGUI_OA_Econ_Shop_Locked", why or "IGUI_OA_Econ_Shop_Locked"
    end
    return s
end

-- A word wrap: `text` cut into lines no wider than `width` by `measure(string)`, at spaces (a word wider than a line
-- is cut between letters). At most `maxLines` lines when given: the last one ends in "..." if text was left.
function ShopView.wrap(text, width, measure, maxLines)
    local lines, line = {}, ""
    local function push()
        if line ~= "" then lines[#lines + 1] = line end
        line = ""
    end
    for word in string.gmatch(text or "", "%S+") do
        local try = (line == "") and word or (line .. " " .. word)
        if measure(try) <= width then
            line = try
        else
            push()
            while #word > 1 and measure(word) > width do
                local k = #word - 1
                while k > 1 and measure(string.sub(word, 1, k)) > width do k = k - 1 end
                lines[#lines + 1] = string.sub(word, 1, k)
                word = string.sub(word, k + 1)
            end
            line = word
        end
    end
    push()
    if maxLines and #lines > maxLines then
        while #lines > maxLines do table.remove(lines) end
        local last = lines[#lines]
        while #last > 1 and measure(last .. "...") > width do last = string.sub(last, 1, #last - 1) end
        lines[#lines] = last .. "..."
    end
    return lines
end

-- The rows of the card list from blocks { { head, note, entries = { card ... } } } (a block without a head has none):
-- { kind = "head", head, note, h } and { kind = "cards", cards = { card with .col = 0 | 1 ... }, h }.
function ShopView.rows(blocks)
    local used = {}
    for _, block in ipairs(blocks) do
        if #block.cards > 0 then used[#used + 1] = block end
    end
    local rows = {}
    for bi, block in ipairs(used) do
        if block.head then
            rows[#rows + 1] = { kind = "head", head = block.head, note = block.note, h = ShopView.HEAD_H }
        end
        local row
        for i, card in ipairs(block.cards) do
            if i % 2 == 1 then
                row = { kind = "cards", cards = {}, h = ShopView.ROW_H }
                rows[#rows + 1] = row
            end
            card.col = (i - 1) % 2
            row.cards[#row.cards + 1] = card
        end
        if bi < #used and block.head then row.h = row.h + ShopView.BLOCK_GAP end
    end
    return rows
end

-- The columns of a body `w` wide: the left column, the cards and detail column, the cart (DESIGN-terminal 1.2: the
-- cart is 200 wide, 176 in a narrow window, and the cards take what is left).
function ShopView.columns(w)
    local cartw = w >= ShopView.WIDE and 200 or 176
    local cx = ShopView.CAT_W + 8
    return { catw = ShopView.CAT_W, cx = cx, cw = w - cx - cartw - 8, cartw = cartw, cartx = w - cartw }
end

-- The two cards in a row: each this wide, with 6 between them and room for the scroll bar on the right.
function ShopView.cardWidth(listWidth)
    return math.floor((listWidth - 14) / 2)
end

-- The rectangles of a body `w` by `h`. `o`: { lineH (a text line), descLines (of the detail's text), bandLines (0 for
-- no band) }. { cols, band = {x,y,w,h} | nil, cards = {x,y,w,h}, detail = {x,y,w,h}, cart = {x,y,w,h} }. The
-- detail is 104 high, 120 when its text takes three lines.
function ShopView.layout(w, h, o)
    local cols = ShopView.columns(w)
    local lineH = o.lineH or 16
    local detailH = (o.descLines or 2) > 2 and 120 or 104
    local out = { cols = cols }
    local top = 0
    if (o.bandLines or 0) > 0 then
        local bh = lineH * o.bandLines + 8
        out.band = { x = cols.cx, y = 0, w = cols.cw, h = bh }
        top = bh + 6
    end
    out.cards = { x = cols.cx, y = top, w = cols.cw, h = math.max(0, h - detailH - 8 - top) }
    out.detail = { x = cols.cx, y = h - detailH, w = cols.cw, h = detailH }
    out.cart = { x = cols.cartx, y = 0, w = cols.cartw, h = h }
    return out
end

-- Where the detail's controls go (x relative to the detail, y of the control row from its top). With a combo box
-- (the kinds of a seed, a battery, a target of a kit) there is no quantity: the label `종류 고르기` and the box sit
-- at the left, the box shortening to leave room for the button; a detail too narrow for the label drops it and
-- starts the box at the margin.
function ShopView.detailRow(cw, detailH, hasCombo)
    local addW = 118
    local row = { y = detailH - 28, h = 20, add = { x = cw - addW - 10, w = addW } }
    if hasCombo then
        local labelled = cw >= 340
        local x = labelled and 76 or 10
        row.combo = { x = x, w = math.max(60, math.min(150, row.add.x - 8 - x)), label = labelled }
    else
        local x = ShopView.DETAIL_TEXT
        row.minus, row.count, row.plus = { x = x, w = 20 }, { x = x + 22, w = 24 }, { x = x + 48, w = 20 }
    end
    return row
end

-- The cart's totals (DESIGN-terminal 4.4): the sum, the balance before and after, and how much is short.
function ShopView.cartSummary(total, balance)
    return { total = total, balance = balance, after = balance - total, short = math.max(0, total - balance) }
end

-- The cart panel's pieces from the bottom up: the clear button, the hint (`hintLines` lines) over it, the totals
-- (two lines, and `shortLines` lines more when the balance is short) over that, and the list of lines above all of
-- it. Returns y values in the cart panel; `list` = { y, h }. With an empty cart there are no totals.
function ShopView.cartRects(h, hintLines, shortLines, hasLines, lineH)
    lineH = lineH or 16
    local out = { clearY = h - 30 }
    out.hintY = out.clearY - 6 - lineH * hintLines
    local bottom = out.hintY - 10
    if hasLines then
        local sum = lineH + 4 + lineH
        if shortLines > 0 then sum = sum + 6 + lineH * shortLines end
        out.sumY = bottom - sum
        out.totalY, out.balanceY = out.sumY, out.sumY + lineH + 4
        out.shortY = out.balanceY + lineH + 6
        out.ruleY = out.sumY - 6
        bottom = out.sumY - 12
    end
    out.list = { y = 28, h = math.max(0, bottom - 28) }
    return out
end

return ShopView
