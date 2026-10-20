-- The mod's moodles (육감, 물림 내성 회복 중, 억제 중, 검사 전, 적응 중). With MoodleFramework (MF) active, they are MF's:
-- the moodle library other mods build on (ETW), which the mods that draw the moodle column themselves follow
-- (PlainMoodles), so they show wherever those mods' moodles do; MF draws them under the game's column. Without MF, in
-- the game's own column through the extension API (PZExtAPI.moodles): the game draws them, places them, wiggles them
-- and shows their tooltips (Translate/<lang>/Moodles.json, a name and a text for each level). In a game without the
-- API's moodle hooks they are drawn as stand-ins left of the game's column instead, one under the other, on the game's
-- moodle background tinted as the game tints it, with the name and text when the mouse is over one. A moodle is set
-- only when its level changes.
require "ISUI/ISPanel"
require "OperationAcorn/Client"
require "OperationAcorn/Trade/UI"
local OA = OperationAcorn
local UI = OA.Trade.UI
OA.Upgrades = OA.Upgrades or {}
local Moodles = {}
OA.Upgrades.Moodles = Moodles

local SIZES = { 32, 48, 64, 80, 96, 128 }
local SHIELD = "media/textures/OA_Moodle_BiteShield_%d_{size}.png"

-- The moodles, in the stand-ins' order: kind ("good", "bad" or "neutral") and picture ({size}: the moodle size; a
-- list: one for each level, 1 to 4).
Moodles.DEFS = {
    { id = "sixth", kind = "neutral", picture = "media/textures/OA_Moodle_Sixth_{size}.png" },
    { id = "biteShield", kind = "bad",
      picture = { string.format(SHIELD, 1), string.format(SHIELD, 2), string.format(SHIELD, 3), string.format(SHIELD, 4) } },
    -- a delay drug holds (the level: a day or less left, up to 3, 5 and 7 days) and a zombie wound waits for a test
    { id = "suppressed", kind = "neutral", picture = "media/textures/OA_Moodle_Suppressed_{size}.png" },
    { id = "untested", kind = "bad", picture = "media/textures/OA_Moodle_Untested_{size}.png" },
    -- a dose of an upgrade serum is being adapted to (Adapting.lua)
    { id = "adapting", kind = "neutral", picture = "media/textures/OA_Moodle_Adapting_{size}.png" },
}
local byId = {}
for _, def in ipairs(Moodles.DEFS) do byId[def.id] = def end

local how = nil          -- nil until decided, "mf", "api" or "draw"
local levels = {}        -- id -> the level shown
local inColumn = {}      -- id -> true when the game's column shows it (defined through the API)
local types = {}         -- id -> the game's MoodleType the API registered for it

-- Whether a moodle shown is one of the stand-ins: neither MF's nor in the game's column.
local function standIn(id)
    return how ~= "mf" and not inColumn[id]
end

-- Whether the hooks the API's moodles need went in: true, false, or nil while their classes have not loaded.
local function hooksIn(api)
    local ok, hooks = pcall(api.hooks)
    if not ok or type(hooks) ~= "table" then return false end
    local level, picture = hooks["Moodle.Update:level"], hooks["MoodlesUI.render"]
    if level == "applied" and picture == "applied" then return true end
    if level == "not-loaded" or picture == "not-loaded" then return nil end
    return false
end

-- ---- the stand-ins ---------------------------------------------------------------------------------------------

local Panel = ISPanel:derive("ISOAMoodleStandIns")

-- The element is one pixel at the screen's corner and draws past its bounds (as Visual Sounds' does): the game gives a
-- click on any element under the mouse to it and not to the world, consuming events or not, so a full-screen one took
-- every click in the world. screenW and screenH are the player's screen it draws over.
function Panel:new(playerNum)
    local o = ISPanel.new(self, getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum), 1, 1)
    o.screenW, o.screenH = getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)
    o.playerNum = playerNum
    o.background = false
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    o.moveWithMouse = false
    return o
