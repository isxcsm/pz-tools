package pzext.api;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.core.fonts.AngelCodeFont;
import zombie.ui.TextManager;
import zombie.ui.UIFont;

/**
 * {@code text.wrap} and {@code text.fit}: the breaking and the cutting themselves (a font ten pixels to a character, so that every
 * width is easy to see), then through Lua against the game's fonts named, the cache (hits, owners, fonts made again, the least
 * recently used out), the arguments, and what a cached call costs. Keys from {@code text.font} are tried from the test of those.
 */
final class TextFitsTest {
    private TextFitsTest() { }

    static void run(KahluaTable text) throws Exception {
        var api = (KahluaTable)LuaManager.env.rawget(GameApi.GLOBAL);
        Object mod = FormulasTest.call(api, "client", "text.fits.mod").get(0), other = FormulasTest.call(api, "client", "text.fits.other").get(0);
        try { all(text, mod, other); }
        catch (Exception | Error expected) { throw expected; }
        catch (Throwable failure) { throw new IllegalStateException(failure); }
    }

    private static void all(KahluaTable text, Object mod, Object other) throws Throwable {
        algorithm();
        named(text, mod, other);
        caching(text, mod, other);
        rejects(text, mod);
        cost(text, mod);
    }

    private static final TextFits.Width TEN = text -> text.length() * 10;

    private static List<String> wrap(String text, int limit) throws Throwable { return Arrays.asList(TextFits.wrap(TEN, text, limit)); }

    private static void algorithm() throws Throwable {
        check(wrap("hello world foo", 80).equals(List.of("hello", "world", "foo")), "Words: " + wrap("hello world foo", 80));
        check(wrap("hello world foo", 100).equals(List.of("hello", "world foo")), "Words that fit: " + wrap("hello world foo", 100));
        check(wrap("hello world", 1000).equals(List.of("hello world")), "Text that fits was broken");
        // The spaces at a break are dropped; inside a row they stay.
        check(wrap("ab    cd  ef", 70).equals(List.of("ab", "cd  ef")), "Spaces at a break: " + wrap("ab    cd  ef", 70));
        check(wrap("a\n\nb", 100).equals(List.of("a", "", "b")), "Paragraphs: " + wrap("a\n\nb", 100));
        check(wrap("", 100).equals(List.of("")), "Nothing is an empty line");
        check(wrap("a\n", 100).equals(List.of("a", "")), "A trailing break is an empty line");
        // A word wider than a row is cut after as many characters as fit; one at least.
        check(wrap("abcdefghij", 35).equals(List.of("abc", "def", "ghi", "j")), "A long word: " + wrap("abcdefghij", 35));
        check(wrap("abc", 1).equals(List.of("a", "b", "c")), "A row narrower than a character keeps one: " + wrap("abc", 1));
        check(wrap("ab cdefghij", 50).equals(List.of("ab", "cdefg", "hij")), "A long word after a short: " + wrap("ab cdefghij", 50));
        // Scripts written without spaces break between characters, but not beside a space.
        check(wrap("日本語日本語", 30).equals(List.of("日本語", "日本語")), "Han: " + wrap("日本語日本語", 30));
        check(wrap("ab日本", 30).equals(List.of("ab日", "本")), "Latin before Han: " + wrap("ab日本", 30));
        // A pair of surrogates is one character.
        String faces = "😀😀😀";
        check(wrap(faces, 45).equals(List.of("😀😀", "😀")), "Surrogates were cut in two: " + wrap(faces, 45));
        try { TextFits.wrap(TEN, "\n".repeat(600), 100); throw new AssertionError("600 lines were made"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("more than 512 lines"), expected.getMessage()); }
        check(TextFits.widest(TEN, TextFits.wrap(TEN, "hello world foo", 100)) == 90, "The widest line is wrong");
        check(TextFits.widest(TEN, new String[] { "", "" }) == 0, "Empty lines have a width");

        check(Arrays.equals(TextFits.fit(TEN, "hello world", 200, "..."), new Object[] { "hello world", false }), "Text that fits was cut");
        check(Arrays.equals(TextFits.fit(TEN, "hello world", 60, "..."), new Object[] { "hel...", true }), "The cut: " + Arrays.toString(TextFits.fit(TEN, "hello world", 60, "...")));
        check(Arrays.equals(TextFits.fit(TEN, "ab cd ef", 60, "..."), new Object[] { "ab...", true }), "The spaces at a cut stay: " + Arrays.toString(TextFits.fit(TEN, "ab cd ef", 60, "...")));
        check(Arrays.equals(TextFits.fit(TEN, "hello world", 60, "…"), new Object[] { "hello…", true }), "Another ellipsis");
        check(Arrays.equals(TextFits.fit(TEN, "hello world", 20, "..."), new Object[] { "", true }), "An ellipsis wider than the limit");
        check(Arrays.equals(TextFits.fit(TEN, "hello world", 30, "..."), new Object[] { "...", true }), "Only the ellipsis");
        check(Arrays.equals(TextFits.fit(TEN, "ab\ncd", 100, "..."), new Object[] { "ab", false }), "Only the first line");
        check(Arrays.equals(TextFits.fit(TEN, "", 10, "..."), new Object[] { "", false }), "Nothing is not cut");
        check(Arrays.equals(TextFits.fit(TEN, "😀😀😀", 50, "."), new Object[] { "😀😀.", true }),
            "A pair of surrogates was cut in two: " + Arrays.toString(TextFits.fit(TEN, "😀😀😀", 50, ".")));
        check(TextFits.wide('日') && TextFits.wide('ア') && TextFits.wide('Ａ') && !TextFits.wide('a') && !TextFits.wide('가'), "Wide characters");
    }

