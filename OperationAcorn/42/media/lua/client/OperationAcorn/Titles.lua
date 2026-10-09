-- The titles of events (OA.Sync.title): drawn big over the player's screen by the extension API's text
-- (PZToolsAPI.text.title, queued one at a time), or, without it, as a text over the character.
require "OperationAcorn/Client"
local OA = OperationAcorn
local Titles = {}
OA.Titles = Titles

-- The tones a title can take over its style's colour, title and line under it.
Titles.TONES = {
    gold = { { 1.00, 0.86, 0.50 }, { 0.95, 0.88, 0.70 } },
    green = { { 0.62, 1.00, 0.70 }, { 0.78, 0.95, 0.82 } },
    red = { { 1.00, 0.55, 0.50 }, { 0.95, 0.75, 0.72 } },
}

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

-- The local characters the title is for (every one for a nil playerId).
local function charactersOf(playerId)
    local found = {}
    for i = 0, getNumActivePlayers() - 1 do
        local character = getSpecificPlayer(i)
        if character and (playerId == nil or OA.Client.id(character) == playerId) then found[#found + 1] = character end
    end
    return found
end

-- The extension API's text, when its drawing hook is in.
local function textApi()
    local api = OA.api()
    local t = api and api.text
    if type(t) ~= "table" or type(t.title) ~= "function" then return nil end
    local ok, status = pcall(t.status)
    if not ok or status ~= "applied" then return nil end
    return t
end

-- Shows a title (detail as OA.Sync.title takes it) for the player of that id; returns how it was shown: "title",
-- "halo" or nil. With `noHalo` a title the API cannot draw is not shown at all (the caller has its own way then).
function Titles.show(playerId, detail, noHalo)
    if type(detail) ~= "table" then return nil end
    local title = text(detail.key, detail.args)
    if not title then return nil end
    local sub = text(detail.sub, detail.subArgs)
    local characters = charactersOf(playerId)
    if #characters == 0 then return nil end
    local t = textApi()
    local handle = t and OA.handle()
    if noHalo and not handle then return nil end
    local shown
    for _, character in ipairs(characters) do
        local done = false
        if handle then
            local spec = { text = title, subtitle = sub, style = detail.style or "stamp", player = character:getPlayerNum() }
            local tone = Titles.TONES[detail.tone]
            if tone then spec.color, spec.subtitleColor = tone[1], tone[2] end
            local ok, err = pcall(t.title, handle, spec)
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

OA.Sync.listen("title", Titles.show)

return Titles
