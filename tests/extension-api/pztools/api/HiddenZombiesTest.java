package pztools.api;

import java.util.Arrays;
import java.util.List;
import java.util.Random;
import se.krka.kahlua.vm.KahluaTable;
import pztools.bridge.ApiHooks;
import zombie.GameTime;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.iso.IsoCell;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoWorld;
import zombie.iso.LightingJNI;
import zombie.iso.LosUtil;

/**
 * {@code vision.hiddenZombieFix} against the synthetic game: which zombies it shows (the ones the game does not draw, on the
 * player's floor or next to it, in the view distance and the cone, with nothing blocking the line and the game's light test passed),
 * how often it looks, that it
 * does nothing unless declared, and what it costs for thousands of zombies.
 */
final class HiddenZombiesTest {
    private static final ClassLoader GAME = HiddenZombiesTest.class.getClassLoader();
    private static final long FRAME = 16_700_000L;
    private static long now = 1_000_000_000L;

    private HiddenZombiesTest() { }

    static void run(KahluaTable api) throws Exception {
        KahluaTable formulas = (KahluaTable)api.rawget("formulas");
        IsoCell home = IsoWorld.instance.cell;
        float viewed = GameTime.instance.viewDist;
        HiddenZombies.clock = () -> now;
        try {
            var cell = new IsoCell();
            IsoWorld.instance.cell = cell;
            for (int x = 0; x < 64; x++) for (int y = 0; y < 64; y++) for (int z = 0; z < 3; z++) cell.load(x, y, z);
            var player = new IsoPlayer();
            player.x = 10.5f; player.y = 10.5f; player.z = 0f;
            IsoPlayer.players[0] = player;
            GameTime.instance.viewDist = 30f;
            LightingJNI.setCone(144f);
            frames(1);
            Object mod = FormulasTest.call(api, "client", "hidden.mod").get(0), second = FormulasTest.call(api, "client", "hidden.second").get(0);
            filters(formulas, mod, cell, player);
            light(formulas, mod, cell, player);
            cadence(formulas, mod, cell, player);
            declarations(api, formulas, mod, second, cell, player);
            states(formulas, mod, cell, player);
            splitScreen(formulas, mod, cell, player);
            FormulasTest.call(mod, "clear");
            cost(formulas, mod);
            fault(api, formulas);
            IsoPlayer.players[0] = null;
            IsoPlayer.players[1] = null;
            frames(1);
        } finally {
            HiddenZombies.clock = System::nanoTime;
            GameTime.instance.viewDist = viewed;
            IsoWorld.instance.cell = home;
            IsoPlayer.players[0] = null;
            IsoPlayer.players[1] = null;
        }
    }

    /** Which zombies are shown, one frame after they are first looked at. */
    private static void filters(KahluaTable formulas, Object mod, IsoCell cell, IsoPlayer player) {
        var points = (KahluaTable)FormulasTest.call(formulas, "points").get(0);
        check(ApiHooks.APPLIED.equals(points.rawget("vision.hiddenZombieFix")),
            "The fix is " + points.rawget("vision.hiddenZombieFix"));
        // A wall on the west edge of the squares x = 13, y = 11 to 13; an opening in the floor above one square, and above the next floor.
        for (int y = 11; y <= 13; y++) cell.getGridSquare(13, y, 0).westWall = true;
        cell.getGridSquare(15, 10, 1).openFloor = true;
        cell.getGridSquare(15, 10, 2).openFloor = true;
        var near = place(cell, 15.5f, 10.5f, 0);
        var aside = place(cell, 15.5f, 19.16f, 0);
        var edge = place(cell, 39.5f, 10.5f, 0);
        var above = place(cell, 15.5f, 10.5f, 1);
        var walled = place(cell, 16.5f, 12.5f, 0);
        var wide = place(cell, 11.5f, 20.45f, 0);
        var behind = place(cell, 5.5f, 10.5f, 0);
        var far = place(cell, 41.5f, 10.5f, 0);
        var closed = place(cell, 15.5f, 8.5f, 1);
        var twoFloors = place(cell, 15.5f, 10.5f, 2);
        var drawn = place(cell, 15.5f, 9.5f, 0);
        drawn.isVisibleToPlayer[0] = true;
        // Nothing is looked at before a mod declares the fix.
        int tests = IsoGridSquare.visionTests, lines = LosUtil.lines;
        frames(5);
        check(IsoGridSquare.visionTests == tests && LosUtil.lines == lines && player.spotted.isEmpty() && near.alphaSets == 0,
            "The fix ran without a declaration");
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        frames(1);
        for (var shown : List.of(near, aside, edge, above))
            check(shown.targetAlpha[0] == 1f && shown.alphaSets == 1, "A zombie in sight was not shown on the first frame: " + describe(shown));
        for (var hidden : List.of(walled, wide, behind, far, closed, twoFloors, drawn))
            check(hidden.targetAlpha[0] == 0f && hidden.alphaSets == 0, "A zombie that should stay as the game has it was changed: " + describe(hidden));
        check(player.spotted.size() == 4 && player.spotted.containsAll(List.of(near, aside, edge, above)),
            "The zombies shown were not offered to the player's spotting: " + player.spotted.size());
        FormulasTest.call(mod, "clear");
        cell.zombieList.clear();
        player.spotted.clear();
        frames(1);
    }

