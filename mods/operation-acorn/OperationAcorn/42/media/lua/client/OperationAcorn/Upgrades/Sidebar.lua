-- The way to the adaptation tab: the game's sidebar heart (the button that opens the character info window). While
-- research points have come that the tab has not been seen with, the heart beats: the game's own lit heart (the one
-- it shows while the window is open) comes over it in a double beat and goes, then rests (not the game's shake, which
-- says the character was hurt); its tooltip says so, and a click on it opens the window on the adaptation tab instead
-- of the health one. Seeing the tab (Sidebar.seen) stops it. What was seen is the
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

-- The beat: every PERIOD_MS two beats, at BEATS ms into it, each coming up over RISE_MS and fading over FALL_MS to
-- the lit heart's PEAK alpha (the second a little weaker, SECOND); the rest of the period it rests. Its alpha is drawn
-- in LEVELS steps: while it rests the step stays 0, so nothing is drawn afresh then.
Sidebar.PERIOD_MS = 1700
Sidebar.BEATS = { 0, 260 }
Sidebar.RISE_MS, Sidebar.FALL_MS = 70, 300
Sidebar.PEAK, Sidebar.SECOND = 0.95, 0.7
Sidebar.LEVELS = 32
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

-- The lit heart's alpha at `now` (ms): the stronger of the two beats, each eased up and down.
function Sidebar.beat(now)
    local t = now % Sidebar.PERIOD_MS
    local a = 0
    for k, at in ipairs(Sidebar.BEATS) do
        local d = t - at
        local v = 0
        if d >= 0 and d < Sidebar.RISE_MS then
            v = math.sin(d / Sidebar.RISE_MS * math.pi / 2)
        elseif d >= Sidebar.RISE_MS and d < Sidebar.RISE_MS + Sidebar.FALL_MS then
            local f = (d - Sidebar.RISE_MS) / Sidebar.FALL_MS
            v = (1 - f) * (1 - f)
        end
        v = v * (k == 1 and 1 or Sidebar.SECOND)
        if v > a then a = v end
    end
    return a * Sidebar.PEAK
end

-- The beat's step at `now`: 0 (resting) to LEVELS.
function Sidebar.step(now)
    return math.floor(Sidebar.beat(now) / Sidebar.PEAK * Sidebar.LEVELS + 0.5)
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

-- The lit heart over the button, where and as large as the button draws its own picture (ISButton:render).
local function drawBeat(el)
    local button, tex = el.healthBtn, el.heartIconOn
    if not (tex and button and button:getIsVisible()) then return end
    local step = Sidebar.step(getTimestampMs())
    if step <= 0 then return end
    local bw, bh = button:getWidth(), button:getHeight()
    local w, h = tex:getWidthOrig(), tex:getHeightOrig()
    if w > bw or h > bh then
        local k = math.min(bw / w, bh / h)
        w, h = w * k, h * k
    end
    local x, y = button:getX() + (bw - w) / 2, button:getY() + (bh - h) / 2
    el:drawTextureScaled(tex, x, y, w, h, step / Sidebar.LEVELS * Sidebar.PEAK, 1, 1, 1)
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

-- The beat over the heart: drawn after the sidebar's buttons.
local baseRender = ISEquippedItem.render
function ISEquippedItem:render()
    baseRender(self)
    if self.oaFresh then OA.try("sidebar: the heart's beat", drawBeat, self) end
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
