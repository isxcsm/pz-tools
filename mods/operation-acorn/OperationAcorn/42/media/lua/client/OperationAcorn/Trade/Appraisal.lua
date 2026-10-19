-- Appraisal: a line on an item's tooltip with what the team would give for it (or why not), and an estimate panel
-- beside the loot window while a delivery box is open. Nothing here changes anything; values come from the economy
-- part and are kept for an item half a second (a tooltip is drawn every frame it is up). The loot window's refresh
-- also sets the box's accept rule again on this side.
require "ISUI/ISToolTipInv"
require "ISUI/ISPanel"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/Estimate"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Trade/Crate"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Objects, Things, Estimate = Trade.Objects, Trade.Things, Trade.Estimate
local Appraisal = {}
Trade.Appraisal = Appraisal

-- Tooltip --------------------------------------------------------------------------------------------------------------

-- Per item, kept Appraisal.KEEP_MS of real time like the other tooltip lines (TipLines): { at (ms), tier, serial, line }.
-- The worth moves with the market (a settlement, a new region), the item's own state (food going stale, condition, a
-- bag filled) and a mission's state, so it is worked out again soon, and at once when the tier or the settlement
-- number changed. Bounded (OA.putTimed): the entries past KEEP_MS go
-- as a new one is put, so what is held is what was hovered lately.
Appraisal.KEEP_MS = 500
local cache = OA.bounded()
Appraisal.cache = cache

