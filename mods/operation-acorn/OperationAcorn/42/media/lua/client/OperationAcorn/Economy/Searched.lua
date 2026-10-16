-- The search watch: the building the character is in, its containers searched, and what is told of it, all on the
-- loot window's own refresh (ISInventoryPage:refreshBackpacks, which the game runs when the character steps onto
-- another square or turns, and when a container's contents change). Nothing here runs per frame or on the game's
-- clock (so a paused or held clock does not stop it), and while the character stands, nothing runs at all.
--   * Each container the window lists is marked as looked into (OA.Buildings.mark, at checkExplored, where the game
--     rolls the loot of one not rolled yet), once an object. Not the game's explored flag: the game sets that as the
--     square loads.
--   * Coming into a building, or a container marked in it, is a look (OA.Buildings.tick: the walk, in Java through
--     the API): the progress the terminal shows, the ledger's lines (철저한 수색), and whether the building is now all
--     searched.
--   * What a look found is told once the character steps away from the containers that made it (none of them is
--     listed any more), not while it is still looting them: the building all searched (the economy's check, with
--     its bonus and title), or a further stage of the floor.
--   * The ledger's outlines (rank 2) are made again on a new square or a container marked. A slow timer (SIGHT_MS, on
--     the API's timers: no frame wakes Lua in between) catches only what changes the sight while the character
--     stands (a door opened), and runs only while there are outlines to keep.
--   * A building not counted whole yet (a square not loaded) is looked at again each RELOOK_MS while the character
--     is in it.
--   * A square under a roof with no room (a stairwell, a doorway) is still the building the character is in, so going
--     up or down is a floor of the same building (the ledger tells a floor all searched), not leaving and entering.
require "ISUI/ISInventoryPage"
require "OperationAcorn/Sync"
require "OperationAcorn/Economy/Buildings"
local OA = OperationAcorn
local Watch = {}
OA.SearchWatch = Watch

local SIGHT_MS = 1000
local RELOOK_MS = 1000

local listing = false   -- the loot window's refresh is going on
local listed = {}       -- container -> true: the containers it lists
local fresh = {}        -- those it marked for the first time

-- The building the character is in (key) and the room it was asked for, the square of the last refresh and its
-- floor, what waits to be told ({ key, done, line, near = the containers that made it }), the building the economy
-- was asked about on entering, and whether a look again is due.
local state = { player = 0, key = nil, room = nil, square = nil, z = nil, pending = nil, asked = nil, relook = false }
local sightSlot = {}

local function senses()
    return OA.Upgrades and OA.Upgrades.Senses
end

local function wipe(t)
    for k in pairs(t) do t[k] = nil end
end

local function stopSight()
    if sightSlot.id then OA.timerOff(sightSlot) end
end

-- The ledger's outlines, and the slow check of sight while there are any to keep.
local function outline(player)
    local S = senses()
    if S and state.key and S.ledgerOutline(player) then
        OA.timerOn(sightSlot, { ms = SIGHT_MS }, function()
            local p = getSpecificPlayer(state.player)
            local s = senses()
            if p and state.key and s and s.ledgerOutline(p) then return end
            stopSight()
        end)
    else
        stopSight()
    end
end

-- Tells what waits: the building all searched (the economy checks it against the walk), or the floor's stage line
-- (held on while the last line is too recent).
local function tell(player, now)
    local p = state.pending
    if p.done then
        state.pending = nil
        OA.Sync.send(player, "searched", { key = p.key })
        local S = senses()
        if S then S.ledgerDone(player, now) end
    else
        local S = senses()
        if not S or S.ledgerSay(player, p.line, now) then state.pending = nil end
    end
end

