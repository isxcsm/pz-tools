-- How a change reaches the players. Alone, the game is its own server: the windows refresh at once. On a server,
-- the save's data goes to every client and they are told what changed. The client side sets BU.onChanged and
-- BU.onNotice.
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Sync = {}
BU.Sync = Sync

function Sync.changed(panelId)
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

-- Something a player near the panel should hear: a translation key and its arguments (strings or numbers). Its
-- window's log keeps it too.
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

-- A sound at the box, for the players who hear it there.
function Sync.sound(panel, name)
    if isServer() then
        sendServerCommand(BU.MOD, "sound", { panel = panel.id, name = name })
    elseif BU.onSound then
        BU.onSound(panel.id, name)
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
-- server part answers it.
function Sync.send(player, command, args)
    sendClientCommand(player, BU.MOD, command, args or {})
end

return Sync
