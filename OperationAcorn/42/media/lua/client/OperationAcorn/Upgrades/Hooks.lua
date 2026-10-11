-- Where the upgrades meet the game's screens and clocks: the right-click entries (serums and infection medicines in the
-- bag, the research plan, locked doors, windows and cars), the item tooltips of the serums, the notices and the title
-- (or banner) of a tree's opening, declaring the effects to the API, the once-a-minute infection work (the delay drug's
-- hold in Watch.lua, the stand-in bite shield). Other mods' menus and tooltips are wrapped, never replaced.
require "ISUI/ISToolTip"
require "ISUI/ISToolTipInv"
require "ISUI/ISPanel"
require "ISUI/ISInventoryPaneContextMenu"
require "ISUI/ISWorldObjectContextMenu"
require "OperationAcorn/Client"
require "OperationAcorn/Titles"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Moodles"
require "OperationAcorn/Upgrades/Watch"
require "OperationAcorn/Upgrades/Adapting"
require "OperationAcorn/Upgrades/Actions"
require "OperationAcorn/Upgrades/Texts"
require "OperationAcorn/Upgrades/Window"
require "OperationAcorn/Upgrades/Pulse"
require "OperationAcorn/Upgrades/Senses"
require "OperationAcorn/Upgrades/Dash"
require "OperationAcorn/Upgrades/Carry"
require "OperationAcorn/Trade/UI"
local OA = OperationAcorn
local UI = OA.Trade.UI
local Data = OA.Upgrades.Data
local Rules = OA.Upgrades.Rules
local Effects = OA.Upgrades.Effects
local Serums = OA.Upgrades.Serums
local Infection = OA.Infection
local Actions = OA.Upgrades.Actions
local Texts = OA.Upgrades.Texts
local Pulse = OA.Upgrades.Pulse
local Senses = OA.Upgrades.Senses
local Dash = OA.Upgrades.Dash
local Watch = OA.Upgrades.Watch
local Adapting = OA.Upgrades.Adapting
local Hooks = {}
OA.Upgrades.Hooks = Hooks

local function localSection()
    local player = getPlayer()
    local record = player and OA.Client.record(player)
    if not record then return nil, player end
    return Rules.section(record), player
end

-- ---- the effects ----------------------------------------------------------------------------------------------

-- Declares the character's values to the API, and sets the timers and hooks the Lua effects need.
function Hooks.refresh()
    local u, player = localSection()
    if not player then return end
    local record = OA.Client.record(player)
    Effects.apply(record)
    local land = u and Effects.landRank(u)
    if player:getVariableString(Effects.LAND_VARIABLE) ~= (land or "") then
        if land then player:setVariable(Effects.LAND_VARIABLE, land) else player:clearVariable(Effects.LAND_VARIABLE) end
    end
    if not u then return end
    local need = Senses.refresh() or Dash.needs(u)
    Pulse.enable(need)
    Adapting.moodle(u)
end

local function onChanged() Hooks.refresh() end
OA.Sync.listen("upgrades", onChanged)
OA.Sync.listen("all", onChanged)

-- ---- notices and the banner ------------------------------------------------------------------------------------

-- The banner of a tree opening: a few lines on the top of the screen that fade away. Its frame (Trade/UI live) runs
-- every frame before the UI draws: with PZ Optimization the fade starts on time after the banner held still, and the
-- banner goes at the end of its life; the drawing only paints.
local Banner = ISPanel:derive("ISOABanner")
ISOABanner = Banner
local banner = nil

