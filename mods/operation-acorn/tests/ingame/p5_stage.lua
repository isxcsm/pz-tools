-- P5 (PLAN 3·4단계): one stage's story mission from the start, its site and its stage. Set P5_STAGE (2 to 8; 3 takes
-- P5_OPTION "a" or "b", else "a"; 6 to 8 are the milestones after the fifth stage) before RUN. CHANGES THE RECORD (stage, active mission, the world's used sites): use a
-- throwaway save. Header setup: a character with a record, standing where the base is taken to be.
-- It starts the mission and puts the character 30 squares from the site (near enough for the stage and its keepers).
-- Wait a few seconds for the chunks, then RUN p5_stage_after.lua.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p5stage")
local record, player = P4T.record()
if not record then say("no record yet: wait for the first hello"); return end
local stage = P5_STAGE or 2

-- The story from nothing, then the stage reached (the earlier stages' scenes dropped as passed).
local s = OA.Missions.state(record)
if s.active then OA.Missions.finish(record, s.active, "lost") end
record.story, record.comms, record.missions = nil, nil, nil
OA.Missions.state(record).nextAt = 0
OA.Story.setAnchor(record, math.floor(player:getX()), math.floor(player:getY()), 0)
record.trade = record.trade or {}
record.trade.stage = 0
OA.Story.firstContact(record, false)
for n = 1, math.min(stage, 5) do P4T.setStage(record, n, 0) end
for k = 1, stage - 5 do P4T.setStage(record, 5, k) end
local m = P4T.takeMission(record, P5_OPTION or "a")
if not P4T.check(say, "a story mission started", m ~= nil and m.story ~= nil, m and m.story) then return end
local site = m.site
if not P4T.check(say, "it has a site", site ~= nil) then return end
say("story", m.story, "option", tostring(m.chosen), "facility", m.facility, "site", site.key, "at", site.x, site.y, site.z,
    "box", site.x1, site.y1, site.x2, site.y2, "ground", tostring(site.ground))
P4T.check(say, "a stage is planned", m.stage ~= nil, OA.Stage.defOf(m) and "def" or "no def")
for _, it in ipairs(m.items) do say("piece", it.key, it.type, "staged", tostring(it.staged), "placed", tostring(it.placed)) end
P5_MISSION = m.id
P4T.go(site.x - 30, site.y, 0)
say("teleported 30 squares west of the site; wait a few seconds, then RUN p5_stage_after.lua")
