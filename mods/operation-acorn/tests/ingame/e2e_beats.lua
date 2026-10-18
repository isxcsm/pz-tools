-- The E2E director's beats in the game (E2E-DEBUG.md 9, the first run of the story's combined check): each beat set
-- in order, with the character moved, and the record and the world looked at a few seconds after. 01: the game's
-- helicopter comes for the character (its active flag and target read off the world's helicopter) and the first
-- supply comes down as it goes; 01L and 01N: the supply at once, with their plan's mode. The story beats: the calls
-- before played and its own to come, the level, the mission offered, the character by the base terminal, the box
-- standing (filled where the beat fills it). The join beats: the world's tier and no terminal known. X: nothing set.
-- No title shown by a setting but the first supply's. Changes the save: E2E_BEATS = { "02", ... } runs some only.
-- Prints [e2ebeats] lines.
local OA = OperationAcorn
local E2E = OA.Dev.E2E
local Comms, Story, Missions, Trade = OA.Comms, OA.Story, OA.Missions, OA.Trade
local t = STEPS("e2ebeats")
local player = getPlayer()

local function record() return OA.Dev.record() end

-- the first supplies that came, and the titles shown, from the director's setting on
local drops, titles = {}, {}
local realFirst, realTitle = E2E.firstSupply, OA.Sync.title
E2E.firstSupply = function()
    local ok = realFirst()
    drops[#drops + 1] = { at = getTimestampMs(), ok = ok }
    return ok
end
OA.Sync.title = function(id, spec, ...)
    titles[#titles + 1] = spec and spec.key or "?"
    return realTitle(id, spec, ...)
end

-- The world's helicopter, read through the game's reflection (the class is not given to Lua): its fields by name.
local function heliFields()
    local world = getWorld()
    local heli
    for i = 0, getNumClassFields(world) - 1 do
        local field = getClassField(world, i)
        if string.find(tostring(field), "helicopter", 1, true) then heli = getClassFieldVal(world, field) end
    end
    if not heli then return nil end
    local out = {}
    for i = 0, getNumClassFields(heli) - 1 do
        local field = getClassField(heli, i)
        local name = string.match(tostring(field), "([%w_]+)$")
        if name then out[name] = getClassFieldVal(heli, field) end
    end
    return out
end

local function heliActive()
    local f = heliFields()
    if not f then return nil end
    return f.bActive or f.active, f.target
end

local function near(x, y, d)
    return math.abs(player:getX() - x) <= d and math.abs(player:getY() - y) <= d
end

local function standingBox(r)
    local box = Trade.Boxes.active(r)
    if not (box and box.x) then return nil end
    local Objects = Trade.Objects
    return Objects.find(Objects.square(box.x, box.y, box.z or 0), Objects.DELIVERY_BOX, box.id), box
end

local function before(from)
    local behind
    for i, id in ipairs(E2E.ORDER) do
        if id == from then return behind end
        behind = id
    end
end

local function fillCount()
    local n = 0
    for _, entry in ipairs(E2E.FILL) do n = n + entry[2] end
    return n
end

local function hasSerum()
    return player:getInventory():getCountTypeRecurse("OperationAcorn.UpgradeSerumShared") > 0
end

-- each beat: set, then looked at after `wait` ms
local function look(beat)
    local r = record()
    local id = beat.id
    t.check(id .. ": the beat set", E2E.current == id, E2E.current)
    if beat.from then
        t.check(id .. ": stage " .. beat.stage .. "/" .. (beat.milestones or 0),
            r.trade.stage == beat.stage and (r.trade.milestones or 0) == (beat.milestones or 0),
            r.trade.stage .. "/" .. tostring(r.trade.milestones))
        local behind = before(beat.from)
        t.check(id .. ": " .. tostring(behind) .. " played, " .. beat.from .. " to come",
            (not behind or Comms.done(r, behind)) and not Comms.done(r, beat.from))
        local e = OA.CommsData.BY_ID[beat.from]
        if string.match(e.trigger, "^tier:") then
            local ready = Comms.next(r, "terminal")
            t.check(id .. ": the terminal plays " .. beat.from .. " next", ready and ready.id == beat.from,
                ready and ready.id)
        end
        local m = Missions.active(r)
        if beat.offer then
            t.check(id .. ": a mission offered", m and m.state == "waiting", m and (m.story or m.kind) or "none")
        else
            t.check(id .. ": nothing offered", m == nil, m and m.state)
        end
        t.check(id .. ": registered", Trade.registered(r))
        local term = r.heli and r.heli.terminal
        t.check(id .. ": by the base terminal", term and near(term.x, term.y, 4),
            term and (term.x .. "," .. term.y) or "no terminal")
        local object, box = standingBox(r)
        t.check(id .. ": the box standing", object ~= nil, box and (box.id .. " " .. box.state) or "none")
        if beat.fill and object then
            t.check(id .. ": the box filled, nothing of an earlier beat's", object:getContainer():getItems():size() == fillCount(),
                object:getContainer():getItems():size())
        end
        if beat.serum then t.check(id .. ": a serum given", hasSerum()) end
        if beat.handover then
            t.check(id .. ": the handover over", Story.section(r).handover == true)
        end
    elseif beat.join then
        local tier = Story.joinedTier(r)
        if beat.join == "H" then
            t.check(id .. ": joined after the handover", Story.joinedAfterHandover(r))
        else
            t.check(id .. ": joined at " .. beat.join, tier == beat.join, tier)
        end
        t.check(id .. ": no terminal known yet", not Trade.registered(r))
    elseif beat.fresh then
        t.check(id .. ": the first supply's plan " .. (beat.firstMode or "window"),
            r.first and r.first.mode == (beat.firstMode or "window"), r.first and r.first.mode)
    end
end

local wanted
if E2E_BEATS then
    wanted = {}
    for _, id in ipairs(E2E_BEATS) do wanted[id] = true end
end

local steps = {}
local function add(ms, fn) steps[#steps + 1] = { ms, fn } end
local logBefore

for _, beat in ipairs(E2E.BEATS) do
    if not wanted or wanted[beat.id] then
        add(500, function()
            titles, drops = {}, {}
            if beat.keep then logBefore = #Comms.section(record()).log end
            E2E.set(beat.id)
            t.say("set", beat.id)
        end)
        if beat.first == "heli" then
            add(3000, function()
                local active, target = heliActive()
                t.check("01: the game's helicopter flies", active == true, tostring(active))
                t.check("01: for the character", target == player, tostring(target))
                t.check("01: no supply while it flies", #drops == 0, #drops)
                look(beat)
            end)
            add((E2E.HELI_SECONDS - 3) * 1000 + 2000, function()
                t.check("01: the supply as it goes", #drops == 1 and drops[1].ok, #drops)
                t.check("01: the helicopter gone", heliActive() ~= true)
                t.check("01: the first supply's title", titles[1] == "IGUI_OA_Title_FirstSupply", titles[1])
                t.check("01: done", record().first.done == true)
            end)
        elseif beat.first == "drop" then
            add(2000, function()
                t.check(beat.id .. ": the supply at once", #drops == 1 and drops[1].ok, #drops)
                t.check(beat.id .. ": no helicopter", heliActive() ~= true)
                look(beat)
            end)
        else
            add(4000, function()
                look(beat)
                local leaked = {}
                for _, key in ipairs(titles) do leaked[#leaked + 1] = key end
                t.check(beat.id .. ": no title from setting", #leaked == 0, table.concat(leaked, ","))
                if beat.keep then
                    t.check("X: the record untouched", #Comms.section(record()).log == logBefore)
                end
            end)
        end
    end
end
add(0, function()
    E2E.firstSupply, OA.Sync.title = realFirst, realTitle
end)
t.run(steps)
