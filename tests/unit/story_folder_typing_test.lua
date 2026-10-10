-- The folder tab's typing of what it shows (client/Story/TabFolder, with the panel of client/Story/TypedText): a text is
-- typed every time it is shown, a click brings it to the furthest point seen and no further, a scene left half way
-- starts over and a document goes on, and the records of before are read as they were. The game's rich text panel is
-- stood in for by one that cuts the text at its commands into rows (as story_typedtext_test does); the tab is the real
-- one, its methods run on a table that has only what they touch, and the server's side is the real one too.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Markup"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Typing"
require "OperationAcorn/Story/Folder"
local OA = OperationAcorn
local Markup, Typing, Story, Folder = OA.Markup, OA.Typing, OA.Story, OA.StoryFolder

local function stubPanel()
    local c = {}
    c.__index = c
    function c:derive() local d = {}; d.__index = d; setmetatable(d, { __index = c }); return d end
    function c:new(x, y, w, h)
        return setmetatable({ x = x, y = y, width = w, height = h, marginLeft = 0, marginTop = 0, defaultFont = "Medium",
            lines = {}, lineX = {}, lineY = {}, text = "", drawn = {}, yscroll = 0 }, self)
    end
    function c:paginate()
        self.laidW = self.width
        self.lines, self.lineX, self.lineY = {}, {}, {}
        local x, y, pos, rest = 0, 0, 1, self.text
        while pos <= #rest do
            local s, e = string.find(rest, "<[A-Z]+[^>]*>", pos)
            local piece = string.sub(rest, pos, (s or #rest + 1) - 1)
            piece = string.gsub(piece, "^%s+", "")
            piece = string.gsub(piece, "%s+$", "")
            if piece ~= "" then
                self.lines[#self.lines + 1] = piece
                self.lineX[#self.lines] = x
                self.lineY[#self.lines] = y
                x = x + #piece * 11
            end
            if s then
                if string.sub(rest, s, e) == "<LINE>" then x, y = 0, y + 29 end
                pos = e + 1
            else
                pos = #rest + 1
            end
        end
    end
    function c:render() end
    function c:getYScroll() return self.yscroll end
    function c:measure(s, font) return getTextManager():MeasureStringX(font, s) end
    function c:lineHeightOf(font) return getTextManager():getFontHeight(font) end
    function c:setYScroll(v) self.yscroll = v end
    function c:setVisible(v) self.visible = v end
    function c:drawRect(...) end
    function c:onMouseDown() end
    return c
end

local ms

-- The tab, with the panel, the record and the characters of the test; `contents[key]` is what Folder.content gives.
local function folder(opts)
    opts = opts or {}
    OARichText = stubPanel()
    UIFont = { Small = "Small", Medium = "Medium" }
    OATab ={ derive = function(self, name)
        local d = {}
        d.__index = d
        setmetatable(d, { __index = self })
        return d
    end }
    OA.Trade = OA.Trade or {}
    OA.Trade.UI = {}
    getTextManager = function()
        return { getFontHeight = function() return 29 end, MeasureStringX = function(_, _, s) return #tostring(s) * 11 end }
    end
    ms = 1000000
    getTimestampMs = function() return ms end
    local game = getGameTime
    getGameTime = function()
        local t = game()
        t.getMinutesPerDay = function() return 60 end
        return t
    end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" or name == "OperationAcorn/Trade/Button"
            or name == "OperationAcorn/Trade/RichText" then
            return true
        end
        return real(name)
    end
    local ok, err = pcall(function()
        real "OperationAcorn/Story/TypedText"
        real "OperationAcorn/Story/TabFolder"
        real "OperationAcorn/Story/Init"
    end)
    require = real
    if not ok then error(err, 0) end
    -- the timings below are those of the rows and the characters: the title's coming in and a row's print under the
    -- head are off unless a test asks for them
    OATabFolder.ENTER = opts.enter or 0
    Typing.LINE_PRINT = opts.print or 0

    local record = OA.Store.ensure("p1", "P")
    record.number = 347
    local character = { getUsername = function() return "P" end }
    local contents = {}
    Folder.content = function(_, entry) return contents[entry.key] end
    local tab = setmetatable({ window = { tier = opts.tier or "crude", character = character }, kept = {}, sent = {},
        index = {}, flat = {}, prevButton = {}, nextButton = {} }, { __index = OATabFolder })
    local body = OATypedText:new(0, 0, 300, 200)
    body.target, body.onFinished = tab, OATabFolder.onTyped
    body.cursorColor = { 1, 1, 1 }
    tab.body = body
    tab.record = function() return record end
    tab.palette = function() return { text = { 1, 1, 1 } } end
    tab.fitHeads = function() end
    tab.told = {}
    tab.send = function(self, command, args)
        if command == "story_typed" then self.told[#self.told + 1] = args end
        args.id = "p1"
        sendClientCommand(character, OA.MOD, command, args)
    end
    local t = { tab = tab, body = body, record = record, contents = contents }
    -- An entry of a kind (scene, document, or nil for a paper that is not typed) with the text 20 characters long, 10 a second.
    function t.add(key, kind, text)
        local entry = { key = key, isNew = false }
        tab.flat[#tab.flat + 1] = entry
        tab.index[key] = #tab.flat
        contents[key] = { title = key, meta = "", body = Markup.strip(text), marked = text, kind = kind }
        t[key] = entry
        return entry
    end
    function t.show(key) tab:show(t[key], record) end
    function t.shown() return table.concat(body.lines, "") end
    function t.frame(add)
        ms = ms + add
        body:render()
    end
    return t
end

local TEXT = "{s:10}abcdefghijklmnopqrst"
-- A document of four rows of five characters: it is printed a row at a time, Typing.LINE_STEP apart.
local DOC = "{s:10}abcde\nfghij\nklmno\npqrst"
local ROWS = { "abcde", "abcdefghij", "abcdefghijklmno", "abcdefghijklmnopqrst" }

test("an entry is typed every time it is shown, at the same speed as the first time", function()
    local t = folder()
    t.add("c:s1", "scene", TEXT)
    t.add("d:x", "document", TEXT)
    Story.markNew(t.record, "c:s1")
    t.show("c:s1")
    t.frame(0)
    eq(t.shown(), "a", "typed from the first character")
    for _ = 1, 6 do t.frame(400) end
    eq(t.shown(), "abcdefghijklmnopqrst")
    truthy(Story.typedState(t.record, "c:s1").done, "seen to the end")
    -- shown again: typed again
    t.show("d:x")
    t.show("c:s1")
    eq(t.shown(), "", "laid out, nothing on")
    t.frame(0)
    eq(t.shown(), "a")
    t.frame(100)
    eq(t.shown(), "ab", "at the same speed")
    t.frame(250)
    eq(t.shown(), "abcd")
end)

test("a click brings an entry that was read to the end before to its end, and not at the first time", function()
    local t = folder()
    t.add("c:s1", "scene", TEXT)
    Story.markNew(t.record, "c:s1")
    t.show("c:s1")
    t.frame(0)
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), "a", "the first time there is nothing seen to bring")
    for _ = 1, 6 do t.frame(400) end
    eq(t.shown(), "abcdefghijklmnopqrst")
    t.add("d:x", "document", TEXT)
    t.show("d:x")
    t.show("c:s1")
    t.frame(0)
    t.frame(100)
    eq(t.shown(), "ab")
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), "abcdefghijklmnopqrst", "all of it was seen")
    eq(t.body.run.done, true)
end)

test("a scene left half way starts over, and a click brings it to the furthest point seen", function()
    local t = folder()
    t.add("c:s1", "scene", TEXT)
    t.add("d:x", "document", TEXT)
    Story.markNew(t.record, "c:s1")
    t.show("c:s1")
    t.frame(0)
    t.frame(400)
    t.frame(450)
    eq(t.shown(), "abcdefghi", "nine characters at 0.85 s")
    t.show("d:x")
    local state = Story.typedState(t.record, "c:s1")
    eq(state.seen, 9)
    eq(state.done, nil)
    near(state.t, 0.85, 1e-9)
    TEST.hours = 5
    t.show("c:s1")
    t.frame(0)
    eq(t.shown(), "a", "from the beginning, though the game time passed")
    near(t.body.run.clock, 0, 1e-9)
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), "abcdefghi", "to the furthest point seen")
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), "abcdefghi", "and no further")
    t.frame(100)
    eq(t.shown(), "abcdefghij", "the rest is typed in its time")
end)

