-- The titles of events (OA.Sync.title): drawn big over the player's screen by the extension API's text
-- (PZExtAPI.text.title, queued one at a time), or, without it, as a text over the character.
require "OperationAcorn/Sync"
require "OperationAcorn/Client"
require "OperationAcorn/Markup"
local OA = OperationAcorn
local Titles = {}
OA.Titles = Titles

-- The tones a title can take over its style's colour, title and line under it.
Titles.TONES = {
    gold = { { 1.00, 0.86, 0.50 }, { 0.95, 0.88, 0.70 } },
    amber = { { 1.00, 0.70, 0.40 }, { 0.95, 0.82, 0.66 } },
    green = { { 0.62, 1.00, 0.70 }, { 0.78, 0.95, 0.82 } },
    red = { { 1.00, 0.55, 0.50 }, { 0.95, 0.75, 0.72 } },
    -- an acorn's shell: the operation's own name
    acorn = { { 0.88, 0.70, 0.45 }, { 0.92, 0.86, 0.74 } },
}

-- Every title goes first, the one on the screen leaving at once (the dev panel's switch for trying titles).
Titles.now = false

-- A text by key and arguments; an argument that is itself a text ({ key, args }: a mission's or a capstone's name) is
-- translated here, on the player's side.
local function text(key, args)
    if type(key) ~= "string" then return nil end
    local list = {}
    for i, arg in ipairs(args or {}) do
        if type(arg) == "table" then list[i] = text(arg.key, arg.args) or "" else list[i] = arg end
    end
    return getText(key, unpack(list))
end
Titles.text = text

-- The local characters the title is for (every one for a nil playerId).
local function charactersOf(playerId)
    local found = {}
    for i = 0, getNumActivePlayers() - 1 do
        local character = getSpecificPlayer(i)
        if character and (playerId == nil or OA.Client.id(character) == playerId) then found[#found + 1] = character end
    end
    return found
end
Titles.charactersOf = charactersOf

-- The extension API's text, when its drawing hook is in.
local function textApi()
    local api = OA.api()
    local t = api and api.text
    if type(t) ~= "table" or type(t.title) ~= "function" then return nil end
    local ok, status = pcall(t.status)
    if not ok or status ~= "applied" then return nil end
    return t
end
Titles.textApi = textApi

-- The style to ask the API for: the detail's (else "dust") when the API has it (an older PZ Extension API may not have "dust" or
-- "unveil"), else "stamp"; a brief title (a light one, low on the screen) the API does not have is not a title (nil: the
-- text over the character instead). The styles' kinds: dust anything not plainly another, discovery a thing found, unveil a thing
-- strange, notice word from the radio, stamp a great thing done, bleed an infection found, sink a thing lost, type a
-- document or an order, pulse a danger passed.
-- The API's styles are asked once (again for another API's text).
local styles, stylesOf
local function styleFor(t, wanted)
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
Titles.styleFor = styleFor

