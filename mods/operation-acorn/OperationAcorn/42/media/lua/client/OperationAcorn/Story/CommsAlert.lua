-- The terminal tells of a call waiting (SCENES.md 2): while the comms tab has one to play, the terminal the record's
-- requests go to (Trade.terminalPosition) has the game's outline blinking on it, and every ten game minutes a short
-- burst of static comes from it. Only the player hears it: it is played on one of the game's free emitters, and
-- zombies hear only the world's sounds (WorldSoundManager). A terminal without power says nothing. Worked out when the
-- record's calls or its terminal change and every ten game minutes, one square looked at for each player; nothing
-- per tick.
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Objects"
require "OperationAcorn/Story/Comms"
local OA = OperationAcorn
local Comms, Objects = OA.Comms, OA.Trade.Objects
local Alert = {}
OA.CommsAlert = Alert

-- The outline's colour (the crude terminal's green), the static and how far it carries (가안: set in the game).
Alert.COLOUR = { 0.45, 0.95, 0.55 }
Alert.SOUND = "RadioZap"
Alert.RANGE = 15

-- The terminal lit for each player's number.
local lit = {}

-- The record's terminal when it is loaded and has power: the object and its square.
local function terminalOf(record)
    local x, y, z = OA.Trade.terminalPosition(record)
    if not x then return nil end
    local square = getCell():getGridSquare(x, y, z)
    local object = square and Objects.find(square, Objects.TERMINAL)
    if object and Objects.powered(square, object) then return object, square end
    return nil
end

local function light(object, n, on)
    if on then
        local c = Alert.COLOUR
        object:setOutlineHighlightCol(n, c[1], c[2], c[3], 0.9)
    end
    object:setOutlineHighlight(n, on)
    object:setOutlineHlBlink(n, on)
end

-- Each player's terminal lit while a call waits; `sound`: the static too.
function Alert.update(sound)
    for n = 0, getNumActivePlayers() - 1 do
        local character = getSpecificPlayer(n)
        local want, square
        if character and not character:isDead() then
            local record = OA.Client.record(character)
            if record and Comms.waiting(record) > 0 then want, square = terminalOf(record) end
        end
        local was = lit[n]
        if was and was ~= want then
            light(was, n, false)
            lit[n] = nil
        end
        if want then
            if was ~= want then
                light(want, n, true)
                lit[n] = want
            end
            if sound then getSoundManager():PlayWorldSound(Alert.SOUND, square, 0, Alert.RANGE, 1, false) end
        end
    end
end

local function quiet() Alert.update(false) end
OA.Sync.listen("comms", quiet)
OA.Sync.listen("trade", quiet)
OA.Sync.listen("all", quiet)
Events.OnGameStart.Add(quiet)
Events.EveryTenMinutes.Add(function() Alert.update(true) end)

return Alert
