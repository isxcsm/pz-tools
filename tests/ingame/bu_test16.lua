-- Batch 5: how the bank hands the load to a generator and takes it back, by fixed rules at every tier (BU.Energy:
-- HANDOVER 20%, TAKE_BACK 80%, the sun with the margin), with made-up network states. "[bu16]" lines. Leaves nothing
-- behind.
RUN("bu_lib.lua")
RUN("bu_rack.lua")
local BU = BuildingUtilities
local Store, Units, Changes, Energy, Networks = BU.Store, BU.Units, BU.Changes, BU.Energy, BU.Networks
local say = BUT.say("bu16")
local f = BUT.f
local panel = BUT.nearPanel()
if not panel then say("no panel"); return end
local tier = panel.tier
-- The scene's units (bu_visual) would count too: off the panel while this runs.
local scene = Store.unitList(nil, panel.id)
for _, unit in ipairs(scene) do unit.panel = nil end

-- A generator on the player's square (loaded) with fuel, and one without.
local px, py, pz = math.floor(getPlayer():getX()), math.floor(getPlayer():getY()), math.floor(getPlayer():getZ())
local withGenerator = { load = 0.6, supplied = true, producers = { { x = px, y = py, z = pz, fuel = 5, condition = 90 } } }
local emptyGenerator = { load = 0.4, supplied = true, producers = { { x = px, y = py, z = pz, fuel = 0, condition = 90 } } }
for t = 1, BU.TIERS do
    panel.tier = t
    local r = Energy.rules(panel, withGenerator)
    local e = Energy.rules(panel, emptyGenerator)
    say("tier", t, "floor", f(r.floor), "restart", f(r.restart), "generators", r.generators,
        "| no fuel: floor", f(e.floor), "restart", f(e.restart), "generators", e.generators)
end

-- A rack: with a generator ready the bank carries the load down to 20%, alone down to empty.
panel.tier = 1
local square = BUT.square(panel.x, panel.y, panel.z, 1, 12, function(sq) return Units.canInstall("rack", sq) end)
local rack = Changes.installUnit("rack", square, BU.Rack.SPRITE)
say("tier 1 rack", tostring(Units.canConnect(rack, panel)))
Changes.connectUnit(rack, panel, {})
for _ = 1, 2 do BURACK.put(rack, { type = "Base.CarBattery1", charge = 0.25, condition = 100 }) end
local onBank = { load = 0.3, supplied = true, producer = { source = Energy.SOURCE }, producers = withGenerator.producers }
say("25% with a generator ready: can", Energy.run(panel, onBank, 0, true))
for _, battery in ipairs(rack.batteries) do battery.charge = 0.18 end
say("18% with a generator ready: can", Energy.run(panel, onBank, 0, true))
local alone = { load = 0.3, supplied = true, producer = { source = Energy.SOURCE }, producers = {} }
say("18% alone: can", Energy.run(panel, alone, 0, true))
-- A generator carries: the bank comes back at 80%, not before; switching by hand from 30%.
local onGenerator = { load = 0.3, supplied = true, enabled = true, producer = { x = px, y = py, z = pz },
    producers = withGenerator.producers }
local rules = Energy.rules(panel, onGenerator)
for _, charge in ipairs({ 0.25, 0.35, 0.79, 0.81 }) do
    for _, battery in ipairs(rack.batteries) do battery.charge = charge end
    local _, ready = Energy.sourceOffer(panel, onGenerator)
    say("on a generator at", f(charge), "takes back", Energy.ready(rules, 0, Energy.bank(panel)), "by hand", tostring(ready))
end
-- A generator charges nothing: a day with it, no sun, only the weak drain moves the bank.
local before = Energy.bank(panel).energy
Energy.run(panel, onGenerator, 24, false)
say("a day on a generator: bank change", f(Energy.bank(panel).energy - before), "flow", f(panel.bankFlow))

BURACK.empty(rack)
Changes.removeUnit(rack)
panel.tier, panel.bankFlow = tier, nil
for _, unit in ipairs(scene) do unit.panel = panel.id end
Changes.unitsChanged(panel)
say("left", #Store.unitList(), "tier", panel.tier, "extra", f(Networks.state(panel, "power").extraLoad))
