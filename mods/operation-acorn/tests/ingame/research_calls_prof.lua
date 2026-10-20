-- The research tab's draw calls counted by kind, per paint, while it comes up on the trees (its opening) and while it
-- stands still: what a frame of the opening asks of the game. Changes nothing. Prints [callsprof] lines.
local OA = OperationAcorn
local t = STEPS("callsprof")
local Window = OA.Upgrades.Window
local info = getPlayerInfoPanel(0)
if info:getIsVisible() and info.panel:getActiveView() == Window.view(0) then OA.Upgrades.open(0) end
local view = OA.Upgrades.open(0)
view:onMode({ internal = "trees" })
local cls = getmetatable(view).__index

local phase, counts, paints = nil, {}, {}
local NAMES = { "drawRect", "drawRectBorder", "drawTexture", "drawTextureScaled", "drawTextureScaledAspect",
    "drawTextureTiled", "drawText", "drawTextCentre", "drawTextRight", "drawTextUntrimmed" }
local reals = {}
local inPaint = false
for _, name in ipairs(NAMES) do
    local real = ISUIElement[name]
    if real then
        reals[name] = real
        ISUIElement[name] = function(...)
            if inPaint and phase then
                local c = counts[phase]
                c[name] = (c[name] or 0) + 1
            end
            return real(...)
        end
    end
end
local realPaint = cls.paint
cls.paint = function(self, el)
    if not phase then return realPaint(self, el) end
    inPaint = true
    realPaint(self, el)
    inPaint = false
    paints[phase] = (paints[phase] or 0) + 1
end
local function start(name)
    phase = name
    counts[name] = {}
end
t.run({
    { 300, function() OA.Upgrades.open(0) end },
    { 400, function()
        start("opening")
        OA.Upgrades.open(0)
    end },
    { 700, function() start("still") end },
    { 800, function()
        phase = nil
        cls.paint = realPaint
        for name, real in pairs(reals) do ISUIElement[name] = real end
        for _, name in ipairs({ "opening", "still" }) do
            local list = {}
            local n = paints[name] or 0
            for kind, c in pairs(counts[name]) do list[#list + 1] = string.format("%s %.0f", kind, c / math.max(1, n)) end
            table.sort(list)
            t.say(name, "paints", n, "| a paint:", table.concat(list, ", "))
        end
    end },
})
