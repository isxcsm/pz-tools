package pztools.api;

import java.lang.classfile.ClassFile;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import pztools.bridge.AgentEntry;

/**
 * The leave effect {@code "dust"} (docs/design/extension-api.md, "Dust"): a text breaks into fine dust that drifts away, swept
 * across it from one side, while the part the sweep has not reached stays as it was.
 *
 * <p>Once the text stands still (its enter is over, or it began to leave), it is drawn once, shadow, outline and colours with it,
 * into a picture of its own: a frame buffer of the game's ({@code TextureFBO}) the size of the text's box, drawn into from the
 * game's render queue. The render thread reads that picture's alpha back once, and the main thread cuts the box into square cells,
 * keeping those with ink in them, at most {@link #MAX_CELLS}. As the text leaves, each cell is a quad of the game's sprite renderer
 * that shows its own part of the picture (texture coordinates into the one picture, so the quads go to the card in one batch),
 * moved, shrunk and faded on its own schedule; the cells not yet reached are drawn as a strip for each row. The picture is let go
 * once the text has gone (or is taken away), from the render queue, after the last frame that drew it.
 *
 * <p>The schedule ({@link #start}, {@link #age}, {@link #alpha}, {@link #driftX}, {@link #driftY}) is pure arithmetic on a seed,
 * the same for the same text. Everything else here runs on the game's main thread but what is queued for its render thread
 * (the drawers and the frame buffer's making), which touches only the piece it was made for.
 */
final class Dust {
    // ---- the schedule, as shares of the leave ----

    /** The share of the leave the front takes to cross the text, the most a cell starts after it, and the longest a cell lives. */
    static final double SWEEP = 0.45, JITTER = 0.12, LIFE = 1 - SWEEP - JITTER;
    /** The share of the leave a text waits for its picture, drawn as it was, before it fades instead. */
    static final double PENDING = 0.15;
    /** The most cells a text breaks into: a larger text has larger cells. */
    static final int MAX_CELLS = 4500;
    /** A cell's side as a share of the line's height (2.7 pixels for a line a tenth of 1080), and the smallest, in pixels. */
    static final double CELL = 0.025, MIN_CELL = 1.5;
    /** How far a cell rises, and goes to the side, over its life, and how far it swirls, in line heights, at a drift of 1. */
    static final double RISE = 1.1, SIDE = 0.8, SWIRL = 0.12;
    /** A cell is ink when the alpha of a texel of it is at least this (of 255). */
    static final int INK = 10;
    /** The largest picture, on each side, in pixels: a larger text fades instead. */
    static final int MAX_SIDE = 4096;
    /** The margin around the text's lines, in line heights and pixels: glyphs reach past their advance, and the shadow and outline. */
    static final double MARGIN = 0.2;

    /** Which way the front goes: {@code "right"} breaks the text from its left side first. */
    enum Sweep { RIGHT, LEFT, UP, DOWN }

    private Dust() { }

    /** A cell's side in pixels for a line {@code line} pixels high and the size option. */
    static double cell(double line, double size) { return Math.max(MIN_CELL, line * CELL * size); }

    /** How far across the text the front is at {@code progress} of the leave: 0 to 1 (the cells' jitter left out). */
    static double front(double progress) { return clamp(progress / SWEEP, 0, 1); }

    /**
     * When a cell starts to go, as a share of the leave: by its place {@code along} the sweep (0 at the side it starts from, 1 at
     * the other), a slow wave {@code across} the sweep (so the front is not a straight line) and a little of its own. From 0 to
     * {@code SWEEP + JITTER}.
     */
    static double start(double along, double across, long seed, int index) {
        return SWEEP * clamp(along, 0, 1) + JITTER * (0.65 * wave(across, seed) + 0.35 * unit(seed, index, 1));
    }

    /** How long a cell lives, as a share of the leave: three quarters of {@link #LIFE} to all of it. */
    static double life(long seed, int index) { return LIFE * (0.75 + 0.25 * unit(seed, index, 2)); }

    /** A cell's own time at {@code progress}: below 0 before it starts, 1 when it has gone. */
    static double age(double progress, double start, double life) { return (progress - start) / life; }

    /** A cell's alpha at its age: whole before it starts, gone at 1. */
    static double alpha(double age) { return age <= 0 ? 1 : age >= 1 ? 0 : 1 - smooth(age); }

    /** A cell's size at its age, as a share of its side: it wears down to 55%. */
    static double size(double age) { return 1 - 0.45 * clamp(age, 0, 1); }

    /** How far along its path a cell is: quick at first, slowing (ease out). */
    static double ease(double age) { double q = 1 - clamp(age, 0, 1); return 1 - q * q; }

