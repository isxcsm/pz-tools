-- Titles over the screen through the extension API's text (PZExtAPI.text.title): what every mod drawing one does, once.
-- The style asked for when the API has it (an older API may lack some: a stamp then; a brief title it lacks is not
-- drawn), a dark band behind a title over a window (busy, bright panels), its sounds (PZUIKit.Sound.titleSounds), and an
-- older API's limits (no sounds, no scale) taken in turn. A mod gives its API table and handle and the title's spec; what
-- it does when no title is drawn (a line the character says) is its own.
require "PZUIKit/Sound"
PZUIKit = PZUIKit or {}
local Titles = {}
PZUIKit.Titles = Titles

-- The API's text when its drawing hook is in (`api`: the mod's PZExtAPI table, or nil), else nil.
function Titles.textApi(api)
    local t = api and api.text
    if type(t) ~= "table" or type(t.title) ~= "function" then return nil end
    local ok, status = pcall(t.status)
    if not ok or status ~= "applied" then return nil end
    return t
end

-- The style to draw: `wanted` (else "dust") when the API has it, else "stamp"; nil for a brief title the API does not
-- have. The API's styles are asked once (again for another API's text).
local styles, stylesOf
function Titles.styleFor(t, wanted)
    wanted = wanted or "dust"
    if stylesOf ~= t then
        styles, stylesOf = {}, t
        local ok, list = pcall(t.styles)
        if ok and type(list) == "table" then
            for _, name in ipairs(list) do styles[name] = true end
        elseif ok and list ~= nil and list.size then
            for i = 0, list:size() - 1 do styles[list:get(i)] = true end
        end
    end
    if styles[wanted] then return wanted end
    if wanted == "brief" then return nil end
    return "stamp"
end

-- A title over a window gets this dark band behind it, so that it reads; over the world the style's own (if any) is
-- enough. A window counts when it is at least WINDOW_W by WINDOW_H and crosses the middle of the screen across, between
-- WINDOW_TOP and WINDOW_BOTTOM of its height (where titles go); a window filling the screen (the game's own layers) does
-- not. A brief title is judged where it goes, low on the screen (BRIEF_TOP to BRIEF_BOTTOM): its own faint backdrop is
-- lost on a window's panel and its line read as the panel's.
Titles.OVER_WINDOW = 0.75
local WINDOW_W, WINDOW_H, WINDOW_TOP, WINDOW_BOTTOM = 300, 200, 0.08, 0.6
local BRIEF_TOP, BRIEF_BOTTOM = 0.74, 0.86
local NO_TABLE = {}

-- Whether a window is open where a title goes (looked at once a title, not on a clock); `brief` for a brief title's place.
function Titles.overWindow(brief)
    local ui = UIManager and UIManager.getUI and UIManager.getUI()
    if not ui then return false end
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local mid = sw / 2
    local top, bottom = sh * (brief and BRIEF_TOP or WINDOW_TOP), sh * (brief and BRIEF_BOTTOM or WINDOW_BOTTOM)
    for i = 0, ui:size() - 1 do
        local el = ui:get(i)
        local t = el and el:isVisible() and (el:getTable() or NO_TABLE)
        -- (a collapsed window, such as the inventory folded to its bar, keeps its open height)
        if t and not t.isCollapsed then
            local x, y, w, h = el:getX(), el:getY(), el:getWidth(), el:getHeight()
            if w >= WINDOW_W and h >= WINDOW_H and w < sw and x < mid and x + w > mid and y < bottom and y + h > top then
                return true
            end
        end
    end
    return false
end

-- Where a title's middle goes for `at`, as a share of the screen's height (the API's spec.y): "center" puts the title
-- and its line together in the middle (a big title's line hangs below it: their block's middle is about 0.035 under the
-- title's), a number is taken as it is; nil leaves the style's place.
Titles.CENTER, Titles.CENTER_ALONE = 0.465, 0.5
function Titles.place(at, withLine)
    if at == "center" then return withLine and Titles.CENTER or Titles.CENTER_ALONE end
    if type(at) == "number" and at >= 0 and at <= 1 then return at end
    return nil
end

-- Draws a title: `spec` as the API's text.title takes it (text, subtitle, style: the one wanted, player, color...), its
-- style, backdrop (unless given) and sounds filled in here. `log(...)`: where a failure is told. True when it is drawn,
-- and its key (Titles.shown).
function Titles.show(api, handle, spec, log)
    local t = Titles.textApi(api)
    if not (t and handle and spec and spec.text) then return false end
    local style = Titles.styleFor(t, spec.style)
    if not style then return false end
    -- (an emblem is its style's plate's: a style the API lacks goes without it)
    if style ~= spec.style then spec.emblem = nil end
    spec.style = style
    if spec.backdrop == nil and Titles.overWindow(style == "brief") then spec.backdrop = Titles.OVER_WINDOW end
    spec.sounds, spec.subtitleSounds = PZUIKit.Sound.titleSounds(style)
    if not spec.subtitle then spec.subtitleSounds = nil end
    local ok, err = pcall(t.title, handle, spec)
    if not ok and (spec.sounds or spec.subtitleSounds) then
        -- (an older PZ Extension API has no sounds: the title silent)
        spec.sounds, spec.subtitleSounds = nil, nil
        ok, err = pcall(t.title, handle, spec)
    end
    if not ok and spec.scale then
        -- (an older PZ Extension API has no scale: the title at its style's size)
        spec.scale = nil
        ok, err = pcall(t.title, handle, spec)
    end
    if not ok and log then log("title:", tostring(err)) end
    return ok, ok and err or nil
end

-- Whether a title drawn (its key, as Titles.show gave it) is still on the screen or waiting its turn: false once it has
-- left.
function Titles.shown(api, handle, key)
    local t = Titles.textApi(api)
    if not (t and t.shown and handle and key) then return false end
    local ok, on = pcall(t.shown, handle, key)
    return ok and on == true
end

return Titles