    /**
     * What the game goes on to ask of a zombie it finds in sight (the rest of {@code TestIfSeen}) is still asked: the light of the
     * zombie's square, the player's own square when the zombie is within the detection range, the distance of 1 and the view distance.
     */
    private static void light(KahluaTable formulas, Object mod, IsoCell cell, IsoPlayer player) {
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        var ours = cell.getGridSquare(10, 10, 0);
        player.square = ours;
        // In a lit square (the square grid of the game is not what is asked) the zombie is shown; in a square the game's light test
        // finds too dark it is not, and the same zombie is shown when the square is a little lighter.
        var lit = place(cell, 20.5f, 10.5f, 0);
        var dark = place(cell, 22.5f, 10.5f, 0);
        var darker = place(cell, 24.5f, 10.5f, 0);
        cell.getGridSquare(22, 10, 0).setLight(0, 0.0001f);
        cell.getGridSquare(24, 10, 0).setLight(0, 0.01f);
        frames(1);
        check(lit.alphaSets == 1, "A zombie in a lit square was not shown: " + describe(lit));
        check(dark.alphaSets == 0 && dark.targetAlpha[0] == 0f, "A zombie in a square too dark for the game's light test was shown: " + describe(dark));
        check(darker.alphaSets == 1, "A zombie in a dim square the game still sees was not shown: " + describe(darker));
        // The light of a square going out hides a shown zombie within 0.1 seconds, and its coming back shows it.
        cell.getGridSquare(20, 10, 0).setLight(0, 0f);
        int sets = lit.alphaSets;
        long lag = 0;
        do { sets = lit.alphaSets; frames(1); lag += FRAME; } while (lit.alphaSets > sets && lag < 1_000_000_000L);
        check(lag <= 100_000_000L + FRAME, "A zombie in a square that went dark stayed shown for " + lag / 1_000_000 + " ms");
        sets = lit.alphaSets;
        frames(10);
        check(lit.alphaSets == sets, "A zombie in a dark square was shown again");
        cell.getGridSquare(20, 10, 0).setLight(0, 1f);
        long wait = 0;
        do { frames(1); wait += FRAME; } while (lit.alphaSets == sets && wait < 1_000_000_000L);
        check(lit.alphaSets > sets && wait <= 100_000_000L + FRAME, "A zombie was not shown again within 0.1 seconds of the light coming back: " + wait / 1_000_000 + " ms");
        cell.zombieList.clear();
        FormulasTest.call(mod, "clear");
        frames(1);

        // The detection range: the player's own square lights a zombie in the dark only within it.
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        cell.getGridSquare(15, 10, 0).setLight(0, 0f);
        cell.getGridSquare(13, 10, 0).setLight(0, 0f);
        var beyond = place(cell, 15.5f, 10.5f, 0);
        var within = place(cell, 13.5f, 10.5f, 0);
        frames(1);
        check(beyond.alphaSets == 0, "A zombie in the dark beyond the detection range was shown: " + describe(beyond));
        check(within.alphaSets == 1, "A zombie in the dark within the detection range of a lit player was not shown: " + describe(within));
        ours.setLight(0, 0f);
        for (int wait2 = 0; wait2 < 12; wait2++) frames(1);
        int before = within.alphaSets;
        frames(12);
        check(within.alphaSets == before, "A zombie in the dark was shown with the player's square dark as well");
        ours.setLight(0, 1f);
        player.detectionRange = 6f;
        frames(12);
        check(beyond.alphaSets > 0, "A zombie in the dark within a longer detection range was not shown");
        player.detectionRange = 2f;
        frames(12);
        before = within.alphaSets;
        frames(12);
        check(within.alphaSets == before, "A zombie in the dark beyond a shorter detection range was shown");
        player.detectionRange = 3.5f;
        FormulasTest.call(mod, "clear");
        cell.zombieList.clear();
        frames(1);

        // Within a square the light is doubled and the fade is none; a step further it is neither.
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        ours.setLight(0, 0f);
        cell.getGridSquare(11, 10, 0).setLight(0, 0.00015f);
        cell.getGridSquare(12, 10, 0).setLight(0, 0.00015f);
        var close = place(cell, 11.4f, 10.5f, 0);
        var apart = place(cell, 12.0f, 10.5f, 0);
        frames(1);
        check(close.alphaSets == 1 && apart.alphaSets == 0, "The distance of 1 did not double the light: " + describe(close) + " / " + describe(apart));

        // Beyond the view distance nothing is shown, and a zombie with no square is not either (the game does not see it).
        ours.setLight(0, 1f);
        GameTime.instance.viewDist = 6f;
        var past = place(cell, 17.5f, 10.5f, 0);
        var homeless = place(cell, 14.5f, 10.5f, 0);
        homeless.square = null;
        frames(1);
        check(past.alphaSets == 0 && homeless.alphaSets == 0, "A zombie past the view distance, or with no square, was shown");
        GameTime.instance.viewDist = 30f;
        for (int x = 11; x <= 15; x++) cell.getGridSquare(x, 10, 0).setLight(0, 1f);
        for (int x : new int[] { 20, 22, 24 }) cell.getGridSquare(x, 10, 0).setLight(0, 1f);
        player.square = null;
        FormulasTest.call(mod, "clear");
        cell.zombieList.clear();
        player.spotted.clear();
        frames(1);
    }

