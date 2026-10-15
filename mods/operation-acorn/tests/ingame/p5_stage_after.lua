-- P5: after p5_stage.lua: the stage as it stands in the world, piece by piece of its data (Story/StageData). BAD lines
-- are what is missing. Then, by the stage:
--   2: P5_PUT() leaves the case (the character is moved to the drop), P5_WAIT(f) brings the wait to f (0 to 1) and
--      says what woke and fell; P5_AWAY() moves the character away and looks once (the record is swapped in).
--   5 (and any stage with "heli"): P5_HELI() wakes what waits for the helicopter; P5_LYING() counts who still lies.
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p5stage")
local record, player = P4T.record()
local m = record and OA.Missions.active(record)
if not (m and m.stage) then say("no stage mission: RUN p5_stage.lua first"); return end
local st, site = m.stage, m.site
local def = OA.Stage.defOf(m)
P4T.check(say, "the site was set up", st.placed == true)
P4T.check(say, "its zombies were made", st.kept == true)
for role, i in pairs(st.roles or {}) do say("role", role, i) end

-- What stands round the site: the building's box and 12 squares about it, or 14 squares about open ground.
local cell = getCell()
local x1, y1, x2, y2
if site.ground then
    x1, y1, x2, y2 = math.floor(site.x) - 14, math.floor(site.y) - 14, math.floor(site.x) + 14, math.floor(site.y) + 14
else
    x1, y1, x2, y2 = site.x1 - 12, site.y1 - 12, site.x2 + 12, site.y2 + 12
