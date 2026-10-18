-- The serum's hallucination (LORE 7, TREES 159): a brief wash of light along the screen's edges, longer for the first
-- three doses, and where a drop site lies within the loaded squares the light stays longer on the edge that faces
-- it. It does not replay the reference night, makes no sound of rotors, shows no map mark and tells no distance. A
-- one-pixel ISUI element drawing over the whole screen, so the game stays playable beneath it (a full-screen element
-- takes every click in the world, consuming events or not); a client option turns it off. A ringing in the ears sounds
-- once at the start, on the same option: the game has no tinnitus sound, so the steady test tone of its television
-- (`TelevisionTestBeep`, Object/Television/TestTone, which the game loops when a set has no signal) is played low and
-- faded out by the overlay's frame, which stops it. The frame (Trade/UI live) runs every frame before the UI draws, so
-- with PZ Optimization the ringing still steps smoothly, the glow falls on time after holding still, and the overlay
-- goes when its last run is over; the drawing only paints.
require "ISUI/ISPanel"
require "OperationAcorn/Core"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Glow"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Sounds"
local OA = OperationAcorn
local UI = OA.Trade.UI
local Hallucination = {}
OA.Hallucination = Hallucination

-- The overlay's strips: how many a glow is drawn with, and how deep it reaches in the screen's shorter side.
Hallucination.STRIPS = 16
Hallucination.DEPTH = 0.16
-- Milliseconds: the long run (first doses) and the short one, the site edge staying 1.5 times as long.
Hallucination.LONG_MS = 14000
Hallucination.SHORT_MS = 5000
-- The ringing (OA.Sounds' oa.hallucination.ring): how loud it gets (0 to 1), and the milliseconds it takes to rise, to hold and to fade.
Hallucination.RING_VOLUME = 0.35
Hallucination.RING_MS = { 400, 1200, 1800 }

ISOAHallucination = ISPanel:derive("ISOAHallucination")

function ISOAHallucination:new(playerNum)
    local o = ISPanel.new(self, getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum), 1, 1)
    o.screenW, o.screenH = getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)
    o.background = false
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.playerNum = playerNum
    o.runs = {}
    o:initialise()
    o:instantiate()
    o.javaObject:setConsumeMouseEvents(false)
    o:setAlwaysOnTop(true)
    o.javaObject:setIgnoreLossControl(true)
    return o
end

-- One glow along an edge: strips from the border inward, brighter at the border.
function ISOAHallucination:glow(edge, strength)
    if strength <= 0.01 then return end
    local w, h = self.screenW, self.screenH
    local depth = math.floor(math.min(w, h) * Hallucination.DEPTH)
    local n = Hallucination.STRIPS
    local step = math.max(1, math.floor(depth / n))
    for i = 0, n - 1 do
        local a = strength * ((1 - i / n) ^ 2) * 0.55
        if a > 0.004 then
            local d = i * step
            if edge == "left" then self:drawRect(d, 0, step, h, a, 1.0, 0.96, 0.82)
            elseif edge == "right" then self:drawRect(w - d - step, 0, step, h, a, 1.0, 0.96, 0.82)
            elseif edge == "top" then self:drawRect(0, d, w, step, a, 1.0, 0.96, 0.82)
            else self:drawRect(0, h - d - step, w, step, a, 1.0, 0.96, 0.82) end
        end
    end
end

-- The ringing of a run at `t` ms: its volume follows the rise, the hold and the fade, and it is stopped at the end.
function ISOAHallucination:ring(run, t)
    local ring = run.ring
    if not ring then return end
    local rise, hold, fade = Hallucination.RING_MS[1], Hallucination.RING_MS[2], Hallucination.RING_MS[3]
    if t >= rise + hold + fade then
        ring.emitter:stopSound(ring.id)
        run.ring = nil
        return
    end
    local volume = 1
    if t < rise then volume = t / rise
    elseif t >= rise + hold then volume = 1 - (t - rise - hold) / fade end
    ring.emitter:setVolume(ring.id, volume * Hallucination.RING_VOLUME)
