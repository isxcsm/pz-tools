-- Drop sites round the start, documents, the overlay's arithmetic, the compass, and the texts the data names.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Docs"
require "OperationAcorn/Story/Sites"
require "OperationAcorn/Story/Glow"
require "OperationAcorn/Economy/Categories"
local OA = OperationAcorn
local Data, Story, Docs, Sites = OA.StoryData, OA.Story, OA.StoryDocs, OA.Sites

local ORIGIN = { x = 8000, y = 7000 }
local function yes() return true end

-- An empty sites section and no work waiting for chunks.
local function clearSites()
    local sec = OA.Store.world("sites")
    for k in pairs(sec) do sec[k] = nil end
    OA.Chunks.remove(function() return true end)
end

test("the sites are laid out once round the start, one of each kind, each with its own stake and date", function()
    clearSites()
    eq(Sites.ensure(nil, yes), nil, "no start yet")
    eq(#Sites.list(), 0)
    local list = Sites.ensure(ORIGIN, yes)
    eq(#list, Sites.COUNT)
    eq(Sites.ensure({ x = 100, y = 100 }, yes), list, "once")
    local kinds, stakes, dates = {}, {}, {}
    for i, a in ipairs(list) do
        eq(a.n, i)
        eq(a.state, "pending")
        truthy(Sites.FRAGMENT[a.kind], a.kind)
        eq(kinds[a.kind], nil, "kinds differ")
        kinds[a.kind] = true
        eq(stakes[a.stake], nil, "stake numbers differ")
        stakes[a.stake] = true
        truthy(a.date >= 1 and a.date <= Sites.DATES)
        eq(dates[a.date], nil, "dates differ")
        dates[a.date] = true
        local d = OA.Places.distance(ORIGIN.x, ORIGIN.y, a.x, a.y)
        truthy(d >= Sites.RING_LO - 1 and d <= Sites.RING_HI + 1, "in the ring: " .. d)
        for j = i + 1, #list do
            truthy(OA.Places.distance(a.x, a.y, list[j].x, list[j].y) >= Sites.SPACING - 1, "spaced")
        end
    end
    eq(#OA.Chunks.list("oa_site"), Sites.COUNT, "each waits for its chunk")
    eq(Sites.byNumber(3), list[3])
    eq(Sites.byNumber(99), nil)
end)

test("a site that is not land is moved within the ring, and gives up after a number of tries", function()
    clearSites()
    local list = Sites.ensure(ORIGIN, yes)
    local site = list[1]
    local ox, oy = site.x, site.y
    truthy(Sites.replace(site, yes))
    truthy(site.x ~= ox or site.y ~= oy, "a new place")
    local d = OA.Places.distance(ORIGIN.x, ORIGIN.y, site.x, site.y)
    truthy(d >= Sites.RING_LO - 1 and d <= Sites.RING_HI + 1, "still in the ring: " .. d)
    for k = 2, 3 do
        truthy(OA.Places.distance(site.x, site.y, list[k].x, list[k].y) >= Sites.SPACING - 1, "apart from the others")
    end
    for _ = 1, Sites.MAX_RETRIES do Sites.replace(site, yes) end
    eq(Sites.replace(site, yes), false)
    eq(site.state, "failed")
end)

-- A site's chunk loads and nothing in it fits: the fit is asked of the chunk's squares, the middle and its neighbours on
-- land and the whole scorched footprint on open ground (a lake is not under it), and the site moves on.
test("a site fits its scorched footprint on open ground in its chunk, and moves when nothing fits", function()
    clearSites()
    local list = Sites.ensure(ORIGIN, yes)
    local site = list[2]
    site.kind = "iron"
    local fit
    PZExtAPI = { version = OA.API_VERSION, client = function() return {} end,
        squares = { fit = function(anchors, parts, options) fit = { anchors = anchors, parts = parts, options = options } end },
        zones = { points = function(x, y, lo, hi) return { { x = x + lo + 1, y = y, zones = {} } } end } }
    getWorld = function() return { getMetaGrid = function() return { getCellData = function() return {} end } end } end
    local entry = { kind = "oa_site", site = 2, x = site.x, y = site.y, z = 0 }
    local x1, y1 = math.floor(site.x / 8) * 8, math.floor(site.y / 8) * 8
    eq(Sites.onChunk(entry, nil), true)
    eq(fit.anchors.x1, x1); eq(fit.anchors.y2, y1 + 7); eq(fit.anchors.z, 0)
    eq(fit.options.order, "random")
    local middle, scorched = fit.parts[1], fit.parts[2]
    eq(#middle.offsets, 6, "the middle and the squares east and south of it")
    eq(middle.filter.free, true); eq(middle.filter.tree, false); eq(middle.filter.building, "none")
    eq(middle.filter.zonesNot, Sites.NOT)
    eq(#scorched.offsets, 2 * Sites.SCORCH.iron)
    eq(scorched.filter.wet, false); eq(scorched.filter.natural, true); eq(scorched.filter.outside, true)
    truthy(scorched.filter == OA.StoryGame.GROUND, "the camp's ground")
    eq(site.state, "pending", "not placed")
    truthy(site.tries >= 1, "moved on")
    getWorld, PZExtAPI = nil, nil
end)

test("a player near a site has seen it", function()
    clearSites()
    local list = Sites.ensure(ORIGIN, yes)
    list[2].state = "placed"
    local record = OA.Store.ensure("p1", "P")
    local told = {}
    OA.Sync.listen("title", function(id, detail) told[#told + 1] = detail end)
    eq(Sites.visit(record, list[2].x + 200, list[2].y), false)
    eq(#told, 0)
    truthy(Sites.visit(record, list[2].x + 20, list[2].y))
    eq(Sites.seenOf(record)[2], true)
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
    list = Docs.forItem(record, "EvidenceEnvelope", { OA_Variant = "police" })
    eq(list[1].variant, "police")
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
    local text = Docs.body(record, "police_card", "police")
    truthy(string.find(text, "0347", 1, true))
    truthy(string.find(text, "IGUI_OA_Story_Facility_police", 1, true))
    truthy(string.find(text, "IGUI_OA_Story_FacilityNote_police", 1, true))
    eq(string.find(Docs.body(record, "police_card", "muldraugh_pd"), "Facility", 1, true), nil, "no name for an unknown one")
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
    local page = Docs.body(record, "roster_page", "shelter")
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
    for _, id in ipairs(Data.FACILITIES) do add("Facility_" .. id); add("FacilityNote_" .. id) end
    for _, id in ipairs(storyIds()) do add("Title_" .. id); add("Brief_" .. id) end
    for _, r in ipairs(Data.REGULAR) do
        -- (the comparison is told in the contract's words)
        if r.id ~= "compare" then add("RegTitle_" .. (r.id or r.item)); add("RegBrief_" .. (r.id or r.item)) end
    end
    for _, e in ipairs(Data.SPECIALS) do add("SpecialTitle_" .. e.id) end
    for _, c in ipairs(Data.CONTRACTS) do add("ConTitle_" .. c.id); add("ConBrief_" .. c.id) end
    for _, id in ipairs(Docs.all()) do
        add("DocTitle_" .. id)
        if id ~= "roster_page" and id ~= "status_table" then add("Doc_" .. id) end
    end
    add("Doc_soil_slip_plain")
    for _, stage in pairs(Data.STAGES) do
        for _, id in ipairs(stage.notes) do add("Note_" .. id) end
    end
    for _, ms in pairs(Data.MILESTONES) do
        for _, id in ipairs(ms.notes) do add("Note_" .. id) end
    end
    -- The trust tier in words (Story.tierText).
    add("Copy_Stage"); add("Copy_StageNamed")
    -- The request copies a special request brings to the folder: the text of each, and the approvals.
    for _, ids in pairs(Data.REQUESTS) do
        for _, id in ipairs(ids) do add("Request_" .. id) end
    end
    add("Request_Title"); add("Request_Head"); add("Request_Approval_a"); add("Request_Approval_b")
    -- The stake record and where a delivered paper's copy came from, the one-off remark of a new region, and the filler
    -- remarks (the bundles Story.fillNoteKey draws from, by their number of lines).
    add("DocTitle_stake_log"); add("StakeLog_Line"); add("Meta_stakes"); add("Meta_copy"); add("Note_region")
    for id, n in pairs({ s1 = 5, s2 = 5, s3 = 5, s4 = 5, s5 = 5, m = 4, a = 4, partial = 4, serum = 2 }) do
        for i = 1, n do add("Fill_" .. id .. "_" .. i) end
    end
    for _, id in ipairs({ "case_confirmed", "cooler_good", "cooler_warm", "cooler_bad", "serum" }) do add("Note_" .. id) end
    -- What the team makes of a delivered revisit or soil sample (Missions.answer).
    for _, def in pairs(Data.REVISITS) do if def.note then add("Note_" .. def.note) end end
    -- The remarks on the last flight's boxes (Story.tookFacts).
    for _, id in ipairs({ "cash", "refused", "low", "many" }) do add("Took_" .. id) end
    for _, letter in ipairs(OA.Categories.LETTERS) do add("Took_cat_" .. letter) end
    for m, pool in pairs(Data.AFTER) do
        for i = 1, pool.notes do add("Note_after" .. m .. "_" .. i) end
    end
    for _, g in ipairs({ "1", "2", "3", "4" }) do add("Greeting_" .. g) end
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

test("the filler bundles have no line past the last one the data counts, in either language", function()
    for _, lang in ipairs({ "EN", "KO" }) do
        local keys = keysOf(lang, "IG_UI.json")
        for id, n in pairs({ s1 = 5, s2 = 5, s3 = 5, s4 = 5, s5 = 5, m = 4, a = 4, partial = 4, serum = 2 }) do
            truthy(keys["IGUI_OA_Story_Fill_" .. id .. "_" .. n], lang .. " has the last line of " .. id)
            eq(keys["IGUI_OA_Story_Fill_" .. id .. "_" .. (n + 1)], nil, lang .. " has no line after it")
        end
    end
end)

test("a remark of the ordered pools that says something is enclosed has its items in the data, and no other has", function()
    local en = keysOf("EN", "IG_UI.json")
    -- the list and appendix remarks name papers that are in the crate by the papers' own way, the last_a one is general
    local papers = { m1_a = true, m2_a = true, late_appendix = true, last_a = true }
    for key, value in pairs(en) do
        local id = string.match(key, "^IGUI_OA_Story_Note_(.+)$")
        if id then
            local says = string.find(value, "enclosed", 1, true) and not string.find(value, "not enclosed", 1, true)
            if says and not papers[id] then truthy(Data.NOTE_ITEMS[id], id .. " says enclosed and has no items") end
            if Data.NOTE_ITEMS[id] then truthy(says, id .. " has items and does not say so") end
        end
    end
end)

test("a document that carries its own paper (OA_Doc with OA_Only) shows that one alone, with the place", function()
    local record = OA.Store.ensure("p1", "P")
    local list = Docs.forItem(record, "PharmacyLedger", { OA_Doc = "revisit_ledger", OA_Only = true, OA_Variant = "medical" })
    eq(#list, 1)
    eq(list[1].id, "revisit_ledger")
    eq(list[1].variant, "medical")
    list = Docs.forItem(record, "PharmacyLedger", { OA_Variant = "medical" })
    eq(list[1].id, "con_ledger", "the contract's item still has its own")
    list = Docs.forItem(record, "SerumSheet", { OA_Doc = "serum_sheet" })
    eq(#list, 1, "a supply item that names its paper is not shown twice")
    eq(Docs.forItem(record, "HandoverPages", { OA_Variant = "army" })[1].id, "handover_pages")
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
