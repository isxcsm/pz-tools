-- Operation Acorn: a research team on the radio trades with the player for what they gather, and pays in credits,
-- trust, upgrades and supplies. This file holds what every part shares: the name, the log, the API, time and options.
OperationAcorn = OperationAcorn or {}
local OA = OperationAcorn

OA.MOD = "OperationAcorn"
-- Every key this mod keeps in a save (global ModData, player and object modData) starts with this.
OA.PREFIX = "OA_"
OA.API_VERSION = 1

function OA.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[OperationAcorn] " .. table.concat(parts, " "))
end

-- The extension API, or nil with the reason it is missing: PZ Tools not installed in startup mode, or another
-- version. Without it the mod changes nothing and only explains (DESIGN 2).
function OA.api()
    local api = PZToolsAPI
    if type(api) ~= "table" or type(api.client) ~= "function" then return nil, "missing" end
    if api.version ~= OA.API_VERSION then return nil, "version" end
    return api
end

-- This mod's handle: every declaration to the API goes through it.
function OA.handle()
    local api = OA.api()
    return api and api.client(OA.MOD) or nil
end

-- A sandbox option by name (media/sandbox-options.txt, page OperationAcorn...).
function OA.option(name)
    local vars = SandboxVars and SandboxVars.OperationAcorn
    return vars and vars[name]
end

-- Time. The world age in hours is the clock every record uses: it grows while the game runs and is saved.
function OA.hours()
    return getGameTime():getWorldAgeHours()
end

-- A real-time throttle for work that follows no game time. The game-time events fire many times a real second when
-- the game is fast-forwarded or everyone sleeps (ten game minutes are 25 s at the default day length, some 0.6 s at
-- x40), so such work keeps to real time instead. `last` is the caller's table of the real time (ms) each key was last
-- due, `now` is getTimestampMs(). True, and `now` noted, when `ms` have passed since the key was last due, the key
-- never was, or the clock went back. Only subtraction on the timestamps: Kahlua's % is wrong at their size.
function OA.due(last, key, now, ms)
    local at = last[key]
    if at and now >= at and now - at < ms then return false end
    last[key] = now
    return true
end

-- The game day a world age falls on: day 0 is the world's first (partial) day, and the day changes at 00:00.
function OA.day(hours)
    local now = OA.hours()
    -- The hour of day at world age 0.
    local start = OA.remainder(getGameTime():getTimeOfDay() - now, 24)
    return math.floor(((hours or now) + start) / 24 + 1e-6)
end

-- The week a day falls in (weeks of seven days from day 0): the request list changes with it.
function OA.week(day)
    return math.floor((day or OA.day()) / 7)
end

-- A whole random number from a to b, both included; or from 0 to a - 1 with one argument (as ZombRand).
function OA.random(a, b)
    if b == nil then return ZombRand(a) end
    return ZombRand(a, b + 1)
end

-- A random number from a to b.
function OA.randomFloat(a, b)
    return ZombRandFloat(a, b)
end

