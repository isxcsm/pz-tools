-- Texts held where they cannot be seen (PZExtAPI.text; Texts.java): a text with a 2 s hold is shown, then held in turn by
-- sleep, the player's screen faded dark and the game's menu (Escape), each for 3 s; it is still shown after each, and goes
-- once it was in sight about 2 s in all. Run in a test save with `pzdev.py file` (--follow 15): "[textholds]" lines over
-- about 13 seconds, ending with "done: N BAD". The player wakes and the menu closes at the end.
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
local key
local function shown() return text.shown(handle, key) end

-- Each step waits its milliseconds after the one before, then runs; the frames drive it (they go on in the menu, where the
-- game's ticks stand).
local steps = {
    { 0, function() key = text.show(handle, { text = "Held", hold = 2.0 }) end },
    { 500, function()
        check("shown", shown())
        player:setAsleep(true)
    end },
    { 3000, function()
        player:setAsleep(false)
        check("kept through sleep", shown())
    end },
    { 300, function() UIManager.FadeOut(0, 0.1) end },
    { 3000, function()
        check("the screen dark", UIManager.getFadeAlpha(0) > 0.5, UIManager.getFadeAlpha(0))
        UIManager.FadeIn(0, 0.1)
    end },
    { 400, function()
        check("kept through the dark", shown())
        ToggleEscapeMenu(menuKey)
        check("the menu over the game", MainScreen.instance:isVisible())
    end },
    { 3000, function()
        ToggleEscapeMenu(menuKey)
        check("kept through the menu", shown())
    end },
    { 2500, function()
        check("gone after its time in sight", not shown())
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
