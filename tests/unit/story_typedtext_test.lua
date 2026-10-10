-- The folder's text panel that types (client/Story/TypedText): with the game's rich text panel stood in for by one that
-- cuts the text at its commands into rows, what a frame does with the clock, the gaps, a click, a layout in the middle of
-- the typing, and the end of it.
require "OperationAcorn/Core"
require "OperationAcorn/Markup"
require "OperationAcorn/Story/Typing"
local OA = OperationAcorn
local Markup, Typing = OA.Markup, OA.Typing

-- A rich text panel with the parts TypedText uses: paginate makes `lines` (one for each stretch of text between the
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
    function c:render() self.renders = self.renders + 1 end
    function c:getYScroll() return self.yscroll end
    function c:drawRect(...) self.drawn[#self.drawn + 1] = { ... } end
    function c:onMouseDown() self.mouseDown = true end
    return c
end

local function load()
    ISRichTextPanel = stubPanel()
    getTextManager = function()
        return { getFontHeight = function() return 14 end, MeasureStringX = function(_, _, s) return #tostring(s) * 7 end }
    end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Story/TypedText")
    require = real
    if not ok then error(err, 0) end
    return OATypedText
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

test("a click types the rest at once", function()
    local panel, run = panelFor("abcdefghij", 1)
    clock()
    panel:render()
    eq(shown(panel), "a")
    panel:onMouseDown(5, 5)
    truthy(panel.mouseDown, "the panel's own click handling still runs")
    ms = ms + 16
    panel:render()
    eq(shown(panel), "abcdefghij")
    eq(panel.finished, 1)
    -- a click on a text that is done does nothing
    panel:onMouseDown(5, 5)
    eq(run.done, true)
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
