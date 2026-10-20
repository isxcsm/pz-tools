-- Drawing kept and played back (PZUIKit.Tape). A drawing that takes long to work out (a board of many parts, each a
-- dozen rectangles and pictures worked out in Lua) is recorded once: the game's draw calls it makes, in order, with
-- their numbers, on a tape. Each time the element must be drawn again (PZ Optimization draws an element afresh when
-- anything it shows changed: a light under the mouse) the tape is played back instead of the drawing worked out again,
-- until what it shows has changed and the owner records it anew.
--
-- With the extension API every draw (pictures and rectangles, texts, clips, lines) is kept by the API (draw.keep, its
-- own arrays: a Lua table's writes are what a recording would cost most) and the whole tape played by one call
-- (draw.play), no Lua run for any draw. An API from before the texts (draw.kinds) keeps the shapes alone; without the
-- API they are kept on the tape's own table, played by the game's calls one by one (still without the Lua that made
-- them). The texts and the clips then stay on the tape's table with the number of shapes before each, and are made
-- between the shapes as they came.
--
-- A tape is recorded by drawing on a stand-in of the element (Tape.record): what it reads is the element's, what it
-- writes goes to the element, and its javaObject keeps the calls. The stand-in's place is 0, 0, so that a text drawn
-- in the API's faces (at the screen's pixels) is kept at the element's own, and played where the element is then. A
-- drawing that makes a call the tape cannot keep (a picture drawn another way, a round clip) is not kept: Tape.record says
-- so, and the owner draws it as it is.
--
-- What lights (a place under the mouse, a click's flash: UI.placeLevels) is not kept: while a tape records, every light
-- reads dark (PZUIKit.taping). A drawing marks its places as parts (Tape.part); Tape.playRound plays the tape with the
-- lit ones left out and drawn as they are in their places, so that the lights come and go over a kept drawing.
PZUIKit = PZUIKit or {}
require "PZUIKit/Faces"
local Kit = PZUIKit
local Faces = Kit.Faces
local Tape = {}
Kit.Tape = Tape

-- The kinds of shapes: a picture scaled and coloured (or a rectangle, without a picture), tiled, scaled keeping its
-- aspect; and of the rest: texts in an API face, and in the game's fonts left, centred, right, untrimmed; a clip set,
-- taken off, and painted back; a line.
local SCALED, TILED, ASPECT = 1, 2, 3
local FACE, TEXT, CENTRE, RIGHT, UNTRIMMED = 4, 5, 6, 7, 8
local CLIP, UNCLIP, RECLIP, LINE = 9, 10, 11, 12
-- The values of a shape on the tape's own table (without the API): its kind, its picture (false for none), x, y, w, h,
-- r, g, b, a. A text, a clip or a line on tape.texts: the shapes before it, its kind, its face's key or font (a line's
-- picture), x, y, its string (a clip's w, a line's x2), r (a clip's h), g, b, a, and a line's y2 and thickness.
local STRIDE, TEXT_STRIDE = 10, 12
Tape.STRIDE = STRIDE

function Tape.new()
    return { n = 0, texts = {}, nTexts = 0 }
end

-- The API's tape calls, or nil: none (another version, an older API); and whether it keeps the texts, clips and lines
-- too (its draw.kinds: the last kind it takes).
local LAST_KIND = 12
local function apiTapes()
    local a = PZExtAPI
    if type(a) ~= "table" or a.version ~= Kit.API_VERSION then return nil end
    local draw = a.draw
    if type(draw) ~= "table" then return nil end
    local keep, clear, play = draw.keep, draw.clear, draw.play
    if type(keep) ~= "function" or type(clear) ~= "function" or type(play) ~= "function" then return nil end
    return keep, clear, play, type(draw.kinds) == "number" and draw.kinds >= LAST_KIND
end

-- The recording: the tape, the API's keep (nil: on the tape's table) and whether it keeps every draw, the draws so far
-- (with the API keeping every draw, all of them; else the shapes) and the texts so far on the tape's table.
local recording, keepCall, keepAll, shapesN, textsN = nil, nil, false, 0, 0
-- (the part being drawn: its place on recording.parts)
local part = nil

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

