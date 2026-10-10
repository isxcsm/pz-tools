-- Typing in the terminal and the stage scenes (DESIGN-terminal 14 F2, story-improvements 8): the markup of typed texts
-- (the API's language), the character count a clock gives, the pieces of the folder's text panel, how a half-typed text is
-- kept and resumed by the world's age, the stage title and its scene, the scene over the screen, and the check of
-- the markup in the translation files (every radio copy, in both languages: well-formed, the pauses within the limit,
-- short enough for the API). No Hangul in this file: the test VM keeps only the low byte of a literal's letters.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Markup"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Typing"
require "OperationAcorn/Story/Folder"
local OA = OperationAcorn
local Markup, Typing, Story, Data = OA.Markup, OA.Typing, OA.Story, OA.StoryData

local function setup(stage, milestones)
    local record = OA.Store.ensure("p1", "P")
    record.number = 347
    record.trade = { stage = stage or 0, milestones = milestones or 0, credits = 0, trust = 0 }
    OA.Trade = { addToDrop = function() end }
    return record
end

-- The markup ------------------------------------------------------------------------------------------------------

test("a text without tags is typed at the speed, one character each, the first at once", function()
    local read = Markup.parse("abcd", 10)
    eq(read.plain, "abcd")
    eq(read.n, 4)
    near(read.times[1], 0)
    near(read.times[2], 0.1)
    near(read.times[4], 0.3)
    near(read.total, 0.4, 1e-9, "the last character's turn counts")
    eq(read.pauses, 0)
    eq(#read.runs, 0)
    eq(Markup.parse("x").total, 1 / Markup.DEFAULT_SPEED, "30 a second when no speed is given")
end)

test("a pause holds the next character back; at the start it delays the first, at the end it lengthens the typing", function()
    local read = Markup.parse("a{p:0.5}b", 10)
    eq(read.plain, "ab")
    near(read.times[2], 0.6)
    near(read.total, 0.7)
    near(read.pauses, 0.5)
    local first = Markup.parse("{p:2}a", 10)
    near(first.times[1], 2)
    local last = Markup.parse("a{p:3}", 10)
    near(last.total, 3.1)
    near(Markup.parse("a{p:30}b", 10).times[2], 30.1)
    near(Markup.parse("a{p:0.125}b", 10).times[2], 0.225)
end)

test("a speed tag changes the rate from the next character on, and {s} brings the text's own back", function()
    local read = Markup.parse("a{s:5}bc{s}d", 20)
    near(read.times[2], 0.05)
    near(read.times[3], 0.25)
    near(read.times[4], 0.45)
    near(read.total, 0.5)
end)

test("a line end takes no time of its own and comes with the next character", function()
    local read = Markup.parse("ab\ncd", 10)
    eq(read.n, 5)
    eq(read.plain, "ab\ncd")
    near(read.times[3], 0.2)
    near(read.times[4], 0.2)
    near(read.times[5], 0.3)
end)

test("colours are runs of the characters between the tags; the braces are escaped by doubling", function()
    local read = Markup.parse("a{c:FF8000}bc{/c}d {{x}}", 10)
    eq(read.plain, "abcd {x}")
    eq(#read.runs, 1)
    eq(read.runs[1].from, 2)
    eq(read.runs[1].to, 3)
    near(read.runs[1].r, 1)
    near(read.runs[1].g, 128 / 255)
    near(read.runs[1].b, 0)
    eq(Markup.parse("{c:ff0000}x{/c}").runs[1].r, 1, "either case")
    eq(#Markup.parse("a{c:FF0000}{/c}b").runs, 0, "a colour of nothing is nothing")
end)

test("what the API refuses is refused here: bad tags, a brace alone, colours that nest or never close, nothing left", function()
    local function bad(text, why)
        local read, message = Markup.parse(text)
        eq(read, nil, why or text)
        truthy(type(message) == "string" and message ~= "", "says what is wrong")
    end
    bad("a{p:}b")
    bad("a{p:x}b")
    bad("a{p:.5}b")
    bad("a{p:0.1234}b")
    bad("a{p:31}b")
    bad("a{p:-1}b")
    bad("a{s:0}b")
    bad("a{s:1001}b")
    bad("a{s:5.5}b")
    bad("a{c:FF00}b{/c}")
    bad("a{c:GG0000}b{/c}")
    bad("a{c:FF0000}b{c:00FF00}c{/c}{/c}")
    bad("a{c:FF0000}b")
    bad("a{/c}b")
    bad("a{q:1}b")
    bad("a{b")
    bad("a}b")
    bad("{p:1}")
    bad("")
    bad("{c:FF0000}{/c}")
    eq(Markup.parse("a{p:30}b") ~= nil, true)
    eq(Markup.parse("a{s:1000}b") ~= nil, true)
    eq(Markup.parse("a{s:1}b") ~= nil, true)
end)

test("the count of characters at a time of the typing is the last whose time has come", function()
    local read = Markup.parse("a{p:1}bc", 10)
    eq(Markup.count(read, -1), 0)
    eq(Markup.count(read, 0), 1)
    eq(Markup.count(read, 0.99), 1, "held back by the pause")
    eq(Markup.count(read, 1.1), 2)
    eq(Markup.count(read, 1.25), 3)
    eq(Markup.count(read, read.total), 3)
    eq(Markup.count(read, 1000), 3)
    local long = Markup.parse(string.rep("x", 400), 40)
    for _, t in ipairs({ 0.01, 0.51, 3.01, 9.99 }) do
        eq(Markup.count(long, t), math.min(400, math.floor(t * 40) + 1), "at " .. t)
    end
end)

test("stripped, a text is what shows: the tags gone, the braces unescaped; a faulty text still reads", function()
    eq(Markup.strip("Oak.{p:0.6} Over."), "Oak. Over.")
    eq(Markup.strip("a{c:FF0000}b{/c}{s:5}c{s}"), "abc")
    eq(Markup.strip("{{a}}"), "{a}")
    eq(Markup.strip("no tags"), "no tags")
    eq(Markup.strip("a{p:0.6}b{c:FF0000}c"), "abc", "the colour never closed: the tags that are well-formed are taken out")
    eq(Markup.strip("a{p:x}b"), "a{p:x}b", "an unknown tag is left as written")
    eq(Markup.strip(nil), nil)
end)

test("the line under a title is the first sentences of a radio line within the limit", function()
    local line = "This is Oak.{p:0.6} Scheduled contact.{p:0.6} Box received. Curtain sample in good condition. Over."
    eq(Markup.lead(line, 24), "This is Oak. Scheduled contact.")
    eq(Markup.lead(line, 17), "This is Oak. Scheduled...", "a lone short sentence is carried on into the next, cut at a word")
    eq(Markup.lead("Oak. Sheet 1 of the unresolved items list goes in the next drop. Over.", 24),
        "Oak. Sheet 1 of the unresolved items list...")
    eq(Markup.lead(line, 7), "This is Oak.")
    eq(Markup.lead(line, 1000), "This is Oak. Scheduled contact. Box received. Curtain sample in good condition. Over.")
    eq(Markup.lead("One long sentence without any stop in it at all", 11), "One long sentence...")
    eq(Markup.lead("First line.\nSecond line.", 100), "First line.")
    eq(Markup.lead("0347. Where are you sleeping tonight.", 24), "0347. Where are you sleeping tonight.")
    eq(Markup.lead("No end", 30), "No end")
end)

test("a text's width in ems counts the Latin range narrower, and a Hangul syllable whole", function()
    near(Markup.width("abc"), 1.65)
    local ko = (readfile("OperationAcorn/42/media/lua/shared/Translate/KO/IG_UI.json") or "")
    local name = string.match(ko, '"IGUI_OA_Econ_Stage_1": "([^"]+)"')
    eq(#name, 2, "two syllables, two characters")
    near(Markup.width(name), 2, 1e-9, "a whole em each")
    -- a Korean radio line of the first stage: its first sentences fit the title's line
    local line = string.match(ko, '"IGUI_OA_Story_Radio_s1_a": "([^"]+)"')
    local lead = Markup.lead(line, OA.Story.TITLE_LEAD)
    truthy(#lead >= 8 and #lead < #Markup.strip(line), "the first sentences, not all of it")
    truthy(Markup.width(lead) <= OA.Story.TITLE_LEAD)
    truthy(string.find(Markup.strip(line), lead, 1, true) == 1)
end)

test("a plain text is broken into rows at spaces", function()
    local rows = Markup.wrap("aaa bbb ccc ddd", 7)
    eq(#rows, 2)
    eq(rows[1], "aaa bbb")
    eq(rows[2], "ccc ddd")
    eq(Markup.wrap("abcdefghij kl", 5)[1], "abcdefghij", "a word wider than the row stays whole")
    eq(#Markup.wrap("one\ntwo", 20), 2)
    -- by a measure instead of the characters: ten pixels each
    local measured = Markup.wrap("ii ii ii ii", 50, function(row) return #row * 10 end)
    eq(#measured, 2)
    eq(measured[1], "ii ii")
end)

-- The clock and the record ----------------------------------------------------------------------------------------

test("the speeds are for the new kinds of text only, and the field terminal types a little slower", function()
    eq(Typing.speed("scene", "crude"), 30)
    truthy(Typing.speed("scene", "field") < Typing.speed("scene", "crude"))
    truthy(Typing.speed("document", "crude") >= 60 and Typing.speed("document", "crude") <= 80)
    eq(Typing.speed(nil, "crude"), nil)
    eq(Typing.speed("manifest", "crude"), nil)
    eq(Typing.KIND_OF_GROUP.radio, "scene")
    eq(Typing.KIND_OF_GROUP.request, "document")
    eq(Typing.KIND_OF_GROUP.manifest, nil)
    eq(Typing.KIND_OF_GROUP.field, nil)
end)

test("a document left half typed goes on by the game time that passed, turned into real seconds of the day's length", function()
    -- a 60 minute day: a game hour is 150 real seconds
    near(Typing.secondsPerHour(60), 150)
    near(Typing.secondsPerHour(24), 60)
    eq(Typing.start(nil, 10, 60, "document"), 0, "no state: from the start (it is typed every time)")
    eq(Typing.start(true, 10, 60, "document"), 0, "seen to the end before: from the start")
    eq(Typing.start({ seen = 40, done = true }, 10, 60, "document"), 0, "a showing that ran to its end left no clock")
    near(Typing.start({ seen = 0 }, 10, 60, "document"), 0, 1e-9, "never opened: from the start whenever it is opened")
    near(Typing.start({ t = 0 }, 10, 60, "document"), 0, 1e-9)
    near(Typing.start({ start = 10, t = 3 }, 10, 60, "document"), 3)
    near(Typing.start({ start = 10, t = 3 }, 10.02, 60, "document"), 6, 1e-9, "a minute and a fifth of game time, 3 real seconds")
    near(Typing.start({ start = 10, t = 3 }, 9, 60, "document"), 3, 1e-9, "the clock never runs back")
    near(Typing.start({ start = 10, t = 3 }, 11, 24, "document"), 63)
    -- a night's sleep finishes any text
    local read = Markup.parse(string.rep("x", 300), 30)
    truthy(Typing.start({ start = 22, t = 2 }, 30, 60, "document") >= read.total)
end)

test("a scene left half typed starts over, whatever its record says; the way is a table by kind", function()
    eq(Typing.RESUME.scene, "restart")
    eq(Typing.RESUME.document, "resume")
    eq(Typing.start({ start = 10, t = 3, seen = 20 }, 10.02, 60, "scene"), 0)
    eq(Typing.start({ start = 10, t = 3 }, 10, 60, "scene"), 0)
    eq(Typing.start({ start = 10, t = 3 }, 10, 60, "somethingnew"), 0, "a kind with no way chosen starts over")
    eq(Typing.start({ start = 10, t = 3 }, 10, 60), 0)
    -- every typed kind has a speed and a way
    for kind in pairs(Typing.SPEED) do truthy(Typing.RESUME[kind], kind .. " chooses its way") end
end)

test("how far a text has been seen: all of it for what was shown whole, the record's count, or the old clock's characters", function()
    local read = Markup.parse("abcdefghij", 10)   -- one character each tenth of a second
    eq(Typing.seenOf(nil, read), 10, "no state: it was shown whole")
    eq(Typing.seenOf(true, read), 10, "an old record's typed to its end")
    eq(Typing.seenOf({ seen = 4 }, read), 4)
    eq(Typing.seenOf({ seen = 0 }, read), 0)
    eq(Typing.seenOf({ seen = 99 }, read), 10, "never past the text")
    eq(Typing.seenOf({ seen = 4, done = true }, read), 10, "done is the whole of it")
    eq(Typing.seenOf({ t = 0 }, read), 0, "an old new entry: nothing seen")
    eq(Typing.seenOf({ start = 3, t = 0.35 }, read), 4, "an old { start, t }: as far as its clock had come")
    eq(Typing.seenOf({ start = 3, t = 50 }, read), 10)
end)

test("the state kept for a showing: the furthest seen only grows, done stays, the clock is kept for a showing left half way", function()
    local state = Typing.keep(nil, 6, nil, 0.5, 12)
    eq(state.seen, 6); eq(state.done, nil); eq(state.start, 12); near(state.t, 0.5)
    state = Typing.keep(state, 3, nil, 0.2, 13)
    eq(state.seen, 6, "a shorter showing does not take the furthest back")
    eq(state.start, 13); near(state.t, 0.2)
    state = Typing.keep(state, 10, true, nil, 14)
    eq(state.done, true); eq(state.seen, 10)
    eq(state.start, nil, "a showing that ran to its end leaves no clock"); eq(state.t, nil)
    state = Typing.keep(state, 2, nil, 0.1, 15)
    eq(state.done, true, "seen to the end stays so"); eq(state.seen, 10); near(state.t, 0.1)
    eq(Typing.keep(true, 0, nil, nil, 1).done, true, "an old record's true is done")
    local old = Typing.keep({ start = 3, t = 2 }, 5, nil, 1, 9)
    eq(old.seen, 5, "an old { start, t } takes the count the window worked out"); eq(old.t, 1)
    -- what the window kept and what the record says
    local kept = { seen = 3, t = 1, start = 5 }
    eq(Typing.latest(nil, nil), nil)
    eq(Typing.latest({ seen = 1 }, nil).seen, 1)
    eq(Typing.latest({ seen = 1 }, kept), kept, "the window's own is the newer")
    local late = Typing.latest({ seen = 1, done = true }, kept)
    eq(late.done, true, "read whole in the viewer meanwhile"); eq(late.seen, 3); eq(late.t, 1)
    eq(Typing.latest(true, kept).done, true)
end)

-- The text panel's text -------------------------------------------------------------------------------------------

test("the panel's text has the colours and line ends, and keeps the space where a colour begins", function()
    local read = Markup.parse("a {c:FF0000}b{/c} c\nd")
    local rich = Typing.rich(read, { 0.5, 0.6, 0.7 })
    truthy(string.find(rich, "^ <TEXT> <RGB:0.500,0.600,0.700> a"), rich)
    truthy(string.find(rich, "<RGB:1.000,0.000,0.000>", 1, true), "the colour")
    truthy(string.find(rich, "<SPACE> b", 1, true), "the space before the coloured b")
    truthy(string.find(rich, "<RGB:0.500,0.600,0.700>  <SPACE> c", 1, true), "and the one after it")
    truthy(string.find(rich, "<LINE> d", 1, true), "a line end")
    -- no colour: one tag and the lines
    local plain = Typing.rich(Markup.parse("one\n\ntwo"), { 1, 1, 1 })
    eq(plain, " <TEXT> <RGB:1.000,1.000,1.000> one <LINE>  <LINE> two")
    -- the panel's own markup characters are escaped
    truthy(string.find(Typing.rich(Markup.parse("a<b>c"), { 1, 1, 1 }), "a&lt;b&gt;c", 1, true))
end)

test("the characters of the panel's rows are matched to the text's, less the spaces it dropped", function()
    local src = Typing.align("ab cd\nef  gh", { "ab", "cd", "ef", "gh" })
    eq(table.concat(src[1], ","), "1,2")
    eq(table.concat(src[2], ","), "4,5")
    eq(table.concat(src[3], ","), "7,8")
    eq(table.concat(src[4], ","), "11,12")
end)

test("the reveal hands the rows their beginnings as the count grows, and keeps each beginning once made", function()
    local lines = {}
    local reveal = Typing.reveal({ "ab", "cd", "ef" }, "ab cd\nef", lines)
    eq(lines[1] .. "|" .. lines[2] .. "|" .. lines[3], "||", "nothing has come on")
    local c, k = reveal:show(1)
    eq(lines[1], "a")
    eq(c, 1)
    eq(k, 1)
    reveal:show(2)
    eq(lines[1], "ab")
    c, k = reveal:show(4)
    eq(lines[1], "ab")
    eq(lines[2], "c")
    eq(c, 2)
    eq(k, 1)
    local made = reveal.pre[2][1]
    reveal:show(5)
    eq(lines[2], "cd")
    c = reveal:show(8)
    eq(c, nil, "every row is whole")
    eq(lines[3], "ef")
    -- the count may jump (resumed from far on)
    local jumped = {}
    local again = Typing.reveal({ "ab", "cd", "ef" }, "ab cd\nef", jumped)
    again:show(7)
    eq(jumped[1] .. jumped[2] .. jumped[3], "abcde")
    eq(again.pre[2][1], nil, "a row shown whole makes no beginning")
    eq(made, "c")
end)

test("a text typed through the reveal never shows a character before its time", function()
    local read = Markup.parse("Oak.{p:0.5} Over.", 10)
    local lines = {}
    local reveal = Typing.reveal({ "Oak. Over." }, read.plain, lines)
    local seen = ""
    for step = 0, 40 do
        local t = step * 0.05
        reveal:show(Markup.count(read, t))
        local shown = lines[1]
        truthy(#shown >= #seen, "it only grows")
        seen = shown
        local expected = Markup.count(read, t)
        eq(#shown, expected, "at " .. t)
    end
    eq(seen, "Oak. Over.")
end)

-- What the story keeps and says -------------------------------------------------------------------------------------

test("what is new has nothing seen; the record keeps the furthest seen, and done is done", function()
    local record = setup(1)
    Story.markNew(record, "c:s1")
    local state = Story.typedState(record, "c:s1")
    eq(state.seen, 0)
    eq(state.done, nil)
    eq(state.start, nil)
    eq(Story.typedState(record, "c:other"), nil, "what was never kept has no state: it was shown whole")
    TEST.hours = 10
    truthy(Story.saveTyped(record, "c:s1", 12, false, 4.5))
    state = Story.typedState(record, "c:s1")
    eq(state.seen, 12)
    near(state.t, 4.5)
    eq(state.start, 10)
    truthy(Story.saveTyped(record, "c:s1", 5, false, 1))
    eq(Story.typedState(record, "c:s1").seen, 12, "the furthest seen does not go back")
    truthy(Story.saveTyped(record, "c:fresh", 3, false, 1), "an entry with no state takes one when it is left half way")
    eq(Story.typedState(record, "c:fresh").seen, 3)
    eq(Story.saveTyped(record, "bad key", 4, false, 4.5), false, "only a folder's key")
    eq(Story.saveTyped(record, "c:s1", -1, false, nil), false)
    eq(Story.saveTyped(record, "c:s1", "x", false, nil), false)
    eq(Story.saveTyped(record, "c:s1", nil, false, -1), false)
    eq(Story.saveTyped(record, "c:s1", nil, false, nil), false, "nothing to keep")
    truthy(Story.saveTyped(record, "c:s1", 40, true, nil))
    state = Story.typedState(record, "c:s1")
    eq(state.done, true)
    eq(state.t, nil, "a showing that ran to its end left no clock")
    truthy(Story.saveTyped(record, "c:s1", 3, false, 1.5))
    state = Story.typedState(record, "c:s1")
    eq(state.done, true, "seen to the end stays so")
    eq(state.seen, 40)
    near(state.t, 1.5, 1e-9, "a document shown again and left half way keeps its place")
    -- the same arrival again is not new, and does not start over
    eq(Story.markNew(record, "c:s1"), false)
    eq(Story.typedState(record, "c:s1").done, true)
end)

test("records from before are read as they were: true is seen to the end, { start, t } is seen as far as its clock", function()
    local record = setup(1)
    local s = Story.section(record)
    s.typed = { ["c:a"] = true, ["c:b"] = { start = 3, t = 0.35 }, ["c:c"] = { t = 0 } }
    local read = Markup.parse("abcdefghij", 10)
    eq(Typing.seenOf(Story.typedState(record, "c:a"), read), 10)
    eq(Typing.seenOf(Story.typedState(record, "c:b"), read), 4)
    eq(Typing.seenOf(Story.typedState(record, "c:c"), read), 0)
    -- a document goes on from the old clock, a scene starts over
    near(Typing.start(Story.typedState(record, "c:b"), 3, 60, "document"), 0.35)
    eq(Typing.start(Story.typedState(record, "c:b"), 3, 60, "scene"), 0)
    -- the first thing the window tells is saved in the new form over the old
    TEST.hours = 4
    truthy(Story.saveTyped(record, "c:a", 2, false, 1))
    eq(Story.typedState(record, "c:a").done, true, "true stays done")
    truthy(Story.saveTyped(record, "c:b", 4, false, 0.4))
    local b = Story.typedState(record, "c:b")
    eq(b.seen, 4); near(b.t, 0.4); eq(b.start, 4); eq(b.done, nil)
    -- an old record without the table takes the first new entry's state
    s.typed = nil
    eq(Story.typedState(record, "c:s1"), nil)
    Story.markNew(record, "d:something")
    eq(Story.typedState(record, "d:something").seen, 0)
end)

test("the window's commands keep what was seen; a paper read whole in its viewer is seen to the end", function()
    local ok = pcall(require, "OperationAcorn/Story/Init")
    truthy(ok, "the story's server part loads")
    local record = setup(1)
    local character = { getUsername = function() return "P" end }
    Story.markNew(record, "c:s1")
    Story.markNew(record, "d:police_card")
    TEST.hours = 3
    sendClientCommand(character, OA.MOD, "story_typed", { id = "p1", key = "c:s1", seen = 17, t = 2.25 })
    eq(Story.typedState(record, "c:s1").seen, 17)
    eq(Story.typedState(record, "c:s1").t, 2.25)
    eq(Story.typedState(record, "c:s1").start, 3)
    sendClientCommand(character, OA.MOD, "story_typed", { id = "p1", key = "c:s1", seen = 30, done = true })
    eq(Story.typedState(record, "c:s1").done, true)
    eq(Story.typedState(record, "c:s1").t, nil)
    sendClientCommand(character, OA.MOD, "story_typed", { id = "p1", key = 5, t = 1 })
    sendClientCommand(character, OA.MOD, "story_typed", { id = "p1", key = "c:s1", seen = "x" })
    eq(Story.typedState(record, "c:s1").seen, 30, "a bad number changes nothing")
    sendClientCommand(character, OA.MOD, "story_read", { id = "p1", doc = "police_card" })
    eq(Story.typedState(record, "d:police_card").done, true)
    sendClientCommand(character, OA.MOD, "story_read", { id = "p1", doc = "never_kept" })
    eq(Story.typedState(record, "d:never_kept"), nil, "a paper the folder kept nothing of keeps nothing")
end)

test("the copy's text is plain for the places that show it whole, and marked for the one that types it", function()
    getText = function(key, ...)
        if key == "IGUI_OA_Story_Radio_s1_a" then return "Oak.{p:0.5} Over." end
        if key == "IGUI_OA_Story_Radio_s1_b" then return "Again.{p:1} Over." end
        return key
    end
    local record = setup(1)
    local copy = { id = "s1", stage = 1, keys = { "s1_a", "s1_b" } }
    eq(Story.copyText(record, copy), "Oak. Over.\n\nAgain. Over.")
    eq(Story.copyMarked(record, copy), "Oak.{p:0.5} Over.\n\nAgain.{p:1} Over.")
end)

test("a stage's title names the stage; the line under it is the first radio line of its copy", function()
    local record = setup(3)
    local detail = Story.stageTitle(record, 3)
    eq(detail.key, "IGUI_OA_Title_StageNamed")
    eq(detail.args[1], 3)
    eq(detail.args[2].key, "IGUI_OA_Econ_Stage_3")
    eq(detail.sub, "IGUI_OA_Story_Radio_s3_a")
    eq(detail.subArgs[1], "0347")
    eq(detail.subLead, Story.TITLE_LEAD)
    eq(detail.style, "stamp")
    eq(detail.fallback, "good")
    eq(Story.stageTitle(record, 5).sub, "IGUI_OA_Story_Radio_s5_first")
    -- the milestones have the number alone, but the 8th is the handover
    local m1 = Story.stageTitle(record, 6)
    eq(m1.key, "IGUI_OA_Title_Stage")
    eq(m1.args[1], 6)
    eq(m1.sub, "IGUI_OA_Story_Radio_m1_a")
    eq(Story.stageTitle(record, 7).key, "IGUI_OA_Title_Stage")
    local m3 = Story.stageTitle(record, 8)
    eq(m3.key, "IGUI_OA_Title_StageNamed")
    eq(m3.args[2].key, "IGUI_OA_Terminal_LevelHandover")
    -- past the story's own lines: the plain title and the shop's new items
    local late = Story.stageTitle(record, 9)
    eq(late.key, "IGUI_OA_Title_Stage")
    eq(late.sub, "IGUI_OA_Title_NewItems")
    eq(late.subLead, nil)
end)

test("a stage entered through a trust change gets its scene after the title; the other ways do not", function()
    local scenes = {}
    OA.Sync.listen("scene", function(playerId, detail) scenes[#scenes + 1] = { player = playerId, detail = detail } end)
    local record = setup(2)
    Story.onStage(record)
    eq(#scenes, 0, "the tick that catches up says nothing")
    record.trade.stage = 3
    Story.onStage(record, nil, nil, true)
    eq(#scenes, 1)
    eq(scenes[1].player, "p1")
    eq(scenes[1].detail.id, "s3")
    -- s3_b tells of the paper in the next crate: it joins the copy once that paper has gone (Data.RADIO_AFTER)
    eq(table.concat(scenes[1].detail.keys, ","), "s3_a,s3_c")
    eq(scenes[1].detail.number, "0347")
    -- two stages at once: the last one's scene
    record.trade.stage = 5
    Story.onStage(record, nil, nil, true)
    eq(#scenes, 2)
    eq(scenes[2].detail.id, "s5")
    eq(scenes[2].detail.keys[1], "s5_first")
    -- a milestone
    record.trade.milestones = 1
    Story.onStage(record, nil, nil, true)
    eq(scenes[3].detail.id, "m1")
    -- nothing new, nothing shown
    Story.onStage(record, nil, nil, true)
    eq(#scenes, 3)
end)

test("the first contact is a scene, unless it comes from the tick that finds a record past the first stage", function()
    local scenes = {}
    OA.Sync.listen("scene", function(playerId, detail) scenes[#scenes + 1] = detail end)
    local record = setup(1)
    truthy(Story.firstContact(record, false))
    eq(#scenes, 1)
    eq(scenes[1].id, "first")
    eq(scenes[1].keys[1], "first")
    eq(Story.firstContact(record, false), false)
    eq(#scenes, 1, "once")
    local late = OA.Store.ensure("p2", "Q")
    late.number = 5
    late.trade = { stage = 1, milestones = 0 }
    Story.firstContact(late, true)
    eq(scenes[2].keys[1], "first_late")
    local quiet = OA.Store.ensure("p3", "R")
    quiet.number = 6
    quiet.trade = { stage = 1, milestones = 0 }
    Story.firstContact(quiet, false, true)
    eq(#scenes, 2, "quiet")
    truthy(Story.section(quiet).firstContact)
end)

test("the handover is a scene after its title", function()
    local told, scenes = {}, {}
    OA.Sync.listen("title", function(playerId, detail) told[#told + 1] = detail end)
    OA.Sync.listen("scene", function(playerId, detail) scenes[#scenes + 1] = detail end)
    local record = setup(5, 3)
    Story.section(record).seenMilestones = 3
    Story.completeHandover(record)
    eq(told[1].key, "IGUI_OA_Title_Handover")
    eq(scenes[1].id, "handover")
    eq(scenes[1].keys[1], "handover")
end)

-- The markup in the translation files -----------------------------------------------------------------------------

-- A language's texts as the game would read them from its file.
local function texts(lang)
    local map = {}
    local text = readfile("OperationAcorn/42/media/lua/shared/Translate/" .. lang .. "/IG_UI.json") or ""
    for line in string.gmatch(text, "[^\n]+") do
        local k, v = string.match(line, '^%s*"([^"]+)":%s*"(.*)",?%s*$')
        if k then
            v = string.gsub(v, "\\(.)", function(c) if c == "n" then return "\n" end return c end)
            map[k] = v
        end
    end
    return map
end

-- Every radio copy that is a scene: { id, keys }.
local function scenes()
    local list = { { id = "first", keys = { "first" } }, { id = "first_late", keys = { "first_late" } },
        { id = "handover", keys = { Data.HANDOVER_RADIO } } }
    for st = 1, Data.LAST_STAGE do
        local def = Data.STAGES[st]
        if def and def.radio and #def.radio > 0 then list[#list + 1] = { id = "s" .. st, keys = def.radio } end
    end
    for k = 1, 3 do
        local def = Data.MILESTONES[k]
        if def and def.radio and #def.radio > 0 then list[#list + 1] = { id = "m" .. k, keys = def.radio } end
    end
    return list
end

test("every translated text with braces reads as markup, in both languages", function()
    local found = 0
    for _, lang in ipairs({ "EN", "KO" }) do
        for key, value in pairs(texts(lang)) do
            if string.find(value, "[{}]") then
                found = found + 1
                local read, why = Markup.parse(value)
                truthy(read, lang .. " " .. key .. ": " .. tostring(why))
            end
        end
    end
    truthy(found >= 20, "the scenes' lines carry marks")
end)

test("every scene is within the limits: the pauses, the time it takes, the API's length, the rows the old API takes", function()
    for _, lang in ipairs({ "EN", "KO" }) do
        local map = texts(lang)
        for _, scene in ipairs(scenes()) do
            local lines, pauses, seconds = {}, 0, 0
            for _, key in ipairs(scene.keys) do
                local value = map["IGUI_OA_Story_Radio_" .. key]
                truthy(value, lang .. " has " .. key)
                local read, why = Markup.parse(value, 28)
                truthy(read, lang .. " " .. key .. ": " .. tostring(why))
                pauses = pauses + read.pauses
                seconds = seconds + read.total
                lines[#lines + 1] = value
            end
            local what = lang .. " scene " .. scene.id
            truthy(pauses <= Typing.MAX_PAUSES, what .. " pauses for " .. pauses .. " s")
            truthy(seconds <= 30, what .. " takes " .. seconds .. " s at 28 a second")
            local joined = string.gsub(table.concat(lines, "\n\n"), "%%1", "0347")
            truthy(#joined <= Markup.MAX_LENGTH, what .. " is " .. #joined .. " characters with its tags")
            local rows = 0
            for _ in string.gmatch(table.concat(lines, "\n\n") .. "\n", "(.-)\n") do rows = rows + 1 end
            truthy(rows <= 8, what .. " has " .. rows .. " lines of its own")
        end
    end
end)

test("a scene's marks are only pauses: its words are what the plain text says", function()
    local map = texts("EN")
    for _, scene in ipairs(scenes()) do
        for _, key in ipairs(scene.keys) do
            local value = map["IGUI_OA_Story_Radio_" .. key]
            local stripped = Markup.strip(value)
            truthy(not string.find(stripped, "[{}]"), key)
            truthy(#stripped < #value, key .. " has pauses")
            -- the marks leave the sentences whole: a pause comes after a stop or before the closing word
            truthy(not string.find(value, "{p:[%d%.]+}[%.,]"), key .. ": a pause is not put before a stop")
        end
    end
end)
