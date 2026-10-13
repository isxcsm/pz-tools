-- The client's watch on the character's infection (DESIGN-terminal 17): the new zombie wounds that make a wound
-- untested and end a delay drug, the once-a-minute work (holding the infection where a drug took it, telling the server
-- what the body shows) and the two moodles, `억제 중` while a drug holds and `검사 전` while a wound is untested. What the
-- server decides and keeps is in the record's infection section (shared Upgrades/Infection.lua, server Upgrades/Server.lua).
require "OperationAcorn/Client"
require "OperationAcorn/Upgrades/Serums"
require "OperationAcorn/Upgrades/Moodles"
local OA = OperationAcorn
local Infection = OA.Infection
local Serums = OA.Upgrades.Serums
local Moodles = OA.Upgrades.Moodles
local Watch = {}
OA.Upgrades.Watch = Watch

-- ---- the moodles ----------------------------------------------------------------------------------------------

-- Sets the two moodles from the record at `now`: a drug's by the days it has left (a level for a day or less, up to 3,
-- 5 and 7 days), the untested one on or off.
function Watch.moodles(record, now)
    local state = Infection.state(record, now)
    Moodles.set("suppressed", state and state.drug and Infection.drugLevel(state.drug.hoursLeft) or 0)
    Moodles.set("untested", state and state.untested and 1 or 0)
end

-- ---- once a minute ------------------------------------------------------------------------------------------------

-- Holds the infection where a drug took it, tells the server when the body shows something the record does not, and
-- sets the moodles. Call about once a minute for the local character.
function Watch.minute(player, now)
    local record = OA.Client.record(player)
    if not record then return end
    Serums.holdInfection(player, record, now)
    local infected = player:getBodyDamage():IsInfected()
    local progress = nil
    if infected and record.infection and record.infection.known then progress = Serums.progress(player) end
    if Infection.wantsSeen(record, infected, progress, now) then
        OA.Sync.send(player, "infection.seen", { infected = infected, progress = progress })
    end
    Watch.moodles(record, now)
end

-- ---- every update, while a zombie attacks ---------------------------------------------------------------------

local me = nil      -- the local character (the first player)

-- One update of the character: Infection.watch reads nothing but a counter until a zombie has attacked, and says the
-- kind of a wound the moment it shows.
local function onUpdate(player)
    if player ~= me then return end
    local kind = Infection.watch(player)
    if kind and not player:isDead() then
        OA.Sync.send(player, "infection.wound", { kind = kind })
    end
end
Events.OnPlayerUpdate.Add(onUpdate)

local function onCreatePlayer(index, player)
    if index == 0 then
        me = player
        Infection.resetWatch()
    end
end
Events.OnCreatePlayer.Add(onCreatePlayer)

local function onGameStart()
    me = getPlayer()
    Infection.resetWatch()
    local player = me
    local record = player and OA.Client.record(player)
    if record then Watch.moodles(record, OA.hours()) end
end
Events.OnGameStart.Add(onGameStart)

-- The record changed (a wound, a test, a drug, a cure): the moodles follow at once.
local function onChanged()
    local player = getPlayer()
    local record = player and OA.Client.record(player)
    if record then Watch.moodles(record, OA.hours()) end
end
OA.Sync.listen("infection", onChanged)
OA.Sync.listen("all", onChanged)

return Watch
