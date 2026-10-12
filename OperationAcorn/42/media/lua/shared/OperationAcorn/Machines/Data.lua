-- The base machines (P5): what each kind is, what its parts do, and every number NUMBERS.md chapter 11 sets. Pure
-- data, no game objects: the pure logic (Logic.lua) and the game side (Machines.lua) both read it.
require "OperationAcorn/Core"
require "OperationAcorn/Sprites"
local OA = OperationAcorn
OA.Machines = OA.Machines or {}
local Machines = OA.Machines
local Data = {}
Machines.Data = Data

-- The key a machine's state has in its anchor object's modData.
Data.KEY = "OA_Machine"
-- The module the machine and part items are in.
Data.MODULE = "OperationAcorn"

-- How fast the machines that work on things go, in one unit: game seconds a weight of what is put in, and the least
-- for one thing (NUMBERS 11). With the old motor a machine goes as fast as the work by hand; a better motor is its
-- bonus (the motor's lanes and speed below), besides working on its own. At the default day length a game minute is
-- 2.5 real seconds; a vanilla action tick is 1/30 real second.
--   shred: the hand bench's rule (the bulk shredder too): 5 game minutes a weight, some 12 real seconds.
--   cut: vanilla's ripping of a garment, 40 ticks (some 30 game seconds), for a garment of the median weight 0.3.
--   saw: vanilla's sawing of a log into planks, 230 ticks (some 3 game minutes), for a log of weight 9.
Data.WORK_SECONDS = {
    shred = { perWeight = 300, least = 30 },
    cut = { perWeight = 100, least = 30 },
    saw = { perWeight = 20, least = 30 },
}
-- The weight an hour the parts' wear (Data.PARTS wear, an hour) is for: a machine that works more an hour wears its
-- parts that much faster, so a part lasts the same weight on every machine (an old motor about 1,500).
Data.WEAR_WEIGHT = 30

local function rateOf(work) return 3600 / Data.WORK_SECONDS[work].perWeight end
local function wearOf(work) return rateOf(work) / Data.WEAR_WEIGHT end

-- Every machine kind. The names are Sprites.MACHINE_KINDS' (plus rainStorage and lure, which have one tile each).
--   item: the item type (in module OperationAcorn) the shop delivers and the player puts down.
--   weight: the whole machine's (scripts/OA_machines.txt and tools/tile_art.py say the same); the furniture tool's
--     pieces share it, one a tile.
--   power: true when it runs only with electricity. load: the generator load (NUMBERS 11: the unit is the vanilla
--     generator's per-device consumption, a fridge is 0.13). work: the kind of work (Data.WORK_SECONDS) of a machine
--     that works on things by weight. rate: work units an hour with the old motor (weight for those, litres for the
--     refiners). noise: the radius of the sound it makes while it runs (40, the saw 60: twice a vanilla generator's
--     20, so that it counts; a soundproof cover halves it). wear: the multiplier of its parts' wear an hour
--     (1 when missing; by weight, rate / Data.WEAR_WEIGHT).
--   slots: the part slots, in the order a window lists them. A slot a machine ships without is in `empty`.
--   inputs/outputs: the containers (titles IGUI_ContainerTitle_<type>); `in` is where things are put, `out` where
--     the products come out. A refiner has `in` only: the tank it fills stays in it.
Data.KINDS = {
    shredBench = {
        item = "ShredBench", weight = 20, hand = true, slots = {}, containers = {},
    },
    bulkShredder = {
        item = "BulkShredder", weight = 60, power = true, load = 0.6, work = "shred", rate = rateOf("shred"), wear = wearOf("shred"), noise = 40,
        slots = { "motor", "blade", "cover" }, empty = { cover = true }, containers = { "in", "out" }, containerAt = { out = { 1, 0 } },
    },
    cutter = {
        item = "FabricCutter", weight = 35, power = true, load = 0.4, work = "cut", rate = rateOf("cut"), wear = wearOf("cut"), noise = 40,
        slots = { "motor", "blade", "cover" }, empty = { cover = true }, containers = { "in", "out" }, containerAt = { out = { 1, 0 } },
    },
    propaneRefiner = {
        item = "PropaneRefinery", weight = 50, power = true, load = 0.3, rate = 2, noise = 40,
        slots = { "motor", "catalyst", "cover" }, empty = { cover = true }, containers = { "in", "tank" },
    },
    oilRefiner = {
        item = "OilRefinery", weight = 55, power = true, load = 0.3, rate = 0.5, noise = 40,
        slots = { "motor", "catalyst", "cover" }, empty = { cover = true }, containers = { "in", "tank" },
    },
    woodSaw = {
        item = "LogSaw", weight = 55, power = true, load = 0.8, work = "saw", rate = rateOf("saw"), wear = wearOf("saw"), noise = 60,
        slots = { "motor", "blade", "cover" }, empty = { cover = true }, containers = { "in", "out" },
        containerAt = { out = { 1, 0 } },
    },
    researchStorage = {
        -- a locker on each of its two squares, as a double wardrobe has a compartment a square
        item = "TeamLocker", weight = 40, slots = {}, containers = { "store" }, everyTile = true,
    },
    rainStorage = {
        item = "RainCistern", weight = 25, slots = {}, containers = {},
    },
    lure = {
        item = "BaitTrap", weight = 4, slots = {}, containers = {},
    },
}

-- The light a machine gives off around it at night (OA.Lights), by its look: `running`, and `ready` (switched on and
-- waiting: its lamps lit, nothing moving). { r, g, b, radius in squares }, in the colour of what is lit on its tiles:
-- the shredder's amber beacon, the cutter's panel lamps, the saw's work lamp, the propane refiner's flare, the oil
-- refiner's furnace lamps. The kinds not here give none (the bench, the locker, the rain storage, the lure).
Data.LIGHTS = {
    bulkShredder = { running = { 0.95, 0.6, 0.2, 4 }, ready = { 0.45, 0.3, 0.1, 2 } },
    cutter = { running = { 0.5, 0.65, 0.5, 3 }, ready = { 0.3, 0.4, 0.3, 2 } },
    woodSaw = { running = { 1.0, 0.92, 0.75, 6 }, ready = { 0.45, 0.42, 0.34, 2 } },
    propaneRefiner = { running = { 1.0, 0.55, 0.15, 6 }, ready = { 0.3, 0.4, 0.3, 2 } },
    oilRefiner = { running = { 0.95, 0.5, 0.18, 4 }, ready = { 0.45, 0.25, 0.1, 2 } },
}

-- The light of a kind in a look (Machines.refreshLook's: true running, "ready", or false), or nil.
function Data.lightOf(kind, look)
    local lights = Data.LIGHTS[kind]
    if not lights then return nil end
    if look == true then return lights.running end
    if look == "ready" then return lights.ready end
    return nil
end

-- The object modData key of the other squares of a multi-tile machine, pointing to its anchor.
Data.ANCHOR_KEY = "OA_Anchor"
-- The anchor's modData keys the PZ Tools API reads: OA_Capacity, a number (0 here), lifts the vanilla container cap for
-- the research storage (the API adds the number to the raw capacity and reads nothing but numbers) (the upgrades package names the key to the API); OA_Load is the machine's load multiplier (the
-- motor's power multiplier while it runs, else 0), for the generator hook's per-object multiplier.
Data.CAPACITY_KEY = "OA_Capacity"
Data.LOAD_KEY = "OA_Load"

-- The machine kind of an item type (without the module): BulkShredder -> bulkShredder.
Data.ITEM_KINDS = {}
for kind, def in pairs(Data.KINDS) do Data.ITEM_KINDS[def.item] = kind end

-- The kinds in the order the shop and the menus list them.
Data.ORDER = { "shredBench", "bulkShredder", "cutter", "propaneRefiner", "oilRefiner", "woodSaw", "researchStorage",
    "rainStorage", "lure" }

-- The kinds whose window opens (parts, work, rain or the lure to look at); the others are only picked up or used.
function Data.hasWindow(kind)
    local def = Data.KINDS[kind]
    return def ~= nil and (#def.slots > 0 or def.rate ~= nil or kind == "rainStorage" or kind == "lure")
end

-- The kinds that work by themselves on what is put in them (the ten-minute step and the chunk catch-up run these).
function Data.processes(kind)
    local def = Data.KINDS[kind]
    return def ~= nil and def.rate ~= nil
end

-- Containers. The type is the container's `type` string: the loot window shows IGUI_ContainerTitle_<type>.
Data.CONTAINERS = {
    ["in"] = { type = "OAMachineIn", capacity = 100 },
    out = { type = "OAMachineOut", capacity = 100 },
    -- a refiner's: the propane tanks or petrol cans it fills (apart from what it refines, so that what goes in and
    -- what comes out are not mixed)
    tank = { type = "OAMachineTank", capacity = 100 },
    -- 500 a square (NUMBERS 11): more than the biggest vanilla crate stacked three high (80 x 3). The vanilla cap of an
    -- object container is 100 (ItemContainer.MAX_CAPACITY, applied in getCapacity); the extension API lifts it.
    store = { type = "OAResearchStorage", capacity = 500 },
}
-- The translation keys of the container titles (written out so that tools/check_translations.py sees them used).
Data.TITLES = {
    OAMachineIn = "IGUI_ContainerTitle_OAMachineIn",
    OAMachineOut = "IGUI_ContainerTitle_OAMachineOut",
    OAMachineTank = "IGUI_ContainerTitle_OAMachineTank",
    OAResearchStorage = "IGUI_ContainerTitle_OAResearchStorage",
}

-- Big rain storage (NUMBERS 11): litres, and the rain factor (vanilla's rain collector is 400 and 0.4). Both live in
-- the entity script (scripts/OA_machines.txt, entity RainStorageEntity) as well, which is what the game uses.
Data.RAIN_CAPACITY = 4000
Data.RAIN_FACTOR = 4.0
Data.RAIN_ENTITY = "OperationAcorn.RainStorageEntity"
-- The game's largest rain barrel holds 600: pouring the rain storage out (the game's 비우기) goes this much faster, so a
-- full one empties in that barrel's time (about 7 minutes at normal speed, not 45). It must be empty to be taken up.
Data.RAIN_POUR_SPEED = Data.RAIN_CAPACITY / 600

-- The installable lure: lasts `hours` of world time from when it is put down, one sound every `interval` hours with
-- radius `radius` (vanilla NoiseTrap: 30 seconds and 17). After that only a spent shell is left.
Data.LURE = { hours = 24, interval = 0.25, radius = 60 }
-- The item modData key of a lure taken back while it worked: the hours it had left (put down again, it goes on from
-- there; a lure taken back does not come back new).
Data.LURE_LEFT_KEY = "OA_LureLeft"
-- The working lure's sound rings: a looping animation the game plays over it (IsoObject.AttachAnim loads the frames
-- <name>_<anim>_0 ..; they are in the machines texture pack, tools/tile_art.py lure_fx_frames). speed: frames a
-- sixtieth of a second (IsoSprite.update): 0.08, the six frames in some 1.25 seconds.
Data.LURE_FX = { name = "oa_lurefx", anim = "01", frames = 6, speed = 0.08 }
-- The object modData key the extension API steps attached animations by (anim.stepKey): 1 while the rings play.
Data.ANIM_KEY = "OA_Anim"


-- Conversions (NUMBERS 11).
Data.PROPANE_WEIGHT = 50 -- weight of rotten food that fills one empty tank (5 for each 10%)
Data.OIL_PER_PETROL = 0.8 -- litres of petrol from a litre of oil
-- Litres of oil in one item (NUMBERS 11: oil, olive oil and lard; seeds at twice vanilla's efficiency).
Data.OILS = {
    ["Base.OilVegetable"] = 1,
    ["Base.OilOlive"] = 1,
    ["Base.Lard"] = 0.3,
    ["Base.SunflowerSeeds"] = 1 / 90,
    ["Base.FlaxSeed"] = 1 / 450,
    ["Base.HempSeed"] = 1 / 450,
}
-- Items that are liquid in a bottle or a pack (a partly used one counts for what is left): the rest are seeds.
Data.OIL_FOOD = { ["Base.OilVegetable"] = true, ["Base.OilOlive"] = true, ["Base.Lard"] = true }

-- Parts (NUMBERS 11 'Part grades'). A part kind has the slot it fits and, by tier, what it does:
--   lanes, speed, power: the motor's lanes (how many things it works on at once, each at the machine's rate), and its
--     multipliers (speed of work, and the electricity it draws).
--   yield: a shredder blade's pack multiplier. pieces: a cutter blade's added pieces (expected). planks: a saw
--   blade's planks from a log (expected). use: a catalyst's material use (less is better). noise, speed: a cover's
--   multipliers on the machine's noise radius and speed.
--   wear: condition lost for each hour of running.
--   containers: its containers' roles (Data.CONTAINERS); containerAt: the square (sx, sy facing south) a role's container
--     is on, where the picture shows it (the bin the products fall in); the anchor when not given. everyTile: every
--     square has all its containers (the research storage's lockers).
-- Part items are `<Name><Tier>` in module OperationAcorn, with ConditionMax 100: MotorOld, MotorNormal, MotorModern,
-- ShredBladeOld ..., FilterOld ...; the cover has one item, SoundproofCover. (The shop, P1, names the same.)
Data.TIERS = { "old", "normal", "modern" }
Data.TIER_SUFFIX = { old = "Old", normal = "Normal", modern = "Modern" }
Data.PARTS = {
    motor = {
        slot = "motor", name = "Motor", role = "speed",
        tiers = {
            old = { lanes = 1, speed = 1.0, power = 1.0, wear = 2 },
            normal = { lanes = 2, speed = 1.15, power = 1.25, wear = 1.5 },
            modern = { lanes = 3, speed = 1.3, power = 1.5, wear = 1 },
        },
    },
    shredBlade = {
        slot = "blade", name = "ShredBlade", role = "yield", kinds = { "bulkShredder" },
        tiers = {
            old = { yield = 1.0, wear = 2 },
            normal = { yield = 1.1, wear = 1.5 },
            modern = { yield = 1.2, wear = 1 },
        },
    },
    cutBlade = {
        slot = "blade", name = "CutBlade", role = "yield", kinds = { "cutter" },
        tiers = {
            old = { pieces = 0, wear = 2 },
            normal = { pieces = 0.5, wear = 1.5 },
            modern = { pieces = 1, wear = 1 },
        },
    },
    sawBlade = {
        slot = "blade", name = "SawBlade", role = "yield", kinds = { "woodSaw" },
        tiers = {
            old = { planks = 6, wear = 2 },
            normal = { planks = 6.5, wear = 1.5 },
            modern = { planks = 7, wear = 1 },
        },
    },
    catalyst = {
        slot = "catalyst", name = "Filter", role = "yield", kinds = { "propaneRefiner", "oilRefiner" },
        tiers = {
            old = { use = 1.0, wear = 2 },
            normal = { use = 0.8, wear = 1.5 },
            modern = { use = 0.6, wear = 1 },
        },
    },
    cover = {
        slot = "cover", name = "SoundproofCover", item = "SoundproofCover", role = "cover",
        kinds = { "bulkShredder", "cutter", "propaneRefiner", "oilRefiner", "woodSaw" },
        tiers = {
            normal = { noise = 0.5, speed = 0.85, wear = 1.5 },
        },
    },
}

-- The part kind a slot of a machine kind takes: the motor fits every machine, the others the kinds they list.
function Data.partKind(kind, slot)
    if slot == "motor" then return "motor" end
    for name, def in pairs(Data.PARTS) do
        if def.slot == slot and def.kinds then
            for _, k in ipairs(def.kinds) do
                if k == kind then return name end
            end
        end
    end
    return nil
end

-- A part item's type name: Motor + Old, ... (the cover's is SoundproofCover whatever the tier).
function Data.partItem(part, tier)
    local def = Data.PARTS[part]
    if def.item then return def.item end
    return def.name .. Data.TIER_SUFFIX[tier]
end

-- Every part item as { part, tier } by its item type name (for a window that finds parts in an inventory).
Data.PART_ITEMS = {}
for part, def in pairs(Data.PARTS) do
    for tier in pairs(def.tiers) do
        Data.PART_ITEMS[Data.partItem(part, tier)] = { part = part, tier = tier }
    end
end

-- The parts: wear and what a worn part does (NUMBERS 11).
Data.CONDITION_MAX = 100
Data.WORN_BELOW = 25 -- under this condition a part slows the machine and cuts its output
Data.WORN_SPEED = 0.5
Data.WORN_YIELD = 0.8

-- Soft clothing that vanilla cannot rip, by its body location (the name after "base:"), and what the cutter makes of
-- it (REWARDS: hats and gloves 1 or 2 pieces, shoes 2 of leather).
Data.UNRIPPABLE = {
    hat = { low = 1, high = 2 }, fullhat = { low = 1, high = 2 },
    hands = { low = 1, high = 2 }, handsleft = { low = 1, high = 2 }, handsright = { low = 1, high = 2 },
    shoes = { low = 2, high = 2, material = "Leather" },
}
-- Names of hard or sealed headgear and the like, which no blade makes cloth of.
Data.UNRIPPABLE_NOT = { "Helmet", "HardHat", "GasMask", "Welding", "SCBA", "Visor", "Goggles", "Mask_", "Hazmat",
    "Boxing", "Football", "Hockey", "Baseball_Helmet", "Bone", "Metal", "Steel", "Chainmail", "Armor", "Plate" }
-- Gloves and hats whose name says leather or hide are cut into leather; so are shoes.
Data.LEATHER_NAMES = { "Leather", "Hide", "Fingerless", "Work", "Rubber", "Batting", "Boots", "Shoes" }


-- Work that one step of a machine does is cut to this many products, so that a long absence or a huge pile is taken
-- a few at a time (DESIGN 12, performance rules).
Data.BATCH = 80
-- A chunk load takes this many batches at most; the ten-minute step does the rest.
Data.CATCHUP_BATCHES = 3

return Data
