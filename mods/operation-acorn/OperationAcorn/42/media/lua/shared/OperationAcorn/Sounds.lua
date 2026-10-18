-- Operation Acorn's sounds (SOUND-SYSTEM.md): each cue the mod sounds, and the game's sound it is. Vanilla sounds for
-- now; the mod's own come in as sound scripts and change a line here. Played through PZUIKit.Sound.
require "PZUIKit/Sound"
local OA = OperationAcorn
local Sounds = {}
OA.Sounds = Sounds

Sounds.CUES = {
    -- the terminal's comms: a line of the team coming in, a line sent, the static under a call
    ["oa.comms.in"] = { sound = "RadioZap" },
    ["oa.comms.send"] = { sound = "RadioButton" },
    ["oa.comms.static"] = { sound = "RadioStatic" },
    -- the characters of a call: the team's coming in (no sound yet), the protagonist's typed and erased (the kit's keys)
    ["oa.comms.recv"] = { gap = 40 },
    ["oa.comms.key"] = { keyboard = "kit.terminal", gap = 40 },
    ["oa.comms.erase"] = { keyboard = "kit.terminal", erase = true, gap = 40 },
    -- the terminal printing a paper: a character typed (the kit's keyboard), a row printed (the kit's dot-matrix line)
    ["oa.paper.key"] = { keyboard = "kit.terminal", gap = 40 },
    ["oa.paper.row"] = { sound = "KIT_PrintRow" },
    -- a call waiting: a burst of static at the terminal, heard around it
    ["oa.comms.alert"] = { sound = "RadioZap" },
    -- the helicopter of a drop passing over
    ["oa.heli.pass"] = { sound = "Helicopter" },
    -- a box's or a crate's latch; one broken open
    ["oa.box.latch"] = { sound = "CloseMetalToolbox" },
    ["oa.box.break"] = { sound = "BreakFurniture" },
    -- a stage's things: a plank torn off a window, a radio talking
    ["oa.stage.plank"] = { sound = "BreakBarricadePlank" },
    ["oa.stage.radio"] = { sound = "RadioTalk" },
    -- the phone the hallucination rings
    ["oa.hallucination.ring"] = { sound = "TelevisionTestBeep" },
    -- an infection test's swab, while the result is waited for
    ["oa.serum.test"] = { sound = "FirstAidApplyAlcoholWipes" },
}
PZUIKit.Sound.defineAll(Sounds.CUES)

return Sounds
