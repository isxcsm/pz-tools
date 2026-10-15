-- Typing in the terminal and the stage scenes (DESIGN-terminal 14 F2, story-improvements 8): the markup of typed texts
-- (the API's language), the character count a clock gives, the pieces of the folder's text panel, how a half-typed text is
-- kept and resumed by the world's age, the stage title, and the check of the markup in the translation files (every radio copy, in both languages: well-formed, the pauses within the limit,
-- short enough for the API). No Hangul in this file: the test VM keeps only the low byte of a literal's letters.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Markup"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Typing"
require "PZUIKit/Typing"
require "OperationAcorn/Story/Folder"
local OA = OperationAcorn
local Markup, Typing, Story, Data = OA.Markup, OA.Typing, OA.Story, OA.StoryData
local KitTyping = PZUIKit.Typing

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

test("the speeds are for the kinds of text, a scene typed a character at a time and a paper printed a row at a time", function()
    eq(Typing.speed("scene", "crude"), 30)
    truthy(Typing.speed("scene", "field") < Typing.speed("scene", "crude"))
    truthy(Typing.speed("document", "crude") >= 60 and Typing.speed("document", "crude") <= 80)
    eq(Typing.speed(nil, "crude"), nil)
    eq(Typing.speed("manifest", "crude"), nil)
    eq(Typing.KIND_OF_GROUP.radio, "scene")
    eq(Typing.KIND_OF_GROUP.request, "document")
    eq(Typing.KIND_OF_GROUP.manifest, "document")
    eq(Typing.KIND_OF_GROUP.field, "document")
    eq(Typing.KIND_OF_GROUP.research, "document")
    eq(Typing.MODE.scene, "chars")
    eq(Typing.MODE.document, "lines")
end)

test("a first presentation left half way goes on at exactly the clock it stopped at, a scene and a document alike", function()
    eq(KitTyping.start(nil), 0, "no state: from the start")
    eq(KitTyping.start(true), 0, "an old record's typed to its end: from the start")
    near(KitTyping.start({ seen = 0 }), 0, 1e-9, "never opened: from the start whenever it is opened")
    near(KitTyping.start({ t = 0 }), 0, 1e-9)
    near(KitTyping.start({ seen = 12, t = 3 }), 3)
    near(KitTyping.start({ seen = 12, t = 3.25 }), 3.25, 1e-9)
    -- no game time is made up for: the old record's world age is not read
    near(KitTyping.start({ seen = 12, start = 10, t = 3 }), 3, 1e-9, "an old { start, t } resumes at t, however long ago")
    -- the scene / document split and the game-time conversion are gone
    eq(Typing.RESUME, nil)
    eq(Typing.secondsPerHour, nil)
end)

test("a text seen to its end plays again from the beginning, whatever clock an older record kept", function()
    eq(KitTyping.start({ seen = 40, done = true }), 0)
    eq(KitTyping.start({ seen = 40, done = true, t = 3 }), 0, "a clock left in a done state is not read")
    eq(KitTyping.start({ done = true, start = 10, t = 3 }), 0)
end)

test("how far a text has been seen: all of it for what was shown whole, the record's count, or the old clock's characters", function()
    local read = Markup.parse("abcdefghij", 10)   -- one character each tenth of a second
    eq(KitTyping.seenOf(nil, read), 10, "no state: it was shown whole")
    eq(KitTyping.seenOf(true, read), 10, "an old record's typed to its end")
    eq(KitTyping.seenOf({ seen = 4 }, read), 4)
    eq(KitTyping.seenOf({ seen = 0 }, read), 0)
    eq(KitTyping.seenOf({ seen = 99 }, read), 10, "never past the text")
    eq(KitTyping.seenOf({ seen = 4, done = true }, read), 10, "done is the whole of it")
    eq(KitTyping.seenOf({ t = 0 }, read), 0, "an old new entry: nothing seen")
    eq(KitTyping.seenOf({ start = 3, t = 0.35 }, read), 4, "an old { start, t }: as far as its clock had come")
    eq(KitTyping.seenOf({ start = 3, t = 50 }, read), 10)
end)

