-- The research plan: the tree screen (DESIGN 8). A tab for each of the three trees and the 2nd board; a grid of nodes
-- with the links between them, locked capstones in sight; a click plans a rank (a right click takes it back), and the
-- plan is only a plan until "research approval" sends it to the server. The detail pane under the grid tells what the
-- node under the mouse (or the cursor, with a gamepad) gives now and at its next rank, and exactly what it needs.
-- Sizes come from the font, so the game's UI size option works; a gamepad moves a cursor over the nodes.
require "ISUI/ISCollapsableWindowJoypad"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISRichTextPanel"
require "ISUI/ISModalDialog"
require "ISUI/ISContextMenu"
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Texts"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Plan = OA.Upgrades.Plan
local Effects = OA.Upgrades.Effects
local Texts = OA.Upgrades.Texts
local Window = {}
OA.Upgrades.Window = Window

local TABS = { "scout", "load", "survival", "board" }
local COLORS = {
    locked = { bg = { 0.09, 0.09, 0.10 }, border = { 0.30, 0.30, 0.32 }, text = { 0.45, 0.45, 0.47 } },
    open = { bg = { 0.10, 0.15, 0.20 }, border = { 0.45, 0.75, 1.00 }, text = { 0.95, 0.95, 0.95 } },
    done = { bg = { 0.12, 0.25, 0.15 }, border = { 0.40, 0.85, 0.45 }, text = { 0.95, 1.00, 0.95 } },
    plan = { bg = { 0.08, 0.22, 0.26 }, border = { 0.30, 1.00, 1.00 }, text = { 1.00, 1.00, 1.00 } },
    gold = { bg = { 0.22, 0.18, 0.06 }, border = { 1.00, 0.82, 0.25 }, text = { 1.00, 0.95, 0.75 } },
}

-- ---- the grid --------------------------------------------------------------------------------------------------

local Grid = ISPanel:derive("ISOAResearchGrid")
ISOAResearchGrid = Grid

function Grid:new(x, y, w, h, window)
    local o = ISPanel.new(self, x, y, w, h)
    o.window = window
    o.backgroundColor = { r = 0.03, g = 0.03, b = 0.04, a = 0.95 }
    o.borderColor = { r = 0.35, g = 0.35, b = 0.38, a = 1 }
    o.rects = {}
    o.scrollY = 0
    o.contentH = 0
    return o
end

