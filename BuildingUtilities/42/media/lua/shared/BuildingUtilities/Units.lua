-- Units: objects this mod puts down and wires to a main panel like a generator (solar panels and battery racks for its
-- power; pumps, sprinklers and filters for its water). They are kept in the save (Store.units), not only on their squares, because they count while those
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
--   sprite(square, side): the sprite it stands as when put down there, facing a side (BU.SIDES), a kind with fewer
--     looks giving one for several; square is nil for the faces the furniture tool turns through (Moveables.lua).
--   sprites: each sprite it can stand as, in each of its looks (the server learns of them as their squares load:
--     onLoad).
--   utility: what it is wired for: "power" (a source of the panel's power) or "water" (it works for one of the
--     panel's water groups); minTier and tierReason: the lowest tier of a panel it is wired to.
--   colour: { r, g, b } on the plan.
-- And, each optional:
--   create(unit, object): as it is put down (the server).
--   isEmpty(unit): whether it holds nothing, so that it can be taken down; notEmptyReason the text key when not.
--   onLoad(unit, object): as its square loads (the server).
--   sync(unit, object): each minute while its square is loaded (the server): what keeps its object in step, as its
--     look (Units.setSprite, Units.setOverlay).
--   title(unit, text): its line on the world menu, from its name.
--   options(unit, character): world menu options, each { text, action = function(character, unit) a timed action,
--     reason (why it cannot now, or nil) }.
-- Its texts: IGUI_BU_Unit_<kind> (its name) and ContextMenu_BU_Install_<kind>.
function Units.define(kind, definition)
    if not definitions[kind] then Units.KINDS[#Units.KINDS + 1] = kind end
    definition.kind = kind
    definitions[kind] = definition
    return definition
end

function Units.definition(kind) return definitions[kind] end

function Units.name(unit) return getText("IGUI_BU_Unit_" .. unit.kind) end

function Units.utility(unit) return definitions[unit.kind].utility end

-- The units wired to a panel that are of a utility, of the kinds that are on (BU.enabled): one of a kind that is off
-- does nothing.
function Units.of(panelId, utility)
    local result = {}
    for _, unit in ipairs(Store.unitList(nil, panelId)) do
        if definitions[unit.kind].utility == utility and BU.enabled(unit.kind) then result[#result + 1] = unit end
    end
    return result
end

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

-- An object of this mod shows another sprite, or another overlay over it (nil for none), when it does not already;
-- on a server its players see it too.
function Units.setSprite(object, name)
    local sprite = object:getSprite()
    if sprite and sprite:getName() == name then return end
    object:setSprite(getSprite(name))
    if isServer() then object:transmitUpdatedSpriteToClients() end
end

function Units.setOverlay(object, name)
    local current = object:getOverlaySprite() and object:getOverlaySprite():getName() or nil
    if current ~= name then object:setOverlaySprite(name or "", isServer()) end
end

-- Looks: what a thing shows of its state, a sprite for each way it faces ({ [look] = { [facing] = sprite } }), drawn in
-- this mod's sheet (bu_water_01, tools/tile_art.py). A look's sprites follow each other in the sheet, from first, in
-- the order of facings.
function Units.sheetSprites(first, facings)
    local result = {}
    for index, facing in ipairs(facings) do result[facing] = "bu_water_01_" .. (first + index - 1) end
    return result
end

-- What each sprite of a set of looks shows: { look, facing } by its name.
function Units.lookOf(looks)
    local result = {}
    for look, sprites in pairs(looks) do
        for facing, name in pairs(sprites) do result[name] = { look = look, facing = facing } end
    end
    return result
end

-- Every sprite of a set of looks, in the order of the looks and the facings given.
function Units.lookSprites(looks, order, facings)
    local result = {}
    for _, look in ipairs(order) do
        for _, facing in ipairs(facings) do result[#result + 1] = looks[look][facing] end
    end
    return result
end

-- A unit's object, when loaded, in step with it now (its kind's sync): after a player changed it, without waiting for
-- the next minute.
function Units.show(unit)
    local sync = definitions[unit.kind].sync
    local object = sync and Units.object(unit)
    if object then sync(unit, object) end
end

-- An object takes the sprite of a look, facing as it does (lookOf: what its sprites show); one that shows another
-- sprite is left as it is.
function Units.showLook(object, looks, look, lookOf)
    local current = object:getSprite() and object:getSprite():getName()
    local shown = current and lookOf[current]
    if shown then Units.setSprite(object, looks[look][shown.facing]) end
end

local function blocked(square)
    if Store.unitAt(square:getX(), square:getY(), square:getZ()) then return true end
    if Store.panelAt(square:getX(), square:getY(), square:getZ()) then return true end
    local properties = square:getProperties()
    if properties and properties:has(IsoFlagType.water) then return true end
    return not square:getFloor() or not square:isFree(false)
end

-- Whether a unit of a kind can go on a square: of a kind that is on, where its kind may stand, on a free floor. True,
-- or nil and a reason.
function Units.canInstall(kind, square)
    if not BU.enabled(kind) then return nil, "disabled" end
    if not square then return nil, "noSquare" end
    if not BU.api() then return nil, "noApi" end
    local ok, reason = definitions[kind].canPlace(square)
    if not ok then return nil, reason end
    if blocked(square) then return nil, "blocked" end
    return true
end

-- The sprite for a unit put on a square by a character (facing them), or facing a side.
function Units.spriteFor(kind, square, character) return definitions[kind].sprite(square, BU.sideOf(square, character)) end
function Units.spriteFacing(kind, square, side) return definitions[kind].sprite(square, side) end

-- The panels a unit could be wired to, as for a generator (Panels.producerCandidates).
function Units.candidates(unit) return Panels.producerCandidates(unit.x, unit.y, unit.z) end

-- Whether a unit can be wired to a panel (a sub-panel takes it on to its main panel, whose tier counts). True, or
-- false and a reason.
function Units.canConnect(unit, panel)
    if not BU.enabled(unit.kind) then return false, "disabled" end
    if unit.panel then return false, "connectedElsewhere" end
    local definition = definitions[unit.kind]
    if (Panels.root(panel).tier or 1) < (definition.minTier or 1) then return false, definition.tierReason end
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
