-- Batch 4 of the plan (DESIGN 12), the generators' noise: how far the game says each is heard (its item's sound
-- radius, half inside a room), the disc it makes, and the range showing it on the plan and the ground (dim while the
-- generator is off, shown again when it starts). "[bu22]" lines. Puts two generators down and takes them away again,
-- unless BU22_KEEP is set: then they and the range stay for a look, and BU22_CLEAN() takes them away.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Geometry, Changes, PanelWindow = BU.Store, BU.Panels, BU.Geometry, BU.Changes, BU.PanelWindow
local say = BUT.say("bu22")
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end

-- The disc: the squares within the radius, as a sound carries.
local function count(area)
    local cells, edges = 0, 0
    for y = area.minY, area.minY + area.h - 1 do
        for x = area.minX, area.minX + area.w - 1 do
            if Geometry.reached(area, x, y) then cells = cells + 1 end
            if Geometry.onEdge(area, x, y) then edges = edges + 1 end
        end
    end
    return cells, edges
end
say("disc 20 cells, edge", count(Geometry.disc(0, 0, 20)))
say("disc 10 cells, edge", count(Geometry.disc(0, 0, 10)))
say("disc 20 reaches (20,0)", Geometry.reached(Geometry.disc(0, 0, 20), 20, 0), "(15,15)",
    Geometry.reached(Geometry.disc(0, 0, 20), 15, 15))

-- A free square near the player, outside or in a room.
local function freeSquare(inside)
    return BUT.squareNear(2, 20, function(q)
        return (q:getRoom() ~= nil) == inside and q:getObjects():size() == 1 and q:isFree(false) and not q:getGenerator()
            and q:getMovingObjects():size() == 0
    end)
end
local outside, inside = freeSquare(false), freeSquare(true)
local old = IsoGenerator.new(instanceItem("Base.Generator_Old"), getCell(), outside)
local plain = inside and IsoGenerator.new(instanceItem("Base.Generator"), getCell(), inside)
say("old outside at", outside:getX(), outside:getY(), "noise", Panels.generatorNoise(outside:getX(), outside:getY(), 0))
if plain then say("plain inside at", inside:getX(), inside:getY(), "noise", Panels.generatorNoise(inside:getX(), inside:getY(), 0)) end
say("not loaded (far away) noise", Panels.generatorNoise(1, 1, 0, true))

-- Connected to the test panel: the range shows its noise.
Changes.connectProducer(panel, "power", outside:getX(), outside:getY(), 0, true)
PanelWindow.open(getPlayer(), panel)
local window = PanelWindow.get(panel.id)
-- The whole plan, as the edges counted are those on the map.
window.plan.zoom, window.plan.panX, window.plan.panY = nil, nil, nil
if window:activeUtility() ~= "power" then window.tabs:activateView(getText("IGUI_BU_Tab_power")) end
window:refresh()
if window.rangeShown then window:onRange() end
window:onRange()
local plan = window.plan
local legend = false
for _, entry in ipairs(plan.legend) do if entry.text == getText("IGUI_BU_Legend_rangeNoise") then legend = true end end
local noises = plan.data.ranges and plan.data.ranges.noise or {}
say("range shown", window.rangeShown, "noises", #noises, "radius", noises[1] and noises[1].radius, "running",
    noises[1] and noises[1].running, "legend", legend, "plan edges", #plan.edges)
local key = plan.data.rangeKey
old:setActivated(true)
window:refresh()
say("started: activated", old:isActivated(), "key changed", key ~= plan.data.rangeKey, "running now",
    plan.data.ranges.noise[1] and plan.data.ranges.noise[1].running)
old:setActivated(false)
window:refresh()

function BU22_CLEAN()
    Changes.disconnectProducer(panel, "power", outside:getX(), outside:getY(), 0)
    old:remove()
    if plain then plain:remove() end
    window:refresh()
    say("cleaned: producers", #panel.power.producers, "generator left", outside:getGenerator() ~= nil)
end
if not BU22_KEEP then
    if window.rangeShown then window:onRange() end
    BU22_CLEAN()
end
