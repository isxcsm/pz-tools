-- A sound the server sends a player (OA.Sync.sound, a cue of Sounds.lua): sounded from each of that player's local
-- characters, so that it is heard where they stand (the easter egg radio's tone).
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Sounds"
local OA = OperationAcorn
local Cues = {}
OA.Cues = Cues

function Cues.play(playerId, detail)
    local cue = type(detail) == "table" and detail.cue
    if type(cue) ~= "string" then return end
    for i = 0, getNumActivePlayers() - 1 do
        local character = getSpecificPlayer(i)
        if character and (playerId == nil or OA.Client.id(character) == playerId) then
            PZUIKit.Sound.on(cue, character)
        end
    end
end
OA.Sync.listen("sound", Cues.play)

return Cues
