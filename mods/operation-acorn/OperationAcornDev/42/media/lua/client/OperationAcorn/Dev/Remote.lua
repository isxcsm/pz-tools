-- Debug only: a command channel for driving the running game from outside (mods/tools/pzdev.py), so a check never types
-- into the Lua console (whose focus and completion popup lose keys, and whose keys leak into the game when it is
-- closed). The tool writes Zomboid/Lua/oadev/cmd.lua, its first line "--#<id>"; a new id runs once, its print lines
-- caught, and Zomboid/Lua/oadev/out.txt gets "#<id>", the lines, then "ok" or "error: <message>". The file's first
-- line is read four times a second, also while the game is paused. Nothing of this loads without -debug.
--
-- It also defines the loaders the in-game checks use: LD(path) reads a file under Zomboid/Lua, RUN(file) runs one of
-- tests/ingame (Zomboid/Lua/oa), RUNX(file) one of Zomboid/Lua/oax (scratch scripts).
if not isDebugEnabled() then return end
require "OperationAcorn/Core"
local OA = OperationAcorn
local Remote = {}
OA.Remote = Remote

local CMD, OUT = "oadev/cmd.lua", "oadev/out.txt"
local EVERY_MS = 250

function LD(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local lines = {}
    local line = reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return table.concat(lines, "\n")
end

local function runFile(path)
    local text = LD(path)
    if not text then error("no file " .. path, 2) end
    local chunk, err = loadstring(text, path)
    if not chunk then error(err, 2) end
    return chunk()
end

function RUN(file) return runFile("oa/" .. file) end
function RUNX(file) return runFile("oax/" .. file) end

-- An in-game check in timed steps, for any mod's tests: local t = STEPS("tag"), then t.run({ { ms, fn }, ... }): each
-- step waits its milliseconds after the one before, then runs; the frames drive it (also paused, and under the game's
-- menu, where the ticks stand). t.say(...) prints a "[tag]" line, t.check(what, ok, got) an "ok"/"BAD" one; the run
-- ends with "[tag] done: N BAD" (pzdev.py check/file return on that line). A step that fails ends it with "ERROR".
local stepsFrame
function STEPS(tag)
    local t = { bad = 0 }
    function t.say(...) print("[" .. tag .. "]", ...) end
    function t.check(what, ok, got)
        if not ok then t.bad = t.bad + 1 end
        t.say(ok and "ok" or "BAD", what, got ~= nil and tostring(got) or "")
    end
    function t.run(steps)
        local step, last = 1, getTimestampMs()
        stepsFrame = function()
            local due = steps[step]
            if not due then return end
            if getTimestampMs() - last < due[1] then return end
            last = getTimestampMs()
            step = step + 1
            local ok, err = pcall(due[2])
            if not ok then t.say("ERROR", tostring(err)) t.bad = t.bad + 1 step = #steps + 1 end
            if step > #steps then t.say("done: " .. t.bad .. " BAD") stepsFrame = nil end
        end
    end
    return t
end
Events.OnPostUIDraw.Add(function() if stepsFrame then stepsFrame() end end)

local function firstLine(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local line = reader:readLine()
    reader:close()
    return line
end

local function write(id, lines)
    local writer = getFileWriter(OUT, true, false)
    writer:write("#" .. id .. "\n")
    for _, line in ipairs(lines) do writer:write(line .. "\n") end
    writer:close()
end

-- Runs a command text with print caught; returns its lines (the last one "ok" or "error: ...").
function Remote.run(text)
    local lines = {}
    local basePrint = print
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        lines[#lines + 1] = table.concat(parts, "\t")
        basePrint(...)
    end
    local chunk, err = loadstring(text, "pzdev")
    local ok
    if chunk then ok, err = pcall(chunk) end
    print = basePrint
    lines[#lines + 1] = (chunk and ok) and "ok" or ("error: " .. tostring(err))
    return lines
end

local function idOf(head)
    return head and string.match(head, "^%-%-#(%S+)")
end

-- a command left from an earlier session is not run again: only ids written after this loaded count
local lastId = idOf(firstLine(CMD))
local nextAt
local function poll()
    local now = getTimestampMs()
    if nextAt and now < nextAt then return end
    nextAt = now + EVERY_MS
    local id = idOf(firstLine(CMD))
    if not id or id == lastId then return end
    lastId = id
    write(id, Remote.run(LD(CMD) or ""))
end

Events.OnTickEvenPaused.Add(poll)

-- The game paused or going again, logged as it changes ("[pzdev] paused" / "[pzdev] running": pzdev.py watch reports
-- them), looked at once a second. A driven test does not stop when the window loses focus: pzdev.py starts the game
-- with that option off in options.ini and puts the user's value back as the game ends (set here at run time, the
-- game would save it into the user's options).
local paused, pausedAt = nil, nil
local function watchPause()
    local now = getTimestampMs()
    if pausedAt and now < pausedAt then return end
    pausedAt = now + 1000
    local is = isGamePaused() == true
    if is ~= paused then
        if paused ~= nil or is then print(is and "[pzdev] paused" or "[pzdev] running") end
        paused = is
    end
end
Events.OnTickEvenPaused.Add(watchPause)

-- A Lua error does not stop the game in the debugger (the debug tool bar's Break On Error, ticked again at every game
-- start): a command's error comes back as "error: ...", any other is in the log ("Exception thrown", what pzdev.py
-- watch reports), and nothing waits on a Resume press. Tick it again in the tool bar to step through an error.
UIManager.setShowLuaDebuggerOnError(false)
Events.OnGameStart.Add(function() UIManager.setShowLuaDebuggerOnError(false) end)
