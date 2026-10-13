-- Four tiers and the name: capacity, ranges, loss, unlocks per tier; an old save's tier 3 box becomes tier 4.
-- "[bu12]" lines. Leaves nothing behind.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local say = BUT.say("bu12")
say("tiers", BU.TIERS, "smart", BU.SMART_TIER, "timer", BU.TIMER_TIER, "link", BU.LINK_TIER)
for tier = 1, BU.TIERS do
    say("tier", tier, "capacity", BU.capacity(tier), "ranges", BU.connectRange(tier),
        "loss", string.format("%.2f", BU.lossPerPiece(tier)), "sheds", BU.overloadEnabled() and tier >= BU.SMART_TIER,
        "cost skill", BU.Costs.upgrade(tier) and BU.Costs.upgrade(tier).skill or "-")
end
say("upgrade note 3:", (BU.Panels.upgradeNote(3, true):gsub("\n", " | ")))
say("upgrade note 4:", (BU.Panels.upgradeNote(4, true):gsub("\n", " | ")))
say("names", getText("IGUI_BU_WindowTitle"), getText("IGUI_BU_PanelDefault"), getText("ContextMenu_BU_Install"),
    getItemNameFromFullType("BuildingUtilities.BreakerBox"))
-- An old save: version 2 with a tier 3 box.
local data = ModData.getOrCreate("BuildingUtilities")
local version, saved = data.version, data.panels
local old = { id = "pOld", x = 0, y = 0, z = 0, sprite = "x", tier = 3, tripped = false, log = {},
    power = { producers = {}, excluded = {}, included = {} }, water = { producers = {}, excluded = {}, included = {} } }
local two = { id = "pTwo", x = 0, y = 0, z = 0, sprite = "x", tier = 2, tripped = false, log = {},
    power = { producers = {}, excluded = {}, included = {} }, water = { producers = {}, excluded = {}, included = {} } }
data.version, data.panels = 2, { pOld = old, pTwo = two }
BU.Store.data()
say("migrated: tier 3 ->", old.tier, "tier 2 ->", two.tier, "version", data.version)
data.version, data.panels = version, saved
say("restored", data.version, #BU.Store.list())
