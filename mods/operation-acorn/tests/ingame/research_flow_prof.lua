-- The research tab's flow and pulse panels timed while the trees stand still (their lit lines' lights and the pulse
-- move): the paints, their mean and worst, over a few seconds. Changes nothing. Prints [flowprof] lines.
local OA = OperationAcorn
local t = STEPS("flowprof")
local Window = OA.Upgrades.Window
local info = getPlayerInfoPanel(0)
if not (info:getIsVisible() and info.panel:getActiveView() == Window.view(0)) then OA.Upgrades.open(0) end
local view = Window.view(0)
view:onMode({ internal = "trees" })
local cls = getmetatable(view).__index
local stats = {}
local reals = {}
for _, name in ipairs({ "paintFlow", "paintPulses" }) do
    local real = cls[name]
    reals[name] = real
    local s = { n = 0, total = 0, worst = 0 }
    stats[name] = s
    cls[name] = function(self, el)
        local t0 = getTimestampMs()
        real(self, el)
        local ms = getTimestampMs() - t0
        s.n, s.total = s.n + 1, s.total + ms
        if ms > s.worst then s.worst = ms end
    end
end
t.run({
    { 4000, function()
        for name, real in pairs(reals) do cls[name] = real end
        for name, s in pairs(stats) do
            t.say(name, "paints", s.n, string.format("mean %.3f ms worst %.2f ms", s.total / math.max(1, s.n), s.worst))
        end
        t.say("lighting", view.lighting, "lines", #view.lines)
    end },
})