test("the state kept for a showing: the furthest seen only grows, done stays, the clock is kept for a first presentation only", function()
    local state = KitTyping.keep(nil, 6, nil, 0.5)
    eq(state.seen, 6); eq(state.done, nil); near(state.t, 0.5); eq(state.start, nil, "no world age is kept")
    state = KitTyping.keep(state, 3, nil, 0.2)
    eq(state.seen, 6, "a shorter showing does not take the furthest back")
    near(state.t, 0.2)
    state = KitTyping.keep(state, 10, true, nil)
    eq(state.done, true); eq(state.seen, 10)
    eq(state.t, nil, "a showing that ran to its end leaves no clock")
    state = KitTyping.keep(state, 2, nil, 0.1)
    eq(state.done, true, "seen to the end stays so"); eq(state.seen, 10)
    eq(state.t, nil, "and a replay left half way keeps no clock")
    eq(KitTyping.keep({ seen = 10, done = true, t = 3, start = 8 }, 4, nil, 1).t, nil, "an old clock in a done state goes")
    eq(KitTyping.keep(true, 0, nil, 0.3).done, true, "an old record's true is done")
    eq(KitTyping.keep(true, 0, nil, 0.3).t, nil)
    local old = KitTyping.keep({ start = 3, t = 2 }, 5, nil, 1)
    eq(old.seen, 5, "an old { start, t } takes the count the window worked out"); eq(old.t, 1); eq(old.start, nil)
    -- what the window kept and what the record says
    local kept = { seen = 3, t = 1 }
    eq(KitTyping.latest(nil, nil), nil)
    eq(KitTyping.latest({ seen = 1 }, nil).seen, 1)
    eq(KitTyping.latest({ seen = 1 }, kept), kept, "the window's own is the newer")
    local late = KitTyping.latest({ seen = 1, done = true }, kept)
    eq(late.done, true, "read whole in the viewer meanwhile"); eq(late.seen, 3); eq(late.t, nil, "and a done entry keeps no clock")
    eq(KitTyping.latest(true, kept).done, true)
end)

-- The text panel's text -------------------------------------------------------------------------------------------

test("the panel's text has the colours and line ends, and keeps the space where a colour begins", function()
    local read = Markup.parse("a {c:FF0000}b{/c} c\nd")
    local rich = KitTyping.rich(read, { 0.5, 0.6, 0.7 })
    truthy(string.find(rich, "^ <TEXT> <RGB:0.500,0.600,0.700> a"), rich)
    truthy(string.find(rich, "<RGB:1.000,0.000,0.000>", 1, true), "the colour")
    truthy(string.find(rich, "<SPACE> b", 1, true), "the space before the coloured b")
    truthy(string.find(rich, "<RGB:0.500,0.600,0.700>  <SPACE> c", 1, true), "and the one after it")
    truthy(string.find(rich, "<LINE> d", 1, true), "a line end")
    -- no colour: one tag and the lines
    local plain = KitTyping.rich(Markup.parse("one\n\ntwo"), { 1, 1, 1 })
    eq(plain, " <TEXT> <RGB:1.000,1.000,1.000> one <LINE>  <LINE> two")
    -- the panel's own markup characters are escaped
    truthy(string.find(KitTyping.rich(Markup.parse("a<b>c"), { 1, 1, 1 }), "a&lt;b&gt;c", 1, true))
end)

-- The documents' own marks ------------------------------------------------------------------------------------

local DOT = string.char(183)
local Folder = OA.StoryFolder

test("a document's marks go out of its text, and each marked line has its style", function()
    local text = "## Findings\n~ Dr. Hale, day 12\nplain line\n" .. DOT .. " a bullet\n2. a number\n3) another\n> Hale"
    local clean, styles = KitTyping.marks(text)
    eq(clean, "Findings\nDr. Hale, day 12\nplain line\n" .. DOT .. " a bullet\n2. a number\n3) another\nHale",
        "head, meta and sign-off marks gone; bullet and number markers kept")
    eq(styles[1].kind, "head")
    eq(styles[2].kind, "meta")
    eq(styles[3], nil, "a line with no mark has no style")
    eq(styles[4].kind, "bullet")
    eq(styles[4].hang, 2, "the bullet and its space")
    eq(styles[5].kind, "num")
    eq(styles[5].hang, 3)
    eq(styles[6].hang, 3)
    eq(styles[7].kind, "sign")
    -- a mark only counts at the start of a line, with its space
    local same, none = KitTyping.marks("a ## b\n##c\n>d\n~e\n12 x")
    eq(same, "a ## b\n##c\n>d\n~e\n12 x")
    eq(none[1], nil)
    eq(none[2], nil)
    eq(none[5], nil)
    -- the marks are never typed: the reading of the clean text has none of them
    local read = Markup.parse(clean, 10)
    truthy(not string.find(read.plain, "## ", 1, true))
    truthy(not string.find(read.plain, "> ", 1, true))
    eq(KitTyping.marks(nil), nil)
end)

