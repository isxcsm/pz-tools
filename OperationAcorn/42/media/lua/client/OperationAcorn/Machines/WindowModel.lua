-- What the machine window shows (DESIGN 12; mockups/machines/a-equipment.html, "research-team equipment"): the name
-- plate and its light, what the machine does or what to do next, its jobs, its bins, its performance in the units the
-- game uses, its parts with what each does and the buttons that make sense, and the rain storage's water or the
-- lure's hours. Model.read takes what it needs from the game once (the status, the jobs, the bins); Model.build makes
-- the texts and shares from that alone (the tests give it plain tables). Nothing here draws: WindowLayout.lua lays the
-- model out, Window.lua does it again only when the model changed (Model.key).
require "OperationAcorn/Machines/Machines"
local OA = OperationAcorn
local Machines = OA.Machines
local Data, Logic = Machines.Data, Machines.Logic
local Model = {}
Machines.WindowModel = Model

-- The vanilla numbers the window compares with: a fridge's generator load (IsoGenerator.FridgeFreezerPowerConsumption),
-- a generator's sound radius outdoors (Base.Generator SoundRadius) and the noise trap's (vanilla NoiseTrap). And the rain
-- a fluid container's rain factor of 1 catches in a game hour of the heaviest rain (FluidContainerUpdateSystem: 0.005 L
-- a game second times the precipitation intensity, 0 to 1, and the factor; half of it in snow). The game's rain
-- collectors come in more than one size (factors 0.25 and 0.4), so the window gives litres, not a ratio to one of them.
Model.FRIDGE_LOAD = 0.13
Model.GENERATOR_NOISE = 20
Model.NOISE_TRAP = 17
Model.RAIN_LITRES_AN_HOUR = 0.005 * 3600
-- The sandbox's generator fuel an hour for a load of 1 (GeneratorFuelConsumption, in litres: IsoGenerator's
-- getTotalPowerUsing is the load times it, "L/h").
Model.FUEL_DEFAULT = 0.1

local function text(key, ...) return getText(key, ...) end

-- Numbers -----------------------------------------------------------------------------------------------------------

-- A number with at most `places` decimals and no zeros after the point: 1.50 -> "1.5", 2.0 -> "2".
function Model.decimal(x, places)
    local s = string.format("%." .. places .. "f", x)
    if string.find(s, ".", 1, true) then
        s = string.gsub(s, "0+$", "")
        s = string.gsub(s, "%.$", "")
    end
    if s == "-0" then s = "0" end
    return s
end

-- An amount as the window writes it: whole from 100 up, one decimal from 1, two under.
function Model.amount(x)
    x = x or 0
    if x >= 100 then return tostring(OA.round(x)) end
    if x >= 1 then return Model.decimal(x, 1) end
    return Model.decimal(x, 2)
end

-- A whole number with its thousands marked: 4000 -> "4,000".
function Model.grouped(n)
    local s = tostring(OA.round(n or 0))
    local count
    repeat s, count = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2") until count == 0
    return s
end

-- Hours as a time: "16분", "2시간", "16시간 20분" (at least a minute).
function Model.duration(hours)
    local minutes = math.max(1, OA.round((hours or 0) * 60))
    if minutes < 60 then return text("IGUI_OA_Machine_Minutes", minutes) end
    local h = math.floor(minutes / 60)
    local m = minutes - h * 60
    if m == 0 then return text("IGUI_OA_Machine_Hours", h) end
    return text("IGUI_OA_Machine_HoursMinutes", h, m)
end

-- The number of a machine ("m12" -> 12).
function Model.number(id)
    return tonumber(string.match(tostring(id or ""), "%d+")) or 0
end

-- The light and the strip ------------------------------------------------------------------------------------------
-- A tone is the name of a palette colour: good, warn, bad, off, water.

local STOP_REASONS = { outputFull = true, noTank = true, noOwner = true }

-- Whether a working machine would work on what is in it now (on, its parts, power, and nothing stops it).
local function canWork(status)
    return status.on and not status.stopped and status.powered ~= false and not STOP_REASONS[status.reason]
end

