"""Builds the extension API's embedded fonts (docs/design/extension-api.md, "The embedded font").

Each pack is a static Noto Sans SemiBold (wght 600) made from Google Fonts' variable font, cut down to the characters a
language's large text needs, with what a distance-field atlas does not use taken out: hinting, vertical metrics, glyph
names, the layout tables (pair kerning of the non-CJK characters is kept, flattened into a 'kern' table) and DSIG.

    python -X utf8 scripts/fonts/build-api-fonts.py --source <folder with the downloaded originals>
    python -X utf8 scripts/fonts/build-api-fonts.py --scan --game <ProjectZomboid folder> --mods <mod folder> ...

The originals come from https://github.com/google/fonts (OFL): ofl/notosans/NotoSans[wdth,wght].ttf and
ofl/notosans{kr,jp,sc,tc}/NotoSans{KR,JP,SC,TC}[wght].ttf, with OFL.txt. They are not kept in the repository; the packs
and the license are (src/PzTools.GameBridge.Agent/fonts).

--scan writes scripts/fonts/in-use/<pack>.txt: every character of the game's translations for the pack's languages and of
the given mods' (all their languages for the Latin pack). The build adds those to each pack's fixed sets, so a run gives the
same files from the same inputs. Needs fontTools (pip install fonttools).
"""

import argparse
import hashlib
import json
import pathlib
import re
import sys

from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables._k_e_r_n import KernTable_format_0
from fontTools.subset import Options, Subsetter
from fontTools.varLib import instancer

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
IN_USE = HERE / "in-use"
OUTPUT = REPO / "src" / "PzTools.GameBridge.Agent" / "fonts"

WEIGHT = 600

# The game's languages (media/lua/shared/Translate/<code>) by pack. Thai has no pack: the game's font draws it.
LANGUAGES = {
    "ko": ["KO"],
    "ja": ["JP"],
    "sc": ["CN"],
    "tc": ["CH"],
}
NOT_LATIN = {"KO", "JP", "CN", "CH", "TH"}


def ranges(*pairs):
    result = set()
    for low, high in pairs:
        result.update(range(low, high + 1))
    return result


# Every pack: Latin, Greek, Cyrillic, punctuation and the signs large text uses (· × — → █ … ★ ①); what the translations
# use besides comes from in-use/<pack>.txt.
COMMON = ranges(
    (0x0020, 0x007E), (0x00A0, 0x024F), (0x0370, 0x03FF), (0x0400, 0x04FF),
    (0x2010, 0x205E), (0x20A0, 0x20C0), (0x2103, 0x2103), (0x2116, 0x2116), (0x2122, 0x2122),
    (0x2190, 0x2199), (0x2212, 0x2212), (0x221E, 0x221E), (0x2248, 0x2248), (0x2260, 0x2260), (0x2264, 0x2265),
    (0x2460, 0x2473), (0x2580, 0x259F), (0x25A0, 0x25A1), (0x25B2, 0x25B3), (0x25B6, 0x25B7), (0x25BC, 0x25BD),
    (0x25C0, 0x25C1), (0x25C6, 0x25C7), (0x25CB, 0x25CB), (0x25CE, 0x25CF), (0x2605, 0x2606), (0x2610, 0x2612),
    (0x2660, 0x2667), (0x266A, 0x266B),
)
# The CJK packs: the ideographic punctuation and the full-width forms.
CJK_PUNCTUATION = ranges((0x3000, 0x3011), (0x3014, 0x301F), (0xFF01, 0xFF5E), (0xFF61, 0xFF65))


def ks_x_1001_hangul():
    """The 2,350 Hangul syllables of KS X 1001 (EUC-KR's two-byte syllables)."""
    found = set()
    for code in range(0xAC00, 0xD7A4):
        try:
            if len(chr(code).encode("euc_kr")) == 2:
                found.add(code)
        except UnicodeEncodeError:
            pass
    return found


def two_byte(codec, leads, trails):
    found = set()
    for lead in leads:
        for trail in trails:
            try:
                text = bytes((lead, trail)).decode(codec)
            except UnicodeDecodeError:
                continue
            if len(text) == 1:
                found.add(ord(text))
    return found


def jis_level_1():
    """JIS X 0208's first level of kanji (2,965, EUC-JP B0A1 to CFD3): the common ones, with nearly all the joyo kanji."""
    found = two_byte("euc_jp", range(0xB0, 0xD0), range(0xA1, 0xFF))
    return {code for code in found if 0x4E00 <= code <= 0x9FFF}


def gb2312_level_1():
    """GB 2312's first level of hanzi (3,755, rows 16 to 55): the common simplified characters."""
    found = two_byte("gb2312", range(0xB0, 0xD8), range(0xA1, 0xFF))
    return {code for code in found if 0x4E00 <= code <= 0x9FFF}


def big5_level_1():
    """Big5's frequent characters (5,401, A440 to C67E), drawn from the Ministry of Education's common traditional set."""
    found = two_byte("big5", range(0xA4, 0xC7), list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)))
    return {code for code in found if 0x4E00 <= code <= 0x9FFF}


