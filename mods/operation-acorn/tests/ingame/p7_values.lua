-- P7: the numeric adaptations as the game reads them (E2E.md 2). Each node is taken from nothing to its ranks and what the
-- game answers is measured against the same character with no ranks: the most carried, the inventory's limit and load
-- (materials, furniture, the keyring), a crate's capacity, the discomfort of worn gear, a muscle's strain, the poison
-- and endurance stats, the fatigue rate, a tree's slowdown, and the board's lines at many ranks (their caps). Points the
-- game cannot be asked from Lua (the vision cone, night sight, falls, loot, walking) are checked as the API combines
-- them against the node's value; night sight is looked at by hand at 2 a.m. The expected numbers are E2E.md's, not
-- the code's. At the end the record's upgrades are emptied and declared again (vanilla values).
-- Setup: single player, PZ Extension API on, a square free 2 east of the character. CHANGES THE SAVE: it
-- empties the character's inventory (all but what is worn) and the record's upgrades. Lines are tagged "[p7values]".
RUN("p3_lib.lua")
local OA = OperationAcorn
local Rules, Data, Effects = OA.Upgrades.Rules, OA.Upgrades.Data, OA.Upgrades.Effects
local say = P3T.say("p7values")
local function check(...) return P3T.check(say, ...) end
local near = P3T.near
local record, player, u = P3T.record()
local api = OA.api()
if not check("the extension API is there", api ~= nil and api.formulas ~= nil) then return end
local F = api.formulas

local inv = player:getInventory()
local function emptyInventory()
    local items = inv:getItems()
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if not player:isEquipped(item) and not player:isEquippedClothing(item) then inv:Remove(item) end
    end
end

-- Ranks from nothing: `ranks` = { id = n, ... }, then declared to the API.
local function setRanks(ranks)
    P3T.fresh(u)
    for id, n in pairs(ranks) do
        for _ = 1, n do
            local ok, why = P3T.buy(u, id)
            if not ok then say("could not buy", id, why) end
        end
    end
    Effects.apply(record)
end

local function load() return player:getInventoryWeight() end
-- What the worn clothes weigh: every load below is measured above it.
local worn = 0

local function section(name, fn)
    say("----", name)
    local ok, err = pcall(fn)
    if not ok then say("BAD", name, "error", tostring(err)) end
end

emptyInventory()
setRanks({})
worn = load()

section("튼튼한 어깨: the most carried and the inventory's limit", function()
    local max0, limit0 = player:getMaxWeight(), inv:getEffectiveCapacity(player)
    for r, add in ipairs({ 2, 4, 6, 8, 10 }) do
        setRanks({ capacity = r })
        check("rank " .. r .. ": most carried +" .. add, player:getMaxWeight() - max0 == add, player:getMaxWeight() - max0)
        local limit = math.floor(add * Data.LIMIT_PER_WEIGHT + 0.5)
        check("rank " .. r .. ": inventory limit +" .. limit, inv:getEffectiveCapacity(player) - limit0 == limit,
            inv:getEffectiveCapacity(player) - limit0)
    end
end)

section("자재 운반 / 숙련: materials lighter, the second replacing the first", function()
    emptyInventory()
    setRanks({})
    for _ = 1, 10 do inv:AddItem("Base.Plank") end
    local w0 = load() - worn
    say("info ten planks weigh", w0)
    for r, pct in ipairs({ 15, 30, 45 }) do
        setRanks({ materials = r })
        check("자재 운반 " .. r .. ": " .. pct .. "% lighter in carrying", near(load() - worn, w0 / (1 + pct / 100), 0.05), load() - worn)
    end
    for r, pct in ipairs({ 70, 100 }) do
        setRanks({ materials = 3, materialsPlus = r })
        check("숙련 " .. r .. ": " .. pct .. "% (not added to the base)", near(load() - worn, w0 / (1 + pct / 100), 0.05), load() - worn)
    end
    emptyInventory()
end)

