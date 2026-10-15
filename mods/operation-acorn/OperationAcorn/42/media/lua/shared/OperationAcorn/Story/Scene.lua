-- What a mission's place shows when the player gets there (DESIGN-terminal 7.1): a few things someone left there, a
-- line over the character's head on first entering the circle, zombies that keep the building (the sandbox option
-- MissionGuards, on by default), and now and then a survivor who came first and turned, carrying a little. The drop
-- sites get their own first-visit line here too (story-improvements 10).
--
-- What a mission will show is decided once, as it begins (m.scene, kept with the mission). It is put in the world by
-- the one-minute look below, only while the player is inside the mission's circle, and only once the building's key
-- square is loaded and the mission's piece is in place there (the piece itself may be placed by a later chunk load,
-- and the zombies are best made while the player is near): no work per square or per frame. The world's hands are
-- `Scene.game` (Story/SceneGame); tests give it fakes.
--
-- The survivor's drop: the game's IsoZombie.addItemToSpawnAtDeath list is not saved, a zombie that leaves the loaded
-- area is kept only as its position, outfit id and state flags, and a zombie risen from a fake-dead body never spawns
-- that list. So the survivor is known by its persistent outfit id (kept through all of that) and what it carried is
-- put in its inventory as it dies (OnZombieDead comes after the game fills the inventory and before the body is made
-- from it).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Say"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Stage"
local OA = OperationAcorn
local Data, Places = OA.StoryData, OA.Places
local Scene = {}
OA.Scene = Scene

Scene.game = nil

-- Numbers (가안).
Scene.SURVIVOR_CHANCE = 25   -- percent a mission has a survivor, never two missions in a row
Scene.SURVIVORS_KEPT = 4     -- survivors not yet dead a record remembers (the oldest is forgotten)
Scene.NEAR = 20              -- nothing is made closer than this to the player (it would appear in sight)
Scene.READY = 40             -- the scene is made once the player is this near its piece: made as the circle is
                             -- entered (up to 100 squares off), the keepers wandered out before the player came
Scene.CLOSE = 10             -- how far from the player things are made when the player came nearer than NEAR between
                             -- two looks (by car): out of the room the player stands in, not never
Scene.SITE_TOUCH = 4         -- how close to a drop site's middle counts as being at it
Scene.LOOK_MS = 1000         -- real milliseconds at least between two looks (the minute fires fast when fast-forwarded)
Scene.DRIFT = 200            -- how far from its building a dying survivor may be and still be the one
-- Vanilla's stage days for the survivalist outfits (ZombiesStageDefinitions.daysMid, daysLate): the _Mid look from
-- the 30th day since the outbreak, the _Late one from the 90th.
Scene.MID_DAYS = 30
Scene.LATE_DAYS = 90

