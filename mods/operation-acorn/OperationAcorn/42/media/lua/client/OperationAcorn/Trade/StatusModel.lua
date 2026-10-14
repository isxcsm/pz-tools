-- What the status tab shows (DESIGN-terminal 2), worked out from a record as plain tables of texts and numbers: the
-- helicopter and this flight's waybill, the trust road and what each level opens, the flight support cards, the
-- record of finds, and the board a field terminal shows the first time it is opened (12). The views (TabHeli,
-- TabProgress, TabUpgrades, TabRecords, TabStatus) lay these out and draw them; nothing here draws or measures text,
-- so it is tested outside the game. Everything is worked out when the record changes, never per frame.
--
-- A text with parts in other colours is a list of parts { s, arg = n }: M.parts translates a key with its arguments
-- marked, so the view can give the n-th argument its own colour (a number in the number font) in any language's order.
require "OperationAcorn/Core"
require "OperationAcorn/Economy/Trust"
require "OperationAcorn/Economy/Support"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Economy/Codex"
require "OperationAcorn/Economy/Categories"
require "OperationAcorn/Trade/Terminal"
require "OperationAcorn/Trade/Trade"
require "OperationAcorn/Trade/Rules"
require "OperationAcorn/Trade/Boxes"
require "OperationAcorn/Trade/Orders"
require "OperationAcorn/Trade/Estimate"
require "OperationAcorn/Trade/Ledger"
require "OperationAcorn/Trade/Text"
require "OperationAcorn/Story/Places"
local OA = OperationAcorn
local Trade = OA.Trade
local Trust, Support, Shop, Codex, Terminal = OA.Trust, OA.Support, OA.Shop, OA.Codex, OA.Terminal
local Rules, Boxes, Orders, Estimate, Ledger, Text = Trade.Rules, Trade.Boxes, Trade.Orders, Trade.Estimate, Trade.Ledger,
    Trade.Text
local M = {}
Trade.StatusModel = M

local function tr(key, ...)
    return getText(key, ...)
end

local function credits(n)
    return Text.credits(n)
end

-- Parts -------------------------------------------------------------------------------------------------------------

-- A translated text cut into parts: { { s = "...", arg = nil | n } }, arg being the argument's number.
function M.parts(key, ...)
    local args = {}
    for i = 1, select("#", ...) do args[i] = "\1" .. i .. "\3" .. tostring(select(i, ...)) .. "\2" end
    return M.split(tr(key, unpack(args)))
end

