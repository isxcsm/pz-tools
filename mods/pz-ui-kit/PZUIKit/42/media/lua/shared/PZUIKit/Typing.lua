-- Typing a text in a window: the clock a text is typed by and how far it has been seen, and the pieces the kit's text
-- panel that types (PZUITypedText) is made of, here so that they can be tested without the game. Nothing in this file
-- touches the game.
--
-- How a text is typed: the window counts the time it has shown the text (real seconds, from the differences of
-- getTimestampMs, which go on while the game is paused) and asks Markup.count how many characters have come on by then
-- (a character at a time); or it prints the text a row at a time, whole, as a teleprinter prints a line (Typing.printed,
-- every LINE_STEP seconds). A frame in which the count has not changed does nothing more. What a mod keeps of each text
-- is how far the player has SEEN it, so that a click can show that much at once and never more:
--   { seen = the furthest character that has come on, in any showing (a character count, so that it holds at another
--     speed),
--     done = true once it was seen to its end,
--     t = the seconds typed, of a first presentation left half way }
-- The first presentation of a text (not seen to its end yet) goes on from where it was left, at exactly the clock it
-- stopped at: nothing runs while the player is away. Once a text has been seen to its end nothing of a showing is kept
-- but that: every showing plays it again from the beginning, and a click shows all of it. A state of `true` is read as
-- seen to the end, and so is no state at all (Typing.seenOf: a text shown whole before).
require "PZUIKit/Markup"
PZUIKit = PZUIKit or {}
local Markup = PZUIKit.Markup
local Typing = {}
PZUIKit.Typing = Typing

local sub, find = string.sub, string.find

-- The seconds between two printed rows: four rows a second, so a text of thirty rows is printed in under eight seconds,
-- with a beat between rows that reads as a printer's (rows that ran into each other read as fast typing).
Typing.LINE_STEP = 0.25
-- The seconds a row takes to print, left to right under the print head (the cursor): quick, so the row is a stroke and
-- the beat is the wait for the next one.
Typing.LINE_PRINT = 0.05

-- Where the clock of a text stands when the window shows it, in seconds typed: where the first presentation was left,
-- exactly (no game time is made up for); 0 for a text seen to its end (it plays again from the beginning, whatever clock
-- an older record kept) and for one with nothing left half way.
function Typing.start(state)
    if type(state) ~= "table" or state.done then return 0 end
    return math.max(0, tonumber(state.t) or 0)
end

-- How far a text has been seen, in characters of its reading (Markup.parse): all of it for a state of `true` or done, and
-- for an entry with no state (it was shown whole); the state's own count otherwise. A state with a clock only: the
-- characters that had come on by it.
function Typing.seenOf(state, read)
    if type(state) ~= "table" or state.done then return read.n end
    local seen = tonumber(state.seen)
    if seen then return math.min(math.max(seen, 0), read.n) end
    local t = tonumber(state.t) or 0
    if t > 0 then return Markup.count(read, t) end
    return 0
end

-- The state to keep once a showing is left (or the window closes), from the one kept before (nil, `true` or a table), how
-- far the text has been seen in this showing (`seen` characters), whether that is the whole of it, and `clock` (seconds
-- typed) when the showing ended before the typing did, nil when it ran to its end. The furthest seen only grows and a
-- text seen to its end stays so, and keeps no clock: a showing of it that is left half way is not kept.
function Typing.keep(old, seen, done, clock)
    local was = type(old) == "table" and old or nil
    local state = { seen = math.max(was and tonumber(was.seen) or 0, seen or 0) }
    if old == true or (was and was.done) or done then
        state.done = true
    elseif clock then
        state.t = clock
    end
    return state
end