    /** Small is 8 pixels to a character in the synthetic game. */
    private static void named(KahluaTable text, Object mod, Object other) {
        List<Object> result = FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb cccc", 70.0);
        check(lines(result.get(0)).equals(List.of("aaaa", "bbbb", "cccc")) && result.get(1).equals(32.0), "wrap in Small: " + lines(result.get(0)) + " " + result.get(1));
        result = FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb cccc", 80.0);
        check(lines(result.get(0)).equals(List.of("aaaa bbbb", "cccc")) && result.get(1).equals(72.0), "wrap in Small at 80: " + lines(result.get(0)) + " " + result.get(1));
        result = FormulasTest.call(text, "wrap", mod, "Medium", "aaaa bbbb cccc", 80.0);
        check(lines(result.get(0)).equals(List.of("aaaa", "bbbb", "cccc")) && result.get(1).equals(44.0), "wrap in Medium: " + lines(result.get(0)) + " " + result.get(1));
        result = FormulasTest.call(text, "fit", mod, "Small", "hello world", 50.0);
        check(result.equals(List.of("hel...", true)), "fit: " + result);
        result = FormulasTest.call(text, "fit", mod, "Small", "hello", 50.0);
        check(result.equals(List.of("hello", false)), "fit of text that fits: " + result);
        result = FormulasTest.call(text, "fit", mod, "Small", "hello world", 50.0, "~");
        check(result.equals(List.of("hello~", true)), "fit with an ellipsis: " + result);
        result = FormulasTest.call(text, "fit", mod, "Small", "hello world", 5.0);
        check(result.equals(List.of("", true)), "fit in a width the ellipsis does not fit: " + result);
        // A Lua string is a Java string: the breaks and the lines are the same for another owner.
        result = FormulasTest.call(text, "wrap", other, "Small", "aaaa bbbb cccc", 70.0);
        check(lines(result.get(0)).equals(List.of("aaaa", "bbbb", "cccc")), "Another mod's wrap");
    }

