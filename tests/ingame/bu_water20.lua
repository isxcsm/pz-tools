-- For bu_test20: two vanilla rain collector barrels on free squares outside near the player, part filled, connected
-- to the test panel as water producers. Does nothing when the panel has two already. "[bu20w]" lines.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Changes = BU.Store, BU.Changes
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then print("[bu20w] no panel") return end
if #panel.water.producers >= 2 then print("[bu20w] has", #panel.water.producers, "producers") return end
-- A barrel square has more than its floor on it, so the second search passes the first one.
for placed = 0, 1 do
    local q = BUT.squareNear(2, 12, function(q) return not q:getRoom() and BUT.freeOutside(q) end)
    if q then
        local sprite = "carpentry_02_54"
        local barrel = IsoThumpable.new(getCell(), q, sprite, false, {})
        local info = SpriteConfigManager.getObjectInfoFromSprite(sprite)
        GameEntityFactory.CreateIsoObjectEntity(barrel, info:getScript():getParent(), true)
        q:AddSpecialObject(barrel)
        local fc = barrel:getFluidContainer()
        fc:Empty()
        fc:addFluid(FluidType.Water, 40 + placed * 40)
        Changes.connectProducer(panel, "water", q:getX(), q:getY(), 0, true)
        print("[bu20w] barrel at", q:getX(), q:getY(), "holds", fc:getAmount(), "of", fc:getCapacity())
    end
end
print("[bu20w] producers now", #panel.water.producers)
