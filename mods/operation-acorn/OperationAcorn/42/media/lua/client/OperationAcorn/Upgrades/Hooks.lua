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
require "OperationAcorn/TipLines"
require "OperationAcorn/Upgrades/Api"
require "OperationAcorn/Upgrades/Sense"
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
-- A new character (one that died is replaced in the world): its own record's effects at once, none of the last one's.
OA.on("OnCreatePlayer", onChanged)

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
    o.born = UI.sceneNow()
    return o
end

Banner.LIFETIME = 9000
Banner.FADE = 2000

-- Each frame: the banner taken off at the end of its life, or when another took its place (nil then); else its age
-- while it fades, 0 while it holds still.
function Banner.tick(el)
    if el ~= banner then return nil end
    local age = UI.sceneNow() - el.born
    if age >= Banner.LIFETIME then
        el:removeFromUIManager()
        banner = nil
        return nil
    end
    return age > Banner.LIFETIME - Banner.FADE and age or 0
end

function Banner:render()
    local age = UI.sceneNow() - self.born
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

-- A tree opened (its first serum adapted to): a title, with the points that came under it and, with `guide`, that its
-- memo came to the terminal's folder; or the banner when the API cannot draw it. `shared`: a shared dose opened it, or
-- with no tree (tree "") the trees still closed, all at once; its points are shared ones.
function Hooks.treeOpened(playerId, tree, guide, points, shared)
    local key, args, title = "IGUI_OA_Title_TreeOpened", nil, nil
    if tree ~= "" then
        local name = "IGUI_OA_Tree_Name_" .. tree
        args, title = { { key = name } }, getText(key, getText(name))
    else
        key = "IGUI_OA_Title_TreesOpened"
        args, title = {}, getText(key)
    end
    local line = (shared and "IGUI_OA_Title_OpenedSubShared" or "IGUI_OA_Title_OpenedSub") .. (guide and "Guide" or "")
    local detail = { key = key, args = args, sub = line, subArgs = { points or 1 }, style = "dust" }
    if OA.Titles.show(playerId, detail, true) == "title" then return end
    Hooks.banner(title .. "<LINE>" .. getText(line, points or 1))
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

