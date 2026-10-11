package pztools.api;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.MethodModel;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import se.krka.kahlua.vm.*;
import zombie.ai.states.PlayerClimbState;
import zombie.ai.states.PlayerStrafeState;
import zombie.ai.states.player.PlayerMovementState;
import zombie.characters.CharacterStat;
import zombie.characters.FallingConstants;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.characters.BodyDamage.BodyDamage;
import zombie.characters.BodyDamage.BodyPart;
import zombie.characters.BodyDamage.BodyPartType;
import zombie.characters.BodyDamage.Thermoregulator;
import zombie.characters.Moodles.Moodle;
import zombie.characters.WornItems.WornItems;
import zombie.entity.components.fluids.FluidContainer;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.inventory.ItemPickerJava;
import zombie.inventory.types.Food;
import zombie.inventory.types.HandWeapon;
import zombie.inventory.types.InventoryContainer;
import zombie.inventory.types.Moveable;
import zombie.inventory.types.WeaponPart;
import zombie.iso.CorpseCount;
import zombie.iso.IsoCell;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.LightingJNI;
import zombie.iso.Vector2;
import zombie.iso.objects.IsoDeadBody;
import zombie.iso.objects.IsoTree;
import zombie.network.packets.ItemStatsPacket;
import zombie.scripting.objects.ItemTag;
import zombie.scripting.objects.ItemType;
import zombie.vehicles.VehiclePart;
import zombie.Lua.LuaEventManager;
import zombie.Lua.LuaManager;
import pztools.bridge.ApiHooks;
import pztools.bridge.Tracked;

/**
 * The formulas as a Lua mod sees them, against the synthetic game: what a mod declares through its handle changes the
 * game's answer for the local player's character and for nothing else, several mods combine by each point's rule, and
 * the declarations go with the world, stay across a newer API, and never make the game fail.
 */
final class FormulasTest {
    private FormulasTest() { }

    static void run(KahluaTable api) throws Exception {
        KahluaTable formulas = (KahluaTable)api.rawget("formulas");
        check(formulas != null, "PZToolsAPI.formulas is missing");
        var player = new IsoPlayer();
        IsoPlayer.players[0] = player;
        var other = new IsoGameCharacter();
        points(formulas);
        calls(api, formulas);
        bodyPoints(api, formulas, player, other);
        survival(api, formulas, player, other);
        combining(api, formulas, player);
        carry(api, formulas, player, other);
        kept(api, formulas, player, other);
        room(api, formulas, player, other);
        capacities(api, formulas, player, other);
        loads(api, formulas, player, other);
        speeds(api, formulas, player, other);
        partial(formulas);
        faults(api, formulas, player);
        world(api, formulas, player);
        takeover(api, formulas, player);
        IsoPlayer.players[0] = null;
    }

    /**
     * Night sight's least light and screen pass: the squares' corners as the lighting hands them are raised to the least
     * light for a local player, and the light their objects are drawn with (a copy: the square's own is the game's), the
     * game's lighting is worked again when it changes; the screen pass gets the strength, each square's share of its
     * colour kept (the game's light against the least) and its light sources' share (a lamp's falling off to its radius,
     * a room's light whole, none without one) in a texture on its own unit, the unit that was active made active again,
     * and where a pixel is on the floor. The squares are raised to the dark place's least light, and the screen pass
     * takes them down to the one shown; each set of values carries the last set's of the same squares, which the pass
     * goes from to the newest's by the clock.
     */
    private static void lamps(Formulas formulas, zombie.iso.weather.WeatherShader pass, IsoPlayer player) {
        IsoCell home = IsoWorld.instance.currentCell;
        var cell = new IsoCell();
        IsoWorld.instance.setCell(cell);
        player.x = 100.5f;
        player.y = 200.5f;
        player.z = 0f;
        pass.onCompileSuccess(new zombie.core.opengl.ShaderProgram());
        formulas.nightSightFrame(0);
        // the least light grows with the value by the curve (0.8 here)
        float grown = Formulas.sightCurve(0.8f, Formulas.SIGHT_CURVE);
        int least = Math.round(Math.min(1f, (Formulas.FLOOR_FULL + Formulas.DARK_EXTRA) * grown) * 255f), shown = Math.round(Math.min(1f, Formulas.FLOOR_FULL * grown) * 255f);
        check(formulas.nightLamps().floorLight() == least && near(formulas.nightLamps().shade(), shown / (double)least),
            "The least light was not set: " + formulas.nightLamps().floorLight() + " " + formulas.nightLamps().shade());

        // the corners: each colour raised, the alpha kept, for a local player alone, in both of the lighting's reads
        int[] handed = { 7, 0x00102030, 500, 500, 3, 0xFF0A0B0C, 0xFFFFFFFF, 0xFF00FF00, 0x80000000, 0, 0, 0, 0, 2 };
        LightingJNI.squares.put("100,200,0", handed.clone());
        LightingJNI.changed.add("100,200,0");
        var square = cell.load(100, 200, 0);
        for (boolean chunks : new boolean[] { true, false }) {
            var mine = new LightingJNI.JNILighting(0, square);
            var theirs = new LightingJNI.JNILighting(1, square);
            mine.read(chunks);
            theirs.read(chunks);
            int raised = 0xFF000000 | least << 16 | least << 8 | least;
            check(mine.lightverts(0) == raised && mine.lightverts(1) == 0xFFFFFFFF && mine.lightverts(2) == (0xFF00FF00 | least << 16 | least)
                && mine.lightverts(3) == (0x80000000 | least << 16 | least << 8 | least) && mine.lightverts(7) == (least << 16 | least << 8 | least)
                && theirs.lightverts(0) == 0xFF0A0B0C && theirs.lightverts(3) == 0x80000000,
                "The corners were not raised for the local player alone: " + Integer.toHexString(mine.lightverts(0)) + " " + Integer.toHexString(theirs.lightverts(0)));
        }
        check(java.util.Arrays.equals(LightingJNI.squares.get("100,200,0"), handed), "What the lighting handed was changed");
        // a square the lighting says has not changed: read again only when it was raised to another least light (or not
        // read since squares are raised), and for a local player alone
        LightingJNI.changed.clear();
        var unchanged = new LightingJNI.JNILighting(0, square);
        unchanged.read(true);
        check(unchanged.lightverts(0) == 0, "A square raised to the least light was read again");
        LightingJNI.squares.put("101,201,0", handed.clone());
        var unseen = new LightingJNI.JNILighting(0, cell.load(101, 201, 0));
        var unseenTheirs = new LightingJNI.JNILighting(1, cell.load(101, 201, 0));
        unseen.read(false);
        unseenTheirs.read(false);
        check(unseen.lightverts(1) == 0xFFFFFFFF && unseenTheirs.lightverts(1) == 0, "A square not read since squares are raised was not read, or for another player");
        formulas.nightLamps().floorLight(40);
        unchanged.read(false);
        check(unchanged.lightverts(0) == (0xFF000000 | 40 << 16 | 40 << 8 | 40), "A square raised to another least light was not read again: "
            + Integer.toHexString(unchanged.lightverts(0)));
        formulas.nightLamps().floorLight(least);
        unchanged.read(true);
        unseen.read(true);
        LightingJNI.squares.remove("101,201,0");
        // the game's light of the square, as its corners were handed: their mean (its own light, 0.95 below, is not what it is drawn with)
        double seen = Math.round((NightLamps.luma(12, 11, 10) + 255 + 0.587f * 255) * 1000 / 8000f) / 255.0;
        // the objects' light: a raised copy, the square's own left as it is; a light square's as it is
        var renderer = new zombie.iso.fboRenderChunk.FBORenderCell();
        square.setLight(0, 0.1f);
        var own = square.lighting[0].lightInfo();
        square.lighting[0] = () -> own;
        var drawn = renderer.objectLight(0, square);
        check(drawn != own && near(drawn.r, least / 255.0) && near(drawn.b, least / 255.0) && own.r == 0.1f,
            "The objects' light was not a raised copy: " + drawn.r + " " + own.r);
        square.setLight(0, 0.95f);
        check(renderer.objectLight(0, square).r == 0.95f, "A light square's objects' light changed");
        // a square the player has never seen (an unexplored room, drawn black): its corners and its objects' light are the game's
        int[] unexplored = handed.clone();
        unexplored[0] = 4;
        LightingJNI.squares.put("105,205,0", unexplored);
        var hiddenRoom = cell.load(105, 205, 0);
        hiddenRoom.setLight(0, 0.1f);
        hiddenRoom.setUnexplored(0);
        var hiddenLighting = new LightingJNI.JNILighting(0, hiddenRoom);
        hiddenLighting.read(true);
        check(hiddenLighting.lightverts(0) == 0xFF0A0B0C && renderer.objectLight(0, hiddenRoom).r == 0.1f,
            "A square the player has never seen was raised: " + Integer.toHexString(hiddenLighting.lightverts(0)));
        LightingJNI.squares.remove("105,205,0");
        LightingJNI.squares.clear();

        var lamp = new zombie.iso.IsoGridSquare.ResultLight(104, 203, 7, 1f, zombie.iso.IsoGridSquare.ResultLight.RLF_NONE);
        cell.load(100, 203, 0).setLight(0, 0.9f, lamp);
        cell.load(101, 200, 0).setLight(0, 0.3f);
        cell.load(102, 200, 0).setLight(0, 0.3f, new zombie.iso.IsoGridSquare.ResultLight(90, 190, 5, 1f, zombie.iso.IsoGridSquare.ResultLight.RLF_ROOMLIGHT));
        cell.load(103, 200, 0).setLight(0, 0.3f, new zombie.iso.IsoGridSquare.ResultLight(110, 200, 5, 1f, zombie.iso.IsoGridSquare.ResultLight.RLF_NONE));
        cell.load(104, 203, 0).setLight(0, 1f, lamp);
        int x0 = 100 - NightLamps.SIZE / 2, y0 = 200 - NightLamps.SIZE / 2;
        // the newest set's values (the third and fourth bytes of a square), and the last set's (the first)
        java.util.function.BiFunction<Integer, Integer, Double> kept = (x, y) ->
            (org.lwjgl.opengl.GL11.pixels[NightLamps.first(x - x0, y - y0) + 2] & 0xFF) / 255.0;
        java.util.function.BiFunction<Integer, Integer, Double> share = (x, y) ->
            (org.lwjgl.opengl.GL11.pixels[NightLamps.first(x - x0, y - y0) + 3] & 0xFF) / 255.0;
        java.util.function.BiFunction<Integer, Integer, Double> keptBefore = (x, y) ->
            (org.lwjgl.opengl.GL11.pixels[NightLamps.first(x - x0, y - y0)] & 0xFF) / 255.0;
        double floor = least / 255.0, lampShare = (1 - 4 / 7.0) / 0.9;
        frameLater(formulas, pass);
        // the set before had none of the lights (the cell was empty), and this one goes from it towards the squares' values
        // by at most the pace night sight eases at (a tenth of a second of nightSight.ease, tuned to 0.3 here, for it)
        int pace = Math.round(255f * 0.1f / 0.3f);
        check(keptBefore.apply(101, 200) == 0.0 && keptBefore.apply(100, 203) == 0.0 && kept.apply(101, 200) == pace / 255.0
            && share.apply(104, 203) == pace / 255.0, "The newest set's values did not go from the last set's at night sight's pace: "
            + keptBefore.apply(101, 200) + " " + kept.apply(101, 200) + " " + share.apply(104, 203));
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        IsoWorld.instance.setCell(home);
        check(near(org.lwjgl.opengl.GL20.values.get(3), 0.8) && org.lwjgl.opengl.GL20.values.get(4) == 1f && near(org.lwjgl.opengl.GL20.values.get(9), Formulas.SIGHT_LIFT)
            && near(org.lwjgl.opengl.GL20.values.get(11), shown / (double)least) && org.lwjgl.opengl.GL20.values.get(10) >= 0f && org.lwjgl.opengl.GL20.values.get(10) < 1f,
            "The screen pass did not get the strength, the least light shown or how far it is between the values, or is not on: " + org.lwjgl.opengl.GL20.values);
        check(org.lwjgl.opengl.GL20.integers.get(6) == NightLamps.UNIT && org.lwjgl.opengl.GL11.unitBound == 0x84C0 + NightLamps.UNIT
            && org.lwjgl.opengl.GL13.active() == 0x84C0 && org.lwjgl.opengl.GL11.width == 2 * NightLamps.SIZE,
            "The values' texture is not on its own unit, or the active unit was not given back: " + org.lwjgl.opengl.GL13.active());
        check(kept.apply(100, 203) == 1.0 && Math.abs(share.apply(100, 203) - lampShare) < 0.01 && kept.apply(104, 203) == 1.0
            && share.apply(104, 203) == 1.0 && Math.abs(kept.apply(101, 200) - 0.3 / floor) < 0.01 && share.apply(101, 200) == 0.0
            && share.apply(102, 200) == 1.0 && share.apply(103, 200) == 0.0 && kept.apply(95, 195) == 0.0
            && Math.abs(kept.apply(100, 200) - seen / floor) < 0.01,
            "The squares' values: " + kept.apply(101, 200) + " " + share.apply(100, 203) + " " + share.apply(102, 200) + " " + kept.apply(100, 200));
        check(org.lwjgl.opengl.GL20.values.get(5) == 0f, "Beyond the values the colour is not kept as on their edge: " + org.lwjgl.opengl.GL20.values.get(5));
        // the player stands on its square: the squares behind it it is drawn over, and their sides, keep at least its values
        // (its square lit by the corners handed, the ones behind it not loaded)
        double standing = kept.apply(100, 200);
        check(kept.apply(99, 199) == standing && kept.apply(97, 197) == standing && kept.apply(98, 199) == standing && kept.apply(100, 199) == standing
            && kept.apply(96, 196) == 0.0 && !formulas.nightLamps().darkPlace(),
            "The squares a standing player is drawn over do not keep its colour: " + kept.apply(99, 199) + " " + kept.apply(96, 196));
        float[] u = org.lwjgl.opengl.GL20.vectors.get(7), v = org.lwjgl.opengl.GL20.vectors.get(8);
        float wx = 103.25f, wy = 197.5f;
        float fx = zombie.Lua.LuaManager.GlobalObject.isoToScreenX(0, wx, wy, 0f);
        float fy = zombie.core.Core.getInstance().getScreenHeight() - zombie.Lua.LuaManager.GlobalObject.isoToScreenY(0, wx, wy, 0f);
        check(near(u[0] * fx + u[1] * fy + u[2], (wx - x0) / (double)NightLamps.SIZE) && near(v[0] * fx + v[1] * fy + v[2], (wy - y0) / (double)NightLamps.SIZE),
            "A pixel is not found where it is on the floor: " + java.util.Arrays.toString(u) + " " + java.util.Arrays.toString(v));
        // a square on: the last set's values are of the same squares, where the newest set starts
        IsoWorld.instance.setCell(cell);
        double before = kept.apply(101, 200);
        player.x = 101.5f;
        frameLater(formulas, pass);
        int moved = x0 + 1;
        double after = (org.lwjgl.opengl.GL11.pixels[NightLamps.first(101 - moved, 200 - y0)] & 0xFF) / 255.0;
        check(after == before, "The last set's values are not of the same squares after a step: " + after + " " + before);
        player.x = 100.5f;
        bench(formulas, pass, handed);
        IsoWorld.instance.setCell(home);
        player.x = player.y = 0f;
    }

