-- Where world squares are on the game's screen, for clicking them.
local zoom = getCore():getZoom(0)
for _, at in ipairs({ { "generator", 3573, 10908, 0 }, { "box", 3571, 10892, 0 }, { "barrel", 3571, 10907, 0 },
                       { "player", getPlayer():getX(), getPlayer():getY(), 0 } }) do
    local x = (IsoUtils.XToScreen(at[2] + 0.5, at[3] + 0.5, at[4], 0) - IsoCamera.getOffX()) / zoom
    local y = (IsoUtils.YToScreen(at[2] + 0.5, at[3] + 0.5, at[4], 0) - IsoCamera.getOffY()) / zoom
    print("[buscreen]", at[1], math.floor(x), math.floor(y), "zoom", zoom, "screen", getCore():getScreenWidth(), getCore():getScreenHeight())
end
