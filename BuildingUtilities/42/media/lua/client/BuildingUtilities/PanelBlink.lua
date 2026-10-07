-- A tripped box's red lamp blinks: near each player, every box whose breaker is down is turned between its lamp's lit
-- and dark frames (BU.PanelLook.blink), here only (the server keeps either). Which boxes are near is worked out once a
-- second, and a frame is set only as the lamp goes on or off; the game paused, they keep the frame they have.
require "BuildingUtilities/PanelLook"
local BU = BuildingUtilities
local Store, Panels, PanelLook = BU.Store, BU.Panels, BU.PanelLook

-- The lamp is lit LIT_MS of each PERIOD_MS.
local RANGE, PERIOD_MS, LIT_MS, REFRESH_MS = 25, 1400, 900, 1000

local near, refreshedAt, shownLit = {}, 0, nil

-- The tripped boxes within RANGE of a player whose squares are loaded.
local function refresh()
    refreshedAt = getTimestampMs()
    near = {}
    for _, panel in ipairs(Store.list()) do
        if panel.tripped then
            for index = 0, getNumActivePlayers() - 1 do
                local player = getSpecificPlayer(index)
                if player and not player:isDead() and math.abs(panel.x - player:getX()) <= RANGE
                        and math.abs(panel.y - player:getY()) <= RANGE then
                    local object = Panels.object(panel)
                    if object then near[#near + 1] = object end
                    break
                end
            end
        end
    end
    -- Boxes just found take their frame at once.
    shownLit = nil
end

local function onTick()
    local now = getTimestampMs()
    if now - refreshedAt > REFRESH_MS then refresh() end
    if #near == 0 or getGameSpeed() == 0 then return end
    local lit = BU.remainder(now, PERIOD_MS) < LIT_MS
    if lit == shownLit then return end
    shownLit = lit
    for _, object in ipairs(near) do PanelLook.blink(object, lit) end
end

Events.OnTick.Add(onTick)
