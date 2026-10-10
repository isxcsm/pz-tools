-- The missions tab's mission screen (DESIGN-terminal 6.1, 6.2): the mission card, a card of its own under a colour band
-- (the colour is the map's: teal for the regular and contract missions, sky blue for the story's), with what is
-- asked, where from here, until when and what it pays; and under it the special request's slot, a locked board at
-- the crude terminal. Everything is worked out when the record changes or the player has walked (`refresh`); the
-- frames only draw it (`prerender`).
require "OperationAcorn/Trade/TerminalWindow"
require "OperationAcorn/Story/Button"
require "OperationAcorn/Story/Data"
require "OperationAcorn/Story/Places"
require "OperationAcorn/Story/Rewards"
require "OperationAcorn/Story/Missions"
require "OperationAcorn/Story/View"
require "OperationAcorn/Economy/Shop"
local OA = OperationAcorn
local UI, Text = OA.Trade.UI, OA.Trade.Text
local Data, Places, Rewards, Missions = OA.StoryData, OA.Places, OA.Rewards, OA.Missions

OATabMission = OATab:derive("OATabMission")

-- The card's height, and the height of the screen (the body under the sub-tabs) under which it is the small one.
OATabMission.CARD_H, OATabMission.CARD_H_SMALL, OATabMission.SMALL_BELOW = 196, 172, 350


-- Text with its numbers apart ---------------------------------------------------------------------------------------
-- The crude terminal draws numbers in the Code font, which has no Hangul, so a line with both is drawn in runs. The
-- numbers are wrapped in two control characters before the text is made and cut out again: the translation keeps its
-- one natural sentence.
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
local function wrapLines(text, width)
    local lines = {}
    local line = ""
    for word in string.gmatch(text, "%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if UI.textWidth(try) <= width then
            line = try
        else
            if line ~= "" then lines[#lines + 1] = line end
            line = word
            while UI.textWidth(line) > width and #line > 1 do
                local cut = #line
                while cut > 1 and UI.textWidth(string.sub(line, 1, cut)) > width do cut = cut - 1 end
                lines[#lines + 1] = string.sub(line, 1, cut)
                line = string.sub(line, cut + 1)
            end
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
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
    self.mapButton = OAMButton:new(0, 0, 120, bh, getText("IGUI_OA_Story_UI_ShowMap"), p, self, OATabMission.onMap, "strong")
    self.rerollButton = OAMButton:new(0, 0, 88, bh, getText("IGUI_OA_Story_UI_Reroll"), p, self, OATabMission.onReroll)
    self.optionButtons = {}
    for _, option in ipairs({ "a", "b" }) do
        local b = OAMButton:new(0, 0, 170, bh, "", p, self, OATabMission.onChoose)
        b.internal = option
        self.optionButtons[option] = b
    end
    self.shopButton = OAMButton:new(0, 0, 120, bh - 4, getText("IGUI_OA_Story_UI_ShowInShop"), p, self, OATabMission.onShop)
    for _, b in ipairs({ self.mapButton, self.rerollButton, self.optionButtons.a, self.optionButtons.b, self.shopButton }) do
        b:initialise()
        b:instantiate()
        b:setVisible(false)
        self:addChild(b)
    end
end

function OATabMission:onMap()
    local info = self.info
    if info and info.area then OA.StoryTabs.showOnMap(self:character()) end
end

function OATabMission:onChoose(button)
    self:send("story_choose", { option = button.internal })
end

function OATabMission:onReroll()
    self:send("story_reroll", {})
end

function OATabMission:onShop()
    self.window:showShopEntry("field_terminal")
end

-- What the screen shows -------------------------------------------------------------------------------------------

-- The time left as runs: "남은 기한 8일 6시간", or the hours alone under a day.
local function timeRuns(kind, dayKey, hourKey, hours)
    hours = math.max(0, hours)
    local days = math.floor(hours / 24)
    if days > 0 then return runsOf(kind, dayKey, days, math.floor(hours - days * 24)) end
    return runsOf(kind, hourKey, math.max(1, math.ceil(hours)))
end

-- The texture of a mission's item (its script's icon), or nil.
local function itemTexture(name)
    local script = getScriptManager():FindItem(Data.fullType(name))
    return script and script:getNormalTexture() or nil
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
    card.colour = OA.StoryView.color(card.kind)
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
    local place = info.place and getText("IGUI_OA_Story_Place_" .. info.place) or ""
    card.brief = getText(briefKey, place, OA.Story.number(record))
    if info.item and info.state ~= "offer" then
        card.item = { tex = itemTexture(info.item),
            runs = join(plain("dim", getText("IGUI_OA_Story_UI_ItemLabel") .. " "), plain("text", getItemNameFromFullType(Data.fullType(info.item)))) }
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
    -- The reward, with what it is made of when the base is known: danger pay and the streak, on the credits only.
    local danger = info.danger and math.floor(info.danger * 100 + 0.5) or 0
    local streak = info.streak or 0
    if info.base and (danger > 0 or streak > 0) then
        local dot = getText("IGUI_OA_Story_UI_Dot")
        local bonus = runsOf("dim", "IGUI_OA_Story_UI_Base", Text.credits(info.base))
        if danger > 0 then
            bonus = join(bonus, plain("dim", dot), runsOf("warn", "IGUI_OA_Story_UI_Danger", danger))
        end
        if streak > 0 then
            bonus = join(bonus, plain("dim", dot),
                runsOf("good", "IGUI_OA_Story_UI_Streak", streak, math.floor(Rewards.streakBonus(streak) * 100 + 0.5)))
        end
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

-- The special request's slot: the locked board at the crude terminal, the empty slot at the field terminal (the
-- special request's own screens are the special-request unit's).
function OATabMission:buildSpecial(record, info)
    local p = self:palette()
    local special = { head = getText("IGUI_OA_Story_UI_Special") }
    if self.window.tier ~= "field" then
        special.locked = true
        special.tag = getText("IGUI_OA_Story_UI_SpecialLocked")
        special.text = getText("IGUI_OA_Story_UI_SpecialLockedText")
        special.bullets = {}
        for _, form in ipairs({ "exchange", "fetch", "field", "choose" }) do
            special.bullets[#special.bullets + 1] = getText("IGUI_OA_Story_UI_SpecialBullet_" .. form)
        end
        local entry = OA.Shop and OA.Shop.entry("field_terminal")
        special.cost = measure(runsOf("dim", "IGUI_OA_Story_UI_SpecialLockedCost", Text.credits(entry and entry.price or 50000)), p)
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
    for _, b in ipairs({ self.mapButton, self.rerollButton, self.optionButtons.a, self.optionButtons.b, self.shopButton }) do
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
    if special and special.locked then
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
        if card.item.tex then
            self:drawTextureScaledAspect(card.item.tex, 12, yy, 24, 24, 1, p.iconTint and p.iconTint[1] or 1,
                p.iconTint and p.iconTint[2] or 1, p.iconTint and p.iconTint[3] or 1)
        end
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
    else
        UI.text(self, special.head, 12, y0 + 6, p.head)
        UI.text(self, special.text, 12, y0 + 26, p.dim)
    end
end

function OATabMission:prerender()
    if not (self.card and self.special) then return end
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    local p = self:palette()
    self:drawCard(p)
    self:drawSpecial(p)
end

return OATabMission
