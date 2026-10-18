-- A mission scene's hands in the game world (server side, and alone): Scene.game points here. Things on the floor of
-- the building, the zombies that keep it, the survivor and what it carried. Checked in the game, not by unit tests.
--
-- B42 calls used (checked in the game's files): addZombiesInOutfit(x, y, z, count, outfit, femaleChance, crawler,
-- fallOnFront, fakeDead, knockedDown, invulnerable, sitting, health) (LuaManager.GlobalObject; the outfit is dressed
-- with PersistentOutfits, whose id the zombie keeps when it leaves the loaded area and when a fake-dead body rises),
-- IsoDeadBody.new(zombie, false) and setFakeDead (the body takes the zombie's place, outfit and things),
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

function SceneGame.say(record, id, ctx, delay)
    OA.Say.tell(record.id, id, ctx, delay)
end

function SceneGame.title(record, detail)
    OA.Sync.title(record.id, detail)
end

-- Whether the player stands inside the building a square is in (the square loaded: the same building).
function SceneGame.inBuildingOf(record, at)
    local p = OA.StoryGame.character(record)
    local here = p and p:getCurrentSquare()
    local building = here and here:getBuilding()
    if not building then return false end
    local square = getCell():getGridSquare(at.x, at.y, at.z)
    local there = square and square:getBuilding()
    return there ~= nil and there:getDef() == building:getDef()
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

-- One zombie on the square. Fake dead it lies there as a fake-dead body (as the game's own lie, rising when a player
-- comes near and sees it): a zombie made fake dead falls as a ragdoll when the game's physics hit reaction is on, and
-- slides squares away, through walls too, before it settles.
-- `female`: the chance (0 to 100); left out (nil or false), the outfit's: one the game has for one sex only (a prison guard's, an
-- inmate's) is that sex, else either (an outfit asked for a sex it has not is the game's random one).
local onlyFor = {}
local function femaleChance(outfit)
    local c = onlyFor[outfit]
    if c == nil then
        local f, m = getAllOutfits(true):contains(outfit), getAllOutfits(false):contains(outfit)
        c = (f and not m and 100) or (m and not f and 0) or false
        onlyFor[outfit] = c
    end
    return c or nil
end

function SceneGame.spawn(sq, outfit, female, crawler, fakeDead, sitting)
    if not female and outfit then female = femaleChance(outfit) end
    local list = addZombiesInOutfit(sq:getX(), sq:getY(), sq:getZ(), 1, outfit or nil, female or nil, crawler == true,
        false, false, false, false, sitting == true, 1.0)
    local zombie = list and list:size() > 0 and list:get(0) or nil
    if zombie and fakeDead then IsoDeadBody.new(zombie, false):setFakeDead(true) end
    return zombie
end
local spawn = SceneGame.spawn

-- The zombies already in a building (once, as the scene is made).
local function zombiesIn(building)
    local list = getCell():getZombieList()
    local n = 0
    for i = 0, list:size() - 1 do
        local sq = list:get(i):getCurrentSquare()
        if sq and sq:getBuilding() == building then n = n + 1 end
    end
    return n
end

-- The keepers, less those already in the building: the first in the piece's room when it can be, the rest spread
-- over the building's rooms on the piece's floor.
function SceneGame.spawnGuards(it, guards, px, py, near)
    local home = getCell():getGridSquare(it.at.x, it.at.y, it.at.z)
    local building = home and home:getBuilding()
    if not building then return end
    local squares = freeSquares(it, 200, px, py, near)
    local room = home:getRoom()
    for i = 1, #guards - zombiesIn(building) do
        local g = guards[i]
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
        spawn(sq, g.outfit, g.female, false, g.look == "fakeDead", g.look == "sitting")
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
