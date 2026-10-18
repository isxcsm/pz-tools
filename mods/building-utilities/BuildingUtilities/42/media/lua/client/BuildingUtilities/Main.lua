-- The player's side: windows that show changes, notices for players near a box, a summary when the mouse is over a
-- box, and in multiplayer the server's data and messages. The world itself changes on the server side (server/BuildingUtilities/Server.lua).
require "BuildingUtilities/ContextMenu"
require "BuildingUtilities/Sounds"
require "BuildingUtilities/PanelWindow"
require "BuildingUtilities/PanelStatus"
require "BuildingUtilities/RackWindow"
require "BuildingUtilities/Moveables"
require "BuildingUtilities/Batteries"
require "BuildingUtilities/Finds"
require "BuildingUtilities/Titles"
require "BuildingUtilities/Lights"
require "BuildingUtilities/PanelBlink"
require "BuildingUtilities/SprinklerSpray"
local BU = BuildingUtilities
local Store, Panels, PanelWindow = BU.Store, BU.Panels, BU.PanelWindow

-- The box on a square shows the summary: set as its square loads and as a box is put down. (A tripped box shows it
-- on its own lamps: BU.PanelLook.)
local function giveSummary(box)
    if box and not box:haveSpecialTooltip() then box:setSpecialTooltip(true) end
end

-- The summaries over boxes (summaryOf), by panel id.
local summaries = {}

-- Something changed: of the box given, or of none in particular (nil). Every window refreshes once that settles, as a
-- box's change can show in another's window too (its name, a device connected to it).
function BU.onChanged(panelId)
    Store.dataChanged()
    local panel = panelId and Store.get(panelId)
    if panel then giveSummary(Panels.object(panel)) end
    PanelWindow.refreshAll()
    BU.RackWindow.refreshAll()
    BU.PanelBlink.changed(panelId)
    BU.SprinklerSpray.changed(panelId)
    summaries = {}
    -- A client's data is the server's only once received (onReceiveGlobalModData); a box taken down leaves its marks.
    if not isClient() and panelId and not panel then PanelWindow.forgetRemoved() end
end

-- A sound at a box (a cue of BU.Sounds), heard where it is.
function BU.onSound(panelId, cue)
    local panel = Store.get(panelId)
    local square = panel and getCell():getGridSquare(panel.x, panel.y, panel.z)
    if square then PZUIKit.Sound.at(cue, square, true) end
end

-- A box's notice: kept in its log (BU.Sync.notice), which its window shows; nothing over the players' heads (a
-- generator taking over, a tripped breaker: the box's lamps and its window tell them).
function BU.onNotice(panelId, key, args)
    if not Store.get(panelId) then return end
    PanelWindow.refreshAll()
    BU.RackWindow.refreshAll()
end

-- The mouse over a box: its name and tier, the breaker and main switch, power and water as its window's status line
-- tells them (PanelWindow.status), the load, and the box that supplies it. Worked out every SUMMARY_MS, not each
-- frame.
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

-- The summary of a box: { title, lines = { { label, value, r, g, b } } }. Only the utilities that are on (BU.enabled).
local function summaryOf(panel)
    local lines = {}
    local powerOn = BU.enabled("power")
    if powerOn and panel.tripped then lines[#lines + 1] = { label = getText("IGUI_BU_TipBreaker"), value = getText("IGUI_BU_Tripped"), r = 1, g = 0.4, b = 0.4 } end
    -- Told apart from the status, which the grid has while it runs.
    if powerOn and panel.switchedOff then lines[#lines + 1] = { label = getText("IGUI_BU_TipSwitch"), value = getText("IGUI_BU_SwitchOff"), r = 1, g = 0.75, b = 0.3 } end
    if powerOn then statusLine(lines, getText("IGUI_BU_TipPower"), PanelWindow.status(panel, "power")) end
    local power = BU.Networks.state(panel, "power")
    if power and power.load then
        -- As the window's top tells it: the load against the limit, red over it.
        local load = math.max(0, power.load)
        local limit = Panels.limit(panel)
        local over = BU.overloadEnabled() and load > limit + 1e-6
        lines[#lines + 1] = { label = getText("IGUI_BU_TipLoad"), value = string.format("%.2f / %.2f", load, limit),
            r = 1, g = over and 0.42 or 1, b = over and 0.38 or 1 }
    end
    -- Water where the box has tanks.
    if BU.enabled("water") and #panel.water.producers > 0 then statusLine(lines, getText("IGUI_BU_TipWater"), PanelWindow.status(panel, "water")) end
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
    elseif command == "sound" and args then BU.onSound(args.panel, args.cue)
    elseif command == "title" and args then BU.onTitle(getPlayer(), args.kind, args.tier) end
end

local function onReceiveGlobalModData(key, data)
    if key ~= Store.KEY or type(data) ~= "table" then return end
    ModData.add(key, data)
    Store.reload()
    BU.onChanged()
    PanelWindow.forgetRemoved()
    -- What is lit by the data (a rack's batteries) near the player, now that it is here.
    BU.Lights.everyMinute()
end

-- A network the API runs here changed: the windows that show it.
local function onNetworkChange(id) PanelWindow.onNetworkChange(id) end

-- The API's network events, heard from the game's start where the API is (it may set its event up after this file
-- loads), once.
local listening = false

local function onGameStart()
    if isClient() then ModData.request(Store.KEY) end
    BU.declareOutlines()
    -- The squares loaded before this: their boxes (a box loaded later is found as its square loads).
    local _, near = BU.Nearby.hotPanels()
    for _, panel in ipairs(near) do giveSummary(Panels.object(panel)) end
    if not listening and BU.api() and Events.OnPZExtNetworkChange then
        Events.OnPZExtNetworkChange.Add(onNetworkChange)
        listening = true
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData)
Events.OnGameStart.Add(onGameStart)
Events.DoSpecialTooltip.Add(onSpecialTooltip)
-- Boxes come into view as squares load. (Their mod data says what they are; the data of the save may not be here yet.)
for _, sprite in ipairs(BU.PanelLook.ALL) do
    BU.onLoadSprite(sprite, function(object)
        if object:hasModData() and object:getModData()[Panels.MODDATA] then giveSummary(object) end
    end)
end
