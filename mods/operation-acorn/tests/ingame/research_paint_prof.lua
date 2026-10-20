-- The research tab's drawing, timed by phase: the tab coming up on the trees, the trees still, the switch to the board,
-- the board's reveal (as after the last capstone), the board still. For each: the paints, their mean and worst, and
-- what of a paint the parts take on average (under the nodes, the nodes, over them, the take). Changes nothing.
-- Prints [paintprof] lines.
local OA = OperationAcorn
local t = STEPS("paintprof")
local Window = OA.Upgrades.Window

local info = getPlayerInfoPanel(0)
if info:getIsVisible() and info.panel:getActiveView() == Window.view(0) then OA.Upgrades.open(0) end
local view = OA.Upgrades.open(0)
local cls = getmetatable(view).__index

local phase, stats = nil, {}
local inPaint = false
local function stat(name)
    local s = stats[phase]
    if not s then
        s = { paints = 0, total = 0, worst = 0, parts = {} }
        stats[phase] = s
    end
    return s
end
local reals = {}
local function wrapPart(name)
    local real = cls[name]
    reals[name] = real
    cls[name] = function(self, ...)
        if not phase or not inPaint then return real(self, ...) end
        local t0 = getTimestampMs() * 1e6
        local a, b = real(self, ...)
        local ms = ((getTimestampMs() * 1e6) - t0) / 1e6
        local s = stat()
        s.parts[name] = (s.parts[name] or 0) + ms
        return a, b
    end
end
for _, name in ipairs({ "paintUnder", "paintNode", "paintOver", "drawTake", "paintStrip", "paintLine", "updateTip",
        "frameState" }) do
    wrapPart(name)
end
local realPaint = cls.paint
reals.paint = realPaint
cls.paint = function(self, el, ...)
    if not phase then return realPaint(self, el, ...) end
    inPaint = true
    local t0 = getTimestampMs() * 1e6
    realPaint(self, el, ...)
    local ms = ((getTimestampMs() * 1e6) - t0) / 1e6
    inPaint = false
    local s = stat()
    s.paints = s.paints + 1
    s.total = s.total + ms
    if ms > s.worst then s.worst = ms end
end

local function report(name)
    local s = stats[name]
    if not s then t.say(name, "no paint") return end
    local parts = {}
    for part, ms in pairs(s.parts) do parts[#parts + 1] = string.format("%s %.2f", part, ms / s.paints) end
    table.sort(parts)
    t.say(name, "paints", s.paints, string.format("mean %.2f ms worst %.2f ms", s.total / s.paints, s.worst),
        "| per paint:", table.concat(parts, ", "))
end

t.run({
    { 300, function()
        view:onMode({ internal = "trees" })
        OA.Upgrades.open(0) -- hide
    end },
    { 300, function()
        phase = "open trees"
        OA.Upgrades.open(0)
    end },
    { 1500, function() phase = "trees still" end },
    { 1500, function()
        phase = "switch to board"
        view:onMode({ internal = "board" })
    end },
    { 1200, function() phase = "board still" end },
    { 1500, function()
        phase = "board reveal"
        view:revealBoard(getTimestampMs())
    end },
    { 2500, function()
        phase = nil
        for name, real in pairs(reals) do cls[name] = real end
        for _, name in ipairs({ "open trees", "trees still", "switch to board", "board still", "board reveal" }) do
            report(name)
        end
        t.say("UI.S", OA.Trade.UI.S, "screen", getCore():getScreenWidth(), getCore():getScreenHeight())
    end },
})
