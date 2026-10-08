-- P8 assets, in game: puts every tile of the two sheets down on the squares east of the player, checks the tile
-- properties the sheets define, gives the player every item (where its script exists), checks the item icons and the
-- tree node icons loaded as textures, and looks for the backpack's model script and clothing item.
-- Run from the debug console (single player, a character standing in open ground): RUN("p8_assets.lua") with the
-- loader from base-utilities' tests/ingame/README.md pointed at the folder this file is in. Lines are tagged "[p8]",
-- each "ok" or "BAD", ending with "done". Then LOOK at the tiles (the rows east of you, north of the player: the trade
-- tiles first, then the machines, eight a row, in sheet order) and, if the backpack item exists, at yourself wearing
-- it (P8_WEAR()). P8_CLEAN() takes the tiles and the items it gave away again.
local function say(...) print("[p8]", ...) end
local function check(what, ok, extra) say(ok and "ok" or "BAD", what, extra and tostring(extra) or "") end

local player = getPlayer()
if not player then say("BAD no player"); return end
local cell = getCell()
local origin = player:getSquare()
if not origin then say("BAD player has no square"); return end
local ox, oy, oz = origin:getX() + 3, origin:getY() - 8, origin:getZ()

if P8_CLEAN then P8_CLEAN() end
P8_PLACED = {}
P8_GIVEN = {}

local function sprite(name)
    return IsoSpriteManager.instance:getSprite(name)
end
local function prop(sp, key)
    local props = sp and sp:getProperties()
    if not props then return nil end
    local ok, val = pcall(function() return props:Val(key) end)
    if ok and val and val ~= "" then return val end
    local ok2, has = pcall(function() return props:Is(key) end)
    if ok2 and has then return true end
    return nil
end

-- Which tiles (sheet, first index, count) and which properties each group must have (true: present).
local TILES = {
    { "oa_trade_01", 0, 8, "terminal", { Facing = true, solidtrans = true } },
    { "oa_trade_01", 8, 2, "delivery box", { container = "crate" } },
    { "oa_trade_01", 10, 2, "supply crate", { container = "militarycrate" } },
    { "oa_trade_01", 12, 1, "parachute crate", { solidtrans = true } },
    { "oa_trade_01", 13, 1, "scorched ground", {} },
    { "oa_trade_01", 14, 1, "meteor rocks", { IsLow = true } },
    { "oa_trade_01", 15, 1, "site stake", { IsLow = true } },
    { "oa_machines_01", 0, 4, "shred bench", { Facing = true, solidtrans = true } },
    { "oa_machines_01", 4, 8, "bulk shredder", { Facing = true, solidtrans = true } },
    { "oa_machines_01", 12, 8, "cutter", { Facing = true, solidtrans = true } },
    { "oa_machines_01", 20, 8, "propane refiner", { Facing = true, solidtrans = true } },
    { "oa_machines_01", 28, 8, "oil refiner", { Facing = true, solidtrans = true } },
    { "oa_machines_01", 36, 8, "wood saw", { Facing = true, solidtrans = true } },
    { "oa_machines_01", 44, 4, "research storage", { Facing = true, container = "locker" } },
    { "oa_machines_01", 48, 1, "rain storage", { IsWaterCollector = true, solidtrans = true } },
    { "oa_machines_01", 49, 2, "lure", { IsLow = true } },
}

local column, row = 0, 0
local function nextSquare(newRow)
    if newRow then row = row + (column > 0 and 1 or 0) + 1; column = 0 end
    if column >= 8 then column = 0; row = row + 1 end
    local sq = cell:getGridSquare(ox + column * 2, oy + row * 2, oz)
    column = column + 1
    return sq
end