-- Where each node of the current tab is drawn, and the lines between them. Called when the tab or the size changes.
function Grid:layout()
    local win = self.window
    local fh, pad = win.fh, win.pad
    self.rects, self.lines, self.rowLabels = {}, {}, {}
    local tab = win.tab
    local cardW, cardH = win.cardW, win.cardH
    local gutter = win.gutter
    if tab == Data.BOARD then
        local x0 = pad
        local colW = math.max(cardW, math.floor((self.width - pad * 2 - (#Data.BOARD_GROUPS - 1) * pad) / #Data.BOARD_GROUPS))
        local maxRows = 0
        for c, group in ipairs(Data.BOARD_GROUPS) do
            local x = x0 + (c - 1) * (colW + pad)
            self.rowLabels[#self.rowLabels + 1] = { x = x, y = pad, text = Texts.treeName(group), w = colW }
            for _, node in ipairs(Data.boardGroup(group)) do
                local y = pad + fh + pad + (node.row - 1) * (cardH + pad)
                self.rects[#self.rects + 1] = { id = node.id, x = x, y = y, w = colW, h = cardH }
                maxRows = math.max(maxRows, node.row)
            end
        end
        self.contentH = pad + fh + pad + maxRows * (cardH + pad)
    else
        local gapX = math.floor((self.width - gutter - pad - 5 * cardW) / 4)
        gapX = math.max(gapX, pad)
        local gapY = pad * 2
        self.gapY = gapY
        local byId = {}
        for _, node in ipairs(Data.treeNodes(tab)) do
            local x = gutter + (node.col - 1) * (cardW + gapX)
            local y = pad + (node.row - 1) * (cardH + gapY)
            local rect = { id = node.id, x = x, y = y, w = cardW, h = cardH }
            self.rects[#self.rects + 1] = rect
            byId[node.id] = rect
        end
        for _, node in ipairs(Data.treeNodes(tab)) do
            for _, req in ipairs(node.req) do
                self.lines[#self.lines + 1] = { from = byId[req[1]], to = byId[node.id], id = node.id, need = req }
            end
        end
        for row = 1, Data.ROWS do
            local need = Rules.rowNeed(row)
            local text
            if row == Data.ROWS then
                text = getText("IGUI_OA_Tree_RowCapstone", need)
            elseif need == 0 then
                text = getText("IGUI_OA_Tree_RowFirst")
            else
                text = getText("IGUI_OA_Tree_RowNeed", need)
            end
            self.rowLabels[#self.rowLabels + 1] = { x = pad, y = pad + (row - 1) * (cardH + gapY), text = text, row = row }
        end
        self.contentH = pad + Data.ROWS * (cardH + gapY)
    end
    self.scrollY = math.max(0, math.min(self.scrollY, self.contentH - self.height))
end

function Grid:rectOf(id)
    for _, r in ipairs(self.rects) do
        if r.id == id then return r end
    end
    return nil
end

function Grid:nodeAt(x, y)
    y = y + self.scrollY
    for _, r in ipairs(self.rects) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return r.id end
    end
    return nil
end

-- Scrolls so that the node is in view (for the gamepad cursor).
function Grid:reveal(id)
    local r = self:rectOf(id)
    if not r then return end
    if r.y < self.scrollY then self.scrollY = r.y - self.window.pad end
    if r.y + r.h > self.scrollY + self.height then self.scrollY = r.y + r.h - self.height + self.window.pad end
    self.scrollY = math.max(0, math.min(self.scrollY, math.max(0, self.contentH - self.height)))
end

function Grid:onMouseWheel(delta)
    self.scrollY = math.max(0, math.min(self.scrollY + delta * self.window.fh * 2, math.max(0, self.contentH - self.height)))
    return true
end

function Grid:onMouseMove(dx, dy)
    self.window.hover = self:nodeAt(self:getMouseX(), self:getMouseY())
end

function Grid:onMouseMoveOutside(dx, dy)
    self.window.hover = nil
end

function Grid:onMouseUp(x, y)
    local id = self:nodeAt(x, y)
    if id then self.window:plan(id) end
    return true
end

function Grid:onRightMouseUp(x, y)
    local id = self:nodeAt(x, y)
    if id then self.window:unplan(id) end
    return true
end

local function setColor(list, a)
    return a, list[1], list[2], list[3]
end

-- A pip row: filled for the ranks held, cyan for the ranks planned, hollow for the rest.
local function drawPips(grid, x, y, size, have, planned, total, color)
    local gap = math.max(2, math.floor(size / 3))
    local width = total * size + (total - 1) * gap
    local px = x - math.floor(width / 2)
    for i = 1, total do
        local rx = px + (i - 1) * (size + gap)
        if i <= have then
            grid:drawRect(rx, y, size, size, 1, color[1], color[2], color[3])
        elseif i <= have + planned then
            grid:drawRect(rx, y, size, size, 1, 0.3, 1.0, 1.0)
        else
            grid:drawRectBorder(rx, y, size, size, 0.8, 0.5, 0.5, 0.5)
        end
    end
end

function Grid:render()
    local win = self.window
    local fh, pad = win.fh, win.pad
    local sim, u = win.sim, win.u
    if not sim then return end
    self:setStencilRect(0, 0, self.width, self.height)
    local sy = -self.scrollY
    local locked = (win.tab ~= Data.BOARD) and not Rules.treeOpen(u, win.tab)
    local boardClosed = (win.tab == Data.BOARD) and not Rules.boardOpen(sim)
    local counts = win.counts

    for _, label in ipairs(self.rowLabels) do
        if label.row then
            local met = Rules.treeSpent(sim, win.tab) >= Rules.rowNeed(label.row)
            local c = met and 0.7 or 0.45
            self:drawText(label.text, label.x, label.y + sy + 2, c, c, c, 1, UIFont.Small)
        else
            self:drawTextCentre(label.text, label.x + label.w / 2, label.y + sy, 0.9, 0.9, 0.9, 1, UIFont.Small)
        end
    end

    -- a prerequisite: down from the bottom of the node it needs, across in the gap under that row, down into the
    -- node (rects, 2 px: the vanilla drawLine2 is a skewed quad that shows as stray dashes on a straight line)
    for _, line in ipairs(self.lines) do
        local have = Rules.rank(sim, line.need[1])
        local ok = have >= line.need[2]
        local a, r, g, b = 0.8, 0.35, 0.35, 0.38
        if ok then a, r, g, b = 0.9, 0.4, 0.85, 0.45 end
        local f, t = line.from, line.to
        local x1, y1 = math.floor(f.x + f.w / 2) - 1, f.y + f.h + sy
        local x2, y2 = math.floor(t.x + t.w / 2) - 1, t.y + sy
        if x1 == x2 then
            self:drawRect(x1, y1, 2, y2 - y1, a, r, g, b)
        else
            local ym = y1 + math.floor((self.gapY or win.pad) / 2)
            self:drawRect(x1, y1, 2, ym - y1, a, r, g, b)
            self:drawRect(math.min(x1, x2), ym, math.abs(x2 - x1) + 2, 2, a, r, g, b)
            self:drawRect(x2, ym, 2, y2 - ym, a, r, g, b)
        end
    end

    for _, rect in ipairs(self.rects) do
        local node = Data.byId[rect.id]
        local ry = rect.y + sy
        if ry + rect.h >= 0 and ry <= self.height then
            local rank = Rules.rank(sim, node.id)
            local planned = counts[node.id] or 0
            local have = rank - planned
            local why = nil
            if not boardClosed then why = Rules.blocked(sim, node.id, { fragments = win.fragmentsLeft }, "A") end
            local scheme = COLORS.locked
            if boardClosed then
                scheme = COLORS.locked
            elseif node.board then
                scheme = (why == nil) and COLORS.open or COLORS.locked
                if rank > 0 then scheme = COLORS.done end
            elseif node.ranks and rank >= node.ranks then
                scheme = COLORS.done
            elseif why == nil or (rank > 0) then
                scheme = COLORS.open
            end
            if node.capstone and not locked and (why == nil or rank > 0) then scheme = COLORS.gold end
            if planned > 0 then scheme = COLORS.plan end
            if locked then scheme = COLORS.locked end
            self:drawRect(rect.x, ry, rect.w, rect.h, 0.95, scheme.bg[1], scheme.bg[2], scheme.bg[3])
            local focus = (win.hover == node.id) or (win.cursor == node.id and win.joypad)
            local br = scheme.border
            if focus then br = { 1, 1, 1 } end
            self:drawRectBorder(rect.x, ry, rect.w, rect.h, 1, br[1], br[2], br[3])
            if node.capstone then
                self:drawRectBorder(rect.x + 2, ry + 2, rect.w - 4, rect.h - 4, 0.6, br[1], br[2], br[3])
            end
            local t = scheme.text
            -- the name, cut to the card; a board card that is still closed shows only the outline
            local name
            if boardClosed then
                local revealed = win.revealed[node.group]
                name = revealed and Texts.nodeName(node.id) or "???"
                t = revealed and { 0.55, 0.55, 0.58 } or { 0.35, 0.35, 0.38 }
            else
                name = Texts.nodeName(node.id)
            end
            local icon = win.iconSize
            local showIcon = node.icon and not (boardClosed and not win.revealed[node.group])
            local textX, room = rect.x + rect.w / 2, rect.w - 6
            if showIcon then
                local tex = getTexture(node.icon)
                if tex then
                    local dim = locked or (why ~= nil and rank == 0 and planned == 0)
                    self:drawTextureScaledAspect(tex, rect.x + 4, ry + 4, icon, icon, dim and 0.45 or 1, 1, 1, 1)
                end
                textX = rect.x + icon + 8 + (rect.w - icon - 12) / 2
                room = rect.w - icon - 12
            end
            while #name > 1 and getTextManager():MeasureStringX(UIFont.Small, name) > room do
                name = string.sub(name, 1, #name - 1)
            end
            self:drawTextCentre(name, textX, ry + 3, t[1], t[2], t[3], 1, UIFont.Small)
            if not boardClosed then
                if node.board then
                    local label = getText("IGUI_OA_Tree_BoardRank", rank, Rules.cost(sim, node.id))
                    self:drawTextCentre(label, textX, ry + 3 + fh, t[1], t[2], t[3], 1, UIFont.Small)
                else
                    local size = math.max(4, math.floor(fh * 0.5))
                    drawPips(self, textX, ry + 3 + fh + 2, size, have, planned, node.ranks, t)
                end
                -- the node does nothing without the API
                if node.kind == "api" and Effects.status(node.id) ~= "ok" and not locked then
                    self:drawText("PZ", rect.x + rect.w - 2 - getTextManager():MeasureStringX(UIFont.Small, "PZ"), ry + 1,
                        1, 0.5, 0.25, 0.9, UIFont.Small)
                end
            end
        end
    end

    -- more below or above: a thin bar on the right shows where the view is (the wheel scrolls)
    if self.contentH > self.height then
        local track = self.height - 4
        local thumb = math.max(win.fh, math.floor(track * self.height / self.contentH))
        local at = math.floor((track - thumb) * self.scrollY / (self.contentH - self.height))
        self:drawRect(self.width - 5, 2, 3, track, 0.5, 0.2, 0.2, 0.22)
        self:drawRect(self.width - 5, 2 + at, 3, thumb, 0.9, 0.6, 0.6, 0.65)
    end

    if locked then
        self:drawRect(0, 0, self.width, self.height, 0.55, 0, 0, 0)
        local text = getText("IGUI_OA_Tree_TreeClosed", Texts.treeName(win.tab))
        self:drawTextCentre(text, self.width / 2, self.height / 2 - win.fh / 2, 1, 0.9, 0.5, 1, UIFont.Small)
    end
    self:clearStencilRect()
end

-- ---- the window ------------------------------------------------------------------------------------------------

local Research = ISCollapsableWindowJoypad:derive("ISOAResearch")
ISOAResearch = Research

local current = nil

function Research:new(playerNum)
    local fh = getTextManager():getFontHeight(UIFont.Small)
    local pad = math.max(6, math.floor(fh * 0.5))
    local cardH = fh * 2 + 8
    local iconSize = cardH - 8
    -- the card is as wide as the longest name needs
    local cardW = fh * 6
    for _, node in ipairs(Data.nodes) do
        cardW = math.max(cardW, getTextManager():MeasureStringX(UIFont.Small, Texts.nodeName(node.id)) + pad + iconSize + 8)
    end
    local gutter = 0
    for row = 1, Data.ROWS do
        local need = Rules.rowNeed(row)
        local text = row == Data.ROWS and getText("IGUI_OA_Tree_RowCapstone", need)
            or (need == 0 and getText("IGUI_OA_Tree_RowFirst") or getText("IGUI_OA_Tree_RowNeed", need))
        gutter = math.max(gutter, getTextManager():MeasureStringX(UIFont.Small, text))
    end
    gutter = gutter + pad * 2
    local gridW = gutter + 5 * cardW + 4 * pad + pad
    local width = math.max(gridW + pad * 2, fh * 40)
    local screenH = getCore():getScreenHeight()
    local height = math.min(screenH - fh * 3, fh * 36)
    local x = math.max(0, math.floor((getCore():getScreenWidth() - width) / 2))
    local y = math.max(0, math.floor((screenH - height) / 2))
    local o = ISCollapsableWindowJoypad.new(self, x, y, width, height)
    o.playerNum = playerNum
    o.player = getSpecificPlayer(playerNum)
    o.fh, o.pad, o.cardW, o.cardH, o.gutter, o.iconSize = fh, pad, cardW, cardH, gutter, iconSize
    o.resizable = true
    o.minimumWidth = gridW + pad * 2
    o.minimumHeight = fh * 24
    o.tab = "scout"
    o.steps = {}
    o.counts = {}
    o.fragments = 0
    o.fragmentsLeft = 0
    o.revealed = {}
    o:setTitle(getText("IGUI_OA_Tree_Title"))
    return o
end

function Research:createChildren()
    ISCollapsableWindowJoypad.createChildren(self)
    local fh, pad = self.fh, self.pad
    local top = self:titleBarHeight() + pad
    self.tabButtons = {}
    for _, tab in ipairs(TABS) do
        local b = ISButton:new(pad, top, fh * 8, fh + 6, "", self, Research.onTab)
        b.internal = tab
        b:initialise()
        b:instantiate()
        self:addChild(b)
        self.tabButtons[#self.tabButtons + 1] = b
    end
    self.pointsY = top + fh + 6 + pad
    self.grid = Grid:new(pad, self.pointsY + fh + pad, self.width - pad * 2, 100, self)
    self.grid:initialise()
    self.grid:instantiate()
    self:addChild(self.grid)
    self.detail = ISRichTextPanel:new(pad, 0, self.width - pad * 2, fh * 9)
    self.detail:initialise()
    self.detail:instantiate()
    self.detail.defaultFont = UIFont.Small
    self.detail.autosetheight = false
    self.detail.clip = true
    self.detail:setMargins(pad, pad, pad, pad)
    self.detail.backgroundColor = { r = 0.04, g = 0.04, b = 0.05, a = 0.95 }
    self.detail.borderColor = { r = 0.35, g = 0.35, b = 0.38, a = 1 }
    self:addChild(self.detail)
    self.approveButton = ISButton:new(pad, 0, fh * 8, fh + 8, getText("IGUI_OA_Tree_Approve"), self, Research.onApprove)
    self.clearButton = ISButton:new(pad, 0, fh * 8, fh + 8, getText("IGUI_OA_Tree_ClearPlan"), self, Research.onClear)
    self.resetButton = ISButton:new(pad, 0, fh * 8, fh + 8, getText("IGUI_OA_Tree_Reset"), self, Research.onReset)
    for _, b in ipairs({ self.approveButton, self.clearButton, self.resetButton }) do
        b:initialise()
        b:instantiate()
        self:addChild(b)
    end
    self.approveButton.backgroundColor = { r = 0.1, g = 0.35, b = 0.4, a = 1 }
    self:arrange()
end

-- Places the children by the window's size.
function Research:arrange()
    local fh, pad = self.fh, self.pad
    local top = self:titleBarHeight() + pad
    local x = pad
    local tabW = math.floor((self.width - pad * 2 - pad * (#TABS - 1)) / #TABS)
    for _, b in ipairs(self.tabButtons) do
        b:setX(x)
        b:setY(top)
        b:setWidth(tabW)
        x = x + tabW + pad
    end
    local footerH = fh + 8 + pad
    local detailH = fh * 9
    local gridY = self.pointsY + fh + pad
    local gridH = self.height - gridY - detailH - footerH - pad * 3
    if gridH < fh * 6 then
        detailH = math.max(fh * 4, detailH - (fh * 6 - gridH))
        gridH = self.height - gridY - detailH - footerH - pad * 3
    end
    gridH = math.max(gridH, fh * 6)
    self.grid:setY(gridY)
    self.grid:setWidth(self.width - pad * 2)
    self.grid:setHeight(gridH)
    self.detail:setY(gridY + gridH + pad)
    self.detail:setWidth(self.width - pad * 2)
    self.detail:setHeight(detailH)
    self.detail.textDirty = true
    local by = self.height - footerH - pad + 4
    self.approveButton:setY(by)
    self.approveButton:setX(pad)
    self.clearButton:setY(by)
    self.clearButton:setX(pad + self.approveButton.width + pad)
    self.resetButton:setY(by)
    self.resetButton:setX(self.width - pad - self.resetButton.width - self:resizeWidgetHeight())
    self.grid:layout()
end

function Research:onResize()
    ISCollapsableWindowJoypad.onResize(self)
    if self.grid then self:arrange() end
end

-- ---- state -----------------------------------------------------------------------------------------------------

function Research:record()
    return OA.Client.record(self.player)
end

-- Reads the record again and re-simulates the plan on it.
function Research:refresh()
    local record = self:record()
    if not record then return end
    self.u = Rules.section(record)
    self:countFragments()
    local sim, kept, used = Plan.simulate(self.u, self.steps, self.fragments)
    self.sim, self.steps = sim, kept
    self.counts = Plan.counts(kept)
    self.fragmentsLeft = self.fragments - used
    self.revealed = {}
    for _, tree in ipairs(Data.TREES) do
        local cap = Data.capstone(tree)
        if cap and Rules.rank(sim, cap.id) >= 1 then self.revealed[tree] = true end
    end
    self:updateButtons()
    self:updateDetail()
end

function Research:countFragments()
    self.fragments = self.player:getInventory():getCountTypeRecurse(Data.FRAGMENT)
    self.nextCount = getTimestampMs() + 1000
end

function Research:updateButtons()
    local sim = self.sim
    for _, b in ipairs(self.tabButtons) do
        local tab = b.internal
        local title
        if tab == Data.BOARD then
            if Rules.boardOpen(sim) then
                title = Texts.treeName(tab)
            else
                title = getText("IGUI_OA_Tree_BoardClosedTab", Rules.capstones(sim), #Data.TREES)
            end
        else
            title = Texts.treeName(tab)
        end
        b:setTitle(title)
        if tab == self.tab then
            b.backgroundColor = { r = 0.12, g = 0.30, b = 0.38, a = 1 }
            b.borderColor = { r = 0.5, g = 0.9, b = 1.0, a = 1 }
        else
            b.backgroundColor = { r = 0, g = 0, b = 0, a = 1 }
            b.borderColor = { r = 0.7, g = 0.7, b = 0.7, a = 1 }
        end
    end
    local hasPlan = #self.steps > 0
    self.approveButton.enable = hasPlan
    self.clearButton.enable = hasPlan
    local canReset = false
    if self.tab ~= Data.BOARD then
        canReset = Rules.treeSpent(self.u, self.tab) > 0
    end
    self.resetButton:setVisible(self.tab ~= Data.BOARD)
    self.resetButton.enable = canReset and #self.steps == 0
end

function Research:setTab(tab)
    if self.tab == tab then return end
    self.tab = tab
    self.grid.scrollY = 0
    self.grid:layout()
    self.cursor = nil
    self:moveCursor(nil)
    self:updateButtons()
    self:updateDetail()
end

function Research:onTab(button)
    self:setTab(button.internal)
end

-- ---- planning --------------------------------------------------------------------------------------------------

function Research:plan(id, choice)
    if not self.sim then return end
    local node = Data.byId[id]
    if node.board and node.choose and not choice then
        return self:chooseFamily(id)
    end
    local steps, why = Plan.add(self.u, self.steps, id, choice, self.fragments)
    if not steps then
        self.refusal = { id = id, why = why }
        self:updateDetail()
        return
    end
    self.refusal = nil
    self.steps = steps
    self:refresh()
end

function Research:unplan(id)
    if not self.sim then return end
    self.steps = Plan.remove(self.u, self.steps, id, self.fragments)
    self.refusal = nil
    self:refresh()
end

-- The family weight node asks which family the point is for.
function Research:chooseFamily(id)
    local context = ISContextMenu.get(self.playerNum, getMouseX(), getMouseY())
    for _, family in ipairs(Data.FAMILY_ORDER) do
        local n = self.sim.board.family[family] or 0
        local label = Texts.familyName(family)
        if n > 0 then label = label .. " (" .. Texts.number(Rules.familyAmount(self.sim, family) * 100) .. "%)" end
        context:addOption(label, self, Research.onFamily, id, family)
    end
    if self.joypad then
        context.origin = self
        setJoypadFocus(self.playerNum, context)
    end
end

function Research:onFamily(id, family)
    self:plan(id, family)
end

function Research:onApprove()
    if #self.steps == 0 then return end
    OA.Sync.send(self.player, "upgrades.approve", { steps = self.steps })
    self.steps = {}
    self.refusal = nil
    self:refresh()
end

function Research:onClear()
    self.steps = {}
    self.refusal = nil
    self:refresh()
end

function Research:onReset()
    local tree = self.tab
    if tree == Data.BOARD or not self.u then return end
    local cost = Rules.resetCost(self.u, tree)
    local credits = (OA.Store.section(self:record(), "trade").credits) or 0
    local text = getText("IGUI_OA_Tree_ResetConfirm", Texts.treeName(tree), cost, credits)
    local modal = ISModalDialog:new(0, 0, 360, 190, text, true, self, Research.onResetAnswer, self.playerNum, tree)
    modal:initialise()
    modal:addToUIManager()
    modal:setX(self.x + (self.width - modal.width) / 2)
    modal:setY(self.y + (self.height - modal.height) / 2)
    if self.joypad then setJoypadFocus(self.playerNum, modal) end
end

function Research:onResetAnswer(button, tree)
    if button.internal == "YES" then
        OA.Sync.send(self.player, "upgrades.reset", { tree = tree })
    end
    if self.joypad then setJoypadFocus(self.playerNum, self) end
end

-- ---- the detail pane -------------------------------------------------------------------------------------------

local function rgb(r, g, b)
    return string.format("<RGB:%.2f,%.2f,%.2f> ", r, g, b)
end

local function line(text, r, g, b)
    return rgb(r, g, b) .. text .. " <LINE> "
end

function Research:updateDetail()
    if not self.detail or not self.sim then return end
    local id = self.hover or (self.joypad and self.cursor) or self.cursor
    local text = ""
    local sim = self.sim
    if self.tab == Data.BOARD and not Rules.boardOpen(sim) then
        text = line(getText("IGUI_OA_Tree_BoardHidden", Rules.capstones(sim), #Data.TREES), 0.8, 0.8, 0.85)
        self.detail.text = text
        self.detail:paginate()
        return
    end
    if not id then
        self.detail.text = line(getText("IGUI_OA_Tree_Hint"), 0.7, 0.7, 0.75)
        self.detail:paginate()
        return
    end
    local node = Data.byId[id]
    local rank = Rules.rank(sim, id)
    local planned = self.counts[id] or 0
    text = text .. line(Texts.nodeName(id), 1.0, 0.95, 0.6)
    text = text .. line(Texts.note(id), 0.6, 0.6, 0.65)
    text = text .. line(Texts.desc(id), 0.85, 0.85, 0.85)
    local rankText = node.ranks and (" " .. rank .. "/" .. node.ranks) or (" " .. rank)
    text = text .. line(getText("IGUI_OA_Tree_Current") .. rankText .. (planned > 0 and (" (+" .. planned .. ")") or ""), 1, 1, 1)
    text = text .. line(Texts.rankLine(node, rank, sim), 0.9, 0.95, 1.0)
    if not Rules.maxed(sim, id) then
        local nextLine
        if node.board and node.choose then
            nextLine = getText("IGUI_OA_Tree_NextFamily")
        else
            -- the next rank as it would read: on a copy of the plan that takes it
            local after = Plan.add(self.u, self.steps, id, node.choose and "A" or nil, self.fragments)
            if after then
                local simAfter = Plan.simulate(self.u, after, self.fragments)
                nextLine = Texts.rankLine(node, Rules.rank(simAfter, id), simAfter)
            else
                nextLine = Texts.rankLine(node, math.min(rank + 1, node.ranks or rank + 1), sim)
            end
        end
        text = text .. line(getText("IGUI_OA_Tree_Next") .. ": " .. nextLine, 0.7, 1.0, 0.8)
        for _, c in ipairs(Texts.conditions(sim, node, { fragments = self.fragmentsLeft })) do
            if c.ok then
                text = text .. line(c.text, 0.55, 0.85, 0.55)
            else
                text = text .. line(c.text, 1.0, 0.45, 0.4)
            end
        end
    else
        text = text .. line(getText("IGUI_OA_Tree_Maxed"), 0.55, 0.85, 0.55)
    end
    local api = Texts.apiNote(id)
    if api and node.kind == "api" then text = text .. line(api, 1.0, 0.6, 0.3) end
    if self.refusal and self.refusal.id == id then
        text = text .. line(Texts.reason(self.refusal.why), 1.0, 0.4, 0.4)
    end
    self.detail.text = text
    self.detail:paginate()
end

-- ---- drawing the window's own parts ----------------------------------------------------------------------------

function Research:pointsText()
    local sim = self.sim
    if not sim then return "" end
    local spent = Plan.spent(self.u, sim)
    if self.tab == Data.BOARD then
        local trees = 0
        for _, tree in ipairs(Data.TREES) do trees = trees + Rules.ownPool(sim, tree) end
        return getText("IGUI_OA_Tree_PointsBoard", Rules.boardLeft(sim), trees, Rules.sharedPool(sim), spent.board)
    end
    return getText("IGUI_OA_Tree_PointsTree", Rules.ownPool(sim, self.tab), Rules.sharedPool(sim), self.fragmentsLeft,
        spent[self.tab])
end

function Research:render()
    ISCollapsableWindowJoypad.render(self)
    if not self.sim then return end
    self:drawText(self:pointsText(), self.pad, self.pointsY, 0.9, 0.9, 0.9, 1, UIFont.Small)
    if self.joypad then
        local fh = self.fh
        local y = self.height - fh - self.pad
        local hint = getText("IGUI_OA_Tree_PadHint")
        local w = getTextManager():MeasureStringX(UIFont.Small, hint)
        self:drawText(hint, self.approveButton.x + self.approveButton.width + self.clearButton.width + self.pad * 3, y,
            0.8, 0.8, 0.8, 1, UIFont.Small)
    end
end

function Research:update()
    ISCollapsableWindowJoypad.update(self)
    if self.nextCount and getTimestampMs() >= self.nextCount then
        local before = self.fragments
        self:countFragments()
        if before ~= self.fragments then self:refresh() end
    end
end

-- ---- gamepad ---------------------------------------------------------------------------------------------------

function Research:onGainJoypadFocus(joypadData)
    ISCollapsableWindowJoypad.onGainJoypadFocus(self, joypadData)
    self.joypad = true
    self:moveCursor(self.cursor)
    self:updateDetail()
end

function Research:onLoseJoypadFocus(joypadData)
    ISCollapsableWindowJoypad.onLoseJoypadFocus(self, joypadData)
end

-- Puts the cursor on a node (the first one when none is named), and shows it.
function Research:moveCursor(id)
    if not self.grid then return end
    if not id or not self.grid:rectOf(id) then
        local first = self.grid.rects[1]
        id = first and first.id or nil
    end
    self.cursor = id
    if id then self.grid:reveal(id) end
    self:updateDetail()
end

-- The nearest node in a direction from the cursor: dx, dy are -1, 0 or 1.
function Research:step(dx, dy)
    local from = self.grid:rectOf(self.cursor)
    if not from then return self:moveCursor(nil) end
    local fx, fy = from.x + from.w / 2, from.y + from.h / 2
    local best, bestScore = nil, nil
    for _, r in ipairs(self.grid.rects) do
        if r.id ~= self.cursor then
            local rx, ry = r.x + r.w / 2 - fx, r.y + r.h / 2 - fy
            local along = rx * dx + ry * dy
            if along > 1 then
                local across = math.abs(rx * dy) + math.abs(ry * dx)
                local score = along + across * 2
                if not bestScore or score < bestScore then best, bestScore = r.id, score end
            end
        end
    end
    if best then self:moveCursor(best) end
end

function Research:onJoypadDirLeft(joypadData) self:step(-1, 0) end
function Research:onJoypadDirRight(joypadData) self:step(1, 0) end
function Research:onJoypadDirUp(joypadData) self:step(0, -1) end
function Research:onJoypadDirDown(joypadData) self:step(0, 1) end

function Research:onJoypadDown(button, joypadData)
    if button == Joypad.AButton then
        if self.cursor then self:plan(self.cursor) end
    elseif button == Joypad.XButton then
        if self.cursor then self:unplan(self.cursor) end
    elseif button == Joypad.YButton then
        self:onApprove()
    elseif button == Joypad.BButton then
        self:close()
    elseif button == Joypad.LBumper or button == Joypad.RBumper then
        local index = 1
        for i, tab in ipairs(TABS) do if tab == self.tab then index = i end end
        index = index + (button == Joypad.RBumper and 1 or -1)
        if index < 1 then index = #TABS elseif index > #TABS then index = 1 end
        self:setTab(TABS[index])
    end
end

-- ---- opening and closing ---------------------------------------------------------------------------------------

function Research:close()
    if self.joypad then setJoypadFocus(self.playerNum, nil) end
    self:setVisible(false)
    self:removeFromUIManager()
    if current == self then current = nil end
end

-- Opens the research plan for a local player (the first one when not named); a second call closes it.
function Window.open(playerNum)
    playerNum = playerNum or 0
    if current then
        local was = current
        was:close()
        if was.playerNum == playerNum then return nil end
    end
    local player = getSpecificPlayer(playerNum)
    if not player then return nil end
    local window = Research:new(playerNum)
    window:initialise()
    window:instantiate()
    window:addToUIManager()
    window:setVisible(true)
    window:bringToTop()
    current = window
    window:refresh()
    window:moveCursor(nil)
    if getJoypadData(playerNum) then
        window.joypad = true
        setJoypadFocus(playerNum, window)
    end
    return window
end

function Window.current()
    return current
end

OA.Upgrades.open = Window.open

-- The record changed (an approval, a reset, a serum): the open window reads it again.
local function onChanged()
    if current then current:refresh() end
end
OA.Sync.listen("upgrades", onChanged)
OA.Sync.listen("trade", onChanged)
OA.Sync.listen("all", onChanged)

return Window
