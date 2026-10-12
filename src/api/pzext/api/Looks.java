package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * The looks of text's later effects (docs/design.md, "Looks"): a text drawn over its life by a shader of the API's own, over a
 * picture of it. The picture is the dust's ({@link Dust.Piece}): the text drawn once, at rest, into a frame buffer, as soon as it
 * shows. Each frame the main thread hands a {@link Frame} (a few numbers: where the text is, its share of its enter and leave,
 * its clocks) to a drawer of the game's render queue, and the render thread draws the look from them in the queue's order:
 * <ul>
 * <li>{@code impact} (enter): the text falls onto the screen and hits, squashing and shaking, white-hot and cooling, with a
 *     streak of light, a puff of dust, and a gleam passing over it once as it stays;</li>
 * <li>{@code torch} (enter) and {@code dim} (leave): a torch's beam sways in over the text and opens over it, flickers once as it
 *     stays, and stutters down to embers as the text leaves;</li>
 * <li>{@code signal} (enter) and {@code lost} (leave): a radio signal tuned in (rows torn sideways, colours apart, grain),
 *     a hiccup as it stays, cutting out and sinking into the grain as it leaves;</li>
 * <li>{@code mist} (enter and leave): drifting mist clears off the text, a veil of it drifting on behind as it stays, and the
 *     text sinks back into it as it leaves;</li>
 * <li>{@code erode} (leave): it weathers away in place, its colour draining, worn off in pits from its edges;</li>
 * <li>{@code burn} (leave): it burns spot by spot from a corner like paper (a map of when each spot burns), a ragged glowing
 *     edge, shards of ash and sparks tumbling away on the wind.</li>
 * </ul>
 * The numbers are those of tools/title-lab, where the looks are made: the page draws them with the same arithmetic and shader.
 */
final class Looks {
    // ---- the looks' numbers (tools/title-lab) ----

    /** Impact: the fall, in seconds; how fast the heat cools; the glow, the streak and the dust's strength; when the gleam starts and how bright it is. */
    static final double IMPACT = 0.16, IMPACT_COOL = 4, IMPACT_GLOW = 1, IMPACT_STREAK = 0.8, IMPACT_DUST = 1, SHINE_AT = 0.8, SHINE = 0.45;
    static final int PUFFS = 46;
    /** Erode: the size of its grain (pixels for a line 72 high) and how much of its colour drains. */
    static final double ERODE_GRAIN = 9, ERODE_DRAIN = 0.8;
    /** Torch: the light it throws behind the text, and how deep it stutters as it dies. */
    static final double TORCH_POOL = 1, TORCH_STUTTER = 1;
    /** Radio: the static's specks and the signal's hiccups. */
    static final double RADIO_STATIC = 1, RADIO_HICCUP = 1;
    /** Mist: how thick, how fast it drifts, and how much of it stays as the text does. */
    static final double FOG_THICK = 1.7, FOG_DRIFT = 1.25, FOG_STAY = 0.5;
    /**
     * Burn: the share of the leave its front takes to cross the text, how far ahead holes open, how ragged and curled the edge is;
     * the flame's edge, the char and the scorch ahead of it, as shares of the leave.
     */
    static final double FRONT = 0.52, SPREAD = 0.07, RAGGED = 0.03, CURL = 0.6, EDGE_W = 0.012, CHAR_W = 0.02, SCORCH_W = 0.07;
    /** Burn's ash: the share of the cells that leave as shards, their size, how fast they spin, how soon they grey, and to what. */
    static final double FLAKES = 0.5, FLAKE_SIZE = 1.1, SPIN = 7, GREYING = 0.35, PAPER_ASH = 0.55;
    /** The colour a text burns with when it is given none. */
    static final float[] BURN = { 1f, 0.32f, 0.1f, 1f };
    /** How long a text's backdrop takes to come in, in seconds, whatever its enter. */
    static final double BACKDROP_IN = 1.2;

    /** The looks drawn over a text's life. */
    static final int PLAIN = 0, TORCH = 1, RADIO = 2, FOG = 3;

    private Looks() { }

    // ---- the arithmetic (pure: the main thread's, the render thread's and the tests') ----

    static double smooth(double p) { return p * p * (3 - 2 * p); }

    static double clamp(double value, double low, double high) { return value < low ? low : value > high ? high : value; }

    static double bump(double x, double at, double width) { double d = (x - at) / width; return Math.exp(-d * d); }

    /** An integer hash, 0 to 1 (the page's {@code hash}). */
    static double hash(int x, int y, int s) {
        int h = x * 374761393 + y * 668265263 + s * 1442695041;
        h = (h ^ (h >>> 13)) * 1274126177;
        h ^= h >>> 16;
        return (h & 0xFFFFFFFFL) / 4294967296.0;
    }

    /** Value noise on {@link #hash}, 0 to 1. */
    static double vnoise(double x, double y, int s) {
        int ix = (int)Math.floor(x), iy = (int)Math.floor(y);
        double fx = smooth(x - ix), fy = smooth(y - iy);
        double a = hash(ix, iy, s), b = hash(ix + 1, iy, s), c = hash(ix, iy + 1, s), d = hash(ix + 1, iy + 1, s);
        return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy;
    }

    /** How far along the burn's sweep a pixel is, 0 to 1, in a picture {@code w} by {@code h}. */
    static double along(double x, double y, double w, double h, Dust.Sweep sweep) {
        return switch (sweep) {
            case RIGHT -> x / w;
            case LEFT -> 1 - x / w;
            case DOWN -> y / h;
            case UP -> 1 - y / h;
            case UPRIGHT -> (x + (h - y)) / (w + h);
            case UPLEFT -> ((w - x) + (h - y)) / (w + h);
            case DOWNRIGHT -> (x + y) / (w + h);
            case DOWNLEFT -> ((w - x) + y) / (w + h);
        };
    }

