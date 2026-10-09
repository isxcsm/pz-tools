-- The research plan (DESIGN 8), as a tab of the character info window, beside the game's skills and health: the three
-- trees side by side, each a grid of icon nodes (four columns, five rows opened by the points spent in the tree, the
-- capstone last) with the prerequisite lines between them, and the 2nd board in their place. A node shows its state
-- at a glance: grey while it cannot be taken, a green frame when it can, gold when it is full, cyan for a planned
-- rank, its ranks in the corner. A click plans a rank (a right click takes it back); the plan is only a plan until
-- "research approval" sends it to the server. What a node gives now and next, and what it needs, shows in a tooltip
-- beside it (the mouse) or beside the cursor (a gamepad, which also reaches the buttons). Sizes come from the font,
-- so the game's UI size option works; the tab sizes its window while it shows, as the game's own tabs do.
require "ISUI/ISPanelJoypad"
require "ISUI/ISButton"
require "ISUI/ISToolTip"
require "ISUI/ISModalDialog"
require "ISUI/ISContextMenu"
require "XpSystem/ISUI/ISCharacterInfoWindow"
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Texts"
require "OperationAcorn/Upgrades/Links"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Plan = OA.Upgrades.Plan
local Effects = OA.Upgrades.Effects
local Texts = OA.Upgrades.Texts
local Links = OA.Upgrades.Links
local Window = {}
OA.Upgrades.Window = Window

local GOLD = { 1.00, 0.82, 0.25 }
local GREEN = { 0.35, 0.90, 0.40 }
local CYAN = { 0.30, 1.00, 1.00 }
local GREY = { 0.30, 0.30, 0.32 }
-- Each tree's panel: a dark tint of its icons' colour, and its name's colour.
local TINT = {
    scout = { bg = { 0.04, 0.09, 0.11 }, name = { 0.55, 0.85, 0.95 } },
    load = { bg = { 0.11, 0.07, 0.03 }, name = { 0.98, 0.76, 0.45 } },
    survival = { bg = { 0.05, 0.09, 0.04 }, name = { 0.62, 0.92, 0.55 } },
}

local View = ISPanelJoypad:derive("ISOAResearchView")
ISOAResearchView = View

local views = {}       -- by player number

local function tabName() return getText("IGUI_OA_Tree_TabName") end

function View:new(playerNum)
    local o = ISPanelJoypad.new(self, 0, 0, 100, 100)
    o.playerNum = playerNum
    o.player = getSpecificPlayer(playerNum)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.mode = "trees"
    o.steps, o.counts = {}, {}
    o.fragments, o.fragmentsLeft = 0, 0
    o.revealed = {}
    o.items, o.lines, o.panels = {}, {}, {}
    o:measure()
    o:setWidth(o.wantW)
    o:setHeight(o.wantH)
    return o
end

-- The sizes, from the font.
function View:measure()
    local tm = getTextManager()
    local fh, fm = tm:getFontHeight(UIFont.Small), tm:getFontHeight(UIFont.Medium)
    local pad = math.max(6, math.floor(fh * 0.5))
    local tile = math.max(32, math.floor(fh * 2.3 + 0.5))
    local gapX = math.floor(tile * 0.4)
    -- the gap between rows: room for a line's arrow into the node below (what opens a row is in the tooltip)
    local gapY = math.max(10, math.floor(tile * 0.5))
    self.fh, self.fm, self.pad, self.tile, self.gapX, self.gapY = fh, fm, pad, tile, gapX, gapY
    self.gridW = Data.COLS * tile + (Data.COLS - 1) * gapX + pad * 2
    self.gridH = Data.ROWS * tile + (Data.ROWS - 1) * gapY + pad * 2
    self.headH = fm + fh + pad
    self.barH = fh + 10
    self.btnH = fh + 8
    self.panelY = pad + self.barH + pad
    self.wantW = pad + 3 * self.gridW + 2 * pad + pad
    self.wantH = self.panelY + self.headH + self.gridH + pad + self.btnH + pad
end

