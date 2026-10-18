-- The caches added for speed: each must answer as the uncached path did. Item types and fake items here are stand-ins
-- for the game's.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Things"
local OA = OperationAcorn

function instanceof(object, class)
    return object ~= nil and object.classes ~= nil and object.classes[class] == true
end
ItemType = { MOVEABLE = "moveable" }

local function list(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end, items = t }
end

-- A fake inventory item. `o`: weight, display, moveable, food, uses, condition, max, fluid, contents, data.
local function item(fullType, o)
    o = o or {}
    local it = { classes = {}, data = o.data, fullType = fullType }
    local weight = o.weight or 1.0
    it.getFullType = function() return fullType end
    it.getScriptItem = function()
        return { getActualWeight = function() return o.scriptWeight or weight end }
    end
    it.isFluidContainer = function() return o.fluid or false end
    it.getActualWeight = function() return o.fluid and weight + 5 or weight end
    it.getDisplayCategory = function() return o.display or "Junk" end
    it.getCategory = function() return "Normal" end
    it.isItemType = function(_, t) return o.moveable and t == "moveable" or false end
    it.getConditionMax = function() return o.max or 10 end
    it.getCondition = function() return o.condition or (o.max or 10) end
    it.hasModData = function() return it.data ~= nil end
    it.getModData = function() it.data = it.data or {}; return it.data end
    if o.food then
        it.classes.Food = true
        it.isRotten = function() return o.food == "rotten" end
        it.isFresh = function() return o.food == "fresh" end
    end
    if o.uses then
        it.classes.DrainableComboItem = true
        it.getCurrentUsesFloat = function() return o.uses end
    end
    if o.contents then
        it.classes.InventoryContainer = true
        it.getInventory = function() return { getItems = function() return list(o.contents) end } end
    end
    return it
end

-- Many kinds of item: every branch of Value.info and every kind of full type.
local function kinds()
    return {
        item("Base.Hammer", { weight = 1.2, display = "Tool" }),
        item("Base.Money", { weight = 0.01, display = "Junk" }),
        item("Base.MoneyBundle", { weight = 0.1 }),
        item("Base.Shirt_Tshirt_TINT", { display = "Clothing", condition = 4 }),
        item("Base.Apple", { display = "Food", food = "fresh" }),
        item("Base.Bread", { display = "Food", food = "stale" }),
        item("Base.Rotten", { display = "Food", food = "rotten" }),
        item("Base.Bleach", { display = "Household", uses = 0.4 }),
        item("Base.BottleWater", { display = "WaterContainer", fluid = true, weight = 0.3, scriptWeight = 0.1 }),
        item("Base.Bag_ALICEpack", { display = "Bag", contents = { item("Base.Rag") } }),
        item("Base.Bag_Empty", { display = "Bag", contents = {} }),
        item("Base.Ammo_556", { display = "Ammo" }),
        item("Base.AmmoStrapShotgun", { display = "Container" }),
        item("Base.LargeMeteorite", { display = "Junk" }),
        item("Base.Log", { display = "Material" }),
        item("Base.Dung_Cow", { display = "Junk" }),
        item("Moveables.Fridge", { display = "Furniture", moveable = true }),
        item("Other.Log", { display = "Material" }),
        item("Other.Dung_x", { display = "Weapon" }),
        item("Base.Weird", { display = "NotAKnownCategory" }),
        item("Base.Corpse", { display = "Corpse" }),
        item("OperationAcorn.SampleBundle", { display = "Junk" }),
        item("OperationAcorn.KitCapacity", { display = "Tool" }),
        item("OperationAcorn.TissueTarget", { display = "Junk", data = { OA_Mission = "m1" } }),
        item("Base.Rag", { display = "Clothing", data = { OA_Bought = true, OA_Cell = "5,2" } }),
        item("Base.Rag", { display = "Clothing", data = { OA_Cell = "5,2" } }),
    }
end

-- The type-level fields of an info as they were worked out before the types were remembered.
local function refInfo(it, V)
    local fullType = it:getFullType()
    local name = tostring(fullType)
    if string.sub(name, 1, 5) == "Base." then name = string.sub(name, 6) end
    name = string.gsub(name, "_TINT", "")
    name = string.gsub(name, "TINT", "")
    local module, own = string.match(tostring(fullType), "^([^%.]+)%.(.+)$")
    if module ~= OA.MOD then own = nil end
    return { baseType = name, cash = V.CASH[fullType], own = own, moveable = it:isItemType(ItemType.MOVEABLE) and true or false }
end