end

-- The brightness of a run's faint light on every edge and of its light on the site's edge at `t` ms.
local function levels(run, t)
    local base = OA.Glow.envelope(t, run.total)
    local site = run.edge and OA.Glow.envelope(t, run.total * 1.5) or 0
    return base, site
end

-- Each frame, before the UI draws: the ringing of every run, the runs that are over let go, and the overlay taken off
-- with the last one (nil then). Gives the sum of the runs' brightnesses: it changes exactly when the drawing does (it
-- holds still while every glow holds, and moves again when one falls).
function ISOAHallucination:tick()
    local runs, now = self.runs, UI.sceneNow()
    local look, n = 0, 0
    for i = 1, #runs do
        local run = runs[i]
        local t = now - run.start
        self:ring(run, t)
        if t < run.total * 1.5 then
            n = n + 1
            runs[n] = run
            local base, site = levels(run, t)
            look = look + base + site
        end
    end
    for i = #runs, n + 1, -1 do runs[i] = nil end
    if n == 0 then
        self:removeFromUIManager()
        if Hallucination.overlays[self.playerNum] == self then Hallucination.overlays[self.playerNum] = nil end
        return nil
    end
    return look
end

local EDGES = { "left", "right", "top", "bottom" }

function ISOAHallucination:prerender()
    local now = UI.sceneNow()
    for _, run in ipairs(self.runs) do
        local t = now - run.start
        if t < run.total * 1.5 then
            local base, site = levels(run, t)
            -- A faint light on all four edges, and the stronger one where the site is.
            for _, e in ipairs(EDGES) do
                local s = base * 0.35
                if e == run.edge then s = math.max(s, site) end
                self:glow(e, s)
            end
        end
    end
end

Hallucination.overlays = {}

-- Does the player want the effect (a client option; on unless switched off).
function Hallucination.enabled()
    local options = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions:getOptions(OA.MOD)
    local option = options and options:getOption("OA_Hallucination")
    if option and option.getValue then return option:getValue() ~= false end
    return true
end

-- Starts a run. detail: { long =, dx =, dy = }.
function Hallucination.start(playerNum, detail)
    if not Hallucination.enabled() then return end
    local ui = Hallucination.overlays[playerNum]
    if not ui then
        ui = ISOAHallucination:new(playerNum)
        ui:addToUIManager()
        Hallucination.overlays[playerNum] = ui
        UI.live(ui, ISOAHallucination.tick)
    end
    local run = {
        start = UI.sceneNow(),
        total = detail.long and Hallucination.LONG_MS or Hallucination.SHORT_MS,
        edge = (detail.dx and detail.dy) and OA.Glow.edge(detail.dx, detail.dy) or nil,
    }
    run.ring = Hallucination.startRing(playerNum)
    table.insert(ui.runs, run)
end

-- Starts the ringing on the player's own sound emitter; returns { emitter, id } or nil when it cannot sound.
function Hallucination.startRing(playerNum)
    local player = getSpecificPlayer(playerNum)
    local emitter = player and player:getEmitter()
    if not emitter then return nil end
    local name = PZUIKit.Sound.name("oa.hallucination.ring")
    local id = name and emitter:playSound(name)
    if not id or id == 0 then return nil end
    emitter:setVolume(id, 0)
    return { emitter = emitter, id = id }
end

OA.Sync.listen("hallucinate", function(playerId, detail)
    local player = getPlayer()
    if not player then return end
    if OA.Store.idOf(player) ~= playerId then return end
    Hallucination.start(player:getPlayerNum(), detail or {})
end)

-- The option, in the game's mod options screen.
local function makeOptions()
    local options = OA.Client.options()
    if not options then return end
    options:addTickBox("OA_Hallucination", getText("IGUI_OA_Story_OptionHallucination"), true,
        getText("IGUI_OA_Story_OptionHallucinationTip"))
end

makeOptions()

return Hallucination
