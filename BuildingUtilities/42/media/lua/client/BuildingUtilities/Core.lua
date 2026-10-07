-- Building Utilities: one breaker box powers and waters a whole building through the PZ Tools extension API.
-- The rules (what joins, how far, one box per building) are this mod's; the API runs the networks.
BuildingUtilities = BuildingUtilities or {}
local BU = BuildingUtilities

BU.MOD = "BuildingUtilities"
BU.UTILITIES = { "power", "water" }
BU.POLICY = { power = "sequential", water = "fullest" }
BU.API_VERSION = 1

function BU.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildingUtilities] " .. table.concat(parts, " "))
end

-- The extension API, or nil with the reason it is missing: PZ Tools not installed in startup mode, or another version.
function BU.api()
    local api = PZToolsAPI
    if type(api) ~= "table" or not api.networks then return nil, "missing" end
    if api.version ~= BU.API_VERSION then return nil, "version" end
    return api
end

-- This mod's handle: every network change goes through it.
function BU.handle()
    local api = BU.api()
    return api and api.client(BU.MOD) or nil
end

function BU.networkId(panelId, utility) return "bu-" .. panelId .. "-" .. utility end

-- "x,y,z,sprite": how an object is named in the saved lists.
function BU.thingKey(x, y, z, sprite) return x .. "," .. y .. "," .. z .. "," .. sprite end

function BU.parseThing(key)
    local x, y, z, sprite = key:match("^(-?%d+),(-?%d+),(-?%d+),(.+)$")
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z), sprite
end

function BU.sandbox(name, default)
    local page = SandboxVars and SandboxVars.BuildingUtilities
    local value = page and page[name]
    if value == nil then return default end
    return value
end

-- Squares around a building, from its outline, in which a device outside it can join: the API reads at most 32.
function BU.exteriorRange() return math.max(0, math.min(32, BU.sandbox("ExteriorRange", 10))) end
function BU.producerRange() return math.max(1, BU.sandbox("ProducerRange", 20)) end
function BU.subPanelRange() return math.max(1, BU.sandbox("SubPanelRange", 50)) end

-- The breaker box: no vanilla tile is one, so a small electric terminal stands in for it, one sprite per facing.
BU.PANEL_SPRITES = { "security_01_0", "security_01_1", "security_01_2", "security_01_3" }
BU.PANEL_ITEM = "BuildingUtilities.BreakerBox"

-- A water producer: an object the game fills with rain or water (rain barrels, metal drums), with a fluid container.
function BU.isWaterContainer(object)
    if not object or instanceof(object, "IsoGenerator") then return false end
    local properties = object:getProperties()
    if not properties or not properties:has("IsWaterCollector") then return false end
    local container = object:getFluidContainer()
    return container ~= nil and container:getCapacity() > 0
end

-- The objects on a square with a sprite name, as a device entry names them.
function BU.objectsWithSprite(x, y, z, sprite)
    local result = {}
    local square = getCell():getGridSquare(x, y, z)
    if not square then return result end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local name = object:getSpriteName() or (object:getSprite() and object:getSprite():getName())
        if name == sprite then result[#result + 1] = object end
    end
    return result
end

-- What players call an object: its moveable name, or its sprite name when the square is not loaded.
function BU.displayName(x, y, z, sprite)
    local object = BU.objectsWithSprite(x, y, z, sprite)[1]
    if object then
        local name = Translator.getMoveableDisplayName(object)
        if name and name ~= "" then return name end
        if object:getObjectName() and object:getObjectName() ~= "" then return object:getObjectName() end
    end
    return sprite
end

-- A room name of the map ("kitchen", "gasstore") as words.
function BU.roomName(name)
    local text = getTextOrNull("IGUI_BU_Room_" .. name)
    if text then return text end
    return (name:gsub("^%l", string.upper))
end

return BU
