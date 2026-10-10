-- A mission scene's hands in the game world (server side, and alone): Scene.game points here. Things on the floor of
-- the building, the zombies that keep it, the survivor and what it carried. Checked in the game, not by unit tests.
--
-- B42 calls used (checked in the game's files): addZombiesInOutfit(x, y, z, count, outfit, femaleChance, crawler,
-- fallOnFront, fakeDead, knockedDown, invulnerable, sitting, health) (LuaManager.GlobalObject; the outfit is dressed
-- with PersistentOutfits, whose id the zombie keeps when it leaves the loaded area and when a fake-dead body rises),
-- IsoGameCharacter.getPersistentOutfitID, GameTime.getWorldAgeDaysSinceBegin, ClimateManager's season getDawn and
-- getDusk, DrainableComboItem.setUsedDelta, and the OnZombieDead
-- event (IsoZombie.onKilled: after DoZombieInventory, before DoDeath makes the body from the inventory).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Say"
require "OperationAcorn/Story/Scene"
require "OperationAcorn/Story/Game"
local OA = OperationAcorn
local Scene = OA.Scene
local SceneGame = {}
OA.SceneGame = SceneGame

function SceneGame.playerPosition(record)
    return OA.StoryGame.playerPosition(record)
end

function SceneGame.days()
    return getGameTime():getWorldAgeDaysSinceBegin()
end

-- Night by the season's dawn and dusk (ClimateManager's season, as the foraging display reads them; GameTime's own
-- dawn and dusk fields are not kept up).
function SceneGame.isNight()
    local season = getClimateManager():getSeason()
    return Scene.isNight(getGameTime():getTimeOfDay(), season:getDawn(), season:getDusk())
end

function SceneGame.say(record, id, ctx)
    OA.Say.tell(record.id, id, ctx)
end

function SceneGame.loaded(at)
    return getCell():getGridSquare(at.x, at.y, at.z) ~= nil
end

-- The free squares in rooms of the piece's building, on its floor, within `radius` of it (loaded ones only), nearest
-- first; those nearer than `near` (Scene.NEAR by default) to the player (px, py) left out when px is given.
local function freeSquares(it, radius, px, py, near)
    local c = getCell()
    local at = it.at
    local home = c:getGridSquare(at.x, at.y, at.z)
    local building = home and home:getBuilding()
    local list = {}
    if not building then return list end
    near = near or Scene.NEAR
    local near2 = near * near
    for x = math.max(it.x1, at.x - radius), math.min(it.x2, at.x + radius) do
        for y = math.max(it.y1, at.y - radius), math.min(it.y2, at.y + radius) do
            local sq = c:getGridSquare(x, y, at.z)
            if sq and sq:getRoom() and sq:getBuilding() == building and sq:isFree(false) then
                local far = true
                if px then
                    local dx, dy = x - px, y - py
                    far = dx * dx + dy * dy >= near2
                end
                if far then
                    local dx, dy = x - at.x, y - at.y
                    list[#list + 1] = { sq = sq, d = dx * dx + dy * dy }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    return list
end

local function takeRandom(list, upTo)
    if #list == 0 then return nil end
    local i = OA.random(1, math.min(#list, upTo or #list))
    return table.remove(list, i).sq
end

-- The things left: each on its own square near the piece, a drained one with what is left of it.
function SceneGame.placeProps(it, props)
    local squares = freeSquares(it, 6)
    for _, p in ipairs(props) do
        local sq = takeRandom(squares, 12)
        if not sq then return end
        local item = sq:AddWorldInventoryItem(p.type, 0.2 + OA.randomFloat(0, 0.6), 0.2 + OA.randomFloat(0, 0.6), 0)
        if item and p.left and instanceof(item, "DrainableComboItem") then item:setUsedDelta(p.left) end
    end
end

local function spawn(sq, outfit, female, crawler, fakeDead, sitting)
    local list = addZombiesInOutfit(sq:getX(), sq:getY(), sq:getZ(), 1, outfit or nil, female or nil, crawler == true,
        false, fakeDead == true, false, false, sitting == true, 1.0)
    if list and list:size() > 0 then return list:get(0) end
    return nil
end

-- The keepers: the first in the piece's room when it can be, the rest about the building.
function SceneGame.spawnGuards(it, guards, px, py, near)
    local squares = freeSquares(it, 16, px, py, near)
    local home = getCell():getGridSquare(it.at.x, it.at.y, it.at.z)
    local room = home and home:getRoom()
    for i, g in ipairs(guards) do
        local sq
        if i == 1 and room then
            for k, e in ipairs(squares) do
                if e.sq:getRoom() == room then
                    sq = table.remove(squares, k).sq
                    break
                end
            end
        end
        sq = sq or takeRandom(squares)
        if not sq then return end
        spawn(sq, g.outfit, g.female)
    end
end

-- The survivor, by the piece: its persistent outfit id, or nil when it could not be made.
function SceneGame.spawnSurvivor(it, s, px, py, near)
    local sq = takeRandom(freeSquares(it, 2, px, py, near), 4)
    if not sq then return nil end
    local zombie = spawn(sq, s.outfit, 50, s.look == "crawler", s.look == "fakeDead", s.look == "sitting")
    if not zombie then return nil end
    local id = zombie:getPersistentOutfitID()
    if not id or id == 0 then return nil end
    return id
end

-- OnZombieDead: a survivor's things go into its inventory, which becomes the body's. Marked with the mission, so the
-- first one taken says the line.
function SceneGame.zombieDied(zombie)
    if isClient() or not zombie then return end
    local record, s = Scene.survivorDied(zombie:getPersistentOutfitID(), zombie:getX(), zombie:getY())
    if not s then return end
    local inv = zombie:getInventory()
    for _, t in ipairs(s.carried or {}) do
        local item = instanceItem(t)
        if item then
            item:getModData().OA_Carried = s.mission
            inv:AddItem(item)
        end
    end
    OA.log("survivor of", s.mission, "dropped", #(s.carried or {}), "things for", record.number)
end

return SceneGame