test("a document left half way goes on from there, with the game time that passed turned into the terminal's work", function()
    local t = folder()
    t.add("d:x", "document", DOC)
    t.add("c:s1", "scene", TEXT)
    Story.markNew(t.record, "d:x")
    TEST.hours = 1
    t.show("d:x")
    t.frame(0)
    t.frame(250)
    eq(t.shown(), ROWS[2], "two rows at 0.25 s")
    t.show("c:s1")
    t.show("d:x")
    t.frame(0)
    eq(t.shown(), ROWS[2], "no time has passed: where it was")
    t.show("c:s1")
    -- a 60 minute day: a game hour is 150 real seconds, so 0.01 of an hour is 1.5 s, more than the rows left
    TEST.hours = 1.01
    t.show("d:x")
    t.frame(0)
    eq(t.shown(), ROWS[4], "the terminal printed all of it while the player was away")
    eq(Story.typedState(t.record, "d:x").done, true)
    eq(Story.typedState(t.record, "d:x").t, nil)
    -- seen to the end, it is printed again from the start whatever time has passed
    t.show("c:s1")
    TEST.hours = 1.02
    t.show("d:x")
    t.frame(0)
    eq(t.shown(), ROWS[1])
end)

test("a click in a document comes to the furthest point seen, and no further", function()
    local t = folder()
    t.add("d:x", "document", DOC)
    t.add("c:s1", "scene", TEXT)
    Story.markNew(t.record, "d:x")
    t.show("d:x")
    t.frame(0)
    t.frame(250)
    eq(t.shown(), ROWS[2])
    t.show("c:s1")
    t.show("d:x")
    t.frame(0)
    eq(t.shown(), ROWS[2], "resumed at the point it was left")
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), ROWS[2], "nothing beyond it was seen")
    eq(t.body.run.seen, 11, "two rows and the line end between them")
