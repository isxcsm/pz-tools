-- For looking: two solar panels outside and a rack inside wired to the test panel (tier 3), four batteries in the
-- rack, items in the player's hands for the menus, and the panel's window open.
RUN("bu_rack.lua")
local BU = BuildingUtilities
local Store, Units, Changes = BU.Store, BU.Units, BU.Changes
local p = getPlayer()
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
panel.tier = 3
local cell = getCell()
local solar, rack = {}, nil
for r = 1, 12 do
    for dx = -r, r do
        for dy = -r, r do
            local sq = cell:getGridSquare(panel.x + dx, panel.y + dy, 0)
            if sq then
                if #solar < 2 and Units.canInstall("solar", sq) then
                    solar[#solar + 1] = Changes.installUnit("solar", sq, #solar == 0 and Units.SPRITES.W or Units.SPRITES.N)
                elseif not rack and Units.canInstall("rack", sq) and (math.abs(dx) + math.abs(dy)) > 1 then
                    rack = Changes.installUnit("rack", sq, Units.SPRITES.rack)
                end
            end
        end
    end
    if #solar >= 2 and rack then break end
end
for _, unit in ipairs(solar) do Changes.connectUnit(unit, panel, { ["Base.ElectricWire"] = 1 }) end
Changes.connectUnit(rack, panel, { ["Base.ElectricWire"] = 1 })
for i = 1, 4 do BURACK.put(rack, { type = i == 1 and "Base.CarBattery2" or "Base.CarBattery1", charge = 0.7, condition = i == 4 and 25 or 90 }) end
local inv = p:getInventory()
for _, t in ipairs({ "BuildingUtilities.SolarPanel", "BuildingUtilities.BatteryRack", "Base.CarBattery1", "Base.CarBattery3", "Base.BakingSoda", "Base.Screwdriver" }) do
    inv:AddItem(t)
end
local worn = inv:getFirstTypeRecurse("Base.CarBattery3")
worn:setCondition(30)
print("[buvis] solar", #solar, solar[1] and (solar[1].x .. "," .. solar[1].y), solar[2] and (solar[2].x .. "," .. solar[2].y), "rack", rack and (rack.x .. "," .. rack.y),
    "icon", tostring(getTexture("media/textures/Item_BUSolarPanel.png") ~= nil), tostring(instanceItem("BuildingUtilities.SolarPanel"):getTexture()))
BU.PanelWindow.open(p, panel)