    /**
     * The burn map: when each pixel of a picture {@code w} by {@code h} burns away, as a share of the leave: the sweep, clumps a few
     * cells wide (holes open ahead of the front) and fine fibres that make the edge ragged, over a warp that curls it.
     */
    static float[] burnMap(int w, int h, double cell, long seed, Dust.Sweep sweep) {
        float[] map = new float[w * h];
        int s = (int)(seed & 0xFFFFFF);
        double warp = CURL * cell * 4, patch = Dust.PATCH * cell, fine = Dust.FINE_PATCH * cell;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                double wx = x + (vnoise(x / 23.0, y / 23.0, s + 5) - 0.5) * warp, wy = y + (vnoise(x / 23.0, y / 23.0, s + 6) - 0.5) * warp;
                double clump = 0.7 * vnoise(wx / patch, wy / patch, s) + 0.3 * vnoise(wx / fine, wy / fine, s + 1);
                double fibre = 0.6 * vnoise(wx / 3, wy / 3, s + 2) + 0.4 * vnoise(wx / 1.4, wy / 1.4, s + 3);
                map[y * w + x] = (float)(FRONT * along(x, y, w, h, sweep) + SPREAD * clump + RAGGED * (fibre - 0.5));
            }
        return map;
    }

    /** The map as a texture's pixels, its rows from the top: each value in 16 bits, high in red, low in green. */
    static ByteBuffer encode(float[] map) {
        ByteBuffer pixels = ByteBuffer.allocateDirect(map.length * 4).order(ByteOrder.nativeOrder());
        for (float value : map) {
            int v = (int)Math.round(clamp(value, 0, 1) * 65535);
            pixels.put((byte)(v >> 8)).put((byte)v).put((byte)0).put((byte)255);
        }
        return pixels.flip();
    }

    /** The cells' flakes leave as the map burns their middle. */
    static void startsFromMap(Dust.Cells cells, float[] map, int w, int h) {
        for (int index = 0; index < cells.count; index++) {
            int x = Math.min(w - 1, (int)Math.floor((cells.column[index] + 0.5) * cells.size));
            int y = Math.min(h - 1, (int)Math.floor((cells.row[index] + 0.5) * cells.size));
            cells.start[index] = map[y * w + x];
        }
    }

    /**
     * The impact's fall and hit at {@code secs} into the enter, into {@code into}: alpha, scale, squash across, squash up, shake
     * across (in lines) and down (in lines).
     */
    static void impact(double secs, double[] into) {
        into[0] = 1; into[1] = 1; into[2] = 1; into[3] = 1; into[4] = 0; into[5] = 0;
        if (secs < IMPACT) {
            double u = Math.max(0, secs) / IMPACT;
            into[1] = 1.45 - 0.45 * u * u;
            into[0] = Math.min(1, u * 2.5);
            return;
        }
        double k = secs - IMPACT, ring = Math.exp(-k * 18), shake = Math.exp(-k * 14);
        into[3] = 1 - 0.07 * ring * Math.cos(k * 40);
        into[2] = 1 + 0.04 * ring * Math.cos(k * 40);
        into[4] = 0.03 * shake * Math.sin(k * 70);
        into[5] = 0.02 * shake * Math.cos(k * 55);
    }

    /**
     * The torch at {@code secs} into the text's life (its leave's start at most), into {@code into}: its place across and down the
     * picture (shares), its radius (in the picture's widths), the trail it has lit to, how much of the trail stays, the pool's
     * strength, and how far it has opened.
     */
    static void torch(double secs, double[] into) {
        double e = smooth(clamp(secs / 1.7, 0, 1)), sway = 1 - e;
        double x = -0.2 + 0.75 * e, y = 0.55 + (0.1 * Math.sin(secs * 3.1) + 0.04 * Math.sin(secs * 7.3)) * sway, r = 0.2;
        double v = smooth(clamp((secs - 1.6) / 0.6, 0, 1));
        x += (0.5 - x) * v;
        y += (0.5 - y) * v;
        r += 1.3 * v;
        into[0] = x; into[1] = y; into[2] = r; into[3] = -0.2 + 0.75 * e; into[4] = 0.75 + 0.25 * v; into[5] = 1 - 0.55 * v; into[6] = v;
    }

    /** A torch far away: all of the text lit. */
    static void farTorch(double[] into) { into[0] = 0.5; into[1] = 0.5; into[2] = 10; into[3] = 2; into[4] = 1; into[5] = 0; into[6] = 1; }

    /**
     * How bright the torch is: a flicker as the text stays ({@code cue} seconds of the group's clock, the clock's {@code group}),
     * and as it leaves ({@code out}) a stutter down to embers.
     */
    static double light(double group, double cue, double out) {
        double light = 1 - 0.25 * bump(group, cue + 1.4, 0.05) - 0.15 * bump(group, cue + 1.55, 0.03);
        if (out > 0) {
            light = Math.max(0.22, 1 - 0.85 * smooth(clamp(out / 0.6, 0, 1)));
            light *= 1 - TORCH_STUTTER * (0.75 * bump(out, 0.08, 0.012) + 0.6 * bump(out, 0.16, 0.01) + 0.5 * bump(out, 0.21, 0.008));
        }
        return light;
    }

    /** How much of a torch-lit text is left as it leaves: all, then dying out over the last 60%. */
    static double ember(double out) { return 1 - smooth(clamp((out - 0.4) / 0.6, 0, 1)); }

    /**
     * A radio text's signal, 0 to 1: tuned in over its enter (a hiccup on the way), a hiccup as it stays, and as it leaves, two
     * cuts and then sinking into the grain.
     */
    static double signal(double enterTime, double secs, double out) {
        double sig;
        if (out > 0) sig = (1 - smooth(clamp((out - 0.2) / 0.8, 0, 1))) * (1 - RADIO_HICCUP * (0.5 * bump(out, 0.05, 0.01) + 0.4 * bump(out, 0.11, 0.008)));
        else sig = smooth(clamp(secs / enterTime, 0, 1)) * (1 - RADIO_HICCUP * 0.35 * bump(secs, enterTime * 0.55, 0.03))
            * (1 - RADIO_HICCUP * 0.15 * bump(secs, enterTime + 2.6, 0.03));
        return clamp(sig, 0, 1);
    }

    /** How far the mist has cleared off the text, 0 to 1: over its enter, and back as it leaves (hidden as the leave ends). */
    static double clear(double enterTime, double secs, double out) {
        return out > 0 ? 1 - smooth(clamp((out - 0.2) / 0.95, 0, 1)) : smooth(clamp(secs / enterTime, 0, 1));
    }

    /** How thick the mist is: in slowly, thinning to what stays as the text clears; thickest half way out, then thinning away. */
    static double mist(double enterTime, double secs, double out) {
        if (out > 0) return (FOG_STAY + (0.75 - FOG_STAY) * smooth(clamp(out / 0.5, 0, 1))) * (1 - smooth(clamp((out - 0.5) / 0.5, 0, 1)));
        return smooth(clamp(secs / 1.8, 0, 1)) * (0.8 - (0.8 - FOG_STAY) * smooth(clamp((secs - 0.6) / enterTime, 0, 1)));
    }

    // ---- what the main thread hands the render thread ----

    /**
     * One frame of a text's look on one screen: written by the main thread, then drawn by the render thread from the render queue
     * (a piece keeps a few, used in turn: the render thread is at most a couple of frames behind).
     */
    static final class Frame implements Runnable {
        final Dust.Piece piece;
        final Gl gl;
        Object drawer;
        int look;
        boolean impact, erode, burn, lead;
        /** The picture's middle at rest, in pixels; the text's line height and its ink's width, in pixels. */
        double cx, cy, line, ink;
        /** Its scale, squash across and up, and move, in pixels. */
        double s, sx, sy, dx, dy;
        /** Its alpha from its enter, with its leave's too (a plain text's), and its leave's share (what the impact's light keeps). */
        double enterAlpha, alpha, left;
        /** Its seconds since its delay, its leave's share, its enter's length, when it leaves as scheduled, its group's clock and cue. */
        double secs, out, enterTime, scheduled, leaving, group, cue;
        double drift;
        float burnRed, burnGreen, burnBlue;

        Frame(Dust.Piece piece, Gl gl) { this.piece = piece; this.gl = gl; }

        @Override public void run() { gl.render(this); }
    }

    // ---- the render thread's drawing ----

    /** The program, the GL calls and the drawing; null from {@link #open} in a game without them (the looks fade instead). */
    static final class Gl {
        // OpenGL.
        private static final int TRIANGLES = 4, FLOAT = 0x1406, TEXTURE_2D = 0x0DE1, TEXTURE0 = 0x84C0, TEXTURE1 = 0x84C1, BLEND = 0x0BE2,
            ONE = 1, ONE_MINUS_SRC_ALPHA = 0x0303, ALPHA_TEST = 0x0BC0, DEPTH_TEST = 0x0B71, CULL_FACE = 0x0B44, ARRAY_BUFFER = 0x8892,
            CURRENT_PROGRAM = 0x8B8D, VERTEX_SHADER = 0x8B31, FRAGMENT_SHADER = 0x8B30, COMPILE_STATUS = 0x8B81, LINK_STATUS = 0x8B82,
            MIN_FILTER = 0x2801, MAG_FILTER = 0x2800, WRAP_S = 0x2802, WRAP_T = 0x2803, LINEAR = 0x2601, NEAREST = 0x2600,
            CLAMP_TO_EDGE = 0x812F, RGBA = 0x1908, UNSIGNED_BYTE = 0x1401, UNPACK_ALIGNMENT = 0x0CF5, ALL_ATTRIB_BITS = 0x000FFFFF;
        private static final int FLOATS = 11, STRIDE = FLOATS * 4;

        private final MethodHandle pushAttrib, popAttrib, pushClient, popClient, enable, disable, blendFunc, bindTexture, getInteger, drawArrays,
            genTexture, deleteTexture, texImage, texParameter, pixelStore, activeTexture, bindBuffer;
        private final MethodHandle createShader, shaderSource, compileShader, shaderValue, shaderLog, createProgram, attachShader, bindAttrib,
            linkProgram, programValue, programLog, useProgram, uniformAt, uniform1f, uniform2f, uniform3f, uniform4f, uniform1i, uniformMatrix,
            attribPointer, enableAttrib, disableAttrib;
        private final MethodHandle textureId, lastTexture, ringBuffer, restoreVbos, restore;
        private final MethodHandle core, projection, modelView, peek, empty, mul, matrixGet;
        private final Object product;
        /** Set once the program does not compile or a draw fails: the main thread's texts fade from then on. */
        volatile boolean failed;
        private boolean reported;

        // The render thread's: the program and its uniforms' places, the vertices, the matrix's floats, scratch.
        private int program = -1;
        private int uMode, uMvp, uTex, uMap, uTexRect, uProgress, uEdge, uChar, uScorch, uGlow, uFlickerN, uFlickerD, uBurn, uScorched, uCharred,
            uPicSize, uBlur, uGrain, uDrain, uTorch, uReveal, uRemain, uLight, uEmber, uSig, uClock, uStatic, uClear, uFogAmt, uNoise, uFogHalf;
        private FloatBuffer verts = ByteBuffer.allocateDirect(FLOATS * 6 * 256 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
        private int count, mode;
        private final FloatBuffer matrix = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
        private final double[] torch = new double[7];

        private Gl(ClassLoader game) throws ReflectiveOperationException {
            var lookup = MethodHandles.publicLookup();
            Class<?> gl11 = Game.type(game, "org.lwjgl.opengl.GL11"), gl13 = Game.type(game, "org.lwjgl.opengl.GL13");
            Class<?> gl15 = Game.type(game, "org.lwjgl.opengl.GL15"), gl20 = Game.type(game, "org.lwjgl.opengl.GL20");
            MethodType i = MethodType.methodType(void.class, int.class), ii = MethodType.methodType(void.class, int.class, int.class);
            MethodType iii = MethodType.methodType(void.class, int.class, int.class, int.class), none = MethodType.methodType(void.class);
            pushAttrib = lookup.findStatic(gl11, "glPushAttrib", i);
            popAttrib = lookup.findStatic(gl11, "glPopAttrib", none);
            pushClient = lookup.findStatic(gl11, "glPushClientAttrib", i);
            popClient = lookup.findStatic(gl11, "glPopClientAttrib", none);
            enable = lookup.findStatic(gl11, "glEnable", i);
            disable = lookup.findStatic(gl11, "glDisable", i);
            blendFunc = lookup.findStatic(gl11, "glBlendFunc", ii);
            bindTexture = lookup.findStatic(gl11, "glBindTexture", ii);
            getInteger = lookup.findStatic(gl11, "glGetInteger", MethodType.methodType(int.class, int.class));
            drawArrays = lookup.findStatic(gl11, "glDrawArrays", iii);
            genTexture = lookup.findStatic(gl11, "glGenTextures", MethodType.methodType(int.class));
            deleteTexture = lookup.findStatic(gl11, "glDeleteTextures", i);
            texImage = lookup.findStatic(gl11, "glTexImage2D", MethodType.methodType(void.class, int.class, int.class, int.class, int.class, int.class,
                int.class, int.class, int.class, ByteBuffer.class));
            texParameter = lookup.findStatic(gl11, "glTexParameteri", iii);
            pixelStore = lookup.findStatic(gl11, "glPixelStorei", ii);
            activeTexture = lookup.findStatic(gl13, "glActiveTexture", i);
            bindBuffer = lookup.findStatic(gl15, "glBindBuffer", ii);
            createShader = lookup.findStatic(gl20, "glCreateShader", MethodType.methodType(int.class, int.class));
            shaderSource = lookup.findStatic(gl20, "glShaderSource", MethodType.methodType(void.class, int.class, CharSequence.class));
            compileShader = lookup.findStatic(gl20, "glCompileShader", i);
            shaderValue = lookup.findStatic(gl20, "glGetShaderi", MethodType.methodType(int.class, int.class, int.class));
            shaderLog = lookup.findStatic(gl20, "glGetShaderInfoLog", MethodType.methodType(String.class, int.class));
            createProgram = lookup.findStatic(gl20, "glCreateProgram", MethodType.methodType(int.class));
            attachShader = lookup.findStatic(gl20, "glAttachShader", ii);
            bindAttrib = lookup.findStatic(gl20, "glBindAttribLocation", MethodType.methodType(void.class, int.class, int.class, CharSequence.class));
            linkProgram = lookup.findStatic(gl20, "glLinkProgram", i);
            programValue = lookup.findStatic(gl20, "glGetProgrami", MethodType.methodType(int.class, int.class, int.class));
            programLog = lookup.findStatic(gl20, "glGetProgramInfoLog", MethodType.methodType(String.class, int.class));
            useProgram = lookup.findStatic(gl20, "glUseProgram", i);
            uniformAt = lookup.findStatic(gl20, "glGetUniformLocation", MethodType.methodType(int.class, int.class, CharSequence.class));
            uniform1f = lookup.findStatic(gl20, "glUniform1f", MethodType.methodType(void.class, int.class, float.class));
            uniform2f = lookup.findStatic(gl20, "glUniform2f", MethodType.methodType(void.class, int.class, float.class, float.class));
            uniform3f = lookup.findStatic(gl20, "glUniform3f", MethodType.methodType(void.class, int.class, float.class, float.class, float.class));
            uniform4f = lookup.findStatic(gl20, "glUniform4f", MethodType.methodType(void.class, int.class, float.class, float.class, float.class, float.class));
            uniform1i = lookup.findStatic(gl20, "glUniform1i", ii);
            uniformMatrix = lookup.findStatic(gl20, "glUniformMatrix4fv", MethodType.methodType(void.class, int.class, boolean.class, FloatBuffer.class));
            attribPointer = lookup.findStatic(gl20, "glVertexAttribPointer", MethodType.methodType(void.class, int.class, int.class, int.class,
                boolean.class, int.class, FloatBuffer.class));
            enableAttrib = lookup.findStatic(gl20, "glEnableVertexAttribArray", i);
            disableAttrib = lookup.findStatic(gl20, "glDisableVertexAttribArray", i);
            Class<?> texture = Game.type(game, "zombie.core.textures.Texture"), spriteRenderer = Game.type(game, "zombie.core.SpriteRenderer");
            Class<?> ring = Game.type(game, "zombie.core.SpriteRenderer$RingBuffer"), glState = Game.type(game, "zombie.core.opengl.GLStateRenderThread");
            textureId = Game.exact(texture.getMethod("getID"), MethodType.methodType(int.class, Object.class));
            lastTexture = lookup.unreflectSetter(texture.getField("lastTextureID")).asType(MethodType.methodType(void.class, int.class));
            ringBuffer = lookup.unreflectGetter(spriteRenderer.getField("ringBuffer")).asType(MethodType.methodType(Object.class));
            restoreVbos = lookup.unreflectSetter(ring.getField("restoreVbos")).asType(MethodType.methodType(void.class, Object.class, boolean.class));
            restore = Game.exact(glState.getMethod("restore"), none);
            // The interface's projection: the game's matrix stacks (as ShaderHelper.setModelViewProjection reads them).
            Class<?> coreType = Game.type(game, "zombie.core.Core"), stack = Game.type(game, "zombie.core.opengl.MatrixStack");
            Class<?> matrixType = Game.type(game, "org.joml.Matrix4f"), matrixLike = Game.type(game, "org.joml.Matrix4fc");
            core = Game.exact(coreType.getMethod("getInstance"), MethodType.methodType(Object.class));
            projection = lookup.unreflectGetter(coreType.getField("projectionMatrixStack")).asType(MethodType.methodType(Object.class, Object.class));
            modelView = lookup.unreflectGetter(coreType.getField("modelViewMatrixStack")).asType(MethodType.methodType(Object.class, Object.class));
            peek = Game.exact(stack.getMethod("peek"), MethodType.methodType(Object.class, Object.class));
            empty = Game.exact(stack.getMethod("isEmpty"), MethodType.methodType(boolean.class, Object.class));
            mul = Game.exact(matrixType.getMethod("mul", matrixLike, matrixType), MethodType.methodType(Object.class, Object.class, Object.class, Object.class));
            matrixGet = Game.exact(matrixType.getMethod("get", FloatBuffer.class), MethodType.methodType(FloatBuffer.class, Object.class, FloatBuffer.class));
            product = matrixType.getConstructor().newInstance();
        }

        /** The looks' drawing, or null (reported once) in a game without what it needs. */
        static Gl open(ClassLoader game) {
            try { return new Gl(game); }
            catch (ReflectiveOperationException | RuntimeException | LinkageError missing) {
                System.err.println("[PZExt] text: the looks fade instead in this game: " + missing);
                return null;
            }
        }

        private void report(String what, Throwable failure) {
            if (!reported) System.err.println("[PZExt] text: " + what + "; the looks fade instead: " + failure);
            reported = true;
        }

        /** Lets a burn map's texture go, on the render thread. */
        void deleteTexture(int texture) {
            try { deleteTexture.invokeExact(texture); }
            catch (Throwable failure) { report("a burn map could not be let go", failure); }
        }

        // ---- the program ----

        private static final String VERTEX = """
            #version 120
            attribute vec2 pos; attribute vec2 uv; attribute vec4 col; attribute vec3 aux;
            uniform mat4 mvp;
            varying vec2 vUv; varying vec4 vCol; varying vec3 vAux;
            void main() { vUv = uv; vCol = col; vAux = aux; gl_Position = mvp * vec4(pos, 0.0, 1.0); }
            """;

        // The page's shader (tools/title-lab), its picture read through pic(): its part of the game's texture, nothing outside it.
        private static final String FRAGMENT = """
            #version 120
            uniform sampler2D tex; uniform sampler2D burnMap; uniform vec4 texRect;
            uniform float mode, progress, edgeW, charW, scorchW, glow, flickerN, flickerD;
            uniform vec3 burn, scorched, charred; uniform vec2 picSize; uniform vec2 blurR; uniform float grainSize, drainBy;
            uniform vec3 torch; uniform float reveal, remain, light, ember;
            uniform float sig, clock, staticBy;
            uniform float clear, fogAmt, noiseScale; uniform vec2 fogHalf;
            varying vec2 vUv; varying vec4 vCol; varying vec3 vAux;
            float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
            float vn(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
              return mix(mix(h(i), h(i + vec2(1.0, 0.0)), f.x), mix(h(i + vec2(0.0, 1.0)), h(i + vec2(1.0, 1.0)), f.x), f.y); }
            float fbm(vec2 q) { return 0.5 * vn(q) + 0.3 * vn(q * 2.1 + 3.0) + 0.2 * vn(q * 4.3 + 7.0); }
            vec4 pic(vec2 p) {
              if (p.x < 0.0 || p.y < 0.0 || p.x > 1.0 || p.y > 1.0) return vec4(0.0);
              return texture2D(tex, texRect.xy + p * texRect.zw);
            }
            void main() {
              if (mode < 0.5) { gl_FragColor = pic(vUv) * vCol; return; }
              if (mode < 1.5) {
                vec4 c = pic(vUv);
                vec4 bm = texture2D(burnMap, vUv);
                float B = (bm.r * 255.0 * 256.0 + bm.g * 255.0) / 65535.0;
                float x = B - progress;
                if (x <= 0.0) discard;
                float a = c.a;
                vec3 col = a > 0.0 ? c.rgb / a : vec3(0.0);
                float fl = 1.0 - flickerD * (0.5 + 0.5 * sin(6.2831 * (progress * flickerN + vn(vUv * picSize / 7.0))));
                vec3 outc = col; float hot = 0.0;
                if (x < edgeW) {
                  float e = x / edgeW;
                  vec3 core = mix(vec3(1.0, 0.92, 0.65), burn, 0.3);
                  outc = mix(core, burn, smoothstep(0.0, 1.0, e)) * fl;
                  hot = (1.0 - 0.4 * e) * fl;
                } else if (x < edgeW + charW) {
                  float s = smoothstep(0.0, 0.6, (x - edgeW) / charW);
                  outc = mix(burn * 0.4 * fl, charred, s);
                  hot = 0.35 * (1.0 - s) * fl;
                } else if (x < edgeW + charW + scorchW) {
                  float s = 1.0 - (x - edgeW - charW) / scorchW;
                  outc = col * mix(vec3(1.0), scorched, s * s);
                }
                gl_FragColor = vec4(outc * a, a * (1.0 - glow * hot)) * vCol.a;
                return;
              }
              if (mode < 2.5) {
                vec2 l = vAux.xy;
                float n = vn(l * 2.3 + vAux.z * 37.0) + 0.5 * vn(l * 5.0 + vAux.z * 11.0);
                float m = 1.0 - smoothstep(0.6, 0.95, length(l) + (n - 0.75) * 0.75);
                gl_FragColor = vCol * m;
                return;
              }
              if (mode < 3.5) {
                float a = pic(vUv).a;
                gl_FragColor = vec4(vCol.rgb * a, vCol.a * a);
                return;
              }
              if (mode < 4.5) {
                float m = 1.0 - smoothstep(0.0, 1.0, length(vAux.xy));
                gl_FragColor = vCol * m * m;
                return;
              }
              if (mode < 5.5) {
                float a = pic(vUv).a;
                float d = (vUv.x + vUv.y * 0.35) - progress;
                gl_FragColor = vec4(vCol.rgb * a * exp(-d * d / (edgeW * edgeW)), 0.0);
                return;
              }
              if (mode > 12.5) {
                float bx = vUv.x < 0.2 ? vUv.x / 0.2 : vUv.x > 0.8 ? (1.0 - vUv.x) / 0.2 : 1.0;
                float by = vUv.y < 0.3 ? vUv.y / 0.3 : vUv.y > 0.7 ? (1.0 - vUv.y) / 0.3 : 1.0;
                float a = clamp(bx, 0.0, 1.0) * clamp(by, 0.0, 1.0);
                gl_FragColor = vec4(vCol.rgb * a, vCol.a * a);
                return;
              }
              if (mode > 11.5) {
                vec2 l = vAux.xy;
                vec2 q = l * fogHalf / noiseScale * 0.35;
                float flow = 0.6 * fbm(q + vec2(clock * 0.22, clock * 0.03)) + 0.4 * fbm(q * 1.7 + vec2(-clock * 0.13, clock * 0.06) + 5.0);
                float band = (1.0 - smoothstep(0.3, 1.0, abs(l.x))) * (1.0 - smoothstep(0.1, 1.0, abs(l.y)));
                float m = smoothstep(0.22, 0.78, flow) * band * fogAmt * 0.55;
                gl_FragColor = vec4(vec3(0.84, 0.86, 0.88) * m, m);
                return;
              }
              if (mode > 10.5) {
                vec2 q = vUv * picSize / noiseScale * 0.6 + vec2(clock * 0.2, clock * 0.03);
                float n = fbm(q);
                float vis = smoothstep(n - 0.35, n + 0.35, clear * 1.7 - 0.35);
                vec2 r = blurR * (1.0 - vis);
                vec4 c = pic(vUv) * 0.2;
                for (int i = 0; i < 8; i++) { float t = float(i) / 8.0 * 6.2831; c += pic(vUv + vec2(cos(t), sin(t)) * r) * 0.1; }
                if (c.a <= 0.0) discard;
                vec3 col = c.rgb / c.a;
                col = mix(col, vec3(dot(col, vec3(0.3, 0.55, 0.15))) * vec3(0.86, 0.9, 0.95), (1.0 - vis) * 0.6);
                gl_FragColor = vec4(col * c.a, c.a) * vis * vCol.a;
                return;
              }
              if (mode > 9.5) {
                vec2 px = vUv * picSize;
                float weak = 1.0 - sig;
                float row = floor(px.y / 3.0), tick = floor(clock * 24.0);
                float tear = (h(vec2(row, tick)) - 0.5) * weak * weak * 0.12 + (h(vec2(floor(px.y / 11.0), tick + 7.0)) - 0.5) * weak * 0.05;
                float apart = weak * 0.006;
                vec4 cr = pic(vUv + vec2(tear + apart, 0.0));
                vec4 cg = pic(vUv + vec2(tear, 0.0));
                vec4 cb = pic(vUv + vec2(tear - apart, 0.0));
                vec4 c = vec4(cr.r, cg.g, cb.b, max(cg.a, max(cr.a, cb.a)));
                float grain = h(floor(px / 1.5) + vec2(tick * 3.1, tick * 1.7));
                float keep = smoothstep(grain - 0.12, grain + 0.12, sig * 1.15 - 0.05);
                float scan = 1.0 - 0.18 * weak * step(0.5, fract(px.y / 3.0));
                c *= keep * scan;
                c.rgb = mix(c.rgb, c.rgb * vec3(0.78, 0.92, 1.05), weak);
                float speck = step(0.992, h(floor(px / 2.0) + vec2(tick * 5.3, tick))) * weak * sig * 4.0 * staticBy;
                gl_FragColor = (c + vec4(vec3(0.75, 0.85, 0.95) * speck * 0.5, 0.0)) * vCol.a;
                return;
              }
              if (mode > 8.5) {
                vec4 c = pic(vUv);
                float a = c.a;
                if (a <= 0.0) discard;
                vec3 col = c.rgb / a;
                vec2 d = (vUv - torch.xy) * vec2(1.0, picSize.y / picSize.x);
                float beam = 1.0 - smoothstep(0.35, 1.0, length(d) / torch.z);
                float trail = (1.0 - smoothstep(reveal - 0.3, reveal + 0.02, vUv.x)) * remain;
                float seen = clamp(max(beam, trail), 0.0, 1.0);
                col = col * mix(vec3(0.55, 0.32, 0.14), vec3(1.0), light) * light + vec3(1.0, 0.86, 0.6) * beam * 0.22 * light;
                gl_FragColor = vec4(col * a * seen, a * seen) * ember * vCol.a;
                return;
              }
              vec4 c = pic(vUv);
              float a = c.a;
              if (a <= 0.0) discard;
              vec3 col = c.rgb / a;
              float cover = 0.0;
              for (int i = 0; i < 8; i++) { float t = float(i) / 8.0 * 6.2831; cover += pic(vUv + vec2(cos(t), sin(t)) * blurR).a; }
              cover /= 8.0;
              vec2 px = vUv * picSize;
              float n = 0.5 * vn(px / grainSize) + 0.3 * vn(px / (grainSize * 0.4)) + 0.2 * vn(px / (grainSize * 0.15));
              float keep = n * 0.7 + cover * 0.3;
              float wear = 0.22 + 0.7 * smoothstep(0.08, 0.92, progress);
              float mask = smoothstep(wear - 0.05, wear + 0.05, keep);
              float drain = smoothstep(0.3, 0.85, progress) * drainBy;
              float lum = dot(col, vec3(0.3, 0.55, 0.15));
              col = mix(col, vec3(lum) * vec3(0.86, 0.8, 0.72) * 0.8, drain);
              float last = 1.0 - smoothstep(0.7, 1.0, progress);
              gl_FragColor = vec4(col * a, a) * mask * last * vCol.a;
            }
            """;

        /** The page's modes: the picture, burning, a shard of ash, its shape as light, a puff, a gleam, eroding, torch-lit, radio, through mist, mist, a band of light. */
        private static final int PICTURE = 0, BURNING = 1, SHARD = 2, SHAPE = 3, PUFF = 4, GLEAM = 5, ERODING = 8, LIT = 9, SIGNAL = 10,
            MISTED = 11, MIST = 12, BAND = 13;

        /** Compiles the program, once; false when it does not (reported, and the looks fade from then on). */
        private boolean program() throws Throwable {
            if (program > 0) return true;
            if (program == 0) return false;
            program = 0;
            int vertex = compile(VERTEX_SHADER, VERTEX), fragment = compile(FRAGMENT_SHADER, FRAGMENT);
            if (vertex == 0 || fragment == 0) { failed = true; return false; }
            int made = (int)createProgram.invokeExact();
            attachShader.invokeExact(made, vertex);
            attachShader.invokeExact(made, fragment);
            bindAttrib.invokeExact(made, 0, (CharSequence)"pos");
            bindAttrib.invokeExact(made, 1, (CharSequence)"uv");
            bindAttrib.invokeExact(made, 2, (CharSequence)"col");
            bindAttrib.invokeExact(made, 3, (CharSequence)"aux");
            linkProgram.invokeExact(made);
            if ((int)programValue.invokeExact(made, LINK_STATUS) == 0) {
                report("the looks' shader did not link", new IllegalStateException((String)programLog.invokeExact(made)));
                failed = true;
                return false;
            }
            uMode = at(made, "mode"); uMvp = at(made, "mvp"); uTex = at(made, "tex"); uMap = at(made, "burnMap"); uTexRect = at(made, "texRect");
            uProgress = at(made, "progress"); uEdge = at(made, "edgeW"); uChar = at(made, "charW"); uScorch = at(made, "scorchW");
            uGlow = at(made, "glow"); uFlickerN = at(made, "flickerN"); uFlickerD = at(made, "flickerD"); uBurn = at(made, "burn");
            uScorched = at(made, "scorched"); uCharred = at(made, "charred"); uPicSize = at(made, "picSize"); uBlur = at(made, "blurR");
            uGrain = at(made, "grainSize"); uDrain = at(made, "drainBy"); uTorch = at(made, "torch"); uReveal = at(made, "reveal");
            uRemain = at(made, "remain"); uLight = at(made, "light"); uEmber = at(made, "ember"); uSig = at(made, "sig");
            uClock = at(made, "clock"); uStatic = at(made, "staticBy"); uClear = at(made, "clear"); uFogAmt = at(made, "fogAmt");
            uNoise = at(made, "noiseScale"); uFogHalf = at(made, "fogHalf");
            program = made;
            return true;
        }

        private int at(int made, String name) throws Throwable { return (int)uniformAt.invokeExact(made, (CharSequence)name); }

        private int compile(int type, String source) throws Throwable {
            int shader = (int)createShader.invokeExact(type);
            shaderSource.invokeExact(shader, (CharSequence)source);
            compileShader.invokeExact(shader);
            if ((int)shaderValue.invokeExact(shader, COMPILE_STATUS) != 0) return shader;
            report("the looks' shader did not compile", new IllegalStateException((String)shaderLog.invokeExact(shader)));
            return 0;
        }

        // ---- a frame ----

        /** Draws a frame's look, on the render thread, in the render queue: the game's state saved and put back around it. */
        void render(Frame f) {
            Dust.Piece piece = f.piece;
            if (failed || piece.released || piece.destroyed.get()) return;
            boolean pushed = false;
            int before = 0;
            try {
                before = (int)getInteger.invokeExact(CURRENT_PROGRAM);
                pushClient.invokeExact(-1);
                pushAttrib.invokeExact(ALL_ATTRIB_BITS);
                pushed = true;
                if (!program()) return;
                useProgram.invokeExact(program);
                enable.invokeExact(BLEND);
                blendFunc.invokeExact(ONE, ONE_MINUS_SRC_ALPHA);
                disable.invokeExact(ALPHA_TEST);
                disable.invokeExact(DEPTH_TEST);
                disable.invokeExact(CULL_FACE);
                // The projection the interface is drawn with now.
                Object instance = (Object)core.invokeExact();
                Object projectionStack = (Object)projection.invokeExact(instance), viewStack = (Object)modelView.invokeExact(instance);
                if ((boolean)empty.invokeExact(projectionStack) || (boolean)empty.invokeExact(viewStack)) return;
                Object made = (Object)mul.invokeExact((Object)peek.invokeExact(projectionStack), (Object)peek.invokeExact(viewStack), product);
                matrix.clear();
                FloatBuffer floats = (FloatBuffer)matrixGet.invokeExact(product, matrix);
                uniformMatrix.invokeExact(uMvp, false, matrix);
                uniform1i.invokeExact(uTex, 0);
                uniform1i.invokeExact(uMap, 1);
                // The picture: its part of the texture, its rows going up from the box's bottom.
                activeTexture.invokeExact(TEXTURE0);
                bindTexture.invokeExact(TEXTURE_2D, (int)textureId.invokeExact(piece.texture));
                texParameter.invokeExact(TEXTURE_2D, MIN_FILTER, LINEAR);
                texParameter.invokeExact(TEXTURE_2D, MAG_FILTER, LINEAR);
                uniform4f.invokeExact(uTexRect, piece.uStart, piece.vEnd, piece.uEnd - piece.uStart, piece.vStart - piece.vEnd);
                uniform2f.invokeExact(uPicSize, (float)piece.boxWidth, (float)piece.boxHeight);
                bindBuffer.invokeExact(ARRAY_BUFFER, 0);
                for (int index = 4; index < 8; index++) disableAttrib.invokeExact(index);
                for (int index = 0; index < 4; index++) enableAttrib.invokeExact(index);
                count = 0;
                compose(f);
            } catch (Throwable failure) {
                if (failure instanceof VirtualMachineError fatal && !(fatal instanceof OutOfMemoryError)) throw fatal;
                failed = true;
                report("a look could not be drawn", failure);
            } finally {
                try {
                    if (pushed) {
                        activeTexture.invokeExact(TEXTURE0);
                        popAttrib.invokeExact();
                        popClient.invokeExact();
                    }
                    useProgram.invokeExact(before);
                    lastTexture.invokeExact(-1);
                    restoreVbos.invokeExact((Object)ringBuffer.invokeExact(), true);
                    restore.invokeExact();
                } catch (Throwable failure) {
                    failed = true;
                    report("the game's drawing could not be put back", failure);
                }
            }
        }

        private void compose(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            if (f.burn && f.out > 0) { paper(f); return; }
            switch (f.look) {
                case TORCH -> torch(f);
                case RADIO -> radio(f);
                case FOG -> fog(f);
                default -> {
                    if (f.erode && f.out > 0) erode(f);
                    else if (f.alpha > 0.002) {
                        float a = (float)f.alpha;
                        double hw = piece.boxWidth * f.s * f.sx / 2, hh = piece.boxHeight * f.s * f.sy / 2, cx = f.cx + f.dx, cy = f.cy + f.dy;
                        mode = PICTURE;
                        quad(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, a, a, a, a);
                        flush();
                    }
                }
            }
            if (f.impact) impact(f);
        }

        /** The burn: the text spot by spot by its map, then its shards of ash and sparks. */
        private void paper(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            Dust.Cells cells = piece.cells;
            if (cells == null || piece.map == null) return;
            if (piece.mapTexture == 0) {
                int made = (int)genTexture.invokeExact();
                activeTexture.invokeExact(TEXTURE1);
                bindTexture.invokeExact(TEXTURE_2D, made);
                texParameter.invokeExact(TEXTURE_2D, MIN_FILTER, NEAREST);
                texParameter.invokeExact(TEXTURE_2D, MAG_FILTER, NEAREST);
                texParameter.invokeExact(TEXTURE_2D, WRAP_S, CLAMP_TO_EDGE);
                texParameter.invokeExact(TEXTURE_2D, WRAP_T, CLAMP_TO_EDGE);
                pixelStore.invokeExact(UNPACK_ALIGNMENT, 4);
                texImage.invokeExact(TEXTURE_2D, 0, RGBA, piece.boxWidth, piece.boxHeight, 0, RGBA, UNSIGNED_BYTE, piece.map.duplicate());
                piece.mapTexture = made;
            } else {
                activeTexture.invokeExact(TEXTURE1);
                bindTexture.invokeExact(TEXTURE_2D, piece.mapTexture);
            }
            activeTexture.invokeExact(TEXTURE0);
            float progress = (float)f.out;
            uniform1f.invokeExact(uProgress, progress);
            uniform1f.invokeExact(uEdge, (float)EDGE_W);
            uniform1f.invokeExact(uChar, (float)CHAR_W);
            uniform1f.invokeExact(uScorch, (float)SCORCH_W);
            uniform1f.invokeExact(uGlow, (float)Dust.GLOW);
            uniform1f.invokeExact(uFlickerN, (float)Dust.FLICKER);
            uniform1f.invokeExact(uFlickerD, (float)Dust.FLICKER_DEPTH);
            uniform3f.invokeExact(uBurn, f.burnRed, f.burnGreen, f.burnBlue);
            uniform3f.invokeExact(uScorched, (float)Dust.SCORCHED[0], (float)Dust.SCORCHED[1], (float)Dust.SCORCHED[2]);
            uniform3f.invokeExact(uCharred, (float)Dust.CHARRED[0], (float)Dust.CHARRED[1], (float)Dust.CHARRED[2]);
            double x = piece.boxX, y = piece.boxY;
            mode = BURNING;
            quad(x, y, x + piece.boxWidth, y + piece.boxHeight, 0, 0, 1, 1, 1, 1, 1, 1);
            flush();
            mode = SHARD;
            double reach = piece.line * f.drift, size = cells.size;
            for (int cell = 0; cell < cells.count; cell++) {
                double kind = cells.phase2[cell];
                boolean spark = kind < Dust.SPARKS, flake = !spark && kind < Dust.SPARKS + (1 - Dust.SPARKS) * FLAKES;
                if (!spark && !flake) continue;
                double age = (f.out - cells.start[cell]) / cells.life[cell];
                if (age <= 0 || age >= 1) continue;
                double shown = Dust.alpha(age);
                if (shown <= 0.002) continue;
                double cx = x + (cells.column[cell] + 0.5) * size + reach * Dust.driftX(age, cells.side[cell], cells.freq[cell], cells.phase[cell]);
                double cy = y + (cells.row[cell] + 0.5) * size + reach * Dust.driftY(age, cells.rise[cell], cells.freq[cell], cells.phase2[cell]);
                double turn = (cells.phase[cell] < 0.5 ? -1 : 1) * SPIN * age + cells.phase[cell] * 6.28;
                if (spark) {
                    double hot = Dust.heat(age), keep = Dust.BURN_ASH + (1 - Dust.BURN_ASH) * hot, hs = size * 0.35 * cells.flake[cell];
                    shard(cx, cy, hs, turn, 1, shown * f.burnRed * keep, shown * f.burnGreen * keep, shown * f.burnBlue * keep,
                        shown * (1 - Dust.GLOW * hot), cells.phase[cell]);
                    continue;
                }
                // Ash: char as it leaves, greying fast, its rim still glowing a moment.
                double tumble = 0.25 + 0.75 * Math.abs(Math.cos(SPIN * 0.7 * age * cells.freq[cell] + cells.phase2[cell] * 6.28));
                double grey = Dust.CHARRED[0] + (PAPER_ASH - Dust.CHARRED[0]) * smooth(clamp(age / GREYING, 0, 1));
                double warm = 1 - smooth(clamp(age / 0.15, 0, 1));
                double hs = size * FLAKE_SIZE * cells.flake[cell] * (1 - 0.4 * clamp(age, 0, 1));
                shard(cx, cy, hs, turn, tumble, shown * (grey + (f.burnRed * 0.6 - grey) * warm), shown * (grey + (f.burnGreen * 0.6 - grey) * warm),
                    shown * (grey + (f.burnBlue * 0.6 - grey) * warm), shown, cells.phase[cell]);
            }
            flush();
        }

        /** Torch-lit: the light thrown behind the text (the torch's own text), and the text in the beam and the trail it lit. */
        private void torch(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            double light = light(f.group, f.cue, f.out), ember = ember(f.out);
            if (f.lead) Looks.torch(Math.min(f.secs, f.leaving), torch);
            else farTorch(torch);
            double s = f.s, cx = f.cx + f.dx, cy = f.cy + f.dy, hw = piece.boxWidth * s / 2, hh = piece.boxHeight * s / 2;
            if (f.lead && TORCH_POOL > 0) {
                double strength = 0.09 * TORCH_POOL * torch[5] * light * ember * f.alpha;
                if (strength > 0.002) {
                    mode = PUFF;
                    shard(cx + (torch[0] - 0.5) * piece.boxWidth * s, cy + (torch[1] - 0.5) * piece.boxHeight * s, f.line * 1.3 * (1 + 1.2 * torch[6]), 0, 0.6,
                        strength, 0.82 * strength, 0.55 * strength, 0, 0);
                    flush();
                }
            }
            mode = LIT;
            uniform3f.invokeExact(uTorch, (float)torch[0], (float)torch[1], (float)torch[2]);
            uniform1f.invokeExact(uReveal, (float)torch[3]);
            uniform1f.invokeExact(uRemain, (float)torch[4]);
            uniform1f.invokeExact(uLight, (float)light);
            uniform1f.invokeExact(uEmber, (float)ember);
            float a = (float)f.enterAlpha;
            quad(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, a, a, a, a);
            flush();
        }

        /** Radio: the text as a signal of its strength. */
        private void radio(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            double s = f.s, cx = f.cx + f.dx, cy = f.cy + f.dy, hw = piece.boxWidth * s / 2, hh = piece.boxHeight * s / 2;
            mode = SIGNAL;
            uniform1f.invokeExact(uSig, (float)signal(f.enterTime, f.secs, f.out));
            uniform1f.invokeExact(uClock, (float)f.group);
            uniform1f.invokeExact(uStatic, (float)RADIO_STATIC);
            float a = (float)f.enterAlpha;
            quad(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, a, a, a, a);
            flush();
        }

        /** Mist: the mist behind the text, and the text through it. */
        private void fog(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            double s = f.s, cx = f.cx + f.dx, cy = f.cy + f.dy, hw = piece.boxWidth * s / 2, hh = piece.boxHeight * s / 2;
            uniform1f.invokeExact(uClock, (float)(f.group * FOG_DRIFT));
            uniform1f.invokeExact(uNoise, (float)(f.line * 0.5));
            double fx = f.ink * 0.5 + f.line * 1.5, fy = f.line * 1.3;
            mode = MIST;
            uniform1f.invokeExact(uFogAmt, (float)(mist(f.enterTime, f.secs, f.out) * FOG_THICK));
            uniform2f.invokeExact(uFogHalf, (float)fx, (float)fy);
            shard(cx, cy, fx, 0, fy / fx, 0, 0, 0, 0, 0);
            flush();
            mode = MISTED;
            uniform1f.invokeExact(uClear, (float)clear(f.enterTime, f.secs, f.out));
            uniform2f.invokeExact(uBlur, (float)(f.line * 0.08 / piece.boxWidth), (float)(f.line * 0.08 / piece.boxHeight));
            float a = (float)f.enterAlpha;
            quad(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, a, a, a, a);
            flush();
        }

        /** Weathering away in place. */
        private void erode(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            double s = f.s, cx = f.cx + f.dx, cy = f.cy + f.dy, hw = piece.boxWidth * s / 2, hh = piece.boxHeight * s / 2;
            double r = Math.max(1, f.line * 0.03);
            mode = ERODING;
            uniform1f.invokeExact(uProgress, (float)f.out);
            uniform2f.invokeExact(uBlur, (float)(r / piece.boxWidth), (float)(r / piece.boxHeight));
            uniform1f.invokeExact(uGrain, (float)(ERODE_GRAIN * f.line / 72));
            uniform1f.invokeExact(uDrain, (float)ERODE_DRAIN);
            quad(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, 1, 1, 1, 1);
            flush();
        }

        /** The impact's light and dust over the text, and the gleam that passes over it once as it stays. */
        private void impact(Frame f) throws Throwable {
            double secs = f.secs;
            if (secs < IMPACT) return;
            Dust.Piece piece = f.piece;
            double k = secs - IMPACT, cx = f.cx + f.dx, cy = f.cy + f.dy, sx = f.s * f.sx, sy = f.s * f.sy, la = f.left;
            double hw = piece.boxWidth * sx / 2, hh = piece.boxHeight * sy / 2;
            // White-hot letters cooling, and their glow.
            double hot = Math.exp(-k * IMPACT_COOL) * la;
            if (hot > 0.01) {
                mode = SHAPE;
                box(cx, cy, hw, hh, hot, 0.92 * hot, 0.75 * hot);
                double r = f.line * 0.05 * (1 + 2 * k), glow = 0.1 * hot * IMPACT_GLOW;
                for (int index = 0; index < 12; index++) {
                    double angle = index / 12.0 * 2 * Math.PI;
                    box(cx + Math.cos(angle) * r, cy + Math.sin(angle) * r, hw, hh, glow, 0.8 * glow, 0.5 * glow);
                }
                flush();
            }
            // A streak of light across, widening.
            double streak = IMPACT_STREAK * Math.exp(-k * 5) * la;
            if (streak > 0.01) {
                mode = BAND;
                double wide = f.ink * (0.5 + 1.3 * (1 - Math.exp(-k * 7))), high = f.line * 0.07 * (1 + k), y = cy + f.line * 0.05;
                quad(cx - wide / 2, y - high / 2, cx + wide / 2, y + high / 2, 0, 0, 1, 1, streak, 0.9 * streak, 0.75 * streak, 0);
                quad(cx - wide * 0.35, y - high * 0.18, cx + wide * 0.35, y + high * 0.18, 0, 0, 1, 1, streak, streak, streak, 0);
                flush();
            }
            // Dust kicked out from under the letters, to the sides.
            mode = PUFF;
            double ink = f.ink > 0 ? f.ink : 1;
            for (int index = 0; index < PUFFS; index++) {
                double life = 0.9 + 0.5 * hash(index, 5, 77);
                if (k > life) continue;
                double x0 = (hash(index, 1, 77) - 0.5) * 0.9 * ink, side = x0 < 0 ? -1 : 1;
                double vx = side * (0.3 + 0.9 * hash(index, 2, 77)) + 1.2 * x0 / ink, vy = -(0.05 + 0.35 * hash(index, 3, 77));
                double size = 0.05 + 0.08 * hash(index, 4, 77);
                double e = (1 - Math.exp(-3.2 * k)) / 3.2, fade = 0.3 * IMPACT_DUST * Math.pow(1 - k / life, 1.5) * la;
                double x = cx + x0 + vx * e * f.line, y = cy + 0.3 * f.line + vy * e * f.line + 0.1 * f.line * k * k;
                shard(x, y, f.line * size * (1 + 1.5 * k), 0, 1, 0.8 * fade, 0.78 * fade, 0.74 * fade, fade, 0);
            }
            flush();
            // A gleam passing over the letters once, slowly, from settled to leaving (wholly off them at both ends, softly).
            double at = (secs - SHINE_AT) / Math.max(0.5, f.scheduled - SHINE_AT - 0.3);
            if (at > 0 && at < 1) {
                mode = GLEAM;
                uniform1f.invokeExact(uProgress, (float)(-0.45 + 2.2 * at));
                uniform1f.invokeExact(uEdge, 0.12f);
                double s = 0.85 * SHINE * la * smooth(clamp(at / 0.15, 0, 1)) * smooth(clamp((1 - at) / 0.15, 0, 1)), r = f.line * 0.035, halo = 0.12 * s;
                box(cx, cy, hw, hh, s, 0.97 * s, 0.9 * s);
                for (int index = 0; index < 12; index++) {
                    double angle = index / 12.0 * 2 * Math.PI;
                    box(cx + Math.cos(angle) * r, cy + Math.sin(angle) * r, hw, hh, halo, 0.95 * halo, 0.85 * halo);
                }
                flush();
            }
        }

        /** The whole picture about a middle, in a colour of light (alpha 0: it adds). */
        private void box(double cx, double cy, double hw, double hh, double r, double g, double b) {
            quad(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, r, g, b, 0);
        }

        // ---- the vertices ----

        private void vertex(double x, double y, double u, double v, double r, double g, double b, double a, double l0, double l1, double seed) {
            FloatBuffer to = verts;
            int at = count * FLOATS;
            to.put(at, (float)x).put(at + 1, (float)y).put(at + 2, (float)u).put(at + 3, (float)v).put(at + 4, (float)r).put(at + 5, (float)g)
                .put(at + 6, (float)b).put(at + 7, (float)a).put(at + 8, (float)l0).put(at + 9, (float)l1).put(at + 10, (float)seed);
            count++;
        }

        /** Room for six more vertices: the buffer doubles when it is full. */
        private void room() {
            if ((count + 6) * FLOATS <= verts.capacity()) return;
            FloatBuffer larger = ByteBuffer.allocateDirect(verts.capacity() * 2 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
            larger.put(0, verts, 0, count * FLOATS);
            verts = larger;
        }

        private void quad(double x0, double y0, double x1, double y1, double u0, double v0, double u1, double v1, double r, double g, double b, double a) {
            room();
            vertex(x0, y0, u0, v0, r, g, b, a, -1, -1, 0); vertex(x1, y0, u1, v0, r, g, b, a, 1, -1, 0); vertex(x1, y1, u1, v1, r, g, b, a, 1, 1, 0);
            vertex(x0, y0, u0, v0, r, g, b, a, -1, -1, 0); vertex(x1, y1, u1, v1, r, g, b, a, 1, 1, 0); vertex(x0, y1, u0, v1, r, g, b, a, -1, 1, 0);
        }

        /** A shard (or a puff) about a middle, half its side {@code hs}, turned by {@code angle}, its height times {@code tumble}. */
        private void shard(double cx, double cy, double hs, double angle, double tumble, double r, double g, double b, double a, double seed) {
            room();
            double cos = Math.cos(angle), sin = Math.sin(angle);
            corner(cx, cy, hs, tumble, cos, sin, -1, -1, r, g, b, a, seed); corner(cx, cy, hs, tumble, cos, sin, 1, -1, r, g, b, a, seed);
            corner(cx, cy, hs, tumble, cos, sin, 1, 1, r, g, b, a, seed); corner(cx, cy, hs, tumble, cos, sin, -1, -1, r, g, b, a, seed);
            corner(cx, cy, hs, tumble, cos, sin, 1, 1, r, g, b, a, seed); corner(cx, cy, hs, tumble, cos, sin, -1, 1, r, g, b, a, seed);
        }

        private void corner(double cx, double cy, double hs, double tumble, double cos, double sin, double lx, double ly, double r, double g, double b,
                double a, double seed) {
            double x = lx * hs, y = ly * hs * tumble;
            vertex(cx + x * cos - y * sin, cy + x * sin + y * cos, 0, 0, r, g, b, a, lx, ly, seed);
        }

        /** Draws what was put since the last, in the mode. */
        private void flush() throws Throwable {
            if (count == 0) return;
            uniform1f.invokeExact(uMode, (float)mode);
            FloatBuffer all = verts;
            attribPointer.invokeExact(0, 2, FLOAT, false, STRIDE, all.position(0));
            attribPointer.invokeExact(1, 2, FLOAT, false, STRIDE, all.position(2));
            attribPointer.invokeExact(2, 4, FLOAT, false, STRIDE, all.position(4));
            attribPointer.invokeExact(3, 3, FLOAT, false, STRIDE, all.position(8));
            all.position(0);
            drawArrays.invokeExact(TRIANGLES, 0, count);
            count = 0;
        }
    }
}
