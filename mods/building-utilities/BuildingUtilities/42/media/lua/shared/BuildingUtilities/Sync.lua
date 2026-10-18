-- How a change reaches the players. Alone, the game is its own server: the windows refresh at once. On a server,
-- the save's data goes to every client and they are told what changed. The client side sets BU.onChanged and
-- BU.onNotice.
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Sync = {}
BU.Sync = Sync

function Sync.changed(panelId)
    BU.Store.dataChanged()
    -- The box shows it in the world first (BU.PanelLook: its breaker, its power).
    local panel = panelId and BU.PanelLook and BU.Store.get(panelId)
    if panel then BU.PanelLook.show(panel) end
    if isServer() then
        ModData.transmit(BU.Store.KEY)
        sendServerCommand(BU.MOD, "changed", { panel = panelId })
    elseif BU.onChanged then
        BU.onChanged(panelId)
    end
end

-- Something that happened at the box: a translation key and its arguments (strings or numbers), kept in its log,
-- which its window shows.
function Sync.notice(panel, key, ...)
    local args = { ... }
    BU.Store.record(panel, key, args)
    if isServer() then
        ModData.transmit(BU.Store.KEY)
        sendServerCommand(BU.MOD, "notice", { panel = panel.id, key = key, args = args })
    elseif BU.onNotice then
        BU.onNotice(panel.id, key, args)
    end
end

-- A sound at the box, for the players who hear it there: a cue of BU.Sounds.
function Sync.sound(panel, cue)
    if isServer() then
        sendServerCommand(BU.MOD, "sound", { panel = panel.id, cue = cue })
    elseif BU.onSound then
        BU.onSound(panel.id, cue)
    end
end

-- A title on a player's screen (client/BuildingUtilities/Titles.lua): kind "tier" with the tier a box was raised to.
function Sync.title(player, kind, tier)
    if isServer() then
        sendServerCommand(player, BU.MOD, "title", { kind = kind, tier = tier })
    elseif BU.onTitle then
        BU.onTitle(player, kind, tier)
    end
end

-- What a client asks of the server: a command and its arguments, as the player who asks. Alone, the game's own
-- server part answers it. When it was sent is kept: a change told soon after answers the player's own click, and the
-- windows show it at once (Sync.answering).
function Sync.send(player, command, args)
    Sync.sentAt = getTimestampMs()
    sendClientCommand(player, BU.MOD, command, args or {})
end

-- Whether a change told now likely answers a command this client just sent (within ANSWER_MS: alone it comes the
-- next tick, from a server a moment later).
local ANSWER_MS = 1000
function Sync.answering() return Sync.sentAt ~= nil and getTimestampMs() - Sync.sentAt < ANSWER_MS end

return Sync
