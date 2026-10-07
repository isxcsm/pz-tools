-- The player's side: windows that show changes, notices for players near a box, and in multiplayer the server's
-- data and messages. The world itself changes on the server side (server/BuildingUtilities/Server.lua).
require "BuildingUtilities/ContextMenu"
require "BuildingUtilities/PanelWindow"
require "BuildingUtilities/Moveables"
local BU = BuildingUtilities
local Store, Panels, PanelWindow = BU.Store, BU.Panels, BU.PanelWindow

-- How far from a box's building, in squares, a player hears it; one with its window open always does.
local NOTICE_RANGE = 40
local GOOD = { IGUI_BU_Notice_Switched = true }

-- A tripped box blinks red in the world for the players here, until its breaker is reset.
local marked = {}
local RED = ColorInfo.new(1, 0.2, 0.2, 1)

local function markTripped()
    for _, object in ipairs(marked) do
        for index = 0, getNumActivePlayers() - 1 do
            object:setHighlighted(index, false, false)
            object:setBlink(index, false)
        end
    end
    marked = {}
    for _, panel in ipairs(Store.list()) do
        local object = panel.tripped and Panels.object(panel)
        if object then
            for index = 0, getNumActivePlayers() - 1 do
                object:setHighlightColor(index, RED)
                object:setHighlighted(index, true, false)
                object:setBlink(index, true)
            end
            marked[#marked + 1] = object
        end
    end
end

function BU.onChanged()
    markTripped()
    PanelWindow.refreshAll()
end

-- A sound at a box, heard where it is.
function BU.onSound(panelId, name)
    local panel = Store.get(panelId)
    local square = panel and getCell():getGridSquare(panel.x, panel.y, panel.z)
    if square then square:playSoundLocal(name) end
end

function BU.onNotice(panelId, key, args)
    local panel = Store.get(panelId)
    if not panel then return end
    args = args or {}
    local text = getText(key, args[1] ~= nil and tostring(args[1]) or "", args[2] ~= nil and tostring(args[2]) or "")
    for index = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(index)
        if player and not player:isDead() then
            local steps = Panels.steps(panel, player:getX(), player:getY())
            if PanelWindow.isOpen(panelId) or steps and steps <= NOTICE_RANGE then
                if GOOD[key] then HaloTextHelper.addGoodText(player, text) else HaloTextHelper.addBadText(player, text) end
            end
        end
    end
    PanelWindow.refreshAll()
end

-- Multiplayer: the server's data, and what it tells.
local function onServerCommand(module, command, args)
    if module ~= BU.MOD then return end
    if command == "changed" then BU.onChanged(args and args.panel)
    elseif command == "notice" and args then BU.onNotice(args.panel, args.key, args.args)
    elseif command == "sound" and args then BU.onSound(args.panel, args.name) end
end

local function onReceiveGlobalModData(key, data)
    if key ~= Store.KEY or type(data) ~= "table" then return end
    ModData.add(key, data)
    BU.onChanged()
end

local function onGameStart()
    if isClient() then ModData.request(Store.KEY) end
    markTripped()
end

-- A network the API runs here changed: the windows that show it.
local function onNetworkChange(id) PanelWindow.onNetworkChange(id) end

Events.OnServerCommand.Add(onServerCommand)
Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData)
Events.OnGameStart.Add(onGameStart)
-- Boxes come into view as squares load.
Events.EveryOneMinute.Add(markTripped)
if Events.OnPZToolsNetworkChange then Events.OnPZToolsNetworkChange.Add(onNetworkChange) end
