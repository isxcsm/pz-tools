-- The kit's scale and faces (PZUIKit UI.setScale, Faces.build): every window open calls it, and a call that finds the
-- scale, the faces' kind and the game's fonts as the last one left them does nothing, so the windows open keep their
-- measured texts and their faces; a change of any of them makes everything again.
require "OperationAcorn/Core"

local fonts, measured, heightCalls

local function load()
    local panel = {}
    panel.derive = function(self)
        local d = setmetatable({}, { __index = self })
        d.__index = d
        return d
    end
    ISPanel = panel
    UIFont = setmetatable({}, { __index = function(_, k) return k end })
    getTimestampMs = function() return 1000 end
    -- the game's fonts: a height each, and a width a letter (the probe's letters are wider where the font has them)
    fonts = { Small = 16, Medium = 20, Large = 24, letter = 7, wide = 7 }
    measured, heightCalls = 0, 0
    getTextManager = function()
        return {
            getFontHeight = function(_, f) heightCalls = heightCalls + 1; return fonts[f] or 16 end,
            MeasureStringX = function(_, f, s)
                if string.find(s, "^abc") then measured = measured + 1 end
                local n = 0
                for i = 1, #s do n = n + (string.byte(s, i) > 255 and fonts.wide or fonts.letter) end
                return n
            end,
        }
    end
    Events.OnPreUIDraw = { Add = function() end }
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "PZUIKit/UI")
    require = real
    if not ok then error(err, 0) end
    PZUIKit.Faces.reset()
    return PZUIKit.UI, PZUIKit.Faces
end

test("a call with the scale, the faces and the fonts as they were keeps the texts measured and the faces", function()
    local UI, Faces = load()
    eq(UI.setScale(1, false), true)
    local era, face = UI.era, Faces.face(UIFont.Small)
    eq(UI.textWidth("abc"), 21)
    eq(measured, 1)
    eq(UI.setScale(1, false), true, "and the same answer")
    eq(UI.setScale(1), true, "nil keeps the faces' kind")
    eq(UI.textWidth("abc"), 21)
    eq(measured, 1, "measured once")
    eq(Faces.face(UIFont.Small), face, "the faces are the ones made")
    eq(UI.era, era, "no new era")
end)

test("a new scale, or fonts the game made again, make the texts and the faces anew", function()
    local UI, Faces = load()
    UI.setScale(1, false)
    UI.textWidth("abc")
    local face = Faces.face(UIFont.Small)
    -- the font option: a taller Small font
    fonts.Small = 19
    UI.setScale(1, false)
    UI.textWidth("abc")
    eq(measured, 2, "the heights changed: measured again")
    truthy(Faces.face(UIFont.Small) ~= face, "and the faces made again")
    -- the language: the same heights, the Korean letters in another width
    local face2 = Faces.face(UIFont.Small)
    fonts.wide = 12
    UI.setScale(1, false)
    UI.textWidth("abc")
    eq(measured, 3, "the probe changed: measured again")
    truthy(Faces.face(UIFont.Small) ~= face2)
    -- the scale
    local era = UI.era
    UI.setScale(2, false)
    eq(UI.S, 2)
    eq(UI.era, era + 1)
    UI.textWidth("abc")
    eq(measured, 4)
    UI.setScale(2, false)
    UI.textWidth("abc")
    eq(measured, 4, "and kept again")
    -- the faces forgotten whole
    Faces.reset()
    UI.setScale(2, false)
    UI.textWidth("abc")
    eq(measured, 5, "the faces forgotten: everything made again")
end)

test("a wrap or a cut is kept for the last width its text was asked at only", function()
    local UI = load()
    UI.setScale(1, false)
    local text = "one two three four five six seven"
    local a = UI.wrapMemo(text, 100)
    eq(UI.wrapMemo(text, 100), a, "the same width: the same lines")
    eq(a[1], "one two three")
    local b = UI.wrapMemo(text, 60)
    truthy(b ~= a)
    eq(b[1], "one two")
    local again = UI.wrapMemo(text, 100)
    truthy(again ~= a, "the first width was not kept")
    eq(table.concat(again, "|"), table.concat(a, "|"), "and comes out the same")
    local cut = UI.fitMemo(text, 70)
    eq(cut, UI.fit(text, 70))
    eq(UI.fitMemo(text, 70), cut)
    eq(UI.fitMemo(text, 140), UI.fit(text, 140), "another width: its own cut")
    eq(UI.fitMemo(text, 70), cut, "and the first again, the same")
    -- other texts keep theirs
    local other = UI.wrapMemo("alpha beta", 100)
    eq(UI.wrapMemo("alpha beta", 100), other)
end)

test("a font's height is asked of its face once, again before each frame draws, and kept", function()
    local UI = load()
    UI.setScale(1, false)
    local before = heightCalls
    for _ = 1, 10 do
        UI.fontHeight()
        UI.fontHeight(UIFont.Small)
        UI.fontHeight(UIFont.Medium)
        UI.titleBarHeight()
        UI.resizeWidgetHeight()
    end
    eq(heightCalls - before, 3, "three kinds of ask, once each")
    eq(UI.fontHeight(UIFont.Medium), 20)
    -- the font option changes under the window: shown from the next frame
    fonts.Medium = 25
    eq(UI.fontHeight(UIFont.Medium), 20, "kept for the frame")
    before = heightCalls
    UI.liveFrame()
    eq(heightCalls - before, 3, "each kind asked again before the frame draws")
    eq(UI.fontHeight(UIFont.Medium), 25, "the new height in the next")
    UI.fontHeight()
    eq(heightCalls - before, 3, "and none asked as it draws")
    -- at a scale the height comes out in design units
    UI.setScale(2, false)
    eq(UI.fontHeight(UIFont.Medium), 12.5, "a new scale is not served from the old")
end)
