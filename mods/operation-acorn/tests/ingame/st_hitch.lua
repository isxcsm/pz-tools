-- A frame that took long (ST_HITCH ms, 400 by default) printed as it ends: [hitch] ms, the game hour, where the
-- character stands, and the last [st] line before it. Added once.
ST_HITCH = ST_HITCH or 400
if ST_HITCHED then return end
ST_HITCHED = true
local last = getTimestampMs()
Events.OnTick.Add(function()
    local now = getTimestampMs()
    local d = now - last
    last = now
    if d >= ST_HITCH then
        local p = getPlayer()
        print("[hitch]", d .. " ms", getGameTime():getHour() .. ":" .. getGameTime():getMinutes(),
            p and math.floor(p:getX()) or "", p and math.floor(p:getY()) or "")
    end
end)
print("[hitch] watching")
