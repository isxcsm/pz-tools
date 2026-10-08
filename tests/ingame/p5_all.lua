-- P5: runs every base-machine check one after another; an error in one is printed and the next runs. Single player,
-- open ground with a clear 20 x 20 patch east and south, no roof (the cistern). Use a throwaway save.
-- Not scripted (do by hand): put a machine down and pick it up from the world menu, open the machine window, install
-- and remove parts through its buttons, stand next to a generator that is on (power rule), move a machine with the
-- vanilla move tool (it must not be offered), drive away and come back (catch-up on chunk load).
local files = { "p5_place.lua", "p5_work.lua", "p5_special.lua" }
RUN("p5_lib.lua")
for _, file in ipairs(files) do
    print("[p5all] ---- " .. file)
    local ok, err = pcall(RUN, file)
    if not ok then print("[p5all] ERROR in " .. file .. ": " .. tostring(err)) end
end
print("[p5all] finished; search the log for BAD and ERROR, then call P5_CLEAN()")