function Banner:new(text)
    local fh = getTextManager():getFontHeight(UIFont.Medium)
    local lines = {}
    -- a text breaks its lines with <LINE>
    for line in string.gmatch(text .. "<LINE>", "(.-)<LINE>") do lines[#lines + 1] = line end
    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, getTextManager():MeasureStringX(UIFont.Medium, line))
    end
    width = width + fh * 2
    local height = #lines * (fh + 2) + fh
    local x = math.floor((getPlayerScreenWidth(0) - width) / 2) + getPlayerScreenLeft(0)
    local y = getPlayerScreenTop(0) + math.floor(getPlayerScreenHeight(0) * 0.12)
    local o = ISPanel.new(self, x, y, width, height)
    o.lines, o.fh = lines, fh
    o.backgroundColor = { r = 0.02, g = 0.04, b = 0.06, a = 0.85 }
    o.borderColor = { r = 0.4, g = 0.8, b = 1.0, a = 0.9 }
    o.born = getTimestampMs()
    return o
end

Banner.LIFETIME = 9000
Banner.FADE = 2000

-- Each frame: the banner taken off at the end of its life, or when another took its place (nil then); else its age
-- while it fades, 0 while it holds still.
function Banner.tick(el, now)
    if el ~= banner then return nil end
    local age = now - el.born
    if age >= Banner.LIFETIME then
        el:removeFromUIManager()
        banner = nil
        return nil
    end
    return age > Banner.LIFETIME - Banner.FADE and age or 0
end

function Banner:render()
    local age = getTimestampMs() - self.born
    local a = 1
    if age > Banner.LIFETIME - Banner.FADE then a = math.max(0, (Banner.LIFETIME - age) / Banner.FADE) end
    self.backgroundColor.a = 0.85 * a
    self.borderColor.a = 0.9 * a
    local y = self.fh / 2
    for _, line in ipairs(self.lines) do
        self:drawTextCentre(line, self.width / 2, y, 0.85, 0.95, 1.0, a, UIFont.Medium)
        y = y + self.fh + 2
    end
end

function Hooks.banner(text)
    if banner then
        banner:removeFromUIManager()
        banner = nil
    end
    banner = Banner:new(text)
    banner:initialise()
    banner:instantiate()
    banner.javaObject:setConsumeMouseEvents(false)
    banner:addToUIManager()
    UI.live(banner, Banner.tick)
end

