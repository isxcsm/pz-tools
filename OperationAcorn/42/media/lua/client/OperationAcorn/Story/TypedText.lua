-- The text panel that types (DESIGN-terminal 14 F2): an ISRichTextPanel for a document or a radio copy in the terminal's
-- folder, laid out at once for the whole text so that nothing moves as it comes on, and drawn with the characters that
-- have come on. What a frame does is: add the real time since the last frame to the text's clock, look up how many
-- characters that is (Markup.count), and when the number has changed hand the panel's rows their new beginnings
-- (Typing.reveal, which keeps each beginning once made). No Lua timer runs per character, and a text that is not typed,
-- or is typed to its end, is the plain panel.
--
-- The text's state is its `run` (made by the folder tab, kept with the window): { parse = the reading of the text
-- (Markup.parse), clock = seconds typed, last = the time of the last frame (ms), done }. A click on the text types the
-- rest at once.
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

function OATypedText:render()
    -- The panel lays the text out again in its own render when its size changed; done first, the reveal starts over the
    -- new rows before they are drawn.
    if self.textDirty then self:paginate() end
    local run = self.run
    if self.reveal and run and not run.done then self:advance(run) end
    ISRichTextPanel.render(self)
    if self.tipChunk and self.cursorColor then self:drawCursor() end
end

-- A block after the last character that has come on, blinking.
function OATypedText:drawCursor()
    local c = self.tipChunk
    local fh = getTextManager():getFontHeight(self.defaultFont)
    local y = self.lineY[c] + self.marginTop + self:getYScroll()
    if y < 0 or y + fh > self.height then return end
    local col = self.cursorColor
    local a = 0.55 + 0.45 * math.sin(getTimestampMs() / 160)
    self:drawRect(self.tipX + 1, y + 3, 6, fh - 6, a, col[1], col[2], col[3])
end

return OATypedText
