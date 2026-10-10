-- What the server answers and watches for the trade part: the terminal's commands, the ten-minute work (arrivals, the
-- first supply, marks, lost boxes, the terminal's light; the last three at most once each few real seconds) and the
-- work that waits for a chunk to load.
require "OperationAcorn/Server"
require "OperationAcorn/Trade/Heli"
require "OperationAcorn/Trade/FirstSupply"
require "OperationAcorn/Trade/Markers"
require "OperationAcorn/Trade/Terminal"
local OA = OperationAcorn
local Store, Chunks, Server, Trade = OA.Store, OA.Chunks, OA.Server, OA.Trade
local Objects, Things, Boxes, Heli, Orders = Trade.Objects, Trade.Things, Trade.Boxes, Trade.Heli, Trade.Orders
local Handlers = {}
Trade.Handlers = Handlers

-- The terminal a command was made at: a table { x, y, z } of the terminal the window is open on. The character must
-- be near it and it must have power. Returns the terminal object, or nil and a reason (IGUI_OA_Trade_Reason_<reason>).
function Handlers.terminalFor(character, args)
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not (x and y and z) then return nil, "noTerminal" end
    local square = Objects.square(x, y, z)
    local object = Objects.find(square, Objects.TERMINAL)
    if not object then return nil, "noTerminal" end
    if not Things.near(character, x, y) then return nil, "far" end
    if not Objects.powered(square) then return nil, "noPower" end
    return object
end

local function refuse(record, reason)
    OA.Sync.notice(record.id, "IGUI_OA_Trade_Reason_" .. tostring(reason))
end

-- The cart: the lines the terminal's shop tab holds, kept in the record so that a closed window loses nothing. The
-- research team's goods are ordered at a field terminal only (checked again here, by the terminal it was sent at).
function Handlers.setCart(record, object, lines)
    local _, dropped = Orders.set(record, lines, not Objects.isUpgraded(object))
    if dropped > 0 then refuse(record, "fieldOnly") end
end

Server.on("tradeCart", function(character, record, args)
    local object, why = Handlers.terminalFor(character, args)
    if not object then return refuse(record, why) end
    if type(args.lines) ~= "table" then return end
    Handlers.setCart(record, object, args.lines)
    OA.Sync.changed("trade", record.id)
end)

-- A call, with the cart as it stands. kind "reissue" asks for a new delivery box; a box not standing in the world
-- (lost, or carried away and gone with its carrier) is what it is for.
Server.on("tradeCall", function(character, record, args)
    local object, why = Handlers.terminalFor(character, args)
    if not object then return refuse(record, why) end
    local kind = args.kind == "reissue" and "reissue" or "normal"
    if type(args.lines) == "table" then Handlers.setCart(record, object, args.lines) end
    local ok, reason
    if kind == "reissue" then
        local canCall, noBox = Boxes.canCall(record)
        if canCall then return refuse(record, "hasBox") end
        local square = object:getSquare()
        ok, reason = Heli.call(character, record, kind, square:getX(), square:getY())
        if not ok and reason == nil then reason = noBox end
    else
        ok, reason = Heli.call(character, record, kind)
    end
    if not ok then refuse(record, reason) end
end)

-- A crate a loot window shows empty: it breaks (the server looks for itself; a crate not empty here stays).
Server.on("crateEmptied", function(character, record, args)
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not (x and y and z) or not Things.near(character, x, y) then return end
    local object = Objects.find(Objects.square(x, y, z), Objects.CRATE)
    if object then Things.breakEmptyCrate(object) end
end)

-- The first time a terminal is used the team answers (LORE: the first radio line says the number once more): the
-- story part files it as a radio copy. A world where the first supply did not come with the vanilla helicopter gets
-- the late line.
Server.on("tradeUsed", function(character, record, args)
    local object = Handlers.terminalFor(character, args)
    if not object then return end
    local heli = Trade.heli(record)
    if heli.greeted then return end
    heli.greeted = true
    local late = record.first ~= nil and record.first.mode ~= "window"
    if OA.Story and OA.Story.firstContact then OA.Story.firstContact(record, late) end
end)

-- A tab of the terminal has been looked at: its dot goes (what it has seen is a number, DESIGN-terminal 1.1).
Server.on("terminalSeen", function(character, record, args)
    if OA.Terminal.setSeen(record, args.key, tonumber(args.value)) then OA.Sync.changed("trade", record.id) end
end)

