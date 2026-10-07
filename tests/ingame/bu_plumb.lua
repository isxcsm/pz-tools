-- Vanilla plumbing in game: a sink near the player, a rain barrel on the square above it holding tainted water,
-- the sink plumbed (as ISPlumbItem does), then water taken from the sink into an empty bottle as ISTakeWaterAction
-- does (transferFluidTo). "[buplumb]" lines. BUPLUMB keeps what to take away (bu_plumbdone.lua).
local p = getPlayer()
local cell = getCell()
local sink
for dx = -20, 20 do
    for dy = -20, 20 do
        local sq = cell:getGridSquare(p:getX() + dx, p:getY() + dy, 0)
        if sq and not sink then
            for i = 0, sq:getObjects():size() - 1 do
                local o = sq:getObjects():get(i)
                if o:getSprite() and o:getSprite():getProperties():has(IsoFlagType.waterPiped) then sink = o break end
            end
        end
    end
end
if not sink then print("[buplumb] no sink") return end
local x, y = sink:getSquare():getX(), sink:getSquare():getY()
local above = cell:getGridSquare(x, y, 1) or cell:createNewGridSquare(x, y, 1, true)
local barrel = IsoThumpable.new(cell, above, "carpentry_02_54", false, {})
GameEntityFactory.CreateIsoObjectEntity(barrel, SpriteConfigManager.getObjectInfoFromSprite("carpentry_02_54"):getScript():getParent(), true)
above:AddSpecialObject(barrel)
local fc = barrel:getFluidContainer()
fc:Empty()
fc:addFluid(FluidType.TaintedWater, 50)
local wasPlumbed = sink:getUsesExternalWaterSource()
sink:setUsesExternalWaterSource(true)
sink:doFindExternalWaterSource()
BUPLUMB = { sink = sink, barrel = barrel, above = above, wasPlumbed = wasPlumbed }
print("[buplumb] sink", x, y, sink:getSprite():getName(), "barrel above tainted", tostring(fc:isTainted()), "amount", fc:getAmount())
print("[buplumb] sink has water", tostring(sink:hasWater()), "sink says tainted", tostring(sink:isTaintedWater()), "sink amount", sink:getFluidAmount())
local bottle = instanceItem("Base.WaterBottle")
local bfc = bottle:getFluidContainer()
bfc:Empty()
sink:transferFluidTo(bfc, 0.5)
print("[buplumb] bottle got", bfc:getAmount(), "tainted", tostring(bfc:isTainted()), "primary", tostring(bfc:getPrimaryFluid()),
    "barrel now", fc:getAmount(), tostring(fc:getPrimaryFluid()))
