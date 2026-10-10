-- The missions tab's document folder (DESIGN-terminal 6.4): a list of what the record keeps, in groups with the newest
-- on top, and the document open beside it inside the terminal's own window (no window of its own to hide behind the
-- terminal). Choosing a row reads it: the text on the right, 'previous' and 'next' step through the list, and what was
-- new stops being new (the server is told). The list is built again only when what it lists changed (not when the
-- typing goes on or is hurried: the server's answer to that redraws the tab, and the list stays as it was); the frames
-- only draw it.
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/Button"
require "OperationAcorn/Story/Folder"
require "OperationAcorn/Story/TypedText"
local OA = OperationAcorn
local UI = OA.Trade.UI
local Folder, Typing, Markup = OA.StoryFolder, OA.Typing, OA.Markup

OATabFolder = OATab:derive("OATabFolder")

-- The list's font: the Medium, as the document's (the folder is for reading), its rows a line of it and a margin.
OATabFolder.LIST_FONT = UIFont.Medium
OATabFolder.ROW_PAD = 4
-- The list's width: 232, 200 when the window is narrow (the minimum size).
OATabFolder.LIST_W, OATabFolder.LIST_W_NARROW, OATabFolder.NARROW_BELOW = 232, 200, 680
-- The document's font: one step over the other tabs' Small (DESIGN-terminal 6.4: the folder is for reading).
OATabFolder.BODY_FONT = UIFont.Medium
-- The reader's heads: the title's top, the room the title takes at least, and the body's top under the rule.
OATabFolder.TITLE_Y, OATabFolder.TITLE_MIN_H, OATabFolder.RULE_GAP, OATabFolder.BODY_GAP = 6, 24, 4, 8

function OATabFolder:createChildren()
    local p = self:palette()
    self.listWidth = OATabFolder.LIST_W
    local list = UI.list(self, 0, 0, self.listWidth, self.height, OATabFolder.drawRow, self, OATabFolder.onPick)
    self.rowH = OATabFolder.rowHeight()
    UI.rowHeight(list, self.rowH)
    list.rowH = self.rowH
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
    body.background = false
    body.palette = p
    body.marginLeft, body.marginRight, body.marginTop, body.marginBottom = 0, 0, 0, 0
    body.defaultFont = OATabFolder.BODY_FONT
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
    -- What this window has kept of each entry since it opened (Typing.keep), which the record may not have yet.
    self.kept = {}
end

-- A row of the list: a line of the list's font and the margin (design units).
function OATabFolder.rowHeight()
    return math.ceil(UI.fontHeight(OATabFolder.LIST_FONT)) + OATabFolder.ROW_PAD
end

-- The room on the right of a row: the label's margin, and the scroll bar's when the list scrolls.
local function rightRoom(list)
    return list:isVScrollBarVisible() and 22 or 10
end

-- How strong the list's rows are drawn next to the document (worklist 3-8): the list is for finding, the document for
-- reading, so the rows other than the one shown are quieter than the document's text and its heads.
OATabFolder.ROW_ALPHA, OATabFolder.LABEL_ALPHA = 0.7, 0.6

-- The list's rows: a group's name, or an entry with its tier on the right and a mark when it is new (design units: the
-- list is a canvas over the game's list, UI.list). The group names are labels: dim and a size down, at the foot of
-- their row so they sit on the entries under them (the document's heads are the ones in the head colour); the entries
-- are quieter than the one shown.
function OATabFolder.drawRow(list, y, item)
    local p = list.palette
    local row = item.item
    local font = OATabFolder.LIST_FONT
    local ty = y + OATabFolder.ROW_PAD / 2
    if row.header then
        local drop = UI.fontHeight(font) - UI.fontHeight(UIFont.Small)
        UI.text(list, row.header, 8, ty + drop, p.dim)
        return
    end
    local selected = list.selected == item.index
    if row.entry.isNew then UI.fill(list, 10, y + math.floor((list.rowH - 4) / 2), 4, 4, p.warn) end
    if selected then
        UI.text(list, row.title, 18, ty, p.bright, font)
    else
        UI.text(list, row.title, 18, ty, p.text, font, OATabFolder.ROW_ALPHA)
    end
    if row.label ~= "" then
        UI.textRight(list, row.label, list.width - rightRoom(list), ty, p.dim, font, OATabFolder.LABEL_ALPHA)
    end
end

-- What the folder holds ------------------------------------------------------------------------------------------

-- What the list shows of the groups, as one text: the list is built again only when it changes.
local function listSignature(groups)
    local parts = {}
    for _, group in ipairs(groups) do
        parts[#parts + 1] = group.id
        for _, entry in ipairs(group.entries) do
            parts[#parts + 1] = entry.key .. "|" .. tostring(entry.title) .. "|" .. tostring(entry.tier) .. "|"
                .. (entry.isNew and "n" or "")
        end
    end
    return table.concat(parts, ";")
end

-- The list filled from the groups, the titles cut to the room their row leaves (its tier on the right, the scroll bar).
-- The game's list adds each row's height to the height it scrolls over and its clear keeps that height: it is put back
-- to nothing first, else the list counts the old rows too until its next frame and its scroll bar (and the tiers by
-- it) show for that frame.
function OATabFolder:fillList()
    local list = self.list
    list:clear()
    list:setScrollHeight(0)
    self.rowOf = {}
    local font = OATabFolder.LIST_FONT
    local rows = 0
    for _, group in ipairs(self.groups) do rows = rows + 1 + #group.entries end
    local scrolls = rows * self.rowH > self.height
    local base = self.listWidth - 18 - (scrolls and 22 or 10)
    for _, group in ipairs(self.groups) do
        list:addItem(group.id, { header = getText("IGUI_OA_Story_Group_" .. group.id) })
        for _, entry in ipairs(group.entries) do
            local label = Folder.tierLabel(entry.tier)
            -- a title that names its tier already (a radio copy's "6단계") shows it once
            if label ~= "" and entry.title and string.find(entry.title, label, 1, true) then label = "" end
            local reach = base - (label ~= "" and UI.textWidth(label, font) + 8 or 0)
            local item = list:addItem(entry.key, { entry = entry, title = UI.fit(entry.title, reach, font), label = label })
            self.rowOf[entry.key] = item.itemindex
        end
    end
    self.listW, self.listH = self.listWidth, self.height
    self.listSig = listSignature(self.groups)
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
    -- laid out for a new size only (the frames do it too); the list built again only when what it lists changed
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    if self.listSig ~= listSignature(self.groups) then self:fillList() end
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

-- How a shown entry's heads come in (real seconds): the title slides in from the left as it shows, the line under it a
-- little after, and the rule is drawn left to right with a bright tip; the body's print waits for the rule (ENTER).
OATabFolder.TITLE_IN, OATabFolder.META_AFTER, OATabFolder.RULE_AFTER, OATabFolder.RULE_IN = 0.25, 0.08, 0.05, 0.3
OATabFolder.ENTER = OATabFolder.RULE_AFTER + OATabFolder.RULE_IN
OATabFolder.SLIDE = 10

-- Reads an entry: the text on the right, and what was new is told to the server as seen.
function OATabFolder:show(entry, record)
    self:leave()
    self.key, self.shown = entry.key, entry.key
    local content = Folder.content(record, entry)
    self.content = content
    self.at = self.index[entry.key]
    local run = self:runFor(entry, content, record)
    local read = (run and run.parse) or Markup.parse(content.marked) or { plain = content.body, runs = {} }
    if run then run.hold = OATabFolder.ENTER end
    self.body.run = run
    self.enterAt = getTimestampMs()
    local p = self:palette()
    self.body.text = Typing.rich(read, p.text, content.styles, { head = p.head, dim = p.dim })
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

-- How an entry is typed: its run (the reading of its text, the clock and how far it has been seen) for a kind of text that
-- is typed, else nil and the plain panel. An entry is typed every time it is shown, at the same speed; where it starts
-- is its kind's way (Typing.RESUME): a scene from the beginning, a document from where it was left with the game time
-- that passed turned into the terminal's own work. A click brings it to the furthest point seen (TypedText).
function OATabFolder:runFor(entry, content, record)
    local key = entry.key
    local speed = Typing.speed(content.kind, self.window.tier)
    if not speed then return nil end
    local parse = Markup.parse(content.marked, speed)
    if not parse then return nil end
    local state = Typing.latest(OA.Story.typedState(record, key), self.kept[key])
    local clock = Typing.start(state, OA.hours(), getGameTime():getMinutesPerDay(), content.kind)
    -- a document is printed a row at a time (TypedText): its rows are the panel's, so whether it is over is known when
    -- it is laid out; past a step a character it is over whatever its rows
    local step = Typing.MODE[content.kind] == "lines" and Typing.LINE_STEP or nil
    local over = step and parse.n * step or parse.total
    local run = { key = key, parse = parse, step = step, clock = clock, seen = Typing.seenOf(state, parse),
        done = clock >= over }
    if run.done then
        -- Left so long that the terminal has printed all of it: shown whole.
        run.seen = parse.n
        self:report(run)
        return nil
    end
    return run
end

-- The server is told how far a showing got, and the window keeps the same (Typing.keep): when the typing ends, when
-- another entry is shown, and when the window closes. Once for a showing; a showing that was not drawn says nothing.
function OATabFolder:report(run)
    if run.sent or not (run.last or run.done) then return end
    run.sent = true
    local key, n = run.key, run.parse.n
    local seen = math.min(run.seen or 0, n)
    local all = seen >= n or nil
    local clock = (not run.done) and run.clock or nil
    local old = Typing.latest(OA.Story.typedState(self:record(), key), self.kept[key])
    self.kept[key] = Typing.keep(old, seen, all, clock, OA.hours())
    self:send("story_typed", { key = key, seen = seen, done = all, t = clock })
end

-- The panel typed a text to its end.
function OATabFolder.onTyped(self, run)
    self:report(run)
end

-- The entry on show is left (another is shown, the window closes): what it got to is kept.
function OATabFolder:leave()
    local run = self.body and self.body.run
    if run then self:report(run) end
end

function OATabFolder:onWindowClose()
    self:leave()
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
    local lw = self.listWidth
    return lw + 8, 0, self.width - lw - 8, self.height
end

-- Where the reader's heads and its body go: the title (Medium), the line under it, the rule and the body's top.
function OATabFolder.heads()
    local F = OATabFolder
    local metaY = F.TITLE_Y + math.max(F.TITLE_MIN_H, UI.fontHeight(UIFont.Medium))
    local ruleY = metaY + UI.fontHeight() + F.RULE_GAP
    return metaY, ruleY, ruleY + F.BODY_GAP
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
    self.listWidth = w >= OATabFolder.NARROW_BELOW and OATabFolder.LIST_W or OATabFolder.LIST_W_NARROW
    UI.size(list, self.listWidth, h)
    local rx, _, rw = self:readerRect()
    local bh = UI.buttonHeight()
    local bodyY
    self.metaY, self.ruleY, bodyY = OATabFolder.heads()
    local body = self.body
    UI.place(body, rx + 12, bodyY, rw - 24, math.max(20, h - bodyY - bh - 16))
    body:paginate()
    self.prevButton:setX(rx + 12)
    self.prevButton:setY(h - bh - 8)
    self.nextButton:setX(rx + 12 + self.prevButton.width + 6)
    self.nextButton:setY(h - bh - 8)
    self.countX = self.nextButton.x + self.nextButton.width + 12
    self:fitHeads()
    if self.listW and (self.listW ~= self.listWidth or self.listH ~= h) then self:fillList() end
end

-- 0 to 1, fast at first and settling (a cubic ease out); below 0 is 0, above 1 is 1.
local function easeOut(f)
    if f <= 0 then return 0 end
    if f >= 1 then return 1 end
    local g = 1 - f
    return 1 - g * g * g
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
    local title, meta, rule = 1, 1, 1
    if self.enterAt then
        local t = (getTimestampMs() - self.enterAt) / 1000
        if t >= OATabFolder.ENTER + OATabFolder.META_AFTER then
            self.enterAt = nil
        else
            local F = OATabFolder
            title = easeOut((t) / F.TITLE_IN)
            meta = easeOut((t - F.META_AFTER) / F.TITLE_IN)
            rule = easeOut((t - F.RULE_AFTER) / F.RULE_IN)
        end
    end
    local slide = OATabFolder.SLIDE
    UI.text(self, self.titleText, rx + 12 - (1 - title) * slide, OATabFolder.TITLE_Y, p.bright, UIFont.Medium, title)
    UI.text(self, self.metaText, rx + 12 - (1 - meta) * slide, self.metaY, p.dim, nil, meta)
    local ruleW = (rw - 24) * rule
    if ruleW > 0 then UI.fill(self, rx + 12, self.ruleY, ruleW, 1, p.border, 0.6) end
    if rule < 1 and ruleW > 0 then
        UI.fill(self, rx + 12 + ruleW - math.min(ruleW, 24), self.ruleY, math.min(ruleW, 24), 1, p.head, 0.9)
    end
    UI.text(self, self.at .. " / " .. #self.flat, self.countX, rh - UI.buttonHeight() - 8 + (UI.buttonHeight() - UI.fontHeight()) / 2,
        p.dim, p.numberFont)
end

return OATabFolder
