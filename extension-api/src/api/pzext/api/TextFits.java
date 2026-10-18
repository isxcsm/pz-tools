package pzext.api;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/**
 * {@code text.wrap} and {@code text.fit} (docs/design.md, "Wrapping and fitting a width"): a string broken into lines
 * no wider than a number of pixels, and a string cut to a width with an ellipsis, in a font a mod names, kept in a cache so that a
 * mod that lays out the same text every frame measures it once.
 *
 * <p>The breaking is the one {@code text.show} uses for its {@code width} ([typing, markup and fitting a width]): at a {@code \n}; before
 * a word that follows spaces (the spaces at the break are dropped); between two characters of the scripts written without spaces
 * (Han, kana, full-width forms), but not beside a space; and, for a word alone wider than a line, after as many of its characters as
 * fit, at least one. There is no hyphenation and no rule for punctuation at the start of a row.
 *
 * <p>What a width is comes from the font ({@link Width}), so that the algorithm is the same for the game's fonts and the API's. It
 * measures each candidate end of a row once, so a text of {@code n} words costs about {@code n} measures, and a cut costs a
 * binary search.
 */
final class TextFits {
    /** The longest text a call takes, in characters, and the most lines it makes. */
    static final int MAX_TEXT = 8192, MAX_LINES = 512;
    /** The longest ellipsis, in characters; the one used when a mod gives none. */
    static final int MAX_ELLIPSIS = 8;
    static final String ELLIPSIS = "...";
    /** How many results the cache keeps. */
    static final int CACHE = 512;

    private TextFits() { }

    /** The width in pixels of a text in the font a call named. */
    @FunctionalInterface interface Width { int of(String text) throws Throwable; }

    /** Whether the character is of a script written without spaces between words: a row may break beside it. */
    static boolean wide(char letter) {
        return letter >= 0x2E80 && letter <= 0x9FFF || letter >= 0xF900 && letter <= 0xFAFF || letter >= 0xFF00 && letter <= 0xFFEF;
    }

    /** The text as lines no wider than {@code limit} pixels (an empty paragraph is an empty line). A line a font cannot make narrow enough keeps one character. */
    static String[] wrap(Width width, String text, int limit) throws Throwable {
        var lines = new ArrayList<String>();
        for (int begin = 0; begin <= text.length();) {
            int end = text.indexOf('\n', begin);
            if (end < 0) end = text.length();
            int start = begin;
            do {
                int stop = start == end ? end : row(width, text, start, end, limit);
                lines.add(text.substring(start, stop));
                start = stop;
                // A row that was broken at spaces does not carry them over.
                if (stop < end) while (start < end && text.charAt(start) == ' ') start++;
            } while (start < end);
            begin = end + 1;
            if (lines.size() > MAX_LINES) throw new IllegalArgumentException("the text makes more than " + MAX_LINES + " lines");
        }
        return lines.toArray(new String[0]);
    }

    /** Where the row that starts at {@code start} ends: at the paragraph's end if that fits, else at the last break that does. */
    private static int row(Width width, String text, int start, int end, int limit) throws Throwable {
        if (width.of(text.substring(start, end)) <= limit) return end;
        int best = -1;
        for (int at = start + 1; at < end; at++) {
            // A break is before a word that follows spaces, or beside a character of a script written without them.
            if (text.charAt(at) == ' ' || text.charAt(at - 1) != ' ' && !wide(text.charAt(at - 1)) && !wide(text.charAt(at))) continue;
            int stop = at;
            while (stop > start && text.charAt(stop - 1) == ' ') stop--;
            if (stop == start) continue;
            if (width.of(text.substring(start, stop)) > limit) break;
            best = stop;
        }
        if (best >= 0) return best;
        // A word wider than the row: as many of its characters as fit, one at least (a pair of surrogates is one).
        int stop = start + Character.charCount(text.codePointAt(start));
        while (stop < end) {
            int next = stop + Character.charCount(text.codePointAt(stop));
            if (width.of(text.substring(start, next)) > limit) break;
            stop = next;
        }
        return stop;
    }

    /** The widest of the lines, in pixels. */
    static int widest(Width width, String[] lines) throws Throwable {
        int widest = 0;
        for (String line : lines) if (!line.isEmpty()) widest = Math.max(widest, width.of(line));
        return widest;
    }

