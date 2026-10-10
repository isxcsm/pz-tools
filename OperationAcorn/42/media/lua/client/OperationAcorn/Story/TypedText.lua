-- The text panel that types (DESIGN-terminal 14 F2): an ISRichTextPanel for a document or a radio copy in the terminal's
-- folder, laid out at once for the whole text so that nothing moves as it comes on, and drawn with the characters that
-- have come on. What a frame does is: add the real time since the last frame to the text's clock, look up how many
-- characters that is (Markup.count), and when the number has changed hand the panel's rows their new beginnings
-- (Typing.reveal, which keeps each beginning once made). No Lua timer runs per character, and a text that is not typed,
-- or is typed to its end, is the plain panel.
--
-- The text's state is its `run` (made by the folder tab for each showing of an entry): { parse = the reading of the text
-- (Markup.parse), clock = seconds typed, last = the time of the last frame (ms), seen = the furthest character that has
-- come on in any showing (it grows as the typing does), done = the typing is over }. A click on the text brings it at once
-- to the furthest point seen before (the whole of it when it was seen to the end) and no further: what the player has
-- never seen is typed in its time and cannot be skipped. The click is anywhere on the panel (no coordinates are read, so
-- the font and the scroll do not matter to it).
require "ISUI/ISRichTextPanel"
require "OperationAcorn/Core"
require "OperationAcorn/Markup"
require "OperationAcorn/Story/Typing"
local OA = OperationAcorn
local Markup, Typing = OA.Markup, OA.Typing

OATypedText = ISRichTextPanel:derive("OATypedText")

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
    ISRichTextPanel.paginate(self)
    self.reveal, self.n, self.tipChunk = nil, nil, nil
    local run = self.run
    if run and run.parse and not run.done then
        local chunks = {}
        for c, line in ipairs(self.lines or {}) do chunks[c] = unescape(line) end
        self.reveal = Typing.reveal(chunks, run.parse.plain, self.lines)
    end
end

-- A frame of a text on its way: the clock, the number of characters, and the rows when it has changed.
function OATypedText:advance(run)
    local now = getTimestampMs()
    if run.last and now > run.last and now - run.last < OATypedText.GAP then
        run.clock = run.clock + (now - run.last) / 1000
    end
    run.last = now
    local parse = run.parse
    local finished = run.clock >= parse.total
    local n = finished and parse.n or Markup.count(parse, run.clock)
    if n ~= self.n then
        self.n = n
        if n > (run.seen or 0) then run.seen = n end
        local c, k = self.reveal:show(n)
        self.tipChunk = c
        if c then
            self.tipX = self.lineX[c] + self.marginLeft + getTextManager():MeasureStringX(self.defaultFont, self.lines[c])
        end
    end
    if finished then
        run.done = true
        self.reveal, self.tipChunk = nil, nil
        if self.onFinished then self.onFinished(self.target, run) end
    end
end

-- The furthest point the player has seen of this text, at once: the clock goes on to the moment that character comes
-- (the whole text's end when it was seen to the end). Nothing happens at or past it, so a click cannot skip what was
-- never seen. The next frame draws it.
function OATypedText:hurry(run)
    local parse = run.parse
    local seen = run.seen or 0
    local at = seen >= parse.n and parse.total or parse.times[seen]
    if at and at > run.clock then run.clock = at end
end

function OATypedText:onMouseDown(x, y)
    ISRichTextPanel.onMouseDown(self, x, y)
    local run = self.run
    if self.reveal and run and not run.done then self:hurry(run) end
end

function OATypedText:render()
    -- The panel lays the text out again in its own render when its size changed; done first, the reveal starts over the
    -- new rows before they are drawn.
    if self.textDirty then self:paginate() end
    local run = self.run
    if self.reveal and run and not run.done then self:advance(run) end
    ISRichTextPanel.render(self)
    if self.tipChunk and self.cursorColor then self:drawCursor() end
end

-- A block after the last character that has come on, blinking. The panel is the game's, in pixels: the block is the
-- row's font high (less a ninth at each end, 3 at least) and a quarter of that wide, 6 at least, so it keeps to the text
-- in any font (the folder's body is the Medium font, at any scale).
function OATypedText:drawCursor()
    local c = self.tipChunk
    local fh = getTextManager():getFontHeight(self.defaultFont)
    local y = self.lineY[c] + self.marginTop + self:getYScroll()
    if y < 0 or y + fh > self.height then return end
    local col = self.cursorColor
    local inset = math.max(3, math.floor(fh / 9))
    local a = 0.55 + 0.45 * math.sin(getTimestampMs() / 160)
    self:drawRect(self.tipX + 1, y + inset, math.max(6, math.floor(fh / 4)), fh - 2 * inset, a, col[1], col[2], col[3])
end

return OATypedText
