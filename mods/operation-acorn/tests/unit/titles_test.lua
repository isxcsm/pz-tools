-- Titles of events: through the extension API's text when its hook is in, else said by the character (never a small
-- text over it).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Sync"
require "OperationAcorn/Titles"
local OA = OperationAcorn

local function world()
    local said = {}
    local data = { OA_Id = "p1" }
    local character = { getModData = function() return data end, getPlayerNum = function() return 0 end,
        Say = function(_, t) said[#said + 1] = t end }
    HaloTextHelper = nil
    getNumActivePlayers = function() return 1 end
    getSpecificPlayer = function() return character end
    return said
end

test("without the API's text a title is said by the character", function()
    local said = world()
    PZExtAPI = nil
    OA.Sync.title("p1", { key = "IGUI_OA_Title_Paid", sub = "IGUI_OA_Title_PaidSub", subArgs = { 300 },
        style = "discovery" })
    eq(#said, 1)
    eq(said[1], "IGUI_OA_Title_Paid - IGUI_OA_Title_PaidSub 300")
    OA.Sync.title("someone else", { key = "IGUI_OA_Title_Paid" })
    eq(#said, 1, "another player's title is not shown here")
end)

test("with the API's text a title goes to it, in its style and tone, on the player's screen", function()
    local said = world()
    local called = {}
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            styles = function() return { "stamp", "dust" } end,
            title = function(handle, spec) called[#called + 1] = { handle = handle, spec = spec } end,
        },
    }
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone", args = { "x" }, tone = "gold" }), "title")
    eq(#said, 0)
    eq(called[1].handle, "handle")
    eq(called[1].spec.style, "dust", "dust unless said")
    eq(called[1].spec.dustBurn, nil, "the API burns in its own colour")
    eq(called[1].spec.now, nil, "queued")
    eq(called[1].spec.text, "IGUI_OA_Title_Capstone x")
    eq(called[1].spec.subtitle, nil)
    eq(called[1].spec.player, 0)
    eq(called[1].spec.color, OA.Titles.TONES.gold[1])
    eq(called[1].spec.y, nil, "the style's own place unless said")
    -- a place: the middle (the title and its line together, or the title alone), or a share of the height
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone", sub = "IGUI_OA_Title_NewItems", at = "center" })
    eq(called[2].spec.y, OA.Titles.CENTER)
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone", at = "center" })
    eq(called[3].spec.y, OA.Titles.CENTER_ALONE)
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone", at = 0.3 })
    eq(called[4].spec.y, 0.3)
    -- a hook that is not in: the character says it instead
    PZExtAPI.text.status = function() return "not-loaded" end
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone" }), "said")
    eq(said[1], "IGUI_OA_Title_Capstone")
    PZExtAPI = nil
end)

test("an argument that is a text is translated on the player's side", function()
    local said = world()
    PZExtAPI = nil
    OA.Sync.title("p1", { key = "IGUI_OA_Title_Paid", sub = "IGUI_OA_Title_PaidSub",
        subArgs = { { key = "IGUI_OA_Story_Title_x", args = { 2 } }, 300 } })
    eq(said[1], "IGUI_OA_Title_Paid - IGUI_OA_Title_PaidSub IGUI_OA_Story_Title_x 2 300")
    -- an amount is written as the terminal writes credits; a plain number (a call sign) is left as it is
    OA.Sync.title("p1", { key = "IGUI_OA_Title_Paid", sub = "IGUI_OA_Title_PaidSub", subArgs = { 1894, { credits = 1485 } } })
    eq(said[2], "IGUI_OA_Title_Paid - IGUI_OA_Title_PaidSub 1894 1,485")
end)

test("with noHalo a title the API cannot draw is not shown, for the caller's own way", function()
    local said = world()
    PZExtAPI = nil
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_TreeOpened" }, true), nil)
    eq(#said, 0)
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = { status = function() return "applied" end, title = function() error("broken") end },
    }
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_TreeOpened" }, true), nil, "a failed draw is not a title")
    eq(#said, 0)
    PZExtAPI = nil
end)

test("a style the API does not have (an older PZ Extension API) is asked as stamp", function()
    world()
    local called = {}
    local function api(styles)
        PZExtAPI = {
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
    PZExtAPI = nil
end)

test("a brief title the API does not have is said by the character, not a big one", function()
    local said = world()
    local called = {}
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            styles = function() return { "stamp", "dust" } end,
            title = function(_, spec) called[#called + 1] = spec.style end,
        },
    }
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_SearchedBonus", args = { "170" }, style = "brief" }), "said")
    eq(#called, 0)
    eq(said[1], "IGUI_OA_Title_SearchedBonus 170")
    -- (an API that has it: its styles are asked again, for another API's text)
    PZExtAPI.text = {
        status = function() return "applied" end,
        styles = function() return { "stamp", "dust", "brief" } end,
        title = function(_, spec) called[#called + 1] = spec end,
    }
    OA.Titles.show("p1", { key = "IGUI_OA_Title_SearchedBonus", args = { "170" }, style = "brief" })
    eq(called[1].style, "brief")
    PZExtAPI = nil
end)

test("the dev panel's switch lets every title go first", function()
    world()
    local called = {}
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            styles = function() return { "stamp", "dust", "notice" } end,
            title = function(_, spec) called[#called + 1] = { now = spec.now, style = spec.style } end,
        },
    }
    OA.Titles.now = true
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone" }), "title")
    eq(called[1].style, "dust")
    eq(called[1].now, true)
    OA.Titles.now = false
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Capstone", style = "notice" })
    eq(called[2].now, nil)
    PZExtAPI = nil
end)

test("a title's size asks the API for a scale of its style's; an older API without one shows it at the style's size", function()
    world()
    local called = {}
    local refuseScale = false
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            styles = function() return { "stamp", "dust" } end,
            title = function(_, spec)
                if refuseScale and spec.scale then error("spec has no field scale") end
                called[#called + 1] = spec
            end,
        },
    }
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Operation", size = "major" })
    eq(called[1].scale, OA.Titles.SIZES.major)
    truthy(OA.Titles.SIZES.major > 1)
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Sealed", size = "minor" })
    eq(called[2].scale, OA.Titles.SIZES.minor)
    truthy(OA.Titles.SIZES.minor < 1)
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Paid" })
    eq(called[3].scale, nil, "the style's size")
    refuseScale = true
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_Operation", size = "major" }), "title")
    eq(called[4].scale, nil)
    -- a notice shown as a title carries its size
    refuseScale = false
    OA.Titles.notice("p1", { key = "IGUI_OA_Title_Sealed", style = "stamp", size = "minor" }, "IGUI_OA_Trade_Notice_Sealed", { 3 })
    eq(called[5].scale, OA.Titles.SIZES.minor)
    PZExtAPI = nil
end)

test("a title carries its style's sounds (the kit's title cues); an older API without sounds shows it silent", function()
    world()
    local called = {}
    local refuseSounds = false
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            styles = function() return { "stamp", "dust" } end,
            title = function(_, spec)
                if refuseSounds and (spec.sounds or spec.subtitleSounds) then error("spec has no field sounds") end
                called[#called + 1] = spec
            end,
        },
    }
    local Sound = PZUIKit.Sound
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Sealed", style = "dust" })
    eq((called[1].sounds or {}).land, nil, "no sound defined for a moment: none asked")
    Sound.define("kit.title.dust.land", { sound = "Thud" })
    Sound.define("kit.title.dust.line.land", { sound = "Tap" })
    Sound.define("kit.title.dust.hold", { sound = "Hum" })
    Sound.define("kit.title.dust.line.hold", { sound = "LineHum" })
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Sealed", sub = "IGUI_OA_Title_Marked", style = "dust" })
    eq(called[2].sounds.land, "Thud")
    eq(called[2].subtitleSounds.land, "Tap")
    eq(called[2].sounds.hold, "Hum", "the hold is asked for with the other moments")
    eq(called[2].subtitleSounds.hold, "LineHum")
    OA.Titles.show("p1", { key = "IGUI_OA_Title_Sealed", style = "dust" })
    eq(called[3].subtitleSounds, nil, "no line: no line's sounds")
    refuseSounds = true
    eq(OA.Titles.show("p1", { key = "IGUI_OA_Title_Sealed", style = "dust" }), "title")
    eq(called[4].sounds, nil)
    Sound.define("kit.title.dust.land", {})
    Sound.define("kit.title.dust.line.land", {})
    Sound.define("kit.title.dust.hold", {})
    Sound.define("kit.title.dust.line.hold", {})
    PZExtAPI = nil
end)

test("a notice as a brief title in its tone, or said; a refusal of the character's own said", function()
    local said = world()
    local called = {}
    PZExtAPI = {
        version = OA.API_VERSION,
        client = function() return "handle" end,
        text = {
            status = function() return "applied" end,
            styles = function() return { "stamp", "brief" } end,
            title = function(_, spec) called[#called + 1] = spec end,
        },
    }
    OA.Titles.brief("p1", "IGUI_OA_Trade_Reason_far", nil, "red")
    eq(#called, 1)
    eq(called[1].style, "brief")
    eq(called[1].text, "IGUI_OA_Trade_Reason_far")
    eq(called[1].subtitle, nil)
    eq(called[1].color, OA.Titles.TONES.red[1])
    eq(#said, 0)
    OA.Titles.say("p1", "IGUI_OA_Story_FieldFail_device")
    eq(said[1], "IGUI_OA_Story_FieldFail_device")
    eq(#called, 1)
    PZExtAPI = nil
    OA.Titles.brief("p1", "IGUI_OA_Trade_Notice_Called", { "3" })
    eq(said[2], "IGUI_OA_Trade_Notice_Called 3")
end)