function View:createChildren()
    ISPanelJoypad.createChildren(self)
    local fh, pad = self.fh, self.pad
    local function button(title, onClick, w, h)
        local b = ISButton:new(0, 0, w, h, title, self, onClick)
        b:initialise()
        b:instantiate()
        self:addChild(b)
        return b
    end
    local modeW = fh * 9
    self.treesButton = button(getText("IGUI_OA_Tree_ModeTrees"), View.onMode, modeW, self.barH)
    self.treesButton.internal = "trees"
    self.boardButton = button("", View.onMode, modeW, self.barH)
    self.boardButton.internal = "board"
    self.treesButton:setX(pad)
    self.treesButton:setY(pad)
    self.boardButton:setX(pad + modeW + pad)
    self.boardButton:setY(pad)
    local by = self.wantH - pad - self.btnH
    self.approveButton = button(getText("IGUI_OA_Tree_Approve"), View.onApprove, fh * 8, self.btnH)
    self.approveButton:setX(pad)
    self.approveButton:setY(by)
    self.clearButton = button(getText("IGUI_OA_Tree_ClearPlan"), View.onClear, fh * 8, self.btnH)
    self.clearButton:setX(pad + fh * 8 + pad)
    self.clearButton:setY(by)
    -- a reset for each tree, at its panel's top right
    self.resetButtons = {}
    local resetW = getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_OA_Tree_Reset")) + pad * 2
    for i, tree in ipairs(Data.TREES) do
        local b = button(getText("IGUI_OA_Tree_Reset"), View.onReset, resetW, fh + 4)
        b.internal = tree
        b:setX(self:panelX(i) + self.gridW - pad - resetW)
        b:setY(self.panelY + pad)
        self.resetButtons[tree] = b
    end
    self:layout()
end

function View:panelX(i)
    return self.pad + (i - 1) * (self.gridW + self.pad)
end

-- ---- layout ----------------------------------------------------------------------------------------------------

