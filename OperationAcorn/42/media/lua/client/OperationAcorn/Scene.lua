-- The radio scenes (DESIGN-terminal 14 F2, story-improvements 8): when the first contact comes, a trust stage or milestone
-- is entered, or the department is handed over, the radio lines of that copy are typed over the game, a character at a time
-- with the pauses their translation marks, by the extension API's text (PZToolsAPI.text.show with enter = "type": the
-- Java side draws it, no Lua runs per character). They come after the stage's title. An API from before typing refuses
-- the typed spec; the scene is then shown plain, whole, in rows of its own breaking. Without the API's text there is no
-- scene; the copy is in the terminal's folder in any case.
require "OperationAcorn/Client"
require "OperationAcorn/Titles"
require "OperationAcorn/Markup"
local OA = OperationAcorn
local Scene = {}
OA.Scene = Scene

-- How the scene looks: the radio's green, left-aligned in the middle half of the screen, under the title. The speed is
-- the story scenes' (25 to 30 characters a second, Typing.SPEED).
Scene.SPEED = 28
Scene.COLOR = { 0.65, 0.85, 0.65, 1 }
Scene.FONT = { "SdfRegular", "Medium" }
-- The plain scene (the API from before has no width to fit) is broken to this share of the screen's width, in at most
-- this many rows.
Scene.PLAIN_WIDTH = 0.5
Scene.PLAIN_ROWS = 8
Scene.SIZE = 0.034

-- The scene's lines, translated, as the strings with their markup.
function Scene.lines(detail)
    local lines = {}
    for _, key in ipairs(detail.keys or {}) do
        lines[#lines + 1] = getText("IGUI_OA_Story_Radio_" .. key, detail.number)
    end
    return lines
end

-- How wide a row of the plain scene may be, and how a row is measured: in the pixels of the Medium font at the zoom that
-- makes its lines the size of the scene's.
function Scene.measure()
    local manager = getTextManager()
    local zoom = Scene.SIZE * getCore():getScreenHeight() / manager:getFontHeight(UIFont.Medium)
    local limit = Scene.PLAIN_WIDTH * getCore():getScreenWidth() / zoom
    return function(row) return manager:MeasureStringX(UIFont.Medium, row) end, limit
end

-- The plain show's rows: the lines without markup, broken to the width, one after another.
function Scene.plainRows(lines, measure, limit)
    local rows = {}
    for _, line in ipairs(lines) do
        for _, row in ipairs(OA.Markup.wrap(OA.Markup.strip(line), limit, measure)) do
            if row ~= "" and #rows < Scene.PLAIN_ROWS then rows[#rows + 1] = row end
        end
    end
    return rows
end

-- The typed spec for a text on a screen.
function Scene.typedSpec(text, player)
    return {
        text = text, enter = "type", speed = Scene.SPEED, cursor = true, markup = true, width = 0.5, align = "left",
        x = 0.25, y = 0.72, font = Scene.FONT, size = Scene.SIZE, color = Scene.COLOR, shadow = true, hold = 5,
        leave = "fade", leaveTime = 1.2, queue = true, player = player,
    }
end

-- What an API from before typing takes.
function Scene.plainSpec(rows, player)
    return {
        text = table.concat(rows, "\n"), enter = "fade", enterTime = 0.6, align = "left", x = 0.25, y = 0.72,
        font = Scene.FONT, size = Scene.SIZE, color = Scene.COLOR, shadow = true, hold = 8, leave = "fade", leaveTime = 1.2,
        queue = true, player = player,
    }
end

-- Shows the scene (detail as OA.Sync.scene takes it) to the player of that id; returns how: "typed", "plain" or nil.
function Scene.show(playerId, detail)
    if type(detail) ~= "table" then return nil end
    local t = OA.Titles.textApi()
    local handle = t and OA.handle()
    if not (handle and type(t.show) == "function") then return nil end
    local lines = Scene.lines(detail)
    if #lines == 0 then return nil end
    local text = table.concat(lines, "\n\n")
    local shown
    for _, character in ipairs(OA.Titles.charactersOf(playerId)) do
        local player = character:getPlayerNum()
        local ok, err = pcall(t.show, handle, Scene.typedSpec(text, player))
        if ok then
            shown = shown or "typed"
        else
            -- An older API refuses the typed spec: the plain scene instead.
            local measure, limit = Scene.measure()
            local plain
            plain, err = pcall(t.show, handle, Scene.plainSpec(Scene.plainRows(lines, measure, limit), player))
            if plain then shown = shown or "plain" else OA.log("scene:", tostring(err)) end
        end
    end
    return shown
end

OA.Sync.listen("scene", Scene.show)

return Scene
