package pztools.startup;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;

/**
 * Edits the {@code classpath} list of the game's launcher file ({@code ProjectZomboid64.json}) as text, by one entry,
 * and nothing else: every other byte of the file stays (its layout, its other entries, other tools' lines). Tools that
 * rewrite that file (pzopt's AOT step drops {@code .} from the class path and keeps every other entry, in order) keep an
 * entry added after the game's jar, and a reset by Steam brings the plain file back; the loader adds its entry back
 * when it is missing (docs/design/startup-loader.md).
 *
 * <p>Uses java.base alone, like {@link StartupLoader}; it is part of the loader's files, in the game's folder and in the jar.
 */
public final class Launcher {
    /** The launcher file, in the game's folder. */
    public static final String FILE = "ProjectZomboid64.json";

    private final String text;
    private final List<String> values = new ArrayList<>();
    private final List<int[]> spans = new ArrayList<>();   // {gap start, element start, element end}
    private int open, close;

    private Launcher(String text) { this.text = text; }

    // ---- the text ----

    /** The class path list of the launcher text, or null when the text has none this can read (a list of plain strings). */
    public static Launcher parse(String text) {
        try { return scan(text); }
        catch (RuntimeException unreadable) { return null; }
    }

    private static Launcher scan(String text) {
        int length = text.length(), depth = 0;
        for (int index = 0; index < length; ) {
            char c = text.charAt(index);
            if (c == '"') {
                int end = stringEnd(text, index);
                if (depth == 1 && text.startsWith("\"classpath\"", index)) {
                    int after = skip(text, end);
                    if (after < length && text.charAt(after) == ':') {
                        int list = skip(text, after + 1);
                        if (list < length && text.charAt(list) == '[') return elements(text, list);
                        return null;
                    }
                }
                index = end;
            } else if (c == '/' && index + 1 < length && (text.charAt(index + 1) == '/' || text.charAt(index + 1) == '*')) {
                index = skip(text, index);
            } else {
                if (c == '{' || c == '[') depth++;
                else if (c == '}' || c == ']') depth--;
                index++;
            }
        }
        return null;
    }

    private static Launcher elements(String text, int open) {
        var list = new Launcher(text);
        list.open = open;
        int length = text.length(), index = skip(text, open + 1), gap = open + 1;
        if (index < length && text.charAt(index) == ']') { list.close = index; return list; }
        while (true) {
            if (index >= length || text.charAt(index) != '"') return null;
            int end = stringEnd(text, index);
            list.values.add(decode(text.substring(index + 1, end - 1)));
            list.spans.add(new int[] { gap, index, end });
            index = skip(text, end);
            if (index >= length) return null;
            char c = text.charAt(index);
            if (c == ']') { list.close = index; return list; }
            if (c != ',') return null;
            gap = index + 1;
            index = skip(text, gap);
        }
    }

    /** The index after the string that starts at {@code start}. */
    private static int stringEnd(String text, int start) {
        for (int index = start + 1; index < text.length(); index++) {
            char c = text.charAt(index);
            if (c == '\\') index++;
            else if (c == '"') return index + 1;
            else if (c == '\n' || c == '\r') break;
        }
        throw new IllegalArgumentException("unterminated string");
    }