-- A text, a clip or a line kept by the API: as the API takes it (draw.keep); one it refuses (a font or a colour left
-- out) leaves this tape unkept, the others as they are.
local function keepMore(kind, pic, x, y, s, r, g, b, a, y2, thickness)
    local t = recording
    local ok, err
    if kind == FACE then
        ok, err = pcall(keepCall, t, kind, false, x, y, pic, 0, r, g, b, a, s)
    elseif kind <= UNTRIMMED then
        ok, err = pcall(keepCall, t, kind, pic, x, y, 0, 0, r, g, b, a, s)
    elseif kind == LINE then
        ok, err = pcall(keepCall, t, kind, pic or false, x, y, s, y2, r, g, b, a, thickness)
    else
        ok, err = pcall(keepCall, t, kind, false, x, y, s, r, 0, 0, 0, 0)
    end
    if ok then
        shapesN = shapesN + 1
    elseif not t.bad then
        t.bad = tostring(err)
    end
end

local function putText(kind, pic, x, y, s, r, g, b, a, y2, thickness)
    if keepAll then return keepMore(kind, pic, x, y, s, r, g, b, a, y2, thickness) end
    local l = recording.texts
    local at = textsN * TEXT_STRIDE
    l[at + 1], l[at + 2], l[at + 3], l[at + 4], l[at + 5] = shapesN, kind, pic, x, y
    l[at + 6], l[at + 7], l[at + 8], l[at + 9], l[at + 10] = s, r, g, b, a
    l[at + 11], l[at + 12] = y2, thickness
    textsN = textsN + 1
end

-- The javaObject of the stand-in: the game's draw calls ISUIElement's draws make, kept; its place 0, 0; another draw
-- (a call named Draw..., a clip of another kind) leaves the tape unplayable (named on it); anything else (its size, the
-- mouse) is asked of the element's own.
local keeper = {}
function keeper:DrawTextureScaledColor(tex, x, y, w, h, r, g, b, a) put(SCALED, tex, x, y, w, h, r, g, b, a) end
function keeper:DrawTextureScaled(tex, x, y, w, h, a) put(SCALED, tex, x, y, w, h, 1, 1, 1, a) end
function keeper:DrawTextureTiled(tex, x, y, w, h, r, g, b, a) put(TILED, tex, x, y, w, h, r, g, b, a) end
function keeper:DrawTextureScaledAspect(tex, x, y, w, h, r, g, b, a) put(ASPECT, tex, x, y, w, h, r, g, b, a) end
function keeper:DrawText(font, s, x, y, r, g, b, a) putText(TEXT, font, x, y, s, r, g, b, a) end
function keeper:DrawTextCentre(font, s, x, y, r, g, b, a) putText(CENTRE, font, x, y, s, r, g, b, a) end
function keeper:DrawTextRight(font, s, x, y, r, g, b, a) putText(RIGHT, font, x, y, s, r, g, b, a) end
function keeper:DrawTextUntrimmed(font, s, x, y, r, g, b, a) putText(UNTRIMMED, font, x, y, s, r, g, b, a) end
function keeper:setStencilRect(x, y, w, h) putText(CLIP, false, x, y, w, h, 0, 0, 0) end
function keeper:clearStencilRect() putText(UNCLIP, false, 0, 0, 0, 0, 0, 0, 0) end
function keeper:repaintStencilRect(x, y, w, h) putText(RECLIP, false, x, y, w, h, 0, 0, 0) end
function keeper:DrawLine(tex, x, y, x2, y2, thickness, r, g, b, a) putText(LINE, tex, x, y, x2, r, g, b, a, y2, thickness) end
function keeper:getAbsoluteX() return 0 end
function keeper:getAbsoluteY() return 0 end
function keeper:getXScroll() return 0 end
function keeper:getYScroll() return 0 end
local function unkept(name)
    return function()
        if recording and not recording.bad then recording.bad = name end
    end
end

-- The stand-in's javaObject for an element whose own is `jo`.
local function keeperOf(jo)
    return setmetatable({}, { __index = function(t, name)
        local call = keeper[name]
        if call then return call end
        if not jo or string.find(name, "^Draw") or string.find(name, "Stencil") then
            call = unkept(name)
        else
            call = function(_, ...) return jo[name](jo, ...) end
        end
        rawset(t, name, call)
        return call
    end })
end

local function keepFace(key, s, x, y, r, g, b, a)
    putText(FACE, key, x, y, s, r, g, b, a)
end

