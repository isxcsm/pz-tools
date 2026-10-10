-- The words of the trade part: money, the reasons orders are cut short, and a receipt
-- written out as lines. Plain functions over tables and a translate function, so they are tested outside the game.
require "OperationAcorn/Core"
require "OperationAcorn/Trade/Trade"
local OA = OperationAcorn
local Trade = OA.Trade
local Text = {}
Trade.Text = Text

-- The separator " · " and the sign × the screens put between words and before a count. Made from their
-- character codes: the game reads a mod's Lua files so that a letter past ASCII written in the code comes out as
-- U+FFFD (texts from the translation files are fine).
Text.DOT = " " .. string.char(183) .. " "
Text.TIMES = string.char(215)

-- The translate function (the game's getText); a test sets its own.
function Text.tr(key, ...)
    return getText(key, ...)
end

-- The vehicle class of a car part (1 standard, 2 heavy-duty, 3 sports), or false. The game names the three alike
-- (CarBattery1..3 are all "car battery") and tells them apart by this, as its mechanics window does. Only the
-- vehicle maintenance items are looked at, each once (it takes an item made from the type).
local classes = {}
local function vehicleClass(fullType)
    local class = classes[fullType]
    if class ~= nil then return class end
    local ok, t = pcall(function()
        local script = getScriptManager():FindItem(fullType)
        if not (script and script:getDisplayCategory() == "VehicleMaintenance") then return 0 end
        return instanceItem(fullType):getMechanicType()
    end)
    class = ok and type(t) == "number" and t > 0 and t or false
    classes[fullType] = class
    return class
end

-- The name of an item type (the game's, with the vehicle class of a car part), for a receipt line.
function Text.itemName(fullType)
    if not fullType then return "?" end
    local ok, name = pcall(getItemNameFromFullType, fullType)
    if not (ok and name and name ~= "") then return tostring(fullType) end
    local class = vehicleClass(fullType)
    if class then name = Text.tr("IGUI_OA_Item_VehicleClass", name, Text.tr("IGUI_VehicleType_" .. class)) end
    return name
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

-- A text { key, args } (args may be such texts) by the translate function.
function Text.trText(text)
    local args = {}
    for i, a in ipairs(text.args or {}) do args[i] = type(a) == "table" and Text.trText(a) or a end
    return Text.tr(text.key, unpack(args))
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

-- The name of a column of the manifest form: the story part's other name from the 4th stage on (the receipt keeps
-- whether it was written in the old form), else the form's own.
function Text.formLabel(receipt, id)
    if receipt.oldForm and OA.Story and OA.Story.OLD_LABELS and OA.Story.OLD_LABELS[id] then
        return Text.tr("IGUI_OA_Story_Form_" .. id)
    end
    return Text.tr("IGUI_OA_Trade_Rc_Label_" .. id)
end

-- A receipt as lines { text, kind } for the manifest paper and its copy in the document folder. kind is "head", "line",
-- "good" (a gift), "bad" (something cut short), "note" or "total".
function Text.receipt(receipt)
    local lines = {}
    local function add(kind, key, ...)
        lines[#lines + 1] = { kind = kind, text = Text.tr(key, ...) }
    end
    local function raw(kind, text)
        lines[#lines + 1] = { kind = kind, text = text }
    end
    if receipt.oldForm then
        add("head", "IGUI_OA_Trade_Rc_HeadOld", Text.formLabel(receipt, "serial"), receipt.id or 0, receipt.day or 0)
    else
        add("head", "IGUI_OA_Trade_Rc_Head", receipt.id or 0, receipt.day or 0)
    end
    if receipt.number then
        add("line", "IGUI_OA_Trade_Rc_Row", Text.formLabel(receipt, "receivers"), string.format("%04d", receipt.number))
    end
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
    if (receipt.fee or 0) > 0 then
        add("bad", "IGUI_OA_Trade_Rc_Fee", math.floor((receipt.feeRate or 0) * 100 + 0.5), Text.credits(receipt.fee))
    elseif receipt.feeReleased then
        add("good", "IGUI_OA_Trade_Rc_FeeReleased")
    end
    -- A filled line names its request group (an older receipt's, an item type: its own name).
    local requestName = OA.Requests and OA.Requests.nameOf or Text.itemName
    for _, fill in ipairs(receipt.filled or {}) do
        add("good", "IGUI_OA_Trade_Rc_Filled", requestName(fill.fullType), Text.credits(fill.trust))
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
    local applied = 0
    for _, s in ipairs(receipt.support or {}) do
        local change = OA.Support and Text.trText(OA.Support.changeText(s.id, s.from, s.to)) or s.id
        if s.paid then
            applied = applied + 1
            add("line", "IGUI_OA_Trade_Rc_Support", change, Text.credits(s.price))
        else
            add("bad", "IGUI_OA_Trade_Rc_SupportWait", change)
        end
    end
    for _, gift in ipairs(receipt.gifts or {}) do
        raw("good", Text.tr("IGUI_OA_Trade_Rc_Gift", Text.itemName(gift.type), gift.count or 1))
    end
    if receipt.bonusNote then add("good", receipt.bonusNote) end
    if applied > 0 then add("note", "IGUI_OA_Trade_Rc_SupportNote", applied) end
    for _, e in ipairs(receipt.events or {}) do
        if e.kind == "stage" then add("good", "IGUI_OA_Trade_Rc_NewItems", e.n or e.stage or 0) end
    end
    if receipt.note and receipt.note.key then
        local a = receipt.note.args or {}
        add("note", "IGUI_OA_Trade_Rc_Row", Text.formLabel(receipt, "remarks"), Text.tr(receipt.note.key, unpack(a)))
    end
    add("total", "IGUI_OA_Trade_Rc_Balance", Text.credits(receipt.balanceBefore), Text.credits(receipt.balance))
    return lines
end

return Text
