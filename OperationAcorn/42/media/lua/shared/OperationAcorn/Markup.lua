-- The markup of typed texts (DESIGN-terminal 14 F2): the same small language the extension API's text.show reads with
-- `markup = true` (PZ Extension API, docs/design.md, "Typing, markup and fitting a width"), read here by Lua for
-- the texts the terminal's own window types, and for the places that show such a text plain.
--
--   {p:seconds}    a pause before the next character (0 to 30, up to three decimals)
--   {s:rate}       from the next character on, `rate` characters a second (1 to 1000); {s} the text's own speed again
--   {c:RRGGBB}...{/c}  the characters between are in this colour (no nesting)
--   {{ and }}      one { and one }
--
-- Anything else in braces is an error here as it is in the API (a text that passes here passes there, which is what the
-- check in tests/unit/story_typing_test.lua is for). Reading is done once when a text is shown; what the window draws
-- each frame is a character count looked up in the table of times this makes (Markup.count), with no parsing.
-- Strings are the game's: one character is one UTF-16 unit, a Hangul syllable one, as in the API.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Markup = {}
OA.Markup = Markup

Markup.DEFAULT_SPEED = 30      -- characters a second, as the API's
Markup.MAX_SECONDS = 300       -- the longest a text may take to type
Markup.MAX_LENGTH = 512        -- the API's longest text, tags included

local sub, find = string.sub, string.find

-- The seconds of a pause tag's body ("0.6", "3"), or nil.
local function pauseSeconds(body)
    if not (find(body, "^%d+$") or find(body, "^%d+%.%d%d?%d?$")) then return nil end
    local seconds = tonumber(body)
    if seconds and seconds >= 0 and seconds <= 30 then return seconds end
    return nil
end

local function rateOf(body)
    if not find(body, "^%d+$") then return nil end
    local rate = tonumber(body)
    if rate and rate >= 1 and rate <= 1000 then return rate end
    return nil
end

local function hexColour(body)
    if not find(body, "^%x%x%x%x%x%x$") then return nil end
    return tonumber(sub(body, 1, 2), 16) / 255, tonumber(sub(body, 3, 4), 16) / 255, tonumber(sub(body, 5, 6), 16) / 255
end