section("가구 운반: a carried piece of furniture", function()
    setRanks({})
    local chair = instanceItem("Moveables.Moveable")
    if chair and chair.ReadFromWorldSprite then chair:ReadFromWorldSprite("furniture_seating_indoor_01_0") end
    if not check("a chair to carry", chair ~= nil and chair:getWeight() > 0, chair and chair:getWeight()) then return end
    inv:AddItem(chair)
    local w0 = load() - worn
    for r, pct in ipairs({ 50, 100 }) do
        setRanks({ furniture = r })
        check("rank " .. r .. ": " .. pct .. "% lighter", near(load() - worn, w0 / (1 + pct / 100), 0.05), w0 .. " -> " .. load() - worn)
    end
    emptyInventory()
end)

section("열쇠고리: keys in a key ring weigh nothing", function()
    setRanks({})
    local ring = inv:AddItem("Base.KeyRing")
    local keys = ring and ring:getInventory()
    if not check("a key ring", keys ~= nil) then return end
    local empty = load() - worn
    for _ = 1, 5 do keys:AddItem("Base.Key1") end
    local w0 = load() - worn
    setRanks({ keyring = 1 })
    local w1 = load() - worn
    check("the keys' weight is gone, the ring's stays", w1 < w0 and near(w1, empty, 0.001), w0 .. " -> " .. w1 .. " (ring " .. empty .. ")")
    emptyInventory()
end)

section("과적 적응: the excess counts 70/40%", function()
    setRanks({})
    -- in debug, ghost mode and unlimited carry make the game count no load at all
    local ghost, unlimited = player:isGhostMode(), player:isUnlimitedCarry()
    player:setGhostMode(false)
    player:setUnlimitedCarry(false)
    local max = player:getMaxWeight()
    for _ = 1, math.ceil((max + 10) / 3) do inv:AddItem("Base.Plank") end
    local moodles = player:getMoodles()
    local function heavy()
        moodles:Update()
        return moodles:getMoodleLevel(MoodleType.HEAVY_LOAD)
    end
    local heavy0 = heavy()
    local speed0 = player:getPathSpeed()
    setRanks({ overload = 2 })
    local heavy2 = heavy()
    say("info load", load(), "max", max, "heavy load moodle", heavy0, "->", heavy2, "path speed", speed0, "->", player:getPathSpeed())
    check("the API's overload is 60% of the excess", near(F.get("overload.compress"), 0.6, 0.001), F.get("overload.compress"))
    check("the heavy load moodle is lighter", heavy0 > 0 and heavy2 < heavy0, heavy0 .. " -> " .. heavy2)
    player:setGhostMode(ghost)
    player:setUnlimitedCarry(unlimited)
    emptyInventory()
end)

section("알뜰한 수납: a crate holds 20/40/60% more", function()
    setRanks({})
    local sq = getCell():getGridSquare(math.floor(player:getX()) + 2, math.floor(player:getY()), math.floor(player:getZ()))
    local crate = IsoObject.new(sq, "carpentry_01_16", "Crate")
    sq:AddSpecialObject(crate)
    crate:createContainersFromSpriteProperties()
    local c = crate:getContainer()
    if not check("a crate", c ~= nil) then
        sq:transmitRemoveItemFromSquare(crate)
        return
    end
    local cap0 = c:getEffectiveCapacity(player)
    for r, pct in ipairs({ 20, 40, 60 }) do
        setRanks({ storage = r })
        check("rank " .. r .. ": capacity +" .. pct .. "%", near(c:getEffectiveCapacity(player), math.min(100, cap0 * (1 + pct / 100)), 1),
            cap0 .. " -> " .. c:getEffectiveCapacity(player))
    end
    local bag = inv:AddItem("Base.Bag_Schoolbag")
    check("a bag's own capacity is not touched", bag:getInventory():getEffectiveCapacity(player) == bag:getInventory():getCapacity(),
        bag:getInventory():getEffectiveCapacity(player))
    sq:transmitRemoveItemFromSquare(crate)
    emptyInventory()
end)

