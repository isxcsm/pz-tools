-- Building Utilities Dev: the "BU" section of the shared debug window (PZExtDev, F8): give, the panel, power, solar
-- and batteries, water, devices, options. Each page shows its state at the top, kept up while it shows, and its
-- controls below; every control calls a function of BuildingUtilities.Dev (Dev.lua). The pages after the first work
-- on one panel: the one chosen on the panel page, else the nearest. The game's environment (time, weather,
-- temperature, the character) is the window's own "API" section. Debug mode only.
-- Mod Lua holds no letters past ASCII (the game reads them as U+FFFD): every text comes from translation keys.
if not isDebugEnabled() then return end
require "PZExtDev/Panel"
require "BuildingUtilities/Dev/Dev"
local BU = BuildingUtilities
local Dev = BU.Dev

local function T(key, ...)
    return getText("IGUI_BUDev_" .. key, ...)
end

local function itemName(fullType)
    return getItemNameFromFullType(fullType) or fullType
end

-- A give button: the item's own name, and the count past one.
local function gift(fullType, count)
    local text = itemName(fullType) .. ((count or 1) > 1 and (" x" .. tostring(count)) or "")
    return { text, function() Dev.give({ { fullType, count or 1 } }) end }
end

-- The panel line a page starts with; the page's controls do nothing without one.
local function panelLine(panel)
    return panel and T("Panel", Dev.name(panel)) or T("NoPanel", tostring(Dev.REACH))
end

-- A control that works on the panel, when there is one.
local function onPanel(fn)
    return function()
        local panel = Dev.selected()
        if panel then fn(panel) else Dev.say("no panel") end
    end
end

local function yes(on) return on and T("Yes") or T("No") end

-- ---- give ---------------------------------------------------------------------------------------------------------

local function givePage(page, ui)
    ui.heading(page, T("Gv_Units"), 1)
    local rows = ui.buttons(page, 2, {
        gift("BuildingUtilities.BreakerBox"),
        gift("BuildingUtilities.SolarPanel", 4),
        gift("BuildingUtilities.BatteryRack"),
        gift("BuildingUtilities.WaterPump"),
        gift("BuildingUtilities.BoosterPump"),
        gift("BuildingUtilities.WaterFilter"),
        gift("BuildingUtilities.Sprinkler", 2),
    })
    local n = 3 + rows
    ui.heading(page, T("Gv_Batteries"), n)
    rows = ui.buttons(page, n + 1, {
        gift("Base.CarBattery1"),
        gift("Base.CarBattery2"),
        gift("Base.CarBattery3"),
        { T("Gv_Worn"), function() Dev.giveWornBattery() end },
        gift("Base.BakingSoda"),
    })
    n = n + 2 + rows
    ui.heading(page, T("Gv_Lines"), n)
    rows = ui.buttons(page, n + 1, {
        gift("Base.ElectricWire", 50),
        gift("Base.Pipe", 30),
        gift("Base.ElectronicsScrap", 20),
        gift("Base.SmallSheetMetal", 10),
        gift("Base.Charcoal", 10),
        gift("Base.RippedSheets", 10),
    })
    n = n + 2 + rows
    ui.heading(page, T("Gv_Tools"), n)
    ui.buttons(page, n + 1, {
        gift("Base.Screwdriver"),
        gift("Base.PipeWrench"),
        gift("Base.Generator"),
        { itemName("Base.PetrolCan"), function() Dev.giveFuelCan() end },
    })
    local free = ui.tick(page, T("Gv_Free"), ui.PAD, ui.row(n + 3), function(on)
        Dev.setOption("BuildingUtilities.CostsEnabled", not on)
    end)
    page.refresh = function()
        free:setSelected(1, Dev.option("CostsEnabled", true) ~= true)
    end
end

-- ---- the panel ------------------------------------------------------------------------------------------------------

