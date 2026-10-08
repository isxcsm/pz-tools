-- P1: OA.Value.info on real game items, the category and acceptance rules, and an appraisal of each.
-- Gives the character test items (the inventory keeps them; it removes them at the end). Changes nothing in the save.
-- Prints "[p1value]" lines: each rule ends in ok or BAD.
RUN("p1_lib.lua")
local OA = OperationAcorn
local say = P1T.say("p1value")
local record, player = P1T.record()
if not record then say("no record yet: wait for the first hello"); return end
local inv = player:getInventory()
local made = {}
local function give(type)
    local ok, item = pcall(function() return inv:AddItem(type) end)
    if ok and item then made[#made + 1] = item end
    return ok and item or nil
end

-- type, expected category (nil: not taken), expected acceptance
local cases = {
    { "Base.Apple", "A", true }, { "Base.TinnedBeans", "A", true }, { "Base.Tshirt_DefaultTEXTURE_TINT", "B", true },
    { "Base.Bag_ALICEpack", "C", true }, { "Base.Notebook", "D", true }, { "Base.BookFirstAid1", "D", true },
    { "Base.Pan", "F", true }, { "Base.Candle", "F", true }, { "Base.Battery", "G", true }, { "Base.WalkieTalkie1", "G", true },
    { "Base.Hammer", "H", true }, { "Base.PetrolCan", "H", true }, { "Base.Pills", "I", true }, { "Base.Katana", "J", true },
    { "Base.Screws", "K", true }, { "Base.Rope", "K", true },
    { "Base.Money", nil, true, "cash" }, { "Base.MoneyBundle", nil, true, "cash" },
    { "Base.Bullets9mmBox", nil, false }, { "Base.ShotgunShellsBox", nil, false }, { "Base.Bag_AmmoBox_9mm", nil, false },
    { "Base.LargeMeteorite", nil, false }, { "Base.Log", nil, false }, { "Base.Plank", nil, false },
    { "Base.Twigs", nil, false }, { "Base.Dung_Cow", nil, false }, { "Base.Mov_FitnessContraption", nil, false },
}
for _, case in ipairs(cases) do
    local item = give(case[1])
    if not item then
        say(case[1], "could not be made, skipped")
    else
        local info = OA.Value.info(item)
        local letter, why = OA.Categories.of(info)
        local ok, reason = OA.Value.accepts(info)
        local good = letter == case[2] and (ok == true) == case[3]
        P1T.check(say, case[1], good, "category " .. tostring(letter or ("-/" .. tostring(why))) .. " accepts " ..
            tostring(ok) .. " " .. tostring(reason or "") .. " weight " .. tostring(info.weight))
    end
end

-- Cash weights and values.
local money, bundle = give("Base.Money"), give("Base.MoneyBundle")
if money and bundle then
    local ctx = OA.Value.context(record)
    local a = OA.Value.appraise(OA.Value.info(money), ctx)
    P1T.check(say, "$1 is 100 credits x rate", P1T.near(a.credits, 100 * ctx.rate, 1e-6), a.credits .. " rate " .. ctx.rate)
    P1T.check(say, "$1 is 0.02 cash trust", P1T.near(a.cashTrust, 0.02, 1e-9), a.cashTrust)
    local b = OA.Value.appraise(OA.Value.info(bundle), ctx)
    P1T.check(say, "a bundle is $100 = 10,000 credits x rate", P1T.near(b.credits, 10000 * ctx.rate, 1e-6), b.credits)
end

-- Food freshness.
local apple = give("Base.Apple")
if apple then
    P1T.check(say, "a new apple is fresh", OA.Value.info(apple).food == "fresh", OA.Value.info(apple).food)
    apple:setAge(apple:getOffAge() + 0.5)
    P1T.check(say, "an older apple is stale", OA.Value.info(apple).food == "stale", OA.Value.info(apple).food)
    apple:setAge(apple:getOffAgeMax() + 0.5)
    local info = OA.Value.info(apple)
    P1T.check(say, "an old apple is rotten and refused", info.food == "rotten" and OA.Value.accepts(info) == false, info.food)
end

-- Drainables.
local battery = give("Base.Battery")
if battery then
    P1T.check(say, "a new battery is full", P1T.near(OA.Value.info(battery).condition, 1.0, 0.01), OA.Value.info(battery).condition)
    battery:setCurrentUsesFloat(0.0)
    local info = OA.Value.info(battery)
    P1T.check(say, "a spent battery is condition 0 and worth half", P1T.near(info.condition, 0, 0.01) and
        P1T.near(OA.Value.state(info), 0.5, 0.01), info.condition)
end

-- Bags: empty accepted, filled refused.
local bag = give("Base.Bag_ALICEpack")
if bag then
    P1T.check(say, "an empty bag is not filled", OA.Value.info(bag).filled == false)
    bag:getInventory():AddItem("Base.Hammer")
    local info = OA.Value.info(bag)
    P1T.check(say, "a bag with a hammer is filled and refused", info.filled == true and OA.Value.accepts(info) == false)
end

-- A hurt tool.
local axe = give("Base.Axe")
if axe then
    axe:setCondition(math.floor(axe:getConditionMax() / 2))
    local c = OA.Value.info(axe).condition
    P1T.check(say, "a half-worn axe has about half condition", c and c > 0.3 and c < 0.7, c)
end

-- A drink's container is counted empty: the info weight is the script's.
local can = give("Base.PetrolCan")
if can then
    local info = OA.Value.info(can)
    local script = can:getScriptItem()
    P1T.check(say, "a fluid container weighs its script weight", P1T.near(info.weight, script:getActualWeight(), 1e-6),
        info.weight .. " / " .. script:getActualWeight() .. " item " .. can:getActualWeight())
end

-- Tags a pickup or a shop leaves.
local hammer = give("Base.Hammer")
if hammer then
    hammer:getModData().OA_Bought = true
    local info = OA.Value.info(hammer)
    P1T.check(say, "a shop item is refused", info.bought == true and OA.Value.accepts(info) == false)
    hammer:getModData().OA_Bought = nil
    hammer:getModData().OA_Cell = "40,35"
    info = OA.Value.info(hammer)
    local ctx = OA.Value.context(record)
    local a = OA.Value.appraise(info, ctx)
    P1T.check(say, "a tagged item earns the new region mark (unless the cell is used up)",
        a.marks.newRegion or ((ctx.cellUsed and ctx.cellUsed["40,35"]) or 0) >= 30, tostring(a.marks.newRegion))
end

-- The mark keys and the price of a plain item at the market now.
local shirt = give("Base.Tshirt_DefaultTEXTURE_TINT")
if shirt then
    local ctx = OA.Value.context(record)
    local info = OA.Value.info(shirt)
    local a = OA.Value.appraise(info, ctx)
    say("t-shirt", "weight", info.weight, "B index", OA.Market.index("B"), "credits", a.credits, "trust", a.trust,
        "marks", table.concat(OA.Value.markKeys(a.marks), ","))
    local expected = info.weight * 400 * OA.Market.index("B") * OA.Value.state(info) * ctx.rate
    P1T.check(say, "a t-shirt follows weight x 400 x index x state x rate", P1T.near(a.credits, expected, 1e-6), expected)
end

for _, item in ipairs(made) do
    local container = item:getContainer()
    if container then container:Remove(item) end
end
say("done")
