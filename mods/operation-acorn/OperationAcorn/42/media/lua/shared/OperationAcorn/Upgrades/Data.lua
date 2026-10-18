-- The upgrade trees as data: every node of the three trees and of the 2nd board (TREES.md), with where it sits on the
-- screen, what it needs, how many ranks it has and what each rank gives. Nothing here touches the game; the rules
-- (Rules.lua) and the effects (Effects.lua) read this table. Names and texts are translations, found by node id:
--   IGUI_OA_Tree_Node_<id>_Name, _Rank (the effect of a rank, one sentence; _Rank1, _Rank2 ... when each rank reads
--   differently: rankText = true), _Desc (only where the rank text leaves out something a player would not expect) and
--   _Note (the research team's line, capstones only).
-- adds (with rankText): the ranks whose text adds to the lines before rather than replacing them (true: every rank after
-- the first), so a tooltip lists what each rank taken gives; a rank not added replaces the lines before it.
-- kind: "lua" works with this mod alone; "api" needs PZ Extension API to change the game's numbers.
-- values: the effect of each rank in its unit (cumulative: the value at that rank).
-- lighter: the values are carrying efficiencies (a weight is divided by 1 + sum); the text shows the weight taken off.
require "OperationAcorn/Core"
OperationAcorn.Upgrades = OperationAcorn.Upgrades or {}
local Data = {}
OperationAcorn.Upgrades.Data = Data

Data.TREES = { "scout", "load", "survival" }
Data.BOARD = "board"
-- The upgrade serum item of each tree (module OperationAcorn).
Data.SERUM_ITEM = { scout = "UpgradeSerumScout", load = "UpgradeSerumLoad", survival = "UpgradeSerumSurvival" }
Data.SHARED_ITEM = "UpgradeSerumShared"
-- The meteorite fragment that opens each tree's capstone (sent to the research team in a delivery box: Rules.unseal).
-- Three kinds fall, one at each drop site (Story/Sites.lua). MeteorFragment is the stony one (the name it had when
-- there was one kind).
Data.FRAGMENTS = { scout = "OperationAcorn.MeteorFragmentStonyIron", load = "OperationAcorn.MeteorFragmentIron",
                   survival = "OperationAcorn.MeteorFragment" }

-- The tree a fragment's full type opens, or nil.
function Data.treeOfFragment(fullType)
    for tree, ft in pairs(Data.FRAGMENTS) do
        if ft == fullType then return tree end
    end
    return nil
end
-- Points that must be spent in a tree to open its rows 1 to 4, and its capstone (TREES rules).
Data.ROW_COST = { 0, 3, 6, 9 }
Data.CAPSTONE_COST = 12
Data.ROWS = 5
-- The columns of a tree.
Data.COLS = 4
-- The distance 기척 감지 watches (tiles). Sixth sense has its own, per rank.
Data.SENSE_RADIUS = 20
-- A reset costs this share of what the tree's serums cost (NUMBERS 6).
Data.RESET_SHARE = 0.10
-- How the extension API adds to the character's carrying limit: the pickup limit grows with it (FEASIBILITY 3).
Data.LIMIT_PER_WEIGHT = 1.75
-- Days the bite shield waits between two bites it saves you from.
Data.BITE_DAYS = 7
-- The 2nd board's k-th rank of a node costs ceil(k / BOARD_STEP) points (NUMBERS 6).
Data.BOARD_STEP = 5
-- Game hours a dose of an upgrade serum takes to adapt (DESIGN-terminal 19): the point comes when it is over, and doses
-- taken meanwhile share the time. A first guess.
Data.ADAPT_HOURS = 0.5
-- The nodes that tell their first effect, once each (the order of the lines in the self-talk bundle FirstEffect, two a
-- node).
Data.FIRST_EFFECT = { "sense", "ledger", "overload", "furniture", "crowbar", "dash" }

-- Item display categories by family, for the 2nd board's family nodes, one a family (NUMBERS 12): the gear a
-- character carries and uses, the supplies it lives on, and the odds and ends picked up along the way. Materials and
-- furniture are the heavy-load node's, so they are not here.
Data.FAMILIES = {
    Gear = { "Weapon", "SportsWeapon", "WeaponPart", "WeaponCrafted", "BrokenWeapon", "WeaponImprovised",
             "AnimalPartWeapon", "Explosives", "Ammo", "Tool", "ToolWeapon", "VehicleMaintenance",
             "VehicleMaintenanceWeapon", "Gardening", "GardeningWeapon", "Fishing", "FishingWeapon", "Camping",
             "Trapping", "AnimalPart", "Clothing", "Accessory", "ProtectiveGear", "Ears", "Bag", "Container" },
    Supply = { "Food", "WaterContainer", "FirstAid", "FirstAidWeapon", "Cooking", "CookingWeapon", "FireSource",
               "LightSource" },
    Misc = { "Junk", "Memento", "Bug", "Sports", "Instrument", "InstrumentWeapon", "JunkWeapon", "Teddy Bear", "Fox",
             "Bunny", "Duck", "Frog", "Raccoon", "Bear", "Badger", "Squirrel", "Beaver", "Mole", "Hedgehog", "Dog",
             "Goblin", "Spider", "Eye", "Literature", "SkillBook", "RecipeResource", "Cartography", "Entertainment",
             "Electronics", "Communications", "Household", "HouseholdWeapon", "Appearance", "Security" },
}
Data.FAMILY_ORDER = { "Gear", "Supply", "Misc" }
-- The display categories the heavy-load nodes cover.
Data.MATERIAL_CATEGORIES = { "Material", "MaterialWeapon", "Paint" }

local nodes, byId = {}, {}
Data.nodes = nodes
Data.byId = byId

-- node(tree, id, row, col, ranks, kind, req, extra)
local function node(tree, id, row, col, ranks, kind, req, extra)
    local n = { id = id, tree = tree, row = row, col = col, ranks = ranks, kind = kind, req = req or {} }
    for k, v in pairs(extra or {}) do n[k] = v end
    nodes[#nodes + 1] = n
    byId[id] = n
    return n
end

-- Four columns a tree (the research tab sets the three side by side). Every prerequisite sits straight above its node
-- with the cells between empty, so each line runs straight down (a unit test holds it); each capstone stands in the
-- second column, under the middle of its tree.
-- ---- Scout: field detection research (10 nodes, 25 points, capstone Night Eye) --------------------------------------
node("scout", "sight", 1, 2, 3, "api", {}, { cap = 90, unit = "deg", values = { 24, 48, 72 } })
node("scout", "sixth", 1, 1, 2, "lua", {}, { unit = "tiles", values = { 4, 8 } })
node("scout", "alarm", 1, 3, 1, "lua")
node("scout", "ledger", 1, 4, 3, "lua", {}, { rankText = true, adds = true, unit = "pct", values = { 0, 0, 200 } })
node("scout", "rich", 2, 3, 3, "api", {}, { unit = "pct", values = { 15, 30, 50 } })
node("scout", "night", 2, 2, 3, "api", {}, { cap = 100, unit = "pct", values = { 20, 40, 60 } })
node("scout", "sense", 3, 1, 2, "lua", { { "sixth", 2 } }, { rankText = true, adds = true })
node("scout", "keen", 3, 4, 3, "lua", {}, { unit = "pct", values = { 10, 20, 30 } })
node("scout", "ammo", 4, 3, 2, "api", { { "rich", 2 } }, { unit = "pct", values = { 50, 100 } })
node("scout", "sensePlus", 4, 1, 3, "lua", { { "sense", 2 } }, { rankText = true, adds = true })
node("scout", "nightEye", 5, 2, 1, "api", { { "night", 3 } }, { capstone = true })

-- ---- Load: load adaptation research (10 nodes, 25 points, capstone Armor Constitution) -------------------------------
-- overload values: the share of the excess weight that still counts; the rest is what the node takes away.
node("load", "overload", 1, 1, 2, "api", {}, { unit = "pct", values = { 70, 40 }, rankText = true })
node("load", "moveSpeed", 1, 3, 3, "lua", {}, { cap = 95, unit = "pct", values = { 20, 35, 50 } })
node("load", "keyring", 1, 4, 1, "api")
node("load", "furniture", 1, 2, 2, "api", {}, { unit = "pct", lighter = true, values = { 50, 100 } })
node("load", "materials", 2, 4, 3, "api", {}, { unit = "pct", lighter = true, values = { 15, 30, 45 } })
node("load", "runSpeed", 2, 2, 2, "api", {}, { cap = 95, unit = "pct", values = { 30, 60 } })
node("load", "capacity", 3, 1, 5, "api", { { "overload", 2 } }, { unit = "num", values = { 2, 4, 6, 8, 10 } })
node("load", "combatSpeed", 3, 2, 2, "api", { { "runSpeed", 2 } }, { cap = 95, unit = "pct", values = { 30, 60 } })
-- materialsPlus values: the total efficiency from the base node and this one together (it replaces the base node's).
node("load", "materialsPlus", 4, 4, 2, "api", { { "materials", 3 } }, { unit = "pct", lighter = true, values = { 70, 100 } })
node("load", "storage", 4, 3, 3, "api", { { "moveSpeed", 2 } }, { unit = "pct", values = { 20, 40, 60 } })
node("load", "armor", 5, 2, 1, "api", { { "combatSpeed", 2 } }, { capstone = true })

-- ---- Survival: survival adaptation research (10 nodes, 25 points, capstone Breakthrough Sprint) ---------------------
node("survival", "serumAdapt", 1, 1, 2, "lua", {}, { rankText = true })
node("survival", "crowbar", 1, 2, 2, "lua", {}, { cap = 100, unit = "pct", values = { 35, 50 }, rankText = true, adds = true })
node("survival", "stiff", 1, 3, 3, "api", {}, { cap = 95, unit = "pct", values = { 20, 40, 60 } })
node("survival", "fall", 2, 1, 3, "api", {}, { rankText = true })
node("survival", "lock", 2, 4, 2, "lua", {}, { cap = 100, unit = "pct", values = { 50, 90 }, rankText = true, adds = true })
node("survival", "brush", 2, 2, 2, "api", {}, { cap = 100, unit = "pct", values = { 50, 100 }, rankText = true })
node("survival", "gear", 3, 3, 3, "api", {}, { cap = 95, unit = "pct", values = { 20, 40, 60 } })
node("survival", "resist", 3, 4, 3, "api", {}, { cap = 95, unit = "pct", values = { 20, 40, 60 } })
node("survival", "walk", 4, 2, 3, "api", { { "brush", 1 } }, { unit = "pct", values = { 5, 10, 15 } })
node("survival", "resistPlus", 4, 4, 2, "api", { { "resist", 3 } }, { cap = 95, unit = "pct", values = { 30, 60 }, rankText = true })
node("survival", "dash", 5, 2, 1, "lua", { { "walk", 3 } }, { capstone = true })

-- ---- The 2nd board: endless nodes, rank k costs ceil(k / 5) points -------------------------------------------------
-- form "divide": the effect is a reduction sum, a value is divided by (1 + sum); "add": the amount adds up;
-- "approach": the sum is 0.1 per rank and the bonus is limit * sum / (1 + sum). step is per rank (a fraction, or the
-- amount itself for "add"). group: the column of the board; row: the node's cell in it, counted four a line (a cell
-- left out stays empty).
local function board(id, group, row, form, step, kind, extra)
    local n = { id = id, tree = Data.BOARD, group = group, row = row, form = form, step = step, kind = kind, req = {},
                board = true }
    for k, v in pairs(extra or {}) do n[k] = v end
    nodes[#nodes + 1] = n
    byId[id] = n
    return n
end

-- the weight line first: materials and furniture, then a node a family (bFamilyGear ...)
board("bHeavy", "load", 1, "divide", 0.20, "api")
for i, family in ipairs(Data.FAMILY_ORDER) do
    board("bFamily" .. family, "load", 1 + i, "divide", 0.10, "api", { family = family })
end
board("bGear", "load", 5, "divide", 0.10, "api")
board("bSpeedPen", "load", 6, "divide", 0.10, "api")
board("bOverload", "load", 7, "divide", 0.10, "api")
board("bTransfer", "load", 8, "divide", 0.10, "lua")
board("bLimit", "load", 9, "add", 1, "api", { unit = "num" })
board("bStorage", "load", 10, "add", 0.05, "api", { unit = "pct100" })
board("bWound", "survival", 1, "divide", 0.10, "api")
board("bIllness", "survival", 2, "divide", 0.10, "api")
board("bBite", "survival", 3, "divide", 0.10, "lua")
board("bStiff", "survival", 4, "divide", 0.10, "api")
board("bEndurance", "survival", 5, "divide", 0.05, "api")
board("bSleep", "survival", 6, "divide", 0.05, "api")
board("bGearLoss", "survival", 7, "divide", 0.10, "api")
board("bFall", "survival", 8, "divide", 0.10, "api")
board("bDash", "survival", 9, "divide", 0.10, "lua")
board("bWalk", "survival", 10, "approach", 0.10, "api", { limit = 0.40 })
board("bLoot", "scout", 1, "approach", 0.10, "api", { limit = 1.00 })
board("bShard", "scout", 2, "approach", 0.10, "lua", { limit = 0.30 })
board("bBundle", "scout", 3, "add", 0.02, "lua", { unit = "num" })

-- Node icons (media/textures, made by the assets part; the file name is OA_Node_<slug>.png).
local ICONS = {
    sight = "SightCone", sixth = "Hunch", alarm = "AlarmRead",
    ledger = "SearchLog", rich = "RichSearch", night = "NightEye",
    sense = "Presence", keen = "SampleGrade", ammo = "AmmoSearch",
    sensePlus = "PresenceRadar", nightEye = "NocturnalEye", overload = "Overload",
    moveSpeed = "TransferSpeed", keyring = "KeyRing", furniture = "FurnitureWeight",
    materials = "MaterialWeight", runSpeed = "RunSpeed", capacity = "CarryCapacity",
    combatSpeed = "CombatSpeed", materialsPlus = "MaterialWeightPlus", storage = "StorageCapacity",
    armor = "ArmorBody", serumAdapt = "SerumAdapt", crowbar = "CrowbarPry",
    stiff = "LimbStiffness", fall = "BreakFall", lock = "LockPick",
    brush = "BrushClear", gear = "GearCare", resist = "InfectionResist",
    walk = "WalkSpeed", resistPlus = "InfectionResistPlus", dash = "BreakSprint",
    bHeavy = "B2HeavyLoad", bGear = "B2GearAdapt",
    bSpeedPen = "B2GearSpeed", bOverload = "B2OverloadPenalty", bTransfer = "B2TransferTime",
    bLimit = "B2CarryLimit", bStorage = "B2StorageCapacity", bWound = "B2ScratchInfect",
    bIllness = "B2SicknessRate", bBite = "B2BiteCooldown", bStiff = "B2LimbFatigue",
    bEndurance = "B2Stamina", bSleep = "B2SleepFatigue", bGearLoss = "B2GearDamage",
    bFall = "B2FallDamage", bDash = "B2SprintStamina", bWalk = "B2WalkSpeed",
    bLoot = "B2LootChance", bShard = "B2SelectedSample", bBundle = "B2SampleBundle",
    bFamilyGear = "B2FamilyGear", bFamilySupply = "B2FamilySupply", bFamilyMisc = "B2FamilyMisc",
}
for id, slug in pairs(ICONS) do
    local n = byId[id]
    if n then
        n.icon = "media/textures/OA_Node_" .. slug .. ".png"
        -- the same icon in grey, for a node that is not open yet (tools/node_icons.py writes both)
        n.iconGray = "media/textures/OA_Node_" .. slug .. "_Gray.png"
    end
end

-- A capstone's icon while its tree is sealed, by tree: a question mark on the capstone's badge (grey, as a node not
-- yet open), which tells nothing of the capstone.
Data.SEALED_ICON = {
    scout = "media/textures/OA_Node_SealedScout_Gray.png",
    load = "media/textures/OA_Node_SealedLoad_Gray.png",
    survival = "media/textures/OA_Node_SealedSurvival_Gray.png",
}

-- The board's columns in order (the order of the tree tabs), and each column's nodes.
Data.BOARD_GROUPS = { "scout", "load", "survival" }

-- The lists below are made once, here, from the nodes above (they are fixed from this point): the research window and
-- the rules ask for them per frame and per node. The lists are shared: a caller only reads them.
local EMPTY = {}
local byTree, capstoneOf, byGroup = {}, {}, {}
for _, n in ipairs(nodes) do
    local list = byTree[n.tree]
    if not list then
        list = {}
        byTree[n.tree] = list
    end
    list[#list + 1] = n
    if n.capstone and not capstoneOf[n.tree] then capstoneOf[n.tree] = n end
    if n.board then
        local group = byGroup[n.group]
        if not group then
            group = {}
            byGroup[n.group] = group
        end
        group[#group + 1] = n
    end
end
for _, group in pairs(byGroup) do
    table.sort(group, function(a, b) return a.row < b.row end)
end

-- The nodes of a column of the board, by row. Shared: read, not changed.
function Data.boardGroup(group)
    return byGroup[group] or EMPTY
end

-- The nodes of a tree in the order they are written (the capstone last). Shared: read, not changed.
function Data.treeNodes(tree)
    return byTree[tree] or EMPTY
end

function Data.capstone(tree)
    return capstoneOf[tree]
end

-- The translation key of a node's text: part is "Name", "Note", "Desc" or "Rank".
function Data.key(id, part)
    return "IGUI_OA_Tree_Node_" .. id .. "_" .. part
end

return Data
