package pzext.api;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.TimeUnit;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL20;
import se.krka.kahlua.vm.KahluaTable;
import zombie.core.SpriteRenderer;
import zombie.core.opengl.GLStateRenderThread;
import zombie.core.opengl.RenderThread;
import zombie.core.textures.Texture;
import zombie.core.textures.TextureFBO;
import zombie.ui.TextManager;
import zombie.ui.UIManager;

/**
 * The looks against the synthetic game: their arithmetic, the same as tools/title-lab's (numbers its own functions give); each title
 * style's picture made as it shows and drawn by the API's shader in the page's modes and order over its enter, hold and leave; the
 * burn's map made away from the main thread and given to the card, and let go with the picture; the game's GL state put back after
 * each draw; the text drawn as it is where the shader does not compile; the frames of a look allocate nothing.
 */
final class LooksTest {
    private static final double SECOND = 1e9;
    private static final long[] NOW = { 9_000_000_000_000L };
    // The program's "mode" uniform, as the synthetic GL records it.
    private static final int MODE = 900;

    private LooksTest() { }

    static void run(KahluaTable text, Object mod) throws Exception {
        arithmetic();
        GameApi.texts().clock = () -> NOW[0];
        GL20.uniforms.put("mode", MODE);
        Looks.Gl before = GameApi.texts().looks;
        GameApi.texts().looks = Looks.Gl.open(LooksTest.class.getClassLoader());
        GL11.ink = (x, y) -> 255;
        try {
            stamp(text, mod);
            discovery(text, mod);
            notice(text, mod);
            unveil(text, mod);
            burn(text, mod);
            bleed(text, mod);
            sink(text, mod);
            type(text, mod);
            pulse(text, mod);
            failing(text, mod);
            cost(text, mod);
            System.out.println("PASS: looks: the arithmetic is the title lab's; each style is drawn by the shader in its modes over its life; the burn's map is made and let go; the game's state is put back; a shader that does not compile leaves the text as it is");
        } finally {
            GL11.ink = null;
            GL20.uniforms.remove("mode");
            GL20.compiles = true;
            TextManager.record = true;
            SpriteRenderer.flush();
            RenderThread.flush();
            GameApi.texts().looks = before;
        }
    }

    // ---- the arithmetic ----

