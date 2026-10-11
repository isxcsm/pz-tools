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
end)

test("sense cues: Visual Sounds' bands and distance from the character", function()
    eq(Sense.cue(0), 1, "on the character's square")
    eq(Sense.cue(1), 1)
    eq(Sense.cue(1.01), 2)
    eq(Sense.cue(4), 2)
    eq(Sense.cue(6.5), 3)
    eq(Sense.cue(20), 7)
    eq(Sense.cue(20.01), 8)
    eq(Sense.cue(600), 8)
    eq(Sense.offset(0), 0)
    near(Sense.offset(3), 75, 1e-9)
    near(Sense.offset(8), 400 / 3, 1e-9)
    truthy(Sense.offset(20) > Sense.offset(10) and Sense.offset(10) - Sense.offset(5) > Sense.offset(20) - Sense.offset(15),
        "further out, ever slower")
end)

test("sense: a full list keeps a zombie coming or striking over one groaning, and keeps when a sound was first heard", function()
    local list = {}
    Sense.heard(list, "a", "zombie", 0, 0, 0, 0, 2000, 2)
    Sense.heard(list, "b", "attack", 0, 0, 0, 10, 1000, 2)
    eq(list[1].born, 0)
    Sense.heard(list, "a", "zombie", 1, 1, 0, 500, 2500, 2)
    eq(list[1].born, 0, "heard again it does not come on again")
    Sense.heard(list, "c", "thump", 0, 0, 0, 600, 1900, 2)
    eq(#list, 2)
    eq(list[1].key, "b", "the strike stays though it runs out first")
    eq(list[2].key, "c", "the groan went for the zombie beating on a door")
    eq(list[2].born, 600)
end)

-- A plain zombie for Sense.voices.
local function zed(ref, x, y, z, hunt, attack)
    return { ref = ref, x = x, y = y, z = z or 0, hunt = hunt or false, attack = attack or false }
end

local function kinds(out)
    local list = {}
    for i, e in ipairs(out) do list[i] = e.key .. ":" .. e.kind end
    table.sort(list)
    return table.concat(list, ",")
end

test("sense voices: a zombie in reach makes a sound soon, then now and then; taking a target or striking at once", function()
    local memo, out = {}, {}
    local a, b, far, up = "a", "b", "far", "up"
    local function scan(now, list) return kinds(Sense.voices(list, memo, 0, 0, 0, 10, false, now, out)) end
    -- first seen: within FIRST_MS, spread by the order they came in
    local zs = { zed(a, 3, 0), zed(b, 0, 4), zed(far, 30, 0), zed(up, 2, 0, 1) }
    eq(scan(0, zs), "", "nothing at once")
    eq(scan(Sense.FIRST_MS, zs), "a:zombie,b:zombie", "both within the first spread; too far and another floor never")
    -- quiet until their time comes again (three quarters of voiceMs at the least)
    eq(scan(Sense.FIRST_MS + 300, zs), "")
    -- b takes a target: at once; then a strikes: at once
    zs[2] = zed(b, 0, 4, 0, true)
    eq(scan(Sense.FIRST_MS + 400, zs), "b:aggro")
    zs[1] = zed(a, 3, 0, 0, false, true)
    eq(scan(Sense.FIRST_MS + 600, zs), "a:attack")
    -- then each again within a quarter of voiceMs of its distance either way
    local t = Sense.FIRST_MS + 600 + Sense.voiceMs(3) * 1.25
    eq(scan(t, zs), "a:zombie,b:zombie")
    -- one out of reach is forgotten: back in reach it starts again
    eq(scan(t + 10, { zs[2] }), "")
    eq(memo.by[a], nil, "forgotten")
    eq(scan(t + 20, { zs[1] }), "")
    eq(scan(t + 20 + Sense.FIRST_MS, { zs[1] }), "a:zombie")
    -- the advanced rank hears other floors
    local memo2 = {}
    eq(kinds(Sense.voices({ zed(up, 2, 0, 1) }, memo2, 0, 0, 0, 10, true, Sense.FIRST_MS, {})), "")
end)

test("sense voices: a near zombie calls more often than a far one, as Visual Sounds' do", function()
    local memo, out = {}, {}
    local zs = { zed("near", 2, 0), zed("far", 9, 0) }
    local count = { near = 0, far = 0 }
    for now = 0, 60000, 500 do
        for _, e in ipairs(Sense.voices(zs, memo, 0, 0, 0, 10, false, now, out)) do count[e.key] = count[e.key] + 1 end
    end
    truthy(count.near > count.far * 1.8, "near " .. count.near .. ", far " .. count.far)
    truthy(count.near >= 60, "near about every look or two, was " .. count.near)
end)

test("sense voices: a crowd does not call at once", function()
    local memo, out = {}, {}
    local zs = {}
    for k = 1, 20 do zs[k] = zed({}, k % 5, math.floor(k / 5)) end
    local most = 0
    for now = 0, 30000, 500 do
        local n = #Sense.voices(zs, memo, 0, 0, 0, 10, false, now, out)
        if now > Sense.FIRST_MS and n > most then most = n end
    end
    truthy(most <= Sense.VOICES_PER_LOOK, "at most a few a half second, was " .. most)
end)

test("sense voices: past the groans a look allows, the rest wait; a strike is told at once", function()
    local memo, out = {}, {}
    local zs = {}
    -- far enough that none calls twice in these looks
    for k = 1, 10 do zs[k] = zed("z" .. k, 9, 0) end
    Sense.voices(zs, memo, 0, 0, 0, 10, false, 0, out)
    local heard = #Sense.voices(zs, memo, 0, 0, 0, 10, false, Sense.FIRST_MS, out)
    eq(heard, Sense.VOICES_PER_LOOK, "the first look after they came in")
    heard = heard + #Sense.voices(zs, memo, 0, 0, 0, 10, false, Sense.FIRST_MS + 500, out)
    heard = heard + #Sense.voices(zs, memo, 0, 0, 0, 10, false, Sense.FIRST_MS + 1000, out)
    eq(heard, 10, "the others on the next looks")
    zs[10] = zed("z10", 9, 0, 0, false, true)
    for k = 1, 9 do zs[k] = zed("z" .. k, 9, 0) end
    local strike = Sense.voices(zs, memo, 0, 0, 0, 10, false, Sense.FIRST_MS + 1500, out)
    eq(#strike, 1)
    eq(strike[1].kind, "attack")
end)

test("alarm reading: measured to a house's edge, near within the bound, told again only past the wider one", function()
    eq(Sense.toRect(5, 5, 0, 0, 10, 10), 0, "inside the house")
    eq(Sense.toRect(13, 5, 0, 0, 10, 10), 3, "beside a long wall, far from the middle")
    eq(Sense.toRect(13, 14, 0, 0, 10, 10), 5, "off a corner")
    eq(Sense.alarmOn(nil, true), false, "no alarm near")
    eq(Sense.alarmOn(Sense.ALARM_NEAR, false), true)
    eq(Sense.alarmOn(Sense.ALARM_NEAR + 0.5, false), false, "between the bounds it does not come on")
    eq(Sense.alarmOn(Sense.ALARM_NEAR + 0.5, true), true, "and does not go off")
    eq(Sense.alarmOn(Sense.ALARM_LEAVE + 0.1, true), false)
end)

test("sense hunch: unseen, within the radius, on this floor or beside it", function()
    eq(Sense.hunch({ { x = 5, y = 0, z = 0 } }, 0, 0, 0, 8), true)
    eq(Sense.hunch({ { x = 9, y = 0, z = 0 } }, 0, 0, 0, 8), false)
    eq(Sense.hunch({ { x = 3, y = 0, z = 1 } }, 0, 0, 0, 8), true)
    eq(Sense.hunch({ { x = 3, y = 0, z = 2 } }, 0, 0, 0, 8), false)
    eq(Sense.hunch({ { x = 3, y = 0, z = 0, seen = true } }, 0, 0, 0, 8), false, "one the character sees is no hunch")
    eq(Sense.hunch({ { x = 3, y = 0, z = 0, seen = true }, { x = 0, y = 4, z = 0, seen = false } }, 0, 0, 0, 8), true)
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