local function lightOf(input)
    local status, kind = input.status, input.kind
    if kind == "lure" then
        if status.spent then return { text = text("IGUI_OA_Machine_LureSpent"), tone = "off", hollow = true } end
        return { text = text("IGUI_OA_Machine_State_running"), tone = "good" }
    end
    if kind == "rainStorage" then
        local share = (status.capacity or 0) > 0 and (status.water or 0) / status.capacity or 0
        return { text = text("IGUI_OA_Machine_WaterShare", math.floor(share * 100 + 0.5)), tone = "water" }
    end
    local tone = "warn"
    if not status.on then tone = "off"
    elseif status.stopped or status.powered == false then tone = "bad"
    elseif status.running then tone = status.worn and "warn" or "good" end
    return { text = Machines.statusText(status), tone = tone, hollow = not status.on }
end

local function stripOf(input)
    local status, kind = input.status, input.kind
    if kind == "lure" then
        if status.spent then return { text = text("IGUI_OA_Machine_Do_lureSpent"), tone = "off" } end
        return { text = text("IGUI_OA_Machine_Hint_lure"), tone = "good" }
    end
    if kind == "rainStorage" then return { text = text("IGUI_OA_Machine_Hint_rainStorage"), tone = "water" } end
    if status.stopped then
        local slot = text("IGUI_OA_Machine_Slot_" .. (status.broken or status.missing or "motor"))
        if status.broken then return { text = text("IGUI_OA_Machine_Do_broken", slot), tone = "bad" } end
        return { text = text("IGUI_OA_Machine_Do_missing", slot), tone = "bad" }
    end
    if not status.on then return { text = text("IGUI_OA_Machine_Do_off"), tone = "off" } end
    if status.powered == false then return { text = text("IGUI_OA_Machine_Do_noPower"), tone = "bad" } end
    if status.running then
        if status.worn then return { text = text("IGUI_OA_Machine_Do_worn"), tone = "warn" } end
        return { text = text("IGUI_OA_Machine_Do_running"), tone = "good" }
    end
    if STOP_REASONS[status.reason] then return { text = text("IGUI_OA_Machine_Do_" .. status.reason), tone = "warn" } end
    if (input.inCount or 0) == 0 then return { text = text("IGUI_OA_Machine_Hint_" .. kind), tone = "warn" } end
    return { text = text("IGUI_OA_Machine_Do_idle"), tone = "warn" }
end

-- The switch on the plate (a machine that works on things only).
local function switchOf(input)
    if not Data.processes(input.kind) then return nil end
    if input.status.on then return { label = text("ContextMenu_Turn_Off"), enabled = true } end
    local ok = input.canOn == nil or input.canOn.ok
    return { label = text("ContextMenu_Turn_On"), enabled = ok == true, tip = not ok and input.canOn.why or nil }
end

-- Jobs and bins ------------------------------------------------------------------------------------------------------

local function jobsOf(input)
    local status = input.status
    local jobs = { lanes = status.lanes or 1, right = text("IGUI_OA_Machine_Jobs_AtOnce", status.lanes or 1), rows = {} }
    for _, job in ipairs(input.jobs or {}) do
        local share = OA.clamp(job.share or 0, 0, 1)
        jobs.rows[#jobs.rows + 1] = { icon = job.fullType, name = job.name, share = share,
            pct = math.floor(share * 100) .. "%" }
    end
    if #jobs.rows == 0 then
        local count = input.inCount or 0
        if count == 0 then
            jobs.empty = { text("IGUI_OA_Machine_Jobs_None"), text("IGUI_OA_Machine_Jobs_PutIn") }
        elseif canWork(status) then
            jobs.empty = { text("IGUI_OA_Machine_Jobs_Soon"), text("IGUI_OA_Machine_Jobs_Left", count) }
        else
            jobs.empty = { text("IGUI_OA_Machine_Jobs_Stopped"), text("IGUI_OA_Machine_Jobs_Left", count) }
        end
    end
    return jobs
end

-- The input bin's note when the machine does not work on it: what it waits for.
local function waitNote(status)
    if status.stopped then return text("IGUI_OA_Machine_Box_Fix") end
    if not status.on then return text("IGUI_OA_Machine_Box_Off") end
    if status.powered == false then return text("IGUI_OA_Machine_Box_Power") end
    if status.reason == "outputFull" then return text("IGUI_OA_Machine_Box_OutFull") end
    if status.reason == "noTank" then return text("IGUI_OA_Machine_Box_NoTank") end
    return text("IGUI_OA_Machine_Box_Start")
