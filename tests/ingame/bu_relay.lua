-- The relay's click: sounds at boxes are printed ("[burelay]"). The test scene's generator is wired to the test panel,
-- fuelled and switched on, which the API reports as a producer change. With BURELAYSTOP the scene goes back (the
-- generator off and disconnected).
local BU = BuildingUtilities
local Changes, Networks = BU.Changes, BU.Networks
local GEN = { 3573, 10908, 0 }
local panel = BU.Store.get(ModData.getOrCreate("BUTEST").panel)
if not BURELAY then
    BURELAY = BU.onSound
    BU.onSound = function(panelId, name)
        print("[burelay] sound", panelId, name, string.format("%.3f", getGameTime():getWorldAgeHours()))
        return BURELAY(panelId, name)
    end
end
local g = getCell():getGridSquare(GEN[1], GEN[2], GEN[3]):getGenerator()
if not g then print("[burelay] no generator") return end
local function state(label)
    local s = Networks.state(panel, "power")
    print("[burelay] " .. label, "supplied", tostring(s.supplied), "in use",
        s.producer and (s.producer.source or (s.producer.x .. "," .. s.producer.y)) or "none", "generator on", tostring(g:isActivated()))
end
if BURELAYSTOP then
    g:setActivated(false)
    Changes.disconnectProducer(panel, "power", GEN[1], GEN[2], GEN[3])
    BURELAYSTOP = nil
    state("restored")
    return
end
g:setFuel(10)
g:setCondition(100)
Changes.connectProducer(panel, "power", GEN[1], GEN[2], GEN[3], {})
g:setActivated(true)
state("generator on")
