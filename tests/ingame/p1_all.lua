-- P1: runs every economy check one after another; an error in one is printed and the next runs.
-- The ones that change the save run last. Use a throwaway save.
local files = { "p1_value.lua", "p1_requests.lua", "p1_shop.lua", "p1_buildings.lua", "p1_events.lua", "p1_pickup.lua",
    "p1_market.lua" }
RUN("p1_lib.lua")
for _, file in ipairs(files) do
    print("[p1all] ---- " .. file)
    local ok, err = pcall(RUN, file)
    if not ok then print("[p1all] ERROR in " .. file .. ": " .. tostring(err)) end
end
print("[p1all] finished; search the log for BAD and ERROR")