    /** How often the line is drawn again, what a wall does within 0.1 seconds, and the alpha every frame. */
    private static void cadence(KahluaTable formulas, Object mod, IsoCell cell, IsoPlayer player) {
        var zombie = place(cell, 15.5f, 10.5f, 0);
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        long before = HiddenZombies.rays;
        // A second at 60 frames: the alpha is set each frame (the game sets it back to 0 each time it updates), the line is drawn
        // every 0.06 to 0.1 seconds, and the spotting is offered every 0.1 to 0.5.
        frames(60);
        long rays = HiddenZombies.rays - before;
        check(zombie.alphaSets == 60, "The alpha was not set every frame: " + zombie.alphaSets);
        check(rays >= 10 && rays <= 17, "The line was drawn " + rays + " times in a second");
        check(player.spotted.size() >= 2 && player.spotted.size() <= 11, "The spotting was offered " + player.spotted.size() + " times in a second");
        // A wall comes between: the zombie is shown for at most another 0.1 seconds. Tried at several moments within a line's period.
        var wall = cell.getGridSquare(13, 10, 0);
        for (int offset = 0; offset < 6; offset++) {
            frames(offset);
            wall.westWall = true;
            long lag = 0;
            int sets;
            do { sets = zombie.alphaSets; frames(1); lag += FRAME; } while (zombie.alphaSets > sets && lag < 1_000_000_000L);
            check(lag <= 100_000_000L + FRAME, "A zombie behind a new wall stayed shown for " + lag / 1_000_000 + " ms");
            sets = zombie.alphaSets;
            frames(10);
            check(zombie.alphaSets == sets, "A zombie behind a wall was shown again");
            // The wall goes: shown again within 0.1 seconds.
            wall.westWall = false;
            long wait = 0;
            do { frames(1); wait += FRAME; } while (zombie.alphaSets == sets && wait < 1_000_000_000L);
            check(zombie.alphaSets > sets && wait <= 100_000_000L + FRAME, "A zombie was not shown again within 0.1 seconds of the wall going: " + wait / 1_000_000 + " ms");
        }
        FormulasTest.call(mod, "clear");
        cell.zombieList.clear();
        player.spotted.clear();
        frames(1);
    }

