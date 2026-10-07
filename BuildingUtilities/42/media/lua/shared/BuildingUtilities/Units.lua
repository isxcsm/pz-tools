-- Units: objects this mod puts down and wires to a main panel like a generator (solar panels, battery racks, and the
-- kinds to come). They are kept in the save (Store.units), not only on their squares, because they count while those
-- are not loaded. Each kind is defined once (Units.define) with what sets it apart; the rest of the mod asks the
-- definition rather than the kind's name.
require "BuildingUtilities/Panels"
local BU = BuildingUtilities
local Store, Panels = BU.Store, BU.Panels
local Units = {}
BU.Units = Units

Units.MODDATA = "BuildingUtilitiesUnit"
-- The kinds in the order they were defined: menus list them so.
Units.KINDS = {}
local definitions = {}

-- A kind of unit. Its definition:
--   item: the item the player puts down and gets back.
--   canPlace(square): whether it may stand there besides a free floor: true, or nil and a reason.
--   sprite(square, character): the sprite it stands as when put down there.
--   sprites: each sprite it can stand as (the server learns of them as their squares load: onLoad).
--   utility: what it is wired for ("power"); minTier and tierReason: the lowest tier of a panel it is wired to.
--   colour: { r, g, b } on the plan.
-- And, each optional:
--   create(unit, object): as it is put down (the server).
--   isEmpty(unit): whether it holds nothing, so that it can be taken down; notEmptyReason the text key when not.
--   onLoad(unit, object): as its square loads (the server).
--   sync(unit, object): each minute while its square is loaded (the server).
--   title(unit, text): its line on the world menu, from its name.
--   options(unit): world menu options, each { text, action = function(character, unit) a timed action }.
-- Its texts: IGUI_BU_Unit_<kind> (its name) and ContextMenu_BU_Install_<kind>.
function Units.define(kind, definition)
    if not definitions[kind] then Units.KINDS[#Units.KINDS + 1] = kind end
    definition.kind = kind
    definitions[kind] = definition
    return definition
end

function Units.definition(kind) return definitions[kind] end

function Units.name(unit) return getText("IGUI_BU_Unit_" .. unit.kind) end

-- The unit's object on its loaded square, or nil.
function Units.object(unit)
    local square = getCell():getGridSquare(unit.x, unit.y, unit.z)
    if not square then return nil end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:getModData()[Units.MODDATA] == unit.id then return object end
    end
    return nil
end

function Units.ofObject(object)
    local id = object and object:getModData()[Units.MODDATA]
    return id and Store.unit(id) or nil
end

local function blocked(square)
    if Store.unitAt(square:getX(), square:getY(), square:getZ()) then return true end
    if Store.panelAt(square:getX(), square:getY(), square:getZ()) then return true end
    local properties = square:getProperties()
    if properties and properties:has(IsoFlagType.water) then return true end
    return not square:getFloor() or not square:isFree(false)
end

-- Whether a unit of a kind can go on a square: where its kind may stand, on a free floor. True, or nil and a reason.
function Units.canInstall(kind, square)
    if not square then return nil, "noSquare" end
    if not BU.api() then return nil, "noApi" end
    local ok, reason = definitions[kind].canPlace(square)
    if not ok then return nil, reason end
    if blocked(square) then return nil, "blocked" end
    return true
end

-- The sprite for a unit put on a square by a character.
function Units.spriteFor(kind, square, character) return definitions[kind].sprite(square, character) end

-- The main panels a unit could be wired to, as for a generator (Panels.producerCandidates).
function Units.candidates(unit) return Panels.producerCandidates(unit.x, unit.y, unit.z) end

-- Whether a unit can be wired to a panel. True, or false and a reason.
function Units.canConnect(unit, panel)
    if panel.parent then return false, "isSubPanel" end
    if unit.panel then return false, "connectedElsewhere" end
    local definition = definitions[unit.kind]
    if (panel.tier or 1) < (definition.minTier or 1) then return false, definition.tierReason end
    for _, candidate in ipairs(Panels.inProducerRange(unit.x, unit.y, unit.z)) do
        if candidate.panel == panel then return true end
    end
    return false, "tooFar"
end

-- Whether a unit holds nothing, so that it can be taken down.
function Units.isEmpty(unit)
    local definition = definitions[unit.kind]
    return not definition.isEmpty or definition.isEmpty(unit)
end

return Units
