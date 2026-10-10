-- The text panel that types (DESIGN-terminal 14 F2): our rich text panel (Trade/RichText) for a document or a radio
-- copy in the terminal's folder, laid out at once for the whole text so that nothing moves as it comes on, and drawn
-- with the characters that have come on. What a frame does is: add the real time since the last frame to the text's
-- clock, look up how many characters that is (Markup.count), and when the number has changed hand the panel's rows
-- their new beginnings (Typing.reveal, which keeps each beginning once made). No Lua timer runs per character, and a
-- text that is not typed, or is typed to its end, is the plain panel. A document is printed instead (Typing.MODE): a row at a time, whole, every
-- `run.step` seconds, each printed left to right under the cursor (Typing.LINE_PRINT); the rows are the panel's own (Typing.rowEnds: the character each row ends at), so the same
-- reveal shows them and what is kept of a showing is counted in characters either way.
--
-- The text's state is its `run` (made by the folder tab for each showing of an entry): { parse = the reading of the text
-- (Markup.parse), step = the seconds between printed rows (a document; nil: typed a character at a time), clock = seconds
-- typed, hold = real seconds to wait before the clock runs (the reader's title coming in; kept nowhere), last = the time
-- of the last frame (ms), seen = the furthest character that has
-- come on in any showing (it grows as the typing does), done = the typing is over }. A click on the text brings it at once
-- to the furthest point seen before (the whole of it when it was seen to the end) and no further: what the player has
-- never seen is typed in its time and cannot be skipped. The click is anywhere on the panel (no coordinates are read, so
-- the font and the scroll do not matter to it).
require "OperationAcorn/Trade/RichText"
require "OperationAcorn/Core"
require "OperationAcorn/Markup"
require "OperationAcorn/Story/Typing"
local OA = OperationAcorn
local Markup, Typing = OA.Markup, OA.Typing

OATypedText = OARichText:derive("OATypedText")

-- The most real milliseconds that count between two frames: a longer gap means the panel was not on show (another
-- document, another tab), and the typing waited with it.
OATypedText.GAP = 500

local function unescape(text)
    text = string.gsub(text, "&lt;", "<")
    return (string.gsub(text, "&gt;", ">"))
end

-- Lays the text out again (the panel does, when its text or size changes) and, for a text on its way, starts the reveal
-- over the new rows.
function OATypedText:paginate()
    OARichText.paginate(self)
    self.reveal, self.n, self.tipChunk, self.rowEnds = nil, nil, nil, nil
    local run = self.run
    if run and run.parse and not run.done then
        local chunks = {}
        for c, line in ipairs(self.lines or {}) do chunks[c] = unescape(line) end
        self.reveal = Typing.reveal(chunks, run.parse.plain, self.lines)
        if run.step then self.rowEnds = Typing.rowEnds(self.reveal.src, self.lineY) end
    end
end

-- Where a text on its way stands at its clock: how many characters have come on, whether it is over, and whether the
-- cursor is on show (typing; a document's row being printed). A document comes a row at a time and is over a step after
-- its last row.
function OATypedText:countAt(run)
    local parse = run.parse
    local ends = self.rowEnds
    if ends then
        local n, over, printing = Typing.printed(ends, run.clock, run.step, Typing.LINE_PRINT)
        return n or parse.n, over, printing
    end
    if run.clock >= parse.total then return parse.n, true, false end
    return Markup.count(parse, run.clock), false, true
end

-- A frame of a text on its way: the clock, the number of characters, and the rows when it has changed.
function OATypedText:advance(run)
    local now = getTimestampMs()
    if run.last and now > run.last and now - run.last < OATypedText.GAP then
        local dt = (now - run.last) / 1000
        local hold = run.hold
        if hold and hold > 0 then
            local wait = math.min(hold, dt)
            run.hold, dt = hold - wait, dt - wait
        end
        run.clock = run.clock + dt
    end
    run.last = now
    local n, finished, head = self:countAt(run)
    if n ~= self.n or (self.tipChunk ~= nil) ~= head then
        self.n = n
        if n > (run.seen or 0) then run.seen = n end
        local c = self.reveal:show(n)
        -- the cursor follows the characters as they come: typed, or a row under the print head (not between rows)
        self.tipChunk = (c and head) and c or nil
        if self.tipChunk then
            local x = self.cX and self.cX[c] or (self.lineX[c] + self.marginLeft)
            self.tipX = x + self:measure(self.lines[c], self.defaultFont)
        end
    end
    if finished then
        run.done = true
        self.reveal, self.tipChunk = nil, nil
        if self.onFinished then self.onFinished(self.target, run) end
    end
end

-- The furthest point the player has seen of this text, at once: the clock goes on to the moment that character comes
-- (the whole text's end when it was seen to the end; for a document, the last row seen whole). Nothing happens at or
-- past it, so a click cannot skip what was never seen. The next frame draws it.
function OATypedText:hurry(run)
    local parse = run.parse
    local seen = run.seen or 0
    local at
    local ends = self.rowEnds
    if ends then
        if seen >= parse.n then
            at = #ends * run.step
        else
            local rows = 0
            while rows < #ends and ends[rows + 1] <= seen do rows = rows + 1 end
            if rows > 0 then at = (rows - 1) * run.step + Typing.LINE_PRINT end
        end
    else
        at = seen >= parse.n and parse.total or parse.times[seen]
    end
    run.hold = nil
    if at and at > run.clock then run.clock = at end
end

function OATypedText:onMouseDown(x, y)
    OARichText.onMouseDown(self, x, y)
    local run = self.run
    if self.reveal and run and not run.done then self:hurry(run) end
end

function OATypedText:render()
    -- The panel lays the text out again in its own render when its size changed; done first, the reveal starts over the
    -- new rows before they are drawn.
    if self.textDirty or self.laidW ~= self.width then self:paginate() end
    local run = self.run
    if self.reveal and run and not run.done then self:advance(run) end
    OARichText.render(self)
    if self.tipChunk and self.cursorColor then self:drawCursor() end
end

-- A block after the last character that has come on, blinking, in design units: the block is the row's face high (less
-- a ninth at each end, 3 at least) and a quarter of that wide, 6 at least, so it keeps to the text in any face (the
-- folder's body is the Medium font, at any scale).
function OATypedText:drawCursor()
    local c = self.tipChunk
    local fh = self:lineHeightOf(self.defaultFont)
    local y = self.lineY[c] + self.marginTop + self:getYScroll()
    if y < 0 or y + fh > self.height then return end
    local col = self.cursorColor
    local inset = math.max(3, math.floor(fh / 9))
    local a = 0.55 + 0.45 * math.sin(getTimestampMs() / 160)
    self:drawRect(self.tipX + 1, y + inset, math.max(6, math.floor(fh / 4)), fh - 2 * inset, a, col[1], col[2], col[3])
end

return OATypedText
