-- What follows an upgrade serum dose (DESIGN-terminal 19): the adaptation (shared time, the points at the end, kept in
-- world time across a reload), the research team's papers (the plan with the first dose, a memo when a tree opens, one
-- when its meteorite fragment arrives and another at its capstone, each once), the first effect of six nodes (once each), the timing of the body taking an
-- applied selection, and that every new text is there in both languages.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Serums"
require "OperationAcorn/Upgrades/Server"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Plan = OA.Upgrades.Plan
local Adapt = OA.Upgrades.Adapt
local First = OA.Upgrades.First
local Serums = OA.Upgrades.Serums
local Docs = OA.StoryDocs

CharacterStat = { FOOD_SICKNESS = "sick", FATIGUE = "fatigue" }
BodyPartType = { UpperArm_L = "upperArmL" }

-- A character with the stats and the arm a dose touches, and an upgrade serum of a type in a bag.
local function character(id)
    local stats = {}
    local data = { OA_Id = id }
    local arm = { pain = 0 }
    function arm:getAdditionalPain() return self.pain end
    function arm:setAdditionalPain(v) self.pain = v end
    return {
        stats = stats, arm = arm,
        getUsername = function() return "tester" end,
        getModData = function() return data end,
        getStats = function()
            return {
                get = function(_, stat) return stats[stat] or 0 end,
                set = function(_, stat, v) stats[stat] = v end,
            }
        end,
        getBodyDamage = function()
            return { getBodyPart = function(_, part) return part == BodyPartType.UpperArm_L and arm or nil end }
        end,
    }
end

local function serum(itemType)
    local bag = { DoRemoveItem = function() end }
    return { getType = function() return itemType end, getContainer = function() return bag end }
end

