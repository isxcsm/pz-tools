-- P10 survey: the meteor survey branch (Story/Survey on Story/Branches) end to end, one tree after the other, on
-- scratch records (the real one is left alone), and the drop sites' land.
--   1. a tree's capstone with every other node bought waits only for its fragment (Rules.blocked "sealed"): the branch
--      fires its call once with the notice "call received", the call waits in the comms tab, no zone yet;
--   2. the call played (Comms.played + Story.callPlayed) marks the zone: the site inside it, away from the middle, a
--      dim map circle in the survey colour that is not the way's lead; the fragment arriving (Upgrades.fragmentReceived)
--      takes the zone and the circle away, and the call is never fired again;
--   3. the handover variant: the team's call not played gives way to 관리 7's (C_<tree>_k), whose play marks the zone;
--   4. each drop site (Sites.list) stood at in the game (the character is sent there with god mode; the chunk loads
--      and the site is placed or moved): a loaded square with a floor, outside, no building, not water and no water
--      within 3, the API's open-ground conditions met, the fragment lying near; and the zone checks again on the
--      settled sites (a site that moved after the zone was published would move the circle).
-- Setup: a world with PZ Extension API, the character anywhere the sites are not (it goes there and back, ~1 min).
-- Changes nothing that stays: the scratch records go, the character comes back, the notice at the end is for you to see.
-- Prints "[p10survey]" lines, ending in "done: N BAD" (or "end: N BAD" under p10_all).
RUN("p10_lib.lua")
local OA = OperationAcorn