-- Reads a text. Returns the reading, or nil and what is wrong (the tag and its place in the text):
--   plain   the characters that show, as a string (line ends are "\n")
--   n       how many there are
--   times   times[i] = the second the i-th character comes on (the first at 0; a line end comes with the next character)
--   total   the second the typing is over (the last character's turn and any pause after it)
--   pauses  the seconds of pause in all
--   runs    the colour runs, { { from, to, r, g, b } }, character numbers (1-based, both included)
function Markup.parse(text, speed)
    if type(text) ~= "string" then return nil, "not a text" end
    speed = speed or Markup.DEFAULT_SPEED
    local chars, times, runs = {}, {}, {}
    local n, at, rate, pauses = 0, 0, speed, 0
    local open
    local i, len = 1, #text
    while i <= len do
        local ch = sub(text, i, i)
        if ch == "{" then
            if sub(text, i + 1, i + 1) == "{" then
                ch = "{"
                i = i + 2
            else
                local close = find(text, "}", i + 1, true)
                if not close then return nil, "{ with no } after it at " .. i end
                local tag = sub(text, i + 1, close - 1)
                local name, body = string.match(tag, "^(%a+):(.*)$")
                if tag == "s" then
                    rate = speed
                elseif tag == "/c" then
                    if not open then return nil, "{/c} with no {c:...} open at " .. i end
                    if open.to >= open.from then runs[#runs + 1] = open end
                    open = nil
                elseif name == "p" then
                    local seconds = pauseSeconds(body)
                    if not seconds then return nil, "bad pause {" .. tag .. "} at " .. i end
                    at = at + seconds
                    pauses = pauses + seconds
                elseif name == "s" then
                    local value = rateOf(body)
                    if not value then return nil, "bad speed {" .. tag .. "} at " .. i end
                    rate = value
                elseif name == "c" then
                    local r, g, b = hexColour(body)
                    if not r then return nil, "bad colour {" .. tag .. "} at " .. i end
                    if open then return nil, "colours do not nest: {" .. tag .. "} at " .. i end
                    open = { from = n + 1, to = n, r = r, g = g, b = b }
                else
                    return nil, "unknown tag {" .. tag .. "} at " .. i
                end
                i = close + 1
                ch = nil
            end
        elseif ch == "}" then
            if sub(text, i + 1, i + 1) ~= "}" then return nil, "} with no { before it at " .. i end
            i = i + 2
        else
            i = i + 1
        end
        if ch then
            n = n + 1
            chars[n] = ch
            times[n] = at
            if ch ~= "\n" then at = at + 1 / rate end
            if open then open.to = n end
        end
    end
    if open then return nil, "{c:...} never closed" end
    if n == 0 then return nil, "no character left once the tags are taken out" end
    return { plain = table.concat(chars), n = n, times = times, total = at, pauses = pauses, runs = runs }
end

-- A text as a plain one: the tags taken out, the braces unescaped. A text that is not well-formed has the tags that are
-- taken out and the rest left as written, so that a faulty text still reads.
function Markup.strip(text)
    if type(text) ~= "string" then return text end
    if not find(text, "[{}]") then return text end
    local read = Markup.parse(text)
    if read then return read.plain end
    local s = string.gsub(text, "{p:[%d%.]*}", "")
    s = string.gsub(s, "{s:%d*}", "")
    s = string.gsub(s, "{s}", "")
    s = string.gsub(s, "{c:%x%x%x%x%x%x}", "")
    s = string.gsub(s, "{/c}", "")
    s = string.gsub(s, "{{", "{")
    s = string.gsub(s, "}}", "}")
    return s
end

-- How many characters have come on at second `t` of the typing: the last whose time is not after it (0 before the
-- first). A binary search over the table the reading made.
function Markup.count(read, t)
    local times = read.times
    if t < 0 or read.n == 0 then return 0 end
    if t >= read.total then return read.n end
    local low, high = 0, read.n
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if times[mid] <= t then low = mid else high = mid - 1 end
    end
    return low
end

-- The width of a text in ems, near enough: a character of the Latin range is narrower than a whole em (Hangul, Han and kana
-- take a whole one).
function Markup.width(text)
    local w = 0
    for i = 1, #text do
        w = w + (string.byte(text, i) < 128 and 0.55 or 1)
    end
    return w
end

-- A text's first sentences, plain, in no more than `limit` ems (Markup.width), cut at a word with "..." where a sentence
-- is too long to fit or a short one stands alone. What a title's line under it can hold of a radio line.
function Markup.lead(text, limit)
    local plain = Markup.strip(text or "")
    local first = string.match(plain, "^[^\n]*") or plain
    local len = #first
    local ends, i = {}, 1
    while i <= len do
        local ch = sub(first, i, i)
        if (ch == "." or ch == "!" or ch == "?") and (i == len or sub(first, i + 1, i + 1) == " ") then
            ends[#ends + 1] = i
            i = i + 1
        end
        i = i + 1
    end
    if #ends == 0 or ends[#ends] ~= len then ends[#ends + 1] = len end
    local cut = ends[1]
    for k = 2, #ends do
        if Markup.width(sub(first, 1, ends[k])) <= limit then cut = ends[k] else break end
    end
    -- Sentences that fit and fill at least half the line; a lone short one (a call sign) is carried on into the words
    -- of the next, cut at a word.
    local used = Markup.width(sub(first, 1, cut))
    if used <= limit and (cut >= len or used >= limit / 2) then return sub(first, 1, cut) end
    local fits = 0
    while fits < len and Markup.width(sub(first, 1, fits + 1)) <= limit do fits = fits + 1 end
    if fits >= len then return first end
    local head = sub(first, 1, fits)
    local space
    for j = #head, 2, -1 do
        if sub(head, j, j) == " " then space = j; break end
    end
    return (space and sub(head, 1, space - 1) or head) .. "..."
end

-- A plain text broken into rows of no more than `limit` at spaces (a word longer than that stays whole): characters, or
-- what `measure(row)` says (a width in pixels). For the plain show of a scene that an API without wrapping gets.
local PARAGRAPHS = { paragraphs = true }
function Markup.wrap(text, limit, measure)
    return OA.wrap(text, limit, measure or string.len, PARAGRAPHS)
end

return Markup
