-- Counts the cues that sound (PZUIKit.Sound.name answering a sound) from now on, by cue: SOUND_TALLY_PRINT() prints them
-- (SOUND lines) and starts over. Run it before a scene (p5_comms.lua, bu_window.lua...) to see its sounds come.
local Sound = PZUIKit.Sound
SOUND_TALLY = {}
if not SOUND_TALLY_NAME then
    SOUND_TALLY_NAME = Sound.name
    Sound.name = function(cue, at)
        local name = SOUND_TALLY_NAME(cue, at)
        if name then SOUND_TALLY[cue] = (SOUND_TALLY[cue] or 0) + 1 end
        return name
    end
end
function SOUND_TALLY_PRINT()
    local cues = {}
    for cue, n in pairs(SOUND_TALLY) do cues[#cues + 1] = cue .. " " .. n end
    table.sort(cues)
    print("SOUND tally: " .. (#cues == 0 and "nothing" or table.concat(cues, ", ")))
    SOUND_TALLY = {}
end
print("SOUND tally on")