-- A title over a window (the adaptation tab, the terminal: busy, bright panels) gets this dark band behind it, so that
-- it reads; over the world the style's own (if any) is enough. A window counts when it is at least WINDOW_W by WINDOW_H
-- and crosses the middle of the screen across, between WINDOW_TOP and WINDOW_BOTTOM of its height (where titles go); a
-- window filling the screen (the game's own layers) does not.
Titles.OVER_WINDOW = 0.75
local WINDOW_W, WINDOW_H, WINDOW_TOP, WINDOW_BOTTOM = 300, 200, 0.08, 0.6
local NO_TABLE = {}

-- Whether a window is open where a title goes (looked at once a title, not on a clock).
function Titles.overWindow()
    local ui = UIManager and UIManager.getUI and UIManager.getUI()
    if not ui then return false end
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local mid, top, bottom = sw / 2, sh * WINDOW_TOP, sh * WINDOW_BOTTOM
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

-- Where a title's middle goes for detail.at, as a share of the screen's height (the API's spec.y): "center" puts the title
-- and its line together in the middle (a big title's line hangs below it: their block's middle is about 0.035 under the
-- title's), a number is taken as it is; nil leaves the style's place.
Titles.CENTER, Titles.CENTER_ALONE = 0.465, 0.5
function Titles.place(at, withLine)
    if at == "center" then return withLine and Titles.CENTER or Titles.CENTER_ALONE end
    if type(at) == "number" and at >= 0 and at <= 1 then return at end
    return nil
end

-- How large a title is drawn (detail.size, times its style's size): "major" for the story's great moments (the operation
-- named, a stage's card, the handover, a capstone, a cure), "minor" for the receipt of what the player has just done or
-- will look at anyway (a box sealed, a drop, a mission started or its item secured, a new request); else the style's.
Titles.SIZES = { major = 1.35, minor = 0.72 }

-- Shows a title (detail as OA.Sync.title takes it) for the player of that id; returns how it was shown: "title",
-- "halo" or nil. With `noHalo` a title the API cannot draw is not shown at all (the caller has its own way then).
function Titles.show(playerId, detail, noHalo)
    if type(detail) ~= "table" then return nil end
    local title = text(detail.key, detail.args)
    if not title then return nil end
    local sub = text(detail.sub, detail.subArgs)
    -- (a line under the title is shown without its markup)
    if sub then sub = OA.Markup.strip(sub) end
    local characters = charactersOf(playerId)
    if #characters == 0 then return nil end
    local t = textApi()
    local handle = t and OA.handle()
    local style = handle and styleFor(t, detail.style)
    if not style then handle = nil end
    if noHalo and not handle then return nil end
    local shown
    -- (a brief title, low on the screen, has its own backdrop: windows are judged where the titles go)
    local backdrop = handle and style ~= "brief" and Titles.overWindow() and Titles.OVER_WINDOW or nil
    for _, character in ipairs(characters) do
        local done = false
        if handle then
            local spec = { text = title, subtitle = sub, style = style, player = character:getPlayerNum(),
                now = Titles.now or nil, backdrop = backdrop, y = Titles.place(detail.at, sub ~= nil),
                scale = Titles.SIZES[detail.size] }
            local tone = Titles.TONES[detail.tone]
            if tone then spec.color, spec.subtitleColor = tone[1], tone[2] end
            local ok, err = pcall(t.title, handle, spec)
            if not ok and spec.scale then
                -- (an older PZ Extension API has no scale: the title at its style's size)
                spec.scale = nil
                ok, err = pcall(t.title, handle, spec)
            end
            if ok then done = true else OA.log("title:", tostring(err)) end
        end
        if done then
            shown = "title"
        elseif not noHalo then
            local line = sub and (title .. " - " .. sub) or title
            if detail.fallback == "good" then HaloTextHelper.addGoodText(character, line)
            elseif detail.fallback == "bad" then HaloTextHelper.addBadText(character, line)
            else HaloTextHelper.addText(character, line) end
            shown = shown or "halo"
        end
    end
    return shown
end

-- Shows a notice (OA.Sync.notice: a key and its arguments, already put in the player's language) as a title, when
-- `as` names one: { key (the title), titleArgs (the title takes the notice's arguments too), style, tone, size, fallback
-- ("good" unless given), alone (no line under it: the notice's own text is the title) }. The notice's text is the
-- line under the title.
function Titles.notice(playerId, as, key, args)
    if type(as) ~= "table" then return end
    local detail = { style = as.style, tone = as.tone, fallback = as.fallback or "good", size = as.size }
    if as.alone then
        detail.key, detail.args = key, args
    else
        detail.key, detail.args = as.key, as.titleArgs and args or nil
        detail.sub, detail.subArgs = key, args
    end
    Titles.show(playerId, detail)
end

OA.Sync.listen("title", Titles.show)

return Titles
