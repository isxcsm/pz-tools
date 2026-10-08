-- The terminal's radio log tab: what the team said, newest first, each line with the greeting of the trust stage it
-- was said at. The log is kept in the record by the server (Trade.radio).
require "OperationAcorn/Trade/TerminalWindow"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text

OATabRadio = OATab:derive("OATabRadio")

function OATabRadio:createChildren()
    local pad = UI.PAD
    self.log = UI.rich(self, pad, pad, self.width - pad * 2, self.height - pad * 2)
    self.log.anchorRight = true
    self.log.anchorBottom = true
end

function OATabRadio:refresh()
    local record = self:record()
    if not record then return end
    local log = OA.Store.section(record, "radio")
    local lines = {}
    if #log == 0 then
        lines[1] = { kind = "line", text = getText("IGUI_OA_Trade_Radio_Silent") }
    end
    for i = #log, 1, -1 do
        local entry = log[i]
        local day, h, m = Trade.clockText(entry.at or 0)
        lines[#lines + 1] = { kind = "note", text = getText("IGUI_OA_Trade_Radio_Stamp", day, string.format("%02d:%02d", h, m)) }
        lines[#lines + 1] = { kind = "line", text = Text.radio(entry) }
    end
    UI.setRich(self.log, UI.richLines(lines))
end

OA.Terminal.addTab("radio", "IGUI_OA_Trade_Tab_Radio", function(x, y, w, h, window)
    return OATabRadio:new(x, y, w, h, window)
end)