-- Categories.of as it was before the id rejects were remembered.
local function refOf(C, info)
    if info.cash then return nil, "Cash" end
    if info.own then return nil, "Own" end
    local why
    if C.isVanilla(info.fullType) then
        local id = C.shortName(info.fullType)
        why = C.REJECT_ID[id]
        if why then return nil, why end
        for _, pair in ipairs(C.REJECT_PREFIX) do
            if string.sub(id, 1, #pair[1]) == pair[1] then return nil, pair[2] end
        end
    end
    if info.bought then return nil, "Bought" end
    if info.moveable then return nil, "Furniture" end
    local display = info.displayCategory
    if display then
        why = C.REJECT_DISPLAY[display]
        if why then return nil, why end
        return C.BY_DISPLAY[display] or "E"
    end
    return "E"
end

test("Value.info with the type facts remembered answers as the uncached path, again and again", function()
    local V, C = OA.Value, OA.Categories
    for round = 1, 3 do
        for _, it in ipairs(kinds()) do
            local info = V.info(it)
            local ref = refInfo(it, V)
            local fullType = it:getFullType()
            eq(info.fullType, fullType)
            eq(info.baseType, ref.baseType, fullType)
            eq(info.cash, ref.cash, fullType)
            eq(info.own, it.data and it.data.OA_Mission and "MissionItem" or ref.own, fullType)
            eq(info.moveable, ref.moveable, fullType)
            local a1, a2 = C.of(info)
            local b1, b2 = refOf(C, info)
            eq(a1, b1, fullType)
            eq(a2, b2, fullType)
            eq(C.baseType(fullType), ref.baseType)
        end
    end
    -- two items of a type differ in what is theirs alone
    local a, b = V.info(item("Base.Rag", { data = { OA_Bought = true } })), V.info(item("Base.Rag"))
    eq(a.bought, true)
    eq(b.bought, nil)
    truthy(a ~= V.info(item("Base.Rag")), "an info is its own table")
end)

test("Value.info gives only the fields the box grouping key lists", function()
    local V = OA.Value
    local listed = {}
    for _, name in ipairs(OA.Trade.Boxes.INFO_FIELDS) do listed[name] = true end
    local function check(info, what)
        for k in pairs(info) do truthy(listed[k], what .. ": Boxes.INFO_FIELDS lacks " .. k) end
    end
    for _, it in ipairs(kinds()) do check(V.info(it), it:getFullType()) end
    check(V.infoFromScript({ getFullName = function() return "Base.Hammer" end, getActualWeight = function() return 1 end,
        getDisplayCategory = function() return "Tool" end, isItemType = function() return false end }), "script")
end)

test("items that differ in any one info field group apart, the same ones together", function()
    local Boxes = OA.Trade.Boxes
    local base = { fullType = "Base.Rag", baseType = "Rag", weight = 0.2, displayCategory = "Clothing", moveable = false,
        condition = 1 }
    local function copy(over)
        local t = {}
        for k, v in pairs(base) do t[k] = v end
        for k, v in pairs(over or {}) do t[k] = v end
        return t
    end
    eq(#Boxes.group({ copy(), copy(), copy() }), 1)
    eq(Boxes.group({ copy(), copy(), copy() })[1].count, 3)
    local over = { fullType = "Base.Sock", baseType = "Sock", weight = 0.3, displayCategory = "Tool", moveable = true,
        cash = 1, own = "SampleBundle", food = "stale", condition = 0.5, filled = true, bought = true, cell = "1,1",
        mission = "m" }
    for _, field in ipairs(Boxes.INFO_FIELDS) do
        eq(#Boxes.group({ copy(), copy({ [field] = over[field] }) }), 2, field)
    end
end)

local function box(items) return { getItems = function() return list(items) end } end

test("Things.sealable keeps the refused items' infos and reasons, and a memo spares the second read", function()
    local V = OA.Value
    local reads = 0
    local realInfo = V.info
    V.info = function(it) reads = reads + 1 return realInfo(it) end
    local rag, ammo = item("Base.Rag", { display = "Clothing" }), item("Base.Ammo_556", { display = "Ammo" })
    local bag = item("Base.Bag_Empty", { display = "Bag", contents = {} })
    local c = box({ rag, ammo, bag })
    local plan = OA.Trade.Things.sealable(c)
    eq(reads, 3)
    eq(#plan.taken, 2)
    eq(#plan.refused, 1)
    eq(plan.refused[1], ammo)
    eq(plan.refusedInfos[1].fullType, "Base.Ammo_556")
    eq(plan.refusedWhys[1], "IGUI_OA_Econ_Reject_Ammo")
    local memo = setmetatable({}, { __mode = "k" })
    reads = 0
    OA.Trade.Things.sealable(c, memo)
    eq(reads, 3)
    local again = OA.Trade.Things.sealable(c, memo)
    eq(reads, 4, "only the bag is read again: a bag's answer moves with what is in it")
    eq(#again.taken, 2)
    eq(again.refusedWhys[1], "IGUI_OA_Econ_Reject_Ammo")
    eq(again.refusedInfos[1].fullType, "Base.Ammo_556")
    eq(again.weight, plan.weight)
    -- the unmemoised call always reads fresh
    reads = 0
    OA.Trade.Things.sealable(c)
    eq(reads, 3)
end)

test("the research data's lists are those the per-call functions built, in the same order, and are shared", function()
    require "OperationAcorn/Upgrades/Data"
    local Data = OA.Upgrades.Data
    local function oldTree(tree)
        local list = {}
        for _, n in ipairs(Data.nodes) do
            if n.tree == tree then list[#list + 1] = n end
        end
        return list
    end
    local function oldGroup(group)
        local list = {}
        for _, n in ipairs(Data.nodes) do
            if n.board and n.group == group then list[#list + 1] = n end
        end
        table.sort(list, function(a, b) return a.row < b.row end)
        return list
    end
    local function oldCapstone(tree)
        for _, n in ipairs(Data.nodes) do
            if n.tree == tree and n.capstone then return n end
        end
        return nil
    end
    local trees = { "scout", "load", "survival", Data.BOARD, "nothing" }
    for _, tree in ipairs(trees) do
        local a, b = Data.treeNodes(tree), oldTree(tree)
        eq(#a, #b, tree)
        for i = 1, #b do eq(a[i], b[i], tree .. " " .. i) end
        eq(Data.capstone(tree), oldCapstone(tree), tree)
        eq(Data.treeNodes(tree), a, "the same list each call")
    end
    for _, group in ipairs({ "scout", "load", "survival", "nothing" }) do
        local a, b = Data.boardGroup(group), oldGroup(group)
        eq(#a, #b, group)
        for i = 1, #b do eq(a[i], b[i], group .. " " .. i) end
        eq(Data.boardGroup(group), a)
    end
    eq(#Data.boardGroup("load"), 10)
end)
