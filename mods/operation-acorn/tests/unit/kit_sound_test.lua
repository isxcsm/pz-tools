-- The UI kit's one place for sounds (PZUIKit/Sound, SOUND-SYSTEM.md): a cue's game sound and its gap, an undefined cue
-- said once, typing (a jump is not typing), a loop held while the game is paused, the game's sound turned down while
-- any owner holds it.
require "PZUIKit/Sound"
local Sound = PZUIKit.Sound

local ms, played, stopped, said, volumes, events
local function game()
    ms = 1000
    getTimestampMs = function() return ms end
    played, stopped, said, volumes, events = {}, {}, {}, {}, { added = 0, removed = 0 }
    local ids = 0
    getSoundManager = function()
        return {
            playUISound = function(_, name) ids = ids + 1; played[#played + 1] = name; return ids end,
            stopUISound = function(_, id) stopped[#stopped + 1] = id end,
            setSoundVolume = function(_, v) volumes.sound = v end,
            setAmbientVolume = function(_, v) volumes.ambient = v end,
        }
    end
    getCore = function()
        return { getOptionSoundVolume = function() return 8 end, getOptionAmbientVolume = function() return 6 end }
    end
    Events.OnPreUIDraw = { Add = function() events.added = events.added + 1 end,
        Remove = function() events.removed = events.removed + 1 end }
    Sound.paused = function() return false end
end

test("a cue is its game sound; a silent one and an undefined one are nothing, the undefined said once", function()
    game()
    Sound.defineAll({ ["t.a"] = { sound = "A" }, ["t.silent"] = {} })
    eq(Sound.name("t.a"), "A")
    eq(Sound.name("t.silent"), nil)
    local realPrint = print
    print = function(s) said[#said + 1] = s end
    eq(Sound.name("t.none"), nil)
    eq(Sound.name("t.none"), nil)
    print = realPrint
    eq(#said, 1)
    eq(Sound.soundOf("t.a"), "A")
    eq(Sound.soundOf("kit.press"), "UIActivateButton", "the kit's own")
end)

test("a cue with a gap sounds once within it, again after it; a clock gone back lets it", function()
    game()
    Sound.define("t.gap", { sound = "G", gap = 50 })
    eq(Sound.name("t.gap"), "G")
    ms = ms + 30
    eq(Sound.name("t.gap"), nil)
    ms = ms + 30
    eq(Sound.name("t.gap"), "G")
    ms = ms - 500
    eq(Sound.name("t.gap"), "G")
end)

test("typing: characters that came sound once, none or a jump do not", function()
    game()
    Sound.define("t.key", { sound = "K" })
    Sound.typed("t.key", 3, 3)
    Sound.typed("t.key", 3, 3 + Sound.TYPED_JUMP + 1)
    eq(#played, 0)
    Sound.typed("t.key", 3, 5)
    Sound.typed("t.key", 9, 7)
    eq(table.concat(played, " "), "K K", "typed, and erased")
end)

test("a keyboard: a character always its own key, a space the bar, a new line the return, the erasing one key", function()
    game()
    Sound.defineKeyboard("t.board", { letters = { "L1", "L2", "L3" }, space = "SP", enter = "EN", back = "BK" })
    Sound.defineAll({ ["t.type"] = { keyboard = "t.board" }, ["t.erase"] = { keyboard = "t.board", erase = true } })
    local a = Sound.name("t.type", nil, "a")
    eq(Sound.name("t.type", nil, "a"), a, "the same character, the same key")
    local spread = string.byte("a") * 0.6180339887
    eq(a, ({ "L1", "L2", "L3" })[math.floor((spread - math.floor(spread)) * 3) + 1])
    truthy(Sound.name("t.type", nil, "b") ~= a, "the next character another key")
    eq(Sound.name("t.type", nil, " "), "SP")
    eq(Sound.name("t.type", nil, "\n"), "EN")
    eq(Sound.name("t.type", nil, nil), "L1", "no character: the first letter key")
    eq(Sound.name("t.erase", nil, "a"), "BK")
    eq(Sound.name("t.erase", nil, " "), "BK", "erasing is the one key whatever goes")
    Sound.typed("t.type", 0, 1, " ")
    Sound.typed("t.erase", 5, 4, "x")
    eq(table.concat(played, " "), "SP BK", "typed through the keyboard")
    -- a keyboard without its own space, return or erasing key: a letter key
    Sound.defineKeyboard("t.plain", { letters = { "P" } })
    Sound.define("t.plainErase", { keyboard = "t.plain", erase = true })
    eq(Sound.name("t.plainErase"), "P")
end)

test("the kit's terminal keyboard names its keys", function()
    game()
    Sound.define("t.kit", { keyboard = "kit.terminal" })
    eq(Sound.name("t.kit", nil, " "), "KIT_KeySpace")
    eq(Sound.name("t.kit", nil, "\n"), "KIT_KeyEnter")
    truthy(string.find(Sound.name("t.kit", nil, "q"), "^KIT_Key_%d$") ~= nil)
end)

test("a loop plays while its owner wants it, stops while the game is paused and comes back, and is let go", function()
    game()
    Sound.define("t.loop", { sound = "L" })
    local paused = false
    Sound.paused = function() return paused end
    Sound.loop("owner", "t.loop")
    Sound.loop("owner", "t.loop")
    eq(table.concat(played, " "), "L", "once for an owner")
    eq(events.added, 1)
    paused = true
    Sound.follow()
    eq(#stopped, 1, "stopped with the pause")
    Sound.follow()
    eq(#stopped, 1)
    paused = false
    Sound.follow()
    eq(table.concat(played, " "), "L L", "back as the game goes on")
    Sound.unloop("owner")
    eq(#stopped, 2)
    Sound.follow()
    eq(events.removed, 1, "nothing looped: no more frames followed")
    -- started while paused: it waits for the game
    paused = true
    Sound.loop("other", "t.loop")
    eq(#played, 2)
    paused = false
    Sound.follow()
    eq(#played, 3)
    Sound.unloop("other")
end)

test("the game's sound is turned down while any owner holds it, to the lowest share, and back after the last", function()
    game()
    Sound.duck("a", true, 0.5)
    near(volumes.sound, 0.4, 1e-9)
    near(volumes.ambient, 0.3, 1e-9)
    Sound.duck("b", true, 0.25)
    near(volumes.sound, 0.2, 1e-9)
    Sound.duck("b", false)
    near(volumes.sound, 0.4, 1e-9)
    Sound.duck("a", false)
    near(volumes.sound, 0.8, 1e-9)
    near(volumes.ambient, 0.6, 1e-9)
end)

test("at a square and from a character: the cue's sound, here only when asked", function()
    game()
    Sound.define("t.w", { sound = "W" })
    local square = { log = {} }
    function square:playSound(name) self.log[#self.log + 1] = "all " .. name end
    function square:playSoundLocal(name) self.log[#self.log + 1] = "here " .. name end
    Sound.at("t.w", square)
    Sound.at("t.w", square, true)
    Sound.at("t.w", nil)
    eq(table.concat(square.log, ","), "all W,here W")
    local character = { playSound = function(_, name) return name .. "!" end }
    eq(Sound.on("t.w", character), "W!")
end)

test("a timed action: its sound from the character while it works, stopped as it is stopped or done; done's on the screen", function()
    game()
    Sound.defineAll({ ["t.work"] = { sound = "Work" }, ["t.done"] = { sound = "Done" } })
    local calls = {}
    local function class()
        local c = {}
        function c:start() calls[#calls + 1] = "start" end
        function c:stop() calls[#calls + 1] = "stop" end
        function c:perform() calls[#calls + 1] = "perform" end
        return c
    end
    local stoppedIds = {}
    local function action(c, kind)
        local a = setmetatable({ kind = kind }, { __index = c })
        a.character = {
            playSound = function(_, name) played[#played + 1] = name; return 7 end,
            stopOrTriggerSound = function(_, id) stoppedIds[#stoppedIds + 1] = id end,
        }
        return a
    end
    local worked = class()
    Sound.timed(worked, "t.work", "t.done")
    local a = action(worked)
    a:start()
    eq(table.concat(played, " "), "Work")
    a:perform()
    eq(table.concat(played, " "), "Work Done", "done's sound once it is done")
    eq(table.concat(stoppedIds, " "), "7", "the work's sound stopped")
    eq(table.concat(calls, " "), "start perform", "the class's own still run")
    -- stopped midway: the work's sound stops, no done's
    local b = action(worked)
    b:start()
    b:stop()
    eq(table.concat(played, " "), "Work Done Work")
    eq(table.concat(stoppedIds, " "), "7 7")
    b:stop()
    eq(#stoppedIds, 2, "stopped once")
    -- by the action: a function giving the cue, or none
    local chosen = class()
    Sound.timed(chosen, function(x) return x.kind == "loud" and "t.work" or nil end)
    action(chosen, "quiet"):start()
    eq(#played, 3, "no cue: no sound")
    local c = action(chosen, "loud")
    c:start()
    c:perform()
    eq(table.concat(played, " "), "Work Done Work Work", "no done's cue: nothing more")
end)

test("a title's sounds: its style's moments that have a sound, the line's apart; none when no moment has one", function()
    game()
    eq(Sound.titleSounds("unveil"), nil, "a style whose cues are silent")
    Sound.define("kit.title.unveil.land", { sound = "Thud" })
    Sound.define("kit.title.unveil.line.land", { sound = "Tap" })
    local title, line = Sound.titleSounds("unveil")
    eq(title.land, "Thud")
    eq(title.enter, nil)
    eq(line.land, "Tap")
    Sound.define("kit.title.unveil.land", {})
    Sound.define("kit.title.unveil.line.land", {})
    -- the kit's own: the stamp's hit, the typewriter's run and feed
    title, line = Sound.titleSounds("stamp")
    eq(title.land, "KIT_TitleStamp")
    eq(line.land, "KIT_TitleStampLine")
    title = Sound.titleSounds("type")
    eq(title.enter, "KIT_TitleType")
    eq(title.leave, "KIT_TitleFeed")
end)