-- Records `draw(stand-in, ...)` on `tape` (what it held is dropped). Returns true when the tape can be played: false
-- when the drawing made a call it cannot keep (tape.bad names it), or the API refused a draw (said once). An error of
-- the drawing's own is raised after the element is itself again.
local keepFailed = false
function Tape.record(el, tape, draw, ...)
    local keep, clear, all = nil, nil, false
    if not keepFailed then
        local _
        keep, clear, _, all = apiTapes()
    end
    tape.bad = nil
    local standIn = tape.standIn
    if not standIn or tape.el ~= el then
        standIn = setmetatable({ javaObject = keeperOf(el.javaObject) },
            { __index = el, __newindex = function(_, k, v) el[k] = v end })
        tape.standIn, tape.el = standIn, el
    end
    if keep then clear(tape) end
    local faceDraw = Faces.draw
    recording, keepCall, keepAll, shapesN, textsN = tape, keep, keep ~= nil and all, 0, 0
    tape.parts, tape.nParts, part = tape.parts or {}, 0, nil
    Faces.draw = keepFace
    Kit.taping = true
    local ok, err = pcall(draw, standIn, ...)
    Kit.taping = false
    Faces.draw = faceDraw
    recording, keepCall, keepAll, part = nil, nil, false, nil
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

-- A part of the drawing being recorded, from here to Tape.partEnd: a place that lights (`key`, as UI.placeLevels has
-- it), with `data` for the owner to draw it again (Tape.playRound). Nothing when no tape records.
function Tape.part(key, data)
    if not recording then return end
    local at = recording.nParts * 6
    local parts = recording.parts
    parts[at + 1], parts[at + 2], parts[at + 3], parts[at + 4] = key, data, shapesN, textsN
    part = at
end

function Tape.partEnd()
    if not part then return end
    local parts = recording.parts
    parts[part + 5], parts[part + 6] = shapesN, textsN
    recording.nParts = recording.nParts + 1
    part = nil
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
        elseif kind == UNTRIMMED then
            jo:DrawTextUntrimmed(pic, s, x, y, r, g, b, a)
        elseif kind == CLIP then
            jo:setStencilRect(x, y, s, r)
        elseif kind == UNCLIP then
            jo:clearStencilRect()
        elseif kind == LINE then
            jo:DrawLine(pic, x, y, s, texts[at + 11], texts[at + 12], r, g, b, a)
        else
            jo:repaintStencilRect(x, y, s, r)
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

-- Plays `tape` with each part that `lit(el, key)` says is lit left out and drawn by `drawPart(el, key, data)` in its
-- place (the parts in the order they were drawn). Returns false as Tape.play does (nothing more drawn).
function Tape.playRound(el, tape, lit, drawPart)
    local parts = tape.parts
    local s, t = 0, 0
    for i = 0, (tape.nParts or 0) - 1 do
        local at = i * 6
        local key = parts[at + 1]
        if lit(el, key) then
            if not Tape.play(el, tape, s, t, parts[at + 3], parts[at + 4]) then return false end
            drawPart(el, key, parts[at + 2])
            s, t = parts[at + 5], parts[at + 6]
        end
    end
    return Tape.play(el, tape, s, t)
end

-- An element's drawing (`draw(el, arg)`, its prerender's) kept on a tape of its own (el.uiKept) and played each time
-- it is drawn, recorded again when `keyA` or `keyB` (what it shows: values that are others when it changes), its size
-- or the scale change; with `lit` and `drawPart` played round its lit parts (Tape.playRound). While its window fades
-- it is drawn as it is; one the tape cannot keep (said once for the element) always.
function Tape.keep(el, draw, arg, keyA, keyB, lit, drawPart)
    -- (an element's tapes by their drawings: one element can keep more than one, each its own)
    local tapes = el.uiKept
    if not tapes then
        tapes = {}
        el.uiKept = tapes
    end
    local kept = tapes[draw]
    local UI = Kit.UI
    if kept == false or UI.faded(el, 1) ~= 1 then return draw(el, arg) end
    local S = UI.S
    if not (kept and kept.a == keyA and kept.b == keyB and kept.w == el.width and kept.h == el.height
            and kept.S == S) then
        local tape = kept and kept.tape or Tape.new()
        if not Tape.record(el, tape, draw, arg) then
            Kit.log("tapes: a drawing is not kept, drawn each time (" .. tostring(el.Type) .. ": "
                .. tostring(tape.bad) .. ")")
            tapes[draw] = false
            return draw(el, arg)
        end
        kept = { tape = tape, a = keyA, b = keyB, w = el.width, h = el.height, S = S }
        tapes[draw] = kept
    end
    local played
    if drawPart then
        played = Tape.playRound(el, kept.tape, lit, drawPart)
    else
        played = Tape.play(el, kept.tape)
    end
    if played then return end
    -- (a tape the API lost: recorded again next time)
    kept.S = nil
    draw(el, arg)
end

-- (the tests: the API's calls tried again)
function Tape.reset()
    keepFailed = false
end

return Tape
