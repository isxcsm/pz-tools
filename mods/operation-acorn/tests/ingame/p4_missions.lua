-- P4: starts the story mission of a stage, walks to its place, and checks the item is put there once, with its tag.
-- CHANGES THE RECORD (stage, active mission): use a throwaway save. Header setup: a character with a record.
-- The base is taken to be where the character stands now (Story.setAnchor), so stand where the terminal would be.
-- Usage: set STAGE before RUN (1 evidence, 2 clinic swap, 3 observation, 4 cooler, 5 gym), default 1; P4_STORY
-- "journal" with STAGE 3 takes the farm journal (the weather log counted as delivered).
-- After it teleports, wait a few seconds for the chunks and run p4_missions_after.lua.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4missions")
local record, player = P4T.record()
if not record then say("no record yet: wait for the first hello"); return end
local stage = STAGE or 1
if not OA.Story.handedOver then say("story part missing"); return end

local s = OA.Missions.state(record)
if s.active then OA.Missions.finish(record, s.active, "lost") end
s.nextAt = 0
OA.Story.setAnchor(record, math.floor(player:getX()), math.floor(player:getY()), 0)
P4T.setStage(record, stage, 0)
-- the stage's own story missions first, whatever the save's queue holds (missed ones, an earlier run's)
local ss = OA.Story.section(record)
ss.queue = {}
local own = OA.StoryData.STAGES[stage] and OA.StoryData.STAGES[stage].stories or {}
if P4_STORY then
    own = { P4_STORY }
    local after = OA.StoryData.STORIES[P4_STORY].trigger.after
    if after then ss.done[after] = "done" end
end
for i = #own, 1, -1 do
    ss.done[own[i]] = nil
    OA.Story.queueStory(record, own[i], true)
end
local m = P4T.takeMission(record)
if not P4T.check(say, "a mission started", m ~= nil) then return end
say("mission", m.id, m.kind, m.story or m.title, "level", m.level, "credits", m.credits, "trust", m.trust)
P4T.check(say, "a story mission first at a new stage", m.kind == "story", m.story)
P4T.check(say, "deadline set", m.deadline > OA.hours(), m.deadline)
P4T.check(say, "the circle is on the record", m.area ~= nil and m.area.r >= 60, m.area and m.area.r)
local it = m.items[1]
if it then
    say("item", it.type, "at", it.x, it.y, it.z, "mode", it.mode, "placed", tostring(it.placed), "lock", tostring(it.lock))
    P4T.go(it.x, it.y, it.z)
    say("teleported; wait a few seconds for the chunks, then RUN p4_missions_after.lua")
end
