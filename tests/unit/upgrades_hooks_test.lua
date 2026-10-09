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
    OA.Upgrades.Serums.slowInfection = function() calls = calls + 1 end
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

test("a tree opened is a title with the tree's line under it, or the banner without the API's text", function()
    local Hooks = loadHooks()
    local banners, called, halo = {}, {}, {}
    Hooks.banner = function(text) banners[#banners + 1] = text end
    local data = { OA_Id = "p1" }
    local character = { getModData = function() return data end, getPlayerNum = function() return 0 end }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return character end
    HaloTextHelper = { addText = function(_, t) halo[#halo + 1] = t end }
    PZToolsAPI = nil
    Hooks.treeOpened("p1", "scout")
    eq(#banners, 1)
    eq(banners[1], "IGUI_OA_Title_TreeOpened IGUI_OA_Tree_Name_scout<LINE>IGUI_OA_Tree_Event_scout")
    eq(#halo, 0, "the banner, not a text over the character")
    PZToolsAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            title = function(handle, spec) called[#called + 1] = spec end,
        },
    }
    Hooks.treeOpened("p1", "load")
    eq(#banners, 1, "no banner when the title is drawn")
    eq(called[1].text, "IGUI_OA_Title_TreeOpened IGUI_OA_Tree_Name_load")
    eq(called[1].subtitle, "IGUI_OA_Tree_Event_load")
    PZToolsAPI = nil
end)
