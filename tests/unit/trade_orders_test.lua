-- The cart over the shop's catalog shape (P1): entries with goods or choices, kits with targets, availability that
-- answers how many, and what a line brings.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Rules"
require "OperationAcorn/Trade/Orders"
local OA = OperationAcorn
local Orders, Rules = OA.Trade.Orders, OA.Trade.Rules

-- A shop with P1's entry shapes.
local function fakeShop(options)
    options = options or {}
    local entries = {
        { id = "battery_pack", price = 4000, week = 5, give = { { type = "Base.Battery", count = 4, full = true } } },
        { id = "car_battery", price = 20000, choices = { { type = "Base.CarBattery1", count = 1 },
            { type = "Base.CarBattery2", count = 1 } } },
        { id = "kit_trunk", price = 60000, special = "kit", kit = "trunk", give = { { type = "OperationAcorn.KitTrunk", count = 1 } } },
        { id = "fuelcan_mk1", price = 20000, give = { { type = "OperationAcorn.FuelCanMk1", count = 1, empty = true } } },
        { id = "petrol_can", price = 15000, give = { { type = "Base.PetrolCan", count = 1, full = true, fluid = "Petrol" } } },
    }
    local bought = {}
    OA.Shop = {
        catalog = function() return entries end,
        nameKey = function(entry) return "IGUI_OA_Econ_Shop_Item_" .. entry.id end,
        choices = function(entry) return entry.choices end,
        price = function(entry) return entry.price end,
        kitPrice = function(kind, target) return 100 + #tostring(target) end,
        available = function(entry)
            local left = (options.most or {})[entry.id]
            if left == nil then return 99 end
            if left <= 0 then return 0, "IGUI_OA_Econ_Shop_Limit" end
            return left
        end,
        bought = function(entry, record, count, target)
            bought[#bought + 1] = { id = entry.id, count = count, target = target }
        end,
    }
    return bought
end

local function newRecord() return OA.Store.ensure("rec", "Tester") end

test("a cart keeps known entries, picks a valid choice and merges repeats", function()
    fakeShop()
    local record = newRecord()
    local cart = Orders.set(record, {
        { id = "battery_pack", count = 2 }, { id = "battery_pack", count = 3 }, { id = "nothing", count = 1 },
        { id = "car_battery", count = 1, choice = "Base.CarBattery2" }, { id = "car_battery", count = 1, choice = "bad" },
        { id = "kit_trunk", count = 1, target = "car7" }, { id = "petrol_can", count = 0 } })
    eq(#cart, 4)
    eq(cart[1].count, 5)
    eq(cart[2].choice, "Base.CarBattery2")
    eq(cart[3].choice, "Base.CarBattery1", "an offered choice replaces one that is not offered")
    eq(cart[4].target, "car7")
end)

test("a line brings the goods it names or the choice it made", function()
    fakeShop()
    local entry = Orders.entry("car_battery")
    local specs = Orders.itemSpecs(entry, { choice = "Base.CarBattery2" })
    eq(#specs, 1)
    eq(specs[1].type, "Base.CarBattery2")
    specs = Orders.itemSpecs(Orders.entry("fuelcan_mk1"), {})
    eq(specs[1].empty, true)
    specs = Orders.itemSpecs(Orders.entry("petrol_can"), {})
    eq(specs[1].fluid, "Petrol")
    specs = Orders.itemSpecs(Orders.entry("kit_trunk"), { target = "car7" })
    eq(specs[1].mod.OA_Target, "car7")
    specs = Orders.itemSpecs(Orders.entry("battery_pack"), {})
    eq(specs[1].count, 4)
end)

test("the shop's limit counts units of a line and tells why", function()
    local bought = fakeShop({ most = { battery_pack = 2 } })
    local record = newRecord()
    local svc = Orders.shopService(record)
    local balance, spent, results, items = Rules.payOrders(100000, { { id = "battery_pack", count = 5 } }, svc)
    eq(results[1].delivered, 2)
    eq(results[1].reason, "IGUI_OA_Econ_Shop_Limit")
    eq(#bought, 2)
    eq(spent, 8000)
    eq(#items, 2)
end)

test("a kit is priced with its target and the cart estimate adds the lines", function()
    fakeShop()
    local record = newRecord()
    Orders.set(record, { { id = "battery_pack", count = 2 }, { id = "kit_trunk", count = 1, target = "car7" } })
    local total, left = Orders.estimate(record, 20000)
    eq(total, 8000 + 104)
    eq(left, 20000 - 8104)
end)

test("an unknown shop gives no entries and a name is the entry's", function()
    OA.Shop = nil
    eq(Orders.entry("x"), nil)
    fakeShop()
    eq(Orders.nameOf(Orders.entry("battery_pack")), "IGUI_OA_Econ_Shop_Item_battery_pack")
end)
