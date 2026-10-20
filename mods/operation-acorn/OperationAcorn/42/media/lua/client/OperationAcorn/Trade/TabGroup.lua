-- A terminal tab of a few screens under a row of sub-tabs (DESIGN-terminal 1.1): the comms' and the
-- record's. Each screen is a view of its own, made the first time it is shown, under the row (and under the tab's own
-- head, a strip some tabs draw above the row: `def.head`). The tab on show tells the screen on show: the window asks
-- which (window:subOn), and the window's calls for a tab (refresh, consoleOver, onTabLeave, onWindowClose) reach it.
-- A screen left for another counts as the tab left (a call playing stops).
--
-- `def`:
--   subs = { { id = "calls", make = function(x, y, w, h, window) -> view }, ... } in the row's order;
--   label(id) -> text; items(group, record, item): the item's lock, badge and dot set for the row (the record changed);
--   head = { h = height, refresh = function(group, record), draw = function(group) }: a strip over the row;
--   first(group, record) -> id: the screen the tab opens on (each time it is chosen), else the first;
--   made(group): after the row and the first screen are made (a board laid over them).
require "OperationAcorn/Trade/TerminalWindow"
require "PZUIKit/Tape"
local OA = OperationAcorn
local Tape = PZUIKit.Tape

OATabGroup = OATab:derive("OATabGroup")

-- The room between the row and the screens.
OATabGroup.GAP = 8

-- `id`: the tab's (OA.Terminal.ORDER).
function OATabGroup:new(x, y, width, height, window, id, def)
    local o = OATab.new(self, x, y, width, height, window)
    o.tabId, o.def = id, def
    return o
end

-- Makes the factory of the tab `id` for OA.Terminal.addTab.
function OATabGroup.factory(id, def)
    return function(x, y, w, h, window) return OATabGroup:new(x, y, w, h, window, id, def) end
end

function OATabGroup:headH()
    return self.def.head and self.def.head.h or 0
end

function OATabGroup:createChildren()
    local def = self.def
    local headH = self:headH()
    self.subTabs = PZUISubTabs:new(0, headH > 0 and headH + 6 or 0, self.width, self:palette(), self,
        OATabGroup.onSub)
    self.subTabs:initialise()
    self.subTabs:setAnchorRight(true)
    self:addChild(self.subTabs)
    self.subViews = {}
    local record = self:record()
    self.sub = def.first and record and def.first(self, record) or def.subs[1].id
    self:showSub(self.sub)
    if def.made then def.made(self) end
end

local function subDef(self, id)
    for _, sub in ipairs(self.def.subs) do
        if sub.id == id then return sub end
    end
    return nil
end

-- A screen of the tab, made the first time it is asked for (hidden until shown).
function OATabGroup:subView(id)
    local view = self.subViews[id]
    if view then return view end
    local sub = subDef(self, id)
    if not sub then return nil end
    local y = self.subTabs.y + self.subTabs.height + OATabGroup.GAP
    view = sub.make(0, y, self.width, self.height - y, self.window)
    if not view.javaObject then
        view:initialise()
        view:instantiate()
    end
    view:setAnchorRight(true)
    view:setAnchorBottom(true)
    view:setVisible(false)
    self:addChild(view)
    -- (a board laid over the tab stays over the screens made after it)
    if self.board then self.board:bringToTop() end
    self.subViews[id] = view
    return view
end

-- Puts a screen on show; the one left hears of it (onTabLeave).
function OATabGroup:showSub(id)
    local leaving = self.sub ~= id and self.subViews[self.sub]
    if leaving and leaving.onTabLeave then leaving:onTabLeave() end
    for sid, view in pairs(self.subViews) do view:setVisible(sid == id) end
    self.sub = id
    self:subView(id):setVisible(true)
end

-- A sub-tab clicked: its screen comes up (OATerminalWindow:reveal) and the window redraws (the dots follow what is on
-- show, and what the screen shows is seen).
function OATabGroup.onSub(self, id)
    if id == self.sub then return end
    self:showSub(id)
    self.window:reveal(self.subViews[id])
    self.window:refresh()
end

-- Opens the tab on one of its screens (the window's links: a document, a call).
function OATabGroup:open(id)
    self.window:activate(self.tabId)
    if self.sub ~= id then
        self:showSub(id)
        self.window:reveal(self.subViews[id])
    end
    self.window:refresh()
    return self.subViews[id]
end

function OATabGroup:refresh()
    local record = self:record()
    if not record then return end
    local def = self.def
    local items = {}
    for _, sub in ipairs(def.subs) do
        local item = { id = sub.id, label = def.label(sub.id) }
        if def.items then def.items(self, record, item) end
        items[#items + 1] = item
    end
    self.subTabs:setItems(items, self.sub)
    if def.head then def.head.refresh(self, record) end
    local view = self.subViews[self.sub]
    if view and view.refresh then view:refresh() end
    if self.board and self.board.refresh then self.board:refresh() end
end

-- The tab chosen again: it opens on the screen its rule says (a call waiting: the calls).
function OATabGroup:onTabShow()
    local def = self.def
    local record = self:record()
    local id = def.first and record and def.first(self, record)
    if id and id ~= self.sub then self:showSub(id) end
end

function OATabGroup:onTabLeave()
    local view = self.subViews[self.sub]
    if view and view.onTabLeave then view:onTabLeave() end
end

function OATabGroup:consoleOver()
    if self.board and self.board.consoleOver then self.board:consoleOver() end
    local view = self.subViews[self.sub]
    if view and view.consoleOver then view:consoleOver() end
end

function OATabGroup:onWindowClose()
    for _, view in pairs(self.subViews) do
        if view.onWindowClose then view:onWindowClose() end
    end
end

-- The head strip, kept on a tape (PZUIKit.Tape) until its refresh makes self.headLines anew.
local function drawHead(self)
    self.def.head.draw(self)
end

function OATabGroup:prerender()
    if self.def.head and self.headLines then Tape.keep(self, drawHead, nil, self.headLines) end
end

return OATabGroup
