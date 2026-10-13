-- The panels' networks in the PZ Extension API: each panel has a power network over its building, and its
-- water as networks per pipe, building and floor (BU.Water). Defined from the save as the world starts; changed call
-- by call afterwards, so the API keeps what it has worked out (which producer runs, when supply stopped, what tanks
-- held when last seen).
require "BuildingUtilities/Store"
require "BuildingUtilities/Water"
local BU = BuildingUtilities
local Store, Water = BU.Store, BU.Water
local Networks = {}
BU.Networks = Networks

-- The utility of one of this mod's network ids ("bu-p3-power", "bu-p3-water-c1-b100_200_0-L0-U"), or nil.
local function utilityOf(id) return tostring(id):match("^bu%-p%d+%-(%a+)") end

-- Calls a function of PZExtAPI.networks with this mod's handle first, on the network id. Without the API it does
-- nothing; a utility turned off in the sandbox (BU.enabled) has no networks, and nothing is asked of them but to go.
-- How many changes this mod asked of the networks (stateOf keeps answers between two).
local changes = 0
local function change(name, id, ...)
    local api = BU.api()
    if not api then return nil end
    changes = changes + 1
    if name ~= "remove" and not BU.enabled(utilityOf(id)) then return nil end
    local ok, result = pcall(api.networks[name], BU.handle(), id, ...)
    if not ok then BU.log("networks." .. name .. " failed:", result); return nil end
    return result
end

local function powerId(panel) return BU.networkId(panel.id, "power") end

