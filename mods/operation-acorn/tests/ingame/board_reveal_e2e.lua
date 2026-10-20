-- The 2nd board's opening, played as the player meets it: the research cleared, every tree bought out with two
-- capstones approved, the last (survival's) selected in the tab and applied. Then: the take plays on the trees, the
-- tab turns to the board, which comes up at Motion.REVEAL_PACE with each node's padlock coming off as it pops in; the
-- capstone's title and then the board's (unveil, major, gold); the last capstone's memo and the board's in the folder.
-- Times the tab's paints while it plays (calls over a frame, 16 ms, are named) and the frame gaps. (A screenshot taken
-- meanwhile makes a gap of its own, some 250 ms.)
-- Changes the save (the research). Prints [boardreveal] lines.
local OA = OperationAcorn
local t = STEPS("boardreveal")
local Rules, Data, Motion = OA.Upgrades.Rules, OA.Upgrades.Data, OA.Upgrades.Motion
local Window = OA.Upgrades.Window

-- the research as a player who has done the three trees but the last capstone
local u = OA.Dev.clearResearch()
local record = OA.Dev.record()
local s = OA.Story.section(record)
for _, id in ipairs({ "memo_scout_cap", "memo_load_cap", "memo_survival_cap", "memo_board" }) do
    s.docs[id], s.docExtra[id] = nil, nil
end
for _, tree in ipairs(Data.TREES) do
    for _ = 1, 26 do Rules.inject(u, tree) end
    Rules.unseal(u, tree)
    local more = true
    while more do
        more = false
        for _, node in ipairs(Data.treeNodes(tree)) do
            if not node.capstone and Rules.buy(u, node.id) then more = true end
        end
    end
end
t.check("scout and load capstones bought", Rules.buy(u, "nightEye") and Rules.buy(u, "armor"))
t.check("the board still closed", not Rules.boardOpen(u))
OA.Sync.changed("upgrades", record.id)

-- what the server says to the screen
local titles = {}
local realTitle = OA.Sync.title
OA.Sync.title = function(id, spec, ...)
    titles[#titles + 1] = spec
    return realTitle(id, spec, ...)
end

-- timing: the tab's frame work, and the frames themselves
local slow, calls, worst = {}, 0, 0
local function timed(owner, name)
    local real = owner[name]
    owner[name] = function(...)
        local t0 = getTimestampMs()
        local a, b, c = real(...)
        local ms = getTimestampMs() - t0
        calls = calls + 1
        if ms > worst then worst = ms end
        if ms > 16 then slow[#slow + 1] = name .. " " .. ms .. " ms" end
        return a, b, c
    end
    return real
end
local view
local frames, lastFrame, gap = 0, nil, 0
local function onFrame()
    local now = getTimestampMs()
    if lastFrame then gap = math.max(gap, now - lastFrame) end
    lastFrame = now
    frames = frames + 1
end

local info = getPlayerInfoPanel(0)
if info:getIsVisible() and info.panel:getActiveView() == Window.view(0) then OA.Upgrades.open(0) end
view = OA.Upgrades.open(0)
local cls = getmetatable(view).__index
local reals = {}
for _, name in ipairs({ "paint", "paintFlow", "paintPulses", "revealBoard", "setMode", "workOut", "layout" }) do
    reals[name] = timed(cls, name)
end

local approvedAt, takeEnds
t.run({
    { 300, function()
        view:onMode({ internal = "trees" })
        view:plan("dash")
        t.check("the last capstone selected", #view.steps == 1 and view.steps[1].id == "dash", #view.steps)
    end },
    { 800, function()
        Events.OnPostUIDraw.Add(onFrame)
        approvedAt = getTimestampMs()
        view:approve()
    end },
    { 200, function()
        t.check("the take plays on the trees", view.take ~= nil and view.mode == "trees", view.mode)
        t.check("it is the one that opens the board", view.take and view.take.board == true)
        takeEnds = view.take and (view.take.start + view.take.ends) or getTimestampMs()
        t.say("take ms", view.take and view.take.ends)
        t.check("the board open on the record", Rules.boardOpen(Rules.section(record)))
    end },
    -- (a step waits from the one before: the take, about two seconds, then a moment of the board coming up)
    { 2500, function()
        t.say("past the take's end by", getTimestampMs() - takeEnds, "ms")
        t.check("the take is over", view.take == nil)
        t.check("the tab turned to the board", view.mode == "board", view.mode)
        t.check("at the reveal's pace", view.openPace == Motion.REVEAL_PACE, view.openPace)
        local n, locked = 0, 0
        for _, item in ipairs(view.items) do
            if item.id then
                n = n + 1
                if view.nodes[item.id] and (view.nodes[item.id].state == "locked") then locked = locked + 1 end
            end
        end
        t.check("its nodes shown, none locked", n > 0 and locked == 0, n .. " nodes, " .. locked .. " locked")
    end },
    { 4000, function()
        t.check("the reveal is over", view.openAt == nil and view.unlocks == nil)
        local keys = {}
        for i, spec in ipairs(titles) do keys[i] = (spec.key or "?") .. "/" .. tostring(spec.style) .. "/" .. tostring(spec.size) end
        t.say("titles", table.concat(keys, ", "))
        t.check("the capstone's title, then the board's", #titles == 2 and titles[1].key == Data.key("dash", "Name")
            and titles[2].key == "IGUI_OA_Title_BoardOpened")
        t.check("the board's: unveil, major, gold", titles[2] and titles[2].style == "unveil" and titles[2].size == "major"
            and titles[2].tone == "gold")
        t.check("both memos in the folder", s.docs.memo_survival_cap ~= nil and s.docs.memo_board ~= nil)
        Events.OnPostUIDraw.Remove(onFrame)
        local secs = (getTimestampMs() - approvedAt) / 1000
        t.say("frames", frames, "in", string.format("%.1f s", secs), "fps", string.format("%.0f", frames / secs),
            "worst gap", gap, "ms")
        t.say("tab calls", calls, "worst", worst, "ms", "slow", #slow, table.concat(slow, "; "))
        t.check("no tab call over a frame (16 ms)", #slow == 0, #slow)
        for name, real in pairs(reals) do cls[name] = real end
        OA.Sync.title = realTitle
    end },
})
