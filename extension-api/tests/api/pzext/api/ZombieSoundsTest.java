package pzext.api;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import pzext.boot.Hooks;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaEventManager;
import zombie.Lua.LuaManager;
import zombie.audio.parameters.ParameterZombieState.State;
import zombie.characters.FallingConstants;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.characters.ZombieVocalsManager;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;

/**
 * The sounds zombies make, against the synthetic game: {@code zombies.listen} and {@code OnPZExtZombieSound}. The game's own
 * methods are called (the voice's state set, a voice started, a landing), with the hooks the agent put in them.
 */
final class ZombieSoundsTest {
    private static final ClassLoader GAME = ZombieSoundsTest.class.getClassLoader();
    private static final String EVENT = "OnPZExtZombieSound";
    private static final AtomicLong NOW = new AtomicLong(1_000_000_000_000L);

    private ZombieSoundsTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        var clock = ZombieSounds.clock;
        ZombieSounds.clock = NOW::get;
        try {
            IsoWorld.instance.setCell(new IsoCell());
            var player = new IsoPlayer();
            player.x = 10.5f; player.y = 10.5f;
            IsoPlayer.players[0] = player;
            GameApi.frame(GAME);
            var zombies = (KahluaTable)api.rawget("zombies");
            check(zombies.rawget("listen") != null && LuaEventManager.added.contains(EVENT), "zombies.listen or its event is missing");
            Object mod = FormulasTest.call(api, "client", "sounds.mod").get(0), second = FormulasTest.call(api, "client", "sounds.second").get(0);
            nobody(zombies);
            kinds(zombies, mod, player);
            heard(zombies, mod, second);
            repeats(zombies, mod);
            capped(zombies, mod);
            threads(zombies, mod);
            faults(zombies, mod, player);
            bench(zombies, mod);
            arguments(zombies, mod);
            takeover(api, mod);
            worldLeft(api, mod);
        } finally {
            ZombieSounds.clock = clock;
            IsoWorld.instance.setCell(home);
            IsoPlayer.players[0] = null;
            LuaEventManager.raised.clear();
        }
    }

    private static IsoZombie zombie(float x, float y, float z) {
        var zombie = new IsoZombie();
        zombie.x = x; zombie.y = y; zombie.z = z;
        return zombie;
    }

    private static ZombieSounds sounds() { return GameApi.sounds(); }

    private static void frame() { GameApi.frame(GAME); }

    /** The events raised by the frames until none is noted, as (kind, x, y, z, loudness, zombie). */
    private static List<List<Object>> drain() {
        LuaEventManager.raised.clear();
        for (int frames = 0; frames < 20 && sounds().pending() > 0; frames++) frame();
        frame();
        var events = new ArrayList<List<Object>>();
        for (var raised : LuaEventManager.raised) {
            check(raised.get(0).equals(EVENT), "Another event was raised: " + raised);
            events.add(raised.subList(1, raised.size()));
        }
        LuaEventManager.raised.clear();
        return events;
    }

    private static void later() { NOW.addAndGet(ZombieSounds.REPEAT_NANOS + 1); }

    /** Nobody listens: the hooks note nothing and nothing is raised. */
    private static void nobody(KahluaTable zombies) {
        var zombie = zombie(12f, 10.5f, 0f);
        zombie.parameterZombieState.setState(State.LockTarget);
        new ZombieVocalsManager.Slot().playSound(zombie);
        zombie.DoLand(FallingConstants.getIsoImpactSpeedFromHeight(1f));
        check(sounds().pending() == 0 && sounds().radius() == 0, "Something was noted with nobody listening");
        check(drain().isEmpty(), "An event was raised with nobody listening");
        check(zombie.parameterZombieState.isState(State.LockTarget) && zombie.getEmitter().vocals == 1 && zombie.falls == 1,
            "The game's own methods did not run");
    }

    /** Each kind, where the zombie was, with its loudness; the states that make no sound of their own raise nothing. */
    private static void kinds(KahluaTable zombies, Object mod, IsoPlayer player) {
        check(((Double)FormulasTest.call(zombies, "listen", mod, 30.0).get(0)) == 30.0, "listen did not answer the radius");
        var zombie = zombie(15f, 10.5f, 0f);
        // The game's own aggravation: a target, and the voice's parameter worked out.
        zombie.target = player;
        zombie.parameterZombieState.calculateCurrentValue();
        check(drain().equals(List.of(List.of("aggro", 15.0, 10.5, 0.0, 15.0, zombie))), "The aggro was not raised as it should be");
        zombie.parameterZombieState.setState(State.LockTarget);
        check(drain().equals(List.of(List.of("lunge", 15.0, 10.5, 0.0, 40.0, zombie))), "The lunge was not raised");
        // Searching after a lunge is not an aggravation.
        zombie.parameterZombieState.setState(State.SearchTarget);
        zombie.x = 16f;
        zombie.parameterZombieState.setState(State.AttackBite);
        check(drain().equals(List.of(List.of("attack", 16.0, 10.5, 0.0, 15.0, zombie))), "The attack was not raised (or an aggro was)");
        // The same state again is not a change (the game returns early); calm states and eating make no sound of their own.
        zombie.parameterZombieState.setState(State.AttackBite);
        for (State calm : new State[] { State.Idle, State.Eating, State.GettingUp, State.Reanimate }) zombie.parameterZombieState.setState(calm);
        check(sounds().pending() == 0, "A state with no sound of its own was noted");
        for (State hit : new State[] { State.Hit, State.Pushed, State.RunOver }) {
            later();
            zombie.parameterZombieState.setState(hit);
            check(drain().equals(List.of(List.of("hit", 16.0, 10.5, 0.0, 10.0, zombie))), hit + " was not raised as a hit");
        }
        zombie.parameterZombieState.setState(State.Death);
        check(drain().equals(List.of(List.of("death", 16.0, 10.5, 0.0, 10.0, zombie))), "The death was not raised");
        // The voice: started once, while it plays it is not started again; when it stopped, again.
        var slot = new ZombieVocalsManager.Slot();
        slot.playSound(zombie);
        slot.playSound(zombie);
        check(zombie.getEmitter().vocals == 1, "The game's slot did not start the voice once");
        check(drain().equals(List.of(List.of("voice", 16.0, 10.5, 0.0, 15.0, zombie))), "The voice was not raised once");
        later();
        zombie.vocalEvent = 0L;
        slot.playSound(zombie);
        check(drain().size() == 1, "A voice started again was not raised");
        // A fall, upstairs (the floor is the zombie's, as it lands); a player's landing is not a zombie's.
        zombie.z = 1f;
        zombie.DoLand(FallingConstants.getIsoImpactSpeedFromHeight(1f));
        check(zombie.falls == 1 && drain().equals(List.of(List.of("fall", 16.0, 10.5, 1.0, 10.0, zombie))), "The fall was not raised");
        player.DoLand(FallingConstants.getIsoImpactSpeedFromHeight(1f));
        check(drain().isEmpty(), "A player's landing was raised");
        zombie.z = 0f;
        later();
    }

    /** The radius: across the ground from any local player, the largest a mod listens with; a mod's 0 or clear takes its own away. */
    private static void heard(KahluaTable zombies, Object mod, Object second) {
        var far = zombie(50f, 10.5f, 0f);
        far.parameterZombieState.setState(State.LockTarget);
        check(sounds().pending() == 0, "A zombie beyond the radius was noted");
        // Exactly at the radius, and upstairs: heard (the floor is the mod's to judge).
        var edge = zombie(40.5f, 10.5f, 3f);
        edge.parameterZombieState.setState(State.LockTarget);
        check(drain().equals(List.of(List.of("lunge", 40.5, 10.5, 3.0, 40.0, edge))), "A zombie at the radius was not heard");
        // A second player near the far one.
        var other = new IsoPlayer();
        other.x = 55f; other.y = 10.5f;
        IsoPlayer.players[1] = other;
        far.parameterZombieState.setState(State.Hit);
        check(drain().size() == 1, "A zombie near the second player was not heard");
        IsoPlayer.players[1] = null;
        // A second mod listening farther: the largest radius is used, and taken back with its 0.
        check((Double)FormulasTest.call(zombies, "listen", second, 60.0).get(0) == 60.0, "The larger radius is not in effect");
        far.parameterZombieState.setState(State.LockTarget);
        check(drain().size() == 1, "The larger radius was not used");
        check((Double)FormulasTest.call(zombies, "listen", second, 0.0).get(0) == 30.0, "A radius of 0 did not take the mod's away");
        far.parameterZombieState.setState(State.Hit);
        check(sounds().pending() == 0, "The radius taken back was still used");
        // handle:clear() stops a mod listening; nil does as 0.
        FormulasTest.call(zombies, "listen", second, 45.0);
        FormulasTest.call(second, "clear");
        check(sounds().radius() == 30.0, "clear did not stop the mod listening: " + sounds().radius());
        FormulasTest.call(zombies, "listen", mod);
        check(sounds().radius() == 0, "Listening with no radius did not stop it");
        var near = zombie(11f, 10.5f, 0f);
        near.parameterZombieState.setState(State.LockTarget);
        check(sounds().pending() == 0 && drain().isEmpty(), "Something was noted after the last mod stopped");
        FormulasTest.call(zombies, "listen", mod, 30.0);
        later();
    }

    /** The same kind from the same zombie within a second is raised once; another kind, or another zombie, is not a repeat. */
    private static void repeats(KahluaTable zombies, Object mod) {
        var zombie = zombie(12f, 10.5f, 0f);
        var other = zombie(13f, 10.5f, 0f);
        long before = sounds().repeats();
        zombie.parameterZombieState.setState(State.Hit);
        zombie.parameterZombieState.setState(State.Idle);
        zombie.parameterZombieState.setState(State.Hit);
        other.parameterZombieState.setState(State.Hit);
        zombie.parameterZombieState.setState(State.Attack);
        var events = drain();
        check(events.size() == 3 && events.get(0).get(5) == zombie && events.get(1).get(5) == other && events.get(2).get(0).equals("attack"),
            "The repeat was not left out: " + events);
        check(sounds().repeats() == before + 1, "The repeat was not counted");
        // A repeat in another frame is a repeat too, until a second has passed.
        NOW.addAndGet(ZombieSounds.REPEAT_NANOS / 2);
        zombie.parameterZombieState.setState(State.Idle);
        zombie.parameterZombieState.setState(State.Hit);
        check(drain().isEmpty(), "A repeat half a second later was raised");
        NOW.addAndGet(ZombieSounds.REPEAT_NANOS / 2 + 1);
        zombie.parameterZombieState.setState(State.Idle);
        zombie.parameterZombieState.setState(State.Hit);
        check(drain().size() == 1, "A hit a second later was not raised");
        // More zombies than the repeats are kept for: none is lost, the oldest is forgotten first.
        later();
        var many = new ArrayList<IsoZombie>();
        for (int index = 0; index < 40; index++) many.add(zombie(12f, 12f, 0f));
        for (var each : many) each.parameterZombieState.setState(State.Hit);
        check(drain().size() == 40, "Forty zombies' hits were not all raised");
        later();
    }

    /** At most 8 events a frame, the oldest first; a ring of 64 written over from its oldest when the frames fall behind. */
    private static void capped(KahluaTable zombies, Object mod) {
        var twenty = new ArrayList<IsoZombie>();
        for (int index = 0; index < 20; index++) twenty.add(zombie(12f + index * 0.1f, 10.5f, 0f));
        for (var each : twenty) each.parameterZombieState.setState(State.LockTarget);
        int[] sizes = new int[3];
        for (int frame = 0; frame < 3; frame++) {
            LuaEventManager.raised.clear();
            frame();
            sizes[frame] = LuaEventManager.raised.size();
            if (frame == 0) check(LuaEventManager.raised.get(0).get(6) == twenty.get(0) && LuaEventManager.raised.get(7).get(6) == twenty.get(7),
                "The first frame did not raise the oldest");
        }
        check(Arrays.equals(sizes, new int[] { 8, 8, 4 }), "The frames raised " + Arrays.toString(sizes));
        later();
        long overwritten = sounds().overwritten();
        var hundred = new ArrayList<IsoZombie>();
        for (int index = 0; index < 100; index++) hundred.add(zombie(12f, 10.5f + index * 0.01f, 0f));
        for (var each : hundred) each.parameterZombieState.setState(State.LockTarget);
        check(sounds().pending() == ZombieSounds.CAPACITY && sounds().overwritten() == overwritten + 36, "The ring did not keep the newest 64");
        var events = drain();
        check(events.size() == 64 && events.get(0).get(5) == hundred.get(36) && events.get(63).get(5) == hundred.get(99),
            "The newest 64 were not raised oldest first");
        LuaEventManager.raised.clear();
        later();
    }

    /** A hook on another thread (the world's worker, when the game threads the world): the event is raised by the game's frame. */
    private static void threads(KahluaTable zombies, Object mod) throws Exception {
        var zombie = zombie(12f, 10.5f, 0f);
        var worker = new Thread(() -> {
            for (int round = 0; round < 1000; round++) {
                zombie.parameterZombieState.setState(State.Hit);
                zombie.parameterZombieState.setState(State.Idle);
            }
        });
        worker.start();
        worker.join();
        LuaEventManager.raised.clear();
        frame();
        check(LuaEventManager.raised.size() == 1 && LuaEventManager.lastThread == Thread.currentThread(),
            "A hit on another thread was not raised once on the frame's thread");
        drain();
        // Two threads at once, against the frame: what is noted stays whole (the ring is kept under its lock).
        var writers = new Thread[2];
        for (int index = 0; index < writers.length; index++) {
            writers[index] = new Thread(() -> {
                for (int round = 0; round < 20000; round++) {
                    var each = zombie(12f, 10.5f, 0f);
                    each.parameterZombieState.setState(State.LockTarget);
                }
            });
            writers[index].start();
        }
        while (writers[0].isAlive() || writers[1].isAlive()) {
            LuaEventManager.raised.clear();
            frame();
            for (var raised : LuaEventManager.raised)
                check(raised.get(1).equals("lunge") && raised.get(2).equals(12.0) && raised.get(6) instanceof IsoZombie, "A torn event: " + raised);
        }
        for (var writer : writers) writer.join();
        drain();
        later();
    }

    /** A hook whose handler fails: the game's method goes on as it would, and the API keeps running. */
    private static void faults(KahluaTable zombies, Object mod, IsoPlayer player) {
        Hooks.setZombieSounds(new Hooks.ZombieSounds() {
            @Override public void state(Object zombie, Object from, Object to) { throw new IllegalStateException("broken"); }
            @Override public void voice(Object zombie) { throw new IllegalStateException("broken"); }
            @Override public void landed(Object zombie) { throw new IllegalStateException("broken"); }
        });
        var zombie = zombie(12f, 10.5f, 0f);
        zombie.parameterZombieState.setState(State.LockTarget);
        new ZombieVocalsManager.Slot().playSound(zombie);
        zombie.DoLand(FallingConstants.getIsoImpactSpeedFromHeight(1f));
        check(zombie.parameterZombieState.isState(State.LockTarget) && zombie.getEmitter().vocals == 1 && zombie.vocalEvent != 0L
            && zombie.falls == 1, "A hook that failed stopped the game's method");
        check(drain().isEmpty(), "A failed hook raised an event");
        // The API listens again as a mod asks.
        FormulasTest.call(zombies, "listen", mod, 30.0);
        zombie.parameterZombieState.setState(State.Hit);
        check(drain().size() == 1, "The API did not take the hooks back");
        later();
    }

    /** What a hook costs: with nobody listening (one volatile read), and listening, out of the radius and noted. Printed. */
    private static void bench(KahluaTable zombies, Object mod) {
        var near = zombie(12f, 10.5f, 0f);
        var far = zombie(500f, 10.5f, 0f);
        int rounds = 2_000_000;
        double[] took = new double[3];
        long bytes = 0;
        FormulasTest.call(zombies, "listen", mod, 0.0);
        for (int warm = 0; warm < 2; warm++) {
            // Two state changes a round, each a change (the game's early return is not what is measured).
            long start = System.nanoTime();
            for (int n = 0; n < rounds; n++) { near.parameterZombieState.setState(State.Hit); near.parameterZombieState.setState(State.Idle); }
            took[0] = (System.nanoTime() - start) / (2.0 * rounds);
        }
        FormulasTest.call(zombies, "listen", mod, 30.0);
        for (int warm = 0; warm < 2; warm++) {
            long start = System.nanoTime();
            for (int n = 0; n < rounds; n++) { far.parameterZombieState.setState(State.Hit); far.parameterZombieState.setState(State.Idle); }
            took[1] = (System.nanoTime() - start) / (2.0 * rounds);
            long before = allocated();
            start = System.nanoTime();
            for (int n = 0; n < rounds; n++) { near.parameterZombieState.setState(State.Hit); near.parameterZombieState.setState(State.Idle); }
            took[2] = (System.nanoTime() - start) / (2.0 * rounds);
            bytes = allocated() - before;
        }
        // The game's early return for the same state, which never reaches the hook: the call alone.
        double same = 0;
        for (int warm = 0; warm < 2; warm++) {
            long start = System.nanoTime();
            for (int n = 0; n < rounds; n++) { near.parameterZombieState.setState(State.Idle); near.parameterZombieState.setState(State.Idle); }
            same = (System.nanoTime() - start) / (2.0 * rounds);
        }
        System.out.printf("zombie sounds: a voice state change %.1f ns with nobody listening, %.1f ns listening (out of the radius), %.1f ns noted (every other one a hit,"
            + " the ring written over); %.1f ns for a call that returns early (no hook reached); %d bytes allocated by %d changes noted%n",
            took[0], took[1], took[2], same, bytes, 2 * rounds);
        check(bytes < 16384, "The hooks allocated " + bytes + " bytes");
        drain();
        later();
    }

    private static void arguments(KahluaTable zombies, Object mod) {
        rejects(zombies, "the first argument must be a handle from PZExtAPI.client", "not a handle", 10.0);
        rejects(zombies, "radius must be a number from 0.0 to 1000.0", mod, -1.0);
        rejects(zombies, "radius must be a number from 0.0 to 1000.0", mod, 1000.5);
        rejects(zombies, "radius must be a number from 0.0 to 1000.0", mod, "far");
        check(sounds().radius() == 30.0, "A refused call changed the radius");
    }

    /** A newer API takes the listening over; the function a mod kept refuses to be called. */
    private static void takeover(KahluaTable api, Object mod) throws Exception {
        var zombies = (KahluaTable)api.rawget("zombies");
        Object kept = zombies.rawget("listen");
        var older = sounds();
        GameApi.register(LuaManager.class);
        check(sounds() != older && sounds().radius() == 30.0, "A newer API did not take the listening over");
        var zombie = zombie(12f, 10.5f, 0f);
        zombie.parameterZombieState.setState(State.Death);
        check(drain().size() == 1, "A newer API did not raise the event");
        try {
            invoke(kept, mod, 10.0);
            throw new AssertionError("A function of the older API was still called");
        } catch (IllegalArgumentException refused) {
            check(refused.getMessage().contains("the API was updated"), refused.getMessage());
        }
        check(zombies.rawget("listen") != kept, "The function was not replaced");
        later();
    }

    /** A world left takes the listening with it: the mods listen again in the next one. */
    private static void worldLeft(KahluaTable api, Object mod) {
        IsoWorld.instance.setCell(new IsoCell());
        frame();
        check(sounds().radius() == 0, "The listening outlived its world");
        var zombie = zombie(12f, 10.5f, 0f);
        zombie.parameterZombieState.setState(State.LockTarget);
        check(sounds().pending() == 0 && drain().isEmpty(), "A zombie of the next world was heard with nobody listening there");
    }

    // ---- helpers ----

    private static void rejects(KahluaTable zombies, String message, Object... arguments) {
        try { FormulasTest.call(zombies, "listen", arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.zombies.listen: ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError("listen accepted bad arguments: " + message);
    }

    private static List<Object> invoke(Object function, Object... arguments) {
        var frame = new se.krka.kahlua.vm.LuaCallFrame(arguments);
        ((se.krka.kahlua.vm.JavaFunction)function).call(frame, arguments.length);
        return frame.results;
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
