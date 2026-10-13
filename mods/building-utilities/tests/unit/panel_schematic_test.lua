-- The pipes' schematic over the plan (client/BuildingUtilities/PanelSchematic.lua), with the game's panel and the kit
-- stood in for: it lays out a row a floor and a column a pipe, what the mouse finds there, and outlines what it finds.
require "BuildingUtilities/Core"
require "BuildingUtilities/Water"
local BU = BuildingUtilities

local function load()
    ISPanel = { derive = function()
        local c = {}
        c.__index = c
        return c
    end, new = function(self, x, y, w, h) return setmetatable({ x = x, y = y, width = w, height = h }, self) end,
        prerender = function() end }
    BU.PanelUi = { UI = { scaled = function() end }, PALETTE = { inset = { 0, 0, 0 }, text = { 1, 1, 1 },
        dim = { 0.5, 0.5, 0.5 }, bright = { 1, 1, 1 }, dark = { 0, 0, 0 }, border = { 0.3, 0.3, 0.3 },
        bad = { 1, 0, 0 }, value = { 0, 0, 1 } }, FONT_HGT_SMALL = 16 }
    BU.Units = BU.Units or {}
    BU.Units.name = function(unit) return unit.kind end
    local real = require
    require = function(name)
        if name == "ISUI/ISPanel" or name == "PZUIKit/UI" or name == "BuildingUtilities/PanelUi" then return true end
        return real(name)
    end
    local ok, err = pcall(real, "BuildingUtilities/PanelSchematic")
    require = real
    if not ok then error(err, 0) end
end

test("a row a floor, highest first, a column a pipe; the mouse finds a cell, a machine and an arrival", function()
    load()
    local panel = { id = "p1", z = 0, water = { pipes = { { id = 1 }, { id = 2 } } } }
    local outlined = {}
    local window = { outlineRows = function(_, rows) outlined[#outlined + 1] = #rows end }
    local scheme = ISBUSchematic:new(0, 0, 300, 300, window)
    scheme.panel = panel
    scheme.data = { pipes = { 1, 2 }, low = 0, high = 2,
        cells = { [1] = { [1] = { tanks = { { x = 1, y = 1, z = 1 } }, amount = 40, capacity = 100, uses = 1 } },
            [2] = { [1] = { tanks = {}, amount = 0, capacity = 0, uses = 1, dry = true } } },
        machines = { { unit = { kind = "booster" }, kind = "booster", level = 0, inlet = 1, outlet = 2, top = 5 } },
        arrivals = { { pipe = 1, building = "B", level = 4 } } }
    scheme:layout()
    truthy(scheme.rows[2] < scheme.rows[1] and scheme.rows[1] < scheme.rows[0], "the highest floor at the top")
    truthy(scheme.colX[2] > scheme.colX[1])
    local texts = {}
    for _, item in ipairs(scheme.items) do texts[#texts + 1] = item.text end
    local all = table.concat(texts, "|")
    truthy(string.find(all, "IGUI_BU_SchemeTanks", 1, true), "the storage's cell")
    truthy(string.find(all, "IGUI_BU_SchemeDry", 1, true), "the dry cell")
    truthy(string.find(all, "IGUI_BU_SchemeBooster", 1, true), "the booster")
    truthy(string.find(all, "IGUI_BU_SchemeArrival", 1, true), "water from another building")
    for _, item in ipairs(scheme.items) do
        if string.find(item.text, "SchemeTanks", 1, true) then
            scheme:setHover(item)
            eq(outlined[#outlined], 1, "its storage outlined")
        end
    end
    scheme:setHover(nil)
    eq(outlined[#outlined], 0)
end)
