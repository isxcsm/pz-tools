-- P4: the hallucination overlay. Runs a long glow with a site to the south-east. Look at the screen: light along all
-- four edges, the bottom edge staying longest; the game stays playable beneath it (move, click). Also checks the
-- ModOptions switch exists. For a short run with no site: OA.Hallucination.start(0, { long = false }).
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4hallu")
P4T.check(say, "the overlay module is loaded", OA.Hallucination ~= nil)
local opts = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions("OperationAcorn")
P4T.check(say, "the option is registered", opts ~= nil and opts:getOption("OA_Hallucination") ~= nil)
-- one section for the mod: the research plan's key sits beside it (two create() calls made two, the last one won)
P4T.check(say, "the plan key is in the same section", opts ~= nil and opts:getOption("openPlan") ~= nil)
local sections = 0
for _, o in ipairs(PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.Data or {}) do
    if o.modOptionsID == "OperationAcorn" then sections = sections + 1 end
end
P4T.check(say, "the mod has one options section", sections == 1, sections)
OA.Hallucination.start(0, { long = true, dx = 30, dy = 30 })
say("long run started (14 s)")
