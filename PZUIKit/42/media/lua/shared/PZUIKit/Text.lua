-- Text that fits: the one cut and the one wrap a mod's windows share. Plain functions over a caller's measure, so they
-- are tested outside the game and run on a server too. `measure(string, arg)` is the caller's width (design units,
-- pixels, characters); `arg` is passed on to it (a font).
PZUIKit = PZUIKit or {}
local Text = {}
PZUIKit.Text = Text

-- The start of `text` (at least one character) that, with "..." after it, is no wider than width + eps.
function Text.cutFor(text, width, measure, eps, arg)
    width = width + (eps or 0)
    local cut = text
    while #cut > 1 and measure(cut .. "...", arg) > width do
        cut = string.sub(cut, 1, #cut - 1)
    end
    return cut
end

-- The text whole when it is no wider than width + eps, else cut with "..." at the end.
function Text.fitText(text, width, measure, eps, arg)
    if measure(text, arg) <= width + (eps or 0) then return text end
    return Text.cutFor(text, width, measure, eps, arg) .. "..."
end

-- A text broken into lines no wider than `limit` (+ opts.eps) at its spaces. opts (all optional):
--   paragraphs: "\n" ends a line, a blank paragraph is an empty line (else the line ends are spaces);
--   breakWords: a word wider than a line is cut between letters (else it stays whole on a line of its own);
--   maxLines: at most that many lines, the last ending in "..." where text was left.
function Text.wrap(text, limit, measure, opts, arg)
    local eps = opts and opts.eps or 0
    local paragraphs = opts and opts.paragraphs
    local breakWords = opts and opts.breakWords
    local max = limit + eps
    local lines = {}
    -- a word wider than a line cut between letters: the lines it fills, and what is left of it
    local function cutWord(word)
        while #word > 1 and measure(word, arg) > max do
            local k = #word - 1
            while k > 1 and measure(string.sub(word, 1, k), arg) > max do k = k - 1 end
            lines[#lines + 1] = string.sub(word, 1, k)
            word = string.sub(word, k + 1)
        end
        return word
    end
    local function paragraph(para)
        local line
        for word in string.gmatch(para, "%S+") do
            local longer = line and (line .. " " .. word) or word
            if line and measure(longer, arg) > max then
                lines[#lines + 1] = line
                line = breakWords and cutWord(word) or word
            elseif line == nil and breakWords then
                line = cutWord(word)
            else
                line = longer
            end
        end
        if line ~= nil then
            lines[#lines + 1] = line
        elseif paragraphs then
            lines[#lines + 1] = ""
        end
    end
    text = text or ""
    if paragraphs then
        for para in string.gmatch(text .. "\n", "(.-)\n") do paragraph(para) end
    else
        paragraph(text)
    end
    local most = opts and opts.maxLines
    if most and #lines > most then
        while #lines > most do table.remove(lines) end
        lines[#lines] = Text.cutFor(lines[#lines], limit, measure, 0, arg) .. "..."
    end
    return lines
end

return Text
