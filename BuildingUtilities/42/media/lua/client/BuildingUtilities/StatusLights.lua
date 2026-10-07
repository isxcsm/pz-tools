-- Each box's status light in the world: a small lamp over the box in its power's colour (green supplied, amber soon
-- not or cut on purpose, red none; BuildingUtilities/PanelStatus), blinking while the breaker is down. Drawn by one
-- UI element over the world for the boxes near a player that the player can see; what each shows is worked out once
-- a second, where each is on the screen every frame.
require "ISUI/ISUIElement"
require "BuildingUtilities/PanelStatus"
local BU = BuildingUtilities
local Store, Panels, PanelWindow = BU.Store, BU.Panels, BU.PanelWindow

-- Boxes within so many squares of a player; the lamp so many pixels at zoom 1, so high over the box's floor (a
-- floor is 1).
local RANGE, SIZE, HEIGHT, REFRESH_MS = 25, 6, 0.48, 1000

ISBUStatusLights = ISUIElement:derive("ISBUStatusLights")

function ISBUStatusLights:new()
    local o = ISUIElement.new(self, 0, 0, 1, 1)
    o.lights, o.refreshedAt = {}, 0
    return o
end

-- The boxes near each player, with their colour now.
function ISBUStatusLights:refresh()
    self.refreshedAt = getTimestampMs()
    self.lights = {}
    for index = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(index)
        if player and not player:isDead() then
            for _, panel in ipairs(Store.list()) do
                local near = math.abs(panel.x - player:getX()) <= RANGE and math.abs(panel.y - player:getY()) <= RANGE
                if near and panel.z <= math.floor(player:getZ()) and Panels.object(panel) then
                    local status = PanelWindow.status(panel, "power")
                    self.lights[#self.lights + 1] = { player = index, panel = panel,
                        colour = PanelWindow.STATUS_COLOURS[status.level], blink = panel.tripped == true }
                end
            end
        end
    end
end

function ISBUStatusLights:render()
    if getTimestampMs() - self.refreshedAt > REFRESH_MS then self:refresh() end
    local off = BU.remainder(getTimestampMs(), 1000) < 400
    for _, light in ipairs(self.lights) do
        local panel = light.panel
        local square = getCell():getGridSquare(panel.x, panel.y, panel.z)
        if square and square:isCanSee(light.player) and not (light.blink and off) then
            local x = isoToScreenX(light.player, panel.x + 0.5, panel.y + 0.5, panel.z + HEIGHT)
            local y = isoToScreenY(light.player, panel.x + 0.5, panel.y + 0.5, panel.z + HEIGHT)
            local size = math.max(3, SIZE / getCore():getZoom(light.player))
            local c = light.colour
            self:drawRect(x - size, y - size, size * 2, size * 2, 0.25, c[1], c[2], c[3])
            self:drawRect(x - size / 2, y - size / 2, size, size, 1, c[1], c[2], c[3])
        end
    end
end

local lights
Events.OnGameStart.Add(function()
    lights = ISBUStatusLights:new()
    lights:initialise()
    lights:addToUIManager()
    lights:backMost()
end)