section("갑옷 체질: worn gear a quarter as uncomfortable", function()
    setRanks({})
    local helmet = inv:AddItem("Base.Hat_CrashHelmetFULL")
    player:setWornItem(helmet:getBodyLocation(), helmet)
    player:updateDiscomfortModifiers()
    local d0 = player:getClothingDiscomfortModifier()
    setRanks({ armor = 1 })
    player:updateDiscomfortModifiers()
    local d1 = player:getClothingDiscomfortModifier()
    say("info discomfort", d0, "->", d1)
    check("discomfort with the helmet a quarter", d0 > 0 and near(d1, d0 / 4, 0.01), d0 .. " -> " .. d1)
    player:removeWornItem(helmet)
    inv:Remove(helmet)
end)

section("근육통 완화: strain -20/40/60%", function()
    local part = player:getBodyDamage():getBodyPart(BodyPartType.ForeArm_R)
    local function strain()
        part:setStiffness(0)
        player:addStiffness(BodyPartType.ForeArm_R, 10)
        local s = part:getStiffness()
        part:setStiffness(0)
        return s
    end
    setRanks({})
    local s0 = strain()
    for r, pct in ipairs({ 20, 40, 60 }) do
        setRanks({ stiff = r })
        check("rank " .. r .. ": " .. pct .. "% less", near(strain(), s0 * (1 - pct / 100), 0.05), strain())
    end
end)

section("질병 저항: poison -20/40/60%", function()
    local stats = player:getStats()
    local function poison()
        stats:set(CharacterStat.POISON, 0)
        stats:add(CharacterStat.POISON, 10)
        local p = stats:get(CharacterStat.POISON)
        stats:set(CharacterStat.POISON, 0)
        return p
    end
    setRanks({})
    local p0 = poison()
    for r, pct in ipairs({ 20, 40, 60 }) do
        setRanks({ resist = r })
        check("rank " .. r .. ": " .. pct .. "% less poison", near(poison(), p0 * (1 - pct / 100), 0.05), poison())
    end
end)

section("수풀 헤치기: a tree slows 50/100% less", function()
    setRanks({})
    -- a grown tree (size 5 up) does not slow at all, so a young one (size 3) is made, never put on the map
    local tree = IsoTree.new(player:getSquare(), "e_riverbirch_1_2")
    if not check("a young tree", tree:getSlowFactor(player) < 1, tree:getSize()) then return end
    local f0 = tree:getSlowFactor(player)
    for r, pct in ipairs({ 50, 100 }) do
        setRanks({ brush = r })
        local f = tree:getSlowFactor(player)
        check("rank " .. r .. ": slowdown -" .. pct .. "%", near(1 - f, (1 - f0) * (1 - pct / 100), 0.01), f0 .. " -> " .. f)
    end
    check("rank 2 scratches half the time", near(F.get("move.treeScratchChance"), 0.5, 0.001), F.get("move.treeScratchChance"))
end)

section("the API's combined values for the points Lua cannot measure", function()
    setRanks({ sight = 3 })
    check("시야 보정 3: the cone +72 degrees", near(F.get("vision.coneAdd"), 72, 0.01), F.get("vision.coneAdd"))
    setRanks({ walk = 3 })
    check("빠른 걸음 3: walking x1.15", near(F.get("move.walkMultiplier"), 1.15, 0.001), F.get("move.walkMultiplier"))
    setRanks({ runSpeed = 2 })
    check("가벼운 발 2: run penalty -60%", near(F.get("move.runPenaltyReduction"), 0.6, 0.001), F.get("move.runPenaltyReduction"))
    setRanks({ combatSpeed = 2 })
    check("가벼운 팔 2: combat penalty -60%", near(F.get("move.combatPenaltyReduction"), 0.6, 0.001), F.get("move.combatPenaltyReduction"))
    setRanks({ rich = 3 })
    check("알찬 수색 3: loot x1.5", near(F.get("loot.spawnMultiplier"), 1.5, 0.001), F.get("loot.spawnMultiplier"))
    setRanks({ ammo = 2 })
    check("탄약 수색 2: ammo x2", near(F.get("loot.ammoMultiplier"), 2, 0.001), F.get("loot.ammoMultiplier"))
    for r, share in ipairs({ 2 / 3, 1 / 3, 1 / 4 }) do
        setRanks({ fall = r })
        check("낙법 " .. r .. ": the height counts " .. string.format("%.2f", share), near(F.get("fall.heightMultiplier"), share, 0.001),
            F.get("fall.heightMultiplier"))
    end
    for r, cut in ipairs({ 20, 40, 60 }) do
        setRanks({ gear = r })
        check("장비 아끼기 " .. r .. ": clothes tear " .. cut .. "% less", near(F.get("body.holeChance"), 1 - cut / 100, 0.001),
            F.get("body.holeChance"))
    end
    for r, cut in ipairs({ 30, 60 }) do
        setRanks({ resistPlus = r })
        check("상처 감염 저항 " .. r .. ": " .. cut .. "% fewer rolls", near(F.get("infection.woundChance"), 1 - cut / 100, 0.001),
            F.get("infection.woundChance"))
    end
    for r, lift in ipairs({ 20, 40, 60 }) do
        setRanks({ night = r })
        check("밤눈 " .. r .. ": the dark lifted " .. lift .. "%", near(F.get("vision.darknessRestore"), lift / 100, 0.001),
            F.get("vision.darknessRestore"))
    end
end)

