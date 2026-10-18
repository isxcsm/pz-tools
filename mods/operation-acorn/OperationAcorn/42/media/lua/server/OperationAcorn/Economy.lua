-- The economy's world events, on the side that owns the save (alone, the game is its own server):
--   every day: the market's step, the new week's request lists, the shred counts' upkeep;
--   every ten minutes (at most each few real seconds): the codex looks over what the characters carry (crafting,
--     foraging, trades ...);
--   every minute (at most once a real second): a character in a town the world has searched through takes its share
--     of the shop's restock (Towns.enter);
--   every minute, a compare of the game clock with 07:30 and nothing more until then: Branscomb's walkie-talkie, turned
--     on and carried, is looked for (easter egg 5, Eggs.radioLook);
--   a building all searched: asked by the player's search watch (client/OperationAcorn/Economy/Searched.lua) as the
--     character steps away from the last containers, checked against the walk's own counts;
--   a zombie's death: the killer's kill count;
--   an item taken from a container, the floor or a corpse: the cell it came from (the new-region premium), the codex
--   and the story's sample cooler (its clock starts). The pickup is caught by wrapping ISTransferAction:transferItem,
--   the one place the game moves an item between containers; the original runs first and its result is returned as
--   it was.
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
require "OperationAcorn/Economy/Towns"
require "OperationAcorn/Economy/Shred"
require "OperationAcorn/Economy/Buildings"
require "OperationAcorn/Economy/Eggs"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Server"
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

-- Item types the codex never counts, whatever the item: this mod's goods (by the type's module) and the body's
-- overlays (by the display category, which the game sets on an item only as its type's script makes it, so it is the
-- type's). Found by a first Value.info, then they cost one lookup like a known kind. By full type: as big as the game's
-- item list at most. A shop's item is no loot by its own mark, not its type: it is told by that mark (bought).
local notLoot = {}

local function bought(item)
    return item:hasModData() and item:getModData().OA_Bought ~= nil
end

-- The items the codex has settled: by item (weak), the `kinds` table of the codex it was settled for. An item whose kind
-- is known, that is no loot or that is the shop's is that for good (a kind is never taken out of a codex but with the
-- whole table, a new one), so a look at it again costs one lookup here, none of its own reads.
local counted = setmetatable({}, { __mode = "k" })

-- The codex looks at one item (and the items in it, to a depth of three bags). Known kinds, types that are no loot and
-- the shop's goods cost a lookup or two; only a kind not known yet is read whole (Value.info). `bags`, when given,
-- collects the bags whose items were looked at.
local function acquireItem(record, kinds, item, depth, bags)
    if counted[item] ~= kinds then
        local fullType = item:getFullType()
        if not kinds[baseOf(fullType)] and not notLoot[fullType] and not bought(item) then
            local info = OA.Value.info(item)
            OA.Codex.acquire(record, info)
            if not info.bought and not OA.Categories.isLoot(info) then notLoot[fullType] = true end
            -- (a kind the codex did not take, nor ruled out, is looked at again next time)
            if kinds[baseOf(fullType)] or notLoot[fullType] then counted[item] = kinds end
        else
            counted[item] = kinds
        end
    end
    if depth < 3 and instanceof(item, "InventoryContainer") then
        local inside = item:getInventory()
        if bags then bags[#bags + 1] = inside end
        local items = inside:getItems()
        for i = 0, items:size() - 1 do acquireItem(record, kinds, items:get(i), depth + 1, bags) end
    end
end

-- Real milliseconds at least between two looks over a character's inventory. The look follows no game time (a kind is
-- counted when it is first carried, and a pickup is counted as it happens), and ten game minutes are 25 s of real time
-- at the default day length but some 0.6 s fast-forwarded (x40) and less asleep.
Economy.SWEEP_MS = 5000

local sweptAt = {}     -- by record id: the real time (ms) of the last look over the character's inventory
-- By record id: what the last look saw, { inventory, bags = { container ... }, sizes = { n ... } } (the inventory first,
-- then each bag the look went into, with how many items each held). Nothing has come or gone while every count is the
-- same, so the look is skipped then: one call per container, no search on a tick (Core.lua). Items that turn into other
-- ones in place leave a count as it was; a pickup and a found item are counted as they happen (afterPickup, onItemFound).
local swept = {}

