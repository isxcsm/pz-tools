-- A call on the spot (SCENES.md 2 '현장 교신': S5F, S8F): the field call device sealed, the helicopter coming, the team
-- speaks over the game. Each line is typed at the bottom of the screen, as subtitles are, with the extension API's text
-- (text.show, `enter = "type"`): the call sign first, at once, in the speaker's colour, then the words at the speaker's
-- speed, a cursor after them; a break in the signal or a silence is a pause in the typing. As a line comes the ones
-- before it move up and dim (text.move), a few at most: the last of them goes. The screen is not darkened
-- and the game runs on: the helicopter and the zombies are the scene. The lines go by the same timeline as the comms
-- tab's (Story/CommsScript); while zombies chase or are very close the next line waits (the game's own counts, nothing
-- looked for), and while the game is paused the call is too. At its end the last line fades and the server keeps the
-- call (comms_played): the comms tab has it in its record. Without the API's text the call is kept unseen.
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Titles"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Comms"
require "OperationAcorn/Story/CommsScript"
require "OperationAcorn/Sounds"
local OA = OperationAcorn
local Comms, Script = OA.Comms, OA.CommsScript
local FieldCall = {}
OA.FieldCall = FieldCall

-- Where and how a line is typed: the bottom of the newest line and its height as shares of the screen, the longest a line
-- may be, the backdrop behind it; how long the last line stays (s) and fades. (가안: set in the game.)
FieldCall.BOTTOM = 0.83
FieldCall.SIZE = 0.03
FieldCall.WIDTH = 0.7
FieldCall.BACKDROP = 0.45
FieldCall.LINGER = 2.5
FieldCall.FADE = 0.5
-- The lines on the screen at most; the room a row takes (in line heights) and the gap between lines; the characters a row
-- holds about (a longer line is broken: it takes more rows). The earlier lines' colour and backdrop, the one before the
-- newest first; how long they take to move up (s).
FieldCall.ROWS = 3
FieldCall.ROW = 1.25
FieldCall.GAP = 0.35
FieldCall.ROW_CHARS = 42
FieldCall.DIM = { 0.7, 0.45 }
FieldCall.DIM_BACKDROP = { 0.25, 0.15 }
FieldCall.MOVE = 0.35
-- The call's pace: slower than the terminal's, as it is heard over the helicopter, a turn between the speakers to take a
-- breath, the last words left a while (CommsScript.timeline's pace). (가안: set in the game.)
FieldCall.PACE = { oak = 13, me = 9, turn = 1.2, after = 2.0 }

-- The speakers' colours (markup), the call sign's and the words'.
local COLOURS = { oak = { sign = "6E9C76", words = "8CEB99" }, me = { sign = "8C9E8F", words = "EBF2EB" } }

-- The calls this game has played and told the server of (the record may not say so yet).
local told = {}

-- Whether the character is in trouble: zombies after it, or very close.
local function danger(character)
    local stats = character:getStats()
    return stats:getNumChasingZombies() > 0 or stats:getNumVeryCloseZombies() > 0
end

-- A line's words in the API's markup: the comms marks become pauses ({cut}, {mute} and {p} alike), a brace that is no
-- mark is dropped. Empty when the line is only a pause.
function FieldCall.words(s)
    s = string.gsub(s or "", "{([^}]*)}", function(mark)
        local kind, secs = string.match(mark, "^(%a+):([%d%.]+)$")
        if kind == "cut" or kind == "mute" or kind == "p" then return "{p:" .. secs .. "}" end
        return ""
    end)
    local plain = string.gsub(s, "{p:[%d%.]+}", "")
    if not string.find(plain, "%S") then return "" end
    return s
end

-- The rows a line takes: its sign and words, without the marks, broken where it is longer than a row holds.
function FieldCall.rows(sign, words)
    local plain = string.gsub(words, "{p:[%d%.]+}", "")
    return math.max(1, math.ceil((#sign + 2 + #plain) / FieldCall.ROW_CHARS))
end

-- Where the lines on the screen are centred, the newest last, from the rows each takes: the newest's bottom stays put, each
-- one before it sits above the one after it.
function FieldCall.places(rows)
    local places, step = {}, FieldCall.SIZE * FieldCall.ROW
    local bottom = FieldCall.BOTTOM
    for i = #rows, 1, -1 do
        local height = rows[i] * step
        places[i] = bottom - height / 2
        bottom = bottom - height - FieldCall.SIZE * FieldCall.GAP
    end
    return places
end

-- What the API is asked to type for a line: the call sign at once, then the words at the speaker's speed.
function FieldCall.spec(sign, who, words, speed, playerNum, y)
    local c = COLOURS[who] or COLOURS.oak
    return { text = "{s:1000}{c:" .. c.sign .. "}" .. sign .. "{/c}  {s:" .. speed .. "}{c:" .. c.words .. "}" .. words
            .. "{/c}",
        markup = true, font = { "SdfRegular", "Medium" }, size = FieldCall.SIZE, x = 0.5, y = y or FieldCall.BOTTOM,
        width = FieldCall.WIDTH, enter = "type", speed = speed, cursor = true, leave = "fade", leaveTime = FieldCall.FADE,
        backdrop = FieldCall.BACKDROP, shadow = true, player = playerNum }
end

local current   -- the call on show: { character, entry, lines, tl, t, st, line, shown, last, over }

-- The call's lines go from the screen.
local function hide(call)
    local t = OA.Titles.textApi()
    for i = 1, #call.shown do
        if t then OA.try("field call: hiding a line", t.hide, OA.handle(), call.shown[i].key) end
    end
    call.shown = {}
end

-- A line comes: it is typed under the ones before, which move up and dim, the oldest going past the most there may be (a
-- line that is only a pause shows nothing).
local function start(call, l)
    if l.who ~= "oak" and l.who ~= "me" then return end
    if l.who == "oak" then PZUIKit.Sound.ui("oa.comms.in") end
    local words = FieldCall.words(l.text)
    if words == "" then return end
    local t = OA.Titles.textApi()
    if not t then return end
    local sign = l.who == "oak" and call.sign or call.number
    local speed = l.who == "oak" and FieldCall.PACE.oak or FieldCall.PACE.me
    local shown = call.shown
    shown[#shown + 1] = { rows = FieldCall.rows(sign, words) }
    local rows = {}
    for i = 1, #shown do rows[i] = shown[i].rows end
    local places = FieldCall.places(rows)
    local going = #shown - FieldCall.ROWS
    for i = 1, #shown - 1 do
        local back = #shown - i
        -- the earlier lines move up and dim, without a cursor; past the most there may be, one goes out at the top
        OA.try("field call: moving a line", t.move, OA.handle(), shown[i].key, { y = math.max(0, places[i]), alpha = FieldCall.DIM[back] or 0,
            backdrop = FieldCall.DIM_BACKDROP[back] or 0, cursor = false, time = FieldCall.MOVE })
        if i <= going then OA.try("field call: hiding a line", t.hide, OA.handle(), shown[i].key) end
    end
    local newest = places[#places]
    for _ = 1, math.max(0, going) do table.remove(shown, 1) end
    local ok, key = OA.try("field call: showing a line", t.show, OA.handle(), FieldCall.spec(sign, l.who, words, speed, call.character:getPlayerNum(),
        newest))
    if ok then shown[#shown].key = key else table.remove(shown) end
end

-- The call has played: the server keeps it.
local function played(call)
    if told[call.entry.id] then return end
    told[call.entry.id] = true
    OA.Sync.send(call.character, "comms_played", { entry = call.entry.id })
end

-- Each tick while a call is on: its clock moves unless a line is done and the character is in trouble, or the game is
-- paused; a new line is typed as it comes; at the end the last one stays a while. The handler, once added, stays (one
-- taken off inside its event makes the game skip the next one that tick) and returns at once while no call is on.
local hooked = false
local function tick()
    local call = current
    if not call then return end
    local now = getTimestampMs()
    local dt = (now - (call.last or now)) / 1000
    call.last = now
    if call.over then
        if now >= call.over then
            hide(call)
            current = nil
        end
        return
    end
    local hold = getGameSpeed() == 0 or (call.st.phase == "read" and danger(call.character))
    if not hold then call.t = call.t + dt end
    local st = Script.at(call.tl, call.t)
    call.st = st
    if not st.line then
        call.over = now + FieldCall.LINGER * 1000
        played(call)
        return
    end
    if st.line ~= call.line then
        call.line = st.line
        start(call, call.lines[st.line])
    end
end

-- A call on the spot waiting for this player starts, when none is on.
function FieldCall.check()
    if current then return end
    local character = getPlayer and getPlayer()
    if not character or character:isDead() then return end
    local record = OA.Client.record(character)
    local e = record and Comms.next(record, "field")
    if not e or told[e.id] then return end
    local tier = OA.Story.tier(record)
    local lines = Script.lines(e, { text = Script.text, number = OA.Story.address(record), tier = tier,
        late = OA.Story.lateContact(record) })
    local tl = Script.timeline(lines, nil, FieldCall.PACE)
    current = { character = character, entry = e, lines = lines, tl = tl, t = 0, st = Script.at(tl, 0), line = 0, shown = {},
        sign = getText(e.sign == "admin" and "IGUI_OA_Story_CallSign_Handover" or "IGUI_OA_Story_CallSign_Oak"),
        number = OA.Story.number(record) }
    if not hooked then
        hooked = true
        Events.OnTick.Add(tick)
    end
end

OA.Sync.listen("comms", function() FieldCall.check() end)
OA.Sync.listen("all", function() FieldCall.check() end)
Events.OnGameStart.Add(function() FieldCall.check() end)

return FieldCall