section("the board (연장 투여): many ranks stay under their caps, cost ceil(k/5)", function()
    -- the board opens with the capstones, so the tree's 빠른 걸음 3 / 알찬 수색 come along; the cap is the board line's
    for _, line in ipairs({ { "bWalk", "walk", "move.walkMultiplier", 0.40 }, { "bLoot", "rich", "loot.spawnMultiplier", 1.00 } }) do
        local id, tree, point, cap = line[1], line[2], line[3], line[4]
        for _, k in ipairs({ 20, 50 }) do
            setRanks({ [id] = k })
            local own = Rules.boardAmount(u, id)
            check(id .. " at " .. k .. " ranks stays under +" .. cap, own > 0 and own <= cap + 1e-6, own)
            check(id .. " at " .. k .. ": the API adds the tree's node and the board's line",
                near(F.get(point), 1 + Rules.fraction(u, tree) + own, 1e-6), F.get(point))
        end
    end
    setRanks({ bEndurance = 20 })
    local stats = player:getStats()
    stats:set(CharacterStat.ENDURANCE, 1)
    stats:add(CharacterStat.ENDURANCE, -0.2)
    local drop = 1 - stats:get(CharacterStat.ENDURANCE)
    stats:set(CharacterStat.ENDURANCE, 1)
    check("지구력 at 20 ranks: endurance drains slower", drop > 0 and drop < 0.2,
        string.format("%.3f of 0.2 (declared %s)", drop, tostring(F.get("body.enduranceDrainMultiplier"))))
    setRanks({ bSleep = 20 })
    check("졸음 내성 at 20 ranks: fatigue rate under 1", player:getFatiqueMultiplier() < 1, player:getFatiqueMultiplier())
    for k, want in pairs({ [1] = 1, [5] = 1, [6] = 2, [10] = 2, [11] = 3, [50] = 10 }) do
        setRanks({ bWalk = k - 1 })
        check("rank " .. k .. " of a board line costs " .. want, Rules.cost(u, "bWalk") == want, Rules.cost(u, "bWalk"))
    end
end)

section("a reset is vanilla at once", function()
    local max0 = player:getMaxWeight()
    setRanks({ capacity = 5 })
    check("with 튼튼한 어깨 5 the most carried is up", player:getMaxWeight() == max0 + 10, player:getMaxWeight())
    local ok = Rules.reset(u, "load", 1e9)
    Effects.apply(record)
    check("after the load tree's reset it is back, no reload", ok and player:getMaxWeight() == max0, player:getMaxWeight())
end)

-- back to nothing: the vanilla values
P3T.fresh(u)
Effects.apply(record)
P3T.changed(record)
say("done; the record's upgrades are empty. Night sight: at 2 a.m. in a dark room, OperationAcorn.Dev ranks of 밤눈 and look")
