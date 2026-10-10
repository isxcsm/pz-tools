-- Appraisal: a line on an item's tooltip with what the team would give for it (or why not), and an estimate panel
-- beside the loot window while a delivery box is open. Nothing here changes anything; values come from the economy
-- part and are worked out once for an item a day (a tooltip never recomputes). The loot window's refresh also sets
-- the box's accept rule again on this side.
require "ISUI/ISToolTipInv"
require "ISUI/ISPanel"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/Estimate"
require "OperationAcorn/Trade/UI"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Objects, Things, Estimate = Trade.Objects, Trade.Things, Trade.Estimate
local Appraisal = {}
Trade.Appraisal = Appraisal

-- Tooltip --------------------------------------------------------------------------------------------------------------

-- Per item, for one day and one tier: { day, tier, text, color }. Cleared when the day changes.
local cache, cacheDay = {}, nil

-- The line for an item: { text, r, g, b } or nil when the economy part is not there.
function Appraisal.lineFor(item, record)
    local Value = OA.Value
    if not (Value and Value.info and Value.context) then return nil end
    local day = OA.day()
    if day ~= cacheDay then
        cache, cacheDay = {}, day
    end
    local tier = OA.Trust and OA.Trust.tier(record) or 0
    local hit = cache[item]
    if hit and hit.tier == tier then return hit end
    local info = Value.info(item)
    local ok, why = Value.accepts(info)
    local line
    if ok then
        local credits = OA.round(Value.appraise(info, Value.context(record)).credits)
        local marks = Value.appraise(info, Value.context(record)).marks
        local text = getText("IGUI_OA_Trade_Tip_Worth", Text.credits(credits))
        local words = Text.markText(marks)
        if words then text = text .. "  (" .. words .. ")" end
        line = { text = text, r = 0.6, g = 0.9, b = 0.6, tier = tier }
    elseif info.own or info.bought or info.cash then
        line = { text = Text.tr(why or "IGUI_OA_Trade_Tip_NotTaken"), r = 0.75, g = 0.7, b = 0.55, tier = tier }
    else
        line = { text = Text.tr(why or "IGUI_OA_Trade_Tip_NotTaken"), r = 0.9, g = 0.55, b = 0.5, tier = tier }
    end
    cache[item] = line
    return line
end