    /** Several mods, taking it back, and the fix declared again. */
    private static void declarations(KahluaTable api, KahluaTable formulas, Object mod, Object second, IsoCell cell, IsoPlayer player) {
        var zombie = place(cell, 15.5f, 10.5f, 0);
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", false);
        FormulasTest.call(formulas, "set", second, "vision.hiddenZombieFix", true);
        check(Boolean.TRUE.equals(FormulasTest.call(formulas, "get", "vision.hiddenZombieFix").get(0)), "Two mods did not join as any");
        frames(1);
        check(zombie.alphaSets == 1, "One mod declaring the fix did not turn it on");
        FormulasTest.call(second, "clear");
        check(Boolean.FALSE.equals(FormulasTest.call(formulas, "get", "vision.hiddenZombieFix").get(0)), "The remaining declaration was lost");
        int tests = IsoGridSquare.visionTests, sets = zombie.alphaSets;
        frames(5);
        check(zombie.alphaSets == sets && IsoGridSquare.visionTests == tests, "A declaration of false left the fix on");
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        frames(1);
        check(zombie.alphaSets == sets + 1, "Declaring the fix again did not show the zombie at once");
        FormulasTest.call(mod, "clear");
        FormulasTest.call(second, "clear");
        sets = zombie.alphaSets;
        tests = IsoGridSquare.visionTests;
        frames(5);
        check(zombie.alphaSets == sets && IsoGridSquare.visionTests == tests, "Taking the fix back left it on");
        check(FormulasTest.call(formulas, "get", "vision.hiddenZombieFix").get(0) == null, "A point nobody declares is not nil");
        cell.zombieList.clear();
        player.spotted.clear();
    }

    /** A player who cannot see, and the cone the game has now. */
    private static void states(KahluaTable formulas, Object mod, IsoCell cell, IsoPlayer player) {
        var zombie = place(cell, 15.5f, 10.5f, 0);
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        frames(1);
        int sets = zombie.alphaSets;
        check(sets == 1, "The zombie was not shown");
        player.asleep = true; frames(3); player.asleep = false;
        player.dead = true; frames(3); player.dead = false;
        player.seeEveryone = true; frames(3); player.seeEveryone = false;
        player.vehicle = new Object(); frames(3); player.vehicle = null;
        check(zombie.alphaSets == sets, "A player who is asleep, dead, in a car or sees all had a zombie shown");
        frames(1);
        check(zombie.alphaSets == sets + 1, "The fix did not come back when the player could see");
        // A narrow cone leaves the zombie out, a wide one all around brings the one behind in.
        var behind = place(cell, 5.5f, 10.5f, 0);
        LightingJNI.setCone(36f);
        var aside = place(cell, 15.5f, 8.5f, 0);
        frames(1);
        check(behind.alphaSets == 0 && aside.alphaSets == 0, "A zombie outside a narrow cone was shown");
        LightingJNI.setCone(360f);
        frames(1);
        check(behind.alphaSets == 1 && aside.alphaSets == 1, "A zombie in a cone all around was not shown");
        LightingJNI.setCone(144f);
        // The player turns: the zombie behind is in front.
        int ahead = zombie.alphaSets;
        player.lookX = -1f;
        frames(1);
        check(behind.alphaSets == 2 && zombie.alphaSets == ahead, "A turned player did not see what is in front of it now");
        player.lookX = 1f;
        FormulasTest.call(mod, "clear");
        cell.zombieList.clear();
        player.spotted.clear();
        frames(1);
    }

    /** A second player on the machine is looked for on its own. */
    private static void splitScreen(KahluaTable formulas, Object mod, IsoCell cell, IsoPlayer first) {
        var other = new IsoPlayer();
        other.x = 50.5f; other.y = 30.5f; other.z = 0f; other.lookX = -1f;
        IsoPlayer.players[1] = other;
        var zombie = place(cell, 45.5f, 30.5f, 0);
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        frames(1);
        check(zombie.targetAlpha[1] == 1f && zombie.targetAlpha[0] == 0f && zombie.alphaSets == 1, "The second player's zombie was not shown to it alone");
        check(other.spotted.size() == 1 && first.spotted.isEmpty(), "The spotting went to the wrong player");
        zombie.isVisibleToPlayer[1] = true;
        frames(3);
        check(zombie.alphaSets == 1, "A zombie the game draws for the second player was changed");
        IsoPlayer.players[1] = null;
        FormulasTest.call(mod, "clear");
        cell.zombieList.clear();
        frames(1);
    }

