-- P4: after p4_stage1.lua: the police post's stage as it stands in the world. Prints what it finds in the site's
-- building and around its entrance; BAD lines are what is missing. Then P4S_PICKUP() and P4S_WOKE() (below).
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4stage1")
local record = P4T.record()
local m = record and OA.Missions.active(record)
if not (m and m.stage) then say("no stage mission: RUN p4_stage1.lua first"); return end
local st, site = m.stage, m.site
P4T.check(say, "the building was set up", st.placed == true)
P4T.check(say, "its zombies were made", st.kept == true)
P4T.check(say, "set up for the world", OA.Stage.world()[site.key] == true)
local layout = OA.StageGame.layout(site)
for role, i in pairs(st.roles or {}) do
    local r = role == "entrance" and layout.doors[i] or layout.rooms[i]
    say("role", role, r and (r.name or "door") or "?", r and r.x, r and r.y)
end

-- What stands in the building's box (one square around it for the outer wall).
local cell = getCell()
local found = { notice = 0, desk = 0, radio = 0, chairs = 0, barricades = 0, locked = 0, keyBodies = 0, keyFloor = 0, police = 0 }
local radioObj
local keyId = OA.StageGame and getWorld():getMetaGrid():getBuildingAtRelax(site.x, site.y)
keyId = keyId and keyId:getKeyId()
for z = site.z1 or 0, math.min(site.z2 or 0, (site.z1 or 0) + 3) do
    for x = site.x1 - 1, site.x2 + 1 do
        for y = site.y1 - 1, site.y2 + 1 do
            local sq = cell:getGridSquare(x, y, z)
            if sq then
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    local sprite = o:getSprite() and o:getSprite():getName() or ""
                    if string.find(sprite, "^papernotices_01_") then found.notice = found.notice + 1 end
                    if sprite == "furniture_tables_high_01_26" or sprite == "furniture_tables_high_01_27" then found.desk = found.desk + 1 end
                    if sprite == "appliances_com_01_50" then found.radio = found.radio + 1; radioObj = o end
                    if sprite == "furniture_seating_indoor_01_62" then found.chairs = found.chairs + 1 end
                    if instanceof(o, "IsoBarricade") then found.barricades = found.barricades + 1 end
                    if instanceof(o, "IsoDoor") and o:isLockedByKey() then found.locked = found.locked + 1 end
                end
                local wobs = sq:getWorldObjects()
                for i = 0, wobs:size() - 1 do
                    local it = wobs:get(i):getItem()
                    if it and it:getFullType() == "Base.Key1" and it:getKeyId() == keyId then
                        found.keyFloor = found.keyFloor + 1
                        say("key on the floor at", x, y, z)
                    end
                end
                local bodies = sq:getDeadBodys()
                for i = 0, bodies:size() - 1 do
                    local b = bodies:get(i)
                    local items = b:getContainer() and b:getContainer():getItems()
                    for j = 0, (items and items:size() or 0) - 1 do
                        local it = items:get(j)
                        if it:getFullType() == "Base.Key1" and it:getKeyId() == keyId then
                            found.keyBodies = found.keyBodies + 1
                            say("key body at", x, y, z)
                        end
                    end
                end
            end
        end
    end
