-- A call on the spot (SCENES.md 2 '현장 교신': S5F, S8F): the field call device sealed, the helicopter coming, the team
-- speaks over the screen's top edge. The screen is not darkened and the game runs on: the helicopter and the zombies
-- are the scene. The lines play by the same timeline as the comms tab's (Story/CommsScript), the protagonist's typed on
-- their own row; while zombies chase or are very close the next line waits (the game's own counts, nothing looked
-- for), and while the game is paused the call is too. At its end the strip goes and the server keeps the call
-- (comms_played): the comms tab has it in its record.
require "OperationAcorn/Core"
require "OperationAcorn/Client"
require "OperationAcorn/Sync"
require "OperationAcorn/Trade/UI"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Comms"
require "OperationAcorn/Story/CommsScript"
local OA = OperationAcorn
local UI, Comms, Script = OA.Trade.UI, OA.Comms, OA.CommsScript
local FieldCall = {}
OA.FieldCall = FieldCall

-- The strip (design units): its width (at most a share of the screen), its distance from the top, the rows it shows,
-- the margins; how long it stays after the last line (s). (가안: set in the game.)
FieldCall.W = 620
FieldCall.SHARE = 0.7
FieldCall.TOP = 18
FieldCall.ROWS = 4
FieldCall.PAD = 10
FieldCall.LINGER = 2.5
FieldCall.SOUND_IN = "RadioZap"

local COLOURS = { oak = { 0.55, 0.92, 0.60 }, me = { 0.92, 0.95, 0.92 }, pre = { 0.55, 0.62, 0.56 },
    bg = { 0.02, 0.05, 0.03 }, border = { 0.20, 0.50, 0.25 } }

-- The calls this game has played and told the server of (the record may not say so yet).
local told = {}

OAFieldCall = ISPanel:derive("OAFieldCall")

local chars = Script.chars

local function text(key, ...)
    local s = getText(key, ...)
    if s == key then return "" end
    return s
end

-- Whether the character is in trouble: zombies after it, or very close.
local function danger(character)
    local stats = character:getStats()
    return stats:getNumChasingZombies() > 0 or stats:getNumVeryCloseZombies() > 0
end

function OAFieldCall:new(character, entry, record)
    local sw = UI.dp(getCore():getScreenWidth())
    local w = math.min(FieldCall.W, math.floor(sw * FieldCall.SHARE))
    local h = FieldCall.ROWS * (UI.fontHeight() + 4) + FieldCall.PAD * 2
    local o = ISPanel:new(math.floor((sw - w) / 2), FieldCall.TOP, w, h)
    setmetatable(o, self)
    self.__index = self
    o.wantMouseEvents = false
    o.background = false
    o.character = character
    o.entry = entry
    o.sign = getText(entry.sign == "admin" and "IGUI_OA_Story_CallSign_Handover" or "IGUI_OA_Story_CallSign_Oak")
    o.number = OA.Story.number(record)
    local tier = OA.Story.tier(record)
    o.tier = tier
    o.lines = Script.lines(entry, { text = text, number = o.number, tier = tier, late = OA.Story.lateContact(record) })
    o.tl = Script.timeline(o.lines)
    o.t = 0
    o.st = Script.at(o.tl, 0)
    o.line = 0
    return o
end

-- Each frame: the clock moves unless a line is done and the character is in trouble, or the game is paused.
local function frame(self, now)
    local dt = (now - (self.last or now)) / 1000
    self.last = now
    if self.over then
        if now >= self.over then
            self.over = math.huge
            UI.fadeOut(self)
            return nil
        end
        return 1
    end
    local hold = getGameSpeed() == 0 or (self.st.phase == "read" and danger(self.character))
    if not hold then self.t = self.t + dt end
    local st = Script.at(self.tl, self.t)
    self.st = st
    if not st.line then
        self.over = now + FieldCall.LINGER * 1000
        FieldCall.played(self)
        return now
    end
    if st.line ~= self.line then
        self.line = st.line
        if self.lines[st.line].who == "oak" then getSoundManager():playUISound(FieldCall.SOUND_IN) end
    end
    return now
