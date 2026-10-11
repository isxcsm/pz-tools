-- The senses' jobs (client Upgrades/Senses) against the extension API: the zombie query asked for what the scan reads
-- (and the old scan when the API cannot), the building ledger's near containers picked by the squares the API gave,
-- the marks drawn through the quads call, and the shared timer (Pulse) on the API's timers. The game's UI classes are
-- stand-ins: only the file's top level and the jobs run.
require "OperationAcorn/Core"
local OA = OperationAcorn

local UI = { "ISPanel", "ISPanelJoypad", "ISButton", "ISToolTip", "ISToolTipInv", "ISModalDialog", "ISContextMenu",
    "ISCharacterInfoWindow", "ISWorldObjectContextMenu", "ISInventoryTransferAction", "ISInventoryPaneContextMenu",
    "ISBaseTimedAction" }

local function stubClass()
    local c = {}
    c.derive = function() return stubClass() end
    return setmetatable(c, { __index = function() return function() end end })
end

-- The game's panel for the elements made after loading (Senses' HUD): a table that records what it was told.
local NOOP = { initialise = true, instantiate = true, addToUIManager = true, backMost = true, setX = true, setY = true }
local function panelStandIn()
    ISPanel = { new = function(self, x, y, w, h)
        local o = setmetatable({ x = x, y = y, width = w, height = h }, { __index = function(t, k)
            local v = rawget(self, k)
            if v ~= nil then return v end
            if NOOP[k] then return function() end end
            return nil
        end })
        o.javaObject = { setConsumeMouseEvents = function() end }
        o.removeFromUIManager = function(el) el.removed = true end
        o.setVisible = function(el, v) el.visible = v end
        o.isVisible = function(el) return el.visible end
        return o
    end, derive = function() return {} end }
    UIFont = { Medium = "M", Small = "S" }
    getTextManager = function()
        return { getFontHeight = function() return 20 end, MeasureStringX = function(_, _, s) return #s * 8 end }
    end
    getPlayerScreenLeft = function() return 0 end
    getPlayerScreenTop = function() return 0 end
    getPlayerScreenWidth = function() return 1920 end
    getPlayerScreenHeight = function() return 1080 end
end

local function loadSenses()
    for _, name in ipairs(UI) do _G[name] = stubClass() end
    local font = UIFont
    UIFont = font or setmetatable({}, { __index = function() return 1 end })
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or string.find(name, "^XpSystem/") or string.find(name, "^TimedActions/") then
            return true
        end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Hooks")
    require = real
    UIFont = font
    for _, name in ipairs(UI) do _G[name] = nil end
    if not ok then error(err, 0) end
    panelStandIn()
    return OA.Upgrades.Senses
end

-- A record with the scout tree's nodes bought to `ranks` ({ sixth = 2, ... }); Client.record answers it.
local function recordWith(ranks)
    local Rules = OA.Upgrades.Rules
    local u = Rules.blank()
    for _ = 1, 26 do Rules.inject(u, "scout") end
    -- (bought in the order the tree allows, then only the wanted ranks kept)
    local order = { sight = 3, sixth = 2, alarm = 1, night = 3, rich = 3, ledger = 3, sense = 2, keen = 3, ammo = 2,
        sensePlus = 3 }
    for _, id in ipairs({ "sight", "sixth", "alarm", "night", "rich", "ledger", "sense", "keen", "ammo", "sensePlus" }) do
        for _ = 1, order[id] do
            local ok, why = Rules.buy(u, id, { fragments = 0 })
            if not ok then error("could not buy " .. id .. ": " .. tostring(why)) end
        end
    end
    for id in pairs(order) do u.ranks[id] = ranks[id] or 0 end
    local record = OA.Store.ensure("p", "P")
    record.upgrades = u
    OA.Client.record = function() return record end
    return record
end

local clock
local function advance(ms)
    clock = clock + ms
    TEST.fire("OnTick")
end

-- A zombie stand-in: what the old scan reads from it, counted.
local function zombie(x, y, z, extra)
    local reads = { alpha = 0, target = 0, state = 0 }
    local o = { reads = reads, x = x, y = y, z = z, alpha = 1, hasTarget = false, lunging = false }
    o.getX = function() return o.x end
    o.getY = function() return o.y end
    o.getZ = function() return o.z end
    o.isDead = function() return false end
    o.getTargetAlpha = function() reads.alpha = reads.alpha + 1 return o.alpha end
    o.getTarget = function() reads.target = reads.target + 1 return o.hasTarget and {} or nil end
    o.isCurrentState = function() reads.state = reads.state + 1 return o.lunging end
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

local function player(x, y, z)
    local p = { x = x, y = y, z = z, sneaking = true }
    p.getX = function() return p.x end
    p.getY = function() return p.y end
    p.getZ = function() return p.z end
    p.isDead = function() return false end
    p.isSneaking = function() return p.sneaking end
    p.isRunning = function() return false end
    p.isSprinting = function() return false end
    p.hasTrait = function() return false end
    p.getPlayerNum = function() return 0 end
    p.getCurrentSquare = function() return p.square end
    return p
end

local moodles
local function standIns()
    clock = 1000000
    getTimestampMs = function() return clock end
    moodles = {}
    getPlayer = function() return nil end
    OA.Upgrades.Moodles.set = function(id, level) moodles[id] = level end
    OA.Upgrades.First.report = function() end
    CharacterTrait = { DEAF = 1, KEEN_HEARING = 2, HARD_OF_HEARING = 3 }
    LungeState = { instance = function() return "lunge" end }
    AttackState = { instance = function() return "attack" end }
    HaloTextHelper = { addText = function() end, addGoodText = function() end, addBadText = function() end }
end

-- The API's zombie query over a list of stand-ins, as the real one answers an options table: the zombies of the level
-- asked for, written into options.into (the entries used again), with state, hunting and seen filled in.
local function nearApi(zombies, unseen)
    local log = { calls = {} }
    local api = { version = 1, client = function() return {} end }
    api.zombies = { near = function(x, y, z, radius, limit, opts)
        log.calls[#log.calls + 1] = { z = z, radius = radius, limit = limit, seenBy = opts and opts.seenBy,
            into = opts and opts.into }
        local out = opts and opts.into or {}
        local n = 0
        for _, zed in ipairs(zombies) do
            if math.floor(zed.z) == z then
                n = n + 1
                local e = out[n] or {}
                out[n] = e
                e.zombie, e.x, e.y, e.z, e.distance = zed, zed.x, zed.y, math.floor(zed.z), 1
                if opts then
                    e.state = zed.lunging and "LungeState" or "WalkState"
                    e.crawling = false
                    e.hunting = zed.hasTarget
                    e.seen = nil
                    if opts.seenBy then e.seen = not (unseen and unseen[zed]) end
                end
            end
        end
        for i = n + 1, #out do out[i] = nil end
        return n, out
    end }
    log.api = api
    return log
end

test("the zombie scan asks the API for each level with the player's sight, and reads no zombie but its height", function()
    local Senses = loadSenses()
    standIns()
    local closer, far = zombie(105, 100, 0), zombie(110, 100, 1)
    local hidden = zombie(103, 100, 0)
    local log = nearApi({ closer, far, hidden }, { [hidden] = true })
    PZToolsAPI = log.api
    recordWith({ sixth = 2 })
    local p = player(100, 100, 0.0)
    getPlayer = function() return p end
    OA.Upgrades.Pulse.enable(true)
    advance(0)
    eq(#log.calls, 3, "the floor and the ones beside it")
    eq(log.calls[1].z, -1); eq(log.calls[2].z, 0); eq(log.calls[3].z, 1)
    truthy(log.calls[2].seenBy == p, "the sixth sense asks for the player's sight")
    eq(log.calls[2].limit, 64)
    truthy(log.calls[2].into ~= nil and log.calls[1].into == log.calls[3].into, "one table, used again")
    eq(Senses.state.sixth, true, "a zombie the character does not see is near")
    eq(moodles.sixth, 1)
    eq(closer.reads.alpha + closer.reads.target + closer.reads.state, 0, "nothing is asked of a zombie the API described")
    -- everything seen: no hunch
    PZToolsAPI = nearApi({ closer, far }, {}).api
    advance(600)
    eq(Senses.state.sixth, false)
    eq(moodles.sixth, 0)
    PZToolsAPI = nil
    OA.Upgrades.Pulse.enable(false)
end)

test("a zombie the API says is lunging is heard striking, one that has a target is heard coming", function()
    local Senses = loadSenses()
    standIns()
    local z = zombie(103, 100, 0)
    local log = nearApi({ z }, {})
    PZToolsAPI = log.api
    recordWith({ sense = 2, sensePlus = 3 })
    local p = player(100, 100, 0)
    getPlayer = function() return p end
    OA.Upgrades.Pulse.enable(true)
    advance(0)
    eq(#Senses.state.zombies, 0, "newly in reach: nothing yet")
    eq(log.calls[2].seenBy, nil, "the sight is not asked for without the sixth sense")
    z.hasTarget = true
    advance(600)
    eq(Senses.state.zombies[1] and Senses.state.zombies[1].kind, "aggro", "a target taken")
    z.lunging = true
    advance(600)
    local kinds = {}
    for _, m in ipairs(Senses.state.zombies) do kinds[m.kind] = true end
    truthy(kinds.attack, "a lunge")
    PZToolsAPI = nil
    OA.Upgrades.Pulse.enable(false)
end)

test("an API from before the zombie options, or a failing one, leaves the old scan of the zombie list", function()
    local Senses = loadSenses()
    standIns()
    local unseen = zombie(103, 100, 0, { alpha = 0 })
    -- an API whose near ignores the options: it answers a new table
    PZToolsAPI = { version = 1, client = function() return {} end, zombies = { near = function() return 0, {} end } }
    getCell = function()
        return { getZombieList = function() return { size = function() return 1 end, get = function() return unseen end } end }
    end
    recordWith({ sixth = 2 })
    local p = player(100, 100, 0)
    getPlayer = function() return p end
    OA.Upgrades.Pulse.enable(true)
    advance(0)
    eq(Senses.state.sixth, true, "found by the old scan")
    truthy(unseen.reads.alpha > 0, "its sight asked of the zombie")
    unseen.alpha = 1
    PZToolsAPI.zombies.near = function() error("boom") end
    advance(600)
    eq(Senses.state.sixth, false, "a failing call: the old scan again")
    PZToolsAPI = nil
    OA.Upgrades.Pulse.enable(false)
end)

-- ---- the ledger: the unopened containers near the character ----------------------------------------------------

local function container(x, y, z)
    local c = { parentReads = 0 }
    local explored = false
    local object = { outlined = false }
    object.hasModData = function() return explored end
    object.getModData = function() return { OA_Searched = explored or nil } end
    local square = { getX = function() return x end, getY = function() return y end, getZ = function() return z end,
        isCouldSee = function() return true end }
    object.getSquare = function() return square end
    object.setOutlineHighlightCol = function() end
    object.setOutlineHighlight = function(_, _, on) object.outlined = on end
    c.getParent = function() c.parentReads = c.parentReads + 1 return object end
    c.isExplored = function() return explored end
    c.open = function() explored = true end
    c.object = object
    return c
end

test("the ledger outlines the unopened containers near the character, and asks about no others", function()
    local Senses = loadSenses()
    standIns()
    local nearBox = container(103, 100, 0)
    local farBox = container(130, 100, 0)
    local upstairs = container(102, 100, 1)
    local entries = { { c = nearBox, x = 103, y = 100, z = 0 }, { c = farBox, x = 130, y = 100, z = 0 },
        { c = upstairs, x = 102, y = 100, z = 1 } }
    local calls = 0
    PZToolsAPI = { version = 1, client = function() return {} end, buildings = {
        at = function() return { key = "house", playerBuilt = false } end,
        containers = function(key, opts)
            calls = calls + 1
            local out, n, opened = opts.into or {}, 0, 0
            for _, e in ipairs(entries) do
                if not opts.since or e.c.isExplored() then
                    out[n + 1], out[n + 2], out[n + 3], out[n + 4] = e.c, e.x, e.y, e.z
                    out[n + 5], out[n + 6], out[n + 7] = "shelves", 1, e.c.isExplored()
                    n = n + 7
                end
                if e.c.isExplored() then opened = opened + 1 end
            end
            for i = n + 1, #out do out[i] = nil end
            return out, true, calls, #entries, opened
        end } }
    OA.Buildings.reset()
    recordWith({ ledger = 3 })
    local p = player(100, 100, 0.0)
    p.square = { getRoom = function() return {} end, getX = function() return 100 end, getY = function() return 100 end,
        getZ = function() return 0 end }
    getPlayer = function() return p end
    OA.Buildings.tick(p)
    eq(Senses.ledgerOutline(p), true, "rank 2 and more keeps outlines")
    eq(nearBox.object.outlined, true, "a near unopened container is outlined")
    eq(farBox.object.outlined, false)
    eq(farBox.parentReads, 0, "a far one is not asked about")
    eq(upstairs.parentReads, 0, "nor one on another floor")
    -- opened: the outline goes with the look the mark makes
    nearBox.open()
    OA.Buildings.tick(p)
    Senses.ledgerOutline(p)
    eq(nearBox.object.outlined, false)
    Senses.ledgerLeave()
    PZToolsAPI = nil
end)

test("the ledger tells on entering how much is left, then a floor's further stage as a line for the watch", function()
    local Senses = loadSenses()
    standIns()
    recordWith({ ledger = 1 })
    local said = {}
    local p = player(100, 100, 0.0)
    p.Say = function(_, text) said[#said + 1] = text end
    local text, floor = getText, OA.Buildings.floor
    getText = function(key) return key end
    local floors = { left = 12, total = 12 }
    OA.Buildings.floor = function() return floors.left, floors.total end
    Senses.ledgerLeave()
    eq(Senses.ledgerLook(p, "house", 0, 12, true, 1000), nil)
    eq(said[1], "IGUI_OA_Tree_LedgerUntouched", "told on entering")
    floors.left = 6
    eq(Senses.ledgerLook(p, "house", 6, 12, true, 2000), "IGUI_OA_Tree_LedgerSome", "a further stage: a line, not said")
    eq(#said, 1)
    eq(Senses.ledgerLook(p, "house", 6, 12, true, 2500), nil, "the same stage once")
    eq(Senses.ledgerSay(p, "IGUI_OA_Tree_LedgerSome", 5000), false, "within the gap of the line on entering")
    eq(Senses.ledgerSay(p, "IGUI_OA_Tree_LedgerSome", 11000), true)
    eq(said[2], "IGUI_OA_Tree_LedgerSome")
    -- the floor done: said whatever was said just before
    floors.left = 0
    eq(Senses.ledgerLook(p, "house", 12, 24, true, 11500), "IGUI_OA_Tree_LedgerFloorDone")
    eq(Senses.ledgerSay(p, "IGUI_OA_Tree_LedgerFloorDone", 11600), true, "within the gap, yet said")
    eq(said[3], "IGUI_OA_Tree_LedgerFloorDone")
    -- another floor, all searched: said on coming onto it; one not all searched: nothing
    p.z = 1
    Senses.ledgerFloor(p, 12000)
    eq(said[4], "IGUI_OA_Tree_LedgerFloorDone")
    floors.left = 3
    Senses.ledgerFloor(p, 12500)
    eq(#said, 4)
    -- the building all searched: its own line, once, and no floor's after it
    Senses.ledgerDone(p, 13000)
    eq(said[5], "IGUI_OA_Tree_LedgerAlreadyDone")
    Senses.ledgerDone(p, 13100)
    floors.left = 0
    Senses.ledgerFloor(p, 13200)
    eq(#said, 5)
    recordWith({ ledger = 0 })
    eq(Senses.ledgerLook(p, "other", 0, 3, true, 20000), nil, "no rank, no lines")
    eq(#said, 5)
    getText, OA.Buildings.floor = text, floor
end)

-- ---- the marks through the quads call ---------------------------------------------------------------------------

test("a mark is drawn as one call of two quads through the API, the same numbers DrawTexture takes", function()
    local Senses = loadSenses()
    standIns()
    local S = Senses.state
    local plain = {}
    local ui = { DrawTexture = function(_, tex, ...) plain[#plain + 1] = { ... } end }
    local tex = { getWidth = function() return 100 end, getHeight = function() return 50 end }
    getTexture = function() return tex end
    isoToScreenX = function(_, x, y, z) return (x - y) * 32 end
    isoToScreenY = function(_, x, y, z) return (x + y) * 16 - z * 96 end
    local p = player(100, 100, 0)
    getSpecificPlayer = function() return p end
    S.ring, S.distance, S.extended = true, true, false
    S.zombies = { { kind = "zombie", x = 104, y = 100, z = 0, born = 0, untilMs = 1000000000 } }
    S.sounds = {}
    clock = 500
    local hud = ISOASenseHud:new(0)
    hud.javaObject = ui
    hud.playerNum = 0
    PZToolsAPI = nil
    ISOASenseHud.render(hud)
    truthy(#plain >= 2, "drawn one by one without the API")
    local quads = {}
    PZToolsAPI = { version = 1, client = function() return {} end, draw = { quads = function(el, texture, list, count)
        quads[#quads + 1] = { el = el, tex = texture, count = count, list = { unpack(list, 1, count * 12) } }
    end } }
    ISOASenseHud.render(hud)
    eq(#quads * 2, #plain, "each pair of DrawTexture calls is one call of two quads")
    for i, q in ipairs(quads) do
        truthy(q.el == ui and q.tex == tex)
        eq(q.count, 2)
        for k = 1, 12 do
            near(q.list[k], plain[2 * i - 1][k], 1e-9, "shade number " .. k)
            near(q.list[12 + k], plain[2 * i][k], 1e-9, "picture number " .. k)
        end
    end
    -- a call that fails: told once, and the marks are drawn one by one from then on
    PZToolsAPI.draw.quads = function() error("bad number") end
    plain = {}
    ISOASenseHud.render(hud)
    local tried = 0
    PZToolsAPI.draw.quads = function() tried = tried + 1 end
    plain = {}
    ISOASenseHud.render(hud)
    truthy(#plain >= 2, "one by one after the failure")
    eq(tried, 0, "the API's call is not tried again")
    PZToolsAPI = nil
end)

-- ---- the shared timer on the API's timers ----------------------------------------------------------------------

-- The API's timers over a list: every(handle, spec, fn) -> id; cancel(handle, id); and a way to run what is due.
local function timersApi()
    local t = { list = {}, next = 1 }
    local api = { version = 1, client = function() return "h" end }
    api.timers = {
        every = function(handle, spec, fn)
            local id = t.next
            t.next = t.next + 1
            t.list[id] = { spec = spec, fn = fn }
            return id
        end,
        cancel = function(handle, id)
            local had = t.list[id] ~= nil
            t.list[id] = nil
            return had
        end,
    }
    t.api = api
    t.count = function()
        local n = 0
        for _ in pairs(t.list) do n = n + 1 end
        return n
    end
    -- runs the timers of a period (a once timer is dropped as it is called)
    t.fire = function(period)
        local due = {}
        for id, e in pairs(t.list) do
            if e.spec.ms == period then due[#due + 1] = id end
        end
        for _, id in ipairs(due) do
            local e = t.list[id]
            if e.spec.once then t.list[id] = nil end
            e.fn(id, 1)
        end
    end
    return t
end

test("with the API's timers each job is a timer of its period, the first run comes at once, and off cancels them", function()
    loadSenses()
    standIns()
    local t = timersApi()
    PZToolsAPI = t.api
    local ran = {}
    local Pulse = OA.Upgrades.Pulse
    Pulse.job("probe", 700, function(now) ran[#ran + 1] = now end)
    local ticks = 0
    local add = Events.OnTick.Add
    Events.OnTick.Add = function(fn) ticks = ticks + 1 add(fn) end
    Pulse.enable(true)
    eq(ticks, 0, "no handler on the ticks")
    eq(Pulse.enabled(), true)
    local periods = {}
    for _, e in pairs(t.list) do
        if not e.spec.once then periods[e.spec.ms] = (periods[e.spec.ms] or 0) + 1 end
    end
    eq(periods[500], 1, "the senses look twice a second (the ledger is the search watch's, on the loot window)")
    eq(periods[1000], 1)
    eq(periods[250], 1)
    eq(periods[700], 1)
    local before = t.count()
    Pulse.enable(true)
    eq(t.count(), before, "turned on again: the same timers")
    t.fire(1)
    eq(#ran, 1, "the first run of every job, at the next frame")
    t.fire(700)
    eq(#ran, 2)
    Pulse.enable(false)
    eq(t.count(), 0, "off: no timer left")
    eq(Pulse.enabled(), false)
    -- leaving the world drops the timers: the next game's Pulse.enable makes them again
    Pulse.enable(true)
    eq(t.count() > 0, true)
    t.list = {}
    TEST.fire("OnGameStart")
    Pulse.enable(true)
    truthy(t.count() >= 5, "made again for the new world")
    Pulse.enable(false)
    PZToolsAPI = nil
end)

test("without the API's timers the jobs run on one OnTick handler, as before", function()
    loadSenses()
    standIns()
    PZToolsAPI = nil
    local Pulse = OA.Upgrades.Pulse
    local ran = 0
    Pulse.job("probe2", 700, function() ran = ran + 1 end)
    Pulse.enable(true)
    advance(0)
    eq(ran, 1, "due at once")
    advance(300)
    eq(ran, 1)
    advance(500)
    eq(ran, 2)
    Pulse.enable(false)
end)
