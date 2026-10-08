-- P8 assets, in game: puts the trade tiles and the lure down on the squares east of the player and every machine whole
-- (each look: stopped and running, S E N W; the multi-tile ones on their footprints from the anchor), checks the tile
-- properties the sheets define (facing, grid position and group on every tile; the container and the rain collector
-- only on the anchor), gives the player every item (where its script exists), checks the item icons and the tree node
-- icons loaded as textures, and looks for the backpack's model script and clothing item.
-- Run from the debug console (single player, a character standing in open ground): RUN("p8_assets.lua") with the
-- loader from base-utilities' tests/ingame/README.md pointed at the folder this file is in. Lines are tagged "[p8]",
-- each "ok" or "BAD", ending with "done". Then LOOK at the tiles (the rows east of you, north of the player: the trade
-- tiles first, then a row of four directions for each machine look, stopped before running) and, if the backpack item exists, at yourself wearing
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

local Sprites = OperationAcorn and OperationAcorn.Sprites
if not Sprites then say("BAD OperationAcorn.Sprites is not loaded (the mod is not enabled?)"); return end

local bad, placed = 0, 0
local function wrong(...) say("BAD", ...); bad = bad + 1 end

local function placeTile(sq, name)
    local obj = IsoObject.new(sq, name, nil, false)
    sq:AddSpecialObject(obj)
    P8_PLACED[#P8_PLACED + 1] = { sq = sq, obj = obj }
    placed = placed + 1
end

-- The 1x1 trade tiles (and the lure): each loaded, its properties as the sheet defines them, then placed two squares apart.
local TRADE = {
    { "oa_trade_01", 0, 8, "terminal", { Facing = true, solidtrans = true } },
    { "oa_trade_01", 8, 2, "delivery box", { container = "crate" } },
    { "oa_trade_01", 10, 2, "supply crate", { container = "militarycrate" } },
    { "oa_trade_01", 12, 1, "parachute crate", { solidtrans = true } },
    { "oa_trade_01", 13, 1, "scorched ground", {} },
    { "oa_trade_01", 14, 1, "meteor rocks", { IsLow = true } },
    { "oa_trade_01", 15, 1, "site stake", { IsLow = true } },
}
local function checkProps(name, label, want)
    local sp = sprite(name)
    if not sp then wrong("tile not loaded", name, label); return false end
    for key, value in pairs(want) do
        local got = prop(sp, key)
        if value == true and not got then wrong(name, label, "missing property", key)
        elseif value == false and got then wrong(name, label, "must not have", key, tostring(got))
        elseif value ~= true and value ~= false and got ~= value then wrong(name, label, key, "is", tostring(got), "want", value) end
    end
    return true
end
local x0, y0 = ox, oy
local column = 0
for _, group in ipairs(TRADE) do
    for index = group[2], group[2] + group[3] - 1 do
        local name = group[1] .. "_" .. index
        if checkProps(name, group[4], group[5]) then
            local sq = cell:getGridSquare(x0 + column * 2, y0, oz)
            if sq then placeTile(sq, name) else wrong("no square for", name) end
            column = column + 1
        end
    end
end
for _, on in ipairs({ true, false }) do
    local name = Sprites.lure(on)
    if checkProps(name, "lure", { IsLow = true }) then
        local sq = cell:getGridSquare(x0 + column * 2, y0, oz)
        if sq then placeTile(sq, name) else wrong("no square for", name) end
        column = column + 1
    end
end

-- The machines, each placed whole: its tiles on the squares of its footprint from the anchor (the min-x, min-y square),
-- a stopped look and a running look in a row, the four directions along it, every machine four squares apart. The
-- sheet's rules for them: facing and grid position on every tile, one group, the container (research storage) and the
-- rain collector flag on the anchor only (of each of the rain storage's four water levels).
local DIRS = { "S", "E", "N", "W" }
local KINDS = { "shredBench", "bulkShredder", "cutter", "woodSaw", "researchStorage", "propaneRefiner", "oilRefiner",
    "rainStorage" }
local RUNS = { bulkShredder = true, cutter = true, woodSaw = true, propaneRefiner = true, oilRefiner = true }
local ROW0 = 3
local row = ROW0
local machines = 0
for _, kind in ipairs(KINDS) do
    for _, running in ipairs(RUNS[kind] and { false, true } or { false }) do
        -- the rain storage does not turn: its four looks are the water levels, empty to full
        for d, dir in ipairs(kind == "rainStorage" and { 0, 1, 2, 3 } or DIRS) do
            local level
            if kind == "rainStorage" then level, dir = dir, "S" end
            local tiles = level and Sprites.rainStorageTiles(level) or Sprites.machineTiles(kind, dir, running)
            local w, h = Sprites.footprint(kind, dir)
            if not tiles or #tiles ~= w * h then
                wrong(kind, dir, "machineTiles gives", tiles and #tiles or "nothing", "want", w * h)
            else
                local ax, ay = x0 + (d - 1) * 5, y0 + row * 2
                local group
                for _, t in ipairs(tiles) do
                    local anchor = t.dx == 0 and t.dy == 0
                    local want = {
                        solidtrans = true,
                        SpriteGridPos = t.dx .. "," .. t.dy,
                        GroupName = true,
                        container = (kind == "researchStorage" and anchor) and "locker" or false,
                        IsWaterCollector = (kind == "rainStorage" and anchor) and true or false,
                        Facing = kind == "rainStorage" and false or dir,
                    }
                    if checkProps(t.sprite, kind .. " " .. dir, want) then
                        local g = prop(sprite(t.sprite), "GroupName")
                        group = group or g
                        if g ~= group then wrong(t.sprite, "group differs inside the machine", tostring(g), tostring(group)) end
                        local sq = cell:getGridSquare(ax + t.dx, ay + t.dy, oz)
                        if sq then placeTile(sq, t.sprite) else wrong("no square for", t.sprite) end
                    end
                end
                machines = machines + 1
            end
        end
        row = row + 3
    end
end
check("tiles placed, machines whole", bad == 0, placed .. " tiles placed, " .. machines .. " machines, " .. bad .. " bad")

-- Every tile of both sheets is loaded (also those no look uses), by its place.
local missing = 0
for _, sheet in ipairs({ { "oa_trade_01", 16 }, { "oa_machines_01", 146 } }) do
    for index = 0, sheet[2] - 1 do
        if not sprite(sheet[1] .. "_" .. index) then missing = missing + 1; say("BAD tile not loaded", sheet[1] .. "_" .. index) end
    end
end
check("every tile of the sheets is loaded", missing == 0, missing .. " missing")

-- Facing of the trade terminal tiles: south, east, north, west in order.
local order = { "S", "E", "N", "W" }
for _, first in ipairs({ 0, 4 }) do
    for i = 0, 3 do
        local sp = sprite("oa_trade_01_" .. (first + i))
        check("facing oa_trade_01_" .. (first + i), prop(sp, "Facing") == order[i + 1], prop(sp, "Facing"))
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
    "MissionEnvelope", "MissionSampleTin", "MissionLogbook", "MissionFilterCase", "MissionTape", "MissionFabricRoll", "EvidenceEnvelope", "ClinicRecord",
    "WeatherLog", "FarmJournal", "SampleCooler", "RosterPage", "ReviewMemo", "WardRecord", "CellLog", "SoilSample",
    "StakeTag", "RosterLostPage", "FilterBundle", "PharmacyLedger", "CopyOriginal", "SampleCase", "DeadDropCase", "FieldCallDevice",
    "AnalysisReply", "Appendix", "SerumSheet", "UnresolvedList", "HandoverFile", "KitVoucher",
}
-- The machines package's item names where they differ from the icon names (Item_OA_<icon>.png).
local ALIAS = { Cutter = "FabricCutter", PropaneRefiner = "PropaneRefinery", OilRefiner = "OilRefinery", WoodSaw = "LogSaw",
    ResearchStorage = "TeamLocker", RainStorage = "RainCistern", Lure = "BaitTrap", ShredderBlade = "ShredBlade",
    CuttingBlade = "CutBlade", Catalyst = "Filter" }
local function itemName(icon)
    for from, to in pairs(ALIAS) do
        if string.sub(icon, 1, string.len(from)) == from then return to .. string.sub(icon, string.len(from) + 1) end
    end
    return icon
end
local given, missingScript, noIcon = 0, 0, 0
for _, name in ipairs(ITEMS) do
    local tex = Texture.getSharedTexture("media/textures/Item_OA_" .. name .. ".png")
    if not tex then say("BAD icon texture missing", "Item_OA_" .. name); noIcon = noIcon + 1 end
    local full = "OperationAcorn." .. itemName(name)
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
