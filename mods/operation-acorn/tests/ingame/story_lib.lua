-- The story's combined check driven by hand (E2E-DEBUG.md, PLAN 6단계): what the player sees logged as it comes, and
-- the player's moves made as the buttons make them. RUN once a save is loaded (again after a reload); ST.* after.
--   [st] lines: each title (key, style), notice, monologue (self-talk id or story line key), helicopter pass, call
--   started in the comms tab (id), and each entry the record keeps (comms played, a monologue said), with the real
--   seconds since the lib ran and the game's day and hour.
-- Moves: ST.open() the base terminal (booted at once), ST.tab(id), ST.skip() a call playing, ST.yes() / ST.no() the
-- last question asked, ST.launch() the mission tab's start, ST.call() the helicopter
-- tab's call, ST.seal() the active box's seal (asked, then walked to and sealed), ST.close() the window,
-- ST.state() what stands now.
local OA = OperationAcorn
local UI = PZUIKit.UI
ST = ST or {}
local player = getPlayer()
local started = getTimestampMs()

local function stamp()
    local gt = getGameTime()
    return string.format("%5.1fs d%d %02d:%02d", (getTimestampMs() - started) / 1000, gt:getNightsSurvived(),
        gt:getHour(), gt:getMinutes())
end

function ST.say(...) print("[st]", stamp(), ...) end

local function record() return OA.Dev.record() end

-- What comes to the player ------------------------------------------------------------------------------------------
if not ST.hooked then
    ST.hooked = true
    OA.Sync.listen("title", function(_, d)
        if d then ST.say("TITLE", d.key, d.style or "dust", d.sub or "", d.tone or "") end
    end)
    OA.Sync.listen("notice", function(_, d)
        if d then ST.say("NOTICE", d.key) end
    end)
    OA.Sync.listen("say", function(_, d)
        if d then ST.say("SELF", d.id, d.delay or "") end
    end)
    OA.Sync.listen("storySay", function(_, d)
        if d then ST.say("MONO", d.key, getText(d.key)) end
    end)
    OA.Sync.listen("heliPass", function(_, d)
        ST.say("HELI", d and (d.kind or d.state or "") or "")
    end)
    -- the record's comms log as it grows
    local seen = nil
    OA.Sync.listen("comms", function()
        local r = record()
        local log = r and OA.Comms.section(r).log
        if not log then return end
        if not seen or seen > #log then seen = #log return end
        for i = seen + 1, #log do ST.say("KEPT", log[i].id, log[i].tier or "") end
        seen = #log
    end)
    local start = OATabComms.start
    function OATabComms:start(entry, tier, replay, now, hail)
        ST.say("CALL", entry and entry.id, replay and "(replay)" or "", hail and "(hail)" or "")
        return start(self, entry, tier, replay, now, hail)
    end
    local confirm = UI.confirm
    UI.confirm = function(...)
        ST.asked = confirm(...)
        ST.say("ASK", table.concat(ST.asked.lines, " / "))
        return ST.asked
    end
end

-- The player's moves ------------------------------------------------------------------------------------------------
function ST.open()
    ST.win = OA.Dev.openTerminal()
    if not ST.win then return end
    for _ = 1, 30 do if ST.win.boot then ST.win:bootSkip() end end
    ST.say("OPEN tab", ST.win.activeId or "?")
end

-- The things of the trade near the character (within 8): the nearest of a kind (Objects.TERMINAL, CRATE, ...).
local function nearest(kind)
    local Objects = OA.Trade.Objects
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local best, bestD
    for dy = -8, 8 do
        for dx = -8, 8 do
            local sq = getCell():getGridSquare(px + dx, py + dy, pz)
            local o = sq and Objects.find(sq, kind)
            if o and (not bestD or dx * dx + dy * dy < bestD) then best, bestD = o, dx * dx + dy * dy end
        end
    end
    return best
end
ST.nearest = nearest

-- As the menus do: the crate's seal broken (walked to), its things taken (the game's transfer), a terminal carried
-- put down by the character, the terminal used (walked to; the window opens as the action ends).
function ST.unseal()
    local o = nearest(OA.Trade.Objects.CRATE)
    if not o then ST.say("UNSEAL: no crate") return end
    OA.Trade.Menus.unseal(o, 0)
