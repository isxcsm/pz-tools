-- Real time spent in the story's world work (OA.Stage, OA.Scene, OA.StageGame, OA.SceneGame, OA.Zombies's tables of
-- functions, wrapped once): each call over ST_SLOW ms (10) printed as it ends, with how deep it was called.
local OA = OperationAcorn
ST_SLOW = ST_SLOW or 10
if ST_TIMED then return end
ST_TIMED = true
local depth = 0
local function wrap(name, t)
    if type(t) ~= "table" then return end
    for k, f in pairs(t) do
        if type(f) == "function" then
            t[k] = function(...)
                depth = depth + 1
                local t0 = getTimestampMs()
                local r = { f(...) }
                local ms = getTimestampMs() - t0
                depth = depth - 1
                if ms >= ST_SLOW then print("[timing]", string.rep(".", depth) .. name .. "." .. k, ms .. " ms") end
                return unpack(r)
            end
        end
    end
end
wrap("Stage", OA.Stage)
wrap("Scene", OA.Scene)
wrap("StageGame", OA.StageGame)
wrap("SceneGame", OA.SceneGame)
wrap("ZombieMissions", OA.ZombieMissions)
wrap("Missions", OA.Missions)
print("[timing] wrapped")