end)

test("a document is printed a row at a time, whole, with no cursor, and is over a step after its last row", function()
    local t = folder()
    t.add("d:x", "document", DOC)
    Story.markNew(t.record, "d:x")
    t.show("d:x")
    eq(t.body.run.step, Typing.LINE_STEP)
    t.frame(0)
    eq(t.shown(), ROWS[1], "the first row at once")
    eq(t.body.tipChunk, nil, "no cursor on a printed row")
    t.frame(150)
    eq(t.shown(), ROWS[1], "the next row waits its step")
    t.frame(60)
    eq(t.shown(), ROWS[2])
    t.frame(200)
    eq(t.shown(), ROWS[3])
    t.frame(200)
    eq(t.shown(), ROWS[4], "the last row")
    truthy(not t.body.run.done, "on until a step after it")
    t.frame(200)
    eq(t.body.run.done, true)
    eq(Story.typedState(t.record, "d:x").done, true)
    eq(Story.typedState(t.record, "d:x").seen, 23, "seen is kept in characters (the line ends too)")
end)

test("a document waits for the title to come in, then prints each row from the left under the cursor", function()
    local t = folder({ enter = 0.3, print = 0.1 })
    t.add("d:x", "document", DOC)
    Story.markNew(t.record, "d:x")
    t.show("d:x")
    t.frame(0)
    t.frame(200)
    eq(t.shown(), "", "the title is still coming in")
    t.frame(150)
    eq(t.shown(), "ab", "half way through the first row's print, 0.05 s after the title")
    truthy(t.body.tipChunk ~= nil, "the cursor is the print head")
    t.frame(100)
    eq(t.shown(), ROWS[1], "the first row whole")
    eq(t.body.tipChunk, nil, "no cursor between rows")
end)

test("a click in a document seen to the end before brings all of it; a scene keeps its cursor", function()
    local t = folder()
    t.add("d:x", "document", DOC)
    t.add("c:s1", "scene", TEXT)
    Story.section(t.record).typed = { ["d:x"] = { seen = 23, done = true } }
    t.show("d:x")
    t.frame(0)
    eq(t.shown(), ROWS[1])
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), ROWS[4])
    eq(t.body.run.done, true)
    Story.markNew(t.record, "c:s1")
    t.show("c:s1")
    t.frame(0)
    eq(t.body.run.step, nil, "a radio copy is typed a character at a time")
    truthy(t.body.tipChunk, "with the cursor")
end)

