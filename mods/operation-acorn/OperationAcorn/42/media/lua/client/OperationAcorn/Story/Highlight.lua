-- The container a mission's item lies in, lit (DESIGN-terminal 9): when it is on the character's floor, within six squares
-- and in sight, the game's own object outline is turned on in the mission's colour (teal; a story mission sky blue; the
-- search ledger's amber outline is its own), and the item's name in the loot window is painted in it too. The item's
-- tooltip says "mission item" first (Trade/ItemTip). Nothing is looked for in the world: this mod put the piece there
-- and wrote its square (piece.at) in the record, so every half second (real time) the pieces' squares are measured
-- against the character, and only for one that is near is its square looked at, for the container that holds the item.
-- A piece taken out of its container is not found there, and the outline goes. The work stops when there is no mission
-- to look for. The first time a piece is lit, the character says so (Spotted).
require "ISUI/ISInventoryPane"
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Say"
require "OperationAcorn/Story/View"
require "OperationAcorn/Story/Missions"
local OA = OperationAcorn
local View, Missions = OA.StoryView, OA.Missions
local Highlight = {}
OA.StoryHighlight = Highlight

-- Spotted: a piece first seen lit. Line 4 for one in a container, 5 for one on the floor, the rest either.
OA.Say.define("Spotted", { tags = { [4] = { container = true }, [5] = { container = false } } })

-- The objects lit now, by the character's number: object -> its colour. The search ledger leaves these to this part.
local lit = {}
Highlight.lit = lit

-- The loot panes whose item names are painted: pane -> true (weak: a pane that is gone drops out).
local tinted = setmetatable({}, { __mode = "k" })

-- The look runs on the extension API's timer when it has one (`slot`: OA.timerOn), else on a handler of OnTick
-- (`ticking`) that compares the clock each frame. The look only outlines and paints: it may go on while the game is paused.
local ticking = false
local slot = {}
local last = {}
local EMPTY = {}

-- The items of a container that carry a mission mark: { { item, id } ... }. Found by one walk through the container, and
-- kept while its signature (OA.signature: how many items, what they weigh) is the same, so that the half-second look
-- does not walk a container of thousands of items again and again. container -> { key, list } (weak: a container that
-- is gone drops out).
local marked = setmetatable({}, { __mode = "k" })

local function markedIn(container)
    local key = OA.signature(container)
    local hit = marked[container]
    if hit and hit.key == key then return hit.list end
    local list = {}
    -- oa-scan: ok (once for each signature of the container)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:hasModData() then
            local id = item:getModData().OA_Mission
            if id then list[#list + 1] = { item = item, id = id } end
        end
    end
    marked[container] = { key = key, list = list }
    return list
end

-- Whether the container holds an item whose OA_Mission is this id.
local function holds(container, id)
    for _, entry in ipairs(markedIn(container)) do
        if entry.id == id then return true end
    end
    return false
end

-- Puts into `want` the objects of a square that hold a piece, with the colour to light them: the furniture whose
-- container has it, the item on the floor that is it (or, for a case that holds the piece, the case while the piece is
-- in it). Returns "container" or "floor" when something holds it, else nil.
local function find(square, id, inner, want, color)
    local found
    local objects = square:getObjects()
    for j = 0, objects:size() - 1 do
        local object = objects:get(j)
        for k = 0, object:getContainerCount() - 1 do
            if holds(object:getContainerByIndex(k), id) then
                want[object] = color
                found = "container"
                break
            end
        end
    end
    local floor = square:getWorldObjects()
    for j = 0, floor:size() - 1 do
        local world = floor:get(j)
        local item = world:getItem()
        if item and item:hasModData() and item:getModData().OA_Mission == id then
            if not inner or (instanceof(item, "InventoryContainer") and holds(item:getInventory(), inner)) then
                want[world] = color
                found = found or "floor"
            end
        end
    end
    return found
end

-- Adds the objects to light for a mission seen from a character to `want` (object -> colour; made here when nothing is
-- there yet and something is near, so that nothing is made while nothing is near), and the pieces lit to `seen`
-- ({ id, container }). Returns `want`.
local function wanted(m, player, want, seen)
    local color = View.color(m.kind)
    local n = player:getPlayerNum()
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    for _, it in ipairs(m.items) do
        local at = it.at
        if View.isLit(it) and View.near(px, py, pz, at) then
            local square = getCell():getGridSquare(at.x, at.y, at.z)
            if square and square:isCouldSee(n) then
                want = want or {}
                local inner = it.inside and Missions.itemId(m, "A") or nil
                local id = Missions.itemId(m, it.key)
                local found = find(square, id, inner, want, color)
                if found then seen[#seen + 1] = { id = id, container = found == "container" } end
            end
        end
    end
    return want
end

local function setOutline(object, on, n, color)
    if on then object:setOutlineHighlightCol(n, color[1], color[2], color[3], 0.9) end
    object:setOutlineHighlight(n, on)
end

-- Lights the objects in `want` and no others (the ones lit already are lit again: the game, or another part, may have
-- turned an outline off or changed its colour; the container the loot window has open is the game's to colour).
local function lightOnly(n, want, open)
    local mine = lit[n]
    if mine then
        for object in pairs(mine) do
            if not want[object] then setOutline(object, false, n) end
        end
    end
    for object, color in pairs(want) do
        if object ~= open then setOutline(object, true, n, color) end
    end
    lit[n] = (not OA.isEmpty(want)) and want or nil
end

-- The names to paint in the loot window of a character: { [name] = colour } for the missions' items in the container
-- the window shows, or nil.
local function tintOf(page, missions, player)
    local pane = page and page.inventoryPane
    local inventory = pane and pane.inventory
    if not inventory or not page:isVisible() then return pane, nil end
    local names
    for _, entry in ipairs(markedIn(inventory)) do
        for _, m in ipairs(missions) do
            if View.owns(m, entry.id) then
                names = names or {}
                names[entry.item:getName(player)] = View.color(m.kind)
                break
            end
        end
    end
    return pane, names
end

-- The missions to light for a record: the ones open, the main one and the special request.
local function openMissions(record)
    local list = View.shownList(record)
    for i = #list, 1, -1 do
        if list[i].state ~= "open" then table.remove(list, i) end
    end
    return list
end

-- The first piece in `seen` the character has not spotted before: it says so (one line a look). What it has spotted
-- is kept in its mod data by piece, only for the missions open (the others are let go when one is added).
local function spotted(player, seen, missions)
    local data = player:getModData()
    local said = data.OA_Spotted
    for _, s in ipairs(seen) do
        if not (said and said[s.id]) then
            local keep = {}
            for id in pairs(said or EMPTY) do
                for _, m in ipairs(missions) do
                    if View.owns(m, id) then
                        keep[id] = true
                        break
                    end
                end
            end
            keep[s.id] = true
            data.OA_Spotted = keep
            OA.Say.say(player, "Spotted", { container = s.container })
            return
        end
    end
end
Highlight.spotted = spotted

local function look()
    for n = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(n)
        local record = player and not player:isDead() and OA.Client.record(player)
        local missions = openMissions(record)
        local page = getPlayerLoot(n)
        if #missions > 0 then
            local want
            local seen = {}
            for _, m in ipairs(missions) do want = wanted(m, player, want, seen) end
            if seen[1] then spotted(player, seen, missions) end
            local inventory = page and page.inventoryPane and page.inventoryPane.inventory
            lightOnly(n, want or EMPTY, inventory and inventory:getParent() or nil)
            local pane, names = tintOf(page, missions, player)
            if pane then
                pane.oaTint = names
                tinted[pane] = true
            end
        else
            lightOnly(n, EMPTY, nil)
            local pane = page and page.inventoryPane
            if pane then pane.oaTint = nil end
        end
    end
end

local function tick()
    if OA.due(last, "look", getTimestampMs(), View.EVERY_MS) then look() end
end

-- Takes everything back (the mission ended, or the character is gone).
local function clear()
    for n, mine in pairs(lit) do
        for object in pairs(mine) do setOutline(object, false, n) end
        lit[n] = nil
    end
    for pane in pairs(tinted) do pane.oaTint = nil end
end

-- The work is on while a local character has a mission open.
local function update()
    local want = false
    for n = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(n)
        local record = player and OA.Client.record(player)
        if #openMissions(record) > 0 then want = true end
    end
    if want then
        local timed, fresh = OA.timerOn(slot, { ms = View.EVERY_MS }, look)
        if timed then
            if ticking then
                ticking = false
                Events.OnTick.Remove(tick)
            end
            -- (the first look at the next frame, as the handler's)
            if fresh then OA.timerAfter(1, look) end
        elseif not ticking then
            ticking = true
            Events.OnTick.Add(tick)
        end
    elseif ticking or slot.id ~= nil then
        if ticking then Events.OnTick.Remove(tick) end
        ticking = false
        OA.timerOff(slot)
        clear()
    end
end
Highlight.update = update

-- The loot window's item names: the pane draws each name through drawText, so for the frames of a pane that has names
-- to paint, drawText is this (set on the pane, and put back as it was after); the other panes are not touched.
local draw = ISInventoryPane.drawText
local function paintedText(pane, str, x, y, r, g, b, a, font, ...)
    local color = pane.oaTint[str]
    if color then r, g, b = color[1], color[2], color[3] end
    return draw(pane, str, x, y, r, g, b, a, font, ...)
end

local renderdetails = ISInventoryPane.renderdetails
function ISInventoryPane:renderdetails(doDragged, ...)
    if not self.oaTint then return renderdetails(self, doDragged, ...) end
    -- (an instance field of drawText that is there already, another mod's, is kept)
    local previous = rawget(self, "drawText")
    self.drawText = paintedText
    local ok, err = pcall(renderdetails, self, doDragged, ...)
    self.drawText = previous
    if not ok then error(err, 0) end
end

OA.Sync.listen("missions", update)
OA.Sync.listen("all", update)
Events.OnGameStart.Add(update)

return Highlight