-- The power producers as the API takes them: the units' source first (BU.Energy), so it is the first to take over
-- when a generator stops, then the squares in the player's order.
local function powerProducers(panel)
    local result = {}
    if BU.Energy.hasSource(panel) then result[1] = { source = BU.Energy.SOURCE } end
    for _, at in ipairs(panel.power.producers) do
        if BU.Links.live(panel, BU.Links.producerRef(at.x, at.y, at.z)) then
            result[#result + 1] = { x = at.x, y = at.y, z = at.z }
        end
    end
    return result
end

-- What the network does with one device of a panel: "exclude", "include" or "reset" (the building's rule). A
-- device of the building is connected unless the player excluded it, and so is one in a room built onto it, which
-- the API has as a single object (it is in attached: "include"); one outside only when this panel laid its line (it
-- is in included; any other the panel names is of its building) and the player did not cut its supply (excluded, as
-- one inside); any is off while its timer has it off. A power device outside is off too while the game's
-- AllowExteriorGenerator is off (BU.exteriorPower).
function Networks.rule(panel, utility, key)
    local data = panel[utility]
    local off = data.timed and data.timed[key]
    -- One whose line supplies nothing (BU.Links: cut, past a limit) is as one not connected.
    if data.included[key] and not BU.Links.live(panel, BU.Links.deviceRef(key)) then return "reset" end
    if data.included[key] then
        return (off or data.excluded[key] or utility == "power" and not BU.exteriorPower()) and "exclude" or "include"
    end
    local built = data.attached and data.attached[key]
    if data.excluded[key] or off then return "exclude" end
    return built and "include" or "reset"
end

local function applyRule(id, rule, key)
    local x, y, z, sprite = BU.parseThing(key)
    if x and id then change(rule, id, x, y, z, sprite) end
end

-- A room by its square (BU.placeKey), for the API's addRoom and removeRoom: the API names rooms by a square too.
local function setRoom(id, key, on)
    local x, y, z = BU.parsePlace(key)
    if x then change(on and "addRoom" or "removeRoom", id, x, y, z) end
end

-- Power: the building, or the rooms of the panel's zone.
local function addPowerMembers(panel)
    local id = powerId(panel)
    if not panel.zone then
        change("addBuilding", id, panel.x, panel.y, panel.z)
        return
    end
    for key in pairs(panel.zone) do setRoom(id, key, true) end
end

-- The power network's rules for every device the panel names.
local function applyPowerRules(panel)
    local data, keys = panel.power, {}
    for _, set in ipairs({ data.excluded, data.included, data.attached or {}, data.timed or {} }) do
        for key in pairs(set) do keys[key] = true end
    end
    for key in pairs(keys) do
        local rule = Networks.rule(panel, "power", key)
        if rule ~= "reset" then applyRule(powerId(panel), rule, key) end
    end
end

-- Water.

-- Whether the panels' water can be networks: water is on (BU.enabled) and in this game (BU.waterAvailable).
local function waterOn() return BU.enabled("water") and BU.waterAvailable() end

-- The water networks defined for each panel now, by id: { kind, parents (their ids, as one text), tanks (the tank
-- squares, as one text), rooms (by room id, the room) }. Not saved: the networks are defined anew as a world loads.
local defined = {}
-- The rules set on each panel's water networks for its devices, by device key: { [network id] = rule }. Not saved,
-- as defined.
local definedRules = {}
-- The purify switch last set on each water network (nil: as the API defines one, purifying). Not saved: the
-- networks are defined anew as a world loads, which purifies them.
local purified = {}
-- Whether every panel's power networks, and water networks, are defined now: as the features were when the world
-- started or Networks.applyFeatures last ran.
local powerDefined, waterDefined = false, false

-- Every water device key a panel names, as a set.
local function waterKeys(panel)
    local data, keys = panel.water, {}
    for _, set in ipairs({ data.excluded, data.included, data.attached or {}, data.pipeOf or {} }) do
        for key in pairs(set) do keys[key] = true end
    end
    return keys
end

-- One water device's rules now (Water.layout), { [network id] = rule }. One of the zone's rooms is in its room's use
-- network with the room: nothing to set, but "exclude" there when the player switched it off; on another pipe than
-- its room's, excluded from the room's and included in its own pipe's use network of the room's floor; one in a room
-- built onto the building, which the API has as a single object, included in its pipe's. One outside, on its line,
-- included in its pipe's use network where its line enters (Water.placeOf), while the line supplies it (Networks.rule).
local function waterRules(panel, key, layout)
    local Links = BU.Links
    local result = {}
    local x, y, z = BU.parseThing(key)
    if not x then return result end
    local rule = Networks.rule(panel, "water", key)
    if panel.water.included[key] then
        if rule ~= "include" then return result end
        local building, level = Water.placeOf(panel, x, y, z, Links.deviceRef(key))
        local id = Water.useId(layout, Water.chosenPipe(panel, { key }) or Water.FIRST, building, level)
        if id then result[id] = "include" end
        return result
    end
    local room = Links.homeRoom(panel, x, y, z)
    if not room then return result end
    local roomId = Water.useId(layout, Water.roomPipe(panel, room.key), room.building, room.level)
    if rule == "exclude" then
        if roomId then result[roomId] = "exclude" end
        return result
    end
    local own = Water.useId(layout, Water.chosenPipe(panel, { key }) or Water.roomPipe(panel, room.key), room.building, room.level)
    if own ~= roomId and roomId then result[roomId] = "exclude" end
    if own and (own ~= roomId or rule == "include") then result[own] = "include" end
    return result
end

-- Sets the rules of the devices given (all a panel names when nil) as they are now, taking off those set before on a
-- network that has none now (and is still there).
local function applyWaterRules(panel, layout, keys)
    local rules = definedRules[panel.id] or {}
    definedRules[panel.id] = rules
    local now = defined[panel.id] or {}
    for key in pairs(keys or waterKeys(panel)) do
        local before, after = rules[key] or {}, waterRules(panel, key, layout)
        for id in pairs(before) do
            if not after[id] and now[id] then applyRule(id, "reset", key) end
        end
        for id, rule in pairs(after) do
            if before[id] ~= rule then applyRule(id, rule, key) end
        end
        rules[key] = after
    end
    -- A key the panel no longer names: its rules go.
    if not keys then
        local named = waterKeys(panel)
        for key, set in pairs(rules) do
            if not named[key] then
                for id in pairs(set) do
                    if now[id] then applyRule(id, "reset", key) end
                end
                rules[key] = nil
            end
        end
    end
end

-- The water policy networks are defined with: BU.POLICY.water, or its fallback once the API refused it as a policy
-- it does not have (then for the rest of the session, not asked again).
local waterPolicy = BU.POLICY.water

function Networks.waterPolicy() return waterPolicy end

-- Defines a water network. A game whose API cannot take water networks refuses it (an API that predates hooks()
-- does not tell before): water is then off for this world (BU.waterAvailable), and nothing else is tried.
local function defineWaterNetwork(id)
    purified[id], changes = nil, changes + 1
    local define = BU.api().networks.define
    local ok, failure = pcall(define, BU.handle(), id, "water", waterPolicy)
    if not ok and waterPolicy ~= BU.POLICY.waterFallback and tostring(failure):find("policy for water", 1, true) then
        BU.log("water policy", waterPolicy, "not in this API; using", BU.POLICY.waterFallback)
        waterPolicy = BU.POLICY.waterFallback
        ok, failure = pcall(define, BU.handle(), id, "water", waterPolicy)
    end
    if not ok then BU.hookFault("water", failure) end
    return ok
end

-- The water layout each panel's networks were last defined with (Water.layout), for the water calls below.
local layouts = {}

-- Brings the API's water networks of a panel to its data now (Water.layout): networks no longer wanted go, new ones
-- are defined, each gets its tanks, parents and rooms, and the devices' rules: every device's when a network came or
-- went, else the keys given (all when none are). Networks that stay keep what the API saw of their tanks.
function Networks.defineWater(panel, keys)
    if not waterOn() then return end
    local layout = Water.layout(panel)
    local before = defined[panel.id] or {}
    local now, networksChanged = {}, false
    local wanted = {}
    for _, network in ipairs(layout.networks) do wanted[network.id] = network end
    -- In an order the API takes: every network exists before one names it as a parent; a tank leaves its old network
    -- before it joins another; a room leaves its old network before it joins another.
    for _, network in ipairs(layout.networks) do
        if not before[network.id] then
            if not defineWaterNetwork(network.id) then return end
            if panel.water.frozen then change("setEnabled", network.id, false) end
            networksChanged = true
        end
    end
    local tanks, parents = {}, {}
    for _, network in ipairs(layout.networks) do
        local list = {}
        for _, at in ipairs(network.producers or {}) do list[#list + 1] = at.x .. "," .. at.y .. "," .. at.z end
        table.sort(list)
        tanks[network.id] = table.concat(list, ";")
        parents[network.id] = table.concat(network.parents or {}, ";")
        local old = before[network.id]
        if old and old.tanks ~= tanks[network.id] then change("setProducers", network.id, {}) end
    end
    for _, network in ipairs(layout.networks) do
        local old = before[network.id]
        if network.kind == "T" and (not old or old.tanks ~= tanks[network.id]) then
            change("setProducers", network.id, network.producers)
        end
        if network.kind == "U" and (not old or old.parents ~= parents[network.id]) then
            change("setParents", network.id, network.parents)
        end
    end
    for id in pairs(before) do
        if not wanted[id] then
            change("remove", id)
            networksChanged = true
        end
    end
    local roomSets = {}
    for _, network in ipairs(layout.networks) do
        local old = before[network.id]
        local rooms = {}
        for _, room in ipairs(network.rooms or {}) do rooms[room.id] = room end
        roomSets[network.id] = rooms
        for roomId, room in pairs(old and old.rooms or {}) do
            if not rooms[roomId] then setRoom(network.id, room.key, false) end
        end
    end
    for _, network in ipairs(layout.networks) do
        local old = before[network.id]
        for roomId, room in pairs(roomSets[network.id]) do
            if not (old and old.rooms[roomId]) then setRoom(network.id, room.key, true) end
        end
        now[network.id] = { kind = network.kind, pipe = network.pipe, parents = parents[network.id], tanks = tanks[network.id],
            rooms = roomSets[network.id] }
    end
    defined[panel.id] = now
    layouts[panel.id] = layout
    if networksChanged then
        for id in pairs(definedRules[panel.id] or {}) do
            for netId in pairs(definedRules[panel.id][id]) do
                if not now[netId] then definedRules[panel.id][id][netId] = nil end
            end
        end
    end
    applyWaterRules(panel, layout, (not networksChanged) and keys or nil)
end

-- The layout a panel's water networks were last defined with; worked out (and defined) now when they were not.
function Networks.waterLayout(panel)
    if not layouts[panel.id] then Networks.defineWater(panel) end
    return layouts[panel.id] or Water.layout(panel)
end

-- A panel's water on or off: its pipes thawed or frozen.
function Networks.setWaterEnabled(panel, on)
    for id in pairs(defined[panel.id] or {}) do change("setEnabled", id, on) end
end

-- Takes a panel's water networks away.
local function removeWater(panel)
    for id in pairs(defined[panel.id] or {}) do change("remove", id) end
    defined[panel.id], definedRules[panel.id], layouts[panel.id] = nil, nil, nil
end

-- What the box adds to its devices' load, all its parts together (BU.Changes.setExtraLoad).
function Networks.extraLoad(panel)
    local total = 0
    for _, each in pairs(panel.extraLoads or {}) do total = total + each end
    return total
end

-- Whether a box lets its power through: its breaker up and its main switch on. Its power network is switched on
-- exactly then (Networks.applyEnabled).
function Networks.powerAllowed(panel)
    return not panel.tripped and not panel.switchedOff
end

-- The power network on or off as the box has it (Networks.powerAllowed). Switched off, the API stops its generators
-- (on standby, burning nothing); switched on, it starts the one in use before, or else the first on standby that can
-- run.
function Networks.applyEnabled(panel)
    change("setEnabled", powerId(panel), Networks.powerAllowed(panel))
end

-- Defines a panel's networks from the save. The network gets the extra load the box had (pumps) at once, until the
-- first minute works it out again; none while the box keeps its power off.
function Networks.define(panel)
    local id = powerId(panel)
    change("define", id, "power", BU.POLICY.power)
    change("setProducers", id, powerProducers(panel))
    addPowerMembers(panel)
    applyPowerRules(panel)
    -- A network is defined switched on.
    if not Networks.powerAllowed(panel) then Networks.applyEnabled(panel) end
    local extra = Networks.powerAllowed(panel) and Networks.extraLoad(panel) or 0
    if extra > 0 then Networks.setExtraLoad(panel, extra) end
    Networks.defineWater(panel)
end

-- The panel's zone changed from before (a set of room squares, or nil for the whole building) to what it has now.
function Networks.setZone(panel, before)
    local id, now = powerId(panel), panel.zone
    if not before then change("removeBuilding", id, panel.x, panel.y, panel.z) end
    if not now then
        for key in pairs(before or {}) do setRoom(id, key, false) end
        change("addBuilding", id, panel.x, panel.y, panel.z)
    else
        for key in pairs(before or {}) do
            if not now[key] then setRoom(id, key, false) end
        end
        for key in pairs(now) do
            if not (before and before[key]) then setRoom(id, key, true) end
        end
    end
    Networks.defineWater(panel)
end

-- Every panel of the save, as the world starts. Only the utilities that are on (BU.enabled).
function Networks.defineAll()
    if not BU.api() then return end
    defined, definedRules, purified, layouts = {}, {}, {}, {}
    powerDefined, waterDefined = BU.enabled("power"), waterOn()
    for _, panel in ipairs(Store.list()) do Networks.define(panel) end
end

function Networks.remove(panel)
    change("remove", powerId(panel))
    removeWater(panel)
end

-- A utility turned on or off in the sandbox since the networks were defined (BU.Changes.applyFeatures): turned off,
-- every panel's networks of it go, which gives their producers back to the game; turned on, they are defined from the
-- save, as the world starts.
function Networks.applyFeatures()
    if not BU.api() then return end
    local panels = Store.list()
    local power, water = BU.enabled("power"), waterOn()
    if power ~= powerDefined then
        powerDefined = power
        for _, panel in ipairs(panels) do
            if power then Networks.define(panel) else change("remove", powerId(panel)) end
        end
    end
    if water ~= waterDefined then
        waterDefined = water
        for _, panel in ipairs(panels) do
            if not water then removeWater(panel) else Networks.defineWater(panel) end
        end
    end
end

-- What a box's lines supply changed (BU.Links): its producers and units, and every device it names, again.
function Networks.linesChanged(panel)
    change("setProducers", powerId(panel), powerProducers(panel))
    applyPowerRules(panel)
    for key in pairs(panel.power.included) do
        if Networks.rule(panel, "power", key) == "reset" then applyRule(powerId(panel), "reset", key) end
    end
    Networks.defineWater(panel)
end

function Networks.setProducers(panel, utility)
    if utility == "water" then return Networks.defineWater(panel, {}) end
    change("setProducers", powerId(panel), powerProducers(panel))
end

-- What the box adds to its devices' load (Networks.extraLoad).
function Networks.setExtraLoad(panel, load)
    change("setExtraLoad", powerId(panel), load)
end

-- The units' source: whether it carries the load, and switched on (true) or left (nil).
function Networks.setSource(panel, available, switchOn)
    change("setSource", powerId(panel), BU.Energy.SOURCE, available, switchOn)
end

-- One device as the panel's data has it now (Networks.rule; for water on its pipe's networks, waterRules, the
-- networks defined again first: a fixture on a pipe of its own, or outside, may be the only thing of a use network).
function Networks.apply(panel, utility, key)
    if utility == "water" then
        Networks.defineWater(panel, { [key] = true })
        return
    end
    applyRule(powerId(panel), Networks.rule(panel, utility, key), key)
end

-- A network's state; nil for a utility that is off (BU.enabled). Kept while the clock reads the same millisecond and
-- this mod changed no network (changes): a minute's work asks for the same network many times, and each answer is a
-- table the API makes.
local stateKept, stateAt, stateChanges = {}, nil, -1
local function stateOf(id)
    local api = BU.api()
    if not (api and id and BU.enabled(utilityOf(id))) then return nil end
    local now = getTimestampMs()
    if stateAt ~= now or stateChanges ~= changes then stateKept, stateAt, stateChanges = {}, now, changes end
    local kept = stateKept[id]
    if kept == nil then
        kept = api.networks.state(id) or false
        stateKept[id] = kept
    end
    return kept or nil
end

-- The water calls below work on the networks as last defined (Networks.waterLayout). Without water (off, or not in
-- this game: waterOn) they do nothing.

-- A water network's state, by id.
function Networks.waterState(id)
    if not waterOn() then return nil end
    return stateOf(id)
end

-- Litres of a fluid into tank networks, each in turn as far as it has room (a machine's outlet: Water.fillTargets,
-- the highest floor first). The litres they took.
function Networks.fillInto(panel, ids, litres, fluid)
    if not waterOn() then return 0 end
    local filled = 0
    for _, id in ipairs(ids) do
        if litres - filled <= 1e-6 then break end
        filled = filled + (change("fill", id, litres - filled, fluid) or 0)
    end
    return filled
end

-- Litres out of networks, each in turn as far as it holds them: a use network draws as a fixture there does, a tank
-- network from its floor's tanks. The litres drawn, and what they were by fluid ({ Water = 3, TaintedWater = 1 }).
function Networks.drawFrom(panel, ids, litres)
    local drawn, mix = 0, {}
    local api = BU.api()
    if not waterOn() or not api then return drawn, mix end
    for _, id in ipairs(ids) do
        if litres - drawn <= 1e-6 then break end
        changes = changes + 1
        local ok, taken, fluids = pcall(api.networks.draw, BU.handle(), id, litres - drawn)
        if not ok then
            BU.log("networks.draw failed:", taken)
        elseif taken and taken > 0 then
            drawn = drawn + taken
            for name, amount in pairs(fluids or {}) do mix[name] = (mix[name] or 0) + amount end
        end
    end
    return drawn, mix
end

-- A pipe's water purified as its fixtures take it (as the game's pipes do, and the API by default), or left as its
-- tanks hold it: each use network of the pipe as defined now; only those whose switch differs from what was last set
-- are changed (asked each minute: no layout, no API state). A game without the hooks that keep the taint refuses
-- false: the pipes purify then (BU.purifyAvailable), and the callers stop asking.
function Networks.setPipePurify(panel, pipe, on)
    if not waterOn() then return end
    for id, network in pairs(defined[panel.id] or {}) do
        local current = purified[id]
        if current == nil then current = true end
        if network.kind == "U" and network.pipe == pipe and current ~= on then
            changes = changes + 1
            local ok, failure = pcall(BU.api().networks.setPurify, BU.handle(), id, on)
            if not ok and not on then BU.hookFault("purify", failure); return end
            if ok then purified[id] = on else BU.log("networks.setPurify failed:", failure) end
        end
    end
end

-- The power network's state, or for water the panel's pipes together: { supplied (any pipe), enabled, amount and
-- capacity (summed), producers (every tank as the networks last saw it, with its pipe, building and floor), pipes (by
-- pipe: { amount, capacity, supplied, foreign (tanks holding what is not water), buildings (by building key: { amount,
-- capacity, top (its highest floor with tanks) }) }) }; nil for a utility that is off, or without water in this game.
function Networks.state(panel, utility)
    if utility ~= "water" then return stateOf(powerId(panel)) end
    if not waterOn() then return nil end
    local result = { supplied = false, enabled = not panel.water.frozen, amount = 0, capacity = 0, producers = {}, pipes = {} }
    for _, pipe in ipairs(Water.pipes(panel)) do
        result.pipes[pipe.id] = { amount = 0, capacity = 0, supplied = false, foreign = 0, buildings = {} }
    end
    local layout = Networks.waterLayout(panel)
    for _, network in ipairs(layout.networks) do
        local state = network.kind == "T" and stateOf(network.id) or nil
        local pipe = state and result.pipes[network.pipe]
        if pipe then
            local building = pipe.buildings[network.building] or { amount = 0, capacity = 0 }
            pipe.buildings[network.building] = building
            for _, producer in ipairs(state.producers or {}) do
                producer.pipe, producer.building, producer.level = network.pipe, network.building, network.level
                result.producers[#result.producers + 1] = producer
                if producer.foreign then pipe.foreign = pipe.foreign + 1 end
            end
            local amount, capacity = state.amount or 0, state.capacity or 0
            pipe.amount, pipe.capacity = pipe.amount + amount, pipe.capacity + capacity
            building.amount, building.capacity = building.amount + amount, building.capacity + capacity
            if capacity > 0 and (not building.top or network.level > building.top) then building.top = network.level end
            pipe.supplied = pipe.supplied or amount > 0
            result.amount, result.capacity = result.amount + amount, result.capacity + capacity
        end
    end
    for _, pipe in pairs(result.pipes) do result.supplied = result.supplied or pipe.supplied end
    result.supplied = result.supplied and result.enabled
    return result
end

-- The panel and utility of one of this mod's network ids, and for water its pipe, building tag, floor and kind ("T",
-- "U"); nil for none of this mod's.
function Networks.owner(networkId)
    local text = tostring(networkId)
    local id, pipe, building, level, kind = text:match("^bu%-(p%d+)%-water%-c(%d+)%-b([%w_%-]+)%-L(%-?%d+)%-([TU])$")
    if id then return Store.get(id), "water", tonumber(pipe), building, tonumber(level), kind end
    id = text:match("^bu%-(p%d+)%-power$")
    if id then return Store.get(id), "power" end
    return nil
end

return Networks
