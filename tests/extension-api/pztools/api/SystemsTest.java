package pztools.api;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Random;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaEventManager;
import zombie.Lua.LuaManager;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.iso.IsoCell;
import zombie.iso.IsoChunk;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.objects.IsoGenerator;
import zombie.iso.sprite.IsoSprite;
import zombie.iso.sprite.IsoSpriteInstance;
import pztools.bridge.ApiHooks;

/**
 * The systems points against the synthetic game: the machines a mod declares (what a generator is asked of an object, and the
 * objects that were in the world before the declaration), the animations attached to objects that mods have stepped, the
 * helicopter's state and its event, and the query for the zombies near a point.
 */
final class SystemsTest {
    private static final ClassLoader GAME = SystemsTest.class.getClassLoader();

    private SystemsTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        try {
            var cell = new IsoCell();
            IsoWorld.instance.setCell(cell);
            for (int x = 0; x < 64; x++) for (int y = 0; y < 64; y++) for (int z = 0; z < 3; z++) cell.load(x, y, z);
            var player = new IsoPlayer();
            player.x = 10.5f; player.y = 10.5f;
            IsoPlayer.players[0] = player;
            GameApi.frame(GAME);
            Object mod = FormulasTest.call(api, "client", "systems.mod").get(0), second = FormulasTest.call(api, "client", "systems.second").get(0);
            var formulas = (KahluaTable)api.rawget("formulas");
            machines(formulas, mod, second, cell, player);
            animations(formulas, mod, second, cell);
            helicopter(api, player);
            WatchesTest.run(api, player);
            zombies(api, cell);
            IsoPlayer.players[0] = null;
        } finally {
            IsoWorld.instance.setCell(home);
            IsoPlayer.players[0] = null;
        }
    }

    // ---- machines ----

    private static IsoObject machine(IsoCell cell, String sprite, int x, int y, int z) {
        var object = new IsoObject(new IsoSprite(sprite));
        var square = cell.getGridSquare(x, y, z);
        object.square = square;
        square.objects.add(object);
        return object;
    }

    private static void data(IsoObject object, String key, Object value) { ((KahluaTable)object.getModData()).rawset(key, value); }

    private static void machines(KahluaTable formulas, Object mod, Object second, IsoCell cell, IsoPlayer player) {
        var points = (KahluaTable)FormulasTest.call(formulas, "points").get(0);
        for (String point : new String[] { "machine.baseConsumption", "machine.loadKey" })
            check(ApiHooks.APPLIED.equals(points.rawget(point)), point + " is " + points.rawget(point));
        // A machine in the world before it is declared; a vanilla appliance; an object that is neither. The square holds 2 objects.
        var press = machine(cell, "mymod_press_0", 20, 20, 1);
        var saw = machine(cell, "mymod_saw_0", 21, 20, 1);
        var fridge = machine(cell, "appliances_refrigeration_01_0", 20, 21, 1);
        fridge.powered = true; fridge.consumption = 0.08f;
        var plain = machine(cell, "walls_01_0", 22, 22, 0);
        check(!press.couldBePoweredByGenerator() && press.getGeneratorPowerConsumption() == 0f, "An undeclared machine was a consumer");
        // Declared: asked of it, it is a consumer of the load; asked of anything else, the game answers.
        FormulasTest.call(formulas, "set", mod, "machine.baseConsumption", table("mymod_press_0", 0.25, "mymod_saw_0", 0.5, "appliances_refrigeration_01_0", 0.0));
        check(press.couldBePoweredByGenerator() && press.getGeneratorPowerConsumption() == 0.25f, "A declared machine was not a consumer: " + press.getGeneratorPowerConsumption());
        check(saw.couldBePoweredByGenerator() && saw.getGeneratorPowerConsumption() == 0.5f, "A second machine was not a consumer");
        check(!plain.couldBePoweredByGenerator() && plain.getGeneratorPowerConsumption() == 0f, "An object that was not declared changed");
        // The game's answer for an appliance it knows is OR'd with the declaration; the load a sprite is declared with replaces the game's.
        check(fridge.couldBePoweredByGenerator() && fridge.getGeneratorPowerConsumption() == 0f, "A declaration of 0 did not take the game's load away");
        var other = machine(cell, "appliances_refrigeration_01_1", 23, 21, 1);
        other.powered = true; other.consumption = 0.08f;
        check(other.couldBePoweredByGenerator() && other.getGeneratorPowerConsumption() == 0.08f, "An appliance that was not declared changed");
        // The machines that were there before the declaration are listed with the game for a generator to find, in the next frame
        // with a world and a player, and the generators there are told.
        var chunk = cell.getGridSquare(20, 20, 1).chunk;
        check(!chunk.poweredObjects.contains(press), "The machine was listed before a frame");
        int updates = IsoGenerator.updates;
        GameApi.frame(GAME);
        IsoChunk chunkOfSaw = cell.getGridSquare(21, 20, 1).chunk;
        check(chunk.poweredObjects.contains(press) && chunkOfSaw.poweredObjects.contains(saw), "A machine that was in the world was not listed");
        check(!chunk.poweredObjects.contains(plain) && !chunk.poweredObjects.contains(fridge), "An object that is not a declared machine was listed");
        check(IsoGenerator.updates == updates + 2, "The generators were told " + (IsoGenerator.updates - updates) + " times, for 2 squares");
        // Not again, with nothing new declared.
        GameApi.frame(GAME);
        check(IsoGenerator.updates == updates + 2, "The machines were listed again");
        // The load of one machine: the keys of its data multiply the declared consumption.
        FormulasTest.call(formulas, "set", mod, "machine.loadKey", "mymodLoad");
        check(press.getGeneratorPowerConsumption() == 0.25f, "A machine with no data did not keep its consumption");
        data(press, "mymodLoad", 0.5);
        check(press.getGeneratorPowerConsumption() == 0.125f, "The load of the machine was not applied: " + press.getGeneratorPowerConsumption());
        data(press, "mymodLoad", 0.0);
        check(press.getGeneratorPowerConsumption() == 0f && press.couldBePoweredByGenerator(), "A machine at no load was not idle");
        data(press, "mymodLoad", 1000.0);
        check(press.getGeneratorPowerConsumption() == 25f, "A load above 100 was not held: " + press.getGeneratorPowerConsumption());
        data(press, "mymodLoad", -3.0);
        check(press.getGeneratorPowerConsumption() == 0f, "A load below 0 was not held");
        data(press, "mymodLoad", "heavy");
        check(press.getGeneratorPowerConsumption() == 0.25f, "A load that is not a number was not left out");
        data(press, "mymodLoad", Double.NaN);
        check(press.getGeneratorPowerConsumption() == 0.25f, "A load that is not a number (NaN) was not left out");
        data(press, "mymodLoad", 2.0);
        data(press, "mymodSpeed", 3.0);
        FormulasTest.call(formulas, "set", second, "machine.loadKey", table("mymodSpeed"));
        check(press.getGeneratorPowerConsumption() == 1.5f, "Two keys did not multiply: " + press.getGeneratorPowerConsumption());
        check(((KahluaTable)FormulasTest.call(formulas, "get", "machine.loadKey").get(0)).rawget(2.0) != null, "Two mods' keys did not join");
        // Two mods declaring one sprite add; one taking its declaration back leaves the other's.
        FormulasTest.call(formulas, "set", second, "machine.baseConsumption", table("mymod_saw_0", 0.25));
        check(saw.getGeneratorPowerConsumption() == 0.75f, "Two declarations of a sprite did not add: " + saw.getGeneratorPowerConsumption());
        FormulasTest.call(second, "clear");
        check(saw.getGeneratorPowerConsumption() == 0.5f, "A declaration taken back left the other mod's changed");
        // Allocation: the questions a generator asks of every object on its squares allocate nothing (the second round is counted).
        long bytes = 0;
        float sum = 0;
        for (int round = 0; round < 2; round++) {
            long before = allocated();
            for (int index = 0; index < 100000; index++) {
                sum += press.getGeneratorPowerConsumption() + saw.getGeneratorPowerConsumption() + plain.getGeneratorPowerConsumption();
                if (press.couldBePoweredByGenerator() && saw.couldBePoweredByGenerator() && !plain.couldBePoweredByGenerator()) sum++;
            }
            bytes = allocated() - before;
        }
        System.out.println("machines: " + bytes + " bytes allocated by 100000 rounds of 6 questions about declared machines and one plain object");
        check(sum > 0 && bytes < 16384, "The questions allocated " + bytes + " bytes in 100000 rounds");
        // Taken back: the game's answers again.
        FormulasTest.call(mod, "clear");
        check(!press.couldBePoweredByGenerator() && press.getGeneratorPowerConsumption() == 0f, "A machine stayed a consumer after its declaration went");
        check(fridge.getGeneratorPowerConsumption() == 0.08f, "The game's load did not come back");
        // A rule about the declaration: a number from 0 to 1000 for each name, and the names are text.
        rejects(formulas, "machine.baseConsumption must be a table", mod, "machine.baseConsumption", 1.0);
        rejects(formulas, "[mymod_press_0] must be a number from 0.0 to 1000.0", mod, "machine.baseConsumption", table("mymod_press_0", -1.0));
        rejects(formulas, "machine.loadKey must be a string or a list of strings", mod, "machine.loadKey", 1.0);
        // A machine declared before any frame had a world: listed when there is one. No player yet, no listing.
        IsoPlayer.players[0] = null;
        var late = machine(cell, "mymod_late_0", 30, 30, 0);
        FormulasTest.call(formulas, "set", mod, "machine.baseConsumption", table("mymod_late_0", 1.0));
        GameApi.frame(GAME);
        check(!late.square.chunk.poweredObjects.contains(late), "A machine was listed with no player to say what is loaded");
        IsoPlayer.players[0] = player;
        GameApi.frame(GAME);
        check(late.square.chunk.poweredObjects.contains(late), "A machine was not listed once a player was there");
        FormulasTest.call(mod, "clear");
        GameApi.frame(GAME);
    }

    // ---- attached animations ----

    private static void animations(KahluaTable formulas, Object mod, Object second, IsoCell cell) {
        var points = (KahluaTable)FormulasTest.call(formulas, "points").get(0);
        check(ApiHooks.APPLIED.equals(points.rawget("anim.stepKey")), "anim.stepKey is " + points.rawget("anim.stepKey"));
        // A press with a looping animation of 4 frames at half a frame a step, as a mod attaches one; a sign with one of its own.
        var press = machine(cell, "mymod_press_0", 20, 22, 0);
        var spin = new IsoSprite("mymod_press_spin");
        IsoSpriteInstance wheel = press.attachAnim(spin);
        wheel.setFrameSpeedPerFrame(0.5f);
        var sign = machine(cell, "mymod_sign_0", 21, 22, 0);
        var blink = new IsoSprite("mymod_sign_blink");
        IsoSpriteInstance light = sign.attachAnim(blink);
        GameApi.frame(GAME);
        // Nothing declared: drawn twice a frame, and the game's update() called each time, as in vanilla; nothing steps.
        press.render(); press.render();
        check(spin.steps == 0 && wheel.frame == 0f && wheel.updates == 2, "An animation was stepped with nothing declared: " + spin.steps);
        check(!press.isAnimating(), "An object with nothing declared asked to be drawn every frame");
        // Declared, but the press holds no key: not stepped, and no data table is made for it.
        FormulasTest.call(formulas, "set", mod, "anim.stepKey", "mymodSpin");
        press.render();
        check(spin.steps == 0 && !press.hasModData(), "An object without the key was stepped, or given a data table");
        check(!press.isAnimating() && !press.hasModData(), "An object without the key asked to be drawn every frame");
        // The key held: stepped once a frame however many times it is drawn, at its own speed, and the game's call kept.
        data(press, "mymodSpin", 1.0);
        int updates = wheel.updates;
        press.render(); press.render(); press.render();
        check(spin.steps == 1 && wheel.frame == 0.5f && wheel.updates == updates + 3, "Drawn three times in a frame, it was stepped " + spin.steps + " times");
        // The chunk renderer draws an object every frame only when it is animating (else into the chunk's texture, once): the press is.
        check(press.isAnimating(), "An object holding the key did not ask to be drawn every frame");
        GameApi.frame(GAME);
        press.render(); press.render();
        check(spin.steps == 2 && wheel.frame == 1f, "The next frame did not step it once: " + spin.steps);
        // Looping: back to the first frame after the last (4 frames).
        for (int frame = 0; frame < 6; frame++) { GameApi.frame(GAME); press.render(); }
        check(spin.steps == 8 && wheel.frame == 0f, "The animation did not loop: frame " + wheel.frame);
        // Not drawn in a frame: not stepped in it.
        GameApi.frame(GAME);
        GameApi.frame(GAME);
        press.render();
        check(spin.steps == 9, "An animation that was not drawn was stepped for its frame");
        // A number other than 0 steps; 0, a string, a NaN and a key taken out leave it as in vanilla.
        for (Object held : new Object[] { 0.0, "on", Double.NaN, null }) {
            data(press, "mymodSpin", held);
            GameApi.frame(GAME);
            press.render();
            check(spin.steps == 9 && !press.isAnimating(), "A press holding " + held + " was stepped, or drawn every frame");
        }
        data(press, "mymodSpin", -2.0);
        GameApi.frame(GAME);
        press.render();
        check(spin.steps == 10, "A negative number did not step it");
        // Only the object that holds the key: the sign has none.
        GameApi.frame(GAME);
        sign.render();
        check(blink.steps == 0 && light.updates == 1 && !sign.isAnimating(), "An object without the key was stepped beside one with it");
        // The key on an object with no attached animation: nothing to draw every frame. An object animating of its own stays so.
        var bare = machine(cell, "mymod_bare_0", 23, 22, 0);
        data(bare, "mymodSpin", 1.0);
        check(!bare.isAnimating(), "An object without attached animations asked to be drawn every frame");
        bare.animating = true;
        check(bare.isAnimating(), "The game's own animating was taken away");
        bare.animating = false;
        // Two mods' keys join: the sign holds the second's.
        data(sign, "blinking", 1.0);
        FormulasTest.call(formulas, "set", second, "anim.stepKey", table("blinking"));
        GameApi.frame(GAME);
        sign.render(); press.render();
        check(blink.steps == 1 && spin.steps == 11, "Two mods' keys did not join: " + blink.steps + ", " + spin.steps);
        check(((KahluaTable)FormulasTest.call(formulas, "get", "anim.stepKey").get(0)).len() == 2, "The keys of two mods did not join");
        // A sprite whose step fails: reported once, the game's own call made, and the other objects stepped.
        blink.failing = true;
        var err = new ByteArrayOutputStream();
        PrintStream original = System.err;
        System.setErr(new PrintStream(err, true));
        try {
            for (int frame = 0; frame < 3; frame++) { GameApi.frame(GAME); sign.render(); press.render(); }
        } finally { System.setErr(original); }
        String log = err.toString();
        String report = "[PzTools API] attachedAnim:";
        check(log.contains(report) && log.indexOf(report) == log.lastIndexOf(report) && light.updates == 5 && spin.steps == 14,
            "A failing step was not reported once, or stopped the drawing: " + log);
        blink.failing = false;
        // Allocation: drawing declared objects, stepped and not (the median of five rounds).
        long bytes = Allocations.median(5, () -> {
            for (int frame = 0; frame < 100; frame++) {
                GameApi.frame(GAME);
                for (int draw = 0; draw < 1000; draw++) {
                    press.render(); sign.render();
                    if (!press.isAnimating() || bare.isAnimating()) throw new AssertionError("isAnimating changed");
                }
            }
        });
        System.out.println("attached animations: " + bytes + " bytes allocated by 100 frames of 1000 draws of two stepped objects");
        check(bytes < 16384, "Drawing stepped animations allocated " + bytes + " bytes in 100 frames");
        var plain = machine(cell, "mymod_plain_0", 22, 22, 0);
        plain.attachAnim(new IsoSprite("mymod_plain_spin"));
        double stepped = drawCost(press), keyless = drawCost(plain);
        // Taken back: vanilla again.
        FormulasTest.call(mod, "clear");
        FormulasTest.call(second, "clear");
        int steps = spin.steps;
        GameApi.frame(GAME);
        press.render();
        check(spin.steps == steps && !press.isAnimating(), "An animation was stepped, or drawn every frame, after the declaration went");
        double undeclared = drawCost(press);
        System.out.printf("attached animations: a draw of one costs %.1f ns with nothing declared, %.1f ns declared without the key, %.1f ns with it"
            + " (a frame of 1000 draws, the first one stepping)%n", undeclared, keyless, stepped);
        check(undeclared < 1000 && keyless < 1000 && stepped < 1000, "A draw is slow: " + undeclared + ", " + keyless + ", " + stepped + " ns");
        rejects(formulas, "anim.stepKey must be a string or a list of strings", mod, "anim.stepKey", 1.0);
    }

    /** What drawing the object costs, in ns a draw: the best of 5 rounds of 1000 frames of 1000 draws (the synthetic draw included). */
    private static double drawCost(IsoObject object) {
        double best = Double.MAX_VALUE;
        for (int round = 0; round < 6; round++) {
            long time = 0;
            for (int frame = 0; frame < 1000; frame++) {
                GameApi.frame(GAME);
                long start = System.nanoTime();
                for (int draw = 0; draw < 1000; draw++) object.render();
                time += System.nanoTime() - start;
            }
            // The first round warms up.
            if (round > 0) best = Math.min(best, time / 1e6);
        }
        return best;
    }

    // ---- the helicopter ----

    private static void helicopter(KahluaTable api, IsoPlayer player) throws Exception {
        var area = (KahluaTable)api.rawget("helicopter");
        check(area != null && LuaEventManager.added.contains("OnPZToolsHelicopter"), "The helicopter area or its event is missing");
        var heli = IsoWorld.instance.helicopter;
        GameApi.frame(GAME);
        LuaEventManager.raised.clear();
        List<Object> state = FormulasTest.call(area, "state");
        check(state.size() == 1 && "Inactive".equals(state.get(0)), "A helicopter that is not flying is " + state);
        GameApi.frame(GAME);
        check(LuaEventManager.raised.isEmpty(), "An event was raised with nothing changed");
        // The game sets a target: the helicopter arrives.
        player.x = 10.5f; player.y = 12.5f;
        heli.setTarget(player);
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 1 && LuaEventManager.raised.get(0).equals(Arrays.asList("OnPZToolsHelicopter", "Arriving", player, 1010.5, 1012.5)),
            "The arrival was not raised: " + LuaEventManager.raised);
        state = FormulasTest.call(area, "state");
        check(state.equals(Arrays.asList("Arriving", player, 1010.5, 1012.5)), "The state read is " + state);
        // Through changeState, with the helicopter moving.
        heli.update("Hovering", 12f, 14f);
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 2 && LuaEventManager.raised.get(1).equals(Arrays.asList("OnPZToolsHelicopter", "Hovering", player, 12.0, 14.0)),
            "The hovering was not raised: " + LuaEventManager.raised);
        // Nothing changes, nothing is raised, whatever the helicopter does besides.
        heli.x = 13f;
        GameApi.frame(GAME);
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 2, "An event was raised for a move");
        // The game writes the state straight (the target is gone), and a state the helicopter passes through in a frame is not seen.
        heli.update("Searching", 14f, 15f);
        heli.update("Hovering", 14f, 15f);
        heli.leaveAtOnce();
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 3 && LuaEventManager.raised.get(2).get(1).equals("Leaving"), "A state the game wrote straight was not raised: " + LuaEventManager.raised);
        // Taken off: the state is inactive, with the target as the game has it.
        heli.deactivate();
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 4 && LuaEventManager.raised.get(3).get(1).equals("Inactive"), "The end was not raised: " + LuaEventManager.raised);
        state = FormulasTest.call(area, "state");
        check(state.size() == 1 && "Inactive".equals(state.get(0)), "A helicopter that left is " + state);
        // A save loads while it flies: the change is raised; a newer API taking over meanwhile is not told of a change.
        heli.load("Searching", true);
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 5 && LuaEventManager.raised.get(4).get(1).equals("Searching"), "A state a save loaded was not raised");
        GameApi.register(LuaManager.class);
        GameApi.frame(GAME);
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 5, "A newer API raised an event for a state that did not change: " + LuaEventManager.raised);
        var newer = (KahluaTable)api.rawget("helicopter");
        state = FormulasTest.call(newer, "state");
        check("Searching".equals(state.get(0)), "A newer API does not read the state: " + state);
        heli.deactivate();
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 6, "A newer API did not raise the end");
        LuaEventManager.raised.clear();
    }

    // ---- the zombies near a point ----

    private static IsoZombie place(IsoCell cell, float x, float y, int z) {
        var zombie = new IsoZombie();
        zombie.x = x; zombie.y = y; zombie.z = z;
        cell.zombieList.add(zombie);
        return zombie;
    }

    private static void zombies(KahluaTable api, IsoCell cell) {
        var area = (KahluaTable)api.rawget("zombies");
        check(area != null, "PZToolsAPI.zombies is missing");
        cell.zombieList.clear();
        List<Object> none = FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 20.0);
        check(none.size() == 2 && (Double)none.get(0) == 0.0 && ((KahluaTable)none.get(1)).len() == 0, "No zombies gave " + none);
        // 3 around (10, 10) on the ground floor, 1 upstairs, 1 dead, 1 out of reach; the squares from (10, 10): 2, 5, 8.
        var closest = place(cell, 12f, 10f, 0);
        var middle = place(cell, 10f, 15f, 0);
        var farthest = place(cell, 16f, 10f, 0);
        place(cell, 11f, 10f, 1);
        var dead = place(cell, 10.5f, 10.5f, 0);
        dead.dead = true;
        place(cell, 40f, 10f, 0);
        List<Object> found = FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 8.0);
        var list = (KahluaTable)found.get(1);
        check((Double)found.get(0) == 3.0 && list.len() == 3, "The count and the list are " + found.get(0) + ", " + list.len());
        // Nearest first, each as a table.
        var first = (KahluaTable)list.rawget(1.0);
        check(first.rawget("zombie") == closest && (Double)first.rawget("x") == 12.0 && (Double)first.rawget("y") == 10.0
            && (Double)first.rawget("z") == 0.0 && (Double)first.rawget("distance") == 2.0, "The nearest is wrong");
        check(((KahluaTable)list.rawget(2.0)).rawget("zombie") == middle && ((KahluaTable)list.rawget(3.0)).rawget("zombie") == farthest
            && (Double)((KahluaTable)list.rawget(3.0)).rawget("distance") == 6.0, "The list is not in order of distance");
        // The radius counts a zombie exactly that far.
        check((Double)FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 6.0).get(0) == 3.0 && (Double)FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 5.99).get(0) == 2.0,
            "The radius is not a distance a zombie can be at");
        // Another level, a limit, and none.
        check((Double)FormulasTest.call(area, "near", 10.0, 10.0, 1.0, 8.0).get(0) == 1.0, "The level was not respected");
        var limited = FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 8.0, 2.0);
        check((Double)limited.get(0) == 3.0 && ((KahluaTable)limited.get(1)).len() == 2 && ((KahluaTable)((KahluaTable)limited.get(1)).rawget(2.0)).rawget("zombie") == middle,
            "A limit of 2 gave " + limited.get(0) + ", " + ((KahluaTable)limited.get(1)).len());
        var counted = FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 8.0, 0.0);
        check((Double)counted.get(0) == 3.0 && ((KahluaTable)counted.get(1)).len() == 0, "A limit of 0 is only the count");
        // Many: the list is bounded, the count is not, and the order holds whatever order the game lists them in.
        cell.zombieList.clear();
        var random = new Random(5);
        var distances = new ArrayList<Double>();
        for (int index = 0; index < 500; index++) {
            int x = 10 + random.nextInt(61) - 30, y = 10 + random.nextInt(61) - 30;
            place(cell, x, y, 0);
            long squared = (long)(x - 10) * (x - 10) + (long)(y - 10) * (y - 10);
            if (squared <= 625) distances.add(Math.sqrt(squared));
        }
        distances.sort(null);
        var many = FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 25.0, 64.0);
        var nearest = (KahluaTable)many.get(1);
        check((Double)many.get(0) == distances.size() && nearest.len() == 64, "The count or the bound is wrong: " + many.get(0) + " of " + distances.size() + ", " + nearest.len());
        for (int index = 0; index < 64; index++)
            check(Math.abs((Double)((KahluaTable)nearest.rawget((double)(index + 1))).rawget("distance") - distances.get(index)) < 1e-9, "The list is not the nearest in order at " + index);
        // The arguments.
        rejects(area, "z must be a whole number", "near", 0.0, 0.0, 0.5, 5.0);
        rejects(area, "radius must be a number from 0.0 to 1000.0", "near", 0.0, 0.0, 0.0, -1.0);
        rejects(area, "limit must be a whole number from 0 to 64", "near", 0.0, 0.0, 0.0, 5.0, 65.0);
        rejects(area, "x must be a number", "near", "here", 0.0, 0.0, 5.0);
        // No world: nothing.
        var home = IsoWorld.instance.currentCell;
        IsoWorld.instance.setCell(null);
        List<Object> nowhere = FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 20.0);
        IsoWorld.instance.setCell(home);
        check((Double)nowhere.get(0) == 0.0, "Without a world there were zombies");
        // Cost: 10000 zombies, a radius that takes none, then all: the same pass, the same time, and nothing allocated for a zombie.
        cell.zombieList.clear();
        for (int index = 0; index < 10000; index++) place(cell, 10f + random.nextInt(2001) - 1000, 10f + random.nextInt(2001) - 1000, 0);
        for (int warm = 0; warm < 300; warm++) FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 5.0, 0.0);
        long bytes = allocated();
        long start = System.nanoTime();
        for (int round = 0; round < 500; round++) FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 5.0, 0.0);
        long smallTime = System.nanoTime() - start;
        bytes = allocated() - bytes;
        for (int warm = 0; warm < 300; warm++) FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 1000.0, 8.0);
        start = System.nanoTime();
        for (int round = 0; round < 500; round++) FormulasTest.call(area, "near", 10.0, 10.0, 0.0, 1000.0, 8.0);
        long bigTime = System.nanoTime() - start;
        System.out.printf("zombies.near over 10000 zombies: radius 5 %.1f us, radius 1000 (all of them, the nearest 8) %.1f us a call; %d bytes a call for the first%n",
            smallTime / 500 / 1e3, bigTime / 500 / 1e3, bytes / 500);
        check(bytes / 500 < 2048, "A pass over 10000 zombies allocated " + bytes / 500 + " bytes a call");
        check(smallTime / 500 < 2_000_000L && bigTime / 500 < 4_000_000L, "zombies.near is slow: " + smallTime / 500 + " ns, " + bigTime / 500 + " ns");
        cell.zombieList.clear();
    }

    // ---- helpers ----

    private static KahluaTable table(Object... pairs) {
        var result = LuaManager.platform.newTable();
        if (pairs.length == 1) { result.rawset(1.0, pairs[0]); return result; }
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static void rejects(Object table, String message, String name, Object... arguments) {
        try { FormulasTest.call(table, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    /** A formula point declared wrongly, by the point's name. */
    private static void rejects(KahluaTable formulas, String message, Object mod, String point, Object value) {
        try { FormulasTest.call(formulas, "set", mod, point, value); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(point + " accepted " + value + ": " + message);
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