test("the window closing tells the server how far the entry on show got", function()
    local t = folder()
    t.add("c:s1", "scene", TEXT)
    Story.markNew(t.record, "c:s1")
    TEST.hours = 7
    t.show("c:s1")
    eq(#t.tab.told, 0)
    t.frame(0)
    t.frame(350)
    t.tab:onWindowClose()
    eq(#t.tab.told, 1)
    eq(t.tab.told[1].key, "c:s1")
    eq(t.tab.told[1].seen, 4)
    near(t.tab.told[1].t, 0.35, 1e-9)
    eq(t.tab.told[1].done, nil)
    local state = Story.typedState(t.record, "c:s1")
    eq(state.seen, 4)
    eq(state.start, 7)
    t.tab:onWindowClose()
    eq(#t.tab.told, 1, "once for a showing")
end)

test("a showing that was not drawn tells nothing; a typed paper that has nothing to type is the plain panel", function()
    local t = folder()
    t.add("c:s1", "scene", TEXT)
    t.add("m:7", nil, "a manifest")
    Story.markNew(t.record, "c:s1")
    t.show("c:s1")
    t.show("m:7")
    eq(#t.tab.told, 0, "never drawn")
    eq(t.body.run, nil)
    eq(t.body.reveal, nil)
    t.tab:onWindowClose()
    eq(#t.tab.told, 0)
    eq(Story.typedState(t.record, "m:7"), nil)
end)

test("records from before: an entry typed to its end (true) is typed again and a click shows it whole", function()
    local t = folder()
    t.add("c:s1", "scene", TEXT)
    t.add("d:x", "document", DOC)
    Story.section(t.record).typed = { ["c:s1"] = true, ["d:x"] = true }
    for _, case in ipairs({ { "c:s1", "a", TEXT }, { "d:x", ROWS[1], ROWS[4] } }) do
        local key = case[1]
        t.show(key)
        t.frame(0)
        eq(t.shown(), case[2], key .. " is typed")
        t.body:onMouseDown(3, 3)
        t.frame(16)
        eq(t.shown(), Markup.strip(case[3]), key .. ": a click shows all of it")
    end
end)

test("records from before: { start, t } is a document's place and, for a scene, the furthest point seen", function()
    local t = folder()
    t.add("c:s1", "scene", TEXT)
    t.add("d:x", "document", DOC)
    TEST.hours = 3
    Story.section(t.record).typed = { ["c:s1"] = { start = 3, t = 0.75 }, ["d:x"] = { start = 3, t = 0.25 } }
    t.show("c:s1")
    t.frame(0)
    eq(t.shown(), "a", "a scene starts over")
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), "abcdefgh", "a click brings it to where its clock had come (0.75 s: eight characters)")
    t.show("d:x")
    t.frame(0)
    eq(t.shown(), ROWS[2], "a document goes on from the clock, printed by rows")
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), ROWS[2], "and a click brings nothing more: only the clock's characters were seen")
end)

test("records from before: a document seen part of the way through a row is brought to the last row seen whole", function()
    local t = folder()
    t.add("d:x", "document", DOC)
    Story.section(t.record).typed = { ["d:x"] = { seen = 13 } }
    t.show("d:x")
    t.frame(0)
    eq(t.shown(), ROWS[1])
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), ROWS[2], "the second row was seen whole, the third only in part")
    t.frame(200)
    eq(t.shown(), ROWS[3], "the rest comes in its time")
    eq(t.body.run.seen, 17)
end)

test("a paper with no state at all was shown whole before: it is printed, and a click shows all", function()
    local t = folder()
    t.add("d:x", "document", DOC)
    eq(Story.typedState(t.record, "d:x"), nil)
    t.show("d:x")
    t.frame(0)
    eq(t.shown(), ROWS[1])
    t.body:onMouseDown(3, 3)
    t.frame(16)
    eq(t.shown(), ROWS[4])
    truthy(Story.typedState(t.record, "d:x").done)
end)

test("the field terminal types a scene a little slower than the crude one", function()
    local crude, field = folder({ tier = "crude" }), folder({ tier = "field" })
    local text = "abcdefghijklmnopqrstabcdefghijklmnopqrst"
    crude.add("c:s1", "scene", text)
    field.add("c:s1", "scene", text)
    Story.markNew(crude.record, "c:s1")
    crude.show("c:s1")
    crude.frame(0)
    crude.frame(400)
    local n1 = Markup.count(crude.body.run.parse, crude.body.run.clock)
    Story.markNew(field.record, "c:s1")
    field.show("c:s1")
    field.frame(0)
    field.frame(400)
    local n2 = Markup.count(field.body.run.parse, field.body.run.clock)
    truthy(n2 < n1)
end)
