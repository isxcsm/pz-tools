-- P3: runs every upgrades check one after another; an error in one is printed and the next runs.
-- The ones that change the save run last. Use a throwaway save with PZ Extension API on and zombies near.
local files = { "p3_api.lua", "p3_serums.lua", "p3_plan.lua", "p3_window.lua", "p3_senses.lua", "p3_actions.lua",
    "p3_dash_carry.lua", "p3_bite.lua" }
RUN("p3_lib.lua")
for _, file in ipairs(files) do
    print("[p3all] ---- " .. file)
    local ok, err = pcall(RUN, file)
    if not ok then print("[p3all] ERROR in " .. file .. ": " .. tostring(err)) end
end
print("[p3all] finished; search the log for BAD and ERROR")