-- What the player is told: the notices and the self-talk, in order.
local function listen()
    local told = { notices = {}, say = {}, changed = {} }
    OA.Sync.listen("notice", function(id, detail) told.notices[#told.notices + 1] = detail end)
    OA.Sync.listen("say", function(id, detail) told.say[#told.say + 1] = detail end)
    OA.Sync.listen("upgrades", function(id, detail) told.changed[#told.changed + 1] = detail end)
    return told
end

local function keys(told)
    local list = {}
    for _, n in ipairs(told.notices) do list[#list + 1] = n.key end
    return list
end

local function has(list, key)
    for _, k in ipairs(list) do if k == key then return true end end
    return false
end

test("a dose adapts first: the point and the tree come at the end", function()
    local c = character()
    local record = OA.Store.ensure("a1", "tester")
    local u = Rules.section(record)
    TEST.hours = 100
    truthy(Serums.inject(c, serum("UpgradeSerumScout"), "a1"))
    eq(Rules.ownPool(u, "scout"), 0, "no point yet")
    eq(Rules.treeOpen(u, "scout"), false, "the tree is not open yet")
    eq(u.adapt.doses.scout, 1)
    near(u.adapt.endsAt, 100 + Data.ADAPT_HOURS)
    truthy(Rules.adaptLeft(u, 100.2) > 0)
    eq(Rules.adaptDone(u, 100.2), false)
    eq(Adapt.finish(record, 100.2), false, "too early")
    eq(Rules.ownPool(u, "scout"), 0)
    eq(Adapt.finish(record, 100 + Data.ADAPT_HOURS), true)
    eq(Rules.ownPool(u, "scout"), 1)
    truthy(Rules.treeOpen(u, "scout"))
    eq(u.adapt, nil, "the adaptation is over")
    eq(Adapt.finish(record, 200), false, "nothing to finish twice")
    eq(Rules.ownPool(u, "scout"), 1)
end)

test("doses taken meanwhile share the time and their points come together at the end", function()
    local c = character()
    local record = OA.Store.ensure("a2", "tester")
    local u = Rules.section(record)
    TEST.hours = 50
    Serums.inject(c, serum("UpgradeSerumScout"), "a2")
    TEST.hours = 50.2
    Serums.inject(c, serum("UpgradeSerumScout"), "a2")
    Serums.inject(c, serum("UpgradeSerumLoad"), "a2")
    Serums.inject(c, serum("UpgradeSerumShared"), "a2")
    near(u.adapt.endsAt, 50.2 + Data.ADAPT_HOURS, 1e-9, "the end is the latest dose's, not a sum")
    eq(Adapt.finish(record, 50 + Data.ADAPT_HOURS), false, "the first dose's own end has passed, the shared one has not")
    eq(Adapt.finish(record, 50.2 + Data.ADAPT_HOURS), true)
    eq(Rules.ownPool(u, "scout"), 2)
    eq(Rules.ownPool(u, "load"), 1)
    eq(Rules.sharedPool(u), 1)
    eq(Rules.ownPool(u, "survival"), 0)
end)

test("the end is kept in world time: a reload that finds it passed lets the server finish it", function()
    local c = character()
    local record = OA.Store.ensure("a3", "tester")
    local u = Rules.section(record)
    TEST.hours = 300
    Serums.inject(c, serum("UpgradeSerumSurvival"), "a3")
    -- saved and loaded: the section is plain data, filled again
    local loaded = Rules.fill(Rules.copy(u))
    eq(loaded.adapt.doses.survival, 1)
    near(loaded.adapt.endsAt, 300 + Data.ADAPT_HOURS)
    eq(Rules.adaptDone(loaded, 300.1), false)
    eq(Rules.adaptDone(loaded, 340), true, "a long time away: it is over at once")
    -- the client asks at its first minute; the server finishes only when the record agrees
    TEST.hours = 300.1
    sendClientCommand(c, OA.MOD, "upgrades.adapt", { id = "a3" })
    eq(Rules.ownPool(u, "survival"), 0)
    TEST.hours = 340
    sendClientCommand(c, OA.MOD, "upgrades.adapt", { id = "a3" })
    eq(Rules.ownPool(u, "survival"), 1)
    sendClientCommand(c, OA.MOD, "upgrades.adapt", { id = "a3" })
    eq(Rules.ownPool(u, "survival"), 1, "a second ask changes nothing")
end)

test("the first dose ever brings the research plan to the folder, once", function()
    local c = character()
    local record = OA.Store.ensure("g1", "tester")
    local told = listen()
    TEST.hours = 10
    Serums.inject(c, serum("UpgradeSerumLoad"), "g1")
    eq(Docs.kind("research_guide"), "guide")
    truthy(OA.Story.section(record).docs.research_guide, "the plan is in the folder")
    truthy(OA.Story.section(record).unread["d:research_guide"], "new until opened")
    eq(#told.notices, 1)
    eq(told.notices[1].key, "IGUI_OA_Tree_GuideSent")
    Serums.inject(c, serum("UpgradeSerumLoad"), "g1")
    Serums.inject(c, serum("UpgradeSerumScout"), "g1")
    eq(#told.notices, 1, "no second notice")
end)

test("a tree opening brings its memo once; the notice says whether it came", function()
    local c = character()
    local record = OA.Store.ensure("m1", "tester")
    local told = listen()
    TEST.hours = 10
    Serums.inject(c, serum("UpgradeSerumScout"), "m1")
    Serums.inject(c, serum("UpgradeSerumScout"), "m1")
    Adapt.finish(record, 11)
    local story = OA.Story.section(record)
    truthy(story.docs.memo_scout_open)
    eq(story.docs.memo_load_open, nil)
    local opened, adapted = 0, nil
    for _, n in ipairs(told.notices) do
        if n.key == "IGUI_OA_Tree_Opened" then
            opened = opened + 1
            eq(n.args[1], "scout")
            eq(n.args[2], "guide")
        elseif n.key == "IGUI_OA_Tree_Adapted" then
            adapted = n.args
        end
    end
    eq(opened, 1, "a tree opens once, whatever the number of doses")
    eq(adapted[1], "scout")
    eq(adapted[2], 2, "both points told together")
    -- the same tree again: no memo, no opening
    Serums.inject(c, serum("UpgradeSerumScout"), "m1")
    Adapt.finish(record, 12)
    opened = 0
    for _, n in ipairs(told.notices) do if n.key == "IGUI_OA_Tree_Opened" then opened = opened + 1 end end
    eq(opened, 1)
    -- the self-talk is the bundle for the tree
    eq(told.say[#told.say].id, "Adapted")
    eq(told.say[#told.say].ctx.tree, "scout")
end)

test("a shared serum has no tree to open and no self-talk, only its line", function()
    local c = character()
    local record = OA.Store.ensure("s1", "tester")
    local told = listen()
    TEST.hours = 10
    Serums.inject(c, serum("UpgradeSerumShared"), "s1")
    Adapt.finish(record, 11)
    truthy(has(keys(told), "IGUI_OA_Tree_AdaptedShared"))
    eq(has(keys(told), "IGUI_OA_Tree_Opened"), false)
    eq(#told.say, 0)
    eq(Rules.sharedPool(Rules.section(record)), 1)
end)

test("a capstone approved brings the tree's follow-up memo, once", function()
    local record = OA.Store.ensure("c1", "tester")
    local u = Rules.section(record)
    local told = listen()
    local before = Adapt.capstones(u)
    eq(before.scout, nil)
    Rules.inject(u, "scout")
    u.ranks.nightEye = 1
    eq(Adapt.approved(record, before), true)
    truthy(OA.Story.section(record).docs.memo_scout_cap)
    eq(OA.Story.section(record).docs.memo_load_cap, nil)
    eq(told.notices[#told.notices].key, "IGUI_OA_Tree_GuideSent")
    eq(Adapt.approved(record, before), false, "the memo is not sent twice")
    eq(Adapt.approved(record, Adapt.capstones(u)), false, "a capstone taken before is not new")
end)

test("a fragment received unseals its tree once and brings the sample memo", function()
    local record = OA.Store.ensure("f1", "tester")
    local u = Rules.section(record)
    local told = listen()
    eq(OA.Upgrades.fragmentReceived(record, "Base.Rock"), false, "not a fragment")
    eq(OA.Upgrades.fragmentReceived(record, Data.FRAGMENTS.load), true)
    eq(Rules.unsealed(u, "load"), true)
    eq(Rules.unsealed(u, "scout"), false)
    truthy(OA.Story.section(record).docs.memo_load_sample)
    eq(told.changed[#told.changed].kind, "unseal")
    eq(told.changed[#told.changed].tree, "load")
    eq(told.notices[#told.notices].key, "IGUI_OA_Tree_GuideSent")
    local n = #told.notices
    eq(OA.Upgrades.fragmentReceived(record, Data.FRAGMENTS.load), false, "a second one of the kind changes nothing")
    eq(#told.notices, n)
    eq(Data.treeOfFragment(Data.FRAGMENTS.scout), "scout")
    eq(Data.treeOfFragment(Data.FRAGMENTS.survival), "survival")
end)

test("the papers are guide documents with a title and a text in both languages", function()
    local ids = { Adapt.GUIDE }
    for _, tree in ipairs(Data.TREES) do
        for _, which in ipairs(Adapt.MEMOS) do ids[#ids + 1] = Adapt.memoId(tree, which) end
    end
    eq(#ids, 10)
    for _, lang in ipairs({ "KO", "EN" }) do
        local text = readfile("OperationAcorn/42/media/lua/shared/Translate/" .. lang .. "/IG_UI.json")
        for _, id in ipairs(ids) do
            eq(Docs.kind(id), "guide", id)
            truthy(string.find(text, '"' .. Docs.titleKey(id) .. '"', 1, true), lang .. " title of " .. id)
            truthy(string.find(text, '"IGUI_OA_Story_Doc_' .. id .. '"', 1, true), lang .. " text of " .. id)
        end
    end
end)

test("the self-talk bundles have their lines in both languages, three a tree and two a node", function()
    for _, lang in ipairs({ "KO", "EN" }) do
        local text = readfile("OperationAcorn/42/media/lua/shared/Translate/" .. lang .. "/IG_UI.json")
        for n = 1, #Data.TREES * 3 do
            truthy(string.find(text, '"IGUI_OA_Say_Adapted_' .. n .. '"', 1, true), lang .. " Adapted " .. n)
        end
        eq(string.find(text, '"IGUI_OA_Say_Adapted_' .. (#Data.TREES * 3 + 1) .. '"', 1, true), nil)
        for n = 1, #Data.FIRST_EFFECT * 2 do
            truthy(string.find(text, '"IGUI_OA_Say_FirstEffect_' .. n .. '"', 1, true), lang .. " FirstEffect " .. n)
        end
        eq(string.find(text, '"IGUI_OA_Say_FirstEffect_' .. (#Data.FIRST_EFFECT * 2 + 1) .. '"', 1, true), nil)
    end
    -- the tags put each line with its tree and its node
    eq(OA.Say.fits("Adapted", 1, { tree = "scout" }), true)
    eq(OA.Say.fits("Adapted", 4, { tree = "scout" }), false)
    eq(OA.Say.fits("Adapted", 4, { tree = "load" }), true)
    eq(OA.Say.fits("Adapted", 9, { tree = "survival" }), true)
    eq(OA.Say.fits("FirstEffect", 1, { node = "sense" }), true)
    eq(OA.Say.fits("FirstEffect", 3, { node = "sense" }), false)
    eq(OA.Say.fits("FirstEffect", 12, { node = "dash" }), true)
end)

-- ---- the first effects --------------------------------------------------------------------------------------------

test("a node tells its first effect once, with a rank taken, and only the six named", function()
    local record = OA.Store.ensure("f1", "tester")
    local u = Rules.section(record)
    eq(Rules.firstEffect(u, "sense"), false, "no rank, no first effect")
    u.ranks.sense = 1
    eq(Rules.firstEffect(u, "sense"), true)
    eq(Rules.firstEffect(u, "sense"), false, "once")
    eq(Rules.firstEffect(u, "sixth"), false, "a node that is not one of the six")
    eq(#Data.FIRST_EFFECT, 6)
    for _, id in ipairs(Data.FIRST_EFFECT) do truthy(Data.byId[id], id) end
end)

test("First.grant notes it, tells the player over the head and in self-talk, and keeps it for good", function()
    local record = OA.Store.ensure("f2", "tester")
    local u = Rules.section(record)
    local told = listen()
    u.ranks.sense = 2
    u.ranks.dash = 1
    eq(First.grant(record, "sense"), true)
    eq(told.notices[1].key, "IGUI_OA_Tree_FirstEffect")
    eq(told.notices[1].args[1], "sense")
    eq(told.notices[1].args[2], 2)
    eq(told.say[1].id, "FirstEffect")
    eq(told.say[1].ctx.node, "sense")
    eq(First.grant(record, "sense"), false)
    eq(#told.notices, 1)
    eq(#told.say, 1)
    -- a node of one rank has no stage to tell
    eq(First.grant(record, "dash"), true)
    eq(told.notices[2].key, "IGUI_OA_Tree_FirstEffectSingle")
    -- a reset does not give the first effect back
    u.ranks.sense = nil
    u.ranks.sense = 1
    eq(First.grant(record, "sense"), false)
    eq(First.grant(nil, "sense"), false)
end)

test("the client asks the server once for a node it saw working, and not again once it is noted", function()
    local c = character("f3")
    local record = OA.Store.ensure("f3", "tester")
    local u = Rules.section(record)
    OA.Client.record = function() return record end
    getPlayer = function() return c end
    local clock = 1000000
    getTimestampMs = function() return clock end
    local function asked()
        local n = 0
        for _, sent in ipairs(TEST.sent) do if sent.command == "upgrades.first" then n = n + 1 end end
        return n
    end
    First.report("ledger")
    eq(asked(), 0, "a node not taken asks nothing")
    u.ranks.ledger = 1
    First.report("ledger")
    eq(asked(), 1)
    -- the server noted it, so the record has it now
    eq(u.firstEffect.ledger, true)
    First.report("ledger")
    eq(asked(), 1, "noted: nothing more is asked")
    -- not noted (the server said no): it may ask again only after a while
    u.ranks.crowbar = 1
    First.report("crowbar", c)
    u.firstEffect.crowbar = nil
    First.report("crowbar", c)
    eq(asked(), 2, "a second ask waits")
    clock = clock + First.ASK_MS + 1
    First.report("crowbar", c)
    eq(asked(), 3)
end)

test("the server notes a first effect a client reports, and ignores a bad one", function()
    local c = character()
    local record = OA.Store.ensure("f4", "tester")
    local u = Rules.section(record)
    u.ranks.furniture = 1
    sendClientCommand(c, OA.MOD, "upgrades.first", { id = "f4", node = "furniture" })
    eq(u.firstEffect.furniture, true)
    sendClientCommand(c, OA.MOD, "upgrades.first", { id = "f4", node = "alarm" })
    eq(u.firstEffect.alarm, nil)
    sendClientCommand(c, OA.MOD, "upgrades.first", { id = "f4", node = 5 })
    sendClientCommand(c, OA.MOD, "upgrades.first", { id = "f4" })
end)

-- ---- the body taking an applied selection ------------------------------------------------------------------------

test("the take reaches each applied node once, in the selection's order, on the screen only", function()
    local steps = { { id = "a" }, { id = "b" }, { id = "a" }, { id = "c" }, { id = "b" } }
    local order = Plan.takeOrder(steps, { a = true, b = true, c = true })
    eq(table.concat(order, ","), "a,b,c")
    order = Plan.takeOrder(steps, { a = true, c = true })
    eq(table.concat(order, ","), "a,c", "the board's nodes are not on a trees screen")
    eq(#Plan.takeOrder(steps, nil), 3)
    eq(#Plan.takeOrder({}, {}), 0)
end)

test("the take's scan: a node at a step each, a long selection kept short", function()
    eq(Plan.takeStep(3), Plan.TAKE_STEP_MS)
    eq(Plan.takeStep(100), math.floor(Plan.TAKE_MAX_MS / 100))
    truthy(100 * Plan.takeStep(100) <= Plan.TAKE_MAX_MS)
    local n = 4
    local step = Plan.takeStep(n)
    eq(Plan.takeLit(n, -1), 0)
    eq(Plan.takeLit(n, 0), 1)
    eq(Plan.takeLit(n, step), 2)
    eq(Plan.takeLit(n, step * 3), 4)
    eq(Plan.takeLit(n, step * 10), 4, "never more than the selection")
    eq(Plan.takeLit(0, 500), 0)
end)

test("a node taken pops, bursts with a growing fading glow and a short core flash, its pips flashing", function()
    eq(Plan.takePop(-1), 1)
    eq(Plan.takePop(Plan.TAKE_POP_MS), 1)
    local top = 1
    for t = 0, Plan.TAKE_POP_MS do top = math.max(top, Plan.takePop(t)) end
    near(top, 1 + Plan.TAKE_POP, 0.002)
    eq(Plan.takeBurst(-1), nil)
    local size, a, core = Plan.takeBurst(0)
    eq(size, Plan.TAKE_BURST_FROM)
    eq(a, 1)
    eq(core, 1)
    local size2, a2, core2 = Plan.takeBurst(Plan.TAKE_CORE_MS)
    truthy(size2 > size and a2 < a, "growing and fading")
    eq(core2, 0, "the core flash is the short part")
    size, a = Plan.takeBurst(Plan.TAKE_BURST_MS - 1)
    truthy(size > Plan.TAKE_BURST_TO * 0.99 and a < 0.01)
    eq(Plan.takeBurst(Plan.TAKE_BURST_MS), nil)
    eq(Plan.takePip(0), 1)
    truthy(Plan.takePip(Plan.TAKE_PIP_MS - 1) < 0.01)
    eq(Plan.takePip(Plan.TAKE_PIP_MS), nil)
end)

test("a taken node's light runs up its way, arrives at the header on time, and drains out", function()
    local len = 120
    eq(Plan.takeRun(-1, len), nil)
    local last = -1
    for t = 0, 2000, 10 do
        local head, a = Plan.takeRun(t, len)
        if head then
            truthy(head > last, "up the way, never back")
            truthy(a > 0 and a <= 1)
            last = head
        end
    end
    near(select(1, Plan.takeRun(Plan.takeArrive(len), len)), len, 1e-6, "the head at the header when it arrives")
    eq(Plan.takeRun(Plan.takeArrive(len + Plan.TAKE_TAIL), len), nil, "its tail drained")
    eq(Plan.takeArrive(0), 0, "a node with no way: its header at once")
    eq(Plan.takeHeader(-1), 0)
    truthy(Plan.takeHeader(60) > 0.7, "the header flashes quickly")
    eq(Plan.takeHeader(Plan.TAKE_HEADER_MS), 0)
end)

test("the light runs round the columns after the last node and its light, once, and the take ends with it", function()
    for _, n in ipairs({ 1, 3, 6 }) do
        local last = (n - 1) * Plan.takeStep(n)
        for _, arrive in ipairs({ last, last + 500 }) do
            local at = Plan.takeGlowAt(n, arrive)
            truthy(at >= last + Plan.TAKE_GLOW_WAIT_MS and at >= arrive, "after the scan and the lights")
            truthy(Plan.takeEnd(n, arrive) >= at + Plan.TAKE_GLOW_MS, "the glow is the last part")
        end
    end
    eq(Plan.takeGlow(-1), nil)
    local along, line, fill = Plan.takeGlow(0)
    eq(along, 0)
    eq(line, 1)
    eq(fill, 0)
    -- halfway round in a fifth of its time (slowing more and more as it comes round), round and at its brightest at
    -- TAKE_TRACE
    near(Plan.takeGlow(Plan.TAKE_GLOW_MS * Plan.TAKE_TRACE * (1 - 0.5 ^ (1 / 3))), 0.5, 1e-9)
    along, line, fill = Plan.takeGlow(Plan.TAKE_GLOW_MS * Plan.TAKE_TRACE)
    near(along, 1, 1e-9)
    near(line, 1, 1e-9)
    near(fill, 1, 1e-9)
    local _, late, lateFill = Plan.takeGlow(Plan.TAKE_GLOW_MS * 0.99)
    truthy(late > 0 and late < 0.1 and lateFill == late, "the frame fades after the light came round")
    eq(Plan.takeGlow(Plan.TAKE_GLOW_MS), nil)
end)

test("the take lasts about 2 to 3.2 s for a few nodes, before the padlocks come off", function()
    for _, n in ipairs({ 1, 3, 5 }) do
        local last = (n - 1) * Plan.takeStep(n) + Plan.takeArrive(150)
        local ends = Plan.takeEnd(n, last)
        truthy(ends >= 2000 and ends <= 3200, n .. " nodes: " .. ends)
    end
end)

-- ---- the client's minute ------------------------------------------------------------------------------------------

test("the moodle follows the record and the server is asked once the end has passed", function()
    local real = require
    ISPanel = { derive = function() return setmetatable({}, { __index = function() return function() end end }) end }
    -- the moodles' stand-ins follow the mouse with the terminal's helpers (Trade/UI), whose palettes name the fonts
    UIFont = UIFont or setmetatable({}, { __index = function(_, k) return k end })
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Adapting")
    require = real
    if not ok then error(err, 0) end
    local Adapting = OA.Upgrades.Adapting
    local set = {}
    OA.Upgrades.Moodles.set = function(id, level) set[#set + 1] = id .. "=" .. level end
    local c = character("w1")
    local record = OA.Store.ensure("w1", "tester")
    local u = Rules.section(record)
    Adapting.minute(c, u, 10)
    eq(set[#set], "adapting=0")
    eq(#TEST.sent, 0)
    Rules.startAdapt(u, "scout", 10)
    Adapting.minute(c, u, 10)
    eq(set[#set], "adapting=4", "about 30 minutes left")
    Adapting.minute(c, u, 10.2)
    eq(set[#set], "adapting=3", "about 20")
    Adapting.minute(c, u, 10.4)
    eq(set[#set], "adapting=2", "about 10")
    Adapting.minute(c, u, 10.45)
    eq(set[#set], "adapting=1", "almost done")
    eq(#TEST.sent, 0, "not yet")
    Adapting.minute(c, u, 10 + Data.ADAPT_HOURS)
    eq(set[#set], "adapting=1", "the moodle stays until the server has finished it")
    eq(TEST.sent[#TEST.sent].command, "upgrades.adapt")
end)

-- ---- the furniture and the crowbar -------------------------------------------------------------------------------

test("lifting a furniture is 가구 운반's first effect, with the rank taken, once", function()
    local real = require
    ISMoveablesAction = {}
    function ISMoveablesAction:new(character, square, mode) return setmetatable({ character = character, mode = mode }, { __index = self }) end
    function ISMoveablesAction:complete() return true end
    require = function(name)
        if name == "Moveables/ISMoveablesAction" then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/FirstHooks")
    require = real
    if not ok then error(err, 0) end
    local c = character("fh")
    local record = OA.Store.ensure("fh", "tester")
    local u = Rules.section(record)
    local told = listen()
    local lift = ISMoveablesAction:new(c, "square", "pickup")
    eq(lift.oaId, "fh", "the record's id is put on the action")
    eq(lift:complete(), true)
    eq(#told.notices, 0, "furniture hauling not taken: nothing")
    u.ranks.furniture = 1
    eq(ISMoveablesAction:new(c, "square", "place"):complete(), true)
    eq(#told.notices, 0, "placing is not lifting")
    lift:complete()
    eq(#told.notices, 1)
    eq(told.notices[1].key, "IGUI_OA_Tree_FirstEffect")
    eq(told.notices[1].args[1], "furniture")
    lift:complete()
    eq(#told.notices, 1, "once")
end)

test("a pried lock is 쇠지렛대로 따기's first effect, from the action that decides it", function()
    local real = require
    ISBaseTimedAction = { derive = function(self) return setmetatable({}, { __index = self }) end,
                          new = function(self) return setmetatable({}, { __index = self }) end }
    require = function(name)
        if string.find(name, "^TimedActions/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Actions")
    require = real
    if not ok then error(err, 0) end
    local record = OA.Store.ensure("cb", "tester")
    local u = Rules.section(record)
    u.ranks.crowbar = 1
    local told = listen()
    -- the pry bar and the lock: a character with a bar, a door that opens
    OA.Upgrades.Actions.pryBar = function() return {} end
    OA.Upgrades.Actions.unlock = function() end
    OA.Upgrades.Actions.isReinforced = function() return false end
    addSound = function() end
    instanceof = function() return false end
    OA.random = function() return 1 end
    local target = { getSquare = function() return nil end }
    local body = { getStats = function() return {} end, getX = function() return 0 end, getY = function() return 0 end,
                   getZ = function() return 0 end }
    local action = setmetatable({ oaId = "cb", target = target, character = body }, { __index = ISOAPryOpen })
    eq(action:complete(), true)
    eq(u.firstEffect.crowbar, true)
    eq(told.notices[#told.notices].key, "IGUI_OA_Tree_FirstEffect")
    local function firsts()
        local n = 0
        for _, notice in ipairs(told.notices) do if notice.key == "IGUI_OA_Tree_FirstEffect" then n = n + 1 end end
        return n
    end
    eq(firsts(), 1)
    action:complete()
    eq(firsts(), 1, "once")
end)

test("a dose makes the arm sore and the character drowsy, never asleep; 혈청 적응 halves both and the time, then ends them", function()
    local c = character()
    OA.Store.ensure("se1", "tester")
    TEST.hours = 10
    c.stats.fatigue = 0.1
    Serums.inject(c, serum("UpgradeSerumScout"), "se1")
    near(c.arm.pain, Serums.PAIN, 1e-9, "a sore arm")
    near(c.stats.fatigue, 0.6, 1e-9, "drowsy enough for the moodle")
    Serums.inject(c, serum("UpgradeSerumScout"), "se1")
    near(c.arm.pain, Serums.PAIN, 1e-9, "the pain does not pile up")
    near(c.stats.fatigue, Serums.FATIGUE_MAX, 1e-9, "never past the most a dose brings")
    c.stats.fatigue = 0.98
    Serums.inject(c, serum("UpgradeSerumScout"), "se1")
    near(c.stats.fatigue, 0.98, 1e-9, "one more tired than that is left as tired as it is")
    local u = Rules.blank()
    near(Rules.adaptHours(u), Data.ADAPT_HOURS)
    local half = Rules.blank()
    half.ranks.serumAdapt = 1
    near(Rules.adaptHours(half), Data.ADAPT_HOURS / 2)
    local none = Rules.blank()
    none.ranks.serumAdapt = 2
    near(Rules.adaptHours(none), Data.ADAPT_HOURS / 4)
    Rules.startAdapt(half, "scout", 5)
    near(half.adapt.endsAt, 5 + Data.ADAPT_HOURS / 2, 1e-9, "a shorter adaptation")
    eq(Rules.adaptLevel(Rules.blank(), 5), 0, "nothing adapting: no moodle")
end)
