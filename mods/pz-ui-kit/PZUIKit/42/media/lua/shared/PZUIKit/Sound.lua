-- The one place a mod's sounds come from (SOUND-SYSTEM.md): every sound is asked for by a cue ("oa.comms.in"), and a
-- mod's table says which of the game's sounds a cue is (a vanilla one, or a mod's own from its sound scripts) and how
-- often it may sound (`gap`, ms). Changing a sound, or putting in a new one, is a line of that table.
--
-- Sound.name(cue) is the game's sound for a cue now (nil: no such cue, or still within its gap); the helpers play it
-- the common ways: on the screen (ui), at a square (at), from a character (on). A sound that needs its own emitter (one
-- that moves, one whose volume rises) asks for the name and plays it itself. A timed action's sounds (Sound.timed),
-- typing (Sound.typed), a sound looped on the screen that stops with the game paused (Sound.loop), and the game's
-- sound turned down under a scene (Sound.duck) are here as well. What zombies hear (addSound) is a rule of the game, not a sound: not here.
PZUIKit = PZUIKit or {}
local Sound = {}
PZUIKit.Sound = Sound

local defs = {}     -- cue -> { sound = the game's sound name (nil: silent), gap = ms at least between two }
                    --   or { keyboard = id (its keys by the character), erase = true (its erasing key), gap }
local keyboards = {} -- id -> { letters = { names }, space = name, enter = name, back = name }
local lastAt = {}   -- cue -> the real time (ms) it last sounded
local told = {}     -- the cues asked for and not defined, said once

-- Defines a cue: { sound = name, gap = ms }. A table of them at once: Sound.defineAll({ [cue] = def, ... }).
function Sound.define(cue, def)
    defs[cue] = def
end

function Sound.defineAll(list)
    for cue, def in pairs(list) do defs[cue] = def end
end

function Sound.def(cue)
    return defs[cue]
end

local function clock()
    return getTimestampMs()
end

-- A keyboard: each key its own sound, picked by the character typed (the same character, the same key every time; a
-- space the space bar, a new line the return), and the one key that erases. `letters` are the game's sounds of the
-- letter keys, `space`, `enter`, `back` the others (each falls back to a letter key, the erasing one to the first).
function Sound.defineKeyboard(id, board)
    keyboards[id] = board
end

-- The game's sound of the key that types `char` (a string of one character; nil: the first letter key) on a keyboard,
-- or of its erasing key.
function Sound.keyOf(board, char, erase)
    local letters = board.letters
    if erase then return board.back or letters[1] end
    if char == " " then return board.space or letters[1] end
    if char == "\n" then return board.enter or letters[1] end
    local code = char and char ~= "" and string.byte(char) or 0
    -- spread by the golden ratio: a plain remainder put most Korean syllables (0xAC00 on in steps of 28) on two keys
    local spread = code * 0.6180339887
    return letters[math.floor((spread - math.floor(spread)) * #letters) + 1]
end

-- The game's sound for a cue now, `at` the real time (ms; now by default), `char` the character it is for (a keyboard's
-- cue): nil when the cue is not defined (said once), defined silent, or sounded less than its gap ago (a clock gone back
-- lets it sound).
function Sound.name(cue, at, char)
    local def = defs[cue]
    if not def then
        if not told[cue] then
            told[cue] = true
            print("[PZUIKit] sound: no cue " .. tostring(cue))
        end
        return nil
    end
    local board = def.keyboard and keyboards[def.keyboard]
    if not def.sound and not board then return nil end
    if def.gap then
        at = at or clock()
        local last = lastAt[cue]
        if last and at >= last and at - last < def.gap then return nil end
        lastAt[cue] = at
    end
    if board then return Sound.keyOf(board, char, def.erase) end
    return def.sound
end

-- On the screen (the game's UI sound): its id, or nil. `char`: a keyboard cue's character.
function Sound.ui(cue, char)
    local name = Sound.name(cue, nil, char)
    if not name then return nil end
    return getSoundManager():playUISound(name)
end

-- At a square, heard where it is; `here` only on this machine (a sound a server already sent each player).
function Sound.at(cue, square, here)
    local name = square and Sound.name(cue)
    if not name then return nil end
    if here then return square:playSoundLocal(name) end
    return square:playSound(name)
end

-- From a character (its emitter): the sound's id, or nil.
function Sound.on(cue, character)
    local name = character and Sound.name(cue)
    if not name then return nil end
    return character:playSound(name)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- A timed action's sounds, as the game's own actions make theirs: `during` from the character while it works (started
-- as it starts; stopped, or let ring out to its end, as it is done or stopped: stopOrTriggerSound), `done` on the
-- screen once it is done (the game's furniture taken up or put down: ISMoveablesAction). Each a cue, nil, or a
-- function of the action giving one (nil: none). Called once the class has its own start, stop and perform (at the end
-- of its file): it wraps them.
local function cueOf(cue, action)
    if type(cue) == "function" then return cue(action) end
    return cue
end

local function quiet(action)
    local id = action.kitSound
    action.kitSound = nil
    if id and id ~= 0 then action.character:stopOrTriggerSound(id) end
end

function Sound.timed(class, during, done)
    local start, stop, perform = class.start, class.stop, class.perform
    function class:start()
        start(self)
        local cue = cueOf(during, self)
        if cue then self.kitSound = Sound.on(cue, self.character) end
    end
    function class:stop()
        quiet(self)
        stop(self)
    end
    function class:perform()
        quiet(self)
        local cue = cueOf(done, self)
        if cue then Sound.ui(cue) end
        perform(self)
    end
end

-- Characters `from`+1 to `to` came on (typed, printed, erased: counts either way): one sound for them, within the
-- cue's gap; `char` the last of them (a keyboard cue's key is that character's). More than TYPED_JUMP at once is a jump
-- (a click brought the text on), not typing: no sound.
Sound.TYPED_JUMP = 8
function Sound.typed(cue, from, to, char)
    local n = math.abs((to or 0) - (from or 0))
    if n == 0 or n > Sound.TYPED_JUMP then return nil end
    return Sound.ui(cue, char)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- A sound looped on the screen while its owner wants it (the static under a call): it stops while the game is paused
-- and comes back as the game goes on (the game's own pause stops what it plays; ours must not go on over it).

local loops = {}    -- owner -> { cue, id (nil while held) }
local looping = false

-- Whether the game is paused now (the game's own answer; a test sets Sound.paused).
function Sound.paused()
    return isGamePaused()
end

local function start(loop)
    local name = Sound.name(loop.cue)
    loop.id = name and getSoundManager():playUISound(name) or nil
end

local function halt(loop)
    if loop.id then getSoundManager():stopUISound(loop.id) end
    loop.id = nil
end

-- Each frame the UI draws (it does while paused) while a loop is on: held while paused, back after.
function Sound.follow()
    local paused = Sound.paused()
    local any = false
    for _, loop in pairs(loops) do
        any = true
        if paused and loop.id then
            halt(loop)
            loop.held = true
        elseif not paused and loop.held then
            loop.held = nil
            start(loop)
        end
    end
    if not any and looping then
        looping = false
        Events.OnPreUIDraw.Remove(Sound.follow)
    end
end

function Sound.loop(owner, cue)
    if loops[owner] then return end
    local loop = { cue = cue }
    loops[owner] = loop
    if Sound.paused() then loop.held = true else start(loop) end
    if not looping then
        looping = true
        Events.OnPreUIDraw.Add(Sound.follow)
    end
end

function Sound.unloop(owner)
    local loop = loops[owner]
    if not loop then return end
    halt(loop)
    loops[owner] = nil
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The game's sound and ambience turned down (to `share` of the player's own settings) while any owner holds it, and
-- back to the settings once none does. Only the sound manager's volumes: the player's options are not touched.

Sound.DUCK = 0.5
local duckers = {}

local function applyDuck()
    local share = 1
    for _, s in pairs(duckers) do
        if s < share then share = s end
    end
    local sm, core = getSoundManager(), getCore()
    sm:setSoundVolume(core:getOptionSoundVolume() / 10 * share)
    sm:setAmbientVolume(core:getOptionAmbientVolume() / 10 * share)
end

function Sound.duck(owner, on, share)
    local was = duckers[owner]
    duckers[owner] = on and (share or Sound.DUCK) or nil
    if was ~= duckers[owner] then applyDuck() end
end

-- The game's sound of a cue as it is defined (no gap counted, nothing said): for a control that keeps a sound name
-- itself (the game's button plays its `sounds.activate`).
function Sound.soundOf(cue)
    local def = defs[cue]
    return def and def.sound or nil
end

-- A title's sounds for the API's text.title (spec.sounds, spec.subtitleSounds): the game's sounds of the cues
-- `kit.title.<style>.<moment>` and `kit.title.<style>.line.<moment>`, the moments enter (it starts to come in), land (it
-- has come in: a stamp's hit) and leave; each nil where no moment has a sound.
local MOMENTS = { "enter", "land", "leave" }
local function momentSounds(base)
    local sounds
    for _, moment in ipairs(MOMENTS) do
        local name = Sound.soundOf(base .. moment)
        if name then
            sounds = sounds or {}
            sounds[moment] = name
        end
    end
    return sounds
end

function Sound.titleSounds(style)
    return momentSounds("kit.title." .. style .. "."), momentSounds("kit.title." .. style .. ".line.")
end

-- The kit's own cues: a list's item chosen (a combo's, a menu's), a button pressed; the titles' moments by the API's
-- styles (no sound yet: the cues are the places the sounds go).
Sound.defineAll({
    ["kit.select"] = { sound = "UISelectListItem" },
    ["kit.press"] = { sound = "UIActivateButton" },
})

-- The kit's keyboard: an old terminal's (IBM's buckling springs of the 1980s; tools/sound, sounds.json).
Sound.defineKeyboard("kit.terminal", {
    letters = { "KIT_Key_1", "KIT_Key_2", "KIT_Key_3", "KIT_Key_4", "KIT_Key_5", "KIT_Key_6", "KIT_Key_7", "KIT_Key_8" },
    space = "KIT_KeySpace", enter = "KIT_KeyEnter", back = "KIT_KeyBack",
})
for _, style in ipairs({ "stamp", "discovery", "notice", "unveil", "dust", "bleed", "sink", "type", "pulse", "brief" }) do
    for _, moment in ipairs(MOMENTS) do
        Sound.define("kit.title." .. style .. "." .. moment, {})
        Sound.define("kit.title." .. style .. ".line." .. moment, {})
    end
end

return Sound