    /** A cell's move to the side at its age, in line heights at a drift of 1: its own way and speed, and a swirl that grows. */
    static double driftX(double age, double side, double freq, double phase) {
        double a = clamp(age, 0, 1);
        return SIDE * side * ease(a) + SWIRL * a * wobble(freq * a + phase);
    }

    /** A cell's move up (negative) at its age, in line heights at a drift of 1. */
    static double driftY(double age, double rise, double freq, double phase) {
        double a = clamp(age, 0, 1);
        return -RISE * rise * ease(a) + 0.6 * SWIRL * a * wobble(0.8 * freq * a + phase);
    }

    /**
     * A sine's shape over {@code turns} (one a period), within 3% of {@code sin(2 pi turns)}: a triangle wave rounded by a cubic,
     * a few multiplications where the swirl of thousands of cells a frame would otherwise take as many sines.
     */
    static double wobble(double turns) {
        double f = turns - Math.floor(turns);
        // The triangle: 0 at 0, 1 at a quarter, 0 at a half, -1 at three quarters.
        double t = f < 0.25 ? 4 * f : f < 0.75 ? 2 - 4 * f : 4 * f - 4;
        return t * (1.5 - 0.5 * t * t);
    }

    /** A number from 0 to 1, the same for the same seed, index and salt (SplitMix64). */
    static double unit(long seed, int index, int salt) {
        long z = seed + 0x9E3779B97F4A7C15L * (index + 1L) + 0xD1B54A32D192ED03L * (salt + 1L);
        z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
        z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
        z ^= z >>> 31;
        return (z >>> 11) * 0x1.0p-53;
    }

    /** A smooth wave from 0 to 1 over the place {@code across} (0 to 1): three bumps of its own, the same for the same seed. */
    static double wave(double across, long seed) {
        double x = clamp(across, 0, 1) * 3;
        int at = (int)Math.floor(x);
        double from = unit(seed, at, 7), to = unit(seed, at + 1, 7);
        return from + (to - from) * smooth(x - at);
    }

    static double smooth(double p) { return p * p * (3 - 2 * p); }

    static double clamp(double value, double low, double high) { return value < low ? low : value > high ? high : value; }

    // ---- the cells ----

    /** The alpha of a picture's texel, 0 to 255; {@code y} from the top. */
    @FunctionalInterface interface Alpha { int at(int x, int y); }

    /**
     * The cells of a picture with ink in them, in the order the sweep reaches them: a lane (a row, or a column for an up or down
     * sweep) after another, and in a lane by the place along the sweep. Made once, on the main thread.
     */
    static final class Cells {
        /** A cell's side, in pixels; the grid's columns and rows; the lanes; how many cells. */
        final double size;
        final int columns, rows, lanes, count;
        final Sweep sweep;
        /** Each cell's column and row in the grid. */
        final int[] column, row;
        /** Each cell's start and life (shares of the leave), its way to the side and up (1 is the most), its swirl's rate and phases. */
        final float[] start, life, side, rise, freq, phase, phase2;
        /** The first cell of each lane, and one past the last: {@code lanes + 1} of them. */
        final int[] laneFrom;
        /** The earliest start of a cell and of those after it in its lane: none of a lane from the first whose suffix is past the progress has started. */
        final float[] suffix;

        private Cells(double size, int columns, int rows, int lanes, int count, Sweep sweep) {
            this.size = size; this.columns = columns; this.rows = rows; this.lanes = lanes; this.count = count; this.sweep = sweep;
            column = new int[count]; row = new int[count];
            start = new float[count]; life = new float[count]; side = new float[count]; rise = new float[count];
            freq = new float[count]; phase = new float[count]; phase2 = new float[count];
            laneFrom = new int[lanes + 1];
            suffix = new float[count];
        }

        /** The cells' place along the sweep, from 0 at the side the sweep starts from. */
        int along(int cell) {
            return switch (sweep) {
                case RIGHT -> column[cell];
                case LEFT -> columns - 1 - column[cell];
                case DOWN -> row[cell];
                case UP -> rows - 1 - row[cell];
            };
        }

        /** The first cell of the lane from which none has started at {@code progress}, or the lane's end. */
        int unreached(int lane, double progress) {
            int low = laneFrom[lane], high = laneFrom[lane + 1];
            while (low < high) {
                int middle = (low + high) >>> 1;
                if (suffix[middle] > progress) high = middle;
                else low = middle + 1;
            }
            return low;
        }