test("the panel's text of a marked document: head and dim colours, half a line above a head and the sign-off, the sign-off on the right, bullets hung", function()
    local clean, styles = KitTyping.marks("## One\nbody\n## Two\n" .. DOT .. " wrapped item\n~ meta\n> sign")
    local rich = KitTyping.rich(Markup.parse(clean), { 1, 1, 1 }, styles, { head = { 0, 1, 0 }, dim = { 0.5, 0.5, 0.5 } })
    truthy(string.find(rich, "^ <TEXT> <RGB:1.000,1.000,1.000>  <RGB:0.000,1.000,0.000> One"), rich)
    truthy(not string.find(rich, "^[^O]*<HALF>"), "no half line above the first line")
    truthy(string.find(rich, "<LINE>  <HALF>  <RGB:0.000,1.000,0.000> Two", 1, true), "a later head has its half line")
    truthy(string.find(rich, DOT .. " <HANG> wrapped item", 1, true), "the bullet hangs")
    truthy(string.find(rich, "<RGB:0.500,0.500,0.500> meta", 1, true), "the meta line is dim")
    truthy(string.find(rich, "<HALF>  <RIGHT> sign", 1, true), "the sign-off: half a line, on the right, dim")
    -- a number hangs too, and a colour of the text's own wins over the line's
    local c2, s2 = KitTyping.marks("## {c:FF0000}red{/c} head\n10. long item")
    local r2 = KitTyping.rich(Markup.parse(c2), { 1, 1, 1 }, s2, { head = { 0, 1, 0 }, dim = { 0.5, 0.5, 0.5 } })
    truthy(string.find(r2, "<RGB:1.000,0.000,0.000> red", 1, true), r2)
    truthy(string.find(r2, "10. <HANG>", 1, true), r2)
    -- with no styles the text is as it was
    eq(KitTyping.rich(Markup.parse("one\ntwo"), { 1, 1, 1 }, nil, nil), " <TEXT> <RGB:1.000,1.000,1.000> one <LINE> two")
end)

test("a paper's content has its marks out and its styles; a radio copy keeps its text as written", function()
    getText = function(key, ...)
        if key == "IGUI_OA_Story_Radio_s1_a" then return "## not a head" end
        return key
    end
    local record = setup(1)
    local paper = Folder.content(record, { title = "M", group = "manifest",
        ref = { kind = "manifest", manifest = { text = "## Cargo\\n" .. DOT .. " flour" } } })
    eq(paper.body, "Cargo\n" .. DOT .. " flour")
    eq(paper.styles[1].kind, "head")
    eq(paper.styles[2].kind, "bullet")
    eq(paper.kind, "document")
    local copy = Folder.content(record, { title = "C", group = "radio",
        ref = { kind = "copy", copy = { id = "s1", stage = 1, keys = { "s1_a" } } } })
    eq(copy.body, "## not a head")
    eq(copy.styles, nil)
end)

