-- What the breaker box window's files share: sizes, the palette, the list's ids and helpers that format numbers and
-- outline objects in the world (BuildingUtilities/PanelWindow and its parts).
-- The window is drawn with the shared UI kit (PZUIKit, as Operation Acorn's terminal is): its title bar and frame in
-- the palette below, its body and every part of it in the kit's design units (made for a 16 unit Small font, one scale
-- for the screen) and its texts in the kit's faces (the PZ Extension API's sharp UI fonts). The numbers here are design
-- units.
require "PZUIKit/UI"
local BU = BuildingUtilities
local Panels = BU.Panels
local UI = PZUIKit.UI
local Ui = {}
BU.PanelUi = Ui
Ui.UI = UI

local FONT_HGT_SMALL = 16
local ROW = FONT_HGT_SMALL + 6
local PAD = 8
local REFRESH_MS = 5000
local BAR_W = 220
local SCROLLBAR = 16
local LOG = "log"
-- The list's width alone; with the plan, the plan takes its share of the window beside it (at least so wide each).
local LIST_W, MIN_LIST, MIN_PLAN = 520, 470, 280
-- The window's height at first, kept clear of the screen's edges; the share of the screen it takes at most.
local WINDOW_H = 470
local SCREEN_SHARE = 0.92
-- Motion: a tab's content sliding in (so far, so long), a row lit under the mouse (its time to come and go), the
-- accent the window marks what is current and hovered with.
local SWITCH_MS, SLIDE = 180, 18
local HOVER_IN_MS, HOVER_OUT_MS = 50, 90
local ACCENT = { 0.4, 0.75, 1 }

-- The window's colours (the kit's palette names): dark steel with the electric blue accent, amber headings.
local PALETTE = {
    bg = { 0.065, 0.075, 0.09 }, bgAlpha = 0.97, panel = { 0.11, 0.13, 0.16 },
    text = { 0.88, 0.9, 0.92 }, dim = { 0.55, 0.58, 0.62 }, bright = { 1, 1, 1 },
    value = ACCENT, head = { 1, 0.82, 0.45 }, border = { 0.27, 0.32, 0.39 },
    warn = { 1, 0.75, 0.3 }, bad = { 1, 0.42, 0.38 }, good = { 0.5, 0.95, 0.55 },
    sel = ACCENT, title = { 0.12, 0.15, 0.19 }, dark = { 0.065, 0.075, 0.09 },
    inset = { 0.035, 0.04, 0.05 }, off = { 0.4, 0.42, 0.45 }, tabStrip = { 0.1, 0.12, 0.15 },
    water = { 0.45, 0.72, 1 },
}
local OPTION_W = 84
local SEEN = "BuildingUtilitiesSeen"
local OUTSIDE = "outside"
local ROOM_TICK_X = PAD + 14

local function load2(value) return string.format("%.2f", value) end

-- Eased out: fast at first, settling (t from 0 to 1).
local function ease(t)
    t = math.max(0, math.min(1, t))
    local u = 1 - t
    return 1 - u * u * u
end

-- A value moved toward a target over a frame of so many milliseconds, by a time constant: the same speed at any
-- frame rate.
local function approach(value, target, ms, tau)
    return target + (value - target) * math.exp(-ms / tau)
end

local function percent(value, most)
    if not value or not most or most <= 0 then return "-" end
    local share = value * 100 / most
    if share > 0 and share < 0.5 then return "<1%" end
    return string.format("%.0f%%", share)
end

-- The objects of a device, every part of it.
local function deviceObjects(device)
    local entry = device.entry
    local object = BU.objectsWithSprite(entry.x, entry.y, entry.z, entry.sprite)[1]
    return object and BU.objectParts(object) or {}
end

-- The objects a row stands for: a device's, or what is on a producer's square.
local function rowObjects(row)
    if row.device then return deviceObjects(row.device) end
    if row.unit then
        local object = BU.Units.object(row.unit)
        return object and { object } or {}
    end
    if row.at then
        local square = getCell():getGridSquare(row.at.x, row.at.y, row.at.z)
        local _, object = Panels.producerOn(square)
        return object and { object } or {}
    end
    return {}
end

-- Outlines objects for a player, and takes the outlines away again.
local function outline(playerNum, objects, colour, into)
    for _, object in ipairs(objects) do
        object:setHighlightColor(playerNum, colour)
        object:setHighlighted(playerNum, true, false)
        object:setOutlineHighlightCol(playerNum, colour)
        object:setOutlineHighlight(playerNum, true)
        into[#into + 1] = object
    end
end

local function unoutline(playerNum, objects)
    for _, object in ipairs(objects) do
        object:setHighlighted(playerNum, false, false)
        object:setOutlineHighlight(playerNum, false)
    end
end

-- A time left, one way for a battery and for fuel: under an hour, hours up to two days, then days.
local function duration(hours)
    if hours < 1 then return getText("IGUI_BU_DurLessHour") end
    if hours < 48 then return getText("IGUI_BU_DurHours", math.floor(hours + 0.5)) end
    return getText("IGUI_BU_DurDays", math.floor(hours / 24 + 0.5))
end

local function count(set)
    local n = 0
    for _ in pairs(set or {}) do n = n + 1 end
    return n
end

local function nextSchedule(schedule)
    for index, name in ipairs(BU.SCHEDULES) do
        if name == schedule then return BU.SCHEDULES[index % #BU.SCHEDULES + 1] end
    end
    return BU.SCHEDULES[1]
end

Ui.FONT_HGT_SMALL = FONT_HGT_SMALL
Ui.ROW = ROW
Ui.PAD = PAD
Ui.REFRESH_MS = REFRESH_MS
Ui.BAR_W = BAR_W
Ui.SCROLLBAR = SCROLLBAR
Ui.LOG = LOG
Ui.LIST_W = LIST_W
Ui.MIN_LIST = MIN_LIST
Ui.MIN_PLAN = MIN_PLAN
Ui.WINDOW_H = WINDOW_H
Ui.SCREEN_SHARE = SCREEN_SHARE
Ui.PALETTE = PALETTE
Ui.SWITCH_MS = SWITCH_MS
Ui.SLIDE = SLIDE
Ui.HOVER_IN_MS = HOVER_IN_MS
Ui.HOVER_OUT_MS = HOVER_OUT_MS
Ui.ACCENT = ACCENT
Ui.ease = ease
Ui.approach = approach
Ui.OPTION_W = OPTION_W
Ui.SEEN = SEEN
Ui.OUTSIDE = OUTSIDE
Ui.ROOM_TICK_X = ROOM_TICK_X
Ui.load2 = load2
Ui.percent = percent
Ui.deviceObjects = deviceObjects
Ui.rowObjects = rowObjects
Ui.outline = outline
Ui.unoutline = unoutline
Ui.count = count
Ui.duration = duration
Ui.nextSchedule = nextSchedule

return Ui
