-- The UI of the mod's windows (the terminal and its readers, the machine window): the shared UI kit (PZUIKit: the scale,
-- the faces, drawing in a palette, the lights, its buttons, combo, confirm and rich text) with what is the mod's own on
-- top: the terminals' palettes, the unit of money and the receipt's colours. OA.Trade.UI reads through to the kit, so
-- the screens call both by one name; what is set on it stays the mod's.
require "PZUIKit/UI"
require "OperationAcorn/Core"
require "OperationAcorn/Trade/Text"
local OA = OperationAcorn
OA.Trade = OA.Trade or {}
local UI = setmetatable({}, { __index = PZUIKit.UI })
OA.Trade.UI = UI

-- The unit of money as the screens write it after a number, without a space (UI.UNIT_GAP goes before it).
function UI.creditsUnit()
    return getText("IGUI_OA_Terminal_Credits")
end

-- The two terminals' colours (DESIGN-terminal 1.3): the crude one built from the kit, phosphor green on near black
-- and nothing else (a warning, a debt, a mission's colour are the bright green: `mono`); the field terminal ordered
-- from the shop, warm white and amber on olive. Every screen draws from the palette of the terminal it is open at.
-- The machine window (Machines/Window.lua) is drawn in the field terminal's. `inset` is a well darker than the
-- background (a gauge, an icon's frame), `water` the rain storage's, `off` a light that is out.
-- Colours are { r, g, b }.
UI.PALETTES = {
    crude = {
        bg = { 0.02, 0.05, 0.03 }, bgAlpha = 1, panel = nil,
        text = { 0.45, 0.95, 0.55 }, dim = { 0.25, 0.55, 0.30 }, bright = { 0.78, 1.0, 0.82 },
        value = { 0.78, 1.0, 0.82 }, head = { 0.78, 1.0, 0.82 }, border = { 0.20, 0.50, 0.25 },
        warn = { 0.78, 1.0, 0.82 }, bad = { 0.78, 1.0, 0.82 }, good = { 0.78, 1.0, 0.82 },
        sel = { 0.45, 0.95, 0.55 }, title = { 0.04, 0.10, 0.05 }, dark = { 0.02, 0.05, 0.03 },
        inset = { 0.01, 0.025, 0.015 }, water = { 0.45, 0.95, 0.55 }, off = { 0.25, 0.55, 0.30 },
        tabStrip = nil, numberFont = UIFont.Small, iconTint = { 0.6, 1, 0.6 }, scanlines = true, mono = true,
    },
    field = {
        bg = { 0.10, 0.11, 0.08 }, bgAlpha = 1, panel = { 0.15, 0.16, 0.12 },
        text = { 0.92, 0.90, 0.82 }, dim = { 0.62, 0.60, 0.52 }, bright = { 1, 0.98, 0.92 },
        value = { 1, 0.82, 0.25 }, head = { 1, 0.82, 0.25 }, border = { 0.42, 0.45, 0.30 },
        warn = { 1, 0.82, 0.25 }, bad = { 1, 0.45, 0.35 }, good = { 0.6, 0.95, 0.6 },
        sel = { 1, 0.82, 0.25 }, title = { 0.30, 0.33, 0.20 }, dark = { 0.10, 0.11, 0.08 },
        inset = { 0.06, 0.065, 0.045 }, water = { 0.45, 0.72, 1.0 }, off = { 0.45, 0.45, 0.40 },
        tabStrip = { 0.30, 0.33, 0.20 }, numberFont = UIFont.Small, iconTint = nil, scanlines = false, mono = false,
    },
}
function UI.palette(tier)
    return UI.PALETTES[tier] or UI.PALETTES.crude
end

-- Rich text colors for the receipt kinds.
UI.KIND_TAG = {
    head = " <H2> <RGB:1,1,1> ",
    line = " <TEXT> <RGB:0.85,0.85,0.85> ",
    good = " <TEXT> <RGB:0.55,0.9,0.55> ",
    bad = " <TEXT> <RGB:0.95,0.55,0.45> ",
    note = " <TEXT> <RGB:0.8,0.75,0.55> ",
    total = " <TEXT> <RGB:1,1,1> ",
}

-- Text lines { kind, text } as rich text.
function UI.richLines(lines)
    local parts = {}
    for _, line in ipairs(lines) do
        parts[#parts + 1] = (UI.KIND_TAG[line.kind] or UI.KIND_TAG.line) .. line.text .. " <LINE> "
    end
    return table.concat(parts)
end

return UI
