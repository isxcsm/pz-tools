package pzext.api;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.lwjgl.opengl.GL11;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.core.SpriteRenderer;
import zombie.core.Styles.TransparentStyle;
import zombie.core.Styles.UIFBOStyle;
import zombie.core.opengl.RenderThread;
import zombie.core.textures.Texture;
import zombie.core.textures.TextureFBO;
import zombie.iso.IsoCamera;
import zombie.ui.TextManager;
import zombie.ui.UIFont;
import zombie.ui.UIManager;

/**
 * Dust, the leave effect, against the synthetic game: its schedule (the front, each cell's start, life, drift, size and alpha) and
 * its cells cut from a picture, as pure arithmetic; the {@code "dust"} title style's slow fade in, its hold and its leave; the picture
 * made on the render thread for the text's box, drawn into from the render queue with the interface buffer's blending and read back;
 * the text drawn as strips and cells of that picture, swept from the side asked for, the line under the title a moment after it;
 * the picture let go from the render queue once the text has gone, is hidden, or its box moved; a fade instead without the game's
 * frame buffers, without the dust's drawing, or while the picture is late; wrong fields; the frames of the leave allocate nothing; a
 * newer API takes the dust's fields over and lets the older one's pictures go.
 */
final class DustTest {
    private static final double SECOND = 1e9;
    private static final long[] NOW = { 5_000_000_000_000L };

    private DustTest() { }

    static void run(KahluaTable api, KahluaTable text, Object mod) throws Exception {
        schedule();
        cells();
        useClock();
        try {
            style(text, mod);
            sweepLeft(text, mod);
            fallback(text, mod);
            waiting(text, mod);
            dropped(text, mod);
            moved(text, mod);
            rejects(text, mod);
            cost(text, mod);
            takeover(api, text, mod);
            System.out.println("PASS: dust: the schedule and cells are as computed; a title fades in, holds and crumbles from its picture, its line after it; the picture goes with the text; dust fades where it cannot be made");
        } finally {
            GL11.ink = null;
            TextureFBO.supported = true;
            TextManager.record = true;
            SpriteRenderer.flush();
            RenderThread.flush();
        }
    }

    private static void useClock() { GameApi.texts().clock = () -> NOW[0]; }

    private static void advance(double seconds) { NOW[0] += Math.round(seconds * SECOND); }

    // ---- the schedule ----