    // What night sight's paths cost (printed): the game asks squareStale of every square it reads, squareLit of each it
    // reads again, objectLight of each object it draws; the values are worked out 10 times a second.
    private static void bench(Formulas formulas, zombie.iso.weather.WeatherShader pass, int[] handed) {
        var lamps = formulas.nightLamps();
        var info = new zombie.core.textures.ColorInfo(0.1f, 0.1f, 0.1f);
        int[] lit = handed.clone();
        int rounds = 2_000_000;
        boolean any = false;
        try {
            for (int warm = 0; warm < 2; warm++) {
                long start = System.nanoTime();
                for (int n = 0; n < rounds; n++) lamps.squareLit(0, 100 + (n & 63), 200 + (n >> 6 & 63), 0, lit);
                long litTook = System.nanoTime() - start;
                start = System.nanoTime();
                for (int n = 0; n < rounds; n++) any ^= lamps.squareStale(0, 100 + (n & 63), 200 + (n >> 6 & 63), 0);
                long staleTook = System.nanoTime() - start;
                start = System.nanoTime();
                for (int n = 0; n < rounds; n++) any ^= lamps.objectLight(info, 0, null) == info;
                long objectTook = System.nanoTime() - start;
                long at = System.nanoTime();
                start = System.nanoTime();
                for (int n = 0; n < 200; n++) {
                    lamps.frame(0, at += NightLamps.REFRESH_NS);
                    pass.startRenderThread(new zombie.core.textures.TextureDraw());
                }
                long valuesTook = System.nanoTime() - start;
                if (warm == 1)
                    System.out.printf("night sight: squareLit %.1f ns, squareStale %.1f ns, objectLight %.1f ns a call; the values %.3f ms each, with their draw (the synthetic cell: 7 squares lit)%s%n",
                        litTook / (double)rounds, staleTook / (double)rounds, objectTook / (double)rounds, valuesTook / 200 / 1e6, any ? "" : " ");
            }
        } catch (Throwable failure) { throw new AssertionError(failure); }
    }

    /**
     * A dark place: with most squares around the player without the game's own light, the least light shown is
     * {@link Formulas#DARK_EXTRA} more, eased in over frames (from a frame after the values say so); lit, it eases out.
     * The squares stay raised to the dark place's least light all along, so that the game does not bake them again; with
     * a second player of this machine (no values) they are raised to the one outside a dark place, shown as it is.
     */
    private static void darkPlace(Formulas formulas, zombie.iso.weather.WeatherShader pass, IsoPlayer player) {
        IsoCell home = IsoWorld.instance.currentCell;
        var cell = new IsoCell();
        IsoWorld.instance.setCell(cell);
        player.x = player.y = 300.5f;
        player.z = 0f;
        for (int dx = -6; dx <= 6; dx++) for (int dy = -6; dy <= 6; dy++) cell.load(300 + dx, 300 + dy, 0).setLight(0, 0f);
        float grown = Formulas.sightCurve(0.2f, Formulas.SIGHT_CURVE);
        int plain = Math.round(Math.min(1f, Formulas.FLOOR_FULL * grown) * 255f), dark = Math.round(Math.min(1f, (Formulas.FLOOR_FULL + Formulas.DARK_EXTRA) * grown) * 255f);
        var lamps = formulas.nightLamps();
        float outside = NightLamps.shadeOf(plain, dark, 0f, 1f);
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        check(lamps.darkPlace() && lamps.floorLight() == dark && lamps.shade() > outside && lamps.shade() < 1f,
            "In a dark place the least light shown does not ease towards more: " + lamps.floorLight() + " " + lamps.shade());
        // the squares of a room with no light are in the player's sight, though the game does not see them for the dark
        // (bCanSee asks for light): night sight shows them, and they count for the dark place
        int playerSquare = NightLamps.second(300 - 268, 300 - 268);
        check((org.lwjgl.opengl.GL11.pixels[playerSquare + 2] & 0xFF) == 255 && (org.lwjgl.opengl.GL11.pixels[playerSquare + 3] & 0xFF) == 0
            && lamps.counted()[2] > 0 && lamps.counted()[3] == lamps.counted()[2],
            "Night sight does not show a room with no light: " + (org.lwjgl.opengl.GL11.pixels[playerSquare + 2] & 0xFF) + " " + lamps.counted()[2]);
        // a wall's face is read as the squares behind it, which take the values of the square it stands on (a lit square
        // behind a dark room's wall does not light the wall); a wall in front of the player (cut away) is left
        var walled = cell.load(302, 296, 0);
        var front = cell.load(303, 301, 0);
        walled.northWall = front.northWall = true;
        cell.load(302, 295, 0).setLight(0, 0.5f);
        cell.load(303, 300, 0).setLight(0, 0.5f);
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        java.util.function.BiFunction<Integer, Integer, Integer> keptAt = (x, y) -> org.lwjgl.opengl.GL11.pixels[NightLamps.first(x - 268, y - 268) + 2] & 0xFF;
        check(keptAt.apply(302, 295).equals(keptAt.apply(302, 296)) && keptAt.apply(301, 294).equals(keptAt.apply(302, 296))
            && keptAt.apply(303, 300) > keptAt.apply(303, 301),
            "A wall's face does not take its room's values: " + keptAt.apply(302, 295) + " " + keptAt.apply(302, 296) + " " + keptAt.apply(303, 300));
        walled.northWall = front.northWall = false;
        cell.load(302, 295, 0).setLight(0, 0f);
        cell.load(303, 300, 0).setLight(0, 0f);
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        check(lamps.shade() == 1f && formulas.nightSightDarkShown() == 1f, "In a dark place the least light shown is not the whole more: " + lamps.shade());
        // a few lit squares do not end it
        for (int dx = -6; dx <= -2; dx++) for (int dy = -6; dy <= 6; dy++) cell.load(300 + dx, 300 + dy, 0).setLight(0, 0.5f);
        frameLater(formulas, pass);
        check(formulas.nightLamps().darkPlace(), "A dark place ended with a few lit squares");
        for (int dx = -6; dx <= 6; dx++) for (int dy = -6; dy <= 6; dy++) cell.load(300 + dx, 300 + dy, 0).setLight(0, 0.5f);
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        check(!lamps.darkPlace() && lamps.floorLight() == dark && lamps.shade() > outside && lamps.shade() < 1f,
            "Lit, the least light shown does not ease back, or the squares were raised again: " + lamps.floorLight() + " " + lamps.shade());
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        frameLater(formulas, pass);
        check(lamps.shade() == outside && lamps.floorLight() == dark, "Lit, the least light shown is still more: " + lamps.shade());
        IsoPlayer.players[1] = new IsoPlayer();
        formulas.nightSightFrame(1);
        check(lamps.floorLight() == plain && lamps.shade() == 1f, "With two players the squares are not raised to the least light outside a dark place: "
            + lamps.floorLight() + " " + lamps.shade());
        IsoPlayer.players[1] = null;
        formulas.nightSightFrame(0);
        check(lamps.floorLight() == dark && lamps.shade() == outside, "With one player again the squares are not raised to the dark place's least light");
        // by day none of it is shown outside a dark place (the game's light and colour kept), at dusk some; nothing baked again
        zombie.iso.weather.ClimateManager.night = 0f;
        formulas.nightSightFrame(0);
        check(lamps.shade() == 0f && lamps.floorLight() == dark, "By day the least light is shown: " + lamps.shade());
        zombie.iso.weather.ClimateManager.night = 0.5f;
        formulas.nightSightFrame(0);
        check(lamps.shade() == NightLamps.shadeOf(plain, dark, 0f, 0.5f) && lamps.shade() > 0f && lamps.shade() < outside, "At dusk: " + lamps.shade());
        // a square the player does not see (the game reads it no light, and draws it dimmed its own way) is left as drawn,
        // by day and at night, and it does not count for a dark place; as it comes into sight night sight eases in on it,
        // what is drawn being the game's light times its share kept until then
        var unseen = cell.load(310, 300, 0);
        unseen.setLight(0, 0f);
        unseen.setUnseen(0);
        java.util.function.IntSupplier sight = () -> org.lwjgl.opengl.GL11.pixels[NightLamps.second(310 - 268, 300 - 268) + 2] & 0xFF;
        java.util.function.IntSupplier drawn = () -> org.lwjgl.opengl.GL11.pixels[NightLamps.second(310 - 268, 300 - 268) + 3] & 0xFF;
        java.util.function.IntSupplier seenSight = () -> org.lwjgl.opengl.GL11.pixels[NightLamps.second(300 - 268, 300 - 268) + 2] & 0xFF;
        zombie.iso.weather.ClimateManager.night = 0f;
        for (int i = 0; i < 4; i++) frameLater(formulas, pass);
        check(sight.getAsInt() == 0 && drawn.getAsInt() == 255 && seenSight.getAsInt() == 255 && !lamps.darkPlace(),
            "By day a square the player does not see is not left as drawn: " + sight.getAsInt() + " " + drawn.getAsInt());
        zombie.iso.weather.ClimateManager.night = 1f;
        frameLater(formulas, pass);
        check(sight.getAsInt() == 0 && drawn.getAsInt() == 255, "At night a square the player does not see is not left as drawn");
        unseen.setLight(0, 0f);
        frameLater(formulas, pass);
        check(sight.getAsInt() > 0 && sight.getAsInt() < 255 && drawn.getAsInt() == 0,
            "A square coming into sight does not ease into night sight: " + sight.getAsInt() + " " + drawn.getAsInt());
        IsoWorld.instance.setCell(home);
        player.x = player.y = 0f;
    }

