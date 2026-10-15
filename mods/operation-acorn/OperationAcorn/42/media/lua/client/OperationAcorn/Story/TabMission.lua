-- The missions tab's mission screen (DESIGN-terminal 6.1, 6.2): the mission card, a card of its own under a colour band
-- (the colour is the map's: teal for the regular and contract missions, sky blue for the story's), with what is
-- asked, where from here, until when and what it pays; and under it the special request's slot: a locked board at
-- the crude terminal, at the field terminal the two requests offered (one to choose), or the one taken. Everything is
-- worked out when the record changes or the player has walked (`refresh`); the frames only draw it (`prerender`).
require "OperationAcorn/Trade/TerminalWindow"
require "PZUIKit/Button"
require "PZUIKit/Confirm"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Rewards"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/View"
require "OperationAcorn/Economy/Shop"
require "OperationAcorn/Trade/StatusDraw"
local OA = OperationAcorn
local UI, Text = OA.Trade.UI, OA.Trade.Text
local Data, Places, Rewards, Missions = OA.StoryData, OA.Places, OA.Rewards, OA.Missions

OATabMission = OATab:derive("OATabMission")

-- The card's height, and the height of the screen (the body under the sub-tabs) under which it is the small one.
OATabMission.CARD_H, OATabMission.CARD_H_SMALL, OATabMission.SMALL_BELOW = 196, 172, 350


-- Text with its numbers apart ---------------------------------------------------------------------------------------
-- A line's numbers are drawn in the palette's number font (numberFont), so a line is drawn in runs. The numbers are
-- wrapped in two control characters before the text is made and cut out again: the translation keeps its one
-- natural sentence.
local MARK_A, MARK_B = "\1", "\2"

local function wrapped(...)
    local args = {}
    for i = 1, select("#", ...) do args[i] = MARK_A .. tostring((select(i, ...))) .. MARK_B end
    return args
end

