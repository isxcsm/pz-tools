-- The lines in the world: thin lines from each thing to what it hangs on (BU.Links), while a box's window is open (that
-- box's lines), in their utility's colour (a water pipe's own; a machine's two pipes side by side), grey where they
-- supply nothing. Else nothing is drawn or looked for. A HUD under every window draws them, one pixel at the screen's
-- corner drawing past its bounds (as Operation Acorn's marks: a larger element takes the world's clicks); while it
-- shows it draws every frame, as the camera moves without telling it. The lines are looked for again when they change
-- and every second (what supplies may change with a tier or a zone).
require "ISUI/ISPanel"
require "PZUIKit/UI"
require "BuildingUtilities/Links"
local BU = BuildingUtilities
local Store, Links = BU.Store, BU.Links
local UI = PZUIKit.UI
local LineOverlay = {}
BU.LineOverlay = LineOverlay

local REBUILD_MS = 1000
local WIDTH = 2
-- How far apart a machine's inlet and outlet run (squares).
local PAIR = 0.16
local COLOURS = { power = { 0.95, 0.72, 0.3 }, water = { 0.45, 0.78, 0.86 }, cut = { 0.5, 0.5, 0.52 } }
local WHITE = Texture.getWhite()

local Hud = ISPanel:derive("ISBULineOverlay")

function Hud:new()
    local o = ISPanel.new(self, getPlayerScreenLeft(0), getPlayerScreenTop(0), 1, 1)
    o.background = false
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.moveWithMouse = false
    return o
end

function Hud:prerender() end

-- What shows: the boxes whose windows are open (a set of panel ids).
local shown = { panels = {}, key = "" }
-- The lines to draw, each { x1, y1, z1, x2, y2, z2, colour }, and what they were looked for with.
local segments, segmentsKey = {}, nil

local function build()
    local result = {}
    for _, line in pairs(Links.all()) do
        if line.panel and shown.panels[line.panel] then
            local tx, ty, tz = Links.endOf(line)
            if tx then
                local panel = Store.get(line.panel)
                local colour, second = COLOURS.cut, nil
                if panel and Links.live(panel, line.ref) then
                    -- a water line of a box with more than one pipe in its pipe's colour (a relay's in water's); a
                    -- machine's inlet and outlet side by side when they differ
                    local pipe, outlet
                    if line.utility == "water" and BU.Water.shown(panel) then
                        pipe, outlet = BU.Water.linePipes(panel, line)
                    end
                    colour = pipe and BU.Water.colour(pipe) or COLOURS[line.utility]
                    second = outlet and BU.Water.colour(outlet) or nil
                end
                local x1, y1, x2, y2 = line.x + 0.5, line.y + 0.5, tx + 0.5, ty + 0.5
                if second then
                    local ox, oy = Links.besideOffset(x2 - x1, y2 - y1, PAIR)
                    result[#result + 1] = { x1 - ox, y1 - oy, line.z, x2 - ox, y2 - oy, tz, colour }
                    result[#result + 1] = { x1 + ox, y1 + oy, line.z, x2 + ox, y2 + oy, tz, second }
                else
                    result[#result + 1] = { x1, y1, line.z, x2, y2, tz, colour }
                end
            end
        end
    end
    return result
end

function Hud:render()
    local key = shown.key .. "|" .. Store.linkVersion() .. "|" .. math.floor(getTimestampMs() / REBUILD_MS)
    if key ~= segmentsKey then
        segments, segmentsKey = build(), key
    end
    local ui = self.javaObject
    for i = 1, #segments do
        local s = segments[i]
        local c = s[7]
        ui:DrawLine(WHITE, isoToScreenX(0, s[1], s[2], s[3]), isoToScreenY(0, s[1], s[2], s[3]),
            isoToScreenX(0, s[4], s[5], s[6]), isoToScreenY(0, s[4], s[5], s[6]), WIDTH, c[1], c[2], c[3], 0.85)
    end
end

-- Followed each frame while it shows.
local function frame(el, now) return el:isVisible() and now or nil end

local hud = nil

-- What shows worked out again (a window opened or closed), and the HUD shown or hidden.
function LineOverlay.refresh()
    local panels, parts = {}, {}
    for _, id in ipairs(BU.PanelWindow and BU.PanelWindow.openIds() or {}) do
        panels[id] = true
        parts[#parts + 1] = id
    end
    table.sort(parts)
    shown = { panels = panels, key = table.concat(parts, ",") }
    local on = #parts > 0 and BU.api() ~= nil
    if on and not hud then
        hud = Hud:new()
        hud:initialise()
        hud:instantiate()
        hud.javaObject:setConsumeMouseEvents(false)
        hud:addToUIManager()
        -- under every window and the game's own HUD
        hud:backMost()
    end
    if not hud then return end
    hud:setVisible(on)
    if on then
        hud:setX(getPlayerScreenLeft(0))
        hud:setY(getPlayerScreenTop(0))
        segmentsKey = nil
        UI.live(hud, frame)
    end
end

Events.OnGameStart.Add(LineOverlay.refresh)

return LineOverlay
