-- What the breaker box window's files share: sizes, the list's ids and helpers that format numbers and outline
-- objects in the world (BuildingUtilities/PanelWindow and its parts).
local BU = BuildingUtilities
local Panels = BU.Panels
local Ui = {}
BU.PanelUi = Ui

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local ROW = FONT_HGT_SMALL + 6
local PAD = 8
local REFRESH_MS = 5000
local BAR_W = 220
local SCROLLBAR = 16
local LOG = "log"
-- The list's width alone; with the plan, the plan takes its share of the window beside it (at least so wide each).
local LIST_W, MIN_LIST, MIN_PLAN = 560, 470, 260
local OPTION_W = 84
local SEEN = "BuildingUtilitiesSeen"
local OUTSIDE = "outside"
local ROOM_TICK_X = PAD + 14
local CHOOSE_W = 90
local BATCH_BUTTONS = { "Connect", "All", "None" }
local BATCH_W = 70

local function load2(value) return string.format("%.2f", value) end

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
Ui.OPTION_W = OPTION_W
Ui.SEEN = SEEN
Ui.OUTSIDE = OUTSIDE
Ui.ROOM_TICK_X = ROOM_TICK_X
Ui.CHOOSE_W = CHOOSE_W
Ui.BATCH_BUTTONS = BATCH_BUTTONS
Ui.BATCH_W = BATCH_W
Ui.load2 = load2
Ui.percent = percent
Ui.deviceObjects = deviceObjects
Ui.rowObjects = rowObjects
Ui.outline = outline
Ui.unoutline = unoutline
Ui.count = count
Ui.nextSchedule = nextSchedule

return Ui
