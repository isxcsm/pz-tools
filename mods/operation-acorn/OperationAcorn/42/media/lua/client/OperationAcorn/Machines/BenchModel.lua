-- What the bench window shows (the hand bench, 분해대): the things the character carries that can be shredded, a row a
-- kind with how many of it to shred, what the chosen ones take (game time) and give (sample bundles, the first-shred
-- bonus), and the work under way. Bench.group makes the kinds from the bench's candidates (Machines.benchCandidates),
-- looked for when the window opens or the inventory changed; Bench.build makes the texts from plain tables (the tests
-- give it those). Nothing here draws: WindowLayout.bench lays the model out.
require "OperationAcorn/Machines/Machines"
require "OperationAcorn/Machines/WindowModel"
local OA = OperationAcorn
local Machines = OA.Machines
local Model = Machines.WindowModel
local Bench = {}
Machines.BenchModel = Bench

-- The rows the list shows at once (the rest scroll), and the most things looked for.
Bench.ROWS = 7
Bench.LIMIT = 300

local function text(key, ...) return getText(key, ...) end

-- The candidates by kind (full type), by name: { key, name, icon, entries, weight (of one), baseType, chosen }.
-- `was` (the kinds before) keeps the chosen count of a kind still carried, no more than there is of it now.
function Bench.group(entries, was)
    local byKey, kinds = {}, {}
    for _, entry in ipairs(entries) do
        local key = entry.item:getFullType()
        local kind = byKey[key]
        if not kind then
            kind = { key = key, name = entry.item:getName(), icon = key, entries = {}, chosen = 0,
                weight = entry.data.weight or 0, baseType = entry.data.baseType }
            byKey[key] = kind
            kinds[#kinds + 1] = kind
        end
        kind.entries[#kind.entries + 1] = entry
    end
    for _, old in ipairs(was or {}) do
        local kind = byKey[old.key]
        if kind then kind.chosen = math.min(old.chosen, #kind.entries) end
    end
    table.sort(kinds, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.key < b.key
    end)
    return kinds
end

-- The entries chosen to shred: the first `chosen` of each kind, in the list's order.
function Bench.chosen(kinds)
    local out = {}
    for _, kind in ipairs(kinds) do
        for i = 1, math.min(kind.chosen, #kind.entries) do out[#out + 1] = kind.entries[i] end
    end
    return out
end

-- The list's first row kept in its room: 1 up to the last that still fills it.
function Bench.clampTop(top, count)
    return math.max(1, math.min(top or 1, count - Bench.ROWS + 1))
end

-- The model from what the window keeps: input = { id, kinds, top, first = { [baseType] = true } (kinds never
-- shredded), firstBonus (credits), estimate = { count, weight, minutes, bundles, bonus }, work = nil or { done, total } }.
-- Returns { kind, title, icon, tag, light, strip, list, cells, work, canStart, canAll, canNone }.
function Bench.build(input)
    local kinds = input.kinds or {}
    local est = input.estimate or {}
    local work = input.work
    local items = 0
    for _, kind in ipairs(kinds) do items = items + #kind.entries end
    local m = {
        kind = "shredBench", title = Machines.name("shredBench"), icon = Machines.itemFullType("shredBench"),
        tag = text("IGUI_OA_Machine_Tag", Model.number(input.id)),
    }
    if work then
        m.light = { text = text("IGUI_OA_Machine_Job_shred"), tone = "good" }
        m.strip = { text = text("IGUI_OA_Bench_Working"), tone = "good" }
    else
        m.light = { text = text("IGUI_OA_Machine_State_idle"), tone = "off", hollow = true }
        if #kinds == 0 then
            m.strip = { text = text("IGUI_OA_Machine_Reason_nothingToShred"), tone = "off" }
        else
            m.strip = { text = text("IGUI_OA_Machine_Hint_shredBench"), tone = "warn" }
        end
    end
    local top = Bench.clampTop(input.top, #kinds)
    local list = { right = text("IGUI_OA_Bench_CarriedRight", #kinds, items), top = top, total = #kinds,
        shown = Bench.ROWS, rows = {}, locked = work ~= nil }
    if #kinds == 0 then list.empty = text("IGUI_OA_Bench_Empty") end
    for i = top, math.min(#kinds, top + Bench.ROWS - 1) do
        local kind = kinds[i]
        local n = #kind.entries
        list.rows[#list.rows + 1] = {
            index = i, key = kind.key, icon = kind.icon, name = kind.name,
            weight = text("IGUI_OA_Bench_Weight", Model.amount(kind.weight)),
            chosen = kind.chosen, count = n, pick = tostring(kind.chosen), of = " / " .. n,
            first = input.first and input.first[kind.baseType] and text("IGUI_OA_Bench_First") or nil,
            firstTip = text("IGUI_OA_Bench_FirstTip", OA.round(input.firstBonus or 0)),
            canLess = not work and kind.chosen > 0, canMore = not work and kind.chosen < n,
        }
    end
    m.list = list
    local count = est.count or 0
    local none = count == 0
    m.cells = {
        { value = text("IGUI_OA_Bench_Count", count),
            sub = text("IGUI_OA_Bench_ChosenSub", Model.amount(est.weight or 0)) },
        { value = none and "-" or Model.duration((est.minutes or 0) / 60), sub = text("IGUI_OA_Bench_TimeSub") },
        { value = none and "-" or text("IGUI_OA_Bench_Bundles", Model.amount(est.bundles or 0)),
            sub = (est.bonus or 0) > 0 and text("IGUI_OA_Bench_YieldBonus", OA.round(est.bonus))
                or text("IGUI_OA_Bench_YieldSub"),
            subTone = (est.bonus or 0) > 0 and "good" or nil },
    }
    if work then
        local total = math.max(1, work.total or 1)
        m.work = { share = OA.clamp((work.done or 0) / total, 0, 1),
            text = text("IGUI_OA_Bench_Progress", work.done or 0, total),
            left = none and "" or text("IGUI_OA_Bench_Left", Model.duration((est.minutes or 0) / 60)) }
    end
    m.canStart = not work and count > 0
    m.canAll = not work and count < items
    m.canNone = not work and count > 0
    return m
end

return Bench
