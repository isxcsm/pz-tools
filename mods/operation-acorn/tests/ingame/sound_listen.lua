-- The sounds played for a recording of the game's output (SOUND-SYSTEM.md S6: how they sound next to the game's own),
-- one part at a time by LISTEN_PART: "a" the game's reference sounds, then the timed actions' sounds from the character
-- (each 3 s, then stopped as an action stops them), a thing put down and taken up, the kit's keys typed at the comms'
-- pace and the printer's rows; "b" the titles that sound, queued; "c" a call (p5_comms.lua, LISTEN_CALL, else S0);
-- "d" the folder's first printed document and first typed note shown as new. The ambience is turned down while it
-- runs (the option is not touched). Prints [listen] lines with each sound's time from the part's start (ms).
local OA = OperationAcorn
local Sound = PZUIKit.Sound
local part = LISTEN_PART or "a"
local t = STEPS("listen")
local player = getPlayer()
local sm = getSoundManager()
local start = getTimestampMs()
local function at(...) t.say(getTimestampMs() - start, ...) end
local wasInvisible, wasGhost = player:isInvisible(), player:isGhostMode()
player:setInvisible(false)
player:setGhostMode(false)
sm:setAmbientVolume(0)
local function restore()
    player:setInvisible(wasInvisible)
    player:setGhostMode(wasGhost)
    sm:setAmbientVolume(getCore():getOptionAmbientVolume() / 10)
end

local steps = {}
local function add(ms, fn) steps[#steps + 1] = { ms, fn } end

if part == "a" then
    add(500, function() at("ui", "UIActivateButton") sm:playUISound("UIActivateButton") end)
    for _, name in ipairs({ "UISelectListItem", "RadioZap", "LightSwitch" }) do
        add(1500, function() at("ui", name) sm:playUISound(name) end)
    end
    local id
    for _, name in ipairs({ "GeneratorConnect", "RepairWithWrench", "Dismantle", "FixWithTape",
        "BeginRemoveBarricadePlankCrowbar", "OA_LockPick", "DigFurrowWithHands", "FirstAidApplyAlcoholWipes",
        "PourWaterIntoObject" }) do
        add(1500, function() at("action", name) id = player:playSound(name) end)
        add(3000, function() at("action stop", name) player:stopOrTriggerSound(id) end)
    end
    for _, name in ipairs({ "UIObjectMenuObjectPlace", "UIObjectMenuObjectPickup" }) do
        add(1500, function() at("done", name) sm:playUISound(name) end)
    end
    -- the comms' keys at the protagonist's pace (OA.CommsScript ME_CPS 14), a space now and then; then the erasing key
    local text = "Copy that, moving out now"
    for i = 1, #text do
        add(i == 1 and 1500 or 71, function()
            if i == 1 then at("keys", text) end
            Sound.ui("oa.comms.key", string.sub(text, i, i))
        end)
    end
    for i = 1, 8 do
        add(i == 1 and 600 or 100, function() if i == 1 then at("erase x8") end Sound.ui("oa.comms.erase") end)
    end
    for i = 1, 4 do
        add(i == 1 and 1200 or 350, function() if i == 1 then at("rows x4") end Sound.ui("oa.paper.row") end)
    end
    add(1500, function() at("end") end)
elseif part == "b" then
    -- the game's UI clicks first, the level the titles are set against
    add(500, function() at("ui", "UIActivateButton") sm:playUISound("UIActivateButton") end)
    add(1500, function() at("ui", "UISelectListItem") sm:playUISound("UISelectListItem") end)
    -- then each title alone, the next 2 s after the last is gone (its design time: enter, 5 s held, leave), so that each
    -- sound's time from its title's start is read off the recording
    local LONG = { stamp = 11.6, notice = 10.2, discovery = 11.7, unveil = 13.6, dust = 16.2, sink = 15.6, pulse = 17.2,
        bleed = 12.9, type = 12.5, brief = 11.5 }
    local wait = 1000
    for _, style in ipairs({ "stamp", "notice", "discovery", "unveil", "dust", "sink", "pulse", "bleed", "type", "brief" }) do
        add(wait, function()
            local id = OA.Store.idOf(player)
            if style == "brief" then
                OA.Titles.show(id, { key = "IGUI_OA_Title_SearchedBonus", args = { "1200" }, style = "brief" })
            else
                OA.Titles.show(id, { key = "IGUI_OA_Title_Site", sub = "IGUI_OA_Title_SiteSub", style = style })
            end
            at("title", style)
        end)
        wait = math.floor(LONG[style] * 1000) + 2000
    end
    add(1000, function() end)
elseif part == "c" then
    add(500, function()
        P5_CALL = LISTEN_CALL or "S0"
        at("call", P5_CALL)
        RUN("p5_comms.lua")
    end)
    add(1000, function() end)
elseif part == "d" then
    add(500, function()
        -- a terminal within reach (p5_comms.lua puts one down otherwise; its call is not wanted here: none played)
        local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
        local Objects, square = OA.Trade.Objects, nil
        for dy = -3, 3 do
            for dx = -3, 3 do
                local s = getCell():getGridSquare(px + dx, py + dy, pz)
                if not square and s and Objects.find(s, Objects.TERMINAL) then square = s end
            end
        end
        if not square then at("no terminal within reach: run part c first") return end
        local powered = Objects.powered
        Objects.powered = function() return true end
        local window = OA.Terminal.open(player, square:getX(), square:getY(), square:getZ())
        for _ = 1, 20 do if window.boot then window:bootSkip() end end
        window:activate("docs")
        local view = window.views.docs
        Objects.powered = powered
        -- a save whose story has not opened the docs yet shows the tab locked (no list)
        if not view.flat then at("the docs tab is not open in this save") return end
        Objects.powered = function() return true end
        local record = view:record()
        local Folder, Typing = OA.StoryFolder, OA.Typing
        local doc, note
        for _, entry in ipairs(view.flat) do
            local content = Folder.content(record, entry)
            local mode = content and Typing.MODE[content.kind]
            if mode == "lines" and not doc then doc = entry end
            if mode and mode ~= "lines" and not note then note = entry end
        end
        -- shown as new: nothing kept of it
        local typedState = OA.Story.typedState
        OA.Story.typedState = function() return nil end
        LISTEN_FOLDER = { view = view, record = record, doc = doc, note = note, typedState = typedState,
            powered = powered }
        if doc then view.kept[doc.key] = nil view:show(doc, record) at("document", doc.key) else at("no printed document") end
    end)
    add(12000, function()
        local f = LISTEN_FOLDER
        if not f then return end
        if f.note then f.view.kept[f.note.key] = nil f.view:show(f.note, f.record) at("note", f.note.key) else at("no typed note") end
    end)
    add(12000, function()
        if not LISTEN_FOLDER then return end
        OA.Story.typedState = LISTEN_FOLDER.typedState
        OA.Trade.Objects.powered = LISTEN_FOLDER.powered
        at("end")
    end)
end
add(0, restore)
t.run(steps)