local function countOf(container)
    return container:getItems():size()
end

-- Whether the inventory and the bags the last look went into hold as many items as they held then.
local function unchanged(seen, inventory)
    if not seen or seen.inventory ~= inventory then return false end
    if countOf(inventory) ~= seen.sizes[1] then return false end
    for i, bag in ipairs(seen.bags) do
        if countOf(bag) ~= seen.sizes[i + 1] then return false end
    end
    return true
end

local function sweepInventory(character, record, now)
    if not OA.due(sweptAt, record.id, now, Economy.SWEEP_MS) then return end
    local inventory = character:getInventory()
    if unchanged(swept[record.id], inventory) then return end
    local kinds = OA.Codex.section(record).kinds
    local bags = {}
    -- oa-scan: ok (only when a count changed since the last look)
    local items = inventory:getItems()
    for i = 0, items:size() - 1 do acquireItem(record, kinds, items:get(i), 1, bags) end
    local sizes = { countOf(inventory) }
    for i, bag in ipairs(bags) do sizes[i + 1] = countOf(bag) end
    swept[record.id] = { inventory = inventory, bags = bags, sizes = sizes }
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
    if not record then return end
    acquireItem(record, OA.Codex.section(record).kinds, item, 1)
    -- The story's sample cooler starts its clock as it is picked up.
    if OA.Missions and OA.Missions.pickedUp then OA.Missions.pickedUp(record, item) end
end

-- A grab from the floor (ISGrabItemAction): the action moves the item itself in single player, not through
-- ISTransferAction; into what the character carries, from the square it lay on.
local function grabCell(action)
    local world = action.item
    local square = world and world:getSquare()
    local dest = action.destContainer
    if not (square and dest and dest:isInCharacterInventory(action.character)) then return nil end
    return OA.Value.cellKey(square:getX(), square:getY())
end

local hooked, grabHooked = false, false
function Economy.hookTransfers()
    if not hooked and ISTransferAction and ISTransferAction.transferItem then
        hooked = true
        local original = ISTransferAction.transferItem
        ISTransferAction.transferItem = function(self, character, item, src, dest, ...)
            local ok, cell = OA.try("pickup cell", pickupCell, character, item, src, dest)
            local result = original(self, character, item, src, dest, ...)
            if ok and cell then OA.try("pickup bookkeeping", afterPickup, character, result or item, cell) end
            return result
        end
    end
    if not grabHooked and ISGrabItemAction and ISGrabItemAction.transferItem then
        grabHooked = true
        local grab = ISGrabItemAction.transferItem
        ISGrabItemAction.transferItem = function(self, ...)
            -- (a client in multiplayer only asks: the server moves the item)
            local ok, cell = false, nil
            if not isClient() then ok, cell = OA.try("grab cell", grabCell, self) end
            local item = self.item and self.item:getItem()
            local result = grab(self, ...)
            if ok and cell then OA.try("pickup bookkeeping", afterPickup, self.character, item, cell) end
            return result
        end
    end
end

-- The daily upkeep.
function Economy.daily()
    local day = OA.day()
    OA.Market.update(day)
    OA.Market.prune(day)
    OA.Requests.weekly()
    for _, record in pairs(OA.Store.players()) do
        if OA.Store.alive(record) then OA.Shred.daily(record) end
    end
    OA.Value.reset()
end

-- Every ten minutes, at most once each SWEEP_MS of real time: what the characters carry.
function Economy.tenMinutes()
    local now = getTimestampMs()
    eachPlayer(function(character)
        local record = recordOf(character)
        if record then sweepInventory(character, record, now) end
    end)
end

