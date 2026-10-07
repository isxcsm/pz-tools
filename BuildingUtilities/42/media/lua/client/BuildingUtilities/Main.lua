-- The player's side: windows that show changes, notices for players near a box, a summary when the mouse is over a
-- box, and in multiplayer the server's data and messages. The world itself changes on the server side (server/BuildingUtilities/Server.lua).
require "BuildingUtilities/ContextMenu"
require "BuildingUtilities/PanelWindow"
require "BuildingUtilities/PanelStatus"
require "BuildingUtilities/Moveables"
require "BuildingUtilities/Batteries"
local BU = BuildingUtilities
local Store, Panels, PanelWindow = BU.Store, BU.Panels, BU.PanelWindow

-- How far from a box's building, in squares, a player hears it; one with its window open always does.
local NOTICE_RANGE = 40
local GOOD = { IGUI_BU_Notice_Switched = true, IGUI_BU_Notice_Thawed = true }

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

-- The summaries over boxes (summaryOf), by panel id.
local summaries = {}

function BU.onChanged()
    markTripped()
    PanelWindow.refreshAll()
    summaries = {}
    -- A client's data is the server's only once received (onReceiveGlobalModData).
    if not isClient() then PanelWindow.forgetRemoved() end
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

-- The mouse over a box: its name and tier, the breaker, power and water as its window's status line tells them
-- (PanelWindow.status), the load, and the box that supplies it. Worked out every SUMMARY_MS, not each frame.
local SUMMARY_MS = 500

local function boxOn(square)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local panel = Panels.ofObject(objects:get(i))
        if panel then return panel end
    end
    return nil
end

-- A utility's status in a line: its text, what is left, in its level's colour.
local function statusLine(lines, label, status)
    local c = PanelWindow.STATUS_COLOURS[status.level]
    lines[#lines + 1] = { label = label, value = status.left and status.text .. ", " .. status.left or status.text,
        r = c[1], g = c[2], b = c[3] }
end

-- The summary of a box: { title, lines = { { label, value, r, g, b } } }.
local function summaryOf(panel)
    local lines = {}
    if panel.tripped then lines[#lines + 1] = { label = getText("IGUI_BU_TipBreaker"), value = getText("IGUI_BU_Tripped"), r = 1, g = 0.4, b = 0.4 } end
    statusLine(lines, getText("IGUI_BU_TipPower"), PanelWindow.status(panel, "power"))
    local power = BU.Networks.state(panel, "power")
    if power and power.load then
        local capacity = Panels.capacity(panel)
        -- Amber near what the box carries, as its window's banner, where overload trips it.
        local near = BU.overloadEnabled() and power.load > capacity * 0.8
        lines[#lines + 1] = { label = getText("IGUI_BU_TipLoad"), value = string.format("%.2f / %.2f", power.load, capacity),
            r = 1, g = near and 0.7 or 1, b = near and 0.4 or 1 }
    end
    -- Water where the box, or the main panel it takes its supply from, has tanks.
    local top, steps = panel, 0
    while Store.get(top.parent) and steps < 10 do top, steps = Store.get(top.parent), steps + 1 end
    if #top.water.producers > 0 then statusLine(lines, getText("IGUI_BU_TipWater"), PanelWindow.status(panel, "water")) end
    local parent = Store.get(panel.parent)
    if parent then lines[#lines + 1] = { label = getText("IGUI_BU_TipMain"), value = Panels.name(parent), r = 1, g = 1, b = 1 } end
    return { title = getText("IGUI_BU_TierName", Panels.name(panel), panel.tier or 1), lines = lines }
end

local function drawSummary(tooltip, summary)
    local title = summary.title
    tooltip:DrawTextureScaled(tooltip:getTexture(), 0, 0, tooltip:getWidth(), tooltip:getHeight(), 0.75)
    tooltip:DrawTextCentre(tooltip:getFont(), title, tooltip:getWidth() / 2, 5, 1, 1, 1, 1)
    tooltip:adjustWidth(5, title)
    local layout = tooltip:beginLayout()
    for _, line in ipairs(summary.lines) do
        local item = layout:addItem()
        item:setLabel(line.label .. ":", 1, 1, 1, 1)
        item:setValue(line.value, line.r, line.g, line.b, 1)
    end
    local y = layout:render(5, 5 + getTextManager():getFontHeight(tooltip:getFont()), tooltip)
    tooltip:setHeight(y + 5)
    tooltip:endLayout(layout)
end

local function onSpecialTooltip(tooltip, square)
    local panel = square and boxOn(square)
    if not panel then return end
    local now = getTimestampMs()
    local summary = summaries[panel.id]
    if not summary or now - summary.at >= SUMMARY_MS then
        summary = summaryOf(panel)
        summary.at = now
        summaries[panel.id] = summary
    end
    tooltip:setWidth(100)
    tooltip:setMeasureOnly(true)
    drawSummary(tooltip, summary)
    tooltip:setMeasureOnly(false)
    drawSummary(tooltip, summary)
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
    PanelWindow.forgetRemoved()
end

-- A network the API runs here changed: the windows that show it.
local function onNetworkChange(id) PanelWindow.onNetworkChange(id) end

-- The API's network events, heard from the game's start where the API is (it may set its event up after this file
-- loads), once.
local listening = false

local function onGameStart()
    if isClient() then ModData.request(Store.KEY) end
    markTripped()
    if not listening and BU.api() and Events.OnPZToolsNetworkChange then
        Events.OnPZToolsNetworkChange.Add(onNetworkChange)
        listening = true
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData)
Events.OnGameStart.Add(onGameStart)
Events.DoSpecialTooltip.Add(onSpecialTooltip)
-- Boxes come into view as squares load.
Events.EveryOneMinute.Add(markTripped)
