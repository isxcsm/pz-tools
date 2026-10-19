-- The window's manual tab: the chapters of the box's instruction plate (BU.Manual) down the left, one not read yet
-- marked, and the chapter open beside them. A chapter is printed a row at a time the first time it is read, as
-- Operation Acorn's terminal prints its papers (the kit's PZUITypedText, four rows a second), and a click brings it to
-- its end; a chapter read before shows whole at once. A first reading left half way goes on where it was left. The
-- tab is marked while a chapter is new (ISBUTabs:setDot). A chapter that teaches recipes (Manual.teaches) has a
-- button for each under its text: learn it, or that it is known.
require "ISUI/ISPanel"
require "PZUIKit/UI"
require "PZUIKit/TypedText"
require "PZUIKit/Markup"
require "PZUIKit/Typing"
require "BuildingUtilities/Manual"
require "BuildingUtilities/PanelUi"
require "BuildingUtilities/Sounds"
local BU = BuildingUtilities
local Manual, Ui = BU.Manual, BU.PanelUi
local UI, P, ROW, PAD = Ui.UI, Ui.PALETTE, Ui.ROW, Ui.PAD
local Markup, Typing = PZUIKit.Markup, PZUIKit.Typing

ISBUManual = ISPanel:derive("ISBUManual")

-- The chapters' column (design units).
ISBUManual.CHAPTER_W = 120

function ISBUManual:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.background = false
    o.window = window
    o.utility = Ui.MANUAL
    o.chapters, o.titles = {}, {}
    return o
end

function ISBUManual:createChildren()
    local body = UI.rich(self, ISBUManual.CHAPTER_W + PAD, 0, 100, 100, PZUITypedText)
    body.target, body.onFinished = self, ISBUManual.onPrinted
    body.cursorColor = P.value
    body.sounds = { row = "bu.manual.row" }
    body.background = false
    body.palette = P
    body.marginLeft, body.marginRight, body.marginTop, body.marginBottom = 2, 6, 6, 6
    self.body = body
    self:layout()
end

-- The text beside the chapters, as the tab's size changes, over the recipes' buttons of the chapter open.
function ISBUManual:layout()
    local buttons = self:recipeButtons()
    local strip = #buttons > 0 and self.height - buttons[1].y + PAD or 0
    if self.laidW == self.width and self.laidH == self.height and self.laidStrip == strip then return end
    self.laidW, self.laidH, self.laidStrip = self.width, self.height, strip
    local x = ISBUManual.CHAPTER_W + PAD
    UI.place(self.body, x, 0, math.max(10, self.width - x), math.max(10, self.height - strip))
end

-- The recipes the chapter open teaches at this box.
function ISBUManual:taught() return self.key and Manual.teaches(self.window.panel, self.key) or {} end

-- Each recipe's button under the text: { taught, x, y, w, text, known }, in rows that wrap at the tab's width (the
-- last row at the bottom). Kept for the frames: made again when a chapter opens (show), the window refreshes
-- (refresh: a change told), the character learns one, the tab's size changes, and what the character knows each
-- KNOWN_MS. Not to be changed by a caller.
local KNOWN_MS = 1000

function ISBUManual:recipeButtons()
    local now = getTimestampMs()
    local kept = self.buttons
    if kept and not self.buttonsStale and self.buttonsW == self.width and self.buttonsH == self.height
            and now >= self.buttonsAt and now - self.buttonsAt < KNOWN_MS then
        return kept
    end
    kept = self:makeRecipeButtons()
    self.buttons, self.buttonsStale = kept, false
    self.buttonsW, self.buttonsH, self.buttonsAt = self.width, self.height, now
    return kept
end

