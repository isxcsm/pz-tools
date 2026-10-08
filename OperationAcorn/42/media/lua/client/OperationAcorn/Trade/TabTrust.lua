-- The terminal's trust tab: the level the team holds the player at, the bar to the next one, what the level gives
-- (the rewards table of the economy part) and what the next level opens in the shop.
require "OperationAcorn/Trade/TerminalWindow"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text

OATabTrust = OATab:derive("OATabTrust")

function OATabTrust:createChildren()
    local pad = UI.PAD
    self.barTop = pad + UI.fontHeight() + 6
    self.barHeight = 18
    self.info = UI.rich(self, pad, self.barTop + self.barHeight + pad * 2 + UI.fontHeight(), self.width - pad * 2,
        self.height - (self.barTop + self.barHeight + pad * 2 + UI.fontHeight()) - pad)
    self.info.anchorRight = true
    self.info.anchorBottom = true
    self.progress = nil
end

-- The names of the items a tier opens, as one text.
local function opens(tier)
    local names = {}
    if OA.Shop and OA.Shop.opensAt then
        for _, entry in ipairs(OA.Shop.opensAt(tier)) do names[#names + 1] = Trade.Orders.nameOf(entry) end
    end
    return table.concat(names, ", ")
end

function OATabTrust:refresh()
    local record = self:record()
    if not record or not OA.Trust then return end
    local rewards = OA.Trust.rewards(record)
    self.label = OA.Trust.label(record)
    self.progress = OA.Trust.progress(record)
    local lines = {}
    local function add(kind, text) lines[#lines + 1] = { kind = kind, text = text } end
    add("head", getText("IGUI_OA_Trade_Trust_Gives"))
    add("line", getText("IGUI_OA_Trade_Trust_Box", rewards.boxCapacity))
    add("line", getText("IGUI_OA_Trade_Trust_Call", rewards.callInterval, rewards.arrival.min, rewards.arrival.max))
    if rewards.nightDrop then add("good", getText("IGUI_OA_Trade_Trust_NightDrop")) end
    if rewards.rate > 0 then add("line", getText("IGUI_OA_Trade_Trust_Rate", math.floor(rewards.rate * 100 + 0.5) .. "%")) end
    add("line", getText("IGUI_OA_Trade_Trust_Requests", rewards.requestCount, math.floor(rewards.requestBonus * 100 + 0.5) .. "%"))
    if rewards.discount > 0 then add("line", getText("IGUI_OA_Trade_Trust_Discount", math.floor(rewards.discount * 100 + 0.5) .. "%")) end
    if rewards.terminalGraph then add("good", getText("IGUI_OA_Trade_Trust_Graph")) end
    if rewards.marketForecast then add("good", getText("IGUI_OA_Trade_Trust_Forecast")) end
    local nextOpens = opens(OA.Trust.tier(record) + 1)
    if nextOpens ~= "" then
        add("head", getText("IGUI_OA_Trade_Trust_Next"))
        add("note", nextOpens)
    end
    UI.setRich(self.info, UI.richLines(lines))
end

function OATabTrust:render()
    ISPanel.render(self)
    local pad = UI.PAD
    if not self.progress then return end
    local p = self.progress
    local x, y, w, h = pad, self.barTop, self.width - pad * 2, self.barHeight
    self:drawText(self.label or "", x, pad, 1, 1, 1, 1, UIFont.Medium)
    self:drawRect(x, y, w, h, 0.4, 0, 0, 0)
    local span = math.max(1, p.to - p.from)
    local fraction = math.max(0, math.min(1, (p.trust - p.from) / span))
    self:drawRect(x + 1, y + 1, (w - 2) * fraction, h - 2, 0.8, 0.45, 0.7, 0.4)
    self:drawRectBorder(x, y, w, h, 0.9, 0.5, 0.5, 0.5)
    local text = getText("IGUI_OA_Trade_Trust_Bar", Text.credits(math.floor(p.trust)), Text.credits(p.to))
    self:drawText(text, x, y + h + 4, 0.85, 0.85, 0.85, 1, UIFont.Small)
end

OA.Terminal.addTab("trust", "IGUI_OA_Trade_Tab_Trust", function(x, y, w, h, window)
    return OATabTrust:new(x, y, w, h, window)
end)
