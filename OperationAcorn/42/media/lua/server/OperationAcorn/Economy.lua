-- The economy's world events, on the side that owns the save (alone, the game is its own server):
--   every day: the market's step, the new week's request lists, the shred counts' upkeep;
--   every ten minutes: the codex looks over what the characters carry (crafting, foraging, trades ...);
--   every minute: the building a character stands in, for "all containers searched";
--   a zombie's death: the killer's kill count;
--   an item taken from a container, the floor or a corpse: the cell it came from (the new-region premium) and the
--   codex. The pickup is caught by wrapping ISTransferAction:transferItem, the one place the game moves an item
--   between containers; the original runs first and its result is returned as it was.
-- Nothing here runs per tick, per frame or per square.
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Market"
require "OperationAcorn/Economy/Requests"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Economy/Codex"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Economy/Shred"
require "OperationAcorn/Economy/Buildings"
local OA = OperationAcorn
local Economy = {}
OA.Economy = Economy

-- Calls fn(character) for each character this side looks after.
local function eachPlayer(fn)
    if isServer() then
        local list = getOnlinePlayers()
        for i = 0, list:size() - 1 do fn(list:get(i)) end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player and not player:isDead() then fn(player) end
        end
    end
end

-- The record of a character, or nil if it has none yet (its first hello makes it).
local function recordOf(character)
    local data = character:getModData()
    local id = data and data.OA_Id
    return id and OA.Store.player(id) or nil
end
Economy.recordOf = recordOf

-- A kind's base type from an item type, remembered: the same few hundred names come up all day.
local baseTypes = {}
local function baseOf(fullType)
    local base = baseTypes[fullType]
    if not base then
        base = OA.Categories.baseType(fullType)
        baseTypes[fullType] = base
    end
    return base
end

-- The codex looks at one item (and the items in it, to a depth of three bags). Known kinds cost one lookup.
local function acquireItem(record, kinds, item, depth)
    if not kinds[baseOf(item:getFullType())] then
        OA.Codex.acquire(record, OA.Value.info(item))
    end
    if depth < 3 and instanceof(item, "InventoryContainer") then
        local items = item:getInventory():getItems()
        for i = 0, items:size() - 1 do acquireItem(record, kinds, items:get(i), depth + 1) end
    end
end

local function sweepInventory(character, record)
    local kinds = OA.Codex.section(record).kinds
    local items = character:getInventory():getItems()
    for i = 0, items:size() - 1 do acquireItem(record, kinds, items:get(i), 1) end
end

-- Tags an item, and what is inside it, with the cell it came from. An item keeps the first cell it was tagged with.
local function tagCell(item, cell, budget)
    if budget.left <= 0 then return end
    budget.left = budget.left - 1
    local data = item:getModData()
    if not data.OA_Cell then data.OA_Cell = cell end
    if instanceof(item, "InventoryContainer") then
        local items = item:getInventory():getItems()
        for i = 0, items:size() - 1 do tagCell(items:get(i), cell, budget) end
    end
end

-- What a pickup is: from a container of the world (or the floor, a corpse, a vehicle) into what the character
-- carries. Returns the cell key of where it was taken, or nil when it is some other move.
local function pickupCell(character, item, src, dest)
    if not src or not dest then return nil end
    if src == dest then return nil end
    if src:getType() == "TradeUI" or dest:getType() == "TradeUI" then return nil end
    if not dest:isInCharacterInventory(character) or src:isInCharacterInventory(character) then return nil end
    local square = src:getSquare()
    if not square then
        local world = item:getWorldItem()
        square = world and world:getSquare()
    end
    if not square then return nil end
    return OA.Value.cellKey(square:getX(), square:getY())
end

local function afterPickup(character, item, cell)
    if not item then return end
    tagCell(item, cell, { left = 200 })
    local record = recordOf(character)
    if record then acquireItem(record, OA.Codex.section(record).kinds, item, 1) end
end

local hooked = false
function Economy.hookTransfers()
    if hooked or not ISTransferAction or not ISTransferAction.transferItem then return end
    hooked = true
    local original = ISTransferAction.transferItem
    ISTransferAction.transferItem = function(self, character, item, src, dest, square)
        local ok, cell = pcall(pickupCell, character, item, src, dest)
        local result = original(self, character, item, src, dest, square)
        if ok and cell then
            local done, err = pcall(afterPickup, character, result or item, cell)
            if not done then OA.log("pickup bookkeeping failed:", tostring(err)) end
        end
        return result
    end
end

-- The daily upkeep.
function Economy.daily()
    local day = OA.day()
    OA.Market.update(day)
    OA.Market.prune(day)
    OA.Requests.weekly()
    for _, record in pairs(OA.Store.players()) do OA.Shred.daily(record) end
    OA.Value.reset()
end

-- Every ten minutes: what the characters carry.
function Economy.tenMinutes()
    eachPlayer(function(character)
        local record = recordOf(character)
        if record then sweepInventory(character, record) end
    end)
end

-- Every minute: the building each character stands in. All of a building's containers searched: it is counted once.
function Economy.minute()
    eachPlayer(function(character)
        local key, searched, total, complete = OA.Buildings.tick(character)
        if not key then return end
        OA.Codex.setBuildingProgress(key, searched, total)
        if complete and total > 0 and searched >= total then
            local record = recordOf(character)
            if record then OA.Codex.buildingSearched(record, key, total) end
        end
    end)
end

local function onZombieDead(zombie)
    local killer = zombie:getAttackedBy()
    if killer and instanceof(killer, "IsoPlayer") then
        local record = recordOf(killer)
        if record then OA.Codex.kill(record, 1) end
    end
end

-- A found item (foraging) enters the codex by its type.
local function onItemFound(character, itemType)
    if not character or not itemType then return end
    local record = recordOf(character)
    if record and not OA.Codex.section(record).kinds[baseOf(itemType)] then
        OA.Codex.acquireType(record, itemType)
    end
end

-- The market's events as lines in every record's radio log (the trade part keeps the log). A category refused for a
-- while has the story part's line (or this part's own); the others are this part's.
local function onMarketEvent(event)
    local key, args
    if event.kind == "refusal" then
        key, args = OA.Market.refusalLine(event.cat, "start")
    else
        key = event.key
        if not key then
            key = event.kind == "glut" and "IGUI_OA_Econ_Event_Glut" or "IGUI_OA_Econ_Event_Demand"
        end
        args = { getText(OA.Categories.nameKey(event.cat)) }
    end
    for _, record in pairs(OA.Store.players()) do OA.Market.radioTo(record, key, args) end
end

-- A refused category that has come back as a request: its line, once, to the record whose list it joined.
local function onRequestBack(record, category)
    local key, args = OA.Market.refusalLine(category, "back")
    OA.Market.radioTo(record, key, args)
end

local started = false
function Economy.start()
    if started then return end
    started = true
    OA.Market.update(OA.day())
    OA.Requests.data()
    OA.Market.listen(onMarketEvent)
    OA.Requests.listenBack(onRequestBack)
    Economy.hookTransfers()
end

Events.EveryDays.Add(Economy.daily)
Events.EveryTenMinutes.Add(Economy.tenMinutes)
Events.EveryOneMinute.Add(Economy.minute)
Events.OnZombieDead.Add(onZombieDead)
Events.OnItemFound.Add(onItemFound)
Events.OnGameStart.Add(Economy.start)
Events.OnServerStarted.Add(Economy.start)

return Economy
