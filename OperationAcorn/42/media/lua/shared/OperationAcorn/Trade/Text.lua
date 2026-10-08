-- The words of the trade part: money, times, the radio's greeting, the reasons orders are cut short, and a receipt
-- written out as lines. Plain functions over tables and a translate function, so they are tested outside the game.
require "OperationAcorn/Core"
require "OperationAcorn/Trade/Trade"
local OA = OperationAcorn
local Trade = OA.Trade
local Text = {}
Trade.Text = Text

-- The translate function (the game's getText); a test sets its own.
function Text.tr(key, ...)
    return getText(key, ...)
end

-- The name of an item type (the game's), for a receipt line.
function Text.itemName(fullType)
    if not fullType then return "?" end
    local ok, name = pcall(getItemNameFromFullType, fullType)
    if ok and name and name ~= "" then return name end
    return tostring(fullType)
end
Text.nameOf = Text.itemName

-- 12345 as "12,345", -500 as "-500".
function Text.credits(n)
    n = OA.round(n or 0)
    local sign = n < 0 and "-" or ""
    local digits = tostring(math.abs(n))
    local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if string.sub(out, 1, 1) == "," then out = string.sub(out, 2) end
    return sign .. out
end

-- The hours and minutes of a time of day (0 up to 24) as "07:05".
function Text.clock(tod)
    local h = math.floor(tod)
    local m = math.floor((tod - h) * 60)
    return string.format("%02d:%02d", h % 24, m)
end

-- The radio's greeting by the trust stage the line was said at (LORE 6): the long one at the start, shorter as the
-- team knows the survivor, none at the highest stage.
function Text.greeting(stage)
    stage = math.max(0, math.min(5, math.floor(stage or 0)))
    if stage >= 5 then return "" end
    return Text.tr("IGUI_OA_Trade_Greet_" .. stage)
end

-- A radio log entry { key, args, stage } as a line. A line of this part gets the greeting of its stage and the
-- closing word; the story part's lines (other keys) are said as they are written.
function Text.radio(entry)
    local args = entry.args or {}
    local body = Text.tr(entry.key, unpack(args))
    if not string.find(entry.key, "^IGUI_OA_Trade_Radio_%a") then return body end
    local greeting = Text.greeting(entry.stage)
    local line = body .. " " .. Text.tr("IGUI_OA_Trade_Radio_Over")
    if greeting ~= "" then line = greeting .. " " .. line end
    return line
end

-- Why an order was cut short: the shop's own reasons are translation keys; the helicopter's are short words.
function Text.orderReason(reason)
    if not reason then return nil end
    if string.sub(reason, 1, 5) == "IGUI_" then return Text.tr(reason) end
    return Text.tr("IGUI_OA_Trade_OrderReason_" .. reason)
end

-- The marks of a line as one text ("request, high"): the economy part names them.
local function markText(marks)
    if not marks or not (OA.Value and OA.Value.markKeys) then return nil end
    local words = {}
    for _, key in ipairs(OA.Value.markKeys(marks)) do words[#words + 1] = Text.tr(key) end
    if #words == 0 then return nil end
    return table.concat(words, ", ")
end
Text.markText = markText

-- A receipt as lines { text, kind } for the manifest, the ledger and the radio's look back. kind is "head", "line",
-- "good" (a gift), "bad" (something cut short), "note" or "total".
function Text.receipt(receipt)
    local lines = {}
    local function add(kind, key, ...)
        lines[#lines + 1] = { kind = kind, text = Text.tr(key, ...) }
    end
    local function raw(kind, text)
        lines[#lines + 1] = { kind = kind, text = text }
    end
    add("head", "IGUI_OA_Trade_Rc_Head", receipt.id or 0, receipt.day or 0)
    if receipt.kind == "reissue" then add("line", "IGUI_OA_Trade_Rc_Reissue") end
    if (receipt.boxes or 0) > 0 then
        add("line", "IGUI_OA_Trade_Rc_Boxes", receipt.boxes, Text.credits(receipt.credits), Text.credits(receipt.trust))
        for _, line in ipairs(receipt.lines or {}) do
            local name = line.fullType and Text.itemName(line.fullType) or Text.tr("IGUI_OA_Trade_Rc_Other", line.other or 0)
            local text = Text.tr("IGUI_OA_Trade_Rc_Line", name, line.count or 0, Text.credits(line.credits))
            local marks = markText(line.marks)
            if marks then text = text .. "  (" .. marks .. ")" end
            raw("line", text)
        end
    elseif receipt.kind ~= "reissue" then
        add("line", "IGUI_OA_Trade_Rc_NoBoxes")
    end
    if (receipt.bonus or 0) ~= 0 then add("good", "IGUI_OA_Trade_Rc_Bonus", Text.credits(receipt.bonus)) end
    if (receipt.debtPaid or 0) > 0 then add("line", "IGUI_OA_Trade_Rc_DebtPaid", Text.credits(receipt.debtPaid)) end
    for _, order in ipairs(receipt.orders or {}) do
        local entry = Trade.Orders and Trade.Orders.entry(order.id)
        local name = entry and Trade.Orders.nameOf(entry) or tostring(order.id)
        local kind = (order.delivered or 0) < (order.ordered or 0) and "bad" or "line"
        local text = Text.tr("IGUI_OA_Trade_Rc_Order", name, order.delivered or 0, order.ordered or 0, Text.credits(order.paid))
        local why = Text.orderReason(order.reason)
        if why and kind == "bad" then text = text .. "  - " .. why end
        raw(kind, text)
    end
    for _, gift in ipairs(receipt.gifts or {}) do
        raw("good", Text.tr("IGUI_OA_Trade_Rc_Gift", Text.itemName(gift.type), gift.count or 1))
    end
    if receipt.bonusNote then add("good", receipt.bonusNote) end
    for _, e in ipairs(receipt.events or {}) do
        if e.kind == "stage" then add("good", "IGUI_OA_Trade_Rc_NewItems", e.n or e.stage or 0) end
    end
    if receipt.note and receipt.note.key then
        local a = receipt.note.args or {}
        raw("note", Text.tr(receipt.note.key, unpack(a)))
    end
    add("total", "IGUI_OA_Trade_Rc_Balance", Text.credits(receipt.balanceBefore), Text.credits(receipt.balance))
    return lines
end

return Text
