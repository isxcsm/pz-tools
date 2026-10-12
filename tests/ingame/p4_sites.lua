-- P4: the meteor drop sites round the first character's start. Prints the ring, the spacing, the kinds and the states;
-- then teleports to the first site that is not placed yet (its chunk loads there), and on the second run scans the
-- squares around a placed one for the stake and the fragment of its kind. Header setup: a world started with the mod
-- (the sites are laid out once the first character stands in the world).
RUN("p4_lib.lua")
local OA = OperationAcorn
local Sites = OA.Sites
local say = P4T.say("p4sites")
local list = Sites.list()
local sec = OA.Store.world("sites")
P4T.check(say, "all sites decided", #list == Sites.COUNT, #list)
local origin = sec.origin or { x = 0, y = 0 }
say("around", origin.x, origin.y, "generation", Sites.generation())
local worst, kinds = 99999, {}
for i = 1, #list do
    local d = OA.Places.distance(origin.x, origin.y, list[i].x, list[i].y)
    say("site", list[i].n, list[i].kind, "at", list[i].x, list[i].y, "distance", math.floor(d), list[i].state)
    kinds[list[i].kind or "?"] = true
    for j = i + 1, #list do
        local dd = OA.Places.distance(list[i].x, list[i].y, list[j].x, list[j].y)
        if dd < worst then worst = dd end
    end
end
P4T.check(say, "one of each kind", kinds.stony and kinds.iron and kinds.stonyIron)
P4T.check(say, "spacing kept", worst >= Sites.SPACING / 3 - 1, worst)
local target
for _, s in ipairs(list) do if s.state == "placed" then target = s; break end end
if not target then
    for _, s in ipairs(list) do if s.state == "pending" then target = s; break end end
    if not target then say("no site to visit") return end
    P4T.go(target.x, target.y, 0)
    say("went to site", target.n, "at", target.x, target.y, "; wait for its chunk and run again")
    return
end
say("site", target.n, target.kind, "stake", target.stake, "date", target.date, "at", target.x, target.y)
local want = OA.StoryData.fullType(Sites.FRAGMENT[target.kind])
local stakes, fragments = 0, 0
local cell = getCell()
for x = target.x - 12, target.x + 12 do
    for y = target.y - 12, target.y + 12 do
        local sq = cell:getGridSquare(x, y, 0)
        if sq then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                local md = o:hasModData() and o:getModData()
                if md and md.OA_StakeNo then
                    stakes = stakes + 1
                    say("stake", md.OA_StakeNo, "site", md.OA_Site)
                end
            end
            local wi = sq:getWorldObjects()
            for i = 0, wi:size() - 1 do
                local item = wi:get(i):getItem()
                if item and item:getFullType() == want then
                    fragments = fragments + 1
                    say("fragment", item:getName())
                end
            end
        end
    end
end
P4T.check(say, "the stake is there", stakes > 0, stakes)
P4T.check(say, "one fragment of the site's kind", fragments == 1, fragments)
say("look at the ground: scorched tiles, rocks, the stake, the fragment")
