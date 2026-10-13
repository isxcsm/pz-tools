-- A spraying sprinkler's head going round: near each player, every sprinkler that sprays (BU.WaterUnits.spraying) is
-- turned through its frames, an eighth of a turn each FRAME_MS, here only (the server keeps whichever frame it finds,
-- WaterUnits' sync). Which sprinklers are near is worked out once a second; the game paused, they stand still.
require "BuildingUtilities/WaterUnits"
local BU = BuildingUtilities
local Store, Units, WaterUnits = BU.Store, BU.Units, BU.WaterUnits

local RANGE, FRAME_MS, REFRESH_MS = 25, 150, 1000
local FRAMES = WaterUnits.SPRINKLER_SPRITES.spraying

local near, refreshedAt, shownStep = {}, 0, nil

-- The spraying sprinklers within RANGE of a player whose squares are loaded, with their objects.
local function refresh()
    refreshedAt = getTimestampMs()
    near = {}
    local players = {}
    for index = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(index)
        if player and not player:isDead() then players[#players + 1] = player end
    end
    if #players == 0 then return end
    for _, unit in ipairs(Store.unitList("sprinkler")) do
        if WaterUnits.spraying(unit) then
            for _, player in ipairs(players) do
                if math.abs(unit.x - player:getX()) <= RANGE and math.abs(unit.y - player:getY()) <= RANGE then
                    local object = Units.object(unit)
                    if object then near[#near + 1] = { unit = unit, object = object } end
                    break
                end
            end
        end
    end
end

local function onTick()
    local now = getTimestampMs()
    if now - refreshedAt > REFRESH_MS then refresh() end
    if #near == 0 or getGameSpeed() == 0 then return end
    local step = math.floor(now / FRAME_MS)
    if step == shownStep then return end
    shownStep = step
    for index, each in ipairs(near) do
        -- Each a little out of step with the next, as real ones are.
        local name = FRAMES[BU.remainder(step + index * 3, #FRAMES) + 1]
        local sprite = each.object:getSprite()
        if sprite and sprite:getName() ~= name and WaterUnits.isSprayFrame(sprite:getName()) then
            each.object:setSprite(getSprite(name))
        end
    end
end

Events.OnTick.Add(onTick)