    /** The numbers the page's own functions give (node, tools/title-lab/title-lab.html) for the same inputs. */
    private static void arithmetic() {
        check(Looks.hash(3, 5, 77) == 0.1350277801975608 && Looks.hash(-7, 12, 1) == 0.28860876034013927
            && Looks.hash(100000, -3, 1442695041) == 0.7386068955529481, "The hash is not the page's");
        check(near(Looks.vnoise(1.3, 2.7, 12), 0.24619790692543966) && near(Looks.vnoise(-4.2, 0.5, 99), 0.3808238649461419)
            && near(Looks.vnoise(17.9, 3.01, 0x456789 + 5), 0.685066461467877), "The value noise is not the page's");
        float[] map = Looks.burnMap(20, 9, 2.5, 0x123456789L, Dust.Sweep.DOWNLEFT);
        double sum = 0;
        for (float value : map) sum += value;
        check(near(map[0], 0.4053019881248474) && near(map[57], 0.1239451915025711) && near(map[179], 0.19854091107845306) && Math.abs(sum - 53.17510087043047) < 1e-4,
            "The burn map is not the page's: " + map[0] + ", " + map[57] + ", " + map[179] + ", " + sum);
        double[] torch = new double[7];
        Looks.torch(0.9, torch);
        check(near(torch[0], 0.20805007123956848) && near(torch[1], 0.570861355656489) && near(torch[2], 0.2) && near(torch[3], 0.20805007123956848)
            && near(torch[4], 0.75) && near(torch[5], 1) && near(torch[6], 0), "The torch is not the page's as it sways in");
        Looks.torch(2.5, torch);
        check(near(torch[0], 0.5) && near(torch[1], 0.5) && near(torch[2], 1.5) && near(torch[3], 0.55) && near(torch[4], 1) && near(torch[5], 0.45)
            && near(torch[6], 1), "The torch is not the page's once open");
        check(near(Looks.signal(0.7, 0.4, 0), 0.4411175014355737) && near(Looks.signal(0.7, 3.3, 0), 0.85) && near(Looks.signal(0.7, 9, 0.3), 0.95703125),
            "The radio's signal is not the page's");
        double[] hit = new double[6];
        Looks.impact(0.1, 1, hit);
        check(near(hit[0], 1) && near(hit[1], 1.27421875) && hit[2] == 1 && hit[3] == 1 && hit[4] == 0 && hit[5] == 0, "The impact's fall is not the page's");
        Looks.impact(0.1, Looks.LINE_HIT, hit);
        check(near(hit[1], 1.1508203125), "A line's lighter fall is not the page's");
        Looks.impact(0.3, Looks.LINE_HIT, hit);
        check(near(hit[3], 0.9975975335646583), "A line's lighter hit is not the page's");
        // The ink map of a box 20 by 10 in a picture 40 by 20: its strokes' half width, and a spot's ink, fibre, drying and lifting.
        var inked = new Looks.Shape();
        float[] ink = Looks.inkMap((x, y) -> x >= 10 && x < 30 && y >= 5 && y < 15 ? 255 : 0, 40, 20, 12345, inked);
        int middle = (9 * 40 + 20) * 4, corner = (5 * 40 + 10) * 4, out = (2 * 40 + 2) * 4;
        check(near(inked.stroke, 3.825) && near(ink[middle], 0.6949582099914551) && near(ink[middle + 1], 0.3247954845428467)
            && near(ink[middle + 2], 0.637246310710907) && near(ink[middle + 3], 0.6082073450088501) && near(ink[corner], 0.3029586672782898)
            && ink[out] == 0 && near(ink[out + 1], 0.4476526081562042), "The ink map is not the page's");
        Looks.impact(0.3, 1, hit);
        check(near(hit[1], 1) && near(hit[2], 1.0024960690237317) && near(hit[3], 0.9956318792084696) && near(hit[4] * 90, -0.1393785129067541)
            && near(hit[5], 0.0004320800003443182), "The impact's hit is not the page's");
        // The torch flickers once as the text stays and stutters down to embers; the mist clears and comes back; the text is gone by its end.
        check(Looks.light(3.6, 2.2, 0) < 0.8 && near(Looks.light(3.0, 2.2, 0), 1) && near(Looks.light(9, 2.2, 1), 0.22) && Looks.ember(0.3) == 1 && Looks.ember(1) == 0,
            "The torch's light is wrong");
        check(Looks.clear(3.6, 0, 0) == 0 && Looks.clear(3.6, 3.6, 0) == 1 && Looks.clear(3.6, 9, 0.1) == 1 && Looks.clear(3.6, 9, 1) < 0.1,
            "The mist does not clear and come back");
        check(Looks.mist(3.6, 0, 0) == 0 && near(Looks.mist(3.6, 6, 0), Looks.FOG_STAY) && Looks.mist(3.6, 9, 0.5) > Looks.FOG_STAY && Looks.mist(3.6, 9, 1) == 0,
            "The mist does not come in, stay thin, thicken and go");
        // The heart: racing, calmer as it stays, one more beat after it leaves and a last weak one; the breath out after them.
        double[] beats = { Looks.heartbeat(0.2, 6.9, 10.7), Looks.heartbeat(3.33, 6.9, 10.7), Looks.heartbeat(6.95, 6.9, 10.7),
            Looks.heartbeat(6.9 + Looks.ONE_MORE + 0.08, 6.9, 10.7), Looks.heartbeat(6.9 + Looks.LAST_BEAT + 0.08, 6.9, 10.7), Looks.heartbeat(4.5, 6.9, 10.7) };
        check(near(beats[0], 0.853875022529848) && near(beats[1], 0.27835080378805427) && near(beats[2], 0.3872139141045356) && near(beats[3], 0.24550826504846063)
            && near(beats[4], 0.16367217669897352) && near(beats[5], 0.2714403369081529), "The heartbeat is not the page's: " + java.util.Arrays.toString(beats));
        check(Looks.exhaled(0.3, 10.7) == 0 && near(Looks.exhaled(0.7, 10.7), 0.41636363636363627) && near(Looks.EXHALE_AFTER, 5.2), "The breath out is not the page's");
        check(near(Looks.sunk(5.5, 9), 0.005524271728019903) && near(Looks.sunk(7.2, 9), 0.22434000423464384) && Looks.sunk(9, 9) == 1 && Looks.sunk(4, 9) == 0,
            "The sinking is not the page's");
        check(Looks.sunk(0.25, 0.25) == 1 && Looks.exhaled(1, 0.25) == 1, "A hurried leave does not sink or breathe out in time");
        var shape = new Looks.Shape();
        Looks.drops(shape, 400, 72, 460, 100, 12345, true);
        check(shape.dropCount == 5 && near(shape.reach, 117.68976727954748) && near(shape.drops[0], 316.0899926647544) && near(shape.drops[1], 40.77919132877141)
            && near(shape.drops[2], 0.2) && near(shape.drops[3], 154.55455723404884) && near(shape.drops[14], 1.35) && near(shape.drops[12], 82.77395640313625),
            "The title's drops are not the page's");
        Looks.drops(shape, 300, 30, 330, 45, 99, false);
        check(shape.dropCount == 3 && near(shape.drops[0], 153.76388690434396) && near(shape.drops[4], 23.00425645778887) && near(shape.drops[8], 0.45),
            "The line's drops are not the page's");
        double[] keys = new double[5];
        Looks.keys(new boolean[] { false, false, true, false, false }, 5, 1.3, 4242, keys);
        check(keys[0] == 0 && near(keys[1], 0.25517569873644264) && near(keys[2], 0.8115553633901342) && near(keys[3], 0.9662789374534235) && near(keys[4], 1.17),
            "The typewriter's keys are not the page's: " + java.util.Arrays.toString(keys));
        check(near(Looks.fed(0, 5.5), 0) && near(Looks.fed(0.2, 5.5), 1) && near(Looks.fed(1, 5.5), 3), "The paper is not fed a line at a time");
        // Three letters, the last on a row of its own: the first's ink reaches past its advance (20) to 22, the second's starts at
        // 25; the cut goes to the empty column nearest the gap (23), and none is made across rows.
        int width = 40, height = 10;
        var pixels = java.nio.ByteBuffer.allocateDirect(width * height * 4);
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < width; x++)
                if (x >= 2 && x <= 22 || x >= 25 && x <= 38) pixels.put(((height - 1 - y) * width + x) * 4 + 3, (byte)200);
        double[] glyphs = { 0, 20, 10, 0, 0.5, 20, 40, 30, 0, 0.5, 0, 40, 20, 0.5, 1 };
        Looks.cuts(pixels, width, height, glyphs, 3, 8);
        check(glyphs[1] == 23 && glyphs[5] == 23 && glyphs[6] == 40 && glyphs[10] == 0, "The struck letters are not cut at the empty column: "
            + java.util.Arrays.toString(glyphs));
    }

    // ---- the styles ----

    /** The stamp: its picture as it falls; it hits inked (heat, streak, dust), its line struck after it; a gleam as they stay; it dries away, its line weathers. */
    private static void stamp(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "stamp", "Quest complete", "The well is clean");
        up(origin, 0);
        quiet();
        check(modes(origin, 0.1).equals(List.of(0)), "The stamp is not its picture as it falls: " + modes(origin, 0.11));
        up(origin, 0.2);
        quiet();
        var drawn = modes(origin, 0.4);
        check(drawn.equals(List.of(17, 3, 13, 4, 0, 3, 13, 4)), "The stamp's hit is not its ink, heat, streak and dust, its line struck after it: " + drawn);
        up(origin, 3.0);
        drawn = modes(origin, 3.1);
        check(drawn.equals(List.of(17, 5, 0, 5)), "The stamp does not gleam as it stays, over it and its line: " + drawn);
        // The picture's middle is the title's place (x the screen's middle, y 0.16 of 900).
        float[] picture = GL11.arrays.get(0);
        check(Math.abs((picture[2] + picture[6]) / 2 - 800) < 1.5 && Math.abs((picture[3] + picture[7]) / 2 - 144) < 1.5,
            "The stamp's picture is not at its place: " + (picture[2] + picture[6]) / 2 + ", " + (picture[3] + picture[7]) / 2);
        state();
        check(modes(origin, 8.6).equals(List.of(17, 8)), "The stamp does not dry away and its line weather away: " + modes(origin, 8.61));
        gone(origin, 12.2, key, text, mod);
    }

    /** The torch: its light thrown behind the title and the title lit; the line lit by it all over; both as it dies down. */
    private static void discovery(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "discovery", "Search complete", "3 items");
        up(origin, 0);
        check(modes(origin, 1.0).equals(List.of(4, 9)), "The torch does not light the title as it sways in: " + modes(origin, 1.01));
        up(origin, 3.0);
        check(modes(origin, 3.1).equals(List.of(4, 9, 9)), "The torch does not light the title and its line: " + modes(origin, 3.11));
        check(modes(origin, 9.2).equals(List.of(4, 9, 9)), "The torch does not die down over the title and its line: " + modes(origin, 9.21));
        gone(origin, 12.0, key, text, mod);
    }

    /** The radio: the title and its line as a signal, over their life. */
    private static void notice(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "notice", "Supply drop", "North of the river");
        up(origin, 0);
        up(origin, 0.3);
        check(modes(origin, 0.5).equals(List.of(10, 10)), "The notice is not a signal: " + modes(origin, 0.51));
        check(modes(origin, 8.0).equals(List.of(10, 10)), "The notice is not lost as a signal: " + modes(origin, 8.01));
        gone(origin, 10.7, key, text, mod);
    }

    /** The mist: behind each text, then the text through it. */
    private static void unveil(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "unveil", "A new path", "The bridge is open");
        up(origin, 0);
        up(origin, 1.3);
        check(modes(origin, 2.0).equals(List.of(12, 11, 12, 11)), "The mist is not behind the title and its line: " + modes(origin, 2.01));
        gone(origin, 14.6, key, text, mod);
    }

    /** The burn (the default style): its picture while it stays; then the text burning by its map and its ash; the map made, and let go with it. */
    private static void burn(KahluaTable text, Object mod) throws Exception {
        long origin = NOW[0];
        int textures = GL11.made;
        double key = title(text, mod, null, "Quiet title", "A line under it");
        up(origin, 0);
        up(origin, 0.4);
        quiet();
        check(modes(origin, 3.0).equals(List.of(0, 0)), "The burning title is not its picture as it stays: " + modes(origin, 3.01));
        check(GL11.made == textures, "A burn map went to the card before the leave");
        var drawn = modes(origin, 11.2);
        check(drawn.equals(List.of(1, 2, 1, 2)), "The title and its line do not burn with their ash: " + drawn);
        check(GL11.made == textures + 2 && GL11.width > 200 && GL11.height > 50, "The burn maps (the line's last) did not go to the card: " + GL11.width + " by " + GL11.height);
        int maps = GL11.made;
        at(origin, 17.2);
        frame();
        frame();
        check(!(Boolean)FormulasTest.call(text, "shown", mod, key).get(0) && GL11.deleted.contains(maps) && GL11.deleted.contains(maps - 1),
            "The burn maps were not let go with the text");
    }

    /** The bleed: drops on the title (falling, their flecks, a drop running down), the line seeping in; both dry and flake away. */
    private static void bleed(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "bleed", "Infected", "The test is positive");
        up(origin, 0);
        check(modes(origin, 1.0).equals(List.of(14, 4)), "The drops do not fall on the title and spread: " + modes(origin, 1.01));
        up(origin, 1.3);
        check(modes(origin, 3.0).equals(List.of(14, 4, 14)), "The title does not drip as it stays, its line seeped in: " + modes(origin, 3.01));
        check(modes(origin, 10.0).equals(List.of(14, 4, 14)), "The title and its line do not dry: " + modes(origin, 10.01));
        gone(origin, 13.8, key, text, mod);
    }

    /** The sink: its picture as it stays; the title and its line sinking into their water as they leave. */
    private static void sink(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "sink", "Lost", "The supplies went down");
        up(origin, 0);
        up(origin, 0.8);
        check(modes(origin, 3.0).equals(List.of(0, 0)), "The sinking title is not its picture as it stays: " + modes(origin, 3.01));
        check(modes(origin, 9.0).equals(List.of(15, 15)), "The title and its line do not sink: " + modes(origin, 9.01));
        Looks.Shape shape = shapeOf("Lost");
        check(shape != null && shape.foot > 0, "The sinking title's foot was not found");
        gone(origin, 16.5, key, text, mod);
    }

    /** The typewriter: the title's letters struck, its line's after; both fed up as they leave. */
    private static void type(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "type", "New orders", "Read them now");
        up(origin, 0);
        Looks.Shape shape = shapeOf("New orders");
        check(shape != null && shape.glyphCount == 9 && shape.keys[0] == 0 && shape.keys[8] < 1.3 && shape.keys[3] - shape.keys[2] > shape.keys[2] - shape.keys[1],
            "The title's letters are not struck in turn");
        check(modes(origin, 0.6).equals(List.of(0)), "The title is not struck: " + modes(origin, 0.61));
        up(origin, 1.5);
        check(modes(origin, 9.0).equals(List.of(0, 0)), "The title and its line are not fed up: " + modes(origin, 9.01));
        gone(origin, 13.9, key, text, mod);
    }

    /** The pulse: a glow and the text, the title's and its line's, beating and breathing out. */
    private static void pulse(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "pulse", "Safe", "The fever broke");
        up(origin, 0);
        up(origin, 0.6);
        check(modes(origin, 2.0).equals(List.of(16, 0, 16, 0)), "The title and its line do not glow: " + modes(origin, 2.01));
        check(modes(origin, 13.0).equals(List.of(16, 0, 16, 0)), "The title and its line do not breathe out: " + modes(origin, 13.01));
        gone(origin, 17.5, key, text, mod);
    }

    /** A shader that does not compile: the looks stop, and the text is drawn as it is. */
    private static void failing(KahluaTable text, Object mod) {
        Looks.Gl working = GameApi.texts().looks;
        GL20.compiles = false;
        GameApi.texts().looks = Looks.Gl.open(LooksTest.class.getClassLoader());
        try {
            long origin = NOW[0];
            double key = title(text, mod, "notice", "Broken", null);
            up(origin, 0);
            up(origin, 0.3);
            check(GameApi.texts().looks.failed, "The looks did not stop where the shader does not compile");
            at(origin, 0.5);
            GL11.arrays.clear();
            frame();
            check(last("Broken") != null && GL11.arrays.isEmpty(), "The text is not drawn as it is without the shader");
            FormulasTest.call(text, "hide", mod, key, true);
            frame();
        } finally {
            GL20.compiles = true;
            GameApi.texts().looks = working;
        }
    }

    /** The frames of a look allocate nothing on the main thread. */
    private static void cost(KahluaTable text, Object mod) {
        long origin = NOW[0];
        double key = title(text, mod, "discovery", "Search complete", "3 items");
        up(origin, 0);
        up(origin, 1.6);
        at(origin, 4.0);
        frame();
        check(!GL11.arrays.isEmpty(), "The torch is not drawn");
        TextManager.record = false;
        long[] time = new long[1];
        int frames = 20_000;
        long bytes;
        try {
            bytes = Allocations.median(5, () -> {
                long clock = System.nanoTime();
                for (int frame = 0; frame < frames; frame++) {
                    UIManager.render();
                    SpriteRenderer.queued.clear();
                }
                time[0] = System.nanoTime() - clock;
            });
        } finally { TextManager.record = true; }
        System.out.printf("text: a lit title with its line costs %.1f us a frame to place, allocating %d bytes over %d frames%n",
            time[0] / (double)frames / 1000, bytes, frames);
        check(bytes < 4096, "A look's frames allocated " + bytes + " bytes");
        FormulasTest.call(text, "hide", mod, key, true);
        frame();
    }

    // ---- helpers ----

    private static double title(KahluaTable text, Object mod, String style, String words, String line) {
        KahluaTable spec = line == null ? table("text", words) : table("text", words, "subtitle", line);
        if (style != null) spec.rawset("style", style);
        return (Double)FormulasTest.call(text, "title", mod, spec).get(0);
    }

    /** Frames from {@code seconds} on, until the pictures of the texts showing are made and drawn into. */
    private static void up(long origin, double seconds) {
        for (int step = 0; step < 4; step++) { at(origin, seconds + 0.02 * step); frame(); }
    }

    /** Waits for the work done away from the main thread (a burn's cells and map), and a frame after. */
    private static void quiet() {
        ForkJoinPool.commonPool().awaitQuiescence(10, TimeUnit.SECONDS);
        frame();
    }

    /** The modes drawn in a frame at {@code seconds}, in their order. */
    private static List<Integer> modes(long origin, double seconds) {
        at(origin, seconds);
        GL11.arrays.clear();
        frame();
        var modes = new ArrayList<Integer>();
        for (float[] drawn : GL11.arrays) modes.add((int)drawn[0]);
        return modes;
    }

    /** The game's state is put back after a look's draw. */
    private static void state() {
        check(GL11.pushed == 0 && GL20.current == 0 && Texture.lastTextureID == -1 && SpriteRenderer.ringBuffer.restoreVbos && GLStateRenderThread.restores > 0,
            "The game's GL state was not put back");
    }

    /** The title gone at {@code seconds}, its pictures let go. */
    private static void gone(long origin, double seconds, double key, KahluaTable text, Object mod) {
        int destroyed = TextureFBO.destroyed;
        at(origin, seconds);
        frame();
        frame();
        check(!(Boolean)FormulasTest.call(text, "shown", mod, key).get(0) && TextureFBO.destroyed > destroyed, "The title outlived its leave, or its pictures stayed");
        NOW[0] += Math.round(SECOND);
        frame();
    }

    private static void at(long origin, double seconds) { NOW[0] = origin + Math.round(seconds * SECOND); }

    /** A whole frame: the interface drawn, then the render thread's turn and the render queue run. */
    private static void frame() {
        TextManager.calls.clear();
        UIManager.render();
        RenderThread.flush();
        SpriteRenderer.flush();
    }

    /** What the look of the text showing these words measured of its picture on the first screen. */
    private static Looks.Shape shapeOf(String words) {
        for (Texts.Shown shown : GameApi.texts().shown)
            if (shown.lines[0].equals(words) && shown.pieces != null && shown.pieces[0] != null) return shown.pieces[0].shape;
        return null;
    }

    private static Object[] last(String words) {
        Object[] found = null;
        for (Object[] call : TextManager.calls) if ("text".equals(call[0]) && words.equals(call[5])) found = call;
        return found;
    }

    private static boolean near(double value, double expected) { return Math.abs(value - expected) < 1e-6; }

    private static KahluaTable table(Object... pairs) {
        var result = zombie.Lua.LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
