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
    local c = listen(OA.Trade.onSettled, Story.onSettled)
    -- The manifest's remark: the story's ordered lines go in front of the filler lines and the general ones (they say what
    -- the remark encloses too: Trade.Settle puts it in the crate), and the 2반 papers go in the crates, one to each.
    if OA.Trade.addNoteProvider and OA.Trade.addCrateProvider and not provided then
        provided = true
        OA.Trade.addNoteProvider(function(record, draft)
            local key, args, _, fx = Story.manifestNoteKey(record, draft)
            return key, args, fx
        end, true)
        OA.Trade.addNoteProvider(function(record, draft)
            return Story.fillNoteKey(record, draft)
        end)
        OA.Trade.addCrateProvider(function(record, draft)
            return Story.crateSpecs(record, draft)
        end)
    end
    subscribed = a and b and c
end

-- The living records (a dead character's has no story any more).
local function eachRecord(fn)
    for _, record in pairs(OA.Store.players()) do
        if OA.Store.alive(record) then
            local ok, err = pcall(fn, record)
            if not ok then OA.log("story tick failed:", tostring(err)) end
        end
    end
end

-- The drop sites go round the first character's place (Sites.ensure): asked again until there is one (a server
-- with nobody on it yet).
local sitesMade = false
local function ensureSites()
    if sitesMade then return end
    local origin
    for _, record in pairs(OA.Store.players()) do
        if OA.Store.alive(record) then
            local x, y = Game.playerPosition(record)
            if x then
                origin = { x = math.floor(x), y = math.floor(y) }
                break
            end
        end
    end
    local ok, list = pcall(Sites.ensure, origin)
    if not ok then
        OA.log("meteor sites failed:", tostring(list))
        sitesMade = true
    elseif list then
        sitesMade = true
    end
end

local function start()
    if started then return end
    started = true
    Missions.game = Game
    Scene.game = SceneGame
    ensureSites()
    Game.rebuildWaiting()
    subscribe()
end

local function onTenMinutes()
    if not started then start() end
    ensureSites()
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
-- A fire empties a container (the API's event; without the API a burnt piece waits for the deadline).
if Events.OnPZExtContainerBurning then
    Events.OnPZExtContainerBurning.Add(function(container, object)
        if Game then Game.onBurning(container, object) end
    end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Commands from the windows (client -> server). The character is the one who asks; the record is theirs.

OA.Server.on("story_choose", function(character, record, args)
    Missions.choose(record, args.option)
end)

-- A command from a terminal window: the terminal it was made at must be near and powered (the trade part's own check);
-- `fieldOnly` also wants it to be a field terminal. False, with the reason told to the player, when it is not.
local function atTerminal(character, record, args, fieldOnly)
    local Trade = OA.Trade
    local handlers, objects = Trade and Trade.Handlers, Trade and Trade.Objects
    if not (handlers and objects) then return true end
    local object, why = handlers.terminalFor(character, args)
    if not object then
        OA.Sync.notice(record.id, "IGUI_OA_Trade_Reason_" .. tostring(why))
        return false
    end
    if fieldOnly and not objects.isUpgraded(object) then
        OA.Sync.notice(record.id, "IGUI_OA_Trade_Reason_fieldOnly")
        return false
    end
    return true
end

-- The card's 'take another': once a week, for some trust.
OA.Server.on("story_reroll", function(character, record, args)
    if not atTerminal(character, record, args) then return end
    if not Missions.reroll(record) then OA.Sync.notice(record.id, "IGUI_OA_Story_RerollFail", {}) end
end)

-- One of the two special requests taken (at a field terminal).
OA.Server.on("story_special", function(character, record, args)
    if not atTerminal(character, record, args, true) then return end
    if not Missions.acceptSpecial(record, args.option) then OA.Sync.notice(record.id, "IGUI_OA_Story_SpecialFail", {}) end
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

-- A document was read. `variant` is the place its text was for, `extra` the number it was read with.
OA.Server.on("story_read", function(character, record, args)
    if type(args.doc) == "string" then
        Story.markRead(record, args.doc, type(args.variant) == "string" and args.variant or nil, args.extra)
        Story.clearNew(record, "d:" .. args.doc)
        -- Read whole in the viewer: the terminal's folder has it as seen to the end (an entry it kept nothing of is that).
        if Story.typedState(record, "d:" .. args.doc) then Story.saveTyped(record, "d:" .. args.doc, nil, true) end
    end
end)

-- An entry of the terminal's folder was opened there: it is not new any more. `key` is its folder key ("c:s2" a radio
-- copy, "d:<id>" a document, "r:<number>" a request copy).
OA.Server.on("story_seen", function(character, record, args)
    if type(args.key) == "string" then Story.clearNew(record, args.key) end
end)

-- The folder's text panel kept how far a showing of an entry got (Story/Typing): `seen` characters, `done` when that is
-- all of it, `t` the seconds typed when the showing was left before the end.
OA.Server.on("story_typed", function(character, record, args)
    if type(args.key) == "string" then
        Story.saveTyped(record, args.key, tonumber(args.seen), args.done == true, tonumber(args.t))
    end
end)

-- A drop site's survey stake was read: its number and its date go to the stake record in the folder (the date is the
-- site's own, not what the window says).
OA.Server.on("story_stake", function(character, record, args)
    if type(args.stake) ~= "number" then return end
    for _, site in ipairs(Sites.list()) do
        if site.stake == args.stake then
            Story.noteStake(record, args.stake, site.date)
            return
        end
    end
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
