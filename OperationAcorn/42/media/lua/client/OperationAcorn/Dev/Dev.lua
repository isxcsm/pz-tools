-- Debug only: helpers for checking each part in a running game (single player), meant to be called through the
-- command channel (Dev/Remote.lua, tools/pzdev.py) or the Lua console. They change the save: use a test save.
-- Each prints what it did as "[dev] ..." lines and returns something a check can test.
if not isDebugEnabled() then return end
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Trust"
local OA = OperationAcorn
local Dev = {}
OA.Dev = Dev

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[dev] " .. table.concat(parts, " "))
end
Dev.say = say

-- ---- the character and its record ------------------------------------------------------------------------------

function Dev.player()
    return getPlayer()
end

-- The local character's record (made by the mod's first hello), or nil.
function Dev.record()
    local player = getPlayer()
    local id = player and player:getModData().OA_Id
    return id and OA.Store.player(id) or nil
end

-- Tells the screens and the effects a section of the record changed.
function Dev.changed(section)
    local record = Dev.record()
    if record then OA.Sync.changed(section or "all", record.id) end
end

-- ---- research --------------------------------------------------------------------------------------------------

local function upgrades()
    local record = Dev.record()
    if not record then error("no record yet", 3) end
    return OA.Upgrades.Rules.section(record), record
end

-- Sets research ranks as given ({ night = 3, nightEye = 1, bSense = 4 }; 0 takes a node away). The trees of the
-- ranks open; nothing is paid. Applies the effects at once.
function Dev.ranks(list)
    local u, record = upgrades()
    local Data = OA.Upgrades.Data
    for id, rank in pairs(list) do
        local node = Data.byId[id]
        if not node then error("no node " .. tostring(id), 2) end
        local value = rank > 0 and rank or nil
        if node.board then
            u.board.ranks[id] = value
        else
            u.ranks[id] = value
            u.opened[node.tree] = true
        end
    end
    OA.Sync.changed("upgrades", record.id)
    if OA.Upgrades.Effects then OA.Upgrades.Effects.apply(record) end
    say("ranks", Dev.describe(list))
    return u
end

-- Takes every rank away and empties the points (a fresh research record).
function Dev.clearResearch()
    local u, record = upgrades()
    for k in pairs(u) do u[k] = nil end
    OA.Upgrades.Rules.fill(u)
    OA.Sync.changed("upgrades", record.id)
    if OA.Upgrades.Effects then OA.Upgrades.Effects.apply(record) end
    say("research cleared")
    return u
end

-- Gives points of a tree ("scout", "load", "survival"; "shared" for shared serums) as if that many were injected.
function Dev.points(tree, n)
    local u, record = upgrades()
    local Rules = OA.Upgrades.Rules
    for _ = 1, n do
        if tree == "shared" then Rules.injectShared(u) else Rules.inject(u, tree) end
    end
    OA.Sync.changed("upgrades", record.id)
    say("points", tree, n)
    return u
end

-- ---- trade -----------------------------------------------------------------------------------------------------

function Dev.credits(n)
    local record = Dev.record()
    OA.Store.section(record, "trade").credits = n
    OA.Sync.changed("trade", record.id)
    say("credits", n)
end

-- Sets trust to an amount, with the stage and milestones it makes (the rewards of passing them are not given).
function Dev.trust(amount)
    local record = Dev.record()
    local trade = OA.Store.section(record, "trade")
    trade.trust = amount
    trade.stage, trade.milestones = OA.Trust.levelFor(amount)
    OA.Sync.changed("trade", record.id)
    say("trust", amount, "stage", trade.stage, "milestones", trade.milestones)
end

-- ---- the world -------------------------------------------------------------------------------------------------

-- The hour of the day (0..24), at once.
function Dev.time(hour)
    getGameTime():setTimeOfDay(hour)
    say("time", hour)
end

-- The game speed: 1 normal, 2..4 the fast-forward steps (the speed buttons), 0 paused.
function Dev.speed(n)
    UIManager.getSpeedControls():SetCurrentGameSpeed(n)
    say("speed", n)
end

-- Stops rain, snow and thunder.
function Dev.clearWeather()
    getClimateManager():stopWeatherAndThunder()
    say("weather cleared")
end

local DIRS = { N = "N", NE = "NE", E = "E", SE = "SE", S = "S", SW = "SW", W = "W", NW = "NW" }

