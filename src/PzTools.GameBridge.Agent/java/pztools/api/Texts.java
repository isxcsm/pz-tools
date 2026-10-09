package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.util.*;
import java.util.function.Supplier;
import pztools.bridge.ApiHooks;

/**
 * {@code PZToolsAPI.text}: text a mod shows on the screen (docs/design/extension-api.md, "Text"), and titles: a large line in
 * the middle of the screen, with a smaller one under it, in one of a few styles, one after the other. The game's own text
 * drawing does it ({@code TextManager.DrawString} with a zoom, through the game's distance-field shader for the fonts made for
 * it), from a hook in {@code UIManager.render} once the interface's windows are drawn: so the text is drawn with the interface,
 * on each local player's part of the screen, and nothing runs in Lua for it. With nothing shown the hook returns at once.
 *
 * <p>What is shown belongs to the world it was shown in, and is kept in the API table's metatable for a newer API to take over,
 * as the moodles are. Everything here runs on the game's main thread: the mods' calls, the frame job and the drawing.
 */
final class Texts implements ApiHooks.Text {
    private static final String AREA = "PZToolsAPI.text.";
    private static final String MIRROR = "texts", FORMAT = "pztools-texts 1", GENERATION = "textsGeneration", HANDOVER = "textsHandover";
    /** The hook that draws, as {@code PZToolsAPI.hooks()} names it. */
    static final String HOOK = "UIManager.render:text";
    static final int PLAYERS = 4, MAX_LINES = 8, MAX_LENGTH = 512, MAX_PER_MOD = 64, MAX_ALL = 256, MAX_WAITING = 8;
    static final double MAX_SECONDS = 30, MAX_HOLD = 3600, MAX_SCALE = 20, MAX_SIZE = 0.5, MAX_OUTLINE = 8;
    // A text whose alpha is below this is not drawn.
    private static final float INVISIBLE = 0.002f;
    // How far the rising and sinking effects move, in the text's line heights.
    private static final double RISE = 0.75, DRIFT = 0.5;
    private static final double SECOND = 1e9;

    /** How a text comes onto the screen. */
    enum Enter { NONE, FADE, POP, SLAM, RISE, DROP }

    /** How it goes. */
    enum Leave { NONE, FADE, RISE, SINK, GROW, SHRINK }

    private static final Map<String, Integer> ALIGN = Map.of("left", -1, "center", 0, "right", 1);
    private static final String[] ALIGN_NAMES = { "left", "center", "right" };

    /** One text on the screen, or waiting for its turn in a player's queue of titles. */
    static final class Shown {
        final String owner;
        final long key;
        // The lines, the font's name and the game's font (UIFont); the share of the screen's height a line is, or the zoom.
        String[] lines;
        String fontName;
        Object font;
        double scale = 1, size;
        float red = 1, green = 1, blue = 1, alpha = 1, outline, outlineRed, outlineGreen, outlineBlue, outlineAlpha = 1;
        boolean shadow;
        double x = 0.5, y = 0.5;
        int align;
        double delay, enterTime, hold = Double.POSITIVE_INFINITY, leaveTime;
        Enter enter = Enter.NONE;
        Leave leave = Leave.NONE;
        // The local player whose screen it is on; -1 for every local player's.
        int player = -1;
        // Waits for the queue of its player's screen; waiting until it is the first of that queue.
        boolean queued, waiting;
        // The world it was shown in.
        Object cell;
        // When it was first drawn (System.nanoTime), 0 before; when its mod hid it, 0 if it did not.
        long start, hidden;
        boolean done;
        // The widths of the lines and the height of one at zoom 1, as measured with the game's font (AngelCodeFont) they were for.
        Object measuredWith;
        float[] widths;
        float lineHeight;

        Shown(String owner, long key) { this.owner = owner; this.key = key; }
    }

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    private final Players players;
    // The game's fonts (UIFont) by name.
    private final Map<String, Object> fonts = new LinkedHashMap<>();
    private final Object textManager;
    // TextManager.DrawString(font, x, y, zoom, text, r, g, b, a), MeasureStringX, getFontHeight, isSdf, getFontFromEnum.
    private final MethodHandle drawString, measure, fontHeight, sdf, fontOf;
    private final Field glyphs, sdfShader;
    // SDFShader.updateThreshold, updateShadow, updateOutline; IndieGL.StartShader(shader), EndShader().
    private final MethodHandle threshold, shaderShadow, shaderOutline, startShader, endShader;
    // IsoCamera.getScreenLeft, getScreenTop, getScreenWidth, getScreenHeight of a player; Core.getInstance(), its screen's size.
    private final MethodHandle screenLeft, screenTop, screenWidth, screenHeight, core, coreWidth, coreHeight;
    // What is shown, in the order it was shown: changed on the game's thread and read by the drawing, on the same thread.
    private final ArrayList<Shown> shown = new ArrayList<>();
    private volatile Shown[] drawn = new Shown[0];
    private long next = 1;
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private boolean dirty, reported;
    private long generation;
    /** The clock the effects run on (System.nanoTime: the interface's time, which goes on while the game is paused); for the tests. */
    java.util.function.LongSupplier clock = System::nanoTime;