    /** Past white space and comments. */
    private static int skip(String text, int index) {
        int length = text.length();
        while (index < length) {
            char c = text.charAt(index);
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '﻿') index++;
            else if (c == '/' && text.startsWith("//", index)) {
                int end = text.indexOf('\n', index);
                index = end < 0 ? length : end + 1;
            } else if (c == '/' && text.startsWith("/*", index)) {
                int end = text.indexOf("*/", index + 2);
                if (end < 0) throw new IllegalArgumentException("unterminated comment");
                index = end + 2;
            } else break;
        }
        return index;
    }

    private static String decode(String body) {
        if (body.indexOf('\\') < 0) return body;
        var out = new StringBuilder();
        for (int index = 0; index < body.length(); index++) {
            char c = body.charAt(index);
            if (c != '\\') { out.append(c); continue; }
            char escape = body.charAt(++index);
            switch (escape) {
                case 'b' -> out.append('\b');
                case 'f' -> out.append('\f');
                case 'n' -> out.append('\n');
                case 'r' -> out.append('\r');
                case 't' -> out.append('\t');
                case 'u' -> { out.append((char) Integer.parseInt(body.substring(index + 1, index + 5), 16)); index += 4; }
                default -> out.append(escape);
            }
        }
        return out.toString();
    }

    private static String quote(String entry) {
        return "\"" + entry.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    public boolean contains(String entry) { return values.contains(entry); }

    /** The text with {@code entry} at the end of the class path, laid out as the entry before it; the text itself if it is there. */
    public String with(String entry) {
        if (contains(entry)) return text;
        if (values.isEmpty()) return text.substring(0, open + 1) + quote(entry) + text.substring(open + 1);
        int[] last = spans.getLast();
        String gap = text.substring(last[0], last[1]);
        if (!gap.isBlank()) gap = " ";
        return text.substring(0, last[2]) + "," + gap + quote(entry) + text.substring(last[2]);
    }

    /** The text without any {@code entry} (and the comma and white space that went with it); the text itself if it is not there. */
    public String without(String entry) {
        int found = values.lastIndexOf(entry);
        if (found < 0) return text;
        String result;
        if (found + 1 < values.size()) result = text.substring(0, spans.get(found)[1]) + text.substring(spans.get(found + 1)[1]);
        else if (found > 0) result = text.substring(0, spans.get(found - 1)[2]) + text.substring(spans.get(found)[2]);
        else result = text.substring(0, spans.get(found)[1]) + text.substring(spans.get(found)[2]);
        Launcher rest = parse(result);
        return rest == null ? result : rest.without(entry);
    }

    // ---- the file ----

    /** What the launcher file says of the entry: {@code listed}, {@code absent}, {@code none} (no file) or {@code unreadable}. */
    public static String state(Path file, String entry) {
        try {
            String text = read(file);
            if (text == null) return "none";
            Launcher list = parse(text);
            return list == null ? "unreadable" : list.contains(entry) ? "listed" : "absent";
        } catch (IOException | RuntimeException unreadable) { return "unreadable"; }
    }

    /**
     * Puts the entry at the end of the file's class path unless it is there. Returns {@code listed} (it was),
     * {@code added}, {@code none} (no file) or {@code unreadable} (a file with no class path list this can edit).
     * The file is read again and replaced in one move, so a tool that edits it too loses at most its own latest change.
     */
    public static String ensure(Path file, String entry) throws IOException {
        String text = read(file);
        if (text == null) return "none";
        Launcher list = parse(text);
        if (list == null) return "unreadable";
        if (list.contains(entry)) return "listed";
        write(file, list.with(entry));
        return "added";
    }

    /** Removes the entry from the file's class path. Returns {@code removed}, {@code absent}, {@code none} or {@code unreadable}. */
    public static String drop(Path file, String entry) throws IOException {
        String text = read(file);
        if (text == null) return "none";
        Launcher list = parse(text);
        if (list == null) return "unreadable";
        if (!list.contains(entry)) return "absent";
        write(file, list.without(entry));
        return "removed";
    }

    /** The file's text, or null when there is no regular file or it is not UTF-8. */
    private static String read(Path file) throws IOException {
        if (!Files.isRegularFile(file)) return null;
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(Files.readAllBytes(file))).toString();
        } catch (CharacterCodingException notText) { return null; }
    }

    private static void write(Path file, String text) throws IOException {
        Path staged = Files.createTempFile(file.toAbsolutePath().getParent(), file.getFileName().toString(), ".pztools-tmp");
        try {
            Files.write(staged, text.getBytes(StandardCharsets.UTF_8));
            try { Files.move(staged, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); }
            catch (AtomicMoveNotSupportedException plain) { Files.move(staged, file, StandardCopyOption.REPLACE_EXISTING); }
        } finally { Files.deleteIfExists(staged); }
    }
}
