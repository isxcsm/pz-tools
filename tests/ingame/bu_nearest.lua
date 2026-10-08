-- The water policy (BU.POLICY.water, "nearest"; "fullest" where the API has no "nearest"), drawn for real at the tower
-- panel (ModData BUTOWER, a building of many floors): two vanilla rain collector barrels connected to it, one on the
-- ground floor and one a floor up, each its floor's network's, the upper one the lower one's parent. A draw on the
-- ground floor's network takes from its own barrel first though the upper one is fuller ("fullest": the upper one);
-- the upper one at least 95 percent full gives first (rain before it spills over); the ground floor's barrel empty,
-- the draw goes on up. Its other water producers are set aside meanwhile, "water only from above" off; all put back
-- and the barrels taken away. "[bunear]" lines, each check "ok" or "BAD", ending with "done".
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Changes, Networks, Water = BU.Store, BU.Changes, BU.Networks, BU.Water
local say = BUT.say("bunear")
local function check(what, got, want) say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want)) end

local main = Store.get(ModData.getOrCreate("BUTOWER").panel)
local api = BU.api()
if not main or not api then say("BAD no tower panel or no API"); return end
local page = SandboxVars.BuildingUtilities
local aboveWas = page.WaterFromAboveOnly
page.WaterFromAboveOnly = false
Changes.applyShape()
local kept = main.water.producers
main.water.producers = {}
Networks.setProducers(main, "water")

-- A free square of the building's on a floor, near the box.
local function freeOn(z)
    return BUT.square(main.x, main.y, z, 1, 20, function(q)
        return q:getObjects():size() == 1 and q:isFree(false) and q:getMovingObjects():size() == 0
    end)
end
local barrels = {}
for _, z in ipairs({ 0, 1 }) do
    local q = freeOn(z)
    if q then
        local sprite = "carpentry_02_54"
        local barrel = IsoThumpable.new(getCell(), q, sprite, false, {})
        local info = SpriteConfigManager.getObjectInfoFromSprite(sprite)
        GameEntityFactory.CreateIsoObjectEntity(barrel, info:getScript():getParent(), true)
        q:AddSpecialObject(barrel)
        barrels[#barrels + 1] = barrel
        Changes.connectProducer(main, "water", q:getX(), q:getY(), z, true)
    else
        say("BAD no free square on floor", z)
    end
end

if #barrels == 2 then
    local low, high = barrels[1]:getFluidContainer(), barrels[2]:getFluidContainer()
    local lowId = Water.networkId(main, Water.FIRST, 0)
    local policy = Networks.waterPolicy()
    local parent
    for _, network in ipairs(Water.layout(main)) do if network.id == lowId then parent = network.parent end end
    say("policy", policy, "ground floor network", lowId, "parent", tostring(parent))
    check("the floor up's network is the parent", parent, Water.networkId(main, Water.FIRST, 1))
    local function fill(container, share)
        container:Empty()
        container:addFluid(FluidType.Water, container:getCapacity() * share)
    end
    -- Which barrel a one-litre draw took from.
    local function drawFrom()
        local a, b = low:getAmount(), high:getAmount()
        local ok, drawn = pcall(api.networks.draw, BU.handle(), lowId, 1)
        if not ok then say("BAD draw failed", tostring(drawn)); return "none" end
        local fromLow, fromHigh = a - low:getAmount() > 0.001, b - high:getAmount() > 0.001
        return fromLow and fromHigh and "both" or fromLow and "own" or fromHigh and "above" or "none"
    end
    fill(low, 0.4)
    fill(high, 0.8)
    check("own floor's barrel first, the one above fuller", drawFrom(), policy == "nearest" and "own" or "above")
    fill(high, 0.97)
    check("the one above at 97 percent gives first", drawFrom(), "above")
    fill(low, 0)
    fill(high, 0.8)
    check("own floor's empty: on up", drawFrom(), "above")
    check("the policy asked for", policy, BU.POLICY.water)
end

-- Put back.
for _, barrel in ipairs(barrels) do
    local q = barrel:getSquare()
    Changes.disconnectProducer(main, "water", q:getX(), q:getY(), q:getZ())
    q:transmitRemoveItemFromSquare(barrel)
end
main.water.producers = kept
Networks.setProducers(main, "water")
page.WaterFromAboveOnly = aboveWas
Changes.applyShape()
say("done")
