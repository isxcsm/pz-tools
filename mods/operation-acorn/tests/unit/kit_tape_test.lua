-- The shared UI kit's tapes (PZUIKit Tape): a drawing recorded on a stand-in of its element keeps the game's draw calls
-- in order, its API-face texts at the element's own pixels; played back it makes the same calls where the element is
-- then: its shapes kept and played by the API (draw.keep, draw.play) between the texts, or on the tape's table and
-- played one by one without it.
require "OperationAcorn/Core"

local function load()
    PZUIKit = PZUIKit or {}
    local real = require
    local ok, err = pcall(real, "PZUIKit/Tape")
    if not ok then error(err, 0) end
    PZUIKit.Tape.reset()
    PZExtAPI = nil
    return PZUIKit.Tape, PZUIKit.Faces
end

-- An element whose javaObject logs the game's calls, at screen place 100, 50 (scrolled 0, 7).
local function element(log)
    local jo = {}
    for _, name in ipairs({ "DrawTextureScaledColor", "DrawTextureTiled", "DrawTextureScaledAspect", "DrawText",
        "DrawTextCentre" }) do
        jo[name] = function(_, ...) log[#log + 1] = { name, ... } end
    end
    jo.getAbsoluteX = function() return 100 end
    jo.getAbsoluteY = function() return 50 end
    jo.getXScroll = function() return 0 end
    jo.getYScroll = function() return 7 end
    jo.getWidth = function() return 321 end
    return { javaObject = jo, colour = { 1, 0, 0 } }
end

-- A drawing as ISUIElement's draws and the kit's API-face text make it: two rectangles, a face's text, a tiled
-- picture, a game-font text; the colour read from the element, a count written to it.
local function drawing(el, extra)
    local jo = el.javaObject
    local c = el.colour
    jo:DrawTextureScaledColor(nil, 1, 2, 3, 4, c[1], c[2], c[3], 0.5)
    jo:DrawTextureScaledColor("tex", 5, 6, 7, 8, 1, 1, 1, 1)
    PZUIKit.Faces.draw("face16", "hello", jo:getAbsoluteX() + jo:getXScroll() + 10,
        jo:getAbsoluteY() + jo:getYScroll() + 20, 1, 1, 1, 1)
    jo:DrawTextureTiled("grain", 0, 0, 50, 60, 1, 1, 1, 0.1)
    jo:DrawTextCentre("Small", "mid", 30, 40, 0.2, 0.3, 0.4, 1)
    el.drawn = (el.drawn or 0) + 1
    -- (what the drawing asks of the element's own: its size)
    el.width = jo:getWidth()
    if extra then jo:DrawTexture("tex", 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1) end
end

-- The API's tapes as a stand-in: the draws kept by table, the plays logged; `lost` forgets them (a newer API).
local function api(order)
    local kept = {}
    local a = { version = 1, draw = {} }
    a.draw.keep = function(tape, ...)
        local list = kept[tape] or {}
        kept[tape] = list
        list[#list + 1] = { ... }
    end
    a.draw.clear = function(tape) kept[tape] = nil end
    a.draw.play = function(el, tape, count, start)
        local list = kept[tape]
        if not list then return false end
        order[#order + 1] = "play " .. start .. "+" .. count
        return #list
    end
    a.kept = kept
    return a
end

test("a drawing is kept on a tape and played back as the same calls, where the element is", function()
    local Tape, Faces = load()
    local faces = {}
    Faces.draw = function(...) faces[#faces + 1] = { ... } end
    local log = {}
    local el = element(log)
    local tape = Tape.new()
    truthy(Tape.record(el, tape, drawing), "kept")
    eq(#log, 0, "nothing drawn while recording")
    eq(#faces, 0)
    eq(el.drawn, 1, "a write goes to the element")
    eq(el.width, 321, "a question asked of the element's own")
    eq(tape.n, 3, "three shapes")
    eq(tape.nTexts, 2, "two texts")
    truthy(Tape.play(el, tape))
    eq(#log, 4, "the shapes and the game-font text, one by one")
    eq(log[1][1], "DrawTextureScaledColor")
    eq(log[1][2], nil, "a rectangle: no picture")
    eq(log[1][7], 1, "its colour, read from the element")
    eq(log[1][10], 0.5)
    eq(log[2][2], "tex")
    eq(log[3][1], "DrawTextureTiled")
    eq(log[4][1], "DrawTextCentre")
    eq(log[4][3], "mid")
    eq(#faces, 1)
    eq(faces[1][3], 110, "the face's text at the element's place now")
    eq(faces[1][4], 77)
    -- moved: played where it is now
    el.javaObject.getAbsoluteX = function() return 300 end
    Tape.play(el, tape)
    eq(faces[2][3], 310)
end)

test("with the API the shapes are kept by it and played between the texts, one call each, in order", function()
    local Tape, Faces = load()
    local order = {}
    Faces.draw = function(_, s) order[#order + 1] = "face " .. s end
    local log = {}
    local el = element(log)
    local a = api(order)
    PZExtAPI = a
    local tape = Tape.new()
    truthy(Tape.record(el, tape, drawing))
    eq(#a.kept[tape], 3, "the shapes are the API's")
    eq(a.kept[tape][1][2], false, "a rectangle's picture: false")
    eq(tape[1], nil, "none on the tape's table")
    el.javaObject.DrawTextCentre = function(_, _, s) order[#order + 1] = "text " .. s end
    truthy(Tape.play(el, tape))
    eq(table.concat(order, ", "), "play 1+2, face hello, play 3+1, text mid")
    eq(#log, 0, "no shape by the game's calls")
    -- recorded again: the API's tape starts over
    truthy(Tape.record(el, tape, drawing))
    eq(#a.kept[tape], 3)
    -- a newer API without the tape: nothing drawn, the owner told
    a.kept[tape] = nil
    eq(Tape.play(el, tape), false)
    PZExtAPI = nil
end)

test("with an API that keeps texts, clips and lines too, the whole drawing is the API's and played by one call", function()
    local Tape, Faces = load()
    local order = {}
    Faces.draw = function(_, s) order[#order + 1] = "face " .. s end
    local log = {}
    local el = element(log)
    local a = api(order)
    a.draw.kinds = 12
    PZExtAPI = a
    local tape = Tape.new()
    truthy(Tape.record(el, tape, function(e)
        drawing(e)
        e.javaObject:setStencilRect(1, 2, 3, 4)
        e.javaObject:DrawLine("white", 2, 3, 4, 5, 2, 0.1, 0.2, 0.3, 0.8)
        e.javaObject:clearStencilRect()
    end))
    local kept = a.kept[tape]
    eq(#kept, 8, "three shapes, two texts, a clip, a line, the clip off")
    eq(tape.nTexts, 0, "none on the tape's table")
    eq(table.concat({ kept[3][1], tostring(kept[3][2]), kept[3][5], kept[3][11] }, " "), "4 false face16 hello",
        "a face's text: its key as w, its words last")
    eq(kept[3][3], 10, "at the element's own pixels")
    eq(kept[3][4], 20)
    eq(table.concat({ kept[5][1], kept[5][2], kept[5][11] }, " "), "6 Small mid", "a game font's text: the font, the words")
    eq(table.concat({ kept[6][1], tostring(kept[6][2]), kept[6][3], kept[6][6] }, " "), "9 false 1 4", "a clip")
    eq(table.concat({ kept[7][1], kept[7][2], kept[7][5], kept[7][6], kept[7][11] }, " "), "12 white 4 5 2",
        "a line: its far end as w, h, its thickness last")
    eq(kept[8][1], 10)
    truthy(Tape.play(el, tape))
    eq(table.concat(order, ", "), "play 1+8", "one call, no text drawn by Lua")
    eq(#log, 0)
    -- a text the API refuses (a colour left out): this tape is not kept, said on it; the next is
    a.draw.keep = function(t, kind, ...)
        if kind == 6 then error("PZExtAPI.draw.keep: r must be a number") end
        local list = a.kept[t] or {}
        a.kept[t] = list
        list[#list + 1] = { kind, ... }
    end
    eq(Tape.record(el, tape, drawing), false)
    truthy(string.find(tape.bad, "r must be a number", 1, true))
    truthy(Tape.record(el, Tape.new(), function(e) e.javaObject:DrawText("Small", "x", 0, 0, 1, 1, 1, 1) end))
    PZExtAPI = nil
end)

test("a draw the API refuses is said once: the tape is not kept, later ones go on the tables", function()
    local Tape, Faces = load()
    Faces.draw = function() end
    local el = element({})
    local a = api({})
    a.draw.keep = function() error("PZExtAPI.draw.keep: x must be a number") end
    PZExtAPI = a
    local tape = Tape.new()
    eq(Tape.record(el, tape, drawing), false)
    eq(tape.bad, "draw.keep")
    truthy(Tape.record(el, tape, drawing), "kept on its table")
    eq(tape.api, false)
    eq(tape.n, 3)
    PZExtAPI = nil
end)

test("a drawing with a call the tape cannot keep is not kept, and the element is itself again", function()
    local Tape, Faces = load()
    local realFaces = function() end
    Faces.draw = realFaces
    local el = element({})
    local jo = el.javaObject
    local tape = Tape.new()
    eq(Tape.record(el, tape, drawing, true), false)
    eq(tape.bad, "DrawTexture")
    eq(el.javaObject, jo)
    eq(Faces.draw, realFaces, "the faces draw again")
    truthy(Tape.record(el, tape, drawing))
    eq(tape.n, 3)
    -- an error in the drawing comes out, with everything put back
    local ok = pcall(Tape.record, el, tape, function() error("drawing failed") end)
    eq(ok, false)
    eq(Faces.draw, realFaces)
end)

test("a drawing marks places on its tape; played from place to place, a part between is left out", function()
    local Tape, Faces = load()
    local order = {}
    Faces.draw = function(_, s) order[#order + 1] = "face " .. s end
    local el = element({})
    el.javaObject.DrawTextureScaledColor = function(_, _, x) order[#order + 1] = "rect " .. x end
    local marks = {}
    local function parts(e)
        local jo = e.javaObject
        jo:DrawTextureScaledColor(nil, 1, 0, 1, 1, 1, 1, 1, 1)
        marks[1] = { Tape.mark() }
        jo:DrawTextureScaledColor(nil, 2, 0, 1, 1, 1, 1, 1, 1)
        PZUIKit.Faces.draw("k", "two", 0, 0, 1, 1, 1, 1)
        marks[2] = { Tape.mark() }
        PZUIKit.Faces.draw("k", "three", 0, 0, 1, 1, 1, 1)
        jo:DrawTextureScaledColor(nil, 3, 0, 1, 1, 1, 1, 1, 1)
    end
    local tape = Tape.new()
    truthy(Tape.record(el, tape, parts))
    Tape.play(el, tape, 0, 0, marks[1][1], marks[1][2])
    Tape.play(el, tape, marks[2][1], marks[2][2])
    eq(table.concat(order, ", "), "rect 1, face three, rect 3", "the part between left out")
    order = {}
    Tape.play(el, tape)
    eq(table.concat(order, ", "), "rect 1, rect 2, face two, face three, rect 3")
end)

test("a line is kept with its ends and thickness, between the shapes as it came", function()
    local Tape = load()
    local order = {}
    local el = element({})
    local jo = el.javaObject
    jo.DrawTextureScaledColor = function(_, _, x) order[#order + 1] = "rect " .. x end
    jo.DrawLine = function(_, tex, x, y, x2, y2, w, r, g, b, a)
        order[#order + 1] = table.concat({ "line", tex, x, y, x2, y2, w, r, g, b, a }, " ")
    end
    local tape = Tape.new()
    truthy(Tape.record(el, tape, function(e)
        e.javaObject:DrawTextureScaledColor(nil, 1, 0, 1, 1, 1, 1, 1, 1)
        e.javaObject:DrawLine("white", 2, 3, 4, 5, 2, 0.1, 0.2, 0.3, 0.8)
        e.javaObject:DrawTextureScaledColor(nil, 6, 0, 1, 1, 1, 1, 1, 1)
    end))
    truthy(Tape.play(el, tape))
    eq(table.concat(order, ", "), "rect 1, line white 2 3 4 5 2 0.1 0.2 0.3 0.8, rect 6")
end)

test("a tape keeps its places unlit; played round, the lit ones are drawn as they are in their places", function()
    local Tape = load()
    -- (the kit's UI as it loads: the game's panel and the hooks it asks for)
    ISPanel = { derive = function(self)
        local d = setmetatable({}, { __index = self })
        d.__index = d
        return d
    end }
    UIFont = UIFont or setmetatable({}, { __index = function(_, k) return k end })
    Events = Events or {}
    Events.OnPreUIDraw = Events.OnPreUIDraw or { Add = function() end }
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "PZUIKit/UI")
    require = real
    if not ok then error(err, 0) end
    local UI = PZUIKit.UI
    local order = {}
    local el = element({})
    el.javaObject.DrawTextureScaledColor = function(_, _, x, _, _, _, _, _, _, a)
        order[#order + 1] = "rect " .. x .. (a < 1 and " lit" or "")
    end
    -- a place lit: its hover full
    el.liveNow = 1000
    el.fx = { cur = { place = "b", from = 1, to = 1, at = 0, dur = 1 } }
    local function place(e, key, x)
        local k = UI.placeLevels(e, key)
        e.javaObject:DrawTextureScaledColor(nil, x, 0, 1, 1, 1, 1, 1, k > 0 and 0.5 or 1)
    end
    local function drawing(e)
        for i, key in ipairs({ "a", "b", "c" }) do
            Tape.part(key, i)
            place(e, key, i)
            Tape.partEnd()
        end
        e.javaObject:DrawTextureScaledColor(nil, 9, 0, 1, 1, 1, 1, 1, 1)
    end
    local tape = Tape.new()
    truthy(Tape.record(el, tape, drawing))
    eq(PZUIKit.taping, false)
    truthy(Tape.playRound(el, tape, UI.placeLit, function(e, key, i) place(e, key, i) end))
    eq(table.concat(order, ", "), "rect 1, rect 2 lit, rect 3, rect 9", "the lit place drawn lit, in its place")
    -- the light gone: all from the tape
    order = {}
    el.fx = nil
    Tape.playRound(el, tape, UI.placeLit, function() error("none is lit") end)
    eq(table.concat(order, ", "), "rect 1, rect 2, rect 3, rect 9")
end)
