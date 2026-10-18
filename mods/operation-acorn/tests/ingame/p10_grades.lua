-- P10 grades: how the team names the collection point (Story.grade, designation, address, the stamps Story.onStage
-- sends), on scratch records (the real one is left alone).
--   1. before the handover: tier 1 the full name ("Collection point 0347"), later tiers the bare number in the calls,
--      the terminal's title keeping the full name; a character that came after the handover starts as a new point;
--   2. after the handover, the tiers 8, 10, 11, 12, 13, 14, 16, 17 and 18: the grade (handed, regular, designated, priority,
--      priority, special, top, top, top), the designation with the count past the top grade (redesignated 1 and 2
--      times, no decimal point in the count), the address (never the count), the terminal's title;
--   3. the stamps seen (OA.Sync.title is wrapped for the scratch record): none for the first grade, one "regraded" for
--      each new grade (style stamp, the grade under it, the point's number), none for a tier that changes no grade or a
--      second call at the same tier, "redesignated" with the count at each level past the top.
-- Setup: none (the translations are the game's). Changes nothing that stays.
-- With P10_SHOW_GRADES = true set first, the stamps captured are shown to you afterwards, queued as they came (about
-- 12 s each: to look at the order and the text).
-- Prints "[p10grades]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

P10T.start("p10grades", function(a)
    local Story = OA.Story
    local titles = P10T.capture(a, "title")

    local function noDecimal(text) return string.find(text, "%d%.%d") == nil end

    -- 1. before the handover
    local r = P10T.scratch(a, "grade_before", 1, 0)
    r.number = 347
    local num = Story.number(r)
    a.check("the number is four digits", num == "0347", num)
    a.check("tier 1: no grade", Story.grade(r) == nil)
    local full = getText("IGUI_OA_Story_Grade_none", num)
    a.check("tier 1: the full name", Story.designation(r) == full and Story.address(r) == full, Story.address(r))
    a.check("the full name reads", full ~= "IGUI_OA_Story_Grade_none" and string.find(full, num, 1, true) ~= nil, full)
    r.trade.stage = 3
    a.check("tier 3: the calls say the bare number", Story.address(r) == num, Story.address(r))
    a.check("tier 3: the terminal keeps the full name", Story.designation(r, true) == full, Story.designation(r, true))
    local late = P10T.scratch(a, "grade_late", 2, 0)
    late.number = 512
    Story.section(late).joined = { tier = 9, handover = true }
    a.check("a character that came after the handover starts as a new point", Story.grade(late) == "new"
        and Story.designation(late) == getText("IGUI_OA_Story_Grade_new", Story.number(late)), tostring(Story.grade(late)))

    -- 2 and 3. after the handover
    local g = P10T.scratch(a, "grade_after", 5, 3)
    g.number = 347
    local s = Story.section(g)
    -- (stages and milestones counted as seen, so that only the grades are looked at)
    s.seenStage = 5
    s.handover = true
    local steps = {
        { 8, "handed", false }, { 10, "regular", true }, { 11, "designated", true }, { 12, "priority", true },
        { 13, "priority", false }, { 14, "special", true }, { 16, "top", true }, { 17, "top", false }, { 18, "top", false },
    }
    local seen = 0
    for _, step in ipairs(steps) do
        local tier, grade, stamps = step[1], step[2], step[3]
        g.trade.stage, g.trade.milestones = 5, tier - 5
        s.seenMilestones = tier - 5
        local label = "tier " .. tier
        local before = #titles
        Story.onStage(g)
        Story.onStage(g)
        a.check(label .. ": the tier", OA.Trust.tier(g) == tier and Story.tier(g) == tier, Story.tier(g))
        a.check(label .. ": grade " .. grade, Story.grade(g) == grade, tostring(Story.grade(g)))
        local again = tier > 16 and tier - 16 or 0
        a.check(label .. ": " .. again .. " redesignations", Story.redesignations(g) == again, Story.redesignations(g))
        local name = getText("IGUI_OA_Story_Grade_" .. grade, num)
        local expectFull = again > 0 and getText("IGUI_OA_Story_GradeAgain", name, again) or name
        local designation = Story.designation(g, true)
        a.check(label .. ": designation " .. designation, designation == expectFull and noDecimal(designation)
            and designation ~= "IGUI_OA_Story_Grade_" .. grade, designation)
        a.check(label .. ": the address is the grade without the count", Story.address(g) == name, Story.address(g))
        local title = getText("IGUI_OA_Terminal_Title", designation)
        a.check(label .. ": the terminal's title carries it", string.find(title, designation, 1, true) ~= nil, title)
        -- the stamps: one at most for this tier, however often onStage ran
        local fresh = #titles - before
        if tier == 8 then
            a.check(label .. ": the first grade is not stamped", fresh == 0, P10T.keys(titles))
        elseif tier > 16 then
            local t = titles[#titles]
            a.check(label .. ": one redesignation stamp with the count", fresh == 1 and t.detail.key == "IGUI_OA_Title_GradeAgain"
                and t.detail.style == "stamp" and t.detail.subArgs[2] == again and t.detail.subArgs[1].key == "IGUI_OA_Story_Grade_top"
                and t.detail.subArgs[1].args[1] == num and t.detail.sub == "IGUI_OA_Story_GradeAgain",
                fresh .. " " .. P10T.keys(titles))
        elseif stamps then
            local t = titles[#titles]
            a.check(label .. ": one regrade stamp", fresh == 1 and t.detail.key == "IGUI_OA_Title_Grade" and t.detail.style == "stamp"
                and t.detail.sub == "IGUI_OA_Story_Grade_" .. grade and t.detail.subArgs[1] == num, fresh .. " " .. P10T.keys(titles))
        else
            a.check(label .. ": a tier that changes no grade stamps nothing", fresh == 0, fresh)
        end
        seen = seen + fresh
    end
    a.say("stamps seen in all", seen, "(regrade x5, redesignate x2 expected: 7)")
    a.check("seven stamps in all", seen == 7, seen)

    -- the stamps' texts as the player reads them
    for _, t in ipairs(titles) do
        local d = t.detail
        local sub = d.sub
        local subArgs = {}
        for i, arg in ipairs(d.subArgs or {}) do
            subArgs[i] = type(arg) == "table" and getText(arg.key, unpack(arg.args or {})) or arg
        end
        a.say("stamp:", getText(d.key), "|", getText(sub, unpack(subArgs)))
    end

    if P10_SHOW_GRADES then
        local real = P10T.record()
        if real then
            for _, t in ipairs(titles) do OA.Titles.show(real.id, t.detail) end
            a.say("the stamps are shown to you now, in the order they came")
        end
    end
end)
