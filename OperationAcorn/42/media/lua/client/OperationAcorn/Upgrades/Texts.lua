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

function Texts.note(id)
    return getText(Data.key(id, "Note"))
end

function Texts.desc(id)
    return getText(Data.key(id, "Desc"))
end

-- A reason a rank cannot be taken (Rules.blocked), in words.
function Texts.reason(why)
    return getText("IGUI_OA_Tree_Why_" .. tostring(why))
end

-- A value of a node at a rank as shown: scaled by the effect option, kept under the node's cap.
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
            args[1] = Texts.percent(amount * 100)
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
                    parts[#parts + 1] = Texts.familyName(family) .. " +" .. Texts.percent(Rules.familyAmount(u, family) * 100)
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
    elseif node.unit == "pct" then
        text = Texts.percent(shown(node, v))
    else
        text = Texts.number(shown(node, v))
    end
    args[1] = text
    if node.values2 then args[2] = Texts.number(node.values2[rank] * Rules.mult()) end
    return args
end

-- The line telling what a rank of a node gives (rank 0: nothing yet).
function Texts.rankLine(node, rank, u)
    if rank < 1 then return getText("IGUI_OA_Tree_NoEffect") end
    local key = Data.key(node.id, "Rank")
    if node.rankText then key = key .. math.min(rank, node.ranks or rank) end
    local args = Texts.args(node, rank, u)
    return getText(key, args[1], args[2], args[3])
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
        add(Rules.free(sim, node.tree) >= 1, getText("IGUI_OA_Tree_NeedPoints", 1, Rules.free(sim, node.tree)))
    end
    return list
end

return Texts
