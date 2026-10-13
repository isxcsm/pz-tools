-- Where a mod's options stand in the game's world menu, by what they do: what is done with the thing itself on top
-- (the game's addOptionOnTop); what ties it to something else or takes it apart or away at the menu's end, just over
-- the game's own lines there (disassemble, destroy, sit on the ground, walk here), ties first. The game adds those
-- before the mods fill the menu (OnFillWorldObjectContextMenu), so a mod's addOption would land under them.
require "ISUI/ISContextMenu"
PZUIKit = PZUIKit or {}
local Menu = {}
PZUIKit.Menu = Menu

-- The game's lines at the menu's end, by their text keys.
Menu.TAIL_KEYS = { "ContextMenu_Disassemble", "ContextMenu_Destroy", "ContextMenu_SitGround", "ContextMenu_Walk_to" }

local tailNames
local function isTail(name)
    if not tailNames then
        tailNames = {}
        for _, key in ipairs(Menu.TAIL_KEYS) do tailNames[getText(key)] = true end
    end
    return tailNames[name] == true
end

-- Moves options already in the menu to just over its end, in the order given (at the bottom when it has no such end).
function Menu.beforeTail(context, moved)
    if #moved == 0 then return end
    local going = {}
    for _, option in ipairs(moved) do going[option] = true end
    local kept = {}
    for _, option in ipairs(context.options) do
        if not going[option] then kept[#kept + 1] = option end
    end
    local at = #kept + 1
    for index, option in ipairs(kept) do
        if isTail(option.name) then
            at = index
            break
        end
    end
    local options = {}
    for index = 1, at - 1 do options[#options + 1] = kept[index] end
    for _, option in ipairs(moved) do options[#options + 1] = option end
    for index = at, #kept do options[#options + 1] = kept[index] end
    for index = #context.options, 1, -1 do context.options[index] = nil end
    for index, option in ipairs(options) do
        option.id = index
        context.options[index] = option
    end
end

return Menu