-- Of two states of one entry (the record's, and what this window kept since, which may be the newer): the one to go by.
-- What the record has of being seen to the end counts either way.
function Typing.latest(recorded, kept)
    if kept == nil then return recorded end
    local done = recorded == true or (type(recorded) == "table" and recorded.done)
    if done and not kept.done then
        return { seen = kept.seen, done = true }
    end
    return kept
end

-- ---------------------------------------------------------------------------------------------------------------
-- A document's own marks. A line of a document's text that begins with:
--   "## "  is a section head: the mark goes, the line is in the palette's head colour with half a line above it (none
--          for the first line);
--   "· "   is a bullet: the mark stays, and the rows the line wraps into hang under the text after it;
--   "~ "   is a dim line (who, when): the mark goes;
--   "> "   is the sign-off: the mark goes, the line is dim, on the right, with half a line above it.
-- A numbered line ("1. ", "2) ") hangs its wrapped rows under its text as a bullet does. Lines without a mark are as
-- they were. The marks are taken out of the text before it is read (Markup.parse), so they are never typed and never
-- counted among its characters.
-- A form's lines, when asked for (`opts.fields`): a line that opens with a label and a colon ("Seized: ...", the label
-- of at most FIELD_CHARS characters and not a sentence: no full stop, question or exclamation mark or slash in it) or
-- with a date ("7/5 ...") is a field: the label or the date is dim, and the rows the line wraps into hang under what
-- follows it (under a label of at most HANG_CHARS characters; a longer one would leave the text a narrow column).

local DOT = string.char(183)
Typing.FIELD_CHARS = 24
Typing.HANG_CHARS = 12

