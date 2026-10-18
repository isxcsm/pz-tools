-- A call's lines and their timeline (Story/CommsScript).
require "OperationAcorn/Core"
require "OperationAcorn/Story/CommsScript"
local OA = OperationAcorn
local Script, Data = OA.CommsScript, OA.CommsData

local TEXTS = {
    IGUI_OA_Story_Greeting_1 = "GREET1.",
    IGUI_OA_Comms_S1_1 = "%1, BOX.",
    IGUI_OA_Comms_S1_8 = "{cut:2}NO LANDING.",
    IGUI_OA_Comms_S1_11 = "OK.",
    IGUI_OA_Comms_S1_11_x = "WHO",
    IGUI_OA_Comms_S0_13 = "BOX ONLY?",
    IGUI_OA_Comms_S0_13_x = "JOK",
    IGUI_OA_Comms_S0_10 = "DROP.",
    IGUI_OA_Comms_S0_10_late = "DROP. LATE.",
    IGUI_OA_Comms_S4B_1 = "",
    IGUI_OA_Comms_s1_bedding = "%1, BEDDING.",
}
local function text(key, ...)
    local s = TEXTS[key] or key
    local args = { ... }
    return (string.gsub(s, "%%(%d)", function(d) return args[tonumber(d)] or "" end))
end
local function ctx(tier, late) return { text = text, number = "0347", tier = tier, late = late } end

