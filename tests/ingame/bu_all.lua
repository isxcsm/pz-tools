-- Runs the checks of batches 0 and 2 to 6 and of the plan's batches 1 to 4 (bu_test18 to bu_test22) one after another; an error in one is printed and the next runs.
for _, name in ipairs({ "bu_test12.lua", "bu_test13.lua", "bu_test14.lua", "bu_test15.lua", "bu_test16.lua", "bu_test17.lua", "bu_test18.lua", "bu_test19.lua", "bu_test20.lua", "bu_test21.lua", "bu_test22.lua" }) do
    local ok, err = pcall(RUN, name)
    print("[buall] " .. name .. " " .. (ok and "done" or ("ERROR " .. tostring(err))))
end