function M.split(text)
    local out, pos = {}, 1
    while true do
        local a = string.find(text, "\1", pos, true)
        if not a then break end
        if a > pos then out[#out + 1] = { s = string.sub(text, pos, a - 1) } end
        local mid = string.find(text, "\3", a + 1, true)
        local b = string.find(text, "\2", a + 1, true) or (#text + 1)
        if mid and mid < b then
            out[#out + 1] = { s = string.sub(text, mid + 1, b - 1), arg = tonumber(string.sub(text, a + 1, mid - 1)) }
        else
            out[#out + 1] = { s = string.sub(text, a + 1, b - 1) }
        end
        pos = b + 1
    end
    if pos <= #text then out[#out + 1] = { s = string.sub(text, pos) } end
    return out
end

-- The parts as one plain string (a tooltip, a test).
function M.plain(parts)
    local s = {}
    for i, p in ipairs(parts or {}) do s[i] = p.s end
    return table.concat(s)
end

-- Levels and their names --------------------------------------------------------------------------------------------

-- The road's nodes: 1..5 the stages, 6..8 the levels after them (Trust's milestones; 8 is the handover), 9 every
-- level from the ninth on.
M.LEVELS = 9
M.HANDOVER = Trust.STAGES + 3

-- "3 대조", "6단계", "8 이관", "9단계~": a node's label on the road.
function M.nodeName(t)
    if t <= Trust.STAGES then return tr("IGUI_OA_Status_Node", t, tr(Trust.stageNameKey(t))) end
    if t == M.HANDOVER then return tr("IGUI_OA_Status_Node", t, tr("IGUI_OA_Terminal_LevelHandover")) end
    if t >= M.LEVELS then return tr("IGUI_OA_Status_NodeLast", t) end
    return tr(Trust.MILESTONE_NAME_KEY, t)
end

-- "3단계 대조", "6단계", "8단계 이관", "9단계부터": a level's full name.
function M.levelName(t)
    if t <= Trust.STAGES then return tr("IGUI_OA_Status_LevelName", t, tr(Trust.stageNameKey(t))) end
    if t == M.HANDOVER then return tr("IGUI_OA_Status_LevelName", t, tr("IGUI_OA_Terminal_LevelHandover")) end
    if t >= M.LEVELS then return tr("IGUI_OA_Status_LevelFrom", t) end
    return tr(Trust.MILESTONE_NAME_KEY, t)
end

-- "5단계부터": what a locked step waits for.
function M.fromText(t)
    return tr("IGUI_OA_Status_From", t)
end

-- Trust a level needs (1..5 the stages, then the milestones).
function M.threshold(t)
    if t <= Trust.STAGES then return Trust.stageThreshold(t) end
    return Trust.milestoneThreshold(t - Trust.STAGES)
end

-- What each level opens (DESIGN-terminal 2.3.1) ---------------------------------------------------------------------

-- The shop's goods a screen lists: not the upgrade serums (their own section), not the box (the reissue button), not
-- what the shop hides (kits when they are off, goods whose item is not defined).
function M.listed(entry)
    if entry.group == "serum" or entry.group == "box" or entry.special == "reissue" then return false end
    if entry.kits and not OA.option("KitsForSale") then return false end
    return Shop.stocked(entry)
end

-- The goods a level opens: on every terminal (field = false) or only on the field terminal (field = true).
function M.laneItems(t, field)
    local list = {}
    for _, e in ipairs(Shop.catalog()) do
        if e.tier == t and M.listed(e) and Shop.fieldOnly(e) == field then list[#list + 1] = e end
    end
    return list
end

-- Shared serums a level brings (Trust: stages 2..5 one each, the milestones one each or every few).
function M.serumsAt(t)
    if t <= Trust.STAGES then return Trust.stageSerums(t) end
    return Trust.milestoneSerums(t - Trust.STAGES)
end

-- Trust acceleration from a level (Trust's ACCEL: +10% at 6, +20% at 8), in percent.
M.ACCEL = { [6] = 10, [8] = 20 }

-- The short words under a node's icons on every terminal: missions and the request bands (Requests.eligible: the
-- common band at 1, the rare at 2), the handover, the acceleration, the serum, the endless levels.
function M.chipsA(t)
    local out = {}
    if t == 1 then
        out[#out + 1] = tr("IGUI_OA_Status_Chip_missions")
        out[#out + 1] = tr("IGUI_OA_Status_Chip_common")
    elseif t == 2 then
        out[#out + 1] = tr("IGUI_OA_Status_Chip_rare")
    end
    if t == M.HANDOVER then out[#out + 1] = tr("IGUI_OA_Status_Chip_handover") end
    if M.ACCEL[t] then out[#out + 1] = tr("IGUI_OA_Status_Chip_accel", M.ACCEL[t]) end
    if M.serumsAt(t) > 0 then out[#out + 1] = tr("IGUI_OA_Status_Chip_serum") end
    if t >= M.LEVELS then out[#out + 1] = tr("IGUI_OA_Status_Chip_endless") end
    return out
end

-- The same as whole lines, for the chosen level's list.
function M.moreA(t)
    local out = {}
    if t >= M.LEVELS then
        out[#out + 1] = tr("IGUI_OA_Status_More_serumEach")
        out[#out + 1] = tr("IGUI_OA_Status_More_steeper")
        return out
    end
    if t == 1 then
        out[#out + 1] = tr("IGUI_OA_Status_More_missions")
        out[#out + 1] = tr("IGUI_OA_Status_More_common")
    elseif t == 2 then
        out[#out + 1] = tr("IGUI_OA_Status_More_rare")
    end
    if t == M.HANDOVER then out[#out + 1] = tr("IGUI_OA_Status_More_handover") end
    if M.ACCEL[t] then out[#out + 1] = tr("IGUI_OA_Status_More_accel", M.ACCEL[t]) end
    if t == M.HANDOVER then out[#out + 1] = tr("IGUI_OA_Status_More_kitVoucher") end
    if M.serumsAt(t) > 0 then out[#out + 1] = tr("IGUI_OA_Status_More_serum") end
    return out
end

-- The upgrade levels a level makes available: { { id, level } } in the screen's order (the box's endless levels are
-- the 9th node's own words).
function M.upgradesOpening(t)
    local out = {}
    for _, u in ipairs(Support.LIST) do
        for k, s in ipairs(u.steps) do
            if s[2] == t then out[#out + 1] = { id = u.id, level = k } end
        end
    end
    return out
end

-- An upgrade's value as a text ("100", "3~4시간", "밤에도").
function M.valueText(id, value)
    return Text.trText(Support.valueText(id, value))
end

-- "상자 용량 100", or the name a yes-or-no upgrade goes by ("야간 투하").
function M.openingText(id, level)
    local value = Support.step(id, level).value
    if type(value) == "boolean" then return tr("IGUI_OA_Status_Bin_" .. id) end
    return tr(Support.nameKey(id)) .. " " .. M.valueText(id, value)
end

-- The field terminal lane's words: the special requests at 2, how many upgrades open, the box at the endless levels.
function M.chipsB(t)
    if t >= M.LEVELS then return { tr("IGUI_OA_Status_Chip_box", Support.get("box").endless.add) } end
    local out = {}
    if t == 2 then out[#out + 1] = tr("IGUI_OA_Status_Chip_special") end
    local n = #M.upgradesOpening(t)
    if n > 0 then out[#out + 1] = tr("IGUI_OA_Status_Chip_upgrades", n) end
    return out
end

-- The upgrade column of the chosen level's list.
function M.upgradeLines(t)
    if t >= M.LEVELS then
        local e = Support.get("box").endless
        return { tr("IGUI_OA_Status_Up_boxEach", e.add), tr("IGUI_OA_Status_Up_boxPrice", credits(e.step)) }
    end
    local out = {}
    for _, o in ipairs(M.upgradesOpening(t)) do out[#out + 1] = M.openingText(o.id, o.level) end
    if #out == 0 then out[1] = tr("IGUI_OA_Status_Nothing") end
    return out
end

-- The node a record stands at (its tier, the 9th for every level past 8) and the share of the way to the next.
function M.roadPosition(record)
    local tier = Trust.tier(record)
    local pr = Trust.progress(record)
    local span = math.max(1, pr.to - pr.from)
    return math.min(tier, M.LEVELS), OA.clamp((pr.trust - pr.from) / span, 0, 1)
end

-- The chosen level's head on the right: "앞으로 신뢰도 1,560" for the next level, "받음" for one reached, "신뢰도
-- 37,000에" for a later one ("신뢰도 121,000부터" for the last, which repeats). Parts, the number as argument 1.
function M.detailNote(record, t)
    local tier = Trust.tier(record)
    if t <= tier then return { { s = tr("IGUI_OA_Status_Got") } } end
    if t == tier + 1 then
        local trust = (record.trade and record.trade.trust) or 0
        return M.parts("IGUI_OA_Status_TrustLeft", credits(math.max(0, M.threshold(t) - trust)))
    end
    return M.parts(t >= M.LEVELS and "IGUI_OA_Status_AtTrustOn" or "IGUI_OA_Status_AtTrust", credits(M.threshold(t)))
end

-- Flight support (DESIGN-terminal 2.6) ------------------------------------------------------------------------------

-- An upgrade for a record at this terminal: its level now, the level that comes next (nil when it has them all) and
-- the state: "max", "pending" (asked for), "locked" (trust has not opened the next), "field" (open, but asked at the
-- crude terminal), "debt" (open, but the balance is a debt), "avail".
function M.upgradeState(record, id, field)
    local cur = Support.level(record, id)
    local pending = record.trade and record.trade.pendingLevels and record.trade.pendingLevels[id]
    if pending then return cur, pending, "pending" end
    local s = Support.step(id, cur + 1)
    if not s then return cur, nil, "max" end
    if Trust.tier(record) < s.tier then return cur, cur + 1, "locked" end
    if not field then return cur, cur + 1, "field" end
    if Trade.inDebt(record) then return cur, cur + 1, "debt" end
    return cur, cur + 1, "avail"
end

-- How many upgrades may be asked for now (of a group, or all): the sub-tab's badge and the group buttons.
function M.countAvail(record, field, group)
    local n = 0
    for _, u in ipairs(Support.LIST) do
        if not group or u.group == group then
            local _, _, state = M.upgradeState(record, u.id, field)
            if state == "avail" then n = n + 1 end
        end
    end
    return n
end

-- The first sentence of a text (a card's dim line).
function M.firstSentence(text)
    local at = string.find(text, ".", 1, true)
    if at then return string.sub(text, 1, at) end
    return text
end

-- "4~6시간" and "3~4시간" written as "4~6" and "3~4시간": the unit after the last digit once, when both share it (not
-- a percent sign, which reads badly alone).
function M.shortPair(a, b)
    local function unit(s)
        local last = 0
        for i = 1, #s do
            local c = string.sub(s, i, i)
            if c >= "0" and c <= "9" then last = i end
        end
        if last == 0 then return nil end
        return string.sub(s, last + 1)
    end
    local ua, ub = unit(a), unit(b)
    if ua and ua ~= "" and ua == ub and ua ~= "%" then return string.sub(a, 1, #a - #ua), b end
    return a, b
end

-- The steps of an upgrade's ladder for the detail column: { { level, value, price, tier } }, level 0 first. The box
-- goes on: its table, the levels up to the one after the record's, then one "and on" row { more = true }.
function M.ladder(id, cur)
    local u = Support.get(id)
    local rows = { { level = 0, value = M.valueText(id, u.base) } }
    local last = #u.steps
    if u.endless then last = math.max(last, (cur or 0) + 1) end
    for k = 1, last do
        local s = Support.step(id, k)
        rows[#rows + 1] = { level = k, value = M.valueText(id, s.value), price = s.price, tier = s.tier }
    end
    if u.endless then
        local s = Support.step(id, last + 1)
        rows[#rows + 1] = { level = last + 1, more = true, value = tr("IGUI_OA_Status_BoxOn", M.valueText(id, s.value)),
            step = u.endless.step, tier = s.tier }
    end
    return rows
end

-- The pending requests as the form's lines: { { id, name, from, to, price } }, from and to shortened together.
function M.requests(record)
    local out = {}
    for _, r in ipairs(Support.requests(record)) do
        local from = M.valueText(r.id, Support.step(r.id, r.from).value)
        local to = M.valueText(r.id, Support.step(r.id, r.to).value)
        from, to = M.shortPair(from, to)
        out[#out + 1] = { id = r.id, name = tr(Support.nameKey(r.id)), from = from, to = to, price = r.price }
    end
    return out
end

-- The helicopter (DESIGN-terminal 2.2) ------------------------------------------------------------------------------

-- A world age as "47일째 15:40".
function M.when(hours)
    local day, h, m = Trade.clockText(hours)
    return tr("IGUI_OA_Trade_When", day, string.format("%02d:%02d", h, m))
end

-- Whether a call made now would reach the night (and so come the next morning): either end of the arrival range
-- falls outside the flying hours, and the night drop is not bought.
function M.nightCall(tod, rewards)
    if rewards.nightDrop then return false end
    local function night(hours)
        local at = Rules.timeOfDayAfter(tod, hours)
        return at < Rules.DAY_START or at >= Rules.DAY_END
    end
    return night(rewards.arrival.min) or night(rewards.arrival.max)
end

-- The helicopter's state: { state, colour, subs = { { text, colour } }, eta = { from, to } (on its way), nextAt (the
-- world age the state changes by itself), callable, callWhy, reissue, reissueWhy } (the whys are texts).
function M.heli(record, now, tod)
    local heli = record.heli or {}
    local rewards = Trust.rewards(record)
    local canTime, why = Rules.canCall(heli, now)
    local canBox, boxWhy = Boxes.canCall(record)
    local s = { subs = {} }
    local function sub(text, colour) s.subs[#s.subs + 1] = { text = text, colour = colour } end
    if heli.call then
        s.state, s.colour = tr("IGUI_OA_Status_Heli_Coming"), "value"
        sub(tr("IGUI_OA_Status_Heli_Arrive", M.when(heli.call.arrive)), "text")
        s.eta = { from = heli.call.at or now, to = heli.call.arrive }
    elseif not canBox or not canTime then
        s.state, s.colour = tr("IGUI_OA_Status_Heli_Cannot"), "warn"
        if not canBox then sub(tr(boxWhy == "carried" and "IGUI_OA_Trade_Heli_BoxCarried" or "IGUI_OA_Trade_Heli_NoBox"), "warn") end
        if not canTime then
            sub(tr("IGUI_OA_Trade_Heli_Next", M.when(heli.next)), "text")
            s.nextAt = heli.next
        end
    else
        s.state, s.colour = tr("IGUI_OA_Status_Heli_Ready"), "bright"
        if M.nightCall(tod, rewards) then sub(tr("IGUI_OA_Status_Heli_Night"), "warn") end
    end
    if Trade.inDebt(record) then sub(tr("IGUI_OA_Status_Heli_Debt"), "bad") end
    s.callable = not heli.call and canTime and canBox
    if heli.call then s.callWhy = tr("IGUI_OA_Trade_Reason_pending")
    elseif not canTime then s.callWhy = tr("IGUI_OA_Trade_Reason_" .. tostring(why))
    elseif not canBox then s.callWhy = tr("IGUI_OA_Trade_Reason_" .. tostring(boxWhy)) end
    s.reissue = not heli.call and canTime and not canBox
    if heli.call then s.reissueWhy = tr("IGUI_OA_Trade_Reason_pending")
    elseif not canTime then s.reissueWhy = tr("IGUI_OA_Trade_Reason_wait")
    elseif canBox then s.reissueWhy = tr("IGUI_OA_Trade_Heli_ReissueOnly") end
    s.night = s.callable and M.nightCall(tod, rewards) or false
    return s
end

-- 헬기 사양: the four values the upgrades raise, as they are now (with the sandbox options).
function M.spec(record)
    local r = Trust.rewards(record)
    return {
        { label = tr("IGUI_OA_Status_Spec_box"), value = M.valueText("box", r.boxCapacity) },
        { label = tr("IGUI_OA_Status_Spec_arrive"), value = M.valueText("arrive", { r.arrival.min, r.arrival.max }) },
        { label = tr("IGUI_OA_Status_Spec_call"), value = M.valueText("call", r.callInterval) },
        { label = tr("IGUI_OA_Status_Spec_night"), value = M.valueText("night", r.nightDrop == true) },
    }
end

-- How long ago, in words.
function M.ago(hours)
    if hours < 1 then return tr("IGUI_OA_Status_Ago_Now") end
    if hours < 24 then return tr("IGUI_OA_Status_Ago_Hours", math.floor(hours)) end
    return tr("IGUI_OA_Status_Ago_Days", math.floor(hours / 24))
end

-- The last settlement's line: parts (1 the time, 2 the credits, 3 the trust), or nil before the first.
function M.lastSettle(record, now)
    local last = Ledger.last(record)
    if not last then return nil end
    local trust = math.floor((last.trust or 0) + 0.5)
    return M.parts("IGUI_OA_Status_LastSettleLine", M.ago(math.max(0, now - (last.at or now))), credits(last.credits or 0),
        "+" .. credits(trust))
end

-- Where the supply crates still lying around are, from the player: the nearest, and how many more. nil for none.
function M.crates(markers, px, py)
    local best, bestD
    for _, m in ipairs(markers or {}) do
        local dx, dy = m.x - px, m.y - py
        local d = dx * dx + dy * dy
        if not bestD or d < bestD then best, bestD = m, d end
    end
    if not best then return nil end
    local text = OA.Places.whereText(px, py, best.x, best.y)
    if #markers > 1 then return tr("IGUI_OA_Status_CratesMore", text, #markers - 1) end
    return text
end

-- A number of hours as "4일 6시간" or "6시간".
function M.duration(hours)
    hours = math.max(0, math.floor(hours or 0))
    local days = math.floor(hours / 24)
    if days > 0 then return tr("IGUI_OA_Status_DaysHours", days, hours - days * 24) end
    return tr("IGUI_OA_Status_Hours", hours)
end

local function percent(x)
    return OA.round((x or 0) * 100)
end

-- The infection box (DESIGN-terminal 2.2, 17): two lines from OA.Infection.state, or nil when there is nothing to
-- show. "감염 · 장기 지연제 4일 6시간 남음" / "진행 38%에서 멈춤 · 납품 수수료 30%"; a wound not tested yet is
-- "상처 · 검사 전".
function M.infection(state)
    if not state or not (state.infected or state.untested) then return nil end
    local first, second = {}, {}
    first[1] = tr(state.infected and "IGUI_OA_Status_Inf_Infected" or "IGUI_OA_Status_Inf_Untested")
    if state.drug then
        first[#first + 1] = tr("IGUI_OA_Status_Inf_Drug_" .. (state.drug.kind == "short" and "short" or "long"),
            M.duration(state.drug.hoursLeft))
    elseif state.infected then
        first[#first + 1] = tr("IGUI_OA_Status_Inf_Going")
    end
    if state.infected and state.progress then
        second[#second + 1] = tr(state.drug and "IGUI_OA_Status_Inf_Paused" or "IGUI_OA_Status_Inf_Progress",
            percent(state.progress))
    end
    if (state.fee or 0) > 0 then second[#second + 1] = tr("IGUI_OA_Status_Inf_Fee", percent(state.fee)) end
    return { table.concat(first, Text.DOT), #second > 0 and table.concat(second, Text.DOT) or nil }
end

-- The infection state from the infection part, when it is there (nil otherwise or if it fails).
function M.infectionState(record)
    local Infection = OA.Infection
    if not (Infection and Infection.state) then return nil end
    local ok, state = pcall(Infection.state, record)
    if ok then return state end
    return nil
end

-- The status tab's dot (DESIGN-terminal 11.1): red while there is a debt, an infection or a wound not tested.
function M.statusMark(record)
    if Trade.inDebt(record) then return "bad" end
    local inf = M.infectionState(record)
    if inf and (inf.infected or inf.untested) then return "bad" end
    return nil
end

-- Whether the crude terminal's 진행 sub-tab gets its dot: the field terminal can be bought now.
function M.fieldTerminalBuyable(record)
    local entry = Shop.entry("field_terminal")
    if not entry or not M.listed(entry) then return false end
    return (Shop.available(entry, record)) > 0
end

-- The trust level whose entry the progress screen has not shown yet (DESIGN-terminal 11.1, priority 4: the road's
-- node is lit and the sub-tab has a dot until the screen is looked at), or nil. The window keeps it as seen (ui.seen.road).
function M.roadFresh(record)
    local tier = Trust.tier(record)
    if tier > 0 and tier > (Terminal.seenValue(record, "road") or 0) then return tier end
    return nil
end

-- The marks of the status tab's sub-tabs, worked out when the record changes (the sub-tab on show is `sub`):
--   progress "new" (priority 4): a new level not shown yet, or on the crude terminal the field terminal can be bought;
--   avail (priority 5): how many upgrades may be asked for now (the badge `신청 가능 N`; none on the crude terminal).
function M.subMarks(record, field, sub)
    local marks = { avail = field and M.countAvail(record, true) or 0 }
    if (not field and M.fieldTerminalBuyable(record)) or (sub ~= "progress" and M.roadFresh(record)) then
        marks.progress = "new"
    end
    return marks
end

-- The waybill's sums (the settlement's order, Trade/Settle): the gain repays a debt first, the orders are paid when
-- the balance is not a debt after it (Estimate.flight's rule), then each flight support request the balance can pay.
-- Returns { after, orders (paid), support (paid) }.
function M.receipt(balance, gain, orders, support)
    local after = balance + gain
    local paidOrders = after >= 0 and orders or 0
    after = after - paidOrders
    local paidSupport, paid = 0, {}
    for i, price in ipairs(support or {}) do
        paid[i] = after >= price
        if paid[i] then
            after = after - price
            paidSupport = paidSupport + price
        end
    end
    return { after = after, orders = paidOrders, support = paidSupport, paid = paid }
end

-- The item type an order line's icon shows: the picked choice, the first thing the entry gives, or its first choice.
function M.entryType(entry, line)
    if line and line.choice then return line.choice end
    if entry.give and entry.give[1] then return entry.give[1].type end
    local choices = type(entry.choices) == "table" and entry.choices or nil
    if choices and choices[1] then return choices[1].type end
    return nil
end

-- The request goods in the sealed boxes (the flight's `requests`, the biggest first): "양초 4개, 연필 3개" and the
-- credits they make; nil when there are none.
local function requestSummary(flight)
    local requests = flight.requests
    if not requests or (requests.units or 0) == 0 then return nil end
    local names = {}
    for _, line in ipairs(requests.lines or {}) do
        names[#names + 1] = tr("IGUI_OA_Status_Count", Text.itemName(line.fullType), line.units)
    end
    return table.concat(names, ", "), OA.round(requests.credits or 0)
end

-- 이번 편 운송장: what goes up, what comes down and the sums. `flight` is Estimate.flight(record). Returns
-- { serial, send = { { icon, name, warn, worth, sub } }, recv = { { kind = "item"|"plan", type, name, price } },
--   recvNone, calc = { { label, amount, colour } }, total = { amount, colour } }.
function M.waybill(record, flight)
    local account = Trade.account(record)
    local heli = record.heli or {}
    local w = { serial = Ledger.nextSerial(record), send = {}, recv = {}, calc = {} }
    local reissueCost = OA.reissueCost()
    -- What goes up.
    local sealed = flight.boxes or #Boxes.sealed(record)
    local fee = flight.fee or 0
    if sealed > 0 then
        local subs = {}
        local names, sum = requestSummary(flight)
        if names then
            subs[#subs + 1] = sum > 0 and tr("IGUI_OA_Status_SendRequests", credits(sum), names)
                or tr("IGUI_OA_Status_SendRequestsBare", names)
        end
        if fee > 0 then
            subs[#subs + 1] = tr("IGUI_OA_Status_SendFee", percent(flight.feeRate or 0), credits(fee))
        end
        w.send[1] = { icon = Shop.TYPES.box, name = tr("IGUI_OA_Status_SendSealed", sealed),
            worth = credits(flight.net or (flight.sealed or 0) - fee), sub = #subs > 0 and table.concat(subs, Text.DOT) or nil }
    else
        local box = Boxes.active(record)
        if box and box.state == "placed" then
            w.send[1] = { icon = Shop.TYPES.box, name = tr("IGUI_OA_Status_SendPlaced") }
        elseif box and box.state == "carried" then
            w.send[1] = { icon = Shop.TYPES.box, name = tr("IGUI_OA_Status_SendCarried") }
        else
            w.send[1] = { name = tr("IGUI_OA_Status_SendNone"), warn = true,
                sub = tr("IGUI_OA_Status_SendNoneSub", credits(reissueCost)) }
        end
    end
    -- What comes down: this flight's orders (the cart, or what the coming call carries) and the support requests.
    local lines = heli.call and heli.call.orders or (record.orders and record.orders.cart) or {}
    local svc = Orders.shopService(record)
    local orders = 0
    for _, line in ipairs(lines) do
        local entry = Orders.entry(line.id)
        if entry then
            local price = Orders.lineCost(svc, entry, line)
            orders = orders + price
            local name = Orders.nameOf(entry)
            if line.choice and entry.choices then name = Text.itemName(line.choice) end
            w.recv[#w.recv + 1] = { kind = "item", type = M.entryType(entry, line),
                name = tr("IGUI_OA_Status_ItemCount", name, line.count), price = credits(price) }
        end
    end
    local prices, plans = {}, {}
    for _, r in ipairs(M.requests(record)) do
        prices[#prices + 1] = r.price
        plans[#plans + 1] = #w.recv + 1
        w.recv[#w.recv + 1] = { kind = "plan", name = tr("IGUI_OA_Support_Change", r.name, r.from, r.to),
            price = credits(r.price), from = r.from, to = r.to, label = r.name }
    end
    if #w.recv == 0 then
        w.recvNone = tr(Trade.inDebt(record) and "IGUI_OA_Status_RecvDebt" or "IGUI_OA_Status_RecvNone")
    end
    -- The sums.
    local balance = account.credits
    -- the settlement as it will be paid: the infection handling fee taken off
    local gain = sealed > 0 and (flight.net or (flight.sealed or 0) - fee) or 0
    local bonus = flight.bonus or OA.round(account.bonus or 0)
    local r = M.receipt(balance, gain + bonus, orders, prices)
    -- A request the balance cannot pay waits for the next settlement (Support.settle): its line says so.
    for i, at in ipairs(plans) do
        if not r.paid[i] then w.recv[at].waits = true end
    end
    if balance < 0 then
        w.calc[#w.calc + 1] = { label = tr("IGUI_OA_Status_Calc_Debt"), amount = credits(balance), colour = "bad" }
    else
        w.calc[#w.calc + 1] = { label = tr("IGUI_OA_Status_Calc_Balance"), amount = credits(balance), colour = "text" }
    end
    if sealed > 0 then
        w.calc[#w.calc + 1] = { label = tr(fee > 0 and "IGUI_OA_Status_Calc_SettleFee" or "IGUI_OA_Status_Calc_Settle"),
            amount = "+" .. credits(gain), colour = "text" }
    end
    if bonus > 0 then
        w.calc[#w.calc + 1] = { label = tr("IGUI_OA_Status_Calc_Bonus"), amount = "+" .. credits(bonus), colour = "text" }
    end
    if r.orders > 0 then
        w.calc[#w.calc + 1] = { label = tr("IGUI_OA_Status_Calc_Orders"), amount = "-" .. credits(r.orders), colour = "text" }
    end
    if r.support > 0 then
        w.calc[#w.calc + 1] = { label = tr("IGUI_OA_Status_Calc_Support"), amount = "-" .. credits(r.support), colour = "text" }
    end
    w.total = { amount = credits(r.after), colour = r.after < 0 and "bad" or "value", after = r.after }
    w.orders = r.orders
    w.boxes = sealed
    w.gain = gain + bonus
    return w
end

-- The record (DESIGN-terminal 2.5) -----------------------------------------------------------------------------------

-- The codex, the sweep, the kills and the missions as texts and bars. Parts' argument 1.. are numbers.
function M.records(record)
    local s = Codex.summary(record)
    local c = Codex.section(record)
    local mult = OA.option("BonusMultiplier") or 1.0
    local function pay(n) return credits(n * mult) end
    local out = {}
    if s.nextKinds then
        out.kinds = M.parts("IGUI_OA_Status_Rec_KindsLine", credits(s.kinds), credits(s.nextKinds),
            credits(s.nextKinds - s.kinds))
        local i = c.paid.kinds + 1
        local what = tr("IGUI_OA_Status_Rec_KindPay", credits(s.nextKinds), pay(Codex.KIND_PAY[i]))
        if Codex.KIND_SERUM[s.nextKinds] then what = what .. tr("IGUI_OA_Status_Rec_PlusSerum") end
        out.kindsBonus = M.parts("IGUI_OA_Status_Rec_NextBonus", what)
    else
        out.kinds = M.parts("IGUI_OA_Status_Rec_KindsDone", credits(s.kinds))
    end
    out.cats = {}
    for _, letter in ipairs(OA.Categories.LETTERS) do
        local found, total = Codex.categoryProgress(record, letter)
        local paid = c.paid.cats[letter] or 0
        local nextText
        if paid < #Codex.CATEGORY_STEPS then
            nextText = tr("IGUI_OA_Status_Rec_CatNext", percent(Codex.CATEGORY_STEPS[paid + 1]),
                pay(Codex.CATEGORY_PAY[paid + 1]))
        else
            nextText = tr("IGUI_OA_Status_Rec_CatDone")
        end
        out.cats[#out.cats + 1] = { name = tr(OA.Categories.nameKey(letter)), frac = total > 0 and math.min(1, found / total) or 0,
            count = found .. "/" .. total, nextText = nextText }
    end
    -- The sweep: the bar from the last milestone to the next.
    local pb = c.paid.buildings
    local prevB = pb > 0 and Codex.BUILDING_STEPS[pb] or 0
    out.buildings = { big = M.parts("IGUI_OA_Status_Rec_SweepBig", credits(s.buildings)),
        lines = { M.parts("IGUI_OA_Status_Rec_SweepWhat") } }
    if s.nextBuildings then
        out.buildings.bar = (s.buildings - prevB) / math.max(1, s.nextBuildings - prevB)
        out.buildings.lines[2] = M.parts("IGUI_OA_Status_Rec_SweepNext", credits(s.nextBuildings),
            credits(s.nextBuildings - s.buildings), pay(Codex.BUILDING_PAY[pb + 1]))
    else
        out.buildings.bar = 1
        out.buildings.lines[2] = M.parts("IGUI_OA_Status_Rec_SweepDone")
    end
    local pk = c.paid.kills
    local prevK = pk > 0 and Codex.killThreshold(pk) or 0
    out.kills = { big = M.parts("IGUI_OA_Status_Rec_KillsBig", credits(s.kills)),
        bar = (s.kills - prevK) / math.max(1, s.nextKills - prevK),
        lines = { M.parts("IGUI_OA_Status_Rec_KillsWhat"),
            M.parts("IGUI_OA_Status_Rec_KillsNext", credits(s.nextKills), credits(s.nextKills - s.kills),
                pay(Codex.killPay(pk + 1))) } }
    local missions = record.missions or {}
    local results = missions.results or {}
    out.missions = { big = M.parts("IGUI_OA_Status_Rec_Done", results.done or 0),
        lines = { M.parts("IGUI_OA_Status_Rec_Late", results.expired or 0, missions.streak or 0),
            M.parts("IGUI_OA_Status_Rec_Best", missions.bestStreak or 0) } }
    return out
end

-- The field terminal's first open (DESIGN-terminal 12) -------------------------------------------------------------

-- The "새로 열린 것" board: { { head, lines = { ... } } } for the team's goods, the special requests and flight support.
-- The goods open now are named up to NEWS_NAMES (one line of the board), the rest counted (a late stage opens twenty and more at once).
M.NEWS_NAMES = 4

function M.news(record)
    local tier = Trust.tier(record)
    local open, later = {}, 0
    for _, e in ipairs(Shop.catalog()) do
        if Shop.fieldOnly(e) and M.listed(e) then
            if e.tier <= tier then open[#open + 1] = tr(Shop.nameKey(e)) else later = later + 1 end
        end
    end
    local team = {}
    if #open > 0 then
        local shown = {}
        for i = 1, math.min(#open, M.NEWS_NAMES) do shown[i] = open[i] end
        local names = table.concat(shown, ", ")
        if #open > #shown then names = tr("IGUI_OA_Status_News_TeamRest", names, #open - #shown) end
        team[1] = tr("IGUI_OA_Status_News_TeamNow", #open, names)
    else
        team[1] = tr("IGUI_OA_Status_News_TeamNone")
    end
    if later > 0 then team[#team + 1] = tr("IGUI_OA_Status_News_TeamMore", later) end
    local avail = M.countAvail(record, true)
    return {
        { head = tr("IGUI_OA_Status_News_Team"), lines = team },
        { head = tr("IGUI_OA_Status_News_Special"), lines = { tr("IGUI_OA_Status_News_SpecialWhere"),
            tr("IGUI_OA_Status_News_SpecialKinds") } },
        { head = tr("IGUI_OA_Status_News_Support"), lines = { tr("IGUI_OA_Status_News_SupportWhere"),
            avail > 0 and tr("IGUI_OA_Status_News_SupportNow", avail) or tr("IGUI_OA_Status_News_SupportLater") } },
    }
end

-- Layouts (DESIGN-terminal 1.2: the default 720x480 body is 700x408, the smallest 580x348) -------------------------

-- The status tab's sub-tab screens start under the strip and the sub-tab row.
M.BODY_Y = 96

-- The helicopter column's width: 250, 214 in a narrow window.
function M.heroWidth(w)
    return w >= 680 and 250 or 214
end

-- The new-document card at the foot of the helicopter column, over the buttons (DESIGN-terminal 11.1 priority 2): its
-- height, and the gap above it.
M.GUIDE_H, M.GUIDE_GAP = 38, 6

-- The hero's spacing: whether the last settlement and the crates take a label line and a value line each (roomy),
-- the gap between the blocks, whether the four values fit (a short window with the infection box leaves them to the
-- upgrades screen) and whether the last settlement and the crates fit at all (the infection box and the card are what
-- the player has to see, so they take the room first: the four values go, then the facts). `top` is the height the
-- state, its lines, the arrival bar and the infection box take (from 46 down), `facts` how many fact blocks there are,
-- `card` whether the new-document card stands over the buttons; the buttons keep the bottom 72.
function M.heroSpacing(h, top, facts, card)
    local reserve = 72 + (card and M.GUIDE_H + M.GUIDE_GAP or 0)
    local roomy = h >= 300
    local spec, showFacts = true, true
    local used = 46 + top + 54 + 8 + facts * 36
    if used > h - reserve then
        roomy = false
        used = used - facts * 18
    end
    if used > h - reserve then
        spec = false
        used = used - 54
    end
    if used > h - reserve then
        showFacts = false
        used = used - facts * 18
    end
    local gap = OA.clamp(math.floor((h - reserve - used) / 3), 4, 18)
    return roomy, gap, spec, showFacts
end

-- The road: { lx (lane labels' width), colw, roomy, nodeH, laneH, ya, yb, trackH }.
function M.roadLayout(w, h)
    local lx = w >= 680 and 64 or 56
    local roomy = h >= 300
    local nodeH, laneH = 32, 52
    if not roomy then nodeH, laneH = 28, 38 end
    local ya = nodeH
    local yb = nodeH + laneH + 4
    return { lx = lx, colw = math.floor((w - lx) / M.LEVELS), roomy = roomy, nodeH = nodeH, laneH = laneH, ya = ya,
        yb = yb, trackH = yb + laneH }
end

-- The upgrades screen: { formH, rw (the detail column), lw (the cards), cw, ch (a card), rows, top, areaH (the cards'
-- area), contentH, scroll } for n cards in two columns under the group buttons (26 high). Every group has the same
-- card, CARD_H high (what it does, a value under each pip); the cards that do not fit scroll, and the scroll bar takes
-- SCROLL_W off their width.
M.CARD_H, M.CARD_GAP, M.SCROLL_W = 104, 6, 10

function M.upgradesLayout(w, h, n)
    local narrow = w < 680
    local formH = narrow and 40 or 46
    local rw = narrow and 236 or 268
    local lw = w - rw - 8
    local rows = math.max(1, math.floor((n + 1) / 2))
    local top = 26
    local areaH = math.max(M.CARD_H, h - formH - 6 - top)
    local contentH = rows * (M.CARD_H + M.CARD_GAP) - M.CARD_GAP
    local scroll = contentH > areaH
    local cardsW = scroll and lw - M.SCROLL_W or lw
    return { formH = formH, rw = rw, lw = lw, cw = math.floor((cardsW - M.CARD_GAP) / 2), ch = M.CARD_H, rows = rows,
        top = top, areaH = areaH, contentH = contentH, scroll = scroll }
end

-- The record screen's category rows: 21 apart, 18 in a short window.
function M.recordRowHeight(h)
    return h >= 300 and 21 or 18
end

return M
