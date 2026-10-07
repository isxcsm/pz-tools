-- Loads the mod's changed files (BU_RELOAD, paths under media/lua) again in a running game. "[bur]" lines.
-- The files are read from the active mod's folder, or from BU_LUA_DIR when that is set.
RUN("bu_lib.lua")
local base = BUT.luaDir()
if not base then print("[bur] no folder for the mod: set BU_LUA_DIR") return end
local files = BU_RELOAD or { "shared/BuildingUtilities/Core.lua", "client/BuildingUtilities/PanelPlan.lua",
    "client/BuildingUtilities/PanelWindow.lua" }
for _, file in ipairs(files) do
    local ok, problem = pcall(reloadLuaFile, base .. file)
    print("[bur] reload", file, ok, problem)
end