-- Where each node is drawn and the lines between them, for the mode. The buttons are items too, for the gamepad.
function View:layout()
    local tile, gapX, gapY, pad = self.tile, self.gapX, self.gapY, self.pad
    self.items, self.lines, self.panels = {}, {}, {}
    local groups = (self.mode == "board") and Data.BOARD_GROUPS or Data.TREES
    for i, tree in ipairs(groups) do
        local px, py = self:panelX(i), self.panelY
        local gx, gy = px + pad, py + self.headH + pad
        self.panels[#self.panels + 1] = { tree = tree, x = px, y = py, gx = gx, gy = gy }
        local function cellX(c) return gx + (c - 1) * (tile + gapX) end
        local function cellY(r) return gy + (r - 1) * (tile + gapY) end
        if self.mode == "board" then
            for k, node in ipairs(Data.boardGroup(tree)) do
                local c, r = (k - 1) % Data.COLS + 1, math.floor((k - 1) / Data.COLS) + 1
                self.items[#self.items + 1] = { id = node.id, tree = tree, x = cellX(c), y = cellY(r), w = tile, h = tile }
            end
        else
            for _, node in ipairs(Data.treeNodes(tree)) do
                self.items[#self.items + 1] = { id = node.id, tree = tree, x = cellX(node.col), y = cellY(node.row), w = tile, h = tile }
            end
            local function px2(p)
                if p.x == "gutter" then return gx + p.c * (tile + gapX) - math.floor(gapX / 2) - 1 end
                return cellX(p.c) + math.floor(tile / 2) - 1
            end
            local function py2(p)
                if p.y == "top" then return cellY(p.r) end
                if p.y == "bottom" then return cellY(p.r) + tile end
                return cellY(p.r) + tile + math.floor(gapY / 2)
            end
            for _, link in ipairs(Links.tree(tree)) do
                local segs = {}
                for k = 1, #link.points - 1 do
                    local a, b = link.points[k], link.points[k + 1]
                    local x1, y1, x2, y2 = px2(a), py2(a), px2(b), py2(b)
                    segs[#segs + 1] = { x = math.min(x1, x2), y = math.min(y1, y2), w = math.abs(x2 - x1) + 2, h = math.abs(y2 - y1) + 2 }
                end
                local last = link.points[#link.points]
                self.lines[#self.lines + 1] = { need = link.need, segs = segs, tipX = px2(last) + 1, tipY = py2(last) }
            end
        end
    end
    for _, b in ipairs(self:buttons()) do
        self.items[#self.items + 1] = { button = b, x = b.x, y = b.y, w = b.width, h = b.height }
    end
end

-- The buttons the gamepad cursor can reach now.
function View:buttons()
    local list = { self.treesButton, self.boardButton }
    if self.mode == "trees" then
        for _, tree in ipairs(Data.TREES) do
            local b = self.resetButtons[tree]
            if b and b:getIsVisible() then list[#list + 1] = b end
        end
    end
    list[#list + 1] = self.approveButton
    list[#list + 1] = self.clearButton
    return list
end

function View:itemOf(id)
    for _, item in ipairs(self.items) do
        if item.id == id then return item end
    end
    return nil
end

function View:nodeAt(x, y)
    for _, item in ipairs(self.items) do
        if item.id and x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + item.h then return item.id end
    end
    return nil
end

-- ---- state -----------------------------------------------------------------------------------------------------

function View:record()
    return OA.Client.record(self.player)
end

-- Reads the record again and re-simulates the plan on it.
function View:refresh()
    self.player = getSpecificPlayer(self.playerNum) or self.player
    local record = self.player and self:record()
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
    self.tipDirty = true
end

function View:countFragments()
    self.fragments = self.player:getInventory():getCountTypeRecurse(Data.FRAGMENT)
    self.nextCount = getTimestampMs() + 1000
end

function View:updateButtons()
    local sim = self.sim
    if not sim then return end
    local boardTitle = Rules.boardOpen(sim) and Texts.treeName(Data.BOARD)
        or getText("IGUI_OA_Tree_BoardClosedTab", Rules.capstones(sim), #Data.TREES)
    self.boardButton:setTitle(boardTitle)
    for _, b in ipairs({ self.treesButton, self.boardButton }) do
        if b.internal == self.mode then
            b.backgroundColor = { r = 0.12, g = 0.30, b = 0.38, a = 1 }
            b.borderColor = { r = 0.5, g = 0.9, b = 1.0, a = 1 }
        else
            b.backgroundColor = { r = 0, g = 0, b = 0, a = 1 }
            b.borderColor = { r = 0.6, g = 0.6, b = 0.6, a = 1 }
        end
    end
    local hasPlan = #self.steps > 0
    self.approveButton.enable = hasPlan
    self.approveButton.backgroundColor = hasPlan and { r = 0.1, g = 0.35, b = 0.4, a = 1 } or { r = 0.12, g = 0.12, b = 0.13, a = 1 }
    self.clearButton.enable = hasPlan
    for tree, b in pairs(self.resetButtons) do
        local spent = Rules.treeSpent(self.u, tree) > 0
        b:setVisible(self.mode == "trees" and spent)
        b.enable = spent and not hasPlan
    end
    self:layout()
end

function View:onMode(button)
    if self.mode == button.internal then return end
    self.mode = button.internal
    self.hover = nil
    self:updateButtons()
    if self.joypad then self.cursor = (self:firstNode() or {}).id or self.cursor end
    self.tipDirty = true
end

function View:firstNode()
    for _, item in ipairs(self.items) do
        if item.id then return item end
    end
    return nil
end

-- ---- planning --------------------------------------------------------------------------------------------------

function View:plan(id, choice)
    if not self.sim then return end
    local node = Data.byId[id]
    if node.board and node.choose and not choice then
        return self:chooseFamily(id)
    end
    local steps, why = Plan.add(self.u, self.steps, id, choice, self.fragments)
    if not steps then
        self.refusal = { id = id, why = why }
        self.tipDirty = true
        return
    end
    self.refusal = nil
    self.steps = steps
    self:refresh()
end

function View:unplan(id)
    if not self.sim then return end
    self.steps = Plan.remove(self.u, self.steps, id, self.fragments)
    self.refusal = nil
    self:refresh()
end

-- The family weight node asks which family the point is for.
function View:chooseFamily(id)
    local context = ISContextMenu.get(self.playerNum, getMouseX(), getMouseY())
    for _, family in ipairs(Data.FAMILY_ORDER) do
        local n = self.sim.board.family[family] or 0
        local label = Texts.familyName(family)
        if n > 0 then label = label .. " (" .. Texts.number(Rules.familyAmount(self.sim, family) * 100) .. "%)" end
        context:addOption(label, self, View.onFamily, id, family)
    end
    if self.joypad then
        context.origin = self
        setJoypadFocus(self.playerNum, context)
    end
end

function View:onFamily(id, family)
    self:plan(id, family)
end

function View:onApprove()
    if #self.steps == 0 then return end
    OA.Sync.send(self.player, "upgrades.approve", { steps = self.steps })
    self.steps = {}
    self.refusal = nil
    self:refresh()
end

function View:onClear()
    self.steps = {}
    self.refusal = nil
    self:refresh()
end

function View:onReset(button)
    local tree = button.internal
    if not self.u then return end
    local cost = Rules.resetCost(self.u, tree)
    local credits = (OA.Store.section(self:record(), "trade").credits) or 0
    local text = getText("IGUI_OA_Tree_ResetConfirm", Texts.treeName(tree), cost, credits)
    local modal = ISModalDialog:new(0, 0, 360, 190, text, true, self, View.onResetAnswer, self.playerNum, tree)
    modal:initialise()
    modal:addToUIManager()
    modal:setX(self:getAbsoluteX() + (self.width - modal.width) / 2)
    modal:setY(self:getAbsoluteY() + (self.height - modal.height) / 2)
    if self.joypad then setJoypadFocus(self.playerNum, modal) end
end

function View:onResetAnswer(button, tree)
    if button.internal == "YES" then
        OA.Sync.send(self.player, "upgrades.reset", { tree = tree })
    end
    if self.joypad then setJoypadFocus(self.playerNum, self) end
end

-- ---- the tooltip -----------------------------------------------------------------------------------------------

local function rgb(r, g, b)
    return string.format("<RGB:%.2f,%.2f,%.2f> ", r, g, b)
end

local function line(text, r, g, b)
    return rgb(r, g, b) .. text .. " <LINE> "
end

-- A node's name and what the tooltip says of it (rich text).
function View:tipFor(id)
    local sim = self.sim
    local node = Data.byId[id]
    if node.board and not Rules.boardOpen(sim) then
        local name = self.revealed[node.group] and Texts.nodeName(id) or "???"
        return name, line(getText("IGUI_OA_Tree_BoardHidden", Rules.capstones(sim), #Data.TREES), 0.8, 0.8, 0.85)
    end
    -- as the talent tooltips of other games read: the rank, what it does now (or what the first rank will do), where
    -- it does not apply, what the next rank does, what it still needs; the research team's line last, on capstones
    local rank = Rules.rank(sim, id)
    local planned = self.counts[id] or 0
    local maxed = Rules.maxed(sim, id)
    local stage
    if node.board then
        stage = getText("IGUI_OA_Tree_StageBoard", rank, Rules.cost(sim, id))
    else
        stage = getText("IGUI_OA_Tree_Stage", rank, node.ranks)
    end
    if planned > 0 then stage = stage .. " " .. getText("IGUI_OA_Tree_StagePlanned", planned) end
    local text = line(stage, 0.7, 0.7, 0.72)
    local nextLine
    if not maxed then
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
    end
    local now = Texts.rankLine(node, rank, sim)
    if now then
        text = text .. line(now, 1, 1, 1)
    elseif nextLine then
        text = text .. line(nextLine, 1, 1, 1)
    end
    local desc = Texts.desc(id)
    if desc then text = text .. line(desc, 0.7, 0.7, 0.72) end
    if not maxed then
        if now and nextLine then text = text .. line(getText("IGUI_OA_Tree_Next") .. ": " .. nextLine, 0.55, 0.85, 0.55) end
        -- only what is still missing, in red (a met condition is only noise)
        for _, c in ipairs(Texts.conditions(sim, node, { fragments = self.fragmentsLeft })) do
            if not c.ok then text = text .. line(c.text, 1.0, 0.45, 0.4) end
        end
    end
    local note = Texts.note(id)
    if note then text = text .. line(note, 0.85, 0.78, 0.55) end
    local api = Texts.apiNote(id)
    if api and node.kind == "api" then text = text .. line(api, 1.0, 0.6, 0.3) end
    if self.refusal and self.refusal.id == id then
        text = text .. line(Texts.reason(self.refusal.why), 1.0, 0.4, 0.4)
    end
    return Texts.nodeName(id), text
end

-- The node the tooltip is about: the one under the mouse, or the gamepad cursor's.
function View:focusId()
    if self.hover then return self.hover end
    if self.joypad and self.cursor and self:itemOf(self.cursor) then return self.cursor end
    return nil
end

function View:hideTip()
    if self.tip and self.tipShown then
        self.tip:setVisible(false)
        self.tip:removeFromUIManager()
        self.tipShown = false
    end
    self.tipId = nil
end

-- Shows the tooltip beside the focused node: on its right, or on its left where the screen ends.
function View:updateTip()
    local id = self:focusId()
    if not id or not self.sim then return self:hideTip() end
    if not self.tip then
        self.tip = ISToolTip:new()
        self.tip:initialise()
        self.tip.followMouse = false
        self.tip.maxLineWidth = self.fh * 22
        self.tip.backgroundColor = { r = 0.02, g = 0.02, b = 0.03, a = 0.95 }
        self.tip:setOwner(self)
    end
    local tip = self.tip
    if id ~= self.tipId or self.tipDirty then
        local name, text = self:tipFor(id)
        tip:setName(name)
        tip.description = text
        self.tipId, self.tipDirty = id, false
    end
    -- (a new ISToolTip says it is visible before it is in the UI manager: keep track of that here)
    if not self.tipShown then
        tip:setVisible(true)
        tip:addToUIManager()
        self.tipShown = true
    end
    tip:bringToTop()
    local item = self:itemOf(id)
    local ax, ay = self:getAbsoluteX() + item.x, self:getAbsoluteY() + item.y
    local x = ax + item.w + self.pad
    if x + tip.width > getCore():getScreenWidth() then x = ax - self.pad - tip.width end
    local y = math.max(0, math.min(ay, getCore():getScreenHeight() - tip.height))
    tip:setDesiredPosition(x, y)
end

-- ---- drawing ---------------------------------------------------------------------------------------------------

function View:prerender()
    -- the tab sizes its window while it shows, as the game's own tabs do (another tab may have sized it last)
    local parent = self.parent
    if self.width ~= self.wantW or (parent and parent.width ~= self.x + self.wantW) then
        self:setWidthAndParentWidth(self.wantW)
    end
    if self.height ~= self.wantH or (parent and parent.height ~= self.y + self.wantH) then
        self:setHeightAndParentHeight(self.wantH)
    end
    ISPanelJoypad.prerender(self)
    -- the game draws the children (the buttons) after prerender and before render: what lies under a button is here
    if not self.sim then return end
    self:drawBadges()
    for _, panel in ipairs(self.panels) do self:drawPanel(panel) end
end

local function drawBorder(self, x, y, w, h, t, c, a)
    self:drawRect(x, y, w, t, a, c[1], c[2], c[3])
    self:drawRect(x, y + h - t, w, t, a, c[1], c[2], c[3])
    self:drawRect(x, y, t, h, a, c[1], c[2], c[3])
    self:drawRect(x + w - t, y, t, h, a, c[1], c[2], c[3])
end

-- A badge at the right of the top bar: its text in a frame, right-aligned at x; returns the x left of it.
function View:badge(text, right, color)
    local w = getTextManager():MeasureStringX(UIFont.Small, text) + self.pad * 2
    local x, y, h = right - w, self.pad, self.barH
    self:drawRect(x, y, w, h, 0.9, 0.08, 0.08, 0.10)
    self:drawRectBorder(x, y, w, h, 0.9, 0.40, 0.40, 0.45)
    self:drawTextCentre(text, x + w / 2, y + (h - self.fh) / 2, color[1], color[2], color[3], 1, UIFont.Small)
    return x - self.pad
end

function View:drawBadges()
    local sim = self.sim
    local right = self.width - self.pad
    local spent = Plan.spent(self.u, sim)
    local planned = spent.board
    for _, tree in ipairs(Data.TREES) do planned = planned + spent[tree] end
    if planned > 0 then right = self:badge(getText("IGUI_OA_Tree_BadgePlan", planned), right, CYAN) end
    right = self:badge(getText("IGUI_OA_Tree_BadgeFragments", self.fragmentsLeft), right, { 0.85, 0.80, 0.95 })
    right = self:badge(getText("IGUI_OA_Tree_BadgeShared", Rules.sharedPool(sim)), right, { 0.95, 0.95, 0.95 })
    if self.mode == "board" and Rules.boardOpen(sim) then
        self:badge(getText("IGUI_OA_Tree_BadgeBoard", Rules.boardLeft(sim)), right, GOLD)
    end
end

-- One node: its icon (grey while it cannot be taken), a frame for its state, its ranks in the corner.
function View:drawNode(item)
    local sim, tile, fh = self.sim, self.tile, self.fh
    local node = Data.byId[item.id]
    local x, y = item.x, item.y
    local boardClosed = node.board and not Rules.boardOpen(sim)
    local treeLocked = (not node.board) and not Rules.treeOpen(self.u, node.tree)
    local rank = Rules.rank(sim, node.id)
    local planned = self.counts[node.id] or 0
    local why = nil
    if not boardClosed then why = Rules.blocked(sim, node.id, { fragments = self.fragmentsLeft }, "A") end
    local grey = boardClosed or treeLocked or (why ~= nil and rank == 0)
    local maxed = (not node.board) and node.ranks and rank >= node.ranks
    self:drawRect(x, y, tile, tile, 1, 0.02, 0.02, 0.03)
    local hidden = boardClosed and not self.revealed[node.group]
    if not hidden then
        local tex = getTexture((grey and node.iconGray) or node.icon)
        if tex then self:drawTextureScaledAspect(tex, x + 2, y + 2, tile - 4, tile - 4, grey and 0.8 or 1, 1, 1, 1) end
    else
        self:drawTextCentre("?", x + tile / 2, y + (tile - fh) / 2, 0.4, 0.4, 0.42, 1, UIFont.Small)
    end
    local frame, width = GREY, 1
    if planned > 0 then
        frame, width = CYAN, 2
    elseif maxed then
        frame, width = GOLD, 2
    elseif rank > 0 or not grey then
        frame, width = GREEN, 2
    end
    drawBorder(self, x, y, tile, tile, width, frame, 1)
    if node.capstone then drawBorder(self, x - 3, y - 3, tile + 6, tile + 6, 1, grey and GREY or GOLD, 0.9) end
    -- the ranks: held/most (planned in cyan), or the rank alone on the endless board
    if not hidden and not treeLocked then
        local text = node.board and tostring(rank) or (rank .. "/" .. node.ranks)
        local w = getTextManager():MeasureStringX(UIFont.Small, text) + 4
        local bx, byy = x + tile - w + 2, y + tile - fh + 2
        self:drawRect(bx, byy, w, fh, 0.9, 0, 0, 0)
        local c = (planned > 0 and CYAN) or (maxed and GOLD) or (rank > 0 and GREEN) or { 0.75, 0.75, 0.75 }
        self:drawText(text, bx + 2, byy, c[1], c[2], c[3], 1, UIFont.Small)
    end
    -- a node that does nothing without the API says so in its corner
    if node.kind == "api" and Effects.status(node.id) ~= "ok" and not treeLocked and not hidden then
        self:drawRect(x + 1, y + 1, fh, fh, 0.9, 0.35, 0.15, 0.05)
        self:drawTextCentre("!", x + 1 + fh / 2, y + 1, 1, 0.7, 0.3, 1, UIFont.Small)
    end
    local focus = (self.hover == node.id) or (self.joypad and self.cursor == node.id)
    if focus then drawBorder(self, x - 1, y - 1, tile + 2, tile + 2, 1, { 1, 1, 1 }, 1) end
end

function View:drawPanel(panel)
    local sim, pad = self.sim, self.pad
    local tree = panel.tree
    local tint = TINT[tree]
    local h = self.headH + self.gridH
    self:drawRect(panel.x, panel.y, self.gridW, h, 1, tint.bg[1], tint.bg[2], tint.bg[3])
    self:drawRectBorder(panel.x, panel.y, self.gridW, h, 0.9, 0.32, 0.32, 0.35)
    -- the name, and what is spent in it (as the trees of other games show it), then the points left; on the board a
    -- panel is the board's nodes of that tree
    local title = Texts.treeName(tree)
    if self.mode == "trees" then title = title .. " (" .. Rules.treeSpent(sim, tree) .. ")" end
    self:drawText(title, panel.x + pad, panel.y + pad / 2, tint.name[1], tint.name[2], tint.name[3], 1, UIFont.Medium)
    if self.mode == "trees" then
        -- what the tree can still take; its points beyond that only the 2nd board can use, so they are told apart
        local usable, surplus = Rules.ownSplit(sim, tree)
        local left = surplus > 0 and getText("IGUI_OA_Tree_OwnLeftBoard", usable, surplus)
            or getText("IGUI_OA_Tree_OwnLeft", usable)
        self:drawText(left, panel.x + pad, panel.y + pad / 2 + self.fm, 0.75, 0.75, 0.78, 1, UIFont.Small)
    end
end

function View:render()
    ISPanelJoypad.render(self)
    if not self.sim then
        self:drawTextCentre(getText("IGUI_OA_Tree_NoRecord"), self.width / 2, self.height / 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
        return
    end
    -- the prerequisite lines, gold where the rank they need is held, with a tip into the node
    for _, l in ipairs(self.lines) do
        local ok = Rules.rank(self.sim, l.need[1]) >= l.need[2]
        local c, a = ok and GOLD or GREY, ok and 0.95 or 0.9
        for _, s in ipairs(l.segs) do self:drawRect(s.x, s.y, s.w, s.h, a, c[1], c[2], c[3]) end
        self:drawRect(l.tipX - 4, l.tipY - 4, 8, 2, a, c[1], c[2], c[3])
        self:drawRect(l.tipX - 2, l.tipY - 2, 4, 2, a, c[1], c[2], c[3])
    end
    for _, item in ipairs(self.items) do
        if item.id then self:drawNode(item) end
    end
    -- a tree not opened yet: dark, with why
    if self.mode == "trees" then
        for _, panel in ipairs(self.panels) do
            if not Rules.treeOpen(self.u, panel.tree) then
                local gy = panel.y + self.headH
                self:drawRect(panel.x, gy, self.gridW, self.gridH, 0.6, 0, 0, 0)
                local text = getText("IGUI_OA_Tree_TreeClosed")
                local wrapped = getTextManager():WrapText(UIFont.Small, text, self.gridW - self.pad * 2)
                self:drawTextCentre(wrapped, panel.x + self.gridW / 2, gy + self.gridH / 2 - self.fh, 1, 0.9, 0.5, 1, UIFont.Small)
            end
        end
    end
    -- the gamepad cursor on a button
    if self.joypad and self.cursor and type(self.cursor) == "table" then
        local b = self.cursor
        drawBorder(self, b.x - 2, b.y - 2, b.width + 4, b.height + 4, 2, { 1, 1, 1 }, 1)
    end
    local hint = getText(self.joypad and "IGUI_OA_Tree_PadHint" or "IGUI_OA_Tree_Hint")
    local hx = self.clearButton.x + self.clearButton.width + self.pad * 2
    self:drawText(hint, hx, self.approveButton.y + (self.btnH - self.fh) / 2, 0.6, 0.6, 0.65, 1, UIFont.Small)
    self:updateTip()
end

function View:update()
    ISPanelJoypad.update(self)
    if self.nextCount and getTimestampMs() >= self.nextCount and self.player then
        local before = self.fragments
        self:countFragments()
        if before ~= self.fragments then self:refresh() end
    end
end

function View:setVisible(visible, joypadData)
    ISPanelJoypad.setVisible(self, visible, joypadData)
    if visible then self:refresh() else self:hideTip() end
end

-- ---- mouse -----------------------------------------------------------------------------------------------------

function View:onMouseMove(dx, dy)
    ISPanelJoypad.onMouseMove(self, dx, dy)
    self.hover = self:nodeAt(self:getMouseX(), self:getMouseY())
end

function View:onMouseMoveOutside(dx, dy)
    ISPanelJoypad.onMouseMoveOutside(self, dx, dy)
    self.hover = nil
end

function View:onMouseUp(x, y)
    local id = self:nodeAt(x, y)
    if id then self:plan(id) end
    return true
end

function View:onRightMouseUp(x, y)
    local id = self:nodeAt(x, y)
    if id then self:unplan(id) end
    return true
end

-- ---- gamepad ---------------------------------------------------------------------------------------------------

function View:onGainJoypadFocus(joypadData)
    ISPanelJoypad.onGainJoypadFocus(self, joypadData)
    self.joypad = true
    if not self.cursor then self.cursor = (self:firstNode() or {}).id end
    self.tipDirty = true
end

function View:onLoseJoypadFocus(joypadData)
    ISPanelJoypad.onLoseJoypadFocus(self, joypadData)
    self.joypad = false
    self:hideTip()
end

-- The cursor is a node id, or a button.
local function cursorItem(self)
    if type(self.cursor) == "table" then
        for _, item in ipairs(self.items) do
            if item.button == self.cursor then return item end
        end
        return nil
    end
    return self:itemOf(self.cursor)
end

-- The nearest item (a node or a button) in a direction from the cursor: dx, dy are -1, 0 or 1.
function View:step(dx, dy)
    local from = cursorItem(self)
    if not from then
        self.cursor = (self:firstNode() or {}).id
        return
    end
    local fx, fy = from.x + from.w / 2, from.y + from.h / 2
    local best, bestScore = nil, nil
    for _, item in ipairs(self.items) do
        if item ~= from and (item.id or item.button:getIsVisible()) then
            local rx, ry = item.x + item.w / 2 - fx, item.y + item.h / 2 - fy
            local along = rx * dx + ry * dy
            if along > 1 then
                local across = math.abs(rx * dy) + math.abs(ry * dx)
                local score = along + across * 2
                if not bestScore or score < bestScore then best, bestScore = item, score end
            end
        end
    end
    if best then
        self.cursor = best.id or best.button
        self.tipDirty = true
    end
end

function View:onJoypadDirLeft(joypadData) self:step(-1, 0) end
function View:onJoypadDirRight(joypadData) self:step(1, 0) end
function View:onJoypadDirUp(joypadData) self:step(0, -1) end
function View:onJoypadDirDown(joypadData) self:step(0, 1) end

function View:onJoypadDown(button, joypadData)
    if button == Joypad.AButton then
        if type(self.cursor) == "table" then
            self.cursor:forceClick()
        elseif self.cursor then
            self:plan(self.cursor)
        end
    elseif button == Joypad.XButton then
        if self.cursor and type(self.cursor) ~= "table" then self:unplan(self.cursor) end
    elseif button == Joypad.YButton then
        self:onApprove()
    elseif button == Joypad.BButton then
        local info = getPlayerInfoPanel(self.playerNum)
        if info then info:toggleView(tabName()) end
        setJoypadFocus(self.playerNum, nil)
    elseif button == Joypad.LBumper or button == Joypad.RBumper then
        local info = getPlayerInfoPanel(self.playerNum)
        if info then info:onJoypadDown(button) end
    end
end

-- ---- the tab in the character info window ----------------------------------------------------------------------

-- Adds the tab to each character info window as the game makes it (once a player).
local baseCreate = ISCharacterInfoWindow.createChildren
function ISCharacterInfoWindow:createChildren()
    baseCreate(self)
    local ok, err = pcall(function()
        local view = View:new(self.playerNum)
        view:initialise()
        self.panel:addView(tabName(), view)
        views[self.playerNum] = view
        -- the game restores the window's layout while making it, before this tab is there (see RestoreLayout)
        if self.oaResearchOpen then self.panel:activateView(tabName()) end
    end)
    if not ok then OA.log("research tab failed:", tostring(err)) end
end

-- The game remembers which of its own tabs was open when the game was left; this remembers the research tab too.
local baseSave = ISCharacterInfoWindow.SaveLayout
function ISCharacterInfoWindow:SaveLayout(name, layout)
    baseSave(self, name, layout)
    local view = views[self.playerNum]
    layout.oaResearch = (view and view.parent == self.panel and self.panel:getActiveView() == view) and "true" or nil
end

local baseRestore = ISCharacterInfoWindow.RestoreLayout
function ISCharacterInfoWindow:RestoreLayout(name, layout)
    baseRestore(self, name, layout)
    self.oaResearchOpen = layout.oaResearch == "true"
end

-- Shows the research tab of a local player's character info window (the first player when not named), or hides it
-- when it shows. Returns the tab when it shows.
function Window.open(playerNum)
    playerNum = playerNum or 0
    local info = getPlayerInfoPanel(playerNum)
    local view = views[playerNum]
    if not info or not view then return nil end
    local shown
    if view.parent == info.panel then
        info:toggleView(tabName())
        shown = info:getIsVisible() and info.panel:getActiveView() == view
    elseif view.parent then
        -- torn off into a window of its own
        local window = view.parent
        shown = not window:getIsVisible()
        window:setVisible(shown)
        if shown then
            window:addToUIManager()
            window:bringToTop()
        end
    end
    -- (not isReallyVisible: a window added outside the UI's own update joins the UI manager only on the next frame)
    if not shown then return nil end
    view:refresh()
    if getJoypadData(playerNum) then setJoypadFocus(playerNum, view) end
    return view
end

-- The research tab of a player, shown or not.
function Window.view(playerNum)
    return views[playerNum or 0]
end

OA.Upgrades.open = Window.open

-- The record changed (an approval, a reset, a serum): the tabs read it again.
local function onChanged()
    for _, view in pairs(views) do
        if view:getIsVisible() then view:refresh() end
    end
end
OA.Sync.listen("upgrades", onChanged)
OA.Sync.listen("trade", onChanged)
OA.Sync.listen("all", onChanged)

return Window
