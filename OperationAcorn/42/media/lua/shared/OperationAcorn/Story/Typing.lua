-- Typing inside the terminal (DESIGN-terminal 14 F2, mockups/terminal/story-presentation-ideas.md): the speeds, the clock
-- a text is typed by and how it is kept in the record, and the pieces the window's text panel (client/Story/TypedText)
-- is made of, which are here so that they can be tested without the game. Nothing in this file touches the game.
--
-- How a text is typed: the window counts the time it has shown the text (real seconds, from the differences of
-- getTimestampMs, which go on while the game is paused) and asks Markup.count how many characters have come on by then;
-- a frame in which the count has not changed does nothing more. A text is typed every time it is shown, at the same
-- speed as the first time. What the record keeps of each one is how far the player has SEEN it, so that a click can show
-- that much at once and never more:
--   { seen = the furthest character that has come on, in any showing (a character count, so that it holds on a terminal
--     of the other speed),
--     done = true once it was seen to its end (a click then shows all of it),
--     start, t = the world age in hours and the seconds typed, of a showing left half way }
-- A text left half way is shown again by its kind's way (Typing.RESUME): a scene starts over, a document goes on from
-- where it was with the game time that has passed turned into seconds of the terminal's own work, so a document left for
-- a night's sleep is all typed when the window opens. Older records kept `true` (typed to its end) or { start, t } (the
-- seconds typed): they are read as seen to the end, and as seen as far as that clock had come (Typing.seenOf). An entry
-- with no state at all was shown whole before, so it counts as seen to the end.
require "OperationAcorn/Core"
require "OperationAcorn/Markup"
local OA = OperationAcorn
local Markup = OA.Markup
local Typing = {}
OA.Typing = Typing

local sub, find = string.sub, string.find

-- The characters a second of the two kinds of text and the two terminals (the crude one quick, the field terminal a little
-- slower and smoother): a scene (a radio copy, which carries its pauses) at the speed of a radio read aloud, a document
-- (a request copy, a guide) as fast as it can be followed. A first guess, to be set in the game.
Typing.SPEED = {
    scene = { crude = 30, field = 25 },
    document = { crude = 80, field = 60 },
}
-- What a kind of text does when it is shown again after being left half typed: "restart" types it from the beginning
-- (a scene keeps its pauses and its breath; a click then brings it to the furthest point seen), "resume" goes on from
-- where it was (a document: the terminal went on printing while the player was away). A kind of text that is typed
-- later (a mission briefing, a special request's offer) chooses its way here.
Typing.RESUME = { scene = "restart", document = "resume" }

-- The scenes' longest total pause (seconds): a story scene does not make the player wait longer than this.
Typing.MAX_PAUSES = 6

-- Which kind a folder group is, when its entries are typed. The others (field papers, manifests) are read from items or
-- arrive with the crate, and are not typed here.
Typing.KIND_OF_GROUP = { radio = "scene", request = "document", research = "document" }

-- The speed for a kind on a terminal ("crude" or "field"); nil for a kind that is not typed.
function Typing.speed(kind, tier)
    local speeds = Typing.SPEED[kind]
    if not speeds then return nil end
    return speeds[tier] or speeds.crude
end

-- The real seconds of one game hour at a day of `minutesPerDay` real minutes.
function Typing.secondsPerHour(minutesPerDay)
    return minutesPerDay * 60 / 24
end

-- Where the clock of a text stands when the window shows it, in seconds typed: 0 for a kind that starts over
-- (Typing.RESUME) and for a text with nothing left half way; else where the last showing was left, with the game time
-- that has passed turned into seconds of the terminal's own work. `hours` is the world age now.
function Typing.start(state, hours, minutesPerDay, kind)
    if Typing.RESUME[kind] ~= "resume" or type(state) ~= "table" then return 0 end
    local clock = tonumber(state.t)
    if not clock then return 0 end
    if state.start and hours and minutesPerDay and minutesPerDay > 0 then
        clock = clock + math.max(0, hours - state.start) * Typing.secondsPerHour(minutesPerDay)
    end
    return clock
end

-- How far a text has been seen, in characters of its reading (Markup.parse): all of it for a state of `true` or done, and
-- for an entry with no state (it was shown whole); the record's own count otherwise. An old { start, t } kept the clock
-- only: the characters that had come on by it.
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
-- text seen to its end stays so.
function Typing.keep(old, seen, done, clock, hours)
    local was = type(old) == "table" and old or nil
    local state = { seen = math.max(was and tonumber(was.seen) or 0, seen or 0) }
    if old == true or (was and was.done) or done then state.done = true end
    if clock then state.start, state.t = hours, clock end
    return state
end

-- Of two states of one entry (the record's, and what this window kept since, which may be the newer): the one to go by.
-- What the record has of being seen to the end counts either way.
function Typing.latest(recorded, kept)
    if kept == nil then return recorded end
    local done = recorded == true or (type(recorded) == "table" and recorded.done)
    if done and not kept.done then
        return { seen = kept.seen, start = kept.start, t = kept.t, done = true }
    end
    return kept
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
    end
    out[#out + 1] = escape(body)
    st.lineStart = false
    st.space = find(text, "%s$") ~= nil
    -- A piece that follows another of the same colour on a line cannot happen (a line end comes between).
end

local function segment(out, st, text, rgb)
    local from = 1
    while true do
        local nl = find(text, "\n", from, true)
        piece(out, st, sub(text, from, nl and nl - 1 or #text), rgb)
        if not nl then return end
        out[#out + 1] = " <LINE> "
        st.lineStart, st.space = true, false
        from = nl + 1
    end
end

-- The text for an ISRichTextPanel from a reading (Markup.parse): the characters in colour, the line ends as <LINE>, in
-- the colour `c` ({ r, g, b }, 0 to 1) where the text has none of its own.
function Typing.rich(read, c)
    local default = rgbTag(c[1], c[2], c[3])
    local out = { " <TEXT>", default }
    local st = { rgb = default, lineStart = true, space = false }
    local plain, pos = read.plain, 1
    for _, run in ipairs(read.runs) do
        if run.from > pos then segment(out, st, sub(plain, pos, run.from - 1), default) end
        segment(out, st, sub(plain, run.from, run.to), rgbTag(run.r, run.g, run.b))
        pos = run.to + 1
    end
    if pos <= #plain then segment(out, st, sub(plain, pos), default) end
    return table.concat(out)
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
