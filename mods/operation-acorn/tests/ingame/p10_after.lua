-- P10 after a save and a reload: the checks that compare with what the first run wrote before it (p10_kits_after.lua,
-- p10_state_after.lua), one after the other. Run it after `pzdev reload` (or a save and a load) following p10_all.lua.
-- Each ends with "[p10x] end: N BAD"; the whole with "[p10all] done: N BAD in M areas".
RUN("p10_lib.lua")
P10T.runAll({ "p10_kits_after.lua", "p10_state_after.lua" })
