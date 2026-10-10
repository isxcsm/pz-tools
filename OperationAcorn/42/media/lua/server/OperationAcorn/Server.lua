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

-- A character says who it is the first time it is seen, so that the server has its record.
Server.on("hello", function(character, record, args) end)

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

return Server
