-- The helicopter (DESIGN 9 and 12): the call, the arrival checked every ten minutes, the settlement (Trade.Settle) and
-- the drop in the world. The drop is the helicopter's pass: its sound comes and goes, and the crate appears at the
-- loudest moment, hanging from a parachute for a moment and then landed. Where a square is not loaded the drop waits
-- in the chunk table (kinds trade.land and trade.removeBox) and is done when its chunk loads.
require "OperationAcorn/Server"
require "OperationAcorn/Trade/Settle"
require "OperationAcorn/Trade/Orders"
require "OperationAcorn/Trade/Things"
require "OperationAcorn/Trade/Later"
require "OperationAcorn/Trade/Gain"
require "OperationAcorn/Trade/Text"
require "OperationAcorn/Trade/Markers"
local OA = OperationAcorn
local Store, Chunks, Sprites = OA.Store, OA.Chunks, OA.Sprites
local Trade = OA.Trade
local Rules, Boxes, Settle, Orders, Objects, Things, Later = Trade.Rules, Trade.Boxes, Trade.Settle, Trade.Orders,
    Trade.Objects, Trade.Things, Trade.Later
local Heli = {}
Trade.Heli = Heli

-- The pass, in real seconds: the helicopter is heard from far, comes over the drop, and goes. The crate appears at the
-- loudest moment, the middle; its parachute shows for a moment.
Heli.PASS_SECONDS, Heli.LOUD_AT, Heli.PARACHUTE_SECONDS = 22, 11, 1.8
-- How far the helicopter's path starts and ends from the drop (tiles).
Heli.PATH = 260

local function broadcast(command, args)
    if isServer() then
        sendServerCommand(OA.MOD, command, args)
    else
        OA.Sync.deliver(command, nil, args)
    end
end

local function changed(record)
    OA.Sync.changed("trade", record.id)
end

-- The call -----------------------------------------------------------------------------------------------------------

-- The rewards that decide a call: arrival range (hours), interval (days), night drop. Falls back to the sandbox
-- options when the economy part is missing.
function Heli.rewards(record)
    local rewards
    if OA.Trust and OA.Trust.rewards then
        local ok, r = pcall(OA.Trust.rewards, record)
        if ok then rewards = r end
    end
    rewards = rewards or {}
    return {
        arrival = rewards.arrival or { min = OA.scaled(OA.BALANCE.arrival[1], "HelicopterArrivalMultiplier"),
            max = OA.scaled(OA.BALANCE.arrival[2], "HelicopterArrivalMultiplier") },
        callInterval = rewards.callInterval or OA.scaled(OA.BALANCE.callDays, "CallIntervalMultiplier"),
        nightDrop = rewards.nightDrop == true,
    }
end

