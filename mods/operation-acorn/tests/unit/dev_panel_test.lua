-- The developer sub-mod (OperationAcornDev): its "OA" section of the shared debug window (PZExtDev), its pages built
-- on a fake `ui` with every control driving a function of OperationAcorn.Dev (the panel and ../tools/pzdev.py run the
-- same code), and Dev's helpers with a fake world: the mission's scene made without the distance rule.
isDebugEnabled = function() return true end
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Requests"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Scene"
require "OperationAcorn/Upgrades/Texts"
local OA = OperationAcorn
local Data = OA.Upgrades.Data

local player = { mod = { OA_Id = "p1" } }
function player:getModData() return self.mod end
getPlayer = function() return player end

-- The window takes the section; the test builds its pages itself.
local section
PZExtDev = { section = function(def) section = def end }
do
    local real = require
    require = function(file)
        if file == "PZExtDev/Panel" then return true end
        return real(file)
    end
    require "OperationAcorn/Dev/Dev"
    require "OperationAcorn/Dev/Features"
    require "OperationAcorn/Dev/Panel"
    require = real
end
local Dev = OA.Dev
local real = {}
for k, v in pairs(Dev) do real[k] = v end

-- ---------------------------------------------------------------------------------------------------------------------
-- A fake `ui`: each control is kept on its page in order, and can be clicked, ticked and chosen.