P10T.start("p10survey", function(a)
    local Survey, Branches, Comms, Sites = OA.StorySurvey, OA.StoryBranches, OA.Comms, OA.Sites
    local Rules, Data = OA.Upgrades.Rules, OA.Upgrades.Data
    if not a.check("the survey, branch and sites modules are loaded", Survey and Branches and Sites and OA.StoryView,
        tostring(Survey) .. " " .. tostring(Branches) .. " " .. tostring(Sites)) then return end
    local notices = P10T.capture(a, "notice")

    local list = Sites.list()
    a.check("three sites decided", #list == Sites.COUNT, #list)
    local first = {}
    for _, s in ipairs(list) do
        first[s.n] = { x = s.x, y = s.y, state = s.state }
        a.say("site", s.n, s.kind, "at", s.x, s.y, s.state, "tries", s.tries or 0)
    end

    -- A scratch record whose tree is bought but for the capstone, which waits for the fragment.
    local function prepare(tree)
        local r = P10T.scratch(a, "survey_" .. tree, 3, 0)
        local u = Rules.section(r)
        for _ = 1, 40 do Rules.inject(u, tree) end
        local progress = true
        while progress do
            progress = false
            for _, node in ipairs(Data.treeNodes(tree)) do
                if not node.capstone then
                    for _ = 1, node.ranks + 1 do
                        if Rules.blocked(u, node.id) ~= nil then break end
                        if not Rules.buy(u, node.id) then break end
                        progress = true
                    end
                end
            end
        end
        return r, u
    end

    -- the fragment reaching the team (the real call when the upgrades part is loaded)
    local function receive(r, treeId)
        if OA.Upgrades.fragmentReceived then return OA.Upgrades.fragmentReceived(r, Data.FRAGMENTS[treeId]) end
        return Rules.unseal(Rules.section(r), treeId)
    end

    local function played(r, id)
        Comms.played(r, id, 3)
        OA.Story.callPlayed(r, id)
    end

    -- The zone of a played call: the site inside it, away from the middle, a dim circle on the map.
    local function zoneChecks(tree, r, label)
        local site = Survey.siteOf(tree)
        local zones = Survey.zones(r)
        a.check(label .. " one zone after the call is played", #zones == 1, #zones)
        local z = zones[1]
        if not (z and site) then return end
        local d = OA.Places.distance(site.x, site.y, z.x, z.y)
        a.check(label .. " zone is of the tree", z.tree == tree and z.r == Survey.R, z.tree .. " r " .. tostring(z.r))
        a.check(label .. " the site is inside the zone", d < z.r, "d " .. string.format("%.1f", d) .. " r " .. z.r)
        a.check(label .. " the site is away from the middle", P10T.near(d, Survey.R * Survey.OFFSET, 1.5)
            and d > z.r * 0.25, string.format("%.1f", d))
        local again = Survey.zone(site)
        a.check(label .. " the same zone every time", again.x == z.x and again.y == z.y)
        local scene = OA.StoryView.scene(r, nil)
        local found
        for _, c in ipairs(scene.circles) do
            if c.color == OA.StoryView.MAP_SURVEY then found = c end
        end
        a.check(label .. " a dim survey circle on the map", found ~= nil and found.dim == true and found.r == z.r)
        a.check(label .. " the circle is not the way's lead", scene.lead == nil or scene.lead ~= found)
    end

    -- 1 to 3 for one tree.
    local function tree(treeId)
        local label = "[" .. treeId .. "]"
        local site = Survey.siteOf(treeId)
        a.check(label .. " the tree's drop site exists", site ~= nil, site and (site.kind .. " site " .. site.n) or "none")
        if not site then return end
        local idle = P10T.scratch(a, "survey_idle_" .. treeId, 3, 0)
        local before = #notices
        a.check(label .. " nothing waits: no call, no notice", #Branches.look(idle, "approved") == 0 and #notices == before)

        local r, u = prepare(treeId)
        local cap = Data.capstone(treeId)
        a.check(label .. " the capstone waits only for its fragment", Rules.blocked(u, cap.id) == "sealed",
            Rules.blocked(u, cap.id))
        before = #notices
        local fired = Branches.look(r, "approved")
        a.check(label .. " the branch fires " .. Survey.callOf(treeId, false), #fired == 1 and fired[1] == Survey.callOf(treeId, false),
            table.concat(fired, ","))
        a.check(label .. " the notice is told once", #notices == before + 1
            and notices[#notices].detail.key == "IGUI_OA_Story_Notice_BranchCall", P10T.keys(notices))
        a.check(label .. " the notice reads in the language", getText("IGUI_OA_Story_Notice_BranchCall") ~= "IGUI_OA_Story_Notice_BranchCall",
            getText("IGUI_OA_Story_Notice_BranchCall"))
        a.check(label .. " not fired twice", #Branches.look(r, "settled") == 0 and #notices == before + 1)
        local nextCall = Comms.next(r, "terminal")
        a.check(label .. " the call waits in the terminal's comms", nextCall ~= nil and nextCall.id == Survey.callOf(treeId, false),
            nextCall and nextCall.id)
        a.check(label .. " no zone before the call is heard", #Survey.zones(r) == 0)
        Comms.enterTier(r, 8, OA.hours())
        a.check(label .. " a tier entered drops no branch call", Comms.ready(r, Survey.callOf(treeId, false)))

        played(r, Survey.callOf(treeId, false))
        zoneChecks(treeId, r, label)
        -- the fragment reaches the team
        a.check(label .. " the fragment opens the capstone", receive(r, treeId) == true)
        a.check(label .. " the zone is gone", #Survey.zones(r) == 0)
        local scene = OA.StoryView.scene(r, nil)
        local left = 0
        for _, c in ipairs(scene.circles) do if c.color == OA.StoryView.MAP_SURVEY then left = left + 1 end end
        a.check(label .. " the circle is gone from the map", left == 0, left)
        a.check(label .. " the capstone can be bought now", Rules.blocked(u, cap.id) ~= "sealed", Rules.blocked(u, cap.id))
        a.check(label .. " never fired again", #Branches.look(r, "approved") == 0)

        -- a fragment that comes first drops the call not yet played
        local early, eu = prepare(treeId)
        Branches.look(early, "approved")
        Rules.unseal(eu, treeId)
        Branches.look(early, "settled")
        a.check(label .. " a fragment first drops the call not played", Comms.done(early, Survey.callOf(treeId, false))
            and Comms.next(early, "terminal") == nil)

        -- the handover variant
        local h = prepare(treeId)
        Branches.look(h, "approved")
        OA.Story.section(h).handover = true
        local firedK = Branches.look(h, "approved")
        a.check(label .. " after the handover Admin 7 calls (" .. Survey.callOf(treeId, true) .. ")", #firedK == 1
            and firedK[1] == Survey.callOf(treeId, true), table.concat(firedK, ","))
        a.check(label .. " the team's call gives way", Comms.done(h, Survey.callOf(treeId, false)))
        played(h, Survey.callOf(treeId, true))
        zoneChecks(treeId, h, label .. " handover")
        a.check(label .. " handover: the fragment takes the zone away", receive(h, treeId)
            and #Survey.zones(h) == 0)
        -- played before the handover: no second call after it
        local s = prepare(treeId)
        Branches.look(s, "approved")
        played(s, Survey.callOf(treeId, false))
        OA.Story.section(s).handover = true
        a.check(label .. " played before the handover: no second call", #Branches.look(s, "approved") == 0)
        -- the zone stays on the record when its character dies
        OA.Store.retire(s)
        a.check(label .. " the zone stays with a retired record", #Survey.zones(s) == 1)
    end

    for _, id in ipairs(Data.TREES) do tree(id) end

    -- 4. the drop sites in the game.
    local ox, oy, oz = P10T.where()
    P10T.god(a)
    a.cleanup(function() P10T.tp(ox, oy, oz) end)
    local at = {}
    local steps = {}
    for _, site in ipairs(list) do
        local n = site.n
        steps[#steps + 1] = { after = 300, name = "go " .. n, run = function()
            local s = Sites.byNumber(n)
            at[n] = { x = s.x, y = s.y }
            P10T.tp(s.x, s.y, 0)
        end }
        steps[#steps + 1] = { after = 1500, name = "look " .. n, within = 40000,
            ready = function()
                local s = Sites.byNumber(n)
                if not s then return true end
                -- the site moved while its chunk loaded: go to the new place
                if s.state == "pending" and (s.x ~= at[n].x or s.y ~= at[n].y) then
                    at[n].x, at[n].y = s.x, s.y
                    P10T.tp(s.x, s.y, 0)
                end
                return s.state ~= "pending" and getCell():getGridSquare(s.x, s.y, 0) ~= nil
            end,
            run = function(_, timedOut)
                local s = Sites.byNumber(n)
                local label = "site " .. n .. " (" .. tostring(s.kind) .. ")"
                a.check(label .. " placed", s.state == "placed" and not timedOut, s.state .. (timedOut and " timed out" or ""))
                local was = first[n]
                -- (decided from the map's data, it settles on a fitting square of its chunk as the chunk loads: Sites.onChunk)
                local size = OA.Chunks.SIZE
                a.check(label .. " stayed in the chunk it was decided in",
                    math.floor(was.x / size) == math.floor(s.x / size) and math.floor(was.y / size) == math.floor(s.y / size),
                    was.x .. "," .. was.y .. " -> " .. s.x .. "," .. s.y .. " (the zone follows the site)")
                local sq = getCell():getGridSquare(s.x, s.y, 0)
                if not a.check(label .. " its square is loaded", sq ~= nil, s.x .. "," .. s.y) then return end
                a.check(label .. " has a floor", sq:getFloor() ~= nil)
                a.check(label .. " is outside", sq:isOutside())
                a.check(label .. " is no building", sq:getBuilding() == nil)
                a.check(label .. " is not water", not sq:isWaterSquare() and not sq:getProperties():has(IsoFlagType.water))
                local water = 0
                for dx = -3, 3 do
                    for dy = -3, 3 do
                        local q = getCell():getGridSquare(s.x + dx, s.y + dy, 0)
                        if q and (q:isWaterSquare() or q:getProperties():has(IsoFlagType.water)) then water = water + 1 end
                    end
                end
                a.check(label .. " has no water within 3 squares", water == 0, water)
                local api = OA.api()
                local land = OA.StoryGame.groundWith({ free = true, solidFloor = true, tree = false, zonesNot = Sites.NOT })
                local ok, found = pcall(api.squares.list, { list = { s.x, s.y, 0 } }, land)
                a.check(label .. " meets the API's land conditions", ok and type(found) == "table" and #found == 1,
                    ok and (type(found) == "table" and #found or tostring(found)) or tostring(found))
                local want = OA.StoryData.fullType(Sites.FRAGMENT[s.kind])
                local fragments = 0
                for x = s.x - 12, s.x + 12 do
                    for y = s.y - 12, s.y + 12 do
                        local q = getCell():getGridSquare(x, y, 0)
                        if q then
                            local wi = q:getWorldObjects()
                            for i = 0, wi:size() - 1 do
                                local item = wi:get(i):getItem()
                                if item and item:getFullType() == want then fragments = fragments + 1 end
                            end
                        end
                    end
                end
                a.check(label .. " its fragment lies near", fragments >= 1, fragments)
            end }
    end
    steps[#steps + 1] = { after = 300, name = "back", run = function() P10T.tp(ox, oy, oz) end }
    steps[#steps + 1] = { after = 1000, name = "settled", within = 15000,
        ready = function() return getCell():getGridSquare(ox, oy, oz) ~= nil end,
        run = function()
            -- the zone checks again on the settled sites
            for _, id in ipairs(Data.TREES) do
                if Survey.siteOf(id) then
                    local r = prepare(id)
                    Branches.look(r, "approved")
                    played(r, Survey.callOf(id, false))
                    zoneChecks(id, r, "[" .. id .. "] settled")
                end
            end
            -- for you to see: the notice as the player gets it
            local real = P10T.record()
            if real then OA.Sync.notice(real.id, "IGUI_OA_Story_Notice_BranchCall", {}) end
            a.say("for you to look at: the notice over the character reads", getText("IGUI_OA_Story_Notice_BranchCall"))
        end }
    P10T.run(a, steps)
end)
