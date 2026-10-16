-- The server side's entry: client commands by name, and the world events the parts share. Alone, the game runs this
-- too (it is its own server).
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Chunks"
local OA = OperationAcorn
local Server = {}
OA.Server = Server

-- Command handlers: commands[name] = function(character, record, args). The record is the player's (made the first
-- time, and bound to the account that sent it: record.user); args.id is the character's id (Sync.send adds it).
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

local function onClientCommand(module, command, character, args)
    if module ~= OA.MOD then return end
    local fn = commands[command]
    if not fn then
        OA.log("unknown command", command)
        return
    end
    if type(args) ~= "table" or type(args.id) ~= "string" then return end
    local name = character and character.getUsername and character:getUsername() or nil
    local record = OA.Store.player(args.id)
    -- a record answers to the account that made it: the id comes from the client, so another account naming it is refused
    if record and name and record.user and record.user ~= name then
        OA.log("command", command, "from", name, "names the record of another player: refused")
        return
    end
    record = record or OA.Store.ensure(args.id, name)
    if name and not record.user then record.user = name end
    local ok, err = pcall(fn, character, record, args)
    if not ok then OA.log("command", command, "failed:", tostring(err)) end
end

Events.OnClientCommand.Add(onClientCommand)
Events.LoadChunk.Add(OA.Chunks.loaded)

Events.OnPlayerDeath.Add(onPlayerDeath)

return Server
