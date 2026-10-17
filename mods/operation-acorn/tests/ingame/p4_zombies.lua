-- P4 zombie samples and zombie missions (DESIGN 6 '좀비 시료', 9 '좀비 임무'). Lines tagged "[p4zombies]", each "ok" or
-- "BAD". Single player, a character with a record at stage 1 or above, open ground about; a throwaway save (it replaces
-- the running mission). The API installed with the zombie marks (zombies.mark, zombies.hold).
--
--   RUN("p4_zombies.lua")      the items, shop, first box and API hooks; defines the steps below
--   P4Z_MISSION("clear")       a fresh area clear (or "target") whose circle is 50 squares east of the character
--   P4Z_STATUS()               the mission's counts, the group loaded (how many, how far from the circle's middle)
--   P4Z_KILL(n)                kills n of the loaded group (all when n is nil)
--   P4Z_HARVEST(precise)       harvests the nearest zombie corpse within 3 squares (gives and equips the harvest kit)
--   P4Z_AWAY() / P4Z_BACK()    goes 200 squares off (the group's chunks unload: it goes), and back to the circle
--   P4Z_MARKS()                the world's table of marks: how many zombies of the mission it keeps
--
-- A check by hand: walk to the circle (the group appears out of sight; P4Z_STATUS), stand far off and make noise (it
-- stays), right-click a fresh corpse with the harvest kit in hand (the quick harvest; the precise one once tweezers came).
RUN("p4_lib.lua")
local OA = OperationAcorn
local say = P4T.say("p4zombies")
local function check(...) return P4T.check(say, ...) end
local Data, Missions, Zombies, Harvest = OA.StoryData, OA.Missions, OA.ZombieMissions, OA.Harvest

local function section(name, fn)
    say("----", name)
    local ok, err = pcall(fn)
    if not ok then say("BAD", name, "error", tostring(err)) end
end

section("items", function()
    for _, name in ipairs({ "HarvestKit", "PrecisionTweezers", "TissueCommon", "TissueInfected", "TissueNeural",
        "TissueAnomalous", "TissueTarget" }) do
        local script = getScriptManager():FindItem("OperationAcorn." .. name)
        check(name .. " script", script ~= nil)
        local item = script and instanceItem("OperationAcorn." .. name)
        check(name .. " icon", item ~= nil and item:getTex() ~= nil and item:getTex():getName() ~= "Question_On",
            item and item:getTex() and item:getTex():getName())
    end
    local kit = instanceItem(Harvest.KIT)
    check("the harvest kit can be equipped", kit:hasTag(ItemTag.EQUIPPABLE))
    check("tissue worth", OA.Value.OWN.TissueAnomalous.credits == 3000)
end)

section("outfits", function()
    for _, female in ipairs({ false, true }) do
        local names, have = getAllOutfits(female), {}
        for i = 0, names:size() - 1 do have[names:get(i)] = true end
        for _, def in pairs(Data.ZOMBIES) do
            check(def.outfit .. " " .. (female and "female" or "male"), have[def.outfit] == true)
        end
        check("no OA outfit of our own", have.OA_Crowd == nil and have.OA_Target == nil)
    end
end)

section("shop and first box", function()
    local kit, tweezers = OA.Shop.entry("harvest_kit"), OA.Shop.entry("precision_tweezers")
    check("harvest kit stocked", OA.Shop.stocked(kit))
    check("tweezers stocked", OA.Shop.stocked(tweezers))
    local cargo = {}
    for _, c in ipairs(OA.Trade.FirstSupply.CARGO) do cargo[c.type] = true end
    check("first box: terminal, booklet, harvest kit", cargo["OperationAcorn.CommTerminal"] and cargo["OperationAcorn.TerminalManual"]
        and cargo[Harvest.KIT])
end)

section("api", function()
    local api = OA.api()
    check("zombies.mark and hold", api ~= nil and api.zombies ~= nil and api.zombies.mark ~= nil and api.zombies.hold ~= nil)
    check("zombie missions given", OA.StoryGame.canMarkZombies())
    local hooks = api and api.hooks and api.hooks() or {}
    for _, label in ipairs({ "ZombieIdleState.execute", "WorldSoundManager.getBiggestSoundZomb",
        "ZombiePopulationManager.removeChunkFromWorld", "ZombiePopulationManager.registerZombie", "ZombiePopulationManager.releaseZombie",
        "ZombiePopulationManager.virtualizeZombie", "IsoZombie.removeFromWorld" }) do
        say(label, tostring(hooks[label]))
    end
end)

-- The steps ----------------------------------------------------------------------------------------------------------

local function running()
    local record = P4T.record()
    return record and Zombies.running(record), record
end

function P4Z_MISSION(kind)
    local record, player = P4T.record()
    local old = Missions.active(record)
    if old then Missions.finish(record, old, "lost") end
    -- the plain pick only (a story waiting would come first), of the one kind
    local regular, nextStory, handedOver = Data.REGULAR, OA.Story.nextStory, OA.Story.handedOver
    Data.REGULAR = { { id = kind, kind = kind, weight = 1 } }
    OA.Story.nextStory, OA.Story.handedOver = function() return nil end, function() return false end
    local ok, m = pcall(Missions.start, record)
    if ok and m then
        Missions.launch(record)
        m = Missions.active(record)
    end
    Data.REGULAR, OA.Story.nextStory, OA.Story.handedOver = regular, nextStory, handedOver
    if not (ok and m and m.zombies) then say("BAD", "mission", tostring(m), m and m.title) return end
    m.area.x, m.area.y = math.floor(player:getX()) + 50, math.floor(player:getY())
    OA.Sync.changed("missions", record.id)
    say("mission", m.id, kind, "group", m.zombies.total, "circle", m.area.x, m.area.y, m.area.r)
end

local function group(m)
    local list, found = OA.api().zombies.marked(OA.handle(), m.id), {}
    for _, z in ipairs(list) do found[#found + 1] = z end
    return found
end

-- The world's marks of the mission (virtual zombies included): how many zombies carry its id.
local function worldMarks(m)
    local kept, count = ModData.get("PZExtMarks"), 0
    for _, marks in pairs(kept or {}) do
        if marks[OA.MOD] == m.id then count = count + 1 end
    end
    return count
end

function P4Z_STATUS()
    local m = running()
    if not m then say("no zombie mission running") return end
    local z, far = m.zombies, 0
    local loaded = group(m)
    for _, zed in ipairs(loaded) do
        far = math.max(far, OA.Places.distance(zed:getX(), zed:getY(), m.area.x, m.area.y))
    end
    local p = getPlayer()
    say("status", m.id, z.kind, "total", z.total, "killed", z.killed, "taken", z.taken, "dead", #z.dead,
        "loaded", #loaded, "in the world", worldMarks(m), "farthest", string.format("%.1f", far), "player at",
        string.format("%.1f", OA.Places.distance(p:getX(), p:getY(), m.area.x, m.area.y)))
    check("the group within the circle and its margin", far <= m.area.r + Data.ZOMBIE_MARGIN, far)
end

function P4Z_KILL(n)
    local m = running()
    if not m then say("no zombie mission running") return end
    local killed = 0
    for _, zed in ipairs(group(m)) do
        if n and killed >= n then break end
        zed:Kill(getPlayer())
        killed = killed + 1
    end
    say("killed", killed)
end

function P4Z_HARVEST(precise)
    local p = getPlayer()
    local inv = p:getInventory()
    local kit = inv:getFirstTypeRecurse(Harvest.KIT) or inv:AddItem(Harvest.KIT)
    p:setPrimaryHandItem(kit)
    if precise and not inv:containsTypeRecurse(Harvest.TWEEZERS) then inv:AddItem(Harvest.TWEEZERS) end
    local best, bestD
    for dx = -3, 3 do
        for dy = -3, 3 do
            local sq = getCell():getGridSquare(math.floor(p:getX()) + dx, math.floor(p:getY()) + dy, math.floor(p:getZ()))
            local list = sq and sq:getStaticMovingObjects()
            for i = 0, list and list:size() - 1 or -1 do
                local o = list:get(i)
                if instanceof(o, "IsoDeadBody") and o:isZombie() then
                    local d = dx * dx + dy * dy
                    if not bestD or d < bestD then best, bestD = o, d end
                end
            end
        end
    end
    if not best then say("BAD", "no zombie corpse within 3 squares") return end
    local sq = best:getSquare()
    local record = P4T.record()
    local name, why = Harvest.take(p, record, { x = sq:getX(), y = sq:getY(), z = sq:getZ(), death = best:getDeathTime(),
        precise = precise == true })
    say("harvest", tostring(OA.StoryGame.markOf(best)), "->", tostring(name), tostring(why))
    local again, why2 = Harvest.take(p, record, { x = sq:getX(), y = sq:getY(), z = sq:getZ(), death = best:getDeathTime() })
    check("a corpse gives one sample", again == nil and why2 == "taken", why2)
end

local back
function P4Z_AWAY()
    local p = getPlayer()
    back = { x = math.floor(p:getX()), y = math.floor(p:getY()) }
    P4T.go(back.x + 200, back.y, 0)
    say("went 200 squares east; wait a few seconds, then P4Z_BACK()")
end

function P4Z_BACK()
    local m = running()
    if m then P4T.go(m.area.x - 30, m.area.y, 0) elseif back then P4T.go(back.x, back.y, 0) end
    say("back; P4Z_STATUS() in a few seconds (the group should come again, as many as are missing)")
end

function P4Z_MARKS()
    local m = running()
    if not m then say("no zombie mission running") return end
    say("marks", m.id, "in the world", worldMarks(m), "loaded", #group(m))
end

say("steps: P4Z_MISSION(kind), P4Z_STATUS(), P4Z_KILL(n), P4Z_HARVEST(precise), P4Z_AWAY(), P4Z_BACK(), P4Z_MARKS()")
