package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.util.*;
import java.util.function.Supplier;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.text}: text a mod shows on the screen (docs/design.md, "Text"), and titles: a large line in
 * the middle of the screen, with a smaller one under it, in one of a few styles, one after the other. The game's own text
 * drawing does it ({@code TextManager.DrawString} with a zoom, through the game's distance-field shader for the fonts made for
 * it), from a hook in {@code UIManager.render} once the interface's windows are drawn: so the text is drawn with the interface,
 * on each local player's part of the screen, and nothing runs in Lua for it. With nothing shown the hook returns at once.
 *
 * <p>A text can be typed (its characters come on at a rate, with pauses, speed changes and a cursor), carry colours, and be wrapped
 * to a width. {@link Script} reads its markup once, when it is shown, and {@link Layout} breaks it into rows once for each screen's
 * size and font; each frame then only compares the clock with the time of each character.
 *
 * <p>A text that leaves as dust ({@code leave = "dust"}) is drawn once into a picture of its own as it stands still, and then
 * breaks into cells of that picture that drift away, swept across it ({@link Dust}); without the game's frame buffers it fades.
 * A text with a look (an enter such as {@code "torch"}, a leave such as {@code "burn"}) is drawn into such a picture as soon as it
 * shows, and the picture is drawn by the API's shader over its life ({@link Looks}); without it the text fades.
 *
 * <p>What is shown belongs to the world it was shown in, and is kept in the API table's metatable for a newer API to take over,
 * as the moodles are. Everything here runs on the game's main thread: the mods' calls, the frame job and the drawing (the dust
 * queues a little for the render thread).
 *
 * <p>A mod also draws text of its own in its windows at a height in pixels ({@code font}, {@code fontHeight}, {@code measure},
 * {@code draw}): {@link SizedFonts} chooses and loads the language's font for the height.
 */
final class Texts implements Hooks.Text {
    private static final String AREA = "PZExtAPI.text.";
    private static final String MIRROR = "texts", FORMAT = "pzext-texts 5", FORMAT_BEFORE_BURN = "pzext-texts 4",
        FORMAT_BEFORE_BACKDROP = "pzext-texts 3", FORMAT_BEFORE_DUST = "pzext-texts 2",
        FORMAT_BEFORE_TYPING = "pzext-texts 1",
        GENERATION = "textsGeneration", HANDOVER = "textsHandover";
    /** The hook that draws, as {@code PZExtAPI.hooks()} names it. */
    static final String HOOK = "UIManager.render:text";
    static final int PLAYERS = 4, MAX_LINES = 8, MAX_LENGTH = 512, MAX_PER_MOD = 64, MAX_ALL = 256, MAX_WAITING = 8;
    static final double MAX_SECONDS = 30, MAX_HOLD = 3600, MAX_SCALE = 20, MAX_SIZE = 0.5, MAX_OUTLINE = 8;
    // Typing: the characters a second (DEFAULT_SPEED when left out), the narrowest width to fit, the longest pause, the longest a
    // text may take to type, and the time a cursor is on, and then off.
    static final double DEFAULT_SPEED = 30, MAX_SPEED = 1000, MIN_WIDTH = 0.05, MAX_PAUSE = 30, MAX_TYPING = 300, BLINK = 0.5;
    // Dust: the size of its cells and the reach of its drift, as shares of the default.
    static final double MIN_DUST_SIZE = 0.25, MAX_DUST_SIZE = 8, MAX_DUST_DRIFT = 4;
    // Frames a picture let go from the render queue is given before it is let go on the render thread's own turn.
    private static final int BURIAL_FRAMES = 120;
    private static final java.util.regex.Pattern NUMBER = java.util.regex.Pattern.compile("[0-9]{1,4}(\\.[0-9]{1,3})?");
    private static final java.util.regex.Pattern HEX = java.util.regex.Pattern.compile("[0-9A-Fa-f]{6}");
    private static final String CURSOR = "_";
    // A text whose alpha is below this is not drawn.
    private static final float INVISIBLE = 0.002f;
    // How far the rising and sinking effects move, in the text's line heights.
    private static final double RISE = 0.75, DRIFT = 0.5;
    // How far above its place a settling text starts, and how far below its place a sliding one, in its line heights.
    private static final double SETTLE = 0.3, SLIDE = 0.4;
    // The frames of a look a piece keeps, used in turn (the render thread is at most a couple of frames behind).
    private static final int LOOK_FRAMES = 6;
    // A backdrop: how far its soft edge reaches past the text, to the sides and up and down, in the text's line heights, and
    // in how many rings (each shaded from its inside to its outside by the card, between the points of a smooth step).
    private static final double BACKDROP_SIDE = 2.6, BACKDROP_END = 1.0;
    private static final int BACKDROP_RINGS = 4;
    private static final double SECOND = 1e9;

    /** How a text comes onto the screen (the last four are looks: {@link Looks}). */
    enum Enter { NONE, FADE, POP, SLAM, SETTLE, RISE, DROP, TYPE, SLIDE, IMPACT, TORCH, SIGNAL, MIST }

    /** How it goes (the last five are looks). */
    enum Leave { NONE, FADE, RISE, SINK, GROW, SHRINK, DUST, ERODE, DIM, LOST, MIST, BURN }

    private static final Map<String, Integer> ALIGN = Map.of("left", -1, "center", 0, "right", 1);
    private static final String[] ALIGN_NAMES = { "left", "center", "right" };

    /** One text on the screen, or waiting for its turn in a player's queue of titles. */
    static final class Shown {
        final String owner;
        final long key;
        // The lines (what is drawn: markup left out), the font's name and the game's font (UIFont); the share of the screen's height a
        // line is, or the zoom.
        String[] lines;
        String fontName;
        Object font;
        double scale = 1, size;
        float red = 1, green = 1, blue = 1, alpha = 1, outline, outlineRed, outlineGreen, outlineBlue, outlineAlpha = 1;
        boolean shadow;
        double x = 0.5, y = 0.5;
        int align;
        // What the mod gave as the text, when it has markup, types or fits a width (null for a plain text); and the options for
        // these: the markup is read, a line's width as a share of the screen's, the characters a second (0: the default), a cursor.
        String source;
        boolean markup, cursor;
        double width, speed;
        // What the source makes of it, once; null for a plain text, which is drawn as it always was.
        Script script;
        // The rows of the text on each screen, made for the size of the screen and the font that were then.
        Layout[] layouts;
        double delay, enterTime, hold = Double.POSITIVE_INFINITY, leaveTime;
        Enter enter = Enter.NONE;
        Leave leave = Leave.NONE;
        // The local player whose screen it is on; -1 for every local player's.
        int player = -1;
        // The title a title's line goes with (its look's cues are the title's), or null.
        Shown lead;
        // Waits for the queue of its player's screen; waiting until it is the first of that queue.
        boolean queued, waiting;
        // The world it was shown in.
        Object cell;
        // When it was first drawn (System.nanoTime), 0 before; when its mod hid it, 0 if it did not.
        long start, hidden;
        boolean done;
        // The widths of the lines and the height of one at zoom 1, as measured with the font (AngelCodeFont) they were for: the
        // game's, or the embedded font's.
        Object measuredWith;
        float[] widths;
        float lineHeight;
        // The game's font (AngelCodeFont) of the text's UIFont as last read, and the height of its line at zoom 1.
        Object gameFont;
        float gameLineHeight;
        // The embedded font's AngelCodeFont while it draws the text (null: the game's font draws it); whether that font has every
        // character of the text, as found for the font it was looked up in.
        Object face;
        Object coveredBy;
        boolean covered;
        // Dust: its cells' size and its drift (shares of the default), the way its front goes, the colour it burns with (null:
        // it weathers to ash instead); its piece on each screen.
        double dustSize = 1, dustDrift = 1;
        Dust.Sweep dustSweep = Dust.Sweep.RIGHT;
        float[] dustBurn;
        Dust.Piece[] pieces;
        // A dark backdrop behind it with a soft edge: its strength in the middle (0 for none), and how far it reaches below the
        // text's lines (a share of the screen's height: a title's reaches over its line).
        double backdrop, backdropBelow;

        Shown(String owner, long key) { this.owner = owner; this.key = key; }
    }

    /**
     * What a text's markup and typing make of it, read once when it is shown: the characters it shows, when each comes on and in
     * what colour. The markup is {p:seconds} (a pause), {s:rate} and {s} (a speed, and back to the text's own), and
     * {c:RRGGBB} up to {/c} (a colour); two braces in a row stand for one brace.
     */
    static final class Script {
        /** The characters, markup left out; the lines apart by {@code \n}. */
        final String plain;
        /** For each character, the seconds after typing starts at which it shows; never before the one before it. Null for no typing. */
        final double[] at;
        /** For each character, its colour as 0xRRGGBB, or -1 for the text's own. Null when no character has one. */
        final int[] tint;
        /** How long typing takes: to the end of the last character's turn and the pauses after it. 0 for no typing. */
        final double duration;

        private Script(String plain, double[] at, int[] tint, double duration) {
            this.plain = plain; this.at = at; this.tint = tint; this.duration = duration;
        }

