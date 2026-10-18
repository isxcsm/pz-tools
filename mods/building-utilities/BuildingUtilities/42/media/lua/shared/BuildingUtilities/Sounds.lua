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
    -- the timed actions (PZUIKit.Sound.timed). During: a power line laid or taken away, a wrench's work (a water line,
    -- a pipe, a filter's media), electrical work in a box (upgraded, its design learnt, one taken apart), a battery's
    -- cells refilled. Done: a box made where it stands (as if put down), one taken up. Snow brushed off a panel by hand
    -- is quiet.
    ["bu.action.wire"] = { sound = "GeneratorConnect" },
    ["bu.action.wrench"] = { sound = "RepairWithWrench" },
    ["bu.action.electric"] = { sound = "Dismantle" },
    ["bu.action.battery"] = { sound = "PourWaterIntoObject" },
    ["bu.action.place"] = { sound = "UIObjectMenuObjectPlace" },
    ["bu.action.pickup"] = { sound = "UIObjectMenuObjectPickup" },
}
PZUIKit.Sound.defineAll(Sounds.CUES)

return Sounds