-- A field's lead (the label with its colon, or the date) in bytes and whether its rows hang, or nil for a line that is
-- not a field.
local function fieldLead(line)
    local date = string.match(line, "^%d+/%d+ ")
    if date then return #date - 1, true end
    local label = string.match(line, "^([^:]+): ")
    if not label or find(label, "[%.%?!/]") then return nil end
    -- (the game's strings hold a character, Korean too, as one: their length is their characters)
    local n = #label
    if n > Typing.FIELD_CHARS then return nil end
    return #label + 1, n <= Typing.HANG_CHARS
end

-- The text without its marks, and the style of each line that had one: styles[line] = { kind = "head", "bullet",
-- "num", "meta", "sign" or "field", hang = the characters its wrapped rows hang under, lead = a field's dim lead }.
-- Lines are counted from 1 at each "\n". `opts.fields`: forms' fields are found too.
function Typing.marks(text, opts)
    if type(text) ~= "string" then return text, {} end
    local fields = opts and opts.fields
    local out, styles, li = {}, {}, 0
    for line in string.gmatch(text .. "\n", "(.-)\n") do
        li = li + 1
        local head = sub(line, 1, 3)
        if head == "## " then
            styles[li] = { kind = "head" }
            line = sub(line, 4)
        elseif sub(line, 1, 2) == "~ " then
            styles[li] = { kind = "meta" }
            line = sub(line, 3)
        elseif sub(line, 1, 2) == "> " then
            styles[li] = { kind = "sign" }
            line = sub(line, 3)
        elseif sub(line, 1, 2) == DOT .. " " then
            styles[li] = { kind = "bullet", hang = 2 }
        else
            local number = string.match(line, "^%d+[%.%)] ")
            local lead, hangs
            if not number and fields then lead, hangs = fieldLead(line) end
            if number then
                styles[li] = { kind = "num", hang = #number }
            elseif lead then
                styles[li] = { kind = "field", hang = hangs and lead + 1 or nil, lead = lead }
            end
        end
        out[li] = line
    end
    return table.concat(out, "\n"), styles
end

-- ---------------------------------------------------------------------------------------------------------------
-- The text panel's text.

local function rgbTag(r, g, b)
    return string.format(" <RGB:%.3f,%.3f,%.3f> ", r, g, b)
end

local function escape(text)
    text = string.gsub(text, "<", "&lt;")
    return (string.gsub(text, ">", "&gt;"))
end

local function trimmed(text)
    local s = string.gsub(text, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

-- One line's piece of one colour. The panel cuts its text at spaces and drops them at a change of colour, so a space
-- there is asked for (<SPACE>).
local function piece(out, st, text, rgb)
    local body = trimmed(text)
    if body == "" then
        if text ~= "" then st.space = true end
        return
    end
    local lead = find(text, "^%s") ~= nil
    if rgb ~= st.rgb then
        out[#out + 1] = rgb
        st.rgb = rgb
        if (lead or st.space) and not st.lineStart then out[#out + 1] = " <SPACE> " end
    elseif not st.lineStart then
        -- a piece of the same colour as the one before it on the line (a coloured run in a head's own colour): a space
        -- between them is a space of the text, none keeps them one word
        out[#out + 1] = (lead or st.space) and " " or ""
    end
    out[#out + 1] = escape(body)
    st.lineStart = false
    st.space = find(text, "%s$") ~= nil
end


-- The text for the kit's rich text panel (PZUIRichText) from a reading (Markup.parse): the characters in colour, the line
-- ends as <LINE>, in the colour `c` ({ r, g, b }, 0 to 1) where the text has none of its own. `styles` (Typing.marks,
-- optional) gives lines their look, in `tones` = { head = { r, g, b }, dim = { r, g, b } }: a head and a dim line in
-- those colours where their characters have none of their own, half a line above a head and the sign-off and between
-- the dim lines on top and what follows them, the sign-off on the right, a field's lead dim, and the rows a bullet's, a
-- number's or a field's line wraps into hung under its text.
function Typing.rich(read, c, styles, tones)
    local default = rgbTag(c[1], c[2], c[3])
    local out = { " <TEXT>", default }
    local st = { rgb = default, lineStart = true, space = false }
    local plain = read.plain
    local runs, ri = read.runs, 1
    local headTag = tones and tones.head and rgbTag(tones.head[1], tones.head[2], tones.head[3]) or default
    local dimTag = tones and tones.dim and rgbTag(tones.dim[1], tones.dim[2], tones.dim[3]) or default
    local pos, li, total = 1, 1, #plain
    while pos <= total + 1 do
        local nl = find(plain, "\n", pos, true)
        local last = nl and nl - 1 or total
        local style = styles and styles[li]
        local kind = style and style.kind
        local lineTag = (kind == "head" and headTag) or ((kind == "meta" or kind == "sign") and dimTag) or default
        local before = styles and styles[li - 1]
        if (kind == "head" or kind == "sign") and li > 1 then
            out[#out + 1] = " <HALF> "
        elseif kind ~= "meta" and before and before.kind == "meta" then
            out[#out + 1] = " <HALF> "
        end
        if kind == "sign" then out[#out + 1] = " <RIGHT> " end
        local hangAt = style and style.hang and pos + style.hang - 1 or nil
        local leadTo = style and style.lead and pos + style.lead - 1 or nil
        local at = pos
        while at <= last do
            while runs[ri] and runs[ri].to < at do ri = ri + 1 end
            local run = runs[ri]
            local to, tag
            if run and run.from <= at then
                to, tag = math.min(run.to, last), rgbTag(run.r, run.g, run.b)
            else
                to, tag = math.min(run and run.from - 1 or last, last), lineTag
                if leadTo and at <= leadTo then to, tag = math.min(to, leadTo), dimTag end
            end
            if hangAt and hangAt >= at and hangAt < to then to = hangAt end
            piece(out, st, sub(plain, at, to), tag)
            if hangAt and to == hangAt then
                out[#out + 1] = " <HANG> "
                st.lineStart, st.space = true, false
                hangAt = nil
            end
            at = to + 1
        end
        if not nl then break end
        out[#out + 1] = " <LINE> "
        if kind == "sign" then out[#out + 1] = " <LEFT> " end
        st.lineStart, st.space = true, false
        pos, li = nl + 1, li + 1
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------------------------------------------
-- A document printed a row at a time.

-- The rows of a panel's chunks (Typing.align's src, and each chunk's row top): ends[r] = the reading's character that
-- ends the r-th row that holds one, top to bottom. Blank rows take no turn.
function Typing.rowEnds(src, lineY)
    local ends, lastY = {}, nil
    for c = 1, #src do
        local list = src[c]
        if #list > 0 then
            local y = lineY[c]
            if y ~= lastY then
                ends[#ends + 1] = ends[#ends] or 0
                lastY = y
            end
            if list[#list] > ends[#ends] then ends[#ends] = list[#list] end
        end
    end
    return ends
end

-- How far the print of a text in rows (ends: Typing.rowEnds) has got at second `t`, a row started every `step` seconds
-- and printed over `print` of them: the characters on (the row being printed has the part of its characters that its
-- time gives, from the left), whether it is over, and whether a row is being printed.
function Typing.printed(ends, t, step, print)
    local rows = #ends
    if rows == 0 or t >= rows * step then return nil, true, false end
    local r = Typing.rowsAt(t, rows, step)
    local before = ends[r - 1] or 0
    local f = print > 0 and (t - (r - 1) * step) / print + 1e-9 or 1
    if f >= 1 then return ends[r], false, false end
    return before + math.floor((ends[r] - before) * math.max(0, f)), false, true
end

-- The first chunk of each of those rows (the same rows as Typing.rowEnds).
function Typing.rowFirsts(src, lineY)
    local first, lastY = {}, nil
    for c = 1, #src do
        if #src[c] > 0 and lineY[c] ~= lastY then
            first[#first + 1] = c
            lastY = lineY[c]
        end
    end
    return first
end

-- How many of `count` rows have come on at second `t`, printed `step` seconds apart (the first at once).
function Typing.rowsAt(t, count, step)
    if t < 0 then return 0 end
    return math.min(count, math.floor(t / step + 1e-9) + 1)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Which characters of the panel's rows have come on.
--
-- The panel breaks the text into rows of its own ("chunks": the strings it draws, each at a place). The typing is
-- worked out on the characters of the text as read, so each character of a chunk is matched to the one it is: the
-- chunks hold the text's characters in order, less the spaces the panel dropped.

-- src[c][j] = the number of the reading's character that chunk c's j-th character is.
function Typing.align(plain, chunks)
    local src, p, total = {}, 1, #plain
    for c, chunk in ipairs(chunks) do
        local list = {}
        for j = 1, #chunk do
            local ch = sub(chunk, j, j)
            while p <= total and sub(plain, p, p) ~= ch do p = p + 1 end
            if p > total then p = total end
            list[j] = p
            p = p + 1
        end
        src[c] = list
    end
    return src
end

local Reveal = {}
Reveal.__index = Reveal

-- A reveal over the chunks (strings) of a panel, for the reading's plain text. `lines` is the table the panel draws
-- from: each of its entries is set to the part of the chunk that has come on.
function Typing.reveal(chunks, plain, lines)
    local o = setmetatable({ full = {}, pre = {}, from = 1, count = #chunks, lines = lines }, Reveal)
    for c, chunk in ipairs(chunks) do
        o.full[c] = chunk
        o.pre[c] = {}
        lines[c] = ""
    end
    o.src = Typing.align(plain, chunks)
    return o
end

-- How many of a chunk's characters are among the first `n` of the text: a binary search.
local function visible(list, n)
    local low, high = 0, #list
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if list[mid] <= n then low = mid else high = mid - 1 end
    end
    return low
end

-- The first `k` characters of chunk c, made once and kept: a frame makes no string once they are there.
function Reveal:prefix(c, k)
    local cache = self.pre[c]
    local text = cache[k]
    if not text then
        text = sub(self.full[c], 1, k)
        cache[k] = text
    end
    return text
end

-- The first `n` characters of the text have come on (n only grows): sets the panel's lines. Returns the chunk the typing
-- is at and how many of its characters show (the cursor goes after them), or nil when every chunk is whole.
function Reveal:show(n)
    local lines, src = self.lines, self.src
    local c = self.from
    while c <= self.count do
        local list = src[c]
        local len = #list
        if len == 0 or list[len] <= n then
            lines[c] = self.full[c]
            c = c + 1
            self.from = c
        else
            local k = visible(list, n)
            lines[c] = self:prefix(c, k)
            return c, k
        end
    end
    return nil
end

return Typing
