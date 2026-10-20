-- A call's lines as they play in the comms tab (SCENES.md 2): the text of each line made from the translations (the
-- greeting of the tier it plays at, the collection point's number, the late first crate's own lines, the words erased
-- first), the marks in it ({cut:N} the signal breaks up, {mute:N} nothing comes, {p:N} a pause), and the timeline: when
-- each character of a team line comes in, when the protagonist types, erases and sends, how long a line is left to be
-- read. Pure: `text(key, ...)` is passed in, and a moment of the timeline is worked out from the time alone, so the tab
-- draws a frame from `Script.at(timeline, t)` and nothing runs per character.
require "OperationAcorn/Core"
require "OperationAcorn/Story/CommsData"
local OA = OperationAcorn
local Data = OA.CommsData
local Script = {}
OA.CommsScript = Script

-- Speeds and beats, in characters a second and seconds (SCENES 2 '줄의 시간').
Script.OAK_CPS = 28          -- the team's line comes in evenly
Script.ME_CPS = 14           -- the protagonist types slower
-- A hand's typing, not a machine's: each word at its own speed (up to WORD_SPREAD faster or slower, fixed by its
-- letters), a gap between words, a longer one after the end of a clause inside a line.
Script.WORD_SPREAD = 0.2
Script.WORD_PAUSE = 0.12
Script.CLAUSE_PAUSE = 0.4
Script.CLAUSE_ENDS = { [","] = true, ["."] = true, ["?"] = true, ["!"] = true }
-- Words typed and taken back: the last letters come slower and slower (times a letter's time), the words sit whole
-- with the cursor blinking, are deleted a tap at a time, and the cursor blinks again while the next words are thought
-- of. A line of the data may hold its own (`stop`, `del`, `after`): the further the feeling turns between the erased
-- words and the sent ones, the longer they sit and the longer the thinking after.
Script.ERASE_SLOW = { 2, 3, 4.5 }
Script.ERASE_STOP = 1.2
Script.ERASE_CPS = 10
Script.ERASE_AFTER = 1.4
Script.SEND_AFTER = 0.7      -- the typed words sit whole on the input line a moment before they are sent
-- Reading: a line is read as it comes in, so from its first character to the next line it is given its characters at
-- the language's reading speed (subtitles' adult speeds: Korean 12 a second, Chinese and Japanese 9, the rest 17) and a
-- beat to take it in; once it is all there it stays at least READ_AFTER (the eyes reach its end). A new speaker's line
-- waits a TURN first. The pauses of the marks ({cut}, {mute}, {p}) are the scene's own, on top of the reading.
Script.READ_CPS = { KO = 12, CH = 9, CN = 9, TW = 9, JP = 9 }
Script.READ_CPS_OTHER = 17
Script.UNDERSTAND = 0.6
Script.READ_AFTER = 1.2
Script.TURN = 0.4             -- to the protagonist
Script.TURN_IN = 1.2          -- to the team: the line is open, its cursor blinks a few times before the words come

local function key(id, n, suffix)
    return "IGUI_OA_Comms_" .. id .. "_" .. tostring(n) .. (suffix or "")
end

-- A translation for the calls' text: a key without one is empty (the tests see that every key is there).
function Script.text(key, ...)
    local s = getText(key, ...)
    if s == key then return "" end
    return s
end

-- A text's characters, one each. The game's Lua (Kahlua) keeps a string as Java's characters, so a Hangul letter is
-- one place of it (string.byte gives its code, string.sub(s, i, i) the letter): no UTF-8 bytes to put together.
function Script.chars(s)
    local out = {}
    for i = 1, #s do out[i] = string.sub(s, i, i) end
    return out
end

