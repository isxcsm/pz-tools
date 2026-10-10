-- The status tab's helicopter screen: the state of the delivery box, whether a call is on its way or when the next one
-- is possible, the expected balance, and the buttons that call the helicopter or ask for a new delivery box.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/Estimate"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Rules, Boxes, Estimate = Trade.Rules, Trade.Boxes, Trade.Estimate

OATabHeli = OATab:derive("OATabHeli")

function OATabHeli:createChildren()
    local pad = UI.PAD
    local bh = UI.buttonHeight()
    self.info = UI.rich(self, pad, pad, self.width - pad * 2, self.height - bh - pad * 3)
    self.info.anchorRight = true
    self.info.anchorBottom = true
    local by = self.height - bh - pad
    self.callButton = UI.button(self, pad, by, 220, getText("IGUI_OA_Trade_Heli_Call"), self, OATabHeli.onCall)
    self.reissueButton = UI.button(self, pad * 2 + 220, by, 260, getText("IGUI_OA_Trade_Heli_Reissue"), self, OATabHeli.onReissue)
    for _, b in ipairs({ self.callButton, self.reissueButton }) do
        b.anchorTop = false
        b.anchorBottom = true
    end
end

-- A time (world age in hours) as "day 12, 14:30".
local function whenText(hours)
    local day, h, m = Trade.clockText(hours)
    return getText("IGUI_OA_Trade_When", day, string.format("%02d:%02d", h, m))
end

-- The box line: where the active box stands, or why there is none.
local function boxText(record)
    local box = Boxes.active(record)
    if not box then return getText("IGUI_OA_Trade_Heli_NoBox") end
    if box.state == "carried" then return getText("IGUI_OA_Trade_Heli_BoxCarried") end
    if box.state == "sealed" then
        return getText("IGUI_OA_Trade_Heli_BoxSealed", box.x, box.y, box.sealed and box.sealed.count or 0)
    end
    return getText("IGUI_OA_Trade_Heli_BoxPlaced", box.x, box.y)
end

function OATabHeli:state(record)
    local heli = Trade.heli(record)
    local now = OA.hours()
    local call = heli.call
    local canTime, why = Rules.canCall(heli, now)
    local canBox, boxWhy = Boxes.canCall(record)
    return { heli = heli, now = now, call = call, canTime = canTime, why = why, canBox = canBox, boxWhy = boxWhy }
end

function OATabHeli:refresh()
    local record = self:record()
    if not record then return end
    local s = self:state(record)
    local account = Trade.account(record)
    local lines = {}
    local function add(kind, text) lines[#lines + 1] = { kind = kind, text = text } end
    add("head", getText("IGUI_OA_Trade_Heli_Title"))
    add("line", boxText(record))
    if s.call then
        add("good", getText("IGUI_OA_Trade_Heli_OnTheWay", whenText(s.call.arrive)))
    elseif not s.canTime then
        add("line", getText("IGUI_OA_Trade_Heli_Next", whenText(s.heli.next)))
    else
        add("good", getText("IGUI_OA_Trade_Heli_Ready"))
    end
    local flight = Estimate.flight(record)
    add("line", getText("IGUI_OA_Trade_Heli_Estimate", flight.boxes, Text.credits(flight.sealed), Text.credits(flight.bonus)))
    if flight.cart > 0 then
        add(flight.after < 0 and "bad" or "line", getText("IGUI_OA_Trade_Heli_Orders", Text.credits(flight.orders)))
    end
    add(flight.after < 0 and "bad" or "total", getText("IGUI_OA_Trade_Heli_After", Text.credits(flight.before), Text.credits(flight.after)))
    if account.credits < 0 then
        add("bad", getText("IGUI_OA_Trade_Heli_Debt", Text.credits(-account.credits)))
    end
    local marks = s.heli.markers or {}
    if #marks > 0 then
        add("head", getText("IGUI_OA_Trade_Heli_Left"))
        for _, mark in ipairs(marks) do
            add("note", getText(mark.kind == "first" and "IGUI_OA_Trade_Heli_LeftFirst" or "IGUI_OA_Trade_Heli_LeftCrate", mark.x, mark.y))
        end
    end
    UI.setRich(self.info, UI.richLines(lines))
    local callable = not s.call and s.canTime and s.canBox
    self.callButton.enable = callable
    self.callButton.tooltip = (not callable) and self:whyNot(s) or nil
    local lost = not s.canBox and not s.call and s.canTime
    self.reissueButton.enable = lost
    self.reissueButton.tooltip = lost and nil or getText("IGUI_OA_Trade_Heli_ReissueOnly")
end

-- Why a call cannot be made now, as a text.
function OATabHeli:whyNot(s)
    if s.call then return getText("IGUI_OA_Trade_Reason_pending") end
    if not s.canTime then return getText("IGUI_OA_Trade_Reason_" .. tostring(s.why)) end
    return getText("IGUI_OA_Trade_Reason_" .. tostring(s.boxWhy))
end

function OATabHeli:onCall()
    local record = self:record()
    local flight = Estimate.flight(record)
    local text = getText("IGUI_OA_Trade_Heli_ConfirmCall", flight.boxes, Text.credits(flight.sealed), Text.credits(flight.orders),
        Text.credits(flight.after))
    UI.confirm(self:character(), text, self, OATabHeli.doCall)
end

function OATabHeli:doCall()
    self:send("tradeCall", { kind = "normal" })
end

function OATabHeli:onReissue()
    local cost = OA.option("BoxReissueCost") or 10000
    local text = getText("IGUI_OA_Trade_Heli_ConfirmReissue", Text.credits(cost))
    UI.confirm(self:character(), text, self, OATabHeli.doReissue)
end

function OATabHeli:doReissue()
    self:send("tradeCall", { kind = "reissue" })
end

