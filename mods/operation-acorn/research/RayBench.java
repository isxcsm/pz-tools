// Benchmarks the hidden-zombie ray test outside the game: zombies on a walled tile map, a player, and several ways to pick
// and trace candidates each frame. Also times a Kahlua call per zombie (the Lua OnZombieUpdate approach).
// java -cp projectzomboid.jar RayBench.java
import java.util.*;

public class RayBench {
    static final int W = 128, H = 128, FLOORS = 4, CH = 8;              // loaded area 16x16 chunks of 8x8, floors 0..3
    static final byte WALL_N = 1, WALL_W = 2, SOLID = 4;
    static byte[][] tiles = new byte[FLOORS][W * H];
    static float VIEW = 40f, HALF_CONE = (float) Math.toRadians(72);  // 144 deg cone, 40 tile view distance (generous)

    static int n; static boolean horde;
    static float[] zx, zy; static int[] zz; static boolean[] drawn;
    static int[] cacheKey; static boolean[] cacheClear;
    static int[][] bucket; static int[] bucketLen; static int[] zChunk;
    static float px = 64.5f, py = 64.5f; static int pz = 1; static float dirX = 1, dirY = 0;
    static long rays;

    public static void main(String[] a) throws Exception {
        Random r = new Random(42);
        for (int f = 0; f < FLOORS; f++)
            for (int i = 0; i < W * H; i++) {
                byte b = 0;
                if (r.nextFloat() < 0.15f) b |= WALL_N;
                if (r.nextFloat() < 0.15f) b |= WALL_W;
                if (r.nextFloat() < 0.05f) b |= SOLID;
                tiles[f][i] = b;
            }
        for (boolean h : new boolean[]{false, true})
        for (int count : new int[]{1000, 3000, 10000}) {
            horde = h;
            System.out.printf("%n=== %d zombies, %s ===%n", count, h ? "all within 35 tiles of the player" : "spread over 128x128 tiles");
            run("chunks + filter + ray + cache", count, 0);
            run("chunks + filter + ray, no cache", count, 1);
            run("flat list + filter + ray + cache", count, 2);
            run("quadtree rebuilt per frame + cache", count, 3);
            kahlua(count);
        }
    }

    static void setup(int count) {
        Random r = new Random(7);
        n = count; zx = new float[n]; zy = new float[n]; zz = new int[n]; drawn = new boolean[n];
        cacheKey = new int[n]; cacheClear = new boolean[n]; zChunk = new int[n];
        Arrays.fill(cacheKey, -1);
        int chunks = (W / CH) * (H / CH);
        bucket = new int[chunks][16]; bucketLen = new int[chunks];
        for (int i = 0; i < n; i++) {
            if (horde) { double a = r.nextDouble() * 2 * Math.PI, d = Math.sqrt(r.nextDouble()) * 35;
                zx[i] = (float) (64.5 + Math.cos(a) * d); zy[i] = (float) (64.5 + Math.sin(a) * d); }
            else { zx[i] = r.nextFloat() * W; zy[i] = r.nextFloat() * H; } zz[i] = r.nextInt(FLOORS);
            drawn[i] = r.nextFloat() < 0.6f;
            zChunk[i] = chunkOf(zx[i], zy[i]); add(zChunk[i], i);
        }
    }
    static int chunkOf(float x, float y) { return ((int) y / CH) * (W / CH) + ((int) x / CH); }
    static void add(int c, int i) {
        if (bucketLen[c] == bucket[c].length) bucket[c] = Arrays.copyOf(bucket[c], bucket[c].length * 2);
        bucket[c][bucketLen[c]++] = i;
    }
    static void remove(int c, int i) {
        int[] b = bucket[c];
        for (int k = 0; k < bucketLen[c]; k++) if (b[k] == i) { b[k] = b[--bucketLen[c]]; return; }
    }

    static void moveWorld(Random r, int frame) {
        // zombies shuffle (~0.03 tiles/frame), the player walks and turns now and then; buckets kept like vanilla's chunk lists
        for (int i = 0; i < n; i++) {
            if (r.nextFloat() < 0.5f) {
                zx[i] = Math.max(0, Math.min(W - 0.01f, zx[i] + (r.nextFloat() - 0.5f) * 0.06f));
                zy[i] = Math.max(0, Math.min(H - 0.01f, zy[i] + (r.nextFloat() - 0.5f) * 0.06f));
                int c = chunkOf(zx[i], zy[i]);
                if (c != zChunk[i]) { remove(zChunk[i], i); add(c, i); zChunk[i] = c; }
            }
            if (r.nextFloat() < 0.002f) drawn[i] = !drawn[i];
        }
        px = 64.5f + (float) Math.sin(frame * 0.002) * 20f; py = 64.5f + (float) Math.cos(frame * 0.0017) * 20f;
        double ang = frame * 0.01; dirX = (float) Math.cos(ang); dirY = (float) Math.sin(ang);
    }

