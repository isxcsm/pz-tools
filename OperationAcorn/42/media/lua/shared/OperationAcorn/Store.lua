-- What the mod keeps in the save. Everything lives in one global ModData table the server owns, so that the
-- helicopter can settle a delivery while its box's square is not loaded (DESIGN 12). Each part of the mod keeps its
-- own section, by name, in the world or in a player's record; ARCHITECTURE.md lists the sections and their owners.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Store = {}
OA.Store = Store

Store.KEY = "OA_World"
Store.VERSION = 1

-- { version, nextNumber, numbers = { [number] = id }, players = { [id] = player }, world = { [section] = {...} } }.
-- A player record (one per character: the research team deals with that survivor):
--   id (the key, also in the character's modData as OA_Id), number (the four-digit collection point number the team
--   calls them by), created (world age), name (the character's, for logs), and the sections of the mod's parts.
function Store.root()
    local root = ModData.getOrCreate(Store.KEY)
    if not root.version then
        root.version = Store.VERSION
        root.players = {}
        root.numbers = {}
        root.world = {}
    end
    return root
end

-- A world section (the market, the meteor drop sites ...), made empty the first time.
function Store.world(section)
    local world = Store.root().world
    local t = world[section]
    if not t then
        t = {}
        world[section] = t
    end
    return t
end

-- The record of a player by id, or nil.
function Store.player(id)
    return id and Store.root().players[id] or nil
end

-- A section of a player's record, made empty the first time.
function Store.section(player, section)
    local t = player[section]
    if not t then
        t = {}
        player[section] = t
    end
    return t
end

-- Every player record, for the parts that work on all of them (the helicopters, the missions).
function Store.players()
    return Store.root().players
end

-- A new four-digit collection point number no other player in this world has (LORE: 채집점 번호).
local function newNumber(root)
    for _ = 1, 100 do
        local n = OA.random(1000, 9999)
        if not root.numbers[n] then return n end
    end
    for n = 1000, 9999 do
        if not root.numbers[n] then return n end
    end
    return 0
end

-- The record for a character's id, made the first time. The id is the one the character keeps in its modData
-- (Store.idOf); the server takes it from the command that names it.
function Store.ensure(id, name)
    local root = Store.root()
    local player = root.players[id]
    if not player then
        local number = newNumber(root)
        player = { id = id, number = number, created = OA.hours(), name = name }
        root.players[id] = player
        root.numbers[number] = id
        OA.log("new collection point", number, "for", tostring(name))
    end
    return player
end

-- The id a character goes by, from its modData; made on the character the first time (client side, or alone).
function Store.idOf(character)
    local data = character:getModData()
    local id = data.OA_Id
    if not id then
        id = tostring(OA.random(100000, 999999)) .. "-" .. tostring(math.floor(OA.hours() * 60))
        data.OA_Id = id
    end
    return id
end

return Store
