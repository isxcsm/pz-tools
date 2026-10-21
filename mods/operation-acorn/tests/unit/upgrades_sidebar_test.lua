-- The sidebar heart (client/Upgrades/Sidebar): it beats while points came, or a capstone was unsealed, that the
-- adaptation tab has not been seen with; its tooltip has a line for each.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Upgrades/Api"
local OA = OperationAcorn
local Rules = OA.Upgrades.Rules

local md, el, u, onScreen

local function load()
    md, onScreen = {}, false
    local record = OA.Store.ensure("sidebar1", "S")
    u = Rules.section(record)
    local player = { getModData = function() return md end }
    getSpecificPlayer = function() return player end
    getNumActivePlayers = function() return 1 end
    el = { playerNum = 0, healthBtn = {}, mouseOverList = { { displayString = "Health" } } }
    el.mouseOverList[1].object = el.healthBtn
    getPlayerData = function() return { equipped = el } end
    ISEquippedItem = { render = function() end, onOptionMouseDown = function() end }
    OA.Trade = OA.Trade or {}
    OA.Trade.UI = OA.Trade.UI or {}
    OA.Trade.UI.live = function(target) target.oaLive = (target.oaLive or 0) + 1 end
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") or name == "OperationAcorn/Trade/UI" then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Upgrades/Sidebar")
    require = real
    if not ok then error(err, 0) end
    OA.Upgrades.Window = { onScreen = function() return onScreen end }
    OA.Client.record = function() return record end
    return OA.Upgrades.Sidebar
end

test("a capstone unsealed lights the heart as points do, each with its own line, until the tab is seen", function()
    local Sidebar = load()
    Sidebar.update(0)
    eq(el.oaFresh, false)
    Rules.unseal(u, "scout")
    Sidebar.update(0)
    eq(el.oaFresh, true, "unsealed: it beats")
    eq(el.oaLive, 1)
    eq(el.mouseOverList[1].displayString, "Health <LINE> IGUI_OA_Tree_HeartTipOpen")
    u.sharedInjected = (u.sharedInjected or 0) + 1
    Sidebar.update(0)
    eq(el.mouseOverList[1].displayString, "Health <LINE> IGUI_OA_Tree_HeartTip <LINE> IGUI_OA_Tree_HeartTipOpen")
    eq(el.oaLive, 1, "beating already: not started again")
    onScreen = true
    Sidebar.seen(0)
    eq(el.oaFresh, false, "the tab seen")
    eq(el.mouseOverList[1].displayString, "Health")
    onScreen = false
    Sidebar.update(0)
    eq(el.oaFresh, false, "nothing new")
end)
