-- P1: the building watch. Stand inside a house (and run it again after opening some containers): prints the
-- building's key, how many containers it has, how many were opened, and whether every square is loaded. Compares
-- the PZ Extension API path with the game's own (vanilla) path. Changes nothing but the watch's own cache.
-- Prints "[p1bld]" lines.
RUN("p1_lib.lua")
local OA = OperationAcorn
local say = P1T.say("p1bld")
local record, player = P1T.record()
local square = player:getCurrentSquare()
local room = square and square:getRoom()
if not room then say("stand inside a building first"); return end

local api = OA.api()
say("PZ Extension API", api and "present" or "absent", "buildings", api and api.buildings and "yes" or "no")
OA.Buildings.reset()
-- the watch counts BUDGET squares a look: look until it has the whole building (or 400 looks), timing each look
local key, searched, total, complete
local looks, worst = 0, 0
repeat
    local t0 = P1T.ms()
    key, searched, total, complete = OA.Buildings.tick(player)
    worst = math.max(worst, P1T.ms() - t0)
    looks = looks + 1
until not key or complete or looks >= 400
say("watch", tostring(key), "searched", tostring(searched), "of", tostring(total), "complete", tostring(complete),
    "looks", looks, "slowest look ms", worst)
P1T.check(say, "a building is found", key ~= nil)
if not key then return end
P1T.check(say, "no look takes long (a part at a time)", worst <= 16, worst)
local t0 = P1T.ms()
local _, searched2 = OA.Buildings.tick(player)
local again = P1T.ms() - t0
say("one more look ms", again, "searched", searched2)
P1T.check(say, "a look at a counted building is cheap", again <= 5, again)

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
    say("buildings counted in the codex", OA.Codex.section(record).nb)
end
say("open another container here and run this again: searched should go up by one")
