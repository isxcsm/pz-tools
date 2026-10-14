-- How a first utility panel is had (tier rework, 0): where the game keeps generators, at a share of its own chance
-- (Loot.generatorChance, Loot.boxChance, Loot.fillBox), and the control boards a box holds and its upgrades take
-- (Costs); its design learned at one only by who does not know it, with a screwdriver, in the light.
require "BuildingUtilities/Changes"
require "BuildingUtilities/Loot"
require "BuildingUtilities/Costs"
local BU = BuildingUtilities
local Loot, Costs, Panels = BU.Loot, BU.Costs, BU.Panels

ItemPickerJava = { getLootModifier = function() return 1 end }
ItemTag = { SCREWDRIVER = "screwdriver", PLIERS = "pliers", PIPE_WRENCH = "pipewrench" }
getSandboxOptions = function() return { getCurrentLootMultiplier = function() return 1 end } end
TEST.random = 0
ZombRandFloat = function() return TEST.random end
getScriptManager = function() return { FindItem = function() return { getActualWeight = function() return 3 end } end } end

-- The game's tables: a generator crate (one generator in 20 junk rolls of 10 percent), an electronics store whose
-- crates take it one time in four, and a work truck with a generator at weight 1 in four rolls.
ProceduralDistributions = { list = {
    CrateGenerator = { rolls = 1, items = { "Screwdriver", 10 }, junk = { rolls = 20, items = { "Generator", 10 / 1.4 } } },
    CrateTV = { rolls = 1, items = { "TV", 10 } },
} }
SuburbsDistributions = {
    electronicstore = { other = { procedural = true, procList = {
        { name = "CrateGenerator", min = 0, max = 1, weightChance = 1 },
        { name = "CrateTV", min = 0, max = 1, weightChance = 3 } } } },
}
VehicleDistributions = { {
    Van = { Normal = { TruckBed = { rolls = 4, items = { "Generator", 1 } } },
            Specific = { { TruckBed = { rolls = 1, items = { "Rope", 5 } } } } },
}, }
VehicleDistributions[1].Truck = VehicleDistributions[1].Van

-- A container that fills: of a building (its object) or of a vehicle's part (a vehicle of a script's special chance).
local function container(kind, special)
    local owner = { data = {} }
    function owner:getModData() return self.data end
    local vehicle = kind == "vehicle" and {
        getSkinIndex = function() return 0 end,
        getScript = function() return { getSpecialLootChance = function() return special or 0 end } end,
    } or nil
    local part = vehicle and { data = {}, getVehicle = function() return vehicle end } or nil
    if part then function part:getModData() return self.data end end
    local items = {}
    return {
        items = items, owner = part or owner,
        getVehiclePart = function() return part end, getParent = function() return owner end,
        getSourceGrid = function() return nil end, hasRoomFor = function() return true end,
        AddItem = function(_, item) items[#items + 1] = item; return item end,
    }
end

local function near(actual, expected, what)
    if math.abs(actual - expected) > 1e-6 then
        error((what and what .. ": " or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

test("a generator's chance is worked out of the game's tables, a building's and a vehicle's", function()
    local crate = 1 - (1 - 0.1) ^ 20
    near(Loot.generatorChance("electronicstore", "other", container("building")), crate / 4, "one crate in four")
    eq(Loot.generatorChance("kitchen", "counter", container("building")), 0, "no generator there")
    local truck = 1 - (1 - 0.01) ^ 4
    near(Loot.generatorChance("Van", "TruckBed", container("vehicle")), truck * 0.92, "its normal lists, 92 percent")
    near(Loot.generatorChance("Truck", "TruckBed", container("vehicle", 50)), truck * 0.5, "a script's special share")
end)

test("a utility panel comes at half that, by the option, and marks its container's owner", function()
    local crate = 1 - (1 - 0.1) ^ 20
    near(Loot.boxChance("electronicstore", "other", container("building")), crate / 4 * Loot.BOX_SHARE)
    SandboxVars.BuildingUtilities = { BreakerBoxLoot = 2 }
    near(Loot.boxChance("electronicstore", "other", container("building")), crate / 4 * Loot.BOX_SHARE * 2, "twice")
    SandboxVars.BuildingUtilities = { BreakerBoxLoot = 0 }
    eq(Loot.boxChance("electronicstore", "other", container("building")), 0, "none at 0")
    SandboxVars.BuildingUtilities = {}
    local found = container("vehicle")
    Loot.fillBox("Van", "TruckBed", found)
    eq(found.items[1], Loot.BOX)
    eq(found.owner.data[Loot.BOX_MARK], true, "the vehicle's part marked")
    TEST.random = 0.99
    local missed = container("building")
    Loot.fillBox("electronicstore", "other", missed)
    eq(#missed.items, 0, "past its chance, none")
    eq(missed.owner.data[Loot.BOX_MARK], nil)
end)

test("a zombie's inventory, which fills with no container type, gets nothing and raises nothing", function()
    local corpse = container("building")
    TEST.random = 0
    Loot.fill("Zombie", nil, corpse)
    eq(#corpse.items, 0)
    TEST.random = nil
end)

test("a box holds a board, and one more for each its upgrades took: 1, 2, 4, 8", function()
    eq(Costs.boardsIn(1), 1)
    eq(Costs.boardsIn(2), 2)
    eq(Costs.boardsIn(3), 4)
    eq(Costs.boardsIn(4), 8)
    for tier = 2, 4 do
        local boards = 0
        for _, item in ipairs(Costs.upgrade(tier).items) do
            if item[1] == Costs.BOARD then boards = item[2] end
        end
        eq(boards, Costs.BOARDS[tier], "tier " .. tier)
    end
end)

test("the design is learned at a box only by one who does not know it, with a screwdriver, in the light", function()
    SandboxVars.BuildingUtilities = { CostsEnabled = true }
    local character = { known = false, dark = false, tools = true }
    function character:isRecipeActuallyKnown(name) return name == Panels.RECIPE and self.known end
    function character:tooDarkToRead() return self.dark end
    function character:getPerkLevel() return 0 end
    function character:getInventory()
        local tools = self.tools
        return { getFirstTagEvalRecurse = function() return tools and {} or nil end }
    end
    eq(Panels.reverseEngineerProblem(character), nil)
    character.dark = true
    eq(Panels.reverseEngineerProblem(character), "dark")
    character.tools = false
    eq(Panels.reverseEngineerProblem(character), "tool")
    character.known = true
    eq(Panels.reverseEngineerProblem(character), "known")
end)
