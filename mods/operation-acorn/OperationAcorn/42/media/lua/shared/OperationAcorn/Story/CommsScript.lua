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

-- Speeds and beats, in characters a second and seconds (가안: SCENES 2 '줄의 시간'; set in the game).
Script.OAK_CPS = 28          -- the team's line comes in evenly
Script.ME_CPS = 14           -- the protagonist types slower
Script.ERASE_CPS = 22        -- and deletes faster
Script.READ_CPS = 12         -- the time a line is left to be read: its characters at this rate ...
Script.READ_MIN = 1.5        -- ... at least this long ...
Script.BEAT = 0.5            -- ... and a half beat more before the next line
Script.ERASE_STOP = 0.8      -- the typed words sit with the cursor blinking before they are deleted
Script.ERASE_AFTER = 0.6     -- a beat after the deleting, before the words that are sent

local function key(id, n, suffix)
    return "IGUI_OA_Comms_" .. id .. "_" .. tostring(n) .. (suffix or "")
end

-- Takes the marks out of a text: the plain characters (a list, so that Hangul counts one a character) and the marks
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
            -- one UTF-8 character
            local c = string.byte(src, i)
            local n = c >= 240 and 4 or c >= 224 and 3 or c >= 192 and 2 or 1
            chars[#chars + 1] = string.sub(src, i, i + n - 1)
            i = i + n
        end
    end
    return chars, marks
end

-- The lines of an entry as played: { who, text (plain), chars, marks, erase (plain, or nil), s (seconds, noise and
-- mute) }. ctx = { text = function(key, ...), number = "0347", tier = the tier it plays at, late = the first crate was
-- late }.
function Script.lines(entry, ctx)
    local out = {}
    if entry.kind == "short" or entry.kind == "say" then
        local src = ctx.text("IGUI_OA_Comms_" .. entry.id, ctx.number)
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
            local l = { who = who, text = table.concat(chars), chars = chars, marks = marks }
            if line.erase then l.erase = ctx.text(key(entry.id, n, "_x"), ctx.number) end
            out[#out + 1] = l
        end
    end
    return out
end

-- A greeted line: the tier's greeting before it (1 to 4), or the text alone (5 to 8 open with the number, which the
-- text has). A line that is the greeting alone (empty) is the number without one.
function Script.greeted(src, ctx)
    local gk = Data.GREETED[ctx.tier] and ("IGUI_OA_Story_Greeting_" .. tostring(ctx.tier)) or nil
    if gk then
        local g = ctx.text(gk)
        if src == "" then return g end
        return g .. " " .. src
    end
    if src == "" then return ctx.number .. "." end
    return src
end

-- How long a line is left to be read once it is all there.
function Script.readTime(count)
    return math.max(Script.READ_MIN, count / Script.READ_CPS) + Script.BEAT
end

-- The timeline of a call's lines. Each line gets `t0` (it starts) and `t1` (the next line starts), and the pieces of
-- its time: { from, to, kind, n0, n1 } with kind "in" (the team's characters coming in, n0 to n1), "cut" (the signal
-- breaking up, n0 shown), "hold" (nothing moves), "type" / "erase" (the protagonist's input line: the words erased
-- first, n0 to n1 of them), "typeSend" (the words sent), "read" (all there, left to be read).
function Script.timeline(lines)
    local t = 0
    local list = {}
    for i, l in ipairs(lines) do
        local pieces = {}
        local start = t
        local function add(kind, dur, n0, n1)
            if dur <= 0 then return end
            pieces[#pieces + 1] = { from = t, to = t + dur, kind = kind, n0 = n0, n1 = n1 }
            t = t + dur
        end
        local count = #l.chars
        if l.who == "noise" or l.who == "mute" then
            add("hold", l.s or 1)
        elseif l.who == "me" then
            if l.erase then
                local ec = #(Script.parse(l.erase))
                add("erasetype", ec / Script.ME_CPS, 0, ec)
                add("erasestop", Script.ERASE_STOP, ec, ec)
                add("erase", ec / Script.ERASE_CPS, ec, 0)
                add("hold", Script.ERASE_AFTER)
            end
            add("type", count / Script.ME_CPS, 0, count)
            add("read", Script.readTime(count), count, count)
        else
            -- the team's line, the marks where they fall
            local n = 0
            for _, m in ipairs(l.marks) do
                if m.at > n then add("in", (m.at - n) / Script.OAK_CPS, n, m.at); n = m.at end
                if m.cut then add("cut", m.cut, n, n)
                elseif m.mute then add("hold", m.mute, n, n)
                elseif m.p then add("hold", m.p, n, n) end
            end
            if count > n then add("in", (count - n) / Script.OAK_CPS, n, count) end
            add("read", Script.readTime(count), count, count)
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
