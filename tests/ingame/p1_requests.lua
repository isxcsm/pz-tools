-- P1: the request candidates (the groups of RequestGroups.lua the game has) and the house loot kinds from the game's
-- loot tables (NUMBERS 12 survey), the scan's cost, and a week's list with its groups' names.
-- Rebuilds the table in memory only for the timing (the save's table is put back). Changes nothing else.
-- Prints "[p1req]" lines.
RUN("p1_lib.lua")
local OA = OperationAcorn
local say = P1T.say("p1req")
local record = P1T.record()

local t0 = P1T.ms()
local made = OA.Requests.scan()
local took = P1T.ms() - t0
if not P1T.check(say, "scan returned a table", made ~= nil) then return end
say("scan took ms", took, "candidates", made.n, "house loot kinds", OA.Requests.kindCount(made))
P1T.check(say, "scan is under 2 seconds (it runs once per world)", took < 2000, took)

-- NUMBERS 12 lists the house loot kinds per category (the survey counts by category, before the TINT grouping
-- and the rejections); ours are grouped by base type and only accepted kinds, so they sit somewhat below.
local survey = { A = 316, B = 385, C = 129, D = 356, E = 255, F = 131, G = 48, H = 218, I = 22, J = 49 }
for _, letter in ipairs(OA.Categories.LETTERS) do
    local n = made.total[letter] or 0
    local want = survey[letter]
    say("category", letter, "kinds", n, want and ("survey " .. want) or "")
    if want then P1T.check(say, "category " .. letter .. " is in the survey's range", n > 0 and n <= math.max(want * 1.1, want + 5), n) end
end

-- The world's table is the same shape (the save may have an older scan).
local world = OA.Requests.data()
P1T.check(say, "the world table exists", world ~= nil and world.n and world.n > 0, world and world.n)
if world then
    P1T.check(say, "the world table matches a fresh scan", world.n == made.n, world.n .. " / " .. made.n)
end

-- Every group the tool made is a candidate: the game has a kind of each.
P1T.check(say, "every group is a candidate", made.n == #OA.RequestGroups, made.n .. " / " .. #OA.RequestGroups)
local bands = { common = 0, normal = 0, rare = 0 }
for _, s in ipairs(made.score) do bands[OA.Requests.band(s)] = bands[OA.Requests.band(s)] + 1 end
say("bands: common", bands.common, "normal", bands.normal, "rare", bands.rare)

if record then
    local items = OA.Requests.list(record)
    local want = OA.Trust.rewards(record).requestCount
    say("this week's list (" .. #items .. " of " .. want .. "):")
    for _, t in ipairs(items) do
        local e = OA.Requests.entry(record, t)
        say("  ", t, OA.Requests.nameOf(t), "kinds", #OA.Requests.members(t), "band", e.band, "price", e.price,
            "qty", e.qty, "used", e.used)
    end
    P1T.check(say, "the list has the rewarded count", #items == want, #items .. " / " .. want)
    local seen, dup = {}, false
    for _, t in ipairs(items) do if seen[t] then dup = true end seen[t] = true end
    P1T.check(say, "no group twice", not dup)
    local again = OA.Requests.list(record)
    P1T.check(say, "asking again gives the same list", again == items or table.concat(again, ",") == table.concat(items, ","))
else
    say("no record yet: the week's list was not checked")
end
say("done")
