-- P8 assets, in game: puts the trade tiles and the lure down on the squares east of the player and every machine whole
-- (each look: stopped and running, S E N W; the multi-tile ones on their footprints from the anchor), checks the tile
-- properties the sheets define (facing, grid position and group on every tile; the container and the rain collector
-- only on the anchor), gives the player every item (where its script exists), checks the item icons and the tree node
-- icons loaded as textures, and looks for the backpack's model script and clothing item.
-- Run from the debug console (single player, a character standing in open ground): RUN("p8_assets.lua") with the
-- loader from base-utilities' tests/ingame/README.md pointed at the folder this file is in. Lines are tagged "[p8]",
-- each "ok" or "BAD", ending with "done". Then LOOK at the tiles (the trade tiles in a row north of you, then the machine
-- looks in two columns beside you, four directions each, stopped before running) and, if the backpack item exists, at yourself wearing
-- it (P8_WEAR()). P8_CLEAN() takes the tiles and the items it gave away again.
local function say(...) print("[p8]", ...) end
local function check(what, ok, extra) say(ok and "ok" or "BAD", what, extra and tostring(extra) or "") end

local player = getPlayer()
if not player then say("BAD no player"); return end
local cell = getCell()
local origin = player:getSquare()
if not origin then say("BAD player has no square"); return end
-- The game keeps only about 24 squares around the player loaded: everything goes within that. The trade tiles in a row
-- 12 north, one square apart; the machine looks in two columns (west and east of the player, who stands in the gap
-- between them) of bands three squares deep, starting 9 north.
local px, py, oz = origin:getX(), origin:getY(), origin:getZ()
local ox, oy = px - 8, py - 12

if P8_CLEAN then P8_CLEAN() end
P8_PLACED = {}
P8_GIVEN = {}

local function sprite(name)
    return IsoSpriteManager.instance:getSprite(name)
end
local function prop(sp, key)
    local props = sp and sp:getProperties()
    if not props then return nil end
    -- B42's PropertyContainer: get(name) for a value, has(name) for a flag or a property without one.
    local val = props:get(key)
    if val and val ~= "" then return val end
    if props:has(key) then return true end
    -- A flag (solidtrans, IsLow ...) is asked for by its IsoFlagType, not by name.
    local flag = IsoFlagType[key]
    if flag and props:has(flag) then return true end
    return nil
end

local Sprites = OperationAcorn and OperationAcorn.Sprites
if not Sprites then say("BAD OperationAcorn.Sprites is not loaded (the mod is not enabled?)"); return end

local bad, placed = 0, 0
local function wrong(...) say("BAD", ...); bad = bad + 1 end

local function squareAt(x, y, z)
    return cell:getGridSquare(x, y, z)