    private static void caching(KahluaTable text, Object mod, Object other) {
        var cache = GameApi.texts().fits;
        cache.clear();
        long hits = cache.hits, misses = cache.misses;
        FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb cccc", 70.0);
        FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb cccc", 70.0);
        FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb cccc", 70.0);
        check(cache.misses == misses + 1 && cache.hits == hits + 2, "The same call was not kept: " + (cache.misses - misses) + " misses, " + (cache.hits - hits) + " hits");
        Object first = FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb cccc", 70.0).get(0);
        check(first == FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb cccc", 70.0).get(0), "A kept result was made again");
        // Each of what the call is made of is a key: the width, the font, the text, which call, the ellipsis, the owner.
        misses = cache.misses;
        FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb cccc", 71.0);
        FormulasTest.call(text, "wrap", mod, "Medium", "aaaa bbbb cccc", 70.0);
        FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb ccc", 70.0);
        FormulasTest.call(text, "fit", mod, "Small", "aaaa bbbb cccc", 70.0);
        FormulasTest.call(text, "fit", mod, "Small", "aaaa bbbb cccc", 70.0, "~");
        FormulasTest.call(text, "wrap", other, "Small", "aaaa bbbb cccc", 70.0);
        check(cache.misses == misses + 6, "Different calls were taken for the same: " + (cache.misses - misses));
        // The game makes its fonts again (the font size option): measured again, in the new.
        check(lines(FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb", 80.0).get(0)).equals(List.of("aaaa bbbb")), "Before");
        TextManager.instance.fonts.put(UIFont.Small, new AngelCodeFont(0xD7A3, 18, 10, false));
        try {
            List<Object> after = FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb", 80.0);
            check(lines(after.get(0)).equals(List.of("aaaa", "bbbb")) && after.get(1).equals(40.0), "A font made again was not measured again: " + lines(after.get(0)));
        } finally { TextManager.instance.reset(); }
        check(lines(FormulasTest.call(text, "wrap", mod, "Small", "aaaa bbbb", 80.0).get(0)).equals(List.of("aaaa bbbb")), "The game's own font after");
        // clear() takes away what a mod's calls kept, and only that.
        int size = cache.size();
        FormulasTest.call(other, "clear");
        check(cache.size() < size && cache.size() > 0, "clear() did not take one mod's results away: " + size + " -> " + cache.size());
        // The least recently used out: 512 at most.
        for (int index = 0; index < 700; index++) FormulasTest.call(text, "fit", mod, "Small", "text number " + index, 50.0);
        check(cache.size() == TextFits.CACHE, "The cache holds " + cache.size() + ", not " + TextFits.CACHE);
        long m = cache.misses;
        FormulasTest.call(text, "fit", mod, "Small", "text number 699", 50.0);
        check(cache.misses == m, "The most recent was gone");
        FormulasTest.call(text, "fit", mod, "Small", "text number 0", 50.0);
        check(cache.misses == m + 1, "The oldest was kept");
        FormulasTest.call(mod, "clear");
        check(cache.size() == 0, "clear() left results: " + cache.size());
    }

    private static void rejects(KahluaTable text, Object mod) {
        for (String name : new String[] { "wrap", "fit" }) {
            rejects(text, name, "the first argument must be a handle", "Small", "a", 10.0);
            rejects(text, name, "font must be what text.font returned or one of the game's font names", mod, "Comic", "a", 10.0);
            rejects(text, name, "font must be what text.font returned", mod, null, "a", 10.0);
            rejects(text, name, "font must be what text.font returned", mod, true, "a", 10.0);
            rejects(text, name, "key must be what text.font returned", mod, 20.5, "a", 10.0);
            rejects(text, name, "key must be what text.font returned", mod, 0.0, "a", 10.0);
            rejects(text, name, "text must be a string", mod, "Small", 5.0, 10.0);
            rejects(text, name, "text must be a string of at most 8192 characters", mod, "Small", "x".repeat(8193), 10.0);
            rejects(text, name, "width must be a whole number from 1 to 100000", mod, "Small", "a", 0.0);
            rejects(text, name, "width must be a whole number from 1 to 100000", mod, "Small", "a", 1.5);
            rejects(text, name, "width must be a whole number from 1 to 100000", mod, "Small", "a");
        }
        rejects(text, "fit", "ellipsis must be a string of at most 8 characters", mod, "Small", "a", 10.0, 5.0);
        rejects(text, "fit", "ellipsis must be a string of at most 8 characters", mod, "Small", "a", 10.0, "123456789");
        rejects(text, "wrap", "the text makes more than 512 lines", mod, "Small", "\n".repeat(600), 100.0);
    }

    private static void rejects(KahluaTable text, String name, String message, Object... arguments) {
        try { FormulasTest.call(text, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.text." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    /** What a call that was made before costs: the lookup, the key, and the arguments. Printed. */
    private static void cost(KahluaTable text, Object mod) {
        Object wrap = text.rawget("wrap");
        String words = "the quick brown fox jumps over the lazy dog and runs away from the farm";
        FormulasTest.call(text, "wrap", mod, "Small", words, 200.0);
        var arguments = new Object[] { mod, "Small", words, 200.0 };
        for (int warm = 0; warm < 20_000; warm++) FormulasTest.invoke(wrap, arguments);
        long bytes = allocated(), start = System.nanoTime();
        int rounds = 200_000;
        for (int n = 0; n < rounds; n++) FormulasTest.invoke(wrap, arguments);
        long time = System.nanoTime() - start;
        bytes = allocated() - bytes;
        System.out.printf("text.wrap: a call that was made before costs %.0f ns, %d bytes (the test's own frame included)%n", time / (double)rounds, bytes / rounds);
        // The same text measured every time it is asked: what the cache saves.
        var cache = GameApi.texts().fits;
        long m = cache.misses;
        FormulasTest.invoke(wrap, arguments);
        check(cache.misses == m, "The cost call missed");
        FormulasTest.call(mod, "clear");
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static List<Object> lines(Object table) {
        var result = new ArrayList<Object>();
        var lua = (KahluaTable)table;
        for (int index = 1; lua.rawget((double)index) != null; index++) result.add(lua.rawget((double)index));
        return result;
    }

    /** Called from the fonts test, where the language's fonts of a height are made: text.wrap and text.fit with a key from text.font. */
    static void keyed(KahluaTable text, Object mod, double key, int width) {
        // The game's Small (19): 9 pixels to a Hangul character.
        List<Object> result = FormulasTest.call(text, "wrap", mod, key, "가나다 가나다", 30.0);
        check(lines(result.get(0)).equals(List.of("가나다", "가나다")) && result.get(1).equals((double)width), "wrap with a key: " + lines(result.get(0)) + " " + result.get(1));
        result = FormulasTest.call(text, "fit", mod, key, "가나다라마", 40.0, "");
        check(result.equals(List.of("가나다라", true)), "fit with a key: " + result);
        check(FormulasTest.call(text, "wrap", mod, key, "가나다 가나다", 30.0).get(0) == FormulasTest.call(text, "wrap", mod, key, "가나다 가나다", 30.0).get(0),
            "A call with a key was not kept");
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }

}