end

-- Whether the time a bin takes to empty can be told: the work is by weight (the cutter, the shredder, the saw, and the
-- propane refiner's rotten food), not the oil refiner's litres.
local function byWeight(kind)
    return Data.KINDS[kind].work ~= nil or kind == "propaneRefiner"
end

local function boxesOf(input)
    local status, kind = input.status, input.kind
    local boxes = {}
    for _, box in ipairs(input.boxes or {}) do
        local capacity = math.max(1, box.capacity or 100)
        local frac = OA.clamp((box.weight or 0) / capacity, 0, 1)
        local count = box.count or 0
        local countText = count > 0 and text("IGUI_OA_Machine_Box_Count", count) or text("IGUI_OA_Machine_Box_Empty")
        local note, tone = nil, "warn"
        if box.role == "in" then
            if count == 0 then note = text("IGUI_OA_Machine_Box_Start")
            elseif status.running and byWeight(kind) and (status.rate or 0) > 0 then
                note = text("IGUI_OA_Machine_Box_Eta", Model.duration((box.weight or 0) / status.rate))
            elseif status.running then note = text("IGUI_OA_Machine_State_running")
            else note = waitNote(status) end
        elseif box.role == "tank" then
            note = text("IGUI_OA_Machine_Box_Tanks")
        else
            note = text("IGUI_OA_Machine_Box_FullStops")
            if frac >= 0.95 then tone = "bad" end
        end
        boxes[#boxes + 1] = {
            role = box.role, title = text(Data.TITLES[box.type] or ("IGUI_ContainerTitle_" .. tostring(box.type))), amount = Model.amount(box.weight or 0),
            capacity = Model.grouped(capacity), frac = frac, tone = tone, note = text("IGUI_OA_Machine_Box_Note", countText, note),
            strong = box.role == "in" and count == 0 and status.on and not status.stopped,
        }
    end
    return boxes
end

-- Performance --------------------------------------------------------------------------------------------------------

local function rateText(kind, rate)
    return text("IGUI_OA_Machine_Rate_" .. (kind == "oilRefiner" and "litres" or "weight"), Model.amount(rate))
end

-- The motor's own numbers, or the old motor's when it has none that works.
local function motorOf(kind, parts)
    local motor = parts and parts.motor
    local tier = motor and motor.cond > 0 and Logic.partDef(kind, "motor", motor.tier)
    return tier or Data.PARTS.motor.tiers.old
end

local function perfOf(input)
    local status, kind = input.status, input.kind
    local def = Data.KINDS[kind]
    local running = status.running
    local parts = status.parts or {}
    local cells = {}

    -- the rate, and how it is made (the tooltip)
    local speed = status.speed or 1
    local sub, subTone
    if status.worn then sub, subTone = text("IGUI_OA_Machine_Perf_Worn"), "warn"
    elseif math.abs(speed - 1) < 0.005 then sub = text("IGUI_OA_Machine_Perf_OldMotor")
    else sub = text("IGUI_OA_Machine_Perf_Times", Model.decimal(speed, 1)) end
    local motor = motorOf(kind, parts)
    local tip = { { s = text("IGUI_OA_Machine_Perf_Rate"), tone = "head" },
        text("IGUI_OA_Machine_Perf_TipBase", rateText(kind, def.rate)),
        text("IGUI_OA_Machine_Perf_TipLanes", status.lanes or 1),
        text("IGUI_OA_Machine_Perf_TipSpeed", Model.decimal(motor.speed, 2)) }
    local cover = parts.cover
    if cover and cover.cond > 0 then
        local coverDef = Logic.partDef(kind, "cover", cover.tier)
        if coverDef then tip[#tip + 1] = text("IGUI_OA_Machine_Perf_TipCover", Model.decimal(coverDef.speed, 2)) end
    end
    if status.worn then tip[#tip + 1] = text("IGUI_OA_Machine_Perf_TipWorn") end
    tip[#tip + 1] = "-"
    tip[#tip + 1] = { s = text("IGUI_OA_Machine_Perf_TipTotal", rateText(kind, status.rate or 0)), tone = "value" }
    cells[1] = { value = rateText(kind, status.rate or 0), sub = sub, subTone = subTone, tip = tip }

    -- the power: the load it puts on whatever powers it (the grid, a generator, the power mod's panels), as fridges; a
    -- generator's fuel for it (the load times the sandbox's fuel an hour) only in the tooltip, since grid or solar power
    -- burns none
    local fuelRate = input.fuelRate or Model.FUEL_DEFAULT
    local load = status.load or 0
    local powerSub
    if not input.hook then powerSub = text("IGUI_OA_Machine_Perf_NoHook")
    elseif running then powerSub = text("IGUI_OA_Machine_Perf_Fridges", math.max(1, OA.round(load / Model.FRIDGE_LOAD)))
    else powerSub = text("IGUI_OA_Machine_Perf_NotNow") end
    cells[2] = { value = text("IGUI_OA_Machine_Perf_Power", Model.decimal(load, 2)), sub = powerSub,
        tip = { { s = text("IGUI_OA_Machine_Perf_PowerHead"), tone = "head" }, text("IGUI_OA_Machine_Perf_TipPower"),
            text("IGUI_OA_Machine_Perf_TipGenFuel", Model.decimal(load * fuelRate, 2), Model.decimal(load, 2),
                Model.decimal(fuelRate, 3)) } }

    -- the noise
    local noiseTip = { { s = text("IGUI_OA_Machine_Noise"), tone = "head" }, text("IGUI_OA_Machine_Perf_TipNoise") }
    if def.noise and status.noise and status.noise < def.noise then noiseTip[#noiseTip + 1] = text("IGUI_OA_Machine_Perf_TipQuiet") end
    cells[3] = { value = text("IGUI_OA_Machine_Perf_Noise", status.noise or 0),
        sub = running and text("IGUI_OA_Machine_Perf_GenNoise", Model.GENERATOR_NOISE) or text("IGUI_OA_Machine_Perf_Quiet"),
        tip = noiseTip }
    return { right = not running and text("IGUI_OA_Machine_Perf_WhenRunning") or nil, cells = cells }
end

-- Parts --------------------------------------------------------------------------------------------------------------

-- What a part of a tier does, in words (the part kind's numbers, Data.PARTS).
function Model.effect(partKind, t)
    if partKind == "motor" then
        return text("IGUI_OA_Machine_Fx_motor", t.lanes or 1, Model.decimal(t.speed, 2), Model.decimal(t.power, 2))
    elseif partKind == "shredBlade" then
        if t.yield == 1 then return text("IGUI_OA_Machine_Fx_shredBase") end
        return text("IGUI_OA_Machine_Fx_shred", Model.decimal(t.yield, 2))
    elseif partKind == "cutBlade" then
        if t.pieces == 0 then return text("IGUI_OA_Machine_Fx_cutBase") end
        return text("IGUI_OA_Machine_Fx_cut", Model.decimal(t.pieces, 2))
    elseif partKind == "sawBlade" then
        return text("IGUI_OA_Machine_Fx_saw", Model.decimal(t.planks, 2))
    elseif partKind == "catalyst" then
        if t.use == 1 then return text("IGUI_OA_Machine_Fx_catalystBase") end
        return text("IGUI_OA_Machine_Fx_catalyst", OA.round(t.use * 100))
    elseif partKind == "cover" then
        return text("IGUI_OA_Machine_Fx_cover", Model.decimal(t.noise, 2), Model.decimal(t.speed, 2))
    end
    return ""
end

-- Hours of running a part has left at its wear (the kind's wear multiplier on the tier's).
function Model.hoursLeft(kind, partDef, cond)
    local wear = partDef.wear * (Data.KINDS[kind].wear or 1)
    if wear <= 0 then return nil end
    return cond / wear
end

-- The icon of a part item.
local function partIcon(partKind, tier)
    return Data.MODULE .. "." .. Data.partItem(partKind, tier)
end

local function partsOf(input)
    local status, kind = input.status, input.kind
    local def = Data.KINDS[kind]
    local cards = {}
    for _, slot in ipairs(def.slots) do
        local part = status.parts and status.parts[slot]
        local partKind = Data.partKind(kind, slot)
        local card = { slot = slot, name = text("IGUI_OA_Machine_Slot_" .. slot), buttons = {} }
        local tierDef = part and Logic.partDef(kind, slot, part.tier)
        if part and tierDef then
            local cond = OA.clamp(part.cond or 0, 0, Data.CONDITION_MAX)
            card.icon = partIcon(partKind, part.tier)
            card.tier = text("IGUI_OA_Machine_Tier_" .. part.tier)
            card.frac = cond / Data.CONDITION_MAX
            card.pct = math.floor(cond + 0.5) .. "%"
            card.broken = cond <= 0
            card.worn = not card.broken and cond < Data.WORN_BELOW
            card.tone = card.broken and "bad" or (card.worn and "warn" or "good")
            if card.broken then
                card.life, card.lifeTone = text("IGUI_OA_Machine_Part_Broken"), "bad"
                card.effect, card.effectTone = text(slot == "cover" and "IGUI_OA_Machine_Part_BrokenCover"
                    or "IGUI_OA_Machine_Part_BrokenFx"), "bad"
            else
                local hours = Model.hoursLeft(kind, tierDef, cond)
                card.life = hours and text("IGUI_OA_Machine_Part_Hours", math.floor(hours)) or ""
                if card.worn then
                    card.effect, card.effectTone = text(slot == "cover" and "IGUI_OA_Machine_Part_WornCover"
                        or "IGUI_OA_Machine_Part_WornFx"), "warn"
                else
                    card.effect = Model.effect(partKind, tierDef)
                end
            end
            if card.broken or card.worn then
                card.buttons[#card.buttons + 1] = { id = "replace", label = text("IGUI_OA_Machine_Replace"),
                    strong = card.broken }
            end
            card.buttons[#card.buttons + 1] = { id = "remove", label = text("IGUI_OA_Machine_Remove"),
                tip = Data.processes(kind) and text("IGUI_OA_Machine_Part_RemoveTip") or nil }
        else
            card.empty = true
            card.tier = text("IGUI_OA_Machine_Part_None")
            local optional = def.empty and def.empty[slot]
            -- an empty slot the machine runs without (the cover) is one slim row: its name, what one would do, the button
            card.slim = optional or nil
            card.effect = text(optional and "IGUI_OA_Machine_Part_Optional" or "IGUI_OA_Machine_Part_Needed")
            card.effectTone = not optional and "bad" or nil
            card.buttons[1] = { id = "install", label = text("IGUI_OA_Machine_Install"), strong = not optional }
        end
        cards[#cards + 1] = card
    end
    return cards
end

-- The rain storage and the lure ----------------------------------------------------------------------------------------

local function rainOf(input)
    local status = input.status
    local capacity = status.capacity or Data.RAIN_CAPACITY
    local water = OA.clamp(status.water or 0, 0, capacity)
    local ticks = {}
    for k = 1, 3 do ticks[k] = Model.grouped(capacity * k / 4) end
    return {
        right = text("IGUI_OA_Machine_Rain_Of", Model.grouped(capacity)),
        frac = capacity > 0 and water / capacity or 0, ticks = ticks,
        water = Model.grouped(water), capacity = Model.grouped(capacity),
        rows = {
            { text("IGUI_OA_Machine_Rain_Room"), Model.grouped(capacity - water) .. " L" },
            { text("IGUI_OA_Machine_Rain_Catch"),
                text("IGUI_OA_Machine_Rain_CatchValue", Model.grouped(Data.RAIN_FACTOR * Model.RAIN_LITRES_AN_HOUR)) },
        },
        canEmpty = water > 0.01 and input.canEmpty ~= false,
        canTransfer = input.canTransfer ~= false,
    }
end

local function lureOf(input)
    local status = input.status
    local lure = Data.LURE
    local left = status.spent and 0 or OA.clamp(status.left or 0, 0, lure.hours)
    local next
    if not status.spent then
        local age = lure.hours - left
        -- (no % on the hours: the game's Lua gets it wrong on large numbers)
        local into = age - math.floor(age / lure.interval) * lure.interval
        next = text("IGUI_OA_Machine_Lure_NextValue", Model.duration(lure.interval - into),
            OA.round(lure.interval * 60))
    end
    return {
        right = text("IGUI_OA_Machine_Lure_Of", lure.hours), hours = lure.hours, left = left,
        big = left > 0 and text("IGUI_OA_Machine_Lure_LeftValue", Model.duration(left))
            or text("IGUI_OA_Machine_Lure_LeftValue", text("IGUI_OA_Machine_Hours", 0)),
        ends = { "0", tostring(OA.round(lure.hours / 2)), text("IGUI_OA_Machine_Hours", lure.hours) },
        rows = {
            { text("IGUI_OA_Machine_Lure_Next"), next or text("IGUI_OA_Machine_Lure_None") },
            { text("IGUI_OA_Machine_Lure_Radius"), text("IGUI_OA_Machine_Lure_RadiusValue", lure.radius, Model.NOISE_TRAP) },
        },
        spent = status.spent == true,
        button = status.spent and { id = "lure:clear", label = text("IGUI_OA_Machine_Lure_Clear"), note = text("IGUI_OA_Machine_Lure_ClearNote") }
            or { id = "lure:take", label = text("IGUI_OA_Machine_Lure_Take"), note = text("IGUI_OA_Machine_Lure_TakeNote") },
    }
end

-- The model ------------------------------------------------------------------------------------------------------------

-- The window's model from what Model.read gives: { kind, title, icon, tag, light, switch, strip, jobs, boxes, perf,
-- parts, rain, lure, due (a job is due: the window asks the machine to work) }.
function Model.build(input)
    local kind = input.kind
    local status = input.status
    local model = {
        kind = kind, title = Machines.name(kind), icon = Machines.itemFullType(kind),
        tag = text("IGUI_OA_Machine_Tag", Model.number(input.id)),
        light = lightOf(input), strip = stripOf(input), switch = switchOf(input),
    }
    if Data.processes(kind) then
        model.jobs = jobsOf(input)
        model.boxes = boxesOf(input)
        model.perf = perfOf(input)
        for _, job in ipairs(input.jobs or {}) do
            if (job.share or 0) >= 1 then model.due = true end
        end
        -- on, with something in it and nothing in hand: it may start now rather than at its next step
        model.idleWithInput = not status.running and (input.inCount or 0) > 0 and canWork(status)
    end
    if #Data.KINDS[kind].slots > 0 then model.parts = partsOf(input) end
    if kind == "rainStorage" then model.rain = rainOf(input) end
    if kind == "lure" then model.lure = lureOf(input) end
    return model
end

-- A model as one string: two models that show the same give the same key (the window lays out again only when it
-- changes). Job shares count by the hundredth, as they show.
local function keyOf(v, out)
    local t = type(v)
    if t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        out[#out + 1] = "{"
        for _, k in ipairs(keys) do
            out[#out + 1] = tostring(k)
            out[#out + 1] = "="
            keyOf(v[k], out)
            out[#out + 1] = ";"
        end
        out[#out + 1] = "}"
    elseif t == "number" then
        out[#out + 1] = string.format("%.2f", v)
    else
        out[#out + 1] = tostring(v)
    end
end

function Model.key(model)
    local out = {}
    keyOf(model, out)
    return table.concat(out)
end

-- What Model.build needs, read from the game: the status (once), the jobs in hand, the bins (their weight, capacity
-- and count: no walk through their items), whether it can be switched on, the rain storage's fluid.
function Model.read(object)
    local status = Machines.status(object)
    if not status then return nil end
    local state = Machines.state(object)
    local kind = status.kind
    local input = { kind = kind, id = state.id, status = status, hook = OA.api() ~= nil,
        fuelRate = SandboxVars and SandboxVars.GeneratorFuelConsumption or Model.FUEL_DEFAULT }
    if Data.processes(kind) then
        input.jobs = {}
        for _, job in ipairs(Machines.progress(object) or {}) do
            input.jobs[#input.jobs + 1] = { fullType = job.item:getFullType(), name = job.item:getName(), share = job.share }
        end
        input.boxes = {}
        for _, role in ipairs(Data.KINDS[kind].containers) do
            local container = Machines.container(object, role)
            if container then
                local count = container:getItems():size()
                input.boxes[#input.boxes + 1] = { role = role, type = container:getType(),
                    weight = container:getCapacityWeight(), capacity = container:getCapacity(), count = count }
                if role == "in" then input.inCount = count end
            end
        end
        local ok, why = Machines.canSwitchOn(object)
        input.canOn = { ok = ok == true, why = why }
    end
    if kind == "rainStorage" and object.getFluidContainer then
        local fluid = object:getFluidContainer()
        input.canEmpty = fluid ~= nil and fluid:canPlayerEmpty()
        input.canTransfer = fluid ~= nil
    end
    return input
end

return Model
