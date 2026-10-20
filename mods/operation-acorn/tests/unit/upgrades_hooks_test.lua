-- The upgrades' clock wiring (client Upgrades/Hooks): the ten-minute refresh keeps to real time, the minute's
-- infection work does not; the banner, the senses' marks and the moodles' stand-ins are drawn on time with PZ
-- Optimization's retained UI. The game's UI classes are stand-ins: only the file's top level runs.
require "OperationAcorn/Core"
local OA = OperationAcorn

local UI = { "ISPanel", "ISPanelJoypad", "ISButton", "ISToolTip", "ISToolTipInv", "ISModalDialog", "ISContextMenu",
    "ISCharacterInfoWindow", "ISWorldObjectContextMenu", "ISInventoryTransferAction", "ISInventoryPaneContextMenu",
    "ISBaseTimedAction" }

-- A UI class whose members are all functions that do nothing, and whose derived classes are the same.
local function stubClass()
    local c = {}
    c.derive = function() return stubClass() end
    return setmetatable(c, { __index = function() return function() end end })
end

-- Loads Hooks with the UI stand-ins (the game's own files are not here), then takes them away again.
local function loadHooks()
    for _, name in ipairs(UI) do _G[name] = stubClass() end
    -- the research tab draws with the terminal's helpers (Trade/UI), whose palettes name the game's fonts
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
    return OA.Upgrades.Hooks
end

test("fast-forwarded, the ten-minute refresh runs at most once each REFRESH_MS of real time", function()
    local Hooks = loadHooks()
    local refreshes = 0
    Hooks.refresh = function() refreshes = refreshes + 1 end
    getPlayer = function() return nil end
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    TEST.fire("EveryTenMinutes")
    eq(refreshes, 1)
    -- x40: ten game minutes some 0.6 s apart
    for _ = 1, 8 do
        clock = clock + 600
        TEST.fire("EveryTenMinutes")
    end
    eq(refreshes, 1, "none within REFRESH_MS")
    clock = clock + Hooks.REFRESH_MS
    TEST.fire("EveryTenMinutes")
    eq(refreshes, 2)
    truthy(Hooks.REFRESH_MS < 25000, "the default speed (25 s for ten game minutes) refreshes every time")
end)

test("the minute's infection work runs every game minute, whatever the real time", function()
    loadHooks()
    local calls = 0
    OA.Upgrades.Watch.minute = function() calls = calls + 1 end
    local before = getPlayer
    getPlayer = function() return { isDead = function() return false end } end
    OA.Client.record = function() return OA.Store.ensure("p", "P") end
    getTimestampMs = function() return 1760000000000 end
    local ok, err = pcall(function()
        for _ = 1, 5 do TEST.fire("EveryOneMinute") end
    end)
    getPlayer = before
    if not ok then error(err, 0) end
    eq(calls, 5)
end)

test("a tree opened is a title with the folder line under it when a memo came, or the banner without the API's text", function()
    local Hooks = loadHooks()
    local banners, called, halo = {}, {}, {}
    Hooks.banner = function(text) banners[#banners + 1] = text end
    local data = { OA_Id = "p1" }
    local character = { getModData = function() return data end, getPlayerNum = function() return 0 end }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return character end
    character.Say = function(_, t) halo[#halo + 1] = t end
    PZExtAPI = nil
    Hooks.treeOpened("p1", "scout", true, 2)
    eq(#banners, 1)
    eq(banners[1], "IGUI_OA_Title_TreeOpened IGUI_OA_Tree_Name_scout<LINE>IGUI_OA_Title_OpenedSubGuide 2")
    eq(#halo, 0, "the banner, not a line said")
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            title = function(handle, spec) called[#called + 1] = spec end,
        },
    }
    Hooks.treeOpened("p1", "load", true)
    eq(#banners, 1, "no banner when the title is drawn")
    eq(called[1].text, "IGUI_OA_Title_TreeOpened IGUI_OA_Tree_Name_load")
    eq(called[1].subtitle, "IGUI_OA_Title_OpenedSubGuide 1", "the points under it, and the memo")
    -- no memo (the story part is not there): only the points under the title
    Hooks.treeOpened("p1", "survival", false, 3)
    eq(called[2].subtitle, "IGUI_OA_Title_OpenedSub 3")
    PZExtAPI = nil
end)

test("points that came are a brief title (doses are many), an opening a title of its own; a first effect is a brief title", function()
    local Hooks = loadHooks()
    local banners, good, opened = {}, {}, {}
    Hooks.banner = function(text) banners[#banners + 1] = text end
    Hooks.treeOpened = function(id, tree, guide, points) opened[#opened + 1] = { tree, guide, points } end
    local data = { OA_Id = "p1" }
    local character = { getModData = function() return data end, getPlayerNum = function() return 0 end }
    getPlayer = function() return character end
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return character end
    character.Say = function(_, t) good[#good + 1] = t end
    HaloTextHelper = nil
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_Adapted", args = { "scout", 2 } })
    -- (the test's getText adds a "nil" for each argument the call leaves out; without the API's text a title is
    -- said by the character: its title, then its line)
    local function said(text, prefix) return string.sub(text, 1, #prefix) == prefix end
    truthy(said(good[1], "IGUI_OA_Tree_Adapted IGUI_OA_Tree_Name_scout 2"), good[1])
    truthy(said(good[2], "IGUI_OA_Tree_WhereHint"), "the first point tells where the plan is made, after its title")
    eq(#banners, 0, "a brief title, not the banner")
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_AdaptedShared", args = { 1 } })
    eq(#good, 3, "once a character")
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_Opened", args = { "load", "guide", 2 } })
    eq(#opened, 1)
    eq(opened[1][1], "load")
    eq(opened[1][2], true)
    eq(opened[1][3], 2, "its points with it")
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_Opened", args = { "survival", "" } })
    eq(opened[2][2], false)
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_FirstEffect", args = { "sense", 1 } })
    truthy(said(good[4], "IGUI_OA_Tree_FirstEffect IGUI_OA_Tree_Node_sense_Name 1"), good[4])
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_FirstEffectSingle", args = { "dash", 1 } })
    truthy(said(good[5], "IGUI_OA_Tree_FirstEffectSingle IGUI_OA_Tree_Node_dash_Name 1"), good[5])
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_GuideSent", args = {} })
    truthy(said(good[6], "IGUI_OA_Tree_GuideSent"), good[6])
end)

-- ---- with PZ Optimization's retained UI (Trade/UI live) ------------------------------------------------------------

-- The game's panel for the elements made after loading: a table that records being taken off and shown. Its class's
-- own methods are the file's; the stand-in class answers any other name with a function, so only the calls the
-- elements make are given here.
local made
local NOOP = { initialise = true, instantiate = true, addToUIManager = true, backMost = true }
local function panelStandIn()
    made = {}
    ISPanel = { new = function(self, x, y, w, h)
        local o = setmetatable({ x = x, y = y, width = w, height = h, visible = true }, { __index = function(_, k)
            local v = rawget(self, k)
            if v ~= nil then return v end
            if NOOP[k] then return function() end end
            return nil
        end })
        o.javaObject = { setConsumeMouseEvents = function() end }
        o.removeFromUIManager = function(el) el.removed = true end
        o.setVisible = function(el, v) el.visible = v end
        o.isVisible = function(el) return el.visible end
        made[#made + 1] = o
        return o
    end }
    UIFont = { Medium = "M", Small = "S" }
    getTextManager = function()
        return { getFontHeight = function() return 20 end, MeasureStringX = function(_, _, s) return #s * 8 end }
    end
    getPlayerScreenLeft = function() return 0 end
    getPlayerScreenTop = function() return 0 end
    getPlayerScreenWidth = function() return 1920 end
    getPlayerScreenHeight = function() return 1080 end
end

test("the banner is followed each frame before the UI draws: it holds still, fades on time and goes at its end", function()
    local Hooks = loadHooks()
    panelStandIn()
    local UI = OA.Trade.UI
    local now = 5000000
    getTimestampMs = function() return now end
    UI.sceneNow = function() return now end
    Hooks.banner("one<LINE>two")
    local banner = made[1]
    UI.liveFrame()
    eq(banner.liveLook, 0, "holding still")
    now = now + ISOABanner.LIFETIME - ISOABanner.FADE - 10
    UI.liveFrame()
    eq(banner.liveLook, 0, "still: nothing to draw afresh")
    now = now + 20
    UI.liveFrame()
    eq(banner.liveLook, ISOABanner.LIFETIME - ISOABanner.FADE + 10, "the fade starts on time")
    now = now + 100
    UI.liveFrame()
    eq(banner.liveLook, ISOABanner.LIFETIME - ISOABanner.FADE + 110, "and moves each frame")
    now = banner.born + ISOABanner.LIFETIME
    UI.liveFrame()
    eq(banner.removed, true, "taken off at its end, with no frame drawn")
    eq(banner.liveLook, nil, "and let go")
    -- one taken over by the next is let go
    Hooks.banner("a")
    Hooks.banner("b")
    local first, second = made[2], made[3]
    UI.liveFrame()
    eq(first.removed, true)
    eq(first.liveLook, nil)
    eq(second.liveLook, 0)
end)

test("a banner stands still while the game is paused (the scene clock)", function()
    local Hooks = loadHooks()
    panelStandIn()
    local UI = OA.Trade.UI
    local now, paused = 7000000, false
    getTimestampMs = function() return now end
    isGamePaused = function() return paused end
    Hooks.banner("one")
    local banner = made[1]
    now = now + ISOABanner.LIFETIME - ISOABanner.FADE + 100
    UI.liveFrame()
    eq(banner.liveLook, ISOABanner.LIFETIME - ISOABanner.FADE + 100, "fading")
    paused = true
    UI.liveFrame()
    now = now + 60000
    UI.liveFrame()
    eq(banner.liveLook, ISOABanner.LIFETIME - ISOABanner.FADE + 100, "a minute paused: still where it was")
    eq(banner.removed, nil)
    paused = false
    UI.liveFrame()
    now = now + 50
    UI.liveFrame()
    eq(banner.liveLook, ISOABanner.LIFETIME - ISOABanner.FADE + 150, "and on from there")
    isGamePaused = nil
end)

test("the senses' marks are drawn every frame while one shows, and held still with none", function()
    loadHooks()
    local S = OA.Upgrades.Senses.state
    local tick = ISOASenseHud.tick
    eq(tick(nil, 1000), 0, "nothing heard")
    S.ring = true
    S.zombies = { { born = 900, untilMs = 3000 } }
    eq(tick(nil, 1000), 1000, "a cue on show: every frame")
    eq(tick(nil, 1016), 1016)
    eq(tick(nil, 3000), 0, "run out (still in the list until the next sound): held still")
    S.sounds = { { born = 2900, untilMs = 5000 } }
    eq(tick(nil, 3000), 3000, "a new noise shows at once")
    S.ring = false
    eq(tick(nil, 3016), 0, "the sense off: its cues are not drawn")
end)

test("the moodles' stand-ins follow their levels and the mouse, though the element is one pixel", function()
    loadHooks()
    panelStandIn()
    local Moodles = OA.Upgrades.Moodles
    local UI = OA.Trade.UI
    getCore = function()
        return { getOptionMoodleSize = function() return 1 end, getScreenHeight = function() return 1080 end }
    end
    UIManager = { getMoodleUI = function()
        return { getX = function() return 1800 end, getY = function() return 100 end }
    end }
    local mx, my = 0, 0
    getMouseX = function() return mx end
    getMouseY = function() return my end
    Moodles.set("sixth", 2)
    local panel = made[1]
    truthy(panel and panel.visible, "the stand-ins show")
    local rev = panel.rev
    truthy(rev, "a level written to the panel")
    UI.liveFrame()
    eq(panel.liveLook, 0, "the mouse over none")
    -- 32 px moodles, 6 px left of the column at (1800, 100), 4 px apart
    mx, my = 1770, 110
    UI.liveFrame()
    eq(panel.liveLook, 1, "over the first: drawn afresh for its tooltip")
    eq(panel.hover, 1)
    Moodles.set("untested", 1)
    truthy(panel.rev > rev, "another level: written to the panel")
    my = 140
    UI.liveFrame()
    eq(panel.liveLook, 2, "over the second")
    Moodles.set("sixth", 0)
    UI.liveFrame()
    eq(panel.liveLook, 0, "the second moved up: the mouse is over none")
    Moodles.set("untested", 0)
    eq(panel.visible, false)
    UI.liveFrame()
    eq(panel.liveLook, 0, "none shows: hidden, it waits")
    Moodles.set("sixth", 1)
    UI.liveFrame()
    eq(panel.liveLook, 0, "shown again: followed again")
end)

test("the ten-minute clock refreshes only when the bite shield's rest ends or begins, or nothing is declared yet", function()
    local Hooks = loadHooks()
    local Effects, Rules = OA.Upgrades.Effects, OA.Upgrades.Rules
    local refreshes = 0
    Hooks.refresh = function() refreshes = refreshes + 1 end
    PZExtAPI = { version = OA.API_VERSION, client = function() return "handle" end,
        formulas = { set = function() end, points = function() return {} end } }
    CharacterTrait = {}
    local record = OA.Store.ensure("p", "P")
    getPlayer = function() return { hasTrait = function() return false end, getVariableString = function() return "" end } end
    OA.Client.record = function() return record end
    local u = Rules.section(record)
    u.ranks.resistPlus = 2
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    local function tick()
        clock = clock + Hooks.REFRESH_MS
        TEST.fire("EveryTenMinutes")
    end
    Effects.reset()
    tick()
    eq(refreshes, 1, "nothing declared yet (no API at the start): refreshed")
    Effects.apply(record)
    tick()
    eq(refreshes, 1, "declared armed, still armed: not refreshed")
    u.biteAt = OA.hours()
    tick()
    eq(refreshes, 2, "the shield rests now: the point must be cleared")
    Effects.apply(record)
    tick()
    tick()
    eq(refreshes, 2, "resting as declared: not refreshed")
    TEST.hours = TEST.hours + Rules.biteHours(u) + 1
    tick()
    eq(refreshes, 3, "the rest has ended: the point must be declared")
    Effects.apply(record)
    tick()
    eq(refreshes, 3)
    PZExtAPI = nil
end)

test("the ten-minute clock also refreshes when an input of the values besides the record changed", function()
    local Hooks = loadHooks()
    local Effects, Rules = OA.Upgrades.Effects, OA.Upgrades.Rules
    local refreshes = 0
    Hooks.refresh = function() refreshes = refreshes + 1 end
    PZExtAPI = { version = OA.API_VERSION, client = function() return "handle" end,
        formulas = { set = function() end, points = function() return {} end } }
    CharacterTrait = { NIGHT_VISION = "NV", EAGLE_EYED = "EE" }
    local traits, variable = {}, ""
    local record = OA.Store.ensure("p", "P")
    getPlayer = function()
        return { hasTrait = function(_, t) return traits[t] == true end, getVariableString = function() return variable end }
    end
    OA.Client.record = function() return record end
    local u = Rules.section(record)
    local clock = 1760000000000
    getTimestampMs = function() return clock end
    local function tick()
        clock = clock + Hooks.REFRESH_MS
        TEST.fire("EveryTenMinutes")
    end
    Effects.reset()
    Effects.apply(record)
    tick()
    eq(refreshes, 0, "declared, nothing moved: not refreshed")
    SandboxVars.OperationAcorn.HiddenZombieFix = not SandboxVars.OperationAcorn.HiddenZombieFix
    tick()
    eq(refreshes, 1, "the hidden zombie fix option changed")
    Effects.apply(record)
    tick()
    eq(refreshes, 1, "declared again with it")
    traits.NV = true
    tick()
    eq(refreshes, 2, "Night Vision given")
    Effects.apply(record)
    traits.EE = true
    tick()
    eq(refreshes, 3, "Eagle Eyed given")
    Effects.apply(record)
    tick()
    eq(refreshes, 3)
    u.ranks.fall = 1
    tick()
    eq(refreshes, 4, "the landing variable is not what the record's rank says (the game cleared it)")
    variable = "1"
    tick()
    eq(refreshes, 4, "as it says")
    SandboxVars.OperationAcorn.HiddenZombieFix = not SandboxVars.OperationAcorn.HiddenZombieFix
    PZExtAPI = nil
end)
