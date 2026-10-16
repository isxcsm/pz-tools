-- What the player sees and hears of the trade: a short text over the character for the server's notices, the sound
-- of the helicopter passing over a drop (the vanilla helicopter sound, moved along its path; the crate appears at the
-- loudest moment on the server's side). What the helicopter left is marked on the world map by Story/Maps.
require "OperationAcorn/Client"
require "OperationAcorn/Titles"
require "OperationAcorn/Trade/Trade"
local OA = OperationAcorn
local Trade = OA.Trade
local Presentation = {}
Trade.Presentation = Presentation

-- The vanilla helicopter sound (Base sound "Helicopter").
Presentation.SOUND = "Helicopter"

-- Notices ---------------------------------------------------------------------------------------------------------

-- The parts that show their own notices; this shows the trade part's and the economy's.
local SHOWN_ELSEWHERE = { "^IGUI_OA_Machine_", "^IGUI_OA_Story_", "^IGUI_OA_Tree_", "^IGUI_OA_Gear_" }

local function onNotice(playerId, detail)
    if type(detail) ~= "table" or type(detail.key) ~= "string" then return end
    for _, prefix in ipairs(SHOWN_ELSEWHERE) do
        if string.find(detail.key, prefix) then return end
    end
    local args = detail.args or {}
    if detail.key == "IGUI_OA_Trade_Notice_Sealed" then
        OA.Titles.notice(playerId, { key = "IGUI_OA_Title_Sealed", style = "stamp" }, detail.key, args)
        return
    end
    local text = getText(detail.key, unpack(args))
    for _, character in ipairs(OA.Titles.charactersOf(playerId)) do
        local bad = string.find(detail.key, "_Reason_", 1, true) ~= nil
        if bad then HaloTextHelper.addBadText(character, text) else HaloTextHelper.addText(character, text) end
    end
end
OA.Sync.listen("notice", onNotice)

-- The helicopter's pass --------------------------------------------------------------------------------------------------

local passes = {}
local ticking = false

-- Where the helicopter is, `t` seconds into a pass: along a line through the drop, from far on one side to far on the
-- other, at the drop at the loudest moment.
local function positionAt(pass, t)
    local f = (t / pass.seconds) * 2 - 1
    local reach = pass.path * f
    return pass.x - math.cos(pass.angle) * reach, pass.y - math.sin(pass.angle) * reach
end

local function tick()
    local now = getTimestampMs()
    for i = #passes, 1, -1 do
        local pass = passes[i]
        local t = (now - pass.started) / 1000
        if t >= pass.seconds then
            pass.emitter:stopAll()
            table.remove(passes, i)
        else
            local x, y = positionAt(pass, t)
            pass.emitter:setPos(x, y, 0)
        end
    end
    if #passes == 0 then
        Events.OnTick.Remove(tick)
        ticking = false
    end
end

local function onHeliPass(playerId, args)
    if type(args) ~= "table" or not (args.x and args.seconds and args.path) then return end
    local pass = { x = args.x, y = args.y, seconds = args.seconds, path = args.path, angle = args.angle or 0,
        started = getTimestampMs() }
    local x, y = positionAt(pass, 0)
    local emitter = getWorld():getFreeEmitter(x, y, 0)
    if not emitter then return end
    emitter:playSound(Presentation.SOUND)
    pass.emitter = emitter
    passes[#passes + 1] = pass
    if not ticking then
        ticking = true
        Events.OnTick.Add(tick)
    end
end
OA.Sync.listen("heliPass", onHeliPass)

return Presentation