        /**
         * The cells of a picture {@code width} by {@code height} cut into squares of {@code size} pixels, made larger until at
         * most {@code max} have ink in them; null when none has.
         */
        static Cells of(Alpha alpha, int width, int height, double size, Sweep sweep, long seed, int max) {
            boolean[] ink = null;
            int columns = 0, rows = 0, count = 0;
            for (int attempt = 0; attempt < 12; attempt++) {
                columns = (int)Math.ceil(width / size);
                rows = (int)Math.ceil(height / size);
                ink = new boolean[columns * rows];
                count = 0;
                int[] across = new int[width];
                for (int x = 0; x < width; x++) across[x] = Math.min(columns - 1, (int)(x / size));
                for (int y = 0; y < height; y++) {
                    int base = Math.min(rows - 1, (int)(y / size)) * columns;
                    for (int x = 0; x < width; x++) {
                        int at = base + across[x];
                        if (!ink[at] && alpha.at(x, y) >= INK) { ink[at] = true; count++; }
                    }
                }
                if (count <= max) break;
                size *= Math.sqrt(count / (double)max) * 1.02;
            }
            if (count == 0 || count > max) return null;
            boolean byRows = sweep == Sweep.RIGHT || sweep == Sweep.LEFT;
            int lanes = byRows ? rows : columns, steps = byRows ? columns : rows;
            var cells = new Cells(size, columns, rows, lanes, count, sweep);
            int at = 0;
            for (int lane = 0; lane < lanes; lane++) {
                cells.laneFrom[lane] = at;
                for (int step = 0; step < steps; step++) {
                    int column, row;
                    if (byRows) { row = lane; column = sweep == Sweep.RIGHT ? step : columns - 1 - step; }
                    else { column = lane; row = sweep == Sweep.DOWN ? step : rows - 1 - step; }
                    int index = row * columns + column;
                    if (!ink[index]) continue;
                    cells.column[at] = column;
                    cells.row[at] = row;
                    cells.start[at] = (float)start((step + 0.5) / steps, (lane + 0.5) / lanes, seed, index);
                    cells.life[at] = (float)life(seed, index);
                    double way = unit(seed, index, 3);
                    cells.side[at] = (float)(byRows ? (sweep == Sweep.RIGHT ? 1 : -1) * (0.35 + 0.65 * way) : (2 * way - 1) * 0.6);
                    cells.rise[at] = (float)(0.6 + 0.8 * unit(seed, index, 4));
                    cells.freq[at] = (float)(0.6 + 0.9 * unit(seed, index, 5));
                    cells.phase[at] = (float)unit(seed, index, 6);
                    cells.phase2[at] = (float)unit(seed, index, 8);
                    at++;
                }
                float earliest = Float.POSITIVE_INFINITY;
                for (int cell = at - 1; cell >= cells.laneFrom[lane]; cell--) earliest = cells.suffix[cell] = Math.min(earliest, cells.start[cell]);
            }
            cells.laneFrom[lanes] = at;
            return cells;
        }
    }

    // ---- a text's picture on one screen ----

    /** What a piece is doing: nothing yet, its picture being made, ready, drawn into, read back, cut, or given up (the text fades). */
    static final int NEW = 0, MAKING = 1, READY = 2, CAPTURING = 3, CAPTURED = 4, CUT = 5, FAILED = 6;

    /**
     * The dust of a text on one screen: its picture, the box on the screen it was drawn from, and its cells. The render thread
     * writes {@link #phase} (READY, CAPTURED, FAILED), {@link #fbo} and the pixels; the main thread reads them after the phase.
     */
    static final class Piece implements Runnable {
        final Texts.Shown owner;
        final int screen;
        final long seed;
        volatile int phase = NEW;
        /** The box on the screen, in whole pixels, and the line's height in pixels, as the picture was made. */
        int boxX, boxY, boxWidth, boxHeight;
        double line;
        Object texture;
        volatile Object fbo;
        float uStart, uEnd, vStart, vEnd;
        ByteBuffer pixels;
        Cells cells;
        /** Set when the text no longer needs it: the picture goes, or is not made. */
        volatile boolean released;
        final AtomicBoolean destroyed = new AtomicBoolean();
        // The render thread's: the viewport and scissor the capture puts back, and whether it began.
        final int[] viewport = new int[4];
        boolean scissor, began;
        // The drawers queued with the game's sprites: the capture's start and end, and the letting go.
        Object begin, end, burial;
        Gl gl;

        Piece(Texts.Shown owner, int screen, long seed) { this.owner = owner; this.screen = screen; this.seed = seed; }

        /** Whether it is on its way to the dust: its picture made or being made, not yet cut. */
        boolean pending() { int now = phase; return now >= MAKING && now <= CAPTURED; }

        /** Whether its picture is in video memory, or on its way there. */
        boolean holds() { return phase >= MAKING && texture != null; }

        /** Whether the box on the screen is the one the picture was made for. */
        boolean at(int x, int y, int width, int height) { return x == boxX && y == boxY && width == boxWidth && height == boxHeight; }

