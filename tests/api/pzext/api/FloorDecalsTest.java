package pzext.api;

import java.util.List;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;
import zombie.core.textures.ColorInfo;
import zombie.iso.IsoCamera;
import zombie.iso.IsoCell;
import zombie.iso.IsoDirections;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.fboRenderChunk.FBORenderCell;
import zombie.iso.sprite.IsoSprite;
import zombie.iso.sprite.IsoSpriteManager;

/**
 * {@code floor.set} and {@code floor.clear}: a mod's decals drawn as the chunk renderer draws a square's floor (over its floor
 * objects, as a floor object is drawn: the floor as the object, its offsets, the square's light times the tint), the square's chunk
 * level redrawn when they change, several mods on one square, the checks of a call, a handle's clear, the decals gone with their
 * world, a newer API taking them over, and what the hook costs a floor.
 */
final class FloorDecalsTest {
    private static final ClassLoader GAME = FloorDecalsTest.class.getClassLoader();
    private static final FBORenderCell RENDERER = new FBORenderCell();
    private static IsoCell cell;
    private static IsoSprite wire, pipe, end;

    private FloorDecalsTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        try {
            cell = new IsoCell();
            IsoWorld.instance.setCell(cell);
            GameApi.frame(GAME);
            wire = sprite("decals_01_0");
            pipe = sprite("decals_01_8");
            end = sprite("decals_01_9");
            var area = (KahluaTable)api.rawget("floor");
            check(area != null && area.rawget("set") != null && area.rawget("clear") != null, "PZExtAPI.floor is missing");
            Object mod = FormulasTest.call(api, "client", "floor.mod").get(0), second = FormulasTest.call(api, "client", "floor.second").get(0);
            drawing(area, mod);
            mods(area, mod, second);
            unloaded(area, mod);
            rejects(area, mod);
            clearing(area, mod, second);
            worldLeft(api, mod);
            takeover(api, mod);
            cost(api, mod);
        } finally {
            IsoWorld.instance.setCell(home);
            IsoSprite.drawn.clear();
            IsoSprite.recording = true;
        }
    }

    private static IsoSprite sprite(String name) {
        var made = new IsoSprite(name);
        IsoSpriteManager.instance.namedMap.put(name, made);
        return made;
    }

    private static IsoGridSquare floor(int x, int y, int z) {
        IsoGridSquare square = cell.load(x, y, z);
        if (square.floor == null) {
            square.floor = new IsoObject(sprite("floor_" + x + "_" + y + "_" + z));
            square.floor.square = square;
        }
        return square;
    }

    private static KahluaTable list(Object... values) {
        var table = LuaManager.platform.newTable();
        for (int index = 0; index < values.length; index++)
            table.rawset((double)(index + 1), values[index] instanceof Number number ? (Object)number.doubleValue() : values[index]);
        return table;
    }

    private static List<Object[]> draw(IsoGridSquare square) {
        IsoSprite.drawn.clear();
        RENDERER.level(square);
        return List.copyOf(IsoSprite.drawn);
    }

    private static void drawing(KahluaTable area, Object mod) {
        IsoGridSquare square = floor(10, 20, 0);
        square.floor.offsetX = 3;
        square.floor.offsetY = -2;
        square.setLight(1, 0.5f);
        IsoCamera.frameState.playerIndex = 1;
        int before = square.redraws;
        FormulasTest.call(area, "set", mod, 10.0, 20.0, 0.0, list("decals_01_0", 1, 0.8, 0.2, 0.9, "decals_01_9", 1, 1, 1, 1));
        check(square.redraws == before + 1 && square.redrawFlags == FloorDecals.DIRTY_REDRAW, "The square's chunk level was not redrawn: " + square.redraws);
        ColorInfo light = square.getLightInfo(1);
        var drawn = draw(square);
        check(drawn.size() == 2, "Two decals were not drawn: " + drawn.size());
        Object[] first = drawn.get(0), second = drawn.get(1);
        check(first[0] == wire && first[1] == square.floor && first[2].equals(10f) && first[3].equals(20f) && first[4].equals(0f)
            && first[5] == IsoDirections.N && first[6].equals(3f) && first[7].equals(-2f) && first[12].equals(true) && first[13].equals(false)
            && zombie.IndieGL.depthMask,
            "The decal was not drawn as the floor is: " + java.util.Arrays.toString(first));
        check(first[8].equals(light.r * 1f) && first[9].equals(light.g * 0.8f) && first[10].equals(light.b * 0.2f) && first[11].equals(0.9f),
            "The decal's colour is not the light times its tint: " + java.util.Arrays.toString(first));
        check(second[0] == end && second[11].equals(1f), "The second decal: " + java.util.Arrays.toString(second));
        IsoCamera.frameState.playerIndex = 0;
        square.setLight(1, 1f);
        // The same again: nothing redrawn.
        FormulasTest.call(area, "set", mod, 10.0, 20.0, 0.0, list("decals_01_0", 1, 0.8, 0.2, 0.9, "decals_01_9", 1, 1, 1, 1));
        check(square.redraws == before + 1, "The same decals redrew the level");
        // A square without decals beside it, and a square with no floor: nothing.
        check(draw(floor(11, 20, 0)).isEmpty(), "A square without decals was drawn on");
        IsoGridSquare bare = cell.load(12, 20, 0);
        FormulasTest.call(area, "set", mod, 12.0, 20.0, 0.0, list("decals_01_0", 1, 1, 1, 1));
        check(draw(bare).isEmpty(), "A square with no floor was drawn on");
        FormulasTest.call(area, "set", mod, 12.0, 20.0, 0.0, null);
        // Nil and an empty list take them away.
        FormulasTest.call(area, "set", mod, 10.0, 20.0, 0.0, list());
        check(draw(square).isEmpty() && square.redraws == before + 2, "An empty list did not take the decals away");
        check(GameApi.floor().count() == 0, "Squares are left: " + GameApi.floor().count());
    }

    private static void mods(KahluaTable area, Object mod, Object second) {
        IsoGridSquare square = floor(30, 30, 1);
        FormulasTest.call(area, "set", second, 30.0, 30.0, 1.0, list("decals_01_8", 1, 1, 1, 1));
        FormulasTest.call(area, "set", mod, 30.0, 30.0, 1.0, list("decals_01_0", 1, 1, 1, 1));
        var drawn = draw(square);
        check(drawn.size() == 2 && drawn.get(0)[0] == pipe && drawn.get(1)[0] == wire, "Two mods' decals, in the order they were set: " + drawn.size());
        // A mod's change keeps its place; one mod's removal leaves the other's.
        FormulasTest.call(area, "set", second, 30.0, 30.0, 1.0, list("decals_01_9", 1, 1, 1, 1));
        drawn = draw(square);
        check(drawn.get(0)[0] == end && drawn.get(1)[0] == wire, "A mod's change moved its decals");
        FormulasTest.call(area, "set", second, 30.0, 30.0, 1.0, null);
        drawn = draw(square);
        check(drawn.size() == 1 && drawn.get(0)[0] == wire, "One mod's removal took the other's");
        FormulasTest.call(area, "set", mod, 30.0, 30.0, 1.0, null);
        check(GameApi.floor().count() == 0, "Squares are left after the mods: " + GameApi.floor().count());
    }

    private static void unloaded(KahluaTable area, Object mod) {
        // Not loaded: set without a redraw; drawn once its chunk loads and its floor is drawn.
        FormulasTest.call(area, "set", mod, 500.0, 600.0, 0.0, list("decals_01_0", 1, 1, 1, 1));
        IsoGridSquare square = floor(500, 600, 0);
        check(square.redraws == 0, "A square loaded later was redrawn");
        check(draw(square).size() == 1, "A square loaded later was not drawn on");
        FormulasTest.call(area, "set", mod, 500.0, 600.0, 0.0, null);
    }

    private static void rejects(KahluaTable area, Object mod) {
        rejects(area, "the first argument must be a handle", "nobody", 1.0, 1.0, 0.0, null);
        rejects(area, "x must be a whole number", mod, 1.5, 1.0, 0.0, null);
        rejects(area, "z must be a whole number from -32 to 31", mod, 1.0, 1.0, 32.0, null);
        rejects(area, "list must be a table", mod, 1.0, 1.0, 0.0, "decals_01_0");
        rejects(area, "list must hold 5 values for each decal", mod, 1.0, 1.0, 0.0, list("decals_01_0", 1, 1, 1));
        rejects(area, "list[1] must be the name of a sprite the game knows, not 'nothing_01_0'", mod, 1.0, 1.0, 0.0, list("nothing_01_0", 1, 1, 1, 1));
        rejects(area, "list[6] must be the name of a sprite", mod, 1.0, 1.0, 0.0, list("decals_01_0", 1, 1, 1, 1, 7, 1, 1, 1, 1));
        rejects(area, "list[4] must be a number from 0 to 1", mod, 1.0, 1.0, 0.0, list("decals_01_0", 1, 1, 1.5, 1));
        rejects(area, "list[5] must be a number from 0 to 1", mod, 1.0, 1.0, 0.0, list("decals_01_0", 1, 1, 1, Double.NaN));
        Object[] nine = new Object[45];
        for (int index = 0; index < 45; index += 5) { nine[index] = "decals_01_0"; nine[index + 1] = 1; nine[index + 2] = 1; nine[index + 3] = 1; nine[index + 4] = 1; }
        rejects(area, "at most 8 decals on a square", mod, 1.0, 1.0, 0.0, list(nine));
        check(GameApi.floor().count() == 0, "A refused call set decals");
        // A mod's limit of squares.
        Object[] one = { "decals_01_0", 1, 1, 1, 1 };
        for (int index = 0; index < FloorDecals.MAX_SQUARES_PER_MOD; index++) FormulasTest.call(area, "set", mod, (double)(index % 1000), (double)(2000 + index / 1000), 0.0, list(one));
        rejects(area, "the mod has decals on " + FloorDecals.MAX_SQUARES_PER_MOD + " squares", mod, 5000.0, 5000.0, 0.0, list(one));
        // Changing a square it has decals on is still allowed.
        FormulasTest.call(area, "set", mod, 0.0, 2000.0, 0.0, list("decals_01_8", 1, 1, 1, 1));
        FormulasTest.call(area, "clear", mod);
        check(GameApi.floor().count() == 0, "floor.clear left squares: " + GameApi.floor().count());
    }

    private static void rejects(KahluaTable area, String expected, Object... arguments) {
        try {
            FormulasTest.call(area, "set", arguments);
            throw new AssertionError("Accepted: " + expected);
        } catch (RuntimeException refused) {
            check(String.valueOf(refused.getMessage()).contains(expected), "Expected '" + expected + "', got: " + refused.getMessage());
        }
    }

    private static void clearing(KahluaTable area, Object mod, Object second) {
        IsoGridSquare first = floor(40, 40, 0), other = floor(41, 40, 0);
        FormulasTest.call(area, "set", mod, 40.0, 40.0, 0.0, list("decals_01_0", 1, 1, 1, 1));
        FormulasTest.call(area, "set", mod, 41.0, 40.0, 0.0, list("decals_01_0", 1, 1, 1, 1));
        FormulasTest.call(area, "set", second, 41.0, 40.0, 0.0, list("decals_01_8", 1, 1, 1, 1));
        int firstBefore = first.redraws, otherBefore = other.redraws;
        FormulasTest.call(mod, "clear");
        check(first.redraws == firstBefore + 1 && other.redraws == otherBefore + 1, "handle:clear() did not redraw the squares it cleared");
        check(draw(first).isEmpty(), "handle:clear() left the mod's decals");
        var drawn = draw(other);
        check(drawn.size() == 1 && drawn.get(0)[0] == pipe, "handle:clear() took another mod's decals");
        FormulasTest.call(second, "clear");
        check(GameApi.floor().count() == 0, "Squares are left after the clears: " + GameApi.floor().count());
    }

    private static void worldLeft(KahluaTable api, Object mod) {
        var area = (KahluaTable)api.rawget("floor");
        IsoGridSquare square = floor(50, 50, 0);
        FormulasTest.call(area, "set", mod, 50.0, 50.0, 0.0, list("decals_01_0", 1, 1, 1, 1));
        IsoCell before = cell;
        cell = new IsoCell();
        IsoWorld.instance.setCell(cell);
        GameApi.frame(GAME);
        check(GameApi.floor().count() == 0, "The decals outlived their world");
        check(draw(square).isEmpty(), "A square of the world left was drawn on");
        // And a set in the new world does not bring the old ones back.
        IsoGridSquare here = floor(50, 50, 0);
        FormulasTest.call(area, "set", mod, 51.0, 50.0, 0.0, list("decals_01_0", 1, 1, 1, 1));
        check(GameApi.floor().count() == 1 && draw(here).isEmpty(), "The old world's decals came back");
        FormulasTest.call(mod, "clear");
        check(before != cell, "The world did not change");
    }

    private static void takeover(KahluaTable api, Object mod) throws Exception {
        var area = (KahluaTable)api.rawget("floor");
        IsoGridSquare square = floor(60, 60, 0);
        FormulasTest.call(area, "set", mod, 60.0, 60.0, 0.0, list("decals_01_0", 0.5, 1, 1, 0.75, "decals_01_9", 1, 1, 1, 1));
        Object oldSet = area.rawget("set");
        GameApi.register(LuaManager.class);
        check(area.rawget("set") != oldSet && GameApi.floor().count() == 1, "The decals were not taken over: " + GameApi.floor().count());
        try { ((JavaFunction)oldSet).call(new LuaCallFrame(mod, 60.0, 60.0, 0.0, null), 5); throw new AssertionError("an old function worked"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("the API was updated"), expected.getMessage()); }
        var drawn = draw(square);
        check(drawn.size() == 2 && drawn.get(0)[0] == wire && drawn.get(0)[8].equals(0.5f) && drawn.get(0)[11].equals(0.75f) && drawn.get(1)[0] == end,
            "The new API does not draw the decals taken over: " + drawn.size());
        FormulasTest.call(mod, "clear");
        check(draw(square).isEmpty() && GameApi.floor().count() == 0, "The decals taken over cannot be cleared");
    }

    /** What the hook costs a floor drawn, with 4096 squares of decals: printed, and nothing allocated. */
    private static void cost(KahluaTable api, Object mod) {
        var area = (KahluaTable)api.rawget("floor");
        for (int index = 0; index < 4096; index++) {
            int x = 100 + index % 64, y = 100 + index / 64;
            FormulasTest.call(area, "set", mod, (double)x, (double)y, 0.0, list("decals_01_0", 1, 1, 1, 1, "decals_01_9", 1, 1, 1, 1));
        }
        IsoGridSquare plain = floor(99, 99, 0), decorated = floor(120, 120, 0);
        // The game keeps a square's light; the synthetic square makes it anew unless told.
        var light = new ColorInfo(1f, 1f, 1f);
        decorated.lighting[0] = () -> light;
        IsoSprite.recording = false;
        try {
            for (int warm = 0; warm < 50_000; warm++) { RENDERER.level(plain); RENDERER.level(decorated); }
            int rounds = 200_000;
            long start = System.nanoTime();
            for (int n = 0; n < rounds; n++) RENDERER.level(plain);
            double without = (System.nanoTime() - start) / (double)rounds;
            start = System.nanoTime();
            for (int n = 0; n < rounds; n++) RENDERER.level(decorated);
            double with = (System.nanoTime() - start) / (double)rounds;
            System.out.printf("floor: a level of one floor without decals costs %.1f ns, one with two %.1f ns (4096 squares of decals)%n", without, with);
            long bytes = Allocations.median(9, () -> { for (int n = 0; n < 10_000; n++) { RENDERER.level(plain); RENDERER.level(decorated); } });
            check(bytes < 4096, "Drawing floors allocated " + bytes + " bytes for 20,000 floors");
        } finally {
            IsoSprite.recording = true;
        }
        FormulasTest.call(mod, "clear");
        check(GameApi.floor().count() == 0, "Squares are left after the cost");
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
