-- The missions tab's document folder (DESIGN-terminal 6.4): a list of what the record keeps, in groups with the newest
-- on top, and the document open beside it inside the terminal's own window (no window of its own to hide behind the
-- terminal). Choosing a row reads it: the text on the right, 'previous' and 'next' step through the list, and what was
-- new stops being new (the server is told). The list is built when the record changes; the frames only draw it.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Story/Button"
require "OperationAcorn/Story/Folder"
require "OperationAcorn/Story/TypedText"
local OA = OperationAcorn
local UI = OA.Trade.UI
local Folder, Typing, Markup = OA.StoryFolder, OA.Typing, OA.Markup

OATabFolder = OATab:derive("OATabFolder")

OATabFolder.ROW_H = 18
-- The list's width: 232, 200 when the window is narrow (the minimum size).
OATabFolder.LIST_W, OATabFolder.LIST_W_NARROW, OATabFolder.NARROW_BELOW = 232, 200, 680

function OATabFolder:createChildren()
    local p = self:palette()
    local list = UI.list(self, 0, 0, OATabFolder.LIST_W, self.height, OATabFolder.drawRow, self, OATabFolder.onPick)
    list.itemheight = OATabFolder.ROW_H
    list.itemPadY = 1
    list.palette = p
    list.backgroundColor = p.panel and { r = p.panel[1], g = p.panel[2], b = p.panel[3], a = 1 }
        or { r = p.text[1], g = p.text[2], b = p.text[3], a = 0.03 }
    list.borderColor = { r = p.border[1], g = p.border[2], b = p.border[3], a = 1 }
    list.selectionColor = { r = p.sel[1], g = p.sel[2], b = p.sel[3], a = 0.25 }
    list.mouseOverHighlightColor = { r = p.sel[1], g = p.sel[2], b = p.sel[3], a = 0.1 }
    self.list = list
    -- The text panel that types what is new (Story/TypedText); a document that is not new is its plain panel.
    local body = UI.rich(self, 0, 0, 100, 100, OATypedText)
    body.target, body.onFinished = self, OATabFolder.onTyped
    body.cursorColor = p.bright
    body.backgroundColor.a = 0
    body.borderColor.a = 0
    body.marginLeft, body.marginRight, body.marginTop, body.marginBottom = 0, 0, 0, 0
    self.body = body
    local bh = UI.buttonHeight()
    self.prevButton = OAMButton:new(0, 0, 70, bh, getText("IGUI_OA_Story_UI_Prev"), p, self, OATabFolder.onPrev)
    self.nextButton = OAMButton:new(0, 0, 70, bh, getText("IGUI_OA_Story_UI_Next"), p, self, OATabFolder.onNext)
    for _, b in ipairs({ self.prevButton, self.nextButton }) do
        b:initialise()
        b:instantiate()
        self:addChild(b)
    end
    self.groups, self.flat, self.rowOf = {}, {}, {}
    self.sent = {}
    self.runs, self.typedSent = {}, {}
end

-- The list's rows: a group's name, or an entry with its tier on the right and a mark when it is new.
function OATabFolder.drawRow(list, y, item)
    local p = list.palette
    local row = item.item
    if row.header then
        UI.text(list, row.header, 8, y + 1, p.head)
        return
    end
    local selected = list.selected == item.index
    if row.entry.isNew then UI.fill(list, 10, y + 7, 4, 4, p.warn) end
    UI.text(list, row.title, 18, y + 1, selected and p.bright or p.text)
    if row.label ~= "" then UI.textRight(list, row.label, list.width - (list:isVScrollBarVisible() and 22 or 10), y + 1, p.dim) end
end

-- What the folder holds ------------------------------------------------------------------------------------------

-- The list filled from the groups, the titles cut to the list's width.
function OATabFolder:fillList()
    local list = self.list
    list:clear()
    self.rowOf = {}
    local reach = list.width - 18 - 70
    for _, group in ipairs(self.groups) do
        list:addItem(group.id, { header = getText("IGUI_OA_Story_Group_" .. group.id) })
        for _, entry in ipairs(group.entries) do
            local item = list:addItem(entry.key, { entry = entry, title = UI.fit(entry.title, reach), label = Folder.tierLabel(entry.tier) })
            self.rowOf[entry.key] = item.itemindex
        end
    end
    self.listW = list.width
end

-- The entry to show when the folder is first looked at: the newest of the new ones, else the top one.
function OATabFolder:firstEntry()
    local best
    for _, entry in ipairs(self.flat) do
        if entry.isNew and (not best or entry.seq > best.seq) then best = entry end
    end
    return best or self.flat[1]
end

function OATabFolder:refresh()
    local record = self:record()
    if not record then return end
    self.groups = Folder.entries(record)
    self.flat = Folder.flat(self.groups)
    self.index = {}
    for i, entry in ipairs(self.flat) do self.index[entry.key] = i end
    self:layout()
    self:fillList()
    local entry = (self.key and self.flat[self.index[self.key] or 0]) or self:firstEntry()
    if entry then
        local row = self.rowOf[entry.key]
        if row then self.list.selected = row end
        if entry.key ~= self.shown then self:show(entry, record) end
    else
        self.shown, self.key, self.content = nil, nil, nil
        self.body:setVisible(false)
    end
    self.prevButton:setVisible(entry ~= nil)
    self.nextButton:setVisible(entry ~= nil)
end