-- Makes a call. kind "normal" needs the active box standing in the world; kind "reissue" asks for a new box, costs
-- BoxReissueCost credits (a short balance becomes a debt) and brings the box to a clear spot near x, y. The cart
-- is carried on the flight. Returns true, or false and a reason.
function Heli.call(character, record, kind, x, y)
    local heli = Trade.heli(record)
    local now = OA.hours()
    local ok, why = Rules.canCall(heli, now)
    if not ok then return false, why end
    local call = { kind = kind }
    if kind == "reissue" then
        call.x, call.y, call.z = math.floor(x or character:getX()), math.floor(y or character:getY()), 0
    else
        ok, why = Boxes.canCall(record)
        if not ok then return false, why end
        local box = Boxes.active(record)
        call.x, call.y, call.z = box.x, box.y, box.z
        call.box = box.id
    end
    local rewards = Heli.rewards(record)
    local delay = Rules.callDelay(rewards.arrival, OA.randomFloat)
    local arrive = Rules.arrival(now, getGameTime():getTimeOfDay(), delay, rewards.nightDrop, OA.randomFloat(0, Rules.MORNING_SPREAD))
    local account = Trade.account(record)
    if kind == "reissue" then
        account.credits = account.credits - OA.reissueCost()
    end
    -- The cart goes with this flight (and is paid on arrival); an empty cart is a flight for the delivery alone.
    call.orders = Trade.copy(Orders.cart(record))
    Trade.orders(record).cart = {}
    Rules.startCall(heli, now, arrive, rewards.callInterval, call)
    local day, h, m = Trade.clockText(arrive)
    -- (while nobody answers on the team's side the call is taken automatically: SCENES S4)
    local silent = OA.Comms and OA.Comms.silent(record)
    local key
    if kind == "reissue" then
        key = silent and "IGUI_OA_Trade_Notice_ReissueCalledAuto" or "IGUI_OA_Trade_Notice_ReissueCalled"
    else
        key = silent and "IGUI_OA_Trade_Notice_CalledAuto" or "IGUI_OA_Trade_Notice_Called"
    end
    OA.Sync.notice(record.id, key, { day, string.format("%02d:%02d", h, m) })
    changed(record)
    return true
end

-- The arrival -------------------------------------------------------------------------------------------------------

-- The services the settlement works with: the economy (P1), the shop and the story part.
function Heli.services(record)
    local Value = OA.Value
    return {
        now = OA.hours(),
        day = OA.day(),
        settle = function(r, entries)
            if Value and Value.settle then return Value.settle(r, entries) end
            return { credits = 0, trust = 0, lines = {} }
        end,
        trustAdd = function(r, amount) return Trade.addTrust(r, amount, "settle") end,
        oldForm = OA.Story and OA.Story.oldForm and OA.Story.oldForm(record) or false,
        shop = Orders.shopService(record),
        rnd = function(a, b) return OA.random(a, b) end,
    }
end

-- Removes a sealed box object that is taken away, now if its square is loaded, else when its chunk loads.
function Heli.removeBox(owner, removal)
    local square = Objects.square(removal.x, removal.y, removal.z)
    if square then
        local object = Objects.find(square, Objects.DELIVERY_BOX, removal.id)
        if object then
            Things.unwatch("trade.box", removal.x, removal.y, removal.z)
            Objects.remove(object)
        end
        return true
    end
    Chunks.add({ kind = "trade.removeBox", x = removal.x, y = removal.y, z = removal.z, id = removal.id, owner = owner.id })
    return false
end

-- The noise of the helicopter for zombies, at a place.
function Heli.noise(x, y, z)
    local radius = OA.scaled(OA.BALANCE.noiseRadius, "HelicopterNoiseMultiplier")
    if radius <= 0 then return end
    local ok, err = pcall(function() getWorldSoundManager():addSound(nil, x, y, z, radius, radius) end)
    if not ok then OA.log("noise failed:", tostring(err)) end
end

-- Puts the box, the crate and the smoke down at a spot (a table of a drop): { x, y, z, owner, box, search, remove,
-- boxCargo, cargo, parachute, marker }. Returns true when it was done, false when the square is not loaded yet.
function Heli.setDown(entry)
    local owner = Store.player(entry.owner)
    if not owner then return true end
    local square = Objects.square(entry.x, entry.y, entry.z or 0)
    if not square then return false end
    for _, id in ipairs(entry.remove or {}) do
        local object = Objects.find(square, Objects.DELIVERY_BOX, id)
        if object then
            Things.unwatch("trade.box", entry.x, entry.y, entry.z or 0)
            Objects.remove(object)
        end
    end
    local boxSquare = square
    if entry.box then
        if entry.search then
            boxSquare = Objects.findClear(entry.x, entry.y, 30)
            if not boxSquare then
                boxSquare = Objects.search(entry.x, entry.y, 0, 12, function(s) return Objects.free(s) end) or square
            end
        end
        local bx, by, bz = boxSquare:getX(), boxSquare:getY(), boxSquare:getZ()
        local box = Boxes.get(owner, entry.box)
        if box then
            Boxes.place(owner, entry.box, bx, by, bz)
            box.pending = nil
            local object = Objects.create(boxSquare, Sprites.deliveryBox(false), Objects.DELIVERY_BOX,
                { OA_Box = entry.box, OA_Owner = owner.id })
            local container = Objects.setupBox(object, owner)
            if entry.boxCargo and container then Objects.fill(container, entry.boxCargo) end
            Things.watch("trade.box", bx, by, bz, { box = entry.box, owner = owner.id })
            if entry.marker then Trade.Markers.add(owner, boxSquare, "first", { box = entry.box }) end
        end
    end
    if entry.cargo and #entry.cargo > 0 then
        local crateSquare = Objects.findBeside(boxSquare:getX(), boxSquare:getY(), boxSquare:getZ(), 5) or boxSquare
        Things.makeCrate(crateSquare, entry.cargo, entry.parachute)
        local cx, cy, cz = crateSquare:getX(), crateSquare:getY(), crateSquare:getZ()
        Trade.Markers.add(owner, crateSquare, "crate")
        if entry.parachute then
            Later.after(Heli.PARACHUTE_SECONDS, function()
                local object = Objects.find(Objects.square(cx, cy, cz), Objects.CRATE)
                if object and object:getModData()[Objects.SEALED] then Things.land(object) end
            end)
        end
    end
    changed(owner)
    return true
end

-- The helicopter's pass over a drop that is shown: the clients play the sound; the drop happens at the loud moment.
local function present(owner, entry)
    local heli = Trade.heli(owner)
    entry.at = OA.hours()
    heli.landing = entry
    broadcast("heliPass", { x = entry.x, y = entry.y, z = entry.z or 0, seconds = Heli.PASS_SECONDS,
        loud = Heli.LOUD_AT, path = Heli.PATH, angle = OA.randomFloat(0, 6.283), owner = owner.id })
    local id = owner.id
    Later.after(Heli.LOUD_AT, function() Heli.landNow(id) end)
end

-- The player is told a drop is done: a title, saying the crate is on the map when it is there
-- already (a drop on a square not loaded yet comes down, and is marked, when the square loads).
function Heli.dropped(owner, marked)
    OA.Sync.title(owner.id, { key = "IGUI_OA_Title_Dropped", sub = marked and "IGUI_OA_Title_Marked" or nil,
        style = "notice", fallback = "good" })
end

-- The loud moment of a pass (or at once): the drop waiting in the record is done; the noise and the title follow.
function Heli.landNow(ownerId)
    local owner = Store.player(ownerId)
    if not owner then return end
    local heli = Trade.heli(owner)
    local entry = heli.landing
    if not entry then return end
    heli.landing = nil
    local done = Heli.setDown(entry)
    if not done then
        entry.kind = "trade.land"
        Chunks.add(entry)
    end
    Heli.noise(entry.x, entry.y, entry.z or 0)
    Heli.dropped(owner, done and entry.cargo ~= nil and #entry.cargo > 0)
end

-- Does the physical part of an arrival.
function Heli.deliver(record, plan, call)
    local receipt = plan.receipt
    local cargo = plan.cargo
    local needCrate = #cargo > 0 or (receipt.boxes or 0) > 0 or #(receipt.orders or {}) > 0
    if needCrate then
        table.insert(cargo, 1, { type = "OperationAcorn.SupplyManifest", count = 1, receipt = Trade.copy(receipt) })
    end
    local spot = plan.spot or { x = call.x, y = call.y, z = call.z or 0 }
    local entry = { kind = "trade.land", owner = record.id, x = spot.x, y = spot.y, z = spot.z or 0,
        box = plan.newBox and plan.newBox.id or nil, search = plan.reissue or false,
        cargo = needCrate and cargo or nil, remove = {}, parachute = true, receipt = receipt.id }
    for _, removal in ipairs(plan.removals) do
        if plan.spot and removal.x == plan.spot.x and removal.y == plan.spot.y and removal.z == plan.spot.z then
            entry.remove[#entry.remove + 1] = removal.id
        else
            Heli.removeBox(record, removal)
        end
    end
    if plan.newBox then plan.newBox.pending = true end
    if not entry.box and not entry.cargo and #entry.remove == 0 then return end
    if Objects.square(entry.x, entry.y, entry.z) then
        present(record, entry)
    else
        Chunks.add(entry)
        Heli.dropped(record, false)
    end
end

-- The manifest written out goes to the story part's document folder too (the latest few are kept there, and every
-- one with a remark of the story's own).
function Heli.keepManifest(record, receipt)
    if not (OA.Story and OA.Story.addManifest) then return end
    local ok, err = pcall(function()
        local words = {}
        for _, line in ipairs(Trade.Text.receipt(receipt)) do words[#words + 1] = line.text end
        local keep = OA.Story.keepsManifest and receipt.note and OA.Story.keepsManifest(receipt.note.key) or false
        OA.Story.addManifest(record, receipt.id, table.concat(words, "\n"), keep)
    end)
    if not ok then OA.log("manifest not kept:", tostring(err)) end
end

-- A helicopter whose time has come: settles, pays, and drops. Returns the plan.
function Heli.arrive(record)
    local heli = Trade.heli(record)
    local call = heli.call
    if not call then return nil end
    local plan = Settle.run(record, Heli.services(record))
    heli.call = nil
    heli.last = { at = OA.hours(), receipt = plan.receipt.id, kind = call.kind }
    if record.trade.credits < 0 then
        OA.Sync.title(record.id, { key = "IGUI_OA_Title_Debt", sub = "IGUI_OA_Title_DebtSub", style = "notice",
            tone = "red", fallback = "bad" })
    end
    local applied = OA.Support and OA.Support.appliedTitle(plan.support)
    if applied then OA.Sync.title(record.id, applied) end
    Heli.keepManifest(record, plan.receipt)
    Heli.deliver(record, plan, call)
    Heli.refreshBoxes(record)
    changed(record)
    return plan
end

-- A pass saved in the middle is finished once this many game hours have gone since it began.
Heli.LANDING_STALE_HOURS = 0.5

-- Every ten minutes: the helicopters whose arrival has come.
function Heli.check()
    local now = OA.hours()
    for _, record in pairs(Store.players()) do
        local heli = record.heli
        if heli and heli.call and now >= heli.call.arrive then
            local ok, err = pcall(Heli.arrive, record)
            if not ok then OA.log("arrival failed:", tostring(err)) end
        end
        -- A pass that was saved in the middle is finished.
        if heli and heli.landing and now - (heli.landing.at or 0) > Heli.LANDING_STALE_HOURS then Heli.landNow(record.id) end
    end
end

-- The capacity of a record's boxes that are loaded, set again (a stage may have raised it).
function Heli.refreshBoxes(record)
    for _, box in ipairs(Boxes.all(record)) do
        if box.state == "placed" and box.x then
            local square = Objects.square(box.x, box.y, box.z)
            local object = square and Objects.find(square, Objects.DELIVERY_BOX, box.id)
            if object then Objects.setupBox(object, record) end
        end
    end
end

return Heli
