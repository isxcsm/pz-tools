-- The API fix of pz-tools bae3167 in game: the units' source carries the test panel's load; its units are all
-- disconnected, which takes the source out of the producer list while it is in use: the generator wired after it
-- must take over at once. Then the scene goes back as it was (units wired again, generator off and disconnected).
-- "[buho]" lines.
local BU = BuildingUtilities
local Store, Changes, Networks, Energy = BU.Store, BU.Changes, BU.Networks, BU.Energy
local GEN = { 3573, 10908, 0 }
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
local function state(label)
    local s = Networks.state(panel, "power")
    local g = getCell():getGridSquare(GEN[1], GEN[2], GEN[3]):getGenerator()
    print("[buho] " .. label, "supplied", tostring(s.supplied), "in use",
        s.producer and (s.producer.source or (s.producer.x .. "," .. s.producer.y)) or "none", "producers", #(s.producers or {}),
        "generator on", tostring(g and g:isActivated()))
end
local g = getCell():getGridSquare(GEN[1], GEN[2], GEN[3]):getGenerator()
if not g then print("[buho] no generator") return end
g:setFuel(10)
g:setCondition(100)
Changes.connectProducer(panel, "power", GEN[1], GEN[2], GEN[3], {})
state("wired")
if not Energy.inUse(Networks.state(panel, "power")) then
    Networks.setSource(panel, true, true)
    state("source on")
end
local units = Store.unitList(nil, panel.id)
for _, unit in ipairs(units) do Changes.disconnectUnit(unit) end
state("units out")
BUHO = units
