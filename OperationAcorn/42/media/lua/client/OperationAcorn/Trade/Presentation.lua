-- What the player sees and hears of the trade: a short text over the character for the server's notices, the sound
-- of the helicopter passing over a drop (the vanilla helicopter sound, moved along its path; the crate appears at the
-- loudest moment on the server's side), and the marks of what the helicopter left on the world map.
require "OperationAcorn/Client"
require "OperationAcorn/Trade/Trade"
local OA = OperationAcorn
local Trade = OA.Trade
local Presentation = {}
Trade.Presentation = Presentation

-- The vanilla helicopter sound (Base sound "Helicopter").
Presentation.SOUND = "Helicopter"

-- Notices ---------------------------------------------------------------------------------------------------------

-- The local characters whose record the notice is for.
local function charactersOf(playerId)
    local found = {}
    for i = 0, getNumActivePlayers() - 1 do
        local character = getSpecificPlayer(i)
        if character and (playerId == nil or OA.Client.id(character) == playerId) then found[#found + 1] = character end
    end
    return found
end

local function onNotice(playerId, detail)
    if type(detail) ~= "table" or not detail.key then return end
    local args = detail.args or {}
    local text = getText(detail.key, args[1], args[2], args[3], args[4])
    for _, character in ipairs(charactersOf(playerId)) do
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
    if type(args) ~= "table" or not args.x then return end
    local pass = { x = args.x, y = args.y, seconds = args.seconds or 22, path = args.path or 260, angle = args.angle or 0,
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

-- The world map --------------------------------------------------------------------------------------------------------

local ICON = "Item_OA_SupplyCrate"

-- Marks the unclaimed drops of the player whose map is open.
local function drawMarks(map)
    local character = getSpecificPlayer(map.playerNum or 0)
    local record = character and OA.Client.record(character)
    local marks = record and record.heli and record.heli.markers
    if not marks or #marks == 0 then return end
    local texture = getTexture(ICON)
    local size = 28
    for _, mark in ipairs(marks) do
        local sx = map.mapAPI:worldToUIX(mark.x, mark.y) - size / 2
        local sy = map.mapAPI:worldToUIY(mark.x, mark.y) - size / 2
        if texture then
            map:drawTextureScaledAspect(texture, sx, sy, size, size, 1, 1, 1, 1)
        else
            map:drawRect(sx, sy, size, size, 1, 0.9, 0.7, 0.2)
        end
        map:drawRectBorder(sx - 1, sy - 1, size + 2, size + 2, 1, 0.9, 0.3, 0.2)
        map:drawText(getText(mark.kind == "first" and "IGUI_OA_Trade_Map_First" or "IGUI_OA_Trade_Map_Crate"),
            sx + size + 4, sy + 6, 1, 0.9, 0.5, 1, UIFont.Small)
    end
end

local function hookMap()
    if not ISWorldMap or Presentation.mapHooked then return end
    Presentation.mapHooked = true
    local render = ISWorldMap.render
    function ISWorldMap:render()
        render(self)
        local ok, err = pcall(drawMarks, self)
        if not ok and not Presentation.mapFailed then
            Presentation.mapFailed = true
            OA.log("map marks failed:", tostring(err))
        end
    end
end
Events.OnGameStart.Add(hookMap)

return Presentation
