-- Flight support (운항 지원, DESIGN-terminal 2.6): the numbers trust used to raise by itself are upgrades bought for
-- credits, one level at a time. Trust only opens the next level; the request is made at a field terminal, paid and
-- applied at the next helicopter's settlement. The record keeps the levels it has (trade.levels) and the ones asked
-- for (trade.pendingLevels), by upgrade id; a missing level is 0, the start.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
local OA = OperationAcorn
local Support = {}
OA.Support = Support

-- The upgrades in the order the screen and the settlement go through them. `base` is the value at level 0; each step
-- is { value, tier (the trust level that opens it, Trust.tier), price }. The box capacity goes on after its table:
-- `endless` adds `add` a level from tier `from`, at `price` and then `step` more for each.
Support.LIST = {
    { id = "box", group = "heli", base = OA.BALANCE.boxCapacity,
        steps = { { 100, 3, 30000 }, { 200, 5, 100000 }, { 250, 6, 140000 }, { 300, 7, 180000 }, { 350, 8, 220000 } },
        endless = { add = 50, from = 9, price = 260000, step = 40000 } },
    { id = "call", group = "heli", base = OA.BALANCE.callDays, steps = { { 2, 2, 40000 }, { 1.5, 4, 80000 }, { 1, 7, 150000 } } },
    { id = "arrive", group = "heli", base = { OA.BALANCE.arrival[1], OA.BALANCE.arrival[2] }, steps = { { { 3, 4 }, 3, 30000 }, { { 2, 3 }, 8, 80000 } } },
    { id = "night", group = "heli", base = false, steps = { { true, 5, 100000 } } },
    { id = "rate", group = "trade", base = 0, steps = { { 0.05, 3, 40000 }, { 0.10, 5, 90000 }, { 0.15, 7, 160000 } } },
    { id = "discount", group = "trade", base = 0, steps = { { 0.05, 4, 50000 }, { 0.10, 7, 120000 } } },
    { id = "reqcount", group = "trade", base = 6, steps = { { 8, 2, 20000 }, { 10, 5, 50000 }, { 12, 7, 90000 } } },
    { id = "reqprice", group = "trade", base = 1.0, steps = { { 1.1, 3, 30000 }, { 1.2, 5, 60000 }, { 1.3, 7, 100000 } } },
    { id = "softer", group = "trade", base = false, steps = { { true, 4, 60000 } } },
    { id = "forecast", group = "trade", base = false, steps = { { true, 3, 25000 } } },
    -- The missions: their pay on top (credits only: trust is not bought), their days, and the streak's cap.
    { id = "mpay", group = "mission", base = 0, steps = { { 0.10, 2, 30000 }, { 0.20, 4, 70000 }, { 0.30, 6, 120000 } } },
    { id = "mdays", group = "mission", base = 14, steps = { { 16, 2, 20000 }, { 20, 5, 60000 } } },
    { id = "mstreak", group = "mission", base = 0.3, steps = { { 0.4, 3, 40000 }, { 0.5, 6, 90000 } } },
}
Support.GROUPS = { "heli", "trade", "mission" }

local byId = {}
for _, u in ipairs(Support.LIST) do byId[u.id] = u end

function Support.get(id)
    return byId[id]
end

