package pzext.api;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.FieldModel;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.List;
import pzext.boot.Hooks;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaEventManager;
import zombie.Lua.LuaManager;
import zombie.characters.IsoPlayer;
import zombie.iso.Helicopter;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;

/**
 * What the frame job learns from the hooks instead of looking each frame: the helicopter's events through each way the game
 * writes its state, the first look being a baseline, a write from another thread, the world's changes, a frame in which nothing
 * was written reading nothing, and the frame looking every time when a hook is not in the game's class.
 */
final class WatchesTest {
    private static final ClassLoader GAME = WatchesTest.class.getClassLoader();
    private static final String EVENT = "OnPZExtHelicopter";

    private WatchesTest() { }

    static void run(KahluaTable api, IsoPlayer player) throws Exception {
        helicopter(api, player);
        world(api);
        fallback(api, player);
    }

    private static void frames(int count) { for (int frame = 0; frame < count; frame++) GameApi.frame(GAME); }

    /** The event that came last, as the state it names. */
    private static String last() { return (String)LuaEventManager.raised.get(LuaEventManager.raised.size() - 1).get(1); }

    private static void helicopter(KahluaTable api, IsoPlayer player) throws Exception {
        var area = (KahluaTable)api.rawget("helicopter");
        var heli = IsoWorld.instance.helicopter;
        var hooks = (KahluaTable)FormulasTest.call(api, "hooks").get(0);
        check(Hooks.APPLIED.equals(hooks.rawget("Helicopter.events")) && Hooks.APPLIED.equals(hooks.rawget("IsoWorld.change")),
            "The areas are not told by the hooks: " + hooks.rawget("Helicopter.events") + ", " + hooks.rawget("IsoWorld.change"));
        heli.deactivate();
        frames(2);
        LuaEventManager.raised.clear();
        // A frame in which nothing was written asks the helicopter nothing.
        int reads = heli.activeReads;
        frames(2000);
        check(heli.activeReads == reads && LuaEventManager.raised.isEmpty(), "A frame with nothing written looked at the helicopter " + (heli.activeReads - reads) + " times");

        // The five ways the game writes the state, and the two ways it takes the helicopter off: one event for each, at the next frame.
        heli.setTarget(player);
        check(LuaEventManager.raised.isEmpty(), "The event was raised from the thread that wrote");
        frames(1);
        check(LuaEventManager.raised.size() == 1 && "Arriving".equals(last()), "setTarget: " + LuaEventManager.raised);
        heli.update("Hovering", 12f, 14f);
        frames(1);
        check(LuaEventManager.raised.size() == 2 && "Hovering".equals(last()), "changeState: " + LuaEventManager.raised);
        heli.leaveAtOnce();
        frames(1);
        check(LuaEventManager.raised.size() == 3 && "Leaving".equals(last()), "a state written straight: " + LuaEventManager.raised);
        heli.load("Searching", true);
        frames(1);
        check(LuaEventManager.raised.size() == 4 && "Searching".equals(last()), "a load (the flag and then the state): " + LuaEventManager.raised);
        heli.clientSync(5f, 6f, false);
        frames(1);
        check(LuaEventManager.raised.size() == 5 && "Inactive".equals(last()), "a client sync that takes it off: " + LuaEventManager.raised);
        heli.clientSync(5f, 6f, true);
        frames(1);
        check(LuaEventManager.raised.size() == 6 && "Searching".equals(last()), "a client sync that puts it on: " + LuaEventManager.raised);
        heli.deactivate();
        frames(1);
        check(LuaEventManager.raised.size() == 7 && "Inactive".equals(last()), "deactivate: " + LuaEventManager.raised);
        heli.load("Hovering", true);
        frames(1);
        check(LuaEventManager.raised.size() == 8 && "Hovering".equals(last()), "a load: " + LuaEventManager.raised);
        heli.pickRandomTarget();
        frames(1);
        check(LuaEventManager.raised.size() == 9 && "Inactive".equals(last()), "pickRandomTarget with nobody to fly to: " + LuaEventManager.raised);
        // Writes that end where they began are no change; an event names the state at the frame, not one passed through.
        heli.load("Hovering", true);
        frames(1);
        int count = LuaEventManager.raised.size();
        heli.update("Searching", 1f, 1f);
        heli.update("Hovering", 1f, 1f);
        frames(2);
        check(LuaEventManager.raised.size() == count, "A state that came back within a frame was raised: " + LuaEventManager.raised);
        frames(2000);
        int after = heli.activeReads;
        frames(2000);
        check(heli.activeReads == after, "Quiet frames looked at the helicopter");

        // A write from another thread (the network's): raised by the next frame, on the game's thread.
        Thread writer = new Thread(() -> heli.clientSync(7f, 8f, false), "network");
        writer.start();
        writer.join();
        check(LuaEventManager.raised.size() == count, "The event was raised from the writer's thread");
        frames(1);
        check(LuaEventManager.raised.size() == count + 1 && "Inactive".equals(last()) && LuaEventManager.lastThread == Thread.currentThread(),
            "A write from another thread was not raised on the game's thread: " + LuaEventManager.raised + " by " + LuaEventManager.lastThread);
        Thread loader = new Thread(() -> heli.load("Leaving", true), "loader");
        loader.start();
        loader.join();
        frames(1);
        check(LuaEventManager.raised.size() == count + 2 && "Leaving".equals(last()), "A load from another thread was not raised: " + LuaEventManager.raised);

        // The first look is a baseline: a newer API taking over while it flies is not told that it started, and is told of the next change.
        GameApi.register(LuaManager.class);
        frames(3);
        check(LuaEventManager.raised.size() == count + 2, "A newer API raised the state it found: " + LuaEventManager.raised);
        heli.update("Searching", 2f, 2f);
        frames(1);
        check(LuaEventManager.raised.size() == count + 3 && "Searching".equals(last()), "A newer API missed the first change: " + LuaEventManager.raised);
        var newer = (KahluaTable)api.rawget("helicopter");
        check("Searching".equals(FormulasTest.call(newer, "state").get(0)), "state() disagrees with the events");
        heli.deactivate();
        frames(1);
        LuaEventManager.raised.clear();
        check(area != null, "The helicopter area is missing");
    }

