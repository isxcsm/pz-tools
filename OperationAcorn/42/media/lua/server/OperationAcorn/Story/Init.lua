-- The story part's wiring on the server (and alone): the events the missions and the story run on, the commands the
-- windows send, and the hooks to the trade part. Nothing here runs per tick or per square (DESIGN 12): a ten-minute
-- event compares times, a minute event a few distances, a day event picks the frequency's line, and the rest answers
-- a command or a chunk loading.
require "OperationAcorn/Server"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/Game"
require "OperationAcorn/Story/Sites"
require "OperationAcorn/Story/Story"
require "OperationAcorn/Story/Scene"
require "OperationAcorn/Story/SceneGame"
local OA = OperationAcorn
local Missions, Game, Sites, Story = OA.Missions, OA.StoryGame, OA.Sites, OA.Story
local Scene, SceneGame = OA.Scene, OA.SceneGame
local Init = {}
OA.StoryInit = Init

local started = false
local subscribed = false
local provided = false

-- A trade-part event is a function that takes listeners (OA.Trade.onSealed(fn)) or a plain list of them.
local function listen(event, fn)
    if type(event) == "function" then
        event(fn)
        return true
    elseif type(event) == "table" then
        table.insert(event, fn)
        return true
    end
    return false
end

local function subscribe()
    if subscribed or not OA.Trade then return end
    local a = listen(OA.Trade.onSealed, Missions.onSealed)
    local b = listen(OA.Trade.onSettled, Missions.onSettled)
    -- The manifest's remark: the story's ordered lines go in front of the general ones.
    if OA.Trade.addNoteProvider and not provided then
        provided = true
        OA.Trade.addNoteProvider(function(record)
            return Story.manifestNoteKey(record)
        end, true)
    end
    subscribed = a and b
end

local function eachRecord(fn)
    for _, record in pairs(OA.Store.players()) do
        local ok, err = pcall(fn, record)
        if not ok then OA.log("story tick failed:", tostring(err)) end
    end
end

local function start()
    if started then return end
    started = true
    Missions.game = Game
    Scene.game = SceneGame
    local ok, err = pcall(Sites.ensure)
    if not ok then OA.log("meteor sites failed:", tostring(err)) end
    Game.rebuildWaiting()
    subscribe()
end

local function onTenMinutes()
    if not started then start() end
    subscribe()
    eachRecord(function(record)
        Missions.tick(record)
        local x, y = Game.playerPosition(record)
        if x then Sites.visit(record, x, y) end
        -- The first radio line, when the trade part has not asked for it by the first stage.
        local stage = Story.progress(record)
        if stage >= 1 and not Story.section(record).firstContact then Story.firstContact(record, false, true) end
    end)
end

-- Every game minute: a mission's circle entered, its place shown, a drop site stood at (Story/Scene; a few distances a
-- record, and nothing more until the player is in a circle).
local function onMinute()
    if not started then return end
    eachRecord(Scene.minute)
end

local function onDay()
    local day = OA.day()
    eachRecord(function(record) Story.dailyRadio(record, day) end)
end

Events.EveryTenMinutes.Add(onTenMinutes)
Events.EveryOneMinute.Add(onMinute)
Events.OnZombieDead.Add(SceneGame.zombieDied)
Events.EveryDays.Add(onDay)
Events.OnGameStart.Add(start)
Events.OnServerStarted.Add(start)
Events.OnFillContainer.Add(function(roomName, containerType, container)
    if Game then Game.onFill(roomName, containerType, container) end
end)

-- ---------------------------------------------------------------------------------------------------------------
-- Commands from the windows (client -> server). The character is the one who asks; the record is theirs.

OA.Server.on("story_choose", function(character, record, args)
    Missions.choose(record, args.option)
end)

OA.Server.on("story_swap", function(character, record, args)
    if not Missions.swap(record, character) then OA.Sync.notice(record.id, "IGUI_OA_Story_SwapFail", {}) end
end)

OA.Server.on("story_field", function(character, record, args)
    local ok, why = Missions.fieldCall(record, character)
    if not ok then OA.Sync.notice(record.id, "IGUI_OA_Story_FieldFail_" .. tostring(why), {}) end
end)

OA.Server.on("story_soil", function(character, record, args)
    if not Missions.soil(record, character) then OA.Sync.notice(record.id, "IGUI_OA_Story_SoilFail", {}) end
end)

-- A document was read. `variant` is the place its text was for.
OA.Server.on("story_read", function(character, record, args)
    if type(args.doc) == "string" then
        Story.markRead(record, args.doc, type(args.variant) == "string" and args.variant or nil)
        Story.clearNew(record, "d:" .. args.doc)
        -- Read whole in the viewer: the terminal has nothing left to type of it.
        Story.saveTyped(record, "d:" .. args.doc, nil, true)
    end
end)

-- An entry of the terminal's folder was opened there: it is not new any more. `key` is its folder key ("c:s2" a radio
-- copy, "d:<id>" a document, "r:<number>" a request copy).
OA.Server.on("story_seen", function(character, record, args)
    if type(args.key) == "string" then Story.clearNew(record, args.key) end
end)

-- The folder's text panel kept how far it has typed an entry (Story/Typing): `t` seconds of typing, or `done`.
OA.Server.on("story_typed", function(character, record, args)
    if type(args.key) == "string" then Story.saveTyped(record, args.key, tonumber(args.t), args.done == true) end
end)

-- A drop site's survey stake was read.
OA.Server.on("story_stake", function(character, record, args)
    local s = Story.section(record)
    if type(args.stake) == "number" then s.sitesSearched[args.stake] = true end
end)

-- The serum with the adaptation node at its second point was taken (the upgrade part calls this on each dose): the
-- overlay is told how long to run and where the nearest drop site is; next week's requests get one strange item.
function Story.onSerum(character, record, kind)
    local s = Story.section(record)
    s.hallucinations = (s.hallucinations or 0) + 1
    s.strangeWeek = OA.week() + 1
    local detail = { long = s.hallucinations <= OA.StoryData.HALLUCINATION_LONG }
    local x, y
    if character then x, y = character:getX(), character:getY() end
    if x then
        local best, bestD
        for _, site in ipairs(Sites.list()) do
            if site.state == "placed" then
                local d = OA.Places.distance(x, y, site.x, site.y)
                -- Only what is within the loaded squares (about six chunks around): no map, no distance told.
                if d <= 52 and (not bestD or d < bestD) then best, bestD = site, d end
            end
        end
        if best then detail.dx, detail.dy = best.x - x, best.y - y end
    end
    OA.Sync.changed("hallucinate", record.id, detail)
end

return Init
