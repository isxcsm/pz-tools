-- P2: the whole loop on a throwaway save, without the terminal window. Puts a delivery box down, fills it, seals it,
-- calls the helicopter through the server function, brings the arrival forward and starts the pass. After about
-- 30 real seconds look for the crate beside the box (the "[p2flow]" lines say where). Changes the record (credits,
-- the settlement's serial and summary, boxes): use a throwaway save.
RUN("p2_lib.lua")
local OA = OperationAcorn
local T = OA.Trade
local Objects, Things, Boxes, Heli = T.Objects, T.Things, T.Boxes, T.Heli
local say = P2T.say("p2flow")
local record, player = P2T.record()
if not record then say("no record") return end

local spot = Objects.findClear(math.floor(player:getX()) + 3, math.floor(player:getY()), 25)
if not spot then say("no clear square near the character") return end
local item = player:getInventory():AddItem("OperationAcorn.DeliveryBox")
-- a record whose active box is still carried (packed in a supply crate) calls only once that box stands: this item is it
local active = Boxes.active(record)
if active and active.state == "carried" then
    item:getModData().OA_Box = active.id
    item:getModData().OA_Owner = record.id
end
local ok, object, box = Things.placeBox(player, record, spot, item)
P2T.check(say, "box placed", ok == true)
if not ok then return end
for _ = 1, 8 do object:getContainer():AddItem(instanceItem("Base.RippedSheets")) end
local sealed = Things.seal(player, record, object)
P2T.check(say, "box sealed", sealed == true)
local before = T.account(record).credits
-- an earlier run's call leaves the next one days away: this run may call now
record.heli.next = nil
local called, why = Heli.call(player, record, "normal")
P2T.check(say, "call accepted", called == true, why)
P2T.check(say, "a second call is refused while one is on its way", select(2, Heli.call(player, record, "normal")) == "pending")
record.heli.call.arrive = OA.hours() - 0.01
Heli.check()
local after = T.account(record).credits
say("credits before", before, "after", after)
P2T.check(say, "credits grew (the economy values the cloth)", after > before)
P2T.check(say, "a receipt is in the ledger", T.Ledger.last(record) ~= nil)
P2T.check(say, "the receipt took a serial", (record.trade.serial or 0) >= 1, record.trade.serial)
P2T.check(say, "the sealed box is out of the record", Boxes.get(record, box.id) == nil)
P2T.check(say, "an empty box comes back in the supply crate", Boxes.active(record) ~= nil and Boxes.active(record).state == "carried")
local settled = T.Ledger.last(record)
P2T.check(say, "the last settlement is kept as a summary", settled ~= nil and settled.credits > 0 and settled.boxes >= 1)
P2T.check(say, "no radio log is written", record.radio == nil)
say("pass under way:", tostring(record.heli.landing ~= nil), "at", spot:getX(), spot:getY(),
    "- wait 15 real seconds for the crate, then open the crate and read the manifest in it")
