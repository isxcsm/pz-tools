-- The upgrades' clock wiring (client Upgrades/Hooks): the ten-minute refresh keeps to real time, the minute's
-- infection work does not. The game's UI classes are stand-ins: only the file's top level runs.
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
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or string.find(name, "^XpSystem/") or string.find(name, "^TimedActions/") then
            return true
        end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Hooks")
    require = real
    for _, name in ipairs(UI) do _G[name] = nil end
    if not ok then error(err, 0) end
    return OA.Upgrades.Hooks
end

test("fast-forwarded, the ten-minute refresh runs at most once each REFRESH_MS of real time", function()
    local Hooks = loadHooks()
    local refreshes = 0
    Hooks.refresh = function() refreshes = refreshes + 1 end
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
    HaloTextHelper = { addText = function(_, t) halo[#halo + 1] = t end }
    PZToolsAPI = nil
    Hooks.treeOpened("p1", "scout", true)
    eq(#banners, 1)
    eq(banners[1], "IGUI_OA_Title_TreeOpened IGUI_OA_Tree_Name_scout<LINE>IGUI_OA_Tree_GuideSent")
    eq(#halo, 0, "the banner, not a text over the character")
    PZToolsAPI = {
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
    eq(called[1].subtitle, "IGUI_OA_Tree_GuideSent")
    -- no memo (the story part is not there): nothing under the title
    Hooks.treeOpened("p1", "survival", false)
    eq(called[2].subtitle, nil)
    PZToolsAPI = nil
end)

test("the notices of an adaptation and a first effect are said over the head with their names", function()
    local Hooks = loadHooks()
    local banners, good, opened = {}, {}, {}
    Hooks.banner = function(text) banners[#banners + 1] = text end
    Hooks.treeOpened = function(id, tree, guide) opened[#opened + 1] = { tree, guide } end
    local data = { OA_Id = "p1" }
    local character = { getModData = function() return data end, getPlayerNum = function() return 0 end }
    getPlayer = function() return character end
    HaloTextHelper = { addGoodText = function(_, t) good[#good + 1] = t end, addBadText = function() end,
                       addText = function() end }
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_Adapted", args = { "scout", 2 } })
    -- (the test's getText adds a "nil" for each argument the call leaves out)
    local function said(text, prefix) return string.sub(text, 1, #prefix) == prefix end
    truthy(said(good[1], "IGUI_OA_Tree_Adapted IGUI_OA_Tree_Name_scout 2"), good[1])
    eq(#banners, 1, "the first point tells where the plan is made")
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_AdaptedShared", args = { 1 } })
    eq(#banners, 1, "once a character")
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_Opened", args = { "load", "guide" } })
    eq(#opened, 1)
    eq(opened[1][1], "load")
    eq(opened[1][2], true)
    eq(#good, 2, "an opening is a title, not a text over the head")
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_Opened", args = { "survival", "" } })
    eq(opened[2][2], false)
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_FirstEffect", args = { "sense", 1 } })
    truthy(said(good[3], "IGUI_OA_Tree_FirstEffect IGUI_OA_Tree_Node_sense_Name 1"), good[3])
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_FirstEffectSingle", args = { "dash", 1 } })
    truthy(said(good[4], "IGUI_OA_Tree_FirstEffectSingle IGUI_OA_Tree_Node_dash_Name 1"), good[4])
    OA.Sync.deliver("notice", "p1", { key = "IGUI_OA_Tree_GuideSent", args = {} })
    truthy(said(good[5], "IGUI_OA_Tree_GuideSent"), good[5])
end)