    Texts(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        players = new Players(loader);
        Class<?> font = Game.type(loader, "zombie.ui.UIFont");
        for (Object constant : font.getEnumConstants()) fonts.put(((Enum<?>)constant).name(), constant);
        Class<?> manager = Game.type(loader, "zombie.ui.TextManager");
        textManager = manager.getField("instance").get(null);
        if (textManager == null) throw new IllegalStateException("the game has no TextManager");
        drawString = Game.exact(manager.getMethod("DrawString", font, double.class, double.class, double.class, String.class, double.class,
            double.class, double.class, double.class), MethodType.methodType(void.class, Object.class, Object.class, double.class, double.class,
            double.class, String.class, double.class, double.class, double.class, double.class));
        measure = Game.exact(manager.getMethod("MeasureStringX", font, String.class), MethodType.methodType(int.class, Object.class, Object.class, String.class));
        fontHeight = Game.exact(manager.getMethod("getFontHeight", font), MethodType.methodType(int.class, Object.class, Object.class));
        sdf = Game.exact(manager.getMethod("isSdf", font), MethodType.methodType(boolean.class, Object.class, Object.class));
        fontOf = Game.exact(manager.getMethod("getFontFromEnum", font), MethodType.methodType(Object.class, Object.class, Object.class));
        glyphs = Game.type(loader, "zombie.core.fonts.AngelCodeFont").getField("chars");
        sdfShader = manager.getField("sdfShader");
        Class<?> distance = Game.type(loader, "zombie.core.opengl.SDFShader"), shader = Game.type(loader, "zombie.core.opengl.Shader");
        threshold = Game.exact(distance.getMethod("updateThreshold", float.class), MethodType.methodType(void.class, Object.class, float.class));
        shaderShadow = Game.exact(distance.getMethod("updateShadow", float.class), MethodType.methodType(void.class, Object.class, float.class));
        shaderOutline = Game.exact(distance.getMethod("updateOutline", float.class, float.class, float.class, float.class, float.class),
            MethodType.methodType(void.class, Object.class, float.class, float.class, float.class, float.class, float.class));
        Class<?> indie = Game.type(loader, "zombie.IndieGL");
        startShader = Game.exact(indie.getMethod("StartShader", shader), MethodType.methodType(void.class, Object.class));
        endShader = Game.exact(indie.getMethod("EndShader"), MethodType.methodType(void.class));
        Class<?> camera = Game.type(loader, "zombie.iso.IsoCamera");
        MethodType side = MethodType.methodType(int.class, int.class);
        screenLeft = Game.exact(camera.getMethod("getScreenLeft", int.class), side);
        screenTop = Game.exact(camera.getMethod("getScreenTop", int.class), side);
        screenWidth = Game.exact(camera.getMethod("getScreenWidth", int.class), side);
        screenHeight = Game.exact(camera.getMethod("getScreenHeight", int.class), side);
        Class<?> coreType = Game.type(loader, "zombie.core.Core");
        core = Game.exact(coreType.getMethod("getInstance"), MethodType.methodType(Object.class));
        coreWidth = Game.exact(coreType.getMethod("getScreenWidth"), MethodType.methodType(int.class, Object.class));
        coreHeight = Game.exact(coreType.getMethod("getScreenHeight"), MethodType.methodType(int.class, Object.class));
        // The API this one replaces writes what it shows where this one finds it.
        if (lua.get(meta, HANDOVER) instanceof Supplier<?> earlier) {
            try { earlier.get(); }
            catch (RuntimeException | LinkageError failure) {
                System.err.println("[PzTools API] text: the earlier API did not hand it over: " + failure);
            }
        }
        world = game.cell();
        load(lua.get(meta, MIRROR));
        dirty = false;
    }

    /** Gives the game's interface drawing to this text. Throws a LinkageError in a game whose bootstrap has no text hook. */
    void hook() { ApiHooks.setText(this); }

    /** The game draws no text of the API's. */
    static void unhook() {
        try { ApiHooks.setText(null); } catch (LinkageError olderBootstrap) { }
    }

    /** No text runs in the environment any more: the functions mods kept refuse to be called; what is shown stays for a later API. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    /** Whether the hook that draws is in the game's {@code UIManager}: applied, not-loaded, or why not. */
    static String status() {
        try { return ApiHooks.hookStatus().getOrDefault(HOOK, ApiHooks.NOT_LOADED); }
        catch (LinkageError olderBootstrap) { return "this game's bootstrap has no text hook; restart the game"; }
    }

