-- P4: runs the checks that need no walking. p4_missions, p4_missions_after, p4_sites and p4_map need standing at
-- places: run them by hand (see their headers).
RUN("p4_lib.lua")
for _, file in ipairs({ "p4_docs.lua" }) do
    print("[p4all] ---- " .. file)
    local ok, err = pcall(RUN, file)
    if not ok then print("[p4all] ERROR in " .. file .. ": " .. tostring(err)) end
end
print("[p4all] finished; search the log for BAD and ERROR")
