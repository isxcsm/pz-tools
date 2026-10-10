-- The market (NUMBERS 2): one index per category, the product of three coefficients, kept in the world save.
--   index = clamp(M * S * E, 0.3, 2.0)
--   M the market: a random walk that falls back to 1 (10% of the way a day, +-5% of noise), 0.70..1.30.
--   S the supply: 0.97 for every 10 weight of the category shipped (down to 0.40), +0.03 a day back to 1.
--   E the events: one per category, the largest raise; a glut (x0.8) only when no raise is on.
-- The index is read live (a few multiplications), so a tooltip never shows a price the last flight has changed.
-- The random demand draws its category by the season (OA.Season). The delivery tab's "this week" lines are worked out
-- from this state (Market.situation); nothing is kept for them but a counter (`news`) of events begun and ended, which
-- the tab's dot waits on.
-- Randomness goes through OA.randomFloat / OA.random at call time, so a test can fix it.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Season"
local OA = OperationAcorn
local Market = {}
OA.Market = Market

Market.MIN, Market.MAX = 0.3, 2.0
Market.M_MIN, Market.M_MAX = 0.70, 1.30
Market.REVERT, Market.NOISE = 0.10, 0.05
Market.SUPPLY_DROP, Market.SUPPLY_DROP_SOFT = 0.97, 0.9775
Market.SUPPLY_PER_WEIGHT = 10
Market.SUPPLY_MIN, Market.RECOVERY = 0.40, 0.03
Market.HISTORY_DAYS = 30
Market.MAX_CATCH_UP = 40

-- What the team wants on entering a stage (NUMBERS 2): the categories, for 14 days at x1.3.
Market.STAGE_WANTS = { [1] = { "B", "G" }, [2] = { "B", "G" }, [3] = { "D" }, [4] = { "I", "J" }, [5] = { "D" } }
Market.STAGE_EVENT_MULT, Market.STAGE_EVENT_DAYS = 1.3, 14
-- The story event of stage 2, "filter samples needed at once".
Market.FILTER_EVENT = { stage = 2, cat = "B", mult = 1.5, days = 10 }

local listeners = {}

-- Listens to the events the market raises: fn(event) with { kind = "stage"|"demand"|"glut"|"refusal"|"story",
-- cat, mult, days, key }. The server titles a refusal; the delivery tab shows the rest from the market's state.
function Market.listen(fn)
    table.insert(listeners, fn)
end

-- Counts an event begun or ended (the delivery tab shows a dot until it has been looked at).
local function news(st)
    st.news = (st.news or 0) + 1
end

function Market.news()
    return Market.state().news or 0
end

local function raise(event)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, event)
        if not ok then OA.log("market listener failed:", tostring(err)) end
    end
end

-- The saved state, made the first time.
function Market.state()
    local st = OA.Store.world("market")
    if not st.M then
        local day = OA.day()
        st.day = day
        st.M, st.S = {}, {}
        for _, c in ipairs(OA.Categories.LETTERS) do
            st.M[c] = 1.0
            st.S[c] = 1.0
        end
        st.events = {}
        st.refused = {}
        st.due = {}
        st.history = {}
        st.totals = {}
        st.news = 0
        st.nextDemand = day + OA.random(10, 15)
        st.nextRefusal = day + OA.random(20, 30)
    end
    return st
end

-- The event factor of a category on a day: the largest raise, else the glut, else 1.
local function eventFactor(st, cat, day)
    local best, glut = 1.0, 1.0
    for _, e in ipairs(st.events) do
        if e.cat == cat and e.ends > day then
            if e.mult > 1.0 then
                if e.mult > best then best = e.mult end
            elseif e.mult < glut then
                glut = e.mult
            end
        end
    end
    if best > 1.0 then return best end
    return glut
end

local function compose(m, s, e)
    return OA.clamp(m * s * e, Market.MIN, Market.MAX)
end

-- The index now of a category (1.0 for one the market does not know).
function Market.index(category)
    local st = Market.state()
    local m = st.M[category]
    if not m then return 1.0 end
    return compose(m, st.S[category], eventFactor(st, category, st.day))
end

-- The factors behind an index, for the terminal's price board.
function Market.parts(category)
    local st = Market.state()
    if not st.M[category] then return nil end
    return { market = st.M[category], supply = st.S[category], event = eventFactor(st, category, st.day) }
end

-- Whether the team refuses a category for now (a notice in the estimate window before sealing; a sealed box is
-- never turned away).
function Market.refused(category)
    local st = Market.state()
    local ends = st.refused[category]
    return ends ~= nil and ends > st.day
end

-- Adds an event: `days` days at x`mult` on a category. A story event of another part uses this too.
function Market.addEvent(category, mult, days, key, kind)
    local st = Market.state()
    table.insert(st.events, { cat = category, mult = mult, ends = st.day + days, key = key })
    news(st)
    raise({ kind = kind or "story", cat = category, mult = mult, days = days, key = key })
