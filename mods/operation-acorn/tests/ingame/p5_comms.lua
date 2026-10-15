-- P5 (PLAN 3단계): a call played in the comms tab, to look at its pacing. P5_CALL (an entry id, else "S1") and
-- P5_TIER (else 1). Opens a terminal within reach (else puts one down beside the character), skips its boot, plays the call as a replay (nothing
-- is sent at its end) and logs each line's start and end with its characters. P5_CLEAN() gives the terminal its real power back.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p5comms")
local player = getPlayer()
local Objects, Things = OA.Trade.Objects, OA.Trade.Things
for _ = 1, 3 do getCore():doZoomScroll(0, 1) end
OA.Dev.console(false)
-- The window closes away from a terminal: a terminal within reach, else one put down beside the character.
local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
local at
for dy = -3, 3 do
    for dx = -3, 3 do
        local square = getCell():getGridSquare(px + dx, py + dy, pz)
        if not at and square and Objects.find(square, Objects.TERMINAL) then at = square end
    end
end
if not at then
    at = Objects.findClear(px + 1, py, 4)
    if not at or not Things.placeTerminal(player, at, "S", player:getInventory():AddItem("OperationAcorn.CommTerminal")) then
        say("no square for a terminal")
        return
    end
end
-- Without power the window closes too: this terminal counts as powered until P5_CLEAN().
local powered = Objects.powered
if not P5_CLEAN then
    Objects.powered = function(square, object)
        if square == at then return true end
        return powered(square, object)
    end
    P5_CLEAN = function()
        Objects.powered = powered
        P5_CLEAN = nil
    end
end
local window = OA.Terminal.open(player, at:getX(), at:getY(), at:getZ())
for _ = 1, 20 do if window.boot then window:bootSkip() end end
window:activate("comms")
local view = window.views.comms
local entry = OA.CommsData.BY_ID[P5_CALL or "S1"]
view:start(entry, P5_TIER or 1, true)
say("cps", OA.CommsScript.readCps(), "lines", #view.play.lines, "total", string.format("%.1f", view.play.tl.total))
for i, l in ipairs(view.play.tl.lines) do
    say(i, l.line.who, #l.line.chars, string.format("%.1f-%.1f (%.1f s)", l.t0, l.t1, l.t1 - l.t0), l.line.text)
end