        /** Lets the picture go, on the render thread: once. */
        @Override public void run() {
            if (!destroyed.compareAndSet(false, true)) return;
            Gl own = gl;
            if (own == null) return;
            try {
                Object made = fbo;
                if (made != null) own.fboDestroy.invokeExact(made);
                else if (texture != null) own.textureDestroy.invokeExact(texture);
            } catch (Throwable failure) {
                if (failure instanceof VirtualMachineError fatal && !(fatal instanceof OutOfMemoryError)) throw fatal;
                own.report("the dust's picture could not be let go", failure);
            }
        }
    }

    // ---- the game's drawing, through reflection ----

    /** Kept across API versions: what a replaced API's texts still held, for the next to let go from its own drawing. */
    private static final String ORPHANS = "extension-api-text-orphans";

    /** Gives what the pieces hold to the API that comes next (or the next frame of this one), to be let go after their last draws. */
    static void orphan(List<? extends Runnable> destroys) {
        if (destroys.isEmpty()) return;
        Map<String, Object> kept = AgentEntry.kept();
        synchronized (kept) {
            @SuppressWarnings("unchecked")
            var list = kept.get(ORPHANS) instanceof List<?> earlier ? (List<Runnable>)earlier : new ArrayList<Runnable>();
            list.addAll(destroys);
            kept.put(ORPHANS, list);
        }
    }

    /** What an earlier API left to let go, taken. */
    @SuppressWarnings("unchecked")
    static List<Runnable> orphans() {
        Map<String, Object> kept = AgentEntry.kept();
        synchronized (kept) {
            Object list = kept.remove(ORPHANS);
            return list instanceof List<?> found ? (List<Runnable>)found : List.of();
        }
    }

    /**
     * The game's frame buffers, sprite renderer, render thread and GL calls, read once; null from {@link #open} in a game without
     * them, where dust fades.
     */
    static final class Gl {
        // OpenGL.
        private static final int VIEWPORT = 0x0BA2, SCISSOR_TEST = 0x0C11, RGBA = 0x1908, UNSIGNED_BYTE = 0x1401, PACK_ALIGNMENT = 0x0D05,
            PACK_ROW_LENGTH = 0x0D02, PACK_SKIP_ROWS = 0x0D03, PACK_SKIP_PIXELS = 0x0D04, PIXEL_PACK_BUFFER = 0x88EB,
            PIXEL_PACK_BUFFER_BINDING = 0x88ED;
        // The game's Texture flags, as UIManager makes its frame buffer's.
        private static final int TEXTURE_FLAGS = 16;
        // A drawer of the game's render queue (a GenericDrawer) that runs a Runnable: made once a class loader.
        private static Class<?> drawerOf;
        private static MethodHandle drawerMaker;

        private final MethodHandle renderer, states, populating, styleOf, setStyle, uiStyle, additiveStyle, quad, drawGeneric;
        private final MethodHandle newTexture, textureDestroy, xStart, xEnd, yStart, yEnd;
        private final MethodHandle newFbo, fboStart, fboEnd, fboDestroy, fboSupported;
        private final MethodHandle queue;
        private final MethodHandle getIntegers, isEnabled, enable, disable, viewport, readPixels, pixelStore, getInteger, bindBuffer;
        private final MethodHandle makeDrawer;
        private Object additive, uiFbo;
        private boolean reported;

