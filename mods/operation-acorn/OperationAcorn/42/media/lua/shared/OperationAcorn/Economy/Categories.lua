-- The market categories A..K (NUMBERS 1 and 12): what an item is worth per weight, and what the team does not take.
-- Pure: it reads an `info` table (OA.Value.info makes one from a game item) and never touches the game.
--
-- Judging order (NUMBERS 1): the exceptions named by item id come first (cash, this mod's goods, the do-not-take
-- list), then the item type (furniture), then the DisplayCategory. Vanilla `Money` is Junk (category E): looked up
-- in the other order it would sell as a knick-knack.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Categories = {}
OA.Categories = Categories

Categories.LETTERS = { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K" }

-- Credits per unit of weight (NUMBERS 1). Trust per weight is this over 100.
Categories.UNIT = {
    A = 250, B = 400, C = 300, D = 450, E = 350, F = 350, G = 600, H = 300, I = 500, J = 250, K = 150,
}

-- The translation key of a category's name.
function Categories.nameKey(letter)
    return "IGUI_OA_Econ_Cat_" .. tostring(letter)
end

-- DisplayCategory -> category (NUMBERS 12). A category the table does not know is E (another mod's).
local function fill(map, letter, names)
    for name in string.gmatch(names, "[^,]+") do map[name] = letter end
end

Categories.BY_DISPLAY = {}
local D = Categories.BY_DISPLAY
fill(D, "A", "Food")
fill(D, "B", "Clothing,Accessory,ProtectiveGear,Ears")
-- "Water" is only the plastic water bottle (and a test mug): a container like the rest.
fill(D, "C", "Bag,Container,WaterContainer,Water")
fill(D, "D", "Literature,SkillBook,RecipeResource,Cartography,Entertainment")
fill(D, "E", "Junk,Memento,Bug,Teddy Bear,Fox,Bunny,Duck,Frog,Raccoon,Bear,Badger,Squirrel,Beaver,Mole,Hedgehog,"
    .. "Dog,Goblin,Spider,Eye,Sports,Instrument,InstrumentWeapon,JunkWeapon")
fill(D, "F", "Household,Cooking,CookingWeapon,HouseholdWeapon,Appearance,Security,FireSource,LightSource")
fill(D, "G", "Electronics,Communications")
fill(D, "H", "Tool,ToolWeapon,VehicleMaintenance,VehicleMaintenanceWeapon,Gardening,GardeningWeapon,Fishing,"
    .. "FishingWeapon,Camping,Trapping")
fill(D, "I", "FirstAid,FirstAidWeapon")
fill(D, "J", "Weapon,SportsWeapon,WeaponPart,WeaponCrafted,BrokenWeapon,WeaponImprovised")
fill(D, "K", "Material,MaterialWeapon,Paint")

-- The categories the team never takes, with the reason (the key suffix of IGUI_OA_Econ_Reject_<reason>).
Categories.REJECT_DISPLAY = {
    Ammo = "Ammo", Explosives = "Explosive",
    ZedDmg = "Body", Wound = "Body", Bandage = "Body", MaleBody = "Body", Tail = "Body", Hidden = "Body",
    Corpse = "Body", Animal = "Body", Generic = "Body",
    AnimalPart = "AnimalPart", AnimalPartWeapon = "AnimalPart",
}

-- Item ids (without the module) that are never taken.
Categories.REJECT_ID = {
    LargeMeteorite = "Meteor",
    -- Natural materials that grow back (NUMBERS 1).
    Log = "Nature", LogStacks2 = "Nature", LogStacks3 = "Nature", LogStacks4 = "Nature",
    Plank = "Nature", Plank_Broken = "Nature", TreeBranch2 = "Nature", Branch_Broken = "Nature",
    Twigs = "Nature", TwigsBundle = "Nature", Stone = "Nature", Stone2 = "Nature",
    Dirtbag = "Nature", Sandbag = "Nature", Gravelbag = "Nature", Claybag = "Nature", Clay = "Nature",
}

-- Item id prefixes that are never taken: ammunition containers, and animal dung.
Categories.REJECT_PREFIX = {
    { "Bag_AmmoBox", "Ammo" }, { "AmmoStrap", "Ammo" }, { "Bag_ProtectiveCaseBulkyAmmo", "Ammo" },
    { "Dung_", "AnimalPart" },
}

-- The name of an item type without its module: "Base.Money" -> "Money".
function Categories.shortName(fullType)
    local name = string.match(tostring(fullType), "%.([^%.]+)$")
    return name or tostring(fullType)
end

-- The item's name as the codex counts kinds: no module for the base game, and a colour variant (TINT) is its base.
local baseTypes = {}
function Categories.baseType(fullType)
    local hit = fullType ~= nil and baseTypes[fullType]
    if hit then return hit end
    local name = tostring(fullType)
    if string.sub(name, 1, 5) == "Base." then name = string.sub(name, 6) end
    name = string.gsub(name, "_TINT", "")
    name = string.gsub(name, "TINT", "")
    -- (kept for the session: an item type's name is fixed, and the codex asks it of every item it counts)
    if fullType ~= nil then baseTypes[fullType] = name end
    return name
end

-- True when the item type is from the base game (module Base, or no module given).
function Categories.isVanilla(fullType)
    local module = string.match(tostring(fullType), "^([^%.]+)%.")
    return module == nil or module == "Base"
end

-- Why an item type is never taken by its id, or false: kept by full type for the session (the lists are fixed).
local idRejects = {}
local function idRejectedAt(fullType)
    -- The id lists name vanilla items: another mod's item of the same name is judged by its DisplayCategory.
    if Categories.isVanilla(fullType) then
        local id = Categories.shortName(fullType)
        local why = Categories.REJECT_ID[id]
        if why then return why end
        for _, pair in ipairs(Categories.REJECT_PREFIX) do
            if string.sub(id, 1, #pair[1]) == pair[1] then return pair[2] end
        end
    end
    return false
end
local function idRejected(fullType)
    if fullType == nil then return idRejectedAt(fullType) end
    local why = idRejects[fullType]
    if why == nil then
        why = idRejectedAt(fullType)
        idRejects[fullType] = why
    end
    return why
end

-- The category letter of an item, or nil and why it is not taken: a reason name ("Ammo", "Furniture", "Bought" ...)
-- or "Cash" / "Own" for what the value rules handle before this (OA.Value). `info` as in ARCHITECTURE 5.
function Categories.of(info)
    if info.cash then return nil, "Cash" end
    if info.own then return nil, "Own" end
    local why = idRejected(info.fullType)
    if why then return nil, why end
    if info.bought then return nil, "Bought" end
    if info.moveable then return nil, "Furniture" end
    local display = info.displayCategory
    if display then
        why = Categories.REJECT_DISPLAY[display]
        if why then return nil, why end
        return D[display] or "E"
    end
    return "E"
end

-- True for what a player can loot as an item kind: the codex counts these. Body overlays and the like, this mod's
-- goods and the shop's goods are no loot.
function Categories.isLoot(info)
    if info.own or info.bought then return false end
    local display = info.displayCategory
    return not (display and Categories.REJECT_DISPLAY[display] == "Body")
end

-- A reason name as its translation key.
function Categories.reasonKey(reason)
    return "IGUI_OA_Econ_Reject_" .. tostring(reason)
end

return Categories
