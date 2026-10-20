-- Drawing kept and played back (PZUIKit.Tape). A drawing that takes long to work out (a board of many parts, each a
-- dozen rectangles and pictures worked out in Lua) is recorded once: the game's draw calls it makes, in order, with
-- their numbers, on a tape. Each time the element must be drawn again (PZ Optimization draws an element afresh when
-- anything it shows changed: a light under the mouse) the tape is played back instead of the drawing worked out again,
-- until what it shows has changed and the owner records it anew.
--
-- With the extension API the shapes (pictures and rectangles) are kept by the API (draw.keep, its own arrays: a Lua
-- table's writes are what a recording would cost most) and played by one call (draw.play); without it, on the tape's
-- own table, played by the game's calls one by one (still without the Lua that made them). The texts, a few, stay on
-- the tape's table with the number of shapes before each, and are drawn between the shapes as they came.
--
-- A tape is recorded by drawing on a stand-in of the element (Tape.record): what it reads is the element's, what it
-- writes goes to the element, and its javaObject keeps the calls. The stand-in's place is 0, 0, so that a text drawn
-- in the API's faces (at the screen's pixels) is kept at the element's own, and played where the element is then. A
-- drawing that makes a call the tape cannot keep (a stencil, a line) is not kept: Tape.record says so, and the owner
-- draws it as it is.
PZUIKit = PZUIKit or {}
require "PZUIKit/Faces"
local Kit = PZUIKit
local Faces = Kit.Faces
local Tape = {}
Kit.Tape = Tape

-- The kinds of shapes: a picture scaled and coloured (or a rectangle, without a picture), tiled, scaled keeping its
-- aspect; and of texts: in an API face, and in the game's fonts left, centred, right, untrimmed.
local SCALED, TILED, ASPECT = 1, 2, 3
local FACE, TEXT, CENTRE, RIGHT, UNTRIMMED = 4, 5, 6, 7, 8
-- The values of a shape on the tape's own table (without the API): its kind, its picture (false for none), x, y, w, h,
-- r, g, b, a. A text on tape.texts: the shapes before it, its kind, its face's key or font, x, y, its string, r, g, b, a.
local STRIDE, TEXT_STRIDE = 10, 10
Tape.STRIDE = STRIDE

function Tape.new()
    return { n = 0, texts = {}, nTexts = 0 }
end

-- The API's tape calls, or nil: none (another version, an older API).
local function apiTapes()
    local a = PZExtAPI
    if type(a) ~= "table" or a.version ~= Kit.API_VERSION then return nil end
    local draw = a.draw
    if type(draw) ~= "table" then return nil end
    local keep, clear, play = draw.keep, draw.clear, draw.play
    if type(keep) ~= "function" or type(clear) ~= "function" or type(play) ~= "function" then return nil end
    return keep, clear, play
end

-- The recording: the tape, the API's keep (nil: on the tape's table), the shapes and texts so far.
local recording, keepCall, shapesN, textsN = nil, nil, 0, 0

local function put(kind, pic, x, y, w, h, r, g, b, a)
    local t = recording
    if keepCall then
        keepCall(t, kind, pic or false, x, y, w, h, r, g, b, a)
    else
        local at = shapesN * STRIDE
        t[at + 1], t[at + 2], t[at + 3], t[at + 4], t[at + 5] = kind, pic or false, x, y, w
        t[at + 6], t[at + 7], t[at + 8], t[at + 9], t[at + 10] = h, r, g, b, a
    end
    shapesN = shapesN + 1
end

local function putText(kind, pic, x, y, s, r, g, b, a)
    local l = recording.texts
    local at = textsN * TEXT_STRIDE
    l[at + 1], l[at + 2], l[at + 3], l[at + 4], l[at + 5] = shapesN, kind, pic, x, y
    l[at + 6], l[at + 7], l[at + 8], l[at + 9], l[at + 10] = s, r, g, b, a
    textsN = textsN + 1
end

-- The javaObject of the stand-in: the game's draw calls ISUIElement's draws make, kept; its place 0, 0; anything else
-- leaves the tape unplayable (named on it).
local keeper = {}
function keeper:DrawTextureScaledColor(tex, x, y, w, h, r, g, b, a) put(SCALED, tex, x, y, w, h, r, g, b, a) end
function keeper:DrawTextureScaled(tex, x, y, w, h, a) put(SCALED, tex, x, y, w, h, 1, 1, 1, a) end
function keeper:DrawTextureTiled(tex, x, y, w, h, r, g, b, a) put(TILED, tex, x, y, w, h, r, g, b, a) end
function keeper:DrawTextureScaledAspect(tex, x, y, w, h, r, g, b, a) put(ASPECT, tex, x, y, w, h, r, g, b, a) end
function keeper:DrawText(font, s, x, y, r, g, b, a) putText(TEXT, font, x, y, s, r, g, b, a) end
function keeper:DrawTextCentre(font, s, x, y, r, g, b, a) putText(CENTRE, font, x, y, s, r, g, b, a) end
function keeper:DrawTextRight(font, s, x, y, r, g, b, a) putText(RIGHT, font, x, y, s, r, g, b, a) end
function keeper:DrawTextUntrimmed(font, s, x, y, r, g, b, a) putText(UNTRIMMED, font, x, y, s, r, g, b, a) end
function keeper:getAbsoluteX() return 0 end
function keeper:getAbsoluteY() return 0 end
function keeper:getXScroll() return 0 end
function keeper:getYScroll() return 0 end
setmetatable(keeper, { __index = function(_, name)
    return function()
        if recording and not recording.bad then recording.bad = name end
    end
end })

