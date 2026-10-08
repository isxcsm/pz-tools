-- The helicopter's rules as plain functions of numbers and tables, so that they can be tested outside the game:
-- when a call arrives, when the next call is possible, how a settlement pays a debt first, how orders are paid in
-- order with partial delivery, and when the first supply is due (DESIGN 9, NUMBERS 8).
require "OperationAcorn/Core"
local OA = OperationAcorn
local Rules = {}
OA.Trade = OA.Trade or {}
OA.Trade.Rules = Rules

-- The hours the helicopter flies: 07:00 to 19:00. A night arrival moves to the next morning, 07:00 to 09:00.
Rules.DAY_START, Rules.DAY_END, Rules.MORNING_SPREAD = 7, 19, 2

-- Hours of the day, 0 up to 24, of the moment `delay` hours after one whose time of day is `tod`.
function Rules.timeOfDayAfter(tod, delay)
    return OA.remainder(tod + delay, 24)
end

-- When a call made at world age `now` (hours), at time of day `tod`, arrives. `delay` is the hours the call takes (a
-- number between the rewards' arrival range); `extra` is 0 up to 2 hours added when it moves to the morning. With
-- the night drop reward the arrival stays as it is; without it a night arrival comes the next morning.
function Rules.arrival(now, tod, delay, nightDrop, extra)
    local arrive = now + delay
    local at = Rules.timeOfDayAfter(tod, delay)
    if nightDrop or (at >= Rules.DAY_START and at < Rules.DAY_END) then return arrive end
    local wait
    if at >= Rules.DAY_END then wait = (24 - at) + Rules.DAY_START else wait = Rules.DAY_START - at end
    return arrive + wait + OA.clamp(extra or 0, 0, Rules.MORNING_SPREAD)
end

-- How many hours a call takes: a number from the rewards' range (min, max in hours), picked by `rnd(a, b)`.
function Rules.callDelay(range, rnd)
    local lo, hi = range.min or 4, range.max or 6
    if hi < lo then hi = lo end
    return rnd(lo, hi)
end

-- Whether a call can be made now. The heli table is the record's heli section: call (the pending call), next (the
-- world age from which the next call is possible). Returns true, or false and a reason.
function Rules.canCall(heli, now)
    if heli.call then return false, "pending" end
    if heli.next and now < heli.next then return false, "wait" end
    return true
end

-- Makes a call: the pending call and the time the next one is possible (the interval counts from the call).
function Rules.startCall(heli, now, arriveAt, intervalDays, call)
    call = call or {}
    call.at, call.arrive = now, arriveAt
    heli.call = call
    heli.next = now + intervalDays * 24
    return call
end

-- A settlement's credits added to the balance: a debt (a negative balance) is repaid first, so the balance only
-- passes zero with what is left. Returns the new balance and how much of the debt this repaid.
function Rules.applyGain(credits, gain)
    local debt = credits < 0 and -credits or 0
    return credits + gain, math.min(debt, math.max(gain, 0))
end

