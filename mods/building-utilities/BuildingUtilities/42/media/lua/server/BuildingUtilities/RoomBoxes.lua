-- Spawned boxes (BU.Spawned) in the rooms the game rolls a generator for, where the world is decided: the server, or
-- the game alone. The game names each room a character sees the first time (OnSeeNewRoom, once a room: its RoomDef's
-- doneSpawn is saved) and then rolls its generator there; the box is rolled for and put down on the next tick, so that
-- a generator the game put there has its square and the box takes another. The tick handler, once added, stays (a
-- handler taken off inside its event makes the game skip the next one that tick) and returns at once while none waits.
require "BuildingUtilities/Spawned"
local BU = BuildingUtilities

if isClient() then return end

local pending, hooked = {}, false

local function onTick()
    if pending[1] == nil then return end
    local rooms = pending
    pending = {}
    for _, room in ipairs(rooms) do
        local ok, err = pcall(BU.Spawned.inRoom, room)
        if not ok then BU.log("a spawned box:", err) end
    end
end

local function onSeeNewRoom(room)
    if not room or not BU.api() or BU.Spawned.chance(room:getName()) <= 0 then return end
    pending[#pending + 1] = room
    if not hooked then
        hooked = true
        Events.OnTick.Add(onTick)
    end
end

Events.OnSeeNewRoom.Add(onSeeNewRoom)
