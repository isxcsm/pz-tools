-- The cart in the terminal and the shop services the helicopter pays it with. The catalog, prices and limits are
-- P1's (OA.Shop); this keeps the cart, finds an entry by the id a cart line carries and turns an entry into the
-- item specs one unit brings.
--
-- record.orders = { cart = { { id, count, target, choice } } }
--
-- What this reads of a catalog entry (OA.Shop.catalog()): `id`, `special` ("kit" with `kit`, "serum" with `tree`,
-- "reissue", "cure", "delay"), `group`; the goods as `give` (a list of { type, count, full, fluid, empty }) or as
-- `choices` (a list of the same, the player picks one: the line's `choice` is the picked type); the name from
-- OA.Shop.nameKey. Prices and availability: OA.Shop.price, serumPrice, available (how many, why not, when).
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Rules"
require "OperationAcorn/Economy/Shop"
local OA = OperationAcorn
local Trade = OA.Trade
local Orders = {}
Trade.Orders = Orders

-- A cart holds this many lines, and a line this many units.
Orders.MAX_LINES, Orders.MAX_COUNT = 40, 99

function Orders.cart(record)
    local d = Trade.orders(record)
    d.cart = d.cart or {}
    return d.cart
end

-- The catalog entries by id (rebuilt when the catalog changes size: a stage may add entries).
local indexed, indexSize
local function catalogIndex()
    if not (OA.Shop and OA.Shop.catalog) then return {} end
    local list = OA.Shop.catalog()
    if indexed and indexSize == #list then return indexed end
    indexed = {}
    for _, entry in ipairs(list) do indexed[entry.id] = entry end
    indexSize = #list
    return indexed
end

function Orders.entry(id)
    return catalogIndex()[id]
end

-- The player-facing name of an entry.
function Orders.nameOf(entry)
    if not entry then return "?" end
    if OA.Shop.name then return OA.Shop.name(entry) end
    return getText(OA.Shop.nameKey(entry))
end

-- The things an entry can deliver to pick from: its `choices` (P1 finds the seeds when asked), else none.
function Orders.choicesOf(entry)
    if not entry.choices then return nil end
    return OA.Shop.choices(entry)
end

-- The picked one of an entry's choices by its type, or the first when the line picked none (or a type that is not
-- offered).
local function picked(entry, line)
    local choices = Orders.choicesOf(entry)
    if not choices or #choices == 0 then return nil end
    for _, g in ipairs(choices) do
        if line and g.type == line.choice then return g end
    end
    return choices[1]
end

-- The shop services Rules.payOrders needs, over OA.Shop. P1's `available` answers how many a record may buy at once
-- (0 with a reason) from the weekly count and intervals, so it is asked once for a line and the line's units are
-- counted against it; `bought` records each unit as it is delivered.
function Orders.shopService(record)
    local Shop = OA.Shop
    local most = {}
    return {
        entry = function(line) return Orders.entry(line.id) end,
        available = function(entry, line, delivered)
            if (delivered or 0) == 0 then
                local n, why = Shop.available(entry, record)
                most[line] = { n = n or 0, why = why }
            end
            local m = most[line]
            if m and (delivered or 0) >= m.n then return false, m.why or "limit" end
            return true
        end,
        price = function(entry, line)
            if entry.special == "serum" then return Shop.serumPrice(entry.tree, record) end
            return Shop.price(entry, record)
        end,
        bought = function(entry, line)
            Shop.bought(entry, record, 1)
        end,
        items = function(entry, line)
            return Orders.itemSpecs(entry, line)
        end,
    }
end

-- One goods table of P1's ({ type, count, full, fluid, empty, mod, used, name }) as a drop spec (Trade.dropSpec's
-- fields).
local function spec(g)
    return Trade.dropSpec({ type = g.type, count = g.count, fluid = g.fluid, empty = g.empty, mod = g.mod, used = g.used,
        name = g.name })
end

-- The item specs one unit of an entry brings (a kit carries its target in the item's modData).
function Orders.itemSpecs(entry, line)
    local specs = {}
    local goods = entry.give or { picked(entry, line) }
    for _, g in ipairs(goods) do
        local s = spec(g)
        if s then specs[#specs + 1] = s end
    end
    return specs
end

-- Replaces the cart with the lines given, keeping the valid ones: a known entry, a whole count of 1 to the limit,
-- no more lines than the limit, a repeated entry (same id and choice) merged. Returns the cart.
function Orders.set(record, lines, crude)
    local cart = {}
    local seen = {}
    local dropped = 0
    for _, line in ipairs(lines or {}) do
        if #cart >= Orders.MAX_LINES then break end
        local id = line.id
        local count = math.floor(tonumber(line.count) or 0)
        local entry = type(id) == "string" and Orders.entry(id) or nil
        if entry and crude and OA.Shop.fieldOnly(entry) then
            dropped = dropped + 1
            entry = nil
        end
        if entry and count >= 1 then
            count = math.min(count, Orders.MAX_COUNT)
            local choice
            local pick = picked(entry, line)
            if pick then choice = pick.type end
            local key = id .. "|" .. (choice or "")
            local at = seen[key]
            if at then
                cart[at].count = math.min(Orders.MAX_COUNT, cart[at].count + count)
            else
                cart[#cart + 1] = { id = id, count = count, choice = choice }
                seen[key] = #cart
            end
        end
    end
    Trade.orders(record).cart = cart
    return cart, dropped
end

-- What a line costs with a shop service: one unit's price times the count.
function Orders.lineCost(svc, entry, line)
    return OA.round(svc.price(entry, line)) * (line.count or 1)
end

-- What the cart costs at today's prices, one unit's price times the count (prices that rise as units are bought
-- are not foreseen: the helicopter pays by the price of each unit as it comes), and what is left of the balance.
function Orders.estimate(record, balance)
    local svc = Orders.shopService(record)
    local total = 0
    for _, line in ipairs(Orders.cart(record)) do
        local entry = svc.entry(line)
        if entry then total = total + Orders.lineCost(svc, entry, line) end
    end
    return total, (balance or 0) - total
end

return Orders
