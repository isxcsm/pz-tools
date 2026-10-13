-- The PZ Extension API's power networks, by a handle of their own ("APITest"), not through Building Utilities: generators
-- the check puts down, one network "apit" over them under "sequential" with an extra load of 1, and no building.
-- Phases, each started from the console after RUN("api_power.lua") (positions are kept in ModData APITEST, so a phase
-- runs again after a load):
--   APIT.far()   at the test panel (bu_tp.lua): puts generator F down, full and off.
--   APIT.site()  at the tower (bu_tptower.lua): puts A, B, C down and defines the network {A, B, C}; then a step a
--                game minute: switched on and off by hand (B, then A, out of service); a failover to C; C running
--                out with A and B left off; a source carrying and stopping (C takes over, A and B left off); the
--                network switched off and on with setEnabled (C stops on standby and starts again). It ends with F
--                added to the list and C's fuel set to last about an hour and a half.
--   APIT.away()  teleports to F (C's square no longer loaded) and waits: C runs out where it is not loaded, F takes
--                over from that hour. Then F's fuel is set to last about an hour and a half: save and load again here.
--   APIT.again() after the load: the network defined again (as a mod defines it on load) and waits for F to run out.
--   APIT.back()  teleports to the tower: A and B still out of service (their marks outlast the load), C off.
--   APIT.clear() takes the network and the loaded generators away (run it at both places).
-- "[apit]" lines, each check "ok" or "BAD"; "phase done" ends a phase.
RUN("bu_lib.lua")
APIT = APIT or {}
local T = APIT
local say = BUT.say("apit")
local function check(what, got, want) say(got == want and "ok" or "BAD", what, tostring(got), "want", tostring(want)) end
local ID = "apit"
local data = ModData.getOrCreate("APITEST")

local function handle() return PZExtAPI.client("APITest") end
local function hour() return getGameTime():getWorldAgeHours() end
local function state() return PZExtAPI.networks.state(ID) end
local function key(p) return p and (p.x .. "," .. p.y .. "," .. p.z) or "-" end
local function generator(name)
    local p = data[name]
    local q = p and getCell():getGridSquare(p.x, p.y, p.z)
    return q and q:getGenerator()
end

-- Who carries the load: a generator's name, a source's name, or "none".
local function carrier()
    local s = state()
    local p = s and s.producer
    if not p then return "none" end
    if p.source then return p.source end
    for _, name in ipairs({ "A", "B", "C", "F" }) do if key(data[name]) == key(p) then return name end end
    return key(p)
end

-- A generator as the network sees it: "running", "out" (out of service), "standby", or "unseen" (not seen loaded).
local function seen(name)
    local s = state()
    for _, p in ipairs(s and s.producers or {}) do
        if not p.source and key(p) == key(data[name]) then
            if p.running == nil then return "unseen" end
            return p.running and "running" or (p.outOfService and "out" or "standby")
        end
    end
    return "absent"
end

local function show(tag)
    local s = state()
    local parts = {}
    for _, name in ipairs({ "A", "B", "C", "F" }) do
        local g = generator(name)
        parts[#parts + 1] = name .. "=" .. seen(name) .. (g and ("/" .. tostring(g:isActivated()) .. "/" .. BUT.f(g:getFuel())) or "")
    end
    say(tag, "hour", BUT.f(hour()), "supplied", s and tostring(s.supplied), "carrier", carrier(),
        "fuelPerHour", s and BUT.f(s.fuelPerHour), table.concat(parts, " "))
end

local function producers(withF, withSource)
    local list = {}
    for _, name in ipairs({ "A", "B", "C" }) do list[#list + 1] = data[name] end
    if withF then list[#list + 1] = data.F end
    if withSource then list[#list + 1] = { source = "s1" } end
    return list
end

local function define(withF)
    local h = handle()
    PZExtAPI.networks.define(h, ID, "power", "sequential")
    PZExtAPI.networks.setProducers(h, ID, producers(withF))
    PZExtAPI.networks.setExtraLoad(h, ID, 1)
end

-- What the API raises for the network: { what, hour }.
T.events = T.events or {}
if not T.listening then
    Events.OnPZExtNetworkChange.Add(function(id, what, at)
        if id ~= ID then return end
        T.events[#T.events + 1] = { what = what, hour = at }
        say("event", what, BUT.f(at))
    end)
    T.listening = true
end
local function lastEvent(what)
    for i = #T.events, 1, -1 do if T.events[i].what == what then return T.events[i] end end
end

-- Runs steps a game minute apart. A step returns "again" to run again next minute (up to its limit), "stop" to end.
local function run(name, steps, limit)
    local step, tries = 1, 0
    local function onMinute()
        local ok, result = pcall(steps[step])
        if not ok then say("BAD", name, "step", step, "failed:", result) end
        if ok and result == "again" then
            tries = tries + 1
            if tries < (limit or 150) then return end
            say("BAD", name, "step", step, "waited", tries, "minutes")
        end
        tries = 0
        step = step + 1
        if not ok or result == "again" or result == "stop" or step > #steps then
            Events.EveryOneMinute.Remove(onMinute)
            setGameSpeed(1)
            show(name .. " end")
            say(name, "phase done")
        end
    end
    Events.EveryOneMinute.Add(onMinute)
    say(name, "waiting:", #steps, "steps, one a game minute")
end

local function put(name)
    local q = BUT.squareNear(2, 12, BUT.freeOutside)
    if not q then say("BAD no free square outside for", name); return end
    local g = IsoGenerator.new(instanceItem("Base.Generator"), getCell(), q)
    g:setFuel(g:getMaxFuel())
    g:setCondition(100)
    data[name] = { x = q:getX(), y = q:getY(), z = q:getZ() }
    return g
end

local function teleport(p)
    local player = getPlayer()
    local x, y = p.x + 2.5, p.y + 0.5
    player:setX(x) player:setY(y) player:setZ(p.z)
    player:setLastX(x) player:setLastY(y) player:setLastZ(p.z)
end

-- The fuel for the given hours at the network's rate now.
local function fuelFor(hours)
    local s = state()
    return s and s.fuelPerHour and s.fuelPerHour * hours
end

function T.far()
    if put("F") then data.farAt = { x = getPlayer():getX(), y = getPlayer():getY(), z = getPlayer():getZ() } end
    say("F at", key(data.F))
    say("far phase done")
end

function T.site()
    if not data.F then say("BAD no F: run APIT.far() at the test panel first"); return end
    for _, name in ipairs({ "A", "B", "C" }) do put(name) end
    data.siteAt = { x = getPlayer():getX(), y = getPlayer():getY(), z = getPlayer():getZ() }
    define(false)
    generator("A"):setActivated(true)
    local A, B, C = generator("A"), generator("B"), generator("C")
    local h = handle()
    setGameSpeed(2)
    run("site", {
        function()
            check("A switched on carries", carrier(), "A")
            B:setActivated(true)
        end,
        function()
            check("B switched on by hand carries", carrier(), "B")
            check("A on standby", seen("A"), "standby")
            B:setActivated(false)
        end,
        function()
            check("B switched off by hand: out of service", seen("B"), "out")
            check("B switched off: A takes over", carrier(), "A")
            A:setActivated(false)
        end,
        function()
            check("A switched off by hand: out of service", seen("A"), "out")
            check("failover to C", carrier(), "C")
            check("failover: B stays off", B:isActivated(), false)
            C:setFuel(fuelFor(0.5))
            T.ranOutFrom = hour()
            setGameSpeed(4)
        end,
        function()
            if carrier() ~= "none" then return "again" end
            setGameSpeed(2)
            check("C ran out: the network stops", state().supplied, false)
            check("C ran out: C not running", C:isActivated(), false)
            check("C ran out: A and B stay off", tostring(A:isActivated()) .. " " .. tostring(B:isActivated()), "false false")
            check("C ran out: A and B still out of service", seen("A") .. " " .. seen("B"), "out out")
            local e = lastEvent("supply")
            say("supply event at", e and BUT.f(e.hour), "C fuelled at", BUT.f(T.ranOutFrom))
            C:setFuel(C:getMaxFuel())
            PZExtAPI.networks.setProducers(h, ID, producers(false, true))
            PZExtAPI.networks.setSource(h, ID, "s1", true, true)
        end,
        function()
            check("the source switched on carries", carrier(), "s1")
            check("C on standby", seen("C"), "standby")
            PZExtAPI.networks.setSource(h, ID, "s1", false)
        end,
        function()
            check("the source stopped: C takes over", carrier(), "C")
            check("the source stopped: A and B stay off", tostring(A:isActivated()) .. " " .. tostring(B:isActivated()), "false false")
            PZExtAPI.networks.setEnabled(h, ID, false)
        end,
        function()
            local s = state()
            check("switched off: no supply", s.supplied, false)
            check("switched off: enabled", s.enabled, false)
            check("switched off: C stopped", C:isActivated(), false)
            check("switched off: C on standby, not out of service", seen("C"), "standby")
            PZExtAPI.networks.setEnabled(h, ID, true)
        end,
        function()
            check("switched on: C starts again", carrier(), "C")
            check("switched on: C running", C:isActivated(), true)
            check("switched on: A and B stay off", tostring(A:isActivated()) .. " " .. tostring(B:isActivated()), "false false")
            PZExtAPI.networks.setProducers(h, ID, producers(true))
            check("F added: C still carries", carrier(), "C")
            C:setFuel(fuelFor(1.5))
            data.cFuelledAt = hour()
            say("C fuelled for 1.5 hours at", BUT.f(data.cFuelledAt), ": next APIT.away()")
            return "stop"
        end,
    })
end

function T.away()
    if not data.farAt then say("BAD no F"); return end
    T.events = {}
    teleport(data.farAt)
    setGameSpeed(4)
    run("away", {
        function()
            if carrier() ~= "F" then return "again" end
            local e = lastEvent("producer")
            local now = hour()
            say("F took over: event hour", e and BUT.f(e.hour), "now", BUT.f(now), "C fuelled at", BUT.f(data.cFuelledAt))
            check("the event's hour is a whole hour", e and e.hour == math.floor(e.hour), true)
            check("C ran out within two hours of its fuelling", e and e.hour > data.cFuelledAt and e.hour <= data.cFuelledAt + 2, true)
            check("F running", generator("F"):isActivated(), true)
            check("C not loaded", generator("C"), nil)
            -- F burns the hours since C ran out on its next update.
            T.fFuel = generator("F"):getFuel()
        end,
        function()
            if hour() < (lastEvent("producer") or { hour = 0 }).hour + 2 then return "again" end
            local s = state()
            local burned = T.fFuel - generator("F"):getFuel()
            say("F burned", BUT.f(burned), "since it took over, fuelPerHour", BUT.f(s.fuelPerHour))
            generator("F"):setFuel(fuelFor(1.5))
            data.fFuelledAt = hour()
            say("F fuelled for 1.5 hours at", BUT.f(data.fFuelledAt), ": save and load again here, then APIT.again()")
            return "stop"
        end,
    }, 240)
end

function T.again()
    T.events = {}
    define(true)
    show("defined again")
    setGameSpeed(4)
    run("again", {
        function()
            if state().supplied or carrier() ~= "none" then return "again" end
            local e = lastEvent("supply")
            say("F ran out: supply event at", e and BUT.f(e.hour), "F fuelled at", BUT.f(data.fFuelledAt))
            check("F not running", generator("F"):isActivated(), false)
            check("F ran out within two hours of its fuelling", e and e.hour > data.fFuelledAt and e.hour <= data.fFuelledAt + 2, true)
            return "stop"
        end,
    }, 240)
end

function T.back()
    teleport(data.siteAt)
    run("back", {
        function() end,
        function()
            check("A off", generator("A"):isActivated(), false)
            check("B off", generator("B"):isActivated(), false)
            check("A still out of service after the load", seen("A"), "out")
            check("B still out of service after the load", seen("B"), "out")
            check("C off", generator("C"):isActivated(), false)
            check("nothing carries", carrier(), "none")
            return "stop"
        end,
    })
end

function T.clear()
    handle():clear()
    local left = {}
    for _, name in ipairs({ "A", "B", "C", "F" }) do
        local g = generator(name)
        if g then g:setActivated(false) g:remove() data[name] = nil
        elseif data[name] then left[#left + 1] = name end
    end
    say("cleared; not loaded here, run APIT.clear() by them:", table.concat(left, " "))
end
say("loaded: APIT.far / site / away / again / back / clear")
