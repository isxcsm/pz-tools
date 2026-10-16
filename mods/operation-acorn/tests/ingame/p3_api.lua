-- P3: the adapter to the extension API. Declares the character's values and prints, per point, what was declared and
-- the API's status for it ("applied" is working; "planned" or "partial" means the node's tooltip says it needs PZ Extension API).
-- Setup: PZ Extension API on (with the formulas area). Gives the character points in the record: use a throwaway save.
-- Prints "[p3api]" lines.
RUN("p3_lib.lua")
local OA = OperationAcorn
local Effects = OA.Upgrades.Effects
local Rules = OA.Upgrades.Rules
local say = P3T.say("p3api")
local record, player, u = P3T.record()

local api = OA.api()
P3T.check(say, "the extension API is there", api ~= nil)
P3T.check(say, "the mod's handle", OA.handle() ~= nil)
if not api then return end
local points = api.formulas and api.formulas.points and api.formulas.points() or {}
local count = 0
for _ in pairs(points) do count = count + 1 end
say("API points", count)
for _, name in pairs(Effects.POINTS) do
    P3T.check(say, "the API has point " .. name, points[name] ~= nil, points[name])
end

-- A character with a little of everything
P3T.points(u, "scout", 12)
P3T.points(u, "load", 12)
P3T.points(u, "survival", 12)
local ids = { "sight", "sight", "sight", "night", "night", "night", "rich", "rich", "rich",
    "overload", "overload", "runSpeed", "runSpeed", "materials", "materials", "materials", "furniture", "keyring",
    "stiff", "stiff", "stiff", "resist", "resist", "resist" }
for _, id in ipairs(ids) do
    local ok, why = P3T.buy(u, id)
    if not ok then say("could not buy", id, why) end
end
Effects.reset()
local n = Effects.apply(record)
say("declarations made", n)
for name, value in pairs(Effects.declared()) do
    local text = tostring(value)
    if type(value) == "table" then
        local parts = {}
        for k, v in pairs(value) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
        text = "{" .. table.concat(parts, ", ") .. "}"
    end
    say("declared", name, text, "status", tostring(api.formulas.points()[name]))
end
for _, id in ipairs({ "sight", "rich", "night", "overload", "materials", "stiff", "resist", "walk" }) do
    say("node status", id, tostring((Effects.status(id))))
end
P3T.check(say, "the capacity key is declared", Effects.declared()["capacity.modDataKey"] == "OA_Capacity")
P3T.check(say, "the hidden zombie fix is declared (option on, no visibility mod)",
    Effects.declared()["vision.hiddenZombieFix"] == true or not Effects.hiddenZombieFix(),
    "visibility mod active: " .. tostring(Effects.visibilityModActive()))
-- the carry efficiency of a log (material)
local log = P3T.give("Base.Log")
if log then
    say("log efficiency (45 percent from the materials node)", Effects.efficiencyOf(log), "weight",
        log:getActualWeight(), "api factor", api.formulas.efficiency and api.formulas.efficiency(log) or "-")
end
