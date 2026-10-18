-- The folder's text panel that types (PZUIKit/TypedText, PZUITypedText): with the kit's rich text panel (PZUIRichText) stood in for by one that
-- cuts the text at its commands into rows, what a frame does with the clock, the gaps, a click (it brings the typing to the furthest point seen), a layout in the middle of
-- the typing, and the end of it.
require "OperationAcorn/Core"
require "OperationAcorn/Markup"
require "PZUIKit/Typing"
local OA = OperationAcorn
local Markup, Typing = OA.Markup, PZUIKit.Typing

-- A rich text panel with the parts TypedText uses (PZUIRichText's): paginate makes `lines` (one for each stretch of text between the
-- commands, trimmed), at x and y places; render draws nothing.
local function stubPanel()
    local c = {}
    c.__index = c
    function c:derive() local d = {}; d.__index = d; setmetatable(d, { __index = c }); return d end
    function c:new(x, y, w, h)
        return setmetatable({ x = x, y = y, width = w, height = h, marginLeft = 4, marginTop = 2, defaultFont = "Font",
            lines = {}, lineX = {}, lineY = {}, text = "", drawn = {}, yscroll = 0, renders = 0 }, self)
    end
    function c:paginate()
        self.laidW = self.width
        self.lines, self.lineX, self.lineY = {}, {}, {}
        local x, y = 0, 0
        local rest = self.text
        local pos = 1
        while pos <= #rest do
            local s, e = string.find(rest, "<[A-Z]+[^>]*>", pos)
            local piece = string.sub(rest, pos, (s or #rest + 1) - 1)
            piece = string.gsub(piece, "^%s+", "")
            piece = string.gsub(piece, "%s+$", "")
            if piece ~= "" then
                self.lines[#self.lines + 1] = piece
                self.lineX[#self.lines] = x
                self.lineY[#self.lines] = y
                x = x + #piece * 7
            end
            if s then
                if string.sub(rest, s, e) == "<LINE>" then x, y = 0, y + 14 end
                pos = e + 1
            else
                pos = #rest + 1
            end
        end
    end
    function c:ensureLaid() if self.textDirty or self.laidW ~= self.width then self:paginate() end end
    function c:paintRows() self.renders = self.renders + 1 end
    function c:getYScroll() return self.yscroll end
    function c:measure(s, font) return getTextManager():MeasureStringX(font, s) end
    c.measureRaw = c.measure
    function c:lineHeightOf(font) return getTextManager():getFontHeight(font) end
    function c:drawRect(...) self.drawn[#self.drawn + 1] = { ... } end
    function c:onMouseDown() self.mouseDown = true end
    return c
end

local function load()
    PZUIRichText = stubPanel()
    -- the kit's helpers (PZUIKit/UI: the following each frame) are the real ones, over a stand-in of the game's panel
    ISPanel = { derive = function() return setmetatable({}, { __index = function() return function() end end }) end }
    UIFont = UIFont or setmetatable({}, { __index = function(_, k) return k end })
    getTextManager = function()
        -- the folder's Medium font is a taller and wider one than the stub panel's own
        return {
            getFontHeight = function(_, font) return font == "Medium" and 29 or 14 end,
            MeasureStringX = function(_, font, s) return #tostring(s) * (font == "Medium" and 11 or 7) end,
        }
    end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "PZUIKit/RichText" then return true end
        return real(name)
    end
    local ok, err = pcall(real, "PZUIKit/TypedText")
    require = real
    if not ok then error(err, 0) end
    return PZUITypedText
end

local ms
local function clock()
    ms = 1000000
    getTimestampMs = function() return ms end
end

local function panelFor(text, speed, start)
    local Panel = load()
    local read = Markup.parse(text, speed)
    local panel = Panel:new(0, 0, 300, 200)
    panel.cursorColor = { 1, 1, 1 }
    panel.finished = 0
    panel.onFinished = function(target, run) panel.finished = panel.finished + 1 end
    local run = { parse = read, clock = start or 0, done = false }
    panel.run = run
    panel.text = Typing.rich(read, { 0.5, 0.5, 0.5 })
    panel:paginate()
    return panel, run, read
end

local function shown(panel)
    return table.concat(panel.lines, "|")
end

test("a text on its way starts with nothing drawn, and each frame adds the characters whose time has come", function()
    local panel, run = panelFor("ab\ncd", 10)
    eq(shown(panel), "|", "nothing yet: the rows are laid out whole but empty")
    truthy(panel.reveal, "a reveal over the rows")
    clock()
    panel:render()
    eq(shown(panel), "a|", "the first character at once")
    eq(run.clock, 0)
    ms = ms + 100
    panel:render()
    eq(shown(panel), "ab|")
    ms = ms + 100
    panel:render()
    eq(shown(panel), "ab|c", "the line end takes no time")
    near(run.clock, 0.2, 1e-9)
    ms = ms + 100
    panel:render()
    eq(shown(panel), "ab|cd")
    eq(panel.finished, 0, "the last character's turn is still to pass")
    ms = ms + 100
    panel:render()
    eq(panel.finished, 1)
    eq(run.done, true)
    eq(panel.reveal, nil)
    ms = ms + 100
    panel:render()
    eq(panel.finished, 1, "told once")
    eq(shown(panel), "ab|cd")
end)

test("a frame in which the count has not changed leaves the rows alone", function()
    local panel = panelFor("abcdef", 10)
    clock()
    panel:render()
    local reveal = panel.reveal
    local before = panel.lines[1]
    ms = ms + 30
    panel:render()
    eq(panel.lines[1], before)
    eq(panel.reveal, reveal)
end)

test("a gap between frames longer than the limit is a panel that was not on show: the typing waited", function()
    local panel, run = panelFor("abcdef", 10)
    clock()
    panel:render()
    ms = ms + 100
    panel:render()
    near(run.clock, 0.1, 1e-9)
    ms = ms + 60000
    panel:render()
    near(run.clock, 0.1, 1e-9, "a minute away is no time typed")
    ms = ms + 100
    panel:render()
    near(run.clock, 0.2, 1e-9)
    eq(shown(panel), "abc")
end)

test("a text resumed far on shows whole at once and is told done", function()
    local panel, run = panelFor("Oak.{p:0.5} Over.", 10, 100)
    clock()
    panel:render()
    eq(shown(panel), "Oak. Over.")
    eq(panel.finished, 1)
    eq(run.done, true)
end)

test("a click with nothing seen before it does not hurry the typing", function()
    local panel, run = panelFor("abcdefghij", 1)
    run.seen = 0
    clock()
    panel:render()
    panel:onMouseDown(5, 5)
    truthy(panel.mouseDown, "the panel's own click handling runs")
    ms = ms + 16
    panel:render()
    eq(shown(panel), "a")
    near(run.clock, 0.016, 1e-9)
end)

test("the typing keeps count of the furthest character that has come on", function()
    local panel, run = panelFor("abcdefghij", 10)
    clock()
    panel:render()
    eq(run.seen, 1)
    ms = ms + 250
    panel:render()
    eq(run.seen, 3)
    local panel2, run2 = panelFor("abcdefghij", 10)
    run2.seen = 7
    panel2:render()
    eq(run2.seen, 7, "a showing that has not got as far leaves the furthest as it was")
    for _ = 1, 3 do
        ms = ms + 400
        panel2:render()
    end
    eq(run2.seen, 10)
end)

test("a click brings the text to the furthest point seen before, and the typing goes on from there", function()
    local panel, run = panelFor("abcdefghij", 10)
    run.seen = 6
    clock()
    panel:render()
    eq(shown(panel), "a")
    panel:onMouseDown(5, 5)
    ms = ms + 16
    panel:render()
    eq(shown(panel), "abcdef", "everything up to the sixth character")
    eq(run.seen, 6)
    eq(panel.finished, 0)
    panel:onMouseDown(5, 5)
    ms = ms + 16
    panel:render()
    eq(shown(panel), "abcdef", "a second click brings nothing more: the rest was never seen")
    ms = ms + 100
    panel:render()
    eq(shown(panel), "abcdefg", "the unseen part is typed in its time")
    eq(run.seen, 7)
    panel:onMouseDown(5, 5)
    ms = ms + 16
    panel:render()
    eq(shown(panel), "abcdefg", "and the furthest point is where the typing is")
end)

test("a click cannot skip what was never seen, in front of a pause either", function()
    local panel, run = panelFor("a{p:2}bcd", 10)
    run.seen = 1
    clock()
    panel:render()
    panel:onMouseDown(5, 5)
    ms = ms + 16
    panel:render()
    eq(shown(panel), "a", "the pause is for the unseen b")
    run.seen = 2
    panel:onMouseDown(5, 5)
    ms = ms + 16
    panel:render()
    eq(shown(panel), "ab", "seen as far as b, which comes after the pause: a click brings it")
    eq(panel.finished, 0)
end)

test("a text seen to its end is shown whole by a click and told done", function()
    local panel, run, read = panelFor("a{p:3}bcdef", 1)
    run.seen = read.n
    clock()
    panel:render()
    eq(shown(panel), "a")
    panel:onMouseDown(5, 5)
    ms = ms + 16
    panel:render()
    eq(shown(panel), "abcdef")
    eq(panel.finished, 1)
    eq(run.done, true)
    eq(panel.reveal, nil)
    panel:onMouseDown(5, 5)
    ms = ms + 16
    panel:render()
    eq(panel.finished, 1, "told once")
end)

test("the click is anywhere on the panel and does not depend on its scroll or its font", function()
    local panel, run = panelFor("abcdefghij", 10)
    run.seen = 5
    panel.defaultFont = "Medium"
    panel.yscroll = -40
    clock()
    panel:render()
    panel:onMouseDown(-30, 9000)
    ms = ms + 16
    panel:render()
    eq(shown(panel), "abcde")
end)

test("the cursor is placed and sized by the panel's own font, the Medium of the folder's body", function()
    local panel = panelFor("abcdef", 10)
    panel.defaultFont = "Medium"
    clock()
    panel:render()
    eq(#panel.drawn, 1)
    local cursor = panel.drawn[1]
    near(cursor[1], panel.lineX[1] + panel.marginLeft + 11 + 1, 1e-9, "after the one character at 11 wide, not 7")
    near(cursor[2], panel.lineY[1] + panel.marginTop + 3, 1e-9, "the block starts a little under the row's top")
    near(cursor[4], 29 - 6, 1e-9, "and is the font high less the ends")
    near(cursor[3], 7, 1e-9, "a quarter of the font's height")
end)

test("laying the text out again in the middle of the typing starts the reveal over the new rows", function()
    local panel = panelFor("abcdef", 10, 0.25)
    clock()
    panel:render()
    eq(shown(panel), "abc")
    local first = panel.reveal
    panel:paginate()
    truthy(panel.reveal ~= first)
    eq(shown(panel), "", "the rows are empty until the frame")
    ms = ms + 16
    panel:render()
    eq(shown(panel), "abc")
end)

test("a coloured stretch is its own row and comes on in its turn", function()
    local panel = panelFor("go {c:FF0000}red{/c} now", 10, 0.45)
    clock()
    panel:render()
    eq(shown(panel), "go|re|", "at 0.45 s five characters are on: g, o, a space, r and e")
    eq(#panel.lines, 3)
end)

test("a cursor is drawn after the last character, only while the typing goes on", function()
    local panel = panelFor("abcdef", 10)
    clock()
    panel:render()
    eq(#panel.drawn, 1)
    local cursor = panel.drawn[1]
    near(cursor[1], panel.lineX[1] + panel.marginLeft + 7 + 1, 1e-9, "after the one character, at the row's place")
    for _ = 1, 8 do
        ms = ms + 100
        panel:render()
    end
    local drawn = #panel.drawn
    eq(panel.finished, 1)
    ms = ms + 100
    panel:render()
    eq(#panel.drawn, drawn, "none once it is done")
end)

test("a text that is not typed is the plain panel", function()
    local Panel = load()
    local panel = Panel:new(0, 0, 300, 200)
    panel.text = Typing.rich(Markup.parse("one two"), { 1, 1, 1 })
    panel:paginate()
    eq(panel.reveal, nil)
    getTimestampMs = function() return 1 end
    panel:render()
    eq(shown(panel), "one two")
    eq(panel.renders, 1)
end)

-- With PZ Optimization a panel whose drawing holds still is not drawn (a document's empty page while the title comes
-- in), and a frame drawn late would count as a gap: the typing is followed each frame before the UI draws instead.
test("a document on its way is followed each frame before the UI draws: still while it waits, then printed on time with no frame drawn", function()
    clock()
    local panel, run = panelFor("ab\ncd", 10)
    run.step = 0.2
    panel:paginate()
    run.hold = 0.35
    local empty = shown(panel)
    panel.isVisible = function() return true end
    local UI = PZUIKit.UI
    UI.liveFrame()
    eq(panel.liveLook, 0, "followed from its layout: its clock, still")
    eq(shown(panel), empty, "nothing printed while the title comes in")
    ms = ms + 200
    UI.liveFrame()
    eq(panel.liveLook, 0, "still waiting: nothing to draw afresh")
    ms = ms + 200
    UI.liveFrame()
    near(panel.liveLook, 0.05, 1e-9, "the wait is over on time: the clock moves")
    for _ = 1, 4 do
        ms = ms + 100
        UI.liveFrame()
    end
    truthy(shown(panel) ~= empty, "rows printed")
    eq(panel.renders, 0, "all of it without a frame drawn")
    for _ = 1, 10 do
        ms = ms + 100
        UI.liveFrame()
    end
    eq(run.done, true)
    eq(panel.finished, 1, "told done once")
    eq(panel.liveLook, nil, "and let go")
end)

test("a panel off the screen waits, not asked, and the typing waits; shown again, it goes on", function()
    clock()
    local panel, run = panelFor("abcdef", 10)
    local on = true
    panel.isVisible = function() return on end
    local UI = PZUIKit.UI
    UI.liveFrame()
    eq(panel.liveLook, 0)
    on = false
    ms = ms + 100
    UI.liveFrame()
    eq(panel.liveLook, 0, "not on show: it waits as it was")
    on = true
    ms = ms + 2000
    UI.liveFrame()
    eq(run.clock, 0, "the time away is a gap: the typing waited")
    ms = ms + 100
    UI.liveFrame()
    near(panel.liveLook, 0.1, 1e-9, "followed again")
    -- a frame and its drawing in the same moment add the time once
    panel:render()
    near(run.clock, 0.1, 1e-9)
end)

-- The sounds (PZUIKit.Sound): the panel's `sounds` cues, played on the screen; recorded by name.
local function sounding(panel, cues)
    local heard = {}
    getSoundManager = function() return { playUISound = function(_, name) heard[#heard + 1] = name end } end
    PZUIKit.Sound.defineAll({ ["t.key"] = { sound = "Key" }, ["t.row"] = { sound = "Row" } })
    panel.sounds = cues
    return heard
end

test("a typed character sounds its key; the first count after a layout and a click's jump do not", function()
    local panel, run = panelFor("abcdefghijklmnopqrstuvwxyz", 10)
    local heard = sounding(panel, { key = "t.key" })
    clock()
    panel:render()
    eq(#heard, 0, "the first count: no sound (it may be a text resumed far on)")
    ms = ms + 100
    panel:render()
    ms = ms + 100
    panel:render()
    eq(#heard, 2, "a key a character")
    eq(heard[1], "Key")
    run.seen = 26
    panel:onMouseDown(1, 1)
    ms = ms + 10
    panel:render()
    eq(#heard, 2, "the click brought the rest on at once: no typing sound")
end)

test("a keyboard's cue sounds the key of the character that came", function()
    local panel = panelFor("a b", 10)
    local heard = sounding(panel, { key = "t.board" })
    PZUIKit.Sound.defineKeyboard("t.keys", { letters = { "Letter" }, space = "Space" })
    PZUIKit.Sound.define("t.board", { keyboard = "t.keys" })
    clock()
    panel:render()
    for _ = 1, 3 do
        ms = ms + 100
        panel:render()
    end
    eq(table.concat(heard, " "), "Space Letter", "the space, then the b")
end)

test("a printed document sounds a row as each row begins, once, and nothing for its characters", function()
    clock()
    local panel, run = panelFor("ab\ncd\nef", 10)
    local heard = sounding(panel, { key = "t.key", row = "t.row" })
    run.step = 0.2
    panel:paginate()
    for _ = 1, 20 do
        panel:render()
        ms = ms + 50
    end
    eq(run.done, true)
    eq(table.concat(heard, " "), "Row Row Row", "each row as it begins (the first count found none begun)")
end)