        private Gl(ClassLoader game) throws ReflectiveOperationException {
            var lookup = MethodHandles.publicLookup();
            Class<?> spriteRenderer = Game.type(game, "zombie.core.SpriteRenderer"), texture = Game.type(game, "zombie.core.textures.Texture");
            Class<?> abstractStyle = Game.type(game, "zombie.core.Styles.AbstractStyle"), stateType = Game.type(game, "zombie.core.sprite.GenericSpriteRenderState");
            Class<?> statesType = Game.type(game, "zombie.core.sprite.SpriteRendererStates"), drawer = Game.type(game, "zombie.core.textures.TextureDraw$GenericDrawer");
            Class<?> fbo = Game.type(game, "zombie.core.textures.TextureFBO"), iTexture = Game.type(game, "zombie.interfaces.ITexture");
            renderer = lookup.findStaticGetter(spriteRenderer, "instance", spriteRenderer).asType(MethodType.methodType(Object.class));
            states = lookup.findGetter(spriteRenderer, "states", statesType).asType(MethodType.methodType(Object.class, Object.class));
            populating = Game.exact(statesType.getMethod("getPopulatingActiveState"), MethodType.methodType(Object.class, Object.class));
            styleOf = lookup.findGetter(stateType, "defaultStyle", abstractStyle).asType(MethodType.methodType(Object.class, Object.class));
            setStyle = Game.exact(spriteRenderer.getMethod("setDefaultStyle", abstractStyle), MethodType.methodType(void.class, Object.class, Object.class));
            Class<?> uiFboStyle = Game.type(game, "zombie.core.Styles.UIFBOStyle"), additiveType = Game.type(game, "zombie.core.Styles.AdditiveStyle");
            uiStyle = lookup.findStaticGetter(uiFboStyle, "instance", uiFboStyle).asType(MethodType.methodType(Object.class));
            additiveStyle = lookup.findStaticGetter(additiveType, "instance", additiveType).asType(MethodType.methodType(Object.class));
            Class<?>[] corners = new Class<?>[21];
            corners[0] = texture;
            for (int index = 1; index <= 16; index++) corners[index] = double.class;
            for (int index = 17; index <= 20; index++) corners[index] = float.class;
            MethodType quadType = MethodType.methodType(void.class, Object.class, Object.class, double.class, double.class, double.class, double.class,
                double.class, double.class, double.class, double.class, double.class, double.class, double.class, double.class, double.class,
                double.class, double.class, double.class, float.class, float.class, float.class, float.class);
            quad = Game.exact(spriteRenderer.getMethod("render", corners), quadType);
            drawGeneric = Game.exact(spriteRenderer.getMethod("drawGeneric", drawer), MethodType.methodType(Object.class, Object.class, Object.class));
            newTexture = lookup.unreflectConstructor(texture.getConstructor(int.class, int.class, int.class))
                .asType(MethodType.methodType(Object.class, int.class, int.class, int.class));
            textureDestroy = Game.exact(texture.getMethod("destroy"), MethodType.methodType(void.class, Object.class));
            MethodType coordinate = MethodType.methodType(float.class, Object.class);
            xStart = Game.exact(texture.getMethod("getXStart"), coordinate);
            xEnd = Game.exact(texture.getMethod("getXEnd"), coordinate);
            yStart = Game.exact(texture.getMethod("getYStart"), coordinate);
            yEnd = Game.exact(texture.getMethod("getYEnd"), coordinate);
            newFbo = lookup.unreflectConstructor(fbo.getConstructor(iTexture)).asType(MethodType.methodType(Object.class, Object.class));
            fboStart = Game.exact(fbo.getMethod("startDrawing", boolean.class, boolean.class), MethodType.methodType(void.class, Object.class, boolean.class, boolean.class));
            fboEnd = Game.exact(fbo.getMethod("endDrawing"), MethodType.methodType(void.class, Object.class));
            fboDestroy = Game.exact(fbo.getMethod("destroy"), MethodType.methodType(void.class, Object.class));
            fboSupported = Game.exact(fbo.getMethod("checkFBOSupport"), MethodType.methodType(boolean.class));
            queue = Game.exact(Game.type(game, "zombie.core.opengl.RenderThread").getMethod("queueInvokeOnRenderContext", Runnable.class),
                MethodType.methodType(void.class, Runnable.class));
            Class<?> gl11 = Game.type(game, "org.lwjgl.opengl.GL11");
            getIntegers = lookup.findStatic(gl11, "glGetIntegerv", MethodType.methodType(void.class, int.class, int[].class));
            isEnabled = lookup.findStatic(gl11, "glIsEnabled", MethodType.methodType(boolean.class, int.class));
            enable = lookup.findStatic(gl11, "glEnable", MethodType.methodType(void.class, int.class));
            disable = lookup.findStatic(gl11, "glDisable", MethodType.methodType(void.class, int.class));
            viewport = lookup.findStatic(gl11, "glViewport", MethodType.methodType(void.class, int.class, int.class, int.class, int.class));
            readPixels = lookup.findStatic(gl11, "glReadPixels", MethodType.methodType(void.class, int.class, int.class, int.class, int.class, int.class,
                int.class, ByteBuffer.class));
            pixelStore = lookup.findStatic(gl11, "glPixelStorei", MethodType.methodType(void.class, int.class, int.class));
            getInteger = lookup.findStatic(gl11, "glGetInteger", MethodType.methodType(int.class, int.class));
            bindBuffer = lookup.findStatic(Game.type(game, "org.lwjgl.opengl.GL15"), "glBindBuffer", MethodType.methodType(void.class, int.class, int.class));
            makeDrawer = drawerMaker(drawer);
        }

        /** The game's drawing, or null (reported once) in a game without what dust needs. */
        static Gl open(ClassLoader game) {
            try { return new Gl(game); }
            catch (ReflectiveOperationException | RuntimeException | LinkageError missing) {
                System.err.println("[PzTools API] text: dust fades instead in this game: " + missing);
                return null;
            }
        }