function ISBUManual:makeRecipeButtons()
    local result, character = {}, self:character()
    local left = ISBUManual.CHAPTER_W + PAD * 2
    local x, row = left, 0
    for _, taught in ipairs(self:taught()) do
        local name = getItemNameFromFullType(taught.item)
        local known = character:isRecipeKnown(taught.recipe)
        local text = getText(known and "IGUI_BU_Manual_Known" or "IGUI_BU_Manual_Learn", name)
        local w = UI.textWidth(text) + 16
        if x > left and x + w > self.width - PAD then x, row = left, row + 1 end
        result[#result + 1] = { taught = taught, x = x, row = row, w = w, text = text, known = known }
        x = x + w + PAD
    end
    for _, button in ipairs(result) do button.y = self.height - (row - button.row + 1) * ROW - PAD end
    return result
end

function ISBUManual:character() return self.window.playerObj end

-- The chapters the box offers the character now (the window's refresh): the open one stays, else the first new one
-- opens (the first one when none is); the tab's mark follows.
function ISBUManual:refresh(panel)
    local character = self:character()
    self.chapters = Manual.chapters(panel, character)
    self.buttonsStale = true
    local open, first = nil, nil
    for _, key in ipairs(self.chapters) do
        self.titles[key] = self.titles[key] or Manual.title(key)
        if key == self.key then open = key end
        if not first and Manual.isNew(character, key) then first = key end
    end
    if not open and #self.chapters > 0 then self:show(first or self.chapters[1]) end
    self:mark()
end

function ISBUManual:mark()
    local tabs = self.window.tabs
    if tabs then tabs:setDot(self, Manual.anyNew(self.window.panel, self:character())) end
end

-- Opens a chapter: printed while it is new, whole once read.
function ISBUManual:show(key)
    self:leave()
    self.key = key
    self.buttonsStale = true
    local character = self:character()
    local marked, styles = Typing.marks(Manual.text(key))
    local read = Markup.parse(marked)
    local state = Manual.state(character, key)
    local run = nil
    if read and state ~= true then
        -- a click brings it to its end (all of it counts as seen), not only as far as before
        run = { key = key, parse = read, step = Typing.LINE_STEP, clock = type(state) == "table" and tonumber(state.t) or 0,
            seen = read.n, done = false }
    end
    self.body.run = run
    self.body.text = Typing.rich(read or { plain = marked, runs = {} }, P.text, styles, { head = P.head, dim = P.dim })
    self.body:paginate()
    self.body:setYScroll(0)
end

-- The chapter was printed to its end: read.
function ISBUManual.onPrinted(self, run)
    Manual.keep(self:character(), run.key, true)
    self:mark()
end

-- The chapter open is left half way (another opens, the window closes): its reading goes on from there next time. One
-- that was never drawn keeps nothing.
function ISBUManual:leave()
    local run = self.body and self.body.run
    if run and not run.done and run.last then Manual.keep(self:character(), run.key, false, run.clock) end
    if self.body then self.body.run = nil end
end

function ISBUManual:prerender()
    self:layout()
    local w, fh = ISBUManual.CHAPTER_W, UI.fontHeight()
    local mx, my = -1, -1
    if self:isMouseOver() then mx, my = self:getMouseX(), self:getMouseY() end
    UI.fill(self, 0, 0, w, self.height, P.panel)
    -- The text's side as the other tabs' lists: the world does not show through it.
    UI.fill(self, w, 0, self.width - w, self.height, P.inset, 0.9)
    local character = self:character()
    for index, key in ipairs(self.chapters) do
        local y = (index - 1) * ROW
        local on = key == self.key
        local k = UI.hoverLight(self, key, not on and mx >= 0 and mx < w and my >= y and my < y + ROW)
        if on then
            UI.fill(self, 0, y, w, ROW, P.sel, 0.2)
            UI.fill(self, 0, y, 2, ROW, P.value)
        elseif k > 0 then
            UI.fill(self, 0, y, w, ROW, P.sel, 0.1 * k)
        end
        local f = UI.flashLevel(self, key)
        if f > 0 then UI.fill(self, 0, y, w, ROW, P.sel, 0.3 * f) end
        UI.text(self, self.titles[key] or key, 10, y + (ROW - fh) / 2, on and P.bright or P.text)
        if Manual.isNew(character, key) then UI.fill(self, w - 10, y + (ROW - 4) / 2, 4, 4, P.warn) end
    end
    UI.fill(self, w, 0, 1, self.height, P.border)
    -- The recipes' buttons: one known is a note, not a button.
    for _, button in ipairs(self:recipeButtons()) do
        local h = ROW - 4
        if button.known then
            UI.text(self, button.text, button.x, button.y + (h - fh) / 2, P.dim)
        else
            local over = mx >= button.x and mx < button.x + button.w and my >= button.y and my < button.y + h
            local k = UI.hoverLight(self, "learn" .. button.taught.recipe, over)
            local f = UI.flashLevel(self, "learn" .. button.taught.recipe)
            UI.fill(self, button.x, button.y, button.w, h, P.panel, 0.8)
            if k > 0 or f > 0 then UI.fill(self, button.x, button.y, button.w, h, P.bright, 0.1 * k + 0.25 * f) end
            UI.frame(self, button.x, button.y, button.w, h, k > 0.5 and P.value or P.border)
            UI.textCentre(self, button.text, button.x + button.w / 2, button.y + (h - fh) / 2, k > 0.5 and P.bright or P.text)
        end
    end
end

function ISBUManual:onMouseDown(x, y)
    for _, button in ipairs(self:recipeButtons()) do
        if not button.known and x >= button.x and x < button.x + button.w and y >= button.y and y < button.y + ROW - 4 then
            UI.flash(self, "learn" .. button.taught.recipe, "kit.press")
            self.buttonsStale = true
            BU.Sync.send(self:character(), "learnRecipe",
                { panel = self.window.panel.id, chapter = self.key, recipe = button.taught.recipe })
            return true
        end
    end
    if x >= ISBUManual.CHAPTER_W then return false end
    local key = self.chapters[math.floor(y / ROW) + 1]
    if key and key ~= self.key then
        UI.flash(self, key)
        self:show(key)
    end
    return true
end

UI.scaled(ISBUManual, ISPanel)

return ISBUManual
