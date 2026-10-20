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
    local memo = {}
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

test("the visibility mod is looked up once for the session, and again after Effects.reset", function()
    require "OperationAcorn/Upgrades/Effects"
    local Effects = OA.Upgrades.Effects
    local calls, active = 0, false
    getActivatedMods = function()
        calls = calls + 1
        local mods = { active and "ZombieVisibilityFix" or "SomethingElse", "Other" }
        return { size = function() return #mods end, get = function(_, i) return mods[i + 1] end }
    end
    eq(Effects.visibilityModActive(), false)
    eq(Effects.visibilityModActive(), false)
    eq(Effects.visibilityModActive(), false)
    eq(calls, 1, "read once")
    active = true
    eq(Effects.visibilityModActive(), false, "the list cannot change under the game: the answer stands")
    eq(calls, 1)
    Effects.reset()
    eq(Effects.visibilityModActive(), true, "a new game reads again")
    eq(calls, 2)
    eq(Effects.visibilityModActive(), true)
    eq(calls, 2)
    getActivatedMods = nil
    Effects.reset()
    eq(Effects.visibilityModActive(), false)
end)

test("the API handle is asked for once for each API object and world", function()
    local asked = 0
    local function make(name)
        return { version = OA.API_VERSION, client = function(mod) asked = asked + 1 return name .. mod end }
    end
    PZExtAPI = make("a")
    eq(OA.handle(), "a" .. OA.MOD)
    eq(OA.handle(), "a" .. OA.MOD)
    eq(OA.handle(), "a" .. OA.MOD)
    eq(asked, 1)
    PZExtAPI = make("b")
    eq(OA.handle(), "b" .. OA.MOD, "another API object: asked again")
    eq(asked, 2)
    TEST.fire("OnGameStart")
    eq(OA.handle(), "b" .. OA.MOD)
    eq(asked, 3, "a new world asks again")
    PZExtAPI.client = function() asked = asked + 1 return "c" end
    eq(OA.handle(), "c", "a replaced client function is not kept")
    PZExtAPI.version = "other"
    eq(OA.handle(), nil, "a different version: no handle")
    PZExtAPI = nil
    eq(OA.handle(), nil)
end)

test("an item type's name is made once, and again after a new game starts", function()
    require "OperationAcorn/Trade/Text"
    local Text = OA.Trade.Text
    local calls = 0
    local name = "Hammer"
    getItemNameFromFullType = function() calls = calls + 1 return name end
    getScriptManager = function() return { FindItem = function() return nil end } end
    eq(Text.itemName("Base.Hammer"), "Hammer")
    eq(Text.itemName("Base.Hammer"), "Hammer")
    eq(calls, 1)
    name = "Mallet"
    eq(Text.itemName("Base.Hammer"), "Hammer", "kept within the game")
    TEST.fire("OnGameStart")
    eq(Text.itemName("Base.Hammer"), "Mallet")
    eq(calls, 2)
    name = nil
    eq(Text.itemName("Base.Nothing"), "Base.Nothing", "a name not found is not kept")
    name = "Found"
    eq(Text.itemName("Base.Nothing"), "Found")
end)

test("Machines.anyNear looks at the registry only", function()
    require "OperationAcorn/Machines/Machines"
    local Machines = OA.Machines
    eq(Machines.anyNear(100, 100, 4), false, "no machines")
    Machines.list().m1 = { kind = "cutter", x = 104, y = 96, z = 0 }
    eq(Machines.anyNear(100, 100, 4), true, "at the edge")
    eq(Machines.anyNear(100, 100, 3), false)
    Machines.list().m2 = { kind = "cutter", x = 300, y = 300, z = 2 }
    eq(Machines.anyNear(299, 301, 4), true, "any level")
    Machines.list().m1, Machines.list().m2 = nil, nil
    eq(Machines.anyNear(100, 100, 4), false)
end)

test("Rules.section fills a section once; assign makes it be filled again", function()
    require "OperationAcorn/Upgrades/Rules"
    local Rules = OA.Upgrades.Rules
    local record = OA.Store.ensure("p", "P")
    local u = Rules.section(record)
    truthy(u.board and u.ranks and u.opened)
    -- a field taken away after is not made again by the next read (the section is known to be filled)
    u.unsealed = nil
    eq(Rules.section(record).unsealed, nil)
    -- but the whole fill is done again for a section assigned from a copy
    Rules.assign(u, { ranks = {} })
    local again = Rules.section(record)
    eq(again, u)
    truthy(again.board and again.unsealed and again.injected, "filled after the assign")
    -- a record whose section was replaced is another table, filled when asked
    record.upgrades = {}
    truthy(Rules.section(record).board)
    -- the explicit fill always runs
    local bare = {}
    Rules.fill(bare)
    truthy(bare.board and bare.unsealed)
end)

test("the transfer factor is worked out once until the research is told to have changed", function()
    local real = require
    _G.ISInventoryTransferAction = { new = function(self, character, item) return { maxTime = 100 } end,
        perform = function() end }
    _G.ISWorldObjectContextMenu = { grabItemTime = function() return 100 end }
    _G.ISToolTipInv = { render = function() end }
    require = function(name)
        if string.find(name, "^ISUI/") or string.find(name, "^TimedActions/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Carry")
    require = real
    if not ok then error(err, 0) end
    local Carry, Rules = OA.Upgrades.Carry, OA.Upgrades.Rules
    local record = OA.Store.ensure("p", "P")
    OA.Client.record = function() return record end
    local calls = 0
    local transferTime = Rules.transferTime
    Rules.transferTime = function(u) calls = calls + 1 return transferTime(u) end
    eq(Carry.timeFactor({}, nil), 1)
    eq(Carry.timeFactor({}, nil), 1)
    eq(calls, 1, "worked out once")
    local u = Rules.section(record)
    u.ranks.moveSpeed = 3
    eq(Carry.timeFactor({}, nil), 1, "no news of a change: the factor stands")
    OA.Sync.changed("upgrades", record.id)
    near(Carry.timeFactor({}, nil), 1 - Rules.cut(u, "moveSpeed"), 1e-9)
    truthy(Carry.timeFactor({}, nil) < 1)
    eq(calls, 2)
    Carry.timeFactor({}, nil)
    eq(calls, 2)
    OA.Sync.deliver("all")
    Carry.timeFactor({}, nil)
    eq(calls, 3)
    -- the record the character has now is another: its own factor
    local other = OA.Store.ensure("q", "Q")
    OA.Client.record = function() return other end
    eq(Carry.timeFactor({}, nil), 1)
    eq(calls, 4)
end)

test("an item the carry nodes lighten has its carried weight under its own in the tooltip; one they do not, none", function()
    if not (OA.Upgrades and OA.Upgrades.Carry) then
        local real = require
        _G.ISInventoryTransferAction = { new = function() return { maxTime = 100 } end, perform = function() end }
        _G.ISWorldObjectContextMenu = { grabItemTime = function() return 100 end }
        _G.ISToolTipInv = { render = function() end }
        require = function(name)
            if string.find(name, "^ISUI/") or string.find(name, "^TimedActions/") then return true end
            return real(name)
        end
        local ok, err = pcall(real, "OperationAcorn/Upgrades/Carry")
        require = real
        if not ok then error(err, 0) end
    end
    local Carry, Effects = OA.Upgrades.Carry, OA.Upgrades.Effects
    local efficiencyOf = Effects.efficiencyOf
    local text = getText
    getText = function(key, a) return key .. " " .. tostring(a) end
    local plank = { getUnequippedWeight = function() return 3 end }
    Effects.efficiencyOf = function() return 0.5 end
    eq(Carry.tipLines(plank)[1], "IGUI_OA_Tree_CarriedWeight 2.00")
    Effects.efficiencyOf = function() return 0 end
    eq(Carry.tipLines(plank), nil)
    Effects.efficiencyOf, getText = efficiencyOf, text
end)
