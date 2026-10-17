-- This mod's loot (Loot.lua): its kinds of loot as the API takes them (the options a kind requires worked out of the
-- features its items need), its items put into the game's lists, and how a found filter and box are set as the game
-- spawns them; the control boards a box holds and its upgrades take (Costs); its design learned at one only by who
-- does not know it, with a screwdriver, in the light.
require "BuildingUtilities/Changes"
require "BuildingUtilities/Loot"
require "BuildingUtilities/Costs"
local BU = BuildingUtilities
local Loot, Costs, Panels = BU.Loot, BU.Costs, BU.Panels

ItemTag = { SCREWDRIVER = "screwdriver", PLIERS = "pliers", PIPE_WRENCH = "pipewrench" }

local function kindOf(id)
    for _, kind in ipairs(Loot.KINDS) do if kind.id == id then return kind end end
end

local function text(requires)
    if requires == nil then return "nil" end
    local parts = {}
    for _, entry in ipairs(requires) do
        parts[#parts + 1] = type(entry) == "table" and "(" .. table.concat(entry, "|"):gsub("BuildingUtilities%.", "") .. ")"
            or (entry:gsub("BuildingUtilities%.", ""))
    end
    return table.concat(parts, " ")
end

test("a kind requires the options its features need, any of its features on", function()
    eq(text(Loot.requires({ "solar" })), "EnableSolar EnablePower", "solar: its own and power's")
    eq(text(Loot.requires({ "panel" })), "(EnablePower|EnableWater)", "the box: either utility")
    eq(text(Loot.requires({ "pump", "sprinkler" })), "(EnablePumps|EnableSprinklers) EnableWater (EnablePower|EnableSprinklers)",
        "pumps (water, power) or sprinklers (water)")
    eq(text(Loot.requires({ "booster", "filter", "firesprinkler" })),
        "(EnableBoosters|EnableFilters|EnableFireSprinklers) EnableWater (EnableFilters|EnableFireSprinklers|EnablePower)",
        "boosters (water, power), filters or fire sprinklers (water)")
    eq(text(Loot.requires({ "junction" })), "EnablePower", "a feature with no option of its own: those it needs")
    eq(Loot.requires({ "nothing" }), nil, "a name that is no feature's needs nothing")
end)

test("each kind is defined with the API, by its option, items and requirements", function()
    local defined = {}
    PZExtAPI.loot = { define = function(handle, id, spec) defined[id] = spec; return "BuildingUtilities:" .. id end }
    eq(Loot.define(), true)
    for _, kind in ipairs(Loot.KINDS) do truthy(defined[kind.id], kind.id) end
    local panel = defined.Panel
    eq(panel.option, "BuildingUtilities.BreakerBoxLoot")
    eq(table.concat(panel.items, ","), "BuildingUtilities.BreakerBox,BuildingUtilities.ControlBoard")
    eq(text(panel.requires), "(EnablePower|EnableWater)")
    PZExtAPI.loot = { define = function() error("refused") end }
    eq(Loot.define(), true, "a kind refused is said in the log; the others go on")
    PZExtAPI.loot = nil
    eq(Loot.define(), false, "an API without loot kinds")
end)

test("its items go into the game's lists with their weights; a list the game lacks is left out", function()
    ProceduralDistributions = { list = { GeneratorRoom = { rolls = 4, items = { "ElectricWire", 10 } } } }
    VehicleDistributions = { ElectricianTruckBed = { rolls = 4, items = {} } }
    local said, savedPrint = 0, print
    print = function() said = said + 1 end
    Loot.distribute()
    print = savedPrint
    truthy(said > 0, "the lists the game lacks are said")
    local room = ProceduralDistributions.list.GeneratorRoom.items
    local found = {}
    for i = 1, #room, 2 do found[room[i]] = room[i + 1] end
    eq(found.ElectricWire, 10, "the game's own stay")
    eq(found["BuildingUtilities.BreakerBox"], 2)
    eq(found["BuildingUtilities.ControlBoard"], 4)
    eq(found["BuildingUtilities.FireSprinkler"], 0.5)
    local truck = VehicleDistributions.ElectricianTruckBed.items
    found = {}
    for i = 1, #truck, 2 do found[truck[i]] = truck[i + 1] end
    eq(found["BuildingUtilities.BreakerBox"], 0.5)
    eq(found["BuildingUtilities.ControlBoard"], 2)
    ProceduralDistributions, VehicleDistributions = nil, nil
end)

test("a filter found has part of its media spent; a box found marks its container's owner", function()
    local item = { data = {} }
    function item:getModData() return self.data end
    function item:getFullType() return "BuildingUtilities.WaterFilter" end
    function item:setName() end
    function item:setCustomName() end
    getItemNameFromFullType = function() return "Water Filter" end
    ZombRandFloat = function() return 0.5 end
    Loot.foundFilter(item)
    local media = item.data[BU.Units.KEPT].media
    truthy(math.abs(media - BU.WaterUnits.FILTER_HOURS * 0.3) < 1e-9, "halfway between a tenth and a half of a charge: " .. media)
    local owner, part = { data = {} }, { data = {} }
    for _, each in ipairs({ owner, part }) do function each:getModData() return self.data end end
    local inRoom = { getContainer = function() return { getVehiclePart = function() return nil end, getParent = function() return owner end } end }
    Loot.foundBox(inRoom)
    eq(owner.data[BU.BOX_MARK], true, "the container's object")
    local inVehicle = { getContainer = function() return { getVehiclePart = function() return part end, getParent = function() return nil end } end }
    Loot.foundBox(inVehicle)
    eq(part.data[BU.BOX_MARK], true, "the vehicle's part")
    Loot.foundBox({ getContainer = function() return nil end })
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

test("night sight counts for the dark: the game's reading rule asked of the light it lifts", function()
    local light = 0.31
    local character = {}
    function character:tooDarkToRead() return (light + light) / 2 < 0.43 end
    function character:getCurrentSquare() return { getLightLevel = function() return light end } end
    function character:getPlayerNum() return 0 end
    function character:getWornItemsVisionModifier() return 1 end
    PZExtAPI = PZExtAPI or {}
    PZExtAPI.formulas = { nightSight = function() return { floor = 0 } end }
    eq(Panels.tooDark(character), true, "no night sight: the game's rule")
    PZExtAPI.formulas = { nightSight = function() return { floor = 0.45 } end }
    eq(Panels.tooDark(character), false, "0.31 lifted by 0.45 is 0.52: light enough")
    light = 0.05
    PZExtAPI.formulas = { nightSight = function() return { floor = 0.25 } end }
    eq(Panels.tooDark(character), true, "0.05 lifted by 0.25 is 0.28: still dark")
    light = 0.6
    eq(Panels.tooDark(character), false, "light enough without it")
end)