local function panelPage(page, ui)
    local state = ui.lines(page, 1, 4)
    local list = ui.combo(page, ui.PAD, ui.row(6), 320, {})
    local function readList()
        list:clear()
        for _, entry in ipairs(Dev.panels()) do
            list:addOptionWithData(Dev.name(entry.panel) .. "  " .. ui.num(entry.distance, 0), entry.panel.id)
        end
    end
    local _, x = ui.button(page, T("Pn_Read"), ui.PAD + 330, ui.row(6), 0, readList)
    local _, x2 = ui.button(page, T("Pn_Choose"), x, ui.row(6), 0, function()
        local id = list:getSelectedData()
        if id then Dev.select(id) end
    end)
    ui.button(page, T("Pn_Nearest"), x2, ui.row(6), 0, function() Dev.select(nil) end)

    ui.heading(page, T("Pn_Tier"), 7)
    local tiers = {}
    for tier = 1, BU.TIERS do
        tiers[#tiers + 1] = { T("Pn_TierN", tostring(tier)), onPanel(function(p) Dev.setTier(p, tier) end) }
    end
    ui.buttons(page, 8, tiers)
    ui.heading(page, T("Pn_Breaker"), 9)
    local rows = ui.buttons(page, 10, {
        { T("Pn_Trip"), onPanel(Dev.trip) },
        { T("Pn_Reset"), onPanel(Dev.resetBreaker) },
        { T("Pn_SwitchOff"), onPanel(function(p) Dev.mainSwitch(p, true) end) },
        { T("Pn_SwitchOn"), onPanel(function(p) Dev.mainSwitch(p, false) end) },
        { T("Pn_Overload"), onPanel(function(p) Dev.overload(p, true) end) },
        { T("Pn_OverloadMild"), onPanel(function(p) Dev.overload(p, true, 1.1) end) },
        { T("Pn_OverloadOff"), onPanel(function(p) Dev.overload(p, false) end) },
    })
    ui.buttons(page, 10 + rows, {
        { T("Pn_LogSample"), onPanel(Dev.logSample) },
        { T("Pn_LogClear"), onPanel(Dev.clearLog) },
        { T("Pn_Window"), onPanel(Dev.openWindow) },
        { T("Pn_GoTo"), onPanel(Dev.goTo) },
    })
    readList()

    page.refresh = function()
        local p = Dev.selected()
        if not p then state:set({ panelLine(nil) }) return end
        local zone = p.rooms and T("Pn_ZoneRooms") or T("Pn_ZoneWhole")
        state:set({
            panelLine(p) .. (Dev.selectedId and "" or ("  " .. T("Pn_IsNearest"))),
            T("Pn_State", ui.num(p.tier or 1), yes(p.tripped), yes(p.switchedOff), yes(Dev.overloaded(p))),
            T("Pn_More", zone, ui.num(#(p.log or {}))),
            T("Pn_At", ui.num(p.x), ui.num(p.y), ui.num(p.z)),
        })
    end
end

-- ---- power ----------------------------------------------------------------------------------------------------------

local function powerPage(page, ui)
    local state = ui.lines(page, 1, 4)
    ui.heading(page, T("Pw_Generators"), 6)
    ui.buttons(page, 7, {
        { T("Pw_SpawnFull"), function() Dev.spawnGenerator(1) end },
        { T("Pw_SpawnLow"), function() Dev.spawnGenerator(0.05) end },
        { T("Pw_Fuel", "100"), function() Dev.setFuel(1) end },
        { T("Pw_Fuel", "10"), function() Dev.setFuel(0.1) end },
        { T("Pw_Fuel", "0"), function() Dev.setFuel(0) end },
    })
    ui.hint(page, T("Pw_FuelHint"), 8)
    ui.heading(page, T("Pw_Grid"), 10)
    ui.buttons(page, 11, {
        { T("Pw_GridOff"), function() Dev.gridPower(false) end },
        { T("Pw_GridOn"), function() Dev.gridPower(true) end },
    })
    page.refresh = function()
        local p = Dev.selected()
        local lines = { panelLine(p), T("Pw_GridNow", yes(Dev.gridPowerOn())) }
        local s = p and BU.Networks.state(p, "power")
        if s then
            lines[3] = T("Pw_Load", ui.num(s.load or 0, 2), ui.num(BU.capacity(p.tier or 1), 2), yes(s.supplied))
            lines[4] = T("Pw_FuelNow", ui.num(s.fuelPerHour or 0, 3), s.hoursLeft and ui.num(s.hoursLeft, 1) or "-",
                ui.num(s.producers and #s.producers or 0))
        elseif p then
            lines[3] = T("Pw_NoNetwork")
        end
        state:set(lines)
    end
end

-- ---- solar panels and batteries -------------------------------------------------------------------------------------

local function solarPage(page, ui)
    local state = ui.lines(page, 1, 4)
    local Env = PZExtDev.Env
    local rows = ui.buttons(page, 6, {
        { T("So_Noon"), function() Env.time(12) end },
        { T("So_TwoAm"), function() Env.time(2) end },
        { T("So_Snow", "50"), onPanel(function(p) Dev.snow(p, 0.5) end) },
        { T("So_Snow", "100"), onPanel(function(p) Dev.snow(p, 1) end) },
        { T("So_SnowClear"), onPanel(function(p) Dev.snow(p, nil) end) },
    })
    local n = 7 + rows
    ui.heading(page, T("So_Bank"), n)
    rows = ui.buttons(page, n + 1, {
        { T("So_Charge", "0"), onPanel(function(p) Dev.setBatteries(p, 0) end) },
        { T("So_Charge", "20"), onPanel(function(p) Dev.setBatteries(p, 0.2) end) },
        { T("So_Charge", "50"), onPanel(function(p) Dev.setBatteries(p, 0.5) end) },
        { T("So_Charge", "100"), onPanel(function(p) Dev.setBatteries(p, 1) end) },
        { T("So_Condition", "100"), onPanel(function(p) Dev.setBatteries(p, nil, 100) end) },
        { T("So_Condition", "45"), onPanel(function(p) Dev.setBatteries(p, nil, 45) end) },
        { T("So_Condition", "10"), onPanel(function(p) Dev.setBatteries(p, nil, 10) end) },
    })
    n = n + 2 + rows
    ui.buttons(page, n, {
        { T("So_Cold"), function() Env.temperature(-10) end },
        { T("So_ColdOff"), function() Env.temperature(nil) end },
        { T("So_Graphs"), onPanel(Dev.fillGraphs) },
    })
    page.refresh = function()
        local p = Dev.selected()
        local Energy = BU.Energy
        local lines = { panelLine(p), T("So_Sun", ui.num(Energy.sunlight(), 2), ui.num(Env.temperatureNow(), 1)) }
        if p then
            local solar = Dev.units(p, "solar")
            local snow = 0
            for _, unit in ipairs(solar) do snow = math.max(snow, unit.snow or 0) end
            lines[3] = T("So_Panels", ui.num(#solar), ui.num(Energy.output(p), 3), ui.num(snow * 100))
            local bank = Energy.bank(p)
            lines[4] = bank and T("So_BankNow", ui.num(bank.charge * 100), ui.num(bank.capacity, 1), ui.num(bank.usable, 1),
                ui.num(bank.cold * 100), ui.num(bank.weak), ui.num(p.bankFlow or 0, 2)) or T("So_NoBank")
        end
        state:set(lines)
    end
end

-- ---- water ----------------------------------------------------------------------------------------------------------

local function waterPage(page, ui)
    local state = ui.lines(page, 1, 3)
    local units = ui.lines(page, 4, 6, 0.7, 0.85, 1)
    local rows = ui.buttons(page, 11, {
        { T("Wt_Fill", "100"), onPanel(function(p) Dev.setWater(p, 1) end) },
        { T("Wt_Fill", "50"), onPanel(function(p) Dev.setWater(p, 0.5) end) },
        { T("Wt_Fill", "0"), onPanel(function(p) Dev.setWater(p, 0) end) },
        { T("Wt_Group"), onPanel(Dev.addGroup) },
        { T("Wt_Spray"), onPanel(Dev.spray) },
    })
    local n = 11 + rows
    rows = ui.buttons(page, n, {
        { T("Wt_MediaOut"), onPanel(function(p) Dev.filterMedia(p, true) end) },
        { T("Wt_MediaNew"), onPanel(function(p) Dev.filterMedia(p, false) end) },
        { T("Wt_Freeze"), onPanel(function(p) Dev.freeze(p, true) end) },
        { T("Wt_Thaw"), onPanel(function(p) Dev.freeze(p, false) end) },
        { T("Wt_GridOff"), function() Dev.gridWater(false) end },
        { T("Wt_GridOn"), function() Dev.gridWater(true) end },
    })
    ui.hint(page, T("Wt_Hint"), n + rows)
    page.refresh = function()
        local p = Dev.selected()
        local lines = { panelLine(p) }
        local list = {}
        if p then
            local s = BU.Networks.state(p, "water")
            lines[2] = s and T("Wt_State", ui.num(s.amount or 0), ui.num(s.capacity or 0), ui.num(#BU.Water.groups(p)),
                yes(p.water.frozen), yes(s.supplied)) or T("Wt_None")
            lines[3] = T("Wt_Risks", yes(BU.Water.freezeEnabled()), yes(BU.WaterUnits.unpurifiedPipes()),
                yes(BU.Water.aboveOnly()))
            list = Dev.waterLines(p)
            if #list == 0 then list = { T("Wt_NoUnits") } end
        end
        state:set(lines)
        units:set(list)
    end
end

-- ---- devices --------------------------------------------------------------------------------------------------------

local function devicesPage(page, ui)
    local state = ui.lines(page, 1, 1)
    local utility = "power"
    local list = ui.lines(page, 7, 14, 0.8, 0.8, 0.8)
    local function read()
        local p = Dev.selected()
        if not p then list:set({}) return end
        local devices, complete = Dev.devices(p, utility)
        local lines = {}
        for i, device in ipairs(devices) do
            if i > 13 then
                lines[#lines + 1] = T("Dv_More", ui.num(#devices - 13))
                break
            end
            lines[#lines + 1] = Dev.deviceLine(device)
        end
        if #devices == 0 then lines[1] = T("Dv_None") end
        if not complete then lines[#lines + 1] = T("Dv_Incomplete") end
        list:set(lines)
    end
    -- A control that changes the devices reads them again.
    local function change(fn)
        return onPanel(function(p)
            fn(p)
            read()
        end)
    end
    ui.combo(page, ui.PAD, ui.row(2), 140, { { T("Dv_Power"), "power" }, { T("Dv_Water"), "water" } }, function(u)
        utility = u
        read()
    end)
    ui.button(page, T("Dv_Read"), ui.PAD + 150, ui.row(2), 0, read)
    local rows = ui.buttons(page, 3, {
        { T("Dv_ConnectAll"), change(function(p) Dev.connectAll(p, utility, true) end) },
        { T("Dv_DisconnectAll"), change(function(p) Dev.connectAll(p, utility, false) end) },
        { T("Dv_Sync"), change(Dev.syncAttached) },
    })
    ui.buttons(page, 3 + rows, {
        { T("Dv_Night"), change(function(p) Dev.scheduleAll(p, "night") end) },
        { T("Dv_Day"), change(function(p) Dev.scheduleAll(p, "day") end) },
        { T("Dv_Always"), change(function(p) Dev.scheduleAll(p, "always") end) },
    })
    page.refresh = function()
        state:set({ panelLine(Dev.selected()) })
    end
end

-- ---- options --------------------------------------------------------------------------------------------------------

-- The sandbox's options a test turns in play: the features, then the difficulty mechanics and the risks.
local SWITCHES = {
    { "EnablePower", true }, { "EnableWater", true }, { "EnableSolar", true }, { "EnableBatteries", true },
    { "EnablePumps", true }, { "EnableSprinklers", true },
    { "EnableFilters", true }, { "EnableBoosters", true },
    { "SnowOnPanels", true }, { "BatteryColdLock", true }, { "WornBatteryDrain", true }, { "OverloadEnabled", true },
    { "CostsEnabled", true }, { "WaterFromAboveOnly", false }, { "RiskPipesFreeze", false },
    { "RiskPlumbingUnpurified", false },
}

local function optionsPage(page, ui)
    local ticks = {}
    local half = math.ceil(#SWITCHES / 2)
    for i, entry in ipairs(SWITCHES) do
        local name = entry[1]
        local column = i <= half and 0 or 1
        local row = column == 0 and i or i - half
        ticks[i] = ui.tick(page, getText("Sandbox_BuildingUtilities_" .. name), ui.PAD + column * 290, ui.row(row),
            function(on) Dev.setOption("BuildingUtilities." .. name, on) end)
    end
    local n = half + 2
    ui.label(page, getText("Sandbox_BuildingUtilities_WearRate"), ui.PAD, ui.row(n) + 2)
    local _, x = ui.button(page, "x0", ui.PAD + 200, ui.row(n), 40, function() Dev.setOption("BuildingUtilities.WearRate", 0) end)
    _, x = ui.button(page, "x1", x, ui.row(n), 40, function() Dev.setOption("BuildingUtilities.WearRate", 1) end)
    ui.button(page, "x5", x, ui.row(n), 40, function() Dev.setOption("BuildingUtilities.WearRate", 5) end)
    ui.label(page, getText("Sandbox_BuildingUtilities_LossPerWire"), ui.PAD, ui.row(n + 1) + 2)
    _, x = ui.button(page, "0", ui.PAD + 200, ui.row(n + 1), 40, function() Dev.setOption("BuildingUtilities.LossPerWire", 0) end)
    _, x = ui.button(page, "1", x, ui.row(n + 1), 40, function() Dev.setOption("BuildingUtilities.LossPerWire", 1) end)
    ui.button(page, "3", x, ui.row(n + 1), 40, function() Dev.setOption("BuildingUtilities.LossPerWire", 3) end)
    local now = ui.lines(page, n + 2, 1)
    ui.hint(page, T("Op_Hint"), n + 3)
    page.refresh = function()
        for i, entry in ipairs(SWITCHES) do ticks[i]:setSelected(1, Dev.option(entry[1], entry[2]) == true) end
        now:set({ T("Op_Now", ui.num(Dev.option("WearRate", 1), 1), ui.num(Dev.option("LossPerWire", 1), 1)) })
    end
end

PZExtDev.section({ id = "BU", title = T("Section"), order = 20, pages = {
    { id = "Give", title = T("Tab_Give"), build = givePage },
    { id = "Panel", title = T("Tab_Panel"), build = panelPage },
    { id = "Power", title = T("Tab_Power"), build = powerPage },
    { id = "Solar", title = T("Tab_Solar"), build = solarPage },
    { id = "Water", title = T("Tab_Water"), build = waterPage },
    { id = "Devices", title = T("Tab_Devices"), build = devicesPage },
    { id = "Options", title = T("Tab_Options"), build = optionsPage },
} })