-- A tree opened (its first serum adapted to): a title, with a line under it saying a paper came to the terminal's folder
-- (`guide`: the tree's memo did), or the banner when the API cannot draw it.
function Hooks.treeOpened(playerId, tree, guide)
    local name = "IGUI_OA_Tree_Name_" .. tree
    local line = guide and "IGUI_OA_Title_GuideSub" or nil
    local detail = { key = "IGUI_OA_Title_TreeOpened", args = { { key = name } }, sub = line, style = "stamp" }
    if OA.Titles.show(playerId, detail, true) == "title" then return end
    local text = getText("IGUI_OA_Title_TreeOpened", getText(name))
    if line then text = text .. "<LINE>" .. getText(line) end
    Hooks.banner(text)
end

local function localizedArgs(detail)
    local args = {}
    local raw = detail.args or {}
    for i = 1, #raw do args[i] = raw[i] end
    local key = detail.key
    if (key == "IGUI_OA_Tree_Adapted" or key == "IGUI_OA_Tree_Opened" or key == "IGUI_OA_Tree_ResetDone") and args[1] then
        args[1] = Texts.treeName(tostring(args[1]))
    elseif (key == "IGUI_OA_Tree_FirstEffect" or key == "IGUI_OA_Tree_FirstEffectSingle") and args[1] then
        args[1] = Texts.nodeName(tostring(args[1]))
    elseif (key == "IGUI_OA_Tree_ApproveFailed" or key == "IGUI_OA_Tree_ResetFailed") and args[1] then
        args[1] = Texts.reason(args[1])
    elseif key == "IGUI_OA_Tree_DrugLost" and args[1] then
        args[1] = getText("IGUI_OA_Wound_" .. tostring(args[1]))
    end
    return args
end

local function onNotice(playerId, detail)
    if type(detail) ~= "table" or type(detail.key) ~= "string" then return end
    if not string.find(detail.key, "^IGUI_OA_Tree_") then return end
    local player = getPlayer()
    if not player then return end
    if playerId and OA.Client.id(player) ~= playerId then return end
    local args = localizedArgs(detail)
    local text = getText(detail.key, args[1], args[2], args[3])
    -- the first research point: where the plan is made, once a character
    if (detail.key == "IGUI_OA_Tree_Adapted" or detail.key == "IGUI_OA_Tree_AdaptedShared")
        and not player:getModData().OA_ResearchHint then
        player:getModData().OA_ResearchHint = true
        Hooks.banner(getText("IGUI_OA_Tree_WhereHint"))
    end
    if detail.key == "IGUI_OA_Tree_Opened" then
        local raw = detail.args or {}
        Hooks.treeOpened(playerId, tostring(raw[1]), raw[2] == "guide")
    elseif string.find(detail.key, "Failed$") or string.find(detail.key, "Fail$") or string.find(detail.key, "Expired$")
        or string.find(detail.key, "NotOwner$") or string.find(detail.key, "Lost$") then
        HaloTextHelper.addBadText(player, text)
    else
        HaloTextHelper.addGoodText(player, text)
    end
end
OA.Sync.listen("notice", onNotice)

-- ---- the menus -------------------------------------------------------------------------------------------------

local function tip(option, text)
    local t = ISToolTip:new()
    t:initialise()
    t:setVisible(false)
    t.description = text
    option.toolTip = t
end

local function unavailable(option, text)
    option.notAvailable = true
    tip(option, text)
end

local function useItem(player, item)
    ISInventoryPaneContextMenu.transferIfNeeded(player, item)
    ISTimedActionQueue.add(ISOAUseSerum:new(player, item))
end

-- Runs the adders of a list so that the first one ends up the first option of the menu: each puts its option on top, so
-- they run from the last (the options of this mod go above the game's own).
local function onTop(adders)
    for i = #adders, 1, -1 do adders[i]() end
end

local function onFillInventory(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local actual = ISInventoryPane.getActualItems(items)
    local done = {}
    local adders = {}
    for _, item in ipairs(actual) do
        local itemType = item:getType()
        local kind, length = nil, nil
        if item:getModule() == OA.MOD then kind, length = Serums.kind(itemType) end
        if kind and not done[itemType] then
            done[itemType] = true
            local id = OA.Client.id(player)
            adders[#adders + 1] = function()
                if kind == "upgrade" or kind == "shared" then
                    context:addOptionOnTop(getText("ContextMenu_OA_Tree_Inject"), player, useItem, item)
                elseif kind == "cure" then
                    local option = context:addOptionOnTop(getText("ContextMenu_OA_Tree_UseCure"), player, useItem, item)
                    local status, left = Serums.cureStatus(item, id)
                    if status == "expired" then
                        unavailable(option, getText("Tooltip_OA_Tree_CureExpired"))
                    elseif status == "notOwner" then
                        unavailable(option, getText("Tooltip_OA_Tree_CureNotOwner"))
                    else
                        tip(option, getText("Tooltip_OA_Tree_CureLeft", Texts.number(left)))
                    end
                elseif kind == "delay" then
                    -- never refused for want of an infection: that would tell the player whether they have one
                    local option = context:addOptionOnTop(getText("ContextMenu_OA_Tree_TakeDelay"), player, useItem, item)
                    tip(option, getText("Tooltip_OA_Tree_DelayInfo", OA.Infection.DRUG_HOURS[length] / 24))
                elseif kind == "reversal" then
                    local option = context:addOptionOnTop(getText("ContextMenu_OA_Tree_UseReversal"), player, useItem, item)
                    tip(option, getText("Tooltip_OA_Tree_Item_InfectionReversal"))
                elseif kind == "test" then
                    local option = context:addOptionOnTop(getText("ContextMenu_OA_Tree_UseTest"), player, useItem, item)
                    tip(option, getText("Tooltip_OA_Tree_Item_InfectionTestKit"))
                end
            end
        end
    end
    onTop(adders)
end
Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)

-- What the lock options need in the character's things, by the action: whether it is there and the words that say what
-- is missing. They are looked for here, when the option is picked, not when the menu is built (that would search the
-- whole inventory at every right-click on a locked door).
local NEEDS = {
    [ISOAPryOpen] = { have = function(player) return Actions.pryBar(player) ~= nil end,
        missing = "Tooltip_OA_Tree_NeedPryBar" },
    [ISOAPickLock] = { have = function(player)
        local clip, driver = Actions.pickTools(player)
        return clip ~= nil and driver ~= nil
    end, missing = "Tooltip_OA_Tree_NeedPickTools" },
}

local function startLock(player, target, class)
    local needs = NEEDS[class]
    if needs and not needs.have(player) then
        HaloTextHelper.addBadText(player, getText(needs.missing))
        return
    end
    if instanceof(target, "VehiclePart") then
        ISTimedActionQueue.add(class:new(player, target))
        return
    end
    if luautils.walkAdjWindowOrDoor(player, target:getSquare(), target) then
        ISTimedActionQueue.add(class:new(player, target))
    end
end

-- The two options for one locked door, window or car part.
local function addLockOptions(context, player, target)
    if not Actions.isLocked(target) then return end
    local u = Rules.section(OA.Client.record(player))
    local crowbar, pick = Rules.rank(u, "crowbar"), Rules.rank(u, "lock")
    if crowbar < 1 and pick < 1 then return end
    local reinforced = Actions.isReinforced(target)
    -- pry, then pick: added on top from the last. A missing tool is not greyed out here (that needs a search of the
    -- inventory); the tooltip names the tools and startLock tells the player when the option is picked without them.
    if pick >= 1 then
        local chance = Texts.percent(Rules.lockChance(u) * 100)
        local option = context:addOptionOnTop(getText("ContextMenu_OA_Tree_Pick", chance), player, startLock, target, ISOAPickLock)
        if reinforced and pick < 2 then
            unavailable(option, getText("Tooltip_OA_Tree_Reinforced"))
        else
            tip(option, getText("Tooltip_OA_Tree_PickInfo", chance) .. " <LINE> " .. getText("Tooltip_OA_Tree_NeedPickTools"))
        end
    end
    if crowbar >= 1 then
        local chance = Texts.percent(Rules.crowbarChance(u) * 100)
        local option = context:addOptionOnTop(getText("ContextMenu_OA_Tree_Pry", chance), player, startLock, target, ISOAPryOpen)
        if reinforced and crowbar < 2 then
            unavailable(option, getText("Tooltip_OA_Tree_Reinforced"))
        else
            tip(option, getText("Tooltip_OA_Tree_PryInfo", chance) .. " <LINE> " .. getText("Tooltip_OA_Tree_NeedPryBar"))
        end
    end
end

local function onFillWorld(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    if not OA.Client.record(player) then return end
    local seen = {}
    for _, object in ipairs(worldobjects) do
        if (instanceof(object, "IsoDoor") or instanceof(object, "IsoWindow")) and not seen[object] then
            seen[object] = true
            addLockOptions(context, player, object)
        end
    end
    local vehicle = IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(), getMouseYScaled())
    if vehicle and player:DistToProper(vehicle) < 4 then
        local part = vehicle:getUseablePart(player)
        if part and part:getDoor() then addLockOptions(context, player, part) end
        local trunk = vehicle:getPartById("TrunkDoor") or vehicle:getPartById("DoorRear")
        if trunk and trunk ~= part and trunk:getDoor() then addLockOptions(context, player, trunk) end
    end
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorld)

-- ---- the serums' tooltips ---------------------------------------------------------------------------------------

-- The text under a serum's name. The cure serum's tells the days it has left; the others have one fixed text, and a
-- delay drug's and a reversal's add the infection's progress once a test has shown the infection (not before).
local function tipText(item, player)
    local itemType = item:getType()
    if itemType ~= "CureSerum" then
        local text = getText("Tooltip_OA_Tree_Item_" .. itemType)
        local kind = Serums.kind(itemType)
        if kind == "delay" or kind == "reversal" then
            local state = Infection.state(OA.Client.record(player), OA.hours())
            if state and state.progress then
                text = text .. "<LINE>" .. getText("Tooltip_OA_Tree_Progress", math.floor(state.progress * 100))
            end
        end
        return text
    end
    local status, left = Serums.cureStatus(item, OA.Client.id(player))
    if status == "ok" then return getText("Tooltip_OA_Tree_CureLeft", Texts.number(left)) end
    if status == "expired" then return getText("Tooltip_OA_Tree_CureExpired") end
    return getText("Tooltip_OA_Tree_CureNotOwner")
end

local originalRender = ISToolTipInv.render

-- The text is put on the item while its tooltip is drawn and taken off after, so nothing else sees it.
function ISToolTipInv:render()
    local item = self.item
    local player = getPlayer()
    if item and player and item:getModule() == OA.MOD and Serums.kind(item:getType()) then
        local old = item:getTooltip()
        item:setTooltip(OA.tooltipText(tipText(item, player)))
        local ok, err = pcall(originalRender, self)
        item:setTooltip(old)
        if not ok then error(err, 0) end
        return
    end
    originalRender(self)
end

-- ---- the infection, once a minute ------------------------------------------------------------------------------

local lastBiteLevel = nil   -- the bite shield moodle's level a minute ago (nil before the first minute)

-- The bite shield's moodle while it rests, and a title as it is armed again (not when the game starts armed).
local function biteShield(player, u, now)
    local level = Rules.biteLevel(u, now)
    OA.Upgrades.Moodles.set("biteShield", level)
    if level == 0 and lastBiteLevel and lastBiteLevel > 0 and Rules.rank(u, "resistPlus") >= 2 then
        OA.Titles.show(OA.Client.id(player), { key = "IGUI_OA_Title_BiteReady", style = "notice", tone = "green",
            fallback = "good" })
    end
    lastBiteLevel = level
end

local function onMinute()
    local u, player = localSection()
    if not u or not player or player:isDead() then return end
    local now = OA.hours()
    Watch.minute(player, now)
    Adapting.minute(player, u, now)
    biteShield(player, u, now)
    -- until the API shield is there, the bite is undone from here
    if Rules.rank(u, "resistPlus") >= 2 and not Effects.biteShieldApplied() then
        if Serums.shieldBite(player, u, now) then
            OA.Sync.send(player, "upgrades.bite", {})
        end
    end
end
Events.EveryOneMinute.Add(onMinute)

-- A bite the API's shield saved: the shield rests.
local function onBiteSurvived()
    local player = getPlayer()
    if player then OA.Sync.send(player, "upgrades.bite", {}) end
end

local function onGameStart()
    Effects.reset()
    Hooks.refresh()
    if Events.OnPZToolsBiteSurvived then Events.OnPZToolsBiteSurvived.Add(onBiteSurvived) end
end
Events.OnGameStart.Add(onGameStart)

-- Real milliseconds at least between two refreshes from the ten-minute clock. Of what a refresh reads only the world
-- age moves with game time (the bite shield's rest ends at a game time), and ten game minutes are 25 s of real time at
-- the default day length but some 0.6 s fast-forwarded (x40) and less asleep: the shield is then ready at most this
-- late in real time. A change to the record refreshes at once, as before.
Hooks.REFRESH_MS = 5000

local refreshedAt = {}

Events.EveryTenMinutes.Add(function()
    if OA.due(refreshedAt, "clock", getTimestampMs(), Hooks.REFRESH_MS) then Hooks.refresh() end
end)

return Hooks
