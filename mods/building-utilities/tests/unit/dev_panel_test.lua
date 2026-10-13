-- The developer sub-mod (BuildingUtilitiesDev): its "BU" section of the shared debug window (PZExtDev), its pages
-- built on a fake `ui` and refreshed with and without a panel, and the controls that change the panel, the units and
-- the sandbox the way the mod's own changes do.
isDebugEnabled = function() return true end
require "BuildingUtilities/Changes"
local BU = BuildingUtilities
local Store = BU.Store

-- The character, at 10,10,0 with an inventory that keeps what it is given.
local given = {}
local character = {
    getX = function() return 10 end, getY = function() return 10 end, getZ = function() return 0 end,
    getInventory = function()
        return { AddItem = function(_, t) given[#given + 1] = t return nil end }
    end,
}
getPlayer = function() return character end
getItemNameFromFullType = function(t) return t end
getClimateManager = function() return { getDayLightStrength = function() return 0.5 end } end

-- The sandbox's options as the game keeps them: set by name, made into SandboxVars again by toLua.
local options = {}
getSandboxOptions = function()
    return {
        getOptionByName = function(_, name)
            return { asConfigOption = function()
                return { parse = function(_, text) options[name] = text end }
            end }
        end,
        toLua = function()
            SandboxVars.BuildingUtilities = SandboxVars.BuildingUtilities or {}
            for name, text in pairs(options) do
                local short = string.match(name, "^BuildingUtilities%.(.+)$")
                local value = text == "true" or (text ~= "false" and tonumber(text))
                if short then SandboxVars.BuildingUtilities[short] = value else SandboxVars[name] = value end
            end
        end,
    }
end

-- The window takes the section; the test builds its pages itself.
local section
local envCalls = {}
PZExtDev = {
    section = function(def) section = def end,
    Env = {
        time = function(h) envCalls[#envCalls + 1] = "time(" .. h .. ")" end,
        temperature = function(d) envCalls[#envCalls + 1] = "temperature(" .. tostring(d) .. ")" end,
        temperatureNow = function() return 12, false end,
        teleport = function() end,
    },
}
do
    local real = require
    require = function(file)
        if file == "PZExtDev/Panel" then return true end
        return real(file)
    end
    require "BuildingUtilities/Dev/Dev"
    require "BuildingUtilities/Dev/Panel"
    require = real
end
local Dev = BU.Dev

-- ---------------------------------------------------------------------------------------------------------------------
-- A fake `ui`: each control is kept on its page in order, and can be clicked, ticked and chosen.

local function control(page, kind, fields)
    fields.kind = kind
    function fields:setName(name) self.text = name end
    page.controls[#page.controls + 1] = fields
    return fields
end

local ui = { PAD = 10, GAP = 6, W = 600 }
function ui.row(n) return n * 20 end
function ui.num(v, decimals) return string.format("%." .. tostring(decimals or 0) .. "f", v or 0) end
function ui.fit() end
function ui.say() end
function ui.label(page, text) return control(page, "label", { text = text }) end
ui.heading, ui.hint = ui.label, ui.label
function ui.button(page, text, x, _, _, fn)
    return control(page, "button", { text = text, click = function() fn() end }), x + 50
end
function ui.buttons(page, _, list)
    for _, item in ipairs(list) do ui.button(page, item[1], 0, 0, 0, item[2]) end
    return math.ceil(#list / 4)
end
function ui.tick(page, text, _, _, fn)
    local t = control(page, "tick", { text = text, on = false })
    function t:setSelected(_, on) self.on = on end
    function t:tick(on) self.on = on fn(on) end
    return t
end
function ui.combo(page, _, _, _, items, fn)
    local c = control(page, "combo", { items = {}, selected = 1 })
    function c:clear() self.items = {} end
    function c:addOptionWithData(text, data) self.items[#self.items + 1] = { text, data } end
    function c:getSelectedData() return self.items[self.selected] and self.items[self.selected][2] end
    function c:choose(i)
        self.selected = i
        if fn then fn(self.items[i][2]) end
    end
    for _, item in ipairs(items) do c:addOptionWithData(item[1], item[2]) end
    return c
end
function ui.lines(page, _, count)
    local l = control(page, "lines", { count = count, shown = {} })
    function l:set(list) self.shown = list end
    return l
end

local function build(id)
    for _, def in ipairs(section.pages) do
        if def.id == id then
            local page = { controls = {} }
            def.build(page, ui)
            return page
        end
    end
    error("no page " .. id)
end

local function find(page, kind, text)
    for _, c in ipairs(page.controls) do
        if c.kind == kind and c.text == text then return c end
    end
    error("no " .. kind .. " " .. text)
end

local function firstLines(page)
    for _, c in ipairs(page.controls) do
        if c.kind == "lines" then return c.shown end
    end
end

local PAGES = { "Give", "Panel", "Power", "Solar", "Water", "Devices", "Options" }

test("the BU section: seven pages in order, each built and refreshed without a panel", function()
    eq(section.id, "BU")
    local ids = {}
    for _, def in ipairs(section.pages) do ids[#ids + 1] = def.id end
    eq(table.concat(ids, " "), table.concat(PAGES, " "))
    for _, id in ipairs(PAGES) do
        local page = build(id)
        if page.refresh then page.refresh() end
        if id ~= "Give" and id ~= "Options" then
            eq(firstLines(page)[1], "IGUI_BUDev_NoPanel 60", id .. " says there is no panel")
        end
    end
end)

test("with a panel near, every page refreshes on it, and a far one is not taken", function()
    local panel = Store.newPanel(12, 10, 0, BU.panelSprite("S"))
    for _, id in ipairs(PAGES) do
        local page = build(id)
        if page.refresh then page.refresh() end
        if id ~= "Give" and id ~= "Options" then
            truthy(string.find(firstLines(page)[1], "#" .. tostring(panel.id), 1, true), id .. ": " .. tostring(firstLines(page)[1]))
        end
    end
    panel.x = 500
    eq(Dev.selected(), nil, "beyond the reach")
end)

test("panel page: tier, breaker, main switch and overload change the panel", function()
    local panel = Store.newPanel(12, 10, 0, BU.panelSprite("S"))
    local page = build("Panel")
    find(page, "button", "IGUI_BUDev_Pn_TierN 3"):click()
    eq(panel.tier, 3)
    find(page, "button", "IGUI_BUDev_Pn_Trip"):click()
    eq(panel.tripped, true)
    find(page, "button", "IGUI_BUDev_Pn_Reset"):click()
    eq(panel.tripped, false)
    find(page, "button", "IGUI_BUDev_Pn_SwitchOff"):click()
    eq(panel.switchedOff, true)
    find(page, "button", "IGUI_BUDev_Pn_Overload"):click()
    eq(Dev.overloaded(panel), true)
    find(page, "button", "IGUI_BUDev_Pn_OverloadOff"):click()
    eq(Dev.overloaded(panel), false)
    find(page, "button", "IGUI_BUDev_Pn_LogClear"):click()
    eq(#panel.log, 0)
end)

test("panel page: a panel chosen from the list is used even when another is nearer", function()
    local near = Store.newPanel(11, 10, 0, BU.panelSprite("S"))
    local far = Store.newPanel(40, 10, 0, BU.panelSprite("S"))
    local page = build("Panel")
    local list
    for _, c in ipairs(page.controls) do if c.kind == "combo" then list = c end end
    eq(#list.items, 2)
    list.selected = 2
    find(page, "button", "IGUI_BUDev_Pn_Choose"):click()
    eq(Dev.selected(), far)
    find(page, "button", "IGUI_BUDev_Pn_Nearest"):click()
    eq(Dev.selected(), near)
end)

test("solar page: snow on the panels and off, the clock and the cold", function()
    local panel = Store.newPanel(12, 10, 0, BU.panelSprite("S"))
    local unit = Store.newUnit("solar", 13, 10, 0, "x")
    unit.panel = panel.id
    local page = build("Solar")
    find(page, "button", "IGUI_BUDev_So_Snow 100"):click()
    eq(unit.snow, 1)
    find(page, "button", "IGUI_BUDev_So_SnowClear"):click()
    eq(unit.snow, nil)
    find(page, "button", "IGUI_BUDev_So_TwoAm"):click()
    find(page, "button", "IGUI_BUDev_So_Cold"):click()
    find(page, "button", "IGUI_BUDev_So_ColdOff"):click()
    eq(table.concat(envCalls, " "), "time(2) temperature(-10) temperature(nil)")
    find(page, "button", "IGUI_BUDev_So_Graphs"):click()
    eq(#panel.energyLog, Store.ENERGY_HOURS)
end)

test("water page: filter media used up and new", function()
    local panel = Store.newPanel(12, 10, 0, BU.panelSprite("S"))
    local unit = Store.newUnit("filter", 13, 10, 0, "x")
    unit.panel = panel.id
    local page = build("Water")
    find(page, "button", "IGUI_BUDev_Wt_MediaOut"):click()
    eq(unit.media, 0)
    find(page, "button", "IGUI_BUDev_Wt_MediaNew"):click()
    eq(unit.media, BU.WaterUnits.FILTER_HOURS)
end)

test("options page: a feature off and the wear rate go to the sandbox, and the ticks follow it", function()
    local page = build("Options")
    find(page, "tick", "Sandbox_BuildingUtilities_EnableSolar"):tick(false)
    eq(BU.enabled("solar"), false)
    find(page, "button", "x5"):click()
    eq(BU.sandbox("WearRate", 1), 5)
    find(page, "tick", "Sandbox_BuildingUtilities_RiskPipesFreeze"):tick(true)
    page.refresh()
    eq(find(page, "tick", "Sandbox_BuildingUtilities_EnableSolar").on, false)
    eq(find(page, "tick", "Sandbox_BuildingUtilities_RiskPipesFreeze").on, true)
    eq(find(page, "tick", "Sandbox_BuildingUtilities_EnablePower").on, true)
end)

test("give page: an item by its name, and lines cost nothing", function()
    local page = build("Give")
    find(page, "button", "BuildingUtilities.SolarPanel x4"):click()
    eq(#given, 4)
    find(page, "tick", "IGUI_BUDev_Gv_Free"):tick(true)
    eq(BU.costsEnabled(), false)
end)
