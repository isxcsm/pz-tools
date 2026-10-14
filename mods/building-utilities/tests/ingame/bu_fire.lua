-- The fire sprinkler against the game's fire, at the test panel (bu_setup.lua): its tanks filled; one head put down in a
-- room of its building, one outside near it, both wired. Fires started (IsoFireManager.StartFire): in the room within
-- reach, in another room within reach when there is one, outside by the outside head. At the next game minute, after
-- the mod's own minute ran: the room's and the outside fire out, the other room's burning, 20 L gone a fire put out,
-- the heads showing their spray; the hung look where the square above blocks rain, the standing one where it does not.
-- "[bufire]" lines, each check "ok" or "BAD", "done" at the end. The fires still burning are put out then;
-- BUFIRE_CLEAN() takes the heads away.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Changes, Units, WaterUnits, Networks = BU.Store, BU.Changes, BU.Units, BU.WaterUnits, BU.Networks
local say = BUT.say("bufire")
local bad = 0
local function check(what, got, want)
    if got ~= want then bad = bad + 1 end
    say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want))
end

local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("BAD no panel"); return end
local cell = getCell()
local home = cell:getGridSquare(panel.x, panel.y, panel.z):getBuilding()

local function bare(q)
    return q ~= nil and q:isFree(false) and q:getMovingObjects():size() == 0 and q:getObjects():size() <= 2
        and not q:has(IsoFlagType.burning)
end

-- The room head: a bare square of a room of the panel's building, with a bare square of its room two off.
local roomFire, otherFire
local head = BUT.square(panel.x, panel.y, 0, 1, 12, function(q)
    if not bare(q) or q:getRoom() == nil or q:getBuilding() ~= home or not Units.canInstall("firesprinkler", q) then
        return false
    end
    for _, at in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }) do
        local f = cell:getGridSquare(q:getX() + at[1], q:getY() + at[2], 0)
        if bare(f) and f:getRoom() == q:getRoom() then roomFire = f; return true end
    end
    return false
end)
if not head then say("BAD no room square"); return end
for dx = -3, 3 do
    for dy = -3, 3 do
        local f = cell:getGridSquare(head:getX() + dx, head:getY() + dy, 0)
        if not otherFire and bare(f) and f:getRoom() ~= nil and f:getRoom() ~= head:getRoom() then otherFire = f end
    end
end
-- The outside head: a bare outside square near the panel, with a bare outside square two off.
local outsideFire
local outside = BUT.square(panel.x, panel.y, 0, 4, 16, function(q)
    if not BUT.freeOutside(q) or q:getRoom() ~= nil or not Units.canInstall("firesprinkler", q) then return false end
    local f = cell:getGridSquare(q:getX() + 2, q:getY(), 0)
    if f and BUT.freeOutside(f) and f:getRoom() == nil then outsideFire = f; return true end
    return false
end)
if not outside then say("BAD no outside square"); return end

BU.Dev.setWater(panel, 1)
local function held()
    local total = 0
    for _, network in ipairs(Networks.waterLayout(panel).networks) do
        local state = network.kind == "T" and Networks.waterState(network.id)
        if state then total = total + (state.amount or 0) end
    end
    return total
end

local heads = {}
for _, q in ipairs({ head, outside }) do
    local unit = Changes.installUnit("firesprinkler", q, WaterUnits.fireSprite(q, false))
    Changes.connectUnit(unit, panel, {})
    heads[#heads + 1] = unit
    local above = cell:getGridSquare(q:getX(), q:getY(), 1)
    local hung = above ~= nil and above:hasRainBlockingTile()
    say("head at", q:getX(), q:getY(), "room", tostring(q:getRoom() ~= nil), "above blocks rain", tostring(hung),
        "sprite", Units.object(unit):getSprite():getName())
    check("look", Units.object(unit):getSprite():getName(),
        hung and WaterUnits.FIRE_SPRITES.hung.waiting or WaterUnits.FIRE_SPRITES.standing.waiting)
end
check("room head hangs", Units.object(heads[1]):getSprite():getName(), WaterUnits.FIRE_SPRITES.hung.waiting)
check("outside head stands", Units.object(heads[2]):getSprite():getName(), WaterUnits.FIRE_SPRITES.standing.waiting)

BUFIRE_CLEAN = function()
    for _, unit in ipairs(heads) do Changes.removeUnit(unit) end
    print("[bufire] heads taken away")
end

local fires = { { roomFire, "room fire" }, { outsideFire, "outside fire" } }
if otherFire then fires[#fires + 1] = { otherFire, "other room's fire" } end
for _, f in ipairs(fires) do
    IsoFireManager.StartFire(cell, f[1], true, 100)
    say("started", f[2], f[1]:getX(), f[1]:getY(), "burning", tostring(f[1]:has(IsoFlagType.burning)))
end
if not otherFire then say("no other room within reach: skipped") end
local before = held()
say("water", BUT.litres(before, 1), "fires", IsoFireManager.FireStack:size())

local function putOutAll()
    local stack = IsoFireManager.FireStack
    for i = stack:size() - 1, 0, -1 do
        local q = stack:get(i):getSquare()
        if q then q:stopFire() end
    end
end

local function after()
    Events.EveryOneMinute.Remove(after)
    check("room fire out", roomFire:has(IsoFlagType.burning), false)
    check("outside fire out", outsideFire:has(IsoFlagType.burning), false)
    if otherFire then check("other room's fire burns", otherFire:has(IsoFlagType.burning), true) end
    local used = before - held()
    say("water used", BUT.litres(used, 1))
    check("20 L a fire", math.floor(used + 0.5) % 20, 0)
    check("at least two fires' water", used >= 39.5, true)
    for i, unit in ipairs(heads) do
        check("head " .. i .. " spraying", WaterUnits.spraying(unit), true)
        say("head", i, "sprite", Units.object(unit):getSprite():getName())
    end
    putOutAll()
    say("fires left", IsoFireManager.FireStack:size())
    say(bad == 0 and "done, all ok" or ("done, " .. bad .. " BAD"))
end
Events.EveryOneMinute.Add(after)
