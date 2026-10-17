-- Texts where they cannot be seen (PZExtAPI.text; Texts.java). Sleep, its screen faded black: a text shown before plays on
-- in real time over the black and goes after its 2 s; one shown while asleep starts only once the player woke and the
-- screen is light again. The game's menu (Escape): a text's time stands while it is over the game. Run in a test save with
-- `pzdev.py file` (--follow 14); a picture taken about 1.3 s in shows the first text over the black. "[textholds]" lines
-- over about 11 seconds, ending with "done: N BAD". The player wakes and the menu closes by the end.
local function say(...) print("[textholds]", ...) end
local bad = 0
local function check(what, ok, got)
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", what, got ~= nil and tostring(got) or "")
end

local text = PZExtAPI.text
local handle = PZExtAPI.client("TextHolds")
local player = getPlayer()
local menuKey = getCore():getKey(KeybindId.MAIN_MENU)
if menuKey == 0 then menuKey = Keyboard.KEY_ESCAPE end
local before, during, held
local function shown(key) return text.shown(handle, key) end

-- Each step waits its milliseconds after the one before, then runs; the frames drive it (they go on in the menu, where the
-- game's ticks stand).
local steps = {
    { 0, function() before = text.show(handle, { text = "Before sleep", hold = 2.0 }) end },
    { 500, function()
        check("shown", shown(before))
        player:setAsleep(true)
        UIManager.FadeOut(0, 0.3)
    end },
    { 1000, function()
        check("the screen dark", UIManager.getFadeAlpha(0) > 0.99, UIManager.getFadeAlpha(0))
        check("plays on in the dark", shown(before))
        during = text.show(handle, { text = "While asleep", hold = 1.0 })
    end },
    { 1000, function() check("over after its time, dark or not", not shown(before)) end },
    { 1500, function()
        check("waits while asleep", shown(during))
        player:setAsleep(false)
        UIManager.FadeIn(0, 0.3)
    end },
    { 400, function() check("shown after waking", shown(during)) end },
    { 500, function() check("not started before waking", shown(during)) end },
    { 600, function()
        check("then over", not shown(during))
        held = text.show(handle, { text = "Menu", hold = 2.0 })
    end },
    { 500, function()
        ToggleEscapeMenu(menuKey)
        check("the menu over the game", MainScreen.instance:isVisible())
    end },
    { 3000, function()
        ToggleEscapeMenu(menuKey)
        check("kept through the menu", shown(held))
    end },
    { 2500, function()
        check("gone after its time in sight", not shown(held))
        say("done: " .. bad .. " BAD")
    end },
}

local step, last = 1, getTimestampMs()
TEXTHOLDS_FRAME = function()
    local due = steps[step]
    if not due or getTimestampMs() - last < due[1] then return end
    last = getTimestampMs()
    step = step + 1
    local ok, err = pcall(due[2])
    if not ok then say("ERROR", tostring(err)) say("done: 1 BAD") step = #steps + 1 end
end
-- Added once (a handler taken out while the event runs costs the next one its call); a run again replaces the function.
if not TEXTHOLDS_HOOKED then
    TEXTHOLDS_HOOKED = true
    Events.OnPostUIDraw.Add(function() if TEXTHOLDS_FRAME then TEXTHOLDS_FRAME() end end)
end
