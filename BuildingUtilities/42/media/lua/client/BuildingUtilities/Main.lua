-- The player's side: windows that show changes, notices for players near a box, a summary when the mouse is over a
-- box, and in multiplayer the server's data and messages. The world itself changes on the server side (server/BuildingUtilities/Server.lua).
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
        -- Boxes from before the summary existed get it as they come into view.
        local box = Panels.object(panel)
        if box and not box:haveSpecialTooltip() then box:setSpecialTooltip(true) end
        local object = panel.tripped and box
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

-- The mouse over a box: its name and tier, the breaker, power with the hours left, the load, water, and the box
-- that supplies it.
local function boxOn(square)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local panel = Panels.ofObject(objects:get(i))
        if panel then return panel end
    end
    return nil
end

local function drawSummary(tooltip, panel)
    local title = getText("IGUI_BU_TierName", Panels.name(panel), panel.tier or 1)
    tooltip:DrawTextureScaled(tooltip:getTexture(), 0, 0, tooltip:getWidth(), tooltip:getHeight(), 0.75)
    tooltip:DrawTextCentre(tooltip:getFont(), title, tooltip:getWidth() / 2, 5, 1, 1, 1, 1)
    tooltip:adjustWidth(5, title)
    local layout = tooltip:beginLayout()
    local function line(label, value, r, g, b)
        local item = layout:addItem()
        item:setLabel(label .. ":", 1, 1, 1, 1)
        item:setValue(value, r or 1, g or 1, b or 1, 1)
    end
    local power, water = BU.Networks.state(panel, "power"), BU.Networks.state(panel, "water")
    if panel.tripped then line(getText("IGUI_BU_TipBreaker"), getText("IGUI_BU_Tripped"), 1, 0.4, 0.4) end
    if power and power.supplied then
        local text = power.hoursLeft and getText("IGUI_BU_TipHoursLeft", string.format("%.0f", power.hoursLeft)) or getText("IGUI_BU_TipSupplied")
        line(getText("IGUI_BU_TipPower"), text, 0.5, 1, 0.5)
    else
        line(getText("IGUI_BU_TipPower"), getText("IGUI_BU_TipNoSupply"), 0.7, 0.7, 0.7)
    end
    if power and power.load then
        local capacity = Panels.capacity(panel)
        local over = power.load > capacity * 0.8
        line(getText("IGUI_BU_TipLoad"), string.format("%.2f / %.2f", power.load, capacity), 1, over and 0.7 or 1, over and 0.4 or 1)
    end
    if water and water.supplied then
        line(getText("IGUI_BU_TipWater"), string.format("%.0f / %.0f", water.amount or 0, water.capacity or 0), 0.6, 0.8, 1)
    end
    local parent = Store.get(panel.parent)
    if parent then line(getText("IGUI_BU_TipMain"), Panels.name(parent)) end
    local y = layout:render(5, 5 + getTextManager():getFontHeight(tooltip:getFont()), tooltip)
    tooltip:setHeight(y + 5)
    tooltip:endLayout(layout)
end

local function onSpecialTooltip(tooltip, square)
    local panel = square and boxOn(square)
    if not panel then return end
    tooltip:setWidth(100)
    tooltip:setMeasureOnly(true)
    drawSummary(tooltip, panel)
    tooltip:setMeasureOnly(false)
    drawSummary(tooltip, panel)
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
Events.DoSpecialTooltip.Add(onSpecialTooltip)
-- Boxes come into view as squares load.
Events.EveryOneMinute.Add(markTripped)
if Events.OnPZToolsNetworkChange then Events.OnPZToolsNetworkChange.Add(onNetworkChange) end