-- Notices the character says (its own speech, as the game's self-talk; a halo text is pushed aside by other notices).
local SAID = {
    IGUI_OA_Tree_PrySuccess = true, IGUI_OA_Tree_PryFail = true, IGUI_OA_Tree_PickSuccess = true,
    IGUI_OA_Tree_PickFail = true, IGUI_OA_Tree_PickDisarmed = true, IGUI_OA_Tree_Disarmed = true,
    IGUI_OA_Tree_CureExpired = true, IGUI_OA_Tree_CureNotOwner = true,
}

-- Notices that are events, shown as titles (Titles.notice) with the notice's text under them.
local TITLED = {
    IGUI_OA_Tree_ResetDone = { key = "IGUI_OA_Title_Reset", titleArgs = true, tone = "amber" },
    IGUI_OA_Tree_DelayDone = { key = "IGUI_OA_Title_DelayDone", style = "pulse" },
    IGUI_OA_Tree_DrugLost = { key = "IGUI_OA_Title_DrugLost", style = "sink" },
    IGUI_OA_Tree_GuideSent = { alone = true, style = "type" },
}

-- The notices that bring research points, and when the first one's hint comes (real ms: after its title).
Hooks.HINT_MS = 6500
-- The notices that bring research points.
local POINTS = { IGUI_OA_Tree_Adapted = true, IGUI_OA_Tree_AdaptedShared = true, IGUI_OA_Tree_Opened = true,
    IGUI_OA_Tree_OpenedShared = true }

local function onNotice(playerId, detail)
    if type(detail) ~= "table" or type(detail.key) ~= "string" then return end
    if not string.find(detail.key, "^IGUI_OA_Tree_") then return end
    local player = getPlayer()
    if not player then return end
    if playerId and OA.Client.id(player) ~= playerId then return end
    local args = localizedArgs(detail)
    local text = getText(detail.key, args[1], args[2], args[3])
    if detail.key == "IGUI_OA_Tree_Opened" then
        local raw = detail.args or {}
        Hooks.treeOpened(playerId, tostring(raw[1]), raw[2] == "guide", tonumber(raw[3]))
    elseif detail.key == "IGUI_OA_Tree_OpenedShared" then
        local raw = detail.args or {}
        Hooks.treeOpened(playerId, tostring(raw[1] or ""), raw[2] == "guide", tonumber(raw[3]), true)
    elseif TITLED[detail.key] then
        OA.Titles.notice(playerId, TITLED[detail.key], detail.key, args)
    elseif SAID[detail.key] then
        player:Say(text)
    elseif string.find(detail.key, "Failed$") then
        -- the adaptation tab's buttons: a brief title, red, over its window
        OA.Titles.brief(playerId, detail.key, args, "red")
    else
        OA.Titles.brief(playerId, detail.key, args)
    end
    -- the first research point: where the plan is made, once a character, a brief title once the point's own is over
    -- (at once without the API's timers), and none when the tab is on the screen already
    if POINTS[detail.key] and not player:getModData().OA_ResearchHint then
        player:getModData().OA_ResearchHint = true
        local function hint()
            local Window = OA.Upgrades.Window
            if Window and Window.onScreen(0) then return end
            OA.Titles.brief(playerId, "IGUI_OA_Tree_WhereHint")
        end
        if not OA.timerAfter(Hooks.HINT_MS, hint) then hint() end
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
    local actual = OA.menuItems(items)
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
OA.on("OnFillInventoryObjectContextMenu", onFillInventory)

-- What the lock options need in the character's things, by the action: whether it is there and the line the character
-- says when it is missing. They are looked for here, when the option is picked, not when the menu is built (that would search the
-- whole inventory at every right-click on a locked door).
local NEEDS = {
    [ISOAPryOpen] = { have = function(player) return Actions.pryBar(player) ~= nil end,
        missing = "IGUI_OA_Tree_SayNeedPryBar" },
    [ISOAPickLock] = { have = function(player)
        local clip, driver = Actions.pickTools(player)
        return clip ~= nil and driver ~= nil
    end, missing = "IGUI_OA_Tree_SayNeedPickTools" },
}
NEEDS[ISOADisarm] = NEEDS[ISOAPickLock]

-- The tools in hand first, as the game's own tool actions do (ISWorldObjectContextMenu.onUnbarricade): the pry bar or
-- the screwdriver taken out of its bag and equipped, the paperclip taken out of its bag.
local function equipTools(player, class)
    if class == ISOAPryOpen then
        local bar = Actions.pryBar(player)
        if bar then ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), bar, true) end
        return
    end
    local clip, driver = Actions.pickTools(player)
    if driver then ISWorldObjectContextMenu.equip(player, player:getPrimaryHandItem(), driver, true) end
    if clip then ISWorldObjectContextMenu.transferIfNeeded(player, clip) end
end

local function startLock(player, target, class)
    local needs = NEEDS[class]
    if needs and not needs.have(player) then
        player:Say(getText(needs.missing))
        return
    end
    if instanceof(target, "VehiclePart") then
        -- to the part first, as the game walks to a car's part (ISVehicleMenu)
        local vehicle, area = target:getVehicle(), target:getArea()
        if area and not vehicle:isInArea(area, player) then
            ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, vehicle, area))
        end
        equipTools(player, class)
        ISTimedActionQueue.add(class:new(player, target))
        return
    end
    if luautils.walkAdjWindowOrDoor(player, target:getSquare(), target) then
        equipTools(player, class)
        ISTimedActionQueue.add(class:new(player, target))
    end
end

-- The tools of each action, as names the extension API counts (items.count: an item's full type or a tag; one of each
-- inner list is needed).
local TOOLS = {
    [ISOAPickLock] = { { "Base.Paperclip" }, { "base:screwdriver" } },
    [ISOAPryOpen] = { { "base:crowbar", "base:prybar" } },
}
TOOLS[ISOADisarm] = TOOLS[ISOAPickLock]

-- Whether the character carries the action's tools, as the extension API counts them (kept up by its inventory hooks,
-- so the menu searches nothing); nil without the API's count, when the option only names them and startLock checks.
-- A broken tool counts here: startLock tells of it.
local function carries(player, class)
    local api = OA.api()
    local items = api and api.items
    local count = type(items) == "table" and items.count or nil
    if type(count) ~= "function" then return nil end
    for _, anyOf in ipairs(TOOLS[class]) do
        local found = false
        for _, name in ipairs(anyOf) do
            local ok, n = OA.try("upgrades: counting the tools", count, player, name)
            if not ok then return nil end
            if n > 0 then found = true break end
        end
        if not found then return false end
    end
    return true
end

