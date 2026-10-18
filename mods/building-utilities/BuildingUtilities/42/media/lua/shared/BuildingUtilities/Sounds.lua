-- Building Utilities' sounds (SOUND-SYSTEM.md): each cue the mod sounds, and the game's sound it is. Played through
-- PZUIKit.Sound; a box's sound goes from the server to the players by its cue (Sync.sound).
require "PZUIKit/Sound"
require "BuildingUtilities/Store"
local BU = BuildingUtilities
local Sounds = {}
BU.Sounds = Sounds

Sounds.CUES = {
    -- a box's switch thrown (a supply or a producer on or off, a breaker)
    ["bu.switch"] = { sound = "LightSwitch" },
    -- a generator behind a box stopping
    ["bu.generator.stop"] = { sound = "GeneratorStopping" },
    -- the manual showing a row on the panel's screen (no sound: a screen, not a printer)
    ["bu.manual.row"] = {},
}
PZUIKit.Sound.defineAll(Sounds.CUES)

return Sounds
