-- After bu_handover.lua: the test panel's power network some frames later; with BUHOSTOP the scene goes back (units
-- wired again, the generator off and disconnected). "[buho]" lines.
local BU = BuildingUtilities
local Store, Changes, Networks = BU.Store, BU.Changes, BU.Networks
local GEN = { 3573, 10908, 0 }
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
local function state(label)
    local s = Networks.state(panel, "power")
    local g = getCell():getGridSquare(GEN[1], GEN[2], GEN[3]):getGenerator()
    print("[buho] " .. label, "supplied", tostring(s.supplied), "in use",
        s.producer and (s.producer.source or (s.producer.x .. "," .. s.producer.y)) or "none", "producers", #(s.producers or {}),
        "generator on", tostring(g and g:isActivated()), "units", #Store.unitList(nil, panel.id))
end
state("later")
if BUHOSTOP then
    for _, unit in ipairs(BUHO) do Changes.connectUnit(unit, panel, {}) end
    getCell():getGridSquare(GEN[1], GEN[2], GEN[3]):getGenerator():setActivated(false)
    Changes.disconnectProducer(panel, "power", GEN[1], GEN[2], GEN[3])
    state("restored")
end
