-- What this mod puts on the maps (DESIGN-terminal 6.6, 8): the mission's area as a circle (teal; a story mission's sky
-- blue) on the world map and the minimap, the dots from the player to it and the supply crates left by the helicopter
-- on the world map only, and the world map opened to show the player and the circle together. All are the game's own
-- map markers (a grid square marker: the game draws it in the map's style), which take no per-frame work from this mod.
-- The world map and the minimap are built again by the game when they are opened (the world map once, the minimap on
-- each recreate), so the markers are put on a map when it opens and again whenever the mission or the crates change.
-- Which markers there are is worked out by Story/View (pure); this puts them on the maps and takes them off.
require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/View"
local OA = OperationAcorn
local View = OA.StoryView
local Maps = {}
OA.StoryMaps = Maps

-- The margin kept from the screen's edge when the world map is fitted to the player and the circle, in pixels.
Maps.MARGIN = 96
local MAX_ZOOM = 24

-- Maps that have our markers: mapAPI -> { signature, markers }. Weak keys, so a recreated minimap drops its entry.
local applied = setmetatable({}, { __mode = "k" })

local function removeAll(mapAPI)
    local mine = applied[mapAPI]
    if not mine then return end
    local api = mapAPI:getMarkersAPI()
    for _, marker in ipairs(mine.markers) do pcall(api.removeMarker, api, marker) end
    applied[mapAPI] = nil
end

-- Puts the character's markers on a map (replacing the ones put before; the same ones are left as they are). `world`
-- is whether it is the world map: the dots and the crates are for it only.
function Maps.apply(mapAPI, character, world)
    if not mapAPI or not character then return end
    local record = OA.Client.record(character)
    local list = View.markers(record, math.floor(character:getX()), math.floor(character:getY()), world)
    local signature = View.signature(list)
    local mine = applied[mapAPI]
    if mine and mine.signature == signature then return end
    removeAll(mapAPI)
    if #list == 0 then return end
    local api = mapAPI:getMarkersAPI()
    local markers = {}
    for _, k in ipairs(list) do
        local ok, marker = pcall(api.addGridSquareMarker, api, k.x, k.y, k.r, k.color[1], k.color[2], k.color[3], k.alpha)
        if ok and marker then
            pcall(marker.setBlink, marker, false)
            pcall(marker.setMinScreenRadius, marker, k.minPx)
            markers[#markers + 1] = marker
        end
    end
    applied[mapAPI] = { signature = signature, markers = markers }
end

-- The maps in use right now, for a refresh when the mission or the crates change.
local function liveMaps()
    local list = {}
    if ISWorldMap_instance and ISWorldMap_instance.mapAPI then
        list[#list + 1] = { api = ISWorldMap_instance.mapAPI, player = ISWorldMap_instance.playerNum, world = true }
    end
    for playerNum = 0, getNumActivePlayers() - 1 do
        local mini = getPlayerMiniMap and getPlayerMiniMap(playerNum)
        if mini and mini.inner and mini.inner.mapAPI then
            list[#list + 1] = { api = mini.inner.mapAPI, player = playerNum }
        end
    end
    return list
end

function Maps.refresh()
    for _, entry in ipairs(liveMaps()) do
        Maps.apply(entry.api, getSpecificPlayer(entry.player or 0), entry.world)
    end
end

-- Opening the world map to show the player and the mission's circle (8) ---------------------------------------------

-- The map's size, its smallest zoom and its view setting, as the open map has them (or as it will open).
local function viewOf()
    local map = ISWorldMap_instance
    local api = map and map.mapAPI
    return {
        width = map and map:getWidth() or getCore():getScreenWidth(),
        height = map and map:getHeight() or getCore():getScreenHeight(),
        margin = Maps.MARGIN,
        minZoom = api and api:getBaseZoom() or 12,
        maxZoom = MAX_ZOOM,
        -- The map's own view setting is read as it opens; the isometric bound is the safe one until it is known.
        isometric = api == nil or api:getBoolean("Isometric"),
    }
end

-- Opens the world map centred between the character and the circle of its mission, at the zoom that shows both.
function Maps.show(character)
    local circle = View.circles(View.shown(OA.Client.record(character)))[1]
    if not circle or not (ISWorldMap and ISWorldMap.ShowWorldMap) then return end
    local px, py = character:getX(), character:getY()
    local cx, cy, zoom = View.fit(px, py, circle, viewOf())
    ISWorldMap.ShowWorldMap(character:getPlayerNum(), cx, cy, zoom)
    -- What the map has now (its saved view setting is applied as it opens): fitted again when that changes the zoom.
    local map = ISWorldMap_instance
    if not (map and map.mapAPI) then return end
    local _, _, again = View.fit(px, py, circle, viewOf())
    if math.abs(again - zoom) > 0.005 then
        map.mapAPI:centerOn(cx, cy)
        map.mapAPI:setZoom(again)
    end
end

-- Hooks: the world map when it is shown, the minimap when it is built.
local showWorldMap = ISWorldMap.ShowWorldMap
ISWorldMap.ShowWorldMap = function(playerNum, ...)
    showWorldMap(playerNum, ...)
    if ISWorldMap_instance then
        Maps.apply(ISWorldMap_instance.mapAPI, getSpecificPlayer(playerNum), true)
    end
end

local instantiate = ISMiniMapInner.instantiate
ISMiniMapInner.instantiate = function(self, ...)
    instantiate(self, ...)
    Maps.apply(self.mapAPI, getSpecificPlayer(self.playerNum or 0), false)
end

OA.Sync.listen("missions", function() Maps.refresh() end)
OA.Sync.listen("trade", function() Maps.refresh() end)
OA.Sync.listen("all", function() Maps.refresh() end)

return Maps
