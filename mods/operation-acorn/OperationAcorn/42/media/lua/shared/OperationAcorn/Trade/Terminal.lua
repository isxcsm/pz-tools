-- The communication terminal's tabs (DESIGN-terminal 1.1): always the same five, status, shop, delivery, missions and
-- comms (the team's calls, SCENES.md 2), in that order. The window itself is the client's
-- (client/OperationAcorn/Trade/TerminalWindow.lua); the part that owns a tab gives its view here with addTab, from its
-- own files, before or after the window exists.
require "OperationAcorn/Core"
local OA = OperationAcorn
local Terminal = OA.Terminal or {}
OA.Terminal = Terminal

Terminal.ORDER = { "status", "shop", "delivery", "missions", "comms" }

-- What a tab's dot remembers as seen, in the record's ui.seen (DESIGN-terminal 1.1): numbers only. `road` is the status
-- tab's progress screen: the trust level whose entry it has shown (11.1).
Terminal.SEEN_KEYS = { mission = true, week = true, tier = true, docs = true, market = true, road = true }

local tabs = {}

-- Gives a tab its view. `id` is one of Terminal.ORDER (a second call replaces the first). `factory(x, y, width,
-- height, window)` returns the view (a panel; it may have `refresh(view)` for when the record changes). `opts`:
--   mark(record) -> nil | "new" | "bad": the dot by the tab's name (amber for something not seen yet, red for a
--     state to deal with);
--   seen(record, window) -> key, value, or a table { key = value, ... } for a tab with more than one thing to see:
--     what the window keeps as seen once the tab has been looked at (SEEN_KEYS keys); nil keeps nothing (a tab whose
--     news is seen on one of its screens asks the window which is on show, window:subOn(id));
--   opens(record) -> true: the window opens on this tab (a call waiting to play), not on the status tab.
-- A view may also have wantsKeys(), consumesKey(key) and onKey(key) (the window's keys while it is on show; a view
-- that starts taking keys turns the window's key events on itself), onTabLeave() (another
-- tab was chosen) and consoleOver() (the window's boot console is over).
function Terminal.addTab(id, factory, opts)
    tabs[id] = { id = id, factory = factory, mark = opts and opts.mark, seen = opts and opts.seen,
        opens = opts and opts.opens }
    return tabs[id]
end

function Terminal.tab(id)
    return tabs[id]
end

-- The tab a window opens on for a record: the first that asks to (a failing rule does not), else the status tab.
function Terminal.opening(record)
    if record then
        for _, id in ipairs(Terminal.ORDER) do
            local tab = tabs[id]
            if tab and tab.opens then
                local ok, yes = pcall(tab.opens, record)
                if ok and yes then return id end
            end
        end
    end
    return "status"
end

-- The tab's title key.
function Terminal.titleKey(id)
    return "IGUI_OA_Terminal_Tab_" .. id
end

-- A tab's dot for a record: nil, "new" or "bad". A failing rule shows none.
function Terminal.mark(id, record)
    local tab = tabs[id]
    if not (tab and tab.mark and record) then return nil end
    local ok, mark = pcall(tab.mark, record)
    if ok then return mark end
    return nil
end

-- What a tab keeps as seen for a record, as a list of { key, value } by key (none when the tab has no rule or the rule
-- fails).
function Terminal.seenPairs(id, record, window)
    local tab = tabs[id]
    local list = {}
    if not (tab and tab.seen and record) then return list end
    local ok, first, second = pcall(tab.seen, record, window)
    if not ok or first == nil then return list end
    if type(first) == "table" then
        for key, value in pairs(first) do list[#list + 1] = { key = key, value = value } end
        table.sort(list, function(a, b) return a.key < b.key end)
    else
        list[1] = { key = first, value = second }
    end
    return list
end

-- What a record has seen of a tab's dot (ui.seen), and keeping it (server side: the record is the server's).
function Terminal.seenValue(record, key)
    local ui = record and record.ui
    return ui and ui.seen and ui.seen[key] or nil
end

function Terminal.setSeen(record, key, value)
    if not Terminal.SEEN_KEYS[key] or type(value) ~= "number" then return false end
    record.ui = record.ui or {}
    record.ui.seen = record.ui.seen or {}
    record.ui.seen[key] = value
    return true
end

-- Forgets every tab (tests).
function Terminal.clear()
    tabs = {}
end

return Terminal
