-- The words of the research screen: a node's name, note and description, the line that tells what a rank gives (with
-- the numbers the effect option scales), the conditions to take it, why something is refused. Only text; no drawing.
require "OperationAcorn/Upgrades/Data"
require "OperationAcorn/Upgrades/Rules"
require "OperationAcorn/Upgrades/Effects"
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Effects = OA.Upgrades.Effects
local Texts = {}
OA.Upgrades.Texts = Texts

-- A number as the screen shows it: whole when whole, else one decimal.
function Texts.number(x)
    local rounded = math.floor(x * 10 + 0.5) / 10
    if rounded == math.floor(rounded) then return tostring(math.floor(rounded)) end
    return tostring(rounded)
end

-- A percentage as shown. The sign goes in with the number, not in the translated sentence (a bare percent sign in a
-- translation breaks the game's text formatting).
function Texts.percent(x)
    return Texts.number(x) .. "%"
end

function Texts.treeName(tree)
    return getText("IGUI_OA_Tree_Name_" .. tree)
end

function Texts.familyName(family)
    return getText("IGUI_OA_Tree_Family_" .. family)
end

function Texts.nodeName(id)
    return getText(Data.key(id, "Name"))
end

-- A translation that may be left out, or nil.
local function optional(key)
    if getTextOrNull then return getTextOrNull(key) end
    local text = getText(key)
    if text ~= key then return text end
    return nil
end

-- The research team's line under a capstone (only capstones have one), or nil.
function Texts.note(id)
    return optional(Data.key(id, "Note"))
end

-- What a node's rank text leaves out that a player would not expect (where it does not apply), or nil.
function Texts.desc(id)
    return optional(Data.key(id, "Desc"))
end

-- A reason a rank cannot be taken (Rules.blocked), in words.
function Texts.reason(why)
    return getText("IGUI_OA_Tree_Why_" .. tostring(why))
end

-- A value of a node at a rank as shown: scaled by the effect option, kept under the node's cap.
-- A sum of efficiencies or reductions (a value is divided by 1 + sum) as the whole percentage it takes off.
local function lighter(sum)
    return math.floor((1 - 1 / (1 + sum)) * 100 + 0.5)
end

local function shown(node, value)
    local v = value * Rules.mult()
    if node.cap and v > node.cap then v = node.cap end
    return v
end

-- The numbers a rank line is built from, as strings: %1, %2 ... of the node's rank text. u is the section (for the
-- board nodes, whose numbers follow what is bought).
function Texts.args(node, rank, u)
    local args = {}
    if node.board then
        local amount = Rules.boardAmount(u, node.id)
        if node.form == "divide" then
            -- what the reduction takes off, as the player meets it (a value divided by 1 + sum)
            args[1] = Texts.percent(lighter(amount))
            if node.id == "bBite" then args[2] = Texts.number(Rules.biteHours(u) / 24) end
        elseif node.form == "add" then
            if node.unit == "pct100" then
                args[1] = Texts.percent(amount * 100)
            else
                args[1] = Texts.number(amount)
            end
        else
            args[1] = Texts.percent(amount * 100)
            args[2] = Texts.percent(node.limit * Rules.mult() * 100)
        end
        if node.id == "bFamily" then
            local parts = {}
            for _, family in ipairs(Data.FAMILY_ORDER) do
                local n = u.board.family[family]
                if n and n > 0 then
                    parts[#parts + 1] = Texts.familyName(family) .. " " .. Texts.percent(lighter(Rules.familyAmount(u, family)))
                end
            end
            args[1] = #parts > 0 and table.concat(parts, ", ") or "-"
        end
        return args
    end
    if rank < 1 or not node.values then return args end
    local v = node.values[rank]
    local text
    if node.id == "overload" then
        -- the values are the share of the excess still counted
        text = Texts.percent(100 - shown({ cap = 95 }, 100 - v))
    elseif node.lighter then
        text = Texts.percent(lighter(shown(node, v) / 100))
    elseif node.unit == "pct" then
        text = Texts.percent(shown(node, v))
    else
        text = Texts.number(shown(node, v))
    end
    args[1] = text
    if node.values2 then args[2] = Texts.number(node.values2[rank] * Rules.mult()) end
    if node.id == "resistPlus" then args[2] = Texts.number(Rules.biteHours(u) / 24) end
    return args
end

-- The sentence telling what a rank of a node gives, or nil for rank 0.
function Texts.rankLine(node, rank, u)
    if rank < 1 then return nil end
    local key = Data.key(node.id, "Rank")
    if node.rankText then key = key .. math.min(rank, node.ranks or rank) end
    local args = Texts.args(node, rank, u)
    return getText(key, args[1], args[2], args[3])
end

-- Whether a rank's text adds to the lines of the ranks before it (Data: adds).
local function adds(node, k)
    if k < 2 or not node.rankText or not node.adds then return false end
    return node.adds == true or node.adds[k] == true
end

-- What a node gives at a rank, a line each: the text of every rank taken that a later one does not replace, with the
-- numbers of this rank (so a number reads once, as it is now). Empty for rank 0.
function Texts.lines(node, rank, u)
    local list = {}
    if rank < 1 then return list end
    if not node.rankText then
        list[1] = Texts.rankLine(node, rank, u)
        return list
    end
    local args = Texts.args(node, rank, u)
    local base = Data.key(node.id, "Rank")
    for k = 1, math.min(rank, node.ranks or rank) do
        if not adds(node, k) then list = {} end
        list[#list + 1] = getText(base .. k, args[1], args[2], args[3])
    end
    return list
end

-- The lines of after that are not in before: what a rank taken next gives or changes.
function Texts.newLines(before, after)
    local had = {}
    for _, text in ipairs(before) do had[text] = true end
    local list = {}
    for _, text in ipairs(after) do
        if not had[text] then list[#list + 1] = text end
    end
    return list
end

-- The bite shield's state for the tooltip of the nodes that make it (상처 감염 저항 rank 2, the board's 물림 회복), or
-- nil: armed, or how long it still rests (days and hours). `u` is the record's section, `now` the world age hours.
function Texts.biteStatus(node, u, now)
    if node.id ~= "resistPlus" and node.id ~= "bBite" then return nil end
    if Rules.rank(u, "resistPlus") < 2 then return nil end
    local wait = Rules.biteWait(u, now)
    if wait <= 0 then return getText("IGUI_OA_Tree_BiteArmed"), true end
    local days = math.floor(wait / 24)
    local hours = math.floor(wait - days * 24)
    if days > 0 then return getText("IGUI_OA_Tree_BiteRestDays", days, hours), false end
    return getText("IGUI_OA_Tree_BiteRestHours", math.max(1, hours)), false
end

-- Why the API side of a node does nothing, or nil when it works.
function Texts.apiNote(id)
    local status, detail = Effects.status(id)
    if status == "noApi" then return getText("IGUI_OA_Tree_NeedsApi") end
    if status == "noPoint" then return getText("IGUI_OA_Tree_NeedsPoint", tostring(detail)) end
    return nil
end

-- The conditions to take the next rank of a node, each { ok, text }, with the state the plan would make (sim).
-- ctx.fragments is the fragments the plan leaves in the bag.
function Texts.conditions(sim, node, ctx)
    local list = {}
    local function add(ok, text) list[#list + 1] = { ok = ok, text = text } end
    if node.board then
        add(Rules.boardOpen(sim), getText("IGUI_OA_Tree_NeedBoard", Rules.capstones(sim), #Data.TREES))
        add(Rules.boardFree(sim) >= Rules.cost(sim, node.id),
            getText("IGUI_OA_Tree_NeedPoints", Rules.cost(sim, node.id), Rules.boardFree(sim)))
        return list
    end
    add(Rules.treeOpen(sim, node.tree), getText("IGUI_OA_Tree_NeedOpen", Texts.treeName(node.tree)))
    local need = Rules.rowNeed(node.row)
    if need > 0 then
        local spent = Rules.treeSpent(sim, node.tree)
        add(spent >= need, getText("IGUI_OA_Tree_NeedRow", Texts.treeName(node.tree), need, spent))
    end
    for _, req in ipairs(node.req) do
        local have = Rules.rank(sim, req[1])
        add(have >= req[2], getText("IGUI_OA_Tree_NeedNode", Texts.nodeName(req[1]), req[2], have))
    end
    if node.capstone then
        local have = (ctx and ctx.fragments) or 0
        add(have >= 1, getText("IGUI_OA_Tree_NeedFragment", have))
    end
    if not Rules.maxed(sim, node.id) then
        local free = Rules.free(sim, node.tree)
        add(free >= 1, getText("IGUI_OA_Tree_NeedPoints", 1, math.min(free, Rules.treeRoom(sim, node.tree))))
    end
    return list
end

return Texts