end
local sprites, items, outfits = {}, {}, {}
local n = { dead = 0, fake = 0, zombies = 0, generators = 0, barricades = 0, planks = 0, locked = 0, openWindows = 0 }
local vehicles, seenCar = {}, {}
for z = 0, 2 do
    for x = x1, x2 do
        for y = y1, y2 do
            local sq = cell:getGridSquare(x, y, z)
            if sq then
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    local name = o:getSprite() and o:getSprite():getName()
                    if name then sprites[name] = (sprites[name] or 0) + 1 end
                    if instanceof(o, "IsoGenerator") then n.generators = n.generators + 1 end
                    if instanceof(o, "IsoBarricade") then
                        n.barricades = n.barricades + 1
                        n.planks = n.planks + o:getNumPlanks()
                    end
                    if instanceof(o, "IsoDoor") and o:isLockedByKey() then n.locked = n.locked + 1 end
                    if instanceof(o, "IsoWindow") and o:IsOpen() then n.openWindows = n.openWindows + 1 end
                end
                local wobs = sq:getWorldObjects()
                for i = 0, wobs:size() - 1 do
                    local it = wobs:get(i):getItem()
                    if it then items[it:getFullType()] = (items[it:getFullType()] or 0) + 1 end
                end
                local bodies = sq:getDeadBodys()
                for i = 0, bodies:size() - 1 do
                    if bodies:get(i):isFakeDead() then n.fake = n.fake + 1 else n.dead = n.dead + 1 end
                end
                local moving = sq:getMovingObjects()
                for i = 0, moving:size() - 1 do
                    local zed = moving:get(i)
                    if instanceof(zed, "IsoZombie") then
                        if zed:isFakeDead() then n.fake = n.fake + 1 else n.zombies = n.zombies + 1 end
                        local o = zed:getOutfitName() or "?"
                        outfits[o] = (outfits[o] or 0) + 1
                    end
                end
                local v = z == 0 and sq:getVehicleContainer()
                if v and not seenCar[v] then
                    seenCar[v] = true
                    vehicles[#vehicles + 1] = v
                end
            end
        end
    end
end
for k, v in pairs(n) do say("count", k, v) end
for k, v in pairs(outfits) do say("outfit", k, v) end

local function spriteList(p)
    local list = {}
    local function add(s)
        if type(s) == "table" then for _, t in ipairs(s) do add(t) end else list[#list + 1] = s end
    end
    if p.kind == "tile" and type(p.sprite) == "table" then add(p.sprite.north); add(p.sprite.west)
    elseif p.sprite then add(p.sprite) end
    for _, t in ipairs(p.tiles or {}) do add(t[3]) end
    return list
end

for i, p in ipairs(def.pieces) do
    local what = i .. " " .. p.kind .. " at " .. tostring(p.at)
    if p.kind == "tile" or p.kind == "set" or p.kind == "line" then
        local c = 0
        for _, s in ipairs(spriteList(p)) do c = c + (sprites[s] or 0) end
        P4T.check(say, what, c >= 1, c .. " tiles")
    elseif p.kind == "item" then
        local c = 0
        for _, t in ipairs(p.types or { p.type }) do c = c + (items[t] or 0) end
        P4T.check(say, what, c >= 1, c .. " items")
    elseif p.kind == "vehicle" then
        local want = p.script:gsub("^Base%.", "")
        if want == "CarLightsPolice" then want = "CarLights" end
        local found
        for _, v in ipairs(vehicles) do
            if string.find(v:getScriptName() or "", want, 1, true) then found = v end
        end
        local detail = found and (math.floor(found:getX()) .. "," .. math.floor(found:getY())) or "none"
        if found and p.fuel then
            local tank = found:getPartById("GasTank")
            detail = detail .. " fuel " .. (tank and tank:getContainerContentAmount() or "?")
        end
        if found and p.key then detail = detail .. " keys in " .. tostring(found:isKeysInIgnition()) end
        P4T.check(say, what .. " " .. want, found ~= nil, detail)
    elseif p.kind == "generator" then
        P4T.check(say, what, n.generators >= 1, n.generators)
    elseif p.kind == "board" or p.kind == "barricade" then
        P4T.check(say, what, n.barricades >= 1, n.barricades .. " barricades, " .. n.planks .. " planks")
    elseif p.kind == "lockout" or p.kind == "lock" then
        P4T.check(say, what, n.locked >= 1, n.locked .. " locked doors")
    elseif p.kind == "window" then
        P4T.check(say, what, n.openWindows >= 1, n.openWindows .. " open windows")
    elseif p.kind == "corpse" then
        P4T.check(say, what, n.dead >= 1 or IsoWorld.getZombiesDisabled(), n.dead .. " bodies")
    elseif p.kind == "zombies" then
        local c = p.look == "fakeDead" and n.fake or n.zombies
        P4T.check(say, what .. " " .. tostring(p.outfit) .. " " .. tostring(p.look), c >= 1, c)
    elseif p.kind == "piece" then
        for _, it in ipairs(m.items) do
            if it.key == p.key then
                local at = it.at
                local sq = at and cell:getGridSquare(at.x, at.y, at.z)
                P4T.check(say, what .. " " .. p.key, it.placed == true,
                    at and (at.x .. "," .. at.y .. "," .. at.z .. " " .. tostring(sq and sq:getRoom() and sq:getRoom():getName())) or "-")
            end
        end
    elseif p.kind == "blood" then
        say(what, "(not counted)")
    end
end
for _, v in ipairs(vehicles) do say("vehicle", v:getScriptName(), math.floor(v:getX()), math.floor(v:getY())) end
say("during", st.during and #st.during or 0, "wake", st.wake and st.wake.pickup and #st.wake.pickup or 0,
    st.wake and st.wake.heli and #st.wake.heli or 0)

-- 2: the swap.
function P5_PUT()
    local case
    for _, it in ipairs(m.items) do if it.key == "CASE" then case = it end end
    if not (case and case.at) then say("no drop placed"); return end
    P4T.go(case.at.x + 1, case.at.y, case.at.z)
    player:getInventory():AddItem(OA.StoryData.fullType("SampleCase"))
    P4T.check(say, "the case is left", OA.Missions.swap(record, player), m.swap.stage)
end
function P5_WAIT(f)
    m.swap.waited = f * OA.StoryData.SWAP_WAIT_HOURS - 0.01
    m.swap.at = OA.hours() - 0.01
    OA.Missions.tickSwap(record, m, OA.hours())
    say("wait", f, "stage", m.swap.stage, "left to wake", st.during and #st.during or 0)
end
function P5_AWAY()
    P4T.go(math.floor(site.x) - 60, math.floor(site.y), 0)
    OA.Missions.tickSwap(record, m, OA.hours())
    say("swap", m.swap.stage)
end

-- 5: the helicopter.
function P5_HELI()
    OA.Stage.event(record, m, "heli")
    say("heli: woken (one every", st.stagger and st.stagger.heli, "s)")
end
function P5_LYING()
    local c = 0
    for x = x1, x2 do
        for y = y1, y2 do
            local sq = cell:getGridSquare(x, y, 0)
            local bodies = sq and sq:getDeadBodys()
            for i = 0, (bodies and bodies:size() or 0) - 1 do if bodies:get(i):isFakeDead() then c = c + 1 end end
        end
    end
    say("still lying fake dead", c)
end