    /** What the pass costs for thousands of zombies, against the same frames with the fix not declared. */
    private static void cost(KahluaTable formulas, Object mod) {
        var size = 128;
        var cell = new IsoCell();
        cell.dense(size, 4);
        IsoWorld.instance.cell = cell;
        var random = new Random(42);
        for (int z = 0; z < 4; z++) for (int y = 0; y < size; y++) for (int x = 0; x < size; x++) {
            var square = cell.load(x, y, z);
            square.northWall = random.nextFloat() < 0.15f;
            square.westWall = random.nextFloat() < 0.15f;
            square.solid = random.nextFloat() < 0.05f;
            square.openFloor = random.nextFloat() < 0.1f;
        }
        var player = new IsoPlayer();
        player.x = 64.5f; player.y = 64.5f; player.z = 1f;
        IsoPlayer.players[0] = player;
        GameTime.instance.viewDist = 40f;
        LightingJNI.setCone(144f);
        frames(1);
        System.out.println("hidden zombies, per frame, 128x128 squares on 4 floors, view 40, cone 144 (the synthetic game's squares):");
        System.out.println("  zombies  placed      fix off ms  fix on ms (mean / p99)   extra mean ms   shown/frame   lines/frame");
        double worst = 0;
        // The first pass is for the JIT, and is not shown.
        for (int pass = 0; pass < 2; pass++)
            for (boolean horde : new boolean[] { false, true })
                for (int count : new int[] { 1000, 3000, 10000 }) {
                    cell.zombieList.clear();
                    for (int index = 0; index < count; index++) {
                        double angle = random.nextDouble() * 2 * Math.PI, distance = Math.sqrt(random.nextDouble()) * 35;
                        var zombie = new IsoZombie();
                        zombie.x = horde ? (float)(64.5 + Math.cos(angle) * distance) : random.nextFloat() * size;
                        zombie.y = horde ? (float)(64.5 + Math.sin(angle) * distance) : random.nextFloat() * size;
                        zombie.z = random.nextInt(4);
                        zombie.square = cell.getGridSquare((int)zombie.x, (int)zombie.y, (int)zombie.z);
                        zombie.isVisibleToPlayer[0] = random.nextFloat() < 0.6f;
                        zombie.targetAlpha[0] = zombie.isVisibleToPlayer[0] ? 1f : 0f;
                        cell.zombieList.add(zombie);
                    }
                    FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", false);
                    double[] off = measure(player, cell, 300, 1200);
                    FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
                    long before = HiddenZombies.rays, setBefore = totalSets(cell);
                    double[] on = measure(player, cell, 300, 1200);
                    long drawn = HiddenZombies.rays - before;
                    double shown = (totalSets(cell) - setBefore) / 1500.0;
                    if (pass == 1)
                        System.out.printf("  %7d  %-10s %6.3f / %6.3f   %6.3f / %6.3f        %6.3f      %5.1f    %8.1f%n", count, horde ? "35 around" : "everywhere",
                            off[0], off[1], on[0], on[1], on[0] - off[0], shown, drawn / 1500.0);
                    if (pass == 1 && count == 10000 && horde) worst = on[0] - off[0];
                }
        // What the pass costs without the lines: 10,000 zombies all drawn by the game (one array read each), and none drawn but a
        // cone so narrow that nearly none is a candidate (their positions are read, and nothing more).
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", false);
        double[] idle = measure(player, cell, 300, 600);
        FormulasTest.call(formulas, "set", mod, "vision.hiddenZombieFix", true);
        boolean[] drawn = new boolean[cell.zombieList.size()];
        for (int index = 0; index < drawn.length; index++) { drawn[index] = cell.zombieList.get(index).isVisibleToPlayer[0]; cell.zombieList.get(index).isVisibleToPlayer[0] = true; }
        double[] allDrawn = measure(player, cell, 300, 600);
        for (int index = 0; index < drawn.length; index++) cell.zombieList.get(index).isVisibleToPlayer[0] = false;
        LightingJNI.setCone(18f);
        double[] narrow = measure(player, cell, 300, 600);
        LightingJNI.setCone(144f);
        System.out.printf("  10000 zombies, no lines: fix off %.3f ms; all drawn by the game %.3f ms; none drawn, cone 18 degrees %.3f ms (mean)%n",
            idle[0], allDrawn[0], narrow[0]);
        // The design's measure for the worst case (10,000 zombies all within 35 squares) was 0.16 ms on byte arrays; the synthetic
        // game's squares are objects and cost more. The bound here is for a fault that makes it grow, not a promise.
        check(worst < 5.0, "10,000 zombies near the player cost " + worst + " ms a frame");
        FormulasTest.call(mod, "clear");
        IsoPlayer.players[0] = null;
    }

