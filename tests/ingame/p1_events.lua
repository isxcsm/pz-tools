-- P1: the world handlers and the shred. Runs the daily, ten-minute and minute handlers once with timings, reads the
-- kill count (kill a zombie, run it, kill another, run it: the count goes up by one each time), and prices the shred
-- of real items. The daily handler steps the market to today; it changes nothing else.
-- Prints "[p1ev]" lines.
RUN("p1_lib.lua")
local OA = OperationAcorn
local say = P1T.say("p1ev")
local record, player = P1T.record()
if not record then say("no record yet: wait for the first hello"); return end

local t0 = P1T.ms()
OA.Economy.daily()
say("daily ms", P1T.ms() - t0)
t0 = P1T.ms()
OA.Economy.tenMinutes()
local sweep = P1T.ms() - t0
say("ten-minute sweep ms", sweep, "(your whole inventory, bags included)")
P1T.check(say, "the sweep is under 50 ms", sweep < 50)
t0 = P1T.ms()
OA.Buildings.tick(player)
say("building look ms", P1T.ms() - t0)

local c = OA.Codex.section(record)
local summary = OA.Codex.summary(record)
say("kills", c.kills, "kinds", c.n, "buildings", c.nb, "paid kills", c.paid.kills)
say("next kinds", tostring(summary.nextKinds), "next kills", tostring(summary.nextKills))
say("bonus credits waiting", record.trade.bonus, "credits", record.trade.credits, "trust",
    string.format("%.1f", record.trade.trust), "tier", OA.Trust.tier(record))
if OA._p1evKills and OA._p1evKills ~= c.kills then
    say("kills since the last run", c.kills - OA._p1evKills)
end
OA._p1evKills = c.kills

-- The shred on real items.
local inv = player:getInventory()
for _, type in ipairs({ "Base.Hammer", "Base.Tshirt_DefaultTEXTURE_TINT", "Base.Battery", "Base.Bag_ALICEpack" }) do
    local item = inv:AddItem(type)
    if item then
        local info = OA.Value.info(item)
        local can, why = OA.Shred.can(info)
        local expected, firstBonus = OA.Shred.yield(info, record)
        say("shred", type, "can", tostring(can), why or "", "weight", info.weight, "expected bundles",
            string.format("%.2f", expected), "first bonus", firstBonus)
        if can then
            P1T.check(say, type .. " yields 5 bundles per weight at most twice over", expected >= 0 and
                expected <= info.weight * 5 * 2 + 1e-9)
        end
        inv:Remove(item)
    end
end

local entry = OA.Shop.entry("battery_pack")
say("battery pack price", OA.Shop.price(entry, record), "available", tostring((OA.Shop.available(entry, record))))
say("done")
