-- The status tab's record screen (DESIGN-terminal 2.5): the codex by category on the left (kinds found, each house
-- loot category's bar with its 50% and 90% marks and the bonus it waits for), and on the right the building sweep,
-- the kills and the missions, each with the next milestone. The same on both terminals. Worked out when the record
-- changes (Codex.summary, Codex.categoryProgress through Trade/StatusModel).
require "OperationAcorn/Trade/StatusDraw"
require "OperationAcorn/Trade/StatusModel"
local OA = OperationAcorn
local Trade = OA.Trade
local Draw, M = Trade.Draw, Trade.StatusModel

OATabRecords = OAStatusView:derive("OATabRecords")

function OATabRecords:model(record)
    return M.records(record)
end

function OATabRecords:build(L, w, h)
    local d, p, fh, nf = self.data, L.p, L.fh, L.p.numberFont
    local lw = math.floor(w * 0.58)
    local rw = w - lw - 8
    local bar = p.panel and p.value or p.sel
    -- The codex.
    Draw.panel(L, 0, 0, lw, h)
    local headW = Draw.text(L, getText("IGUI_OA_Status_Rec_Codex"), 10, 6, p.head)
    Draw.run(L, Draw.styled(L, d.kinds, p.dim, p.text), 20 + headW, 6, lw - 30 - headW, "right")
    if d.kindsBonus then
        Draw.run(L, Draw.styled(L, d.kindsBonus, p.dim, p.text, { [1] = { p.text, UIFont.Small } }), 10, 22, lw - 20)
    end
    local rh = M.recordRowHeight(h)
    local yy = 44
    local nameW, barX, countW, nextW = 126, 130, 58, 80
    local barW = lw - barX - countW - nextW - 16
    for _, c in ipairs(d.cats) do
        Draw.fit(L, c.name, 10, yy, nameW - 4, p.text)
        Draw.progress(L, barX, yy + 5, barW, 6, c.frac, bar)
        for _, t in ipairs(OA.Codex.CATEGORY_STEPS) do Draw.rect(L, barX + math.floor(barW * t), yy + 2, 1, 12, p.text, 0.7) end
        Draw.textRight(L, c.count, barX + barW + 6 + countW, yy, p.text, nf)
        Draw.fit(L, c.nextText, lw - nextW - 10, yy, nextW, p.dim, nil, 1, "right")
        yy = yy + rh
    end
    -- The sweep, the kills, the missions.
    local rx = lw + 8
    local blocks = {
        { getText("IGUI_OA_Status_Rec_Sweep"), d.buildings, p.text },
        { getText("IGUI_OA_Status_Rec_Kills"), d.kills, p.text },
        { getText("IGUI_OA_Status_Rec_Missions"), d.missions, p.dim },
    }
    local bh = math.floor((h - 16) / 3)
    for i, b in ipairs(blocks) do
        local by = (i - 1) * (bh + 8)
        local B = b[2]
        Draw.panel(L, rx, by, rw, bh)
        local hw = Draw.text(L, b[1], rx + 10, by + 6, p.head)
        Draw.run(L, Draw.styled(L, B.big, b[3], p.text), rx + 20 + hw, by + 4, rw - 30 - hw, "right")
        local ly = by + 28
        if B.bar then
            Draw.progress(L, rx + 10, ly + 4, rw - 20, 6, B.bar, bar)
            ly = ly + 16
        end
        for _, line in ipairs(B.lines) do
            Draw.run(L, Draw.styled(L, line, p.dim, p.text), rx + 10, ly, rw - 20)
            ly = ly + fh
        end
    end
end