    static boolean candidate(int i) {
        if (drawn[i]) return false;
        int dz = zz[i] - pz; if (dz > 1 || dz < -1) return false;
        float dx = zx[i] - px, dy = zy[i] - py, d2 = dx * dx + dy * dy;
        if (d2 > VIEW * VIEW) return false;
        float dot = dx * dirX + dy * dirY;                              // inside the cone: angle to facing <= half cone
        return dot > 0 && dot * dot >= d2 * (float) (Math.cos(HALF_CONE) * Math.cos(HALF_CONE));
    }

    static boolean test(int i, boolean useCache) {
        int key = (((int) zx[i]) * 1000 + (int) zy[i]) * 8 + zz[i];
        int pkey = ((int) px * 1000 + (int) py);
        key = key * 31 + pkey;
        if (useCache && cacheKey[i] == key) return cacheClear[i];
        boolean clear = ray(px, py, zx[i], zy[i], zz[i] == pz ? pz : pz)
                && (zz[i] == pz || ray(px, py, zx[i], zy[i], zz[i]));   // other floor: trace both floors (cost stand-in)
        cacheKey[i] = key; cacheClear[i] = clear;
        return clear;
    }

    // DDA through tiles; blocked by a solid tile before the target or a wall on the crossed edge
    static boolean ray(float x0, float y0, float x1, float y1, int f) {
        rays++;
        byte[] t = tiles[f];
        int x = (int) x0, y = (int) y0, tx = (int) x1, ty = (int) y1;
        float dx = x1 - x0, dy = y1 - y0;
        int sx = dx > 0 ? 1 : -1, sy = dy > 0 ? 1 : -1;
        float tdx = dx != 0 ? Math.abs(1 / dx) : Float.MAX_VALUE, tdy = dy != 0 ? Math.abs(1 / dy) : Float.MAX_VALUE;
        float tmx = dx != 0 ? ((sx > 0 ? x + 1 - x0 : x0 - x) * tdx) : Float.MAX_VALUE;
        float tmy = dy != 0 ? ((sy > 0 ? y + 1 - y0 : y0 - y) * tdy) : Float.MAX_VALUE;
        while (x != tx || y != ty) {
            if (tmx < tmy) {
                int edge = sx > 0 ? (x + 1) : x;                          // west wall of the tile east of the edge
                if (edge >= 0 && edge < W && (t[y * W + edge] & WALL_W) != 0) return false;
                x += sx; tmx += tdx;
            } else {
                int edge = sy > 0 ? (y + 1) : y;
                if (edge >= 0 && edge < H && (t[edge * W + x] & WALL_N) != 0) return false;
                y += sy; tmy += tdy;
            }
            if (x < 0 || y < 0 || x >= W || y >= H) return false;
            if ((x != tx || y != ty) && (t[y * W + x] & SOLID) != 0) return false;
        }
        return true;
    }

    static int frameWork(int mode) {
        int revealed = 0;
        if (mode == 2) {
            for (int i = 0; i < n; i++) if (candidate(i) && test(i, true)) revealed++;
            return revealed;
        }
        if (mode == 3) {
            Quad q = new Quad(0, 0, W, H);
            for (int i = 0; i < n; i++) q.insert(i);
            int[] out = new int[n]; int k = q.query(px - VIEW, py - VIEW, px + VIEW, py + VIEW, out, 0);
            for (int j = 0; j < k; j++) if (candidate(out[j]) && test(out[j], true)) revealed++;
            return revealed;
        }
        int cx0 = Math.max(0, (int) (px - VIEW) / CH), cx1 = Math.min(W / CH - 1, (int) (px + VIEW) / CH);
        int cy0 = Math.max(0, (int) (py - VIEW) / CH), cy1 = Math.min(H / CH - 1, (int) (py + VIEW) / CH);
        for (int cy = cy0; cy <= cy1; cy++)
            for (int cx = cx0; cx <= cx1; cx++) {
                int c = cy * (W / CH) + cx; int[] b = bucket[c];
                for (int k = 0; k < bucketLen[c]; k++) { int i = b[k]; if (candidate(i) && test(i, mode == 0)) revealed++; }
            }
        return revealed;
    }