    // A frame after the values are due to be worked out again, and a draw.
    private static void frameLater(Formulas formulas, zombie.iso.weather.WeatherShader pass) {
        try { Thread.sleep(NightLamps.REFRESH_NS / 1_000_000L + 10); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        formulas.nightSightFrame(0);
        pass.startRenderThread(new zombie.core.textures.TextureDraw());
    }

    private static void points(KahluaTable formulas) {
        // The classes the load tree hooks are transformed as they load: use each once.
        new Moodle(new IsoPlayer());
        new InventoryContainer("Bag", 1f, 30);
        new Food(null);
        new HandWeapon(1f);
        new WeaponPart(0f);
        new Moveable();
        new ItemStatsPacket();
        new FluidContainer(1f, 0f);
        new WornItems();
        ItemPickerJava.getLootModifierFromType("Other");
        new IsoTree();
        new Thermoregulator(new IsoPlayer());
        CorpseCount.instance.getCorpseCount(null);
        new BodyDamage(new IsoPlayer());
        new BodyPart(new IsoPlayer());
        new zombie.core.opengl.ShaderUnit();
        new zombie.iso.weather.WeatherShader();
        new LightingJNI.JNILighting(0, null);
        new zombie.iso.fboRenderChunk.FBORenderCell();
        var points = (KahluaTable)call(formulas, "points").get(0);
        for (String applied : new String[] { "body.discomfortMultiplier", "body.stiffnessMultiplier", "body.fatigueMultiplier",
                "body.enduranceDrainMultiplier", "body.poisonMultiplier", "carry.categoryEfficiency", "carry.itemEfficiency",
                "carry.containerTagMultiplier", "capacity.maxWeightAdd", "capacity.effectiveMultiplier", "capacity.characterLimitAdd",
                "capacity.modDataKey", "overload.compress", "move.runPenaltyReduction", "move.combatPenaltyReduction" })
            check(ApiHooks.APPLIED.equals(points.rawget(applied)), applied + " is " + points.rawget(applied));
        for (String applied : new String[] { "loot.spawnMultiplier", "loot.ammoMultiplier", "vision.darknessRestore", "vision.coneAdd",
                "vision.nightSight", "fall.landingRemap", "fall.impactMultiplier", "move.walkMultiplier", "move.treeSlowMultiplier", "move.treeScratchChance",
                "body.coldMultiplier", "body.corpseCountMultiplier", "body.corpseSicknessMultiplier", "body.holeChance", "infection.woundChance",
                "infection.biteShield" })
            check(ApiHooks.APPLIED.equals(points.rawget(applied)), applied + " is " + points.rawget(applied));
        for (String applied : new String[] { "machine.baseConsumption", "machine.loadKey", "anim.stepKey" })
            check(ApiHooks.APPLIED.equals(points.rawget(applied)), applied + " is " + points.rawget(applied));
        check(ApiHooks.APPLIED.equals(points.rawget("vision.hiddenZombieFix")), "vision.hiddenZombieFix is " + points.rawget("vision.hiddenZombieFix"));
        check(Formulas.POINTS.size() == 35, "The points are " + Formulas.POINTS.size());
        // Every hook a point names is one the game's classes were given.
        for (var point : Formulas.POINTS)
            for (String label : point.hooks()) check(ApiHooks.hookStatus().containsKey(label), point.name() + " names a hook that does not exist: " + label);
    }

    /** Mistakes in a call are the calling mod's error, named in the message it gets. */
    private static void calls(KahluaTable api, KahluaTable formulas) {
        Object mod = call(api, "client", "formulas.mod").get(0);
        rejects(formulas, "set", "first argument must be a handle", "formulas.mod", "body.discomfortMultiplier", 0.5);
        rejects(formulas, "set", "there is no point body.nothing", mod, "body.nothing", 0.5);
        rejects(formulas, "set", "point must be a string", mod, 5.0, 0.5);
        rejects(formulas, "set", "body.discomfortMultiplier must be a number from 0.0 to 100.0", mod, "body.discomfortMultiplier", -1.0);
        rejects(formulas, "set", "body.discomfortMultiplier must be a number", mod, "body.discomfortMultiplier", "half");
        rejects(formulas, "set", "body.discomfortMultiplier must be a number", mod, "body.discomfortMultiplier", Double.NaN);
        rejects(formulas, "get", "there is no point body.nothing", "body.nothing");
        rejects(formulas, "set", "vision.hiddenZombieFix must be true or false", mod, "vision.hiddenZombieFix", 1.0);
        // The shapes of the points that are built: a chance is from 0 to 1, an amount from 0 up, a shield true or false.
        rejects(formulas, "set", "body.holeChance must be a number from 0.0 to 1.0", mod, "body.holeChance", 1.5);
        rejects(formulas, "set", "move.treeScratchChance must be a number from 0.0 to 1.0", mod, "move.treeScratchChance", -0.1);
        rejects(formulas, "set", "fall.landingRemap must be a number from 0.0 to 1000.0", mod, "fall.landingRemap", -1.0);
        rejects(formulas, "set", "infection.biteShield must be true or false", mod, "infection.biteShield", 1.0);
        rejects(formulas, "set", "vision.darknessRestore must be a number from 0.0 to 1.0", mod, "vision.darknessRestore", 2.0);
        rejects(formulas, "set", "vision.coneAdd must be a number from -1000.0 to 1000.0", mod, "vision.coneAdd", 5000.0);
    }

    /** Each point of the body changes the local player's answer by its value, and no other character's. */
    private static void bodyPoints(KahluaTable api, KahluaTable formulas, IsoPlayer player, IsoGameCharacter other) {
        Object mod = call(api, "client", "body.mod").get(0);
        player.clothingDiscomfortModifier = other.clothingDiscomfortModifier = 2f;
        check(player.getClothingDiscomfortModifier() == 2f, "The game's answer changed without a formula");
        call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        check(player.getClothingDiscomfortModifier() == 1f, "Discomfort was not halved: " + player.getClothingDiscomfortModifier());
        check(other.getClothingDiscomfortModifier() == 2f, "Another character's discomfort changed");
        check(near((Double)call(formulas, "get", "body.discomfortMultiplier").get(0), 0.5), "get does not give the declared value");
        call(formulas, "set", mod, "body.discomfortMultiplier", null);
        check(player.getClothingDiscomfortModifier() == 2f && call(formulas, "get", "body.discomfortMultiplier").get(0) == null,
            "Taking the formula back left it in force");

        // Strain adds up faster or slower, but what the muscles recover is not scaled.
        call(formulas, "set", mod, "body.stiffnessMultiplier", 0.4);
        player.addStiffness(BodyPartType.Hand_L, 10f);
        other.addStiffness(BodyPartType.Hand_L, 10f);
        check(near(player.stiffness.get(BodyPartType.Hand_L), 4) && other.stiffness.get(BodyPartType.Hand_L) == 10f,
            "Stiffness was not scaled for the local player alone: " + player.stiffness);
        player.addStiffness(BodyPartType.Hand_L, -2f);
        check(near(player.stiffness.get(BodyPartType.Hand_L), 2), "Recovered stiffness was scaled: " + player.stiffness);
        call(formulas, "set", mod, "body.stiffnessMultiplier", null);

        player.thermoregulator = other.thermoregulator = new Object();
        player.thermoregulatorFatigue = other.thermoregulatorFatigue = 1.5;
        call(formulas, "set", mod, "body.fatigueMultiplier", 0.8);
        check(near(player.getFatiqueMultiplier(), 1.2) && other.getFatiqueMultiplier() == 1.5, "Fatigue was not scaled for the local player alone");
        // The game's own default (no thermoregulator) is scaled too: the formula changes the answer, whatever it was.
        player.thermoregulator = null;
        check(near(player.getFatiqueMultiplier(), 0.8), "The default fatigue was not scaled");
        call(formulas, "set", mod, "body.fatigueMultiplier", null);
        check(player.getFatiqueMultiplier() == 1.0, "Fatigue stayed scaled");

        // Endurance: what drains it (add of a negative, remove of a positive), not what recovers it, and no other stat.
        call(formulas, "set", mod, "body.enduranceDrainMultiplier", 0.5);
        player.stats.set(CharacterStat.ENDURANCE, 1f);
        other.stats.set(CharacterStat.ENDURANCE, 1f);
        player.stats.add(CharacterStat.ENDURANCE, -0.2f);
        other.stats.add(CharacterStat.ENDURANCE, -0.2f);
        check(near(player.stats.get(CharacterStat.ENDURANCE), 0.9) && near(other.stats.get(CharacterStat.ENDURANCE), 0.8),
            "Endurance drain was not halved for the local player alone: " + player.stats.get(CharacterStat.ENDURANCE));
        player.stats.remove(CharacterStat.ENDURANCE, 0.2f);
        check(near(player.stats.get(CharacterStat.ENDURANCE), 0.8), "remove was not scaled like add: " + player.stats.get(CharacterStat.ENDURANCE));
        player.stats.add(CharacterStat.ENDURANCE, 0.1f);
        check(near(player.stats.get(CharacterStat.ENDURANCE), 0.9), "Endurance recovery was scaled");
        player.stats.set(CharacterStat.HUNGER, 0.5f);
        player.stats.add(CharacterStat.HUNGER, -0.2f);
        check(near(player.stats.get(CharacterStat.HUNGER), 0.3), "Another stat's drop was scaled");
        call(formulas, "set", mod, "body.enduranceDrainMultiplier", null);
        player.stats.add(CharacterStat.ENDURANCE, -0.2f);
        check(near(player.stats.get(CharacterStat.ENDURANCE), 0.7), "Endurance drain stayed scaled");

        // Poison: what adds to it.
        call(formulas, "set", mod, "body.poisonMultiplier", 0.25);
        player.stats.set(CharacterStat.POISON, 0f);
        player.stats.add(CharacterStat.POISON, 8f);
        check(near(player.stats.get(CharacterStat.POISON), 2), "Poison was not scaled: " + player.stats.get(CharacterStat.POISON));
        player.stats.add(CharacterStat.POISON, -1f);
        check(near(player.stats.get(CharacterStat.POISON), 1), "Poison recovery was scaled");
        call(formulas, "set", mod, "body.poisonMultiplier", null);
        call(mod, "clear");
    }

    /**
     * The survival points: loot, what the player sees, falls, trees, walking, the illnesses of the body, torn clothes and
     * wounds, and the bite shield. Each changes the local player's answer and no other character's.
     */
    private static void survival(KahluaTable api, KahluaTable formulas, IsoPlayer player, IsoGameCharacter other) throws Exception {
        Object mod = call(api, "client", "survival.mod").get(0), second = call(api, "client", "survival.second").get(0);
        var remote = new IsoPlayer();

        // Loot: the chance of an item, and the ammunition modifier alone.
        var item = new ItemPickerJava.ItemPickerItem();
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 5), "The game's chance of an item");
        call(formulas, "set", mod, "loot.spawnMultiplier", 1.5);
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 7.5), "The chance was not multiplied: "
            + ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false));
        call(formulas, "set", second, "loot.spawnMultiplier", 2.0);
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 15) && near((Double)call(formulas, "get", "loot.spawnMultiplier").get(0), 3),
            "Two mods' loot chances did not multiply");
        call(second, "clear");
        check(ItemPickerJava.getLootModifierFromType("Ammo") == 1f, "The ammunition modifier changed with nothing declared");
        call(formulas, "set", mod, "loot.ammoMultiplier", 1.5);
        check(ItemPickerJava.getLootModifierFromType("Ammo") == 1.5f && ItemPickerJava.getLootModifierFromType("Generator") == 4f
            && ItemPickerJava.getLootModifierFromType("Other") == 1f, "Only the ammunition modifier should change");
        item.itemName = "Base.Bullets9mm";
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 5 * 1.5 * 1.5), "Both loot points on an ammunition item: "
            + ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false));
        call(mod, "clear");
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 5), "Clearing left the loot changed");

        // Vision: the darkness the player sees in, and the width of the cone.
        player.luma = other.luma = 0.25f;
        check(near(LightingJNI.darkness(player), 0.75), "The game's darkness");
        call(formulas, "set", mod, "vision.darknessRestore", 0.6);
        check(near(LightingJNI.darkness(player), 0.3) && near(LightingJNI.darkness(other), 0.75), "Darkness was not restored for the local player alone");
        call(formulas, "set", second, "vision.darknessRestore", 0.5);
        check(near((Double)call(formulas, "get", "vision.darknessRestore").get(0), 0.8) && near(LightingJNI.darkness(player), 0.15),
            "Two restorations leave what is left of the dark multiplied: " + LightingJNI.darkness(player));
        call(second, "clear");
        call(mod, "clear");
        check(near(LightingJNI.calculateVisionCone(player), (144 - 126 * 0.75 - 180) / 180), "The game's cone");
        call(formulas, "set", mod, "vision.coneAdd", 36.0);
        check(near(LightingJNI.calculateVisionCone(player), (144 - 126 * 0.75 + 36 - 180) / 180)
            && near(LightingJNI.calculateVisionCone(other), (144 - 126 * 0.75 - 180) / 180), "The cone was not widened for the local player alone: "
            + LightingJNI.calculateVisionCone(player));
        // The worn items' multiplier takes the added degrees too, as the traits' are, and the cone has its limits.
        player.wornVision = 1.5f;
        check(near(LightingJNI.calculateVisionCone(player), ((144 - 126 * 0.75 + 36) * 1.5 - 180) / 180), "The worn items did not scale the added degrees");
        call(formulas, "set", mod, "vision.coneAdd", 1000.0);
        check(near(LightingJNI.calculateVisionCone(player), 1.0), "The cone went past all around: " + LightingJNI.calculateVisionCone(player));
        call(formulas, "set", mod, "vision.coneAdd", -100.0);
        check(near(LightingJNI.calculateVisionCone(player), (18 - 180) / 180.0), "The cone went below its least: " + LightingJNI.calculateVisionCone(player));
        player.wornVision = 1f;
        player.luma = other.luma = 1f;
        call(mod, "clear");

        // Night sight: the screen shader gets its step (screen.frag alone, once): the world's sampling returns through it, and
        // its single texels of the world are read through it; its uniforms are found when the screen pass compiles and set
        // when it draws.
        String world = "#version 330\nuniform sampler2D DIFFUSE;\nuniform float NightVisionGoggles;\n"
            + "vec4 textureBicubic(sampler2D sampler, vec2 texCoords)\n{\n\tvec4 a = texture2D(sampler, texCoords);\n\tif (a.r > 0.5) { a = a * 0.5; }\n"
            + "\treturn mix(a, a, 0.5);\n}\nvec3 blur(in vec2 uv) {\n\tvec3 c = texture2D(DIFFUSE, uv).rgb;\n\tc += texture2D( DIFFUSE , uv).rgb;\n\treturn c;\n}\n"
            + "void main() { gl_FragColor = textureBicubic(DIFFUSE, vec2(0.0)); }\n";
        String patched = ApiHooks.shaderSource(world, "media/shaders/screen.frag");
        check(patched.contains("uniform float PZT_NightSight;") && patched.contains("vec4 pztSampled = mix(a, a, 0.5);")
            && patched.contains("return vec4(pztNightSight(pztSampled.rgb), pztSampled.a);")
            && patched.indexOf("vec3 pztNightSight(") < patched.indexOf("vec4 textureBicubic(") && patched.contains("if (a.r > 0.5) { a = a * 0.5; }")
            && patched.contains("vec3 c = pztDiffuse( uv).rgb;") && patched.contains("c += pztDiffuse( uv).rgb;")
            && patched.contains("texture2D(sampler, texCoords)") && patched.contains("textureBicubic(DIFFUSE, vec2(0.0))"),
            "The screen shader did not get night sight's step: " + patched);
        check(ApiHooks.shaderSource(patched, "media/shaders/screen.frag").equals(patched), "The step went in twice");
        check(patched.contains("PZT_SightTexel = 0.5 / " + NightLamps.SIZE + ".0;"), "The step reads the values by another size than theirs");
        check(ApiHooks.shaderSource(world, "media/shaders/blur.frag").equals(world), "Another shader was changed");
        check(ApiHooks.shaderSource("void main() { }", "media/shaders/screen.frag").equals("void main() { }"), "A screen shader with no sampling was changed");
        String noGoggles = world.replace("uniform float NightVisionGoggles;\n", "");
        check(ApiHooks.shaderSource(noGoggles, "media/shaders/screen.frag").equals(noGoggles), "A screen shader with no goggles' uniform was changed");
        zombie.core.opengl.ShaderUnit.text = world;
        check(new zombie.core.opengl.ShaderUnit().load("media/shaders/screen.frag").contains("PZT_NightSight"), "The loaded screen shader has no step");
        String[] uniforms = { "PZT_NightSight", "PZT_SightOn", "PZT_SightKeep", "PZT_SightLamps", "PZT_SightU", "PZT_SightV", "PZT_SightLift",
            "PZT_SightBlend", "PZT_SightShade" };
        for (int i = 0; i < uniforms.length; i++) {
            check(patched.contains(uniforms[i] + ";"), "The step has no " + uniforms[i]);
            org.lwjgl.opengl.GL20.uniforms.put(uniforms[i], 3 + i);
        }
        var pass = new zombie.iso.weather.WeatherShader();
        pass.onCompileSuccess(new zombie.core.opengl.ShaderProgram());

        // The lift eases in as it gets dark, for the local player alone, and leaves in the light; none in daylight.
        var formulasObject = GameApi.formulas();
        float from = Formulas.DARK_FROM, full = Formulas.DARK_FULL;
        check(Formulas.darkGate(0.2f, from, full) == 0f && Formulas.darkGate(0.54f, from, full) == 1f && Formulas.darkGate(0.4f, from, full) > 0.4f
            && Formulas.darkGate(0.4f, from, full) < 0.6f && Formulas.darkGate(0.4f, 0.5f, 0.5f) == 0f && Formulas.darkGate(0.5f, 0.5f, 0.5f) == 1f,
            "The darkness gate");
        // The screen pass goes from the last set's values to the newest's by the clock, over the time the next takes; the
        // least light shown is the one outside a dark place against the dark place's, and the share of the more on top.
        long period = NightLamps.REFRESH_NS;
        check(NightLamps.blend(0, period) == 0f && NightLamps.blend(-5, period) == 0f && NightLamps.blend(period / 4, period) == 0.25f
            && NightLamps.blend(period, period) == 1f && NightLamps.blend(3 * period, period) == 1f && NightLamps.blend(5, 0) == 1f,
            "The blend between the values: " + NightLamps.blend(period / 4, period));
        check(NightLamps.shadeOf(100, 200, 0f, 1f) == 0.5f && NightLamps.shadeOf(100, 200, 1f, 1f) == 1f && NightLamps.shadeOf(100, 200, 0.5f, 1f) == 0.75f
            && NightLamps.shadeOf(100, 200, 2f, 1f) == 1f && NightLamps.shadeOf(100, 200, -1f, 1f) == 0.5f && NightLamps.shadeOf(0, 0, 0f, 1f) == 1f
            && NightLamps.shadeOf(0, 50, 0f, 1f) == 0f, "The least light shown: " + NightLamps.shadeOf(100, 200, 0.5f, 1f));
        // by day (night 0) none outside a dark place, a dark place's whole in one; half of it at half the night
        check(NightLamps.shadeOf(100, 200, 0f, 0f) == 0f && NightLamps.shadeOf(100, 200, 1f, 0f) == 1f && NightLamps.shadeOf(100, 200, 0.5f, 0f) == 0.5f
            && NightLamps.shadeOf(100, 200, 0f, 0.5f) == 0.25f && NightLamps.shadeOf(100, 200, 0f, 2f) == 0.5f, "The least light shown by day: "
            + NightLamps.shadeOf(100, 200, 0f, 0.5f));
        // the values go towards the squares' by at most a step, never past them
        check(NightLamps.toward(0, 200, 85) == 85 && NightLamps.toward(200, 0, 85) == 115 && NightLamps.toward(100, 120, 85) == 120
            && NightLamps.toward(120, 100, 85) == 100 && NightLamps.toward(7, 7, 85) == 7, "A step towards the squares' values");
        call(formulas, "set", mod, "vision.nightSight", 0.8);
        player.luma = 0.05f;
        LightingJNI.darkness(player);
        long t = 1_000_000_000L;
        formulasObject.nightSightStep(t);
        formulasObject.nightSightStep(t += 1_000_000_000L / 10);
        check(near(formulasObject.nightSightScreen(), 0.1 / Formulas.SIGHT_EASE), "Night sight did not ease in: " + formulasObject.nightSightScreen());
        for (int i = 0; i < 20; i++) formulasObject.nightSightStep(t += 1_000_000_000L / 10);
        check(near(formulasObject.nightSightScreen(), 0.8), "Night sight did not come in whole: " + formulasObject.nightSightScreen());
        // the values' and the dark place's checks below run at a quicker pace than the eye's default
        call(formulas, "tune", "nightSight.ease", 0.3);
        lamps(formulasObject, pass, player);
        // in a dark place the least light is more
        call(formulas, "set", mod, "vision.nightSight", 0.2);
        darkPlace(formulasObject, pass, player);
        call(formulas, "set", mod, "vision.nightSight", 0.8);
        call(formulas, "tune", "nightSight.ease");
        // what night sight is doing now, for a look in game
        var state = (KahluaTable)call(formulas, "nightSight").get(0);
        check(near((Double)state.rawget("level"), 0.8) && near((Double)state.rawget("bakedFloor"), formulasObject.nightLamps().floorLight() / 255.0)
            && near((Double)state.rawget("shownFloor"), formulasObject.nightLamps().floorLight() / 255.0 * formulasObject.nightLamps().shade())
            && state.rawget("darkPlace") instanceof Boolean && state.rawget("valuesRun") instanceof Boolean && state.rawget("nightStrength") != null
            && state.rawget("squaresInSight") != null && state.rawget("keptNear") != null && state.rawget("strength") != null,
            "Night sight's state is not told: " + state);
        // a declared value at night moves night sight on within a few frames: the lift's strength, the values, the least light
        zombie.iso.weather.ClimateManager.night = 0.8f;
        player.luma = 0.05f;
        LightingJNI.darkness(player);
        for (int i = 0; i < 5; i++) frameLater(formulasObject, pass);
        state = (KahluaTable)call(formulas, "nightSight").get(0);
        check((Double)state.rawget("strength") > 0 && Boolean.TRUE.equals(state.rawget("valuesRun")) && (Double)state.rawget("shownFloor") > 0
            && (Double)state.rawget("frames") > 0 && (Double)state.rawget("draws") > 0 && near((Double)state.rawget("nightStrength"), 0.8)
            && "applied".equals(state.rawget("hooks")) && state.rawget("problem") == null,
            "A declared value at night does not move night sight on: " + state.rawget("strength") + " " + state.rawget("valuesRun") + " "
                + state.rawget("hooks") + " " + state.rawget("problem"));
        zombie.iso.weather.ClimateManager.night = 1f;
        // the step calls only the clamp and max the game's shaders leave (util/math.h hides GLSL's other forms)
        check(!java.util.regex.Pattern.compile("clamp\\([^,()]+,\\s*vec").matcher(patched).find()
            && !java.util.regex.Pattern.compile("\\bmax\\(\\s*vec").matcher(patched).find()
            && !patched.contains("clamp(uv,"), "The step calls a clamp or max the game's shaders hide");
        // its numbers are tuned while the game runs, and back to their defaults with no value
        var tunings = (KahluaTable)call(formulas, "tunings").get(0);
        var floorTuning = (KahluaTable)tunings.rawget("nightSight.floorFull");
        check(floorTuning != null && near((Double)floorTuning.rawget("default"), Formulas.FLOOR_FULL) && tunings.rawget("nightSight.lift") != null
            && tunings.rawget("nightSight.standing") != null && near((Double)((KahluaTable)tunings.rawget("nightSight.ease")).rawget("default"), Formulas.SIGHT_EASE)
            && near((Double)((KahluaTable)tunings.rawget("nightSight.curve")).rawget("default"), Formulas.SIGHT_CURVE),
            "The tunings are not listed, or night sight does not ease at the eyes' pace");
        // the least light grows with the value by the curve: whole at 1, little at a low value
        check(Formulas.sightCurve(1f, 1.5f) == 1f && Formulas.sightCurve(0f, 1.5f) == 0f && near(Formulas.sightCurve(0.25f, 1.5f), 0.125)
            && Formulas.sightCurve(0.1f, 1.5f) < 0.04f && near(Formulas.sightCurve(0.5f, 1f), 0.5), "The least light's curve: " + Formulas.sightCurve(0.25f, 1.5f));
        check(near((Double)call(formulas, "tune", "nightSight.floorFull", 0.5).get(0), 0.5), "A tuning did not answer its value");
        call(formulas, "tune", "nightSight.lift", 0.4);
        formulasObject.nightSightFrame(0);
        pass.startRenderThread(new zombie.core.textures.TextureDraw());
        check(formulasObject.nightLamps().floorLight() == Math.round(Math.min(1f, (0.5f + Formulas.DARK_EXTRA) * Formulas.sightCurve(0.8f, Formulas.SIGHT_CURVE)) * 255f) && near(org.lwjgl.opengl.GL20.values.get(9), 0.4),
            "A tuning did not take: " + formulasObject.nightLamps().floorLight());
        rejects(formulas, "tune", "nightSight.floorFull must be a number from 0.0 to 1.0", "nightSight.floorFull", 1.5);
        rejects(formulas, "tune", "there is no tuning nightSight.nothing", "nightSight.nothing", 0.5);
        call(formulas, "tune", "nightSight.floorFull");
        call(formulas, "tune", "nightSight.lift");
        formulasObject.nightSightFrame(0);
        check(formulasObject.nightLamps().floorLight() == Math.round(Math.min(1f, (Formulas.FLOOR_FULL + Formulas.DARK_EXTRA) * Formulas.sightCurve(0.8f, Formulas.SIGHT_CURVE)) * 255f), "A tuning was not back to its default");
        // in the light it leaves
        player.luma = 0.9f;
        LightingJNI.darkness(player);
        for (int i = 0; i < 20; i++) formulasObject.nightSightStep(t += 1_000_000_000L / 10);
        check(formulasObject.nightSightScreen() == 0f, "Night sight did not leave in the light: " + formulasObject.nightSightScreen());
        rejects(formulas, "set", "vision.nightSight must be a number from 0.0 to 1.0", mod, "vision.nightSight", 1.5);
        player.luma = 1f;
        call(second, "clear");
        call(mod, "clear");
        // with no night sight declared, no least light: the squares raised are read again as they were, and the screen pass is off
        formulasObject.nightSightFrame(0);
        pass.startRenderThread(new zombie.core.textures.TextureDraw());
        LightingJNI.squares.put("100,200,0", new int[] { 7, 0, 0, 0, 0, 0x01020304, 0, 0, 0, 0, 0, 0, 0 });
        var unraised = new LightingJNI.JNILighting(0, new zombie.iso.IsoGridSquare(100, 200, 0));
        unraised.read(true);
        LightingJNI.squares.clear();
        check(formulasObject.nightLamps().floorLight() == 0 && org.lwjgl.opengl.GL20.values.get(4) == 0f && unraised.lightverts(0) == 0x01020304,
            "Night sight did not go off: " + formulasObject.nightLamps().floorLight() + " " + Integer.toHexString(unraised.lightverts(0)));

        // A fall: the floors forgiven, never from a height that kills, and the damage by a multiplier.
        float oneFloor = FallingConstants.getIsoImpactSpeedFromHeight(1f), twoFloors = FallingConstants.getIsoImpactSpeedFromHeight(2f);
        player.DoLand(oneFloor);
        check(near(player.landedAt, oneFloor) && nearly(player.impactDamage, 115 / 1.5), "The game's landing: " + player.impactDamage);
        call(formulas, "set", mod, "fall.landingRemap", 0.5);
        player.DoLand(oneFloor);
        other.DoLand(oneFloor);
        check(nearly(player.impactDamage, 115 / 3.0) && nearly(other.impactDamage, 115 / 1.5), "Half a floor of the fall was not forgiven for the local player alone: "
            + player.impactDamage + ", " + other.impactDamage);
        call(formulas, "set", mod, "fall.landingRemap", 1.0);
        player.landedAt = player.impactDamage = -1f;
        player.DoLand(oneFloor);
        check(player.landedAt == -1f && player.impactDamage == -1f, "A fall forgiven altogether was still a landing: " + player.landedAt);
        player.DoLand(twoFloors);
        check(nearly(player.impactDamage, 115 / 1.5), "Two floors with one forgiven are one: " + player.impactDamage);
        // A fall of the height that kills is the game's, whatever is forgiven; a little lower is not.
        call(formulas, "set", mod, "fall.landingRemap", 5.0);
        float lethal = FallingConstants.lethalFallThreshold;
        player.DoLand(lethal);
        check(player.landedAt == lethal, "A fall that kills was forgiven: " + player.landedAt);
        player.DoLand(lethal * 1.5f);
        check(player.landedAt == lethal * 1.5f, "A higher fall was forgiven");
        player.landedAt = -1f;
        player.DoLand(Math.nextDown(lethal));
        check(player.landedAt == -1f, "A fall just below the lethal height was not forgiven");
        call(formulas, "set", mod, "fall.landingRemap", null);
        // The damage the landing does is a multiplier of what the speed works out to.
        call(formulas, "set", mod, "fall.impactMultiplier", 0.5);
        player.DoLand(oneFloor);
        other.DoLand(oneFloor);
        check(nearly(player.impactDamage, 115 / 3.0) && nearly(other.impactDamage, 115 / 1.5), "The damage was not halved for the local player alone: "
            + player.impactDamage + ", " + other.impactDamage);
        check(player.landedAt == oneFloor, "The multiplier changed the speed of the landing, not the damage");
        call(formulas, "set", mod, "fall.landingRemap", 0.5);
        player.DoLand(oneFloor);
        check(nearly(player.impactDamage, 115 / 6.0), "Both fall points: " + player.impactDamage);
        call(mod, "clear");
        player.DoLand(oneFloor);
        check(nearly(player.impactDamage, 115 / 1.5), "Clearing left the fall changed");

        // Trees: how much they slow the player and how fast the animation goes, and whether they scratch.
        var tree = new IsoTree();
        check(near(tree.getSlowFactor(player), 0.8) && near(player.treesSpeed(), 1), "The game's trees");
        call(formulas, "set", mod, "move.treeSlowMultiplier", 0.5);
        check(near(tree.getSlowFactor(player), 0.9) && near(tree.getSlowFactor(other), 0.8) && near(tree.getSlowFactor(remote), 0.8),
            "The tree's slowdown was not halved for the local player alone: " + tree.getSlowFactor(player));
        tree.size = 3;
        check(near(tree.getSlowFactor(player), 0.75), "A denser tree: " + tree.getSlowFactor(player));
        tree.size = 5;
        check(near(tree.getSlowFactor(player), 1), "A tree that does not slow");
        tree.size = 1;
        player.ranger = true;
        check(near(tree.getSlowFactor(player), 1.2), "A ranger's bonus was changed: " + tree.getSlowFactor(player));
        player.ranger = false;
        check(near(player.treesSpeed(), 2) && near(remote.treesSpeed(), 1), "The animation was not sped up for the local player alone: " + player.treesSpeed());
        call(formulas, "set", mod, "move.treeSlowMultiplier", 0.0);
        check(near(tree.getSlowFactor(player), 1) && near(player.treesSpeed(), Formulas.MAX_TREE_ANIMATION), "No slowdown: " + tree.getSlowFactor(player)
            + ", " + player.treesSpeed());
        call(formulas, "set", mod, "move.treeSlowMultiplier", 2.0);
        check(near(tree.getSlowFactor(player), 0.6) && near(player.treesSpeed(), 0.5), "A double slowdown: " + tree.getSlowFactor(player));
        call(formulas, "set", mod, "move.treeSlowMultiplier", 100.0);
        check(near(tree.getSlowFactor(player), 0), "A slowdown past standing still: " + tree.getSlowFactor(player));
        call(formulas, "set", mod, "move.treeSlowMultiplier", null);
        for (int step = 0; step < 100; step++) { player.stepInTrees(); other.stepInTrees(); }
        check(player.scratches == 100 && player.holes == 100, "The game's scratches");
        call(formulas, "set", mod, "move.treeScratchChance", 0.0);
        for (int step = 0; step < 100; step++) { player.stepInTrees(); other.stepInTrees(); }
        check(player.scratches == 100 && player.holes == 100 && other.scratches == 200, "A chance of 0 still scratched: " + player.scratches);
        call(formulas, "set", mod, "move.treeScratchChance", 0.5);
        call(formulas, "set", second, "move.treeScratchChance", 0.5);
        check(near((Double)call(formulas, "get", "move.treeScratchChance").get(0), 0.25), "Two chances did not multiply");
        call(second, "clear");
        for (int step = 0; step < 4000; step++) player.stepInTrees();
        check(player.scratches - 100 > 1800 && player.scratches - 100 < 2200 && player.holes == player.scratches,
            "A chance of a half scratched " + (player.scratches - 100) + " of 4000 times; the clothes tore " + player.holes);
        call(mod, "clear");

        // Walking: the movement of a player who walks, runs or strafes, and nothing else.
        player.deferredX = 2f;
        player.deferredY = 4f;
        remote.deferredX = 2f;
        remote.deferredY = 4f;
        player.setCurrentState(PlayerMovementState.instance());
        remote.setCurrentState(PlayerMovementState.instance());
        var movement = new Vector2();
        player.movement(movement);
        check(movement.x == 2f && movement.y == 4f, "The game's movement");
        call(formulas, "set", mod, "move.walkMultiplier", 1.5);
        player.movement(movement);
        check(near(movement.x, 3) && near(movement.y, 6), "Walking was not faster: " + movement.x + ", " + movement.y);
        remote.movement(movement);
        check(movement.x == 2f && movement.y == 4f, "A player of another machine walked faster");
        player.setCurrentState(PlayerStrafeState.instance());
        player.movement(movement);
        check(near(movement.x, 3), "Strafing was not faster");
        player.setCurrentState(PlayerClimbState.instance());
        player.movement(movement);
        check(movement.x == 2f && movement.y == 4f, "Climbing was faster");
        player.setCurrentState(null);
        player.movement(movement);
        check(movement.x == 2f, "A player in no state was faster");
        player.setCurrentState(PlayerMovementState.instance());
        call(formulas, "set", second, "move.walkMultiplier", 1.2);
        player.movement(movement);
        check(near(movement.x, 3.6), "Two walking multipliers: " + movement.x);
        call(second, "clear");
        player.invisible = true;
        check(player.movement(movement).x == 0f, "A movement set to nothing was not returned as it is");
        player.invisible = false;
        call(mod, "clear");
        player.movement(movement);
        check(movement.x == 2f && movement.y == 4f, "Clearing left the walking changed");
        player.setCurrentState(null);

        // The body: a cold, the corpses around and the sickness they make.
        var cold = new Thermoregulator(player);
        var remoteCold = new Thermoregulator(remote);
        cold.skin = remoteCold.skin = 0.2f;
        check(near(cold.getCatchAColdDelta(), 0.2), "The game's cold");
        call(formulas, "set", mod, "body.coldMultiplier", 0.4);
        check(near(cold.getCatchAColdDelta(), 0.08) && near(remoteCold.getCatchAColdDelta(), 0.2), "A cold was not slowed for the local player alone: "
            + cold.getCatchAColdDelta());
        player.hypothermia = 3;
        check(near(cold.getCatchAColdDelta(), 0.24), "The game's own multiplier of the cold stayed in it");
        player.hypothermia = 0;
        call(formulas, "set", mod, "body.coldMultiplier", null);
        CorpseCount.instance.corpses = 8;
        check(CorpseCount.instance.getCorpseCount(player) == 8 && near(player.getBodyDamage().GetBaseCorpseSickness(), 0.03), "The game's corpses");
        call(formulas, "set", mod, "body.corpseSicknessMultiplier", 0.5);
        check(near(player.getBodyDamage().GetBaseCorpseSickness(), 0.015) && near(other.getBodyDamage().GetBaseCorpseSickness(), 0.03)
            && CorpseCount.instance.getCorpseCount(player) == 8, "The sickness was not scaled for the local player alone");
        call(formulas, "set", mod, "body.corpseCountMultiplier", 0.625);
        check(CorpseCount.instance.getCorpseCount(player) == 5 && CorpseCount.instance.getCorpseCount(other) == 8
            && CorpseCount.instance.getCorpseCount(null) == 0, "The corpses were not counted fewer for the local player alone: "
            + CorpseCount.instance.getCorpseCount(player));
        check(near(player.getBodyDamage().GetBaseCorpseSickness(), 0), "The game makes the sickness from the corpses counted");
        CorpseCount.instance.corpses = 0;
        check(CorpseCount.instance.getCorpseCount(player) == 0, "No corpses are still none");
        call(formulas, "set", mod, "body.corpseCountMultiplier", 2.0);
        CorpseCount.instance.corpses = 5;
        check(CorpseCount.instance.getCorpseCount(player) == 10, "Corpses counted more");
        call(mod, "clear");
        CorpseCount.instance.corpses = 0;

        // Clothes tear, and wounds rolled for an infection, by a chance.
        check(player.addHole(null, true) && player.holes == player.scratches + 1, "The game tears the clothes");
        int holes = player.holes;
        call(formulas, "set", mod, "body.holeChance", 0.0);
        boolean any = false;
        for (int index = 0; index < 100; index++) any |= player.addHole(null, true);
        check(!any && player.holes == holes && other.addHole(null, true), "A chance of 0 still tore the clothes, or reached another character");
        call(formulas, "set", mod, "body.holeChance", 0.5);
        int torn = 0;
        for (int index = 0; index < 4000; index++) if (player.addHole(null, true)) torn++;
        check(torn > 1800 && torn < 2200 && player.holes == holes + torn, "A chance of a half tore the clothes " + torn + " of 4000 times");
        call(mod, "clear");
        var wound = player.getBodyDamage().getBodyParts().get(0);
        var otherWound = other.getBodyDamage().getBodyParts().get(0);
        wound.setScratched(true, false);
        otherWound.setScratched(true, false);
        check(wound.infectionRolls == 1 && wound.IsInfected(), "The game rolls for an infection");
        wound.SetInfected(false);
        otherWound.SetInfected(false);
        call(formulas, "set", mod, "infection.woundChance", 0.0);
        for (int index = 0; index < 100; index++) { wound.setScratched(true, false); otherWound.setScratched(true, false); }
        check(wound.infectionRolls == 1 && !wound.IsInfected() && otherWound.infectionRolls == 101,
            "A chance of 0 still rolled for an infection, or reached another character: " + wound.infectionRolls);
        call(formulas, "set", mod, "infection.woundChance", 0.5);
        for (int index = 0; index < 4000; index++) wound.setScratched(true, false);
        check(wound.infectionRolls - 1 > 1800 && wound.infectionRolls - 1 < 2200, "A chance of a half rolled " + (wound.infectionRolls - 1) + " of 4000 times");
        call(mod, "clear");

        // The bite shield: used once for each time it is declared, never for what a save loads, for the local player alone.
        var zombie = new IsoZombie();
        var parts = player.getBodyDamage().getBodyParts();
        var others = other.getBodyDamage().getBodyParts();
        for (var part : parts) { part.SetInfected(false); part.SetFakeInfected(false); }
        LuaEventManager.raised.clear();
        player.getBodyDamage().AddRandomDamageFromZombie(zombie, "Bite", 0);
        check(parts.get(0).bitten() && parts.get(0).IsInfected(), "The game's bite infects");
        parts.get(0).SetInfected(false);
        check(LuaEventManager.added.contains("OnPZToolsBiteSurvived"), "The bite event was not added");
        call(formulas, "set", mod, "infection.biteShield", true);
        // A save loading a bitten part is not a bite.
        parts.get(2).SetBitten(true);
        check(parts.get(2).IsInfected(), "A part loaded as bitten lost its infection to the shield");
        parts.get(2).SetInfected(false);
        // A bite on another character's body: not the player's.
        other.getBodyDamage().AddRandomDamageFromZombie(zombie, "Bite", 1);
        check(others.get(1).bitten() && others.get(1).IsInfected(), "The shield took another character's bite");
        player.getBodyDamage().AddRandomDamageFromZombie(zombie, "Bite", 1);
        check(parts.get(1).bitten() && !parts.get(1).IsInfected() && !parts.get(1).IsFakeInfected(), "The shield did not take the infection out of the bite: "
            + parts.get(1).IsInfected());
        GameApi.frame(FormulasTest.class.getClassLoader());
        check(LuaEventManager.raised.size() == 1 && LuaEventManager.raised.get(0).equals(List.of("OnPZToolsBiteSurvived", 1.0)),
            "The survived bite was not told: " + LuaEventManager.raised);
        GameApi.frame(FormulasTest.class.getClassLoader());
        check(LuaEventManager.raised.size() == 1, "The survived bite was told twice");
        // Used up: the next bite infects, though the mod still declares it.
        player.getBodyDamage().AddRandomDamageFromZombie(zombie, "Bite", 2);
        check(parts.get(2).IsInfected(), "The shield was used twice for one declaration");
        parts.get(2).SetInfected(false);
        // Declared again after it was taken back: armed once more. What the part had before the bite stays.
        call(formulas, "set", mod, "infection.biteShield", null);
        call(formulas, "set", mod, "infection.biteShield", true);
        parts.get(0).SetInfected(true);
        player.getBodyDamage().AddRandomDamageFromZombie(zombie, "Bite", 0);
        check(parts.get(0).IsInfected(), "An infection the part had before the bite was taken out");
        GameApi.frame(FormulasTest.class.getClassLoader());
        check(LuaEventManager.raised.size() == 2 && LuaEventManager.raised.get(1).equals(List.of("OnPZToolsBiteSurvived", 0.0)), "The second survived bite: "
            + LuaEventManager.raised);
        // Two mods: either arms it, and it is armed once while both declare it.
        call(formulas, "set", mod, "infection.biteShield", null);
        call(formulas, "set", mod, "infection.biteShield", true);
        call(formulas, "set", second, "infection.biteShield", true);
        check(call(formulas, "get", "infection.biteShield").get(0) == Boolean.TRUE, "Two shields did not join");
        player.getBodyDamage().AddRandomDamageFromZombie(zombie, "Bite", 2);
        check(!parts.get(2).IsInfected(), "The shield was not armed");
        call(mod, "clear");
        player.getBodyDamage().AddRandomDamageFromZombie(zombie, "Bite", 2);
        check(parts.get(2).IsInfected(), "Another mod's declaration armed the shield again");
        call(second, "clear");
        check(call(formulas, "get", "infection.biteShield").get(0) == null, "The shield stayed declared");
        // Taking it back disarms it.
        parts.get(2).SetInfected(false);
        call(formulas, "set", mod, "infection.biteShield", true);
        call(formulas, "set", mod, "infection.biteShield", false);
        player.getBodyDamage().AddRandomDamageFromZombie(zombie, "Bite", 2);
        check(parts.get(2).IsInfected(), "A shield declared false still worked");
        call(mod, "clear");
        for (var part : parts) { part.SetInfected(false); part.SetBitten(false); }
        LuaEventManager.raised.clear();
    }

    private static boolean nearly(double value, double expected) { return Math.abs(value - expected) <= Math.abs(expected) * 1e-3 + 1e-6; }

    /** Several mods declaring one point combine by its rule; a mod's clear takes back its own and nobody else's. */
    private static void combining(KahluaTable api, KahluaTable formulas, IsoPlayer player) {
        Object first = call(api, "client", "first.mod").get(0), second = call(api, "client", "second.mod").get(0);
        player.clothingDiscomfortModifier = 4f;
        call(formulas, "set", first, "body.discomfortMultiplier", 0.5);
        call(formulas, "set", second, "body.discomfortMultiplier", 0.25);
        check(player.getClothingDiscomfortModifier() == 0.5f && near((Double)call(formulas, "get", "body.discomfortMultiplier").get(0), 0.125),
            "Multipliers did not multiply: " + player.getClothingDiscomfortModifier());
        check(near((Double)call(formulas, "declared", first, "body.discomfortMultiplier").get(0), 0.5)
            && near((Double)call(formulas, "declared", second, "body.discomfortMultiplier").get(0), 0.25), "declared does not give a mod's own value");
        call(first, "clear");
        check(player.getClothingDiscomfortModifier() == 1f && call(formulas, "declared", first, "body.discomfortMultiplier").get(0) == null,
            "A mod's clear did not take back its formulas, or took another's");
        call(formulas, "set", second, "body.discomfortMultiplier", 0.0);
        check(player.getClothingDiscomfortModifier() == 0f, "A multiplier of 0 was not applied");
        call(second, "clear");
        check(player.getClothingDiscomfortModifier() == 4f, "Clearing the last formula left the answer changed");
    }

    private static InventoryItem item(String category, float weight) { return new InventoryItem(category, weight); }

    private static InventoryItem put(IsoGameCharacter owner, InventoryItem item) {
        owner.inventory.AddItem(item);
        return item;
    }

    private static void clearEquipment(IsoGameCharacter character) {
        character.getWornItems().clear();
        character.setPrimaryHandItem(null);
        character.setSecondaryHandItem(null);
    }

    private static KahluaTable table(Object... pairs) {
        KahluaTable result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static KahluaTable list(Object... items) {
        KahluaTable result = LuaManager.platform.newTable();
        for (int index = 0; index < items.length; index++) result.rawset((double)(index + 1), items[index]);
        return result;
    }

    /**
     * An inventory of 30 by the game's count: a plank, paint, a sofa (a moveable), a tool, and a bag (30 room) that holds four
     * nails and a key ring with three keys. Returns plank, paint, sofa, tool, bag, ring.
     */
    private static InventoryItem[] stock(IsoGameCharacter owner) {
        owner.inventory.items.clear();
        clearEquipment(owner);
        var plank = put(owner, item("Material", 3f));
        var paint = put(owner, item("Paint", 2f));
        var sofa = put(owner, item("Furniture", 20f));
        sofa.itemType = ItemType.MOVEABLE;
        var tool = put(owner, item("Tool", 1.5f));
        var bag = new InventoryContainer("Bag", 1f, 30);
        put(owner, bag);
        for (int index = 0; index < 4; index++) bag.getInventory().AddItem(item("Material", 0.5f));
        var ring = new InventoryContainer("Keys", 0.2f, 10);
        ring.itemType = ItemType.KEY_RING;
        ring.tags.add(ItemTag.KEY_RING);
        bag.getInventory().AddItem(ring);
        for (int index = 0; index < 3; index++) ring.getInventory().AddItem(item("Key", 0.1f));
        return new InventoryItem[] { plank, paint, sofa, tool, bag, ring };
    }

    /**
     * What the character carries counts by efficiency: a display category's, an item type's, a bag's tags; the efficiencies of
     * one item add and divide its weight, a worn or hotbar bag keeps the game's own factors, and no other character's weight
     * changes.
     */
    private static void carry(KahluaTable api, KahluaTable formulas, IsoPlayer player, IsoGameCharacter other) {
        Object mod = call(api, "client", "carry.mod").get(0), second = call(api, "client", "carry.second").get(0);
        var mine = stock(player);
        stock(other);
        float vanilla = player.getInventoryWeight();
        check(near(vanilla, 30) && other.getInventoryWeight() == vanilla, "The game's weight is not 30: " + vanilla);
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0));
        check(near(player.getInventoryWeight(), 27.5) && other.getInventoryWeight() == vanilla,
            "Material at +100% did not halve the plank and the nails, or another character's weight changed: " + player.getInventoryWeight());
        // An item's efficiencies add: its category's and its type's.
        call(formulas, "set", mod, "carry.itemEfficiency", table("base:moveable", 1.0));
        check(near(player.getInventoryWeight(), 17.5), "The moveable type at +100% did not halve the sofa: " + player.getInventoryWeight());
        // The mods' efficiencies of one name add too: Material +150%, Furniture +100%; the sofa is at +200% in all.
        call(formulas, "set", second, "carry.categoryEfficiency", table("Material", 0.5, "Furniture", 1.0));
        var both = (KahluaTable)call(formulas, "get", "carry.categoryEfficiency").get(0);
        check(near((Double)both.rawget("Material"), 1.5) && near((Double)both.rawget("Furniture"), 1.0), "Two mods' efficiencies of a name did not add");
        check(near(player.getInventoryWeight(), 3 / 2.5 + 2 + 20 / 3.0 + 1.5 + (1 + 4 * 0.5 / 2.5 + 0.5)),
            "Added efficiencies: " + player.getInventoryWeight());
        call(second, "clear");
        call(formulas, "set", mod, "carry.itemEfficiency", null);
        // What is inside a bag with a tag counts by the number: a key ring's keys weigh nothing.
        call(formulas, "set", mod, "carry.containerTagMultiplier", table("base:keyring", 0.0));
        check(near(player.getInventoryWeight(), 1.5 + 2 + 20 + 1.5 + (1 + 1.0 + 0.2)), "A key ring's keys still weigh: " + player.getInventoryWeight());
        // Equipped, the game's own count (half) holds, with the efficiency in it.
        player.wear(mine[0]);
        check(near(player.getInventoryWeight(), 0.75 + 2 + 20 + 1.5 + 2.2), "An equipped plank: " + player.getInventoryWeight());
        // A worn bag: the weight reduction takes weight off what is inside, not off the bag.
        player.wear(mine[4]);
        ((InventoryContainer)mine[4]).setWeightReduction(50);
        check(near(player.getInventoryWeight(), 0.75 + 2 + 20 + 1.5 + (0.5 + 1.2 * 0.5)), "An equipped bag: " + player.getInventoryWeight());
        // A bag on the hotbar: 70% of the whole.
        player.takeOff(mine[4]);
        mine[4].setAttachedSlot(1);
        check(near(player.getInventoryWeight(), 0.75 + 2 + 20 + 1.5 + 2.2 * 0.7), "A bag on the hotbar: " + player.getInventoryWeight());
        mine[4].setAttachedSlot(-1);
        player.takeOff(mine[0]);
        ((InventoryContainer)mine[4]).setWeightReduction(0);
        // A formula that reaches nothing the character carries leaves the game's weight (to the last bit of a float: the sum is a double's).
        call(formulas, "set", mod, "carry.containerTagMultiplier", null);
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Nothing", 1.0));
        check(near(player.getInventoryWeight(), vanilla), "A formula for a category nothing has changed the weight: " + player.getInventoryWeight());
        // The read queries: an item's factor, and its weight as the load counts it.
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0));
        check(near((Double)call(formulas, "efficiency", mine[0]).get(0), 0.5) && near((Double)call(formulas, "efficiency", mine[1]).get(0), 1)
            && near((Double)call(formulas, "weight", mine[0]).get(0), 1.5) && near((Double)call(formulas, "weight", mine[4]).get(0), 2.5)
            && near((Double)call(formulas, "weight", mine[1]).get(0), 2), "The read queries are wrong");
        rejects(formulas, "efficiency", "item must be an inventory item", 5.0);
        rejects(formulas, "set", "carry.itemEfficiency[base:nothing] is not an item type", mod, "carry.itemEfficiency", table("base:nothing", 1.0));
        rejects(formulas, "set", "carry.containerTagMultiplier[base:nothing] is not an item tag", mod, "carry.containerTagMultiplier",
            table("base:nothing", 0.0));
        rejects(formulas, "set", "[Material] must be a number from -0.9 to 100.0", mod, "carry.categoryEfficiency", table("Material", -1.0));
        rejects(formulas, "set", "must be a table of names to numbers", mod, "carry.categoryEfficiency", 1.0);
        rejects(formulas, "set", "must be named by strings", mod, "carry.categoryEfficiency", table(1.0, 1.0));
        call(mod, "clear");
        check(player.getInventoryWeight() == vanilla, "Clearing the formulas left the weight changed");
        player.inventory.items.clear();
        other.inventory.items.clear();
    }

    private static Formulas formulasObject() throws Exception {
        var field = GameApi.class.getDeclaredField("formulas");
        field.setAccessible(true);
        return (Formulas)field.get(null);
    }

    // ---- the account of the load, kept ----

    /**
     * What the load counts is kept, not worked out: with Material at +100% (its items weigh half) and key rings' items at half,
     * a stock of 27.35 whose every change (items added, taken out, moved, swapped, nested; a weight, an amount, a magazine, a
     * part changed in place; worn, held, on the hotbar) is followed by the difference, without one item looked at again; what
     * cannot be followed item by item is worked out once; and a long random sequence ends where a fresh pass over the inventory does.
     */
    private static void kept(KahluaTable api, KahluaTable formulas, IsoPlayer player, IsoGameCharacter other) throws Exception {
        Object mod = call(api, "client", "kept.mod").get(0);
        Formulas game = formulasObject();
        check(ApiHooks.weightTracked(), "The hooks that follow the weight did not go in: " + ApiHooks.hookStatus());
        var mine = stock(player);
        var bag = (InventoryContainer)mine[4];
        var ring = (InventoryContainer)mine[5];
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0));
        call(formulas, "set", mod, "carry.containerTagMultiplier", table("base:keyring", 0.5));
        stock(other);
        long visits = game.inventoryVisits(), rebuilds = game.inventoryRebuilds();
        float first = player.getInventoryWeight();
        check(near(first, 27.35), "The weight with the formulas: " + first);
        check(game.inventoryRebuilds() - rebuilds == 3 && game.inventoryVisits() - visits == 13,
            "The first question worked out the inventory, the bag and the ring: " + (game.inventoryRebuilds() - rebuilds) + " lists, "
            + (game.inventoryVisits() - visits) + " items");
        visits = game.inventoryVisits();
        rebuilds = game.inventoryRebuilds();
        check(near(other.getInventoryWeight(), 30), "Another character's weight is not the game's: " + other.getInventoryWeight());

        // A question with nothing changed is a few field reads: no item looked at, nothing allocated.
        float[] sink = { 0 };
        for (int index = 0; index < 50000; index++) sink[0] += player.getInventoryWeight();
        // The median of 5 rounds: one round alone may count the JIT's move of the measuring loop to C2 (see Allocations).
        long bytes = Allocations.median(5, () -> { for (int index = 0; index < 200000; index++) sink[0] += player.getInventoryWeight(); });
        check(game.inventoryVisits() == visits && game.inventoryRebuilds() == rebuilds, "A question with nothing changed looked at items");
        check(bytes < 4096, "A question with nothing changed allocated " + bytes + " bytes in 200000 calls");
        check(player.getInventoryWeight() == first && sink[0] > 0, "The weight changed with nothing changed");

        // Items added and taken out, in the character's list, in a bag, in a bag in a bag.
        var nail = item("Material", 0.5f);
        bag.getInventory().AddItem(nail);
        check(near(player.getInventoryWeight(), 27.6), "An item put in a bag: " + player.getInventoryWeight());
        bag.getInventory().Remove(nail);
        check(near(player.getInventoryWeight(), 27.35), "An item taken out of a bag: " + player.getInventoryWeight());
        var key = item("Key", 0.1f);
        ring.getInventory().AddItem(key);
        check(near(player.getInventoryWeight(), 27.4), "An item put in a bag in a bag: " + player.getInventoryWeight());
        ring.getInventory().Remove(key);
        check(near(player.getInventoryWeight(), 27.35), "An item taken out of a bag in a bag: " + player.getInventoryWeight());
        // Moved: a key from the ring (whose items count half) into the bag (whose do not), and a nail from the bag to the character.
        key = ring.getInventory().getItems().get(0);
        ring.getInventory().Remove(key);
        bag.getInventory().AddItem(key);
        check(near(player.getInventoryWeight(), 27.4), "A key moved from the ring to the bag: " + player.getInventoryWeight());
        nail = bag.getInventory().getItems().get(0);
        bag.getInventory().Remove(nail);
        player.inventory.AddItem(nail);
        check(near(player.getInventoryWeight(), 27.4), "A nail moved from the bag to the character: " + player.getInventoryWeight());
        // The whole ring, with its keys, from the bag to the character.
        bag.getInventory().Remove(ring);
        player.inventory.AddItem(ring);
        check(near(player.getInventoryWeight(), 27.4), "The ring moved out of the bag: " + player.getInventoryWeight());
        ring.getInventory().AddItem(item("Key", 0.1f));
        check(near(player.getInventoryWeight(), 27.45), "An item put in the ring, which is the character's now: " + player.getInventoryWeight());
        // Swapped in a list: the ring's first key and the bag's key, and swapped back.
        var swapKey = bag.getInventory().getItems().get(bag.getInventory().getItems().size() - 1);
        var ringKey = ring.getInventory().getItems().get(0);
        int last = bag.getInventory().getItems().size() - 1;
        ring.getInventory().getItems().set(0, swapKey);
        bag.getInventory().getItems().set(last, ringKey);
        check(near(player.getInventoryWeight(), 27.45), "Items swapped between a bag and a ring: " + player.getInventoryWeight());
        ring.getInventory().getItems().set(0, ringKey);
        bag.getInventory().getItems().set(last, swapKey);
        check(near(player.getInventoryWeight(), 27.45), "Items swapped back: " + player.getInventoryWeight());
        // Back where they were: the ring into the bag, the key into the ring, the nail into the bag.
        ring.getInventory().Remove(ring.getInventory().getItems().get(ring.getInventory().getItems().size() - 1));
        player.inventory.Remove(ring);
        bag.getInventory().AddItem(ring);
        bag.getInventory().Remove(swapKey);
        ring.getInventory().AddItem(swapKey);
        player.inventory.Remove(nail);
        bag.getInventory().AddItem(nail);
        check(near(player.getInventoryWeight(), 27.35), "Everything back: " + player.getInventoryWeight());
        check(game.inventoryVisits() == visits && game.inventoryRebuilds() == rebuilds,
            "Adding, taking out, moving and swapping looked at items: " + (game.inventoryVisits() - visits) + ", " + (game.inventoryRebuilds() - rebuilds));

        // Weights that change where the item stands: its own, what it holds, a food's, a fluid's, a weapon's parts and magazine.
        long settled = game.inventorySettled();
        float base = player.getInventoryWeight();
        nail.setActualWeight(2f);
        check(near(player.getInventoryWeight(), base + 0.75), "A weight that changed in place: " + player.getInventoryWeight());
        nail.setActualWeight(0.5f);
        mine[3].setCurrentAmmoCount(5);
        check(near(player.getInventoryWeight(), base + 0.5), "An item that holds something: " + player.getInventoryWeight());
        mine[3].setCurrentAmmoCount(0);
        var food = new Food(null);
        food.setBaseHunger(-4f);
        food.setHungChange(-4f);
        bag.getInventory().AddItem(food);
        check(near(player.getInventoryWeight(), base + 1), "A food: " + player.getInventoryWeight());
        food.setHungChange(-1f);
        check(near(player.getInventoryWeight(), base + 0.25), "A food eaten: " + player.getInventoryWeight());
        food.burn();
        check(near(player.getInventoryWeight(), base + 0.25), "A food that burnt: " + player.getInventoryWeight());
        var water = new FluidContainer(5, 2);
        mine[1].setFluid(water);
        check(near(player.getInventoryWeight(), base + 0.25 + 2), "A fluid: " + player.getInventoryWeight());
        water.adjustAmount(-1.5f);
        check(near(player.getInventoryWeight(), base + 0.25 + 0.5), "A fluid drunk: " + player.getInventoryWeight());
        mine[1].setFluid(null);
        check(near(player.getInventoryWeight(), base + 0.25), "A fluid gone: " + player.getInventoryWeight());
        var rifle = new HandWeapon(3f);
        player.inventory.AddItem(rifle);
        check(near(player.getInventoryWeight(), base + 0.25 + 3), "A weapon: " + player.getInventoryWeight());
        rifle.setWeaponPart("scope", new WeaponPart(0.5f));
        check(near(player.getInventoryWeight(), base + 0.25 + 3.5), "A part attached: " + player.getInventoryWeight());
        rifle.setRoundChambered(true);
        check(near(player.getInventoryWeight(), base + 0.25 + 4.5), "A round chambered: " + player.getInventoryWeight());
        rifle.setContainsClip(true);
        rifle.setMagazineType("Base.Mag");
        check(near(player.getInventoryWeight(), base + 0.25 + 5.5), "A magazine: " + player.getInventoryWeight());
        rifle.clearAllWeaponParts();
        check(near(player.getInventoryWeight(), base + 0.25 + 5), "The parts taken off: " + player.getInventoryWeight());
        var packet = new ItemStatsPacket();
        var meal = new Food(null);
        meal.setBaseHunger(-1f);
        meal.setHungChange(-1f);
        player.inventory.AddItem(meal);
        float withMeal = player.getInventoryWeight();
        packet.apply(meal, new ArrayList<>(List.of("Base.Salt")));
        // What a packet's extra items weigh is the game's to say (nothing, here); that the change is seen is what is checked: no failure, no drift.
        check(player.getInventoryWeight() == withMeal, "A packet's extra items changed the weight in the synthetic game");
        player.inventory.Remove(meal);
        player.inventory.Remove(rifle);
        bag.getInventory().Remove(food);
        check(near(player.getInventoryWeight(), base), "The weapon, the meal and the food taken out: " + player.getInventoryWeight());
        check(game.inventoryVisits() == visits && game.inventoryRebuilds() == rebuilds && game.inventorySettled() > settled,
            "Changes in place were not settled one by one: " + (game.inventoryVisits() - visits) + " items, " + (game.inventoryRebuilds() - rebuilds)
            + " lists, " + (game.inventorySettled() - settled) + " changes");

        // Worn, held, on the hotbar: the game's own count (half, or 70%), with the efficiency in it.
        player.wear(mine[0]);
        check(near(player.getInventoryWeight(), 26.6), "A worn plank: " + player.getInventoryWeight());
        player.setPrimaryHandItem(mine[3]);
        check(near(player.getInventoryWeight(), 25.85), "A tool in the hand: " + player.getInventoryWeight());
        mine[1].setAttachedSlot(2);
        check(near(player.getInventoryWeight(), 25.25), "An item on the hotbar: " + player.getInventoryWeight());
        player.setPrimaryHandItem(mine[1]);
        check(near(player.getInventoryWeight(), 25.6), "An item on the hotbar that is also in the hand: " + player.getInventoryWeight());
        player.setPrimaryHandItem(null);
        mine[1].setAttachedSlot(-1);
        player.takeOff(mine[0]);
        check(near(player.getInventoryWeight(), 27.35), "Everything off: " + player.getInventoryWeight());
        // Worn, then the list of what is worn is another one.
        player.wear(mine[0]);
        check(near(player.getInventoryWeight(), 26.6), "Worn again: " + player.getInventoryWeight());
        player.setWornItems(new WornItems());
        check(near(player.getInventoryWeight(), 27.35), "Another list of worn items: " + player.getInventoryWeight());
        // A worn bag takes weight off its items, and its items count to it all the same.
        bag.equipParent = player;
        player.wear(bag);
        bag.setWeightReduction(50);
        check(near(player.getInventoryWeight(), 27.35 - 2.35 + 0.5 + 1.35 * 0.5), "A worn bag: " + player.getInventoryWeight());
        bag.setWeightReduction(0);
        player.takeOff(bag);
        bag.equipParent = null;
        check(game.inventoryVisits() == visits && game.inventoryRebuilds() == rebuilds, "Worn, held and hotbar changes looked at items");

        // What cannot be followed item by item is worked out once, for the list and the lists it is in.
        long before = game.inventoryRebuilds();
        bag.getInventory().getItems().removeIf(each -> each.getDisplayCategory().equals("Material"));
        check(near(player.getInventoryWeight(), 27.35 - 1.0), "The nails taken out by a filter: " + player.getInventoryWeight());
        check(game.inventoryRebuilds() == before + 2, "A filter worked out " + (game.inventoryRebuilds() - before) + " lists, not the bag and the character's");
        before = game.inventoryRebuilds();
        player.getInventoryWeight();
        check(game.inventoryRebuilds() == before, "A list worked out once was worked out again");
        // Emptied: followed, not worked out again.
        ring.getInventory().getItems().clear();
        check(near(player.getInventoryWeight(), 27.35 - 1.0 - 0.15), "A ring emptied: " + player.getInventoryWeight());
        check(game.inventoryRebuilds() == before, "A list emptied was worked out again");
        // The container has another list: setItems and emptyIt.
        var inside = new ArrayList<InventoryItem>();
        inside.add(item("Tool", 3f));
        bag.getInventory().setItems(inside);
        check(near(player.getInventoryWeight(), 29), "A bag's list replaced: " + player.getInventoryWeight());
        bag.getInventory().emptyIt();
        check(near(player.getInventoryWeight(), 26), "A bag emptied by emptyIt: " + player.getInventoryWeight());
        // Put back what the tests took: the bag holds its nails, the ring and the keys again.
        for (int index = 0; index < 4; index++) bag.getInventory().AddItem(item("Material", 0.5f));
        bag.getInventory().AddItem(ring);
        for (int index = 0; index < 3; index++) ring.getInventory().AddItem(item("Key", 0.1f));
        check(near(player.getInventoryWeight(), 27.35), "The stock back: " + player.getInventoryWeight());

        // A list put into by the list itself (a mod's getItems().add): the weight is right at once, and an item's change later too.
        var loose = item("Tool", 1f);
        bag.getInventory().getItems().add(loose);
        check(near(player.getInventoryWeight(), 28.35), "An item put in through the list: " + player.getInventoryWeight());
        long settledBefore = game.inventorySettled();
        loose.setActualWeight(4f);
        check(near(player.getInventoryWeight(), 31.35) && game.inventorySettled() > settledBefore, "An item put in through the list changed in place: " + player.getInventoryWeight());
        bag.getInventory().getItems().remove(loose);
        check(near(player.getInventoryWeight(), 27.35), "An item taken out through the list: " + player.getInventoryWeight());

        // The declarations: any change works every list out again, once.
        before = game.inventoryRebuilds();
        long beforeVisits = game.inventoryVisits();
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 3.0));
        float quartered = player.getInventoryWeight();
        check(near(quartered, 1.5 / 2 + 2 + 20 + 1.5 + (1 + 4 * 0.5 / 4 + 0.2 + 0.3 * 0.5)), "Another efficiency: " + quartered);
        check(game.inventoryRebuilds() == before + 3 && game.inventoryVisits() - beforeVisits == 5 + 5 + 3,
            "A declaration changed: " + (game.inventoryRebuilds() - before) + " lists and " + (game.inventoryVisits() - beforeVisits) + " items worked out");
        before = game.inventoryRebuilds();
        player.getInventoryWeight();
        check(game.inventoryRebuilds() == before, "The lists were worked out after the first question after the change");
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0));
        player.getInventoryWeight();

        // A container made before the hooks (here: given a plain list) is followed from the first question on.
        var late = new InventoryContainer("Bag", 1f, 30);
        late.getInventory().items = new ArrayList<>();
        late.getInventory().items.add(item("Tool", 2f));
        player.inventory.AddItem(late);
        check(near(player.getInventoryWeight(), 27.35 + 3), "A bag with a plain list: " + player.getInventoryWeight());
        check((Object)late.getInventory().items instanceof Tracked, "The plain list was not replaced by a tracked one");
        late.getInventory().AddItem(item("Tool", 1f));
        check(near(player.getInventoryWeight(), 27.35 + 4), "An item put into the bag whose list was replaced: " + player.getInventoryWeight());
        player.inventory.Remove(late);

        // The character's own list replaced, and a character that is not the player's.
        check(near(other.getInventoryWeight(), 30), "Another character's weight is not the game's: " + other.getInventoryWeight());
        check(near(player.getInventoryWeight(), 27.35), "The weight changed after the late bag was taken out: " + player.getInventoryWeight());
        call(mod, "clear");
        check(near(player.getInventoryWeight(), 30), "Clearing the formulas left the weight changed: " + player.getInventoryWeight());

        random(formulas, mod, player);
        moves(formulas, mod, player);
        call(mod, "clear");
        player.inventory.removeAllItems();
        other.inventory.removeAllItems();
        clearEquipment(player);
    }

    // ---- a fresh pass, for the random test ----

    private static float factorOf(InventoryItem item) { return item.getDisplayCategory().equals("Material") ? 0.5f : 1f; }

    /** The weight an item adds to its list with nothing equipped: the formulas applied the way the load defines them, by a pass over the items. */
    private static float freshPlain(InventoryItem item) {
        if (!(item instanceof InventoryContainer bag)) return item.getUnequippedWeight() * factorOf(item);
        double inner = 0;
        for (InventoryItem each : bag.getInventory().items) inner += freshPlain(each);
        float own = bag.getActualWeight() * factorOf(bag);
        return (float)(own + inner * (bag.hasTag(ItemTag.KEY_RING) ? 0.5f : 1f));
    }

    private static float freshBody(IsoGameCharacter character, InventoryItem item) {
        boolean equipped = character.isEquipped(item);
        boolean hotbar = item.getAttachedSlot() > -1 && !equipped;
        if (!hotbar && !equipped) return freshPlain(item);
        float vanilla = hotbar ? item.getHotbarEquippedWeight() : item.getEquippedWeight();
        if (!(item instanceof InventoryContainer bag)) return factorOf(item) == 1f ? vanilla : vanilla * factorOf(item);
        float whole = freshPlain(bag);
        if (whole == bag.getUnequippedWeight()) return vanilla;
        if (hotbar) return bag.getUnequippedWeight() == 0f ? vanilla : whole * (vanilla / bag.getUnequippedWeight());
        float own = bag.getActualWeight() * factorOf(bag);
        int reduction = bag.getWeightReduction();
        float taken = reduction > 0 ? 1 - reduction / 100f : 1f;
        return own * (float)zombie.ZomboidGlobals.equippedOrWornEncumbranceMultiplier + (whole - own) * taken;
    }

    private static float freshTotal(IsoGameCharacter character) {
        double sum = 0;
        for (InventoryItem each : character.inventory.items) sum += freshBody(character, each);
        return (float)sum;
    }

    private static void collect(ItemContainer container, List<InventoryItem[]> into) {
        for (InventoryItem each : container.items) {
            into.add(new InventoryItem[] { each, null });
            if (each instanceof InventoryContainer bag) collect(bag.getInventory(), into);
        }
    }

    private static boolean inside(InventoryItem outer, ItemContainer container) {
        if (!(outer instanceof InventoryContainer bag)) return false;
        if (bag.getInventory() == container) return true;
        for (InventoryItem each : bag.getInventory().items) if (inside(each, container)) return true;
        return false;
    }

    /**
     * Ten thousand random changes (items made, taken out, moved from any container to any other, nested bags, weights, amounts,
     * what is worn, held and on the hotbar, now and then a filter or a clear), and after each the weight is the fresh pass's, to the bit.
     */
    private static void random(KahluaTable formulas, Object mod, IsoPlayer player) throws Exception {
        Formulas game = formulasObject();
        player.inventory.removeAllItems();
        clearEquipment(player);
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0));
        call(formulas, "set", mod, "carry.containerTagMultiplier", table("base:keyring", 0.5));
        var random = new java.util.Random(20260509);
        String[] categories = { "Material", "Tool", "Paint", "Key", "Food" };
        for (int index = 0; index < 24; index++) {
            if (index % 6 == 0) {
                var bag = new InventoryContainer("Bag", 0.5f + random.nextInt(4) * 0.25f, 50);
                if (random.nextBoolean()) bag.tags.add(ItemTag.KEY_RING);
                put(player, bag);
            } else put(player, new InventoryItem(categories[random.nextInt(categories.length)], 0.01f + random.nextInt(500) / 100f));
        }
        player.getInventoryWeight();
        long rebuilds = game.inventoryRebuilds(), visits = game.inventoryVisits();
        int[] counts = new int[16];
        for (int step = 0; step < 10000; step++) {
            var all = new ArrayList<InventoryItem[]>();
            collect(player.inventory, all);
            var containers = new ArrayList<ItemContainer>();
            containers.add(player.inventory);
            for (var entry : all) if (entry[0] instanceof InventoryContainer bag) containers.add(bag.getInventory());
            InventoryItem pick = all.isEmpty() ? null : all.get(random.nextInt(all.size()))[0];
            ItemContainer target = containers.get(random.nextInt(containers.size()));
            int operation = random.nextInt(16);
            counts[operation]++;
            switch (operation) {
                case 0, 1 -> {
                    InventoryItem made;
                    if (random.nextInt(8) == 0) {
                        var bag = new InventoryContainer("Bag", 0.5f, 50);
                        if (random.nextBoolean()) bag.tags.add(ItemTag.KEY_RING);
                        made = bag;
                    } else if (random.nextInt(8) == 0) {
                        var meal = new Food(null);
                        meal.setBaseHunger(-4f);
                        meal.setHungChange(-4f + random.nextInt(4));
                        made = meal;
                    } else made = new InventoryItem(categories[random.nextInt(categories.length)], 0.01f + random.nextInt(500) / 100f);
                    target.AddItem(made);
                }
                case 2 -> { if (pick != null && pick.container != null) pick.container.Remove(pick); }
                case 3, 4, 5 -> {
                    if (pick != null && pick.container != null && !inside(pick, target) && target != pick.container) {
                        pick.container.Remove(pick);
                        target.AddItem(pick);
                    }
                }
                case 6 -> { if (pick != null) pick.setActualWeight(0.01f + random.nextInt(800) / 100f); }
                case 7 -> { if (pick != null) pick.setCurrentAmmoCount(random.nextInt(30)); }
                case 8 -> {
                    var top = player.inventory.items;
                    if (!top.isEmpty()) {
                        InventoryItem item = top.get(random.nextInt(top.size()));
                        if (player.isEquipped(item)) player.takeOff(item);
                        else player.wear(item);
                    }
                }
                case 9 -> {
                    var top = player.inventory.items;
                    if (!top.isEmpty()) player.setPrimaryHandItem(random.nextInt(3) == 0 ? null : top.get(random.nextInt(top.size())));
                }
                case 10 -> {
                    var top = player.inventory.items;
                    if (!top.isEmpty()) top.get(random.nextInt(top.size())).setAttachedSlot(random.nextBoolean() ? -1 : random.nextInt(4));
                }
                case 11 -> { if (pick instanceof Food meal) meal.setHungChange(-random.nextInt(5)); else if (pick != null) pick.setCustomWeight(random.nextBoolean()); }
                case 12 -> {
                    if (pick != null && pick.fluid == null && random.nextInt(4) == 0) pick.setFluid(new FluidContainer(5, random.nextInt(5)));
                    else if (pick != null && pick.fluid != null) pick.fluid.adjustAmount(random.nextBoolean() ? -0.25f : 0.25f);
                }
                case 13 -> { if (pick instanceof InventoryContainer bag) bag.setWeightReduction(random.nextInt(4) * 25); }
                case 14 -> {
                    if (random.nextInt(25) == 0 && target != player.inventory) {
                        if (random.nextBoolean()) target.getItems().removeIf(each -> each.getDisplayCategory().equals("Paint"));
                        else target.removeAllItems();
                    } else if (target.getItems().size() > 1) Collections.swap(target.getItems(), 0, target.getItems().size() - 1);
                }
                default -> { if (pick != null && pick.container != null && random.nextInt(4) == 0) pick.setActualWeight(pick.actualWeight); }
            }
            float expected = freshTotal(player), got = player.getInventoryWeight();
            if (got != expected) throw new AssertionError("Step " + step + " (operation " + operation + "): the kept weight is " + got + ", a fresh pass gives " + expected);
        }
        long worked = game.inventoryRebuilds() - rebuilds;
        var last = new ArrayList<InventoryItem[]>();
        collect(player.inventory, last);
        System.out.printf("[formulas] 10000 random changes (%d items at the end, %d at the top): kept weight == fresh pass every time; "
            + "%d lists worked out again, %d items looked at%n", last.size(), player.inventory.items.size(), worked, game.inventoryVisits() - visits);
        check(worked < 800, "The random changes worked out " + worked + " lists");
        player.inventory.removeAllItems();
    }

    /** 3000 items moved one by one from one bag to another, the character's capacity asked after each. */
    private static void moves(KahluaTable formulas, Object mod, IsoPlayer player) throws Exception {
        Formulas game = formulasObject();
        player.inventory.removeAllItems();
        clearEquipment(player);
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0));
        var from = new InventoryContainer("Bag", 1f, 50);
        var to = new InventoryContainer("Bag", 1f, 50);
        put(player, from);
        put(player, to);
        var moved = new ArrayList<InventoryItem>();
        for (int index = 0; index < 3000; index++) moved.add(from.getInventory().AddItem(item("Material", 0.002f)));
        var probe = item("Tool", 0.5f);
        long first = game.inventoryVisits();
        float full = player.getInventoryWeight();
        long visits = game.inventoryVisits(), rebuilds = game.inventoryRebuilds(), worked = game.inventoryWorked();
        int fits = 0;
        long start = System.nanoTime();
        for (InventoryItem each : moved) {
            from.getInventory().Remove(each);
            to.getInventory().AddItem(each);
            if (player.inventory.hasRoomFor(player, probe)) fits++;
            if (Math.abs(player.getInventoryWeight() - full) > 1e-3) throw new AssertionError("The weight changed by a move: " + player.getInventoryWeight());
        }
        long elapsed = System.nanoTime() - start;
        check(fits == 3000, "The character's capacity said no for a move");
        check(game.inventoryVisits() == visits && game.inventoryRebuilds() == rebuilds,
            "Moving 3000 items worked lists out again: " + (game.inventoryVisits() - visits) + " items, " + (game.inventoryRebuilds() - rebuilds) + " lists");
        worked = game.inventoryWorked() - worked;
        System.out.printf("[formulas] 3000 items moved one by one with a capacity question each: %.2f us a move, %d items looked at, %d lists worked out, "
            + "%d item weights worked out (%.1f a move)%n", elapsed / 1000.0 / 3000, game.inventoryVisits() - visits, game.inventoryRebuilds() - rebuilds,
            worked, worked / 3000.0);
        check(worked <= 3000 * 4, "A move worked out " + worked / 3000.0 + " item weights");
        // The same moves when the declarations change on every move: each question works the lists out, so the cost shows what the account saves.
        var again = new ArrayList<>(moved);
        long cold = System.nanoTime();
        for (int index = 0; index < 60; index++) {
            call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0 + (index % 7) * 0.1));
            player.getInventoryWeight();
        }
        cold = System.nanoTime() - cold;
        System.out.printf("[formulas] a question after a change of the declarations (3003 items worked out): %.1f us%n", cold / 1000.0 / 60);
        again.clear();
        player.inventory.removeAllItems();
    }

    /** Whether an item fits: what it adds is counted by the same efficiency, against the character who would carry it. */
    private static void room(KahluaTable api, KahluaTable formulas, IsoPlayer player, IsoGameCharacter other) {
        Object mod = call(api, "client", "room.mod").get(0);
        player.inventory.items.clear();
        other.inventory.items.clear();
        clearEquipment(player);
        put(player, item("Tool", 45f));
        put(other, item("Tool", 45f));
        var incoming = item("Material", 10f);
        check(!player.inventory.hasRoomFor(player, incoming) && !other.inventory.hasRoomFor(other, incoming), "10 more than 45 of 50 fit");
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0));
        check(player.inventory.hasRoomFor(player, incoming), "An item at half its weight did not fit");
        check(!other.inventory.hasRoomFor(other, incoming), "An item fit another character at half its weight");
        // A worn bag: against the carrier's inventory by efficiency, against the bag's own room by the real weight.
        player.inventory.items.clear();
        put(player, item("Tool", 10f));
        var bag = new InventoryContainer("Bag", 1f, 30);
        put(player, bag);
        bag.equipParent = player;
        player.wear(bag);
        check(bag.getInventory().hasRoomFor(player, item("Material", 29f)), "An item that fits the bag did not fit");
        check(!bag.getInventory().hasRoomFor(player, item("Material", 31f)), "An item fit a bag by less than its real weight");
        player.inventory.items.clear();
        put(player, item("Tool", 44f));
        put(player, bag);
        check(bag.getInventory().hasRoomFor(player, incoming), "Half an item did not fit the carrier's inventory");
        call(formulas, "set", mod, "carry.categoryEfficiency", null);
        check(!bag.getInventory().hasRoomFor(player, incoming), "The whole item fit the carrier's inventory");
        // A container that is not a character's: the real weight.
        call(formulas, "set", mod, "carry.categoryEfficiency", table("Material", 1.0));
        var crate = new ItemContainer(new IsoObject(null));
        crate.capacity = 9;
        check(!crate.hasRoomFor(player, incoming), "A crate counted an item at its efficiency");
        crate.worldItem = true;
        incoming.onGround = true;
        check(!crate.hasRoomFor(player, incoming), "A crate on the ground counted an item at its efficiency");
        call(mod, "clear");
        player.inventory.items.clear();
        other.inventory.items.clear();
        clearEquipment(player);
    }

    /** The most a character carries, what a container holds and the limits of the game that a container may declare away. */
    private static void capacities(KahluaTable api, KahluaTable formulas, IsoPlayer player, IsoGameCharacter other) {
        Object mod = call(api, "client", "capacity.mod").get(0), second = call(api, "client", "capacity.second").get(0);
        check(player.getMaxWeight() == 20 && other.getMaxWeight() == 20, "The most carried is not the game's");
        call(formulas, "set", mod, "capacity.maxWeightAdd", 4.0);
        call(formulas, "set", second, "capacity.maxWeightAdd", 2.0);
        check(player.getMaxWeight() == 26 && other.getMaxWeight() == 20 && player.inventory.getMaxWeight() == 26f,
            "The most carried was not added to for the local player alone: " + player.getMaxWeight());
        call(second, "clear");
        call(mod, "clear");
        check(player.getMaxWeight() == 20, "The most carried stayed added to");

        // What a container holds: the game's trait multiplier first, the formula's after it; not a corpse, the floor, a
        // character's inventory or a bag.
        var crate = new ItemContainer(new IsoObject(null));
        crate.capacity = 60;
        var body = new ItemContainer(new IsoDeadBody());
        body.capacity = 60;
        var floor = new ItemContainer(new IsoObject(null));
        floor.capacity = 60;
        floor.type = "floor";
        var bag = new InventoryContainer("Bag", 1f, 30);
        check(crate.getEffectiveCapacity(player) == 60, "A container's capacity is not the game's");
        call(formulas, "set", mod, "capacity.effectiveMultiplier", 1.5);
        call(formulas, "set", second, "capacity.effectiveMultiplier", 1.2);
        check(crate.getEffectiveCapacity(player) == 108 && crate.getEffectiveCapacity(other) == 60 && crate.getEffectiveCapacity(null) == 60,
            "A container's capacity was not multiplied for the local player alone: " + crate.getEffectiveCapacity(player));
        check(body.getEffectiveCapacity(player) == 60 && floor.getEffectiveCapacity(player) == 60
            && player.inventory.getEffectiveCapacity(player) == 50 && bag.getInventory().getEffectiveCapacity(player) == 30,
            "The capacity of a corpse, the floor, a character or a bag was multiplied");
        player.organized = true;
        check(crate.getEffectiveCapacity(player) == 140, "The trait multiplier and the formula: " + crate.getEffectiveCapacity(player));
        player.organized = false;
        call(second, "clear");
        call(mod, "clear");
        check(crate.getEffectiveCapacity(player) == 60, "The capacity stayed multiplied");

        // The character's own inventory limit.
        call(formulas, "set", mod, "capacity.characterLimitAdd", 18.0);
        check(player.inventory.getEffectiveCapacity(player) == 68 && other.inventory.getEffectiveCapacity(other) == 50
            && crate.getEffectiveCapacity(player) == 60, "The limit of the character's inventory: " + player.inventory.getEffectiveCapacity(player));
        call(mod, "clear");

        // The game's limits are 100 for a container, 50 for an item's, 1000 for a vehicle part's. A container that declares a key
        // in the modData of what holds it is not held to them; any other is.
        crate.capacity = 300;
        var other_crate = new ItemContainer(new IsoObject(null));
        other_crate.capacity = 300;
        var trunk = new ItemContainer(null);
        trunk.capacity = 1500;
        var part = new VehiclePart();
        trunk.vehiclePart = part;
        var seat = new ItemContainer(null);
        seat.capacity = 800;
        seat.vehicleSeat = true;
        seat.seatOccupied = true;
        var seatPart = new VehiclePart();
        seat.vehiclePart = seatPart;
        var kit = new InventoryContainer("Bag", 1f, 60);
        var plain = new InventoryContainer("Bag", 1f, 60);
        check(crate.getCapacity() == 100 && trunk.getCapacity() == 1000 && kit.getInventory().getCapacity() == 50 && kit.getCapacity() == 49
            && seat.getCapacity() == 200, "The game's limits are not the game's");
        call(formulas, "set", mod, "capacity.modDataKey", "MyMod_CapacityAdd");
        check(crate.getCapacity() == 100 && trunk.getCapacity() == 1000 && kit.getCapacity() == 49, "A key nobody declares in changed a capacity");
        crate.parent.getModData().rawset("MyMod_CapacityAdd", 0.0);
        part.getModData().rawset("MyMod_CapacityAdd", 250.0);
        kit.getModData().rawset("MyMod_CapacityAdd", 20.0);
        seatPart.getModData().rawset("MyMod_CapacityAdd", 25.0);
        check(crate.getCapacity() == 300 && other_crate.getCapacity() == 100, "A container that declares was not lifted, or another was");
        check(crate.getEffectiveCapacity(player) == 300, "The effective capacity of a lifted container: " + crate.getEffectiveCapacity(player));
        check(trunk.getCapacity() == 1750 && seat.getCapacity() == 225, "A vehicle part's key: " + trunk.getCapacity() + ", " + seat.getCapacity());
        // A bag that declares is lifted past its own clamp (50 less its weight) too.
        check(kit.getInventory().getCapacity() == 80 && kit.getCapacity() == 80 && kit.getEffectiveCapacity(player) == 80
            && plain.getCapacity() == 49 && plain.getEffectiveCapacity(player) == 49, "A bag's kit: " + kit.getCapacity());
        // A second mod's key joins the first's; a key without a number is not a declaration.
        call(formulas, "set", second, "capacity.modDataKey", list("MyMod_Other", "MyMod_CapacityAdd"));
        other_crate.parent.getModData().rawset("MyMod_Other", "yes");
        check(other_crate.getCapacity() == 100, "A key that is not a number lifted a container");
        other_crate.parent.getModData().rawset("MyMod_Other", 5.0);
        check(other_crate.getCapacity() == 305, "A second mod's key did not lift: " + other_crate.getCapacity());
        check(((KahluaTable)call(formulas, "get", "capacity.modDataKey").get(0)).len() == 2, "The keys of two mods did not join");
        call(mod, "clear");
        call(second, "clear");
        check(crate.getCapacity() == 100 && kit.getCapacity() == 49 && trunk.getCapacity() == 1000, "The capacity stayed lifted");
        rejects(formulas, "set", "must be a string or a list of strings", mod, "capacity.modDataKey", 1.0);
    }

    /** How heavily a character is loaded, as the moodle, the path speed and the fall damage ask it. */
    private static void loads(KahluaTable api, KahluaTable formulas, IsoPlayer player, IsoGameCharacter other) {
        Object mod = call(api, "client", "overload.mod").get(0);
        var moodle = new Moodle(player);
        var otherMoodle = new Moodle(other);
        player.inventory.items.clear();
        other.inventory.items.clear();
        put(player, item("Tool", 30f));
        put(other, item("Tool", 30f));
        player.heavyLoad = 1;
        moodle.Update();
        player.landing();
        check(near(moodle.ratio, 1.5) && near(player.getPathSpeed(), 0.825) && near(player.landing[0], 1.5) && near(player.landing[1], 30),
            "The game's load: " + moodle.ratio);
        call(formulas, "set", mod, "overload.compress", 0.6);
        // 20 + (30 - 20) x 0.4 = 24, in the moodle, the path speed and the questions of the fall.
        moodle.Update();
        otherMoodle.Update();
        player.landing();
        check(near(moodle.ratio, 1.2) && near(otherMoodle.ratio, 1.5), "The moodle's load was not compressed for the local player alone: " + moodle.ratio);
        check(near(player.getPathSpeed(), 0.65 + 0.35 * 0.8), "The path speed's load: " + player.getPathSpeed());
        check(near(player.landing[0], 1.2) && near(player.landing[1], 24), "The fall's load: " + player.landing[0] + ", " + player.landing[1]);
        // Within the most there is nothing to compress; and the most is the one the character has now.
        player.inventory.items.clear();
        put(player, item("Tool", 15f));
        moodle.Update();
        check(near(moodle.ratio, 0.75), "A load within the most was compressed: " + moodle.ratio);
        call(formulas, "set", mod, "capacity.maxWeightAdd", 5.0);
        player.inventory.items.clear();
        put(player, item("Tool", 30f));
        moodle.Update();
        check(near(moodle.ratio, (25 + 5 * 0.4) / 25), "The most carried added to is not the most compressed from: " + moodle.ratio);
        call(mod, "clear");
        moodle.Update();
        check(near(moodle.ratio, 1.5), "The load stayed compressed");
        rejects(formulas, "set", "overload.compress must be a number from 0.0 to 1.0", mod, "overload.compress", 1.5);
        player.heavyLoad = 0;
        player.inventory.items.clear();
        other.inventory.items.clear();
    }

    /** What equipment takes off the speeds: the part of a penalty a formula takes away, and no bonus. */
    private static void speeds(KahluaTable api, KahluaTable formulas, IsoPlayer player, IsoGameCharacter other) {
        Object mod = call(api, "client", "speed.mod").get(0), second = call(api, "client", "speed.second").get(0);
        player.bagsRunModifier = other.bagsRunModifier = 0.8f;
        check(near(player.calculateBaseSpeed(), 0.8 * 0.9), "The game's speed");
        call(formulas, "set", mod, "move.runPenaltyReduction", 0.5);
        check(near(player.calculateBaseSpeed(), 0.8 * 0.95) && near(player.fullSpeedMod(), 0.9) && near(other.calculateBaseSpeed(), 0.8 * 0.9),
            "A penalty was not halved for the local player alone: " + player.calculateBaseSpeed());
        // Two reductions: what is left of the penalty multiplies, 0.5 x 0.5.
        call(formulas, "set", second, "move.runPenaltyReduction", 0.5);
        check(near(player.calculateBaseSpeed(), 0.8 * 0.975) && near(player.fullSpeedMod(), 0.95), "Two reductions: " + player.calculateBaseSpeed());
        check(near((Double)call(formulas, "get", "move.runPenaltyReduction").get(0), 0.75), "Two reductions combine as "
            + call(formulas, "get", "move.runPenaltyReduction").get(0));
        call(second, "clear");
        player.bagsRunModifier = 1.2f;
        check(near(player.calculateBaseSpeed(), 0.8 * 0.9), "A bonus was reduced: " + player.calculateBaseSpeed());
        call(mod, "clear");

        player.setCombatSpeedModifier(0.9f);
        other.setCombatSpeedModifier(0.9f);
        check(near(player.calculateCombatSpeed(), 0.9), "The game's combat speed");
        call(formulas, "set", mod, "move.combatPenaltyReduction", 0.5);
        check(near(player.calculateCombatSpeed(), 0.95) && near(other.calculateCombatSpeed(), 0.9), "The combat penalty was not halved for the local player alone");
        player.setCombatSpeedModifier(1.2f);
        check(near(player.calculateCombatSpeed(), 1.2), "A combat bonus was reduced");
        call(mod, "clear");
        player.setCombatSpeedModifier(1f);
        other.setCombatSpeedModifier(1f);
        player.bagsRunModifier = other.bagsRunModifier = 1f;
    }

    /** A point whose hook is missing says so, and the other hooks of the class stay. */
    private static void partial(KahluaTable formulas) throws Exception {
        Method transform = ApiHooks.class.getDeclaredMethod("transform", String.class, byte[].class, ClassLoader.class);
        transform.setAccessible(true);
        ClassLoader game = FormulasTest.class.getClassLoader();
        String container = "zombie/inventory/ItemContainer";
        byte[] own;
        try (var input = game.getResourceAsStream(container + ".class")) { own = input.readAllBytes(); }
        var files = ClassFile.of();
        byte[] without = files.transformClass(files.parse(own), ClassTransform.dropping(element ->
            element instanceof MethodModel method && method.methodName().equalsString("hasRoomFor")
                && method.methodType().stringValue().equals("(Lzombie/characters/IsoGameCharacter;Lzombie/inventory/InventoryItem;)Z")));
        check(transform.invoke(null, container, without, game) != null, "The container's other hooks were lost with one");
        var points = (KahluaTable)call(formulas, "points").get(0);
        check(points.rawget("carry.categoryEfficiency") instanceof String text && text.startsWith("partial: ItemContainer.hasRoomFor: expected one hasRoomFor"),
            "A point with one hook missing is " + points.rawget("carry.categoryEfficiency"));
        check(ApiHooks.APPLIED.equals(points.rawget("capacity.characterLimitAdd")), "A point of another hook of the class: " + points.rawget("capacity.characterLimitAdd"));
        transform.invoke(null, container, own, game);
        points = (KahluaTable)call(formulas, "points").get(0);
        check(ApiHooks.APPLIED.equals(points.rawget("carry.categoryEfficiency")), "The point did not come back: " + points.rawget("carry.categoryEfficiency"));
    }

    /** A hook that cannot answer gives the game's answer, and the API keeps running. */
    private static void faults(KahluaTable api, KahluaTable formulas, IsoPlayer player) throws Exception {
        Object mod = call(api, "client", "fault.mod").get(0);
        player.clothingDiscomfortModifier = 3f;
        call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        check(player.getClothingDiscomfortModifier() == 1.5f, "The formula does not apply");
        ApiHooks.setFormulas(new ApiHooks.Formulas() {
            @Override public float discomfort(float vanilla, Object character) { throw new IllegalStateException("broken"); }
            @Override public float stiffness(float amount, Object character) { throw new IllegalStateException("broken"); }
            @Override public double fatigue(double vanilla, Object character) { throw new IllegalStateException("broken"); }
            @Override public float statDelta(float delta, Object stats, Object stat) { throw new IllegalStateException("broken"); }
        });
        check(player.getClothingDiscomfortModifier() == 3f, "A hook that failed did not give the game's answer");
        player.stats.set(CharacterStat.ENDURANCE, 1f);
        player.stats.add(CharacterStat.ENDURANCE, -0.5f);
        check(near(player.stats.get(CharacterStat.ENDURANCE), 0.5), "A stat change failed with its hook");
        survivalFaults(player);
        ApiHooks.setFormulas(null);
        check(player.getClothingDiscomfortModifier() == 3f, "Without a handler the game's answer changed");
        GameApi.register(LuaManager.class);
        check(player.getClothingDiscomfortModifier() == 1.5f, "A newer API did not take the formulas back");
        call(mod, "clear");
    }

    /** The survival hooks too: a handler that fails gives the game's answer at each of them, and the game goes on. */
    private static void survivalFaults(IsoPlayer player) {
        ApiHooks.setFormulas(new ApiHooks.Formulas() {
            @Override public float lootChance(float vanilla) { throw new IllegalStateException("broken"); }
            @Override public float lootAmmo(float vanilla) { throw new IllegalStateException("broken"); }
            @Override public float darkness(float vanilla, Object character) { throw new IllegalStateException("broken"); }
            @Override public float coneAdd(Object character, float degrees) { throw new IllegalStateException("broken"); }
            @Override public void squareLit(int playerIndex, int x, int y, int z, int[] lit) { throw new IllegalStateException("broken"); }
            @Override public boolean squareStale(int playerIndex, int x, int y, int z) { throw new IllegalStateException("broken"); }
            @Override public Object objectLight(Object info, int playerIndex) { throw new IllegalStateException("broken"); }
            @Override public float landing(float speed, Object character) { throw new IllegalStateException("broken"); }
            @Override public float impact(float speed, Object character) { throw new IllegalStateException("broken"); }
            @Override public float treeSlow(float vanilla, Object mover) { throw new IllegalStateException("broken"); }
            @Override public float treeAnimation(float vanilla, Object who) { throw new IllegalStateException("broken"); }
            @Override public boolean treeScratch(Object character) { throw new IllegalStateException("broken"); }
            @Override public float walk(Object character) { throw new IllegalStateException("broken"); }
            @Override public float cold(float vanilla, Object who) { throw new IllegalStateException("broken"); }
            @Override public int corpseCount(int vanilla, Object character) { throw new IllegalStateException("broken"); }
            @Override public float corpseSickness(float vanilla, Object character) { throw new IllegalStateException("broken"); }
            @Override public boolean hole(Object character) { throw new IllegalStateException("broken"); }
            @Override public boolean wound(Object character) { throw new IllegalStateException("broken"); }
            @Override public void bite(Object bodyDamage, int index, boolean after) { throw new IllegalStateException("broken"); }
        });
        var item = new ItemPickerJava.ItemPickerItem();
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 5) && ItemPickerJava.getLootModifierFromType("Ammo") == 1f,
            "A loot hook that failed did not give the game's answer");
        player.luma = 0.25f;
        check(near(LightingJNI.darkness(player), 0.75) && near(LightingJNI.calculateVisionCone(player), (144 - 126 * 0.75 - 180) / 180),
            "A vision hook that failed did not give the game's answer");
        player.luma = 1f;
        LightingJNI.squares.put("5,5,0", new int[] { 0, 0, 0, 0, 0, 0x01020304, 0, 0, 0, 0, 0, 0, 0 });
        LightingJNI.changed.add("5,5,0");
        var stale = new LightingJNI.JNILighting(0, new zombie.iso.IsoGridSquare(6, 6, 0));
        stale.read(false);
        check(stale.lightverts(0) == 0, "A square was read again when the hook that says whether to failed");
        var unlit = new LightingJNI.JNILighting(0, new zombie.iso.IsoGridSquare(5, 5, 0));
        unlit.read(true);
        var dim = new zombie.iso.IsoGridSquare(5, 5, 0);
        dim.setLight(0, 0.05f);
        check(unlit.lightverts(0) == 0x01020304 && new zombie.iso.fboRenderChunk.FBORenderCell().objectLight(0, dim).r == 0.05f,
            "A night sight hook that failed did not give the game's light");
        LightingJNI.squares.clear();
        LightingJNI.changed.clear();
        float oneFloor = FallingConstants.getIsoImpactSpeedFromHeight(1f);
        player.DoLand(oneFloor);
        check(player.landedAt == oneFloor && nearly(player.impactDamage, 115 / 1.5), "A fall hook that failed did not give the game's answer");
        var tree = new IsoTree();
        check(near(tree.getSlowFactor(player), 0.8) && near(player.treesSpeed(), 1), "A tree hook that failed did not give the game's answer");
        int scratches = player.scratches;
        player.stepInTrees();
        check(player.scratches == scratches + 1 && player.addHole(null, true), "A gate that failed did not let the game go on");
        player.deferredX = 2f;
        player.deferredY = 4f;
        player.setCurrentState(PlayerMovementState.instance());
        var movement = new Vector2();
        player.movement(movement);
        check(movement.x == 2f && movement.y == 4f, "A walking hook that failed changed the movement");
        player.setCurrentState(null);
        var cold = new Thermoregulator(player);
        cold.skin = 0.2f;
        CorpseCount.instance.corpses = 8;
        check(near(cold.getCatchAColdDelta(), 0.2) && CorpseCount.instance.getCorpseCount(player) == 8
            && near(player.getBodyDamage().GetBaseCorpseSickness(), 0.03), "A body hook that failed did not give the game's answer");
        CorpseCount.instance.corpses = 0;
        var part = player.getBodyDamage().getBodyParts().get(1);
        part.SetInfected(false);
        int rolls = part.infectionRolls;
        part.setScratched(true, false);
        check(part.infectionRolls == rolls + 1, "A wound gate that failed did not let the roll go on");
        part.SetInfected(false);
        player.getBodyDamage().AddRandomDamageFromZombie(new IsoZombie(), "Bite", 1);
        check(part.bitten() && part.IsInfected(), "A bite hook that failed stopped the bite");
        part.SetInfected(false);
        part.SetBitten(false);
    }

    /** The declarations belong to the world they were made in. */
    private static void world(KahluaTable api, KahluaTable formulas, IsoPlayer player) throws Exception {
        Object mod = call(api, "client", "world.mod").get(0);
        player.clothingDiscomfortModifier = 2f;
        IsoCell home = IsoWorld.instance.currentCell;
        GameApi.frame(FormulasTest.class.getClassLoader());
        call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        check(player.getClothingDiscomfortModifier() == 1f, "The formula does not apply");
        // The player leaves the world: no cell, then another.
        IsoWorld.instance.setCell(null);
        GameApi.frame(FormulasTest.class.getClassLoader());
        check(player.getClothingDiscomfortModifier() == 2f && call(formulas, "get", "body.discomfortMultiplier").get(0) == null,
            "A formula outlived the world it was declared in");
        IsoWorld.instance.setCell(new IsoCell());
        GameApi.frame(FormulasTest.class.getClassLoader());
        // Declared in the new world, before its first frame: kept.
        call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        GameApi.frame(FormulasTest.class.getClassLoader());
        check(player.getClothingDiscomfortModifier() == 1f, "A formula declared in a new world was dropped");
        IsoWorld.instance.setCell(null);
        GameApi.frame(FormulasTest.class.getClassLoader());
        IsoWorld.instance.setCell(home);
        GameApi.frame(FormulasTest.class.getClassLoader());
        check(player.getClothingDiscomfortModifier() == 2f, "The formula came back with the old world");
    }

    /** A newer API takes the declarations over; a function a mod kept from before says the API was updated. */
    private static void takeover(KahluaTable api, KahluaTable formulas, IsoPlayer player) throws Exception {
        Object mod = call(api, "client", "kept.mod").get(0);
        player.clothingDiscomfortModifier = 8f;
        call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        call(formulas, "set", mod, "body.poisonMultiplier", 0.25);
        // Kept for a newer API at the frame, and as it takes over.
        GameApi.frame(FormulasTest.class.getClassLoader());
        Object text = api.getMetatable().rawget("formulas");
        check(text instanceof String kept && kept.startsWith("pztools-formulas 1\n") && kept.contains("kept.mod\tbody.discomfortMultiplier\tn:0.5"),
            "The declarations were not kept: " + text);
        Object set = formulas.rawget("set");
        GameApi.register(LuaManager.class);
        check(api.rawget("formulas") == formulas && formulas.rawget("set") != set, "A newer API did not replace the functions in the same table");
        check(player.getClothingDiscomfortModifier() == 4f, "A newer API lost a declaration");
        check(near((Double)call(formulas, "declared", call(api, "client", "kept.mod").get(0), "body.poisonMultiplier").get(0), 0.25),
            "A newer API lost a mod's value");
        try { invoke(set, mod, "body.discomfortMultiplier", 0.1); throw new AssertionError("A function kept from before the takeover ran"); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZToolsAPI.formulas.set: the API was updated"), expected.getMessage());
        }
        check(player.getClothingDiscomfortModifier() == 4f, "A function kept from before the takeover changed a formula");
        // A declaration made since the last frame is not lost either.
        call(formulas, "set", mod, "body.discomfortMultiplier", 0.25);
        GameApi.register(LuaManager.class);
        check(player.getClothingDiscomfortModifier() == 2f, "A newer API lost a declaration made since the last frame");
        call(mod, "clear");
        check(player.getClothingDiscomfortModifier() == 8f, "Clearing after a takeover left the answer changed");
    }

    private static void rejects(KahluaTable formulas, String name, String message, Object... arguments) {
        try { call(formulas, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZToolsAPI.formulas." + name + ": ") && expected.getMessage().contains(message),
                expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static boolean near(double value, double expected) { return Math.abs(value - expected) < 1e-5; }

    static List<Object> call(Object table, String name, Object... arguments) {
        // A handle's functions are called with a colon: the handle is the first argument.
        var holder = (KahluaTable)table;
        Object function = holder.rawget(name);
        if (function == null && holder.getMetatable() != null) {
            Object index = holder.getMetatable().rawget("__index");
            if (index instanceof KahluaTable methods) {
                var withHandle = new Object[arguments.length + 1];
                withHandle[0] = holder;
                System.arraycopy(arguments, 0, withHandle, 1, arguments.length);
                return invoke(methods.rawget(name), withHandle);
            }
        }
        return invoke(function, arguments);
    }

    static List<Object> invoke(Object function, Object... arguments) {
        var frame = new LuaCallFrame(arguments);
        int count = ((JavaFunction)function).call(frame, arguments.length);
        check(count == frame.results.size(), "The result count is wrong");
        return frame.results;
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
