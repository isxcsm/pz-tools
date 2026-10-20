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

-- A canvas's stand-in: every method there, returning 0; not the kit's fields (its frame time, liveNow, is the clock's
-- then; uiGone and uiFadeRoot unset, as on a body in the UI: a function there read as taken out, its frames dropped).
local NOT_METHODS = { liveNow = true, uiGone = true, uiFadeRoot = true }
local function canvasMethod(_, key)
    if not NOT_METHODS[key] then return function() return 0 end end
end

-- Loads the tab with the stand-ins; returns its view class.
local function loadWindow()
    for _, name in ipairs(UI) do _G[name] = stubClass() end
    UIFont = setmetatable({}, { __index = function(_, k) return k end })
    getTextManager = function()
        return setmetatable({}, { __index = function() return function() return 16 end end })
    end
    getText = function(key) return key end
    -- (no pictures: the tab draws without them)
    getTexture = function() return nil end
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

test("every node sits inside its column's (or band's) grid, on no other node", function()
    for _, mode in ipairs({ "trees", "board" }) do
        local view = laidOut(mode)
        local nodes = 0
        for _, item in ipairs(view.items) do
            if item.id then
                nodes = nodes + 1
                local inside = false
                for _, panel in ipairs(view.panels) do
                    if item.x >= panel.gx and item.x + item.w <= panel.gx + panel.w and item.y >= panel.gy
                        and item.y + item.h + L.PIPS <= panel.gy + panel.gridH then
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

test("the board is a band across for each tree, its nodes in one row, in the columns' room", function()
    local view = laidOut("board")
    eq(#view.panels, 3, "bands")
    local top, bottom = L.COL_Y, L.COL_Y + L.STRIP + L.GRID_H
    for i, panel in ipairs(view.panels) do
        eq(panel.tree, Data.BOARD_GROUPS[i], "band " .. i)
        eq(panel.w, L.VIEW_W - 2 * L.PAD, "band " .. i .. " across")
        truthy(panel.y >= top and panel.y + panel.strip + panel.gridH <= bottom + 1e-6, "band " .. i .. " in the room")
        local row = nil
        for _, item in ipairs(view.items) do
            if item.id and item.tree == panel.tree then
                row = row or item.y
                eq(item.y, row, item.id .. " in its band's row")
            end
        end
    end
    eq(#view.panels[1].trays, 1, "scout: one kind")
    eq(#view.panels[2].trays, 3, "load: lightening, gear, carrying")
    eq(#view.panels[3].trays, 2, "survival: resistance, the rest")
    for _, panel in ipairs(view.panels) do
        local first, last = panel.trays[1], panel.trays[#panel.trays]
        truthy(math.abs((first.x - panel.x) - (panel.x + panel.w - last.x - last.w)) < 1e-6, panel.tree .. ": the row in the middle")
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

test("an applied selection's take is followed each frame before the UI draws, and let go once it is over", function()
    local UI = OA.Trade.UI
    local view = laidOut("trees")
    local body = { view = view, isVisible = function() return true end }
    view.body, view.sim = body, {}
    view.getIsVisible = function() return true end
    local now = 7000000
    view.t0 = now
    getTimestampMs = function() return now end
    local ids = {}
    for _, item in ipairs(view.items) do
        if item.id and #ids < 2 then ids[#ids + 1] = { id = item.id } end
    end
    view.approved = { steps = ids, at = now }
    View.startTake(view)
    local start = now
    local ends = view.take.ends
    truthy(ends > 0)
    UI.liveFrame()
    eq(body.liveLook, 0, "the first node is taken")
    now = start + 300
    UI.liveFrame()
    eq(body.liveLook, 300, "every frame while it plays")
    now = start + ends - 1
    UI.liveFrame()
    eq(body.liveLook, ends - 1, "the wave to its end")
    now = start + ends
    UI.liveFrame()
    eq(body.liveLook, nil, "over: let go")
    eq(view.take, nil, "and the take gone, with no frame drawn")
end)

-- ---- motion (Motion.lua's timing, followed by View.tick) -----------------------------------------------------------

-- A shown body for the tab and the flow over it, both in a shown tab, and a clock the test moves.
local clock = { now = 9000000 }
local function shown(view)
    local function on() return true end
    view.isVisible = on
    local body = { view = view, isVisible = on, parent = view }
    local flow = { view = view, isVisible = on, parent = view }
    local pulse = { view = view, isVisible = on, parent = view, pulses = true }
    view.body, view.flow, view.pulse = body, flow, pulse
    getTimestampMs = function() return clock.now end
    return body, flow, pulse
end

-- A tab on a section of the upgrades, its refresh done here (no player): the selection simulated, the states worked
-- out.
local function onSection(u)
    local Plan = OA.Upgrades.Plan
    local view = laidOut("trees")
    view.u, view.steps = u, {}
    view.refresh = function(v)
        local sim, kept = Plan.simulate(v.u, v.steps)
        v.sim, v.steps, v.counts, v.revealed = sim, kept, Plan.counts(kept), {}
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

test("the pulses, dashes and lights keep only their panels followed: the body is let go and kept as drawn", function()
    local UI = OA.Trade.UI
    local view = onSection(scoutSection())
    local body, flow, pulse = shown(view)
    eq(view.flowing, true, "a node can be taken")
    truthy(#view.pulsing > 0, "the nodes that pulse, listed")
    eq(view.pulsingOn, true)
    eq(view.lighting, false, "no line is lit or selected yet")
    View.animate(view)
    UI.liveFrame()
    local first = pulse.liveLook
    truthy(first ~= nil, "the pulse panel is followed")
    eq(flow.liveLook, nil, "the lights have nothing to show: not followed")
    eq(body.liveLook, nil, "the body: nothing of its own moves")
    eq(body.liveCount, nil, "and nothing written to it")
    -- the pulse moves on a step at a time: fewer changes than frames, and each step of the cycle gets its turn
    local looks, changes, last = {}, 0, first
    for _ = 1, 200 do
        clock.now = clock.now + 16
        UI.liveFrame()
        if pulse.liveLook ~= last then changes = changes + 1 end
        last = pulse.liveLook
        looks[pulse.liveLook] = true
    end
    truthy(changes > 40 and changes < 150, "drawn on a step, not each frame: " .. changes .. " of 200")
    eq(body.liveCount, nil, "the body still untouched: a sibling, not the panel's parent")
    truthy(view.liveCount ~= nil, "the tab marked (its own drawing is light)")
    -- a take: the pulses hold still (the take draws its own lights)
    view.take = { order = {}, start = clock.now, ends = 1000 }
    clock.now = clock.now + 16
    UI.liveFrame()
    eq(pulse.liveLook, -1)
    view.take = nil
    -- nothing left that pulses: the panel let go too
    view.pulsingOn = false
    UI.liveFrame()
    eq(pulse.liveLook, nil, "nothing pulses: let go")
    view.pulsingOn = true
    View.animate(view)
    pulse.isVisible = function() return false end
    UI.liveFrame()
    eq(pulse.liveLook, nil, "hidden: let go")
    local closed = onSection(OA.Upgrades.Rules.blank())
    eq(closed.flowing, false, "no tree open: nothing moves by itself")
end)

test("a lit line's light is followed each frame by the flow, and the take holds it still", function()
    local UI = OA.Trade.UI
    local u = scoutSection()
    for _ = 1, 2 do truthy(OA.Upgrades.Rules.buy(u, "sixth")) end
    local view = onSection(u)
    local body, flow = shown(view)
    eq(view.lighting, true, "sixth at its second rank lights its line")
    View.animate(view)
    UI.liveFrame()
    local first = flow.liveLook
    clock.now = clock.now + 16
    UI.liveFrame()
    truthy(flow.liveLook ~= first and flow.liveLook ~= nil, "the flow moves each frame")
    view.take = { order = {}, start = clock.now, ends = 1000 }
    clock.now = clock.now + 16
    UI.liveFrame()
    eq(flow.liveLook, -1)
    view.take = nil
    view.lighting = false
    UI.liveFrame()
    eq(flow.liveLook, nil, "nothing flows: let go")
end)

test("an idle comet or a node held back costs no drawing; a pulse is drawn on its steps", function()
    local view = onSection(scoutSection())
    shown(view)
    local drawn = 0
    local el = setmetatable({}, { __index = canvasMethod })
    ISUIElement = { drawRect = function() drawn = drawn + 1 end, drawTextureScaled = function() drawn = drawn + 1 end }
    View.paintFlow(view, el)
    eq(drawn, 0, "nothing lit or selected: the lights panel draws nothing")
    view.pulseLevel = nil
    View.paintPulses(view, el)
    truthy(drawn > 0, "the nodes that can be taken pulse")
    local atLevel = drawn
    drawn = 0
    view.pulseLevel = 0
    View.paintPulses(view, el)
    eq(drawn, 0, "at the low point the pulse adds nothing to the body's frames")
    view.pulseLevel = OA.Upgrades.Window.PULSE_LEVELS
    View.paintPulses(view, el)
    eq(drawn, atLevel, "the same nodes at the top")
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
    eq(#children, 3, "made again for a new scale: the old three gone")
    eq(children[1], view.body)
    eq(children[2], view.flow, "the flow after the body: drawn over it")
    eq(children[3], view.pulse, "the pulse panel last")
    eq(view.flow.parent, view, "a sibling of the body")
    eq(view.flow.width, view.body.width)
    eq(view.flow.height, view.body.height)
    truthy(rawget(OAResearchFlow, "onMouseUp") == nil and rawget(OAResearchFlow, "onMouseMove") == nil,
        "it handles no mouse: the body under it does")
    -- but the game gives it a right click whatever it takes: it passes it on, and the rank is taken back
    local taken
    view.itemAt = function(_, x, y) return x == 5 and y == 6 and { id = "sight" } or nil end
    view.unplan = function(_, id) taken = id end
    eq(OAResearchFlow.onRightMouseUp(view.flow, 5, 6), true)
    eq(taken, "sight", "a right click over the flow takes the rank back")
end)

test("a taken node's light runs up its lit lines to its tree's header, through the nodes on the way", function()
    local u = scoutSection()
    for _, id in ipairs({ "sixth", "sixth", "sight", "sight", "sight", "alarm", "sense", "sense" }) do
        truthy(OA.Upgrades.Rules.buy(u, id), id)
    end
    local view = onSection(u)
    view:refresh()
    local lines, offs, len = View.wayUp(view, "sensePlus")
    eq(#lines, 2, "sensePlus to sense, sense to sixth")
    eq(lines[1].to, "sensePlus")
    eq(lines[2].to, "sense")
    eq(offs[1], 0)
    truthy(offs[2] > lines[1].len, "the second line starts past the node between")
    near(len, offs[2] + lines[2].len, 1e-9)
    eq(View.wayUp(view, "sixth"), nil, "a first-row node has no way up")
end)

test("the padlocks an approval took off come off once its take is over, not on top of it", function()
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
    for _, step in ipairs(steps) do truthy(Rules.buy(u, step.id, step.choice)) end
    view.steps = {}
    view:refresh()
    View.startTake(view)
    local start = clock.now
    local ends = start + view.take.ends
    local opened = 0
    for id, at in pairs(view.unlocks) do
        eq(at, ends, id .. " after the take")
        if view.nodes[id] and view.nodes[id].state == "avail" then
            opened = opened + 1
            eq(rowOf(id), 2, id)
        end
        truthy(not Plan.counts(steps)[id], "not a node the take reaches")
    end
    truthy(opened > 0, "row 2 opened by the approval")
    eq(Motion.unlock(start - ends), 1, "drawn locked meanwhile")
    view.flowing = false
    clock.now = ends - 100
    UI.liveFrame()
    eq(body.liveLook, clock.now, "the take moves to its end")
    clock.now = ends
    UI.liveFrame()
    eq(view.take, nil, "the take is over")
    eq(body.liveLook, clock.now, "the padlocks come off")
    clock.now = ends + Motion.UNLOCK_MS
    UI.liveFrame()
    eq(body.liveLook, nil, "over: let go")
    eq(view.unlocks, nil)
end)

test("the take of the last capstone turns the tab to the board, which comes up slowly, its padlocks coming off", function()
    local UI = OA.Trade.UI
    local Rules = OA.Upgrades.Rules
    local Motion = OA.Upgrades.Motion
    local u = Rules.blank()
    for _, tree in ipairs(Data.TREES) do u.opened[tree] = true end
    u.ranks.nightEye, u.ranks.armor = 1, 1
    local view = onSection(u)
    local body = shown(view)
    view.getIsVisible = function() return true end
    -- the approval of the last capstone as View.approve makes it, then the server's answer
    view.approved = { steps = { { id = "dash" } }, at = clock.now, locked = View.lockedOnRecord(view),
        boardWas = Rules.boardOpen(u) }
    eq(view.approved.boardWas, false)
    u.ranks.dash = 1
    view:refresh()
    View.startTake(view)
    truthy(view.take.board, "this take opened the board")
    eq(view.mode, "trees", "the trees while it plays")
    local ends = clock.now + view.take.ends
    clock.now = ends
    UI.liveFrame()
    eq(view.take, nil)
    eq(view.mode, "board", "then the board")
    eq(view.openPace, Motion.REVEAL_PACE)
    eq(body.liveLook, clock.now, "it comes up")
    local first, last, count = nil, 0, 0
    for _, item in ipairs(view.items) do
        if item.id then
            truthy(Data.byId[item.id].board, item.id)
            local at = view.unlocks[item.id]
            eq(at, ends + Motion.revealUnlockAt(item.col, item.row), item.id .. " opens as it pops in")
            first = math.min(first or at, at)
            last = math.max(last, at)
            count = count + 1
        end
    end
    truthy(count > 0)
    truthy(last > first, "one band after another")
    truthy(last - ends <= Motion.openEnd(#view.panels, Data.ROWS) * Motion.REVEAL_PACE, "within the board's coming up")
    -- a take that opens nothing turns nothing
    local again = onSection(u)
    shown(again)
    again.getIsVisible = function() return true end
    again.approved = { steps = { { id = "dash" } }, at = clock.now, boardWas = true }
    View.startTake(again)
    eq(again.take.board, false)
    -- approved with the board on the screen (the capstone selected in the trees before): it comes up all the same
    u.ranks.dash = nil
    local onBoard = onSection(u)
    shown(onBoard)
    onBoard.getIsVisible = function() return true end
    View.onMode(onBoard, { internal = "board" })
    onBoard.approved = { steps = { { id = "dash" } }, at = clock.now, boardWas = false }
    u.ranks.dash = 1
    onBoard:refresh()
    View.startTake(onBoard)
    eq(#onBoard.take.order, 0, "no node of the plan on the screen")
    clock.now = clock.now + onBoard.take.ends
    UI.liveFrame()
    eq(onBoard.mode, "board")
    eq(onBoard.openPace, Motion.REVEAL_PACE, "it comes up as it would from the trees")
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
    truthy(body.liveLook ~= nil, "coming up: followed")
    clock.now = clock.now + UI.HOVER_IN_MS
    UI.liveFrame()
    eq(body.liveLook, nil, "up: let go")
    View.setHover(view, nil)
    eq(body.fx.fade.place, item.id, "going down")
    UI.liveFrame()
    truthy(body.liveLook ~= nil, "followed while it goes down")
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
    local drawn = {}
    ISUIElement = { drawRect = rect, drawTextureScaled = function(_, tex, _, _, w, h, a)
        if a < 0 or a > 1 or w < 0 or h < 0 then bad[#bad + 1] = "texture a=" .. a end
        if tex.path then drawn[tex.path] = (drawn[tex.path] or 0) + 1 end
    end, drawTextureTiled = function(_, tex, _, _, w, h, _, _, _, a)
        if a < 0 or a > 1 or w < 0 or h < 0 then bad[#bad + 1] = "tiled a=" .. a end
        if tex.path then drawn[tex.path] = (drawn[tex.path] or 0) + 1 end
    end }
    getTexture = function(path) return { path = path } end
    getSoundManager = function() return { playUISound = function() end } end
    -- the body: its own fields set, the game's drawing answered by stand-ins
    local el = view.body
    el.drawRect, el.uiBase, el.uiScaled, el.uiDesign = rect, false, false, false
    el.fx, el.fxFlash, el.rev, el.liveLook = false, false, 0, false
    setmetatable(el, { __index = canvasMethod })
    -- the flow and the pulse paint on themselves, as in the game (each its own frame time)
    for _, part in ipairs({ view.flow, view.pulse }) do
        part.drawRect, part.uiBase, part.uiScaled, part.uiDesign = rect, false, false, false
        setmetatable(part, { __index = canvasMethod })
    end
    View.startOpen(view)
    View.paint(view, el)
    eq(covers, 3, "the opening starts with the columns hidden")
    -- clicks, a row opening, an applied selection's take, the padlocks after it; a frame every 16 ms for 4 s
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
            View.paintFlow(view, view.flow)
            View.paintPulses(view, view.pulse)
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
    local comet, comets, arrivals = Motion.comet, 0, 0
    Motion.comet = function(...)
        local head, a, tail, after, arrive = comet(...)
        if head then comets = comets + 1 end
        if arrive and arrive > 0 then arrivals = arrivals + 1 end
        return head, a, tail, after, arrive
    end
    view.approved = { steps = view.steps, at = clock.now, locked = View.lockedOnRecord(view), spent = view.spentPlan }
    for _, step in ipairs(view.steps) do OA.Upgrades.Rules.buy(u, step.id, step.choice) end
    -- (and a prerequisite met: sixth at its second rank lights its line to sense)
    for _ = 1, 2 do truthy(OA.Upgrades.Rules.buy(u, "sixth")) end
    -- (and sense in what the take plays, to send a light up that line: the take draws what it is given)
    local applied = view.approved.steps
    applied[#applied + 1] = { id = "sense" }
    view.steps = {}
    view:refresh()
    View.startTake(view)
    truthy(#view.take.order > 0)
    local runs = 0
    for _, way in ipairs(view.take.ways) do
        if way.lines then runs = runs + 1 end
    end
    truthy(runs > 0, "a taken node's light has a way up")
    frames(300)
    Motion.comet = comet
    eq(#bad, 0, table.concat(bad, "; "))
    truthy(rects > 0)
    truthy(comets > 0 and arrivals > 0, "a lit line's light drawn, arriving at its node")
    truthy((drawn["media/textures/OA_Glow.png"] or 0) > 0, "the light's glow drawn")
    truthy((drawn["media/textures/OA_Wave.png"] or 0) > 0, "the take's wave drawn")
    truthy((drawn["media/textures/OA_Grain.png"] or 0) > 0, "the columns' grain drawn")
end)

-- ---- the flow's and the pulse's rectangles through the API's rects call -------------------------------------------

-- The numbers of the rectangles a frame draws, one drawRect each (x, y, w, h, r, g, b, a), and the textures between
-- them, as a list of entries in drawing order.
local function frameOf(paint, view, el, api)
    local log = {}
    ISUIElement = {
        drawRect = function(_, x, y, w, h, a, r, g, b) log[#log + 1] = { "rect", x, y, w, h, r, g, b, a } end,
        drawTextureScaled = function(_, tex) log[#log + 1] = { "texture", tex } end,
    }
    local calls = 0
    PZExtAPI = nil
    if api then
        PZExtAPI = { version = 1, client = function() return {} end, draw = { rects = function(e, list, count)
            calls = calls + 1
            log[#log + 1] = { "batch", e, count, { unpack(list, 1, count * 8) } }
        end } }
    end
    paint(view, el)
    PZExtAPI = nil
    return log, calls
end

-- A batch's entry as the rectangles it holds, the way drawRect lists them.
local function flatten(log)
    local flat = {}
    for _, e in ipairs(log) do
        if e[1] == "batch" then
            for i = 0, e[3] - 1 do
                local l = e[4]
                local at = i * 8
                flat[#flat + 1] = { "rect", l[at + 1], l[at + 2], l[at + 3], l[at + 4], l[at + 5], l[at + 6], l[at + 7], l[at + 8] }
            end
        else
            flat[#flat + 1] = e
        end
    end
    return flat
end

test("the pulse's frames go to the API as one list of rectangles, the same ones drawRect would draw in the same order", function()
    local view = onSection(scoutSection())
    shown(view)
    view.pulseLevel = nil
    local el = setmetatable({}, { __index = canvasMethod })
    local plain = frameOf(View.paintPulses, view, el, false)
    truthy(#plain > 4, "the nodes that can be taken pulse")
    local batched, calls = frameOf(View.paintPulses, view, el, true)
    eq(calls, 1, "one call")
    eq(batched[1][2], el, "on the panel")
    local flat = flatten(batched)
    eq(#flat, #plain)
    for i = 1, #plain do
        for k = 2, 9 do eq(flat[i][k], plain[i][k], "rectangle " .. i .. " number " .. k) end
    end
end)

test("the flow's rectangles are drawn before a picture asked after them, and a failing call is drawn one by one", function()
    local u = scoutSection()
    for _ = 1, 2 do truthy(OA.Upgrades.Rules.buy(u, "sixth")) end
    local view = onSection(u)
    shown(view)
    getTexture = function(path) return { path = path } end
    local el = setmetatable({}, { __index = canvasMethod })
    -- a moment when the lit line's light is on the line
    local plain, batched, calls
    for ms = 0, 6000, 250 do
        clock.now = 9000000 + ms
        view.t0 = 9000000
        plain = frameOf(View.paintFlow, view, el, false)
        if #plain > 3 then break end
    end
    truthy(#plain > 3, "a lit line's light has something to draw")
    batched, calls = frameOf(View.paintFlow, view, el, true)
    local flat = flatten(batched)
    eq(#flat, #plain)
    for i = 1, #plain do
        eq(flat[i][1], plain[i][1], "entry " .. i .. " is a " .. plain[i][1])
        for k = 2, 9 do
            if plain[i][1] == "rect" then eq(flat[i][k], plain[i][k], "rectangle " .. i .. " number " .. k) end
        end
    end
    truthy(calls >= 1)
    -- a call that fails: this frame's rectangles are drawn one by one, and the call is not used again
    local log = {}
    ISUIElement = { drawRect = function(_, x, y, w, h, a) log[#log + 1] = { x, y, w, h } end,
        drawTextureScaled = function() end }
    local tried = 0
    -- (named: Kahlua's error() in an unnamed function throws a NullPointerException of its own)
    local function rects() tried = tried + 1; error("bad") end
    PZExtAPI = { version = 1, client = function() return {} end, draw = { rects = rects } }
    local logged = {}
    local realLog = OA.log
    OA.log = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end
    View.paintFlow(view, el)
    eq(#log >= 1, true, "drawn one by one after the failure")
    local first = #log
    eq(tried >= 1, true)
    local seen = tried
    log = {}
    View.paintFlow(view, el)
    eq(tried, seen, "not tried again")
    eq(#log >= 1, true)
    OA.log = realLog
    eq(#logged, 1, "told once")
    PZExtAPI = nil
end)

test("a sealed capstone is an outline: no name, no way into it, no rank; unsealed it shows as any node", function()
    local Rules = OA.Upgrades.Rules
    local u = scoutSection()
    local view = onSection(u)
    eq(view.nodes.nightEye.hidden, true)
    eq(view.nodes.armor.hidden, true, "every tree's")
    for _, line in ipairs(view.lines) do
        if line.to == "nightEye" then eq(line.state, "hidden") end
    end
    local rows = View.tipRows(view, "nightEye")
    eq(rows[1].text, "???")
    eq(#rows, 2, "a title and one line, nothing of what it does or needs")
    Rules.unseal(u, "scout")
    view:refresh()
    eq(view.nodes.nightEye.hidden, nil)
    eq(view.nodes.armor.hidden, true)
    truthy(View.tipRows(view, "nightEye")[1].text ~= "???")
end)

test("the body's parts are kept on tapes: played back, a node under the mouse alone worked out; a change drops them", function()
    local u = scoutSection()
    local view = onSection(u)
    shown(view)
    view.getIsVisible = function() return true end
    view.updateTip = function() end
    PZExtAPI = nil
    ISUIElement = { drawRect = function() end, drawTextureScaled = function() end, drawTextureTiled = function() end }
    getTexture = function(path) return { path = path } end
    -- the body draws through its javaObject, which logs the game's calls
    local calls = 0
    local jo = setmetatable({}, { __index = function(_, k)
        if k == "getAbsoluteX" or k == "getAbsoluteY" or k == "getXScroll" or k == "getYScroll" then return function() return 0 end end
        return function() calls = calls + 1 end
    end })
    local el = view.body
    el.javaObject = jo
    el.drawRect = function(self, x, y, w, h, a, r, g, b) self.javaObject:DrawTextureScaledColor(nil, x, y, w, h, r, g, b, a) end
    el.drawRectBorder = el.drawRect
    el.uiBase, el.fx, el.fxFlash, el.liveLook, el.rev = false, false, false, false, 0
    setmetatable(el, { __index = canvasMethod })
    ISUIElement.drawRect = function(self, ...) return self:drawRect(...) end
    local worked = {}
    local paintNode = View.paintNode
    View.paintNode = function(v, e, item)
        worked[#worked + 1] = item.id
        return paintNode(v, e, item)
    end
    local ok, err = pcall(function()
        View.paint(view, el)
        local nodes = #worked
        truthy(nodes > 0, "the first frame works every node out (recorded)")
        eq(calls > 0, true, "and draws them")
        local first = calls
        worked, calls = {}, 0
        View.paint(view, el)
        eq(#worked, 0, "played back: no node worked out")
        eq(calls, first, "the same draws")
        -- the mouse on a node: that node alone, the rest played
        local item
        for _, it in ipairs(view.items) do if it.id then item = it; break end end
        View.setHover(view, item)
        el.fx = { cur = { place = item.id, from = 0, to = 1, at = 0, dur = 1 } }
        worked = {}
        View.paint(view, el)
        eq(#worked, 1)
        eq(worked[1], item.id)
        -- a change of what the tab shows: every node recorded again (still), the one under the mouse drawn lit
        view:changed()
        worked = {}
        View.paint(view, el)
        eq(#worked, nodes + 1)
        eq(worked[#worked], item.id)
    end)
    View.paintNode = paintNode
    if not ok then error(err, 0) end
end)

test("a steady pulse is kept per step and played back; with the focus on a pulsing node it is worked out", function()
    local view = onSection(scoutSection())
    shown(view)
    PZExtAPI = nil
    local worked, drawn = 0, {}
    ISUIElement = { drawRect = function(self, x, y, w, h, a, r, g, b)
        worked = worked + 1
        self.javaObject:DrawTextureScaledColor(nil, x, y, w, h, r, g, b, a)
    end }
    local jo = { DrawTextureScaledColor = function(_, _, x, y, w, h, r, g, b, a)
        drawn[#drawn + 1] = table.concat({ x, y, w, h, r, g, b, a }, ",")
    end }
    local el = setmetatable({ javaObject = jo }, { __index = canvasMethod })
    view.pulseLevel = 12
    View.paintPulses(view, el)
    truthy(worked > 0, "recorded")
    truthy(view.pulseTapes[12], "kept for its step")
    local first = drawn
    worked, drawn = 0, {}
    View.paintPulses(view, el)
    eq(worked, 0, "played back")
    eq(table.concat(drawn, ";"), table.concat(first, ";"), "the same rectangles")
    view.hover = view.pulsing[1].key
    worked = 0
    View.paintPulses(view, el)
    truthy(worked > 0, "the focus on a pulsing node: worked out")
    view.hover = nil
    view:changed()
    eq(view.pulseTapes, nil, "a change drops the steps")
end)
