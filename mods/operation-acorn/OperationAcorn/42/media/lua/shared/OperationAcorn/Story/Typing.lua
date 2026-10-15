-- Typing inside the terminal (DESIGN-terminal 14 F2, mockups/terminal/story-presentation-ideas.md): how each kind of text
-- comes on and at what speed on each terminal. The typing itself, the clock a text is typed by and how far it was seen,
-- are the UI kit's (PZUIKit.Typing, the panel PZUITypedText); the record keeps that state for each entry
-- (Story.typedState). Nothing in this file touches the game.
require "OperationAcorn/Core"
require "PZUIKit/Typing"
local OA = OperationAcorn
local Typing = {}
OA.Typing = Typing

-- How a kind of text comes on: a scene (a text that carries its pauses) a character at a time, as a radio is read
-- aloud; a document (a request copy, a guide, a field paper, a manifest) a row at a time, printed whole as a
-- teleprinter prints a line (DESIGN-terminal 14 F2, worklist 3-2; PZUIKit.Typing.LINE_STEP).
Typing.MODE = { scene = "chars", document = "lines" }

-- The characters a second of the two kinds of text and the two terminals (the crude one quick, the field terminal a little
-- slower and smoother): a scene at the speed of a radio read aloud, a document as fast as it can be followed. A
-- document is printed by rows (PZUIKit.Typing.LINE_STEP); its speed here is what the records of before were kept in (a
-- clock of seconds and the characters seen, PZUIKit.Typing.seenOf). A first guess, to be set in the game.
Typing.SPEED = {
    scene = { crude = 30, field = 25 },
    document = { crude = 80, field = 60 },
}

-- Which kind a folder group is: every paper is a document.
Typing.KIND_OF_GROUP = { request = "document", research = "document", field = "document", manifest = "document" }

-- The speed for a kind on a terminal ("crude" or "field"); nil for a kind that is not typed.
function Typing.speed(kind, tier)
    local speeds = Typing.SPEED[kind]
    if not speeds then return nil end
    return speeds[tier] or speeds.crude
end

return Typing