-- The ten-minute work. A failing part does not stop the others.
local function guarded(name, fn)
    local ok, err = pcall(fn)
    if not ok then OA.log(name, "failed:", tostring(err)) end
end

local function refreshTerminals()
    for _, entry in ipairs(Chunks.list("trade.terminal")) do
        local square = Objects.square(entry.x, entry.y, entry.z)
        local object = square and Objects.find(square, Objects.TERMINAL)
        if object then Objects.showTerminal(object) end
    end
end

local function reconcileAll()
    for _, record in pairs(Store.players()) do
        if record.boxes then Things.reconcile(record) end
    end
end

-- Real milliseconds at least between two runs of the ten-minute work that only looks at the world and follows no game
-- time. Ten game minutes are 25 s of real time at the default day length but some 0.6 s fast-forwarded (x40), and
-- less asleep: this work then ran over and over for nothing. Each interval is below 25 s, so the default speed is as
-- before. The arrivals and the first supply compare game times and stay every ten minutes.
--   TERMINALS_MS: the terminal's light follows its power (a generator running dry while fast-forwarded shows soon).
--   BOXES_MS: the lost-box look is only a fallback to OnObjectAboutToBeRemoved; a few seconds late costs nothing.
--   MARKS_MS: a mark goes when its thing is gone, and its smoke is lit again (the game lights none on a square that
--     already smokes, so smoke did not pile up; the look was only wasted).
Handlers.TERMINALS_MS = 5000
Handlers.BOXES_MS = 10000
Handlers.MARKS_MS = 10000

local lastRun = {}     -- by work name: the real time (ms) it last ran

-- Runs a piece of the ten-minute work when its real-time interval has passed.
local function throttled(name, ms, fn, now)
    if OA.due(lastRun, name, now, ms) then guarded(name, fn) end
end

local function everyTenMinutes()
    guarded("arrivals", Heli.check)
    guarded("first supply", Trade.FirstSupply.check)
    local now = getTimestampMs()
    throttled("marks", Handlers.MARKS_MS, Trade.Markers.checkAll, now)
    throttled("lost boxes", Handlers.BOXES_MS, reconcileAll, now)
    throttled("terminal light", Handlers.TERMINALS_MS, refreshTerminals, now)
end
Events.EveryTenMinutes.Add(everyTenMinutes)

-- A box or terminal that is taken out of the world by something other than us (a sledgehammer): the record forgets it.
-- Our own removals set Objects.removing. The event fires on the side that decides (the server, or the game alone).
local function onRemoved(object)
    if Objects.removing or not object or not object.hasModData then return end
    local kind = Objects.kindOf(object)
    if kind == Objects.DELIVERY_BOX or kind == Objects.TERMINAL then
        guarded("destroyed", function() Things.destroyed(object) end)
    end
end
Events.OnObjectAboutToBeRemoved.Add(onRemoved)

-- Chunk work ------------------------------------------------------------------------------------------------------

-- A terminal's tile shows the power it has now.
Chunks.handle("trade.terminal", function(entry)
    local square = Objects.square(entry.x, entry.y, entry.z)
    local object = square and Objects.find(square, Objects.TERMINAL)
    if object then Objects.showTerminal(object) end
    return false
end)

-- A box set up again: the game does not keep a container's accept function, and the capacity may have grown.
Chunks.handle("trade.box", function(entry)
    local square = Objects.square(entry.x, entry.y, entry.z)
    local object = square and Objects.find(square, Objects.DELIVERY_BOX, entry.box)
    if object then Objects.setupBoxOf(object) end
    return false
end)

-- A sealed box a helicopter took, whose square was not loaded: taken away now.
Chunks.handle("trade.removeBox", function(entry)
    local square = Objects.square(entry.x, entry.y, entry.z)
    if not square then return false end
    local object = Objects.find(square, Objects.DELIVERY_BOX, entry.id)
    if object then
        Things.unwatch("trade.box", entry.x, entry.y, entry.z)
        Objects.remove(object)
        return true
    end
    -- The chunk may not be whole yet: look a few more times, then let it go.
    entry.tries = (entry.tries or 0) + 1
    return entry.tries >= 3
end)

-- A drop that waited for its place: the box, the crate and the smoke are set down.
Chunks.handle("trade.land", function(entry)
    return Heli.setDown(entry)
end)

return Handlers
