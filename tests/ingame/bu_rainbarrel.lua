-- A vanilla rain collector barrel (as the map makes one) put empty on a free square outside, and a storm started as
-- the admin panel does. bu_rainread.lua reads what fills it. "[burb]" lines.
local p = getPlayer():getSquare()
local found
for r = 2, 12 do
    for dx = -r, r do
        for dy = -r, r do
            local q = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, 0)
            if not found and q and q:isOutside() and not q:getRoom() and q:getObjects():size() == 1 and q:isFree(false)
                and q:getMovingObjects():size() == 0 then found = q end
        end
    end
end
if not found then print("[burb] no free square outside") return end
local sprite = "carpentry_02_54"
local barrel = IsoThumpable.new(getCell(), found, sprite, false, {})
local info = SpriteConfigManager.getObjectInfoFromSprite(sprite)
GameEntityFactory.CreateIsoObjectEntity(barrel, info:getScript():getParent(), true)
found:AddSpecialObject(barrel)
local fc = barrel:getFluidContainer()
fc:Empty()
BURB = { x = found:getX(), y = found:getY() }
getClimateManager():triggerCustomWeatherStage(WeatherPeriod.STAGE_STORM, 4)
print("[burb] barrel at", found:getX(), found:getY(), "outside", tostring(found:isOutside()), "capacity", fc:getCapacity(),
    "rain catcher", fc:getRainCatcher(), "amount", fc:getAmount(), "clean fill", tostring(fc:isFilledWithCleanWater()))
