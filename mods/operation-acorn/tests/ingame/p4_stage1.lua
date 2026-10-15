-- P4: stage 1 from the start (PLAN 2단계): the first call waiting, the evidence mission at a temporary police post
-- picked in the band, and its stage. CHANGES THE RECORD (stage, active mission, the world's used sites): use a
-- throwaway save. Header setup: a character with a record, standing where the terminal would be (the base is taken to
-- be here).
-- It starts the mission and puts the character 30 squares from the site (near enough for the stage and its keepers).
-- Wait a few seconds for the chunks, then RUN p4_stage1_after.lua. P4S_PICKUP() then takes the envelope as a pickup
-- does (the hall's officer gets up), P4S_WOKE() a few seconds later says whether it did.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4stage1")
local record, player = P4T.record()
if not record then say("no record yet: wait for the first hello"); return end

local s = OA.Missions.state(record)
if s.active then OA.Missions.finish(record, s.active, "lost") end
s.nextAt = 0
OA.Story.setAnchor(record, math.floor(player:getX()), math.floor(player:getY()), 0)
P4T.setStage(record, 1, 0)
OA.Story.firstContact(record, false)
local comms = OA.Comms.section(record)
P4T.check(say, "the first call waits for the terminal", comms.fired.S0 ~= nil and not comms.played.S0)
OA.Missions.tick(record)
local m = OA.Missions.active(record)
if not P4T.check(say, "the evidence mission started", m ~= nil and m.story == "evidence", m and m.story) then return end
local site = m.site
if not P4T.check(say, "it has a site", site ~= nil) then return end
say("site", site.key, "at", site.x, site.y, site.z, "box", site.x1, site.y1, site.x2, site.y2, "ground", tostring(site.ground))
P4T.check(say, "the facility is the police post", m.facility == "police", m.facility)
P4T.check(say, "a building, not open ground", not site.ground)
local lo, hi = OA.Rewards.band(m.level)
local d = OA.Places.distance(site.x, site.y, player:getX(), player:getY())
P4T.check(say, "in the band of level " .. m.level, d >= lo and d <= hi, math.floor(d) .. " in " .. lo .. "-" .. hi)
P4T.check(say, "the site is used for the world", OA.Story.world().used[site.key] == true)
P4T.check(say, "a stage is planned", m.stage ~= nil)
P4T.check(say, "the envelope waits for the stage", m.items[1].staged == true)
P4T.go(site.x - 30, site.y, 0)
say("teleported 30 squares west of the site; wait a few seconds, then RUN p4_stage1_after.lua")
