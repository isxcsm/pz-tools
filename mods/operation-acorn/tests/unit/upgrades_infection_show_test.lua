-- How the infection is told (DESIGN-terminal 17.6, 18): which line bundle and tags each event draws from, the cooldown of
-- the lost-drug line, the handling notice that comes once with the first positive test, the certificate of a cure by
-- its length, the line that lifts the fee after a cure, and the longer cure action and the short test wait.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Say"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Serums"
require "OperationAcorn/Upgrades/Server"
require "OperationAcorn/Story/Folder"
local OA = OperationAcorn
local Infection = OA.Infection
local Serums = OA.Upgrades.Serums
local Guides = OA.Upgrades.Guides
local Say = OA.Say

CharacterStat = { ZOMBIE_INFECTION = "inf", ZOMBIE_FEVER = "fever", FOOD_SICKNESS = "sick", FATIGUE = "fatigue" }

-- A character with a body: infected or not, a progress, items that go when used.
local function newCharacter()
    local c = { hours = 100, infected = false, time = -1, stats = {}, data = {} }
    local list = { size = function() return 0 end, get = function() end }
    local body = {
        IsInfected = function() return c.infected end,
        IsFakeInfected = function() return false end,
        getInfectionTime = function() return c.time end,
        setInfectionTime = function(_, t) c.time = t end,
        setInfected = function(_, v) c.infected = v end,
        setInfectionMortalityDuration = function() end,
        setIsFakeInfected = function() end,
        getBodyParts = function() return list end,
    }
    c.getBodyDamage = function() return body end
    c.getStats = function()
        return {
            get = function(_, stat) return c.stats[stat] or 0 end,
            set = function(_, stat, v) c.stats[stat] = v end,
            reset = function(_, stat) c.stats[stat] = nil end,
        }
    end
    c.getHoursSurvived = function() return c.hours end
    c.getModData = function() return c.data end
    c.getUsername = function() return "tester" end
    return c
end

local function newItem(itemType)
    local item = { removed = 0, data = {} }
    local container = { DoRemoveItem = function() item.removed = item.removed + 1 end }
    item.getType = function() return itemType end
    item.getContainer = function() return container end
    item.getModData = function() return item.data end
    return item
end

