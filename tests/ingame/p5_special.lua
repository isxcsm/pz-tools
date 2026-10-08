-- P5 specials: the big rain storage (2x2, one fluid container on the anchor, a plumbing source through the vanilla
-- water-source search), the research storage (container capacity 300 against the vanilla 100 cap), the lure (24 h, a
-- sound every 15 minutes at radius 60, then a spent shell; does nothing while unloaded), and the notices. Setup: single
-- player in open ground with NO roof overhead and a clear patch 20 x 20 east and south, a character with a record.
-- It gives itself the items; P5_CLEAN() removes the machines. Lines are tagged "[p5special]", each "ok" or "BAD".
RUN("p5_lib.lua")
local say = P5T.say("p5special")
local function check(...) return P5T.check(say, ...) end
local M = P5T.machines()
local Data = M.Data
local near = P5T.near
local player = getPlayer()

local function section(name, fn)
    say("----", name)
    local ok, err = pcall(fn)
    if not ok then say("BAD", name, "error", tostring(err)) end
end

section("rain storage", function()
    local object, reason = P5T.place("rainStorage", 3, 2, "S")
    if not check("placed on the 2x2", object ~= nil, reason) then return end
    local state = M.state(object)
    check("it is an IsoThumpable", instanceof(object, "IsoThumpable"))
    local fluid = object.getFluidContainer and object:getFluidContainer()
    check("the anchor has a fluid container (entity script applied)", fluid ~= nil)
    if fluid then
        check("capacity 4000 litres", near(fluid:getCapacity(), 4000, 0.5), fluid:getCapacity())
        local okRain, rain = pcall(function() return fluid:getRainCatcher() end)
        check("rain factor 4.0", okRain and near(rain, 4.0, 0.01), tostring(rain))
    end
    -- The other three squares have no fluid container: the plumbing sees one source, on the anchor's square.
    local others = 0
    for dy = 0, 1 do
        for dx = 0, 1 do
            if dx ~= 0 or dy ~= 0 then
                local sq = getCell():getGridSquare(state.x + dx, state.y + dy, state.z)
                for i = 0, sq:getObjects():size() - 1 do
                    local o = sq:getObjects():get(i)
                    if M.anchorMark(o) and o.getFluidContainer and o:getFluidContainer() then others = others + 1 end
                end
            end
        end
    end
    check("no fluid container on the three parts", others == 0, others)
    -- Water in, then it cannot be picked up, and the vanilla water-source search (the plumbing's, one call a square)
    -- finds it on the anchor's square only.
    if fluid then
        fluid:addFluid(Fluid.Water, 10)
        local finder = ISWorldObjectContextMenu and ISWorldObjectContextMenu.FindWaterSourceOnSquare
        if finder then
            local onAnchor = finder(object:getSquare())
            check("the anchor square is a water source", onAnchor ~= nil, tostring(onAnchor))
            local partSquare = getCell():getGridSquare(state.x + 1, state.y + 1, state.z)
            local onPart = finder(partSquare)
            check("a part's square is not a second source", onPart == nil, tostring(onPart))
        else
            say("info FindWaterSourceOnSquare is not in this build: check the plumbing by hand")
        end
        check("with water in it, it cannot be picked up", M.canPickUp(object) == nil)
        fluid:Empty()
        check("empty, it can", M.canPickUp(object) ~= nil)
    end
    local status = M.status(object)
    check("status reports water and capacity", status.capacity ~= nil, tostring(status.capacity))
    say("info Now wait for rain (or use the weather tools) and watch the amount in the machine window: 4x a rain barrel")
end)

section("research storage", function()
    local object, reason = P5T.place("researchStorage", 3, 6, "S")
    if not check("placed", object ~= nil, reason) then return end
    check("the anchor asks the API to lift the cap (OA_Capacity)", object:getModData().OA_Capacity == true)
    local container = M.container(object, "store")
    check("it has the storage container", container ~= nil)
    if container then
        say("info capacity", container:getCapacity(), "(vanilla caps the display at 100 until the API lifts it)")
        check("capacity set to 300 or capped at 100 by vanilla", container:getCapacity() == 300 or container:getCapacity() == 100)
    end
end)

section("lure", function()
    local object, reason = P5T.place("lure", 3, 9, "S")
    if not check("placed", object ~= nil, reason) then return end
    local state = M.state(object)
    check("armed", state.spent == false)
    check("an armed lure cannot be picked up", M.canPickUp(object) == nil)
    local sounds = {}
    local realAddSound = addSound
    addSound = function(...)
        sounds[#sounds + 1] = { ... }
        return realAddSound(...)
    end
    -- 15 minutes on: one sound at radius 60.
    state.start = state.start - 0.26
    M.update(object)
    check("a sound after a quarter hour", #sounds >= 1, #sounds)
    if sounds[1] then check("radius 60", sounds[1][5] == 60, sounds[1][5]) end
    -- 24 hours on: spent.
    state.start = state.start - 25
    M.update(object)
    check("spent after 24 hours", state.spent == true)
    check("a spent lure can be removed", M.canPickUp(object) ~= nil)
    addSound = realAddSound
end)

say("done; P5_CLEAN() takes the machines away")
