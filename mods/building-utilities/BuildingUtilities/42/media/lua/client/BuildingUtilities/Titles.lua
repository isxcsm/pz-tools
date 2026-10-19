-- The titles of a character's firsts with the boxes, drawn big over the screen by the extension API's text
-- (PZExtAPI.text.title) in the window's accent: the first box they see powered by its own supplies ("lit", as its
-- window opens or shows a change), and each tier they first raise a box to ("tier", as the upgrade is done, the window
-- open or not: Sync.title). Once for each character (their mod data). Without the API's text there is none, and it is
-- still to come.
require "BuildingUtilities/PanelUi"
require "BuildingUtilities/Networks"
require "PZUIKit/Titles"
local BU = BuildingUtilities
local Titles = {}
BU.Titles = Titles

Titles.SEEN = "buTitles"
local STYLES = { lit = "unveil", tier = "notice" }
local SUBTITLE = { 0.78, 0.9, 1 }

-- The drawing is the UI kit's (PZUIKit.Titles): the API's text, the style it has, the band over a window, the sounds.
local Kit = PZUIKit.Titles

-- Shows a title to a character unless they have seen it: kind "lit", or "tier" with the tier reached. True when shown.
function Titles.show(character, kind, tier)
    if not character or not STYLES[kind] then return false end
    local mark = kind == "tier" and "tier" .. tostring(tier) or kind
    local data = character:getModData()
    local seen = data[Titles.SEEN] or {}
    if seen[mark] then return false end
    local api = BU.api()
    local handle = Kit.textApi(api) and BU.handle()
    if not handle then return false end
    local key, sub = "IGUI_BU_Title_Lit", "IGUI_BU_Title_LitSub"
    if kind == "tier" then
        key = "IGUI_BU_Title_Tier" .. tostring(tier)
        sub = key .. "Sub"
    end
    local spec = { text = getText(key), subtitle = getText(sub), style = STYLES[kind], color = BU.PanelUi.ACCENT,
        subtitleColor = SUBTITLE, player = character:getPlayerNum() }
    if not Kit.show(api, handle, spec, BU.log) then return false end
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

-- A click the window refuses (a cost not met, a room out of reach): a brief title (light, low on the screen, over the
-- window), red; without the API's text, or one without the brief style, the character says it. Never the small text
-- over the character.
Titles.REFUSED = { 1.00, 0.55, 0.50 }
function Titles.refuse(character, line)
    if not character or not line then return end
    local api = BU.api()
    local handle = Kit.textApi(api) and BU.handle()
    local spec = { text = line, style = "brief", color = Titles.REFUSED, player = character:getPlayerNum() }
    if handle and Kit.show(api, handle, spec, BU.log) then return end
    character:Say(line)
end

-- What the box's side says: a title for a local character.
function BU.onTitle(character, kind, tier) Titles.show(character, kind, tier) end

return Titles