end
-- the vehicles within 12 squares of the building's box
local vehicles, seenCar = {}, {}
for x = site.x1 - 12, site.x2 + 12 do
    for y = site.y1 - 12, site.y2 + 12 do
        local sq = cell:getGridSquare(x, y, 0)
        local v = sq and sq:getVehicleContainer()
        if v and not seenCar[v] then
            seenCar[v] = true
            vehicles[#vehicles + 1] = v
        end
    end
end
for _, v in ipairs(vehicles) do
    if string.find(v:getScriptName() or "", "CarLights", 1, true) then  -- the game picks the region's police car
        found.police = found.police + 1
        local door = v:getPartById("DoorFrontLeft")
        local battery = v:getPartById("Battery")
        local item = battery and battery:getInventoryItem()
        say("police car at", math.floor(v:getX()), math.floor(v:getY()), "door open", tostring(door and door:getDoor() and door:getDoor():isOpen()),
            "battery", item and item:getCurrentUsesFloat() or "none")
    else
        say("other vehicle", v:getScriptName(), math.floor(v:getX()), math.floor(v:getY()))
    end
end
for k, n in pairs(found) do say("found", k, n) end
P4T.check(say, "a notice by the entrance", found.notice >= 1)
P4T.check(say, "the desk (two squares)", found.desk == 2, found.desk)
P4T.check(say, "the walkie-talkie on it", found.radio == 1)
say("folding chairs (the row of 4 when the room has space; the building's own count too)", found.chairs)
P4T.check(say, "the ground floor windows boarded", found.barricades >= 1, found.barricades)
say("inner room doors locked", found.locked)
-- a world with no zombies makes no bodies: the key lies on the floor there
-- (a building's own dead may have its key too; an inner room with no door has nothing locked and no key is put)
local noZombies = IsoWorld.getZombiesDisabled()
local keys = noZombies and found.keyFloor or found.keyBodies
if found.locked > 0 then
    P4T.check(say, noZombies and "the building's key on the floor (no zombies)" or "an officer's body with the building's key",
        keys >= 1, found.keyBodies .. " " .. found.keyFloor)
else
    say("nothing locked (the inner room has no door): no key put")
end
P4T.check(say, "the police car by the entrance", found.police == 1, found.police)
-- no other car crowds it (two cars' middles closer than 4 squares overlap)
local closest
for _, v in ipairs(vehicles) do
    if not string.find(v:getScriptName() or "", "CarLights", 1, true) then
        for _, w in ipairs(vehicles) do
            if string.find(w:getScriptName() or "", "CarLights", 1, true) then
                local ex, ey = v:getX() - w:getX(), v:getY() - w:getY()
                local d = math.sqrt(ex * ex + ey * ey)
                if not closest or d < closest then closest = d end
            end
        end
    end
end
P4T.check(say, "no car on top of it", closest == nil or closest >= 4, closest and math.floor(closest * 10) / 10)
if radioObj then
    P4T.check(say, "the walkie-talkie is a radio", instanceof(radioObj, "IsoRadio") or instanceof(radioObj, "IsoWaveSignal"),
        tostring(radioObj))
    local dd = radioObj.getDeviceData and radioObj:getDeviceData()
    say("radio device", tostring(dd), "on", dd and tostring(dd:getIsTurnedOn()) or "-")
end

-- The envelope: placed, in the inner room.
local it = m.items[1]
P4T.check(say, "the envelope is placed", it.placed == true, it.at and (it.at.x .. "," .. it.at.y .. "," .. it.at.z))
if it.at then
    local sq = cell:getGridSquare(it.at.x, it.at.y, it.at.z)
    local room = sq and sq:getRoom()
    local inner = st.roles and st.roles.inner and layout.rooms[st.roles.inner]
    P4T.check(say, "in the inner room", room ~= nil and inner ~= nil and room:getRoomDef() == inner.def,
        room and room:getName() or "-")
end

-- The officer lying fake dead in the hall.
local wake = st.wake and st.wake.pickup
P4T.check(say, "one waits for the pickup", wake ~= nil and #wake == 1)
local function lying()
    local n = 0
    for _, at in ipairs(wake or {}) do
        for dx = -1, 1 do
            for dy = -1, 1 do
                local sq = cell:getGridSquare(at.x + dx, at.y + dy, at.z)
                if sq then
                    local bodies = sq:getDeadBodys()
                    for i = 0, bodies:size() - 1 do if bodies:get(i):isFakeDead() then n = n + 1 end end
                    local mo = sq:getMovingObjects()
                    for i = 0, mo:size() - 1 do
                        local z = mo:get(i)
                        if instanceof(z, "IsoZombie") and z:isFakeDead() then n = n + 1 end
                    end
                end
            end
        end
    end
    return n
end
P4T.check(say, "he lies fake dead there", lying() >= 1, lying())

-- The envelope taken as a pickup takes it (the found piece: monologue and the stage's event).
function P4S_PICKUP()
    OA.Missions.found(record, m, m.items[1], nil)
    say("envelope found: the officer should get up; P4S_WOKE() in a few seconds")
end

function P4S_WOKE()
    P4T.check(say, "nobody lies fake dead any more", lying() == 0, lying())
    P4T.check(say, "the pickup monologue is in the comms record", OA.Comms.section(record).played.S1F_pickup ~= nil)
end
