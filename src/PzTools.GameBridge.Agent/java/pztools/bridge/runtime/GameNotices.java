package pztools.bridge.runtime;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import pztools.bridge.AgentEntry;

/**
 * A short note over the player's head for what the app did at the player's request, such as a hotkey pressed in the
 * game. Built only from a fixed catalog of notes, each with at most one whole number, so no text from outside reaches
 * the game. The request returns at once; the note is shown on the game thread, through the per-frame relay.
 */
final class GameNotices {
    static final int MAXIMUM_ITEMS = 4;
    private static final long PATIENCE_NANOS = TimeUnit.SECONDS.toNanos(5);
    // The game counts this down in its own ticks; longer when several notes stand in one line.
    private static final float DURATION = 240.0f, LONG_DURATION = 400.0f;
    // Notes that say something did not happen, shown in the save notice's failure colour.
    private static final Set<String> WARNINGS = Set.of("save-last-failed", "save-last-none", "recording-failed", "backup-failed", "busy");
    private static final Map<String, Map<String, String>> CATALOG = load();
    private static final AtomicReference<Note> pending = new AtomicReference<>();
    private static volatile Method instance, setHaloNote;

    private record Note(String text, boolean warning, float duration, long expires) { }

    private GameNotices() { }

    static boolean handles(String command) { return command.equals("NOTICE"); }

    /** {@code NOTICE <language> <item> [<item> ...]}, each item {@code key} or {@code key:number}. */
    static synchronized String handle(String[] command) {
        try {
            if (command.length < 3 || command.length > 2 + MAXIMUM_ITEMS)
                return ProfileControl.error("protocol", "Invalid notice request");
            String[] items = java.util.Arrays.copyOfRange(command, 2, command.length);
            String text = compose(command[1], items);
            boolean warning = false;
            for (String item : items) warning |= WARNINGS.contains(key(item));
            prepare(AgentEntry.ensureGameHook().getClassLoader());
            // At the main menu, or between worlds, there is no one to show it to; the app says so another way.
            if (instance.invoke(null) == null) return ProfileControl.ok("no-player");
            pending.set(new Note(text, warning, items.length > 1 ? LONG_DURATION : DURATION, System.nanoTime() + PATIENCE_NANOS));
            ProfileControl.hookForNotice();
            return ProfileControl.ok("queued");
        } catch (IllegalArgumentException invalid) {
            return ProfileControl.error("protocol", String.valueOf(invalid.getMessage()));
        } catch (Throwable failure) {
            return ProfileControl.error("notice-failed", failure.getClass().getSimpleName());
        }
    }

    /** The note's text: each item's line in the language, joined. Refuses anything not in the catalog. */
    static String compose(String language, String[] items) {
        Map<String, String> lines = CATALOG.get(language);
        if (lines == null) throw new IllegalArgumentException("Unsupported notice language");
        if (items.length == 0 || items.length > MAXIMUM_ITEMS) throw new IllegalArgumentException("Invalid notice items");
        var text = new StringBuilder();
        for (String item : items) {
            String line = lines.get(key(item));
            if (line == null) throw new IllegalArgumentException("Unknown notice");
            int colon = item.indexOf(':');
            boolean wantsNumber = line.contains("{0}");
            if (wantsNumber != (colon > 0)) throw new IllegalArgumentException("Notice number mismatch");
            if (wantsNumber) {
                String number = item.substring(colon + 1);
                if (!number.matches("[0-9]{1,6}")) throw new IllegalArgumentException("Invalid notice number");
                line = line.replace("{0}", Integer.toString(Integer.parseInt(number)));
            }
            if (text.length() != 0) text.append(" · ");
            text.append(line);
        }
        return text.toString();
    }

    private static String key(String item) {
        int colon = item.indexOf(':');
        return colon < 0 ? item : item.substring(0, colon);
    }

    /** Game thread, each frame: one read while nothing waits. A note that waited too long is dropped. */
    static void tick() {
        if (pending.get() == null) return;
        Note note = pending.getAndSet(null);
        if (note == null || System.nanoTime() > note.expires) return;
        try {
            Object player = instance.invoke(null);
            if (player != null)
                setHaloNote.invoke(player, note.text, note.warning ? 255 : 180, note.warning ? 110 : 230,
                    note.warning ? 110 : 255, note.duration);
        } catch (Throwable ignored) {
            // A note is a courtesy; the game goes on whatever went wrong here.
        }
    }

    private static void prepare(ClassLoader loader) throws ReflectiveOperationException {
        if (setHaloNote != null) return;
        Class<?> players = Class.forName("zombie.characters.IsoPlayer", false, loader);
        instance = players.getMethod("getInstance");
        setHaloNote = players.getMethod("setHaloNote", String.class, int.class, int.class, int.class, float.class);
    }

    private static Map<String, Map<String, String>> load() {
        String[] rows = NoticeLanguageData.NOTICE_ROWS;
        var result = new HashMap<String, Map<String, String>>();
        if (rows.length == 0) return Map.of();
        String[] languages = rows[0].split("\t", -1);
        for (int column = 1; column < languages.length; column++) result.put(languages[column], new HashMap<>());
        for (int row = 1; row < rows.length; row++) {
            String[] fields = rows[row].split("\t", -1);
            if (fields.length != languages.length) throw new IllegalStateException("Invalid notice catalog");
            for (int column = 1; column < fields.length; column++) result.get(languages[column]).put(fields[0], fields[column]);
        }
        var frozen = new HashMap<String, Map<String, String>>();
        result.forEach((language, lines) -> frozen.put(language, Map.copyOf(lines)));
        frozen.put("ko", frozen.get("ko-KR"));
        frozen.put("en", frozen.get("en-US"));
        return Map.copyOf(frozen);
    }
}