        /**
         * A class of the game's {@code TextureDraw.GenericDrawer} whose {@code render()} runs a Runnable, defined once in the game's
         * class loader beside it (an API after this one finds it there: its shape is fixed by its name). The render queue calls it
         * on the render thread, in order with the sprites.
         */
        private static synchronized MethodHandle drawerMaker(Class<?> drawer) throws ReflectiveOperationException {
            if (drawerOf == drawer && drawerMaker != null) return drawerMaker;
            String name = drawer.getPackageName() + ".PzToolsRunDrawer1";
            Class<?> made;
            try { made = Class.forName(name, false, drawer.getClassLoader()); }
            catch (ClassNotFoundException first) {
                ClassDesc parent = ClassDesc.of(drawer.getName()), runnable = ClassDesc.of("java.lang.Runnable"), self = ClassDesc.of(name);
                MethodTypeDesc none = MethodTypeDesc.of(ConstantDescs.CD_void);
                byte[] bytes = ClassFile.of().build(self, type -> type
                    .withFlags(ClassFile.ACC_PUBLIC | ClassFile.ACC_FINAL | ClassFile.ACC_SUPER)
                    .withSuperclass(parent)
                    .withField("run", runnable, ClassFile.ACC_PRIVATE | ClassFile.ACC_FINAL)
                    .withMethodBody("<init>", MethodTypeDesc.of(ConstantDescs.CD_void, runnable), ClassFile.ACC_PUBLIC, code -> code
                        .aload(0).invokespecial(parent, "<init>", none)
                        .aload(0).aload(1).putfield(self, "run", runnable)
                        .return_())
                    .withMethodBody("render", none, ClassFile.ACC_PUBLIC, code -> code
                        .aload(0).getfield(self, "run", runnable).invokeinterface(runnable, "run", none)
                        .return_()));
                // A lookup in the drawer's package (the game's classes are in an unnamed module, open to all) defines it there.
                made = MethodHandles.privateLookupIn(drawer, MethodHandles.lookup()).defineClass(bytes);
            }
            var maker = MethodHandles.publicLookup().findConstructor(made, MethodType.methodType(void.class, Runnable.class))
                .asType(MethodType.methodType(Object.class, Runnable.class));
            drawerOf = drawer;
            drawerMaker = maker;
            return maker;
        }

        void report(String what, Throwable failure) {
            if (!reported) System.err.println("[PzTools API] text: " + what + "; dust fades instead: " + failure);
            reported = true;
        }

        /** A drawer of the render queue that runs this. */
        Object drawer(Runnable run) throws Throwable { return (Object)makeDrawer.invokeExact(run); }

        /** Runs this on the render thread, at its next turn (at once on the render thread itself). */
        void onRenderThread(Runnable run) throws Throwable { queue.invokeExact(run); }

        /**
         * Starts making a piece's picture for the box: the game's texture now (its storage follows on the render thread), and the
         * frame buffer over it on the render thread. False when the box is too large or the game has no frame buffers.
         */
        boolean make(Piece piece, int x, int y, int width, int height, double line) throws Throwable {
            if (width <= 0 || height <= 0 || width > MAX_SIDE || height > MAX_SIDE || !(boolean)fboSupported.invokeExact()) return false;
            piece.gl = this;
            piece.boxX = x; piece.boxY = y; piece.boxWidth = width; piece.boxHeight = height; piece.line = line;
            piece.texture = (Object)newTexture.invokeExact(width, height, TEXTURE_FLAGS);
            piece.uStart = (float)xStart.invokeExact(piece.texture);
            piece.uEnd = (float)xEnd.invokeExact(piece.texture);
            piece.vStart = (float)yStart.invokeExact(piece.texture);
            piece.vEnd = (float)yEnd.invokeExact(piece.texture);
            piece.pixels = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder());
            piece.begin = drawer(() -> begin(piece));
            piece.end = drawer(() -> end(piece));
            piece.burial = drawer(piece);
            piece.phase = MAKING;
            onRenderThread(() -> {
                // Let go before it was made: the texture alone goes (once, whichever of this and the burial comes first).
                if (piece.released) { piece.run(); return; }
                try {
                    piece.fbo = (Object)newFbo.invokeExact(piece.texture);
                    piece.phase = READY;
                } catch (Throwable failure) {
                    if (failure instanceof VirtualMachineError fatal && !(fatal instanceof OutOfMemoryError)) throw fatal;
                    piece.phase = FAILED;
                    report("the dust's picture could not be made", failure);
                    if (piece.released) piece.run();
                }
            });
            return true;
        }

        /**
         * Queues the capture's start: the picture is drawn into, with the interface's buffer's blending (so its colours are
         * premultiplied by their alpha). What is drawn before {@link #endCapture} goes into it. The style to put back.
         */
        Object beginCapture(Piece piece) throws Throwable {
            Object renderer = (Object)this.renderer.invokeExact();
            Object state = (Object)populating.invokeExact((Object)states.invokeExact(renderer));
            Object before = (Object)styleOf.invokeExact(state);
            Object style = uiFbo;
            if (style == null) style = uiFbo = (Object)uiStyle.invokeExact();
            piece.phase = CAPTURING;
            setStyle.invokeExact(renderer, style);
            try { Object queued = (Object)drawGeneric.invokeExact(renderer, piece.begin); }
            catch (Throwable failure) { setStyle.invokeExact(renderer, before); throw failure; }
            return before;
        }