-- The option's tooltip with the tools it needs: in red and the option greyed out when the character has none, left
-- out when it has them (as the game's own options say only what is missing), and named when the API cannot tell.
local function toolTip(option, player, class, text, need)
    local has = carries(player, class)
    if has == false then
        option.notAvailable = true
        tip(option, text .. " <LINE> <RGB:1,0.35,0.3> " .. getText(need))
    elseif has then
        tip(option, text)
    else
        tip(option, text .. " <LINE> " .. getText(need))
    end
end

-- An option's label: a car's part named after the action, as two parts of one car may both be offered.
local function label(key, partKey, chance, part)
    if part then return getText(partKey, chance, part) end
    return getText(key, chance)
end

-- The option to cut the alarm of a door, window or car part alone, locked or not, for one with 자물쇠 따기 and 경보
-- 읽기 (who reads alarms: the character told of it). Picking a locked one cuts it too.
local function addDisarmOption(context, player, target, u)
    if Rules.rank(u, "lock") < 1 or Rules.rank(u, "alarm") < 1 or not Actions.alarmOf(target) then return end
    local chance = Texts.percent(Rules.lockChance(u) * 100)
    local option = context:addOptionOnTop(getText("ContextMenu_OA_Tree_Disarm", chance), player, startLock, target, ISOADisarm)
    toolTip(option, player, ISOADisarm, getText("Tooltip_OA_Tree_DisarmInfo", chance), "Tooltip_OA_Tree_NeedPickTools")
end

-- The two options for one locked door, window or car part, and the alarm's alone (locked or not: cutting the alarm
-- leaves the lock as it is). `part` names a car's part in the labels; `alarm` false leaves the alarm's option out (a
-- car's second part: the alarm is the car's, offered once).
local function addLockOptions(context, player, target, part, alarm)
    local u = Rules.section(OA.Client.record(player))
    -- first: the options are added on top, so it shows under the pick and the pry
    if alarm ~= false then addDisarmOption(context, player, target, u) end
    if not Actions.isLocked(target) then return end
    local crowbar, pick = Rules.rank(u, "crowbar"), Rules.rank(u, "lock")
    if crowbar < 1 and pick < 1 then return end
    local reinforced = Actions.isReinforced(target)
    -- pry, then pick: added on top from the last
    if pick >= 1 then
        local chance = Texts.percent(Rules.lockChance(u) * 100)
        local option = context:addOptionOnTop(label("ContextMenu_OA_Tree_Pick", "ContextMenu_OA_Tree_PickPart", chance, part), player, startLock, target, ISOAPickLock)
        if reinforced and pick < 2 then
            unavailable(option, getText("Tooltip_OA_Tree_Reinforced"))
        else
            local text = getText("Tooltip_OA_Tree_PickInfo", chance)
            -- the alarm it cuts, told only to one who reads alarms
            if Rules.rank(u, "alarm") >= 1 and Actions.alarmOf(target) then text = text .. " <LINE> " .. getText("Tooltip_OA_Tree_PickAlarm") end
            toolTip(option, player, ISOAPickLock, text, "Tooltip_OA_Tree_NeedPickTools")
        end
    end
    if crowbar >= 1 then
        local chance = Texts.percent(Rules.crowbarChance(u) * 100)
        local option = context:addOptionOnTop(label("ContextMenu_OA_Tree_Pry", "ContextMenu_OA_Tree_PryPart", chance, part), player, startLock, target, ISOAPryOpen)
        if reinforced and crowbar < 2 then
            unavailable(option, getText("Tooltip_OA_Tree_Reinforced"))
        else
            toolTip(option, player, ISOAPryOpen, getText("Tooltip_OA_Tree_PryInfo", chance), "Tooltip_OA_Tree_NeedPryBar")
        end
    end
end

-- A car's part by the game's own name of it (as its mechanics window names it).
local function partName(part)
    return getText("IGUI_VehiclePart" .. part:getId())
end

-- How near the character must stand for the lock and alarm options: the options tell whether a door, window or car is
-- locked and alarmed, which the character knows close up, at the distance 경보 읽기 notices an alarm and outlines it
-- (Sense.ALARM_NEAR), a car's measured as the alarm's (from its middle, Sense.ALARM_CAR less).
local NEAR = OA.Upgrades.Sense.ALARM_NEAR

local function nearSquare(player, sq)
    if not sq or sq:getZ() ~= math.floor(player:getZ()) then return false end
    local dx, dy = sq:getX() + 0.5 - player:getX(), sq:getY() + 0.5 - player:getY()
    return dx * dx + dy * dy < NEAR * NEAR
end

