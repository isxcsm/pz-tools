-- P1: the market. CHANGES THE SAVE'S MARKET (it steps it forward by days). Use a throwaway save.
-- Prints "[p1mkt]" lines.
RUN("p1_lib.lua")
local OA = OperationAcorn
local say = P1T.say("p1mkt")
local record = P1T.record()

local function dump(tag)
    local parts = {}
    for _, c in ipairs(OA.Categories.LETTERS) do parts[#parts + 1] = c .. "=" .. string.format("%.2f", OA.Market.index(c)) end
    say(tag, table.concat(parts, " "))
end

local st = OA.Market.state()
P1T.check(say, "state exists", st.M ~= nil and st.S ~= nil)
dump("now")
for _, c in ipairs(OA.Categories.LETTERS) do
    local i = OA.Market.index(c)
    if i < 0.3 - 1e-9 or i > 2.0 + 1e-9 then P1T.check(say, "index in 0.3..2.0 for " .. c, false, i) end
end

-- A flight lowers the supply factor by 0.97 per 10 weight; the index follows.
local before = OA.Market.index("F")
local sBefore = OA.Market.state().S.F
OA.Market.ship("F", 10, record)
local drop = OA.Market.state().S.F / sBefore
P1T.check(say, "10 weight of F lowers its supply to about x0.97 (softer with a reward)", drop <= 1.0 and drop >= 0.96, drop)
P1T.check(say, "the index fell", OA.Market.index("F") <= before + 1e-9, before .. " -> " .. OA.Market.index("F"))

-- A month of days: stays in range, history is kept, events fire.
local events = 0
OA.Market.listen(function(e) events = events + 1; say("event", e.kind, e.cat, e.mult, e.days) end)
local start = OA.day()
local t0 = P1T.ms()
for day = start + 1, start + 40 do OA.Market.update(day) end
say("40 steps took ms", P1T.ms() - t0)
dump("after 40 days")
local inRange = true
for _, c in ipairs(OA.Categories.LETTERS) do
    local i = OA.Market.index(c)
    if i < 0.3 - 1e-9 or i > 2.0 + 1e-9 then inRange = false end
end
P1T.check(say, "all indexes stay in 0.3..2.0", inRange)
P1T.check(say, "history is kept", #OA.Market.history("K") > 0, #OA.Market.history("K"))
say("events seen in 40 days:", events)
say("forecast A:", OA.Market.forecast("A"), "F:", OA.Market.forecast("F"))
OA.Market.prune(OA.day())
say("done (the market's saved day is now ", OA.Market.state().day, "while the game's day is", OA.day() .. "; it catches up on its own)")