        /** Queues the capture's end (the picture read back) and puts the style back. */
        void endCapture(Piece piece, Object before) throws Throwable {
            Object renderer = (Object)this.renderer.invokeExact();
            try { Object queued = (Object)drawGeneric.invokeExact(renderer, piece.end); }
            finally { setStyle.invokeExact(renderer, before); }
        }

        /** On the render thread, in the queue: the frame buffer bound and cleared, the viewport moved so that the box is its corner. */
        private void begin(Piece piece) {
            piece.began = false;
            if (piece.released) return;
            try {
                getIntegers.invokeExact(VIEWPORT, piece.viewport);
                piece.scissor = (boolean)isEnabled.invokeExact(SCISSOR_TEST);
                if (piece.scissor) disable.invokeExact(SCISSOR_TEST);
                fboStart.invokeExact(piece.fbo, true, true);
                piece.began = true;
                // The interface's projection is the viewport's pixels from its top left: the box's top left at (0, height).
                viewport.invokeExact(-piece.boxX, piece.boxY + piece.boxHeight - piece.viewport[3], piece.viewport[2], piece.viewport[3]);
            } catch (Throwable failure) {
                if (failure instanceof VirtualMachineError fatal && !(fatal instanceof OutOfMemoryError)) throw fatal;
                piece.phase = FAILED;
                report("the dust's picture could not be drawn", failure);
                if (!piece.began) restore(piece);
            }
        }

        /** On the render thread, in the queue: the picture's alpha read back, the frame buffer and viewport put back. */
        private void end(Piece piece) {
            if (!piece.began) return;
            piece.began = false;
            boolean read = false;
            try {
                int buffer = (int)getInteger.invokeExact(PIXEL_PACK_BUFFER_BINDING), alignment = (int)getInteger.invokeExact(PACK_ALIGNMENT);
                int rowLength = (int)getInteger.invokeExact(PACK_ROW_LENGTH), skipRows = (int)getInteger.invokeExact(PACK_SKIP_ROWS);
                int skipPixels = (int)getInteger.invokeExact(PACK_SKIP_PIXELS);
                try {
                    if (buffer != 0) bindBuffer.invokeExact(PIXEL_PACK_BUFFER, 0);
                    pixelStore.invokeExact(PACK_ALIGNMENT, 4);
                    pixelStore.invokeExact(PACK_ROW_LENGTH, 0);
                    pixelStore.invokeExact(PACK_SKIP_ROWS, 0);
                    pixelStore.invokeExact(PACK_SKIP_PIXELS, 0);
                    ByteBuffer pixels = piece.pixels;
                    pixels.clear();
                    readPixels.invokeExact(0, 0, piece.boxWidth, piece.boxHeight, RGBA, UNSIGNED_BYTE, pixels);
                    read = true;
                } finally {
                    pixelStore.invokeExact(PACK_ALIGNMENT, alignment);
                    pixelStore.invokeExact(PACK_ROW_LENGTH, rowLength);
                    pixelStore.invokeExact(PACK_SKIP_ROWS, skipRows);
                    pixelStore.invokeExact(PACK_SKIP_PIXELS, skipPixels);
                    if (buffer != 0) bindBuffer.invokeExact(PIXEL_PACK_BUFFER, buffer);
                }
            } catch (Throwable failure) {
                if (failure instanceof VirtualMachineError fatal && !(fatal instanceof OutOfMemoryError)) throw fatal;
                report("the dust's picture could not be read", failure);
            } finally {
                try { fboEnd.invokeExact(piece.fbo); } catch (Throwable failure) { report("the frame buffer could not be put back", failure); read = false; }
                restore(piece);
                piece.phase = read ? CAPTURED : FAILED;
            }
        }

        private void restore(Piece piece) {
            try {
                viewport.invokeExact(piece.viewport[0], piece.viewport[1], piece.viewport[2], piece.viewport[3]);
                if (piece.scissor) enable.invokeExact(SCISSOR_TEST);
            } catch (Throwable failure) { report("the viewport could not be put back", failure); }
        }

        /** Cuts the piece's picture into its cells, once it was read: false when it has no ink. The pixels are let go. */
        static boolean cut(Piece piece, double size, Sweep sweep) {
            ByteBuffer pixels = piece.pixels;
            int width = piece.boxWidth, height = piece.boxHeight;
            // The rows read back are from the bottom of the box.
            Cells cells = Cells.of((x, y) -> pixels.get(((height - 1 - y) * width + x) * 4 + 3) & 0xFF, width, height, size, sweep, piece.seed, MAX_CELLS);
            piece.pixels = null;
            piece.cells = cells;
            piece.phase = cells == null ? FAILED : CUT;
            return cells != null;
        }