local function listen()
    local told = { titles = {}, says = {}, notices = {} }
    OA.Sync.listen("title", function(_, d) told.titles[#told.titles + 1] = d end)
    OA.Sync.listen("say", function(_, d) told.says[#told.says + 1] = d end)
    OA.Sync.listen("notice", function(_, d) told.notices[#told.notices + 1] = d end)
    return told
end

local function titleOf(told, key)
    for _, t in ipairs(told.titles) do
        if t.key == key then return t end
    end
    return nil
end

local function record(id)
    return OA.Store.ensure(id or "inf", "tester")
end

-- A language with n lines for each bundle named.
local function language(lines)
    getTextOrNull = function(key)
        for id, n in pairs(lines) do
            local k = tonumber(string.match(key, "^IGUI_OA_Say_" .. id .. "_(%d+)$"))
            if k and k >= 1 and k <= n then return key end
        end
        return nil
    end
end

-- A cure serum for an infected character, the shelf life not in the way.
local function cure(c, id)
    Serums.cureStatus = function() return "ok", 3 end
    c.infected = true
    return Serums.use(c, newItem("CureSerum"), id or "inf")
end

-- ---- what is remembered of an infection --------------------------------------------------------------------------

test("the days start at the wound; the doses are counted from then, and a negative test forgets both", function()
    local r = record()
    Infection.dose(r, "long", 5, nil)
    eq(r.infection.doses, nil, "a drug before any wound is not part of an infection")
    Infection.wounded(r, "scratch", 10)
    eq(r.infection.since, 10)
    Infection.wounded(r, "bite", 50)
    eq(r.infection.since, 10, "the first wound counts")
    Infection.dose(r, "long", 20, 1)
    Infection.dose(r, "short", 40, 1)
    eq(r.infection.doses, 2)
    Infection.tested(r, false)
    eq(r.infection.since, nil)
    eq(r.infection.doses, nil)
end)

test("a positive test sets the start when no wound did, and counts the positive tests", function()
    local r = record()
    eq(Infection.tested(r, true, 0.1, 30), 1)
    eq(r.infection.since, 30)
    eq(Infection.tested(r, true, 0.2, 40), 2)
    eq(r.infection.since, 30)
    eq(Infection.tested(r, false), 0)
    eq(r.infection.positives, 2, "the count stays: a later positive is not the first")
end)

test("the summary: whole days since the start (at least 1), the doses, and a length that is short, normal or long", function()
    local r = record()
    Infection.wounded(r, "scratch", 0)
    Infection.dose(r, "long", 1, 0)
    local days, doses, length = Infection.summary(r, 3)
    eq(days, 1)
    eq(doses, 1)
    eq(length, "short")
    days, _, length = Infection.summary(r, 24 * 14 - 1)
    eq(days, 14, "rounded to the nearest day")
    eq(length, "normal", "14 days is no longer short")
    days, _, length = Infection.summary(r, 24 * 43)
    eq(days, 43)
    eq(length, "normal")
    _, _, length = Infection.summary(r, 24 * 60 - 5)
    eq(length, "long")
    days, doses, length = Infection.summary(record("other"), 99)
    eq(days, 1)
    eq(doses, 0)
    eq(length, "short", "nothing known: a short one")
end)

-- ---- the bundles -------------------------------------------------------------------------------------------------

test("the cure's lines: a short infection draws the short line or the plain ones, a long one the long line", function()
    language({ Cured = 5 })
    local function drawn(length)
        local seen = {}
        local state = {}
        for _ = 1, 40 do
            local n = Say.pick(state, "Cured", { length = length }, 0)
            seen[n] = true
        end
        return seen
    end
    local short, normal, long = drawn("short"), drawn("normal"), drawn("long")
    truthy(short[1] and not short[2])
    truthy(long[2] and not long[1])
    truthy(not normal[1] and not normal[2] and normal[3] and normal[4] and normal[5])
end)

test("the first positive test draws lines 1 and 2, a later one lines 3 and 4", function()
    language({ TestPositive = 4 })
    local state = {}
    for _ = 1, 10 do
        local n = Say.pick(state, "TestPositive", { first = true }, 0)
        truthy(n == 1 or n == 2)
    end
    state = {}
    for _ = 1, 10 do
        local n = Say.pick(state, "TestPositive", { first = false }, 0)
        truthy(n == 3 or n == 4)
    end
end)

test("the lost-drug line comes at most once a day, the others have no rest", function()
    language({ DrugLost = 4, Reversal = 3 })
    local state = {}
    truthy(Say.pick(state, "DrugLost", nil, 100))
    eq(Say.pick(state, "DrugLost", nil, 110), nil)
    truthy(Say.pick(state, "DrugLost", nil, 124.5))
    truthy(Say.pick(state, "Reversal", nil, 100))
    truthy(Say.pick(state, "Reversal", nil, 100))
end)

test("the bundles of the infection are 3, 5, 4, 4, 4, 3 and 2 lines in both languages", function()
    local want = { CureStart = 3, Cured = 5, TestPositive = 4, TestNegative = 4, DrugLost = 4, Reversal = 3,
        DelayFirst = 2, TerminalFirst = 3 }
    for _, lang in ipairs({ "KO", "EN" }) do
        local text = readfile("OperationAcorn/42/media/lua/shared/Translate/" .. lang .. "/IG_UI.json") or ""
        for id, n in pairs(want) do
            local count = 0
            while string.find(text, '"IGUI_OA_Say_' .. id .. "_" .. (count + 1) .. '"', 1, true) do count = count + 1 end
            eq(count, n, lang .. " " .. id)
        end
    end
end)

-- ---- the events --------------------------------------------------------------------------------------------------

test("a positive test: a title bleeding in, a line for the first one, and the handling notice once", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    c.infected = true
    Infection.wounded(r, "scratch", 0)
    truthy(Serums.use(c, newItem("InfectionTestKit"), "inf"))
    eq(told.titles[1].key, "IGUI_OA_Title_TestPositive")
    eq(told.titles[1].style, "bleed")
    eq(told.says[1].id, "TestPositive")
    eq(told.says[1].ctx.first, true)
    -- the paper is in the folder, new, and a title says so
    local guide = titleOf(told, "IGUI_OA_Story_DocTitle_infection_guide")
    truthy(guide, "the notice title")
    eq(guide.sub, "IGUI_OA_Title_GuideSub")
    eq(guide.style, "type")
    local card = OA.StoryFolder.newGuide(r)
    eq(card.id, "infection_guide")
    -- a second positive test: another line, no second paper
    truthy(Serums.use(c, newItem("InfectionTestKit"), "inf"))
    eq(told.says[2].ctx.first, false)
    eq(#told.titles, 3, "the second stamp only")
    eq(titleOf(told, "IGUI_OA_Title_TestPositive") ~= nil, true)
end)

test("a negative test brings the news title and a line, and no paper", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    Infection.wounded(r, "scratch", 0)
    truthy(Serums.use(c, newItem("InfectionTestKit"), "inf"))
    eq(told.titles[1].key, "IGUI_OA_Title_TestNegative")
    eq(told.titles[1].sub, "IGUI_OA_Title_TestNegativeSub")
    eq(told.says[1].id, "TestNegative")
    eq(#told.titles, 1)
    eq(OA.StoryFolder.newGuide(r), nil)
end)

test("a delay drug has a line the first time only, whether or not there is an infection", function()
    local c = newCharacter()
    local told = listen()
    truthy(Serums.use(c, newItem("DelayDrug"), "inf"))
    eq(#told.says, 1)
    eq(told.says[1].id, "DelayFirst")
    truthy(Serums.use(c, newItem("DelayDrugLong"), "inf"))
    eq(#told.says, 1)
    eq(#told.notices, 2, "the text over the head each time")
end)

test("a reversal: the news title and a line, the same with no infection", function()
    local c = newCharacter()
    local told = listen()
    truthy(Serums.use(c, newItem("InfectionReversal"), "inf"))
    eq(told.titles[1].key, "IGUI_OA_Title_Reversal")
    eq(told.says[1].id, "Reversal")
end)

test("a zombie wound over a lasting drug: red text and a line; with no drug, nothing is said", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    Infection.dose(r, "long", 0, nil)
    TEST.hours = 5
    sendClientCommand(c, OA.MOD, "infection.wound", { id = "inf", kind = "scratch" })
    eq(told.notices[1].key, "IGUI_OA_Tree_DrugLost")
    eq(told.says[1].id, "DrugLost")
    sendClientCommand(c, OA.MOD, "infection.wound", { id = "inf", kind = "bite" })
    eq(#told.says, 1, "no drug: a scratch is not told")
    eq(#told.notices, 1)
    eq(#told.titles, 0)
end)

-- ---- the cure ----------------------------------------------------------------------------------------------------

test("a cure: the green stamp with the days and the drugs, the line a moment later, the certificate of its length", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    Infection.wounded(r, "scratch", 0)
    Infection.tested(r, true, 0.3, 0)
    TEST.hours = 24
    Infection.dose(r, "long", 24, 5)
    Infection.dose(r, "short", 100, 5)
    TEST.hours = 24 * 43
    truthy(cure(c))
    local stamp = titleOf(told, "IGUI_OA_Title_Cured")
    eq(stamp.style, "pulse")
    eq(stamp.tone, "green")
    eq(stamp.sub, "IGUI_OA_Title_CuredSubDrugs")
    eq(stamp.subArgs[1], 43)
    eq(stamp.subArgs[2], 2)
    eq(told.says[1].id, "Cured")
    eq(told.says[1].ctx.length, "normal")
    eq(told.says[1].delay, Serums.CURED_SAY_DELAY)
    truthy(Serums.CURED_SAY_DELAY >= 2 and Serums.CURED_SAY_DELAY <= 3)
    local card = OA.StoryFolder.newGuide(r)
    eq(card.id, "cure_cert_normal")
    local paper = titleOf(told, "IGUI_OA_Story_DocTitle_cure_cert_normal")
    eq(paper.sub, "IGUI_OA_Title_GuideSub")
    -- the certificate states the days and the doses it took
    local text = OA.StoryDocs.body(r, "cure_cert_normal", nil, Guides.pack(43, 2))
    truthy(string.find(text, " 43 2", 1, true), "the days and doses in the text")
end)

test("a cure with no drug has the plainer sub line", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    Infection.wounded(r, "cut", 0)
    TEST.hours = 24 * 5
    truthy(cure(c))
    local stamp = titleOf(told, "IGUI_OA_Title_Cured")
    eq(stamp.sub, "IGUI_OA_Title_CuredSub")
    eq(stamp.subArgs[1], 5)
    eq(told.says[1].ctx.length, "short")
    eq(OA.StoryFolder.newGuide(r).id, "cure_cert_short")
end)

test("the certificate is the one of the infection's length", function()
    for _, case in ipairs({ { 2, "short" }, { 40, "normal" }, { 90, "long" } }) do
        local c = newCharacter()
        local r = record("len" .. case[1])
        Infection.wounded(r, "scratch", 0)
        TEST.hours = 24 * case[1]
        truthy(cure(c, "len" .. case[1]))
        eq(OA.StoryFolder.newGuide(r).id, "cure_cert_" .. case[2])
    end
end)

test("a second cure of the same length sends no second paper and no second notice", function()
    local c = newCharacter()
    local r = record()
    local told = listen()
    Infection.wounded(r, "scratch", 0)
    TEST.hours = 24 * 3
    truthy(cure(c))
    Infection.wounded(r, "scratch", TEST.hours)
    TEST.hours = TEST.hours + 24 * 3
    truthy(cure(c))
    eq(#told.titles, 3, "two stamps and one notice")
    eq(told.says[2].id, "Cured")
end)

-- ---- the actions -------------------------------------------------------------------------------------------------

-- Loads the upgrade actions with a stand-in for the game's timed action base.
local function loadActions()
    local base = {}
    base.__index = base
    function base:derive() local c = setmetatable({}, { __index = self }); c.__index = c; return c end
    function base.new(cls, character) return setmetatable({ character = character, calls = {} }, cls) end
    function base:stop() end
    function base:perform() end
    function base:getJobDelta() return 0 end
    function base:setActionAnim(a) self.calls[#self.calls + 1] = "anim:" .. tostring(a) end
    function base:setOverrideHandModels() end
    ISBaseTimedAction = base
    CharacterActionAnims = { TakePills = "TakePills" }
    local real = require
    require = function(name)
        if string.find(name, "^TimedActions/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Actions")
    require = real
    if not ok then error(err, 0) end
    return OA.Upgrades.Actions
end

-- A character the actions can run on: what it says over its head, the sounds it plays and stops.
local function actor()
    local c = newCharacter()
    c.said, c.played, c.stopped, c.vars = {}, {}, {}, {}
    c.isTimedActionInstant = function() return false end
    c.isLocalPlayer = function() return true end
    c.Say = function(_, text) c.said[#c.said + 1] = text end
    c.playSound = function(_, name) c.played[#c.played + 1] = name; return 7 end
    c.getEmitter = function() return { isPlaying = function() return true end } end
    c.stopOrTriggerSound = function(_, handle) c.stopped[#c.stopped + 1] = handle end
    c.SetVariable = function(_, k, v) c.vars[k] = v end
    c.reportEvent = function() end
    return c
end

local function usable(itemType)
    local item = newItem(itemType)
    item.setJobDelta = function() end
    item.setJobType = function() end
    return item
end

test("the cure takes the longest, the test kit is a short wait, a serum as before", function()
    local Actions = loadActions()
    local c = actor()
    local cureAction = ISOAUseSerum:new(c, usable("CureSerum"))
    local testAction = ISOAUseSerum:new(c, usable("InfectionTestKit"))
    local serumAction = ISOAUseSerum:new(c, usable("UpgradeSerumScout"))
    eq(cureAction:getDuration(), Actions.CURE_TICKS)
    eq(testAction:getDuration(), Actions.TEST_TICKS)
    eq(serumAction:getDuration(), Actions.USE_TICKS)
    truthy(Actions.CURE_TICKS > Actions.USE_TICKS and Actions.TEST_TICKS < Actions.USE_TICKS)
    c.isTimedActionInstant = function() return true end
    eq(ISOAUseSerum:new(c, usable("CureSerum")):getDuration(), 1)
end)

test("starting the cure the character says a line; a serum or a drug says nothing", function()
    language({ CureStart = 3 })
    loadActions()
    local c = actor()
    ISOAUseSerum:new(c, usable("CureSerum")):start()
    eq(#c.said, 1)
    eq(#c.played, 0, "the dose has its own sound")
    ISOAUseSerum:new(c, usable("DelayDrug")):start()
    ISOAUseSerum:new(c, usable("UpgradeSerumScout")):start()
    eq(#c.said, 1)
end)

test("the test wait works at the kit with the game's wipe sound, and stops it when it is over or broken off", function()
    local Actions = loadActions()
    local c = actor()
    local action = ISOAUseSerum:new(c, usable("InfectionTestKit"))
    action:start()
    eq(c.played[1], PZUIKit.Sound.def("oa.serum.test").sound)
    eq(c.vars.LootPosition, "Mid")
    action:update()
    local anims = 0
    for _, call in ipairs(action.calls) do if call == "anim:TakePills" then anims = anims + 1 end end
    eq(anims, 0, "the pill animation is not set over the wait")
    action:perform()
    eq(c.stopped[1], 7)
    local again = ISOAUseSerum:new(c, usable("InfectionTestKit"))
    again:start()
    again:stop()
    eq(c.stopped[2], 7)
end)

test("the dose of a serum or a cure keeps the pill animation", function()
    loadActions()
    local c = actor()
    local action = ISOAUseSerum:new(c, usable("CureSerum"))
    action:update()
    eq(action.calls[1], "anim:TakePills")
end)