-- Every game minute, at most once a real second: a character who has come into a town the world has searched through
-- takes its share of the shop's faster restock (Towns.enter: nothing is looked up until the world has such a town).
local lastMinute = {}
function Economy.minute()
    if not OA.due(lastMinute, "towns", getTimestampMs(), 1000) then return end
    eachPlayer(function(character)
        local record = recordOf(character)
        if record and OA.Store.alive(record) then
            OA.try("towns enter", OA.Towns.enter, record, character:getX(), character:getY())
        end
    end)
end

-- A building all searched by a record's character: counted once, its bonus more with 철저한 수색's rank 3 (the
-- search ledger), and told from rank 1 by a brief title (a light one: one comes with every building): what the bonus
-- will be (BonusMultiplier in), and at rank 3 how much of it the rank added, so the rank is seen to pay.
function Economy.searched(record, key, total)
    local Rules = OA.Upgrades.Rules
    local u = Rules.section(record)
    local rank = Rules.rank(u, "ledger")
    local mult = rank >= 3 and 1 + Rules.fraction(u, "ledger") or 1
    local credits = OA.Codex.buildingSearched(record, key, total, mult)
    if credits and rank >= 1 then
        local scale = OA.option("BonusMultiplier") or 1.0
        local bonus = math.floor(credits * scale + 0.5)
        local added = math.floor(credits * (mult - 1) / mult * scale + 0.5)
        local title = { key = "IGUI_OA_Title_SearchedBonus", args = { tostring(bonus) }, style = "brief", fallback = "good" }
        if added > 0 then
            title.key = "IGUI_OA_Title_SearchedBonusThorough"
            title.args = { tostring(bonus), tostring(added), { key = "IGUI_OA_Tree_Node_ledger_Name" } }
        end
        OA.Sync.title(record.id, title)
    end
    return credits
end

-- The building `key` all searched, as the character's last look at it found it (OA.Buildings.counts: the walk the
-- search watch keeps, so nothing is walked here): counted once, with its bonus and title. Returns the credits, or nil.
function Economy.checkSearched(character, record, key)
    local searched, total, complete = OA.Buildings.counts(character, key)
    if not searched or not complete or total <= 0 or searched < total then return nil end
    return Economy.searched(record, key, total)
end

OA.Server.on("searched", function(character, record, args)
    if type(args.key) == "string" then Economy.checkSearched(character, record, args.key) end
end)

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

-- A category refused for a while: a title for every record. The market's other events, and the refusal's own line,
-- the delivery tab works out from the market's state.
local function onMarketEvent(event)
    if event.kind ~= "refusal" then return end
    local title = { key = "IGUI_OA_Title_Refusal", sub = "IGUI_OA_Title_RefusalSub",
        subArgs = { { key = OA.Categories.nameKey(event.cat) }, event.days or 7 }, style = "notice",
        fallback = "bad" }
    for _, record in pairs(OA.Store.players()) do
        -- (told only to who trades: a character who has not used the terminal yet knows nothing of the market)
        if OA.Store.alive(record) and OA.Trust.contacted(record) then OA.Sync.title(record.id, title) end
    end
end

local started = false
function Economy.start()
    if started then return end
    started = true
    OA.Market.update(OA.day())
    OA.Requests.data()
    OA.Market.listen(onMarketEvent)
    Economy.hookTransfers()
end

-- Every game minute: at 07:30 the characters' walkie-talkies (the egg's, a record that has not had it). Not throttled,
-- the minute is the only one of the day; the clock alone is read on every other.
function Economy.eggMinute()
    if not OA.Eggs.radioTime() then return end
    eachPlayer(function(character)
        local record = recordOf(character)
        if record and OA.Store.alive(record) then
            OA.try("easter egg radio", OA.Eggs.radioLook, record, character)
        end
    end)
end

Events.EveryDays.Add(Economy.daily)
Events.EveryTenMinutes.Add(Economy.tenMinutes)
Events.EveryOneMinute.Add(Economy.minute)
Events.EveryOneMinute.Add(Economy.eggMinute)
Events.OnZombieDead.Add(onZombieDead)
Events.OnItemFound.Add(onItemFound)
Events.OnGameStart.Add(Economy.start)
Events.OnServerStarted.Add(Economy.start)

return Economy
