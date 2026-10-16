-- A box's generator while nobody is near, at the test panel (bu_setup.lua): a fuelled generator in the yard carries
-- the load (the solar side faked out, no bank); the player goes far off (its square no longer loaded), the game runs
-- some hours fast, and back: the fuel it burned meanwhile is about its rate over those hours, and it still carries
-- the load. "[buaway]" lines, each "ok" or "BAD"; "done" at the end, about a minute later. The player is put back,
-- the speed set to 1, the generator taken away and the faked functions put back.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Changes, Energy, Networks = BU.Store, BU.Panels, BU.Changes, BU.Energy, BU.Networks
local player = getPlayer()
local bad = 0
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[buaway] " .. table.concat(parts, " "))
end
local function check(label, got, want)
    local ok = got == want
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", label, got, "want", want)
end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local HOURS, FAR = 4, 600
local outputOf, bankOf = Energy.output, Energy.bank
local home = { x = player:getX(), y = player:getY(), z = player:getZ() }

local sq = BUT.square(panel.x, panel.y, 0, 3, 12, function(s)
    return s:isOutside() and s:isFree(false) and not s:getGenerator() and BuildingUtilities.Links.get(BuildingUtilities.Links.producerRef(s:getX(), s:getY(), 0)) == nil
        and not Panels.buildingAt(s:getX(), s:getY(), 0)
end)
if not sq then say("BAD no square for the generator"); return end
local gx, gy = sq:getX(), sq:getY()
local key = gx .. "," .. gy .. ",0"
Energy.output = function() return 0, 1, 0 end
Energy.bank = function() return nil end
local generator = IsoGenerator.new(instanceItem("Base.Generator"), getCell(), sq)
generator:setFuel(generator:getMaxFuel())
generator:setCondition(100)
Changes.connectProducer(panel, "power", gx, gy, 0, {})
generator:setActivated(true)
say("generator at", key)

local function carrier()
    local state = Networks.state(panel, "power")
    local producer = state and state.producer
    return producer and (producer.source or (producer.x .. "," .. producer.y .. "," .. producer.z)) or "none"
end
local function generatorHere()
    local square = getCell():getGridSquare(gx, gy, 0)
    return square and square:getGenerator()
end
-- The game's speed as its buttons set it: the speed and the time's multiplier (1, 5, 20, 40 for speeds 1 to 4).
local MULTIPLIERS = { 1, 5, 20, 40 }
local function speed(n)
    UIManager.getSpeedControls():SetCurrentGameSpeed(n)
    getGameTime():setMultiplier(MULTIPLIERS[n])
end
local function moveTo(x, y, z)
    player:setX(x) player:setY(y) player:setZ(z)
    player:setLastX(x) player:setLastY(y) player:setLastZ(z)
end
local function finish()
    speed(1)
    moveTo(home.x, home.y, home.z)
    Energy.output, Energy.bank = outputOf, bankOf
    local g = generatorHere()
    Changes.disconnectProducer(panel, "power", gx, gy, 0)
    if g then g:setActivated(false); g:remove() end
    say("done:", bad, "BAD")
end

local phase, startHour, fuel0, rate, awayHours = "carry", nil, nil, nil, nil
local function now() return getGameTime():getWorldAgeHours() end
local minutes = 0
local function onMinute()
    minutes = minutes + 1
    if phase == "carry" and minutes >= 3 then
        check("before: the generator carries", carrier(), key)
        local state = Networks.state(panel, "power")
        rate = state and state.fuelPerHour
        fuel0, startHour = generator:getFuel(), now()
        say("fuel", string.format("%.3f", fuel0), "per hour", rate and string.format("%.4f", rate))
        moveTo(gx - FAR, gy - FAR, 0)
        speed(3)
        phase = "away"
    elseif phase == "away" then
        if minutes == 6 then say("away: its square loaded", getCell():getGridSquare(gx, gy, 0) ~= nil) end
        if now() - startHour >= HOURS then
            awayHours = now() - startHour
            speed(1)
            moveTo(home.x, home.y, home.z)
            phase, minutes = "back", 0
        end
    elseif phase == "back" and minutes >= 3 then
        Events.EveryOneMinute.Remove(onMinute)
        local g = generatorHere()
        check("back: the generator there", g ~= nil, true)
        if g and rate then
            local burned, want = fuel0 - g:getFuel(), rate * (now() - startHour)
            say("burned", string.format("%.3f", burned), "over", string.format("%.2f", now() - startHour), "h, by its rate",
                string.format("%.3f", want), "away", string.format("%.2f", awayHours), "h")
            check("back: about its rate (within a fifth)", math.abs(burned - want) <= want * 0.2, true)
        end
        check("back: it still carries", carrier(), key)
        check("back: still running", g and g:isActivated(), true)
        finish()
    end
end
Events.EveryOneMinute.Add(onMinute)
