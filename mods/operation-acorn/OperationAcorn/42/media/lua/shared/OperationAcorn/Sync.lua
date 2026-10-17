-- How a change reaches the players. Alone, the game is its own server: the windows refresh at once. On a server,
-- the save's data goes to every client and they are told what changed (multiplayer is untested, not blocked).
require "OperationAcorn/Store"
local OA = OperationAcorn
local Sync = {}
OA.Sync = Sync

-- Listeners on the client side, by what changed: OA.Sync.listen("trade", function(playerId, detail) ... end).
local listeners = {}
function Sync.listen(what, fn)
    listeners[what] = listeners[what] or {}
    table.insert(listeners[what], fn)
end

function Sync.deliver(what, playerId, detail)
    for _, fn in ipairs(listeners[what] or {}) do fn(playerId, detail) end
end

-- A player's record (or the world, for a nil playerId) changed in the part named `what`.
function Sync.changed(what, playerId, detail)
    if isServer() then
        ModData.transmit(OA.Store.KEY)
        sendServerCommand(OA.MOD, "changed", { what = what, player = playerId, detail = detail })
    else
        Sync.deliver(what, playerId, detail)
    end
end

-- Something a player should be told, over the character: a translation key and its arguments (strings or numbers).
function Sync.notice(playerId, key, args)
    if isServer() then
        sendServerCommand(OA.MOD, "notice", { player = playerId, key = key, args = args })
    else
        Sync.deliver("notice", playerId, { key = key, args = args })
    end
end

-- A title over a player's screen for an event (a request done, a building searched): `detail` is { key, args (the
-- title's translation and its arguments), sub, subArgs (the line under it, optional), style ("dust", the default, for
-- anything not plainly another; "discovery" a thing found; "unveil" a thing strange; "notice" word from the radio; "stamp" a
-- great thing done: as PZExtAPI.text.title has them), tone ("gold", "green", "red" or nil for the style's own colour),
-- fallback ("good", "bad" or nil), at (where on the screen: "center", a share of its height from the top for the title's
-- middle, or nil for the style's place near the top) }. An argument may itself be a text, { key, args }, translated on the player's side
-- (a name the server cannot put in the player's language). Shown by client/OperationAcorn/Titles.lua; without the
-- extension API's text, as a text over the character in the fallback's colour.
function Sync.title(playerId, detail)
    if isServer() then
        sendServerCommand(OA.MOD, "title", { player = playerId, detail = detail })
    else
        Sync.deliver("title", playerId, detail)
    end
end

-- What a client asks of the server: a command and its arguments, as the player who asks. The character's id goes
-- with it, since the server finds the player's record by it.
function Sync.send(character, command, args)
    args = args or {}
    args.id = OA.Store.idOf(character)
    sendClientCommand(character, OA.MOD, command, args)
end

return Sync
