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
    -- (the tab's own methods only: the stand-in class would answer a name the tab has not set, such as what moves by
    -- the clock while nothing does, with a function)
    local view = setmetatable({ mode = mode, t0 = 0 }, { __index = function(_, k) return rawget(View, k) end })
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
    eq(view.stamp, nil, "and the stamp gone, with no frame drawn")
end)

-- ---- motion (Motion.lua's timing, followed by View.tick) -----------------------------------------------------------

-- A shown body for the tab and the flow over it, both in a shown tab, and a clock the test moves.
local clock = { now = 9000000 }
local function shown(view)
    local function on() return true end
    view.isVisible = on
    local body = { view = view, isVisible = on, parent = view }
    local flow = { view = view, isVisible = on, parent = view }
    view.body, view.flow = body, flow
    getTimestampMs = function() return clock.now end
    return body, flow
end

-- A tab on a section of the upgrades, its refresh done here (no player): the selection simulated, the states worked
-- out.
local function onSection(u)
    local Plan = OA.Upgrades.Plan
    local view = laidOut("trees")
    view.u, view.steps, view.fragments = u, {}, 0
    view.refresh = function(v)
        local sim, kept = Plan.simulate(v.u, v.steps, 0)
        v.sim, v.steps, v.counts, v.fragmentsLeft, v.revealed = sim, kept, Plan.counts(kept), 0, {}
        v.spentPlan = Plan.spent(v.u, sim)
        View.workOut(v)
    end
    view:refresh()
    return view
end

-- A section with the scout tree opened and points to spend in it.
local function scoutSection()
    local Rules = OA.Upgrades.Rules
    local u = Rules.blank()
    for _ = 1, 8 do Rules.inject(u, "scout") end
    return u
end

-- Ranks of the scout tree's row 1 nodes that need nothing, as many as it takes to open row 2.
local function rowTwoSteps()
    local picks = {}
    for _, node in ipairs(Data.treeNodes("scout")) do
        if node.row == 1 and #node.req == 0 then
            for _ = 1, node.ranks do picks[#picks + 1] = node.id end
        end
    end
    local out = {}
    for i = 1, Data.ROW_COST[2] do out[i] = picks[i] end
    return out
end

local function rowOf(id) return Data.byId[id].row end

test("a line knows its number and its length, which time the light that runs down it", function()
    local view = laidOut("trees")
    for i, line in ipairs(view.lines) do
        eq(line.index, i)
        local len = 0
        for k = 2, #line.points do
            local a, b = line.points[k - 1], line.points[k]
            len = len + math.abs(b[1] - a[1]) + math.abs(b[2] - a[2])
        end
        near(line.len, len, 1e-6, "line " .. i)
        truthy(line.len > 0)
    end
end)

test("a raised rank pops its node; the row it opens loses its padlocks just behind the pop", function()
    local Motion = OA.Upgrades.Motion
    local view = onSection(scoutSection())
    shown(view)
    local steps = rowTwoSteps()
    for i = 1, #steps - 1 do View.plan(view, steps[i]) end
    eq(view.unlocks, nil, "row 2 not open yet: nothing comes off")
    clock.now = clock.now + 1000
    local last = steps[#steps]
    View.plan(view, last)
    local fx = view.fx[last]
    eq(fx.kind, "pop")
    eq(fx.start, clock.now)
    eq(fx.ms, Motion.fxMs("pop"))
    local ranks = 0
    for _, id in ipairs(steps) do
        if id == last then ranks = ranks + 1 end
    end
    eq(fx.pip, ranks, "the pip just selected flashes")
    eq(view.bump.tree, "scout", "the tree's points hop")
    eq(view.bump.seg, #steps - 1, "with the bar's segment just selected")
    local opened = 0
    for id, at in pairs(view.unlocks) do
        opened = opened + 1
        eq(rowOf(id), 2, id .. " is of the row that opened")
        eq(at, clock.now + Motion.UNLOCK_DELAY_MS, "behind the pop")
        eq(view.nodes[id].state, "avail")
    end
    truthy(opened > 0, "row 2 opened")
    eq(view.unlockEnd, clock.now + Motion.UNLOCK_DELAY_MS + Motion.UNLOCK_MS)
end)

test("a rank taken back shrinks its node, a refused click or nothing to take back shakes it", function()
    local view = onSection(scoutSection())
    shown(view)
    local first = rowTwoSteps()[1]
    View.plan(view, first)
    View.unplan(view, first)
    eq(view.fx[first].kind, "shrink")
    View.unplan(view, first)
    eq(view.fx[first].kind, "shake", "nothing of it selected")
    local high
    for _, node in ipairs(Data.treeNodes("scout")) do
        if node.row == 3 then high = node.id end
    end
    View.plan(view, high)
    eq(view.fx[high].kind, "shake", "row 3 is not open")
    eq(view.refusal.id, high, "the reason in its tooltip as before")
end)

test("a click's answer is followed each frame and let go once over", function()
    local UI = OA.Trade.UI
    local Motion = OA.Upgrades.Motion
    local view = laidOut("trees")
    local body = shown(view)
    View.startFx(view, "x", "pop")
    UI.liveFrame()
    eq(body.liveLook, clock.now, "the tab's clock: drawn afresh")
    clock.now = clock.now + 16
    UI.liveFrame()
    eq(body.liveLook, clock.now, "every frame")
    clock.now = clock.now + Motion.fxMs("pop")
    UI.liveFrame()
    eq(body.liveLook, nil, "over: let go")
    eq(view.fx, nil, "and dropped before the frame drawn without it")
end)

test("the pulses, dashes and lights keep only the flow followed: the body is let go and kept as drawn", function()
    local UI = OA.Trade.UI
    local view = onSection(scoutSection())
    local body, flow = shown(view)
    eq(view.flowing, true, "a node can be taken")
    truthy(#view.pulsing > 0, "the nodes that pulse, listed")
    View.animate(view)
    UI.liveFrame()
    local first = flow.liveLook
    eq(body.liveLook, nil, "the body: nothing of its own moves")
    eq(body.liveCount, nil, "and nothing written to it")
    clock.now = clock.now + 16
    UI.liveFrame()
    truthy(flow.liveLook ~= first and flow.liveLook ~= nil, "the flow moves each frame")
    eq(body.liveCount, nil, "the body still untouched: a sibling, not the flow's parent")
    truthy(view.liveCount ~= nil, "the tab marked (its own drawing is light)")
    -- a stamp: the flow holds still under its seal
    view.stamp = { order = {}, start = clock.now }
    clock.now = clock.now + 16
    UI.liveFrame()
    eq(flow.liveLook, -1)
    view.stamp = nil
    -- the selection taken back and nothing left that moves: the flow let go too
    view.flowing = false
    UI.liveFrame()
    eq(flow.liveLook, nil, "nothing flows: let go")
    view.flowing = true
    View.animate(view)
    flow.isVisible = function() return false end
    UI.liveFrame()
    eq(flow.liveLook, nil, "hidden: let go")
    local closed = onSection(OA.Upgrades.Rules.blank())
    eq(closed.flowing, false, "no tree open: nothing moves by itself")
end)

test("the flow is made with the body, after it, as its sibling in the tab", function()
    local view = laidOut("trees")
    local children = {}
    view.addChild = function(v, child)
        children[#children + 1] = child
        child.parent = v
    end
    view.removeChild = function(_, child)
        for i, c in ipairs(children) do
            if c == child then table.remove(children, i) end
        end
    end
    -- the game's panel as far as making the two goes
    ISPanel.new = function(class, x, y, w, h)
        return setmetatable({ x = x, y = y, width = w, height = h }, { __index = class })
    end
    View.makeBody(view)
    View.makeBody(view)
    eq(#children, 2, "made again for a new scale: the old two gone")
    eq(children[1], view.body)
    eq(children[2], view.flow, "the flow after the body: drawn over it")
    eq(view.flow.parent, view, "a sibling of the body")
    eq(view.flow.width, view.body.width)
    eq(view.flow.height, view.body.height)
    truthy(rawget(OAResearchFlow, "onMouseUp") == nil and rawget(OAResearchFlow, "onMouseMove") == nil,
        "it handles no mouse: the body under it does")
end)

test("the padlocks an approval took off come off once its stamp is over, not on top of it", function()
    local UI = OA.Trade.UI
    local Plan = OA.Upgrades.Plan
    local Rules = OA.Upgrades.Rules
    local Motion = OA.Upgrades.Motion
    local u = scoutSection()
    local view = onSection(u)
    local body = shown(view)
    view.getIsVisible = function() return true end
    for _, id in ipairs(rowTwoSteps()) do View.plan(view, id) end
    view.fx, view.unlocks, view.unlockFrom, view.unlockEnd = nil, nil, nil, nil
    -- the approval as View.approve makes it, then the server's answer: the ranks on the record, the selection gone
    local steps = view.steps
    view.approved = { steps = steps, at = clock.now, locked = View.lockedOnRecord(view) }
    for _, step in ipairs(steps) do truthy(Rules.buy(u, step.id, { fragments = 0 }, step.choice)) end
    view.steps = {}
    view:refresh()
    View.startStamp(view)
    local start = clock.now
    local n = #Plan.stampOrder(steps)
    local ends = start + Plan.stampEnd(n)
    local opened = 0
    for id, at in pairs(view.unlocks) do
        eq(at, ends, id .. " after the stamp")
        if view.nodes[id] and view.nodes[id].state == "avail" then
            opened = opened + 1
            eq(rowOf(id), 2, id)
        end
        truthy(not Plan.counts(steps)[id], "not a node the stamp lights")
    end
    truthy(opened > 0, "row 2 opened by the approval")
    eq(Motion.unlock(start - ends), 1, "drawn locked meanwhile")
    view.flowing = false
    clock.now = start + Plan.sealAt(n) + Plan.sealSettle() + 100
    UI.liveFrame()
    eq(body.liveLook, -1, "the seal holds still: nothing drawn afresh")
    clock.now = ends
    UI.liveFrame()
    eq(view.stamp, nil, "the stamp is over")
    eq(body.liveLook, clock.now, "the padlocks come off")
    clock.now = ends + Motion.UNLOCK_MS
    UI.liveFrame()
    eq(body.liveLook, nil, "over: let go")
    eq(view.unlocks, nil)
end)

test("the opening is followed while it plays and only then", function()
    local UI = OA.Trade.UI
    local Motion = OA.Upgrades.Motion
    local view = laidOut("trees")
    local body = shown(view)
    View.startOpen(view)
    UI.liveFrame()
    eq(body.liveLook, clock.now)
    clock.now = clock.now + Motion.openEnd(#view.panels, Data.ROWS) - 1
    UI.liveFrame()
    eq(body.liveLook, clock.now, "still opening")
    clock.now = clock.now + 1
    UI.liveFrame()
    eq(body.liveLook, nil, "open")
    eq(view.openAt, nil)
end)

test("a switch between the trees and the board brings the new trees up at the switch's pace", function()
    local UI = OA.Trade.UI
    local Motion = OA.Upgrades.Motion
    local view = laidOut("trees")
    local body = shown(view)
    View.onMode(view, { internal = "board" })
    eq(view.openPace, Motion.SWITCH_PACE)
    local ends = Motion.openEnd(#view.panels, Data.ROWS) * Motion.SWITCH_PACE
    truthy(ends >= 300 and ends <= 450, "short: " .. ends)
    UI.liveFrame()
    eq(body.liveLook, clock.now, "followed")
    clock.now = clock.now + ends
    UI.liveFrame()
    eq(body.liveLook, nil, "over at its pace")
    View.onMode(view, { internal = "board" })
    eq(view.openAt, nil, "the same mode again: nothing")
end)

test("the light under the mouse keeps the body followed while it comes up or goes down, then lets it go", function()
    local UI = OA.Trade.UI
    local view = laidOut("trees")
    local body = shown(view)
    body.rev = 0
    view.asking = function() return false end
    local item = view:firstNode()
    View.setHover(view, item)
    eq(body.fx.cur.place, item.id, "the node's light, by its id")
    UI.liveFrame()
    eq(body.liveLook, clock.now, "coming up: our frame function follows it (not replaced by the light's)")
    clock.now = clock.now + UI.HOVER_IN_MS
    UI.liveFrame()
    eq(body.liveLook, nil, "up: let go")
    View.setHover(view, nil)
    eq(body.fx.fade.place, item.id, "going down")
    UI.liveFrame()
    eq(body.liveLook, clock.now)
    clock.now = clock.now + UI.HOVER_OUT_MS
    UI.liveFrame()
    eq(body.liveLook, nil, "down: let go")
end)

test("a click's mark on the points is followed while it hops and dropped after", function()
    local UI = OA.Trade.UI
    local Motion = OA.Upgrades.Motion
    local view = onSection(scoutSection())
    local body = shown(view)
    View.plan(view, rowTwoSteps()[1])
    view.fx = nil
    UI.liveFrame()
    eq(body.liveLook, clock.now, "the hop")
    clock.now = clock.now + Motion.BUMP_MS
    UI.liveFrame()
    eq(body.liveLook, nil)
    eq(view.bump, nil)
end)

test("a hidden tab forgets what was moving", function()
    local view = laidOut("trees")
    shown(view)
    view.hideTip = function() end
    View.startFx(view, "x", "pop")
    View.addUnlock(view, "y", clock.now)
    View.startOpen(view)
    View.setVisible(view, false)
    eq(view.fx, nil)
    eq(view.unlocks, nil)
    eq(view.unlockEnd, nil)
    eq(view.openAt, nil)
end)

test("every motion paints, frame after frame, with strengths between 0 and 1 and no size below 0", function()
    local Plan = OA.Upgrades.Plan
    local P = OA.Trade.UI.palette("field")
    local u = scoutSection()
    local view = onSection(u)
    local refresh = view.refresh
    view.refresh = function(v)
        refresh(v)
        v.spentPlan = Plan.spent(v.u, v.sim)
    end
    view:refresh()
    shown(view)
    view.getIsVisible = function() return true end
    local rects, bad, covers = 0, {}, 0
    local function rect(_, x, y, w, h, a, r, g, b)
        rects = rects + 1
        if a < 0 or a > 1 or w < 0 or h < 0 or x ~= x or y ~= y then bad[#bad + 1] = x .. "," .. y .. " a=" .. a end
        if a == 1 and r == P.bg[1] and g == P.bg[2] and b == P.bg[3] and w == L.COL_W then covers = covers + 1 end
    end
    ISUIElement = { drawRect = rect, drawTextureScaled = function(_, _, _, _, w, h, a)
        if a < 0 or a > 1 or w < 0 or h < 0 then bad[#bad + 1] = "texture a=" .. a end
    end }
    getTexture = function() return {} end
    getSoundManager = function() return { playUISound = function() end } end
    -- the body: its own fields set, the game's drawing answered by stand-ins
    local el = view.body
    el.drawRect, el.oaBase, el.oaScaled, el.oaDesign = rect, false, false, false
    el.fx, el.fxFlash, el.rev, el.liveLook = false, false, 0, false
    setmetatable(el, { __index = function() return function() return 0 end end })
    View.startOpen(view)
    View.paint(view, el)
    eq(covers, 3, "the opening starts with the columns hidden")
    -- clicks, a row opening, an approval's stamp, the padlocks after it; a frame every 16 ms for 4 s
    local steps = rowTwoSteps()
    for _, id in ipairs(steps) do View.plan(view, id) end
    View.unplan(view, steps[1])
    View.plan(view, steps[1])
    for _, node in ipairs(Data.treeNodes("scout")) do
        if node.row == 3 then View.plan(view, node.id) end
    end
    -- the mouse on a node (its tooltip aside), then off it, and a switch to the board and back
    view.updateTip = function() end
    View.setHover(view, view.byKey[steps[1]])
    local function frames(n)
        for _ = 1, n do
            clock.now = clock.now + 16
            OA.Trade.UI.liveFrame()
            View.paint(view, el)
            View.paintFlow(view, el)
        end
    end
    frames(30)
    View.setHover(view, nil)
    View.onMode(view, { internal = "board" })
    frames(20)
    View.onMode(view, { internal = "trees" })
    frames(40)
    -- the approval and its answer, as in the test above; then the lit lines' lights for a while
    local Motion = OA.Upgrades.Motion
    local bead, beads = Motion.bead, 0
    Motion.bead = function(...)
        local head, a, len = bead(...)
        if head then beads = beads + 1 end
        return head, a, len
    end
    view.approved = { steps = view.steps, at = clock.now, locked = View.lockedOnRecord(view) }
    for _, step in ipairs(view.steps) do OA.Upgrades.Rules.buy(u, step.id, { fragments = 0 }, step.choice) end
    -- (and a prerequisite met: sixth at its second rank lights its line to sense)
    for _ = 1, 2 do truthy(OA.Upgrades.Rules.buy(u, "sixth", { fragments = 0 })) end
    view.steps = {}
    view:refresh()
    View.startStamp(view)
    frames(300)
    Motion.bead = bead
    eq(#bad, 0, table.concat(bad, "; "))
    truthy(rects > 0)
    truthy(beads > 0, "a lit line's light drawn")
end)