local function onFillWorld(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player or player:getVehicle() then return end
    if not OA.Client.record(player) then return end
    local seen = {}
    for _, object in ipairs(worldobjects) do
        if (instanceof(object, "IsoDoor") or instanceof(object, "IsoWindow")) and not seen[object]
                and nearSquare(player, object:getSquare()) then
            seen[object] = true
            addLockOptions(context, player, object)
        end
    end
    local vehicle = IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(), getMouseYScaled())
    if vehicle and player:DistToProper(vehicle) - OA.Upgrades.Sense.ALARM_CAR <= NEAR then
        local part = vehicle:getUseablePart(player)
        local door = part and part:getDoor() and part or nil
        local trunk = vehicle:getPartById("TrunkDoor") or vehicle:getPartById("DoorRear")
        if trunk == door or not (trunk and trunk:getDoor()) then trunk = nil end
        -- the trunk's first, so the door's come on top; the car's alarm once, with the door's (the trunk's without one)
        if trunk then addLockOptions(context, player, trunk, partName(trunk), door == nil) end
        if door then addLockOptions(context, player, door, partName(door)) end
    end
end
OA.on("OnFillWorldObjectContextMenu", onFillWorld)

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

-- The lines a serum adds to its tooltip (TipLines puts them on the item while the tooltip is drawn).
OA.TipLines.add("serums", function(item)
    local player = getPlayer()
    if not (player and item:getModule() == OA.MOD and Serums.kind(item:getType())) then return nil end
    return { tipText(item, player) }
end)

-- ---- the infection, once a minute ------------------------------------------------------------------------------

local lastBiteLevel = nil   -- the bite shield moodle's level a minute ago (nil before the first minute)

-- The bite shield's moodle while it rests, and a title as it is armed again (not when the game starts armed).
local function biteShield(player, u, now)
    local level = Rules.biteLevel(u, now)
    OA.Upgrades.Moodles.set("biteShield", level)
    if level == 0 and lastBiteLevel and lastBiteLevel > 0 and Rules.rank(u, "resistPlus") >= 2 then
        OA.Titles.show(OA.Client.id(player), { key = "IGUI_OA_Title_BiteReady", style = "dust", tone = "green" })
    end
    lastBiteLevel = level
end

local function onMinute()
    local u, player = localSection()
    if not u or not player or player:isDead() then return end
    local now = OA.hours()
    Watch.minute(player, now)
    Adapting.minute(player, u, now)
    if u.adapt and OA.Upgrades.Window then OA.Upgrades.Window.adaptMinute() end
    biteShield(player, u, now)
    -- until the API shield is there, the bite is undone from here
    if Rules.rank(u, "resistPlus") >= 2 and not Effects.biteShieldApplied() then
        if Serums.shieldBite(player, u, now) then
            OA.Sync.send(player, "upgrades.bite", {})
        end
    end
end
OA.on("EveryOneMinute", onMinute)

-- A bite the API's shield saved: the shield rests.
local function onBiteSurvived()
    local player = getPlayer()
    if player then OA.Sync.send(player, "upgrades.bite", {}) end
end

-- (the event keeps its handlers across games: added once)
local biteHooked = false

local function onGameStart()
    Effects.reset()
    Hooks.refresh()
    if Events.OnPZExtBiteSurvived and not biteHooked then
        biteHooked = true
        OA.on("OnPZExtBiteSurvived", onBiteSurvived)
    end
end
OA.on("OnGameStart", onGameStart)

-- Real milliseconds at least between two refreshes from the ten-minute clock. Of what a refresh reads only the world
-- age moves with game time (the bite shield's rest ends at a game time), and ten game minutes are 25 s of real time at
-- the default day length but some 0.6 s fast-forwarded (x40) and less asleep: the shield is then ready at most this
-- late in real time. A change to the record refreshes at once, as before. The clock refreshes only when what was
-- declared no longer fits (Effects.stale: the shield's rest ended, no API yet, or an input besides the record changed:
-- the hidden zombie fix option, the vision traits) or the character's landing variable is not what the record says
-- (landStale), not every ten minutes.
Hooks.REFRESH_MS = 5000

local refreshedAt = {}

-- Whether the character's landing variable (OALandRank) is not what the record says: the game may have cleared it.
function Hooks.landStale(u, player)
    return u ~= nil and player ~= nil and player:getVariableString(Effects.LAND_VARIABLE) ~= (Effects.landRank(u) or "")
end

OA.on("EveryTenMinutes", function()
    if not OA.due(refreshedAt, "clock", getTimestampMs(), Hooks.REFRESH_MS) then return end
    local u, player = localSection()
    if Effects.stale(u, OA.hours(), player) or Hooks.landStale(u, player) then Hooks.refresh() end
end)

return Hooks
