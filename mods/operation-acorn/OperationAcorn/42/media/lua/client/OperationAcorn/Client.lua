-- The client side's entry: what the server says, and the character's first hello. Alone, Sync calls the listeners
-- directly and this only says hello.
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
local OA = OperationAcorn
local Client = {}
OA.Client = Client

local function onServerCommand(module, command, args)
    if module ~= OA.MOD or type(args) ~= "table" then return end
    if command == "changed" then
        OA.Sync.deliver(args.what, args.player, args.detail)
    elseif command == "title" then
        OA.Sync.deliver("title", args.player, args.detail)
    elseif command == "notice" then
        OA.Sync.deliver("notice", args.player, { key = args.key, args = args.args })
    else
        OA.Sync.deliver(command, args.player, args)
    end
end

-- The local character's record id, made on the character the first time.
function Client.id(character)
    return OA.Store.idOf(character or getPlayer())
end

-- The local character's record as this client sees it (alone it is the save's; on a server the transmitted copy).
function Client.record(character)
    return OA.Store.player(Client.id(character))
end

-- The mod's one section in the game's mod options (B42 PZAPI.ModOptions), made by whichever part asks first. Each
-- create() call adds a section and takes the id over, so the parts must share this one. nil without the API.
function Client.options()
    if not (PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.create) then return nil end
    return PZAPI.ModOptions:getOptions(OA.MOD) or PZAPI.ModOptions:create(OA.MOD, getText("IGUI_OA_OptionsTitle"))
end

local function onCreatePlayer(index, character)
    if character and character:isLocalPlayer() then
        OA.Sync.send(character, "hello", {})
    end
end

-- On a server the save's data comes as a copy: asked for at the start, sent again on every change.
local function onReceiveGlobalModData(key, data)
    if key ~= OA.Store.KEY or type(data) ~= "table" then return end
    ModData.add(key, data)
    OA.Sync.deliver("all", nil, nil)
end

local function onGameStart()
    if isClient() then ModData.request(OA.Store.KEY) end
    OA.declareOutlines()
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData)
Events.OnGameStart.Add(onGameStart)

return Client
