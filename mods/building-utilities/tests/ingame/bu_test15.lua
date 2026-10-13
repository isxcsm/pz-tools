-- Batch 4: the battery bank. Capacity by kind and condition, wear by depth, worn batteries, the bank carrying the
-- load and charging, with a made-up network state. "[bu15]" lines. Leaves nothing behind.
RUN("bu_lib.lua")
RUN("bu_rack.lua")
local BU = BuildingUtilities
local Store, Units, Changes, Energy, Networks = BU.Store, BU.Units, BU.Changes, BU.Energy, BU.Networks
local say = BUT.say("bu15")
local f = BUT.f
local player = getPlayer()

say("capacity std/heavy/sport full", f(Energy.batteryCapacity({ type = "Base.CarBattery1", condition = 100 })),
    f(Energy.batteryCapacity({ type = "Base.CarBattery2", condition = 100 })), f(Energy.batteryCapacity({ type = "Base.CarBattery3", condition = 100 })),
    "std at 50 / 0", f(Energy.batteryCapacity({ type = "Base.CarBattery1", condition = 50 })), f(Energy.batteryCapacity({ type = "Base.CarBattery1", condition = 0 })))
say("wearAt 0.8/0.5/0.35/0.2/0.1/0", f(Energy.wearAt(0.8)), f(Energy.wearAt(0.5)), f(Energy.wearAt(0.35)), f(Energy.wearAt(0.2)), f(Energy.wearAt(0.1)), f(Energy.wearAt(0)))
say("cold now", f(Energy.coldShare({})), "temp", f(getClimateManager():getTemperature()))

local panel = BUT.nearPanel()
if not panel then say("no panel"); return end
local tier = panel.tier
-- The scene's units (bu_visual) would count too: off the panel while this runs.
local scene = Store.unitList(nil, panel.id)
for _, unit in ipairs(scene) do unit.panel = nil end
panel.tier = 1
local square = BUT.square(panel.x, panel.y, panel.z, 1, 12, function(sq) return Units.canInstall("rack", sq) end)
local rack = Changes.installUnit("rack", square, BU.Rack.SPRITE)
say("tier 1 rack", tostring(Units.canConnect(rack, panel)))
Changes.connectUnit(rack, panel, {})
for i = 1, 4 do
    BURACK.put(rack, { type = i == 4 and "Base.CarBattery2" or "Base.CarBattery1", charge = 1, condition = i == 1 and 20 or 100 })
end
local bank = Energy.bank(panel)
say("bank", #bank.batteries, "capacity", f(bank.capacity), "energy", f(bank.energy), "weak", bank.weak, "cold", f(bank.cold), "usable", f(bank.usable))

-- The bank carries a load of 0.5 for two hours at night (no sun counted: none of the panel's units is a panel).
local state = { load = 0.5, supplied = true, producer = { source = Energy.SOURCE } }
local can = Energy.run(panel, state, 2, true)
bank = Energy.bank(panel)
say("after 2h of 0.5: energy", f(bank.energy), "charge", f(bank.charge), "flow", f(panel.bankFlow), "can", can,
    "conditions", f(rack.batteries[1].condition), f(rack.batteries[2].condition))
-- Drawn down to nothing: no longer available.
can = Energy.run(panel, { load = 5, supplied = true, producer = { source = Energy.SOURCE } }, 10, true)
bank = Energy.bank(panel)
say("drained: energy", f(bank.energy), "can", can, "condition", f(rack.batteries[2].condition), "overlay", BU.Rack.overlay(rack))
-- Not available, a little charge: does not start until 2%.
for _, battery in ipairs(rack.batteries) do battery.charge = 0.01 end
say("1% start", Energy.run(panel, { load = 0.1, supplied = false }, 0, false), "available stays", Energy.run(panel, { load = 0.1, supplied = false }, 0, true))
-- A generator runs: no sun, nothing charges or drains over a day; the worst battery holds part of the bank back.
for _, battery in ipairs(rack.batteries) do battery.charge = 0.5 end
bank = Energy.bank(panel)
local before = bank.energy
Energy.run(panel, { load = 0.2, supplied = true, producer = { x = 1, y = 1, z = 0 } }, 24, false)
bank = Energy.bank(panel)
say("a day with a generator: change", f(before - bank.energy), "expected 0; held back", f(bank.drag), "worst", bank.worst and bank.worst.condition or "-")

-- Batteries back out keep what the bank did to them.
local item = BURACK.take(rack, 2)
say("out", item:getFullType(), f(item:getCurrentUsesFloat()), item:getCondition())
BURACK.empty(rack)
Changes.removeUnit(rack)
panel.tier = tier
panel.bankFlow = nil
for _, unit in ipairs(scene) do unit.panel = panel.id end
Changes.unitsChanged(panel)
say("left", #Store.unitList(), "tier", panel.tier)
