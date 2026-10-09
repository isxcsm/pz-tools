-- The serum's hallucination (LORE 7, TREES 159): a brief wash of light along the screen's edges, longer for the first
-- three doses, and where a drop site lies within the loaded squares the light stays longer on the edge that faces
-- it. It does not replay the reference night, makes no sound of rotors, shows no map mark and tells no distance. A
-- one-pixel ISUI element drawing over the whole screen, so the game stays playable beneath it (a full-screen element
-- takes every click in the world, consuming events or not); a client option turns it off.
require "ISUI/ISPanel"
require "OperationAcorn/Core"
require "OperationAcorn/Sync"
require "OperationAcorn/Story/Glow"
require "OperationAcorn/Client"
local OA = OperationAcorn
local Hallucination = {}
OA.Hallucination = Hallucination

-- The overlay's strips: how many a glow is drawn with, and how deep it reaches in the screen's shorter side.
Hallucination.STRIPS = 16
Hallucination.DEPTH = 0.16
-- Milliseconds: the long run (first doses) and the short one, the site edge staying 1.5 times as long.
Hallucination.LONG_MS = 14000
Hallucination.SHORT_MS = 5000

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

function ISOAHallucination:prerender()
    local now = getTimestampMs()
    local alive = {}
    for _, run in ipairs(self.runs) do
        local t = now - run.start
        local base = OA.Glow.envelope(t, run.total)
        local site = run.edge and OA.Glow.envelope(t, run.total * 1.5) or 0
        if t < run.total * 1.5 then
            alive[#alive + 1] = run
            -- A faint light on all four edges, and the stronger one where the site is.
            for _, e in ipairs({ "left", "right", "top", "bottom" }) do
                local s = base * 0.35
                if e == run.edge then s = math.max(s, site) end
                self:glow(e, s)
            end
        end
    end
    self.runs = alive
    if #alive == 0 then
        self:removeFromUIManager()
        Hallucination.overlays[self.playerNum] = nil
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
    end
    local run = {
        start = getTimestampMs(),
        total = detail.long and Hallucination.LONG_MS or Hallucination.SHORT_MS,
        edge = (detail.dx and detail.dy) and OA.Glow.edge(detail.dx, detail.dy) or nil,
    }
    table.insert(ui.runs, run)
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
