-- The call on the spot typed at the bottom of the screen (client Story/FieldCall): a line's words in the API's markup.
require "OperationAcorn/Story/FieldCall"
local FieldCall = OperationAcorn.FieldCall

test("the comms marks become pauses of the typing, a line that is only a pause shows nothing", function()
    eq(FieldCall.words("{mute:3}PEOPLE ARE NOT TAKEN UP."), "{p:3}PEOPLE ARE NOT TAKEN UP.")
    eq(FieldCall.words("{p:1}CORRECTION. {cut:2}OVER."), "{p:1}CORRECTION. {p:2}OVER.")
    eq(FieldCall.words("{cut:6}"), "")
    eq(FieldCall.words("PLAIN {x} WORDS"), "PLAIN  WORDS", "a brace that is no mark goes")
end)

test("the call sign comes at once in the speaker's colour, the words at the speaker's speed, typed at the bottom", function()
    local spec = FieldCall.spec("OAK", "oak", "WORDS.", 28, 0)
    eq(spec.text, "{s:1000}{c:6E9C76}OAK{/c}  {s:28}{c:8CEB99}WORDS.{/c}")
    eq(spec.enter, "type")
    eq(spec.markup, true)
    eq(spec.y, FieldCall.BOTTOM)
    truthy(spec.y > 0.5, "the lower half")
    eq(spec.player, 0)
end)

test("the lines stack up from the bottom: the newest's bottom stays put, a longer line takes more room", function()
    eq(FieldCall.rows("OAK", "SHORT."), 1)
    eq(FieldCall.rows("OAK", "{p:3}" .. string.rep("W", FieldCall.ROW_CHARS)), 2, "the marks take no room")
    local step, gap = FieldCall.SIZE * FieldCall.ROW, FieldCall.SIZE * FieldCall.GAP
    local one = FieldCall.places({ 1 })
    truthy(math.abs(one[1] - (FieldCall.BOTTOM - step / 2)) < 1e-9, "one line")
    local three = FieldCall.places({ 1, 2, 1 })
    truthy(math.abs(three[3] - one[1]) < 1e-9, "the newest stays where one line is")
    truthy(math.abs(three[2] - (FieldCall.BOTTOM - step - gap - step)) < 1e-9, "a line of two rows above it")
    truthy(math.abs(three[1] - (FieldCall.BOTTOM - 3 * step - 2 * gap - step / 2)) < 1e-9, "the oldest on top")
end)
