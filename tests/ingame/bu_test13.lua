-- Batch 2: assets and units. Sprites and icons load; a solar panel and a rack go down, wire to a main panel, a
-- battery goes in and out with its charge and condition, the rack's overlay follows, a battery is reconditioned,
-- and everything is taken away again. "[bu13]" lines. Leaves nothing behind.
RUN("bu_rack.lua")
local BU = BuildingUtilities
local Store, Panels, Units, Changes, Actions = BU.Store, BU.Panels, BU.Units, BU.Changes, BU.Actions
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[bu13] " .. table.concat(parts, " "))
end
local player = getPlayer()

-- Assets.
for _, name in ipairs({ "bu_solar_01_0", "bu_solar_01_8", "bu_solar_01_9", "bu_solar_01_10", "bu_solar_01_1", "bu_solar_01_35" }) do
    local sprite = getSprite(name)
    say("sprite", name, sprite ~= nil, sprite and sprite:getProperties():has("Facing") and sprite:getProperties():get("Facing") or "-")
end
say("icons", getTexture("Item_BUSolarPanel") ~= nil, getTexture("Item_BUBatteryRack") ~= nil)
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
local panel
for _, p in ipairs(Store.list()) do
    if not p.parent and math.abs(p.x - player:getX()) + math.abs(p.y - player:getY()) < 60 then panel = p; break end
end
say("panel", panel and panel.id or "none", panel and panel.tier)
if not panel then return end
local cell = getCell()
local outside, inside
for r = 1, 12 do
    for dx = -r, r do
        for dy = -r, r do
            local sq = cell:getGridSquare(panel.x + dx, panel.y + dy, 0)
            if sq then
                if not outside and sq:isOutside() and Units.canInstall("solar", sq) then outside = sq end
                if not inside and panel.z == 0 and Units.canInstall("rack", sq) then inside = sq end
            end
        end
    end
    if outside and inside then break end
end
say("squares", outside and (outside:getX() .. "," .. outside:getY()) or "none", inside and (inside:getX() .. "," .. inside:getY()) or "none")
say("rules: rack outside", tostring(select(2, Units.canInstall("rack", outside))), "solar inside", tostring(select(2, Units.canInstall("solar", inside))))

-- Down, wired, a battery in and out.
local solar = Changes.installUnit("solar", outside, Units.spriteFor("solar", outside, player))
local rack = Changes.installUnit("rack", inside, Units.spriteFor("rack", inside, player))
say("installed", solar.id, solar.sprite, Units.object(solar) ~= nil, rack.id, Units.object(rack) ~= nil,
    "taken", tostring(select(2, Units.canInstall("solar", outside))))
local cost, other = Actions.lineCost("unit", panel, "power", solar.x, solar.y, solar.z, solar.id)
say("solar line", cost and Store.unit(solar.id) == other, cost and cost.items[1][1], cost and cost.items[1][2])
Changes.connectUnit(solar, panel, { ["Base.ElectricWire"] = 2 })
Changes.connectUnit(rack, panel, { ["Base.ElectricWire"] = 1 })
say("wired", #Store.unitList(nil, panel.id), "again", tostring(select(2, Actions.lineCost("unit", panel, "power", solar.x, solar.y, solar.z, solar.id))),
    "paid", Changes.paidFor(panel)["Base.ElectricWire"])
local battery = instanceItem("Base.CarBattery2")
battery:setUsedDelta(0.62)
battery:setCondition(41)
local record = BU.Rack.batteryRecord(battery)
say("record", record.type, string.format("%.2f", record.charge), record.condition, BU.Rack.batteryText(record))
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
say("revive", tostring(select(2, BU.Rack.canRevive(player, back))))
local before = back:getCondition()
back:getModData()[BU.Rack.REVIVED] = 3
say("revived out", tostring(select(2, BU.Rack.canRevive(player, back))))
back:getModData()[BU.Rack.REVIVED] = nil
back:setCondition(80)
say("not worn", tostring(select(2, BU.Rack.canRevive(player, back))), "was", before)

-- A sub-panel cannot be made of a panel with units; then everything goes.
local another
for _, p in ipairs(Store.list()) do if p ~= panel then another = p end end
say("link refused", another and tostring(select(2, Panels.canLink(panel, another))) or "no other panel", "units count", #Store.unitList(nil, panel.id))
say("refund solar", Changes.removeUnit(solar)["Base.ElectricWire"], "rack", Changes.disconnectUnit(rack)["Base.ElectricWire"])
Changes.removeUnit(rack)
say("left", #Store.unitList(), Store.unitAt(outside:getX(), outside:getY(), 0) == nil)