-- The runs of a translated text: { { text =, num = true | nil, kind = colour name } } with `kind` for all of them.
local function runsOf(kind, key, ...)
    local a = wrapped(...)
    local text = getText(key, a[1], a[2], a[3], a[4])
    local list, pos = {}, 1
    while pos <= #text do
        local s = string.find(text, MARK_A, pos, true)
        if not s then break end
        local e = string.find(text, MARK_B, s, true) or (#text + 1)
        if s > pos then list[#list + 1] = { text = string.sub(text, pos, s - 1), kind = kind } end
        list[#list + 1] = { text = string.sub(text, s + 1, e - 1), kind = kind, num = true }
        pos = e + 1
    end
    if pos <= #text then list[#list + 1] = { text = string.sub(text, pos), kind = kind } end
    return list
end

local function plain(kind, text)
    return { { text = text, kind = kind } }
end

-- The lists one after another.
local function join(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, run in ipairs(list) do out[#out + 1] = run end
    end
    return out
end

-- The widths, with the number font of the palette for the numbers.
local function measure(list, p)
    local w = 0
    for _, run in ipairs(list) do
        run.w = UI.textWidth(run.text, run.num and p.numberFont or nil)
        w = w + run.w
    end
    list.w = w
    return list
end

local function drawRuns(el, x, y, list, p)
    for _, run in ipairs(list) do
        UI.text(el, run.text, x, y, p[run.kind] or p.text, run.num and p.numberFont or nil)
        x = x + run.w
    end
end

-- A text cut into lines of at most `width` (at the spaces; a word wider than a line is cut where it is).
local WORDS = { breakWords = true }
local function wrapLines(text, width)
    return OA.wrap(text, width, UI.textWidth, WORDS)
end

-- A panel: the border, and the palette's panel colour (the crude terminal a faint wash).
local function panel(el, p, x, y, w, h)
    if p.panel then UI.fill(el, x, y, w, h, p.panel) else UI.fill(el, x, y, w, h, p.text, 0.03) end
    UI.frame(el, x, y, w, h, p.border)
end

-- The widgets ------------------------------------------------------------------------------------------------------

function OATabMission:createChildren()
    local p = self:palette()
    local bh = UI.buttonHeight()
    self.mapButton = PZUIButton:new(0, 0, 120, bh, getText("IGUI_OA_Story_UI_ShowMap"), p, self, OATabMission.onMap, "strong")
    self.rerollButton = PZUIButton:new(0, 0, 88, bh, getText("IGUI_OA_Story_UI_Reroll"), p, self, OATabMission.onReroll)
    self.optionButtons = {}
    for _, option in ipairs({ "a", "b" }) do
        local b = PZUIButton:new(0, 0, 170, bh, "", p, self, OATabMission.onChoose)
        b.internal = option
        self.optionButtons[option] = b
    end
    self.shopButton = PZUIButton:new(0, 0, 120, bh - 4, getText("IGUI_OA_Story_UI_ShowInShop"), p, self, OATabMission.onShop)
    self.acceptButton = PZUIButton:new(0, 0, 120, bh - 4, getText("IGUI_OA_Story_UI_SpecialAccept"), p, self,
        OATabMission.onAccept, "strong")
    self.specialMapButton = PZUIButton:new(0, 0, 120, bh - 4, getText("IGUI_OA_Story_UI_ShowMap"), p, self,
        OATabMission.onSpecialMap, "strong")
    for _, b in ipairs(self:buttons()) do
        b:initialise()
        b:instantiate()
        b:setVisible(false)
        self:addChild(b)
    end
end

-- Every button of the screen (layout shows the ones the screen needs).
function OATabMission:buttons()
    return { self.mapButton, self.rerollButton, self.optionButtons.a, self.optionButtons.b, self.shopButton,
        self.acceptButton, self.specialMapButton }
end

function OATabMission:onMap()
    local info = self.info
    if info and info.area then OA.StoryTabs.showOnMap(self:character()) end
end

-- What cannot be taken back asks first: a choice closes the other option for good, 'take another' costs trust and the
-- week's one, a special request closes the other one offered.
function OATabMission:onChoose(button)
    local text = getText("IGUI_OA_Story_ChooseAsk", button.title or "")
    UI.confirm(self:character(), string.gsub(text, "\\n", "\n"), self, OATabMission.doChoose, button.internal)
end

function OATabMission:doChoose(option)
    self:send("story_choose", { option = option })
end

function OATabMission:onReroll()
    local reroll = self.info and self.info.reroll
    local text = getText("IGUI_OA_Story_RerollAsk", reroll and reroll.trust or 0)
    UI.confirm(self:character(), string.gsub(text, "\\n", "\n"), self, OATabMission.doReroll)
end

function OATabMission:doReroll()
    self:send("story_reroll", {})
end

function OATabMission:onShop()
    self.window:showShopEntry("field_terminal")
end

-- The special request: the one picked of the two is taken; its area on the map.
function OATabMission:onAccept()
    local option = self.pick or "a"
    local offered = self.special and self.special.options and self.special.options[option]
    local text = getText("IGUI_OA_Story_SpecialAsk", offered and offered.title or "")
    UI.confirm(self:character(), string.gsub(text, "\\n", "\n"), self, OATabMission.doAccept, option)
end

function OATabMission:doAccept(option)
    self:send("story_special", { option = option })
end

function OATabMission:onSpecialMap()
    local special = self.info and self.info.special
    if special and special.state == "mission" and special.mission.area then
        OA.StoryTabs.showOnMap(self:character(), "special")
    end
end

-- A click on the screen itself: the radio cells of the two offered requests, and the link to the request's copy.
function OATabMission:onMouseDown(x, y)
    local special = self.special
    local function inside(r) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end
    if special and special.kind == "offer" and special.cells then
        for _, key in ipairs({ "a", "b" }) do
            if inside(special.cells[key]) then self.pick = key end
        end
    elseif special and special.kind == "mission" and special.link and inside(special.linkRect) then
        OA.StoryTabs.openDocument(self.window, special.link.key)
    end
    return true
end

-- What the screen shows -------------------------------------------------------------------------------------------

-- The time left as runs: "남은 기한 8일 6시간", or the hours alone under a day.
local function timeRuns(kind, dayKey, hourKey, hours)
    hours = math.max(0, hours)
    local days = math.floor(hours / 24)
    if days > 0 then return runsOf(kind, dayKey, days, math.floor(hours - days * 24)) end
    return runsOf(kind, hourKey, math.max(1, math.ceil(hours)))
end


-- Where a circle is from the player: "현재 위치에서 북동쪽 약 1.2km · 표시 구역 반지름 약 70m".
local function whereText(px, py, area)
    return Places.whereText(px, py, area.x, area.y, area.r) .. " " .. getText("IGUI_OA_Story_UI_Radius", math.floor(area.r + 0.5))
end

-- The card of a mission: all its strings and numbers.
function OATabMission:buildCard(record, info)
    local p = self:palette()
    local c = self:character()
    local px, py = c:getX(), c:getY()
    local card = { kind = info.kind or "regular" }
    -- the crude terminal is green only: its card band and badge are the bright green
    card.colour = p.mono and p.bright or OA.StoryView.color(card.kind)
    local titleKey, briefKey = Missions.keys(info)
    card.title = getText(titleKey)
    card.badges = { { text = getText("IGUI_OA_Story_UI_Badge_" .. card.kind), colour = card.colour } }
    if info.urgent then card.badges[#card.badges + 1] = { text = getText("IGUI_OA_Story_UI_Badge_urgent"), colour = p.warn } end
    if info.state == "sealed" then
        card.right = plain("text", getText("IGUI_OA_Story_UI_Sealed"))
    elseif info.state == "calling" then
        card.right = plain("text", getText("IGUI_OA_Story_UI_Calling"))
    else
        card.right = timeRuns("text", "IGUI_OA_Story_UI_Left", "IGUI_OA_Story_UI_LeftHours", info.left or 0)
    end
    measure(card.right, p)
    local place = info.facility and getText("IGUI_OA_Story_Facility_" .. info.facility) or ""
    card.brief = getText(briefKey, place, OA.Story.number(record))
    if info.item and info.state ~= "offer" then
        card.item = { type = Data.fullType(info.item),
            runs = join(plain("dim", getText("IGUI_OA_Story_UI_ItemLabel") .. " "), plain("text", getItemNameFromFullType(Data.fullType(info.item)))) }
        -- scattered pieces: "시료 깡통 3곳 중 1곳 회수"
        if info.scatter then
            card.item.runs = join(card.item.runs, plain("text", " "),
                runsOf("text", "IGUI_OA_Story_UI_ScatterCount", info.scatter.total, info.scatter.found))
        end
        measure(card.item.runs, p)
    end
    -- The conditions at the place, as the card has always told them.
    card.lines = {}
    local function line(text) card.lines[#card.lines + 1] = text end
    if info.state == "offer" then line(getText("IGUI_OA_Story_UI_Offer")) end
    if info.swap then line(getText("IGUI_OA_Story_UI_Swap_" .. info.swap)) end
    if info.field then line(getText("IGUI_OA_Story_UI_Field_" .. info.field)) end
    if info.cooler and info.cooler.started then
        line(getText("IGUI_OA_Story_UI_Cooler", string.format("%.1f", info.cooler.temp)))
    end
    if info.compare then line(getText("IGUI_OA_Story_UI_Compare", tostring(info.compare))) end
    if info.heavy then line(getText("IGUI_OA_Story_UI_Heavy", info.heavy)) end
    if info.zombies then
        line(getText("IGUI_OA_Story_UI_Zombies_" .. info.zombies.kind, info.zombies.total, info.zombies.done))
    end
    if info.scatter then line(getText("IGUI_OA_Story_UI_Scatter", math.floor(Rewards.SCATTER_BONUS * 100 + 0.5))) end
    if info.stakeNo then line(getText("IGUI_OA_Story_UI_Stake", tostring(info.stakeNo))) end
    -- Where: one circle, or two for the comparison.
    card.where = {}
    if info.area then
        if info.area2 then
            card.where[1] = { label = getText("IGUI_OA_Story_UI_WhereFirst") .. " ", text = whereText(px, py, info.area) }
            card.where[2] = { label = getText("IGUI_OA_Story_UI_WhereSecond") .. " ", text = whereText(px, py, info.area2) }
        else
            card.where[1] = { label = getText("IGUI_OA_Story_UI_Where") .. " ", text = whereText(px, py, info.area) }
        end
    end
    card.hint = nil
    if info.item and info.state == "open" then
        card.hint = getText("IGUI_OA_Story_UI_Hint", getText(card.kind == "story" and "IGUI_OA_Story_UI_ColourSky" or "IGUI_OA_Story_UI_ColourTeal"))
    end
    -- The reward, with what it is made of when the base is known: the distance and danger pay (credits and trust), the
    -- streak and the flight support's pay (credits only).
    local function percent(v) return v and math.floor(v * 100 + 0.5) or 0 end
    local far, danger, support = percent(info.far), percent(info.danger), percent(info.support)
    local streak = info.streak or 0
    if info.base and (far > 0 or danger > 0 or streak > 0 or support > 0) then
        local dot = getText("IGUI_OA_Story_UI_Dot")
        local bonus = runsOf("dim", "IGUI_OA_Story_UI_Base", Text.credits(info.base))
        if far > 0 then bonus = join(bonus, plain("dim", dot), runsOf("good", "IGUI_OA_Story_UI_Far", far)) end
        if danger > 0 then
            bonus = join(bonus, plain("dim", dot), runsOf("warn", "IGUI_OA_Story_UI_Danger", danger))
        end
        if streak > 0 then
            bonus = join(bonus, plain("dim", dot),
                runsOf("good", "IGUI_OA_Story_UI_Streak", streak, percent(info.streakPay or Rewards.streakBonus(streak))))
        end
        if support > 0 then bonus = join(bonus, plain("dim", dot), runsOf("good", "IGUI_OA_Story_UI_Support", support)) end
        card.bonus = measure(bonus, p)
    end
    if info.credits then
        local reward = runsOf("text", "IGUI_OA_Story_UI_Reward", Text.credits(info.credits), info.trust or 0)
        for _, run in ipairs(reward) do
            if run.num then run.kind = "value" end
        end
        card.reward = measure(reward, p)
    end
    if info.options then
        card.options = {}
        for _, option in ipairs({ "a", "b" }) do
            if info.options[option] then
                card.options[option] = getText("IGUI_OA_Story_Option_" .. tostring(info.title) .. "_" .. option)
            end
        end
    end
    return card
end

-- The empty card: no request now, when the next comes, or that the first stage brings them.
function OATabMission:buildEmpty(record, info)
    local p = self:palette()
    local sub
    if not (info.nextIn and info.nextIn > 0) and not Rewards.level(OA.Story.progress(record)) then
        sub = plain("dim", getText("IGUI_OA_Story_UI_NoneYet"))
    elseif info.nextIn and info.nextIn > 0 then
        sub = timeRuns("dim", "IGUI_OA_Story_UI_NextIn", "IGUI_OA_Story_UI_NextInHours", info.nextIn)
    else
        sub = plain("dim", "")
    end
    return { empty = true, head = getText("IGUI_OA_Story_UI_NoMission"), sub = measure(sub, p) }
end

-- The reward line of a special request: "보상 70,000 크레딧 · 신뢰도 200 · 기한 14일" (an offer, with the days), and the
-- danger pay when there is one.
local function specialReward(o, p, withDays)
    local runs
    if withDays then
        runs = runsOf("text", "IGUI_OA_Story_UI_SpecialReward", Text.credits(o.credits), o.trust or 0, o.days or Rewards.SPECIAL_DAYS)
    else
        runs = runsOf("text", "IGUI_OA_Story_UI_Reward", Text.credits(o.credits), o.trust or 0)
    end
    for _, run in ipairs(runs) do
        if run.num then run.kind = "value" end
    end
    local far = o.far and math.floor(o.far * 100 + 0.5) or 0
    if far > 0 then
        runs = join(runs, plain("dim", getText("IGUI_OA_Story_UI_Dot")), runsOf("good", "IGUI_OA_Story_UI_Far", far))
    end
    local danger = o.danger and math.floor(o.danger * 100 + 0.5) or 0
    if danger > 0 then
        runs = join(runs, plain("dim", getText("IGUI_OA_Story_UI_Dot")), runsOf("warn", "IGUI_OA_Story_UI_Danger", danger))
    end
    return measure(runs, p)
end

-- The special request's slot: the locked board at the crude terminal; at the field terminal nothing yet, the next
-- offer's time, the two requests offered, or the one taken.
function OATabMission:buildSpecial(record, info)
    local p = self:palette()
    local c = self:character()
    local px, py = c:getX(), c:getY()
    local special = { head = getText("IGUI_OA_Story_UI_Special") }
    local slot = info.special
    if self.window.tier == "field" and slot and slot.state == "wait" then
        special.kind = "wait"
        special.runs = measure(timeRuns("dim", "IGUI_OA_Story_UI_SpecialNextIn", "IGUI_OA_Story_UI_SpecialNextInHours",
            slot.nextIn or 0), p)
    elseif self.window.tier == "field" and slot and slot.state == "offer" then
        special.kind = "offer"
        special.hint = getText("IGUI_OA_Story_UI_SpecialPick")
        special.options = {}
        for _, key in ipairs({ "a", "b" }) do
            local o = slot.options[key]
            special.options[key] = {
                title = getText("IGUI_OA_Story_SpecialTitle_" .. o.id),
                form = getText("IGUI_OA_Story_UI_SpecialForm_" .. o.form),
                where = Places.whereText(px, py, o.area.x, o.area.y),
                reward = specialReward(o, p, true),
            }
        end
        -- the first is chosen to begin with; a new offer starts again
        if self.pickSeq ~= slot.seq or not special.options[self.pick or ""] then self.pick, self.pickSeq = "a", slot.seq end
    elseif self.window.tier == "field" and slot and slot.state == "mission" then
        local m = slot.mission
        special.kind = "mission"
        special.title = getText("IGUI_OA_Story_SpecialTitle_" .. m.title)
        special.form = getText("IGUI_OA_Story_UI_SpecialForm_" .. m.form)
        if m.state == "sealed" then
            special.right = plain("text", getText("IGUI_OA_Story_UI_Sealed"))
        elseif m.state == "calling" then
            special.right = plain("text", getText("IGUI_OA_Story_UI_Calling"))
        else
            special.right = timeRuns("text", "IGUI_OA_Story_UI_Left", "IGUI_OA_Story_UI_LeftHours", m.left or 0)
        end
        measure(special.right, p)
        special.lines = {}
        if m.swap then special.lines[#special.lines + 1] = getText("IGUI_OA_Story_UI_Swap_" .. m.swap) end
        if m.field then special.lines[#special.lines + 1] = getText("IGUI_OA_Story_UI_Field_" .. m.field) end
        if m.form == "fetch" and m.state == "open" then
            special.lines[#special.lines + 1] = getText("IGUI_OA_Story_UI_Fetch")
        end
        if m.area and m.state ~= "sealed" then
            special.where = { label = getText("IGUI_OA_Story_UI_Where") .. " ", text = whereText(px, py, m.area) }
        end
        if m.request then
            special.link = { key = "r:" .. m.request, text = getText("IGUI_OA_Story_UI_SpecialCopy") }
        end
        special.reward = specialReward(m, p)
        special.hasArea = m.area ~= nil and m.state ~= "sealed"
    elseif self.window.tier ~= "field" then
        special.locked = true
        special.tag = getText("IGUI_OA_Story_UI_SpecialLocked")
        special.text = getText("IGUI_OA_Story_UI_SpecialLockedText")
        special.bullets = {}
        for _, form in ipairs({ "exchange", "fetch", "field", "choose" }) do
            special.bullets[#special.bullets + 1] = getText("IGUI_OA_Story_UI_SpecialBullet_" .. form)
        end
        local entry = OA.Shop and OA.Shop.entry("field_terminal")
        local price = entry and OA.Shop.price(entry, record) or 0
        special.cost = measure(runsOf("dim", "IGUI_OA_Story_UI_SpecialLockedCost", Text.credits(price)), p)
    else
        special.text = getText("IGUI_OA_Story_UI_SpecialNone")
    end
    return special
end

function OATabMission:refresh()
    local record = self:record()
    if not record then return end
    local info = {}
    if record.missions then info = Missions.describe(record) end
    self.info = info
    self.results = nil
    if info.results then
        self.results = measure(runsOf("dim", "IGUI_OA_Story_UI_Results", info.results.done or 0, info.results.expired or 0,
            info.results.lost or 0), self:palette())
    end
    self.card = info.id and self:buildCard(record, info) or self:buildEmpty(record, info)
    self.special = self:buildSpecial(record, info)
    self.laidW = nil
end

-- The results of the missions so far ("지금까지: 완료 3, 기한 경과 0, 분실 0"), drawn by the tab above in the row of the
-- sub-tabs, ending at x.
function OATabMission:drawResults(el, right, y)
    local list = self.results
    if list then drawRuns(el, right - list.w, y, list, self:palette()) end
end

-- Where everything goes, worked out when the size changes or the record does.
function OATabMission:layout()
    local card, p = self.card, self:palette()
    local w, h = self.width, self.height
    self.laidW, self.laidH = w, h
    self.small = h < OATabMission.SMALL_BELOW
    self.cardH = self.small and OATabMission.CARD_H_SMALL or OATabMission.CARD_H
    local cardH = self.cardH
    for _, b in ipairs(self:buttons()) do
        b:setVisible(false)
    end
    if card and not card.empty then
        local by = cardH - self.mapButton.height - 8
        local x = w - 12 - self.mapButton.width
        self.mapButton:setX(x)
        self.mapButton:setY(by)
        self.mapButton:setVisible(true)
        self.mapButton.enable = self.info.area ~= nil and self.info.state ~= "sealed"
        self.buttonsLeft = x
        if self.info.reroll then
            x = x - 8 - self.rerollButton.width
            self.rerollButton:setX(x)
            self.rerollButton:setY(by)
            self.rerollButton:setVisible(true)
            self.rerollButton.enable = (self.info.reroll.left or 0) > 0
            self.rerollButton.tooltip = getText("IGUI_OA_Story_UI_RerollTip", self.info.reroll.trust or 0)
            self.buttonsLeft = x
        end
        for _, option in ipairs({ "b", "a" }) do
            local label = card.options and card.options[option]
            if label then
                local b = self.optionButtons[option]
                b:setTitle(label)
                x = x - 8 - b.width
                b:setX(x)
                b:setY(by)
                b:setVisible(true)
                self.buttonsLeft = x
            end
        end
        -- the title and its badges, cut to what the deadline leaves
        local badgesW = 0
        for _, badge in ipairs(card.badges) do
            badge.w = UI.textWidth(badge.text) + 12
            badgesW = badgesW + badge.w + 6
        end
        card.titleText = UI.fit(card.title, w - 24 - card.right.w - 16 - badgesW, UIFont.Medium)
        card.titleW = UI.textWidth(card.titleText, UIFont.Medium)
        card.briefLines = wrapLines(card.brief, w - 24)
        card.hintText = card.hint and UI.fit(card.hint, w - 38) or nil
        card.lineFits = {}
        for i, text in ipairs(card.lines) do card.lineFits[i] = UI.fit(text, w - 24) end
        for _, where in ipairs(card.where) do
            where.labelW = UI.textWidth(where.label)
            where.fit = UI.fit(where.text, w - 24 - where.labelW)
        end
    end
    local sy = cardH + 8
    local sh = h - sy
    self.slot = { y = sy, h = sh }
    local special = self.special
    local fh = UI.fontHeight()
    if special and special.kind == "offer" then
        local b = self.acceptButton
        b:setX(w - 12 - b.width)
        b:setY(sy + sh - b.height - 4)
        b:setVisible(true)
        special.hintFit = UI.fit(special.hint, w - 24 - UI.textWidth(special.head) - 12)
        -- two cells side by side: a radio, the title, the form (dim) and the place
        local cw = math.floor((w - 36) / 2)
        special.cells = {}
        for i, key in ipairs({ "a", "b" }) do
            special.cells[key] = { x = 12 + (i - 1) * (cw + 12), y = sy + 26, w = cw, h = 3 * fh + 10 }
            local o = special.options[key]
            o.titleFit = UI.fit(o.title, cw - 32)
            o.formFit = UI.fit(o.form, cw - 32)
            o.whereFit = UI.fit(o.where, cw - 32)
        end
    elseif special and special.kind == "mission" then
        local b = self.specialMapButton
        b:setX(w - 12 - b.width)
        b:setY(sy + sh - b.height - 4)
        b:setVisible(true)
        b.enable = special.hasArea
        local mh = UI.fontHeight(UIFont.Medium)
        special.titleFit = UI.fit(special.title, w - 24 - special.right.w - UI.textWidth(special.head) - 24, UIFont.Medium)
        special.mh = mh
        special.formFit = UI.fit(special.form, w - 24)
        special.lineFits = {}
        for i, text in ipairs(special.lines) do special.lineFits[i] = UI.fit(text, w - 24) end
        if special.where then special.where.labelW = UI.textWidth(special.where.label) end
        if special.where then special.where.fit = UI.fit(special.where.text, w - 24 - special.where.labelW) end
        if special.link then special.link.w = UI.textWidth(special.link.text) end
    elseif special and special.locked then
        local b = self.shopButton
        b:setX(w - 12 - b.width)
        b:setY(sy + sh - b.height - 4)
        b:setVisible(true)
        special.textLines = wrapLines(special.text, w - 24)
        special.tagX = 26 + UI.textWidth(special.head) + 10
        special.bulletFits = {}
        for i, text in ipairs(special.bullets) do special.bulletFits[i] = UI.fit(text, w - 36) end
    end
end

-- Drawing -----------------------------------------------------------------------------------------------------------

function OATabMission:drawCard(p)
    local card = self.card
    local w, cardH = self.width, self.cardH
    panel(self, p, 0, 0, w, cardH)
    if card.empty then
        UI.textCentre(self, card.head, w / 2, cardH / 2 - 26, p.text, UIFont.Medium)
        local x = (w - card.sub.w) / 2
        drawRuns(self, x, cardH / 2 + 4, card.sub, p)
        return
    end
    local fh = UI.fontHeight()
    local c = card.colour
    UI.fill(self, 0, 0, 3, cardH, c, 0.9)
    UI.text(self, card.titleText, 12, 4, p.bright, UIFont.Medium)
    local bx = 12 + card.titleW + 8
    for _, badge in ipairs(card.badges) do
        UI.fill(self, bx, 8, badge.w, fh, badge.colour, 0.85)
        UI.textCentre(self, badge.text, bx + badge.w / 2, 8, p.dark)
        bx = bx + badge.w + 6
    end
    drawRuns(self, w - 12 - card.right.w, 7, card.right, p)
    local yy = 32
    for _, text in ipairs(card.briefLines) do
        UI.text(self, text, 12, yy, p.text)
        yy = yy + fh
    end
    yy = yy + 6
    local bonusRows = card.bonus and 1 or 0
    local low = cardH - 36 - 18 * bonusRows
    if card.item then
        UI.icon(self, OA.Trade.Draw.itemTexture(card.item.type, UI.px(24)), 12, yy, 24, 1, p.iconTint)
        drawRuns(self, 42, yy + 4, card.item.runs, p)
        yy = yy + 28
    end
    -- What is at the place comes after the brief; the lines of conditions give way before the position does.
    local whereH = #card.where * (fh + 2)
    for _, text in ipairs(card.lineFits) do
        if yy + fh + 2 + whereH <= low then
            UI.text(self, text, 12, yy, p.warn)
            yy = yy + fh
        end
    end
    yy = yy + 2
    for _, where in ipairs(card.where) do
        if yy + fh <= low then
            UI.text(self, where.label, 12, yy, p.dim)
            UI.text(self, where.fit, 12 + where.labelW, yy, p.text)
        end
        yy = yy + fh + 2
    end
    if card.hintText and yy + fh < low then
        UI.fill(self, 12, yy + 5, 8, 6, c, 0.9)
        UI.text(self, card.hintText, 26, yy, p.dim)
    end
    if card.bonus then drawRuns(self, 12, cardH - 48, card.bonus, p) end
    if card.reward then drawRuns(self, 12, cardH - 30, card.reward, p) end
end

function OATabMission:drawSpecial(p)
    local special, slot = self.special, self.slot
    local w, h = self.width, slot.h
    local y0 = slot.y
    panel(self, p, 0, y0, w, h)
    if special.locked then
        UI.lock(self, 12, y0 + 9, p.warn)
        UI.text(self, special.head, 26, y0 + 6, p.head)
        UI.text(self, special.tag, special.tagX, y0 + 6, p.warn)
        local fh = UI.fontHeight()
        local yy = y0 + 26
        for _, text in ipairs(special.textLines) do
            UI.text(self, text, 12, yy, p.text)
            yy = yy + fh
        end
        yy = yy + 4
        for _, text in ipairs(special.bulletFits) do
            if yy + fh <= y0 + h - 30 then
                UI.fill(self, 14, yy + 5, 4, 4, p.dim)
                UI.text(self, text, 24, yy, p.dim)
            end
            yy = yy + fh
        end
        drawRuns(self, 12, y0 + h - 26, special.cost, p)
    elseif special.kind == "offer" then
        self:drawOffer(p, special, y0, h)
    elseif special.kind == "mission" then
        self:drawMission(p, special, y0, h)
    elseif special.kind == "wait" then
        UI.text(self, special.head, 12, y0 + 6, p.head)
        drawRuns(self, 12, y0 + 26, special.runs, p)
    else
        UI.text(self, special.head, 12, y0 + 6, p.head)
        UI.text(self, special.text, 12, y0 + 26, p.dim)
    end
end

-- A disc of radius r from rows of rectangles (the radio buttons).
local function disc(el, cx, cy, r, c, a)
    for dy = -r, r do
        local half = math.floor(math.sqrt(r * r + 0.5 - dy * dy))
        UI.fill(el, cx - half, cy + dy, 2 * half + 1, 1, c, a)
    end
end

-- The two requests offered: a radio cell each, the picked one framed, and its reward under them.
function OATabMission:drawOffer(p, special, y0, h)
    local w = self.width
    local fh = UI.fontHeight()
    UI.text(self, special.head, 12, y0 + 6, p.head)
    UI.text(self, special.hintFit, w - 12 - UI.textWidth(special.hintFit), y0 + 6, p.dim)
    for _, key in ipairs({ "a", "b" }) do
        local cell, o = special.cells[key], special.options[key]
        local on = self.pick == key
        if on then UI.fill(self, cell.x, cell.y, cell.w, cell.h, p.sel, 0.12) end
        UI.frame(self, cell.x, cell.y, cell.w, cell.h, on and p.sel or p.border, on and 0.9 or 1)
        disc(self, cell.x + 11, cell.y + 3 + math.floor(fh / 2), 5, on and p.sel or p.dim)
        disc(self, cell.x + 11, cell.y + 3 + math.floor(fh / 2), 3, p.dark)
        if on then disc(self, cell.x + 11, cell.y + 3 + math.floor(fh / 2), 2, p.sel) end
        UI.text(self, o.titleFit, cell.x + 24, cell.y + 3, p.bright)
        UI.text(self, o.formFit, cell.x + 24, cell.y + 3 + fh, p.dim)
        UI.text(self, o.whereFit, cell.x + 24, cell.y + 3 + 2 * fh, p.text)
    end
    local picked = special.options[self.pick or "a"]
    if picked then drawRuns(self, 12, y0 + h - 24, picked.reward, p) end
end

-- The request taken: its title and form, what is asked now, where, the link to the staff's request copy, the reward.
function OATabMission:drawMission(p, special, y0, h)
    local w = self.width
    local fh = UI.fontHeight()
    UI.text(self, special.head, 12, y0 + 6, p.head)
    drawRuns(self, w - 12 - special.right.w, y0 + 7, special.right, p)
    local yy = y0 + 22
    UI.text(self, special.titleFit, 12, yy, p.bright, UIFont.Medium)
    yy = yy + special.mh + 1
    UI.text(self, special.formFit, 12, yy, p.dim)
    yy = yy + fh + 4
    local limit = y0 + h - 28
    for _, text in ipairs(special.lineFits) do
        if yy + fh <= limit then UI.text(self, text, 12, yy, p.warn) end
        yy = yy + fh
    end
    local where = special.where
    if where and yy + fh <= limit then
        UI.text(self, where.label, 12, yy, p.dim)
        UI.text(self, where.fit, 12 + where.labelW, yy, p.text)
    end
    if where then yy = yy + fh + 2 end
    special.linkRect = nil
    if special.link and yy + fh <= limit then
        UI.text(self, special.link.text, 12, yy, p.sel)
        UI.fill(self, 12, yy + fh - 1, special.link.w, 1, p.sel, 0.6)
        special.linkRect = { x = 12, y = yy, w = special.link.w, h = fh }
    end
    drawRuns(self, 12, y0 + h - 24, special.reward, p)
end

function OATabMission:prerender()
    if not (self.card and self.special) then return end
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    local p = self:palette()
    self:drawCard(p)
    self:drawSpecial(p)
end

return OATabMission
