-- Batch 2: assets and units. Sprites and icons load; a solar panel and a rack go down, wire to a main panel, a
-- battery goes in and out with its charge and condition, the rack's overlay follows, a battery is reconditioned,
-- and everything is taken away again. "[bu13]" lines. Leaves nothing behind.
RUN("bu_lib.lua")
RUN("bu_rack.lua")
local BU = BuildingUtilities
local Store, Units, Changes, Actions = BU.Store, BU.Units, BU.Changes, BU.Actions
local function why(_, reason) return tostring(reason or "-") end
local say = BUT.say("bu13")
local player = getPlayer()

-- Assets.
for _, name in ipairs({ "bu_solar_01_0", "bu_solar_01_8", "bu_solar_01_9", "bu_solar_01_10", "bu_solar_01_1", "bu_solar_01_35" }) do
    local sprite = getSprite(name)
    say("sprite", name, sprite ~= nil, sprite and sprite:getProperties():has("Facing") and sprite:getProperties():get("Facing") or "-")
end
say("icons", instanceItem("BuildingUtilities.SolarPanel"):getTex() ~= nil,
    instanceItem("BuildingUtilities.BatteryRack"):getTex() ~= nil)
say("items", getItemNameFromFullType(Units.definition("solar").item), getItemNameFromFullType(Units.definition("rack").item),
    instanceItem(Units.definition("solar").item) ~= nil, instanceItem(Units.definition("rack").item) ~= nil)
local recipes = getScriptManager():getAllCraftRecipes()
local found = {}
for i = 0, recipes:size() - 1 do
    local name = recipes:get(i):getName()
    if name == "MakeSolarPanel" or name == "MakeBatteryRack" then found[#found + 1] = name end
end
say("recipes", table.concat(found, ","))

-- A main panel near the player, and an outside and an inside square near it.
local panel = BUT.nearPanel()
say("panel", panel and panel.id or "none", panel and panel.tier)
if not panel then return end
local outside = BUT.square(panel.x, panel.y, 0, 1, 12, function(sq) return sq:isOutside() and Units.canInstall("solar", sq) end)
local inside = panel.z == 0 and BUT.square(panel.x, panel.y, 0, 1, 12, function(sq) return Units.canInstall("rack", sq) end) or nil
say("squares", outside and (outside:getX() .. "," .. outside:getY()) or "none", inside and (inside:getX() .. "," .. inside:getY()) or "none")
say("rules: rack outside", why(Units.canInstall("rack", outside)), "solar inside", why(Units.canInstall("solar", inside)))

-- Down, wired, a battery in and out.
local solar = Changes.installUnit("solar", outside, Units.spriteFacing("solar", outside, BuildingUtilities.sideOf(outside, player)))
local rack = Changes.installUnit("rack", inside, Units.spriteFacing("rack", inside, BuildingUtilities.sideOf(inside, player)))
say("installed", solar.id, solar.sprite, Units.object(solar) ~= nil, rack.id, Units.object(rack) ~= nil,
    "taken", why(Units.canInstall("solar", outside)))
local cost, other = Actions.lineCost("unit", panel, "power", solar.x, solar.y, solar.z, solar.id)
local wire = cost and cost.items[1]
say("solar line", cost and Store.unit(solar.id) == other, wire and wire[1] or "none", wire and wire[2] or 0)
Changes.connectUnit(solar, panel, { ["Base.ElectricWire"] = 2 })
Changes.connectUnit(rack, panel, { ["Base.ElectricWire"] = 1 })
say("wired", #Store.unitList(nil, panel.id), "again", why(Actions.lineCost("unit", panel, "power", solar.x, solar.y, solar.z, solar.id)),
    "paid", Changes.paidFor(panel)["Base.ElectricWire"])
local battery = instanceItem("Base.CarBattery2")
battery:setUsedDelta(0.62)
battery:setCondition(41)
local record = BU.Rack.batteryRecord(battery)
say("record", record.type, string.format("%.2f", record.charge), record.condition)
for i = 1, 6 do BURACK.put(rack, { type = "Base.CarBattery2", charge = 0.62, condition = 41 }) end
local object = Units.object(rack)
local box = object:getContainer()
say("rack", #rack.batteries, "container", box:getType(), box:getCapacity(), "ids", rack.batteries[1].id ~= nil,
    "overlay", BU.Rack.overlay(rack), object:getOverlaySprite() and object:getOverlaySprite():getName())
say("takes battery", box:isItemAllowed(instanceItem("Base.CarBattery1")), "plank", box:isItemAllowed(instanceItem("Base.Plank")))
-- The bank's change goes to the items; a battery taken out keeps it.
rack.batteries[1].charge, rack.batteries[1].condition = 0.3, 37.6
local back = BURACK.take(rack, 1)
say("out", back:getFullType(), string.format("%.2f", back:getCurrentUsesFloat()), back:getCondition(), #rack.batteries)
for _ = 1, 15 do BURACK.put(rack, { type = "Base.CarBattery1", charge = 0.5, condition = 90 }) end
say("full", #rack.batteries, "takes more", box:isItemAllowed(instanceItem("Base.CarBattery1")), "removable", Units.isEmpty(rack))
BURACK.empty(rack)
say("emptied", #rack.batteries, "removable", Units.isEmpty(rack))
say("empty overlay", object:getOverlaySprite() and object:getOverlaySprite():getName() or "none")

-- Reconditioning, done by hand as the action would.
say("revive", why(BU.Rack.canRevive(player, back)))
local before = back:getCondition()
back:getModData()[BU.Rack.REVIVED] = 3
say("revived out", why(BU.Rack.canRevive(player, back)))
back:getModData()[BU.Rack.REVIVED] = nil
back:setCondition(80)
say("not worn", why(BU.Rack.canRevive(player, back)), "was", before)

-- Then everything goes.
say("refund solar", Changes.removeUnit(solar)["Base.ElectricWire"], "rack", Changes.disconnectUnit(rack)["Base.ElectricWire"])
Changes.removeUnit(rack)
say("left", #Store.unitList(), Store.unitAt(outside:getX(), outside:getY(), 0) == nil)
