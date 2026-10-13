-- The radio scene over the screen (client/RadioScene.lua): typed through the extension API's text with the lines' markup, the
-- plain show for an API from before typing, nothing without the API; and the stage title's line under it.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Titles"
require "OperationAcorn/RadioScene"
local OA = OperationAcorn

local function world()
    local data = { OA_Id = "p1" }
    local character = { getModData = function() return data end, getPlayerNum = function() return 0 end }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return character end
    getText = function(key, ...)
        local parts = { key }
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        return table.concat(parts, " ")
    end
end

local function api(show, status)
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return status or "applied" end,
            title = function() end,
            show = show,
        },
    }
end

local DETAIL = { id = "s3", keys = { "s3_a", "s3_b" }, number = "0347" }

test("a scene is typed through the API's text: the lines with their markup, after the title, on the player's screen", function()
    world()
    local specs = {}
    api(function(handle, spec) specs[#specs + 1] = { handle = handle, spec = spec } end)
    eq(OA.Sync.scene("p1", DETAIL), nil)
    eq(#specs, 1)
    local spec = specs[1].spec
    eq(specs[1].handle, "handle")
    eq(spec.enter, "type")
    eq(spec.markup, true)
    eq(spec.cursor, true)
    eq(spec.width, 0.5)
    eq(spec.queue, true, "it waits for the title before it")
    eq(spec.player, 0)
    eq(spec.speed, OA.RadioScene.SPEED)
    eq(spec.text, "IGUI_OA_Story_Radio_s3_a 0347\n\nIGUI_OA_Story_Radio_s3_b 0347")
    eq(spec.enterTime, nil, "typing takes no time of its own")
    eq(OA.RadioScene.show("p1", DETAIL), "typed")
    eq(OA.RadioScene.show("someone else", DETAIL), nil, "another player's scene is not shown here")
end)

test("an API from before typing gets the plain scene: no markup, the lines in rows, whole", function()
    world()
    getCore = function() return { getScreenWidth = function() return 1000 end, getScreenHeight = function() return 1000 end } end
    getTextManager = function()
        return { getFontHeight = function() return 20 end, MeasureStringX = function(_, _, s) return #s * 10 end }
    end
    UIFont = { Medium = "Medium" }
    local shown = {}
    api(function(handle, spec)
        if spec.enter == "type" or spec.markup or spec.speed or spec.cursor or spec.width then
            error("PZExtAPI.text.show: spec has no field enter")
        end
        shown[#shown + 1] = spec
    end)
    getText = function(key) return "Oak.{p:0.5} Contact. Box received." end
    eq(OA.RadioScene.show("p1", DETAIL), "plain")
    eq(#shown, 1)
    local rows = {}
    for row in string.gmatch(shown[1].text .. "\n", "(.-)\n") do rows[#rows + 1] = row end
    truthy(#rows >= 2 and #rows <= OA.RadioScene.PLAIN_ROWS)
    truthy(not string.find(shown[1].text, "{", 1, true), "no markup")
    truthy(string.find(shown[1].text, "Oak. Contact.", 1, true))
    eq(shown[1].enter, "fade")
    eq(shown[1].queue, true)
    -- an API that refuses that too shows nothing, and does not break the game
    api(function() error("broken") end)
    eq(OA.RadioScene.show("p1", DETAIL), nil)
end)

test("without the API's text, or its hook, there is no scene", function()
    world()
    PZExtAPI = nil
    eq(OA.RadioScene.show("p1", DETAIL), nil)
    api(function() error("must not be called") end, "not-loaded")
    eq(OA.RadioScene.show("p1", DETAIL), nil)
    api(nil)
    eq(OA.RadioScene.show("p1", DETAIL), nil, "no show function")
    api(function() end)
    eq(OA.RadioScene.show("p1", { id = "x", keys = {} }), nil, "nothing to say")
    eq(OA.RadioScene.show("p1", nil), nil)
end)

test("a title's line is stripped of markup, and cut to its first sentences when the title says how long it may be", function()
    world()
    local halo = {}
    HaloTextHelper = {
        addText = function(_, t) halo[#halo + 1] = t end,
        addGoodText = function(_, t) halo[#halo + 1] = t end,
        addBadText = function() end,
    }
    PZExtAPI = nil
    getText = function(key) return key == "Sub" and "Oak.{p:0.5} Contact. A longer sentence follows here." or key end
    OA.Titles.show("p1", { key = "Head", sub = "Sub", fallback = "good" })
    eq(halo[1], "Head - Oak. Contact. A longer sentence follows here.")
    OA.Titles.show("p1", { key = "Head", sub = "Sub", subLead = 8, fallback = "good" })
    eq(halo[2], "Head - Oak. Contact.")
    local called = {}
    api(nil)
    PZExtAPI.text.title = function(_, spec) called[#called + 1] = spec end
    OA.Titles.show("p1", { key = "Head", sub = "Sub", subLead = 8 })
    eq(called[1].subtitle, "Oak. Contact.")
end)
