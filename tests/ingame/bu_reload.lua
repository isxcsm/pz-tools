-- Loads the mod's changed files again in a running game, then opens a box's window for a look. "[bur]" lines.
local base = "C:/Users/isxcs/Zomboid/mods/BuildingUtilities/42/media/lua/"
local files = BU_RELOAD or { "shared/BuildingUtilities/Core.lua", "client/BuildingUtilities/PanelPlan.lua",
    "client/BuildingUtilities/PanelWindow.lua" }
for _, file in ipairs(files) do
    local ok, problem = pcall(reloadLuaFile, base .. file)
    print("[bur] reload", file, ok, problem)
end