-- The line for an item: { text, r, g, b } or nil when the economy part is not there.
function Appraisal.lineFor(item, record)
    local Value = OA.Value
    if not (Value and Value.info and Value.context) then return nil end
    local now = getTimestampMs()
    local trade = record.trade
    local serial = trade and trade.serial or 0
    local tier = OA.Trust and OA.Trust.tier(record) or 0
    local hit = cache.t[item]
    if hit and hit.tier == tier and hit.serial == serial and now >= hit.at and now - hit.at < Appraisal.KEEP_MS then
        return hit.line
    end
    local info = Value.info(item)
    local ok, why = Value.accepts(info)
    local line
    if info.own == "MissionItem" then
        -- (a running mission's item is worth nothing alone: the mission pays for it)
        line = { text = getText("IGUI_OA_Trade_Tip_Mission"), r = 0.6, g = 0.9, b = 0.6 }
    elseif ok then
        local worth = Value.appraise(info, Value.context(record))
        local text = getText("IGUI_OA_Trade_Tip_Worth", Text.credits(OA.round(worth.credits)))
        local words = Text.markText(worth.marks)
        if words then text = text .. "  (" .. words .. ")" end
        line = { text = text, r = 0.6, g = 0.9, b = 0.6 }
    elseif info.own or info.bought or info.cash then
        line = { text = Text.tr(why or "IGUI_OA_Trade_Tip_NotTaken"), r = 0.75, g = 0.7, b = 0.55 }
    else
        line = { text = Text.tr(why or "IGUI_OA_Trade_Tip_NotTaken"), r = 0.9, g = 0.55, b = 0.5 }
    end
    line.width = UI.textWidthPx(line.text, UIFont.Small)
    OA.putTimed(cache, item, { at = now, tier = tier, serial = serial, line = line }, now, Appraisal.KEEP_MS)
    return line
end

-- The tooltip draws the item's own lines through the game; the appraisal is a strip drawn under it (above it when the
-- tooltip is at the bottom of the screen), and says how much room it took (oaAbove, oaBelow) for the lines of ItemTip.
-- The game's functions below are left as they are while the mod is off (OA.off).
if not OA.off then
    local originalRender = ISToolTipInv.render
    function ISToolTipInv:render(...)
        originalRender(self, ...)
        local item = self.item
        if not item or not self:isVisible() then return end
        if ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end
        local record = OA.Client.record(getPlayer())
        -- (no worth before the team is met: the terminal not used yet)
        if not record or not OA.Trust.contacted(record) then return end
        local ok, line = OA.try("appraisal line", Appraisal.lineFor, item, record)
        if not ok or not line then return end
        local font = UIFont.Small
        local h = UI.fontHeightPx(font) + 8
        local w = math.max(self.width, line.width + 16)
        local y = self.height
        if self:getY() + self.height + h > getCore():getScreenHeight() then y = -h end
        -- what the item tooltip's other lines (ItemTip) find taken
        if y < 0 then self.oaAbove = h else self.oaBelow = h end
        self:drawRect(0, y, w, h, self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
        self:drawRectBorder(0, y, w, h, self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
        self:drawText(line.text, 8, y + 4, line.r, line.g, line.b, 1, font)
    end
end

-- The estimate panel ---------------------------------------------------------------------------------------------------

OAEstimatePanel = ISPanel:derive("OAEstimatePanel")
-- The least height (pixels) the panel takes under the box's window when the right side has no room.
OAEstimatePanel.BELOW_MIN = 160
-- Real time between looks for the open box.
OAEstimatePanel.LOOK_MS = 500

function OAEstimatePanel:createChildren()
    local pad = UI.PAD
    self.list = UI.list(self, 0, UI.fontHeightPx() * 2 + pad, self.width, self.height - UI.fontHeightPx() * 2 - pad, OAEstimatePanel.drawRow)
    self.list:setAnchorBottom(true)
end

local REFUSED_COLOR, TAKEN_COLOR = { 0.9, 0.55, 0.5 }, { 0.9, 0.9, 0.9 }

-- A row is { name, value, refused, valueW (the value's width in pixels, measured when the row is made), cut (the name
-- cut to what is left of the width, made at the width cutFor) }: a frame measures nothing.
function OAEstimatePanel.drawRow(list, y, item)
    local row = item.item
    local pad = list.itemPadY
    local c = row.refused and REFUSED_COLOR or TAKEN_COLOR
    local width = list.width
    local textX = width - 16 - row.valueW
    if row.cutFor ~= width then
        row.cut, row.cutFor = UI.fitPx(row.name, textX - 16, list.font), width
    end
    list:drawText(row.cut, 8, y + pad, c[1], c[2], c[3], 1, list.font)
    list:drawText(row.value, textX, y + pad, c[1], c[2], c[3], 1, list.font)
end

-- The row of a name and a value.
local function makeRow(name, value, refused)
    return { name = name, value = value, refused = refused, valueW = UI.textWidthPx(value) }
end

-- The container of the page's pane, when it is an open delivery box: the object, or nil.
local function boxOf(page)
    local pane = page.inventoryPane
    local inventory = pane and pane.inventory
    local object = inventory and inventory:getParent()
    if object and Objects.kindOf(object) == Objects.DELIVERY_BOX and not object:getModData()[Objects.SEALED]
        and not Objects.abandoned(object) then
        return object, inventory
    end
    return nil
end

-- Real time the infos read for the open box are kept (the memo is also dropped at a new day or settlement).
OAEstimatePanel.MEMO_MS = 2000

-- The memo (by item) of what Value.info said of the items of a panel's box (Things.sealable): made again once its
-- day or settlement number has changed or MEMO_MS has passed, so that an item put in or taken out reads only what is
-- new and the others are not read again, yet nothing of an item's state is older than that.
local function infoMemo(panel, record, now)
    local trade = record and record.trade
    local day, serial = OA.day(), trade and trade.serial or 0
    local memo = panel.memo
    if not (memo and memo.day == day and memo.serial == serial and now >= memo.at and now - memo.at < OAEstimatePanel.MEMO_MS) then
        memo = { day = day, serial = serial, at = now, items = {} }
        panel.memo = memo
    end
    return memo.items
end

-- Writes the rows for a container's items.
function OAEstimatePanel:fill(container)
    local record = OA.Client.record(self.character)
    local plan = Things.sealable(container, infoMemo(self, record, getTimestampMs()))
    local entries = Trade.Boxes.group(plan.infos)
    local worth = Estimate.entries(record, entries)
    self.list:clear()
    if worth then
        for i, entry in ipairs(entries) do
            local line = worth.lines[i]
            local value
            if entry.info.own == "MissionItem" then
                value = getText("IGUI_OA_Trade_Tip_Mission")
            else
                value = Text.credits(OA.round(line.credits))
                local marks = Text.markText(line.marks)
                if marks then value = value .. "  " .. marks end
            end
            self.list:addItem(entry.info.fullType, makeRow(Text.itemName(entry.info.fullType) .. " x" .. entry.count, value))
        end
    end
    for i, item in ipairs(plan.refused) do
        self.list:addItem(item:getFullType(),
            makeRow(item:getDisplayName(), Text.tr(plan.refusedWhys[i] or "IGUI_OA_Trade_Tip_NotTaken"), true))
    end
    self.total = worth and getText("IGUI_OA_Trade_Estimate_Total", Text.credits(worth.credits), Text.credits(worth.trust)) or ""
    self.count = #plan.taken
    self.weight = plan.weight
end

-- Shown only while the loot window shows an open box and is not folded to its title bar: beside it on the right; where
-- the screen ends first, under it, or on its left when there is no room under it either. Its folding or closing
-- hides the panel at once; the box is looked for twice a second of real time, the rows redone only when its contents
-- changed.
function OAEstimatePanel:update()
    local page = self.page
    local folded = page.isCollapsed or not page:isVisible()
    if folded and self:isVisible() then
        self:setVisible(false)
        self.signature = nil
    end
    if not OA.due(self.looked, "box", getTimestampMs(), OAEstimatePanel.LOOK_MS) then return end
    local object, container = boxOf(page)
    if not object or folded then
        self:setVisible(false)
        self.signature = nil
        return
    end
    local x, y, h = page:getX() + page:getWidth() + 4, page:getY(), page:getHeight()
    if x + self:getWidth() > getCore():getScreenWidth() then
        -- no room on the right (a narrow screen): under the box's window when there is room, else on its left, where the
        -- player's own inventory window usually is and would cover it
        local below = page:getY() + page:getHeight() + 4
        local room = getCore():getScreenHeight() - below - 4
        if room >= OAEstimatePanel.BELOW_MIN then
            x, y, h = page:getX(), below, math.min(math.max(page:getHeight(), OAEstimatePanel.BELOW_MIN), room)
        else
            x = math.max(0, page:getX() - self:getWidth() - 4)
        end
    end
    self:setX(x)
    self:setY(y)
    self:setHeight(h)
    -- coming up, over the windows it may touch (the box's window overlaps the player's on a narrow screen)
    if not self:isVisible() then self:bringToTop() end
    self:setVisible(true)
    local signature = container:getItems():size() .. "|" .. OA.day() .. "|" .. tostring(container:getContentsWeight())
    if signature ~= self.signature then
        self.signature = signature
        self:fill(container)
    end
end

-- The height of a line of the small font, measured once for each UI era (the fonts change with it).
local lineH = { era = nil, h = 0 }
local function lineHeight()
    if lineH.era ~= UI.era then lineH.era, lineH.h = UI.era, UI.fontHeightPx() end
    return lineH.h
end

function OAEstimatePanel:render()
    ISPanel.render(self)
    self:drawText(UI.str("IGUI_OA_Trade_Estimate_Title"), 8, 4, 1, 1, 1, 1, UIFont.Small)
    self:drawText(self.total or "", 8, 4 + lineHeight(), 0.7, 0.95, 0.7, 1, UIFont.Small)
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
    o.looked = {}
    return o
end

-- One panel for each loot page; a page made at the start of a game may be replaced, so the panel is looked up each time.
local panels = {}

local function onRefresh(page, state)
    if state ~= "buttonsAdded" then return end
    local onCharacter = page.onCharacter
    local character = not onCharacter and getSpecificPlayer(page.player) or nil
    -- One pass over the page's containers: the box's accept rule (the game does not keep it, and this client needs it
    -- for what it drags), and the take-only rule of a supply crate.
    for _, backpack in ipairs(page.backpacks or {}) do
        local container = backpack.inventory
        local object = container and container:getParent()
        local kind = object and Objects.kindOf(object)
        if kind == Objects.DELIVERY_BOX then
            Objects.setupBoxOf(object)
        elseif kind == Objects.CRATE and character then
            Trade.Crate.refresh(character, container, object)
        end
    end
    if onCharacter or not character then return end
    local panel = panels[page]
    if not panel then
        panel = OAEstimatePanel:new(page, character)
        panel:initialise()
        panel:addToUIManager()
        panel:setVisible(false)
        panels[page] = panel
    end
end
OA.on("OnRefreshInventoryWindowContainers", onRefresh)

return Appraisal
