-- The lines this mod adds to an item's own tooltip (the team's gear and kits, a lure's time left, a serum's text). The
-- game draws an item's tooltip from the text it holds, so the lines are put on the item while the tooltip is drawn and
-- taken off after, and nothing else sees them. One wrapper of ISToolTipInv:render does it for every part: each part adds
-- a provider (item -> its lines), the lines of all of them go after the item's own text in one string that is escaped
-- once (OA.tooltipText), and that string is kept per item for TipLines.KEEP_MS of real time, since a tooltip is drawn
-- every frame it is up and the lines change on a scale of seconds. A frame then looks one table up and swaps the text.
require "ISUI/ISToolTipInv"
require "OperationAcorn/Core"
local OA = OperationAcorn
local TipLines = {}
OA.TipLines = TipLines

-- Real milliseconds a made text is kept for an item.
TipLines.KEEP_MS = 500

local providers = {}    -- { name, fn }: fn(item) gives an array of lines (already translated) or nil
local failed = {}       -- by provider name: whether its failure was told
-- by item: { at (ms), text (a string, or false for none) }; bounded (OA.putTimed): what is past KEEP_MS goes as a new one is put
local kept = OA.bounded()
TipLines.kept = kept

-- Adds a part's lines. `fn(item)` gives an array of translated lines, or nil when the item has none of this part's.
function TipLines.add(name, fn)
    providers[#providers + 1] = { name = name, fn = fn }
end

-- The text to show for an item: its own tooltip text with every provider's lines after it, escaped once; false when no
-- provider has a line for it.
local function make(item)
    local lines
    for _, p in ipairs(providers) do
        local ok, own = pcall(p.fn, item)
        if not ok then
            if not failed[p.name] then
                failed[p.name] = true
                OA.log("tooltip lines of", p.name, "failed:", tostring(own))
            end
        elseif own and #own > 0 then
            lines = lines or {}
            for _, line in ipairs(own) do lines[#lines + 1] = line end
        end
    end
    if not lines then return false end
    local old = item:getTooltip()
    if old and old ~= "" then table.insert(lines, 1, getText(old)) end
    return OA.tooltipText(table.concat(lines, " <LINE> "))
end

-- The text for an item now (made again once KEEP_MS has passed).
function TipLines.textFor(item)
    local now = getTimestampMs()
    local hit = kept.t[item]
    if hit and now >= hit.at and now - hit.at < TipLines.KEEP_MS then return hit.text end
    local text = make(item)
    OA.putTimed(kept, item, { at = now, text = text }, now, TipLines.KEEP_MS)
    return text
end

-- The game's functions below are left as they are while the mod is off (OA.off).
if OA.off then return TipLines end

local originalRender = ISToolTipInv.render

function ISToolTipInv:render()
    local item = self.item
    local text = item and TipLines.textFor(item)
    if not text then return originalRender(self) end
    local old = item:getTooltip()
    item:setTooltip(text)
    local ok, err = pcall(originalRender, self)
    item:setTooltip(old)
    if not ok then error(err, 0) end
end

return TipLines