        /** Queues the piece's letting go after what was drawn before it in the render queue. */
        void bury(Piece piece) throws Throwable {
            Object renderer = (Object)this.renderer.invokeExact();
            Object queued = (Object)drawGeneric.invokeExact(renderer, piece.burial);
        }

        /** Queues a drawer made for a Runnable (another API's piece) after what was drawn before it. */
        void buryDrawer(Object drawer) throws Throwable {
            Object renderer = (Object)this.renderer.invokeExact();
            Object queued = (Object)drawGeneric.invokeExact(renderer, drawer);
        }

        /**
         * Draws the piece at {@code progress} of its leave: each lane's unreached part as one strip, the cells before it in place or
         * on their way, in the picture's premultiplied colours (the style the game draws its interface's buffer with). {@code fade}
         * is the alpha of the whole; {@code drift} the text's. Allocates nothing.
         */
        void draw(Piece piece, double progress, double fade, double drift) throws Throwable {
            Cells cells = piece.cells;
            Object renderer = (Object)this.renderer.invokeExact();
            Object state = (Object)populating.invokeExact((Object)states.invokeExact(renderer));
            Object before = (Object)styleOf.invokeExact(state);
            Object style = additive;
            if (style == null) style = additive = (Object)additiveStyle.invokeExact();
            setStyle.invokeExact(renderer, style);
            try {
                Object texture = piece.texture;
                double size = cells.size, width = piece.boxWidth, height = piece.boxHeight, reach = piece.line * drift;
                for (int lane = 0; lane < cells.lanes; lane++) {
                    int from = cells.laneFrom[lane], unreached = cells.unreached(lane, progress);
                    if (unreached < cells.laneFrom[lane + 1]) {
                        // The lane's part the front has not reached, from its first such cell to the far side, as it was.
                        double left, top, right, bottom;
                        int column = cells.column[unreached], row = cells.row[unreached];
                        switch (cells.sweep) {
                            case RIGHT -> { left = column * size; right = width; top = row * size; bottom = Math.min(height, top + size); }
                            case LEFT -> { left = 0; right = Math.min(width, (column + 1) * size); top = row * size; bottom = Math.min(height, top + size); }
                            case DOWN -> { top = row * size; bottom = height; left = column * size; right = Math.min(width, left + size); }
                            default -> { top = 0; bottom = Math.min(height, (row + 1) * size); left = column * size; right = Math.min(width, left + size); }
                        }
                        drawPart(renderer, texture, piece, left, top, right, bottom, 0, 0, 1, (float)fade);
                    }
                    for (int cell = from; cell < unreached; cell++) {
                        double left = cells.column[cell] * size, top = cells.row[cell] * size;
                        double right = Math.min(width, left + size), bottom = Math.min(height, top + size);
                        double age = age(progress, cells.start[cell], cells.life[cell]);
                        if (age <= 0) { drawPart(renderer, texture, piece, left, top, right, bottom, 0, 0, 1, (float)fade); continue; }
                        if (age >= 1) continue;
                        float shown = (float)(alpha(age) * fade);
                        if (shown <= 0.002f) continue;
                        double dx = reach * driftX(age, cells.side[cell], cells.freq[cell], cells.phase[cell]);
                        double dy = reach * driftY(age, cells.rise[cell], cells.freq[cell], cells.phase2[cell]);
                        drawPart(renderer, texture, piece, left, top, right, bottom, dx, dy, size(age), shown);
                    }
                }
            } finally {
                setStyle.invokeExact(renderer, before);
            }
        }

        /**
         * One quad: the box's part {@code left..right}, {@code top..bottom} (pixels from its top left), moved by {@code dx, dy},
         * scaled about its middle, at an alpha (premultiplied: every channel).
         */
        private void drawPart(Object renderer, Object texture, Piece piece, double left, double top, double right, double bottom, double dx, double dy,
                double scale, float alpha) throws Throwable {
            double width = piece.boxWidth, height = piece.boxHeight;
            double u0 = piece.uStart + (piece.uEnd - piece.uStart) * left / width, u1 = piece.uStart + (piece.uEnd - piece.uStart) * right / width;
            // The picture's rows go up from the box's bottom.
            double vTop = piece.vStart + (piece.vEnd - piece.vStart) * (height - top) / height;
            double vBottom = piece.vStart + (piece.vEnd - piece.vStart) * (height - bottom) / height;
            double halfX = (right - left) * scale / 2, halfY = (bottom - top) * scale / 2;
            double x = piece.boxX + (left + right) / 2 + dx, y = piece.boxY + (top + bottom) / 2 + dy;
            quad.invokeExact(renderer, texture, x - halfX, y - halfY, x + halfX, y - halfY, x + halfX, y + halfY, x - halfX, y + halfY,
                u0, vTop, u1, vTop, u1, vBottom, u0, vBottom, alpha, alpha, alpha, alpha);
        }
    }
}
