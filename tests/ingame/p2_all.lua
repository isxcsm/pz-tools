-- P2: runs the object checks, then the first-supply and flow checks, one after another. Use a throwaway save, a
-- single-player world with the mod and PZ Tools on, one character with a record, open ground (a clear patch of about
-- 15 x 15) east of the character, no roof. Afterwards call P2_CLEAN().
-- Not scripted (do by hand): the terminal window in the game (all six tabs, a tab from another part, the shop's
-- choices and kit targets, the confirm dialogs), the placement cursor (green and red squares around a box, the
-- terminal turning to face you), carrying with both hands, the right-click menus, the tooltip line on items, the
-- estimate panel beside an open box, the unseal action with and without a crowbar, the helicopter sound passing over,
-- the crate falling on its parachute, the smoke and the world map mark, reading the manifest and the manual, a
-- sledgehammer on a box, a generator turning the terminal's screen on.
local files = { "p2_objects.lua", "p2_first.lua", "p2_flow.lua" }
RUN("p2_lib.lua")
for _, file in ipairs(files) do
    print("[p2all] ---- " .. file)
    local ok, err = pcall(RUN, file)
    if not ok then print("[p2all] ERROR in " .. file .. ": " .. tostring(err)) end
end
print("[p2all] finished; search the log for BAD and ERROR, then call P2_CLEAN()")