-- Rounds half away from zero, for the one rounding a settlement does (NUMBERS 1).
function OA.round(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

-- The vehicles of the loaded cell, as a list Lua can index. B42's IsoCell.getVehicles() is a Set, which has no get(i)
-- (found in game: "tried to call nil"); the vehicles are copied into `into` (a reused ArrayList) or a new one.
function OA.vehicles(into)
    local list = into or ArrayList.new()
    list:clear()
    local cell = getCell()
    if cell then list:addAll(cell:getVehicles()) end
    return list
end

-- Searching the inventory or a container (the *Recurse calls, a loop over getItems()) is never done while a right-click
-- menu is built, every tick or frame, or at every refresh of a screen: a mod that raises the bag capacity lets a player
-- carry thousands of items, and such a search can freeze the game. The ways out, in this order: act on the item the
-- player clicked; look once when the player commits to an action (a button, the start of a timed action); or keep
-- the answer under a cheap signature of the container, below. tools/check_translations.py looks for the searches.

-- A short text that changes when what a container holds changes: how many items lie in it and what they weigh (a bag
-- weighs what is in it, so a change inside a bag shows too). Both are one call into the game, not a search.
function OA.signature(container)
    return tostring(container:getItems():size()) .. "|" .. tostring(container:getContentsWeight())
end

-- Whether an item is in a character's inventory, at any depth of bags: the item's container and the bag that holds
-- that container, upward, until the inventory (a few steps; the inventory is not searched).
function OA.inInventory(item, character)
    if not item or not character then return false end
    local inventory = character:getInventory()
    local container = item:getContainer()
    for _ = 1, 20 do
        if not container then return false end
        if container == inventory then return true end
        local holder = container:getContainingItem()
        container = holder and holder:getContainer() or nil
    end
    return false
end

-- Whether a table has no entries. The game's Lua has no next(), so this is a pairs loop that stops at once.
function OA.isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

function OA.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

-- A curve fast at first that settles at the end (a cubic; u from 0 to 1, held at 0 and 1 outside it).
function OA.easeOut(u)
    if u <= 0 then return 0 end
    if u >= 1 then return 1 end
    local v = 1 - u
    return 1 - v * v * v
end

-- ---- text that fits (the one cut and the one wrap the windows share) ---------------------------------------------
-- `measure(string, arg)` is the caller's width (design units, pixels, characters); `arg` is passed on to it (a font).

-- The start of `text` (at least one character) that, with "..." after it, is no wider than width + eps.
function OA.cutFor(text, width, measure, eps, arg)
    width = width + (eps or 0)
    local cut = text
    while #cut > 1 and measure(cut .. "...", arg) > width do
        cut = string.sub(cut, 1, #cut - 1)
    end
    return cut
end

-- The text whole when it is no wider than width + eps, else cut with "..." at the end.
function OA.fitText(text, width, measure, eps, arg)
    if measure(text, arg) <= width + (eps or 0) then return text end
    return OA.cutFor(text, width, measure, eps, arg) .. "..."
end

-- A text broken into lines no wider than `limit` (+ opts.eps) at its spaces. opts (all optional):
--   paragraphs: "\n" ends a line, a blank paragraph is an empty line (else the line ends are spaces);
--   breakWords: a word wider than a line is cut between letters (else it stays whole on a line of its own);
--   maxLines: at most that many lines, the last ending in "..." where text was left.
function OA.wrap(text, limit, measure, opts, arg)
    local eps = opts and opts.eps or 0
    local paragraphs = opts and opts.paragraphs
    local breakWords = opts and opts.breakWords
    local max = limit + eps
    local lines = {}
    -- a word wider than a line cut between letters: the lines it fills, and what is left of it
    local function cutWord(word)
        while #word > 1 and measure(word, arg) > max do
            local k = #word - 1
            while k > 1 and measure(string.sub(word, 1, k), arg) > max do k = k - 1 end
            lines[#lines + 1] = string.sub(word, 1, k)
            word = string.sub(word, k + 1)
        end
        return word
    end
    local function paragraph(para)
        local line
        for word in string.gmatch(para, "%S+") do
            local longer = line and (line .. " " .. word) or word
            if line and measure(longer, arg) > max then
                lines[#lines + 1] = line
                line = breakWords and cutWord(word) or word
            elseif line == nil and breakWords then
                line = cutWord(word)
            else
                line = longer
            end
        end
        if line ~= nil then
            lines[#lines + 1] = line
        elseif paragraphs then
            lines[#lines + 1] = ""
        end
    end
    text = text or ""
    if paragraphs then
        for para in string.gmatch(text .. "\n", "(.-)\n") do paragraph(para) end
    else
        paragraph(text)
    end
    local most = opts and opts.maxLines
    if most and #lines > most then
        while #lines > most do table.remove(lines) end
        lines[#lines] = OA.cutFor(lines[#lines], limit, measure, 0, arg) .. "..."
    end
    return lines
end

-- The widest line of an item's tooltip text, in pixels of the small font (about the width of the game's own).
OA.TOOLTIP_WIDTH = 330

-- Text already translated, made ready for InventoryItem:setTooltip. The item tooltip is one plain label: a <LINE>
-- becomes a new line, a line wider than OA.TOOLTIP_WIDTH is wrapped at its spaces (on the client, where the font is
-- measured), and a % is doubled (the game formats the text again when it draws it: a % left by getText, as 10%% in a
-- translation, would be read as a format code and throw).
function OA.tooltipText(text)
    local measure = getTextManager and UIFont and function(s) return getTextManager():MeasureStringX(UIFont.Small, s) end
    local out = {}
    for line in string.gmatch(text .. "<LINE>", "(.-)<LINE>") do
        line = string.match(line, "^%s*(.-)%s*$")
        if not measure or measure(line) <= OA.TOOLTIP_WIDTH then
            out[#out + 1] = line
        else
            for _, part in ipairs(OA.wrap(line, OA.TOOLTIP_WIDTH, measure)) do out[#out + 1] = part end
        end
    end
    return (string.gsub(table.concat(out, "\n"), "%%", "%%%%"))
end

-- Kahlua's % gives wrong results for negative numbers and for large values such as getTimestampMs(): this is the
-- remainder with the sign of b.
function OA.remainder(a, b)
    return a - math.floor(a / b) * b
end

return OA
