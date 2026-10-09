-- The senses and the plan on the research screen.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Api"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules
local Sense = OA.Upgrades.Sense
local Plan = OA.Upgrades.Plan

local function fresh() return Rules.blank() end

local function inject(u, tree, n)
    for _ = 1, n do Rules.inject(u, tree) end
end

local function buy(u, ids, ctx)
    ctx = ctx or { fragments = 0 }
    for _, id in ipairs(ids) do
        local ok, why = Rules.buy(u, id, ctx)
        if not ok then error("could not buy " .. id .. ": " .. tostring(why), 2) end
    end
end

local function rep(id, n)
    local list = {}
    for _ = 1, n do list[#list + 1] = id end
    return list
end

local function cat(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, v in ipairs(list) do out[#out + 1] = v end
    end
    return out
end

local SCOUT = cat(rep("sight", 3), rep("sixth", 2), rep("alarm", 1), rep("night", 3), rep("rich", 3), rep("ledger", 3),
    rep("sense", 2), rep("keen", 3), rep("ammo", 2), rep("sensePlus", 3))

test("sense: hearing shares follow the vanilla traits", function()
    eq(Sense.hearing(true, true, false), 0)
    eq(Sense.hearing(false, true, false), 1.2)
    eq(Sense.hearing(false, false, true), 0.8)
    eq(Sense.hearing(false, false, false), 1)
end)

test("sense: a noise heard again keeps one entry; the oldest goes past the cap; run-out ones leave", function()
    local list = {}
    Sense.heard(list, "car", "vehicle", 1, 2, 0, 0, 1000, 3)
    Sense.heard(list, "car", "alarm", 5, 6, 0, 500, 3000, 3)
    eq(#list, 1)
    eq(list[1].kind, "alarm")
    eq(list[1].x, 5)
    eq(list[1].untilMs, 3000)
    Sense.heard(list, "radio", "device", 0, 0, 0, 600, 2000, 3)
    Sense.heard(list, "bang", "noise", 0, 0, 0, 700, 2000, 3)
    Sense.heard(list, "tv", "device", 0, 0, 0, 800, 2000, 3)
    eq(#list, 3)
    eq(list[1].key, "radio")
    eq(list[3].key, "tv")
    -- the TV heard again lasts to 3000: at 2500 it is left besides the new one
    Sense.heard(list, "tv", "device", 0, 0, 0, 900, 3000, 3)
    Sense.heard(list, "gen", "device", 0, 0, 0, 2500, 4000, 3)
    eq(#list, 2)
    eq(list[1].key, "tv")
    eq(list[2].key, "gen")
end)

test("sense sectors: twelve around the screen, opposite worlds opposite sectors", function()
    local right = Sense.sector(1, -1)
    local left = Sense.sector(-1, 1)
    local down = Sense.sector(1, 1)
    local up = Sense.sector(-1, -1)
    eq((left + 6 - 1) % 12 + 1, right, "left and right are half a ring apart")
    eq((up + 6 - 1) % 12 + 1, down)
    truthy(right ~= left and up ~= down)
    for s = 1, 12 do
        local x, y = Sense.direction(s)
        near(x * x + y * y, 1, 1e-9)
    end
    eq(Sense.sector(0, 0), 1)
end)

test("sense scan groups zombies by sector and keeps the nearest", function()
    local list = {
        { x = 5, y = 0, z = 0 }, { x = 8, y = 0, z = 0, thump = true }, { x = 0, y = -6, z = 0 },
        { x = 50, y = 0, z = 0 }, { x = 3, y = 0, z = 2 },
    }
    local out = Sense.scan(list, 0, 0, 0, 20, false)
    local s = Sense.sector(5, 0)
    eq(out[s].n, 2)
    near(out[s].d, 5, 1e-9)
    eq(out[s].thump, true)
    local total = 0
    for _, e in pairs(out) do total = total + e.n end
    eq(total, 3, "one is too far, one is on another floor")
    local all = Sense.scan(list, 0, 0, 0, 20, true)
    local sum = 0
    for _, e in pairs(all) do sum = sum + e.n end
    eq(sum, 4, "the advanced rank counts other floors")
    local east = all[Sense.sector(3, 0)]
    eq(east.up, true, "the one two floors up marks its sector")
    eq(east.down, nil)
    eq(out[s].up, nil, "nothing above on the plain scan")
end)

test("sense hunch: within the radius, on this floor or beside it", function()
    eq(Sense.hunch({ { x = 5, y = 0, z = 0 } }, 0, 0, 0, 8), true)
    eq(Sense.hunch({ { x = 9, y = 0, z = 0 } }, 0, 0, 0, 8), false)
    eq(Sense.hunch({ { x = 3, y = 0, z = 1 } }, 0, 0, 0, 8), true)
    eq(Sense.hunch({ { x = 3, y = 0, z = 2 } }, 0, 0, 0, 8), false)
end)

test("presence sense works crouched; the advanced node widens when", function()
    local u = fresh()
    inject(u, "scout", 14)
    eq(Sense.active(u, true, false, false), false, "no node")
    buy(u, cat(rep("sight", 3), rep("sixth", 2), rep("alarm", 1), rep("sense", 2)))
    eq(Sense.active(u, true, false, false), true, "crouched")
    eq(Sense.active(u, false, false, false), false, "standing")
    eq(Sense.active(u, true, true, false), false, "running")
    eq(Sense.distance(u), true)
    eq(Sense.extended(u), false)
    buy(u, cat(rep("night", 3), rep("rich", 1), rep("ledger", 1), rep("sensePlus", 1)))
    eq(Sense.active(u, false, false, false), true, "upright at advanced rank 1")
    eq(Sense.active(u, false, true, false), false)
end)

test("plan: adding, removing and dependants", function()
    local u = fresh()
    inject(u, "scout", 6)
    local steps = {}
    for _ = 1, 3 do steps = Plan.add(u, steps, "sight", nil, 0) end
    eq(#steps, 3)
    local again, why = Plan.add(u, steps, "sight", nil, 0)
    eq(again, nil)
    eq(why, "maxed")
    steps = Plan.add(u, steps, "rich", nil, 0)
    eq(#steps, 4, "the row opens on the plan's own points")
    local removed = Plan.remove(u, steps, "sight", 0)
    eq(#removed, 2, "taking a sight back drops the step that needed the row")
    local sim, _, used = Plan.simulate(u, steps, 0)
    eq(Rules.rank(sim, "rich"), 1)
    eq(used, 0)
    eq(Plan.counts(steps).sight, 3)
    local spent = Plan.spent(u, sim)
    eq(spent.scout, 4)
    eq(spent.board, 0)
end)

test("plan: a capstone in the plan uses a fragment", function()
    local u = fresh()
    inject(u, "scout", 26)
    buy(u, SCOUT)
    local steps = Plan.add(u, {}, "nightEye", nil, 1)
    truthy(steps)
    local _, _, used = Plan.simulate(u, steps, 1)
    eq(used, 1)
    local none, why = Plan.add(u, {}, "nightEye", nil, 0)
    eq(none, nil)
    eq(why, "fragment")
end)
