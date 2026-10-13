-- The titles of a character's firsts with the boxes, drawn big over the screen by the extension API's text
-- (PZExtAPI.text.title) in the window's accent: the first box they see powered by its own supplies ("lit", as its
-- window opens or shows a change), and each tier they first raise a box to ("tier", as the upgrade is done, the window
-- open or not: Sync.title). Once for each character (their mod data). Without the API's text there is none, and it is
-- still to come.
require "BuildingUtilities/PanelUi"
require "BuildingUtilities/Networks"
local BU = BuildingUtilities
local Titles = {}
BU.Titles = Titles

Titles.SEEN = "buTitles"
local STYLES = { lit = "unveil", tier = "notice" }
local SUBTITLE = { 0.78, 0.9, 1 }

-- The API's text, when its drawing hook is in.
local function textApi()
    local api = BU.api()
    local text = api and api.text
    if type(text) ~= "table" or type(text.title) ~= "function" then return nil end
    local ok, status = pcall(text.status)
    if not ok or status ~= "applied" then return nil end
    return text
end

-- Shows a title to a character unless they have seen it: kind "lit", or "tier" with the tier reached. True when shown.
function Titles.show(character, kind, tier)
    if not character or not STYLES[kind] then return false end
    local mark = kind == "tier" and "tier" .. tostring(tier) or kind
    local data = character:getModData()
    local seen = data[Titles.SEEN] or {}
    if seen[mark] then return false end
    local text = textApi()
    local handle = text and BU.handle()
    if not handle then return false end
    local key, sub = "IGUI_BU_Title_Lit", "IGUI_BU_Title_LitSub"
    if kind == "tier" then
        key = "IGUI_BU_Title_Tier" .. tostring(tier)
        sub = key .. "Sub"
    end
    local ok, failure = pcall(text.title, handle, { text = getText(key), subtitle = getText(sub),
        style = STYLES[kind], color = BU.PanelUi.ACCENT, subtitleColor = SUBTITLE, player = character:getPlayerNum() })
    if not ok then
        BU.log("title:", tostring(failure))
        return false
    end
    seen[mark] = true
    data[Titles.SEEN] = seen
    return true
end

-- The first box a character sees powered: its own supplies reach it, its breaker up and its main switch on.
function Titles.lit(character, panel)
    if not panel or not BU.enabled("power") or panel.tripped or panel.switchedOff then return end
    local seen = character and character:getModData()[Titles.SEEN]
    if seen and seen.lit then return end
    local state = BU.Networks.state(panel, "power")
    if state and state.supplied then Titles.show(character, "lit") end
end

-- What the box's side says: a title for a local character.
function BU.onTitle(character, kind, tier) Titles.show(character, kind, tier) end

return Titles
