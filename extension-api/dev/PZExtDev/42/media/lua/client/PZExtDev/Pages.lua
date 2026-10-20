-- PZ Extension API Dev: the window's own section, "API": the game's environment for every mod's tests, and the
-- API's state and areas, read and tried as a mod would through a handle of its own ("PZExtDev"). Nothing of a mod's
-- content is here: the mods' dev mods add their own sections (Panel.lua).
if not isDebugEnabled() then return end
require "PZExtDev/Panel"
require "PZExtDev/Env"
local Dev = PZExtDev
local Env = Dev.Env

local function T(key, ...)
    return getText("IGUI_PZExtDev_" .. key, ...)
end

local function api()
    return PZExtAPI
end

local function hourText(hour)
    local h = math.floor(hour)
    local m = math.floor((hour - h) * 60 + 0.5)
    if m >= 60 then
        h = h + 1
        m = 0
    end
    local function two(n) return n < 10 and ("0" .. string.format("%.0f", n)) or string.format("%.0f", n) end
    return two(h) .. ":" .. two(m)
end

-- ---- Environment ---------------------------------------------------------------------------------------------------

local function envPage(page, ui)
    local PAD, W = ui.PAD, ui.W
    local state = ui.lines(page, 1, 2)

    ui.heading(page, T("Env_Time"), 3)
    local hourLabel = ui.label(page, "", W - PAD - 60, ui.row(3) + 2)
    local hourSlider = ui.slider(page, PAD, ui.row(4), W - 2 * PAD, 0, 24, 0.25, 1, function(value)
        Env.time(value)
        hourLabel:setName(hourText(value))
    end)
    local frozen = ui.tick(page, T("Env_Freeze"), PAD, ui.row(5), function(on) Env.freeze(on) end)
    ui.buttons(page, 6, {
        { T("Env_Noon"), function() Env.time(12) end },
        { T("Env_Dusk"), function() Env.time(19) end },
        { T("Env_TwoAm"), function() Env.time(2) end },
        { T("Env_Dawn"), function() Env.time(6) end },
        { "||", function() Env.speed(0) end },
        { "1x", function() Env.speed(1) end },
        { "2x", function() Env.speed(2) end },
        { "3x", function() Env.speed(3) end },
        { "4x", function() Env.speed(4) end },
    })

    ui.heading(page, T("Env_Weather"), 8)
    ui.buttons(page, 9, {
        { T("Env_Clear"), function() Env.clearWeather() end },
        { T("Env_Rain"), function() Env.rain(3) end },
        { T("Env_Storm"), function() Env.storm(3) end },
        { T("Env_Snow"), function() Env.snow(6) end },
    })
    ui.label(page, T("Env_Temperature"), PAD, ui.row(10) + 2)
    local _, tx = ui.button(page, "-10", PAD + 110, ui.row(10), 40, function() Env.temperature(-10) end)
    _, tx = ui.button(page, "0", tx, ui.row(10), 40, function() Env.temperature(0) end)
    _, tx = ui.button(page, "15", tx, ui.row(10), 40, function() Env.temperature(15) end)
    _, tx = ui.button(page, "30", tx, ui.row(10), 40, function() Env.temperature(30) end)
    ui.button(page, T("Env_TemperatureGame"), tx, ui.row(10), 0, function() Env.temperature(nil) end)

    ui.heading(page, T("Env_Character"), 12)
    local god = ui.tick(page, T("Env_God"), PAD, ui.row(13), function(on) Env.godMode(on) end)
    local invisible = ui.tick(page, T("Env_Invisible"), PAD + 180, ui.row(13), function(on) Env.invisible(on) end)
    local noClip = ui.tick(page, T("Env_NoClip"), PAD + 360, ui.row(13), function(on) Env.noClip(on) end)
    ui.buttons(page, 14, {
        { T("Env_Heal"), function() Env.heal() end },
        { T("Env_Needs"), function() Env.refresh() end },
    })

    ui.heading(page, T("Env_Zombies"), 16)
    ui.label(page, T("Env_Count"), PAD, ui.row(17) + 2)
    local countItems = {}
    for _, n in ipairs({ 1, 5, 10, 25, 50 }) do countItems[#countItems + 1] = { tostring(n), n } end
    local countBox = ui.combo(page, PAD + 90, ui.row(17), 80, countItems)
    local outfits = { { T("Env_AnyOutfit"), false }, { "Generic01", "Generic01" }, { "Survivalist", "Survivalist" },
        { "Police", "Police" }, { "Fireman", "Fireman" }, { "Doctor", "Doctor" }, { "ArmyCamoGreen", "ArmyCamoGreen" } }
    local outfitBox = ui.combo(page, PAD + 180, ui.row(17), 170, outfits)
    local harmless = ui.tick(page, T("Env_Harmless"), PAD + 360, ui.row(17), function() end)
    harmless:setSelected(1, true)
    ui.buttons(page, 18, {
        { T("Env_Spawn"), function()
            Env.spawn(countBox:getSelectedData(), outfitBox:getSelectedData() or nil, harmless:isSelected(1))
        end },
        { T("Env_Clear30"), function() Env.clearZombies(30) end },
        { T("Env_ClearAll"), function() Env.clearZombies() end },
        { T("Env_Sound"), function() Env.sound(0, 0, 40, 40) end },
    })

    page.refresh = function()
        local hour = Env.hour()
        hourLabel:setName(hourText(hour))
        if not hourSlider.dragInside then hourSlider:setCurrentValue(hour, true) end
        frozen:setSelected(1, Env.frozen())
        local g, i, n = Env.flags()
        god:setSelected(1, g)
        invisible:setSelected(1, i)
        noClip:setSelected(1, n)
        local temp, held = Env.temperatureNow()
        local rain, snow, light = Env.weatherNow()
        local x, y, z = Env.where()
        state:set({
            T("Env_StateTime", hourText(hour), ui.num(getGameTime():getTrueMultiplier(), 1), ui.num(temp, 1),
                held and T("Env_Held") or "", ui.num(rain, 2), ui.num(snow, 2), ui.num(light, 2)),
            T("Env_StatePlace", ui.num(x), ui.num(y), ui.num(z), ui.num(Env.zombiesNear(30))),
        })
    end
end

-- ---- the API's own pages ------------------------------------------------------------------------------------------

local handle = nil
-- This mod's handle, as a mod would have one.
local function mine()
    local a = api()
    if not a then error(T("NoApi"), 0) end
    handle = handle or a.client("PZExtDev")
    return handle
end

-- The keys of a table, sorted (pairs walks a Kahlua table without next()).
local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function num(value)
    return Dev.ui.num(value, 3)
end

local function show(value)
    if type(value) == "table" then
        local parts = {}
        for _, k in ipairs(sortedKeys(value)) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(value[k]) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    if type(value) == "number" then return num(value) end
    return tostring(value)
end

local function statusPage(page, ui)
    local lines = ui.lines(page, 1, 14)
    ui.buttons(page, 16, {
        { T("St_Log"), function()
            for _, name in ipairs(sortedKeys(api().hooks())) do print("[dev] hook " .. name .. " " .. tostring(api().hooks()[name])) end
            ui.say(T("St_Logged"))
        end },
    })
    page.refresh = function()
        local a = api()
        if not a then lines:set({ T("NoApi") }) return end
        local hooks = a.hooks()
        local applied, waiting, broken = 0, 0, {}
        for _, name in ipairs(sortedKeys(hooks)) do
            local state = hooks[name]
            if state == "applied" then applied = applied + 1
            elseif state == "not-loaded" then waiting = waiting + 1
            else broken[#broken + 1] = name .. ": " .. tostring(state) end
        end
        local points, notApplied = 0, 0
        for _, state in pairs(a.formulas and a.formulas.points() or {}) do
            points = points + 1
            if state ~= "applied" then notApplied = notApplied + 1 end
        end
        local out = {
            T("St_Version", ui.num(a.version)),
            T("St_Hooks", ui.num(applied), ui.num(waiting), ui.num(#broken)),
            T("St_Points", ui.num(points), ui.num(notApplied)),
            T("St_Text", a.text and tostring(a.text.status()) or "-"),
            T("St_Networks", ui.num(a.networks and #a.networks.ids() or 0)),
        }
        for i = 1, math.min(#broken, 9) do out[#out + 1] = broken[i] end
        lines:set(out)
    end
end

-- Values a point is tried with: its shape is not known from here, so a wrong one is the API's error on the status line.
local TRIES = { { "0", 0 }, { "0.5", 0.5 }, { "1", 1 }, { "2", 2 }, { "true", true } }

local function pointsPage(page, ui)
    local a = api()
    local names = {}
    for _, name in ipairs(sortedKeys(a and a.formulas and a.formulas.points() or {})) do names[#names + 1] = { name, name } end
    if #names == 0 then names[1] = { T("NoApi"), false } end
    local box = ui.combo(page, ui.PAD, ui.row(1), ui.W - 2 * ui.PAD, names)
    local lines = ui.lines(page, 2, 3)
    local list = {}
    for _, try in ipairs(TRIES) do
        list[#list + 1] = { T("Pt_Set", try[1]), function()
            api().formulas.set(mine(), box:getSelectedData(), try[2])
            ui.say(T("Pt_Declared", box:getSelectedData(), try[1]))
        end }
    end
    list[#list + 1] = { T("Pt_Clear"), function() api().formulas.set(mine(), box:getSelectedData(), nil) end }
    list[#list + 1] = { T("Pt_ClearAll"), function() mine():clear() end }
    local rows = ui.buttons(page, 5, list)

    ui.heading(page, T("Pt_Tunings"), 6 + rows)
    local tuning = ui.lines(page, 7 + rows, 2)
    ui.buttons(page, 9 + rows, {
        { "-0.1", function()
            local t = api().formulas.tunings()["nightSight.floor"]
            api().formulas.tune("nightSight.floor", t.value - 0.1)
        end },
        { "+0.1", function()
            local t = api().formulas.tunings()["nightSight.floor"]
            api().formulas.tune("nightSight.floor", t.value + 0.1)
        end },
        { T("Pt_Default"), function() api().formulas.tune("nightSight.floor") end },
    })
    page.refresh = function()
        local f = api() and api().formulas
        local point = box:getSelectedData()
        if not f or not point then lines:set({ T("NoApi") }) return end
        lines:set({
            T("Pt_Status", tostring(f.points()[point])),
            T("Pt_Combined", show(f.get(point))),
            T("Pt_Mine", handle and show(f.declared(handle, point)) or "nil"),
        })
        local t = f.tunings()["nightSight.floor"]
        local ns = f.nightSight()
        tuning:set({
            t and T("Pt_Floor", ui.num(t.value, 2), ui.num(t.default, 2)) or "",
            ns and T("Pt_Night", show(ns.level), show(ns.floor), show(ns.programs), tostring(ns.problem or "-")) or "",
        })
    end
end

local function buildingsPage(page, ui)
    local here = ui.lines(page, 1, 4)
    local found = ui.lines(page, 6, 2)
    ui.buttons(page, 8, {
        { T("Bd_Objects"), function()
            local x, y, z = Env.where()
            local b = api().buildings.at(x, y, z)
            if not b then found:set({ T("Bd_None") }) return end
            local power, water = 0, 0
            local objects, complete = api().buildings.objects(b.key)
            for _, o in ipairs(objects or {}) do
                if o.power then power = power + 1 end
                if o.water then water = water + 1 end
            end
            local attached = api().buildings.attached(b.key)
            found:set({ T("Bd_Counts", ui.num(power), ui.num(water), tostring(complete)),
                T("Bd_Attached", ui.num(attached and #attached or 0)) })
        end },
    })

    ui.heading(page, T("Bd_Networks"), 10)
    local ids = {}
    local box = ui.combo(page, ui.PAD, ui.row(11), 300, {})
    ui.button(page, T("Bd_Reload"), ui.PAD + 310, ui.row(11), 0, function()
        box:clear()
        ids = api().networks.ids()
        for _, id in ipairs(ids) do box:addOptionWithData(id, id) end
    end)
    local net = ui.lines(page, 12, 5)

    page.refresh = function()
        local a = api()
        if not a then here:set({ T("NoApi") }) return end
        local x, y, z = Env.where()
        local b = a.buildings.at(x, y, z)
        if b then
            here:set({ T("Bd_Key", b.key, tostring(b.playerBuilt)), T("Bd_Room", tostring(b.room), tostring(b.roomId)),
                T("Bd_Box", ui.num(b.minX), ui.num(b.minY), ui.num(b.maxX), ui.num(b.maxY), ui.num(b.minLevel), ui.num(b.maxLevel)),
                T("Bd_Version", ui.num(a.buildings.version())) })
        else
            here:set({ T("Bd_None"), "", "", T("Bd_Version", ui.num(a.buildings.version())) })
        end
        local id = box:getSelectedData()
        local s = id and a.networks.state(id)
        if not s then net:set({ id and T("Bd_NoNetwork") or "" }) return end
        local producer = s.producer and (s.producer.source or (ui.num(s.producer.x) .. "," .. ui.num(s.producer.y))) or "-"
        net:set({
            T("Bd_Net", s.owner, s.utility, s.policy, tostring(s.supplied), tostring(s.enabled), tostring(s.parent or "-")),
            s.utility == "power" and T("Bd_Power", show(s.load), show(s.ownLoad), show(s.loadFactor), show(s.fuelPerHour), show(s.hoursLeft))
                or T("Bd_Water", show(s.amount), show(s.capacity), tostring(s.purify)),
            T("Bd_Producer", producer, ui.num(s.producers and #s.producers or 0), tostring(s.complete)),
        })
    end
end

local SAMPLES = { { "Title_Ko", "Sub_Ko" }, { "Title_En", "Sub_En" } }

-- The sounds of a title style, when a mod that has them gave a way to find them (the API carries none):
-- PZExtDev.titleSounds(style) returns the spec's sounds and subtitleSounds, or nil for a silent title.
local function soundsOf(style)
    local find = PZExtDev.titleSounds
    if type(find) ~= "function" then return nil, nil end
    local ok, sounds, line = pcall(find, style)
    if not ok then return nil, nil end
    return sounds, line
end

local function textPage(page, ui)
    local lines = ui.lines(page, 1, 2)
    local styles = {}
    local a = api()
    for _, s in ipairs(a and a.text and a.text.styles() or {}) do styles[#styles + 1] = { s, s } end
    local styleBox = ui.combo(page, ui.PAD, ui.row(3), 200, styles)
    local sampleBox = ui.combo(page, ui.PAD + 210, ui.row(3), 200,
        { { T("Tx_Korean"), 1 }, { T("Tx_English"), 2 } })
    local burn = ui.tick(page, T("Tx_Burn"), ui.PAD + 420, ui.row(3), function() end)
    local lastKey = nil
    ui.buttons(page, 4, {
        { T("Tx_Title"), function()
            local sample = SAMPLES[sampleBox:getSelectedData() or 1]
            local style = styleBox:getSelectedData()
            local sounds, lineSounds = soundsOf(style)
            lastKey = api().text.title(mine(), { text = T("Tx_" .. sample[1]), subtitle = T("Tx_" .. sample[2]),
                style = style, leave = burn:isSelected(1) and "burn" or nil, now = true, sounds = sounds,
                subtitleSounds = lineSounds })
        end },
        { T("Tx_Typed"), function()
            lastKey = api().text.show(mine(), { text = T("Tx_TypedText"), font = { "SdfRegular", "Medium" }, size = 0.03,
                y = 0.7, enter = "type", cursor = true, hold = 4, leave = "fade", backdrop = 0.4 })
        end },
        { T("Tx_Hide"), function() if lastKey then api().text.hide(mine(), lastKey, true) end end },
    })
    page.refresh = function()
        local t = api() and api().text
        if not t then lines:set({ T("NoApi") }) return end
        lines:set({ T("St_Text", tostring(t.status())), lastKey and T("Tx_Shown", tostring(t.shown(mine(), lastKey))) or "" })
    end
end

local MOODLE = "Test"

local function moodlesPage(page, ui)
    local lines = ui.lines(page, 1, 1)
    local kinds = { { T("Md_Good"), "good" }, { T("Md_Bad"), "bad" }, { T("Md_Neutral"), "neutral" } }
    local kindBox = ui.combo(page, ui.PAD, ui.row(2), 160, kinds)
    ui.button(page, T("Md_Define"), ui.PAD + 170, ui.row(2), 0, function()
        api().moodles.define(mine(), MOODLE, { kind = kindBox:getSelectedData(),
            picture = "media/ui/Moodles/{size}/Mood_Bored.png" })
        ui.say(T("Md_Defined"))
    end)
    local list = {}
    for level = 0, 4 do
        list[#list + 1] = { T("Md_Level", tostring(level)), function() api().moodles.set(mine(), MOODLE, level) end }
    end
    ui.buttons(page, 3, list)
    page.refresh = function()
        local m = api() and api().moodles
        if not m then lines:set({ T("NoApi") }) return end
        local ok, level = pcall(m.level, mine(), MOODLE)
        lines:set({ ok and T("Md_Now", ui.num(level)) or T("Md_NotDefined") })
    end
end

local events = {}   -- the last events the systems page caught, newest first
local function note(text)
    table.insert(events, 1, text)
    while #events > 6 do table.remove(events) end
end
local function onSound(kind, x, y, z, loudness) note(T("Sy_Sound", kind, num(x), num(y), num(loudness))) end
local function onHit(_, _, _, part, damage, killed) note(T("Sy_Hit", tostring(part), num(damage), tostring(killed))) end
local function onHeli(state) note(T("Sy_Heli", tostring(state))) end
local timerTicks, timerId, chunkLoads, chunkId = 0, nil, 0, nil

local function systemsPage(page, ui)
    local lines = ui.lines(page, 1, 4)
    local listen = ui.tick(page, T("Sy_Listen"), ui.PAD, ui.row(6), function(on)
        api().zombies.listen(mine(), on and 30 or 0)
        if on then Events.OnPZExtZombieSound.Add(onSound) else Events.OnPZExtZombieSound.Remove(onSound) end
    end)
    local hits = ui.tick(page, T("Sy_Hits"), ui.PAD + 200, ui.row(6), function(on)
        api().zombies.watchHits(mine(), on)
        if on then Events.OnPZExtZombieHit.Add(onHit) else Events.OnPZExtZombieHit.Remove(onHit) end
    end)
    ui.buttons(page, 7, {
        { T("Sy_Timer"), function()
            if timerId then api().timers.cancel(mine(), timerId) timerId = nil return end
            timerTicks = 0
            timerId = api().timers.every(mine(), { ms = 1000 }, function() timerTicks = timerTicks + 1 end)
        end },
        { T("Sy_Chunks"), function()
            if chunkId then api().chunks.unwatch(mine(), chunkId) chunkId = nil return end
            local x, y = Env.where()
            chunkLoads = 0
            chunkId = api().chunks.watch(mine(), { x = x - 64, y = y - 64, w = 128, h = 128 },
                function(_, kind) if kind == "load" then chunkLoads = chunkLoads + 1 end end)
        end },
        { T("Sy_Held"), function()
            local item = getPlayer():getPrimaryHandItem()
            if not item then ui.say(T("Sy_NoItem")) return end
            local f = api().formulas
            ui.say(T("Sy_Count", item:getFullType(), ui.num(api().items.count(getPlayer(), item:getFullType())),
                ui.num(f.weight(item), 2), ui.num(f.efficiency(item), 2)))
        end },
    })
    local caught = ui.lines(page, 9, 6, 0.85, 0.85, 0.7)
    page.refresh = function()
        local a = api()
        if not a then lines:set({ T("NoApi") }) return end
        local x, y, z = Env.where()
        local heli, target = "-", nil
        if a.helicopter then heli, target = a.helicopter.state() end
        local near = a.zombies and a.zombies.near(x, y, z, 30, 0) or 0
        lines:set({
            T("Sy_HeliNow", tostring(heli), tostring(target ~= nil)),
            T("Sy_Near", ui.num(near)),
            T("Sy_TimerNow", timerId and T("On") or T("Off"), ui.num(timerTicks)),
            T("Sy_ChunksNow", chunkId and T("On") or T("Off"), ui.num(chunkLoads)),
        })
        caught:set(events)
    end
    if Events.OnPZExtHelicopter then
        Events.OnPZExtHelicopter.Remove(onHeli)
        Events.OnPZExtHelicopter.Add(onHeli)
    end
end

-- ---- the section --------------------------------------------------------------------------------------------------

Dev.apiPages = {
    { id = "Env", title = T("Tab_Env"), build = envPage },
    { id = "Status", title = T("Tab_Status"), build = statusPage },
    { id = "Points", title = T("Tab_Points"), build = pointsPage },
    { id = "Buildings", title = T("Tab_Buildings"), build = buildingsPage },
    { id = "Text", title = T("Tab_Text"), build = textPage },
    { id = "Moodles", title = T("Tab_Moodles"), build = moodlesPage },
    { id = "Systems", title = T("Tab_Systems"), build = systemsPage },
}

Dev.section({ id = "API", title = T("Section_Api"), order = 10, pages = Dev.apiPages })
