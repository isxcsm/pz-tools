-- The words of the research screen: every node has its texts in both languages, the numbers a rank line is built from
-- are what the rules say, and the time an item takes to move follows its weight.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Texts"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Texts = OA.Upgrades.Texts

local TRANSLATE = "OperationAcorn/42/media/lua/shared/Translate/"

local function inject(u, tree, n)
    for _ = 1, n do Rules.inject(u, tree) end
end

local function buy(u, id, n, ctx)
    for _ = 1, n or 1 do
        local ok, why = Rules.buy(u, id, ctx or { fragments = 0 })
        if not ok then error("could not buy " .. id .. ": " .. tostring(why), 2) end
    end
end

-- The text of a file, or fails the test.
local function file(lang, name)
    local text = readfile(TRANSLATE .. lang .. "/" .. name)
    if not text then error("no file " .. lang .. "/" .. name) end
    return text
end

local function has(text, key)
    return string.find(text, '"' .. key .. '":', 1, true) ~= nil
end

test("every node has its name and rank text in both languages, a note on capstones only", function()
    for _, lang in ipairs({ "EN", "KO" }) do
        local text = file(lang, "IG_UI.json")
        for _, node in ipairs(Data.nodes) do
            truthy(has(text, Data.key(node.id, "Name")), lang .. " lacks " .. Data.key(node.id, "Name"))
            eq(has(text, Data.key(node.id, "Note")), node.capstone == true, lang .. " note of " .. node.id)
            if node.rankText then
                for r = 1, node.ranks do
                    truthy(has(text, Data.key(node.id, "Rank" .. r)), lang .. " lacks " .. node.id .. " rank " .. r)
                end
            else
                truthy(has(text, Data.key(node.id, "Rank")), lang .. " lacks " .. node.id .. " rank text")
            end
        end
    end
end)

test("the items have names in both languages", function()
    for _, lang in ipairs({ "EN", "KO" }) do
        local text = file(lang, "ItemName.json")
        for _, name in ipairs({ "UpgradeSerumScout", "UpgradeSerumLoad", "UpgradeSerumSurvival", "UpgradeSerumShared",
                                "CureSerum", "DelayDrug" }) do
            truthy(has(text, "OperationAcorn." .. name), lang .. " lacks " .. name)
        end
    end
end)

test("every trees' scripts' items exist in OA_upgrades.txt", function()
    local text = readfile("OperationAcorn/42/media/scripts/OA_upgrades.txt")
    truthy(text, "no item script")
    for _, name in ipairs({ "UpgradeSerumScout", "UpgradeSerumLoad", "UpgradeSerumSurvival", "UpgradeSerumShared",
                            "CureSerum", "DelayDrug" }) do
        truthy(string.find(text, "item " .. name, 1, true), name .. " is not in the script")
        truthy(string.find(text, "Icon = OA_" .. name, 1, true), name .. " has no OA_ icon")
    end
end)

test("rank line numbers: a percentage carries its sign, a count does not", function()
    local u = Rules.blank()
    inject(u, "scout", 12)
    local rich = Data.byId.rich
    local args = Texts.args(rich, 2, u)
    eq(args[1], "30%")
    local sight = Data.byId.sight
    eq(Texts.args(sight, 3, u)[1], "36")
    local keen = Data.byId.keen
    local keenArgs = Texts.args(keen, 2, u)
    eq(keenArgs[1], "100%")
    eq(keenArgs[2], "2")
end)

test("rank line numbers follow the effect option", function()
    SandboxVars.OperationAcorn.UpgradeEffectMultiplier = 2
    local u = Rules.blank()
    local args = Texts.args(Data.byId.rich, 1, u)
    eq(args[1], "30%")
    -- capped nodes stay under their cap
    eq(Texts.args(Data.byId.moveSpeed, 3, u)[1], "95%")
end)

test("a carrying efficiency shows the weight it takes off", function()
    local u = Rules.blank()
    -- +100% efficiency halves the weight
    eq(Texts.args(Data.byId.furniture, 2, u)[1], "50%")
    eq(Texts.args(Data.byId.materials, 1, u)[1], "13%")
end)

test("overload shows the share of the excess that still counts", function()
    local u = Rules.blank()
    eq(Texts.args(Data.byId.overload, 1, u)[1], "70%")
    eq(Texts.args(Data.byId.overload, 2, u)[1], "40%")
end)

test("board numbers read what is bought", function()
    local u = Rules.blank()
    u.board = u.board or {}
    u.board.ranks = { bWalk = 10, bBite = 3, bLimit = 4 }
    local walk = Texts.args(Data.byId.bWalk, 10, u)
    near(tonumber(string.match(walk[1], "[%d%.]+")), 20, 1e-9)
    eq(walk[2], "40%")
    eq(Texts.args(Data.byId.bLimit, 4, u)[1], "4")
    -- a reduction shows what it takes off: a wait divided by 1.3 is 23% shorter
    local bite = Texts.args(Data.byId.bBite, 3, u)
    eq(bite[1], "23%")
    eq(bite[2], "5.4")
end)

test("the conditions list what a node needs, each with its state", function()
    local u = Rules.blank()
    inject(u, "scout", 4)
    buy(u, "sixth", 1)
    local conditions = Texts.conditions(u, Data.byId.sense, { fragments = 0 })
    local open, node = false, false
    for _, c in ipairs(conditions) do
        if string.find(c.text, "NeedNode", 1, true) then node = c.ok end
        if string.find(c.text, "NeedOpen", 1, true) then open = c.ok end
    end
    truthy(open, "the tree is open")
    eq(node, false, "needs the hunch at 2")
    local capstone = Texts.conditions(u, Data.byId.nightEye, { fragments = 0 })
    local fragment
    for _, c in ipairs(capstone) do
        if string.find(c.text, "NeedFragment", 1, true) then fragment = c.ok end
    end
    eq(fragment, false)
end)

test("moving an item takes the time of its weight up to 3", function()
    eq(Rules.weightRatio(2, 0), 1)
    eq(Rules.weightRatio(9, 0), 1)
    -- weight 9 with +200% becomes 3: the time stays at the cap
    eq(Rules.weightRatio(9, 2), 1)
    -- weight 3 with +100% becomes 1.5: half the time
    near(Rules.weightRatio(3, 1), 0.5, 1e-9)
    -- weight 1 with +100% becomes 0.5: half the time too
    near(Rules.weightRatio(1, 1), 0.5, 1e-9)
    -- weight 0 changes nothing
    eq(Rules.weightRatio(0, 1), 1)
end)
