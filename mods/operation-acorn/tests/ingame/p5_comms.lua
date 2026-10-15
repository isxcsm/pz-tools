-- P5 (PLAN 3단계): a call played in the comms tab, to look at its pacing. P5_CALL (an entry id, else "S1") and
-- P5_TIER (else 1). Opens the terminal where the character stands, skips its boot, plays the call as a replay (nothing
-- is sent at its end) and logs each line's start and end with its characters.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p5comms")
local player = getPlayer()
for _ = 1, 3 do getCore():doZoomScroll(0, 1) end
local window = OA.Terminal.open(player, math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()))
for _ = 1, 20 do if window.boot then window:bootSkip() end end
window:activate("comms")
local view = window.views.comms
local entry = OA.CommsData.BY_ID[P5_CALL or "S1"]
view:start(entry, P5_TIER or 1, true)
say("cps", OA.CommsScript.readCps(), "lines", #view.play.lines, "total", string.format("%.1f", view.play.tl.total))
for i, l in ipairs(view.play.tl.lines) do
    say(i, l.line.who, #l.line.chars, string.format("%.1f-%.1f (%.1f s)", l.t0, l.t1, l.t1 - l.t0), l.line.text)
end