end

function Panel:prerender() end

-- The background's tint at a level, as the game's column has it: grey, toward the good or bad colour by level over 4.
local GREY = 0.42
local function tint(kind, level)
    local t = level / 4
    if kind == "bad" then return GREY + 0.45 * t, GREY - 0.22 * t, GREY - 0.22 * t end
    if kind == "good" then return GREY - 0.22 * t, GREY + 0.35 * t, GREY - 0.22 * t end
    return GREY, GREY, GREY
end

-- The textures are fetched once: [size] = the background, [def.id][level * 1000 + size] = a picture (false: none).
local backs, pictures = {}, {}

local function backOf(size)
    local back = backs[size]
    if back == nil then
        back = getTexture("media/ui/Moodles/" .. size .. "/_Moodles_BGsolid.png") or false
        backs[size] = back
    end
    return back
end

local function pictureOf(def, level, size)
    local byLevel = pictures[def.id]
    if not byLevel then
        byLevel = {}
        pictures[def.id] = byLevel
    end
    local key = level * 1000 + size
    local tex = byLevel[key]
    if tex == nil then
        local path = type(def.picture) == "table" and def.picture[level] or def.picture
        tex = getTexture((string.gsub(path, "{size}", tostring(size)))) or false
        byLevel[key] = tex
    end
    return tex
end

-- Where the stand-ins go (their size, and the first's place: left of the game's column) and which one the mouse is
-- over (its place in the column, 0 for none), written to the panel. The panel is one pixel and never has the mouse, so
-- PZ Optimization would not draw it afresh for a hover: this runs each frame before the UI draws (Trade/UI live), and
-- a value it changes is drawn at once. Gives the hovered one (the look).
function Panel:place()
    local option = getCore():getOptionMoodleSize()
    local size = SIZES[option] or ((getCore():getScreenHeight() > 1200) and 64 or 48)
    local column = UIManager.getMoodleUI(self.playerNum)
    local x, y = self.screenW - size - 8, size * 2
    if column then
        x = column:getX() - self.x - size - 6
        y = column:getY() - self.y
    end
    local mx, my = getMouseX() - self.x, getMouseY() - self.y
    local hover, at = 0, 0
    if mx >= x and mx < x + size and my >= y then
        for _, def in ipairs(Moodles.DEFS) do
            if (levels[def.id] or 0) > 0 and standIn(def.id) then
                at = at + 1
                local top = y + (at - 1) * (size + 4)
                if my >= top and my < top + size then hover = at end
            end
        end
    end
    self.size, self.atX, self.atY, self.hover = size, x, y, hover
    return hover
end

function Panel:render()
    if not self.size then self:place() end
    local size, x, y = self.size, self.atX, self.atY
    local back = backOf(size)
    local at = 0
    for _, def in ipairs(Moodles.DEFS) do
        local level = levels[def.id] or 0
        if level > 0 and standIn(def.id) then
            at = at + 1
            local r, g, b = tint(def.kind, level)
            if back then self:drawTextureScaled(back, x, y, size, size, 0.9, r, g, b) end
            local icon = pictureOf(def, level, size)
            if icon then self:drawTextureScaled(icon, x, y, size, size, 1, 1, 1, 1) end
            if at == self.hover then
                local key = "Moodles_" .. OA.MOD .. ":" .. def.id
                local name, text = UI.str(key .. "_lvl" .. level), UI.str(key .. "_desc_lvl" .. level)
                local tm = getTextManager()
                local w = math.max(tm:MeasureStringX(UIFont.Small, name), tm:MeasureStringX(UIFont.Small, text)) + 16
                local fh = tm:getFontHeight(UIFont.Small)
                local tx = x - w - 6
                self:drawRect(tx, y, w, fh * 2 + 12, 0.75, 0, 0, 0)
                self:drawText(name, tx + 8, y + 4, 1, 1, 1, 1, UIFont.Small)
                self:drawText(text, tx + 8, y + 6 + fh, 0.8, 0.8, 0.8, 1, UIFont.Small)
            end
            y = y + size + 4
        end
    end