test("marks come out of a text where they fall, a Hangul letter (one place of a Kahlua string) one a character", function()
    local chars, marks = Script.parse("AB{cut:2}C{p:0.5}" .. string.char(44032))
    eq(#chars, 4)
    eq(chars[4], string.char(44032))
    eq(#marks, 2)
    eq(marks[1].at, 2)
    eq(marks[1].cut, 2)
    eq(marks[2].at, 3)
    eq(marks[2].p, 0.5)
end)

test("a greeted line opens with the tier's greeting, from the fifth tier with the number alone", function()
    local lines = Script.lines(Data.BY_ID.S1, ctx(1))
    eq(lines[1].text, "GREET1. 0347, BOX.")
    eq(Script.lines(Data.BY_ID.S1, ctx(5))[1].text, "0347, BOX.")
    eq(Script.lines(Data.BY_ID.S4B, ctx(5))[1].text, "0347.", "the greeting alone becomes the number")
end)

test("the late first crate has lines of its own, an erased line its erased words", function()
    eq(Script.lines(Data.BY_ID.S0, ctx(0, true))[10].text, "DROP. LATE.")
    eq(Script.lines(Data.BY_ID.S0, ctx(0, false))[10].text, "DROP.")
    local l = Script.lines(Data.BY_ID.S1, ctx(1))[11]
    eq(l.text, "OK.")
    eq(l.erase, "WHO")
    eq(Script.lines(Data.BY_ID.s1_bedding, ctx(6))[1].text, "0347, BEDDING.")
end)

test("the timeline: a team line comes in, breaks up at its mark, and is left to be read", function()
    local l = Script.lines(Data.BY_ID.S1, ctx(1))[8]
    local tl = Script.timeline({ l }, 12)
    local count = #l.chars
    near(tl.total, 2 + count / Script.OAK_CPS + Script.readTime(count, count / Script.OAK_CPS, 12), 1e-6)
    local st = Script.at(tl, 1)
    eq(st.flicker, true, "breaking up first")
    eq(st.shown, 0)
    st = Script.at(tl, 2 + 3 / Script.OAK_CPS + 0.001)
    eq(st.shown, 3)
    eq(st.flicker, false)
    st = Script.at(tl, tl.total + 1)
    eq(st.line, nil)
    eq(st.done, 1)
end)

test("reading: a line is given its characters at the language's speed and a beat from its first character, and stays a while once all there", function()
    eq(Script.readCps("KO"), 12)
    eq(Script.readCps("JP"), 9)
    eq(Script.readCps("EN"), 17)
    local function line(who, n)
        local chars = {}
        for i = 1, n do chars[i] = "x" end
        return { who = who, text = table.concat(chars), chars = chars, marks = {} }
    end
    -- 60 characters in Korean: 5 s to read and 0.6 to take in, from the first character
    local tl = Script.timeline({ line("oak", 60) }, 12)
    near(tl.total, 60 / 12 + Script.UNDERSTAND, 1e-6)
    -- 6 characters come in fast: still READ_AFTER once all there
    tl = Script.timeline({ line("oak", 6) }, 12)
    near(tl.total, 6 / Script.OAK_CPS + Script.READ_AFTER, 1e-6)
    -- the same words take more characters in English, read faster
    near(Script.timeline({ line("oak", 150) }, 17).total, 150 / 17 + Script.UNDERSTAND, 1e-6)
    -- a new speaker waits a turn; the same one does not
    local two = Script.timeline({ line("oak", 60), line("me", 6) }, 12)
    near(two.lines[2].t0, two.lines[1].t1)
    eq(two.lines[2].pieces[1].kind, "hold")
    near(two.lines[2].pieces[1].to - two.lines[2].pieces[1].from, Script.TURN, 1e-9)
    -- to the team the line opens longer (its cursor blinks a few times first)
    local back = Script.timeline({ line("me", 6), line("oak", 6) }, 12)
    eq(back.lines[2].pieces[1].kind, "hold")
    near(back.lines[2].pieces[1].to - back.lines[2].pieces[1].from, Script.TURN_IN, 1e-9)
    local same = Script.timeline({ line("oak", 60), line("oak", 6) }, 12)
    eq(same.lines[2].pieces[1].kind, "in")
end)

-- The pieces of a line's timeline of one kind, and when the first piece of another kind starts.
local function pieces(entry, kind)
    local out = {}
    for _, pc in ipairs(entry.pieces) do if pc.kind == kind then out[#out + 1] = pc end end
    return out
end

test("an erased line: typed slower at its end, held, deleted a tap at a time, a beat, then the words that are sent", function()
    local l = Script.lines(Data.BY_ID.S0, ctx(0))[13]
    eq(l.eraseStop, nil, "this one at the default pace")
    local tl = Script.timeline({ l })
    local typed = pieces(tl.lines[1], "erasetype")
    eq(typed[#typed].n1, 3)
    local function per(pc) return (pc.to - pc.from) / (pc.n1 - pc.n0) end
    for i = 2, #typed do truthy(per(typed[i]) > per(typed[i - 1]), "each of the last letters slower") end
    local stop = pieces(tl.lines[1], "erasestop")[1]
    near(stop.to - stop.from, Script.ERASE_STOP, 1e-9)
    local st = Script.at(tl, (stop.from + stop.to) / 2)
    eq(st.input, 3, "held whole")
    eq(st.inputOf, "erase")
    local erase = pieces(tl.lines[1], "erase")[1]
    near(erase.from, stop.to, 1e-9)
    near(erase.to - erase.from, 3 / Script.ERASE_CPS, 1e-9)
    eq(Script.at(tl, erase.from + 1.5 / Script.ERASE_CPS).input, 1, "a tap at a time")
    local think = pieces(tl.lines[1], "hold")[1]
    near(think.from, erase.to, 1e-9)
    near(think.to - think.from, Script.ERASE_AFTER, 1e-9)
    st = Script.at(tl, pieces(tl.lines[1], "type")[1].to - 0.001)
    eq(st.inputOf, "text")
end)

test("an erased line of its own pace: the words sit longer, go slower, and the thinking after is longer", function()
    local l = Script.lines(Data.BY_ID.S9, ctx(8))[6]
    eq(l.eraseStop, 2.2)
    local tl = Script.timeline({ l })
    local stop = pieces(tl.lines[1], "erasestop")[1]
    near(stop.to - stop.from, 2.2, 1e-9)
    local erase = pieces(tl.lines[1], "erase")[1]
    near(erase.to - erase.from, #Script.parse(l.erase) / 5, 1e-9)
    local think = pieces(tl.lines[1], "hold")[1]
    near(think.from, erase.to, 1e-9)
    near(think.to - think.from, 2.6, 1e-9)
end)

test("a line's pause: a beat before it, after the turn, the cursor blinking on an empty input line", function()
    local lines = Script.lines(Data.BY_ID.S1, ctx(1))
    eq(lines[7].pause, 2)
    local tl = Script.timeline({ lines[6], lines[7] })
    local second = tl.lines[2]
    eq(second.pieces[1].kind, "hold")
    near(second.pieces[1].to - second.pieces[1].from, 2, 1e-9)
    local st = Script.at(tl, second.pieces[1].from + 1)
    eq(st.line, 2)
    eq(st.input, 0)
    eq(st.phase, "hold")
end)

test("every erased line's own pace is longer than the default, and every pause a beat of a few seconds", function()
    for _, e in ipairs(Data.ENTRIES) do
        for n, line in ipairs(e.lines or {}) do
            local where = e.id .. " " .. n
            if line.stop then truthy(line.erase and line.stop >= Script.ERASE_STOP, where) end
            if line.after then truthy(line.erase and line.after >= Script.ERASE_AFTER, where) end
            if line.del then truthy(line.erase and line.del <= Script.ERASE_CPS, where) end
            if line.pause then truthy(line.pause > 0 and line.pause <= 3, where) end
        end
    end
end)

test("a hand's typing: a word at its own speed, a gap between words, a longer one after a clause", function()
    local chars = Script.parse("AB CD, EF")
    local got = {}
    Script.typing(function(kind, dur, n0, n1) got[#got + 1] = { dur = dur, n0 = n0, n1 = n1 } end,
        "type", chars, 0, #chars, 10)
    -- AB and its space, a gap; CD, and its space, a clause's gap; EF
    eq(#got, 5)
    eq(got[1].n1, 3)
    near(got[2].dur, Script.WORD_PAUSE, 1e-9)
    eq(got[2].n0, got[2].n1)
    eq(got[3].n1, 7)
    near(got[4].dur, Script.CLAUSE_PAUSE, 1e-9)
    eq(got[5].n1, 9)
    for _, i in ipairs({ 1, 3, 5 }) do
        local per = got[i].dur / (got[i].n1 - got[i].n0)
        truthy(per >= 1 / (10 * (1 + Script.WORD_SPREAD)) - 1e-9 and per <= 1 / (10 * (1 - Script.WORD_SPREAD)) + 1e-9)
    end
end)

test("the record writes a break as its words and keeps the rest plain", function()
    local l = Script.lines(Data.BY_ID.S1, ctx(1))[8]
    eq(Script.recordText(l, function(s) return "[CUT " .. s .. "]" end), "[CUT 2] NO LANDING.")
end)

test("every line of every call has its text in both languages", function()
    local function load(lang)
        local src = readfile("OperationAcorn/42/media/lua/shared/Translate/" .. lang .. "/IG_UI.json")
        truthy(src, lang)
        return src
    end
    for _, lang in ipairs({ "KO", "EN" }) do
        local src = load(lang)
        local function has(k) return string.find(src, '"' .. k .. '"', 1, true) ~= nil end
        for _, e in ipairs(Data.ENTRIES) do
            if e.kind == "short" or e.kind == "say" then
                truthy(has("IGUI_OA_Comms_" .. e.id), lang .. " " .. e.id)
            else
                for n, line in ipairs(e.lines) do
                    if line[1] == "oak" or line[1] == "me" then truthy(has("IGUI_OA_Comms_" .. e.id .. "_" .. n), lang .. " " .. e.id .. " " .. n) end
                    if line.erase then truthy(has("IGUI_OA_Comms_" .. e.id .. "_" .. n .. "_x"), lang .. " " .. e.id .. " " .. n .. "x") end
                    if line.late then truthy(has("IGUI_OA_Comms_" .. e.id .. "_" .. n .. "_late"), lang .. " late") end
                end
                truthy(has("IGUI_OA_Comms_Scene_" .. e.id), lang .. " name " .. e.id)
            end
        end
        for _, id in ipairs(Data.AFTER_SAYS) do truthy(has("IGUI_OA_Comms_" .. id), lang .. " " .. id) end
    end
end)

test("the calls' lines carry only the comms tab's marks, each with its seconds", function()
    local KNOWN = { cut = true, mute = true, p = true }
    for _, lang in ipairs({ "KO", "EN" }) do
        local src = readfile("OperationAcorn/42/media/lua/shared/Translate/" .. lang .. "/IG_UI.json")
        for key, value in string.gmatch(src, '"(IGUI_OA_Comms_[^"]+)":%s*"([^"]*)"') do
            for mark in string.gmatch(value, "{([^}]*)}") do
                local kind, secs = string.match(mark, "^(%a+):([%d%.]+)$")
                truthy(kind and KNOWN[kind] and tonumber(secs) ~= nil, lang .. " " .. key .. " {" .. mark .. "}")
            end
            local plain = string.gsub(value, "{[^}]*}", "")
            eq(string.find(plain, "[{}]"), nil, lang .. " " .. key .. " has a brace that is no mark")
        end
    end
end)

test("the protagonist stops typing at a mark; a call on the spot has its own pace", function()
    local chars, marks = Script.parse("AB{p:2}CD")
    local me = { who = "me", text = table.concat(chars), chars = chars, marks = marks }
    local tl = Script.timeline({ me }, 12)
    local typed = pieces(tl.lines[1], "type")
    local ab, stop = typed[1], typed[2]
    eq(ab.n1, 2)
    near(stop.to - stop.from, 2, 1e-9)
    local st = Script.at(tl, stop.from + 1)
    eq(st.phase, "type")
    eq(st.input, 2, "held at the mark")
    st = Script.at(tl, typed[3].to - 0.001)
    eq(st.input, 3, "typing again after it")
    local typing = typed[#typed].to
    near(typed[#typed].to - typed[#typed].from, Script.SEND_AFTER, 1e-9)
    st = Script.at(tl, typing - Script.SEND_AFTER / 2)
    eq(st.phase, "type", "typed whole, not sent yet")
    eq(st.input, 4)
    eq(Script.at(tl, typing + 0.001).phase, "read", "then sent")
    near(tl.total, typing + Script.readTime(4, typing, 12), 1e-6)
    local oak = { who = "oak", text = "XY", chars = { "X", "Y" }, marks = {} }
    local slow = Script.timeline({ oak, me }, 12, { oak = 4, me = 2, turn = 1.5, after = 3 })
    near(slow.lines[1].t1, 2 / 4 + 3, 1e-6)
    near(slow.lines[2].pieces[1].to - slow.lines[2].pieces[1].from, 1.5, 1e-9)
    local per = (slow.lines[2].pieces[2].to - slow.lines[2].pieces[2].from) / 2
    truthy(per >= 1 / (2 * (1 + Script.WORD_SPREAD)) - 1e-9 and per <= 1 / (2 * (1 - Script.WORD_SPREAD)) + 1e-9,
        "the call's own typing speed")
end)
