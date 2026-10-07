-- The sandbox's features page (BU.enabled): each toggle turned off in SandboxVars at runtime, the world brought to it
-- (Changes.applyFeatures, as the server's minute does) and the passes that use it run; what is off must do nothing
-- and be hidden, and come back once it is on again. Then both utilities off together, the plan's supply lines'
-- switch (flow, lines, off, and a producer's line under the mouse), its supply across floors (riser, badge, strip
-- mark) and its top bar at the least width. Puts a pump, a sprinkler and a filter down near the player, wired to the
-- test panel (bu_setup.lua; tier 2 or more), and takes them away; leaves the options, the switch and the panel as it
-- found them. "[bufeat]" lines, each check "ok" or "BAD".
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Networks, Panels, Changes, Units, Energy, Water, WaterUnits, WaterRun, PanelLook, PanelWindow = BU.Store,
    BU.Networks, BU.Panels, BU.Changes, BU.Units, BU.Energy, BU.Water, BU.WaterUnits, BU.WaterRun, BU.PanelLook,
    BU.PanelWindow
local say = BUT.say("bufeat")
local bad = 0
local function check(what, got, want)
    if got ~= want then bad = bad + 1 end
    say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want))
end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local api = PZToolsAPI
local player = getPlayer()
local page = SandboxVars.BuildingUtilities
local OPTIONS = { "EnablePower", "EnableWater", "EnableSolar", "EnableBatteries", "EnableChargeController",
    "EnablePumps", "EnableSprinklers", "EnableFilters" }
local saved = {}
for _, name in ipairs(OPTIONS) do saved[name] = page[name] end
local savedRisk, savedTier = page.RiskPlumbingUnpurified, panel.tier
local function set(name, on)
    page[name] = on
    Changes.applyFeatures()
end
local function allOn()
    for _, name in ipairs(OPTIONS) do page[name] = true end
    Changes.applyFeatures()
end
allOn()
say("panel", panel.id, "tier", panel.tier, "features", BU.featureKey())

-- The rules between them: a kind needs its utility, the controller its racks, the pump both utilities.
page.EnablePower = false
check("power off: solar", BU.enabled("solar"), false)
check("power off: controller", BU.enabled("controller"), false)
check("power off: pump", BU.enabled("pump"), false)
check("power off: sprinkler", BU.enabled("sprinkler"), true)
page.EnablePower, page.EnableWater = true, false
check("water off: filter", BU.enabled("filter"), false)
check("water off: rack", BU.enabled("rack"), true)
page.EnableWater, page.EnableBatteries = true, false
check("racks off: controller", BU.enabled("controller"), false)
page.EnableBatteries = true

-- The recipes hide and refuse while what they make is off.
local function recipeShown(name)
    return BuildingUtilitiesRecipeShown({ player = player, recipe = getScriptManager():getCraftRecipe("BuildingUtilities." .. name) })
end
page.EnableSolar = false
check("solar off: recipe shown", recipeShown("MakeSolarPanel"), false)
check("solar off: recipe test", BU.RecipeTest.MakeSolarPanel(), false)
check("solar off: rack recipe shown", recipeShown("MakeBatteryRack"), true)
page.EnableSolar = true
check("solar on: recipe shown", recipeShown("MakeSolarPanel"), true)

-- Water units near the player, wired to the test panel (tier 2 at least for them).
if (panel.tier or 1) < WaterUnits.TIER then panel.tier = WaterUnits.TIER end
local used = {}
local function freeSquare()
    local q = BUT.squareNear(3, 14, function(q)
        return not used[q:getX() .. "," .. q:getY()] and BUT.freeOutside(q) and not WaterUnits.waterBeside(q)
    end)
    if q then
        for dx = -1, 1 do for dy = -1, 1 do used[(q:getX() + dx) .. "," .. (q:getY() + dy)] = true end end
    end
    return q
end
local function put(kind)
    local square = freeSquare()
    local unit = Changes.installUnit(kind, square, Units.spriteFor(kind, square, player))
    Changes.connectUnit(unit, panel, {})
    return unit, square
