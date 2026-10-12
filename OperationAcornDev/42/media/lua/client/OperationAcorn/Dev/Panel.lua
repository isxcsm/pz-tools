-- Operation Acorn Dev: the "OA" section of the shared debug window (PZExtDev, F8): a page for each part of the mod,
-- its state at the top, kept up while the page shows, and its controls below. Every control calls a function of
-- OperationAcorn.Dev (Dev.lua, Features.lua), the same functions the command channel (tools/pzdev.py) runs. The game's
-- environment (time, weather, the character, zombie spawns) is the window's own "API" section. Debug mode only.
-- Mod Lua holds no letters past ASCII (the game reads them as U+FFFD): every text comes from IGUI_OADev_* keys.
if not isDebugEnabled() then return end
require "PZExtDev/Panel"
require "OperationAcorn/Core"
require "OperationAcorn/Titles"
require "OperationAcorn/Dev/Dev"
require "OperationAcorn/Dev/Features"
local OA = OperationAcorn
local Dev = OA.Dev
local Panel = {}
OA.DevPanel = Panel

local function T(key, ...)
    return getText("IGUI_OADev_" .. key, ...)
end

local function treeName(tree)
    local texts = OA.Upgrades and OA.Upgrades.Texts
    return texts and texts.treeName(tree) or tree
end

