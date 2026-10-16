-- The base machines' pure logic: what a machine does with its parts, how long a job takes, how work carries over
-- time (the ten-minute step and the catch-up when a place loads), and what comes out. No game objects here: a
-- machine is a table (kind, parts, last, lanes ...) and the game side (Machines.lua) hands this the jobs through a
-- small interface. tests/unit/machines_*_test.lua checks it all outside the game.
require "OperationAcorn/Machines/Data"
local OA = OperationAcorn
local Machines = OA.Machines
local Data = Machines.Data
local Logic = {}
Machines.Logic = Logic

local EPS = 1e-9

-- A whole number from an expected value: the whole part, and one more with the chance of the rest.
function Logic.roll(expected)
    if expected <= 0 then return 0 end
    local whole = math.floor(expected)
    local rest = expected - whole
    if rest > EPS and OA.randomFloat(0, 1) < rest then whole = whole + 1 end
    return whole
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Parts

-- The parts a new machine of a kind ships with: the old tier at full condition for every slot, except the slots the
-- kind ships without (the soundproof cover).
function Logic.newParts(kind)
    local def = Data.KINDS[kind]
    local parts = {}
    for _, slot in ipairs(def.slots) do
        if not (def.empty and def.empty[slot]) then
            parts[slot] = { tier = "old", cond = Data.CONDITION_MAX }
        end
    end
    return parts
end

-- The part kind's definition of a tier, for a slot of a machine kind: nil when the slot takes no part there or the
-- part has no such tier.
function Logic.partDef(kind, slot, tier)
    local name = Data.partKind(kind, slot)
    local def = name and Data.PARTS[name]
    return def and def.tiers[tier], name
end

-- Whether a part of a tier fits a slot of a machine kind.
function Logic.fits(kind, slot, partName, tier)
    local has = false
    for _, s in ipairs(Data.KINDS[kind].slots) do
        if s == slot then has = true end
    end
    if not has then return false end
    local name = Data.partKind(kind, slot)
    if name ~= partName then return false end
    return Data.PARTS[name].tiers[tier] ~= nil
end

