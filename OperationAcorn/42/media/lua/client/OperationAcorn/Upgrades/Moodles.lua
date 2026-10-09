-- The mod's moodles (육감, 물림 내성 회복 중): in the game's own column through the extension API (PZToolsAPI.moodles):
-- the game draws them, places them, wiggles them and shows their tooltips (Translate/<lang>/Moodles.json, a name and
-- a text for each level). In a game without the API's moodle hooks they are drawn as stand-ins left of the game's
-- column instead, one under the other, on the game's moodle background tinted as the game tints it, with the name and
-- text when the mouse is over one. A moodle is set only when its level changes.
require "ISUI/ISPanel"
require "OperationAcorn/Client"
local OA = OperationAcorn
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
}
local byId = {}
for _, def in ipairs(Moodles.DEFS) do byId[def.id] = def end

local how = nil          -- nil until decided, "api" or "draw"
local levels = {}        -- id -> the level shown
local inColumn = {}      -- id -> true when the game's column shows it (defined through the API)

-- Whether the hooks the API's moodles need went in: true, false, or nil while their classes have not loaded.
local function hooksIn(api)
    local ok, hooks = pcall(api.hooks)
    if not ok or type(hooks) ~= "table" then return false end
    local level, picture = hooks["Moodle.Update:level"], hooks["MoodlesUI.render"]
    if level == "applied" and picture == "applied" then return true end
    if level == "not-loaded" or picture == "not-loaded" then return nil end
    return false
end

local function decide()
    if how then return how end
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

-- ---- the stand-ins ---------------------------------------------------------------------------------------------

local Panel = ISPanel:derive("ISOAMoodleStandIns")

function Panel:new(playerNum)
    local o = ISPanel.new(self, getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum),
        getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum))
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

local function pictureOf(def, level, size)
    local path = type(def.picture) == "table" and def.picture[level] or def.picture
    return getTexture((string.gsub(path, "{size}", tostring(size))))
end

function Panel:render()
    local option = getCore():getOptionMoodleSize()
    local size = SIZES[option] or ((getCore():getScreenHeight() > 1200) and 64 or 48)
    local column = UIManager.getMoodleUI(self.playerNum)
    local x, y = self.width - size - 8, size * 2
    if column then
        x = column:getX() - self.x - size - 6
        y = column:getY() - self.y
    end
    local back = getTexture("media/ui/Moodles/" .. size .. "/_Moodles_BGsolid.png")
    local mx, my = getMouseX() - self.x, getMouseY() - self.y
    for _, def in ipairs(Moodles.DEFS) do
        local level = levels[def.id] or 0
        if level > 0 and not inColumn[def.id] then
            local r, g, b = tint(def.kind, level)
            if back then self:drawTextureScaled(back, x, y, size, size, 0.9, r, g, b) end
            local icon = pictureOf(def, level, size)
            if icon then self:drawTextureScaled(icon, x, y, size, size, 1, 1, 1, 1) end
            if mx >= x and mx < x + size and my >= y and my < y + size then
                local key = "Moodles_" .. OA.MOD .. ":" .. def.id
                local name, text = getText(key .. "_lvl" .. level), getText(key .. "_desc_lvl" .. level)
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

-- Shows the stand-ins' panel while one is drawn.
local function standIns()
    local any = false
    for _, def in ipairs(Moodles.DEFS) do
        if (levels[def.id] or 0) > 0 and not inColumn[def.id] then any = true end
    end
    if any and not panel then
        panel = Panel:new(0)
        panel:initialise()
        panel:instantiate()
        panel.javaObject:setConsumeMouseEvents(false)
        panel:addToUIManager()
        panel:backMost()
    end
    if panel then panel:setVisible(any) end
end

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
    if way == "api" and inColumn[id] == nil then
        local ok, err = pcall(PZToolsAPI.moodles.define, OA.handle(), id, { kind = def.kind, picture = def.picture })
        inColumn[id] = ok
        if not ok then OA.log("moodle", id, tostring(err)) end
    end
    if inColumn[id] then
        local ok, err = pcall(PZToolsAPI.moodles.set, OA.handle(), id, level)
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