Scene.SURVIVOR_OUTFITS = { "Survivalist", "Survivalist02", "Survivalist03", "Survivalist04", "Survivalist05" }
-- How the survivor is found (addZombiesInOutfit's flags): lying by the mission's container and getting up as the
-- player comes near, sitting against something, crawling, or standing.
Scene.LOOKS = { "fakeDead", "sitting", "crawler", "standing" }

-- What the survivor carried, by the mission's level (1 to 5 and on): one thing to eat and one or two others.
Scene.CARRIED = {
    [1] = { food = { "Base.TinnedBeans", "Base.CannedCorn", "Base.TinnedSoup", "Base.GranolaBar" },
            kit = { "Base.Bandage", "Base.Matches", "Base.Battery" } },
    [2] = { food = { "Base.TinnedBeans", "Base.TinnedSoup", "Base.BeefJerky", "Base.GranolaBar" },
            kit = { "Base.Bandage", "Base.Bandaid", "Base.Matches", "Base.TinOpener" } },
    [3] = { food = { "Base.CannedChili", "Base.TinnedBeans", "Base.BeefJerky" },
            kit = { "Base.Bandage", "Base.Pills", "Base.Bullets9mmBox" } },
    [4] = { food = { "Base.WaterRationCan", "Base.CannedChili", "Base.BeefJerky" },
            kit = { "Base.Bullets9mmBox", "Base.Bullets38Box", "Base.AlcoholWipes", "Base.PillsBeta" } },
    [5] = { food = { "Base.WaterRationCan", "Base.BeefJerky" },
            kit = { "Base.ShotgunShellsBox", "Base.Bullets9mmBox", "Base.Antibiotics", "Base.Disinfectant" } },
}

-- The things someone left at a mission's place: vanilla items, some of them used up (left = what is left of a
-- drainable, 0 to 1). A regular mission's building is any building, so its things fit anywhere.
local function prop(t, left) return { type = t, left = left } end
Scene.PROPS = {
    any = { prop("Base.HandTorch", 0), prop("Base.Battery", 0), prop("Base.Gloves_Surgical"),
            prop("Base.Hat_SurgicalMask"), prop("Base.Plasticbag"), prop("Base.DuctTape", 0.1),
            prop("Base.Twine", 0.2), prop("Base.Pencil"), prop("Base.SheetPaper2"), prop("Base.Zipties") },
    police = { prop("Base.Clipboard"), prop("Base.Pen"), prop("Base.Paperclip"), prop("Base.Zipties"),
               prop("Base.Gloves_Surgical"), prop("Base.HandTorch", 0) },
    medical = { prop("Base.Gloves_Surgical"), prop("Base.Hat_SurgicalMask"), prop("Base.CottonBalls"),
                prop("Base.Tissue", 0.3), prop("Base.Clipboard"), prop("Base.AlcoholWipes", 0) },
    records = { prop("Base.Pencil"), prop("Base.Notepad"), prop("Base.SheetPaper2"), prop("Base.HandTorch", 0),
                prop("Base.Candle", 0.1) },
    army = { prop("Base.Battery", 0), prop("Base.HandTorch", 0), prop("Base.Twine", 0.2), prop("Base.DuctTape", 0.1),
             prop("Base.Hat_DustMask") },
    prison = { prop("Base.Tissue", 0.3), prop("Base.Pencil"), prop("Base.SheetPaper2"), prop("Base.Zipties") },
    travel = { prop("Base.Plasticbag"), prop("Base.Twine", 0.2), prop("Base.Zipties"), prop("Base.Notepad") },
}

-- The props of a facility (Data.FACILITIES; a regular mission's building has none and gets things that fit anywhere).
Scene.KIND_PROPS = {
    police = "police", medical = "medical", hospital = "medical", farm = "records", army = "army", shelter = "travel",
    prison = "prison",
}
-- The keepers of a facility: vanilla outfits (media/clothing/clothing.xml) and the chance in 100 of a woman (0 or 100
-- for an outfit only one has). A facility not here, and a regular mission, gets the game's own outfit for the place.
Scene.GUARDS = {
    police = { { "Police", 30 } },
    medical = { { "Doctor", 50 }, { "Nurse", 70 } },
    hospital = { { "Nurse", 70 }, { "Doctor", 50 }, { "HospitalPatient", 50 } },
    farm = { { "Farmer", 30 } },
    army = { { "ArmyCamoGreen", 10 } },
    prison = { { "Inmate", 0 }, { "PrisonGuard", 0 } },
}

-- The self-talk (DESIGN-terminal 18). Arrive: a mission's circle entered, lines 1-3 at night, 4-6 by day, the rest
-- either (a story mission's circle has the story's own monologue instead, Scene.arrivalLine). Survivor: the first of a
-- survivor's things taken, once a mission. SiteFirst: a drop site first stood at.
OA.Say.define("Arrive", { tags = {
    [1] = { night = true }, [2] = { night = true }, [3] = { night = true },
    [4] = { night = false }, [5] = { night = false }, [6] = { night = false },
} })
OA.Say.define("Survivor", {})
OA.Say.define("SiteFirst", {})
-- InBuilding: the building that holds a piece not found yet, first entered: the character makes out where in it the
-- piece is. Floor: the floor changed that. Lines 1-2 the floor above, 3-4 this one, 5-6 below.
local whereTags = {
    [1] = { where = "up" }, [2] = { where = "up" }, [3] = { where = "here" }, [4] = { where = "here" },
    [5] = { where = "down" }, [6] = { where = "down" },
}
OA.Say.define("InBuilding", { tags = whereTags })
OA.Say.define("Floor", { tags = whereTags })

-- A record's section: { last = whether the last mission had a survivor, survivors = { { mission, outfit, x, y, z,
-- carried } } not yet dead, sites = { [n] = true } drop sites stood at, said = the mission whose survivor line was
-- said }.
function Scene.section(record)
    local s = OA.Store.section(record, "scene")
    if not s.version then
        s.version = 1
        s.last = false
        s.survivors = {}
        s.sites = {}
    end
    return s
end

-- ---------------------------------------------------------------------------------------------------------------
-- The choices (pure: `int` is OA.random unless a test gives its own).

