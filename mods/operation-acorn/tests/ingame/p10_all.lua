-- P10 (round 3 in-game checks, E2E.md chapter 10): runs every area one after another from the frames (the areas that need
-- the game to run on, a teleport or a minute, go on while the next waits). An error in one is printed and the next runs.
-- Each area ends with "[p10x] end: N BAD"; the whole ends with "[p10all] done: N BAD in M areas" (pzdev check follows
-- that line). Order: survey, restock, dense, kits, state, grades, eggs, titles (the titles last: they take the longest
-- and want the screen free of the others'). About 6 minutes.
-- Setup: a throwaway save (BU_Spawn_E2E) with PZ Extension API, the Dev mod, the character on open ground with no zombies
-- near (it is sent to the three drop sites and to a dense place and back; god mode and invisibility are on during that).
-- Changes nothing that stays but what the reload check needs: the weapons of p10_kits, and the record p10_keep with the
-- world's P10X marks of p10_state.
-- After this: save, `pzdev reload`, then p10_after.lua (p10_kits_after.lua and p10_state_after.lua), which take them away.
-- Not scripted (by hand): the visuals and sounds of the titles (ink texture, sound moments, hold fade), the swing and shot
-- damage of the kit weapons, the map's circles drawn (colours and overlaps), the shop cards drawn, the terminal flow of the
-- survey call, a town searched through building by building in the game, the dense place cleared by real kills (see
-- the README of this folder and E2E.md 10.2, 10.3, 10.4).
RUN("p10_lib.lua")
P10T.runAll({ "p10_survey.lua", "p10_restock.lua", "p10_dense.lua", "p10_kits.lua", "p10_state.lua", "p10_grades.lua",
    "p10_eggs.lua", "p10_titles.lua" })
