-- P11: after p11_wreck.lua: the stage piece by piece (p5_stage_after.lua), then the wreck itself: the parts the data
-- names battered or taken out, the tyres' wheels bare, the glass on the ground, the transport log in the glove box.
-- Then P11_ENTER() walks into the site's circle (the self-talk on the truck comes, the hour's line does not) and
-- P11_LOOK() stands the character beside the truck for a picture; P11_CHECK() after a few seconds says what was said.
RUN("p5_stage_after.lua")
local OA = OperationAcorn
local say = P4T.say("p11wreck")
local record, player = P4T.record()
local m = record and OA.Missions.active(record)
if not (m and m.story == "revisit_wreck") then say("no truck mission: RUN p11_wreck.lua first"); return end
local site = m.site
local def = OA.Stage.defOf(m)
local spec = def.pieces[1].wreck

local car
local list = OA.vehicles()
for i = 0, list:size() - 1 do
    local v = list:get(i)
    if math.abs(v:getX() - site.x) < 16 and math.abs(v:getY() - site.y) < 16 then car = v end
end
if not P4T.check(say, "the truck stands at the site", car ~= nil, car and car:getScriptName()) then return end
P11_CAR = car

local function cond(id)
    local part = car:getPartById(id)
    return part and part:getCondition()
end
local low, high = 100, 0
for i = 0, car:getPartCount() - 1 do
    local part = car:getPartByIndex(i)
    if part:getInventoryItem() then
        local c = part:getCondition()
        if c < low then low = c end
        if c > high then high = c end
    end
end
say("parts holding an item: condition", low, "to", high)
for id, want in pairs(spec.parts) do
    P4T.check(say, "part " .. id .. " at " .. want, cond(id) == want, cond(id))
end
for _, id in ipairs(spec.remove) do
    local part = car:getPartById(id)
    P4T.check(say, "part " .. id .. " taken out", part ~= nil and part:getInventoryItem() == nil,
        part and tostring(part:getInventoryItem()) or "no part")
end
local glass = 0
local cx, cy = math.floor(car:getX()), math.floor(car:getY())
for dx = -3, 3 do
    for dy = -3, 3 do
        local sq = getCell():getGridSquare(cx + dx, cy + dy, 0)
        local objs = sq and sq:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            if instanceof(objs:get(i), "IsoBrokenGlass") then glass = glass + 1 end
        end
    end
end
P4T.check(say, "broken glass by the truck", glass >= 1, glass)
local box = car:getPartById("GloveBox")
local c = box and box:getItemContainer()
local log = c and c:getFirstTypeRecurse(OA.StoryData.fullType("TransportLog"))
P4T.check(say, "the transport log in the glove box", log ~= nil)
local door = car:getPartById("DoorFrontRight")
P4T.check(say, "the passenger door open", door and door:getDoor() and door:getDoor():isOpen(), door and "part" or "no part")

function P11_ENTER()
    P4T.go(math.floor(site.x) - 4, math.floor(site.y), 0)
    say("walked into the circle")
end

function P11_LOOK()
    P4T.go(cx - 3, cy + 3, 0)
    say("standing by the truck")
end

function P11_CHECK()
    local played = OA.Comms.section(record).played
    P4T.check(say, "the truck's self-talk said", played.PW_enter ~= nil)
    P4T.check(say, "no line for a known place", played.A1 == nil and played.A2 == nil and played.A3 == nil)
end

-- Where it stands: by a road (none within ROADSIDE_NEAR, one within ROADSIDE_FAR), on dry ground.
do
    local Game = OA.StoryGame
    local near, far = 99, nil
    local grid = getWorld():getMetaGrid()
    for r = 0, 30 do
        for _, d in ipairs({ { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }) do
            local zs = grid:getZonesAt(cx + d[1] * r, cy + d[2] * r, 0)
            for i = 0, zs:size() - 1 do
                if zs:get(i):getType() == "Nav" and r < near then near = r end
            end
        end
    end
    say("nearest road", near, "squares (rows and diagonals)")
    P4T.check(say, "by a road", near > Game.ROADSIDE_NEAR - 3 and near <= Game.ROADSIDE_FAR + 3, near)
    local wet = 0
    for dx = -2, 2 do
        for dy = -2, 2 do
            local sq = getCell():getGridSquare(cx + dx, cy + dy, 0)
            if sq and sq:getProperties():has(IsoFlagType.water) then wet = wet + 1 end
        end
    end
    P4T.check(say, "no water under the truck", wet == 0, wet)
end