KANA = ranges((0x3041, 0x3096), (0x3099, 0x30FF), (0x31F0, 0x31FF), (0xFF66, 0xFF9F))
HANGUL_JAMO = ranges((0x3131, 0x318E))


def in_use(pack):
    path = IN_USE / f"{pack}.txt"
    if not path.exists():
        return set()
    return {ord(letter) for letter in path.read_text(encoding="utf-8") if letter not in "\r\n"}


PACKS = {
    # pack: (original, the axes to pin, the characters wanted)
    "latin": ("NotoSans[wdth,wght].ttf", {"wght": WEIGHT, "wdth": 100}, lambda: COMMON | in_use("latin")),
    "ko": ("NotoSansKR[wght].ttf", {"wght": WEIGHT}, lambda: COMMON | CJK_PUNCTUATION | HANGUL_JAMO | ks_x_1001_hangul() | in_use("ko")),
    "ja": ("NotoSansJP[wght].ttf", {"wght": WEIGHT}, lambda: COMMON | CJK_PUNCTUATION | KANA | jis_level_1() | in_use("ja")),
    "sc": ("NotoSansSC[wght].ttf", {"wght": WEIGHT}, lambda: COMMON | CJK_PUNCTUATION | gb2312_level_1() | in_use("sc")),
    "tc": ("NotoSansTC[wght].ttf", {"wght": WEIGHT}, lambda: COMMON | CJK_PUNCTUATION | big5_level_1() | in_use("tc")),
}

# Kerning is kept for these characters only: the CJK fonts kern Latin and punctuation, never their syllables or ideographs.
KERNED = ranges((0x0020, 0x024F), (0x0370, 0x052F), (0x2010, 0x205E))
# A legacy kern subtable holds at most (65535 - 14) / 6 pairs.
PAIRS_PER_SUBTABLE = 10000


