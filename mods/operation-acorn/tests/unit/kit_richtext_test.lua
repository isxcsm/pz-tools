-- The kit's rich text panel (PZUIKit/RichText, PZUIRichText): the layout its paginate makes for a text at a width (the
-- rows, their places, their faces), the same as the one-token-at-a-time version it replaced; the layout made again when
-- the width changes, also while it is dragged (at most every PAGINATE_MS, and once more when it has settled); the
-- heights asked once a font in a render.
require "OperationAcorn/Core"

local now = 1000

-- The game's panel as far as the kit's files ask of it (derive, new), and fonts of fixed sizes: Small 16 high and 7
-- wide a letter, Medium 20 and 9, Large 24 and 11.
local FH = { Small = 16, Medium = 20, Large = 24, Massive = 32 }
local FW = { Small = 7, Medium = 9, Large = 11, Massive = 14 }
local heightCalls, measureLog

local function load()
    local panel = {}
    panel.derive = function(self)
        local d = setmetatable({}, { __index = self })
        d.__index = d
        return d
    end
    panel.new = function(self, x, y, w, h)
        return setmetatable({ x = x, y = y, width = w, height = h, drawn = {} }, self)
    end
    for _, name in ipairs({ "setStencilRect", "clearStencilRect", "repaintStencilRect", "drawRect" }) do
        panel[name] = function() end
    end
    panel.isVisible = function() return true end
    panel.initialise = function() end
    panel.instantiate = function(self) self.javaObject = { setConsumeMouseEvents = function() end, setX = function() end, setY = function() end,
            setWidth = function() end, setHeight = function() end } end
    panel.setAlwaysOnTop = function() end
    panel.addToUIManager = function(self) self.inUI = true end
    panel.removeFromUIManager = function(self) self.inUI = false end
    panel.setVisible = function(self, v) self.visible = v end
    panel.setWidth = function(self, w) self.width = w end
    panel.setHeight = function(self, h) self.height = h end
    panel.setX = function(self, v) self.x = v; self.moved = (self.moved or 0) + 1 end
    panel.setY = function(self, v) self.y = v; self.moved = (self.moved or 0) + 1 end
    panel.getWidth = function(self) return self.width end
    panel.getHeight = function(self) return self.height end
    panel.drawText = function(self, text) self.drawn[#self.drawn + 1] = text end
    panel.__index = panel
    ISPanel = panel
    UIFont = setmetatable({}, { __index = function(_, k) return k end })
    getTimestampMs = function() return now end
    heightCalls, measureLog = 0, {}
    now = 1000
    getTextManager = function()
        return {
            getFontHeight = function(_, f) heightCalls = heightCalls + 1; return FH[f] or 16 end,
            MeasureStringX = function(_, f, s)
                measureLog[s] = (measureLog[s] or 0) + 1
                return #tostring(s) * (FW[f] or 7)
            end,
        }
    end
    Events.OnPreUIDraw = { Add = function() end }
    local real = require
    require = function(name)
        if string.find(name, "^ISUI/") then return true end
        return real(name)
    end
    local ok, err = pcall(real, "PZUIKit/RichText")
    require = real
    if not ok then error(err, 0) end
    PZUIKit.UI.setScale(1, false)
    return PZUIRichText, PZUIKit.UI
end

local function panelOf(width, text)
    local P = load()
    local o = P:new(0, 0, width, 100)
    o:setText(text)
    o:paginate()
    return o
end

-- A layout as one string: every chunk with its place, face and side, and the content's height.
local function dump(p)
    local out = {}
    for c = 1, #p.lines do
        out[#out + 1] = string.format("%s|%s|%s|%s|%s", p.lines[c], p.lineX[c], p.lineY[c], p.cFont[c], p.cOrient[c])
    end
    out[#out + 1] = "H" .. p.contentH
    return table.concat(out, "\n")
end

local TEXTS = {
    "The quick brown fox jumps over the lazy dog and keeps running through the long field",
    "<H1> Title <TEXT> Body text that wraps around the panel width <LINE> second <BR> third <RGB:1,0,0> red words " ..
        "<POPRGB> more words here <CENTRE> centred line of text <LEFT> back",
    "line one\nline two is a bit longer than one\n\nline four",
    "short supercalifragilisticexpialidocious tail <HANG> bullet words that go on and on and on to wrap",
    "a &lt;b&gt; c <SIZE:large> big text <SIZE:medium> mid words <SPACE> x <SIZE:small> small <HALF> halved",
    "",
    "<LINE> <LINE> only commands <LINE>",
    "<H1>Tight title<LINE>no space after the command<RGB:0,1,0> green<POPRGB>  two  spaces   and  gaps  \n  trailing   ",
    "an unmatched <b c> pair and a lone > sign and a < sign, then <PUSHRGB:1,1,0> pushed <PUSHRGB:0,1,1> deeper " ..
        "<POPRGB> up <POPRGB> out <POPRGB> done",
    string.rep("alpha beta gamma <RGB:1,0,0>delta<POPRGB> epsilon zeta eta theta\niota kappa <LINE> lambda mu nu xi " ..
        "omicron pi rho <BR> ", 12),
}


local EXPECTED = [==[
DUMP 1 90
The|0|0|Small|left
quick|0|16|Small|left
brown|0|32|Small|left
fox|0|48|Small|left
jumps|0|64|Small|left
over the|0|80|Small|left
lazy dog|0|96|Small|left
and|0|112|Small|left
keeps|0|128|Small|left
running|0|144|Small|left
through|0|160|Small|left
the long|0|176|Small|left
field|0|192|Small|left
H220
DUMP 1 160
The quick brown|0|0|Small|left
fox jumps over the|0|16|Small|left
lazy dog and keeps|0|32|Small|left
running through|0|48|Small|left
the long field|0|64|Small|left
H92
DUMP 1 300
The quick brown fox jumps over the|0|0|Small|left
lazy dog and keeps running through the|0|16|Small|left
long field|0|32|Small|left
H60
DUMP 2 90
|0|0|Small|left
Title|0|0|Large|centre
Body|0|16|Small|left
text|0|32|Small|left
that|0|48|Small|left
wraps|0|64|Small|left
around|0|80|Small|left
the|0|96|Small|left
panel|0|112|Small|left
width|0|128|Small|left
second|0|144|Small|left
third|0|176|Small|left
red|35|176|Small|left
words|0|192|Small|left
more|0|208|Small|left
words|0|224|Small|left
here|0|240|Small|left
centred|0|256|Small|centre
line of|0|272|Small|centre
text|0|288|Small|centre
back|28|288|Small|left
H316
DUMP 2 160
|0|0|Small|left
Title|0|0|Large|centre
Body text|55|0|Small|left
that wraps around|0|16|Small|left
the panel width|0|32|Small|left
second|0|48|Small|left
third|0|80|Small|left
red words|35|80|Small|left
more|98|80|Small|left
words here|0|96|Small|left
centred|70|96|Small|centre
line of text|0|112|Small|centre
back|84|112|Small|left
H140
DUMP 2 300
|0|0|Small|left
Title|0|0|Large|centre
Body text that wraps around|55|0|Small|left
the panel width|0|16|Small|left
second|0|32|Small|left
third|0|64|Small|left
red words|35|64|Small|left
more words here|98|64|Small|left
centred|203|64|Small|centre
line of text|0|80|Small|centre
back|84|80|Small|left
H108
DUMP 3 90
line one|0|0|Small|left
line two|0|16|Small|left
is a bit|0|32|Small|left
longer|0|48|Small|left
than one|0|64|Small|left
|0|80|Small|left
line|0|96|Small|left
four|0|112|Small|left
H140
DUMP 3 160
line one|0|0|Small|left
line two is a bit|0|16|Small|left
longer than one|0|32|Small|left
|0|48|Small|left
line four|0|64|Small|left
H92
DUMP 3 300
line one|0|0|Small|left
line two is a bit longer than one|0|16|Small|left
|0|32|Small|left
line four|0|48|Small|left
H76
DUMP 4 90
short|0|0|Small|left
supercalifragilisticexpialidocious|0|16|Small|left
tail|0|32|Small|left
bullet|35|48|Small|left
words|35|64|Small|left
that|35|80|Small|left
go|35|96|Small|left
on|35|112|Small|left
and|35|128|Small|left
on|35|144|Small|left
and|35|160|Small|left
on|35|176|Small|left
to|35|192|Small|left
wrap|35|208|Small|left
H236
DUMP 4 160
short|0|0|Small|left
supercalifragilisticexpialidocious|0|16|Small|left
tail|0|32|Small|left
bullet words|35|32|Small|left
that go on|35|48|Small|left
and on and on|35|64|Small|left
to wrap|35|80|Small|left
H108
DUMP 4 300
short|0|0|Small|left
supercalifragilisticexpialidocious|0|16|Small|left
tail|0|32|Small|left
bullet words that go on and on|35|32|Small|left
and on to wrap|35|48|Small|left
H76
DUMP 5 90
a <b> c|0|0|Small|left
big|0|24|Large|left
text|0|48|Large|left
mid|0|68|Medium|left
words|0|88|Medium|left
x|0|108|Medium|left
small|9|108|Small|left
halved|0|132|Small|left
H160
DUMP 5 160
a <b> c|0|0|Small|left
big|49|0|Large|left
text|0|24|Large|left
mid words|44|24|Medium|left
x|0|44|Medium|left
small|9|44|Small|left
halved|44|52|Small|left
H80
DUMP 5 300
a <b> c|0|0|Small|left
big text|49|0|Large|left
mid words|137|0|Medium|left
x|227|0|Medium|left
small|0|16|Small|left
halved|35|24|Small|left
H52
DUMP 6 90
|0|0|Small|left
H12
DUMP 6 160
|0|0|Small|left
H12
DUMP 6 300
|0|0|Small|left
H12
DUMP 7 90
|0|0|Small|left
|0|16|Small|left
only|0|32|Small|left
commands|0|48|Small|left
H76
DUMP 7 160
|0|0|Small|left
|0|16|Small|left
only commands|0|32|Small|left
H60
DUMP 7 300
|0|0|Small|left
|0|16|Small|left
only commands|0|32|Small|left
H60
DUMP 8 90
|0|0|Small|left
Tight|0|0|Large|centre
no|0|24|Large|centre
space|0|48|Large|centre
after|0|72|Large|centre
the|0|96|Large|centre
|33|96|Large|centre
two|0|120|Large|centre
spaces|0|144|Large|centre
and|0|168|Large|centre
gaps|0|192|Large|centre
trailing|0|240|Large|centre
|0|264|Large|centre
H276
DUMP 8 160
|0|0|Small|left
Tight|0|0|Large|centre
no space|0|24|Large|centre
after the|0|48|Large|centre
|99|48|Large|centre
two spaces|0|72|Large|centre
and gaps|0|96|Large|centre
trailing|0|120|Large|centre
H156
DUMP 8 300
|0|0|Small|left
Tight|0|0|Large|centre
no space after the|0|24|Large|centre
|198|24|Large|centre
two|198|24|Large|centre
spaces and gaps|0|48|Large|centre
trailing|0|72|Large|centre
H108
DUMP 9 90
an|0|0|Small|left
unmatched|0|16|Small|left
<b c>|0|32|Small|left
pair and|0|48|Small|left
a lone >|0|64|Small|left
sign and|0|80|Small|left
a <|0|96|Small|left
sign,|0|112|Small|left
then|0|128|Small|left
pushed|0|144|Small|left
deeper|0|160|Small|left
up|42|160|Small|left
out|0|176|Small|left
done|21|176|Small|left
H204
DUMP 9 160
an unmatched <b c>|0|0|Small|left
pair and a lone >|0|16|Small|left
sign and a < sign,|0|32|Small|left
then|0|48|Small|left
pushed|28|48|Small|left
deeper|70|48|Small|left
up|112|48|Small|left
out|0|64|Small|left
done|21|64|Small|left
H92
DUMP 9 300
an unmatched <b c> pair and a lone >|0|0|Small|left
sign and a < sign, then|0|16|Small|left
pushed|161|16|Small|left
deeper|203|16|Small|left
up|245|16|Small|left
out|0|32|Small|left
done|21|32|Small|left
H60
DUMP 10 90
alpha|0|0|Small|left
beta|0|16|Small|left
gamma|0|32|Small|left
|35|32|Small|left
epsilon|0|48|Small|left
zeta eta|0|64|Small|left
theta|0|80|Small|left
iota|0|96|Small|left
kappa|0|112|Small|left
lambda|0|128|Small|left
mu nu xi|0|144|Small|left
omicron|0|160|Small|left
pi rho|0|176|Small|left
alpha|0|208|Small|left
beta|0|224|Small|left
gamma|0|240|Small|left
|35|240|Small|left
epsilon|0|256|Small|left
zeta eta|0|272|Small|left
theta|0|288|Small|left
iota|0|304|Small|left
kappa|0|320|Small|left
lambda|0|336|Small|left
mu nu xi|0|352|Small|left
omicron|0|368|Small|left
pi rho|0|384|Small|left
alpha|0|416|Small|left
beta|0|432|Small|left
gamma|0|448|Small|left
|35|448|Small|left
epsilon|0|464|Small|left
zeta eta|0|480|Small|left
theta|0|496|Small|left
iota|0|512|Small|left
kappa|0|528|Small|left
lambda|0|544|Small|left
mu nu xi|0|560|Small|left
omicron|0|576|Small|left
pi rho|0|592|Small|left
alpha|0|624|Small|left
beta|0|640|Small|left
gamma|0|656|Small|left
|35|656|Small|left
epsilon|0|672|Small|left
zeta eta|0|688|Small|left
theta|0|704|Small|left
iota|0|720|Small|left
kappa|0|736|Small|left
lambda|0|752|Small|left
mu nu xi|0|768|Small|left
omicron|0|784|Small|left
pi rho|0|800|Small|left
alpha|0|832|Small|left
beta|0|848|Small|left
gamma|0|864|Small|left
|35|864|Small|left
epsilon|0|880|Small|left
zeta eta|0|896|Small|left
theta|0|912|Small|left
iota|0|928|Small|left
kappa|0|944|Small|left
lambda|0|960|Small|left
mu nu xi|0|976|Small|left
omicron|0|992|Small|left
pi rho|0|1008|Small|left
alpha|0|1040|Small|left
beta|0|1056|Small|left
gamma|0|1072|Small|left
|35|1072|Small|left
epsilon|0|1088|Small|left
zeta eta|0|1104|Small|left
theta|0|1120|Small|left
iota|0|1136|Small|left
kappa|0|1152|Small|left
lambda|0|1168|Small|left
mu nu xi|0|1184|Small|left
omicron|0|1200|Small|left
pi rho|0|1216|Small|left
alpha|0|1248|Small|left
beta|0|1264|Small|left
gamma|0|1280|Small|left
|35|1280|Small|left
epsilon|0|1296|Small|left
zeta eta|0|1312|Small|left
theta|0|1328|Small|left
iota|0|1344|Small|left
kappa|0|1360|Small|left
lambda|0|1376|Small|left
mu nu xi|0|1392|Small|left
omicron|0|1408|Small|left
pi rho|0|1424|Small|left
alpha|0|1456|Small|left
beta|0|1472|Small|left
gamma|0|1488|Small|left
|35|1488|Small|left
epsilon|0|1504|Small|left
zeta eta|0|1520|Small|left
theta|0|1536|Small|left
iota|0|1552|Small|left
kappa|0|1568|Small|left
lambda|0|1584|Small|left
mu nu xi|0|1600|Small|left
omicron|0|1616|Small|left
pi rho|0|1632|Small|left
alpha|0|1664|Small|left
beta|0|1680|Small|left
gamma|0|1696|Small|left
|35|1696|Small|left
epsilon|0|1712|Small|left
zeta eta|0|1728|Small|left
theta|0|1744|Small|left
iota|0|1760|Small|left
kappa|0|1776|Small|left
lambda|0|1792|Small|left
mu nu xi|0|1808|Small|left
omicron|0|1824|Small|left
pi rho|0|1840|Small|left
alpha|0|1872|Small|left
beta|0|1888|Small|left
gamma|0|1904|Small|left
|35|1904|Small|left
epsilon|0|1920|Small|left
zeta eta|0|1936|Small|left
theta|0|1952|Small|left
iota|0|1968|Small|left
kappa|0|1984|Small|left
lambda|0|2000|Small|left
mu nu xi|0|2016|Small|left
omicron|0|2032|Small|left
pi rho|0|2048|Small|left
alpha|0|2080|Small|left
beta|0|2096|Small|left
gamma|0|2112|Small|left
|35|2112|Small|left
epsilon|0|2128|Small|left
zeta eta|0|2144|Small|left
theta|0|2160|Small|left
iota|0|2176|Small|left
kappa|0|2192|Small|left
lambda|0|2208|Small|left
mu nu xi|0|2224|Small|left
omicron|0|2240|Small|left
pi rho|0|2256|Small|left
alpha|0|2288|Small|left
beta|0|2304|Small|left
gamma|0|2320|Small|left
|35|2320|Small|left
epsilon|0|2336|Small|left
zeta eta|0|2352|Small|left
theta|0|2368|Small|left
iota|0|2384|Small|left
kappa|0|2400|Small|left
lambda|0|2416|Small|left
mu nu xi|0|2432|Small|left
omicron|0|2448|Small|left
pi rho|0|2464|Small|left
|0|2496|Small|left
H2508
DUMP 10 160
alpha beta gamma|0|0|Small|left
|112|0|Small|left
epsilon zeta eta|0|16|Small|left
theta|0|32|Small|left
iota kappa|0|48|Small|left
lambda mu nu xi|0|64|Small|left
omicron pi rho|0|80|Small|left
alpha beta gamma|0|112|Small|left
|112|112|Small|left
epsilon zeta eta|0|128|Small|left
theta|0|144|Small|left
iota kappa|0|160|Small|left
lambda mu nu xi|0|176|Small|left
omicron pi rho|0|192|Small|left
alpha beta gamma|0|224|Small|left
|112|224|Small|left
epsilon zeta eta|0|240|Small|left
theta|0|256|Small|left
iota kappa|0|272|Small|left
lambda mu nu xi|0|288|Small|left
omicron pi rho|0|304|Small|left
alpha beta gamma|0|336|Small|left
|112|336|Small|left
epsilon zeta eta|0|352|Small|left
theta|0|368|Small|left
iota kappa|0|384|Small|left
lambda mu nu xi|0|400|Small|left
omicron pi rho|0|416|Small|left
alpha beta gamma|0|448|Small|left
|112|448|Small|left
epsilon zeta eta|0|464|Small|left
theta|0|480|Small|left
iota kappa|0|496|Small|left
lambda mu nu xi|0|512|Small|left
omicron pi rho|0|528|Small|left
alpha beta gamma|0|560|Small|left
|112|560|Small|left
epsilon zeta eta|0|576|Small|left
theta|0|592|Small|left
iota kappa|0|608|Small|left
lambda mu nu xi|0|624|Small|left
omicron pi rho|0|640|Small|left
alpha beta gamma|0|672|Small|left
|112|672|Small|left
epsilon zeta eta|0|688|Small|left
theta|0|704|Small|left
iota kappa|0|720|Small|left
lambda mu nu xi|0|736|Small|left
omicron pi rho|0|752|Small|left
alpha beta gamma|0|784|Small|left
|112|784|Small|left
epsilon zeta eta|0|800|Small|left
theta|0|816|Small|left
iota kappa|0|832|Small|left
lambda mu nu xi|0|848|Small|left
omicron pi rho|0|864|Small|left
alpha beta gamma|0|896|Small|left
|112|896|Small|left
epsilon zeta eta|0|912|Small|left
theta|0|928|Small|left
iota kappa|0|944|Small|left
lambda mu nu xi|0|960|Small|left
omicron pi rho|0|976|Small|left
alpha beta gamma|0|1008|Small|left
|112|1008|Small|left
epsilon zeta eta|0|1024|Small|left
theta|0|1040|Small|left
iota kappa|0|1056|Small|left
lambda mu nu xi|0|1072|Small|left
omicron pi rho|0|1088|Small|left
alpha beta gamma|0|1120|Small|left
|112|1120|Small|left
epsilon zeta eta|0|1136|Small|left
theta|0|1152|Small|left
iota kappa|0|1168|Small|left
lambda mu nu xi|0|1184|Small|left
omicron pi rho|0|1200|Small|left
alpha beta gamma|0|1232|Small|left
|112|1232|Small|left
epsilon zeta eta|0|1248|Small|left
theta|0|1264|Small|left
iota kappa|0|1280|Small|left
lambda mu nu xi|0|1296|Small|left
omicron pi rho|0|1312|Small|left
|0|1344|Small|left
H1356
DUMP 10 300
alpha beta gamma|0|0|Small|left
|112|0|Small|left
epsilon zeta eta theta|112|0|Small|left
iota kappa|0|16|Small|left
lambda mu nu xi omicron pi rho|0|32|Small|left
alpha beta gamma|0|64|Small|left
|112|64|Small|left
epsilon zeta eta theta|112|64|Small|left
iota kappa|0|80|Small|left
lambda mu nu xi omicron pi rho|0|96|Small|left
alpha beta gamma|0|128|Small|left
|112|128|Small|left
epsilon zeta eta theta|112|128|Small|left
iota kappa|0|144|Small|left
lambda mu nu xi omicron pi rho|0|160|Small|left
alpha beta gamma|0|192|Small|left
|112|192|Small|left
epsilon zeta eta theta|112|192|Small|left
iota kappa|0|208|Small|left
lambda mu nu xi omicron pi rho|0|224|Small|left
alpha beta gamma|0|256|Small|left
|112|256|Small|left
epsilon zeta eta theta|112|256|Small|left
iota kappa|0|272|Small|left
lambda mu nu xi omicron pi rho|0|288|Small|left
alpha beta gamma|0|320|Small|left
|112|320|Small|left
epsilon zeta eta theta|112|320|Small|left
iota kappa|0|336|Small|left
lambda mu nu xi omicron pi rho|0|352|Small|left
alpha beta gamma|0|384|Small|left
|112|384|Small|left
epsilon zeta eta theta|112|384|Small|left
iota kappa|0|400|Small|left
lambda mu nu xi omicron pi rho|0|416|Small|left
alpha beta gamma|0|448|Small|left
|112|448|Small|left
epsilon zeta eta theta|112|448|Small|left
iota kappa|0|464|Small|left
lambda mu nu xi omicron pi rho|0|480|Small|left
alpha beta gamma|0|512|Small|left
|112|512|Small|left
epsilon zeta eta theta|112|512|Small|left
iota kappa|0|528|Small|left
lambda mu nu xi omicron pi rho|0|544|Small|left
alpha beta gamma|0|576|Small|left
|112|576|Small|left
epsilon zeta eta theta|112|576|Small|left
iota kappa|0|592|Small|left
lambda mu nu xi omicron pi rho|0|608|Small|left
alpha beta gamma|0|640|Small|left
|112|640|Small|left
epsilon zeta eta theta|112|640|Small|left
iota kappa|0|656|Small|left
lambda mu nu xi omicron pi rho|0|672|Small|left
alpha beta gamma|0|704|Small|left
|112|704|Small|left
epsilon zeta eta theta|112|704|Small|left
iota kappa|0|720|Small|left
lambda mu nu xi omicron pi rho|0|736|Small|left
|0|768|Small|left
H780
]==]

-- The first line two texts differ at, for a message.
local function firstDifference(a, b)
    local i = 0
    local ia, ib = string.gmatch(a .. "\n", "(.-)\n"), string.gmatch(b .. "\n", "(.-)\n")
    while true do
        i = i + 1
        local la, lb = ia(), ib()
        if la == nil and lb == nil then return nil end
        if la ~= lb then return "line " .. i .. ": expected " .. tostring(lb) .. ", got " .. tostring(la) end
    end
end

test("paginate lays every text out as it always did, at every width", function()
    local out = {}
    for i, text in ipairs(TEXTS) do
        for _, w in ipairs({ 90, 160, 300 }) do
            out[#out + 1] = "DUMP " .. i .. " " .. w
            out[#out + 1] = dump(panelOf(w, text))
        end
    end
    local actual = table.concat(out, "\n")
    local expected = string.gsub(EXPECTED, "\n$", "")
    local why = firstDifference(actual, expected)
    if why then error(why, 0) end
end)

-- The rows a render draws, found the plain way: every row against the top and the bottom.
local function visibleRows(p)
    local rows = {}
    local top = p.marginTop - p.scroll
    for c = 1, #p.lines do
        local ly = top + p.lineY[c]
        if ly >= p.height then break end
        if p.lines[c] ~= "" and ly + p:lineHeightOf(p.cFont[c]) > 0 then rows[#rows + 1] = p.lines[c] end
    end
    return rows
end

test("render draws the rows on show only, and asks each font's height once", function()
    local text = {}
    for i = 1, 120 do
        text[#text + 1] = (i % 15 == 0 and "<SIZE:large> " or (i % 7 == 0 and "<SIZE:medium> " or "<SIZE:small> ")) ..
            "row" .. i .. " <LINE>"
    end
    local p = panelOf(200, table.concat(text, " "))
    local asked, ask = 0, p.lineHeightOf
    p.lineHeightOf = function(self, font) asked = asked + 1; return ask(self, font) end
    truthy(p.contentH > 1000, "a tall text")
    for _, scroll in ipairs({ 0, 5, 37, 400, 777.5, p:maxScroll() }) do
        p:setScroll(scroll)
        p.drawn = {}
        asked = 0
        p:render()
        local calls = asked
        local want = visibleRows(p)
        eq(table.concat(p.drawn, ","), table.concat(want, ","), "the rows at scroll " .. scroll)
        truthy(#want >= 3, "some rows show at scroll " .. scroll)
        truthy(calls <= 3, "each of the three fonts once, not each row: " .. calls .. " for " .. #want)
    end
end)

test("render takes a font's new height at once (none is kept past the render)", function()
    local p = panelOf(200, "one <LINE> two <LINE> three")
    p:render()
    eq(#p.drawn, 3)
    FH.Small = 40
    PZUIKit.UI.liveFrame()
    p:setScroll(0)
    p.marginTop = -45
    p.drawn = {}
    p:render()
    FH.Small = 16
    -- row one is at -45 and 40 high now: it shows no more; the others do
    eq(table.concat(p.drawn, ","), "two,three")
end)

test("the chunks a layout tries are measured and not kept in the texts' cache", function()
    local P, UI = load()
    local p = P:new(0, 0, 160, 100)
    p:setText(TEXTS[1])
    p:paginate()
    eq(p.lines[1], "The quick brown")
    -- (the layout measured "The quick brown" on its way, and the cache was not filled with it)
    local before = measureLog["The quick brown"] or 0
    truthy(before >= 1, "measured by the layout")
    UI.textWidth("The quick brown")
    eq(measureLog["The quick brown"], before + 1, "the cache had not got it")
    UI.textWidth("The quick brown")
    eq(measureLog["The quick brown"], before + 1, "and has it now")
    local raw = UI.textWidthRaw("The quick brown")
    eq(raw, UI.textWidth("The quick brown"), "the same width")
    UI.textWidthRaw("The quick brown")
    eq(measureLog["The quick brown"], before + 3, "raw is measured each time")
end)

test("a width on its way is laid out every 50 ms, and the width it stops at is laid out at last", function()
    local P, UI = load()
    local laid = 0
    local paginate = P.paginate
    P.paginate = function(self) laid = laid + 1; return paginate(self) end
    local p = P:new(0, 0, 300, 100)
    p:setText(TEXTS[10])
    p:render()
    eq(laid, 1, "the first layout at once")
    eq(p.laidW, 300)
    -- dragged: 5 wider or narrower every 10 ms, a frame each
    local width = 300
    for step = 1, 40 do
        now = now + 10
        width = width + (step % 2 == 0 and 7 or -5)
        p.width = width
        p:onResize()
        UI.liveFrame()
        p:render()
    end
    truthy(laid <= 1 + 400 / 50 + 1, "about one layout in 50 ms, not one a step: " .. laid)
    truthy(laid >= 6, "but they are made while it goes: " .. laid)
    -- the width stops: the layout it stops at is made within the 50 ms, with no more resizing
    local last = p.width
    local frames = 0
    while p.laidW ~= p.width and frames < 20 do
        now = now + 10
        UI.liveFrame()
        p:render()
        frames = frames + 1
    end
    eq(p.laidW, last, "laid out for the width it stopped at")
    truthy(frames <= 5, "within 50 ms: " .. frames)
    local fresh = panelOf(last, TEXTS[10])
    eq(dump(p), dump(fresh), "the same layout as one made for that width alone")
    -- (the panel is let go once it has caught up)
    UI.liveFrame()
    local entries = UI.liveSize()
    eq(entries, 0, "nothing followed once the layout stands")
end)

test("a width changed after a still time is laid out at once; the height alone lays out nothing", function()
    local P, UI = load()
    local laid = 0
    local paginate = P.paginate
    P.paginate = function(self) laid = laid + 1; return paginate(self) end
    local p = P:new(0, 0, 300, 100)
    p:setText(TEXTS[1])
    p:render()
    now = now + 5000
    p.width = 180
    p:onResize()
    p:render()
    eq(laid, 2, "at once")
    eq(p.laidW, 180)
    now = now + 5
    p.height = 60
    p:onResize()
    p:render()
    eq(laid, 2, "a height only is no new layout")
    eq(p:maxScroll(), math.max(0, p.contentH - 60), "but the scroll's end follows it")
end)

test("a layout waiting for its time is made by the frame of UI.live even when nothing renders", function()
    local P, UI = load()
    local p = P:new(0, 0, 300, 100)
    p:setText(TEXTS[1])
    p:render()
    now = now + 5000
    p.width = 200
    p:render()
    eq(p.laidW, 200, "at once after a still time")
    now = now + 10
    p.width = 150
    p:render()
    eq(p.laidW, 200, "waiting")
    now = now + 20
    UI.liveFrame()
    eq(p.laidW, 200, "still waiting")
    now = now + 25
    UI.liveFrame()
    eq(p.laidW, 150, "laid out by the frame, with no render")
    truthy(p.liveLook ~= nil, "and the panel told of it")
    now = now + 10
    UI.liveFrame()
    eq(p.liveLook, nil, "then let go")
end)

test("the tooltip makes no colour tables, asks the screen once an era and moves only when its place changes", function()
    local P, UI = load()
    local asked = 0
    getCore = function()
        return { getScreenWidth = function() asked = asked + 1; return 1600 end, getScreenHeight = function() return 900 end }
    end
    local mouse = { 100, 100 }
    getMouseX = function() return mouse[1] end
    getMouseY = function() return mouse[2] end
    local palette = { bg = { 0.1, 0.2, 0.3 }, border = { 0.4, 0.5, 0.6 } }
    local owner = {}
    local tip
    local new = P.new
    P.new = function(self, ...) tip = new(self, ...); return tip end
    PZUIRichTip.show(owner, "hello world", palette)
    local bg = tip.backgroundColor
    eq(bg.r, 0.1)
    eq(bg.a, 0.97)
    eq(tip.borderColor.b, 0.6)
    local moved = tip.moved
    eq(asked, 1)
    for _ = 1, 5 do PZUIRichTip.show(owner, "hello world", palette) end
    eq(asked, 1, "the screen asked once")
    eq(tip.moved, moved, "not moved while the mouse stands")
    eq(tip.backgroundColor, bg, "the colour table is the one made")
    mouse[1] = 130
    PZUIRichTip.show(owner, "hello world", palette)
    truthy(tip.moved > moved, "moved with the mouse")
    palette.bg = { 0.9, 0.8, 0.7 }
    PZUIRichTip.show(owner, "hello world", palette)
    eq(tip.backgroundColor.r, 0.9, "a new palette shows")
    eq(tip.backgroundColor, bg, "in the same table")
    UI.setScale(2, false)
    PZUIRichTip.show(owner, "hello world", palette)
    eq(asked, 2, "asked again in the next era")
end)