-- Reads an entry: the text on the right, and what was new is told to the server as seen.
function OATabFolder:show(entry, record)
    self.key, self.shown = entry.key, entry.key
    local content = Folder.content(record, entry)
    self.content = content
    self.at = self.index[entry.key]
    local run = self:runFor(entry, content, record)
    local read = (run and run.parse) or Markup.parse(content.marked) or { plain = content.body, runs = {} }
    self.body.run = run
    self.body.text = Typing.rich(read, self:palette().text)
    self.body:paginate()
    self.body:setYScroll(0)
    self.body:setVisible(true)
    self.prevButton.enable = self.at > 1
    self.nextButton.enable = self.at < #self.flat
    self:fitHeads()
    if entry.isNew and not self.sent[entry.key] then
        self.sent[entry.key] = true
        self:send("story_seen", { key = entry.key })
    end
end

-- How an entry is typed: its run (the reading of its text and the clock, seconds typed) while it has something left to
-- type, else nil and the plain panel. What is new is typed when first shown; one left half typed goes on from where it
-- stood with the game time that passed turned into the terminal's own work (Typing.start). The run is kept with the
-- window, so the entry shown again goes on from where it was.
function OATabFolder:runFor(entry, content, record)
    local key = entry.key
    local run = self.runs[key]
    if run then return not run.done and run or nil end
    local speed = Typing.speed(content.kind, self.window.tier)
    local clock = speed and Typing.start(OA.Story.typedState(record, key), OA.hours(), getGameTime():getMinutesPerDay())
    if not clock then return nil end
    local parse = Markup.parse(content.marked, speed)
    if not parse then return nil end
    run = { key = key, parse = parse, clock = clock, done = clock >= parse.total }
    self.runs[key] = run
    if run.done then
        self:report(run)
        return nil
    end
    return run
end

-- The server is told how far an entry is typed: done (once), or the seconds when the window closes.
function OATabFolder:report(run)
    if run.done then
        if self.typedSent[run.key] then return end
        self.typedSent[run.key] = true
        self:send("story_typed", { key = run.key, done = true })
    elseif run.last then
        self:send("story_typed", { key = run.key, t = run.clock })
    end
end

-- The panel typed a text to its end.
function OATabFolder.onTyped(self, run)
    self:report(run)
end

-- The window is closing: what is half typed is kept, to go on from there when the folder shows it again.
function OATabFolder:onWindowClose()
    for _, run in pairs(self.runs) do self:report(run) end
end

function OATabFolder.onPick(self, row)
    if not row then return end
    if row.header then
        local previous = self.key and self.rowOf[self.key]
        if previous then self.list.selected = previous end
        return
    end
    if row.entry.key ~= self.shown then self:show(row.entry, self:record()) end
end

-- The entry before or after the one on show (the list's order).
function OATabFolder:step(by)
    local entry = self.flat[(self.at or 1) + by]
    if not entry then return end
    local row = self.rowOf[entry.key]
    if row then
        self.list.selected = row
        self.list:ensureVisible(row)
    end
    self:show(entry, self:record())
end

function OATabFolder:onPrev() self:step(-1) end
function OATabFolder:onNext() self:step(1) end

-- Show a given entry (the status tab's new-document card, the special request's copy link): by its folder key.
function OATabFolder:showKey(key)
    self.key = key
    self:refresh()
end

-- Where everything goes ------------------------------------------------------------------------------------------

function OATabFolder:readerRect()
    local lw = self.list.width
    return lw + 8, 0, self.width - lw - 8, self.height
end

-- The title and the line under it cut to the reader's width.
function OATabFolder:fitHeads()
    local content = self.content
    if not content then return end
    local _, _, rw = self:readerRect()
    self.titleText = UI.fit(content.title, rw - 24, UIFont.Medium)
    self.metaText = UI.fit(content.meta, rw - 24)
end

function OATabFolder:layout()
    local w, h = self.width, self.height
    self.laidW, self.laidH = w, h
    local list = self.list
    UI.size(list, w >= OATabFolder.NARROW_BELOW and OATabFolder.LIST_W or OATabFolder.LIST_W_NARROW, h)
    local rx, _, rw = self:readerRect()
    local bh = UI.buttonHeight()
    local body = self.body
    body:setX(rx + 12)
    body:setY(58)
    UI.size(body, rw - 24, math.max(20, h - 58 - bh - 16))
    body:paginate()
    self.prevButton:setX(rx + 12)
    self.prevButton:setY(h - bh - 8)
    self.nextButton:setX(rx + 88)
    self.nextButton:setY(h - bh - 8)
    self:fitHeads()
    if self.listW and self.listW ~= list.width then self:fillList() end
end

function OATabFolder:prerender()
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    local p = self:palette()
    local rx, _, rw, rh = self:readerRect()
    if p.panel then UI.fill(self, rx, 0, rw, rh, p.panel) else UI.fill(self, rx, 0, rw, rh, p.text, 0.03) end
    UI.frame(self, rx, 0, rw, rh, p.border)
    if not self.content then
        local text = getText("IGUI_OA_Story_UI_NoDocuments")
        UI.textCentre(self, UI.fit(text, rw - 24), rx + rw / 2, rh / 2 - 8, p.dim)
        return
    end
    UI.text(self, self.titleText, rx + 12, 6, p.bright, UIFont.Medium)
    UI.text(self, self.metaText, rx + 12, 30, p.dim)
    UI.fill(self, rx + 12, 50, rw - 24, 1, p.border, 0.6)
    UI.text(self, self.at .. " / " .. #self.flat, rx + 170, rh - UI.buttonHeight() - 8 + (UI.buttonHeight() - UI.fontHeight()) / 2,
        p.dim, p.numberFont)
end

return OATabFolder
