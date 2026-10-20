-- The terminal's record tab (DESIGN-terminal 1.1, 2), a row of sub-tabs (Trade/TabGroup) under a strip of the trust
-- level (which terminal this is, the level and its bar): the progress (the trust road) and the track record (the
-- codex, the sweep, the kills, the missions). The trust level and the balance in short stand on the window's tab
-- strip whatever tab is on show (OATerminalWindow:drawHead).
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Trade/TabGroup"
require "OperationAcorn/Trade/StatusDraw"
require "OperationAcorn/Trade/StatusModel"
require "OperationAcorn/Trade/TabProgress"
require "OperationAcorn/Trade/TabRecords"
require "OperationAcorn/Economy/Trust"
local OA = OperationAcorn
local Trade, UI, Text = OA.Trade, OA.Trade.UI, OA.Trade.Text
local Trust = OA.Trust
local M = Trade.StatusModel

OATabStatus = {}

-- The record tab's strip of the trust level.
OATabStatus.TOP_H = 54

local function subLabel(id)
    return getText("IGUI_OA_Terminal_Sub_" .. id)
end

local function make(class)
    return function(x, y, w, h, window) return class:new(x, y, w, h, window) end
end

-- The trust level's words: "신뢰도 2단계 · 분류" up to the 5th stage, the bare number after it, the handover at 8.
function OATabStatus.levelText(tier)
    if tier <= Trust.STAGES then return getText("IGUI_OA_Terminal_Level", tier, getText(Trust.stageNameKey(tier))) end
    if tier == M.HANDOVER then return getText("IGUI_OA_Terminal_Level", tier, getText("IGUI_OA_Terminal_LevelHandover")) end
    return getText("IGUI_OA_Terminal_LevelPlain", tier)
end

-- The record tab --------------------------------------------------------------------------------------------------

-- What the strip shows, worked out when the record changes (the frames only draw it).
function OATabStatus.topLines(group, record)
    local tier = Trust.tier(record)
    local pr = Trust.progress(record)
    local span = math.max(1, pr.to - pr.from)
    local p = group:palette()
    local nf = p.numberFont
    local trust, to = Text.credits(pr.trust), Text.credits(pr.to)
    local nextLevel, left = getText("IGUI_OA_Terminal_ToLevel", tier + 1), Text.credits(math.max(0, pr.to - pr.trust))
    return {
        -- the trust line's parts as `run` draws them, made here and not every frame
        run = { { trust, p.text, nf }, { " / ", p.dim }, { to, p.dim, nf }, { Text.DOT .. nextLevel .. " ", p.dim },
            { left, p.text, nf } },
        level = OATabStatus.levelText(tier),
        frac = math.max(0, math.min(1, (pr.trust - pr.from) / span)),
    }
end

-- Draws texts one after another from x; each { text, colour, font }. Returns the x after the last.
local function run(el, x, y, parts)
    for _, part in ipairs(parts) do
        local before, more = UI.spaceGaps(part[1], part[3])
        UI.text(el, part[1], x + before, y, part[2], part[3])
        x = x + UI.textWidth(part[1], part[3]) + more
    end
    return x
end

-- The strip: which terminal this is, the level, its bar and how far the next is.
local function drawTop(group)
    local t = group.headLines
    local p = group:palette()
    local w = group.width
    local field = group.window.tier == "field"
    local badge = UI.str(field and "IGUI_OA_Terminal_Field" or "IGUI_OA_Terminal_Crude")
    -- the badge widens for a longer name (another language), and the level moves right with it
    if group.badgeText ~= badge then
        group.badgeText, group.badgeW = badge, math.max(76, UI.textWidth(badge) + 12)
    end
    local bw = group.badgeW
    if field then
        UI.fill(group, 0, 4, bw, 20, p.tabStrip)
        UI.textCentre(group, badge, bw / 2, 6, p.value)
    else
        UI.frame(group, 0, 4, bw, 20, p.dim)
        UI.textCentre(group, badge, bw / 2, 6, p.dim)
    end
    local x0 = bw + 12
    UI.text(group, t.level, x0, 1, p.bright, UIFont.Medium)
    local barW = w - x0
    UI.fill(group, x0, 29, barW, 7, p.dim, 0.35)
    UI.fill(group, x0, 29, math.floor(barW * t.frac + 0.5), 7, field and p.value or p.sel)
    UI.frame(group, x0, 29, barW, 7, p.border)
    run(group, x0, 37, t.run)
end

OATabStatus.RECORDS = {
    subs = { { id = "progress", make = make(OATabProgress) }, { id = "records", make = make(OATabRecords) } },
    label = subLabel,
    -- the progress's dot: a new level not shown yet, or at the crude terminal the field terminal can be bought
    items = function(group, record, item)
        if item.id == "progress" then
            item.dot = M.progressMark(record, group.window.tier == "field", group.sub)
        end
    end,
    head = {
        h = OATabStatus.TOP_H,
        refresh = function(group, record) group.headLines = OATabStatus.topLines(group, record) end,
        draw = drawTop,
    },
}

-- The tabs ---------------------------------------------------------------------------------------------------------

-- The record tab's dot: a new level (priority 4), until the progress screen has shown it (ui.seen.road). (The crude
-- terminal's hint that the field terminal can be bought stays on the progress's sub-tab: it is no news to blink for.)
OA.Terminal.addTab("records", OATabGroup.factory("records", OATabStatus.RECORDS), {
    mark = function(record) return M.roadFresh(record) and "new" or nil end,
    seen = function(record, window)
        if window and window:subOn("records") == "progress" then return "road", Trust.tier(record) end
        return nil
    end,
})

return OATabStatus
