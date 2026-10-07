-- Batch 5: the charge controller (tier 3) and deep discharge protection (tier 4), with made-up network states.
-- "[bu16]" lines. Leaves nothing behind.
RUN("bu_lib.lua")
RUN("bu_rack.lua")
local BU = BuildingUtilities
local Store, Units, Changes, Energy, Panels, Networks = BU.Store, BU.Units, BU.Changes, BU.Energy, BU.Panels, BU.Networks
local say = BUT.say("bu16")
local f = BUT.f
local player = getPlayer()
local panel = BUT.nearPanel()
if not panel then say("no panel"); return end
local tier, controller = panel.tier, panel.controller
-- The scene's units (bu_visual) would count too: off the panel while this runs.
local scene = Store.unitList(nil, panel.id)
for _, unit in ipairs(scene) do unit.panel = nil end

local defaults = Energy.settings(panel)
say("defaults", defaults.start, defaults.stop, defaults.quietFrom, defaults.quietTo, defaults.protect, "valid", Energy.validSettings(defaults))
say("invalid start>=stop", Energy.validSettings({ start = 50, stop = 60, quietFrom = 22, quietTo = 6, protect = 20 }),
    Energy.validSettings({ start = 30, stop = 30, quietFrom = 22, quietTo = 6, protect = 20 }), "odd hours",
    Energy.validSettings({ start = 30, stop = 90, quietFrom = 13, quietTo = 6, protect = 20 }))
say("quiet now", Energy.isQuiet(defaults), "hour", f(getGameTime():getTimeOfDay()), "none", Energy.isQuiet({ quietFrom = 0, quietTo = 0 }))

local withGenerator = { load = 0.6, extraLoad = 0.2, loadFactor = 1, supplied = true, producers = { { x = 1, y = 1, z = 0, fuel = 5, condition = 90 } } }
local emptyGenerator = { load = 0.4, supplied = true, producers = { { x = 1, y = 1, z = 0, fuel = 0, condition = 90 } } }
for _, t in ipairs({ 2, 3, 4 }) do
    panel.tier = t
    panel.controller = { start = 30, stop = 90, quietFrom = 0, quietTo = 0, protect = 20 }
    local r = Energy.rules(panel, withGenerator)
    local e = Energy.rules(panel, emptyGenerator)
    say("tier", t, "load", f(r.load), "charging", f(r.charging), "floor", f(r.floor), "restart", f(r.restart), "generators", r.generators,
        "| no fuel: floor", f(e.floor), "generators", e.generators)
end
panel.controller = { start = 30, stop = 90, quietFrom = 0, quietTo = 23, protect = 20 }
panel.tier = 3
local q = Energy.rules(panel, withGenerator)
say("quiet all day: quiet", q.quiet, "floor", f(q.floor), "restart", f(q.restart))

-- A rack at tier 4: the source can carry the load down to 5%, a generator ready takes over below 30% outside quiet hours.
panel.tier = 4
panel.controller = { start = 30, stop = 90, quietFrom = 0, quietTo = 0, protect = 20 }
local square = BUT.square(panel.x, panel.y, panel.z, 1, 12, function(sq) return Units.canInstall("rack", sq) end)
local rack = Changes.installUnit("rack", square, BU.Rack.SPRITE)
Changes.connectUnit(rack, panel, {})
for i = 1, 2 do BURACK.put(rack, { type = "Base.CarBattery1", charge = 0.25, condition = 100 }) end
local onBank = { load = 0.3, supplied = true, producer = { source = Energy.SOURCE }, producers = withGenerator.producers }
local can = Energy.run(panel, onBank, 0, true)
say("25% with a generator ready: can", can)
local alone = { load = 0.3, supplied = true, producer = { source = Energy.SOURCE }, producers = {} }
say("25% alone: can", Energy.run(panel, alone, 0, true))
for _, battery in ipairs(rack.batteries) do battery.charge = 0.06 end
Energy.run(panel, alone, 2, true)
local bank = Energy.bank(panel)
say("drawn to the cutoff", f(bank.charge), "can", Energy.run(panel, alone, 0, true))

-- Protection: saving and unsaving the panel's devices.
local keys = {}
for _, device in ipairs(Panels.devices(panel, "power")) do
    if device.state == "on" and not device.held and not device.essential and (device.power or 0) > 0 and #keys < 2 then keys[#keys + 1] = device.key end
end
Changes.save(panel, keys)
local held = 0
for _, device in ipairs(Panels.devices(panel, "power")) do if device.held == "saving" then held = held + 1 end end
say("saved", #keys, "held as saving", held, "rule", keys[1] and Networks.rule(panel, "power", keys[1]))
Changes.unsave(panel)
held = 0
for _, device in ipairs(Panels.devices(panel, "power")) do if device.held == "saving" then held = held + 1 end end
say("unsaved, held", held)

BURACK.empty(rack)
Changes.removeUnit(rack)
panel.tier, panel.controller, panel.bankFlow = tier, controller, nil
for _, unit in ipairs(scene) do unit.panel = panel.id end
Changes.unitsChanged(panel)
say("left", #Store.unitList(), "tier", panel.tier, "extra", f(Networks.state(panel, "power").extraLoad))