end
local pump, pumpSquare = put("pump")
local sprinkler = put("sprinkler")
local filter = put("filter")
-- The test panel's power is taken as on, whatever its supply, as in bu_test21.
local realState = Networks.state
Networks.state = function(p, utility)
    local state = realState(p, utility)
    if utility ~= "power" or p ~= panel or not state then return state end
    local copy = {}
    for k, v in pairs(state) do copy[k] = v end
    copy.supplied = true
    return copy
end

-- Power off: no power network (the API forgets it), the box dark, no power devices, nothing of power to install or
-- connect, pumps stopped and drawing nothing; on again: all back.
local powerId = BU.networkId(panel.id, "power")
local devicesBefore = #Panels.devices(panel, "power")
WaterRun.pumps(panel, 1)
say("pump with power: running", pump.running, "load", panel.extraLoads and panel.extraLoads.pumps)
set("EnablePower", false)
check("power off: API network", api.networks.state(powerId), nil)
check("power off: state", Networks.state(panel, "power"), nil)
check("power off: look", PanelLook.wanted(panel), "off")
check("power off: devices", #Panels.devices(panel, "power"), 0)
check("power off: install solar", select(2, Units.canInstall("solar", freeSquare())), "disabled")
check("power off: power units", #Units.of(panel.id, "power"), 0)
check("power off: has source", Energy.hasSource(panel), false)
WaterRun.pumps(panel, 60)
check("power off: pump running", pump.running, nil)
check("power off: pumps load", panel.extraLoads and panel.extraLoads.pumps, nil)
local loadNote = getText("IGUI_BU_UpgradeNote", string.format("%.2f", BU.capacity(2)))
check("power off: upgrade note tells load", Panels.upgradeNote(2, true):find(loadNote, 1, true) ~= nil, false)
check("power off: water state", Networks.state(panel, "water") ~= nil, BU.waterAvailable())
set("EnablePower", true)
check("power on: API network", api.networks.state(powerId) ~= nil, true)
check("power on: devices back", #Panels.devices(panel, "power"), devicesBefore)
check("power on: look", PanelLook.wanted(panel) ~= nil, true)

-- Solar panels and racks off: none in the source; the bank gone; on again: as before.
local sourceBefore = Energy.hasSource(panel)
set("EnableSolar", false)
check("solar off: output count", select(2, Energy.output(panel)), 0)
set("EnableBatteries", false)
check("racks off: bank", Energy.bank(panel), nil)
check("solar and racks off: has source", Energy.hasSource(panel), false)
check("solar and racks off: source in network", Energy.sourceState(api.networks.state(powerId)), nil)
set("EnableSolar", true)
set("EnableBatteries", true)
check("solar and racks on: has source", Energy.hasSource(panel), sourceBefore)

-- The charge controller off: tier 3 runs as tier 2 (no quiet hours, no hand-over floor).
panel.tier = math.max(panel.tier, BU.CONTROLLER_TIER)
set("EnableChargeController", false)
check("controller off: has controller", Energy.hasController(panel), false)
check("controller off: quiet", Energy.rules(panel, api.networks.state(powerId) or {}).quiet, false)
set("EnableChargeController", true)
check("controller on: has controller", Energy.hasController(panel), true)
panel.tier = math.max(savedTier or 1, WaterUnits.TIER)

-- Pumps off alone: stand still and draw nothing; on: run again (dry, with power).
local waterUnits = #Units.of(panel.id, "water")
set("EnablePumps", false)
WaterRun.pumps(panel, 60)
check("pumps off: running", pump.running, nil)
check("pumps off: load", panel.extraLoads and panel.extraLoads.pumps, nil)
check("pumps off: water units listed", #Units.of(panel.id, "water"), waterUnits - 1)
check("pumps off: install", select(2, Units.canInstall("pump", freeSquare())), "disabled")
set("EnablePumps", true)
WaterRun.pumps(panel, 60)
check("pumps on: running", pump.running, true)

-- Sprinklers off: a dry plant beside one stays dry; on: watered.
local plant = { state = "seeded", waterLvl = 20, waterNeeded = 50, waterNeededMax = 80 }
function plant:water(_, uses) self.waterLvl = self.waterLvl + uses * 10 end
local realSystem = SFarmingSystem and SFarmingSystem.instance
local stand = { getLuaObjectAt = function(_, x, y)
    if x == sprinkler.x + 1 and y == sprinkler.y then return plant end
end }
local function sprinkle()
    if SFarmingSystem then SFarmingSystem.instance = stand end
    local ok, err = pcall(WaterRun.sprinklers, panel)
    if SFarmingSystem then SFarmingSystem.instance = realSystem end
    if not ok then say("BAD sprinklers:", tostring(err)) end
end
set("EnableSprinklers", false)
sprinkle()
check("sprinklers off: plant water", plant.waterLvl, 20)
set("EnableSprinklers", true)
sprinkle()
say("sprinklers on: plant water", plant.waterLvl, "(more than 20 unless it rains or the tanks are empty; raining",
    RainManager.isRaining(), ")")

-- Filters off with the pipes leaving water unpurified: rest, keep their media, purify nothing; on: work.
page.RiskPlumbingUnpurified = true
local function purify()
    local state = Networks.groupState(panel, WaterUnits.group(filter))
    return state and state.purify
end
WaterRun.filters(panel, 60)
say("filter on: working", filter.working, "purify", purify(), "(true, true with the purification hooks)")
set("EnableFilters", false)
local media = filter.media
WaterRun.filters(panel, 60)
check("filters off: working", filter.working, nil)
check("filters off: media kept", filter.media, media)
check("filters off: purify", purify() == true, not WaterUnits.unpurifiedPipes())
set("EnableFilters", true)
WaterRun.filters(panel, 60)
say("filters on: working", filter.working, "(true with the purification hooks, unless another filter of its group works)")
page.RiskPlumbingUnpurified = savedRisk
WaterRun.filters(panel, 1)

-- Water off: its networks go (the API forgets them), nothing drawn or filled, freezing left, the water units listed
-- none; on: the tanks again as before.
local lowest = Water.lowestId(panel, Water.FIRST)
local held = Networks.groupState(panel, Water.FIRST)
set("EnableWater", false)
check("water off: API network", lowest and api.networks.state(lowest), nil)
check("water off: state", Networks.state(panel, "water"), nil)
check("water off: fill", Networks.fill(panel, Water.FIRST, 1, "Water"), 0)
check("water off: devices", #Panels.devices(panel, "water"), 0)
check("water off: water units", #Units.of(panel.id, "water"), 0)
check("water off: install sprinkler", select(2, Units.canInstall("sprinkler", freeSquare())), "disabled")
check("water off: pump", BU.enabled("pump"), false)
set("EnableWater", true)
local back = Networks.groupState(panel, Water.FIRST)
check("water on: state", back ~= nil, BU.waterAvailable())
say("water on: held", held and held.amount, "now", back and back.amount)

-- The window: a tab per utility on; it opens anew when that changes.
PanelWindow.open(player, panel)
local window = PanelWindow.get(panel.id)
check("window: power tab", window.lists.power ~= nil, true)
page.EnablePower = false
Changes.applyFeatures()
window:refresh()
window = PanelWindow.get(panel.id)
check("window power off: power tab", window.lists.power ~= nil, false)
check("window power off: water tab", window.lists.water ~= nil, true)
check("window power off: reset shown", window.resetButton:getIsVisible(), false)

-- Both off: the box can no longer be put down, its window has the log only, nothing of the mod runs.
page.EnableWater = false
Changes.applyFeatures()
window:refresh()
window = PanelWindow.get(panel.id)
check("both off: features", BU.featureKey(), "")
check("both off: box", select(2, Panels.canInstall(getCell():getGridSquare(panel.x, panel.y, panel.z))), "disabled")
check("both off: window tabs", window.lists.power == nil and window.lists.water == nil, true)
check("both off: active utility", window:activeUtility(), nil)
check("both off: status", window.status, nil)
WaterRun.pumps(panel, 60)
WaterRun.filters(panel, 60)
check("both off: pump running", pump.running, nil)
allOn()
window:refresh()
window = PanelWindow.get(panel.id)
check("all on: window tabs", window.lists.power ~= nil and window.lists.water ~= nil, true)

-- The plan's supply lines' switch: flow (lines and dots), lines (no dots), off (no producers' lines), and the line of
-- the producer under the mouse without dots.
local ISBUPlan = ISBUPlan
local savedFlow = ISBUPlan.flowState()
window:setPlanShown(true)
window.tabs:activateView(getText("IGUI_BU_Tab_water"))
window:refresh()
local plan = window.plan
local function hover(square)
    plan.getMouseX = function() return square.x + 1 end
    plan.getMouseY = function() return square.y + 1 end
    plan:onMouseMove(0, 0)
    plan.getMouseX, plan.getMouseY = nil, nil
    return plan.hoverLine
end
local function producerSquare()
    for _, square in ipairs(plan.squares) do
        if square.line then return square end
    end
end
local counts = {}
for _, state in ipairs(ISBUPlan.FLOW_STATES) do
    ISBUPlan.setFlowState(state)
    plan:layout()
    local square = producerSquare()
    local line = square and hover(square)
    counts[state] = { lines = #plan.lines, flows = #plan.flows }
    say("switch", state, "lines", #plan.lines, "flows", #plan.flows, "producer square", square ~= nil,
        "hover line", line ~= nil)
    local label
    for _, toggle in ipairs(plan.toggles) do if toggle.name == "flow" then label = toggle.text end end
    check("switch " .. state .. ": label", label, getText("IGUI_BU_PlanFlow_" .. state))
    if state ~= "flow" then check("switch " .. state .. ": dots", #plan.flows, 0) end
    if square then check("switch " .. state .. ": hover line", line ~= nil, state ~= "flow") end
    plan:onMouseMoveOutside(0, 0)
end
check("switch lines: as many lines as flow", counts.lines.lines, counts.flow.lines)
check("switch off: fewer lines", counts.off.lines < counts.flow.lines or #plan.squares <= 1, true)

-- Supply across floors: the plan's data with a pump and a tank on a floor of their own above the rest; on their floor
-- the riser (their lines run on to it), on the box's floor a badge for them (count, what, a stub into the box and its
-- dots as the switch has them), the strip's mark, and a click on the badge going to their floor.
local real = plan.data
local fake = {}
for key, value in pairs(real) do fake[key] = value end
local boxZ = real.box.z
local top = boxZ
for _, room in ipairs(real.rooms) do top = math.max(top, room.level) end
for _, producer in ipairs(real.producers) do top = math.max(top, producer.z) end
local level = top + 1
fake.producers = {}
for _, producer in ipairs(real.producers) do fake.producers[#fake.producers + 1] = producer end
fake.producers[#fake.producers + 1] = { x = real.box.x + 2, y = real.box.y, z = level, inUse = true, text = "test pump",
    unit = "pump", flow = 1 }
fake.producers[#fake.producers + 1] = { x = real.box.x + 4, y = real.box.y, z = level, inUse = false, text = "test tank",
    flow = 1 }
ISBUPlan.setFlowState("flow")
plan:setData(fake)
plan:showFloor(level)
check("floors: riser on the producers' floor", plan.riser ~= nil, true)
check("floors: riser text", plan.riser and plan.riser.text, getText("IGUI_BU_PlanRiser", "v", BU.floorName(boxZ)))
local onward = 0
for _, square in ipairs(plan.squares) do if square.line and square.line.x3 then onward = onward + 1 end end
check("floors: producers' lines run on to the riser", onward, 2)
check("floors: no badge away from the box", #plan.badges, 0)
local mark
for _, cell in ipairs(plan.strip) do if cell.level == level then mark = cell.producer end end
check("floors: strip marks the producers' floor", mark ~= nil, true)
say("floors: strip mark colour", mark and table.concat(mark, ","), "(mixed: a pump and a tank)")
for _, state in ipairs(ISBUPlan.FLOW_STATES) do
    ISBUPlan.setFlowState(state)
    plan:showFloor(boxZ)
    plan:layout()
    local badge = plan.badges[1]
    check("floors " .. state .. ": one badge by the box", #plan.badges, 1)
    if badge then
        check("floors " .. state .. ": badge text", badge.text, getText("IGUI_BU_PlanArrive", "^", BU.floorName(level), 2))
        local stub, dots = false, false
        for _, line in ipairs(plan.lines) do if line.x1 == badge.x and line.y1 == badge.y + badge.h / 2 then stub = true end end
        for _, flow in ipairs(plan.flows) do
            if flow.points[1][1] == badge.x and flow.points[1][2] == badge.y + badge.h / 2 then dots = true end
        end
        check("floors " .. state .. ": stub", stub, state ~= "off")
        check("floors " .. state .. ": dots into the box", dots, state == "flow")
        hover(badge)
        say("floors " .. state .. ": badge tip", plan.status)
        check("floors " .. state .. ": badge tip", plan.status, badge.tip)
        plan:onMouseMoveOutside(0, 0)
    end
end
local badge = plan.badges[1]
if badge then
    plan:click(badge.x + 1, badge.y + 1)
    check("floors: a click on the badge goes to its floor", plan.floor, level)
    if plan.riser then
        plan:click(plan.riser.x + 1, plan.riser.y + 1)
        check("floors: a click on the riser goes to the box's floor", plan.floor, boxZ)
    end
end
-- The top bar at the plan's least width with all it can hold (every switch, Fit, a long floor name with the load,
-- several floors): no two parts overlap, none leaves the bar, and the map starts below it.
local savedWidth = plan.width
local wide = {}
for key, value in pairs(real) do wide[key] = value end
wide.utility, wide.zoneEditable = "power", true
plan:setData(wide)
plan:setWidth(BU.PanelUi.MIN_PLAN)
plan.zoom = 2
plan:layout()
plan.floor, plan.floorLoad, plan.levels = -12, { [-12] = 123.45 }, { -12, 0 }
local height = getTextManager():getFontHeight(UIFont.Small) + 2
for _, state in ipairs(ISBUPlan.FLOW_STATES) do
    ISBUPlan.setFlowState(state)
    plan:layoutTop()
    local boxes = { { what = "title", x = plan.titleX, y = 7, w = plan.titleW, h = height } }
    for _, toggle in ipairs(plan.toggles) do
        boxes[#boxes + 1] = { what = toggle.name, x = toggle.x, y = toggle.y, w = toggle.w, h = height }
    end
    local clash
    for index, a in ipairs(boxes) do
        if a.x < 8 or a.x + a.w > plan.width - 8 or a.y + a.h > plan.topH then clash = a.what .. " outside" end
        for other = index + 1, #boxes do
            local b = boxes[other]
            if a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h then
                clash = a.what .. " on " .. b.what
            end
        end
    end
    say("top bar", plan.width, state, "title", plan.floorTitle, "full", plan.titleFull, "switches", #plan.toggles,
        "height", plan.topH)
    check("top bar " .. state .. ": nothing overlaps at the least width", clash, nil)
    check("top bar " .. state .. ": every switch", #plan.toggles, 5)
end
plan:layout()
check("top bar: the map below it", plan.map ~= nil and plan.map.top >= plan.topH, true)
plan.zoom = 1
plan:setWidth(savedWidth)
plan:setData(real)
plan:showFloor(boxZ)
ISBUPlan.setFlowState(savedFlow)
plan:layout()
check("switch restored", ISBUPlan.flowState(), savedFlow)

-- Gone again.
Networks.state = realState
for _, unit in ipairs({ pump, sprinkler, filter }) do Changes.removeUnit(unit) end
WaterRun.pumps(panel, 1)
for _, name in ipairs(OPTIONS) do page[name] = saved[name] end
page.RiskPlumbingUnpurified = savedRisk
panel.tier = savedTier
Changes.applyFeatures()
window:refresh()
say("done:", bad, "BAD; features", BU.featureKey(), "units", #Store.unitList(nil, panel.id))