-- Level n of an upgrade: { value, tier, price } (level 0 is { base }); nil past its end.
function Support.step(id, n)
    local u = byId[id]
    if not u or n < 0 then return nil end
    if n == 0 then return { value = u.base, tier = 0, price = 0 } end
    local s = u.steps[n]
    if s then return { value = s[1], tier = s[2], price = s[3] } end
    local e = u.endless
    if not e then return nil end
    local past = n - #u.steps
    local last = u.steps[#u.steps][1]
    return { value = last + e.add * past, tier = e.from + past - 1, price = e.price + e.step * (past - 1) }
end

-- The levels a record has, and the ones it has asked for (both made empty the first time).
function Support.levels(record)
    local t = OA.Store.section(record, "trade")
    t.levels = t.levels or {}
    return t.levels
end

function Support.pending(record)
    local t = OA.Store.section(record, "trade")
    t.pendingLevels = t.pendingLevels or {}
    return t.pendingLevels
end

function Support.level(record, id)
    local t = record.trade
    return t and t.levels and t.levels[id] or 0
end

-- The value an upgrade has now for a record.
function Support.value(record, id)
    return Support.step(id, Support.level(record, id)).value
end

-- Bumped whenever a level changes, so that what is worked out from the levels is worked out again.
local function changed(record)
    local t = OA.Store.section(record, "trade")
    t.levelsRev = (t.levelsRev or 0) + 1
end

-- Whether a record may ask for level `level` of `id` now, at a field terminal or not. Returns true, or false and why:
-- "unknown", "max" (no such level), "next" (not the level after the one it has), "pending" (already asked for),
-- "tier" (trust has not opened it), "debt", "field" (asked at a crude terminal).
function Support.canRequest(record, id, level, field)
    if not byId[id] then return false, "unknown" end
    local s = type(level) == "number" and Support.step(id, level) or nil
    if not s or level < 1 then return false, "max" end
    if level ~= Support.level(record, id) + 1 then return false, "next" end
    if Support.pending(record)[id] then return false, "pending" end
    if OA.Trust.tier(record) < s.tier then return false, "tier" end
    local t = record.trade
    if t and (t.credits or 0) < 0 then return false, "debt" end
    if not field then return false, "field" end
    return true
end

function Support.request(record, id, level, field)
    local ok, why = Support.canRequest(record, id, level, field)
    if not ok then return false, why end
    Support.pending(record)[id] = level
    return true
end

-- A request taken back before the settlement.
function Support.cancel(record, id)
    local pending = Support.pending(record)
    if not pending[id] then return false end
    pending[id] = nil
    return true
end

-- The pending requests, in the screen's order: { { id, from, to, price } }.
function Support.requests(record)
    local pending = record.trade and record.trade.pendingLevels or {}
    local list = {}
    for _, u in ipairs(Support.LIST) do
        local level = pending[u.id]
        if level then
            list[#list + 1] = { id = u.id, from = Support.level(record, u.id), to = level, price = Support.step(u.id, level).price }
        end
    end
    return list
end

-- At a settlement: each request is paid from the balance, in order, and its level applied; one the balance cannot
-- pay waits for the next settlement (no request goes into debt). A request whose level is no longer the next (the
-- level came another way) is dropped without a word. Returns the new balance and what happened:
-- { { id, from, to, price, paid } }.
function Support.settle(record, balance)
    local done, applied = {}, false
    local pending = Support.pending(record)
    local levels = Support.levels(record)
    for _, r in ipairs(Support.requests(record)) do
        if r.to ~= (levels[r.id] or 0) + 1 then
            pending[r.id] = nil
        else
            local paid = balance >= r.price
            if paid then
                balance = balance - r.price
                levels[r.id] = r.to
                pending[r.id] = nil
                applied = true
            end
            done[#done + 1] = { id = r.id, from = r.from, to = r.to, price = r.price, paid = paid }
        end
    end
    if applied then changed(record) end
    return balance, done
end

-- Words ------------------------------------------------------------------------------------------------------------
-- A value or a change as a text to translate where it is shown: { key, args }, args being strings or such texts
-- (the titles translate them on the player's side). IGUI_OA_Support_Name_<id> names an upgrade.

function Support.nameKey(id)
    return "IGUI_OA_Support_Name_" .. id
end

local function number(v)
    if v == math.floor(v) then return tostring(v) end
    return tostring(math.floor(v * 100 + 0.5) / 100)
end

function Support.valueText(id, value)
    if type(value) == "boolean" then return { key = "IGUI_OA_Support_" .. id .. "_" .. tostring(value) } end
    if id == "arrive" then return { key = "IGUI_OA_Support_V_arrive", args = { number(value[1]), number(value[2]) } } end
    if id == "rate" or id == "discount" or id == "mpay" or id == "mstreak" then
        return { key = "IGUI_OA_Support_V_" .. id, args = { number(value * 100) } }
    end
    -- the request price as what it adds: ×1.2 is "+20%"
    if id == "reqprice" then return { key = "IGUI_OA_Support_V_reqprice", args = { number(OA.round((value - 1) * 100)) } } end
    return { key = "IGUI_OA_Support_V_" .. id, args = { number(value) } }
end

-- "상자 용량 50 → 100" for level `from` to level `to`.
function Support.changeText(id, from, to)
    return { key = "IGUI_OA_Support_Change", args = { { key = Support.nameKey(id) },
        Support.valueText(id, Support.step(id, from).value), Support.valueText(id, Support.step(id, to).value) } }
end

-- The title after a settlement that applied upgrades (DESIGN-terminal 2.6): "운항 지원 반영", the changes under it
-- joined by " · ", from the fourth on counted ("외 N건"). nil when none was applied.
function Support.appliedTitle(done)
    local changes = {}
    for _, d in ipairs(done or {}) do
        if d.paid then changes[#changes + 1] = Support.changeText(d.id, d.from, d.to) end
    end
    if #changes == 0 then return nil end
    local sub
    if #changes <= 3 then
        sub = { key = "IGUI_OA_Support_Joined" .. #changes, args = changes }
    else
        sub = { key = "IGUI_OA_Support_JoinedMore", args = { changes[1], changes[2], changes[3], tostring(#changes - 3) } }
    end
    return { key = "IGUI_OA_Title_SupportApplied", sub = sub.key, subArgs = sub.args, style = "notice", size = "minor" }
end

return Support
