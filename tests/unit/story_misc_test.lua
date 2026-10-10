-- Drop sites, documents, the overlay's arithmetic, the radio frequency, the compass, and the texts the data names.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Story/Sites"
require "OperationAcorn/Story/Glow"
require "OperationAcorn/Story/Radio"
local OA = OperationAcorn
local Data, Story, Docs, Sites = OA.StoryData, OA.Story, OA.StoryDocs, OA.Sites

local BOUNDS = { minX = 0, minY = 0, maxX = 14000, maxY = 12000 }

test("the sites are decided once, spread out, each with its own stake number", function()
    local list = Sites.ensure(BOUNDS, function() return true end)
    eq(#list, 24)
    eq(Sites.ensure(BOUNDS, function() return false end), list, "once")
    local stakes = {}
    for i, a in ipairs(list) do
        eq(a.n, i)
        eq(a.state, "pending")
        eq(stakes[a.stake], nil, "stake numbers differ")
        stakes[a.stake] = true
        truthy(a.date >= 1 and a.date <= Sites.DATES)
        for j = i + 1, #list do
            local b = list[j]
            truthy(OA.Places.distance(a.x, a.y, b.x, b.y) >= OA.Store.world("sites").spacing - 1, "spaced")
        end
    end
    eq(Sites.byNumber(3), list[3])
    eq(Sites.byNumber(99), nil)
end)

test("the site count follows the option", function()
    SandboxVars.OperationAcorn = SandboxVars.OperationAcorn or {}
    SandboxVars.OperationAcorn.MeteorSites = 0.5
    eq(Sites.count(), 12)
end)

test("a site that is not land is moved, and gives up after a number of tries", function()
    local list = Sites.ensure(BOUNDS, function() return true end)
    local site = list[1]
    local ox, oy = site.x, site.y
    truthy(Sites.replace(site, BOUNDS, function() return true end))
    truthy(site.x ~= ox or site.y ~= oy, "a new place")
    for _ = 1, Sites.MAX_RETRIES do Sites.replace(site, BOUNDS, function() return true end) end
    eq(Sites.replace(site, BOUNDS, function() return true end), false)
    eq(site.state, "failed")
end)

test("fragments: one to three, more with the upgrade, the expectation kept", function()
    eq(Sites.fragmentCount(0, function() return 2 end, function() return 0.5 end), 2)
    eq(Sites.fragmentCount(0.5, function() return 3 end, function() return 0.1 end), 5, "4.5 rounds up on a low roll")
    eq(Sites.fragmentCount(0.5, function() return 3 end, function() return 0.99 end), 4)
    eq(Sites.fragmentCount(0.5, function() return 3 end, function() return 0.6 end), 4)
    local sum, n = 0, 400
    local seed = 12345
    local function rnd(a, b)
        seed = OA.remainder(seed * 69069 + 1, 4294967296)
        return a + OA.remainder(math.floor(seed / 65536), b - a + 1)
    end
    local function rndf()
        seed = OA.remainder(seed * 69069 + 1, 4294967296)
        return seed / 4294967296
    end
    for _ = 1, n do sum = sum + Sites.fragmentCount(0.5, rnd, rndf) end
    near(sum / n, 3.0, 0.35, "2 x 1.5 on average")
end)

test("the best upgrade bonus among the records, and none without the upgrade part", function()
    eq(Sites.bestBonus(), 0)
    local a = OA.Store.ensure("a", "A")
    local b = OA.Store.ensure("b", "B")
    OA.Upgrades = { fragmentBonus = function(rec) return rec == a and 0.25 or 0.5 end }
    eq(Sites.bestBonus(), 0.5)
    OA.Upgrades = nil
end)

test("a player near a site has seen it", function()
    local list = Sites.ensure(BOUNDS, function() return true end)
    list[2].state = "placed"
    local record = OA.Store.ensure("p1", "P")
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    eq(Sites.visit(record, list[2].x + 200, list[2].y), false)
    eq(#told, 0)
    truthy(Sites.visit(record, list[2].x + 20, list[2].y))
    eq(Story.section(record).sitesSeen[2], true)
    eq(#told, 1)
    eq(told[1].key, "IGUI_OA_Title_Site")
    eq(told[1].style, "discovery")
    eq(Sites.visit(record, list[2].x, list[2].y), false, "once")
    eq(#told, 1, "a title the first time only")
end)

test("documents of an item: its own id first, its data ones, a field note", function()
    local record = OA.Store.ensure("p1", "P")
    local list = Docs.forItem(record, "SampleCooler", {})
    eq(#list, 2)
    eq(list[1].id, "cooler_front")
    eq(list[2].id, "cooler_back")
    list = Docs.forItem(record, "AnalysisReply", { OA_Doc = "reply_first" })
    eq(#list, 1)
    eq(list[1].id, "reply_first")
    list = Docs.forItem(record, "MissionEnvelope", { OA_Note = "note_3" })
    eq(#list, 1)
    eq(list[1].id, "note_3")
    eq(#Docs.forItem(record, "MissionEnvelope", { OA_Note = "bogus" }), 0)
    eq(#Docs.forItem(record, "MeteorFragment", {}), 0)
    list = Docs.forItem(record, "StakeTag", { OA_Stake = 412 })
    eq(list[1].extra, 412)
    list = Docs.forItem(record, "EvidenceEnvelope", { OA_Variant = "westpoint_pd" })
    eq(list[1].variant, "westpoint_pd")
end)

test("every document id has a kind and a title key, and the registry is complete", function()
    local all = Docs.all()
    truthy(#all >= 40)
    for _, id in ipairs(all) do
        truthy(Docs.kind(id), id)
        truthy(string.find(Docs.titleKey(id), "^IGUI_OA_Story_DocTitle_%w"), id)
    end
    for _, item in pairs(Data.ITEMS) do
        for _, id in ipairs(item.docs or {}) do truthy(Docs.kind(id), "item document " .. id) end
    end
end)

test("a document's text takes the number, the place and where in the building", function()
    local record = OA.Store.ensure("p1", "P")
    record.number = 347
    local text = Docs.body(record, "police_card", "muldraugh_pd")
    truthy(string.find(text, "0347", 1, true))
    truthy(string.find(text, "IGUI_OA_Story_Place_muldraugh_pd", 1, true))
    truthy(string.find(text, "IGUI_OA_Story_PlaceNote_muldraugh_pd", 1, true))
    local slip = Docs.body(record, "soil_slip", nil, nil)
    truthy(string.find(slip, "Doc_soil_slip_plain", 1, true))
    slip = Docs.body(record, "soil_slip", nil, 412)
    truthy(string.find(slip, "Doc_soil_slip ", 1, true) and string.find(slip, "412", 1, true))
    truthy(string.find(Docs.stakeBody(412, 3), "StakeDate_3", 1, true))
end)

test("the roster page shares three numbers with the status table and smears the player's", function()
    local record = OA.Store.ensure("p1", "P")
    record.number = 347
    local st = Story.statusTable(record)
    local page = Docs.body(record, "roster_page", "riverside_school")
    for _, idx in ipairs(st.roster) do
        truthy(string.find(page, string.format("%04d", st.rows[idx].n), 1, true), "row " .. idx)
    end
    truthy(string.find(page, "Doc_roster_page_smeared 0347", 1, true))
    local table_ = Docs.body(record, "status_table")
    local lines = 0
    for _ in string.gmatch(table_, "[^\n]+") do lines = lines + 1 end
    eq(lines, 1 + Data.STATUS_ROWS + 1 - 0, "head, rows, foot")
end)

test("the glow rises fast, holds, and falls slowly, and the edges face the right way", function()
    local G = OA.Glow
    eq(G.envelope(0, 1000), 0)
    eq(G.envelope(1000, 1000), 0)
    near(G.envelope(60, 1000), 0.5, 1e-9)
    eq(G.envelope(500, 1000), 1)
    truthy(G.envelope(900, 1000) < G.envelope(700, 1000))
    eq(G.edge(10, -10), "right")
    eq(G.edge(-10, 10), "left")
    eq(G.edge(10, 10), "bottom")
    eq(G.edge(-10, -10), "top")
end)

test("the radio takes the first free frequency and keeps the one it had", function()
    local R = OA.StoryRadio
    eq(R.choose({}, nil, { 100, 200, 300 }), 100)
    eq(R.choose({ [100] = true }, nil, { 100, 200, 300 }), 200)
    eq(R.choose({ [100] = true }, 300, { 100, 200, 300 }), 300, "the saved one while it is free")
    eq(R.choose({ [300] = true }, 300, { 100, 200, 300 }), 100, "a clash moves it")
    local all = {}
    for _, f in ipairs({ 100, 200 }) do all[f] = true end
    local f = R.choose(all, nil, { 100, 200 }, function(a, b) return 450 end)
    eq(f, 90000)
    -- Every candidate is a multiple of 200 kHz in the broadcast band.
    for _, c in ipairs(R.CANDIDATES) do
        eq(OA.remainder(c, 200), 0)
        truthy(c >= 88000 and c <= 108000)
    end
end)

test("the compass names where a place lies from the base", function()
    local P = OA.Places
    eq(P.bearing(0, 0, 100, 0), "E")
    eq(P.bearing(0, 0, 0, 100), "S")
    eq(P.bearing(0, 0, -100, 0), "W")
    eq(P.bearing(0, 0, 0, -100), "N")
    eq(P.bearing(0, 0, 100, 100), "SE")
    eq(P.bearing(0, 0, -100, -100), "NW")
    eq(P.bearing(0, 0, 100, -100), "NE")
    eq(P.bearing(0, 0, -100, 100), "SW")
    eq(P.bearing(5, 5, 5, 5), nil)
end)

-- ---------------------------------------------------------------------------------------------------------------
-- The texts: every id the data names has a text in both languages (the translation checker covers the code's keys).

local function keysOf(lang, file)
    local text = readfile("OperationAcorn/42/media/lua/shared/Translate/" .. lang .. "/" .. file) or ""
    local keys = {}
    for line in string.gmatch(text, "[^\n]+") do
        local k, v = string.match(line, '^%s*"([^"]+)":%s*"(.*)",?%s*$')
        if k then keys[k] = v end
    end
    return keys
end

local function need(lang, file, list)
    local keys = keysOf(lang, file)
    for _, key in ipairs(list) do
        if keys[key] == nil then error(lang .. " " .. file .. " lacks " .. key) end
    end
end

local function storyIds()
    local ids = {}
    for id in pairs(Data.STORIES) do if id ~= "soil" then ids[#ids + 1] = id end end
    for id in pairs(Data.REVISITS) do ids[#ids + 1] = id end
    ids[#ids + 1] = "observation_a"
    ids[#ids + 1] = "observation_b"
    ids[#ids + 1] = "soil_site"
    ids[#ids + 1] = "soil_plain"
    return ids
end

local function uiKeys()
    local P = "IGUI_OA_Story_"
    local list = {}
    local function add(k) list[#list + 1] = P .. k end
    for id in pairs(Data.PLACES) do add("Place_" .. id); add("PlaceNote_" .. id) end
    for _, id in ipairs(storyIds()) do add("Title_" .. id); add("Brief_" .. id) end
    for _, r in ipairs(Data.REGULAR) do add("RegTitle_" .. r.item); add("RegBrief_" .. r.item) end
    for _, c in ipairs(Data.CONTRACTS) do add("ConTitle_" .. c.id); add("ConBrief_" .. c.id) end
    for _, id in ipairs(Docs.all()) do
        add("DocTitle_" .. id)
        if id ~= "roster_page" and id ~= "status_table" then add("Doc_" .. id) end
    end
    add("Doc_soil_slip_plain")
    for _, stage in pairs(Data.STAGES) do
        for _, id in ipairs(stage.radio) do add("Radio_" .. id) end
        for _, id in ipairs(stage.notes) do add("Note_" .. id) end
    end
    for _, ms in pairs(Data.MILESTONES) do
        for _, id in ipairs(ms.radio) do add("Radio_" .. id) end
        for _, id in ipairs(ms.notes) do add("Note_" .. id) end
    end
    add("Radio_" .. Data.HANDOVER_RADIO)
    for _, id in ipairs({ "first", "first_late" }) do add("Radio_" .. id) end
    -- The radio copies' titles: the first contact and the handover have their own, the stages share one.
    add("Copy_Title"); add("Copy_Stage"); add("Copy_StageNamed"); add("Copy_first"); add("Copy_handover")
    -- The request copies a special request brings to the folder: the text of each, and the approvals.
    for _, ids in pairs(Data.REQUESTS) do
        for _, id in ipairs(ids) do add("Request_" .. id) end
    end
    add("Request_Title"); add("Request_Head"); add("Request_Approval_a"); add("Request_Approval_b")
    for _, id in ipairs({ "case_confirmed", "cooler_good", "cooler_warm", "cooler_bad", "serum" }) do add("Note_" .. id) end
    for m, pool in pairs(Data.AFTER) do
        for i = 1, pool.notes do add("Note_after" .. m .. "_" .. i) end
        for i = 1, pool.radio do add("Radio_after" .. m .. "_" .. i) end
        for i = 1, pool.questions do add("Question_after" .. m .. "_" .. i) end
    end
    for key, count in pairs(Data.BROADCAST_LINES) do
        for i = 1, count do add("Broadcast_" .. key .. "_" .. i) end
    end
    for _, g in ipairs({ "1", "2", "3", "4", "H" }) do add("Greeting_" .. g) end
    for cat in pairs(Data.REFUSALS) do add("Refuse_" .. cat .. "_start"); add("Refuse_" .. cat .. "_back") end
    add("Refuse_any_start"); add("Refuse_any_back")
    for i = 1, Sites.DATES do add("StakeDate_" .. i) end
    for id in pairs(Story.OLD_LABELS) do add("Form_" .. id) end
    for _, code in ipairs({ "none", "nodata", "excluded", "keep" }) do add("Status_" .. code) end
    return list
end

test("every id in the data has its text, in both languages", function()
    local ui = uiKeys()
    local items = {}
    local tips = {}
    for name in pairs(Data.ITEMS) do
        items[#items + 1] = "OperationAcorn." .. name
        tips[#tips + 1] = "Tooltip_OA_Story_" .. name
    end
    for _, lang in ipairs({ "EN", "KO" }) do
        need(lang, "IG_UI.json", ui)
        need(lang, "ItemName.json", items)
        need(lang, "Tooltip.json", tips)
    end
end)

test("the items script and the data name the same items", function()
    local text = readfile("OperationAcorn/42/media/scripts/OA_story.txt") or ""
    local scripted = {}
    for name in string.gmatch(text, "\n%s*item%s+(%w+)") do scripted[name] = true end
    for name in pairs(Data.ITEMS) do truthy(scripted[name], "script lacks " .. name) end
    for name in pairs(scripted) do truthy(Data.ITEMS[name], "data lacks " .. name) end
end)

test("the world's texts keep LORE's rules: no dates outside documents, no empty-slot wording, no rescue", function()
    local ko = keysOf("KO", "IG_UI.json")
    for key, value in pairs(ko) do
        local family = string.match(key, "^IGUI_OA_Story_(%a+)_")
        if family == "Radio" or family == "Note" or family == "Greeting" or family == "Broadcast" or family == "Refuse"
            or family == "Question" then
            eq(string.find(value, "%d+/%d+") == nil, true, key .. " has a calendar date")
            eq(string.find(value, "월") == nil, true, key .. " names a month")
        end
        eq(string.find(value, "공란", 1, true) == nil, true, key .. " says 공란")
        eq(string.find(value, "구조", 1, true) == nil, true, key .. " talks of rescue")
    end
end)

-- B42: the metagrid spans +-250 cells, the drawn map only some; zones are known only for loaded cells.
test("the sites' bounds are the drawn map's cells, found to the cell", function()
    local savedWorld = getWorld
    getWorld = function()
        return { getMetaGrid = function()
            return {
                getMinX = function() return -250 end, getMinY = function() return -250 end,
                getMaxX = function() return 250 end, getMaxY = function() return 250 end,
                getCellData = function(_, cx, cy) return (cx >= 3 and cx <= 21 and cy >= 5 and cy <= 9) or nil end,
                getZonesAt = function() return nil end,
            }
        end }
    end
    Sites.resetExtent()
    local b = Sites.bounds()
    eq(b.minX, 3 * 256); eq(b.maxX, 22 * 256 - 1)
    eq(b.minY, 5 * 256); eq(b.maxY, 10 * 256 - 1)
    getWorld = savedWorld
    Sites.resetExtent()
end)
