-- The faces the kit's texts are drawn in (UI.lua's rule block): a face is one of the game's font names
-- (UIFont.Small, Medium, Large) at the scale now. With the extension API's UI fonts (PZExtAPI.text) a face is the
-- API's font of the name's design height times the scale (Small 16, Medium 20, Large 24 design units: 32, 40 and 48
-- pixels at 1080p; Massive 32, for a title, only through UI.titleFont: the game's Massive has no Korean letters),
-- whatever the game's font option says; without them it is the game's own font of that name, as the
-- font option made it. This file only finds the faces, measures and draws with them; UI.lua decides the scale and
-- where a text goes.
--
-- The API may be missing (an older PZ Extension API) or one of its calls may throw: then the faces are the game's fonts
-- again, for the rest of the session, said once in the log (Faces.onFail tells UI.lua, which goes back to the font's
-- scale). A frame asks only tables made when the scale was set: a face of a font, its key and height.
PZUIKit = PZUIKit or {}
local Kit = PZUIKit
local Faces = {}
Kit.Faces = Faces

-- The extension API's version the kit is written for, and the name it declares its fonts under.
Kit.API_VERSION = 1
Kit.MOD = "PZUIKit"

function Kit.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[PZUIKit] " .. table.concat(parts, " "))
end

-- The extension API, or nil: not installed, or another version.
local function api()
    local a = PZExtAPI
    if type(a) ~= "table" or type(a.client) ~= "function" or a.version ~= Kit.API_VERSION then return nil end
    return a
end

local floor = math.floor

-- The design heights of the game's font names, in design units (UIFont.NewSmall and the like are the same sizes).
local DESIGN = {}
local designed = false
local function design(name, h)
    local font = UIFont and UIFont[name]
    if font ~= nil then DESIGN[font] = h end
end

-- The screen height one design unit is a pixel at, and the steps the scale goes in (an eighth).
Faces.SCREEN_BASE = 540
Faces.STEPS = 8

-- Whether the faces are the API's (true) or the game's fonts (false).
Faces.on = false

local handle                      -- this mod's handle (while the API is used)
local apiText, apiFont, apiMeasure, apiHeight, apiDraw
local failed = false              -- a call threw or answered nothing: the game's fonts for the session
local drawn = false               -- a draw went through once: the next ones are called without a guard
local keys = {}                   -- pixel height -> the API's key (false: none), kept across scales
local faces = {}                  -- font -> face { font, key (nil: the game's font) }, for the scale and the mode now
local small                       -- the Small face (asked most)

-- The scale of the screen: its height over 540, down to an eighth, never under 1 (720p 1.25, 900p 1.625, 1080p 2,
-- 1440p 2.625, 2160p 4). Design numbers that are multiples of 8 come out whole pixels.
function Faces.screenScale(height)
    return math.max(1, floor(height * Faces.STEPS / Faces.SCREEN_BASE) / Faces.STEPS)
end

-- Called (no arguments) when a call of the API fails while the faces are in use: UI.lua goes back to the game's fonts.
Faces.onFail = nil

-- Gives the API up for the session, said once in the log; `quiet` while the faces are being made (the caller then
-- makes the game's).
local function fail(why, quiet)
    if failed then return end
    failed = true
    Faces.on = false
    Kit.log("UI fonts: the game's fonts (" .. tostring(why) .. ")")
    if not quiet and Faces.onFail then Faces.onFail() end
end

-- Whether the API's UI fonts can be used: present, with the four calls, and none of them has failed.
function Faces.available()
    if failed then return false end
    local a = api()
    local t = a and a.text
    if type(t) ~= "table" or type(t.font) ~= "function" or type(t.measure) ~= "function"
        or type(t.fontHeight) ~= "function" or type(t.draw) ~= "function" then
        return false
    end
    local h = a.client(Kit.MOD)
    if not h then return false end
    handle = h
    apiText, apiFont, apiMeasure, apiHeight, apiDraw = t, t.font, t.measure, t.fontHeight, t.draw
    return true
end

-- Whether the API's calls can be made now. A newer API taking over in a running game (the developer's reload) puts new
-- functions into the same table, and the ones read before refuse to run: they are read again (the keys stay: a key is
-- its height). An API that went away, or is another version now, is given up (fail). Three lookups a call.
local function current()
    local a = PZExtAPI
    local t = type(a) == "table" and a.text or nil
    if t == apiText and t.draw == apiDraw then return true end
    if Faces.available() then return true end
    fail("the extension API changed under the game")
    return false
end

-- The API's key of a font `px` pixels high (asked once a size), or nil when it has none.
local function keyFor(px)
    local key = keys[px]
    if key == nil then
        local ok, k = pcall(apiFont, handle, px)
        if not ok then return nil, k end
        key = k or false
        keys[px] = key
    end
    return key or nil
end

-- The face of a font for the scale and the mode now (made the first time it is asked, then kept).
local function make(font, s)
    if Faces.on then
        local h = DESIGN[font]
        if h then
            local px = floor(h * s + 0.5)
            local key, err = keyFor(px)
            if not key then return nil, err or ("no font of " .. px .. " px") end
            local ok, height = pcall(apiHeight, handle, key)
            if not ok or type(height) ~= "number" or height <= 0 then return nil, ok and "no height" or height end
            local okW, w = pcall(apiMeasure, handle, key, "x x")
            if not okW or type(w) ~= "number" then return nil, okW and "no width" or w end
            return { font = font, key = key }
        end
    end
    return { font = font, key = nil }
end

local scale = 1

-- Sets the faces for a scale: the API's (`useApi`, after Faces.available) or the game's fonts. False when the API's
-- were asked for and could not be made (the game's fonts are set instead, and the API is given up).
function Faces.build(s, useApi)
    if not designed then
        designed = true
        design("Small", 16); design("Medium", 20); design("Large", 24); design("Massive", 32)
        design("NewSmall", 16); design("NewMedium", 20); design("NewLarge", 24)
    end
    scale = s
    Faces.on = (useApi and not failed) and true or false
    faces, small = {}, nil
    if Faces.on then
        for font in pairs(DESIGN) do
            local face, err = make(font, s)
            if not face then
                fail(err, true)
                faces = {}
                break
            end
            faces[font] = face
        end
    end
    small = Faces.face(UIFont.Small)
    return Faces.on or not useApi
end

-- The face of a font (nil: Small).
function Faces.face(font)
    if font == nil then return small or Faces.face(UIFont.Small) end
    local face = faces[font]
    if not face then
        face = make(font, scale)
        faces[font] = face
    end
    return face
end

-- A font's height in pixels: asked each time (O(1)), as a font's line height can change under an open window (the
-- game's fonts made again for an option or a language, the API's drawn font arriving after its first frames).
function Faces.height(font)
    local face = Faces.face(font)
    local key = face.key
    if key and current() then return apiHeight(handle, key) end
    return getTextManager():getFontHeight(face.font)
end

-- A text's width in pixels in a face (the game's MeasureStringX for a game font).
function Faces.measure(face, s)
    local key = face.key
    if key and current() then return apiMeasure(handle, key, s) end
    return getTextManager():MeasureStringX(face.font, s)
end

-- Draws a text in an API face at screen pixels x, y. The first draw of the session is guarded: an API that throws there
-- is given up (fail) and the text is not drawn this frame.
function Faces.draw(key, s, x, y, r, g, b, a)
    if not current() then return end
    if drawn then return apiDraw(handle, key, s, x, y, r, g, b, a) end
    local ok, err = pcall(apiDraw, handle, key, s, x, y, r, g, b, a)
    if ok then drawn = true else fail(err) end
end

-- Forgets a failure (the tests start each case over).
function Faces.reset()
    failed, drawn, keys, faces, small = false, false, {}, {}, nil
    Faces.on = false
    DESIGN, designed = {}, false
end

return Faces
