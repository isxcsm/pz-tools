-- The terminal's comms tab (SCENES.md 2): the team's calls played and kept. Above, the record: each call under a head
-- (the tier, the regular call's hour, its name) with its replay button, the field monologues of a tier under one
-- head, the newest at the foot; only the newest open, the others folded to their heads (a click on a head opens or
-- folds it). Below, the protagonist's input line. A call plays here: the team's lines come in
-- like a signal, the protagonist's are typed on the input line (words typed and erased first) and go up into the
-- record when sent. While a call plays the game is paused (alone; never on a server), its sound turned down under a
-- low static, and its button skips it (a click: no key, which the game would also take); another tab or the window closing counts as skipping. Played or
-- skipped, the server keeps it (comms_played) and the next waiting call follows after a beat.
--
-- The lines are worked out once a line starts (Story/CommsScript); a frame draws from the timeline at the clock alone.
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Comms"
require "OperationAcorn/Story/CommsScript"
local OA = OperationAcorn
local UI, Comms, Script, Data = OA.Trade.UI, OA.Comms, OA.CommsScript, OA.CommsData

OATabComms = OATab:derive("OATabComms")

-- Layout (design units): the head row, the gap under it, the input line's height and the gap over it, the margins
-- in the record, the scroll bar, a wheel step.
OATabComms.TOP_H = 26
OATabComms.INPUT_GAP = 8
OATabComms.PAD = 10
OATabComms.BAR = 6
OATabComms.STEP = 48
-- A beat between one call and the next waiting one (ms).
OATabComms.NEXT_MS = 1500
-- The game's sound and ambience under a call, as a share of the player's own setting; the sounds (가안: set in the
-- game).
OATabComms.DUCK = 0.5
OATabComms.SOUND_STATIC = "RadioStatic"
OATabComms.SOUND_IN = "RadioZap"
OATabComms.SOUND_SEND = "RadioButton"

-- The voices' colours: the crude terminal's are its own greens; the field terminal's team line is a radio green.
local function colours(p)
    if p.mono then
        return { oak = p.text, me = { 0.90, 0.95, 0.90 }, field = { 0.70, 0.78, 0.70 }, pre = p.dim }
    end
    return { oak = { 0.55, 0.92, 0.60 }, me = p.bright, field = { 0.78, 0.76, 0.68 }, pre = p.dim }
end

local chars = Script.chars

-- How a call's lines are made for a record at a tier.
local function context(record, tier)
    return { text = Script.text, number = OA.Story.number(record), tier = tier, late = OA.Story.lateContact(record) }
end

-- What goes between the parts of a head (a middle dot).
local SEP = " " .. string.char(183) .. " "

-- The tier as the heads write it: the start, the stage's name, or after the handover.
local function tierLabel(tier)
    if tier <= 0 then return UI.str("IGUI_OA_Comms_Start") end
    if tier > OA.StoryData.TRANSFER_TIER then return UI.str("IGUI_OA_Comms_After") end
    return OA.Story.tierText(tier)
end

-- A regular call (its head shows the hour): one that opens with the greeting, and the scheduled calls after the
-- handover.
local function regular(e)
    return e.greet or (e.sign == "admin" and string.find(e.trigger, "^tier:") ~= nil)
end

local function hasTeam(e)
    for _, line in ipairs(e.lines or {}) do
        if line[1] == "oak" then return true end
    end
    return false
end

local function headText(e, tier)
    local parts = { tierLabel(tier) }
    if e.kind == "short" then
        parts[2] = UI.str("IGUI_OA_Comms_Short")
    elseif e.kind == "say" then
        parts[2] = UI.str("IGUI_OA_Comms_Field")
    else
        if regular(e) then parts[#parts + 1] = UI.str("IGUI_OA_Comms_Regular") end
        parts[#parts + 1] = UI.str("IGUI_OA_Comms_Scene_" .. e.id)
        if not hasTeam(e) then parts[#parts + 1] = UI.str("IGUI_OA_Comms_NoReception") end
    end
    return table.concat(parts, SEP)
end

local function signOf(e)
    return UI.str(e.sign == "admin" and "IGUI_OA_Story_CallSign_Handover" or "IGUI_OA_Story_CallSign_Oak")
end

local function cutText(s)
    return getText("IGUI_OA_Comms_Cut", tostring(s))
end

-- The record's rows ------------------------------------------------------------------------------------------------
-- A row: { kind = "head" | "oak" | "me" | "field" | "noise", h, lines (the text as drawn, wrapped), and by kind: sign,
-- replay (the log item to play again), erase (the struck words), counts (characters a wrapped line) }.

function OATabComms:textX()
    return OATabComms.PAD + self.prefixW
end

function OATabComms:textW()
    return self.log.width - self:textX() - OATabComms.PAD - OATabComms.BAR
end

local function rowH(n)
    return n * (UI.fontHeight() + 2) + 4
end

function OATabComms:headRow(label, item)
    return { kind = "head", text = label, replay = item, h = UI.fontHeight() + 14 }
end

-- A line's row: `text` wrapped to the text column; the erased words first, struck, on the first line.
function OATabComms:lineRow(kind, sign, s, erase)
    local tw = self:textW()
    local row = { kind = kind, sign = sign, erase = erase }
    if erase and erase ~= "" then
        row.eraseW = UI.textWidth(erase)
        local first = UI.wrapMemo(s, math.max(20, tw - row.eraseW - UI.spaceWidth()))[1] or ""
        local rest = string.gsub(string.sub(s, #first + 1), "^%s+", "")
        row.lines = { first }
        if rest ~= "" then
            for _, l in ipairs(UI.wrapMemo(rest, tw)) do row.lines[#row.lines + 1] = l end
        end
    else
        row.lines = UI.wrapMemo(s, tw)
    end
    row.counts = {}
    for i, l in ipairs(row.lines) do row.counts[i] = #chars(l) end
    row.h = rowH(#row.lines)
    return row
end

-- The rows of a played line (the record's: a break is written as the time it lasted).
function OATabComms:playedRows(rows, e, l)
    if l.who == "noise" or l.who == "mute" then
        local key = l.who == "noise" and "IGUI_OA_Comms_Noise" or "IGUI_OA_Comms_Mute"
        rows[#rows + 1] = self:lineRow("noise", nil, getText(key, tostring(l.s)))
    elseif l.who == "me" then
        rows[#rows + 1] = self:lineRow("me", self.number, l.text, l.erase)
    elseif l.who == "say" then
        rows[#rows + 1] = self:lineRow("field", UI.str("IGUI_OA_Comms_Field"), l.text)
    else
        rows[#rows + 1] = self:lineRow("oak", signOf(e), Script.recordText(l, cutText))
    end
end

-- The record's blocks: a head for each call (a short one too: each can be played again), one for a run of field
-- monologues of a tier, and its lines' rows. A block's key is the place in the log of its first entry (the log only
-- grows).
function OATabComms:recordBlocks(record)
    local blocks = {}
    local block, lastGroup
    for index, item in ipairs(Comms.section(record).log) do
        local e = Data.BY_ID[item.id]
        if e then
            local grouped = e.kind == "say"
            local group = grouped and (e.kind .. ":" .. tostring(item.tier)) or nil
            if not grouped or group ~= lastGroup or not block then
                local head = self:headRow(headText(e, item.tier), not grouped and item or nil)
                head.block = index
                block = { head = head, rows = {} }
                blocks[#blocks + 1] = block
            end
            lastGroup = group
            for _, l in ipairs(Script.lines(e, context(record, item.tier))) do self:playedRows(block.rows, e, l) end
            -- a short call has no name: its folded head shows how it begins
            if e.kind == "short" then
                for _, r in ipairs(block.rows) do
                    if r.kind ~= "noise" and r.lines[1] then block.head.preview = r.lines[1]; break end
                end
            end
        end
    end
    return blocks
end

-- Whether a block of the record shows its lines: as its head was last clicked, else only the newest (none while a
-- call plays: the call is the newest then).
function OATabComms:isOpen(key)
    local set = self.opened[key]
    if set ~= nil then return set end
    return key == self.newest and not self.play
end

-- A head clicked: its block opens or folds, the head staying where it was on the record.
function OATabComms:toggle(head)
    local key = head.block
    self.opened[key] = not self:isOpen(key)
    local record = self:record()
    if not record then return end
    local log = self.log
    local at = head.y - log.scroll
    self:setRows(record)
    log:setScroll(head.y - at)
end

-- The rows of the call playing: its head, the lines played, the one coming in (as it comes: no break written).
function OATabComms:playRows()
    local play, st = self.play, self.st
    local rows = { self:headRow(headText(play.entry, play.tier)) }
    for i = 1, st.done do self:playedRows(rows, play.entry, play.lines[i]) end
    local l = st.line and play.lines[st.line]
    if l then
        if l.who == "noise" or l.who == "mute" or l.who == "say" then
            self:playedRows(rows, play.entry, l)
        elseif l.who == "me" then
            if st.phase == "read" then self:playedRows(rows, play.entry, l) end
        else
            local row = self:lineRow("oak", signOf(play.entry), l.text)
            row.coming = true
            rows[#rows + 1] = row
        end
    end
    return rows
end

-- Puts the rows on the record, which stays at its foot when it was there (and while a call plays).
function OATabComms:setRows(record)
    local key = #Comms.section(record).log .. "|" .. tostring(self.log.width)
    if key ~= self.recordKey then
        self.recordKey = key
        self.prefixW = 0
        for _, k in ipairs({ "IGUI_OA_Story_CallSign_Oak", "IGUI_OA_Story_CallSign_Handover", "IGUI_OA_Comms_Field" }) do
            self.prefixW = math.max(self.prefixW, UI.textWidth(UI.str(k)))
        end
        self.prefixW = math.max(self.prefixW, UI.textWidth(self.number)) + 12
        self.kept = self:recordBlocks(record)
        local last = self.kept[#self.kept]
        self.newest = last and last.head.block
    end
    local rows = {}
    for _, block in ipairs(self.kept) do
        local open = self:isOpen(block.head.block)
        block.head.open = open
        rows[#rows + 1] = block.head
        if open then
            for _, r in ipairs(block.rows) do rows[#rows + 1] = r end
        end
    end
    if self.play then
        for _, r in ipairs(self:playRows()) do rows[#rows + 1] = r end
    end
    self.log:setRows(rows, self.play ~= nil)
end

-- The tab ----------------------------------------------------------------------------------------------------------

function OATabComms:createChildren()
    local p = self:palette()
    self.number = OA.Story.number(self:record() or {})
    self.colours = colours(p)
    self.skipButton = PZUIButton:new(0, 0, 90, UI.buttonHeight() - 4, getText("IGUI_OA_Comms_Skip"), p, self,
        OATabComms.skip)
    self.skipButton:initialise()
    self.skipButton:instantiate()
    self.skipButton:setVisible(false)
    self:addChild(self.skipButton)
    self.log = OACommsLog:new(0, OATabComms.TOP_H, self.width, 100, self)
    self.log:initialise()
    self.log:instantiate()
    self:addChild(self.log)
    -- the calls this window has told the server it played (the record may not say so yet)
    self.told = {}
    -- the record's blocks opened or folded by a click on their heads
    self.opened = {}
    self:layout()
end

function OATabComms:inputH()
    return UI.fontHeight() + 12
end

function OATabComms:layout()
    local w, h = self.width, self.height
    self.laidW, self.laidH = w, h
    local b = self.skipButton
    b:setX(w - b.width)
    b:setY(math.floor((OATabComms.TOP_H - 4 - b.height) / 2))
    local top = OATabComms.TOP_H
    UI.place(self.log, 0, top, w, math.max(40, h - top - self:inputH() - OATabComms.INPUT_GAP))
    self.recordKey = nil
    local record = self:record()
    if record then self:setRows(record) end
end

function OATabComms:refresh()
    local record = self:record()
    if not record then return end
    self:setRows(record)
    self:follow()
end

-- The call waiting to play next, if any (not one this window has played already).
function OATabComms:waiting(record)
    local e = Comms.next(record, "terminal")
    if e and not self.told[e.id] then return e end
    return nil
end

-- The cursor's blink on the input line (on, off), as the input line draws it.
OATabComms.BLINK_MS = 450

local function blinking(st)
    return st.phase ~= "type" and st.phase ~= "erasetype" and st.phase ~= "erase"
end

-- What the tab draws by the clock while a call plays (UI.live's look): the input line's characters, whose they are,
-- and its cursor's blink.
local function inputLook(st, now)
    local blink = blinking(st) and OA.remainder(math.floor(now / OATabComms.BLINK_MS), 2) or 0
    local of = st.inputOf == "erase" and 1 or st.inputOf == "text" and 2 or 0
    return (((st.line or 0) * 3 + of) * 2000 + (st.input or 0)) * 2 + blink
end

-- The cursor of the team's line coming in: none once it is all there, steady while its characters come, blinking
-- (RECV_BLINK_MS on, then off) while the line is open and nothing comes (the turn to the team, a silence, a pause, the
-- signal broken off). 0 none, 1 on, 2 off.
OATabComms.RECV_BLINK_MS = 300

local function recvCursor(st, now)
    if st.phase == "read" then return 0 end
    if st.phase == "in" then return 1 end
    return OA.remainder(math.floor(now / OATabComms.RECV_BLINK_MS), 2) == 0 and 1 or 2
end
OATabComms.recvCursor = recvCursor

-- What the record draws by the clock while a call plays: the characters of the line coming in and its cursor. Nil
-- once the call is over: its rows are written then.
local function logFrame(log, now)
    local st = log.tab.play and log.tab.st
    if not st then return nil end
    return ((st.line or 0) * 10000 + (st.shown or 0)) * 3 + recvCursor(st, now)
end

-- Each frame while something is going on (a call playing, one waiting to start): the clock's state, the rows as
-- lines start, the next call after a beat; nil when there is nothing.
local function frame(self, now)
    if self.play then
        self:advance(now)
        return self.st and inputLook(self.st, now) or 0
    end
    local window = self.window
    if window.boot and not window.consoleDone then return 1 end
    if self.nextAt and now < self.nextAt then return 1 end
    self.nextAt = nil
    local record = self:record()
    local e = record and self:waiting(record)
    if not e then return nil end
    self:start(e, OA.Story.tier(record), false, now)
    return now
end

-- Something may play: the tab follows the clock until it is done.
function OATabComms:follow()
    if self.play or (self:record() and self:waiting(self:record())) then UI.live(self, frame) end
end

-- The window's console is over: a waiting call may start.
function OATabComms:consoleOver()
    self:follow()
end

-- A call starts: `entry` at `tier`, `replay` from the record (nothing is sent at its end).
function OATabComms:start(entry, tier, replay, now)
    local record = self:record()
    local lines = Script.lines(entry, context(record, tier))
    self.play = { entry = entry, tier = tier, replay = replay, lines = lines, tl = Script.timeline(lines),
        at = now or getTimestampMs(), line = 0 }
    self.st = Script.at(self.play.tl, 0)
    self.skipButton:setVisible(true)
    self.window:setWantKeyEvents(true)
    self:hush(true)
    self:setRows(record)
    self.log:toFoot()
    UI.live(self, frame)
    UI.live(self.log, logFrame)
end

-- The clock moved: the state at it; a line that starts sounds and comes into the rows.
function OATabComms:advance(now)
    local play = self.play
    local st = Script.at(play.tl, (now - play.at) / 1000)
    self.st = st
    if not st.line then return self:finish() end
    local changed = false
    if st.line ~= play.line then
        play.line, play.sent = st.line, false
        local who = play.lines[st.line].who
        if who == "oak" then self:sound(OATabComms.SOUND_IN) end
        changed = true
    end
    if play.lines[st.line].who == "me" and st.phase == "read" and not play.sent then
        play.sent = true
        self:sound(OATabComms.SOUND_SEND)
        changed = true
    end
    if changed then self:setRows(self:record()) end
end

-- The call is over, played to its end or skipped (the same to the record). A call from the waiting ones goes to the
-- record; the next follows after a beat, unless the tab or the window is being left.
function OATabComms:finish(leaving)
    local play = self.play
    if not play then return end
    self.play, self.st = nil, nil
    self:hush(false)
    self.skipButton:setVisible(false)
    if not self.window.boot then self.window:setWantKeyEvents(false) end
    if not play.replay then
        self.told[play.entry.id] = true
        self:send("comms_played", { entry = play.entry.id })
    end
    if leaving then return end
    self.nextAt = getTimestampMs() + OATabComms.NEXT_MS
    local record = self:record()
    if record then self:setRows(record) end
    self:follow()
end

function OATabComms.skip(self)
    self:finish()
end

-- Another tab was chosen, or the window goes: a call playing counts as skipped.
function OATabComms:onTabLeave()
    self:finish(true)
end

function OATabComms:onWindowClose()
    self:finish(true)
end

-- A head's replay button: the scene plays again as it first did.
function OATabComms:replay(item)
    if self.play then return end
    local e = Data.BY_ID[item.id]
    if e then self:start(e, item.tier, true) end
end

-- The sound under a call (`on`): the game paused (alone), its sound and ambience turned down, a low static; and all
-- of it back.
function OATabComms:hush(on)
    local sm = getSoundManager()
    if on then
        if not isClient() and getGameSpeed() > 0 then
            self.speed = getGameSpeed()
            setGameSpeed(0)
        end
        local core = getCore()
        sm:setSoundVolume(core:getOptionSoundVolume() / 10 * OATabComms.DUCK)
        sm:setAmbientVolume(core:getOptionAmbientVolume() / 10 * OATabComms.DUCK)
        if not self.static then self.static = sm:playUISound(OATabComms.SOUND_STATIC) end
        return
    end
    if self.static then
        sm:stopUISound(self.static)
        self.static = nil
    end
    local core = getCore()
    sm:setSoundVolume(core:getOptionSoundVolume() / 10)
    sm:setAmbientVolume(core:getOptionAmbientVolume() / 10)
    if self.speed then
        if getGameSpeed() == 0 then setGameSpeed(self.speed) end
        self.speed = nil
    end
end

function OATabComms:sound(name)
    getSoundManager():playUISound(name)
end

-- Drawing ----------------------------------------------------------------------------------------------------------

function OATabComms:prerender()
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    local p = self:palette()
    local fh = UI.fontHeight()
    local ty = math.floor((OATabComms.TOP_H - 4 - fh) / 2)
    UI.text(self, UI.str("IGUI_OA_Comms_Record"), 0, ty, p.head)
    if self.play then
        UI.textRight(self, UI.str("IGUI_OA_Comms_Receiving"), self.skipButton.x - 10, ty, p.warn)
    end
    self:drawInput(p)
end

-- The characters of a text the frames draw a part of, split once.
local split = {}
local splitCount = 0
local function charsOf(s)
    local cs = split[s]
    if not cs then
        if splitCount > 400 then
            split, splitCount = {}, 0
        end
        cs = chars(s)
        split[s] = cs
        splitCount = splitCount + 1
    end
    return cs
end

-- The input line: the number and the prompt, what is typed (the words to erase, then the words sent) and the cursor.
function OATabComms:drawInput(p)
    local c = self.colours
    local h = self:inputH()
    local y = self.height - h
    local w = self.width
    local st = self.st
    local typing = st and st.inputOf ~= nil
    if p.panel then UI.fill(self, 0, y, w, h, p.panel) else UI.fill(self, 0, y, w, h, p.text, 0.03) end
    UI.frame(self, 0, y, w, h, typing and p.sel or p.border)
    local prompt = self.number .. " >"
    local ty = y + (h - UI.fontHeight()) / 2
    UI.text(self, prompt, 10, ty, c.pre)
    if not st then return end
    local x = 10 + UI.textWidth(prompt) + 8
    local shown = ""
    local l = st.line and self.play.lines[st.line]
    if l and st.inputOf then
        local cs = charsOf((st.inputOf == "erase" and l.erase or l.text) or "")
        shown = table.concat(cs, "", 1, math.min(st.input, #cs))
    end
    self:setStencilRect(1, y + 1, w - 2, h - 2)
    if shown ~= "" then UI.text(self, shown, x, ty, c.me) end
    -- the cursor: steady while typing, blinking while it waits
    local blink = blinking(st)
    if l and l.who == "me" and st.phase ~= "read" then
        if not blink or OA.remainder(math.floor(getTimestampMs() / OATabComms.BLINK_MS), 2) == 0 then
            UI.fill(self, x + UI.textWidth(shown) + 1, ty + 1, 7, UI.fontHeight() - 2, c.me, 0.85)
        end
    end
    UI.unclip(self, 1, y + 1, w - 2, h - 2)
end

-- The record's panel: its rows drawn where they are scrolled to, a bar on the right; the heads' replay buttons.
OACommsLog = ISPanel:derive("OACommsLog")

function OACommsLog:new(x, y, width, height, tab)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.tab = tab
    o.background = false
    o.rows, o.full, o.scroll = {}, 0, 0
    return o
end

function OACommsLog:maxScroll()
    return math.max(0, self.full - self.height + 8)
end

function OACommsLog:setScroll(v)
    self.scroll = math.max(0, math.min(self:maxScroll(), v))
end

function OACommsLog:toFoot()
    self:setScroll(self:maxScroll())
end

-- New rows: the record stays at its foot when it was there, or when `foot`.
function OACommsLog:setRows(rows, foot)
    local atFoot = foot or self.scroll >= self:maxScroll() - 2
    local y = 4
    for _, row in ipairs(rows) do
        row.y = y
        y = y + row.h
    end
    self.rows, self.full = rows, y
    if atFoot then self:toFoot() else self:setScroll(self.scroll) end
end

function OACommsLog:thumb()
    return UI.thumb(self.height, self.full + 8, self.scroll, self:maxScroll())
end

function OACommsLog:onMouseWheel(del)
    if self:maxScroll() <= 0 then return false end
    self:setScroll(self.scroll + del * OATabComms.STEP)
    return true
end

-- The replay button of a head row: its left edge and width.
function OACommsLog:replayBox()
    local w = UI.textWidth(UI.str("IGUI_OA_Comms_Replay")) + 16
    return self.width - OATabComms.PAD - OATabComms.BAR - w, w
end

function OACommsLog:rowAt(y)
    for _, row in ipairs(self.rows) do
        if y >= row.y and y < row.y + row.h then return row end
    end
    return nil
end

-- The replay button under the mouse (its row), if any.
function OACommsLog:replayAt(x, y)
    local row = self:rowAt(y + self.scroll)
    if not (row and row.replay) or self.tab.play then return nil end
    local bx, bw = self:replayBox()
    if x >= bx and x < bx + bw then return row end
    return nil
end

function OACommsLog:onMouseDown(x, y)
    if self:maxScroll() > 0 and x >= self.width - OATabComms.BAR - 2 then
        UI.barPress(self, y)
        return true
    end
    local row = self:replayAt(x, y)
    if row then
        UI.placeFlash(self, row.replay)
        self.tab:replay(row.replay)
        return true
    end
    row = self:headAt(y)
    if row then self.tab:toggle(row) end
    return true
end

-- The head of a record's block under the mouse (it opens and folds the block), if any; none while a call plays (the
-- record stays at the call).
function OACommsLog:headAt(y)
    if self.tab.play then return nil end
    local row = self:rowAt(y + self.scroll)
    if row and row.block then return row end
    return nil
end

function OACommsLog:onMouseMove(dx, dy) UI.barDrag(self, dy) end
function OACommsLog:onMouseMoveOutside(dx, dy) UI.barDrag(self, dy) end
function OACommsLog:onMouseUp() self.dragging = false end
function OACommsLog:onMouseUpOutside() self.dragging = false end

function OACommsLog:prerender()
    local tab = self.tab
    local p = tab:palette()
    local w, h = self.width, self.height
    if p.panel then UI.fill(self, 0, 0, w, h, p.panel) else UI.fill(self, 0, 0, w, h, p.text, 0.03) end
    UI.frame(self, 0, 0, w, h, p.border)
    local over
    self.overHead = nil
    if self:isMouseOver() and not self.dragging then
        local row = self:replayAt(self:getMouseX(), self:getMouseY())
        over = row and row.replay
        if not over then self.overHead = self:headAt(self:getMouseY()) end
    end
    UI.placeLight(self, over)
    if #self.rows == 0 then
        UI.textCentre(self, UI.str("IGUI_OA_Comms_Empty"), w / 2, h / 2 - UI.fontHeight() / 2, p.dim)
        return
    end
    self:setStencilRect(1, 1, w - 2, h - 2)
    for _, row in ipairs(self.rows) do
        local y = row.y - self.scroll
        if y + row.h > 0 and y < h then self:drawRow(row, y, p) end
    end
    UI.unclip(self, 1, 1, w - 2, h - 2)
    if self:maxScroll() > 0 then
        local ty, th = self:thumb()
        UI.drawBar(self, w - OATabComms.BAR - 2, OATabComms.BAR - 2, h, ty, th, p.border)
    end
end

-- A small triangle in a box `size` square at x, y: pointing down (`open`) or right.
function OACommsLog.foldMark(panel, x, y, size, open, colour)
    local half = math.floor(size / 2)
    -- its point is half + 1 deep: centred that way in the box
    local inset = math.floor((size - half - 1) / 2)
    for i = 0, half do
        local span = (half - i) * 2 + 1
        if open then
            UI.fill(panel, x + i, y + inset + i, span, 1, colour)
        else
            UI.fill(panel, x + inset + i, y + i, 1, span, colour)
        end
    end
end

-- A row at y: a head with its fold mark, rule and replay button, or a line after its call sign.
function OACommsLog:drawRow(row, y, p)
    local tab = self.tab
    local c = tab.colours
    local fh = UI.fontHeight()
    local pad = OATabComms.PAD
    if row.kind == "head" then
        local ty = y + 8
        local hover = self.overHead == row
        UI.fill(self, pad, ty + math.floor(fh / 2), self.width - pad * 2 - OATabComms.BAR, 1, p.border, 0.5)
        -- the fold mark: pointing down over an open block, right at a folded one
        local mark = row.block and math.floor(fh * 0.4) or 0
        local label = UI.fitMemo(row.text, self.width - pad * 4 - 120 - mark)
        local lw = UI.textWidth(label) + 12 + (mark > 0 and mark + 6 or 0)
        -- a folded short call's first words, dim, up to the replay button
        local preview, pw = nil, 0
        if row.preview and not row.open then
            local room = self:replayBox() - 16 - (pad + lw + 8)
            if room > 40 then
                preview = UI.fitMemo(row.preview, room)
                pw = UI.textWidth(preview) + 8
            end
        end
        if preview then
            if p.panel then UI.fill(self, pad + lw, ty, pw + 4, fh, p.panel) else UI.fill(self, pad + lw, ty, pw + 4, fh, p.bg) end
            UI.text(self, preview, pad + lw + 4, ty, p.dim)
        end
        if p.panel then UI.fill(self, pad, ty, lw, fh, p.panel) else UI.fill(self, pad, ty, lw, fh, p.bg) end
        if hover then UI.fill(self, pad, ty, lw, fh, p.sel, 0.15) end
        local colour = hover and p.bright or p.head
        local lx = pad + 4
        if mark > 0 then
            OACommsLog.foldMark(self, lx, ty + math.floor((fh - mark) / 2), mark, row.open, colour)
            lx = lx + mark + 6
        end
        UI.text(self, label, lx, ty, colour)
        if row.replay and not tab.play then
            local bx, bw = self:replayBox()
            local k, f = UI.placeLevels(self, row.replay)
            if p.panel then UI.fill(self, bx - 4, ty - 2, bw + 8, fh + 4, p.panel) else UI.fill(self, bx - 4, ty - 2, bw + 8, fh + 4, p.bg) end
            if k > 0 or f > 0 then UI.fill(self, bx, ty - 1, bw, fh + 2, p.sel, 0.12 * k + 0.25 * f) end
            UI.frame(self, bx, ty - 1, bw, fh + 2, k > 0.5 and p.text or p.border)
            UI.textCentre(self, UI.str("IGUI_OA_Comms_Replay"), bx + bw / 2, ty, k > 0.5 and p.bright or p.text)
        end
        return
    end
    local tx = tab:textX()
    local ly = y + 2
    local colour = c[row.kind] or c.pre
    if row.sign then UI.text(self, row.sign, pad, ly, c.pre) end
    if row.kind == "noise" then colour = c.pre end
    -- The line coming in: as many characters as have come.
    local left = math.huge
    if row.coming and tab.st then left = tab.st.shown end
    local x0 = tx
    if row.erase and row.erase ~= "" then
        -- the words erased before the line was sent: dim and struck, never sent
        UI.text(self, row.erase, tx, ly, c.pre, nil, 0.75)
        UI.fill(self, tx, ly + math.floor(fh * 0.55), row.eraseW, 1, c.pre, 0.9)
        x0 = tx + row.eraseW + UI.spaceWidth()
    end
    -- where the characters end: the cursor of the line coming in goes there
    local cx, cy = x0, ly
    for i, l in ipairs(row.lines) do
        if left <= 0 then break end
        local s = l
        if left < row.counts[i] then s = table.concat(charsOf(l), "", 1, left) end
        local lx, lyi = i == 1 and x0 or tx, ly + (i - 1) * (fh + 2)
        UI.text(self, s, lx, lyi, colour)
        cx, cy = lx + UI.textWidth(s), lyi
        left = left - row.counts[i]
    end
    if row.coming and tab.st and tab.recvCursor(tab.st, getTimestampMs()) == 1 then
        UI.fill(self, cx + 1, cy + 1, 7, fh - 2, colour, 0.85)
    end
end

UI.scaled(OACommsLog, ISPanel)

OA.Terminal.addTab("comms", function(x, y, w, h, window)
    return OATabComms:new(x, y, w, h, window)
end, {
    mark = function(record) return Comms.waiting(record) > 0 and "new" or nil end,
    opens = function(record) return Comms.waiting(record) > 0 end,
})

return OATabComms