local lastSheet = nil
local placed, bad = 0, 0
for _, group in ipairs(TILES) do
    local sheet, first, count, label, want = group[1], group[2], group[3], group[4], group[5]
    for index = first, first + count - 1 do
        local name = sheet .. "_" .. index
        local sp = sprite(name)
        if not sp then
            say("BAD tile not loaded", name, label); bad = bad + 1
        else
            for key, value in pairs(want) do
                local got = prop(sp, key)
                if value == true and not got then say("BAD", name, label, "missing property", key); bad = bad + 1
                elseif value ~= true and got ~= value then say("BAD", name, label, key, "is", tostring(got), "want", value); bad = bad + 1 end
            end
            local sq = nextSquare(lastSheet ~= nil and lastSheet ~= sheet)
            lastSheet = sheet
            if sq then
                local obj = IsoObject.new(sq, name, nil, false)
                sq:AddSpecialObject(obj)
                P8_PLACED[#P8_PLACED + 1] = { sq = sq, obj = obj }
                placed = placed + 1
            else
                say("BAD no square for", name)
            end
        end
    end
end
check("tiles placed", placed == 67 and bad == 0, placed .. " placed, " .. bad .. " bad")

-- Facing of the four-direction groups: south, east, north, west in order.
local order = { "S", "E", "N", "W" }
for _, probe in ipairs({ { "oa_trade_01", 0 }, { "oa_trade_01", 4 }, { "oa_machines_01", 0 }, { "oa_machines_01", 8 },
    { "oa_machines_01", 44 } }) do
    for i = 0, 3 do
        local sp = sprite(probe[1] .. "_" .. (probe[2] + i))
        check("facing " .. probe[1] .. "_" .. (probe[2] + i), prop(sp, "Facing") == order[i + 1], prop(sp, "Facing"))
    end
end

-- Items: given where their script exists; their icon texture must be there either way.
local ITEMS = {
    "CommTerminal", "DeliveryBox", "SupplyCrate", "TerminalManual", "SupplyManifest", "SampleBundle",
    "MeteorFragment", "UpgradeSerumScout", "UpgradeSerumLoad", "UpgradeSerumSurvival", "UpgradeSerumShared",
    "CureSerum", "DelayDrug", "ShredBench", "BulkShredder", "Cutter", "PropaneRefiner", "OilRefiner", "WoodSaw",
    "ResearchStorage", "RainStorage", "Lure", "Motor", "MotorOld", "MotorNormal", "MotorModern", "ShredderBlade",
    "ShredderBladeOld", "ShredderBladeNormal", "ShredderBladeModern", "CuttingBlade", "CuttingBladeOld",
    "CuttingBladeNormal", "CuttingBladeModern", "SawBlade", "SawBladeOld", "SawBladeNormal", "SawBladeModern",
    "Catalyst", "CatalystOld", "CatalystNormal", "CatalystModern", "SoundproofCover", "SoundproofCoverOld",
    "SoundproofCoverNormal", "SoundproofCoverModern", "BagCapacityKit", "BagWeightKit", "TrunkKit",
    "EngineTuningKit", "ResearchBackpack", "FuelCanMk1", "FuelCanMk2", "FuelCanMk3", "WeldingTorchMk1",
    "WeldingTorchMk2", "WeldingTorchMk3", "MissionItem", "DocumentItem",
}
local given, missingScript, noIcon = 0, 0, 0
for _, name in ipairs(ITEMS) do
    local tex = Texture.getSharedTexture("media/textures/Item_OA_" .. name .. ".png")
    if not tex then say("BAD icon texture missing", "Item_OA_" .. name); noIcon = noIcon + 1 end
    local full = "OperationAcorn." .. name
    if ScriptManager.instance:FindItem(full) then
        local ok, item = pcall(function() return player:getInventory():AddItem(full) end)
        if ok and item then
            given = given + 1
            P8_GIVEN[#P8_GIVEN + 1] = item
            local icon = item:getTexture()
            if not icon or icon:getName() == "Item_Unknown" then say("BAD item shows no icon", full) end
        else
            say("BAD could not give", full, tostring(item))
        end
    else
        missingScript = missingScript + 1
    end
end
say(noIcon == 0 and "ok" or "BAD", "item icon textures", (#ITEMS - noIcon) .. " of " .. #ITEMS)
say("info", "items given", given, "no item script yet", missingScript)

-- Tree node icons.
local NODES = {
    "OA_Node_SightCone.png", "OA_Node_Hunch.png", "OA_Node_AlarmRead.png", "OA_Node_SearchLog.png",
    "OA_Node_RichSearch.png", "OA_Node_NightEye.png", "OA_Node_Presence.png", "OA_Node_KeenEye.png",
    "OA_Node_AmmoSearch.png", "OA_Node_PresenceRadar.png", "OA_Node_NocturnalEye.png", "OA_Node_Overload.png",
    "OA_Node_TransferSpeed.png", "OA_Node_KeyRing.png", "OA_Node_FurnitureWeight.png", "OA_Node_MaterialWeight.png",
    "OA_Node_RunSpeed.png", "OA_Node_CarryCapacity.png", "OA_Node_CombatSpeed.png", "OA_Node_MaterialWeightPlus.png",
    "OA_Node_StorageCapacity.png", "OA_Node_ArmorBody.png", "OA_Node_SerumAdapt.png", "OA_Node_CrowbarPry.png",
    "OA_Node_LimbStiffness.png", "OA_Node_BreakFall.png", "OA_Node_LockPick.png", "OA_Node_BrushClear.png",
    "OA_Node_GearCare.png", "OA_Node_InfectionResist.png", "OA_Node_WalkSpeed.png",
    "OA_Node_InfectionResistPlus.png", "OA_Node_BreakSprint.png", "OA_Node_B2HeavyLoad.png",
    "OA_Node_B2CategoryWeight.png", "OA_Node_B2GearAdapt.png", "OA_Node_B2GearSpeed.png",
    "OA_Node_B2OverloadPenalty.png", "OA_Node_B2TransferTime.png", "OA_Node_B2CarryLimit.png",
    "OA_Node_B2StorageCapacity.png", "OA_Node_B2ScratchInfect.png", "OA_Node_B2SicknessRate.png",
    "OA_Node_B2BiteCooldown.png", "OA_Node_B2LimbFatigue.png", "OA_Node_B2Stamina.png", "OA_Node_B2SleepFatigue.png",
    "OA_Node_B2GearDamage.png", "OA_Node_B2FallDamage.png", "OA_Node_B2SprintStamina.png", "OA_Node_B2WalkSpeed.png",
    "OA_Node_B2LootChance.png", "OA_Node_B2MeteorShard.png", "OA_Node_B2SampleBundle.png",
    "OA_Node_B2PresenceRadius.png", "OA_Node_B2HunchRadius.png",
}
local noNode = 0
for _, file in ipairs(NODES) do
    if not Texture.getSharedTexture("media/textures/" .. file) then say("BAD node icon missing", file); noNode = noNode + 1 end
end
say(noNode == 0 and "ok" or "BAD", "node icon textures", (#NODES - noNode) .. " of " .. #NODES)

-- The research backpack: its model script, and the item if its package exists.
local model = ScriptManager.instance:getModelScript("OperationAcorn.OA_ResearchPack_Ground")
check("ground model script", model ~= nil)
local pack = ScriptManager.instance:FindItem("OperationAcorn.ResearchBackpack")
if pack then
    local item = player:getInventory():AddItem("OperationAcorn.ResearchBackpack")
    P8_GIVEN[#P8_GIVEN + 1] = item
    check("backpack item has a clothing item", item and item:getClothingItem() ~= nil)
    check("backpack is a container", item and item:IsInventoryContainer())
    function P8_WEAR()
        ISTimedActionQueue.add(ISWearClothing:new(player, item, 50))
        say("wearing the backpack: look at its fit on the back (male and female), then drop it and look at the ground model, hold it in each hand")
    end
else
    say("info", "no ResearchBackpack item script yet (P6); the backpack model is checked once it exists")
end

function P8_CLEAN()
    for _, p in ipairs(P8_PLACED or {}) do pcall(function() p.sq:RemoveTileObject(p.obj) end) end
    for _, item in ipairs(P8_GIVEN or {}) do pcall(function() item:getContainer():Remove(item) end) end
    P8_PLACED, P8_GIVEN = {}, {}
    say("cleaned")
end
say("done", "tiles stand east of you; P8_CLEAN() takes everything away")
