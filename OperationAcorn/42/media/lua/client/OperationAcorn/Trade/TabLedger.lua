-- The terminal's ledger tab: the receipts of the last thirty days (newest first) with the selected one written out,
-- and the totals of everything before.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/Ledger"
local OA = OperationAcorn
local Trade, UI, Text, Ledger = OA.Trade, OA.Trade.UI, OA.Trade.Text, OA.Trade.Ledger

OATabLedger = OATab:derive("OATabLedger")

function OATabLedger:createChildren()
    local pad = UI.PAD
    local fh = UI.fontHeight()
    local half = math.floor(self.width * 0.36)
    local top = pad + fh + 4
    local bottom = fh * 2 + pad * 2
    UI.label(self, pad, pad, getText("IGUI_OA_Trade_Ledger_List"))
    self.list = UI.list(self, pad, top, half - pad * 1.5, self.height - top - bottom, OATabLedger.drawRow, self, OATabLedger.onSelect)
    self.list.anchorBottom = true
    self.detail = UI.rich(self, half + pad / 2, top, self.width - half - pad * 1.5, self.height - top - bottom)
    self.detail.anchorRight = true
    self.detail.anchorBottom = true
    self.totals = UI.label(self, pad, self.height - bottom + pad / 2, " ")
    self.totals.anchorTop = false
    self.totals.anchorBottom = true
end

function OATabLedger.drawRow(list, y, item)
    local row = item.item
    local pad = list.itemPadY
    list:drawText(row.name, 8, y + pad, 0.92, 0.92, 0.92, 1, list.font)
    local text = (row.credits >= 0 and "+" or "") .. Text.credits(row.credits)
    list:drawText(text, list.width - 20 - UI.textWidth(text), y + pad, 0.7, 0.9, 0.7, 1, list.font)
end

function OATabLedger:onSelect()
    self:showSelected()
end

function OATabLedger:showSelected()
    local row = self.list.items[self.list.selected]
    row = row and row.item
    if not row then
        UI.setRich(self.detail, " <TEXT> <RGB:0.7,0.7,0.7> " .. getText("IGUI_OA_Trade_Ledger_Empty") .. " <LINE> ")
        return
    end
    UI.setRich(self.detail, UI.richLines(Text.receipt(row.receipt)))
end

function OATabLedger:refresh()
    local record = self:record()
    if not record then return end
    local data = Ledger.data(record)
    local selected = self.list.selected
    self.list:clear()
    for i = #data.receipts, 1, -1 do
        local receipt = data.receipts[i]
        self.list:addItem(tostring(receipt.id), {
            receipt = receipt,
            name = getText("IGUI_OA_Trade_Ledger_Row", receipt.id, receipt.day or 0),
            credits = (receipt.credits or 0) + (receipt.bonus or 0) - (receipt.spent or 0),
        })
    end
    if selected and selected <= self.list.count then self.list.selected = selected end
    if self.list.count > 0 and (not self.list.selected or self.list.selected < 1) then self.list.selected = 1 end
    local t = data.totals
    self.totals:setName(getText("IGUI_OA_Trade_Ledger_Totals", t.receipts, Text.credits(t.credits), Text.credits(t.spent),
        Text.credits(t.trust)))
    self:showSelected()
end

OA.Terminal.addTab("ledger", "IGUI_OA_Trade_Tab_Ledger", function(x, y, w, h, window)
    return OATabLedger:new(x, y, w, h, window)
end)