-- Turns the character to face a compass way ("N", "SE" ...: the map's north is up and to the right on screen).
function Dev.face(dir)
    local player = getPlayer()
    local d = IsoDirections[DIRS[dir] or "S"]
    player:setDir(d)
    if player.setForwardDirection then player:setForwardDirection(d:ToVector()) end
    say("face", dir)
end

-- Zombies at offsets from the character, made harmless and still (useless): { { dx, dy, n }, ... }, dz optional as a
-- fourth number. Returns how many.
function Dev.zombies(spots)
    local player = getPlayer()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local made = 0
    for _, s in ipairs(spots) do
        local list = addZombiesInOutfit(px + s[1], py + s[2], pz + (s[4] or 0), s[3] or 1, "Generic01", 50)
        for i = 0, list:size() - 1 do
            local z = list:get(i)
            z:setUseless(true)
            made = made + 1
        end
    end
    say("zombies", made)
    return made
end

-- Removes the zombies within a radius of the character (all loaded ones without a radius). Returns how many.
function Dev.clearZombies(radius)
    local player = getPlayer()
    local list = getCell():getZombieList()
    local gone = 0
    for i = list:size() - 1, 0, -1 do
        local z = list:get(i)
        if not radius or IsoUtils.DistanceTo(z:getX(), z:getY(), player:getX(), player:getY()) <= radius then
            z:removeFromWorld()
            z:removeFromSquare()
            gone = gone + 1
        end
    end
    say("zombies removed", gone)
    return gone
end

-- A world sound at an offset from the character (what zombies and the presence marks hear).
function Dev.sound(dx, dy, radius, volume)
    local player = getPlayer()
    local x, y, z = math.floor(player:getX()) + dx, math.floor(player:getY()) + dy, math.floor(player:getZ())
    addSound(nil, x, y, z, radius or 30, volume or 30)
    say("sound at", dx, dy)
end

-- ---- a place to try everything by hand ------------------------------------------------------------------------

-- One of each thing the mod puts in the world, working, on clear open ground near the character, for a person to try
-- the windows and menus by hand: a terminal with power, a delivery box, a sealed supply crate, every machine facing
-- south, a running generator among them (the terminal and most machines need power), the heavy items (terminal, box,
-- crate, a bench) on the ground to try placing, and one of each usable item in the inventory (serums issued to this
-- character, the cure among them, kits, parts, fuel cans, documents to read). The character is put south of it all.
-- Dev.clearShowroom() takes everything away again, after a reload too (the area is kept in the character's modData).
-- Returns the area's corner, or nil when no clear ground is near.
local SHOW_W, SHOW_H = 16, 11
local SHOW_ITEMS = {
    { "UpgradeSerumScout", 2 }, { "UpgradeSerumLoad", 2 }, { "UpgradeSerumSurvival", 2 }, { "UpgradeSerumShared", 2 },
    { "CureSerum", 1, issued = true }, { "DelayDrug", 2 }, { "DelayDrugLong", 2 }, { "InfectionReversal", 1 },
    { "InfectionTestKit", 2 },
    { "KitBagCapacity", 1 }, { "KitBagWeight", 1 }, { "KitTrunk", 1 }, { "KitEngine", 1 }, { "KitVoucher", 1 },
    { "TeamBackpack", 1 }, { "FuelCanMk1", 1 }, { "FuelCanMk2", 1 }, { "FuelCanMk3", 1 },
    { "TerminalManual", 1 }, { "SupplyManifest", 1 }, { "SampleBundle", 3 }, { "MeteorFragment", 3 },
    { "MotorNormal", 1 }, { "ShredBladeNormal", 1 }, { "CutBladeNormal", 1 }, { "SawBladeNormal", 1 },
    { "FilterNormal", 1 }, { "SoundproofCover", 1 },
    { "EvidenceEnvelope", 1 }, { "ClinicRecord", 1 }, { "WeatherLog", 1 }, { "SerumSheet", 1 }, { "HandoverFile", 1 },
}
local SHOW_GROUND = { "CommTerminal", "DeliveryBox", "ShredBench" } -- the bench as its pieces
-- The machines: kind and anchor (dx, dy) in the area, all facing south.
local SHOW_MACHINES = {
    { "shredBench", 1, 4 }, { "bulkShredder", 4, 4 }, { "cutter", 7, 4 }, { "woodSaw", 10, 4 },
    { "researchStorage", 13, 4 }, { "propaneRefiner", 1, 7 }, { "oilRefiner", 5, 7 }, { "rainStorage", 9, 7 },
    { "lure", 13, 7 },
}
local show = nil   -- what Dev.showroom made: { objects, machines, generator, ground, items }

-- Whether the area with its corner at (x, y) on the ground floor is open ground with nothing on it.
local function openArea(x, y)
    local cell = getCell()
    for dx = 0, SHOW_W - 1 do
        for dy = 0, SHOW_H - 1 do
            local sq = cell:getGridSquare(x + dx, y + dy, 0)
            -- a fence or a wall on a square's north or west side would split the area
            local flags = sq and sq:getProperties()
            if not sq or not sq:isOutside() or sq:getBuilding() or sq:HasTree() or not OA.Trade.Objects.free(sq)
                or flags:has(IsoFlagType.collideN) or flags:has(IsoFlagType.collideW) then
                return false
            end
        end
    end
    return true
end

function Dev.showroom()
    Dev.clearShowroom()
    local player = getPlayer()
    local record = Dev.record()
    if not record then say("showroom: no record yet") return nil end
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local corner = OA.Trade.Objects.search(px, py, 0, 40, function(sq) return openArea(sq:getX(), sq:getY()) end)
    if not corner then say("showroom: no clear", SHOW_W, "x", SHOW_H, "ground within 40") return nil end
    local cell = getCell()
    local x0, y0 = corner:getX(), corner:getY()
    local function at(dx, dy) return cell:getGridSquare(x0 + dx, y0 + dy, 0) end
    local inv = player:getInventory()
    show = { objects = {}, machines = {}, ground = {}, items = {} }

    -- power first: a generator, fuelled and running, in the middle of the first row
    local gen = IsoGenerator.new(instanceItem("Base.Generator"), cell, at(7, 1))
    gen:setConnected(true)
    gen:setFuel(100)
    gen:setActivated(true)
    show.generator = gen

    local T = OA.Trade
    local okT, terminal = T.Things.placeTerminal(player, at(1, 1), "S", inv:AddItem("OperationAcorn.CommTerminal"))
    if okT then show.objects[#show.objects + 1] = terminal end
    local okB, box = T.Things.placeBox(player, record, at(13, 1), inv:AddItem("OperationAcorn.DeliveryBox"))
    if okB then show.objects[#show.objects + 1] = box end
    show.objects[#show.objects + 1] = T.Things.makeCrate(at(10, 1),
        { { type = "Base.Battery", count = 2 }, { type = "OperationAcorn.SampleBundle", count = 2 } }, false)

    local M = OA.Machines
    local placed = 0
    for _, m in ipairs(SHOW_MACHINES) do
        local sq = at(m[2], m[3])
        local ok, why = M.canPlace(m[1], sq, "S")
        if ok then
            local item = inv:AddItem(M.itemFullType(m[1]))
            local object = M.place(m[1], sq, player, item, "S")
            if item:getContainer() then item:getContainer():Remove(item) end
            if object then
                show.machines[#show.machines + 1] = object
                placed = placed + 1
            end
        else
            say("showroom:", m[1], "not placed:", tostring(why))
        end
    end

    -- the heavy items on the ground beside the terminal, to pick up and place
    for i, name in ipairs(SHOW_GROUND) do
        local sq = at(3 + (i - 1) % 2, 1 + math.floor((i - 1) / 2))
        local pieces = M.deliveryItems("OperationAcorn." .. name)
        for _, item in ipairs(pieces or { "OperationAcorn." .. name }) do
            show.ground[#show.ground + 1] = sq:AddWorldInventoryItem(item, 0.5, 0.5, 0)
        end
    end

    for _, entry in ipairs(SHOW_ITEMS) do
        for _ = 1, entry[2] do
            local item = inv:AddItem("OperationAcorn." .. entry[1])
            if item then
                if entry.issued then
                    item:getModData().OA_Issued = OA.hours()
                    item:getModData().OA_Owner = record.id
                end
                show.items[#show.items + 1] = item
            end
        end
    end

    player:getModData().OA_Showroom = { x = x0, y = y0 }
    -- the character south of it all, facing it
    player:setX(x0 + 8.5)
    player:setY(y0 + SHOW_H - 0.5)
    player:setLastX(player:getX())
    player:setLastY(player:getY())
    player:setDir(IsoDirections.N)
    say("showroom at", x0, y0, "terminal", tostring(okT), "box", tostring(okB), "machines", placed, "of",
        #SHOW_MACHINES, "items", #show.items, "powered", tostring(OA.Trade.Objects.powered(at(1, 1))))
    return x0, y0
end

-- Takes away what Dev.showroom made (the delivery box out of the record too) and the items it gave that are still
-- in the inventory. After a reload (its list gone) it sweeps the area it kept: the mod's objects and machines, the
-- generators and the mod's items on the ground there; the items it gave stay in the inventory.
function Dev.clearShowroom()
    local player = getPlayer()
    local area = player:getModData().OA_Showroom
    player:getModData().OA_Showroom = nil
    if not show and not area then return end
    local T = OA.Trade
    if not show then
        local cell, swept = getCell(), 0
        for dx = 0, SHOW_W - 1 do
            for dy = 0, SHOW_H - 1 do
                local sq = cell:getGridSquare(area.x + dx, area.y + dy, 0)
                local anchor = sq and OA.Machines.at(sq)
                if anchor and OA.Machines.state(anchor) then
                    OA.Machines.remove(anchor)
                    swept = swept + 1
                end
                local objects = sq and sq:getObjects()
                for i = (objects and objects:size() or 0) - 1, 0, -1 do
                    local o = objects:get(i)
                    if T.Objects.kindOf(o) then
                        T.Things.destroyed(o)
                        T.Objects.remove(o)
                        swept = swept + 1
                    elseif instanceof(o, "IsoGenerator") then
                        o:setActivated(false)
                        sq:transmitRemoveItemFromSquare(o)
                        swept = swept + 1
                    elseif instanceof(o, "IsoWorldInventoryObject") and o:getItem()
                        and o:getItem():getModule() == "OperationAcorn" then
                        sq:transmitRemoveItemFromSquare(o)
                        swept = swept + 1
                    end
                end
            end
        end
        say("showroom swept", swept)
        return
    end
    for _, object in ipairs(show.objects) do
        if object:getSquare() then
            T.Things.destroyed(object)
            T.Objects.remove(object)
        end
    end
    for _, object in ipairs(show.machines) do
        if OA.Machines.state(object) then OA.Machines.remove(object) end
    end
    local gen = show.generator
    if gen and gen:getSquare() then
        gen:setActivated(false)
        gen:getSquare():transmitRemoveItemFromSquare(gen)
    end
    for _, item in ipairs(show.ground) do
        local world = item:getWorldItem()
        if world and world:getSquare() then world:getSquare():transmitRemoveItemFromSquare(world) end
    end
    local taken = 0
    for _, item in ipairs(show.items) do
        local container = item:getContainer()
        if container then
            container:Remove(item)
            taken = taken + 1
        end
    end
    show = nil
    say("showroom cleared, items taken back", taken)
end

-- ---- screens ---------------------------------------------------------------------------------------------------

-- Shows or hides the game's Lua console (the channel needs none; a picture should not have it).
function Dev.console(show)
    local console = UIManager.getDebugConsole()
    if console then console:setVisible(show == true) end
end

-- Closes the character info window (where the research tab is) and the Lua console.
function Dev.closeWindows()
    local info = getPlayerInfoPanel(0)
    if info and info:getIsVisible() then info:close() end
    Dev.console(false)
    say("windows closed")
end

-- A short state line: time, speed, weather, the character's place and facing, zombies near.
function Dev.state()
    local player = getPlayer()
    local near = 0
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if IsoUtils.DistanceTo(z:getX(), z:getY(), player:getX(), player:getY()) <= 30 then near = near + 1 end
    end
    say("time", string.format("%.2f", getGameTime():getTimeOfDay()), "speed", getGameTime():getTrueMultiplier(),
        "daylight", string.format("%.2f", getClimateManager():getDayLightStrength()),
        "at", math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()),
        "facing", tostring(player:getDir()), "zombies within 30", near)
end

function Dev.describe(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    table.sort(parts)
    return table.concat(parts, " ")
end

return Dev