    /** The schedule is arithmetic on a seed: bounded, ordered along the sweep, the same twice, whole before a cell starts and gone at its end. */
    private static void schedule() {
        check(Dust.front(0) == 0 && near(Dust.front(Dust.SWEEP / 2), 0.5) && Dust.front(1) == 1, "The front is not where it should be");
        check(near(Dust.cell(108, 1), 4.32) && Dust.cell(30, 1) == Dust.MIN_CELL && near(Dust.cell(76.5, 2), 6.12), "A cell's side is wrong");
        double total = Dust.SWEEP + Dust.JITTER + Dust.LIFE;
        check(near(total, 1), "The sweep, its jitter and a cell's life do not fill the leave: " + total);
        for (long seed : new long[] { 1, 42, -7, 0x5DEECE66DL })
            for (int index = 0; index < 400; index++) {
                double along = (index % 20) / 19.0, across = (index / 20) / 19.0;
                double start = Dust.start(along, across, seed, index), life = Dust.life(seed, index);
                check(start >= 0 && start <= Dust.SWEEP + Dust.JITTER + 1e-12, "A cell starts at " + start);
                check(life >= 0.75 * Dust.LIFE - 1e-12 && life <= Dust.LIFE + 1e-12 && start + life <= 1 + 1e-12, "A cell outlives the leave: " + start + " + " + life);
                check(start == Dust.start(along, across, seed, index), "The schedule is not the same twice");
                // Further along the sweep, later by the sweep's share alone.
                check(near(Dust.start(1, across, seed, index) - Dust.start(0, across, seed, index), Dust.SWEEP), "The start does not follow the sweep");
                double wave = Dust.wave(across, seed);
                check(wave >= 0 && wave <= 1 && Math.abs(Dust.wave(across + 1e-4, seed) - wave) < 1e-2, "The front's wave is not smooth: " + wave);
            }
        check(Dust.start(0.5, 0.5, 1, 3) != Dust.start(0.5, 0.5, 2, 3), "Another seed gives the same schedule");
        // The noise is clumpy: in 0 to 1, near cells alike, far ones not; wearing comes over WEATHER before a start.
        double lowest = 1, highest = 0, step = 0;
        for (int column = 0; column < 60; column++)
            for (int row = 0; row < 20; row++) {
                double here = Dust.grain(column, row, 5);
                lowest = Math.min(lowest, here);
                highest = Math.max(highest, here);
                step = Math.max(step, Math.abs(Dust.grain(column + 1, row, 5) - here));
            }
        check(lowest >= 0 && highest <= 1 && highest - lowest > 0.4 && step < 0.35, "The noise is not clumpy: " + lowest + " to " + highest + ", steps of " + step);
        check(Dust.worn(0.3, 0.5) == 0 && near(Dust.worn(0.5, 0.5), 1) && near(Dust.worn(0.5 - Dust.WEATHER / 2, 0.5), 0.5), "A cell does not wear before it starts");
        check(Dust.caught(Dust.CATCH) == 0 && Dust.caught(1) == 1 && Dust.driftX(Dust.CATCH, 1, 1, 0.3) == 0 && Dust.driftY(Dust.CATCH, 1, 1, 0.3) > 0,
            "A flake does not sag before the wind catches it");
        check(Dust.age(0.3, 0.3, 0.4) == 0 && near(Dust.age(0.7, 0.3, 0.4), 1) && Dust.age(0.1, 0.3, 0.4) < 0, "A cell's age is wrong");
        check(Dust.alpha(-1) == 1 && Dust.alpha(0) == 1 && near(Dust.alpha(Dust.HOLD), 1) && near(Dust.alpha((1 + Dust.HOLD) / 2), 0.5) && Dust.alpha(1) == 0 && Dust.alpha(2) == 0, "A cell's alpha is wrong");
        for (double age = 0; age < 1; age += 0.05) check(Dust.alpha(age + 0.05) <= Dust.alpha(age), "A cell's alpha rises at " + age);
        check(Dust.size(0) == 1 && near(Dust.size(1), 0.45) && Dust.ease(0) == 0 && Dust.ease(1) == 1 && near(Dust.ease(0.5), 0.3125), "A cell's size or ease is wrong");
        // A flake comes loose warm and greys as it goes: no glow in place or past a third of its life, the most at 8%.
        check(Dust.ember(0) == 0 && near(Dust.ember(0.08), 1) && Dust.ember(0.34) == 0 && Dust.ember(0.2) > 0 && Dust.ember(0.2) < 1, "A flake's glow is wrong");
        check(Dust.ash(0) == 1 && near(Dust.ash(0.7), Dust.ASH) && near(Dust.ash(1), Dust.ASH), "A flake does not grey as it goes");
        for (double age = 0; age < 1; age += 0.05) check(Dust.ash(age + 0.05) <= Dust.ash(age) && Dust.ease(age + 0.05) > Dust.ease(age), "A flake brightens or turns back at " + age);
        for (double turns = -2; turns < 2; turns += 0.01)
            check(Math.abs(Dust.wobble(turns) - Math.sin(2 * Math.PI * turns)) < 0.03, "The swirl's wave is not a sine's shape at " + turns);
        check(Dust.wobble(0) == 0 && Dust.wobble(0.25) == 1 && Dust.wobble(0.75) == -1, "The swirl's wave does not reach its peaks");
        for (double phase = 0; phase < 1; phase += 0.1) {
            check(Dust.driftX(0, 1, 1, phase) == 0 && Dust.driftY(0, 1, 1, phase) == 0, "A cell moved before it started");
            check(Dust.driftX(1, 1, 1.2, phase) > 3.5 && Dust.driftX(1, -1, 1.2, phase) < -3.5, "A cell does not go a long way to its side");
            check(Dust.driftY(1, 1, 1.2, phase) < -0.8 && Dust.driftY(1, 0.6, 1.2, phase) < -0.4, "A cell does not rise: " + Dust.driftY(1, 1, 1.2, phase));
        }
    }

