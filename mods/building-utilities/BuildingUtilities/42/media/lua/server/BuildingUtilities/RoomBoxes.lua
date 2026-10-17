-- Spawned boxes (BU.Spawned) in the rooms the game rolls a generator for, where the world is decided: the server, or
-- the game alone. The game names each room a character sees the first time (OnSeeNewRoom, once a room: its RoomDef's
-- doneSpawn is saved) and then rolls its generator there; the box is rolled for and put down on the next tick, so that
-- a generator the game put there has its square and the box takes another.
require "BuildingUtilities/Spawned"
local BU = BuildingUtilities

if isClient() then return end

local pending, ticking = {}, false

local function onTick()
    Events.OnTick.Remove(onTick)
    ticking = false
    local rooms = pending
    pending = {}
    for _, room in ipairs(rooms) do
        local ok, err = pcall(BU.Spawned.inRoom, room)
        if not ok then BU.log("a spawned box:", err) end
    end
end

local function onSeeNewRoom(room)
    if not room or BU.Spawned.chance(room:getName()) <= 0 then return end
    pending[#pending + 1] = room
    if not ticking then
        ticking = true
        Events.OnTick.Add(onTick)
    end
end

Events.OnSeeNewRoom.Add(onSeeNewRoom)
