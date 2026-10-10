-- The research tab's layout (client Upgrades/Window): it fits the screens the game runs at, its nodes sit inside their
-- columns without overlapping, and the prerequisite lines start under the rank pips and end on the node they lead to.
-- The game's UI classes are stand-ins: only the file's top level and its layout run.
require "OperationAcorn/Core"
local OA = OperationAcorn

local UI = { "ISPanel", "ISPanelJoypad", "ISButton", "ISToolTip", "ISToolTipInv", "ISModalDialog", "ISContextMenu",
    "ISCharacterInfoWindow", "ISWorldObjectContextMenu", "ISInventoryTransferAction", "ISInventoryPaneContextMenu",
    "ISBaseTimedAction", "ISScrollingListBox", "ISCollapsableWindow" }

local derived = {}
local function stubClass()
    local c = {}
    c.derive = function()
        local d = stubClass()
        derived[#derived + 1] = d
        return d
    end
    return setmetatable(c, { __index = function() return function() end end })
end

-- Loads the tab with the stand-ins; returns its view class.
local function loadWindow()
    for _, name in ipairs(UI) do _G[name] = stubClass() end
    UIFont = setmetatable({}, { __index = function(_, k) return k end })
    getTextManager = function()
        return setmetatable({}, { __index = function() return function() return 16 end end })
    end
    getText = function(key) return key end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or string.find(name, "^XpSystem/") or string.find(name, "^TimedActions/") then
            return true
        end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Window")
    require = real
    if not ok then error(err, 0) end
    for _, class in ipairs(derived) do
        if rawget(class, "tipRows") then return class end
    end
    error("no view class")
end

local View = loadWindow()
local Window = OA.Upgrades.Window
local Data = OA.Upgrades.Data
local L = Window.LAYOUT

local function laidOut(mode)
    local view = setmetatable({ mode = mode }, { __index = View })
    view.boardTabWidth = function() return 100 end
    View.layout(view)
    return view
end

test("the tab fits a 720p screen at its scale (1.25) and a 900p one (1.625), the game's bars with it", function()
    local bars = 50
    truthy(L.VIEW_W * 1.25 <= 1280 and L.VIEW_H * 1.25 + bars <= 720, "720p")
    truthy(L.VIEW_W * 1.625 <= 1600 and L.VIEW_H * 1.625 + bars <= 900, "900p")
    truthy(L.VIEW_W <= 620, "no wider than about 1000 px at 900p (the tab is one of the character window's, not the terminal)")
end)

test("every node sits inside its column's grid, on no other node", function()
    for _, mode in ipairs({ "trees", "board" }) do
        local view = laidOut(mode)
        local nodes = 0
        for _, item in ipairs(view.items) do
            if item.id then
                nodes = nodes + 1
                local inside = false
                for _, panel in ipairs(view.panels) do
                    if item.x >= panel.gx and item.x + item.w <= panel.gx + L.COL_W and item.y >= panel.gy
                        and item.y + item.h + L.PIPS <= panel.gy + L.GRID_H then
                        inside = true
                    end
                end
                truthy(inside, mode .. " " .. item.id .. " inside")
                for _, other in ipairs(view.items) do
                    if other ~= item and other.id then
                        truthy(not (other.x < item.x + item.w and item.x < other.x + other.w
                            and other.y < item.y + item.h and item.y < other.y + other.h), item.id .. " on " .. other.id)
                    end
                end
            end
        end
        local want = 0
        for _, n in ipairs(Data.nodes) do
            if (mode == "board") == (n.board == true) then want = want + 1 end
        end
        eq(nodes, want, mode)
    end
end)

test("a line starts under its prerequisite's pips and ends on the top of its node", function()
    local view = laidOut("trees")
    local byId = {}
    for _, item in ipairs(view.items) do
        if item.id then byId[item.id] = item end
    end
    truthy(#view.lines > 0, "lines")
    for _, line in ipairs(view.lines) do
        local from = byId[line.need[1]]
        local first, last = line.points[1], line.points[#line.points]
        truthy(first[2] >= from.y + from.h + L.PIPS, line.need[1] .. " under its pips")
        local to
        for _, item in pairs(byId) do
            if math.abs(item.x + item.w / 2 - last[1]) < 0.01 and math.abs(item.y - last[2]) < 0.01 then to = item end
        end
        truthy(to ~= nil, line.need[1] .. " ends on a node's top")
    end
end)

test("the buttons sit in the top bar and the bottom bar, inside the tab", function()
    local view = laidOut("trees")
    for _, key in ipairs({ "mode:trees", "mode:board", "clear", "approve", "reset:scout" }) do
        local item = view.byKey[key]
        truthy(item ~= nil, key)
        truthy(item.x >= 0 and item.x + item.w <= L.VIEW_W and item.y >= 0 and item.y + item.h <= L.VIEW_H, key .. " inside")
    end
    truthy(view.byKey.approve.y >= L.PLAN_Y, "approve in the bottom bar")
    truthy(view.byKey.clear.x + view.byKey.clear.w <= view.byKey.approve.x, "clear left of approve")
end)

test("while the tab's question is on the screen nothing is hovered and the tooltip is hidden", function()
    local view = laidOut("trees")
    local shown = true
    view.question = { isVisible = function() return shown end }
    local hidden = 0
    view.tip = { setVisible = function() end, removeFromUIManager = function() hidden = hidden + 1 end }
    view.tipShown = true
    view.sim, view.body = {}, {}
    View.setHover(view, { key = "reset" })
    eq(rawget(view, "hover"), nil, "not hovered under the question")
    View.updateTip(view)
    eq(hidden, 1, "the tooltip taken off")
    shown = false
    View.setHover(view, { key = "reset" })
    eq(rawget(view, "hover"), "reset", "hovered again once the question is gone")
    eq(rawget(view, "question"), nil, "forgotten")
end)

-- ---- with PZ Optimization's retained UI (Trade/UI live) ------------------------------------------------------------

test("what the body paints is the tab's: each change of it is written to the body, which PZ Optimization watches", function()
    local view = laidOut("trees")
    -- (the stand-in class answers a name the view has not set with a function)
    view.body, view.cursor, view.sim = {}, false, false
    view.asking = function() return false end
    view.reachable = function() return true end
    View.setHover(view, view.byKey.approve)
    eq(view.body.rev, 1, "a hover")
    View.setHover(view, view.byKey.approve)
    eq(view.body.rev, 1, "the same hover: nothing")
    view.joypad = true
    View.step(view, 1, 0)
    eq(view.body.rev, 2, "the gamepad's cursor placed")
    View.step(view, 1, 0)
    eq(view.body.rev, 3, "and moved")
    View.onMode(view, { internal = "board" })
    eq(view.body.rev, 4, "the mode")
    eq(view.tipDirty, true, "the tooltip is made again too")
end)

test("the approval stamp is followed each frame before the UI draws: the seal holds still, then fades on time", function()
    local Plan = OA.Upgrades.Plan
    local UI = OA.Trade.UI
    local view = laidOut("trees")
    local body = { view = view, isVisible = function() return true end }
    view.body, view.sim = body, {}
    view.getIsVisible = function() return true end
    local now = 7000000
    getTimestampMs = function() return now end
    local ids = {}
    for _, item in ipairs(view.items) do
        if item.id and #ids < 2 then ids[#ids + 1] = { id = item.id } end
    end
    view.approved = { steps = ids, at = now }
    View.startStamp(view)
    local start = now
    UI.liveFrame()
    eq(body.liveLook, 0, "the first node lights")
    now = start + 300
    UI.liveFrame()
    eq(body.liveLook, 300, "the nodes flash: every frame")
    local hold = Plan.sealAt(2) + Plan.SEAL_MS - Plan.SEAL_FADE_MS
    now = start + hold - 1
    UI.liveFrame()
    eq(body.liveLook, -1, "the seal holds still")
    now = start + hold + 10
    UI.liveFrame()
    eq(body.liveLook, hold + 10, "its fade starts on time")
    now = start + Plan.stampEnd(2)
    UI.liveFrame()
    eq(body.liveLook, nil, "over: let go")
    eq(rawget(view, "stamp"), nil, "and the stamp gone, with no frame drawn")
end)