    static void run(String name, int count, int mode) {
        setup(count);
        Random r = new Random(1);
        int frames = 3000; long[] t = new long[frames]; long sink = 0;
        for (int f = 0; f < 2000; f++) { moveWorld(r, f); sink += frameWork(mode); }      // warm-up (JIT)
        rays = 0;
        for (int f = 0; f < frames; f++) {
            moveWorld(r, f + 2000);
            long s = System.nanoTime(); sink += frameWork(mode); t[f] = System.nanoTime() - s;
        }
        Arrays.sort(t); double mean = Arrays.stream(t).average().orElse(0);
        System.out.printf("%-38s mean %7.3f ms  p99 %7.3f ms  rays/frame %6.1f  (revealed avg %.1f)%n", name,
                mean / 1e6, t[(int) (frames * 0.99)] / 1e6, rays / (double) frames, sink / (double) (frames + 2000));
    }

    static final class Quad {
        final float x0, y0, x1, y1; int[] items = new int[8]; int len; Quad[] kids;
        Quad(float a, float b, float c, float d) { x0 = a; y0 = b; x1 = c; y1 = d; }
        void insert(int i) {
            if (kids != null) { kid(i).insert(i); return; }
            if (len < items.length || x1 - x0 < 1) {
                if (len == items.length) items = Arrays.copyOf(items, len * 2);
                items[len++] = i; return;
            }
            float mx = (x0 + x1) / 2, my = (y0 + y1) / 2;
            kids = new Quad[]{new Quad(x0, y0, mx, my), new Quad(mx, y0, x1, my), new Quad(x0, my, mx, y1), new Quad(mx, my, x1, y1)};
            for (int k = 0; k < len; k++) kid(items[k]).insert(items[k]);
            len = 0; kid(i).insert(i);
        }
        Quad kid(int i) { float mx = (x0 + x1) / 2, my = (y0 + y1) / 2; return kids[(zx[i] < mx ? 0 : 1) + (zy[i] < my ? 0 : 2)]; }
        int query(float a, float b, float c, float d, int[] out, int k) {
            if (c < x0 || a > x1 || d < y0 || b > y1) return k;
            if (kids != null) { for (Quad q : kids) k = q.query(a, b, c, d, out, k); return k; }
            for (int j = 0; j < len; j++) out[k++] = items[j];
            return k;
        }
    }

    // Lua per zombie: what OnZombieUpdate costs before any ray, with the same cheap early-exit checks done in Lua.
    static void kahlua(int count) throws Exception {
        setup(count);
        se.krka.kahlua.vm.Platform p = se.krka.kahlua.j2se.J2SEPlatform.getInstance();
        se.krka.kahlua.vm.KahluaTable env = p.newTable();          // bare table: stdlib.lua is not needed
        se.krka.kahlua.vm.KahluaThread th = new se.krka.kahlua.vm.KahluaThread(p, env);
        th.debugOwnerThread = Thread.currentThread();
        String src = "function onZombieUpdate(drawn, zx, zy, zz, px, py, pz)\n" +
                "  if drawn then return false end\n" +
                "  local dz = zz - pz\n  if dz > 1 or dz < -1 then return false end\n" +
                "  local dx, dy = zx - px, zy - py\n  if dx*dx + dy*dy > 1600 then return false end\n" +
                "  return true\nend\n";
        se.krka.kahlua.vm.LuaClosure c = se.krka.kahlua.luaj.compiler.LuaCompiler.loadstring(src, "bench", env);
        th.pcall(c, new Object[0]);
        Object fn = env.rawget("onZombieUpdate");
        int frames = 300; long[] t = new long[frames];
        Object[] args = new Object[7];
        for (int f = 0; f < 100 + frames; f++) {
            long s = System.nanoTime();
            for (int i = 0; i < n; i++) {
                args[0] = drawn[i]; args[1] = (double) zx[i]; args[2] = (double) zy[i]; args[3] = (double) zz[i];
                args[4] = (double) px; args[5] = (double) py; args[6] = (double) pz;
                th.pcallvoid(fn, args);           // how events reach Lua handlers
            }
            if (f >= 100) t[f - 100] = System.nanoTime() - s;
        }
        Arrays.sort(t); double mean = Arrays.stream(t).average().orElse(0);
        System.out.printf("%-38s mean %7.3f ms  p99 %7.3f ms  (filter only, no ray, no Java object access)%n",
                "Kahlua call per zombie", mean / 1e6, t[(int) (frames * 0.99)] / 1e6);
    }
}
