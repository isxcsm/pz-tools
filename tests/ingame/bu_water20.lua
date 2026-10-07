-- For bu_test20: two vanilla rain collector barrels on free squares outside near the player, part filled, connected
-- to the test panel as water producers. Does nothing when the panel has two already. "[bu20w]" lines.
local BU = BuildingUtilities
local Store, Changes = BU.Store, BU.Changes
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then print("[bu20w] no panel") return end
if #panel.water.producers >= 2 then print("[bu20w] has", #panel.water.producers, "producers") return end
local p = getPlayer():getSquare()
local placed = 0
for r = 2, 12 do
    for dx = -r, r do
        for dy = -r, r do
            local q = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, 0)
            if placed < 2 and q and q:isOutside() and not q:getRoom() and q:getObjects():size() == 1 and q:isFree(false)
                and q:getMovingObjects():size() == 0 then
                local sprite = "carpentry_02_54"
                local barrel = IsoThumpable.new(getCell(), q, sprite, false, {})
                local info = SpriteConfigManager.getObjectInfoFromSprite(sprite)
                GameEntityFactory.CreateIsoObjectEntity(barrel, info:getScript():getParent(), true)
                q:AddSpecialObject(barrel)
                local fc = barrel:getFluidContainer()
                fc:Empty()
                fc:addFluid(FluidType.Water, 40 + placed * 40)
                Changes.connectProducer(panel, "water", q:getX(), q:getY(), 0, true)
                placed = placed + 1
                print("[bu20w] barrel at", q:getX(), q:getY(), "holds", fc:getAmount(), "of", fc:getCapacity())
            end
        end
    end
end
print("[bu20w] producers now", #panel.water.producers)