-- Takes the marks out of a text: the plain characters (a list, one each) and the marks
-- { at = characters before it, cut | mute | p = seconds }.
function Script.parse(src)
    local chars, marks = {}, {}
    local i, len = 1, #src
    while i <= len do
        local kind, secs, stop = nil, nil, nil
        if string.sub(src, i, i) == "{" then
            local a, b, k, v = string.find(src, "^{(%a+):([%d%.]+)}", i)
            if a then kind, secs, stop = k, tonumber(v), b end
        end
        if kind then
            marks[#marks + 1] = { at = #chars, [kind] = secs }
            i = stop + 1
        else
            chars[#chars + 1] = string.sub(src, i, i)
            i = i + 1
        end
    end
    return chars, marks
end

-- The lines of an entry as played: { who, text (plain), chars, marks, erase (plain, or nil), s (seconds, noise and
-- mute), pause (a beat before the line, seconds), eraseStop, eraseCps, eraseAfter (the erased words' own pace) }. ctx = { text = function(key, ...), number = "0347", tier = the tier it plays at, late = the first crate was
-- late, order = function(entry): where an `ordered` entry stands among its branch's calls }.
function Script.lines(entry, ctx)
    local out = {}
    if entry.kind == "short" or entry.kind == "say" then
        local k = "IGUI_OA_Comms_" .. entry.id
        local src = ctx.text(k, ctx.number)
        -- an ordered call that comes after others of its branch has its own words when there are some (k_2, k_3)
        local n = entry.ordered and ctx.order and ctx.order(entry) or 1
        if n > 1 then
            local nth = ctx.text(k .. "_" .. tostring(n), ctx.number)
            if nth ~= "" and nth ~= k .. "_" .. tostring(n) then src = nth end
        end
        if entry.greet then src = Script.greeted(src, ctx) end
        local chars, marks = Script.parse(src)
        out[1] = { who = entry.kind == "say" and "say" or "oak", text = table.concat(chars), chars = chars, marks = marks }
        return out
    end
    for n, line in ipairs(entry.lines) do
        local who = line[1]
        if who == "noise" or who == "mute" then
            out[#out + 1] = { who = who, s = line.s, chars = {}, marks = {}, text = "" }
        else
            local k = key(entry.id, n, line.late and ctx.late and "_late" or nil)
            local src = ctx.text(k, ctx.number)
            if n == 1 and entry.greet then src = Script.greeted(src, ctx) end
            local chars, marks = Script.parse(src)
            local l = { who = who, text = table.concat(chars), chars = chars, marks = marks, pause = line.pause,
                cue = line.cue }
            if line.erase then
                l.erase = ctx.text(key(entry.id, n, "_x"), ctx.number)
                l.eraseStop, l.eraseCps, l.eraseAfter = line.stop, line.del, line.after
            end
            out[#out + 1] = l
        end
    end
    return out
end

-- A greeted line: the tier's greeting before it (1 to 4), or the text alone (5 to 8 open with the number, which the
-- text has; and every tier for a record that came after the air time was cut: ctx.greet false, Story.greets). A line
-- that is the greeting alone (empty) is the number without one.
function Script.greeted(src, ctx)
    local gk = ctx.greet ~= false and Data.GREETED[ctx.tier] and ("IGUI_OA_Story_Greeting_" .. tostring(ctx.tier)) or nil
    if gk then
        local g = ctx.text(gk)
        if src == "" then return g end
        return g .. " " .. src
    end
    if src == "" then return ctx.number .. "." end
    return src
end

-- The reading speed of a language (the game's: Translator's code, "KO", "EN", ...).
function Script.readCps(lang)
    if lang == nil then
        local ok, code = pcall(function() return tostring(Translator.getLanguage():name()) end)
        lang = ok and code or nil
    end
    return Script.READ_CPS[lang or ""] or Script.READ_CPS_OTHER
end

-- How long a line of `count` characters is left once it is all there, `shown` seconds after its first came in (or
-- began to be typed): the rest of its reading time, and at least READ_AFTER (or `after`).
function Script.readTime(count, shown, cps, after)
    return math.max(after or Script.READ_AFTER, count / (cps or Script.readCps()) + Script.UNDERSTAND - (shown or 0))
end

-- The protagonist typing characters a+1 to b of `chars` at `cps` as pieces of `kind` (n0 to n1 typed), through
-- `add(kind, seconds, n0, n1)`: each word at its speed, the gaps between words and after a clause as pieces that type
-- nothing; `slowing`: the last letters slow down (words about to be taken back).
function Script.typing(add, kind, chars, a, b, cps, slowing)
    local d = {}
    local i = a + 1
    while i <= b do
        local j = i
        while j < b and chars[j] ~= " " do j = j + 1 end
        local sum = 0
        for k = i, j do sum = sum + (string.byte(chars[k]) or 0) end
        local speed = cps * (1 + Script.WORD_SPREAD * (OA.remainder(sum, 5) / 2 - 1))
        for k = i, j do d[k] = 1 / speed end
        i = j + 1
    end
    if slowing then
        local slow = Script.ERASE_SLOW
        for k = 1, #slow do
            local at = b - #slow + k
            if at > a then d[at] = slow[k] / cps end
        end
    end
    local function gap(k)
        if k >= b or chars[k] ~= " " then return 0 end
        return Script.CLAUSE_ENDS[chars[k - 1] or ""] and Script.CLAUSE_PAUSE or Script.WORD_PAUSE
    end
    local n = a
    while n < b do
        local m = n + 1
        while m < b and d[m + 1] == d[n + 1] and gap(m) == 0 do m = m + 1 end
        add(kind, (m - n) * d[n + 1], n, m)
        if gap(m) > 0 then add(kind, gap(m), m, m) end
        n = m
    end
end

-- The timeline of a call's lines. Each line gets `t0` (it starts) and `t1` (the next line starts), and the pieces of
-- its time: { from, to, kind, n0, n1 } with kind "in" (the team's characters coming in, n0 to n1), "cut" (the signal
-- breaking up, n0 shown), "hold" (nothing moves), "type" / "erase" (the protagonist's input line: the words erased
-- first, n0 to n1 of them), "typeSend" (the words sent), "read" (all there, left to be read). `cps`: the reading speed
-- (Script.readCps, the game's language when not given). `pace`: another pace than the tab's, { oak, me (characters a
-- second), turn (to either speaker; turnIn to the team alone), after (READ_AFTER) }, each left out the tab's. A mark in the protagonist's words is a stop in the typing.
function Script.timeline(lines, cps, pace)
    cps = cps or Script.readCps()
    pace = pace or {}
    local oakCps, meCps = pace.oak or Script.OAK_CPS, pace.me or Script.ME_CPS
    local turn, after = pace.turn or Script.TURN, pace.after or Script.READ_AFTER
    local turnIn = pace.turnIn or pace.turn or Script.TURN_IN
    local t = 0
    local list = {}
    local last
    for i, l in ipairs(lines) do
        local pieces = {}
        local start = t
        local function add(kind, dur, n0, n1)
            if dur <= 0 then return end
            pieces[#pieces + 1] = { from = t, to = t + dur, kind = kind, n0 = n0, n1 = n1 }
            t = t + dur
        end
        local count = #l.chars
        local speech = l.who ~= "noise" and l.who ~= "mute"
        if speech and last and last ~= l.who then add("hold", l.who == "me" and turn or turnIn, 0, 0) end
        if speech then last = l.who end
        if l.pause then add("hold", l.pause, 0, 0) end
        if l.who == "noise" or l.who == "mute" then
            add("hold", l.s or 1)
        elseif l.who == "me" then
            if l.erase then
                local echars = Script.parse(l.erase)
                local ec = #echars
                Script.typing(add, "erasetype", echars, 0, ec, meCps, true)
                add("erasestop", l.eraseStop or Script.ERASE_STOP, ec, ec)
                add("erase", ec / (l.eraseCps or Script.ERASE_CPS), ec, 0)
                add("hold", l.eraseAfter or Script.ERASE_AFTER)
            end
            local n, typing = 0, t
            for _, m in ipairs(l.marks) do
                if m.at > n then Script.typing(add, "type", l.chars, n, m.at, meCps); n = m.at end
                add("type", m.cut or m.mute or m.p or 0, n, n)
            end
            if count > n then Script.typing(add, "type", l.chars, n, count, meCps) end
            add("type", Script.SEND_AFTER, count, count)
            add("read", Script.readTime(count, t - typing, cps, after), count, count)
        else
            -- the team's line, the marks where they fall
            local n = 0
            for _, m in ipairs(l.marks) do
                if m.at > n then add("in", (m.at - n) / oakCps, n, m.at); n = m.at end
                if m.cut then add("cut", m.cut, n, n)
                elseif m.mute then add("hold", m.mute, n, n)
                elseif m.p then add("hold", m.p, n, n) end
            end
            if count > n then add("in", (count - n) / oakCps, n, count) end
            add("read", Script.readTime(count, count / oakCps, cps, after), count, count)
        end
        list[i] = { line = l, t0 = start, t1 = t, pieces = pieces }
    end
    return { lines = list, total = t }
end

-- A moment of the timeline: { done = lines fully in the log before the current one, line = the current line's index (nil
-- after the end), shown = characters of it in the log (team lines), input = characters on the input line, inputOf =
-- "erase" | "text" | nil (whose characters), flicker = the signal is breaking up, phase = the piece's kind }.
function Script.at(tl, t)
    local lines = tl.lines
    for i, entry in ipairs(lines) do
        if t < entry.t1 then
            local st = { done = i - 1, line = i, shown = 0, input = 0 }
            for _, pc in ipairs(entry.pieces) do
                if t < pc.to then
                    local k = (t - pc.from) / (pc.to - pc.from)
                    local n = pc.n0 and math.floor(pc.n0 + (pc.n1 - pc.n0) * k + 1e-6) or 0
                    st.phase = pc.kind
                    if pc.kind == "in" or pc.kind == "cut" then
                        st.shown = n
                        st.flicker = pc.kind == "cut"
                    elseif pc.kind == "erasetype" or pc.kind == "erasestop" or pc.kind == "erase" then
                        st.input, st.inputOf = n, "erase"
                    elseif pc.kind == "type" then
                        st.input, st.inputOf = n, "text"
                    elseif pc.kind == "read" then
                        st.shown = #entry.line.chars
                    end
                    return st
                end
            end
            st.shown = #entry.line.chars
            return st
        end
    end
    return { done = #lines, line = nil, shown = 0, input = 0 }
end

-- The characters of a line that came between two looks at it (Script.at's states): `was` the counts of the last look
-- (a table kept by the caller, empty at first; updated to this look's), `emit(kind, from, to)` for each kind that
-- moved: "recv" the team's characters coming in (not a line put up whole as it is read), "key" the protagonist's
-- typed, "erase" erased. Counted from nothing as each line starts and as the input turns from the words erased to
-- the words sent. The last characters of a team's line may come between two looks, the second already in its reading.
local function coming(phase)
    return phase == "in" or phase == "cut"
end

function Script.charsSince(was, st, emit)
    if was.line ~= st.line then was.line, was.shown, was.input, was.inputOf, was.phase = st.line, 0, 0, nil, nil end
    if (coming(st.phase) or st.phase == "read" and coming(was.phase)) and st.shown ~= was.shown then
        emit("recv", was.shown, st.shown)
    end
    if st.inputOf then
        local from = st.inputOf == was.inputOf and was.input or 0
        if st.input > from then
            emit("key", from, st.input)
        elseif st.input < from then
            emit("erase", st.input, from)
        end
    end
    was.shown, was.input, was.inputOf, was.phase = st.shown, st.input, st.inputOf, st.phase
end

-- A line as the record keeps it: the marks of a break as "[송신 중단 N초]" (`cutText(seconds)`), the rest plain.
function Script.recordText(l, cutText)
    local parts, n = {}, 0
    for _, m in ipairs(l.marks) do
        if m.cut or m.mute then
            if m.at > n then parts[#parts + 1] = table.concat(l.chars, "", n + 1, m.at) end
            n = m.at
            parts[#parts + 1] = cutText(m.cut or m.mute)
            if m.at < #l.chars then parts[#parts + 1] = " " end
        end
    end
    if #l.chars > n then parts[#parts + 1] = table.concat(l.chars, "", n + 1, #l.chars) end
    return table.concat(parts)
end

return Script
