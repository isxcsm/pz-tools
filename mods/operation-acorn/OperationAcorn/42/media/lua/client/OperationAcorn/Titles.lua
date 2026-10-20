-- The titles of events (OA.Sync.title): drawn big over the player's screen by the extension API's text
-- (PZExtAPI.text.title, queued one at a time), or, without it, as a text over the character.
require "OperationAcorn/Sync"
require "OperationAcorn/Client"
require "OperationAcorn/Markup"
require "OperationAcorn/Trade/Text"
require "PZUIKit/Titles"
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

-- The operation's emblem on a seal title's plate (PZExtAPI text, style "seal": the acorn, tools/seal_emblem.py).
Titles.EMBLEM = "media/textures/OA_SealEmblem.png"

-- Every title goes first, the one on the screen leaving at once (the dev panel's switch for trying titles).
Titles.now = false

-- A text by key and arguments; an argument that is itself a text ({ key, args }: a mission's or a capstone's name) is
-- translated here, on the player's side.
local function text(key, args)
    if type(key) ~= "string" then return nil end
    local list = {}
    for i, arg in ipairs(args or {}) do
        if type(arg) ~= "table" then
            list[i] = arg
        elseif arg.credits then
            -- an amount, written as the terminal writes credits ("1,485")
            list[i] = OA.Trade.Text.credits(arg.credits)
        else
            list[i] = text(arg.key, arg.args) or ""
        end
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

-- The drawing is the UI kit's (PZUIKit.Titles): the API's text, the style it has, the band over a window, the place.
local Kit = PZUIKit.Titles
function Titles.textApi() return Kit.textApi(OA.api()) end
Titles.styleFor, Titles.overWindow, Titles.place = Kit.styleFor, Kit.overWindow, Kit.place
Titles.OVER_WINDOW, Titles.CENTER, Titles.CENTER_ALONE = Kit.OVER_WINDOW, Kit.CENTER, Kit.CENTER_ALONE

-- How large a title is drawn (detail.size, times its style's size): "major" for the story's great moments (the operation
-- named, a stage's card, the handover, a capstone, a cure), "minor" for the receipt, in a large style, of what the player
-- has just done (a box sealed, a mission's item secured, a kit redeemed); else the style's. The notice style is small
-- already and is not made smaller.
Titles.SIZES = { major = 1.35, minor = 0.72 }

-- Whether one of the windows a player works in is open: the terminal's, or the adaptation tab on the screen.
function Titles.windowOpen(playerNum)
    if OATerminalWindow and OATerminalWindow.instances and OATerminalWindow.instances[playerNum] then return true end
    local Window = OA.Upgrades and OA.Upgrades.Window
    return Window ~= nil and Window.onScreen(playerNum) == true
end

-- The brief titles held while a window is open (Titles.show): { playerId, detail, noSay, playerNum, text }, in the
-- order they came; one the same as one held already is not held twice. Looked at every HELD_LOOK_MS of real time
-- while there are some.
Titles.HELD_LOOK_MS = 250
local held = {}
local heldLook = 0

-- Shows a title (detail as OA.Sync.title takes it) for the player of that id; returns how it was shown: "title",
-- "said" (the API cannot draw it: the character says it), "held" or nil, and the key of a title drawn (a later one's
-- `after`). With `noSay` a title the API cannot draw is not shown at all (the caller has its own way then). The small
-- text over the character is never used. A brief title is news from the world, and while the player works in a window
-- (Titles.windowOpen) it waits for the window to close; one that answers what was done in the window (detail.answer: a
-- button's refusal, a call taken) comes over it at once.
function Titles.show(playerId, detail, noSay)
    if type(detail) ~= "table" then return nil end
    local title = text(detail.key, detail.args)
    if not title then return nil end
    local sub = text(detail.sub, detail.subArgs)
    -- (a line under the title is shown without its markup)
    if sub then sub = OA.Markup.strip(sub) end
    local characters = charactersOf(playerId)
    if #characters == 0 then return nil end
    if detail.style == "brief" and not detail.answer and not Titles.now then
        local playerNum = characters[1]:getPlayerNum()
        if Titles.windowOpen(playerNum) then
            local whole = title .. "|" .. (sub or "")
            for _, h in ipairs(held) do
                if h.playerNum == playerNum and h.text == whole then return "held" end
            end
            held[#held + 1] = { playerId = playerId, detail = detail, noSay = noSay, playerNum = playerNum, text = whole }
            return "held"
        end
    end
    local api = OA.api()
    local handle = Kit.textApi(api) and OA.handle()
    if handle and not Kit.styleFor(Kit.textApi(api), detail.style) then handle = nil end
    if noSay and not handle then return nil end
    local shown, key
    for _, character in ipairs(characters) do
        local spec = { text = title, subtitle = sub, style = detail.style, player = character:getPlayerNum(),
            now = Titles.now or nil, y = Titles.place(detail.at, sub ~= nil), scale = Titles.SIZES[detail.size],
            after = detail.after }
        local tone = Titles.TONES[detail.tone]
        if tone then spec.color, spec.subtitleColor = tone[1], tone[2] end
        if detail.style == "seal" then spec.emblem = Titles.EMBLEM end
        local drawn, drawnKey = false, nil
        if handle then drawn, drawnKey = Kit.show(api, handle, spec, OA.log) end
        if drawn then
            shown, key = "title", key or drawnKey
        elseif not noSay then
            character:Say(sub and (title .. " - " .. sub) or title)
            shown = shown or "said"
        end
    end
    return shown, key
end


-- Shows a notice (OA.Sync.notice: a key and its arguments, already put in the player's language) as a title, when
-- `as` names one: { key (the title), titleArgs (the title takes the notice's arguments too), style, tone, size, alone
-- (no line under it: the notice's own text is the title), after (a title's key it waits to have left), answer (it
-- answers what was done in a window: Titles.show) }. The notice's text is the line under the title.
function Titles.notice(playerId, as, key, args)
    if type(as) ~= "table" then return end
    local detail = { style = as.style, tone = as.tone, size = as.size, after = as.after, answer = as.answer }
    if as.alone then
        detail.key, detail.args = key, args
    else
        detail.key, detail.args = as.key, as.titleArgs and args or nil
        detail.sub, detail.subArgs = key, args
    end
    return Titles.show(playerId, detail)
end

-- A notice as a brief title (light, low on the screen): its own text the title. `tone`: "red" for a refusal, "amber"
-- for a warning, nil for news. `after`: a title's key it waits to have left. `answer`: it answers what was done in a
-- window, over which it comes at once (else it waits for the window to close: Titles.show).
function Titles.brief(playerId, key, args, tone, after, answer)
    return Titles.notice(playerId, { alone = true, style = "brief", tone = tone, after = after, answer = answer },
        key, args)
end

-- The titles held for a window: each shown once its player's windows are closed (the handler stays, and returns at
-- once while none is held). `now` true: looked at at once (the terminal closed).
function Titles.showHeld(now)
    if held[1] == nil then return end
    if now ~= true then
        now = now or getTimestampMs()
        if now >= heldLook and now - heldLook < Titles.HELD_LOOK_MS then return end
    else
        now = getTimestampMs()
    end
    heldLook = now
    local waiting = held
    held = {}
    for _, h in ipairs(waiting) do
        if Titles.windowOpen(h.playerNum) then
            held[#held + 1] = h
        else
            OA.try("title held for a window", Titles.show, h.playerId, h.detail, h.noSay)
        end
    end
end
OA.on("OnTick", function() Titles.showHeld() end)
-- (the terminal closing shows them at once, before what other parts bring as it closes: this file loads before them)
OA.terminalWatchers = OA.terminalWatchers or {}
table.insert(OA.terminalWatchers, function(_, open)
    if not open then Titles.showHeld(true) end
end)

-- Takes a title Titles.show drew away at once (its key), one still waiting too. True when there was one.
function Titles.hide(key)
    return key ~= nil and Kit.hide(OA.api(), OA.handle(), key)
end

-- A notice the character says: what it tried did not work (its text is written as the character's own words).
function Titles.say(playerId, key, args)
    local line = text(key, args)
    if not line then return end
    for _, character in ipairs(charactersOf(playerId)) do character:Say(line) end
end

OA.Sync.listen("title", Titles.show)

return Titles
