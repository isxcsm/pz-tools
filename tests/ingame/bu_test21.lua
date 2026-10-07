-- Batch 3 of the plan (DESIGN 12), the water units: a pump put down away from water runs dry (draws its power, lifts
-- nothing), then lifts once a well stands beside it, and stops without power; a sprinkler waters a dry plant (a
-- stand-in for the farming system's) and shows its spray; a filter wears and purifies only with the
-- RiskPlumbingUnpurified option, runs out, and takes new media. "[bu21]" lines. Takes away what it put down and
-- leaves the option as it found it.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Networks, Water, Changes, Units, WaterUnits, WaterRun = BU.Store, BU.Networks, BU.Water, BU.Changes,
    BU.Units, BU.WaterUnits, BU.WaterRun
local say = BUT.say("bu21")
local function litres(value) return BUT.litres(value, 2) end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local player = getPlayer()
local status = ISBUPanelWindow.waterUnitStatus
say("panel tier", panel.tier, "supplied", Networks.state(panel, "power") and Networks.state(panel, "power").supplied,
    "pipes unpurified", WaterUnits.unpurifiedPipes())

-- Free outside squares near the player with free squares around them (for the well).
local used = {}
local function freeSquare()
    local q = BUT.squareNear(3, 14, function(q)
        local x, y = q:getX(), q:getY()
        local east = getCell():getGridSquare(x + 1, y, 0)
        return not used[x .. "," .. y] and not used[(x + 1) .. "," .. y] and east and q:isOutside() and east:isOutside()
            and q:getObjects():size() == 1 and east:getObjects():size() == 1 and q:isFree(false) and east:isFree(false)
            and not WaterUnits.waterBeside(q)
    end)
    if q then
        local x, y = q:getX(), q:getY()
        for ex = -1, 2 do for ey = -1, 1 do used[(x + ex) .. "," .. (y + ey)] = true end end
    end
    return q
end
local function put(kind)
    local square = freeSquare()
    local ok, reason = Units.canInstall(kind, square)
    local unit = Changes.installUnit(kind, square, Units.spriteFor(kind, square, player))
    Changes.connectUnit(unit, panel, {})
    say(kind, "at", unit.x, unit.y, "canInstall", ok, reason or "", "sprite", unit.sprite)
    return unit, square
end

-- The pump: dry, then beside a well, then without power. The test panel's power is taken as on (its state seen as
-- supplied) whatever its bank holds.
local realState = Networks.state
Networks.state = function(p, utility)
    local state = realState(p, utility)
    if utility ~= "power" or p ~= panel or not state then return state end
    local copy = {}
    for k, v in pairs(state) do copy[k] = v end
    copy.supplied = true
    return copy
end
local pump, pumpSquare = put("pump")
WaterRun.pumps(panel, 1)
local power = Networks.state(panel, "power")
say("dry: fluid", pump.fluid, "running", pump.running, "idle", pump.idle, "load", panel.extraLoads and panel.extraLoads.pumps,
    "flow", Units.definition("pump").flow(pump), "status", status(nil, pump))
local well = getCell():getGridSquare(pump.x + 1, pump.y, 0)
local wellObject = IsoObject.new(well, "camping_01_16", nil, false)
well:AddTileObject(wellObject)
say("well beside:", WaterUnits.waterBeside(pumpSquare))
local group = Networks.groupState(panel, WaterUnits.group(pump))
local before = group and group.amount
WaterRun.pumps(panel, 60)
say("wet: fluid", pump.fluid, "running", pump.running, "idle", pump.idle, "load", panel.extraLoads and panel.extraLoads.pumps,
    "flow", Units.definition("pump").flow(pump), "status", status(nil, pump), "held before", litres(before),
    "of", litres(group and group.capacity))
panel.tripped = true
WaterRun.pumps(panel, 1)
say("tripped: running", pump.running, "idle", pump.idle, "load", panel.extraLoads and panel.extraLoads.pumps, "status", status(nil, pump))
panel.tripped = nil
WaterRun.pumps(panel, 1)
local after = Networks.groupState(panel, WaterUnits.group(pump))
say("power back: running", pump.running, "idle", pump.idle, "held now", litres(after and after.amount))

-- The sprinkler, with a dry plant beside it in place of the farming system's.
local sprinkler = put("sprinkler")
local plant = { state = "seeded", waterLvl = 20, waterNeeded = 50, waterNeededMax = 80 }
function plant:water(_, uses) self.waterLvl = self.waterLvl + uses * 10 end
local realSystem = SFarmingSystem and SFarmingSystem.instance
local stand = { getLuaObjectAt = function(_, x, y)
    if x == sprinkler.x + 1 and y == sprinkler.y then return plant end
end }
local raining = RainManager.isRaining()
if SFarmingSystem then SFarmingSystem.instance = stand end
local okRun, err = pcall(WaterRun.sprinklers, panel)
if SFarmingSystem then SFarmingSystem.instance = realSystem end
say("sprinkler ran", okRun, okRun and "" or tostring(err), "raining", raining, "plant water", plant.waterLvl,
    "sprayedAt", sprinkler.sprayedAt ~= nil, "status", status(nil, sprinkler))
local sprinklerObject = Units.object(sprinkler)
Units.definition("sprinkler").sync(sprinkler, sprinklerObject)
say("sprinkler sprite", sprinklerObject and sprinklerObject:getSprite():getName())

-- The filter: rests with the game's pipes, wears with the option, runs out, takes new media.
local filter = put("filter")
local page = SandboxVars.BuildingUtilities
local option = page.RiskPlumbingUnpurified
local function purify()
    local state = Networks.groupState(panel, WaterUnits.group(filter))
    return state and state.purify
end
page.RiskPlumbingUnpurified = false
WaterRun.filters(panel, 60)
say("pipes purify: media", litres(filter.media), "purify", purify(), "status", status(nil, filter))
page.RiskPlumbingUnpurified = true
WaterRun.filters(panel, 60)
say("option on: media", litres(filter.media), "purify", purify(), "status", status(nil, filter))
filter.media = 0.5
WaterRun.filters(panel, 60)
say("spent: media", litres(filter.media), "purify", purify(), "title", Units.definition("filter").title(filter, "Filter"))
WaterRun.filters(panel, 1)
say("spent, a minute on: purify", purify())
local entry = Units.definition("filter").options(filter, player)[1]
say("replace option", entry.text, "reason", entry.reason)
Changes.replaceMedia(filter)
WaterRun.filters(panel, 1)
say("replaced: media", litres(filter.media), "purify", purify())
page.RiskPlumbingUnpurified = option
WaterRun.filters(panel, 1)
say("option back", option, "purify", purify())

-- Gone again.
well:transmitRemoveItemFromSquare(wellObject)
for _, unit in ipairs({ pump, sprinkler, filter }) do Changes.removeUnit(unit) end
WaterRun.pumps(panel, 1)
Networks.state = realState
say("cleaned: units", #Units.of(panel.id, "water"), "load", panel.extraLoads and panel.extraLoads.pumps)