end

function ST.takeAll()
    local o = nearest(OA.Trade.Objects.CRATE)
    local c = o and o:getContainer()
    if not c then ST.say("TAKE: no open crate") return end
    local items = {}
    for i = 0, c:getItems():size() - 1 do items[#items + 1] = c:getItems():get(i) end
    for _, item in ipairs(items) do
        ISTimedActionQueue.add(ISInventoryTransferAction:new(player, item, c, player:getInventory()))
    end
    ST.say("TAKE", #items)
end

function ST.placeTerminal()
    local Objects = OA.Trade.Objects
    local item = player:getInventory():getFirstTypeRecurse("OperationAcorn.CommTerminal")
    local square = Objects.findClear(math.floor(player:getX()) + 1, math.floor(player:getY()), 4)
    if not (item and square) then ST.say("PLACE: no terminal carried or no square") return end
    ISTimedActionQueue.add(ISOAPlaceThing:new(player, Objects.TERMINAL, item, square, "S"))
    ST.say("PLACE at", square:getX(), square:getY())
end

function ST.use()
    local o = nearest(OA.Trade.Objects.TERMINAL)
    if not o then ST.say("USE: no terminal") return end
    OA.Dev.powerAt(o:getSquare())
    OA.Trade.Menus.use(o, 0)
end

function ST.tab(id)
    ST.win = ST.win or OATerminalWindow.instances[0]
    ST.win:activate(id)
    ST.say("TAB", id)
end

function ST.view(id)
    ST.win = OATerminalWindow.instances[0]
    return ST.win and ST.win.views[id]
end

-- The comms tab's calls screen, if made.
function ST.calls()
    ST.win = OATerminalWindow.instances[0]
    return ST.win and ST.win:subView("comms", "calls")
end

function ST.skip()
    local v = ST.calls()
    if v and v.play then OATabComms.skip(v) ST.say("SKIP") else ST.say("SKIP: nothing playing") end
end

function ST.yes()
    if not ST.asked then ST.say("YES: nothing asked") return end
    local asked = ST.asked
    ST.asked = nil
    asked:onYesButton()
    ST.say("YES")
end

function ST.no()
    if ST.asked then ST.asked:onNoButton() ST.asked = nil end
    ST.say("NO")
end

-- The missions tab's screen; ST.missions("docs") the documents (the comms tab's inbox).
function ST.missions(sub)
    if sub == "docs" then
        ST.tab("comms")
        return ST.view("comms"):open("docs")
    end
    ST.tab("missions")
    return ST.view("missions")
end

function ST.launch()
    ST.missions():onLaunch()
end

function ST.call()
    ST.tab("heli")
    ST.view("heli"):onCall()
end

function ST.seal()
    local r = record()
    local box = OA.Trade.Boxes.active(r)
    local Objects = OA.Trade.Objects
    local object = box and box.x and Objects.find(Objects.square(box.x, box.y, box.z or 0), Objects.DELIVERY_BOX, box.id)
    if not object then ST.say("SEAL: no box standing") return end
    OA.Trade.Menus.seal(object, 0)
end

-- The terminal window closes, however it opened (ST.open, or the terminal used: ST.use).
function ST.close()
    local win = ST.win or OATerminalWindow.instances[player:getPlayerNum()]
    if win then win:close() end
    ST.win = nil
    ST.say("CLOSE")
end

function ST.state()
    local r = record()
    local Comms, Missions = OA.Comms, OA.Missions
    local nextCall = Comms.next(r, "terminal")
    local m = Missions.active(r)
    local v = ST.calls()
    local play = v and v.play
    ST.say("STATE stage", r.trade.stage, r.trade.milestones or 0, "next call", nextCall and nextCall.id or "-",
        "mission", m and ((m.story or m.kind or "?") .. ":" .. tostring(m.state)) or "-",
        "playing", play and (play.entry and play.entry.id or "?") or "-",
        "tab", ST.win and ST.win.activeId or "closed",
        "heli", tostring(r.heli and r.heli.call and r.heli.call.arrive))
end

OA.Dev.console(false)
RUN("st_hitch.lua")
RUN("st_timing.lua")
ST.say("lib ready")