local function treeItems(withBoard)
    local Data = OA.Upgrades.Data
    local items = {}
    for _, tree in ipairs(Data.TREES) do items[#items + 1] = { treeName(tree), tree } end
    if withBoard then items[#items + 1] = { treeName(Data.BOARD), Data.BOARD } end
    return items
end

-- The nodes of a tree, or of the second board.
local function nodesOf(tree)
    local Data = OA.Upgrades.Data
    if tree ~= Data.BOARD then return Data.treeNodes(tree) end
    local list = {}
    for _, n in ipairs(Data.nodes) do
        if n.board then list[#list + 1] = n end
    end
    return list
end

local function mostNodes()
    local Data = OA.Upgrades.Data
    local most = #nodesOf(Data.BOARD)
    for _, tree in ipairs(Data.TREES) do most = math.max(most, #Data.treeNodes(tree)) end
    return most
end

local function hours(h, ui)
    return h and (ui.num(h, 1) .. "h") or "-"
end

-- ---- trade --------------------------------------------------------------------------------------------------------

local function tradePage(page, ui)
    local state = ui.lines(page, 1, 2)
    ui.heading(page, T("Tr_Money"), 4)
    local rows = ui.buttons(page, 5, {
        { "-1000", function() Dev.addCredits(-1000) end },
        { "+1000", function() Dev.addCredits(1000) end },
        { "+10000", function() Dev.addCredits(10000) end },
        { T("Tr_Debt"), function() Dev.debt() end },
    })
    local stages = {}
    for level = 0, 7 do
        stages[#stages + 1] = { level <= 5 and T("Tr_Stage", tostring(level)) or T("Tr_Milestone", tostring(level - 5)),
            function() Dev.stage(level) end }
    end
    rows = rows + ui.buttons(page, 5 + rows, stages)

    local n = 6 + rows
    ui.heading(page, T("Tr_Things"), n)
    rows = ui.buttons(page, n + 1, {
        { T("Tr_FieldTerminal"), function() Dev.giveAll({ "FieldTerminal" }) end },
        { T("Tr_Terminal"), function() Dev.giveAll({ "CommTerminal" }) end },
        { T("Tr_Box"), function() Dev.giveAll({ "DeliveryBox" }) end },
        { T("Tr_Manual"), function() Dev.giveAll({ "TerminalManual" }) end },
    })
    n = n + 2 + rows
    ui.heading(page, T("Tr_Heli"), n)
    ui.buttons(page, n + 1, {
        { T("Tr_HeliNow"), function() Dev.heliNow() end },
        { T("Tr_HeliReady"), function() Dev.heliReady() end },
        { T("Tr_Crate"), function() Dev.crateHere(false) end },
        { T("Tr_Parachute"), function() Dev.crateHere(true) end },
        { T("Tr_FirstNow"), function() Dev.firstSupply() end },
        { T("Tr_FirstReset"), function() Dev.firstSupply(true) end },
        { T("Tr_WeekReset"), function() Dev.shopWeekReset() end },
    })
    page.refresh = function()
        local s = Dev.tradeState()
        if not s then state:set({ T("NoRecord") }) return end
        state:set({
            T("Tr_State", ui.num(s.credits), ui.num(s.trust), ui.num(s.stage), ui.num(s.milestones)),
            T("Tr_HeliState", hours(s.arrive, ui), hours(s.wait, ui), tostring(s.first)),
        })
    end
end

-- ---- economy ------------------------------------------------------------------------------------------------------

local function economyPage(page, ui)
    local market = ui.lines(page, 1, 2)
    ui.buttons(page, 3, {
        { T("Ec_Redraw"), function() Dev.redrawRequests() end },
        { T("Ec_Daily"), function() Dev.daily() end },
    })
    ui.heading(page, T("Ec_Market"), 5)
    local cats = {}
    for _, c in ipairs(OA.Categories.LETTERS) do cats[#cats + 1] = { c, c } end
    local catBox = ui.combo(page, ui.PAD, ui.row(6), 80, cats)
    local _, x = ui.button(page, T("Ec_Demand"), ui.PAD + 90, ui.row(6), 0, function()
        Dev.marketEvent(catBox:getSelectedData(), 1.5)
    end)
    ui.button(page, T("Ec_Glut"), x, ui.row(6), 0, function() Dev.marketEvent(catBox:getSelectedData(), 0.6) end)

    ui.heading(page, T("Ec_Held"), 8)
    local held = ui.lines(page, 9, 1)
    ui.button(page, T("Ec_Appraise"), ui.PAD, ui.row(10), 0, function()
        local v, fullType = Dev.appraiseHeld()
        held:set({ v and T("Ec_Worth", fullType, ui.num(v.credits, 1), ui.num(v.trust, 1), tostring(v.category))
            or T("Ec_NothingHeld") })
    end)

    ui.heading(page, T("Ec_Reset"), 12)
    ui.buttons(page, 13, {
        { T("Ec_Codex"), function() Dev.resetCodex() end },
        { T("Ec_Search"), function() Dev.resetSearch() end },
        { T("Ec_Shred"), function() Dev.resetShred() end },
    })
    ui.hint(page, T("Ec_SearchHint"), 14)
    page.refresh = function()
        local r = Dev.record()
        local list = r and OA.Requests.list(r) or {}
        market:set({ T("Ec_Index", Dev.marketLine()), T("Ec_Requests", ui.num(#list), ui.num(OA.week())) })
    end
end

-- ---- machines -----------------------------------------------------------------------------------------------------

local function machinesPage(page, ui)
    local near = ui.lines(page, 1, 6)
    local kinds = {}
    for _, kind in ipairs(Dev.MACHINES) do kinds[#kinds + 1] = { kind, kind } end
    local kindBox = ui.combo(page, ui.PAD, ui.row(8), 200, kinds)
    local _, x = ui.button(page, T("Mc_Give"), ui.PAD + 210, ui.row(8), 0, function()
        Dev.giveMachine(kindBox:getSelectedData())
    end)
    ui.button(page, T("Mc_Parts"), x, ui.row(8), 0, function() Dev.giveAll(Dev.PARTS) end)
    local form = ui.lines(page, 9, 1, 0.7, 0.7, 0.7)
    ui.buttons(page, 10, {
        { T("Mc_Hour"), function() Dev.advanceMachines(1) end },
        { T("Mc_Hours", "8"), function() Dev.advanceMachines(8) end },
        { T("Mc_Hours", "24"), function() Dev.advanceMachines(24) end },
    })
    page.refresh = function()
        local lines = Dev.machineLines(20)
        if #lines == 0 then lines = { T("Mc_None") } end
        near:set(lines)
        form:set({ T("Mc_Form", table.concat(Dev.deliveryOf(kindBox:getSelectedData()), ", ")) })
    end
end

-- ---- gear ---------------------------------------------------------------------------------------------------------

local function gearPage(page, ui)
    ui.heading(page, T("Gr_Kits"), 1)
    ui.buttons(page, 2, {
        { T("Gr_BagCapacity"), function() Dev.giveAll({ "KitBagCapacity" }) end },
        { T("Gr_BagWeight"), function() Dev.giveAll({ "KitBagWeight" }) end },
        { T("Gr_Trunk"), function() Dev.giveAll({ "KitTrunk" }) end },
        { T("Gr_Engine"), function() Dev.giveAll({ "KitEngine" }) end },
        { T("Gr_Voucher"), function() Dev.giveAll({ "KitVoucher" }) end },
        { T("Gr_Backpack"), function() Dev.giveAll({ "TeamBackpack" }) end },
        { T("Gr_FuelCans"), function() Dev.giveAll({ "FuelCanMk1", "FuelCanMk2", "FuelCanMk3" }) end },
    })
end

-- ---- upgrades -----------------------------------------------------------------------------------------------------

local function upgradesPage(page, ui)
    local Data = OA.Upgrades.Data
    local texts = OA.Upgrades.Texts
    local state = ui.lines(page, 1, 1)
    local night = ui.tick(page, T("Up_NightSight"), ui.PAD, ui.row(2), function(on) Dev.nightSight(on) end)

    ui.label(page, T("Up_Points"), ui.PAD, ui.row(3) + 2)
    local pointItems = treeItems(false)
    pointItems[#pointItems + 1] = { T("Up_Shared"), "shared" }
    local pointBox = ui.combo(page, ui.PAD + 110, ui.row(3), 160, pointItems)
    local _, px = ui.button(page, "+1", ui.PAD + 280, ui.row(3), 36, function() Dev.points(pointBox:getSelectedData(), 1) end)
    ui.button(page, "+5", px, ui.row(3), 36, function() Dev.points(pointBox:getSelectedData(), 5) end)

    local current = Data.TREES[1]
    local rows = {}
    local function fill()
        local list = nodesOf(current)
        local hasRecord = Dev.record() ~= nil
        for i, row in ipairs(rows) do
            local node = hasRecord and list[i] or nil
            row.node = node
            for _, control in ipairs(row.controls) do control:setVisible(node ~= nil) end
            if node then
                row.name:setName(texts and texts.nodeName(node.id) or node.id)
                row.rank:setName(tostring(Dev.rank(node.id)) .. "/" .. (node.ranks and tostring(node.ranks) or "-"))
            end
        end
        ui.fit()
    end
    ui.buttons(page, 4, {
        { T("Up_Reset"), function() Dev.clearResearch() fill() end },
        { T("Up_EndAdapt"), function() Dev.endAdapt() end },
        { T("Up_FirstEffects"), function() Dev.resetFirstEffects() end },
        { T("Up_Serums"), function()
            Dev.giveAll({ "UpgradeSerumScout", "UpgradeSerumLoad", "UpgradeSerumSurvival", "UpgradeSerumShared" })
        end },
        { T("Up_SenseSound"), function() Dev.sound(12, 0, 30, 30) end },
    })

    ui.heading(page, T("Up_Alarms"), 6)
    ui.buttons(page, 7, {
        { T("Up_AlarmHouse"), function() Dev.alarmHouse() end },
        { T("Up_AlarmCar"), function() Dev.alarmCar() end },
        { T("Up_AlarmClear"), function() Dev.clearAlarms() end },
    })

    ui.label(page, T("Up_Tree"), ui.PAD, ui.row(9) + 2)
    ui.combo(page, ui.PAD + 70, ui.row(9), 200, treeItems(true), function(tree)
        current = tree
        fill()
    end)
    local nameW = 220
    for i = 1, mostNodes() do
        local y = ui.row(9 + i)
        local row = { controls = {} }
        row.name = ui.label(page, "", ui.PAD, y + 2)
        local minus = ui.button(page, "-", ui.PAD + nameW, y, 26, function()
            if row.node then Dev.setRank(row.node.id, math.max(0, Dev.rank(row.node.id) - 1)) fill() end
        end)
        row.rank = ui.label(page, "", ui.PAD + nameW + 34, y + 2)
        local plus = ui.button(page, "+", ui.PAD + nameW + 90, y, 26, function()
            local node = row.node
            if node then Dev.setRank(node.id, math.min(node.ranks or 99, Dev.rank(node.id) + 1)) fill() end
        end)
        row.controls = { row.name, minus, row.rank, plus }
        rows[i] = row
    end

    page.refresh = function()
        if Dev.record() then night:setSelected(1, Dev.nightSightOn()) end
        local houses, cars = Dev.alarmsNear()
        state:set({ T("Up_State", hours(Dev.adaptLeft(), ui), ui.num(houses), ui.num(cars)) })
        fill()
    end
end

-- ---- infection ----------------------------------------------------------------------------------------------------

local function infectionPage(page, ui)
    local state = ui.lines(page, 1, 2)
    ui.buttons(page, 4, {
        { T("If_Bite"), function() Dev.bite(true) end },
        { T("If_BiteClean"), function() Dev.bite(false) end },
        { T("If_Ahead"), function() Dev.infectionAhead(12) end },
        { T("If_Test"), function() Dev.test() end },
        { T("If_Cure"), function() Dev.cure() end },
    })
    ui.heading(page, T("If_Items"), 6)
    ui.buttons(page, 7, {
        { T("If_Kits"), function() Dev.giveAll({ "InfectionTestKit", "InfectionTestKit" }) end },
        { T("If_Drugs"), function() Dev.giveAll({ "DelayDrug", "DelayDrugLong" }) end },
        { T("If_Reversal"), function() Dev.giveAll({ "InfectionReversal" }) end },
    })
    ui.hint(page, T("If_CureHint"), 8)
    page.refresh = function()
        state:set(Dev.infectionLines())
    end
end

-- ---- missions -----------------------------------------------------------------------------------------------------

local function missionPage(page, ui)
    local info = ui.lines(page, 1, 4)
    local counted = nil
    ui.buttons(page, 6, {
        { T("Ms_Start"), function() Dev.startMission() end },
        { T("Ms_Done"), function() Dev.finishMission("done") end },
        { T("Ms_Expire"), function() Dev.finishMission("expired") end },
        { T("Ms_Lose"), function() Dev.finishMission("lost") end },
    })
    ui.buttons(page, 7, {
        { T("Ms_Goto"), function() Dev.gotoMission() end },
        { T("Ms_Build"), function() Dev.buildScene() counted = nil end },
        { T("Ms_Count"), function()
            local n, found = Dev.zombiesInBuilding()
            counted = found and n or -1
        end },
    })
    ui.heading(page, T("Ms_Story"), 9)
    ui.buttons(page, 10, {
        { T("Ms_Hallucination"), function() Dev.hallucinate(false) end },
        { T("Ms_HallucinationLong"), function() Dev.hallucinate(true) end },
        { T("Ms_Fragments"), function() Dev.giveAll({ "MeteorFragment", "MeteorFragmentIron", "MeteorFragmentStonyIron" }) end },
        { T("Ms_Documents"), function()
            Dev.giveAll({ "EvidenceEnvelope", "ClinicRecord", "WeatherLog", "SerumSheet", "HandoverFile" })
        end },
    })
    ui.hint(page, T("Ms_StageHint"), 11)

    page.refresh = function()
        local m, piece = Dev.mission()
        local lines = {}
        if not m then
            lines[1] = T("Ms_None")
        else
            lines[1] = T("Ms_Line") .. ": " .. tostring(m.place) .. " (" .. tostring(m.state) .. ")"
            local x, y, z = Dev.missionPlace()
            local where = T("Ms_NoPiece")
            if piece then where = x and (tostring(x) .. ", " .. tostring(y) .. ", " .. tostring(z)) or T("Ms_NotPlaced") end
            lines[2] = T("Ms_Piece") .. ": " .. where
            local sc = m.scene
            local scene = T("Ms_NoScene")
            if sc then scene = sc.built and T("Ms_Built") or T("Ms_Planned") end
            lines[3] = T("Ms_Scene") .. ": " .. scene
        end
        if counted ~= nil then
            lines[4] = counted < 0 and T("Ms_NoBuilding") or (T("Ms_Zombies") .. ": " .. ui.num(counted))
        end
        info:set(lines)
    end
end

-- ---- effects ------------------------------------------------------------------------------------------------------

local function effectsPage(page, ui)
    ui.label(page, T("Up_Tree"), ui.PAD, ui.row(1) + 2)
    local treeBox = ui.combo(page, ui.PAD + 70, ui.row(1), 200, treeItems(false))
    local function tree() return treeBox:getSelectedData() end
    local now = ui.tick(page, T("Fx_TitlesNow"), ui.PAD + 290, ui.row(1), function(on) OA.Titles.now = on end)
    now:setSelected(1, OA.Titles.now == true)
    ui.heading(page, T("Fx_Titles"), 2)
    local rows = ui.buttons(page, 3, {
        { T("Fx_Capstone"), function() Dev.title("capstone", tree()) end },
        { T("Fx_TreeOpened"), function() Dev.title("tree", tree()) end },
        { T("Fx_BoardOpened"), function() Dev.title("board") end },
        { T("Fx_LineOpened"), function() Dev.title("line") end },
        { T("Fx_NewRequest"), function() Dev.title("request") end },
        { T("Fx_Stage"), function() Dev.titleMore("stage") end },
        { T("Fx_Milestone"), function() Dev.titleMore("milestone") end },
        { T("Fx_Paid"), function() Dev.titleMore("paid") end },
        { T("Fx_Debt"), function() Dev.titleMore("debt") end },
        { T("Fx_Positive"), function() Dev.titleMore("positive") end },
        { T("Fx_Negative"), function() Dev.titleMore("negative") end },
        { T("Fx_Cured"), function() Dev.titleMore("cured") end },
        { T("Fx_FirstSupply"), function() Dev.titleMore("firstSupply") end },
    })
    local n = 4 + rows
    ui.heading(page, T("Fx_Scenes"), n)
    ui.buttons(page, n + 1, {
        { T("Fx_Take"), function() Dev.replayTake() end },
        { T("Fx_Showroom"), function() Dev.showroom() end },
        { T("Fx_ShowroomSolar"), function() Dev.showroom({ solar = true }) end },
        { T("Fx_ShowroomClear"), function() Dev.clearShowroom() end },
    })
    ui.hint(page, T("Fx_TakeHint"), n + 3)
end

PZExtDev.section({ id = "OA", title = T("Section"), order = 30, pages = {
    { id = "Trade", title = T("Tab_Trade"), build = tradePage },
    { id = "Economy", title = T("Tab_Economy"), build = economyPage },
    { id = "Machines", title = T("Tab_Machines"), build = machinesPage },
    { id = "Gear", title = T("Tab_Gear"), build = gearPage },
    { id = "Upgrades", title = T("Tab_Upgrades"), build = upgradesPage },
    { id = "Infection", title = T("Tab_Infection"), build = infectionPage },
    { id = "Missions", title = T("Tab_Missions"), build = missionPage },
    { id = "Effects", title = T("Tab_Effects"), build = effectsPage },
} })

return Panel
