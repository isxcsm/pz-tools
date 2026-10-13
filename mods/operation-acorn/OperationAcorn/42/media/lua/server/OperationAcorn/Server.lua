-- The server side's entry: client commands by name, and the world events the parts share. Alone, the game runs this
-- too (it is its own server).
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Chunks"
local OA = OperationAcorn
local Server = {}
OA.Server = Server

-- Command handlers: commands[name] = function(character, record, args). The record is the player's (made the first
-- time); args.id is the character's id (Sync.send adds it).
local commands = {}

function Server.on(name, fn)
    commands[name] = fn
end

-- A character says who it is the first time it is seen, so that the server has its record. A living character's
-- record is never a dead one's (Store.retire alone may have taken a split-screen player not yet joined for one).
Server.on("hello", function(character, record, args)
    if record.dead ~= nil and character and not character:isDead() then record.dead = nil end
end)

-- A character died: its record goes still, and its running missions end (Missions.retire).
local function onPlayerDeath(character)
    if isClient() or not character then return end
    local id = character:getModData().OA_Id
    local record = id and OA.Store.player(id)
    if record and OA.Store.retire(record) and OA.Missions and OA.Missions.retire then OA.Missions.retire(record) end
end

-- A save from before records went still: alone, a record no local character has is a dead character's (a new one in
-- the world has its own). Marked only; a split-screen player who joins later says hello and is alive again.
local function retireOthers()
    if isClient() or isServer() then return end
    local ids, count = {}, 0
    for i = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(i)
        if p and not p:isDead() then
            ids[OA.Store.idOf(p)] = true
            count = count + 1
        end
    end
    if count == 0 then return end
    for _, record in pairs(OA.Store.players()) do
        if not ids[record.id] then OA.Store.retire(record) end
    end
end

local function onClientCommand(module, command, character, args)
    if module ~= OA.MOD then return end
    local fn = commands[command]
    if not fn then
        OA.log("unknown command", command)
        return
    end
    if type(args) ~= "table" or type(args.id) ~= "string" then return end
    local name = character and character.getUsername and character:getUsername() or nil
    local record = OA.Store.ensure(args.id, name)
    local ok, err = pcall(fn, character, record, args)
    if not ok then OA.log("command", command, "failed:", tostring(err)) end
end

-- The records saved by an older version are brought up to date once the save is loaded.
local upgraded = false
local function upgradeRecords()
    if upgraded or isClient() then return end
    upgraded = true
    OA.Store.upgradeAll()
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnGameStart.Add(upgradeRecords)
Events.OnServerStarted.Add(upgradeRecords)
Events.LoadChunk.Add(OA.Chunks.loaded)

Events.OnPlayerDeath.Add(onPlayerDeath)
Events.OnGameStart.Add(retireOthers)

return Server
