-- Batch 6: blackout and the energy record. "[bu17]" lines. Leaves the panel as it was.
local BU = BuildingUtilities
local Store, Panels, Changes, Networks = BU.Store, BU.Panels, BU.Changes, BU.Networks
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu17] " .. table.concat(parts, " "))
end
local player = getPlayer()
local panel
for _, p in ipairs(Store.list()) do
    if math.abs(p.x - player:getX()) + math.abs(p.y - player:getY()) < 60 then panel = p; break end
end
if not panel then say("no panel"); return end
say("store version", Store.data().version, "panels fn ok", Store.panels() == Store.data().panels)

local lights = Panels.blackoutLights(panel)
say("lights", #lights, lights[1] or "-")
Changes.setBlackout(panel, true)
local held, count = 0, 0
for _ in pairs(panel.power.blackout) do count = count + 1 end
for _, device in ipairs(Panels.devices(panel, "power")) do if device.held == "blackout" then held = held + 1 end end
say("blackout on: set", count, "held", held, "rule", lights[1] and Networks.rule(panel, "power", lights[1]) or "-")
local object = lights[1] and BU.objectsWithSprite(BU.parseThing(lights[1]))[1]
say("first light has power", object and object:getSquare():haveElectricity() or "-", "switch on", object and object:isActivated() or "-")
Changes.setBlackout(panel, false)
count = 0
for _ in pairs(panel.power.blackout) do count = count + 1 end
say("blackout off: set", count, "rule", lights[1] and Networks.rule(panel, "power", lights[1]) or "-", "log", panel.log[#panel.log].key)

-- The energy record: two made-up hours.
local log, now = panel.energyLog, panel.energyNow
panel.energyLog, panel.energyNow = nil, nil
Store.recordEnergy(panel, 0.2, 0.3, 0.5)
Store.recordEnergy(panel, 0.4, 0.1, 0.6)
panel.energyNow.hour = panel.energyNow.hour - 1
Store.recordEnergy(panel, 0.1, 0.1, nil)
local first = panel.energyLog and panel.energyLog[1]
say("record", panel.energyLog and #panel.energyLog, "made", first and string.format("%.2f", first.made), "used", first and string.format("%.2f", first.used),
    "charge", first and first.charge, "now n", panel.energyNow.n)
for _ = 1, 60 do
    panel.energyNow.hour = panel.energyNow.hour - 1
    Store.recordEnergy(panel, 0, 0, nil)
end
say("kept", #panel.energyLog, "of", Store.ENERGY_HOURS)
panel.energyLog, panel.energyNow = log, now
say("restored")