end

local panel = nil

-- Shows the stand-ins' panel while one is drawn; a count written to it tells PZ Optimization a level changed.
local function standIns()
    local any = false
    for _, def in ipairs(Moodles.DEFS) do
        if (levels[def.id] or 0) > 0 and standIn(def.id) then any = true end
    end
    if any and not panel then
        panel = Panel:new(0)
        panel:initialise()
        panel:instantiate()
        panel.javaObject:setConsumeMouseEvents(false)
        panel:addToUIManager()
        panel:backMost()
    end
    if panel then
        panel:setVisible(any)
        panel.rev = (panel.rev or 0) + 1
        -- followed each frame while it shows (a hidden panel was let go)
        if any then UI.live(panel, Panel.place) end
    end
end

-- ---- MoodleFramework -----------------------------------------------------------------------------------------

-- MF has good and bad moodles only (a neutral value hides one): ours that are neutral (육감, 억제 중, 적응 중: the
-- character's own good) are good ones. A level is MF's value past its default thresholds (bad 0.1 to 0.4, good 0.6 to
-- 0.9); 0.5 hides it. Its name is the prefix and the id.
Moodles.MF_PREFIX = "OperationAcorn_"
local GOOD, BAD = 1, 2
local MF_VALUES = { [GOOD] = { 0.65, 0.75, 0.85, 0.95 }, [BAD] = { 0.35, 0.25, 0.15, 0.05 } }

local function sideOf(def)
    return def.kind == "bad" and BAD or GOOD
end

-- Whether MF is active: its table, or its mod on (its file read now when ours came first). The mod list does not
-- change under a running game.
local function mfActive()
    local mf = rawget(_G, "MF")
    if type(mf) ~= "table" and type(getActivatedMods) == "function" then
        local ok, on = pcall(function()
            local mods = getActivatedMods()
            for i = 0, mods:size() - 1 do
                if string.find(string.lower(tostring(mods:get(i))), "moodleframework", 1, true) then return true end
            end
            return false
        end)
        if ok and on then pcall(require, "MF_ISMoodle") end
        mf = rawget(_G, "MF")
    end
    return type(mf) == "table" and type(mf.createMoodle) == "function" and type(mf.getMoodle) == "function"
        and type(mf.ISMoodle) == "table"
end

-- A level's text of ours (Moodles.json): the level's, else the nearest one under it that has one.
local function levelText(key, level)
    for l = level, 1, -1 do
        local t = getTextOrNull(key .. "_lvl" .. l)
        if t then return t end
    end
    return ""
end

-- The local player's MF moodle for a def, made (and given our names, texts and pictures) the first time.
local function mfMoodle(def)
    local name = Moodles.MF_PREFIX .. def.id
    local moodle = MF.getMoodle(name, 0)
    if not moodle then
        local player = getSpecificPlayer(0)
        if not player then return nil end
        moodle = MF.ISMoodle:new(name, player)
    end
    if not moodle.oaReady then
        moodle.oaReady = true
        local side = sideOf(def)
        local size = MF.getSize and MF.getSize() or 48
        local key = "Moodles_" .. OA.MOD .. ":" .. def.id
        for level = 1, 4 do
            moodle:setTitle(side, level, levelText(key, level))
            moodle:setDescription(side, level, levelText(key .. "_desc", level))
            local picture = pictureOf(def, level, size)
            if picture then moodle:setPicture(side, level, picture) end
        end
    end
    return moodle
end

-- MF makes a moodle for each character as it is made: ours are named to it once, before (and made at once for the
-- character there is).
local function mfStart()
    for _, def in ipairs(Moodles.DEFS) do MF.createMoodle(Moodles.MF_PREFIX .. def.id) end
end

local function decide()
    if how then return how end
    if mfActive() then
        how = "mf"
        mfStart()
        return how
    end
    local api, handle = OA.api(), OA.handle()
    if not (api and handle and type(api.moodles) == "table") then
        how = "draw"
    else
        local hooked = hooksIn(api)
        if hooked == nil then return nil end
        how = hooked and "api" or "draw"
    end
    return how
end

-- ---- a moodle mod that draws the column itself -------------------------------------------------------------------

-- PlainMoodles (PlainMoodlesLevels) hides the game's moodle column and draws its own from a fixed list of the game's
-- moodle types (and MoodleFramework's), so a type registered through the API is never in it. Its list (getTypes) is
-- given ours as they are defined, each with an icon name of our own that its texture lookup (getUiTexture) answers
-- with our picture. Its plate, level marks, order and tooltips (the translation name's Moodles.json keys) are its own.
-- Feature-checked, not by version: without that table or those functions nothing is done.
local ICON = "OA_Moodle_"
function Moodles.plain()
    local PML = rawget(_G, "PlainMoodlesLevels")
    if type(PML) ~= "table" or type(PML.getTypes) ~= "function" or type(PML.getUiTexture) ~= "function" then return false end
    if not PML.oaHooked then
        PML.oaHooked = true
        local getTypes, getUiTexture = PML.getTypes, PML.getUiTexture
        PML.getTypes = function(...)
            local list = getTypes(...)
            if type(list) ~= "table" then return list end
            PML.typeIcons = PML.typeIcons or {}
            for _, def in ipairs(Moodles.DEFS) do
                local t = types[def.id]
                if t and not PML.oaListed then PML.oaListed = {} end
                if t and not PML.oaListed[def.id] then
                    PML.oaListed[def.id] = true
                    list[#list + 1] = t
                    PML.typeIcons[#list] = ICON .. def.id
                end
            end
            return list
        end
        PML.getUiTexture = function(size, name)
            local id = type(name) == "string" and string.sub(name, 1, #ICON) == ICON and string.sub(name, #ICON + 1)
            local def = id and byId[id]
            if def then return pictureOf(def, math.max(1, levels[id] or 1), size) or nil end
            return getUiTexture(size, name)
        end
    end
    return true
end
OA.on("OnGameStart", function() Moodles.plain() end)

-- ---- setting a level -------------------------------------------------------------------------------------------

-- The level (0 to 4; 0 hides it) the moodle `id` shows for the local player. Nothing is done while the level is the
-- one shown; nothing is defined for a moodle that never shows.
function Moodles.set(id, level)
    local def = byId[id]
    if not def then return end
    level = level or 0
    if (levels[id] or 0) == level then return end
    local way = decide()
    if way == nil then return end          -- the API's classes not loaded yet: the next call decides
    if way == "mf" then
        local moodle = mfMoodle(def)
        if not moodle then return end      -- no character yet: the next call
        moodle:setValue(level > 0 and MF_VALUES[sideOf(def)][math.min(level, 4)] or 0.5)
        levels[id] = level
        return
    end
    if way == "api" and inColumn[id] == nil then
        local ok, err = pcall(PZExtAPI.moodles.define, OA.handle(), id, { kind = def.kind, picture = def.picture })
        inColumn[id] = ok
        if ok then
            types[id] = err
            Moodles.plain()
        else
            OA.log("moodle", id, tostring(err))
        end
    end
    if inColumn[id] then
        local ok, err = pcall(PZExtAPI.moodles.set, OA.handle(), id, level)
        if not ok then
            OA.log("moodle", id, tostring(err))
            return
        end
    end
    levels[id] = level
    standIns()
end

-- The level the moodle shows now (0 when hidden).
function Moodles.level(id)
    return levels[id] or 0
end

return Moodles
