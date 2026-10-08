-- P4: the meteor drop sites. Prints the count, the spacing, the states; then teleports to the first site that is not
-- placed yet (its chunk loads there), and on the second run scans the squares around a placed one for the stake and
-- the numbered fragments. Header setup: a world started with the mod (the sites are decided at the first world start).
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4sites")
local list = OA.Sites.list()
P4T.check(say, "all sites decided", #list == OA.Sites.count(), #list)
local worst = 99999
for i = 1, #list do
    for j = i + 1, #list do
        local d = OA.Places.distance(list[i].x, list[i].y, list[j].x, list[j].y)
        if d < worst then worst = d end
    end
end
P4T.check(say, "spacing kept", worst >= (OA.Store.world("sites").spacing or 300) - 1, worst)
local placed, pending, failed = 0, 0, 0
for _, s in ipairs(list) do
    if s.state == "placed" then placed = placed + 1 elseif s.state == "failed" then failed = failed + 1 else pending = pending + 1 end
end
say("placed", placed, "pending", pending, "failed", failed)
local target
for _, s in ipairs(list) do if s.state == "placed" then target = s; break end end
if not target then
    target = list[1]
    P4T.go(target.x, target.y, 0)
    say("went to site", target.n, "at", target.x, target.y, "; wait for its chunk and run again")
    return
end
say("site", target.n, "stake", target.stake, "date", target.date, "at", target.x, target.y)
local seen = {}
local cell = getCell()
for x = target.x - 12, target.x + 12 do
    for y = target.y - 12, target.y + 12 do
        local sq = cell:getGridSquare(x, y, 0)
        if sq then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                local md = o:hasModData() and o:getModData()
                if md and (md.OA_Site or md.OA_StakeNo) then seen[#seen + 1] = "object stake " .. tostring(md.OA_StakeNo) .. " site " .. tostring(md.OA_Site) end
            end
            local wi = sq:getWorldObjects()
            for i = 0, wi:size() - 1 do
                local item = wi:get(i):getItem()
                if item and item:getFullType() == "OperationAcorn.MeteorFragment" then
                    seen[#seen + 1] = "fragment " .. tostring(item:getModData().OA_Stake) .. " " .. item:getName()
                end
            end
        end
    end
end
for _, line in ipairs(seen) do say(line) end
P4T.check(say, "the stake with the site number is there", #seen > 0)
say("look at the ground: scorched tiles, rocks, the stake; the fragments carry the stake number in their name")
