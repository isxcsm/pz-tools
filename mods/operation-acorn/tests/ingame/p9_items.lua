-- P9: a mission's piece in the real world (E2E.md 4.3). A regular mission is started, its piece put in the character's
-- hands as a pickup would, and then moved around: carried, in a bag, on the floor, in a crate, in a car's trunk, gone
-- (sealed away). Each time the maps' place (Missions.lookWhere) must follow. Then the crate burns with the piece in it
-- (Game.onBurning, what the API's fire event calls): the piece is not found any more, it is laid out again at its place
-- or waits for it to load, and the deadline gives back the time the mission had. Last, taking another mission works once
-- a week. Death, streaks, urgent deadlines and sealing on time are the unit tests' (story_missions_test).
-- Setup: single player, a record past the first hello, a square free 2 east of the character, a car within the loaded
-- cell for the trunk (else that step is skipped). CHANGES THE RECORD (the stage set to 2 with its stories done, the
-- active mission, this week's reroll): use a throwaway save. Lines are tagged "[p9items]".
RUN("p4_lib.lua")
local OA = OperationAcorn
local Missions, Game = OA.Missions, OA.Missions.game
local say = P4T.say("p9items")
local function check(...) return P4T.check(say, ...) end
local record, player = P4T.record()
if not record then say("no record yet: wait for the first hello"); return end

-- A regular mission: the stage's stories counted as done, so the tick makes a plain one.
local s = Missions.state(record)
if s.active then Missions.finish(record, s.active, "lost") end
s.nextAt, s.reroll = 0, nil
P4T.setStage(record, 2, 0)
local ss = OA.Story.section(record)
ss.queue = {}
for stage = 1, 2 do
    for _, id in ipairs(OA.StoryData.STAGES[stage].stories or {}) do ss.done[id] = "done" end
end
local m = P4T.takeMission(record)
if not check("a regular mission started", m ~= nil and m.kind == "regular", m and m.kind) then return end
local it = m.items[1]
say("mission", m.id, m.form or m.title, "piece", it.type, it.mode, "deadline in", string.format("%.1f h", m.deadline - OA.hours()))

-- In the character's hands, as a pickup finds it.
local item = Game.giveMissionItem(player, it.type, Missions.itemId(m, it.key))
Missions.pickedUp(record, item)
check("picked up: found", it.found == true)
local function where(label, x, y, z, carried)
    Missions.lookWhere(record, m)
    local w = it.where
    check(label, w ~= nil and w.x == x and w.y == y and w.z == z and (w.carried == true) == carried,
        w and (w.x .. "," .. w.y .. "," .. w.z .. (w.carried and " carried" or "")) or "none")
end
local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
where("carried: the maps follow the character", px, py, pz, true)

local inv = player:getInventory()
local bag = inv:AddItem("Base.Bag_Schoolbag")
inv:Remove(item)
bag:getInventory():AddItem(item)
where("in a bag the character holds: still carried", px, py, pz, true)

bag:getInventory():Remove(item)
local sq = getCell():getGridSquare(px + 2, py, pz)
sq:AddWorldInventoryItem(item, 0.5, 0.5, 0)
where("dropped on the floor: the square", px + 2, py, pz, false)

local floor = item:getWorldItem()
if floor then
    sq:transmitRemoveItemFromSquare(floor)
    floor:removeFromWorld()
    floor:removeFromSquare()
end
item:setWorldItem(nil)
local crate = IsoObject.new(sq, "carpentry_01_16", "Crate")
sq:AddSpecialObject(crate)
crate:createContainersFromSpriteProperties()
local box = crate:getContainer()
box:AddItem(item)
where("in a crate: the crate's square", px + 2, py, pz, false)

local car
local vehicles = OA.vehicles()
for i = 0, vehicles:size() - 1 do
    local v = vehicles:get(i)
    local trunk = v:getPartById("TruckBed")
    if not car and trunk and trunk:getItemContainer() then car = { v = v, c = trunk:getItemContainer() } end
end
if car then
    box:Remove(item)
    car.c:AddItem(item)
    where("in a car's trunk: the car", math.floor(car.v:getX()), math.floor(car.v:getY()), math.floor(car.v:getZ()), false)
    car.c:Remove(item)
    box:AddItem(item)
else
    say("info no car with a trunk loaded: the trunk step skipped")
end

-- Gone (sealed away): the maps keep the last place.
local last = it.where
box:Remove(item)
Missions.lookWhere(record, m)
check("gone from the world: the last place stays", it.where == last)
box:AddItem(item)

-- The crate burns with the piece in it.
local span = m.deadline - (m.issued or OA.hours())
local before = m.deadline
Game.onBurning(box, crate)
check("burnt: the piece is to be found again", not it.found and it.where == nil)
check("burnt: laid out again or waiting for its place to load", it.placed == true or it.placed == false, tostring(it.placed))
check("burnt: the deadline gives the time the mission had", m.deadline >= before and m.deadline >= OA.hours() + span - 0.01,
    string.format("%.1f -> %.1f h left", before - OA.hours(), m.deadline - OA.hours()))
check("the mission goes on", Missions.active(record) == m and m.state == "open")
sq:transmitRemoveItemFromSquare(crate)

-- Another mission instead, once a week.
local offer = Missions.rerollOffer(record, m)
check("the card offers another mission, once this week", offer ~= nil and offer.left == 1, offer and offer.trust)
local took = Missions.reroll(record)
local fresh = Missions.active(record)
check("taken: a new mission", took and fresh ~= m, fresh and fresh.id)
local again = Missions.rerollOffer(record, fresh)
check("the second time this week is refused", again ~= nil and again.left == 0 and not Missions.reroll(record))

inv:Remove(bag)
say("done; the new mission stays active (finish it with OperationAcorn.Missions.finish if needed)")