    /** How many times the alpha of the cell's zombies was set. */
    private static long totalSets(IsoCell cell) {
        long total = 0;
        for (var zombie : cell.zombieList) total += zombie.alphaSets;
        return total;
    }

    /** The mean and the 99th percentile, in milliseconds, of a frame of the API with the player walking and turning. */
    private static double[] measure(IsoPlayer player, IsoCell cell, int warm, int frames) {
        double[] times = new double[frames];
        for (int frame = 0; frame < warm + frames; frame++) {
            double turn = frame * 0.01;
            player.lookX = (float)Math.cos(turn); player.lookY = (float)Math.sin(turn);
            player.x = 64.5f + (float)Math.sin(frame * 0.002) * 20f; player.y = 64.5f + (float)Math.cos(frame * 0.0017) * 20f;
            now += FRAME;
            long start = System.nanoTime();
            GameApi.frame(GAME);
            long took = System.nanoTime() - start;
            if (frame >= warm) times[frame - warm] = took / 1e6;
        }
        Arrays.sort(times);
        return new double[] { Arrays.stream(times).average().orElse(0), times[(int)(frames * 0.99)] };
    }

    /** A fault in the game's list stops the fix alone, once; the formulas and the game go on. */
    private static void fault(KahluaTable api, KahluaTable formulas) {
        var cell = new IsoCell();
        IsoWorld.instance.cell = cell;
        var player = new IsoPlayer();
        IsoPlayer.players[0] = player;
        frames(1);
        Object breaking = FormulasTest.call(api, "client", "hidden.broken").get(0);
        FormulasTest.call(formulas, "set", breaking, "vision.hiddenZombieFix", true);
        FormulasTest.call(formulas, "set", breaking, "body.discomfortMultiplier", 0.5);
        cell.brokenZombieList = true;
        frames(2);
        var points = (KahluaTable)FormulasTest.call(formulas, "points").get(0);
        check(String.valueOf(points.rawget("vision.hiddenZombieFix")).startsWith("unavailable: stopped: "), "A fault was not reported by the point: " + points.rawget("vision.hiddenZombieFix"));
        cell.brokenZombieList = false;
        player.clothingDiscomfortModifier = 2f;
        frames(2);
        check(player.getClothingDiscomfortModifier() == 1f, "A fault in the fix stopped the other formulas");
        check(Boolean.TRUE.equals(FormulasTest.call(formulas, "get", "vision.hiddenZombieFix").get(0)), "The declaration was lost with the fault");
        FormulasTest.call(breaking, "clear");
        IsoPlayer.players[0] = null;
    }

    private static IsoZombie place(IsoCell cell, float x, float y, int z) {
        var zombie = new IsoZombie();
        zombie.x = x; zombie.y = y; zombie.z = z;
        zombie.square = cell.getGridSquare((int)x, (int)y, z);
        zombie.targetAlpha[0] = 0f;
        cell.zombieList.add(zombie);
        return zombie;
    }

    private static String describe(IsoZombie zombie) {
        return "at " + zombie.x + "," + zombie.y + "," + zombie.z + " alpha " + zombie.targetAlpha[0] + " set " + zombie.alphaSets + " times";
    }

    /** The frames of the game, 16.7 ms apart. */
    private static void frames(int count) {
        for (int frame = 0; frame < count; frame++) { now += FRAME; GameApi.frame(GAME); }
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
