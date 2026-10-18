package pzext.api;

import java.awt.Font;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.FileTime;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * The embedded font's packs and its bake (docs/design.md, "The embedded font"): every Hangul syllable of KS X 1001
 * and every character the game's and the mods' Korean translations use is in the Korean pack; each pack has the Latin letters; the
 * cache's name follows the font file's bytes, the baker's version, the size and the spread; the bake is a process of its own that
 * writes its folder whole or not at all, cleans up the pack's older bakes and a dead bake's parts, and only one runs at a time.
 * Needs {@code pzext.test.repository} (the repository) and {@code pzext.test.apiJar} (the API's jar), as test-game-bridge.ps1 sets.
 */
final class FontsTest {
    private FontsTest() { }

    static void run() throws Exception {
        Path repository = Path.of(System.getProperty("pzext.test.repository", ""));
        Path fonts = repository.resolve("fonts"), inUse = repository.resolve("tools/fonts-in-use");
        check(Files.isDirectory(fonts) && Files.isDirectory(inUse), "Set pzext.test.repository to the repository: " + repository);
        Path jar = Path.of(System.getProperty("pzext.test.apiJar", ""));
        check(Files.isRegularFile(jar), "Set pzext.test.apiJar to the API's jar: " + jar);
        coverage(fonts, inUse);
        packs();
        Path work = Files.createTempDirectory("pzext-fonts-test");
        try {
            names(fonts, work);
            bake(fonts, jar, work);
        } finally { delete(work); }
        System.out.println("PASS: the font packs have their characters, and a pack is baked in a process of its own into a folder that is whole or absent");
    }

    /** The Korean pack: all 2,350 KS X 1001 syllables and every character of the Korean translations; every pack: the Latin letters. */
    private static void coverage(Path fonts, Path inUse) throws Exception {
        Font korean = Font.createFont(Font.TRUETYPE_FONT, fonts.resolve("pzext-font-ko.ttf").toFile());
        var encoder = Charset.forName("EUC-KR").newEncoder();
        int syllables = 0;
        for (char letter = 0xAC00; letter <= 0xD7A3; letter++) {
            if (!encoder.canEncode(letter)) continue;
            syllables++;
            check(korean.canDisplay(letter), "The Korean pack lacks " + letter);
        }
        check(syllables == 2350, "KS X 1001 has " + syllables + " syllables here, not 2,350");
        String used = Files.readString(inUse.resolve("ko.txt"), StandardCharsets.UTF_8);
        int count = 0;
        for (int index = 0; index < used.length(); index++) {
            char letter = used.charAt(index);
            if (letter == '\n' || letter == '\r') continue;
            count++;
            check(korean.canDisplay(letter), "The Korean pack lacks " + letter + " (U+" + Integer.toHexString(letter) + "), which the translations use");
        }
        check(count > 1400, "The Korean characters in use are only " + count);
        for (String signs : new String[] { "·×—→█…" }) for (char sign : signs.toCharArray()) check(korean.canDisplay(sign), "The Korean pack lacks " + sign);
        for (String pack : new String[] { "latin", "ko", "ja", "sc", "tc" }) {
            Font font = Font.createFont(Font.TRUETYPE_FONT, fonts.resolve("pzext-font-" + pack + ".ttf").toFile());
            for (char letter = 0x21; letter <= 0x7E; letter++) check(font.canDisplay(letter), "The " + pack + " pack lacks " + letter);
            check(font.canDisplay('Ж') && font.canDisplay('é'), "The " + pack + " pack lacks Cyrillic or accented Latin");
        }
        Font japanese = Font.createFont(Font.TRUETYPE_FONT, fonts.resolve("pzext-font-ja.ttf").toFile());
        check(japanese.canDisplay('あ') && japanese.canDisplay('ア') && japanese.canDisplay('漢'), "The Japanese pack lacks kana or kanji");
    }

    /** The game's languages to the packs: Thai has none, the rest of the Latin and Cyrillic languages share one. */
    private static void packs() {
        check("ko".equals(EmbeddedFont.pack("KO")) && "ja".equals(EmbeddedFont.pack("JP")) && "sc".equals(EmbeddedFont.pack("CN"))
            && "tc".equals(EmbeddedFont.pack("CH")) && EmbeddedFont.pack("TH") == null && "latin".equals(EmbeddedFont.pack("RU"))
            && "latin".equals(EmbeddedFont.pack("PTBR")) && "latin".equals(EmbeddedFont.pack("EN")), "A language has the wrong pack");
    }

    /** The cache's name: the pack, the file's digest, the baker's version, the size and the spread; another byte, another name. */
    private static void names(Path fonts, Path work) throws Exception {
        Path ttf = work.resolve("copy.ttf");
        Files.copy(fonts.resolve("pzext-font-latin.ttf"), ttf);
        String name = EmbeddedFont.name("latin", ttf);
        check(name.matches("latin-[0-9a-f]{16}-v" + FontBaker.VERSION + "-" + EmbeddedFont.size("latin") + "-" + EmbeddedFont.SPREAD), "The cache's name is " + name);
        check(name.equals(EmbeddedFont.name("latin", fonts.resolve("pzext-font-latin.ttf"))), "The same bytes gave another name");
        // The name is kept per file (path, size, time of its last change): a file as it was is never read again, a changed one is.
        FileTime stamp = Files.getLastModifiedTime(ttf);
        byte[] bytes = Files.readAllBytes(ttf);
        bytes[bytes.length - 1] ^= 1;
        Files.write(ttf, bytes);
        Files.setLastModifiedTime(ttf, stamp);
        check(name.equals(EmbeddedFont.name("latin", ttf)), "An unchanged file (size and time) was read again");
        Files.setLastModifiedTime(ttf, FileTime.fromMillis(stamp.toMillis() + 2000));
        String changed = EmbeddedFont.name("latin", ttf);
        check(!name.equals(changed), "Another font file gave the same name");
        check(changed.equals(EmbeddedFont.name("latin", ttf)), "The name of a file changed twice");
        Files.write(ttf, Arrays.copyOf(bytes, bytes.length - 1));
        check(!changed.equals(EmbeddedFont.name("latin", ttf)), "A file of another size kept the name");
        // The other file in between, and back: the first is read again and gives its name still.
        check(name.equals(EmbeddedFont.name("latin", fonts.resolve("pzext-font-latin.ttf"))), "The pack file gave another name after the copy changed");
    }

    /** The real bake, in a process of its own on this runtime. */
    private static void bake(Path fonts, Path jar, Path work) throws Exception {
        Path cache = work.resolve("cache"), ttf = fonts.resolve("pzext-font-latin.ttf");
        String name = EmbeddedFont.name("latin", ttf);
        // An older bake of the pack, a dead bake's part (old, and new: one may be running) and another pack's bake.
        Path older = cache.resolve("latin-0123456789abcdef-v0-64-8"), dead = cache.resolve(name + ".part-1"), running = cache.resolve(name + ".part-2");
        Path other = cache.resolve("ko-0123456789abcdef-v" + FontBaker.VERSION + "-64-8");
        for (Path folder : new Path[] { older, dead, running, other }) Files.createDirectories(folder);
        Files.writeString(dead.resolve(FontBaker.FNT), "half");
        Files.setLastModifiedTime(dead, java.nio.file.attribute.FileTime.fromMillis(System.currentTimeMillis() - 7_200_000));
        // A folder that is there but not whole is not a bake.
        Files.createDirectories(cache.resolve(name));
        Files.writeString(cache.resolve(name).resolve(FontBaker.FNT), "half");
        check(!EmbeddedFont.baked(cache, name), "A folder without its atlas counts as baked");
        delete(cache.resolve(name));
        check(!EmbeddedFont.baked(cache, name), "No folder counts as baked");

        Path javaHome = Path.of(System.getProperty("java.home"));
        long start = System.nanoTime();
        Process process = EmbeddedFont.bake(javaHome, jar, ttf, cache, name);
        check(process != null && name.equals(EmbeddedFont.baking()), "The bake did not start");
        check(EmbeddedFont.bake(javaHome, jar, ttf, cache, name) == null, "A second bake started while one ran");
        check(process.waitFor(5, TimeUnit.MINUTES), "The bake did not end");
        long millis = (System.nanoTime() - start) / 1_000_000;
        String log = Files.readString(cache.resolve("bake-latin.log"));
        check(process.exitValue() == 0, "The bake failed: " + log);
        check(EmbeddedFont.baked(cache, name), "The bake left no font");
        check(!Files.exists(older) && !Files.exists(dead) && Files.exists(running) && Files.exists(other),
            "The bake did not clean up the pack's older bakes alone");
        try (var entries = Files.list(cache)) {
            check(entries.noneMatch(path -> path.getFileName().toString().startsWith(name + ".part-") && !path.equals(running)), "The bake left its part");
        }
        Map<String, Integer> header = EmbeddedFont.header(cache.resolve(name).resolve(FontBaker.FNT));
        int width = header.get("width"), height = header.get("height");
        check(header.get("version") == FontBaker.VERSION && header.get("spread") == EmbeddedFont.SPREAD && header.get("size") == EmbeddedFont.size("latin")
            && Integer.bitCount(width) == 1 && Integer.bitCount(height) == 1 && header.get("lineHeight") > EmbeddedFont.size("latin"), "The header is " + header);
        check(Files.size(cache.resolve(name).resolve(FontBaker.ATLAS)) == (long)width * height, "The atlas is not width by height bytes");
        String fnt = Files.readString(cache.resolve(name).resolve(FontBaker.FNT));
        // The game's reader takes no page line with a texture given: the atlas is one picture, given as the font is made.
        check(!fnt.contains("\npage ") && fnt.contains("\nchar id=65 ") && fnt.contains("\nkerning first="), "The text file lacks its characters or kerning");
        // An 'A' is drawn: some texels are inside its outline, some outside.
        int[] a = glyph(fnt, 65);
        byte[] atlas = Files.readAllBytes(cache.resolve(name).resolve(FontBaker.ATLAS));
        int inside = 0, outside = 0;
        for (int y = a[1]; y < a[1] + a[3]; y++) for (int x = a[0]; x < a[0] + a[2]; x++) {
            int value = atlas[y * width + x] & 0xFF;
            if (value > 160) inside++;
            if (value < 20) outside++;
        }
        check(inside > 20 && outside > 20, "The 'A' has " + inside + " texels inside and " + outside + " outside");
        // Baking it again leaves the folder there as it was.
        byte[] before = Files.readAllBytes(cache.resolve(name).resolve(FontBaker.ATLAS));
        Process again = EmbeddedFont.bake(javaHome, jar, ttf, cache, name);
        check(again.waitFor(5, TimeUnit.MINUTES) && again.exitValue() == 0, "Baking again failed");
        check(java.util.Arrays.equals(before, Files.readAllBytes(cache.resolve(name).resolve(FontBaker.ATLAS))), "Baking again changed the atlas");
        System.out.println("The Latin pack baked in " + millis + " ms (" + width + " x " + height + ")");
    }

    /** A character's x, y, width and height in the atlas, from the text file. */
    private static int[] glyph(String fnt, int code) {
        for (String line : fnt.split("\n")) {
            if (!line.startsWith("char id=" + code + " ")) continue;
            var values = new java.util.HashMap<String, Integer>();
            for (String field : line.split(" +")) {
                int equals = field.indexOf('=');
                if (equals > 0) try { values.put(field.substring(0, equals), Integer.parseInt(field.substring(equals + 1))); } catch (NumberFormatException skip) { }
            }
            return new int[] { values.get("x"), values.get("y"), values.get("width"), values.get("height") };
        }
        throw new AssertionError("No character " + code);
    }

    private static void delete(Path root) throws Exception {
        if (!Files.exists(root)) return;
        try (var walk = Files.walk(root)) { for (Path path : walk.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
