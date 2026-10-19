-- P11: the 7/3 truck (revisit_wreck, the 7th milestone after the handover) from the start: its site on open ground,
-- its stage (the wreck made by the API's vehicles.damage, the log in the glove box). CHANGES THE RECORD (story reset,
-- handover done, milestones 7, active mission): use a throwaway save. Puts the character 30 squares from the site;
-- wait a few seconds for the chunks, then RUN p11_wreck_after.lua.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p11wreck")
local record, player = P4T.record()
if not record then say("no record yet: wait for the first hello"); return end
local api = OA.api()
P4T.check(say, "the API has vehicles.damage", api and api.vehicles and api.vehicles.damage ~= nil)

local s = OA.Missions.state(record)
if s.active then OA.Missions.finish(record, s.active, "lost") end
record.story, record.comms, record.missions = nil, nil, nil
OA.Missions.state(record).nextAt = 0
OA.Story.setAnchor(record, math.floor(player:getX()), math.floor(player:getY()), 0)
record.trade = record.trade or {}
record.trade.stage = 0
OA.Story.firstContact(record, false)
for n = 1, 5 do P4T.setStage(record, n, 0) end
for k = 1, 3 do P4T.setStage(record, 5, k) end
OA.Story.missionEnded(record, { story = "handover" }, "done")
local story = OA.Story.section(record)
P4T.check(say, "handed over", OA.Story.handedOver(record))
local left = {}
for _, q in ipairs(story.queue) do left[#left + 1] = q.id end
P4T.check(say, "no 2반 story left after the handover", #left == 0, table.concat(left, ","))
OA.Story.world().shared.revisit_wreck = nil   -- a new site each run (the test asks where it goes)
for k = 4, 7 do P4T.setStage(record, 5, k) end
-- only the truck: the other revisits are the unit tests' (each once, in order)
local keep = {}
for _, q in ipairs(story.queue) do if q.id == "revisit_wreck" then keep[1] = q end end
story.queue = keep
local m = P4T.takeMission(record)
if not P4T.check(say, "the truck's mission started", m ~= nil and m.story == "revisit_wreck", m and m.story) then return end
local site = m.site
if not P4T.check(say, "it has a site on open ground", site ~= nil and site.ground == true) then return end
say("site", site.key, "at", site.x, site.y, site.z, "facility", m.facility)
P4T.check(say, "the world keeps the site (one truck per world)", OA.Story.world().shared.revisit_wreck == site)
for _, it in ipairs(m.items) do say("piece", it.key, it.type, "staged", tostring(it.staged), "placed", tostring(it.placed)) end
P5_MISSION = m.id
P4T.go(site.x - 30, site.y, 0)
say("teleported 30 squares west of the site; wait a few seconds, then RUN p11_wreck_after.lua")
