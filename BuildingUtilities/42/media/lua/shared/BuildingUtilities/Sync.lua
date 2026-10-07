-- How a change reaches the players. Alone, the game is its own server: the windows refresh at once. On a server,
-- the save's data goes to every client and they are told what changed. The client side sets BU.onChanged and
-- BU.onNotice.
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Sync = {}
BU.Sync = Sync

function Sync.changed(panelId)
    if isServer() then
        ModData.transmit(BU.Store.KEY)
        sendServerCommand(BU.MOD, "changed", { panel = panelId })
    elseif BU.onChanged then
        BU.onChanged(panelId)
    end
end

-- Something a player near the panel should hear: a translation key and its arguments (strings or numbers).
function Sync.notice(panel, key, ...)
    local args = { ... }
    if isServer() then
        sendServerCommand(BU.MOD, "notice", { panel = panel.id, key = key, args = args })
    elseif BU.onNotice then
        BU.onNotice(panel.id, key, args)
    end
end

-- What a client asks of the server: a command and its arguments, as the player who asks. Alone, the game's own
-- server part answers it.
function Sync.send(player, command, args)
    sendClientCommand(player, BU.MOD, command, args or {})
end

return Sync
