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

test("sense: a noise heard again keeps one entry; past the cap the one running out first goes, alarms last", function()
    local list = {}
    local _, new = Sense.heard(list, "car", "vehicle", 1, 2, 0, 0, 1000, 3)
    eq(new, true)
    _, new = Sense.heard(list, "car", "alarm", 5, 6, 0, 500, 3000, 3)
    eq(new, false, "the same source again")
    eq(#list, 1)
    eq(list[1].kind, "alarm")
    eq(list[1].x, 5)
    eq(list[1].untilMs, 3000)
    Sense.heard(list, "radio", "device", 0, 0, 0, 600, 2100, 3)
    Sense.heard(list, "bang", "noise", 0, 0, 0, 700, 2000, 3)
    Sense.heard(list, "tv", "device", 0, 0, 0, 800, 2200, 3)
    eq(#list, 3)
    eq(list[1].key, "car", "the alarm heard first stays though it is the oldest")
    eq(list[2].key, "radio")
    eq(list[3].key, "tv", "the bang, closest to running out, went")
    -- the TV heard again lasts to 3000: at 2500 the radio has run out
    Sense.heard(list, "tv", "device", 0, 0, 0, 900, 3000, 3)
    Sense.heard(list, "gen", "device", 0, 0, 0, 2500, 4000, 3)
    eq(#list, 3)
    eq(list[1].key, "car")
    eq(list[2].key, "tv")
    eq(list[3].key, "gen")
    -- a list of alarms only: the one running out first goes
    local alarms = {}
    Sense.heard(alarms, "a", "alarm", 0, 0, 0, 0, 5000, 2)
    Sense.heard(alarms, "b", "alarm", 0, 0, 0, 0, 4000, 2)
    Sense.heard(alarms, "c", "alarm", 0, 0, 0, 0, 6000, 2)
    eq(alarms[1].key, "a")
    eq(alarms[2].key, "c")
end)

test("sense: screen directions and distance bands", function()
    local x, y = Sense.screen(1, -1)
    near(x, 1, 1e-9, "world north-east is the screen's right")
    near(y, 0, 1e-9)
    x, y = Sense.screen(1, 1)
    near(x, 0, 1e-9, "world south-east is the screen's bottom")
    near(y, 1, 1e-9)
    x, y = Sense.screen(3, 0)
    near(x * x + y * y, 1, 1e-9)
    truthy(x > 0 and y > 0, "east is down right")
    x, y = Sense.screen(0, 0)
    eq(x, -1)
    eq(y, 0)
    eq(Sense.band(0), 1)
    eq(Sense.band(Sense.NEAR - 0.01), 1)
    eq(Sense.band(Sense.NEAR), 2)
    eq(Sense.band(Sense.MID - 0.01), 2)
    eq(Sense.band(Sense.MID), 3)
    eq(Sense.band(600), 3)
end)

local function total(marks)
    local n = 0
    for _, m in ipairs(marks) do n = n + m.n end
    return n
end

test("sense scan: one mark a way, nearest first, flags of everyone in it", function()
    local list = {
        { x = 5, y = 0, z = 0 }, { x = 8, y = 0.5, z = 0, thump = true }, { x = 0, y = -6, z = 0 },
        { x = 50, y = 0, z = 0 }, { x = 3, y = 0, z = 2 },
    }
    local out = Sense.scan(list, 0, 0, 0, 20, false)
    eq(#out, 2, "east and north")
    eq(out[1].n, 2, "the two east of the character are one mark")
    near(out[1].d, 5, 1e-9)
    near(out[1].wx, 1, 1e-9, "pointing at its nearest zombie")
    near(out[1].wy, 0, 1e-9)
    eq(out[1].thump, true, "the farther one beating on something marks it")
    eq(out[2].n, 1)
    near(out[2].d, 6, 1e-9)
    eq(out[2].thump, false)
    eq(total(out), 3, "one is too far, one is on another floor")
    local all = Sense.scan(list, 0, 0, 0, 20, true)
    eq(total(all), 4, "the advanced rank counts other floors")
    eq(all[1].n, 3)
    near(all[1].d, 3, 1e-9, "the one two floors up is the nearest east")
    eq(all[1].up, true, "the one two floors up marks its way")
    eq(all[1].down, nil)
    eq(out[1].up, nil, "nothing above on the plain scan")
end)

test("sense scan: ways closer than the merge angle are one mark; at most eight", function()
    -- two zombies 20 degrees apart on the screen are one mark, 40 degrees apart two
    local function at(deg, d)
        -- a world offset whose screen direction is `deg` (screen x right, y down)
        local sx, sy = math.cos(math.rad(deg)), math.sin(math.rad(deg))
        -- screen (sx, sy) = (dx - dy, (dx + dy) / 2): dx = sy + sx / 2, dy = sy - sx / 2
        local dx, dy = sy + sx / 2, sy - sx / 2
        local len = math.sqrt(dx * dx + dy * dy)
        return { x = dx / len * d, y = dy / len * d, z = 0 }
    end
    eq(#Sense.scan({ at(0, 5), at(20, 6) }, 0, 0, 0, 20, false), 1)
    eq(#Sense.scan({ at(0, 5), at(40, 6) }, 0, 0, 0, 20, false), 2)
    local ring = {}
    for k = 0, 23 do ring[#ring + 1] = at(k * 15, 2 + k * 0.5) end
    local out = Sense.scan(ring, 0, 0, 0, 20, false)
    eq(#out, Sense.ZOMBIE_MARKS, "a whole ring is eight marks")
    eq(total(out), 24, "every zombie counts in some mark")
    for i = 1, #out do
        for j = i + 1, #out do
            truthy(out[i].sx * out[j].sx + out[i].sy * out[j].sy < Sense.MERGE_COS, "no two marks within the angle")
        end
    end
    local zero = Sense.scan({ { x = 0, y = 0, z = 0 } }, 0, 0, 0, 20, false)
    eq(#zero, 1, "a zombie on the character's tile still has a way")
    near(zero[1].wx * zero[1].wx + zero[1].wy * zero[1].wy, 1, 1e-9)
end)

test("sense marks: alarms first, merged by way within a distance band, four at most, run-out ones gone", function()
    local sounds = {
        { kind = "noise", x = 3, y = -3, z = 0, untilMs = 2000 },     -- right, near
        { kind = "device", x = 4, y = -3.5, z = 0, untilMs = 3000 },  -- right, near: joins the noise
        { kind = "alarm", x = 40, y = -40, z = 0, untilMs = 1500 },   -- right, far: its own band
        { kind = "vehicle", x = -5, y = 5, z = 0, untilMs = 2500 },   -- left, near
        { kind = "noise", x = 5.5, y = 5.5, z = 0, untilMs = 2500 },  -- down, near
        { kind = "noise", x = -6, y = -6, z = 0, untilMs = 2500 },    -- up, near: past the cap
        { kind = "alarm", x = 0, y = 20, z = 0, untilMs = 900 },      -- run out
    }
    local out = {}
    Sense.marks(sounds, 0, 0, 1000, out)
    eq(#out, Sense.NOISE_MARKS)
    eq(out[1].kind, "alarm", "the alarm first, far as it is")
    eq(out[1].band, 3)
    eq(out[1].n, 1)
    eq(out[2].kind, "noise", "then the nearest")
    eq(out[2].band, 1)
    eq(out[2].n, 2, "the radio beside it is the same mark")
    eq(out[2].untilMs, 3000, "it lasts while the radio does")
    eq(out[3].kind, "vehicle")
    eq(out[4].kind, "noise")
    eq(out[4].y, 5.5)
    -- the table is reused: later, fewer marks leave no stale ones behind
    local same = out[1]
    Sense.marks(sounds, 0, 0, 2600, out)
    eq(#out, 1, "only the radio is left")
    eq(out[1], same, "the mark tables are reused")
    eq(out[1].kind, "device")
    Sense.marks(sounds, 0, 0, 5000, out)
    eq(#out, 0)
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
