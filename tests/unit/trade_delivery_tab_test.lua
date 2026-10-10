-- The delivery tab (client Trade/TabDelivery): what it works out from the record and the market, the layout at the two
-- window sizes, and what it draws. The game's UI classes are stand-ins that record what is drawn.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Terminal"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Requests"
local OA = OperationAcorn

-- A panel that remembers what it was told to draw.
local DRAWS = { "drawRect", "drawRectBorder", "drawText", "drawTextRight", "drawTextCentre", "drawTextureScaledAspect" }
local function stubPanel()
    local c = {}
    c.__index = c
    function c:derive() local d = stubPanel(); setmetatable(d, { __index = c }); return d end
    function c:new(x, y, w, h, window)
        local o = setmetatable({ x = x, y = y, width = w, height = h, window = window, drawn = {}, children = {}, items = {} }, self)
        return o
    end
    for _, fn in ipairs(DRAWS) do c[fn] = function(self, ...) self.drawn[#self.drawn + 1] = { fn, ... } end end
    function c:getWidth() return self.width end
    function c:getHeight() return self.height end
    function c:setWidth(w) self.width = w end
    function c:setHeight(h) self.height = h end
    function c:setY(y) self.y = y end
    function c:setVisible(v) self.visible = v end
    function c:addChild(child) self.children[#self.children + 1] = child end
    function c:initialise() end
    function c:instantiate() end
    function c:isMouseOver() return self.over or false end
    function c:getMouseX() return self.mx or 0 end
    function c:getMouseY() return self.my or 0 end
    function c:getX() return self.x end
    function c:getY() return self.y end
    function c:palette() return self.window.palette end
    function c:record() return self.window.record end
    function c:addItem(name, item) self.items[#self.items + 1] = { text = name, item = item, height = self.itemheight } end
    function c:clear() self.items = {} end
    return c
end

local function texts(el)
    local t = {}
    for _, d in ipairs(el.drawn) do
        if d[1] == "drawText" or d[1] == "drawTextRight" or d[1] == "drawTextCentre" then t[#t + 1] = d[2] end
    end
    return table.concat(t, "|")
end

-- Loads the tab with the UI stand-ins; returns the class.
local loaded
local function load()
    if loaded then return OATabDelivery end
    local real = require
    local panel = stubPanel()
    OATab = panel
    ISPanel, ISScrollingListBox = panel, panel
    for _, name in ipairs({ "ISButton", "ISLabel", "ISRichTextPanel", "ISModalDialog", "ISContextMenu" }) do
        _G[name] = stubPanel()
    end
    UIFont = { Small = "Small", Medium = "Medium", Code = "Code" }
    getTextManager = function()
        return { getFontHeight = function() return 16 end, MeasureStringX = function(_, font, text) return #tostring(text) * 7 end }
    end
    getScriptManager = function() return { FindItem = function() return nil end } end
    getItemNameFromFullType = function(fullType) return "name of " .. fullType end
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/TerminalWindow" then return true end
        return real(name)
    end
    local ok, err = pcall(function()
        real("OperationAcorn/Trade/UI")
        real("OperationAcorn/Trade/TabDelivery")
    end)
    require = real
    if not ok then error(err, 0) end
    loaded = true
    return OATabDelivery
end

-- A world with a request table, a record at a stage, and a market stepped to the first day.
local function world(stage)
    local data = { version = 1, types = {}, score = {}, kinds = {}, total = {}, n = 30 }
    for i = 1, 30 do
        data.types[i] = "Base.Item" .. i
        data.score[i] = i <= 10 and 2.0 or (i <= 20 and 0.5 or 0.1)
        data.kinds["Item" .. i] = (i % 2 == 0) and "A" or "B"
    end
    OA.Requests.install(data)
    OA.randomFloat = function() return 0 end
    OA.random = function(a, b) return a end
    OA.Market.update(OA.day())
    local record = OA.Store.ensure("p", "P")
    OA.Store.section(record, "trade").stage = stage or 0
    -- The week's lines as drawn, each kept at 10 units (the table's rank would ask 5 to 20).
    OA.Requests.list(record)
    for key in pairs(record.codex.req.qty) do record.codex.req.qty[key] = 10 end
    return record
end

local function openTab(record, tier, w, h)
    local Tab = load()
    local UI = OA.Trade.UI
    local window = { palette = UI.palette(tier or "crude"), record = record, tier = tier or "crude" }
    local tab = Tab:new(0, 0, w or 700, h or 408, window)
    tab:createChildren()
    tab:refresh()
    return tab
end

test("the tab shows the week's list: six rows at the start, each with its band, price, quantity and trust", function()
    local record = world(0)
    local tab = openTab(record)
    local d = tab.data
    eq(#d.rows, 6)
    eq(#tab.list.items, 6)
    eq(d.head, "IGUI_OA_Terminal_Del_Head 6")
    eq(d.price, OA.Trade.Text.TIMES .. "1.0")
    for _, row in ipairs(d.rows) do
        eq(row.band, "common", "only the common items at the start")
        eq(row.price, "600"); eq(row.qty, 10); eq(row.trust, "+5"); eq(row.progress, "0/10")
        eq(row.full, false); eq(row.sealed, 0)
    end
    truthy(string.find(d.refresh, "IGUI_OA_Terminal_Del_Refresh"), "the days to the new list")
end)

test("the header's multiplier and the prices follow the request price upgrade", function()
    local record = world(5)
    OA.Support.setLevel(record, "reqprice", 3)
    OA.Support.setLevel(record, "reqcount", 3)
    local tab = openTab(record)
    eq(tab.data.price, OA.Trade.Text.TIMES .. "1.33")
    eq(#tab.data.rows, 12)
    local prices = {}
    for _, row in ipairs(tab.data.rows) do prices[row.band] = row.price end
    eq(prices.common, "800")
    if prices.normal then eq(prices.normal, "2,000") end
    if prices.rare then eq(prices.rare, "5,330") end
end)

test("the bar counts what the week settled and shows what the sealed boxes hold lightly", function()
    local record = world(0)
    local tab0 = openTab(record)
    local item = tab0.data.rows[1].key
    OA.Requests.consume(record, item, 4)
    local Boxes = OA.Trade.Boxes
    local box = Boxes.add(record, { x = 1, y = 1, z = 0 })
    Boxes.seal(record, box.id, { { info = { fullType = item, baseType = OA.Categories.baseType(item), weight = 0.1,
        displayCategory = "Junk" }, count = 3 } })
    local tab = openTab(record)
    local row
    for _, r in ipairs(tab.data.rows) do if r.key == item then row = r end end
    eq(row.progress, "4/10"); eq(row.sealed, 3)
    truthy(tab.data.expect and string.find(tab.data.expect, "IGUI_OA_Terminal_Del_Expect", 1, true),
        "the settlement the sealed boxes make")
    OA.Requests.consume(record, item, 3)
    tab = openTab(record)
    truthy(string.find(tab.data.expect, "ExpectFull", 1, true), "7 settled and 3 sealed fill the line")
end)

test("a sealed box that fills a line adds the trust to the expected settlement", function()
    local record = world(0)
    local tab0 = openTab(record)
    local item = tab0.data.rows[1].key
    local Boxes = OA.Trade.Boxes
    local box = Boxes.add(record, { x = 1, y = 1, z = 0 })
    Boxes.seal(record, box.id, { { info = { fullType = item, baseType = OA.Categories.baseType(item), weight = 0.1,
        displayCategory = "Junk" }, count = 12 } })
    local tab = openTab(record)
    truthy(string.find(tab.data.expect, "ExpectFull", 1, true), tab.data.expect)
    truthy(string.find(tab.data.expect, "6,000", 1, true), "10 at 600")
end)

test("a full line is marked done and dim, and still drawn", function()
    local record = world(0)
    local tab0 = openTab(record)
    local item = tab0.data.rows[1].key
    OA.Requests.consume(record, item, 10)
    local tab = openTab(record)
    local row
    for _, r in ipairs(tab.data.rows) do if r.key == item then row = r end end
    eq(row.full, true)
    local list = tab.list
    list.drawn = {}
    OATabDelivery.drawRow(list, 0, { item = row, height = 26 }, false)
    local all = texts(list)
    truthy(string.find(all, "IGUI_OA_Terminal_Del_DoneShort", 1, true), all)
    truthy(string.find(all, "10/10", 1, true))
end)

test("the situation lines come from the market: raises, a glut, a refusal, and none when quiet", function()
    local record = world(0)
    local quiet = openTab(record)
    eq(#quiet.data.sit, 1)
    eq(quiet.data.sit[1].text, "IGUI_OA_Terminal_Del_SitNone")
    OA.Market.addEvent("B", 1.5, 10, "IGUI_OA_Econ_Event_FilterSamples", "story")
    OA.Market.addEvent("I", 1.25, 5, "IGUI_OA_Econ_Season_summer_I_1")
    OA.Market.addEvent("A", 0.8, 5, "IGUI_OA_Econ_Event_Glut")
    OA.Market.state().refused.F = OA.Market.state().day + 4
    local tab = openTab(record)
    local sit = tab.data.sit
    eq(#sit, 4)
    eq(sit[1].text, "IGUI_OA_Econ_Event_FilterSamples IGUI_OA_Econ_Cat_B"); eq(sit[1].kind, "good")
    eq(sit[1].mult, "IGUI_OA_Terminal_Del_SitMult 1.5"); eq(sit[1].left, "IGUI_OA_Terminal_Del_SitLeft 10")
    eq(sit[2].text, "IGUI_OA_Econ_Season_summer_I_1", "a season line names no category")
    eq(sit[3].kind, "bad"); eq(sit[3].mult, "IGUI_OA_Terminal_Del_SitMult 0.8")
    eq(sit[4].text, "IGUI_OA_Econ_Event_Refusal IGUI_OA_Econ_Cat_F"); eq(sit[4].mult, nil)
    eq(tab.data.sitHead, "IGUI_OA_Terminal_Del_Sit IGUI_OA_Econ_SeasonName_summer", "July: summer")
    TEST.month = 0
    eq(openTab(record).data.sitHead, "IGUI_OA_Terminal_Del_Sit IGUI_OA_Econ_SeasonName_winter")
end)

test("more events than the panel shows are counted", function()
    local record = world(0)
    for i, c in ipairs({ "A", "B", "C", "D", "E", "F", "G" }) do OA.Market.addEvent(c, 1.3, 5, "IGUI_OA_Econ_Event_Demand") end
    local tab = openTab(record)
    local sit = tab.data.sit
    eq(#sit, OATabDelivery.SIT_MAX)
    eq(sit[#sit].text, "IGUI_OA_Terminal_Del_SitMore 3", "7 lines, 4 shown, 3 counted")
end)

test("the index chips: 11 categories, high and low marked, a refused one off, arrows only with the upgrade", function()
    local record = world(0)
    local st = OA.Market.state()
    st.M.A = 1.3; st.M.B = 0.7
    OA.Market.state().refused.C = st.day + 3
    local chips = openTab(record).data.chips
    eq(#chips, 11)
    eq(chips[1].kind, "hi"); eq(chips[1].value, "1.30")
    eq(chips[2].kind, "lo")
    eq(chips[3].kind, "off")
    eq(chips[4].kind, "mid"); eq(chips[4].value, "1.00")
    eq(chips[1].trend, nil, "no forecast without the upgrade")
    truthy(string.find(chips[1].tip, "IGUI_OA_Econ_Cat_A", 1, true))
    OA.Support.setLevel(record, "forecast", 1)
    chips = openTab(record).data.chips
    eq(chips[1].trend, "down", "M falls back toward 1")
    eq(chips[2].trend, "up")
end)

test("it draws without a failure at the default and the smallest size, in both palettes", function()
    for _, tier in ipairs({ "crude", "field" }) do
        for _, size in ipairs({ { 700, 408 }, { 580, 348 } }) do
            local record = world(3)
            OA.Market.addEvent("B", 1.5, 10, "IGUI_OA_Econ_Event_FilterSamples", "story")
            local tab = openTab(record, tier, size[1], size[2])
            tab:prerender()
            local all = texts(tab)
            truthy(string.find(all, "IGUI_OA_Terminal_Del_Col_Item", 1, true), "column heads")
            truthy(string.find(all, "IGUI_OA_Terminal_Del_Sit", 1, true), "the situation panel")
            truthy(string.find(all, "IGUI_OA_Econ_CatShort_A", 1, true), "the chips")
            local m = tab.metrics
            truthy(m.sitY + m.sitH <= size[2], "the panel is inside the tab")
            truthy(tab.list.y + tab.list.height <= m.noteY, "the list is above the note")
            truthy(tab.list.height >= 52, "at least two rows stay")
            truthy(m.noteY + 16 <= m.sitY, "the note is above the panel: " .. m.noteY .. " / " .. m.sitY)
            for _, item in ipairs(tab.list.items) do
                tab.list.drawn = {}
                OATabDelivery.drawRow(tab.list, 0, { item = item.item, height = 26 }, true)
                truthy(#tab.list.drawn > 5)
            end
        end
    end
end)

test("a window resized later lays the tab out again", function()
    local record = world(3)
    local tab = openTab(record, "crude", 700, 408)
    local wide = tab.metrics.BW
    tab.width, tab.height = 580, 348
    tab:prerender()
    truthy(tab.metrics.BW < wide, "the bar is narrower")
    eq(tab.metrics.narrow, true)
    truthy(tab.metrics.sitY + tab.metrics.sitH <= 348)
end)

test("a chip under the mouse draws its tip", function()
    local record = world(0)
    local tab = openTab(record)
    tab:prerender()
    local r = tab.data.chipRects[2]
    tab.over, tab.mx, tab.my = true, r.x + 3, tab.metrics.sitY + r.y + 3
    tab.drawn = {}
    tab:render()
    truthy(string.find(texts(tab), "IGUI_OA_Terminal_Del_ChipTip", 1, true), "the tip")
    tab.drawn = {}
    tab.mx = 0
    tab:render()
    eq(texts(tab), "", "nothing off the chips")
end)

test("a group's row shows the group's name and picture, and the mouse over it lists what it takes", function()
    OA.Requests.useGroups({ { id = "base:charcoal", score = 2, wt = 0.8, dc = "Material",
        items = { "Base.Charcoal", "Base.Coke", "Base.CharcoalCrafted" } } })
    OA.Requests.install(OA.Requests.build({}, function() return nil end, OA.RequestGroups))
    local record = OA.Store.ensure("p", "P")
    local Tab = load()
    local names = { ["Base.Charcoal"] = "Charcoal", ["Base.Coke"] = "Coke", ["Base.CharcoalCrafted"] = "Wood Charcoal" }
    getItemNameFromFullType = function(t) return names[t] or t end
    getScriptManager = function() return { FindItem = function() return nil end } end
    local window = { palette = OA.Trade.UI.palette("crude"), record = record, tier = "crude" }
    local tab = Tab:new(0, 0, 700, 408, window)
    tab:createChildren()
    tab:refresh()
    local row = tab.data.rows[1]
    eq(row.key, "base:charcoal")
    eq(row.name, "Charcoal", "the group's name, not one kind's")
    eq(row.itemType, "Base.Charcoal", "its picture is the first kind's")
    tab:prerender()
    tab.list.over, tab.list.mouseoverselected, tab.list.mx, tab.list.my = true, 1, 40, 10
    tab.drawn = {}
    tab:render()
    local drawn = texts(tab)
    truthy(string.find(drawn, "IGUI_OA_Terminal_Del_Takes", 1, true), "the tip's head")
    truthy(string.find(drawn, "Wood Charcoal", 1, true), "the kiln's charcoal is named")
    truthy(string.find(drawn, "Coke", 1, true))
    tab.list.over = false
    tab.drawn = {}
    tab:render()
    eq(texts(tab), "", "nothing when the mouse is off the list")
end)

test("a group whose dearer kind fetches its own worth shows the cheapest price with a plus, the range in the tip", function()
    OA.Requests.useGroups({ { id = "sets", score = 2, wt = 10, dc = "Electronics", items = { "Base.RadioX", "Base.TvX" } } })
    OA.Requests.install(OA.Requests.build({}, function() return nil end, OA.RequestGroups))
    local record = OA.Store.ensure("p", "P")
    local Tab = load()
    getItemNameFromFullType = function(t) return t end
    ItemType = ItemType or { MOVEABLE = 1 }
    local weight = { ["Base.RadioX"] = 0.5, ["Base.TvX"] = 10 }
    getScriptManager = function()
        return { FindItem = function(_, t)
            if not weight[t] then return nil end
            return { getFullName = function() return t end, getActualWeight = function() return weight[t] end,
                getDisplayCategory = function() return "Electronics" end, isItemType = function() return false end,
                getNormalTexture = function() return nil end }
        end }
    end
    OA.Requests.forget()
    local window = { palette = OA.Trade.UI.palette("crude"), record = record, tier = "crude" }
    local tab = Tab:new(0, 0, 700, 408, window)
    tab:createChildren()
    tab:refresh()
    local row = tab.data.rows[1]
    eq(row.key, "sets")
    eq(row.price, "600+", "the radio fetches the band's 600; the television more")
    eq(row.tip[#row.tip], "IGUI_OA_Terminal_Del_TakesPrices 600 6,000")
    OA.Requests.forget()
end)

test("the day moving on, or an event, refreshes the tab", function()
    local record = world(0)
    local tab = openTab(record)
    local refreshed = 0
    local original = tab.refresh
    tab.refresh = function(self) refreshed = refreshed + 1; return original(self) end
    for _ = 1, OATabDelivery.WATCH + 1 do tab:update() end
    eq(refreshed, 0, "nothing changed")
    OA.Market.addEvent("D", 1.3, 3, "IGUI_OA_Econ_Event_Demand")
    for _ = 1, OATabDelivery.WATCH do tab:update() end
    eq(refreshed, 1, "an event began")
    TEST.hours = 24 * 3
    for _ = 1, OATabDelivery.WATCH do tab:update() end
    eq(refreshed, 2, "a new day")
end)

test("the tab's dot: a new week's list, or an event not seen; looking clears both", function()
    local record = world(0)
    openTab(record)
    local Terminal = OA.Terminal
    local tab = Terminal.tab("delivery")
    truthy(tab, "the tab is registered")
    eq(Terminal.mark("delivery", record), "new", "the first list is not seen")
    for _, pair in ipairs(Terminal.seenPairs("delivery", record)) do Terminal.setSeen(record, pair.key, pair.value) end
    eq(Terminal.mark("delivery", record), nil)
    OA.Market.addEvent("D", 1.3, 3, "IGUI_OA_Econ_Event_Demand")
    eq(Terminal.mark("delivery", record), "new", "an event began")
    for _, pair in ipairs(Terminal.seenPairs("delivery", record)) do Terminal.setSeen(record, pair.key, pair.value) end
    eq(Terminal.mark("delivery", record), nil)
    TEST.hours = 24 * 8
    eq(Terminal.mark("delivery", record), "new", "a new week")
end)