-- The tooltip draws the item's own lines through the game; the appraisal is a strip drawn under it (above it when the
-- tooltip is at the bottom of the screen), and says how much room it took (oaAbove, oaBelow) for the lines of ItemTip.
local originalRender = ISToolTipInv.render
function ISToolTipInv:render()
    originalRender(self)
    local item = self.item
    if not item or not self:isVisible() then return end
    if ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end
    local record = OA.Client.record(getPlayer())
    if not record then return end
    local ok, line = pcall(Appraisal.lineFor, item, record)
    if not ok or not line then return end
    local font = UIFont.Small
    local h = UI.fontHeight(font) + 8
    local w = math.max(self.width, UI.textWidth(line.text, font) + 16)
    local y = self.height
    if self:getY() + self.height + h > getCore():getScreenHeight() then y = -h end
    -- what the item tooltip's other lines (ItemTip) find taken
    if y < 0 then self.oaAbove = h else self.oaBelow = h end
    self:drawRect(0, y, w, h, self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
    self:drawRectBorder(0, y, w, h, self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    self:drawText(line.text, 8, y + 4, line.r, line.g, line.b, 1, font)
end

-- The estimate panel ---------------------------------------------------------------------------------------------------

OAEstimatePanel = ISPanel:derive("OAEstimatePanel")

function OAEstimatePanel:createChildren()
    local pad = UI.PAD
    self.list = UI.list(self, 0, UI.fontHeight() * 2 + pad, self.width, self.height - UI.fontHeight() * 2 - pad, OAEstimatePanel.drawRow)
    self.list.anchorBottom = true
end

function OAEstimatePanel.drawRow(list, y, item)
    local row = item.item
    local pad = list.itemPadY
    local c = row.refused and { 0.9, 0.55, 0.5 } or { 0.9, 0.9, 0.9 }
    local text = row.value
    local textX = list.width - 16 - UI.textWidth(text)
    list:drawText(UI.fit(row.name, textX - 16, list.font), 8, y + pad, c[1], c[2], c[3], 1, list.font)
    list:drawText(text, textX, y + pad, c[1], c[2], c[3], 1, list.font)
end

-- The container of the page's pane, when it is an open delivery box: the object, or nil.
local function boxOf(page)
    local pane = page.inventoryPane
    local inventory = pane and pane.inventory
    local object = inventory and inventory:getParent()
    if object and Objects.kindOf(object) == Objects.DELIVERY_BOX and not object:getModData()[Objects.SEALED] then
        return object, inventory
    end
    return nil
end

-- Writes the rows for a container's items.
function OAEstimatePanel:fill(container)
    local record = OA.Client.record(self.character)
    local plan = Things.sealable(container)
    local entries = Trade.Boxes.group(plan.infos)
    local worth = Estimate.entries(record, entries)
    self.list:clear()
    if worth then
        for i, entry in ipairs(entries) do
            local line = worth.lines[i]
            local value = Text.credits(OA.round(line.credits))
            local marks = Text.markText(line.marks)
            if marks then value = value .. "  " .. marks end
            self.list:addItem(entry.info.fullType, { name = Text.itemName(entry.info.fullType) .. " x" .. entry.count, value = value })
        end
    end
    for _, item in ipairs(plan.refused) do
        local info = OA.Value.info(item)
        local _, why = OA.Value.accepts(info)
        self.list:addItem(item:getFullType(), { name = item:getDisplayName(), value = Text.tr(why or "IGUI_OA_Trade_Tip_NotTaken"), refused = true })
    end
    self.total = worth and getText("IGUI_OA_Trade_Estimate_Total", Text.credits(worth.credits), Text.credits(worth.trust)) or ""
    self.count = #plan.taken
    self.weight = plan.weight
end

-- Twice a second: shown only while the loot window shows an open box; redone only when its contents changed.
function OAEstimatePanel:update()
    self.ticks = (self.ticks or 0) + 1
    if self.ticks < 30 then return end
    self.ticks = 0
    local page = self.page
    local object, container = boxOf(page)
    if not object or not page:isVisible() then
        self:setVisible(false)
        self.signature = nil
        return
    end
    self:setX(page:getX() + page:getWidth() + 4)
    self:setY(page:getY())
    self:setHeight(page:getHeight())
    self:setVisible(true)
    local signature = container:getItems():size() .. "|" .. OA.day() .. "|" .. tostring(container:getContentsWeight())
    if signature ~= self.signature then
        self.signature = signature
        self:fill(container)
    end
end

function OAEstimatePanel:render()
    ISPanel.render(self)
    self:drawText(getText("IGUI_OA_Trade_Estimate_Title"), 8, 4, 1, 1, 1, 1, UIFont.Small)
    self:drawText(self.total or "", 8, 4 + UI.fontHeight(), 0.7, 0.95, 0.7, 1, UIFont.Small)
end

function OAEstimatePanel:new(page, character)
    local o = ISPanel:new(page:getX() + page:getWidth() + 4, page:getY(), 320, page:getHeight())
    setmetatable(o, self)
    self.__index = self
    o.page = page
    o.character = character
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.7 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.total = ""
    return o
end

-- One panel for each loot page; a page made at the start of a game may be replaced, so the panel is looked up each time.
local panels = {}

local function onRefresh(page, state)
    if state ~= "buttonsAdded" then return end
    -- The box's accept rule: the game does not keep it, and this client needs it for what it drags.
    for _, backpack in ipairs(page.backpacks or {}) do
        local object = backpack.inventory and backpack.inventory:getParent()
        if object and Objects.kindOf(object) == Objects.DELIVERY_BOX then Objects.setupBoxOf(object) end
    end
    if page.onCharacter then return end
    local character = getSpecificPlayer(page.player)
    if not character then return end
    local panel = panels[page]
    if not panel then
        panel = OAEstimatePanel:new(page, character)
        panel:initialise()
        panel:addToUIManager()
        panel:setVisible(false)
        panels[page] = panel
    end
end
Events.OnRefreshInventoryWindowContainers.Add(onRefresh)

return Appraisal