end

-- Called when a player enters a stage: the categories the team wants for 14 days (and stage 2's story event).
function Market.stageEvent(stage)
    local wants = Market.STAGE_WANTS[stage]
    if wants then
        for _, c in ipairs(wants) do
            Market.addEvent(c, Market.STAGE_EVENT_MULT, Market.STAGE_EVENT_DAYS, "IGUI_OA_Econ_Event_StageWant", "stage")
        end
    end
    local f = Market.FILTER_EVENT
    if stage == f.stage then
        Market.addEvent(f.cat, f.mult, f.days, "IGUI_OA_Econ_Event_FilterSamples", "story")
    end
end

-- The most trust stage any player has: the refusals start with the first stage.
local function topStage()
    local top = 0
    for _, record in pairs(OA.Store.players()) do
        local stage = record.trade and record.trade.stage or 0
        if stage > top then top = stage end
    end
    return top
end

-- Folds history older than 30 days into totals { n, sum, min, max }.
local function fold(st, cat, day)
    local list = st.history[cat]
    if not list then return end
    local totals = st.totals[cat]
    while list[1] and day - list[1].d >= Market.HISTORY_DAYS do
        local e = table.remove(list, 1)
        if not totals then
            totals = { n = 0, sum = 0, min = e.i, max = e.i }
            st.totals[cat] = totals
        end
        totals.n = totals.n + 1
        totals.sum = totals.sum + e.i
        if e.i < totals.min then totals.min = e.i end
        if e.i > totals.max then totals.max = e.i end
    end
end

local function step(st, day, top, season)
    local letters = OA.Categories.LETTERS
    for _, c in ipairs(letters) do
        local m = st.M[c] + Market.REVERT * (1.0 - st.M[c]) + OA.randomFloat(-Market.NOISE, Market.NOISE)
        st.M[c] = OA.clamp(m, Market.M_MIN, Market.M_MAX)
        st.S[c] = math.min(1.0, st.S[c] + Market.RECOVERY)
    end
    for i = #st.events, 1, -1 do
        if st.events[i].ends <= day then
            table.remove(st.events, i)
            news(st)
        end
    end
    for c, ends in pairs(st.refused) do
        if ends <= day then
            st.refused[c] = nil
            news(st)
        end
    end
    st.day = day
    -- Random demand, every 10 to 15 days; one time in three the team has too much of a category instead. The
    -- category is drawn by the season's weights; a glut never lands on one the season raises. A demand for a category
    -- the season raises is told in the team's words for the season.
    if day >= st.nextDemand then
        local glut = OA.random(1, 3) == 1
        local c, key
        if glut then
            c = OA.Season.pickOther(letters, season, OA.random)
            key = "IGUI_OA_Econ_Event_Glut"
        else
            c = OA.Season.pick(letters, season, OA.random)
            if OA.Season.raised(season, c) then
                key = OA.Season.lineKey(season, c, OA.random(1, OA.Season.LINES))
            else
                key = "IGUI_OA_Econ_Event_Demand"
            end
        end
        local mult = glut and 0.8 or 1.25
        table.insert(st.events, { cat = c, mult = mult, ends = day + 5, key = key })
        news(st)
        raise({ kind = glut and "glut" or "demand", cat = c, mult = mult, days = 5, key = key })
        st.nextDemand = day + OA.random(10, 15)
    end
    -- A category refused for a week, from the first stage on, every 20 to 30 days. It comes back as a request.
    if top >= 1 and day >= st.nextRefusal then
        local c = letters[OA.random(1, #letters)]
        st.refused[c] = day + 7
        table.insert(st.due, { cat = c, day = day + 7 + OA.random(14, 21) })
        news(st)
        raise({ kind = "refusal", cat = c, days = 7 })
        st.nextRefusal = day + OA.random(20, 30)
    end
    for _, c in ipairs(letters) do
        local list = st.history[c]
        if not list then
            list = {}
            st.history[c] = list
        end
        table.insert(list, { d = day, i = compose(st.M[c], st.S[c], eventFactor(st, c, day)) })
        fold(st, c, day)
    end
end

-- Brings the market to a game day (EveryDays): one step for every day since the last. A save that was away for
-- longer than a market remembers (40 days) takes the last 40 steps.
function Market.update(day)
    day = day or OA.day()
    local st = Market.state()
    if st.day >= day and st.history.A then return end
    local top = topStage()
    local season = OA.Season.current()
    local from = st.day + 1
    if st.history.A == nil then from = st.day end
    if day - from + 1 > Market.MAX_CATCH_UP then from = day - Market.MAX_CATCH_UP + 1 end
    for d = from, day do step(st, d, top, season) end
end

-- Weight shipped: the supply of a category falls by 0.97 for every 10 weight (0.9775 with the "softer supply"
-- reward), down to 0.40. `record` is the shipper's.
function Market.ship(category, weight, record)
    if not weight or weight <= 0 then return end
    local st = Market.state()
    local s = st.S[category]
    if not s then return end
    local soft = false
    if record and OA.Trust then soft = OA.Trust.rewards(record).softerSupply end
    local rate = soft and Market.SUPPLY_DROP_SOFT or Market.SUPPLY_DROP
    st.S[category] = math.max(Market.SUPPLY_MIN, s * rate ^ (weight / Market.SUPPLY_PER_WEIGHT))
end

-- The last 30 days of a category as { { d = day, i = index } ... } and what came before as totals
-- { n, sum, min, max } or nil.
function Market.history(category)
    local st = Market.state()
    return st.history[category] or {}, st.totals[category]
end

-- Tomorrow's direction for a category, "up", "down" or "flat" (the 3rd stage reward): the drift only, what is
-- known today (the walk back to 1, the supply recovering, events ending), not the noise.
function Market.forecast(category)
    local st = Market.state()
    local m = st.M[category]
    if not m then return "flat" end
    local now = compose(m, st.S[category], eventFactor(st, category, st.day))
    local m2 = OA.clamp(m + Market.REVERT * (1.0 - m), Market.M_MIN, Market.M_MAX)
    local s2 = math.min(1.0, st.S[category] + Market.RECOVERY)
    local tomorrow = compose(m2, s2, eventFactor(st, category, st.day + 1))
    if tomorrow > now * 1.01 then return "up" end
    if tomorrow < now / 1.01 then return "down" end
    return "flat"
end

-- The categories that were refused and are due back as a request in a span of days (both included), once each.
function Market.dueRequests(firstDay, lastDay)
    local st = Market.state()
    local found = {}
    for _, e in ipairs(st.due) do
        if e.day >= firstDay and e.day <= lastDay then table.insert(found, e.cat) end
    end
    return found
end

-- The line for a category refused for a while ("start") or come back as a request ("back"): the story part's
-- words when it is there (they know the categories it has lines for), else this part's own. Returns key, args.
function Market.refusalLine(category, phase)
    local story = OA.Story
    if story and story.refusalKey then
        return story.refusalKey(category, phase), nil
    end
    local key = phase == "back" and "IGUI_OA_Econ_Radio_RefuseBack" or "IGUI_OA_Econ_Radio_RefuseStart"
    return key, { getText(OA.Categories.nameKey(category)) }
end

-- What is going on in the market now, one line for each category it touches (DESIGN-terminal 5.2): the largest raise
-- on a category, else its glut (the same rule as the index), and the categories the team does not take. Worked out
-- from the state each time it is asked (the delivery tab asks when it is redrawn); nothing is kept.
--   { kind = "raise" | "glut" | "refusal", cat, mult (nil for a refusal), left (days more), key, withCat }
-- `key` is the text's translation key; `withCat` says its %1 is the category's name (a season's line names none).
-- Raises come first, the largest first, then gluts, then refusals; the same kind by category.
Market.REFUSAL_KEY = "IGUI_OA_Econ_Event_Refusal"

local SITUATION_RANK = { raise = 1, glut = 2, refusal = 3 }

function Market.situation()
    local st = Market.state()
    local day = st.day
    local lines = {}
    for _, c in ipairs(OA.Categories.LETTERS) do
        local best, glut
        for _, e in ipairs(st.events) do
            if e.cat == c and e.ends > day then
                if e.mult > 1.0 then
                    if not best or e.mult > best.mult then best = e end
                elseif not glut or e.mult < glut.mult then
                    glut = e
                end
            end
        end
        local e = best or glut
        if e then
            local key = e.key or (best and "IGUI_OA_Econ_Event_Demand" or "IGUI_OA_Econ_Event_Glut")
            lines[#lines + 1] = { kind = best and "raise" or "glut", cat = c, mult = e.mult, left = e.ends - day,
                key = key, withCat = not OA.Season.isLineKey(key) }
        end
        local ends = st.refused[c]
        if ends and ends > day then
            lines[#lines + 1] = { kind = "refusal", cat = c, left = ends - day, key = Market.REFUSAL_KEY, withCat = true }
        end
    end
    table.sort(lines, function(a, b)
        if a.kind ~= b.kind then return SITUATION_RANK[a.kind] < SITUATION_RANK[b.kind] end
        if a.kind == "raise" and a.mult ~= b.mult then return a.mult > b.mult end
        return a.cat < b.cat
    end)
    return lines
end

-- Forgets due requests that are past (kept ten weeks).
function Market.prune(day)
    local st = Market.state()
    for i = #st.due, 1, -1 do
        if st.due[i].day < day - 70 then table.remove(st.due, i) end
    end
end

return Market
