-- What the mod draws on the maps (client Story/Maps): a ring's and a way's dashes go to the extension API's quads call
-- as one list, the same quads DrawTexture would take, and one by one without it. The game's map classes are stand-ins.
require "OperationAcorn/Core"
local OA = OperationAcorn

local UI = { "ISPanel", "ISPanelJoypad", "ISButton", "ISToolTip", "ISToolTipInv", "ISModalDialog", "ISContextMenu",
    "ISScrollingListBox", "ISCollapsableWindow" }

local function stubClass()
    local c = {}
    c.derive = function() return stubClass() end
    return setmetatable(c, { __index = function() return function() end end })
end

local function loadMaps()
    for _, name in ipairs(UI) do _G[name] = stubClass() end
    UIFont = setmetatable({}, { __index = function(_, k) return k end })
    getTextManager = function()
        return setmetatable({}, { __index = function() return function() return 16 end end })
    end
    ISWorldMap = { prerender = function() end, ShowWorldMap = function() end }
    ISMiniMapInner = { prerender = function() end, instantiate = function() end }
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "OperationAcorn/Story/Maps")
    require = real
    if not ok then error(err, 0) end
    return OA.StoryMaps
end

-- A world map element over a flat view (100 pixels a square both ways), with a Java object that records DrawTexture.
local function mapElement(drawn)
    local api = {
        worldToUIX = function(_, x, y) return x * 2 end,
        worldToUIY = function(_, x, y) return y * 2 end,
    }
    local el = { mapAPI = api, playerNum = 0, width = 1000, height = 800 }
    el.getAbsoluteX = function() return 10 end
    el.getAbsoluteY = function() return 20 end
    el.javaObject = { DrawTexture = function(_, tex, ...) drawn[#drawn + 1] = { tex.path, ... } end }
    return el
end

local function setup()
    local Maps = loadMaps()
    getTexture = function(path) return { path = path, getWidth = function() return 8 end, getHeight = function() return 8 end } end
    local record = OA.Store.ensure("p", "P")
    record.missions = { active = { id = "M1", kind = "regular", state = "open", area = { x = 100, y = 100, r = 40 } } }
    local player = { getX = function() return 60 end, getY = function() return 70 end,
        getModData = function() return { OA_Id = "p" } end }
    getSpecificPlayer = function() return player end
    getNumActivePlayers = function() return 1 end
    getTimestampMs = function() return 5000000 end
    Maps.refresh()
    return Maps
end

local function dashes(drawn)
    local list = {}
    for _, d in ipairs(drawn) do
        if d[1] == "media/textures/OA_Map_Dash.png" then list[#list + 1] = d end
    end
    return list
end

test("a ring's and a way's dashes are one call of quads through the API, the numbers DrawTexture takes", function()
    setup()
    local plain = {}
    ISWorldMap.prerender(mapElement(plain))
    local expected = dashes(plain)
    truthy(#expected > 10, "a ring of dashes and the way")
    local drawn, calls, lists = {}, 0, {}
    PZToolsAPI = { version = 1, client = function() return {} end, draw = { quads = function(el, tex, list, count)
        calls = calls + 1
        lists[#lists + 1] = { tex = tex.path, count = count, list = { unpack(list, 1, count * 12) } }
    end } }
    local el = mapElement(drawn)
    ISWorldMap.prerender(el)
    PZToolsAPI = nil
    eq(#dashes(drawn), 0, "no dash by DrawTexture")
    local all = {}
    for _, l in ipairs(lists) do
        eq(l.tex, "media/textures/OA_Map_Dash.png")
        for i = 0, l.count - 1 do
            local q = {}
            for k = 1, 12 do q[k] = l.list[i * 12 + k] end
            all[#all + 1] = q
        end
    end
    eq(#all, #expected)
    for i, q in ipairs(all) do
        for k = 1, 12 do near(q[k], expected[i][k + 1], 1e-9, "dash " .. i .. " number " .. k) end
    end
    truthy(calls <= 4, "a call for the ring and one for the way, not one for each dash")
end)

test("a failing quads call draws the dashes one by one and is not tried again", function()
    setup()
    local tried = 0
    PZToolsAPI = { version = 1, client = function() return {} end, draw = { quads = function() tried = tried + 1 error("bad") end } }
    local drawn = {}
    ISWorldMap.prerender(mapElement(drawn))
    truthy(#dashes(drawn) > 10, "drawn one by one")
    local first = tried
    truthy(first >= 1)
    drawn = {}
    ISWorldMap.prerender(mapElement(drawn))
    eq(tried, first, "not tried again")
    truthy(#dashes(drawn) > 10)
    PZToolsAPI = nil
end)