-- Does this mission have a survivor: SURVIVOR_CHANCE percent, never after a mission that had one.
function Scene.survivorRoll(sec, int)
    int = int or OA.random
    local yes = not sec.last and int(1, 100) <= Scene.SURVIVOR_CHANCE
    sec.last = yes
    return yes
end

-- The survivalist outfit for the days since the outbreak (world age days since the beginning).
function Scene.survivorOutfit(days, int)
    int = int or OA.random
    local base = Scene.SURVIVOR_OUTFITS[int(1, #Scene.SURVIVOR_OUTFITS)]
    if (days or 0) >= Scene.LATE_DAYS then return base .. "_Late" end
    if (days or 0) >= Scene.MID_DAYS then return base .. "_Mid" end
    return base
end

function Scene.survivorLook(int)
    int = int or OA.random
    return Scene.LOOKS[int(1, #Scene.LOOKS)]
end

local function levelOf(level)
    return math.max(1, math.min(5, level or 1))
end

-- What the survivor carried: full types, one to eat and one other, a second other from the third level half the time.
function Scene.carried(level, int)
    int = int or OA.random
    local set = Scene.CARRIED[levelOf(level)]
    local out = { set.food[int(1, #set.food)] }
    local first = int(1, #set.kit)
    out[#out + 1] = set.kit[first]
    if levelOf(level) >= 3 and #set.kit > 1 and int(1, 2) == 1 then
        local second = int(1, #set.kit - 1)
        if second >= first then second = second + 1 end
        out[#out + 1] = set.kit[second]
    end
    return out
end

-- `count` different entries of a list, at random.
local function some(list, count, int)
    local idx = {}
    for i = 1, #list do idx[i] = i end
    local out = {}
    for _ = 1, math.min(count, #idx) do
        local k = int(1, #idx)
        out[#out + 1] = list[idx[k]]
        table.remove(idx, k)
    end
    return out
end

local function copyProp(p)
    return { type = p.type, left = p.left }
end

-- The things left at the place: a regular mission's building gets 1 to 3 that fit anywhere; a facility two of its
-- own kind and one of the others (never the same type twice).
function Scene.props(facility, int)
    int = int or OA.random
    local own = Scene.KIND_PROPS[facility or ""]
    local out = {}
    if not own then
        for _, p in ipairs(some(Scene.PROPS.any, int(1, 3), int)) do out[#out + 1] = copyProp(p) end
        return out
    end
    local taken = {}
    for _, p in ipairs(some(Scene.PROPS[own], 2, int)) do
        out[#out + 1] = copyProp(p)
        taken[p.type] = true
    end
    local rest = {}
    for _, p in ipairs(Scene.PROPS.any) do
        if not taken[p.type] then rest[#rest + 1] = p end
    end
    if #rest > 0 then out[#out + 1] = copyProp(rest[int(1, #rest)]) end
    return out
end

-- One keeper's outfit at a facility: the name and the chance of a woman, or nil (the game's own outfit).
function Scene.guardOutfit(facility, int)
    int = int or OA.random
    local list = Scene.GUARDS[facility or ""]
    if not list then return nil, nil end
    local g = list[int(1, #list)]
    return g[1], g[2]
end

-- How many keep the building by the mission's level (1 to 5; past 5, KEEPERS_ON more a level up to KEEPERS_MOST),
-- give or take two, times the sandbox's zombie population (none in a world without zombies). Those already in the
-- building count among them (SceneGame.spawnGuards).
Scene.KEEPERS = { 10, 15, 20, 26, 32 }
Scene.KEEPERS_ON, Scene.KEEPERS_MOST = 3, 40
-- One keeper in KEEPERS_STILL lies or sits (fake dead, getting up as the player comes; or sitting against something):
-- those stay in the building when noise draws the others out.
Scene.KEEPERS_STILL = 3

local function population()
    local zc = SandboxVars and SandboxVars.ZombieConfig
    local mult = zc and tonumber(zc.PopulationMultiplier) or 1
    return OA.clamp(mult, 0, 4)
end

function Scene.guardCount(level, int, mult)
    int = int or OA.random
    level = math.max(1, level or 1)
    local n = Scene.KEEPERS[math.min(level, #Scene.KEEPERS)]
    if level > #Scene.KEEPERS then
        n = math.min(Scene.KEEPERS_MOST, n + (level - #Scene.KEEPERS) * Scene.KEEPERS_ON)
    end
    n = (n + int(-2, 2)) * (mult or population())
    return math.floor(n + 0.5)
end

-- How one keeper is found: nil (standing), "fakeDead" or "sitting".
function Scene.guardLook(int)
    int = int or OA.random
    if int(1, Scene.KEEPERS_STILL) ~= 1 then return nil end
    return int(1, 2) == 1 and "fakeDead" or "sitting"
end

-- Night by the game's dawn and dusk hours.
function Scene.isNight(hour, dawn, dusk)
    dawn, dusk = dawn or 6, dusk or 21
    return hour < dawn or hour >= dusk
end

-- The mission's piece that stands in a building (the first one with a building's box): nil when there is none, as at a
-- drop site's stake or for a soil sample.
function Scene.buildingPiece(m)
    for _, it in ipairs(m.items or {}) do
        if it.x1 and it.x2 and it.y1 and it.y2 and (it.x2 > it.x1 or it.y2 > it.y1) then return it end
    end
    return nil
end

-- What a mission will show (m.scene), decided as it begins. `days` is the world age in days since the outbreak. A
-- story site with a stage (m.stage, Story/Stage) has its own things and no survivor: only its keepers come from here.
function Scene.plan(record, m, days, int)
    int = int or OA.random
    local sc = { arrived = false, built = false }
    if Scene.buildingPiece(m) then
        sc.props = not m.stage and Scene.props(m.facility, int) or nil
        local guards = {}
        for i = 1, Scene.guardCount(m.level, int) do
            local outfit, female = Scene.guardOutfit(m.facility, int)
            guards[i] = { outfit = outfit or false, female = female or false, look = Scene.guardLook(int) or false }
        end
        sc.guards = guards
        if not m.stage and Scene.survivorRoll(Scene.section(record), int) then
            sc.survivor = { outfit = Scene.survivorOutfit(days, int), look = Scene.survivorLook(int),
                            carried = Scene.carried(m.level, int) }
        end
    else
        sc.built = true
    end
    return sc
end

-- ---------------------------------------------------------------------------------------------------------------
-- In the course of a mission.

-- The mission began (Missions.begin): what it will show is decided once. An offer has no place yet; it is decided when
-- the offer is taken.
function Scene.begin(record, m)
    if m.scene or m.state == "offer" then return end
    OA.Stage.begin(record, m)
    local g = Scene.game
    m.scene = Scene.plan(record, m, g and g.days and g.days() or 0)
end

local function inCircle(area, x, y)
    if not area then return false end
    local dx, dy = x - area.x, y - area.y
    return dx * dx + dy * dy <= area.r * area.r
end

-- Entering the circle: a story mission's own monologue (CommsData "say:<story>:enter", the choice by its option; after
-- the handover the revisits' few in turn), said by the story and kept in the comms tab; else a general line for the
-- hour. Returns the bundle and its context for a general line, nil when the story said its own.
function Scene.arrivalLine(record, m, night)
    if m.story and OA.Story then
        local said
        if Data.REVISITS[m.story] then
            said = OA.Story.afterMonologue(record)
        else
            said = OA.Story.monologue(record, m.chosen and (m.story .. "_" .. m.chosen) or m.story, "enter")
        end
        if said then return nil end
    end
    return "Arrive", { night = night == true }
end

-- The survivor made: remembered by its outfit id until it dies (the oldest forgotten past SURVIVORS_KEPT).
function Scene.addSurvivor(record, m, outfitId, at)
    local sec = Scene.section(record)
    table.insert(sec.survivors, { mission = m.id, outfit = outfitId, x = at.x, y = at.y, z = at.z,
                                  carried = m.scene.survivor.carried })
    while #sec.survivors > Scene.SURVIVORS_KEPT do table.remove(sec.survivors, 1) end
end

-- Puts the mission's scene in the world, if its piece is in place, its square loaded and the player near it (READY),
-- what is made kept NEAR away from the player (CLOSE when the player is already nearer).
function Scene.build(record, m, px, py)
    local sc = m.scene
    local it = Scene.buildingPiece(m)
    if not it then
        sc.built = true
        return
    end
    if not (it.placed and it.at) then return end
    local d = Places.distance(px, py, it.at.x, it.at.y)
    if d > Scene.READY then return end
    local near = d >= Scene.NEAR and Scene.NEAR or Scene.CLOSE
    local g = Scene.game
    if not g.loaded(it.at) then return end
    sc.built = true
    if sc.props and #sc.props > 0 then g.placeProps(it, sc.props) end
    if sc.guards and OA.option("MissionGuards") ~= false then g.spawnGuards(it, sc.guards, px, py, near) end
    if sc.survivor then
        local outfitId = g.spawnSurvivor(it, sc.survivor, px, py, near)
        if outfitId then Scene.addSurvivor(record, m, outfitId, it.at) end
    end
end

-- A drop site first stood at (within SITE_TOUCH of its middle): its number, or nil. Squared distances only.
function Scene.touchSite(record, x, y, sites)
    local sec = Scene.section(record)
    local r2 = Scene.SITE_TOUCH * Scene.SITE_TOUCH
    for _, site in ipairs(sites or {}) do
        if site.state == "placed" and not sec.sites[site.n] then
            local dx, dy = x - site.x, y - site.y
            if dx * dx + dy * dy <= r2 then
                sec.sites[site.n] = true
                return site.n
            end
        end
    end
    return nil
end

-- The floor hint: for the first piece not found yet whose building the player stands in (g.inBuildingOf), where it is
-- from the player's floor (`z`): "up", "down" or "here". The bundle and its context when that is new for the piece
-- (InBuilding the first time, then Floor), else nil. The last answer is kept with the piece, so walking out and in
-- again on the same floor says nothing.
function Scene.floorHint(record, m, z)
    local g = Scene.game
    if not (g and g.inBuildingOf) then return nil end
    for _, it in ipairs(m.items or {}) do
        if it.placed and it.at and not it.plain and not it.found and g.inBuildingOf(record, it.at) then
            local floor = math.floor(z or 0)
            local where = it.at.z > floor and "up" or (it.at.z < floor and "down" or "here")
            local hints = m.scene.hints or {}
            m.scene.hints = hints
            local last = hints[it.key]
            if last == where then return nil end
            hints[it.key] = where
            return last == nil and "InBuilding" or "Floor", { where = where }
        end
    end
    return nil
end

local looks = {}  -- by record id: the real time (ms) of the last look

-- Every game minute, for each record: the circle entered (the line, and the request's name coming out of the mist), the
-- scene put in place, the floor hint in the
-- piece's building, a drop site stood at. Each mission running is looked at: the regular one and a special request
-- beside it. One line a look.
function Scene.minute(record)
    local g = Scene.game
    if not g then return end
    if not OA.due(looks, record.id, getTimestampMs(), Scene.LOOK_MS) then return end
    local x, y, z = g.playerPosition(record)
    if not x then return end
    local said = false
    for _, m in ipairs(OA.Missions.live(record)) do
        if m.scene and m.state == "open" then
            if m.stage and not m.stage.kept then
                local d = Places.distance(x, y, m.site.x, m.site.y)
                OA.Stage.look(record, m, x, y, d >= Scene.NEAR and Scene.NEAR or Scene.CLOSE)
            end
            if inCircle(m.area, x, y) or inCircle(m.area2, x, y) then
                if not m.scene.arrived then
                    m.scene.arrived = true
                    local id, ctx = Scene.arrivalLine(record, m, g.isNight())
                    if id then g.say(record, id, ctx) end
                    g.title(record, { key = "IGUI_OA_Title_Arrived", sub = (OA.Missions.keys(m)), style = "unveil" })
                    said = true
                end
                if not m.scene.built then Scene.build(record, m, x, y) end
            end
            if not said then
                local id, ctx = Scene.floorHint(record, m, z)
                if id then
                    g.say(record, id, ctx)
                    said = true
                end
            end
        end
    end
    if OA.Sites and Scene.touchSite(record, x, y, OA.Sites.list()) then g.say(record, "SiteFirst", nil) end
end

-- A zombie died with this outfit id at x, y: the record and the survivor it was (taken off the list), or nil.
function Scene.survivorDied(outfitId, x, y)
    if not outfitId or outfitId == 0 then return nil end
    local far = Scene.DRIFT * Scene.DRIFT
    for _, record in pairs(OA.Store.players()) do
        local list = record.scene and record.scene.survivors
        if list then
            for i, s in ipairs(list) do
                local dx, dy = x - s.x, y - s.y
                if s.outfit == outfitId and dx * dx + dy * dy <= far then
                    table.remove(list, i)
                    return record, s
                end
            end
        end
    end
    return nil
end

-- One of a survivor's things came into the player's hands (the economy's pickup hook): the line, once a mission.
function Scene.pickedUp(record, item)
    local md = item and item.getModData and item:getModData()
    local mission = md and md.OA_Carried
    if not mission then return end
    local sec = Scene.section(record)
    if sec.said == mission then return end
    sec.said = mission
    if Scene.game then Scene.game.say(record, "Survivor", nil) end
end

return Scene
