-- The mission's area on the map (DESIGN: a circle that marks the area, not the spot). The world map and the minimap
-- are built again by the game when they are opened (the world map once, the minimap on each recreate), so the circles
-- are put on a map when it opens and again whenever the mission changes. Only squares' markers are used: the game
-- draws them in the map's own style, and they take no per-frame work from this mod.
require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
local OA = OperationAcorn
local Maps = {}
OA.StoryMaps = Maps

-- The colours: a story mission's circle is paler blue, the others amber; the second circle (the other copy) is dimmer.
Maps.COLORS = {
    regular = { 1.0, 0.78, 0.25, 0.55 },
    story = { 0.55, 0.78, 1.0, 0.55 },
}

-- Maps that have our markers: mapAPI -> { markers }. Weak keys, so a recreated minimap drops its entry.
local applied = setmetatable({}, { __mode = "k" })

local function activeMission(character)
    local record = OA.Client.record(character)
    if not (record and record.missions and record.missions.active) then return nil end
    local m = record.missions.active
    if m.state == "offer" or m.state == "calling" then return nil end
    return m
end

-- The circles to draw for a mission: { { x =, y =, r =, dim = bool }, ... } (a sealed or finished mission has none).
function Maps.circles(m)
    local list = {}
    if not m or m.state == "sealed" then return list end
    if m.area then list[#list + 1] = { x = m.area.x, y = m.area.y, r = m.area.r } end
    if m.area2 then list[#list + 1] = { x = m.area2.x, y = m.area2.y, r = m.area2.r, dim = true } end
    return list
end

local function removeAll(mapAPI)
    local mine = applied[mapAPI]
    if not mine then return end
    local api = mapAPI:getMarkersAPI()
    for _, marker in ipairs(mine) do pcall(api.removeMarker, api, marker) end
    applied[mapAPI] = nil
end

-- Puts the character's mission circles on a map (replacing the ones put before).
function Maps.apply(mapAPI, character)
    if not mapAPI then return end
    removeAll(mapAPI)
    local m = activeMission(character)
    local circles = Maps.circles(m)
    if #circles == 0 then return end
    local color = (m.kind == "story") and Maps.COLORS.story or Maps.COLORS.regular
    local api = mapAPI:getMarkersAPI()
    local mine = {}
    for _, c in ipairs(circles) do
        local a = c.dim and color[4] * 0.6 or color[4]
        local ok, marker = pcall(api.addGridSquareMarker, api, math.floor(c.x), math.floor(c.y), math.floor(c.r),
            color[1], color[2], color[3], a)
        if ok and marker then
            pcall(marker.setBlink, marker, false)
            mine[#mine + 1] = marker
        end
    end
    applied[mapAPI] = mine
end

-- The maps in use right now, for a refresh when the mission changes.
local function liveMaps()
    local list = {}
    if ISWorldMap_instance and ISWorldMap_instance.mapAPI then
        list[#list + 1] = { api = ISWorldMap_instance.mapAPI, player = ISWorldMap_instance.playerNum }
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
        Maps.apply(entry.api, getSpecificPlayer(entry.player or 0))
    end
end

-- Hooks: the world map when it is shown, the minimap when it is built.
local showWorldMap = ISWorldMap.ShowWorldMap
ISWorldMap.ShowWorldMap = function(playerNum, ...)
    showWorldMap(playerNum, ...)
    if ISWorldMap_instance then
        Maps.apply(ISWorldMap_instance.mapAPI, getSpecificPlayer(playerNum))
    end
end

local instantiate = ISMiniMapInner.instantiate
ISMiniMapInner.instantiate = function(self, ...)
    instantiate(self, ...)
    Maps.apply(self.mapAPI, getSpecificPlayer(self.playerNum or 0))
end

OA.Sync.listen("missions", function() Maps.refresh() end)
OA.Sync.listen("all", function() Maps.refresh() end)

return Maps
