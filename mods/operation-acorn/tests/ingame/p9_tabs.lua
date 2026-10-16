-- P9: opens the terminal within reach (powered for the look, P9_POWER_BACK() undoes it) on the tab P9_TAB (else the
-- first), its boot skipped, for a picture of each tab at the window size and language the game has. Lines "[p9tabs]".
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p9tabs")
local player = getPlayer()
local Objects = OA.Trade.Objects
local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
local at
for dy = -3, 3 do
    for dx = -3, 3 do
        local square = getCell():getGridSquare(px + dx, py + dy, pz)
        if not at and square and Objects.find(square, Objects.TERMINAL) then at = square end
    end
end
if not at then say("no terminal within 3 squares"); return end
if not P9_POWER_BACK then
    local powered = Objects.powered
    Objects.powered = function(square, object)
        if square == at then return true end
        return powered(square, object)
    end
    P9_POWER_BACK = function()
        Objects.powered = powered
        P9_POWER_BACK = nil
    end
end
local window = OATerminalWindow.instances and OATerminalWindow.instances[0]
if not (window and window:isVisible()) then
    window = OA.Terminal.open(player, at:getX(), at:getY(), at:getZ())
    for _ = 1, 20 do if window.boot then window:bootSkip() end end
end
local names = {}
for name in pairs(window.views) do names[#names + 1] = name end
table.sort(names)
if P9_TAB then window:activate(P9_TAB) end
say("tabs", table.concat(names, " "), "showing", P9_TAB or "first", "window", window:getWidth() .. "x" .. window:getHeight())