-- What stage events a trust change brings, as a list of { kind = "stage", n = ... } and { kind = "milestone", n = ... }.
-- OA.Trust.add returns the stages and milestones passed; this reads the shapes it may give: a number (a stage), a
-- table with `stage` or `milestone`, or with `kind` and `n`/`stage`/`index`.
function Rules.stageEvents(list)
    local events = {}
    for _, e in ipairs(list or {}) do
        if type(e) == "number" then
            events[#events + 1] = { kind = "stage", n = e }
        elseif type(e) == "table" then
            local kind = e.kind
            local n = e.n or e.stage or e.milestone or e.index or e.value
            if not kind then
                if e.milestone then kind = "milestone" elseif e.stage then kind = "stage" end
            end
            if (kind == "stage" or kind == "milestone") and type(n) == "number" then
                events[#events + 1] = { kind = kind, n = n }
            end
        end
    end
    return events
end

-- Shared upgrade serums the events bring (NUMBERS 6): one for stage 2, 3, 4 and 5, then one for every
-- `every`th milestone. The first stage (1) brings none.
function Rules.sharedSerums(events, every)
    every = math.max(1, every or 1)
    local count = 0
    for _, e in ipairs(events) do
        if e.kind == "stage" and e.n >= 2 and e.n <= 5 then
            count = count + 1
        elseif e.kind == "milestone" and OA.remainder(e.n, every) == 0 then
            count = count + 1
        end
    end
    return count
end

-- Orders paid in order. `lines` is the cart: { { id, count, target } }. `svc` answers for the game:
--   svc.entry(line)                          the catalog entry, or nil
--   svc.available(entry, line, delivered)    true, or false and a reason key
--   svc.price(entry, line)                   credits for the next unit (prices may rise as units are bought)
--   svc.bought(entry, line)                  called once for each unit delivered
--   svc.items(entry, line)                   the item specs one unit brings
-- A balance below zero (a debt) pays nothing. A line stops when a unit cannot be paid or is no longer available;
-- later lines are tried, since a cheaper one may still fit. Returns the balance left, what was spent, one result per
-- line { id, target, ordered, delivered, paid, reason, name } and the item specs to send.
function Rules.payOrders(credits, lines, svc)
    local results, items, spent = {}, {}, 0
    for _, line in ipairs(lines or {}) do
        local ordered = math.max(1, math.floor(line.count or 1))
        local result = { id = line.id, target = line.target, ordered = ordered, delivered = 0, paid = 0 }
        results[#results + 1] = result
        local entry = svc.entry(line)
        if not entry then
            result.reason = "unknown"
        elseif credits < 0 then
            result.reason = "debt"
        else
            for _ = 1, ordered do
                local ok, why = svc.available(entry, line, result.delivered)
                if not ok then
                    result.reason = why or "unavailable"
                    break
                end
                local price = OA.round(svc.price(entry, line))
                if price > credits then
                    result.reason = "credits"
                    break
                end
                credits = credits - price
                spent = spent + price
                result.paid = result.paid + price
                result.delivered = result.delivered + 1
                svc.bought(entry, line)
                for _, spec in ipairs(svc.items(entry, line)) do items[#items + 1] = spec end
            end
        end
    end
    return credits, spent, results, items
end

-- First supply (DESIGN 3 and 12). The vanilla helicopter sandbox option: 1 never, 2 once, 3 sometimes, 4 often. The
-- vanilla first helicopter flies on a night count of 6 to 9 (the day number counts nights, up at 07:00), in the hours
-- of a window that ends at heliEnd.
Rules.NONE_DAY = 7
Rules.LAST_VANILLA_DAY = 9

-- The plan for a record made when it is created: how the first supply will come. `now` carries what the game says:
-- option (the sandbox value), nights (nights survived), tod (time of day), heliDay and heliEnd (the vanilla first
-- helicopter's night and the hour its window ends), `rnd(a, b)` for whole numbers.
--   mode "window": drop when the vanilla window has passed (the game's helicopter sounds meanwhile);
--   mode "none": no helicopter in the game, quietly on the 7th day;
--   mode "late": the mod came after it, quietly the next morning.
-- The plan is { mode, day, hour }; it is due once the night count passes `day`, or equals it and the time reaches
-- `hour`.
function Rules.firstPlan(now)
    local plan
    if now.option == 1 then
        plan = { mode = "none", day = Rules.NONE_DAY, hour = now.rnd(9, 17) }
    else
        local day, hour = now.heliDay, now.heliEnd
        if type(day) == "number" and type(hour) == "number" and day <= Rules.LAST_VANILLA_DAY then
            plan = { mode = "window", day = day, hour = hour }
        end
    end
    if plan and now.nights > plan.day then plan = nil end
    if not plan then
        plan = { mode = "late", day = now.nights + 1, hour = Rules.DAY_START + now.rnd(1, 2) }
    end
    return plan
end

-- Whether a plan's drop is due at a night count and time of day.
function Rules.firstDue(plan, nights, tod)
    if nights > plan.day then return true end
    return nights == plan.day and tod >= plan.hour
end

return Rules
