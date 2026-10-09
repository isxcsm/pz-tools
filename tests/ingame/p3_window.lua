-- P3: the research tab of the character info window. Opens it, walks both modes (the three trees, the 2nd board) and
-- every node, and prints the tooltip text each would show, so a missing translation key or a bad number shows as a
-- raw key or a leftover %1; checks the nodes sit inside their panels without overlapping, the tooltip shows beside
-- the hovered node, and a second call hides the tab.
-- Setup: a single-player world, the mod on. Some points make it more interesting (run p3_plan.lua first). Changes nothing.
-- Prints "[p3window]" lines. Look at the screen too: UI scale, the gamepad (A/X/Y/B, LB/RB), the locked tree overlay.
RUN("p3_lib.lua")
local OA = OperationAcorn
local say = P3T.say("p3window")

-- from the tab hidden (open() shows it or hides it)
local info = getPlayerInfoPanel(0)
if info:getIsVisible() and info.panel:getActiveView() == OA.Upgrades.Window.view(0) then OA.Upgrades.open(0) end
local view = OA.Upgrades.open(0)
P3T.check(say, "OA.Upgrades.open() shows the research tab", view ~= nil and info:getIsVisible()
    and info.panel:getActiveView() == view)
if not view then return end
local info = getPlayerInfoPanel(0)
say("tab size", view:getWidth(), view:getHeight(), "window", info:getWidth(), info:getHeight())
local function plain(text)
    return (string.gsub(string.gsub(text or "", "<[^>]*>", " "), "%s+", " "))
end
local bad = 0
for _, mode in ipairs({ "trees", "board" }) do
    view:onMode({ internal = mode })
    local nodes = 0
    for _, item in ipairs(view.items) do
        if item.id then
            nodes = nodes + 1
            local name, text = view:tipFor(item.id)
            local all = plain(name .. " " .. text)
            if string.find(all, "IGUI_OA_") or string.find(all, "%%%d") or string.find(all, "ContextMenu_OA") then
                bad = bad + 1
                say("BAD text for", item.id, all)
            end
            -- inside its panel, and on no other node
            local inside = false
            for _, panel in ipairs(view.panels) do
                if item.x >= panel.x and item.x + item.w <= panel.x + view.gridW and item.y >= panel.y then inside = true end
            end
            if not inside then
                bad = bad + 1
                say("BAD node outside its panel", item.id)
            end
            for _, other in ipairs(view.items) do
                if other ~= item and other.id and other.x < item.x + item.w and item.x < other.x + other.w
                    and other.y < item.y + item.h and item.y < other.y + other.h then
                    bad = bad + 1
                    say("BAD nodes overlap", item.id, other.id)
                end
            end
        end
    end
    say("mode", mode, "nodes", nodes, "lines", #view.lines)
end
view:onMode({ internal = "trees" })
P3T.check(say, "no node text shows a raw key or a leftover parameter, no node misplaced", bad == 0, bad)

-- The tooltip: the UI manager takes in what is added while it updates on its next frame, so each look waits a few
-- ticks (the console line runs inside that update).
local function later(ticks, fn)
    local n = 0
    local function step()
        n = n + 1
        if n < ticks then return end
        Events.OnTick.Remove(step)
        fn()
    end
    Events.OnTick.Add(step)
end

view.hover = "sight"
view:updateTip()
local tip = view.tip
later(3, function()
    -- in the UI manager, not only visible: a new ISToolTip reads visible before it is added (it never drew, 2026-10-09)
    P3T.check(say, "the tooltip shows for the hovered node", tip ~= nil and tip:getIsVisible()
        and UIManager.getUI():contains(tip.javaObject) and tip.description ~= "")
    if tip then
        local item = view:itemOf("sight")
        say("tooltip at", tip.desiredX, tip.desiredY, "node at", view:getAbsoluteX() + item.x, view:getAbsoluteY() + item.y)
        say("sample tooltip", plain(tip.name .. " " .. tip.description))
    end
    view.hover = nil
    view:updateTip()
    later(3, function()
        P3T.check(say, "it hides when nothing is hovered",
            not (tip and (tip:getIsVisible() or UIManager.getUI():contains(tip.javaObject))))
        local second = OA.Upgrades.open(0)
        P3T.check(say, "a second call hides the tab", second == nil and not info:getIsVisible())
    end)
end)
