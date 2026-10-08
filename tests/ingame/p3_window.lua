-- P3: the research plan window. Opens it, walks every tab and every node, and prints the detail text the tooltip pane
-- shows, so a missing translation key or a bad number shows as a raw key or a leftover %1.
-- Setup: a single-player world, the mod on. Some points make it more interesting (run p3_plan.lua first). Changes nothing.
-- Prints "[p3window]" lines. Look at the screen too: UI scale, the gamepad (A/X/Y/B, LB/RB), the locked tree overlay.
RUN("p3_lib.lua")
local OA = OperationAcorn
local Data = OA.Upgrades.Data
local say = P3T.say("p3window")

local window = OA.Upgrades.open(0)
P3T.check(say, "OA.Upgrades.open() opens the window", window ~= nil)
if not window then return end
say("window size", window:getWidth(), window:getHeight())
local function plain(text)
    return (string.gsub(string.gsub(text or "", "<[^>]*>", " "), "%s+", " "))
end
local bad = 0
for _, tab in ipairs({ "scout", "load", "survival", "board" }) do
    window:setTab(tab)
    for _, node in ipairs(Data.nodes) do
        if node.tree == tab then
            window.hover = node.id
            window:updateDetail()
            local text = plain(window.detail.text)
            local raw = string.find(text, "IGUI_OA_") or string.find(text, "%%%d") or string.find(text, "ContextMenu_OA")
            if raw then
                bad = bad + 1
                say("BAD text for", node.id, text)
            end
        end
    end
    say("tab", tab, "checked")
end
window.hover = "sight"
window:setTab("scout")
window:updateDetail()
say("sample detail", plain(window.detail.text))
P3T.check(say, "no node text shows a raw key or a leftover parameter", bad == 0, bad)
window.hover = nil
local second = OA.Upgrades.open(0)
P3T.check(say, "a second call closes it", second == nil)
