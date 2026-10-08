-- P1: the building watch. Stand inside a house (and run it again after opening some containers): prints the
-- building's key, how many containers it has, how many were opened, and whether every square is loaded. Compares
-- the PZ Tools API path with the game's own (vanilla) path. Changes nothing but the watch's own cache.
-- Prints "[p1bld]" lines.
RUN("p1_lib.lua")
local OA = OperationAcorn
local say = P1T.say("p1bld")
local record, player = P1T.record()
local square = player:getCurrentSquare()
local room = square and square:getRoom()
if not room then say("stand inside a building first"); return end

local api = OA.api()
say("PZ Tools API", api and "present" or "absent", "buildings", api and api.buildings and "yes" or "no")
OA.Buildings.reset()
local t0 = P1T.ms()
local key, searched, total, complete = OA.Buildings.tick(player)
local first = P1T.ms() - t0
say("tick", tostring(key), "searched", tostring(searched), "of", tostring(total), "complete", tostring(complete),
    "first look ms", first)
P1T.check(say, "a building is found", key ~= nil)
if not key then return end
t0 = P1T.ms()
local _, searched2 = OA.Buildings.tick(player)
local second = P1T.ms() - t0
say("second look ms", second, "searched", searched2)
P1T.check(say, "the second look is no dearer than the scan", second <= math.max(first, 1))

-- The vanilla path, for comparison (the scan with the API hidden).
if api then
    local saved = OA.api
    OA.api = function() return nil end
    local ok, scanned = pcall(OA.Buildings.scan, square, room)
    OA.api = saved
    if ok and scanned then
        say("vanilla path: key", scanned.key, "containers", #scanned.containers, "searched",
            OA.Buildings.searched(scanned.containers), "complete", tostring(scanned.complete))
        P1T.check(say, "both paths count about the same containers", math.abs(#scanned.containers - total) <= 2,
            #scanned.containers .. " vs " .. total)
    else
        say("vanilla path failed or found no building", tostring(scanned))
    end
end

if record then
    local s, t = OA.Codex.buildingProgress(record, key)
    say("Codex.buildingProgress", tostring(s), tostring(t))
    say("buildings counted in the codex", OA.Codex.section(record).nb)
end
say("open another container here and run this again: searched should go up by one")
