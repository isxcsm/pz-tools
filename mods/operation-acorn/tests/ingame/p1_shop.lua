-- P1: the shop. Prices and tiers for the record, the serum price curve, and every item type the catalog
-- names against the game's scripts (vanilla types must exist; this mod's types are made by other parts and are
-- listed when missing). Changes nothing.
-- Prints "[p1shop]" lines.
RUN("p1_lib.lua")
local OA = OperationAcorn
local say = P1T.say("p1shop")
local record = P1T.record()
local manager = getScriptManager()

local catalog = OA.Shop.catalog()
say("catalog entries", #catalog)
local missingVanilla, missingMod = {}, {}
local function checkType(t)
    if manager:FindItem(t) then return end
    if string.find(t, "^Base%.") then missingVanilla[t] = true else missingMod[t] = true end
end
for _, e in ipairs(catalog) do
    for _, g in ipairs(OA.Shop.choices(e) or e.give or {}) do checkType(g.type) end
    if e.give then for _, g in ipairs(e.give) do checkType(g.type) end end
end
local function listOf(set)
    local list = {}
    for t in pairs(set) do list[#list + 1] = t end
    table.sort(list)
    return list
end
local v, m = listOf(missingVanilla), listOf(missingMod)
P1T.check(say, "every vanilla type the catalog names exists", #v == 0, table.concat(v, " "))
say("types of this mod not found (made by the other parts; none is fine only once they are in):", #m,
    table.concat(m, " "))
say("seed choices", #OA.Shop.seedChoices())
P1T.check(say, "there are seed packets to choose from", #OA.Shop.seedChoices() > 0)

-- Every entry has a name in the language.
local noName = {}
for _, e in ipairs(catalog) do
    local key = OA.Shop.nameKey(e)
    if getText(key) == key then noName[#noName + 1] = e.id end
end
P1T.check(say, "every entry has a translated name", #noName == 0, table.concat(noName, " "))

-- Serum curve (NUMBERS 6): first 8000, 26th 8000 * 1.15^25 to the nearest 100, then straight up.
P1T.check(say, "first serum 8000", OA.Shop.serumPriceAt(1) == 8000, OA.Shop.serumPriceAt(1))
say("serum 2, 10, 26, 27:", OA.Shop.serumPriceAt(2), OA.Shop.serumPriceAt(10), OA.Shop.serumPriceAt(26),
    OA.Shop.serumPriceAt(27))
P1T.check(say, "serum 2 = 9200", OA.Shop.serumPriceAt(2) == 9200, OA.Shop.serumPriceAt(2))
P1T.check(say, "the curve rises", OA.Shop.serumPriceAt(27) > OA.Shop.serumPriceAt(26))

if not record then say("no record yet: the per-record rows were skipped"); return end
say("record tier", OA.Trust.tier(record), "stage", OA.Trust.rewards(record).stage, "discount",
    OA.Trust.rewards(record).discount)
for _, e in ipairs(catalog) do
    local count, why, opens = OA.Shop.available(e, record)
    local price = OA.Shop.price(e, record)
    say(string.format("%-20s tier %d price %-8s open %s %s%s", e.id, e.tier, tostring(price), tostring(count),
        why or "", opens and (" at " .. tostring(math.floor(opens))) or ""))
end
say("done")
