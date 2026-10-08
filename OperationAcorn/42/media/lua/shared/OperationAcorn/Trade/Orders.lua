-- The cart in the terminal and the shop services the helicopter pays it with. The catalog, prices and limits are
-- P1's (OA.Shop); this keeps the cart, finds an entry by the id a cart line carries and turns an entry into the
-- item specs one unit brings.
--
-- record.orders = { cart = { { id, count, target } } }
--
-- What this reads of a catalog entry (OA.Shop.catalog()): `id`; `items` (a list of { type, count, ... item specs}) or
-- `type` (a full type name) and `count`; for the price `tree` (an upgrade serum: OA.Shop.serumPrice) or `kit` (a
-- modification kit: OA.Shop.kitPrice with the line's target), else OA.Shop.price(entry, record); the name from
-- `name` or `nameKey` or the item's own.
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Rules"
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
    local list = OA.Shop.catalog() or {}
    if indexed and indexSize == #list then return indexed end
    indexed = {}
    for _, entry in ipairs(list) do
        local id = entry.id or entry.key
        if id then indexed[id] = entry end
    end
    indexSize = #list
    return indexed
end

function Orders.entry(id)
    return catalogIndex()[id]
end

-- The player-facing name of an entry.
function Orders.nameOf(entry)
    if not entry then return "?" end
    if entry.name then return entry.name end
    if entry.nameKey then return getText(entry.nameKey) end
    local fullType = entry.type or (entry.items and entry.items[1] and entry.items[1].type)
    if fullType then return getItemNameFromFullType(fullType) end
    return tostring(entry.id or "?")
end

-- Whether an answer from the shop is a yes: true, or a table/other non-false with no reason. P1's `available` gives
-- true, or false and a reason key.
local function yes(ok, why)
    if ok == true then return true end
    if ok == nil or ok == false then return false, why end
    if type(ok) == "string" then return false, ok end
    return true
end

-- The shop services Rules.payOrders needs, over OA.Shop.
function Orders.shopService(record)
    local Shop = OA.Shop
    return {
        entry = function(line) return Orders.entry(line.id) end,
        available = function(entry)
            if not (Shop and Shop.available) then return true end
            return yes(Shop.available(entry, record))
        end,
        price = function(entry, line)
            if entry.kit and Shop.kitPrice then return Shop.kitPrice(entry.kit, line.target, record) end
            if entry.tree and Shop.serumPrice then return Shop.serumPrice(entry.tree, record) end
            return Shop.price(entry, record)
        end,
        bought = function(entry, line)
            if Shop and Shop.bought then Shop.bought(entry, record, 1, line.target) end
        end,
        items = function(entry, line)
            return Orders.itemSpecs(entry, line)
        end,
    }
end

-- The item specs one unit of an entry brings (a kit carries its target in the item's modData).
function Orders.itemSpecs(entry, line)
    local specs = {}
    local function add(src)
        local spec = Trade.dropSpec(src)
        if not spec then return end
        if line and line.target and entry.kit then
            spec.mod = spec.mod or {}
            spec.mod.OA_Target = line.target
        end
        specs[#specs + 1] = spec
    end
    if entry.items then
        for _, src in ipairs(entry.items) do add(src) end
    elseif entry.type or entry.fullType then
        add({ type = entry.type or entry.fullType, count = entry.count, mod = entry.mod, condition = entry.condition,
            used = entry.used, fluid = entry.fluid, amount = entry.amount })
    end
    return specs
end

-- Replaces the cart with the lines given, keeping the valid ones: a known entry, a whole count of 1 to the limit,
-- no more lines than the limit, a repeated entry (same id and target) merged. Returns the cart.
function Orders.set(record, lines)
    local cart = {}
    local seen = {}
    for _, line in ipairs(lines or {}) do
        if #cart >= Orders.MAX_LINES then break end
        local id = line.id
        local count = math.floor(tonumber(line.count) or 0)
        if type(id) == "string" and count >= 1 and Orders.entry(id) then
            count = math.min(count, Orders.MAX_COUNT)
            local target = type(line.target) == "string" and line.target or nil
            local key = id .. "|" .. (target or "")
            local at = seen[key]
            if at then
                cart[at].count = math.min(Orders.MAX_COUNT, cart[at].count + count)
            else
                cart[#cart + 1] = { id = id, count = count, target = target }
                seen[key] = #cart
            end
        end
    end
    Trade.orders(record).cart = cart
    return cart
end

-- What the cart costs at today's prices, one unit's price times the count (prices that rise as units are bought
-- are not foreseen: the helicopter pays by the price of each unit as it comes), and what is left of the balance.
function Orders.estimate(record, balance)
    local svc = Orders.shopService(record)
    local total = 0
    for _, line in ipairs(Orders.cart(record)) do
        local entry = svc.entry(line)
        if entry then
            local ok, price = pcall(svc.price, entry, line)
            if ok and type(price) == "number" then total = total + OA.round(price) * line.count end
        end
    end
    return total, (balance or 0) - total
end

return Orders
