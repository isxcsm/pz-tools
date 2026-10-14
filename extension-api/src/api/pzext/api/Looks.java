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
 *     edge, shards of ash and sparks tumbling away on the wind;</li>
 * <li>{@code bleed} (enter) and {@code dry} (leave): drops fall on a title one after another and spread where they land,
 *     soaking its letters in with a wet front (a line seeps in so, without drops); a drop runs down from it as it stays; they
 *     dry dark and flake away in patches as it leaves;</li>
 * <li>{@code under} (leave): still water shows under it, its mirror in it coming up swaying in fine streaks; then it sinks
 *     into that water, slowly at first, fading as it goes;</li>
 * <li>{@code strike} (enter) and {@code feed} (leave): its letters struck one by one at a typist's uneven pace, a little off
 *     their line and unevenly inked; the paper fed up a line at a time as it leaves;</li>
 * <li>{@code exhale} (leave): it beats with a heart (a warm glow flaring with each beat) that calms as it stays; one more
 *     beat, a stillness and a last weak one as it starts to leave, and then a breath out: it settles and fades, its glow
 *     staying on a moment after it.</li>
 * <li>{@code wash} (leave): it is inked as it shows (as it hits, after an impact): wet ink, patchy where the paper held it
 *     back, glossy and stirring a little as it stays; as it leaves it dries in blotches, its colour lifting away, the pressed
 *     shape of it left a moment (a map of each spot's ink, made once from its picture).</li>
 * </ul>
 * The numbers are those of tools/title-lab, where the looks are made: the page draws them with the same arithmetic and shader.
 */
final class Looks {
    // ---- the looks' numbers (tools/title-lab) ----

    /** Impact: the fall, in seconds; how fast the heat cools; the glow, the streak and the dust's strength; when the gleam starts and how bright it is. */
    static final double IMPACT = 0.16, IMPACT_COOL = 4, IMPACT_GLOW = 1, IMPACT_STREAK = 0.8, IMPACT_DUST = 1, SHINE_AT = 0.8, SHINE = 0.2;
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
    /**
     * Bleed: how fast a drop spreads, how wet its front looks, how strong the soaked blot beyond the title's letters is, how far
     * its drop runs down; how long a drop falls, and its flecks fly, in seconds; when the title's drops land and the line's seep in.
     */
    static final double BLEED_SOAK = 2.2, BLEED_WET = 0.5, BLEED_STAIN = 0.2, BLEED_DRIP = 1, FALL = 0.2, SPLASH = 0.35;
    static final double[] FALLS = { 0.2, 0.7, 1.0, 1.2, 1.35, 1.48 }, SEEPS = { 0, 0.25, 0.45, 0.6, 0.7, 0.8 };
    static final int MAX_DROPS = 6;
    /**
     * Sink: how deep it sinks (in its lines), how much the water stirs, how strong its mirror is; in seconds into a leave of
     * SINK_LEAVE (a shorter one has them shorter alike), how long the mirror takes to come up and then stays before it sinks.
     */
    static final double SINK_DEPTH = 0.75, SINK_SWELL = 1, SINK_MIRROR = 1, MIRROR_IN = 3.5, MIRROR_STAY = 1.5, SINK_LEAVE = 9;
    /**
     * Strike: how far its letters stray off their line, how unevenly they are inked, how far the paper is fed; when each feed
     * starts (shares of the leave), how long it takes (seconds) and how far it goes (in the title's lines).
     */
    static final double TYPE_JITTER = 1, TYPE_INK = 1, TYPE_FEED = 1, FEED_TIME = 0.22, FEED_STEP = 0.2;
    static final double[] FEEDS = { 0.08, 0.34, 0.6 };
    /**
     * Pulse: how bright its glow is, how strong its beats, how much it calms. In seconds into a leave of PULSE_LEAVE (a shorter
     * one has them shorter alike): how long a beat takes to die down, when one more beat comes, how long the stillness is before
     * the last, and so when that last beat comes and when the breath out starts.
     */
    static final double PULSE_GLOW = 1, PULSE_BEAT = 1, PULSE_CALM = 1, PULSE_LEAVE = 10.7, BEAT_LENGTH = 0.6, ONE_MORE = 0.55 + 0.55 * PULSE_CALM,
        LAST_PAUSE = 1.2, LAST_BEAT = ONE_MORE + BEAT_LENGTH + LAST_PAUSE, EXHALE_AFTER = LAST_BEAT + BEAT_LENGTH + 1.7;

    /**
     * Wash: how patchy its ink is, how glossy while wet, how strongly its pressed shape shows as it goes, how much the wet ink
     * stirs, how dark its shadow is. A line under a title hits with LINE_HIT of an impact's strength.
     */
    static final double INK_PATCHY = 0.35, INK_GLOSS = 0.45, INK_EMBOSS = 1, INK_RIPPLE = 1, INK_SHADOW = 1, LINE_HIT = 0.55;
    private static final double[] FIBRE_AT = { 0.2, 1.4, 2.5 }, FIBRE_BY = { 0.4, 0.3, 0.2 };

    /** The looks drawn over a text's life. */
    static final int PLAIN = 0, TORCH = 1, RADIO = 2, FOG = 3, BLEED = 4, SINK = 5, STRIKE = 6, PULSE = 7, INK = 8;

    private Looks() { }

    // ---- the arithmetic (pure: the main thread's, the render thread's and the tests') ----

    static double smooth(double p) { return p * p * (3 - 2 * p); }

    static double clamp(double value, double low, double high) { return value < low ? low : value > high ? high : value; }

    static double bump(double x, double at, double width) { double d = (x - at) / width; return Math.exp(-d * d); }

    static double smoothstep(double from, double to, double x) { return smooth(clamp((x - from) / (to - from), 0, 1)); }

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

    /** Three octaves of {@link #vnoise}, 0 to 1 (the shader's {@code fbm}). */
    static double fbm(double x, double y, int s) {
        return 0.5 * vnoise(x, y, s) + 0.3 * vnoise(x * 2.1 + 3, y * 2.1 + 3, s) + 0.2 * vnoise(x * 4.3 + 7, y * 4.3 + 7, s);
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
     * Squared distances from each pixel of a picture {@code w} by {@code h} to the nearest one that {@code to} marks
     * (Felzenszwalb's transform, by columns and then rows; the page's {@code edt}).
     */
    static double[] distances(boolean[] to, int w, int h) {
        double[] out = new double[w * h];
        for (int index = 0; index < out.length; index++) out[index] = to[index] ? 0 : FAR;
        int n = Math.max(w, h);
        double[] line = new double[n], done = new double[n], bounds = new double[n + 1];
        int[] lows = new int[n];
        for (int x = 0; x < w; x++) {
            for (int y = 0; y < h; y++) line[y] = out[y * w + x];
            lower(line, h, done, lows, bounds);
            for (int y = 0; y < h; y++) out[y * w + x] = done[y];
        }
        for (int y = 0; y < h; y++) {
            System.arraycopy(out, y * w, line, 0, w);
            lower(line, w, done, lows, bounds);
            System.arraycopy(done, 0, out, y * w, w);
        }
        return out;
    }

    private static final double FAR = 1e10;

    /** One row's squared distances, into {@code done}: the lower envelope of the parabolas over {@code line}. */
    private static void lower(double[] line, int length, double[] done, int[] lows, double[] bounds) {
        int k = 0;
        lows[0] = 0;
        bounds[0] = -FAR;
        bounds[1] = FAR;
        for (int q = 1; q < length; q++) {
            double s;
            while (true) {
                int v = lows[k];
                s = ((line[q] + (double)q * q) - (line[v] + (double)v * v)) / (2.0 * q - 2.0 * v);
                if (s > bounds[k]) break;
                k--;
            }
            k++;
            lows[k] = q;
            bounds[k] = s;
            bounds[k + 1] = FAR;
        }
        k = 0;
        for (int q = 0; q < length; q++) {
            while (bounds[k + 1] < q) k++;
            int v = lows[k];
            done[q] = (double)(q - v) * (q - v) + line[v];
        }
    }

    /**
     * A washed text's ink map, from its picture's alpha ({@code w} by {@code h}, rows from the top): four values 0 to 1 a pixel,
     * how much ink it took (more down a stroke's middle; patchy, bare where the paper's grain and fibres held it back, a little
     * run together), the paper's fibre there, how late it dries and when its colour lifts (blotches of the paper). The strokes'
     * half width (their widest's, in pixels) goes into {@code shape.stroke}.
     */
    static float[] inkMap(Dust.Alpha alpha, int w, int h, int seed, Shape shape) {
        int n = w * h;
        boolean[] outside = new boolean[n];
        float[] cover = new float[n];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int a = alpha.at(x, y), index = y * w + x;
                cover[index] = a / 255f;
                outside[index] = a < 128;
            }
        double[] deep = distances(outside, w, h);
        double most = 0;
        for (int index = 0; index < n; index++) if (!outside[index]) most = Math.max(most, Math.sqrt(deep[index]) - 0.5);
        double r = Math.max(1.5, most * 0.85);
        shape.stroke = r;
        double[] cos = new double[3], sin = new double[3];
        for (int k = 0; k < 3; k++) {
            double angle = FIBRE_AT[k] + hash(k, 1, seed) * 0.6;
            cos[k] = Math.cos(angle);
            sin[k] = Math.sin(angle);
        }
        float[] map = new float[n * 4], lay = new float[n];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int index = y * w + x;
                double v = 0.1 * hash(x, y, seed + 9);
                for (int k = 0; k < 3; k++) v += FIBRE_BY[k] * vnoise((x * cos[k] + y * sin[k]) / 3, (y * cos[k] - x * sin[k]) / 0.6, seed + k);
                double fibre = clamp((v - 0.15) / 0.7, 0, 1);
                double bare = 1 - smoothstep(0.3, 0.62, fbm(x / (r * 1.4), y / (r * 1.4), seed + 23)) + 0.6 * (1 - smoothstep(0.15, 0.55, fibre));
                double middle = outside[index] ? 0 : smoothstep(0, r, Math.sqrt(deep[index]) - 0.5);
                lay[index] = (float)((0.55 + 0.45 * middle) * cover[index] * (1 - Math.min(INK_PATCHY * bare, 0.95)));
                map[index * 4 + 1] = (float)fibre;
                map[index * 4 + 2] = (float)smoothstep(0.2, 0.8, fbm(x / (r * 3.5), y / (r * 3.5), seed + 71));
                map[index * 4 + 3] = (float)fbm(x / (r * 1.3), y / (r * 1.3), seed + 19);
            }
        // Run together a little: across, then down.
        float[] across = new float[n];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int index = y * w + x;
                across[index] = 0.25f * lay[x > 0 ? index - 1 : index] + 0.5f * lay[index] + 0.25f * lay[x < w - 1 ? index + 1 : index];
            }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int index = y * w + x;
                map[index * 4] = 0.25f * across[y > 0 ? index - w : index] + 0.5f * across[index] + 0.25f * across[y < h - 1 ? index + w : index];
            }
        return map;
    }

    /** Values 0 to 1, four a pixel, as a texture's pixels (8 bits each). */
    static ByteBuffer bytes(float[] map) {
        ByteBuffer pixels = ByteBuffer.allocateDirect(map.length).order(ByteOrder.nativeOrder());
        for (float value : map) pixels.put((byte)Math.round(clamp(value, 0, 1) * 255));
        return pixels.flip();
    }

    /**
     * The impact's fall and hit at {@code secs} into the enter, as strong as {@code hit} (1: a title's), into {@code into}: alpha,
     * scale, squash across, squash up, shake across (in lines) and down (in lines).
     */
    static void impact(double secs, double hit, double[] into) {
        into[0] = 1; into[1] = 1; into[2] = 1; into[3] = 1; into[4] = 0; into[5] = 0;
        if (secs < IMPACT) {
            double u = Math.max(0, secs) / IMPACT;
            into[1] = 1 + 0.45 * hit * (1 - u * u);
            into[0] = Math.min(1, u * 2.5);
            return;
        }
        double k = secs - IMPACT, ring = hit * Math.exp(-k * 18), shake = hit * Math.exp(-k * 14);
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

    static double backOut(double p) { double c = 1.70158, q = p - 1; return 1 + (c + 1) * q * q * q + c * q * q; }

    /**
     * A bleeding text's drops, into {@code shape}: where each lands in its picture ({@code width} by {@code height}, its ink
     * {@code ink} wide in the middle), spread over its letters in a shuffled order, and when (a title's {@code falls}, one after
     * another; a line's seep in sooner); and how far each spreads, enough for them together to cover the letters.
     */
    static void drops(Shape shape, double ink, double line, double width, double height, int seed, boolean falls) {
        int count = (int)clamp(Math.round(ink / (line * (falls ? 1.2 : 4))), falls ? 3 : 2, MAX_DROPS);
        double space = ink / count, left = width / 2 - ink / 2;
        shape.reach = 1.15 * Math.hypot(space / 2, 0.55 * line) / 0.55;
        int[] order = new int[count];
        for (int index = 0; index < count; index++) {
            int at = index;
            while (at > 0 && hash(order[at - 1], 3, seed) > hash(index, 3, seed)) { order[at] = order[at - 1]; at--; }
            order[at] = index;
        }
        double[] times = falls ? FALLS : SEEPS;
        for (int index = 0; index < count; index++) {
            int k = order[index];
            shape.drops[index * 3] = left + space * (k + 0.5) + (hash(k, 4, seed) - 0.5) * 0.4 * space;
            shape.drops[index * 3 + 1] = height / 2 + (hash(k, 5, seed) - 0.5) * 0.3 * line;
            shape.drops[index * 3 + 2] = times[index];
        }
        shape.dropCount = count;
    }

    /** The lowest row a picture's ink reaches (its shadow too), in its pixels from the top: its rows read back from the bottom. */
    static double foot(java.nio.ByteBuffer pixels, int width, int height) {
        for (int y = height - 1; y > 0; y--)
            for (int x = 0; x < width; x++) if ((pixels.get(((height - 1 - y) * width + x) * 4 + 3) & 0xFF) > 8) return y + 1;
        return 1;
    }

    /** How far a sinking text has gone under, 0 to 1, {@code into} seconds into its leave: slowly at first, then faster and faster. */
    static double sunk(double into, double leaveTime) {
        double scale = Math.min(1, leaveTime / SINK_LEAVE), from = (MIRROR_IN + MIRROR_STAY) * scale;
        return Math.pow(clamp((into - from) / (leaveTime - from), 0, 1), 2.5);
    }

    /** How strong its mirror is: coming up, swaying, before it sinks (there is no water to see before). */
    static double mirror(double into, double leaveTime) {
        return SINK_MIRROR * smooth(clamp(into / (MIRROR_IN * Math.min(1, leaveTime / SINK_LEAVE)), 0, 1));
    }

    /** How much the water stirs: some always, more as the mirror comes up, settling. */
    static double swell(double into) { return SINK_SWELL * (0.35 + 0.65 * smooth(clamp(into / 0.3, 0, 1)) * Math.exp(-into / 3.2)); }

    /**
     * When each of a struck text's letters is struck, into {@code keys}, in seconds from its start: at a typist's uneven pace,
     * pausing after a space ({@code spaced}: the letter follows one), all within the first nine tenths of its enter.
     */
    static void keys(boolean[] spaced, int count, double enterTime, int seed, double[] keys) {
        double at = 0;
        for (int index = 0; index < count; index++) {
            if (index > 0) at += 0.7 + 0.6 * hash(index, 1, seed) + (spaced[index] ? 1.6 : 0);
            keys[index] = at;
        }
        double last = at > 0 ? at : 1;
        for (int index = 0; index < count; index++) keys[index] = 0.9 * enterTime * keys[index] / last;
    }

    /** How many lines its paper has been fed at share {@code out} of a leave of {@code leaveTime}: each a quick jerk, a little past and back. */
    static double fed(double out, double leaveTime) {
        double fed = 0;
        for (double from : FEEDS) fed += backOut(clamp((out - from) * leaveTime / FEED_TIME, 0, 1));
        return fed;
    }

    private static double beatOnce(double since) { return since <= 0 ? 0 : 1.45 * (1 - Math.exp(-since / 0.03)) * Math.exp(-since / 0.16); }

    private static double lubDub(double since, double strength) { return strength * (beatOnce(since) + 0.6 * beatOnce(since - 0.2)); }

    private static double nextBeat(double at, double calmBy) { return at + 0.55 + 0.55 * PULSE_CALM * clamp(at / calmBy, 0, 1); }

    /**
     * How strongly a pulsing text's heart beats {@code secs} into its group's clock, 0 to about 1: from about 110 beats a minute,
     * slowing to about 55 and weaker beat by beat by {@code leaveAt} (all fitted a little so that one comes just as it leaves);
     * after it, one more as calm, a stillness and a last weak one (in a leave of {@code leaveTime}).
     */
    static double heartbeat(double secs, double leaveAt, double leaveTime) {
        double calmBy = Double.isFinite(leaveAt) ? Math.max(leaveAt, 1) : Double.POSITIVE_INFINITY;
        int count = 0;
        double last = 0;
        for (double at = 0.15; count < 64; at = nextBeat(at, calmBy)) {
            count++;
            last = at;
            double next = nextBeat(at, calmBy);
            if (next > leaveAt) { if (next - leaveAt < leaveAt - at) { count++; last = next; } break; }
        }
        double stretch = Double.isFinite(leaveAt) && last > 0 ? leaveAt / last : 1, beat = 0, at = 0.15;
        for (int index = 0; index < count; index++, at = nextBeat(at, calmBy)) {
            double when = at * stretch;
            if (when > secs) break;
            beat = Math.max(beat, lubDub(secs - when, 1 - 0.55 * PULSE_CALM * clamp(when / calmBy, 0, 1)));
        }
        double scale = Math.min(1, leaveTime / PULSE_LEAVE);
        beat = Math.max(beat, lubDub(secs - leaveAt - ONE_MORE * scale, 0.3));
        beat = Math.max(beat, lubDub(secs - leaveAt - LAST_BEAT * scale, 0.2));
        return beat * PULSE_BEAT;
    }

    /** How far a pulsing text has breathed out, 0 to 1, at share {@code out} of a leave of {@code leaveTime}: after its last beat and a stillness. */
    static double exhaled(double out, double leaveTime) {
        double after = EXHALE_AFTER * Math.min(1, leaveTime / PULSE_LEAVE);
        return clamp((out * leaveTime - after) / (leaveTime - after), 0, 1);
    }

    /** What a look measures of its picture once, as the picture is read back. */
    static final class Shape {
        /** Sink: the lowest row its ink reaches, in its picture's pixels from the top. */
        double foot;
        /** Bleed: each drop's place across and down its picture (pixels) and when it lands (seconds), how many, and how far each spreads. */
        final double[] drops = new double[3 * MAX_DROPS];
        int dropCount;
        double reach;
        /** Wash: its strokes' half width, in its picture's pixels (set with its map, away from the main thread). */
        volatile double stroke;
        /**
         * Strike: each letter's span across its picture (from, to, middle, in pixels) and its row's (top and bottom, shares of the
         * picture's height), when it is struck, and how many; its seed.
         */
        double[] glyphs, keys;
        int glyphCount, seed;
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
        /** Its leave's length; when its title leaves, on the group's clock; its title's line height, in pixels; whether it is a title. */
        double leaveTime, titleLeaves, titleLine;
        boolean title;
        /** The impact's strength (1: a title's). */
        double hit;
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
            uPicSize, uBlur, uGrain, uDrain, uTorch, uReveal, uRemain, uLight, uEmber, uSig, uClock, uStatic, uClear, uFogAmt, uNoise, uFogHalf,
            uDry, uDryBy, uStainBy, uWetBy, uSurf, uSwell, uMirror, uLeft, uDeep, uInkBy;
        private final int[] uDrops = new int[MAX_DROPS];
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
            uniform vec4 drops[6]; uniform float dry, dryBy, stainBy, wetBy;
            uniform float surf, swell, mirror, left; uniform vec3 deep;
            uniform vec4 inkBy;
            varying vec2 vUv; varying vec4 vCol; varying vec3 vAux;
            float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
            float vn(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
              return mix(mix(h(i), h(i + vec2(1.0, 0.0)), f.x), mix(h(i + vec2(0.0, 1.0)), h(i + vec2(1.0, 1.0)), f.x), f.y); }
            float fbm(vec2 q) { return 0.5 * vn(q) + 0.3 * vn(q * 2.1 + 3.0) + 0.2 * vn(q * 4.3 + 7.0); }
            vec4 pic(vec2 p) {
              if (p.x < 0.0 || p.y < 0.0 || p.x > 1.0 || p.y > 1.0) return vec4(0.0);
              return texture2D(tex, texRect.xy + p * texRect.zw);
            }
            float inkDry(vec4 m) { return clamp((progress - 0.08 - 0.22 * m.b) / 0.48, 0.0, 1.0); }
            float inkSurf(vec2 uv) {
              vec4 m = texture2D(burnMap, uv);
              float ink = m.r * smoothstep(0.0, 0.06, clock), dried = smoothstep(0.2, 0.62, inkDry(m));
              float wet = ink * (1.0 - dried), R = noiseScale;
              vec2 px = uv * picSize;
              float rip = (vn((px - vec2(clock * R * 1.1, 0.0)) / (R * 1.6)) - 0.5) * 0.18 + 0.05 * sin(px.x / (R * 1.4) - clock * 2.4);
              return wet + 0.3 * ink * dried + inkBy.z * smoothstep(0.01, 0.15, wet) * rip * wet;
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
              if (mode > 16.5) {
                vec2 e = 1.0 / picSize;
                vec4 m = texture2D(burnMap, vUv);
                float R = noiseScale, fib = m.g, lv = inkDry(m), land = smoothstep(0.0, 0.06, clock);
                float dryF = smoothstep(0.2, 0.62, lv), hw = m.r * land * (1.0 - dryF), pg = m.r * land * dryF;
                float liftAt = 0.48 + 0.05 * smoothstep(0.1, 0.8, pg) + 0.16 * (m.a - 0.5) + 0.03 * (0.5 - fib);
                float lift = smoothstep(liftAt - 0.1, liftAt + 0.14, lv);
                float th = (hw + pg * (0.8 + 0.4 * fib)) * (1.0 - 0.45 * smoothstep(0.1, 0.45, lv)) * (1.0 - lift);
                float cover = smoothstep(0.004, 0.03, th), wet = smoothstep(0.01, 0.15, hw);
                vec2 d = e * 1.5;
                float sx = inkSurf(vUv + vec2(d.x, 0.0)) - inkSurf(vUv - vec2(d.x, 0.0));
                float sy = inkSurf(vUv + vec2(0.0, d.y)) - inkSurf(vUv - vec2(0.0, d.y));
                vec3 N = normalize(vec3(-sx * R * 1.1 / 3.0, -sy * R * 1.1 / 3.0, 1.0));
                vec3 L = normalize(vec3(-0.45 + 0.06 * sin(clock * 0.7), -0.62 + 0.05 * cos(clock * 0.5), 0.65));
                vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
                float diff = dot(N, L) - L.z, nh = max(dot(N, H), 0.0);
                float spec = (pow(nh, 80.0) + 0.2 * pow(nh, 14.0)) * inkBy.x * wet, fres = pow(1.0 - N.z, 2.0);
                vec3 ink = burn, wash = burn * 0.55;
                vec3 col = mix(wash, ink, smoothstep(0.05, 0.6, th)) * (0.78 + 0.55 * diff);
                float dried = max(smoothstep(0.08, 0.45, lv), 0.75 * smoothstep(0.0, 0.3, progress));
                col = mix(col, mix(ink, wash, 0.45) * (0.85 + 0.25 * diff), dried);
                col += (vec3(1.0, 0.97, 0.94) * spec + vec3(0.6) * fres * 0.12 * inkBy.x * wet) * (1.0 - dried);
                float a = cover * mix(0.35 + 0.65 * smoothstep(0.02, 0.25, th), smoothstep(0.0, 0.25, th), dried);
                vec4 outc = vec4(col * a, a);
                float so = texture2D(burnMap, vUv - vec2(R * 0.25, R * 0.4) * e).r * land;
                float sh = smoothstep(0.02, 0.4, so) * inkBy.w * 0.5 * (1.0 - smoothstep(0.35, 0.75, lv)) * (1.0 - 0.9 * smoothstep(0.0, 0.3, progress));
                outc.a += sh * (1.0 - outc.a);
                vec2 ge = e * max(1.0, R * 0.2);
                float gx = smoothstep(0.0, 0.3, texture2D(burnMap, vUv + vec2(ge.x, 0.0)).r) - smoothstep(0.0, 0.3, texture2D(burnMap, vUv - vec2(ge.x, 0.0)).r);
                float gy = smoothstep(0.0, 0.3, texture2D(burnMap, vUv + vec2(0.0, ge.y)).r) - smoothstep(0.0, 0.3, texture2D(burnMap, vUv - vec2(0.0, ge.y)).r);
                float g = (-gx * L.x - gy * L.y) * 0.9 * inkBy.y * lift * (1.0 - smoothstep(0.82, 1.0, lv)) * (1.0 - cover);
                outc += vec4(mix(ink, vec3(1.0), 0.35) * max(g, 0.0) * 0.12, max(-g, 0.0) * 0.04);
                gl_FragColor = outc * (1.0 - smoothstep(0.97, 1.0, progress)) * vCol.a;
                return;
              }
              if (mode > 15.5) {
                float sum = 0.0;
                for (int i = 0; i < 24; i++) {
                  float fi = float(i), an = fi * 2.39996, rr = sqrt((fi + 0.5) / 24.0);
                  sum += pic(vUv + vec2(cos(an), sin(an)) * rr * blurR).a;
                }
                gl_FragColor = vCol * (sum / 24.0);
                return;
              }
              if (mode > 14.5) {
                vec2 px = vUv * picSize;
                float xl = (left + px.x) / noiseScale;
                float d = (vUv.y - surf) * picSize.y / noiseScale;
                if (d <= 0.0) { gl_FragColor = pic(vUv) * vCol.a; return; }
                float own = vn(vec2(xl * 1.4, 3.0)), own2 = vn(vec2(xl * 2.3, 11.0));
                float stir = 0.6 + swell;
                float streak = d / 0.02 + 4.0 * own;
                float sway = sin(clock * 11.0 + 6.3 * own - d * 14.0) + 0.5 * sin(clock * 17.0 + 6.3 * own2 - d * 22.0);
                float jitter = sin(streak * 1.7 + clock * 7.8 + 6.3 * own2) + 0.6 * sin(streak * 0.63 - clock * 5.2 + 6.3 * own);
                float shift = (0.026 * sway * (0.5 + d) + 0.01 * jitter) * noiseScale * stir;
                vec2 mv = vec2(vUv.x + shift / picSize.x, 2.0 * surf - vUv.y);
                float r = noiseScale * (0.01 + 0.04 * d) / picSize.x;
                vec4 m = 0.5 * pic(mv) + 0.25 * (pic(mv + vec2(r, 0.0)) + pic(mv - vec2(r, 0.0)));
                float lit = 0.55 + 0.45 * sin(streak * 2.3 - clock * 6.1 + 6.3 * own2);
                float ma = m.a * mirror * 0.4 * exp(-d * 1.6) * lit;
                if (ma <= 0.001) discard;
                vec3 mcol = mix(m.rgb / m.a, deep, 0.25);
                gl_FragColor = vec4(mcol * ma, ma) * vCol.a;
                return;
              }
              if (mode > 13.5) {
                vec2 px = vUv * picSize;
                float n = fbm(px / noiseScale), fine = fbm(px / (noiseScale * 0.35) + 17.0);
                float m = 0.0, front = 0.0, splat = 0.0;
                for (int i = 0; i < 6; i++) {
                  vec4 d = drops[i];
                  if (d.z <= 0.0) continue;
                  float dist = length(px - d.xy);
                  float x = d.z * (0.62 + 0.6 * n + 0.22 * (fine - 0.5)) - dist;
                  float k = smoothstep(0.0, edgeW, x);
                  m = max(m, k);
                  front = max(front, k * (1.0 - smoothstep(edgeW, edgeW * 4.0, x)) * d.w);
                  float rs = noiseScale * 0.65 * (0.8 + 0.4 * fine);
                  splat = max(splat, (1.0 - smoothstep(rs * 0.75, rs, dist)) * d.w);
                }
                vec4 c = pic(vUv);
                float a = c.a;
                vec3 col = a > 0.0 ? c.rgb / a : vec3(0.0);
                col = col * (1.0 + wetBy * front) + vec3(0.25) * wetBy * front * front;
                float dried = smoothstep(0.0, 0.55, dry) * dryBy;
                col = mix(col, col * vec3(0.42, 0.26, 0.24), dried);
                float keep = 1.0 - smoothstep(n - 0.12, n + 0.12, (dry - 0.4) * 2.1);
                vec2 e = min(vUv, 1.0 - vUv) * picSize;
                float stain = max(m * stainBy * smoothstep(0.0, noiseScale * 2.0, min(e.x, e.y)) * (0.55 + 0.45 * n), 0.85 * splat * sign(stainBy)) * (1.0 - a);
                vec3 sc = mix(burn, burn * vec3(0.42, 0.26, 0.24), dried);
                gl_FragColor = (vec4(col * a, a) * m + vec4(sc * stain, stain)) * keep * vCol.a;
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

        /**
         * The page's modes: the picture, burning, a shard of ash, its shape as light, a puff, a gleam, eroding, torch-lit, radio, through
         * mist, mist, a band of light, bled in, sinking into water, a glow around its letters, inked (the page's 13 to 16).
         */
        private static final int PICTURE = 0, BURNING = 1, SHARD = 2, SHAPE = 3, PUFF = 4, GLEAM = 5, ERODING = 8, LIT = 9, SIGNAL = 10,
            MISTED = 11, MIST = 12, BAND = 13, BLEEDING = 14, SINKING = 15, GLOWING = 16, INKED = 17;

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
            uNoise = at(made, "noiseScale"); uFogHalf = at(made, "fogHalf"); uDry = at(made, "dry"); uDryBy = at(made, "dryBy");
            uStainBy = at(made, "stainBy"); uWetBy = at(made, "wetBy"); uSurf = at(made, "surf"); uSwell = at(made, "swell");
            uMirror = at(made, "mirror"); uLeft = at(made, "left"); uDeep = at(made, "deep"); uInkBy = at(made, "inkBy");
            for (int index = 0; index < MAX_DROPS; index++) uDrops[index] = at(made, "drops[" + index + "]");
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
                case BLEED -> bleed(f);
                case SINK -> sink(f);
                case STRIKE -> strike(f);
                case PULSE -> pulse(f);
                case INK -> inked(f);
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
            map(piece, NEAREST);
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

        /** Binds the piece's map (its texture made the first time, its values read through {@code filter}) to the second unit. */
        private void map(Dust.Piece piece, int filter) throws Throwable {
            activeTexture.invokeExact(TEXTURE1);
            if (piece.mapTexture == 0) {
                int made = (int)genTexture.invokeExact();
                bindTexture.invokeExact(TEXTURE_2D, made);
                texParameter.invokeExact(TEXTURE_2D, MIN_FILTER, filter);
                texParameter.invokeExact(TEXTURE_2D, MAG_FILTER, filter);
                texParameter.invokeExact(TEXTURE_2D, WRAP_S, CLAMP_TO_EDGE);
                texParameter.invokeExact(TEXTURE_2D, WRAP_T, CLAMP_TO_EDGE);
                pixelStore.invokeExact(UNPACK_ALIGNMENT, 4);
                texImage.invokeExact(TEXTURE_2D, 0, RGBA, piece.boxWidth, piece.boxHeight, 0, RGBA, UNSIGNED_BYTE, piece.map.duplicate());
                piece.mapTexture = made;
            } else bindTexture.invokeExact(TEXTURE_2D, piece.mapTexture);
            activeTexture.invokeExact(TEXTURE0);
        }

        /**
         * Inked: before it hits, the text; then its ink by its map (laid as it hits, wet and lit as it stays, drying in blotches and
         * lifting as it leaves, its pressed shape left a moment), with its own shadow.
         */
        private void inked(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            Shape shape = piece.shape;
            double s = f.s, cx = f.cx + f.dx, cy = f.cy + f.dy, hw = piece.boxWidth * s * f.sx / 2, hh = piece.boxHeight * s * f.sy / 2;
            float a = (float)f.enterAlpha;
            if (a <= 0.002 || piece.map == null || shape == null) return;
            if (f.secs < IMPACT && f.impact) {
                mode = PICTURE;
                quad(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, a, a, a, a);
                flush();
                return;
            }
            map(piece, LINEAR);
            mode = INKED;
            uniform1f.invokeExact(uProgress, (float)f.out);
            uniform1f.invokeExact(uClock, (float)(f.impact ? f.secs - IMPACT : f.secs));
            uniform1f.invokeExact(uNoise, (float)shape.stroke);
            uniform4f.invokeExact(uInkBy, (float)INK_GLOSS, (float)INK_EMBOSS, (float)INK_RIPPLE, (float)INK_SHADOW);
            uniform3f.invokeExact(uBurn, f.burnRed, f.burnGreen, f.burnBlue);
            quad(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0, 1, 1, a, a, a, a);
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

        /**
         * Bled in: its drops spread over it (they dry and flake it off as it leaves); over a title, each drop falling and its flecks
         * as it hits, and a drop running down from it as it stays.
         */
        private void bleed(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            Shape shape = piece.shape;
            if (shape == null) return;
            double line = f.line, s = f.s, hw = piece.boxWidth * s / 2, hh = piece.boxHeight * s / 2, x0 = f.cx - hw, y0 = f.cy - hh, r0 = 0.3 * line;
            for (int index = 0; index < MAX_DROPS; index++) {
                double since = index < shape.dropCount ? f.secs - shape.drops[index * 3 + 2] : 0;
                if (since <= 0) uniform4f.invokeExact(uDrops[index], 0f, 0f, 0f, 0f);
                else uniform4f.invokeExact(uDrops[index], (float)shape.drops[index * 3], (float)shape.drops[index * 3 + 1],
                    (float)(r0 + (shape.reach - r0) * (1 - Math.exp(-since * BLEED_SOAK))), (float)Math.exp(-since * 1.5));
            }
            mode = BLEEDING;
            uniform1f.invokeExact(uNoise, (float)(line * 0.35));
            uniform1f.invokeExact(uEdge, (float)(line * 0.06));
            uniform1f.invokeExact(uDry, (float)f.out);
            uniform1f.invokeExact(uDryBy, f.title ? 1f : 0.35f);
            uniform1f.invokeExact(uStainBy, f.title ? (float)BLEED_STAIN : 0f);
            uniform1f.invokeExact(uWetBy, (float)BLEED_WET);
            uniform3f.invokeExact(uBurn, f.burnRed, f.burnGreen, f.burnBlue);
            quad(x0, y0, x0 + 2 * hw, y0 + 2 * hh, 0, 0, 1, 1, 1, 1, 1, 1);
            flush();
            if (!f.title) return;
            mode = PUFF;
            double red = f.burnRed, green = f.burnGreen, blue = f.burnBlue;
            for (int index = 0; index < shape.dropCount; index++) {
                double since = f.secs - shape.drops[index * 3 + 2], x = x0 + shape.drops[index * 3] * s, y = y0 + shape.drops[index * 3 + 1] * s;
                // Falling, faster and faster, onto where it lands.
                if (since > -FALL && since <= 0) {
                    double u = 1 + since / FALL;
                    shard(x, y - (1 - u * u) * 1.8 * line, 0.09 * line, 0, 2.2, red * 0.95, green * 0.95, blue * 0.95, 0.95, 0);
                }
                // Flecks thrown out as it hits, mostly sideways and up.
                if (since > 0 && since < SPLASH) {
                    double u = since / SPLASH, a = 0.9 * (1 - u);
                    for (int fleck = 0; fleck < 6; fleck++) {
                        double angle = Math.PI * (1.05 + 0.9 * (fleck + hash(index, fleck, 9)) / 6), far = 0.45 * line * (1 - Math.pow(1 - u, 3)) * (0.5 + 0.5 * hash(index, fleck, 10));
                        shard(x + Math.cos(angle) * far, y + Math.sin(angle) * far * 0.6 + 0.3 * line * u * u, 0.025 * line, 0, 1, red * a, green * a, blue * a, a, 0);
                    }
                }
            }
            // As it stays, a drop runs down from under the first one, slowly, a bead at its end.
            double since = f.secs - (f.enterTime + 0.4);
            if (BLEED_DRIP > 0 && since > 0 && shape.dropCount > 0) {
                double length = 0.7 * line * BLEED_DRIP * smooth(clamp(since / 3.5, 0, 1)), wide = 0.045 * line;
                double a = 0.9 * (1 - smooth(clamp((f.out - 0.4) / 0.6, 0, 1))), dark = (1 - 0.58 * smooth(clamp(f.out / 0.55, 0, 1))) * a;
                double x = x0 + shape.drops[0] * s, top = f.cy + 0.3 * line;
                if (length > 0.5) {
                    shard(x, top + length / 2, wide, 0, length / 2 / wide, red * dark, green * dark, blue * dark, a, 0);
                    shard(x, top + length, 0.075 * line, 0, 1.15, red * dark, green * dark, blue * dark, a, 0);
                }
            }
            flush();
        }

        /**
         * Sinking: as it stays, the text; as it leaves, still water at its foot, its mirror in it swaying; then it sinks into it (drawn
         * from its sunk top down to a line and a half below the water, for the mirror).
         */
        private void sink(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            Shape shape = piece.shape;
            float a = (float)f.alpha;
            if (a <= 0.002 || shape == null) return;
            double s = f.s, w = piece.boxWidth * s, h = piece.boxHeight * s, cx = f.cx + f.dx, cy = f.cy + f.dy;
            if (f.out <= 0) {
                mode = PICTURE;
                quad(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, 0, 0, 1, 1, a, a, a, a);
                flush();
                return;
            }
            double into = f.out * f.leaveTime;
            double water = cy - h / 2 + shape.foot * s, top = cy - h / 2 + SINK_DEPTH * f.line * s * sunk(into, f.leaveTime), bottom = water + 1.5 * f.line * s;
            mode = SINKING;
            uniform1f.invokeExact(uNoise, (float)f.line);
            uniform1f.invokeExact(uLeft, (float)(cx - w / 2));
            uniform1f.invokeExact(uSurf, (float)((water - top) / h));
            uniform1f.invokeExact(uSwell, (float)swell(into));
            uniform1f.invokeExact(uClock, (float)into);
            uniform3f.invokeExact(uDeep, 0.05f, 0.08f, 0.11f);
            uniform1f.invokeExact(uMirror, (float)mirror(into, f.leaveTime));
            quad(cx - w / 2, top, cx + w / 2, bottom, 0, 0, 1, (bottom - top) / h, a, a, a, a);
            flush();
        }

        /**
         * Struck: each letter from its key on, struck a touch big and bright and settling at once, a little off its line, inked a
         * little unevenly; fed up with the paper as it leaves.
         */
        private void strike(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            Shape shape = piece.shape;
            double a = f.alpha;
            if (a <= 0.002 || shape == null || shape.glyphs == null) return;
            double s = f.s, w = piece.boxWidth, h = piece.boxHeight, line = f.line, cx = f.cx + f.dx, cy = f.cy + f.dy;
            double lift = -TYPE_FEED * FEED_STEP * f.titleLine * fed(f.out, f.leaveTime);
            double[] glyphs = shape.glyphs;
            mode = PICTURE;
            for (int index = 0; index < shape.glyphCount; index++) {
                double since = f.secs - shape.keys[index];
                if (since < 0) continue;
                int seed = shape.seed + 101;
                double strike = 1 - clamp(since / 0.09, 0, 1), big = 1 + 0.14 * strike * strike;
                double ink = Math.min(1, 1 - 0.22 * TYPE_INK * hash(index, 1, seed) + 0.25 * strike);
                double jx = (hash(index, 2, seed) - 0.5) * 0.04 * line * s * TYPE_JITTER, jy = (hash(index, 3, seed) - 0.5) * 0.08 * line * s * TYPE_JITTER;
                double from = glyphs[index * 5], to = glyphs[index * 5 + 1], mid = glyphs[index * 5 + 2], v0 = glyphs[index * 5 + 3], v1 = glyphs[index * 5 + 4];
                double gx = cx + (mid - w / 2) * s + jx, gy = cy + ((v0 + v1) / 2 - 0.5) * h * s + jy + lift, half = (v1 - v0) * h * s / 2 * big;
                double shown = a * clamp(since / 0.025, 0, 1);
                quad(gx + (from - mid) * s * big, gy - half, gx + (to - mid) * s * big, gy + half, from / w, v0, to / w, v1,
                    ink * shown, ink * shown, ink * shown, shown);
            }
            flush();
        }

        /**
         * Pulsing: a warm glow under it (a little always, flaring with each beat; as it breathes out, rising a touch and staying on
         * after it, spreading, then dimming away), and the text swelling a touch with each beat.
         */
        private void pulse(Frame f) throws Throwable {
            Dust.Piece piece = f.piece;
            double out = exhaled(f.out, f.leaveTime), a = f.alpha;
            if (a <= 0.002) return;
            double beat = heartbeat(f.group, f.titleLeaves, f.leaveTime), line = f.line;
            double s = f.s * (1 + 0.035 * beat), w = piece.boxWidth * s, h = piece.boxHeight * s, cx = f.cx + f.dx, cy = f.cy + f.dy;
            double after = smooth(clamp(out / 0.5, 0, 1));
            double glow = (f.out > 0 ? 1 : a) * PULSE_GLOW * (0.12 + 0.5 * beat + 0.2 * after) * (1 - smooth(clamp((out - 0.5) / 0.5, 0, 1)));
            double spread = line * s * (0.1 + 0.06 * beat + 0.08 * smooth(out));
            if (glow > 0.002) {
                double pad = 0.6 * line * s;
                mode = GLOWING;
                uniform2f.invokeExact(uBlur, (float)(spread / w), (float)(spread / h));
                quad(cx - w / 2 - pad, cy - h / 2 - pad, cx + w / 2 + pad, cy + h / 2 + pad, -pad / w, -pad / h, 1 + pad / w, 1 + pad / h,
                    glow, 0.82 * glow, 0.58 * glow, 0);
                flush();
            }
            mode = PICTURE;
            float shown = (float)a;
            quad(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, 0, 0, 1, 1, shown, shown, shown, shown);
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
            double k = secs - IMPACT, cx = f.cx + f.dx, cy = f.cy + f.dy, sx = f.s * f.sx, sy = f.s * f.sy, la = f.left * f.hit;
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
            for (int index = 0, puffs = (int)Math.round(PUFFS * f.hit); index < puffs; index++) {
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
