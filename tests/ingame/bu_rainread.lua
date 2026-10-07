-- After bu_rainbarrel.lua: the rain now and what the barrel holds. With BURBDONE the barrel is taken away.
local sq = getCell():getGridSquare(BURB.x, BURB.y, 0)
local climate = getClimateManager()
for i = 0, sq:getObjects():size() - 1 do
    local o = sq:getObjects():get(i)
    local fc = o:getFluidContainer()
    if fc then
        print("[burb] raining", tostring(climate:isRaining()), "intensity", climate:getPrecipitationIntensity(), "amount", fc:getAmount(),
            "tainted", tostring(fc:isTainted()), "primary", tostring(fc:getPrimaryFluid()), "object tainted", tostring(o:isTaintedWater()))
        if BURBDONE then sq:transmitRemoveItemFromSquare(o) print("[burb] removed") end
        break
    end
end
