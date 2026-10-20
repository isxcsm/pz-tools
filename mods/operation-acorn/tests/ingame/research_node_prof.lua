-- The research tab's nodes timed during the board's reveal, by what each is doing: its padlock flashing off, waiting
-- for it (drawn locked), or neither; and the rest of a paint. Changes nothing. Prints [nodeprof] lines.
local OA = OperationAcorn
local t = STEPS("nodeprof")
local Window, Motion = OA.Upgrades.Window, OA.Upgrades.Motion
local info = getPlayerInfoPanel(0)
if not (info:getIsVisible() and info.panel:getActiveView() == Window.view(0)) then OA.Upgrades.open(0) end
local view = Window.view(0)
local cls = getmetatable(view).__index
local kinds = {}
local function add(kind, ms)
    local k = kinds[kind] or { n = 0, ms = 0 }
    kinds[kind] = k
    k.n, k.ms = k.n + 1, k.ms + ms
end
local realNode, realPaint = cls.paintNode, cls.paint
local on = false
cls.paintNode = function(self, el, item)
    if not on then return realNode(self, el, item) end
    local kind = "plain"
    local at = self.unlocks and self.unlocks[item.id]
    if at then
        local age = OA.Trade.UI.frameNow(el) - at
        kind = age < 0 and "waiting" or (age < Motion.UNLOCK_MS and "flashing" or "plain")
    end
    local t0 = getTimestampMs()
    realNode(self, el, item)
    add(kind, getTimestampMs() - t0)
end
cls.paint = function(self, el)
    if not on then return realPaint(self, el) end
    local t0 = getTimestampMs()
    realPaint(self, el)
    add("paint", getTimestampMs() - t0)
end
t.run({
    { 300, function() view:onMode({ internal = "trees" }) end },
    { 600, function()
        on = true
        view:revealBoard(getTimestampMs())
    end },
    { 3000, function()
        on = false
        cls.paintNode, cls.paint = realNode, realPaint
        for kind, k in pairs(kinds) do
            t.say(kind, "calls", k.n, string.format("%.3f ms a call", k.ms / k.n), "total", k.ms, "ms")
        end
    end },
})
