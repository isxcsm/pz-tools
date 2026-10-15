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
    IGUI_OA_Comms_S0_4 = "ARMY.",
    IGUI_OA_Comms_S0_4_late = "ARMY. LATE.",
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
    eq(Script.lines(Data.BY_ID.S0, ctx(0, true))[4].text, "ARMY. LATE.")
    eq(Script.lines(Data.BY_ID.S0, ctx(0, false))[4].text, "ARMY.")
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
    local same = Script.timeline({ line("oak", 60), line("oak", 6) }, 12)
    eq(same.lines[2].pieces[1].kind, "in")
end)

test("an erased line: typed, held, deleted, a beat, then the words that are sent", function()
    local l = Script.lines(Data.BY_ID.S1, ctx(1))[11]
    local tl = Script.timeline({ l })
    local t = 0
    local st = Script.at(tl, 2 / Script.ME_CPS + 0.001)
    eq(st.inputOf, "erase")
    eq(st.input, 2)
    t = 3 / Script.ME_CPS + Script.ERASE_STOP / 2
    eq(Script.at(tl, t).input, 3, "held whole")
    t = 3 / Script.ME_CPS + Script.ERASE_STOP + 3 / Script.ERASE_CPS + Script.ERASE_AFTER + 1 / Script.ME_CPS + 0.001
    st = Script.at(tl, t)
    eq(st.inputOf, "text")
    eq(st.input, 1)
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
    local st = Script.at(tl, 2 / Script.ME_CPS + 1)
    eq(st.phase, "type")
    eq(st.input, 2, "held at the mark")
    st = Script.at(tl, 2 / Script.ME_CPS + 2 + 1 / Script.ME_CPS + 0.001)
    eq(st.input, 3, "typing again after it")
    local typing = 4 / Script.ME_CPS + 2
    near(tl.total, typing + Script.readTime(4, typing, 12), 1e-6)
    local oak = { who = "oak", text = "XY", chars = { "X", "Y" }, marks = {} }
    local slow = Script.timeline({ oak, me }, 12, { oak = 4, me = 2, turn = 1.5, after = 3 })
    near(slow.lines[1].t1, 2 / 4 + 3, 1e-6)
    near(slow.lines[2].pieces[1].to - slow.lines[2].pieces[1].from, 1.5, 1e-9)
    near(slow.lines[2].pieces[2].to - slow.lines[2].pieces[2].from, 2 / 2, 1e-9)
end)