    // ---- the Lua surface ----

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Exception; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            current(call);
            return body.call(call, arguments);
        }));
    }

    /** Refuses a call into text that a newer API took over, or that stopped: the mod kept the function. */
    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZToolsAPI");
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        lua.set(meta, HANDOVER, (Supplier<String>)this::handover);
        function(table, "show", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object spec = arguments.length > 1 ? arguments[1] : null;
            if (!lua.isTable(spec)) throw new IllegalArgumentException(call + ": spec must be a table, such as { text = \"Hello\", font = \"Large\", hold = 3 }");
            Shown text = new Shown(owner, next);
            read(text, spec, call, "spec");
            if (text.lines == null) throw new IllegalArgumentException(call + ": spec.text must be a string of 1 to " + MAX_LENGTH + " characters");
            room(owner, text.queued && text.player < 0 ? screens() : 1, call);
            next++;
            add(text);
            return new Object[] { (double)text.key };
        });
        function(table, "title", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object spec = arguments.length > 1 ? arguments[1] : null;
            if (!lua.isTable(spec)) throw new IllegalArgumentException(call + ": spec must be a table, such as { text = \"Quest complete\", style = \"stamp\" }");
            long key = title(owner, spec, call);
            return new Object[] { (double)key };
        });
        function(table, "hide", (call, arguments) -> {
            String owner = owner(arguments, call);
            long key = key(arguments, call);
            boolean now = arguments.length > 2 && Boolean.TRUE.equals(arguments[2]);
            return new Object[] { hide(owner, key, now, clock.getAsLong()) };
        });
        function(table, "shown", (call, arguments) -> {
            String owner = owner(arguments, call);
            long key = key(arguments, call);
            for (Shown text : shown) if (text.owner.equals(owner) && text.key == key && !text.done) return new Object[] { true };
            return new Object[] { false };
        });
        function(table, "styles", (call, arguments) -> new Object[] { lua.list(List.copyOf(Styles.ALL.keySet())) });
        function(table, "status", (call, arguments) -> new Object[] { status() });
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZToolsAPI.client");
        return owner;
    }

    private static long key(Object[] arguments, String call) {
        Object value = arguments.length > 1 ? arguments[1] : null;
        if (!(value instanceof Double number) || number != Math.rint(number) || number < 1)
            throw new IllegalArgumentException(call + ": key must be what show or title returned");
        return number.longValue();
    }

    /** Refuses a text beyond what one mod, or all of them, may have on the screen at once. */
    private void room(String owner, int adding, String call) {
        int own = 0, all = 0;
        for (Shown text : shown) if (!text.done) { all++; if (text.owner.equals(owner)) own++; }
        if (own + adding > MAX_PER_MOD) throw new IllegalArgumentException(call + ": the mod has " + own + " texts shown or waiting; at most " + MAX_PER_MOD);
        if (all + adding > MAX_ALL) throw new IllegalArgumentException(call + ": the mods have " + all + " texts shown or waiting; at most " + MAX_ALL);
    }

    /** The number of screens a text for every local player goes on: each local player's, or the one screen without any. */
    private int screens() {
        int count = 0;
        for (Object player : players.all()) if (player != null) count++;
        return Math.max(count, 1);
    }

    /**
     * Reads a text's spec, its fields named under {@code prefix} in the messages; a field the call does not take is a Lua error.
     */
    private void read(Shown text, Object spec, String call, String prefix) throws ReflectiveOperationException {
        for (var entry : lua.entries(spec)) {
            if (!(entry.getKey() instanceof String field)) throw new IllegalArgumentException(call + ": " + prefix + " has a field that is not a name");
            Object value = entry.getValue();
            String name = prefix + "." + field;
            switch (field) {
                case "text" -> text.lines = lines(value, call, name);
                case "font" -> font(text, value, call, name);
                case "scale" -> text.scale = number(value, call, name, 0.05, MAX_SCALE);
                case "size" -> text.size = number(value, call, name, 0.005, MAX_SIZE);
                case "color" -> {
                    float[] color = color(value, call, name);
                    text.red = color[0]; text.green = color[1]; text.blue = color[2]; text.alpha = color[3];
                }
                case "x" -> text.x = number(value, call, name, 0, 1);
                case "y" -> text.y = number(value, call, name, 0, 1);
                case "align" -> {
                    Integer align = value instanceof String word ? ALIGN.get(word) : null;
                    if (align == null) throw new IllegalArgumentException(call + ": " + name + " must be \"left\", \"center\" or \"right\"");
                    text.align = align;
                }
                case "shadow" -> {
                    if (!(value instanceof Boolean on)) throw new IllegalArgumentException(call + ": " + name + " must be true or false");
                    text.shadow = on;
                }
                case "outline" -> text.outline = (float)number(value, call, name, 0, MAX_OUTLINE);
                case "outlineColor" -> {
                    float[] color = color(value, call, name);
                    text.outlineRed = color[0]; text.outlineGreen = color[1]; text.outlineBlue = color[2]; text.outlineAlpha = color[3];
                }
                case "delay" -> text.delay = number(value, call, name, 0, MAX_SECONDS);
                case "enter" -> text.enter = effect(Enter.class, value, call, name);
                case "enterTime" -> text.enterTime = number(value, call, name, 0, MAX_SECONDS);
                case "hold" -> text.hold = number(value, call, name, 0, MAX_HOLD);
                case "leave" -> text.leave = effect(Leave.class, value, call, name);
                case "leaveTime" -> text.leaveTime = number(value, call, name, 0, MAX_SECONDS);
                case "player" -> text.player = player(value, call, name);
                case "queue" -> {
                    if (!(value instanceof Boolean on)) throw new IllegalArgumentException(call + ": " + name + " must be true or false");
                    text.queued = on;
                }
                default -> throw new IllegalArgumentException(call + ": " + prefix + " has no field " + field + "; it takes text, font, scale, size,"
                    + " color, x, y, align, shadow, outline, outlineColor, delay, enter, enterTime, hold, leave, leaveTime, player and queue");
            }
        }
        if (text.lines != null && text.font == null) font(text, "Large", call, prefix + ".font");
        else if (text.lines != null && text.fontName == null) font(text, text.font, call, prefix + ".font");
    }

    private String[] lines(Object value, String call, String name) {
        if (!(value instanceof String text) || text.isEmpty() || text.length() > MAX_LENGTH)
            throw new IllegalArgumentException(call + ": " + name + " must be a string of 1 to " + MAX_LENGTH + " characters");
        String[] lines = text.replace("\r\n", "\n").split("\n", -1);
        if (lines.length > MAX_LINES) throw new IllegalArgumentException(call + ": " + name + " has " + lines.length + " lines; at most " + MAX_LINES);
        for (int index = 0; index < lines.length; index++) lines[index] = lines[index].replace('\t', ' ');
        return lines;
    }

    /**
     * The font: one of the game's names (UIFont), or a list of them, of which the first that has every character of the text is
     * used (the last when none has). The game's distance-field fonts (Sdf...) scale cleanly but have Latin and Cyrillic letters
     * alone; its other fonts are the language's, and blur when zoomed. Kept as given until the text is known (any order of fields).
     */
    private void font(Shown text, Object value, String call, String name) throws ReflectiveOperationException {
        var names = new ArrayList<String>();
        if (value instanceof String one) names.add(one);
        else if (lua.isTable(value)) {
            for (int index = 1;; index++) {
                Object item = lua.get(value, (double)index);
                if (item == null) break;
                if (!(item instanceof String one)) throw new IllegalArgumentException(call + ": " + name + "[" + index + "] must be a font's name");
                names.add(one);
            }
        } else if (value instanceof List<?> list) for (Object item : list) names.add((String)item);
        if (names.isEmpty() || names.size() > 8) throw new IllegalArgumentException(call + ": " + name + " must be a font's name, or a list of 1 to 8");
        for (String font : names)
            if (!fonts.containsKey(font)) throw new IllegalArgumentException(call + ": " + name + ": the game has no font " + font + "; it has " + String.join(", ", fonts.keySet()));
        if (text.lines == null) { text.font = List.copyOf(names); return; }
        String chosen = names.get(names.size() - 1);
        for (String font : names) if (covers(fonts.get(font), text.lines)) { chosen = font; break; }
        text.fontName = chosen;
        text.font = fonts.get(chosen);
    }

    /** Whether the game's font has a character for every one of the lines' (spaces aside). */
    private boolean covers(Object font, String[] lines) throws ReflectiveOperationException {
        Object angel;
        try { angel = (Object)fontOf.invokeExact(textManager, font); }
        catch (Throwable failure) { throw Game.thrown(failure); }
        if (angel == null) return false;
        Object[] defined = (Object[])glyphs.get(angel);
        if (defined == null) return false;
        for (String line : lines)
            for (int index = 0; index < line.length(); index++) {
                char letter = line.charAt(index);
                if (letter <= ' ') continue;
                if (letter >= defined.length || defined[letter] == null) return false;
            }
        return true;
    }

    private static double number(Object value, String call, String name, double min, double max) {
        if (!(value instanceof Double number) || !(number >= min && number <= max))
            throw new IllegalArgumentException(call + ": " + name + " must be a number from " + trim(min) + " to " + trim(max));
        return number;
    }

    private static String trim(double value) { return value == Math.rint(value) ? Long.toString((long)value) : Double.toString(value); }

    /** A colour: { r, g, b, a } or { r = , g = , b = , a = }, each from 0 to 1; a is 1 when left out. */
    private float[] color(Object value, String call, String name) throws ReflectiveOperationException {
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": " + name + " must be a table { r, g, b, a } of numbers from 0 to 1");
        float[] color = { 0, 0, 0, 1 };
        String[] keys = { "r", "g", "b", "a" };
        boolean named = lua.get(value, "r") != null;
        for (int index = 0; index < 4; index++) {
            Object part = named ? lua.get(value, keys[index]) : lua.get(value, (double)(index + 1));
            if (part == null && index == 3) continue;
            if (!(part instanceof Double number) || !(number >= 0 && number <= 1))
                throw new IllegalArgumentException(call + ": " + name + " must be a table { r, g, b, a } of numbers from 0 to 1");
            color[index] = (float)(double)number;
        }
        return color;
    }

    private static <E extends Enum<E>> E effect(Class<E> type, Object value, String call, String name) {
        if (value instanceof String word)
            for (E effect : type.getEnumConstants()) if (effect.name().toLowerCase(Locale.ENGLISH).equals(word)) return effect;
        var names = new StringJoiner(", ");
        for (E effect : type.getEnumConstants()) names.add("\"" + effect.name().toLowerCase(Locale.ENGLISH) + "\"");
        throw new IllegalArgumentException(call + ": " + name + " must be one of " + names);
    }

    private static int player(Object value, String call, String name) {
        if (!(value instanceof Double number) || number != Math.rint(number) || number < 0 || number > PLAYERS - 1)
            throw new IllegalArgumentException(call + ": " + name + " must be a player index from 0 to 3, or nil for every local player");
        return number.intValue();
    }

    /** Shows the text: one for each local player when it is for every player and queued (each player's screen has its queue). */
    private void add(Shown text) throws ReflectiveOperationException {
        text.cell = game.cell();
        if (!text.queued) { shown.add(text); publish(); dirty = true; return; }
        if (text.player >= 0) enqueue(List.of(text), false);
        else {
            boolean any = false;
            for (int index = 0; index < players.all().length && index < PLAYERS; index++) if (players.all()[index] != null) {
                any = true;
                Shown copy = copy(text);
                copy.player = index;
                enqueue(List.of(copy), false);
            }
            if (!any) { text.player = 0; enqueue(List.of(text), false); }
        }
    }

    /**
     * Puts a group (a title and the line under it, all for one player) at the end of its player's queue, or at its head with
     * {@code first}; when the queue is full, the oldest waiting group goes.
     */
    private void enqueue(List<Shown> group, boolean first) {
        int player = group.get(0).player;
        var waiting = new LinkedHashSet<Long>();
        for (Shown text : shown) if (text.queued && text.waiting && text.player == player && !text.done) waiting.add(text.key);
        if (waiting.size() >= MAX_WAITING) {
            long oldest = waiting.iterator().next();
            shown.removeIf(text -> text.queued && text.player == player && text.key == oldest);
        }
        int at = shown.size();
        if (first)
            for (int index = 0; index < shown.size(); index++) {
                Shown other = shown.get(index);
                if (other.queued && other.player == player && other.waiting) { at = index; break; }
            }
        for (Shown text : group) { text.waiting = true; text.cell = group.get(0).cell; }
        shown.addAll(at, group);
        publish();
        dirty = true;
    }

    private static Shown copy(Shown text) {
        var copy = new Shown(text.owner, text.key);
        copy(text, copy);
        return copy;
    }

    /**
     * {@code text.hide}: the text, or the title and the line under it, leaves as its effect says (at once with {@code now}, and a
     * waiting one goes from the queue). Whether there was one.
     */
    private boolean hide(String owner, long key, boolean now, long at) {
        boolean found = false;
        for (Shown text : shown) {
            if (!text.owner.equals(owner) || text.key != key || text.done) continue;
            found = true;
            if (now || text.waiting || text.start == 0) text.done = true;
            else if (text.hidden == 0) text.hidden = at;
        }
        if (found) { shown.removeIf(text -> text.done); publish(); dirty = true; }
        return found;
    }

    /** {@code handle:clear()}: the mod's texts go at once, waiting ones too. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        if (shown.removeIf(text -> text.owner.equals(owner))) { publish(); dirty = true; }
    }

    private void publish() { drawn = shown.toArray(new Shown[0]); }

    // ---- titles ----

    /** The styles of {@code text.title}: how the title and the line under it look and move. */
    static final class Styles {
        /** One style: the title's text and the line's, as specs of {@code show}. */
        record Style(Map<String, Object> title, Map<String, Object> line, double gap) { }

        static final Map<String, Style> ALL = new LinkedHashMap<>();

        static {
            // Stamped: big white letters that slam onto the screen and swell away, for something done (a quest complete).
            ALL.put("stamp", new Style(
                Map.ofEntries(Map.entry("font", List.of("SdfBold", "Large")), Map.entry("size", 0.1), Map.entry("color", List.of(1.0, 1.0, 1.0, 1.0)),
                    Map.entry("shadow", true), Map.entry("outline", 1.0), Map.entry("outlineColor", List.of(0.0, 0.0, 0.0, 0.45)),
                    Map.entry("y", 0.28), Map.entry("enter", "slam"), Map.entry("enterTime", 0.22), Map.entry("hold", 2.4),
                    Map.entry("leave", "grow"), Map.entry("leaveTime", 0.7)),
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Medium")), Map.entry("size", 0.045), Map.entry("color", List.of(0.88, 0.88, 0.88, 1.0)),
                    Map.entry("shadow", true), Map.entry("delay", 0.2), Map.entry("enter", "fade"), Map.entry("enterTime", 0.35),
                    Map.entry("leave", "fade"), Map.entry("leaveTime", 0.7)),
                0.25));
            // Found: warm amber letters that rise into view and drift up as they go, for something found (a search complete).
            ALL.put("discovery", new Style(
                Map.ofEntries(Map.entry("font", List.of("SdfRobertoSans", "Large")), Map.entry("size", 0.08), Map.entry("color", List.of(1.0, 0.8, 0.38, 1.0)),
                    Map.entry("shadow", true), Map.entry("y", 0.28), Map.entry("enter", "rise"), Map.entry("enterTime", 0.6), Map.entry("hold", 2.4),
                    Map.entry("leave", "rise"), Map.entry("leaveTime", 0.9)),
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Medium")), Map.entry("size", 0.042), Map.entry("color", List.of(1.0, 0.93, 0.78, 1.0)),
                    Map.entry("shadow", true), Map.entry("delay", 0.25), Map.entry("enter", "rise"), Map.entry("enterTime", 0.6),
                    Map.entry("leave", "rise"), Map.entry("leaveTime", 0.9)),
                0.3));
            // A notice: a smaller line that drops in near the top of the screen and fades, for news that is not an event of its own.
            ALL.put("notice", new Style(
                Map.ofEntries(Map.entry("font", List.of("SdfBold", "Medium")), Map.entry("size", 0.036), Map.entry("color", List.of(0.92, 0.95, 1.0, 1.0)),
                    Map.entry("shadow", true), Map.entry("y", 0.2), Map.entry("enter", "drop"), Map.entry("enterTime", 0.35), Map.entry("hold", 2.6),
                    Map.entry("leave", "fade"), Map.entry("leaveTime", 0.6)),
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Small")), Map.entry("size", 0.026), Map.entry("color", List.of(0.8, 0.84, 0.9, 1.0)),
                    Map.entry("shadow", true), Map.entry("delay", 0.1), Map.entry("enter", "fade"), Map.entry("enterTime", 0.35),
                    Map.entry("leave", "fade"), Map.entry("leaveTime", 0.6)),
                0.3));
        }

        private Styles() { }
    }

    /**
     * {@code text.title}: a title in a style, with a line under it when {@code subtitle} is given, queued on each player's screen
     * so that one title follows another. {@code now} lets it go first: the title on the screen leaves at once (quickly).
     */
    private long title(String owner, Object spec, String call) throws ReflectiveOperationException {
        String style = "stamp", line = null;
        Object text = null, color = null, lineColor = null, hold = null, player = null, y = null;
        boolean now = false;
        for (var entry : lua.entries(spec)) {
            if (!(entry.getKey() instanceof String field)) throw new IllegalArgumentException(call + ": spec has a field that is not a name");
            Object value = entry.getValue();
            switch (field) {
                case "text" -> text = value;
                case "subtitle" -> {
                    if (!(value instanceof String words) || words.isEmpty() || words.length() > MAX_LENGTH)
                        throw new IllegalArgumentException(call + ": spec.subtitle must be a string of 1 to " + MAX_LENGTH + " characters");
                    line = words;
                }
                case "style" -> {
                    if (!(value instanceof String name) || !Styles.ALL.containsKey(name))
                        throw new IllegalArgumentException(call + ": spec.style must be one of " + String.join(", ", Styles.ALL.keySet()));
                    style = name;
                }
                case "color" -> color = value;
                case "subtitleColor" -> lineColor = value;
                case "hold" -> hold = value;
                case "player" -> player = value;
                case "y" -> y = value;
                case "now" -> {
                    if (!(value instanceof Boolean on)) throw new IllegalArgumentException(call + ": spec.now must be true or false");
                    now = on;
                }
                default -> throw new IllegalArgumentException(call + ": spec has no field " + field
                    + "; it takes text, subtitle, style, color, subtitleColor, hold, y, player and now");
            }
        }
        if (text == null) throw new IllegalArgumentException(call + ": spec.text must be a string of 1 to " + MAX_LENGTH + " characters");
        Styles.Style chosen = Styles.ALL.get(style);
        Shown big = styled(owner, chosen.title(), call), small = line == null ? null : styled(owner, chosen.line(), call);
        Object fonts = chosen.title().get("font");
        big.lines = lines(text, call, "spec.text");
        font(big, fonts, call, "spec.font");
        if (color != null) { float[] parts = color(color, call, "spec.color"); big.red = parts[0]; big.green = parts[1]; big.blue = parts[2]; big.alpha = parts[3]; }
        if (hold != null) big.hold = number(hold, call, "spec.hold", 0, MAX_HOLD);
        if (y != null) big.y = number(y, call, "spec.y", 0, 1);
        if (player != null) big.player = player(player, call, "spec.player");
        if (small != null) {
            small.lines = lines(line, call, "spec.subtitle");
            font(small, chosen.line().get("font"), call, "spec.font");
            if (lineColor != null) { float[] parts = color(lineColor, call, "spec.subtitleColor"); small.red = parts[0]; small.green = parts[1]; small.blue = parts[2]; small.alpha = parts[3]; }
            small.player = big.player;
            // Under the title: its block, a gap, then the line's block, as shares of the screen's height.
            small.y = Math.min(1, big.y + big.size * big.lines.length / 2 + big.size * chosen.gap() + small.size * small.lines.length / 2);
            // It goes as the title goes.
            small.hold = Math.max(0, big.enterTime + big.hold - small.delay - small.enterTime);
        }
        big.queued = true;
        if (small != null) small.queued = true;
        int per = small == null ? 1 : 2;
        room(owner, per * (big.player < 0 ? screens() : 1), call);
        long key = next++;
        Object cell = game.cell();
        for (int screen : big.player >= 0 ? new int[] { big.player } : present()) {
            if (now) {
                // The title on that screen leaves, quickly, and this one goes before those waiting.
                long at = clock.getAsLong();
                for (Shown other : shown)
                    if (other.queued && other.player == screen && !other.waiting && other.start != 0 && !other.done) {
                        if (other.hidden == 0) other.hidden = at;
                        other.leaveTime = Math.min(other.leaveTime, 0.25);
                    }
            }
            Shown title = keyed(big, key, screen);
            title.cell = cell;
            enqueue(small == null ? List.of(title) : List.of(title, keyed(small, key, screen)), now);
        }
        return key;
    }

    /** The local players' indexes, or 0 alone when there is none (the main menu draws on the whole screen). */
    private int[] present() {
        int count = 0;
        Object[] all = players.all();
        for (int index = 0; index < all.length && index < PLAYERS; index++) if (all[index] != null) count++;
        if (count == 0) return new int[] { 0 };
        int[] result = new int[count];
        count = 0;
        for (int index = 0; index < all.length && index < PLAYERS; index++) if (all[index] != null) result[count++] = index;
        return result;
    }

    private static Shown keyed(Shown text, long key, int player) {
        var keyed = new Shown(text.owner, key);
        copy(text, keyed);
        keyed.player = player;
        return keyed;
    }

    private static void copy(Shown from, Shown to) {
        to.lines = from.lines; to.fontName = from.fontName; to.font = from.font; to.scale = from.scale; to.size = from.size;
        to.red = from.red; to.green = from.green; to.blue = from.blue; to.alpha = from.alpha;
        to.outline = from.outline; to.outlineRed = from.outlineRed; to.outlineGreen = from.outlineGreen; to.outlineBlue = from.outlineBlue;
        to.outlineAlpha = from.outlineAlpha; to.shadow = from.shadow; to.x = from.x; to.y = from.y; to.align = from.align;
        to.delay = from.delay; to.enter = from.enter; to.enterTime = from.enterTime; to.hold = from.hold; to.leave = from.leave;
        to.leaveTime = from.leaveTime; to.player = from.player; to.queued = from.queued; to.cell = from.cell;
    }

    /** A text with a style's fields, its text to come. */
    private Shown styled(String owner, Map<String, Object> style, String call) throws ReflectiveOperationException {
        var text = new Shown(owner, 0);
        Object spec = lua.table();
        for (var field : style.entrySet()) {
            Object value = field.getValue();
            if (field.getKey().equals("font")) continue;
            if (value instanceof List<?> list) value = lua.list(list);
            lua.set(spec, field.getKey(), value);
        }
        read(text, spec, call, "style");
        return text;
    }

    // ---- each frame ----

    /** Each frame, on the game's thread: a world left takes its texts away; what is shown is written for a newer API when it changed. */
    void frame() {
        try {
            if (moves.moved() && game.cell() != world) {
                Object cell = game.cell();
                world = cell;
                if (shown.removeIf(text -> text.cell != cell)) { publish(); dirty = true; }
            }
            if (dirty) write();
        } catch (Throwable failure) {
            // Once: a fault that recurs each frame must not flood the game's log. The drawing goes on.
            if (!reported) System.err.println("[PzTools API] text: " + failure);
            reported = true;
        }
    }

    // ---- the drawing (the hook) ----

    @Override public void draw() {
        Shown[] all = drawn;
        if (all.length == 0) return;
        long now = clock.getAsLong();
        Object[] local = players.all();
        boolean anyone = false;
        for (int index = 0; index < local.length && index < PLAYERS; index++) if (local[index] != null) { anyone = true; break; }
        boolean finished = false;
        try {
            for (int screen = 0; screen < PLAYERS; screen++) {
                if (anyone ? screen >= local.length || local[screen] == null : screen > 0) continue;
                release(all, screen);
                int left, top, width, height;
                if (anyone) {
                    left = (int)screenLeft.invokeExact(screen);
                    top = (int)screenTop.invokeExact(screen);
                    width = (int)screenWidth.invokeExact(screen);
                    height = (int)screenHeight.invokeExact(screen);
                } else {
                    Object instance = (Object)core.invokeExact();
                    left = 0;
                    top = 0;
                    width = (int)coreWidth.invokeExact(instance);
                    height = (int)coreHeight.invokeExact(instance);
                }
                if (width <= 0 || height <= 0) continue;
                for (Shown text : all) {
                    if (text.done || text.waiting || text.player >= 0 && text.player != screen) continue;
                    if (text.start == 0) { text.start = now; dirty = true; }
                    if (!draw(text, now, left, top, width, height)) { text.done = true; finished = true; }
                }
            }
        } catch (Throwable failure) {
            // The hook reports it, once; the game draws on.
            throw Texts.<RuntimeException>sneaky(failure);
        }
        if (finished) {
            shown.removeIf(text -> text.done);
            publish();
            dirty = true;
        }
    }

    /** Lets the first waiting group of the screen's queue go when no queued text is on that screen. */
    private void release(Shown[] all, int screen) {
        long first = 0;
        for (Shown text : all) {
            if (!text.queued || text.done || text.player != screen) continue;
            if (!text.waiting) return;
            if (first == 0) first = text.key;
        }
        if (first == 0) return;
        for (Shown text : all) if (text.queued && text.player == screen && text.key == first && !text.done) text.waiting = false;
        dirty = true;
    }

    /** Draws the text on one screen as it is at {@code now}; false once it has gone. Allocates nothing. */
    private boolean draw(Shown text, long now, int left, int top, int width, int height) throws Throwable {
        double t = (now - text.start) / SECOND - text.delay;
        // When it starts to leave: after its hold, or when its mod hid it.
        double leaving = text.enterTime + text.hold;
        if (text.hidden != 0) leaving = Math.min(leaving, Math.max(0, (text.hidden - text.start) / SECOND - text.delay));
        if (text.hidden != 0 && leaving <= 0 && t < 0) return false;
        if (t < 0) return true;
        double out = 0;
        if (t >= leaving) {
            if (text.leave == Leave.NONE || text.leaveTime <= 0) return false;
            out = (t - leaving) / text.leaveTime;
            if (out >= 1) return false;
        }
        double in = text.enter == Enter.NONE || text.enterTime <= 0 ? 1 : Math.min(1, Math.min(t, leaving) / text.enterTime);
        double alpha = 1, scale = 1, shift = 0;
        switch (text.enter) {
            case NONE -> { }
            case FADE -> alpha = smooth(in);
            case POP -> { alpha = Math.min(1, in * 2); scale = 0.5 + 0.5 * backOut(in); }
            case SLAM -> { alpha = Math.min(1, in * 3); scale = 1 + 1.5 * (1 - in * in); }
            case RISE -> { alpha = cubicOut(in); shift = RISE * (1 - cubicOut(in)); }
            case DROP -> { alpha = cubicOut(in); shift = -RISE * (1 - cubicOut(in)); }
        }
        switch (text.leave) {
            case NONE -> { }
            case FADE -> alpha *= 1 - smooth(out);
            case RISE -> { alpha *= 1 - out; shift -= DRIFT * out; }
            case SINK -> { alpha *= 1 - out; shift += DRIFT * out; }
            case GROW -> { alpha *= 1 - out; scale *= 1 + 0.3 * out; }
            case SHRINK -> { alpha *= 1 - out; scale *= 1 - 0.5 * out; }
        }
        float shownAlpha = (float)(alpha * text.alpha);
        if (shownAlpha <= INVISIBLE) return true;
        Object font = text.font;
        Object angel = (Object)fontOf.invokeExact(textManager, font);
        if (angel != text.measuredWith || text.widths == null) measure(text, angel);
        if (text.lineHeight <= 0) return true;
        double zoom = (text.size > 0 ? text.size * height / text.lineHeight : text.scale) * scale;
        double line = text.lineHeight * zoom;
        double anchorX = left + text.x * width, anchorY = top + text.y * height + shift * line;
        double firstY = anchorY - line * text.lines.length / 2;
        boolean distance = (boolean)sdf.invokeExact(textManager, font);
        Object shader = distance ? sdfShader.get(null) : null;
        if (shader != null) {
            // As the game's own distance-field text (AtomUIText): an edge as sharp as the zoom, no outline, no shadow of its own.
            threshold.invokeExact(shader, (float)(0.125 / zoom));
            shaderShadow.invokeExact(shader, 0f);
            shaderOutline.invokeExact(shader, 0f, 0f, 0f, 0f, 0f);
            startShader.invokeExact(shader);
        }
        try {
            for (int index = 0; index < text.lines.length; index++) {
                String words = text.lines[index];
                if (words.isEmpty()) continue;
                double lineWidth = text.widths[index] * zoom;
                double x = text.align < 0 ? anchorX : text.align > 0 ? anchorX - lineWidth : anchorX - lineWidth / 2;
                double y = firstY + line * index;
                if (text.shadow) {
                    double offset = Math.max(1, Math.round(line / 24));
                    drawString.invokeExact(textManager, font, x + offset, y + offset, zoom, words, 0.0, 0.0, 0.0, (double)(shownAlpha * 0.55f));
                }
                if (text.outline > 0) {
                    double o = text.outline;
                    double a = alpha * text.outlineAlpha;
                    for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) {
                        if (dx == 0 && dy == 0) continue;
                        drawString.invokeExact(textManager, font, x + dx * o, y + dy * o, zoom, words, (double)text.outlineRed,
                            (double)text.outlineGreen, (double)text.outlineBlue, a);
                    }
                }
                drawString.invokeExact(textManager, font, x, y, zoom, words, (double)text.red, (double)text.green, (double)text.blue, (double)shownAlpha);
            }
        } finally {
            if (shader != null) endShader.invokeExact();
        }
        return true;
    }

    /** The lines' widths and the line height at zoom 1, for the game's font now (it changes with the font size option). */
    private void measure(Shown text, Object angel) throws Throwable {
        if (text.widths == null || text.widths.length != text.lines.length) text.widths = new float[text.lines.length];
        for (int index = 0; index < text.lines.length; index++)
            text.widths[index] = text.lines[index].isEmpty() ? 0 : (int)measure.invokeExact(textManager, text.font, text.lines[index]);
        text.lineHeight = (int)fontHeight.invokeExact(textManager, text.font);
        text.measuredWith = angel;
    }

    private static double smooth(double p) { return p * p * (3 - 2 * p); }

    private static double cubicOut(double p) { double q = 1 - p; return 1 - q * q * q; }

    private static double backOut(double p) {
        double c = 1.70158, q = p - 1;
        return 1 + (c + 1) * q * q * q + c * q * q;
    }

    // ---- kept for a newer API ----

    /** Writes what is shown into the metatable, where a newer API reads it. */
    private void write() throws ReflectiveOperationException {
        var text = new StringBuilder(FORMAT).append("\nN\t").append(next);
        for (Shown shownText : shown) {
            if (shownText.done) continue;
            Shown s = shownText;
            text.append("\nT\t").append(escape(s.owner)).append('\t').append(s.key).append('\t').append(escape(String.join("\n", s.lines)))
                .append('\t').append(s.fontName).append('\t').append(s.scale).append('\t').append(s.size)
                .append('\t').append(s.red).append('\t').append(s.green).append('\t').append(s.blue).append('\t').append(s.alpha)
                .append('\t').append(s.outline).append('\t').append(s.outlineRed).append('\t').append(s.outlineGreen).append('\t').append(s.outlineBlue)
                .append('\t').append(s.outlineAlpha).append('\t').append(s.shadow).append('\t').append(s.x).append('\t').append(s.y)
                .append('\t').append(ALIGN_NAMES[s.align + 1]).append('\t').append(s.delay).append('\t').append(s.enter.name())
                .append('\t').append(s.enterTime).append('\t').append(s.hold).append('\t').append(s.leave.name()).append('\t').append(s.leaveTime)
                .append('\t').append(s.player).append('\t').append(s.queued).append('\t').append(s.waiting).append('\t').append(s.start)
                .append('\t').append(s.hidden);
        }
        lua.set(meta, MIRROR, text.toString());
        dirty = false;
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n");
    }

    private static String unescape(String value) {
        var result = new StringBuilder(value.length());
        for (int index = 0; index < value.length(); index++) {
            char letter = value.charAt(index);
            if (letter != '\\' || index + 1 == value.length()) { result.append(letter); continue; }
            char escaped = value.charAt(++index);
            result.append(escaped == 't' ? '\t' : escaped == 'n' ? '\n' : escaped);
        }
        return result.toString();
    }

    private String handover() {
        try {
            write();
            return (String)lua.get(meta, MIRROR);
        } catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    /** What an earlier API showed, if anything: in this world, from where it was (the same process's clock). */
    private void load(Object kept) {
        if (!(kept instanceof String text)) return;
        String[] lines = text.split("\n");
        if (!FORMAT.equals(lines[0])) {
            System.err.println("[PzTools API] text: what was shown is kept in another format; it is not shown again");
            return;
        }
        for (int index = 1; index < lines.length; index++) {
            String[] fields = lines[index].split("\t", -1);
            if ("N".equals(fields[0])) { next = Math.max(next, Long.parseLong(fields[1])); continue; }
            if (fields.length != 31 || !"T".equals(fields[0])) throw new IllegalStateException("Unknown line in the kept text: " + lines[index]);
            var s = new Shown(unescape(fields[1]), Long.parseLong(fields[2]));
            s.lines = unescape(fields[3]).split("\n", -1);
            s.fontName = fields[4];
            s.font = fonts.get(s.fontName);
            if (s.font == null) continue;
            s.scale = Double.parseDouble(fields[5]); s.size = Double.parseDouble(fields[6]);
            s.red = Float.parseFloat(fields[7]); s.green = Float.parseFloat(fields[8]); s.blue = Float.parseFloat(fields[9]); s.alpha = Float.parseFloat(fields[10]);
            s.outline = Float.parseFloat(fields[11]); s.outlineRed = Float.parseFloat(fields[12]); s.outlineGreen = Float.parseFloat(fields[13]);
            s.outlineBlue = Float.parseFloat(fields[14]); s.outlineAlpha = Float.parseFloat(fields[15]); s.shadow = Boolean.parseBoolean(fields[16]);
            s.x = Double.parseDouble(fields[17]); s.y = Double.parseDouble(fields[18]); s.align = ALIGN.get(fields[19]);
            s.delay = Double.parseDouble(fields[20]); s.enter = Enter.valueOf(fields[21]); s.enterTime = Double.parseDouble(fields[22]);
            s.hold = Double.parseDouble(fields[23]); s.leave = Leave.valueOf(fields[24]); s.leaveTime = Double.parseDouble(fields[25]);
            s.player = Integer.parseInt(fields[26]); s.queued = Boolean.parseBoolean(fields[27]); s.waiting = Boolean.parseBoolean(fields[28]);
            s.start = Long.parseLong(fields[29]); s.hidden = Long.parseLong(fields[30]);
            s.cell = world;
            next = Math.max(next, s.key + 1);
            shown.add(s);
        }
        publish();
    }

    @SuppressWarnings("unchecked")
    private static <T extends Throwable> T sneaky(Throwable failure) throws T { throw (T)failure; }
}
