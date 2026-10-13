-- Building Utilities Dev: a debug scenario on the main menu's SCENARIOS list (debug mode): a new world among houses,
-- no zombies, the grid's power and water off, a character with the skills the mod asks and what its checks use.
-- The list shows it only while the main menu has the mods on (Zomboid/mods/default.txt), and the world it makes keeps
-- no mods: give its save the mods.txt of a test save, then empty the menu's list again, so Continue loads them anew.
if not isDebugEnabled() then return end
if debugScenarios == nil then debugScenarios = {} end

local GIFTS = {
    { "BuildingUtilities.BreakerBox" }, { "BuildingUtilities.BreakerBox4" }, { "BuildingUtilities.ControlBoard", 4 },
    { "BuildingUtilities.SolarPanel", 4 }, { "BuildingUtilities.BatteryRack" }, { "BuildingUtilities.WaterPump" },
    { "BuildingUtilities.BoosterPump" }, { "BuildingUtilities.WaterFilter" }, { "BuildingUtilities.Sprinkler", 2 },
    { "BuildingUtilities.JunctionBox", 2 }, { "BuildingUtilities.YardHydrant", 2 },
    { "Base.CarBattery1" }, { "Base.CarBattery2" }, { "Base.BakingSoda" },
    { "Base.ElectricWire", 50 }, { "Base.Pipe", 30 }, { "Base.ElectronicsScrap", 20 }, { "Base.SmallSheetMetal", 10 },
    { "Base.Charcoal", 10 }, { "Base.RippedSheets", 10 },
    { "Base.Screwdriver" }, { "Base.PipeWrench" }, { "Base.Pliers" }, { "Base.Generator" },
}

local SKILLS = { "Electricity", "Maintenance", "Farming", "Woodwork", "MetalWelding" }

debugScenarios.BuildingUtilities = {
    name = "Building Utilities",
    startLoc = { x = 10835, y = 10144, z = 0 },
    setSandbox = function()
        SandboxVars.Zombies = 6
        SandboxVars.ElecShutModifier = -1
        SandboxVars.WaterShutModifier = -1
        SandboxVars.LootItemRemovalList = ""
    end,
    onStart = function()
        local p = getPlayer()
        for _, name in ipairs(SKILLS) do
            local perk = Perks[name]
            if perk then
                p:getXp():setXPToLevel(perk, 10)
                p:setPerkLevelDebug(perk, 10)
            end
        end
        p:setGodMod(true)
        local inv = p:getInventory()
        for _, entry in ipairs(GIFTS) do
            for _ = 1, entry[2] or 1 do inv:AddItem(entry[1]) end
        end
        local can = inv:AddItem("Base.PetrolCan")
        local fluid = can and can:getFluidContainer()
        if fluid then fluid:addFluid(Fluid.Petrol, fluid:getFreeCapacity()) end
        print("[BU dev] scenario started")
    end,
}
