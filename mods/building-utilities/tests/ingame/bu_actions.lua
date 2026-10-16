-- The actions the batch checks leave out, at the test panel (bu_setup.lua): the upgrade as a player does it (the
-- window's button queues the action, which takes its cost and raises the tier: the log, the look, the window opened
-- anew with the next upgrade), and an outdoor box put down in the yard (on its pedestal, no rooms, its window filled
-- on every tab, a generator beside it wired to it and listed), and the box's design learnt at it (the recipe known,
-- forgotten first if it was). "[buact]" lines, each "ok" or "BAD"; "done" at the end,
-- some seconds later (the action runs in real time). The panel's tier is put back and what was put down taken away.
RUN("bu_lib.lua")
local BU = BuildingUtilities
local Store, Panels, Changes, Costs, Ui, PanelLook = BU.Store, BU.Panels, BU.Changes, BU.Costs, BU.PanelUi, BU.PanelLook
local PanelWindow = BU.PanelWindow
local player = getPlayer()
local bad = 0
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[buact] " .. table.concat(parts, " "))
end
local function check(label, got, want)
    local ok = got == want
    if not ok then bad = bad + 1 end
    say(ok and "ok" or "BAD", label, got, "want", want)
end
local panel = Store.get(ModData.getOrCreate("BUTEST").panel)
if not panel then say("no panel"); return end
local tierWas = panel.tier or 1

-- The outdoor box: put down on a free square of the yard, a generator beside it wired to it.
local function outdoorChecks()
    local yard = BUT.square(panel.x, panel.y, 0, 4, 14, function(s)
        return s:isOutside() and s:isFree(false) and not Panels.buildingAt(s:getX(), s:getY(), 0)
            and Panels.canInstall(s) == true
    end)
    if not yard then say("BAD no square in the yard"); bad = bad + 1; return end
    local box = Changes.install(yard, "S")
    check("outdoor: an outdoor box", box.outdoor, true)
    check("outdoor: no rooms", box.zone, nil)
    check("outdoor: on its pedestal", Panels.object(box) and Panels.object(box):getSprite():getName(), BU.panelSprite("S", nil, true))
    local okOpen, window = pcall(PanelWindow.open, player, box)
    check("outdoor: window opens", okOpen and window ~= nil, true)
    if okOpen and window then
        for _, entry in ipairs(window.tabs.viewList) do
            window.tabs:activateView(entry.name)
            local ok, err = pcall(function() window:refresh(); window:prerender() end)
            check("outdoor: tab " .. entry.name, ok and "fine" or tostring(err), "fine")
        end
    end
    local beside = BUT.square(yard:getX(), yard:getY(), 0, 1, 3, function(s)
        return s:isOutside() and s:isFree(false) and not s:getGenerator() and BuildingUtilities.Links.get(BuildingUtilities.Links.producerRef(s:getX(), s:getY(), 0)) == nil
    end)
    local generator
    if beside then
        generator = IsoGenerator.new(instanceItem("Base.Generator"), getCell(), beside)
        Changes.connectProducer(box, "power", beside:getX(), beside:getY(), 0, {})
        check("outdoor: the generator is its producer", #box.power.producers, 1)
        check("outdoor: where it is", Panels.where(box, beside:getX(), beside:getY(), 0) ~= nil, true)
        if window then
            window.tabs:activateView(window.tabs.viewList[1].name)
            window:refresh()
            local listed = false
            for _, item in ipairs(window.lists.power.items) do
                if item.item.kind == "producer" and item.item.index == 1 then listed = item.item.text end
            end
            say("outdoor: generator row", listed)
            check("outdoor: the generator listed", listed ~= false, true)
        end
        Changes.unlay(BU.Links.producerRef(beside:getX(), beside:getY(), 0))
        generator:remove()
    else
        say("no square beside the outdoor box for a generator")
    end
    if window then window:close() end
    Changes.remove(box)
    check("outdoor: taken away", Store.get(box.id), nil)
end

-- The upgrade as a player does it: at tier 1 with the cost in the inventory, the window's button.
BU.Dev.setTier(panel, 1)
local cost = Costs.upgrade(2)
for _, item in ipairs(cost.items or {}) do
    for _ = 1, item[2] do player:getInventory():AddItem(item[1]) end
end
check("upgrade: affords it", Costs.affords(player, cost), true)
if PanelWindow.isOpen(panel.id) then PanelWindow.get(panel.id):close() end
local window = PanelWindow.open(player, panel)
local counts = {}
for _, item in ipairs(cost.items or {}) do counts[item[1]] = player:getInventory():getCountTypeRecurse(item[1]) end
window:onUpgrade()
say("upgrade queued, waiting for the action")

local ticks = 0
local function onTick()
    ticks = ticks + 1
    if (panel.tier or 1) < 2 and ticks < 60 * 30 then return end
    Events.OnTick.Remove(onTick)
    check("upgrade: tier", panel.tier, 2)
    for _, item in ipairs(cost.items or {}) do
        check("upgrade: took " .. item[1], counts[item[1]] - player:getInventory():getCountTypeRecurse(item[1]), item[2])
    end
    local log = panel.log or {}
    check("upgrade: logged", log[#log] and log[#log].key, "IGUI_BU_Log_Upgraded")
    local box = Panels.object(panel)
    local facing = PanelLook.of(box) and PanelLook.of(box).facing or 1
    check("upgrade: the look", box:getSprite():getName(),
        PanelLook.SPRITES[PanelLook.variant(2, panel.outdoor)][PanelLook.wanted(panel)][facing])
    local opened = PanelWindow.get(panel.id)
    check("upgrade: the window open again", opened ~= nil, true)
    if opened then
        opened:refresh()
        check("upgrade: the button offers tier 3", opened.upgradeButton.title, getText("ContextMenu_BU_Upgrade", 3))
        opened:close()
    end
    say("upgrade took", ticks, "ticks")
    outdoorChecks()
    BU.Dev.setTier(panel, tierWas)
    -- Learning the design at the box, with a screwdriver.
    local known = player:getKnownRecipes()
    known:remove(Panels.RECIPE)
    if not player:getInventory():containsTypeRecurse("Screwdriver") then player:getInventory():AddItem("Base.Screwdriver") end
    check("learn: not known before", player:isRecipeActuallyKnown(Panels.RECIPE), false)
    check("learn: nothing in the way", Panels.reverseEngineerProblem(player), nil)
    BU.ContextMenu.queueAt(player, panel.x, panel.y, panel.z, ISBUReverseEngineer:new(player, panel))
    local waited = 0
    local function onLearnTick()
        waited = waited + 1
        if not player:isRecipeActuallyKnown(Panels.RECIPE) and waited < 60 * 30 then return end
        Events.OnTick.Remove(onLearnTick)
        check("learn: the recipe known", player:isRecipeActuallyKnown(Panels.RECIPE), true)
        check("learn: the box still there", Panels.object(panel) ~= nil, true)
        say("done:", bad, "BAD")
    end
    Events.OnTick.Add(onLearnTick)
end
Events.OnTick.Add(onTick)
