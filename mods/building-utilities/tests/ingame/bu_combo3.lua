-- For bu_combo: the generator started, a well put east of the pump installed by hand (the server finds it on its
-- next minute), the RiskPlumbingUnpurified option on for this session and the filter's media nearly spent (for its
-- Replace option). "[bucombo3]" lines. BUCOMBO3_CLEAN() takes the well away and the option back.
local BU = BuildingUtilities
local Store, Units = BU.Store, BU.Units
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
local cell = getCell()
local pump, filter
for _, unit in ipairs(Units.of(panel.id, "water")) do
    if unit.kind == "pump" then pump = unit elseif unit.kind == "filter" then filter = unit end
end
for _, at in ipairs(panel.power.producers) do
    local square = cell:getGridSquare(at.x, at.y, at.z)
    local generator = square and square:getGenerator()
    if generator then generator:setActivated(true) end
    print("[bucombo3] generator", at.x, at.y, generator and generator:isActivated())
end
local wellSquare = cell:getGridSquare(pump.x + 1, pump.y, pump.z)
local well = IsoObject.new(wellSquare, "camping_01_16", nil, false)
wellSquare:AddTileObject(well)
local option = SandboxVars.BuildingUtilities.RiskPlumbingUnpurified
SandboxVars.BuildingUtilities.RiskPlumbingUnpurified = true
filter.media = 5
BU.Sync.changed(panel.id)
print("[bucombo3] well east of the pump", wellSquare:getX(), wellSquare:getY(), "filter media", filter.media)
function BUCOMBO3_CLEAN()
    wellSquare:transmitRemoveItemFromSquare(well)
    SandboxVars.BuildingUtilities.RiskPlumbingUnpurified = option
    print("[bucombo3] cleaned")
end