    /** Cells of a picture: the ones with ink, by lanes in the sweep's order, the suffix of their starts, larger cells over the most. */
    private static void cells() {
        // A block of ink 80 by 30 in a picture 100 by 40, with cells of 2: columns 5 to 44, rows 2 to 17.
        Dust.Alpha block = (x, y) -> x >= 10 && x < 90 && y >= 5 && y < 35 ? 255 : 0;
        Dust.Cells right = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.RIGHT, 9, Dust.MAX_CELLS);
        check(right.count == 640 && right.lanes == 20 && right.columns == 50 && right.rows == 20 && right.size == 2, "The cells are " + right.count);
        check(right.laneFrom[0] == 0 && right.laneFrom[2] == 0 && right.laneFrom[3] == 40 && right.laneFrom[20] == 640, "The lanes are wrong");
        for (int lane = 2; lane < 18; lane++) {
            int from = right.laneFrom[lane];
            check(right.row[from] == lane && right.column[from] == 5 && right.column[from + 39] == 44, "A lane is not in the sweep's order");
            for (int cell = from; cell < right.laneFrom[lane + 1]; cell++) {
                check(right.side[cell] > 0 && right.rise[cell] >= 0.5 && right.along(cell) == right.column[cell], "A cell to the right goes the other way");
                check(right.flake[cell] >= 0.4 && right.flake[cell] <= 1, "A flake's size is " + right.flake[cell]);
                if (cell + 1 < right.laneFrom[lane + 1]) check(right.suffix[cell] <= right.suffix[cell + 1], "The suffix of the starts is not ordered");
                check(right.suffix[cell] <= right.start[cell], "The suffix is not the earliest");
            }
            check(right.unreached(lane, -1) == from && right.unreached(lane, 2) == right.laneFrom[lane + 1], "A lane's unreached part is wrong");
            int mid = right.unreached(lane, 0.25);
            for (int cell = mid; cell < right.laneFrom[lane + 1]; cell++) check(right.start[cell] > 0.25, "A cell past the unreached point has started");
        }
        var again = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.RIGHT, 9, Dust.MAX_CELLS);
        check(Arrays.equals(right.start, again.start) && Arrays.equals(right.rise, again.rise), "The same picture gives other cells");
        Dust.Cells left = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.LEFT, 9, Dust.MAX_CELLS);
        check(left.column[left.laneFrom[2]] == 44 && left.side[0] < 0 && left.along(left.laneFrom[2]) == 5, "A sweep to the left does not start at the right");
        Dust.Cells up = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.UP, 9, Dust.MAX_CELLS);
        check(up.lanes == 50 && up.row[up.laneFrom[5]] == 17 && up.count == 640, "A sweep up does not go by columns from the bottom");
        Dust.Cells down = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.DOWN, 9, Dust.MAX_CELLS);
        check(down.row[down.laneFrom[5]] == 2, "A sweep down does not start at the top");
        // From the top right corner: rows from the right; the corner first, a row lower later; the flakes go right, back to it.
        Dust.Cells corner = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.DOWNLEFT, 9, Dust.MAX_CELLS);
        int topRight = corner.laneFrom[2], belowIt = corner.laneFrom[17], topLeft = corner.laneFrom[3] - 1;
        check(corner.lanes == 20 && corner.column[topRight] == 44 && corner.row[belowIt] == 17 && corner.column[belowIt] == 44 && corner.column[topLeft] == 5
            && corner.along(topRight) == 5 + 2 && corner.side[topRight] > 0 && corner.side[belowIt] > 0,
            "A sweep from the top right corner does not go by rows from the right, or its flakes do not go back to the corner");
        // Along a row the cells are further from the corner; the top right starts within the sweep's first tenth (and its jitter),
        // the bottom left in its last.
        boolean across = true;
        for (int lane = 2; lane < 18; lane++) across &= corner.along(corner.laneFrom[lane] + 39) > corner.along(corner.laneFrom[lane]);
        int bottomLeft = corner.laneFrom[18] - 1;
        check(across && corner.column[bottomLeft] == 5 && corner.start[topRight] <= 0.1 * Dust.SWEEP + Dust.JITTER + 1e-6
            && corner.start[bottomLeft] >= 0.9 * Dust.SWEEP, "A sweep from the top right corner does not start there");
        // All ink, 300 by 300 at cells of 1: larger cells, at most the most.
        Dust.Cells full = Dust.Cells.of((x, y) -> 255, 300, 300, 1, Dust.Sweep.RIGHT, 1, 1000);
        check(full.count <= 1000 && full.count > 600 && full.size > 9, "A large picture has " + full.count + " cells of " + full.size);
        check(Dust.Cells.of((x, y) -> 0, 50, 50, 2, Dust.Sweep.RIGHT, 1, 100) == null, "A picture without ink has cells");
        check(Dust.Cells.of((x, y) -> Dust.INK - 1, 50, 50, 2, Dust.Sweep.RIGHT, 1, 100) == null, "A faint picture has cells");
    }

    // ---- the title ----

    /**
     * The {@code "dust"} style: fades in over 1.2 s, its picture made, drawn into and read back while it holds, then crumbles
     * from the left over 6 s from strips and cells of that picture; the line under it crumbles 0.3 s later; each picture goes.
     */
    private static void style(KahluaTable text, Object mod) {
        int fbos = TextureFBO.made, destroyed = TextureFBO.destroyed;
        // The ink of each picture read back: its box without a margin of 22 pixels (12 for the line under the title).
        GL11.ink = (x, y) -> x >= 22 && x < 360 && y >= 22 && y < 100 ? 255 : 0;
        // From the left (the style's is from the top right corner), so that the front is a column.
        FormulasTest.call(text, "title", mod, table("text", "Quiet title", "subtitle", "A line under it", "style", "dust", "dustSweep", "right"));
        long origin = NOW[0];
        render();
        check(draws().isEmpty(), "A dust title starts seen");
        at(origin, 0.6);
        render();
        // SdfRegular is 45 high and 18 a character: 8.5% of 900 is 76.5, zoom 1.7, 11 characters 336.6 wide, centred at 0.28.
        drawn(last("Quiet title"), UIFont.SdfRegular, 800 - 336.6 / 2, 252 - 76.5 / 2, 1.7, "Quiet title", 0.97, 0.95, 0.9, 0.5);
        check(RenderThread.queued.isEmpty(), "The picture was made before the title stood still");
        at(origin, 1.2);
        int textures = Texture.made;
        render();
        check(Texture.made == textures + 1 && RenderThread.queued.size() == 1, "The title's picture was not made as it stood still");
        check(near(alpha(last("Quiet title")), 1), "The title did not come on whole");
        RenderThread.flush();
        check(TextureFBO.made == fbos + 1, "The frame buffer was not made on the render thread");
        at(origin, 1.25);
        render();
        var names = names();
        int begin = names.indexOf("generic"), end = names.lastIndexOf("generic");
        check(begin >= 0 && end > begin && call("style")[1] == UIFBOStyle.instance && names.get(end + 1).equals("style")
            && TextManager.calls.get(end + 1)[1] == TransparentStyle.instance, "The capture is not queued in the interface buffer's blending: " + names);
        var captured = new ArrayList<Object[]>();
        for (int index = begin; index < end; index++) if ("text".equals(names.get(index))) captured.add(TextManager.calls.get(index));
        check(captured.size() == 10 && "Quiet title".equals(captured.get(9)[5]) && near((Double)captured.get(9)[9], 1), "The title was not drawn into its picture: " + captured.size());
        check(last("Quiet title") != null && SpriteRenderer.queued.size() == 2, "The title is not drawn as well while its picture is made");
        TextManager.calls.clear();
        SpriteRenderer.flush();
        // The box (382 by 122 at 609, 191) has its top left at the viewport's (0, height): x -609, y 191 + 122 - 900.
        check(Arrays.equals(call("viewport"), new Object[] { "viewport", -609, -587, 1600, 900 }) && call("fbo-start") != null && call("fbo-end") != null
            && GL11.readWidth == 382 && GL11.readHeight == 122 && Arrays.equals(GL11.viewport, new int[] { 0, 0, 1600, 900 }) && !GL11.scissor,
            "The picture was not drawn and read back in its box: " + names());
        at(origin, 1.3);
        frame();
        check(quads().isEmpty() && last("Quiet title") != null, "The title is not itself while it holds");
        // The line under it stands still at 0.35 + 1.2 s: its picture is made, drawn into and cut.
        for (double moment : new double[] { 1.6, 1.65, 1.7 }) { at(origin, moment); frame(); }
        check(TextureFBO.made == fbos + 2 && last("A line under it") != null && quads().isEmpty(), "The line under the title has no picture");
        // 0.01 s into the title's leave (6.2 s): the strips of its picture, as it was.
        at(origin, 6.21);
        render();
        check(last("Quiet title") == null && last("A line under it") != null, "The title did not turn to its picture, or its line went with it");
        var quads = quads();
        Texture picture = (Texture)quads.get(0)[1];
        check(picture.getWidth() == 382 && picture.getHeight() == 122, "The quads are not of the title's picture");
        // The cells the front comes to first already wear (greyer, thinner, in place); the rest is strips.
        int strips = 0, wearing = 0;
        for (Object[] quad : quads) {
            check(quad[1] == picture && (Float)quad[21] > 0.99f, "A quad of the title is not whole as the leave starts");
            boolean worn = (Float)quad[18] < (Float)quad[21] - 1e-4f;
            if (worn) wearing++; else strips++;
            for (int corner = 0; corner < 4; corner++) {
                double x = (Double)quad[2 + 2 * corner], y = (Double)quad[3 + 2 * corner], u = (Double)quad[10 + 2 * corner], v = (Double)quad[11 + 2 * corner];
                check(x >= 609 - 0.01 && x <= 991 + 0.01 && y >= 191 - 0.01 && y <= 313 + 0.01, "A strip is outside the box: " + x + ", " + y);
                check(u >= 0 && u <= picture.getXEnd() + 1e-6 && v >= 0 && v <= picture.getYEnd() + 1e-6, "A strip shows outside the picture: " + u + ", " + v);
                // The picture's rows go up from the box's bottom (a worn cell is drawn thinner about its middle).
                if (!worn) check(near(v, picture.getYEnd() * (313 - y) / 122) && near(u, picture.getXEnd() * (x - 609) / 382), "A strip shows another part of the picture");
            }
        }
        check(strips > 0 && strips < 200 && wearing > 0, "The title before its front is not strips and cells wearing: " + strips + " strips, " + wearing + " wearing");
        // The line under it leaves 0.3 s after the title (at 6.5 s): text at 6.4, its own picture's quads at 6.6.
        at(origin, 6.4);
        frame();
        check(last("A line under it") != null, "The line under the title went with it");
        at(origin, 6.6);
        frame();
        Object line = other(picture);
        check(last("A line under it") == null && line instanceof Texture lineTexture && lineTexture.getWidth() < 382, "The line under the title did not crumble after it");
        // 0.4 of the way (8.6 s): the front past 85% of the box; what has not gone, or only just (still whole), is whole, cells on their way fade and rise.
        at(origin, 6.2 + 0.4 * 6.0);
        frame();
        boolean faded = false, risen = false, warm = false;
        for (Object[] quad : quads()) {
            if (quad[1] != picture) continue;
            float alpha = (Float)quad[21];
            if (alpha > 0.999f) check((Double)quad[2] >= 609 + (0.4 - Dust.HOLD * Dust.LIFE - Dust.JITTER) / Dust.SWEEP * 382 - 5, "A whole part is behind the front: " + quad[2]);
            else {
                faded = true;
                // Premultiplied, the colour at most the alpha; warm (red, then green, then blue) or grey, never another hue.
                float red = (Float)quad[18], green = (Float)quad[19], blue = (Float)quad[20];
                check(red <= alpha + 1e-6f && green <= red + 1e-6f && blue <= green + 1e-6f, "A flake's colour is " + red + ", " + green + ", " + blue + " at " + alpha);
                if (blue < red - 1e-3f) warm = true;
            }
            if ((Double)quad[3] < 213 - 10) risen = true;
        }
        check(faded && risen && warm, "No cell of the title faded, rose or glowed as it went");
        // The title gone (12.2 s), the line not yet (12.5 s); its picture let go from the render queue at the next frame.
        at(origin, 12.21);
        render();
        check(!hasQuads(picture) && !picture.destroyed, "The title outlived its leave, or its picture went before its last frame");
        RenderThread.flush();
        SpriteRenderer.flush();
        at(origin, 12.22);
        render();
        check(names().contains("generic"), "The title's picture was not let go from the render queue");
        SpriteRenderer.flush();
        check(picture.destroyed && TextureFBO.destroyed == destroyed + 1, "The title's picture was not let go");
        at(origin, 12.55);
        frame();
        frame();
        check(quads().isEmpty() && draws().isEmpty() && ((Texture)line).destroyed && TextureFBO.destroyed == destroyed + 2,
            "The line under the title outlived it, or its picture stayed");
        GL11.ink = null;
    }

    /** {@code show} with dust swept from the right, cells twice the size and no drift: what stays whole is on the left; cells stay in place. */
    private static void sweepLeft(KahluaTable text, Object mod) {
        double key = show(text, mod, "text", "Swept", "size", 0.1, "hold", 0.0, "leave", "dust", "leaveTime", 1.0, "dustSweep", "left",
            "dustSize", 2.0, "dustDrift", 0.0);
        GL11.ink = (x, y) -> 255;
        Texture picture = prepare();
        // The box is the picture's size; with no drift, nothing leaves it, and its left side stays whole longest.
        int width = picture.getWidth();
        advance(0.4);
        render();
        var quads = quads();
        boolean faded = false;
        double boxX = Double.POSITIVE_INFINITY;
        for (Object[] quad : quads) boxX = Math.min(boxX, (Double)quad[2]);
        for (Object[] quad : quads) {
            check((Double)quad[4] <= boxX + width + 1e-6, "A cell with no drift left its place");
            float alpha = (Float)quad[21];
            if (alpha > 0.999f) check((Double)quad[4] <= boxX + (1 - (0.4 - Dust.HOLD * Dust.LIFE - Dust.JITTER) / Dust.SWEEP) * width + 8, "A whole part is behind a front from the right");
            else faded = true;
        }
        check(faded, "No cell went");
        FormulasTest.call(text, "hide", mod, key, true);
        render();
        SpriteRenderer.flush();
        check(picture.destroyed, "A hidden text's picture stayed");
        GL11.ink = null;
    }

    /** Without the dust's drawing, dust fades as {@code "fade"} does. */
    private static void fallback(KahluaTable text, Object mod) {
        Texts texts = GameApi.texts();
        Dust.Gl gl = texts.dust;
        texts.dust = null;
        try {
            double key = show(text, mod, "text", "Plain", "hold", 0.0, "leave", "dust", "leaveTime", 1.0);
            render();
            advance(0.5);
            render();
            check(near(alpha(last("Plain")), 0.5) && quads().isEmpty(), "Dust without the game's frame buffers did not fade");
            FormulasTest.call(text, "hide", mod, key, true);
        } finally { texts.dust = gl; }
        // A game whose frame buffers are not supported: a fade too, and nothing made.
        TextureFBO.supported = false;
        int textures = Texture.made;
        double key = show(text, mod, "text", "Unsupported", "hold", 0.0, "leave", "dust", "leaveTime", 1.0);
        render();
        advance(0.5);
        render();
        check(near(alpha(last("Unsupported")), 0.5) && Texture.made == textures && RenderThread.queued.isEmpty(), "Dust without frame buffers did not fade");
        FormulasTest.call(text, "hide", mod, key, true);
        TextureFBO.supported = true;
    }

    /** A picture late from the render thread: the text as it was for 15% of its leave, then a fade; hidden, the picture is never made. */
    private static void waiting(KahluaTable text, Object mod) {
        int fbos = TextureFBO.made;
        double key = show(text, mod, "text", "Late", "hold", 0.0, "leave", "dust", "leaveTime", 1.0);
        render();
        advance(0.1);
        render();
        check(near(alpha(last("Late")), 1), "A text waiting for its picture is not whole");
        advance(0.1);
        render();
        check(near(alpha(last("Late")), 1 - 0.2 * 0.2 * (3 - 2 * 0.2)), "A text whose picture is late did not fade: " + alpha(last("Late")));
        FormulasTest.call(text, "hide", mod, key, true);
        render();
        SpriteRenderer.flush();
        RenderThread.flush();
        check(TextureFBO.made == fbos && RenderThread.queued.isEmpty(), "A frame buffer was made for a text that had gone");
    }

    /** A text hidden, or cleared, as it crumbles: its picture goes from the render queue. */
    private static void dropped(KahluaTable text, Object mod) {
        GL11.ink = (x, y) -> 255;
        for (String how : new String[] { "hide", "clear" }) {
            int destroyed = TextureFBO.destroyed;
            double key = show(text, mod, "text", "Dropped", "hold", 0.0, "leave", "dust", "leaveTime", 2.0);
            Texture picture = prepare();
            advance(0.5);
            render();
            check(hasQuads(picture), "The text is not crumbling");
            if (how.equals("hide")) FormulasTest.call(text, "hide", mod, key, true);
            else FormulasTest.call(mod, "clear");
            render();
            check(!hasQuads(picture) && names().contains("generic"), "A " + how + " left the dust");
            SpriteRenderer.flush();
            check(picture.destroyed && TextureFBO.destroyed == destroyed + 1, "A " + how + " left the picture");
        }
        GL11.ink = null;
    }

    /** The screen's size changed after the picture was made: the text fades, and the picture goes. */
    private static void moved(KahluaTable text, Object mod) {
        GL11.ink = (x, y) -> 255;
        double key = show(text, mod, "text", "Moved", "hold", 1.0, "leave", "dust", "leaveTime", 1.0);
        Texture picture = prepare();
        IsoCamera.width[0] = 1280;
        try {
            render();
            render();
            SpriteRenderer.flush();
            check(picture.destroyed, "The picture of a box that moved stayed");
            advance(1.5);
            render();
            check(quads().isEmpty() && near(alpha(last("Moved")), 0.5), "A text whose box moved did not fade");
        } finally { IsoCamera.width[0] = 1600; }
        FormulasTest.call(text, "hide", mod, key, true);
        GL11.ink = null;
    }

    /** Wrong dust fields are Lua errors; a title takes {@code leave} and the dust's fields of any style. */
    private static void rejects(KahluaTable text, Object mod) {
        rejects(text, "dustSize goes with spec.leave = \"dust\"", "show", mod, table("text", "x", "dustSize", 2.0));
        rejects(text, "spec.dustSweep must be one of \"right\", \"left\", \"up\", \"down\"", "show", mod, table("text", "x", "leave", "dust", "dustSweep", "sideways"));
        rejects(text, "spec.dustSize must be a number from 0.25 to 8", "show", mod, table("text", "x", "leave", "dust", "dustSize", 9.0));
        rejects(text, "spec.dustDrift must be a number from 0 to 4", "show", mod, table("text", "x", "leave", "dust", "dustDrift", -1.0));
        rejects(text, "spec.dustDrift goes with leave = \"dust\"", "title", mod, table("text", "x", "dustDrift", 2.0));
        rejects(text, "spec.dustBurn goes with leave = \"dust\"", "title", mod, table("text", "x", "dustBurn", table("r", 1.0, "g", 0.3, "b", 0.1)));
        rejects(text, "spec.dustBurn must be a table", "show", mod, table("text", "x", "leave", "dust", "dustBurn", "red"));
        rejects(text, "spec.dustBurn must be a table", "show", mod, table("text", "x", "leave", "dust", "dustBurn", table("r", 2.0, "g", 0.3, "b", 0.1)));
        double burning = (Double)FormulasTest.call(text, "title", mod, table("text", "Burning", "style", "dust", "dustBurn", table("r", 0.9, "g", 0.3, "b", 0.1))).get(0);
        check((Boolean)FormulasTest.call(text, "shown", mod, burning).get(0), "A dust title did not take the burn");
        FormulasTest.call(text, "hide", mod, burning, true);
        rejects(text, "spec.leave must be one of", "title", mod, table("text", "x", "leave", "explode"));
        double key = (Double)FormulasTest.call(text, "title", mod, table("text", "Stamped", "style", "stamp", "leave", "dust", "leaveTime", 2.0, "dustSweep", "up")).get(0);
        check((Boolean)FormulasTest.call(text, "shown", mod, key).get(0), "A stamp title did not take the dust");
        FormulasTest.call(text, "hide", mod, key, true);
        render();
        SpriteRenderer.flush();
        RenderThread.flush();
    }

    /** The frames of the leave allocate nothing. */
    private static void cost(KahluaTable text, Object mod) {
        GL11.ink = (x, y) -> x % 3 == 0 ? 255 : 0;
        double key = (Double)FormulasTest.call(text, "title", mod, table("text", "Quiet title", "subtitle", "A line under it", "style", "dust", "hold", 0.0)).get(0);
        render();
        advance(1.2);
        render();
        RenderThread.flush();
        advance(0.02);
        render();
        SpriteRenderer.flush();
        advance(0.02);
        render();
        advance(1.0);
        render();
        int perFrame = quads().size();
        check(perFrame > 100, "The title is not crumbling: " + perFrame);
        TextManager.record = false;
        long[] time = new long[1];
        int frames = 20_000;
        long bytes;
        try {
            bytes = Allocations.median(5, () -> {
                long clock = System.nanoTime();
                for (int frame = 0; frame < frames; frame++) UIManager.render();
                time[0] = System.nanoTime() - clock;
            });
        } finally { TextManager.record = true; }
        System.out.printf("text: a dust title crumbling (%d quads) costs %.1f us a frame to place, allocating %d bytes over %d frames%n",
            perFrame, time[0] / (double)frames / 1000, bytes, frames);
        check(bytes < 4096, "A crumbling title allocated " + bytes + " bytes");
        FormulasTest.call(text, "hide", mod, key, true);
        render();
        SpriteRenderer.flush();
        GL11.ink = null;
    }

    /** A newer API takes the dust's fields over, and lets go the older one's pictures from its own drawing. */
    private static void takeover(KahluaTable api, KahluaTable text, Object mod) throws Exception {
        GL11.ink = (x, y) -> 255;
        show(text, mod, "text", "Kept", "hold", 100.0, "leave", "dust", "leaveTime", 1.0, "dustSweep", "up", "dustSize", 1.5, "dustDrift", 0.5,
            "dustBurn", table("r", 1.0, "g", 0.5, "b", 0.25));
        Texture picture = prepare();
        ClassLoader game = DustTest.class.getClassLoader();
        GameApi.frame(game);
        KahluaTable meta = api.getMetatable();
        String kept = (String)meta.rawget("texts");
        check(kept.contains("\t1.5\tUP\t0.5") && kept.contains("\t1.0,0.5,0.25,1.0"), "The dust's fields are not kept for a newer API: " + kept);
        GameApi.register(LuaManager.class);
        useClock();
        render();
        check(names().contains("generic") && last("Kept") != null, "The newer API did not let the older one's picture go, or does not show the text");
        SpriteRenderer.flush();
        check(picture.destroyed, "The older API's picture stayed");
        FormulasTest.call(mod, "clear");
        render();
        SpriteRenderer.flush();
        RenderThread.flush();
        GL11.ink = null;
    }

    // ---- helpers ----

    /** Shows a text that leaves as dust, and makes, draws into, reads back and cuts its picture: the picture. */
    private static Texture prepare() {
        int textures = Texture.made;
        render();
        check(Texture.made == textures + 1, "No picture was made");
        RenderThread.flush();
        render();
        SpriteRenderer.flush();
        render();
        // The frame buffer last made is the text's.
        return (Texture)TextureFBO.last.getTexture();
    }

    /** The clock at {@code seconds} after {@code origin}. */
    private static void at(long origin, double seconds) { NOW[0] = origin + Math.round(seconds * SECOND); }

    /** The interface drawn, as the main thread does. */
    private static void render() {
        TextManager.calls.clear();
        UIManager.render();
    }

    /** A whole frame: the interface drawn, then the render thread's turn and the render queue run. */
    private static void frame() {
        render();
        RenderThread.flush();
        SpriteRenderer.flush();
    }

    private static double show(KahluaTable text, Object mod, Object... pairs) { return (Double)FormulasTest.call(text, "show", mod, table(pairs)).get(0); }

    private static List<String> names() {
        var names = new ArrayList<String>();
        for (Object[] call : TextManager.calls) names.add((String)call[0]);
        return names;
    }

    private static List<Object[]> draws() {
        var draws = new ArrayList<Object[]>();
        for (Object[] call : TextManager.calls) if ("text".equals(call[0])) draws.add(call);
        return draws;
    }

    private static List<Object[]> quads() {
        var quads = new ArrayList<Object[]>();
        for (Object[] call : TextManager.calls) if ("quad".equals(call[0])) quads.add(call);
        return quads;
    }

    private static boolean hasQuads(Object texture) {
        for (Object[] quad : quads()) if (texture == null ? quad[1] != null : quad[1] == texture) return true;
        return false;
    }

    /** Another picture than this one, as quads drawn show it; null for any. */
    private static Object other(Object picture) {
        for (Object[] quad : quads()) if (quad[1] != picture) return quad[1];
        return new Object();
    }

    private static Object[] last(String words) {
        Object[] found = null;
        for (Object[] call : draws()) if (words.equals(call[5])) found = call;
        return found;
    }

    private static Object[] call(String name) {
        for (Object[] call : TextManager.calls) if (name.equals(call[0])) return call;
        return null;
    }

    private static double alpha(Object[] draw) { return (Double)draw[9]; }

    private static void drawn(Object[] draw, UIFont font, double x, double y, double zoom, String words, double r, double g, double b, double a) {
        check(draw != null && draw[1] == font && near((Double)draw[2], x) && near((Double)draw[3], y) && near((Double)draw[4], zoom) && words.equals(draw[5])
            && near((Double)draw[6], r) && near((Double)draw[7], g) && near((Double)draw[8], b) && near((Double)draw[9], a),
            "Drawn " + Arrays.toString(draw) + ", expected " + font + " at " + x + ", " + y + " zoom " + zoom + " " + words + " " + r + "," + g + "," + b + "," + a);
    }

    private static void rejects(KahluaTable text, String message, String name, Object... arguments) {
        try { FormulasTest.call(text, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.text." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static boolean near(double value, double expected) { return Math.abs(value - expected) < 1e-4; }

    private static KahluaTable table(Object... pairs) {
        var result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