    /**
     * The text, or its beginning and the ellipsis when it is wider than {@code limit}: the most characters (spaces at the cut taken
     * away) that go with the ellipsis within it. Only the first line of a text with line breaks is taken. When not even the ellipsis
     * fits, the result is empty. The second result says whether it was cut.
     */
    static Object[] fit(Width width, String text, int limit, String ellipsis) throws Throwable {
        int newline = text.indexOf('\n');
        String line = newline < 0 ? text : text.substring(0, newline);
        if (line.isEmpty() || width.of(line) <= limit) return new Object[] { line, false };
        if (width.of(ellipsis) > limit) return new Object[] { "", true };
        // The largest number of characters that fit with the ellipsis: the width grows with the characters.
        int low = 0, high = line.length();
        while (low < high) {
            int middle = (low + high + 1) >>> 1;
            if (width.of(trim(line, middle) + ellipsis) <= limit) low = middle; else high = middle - 1;
        }
        return new Object[] { trim(line, low) + ellipsis, true };
    }

    /** The first {@code count} characters, without a pair of surrogates cut in two and without the spaces at the end. */
    private static String trim(String line, int count) {
        if (count > 0 && count < line.length() && Character.isHighSurrogate(line.charAt(count - 1))) count--;
        while (count > 0 && line.charAt(count - 1) == ' ') count--;
        return line.substring(0, count);
    }

    // ---- the cache ----

    /** What a call asked: who, the font, the limit, which of the two, the ellipsis, and the text. */
    record Key(String owner, Object font, int limit, boolean wrap, String ellipsis, String text) {
        static int hash(String owner, Object font, int limit, boolean wrap, String ellipsis, String text) {
            int hash = owner.hashCode();
            hash = hash * 31 + font.hashCode();
            hash = hash * 31 + limit;
            hash = hash * 31 + (wrap ? 1 : 0);
            hash = hash * 31 + (ellipsis == null ? 0 : ellipsis.hashCode());
            return hash * 31 + text.hashCode();
        }

        @Override public int hashCode() { return hash(owner, font, limit, wrap, ellipsis, text); }
    }

    /** A question put to the cache without making a {@link Key}: it equals the key of the same fields. */
    private static final class Probe {
        String owner, ellipsis, text;
        Object font;
        int limit;
        boolean wrap;

        @Override public int hashCode() { return Key.hash(owner, font, limit, wrap, ellipsis, text); }

        @Override public boolean equals(Object other) {
            return other instanceof Key key && key.limit() == limit && key.wrap() == wrap && key.owner().equals(owner) && key.font().equals(font)
                && Objects.equals(key.ellipsis(), ellipsis) && key.text().equals(text);
        }
    }

    /**
     * A result and what it was measured with: the choices the font gave, which differ once the game makes its fonts again. A hit whose
     * measure differs is measured again. The answer is the function's results, the same array for every call that hits (nothing changes it).
     */
    record Result(Object[] measuredWith, Object[] answer) {
        /** A wrap's result: the lines and the widest of them. */
        static Result wrapped(Object[] measuredWith, Object lines, double widest) { return new Result(measuredWith, new Object[] { lines, widest }); }

        /** A fit's result: the text and whether it was cut. */
        static Result cut(Object[] measuredWith, Object text, boolean cut) { return new Result(measuredWith, new Object[] { text, cut }); }

        boolean valid(Object[] now) {
            if (now.length != measuredWith.length) return false;
            for (int index = 0; index < now.length; index++) if (!Objects.equals(now[index], measuredWith[index])) return false;
            return true;
        }
    }

    /** The results of the last {@link #CACHE} calls, least recently used out first. */
    static final class Cache {
        private final LinkedHashMap<Key, Result> entries = new LinkedHashMap<>(64, 0.75f, true) {
            @Override protected boolean removeEldestEntry(Map.Entry<Key, Result> eldest) { return size() > CACHE; }
        };
        private final Probe probe = new Probe();
        long hits, misses;

        /** The result kept for the question if it was measured with the same; nothing is allocated for it. */
        Result get(String owner, Object font, int limit, boolean wrap, String ellipsis, String text, Object[] measuredWith) {
            probe.owner = owner; probe.font = font; probe.limit = limit; probe.wrap = wrap; probe.ellipsis = ellipsis; probe.text = text;
            Result found = entries.get(probe);
            if (found != null && found.valid(measuredWith)) { hits++; return found; }
            misses++;
            return null;
        }

        void put(Key key, Result entry) { entries.put(key, entry); }

        /** Takes away what an owner's calls kept. */
        void drop(String owner) { entries.keySet().removeIf(key -> key.owner().equals(owner)); }

        void clear() { entries.clear(); }

        int size() { return entries.size(); }
    }
}