        /** Reads the source; a {@code rate} of characters a second is what a {@code {s}} goes back to. */
        static Script read(String source, boolean markup, boolean type, double rate, String call, String name) {
            String text = source.replace("\r\n", "\n").replace('\t', ' ');
            int length = text.length(), count = 0, color = -1;
            var plain = new StringBuilder(length);
            double[] at = type ? new double[length] : null;
            int[] tint = null;
            double time = 0, speed = rate;
            for (int index = 0; index < length; index++) {
                char letter = text.charAt(index);
                if (markup && (letter == '{' || letter == '}')) {
                    if (index + 1 < length && text.charAt(index + 1) == letter) index++;
                    else if (letter == '}') throw bad(call, name, index, "a } with no { before it (write }} for the character)");
                    else {
                        int close = text.indexOf('}', index);
                        if (close < 0) throw bad(call, name, index, "a { with no } after it (write {{ for the character)");
                        String tag = text.substring(index + 1, close);
                        int colon = tag.indexOf(':');
                        String word = colon < 0 ? tag : tag.substring(0, colon), argument = colon < 0 ? null : tag.substring(colon + 1);
                        switch (word) {
                            case "p" -> {
                                if (argument == null || !NUMBER.matcher(argument).matches() || Double.parseDouble(argument) > MAX_PAUSE)
                                    throw bad(call, name, index, "{" + tag + "} must be {p:seconds}, from 0 to " + trim(MAX_PAUSE));
                                time += Double.parseDouble(argument);
                            }
                            case "s" -> {
                                double value = argument == null ? rate : NUMBER.matcher(argument).matches() ? Double.parseDouble(argument) : 0;
                                if (!(value >= 1 && value <= MAX_SPEED))
                                    throw bad(call, name, index, "{" + tag + "} must be {s:characters a second}, from 1 to " + trim(MAX_SPEED) + ", or {s}");
                                speed = value;
                            }
                            case "c" -> {
                                if (argument == null || !HEX.matcher(argument).matches()) throw bad(call, name, index, "{" + tag + "} must be {c:RRGGBB}");
                                if (color >= 0) throw bad(call, name, index, "{" + tag + "} inside a colour that is not closed with {/c}");
                                color = Integer.parseInt(argument, 16);
                            }
                            case "/c" -> {
                                if (argument != null || color < 0) throw bad(call, name, index, "{" + tag + "} with no {c:RRGGBB} before it");
                                color = -1;
                            }
                            default -> throw bad(call, name, index, "{" + tag + "} is not {p:seconds}, {s:rate}, {s}, {c:RRGGBB} or {/c}");
                        }
                        index = close;
                        continue;
                    }
                }
                if (at != null) at[count] = time;
                if (color >= 0) {
                    if (tint == null) { tint = new int[length]; Arrays.fill(tint, -1); }
                    tint[count] = color;
                }
                plain.append(letter);
                count++;
                if (letter != '\n') time += 1 / speed;
            }
            if (color >= 0) throw bad(call, name, length, "a {c:RRGGBB} that is not closed with {/c}");
            if (count == 0) throw bad(call, name, 0, "no characters are left once the markup is read");
            if (type && time > MAX_TYPING) throw new IllegalArgumentException(call + ": " + name + " takes " + trim(Math.rint(time)) + " seconds to type; at most " + trim(MAX_TYPING));
            return new Script(plain.toString(), at == null ? null : Arrays.copyOf(at, count), tint == null ? null : Arrays.copyOf(tint, count), type ? time : 0);
        }

        private static IllegalArgumentException bad(String call, String name, int index, String why) {
            return new IllegalArgumentException(call + ": " + name + " has markup that does not read, at character " + (index + 1) + ": " + why);
        }

        /** How many characters show at {@code seconds} of typing: those whose time has come. */
        int shown(double seconds) {
            if (at == null) return plain.length();
            int low = 0, high = at.length;
            while (low < high) {
                int middle = (low + high) >>> 1;
                if (at[middle] <= seconds + 1e-9) low = middle + 1;
                else high = middle;
            }
            return low;
        }
    }

    /** A run of one colour in a row. When typing, the first characters of it are made once, when first shown, with their widths. */
    static final class Seg {
        int from, to, tint;
        String text;
        // Where it starts in the row, at zoom 1.
        float x;
        String[] part;
        float[] partWidth;
    }

    /** A line as it is drawn: the characters {@code from} to {@code to} of the text, in runs of one colour. */
    static final class Row {
        int from, to;
        float width;
        Seg[] segs;
    }

    /** The rows of a text on one screen, made for the screen's size and the font it was measured with. */
    static final class Layout {
        Object font;
        int width, height;
        Row[] rows;
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
    // AngelCodeFont.drawString(x, y, zoom, text, r, g, b, a) and getWidth(text), for the embedded font; null in a game without them.
    private final MethodHandle faceDraw, faceWidth;
    // SpriteRenderer.instance and render(texture, the four corners, a colour for each, consumer): a backdrop's shaded quads.
    private final Object sprites;
    private final MethodHandle renderShaded;
    /** The embedded font for large text, or null: the game's fonts draw everything (package-private for the tests). */
    EmbeddedFont.Loaded embedded;
    // Whether the embedded font's atlas was in video memory as this frame began: text.measure and text.draw choose by it, so that
    // a text measured and drawn in one frame is in one font.
    private boolean embeddedReady;
    /** The fonts of text.font, measure and draw; null in a game this cannot read them in (package-private for the tests). */
    final SizedFonts sized;
    /** What text.wrap and text.fit measured, kept for the calls that ask again (package-private for the tests). */
    final TextFits.Cache fits = new TextFits.Cache();
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
    /** The game's frame buffers and sprites for dust, or null: dust fades (package-private for the tests). */
    Dust.Gl dust;
    /** The looks' shader and drawing, or null: the looks fade (package-private for the tests). */
    Looks.Gl looks;
    // The impact's state, worked out into it (the frames allocate nothing).
    private final double[] hit = new double[6];
    // The texts' pieces of dust that hold a picture, or will; and the pictures to let go, from the render queue at the next drawing.
    private final ArrayList<Dust.Piece> pieces = new ArrayList<>();
    private final ArrayList<Grave> dying = new ArrayList<>();

    /** A picture to let go: queued with the sprites once, then let go on the render thread's turn should the queue have lost it. */
    static final class Grave {
        final Runnable destroy;
        Object drawer;
        int frames = -1;

        Grave(Runnable destroy, Object drawer) { this.destroy = destroy; this.drawer = drawer; }

