-- The lines under an item's tooltip (DESIGN-terminal 10): "requested · 660 each · this week 6/10" for an item on this
-- week's request list, and "not seen before" for a kind the codex does not have yet; and the first line, "mission item",
-- for what belongs to the player's mission (9). The tooltip is drawn every frame it is up, so nothing here is worked out
-- then: a line is made once for an item type and kept while the week's list (its table), the number of settlements and
-- the list's length stay the same, and a frame only looks tables up. The record is read as it is, never changed: the list
-- of the week is drawn by the server (Requests.list on the client's copy would draw it again).
--
-- The numbers of a request line are the delivery tab's (5.1, Requests.line).
require "OperationAcorn/Core"
require "OperationAcorn/Store"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Economy/Requests"
require "OperationAcorn/Economy/Value"
require "OperationAcorn/Trade/Text"
local OA = OperationAcorn
local ItemTip = {}
OA.ItemTip = ItemTip

-- The colours of the lines (the amber is paler than the ledger's outline, and the mission's is the mission's).
ItemTip.REQUEST_COLOR = { 1.0, 0.82, 0.35 }
ItemTip.NEW_COLOR = { 0.55, 0.95, 0.60 }

-- The request of this week for an item type (its group's line): price, count a week, count settled; nil when the
-- group is not on the list.
function ItemTip.requestOf(record, fullType)
    local codex = record.codex
    local rq = codex and codex.req
    if not rq or not rq.items then return nil end
    local key = OA.Requests.keyOf(fullType)
    local listed = false
    for i = 1, #rq.items do
        if rq.items[i] == key then listed = true break end
    end
    if not listed then return nil end
    local line = OA.Requests.line(record, key, rq.used or {})
    return line.price, line.qty, math.min(line.used, line.qty)
end

-- The line of a request: { text, color } or nil.
local function requestRow(record, fullType)
    local price, count, done = ItemTip.requestOf(record, fullType)
    if not price then return nil end
    local key = done >= count and "IGUI_OA_ItemTip_RequestFull" or "IGUI_OA_ItemTip_Request"
    return { text = getText(key, OA.Trade.Text.credits(price), done, count), color = ItemTip.REQUEST_COLOR }
end

-- What the codex says of an item type: { loot (the codex counts it), base (the name it counts it by) } or false for a
-- type with no script. Once for a type: it never changes.
local kinds = {}
function ItemTip.kind(fullType)
    local hit = kinds[fullType]
    if hit == nil then
        local script = getScriptManager():FindItem(fullType)
        hit = false
        if script then
            local info = OA.Value.infoFromScript(script)
            hit = { loot = OA.Categories.isLoot(info), base = info.baseType }
        end
        kinds[fullType] = hit
    end
    return hit
end

-- Whether the codex has not seen an item type yet. A bought item is never counted (the shop's), so it is never new.
function ItemTip.isNew(record, fullType, bought)
    if bought then return false end
    local kind = ItemTip.kind(fullType)
    if not kind or not kind.loot then return false end
    local codex = record.codex
    return not (codex and codex.kinds and codex.kinds[kind.base])
end

local NONE = {}
local newRow

-- Per item type: the lines made for a (record, week's list, settlements, list length): { record, rq, serial, n, plain,
-- new } (`plain` the lines without "not seen before", `new` with it).
local cache = {}

-- The lines under the tooltip of an item type for a record: an array of { text, color } (shared: not to be changed).
function ItemTip.rows(record, fullType, bought)
    local codex = record.codex
    local rq = codex and codex.req
    local serial = record.trade and record.trade.serial or 0
    local n = rq and rq.items and #rq.items or 0
    local hit = cache[fullType]
    if not hit or hit.record ~= record or hit.rq ~= rq or hit.serial ~= serial or hit.n ~= n then
        local row = requestRow(record, fullType)
        newRow = newRow or { text = getText("IGUI_OA_ItemTip_New"), color = ItemTip.NEW_COLOR }
        hit = { record = record, rq = rq, serial = serial, n = n,
            plain = row and { row } or NONE, new = row and { row, newRow } or { newRow } }
        cache[fullType] = hit
    end
    if ItemTip.isNew(record, fullType, bought) then return hit.new end
    return hit.plain
end

-- The first line of a mission's item, in the mission's colour: an array of the one { text, color } (one for a colour,
-- made once; shared: not to be changed).
local missionRows = {}
function ItemTip.missionRows(color)
    local rows = missionRows[color]
    if not rows then
        rows = { { text = getText("IGUI_OA_ItemTip_Mission"), color = color } }
        missionRows[color] = rows
    end
    return rows
end

-- Drops what was made (a test that changes the texts, or a new game).
function ItemTip.reset()
    cache, kinds, missionRows, newRow = {}, {}, {}, nil
    scores, scoresOf, scoresN = {}, nil, nil
end

-- Where the strips go (the lines are drawn as strips beside the tooltip's panel, which the game draws itself). `y` and
-- `height` are the panel's, `screen` the screen's height; `above` and `below` what other strips (the appraisal) take
-- above and below the panel already; `top` and `bottom` the heights of the mission strip and of the request and
-- codex strip (0 for none). The request and codex strip go below the panel and the mission strip above it, as far as
-- the screen has room: what does not fit goes to the other side (the mission strip below the panel's other strips, the
-- others above). A strip overlaps the next by a pixel, so that their borders are one. Returns the strips' tops
-- relative to the panel's: top (or nil), bottom (or nil).
function ItemTip.place(y, height, screen, above, below, top, bottom)
    local topY, bottomY
    if bottom > 0 then
        if y + height + below + bottom <= screen then
            bottomY = height + below - 1
            below = below + bottom
        else
            bottomY = -(above + bottom) + 1
            above = above + bottom
        end
    end
    if top > 0 then
        if y - above - top >= 0 then
            topY = -(above + top) + 1
        else
            topY = height + below - 1
        end
    end
    return topY, bottomY
end

return ItemTip
