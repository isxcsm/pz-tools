-- P4: the hallucination overlay. Runs a long glow with a site to the south-east. Look at the screen: light along all
-- four edges, the bottom edge staying longest; the game stays playable beneath it (move, click). Also checks the
-- ModOptions switch exists. For a short run with no site: OA.Hallucination.start(0, { long = false }).
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4hallu")
P4T.check(say, "the overlay module is loaded", OA.Hallucination ~= nil)
local opts = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions("OperationAcorn")
P4T.check(say, "the option is registered", opts ~= nil and opts:getOption("OA_Hallucination") ~= nil)
OA.Hallucination.start(0, { long = true, dx = 30, dy = 30 })
say("long run started (14 s)")
