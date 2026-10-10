-- Titles of events: through the extension API's text when its hook is in, else a text over the character.
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Titles"
local OA = OperationAcorn

local function world()
    local halo = {}
    local data = { OA_Id = "p1" }
    local character = { getModData = function() return data end, getPlayerNum = function() return 0 end }
    HaloTextHelper = {
        addText = function(_, t) halo[#halo + 1] = "plain:" .. t end,
        addGoodText = function(_, t) halo[#halo + 1] = "good:" .. t end,
        addBadText = function(_, t) halo[#halo + 1] = "bad:" .. t end,
    }
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return character end
    return halo
end

test("without the API's text a title is a text over the character, in its fallback's colour", function()
    local halo = world()
    PZToolsAPI = nil
    OA.Sync.title("p1", { key = "IGUI_OA_Title_Searched", sub = "IGUI_OA_Title_SearchedBonus", subArgs = { 300 },
        style = "discovery", fallback = "good" })
    eq(#halo, 1)
    eq(halo[1], "good:IGUI_OA_Title_Searched - IGUI_OA_Title_SearchedBonus 300")
    OA.Sync.title("someone else", { key = "IGUI_OA_Title_Searched" })
    eq(#halo, 1, "another player's title is not shown here")
end)

test("with the API's text a title goes to it, in its style and tone, on the player's screen", function()
    local halo = world()
    local called = {}
    PZToolsAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            title = function(handle, spec) called[#called + 1] = { handle = handle, spec = spec } end,
        },
    }
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone", args = { "x" }, tone = "gold" }), "title")
    eq(#halo, 0)
    eq(called[1].handle, "handle")
    eq(called[1].spec.style, "stamp", "stamp unless said")
    eq(called[1].spec.text, "IGUI_OA_Title_Capstone x")
    eq(called[1].spec.subtitle, nil)
    eq(called[1].spec.player, 0)
    eq(called[1].spec.color, OA.Titles.TONES.gold[1])
    -- a hook that is not in: the text over the character instead
    PZToolsAPI.text.status = function() return "not-loaded" end
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone" }), "halo")
    eq(halo[1], "plain:IGUI_OA_Title_Capstone")
    PZToolsAPI = nil
end)

test("an argument that is a text is translated on the player's side", function()
    local halo = world()
    PZToolsAPI = nil
    OA.Sync.title("p1", { key = "IGUI_OA_Title_Paid", sub = "IGUI_OA_Title_PaidSub",
        subArgs = { { key = "IGUI_OA_Story_Title_x", args = { 2 } }, 300 } })
    eq(halo[1], "plain:IGUI_OA_Title_Paid - IGUI_OA_Title_PaidSub IGUI_OA_Story_Title_x 2 300")
end)

test("with noHalo a title the API cannot draw is not shown, for the caller's own way", function()
    local halo = world()
    PZToolsAPI = nil
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_TreeOpened" }, true), nil)
    eq(#halo, 0)
    PZToolsAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = { status = function() return "applied" end, title = function() error("broken") end },
    }
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_TreeOpened" }, true), nil, "a failed draw is not a title")
    eq(#halo, 0)
    PZToolsAPI = nil
end)

test("a style the API does not have (an older PZ Tools) is asked as stamp", function()
    world()
    local called = {}
    local function api(styles)
        PZToolsAPI = {
            version = OA.API_VERSION,
            client = function() return "handle" end,
            text = {
                status = function() return "applied" end,
                styles = function() return styles end,
                title = function(_, spec) called[#called + 1] = spec.style end,
            },
        }
    end
    api({ "stamp", "dust" })
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone", style = "dust" })
    eq(called[1], "dust")
    api({ "stamp" })
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone", style = "dust" })
    eq(called[2], "stamp", "not there: stamp")
    PZToolsAPI = nil
end)