    /** The world's cell stored by the game is noticed by the next frame, and by nothing else. */
    private static void world(KahluaTable api) throws Exception {
        var formulas = (KahluaTable)api.rawget("formulas");
        Object mod = FormulasTest.call(api, "client", "watches.mod").get(0);
        var world = IsoWorld.instance;
        IsoCell home = world.currentCell;
        Field cellField = IsoWorld.class.getDeclaredField("currentCell");
        frames(2);
        FormulasTest.call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        frames(2);
        check(FormulasTest.call(formulas, "get", "body.discomfortMultiplier").get(0) != null, "The declaration was not kept");
        // Stored by the game (init, KillCell): the declarations of the world that was left go.
        IsoCell other = new IsoCell();
        world.setCell(other);
        frames(1);
        check(FormulasTest.call(formulas, "get", "body.discomfortMultiplier").get(0) == null, "A declaration outlived the world it was made in");
        // A cell that changed without the game storing it is not looked for (that is what the hook is for), and the next store sees it.
        FormulasTest.call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        frames(2);
        cellField.set(world, home);
        frames(5);
        check(FormulasTest.call(formulas, "get", "body.discomfortMultiplier").get(0) != null, "The frame looked at the world's cell with no store counted");
        int writes = Hooks.worldWrites();
        world.setCell(home);
        check(Hooks.worldWrites() == writes + 1, "A store of the cell was not counted once: " + (Hooks.worldWrites() - writes));
        frames(1);
        check(FormulasTest.call(formulas, "get", "body.discomfortMultiplier").get(0) == null, "A store of the cell was not seen");
        world.setCell(home);
        frames(2);
        FormulasTest.call(mod, "clear");
        frames(1);
    }