end
local function placeTile(sq, name)
    local obj = IsoObject.new(sq, name, nil, false)
    sq:AddSpecialObject(obj)
    P8_PLACED[#P8_PLACED + 1] = { sq = sq, obj = obj }
    placed = placed + 1
    return obj
end

-- The 1x1 trade tiles (and the lure): each loaded, its properties as the sheet defines them, then placed two squares apart.
local TRADE = {
    { "oa_trade_01", 0, 8, "terminal", { Facing = true, solidtrans = true } },
    { "oa_trade_01", 8, 1, "delivery box", { container = "crate" } },
    { "oa_trade_01", 9, 1, "sealed delivery box", { container = false } },
    { "oa_trade_01", 10, 1, "sealed supply crate", { container = false } },
    { "oa_trade_01", 11, 1, "supply crate", { container = "militarycrate" } },
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
            local sq = squareAt(x0 + column, y0, oz)
            if sq then placeTile(sq, name) else wrong("no square for", name) end
            column = column + 1
        end
    end
end
for _, on in ipairs({ true, false }) do
    local name = Sprites.lure(on)
    if checkProps(name, "lure", { IsLow = true }) then
        local sq = squareAt(x0 + column, y0, oz)
        if sq then placeTile(sq, name) else wrong("no square for", name) end
        column = column + 1
    end
end

-- The machines, each placed whole: its tiles on the squares of its footprint from the anchor (the min-x, min-y square),
-- the stopped, ready and running looks side by side, the four directions along each, three squares apart. The
-- sheet's rules for them: facing and grid position on every tile, one group, the container (research storage) and the
-- rain collector flag on the anchor only; the rain storage is the empty tank with the water level set as overlay.
local DIRS = { "S", "E", "N", "W" }
local KINDS = { "shredBench", "bulkShredder", "cutter", "woodSaw", "researchStorage", "propaneRefiner", "oilRefiner",
    "rainStorage" }
local RUNS = { bulkShredder = true, cutter = true, woodSaw = true, propaneRefiner = true, oilRefiner = true }
local look = 0
local machines = 0
for _, kind in ipairs(KINDS) do
    for _, running in ipairs(RUNS[kind] and { false, "ready", true } or { false }) do
        -- the rain storage does not turn: its four looks are the water levels, empty to full (the empty tank, 1 to 3 with the overlay)
        for d, dir in ipairs(kind == "rainStorage" and { 0, 1, 2, 3 } or DIRS) do
            local level
            if kind == "rainStorage" then level, dir = dir, "S" end
            local tiles = Sprites.machineTiles(kind, dir, running)
            local w, h = Sprites.footprint(kind, dir)
            if not tiles or #tiles ~= w * h then
                wrong(kind, dir, "machineTiles gives", tiles and #tiles or "nothing", "want", w * h)
            else
                local ax = px + (look % 2 == 0 and -12 or 2) + (d - 1) * 3
                local ay = py - 9 + math.floor(look / 2) * 3
                local group
                for _, t in ipairs(tiles) do
                    local anchor = t.dx == 0 and t.dy == 0
                    local want = {
                        solidtrans = true,
                        SpriteGridPos = t.dx .. "," .. t.dy,
                        GroupName = true,
                        container = kind == "researchStorage" and "locker" or false,
                        IsWaterCollector = (kind == "rainStorage" and anchor) and true or false,
                        Facing = dir,
                    }
                    if kind == "rainStorage" then want.Facing = "S" end   -- one facing: the game builds its grid
                    if checkProps(t.sprite, kind .. " " .. dir, want) then
                        local g = prop(sprite(t.sprite), "GroupName")
                        group = group or g
                        if g ~= group then wrong(t.sprite, "group differs inside the machine", tostring(g), tostring(group)) end
                        local sq = squareAt(ax + t.dx, ay + t.dy, oz)
                        if sq then
                            local obj = placeTile(sq, t.sprite)
                            -- the rain storage's water level: an overlay on each square of the empty tank
                            if level and level >= 1 then
                                for _, o in ipairs(Sprites.rainOverlayTiles(level)) do
                                    if o.dx == t.dx and o.dy == t.dy then
                                        checkProps(o.sprite, "rain overlay " .. level, { IsWaterCollector = false, BlocksPlacement = false, solidtrans = false, container = false })
                                        obj:setOverlaySprite(o.sprite)
                                        if obj:getOverlaySprite() == nil then wrong(o.sprite, "overlay did not stick") end
                                    end
                                end
                            end
                        else
                            wrong("no square for", t.sprite)
                        end
                    end
                end
                machines = machines + 1
            end
        end
        look = look + 1
    end
end
check("tiles placed, machines whole", bad == 0, placed .. " tiles placed, " .. machines .. " machines, " .. bad .. " bad")

-- Every tile of both sheets is loaded (also those no look uses), by its place.
local missing = 0
for _, sheet in ipairs({ { "oa_trade_01", 16 }, { "oa_machines_01", 158 } }) do
    for index = 0, sheet[2] - 1 do
        local unused = sheet[1] == "oa_machines_01" and index >= 138 and index <= 145   -- places kept free (the rain levels are overlays)
        if not unused and not sprite(sheet[1] .. "_" .. index) then missing = missing + 1; say("BAD tile not loaded", sheet[1] .. "_" .. index) end
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
    "CommTerminal", "DeliveryBox", "TerminalManual", "SupplyManifest", "SampleBundle",
    "MeteorFragment", "UpgradeSerumScout", "UpgradeSerumLoad", "UpgradeSerumSurvival", "UpgradeSerumShared",
    "CureSerum", "DelayDrug", "DelayDrugLong", "InfectionReversal", "InfectionTestKit", "ShredBench", "BulkShredder", "Cutter", "PropaneRefiner", "OilRefiner", "WoodSaw",
    "ResearchStorage", "RainStorage", "Lure", "Motor", "MotorOld", "MotorNormal", "MotorModern", "ShredderBlade",
    "ShredderBladeOld", "ShredderBladeNormal", "ShredderBladeModern", "CuttingBlade", "CuttingBladeOld",
    "CuttingBladeNormal", "CuttingBladeModern", "SawBlade", "SawBladeOld", "SawBladeNormal", "SawBladeModern",
    "Catalyst", "CatalystOld", "CatalystNormal", "CatalystModern", "SoundproofCover", "SoundproofCoverOld",
    "SoundproofCoverNormal", "SoundproofCoverModern", "BagCapacityKit", "BagWeightKit", "TrunkKit",
    "EngineTuningKit", "ResearchBackpack", "FuelCanMk1", "FuelCanMk2", "FuelCanMk3", "WeldingTorchMk1",
    "WeldingTorchMk2", "WeldingTorchMk3", "MissionItem", "DocumentItem",
    "MissionEnvelope", "MissionSampleTin", "MissionLogbook", "MissionFilterCase", "MissionTape", "MissionFabricRoll", "MissionHeavyCase", "EvidenceEnvelope", "ClinicRecord",
    "WeatherLog", "FarmJournal", "SampleCooler", "RosterPage", "ReviewMemo", "WardRecord", "CellLog", "SoilSample",
    "StakeTag", "RosterLostPage", "FilterBundle", "PharmacyLedger", "CopyOriginal", "SampleCase", "DeadDropCase", "FieldCallDevice",
    "AnalysisReply", "Appendix", "SerumSheet", "UnresolvedList", "HandoverFile", "HandoverPages", "KitVoucher",
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
local noIcon = 0
for _, name in ipairs(ITEMS) do
    local tex = Texture.getSharedTexture("media/textures/Item_OA_" .. name .. ".png")
    if not tex then say("BAD icon texture missing", "Item_OA_" .. name); noIcon = noIcon + 1 end
end
say(noIcon == 0 and "ok" or "BAD", "item icon textures", (#ITEMS - noIcon) .. " of " .. #ITEMS)
-- Every item the mod defines, given once: each must show its own icon.
local given, blank = 0, 0
local all = ScriptManager.instance:getAllItems()
for i = 0, all:size() - 1 do
    local script = all:get(i)
    if script:getModuleName() == "OperationAcorn" then
        local full = script:getFullName()
        local ok, item = pcall(function() return player:getInventory():AddItem(full) end)
        if ok and item then
            given = given + 1
            P8_GIVEN[#P8_GIVEN + 1] = item
            local icon = item:getTexture()
            if not icon or icon:getName() == "Item_Unknown" or string.find(icon:getName(), "Question") then
                say("BAD item shows no icon", full); blank = blank + 1
            end
        else
            say("BAD could not give", full, tostring(item))
        end
    end
end
say(blank == 0 and given > 0 and "ok" or "BAD", "every item of the mod has its icon", given .. " items, " .. blank .. " without")

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
local pack = ScriptManager.instance:FindItem("OperationAcorn.TeamBackpack")
if pack then
    local item = player:getInventory():AddItem("OperationAcorn.TeamBackpack")
    P8_GIVEN[#P8_GIVEN + 1] = item
    check("backpack item has a clothing item", item and item:getClothingItem() ~= nil)
    check("backpack is a container", item and item:IsInventoryContainer())
    function P8_WEAR()
        ISTimedActionQueue.add(ISWearClothing:new(player, item, 50))
        say("wearing the backpack: look at its fit on the back (male and female), then drop it and look at the ground model, hold it in each hand")
    end
else
    say("info", "no TeamBackpack item script; the backpack model is checked once it exists")
end

function P8_CLEAN()
    for _, p in ipairs(P8_PLACED or {}) do pcall(function() p.sq:RemoveTileObject(p.obj) end) end
    for _, item in ipairs(P8_GIVEN or {}) do pcall(function() item:getContainer():Remove(item) end) end
    P8_PLACED, P8_GIVEN = {}, {}
    say("cleaned")
end
say("done", "tiles stand east of you; P8_CLEAN() takes everything away")
