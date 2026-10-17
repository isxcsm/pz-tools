-- Texts where they cannot be seen (PZExtAPI.text; Texts.java). Sleep, its screen faded black: a text shown before plays on
-- in real time over the black and goes after its 2 s; one shown while asleep starts only once the player woke and the
-- screen is light again. The game paused (speed 0) and its menu (Escape): a text's time stands. Run in a test save with
-- `pzdev.py file` (it returns on the last line); a picture taken about 1.3 s in shows the first text over the black, one
-- about 8 s in the typing stopped. "[textholds]" lines over about 18 seconds, ending with "done: N BAD" (the dev channel's
-- STEPS). The player wakes, the game goes on and the menu closes by the end.
local t = STEPS("textholds")
local check = t.check

local text = PZExtAPI.text
local handle = PZExtAPI.client("TextHolds")
local player = getPlayer()
local menuKey = getCore():getKey(KeybindId.MAIN_MENU)
if menuKey == 0 then menuKey = Keyboard.KEY_ESCAPE end
local before, during, stood, held
local function shown(key) return text.shown(handle, key) end

t.run({
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
        stood = text.show(handle, { text = "Paused here", enter = "type", speed = 12, hold = 2.0 })
    end },
    { 300, function()
        setGameSpeed(0)
        check("the game paused", isGamePaused())
    end },
    { 3000, function()
        setGameSpeed(1)
        check("kept through the pause", shown(stood))
    end },
    { 3000, function()
        check("gone after its time unpaused", not shown(stood))
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
    { 2500, function() check("gone after its time in sight", not shown(held)) end },
})