test("a document's rows end at the characters of the panel's rows, and come on a step apart", function()
    -- three chunks on two rows, then a blank row, then a row
    local ends = KitTyping.rowEnds({ { 1, 2 }, { 4, 5 }, {}, { 7, 8, 9 } }, { 0, 0, 29, 58 })
    eq(#ends, 2)
    eq(ends[1], 5)
    eq(ends[2], 9)
    eq(KitTyping.rowsAt(0, 4, 0.2), 1, "the first at once")
    eq(KitTyping.rowsAt(0.19, 4, 0.2), 1)
    eq(KitTyping.rowsAt(0.2, 4, 0.2), 2)
    eq(KitTyping.rowsAt(0.6, 4, 0.2), 4)
    eq(KitTyping.rowsAt(9, 4, 0.2), 4)
    eq(KitTyping.rowsAt(-1, 4, 0.2), 0)
end)

test("a document's row is printed from the left within its step, then whole until the next", function()
    local ends = { 10, 30 }
    local n, over, head = KitTyping.printed(ends, 0, 0.2, 0.1)
    eq(n, 0); eq(over, false); eq(head, true)
    n, over, head = KitTyping.printed(ends, 0.05, 0.2, 0.1)
    eq(n, 5, "half the first row"); eq(head, true)
    n, over, head = KitTyping.printed(ends, 0.15, 0.2, 0.1)
    eq(n, 10, "the first row whole"); eq(head, false)
    n, over, head = KitTyping.printed(ends, 0.25, 0.2, 0.1)
    eq(n, 20, "the second row from where the first ended"); eq(head, true)
    n, over, head = KitTyping.printed(ends, 0.4, 0.2, 0.1)
    eq(n, nil); eq(over, true); eq(head, false)
    n, over = KitTyping.printed({}, 0, 0.2, 0.1)
    eq(over, true, "nothing to print is over")
end)

test("the characters of the panel's rows are matched to the text's, less the spaces it dropped", function()
    local src = KitTyping.align("ab cd\nef  gh", { "ab", "cd", "ef", "gh" })
    eq(table.concat(src[1], ","), "1,2")
    eq(table.concat(src[2], ","), "4,5")
    eq(table.concat(src[3], ","), "7,8")
    eq(table.concat(src[4], ","), "11,12")
end)

test("the reveal hands the rows their beginnings as the count grows, and keeps each beginning once made", function()
    local lines = {}
    local reveal = KitTyping.reveal({ "ab", "cd", "ef" }, "ab cd\nef", lines)
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
    local again = KitTyping.reveal({ "ab", "cd", "ef" }, "ab cd\nef", jumped)
    again:show(7)
    eq(jumped[1] .. jumped[2] .. jumped[3], "abcde")
    eq(again.pre[2][1], nil, "a row shown whole makes no beginning")
    eq(made, "c")
end)

test("a text typed through the reveal never shows a character before its time", function()
    local read = Markup.parse("Oak.{p:0.5} Over.", 10)
    local lines = {}
    local reveal = KitTyping.reveal({ "Oak. Over." }, read.plain, lines)
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
    truthy(Story.saveTyped(record, "c:s1", 12, false, 4.5))
    state = Story.typedState(record, "c:s1")
    eq(state.seen, 12)
    near(state.t, 4.5)
    eq(state.start, nil, "no world age is kept")
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
    eq(state.t, nil, "a text seen to its end and left half way in a replay keeps no place")
    -- the same arrival again is not new, and does not start over
    eq(Story.markNew(record, "c:s1"), false)
    eq(Story.typedState(record, "c:s1").done, true)
end)

test("records from before are read as they were: true is seen to the end, { start, t } is seen as far as its clock", function()
    local record = setup(1)
    local s = Story.section(record)
    s.typed = { ["c:a"] = true, ["c:b"] = { start = 3, t = 0.35 }, ["c:c"] = { t = 0 } }
    local read = Markup.parse("abcdefghij", 10)
    eq(KitTyping.seenOf(Story.typedState(record, "c:a"), read), 10)
    eq(KitTyping.seenOf(Story.typedState(record, "c:b"), read), 4)
    eq(KitTyping.seenOf(Story.typedState(record, "c:c"), read), 0)
    -- both go on from the old clock, with no game time made up for
    near(KitTyping.start(Story.typedState(record, "c:b")), 0.35)
    eq(KitTyping.start(Story.typedState(record, "c:a")), 0, "seen to the end: from the start")
    -- the first thing the window tells is saved in the new form over the old
    truthy(Story.saveTyped(record, "c:a", 2, false, 1))
    eq(Story.typedState(record, "c:a").done, true, "true stays done")
    truthy(Story.saveTyped(record, "c:b", 4, false, 0.4))
    local b = Story.typedState(record, "c:b")
    eq(b.seen, 4); near(b.t, 0.4); eq(b.start, nil, "the world age of before is dropped"); eq(b.done, nil)
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
    sendClientCommand(character, OA.MOD, "story_typed", { id = "p1", key = "c:s1", seen = 17, t = 2.25 })
    eq(Story.typedState(record, "c:s1").seen, 17)
    eq(Story.typedState(record, "c:s1").t, 2.25)
    eq(Story.typedState(record, "c:s1").start, nil)
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
    eq(detail.style, "dust")
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
            -- (the calls' lines carry the comms tab's own marks: Story/CommsScript reads them)
            if string.find(value, "[{}]") and not string.find(key, "^IGUI_OA_Comms_") then
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