local function keepFace(key, s, x, y, r, g, b, a)
    putText(FACE, key, x, y, s, r, g, b, a)
end

-- Records `draw(stand-in, ...)` on `tape` (what it held is dropped). Returns true when the tape can be played: false
-- when the drawing made a call it cannot keep (tape.bad names it), or the API refused a draw (said once). An error of
-- the drawing's own is raised after the element is itself again.
local keepFailed = false
function Tape.record(el, tape, draw, ...)
    local keep, clear = nil, nil
    if not keepFailed then keep, clear = apiTapes() end
    tape.bad = nil
    local standIn = tape.standIn
    if not standIn or tape.el ~= el then
        standIn = setmetatable({ javaObject = keeper }, { __index = el, __newindex = function(_, k, v) el[k] = v end })
        tape.standIn, tape.el = standIn, el
    end
    if keep then clear(tape) end
    local faceDraw = Faces.draw
    recording, keepCall, shapesN, textsN = tape, keep, 0, 0
    Faces.draw = keepFace
    local ok, err = pcall(draw, standIn, ...)
    Faces.draw = faceDraw
    recording, keepCall = nil, nil
    -- (what an earlier recording left past these stays: a play goes only as far as n)
    tape.n, tape.nTexts, tape.api = shapesN, textsN, keep ~= nil
    if not ok then
        if keep and string.find(tostring(err), "PZExtAPI.draw.keep", 1, true) then
            keepFailed = true
            Kit.log("tapes: the API refused a draw, kept on the tables from now on:", tostring(err))
            tape.bad = "draw.keep"
            return false
        end
        error(err, 0)
    end
    return tape.bad == nil
end

-- Where the recording is now (called by the drawing as it is recorded): the shapes and texts so far, a place on the
-- tape to play from or to (Tape.play), so that a part of a drawing can be left out and drawn as it is instead.
function Tape.mark()
    return shapesN, textsN
end

-- The shapes from..to (numbers on the tape) one by one, through the game's calls.
local function shapesByOne(jo, t, from, to)
    for i = from, to do
        local at = (i - 1) * STRIDE
        local kind, pic = t[at + 1], t[at + 2]
        if kind == SCALED then
            jo:DrawTextureScaledColor(pic or nil, t[at + 3], t[at + 4], t[at + 5], t[at + 6], t[at + 7], t[at + 8],
                t[at + 9], t[at + 10])
        elseif kind == TILED then
            jo:DrawTextureTiled(pic, t[at + 3], t[at + 4], t[at + 5], t[at + 6], t[at + 7], t[at + 8], t[at + 9],
                t[at + 10])
        else
            jo:DrawTextureScaledAspect(pic, t[at + 3], t[at + 4], t[at + 5], t[at + 6], t[at + 7], t[at + 8], t[at + 9],
                t[at + 10])
        end
    end
end

-- Plays `tape` on `el` (a tape that could be recorded: Tape.record returned true): its shapes, and its texts where
-- they came, at the element's place now; from the place s0, t0 to s1, t1 (Tape.mark), all of it when left out.
-- Returns false when the API no longer has its shapes (a newer API took over; nothing drawn): the owner records it
-- again.
function Tape.play(el, tape, s0, t0, s1, t1)
    local jo = el.javaObject
    if not jo then return true end
    s0, t0, s1, t1 = s0 or 0, t0 or 0, s1 or tape.n, t1 or tape.nTexts
    local play = nil
    if tape.api then
        local _
        _, _, play = apiTapes()
        if not play then return false end
    end
    local texts = tape.texts
    local from = s0 + 1
    local ox, oy = nil, nil
    for i = t0, t1 - 1 do
        local at = i * TEXT_STRIDE
        local before = texts[at + 1]
        if before >= from then
            if play then
                if play(el, tape, before - from + 1, from) == false then return false end
            else
                shapesByOne(jo, tape, from, before)
            end
            from = before + 1
        end
        local kind, pic, x, y, s = texts[at + 2], texts[at + 3], texts[at + 4], texts[at + 5], texts[at + 6]
        local r, g, b, a = texts[at + 7], texts[at + 8], texts[at + 9], texts[at + 10]
        if kind == FACE then
            if not ox then ox, oy = jo:getAbsoluteX() + jo:getXScroll(), jo:getAbsoluteY() + jo:getYScroll() end
            Faces.draw(pic, s, ox + x, oy + y, r, g, b, a)
        elseif kind == TEXT then
            jo:DrawText(pic, s, x, y, r, g, b, a)
        elseif kind == CENTRE then
            jo:DrawTextCentre(pic, s, x, y, r, g, b, a)
        elseif kind == RIGHT then
            jo:DrawTextRight(pic, s, x, y, r, g, b, a)
        else
            jo:DrawTextUntrimmed(pic, s, x, y, r, g, b, a)
        end
    end
    if s1 >= from then
        if play then
            if play(el, tape, s1 - from + 1, from) == false then return false end
        else
            shapesByOne(jo, tape, from, s1)
        end
    end
    return true
end

-- (the tests: the API's calls tried again)
function Tape.reset()
    keepFailed = false
end

return Tape