        boolean done() { return destroy instanceof Dust.Piece piece && piece.destroyed.get(); }
    }

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
        Class<?> angelCode = Game.type(loader, "zombie.core.fonts.AngelCodeFont");
        glyphs = angelCode.getField("chars");
        MethodHandle draws = null, widths = null;
        try {
            draws = Game.exact(angelCode.getMethod("drawString", float.class, float.class, float.class, String.class, float.class, float.class,
                float.class, float.class), MethodType.methodType(void.class, Object.class, float.class, float.class, float.class, String.class,
                float.class, float.class, float.class, float.class));
            widths = Game.exact(angelCode.getMethod("getWidth", String.class), MethodType.methodType(int.class, Object.class, String.class));
        } catch (NoSuchMethodException older) { draws = null; } // The game's fonts alone.
        faceDraw = draws;
        faceWidth = widths;
        Class<?> renderer = Game.type(loader, "zombie.core.SpriteRenderer"), texture = Game.type(loader, "zombie.core.textures.Texture");
        sprites = renderer.getField("instance").get(null);
        Class<?>[] shaded = new Class<?>[26];
        shaded[0] = texture;
        for (int index = 1; index <= 8; index++) shaded[index] = double.class;
        for (int index = 9; index <= 24; index++) shaded[index] = float.class;
        shaded[25] = java.util.function.Consumer.class;
        Class<?>[] handle = new Class<?>[27];
        handle[0] = Object.class;
        handle[1] = Object.class;
        for (int index = 2; index <= 9; index++) handle[index] = double.class;
        for (int index = 10; index <= 25; index++) handle[index] = float.class;
        handle[26] = Object.class;
        renderShaded = Game.exact(renderer.getMethod("render", shaded), MethodType.methodType(void.class, handle));
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
                System.err.println("[PZExt] text: the earlier API did not hand it over: " + failure);
            }
        }
        dust = Dust.Gl.open(loader);
        looks = dust == null ? null : Looks.Gl.open(loader);
        // The pictures the API before this one held: let go from this one's drawing, after what that one drew.
        for (Runnable destroy : Dust.orphans()) dying.add(new Grave(destroy, null));
        world = game.cell();
        load(lua.get(meta, MIRROR));
        dirty = false;
        // As the Lua environment starts (a loading screen): the language's pack into video memory, or its bake started.
        embedded = faceDraw == null || faceWidth == null ? null : EmbeddedFont.current(loader);
        embeddedReady = embedded != null && embedded.ready.get();
        SizedFonts readable;
        try { readable = new SizedFonts(loader, textManager); }
        catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) {
            readable = null;
            System.err.println("[PZExt] text: text.font has no fonts in this game: " + unreadable);
        }
        sized = readable;
    }

    /** Gives the game's interface drawing to this text. Throws a LinkageError in a game whose bootstrap has no text hook. */
    void hook() { Hooks.setText(this); }

    /** The game draws no text of the API's. */
    static void unhook() {
        try { Hooks.setText(null); } catch (LinkageError olderBootstrap) { }
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
        try { return Hooks.hookStatus().getOrDefault(HOOK, Hooks.NOT_LOADED); }
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
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
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
        // Text a mod draws in its own windows, at a height in pixels: the key is the height.
        function(table, "font", (call, arguments) -> {
            owner(arguments, call);
            Object value = arguments.length > 1 ? arguments[1] : null;
            if (!(value instanceof Double number) || !(number >= 1 && number <= SizedFonts.MAX))
                throw new IllegalArgumentException(call + ": px must be a number from 1 to " + SizedFonts.MAX);
            int px = (int)Math.round(number);
            try { return new Object[] { sized != null && sized.prepare(px, drawable()) ? (Object)(double)px : null }; }
            catch (Throwable failure) { throw Game.thrown(failure); }
        });
        function(table, "fontHeight", (call, arguments) -> {
            owner(arguments, call);
            int px = sizedKey(arguments, call);
            int height;
            try { height = sized == null ? 0 : sized.height(px); }
            catch (Throwable failure) { throw Game.thrown(failure); }
            return new Object[] { height > 0 ? (Object)(double)height : null };
        });
        function(table, "measure", (call, arguments) -> {
            owner(arguments, call);
            int px = sizedKey(arguments, call);
            if (!(arguments.length > 2 && arguments[2] instanceof String words)) throw new IllegalArgumentException(call + ": text must be a string");
            try { return new Object[] { (double)(sized == null ? 0 : sized.measure(px, words, drawable())) }; }
            catch (Throwable failure) { throw Game.thrown(failure); }
        });
        function(table, "draw", (call, arguments) -> {
            owner(arguments, call);
            int px = sizedKey(arguments, call);
            if (!(arguments.length > 2 && arguments[2] instanceof String words)) throw new IllegalArgumentException(call + ": text must be a string");
            double x = place(arguments, 3, call, "x"), y = place(arguments, 4, call, "y");
            float red = part(arguments, 5, call, "r"), green = part(arguments, 6, call, "g"), blue = part(arguments, 7, call, "b"), alpha = part(arguments, 8, call, "a");
            if (sized == null) return Game.NONE;
            try { sized.draw(px, words, x, y, red, green, blue, alpha, drawable()); }
            catch (Throwable failure) { throw Game.thrown(failure); }
            return Game.NONE;
        });
        // A text broken into lines of a width, and cut to one, in a font text.font made or one of the game's by name.
        function(table, "wrap", (call, arguments) -> {
            String owner = owner(arguments, call);
            try { return fitted(owner, arguments, call, true); }
            catch (RuntimeException mine) { throw mine; }
            catch (Throwable failure) { throw Game.thrown(failure); }
        });
        function(table, "fit", (call, arguments) -> {
            String owner = owner(arguments, call);
            try { return fitted(owner, arguments, call, false); }
            catch (RuntimeException mine) { throw mine; }
            catch (Throwable failure) { throw Game.thrown(failure); }
        });
    }

    /** Wraps or fits: the cache first, then the font's measure; a font this game cannot measure gives nil. */
    private Object[] fitted(String owner, Object[] arguments, String call, boolean wrap) throws Throwable {
        Object font = arguments.length > 1 ? arguments[1] : null;
        Object key, uiFont = null;
        int px = 0;
        if (font instanceof String name) {
            uiFont = fonts.get(name);
            if (uiFont == null) throw new IllegalArgumentException(call + ": font must be what text.font returned or one of the game's font names: " + String.join(", ", fonts.keySet()));
            key = name;
        } else if (font instanceof Double) {
            px = sizedKey(arguments, call);
            key = px;
        } else throw new IllegalArgumentException(call + ": font must be what text.font returned or one of the game's font names");
        if (!(arguments.length > 2 && arguments[2] instanceof String words) || words.length() > TextFits.MAX_TEXT)
            throw new IllegalArgumentException(call + ": text must be a string of at most " + TextFits.MAX_TEXT + " characters");
        int limit = Arguments.integer(arguments, 3, call, "width", 1, 100_000);
        String ellipsis = TextFits.ELLIPSIS;
        if (!wrap && arguments.length > 4 && arguments[4] != null) {
            if (!(arguments[4] instanceof String given) || given.length() > TextFits.MAX_ELLIPSIS)
                throw new IllegalArgumentException(call + ": ellipsis must be a string of at most " + TextFits.MAX_ELLIPSIS + " characters");
            ellipsis = given;
        }
        // What the width comes from, and what it was measured with: the choice of a height (made again when the game makes its fonts
        // again, and with the embedded font's readiness), or the game's font object.
        TextFits.Width width;
        Object[] with;
        if (uiFont != null) {
            Object face = (Object)fontOf.invokeExact(textManager, uiFont);
            Object chosen = uiFont;
            width = text -> (int)measure.invokeExact(textManager, chosen, text);
            with = new Object[] { face };
        } else {
            if (sized == null) return new Object[] { null };
            SizedFonts.Choice choice = sized.choice(px);
            if (choice == null) return new Object[] { null };
            int height = px;
            EmbeddedFont.Loaded own = drawable();
            width = text -> sized.measure(height, text, own);
            with = new Object[] { choice, own != null };
        }
        var id = new TextFits.Key(owner, key, limit, wrap, wrap ? null : ellipsis, words);
        TextFits.Result kept = fits.get(id, with);
        if (kept == null) {
            if (wrap) {
                String[] lines;
                try { lines = TextFits.wrap(width, words, limit); }
                catch (IllegalArgumentException tooLong) { throw new IllegalArgumentException(call + ": " + tooLong.getMessage()); }
                kept = new TextFits.Result(with, lua.list(java.util.Arrays.asList((Object[])lines)), TextFits.widest(width, lines), false);
            } else {
                Object[] result = TextFits.fit(width, words, limit, ellipsis);
                kept = new TextFits.Result(with, result[0], 0, (Boolean)result[1]);
            }
            fits.put(id, kept);
        }
        return wrap ? new Object[] { kept.value(), kept.widest() } : new Object[] { kept.value(), kept.cut() };
    }

    /** The embedded font when it can draw this frame (its atlas was in video memory as the frame began), else null. */
    private EmbeddedFont.Loaded drawable() { return embeddedReady ? embedded : null; }

    /** A key text.font gave: the height in pixels it was asked for. */
    private static int sizedKey(Object[] arguments, String call) {
        Object value = arguments.length > 1 ? arguments[1] : null;
        if (!(value instanceof Double number) || number != Math.rint(number) || number < 1 || number > SizedFonts.MAX)
            throw new IllegalArgumentException(call + ": key must be what text.font returned");
        return number.intValue();
    }

    /** A place on the screen, in pixels: any number. */
    private static double place(Object[] arguments, int index, String call, String name) {
        Object value = index < arguments.length ? arguments[index] : null;
        if (!(value instanceof Double number) || !Double.isFinite(number)) throw new IllegalArgumentException(call + ": " + name + " must be a number");
        return number;
    }

    /** A colour's part, 0 to 1. */
    private static float part(Object[] arguments, int index, String call, String name) {
        Object value = index < arguments.length ? arguments[index] : null;
        if (!(value instanceof Double number) || !(number >= 0 && number <= 1)) throw new IllegalArgumentException(call + ": " + name + " must be a number from 0 to 1");
        return (float)(double)number;
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
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
        String dusty = null;
        for (var entry : lua.entries(spec)) {
            if (!(entry.getKey() instanceof String field)) throw new IllegalArgumentException(call + ": " + prefix + " has a field that is not a name");
            Object value = entry.getValue();
            String name = prefix + "." + field;
            switch (field) {
                case "text" -> text.source = source(value, call, name);
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
                case "markup" -> text.markup = flag(value, call, name);
                case "width" -> text.width = number(value, call, name, MIN_WIDTH, 1);
                case "speed" -> text.speed = number(value, call, name, 1, MAX_SPEED);
                case "cursor" -> text.cursor = flag(value, call, name);
                case "backdrop" -> text.backdrop = number(value, call, name, 0, 1);
                case "dustSize", "dustSweep", "dustDrift", "dustBurn" -> { dust(text, field, value, call, name); dusty = field; }
                default -> throw new IllegalArgumentException(call + ": " + prefix + " has no field " + field + "; it takes text, font, scale, size,"
                    + " color, x, y, align, shadow, outline, outlineColor, delay, enter, enterTime, hold, leave, leaveTime, player, queue,"
                    + " markup, width, speed, cursor, backdrop, dustSize, dustSweep, dustDrift and dustBurn");
            }
        }
        if (text.enter != Enter.TYPE && (text.speed != 0 || text.cursor))
            throw new IllegalArgumentException(call + ": " + prefix + ".speed and " + prefix + ".cursor go with " + prefix + ".enter = \"type\"");
        if (dusty != null && text.leave != Leave.DUST && text.leave != Leave.BURN)
            throw new IllegalArgumentException(call + ": " + prefix + "." + dusty + " goes with " + prefix + ".leave = \"dust\" or \"burn\"");
        if (text.source != null) compose(text, call, prefix);
        if (text.lines != null && text.font == null) font(text, "Large", call, prefix + ".font");
        else if (text.lines != null && text.fontName == null) font(text, text.font, call, prefix + ".font");
    }

    /** One of the dust's fields: the cells' size and the drift as shares of the default, the way the front goes, its burn. */
    private void dust(Shown text, String field, Object value, String call, String name) throws ReflectiveOperationException {
        switch (field) {
            case "dustSize" -> text.dustSize = number(value, call, name, MIN_DUST_SIZE, MAX_DUST_SIZE);
            case "dustDrift" -> text.dustDrift = number(value, call, name, 0, MAX_DUST_DRIFT);
            case "dustBurn" -> text.dustBurn = color(value, call, name);
            default -> text.dustSweep = effect(Dust.Sweep.class, value, call, name);
        }
    }

    private static boolean flag(Object value, String call, String name) {
        if (!(value instanceof Boolean on)) throw new IllegalArgumentException(call + ": " + name + " must be true or false");
        return on;
    }

    private static String source(Object value, String call, String name) {
        if (!(value instanceof String text) || text.isEmpty() || text.length() > MAX_LENGTH)
            throw new IllegalArgumentException(call + ": " + name + " must be a string of 1 to " + MAX_LENGTH + " characters");
        return text;
    }

    private String[] lines(Object value, String call, String name) { return lines(source(value, call, name), call, name); }

    private static String[] lines(String text, String call, String name) {
        String[] lines = text.replace("\r\n", "\n").split("\n", -1);
        if (lines.length > MAX_LINES) throw new IllegalArgumentException(call + ": " + name + " has " + lines.length + " lines; at most " + MAX_LINES);
        for (int index = 0; index < lines.length; index++) lines[index] = lines[index].replace('\t', ' ');
        return lines;
    }

    /**
     * Makes the text's lines from its source. With markup, typing or a width to fit it also makes the {@link Script}, which the
     * drawing goes by; a plain text is its lines alone. The enter effect {@code type} takes as long as the typing does.
     */
    private void compose(Shown text, String call, String prefix) {
        boolean type = text.enter == Enter.TYPE;
        if (type && text.enterTime != 0)
            throw new IllegalArgumentException(call + ": " + prefix + ".enterTime does not go with enter = \"type\", which takes as long as its text and speed do");
        String name = prefix + ".text";
        if (!text.markup && !type && text.width == 0) {
            text.lines = lines(text.source, call, name);
            text.source = null;
            return;
        }
        text.script = Script.read(text.source, text.markup, type, text.speed == 0 ? DEFAULT_SPEED : text.speed, call, name);
        text.lines = lines(text.script.plain, call, name);
        if (type) text.enterTime = text.script.duration;
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
        for (String font : names) if (covers(fonts.get(font), text.lines, text.cursor)) { chosen = font; break; }
        text.fontName = chosen;
        text.font = fonts.get(chosen);
    }

    /** Whether the game's font has a character for every one of the lines' (spaces aside), and for the cursor when there is one. */
    private boolean covers(Object font, String[] lines, boolean cursor) throws ReflectiveOperationException {
        Object angel;
        try { angel = (Object)fontOf.invokeExact(textManager, font); }
        catch (Throwable failure) { throw Game.thrown(failure); }
        if (angel == null) return false;
        Object[] defined = (Object[])glyphs.get(angel);
        if (defined == null) return false;
        if (cursor && (CURSOR.charAt(0) >= defined.length || defined[CURSOR.charAt(0)] == null)) return false;
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
        fits.drop(owner);
        if (shown.removeIf(text -> text.owner.equals(owner))) { publish(); dirty = true; }
    }

    private void publish() {
        drawn = shown.toArray(new Shown[0]);
        // A text gone lets its dust's pictures go.
        for (int index = pieces.size() - 1; index >= 0; index--) {
            Dust.Piece piece = pieces.get(index);
            if (piece.owner.done || !shown.contains(piece.owner)) letGo(piece);
        }
    }

    // ---- dust ----

    /** The text's piece of dust on the screen, made the first time it is asked for. */
    private Dust.Piece piece(Shown text, int screen) {
        if (text.pieces == null) text.pieces = new Dust.Piece[PLAYERS];
        Dust.Piece piece = text.pieces[screen];
        if (piece == null) {
            long seed = text.key * 0x9E3779B97F4A7C15L ^ (long)screen << 40 ^ String.join("\n", text.lines).hashCode();
            piece = text.pieces[screen] = new Dust.Piece(text, screen, seed);
            pieces.add(piece);
        }
        return piece;
    }

    /** The piece is no longer needed: its picture goes, from the render queue at the next drawing. The text fades if it still shows. */
    private void letGo(Dust.Piece piece) {
        pieces.remove(piece);
        piece.released = true;
        if (piece.texture != null) dying.add(new Grave(piece, piece.burial));
    }

    /**
     * At the start of the interface's drawing: the pictures let go are queued with the sprites, after the frames that drew them
     * (a picture is not drawn in the frame it is let go).
     */
    private void bury() throws Throwable {
        Dust.Gl gl = dust;
        for (int index = 0; index < dying.size(); index++) {
            Grave grave = dying.get(index);
            if (grave.frames >= 0) continue;
            grave.frames = 0;
            if (gl == null) continue;
            if (grave.drawer == null) grave.drawer = gl.drawer(grave.destroy);
            gl.buryDrawer(grave.drawer);
        }
    }

    /** Each frame: a picture its queue let go is forgotten; one the queue lost (or never drew) is let go on the render thread. */
    private void graves() {
        for (int index = dying.size() - 1; index >= 0; index--) {
            Grave grave = dying.get(index);
            if (grave.done()) { dying.remove(index); continue; }
            if (grave.frames < 0 || ++grave.frames < BURIAL_FRAMES) continue;
            dying.remove(index);
            Dust.Gl gl = dust;
            try { if (gl != null) gl.onRenderThread(grave.destroy); }
            catch (Throwable failure) { if (!reported) System.err.println("[PZExt] text: " + failure); reported = true; }
        }
    }

    // ---- titles ----

    /** The styles of {@code text.title}: how the title and the line under it look and move. */
    static final class Styles {
        /**
         * One style: the title's text and the line's, as specs of {@code show}; the gap between them in the title's lines, and how
         * many seconds after the title the line starts to leave.
         */
        record Style(Map<String, Object> title, Map<String, Object> line, double gap, double trail) { }

        static final Map<String, Style> ALL = new LinkedHashMap<>();

        static {
            // Stamped: big pale letters that fall onto the screen and hit, white-hot and cooling, a gleam passing over them once as
            // they stay; they weather away in place. For something done (a quest complete).
            ALL.put("stamp", new Style(
                Map.ofEntries(Map.entry("font", List.of("SdfBold", "Large")), Map.entry("size", 0.1), Map.entry("color", List.of(0.9, 0.89, 0.86, 1.0)),
                    Map.entry("shadow", true), Map.entry("outline", 1.0), Map.entry("outlineColor", List.of(0.0, 0.0, 0.0, 0.45)),
                    Map.entry("y", 0.28), Map.entry("enter", "impact"), Map.entry("enterTime", 0.6), Map.entry("hold", 5.0), Map.entry("backdrop", 0.3),
                    Map.entry("leave", "erode"), Map.entry("leaveTime", 6.0)),
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Medium")), Map.entry("size", 0.045), Map.entry("color", List.of(0.9, 0.9, 0.88, 1.0)),
                    Map.entry("shadow", true), Map.entry("delay", 0.45), Map.entry("enter", "slide"), Map.entry("enterTime", 0.5),
                    Map.entry("leave", "erode"), Map.entry("leaveTime", 5.6)),
                0.25, 0.4));
            // Found: warm amber letters a torch sways in over and lights, flickering once as they stay; it dies down to embers as
            // they go. For something found (a search complete).
            ALL.put("discovery", new Style(
                Map.ofEntries(Map.entry("font", List.of("SdfBold", "Large")), Map.entry("size", 0.08), Map.entry("color", List.of(1.0, 0.8, 0.38, 1.0)),
                    Map.entry("shadow", true), Map.entry("outline", 1.0), Map.entry("outlineColor", List.of(0.0, 0.0, 0.0, 0.35)),
                    Map.entry("y", 0.28), Map.entry("enter", "torch"), Map.entry("enterTime", 2.2), Map.entry("hold", 5.0), Map.entry("backdrop", 0.3),
                    Map.entry("leave", "dim"), Map.entry("leaveTime", 4.5)),
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Medium")), Map.entry("size", 0.042), Map.entry("color", List.of(1.0, 0.93, 0.78, 1.0)),
                    Map.entry("shadow", true), Map.entry("delay", 1.5), Map.entry("enter", "slide"), Map.entry("enterTime", 0.8),
                    Map.entry("leave", "dim"), Map.entry("leaveTime", 4.3)),
                0.3, 0.15));
            // A notice: a smaller line near the top of the screen that comes in as a radio signal tuned in, hiccups once, and is
            // lost into the static. For news that is not an event of its own.
            ALL.put("notice", new Style(
                Map.ofEntries(Map.entry("font", List.of("SdfBold", "Medium")), Map.entry("size", 0.04), Map.entry("color", List.of(0.88, 0.93, 1.0, 1.0)),
                    Map.entry("shadow", true), Map.entry("y", 0.2), Map.entry("enter", "signal"), Map.entry("enterTime", 0.7), Map.entry("hold", 5.0),
                    Map.entry("backdrop", 0.3), Map.entry("leave", "lost"), Map.entry("leaveTime", 4.5)),
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Small")), Map.entry("size", 0.028), Map.entry("color", List.of(0.76, 0.82, 0.9, 1.0)),
                    Map.entry("shadow", true), Map.entry("delay", 0.25), Map.entry("enter", "signal"), Map.entry("enterTime", 0.7),
                    Map.entry("leave", "lost"), Map.entry("leaveTime", 4.3)),
                0.3, 0.1));
            // Unveiled: soft warm letters the mist clears off slowly, a veil of it drifting behind as they stay; they sink back into
            // it as they go. For something that opens (a new chapter, a new path).
            ALL.put("unveil", new Style(
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Large")), Map.entry("size", 0.075), Map.entry("color", List.of(0.96, 0.93, 0.86, 1.0)),
                    Map.entry("shadow", true), Map.entry("outline", 1.0), Map.entry("outlineColor", List.of(0.0, 0.0, 0.0, 0.35)),
                    Map.entry("y", 0.28), Map.entry("enter", "mist"), Map.entry("enterTime", 3.6), Map.entry("hold", 5.0), Map.entry("backdrop", 0.3),
                    Map.entry("leave", "mist"), Map.entry("leaveTime", 5.0)),
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Medium")), Map.entry("size", 0.036), Map.entry("color", List.of(0.84, 0.83, 0.8, 1.0)),
                    Map.entry("shadow", true), Map.entry("delay", 1.2), Map.entry("enter", "mist"), Map.entry("enterTime", 3.0),
                    Map.entry("leave", "mist"), Map.entry("leaveTime", 4.8)),
                0.35, 0.3));
            // Burnt: a quiet title that fades in slowly, stays, and burns away like paper from its top right corner, its ash and
            // sparks taken by the wind; its line burns a moment after it. For something that ends.
            ALL.put("dust", new Style(
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Large")), Map.entry("size", 0.085), Map.entry("color", List.of(0.97, 0.95, 0.9, 1.0)),
                    Map.entry("shadow", true), Map.entry("outline", 1.0), Map.entry("outlineColor", List.of(0.0, 0.0, 0.0, 0.35)),
                    Map.entry("y", 0.28), Map.entry("enter", "fade"), Map.entry("enterTime", 1.2), Map.entry("hold", 5.0), Map.entry("backdrop", 0.3),
                    Map.entry("leave", "burn"), Map.entry("leaveTime", 10.0), Map.entry("dustSweep", "downleft")),
                Map.ofEntries(Map.entry("font", List.of("SdfRegular", "Medium")), Map.entry("size", 0.04), Map.entry("color", List.of(0.86, 0.85, 0.82, 1.0)),
                    Map.entry("shadow", true), Map.entry("delay", 0.35), Map.entry("enter", "fade"), Map.entry("enterTime", 1.2),
                    Map.entry("leave", "burn"), Map.entry("leaveTime", 10.0), Map.entry("dustSweep", "downleft")),
                0.3, 0.3));
        }

        private Styles() { }
    }

    /**
     * {@code text.title}: a title in a style, with a line under it when {@code subtitle} is given, queued on each player's screen
     * so that one title follows another. {@code now} lets it go first: the title on the screen leaves at once (quickly).
     */
    private long title(String owner, Object spec, String call) throws ReflectiveOperationException {
        String style = "stamp", line = null;
        Object text = null, color = null, lineColor = null, hold = null, player = null, y = null, leave = null, leaveTime = null, backdrop = null;
        var dusts = new LinkedHashMap<String, Object>();
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
                case "leave" -> leave = value;
                case "leaveTime" -> leaveTime = value;
                case "backdrop" -> backdrop = value;
                case "dustSize", "dustSweep", "dustDrift", "dustBurn" -> dusts.put(field, value);
                case "now" -> {
                    if (!(value instanceof Boolean on)) throw new IllegalArgumentException(call + ": spec.now must be true or false");
                    now = on;
                }
                default -> throw new IllegalArgumentException(call + ": spec has no field " + field
                    + "; it takes text, subtitle, style, color, subtitleColor, hold, y, player, leave, leaveTime, backdrop, dustSize, dustSweep, dustDrift,"
                    + " dustBurn and now");
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
        if (backdrop != null) big.backdrop = number(backdrop, call, "spec.backdrop", 0, 1);
        if (player != null) big.player = player(player, call, "spec.player");
        // The way out, for the title and its line alike.
        if (leave != null) big.leave = effect(Leave.class, leave, call, "spec.leave");
        if (leaveTime != null) big.leaveTime = number(leaveTime, call, "spec.leaveTime", 0, MAX_SECONDS);
        for (var field : dusts.entrySet()) {
            if (big.leave != Leave.DUST && big.leave != Leave.BURN)
                throw new IllegalArgumentException(call + ": spec." + field.getKey() + " goes with leave = \"dust\" or \"burn\"");
            dust(big, field.getKey(), field.getValue(), call, "spec." + field.getKey());
        }
        if (small != null) {
            if (leave != null) small.leave = big.leave;
            if (leaveTime != null) small.leaveTime = big.leaveTime;
            small.dustSize = big.dustSize; small.dustDrift = big.dustDrift; small.dustSweep = big.dustSweep; small.dustBurn = big.dustBurn;
            small.lines = lines(line, call, "spec.subtitle");
            font(small, chosen.line().get("font"), call, "spec.font");
            if (lineColor != null) { float[] parts = color(lineColor, call, "spec.subtitleColor"); small.red = parts[0]; small.green = parts[1]; small.blue = parts[2]; small.alpha = parts[3]; }
            small.player = big.player;
            // Under the title: its block, a gap, then the line's block, as shares of the screen's height.
            small.y = Math.min(1, big.y + big.size * big.lines.length / 2 + big.size * chosen.gap() + small.size * small.lines.length / 2);
            // It goes as the title goes, or the style's moment after it.
            small.hold = Math.max(0, big.enterTime + big.hold - small.delay - small.enterTime + chosen.trail());
            // The title's backdrop reaches over its line: one backdrop for both.
            small.backdrop = 0;
            big.backdropBelow = Math.max(0, small.y + small.size * small.lines.length / 2 - big.y - big.size * big.lines.length / 2);
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
            Shown under = small == null ? null : keyed(small, key, screen);
            if (under != null) under.lead = title;
            enqueue(under == null ? List.of(title) : List.of(title, under), now);
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
        to.source = from.source; to.markup = from.markup; to.width = from.width; to.speed = from.speed; to.cursor = from.cursor;
        to.script = from.script;
        to.dustSize = from.dustSize; to.dustDrift = from.dustDrift; to.dustSweep = from.dustSweep; to.dustBurn = from.dustBurn;
        to.backdrop = from.backdrop; to.backdropBelow = from.backdropBelow;
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
        EmbeddedFont.Loaded own = embedded;
        embeddedReady = own != null && own.ready.get();
        try {
            if (moves.moved() && game.cell() != world) {
                Object cell = game.cell();
                world = cell;
                if (shown.removeIf(text -> text.cell != cell)) { publish(); dirty = true; }
            }
            if (dirty) write();
            if (!dying.isEmpty()) graves();
        } catch (Throwable failure) {
            // Once: a fault that recurs each frame must not flood the game's log. The drawing goes on.
            if (!reported) System.err.println("[PZExt] text: " + failure);
            reported = true;
        }
    }

    // ---- the drawing (the hook) ----

    @Override public void draw() {
        Shown[] all = drawn;
        if (all.length == 0 && dying.isEmpty()) return;
        try { if (!dying.isEmpty()) bury(); }
        catch (Throwable failure) { throw Texts.<RuntimeException>sneaky(failure); }
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
                    if (!draw(text, now, screen, left, top, width, height)) { text.done = true; finished = true; }
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
    private boolean draw(Shown text, long now, int screen, int left, int top, int width, int height) throws Throwable {
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
        // Its alpha, scale and move (in lines; across, in lines too: the impact's shake), and the impact's squash.
        double alpha = 1, scale = 1, shift = 0, across = 0, squashX = 1, squashY = 1;
        switch (text.enter) {
            case NONE, TYPE, TORCH, SIGNAL, MIST -> { } // The looks' own.
            case FADE -> alpha = smooth(in);
            case POP -> { alpha = Math.min(1, in * 2); scale = 0.5 + 0.5 * backOut(in); }
            case SLAM -> { alpha = Math.min(1, in * 3); scale = 1 + 1.5 * (1 - in * in); }
            case SETTLE -> { alpha = smooth(in); shift = -SETTLE * (1 - cubicOut(in)); }
            case RISE -> { alpha = cubicOut(in); shift = RISE * (1 - cubicOut(in)); }
            case DROP -> { alpha = cubicOut(in); shift = -RISE * (1 - cubicOut(in)); }
            case SLIDE -> { alpha = cubicOut(in); shift = SLIDE * (1 - cubicOut(in)); }
            case IMPACT -> {
                Looks.impact(Math.min(t, leaving), hit);
                alpha = hit[0]; scale = hit[1]; squashX = hit[2]; squashY = hit[3]; across = hit[4]; shift = hit[5];
            }
        }
        double entered = alpha;
        switch (text.leave) {
            case NONE -> { }
            case FADE -> alpha *= 1 - smooth(out);
            case RISE -> { alpha *= 1 - out; shift -= DRIFT * out; }
            case SINK -> { alpha *= 1 - out; shift += DRIFT * out; }
            case GROW -> { alpha *= 1 - out; scale *= 1 + 0.3 * out; }
            case SHRINK -> { alpha *= 1 - out; scale *= 1 - 0.5 * out; }
            case ERODE, LOST, MIST -> alpha *= 1 - smooth(out); // As the looks take the text (its backdrop goes so).
            case DIM -> alpha *= 1 - smooth(Looks.clamp((out - 0.4) / 0.6, 0, 1));
            case DUST, BURN -> { } // Below, once the text is placed: as dust or burning, or a fade.
        }
        boolean look = looked(text);
        float shownAlpha = (float)(alpha * text.alpha);
        if (shownAlpha <= INVISIBLE && text.leave != Leave.DUST && !look) return true;
        Object font = text.font;
        Object angel = (Object)fontOf.invokeExact(textManager, font);
        if (angel != text.gameFont) {
            text.gameFont = angel;
            text.gameLineHeight = (int)fontHeight.invokeExact(textManager, font);
        }
        if (text.gameLineHeight <= 0) return true;
        // A line's height in pixels before the effects: the embedded font draws it when that is more than the game's fonts are made
        // for (and the game's font would be zoomed past its size).
        double requested = text.size > 0 ? text.size * height : text.gameLineHeight * text.scale;
        EmbeddedFont.Loaded own = embedded;
        boolean large = large(text, own, font, requested);
        Object face = large ? own.font : angel;
        if (face != text.measuredWith || text.script == null && text.widths == null) {
            text.face = large ? own.font : null;
            measure(text, face, large ? own.lineHeight : 0);
        }
        if (text.lineHeight <= 0) return true;
        double base = large ? requested / text.lineHeight : text.size > 0 ? text.size * height / text.lineHeight : text.scale;
        double zoom = base * scale;
        double line = text.lineHeight * zoom;
        double anchorX = left + text.x * width + across * line, anchorY = top + text.y * height + shift * line;
        Script script = text.script;
        Layout laid = null;
        int typed = 0;
        if (script != null) {
            // The rows are those of the text at its own size, not the effect's: a growing text is not broken again.
            if (text.layouts == null) text.layouts = new Layout[PLAYERS];
            laid = text.layouts[screen];
            if (laid == null || laid.font != face || laid.width != width || laid.height != height) laid = text.layouts[screen] = layout(text, face, width, height, base);
            typed = script.shown(Math.min(t, leaving));
        }
        int rowCount = laid == null ? text.lines.length : laid.rows.length;
        double firstY = anchorY - line * rowCount / 2;
        // At rest: the place and size a look's picture is made at.
        double restLine = text.lineHeight * base, restX = left + text.x * width, restFirst = top + text.y * height - restLine * rowCount / 2;
        if (text.backdrop > 0) {
            // As strong as the text is seen, coming in over BACKDROP_IN at most as fast; a text that crumbles or burns takes it with
            // it over its leave. A look's stays at the text's place at rest.
            double seen = Math.min(smooth(Math.min(1, t / Looks.BACKDROP_IN)),
                text.leave == Leave.DUST || text.leave == Leave.BURN ? alpha * (1 - smooth(out)) : alpha);
            if (seen > INVISIBLE) {
                if (look) backdrop(text, laid, restX, restFirst, base, restLine, rowCount, height, seen);
                else backdrop(text, laid, anchorX, firstY, zoom, line, rowCount, height, seen);
            }
        }
        if (look) {
            Looks.Gl drawing = looks;
            if (drawing != null && !drawing.failed && dust != null
                && look(text, screen, laid, typed, t, leaving, out, restX, restFirst, base, restLine, rowCount, large, own, font, entered, alpha, scale,
                    squashX, squashY, across, shift, now)) return true;
            // No picture (yet): the text as it is, a look's enter and leave a fade.
            if (text.enter == Enter.TORCH || text.enter == Enter.SIGNAL || text.enter == Enter.MIST) alpha *= smooth(in);
            if (text.leave == Leave.BURN) alpha *= 1 - smooth(out);
            shownAlpha = (float)(alpha * text.alpha);
            if (shownAlpha <= INVISIBLE) return true;
        }
        if (text.leave == Leave.DUST) {
            Dust.Gl gl = dust;
            Dust.Piece piece = gl == null ? null : piece(text, screen);
            if (piece != null && !piece.released && (t >= text.enterTime || t >= leaving)) {
                // The text stands still: its picture is made, drawn into, read back and cut, a frame or so each.
                try { dust(gl, piece, text, laid, typed, t, anchorX, firstY, zoom, line, rowCount, large, own, font, shownAlpha, alpha); }
                catch (Throwable failure) {
                    if (failure instanceof VirtualMachineError fatal && !(fatal instanceof OutOfMemoryError)) throw fatal;
                    gl.report("the dust could not be made", failure);
                    piece.phase = Dust.FAILED;
                }
                if (piece.phase == Dust.FAILED) letGo(piece);
            }
            if (out > 0) {
                boolean usable = piece != null && !piece.released;
                if (usable && piece.phase == Dust.CUT) {
                    gl.draw(piece, out, 1, text.dustDrift);
                    return true;
                }
                // Its picture on its way: the text as it was for a moment, then a fade.
                if (!(usable && piece.pending() && out < Dust.PENDING)) alpha *= 1 - smooth(out);
                shownAlpha = (float)(alpha * text.alpha);
            }
            if (shownAlpha <= INVISIBLE) return true;
        }
        paintAll(text, laid, typed, t, anchorX, firstY, zoom, line, large, own, font, shownAlpha, alpha, true);
        return true;
    }

    /** Whether the text has a look: an enter or a leave the API's shader draws ({@link Looks}). */
    static boolean looked(Shown text) {
        return switch (text.enter) { case IMPACT, TORCH, SIGNAL, MIST -> true; default -> false; }
            || switch (text.leave) { case ERODE, DIM, LOST, MIST, BURN -> true; default -> false; };
    }

    /** The look drawn over the text's life: the torch's, the radio's, the mist's, or none (the impact, erode and burn alone). */
    static int lookOf(Shown text) {
        if (text.enter == Enter.TORCH || text.leave == Leave.DIM) return Looks.TORCH;
        if (text.enter == Enter.SIGNAL || text.leave == Leave.LOST) return Looks.RADIO;
        if (text.enter == Enter.MIST || text.leave == Leave.MIST) return Looks.FOG;
        return Looks.PLAIN;
    }

    /**
     * A step of the text's look on one screen: its picture made for its box at rest, the text drawn into it (once typed), and,
     * when the picture is there (and for a burn, its cells and map), a frame of it handed to the render queue. False when the
     * look cannot draw yet or at all: the text is drawn as it is. A box that moved since (the screen's size changed) gives it up.
     */
    private boolean look(Shown text, int screen, Layout laid, int typed, double t, double leaving, double out, double anchorX, double firstY,
            double zoom, double line, int rowCount, boolean large, EmbeddedFont.Loaded own, Object font, double entered, double alpha, double scale,
            double squashX, double squashY, double across, double shift, long now) throws Throwable {
        if (text.enter == Enter.TYPE && t < text.enterTime && t < leaving) return false;
        Dust.Gl gl = dust;
        Dust.Piece piece = piece(text, screen);
        if (piece.released) return false;
        double low = Double.POSITIVE_INFINITY, high = Double.NEGATIVE_INFINITY;
        for (int index = 0; index < rowCount; index++) {
            double lineWidth = (laid == null ? text.widths[index] : laid.rows[index].width) * zoom;
            if (lineWidth <= 0) continue;
            double x = text.align < 0 ? anchorX : text.align > 0 ? anchorX - lineWidth : anchorX - lineWidth / 2;
            low = Math.min(low, x);
            high = Math.max(high, x + lineWidth);
        }
        if (!(low <= high)) { letGo(piece); return false; }
        double margin = Math.ceil(line * Dust.MARGIN + text.outline + Math.max(1, Math.round(line / 24)) + 2);
        int boxX = (int)Math.floor(low - margin), boxY = (int)Math.floor(firstY - margin);
        int boxWidth = (int)Math.ceil(high + margin) - boxX, boxHeight = (int)Math.ceil(firstY + line * rowCount + margin) - boxY;
        try {
            switch (piece.phase) {
                case Dust.NEW -> { if (!gl.make(piece, boxX, boxY, boxWidth, boxHeight, line)) piece.phase = Dust.FAILED; }
                case Dust.READY -> {
                    if (!piece.at(boxX, boxY, boxWidth, boxHeight)) { piece.phase = Dust.FAILED; break; }
                    Object before = gl.beginCapture(piece);
                    try { paintAll(text, laid, typed, t, anchorX, firstY, zoom, line, large, own, font, text.alpha, 1, false); }
                    finally { gl.endCapture(piece, before); }
                }
                case Dust.CAPTURED -> {
                    if (!piece.at(boxX, boxY, boxWidth, boxHeight)) { piece.phase = Dust.FAILED; break; }
                    if (text.leave != Leave.BURN) { piece.pixels = null; piece.phase = Dust.CUT; }
                    else if (!piece.cutting) { piece.cutting = true; burnCut(piece, Dust.cell(line, text.dustSize), text.dustSweep); }
                }
                case Dust.CUT -> { if (!piece.at(boxX, boxY, boxWidth, boxHeight)) piece.phase = Dust.FAILED; }
                default -> { }
            }
        } catch (Throwable failure) {
            if (failure instanceof VirtualMachineError fatal && !(fatal instanceof OutOfMemoryError)) throw fatal;
            gl.report("a look's picture could not be made", failure);
            piece.phase = Dust.FAILED;
        }
        if (piece.phase == Dust.FAILED) { letGo(piece); return false; }
        if (piece.phase != Dust.CUT) return false;
        Looks.Gl drawing = looks;
        if (piece.frames == null) {
            var frames = new Looks.Frame[LOOK_FRAMES];
            for (int index = 0; index < frames.length; index++) {
                frames[index] = new Looks.Frame(piece, drawing);
                frames[index].drawer = gl.drawer(frames[index]);
            }
            piece.looks = drawing;
            piece.frames = frames;
        }
        Looks.Frame f = piece.frames[piece.frameAt];
        piece.frameAt = (piece.frameAt + 1) % piece.frames.length;
        f.look = lookOf(text);
        f.impact = text.enter == Enter.IMPACT;
        f.erode = text.leave == Leave.ERODE;
        f.burn = text.leave == Leave.BURN;
        f.lead = text.enter == Enter.TORCH;
        f.cx = piece.boxX + piece.boxWidth / 2.0;
        f.cy = piece.boxY + piece.boxHeight / 2.0;
        f.line = line;
        f.ink = high - low;
        f.s = scale; f.sx = squashX; f.sy = squashY;
        f.dx = across * line;
        f.dy = shift * line * scale;
        f.enterAlpha = entered;
        f.alpha = alpha;
        f.left = entered > 0 ? alpha / entered : 0;
        f.secs = t;
        f.out = out;
        f.enterTime = text.enterTime;
        f.scheduled = text.enterTime + text.hold;
        f.leaving = leaving;
        f.group = (now - text.start) / SECOND;
        Shown lead = text.lead != null ? text.lead : text;
        f.cue = lead.delay + lead.enterTime;
        f.drift = text.dustDrift;
        float[] burn = text.dustBurn != null ? text.dustBurn : Looks.BURN;
        f.burnRed = burn[0]; f.burnGreen = burn[1]; f.burnBlue = burn[2];
        gl.buryDrawer(f.drawer);
        return true;
    }

    /**
     * A burn's cells and map, made from its picture's pixels away from the main thread (a few tens of milliseconds for a title):
     * the piece is CUT once they are there, or FAILED.
     */
    private static void burnCut(Dust.Piece piece, double size, Dust.Sweep sweep) {
        java.util.concurrent.ForkJoinPool.commonPool().execute(() -> {
            try {
                var pixels = piece.pixels;
                int width = piece.boxWidth, height = piece.boxHeight;
                // The rows read back are from the bottom of the box.
                Dust.Cells cells = Dust.Cells.of((x, y) -> pixels.get(((height - 1 - y) * width + x) * 4 + 3) & 0xFF, width, height, size, sweep,
                    piece.seed, Dust.MAX_CELLS);
                if (cells == null) { piece.phase = Dust.FAILED; return; }
                float[] map = Looks.burnMap(width, height, size, piece.seed, sweep);
                Looks.startsFromMap(cells, map, width, height);
                piece.cells = cells;
                piece.map = Looks.encode(map);
                piece.pixels = null;
                piece.phase = Dust.CUT;
            } catch (RuntimeException | OutOfMemoryError failure) {
                System.err.println("[PZExt] text: a burn could not be made; it fades instead: " + failure);
                piece.phase = Dust.FAILED;
            }
        });
    }

    /**
     * The text's backdrop: a dark box over its lines (and below them by {@code backdropBelow}) whose edge fades out over
     * {@link #BACKDROP_SIDE} line heights to the sides and {@link #BACKDROP_END} up and down, as one layer: the box, and rings
     * round it each shaded by the card from its inside to its outside between the points of a smooth step, at the text's own
     * place (not whole pixels), so that it fades and moves as smoothly as the text. Allocates nothing.
     */
    private void backdrop(Shown text, Layout laid, double anchorX, double firstY, double zoom, double line, int rowCount, int height, double seen)
            throws Throwable {
        double low = Double.POSITIVE_INFINITY, high = Double.NEGATIVE_INFINITY;
        for (int index = 0; index < rowCount; index++) {
            double lineWidth = (laid == null ? text.widths[index] : laid.rows[index].width) * zoom;
            if (lineWidth <= 0) continue;
            double x = text.align < 0 ? anchorX : text.align > 0 ? anchorX - lineWidth : anchorX - lineWidth / 2;
            low = Math.min(low, x);
            high = Math.max(high, x + lineWidth);
        }
        if (!(low <= high)) return;
        double top = firstY, bottom = firstY + line * rowCount + text.backdropBelow * height;
        double side = BACKDROP_SIDE * line, end = BACKDROP_END * line, strength = text.backdrop * seen;
        shade(low, top, high, top, high, bottom, low, bottom, (float)strength, (float)strength, (float)strength, (float)strength);
        for (int ring = 0; ring < BACKDROP_RINGS; ring++) {
            double in = (double)ring / BACKDROP_RINGS, out = (double)(ring + 1) / BACKDROP_RINGS;
            float inner = (float)(strength * (1 - smooth(in))), outer = (float)(strength * (1 - smooth(out)));
            double ix0 = low - side * in, ix1 = high + side * in, iy0 = top - end * in, iy1 = bottom + end * in;
            double ox0 = low - side * out, ox1 = high + side * out, oy0 = top - end * out, oy1 = bottom + end * out;
            // The sides, then the corners (their inner corner the darkest), clockwise from the top left.
            shade(ix0, oy0, ix1, oy0, ix1, iy0, ix0, iy0, outer, outer, inner, inner);
            shade(ix1, iy0, ox1, iy0, ox1, iy1, ix1, iy1, inner, outer, outer, inner);
            shade(ix0, iy1, ix1, iy1, ix1, oy1, ix0, oy1, inner, inner, outer, outer);
            shade(ox0, iy0, ix0, iy0, ix0, iy1, ox0, iy1, outer, inner, inner, outer);
            shade(ox0, oy0, ix0, oy0, ix0, iy0, ox0, iy0, outer, outer, inner, outer);
            shade(ix1, oy0, ox1, oy0, ox1, iy0, ix1, iy0, outer, outer, outer, inner);
            shade(ix1, iy1, ox1, iy1, ox1, oy1, ix1, oy1, inner, outer, outer, outer);
            shade(ox0, iy1, ix0, iy1, ix0, oy1, ox0, oy1, outer, inner, outer, outer);
        }
    }

    /** A black quad, its corners clockwise from the top left, each with its alpha. */
    private void shade(double x1, double y1, double x2, double y2, double x3, double y3, double x4, double y4, float a1, float a2, float a3, float a4)
            throws Throwable {
        renderShaded.invokeExact(sprites, (Object)null, x1, y1, x2, y2, x3, y3, x4, y4, 0f, 0f, 0f, a1, 0f, 0f, 0f, a2, 0f, 0f, 0f, a3, 0f, 0f, 0f, a4,
            (Object)null);
    }

    /**
     * A step of the text's dust once it stands still, at its place now: the picture made for its box, the text drawn into it, the
     * picture read back cut into cells. A box that moved since (the screen's size changed) gives up the dust: the text fades.
     */
    private void dust(Dust.Gl gl, Dust.Piece piece, Shown text, Layout laid, int typed, double t, double anchorX, double firstY, double zoom,
            double line, int rowCount, boolean large, EmbeddedFont.Loaded own, Object font, float shownAlpha, double alpha) throws Throwable {
        double low = Double.POSITIVE_INFINITY, high = Double.NEGATIVE_INFINITY;
        for (int index = 0; index < rowCount; index++) {
            double lineWidth = (laid == null ? text.widths[index] : laid.rows[index].width) * zoom;
            if (lineWidth <= 0) continue;
            double x = text.align < 0 ? anchorX : text.align > 0 ? anchorX - lineWidth : anchorX - lineWidth / 2;
            low = Math.min(low, x);
            high = Math.max(high, x + lineWidth);
        }
        if (!(low <= high)) { piece.phase = Dust.FAILED; return; }
        // Glyphs reach past their advance; the shadow and outline past the glyphs.
        double margin = Math.ceil(line * Dust.MARGIN + text.outline + Math.max(1, Math.round(line / 24)) + 2);
        int boxX = (int)Math.floor(low - margin), boxY = (int)Math.floor(firstY - margin);
        int boxWidth = (int)Math.ceil(high + margin) - boxX, boxHeight = (int)Math.ceil(firstY + line * rowCount + margin) - boxY;
        switch (piece.phase) {
            case Dust.NEW -> { if (!gl.make(piece, boxX, boxY, boxWidth, boxHeight, line)) piece.phase = Dust.FAILED; }
            case Dust.READY -> {
                if (!piece.at(boxX, boxY, boxWidth, boxHeight)) { piece.phase = Dust.FAILED; return; }
                // Drawn once more, into the picture, as it is now (no cursor): what the dust is made of.
                Object before = gl.beginCapture(piece);
                try { paintAll(text, laid, typed, t, anchorX, firstY, zoom, line, large, own, font, shownAlpha, alpha, false); }
                finally { gl.endCapture(piece, before); }
            }
            case Dust.CAPTURED -> {
                if (!piece.at(boxX, boxY, boxWidth, boxHeight) || !Dust.Gl.cut(piece, Dust.cell(line, text.dustSize), text.dustSweep)) piece.phase = Dust.FAILED;
            }
            case Dust.CUT -> { if (!piece.at(boxX, boxY, boxWidth, boxHeight)) piece.phase = Dust.FAILED; }
            default -> { }
        }
    }

    /** The text's lines or rows as they are at {@code t}, in the shader for a distance-field font; the cursor with {@code cursor}. */
    private void paintAll(Shown text, Layout laid, int typed, double t, double anchorX, double firstY, double zoom, double line, boolean large,
            EmbeddedFont.Loaded own, Object font, float shownAlpha, double alpha, boolean cursor) throws Throwable {
        Script script = text.script;
        boolean distance = large || (boolean)sdf.invokeExact(textManager, font);
        Object shader = distance ? sdfShader.get(null) : null;
        if (shader != null) {
            // As the game's own distance-field text (AtomUIText): an edge as sharp as the zoom, no outline, no shadow of its own. The
            // embedded font's atlas spans its own distance: its edge is a pixel and a half wide on the screen at any zoom.
            threshold.invokeExact(shader, (float)(large ? EmbeddedFont.EDGE / (2 * own.spread * zoom) : 0.125 / zoom));
            shaderShadow.invokeExact(shader, 0f);
            shaderOutline.invokeExact(shader, 0f, 0f, 0f, 0f, 0f);
            startShader.invokeExact(shader);
        }
        try {
            if (laid == null) {
                for (int index = 0; index < text.lines.length; index++) {
                    String words = text.lines[index];
                    if (words.isEmpty()) continue;
                    double lineWidth = text.widths[index] * zoom;
                    double x = text.align < 0 ? anchorX : text.align > 0 ? anchorX - lineWidth : anchorX - lineWidth / 2;
                    paint(text, words, x, firstY + line * index, zoom, line, text.red, text.green, text.blue, shownAlpha, alpha);
                }
            } else {
                // The rows by the characters that have come on: a row is placed by its whole width, so typing moves nothing.
                Row[] rows = laid.rows;
                for (int index = 0; index < rows.length && rows[index].from < typed; index++) {
                    Row row = rows[index];
                    double lineWidth = row.width * zoom;
                    double x = text.align < 0 ? anchorX : text.align > 0 ? anchorX - lineWidth : anchorX - lineWidth / 2;
                    double y = firstY + line * index;
                    for (Seg seg : row.segs) {
                        if (seg.from >= typed) break;
                        int tint = seg.tint;
                        paint(text, seg.to <= typed ? seg.text : part(seg, typed - seg.from), x + seg.x * zoom, y, zoom, line,
                            tint < 0 ? text.red : (tint >> 16 & 0xFF) / 255f, tint < 0 ? text.green : (tint >> 8 & 0xFF) / 255f,
                            tint < 0 ? text.blue : (tint & 0xFF) / 255f, shownAlpha, alpha);
                    }
                }
                // The cursor sits after the last character that came on and stays on while characters come on; it blinks while it waits.
                if (cursor && text.cursor && (t - (typed > 0 ? script.at[typed - 1] : 0)) % (2 * BLINK) < BLINK) {
                    int at = 0;
                    while (at + 1 < rows.length && rows[at + 1].from < typed) at++;
                    Row row = rows[at];
                    double lineWidth = row.width * zoom, beside = 0;
                    for (Seg seg : row.segs) {
                        if (seg.from >= typed) break;
                        beside = seg.x + partWidth(text, seg, Math.min(seg.to, typed) - seg.from);
                    }
                    double x = text.align < 0 ? anchorX : text.align > 0 ? anchorX - lineWidth : anchorX - lineWidth / 2;
                    paint(text, CURSOR, x + beside * zoom, firstY + line * at, zoom, line, text.red, text.green, text.blue, shownAlpha, alpha);
                }
            }
        } finally {
            if (shader != null) endShader.invokeExact();
        }
    }

    /** One string with the text's shadow and outline, and then in the colour given. */
    private void paint(Shown text, String words, double x, double y, double zoom, double line, float red, float green, float blue, float shownAlpha, double alpha)
        throws Throwable {
        if (text.face != null) { paintFace(text, words, x, y, zoom, line, red, green, blue, shownAlpha, alpha); return; }
        Object font = text.font;
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
        drawString.invokeExact(textManager, font, x, y, zoom, words, (double)red, (double)green, (double)blue, (double)shownAlpha);
    }

    /** {@link #paint} in the embedded font: its AngelCodeFont draws as TextManager.DrawString has the game's draw. */
    private void paintFace(Shown text, String words, double x, double y, double zoom, double line, float red, float green, float blue, float shownAlpha,
            double alpha) throws Throwable {
        Object face = text.face;
        if (text.shadow) {
            double offset = Math.max(1, Math.round(line / 24));
            faceDraw.invokeExact(face, (float)(x + offset), (float)(y + offset), (float)zoom, words, 0f, 0f, 0f, shownAlpha * 0.55f);
        }
        if (text.outline > 0) {
            double o = text.outline;
            float a = (float)(alpha * text.outlineAlpha);
            for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) {
                if (dx == 0 && dy == 0) continue;
                faceDraw.invokeExact(face, (float)(x + dx * o), (float)(y + dy * o), (float)zoom, words, text.outlineRed, text.outlineGreen,
                    text.outlineBlue, a);
            }
        }
        faceDraw.invokeExact(face, (float)x, (float)y, (float)zoom, words, red, green, blue, shownAlpha);
    }

    /**
     * Whether the embedded font draws the text now: it is in video memory, the line asked for is taller than the game's font the
     * text's list picked is made at (that font would be zoomed past its size, and blur), that font is not a distance-field one
     * (those are sharp at any size), and the embedded font has every character of the text (else the game's font draws all of
     * it: no character is missing). Allocates nothing.
     */
    private boolean large(Shown text, EmbeddedFont.Loaded own, Object font, double requested) throws Throwable {
        if (own == null || !own.ready.get() || requested <= text.gameLineHeight) return false;
        if ((boolean)sdf.invokeExact(textManager, font)) return false;
        if (text.coveredBy != own) {
            text.covered = own.covers(text.lines, text.cursor, CURSOR.charAt(0));
            text.coveredBy = own;
        }
        return text.covered;
    }

    /** The width at zoom 1 of these characters in the font that draws the text. */
    private int width(Shown text, String words) throws Throwable {
        return text.face != null ? (int)faceWidth.invokeExact(text.face, words) : (int)measure.invokeExact(textManager, text.font, words);
    }

    /** The first {@code count} characters of a run, made the first time they are asked for (one string for each character typed). */
    private static String part(Seg seg, int count) {
        if (count >= seg.text.length()) return seg.text;
        String made = seg.part[count];
        return made != null ? made : (seg.part[count] = seg.text.substring(0, count));
    }

    /** The width at zoom 1 of the first {@code count} characters of a run, measured the first time it is asked for. */
    private float partWidth(Shown text, Seg seg, int count) throws Throwable {
        if (count <= 0) return 0;
        count = Math.min(count, seg.text.length());
        float known = seg.partWidth[count];
        if (known > 0) return known;
        return seg.partWidth[count] = width(text, part(seg, count));
    }

    // ---- the rows of a text with markup, typing or a width ----

    /**
     * Breaks a script's text into rows for a screen of this size: at the lines it has, and when it has a width, at the spaces (and
     * between the characters of the scripts written without them) that keep a row within it. The width is a share of the screen's,
     * measured with the game's font at the zoom the text has before its effects. Runs once for each size and font, not each frame.
     */
    private Layout layout(Shown text, Object angel, int width, int height, double zoom) throws Throwable {
        String plain = text.script.plain;
        double limit = text.width > 0 ? text.width * width / zoom : Double.POSITIVE_INFINITY;
        var rows = new ArrayList<Row>();
        for (int begin = 0; begin <= plain.length();) {
            int end = plain.indexOf('\n', begin);
            if (end < 0) end = plain.length();
            int start = begin;
            do {
                int stop = start == end ? end : fit(text, plain, start, end, limit);
                rows.add(row(text, start, stop));
                start = stop;
                // A row that was broken at spaces does not carry them over.
                if (stop < end) while (start < end && plain.charAt(start) == ' ') start++;
            } while (start < end);
            begin = end + 1;
        }
        var laid = new Layout();
        laid.font = angel;
        laid.width = width;
        laid.height = height;
        laid.rows = rows.toArray(new Row[0]);
        return laid;
    }

    /** Where the row that starts at {@code start} ends: at the paragraph's end if that fits, else at the last break that does. */
    private int fit(Shown text, String plain, int start, int end, double limit) throws Throwable {
        if (limit == Double.POSITIVE_INFINITY || fits(text, plain.substring(start, end), limit)) return end;
        int best = -1;
        for (int at = start + 1; at < end; at++) {
            // A break is before a word that follows spaces, or beside a character of a script written without them.
            if (plain.charAt(at) == ' ' || plain.charAt(at - 1) != ' ' && !wide(plain.charAt(at - 1)) && !wide(plain.charAt(at))) continue;
            int stop = at;
            while (stop > start && plain.charAt(stop - 1) == ' ') stop--;
            if (stop == start) continue;
            if (!fits(text, plain.substring(start, stop), limit)) break;
            best = stop;
        }
        if (best >= 0) return best;
        // A word wider than the row: as many of its characters as fit, one at least.
        int stop = start + 1;
        while (stop < end && fits(text, plain.substring(start, stop + 1), limit)) stop++;
        return stop;
    }

    private boolean fits(Shown text, String words, double limit) throws Throwable {
        return width(text, words) <= limit;
    }

    /** Whether the character is of a script written without spaces between words (Han, kana, full-width forms): a row may break beside it. */
    private static boolean wide(char letter) { return TextFits.wide(letter); }

    /** The row of the characters {@code from} to {@code to}: its width, and its runs of one colour with where each starts. */
    private Row row(Shown text, int from, int to) throws Throwable {
        Script script = text.script;
        String plain = script.plain;
        var row = new Row();
        row.from = from;
        row.to = to;
        row.width = from == to ? 0 : width(text, plain.substring(from, to));
        var segs = new ArrayList<Seg>();
        for (int at = from; at < to;) {
            int tint = script.tint == null ? -1 : script.tint[at], stop = at + 1;
            while (stop < to && (script.tint == null ? -1 : script.tint[stop]) == tint) stop++;
            var seg = new Seg();
            seg.from = at;
            seg.to = stop;
            seg.tint = tint;
            seg.text = plain.substring(at, stop);
            seg.x = at == from ? 0 : width(text, plain.substring(from, at));
            if (script.at != null) {
                seg.part = new String[seg.text.length()];
                seg.partWidth = new float[seg.text.length() + 1];
            }
            segs.add(seg);
            at = stop;
        }
        row.segs = segs.toArray(new Seg[0]);
        return row;
    }

    /**
     * The lines' widths (of a plain text) and the line height at zoom 1, for the font that draws it now: the game's (it changes with
     * the font size option), or the embedded font, whose line is {@code faceLine} high (its own fonts' lines run to their padding).
     */
    private void measure(Shown text, Object angel, int faceLine) throws Throwable {
        if (text.script == null) {
            if (text.widths == null || text.widths.length != text.lines.length) text.widths = new float[text.lines.length];
            for (int index = 0; index < text.lines.length; index++)
                text.widths[index] = text.lines[index].isEmpty() ? 0 : width(text, text.lines[index]);
        }
        text.lineHeight = text.face != null ? faceLine : (int)fontHeight.invokeExact(textManager, text.font);
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
            text.append("\nT\t").append(escape(s.owner)).append('\t').append(s.key).append('\t').append(escape(s.source != null ? s.source : String.join("\n", s.lines)))
                .append('\t').append(s.fontName).append('\t').append(s.scale).append('\t').append(s.size)
                .append('\t').append(s.red).append('\t').append(s.green).append('\t').append(s.blue).append('\t').append(s.alpha)
                .append('\t').append(s.outline).append('\t').append(s.outlineRed).append('\t').append(s.outlineGreen).append('\t').append(s.outlineBlue)
                .append('\t').append(s.outlineAlpha).append('\t').append(s.shadow).append('\t').append(s.x).append('\t').append(s.y)
                .append('\t').append(ALIGN_NAMES[s.align + 1]).append('\t').append(s.delay).append('\t').append(s.enter.name())
                .append('\t').append(s.enterTime).append('\t').append(s.hold).append('\t').append(s.leave.name()).append('\t').append(s.leaveTime)
                .append('\t').append(s.player).append('\t').append(s.queued).append('\t').append(s.waiting).append('\t').append(s.start)
                .append('\t').append(s.hidden).append('\t').append(s.markup).append('\t').append(s.width).append('\t').append(s.speed)
                .append('\t').append(s.cursor).append('\t').append(s.dustSize).append('\t').append(s.dustSweep.name()).append('\t').append(s.dustDrift)
                .append('\t').append(s.backdrop).append('\t').append(s.backdropBelow).append('\t').append(burnText(s.dustBurn));
        }
        lua.set(meta, MIRROR, text.toString());
        dirty = false;
    }

    /** A burn's colour in the kept text: its parts by commas, "-" for none. */
    private static String burnText(float[] burn) {
        return burn == null ? "-" : burn[0] + "," + burn[1] + "," + burn[2] + "," + burn[3];
    }

    private static float[] burnOf(String field) {
        if ("-".equals(field)) return null;
        String[] parts = field.split(",");
        return new float[] { Float.parseFloat(parts[0]), Float.parseFloat(parts[1]), Float.parseFloat(parts[2]), Float.parseFloat(parts[3]) };
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
            // The newer API draws from now on: it lets this one's pictures go from its drawing, after this one's last frames.
            var destroys = new ArrayList<Runnable>();
            for (Dust.Piece piece : pieces) { piece.released = true; if (piece.texture != null) destroys.add(piece); }
            pieces.clear();
            for (Grave grave : dying) if (!grave.done()) destroys.add(grave.destroy);
            dying.clear();
            Dust.orphan(destroys);
            return (String)lua.get(meta, MIRROR);
        } catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    /** What an earlier API showed, if anything: in this world, from where it was (the same process's clock). */
    private void load(Object kept) {
        if (!(kept instanceof String text)) return;
        String[] lines = text.split("\n");
        // The format before typing has the fields up to hidden; the text of those has no markup, typing or width. The format
        // before dust has the fields up to cursor; its texts have no dust. The format before backdrops has none; the one before burns, no burn.
        boolean before = FORMAT_BEFORE_TYPING.equals(lines[0]), beforeDust = before || FORMAT_BEFORE_DUST.equals(lines[0]);
        boolean beforeBackdrop = beforeDust || FORMAT_BEFORE_BACKDROP.equals(lines[0]);
        boolean beforeBurn = beforeBackdrop || FORMAT_BEFORE_BURN.equals(lines[0]);
        if (!beforeBurn && !FORMAT.equals(lines[0])) {
            System.err.println("[PZExt] text: what was shown is kept in another format; it is not shown again");
            return;
        }
        for (int index = 1; index < lines.length; index++) {
            String[] fields = lines[index].split("\t", -1);
            if ("N".equals(fields[0])) { next = Math.max(next, Long.parseLong(fields[1])); continue; }
            if (fields.length != (before ? 31 : beforeDust ? 35 : beforeBackdrop ? 38 : beforeBurn ? 40 : 41) || !"T".equals(fields[0]))
                throw new IllegalStateException("Unknown line in the kept text: " + lines[index]);
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
            if (!before) {
                s.markup = Boolean.parseBoolean(fields[31]); s.width = Double.parseDouble(fields[32]); s.speed = Double.parseDouble(fields[33]);
                s.cursor = Boolean.parseBoolean(fields[34]);
                if (!beforeDust) {
                    s.dustSize = Double.parseDouble(fields[35]); s.dustSweep = Dust.Sweep.valueOf(fields[36]); s.dustDrift = Double.parseDouble(fields[37]);
                }
                if (!beforeBackdrop) { s.backdrop = Double.parseDouble(fields[38]); s.backdropBelow = Double.parseDouble(fields[39]); }
                if (!beforeBurn) s.dustBurn = burnOf(fields[40]);
                if (s.markup || s.width > 0 || s.enter == Enter.TYPE) {
                    // Read again: the script is not kept, and gives the same as when it was shown.
                    s.source = unescape(fields[3]);
                    if (s.enter == Enter.TYPE) s.enterTime = 0;
                    compose(s, "PZExtAPI.text", "kept text");
                }
            }
            s.cell = world;
            next = Math.max(next, s.key + 1);
            shown.add(s);
        }
        publish();
    }

    @SuppressWarnings("unchecked")
    private static <T extends Throwable> T sneaky(Throwable failure) throws T { throw (T)failure; }
}