-- A look at the building the character is in. `marked`: containers were marked in this refresh (what they make is
-- held until the character steps away from them).
local function look(player, now, marked)
    local key, opened, total, complete = OA.Buildings.tick(player)
    if not key then return end
    local S = senses()
    local line = S and S.ledgerLook(player, key, opened, total, complete, now) or nil
    local done = complete and total > 0 and opened >= total
    if marked then
        if done or line then
            local near = {}
            for i = 1, #fresh do near[fresh[i]] = true end
            state.pending = { key = key, done = done, line = not done and line or nil, near = near }
        end
    elseif done and state.asked ~= key then
        -- all searched before the character came in (it stepped away from the last container in another session):
        -- the economy knows whether it was counted
        state.asked = key
        OA.Sync.send(player, "searched", { key = key })
    end
    if not complete and not state.relook then
        state.relook = OA.timerAfter(RELOOK_MS, function()
            state.relook = false
            local p = getSpecificPlayer(state.player)
            if p and not p:isDead() and state.key == key then
                look(p, getTimestampMs(), false)
                outline(p)
            end
        end)
    end
end

-- After a refresh of the loot window (not the character's own inventory page).
function Watch.refreshed(page)
    local player = getSpecificPlayer(page.player)
    if not player or player:isDead() then return end
    state.player = page.player
    local square = player:getCurrentSquare()
    local moved = square ~= state.square
    state.square = square
    local marked = #fresh > 0
    if not moved and not marked and not state.pending then return end
    local now = getTimestampMs()
    local key = state.key
    local room = square and square:getRoom()
    if room ~= state.room then
        state.room = room
        if room then
            key = OA.Buildings.keyAt(square, room)
        elseif not square or square:isOutside() then
            key = nil
        end
    end
    local entered = key ~= state.key
    -- a floor's line is out of place once out of the building (the building all searched is told as it is left)
    if entered and state.pending and not state.pending.done then state.pending = nil end
    local p = state.pending
    if p then
        local near = false
        for c in pairs(p.near) do
            if listed[c] then
                near = true
                break
            end
        end
        if not near then tell(player, now) end
    end
    if not moved and not marked then return end
    local z = square and square:getZ()
    local otherFloor = not entered and key ~= nil and z ~= state.z
    state.z = z
    if entered then
        state.key = key
        local S = senses()
        if S then S.ledgerLeave() end
        if key then look(player, now, marked) end
    elseif key and marked then
        look(player, now, true)
    end
    if otherFloor then
        local S = senses()
        if S then S.ledgerFloor(player, now) end
    end
    if key then outline(player) else stopSight() end
end

-- Forgets the building and what waits (the developer panel's search reset).
function Watch.reset()
    state.key, state.room, state.square, state.z, state.pending, state.asked = nil, nil, nil, nil, nil, nil
    stopSight()
end

-- A building a container was first looked into: the story keeps it as searched (no story site is set up in a building
-- the player has been through). Told once a building a session; the key is the building's def corner, as the story's.
local toldTouched = {}
local function touched(container, playerObj)
    local object = container:getParent()
    local square = object and object:getSquare()
    local building = square and square:getBuilding()
    local def = building and building:getDef()
    if not def then return end
    local key = tostring(def:getX()) .. "," .. tostring(def:getY())
    if toldTouched[key] then return end
    toldTouched[key] = true
    OA.Sync.send(playerObj, "story_touched", { key = key })
end

local checkExplored = ISInventoryPage.checkExplored
function ISInventoryPage:checkExplored(container, playerObj, ...)
    checkExplored(self, container, playerObj, ...)
    if not container or not playerObj or not playerObj:isLocalPlayer() then return end
    local new = OA.Buildings.mark(container)
    if new then touched(container, playerObj) end
    if listing then
        listed[container] = true
        if new then fresh[#fresh + 1] = container end
    end
end

local refreshBackpacks = ISInventoryPage.refreshBackpacks
function ISInventoryPage:refreshBackpacks(...)
    if self.onCharacter then return refreshBackpacks(self, ...) end
    wipe(listed)
    wipe(fresh)
    listing = true
    local ok, err = pcall(refreshBackpacks, self, ...)
    listing = false
    if not ok then error(err, 0) end
    Watch.refreshed(self)
end

return Watch