    /** A hook that is not in the game's class: the frame looks every time, nothing is lost, and the status says so. */
    private static void fallback(KahluaTable api, IsoPlayer player) throws Exception {
        Method transform = Hooks.class.getDeclaredMethod("transform", String.class, byte[].class, ClassLoader.class);
        transform.setAccessible(true);
        var heli = IsoWorld.instance.helicopter;
        var area = (KahluaTable)api.rawget("helicopter");
        Class<?> stateType = Class.forName("zombie.iso.Helicopter$State", false, GAME);
        Field stateField = Helicopter.class.getDeclaredField("state"), cellField = IsoWorld.class.getDeclaredField("currentCell");
        stateField.setAccessible(true);
        @SuppressWarnings({ "unchecked", "rawtypes" })
        java.util.function.Function<String, Object> state = name -> Enum.valueOf((Class)stateType, name);
        heli.load("Hovering", true);
        frames(2);
        LuaEventManager.raised.clear();

        // The helicopter's hook is not in the class (it lacks a field it needs): every frame looks, and a store nobody counted is seen.
        byte[] lacking = without(Helicopter.class, "active");
        check(transform.invoke(null, "zombie/iso/Helicopter", lacking, GAME) == null, "A class without the field was changed");
        var hooks = (KahluaTable)FormulasTest.call(api, "hooks").get(0);
        check(String.valueOf(hooks.rawget("Helicopter.events")).startsWith("polled: expected the field Helicopter.active")
            && Hooks.APPLIED.equals(hooks.rawget("IsoWorld.change")), "The status does not say the helicopter is polled: " + hooks.rawget("Helicopter.events"));
        int reads = heli.activeReads;
        frames(5);
        check(heli.activeReads >= reads + 5, "The frames did not look at the helicopter without the hook: " + (heli.activeReads - reads));
        stateField.set(heli, state.apply("Leaving"));
        frames(1);
        check(LuaEventManager.raised.size() == 1 && "Leaving".equals(last()), "A store nobody counted was lost without the hook: " + LuaEventManager.raised);

        // The hook is back: a store nobody counted is not looked for, a counted one is.
        try (var input = GAME.getResourceAsStream("zombie/iso/Helicopter.class")) { transform.invoke(null, "zombie/iso/Helicopter", input.readAllBytes(), GAME); }
        hooks = (KahluaTable)FormulasTest.call(api, "hooks").get(0);
        check(Hooks.APPLIED.equals(hooks.rawget("Helicopter.events")), "The status did not come back: " + hooks.rawget("Helicopter.events"));
        frames(3);
        LuaEventManager.raised.clear();
        stateField.set(heli, state.apply("Searching"));
        frames(5);
        check(LuaEventManager.raised.isEmpty(), "The frames looked at the helicopter with the hook in: " + LuaEventManager.raised);
        heli.update("Searching", 3f, 3f);
        frames(1);
        check(LuaEventManager.raised.size() == 1 && "Searching".equals(last()), "A counted store was not seen: " + LuaEventManager.raised);
        heli.deactivate();
        frames(1);
        LuaEventManager.raised.clear();

        // The world's hook is not in the class: the cell is looked at every frame.
        var formulas = (KahluaTable)api.rawget("formulas");
        Object mod = FormulasTest.call(api, "client", "watches.fallback").get(0);
        var world = IsoWorld.instance;
        IsoCell home = world.currentCell;
        check(transform.invoke(null, "zombie/iso/IsoWorld", without(IsoWorld.class, "currentCell"), GAME) == null, "A class without the field was changed");
        hooks = (KahluaTable)FormulasTest.call(api, "hooks").get(0);
        check(String.valueOf(hooks.rawget("IsoWorld.change")).startsWith("polled: expected the field IsoWorld.currentCell"),
            "The status does not say the world is polled: " + hooks.rawget("IsoWorld.change"));
        frames(2);
        FormulasTest.call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        frames(2);
        cellField.set(world, new IsoCell());
        frames(1);
        check(FormulasTest.call(formulas, "get", "body.discomfortMultiplier").get(0) == null, "A world left without a counted store was not seen without the hook");
        try (var input = GAME.getResourceAsStream("zombie/iso/IsoWorld.class")) { transform.invoke(null, "zombie/iso/IsoWorld", input.readAllBytes(), GAME); }
        hooks = (KahluaTable)FormulasTest.call(api, "hooks").get(0);
        check(Hooks.APPLIED.equals(hooks.rawget("IsoWorld.change")), "The world's status did not come back");
        world.setCell(home);
        frames(3);
        FormulasTest.call(mod, "clear");
        frames(1);
        check(area != null && player != null, "unreachable");
    }

    /** The class's bytes with one field taken out (its code still refers to it): the hooks do not fit it. */
    private static byte[] without(Class<?> type, String field) throws Exception {
        try (var input = GAME.getResourceAsStream(type.getName().replace('.', '/') + ".class")) {
            var cf = ClassFile.of();
            return cf.transformClass(cf.parse(input.readAllBytes()),
                ClassTransform.dropping(element -> element instanceof FieldModel model && model.fieldName().equalsString(field)));
        }
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
