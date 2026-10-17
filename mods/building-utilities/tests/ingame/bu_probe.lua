-- Where the mods' Lua time goes: every function of BU's and OA's tables wrapped with a timer (calls nested in others count
-- in both), until BUPROBE.report() prints the fifteen slowest in one call, with their totals, and puts the functions
-- back. For a stretch of play to look at (bu_walls.lua's rooms set, for one). "[buprobe]" lines.
local BU = BuildingUtilities
local say = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end print("[buprobe] " .. table.concat(t, " ")) end
if BUPROBE then BUPROBE.report() end
BUPROBE = { total = {}, most = {}, calls = {}, kept = {} }
local probe = BUPROBE
local modules = {}
for _, root in ipairs({ { "BU", BU }, { "OA", OperationAcorn } }) do
    if root[2] then
        for tableName, module in pairs(root[2]) do modules[root[1] .. "." .. tableName] = module end
    end
end
for tableName, module in pairs(modules) do
    if type(module) == "table" and tableName ~= "BU.Store" then
        for name, fn in pairs(module) do
            if type(fn) == "function" then
                local key = tableName .. "." .. name
                probe.kept[#probe.kept + 1] = { module, name, fn }
                local function finish(start, ...)
                    local took = getTimestampMs() - start
                    probe.total[key] = (probe.total[key] or 0) + took
                    probe.calls[key] = (probe.calls[key] or 0) + 1
                    if took > (probe.most[key] or 0) then probe.most[key] = took end
                    return ...
                end
                module[name] = function(...) return finish(getTimestampMs(), fn(...)) end
            end
        end
    end
end
function probe.report()
    for _, kept in ipairs(probe.kept) do kept[1][kept[2]] = kept[3] end
    local keys = {}
    for key in pairs(probe.total) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return (probe.most[a] or 0) > (probe.most[b] or 0) end)
    for i = 1, math.min(15, #keys) do
        local key = keys[i]
        say(key, "most", probe.most[key] or 0, "ms; all", probe.total[key], "ms over", probe.calls[key], "calls")
    end
    BUPROBE = nil
end
say("wrapped", #probe.kept, "functions")