# ---- --scan ----

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def characters_of(folder):
    """Every character of the translation files under a Translate/<code> folder (.json in Build 42, .txt before)."""
    found = set()
    for file in sorted(folder.rglob("*")):
        if not file.is_file():
            continue
        if file.suffix == ".json":
            try:
                data = json.loads(file.read_text(encoding="utf-8-sig"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            for text in strings(data):
                found.update(text)
        elif file.suffix == ".txt":
            try:
                found.update(file.read_text(encoding="utf-8-sig"))
            except UnicodeDecodeError:
                continue
    return {letter for letter in found if letter >= " " and ord(letter) <= 0xFFFF and not 0xD800 <= ord(letter) <= 0xDFFF}


def translate_folders(root):
    """Each Translate/<code> folder under a game or mod folder, by code."""
    found = {}
    for folder in sorted(root.rglob("Translate")):
        if folder.is_dir():
            for language in sorted(folder.iterdir()):
                if language.is_dir():
                    found.setdefault(language.name.upper(), []).append(language)
    return found


def scan(game, mods):
    roots = [game / "media" / "lua" / "shared"] + list(mods)
    letters = {pack: set() for pack in ["latin", *LANGUAGES]}
    for root in roots:
        for code, folders in translate_folders(root).items():
            for folder in folders:
                found = characters_of(folder)
                if code not in NOT_LATIN:
                    letters["latin"].update(found)
                for pack, codes in LANGUAGES.items():
                    if code in codes:
                        letters[pack].update(found)
    IN_USE.mkdir(parents=True, exist_ok=True)
    for pack, found in letters.items():
        text = "".join(sorted(found - {" ", "\t"}))
        # One line of 64 characters each, so that a change reads as a diff.
        lines = [text[index:index + 64] for index in range(0, len(text), 64)]
        (IN_USE / f"{pack}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        print(f"{pack}: {len(found)} characters in use")


# ---- the build ----

def flatten_kerning(font, cmap):
    """The pair kerning of the GPOS 'kern' feature between the KERNED characters, as {(left glyph, right glyph): units}."""
    if "GPOS" not in font:
        return {}
    gpos = font["GPOS"].table
    wanted = {cmap[code] for code in KERNED if code in cmap}
    lookups = set()
    for record in gpos.FeatureList.FeatureRecord:
        if record.FeatureTag == "kern":
            lookups.update(record.Feature.LookupListIndex)
    pairs = {}
    for index in sorted(lookups):
        lookup = gpos.LookupList.Lookup[index]
        for subtable in lookup.SubTable:
            if lookup.LookupType == 9:
                subtable = subtable.ExtSubTable
            if getattr(subtable, "LookupType", 2) != 2:
                continue
            covered = subtable.Coverage.glyphs
            if subtable.Format == 1:
                for first, pair_set in zip(covered, subtable.PairSet):
                    if first not in wanted:
                        continue
                    for record in pair_set.PairValueRecord:
                        value = getattr(record.Value1, "XAdvance", 0) if record.Value1 else 0
                        if value and record.SecondGlyph in wanted:
                            pairs.setdefault((first, record.SecondGlyph), value)
            elif subtable.Format == 2:
                first_classes = subtable.ClassDef1.classDefs
                second_classes = subtable.ClassDef2.classDefs
                seconds = [glyph for glyph in wanted]
                for first in covered:
                    if first not in wanted:
                        continue
                    row = subtable.Class1Record[first_classes.get(first, 0)]
                    for second in seconds:
                        record = row.Class2Record[second_classes.get(second, 0)]
                        value = getattr(record.Value1, "XAdvance", 0) if record.Value1 else 0
                        if value:
                            pairs.setdefault((first, second), value)
    return pairs


def build(source, pack):
    original, axes, wanted = PACKS[pack]
    path = source / original
    if not path.exists():
        sys.exit(f"{path} is missing: download it from https://github.com/google/fonts")
    codes = wanted()
    font = TTFont(path)
    available = set(font.getBestCmap())
    codes &= available
    # Cut down first, keeping the variations, then pin the weight: much faster than pinning the whole font.
    options = Options()
    options.layout_features = ["kern"]
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.glyph_names = False
    options.hinting = False
    options.legacy_kern = False
    options.drop_tables += ["DSIG", "vhea", "vmtx", "VORG", "BASE", "JSTF", "meta", "STAT", "MVAR", "VVAR"]
    subsetter = Subsetter(options)
    subsetter.populate(unicodes=codes)
    subsetter.subset(font)
    font = instancer.instantiateVariableFont(font, axes, updateFontNames=False)
    cmap = font.getBestCmap()
    pairs = flatten_kerning(font, cmap)
    for table in ["GPOS", "GSUB", "GDEF", "STAT", "HVAR", "hdmx", "LTSH", "VDMX", "cvt ", "fpgm", "prep", "gasp"]:
        if table in font:
            del font[table]
    if pairs:
        kern = newTable("kern")
        kern.version = 0
        kern.kernTables = []
        items = sorted(pairs.items(), key=lambda item: (font.getGlyphID(item[0][0]), font.getGlyphID(item[0][1])))
        for start in range(0, len(items), PAIRS_PER_SUBTABLE):
            subtable = KernTable_format_0()
            subtable.version = 0
            subtable.format = 0
            subtable.coverage = 1
            subtable.tupleIndex = None
            subtable.kernTable = dict(items[start:start + PAIRS_PER_SUBTABLE])
            kern.kernTables.append(subtable)
        font["kern"] = kern
    # The weight is pinned: the font says it is SemiBold.
    font["OS/2"].usWeightClass = WEIGHT
    target = OUTPUT / f"pztools-font-{pack}.ttf"
    OUTPUT.mkdir(parents=True, exist_ok=True)
    # The original's dates stay, so the same inputs give the same bytes.
    font.recalcTimestamp = False
    font.save(target)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()[:16]
    hangul = sum(1 for code in cmap if 0xAC00 <= code <= 0xD7A3)
    han = sum(1 for code in cmap if 0x4E00 <= code <= 0x9FFF)
    print(f"{target.name}: {target.stat().st_size:,} bytes, {len(cmap)} characters ({hangul} Hangul, {han} Han),"
          f" {len(pairs)} kerning pairs, {len(wanted() - available)} wanted characters the original lacks, sha256 {digest}")


def license_text(source):
    """The OFL with both copyright lines: the Noto Project's (Latin) and Adobe's (the CJK fonts)."""
    latin = (source / "OFL-notosans.txt").read_text(encoding="utf-8").splitlines()
    cjk = (source / "OFL-notosanskr.txt").read_text(encoding="utf-8").splitlines()
    body_latin = "\n".join(latin[1:]).strip()
    body_cjk = "\n".join(cjk[1:]).strip()
    if body_latin != body_cjk:
        sys.exit("The licenses' texts differ; keep both files")
    text = "\n".join([
        "The fonts in this folder are subsets of Noto Sans, Noto Sans KR, JP, SC and TC (Google Fonts), static SemiBold",
        "instances cut down by scripts/fonts/build-api-fonts.py.",
        "",
        latin[0],
        cjk[0],
        "",
        body_latin,
        "",
    ])
    (OUTPUT / "OFL.txt").write_text(text, encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=pathlib.Path, help="the folder with the downloaded originals and their OFL-<family>.txt")
    parser.add_argument("--pack", action="append", choices=sorted(PACKS), help="build only these packs")
    parser.add_argument("--scan", action="store_true", help="write the characters in use instead of building")
    parser.add_argument("--game", type=pathlib.Path, help="with --scan: the ProjectZomboid folder")
    parser.add_argument("--mods", type=pathlib.Path, nargs="*", default=[], help="with --scan: mod folders whose translations to read")
    arguments = parser.parse_args()
    if arguments.scan:
        if not arguments.game:
            parser.error("--scan needs --game")
        scan(arguments.game, arguments.mods)
        return
    if not arguments.source:
        parser.error("--source is required")
    for pack in arguments.pack or list(PACKS):
        build(arguments.source, pack)
    license_text(arguments.source)


if __name__ == "__main__":
    main()
