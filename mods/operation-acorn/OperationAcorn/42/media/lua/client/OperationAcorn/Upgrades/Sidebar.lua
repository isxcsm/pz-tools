-- The way to the adaptation tab: the game's sidebar heart (the button that opens the character info window). While
-- research points have come that the tab has not been seen with, a soft light breathes behind the heart (not the
-- game's shake, which says the character was hurt), its tooltip says so, and a click on it opens the window on the
-- adaptation tab instead of the health one. Seeing the tab (Sidebar.seen) puts the light out. What was seen is the
-- count of points that came (the trees' doses adapted and the shared ones), kept in the character's modData.
require "ISUI/ISEquippedItem"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Upgrades/Rules"
local OA = OperationAcorn
local UI = OA.Trade.UI
local Rules = OA.Upgrades.Rules
local Sidebar = {}
OA.Upgrades.Sidebar = Sidebar

-- The light: a breath of PERIOD_MS between LOW and HIGH alpha, drawn in LEVELS steps (a frame is drawn only when the
-- step changes), SIZE times the button, in COLOR.
Sidebar.PERIOD_MS = 1800
Sidebar.LEVELS = 12
Sidebar.LOW, Sidebar.HIGH = 0.15, 0.8
Sidebar.SIZE = 1.7
Sidebar.COLOR = { 0.55, 0.95, 1.0 }
Sidebar.SEEN = "OA_AdaptSeen"

-- Every point that came to u: the trees' doses adapted and the shared ones.
function Sidebar.gained(u)
    local n = u.sharedInjected or 0
    for _, count in pairs(u.injected or {}) do n = n + count end
    return n
end

local function stateOf(playerNum)
    local player = getSpecificPlayer(playerNum)
    local record = player and OA.Client.record(player)
    if not record then return nil end
    return player, Rules.section(record)
end

-- Whether points came that the tab has not been seen with.
function Sidebar.fresh(playerNum)
    local player, u = stateOf(playerNum)
    if not player then return false end
    return Sidebar.gained(u) > (player:getModData()[Sidebar.SEEN] or 0)
end

-- The breath's step at `now` (ms): 0 to LEVELS - 1.
function Sidebar.step(now)
    return math.floor((now % Sidebar.PERIOD_MS) / Sidebar.PERIOD_MS * Sidebar.LEVELS)
end

-- The light's alpha at a step: low at 0, high halfway.
function Sidebar.alpha(step)
    local t = step / Sidebar.LEVELS
    return Sidebar.LOW + (Sidebar.HIGH - Sidebar.LOW) * (0.5 - 0.5 * math.cos(2 * math.pi * t))
end

local function sidebarOf(playerNum)
    local data = getPlayerData and getPlayerData(playerNum)
    return data and data.equipped or nil
end

-- Each frame while the light is on (Trade/UI live): its step; nil once it is out. The tab coming on the screen however
-- it does (the heart, the window's own tab, a key) is the points seen.
local function tick(el, now)
    if not el.oaFresh then return nil end
    local Window = OA.Upgrades.Window
    if Window and Window.onScreen(el.playerNum) then
        Sidebar.update(el.playerNum)
        if not el.oaFresh then return nil end
    end
    return Sidebar.step(now)
end

-- The heart's tooltip: the game's, and a line while points wait.
local function tooltip(el, fresh)
    for _, entry in ipairs(el.mouseOverList or {}) do
        if entry.object == el.healthBtn then
            entry.oaBase = entry.oaBase or entry.displayString
            entry.displayString = fresh and (entry.oaBase .. " <LINE> " .. getText("IGUI_OA_Tree_HeartTip"))
                or entry.oaBase
        end
    end
end

-- The light and the tooltip follow the record (a change, the game's start, the tab seen). Points that come while the
-- tab is on the screen are seen as they come.
function Sidebar.update(playerNum)
    local Window = OA.Upgrades.Window
    if Window and Window.onScreen(playerNum) then
        local player, u = stateOf(playerNum)
        if player then player:getModData()[Sidebar.SEEN] = Sidebar.gained(u) end
    end
    local el = sidebarOf(playerNum)
    if not (el and el.healthBtn) then return end
    local fresh = Sidebar.fresh(playerNum)
    if el.oaFresh == fresh then return end
    el.oaFresh = fresh
    tooltip(el, fresh)
    if fresh then UI.live(el, tick) end
end

-- The tab came on the screen: the points that came so far are known (Sidebar.update notes them).
function Sidebar.seen(playerNum)
    Sidebar.update(playerNum)
end

-- (the developer's research reset: no point seen yet)
function Sidebar.forget(playerNum)
    local player = getSpecificPlayer(playerNum)
    if player then player:getModData()[Sidebar.SEEN] = nil end
    Sidebar.update(playerNum)
end

local glowTex
local function drawGlow(el)
    if glowTex == nil then glowTex = getTexture("media/textures/OA_Glow.png") or false end
    local button = el.healthBtn
    if not (glowTex and button and button:getIsVisible()) then return end
    local size = button:getWidth() * Sidebar.SIZE
    local x = button:getX() + button:getWidth() / 2 - size / 2
    local y = button:getY() + button:getHeight() / 2 - size / 2
    local c = Sidebar.COLOR
    el:drawTextureScaled(glowTex, x, y, size, size, Sidebar.alpha(Sidebar.step(getTimestampMs())), c[1], c[2], c[3])
end

local function onChanged()
    for playerNum = 0, getNumActivePlayers() - 1 do Sidebar.update(playerNum) end
end
OA.Sync.listen("upgrades", onChanged)
OA.Sync.listen("all", onChanged)
OA.on("OnGameStart", onChanged)
OA.on("OnCreatePlayer", function(playerNum) Sidebar.update(playerNum) end)

-- The game's functions below are left as they are while the mod is off (OA.off).
if OA.off then return Sidebar end

-- The light behind the heart: drawn after the sidebar's own background, before its buttons.
local basePrerender = ISEquippedItem.prerender
function ISEquippedItem:prerender()
    basePrerender(self)
    if self.oaFresh then OA.try("sidebar: the heart's light", drawGlow, self) end
end

-- A click on the heart while points wait opens the character window on the adaptation tab (the game's buttons were
-- made with this function, so it is changed before any sidebar is).
local baseDown = ISEquippedItem.onOptionMouseDown
-- (silent: the game's sidebar buttons make no sound of their own; the window opening is the answer)
function ISEquippedItem:onOptionMouseDown(button, x, y)
    if button and button.internal == "HEALTH" and self.oaFresh and OA.Upgrades.open then
        local info = getPlayerInfoPanel(self.playerNum)
        if info and not info:getIsVisible() and OA.Upgrades.open(self.playerNum) then return end
    end
    return baseDown(self, button, x, y)
end

return Sidebar