-- What the installed parts make of a machine. Returns a table:
--   stopped: true when it cannot run (a part is missing or at 0); missing/broken: the slot.
--   speed: the multiplier of its work rate. yield: the multiplier of its output (0.8 with a worn part).
--   power: the multiplier of the electricity it draws. noise: the multiplier of its noise radius.
--   worn: a part (not the cover) is under WORN_BELOW.
--   And the numbers a kind's blade or catalyst brings: shred (pack multiplier), pieces (added cutter pieces),
--   planks (planks from a log), use (a catalyst's material use).
function Logic.effects(kind, parts)
    local def = Data.KINDS[kind]
    local fx = { stopped = false, lanes = 1, speed = 1, yield = 1, power = 1, noise = 1, worn = false,
        shred = 1, pieces = 0, planks = Data.SAW_PLANKS, use = 1 }
    for _, slot in ipairs(def.slots) do
        local part = parts and parts[slot]
        if not part then
            if not (def.empty and def.empty[slot]) then
                fx.stopped = true
                fx.missing = fx.missing or slot
            end
        else
            local tier = Logic.partDef(kind, slot, part.tier)
            if not tier then
                fx.stopped = true
                fx.missing = fx.missing or slot
            elseif slot == "cover" then
                -- A cover at 0 is as good as none; one under WORN_BELOW has lost its damping but still slows.
                if part.cond > 0 then
                    fx.speed = fx.speed * tier.speed
                    if part.cond >= Data.WORN_BELOW then fx.noise = fx.noise * tier.noise end
                end
            elseif part.cond <= 0 then
                fx.stopped = true
                fx.broken = fx.broken or slot
            else
                if part.cond < Data.WORN_BELOW then fx.worn = true end
                if slot == "motor" then
                    fx.lanes = tier.lanes or 1
                    fx.speed = fx.speed * tier.speed
                    fx.power = tier.power
                elseif tier.yield then fx.shred = tier.yield
                elseif tier.pieces then fx.pieces = tier.pieces
                elseif tier.planks then fx.planks = tier.planks
                elseif tier.use then fx.use = tier.use end
            end
        end
    end
    if fx.worn then
        fx.speed = fx.speed * Data.WORN_SPEED
        fx.yield = Data.WORN_YIELD
    end
    return fx
end

-- Wear the parts of a machine that ran for so many hours (NUMBERS 11: old -2, normal -1.5, modern -1 an hour).
-- A part at 0 stays at 0. Returns the slots that reached 0 or fell under WORN_BELOW just now (for a notice).
function Logic.wear(kind, parts, hours)
    local changed = {}
    if hours <= 0 then return changed end
    hours = hours * (Data.KINDS[kind].wear or 1)
    for slot, part in pairs(parts) do
        local tier = Logic.partDef(kind, slot, part.tier)
        if tier and part.cond > 0 then
            local before = part.cond
            part.cond = math.max(0, part.cond - tier.wear * hours)
            if part.cond <= 0 and before > 0 then changed[slot] = "broken"
            elseif part.cond < Data.WORN_BELOW and before >= Data.WORN_BELOW then changed[slot] = "worn" end
        end
    end
    return changed
end

-- The generator load a machine puts on its generator now (NUMBERS 11: the kind's load times the motor's power
-- multiplier, while it is switched on, as the game's appliances draw while on, working or not).
function Logic.load(kind, parts, on)
    local def = Data.KINDS[kind]
    if not def or not def.load then return 0 end
    return def.load * Logic.loadMultiplier(kind, parts, on)
end

-- The factor the API's power hook multiplies a machine's base consumption by (the base per sprite is the API's):
-- the motor's power multiplier while the machine is switched on, 0 when it is off. Load = base load x this.
function Logic.loadMultiplier(kind, parts, on)
    local def = Data.KINDS[kind]
    if not def or not def.load or not on then return 0 end
    local motor = parts and parts.motor
    local tier = motor and Logic.partDef(kind, "motor", motor.tier)
    return tier and tier.power or 1
end

-- The radius of the sound a running machine makes.
function Logic.noiseRadius(kind, fx)
    local def = Data.KINDS[kind]
    if not def or not def.noise then return 0 end
    return OA.round(def.noise * fx.noise)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Work over time

-- Works on a machine from `state.last` to `now`, as many jobs at once as its motor has lanes (each at the machine's
-- rate), and returns what happened.
--   state: { kind, parts, last, lanes, idle }. lanes: the work done on the jobs in hand, by lane: lane i is the i-th
--     job io.next gives (finishing one moves the later ones up a lane, with their work). It is changed: last, lanes,
--     idle, and the parts' condition.
--   io.next(fx, i): the i-th job waiting, { cost = work units, ... } (it is the game side's to keep, Logic only passes
--     it on), or nil and why (noInput, noTank, outputFull ...).
--   io.finish(job, fx): does the job (takes the input, puts out the product).
--   maxJobs: the batch size. When it is reached with time left, `state.last` stays behind `now` (the rest is
--     done by the next step); otherwise it is `now`.
-- Work time that has no job to do is not kept: a machine that waits for input starts its clock when input comes.
-- Returns { done, hours (worked), reason (why it stopped, or nil), debt (time left over), started, worn = {slot=...} }.
function Logic.advance(state, now, io, maxJobs)
    local def = Data.KINDS[state.kind]
    local result = { done = 0, hours = 0 }
    local t = state.last or now
    if t > now then t = now end
    local carries = state.lanes or { 0 }
    state.lanes = carries

    local fx = Logic.effects(state.kind, state.parts)
    if fx.stopped then
        state.last, state.idle, state.lanes = now, true, {}
        result.reason = "stopped"
        return result
    end
    if state.idle then
        local job, why = io.next(fx, 1)
        state.last, state.lanes = now, {}
        if job then
            state.idle = false
            result.started = true
        else
            result.reason = why or "noInput"
        end
        return result
    end

    while result.done < maxJobs and t < now - EPS do
        fx = Logic.effects(state.kind, state.parts)
        if fx.stopped then
            result.reason = "stopped"
            t = now
            carries = {}
            break
        end
        local jobs = {}
        for lane = 1, fx.lanes do
            local job, why = io.next(fx, lane)
            if not job then
                if lane == 1 then result.reason = why or "noInput" end
                break
            end
            jobs[lane] = job
        end
        if #jobs == 0 then
            state.idle = true
            carries = {}
            t = now
            break
        end
        for lane = #carries, #jobs + 1, -1 do carries[lane] = nil end
        -- the time to the first job done
        local rate = def.rate * fx.speed
        local need = math.huge
        for lane, job in ipairs(jobs) do
            need = math.min(need, math.max(0, job.cost - (carries[lane] or 0)))
        end
        local hours = need / rate
        local finishing = t + hours <= now + EPS
        if not finishing then hours = now - t end
        for lane = 1, #jobs do carries[lane] = (carries[lane] or 0) + rate * hours end
        t = t + hours
        result.hours = result.hours + hours
        result.worn = Logic.merge(result.worn, Logic.wear(state.kind, state.parts, hours))
        if not finishing then
            -- not done by now: what was worked is kept for the next step
            t = now
            break
        end
        -- every job done by now, the last lane first (finishing one moves the later ones up)
        for lane = #jobs, 1, -1 do
            if carries[lane] >= jobs[lane].cost - EPS then
                io.finish(jobs[lane], fx)
                table.remove(carries, lane)
                result.done = result.done + 1
            end
        end
    end
    state.lanes = carries

    if t < now - EPS and result.done >= maxJobs then
        result.debt = now - t
        state.last = t
    else
        state.last = now
    end
    return result
end

function Logic.merge(into, from)
    for slot, what in pairs(from) do
        into = into or {}
        into[slot] = what
    end
    return into
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Outputs

-- The hand bench: minutes of game time to shred an item of this weight.
function Logic.benchMinutes(weight)
    local s = Data.WORK_SECONDS.shred
    return math.max(s.least, s.perWeight * weight) / 60
end

-- The vanilla ripping rule (RecipeCodeOnCreate.ripClothing): an item covering n parts, less its holes and patches
-- (at least 1), gives pieces from `low` to n: 1 when n is 1, else 2.
function Logic.ripRange(covered, holes, patches)
    local n = math.max(1, (covered or 1) - ((holes or 0) + (patches or 0)))
    local low = n == 1 and 1 or 2
    return low, n
end

local function nameHas(name, list)
    for _, part in ipairs(list) do
        if string.find(name, part, 1, true) then return true end
    end
    return false
end

-- What the cutter can do with a piece of clothing. `info`: { fullType, fabric (FabricType or nil), location (the
-- body location's name without "base:"), covered, holes, patches, dirt, blood, buckle }.
-- Returns a plan { material = "Cotton"|"Denim"|"Leather", low, high, dirt (0..100), buckle } or nil and why.
function Logic.cutterPlan(info)
    if info.fabric and info.fabric ~= "" then
        local low, high = Logic.ripRange(info.covered, info.holes, info.patches)
        return { material = info.fabric, low = low, high = high, dirt = (info.dirt or 0) + (info.blood or 0),
            buckle = info.buckle }
    end
    local rule = Data.UNRIPPABLE[info.location or ""]
    if not rule then return nil, "notCloth" end
    local name = info.fullType or ""
    if nameHas(name, Data.UNRIPPABLE_NOT) then return nil, "notCloth" end
    local material = rule.material or (nameHas(name, Data.LEATHER_NAMES) and "Leather" or "Cotton")
    return { material = material, low = rule.low, high = rule.high, dirt = (info.dirt or 0) + (info.blood or 0) }
end

-- The pieces a plan gives, with a cutter blade's added pieces and the output multiplier: returns the count and how
-- many of them are dirty (the vanilla rule: each is dirty with the chance of the clothing's dirt plus blood, out of 99).
function Logic.cutterPieces(plan, fx)
    local count = OA.random(plan.low, plan.high)
    count = count + Logic.roll(fx.pieces or 0)
    if fx.yield < 1 then count = Logic.roll(count * fx.yield) end
    local dirty = 0
    local chance = math.min(100, plan.dirt or 0)
    for _ = 1, count do
        if OA.random(1, 99) <= chance then dirty = dirty + 1 end
    end
    return count, dirty
end

-- The saw: planks from one log (6 with the old blade, 6.5 and 7 expected, times the wear multiplier).
function Logic.sawPlanks(fx)
    return Logic.roll(fx.planks * fx.yield)
end

-- The propane refiner: the part of an empty tank that an amount of rotten food's weight fills. NUMBERS 11: weight
-- 50 fills a tank; a catalyst cuts the material (use 0.8: 40 fills it); a worn part cuts the output.
function Logic.propaneGain(weight, fx)
    return weight / (Data.PROPANE_WEIGHT * fx.use) * fx.yield
end

-- The oil refiner: litres of oil in one item (a bottle of oil, a lard, a seed), by its type and how much of it is
-- left (0..1, for the foods that are used up).
function Logic.oilLitres(fullType, left)
    local litres = Data.OILS[fullType]
    if not litres then return nil end
    if Data.OIL_FOOD[fullType] then return litres * math.max(0, math.min(1, left or 1)) end
    return litres
end

-- Litres of petrol from litres of oil.
function Logic.petrolGain(litres, fx)
    return litres * Data.OIL_PER_PETROL / fx.use * fx.yield
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The lure

-- The lure's schedule. state: { start, slot (the last sound slot played), spent }. `now` in world hours. Returns
-- { sound = whether a sound is due, expired = whether the 24 hours are over, slot }. One sound at most per step:
-- sounds that fell between two steps are not made up. A lure that was not loaded when its time passed does nothing
-- then; when it loads past the end it is only a shell.
function Logic.lureStep(state, now)
    local lure = Data.LURE
    local age = now - state.start
    if age >= lure.hours - EPS then
        state.spent = true
        return { sound = false, expired = true, slot = state.slot }
    end
    local slot = math.floor(age / lure.interval + EPS)
    if slot > (state.slot or -1) then
        state.slot = slot
        return { sound = true, expired = false, slot = slot }
    end
    return { sound = false, expired = false, slot = state.slot }
end

-- Hours left on a lure.
function Logic.lureLeft(state, now)
    -- (never more than a whole lure: world time set back puts its start ahead of now)
    return math.max(0, math.min(Data.LURE.hours, Data.LURE.hours - (now - state.start)))
end

return Logic