end

-- The rows on show, the newest last: { sign, text, colour, shown (characters, nil for all), cursor, flicker }.
function OAFieldCall:rows()
    local st, rows = self.st, {}
    local function add(row) rows[#rows + 1] = row end
    local count = st.line and st.done or #self.lines
    for i = 1, count do
        local l = self.lines[i]
        if l.who == "oak" then add({ sign = self.sign, text = l.text, colour = COLOURS.oak })
        elseif l.who == "me" then add({ sign = self.number, text = l.text, colour = COLOURS.me }) end
    end
    local l = st.line and self.lines[st.line]
    if l and l.who == "oak" then
        add({ sign = self.sign, text = l.text, colour = COLOURS.oak, shown = st.shown, flicker = st.flicker })
    elseif l and l.who == "me" then
        if st.phase == "read" then
            add({ sign = self.number, text = l.text, colour = COLOURS.me })
        else
            local src = (st.inputOf == "erase" and l.erase or l.text) or ""
            add({ sign = self.number, text = src, colour = COLOURS.me, shown = st.input, cursor = true })
        end
    end
    return rows
end

function OAFieldCall:prerender()
    local w, h = self.width, self.height
    UI.fill(self, 0, 0, w, h, COLOURS.bg, 0.72)
    UI.frame(self, 0, 0, w, h, COLOURS.border, 0.8)
    local fh = UI.fontHeight()
    local pad = FieldCall.PAD
    local signW = math.max(UI.textWidth(self.sign), UI.textWidth(self.number)) + 12
    local tw = w - pad * 2 - signW
    -- the newest rows from the bottom up, each cut to the width
    local rows = self:rows()
    local y = h - pad - fh
    for i = #rows, math.max(1, #rows - FieldCall.ROWS + 1), -1 do
        local row = rows[i]
        local s = row.text
        if row.shown then
            local cs = chars(s)
            s = table.concat(cs, "", 1, math.min(row.shown, #cs))
        end
        local a = 1
        if row.flicker then
            local t = getTimestampMs()
            a = 0.35 + 0.4 * math.abs(math.sin(t / 37)) * math.abs(math.sin(t / 113))
        end
        local age = #rows - i
        local fade = age == 0 and 1 or 1 - 0.18 * age
        UI.text(self, row.sign, pad, y, COLOURS.pre, nil, fade)
        local shown = s
        if UI.textWidth(shown) > tw then shown = UI.fit(shown, tw) end
        UI.text(self, shown, pad + signW, y, row.colour, nil, a * fade)
        if row.cursor and (OA.remainder(math.floor(getTimestampMs() / 450), 2) == 0 or self.st.phase == "type") then
            UI.fill(self, pad + signW + UI.textWidth(shown) + 1, y + 1, 7, fh - 2, row.colour, 0.85)
        end
        y = y - fh - 4
    end
end

UI.scaled(OAFieldCall, ISPanel)

-- The call has played: the server keeps it.
function FieldCall.played(panel)
    if told[panel.entry.id] then return end
    told[panel.entry.id] = true
    OA.Sync.send(panel.character, "comms_played", { entry = panel.entry.id })
end

local current

-- A call on the spot waiting for this player starts, when none is on show.
function FieldCall.check()
    if current and current.javaObject and current:isVisible() and current.over ~= math.huge then return end
    current = nil
    local character = getPlayer and getPlayer()
    if not character or character:isDead() then return end
    local record = OA.Client.record(character)
    local e = record and Comms.next(record, "field")
    if not e or told[e.id] then return end
    UI.refreshScale()
    local panel = OAFieldCall:new(character, e, record)
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    panel:setAlwaysOnTop(true)
    current = panel
    UI.live(panel, frame)
end

OA.Sync.listen("comms", function() FieldCall.check() end)
OA.Sync.listen("all", function() FieldCall.check() end)
Events.OnGameStart.Add(function() FieldCall.check() end)

return FieldCall