local function control(page, kind, fields)
    fields.kind = kind
    fields.visible = true
    function fields:setVisible(on) self.visible = on end
    function fields:setName(name) self.text = name end
    page.controls[#page.controls + 1] = fields
    return fields
end

local ui = { PAD = 10, GAP = 6, W = 600 }
function ui.row(n) return n * 20 end
function ui.num(v, decimals) return string.format("%." .. tostring(decimals or 0) .. "f", v or 0) end
function ui.fit() end
function ui.say() end
function ui.act(fn) return fn end
function ui.label(page, text) return control(page, "label", { text = text }) end
function ui.heading(page, text) return control(page, "label", { text = text }) end
function ui.hint(page, text) return control(page, "label", { text = text }) end
function ui.button(page, text, x, _, _, fn)
    local b = control(page, "button", { text = text, click = function() fn() end })
    return b, x + 50
end
function ui.buttons(page, _, list)
    for _, item in ipairs(list) do ui.button(page, item[1], 0, 0, 0, item[2]) end
    return math.ceil(#list / 4)
end
function ui.tick(page, text, _, _, fn)
    local t = control(page, "tick", { text = text, on = false })
    function t:setSelected(_, on) self.on = on end
    function t:tick(on) self.on = on fn(on) end
    return t
end
function ui.combo(page, _, _, _, items, fn)
    local c = control(page, "combo", { items = items, selected = 1 })
    function c:getSelectedData() return self.items[self.selected][2] end
    function c:choose(i)
        self.selected = i
        if fn then fn(self.items[i][2]) end
    end
    return c
end
function ui.lines(page, _, count)
    local l = control(page, "lines", { count = count, shown = {} })
    function l:set(list) self.shown = list end
    return l
end

local function build(id)
    for _, def in ipairs(section.pages) do
        if def.id == id then
            local page = { controls = {} }
            def.build(page, ui)
            return page
        end
    end
    error("no page " .. id)
end

local function all(page, kind)
    local found = {}
    for _, c in ipairs(page.controls) do
        if c.kind == kind and c.visible then found[#found + 1] = c end
    end
    return found
end

local function button(page, text)
    for _, b in ipairs(all(page, "button")) do
        if b.text == text then return b end
    end
    error("no button " .. text)
end

-- Dev's functions the pages call, replaced by recorders; `calls` lists them as "name(args)".
local calls
local function record(name, result)
    Dev[name] = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            parts[#parts + 1] = type(v) ~= "table" and tostring(v) or (v.solar and "solar" or table.concat(v, "+"))
        end
        calls[#calls + 1] = name .. "(" .. table.concat(parts, ",") .. ")"
        return result
    end
end
local function fakeDev()
    calls = {}
    for _, name in ipairs({ "addCredits", "debt", "stage", "giveAll", "heliNow", "heliReady", "crateHere",
        "firstSupply", "shopWeekReset", "redrawRequests", "daily", "marketEvent", "resetCodex", "resetSearch",
        "resetShred", "giveMachine", "advanceMachines", "nightSight", "points", "setRank", "clearResearch", "endAdapt",
        "resetFirstEffects", "sound", "alarmHouse", "alarmCar", "clearAlarms", "bite", "infectionAhead", "test", "cure",
        "startMission", "finishMission", "gotoMission", "buildScene", "hallucinate", "title", "titleMore",
        "replayTake", "showroom", "clearShowroom" }) do
        record(name)
    end
    Dev.zombiesInBuilding = function()
        calls[#calls + 1] = "zombiesInBuilding()"
        return 7, true
    end
    Dev.record = function() return { id = "p1" } end
    Dev.rank = function() return 0 end
    Dev.nightSightOn = function() return false end
    Dev.alarmsNear = function() return 1, 2 end
    Dev.adaptLeft = function() return nil end
    Dev.tradeState = function()
        return { credits = 1500, trust = 30, stage = 2, milestones = 0, arrive = 1.5, wait = nil, first = true }
    end
    Dev.marketLine = function() return "A 1.0" end
    Dev.machineLines = function() return {} end
    Dev.deliveryOf = function(kind) return { kind .. "Kit" } end
    Dev.infectionLines = function() return { "infected false" } end
    Dev.mission = function() return nil, nil end
    Dev.missionPlace = function() return nil end
end

test("the OA section: nine pages in order, each built and refreshed", function()
    fakeDev()
    eq(section.id, "OA")
    local ids = {}
    for _, def in ipairs(section.pages) do ids[#ids + 1] = def.id end
    eq(table.concat(ids, " "), "E2E Trade Economy Machines Gear Upgrades Infection Missions Effects")
    for _, id in ipairs(ids) do
        local page = build(id)
        if page.refresh then page.refresh() end
    end
end)

test("E2E page: the chosen beat set, the next one, the beat's lines and a timer's soon", function()
    fakeDev()
    local E2E = Dev.E2E
    local set, nextBeat, timers, soon = E2E.set, E2E.next, E2E.timers, E2E.timerSoon
    local done = {}
    E2E.set = function(id) done[#done + 1] = "set(" .. id .. ")"; E2E.current = id end
    E2E.next = function() done[#done + 1] = "next()"; E2E.current = "03"; return E2E.BY_ID["03"] end
    E2E.timers = function() return { { id = "call_S2B", key = "call", arg = "S2B", left = 11.5 } } end
    E2E.timerSoon = function(id) done[#done + 1] = "soon(" .. id .. ")" end
    local page = build("E2E")
    local beats = all(page, "combo")[1]
    beats:choose(E2E.BY_ID["02"].index)
    button(page, "IGUI_OADev_E2E_Set"):click()
    page.refresh()
    local shown = table.concat(all(page, "lines")[1].shown, "|")
    truthy(string.find(shown, "IGUI_OADev_E2E_Do_02", 1, true), shown)
    button(page, "IGUI_OADev_E2E_Next"):click()
    page.refresh()
    eq(beats.selected, E2E.BY_ID["03"].index, "the combo follows the beat set")
    beats.selected = 1
    page.refresh()
    eq(beats.selected, 1, "and leaves a pick alone")
    local soonButtons = {}
    for _, b in ipairs(all(page, "button")) do
        if b.text == "IGUI_OADev_E2E_Soon" then soonButtons[#soonButtons + 1] = b end
    end
    eq(#soonButtons, 1, "one timer running")
    soonButtons[1]:click()
    eq(table.concat(done, " "), "set(02) next() soon(call_S2B)")
    E2E.set, E2E.next, E2E.timers, E2E.timerSoon = set, nextBeat, timers, soon
    E2E.current = nil
end)

test("trade page: credits, stages, things and the helicopter, and its state", function()
    fakeDev()
    local page = build("Trade")
    button(page, "+1000"):click()
    button(page, "IGUI_OADev_Tr_Debt"):click()
    button(page, "IGUI_OADev_Tr_Stage 1"):click()
    button(page, "IGUI_OADev_Tr_Terminal"):click()
    button(page, "IGUI_OADev_Tr_Parachute"):click()
    button(page, "IGUI_OADev_Tr_FirstReset"):click()
    eq(table.concat(calls, " "), "addCredits(1000) debt() stage(1) giveAll(CommTerminal) crateHere(true) firstSupply(true)")
    page.refresh()
    eq(#all(page, "lines")[1].shown, 2, "credits and the helicopter")
    Dev.tradeState = function() return nil end
    page.refresh()
    eq(all(page, "lines")[1].shown[1], "IGUI_OADev_NoRecord")
end)

test("economy page: a market event on the chosen category, resets", function()
    fakeDev()
    local page = build("Economy")
    all(page, "combo")[1]:choose(3)
    button(page, "IGUI_OADev_Ec_Demand"):click()
    button(page, "IGUI_OADev_Ec_Glut"):click()
    button(page, "IGUI_OADev_Ec_Search"):click()
    eq(table.concat(calls, " "), "marketEvent(C,1.5) marketEvent(C,0.6) resetSearch()")
end)

test("machines page: give the chosen machine, advance the clock, the delivery form shows", function()
    fakeDev()
    local page = build("Machines")
    all(page, "combo")[1]:choose(2)
    button(page, "IGUI_OADev_Mc_Give"):click()
    button(page, "IGUI_OADev_Mc_Hour"):click()
    eq(table.concat(calls, " "), "giveMachine(" .. Dev.MACHINES[2] .. ") advanceMachines(1)")
    page.refresh()
    local lines = all(page, "lines")
    eq(lines[1].shown[1], "IGUI_OADev_Mc_None")
    eq(lines[2].shown[1], "IGUI_OADev_Mc_Form " .. Dev.MACHINES[2] .. "Kit")
end)

test("upgrades page: night sight, points, a node's rank by +, reset", function()
    fakeDev()
    local page = build("Upgrades")
    page.refresh()
    all(page, "tick")[1]:tick(true)
    button(page, "+5"):click()
    local first = Data.treeNodes(Data.TREES[1])[1]
    button(page, "+"):click()
    button(page, "IGUI_OADev_Up_Reset"):click()
    eq(table.concat(calls, " "), "nightSight(true) points(" .. Data.TREES[1] .. ",5) setRank(" .. first.id .. ",1) clearResearch()")
end)

test("upgrades page: the second board lists its own nodes, and a - at rank 0 stays at 0", function()
    fakeDev()
    local page = build("Upgrades")
    local combos = all(page, "combo")
    combos[2]:choose(#combos[2].items)  -- the points combo comes first, then the tree; the board is last
    button(page, "-"):click()
    local boardFirst
    for _, n in ipairs(Data.nodes) do
        if n.board and not boardFirst then boardFirst = n.id end
    end
    eq(calls[1], "setRank(" .. boardFirst .. ",0)")
end)

test("upgrades page: no record hides the node rows", function()
    fakeDev()
    Dev.record = function() return nil end
    local page = build("Upgrades")
    page.refresh()
    for _, b in ipairs(page.controls) do
        if b.text == "+" or b.text == "-" then eq(b.visible, false) end
    end
end)

test("infection page: bites, the clock, test and cure", function()
    fakeDev()
    local page = build("Infection")
    button(page, "IGUI_OADev_If_Bite"):click()
    button(page, "IGUI_OADev_If_BiteClean"):click()
    button(page, "IGUI_OADev_If_Ahead"):click()
    button(page, "IGUI_OADev_If_Test"):click()
    button(page, "IGUI_OADev_If_Cure"):click()
    eq(table.concat(calls, " "), "bite(true) bite(false) infectionAhead(12) test() cure()")
end)

test("missions page: start, finish, go, build, count, and the count shows", function()
    fakeDev()
    local page = build("Missions")
    button(page, "IGUI_OADev_Ms_Start"):click()
    button(page, "IGUI_OADev_Ms_Expire"):click()
    button(page, "IGUI_OADev_Ms_Goto"):click()
    button(page, "IGUI_OADev_Ms_Build"):click()
    button(page, "IGUI_OADev_Ms_Count"):click()
    button(page, "IGUI_OADev_Ms_HallucinationLong"):click()
    eq(table.concat(calls, " "),
        "startMission() finishMission(expired) gotoMission() buildScene() zombiesInBuilding() hallucinate(true)")
    Dev.mission = function() return { place = "clinic", state = "open", scene = { built = false } },
        { placed = true, at = { x = 5, y = 6, z = 0 } } end
    Dev.missionPlace = function() return 5, 6, 0 end
    page.refresh()
    local joined = table.concat(all(page, "lines")[1].shown, "|")
    truthy(string.find(joined, "clinic", 1, true), "the mission")
    truthy(string.find(joined, "5, 6, 0", 1, true), "its place")
    truthy(string.find(joined, "IGUI_OADev_Ms_Zombies: 7", 1, true), "the count: " .. joined)
end)

test("effects page: each title kind on the chosen tree, and the take", function()
    fakeDev()
    local page = build("Effects")
    all(page, "combo")[1]:choose(2)
    button(page, "IGUI_OADev_Fx_Capstone"):click()
    button(page, "IGUI_OADev_Fx_BoardOpened"):click()
    button(page, "IGUI_OADev_Fx_LineOpened"):click()
    button(page, "IGUI_OADev_Fx_Debt"):click()
    button(page, "IGUI_OADev_Fx_Take"):click()
    button(page, "IGUI_OADev_Fx_ShowroomSolar"):click()
    eq(table.concat(calls, " "), "title(capstone," .. Data.TREES[2] .. ") title(board) title(line) titleMore(debt) "
        .. "replayTake() showroom(solar)")
end)

-- ---------------------------------------------------------------------------------------------------------------------
-- Dev's helpers with a fake world (the real ones back)

local function realDev()
    for k, v in pairs(real) do Dev[k] = v end
end

test("the scene is made without the distance rule, and the rule is back after", function()
    realDev()
    local made = {}
    OA.Store.players()["p1"] = { id = "p1" }
    local record = OA.Store.player("p1")
    local piece = { x1 = 1, x2 = 6, y1 = 1, y2 = 6, placed = true, at = { x = 3, y = 3, z = 0 } }
    record.missions = { active = { id = 1, place = "clinic", state = "open", items = { piece },
        scene = { arrived = false, built = false, props = { { type = "x" } }, guards = { {} } } } }
    OA.Scene.game = {
        loaded = function() return true end,
        placeProps = function() made[#made + 1] = "props" end,
        spawnGuards = function() made[#made + 1] = "guards" end,
        spawnSurvivor = function() made[#made + 1] = "survivor" end,
    }
    local before = OA.Scene.READY
    player.getX = function() return 5000 end
    player.getY = function() return 5000 end
    eq(Dev.buildScene(), true, "made far away from the piece")
    eq(table.concat(made, " "), "props guards")
    eq(OA.Scene.READY, before, "the rule is back")
    eq(record.missions.active.scene.built, true)
end)

test("the scene is not made, and says why, when the building is not loaded", function()
    realDev()
    OA.Store.players()["p1"] = { id = "p1" }
    local record = OA.Store.player("p1")
    local piece = { x1 = 1, x2 = 6, y1 = 1, y2 = 6, placed = true, at = { x = 3, y = 3, z = 0 } }
    record.missions = { active = { id = 1, place = "clinic", state = "open", items = { piece },
        scene = { arrived = false, built = false } } }
    OA.Scene.game = { loaded = function() return false end }
    player.getX = function() return 5000 end
    player.getY = function() return 5000 end
    eq(Dev.buildScene(), false)
    eq(record.missions.active.scene.built, false, "still to be built")
    eq(OA.Scene.READY, 40, "the rule is back")
end)
