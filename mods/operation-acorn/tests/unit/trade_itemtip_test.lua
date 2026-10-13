-- The item tooltip's extra lines as the client draws them: the strips' places, colours and texts, that they follow what
-- the appraisal took, and that nothing is drawn (and nothing breaks) when there is nothing to say. The game's tooltip
-- panel and the item are fakes.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/ItemTip"
require "OperationAcorn/Story/View"
local OA = OperationAcorn
local View = OA.StoryView
-- The request lines here are by item type: no generated groups.
OA.Requests.useGroups({})

local calls
local panel, original

local function setup()
    calls = {}
    UIFont = { Small = "Small" }
    OA.Trade.UI = { fontHeightPx = function() return 14 end, textWidthPx = function(text) return #text * 6 end }
    ISContextMenu = { instance = nil }
    getCore = function() return { getScreenHeight = function() return 1080 end } end
    original = function(self)
        calls[#calls + 1] = "panel"
        self.sawAbove, self.sawBelow = self.oaAbove, self.oaBelow
        if self.appraisalBelow then self.oaBelow = self.appraisalBelow end
    end
    ISToolTipInv = { render = original }
    local record = OA.Store.ensure("p1", "P")
    record.trade = { stage = 3, milestones = 0, serial = 1, levels = {} }
    record.codex = { kinds = { Pen = true }, req = { week = 5, items = { "Base.Pencil" }, used = { ["Base.Pencil"] = 6 },
        band = { ["Base.Pencil"] = "common" }, qty = { ["Base.Pencil"] = 10 } } }
    OA.Requests.install({ version = 1, types = { "Base.Pencil" }, score = { 2 }, kinds = {}, total = {}, n = 1 })
    getPlayer = function() return { getModData = function() return { OA_Id = "p1" } end } end
    getScriptManager = function() return { FindItem = function() return nil end } end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/UI" or name == "OperationAcorn/Trade/Appraisal" then
            return true
        end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Trade/ItemTip")
    require = real
    if not ok then error(err, 0) end
    local function record_(kind)
        return function(self, ...) calls[#calls + 1] = { kind, ... } end
    end
    panel = { width = 200, height = 80, y = 300, backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 },
        borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 } }
    panel.getY = function() return panel.y end
    panel.isVisible = function() return true end
    panel.drawRect = record_("rect")
    panel.drawRectBorder = record_("border")
    panel.drawText = record_("text")
    return record
end

local function item(fullType, data)
    return { getFullType = function() return fullType end, hasModData = function() return data ~= nil end,
        getModData = function() return data end }
end

local function render(it)
    panel.item = it
    ISToolTipInv.render(panel)
end

local function texts()
    local list = {}
    for _, c in ipairs(calls) do
        if type(c) == "table" and c[1] == "text" then list[#list + 1] = c end
    end
    return list
end

test("a requested item gets an amber strip under the tooltip, drawn after the game's own panel", function()
    setup()
    panel.width = 400
    render(item("Base.Pencil"))
    eq(calls[1], "panel")
    eq(#texts(), 1)
    local t = texts()[1]
    eq(t[2], "IGUI_OA_ItemTip_Request 600 6 10")
    eq(t[3], 8)
    eq(t[4], 79 + 4, "inside the strip, which starts a pixel up into the panel's border")
    near(t[5], 1.0, 1e-9)
    near(t[6], 0.82, 1e-9)
    near(t[7], 0.35, 1e-9)
    local rect = calls[2]
    eq(rect[1], "rect")
    eq(rect[3], 79)
    eq(rect[4], 400, "as wide as the panel when the line is shorter")
    eq(rect[5], 14 + 8)
    eq(rect[6], 0.5, "the panel's own background alpha")
end)

test("a strip is as wide as its line", function()
    setup()
    panel.width = 100
    render(item("Base.Pencil"))
    eq(calls[2][4], #"IGUI_OA_ItemTip_Request 600 6 10" * 6 + 16)
end)

test("a kind not seen before has a green line, and an item of the codex has none", function()
    setup()
    getScriptManager = function()
        return { FindItem = function(_, t)
            return { getFullName = function() return t end, getActualWeight = function() return 0.1 end,
                getDisplayCategory = function() return "Junk" end, isItemType = function() return false end }
        end }
    end
    ItemType = { MOVEABLE = 1 }
    render(item("Base.Ring"))
    eq(texts()[1][2], "IGUI_OA_ItemTip_New")
    near(texts()[1][5], 0.55, 1e-9)
    calls = {}
    render(item("Base.Pen"))
    eq(#texts(), 0, "Pen is in the codex")
    eq(#calls, 1, "only the game's panel")
end)

test("a mission item's first line is in the mission's colour, above the tooltip", function()
    local record = setup()
    record.missions = { active = { id = "M1-1", kind = "regular", state = "open", items = {} } }
    render(item("OperationAcorn.MissionFilterCase", { OA_Mission = "M1-1" }))
    eq(#texts(), 1)
    local t = texts()[1]
    eq(t[2], "IGUI_OA_ItemTip_Mission")
    eq(t[4], -(14 + 8) + 1 + 4)
    near(t[5], 0.30, 1e-9)
    record.missions.active.kind = "story"
    calls = {}
    render(item("OperationAcorn.EvidenceEnvelope", { OA_Mission = "M1-1#A" }))
    near(texts()[1][5], 0.55, 1e-9)
    near(texts()[1][7], 1.0, 1e-9)
end)

test("an item of another mission, or with no mark, has no mission line", function()
    local record = setup()
    record.missions = { active = { id = "M1-1", kind = "regular", state = "open", items = {} } }
    render(item("Base.Thing", { OA_Mission = "M9-9" }))
    eq(#texts(), 0)
    render(item("Base.Thing", { Other = 1 }))
    eq(#texts(), 0)
end)

test("a mission item that is requested too has both strips", function()
    local record = setup()
    record.missions = { active = { id = "M1-1", kind = "regular", state = "open", items = {} } }
    render(item("Base.Pencil", { OA_Mission = "M1-1" }))
    local list = texts()
    eq(#list, 2)
    eq(list[1][2], "IGUI_OA_ItemTip_Mission", "the mission's strip is drawn first, above")
    eq(list[2][2], "IGUI_OA_ItemTip_Request 600 6 10")
end)

test("the strips come after what the appraisal took, which the panel is told is nothing first", function()
    setup()
    panel.oaBelow = 99
    panel.appraisalBelow = 26
    render(item("Base.Pencil"))
    eq(panel.sawBelow, 0, "the appraisal starts from nothing each frame")
    eq(texts()[1][4], 79 + 26 + 4)
end)

test("at the bottom of the screen the strip goes above the panel", function()
    setup()
    panel.y = 990
    render(item("Base.Pencil"))
    eq(texts()[1][4], -(14 + 8) + 1 + 4)
end)

test("nothing is drawn while a context menu is up or the panel is hidden", function()
    setup()
    ISContextMenu.instance = { visibleCheck = true }
    render(item("Base.Pencil"))
    eq(#texts(), 0)
    ISContextMenu.instance = nil
    panel.isVisible = function() return false end
    render(item("Base.Pencil"))
    eq(#texts(), 0)
    panel.item = nil
    panel.isVisible = function() return true end
    ISToolTipInv.render(panel)
    eq(#texts(), 0)
end)

test("a record that is not there draws nothing, and a failure does not stop the tooltip", function()
    setup()
    getPlayer = function() return nil end
    render(item("Base.Pencil"))
    eq(#texts(), 0)
    getPlayer = function() error("boom") end
    render(item("Base.Pencil"))
    render(item("Base.Pencil"))
    eq(#texts(), 0)
    eq(calls[#calls], "panel", "the game's tooltip was drawn each time")
end)
