package pztools.api;

import java.util.ArrayList;
import java.util.List;
import pztools.bridge.ApiHooks;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaEventManager;
import zombie.characters.BodyDamage.BodyPartType;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.inventory.types.HandWeapon;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;

/**
 * The hits zombies take, against the synthetic game: {@code zombies.watchHits} and {@code OnPZToolsZombieHit}. The game's own method
 * ({@code IsoZombie.Hit}) is called, with the hook the agent put in it.
 */
final class ZombieHitsTest {
    private static final ClassLoader GAME = ZombieHitsTest.class.getClassLoader();
    private static final String EVENT = "OnPZToolsZombieHit";

    private ZombieHitsTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        try {
            IsoWorld.instance.setCell(new IsoCell());
            var player = new IsoPlayer();
            player.x = 10.5f; player.y = 10.5f;
            IsoPlayer.players[0] = player;
            GameApi.frame(GAME);
            var zombies = (KahluaTable)api.rawget("zombies");
            check(zombies.rawget("watchHits") != null && LuaEventManager.added.contains(EVENT), "zombies.watchHits or its event is missing");
            check(ApiHooks.APPLIED.equals(ApiHooks.hookStatus().get("IsoZombie.Hit")), "IsoZombie.Hit is " + ApiHooks.hookStatus().get("IsoZombie.Hit"));
            Object mod = FormulasTest.call(api, "client", "hits.mod").get(0), second = FormulasTest.call(api, "client", "hits.second").get(0);
            nobody(zombies, player);
            hits(zombies, mod, player);
            watchers(zombies, mod, second, player);
            capped(zombies, mod, player);
            threads(zombies, mod, player);
            faults(zombies, mod, player);
            bench(zombies, mod, player);
            arguments(zombies, mod);
            worldLeft(api, zombies, mod);
        } finally {
            IsoWorld.instance.setCell(home);
            IsoPlayer.players[0] = null;
            LuaEventManager.raised.clear();
        }
    }

    private static IsoZombie zombie(float health) {
        var zombie = new IsoZombie();
        zombie.health = health;
        return zombie;
    }

    private static ZombieHits hits() { return GameApi.hits(); }

    /** The events raised by the frames until none is noted, as (zombie, attacker, weapon, part, damage, killed). */
    private static List<List<Object>> drain() {
        LuaEventManager.raised.clear();
        for (int frames = 0; frames < 20 && hits().pending() > 0; frames++) GameApi.frame(GAME);
        GameApi.frame(GAME);
        var events = new ArrayList<List<Object>>();
        for (var raised : LuaEventManager.raised) {
            check(raised.get(0).equals(EVENT), "Another event was raised: " + raised);
            events.add(raised.subList(1, raised.size()));
        }
        LuaEventManager.raised.clear();
        return events;
    }

    /** Nobody watches: the hook notes nothing, and the game's own method runs as it would. */
    private static void nobody(KahluaTable zombies, IsoPlayer player) {
        var zombie = zombie(10f);
        float dealt = zombie.Hit(new HandWeapon(1f), player, 3f, false, 1f, false);
        check(dealt == 3f && zombie.health == 7f && zombie.hits == 1, "The game's own method did not run");
        check(hits().pending() == 0 && !hits().watched() && drain().isEmpty(), "Something was noted with nobody watching");
    }

    /** The zombie, the attacker, the weapon, the part, the damage the game dealt and whether it died. */
    private static void hits(KahluaTable zombies, Object mod, IsoPlayer player) {
        check(FormulasTest.call(zombies, "watchHits", mod, true).get(0) == Boolean.TRUE, "watchHits did not answer that it watches");
        var weapon = new HandWeapon(1f);
        var zombie = zombie(10f);
        zombie.nextHitPart = BodyPartType.Hand_L;
        float dealt = zombie.Hit(weapon, player, 4f, false, 1f, false);
        check(dealt == 4f && hits().pending() == 1, "The hit was not noted");
        check(drain().equals(List.of(List.of(zombie, player, weapon, "Hand_L", 4.0, false))), "The hit was not raised as it should be");
        // A kill: the zombie is dead as the hit left it, with the damage that did it.
        zombie.nextHitPart = BodyPartType.Torso_Upper;
        zombie.Hit(weapon, player, 20f, false, 1f, false);
        check(drain().equals(List.of(List.of(zombie, player, weapon, "Torso_Upper", 20.0, true))), "The kill was not raised as a kill");
        // The game's early return for a zombie that cannot be hurt is before the hit: nothing.
        var immortal = zombie(10f);
        immortal.immortal = true;
        check(immortal.Hit(weapon, player, 4f, false, 1f, false) == 0f && drain().isEmpty(), "A hit the game did not take was raised");
        // A hit turned away (the damage 0 the game's own hook gives) is a hit of no damage.
        var turned = zombie(10f);
        check(turned.Hit(null, player, 4f, false, 1f, false) == 0f, "The game's own method did not turn the hit away");
        check(drain().equals(List.of(java.util.Arrays.asList(turned, player, null, "Torso_Upper", 0.0, false))), "A hit of no damage was not raised as one");
        // Another attacker: the game's own character is the attacker, not only a player.
        var attacker = new IsoZombie();
        zombie.health = 10f;
        zombie.Hit(weapon, attacker, 1f, false, 1f, false);
        check(drain().get(0).get(1) == attacker, "The attacker was not the one that hit");
    }

    /** Two mods watch; the hook stays while one does, and is given back with the last. */
    private static void watchers(KahluaTable zombies, Object mod, Object second, IsoPlayer player) {
        var weapon = new HandWeapon(1f);
        var zombie = zombie(100f);
        check(FormulasTest.call(zombies, "watchHits", second, true).get(0) == Boolean.TRUE, "A second mod could not watch");
        FormulasTest.call(zombies, "watchHits", mod, false);
        check(hits().watched(), "The hook was given back with a mod still watching");
        zombie.Hit(weapon, player, 1f, false, 1f, false);
        check(drain().size() == 1, "A hit was not raised for the mod still watching");
        FormulasTest.call(second, "clear");
        check(!hits().watched() && FormulasTest.call(zombies, "watchHits", mod, false).get(0) == Boolean.FALSE, "clear did not stop the last mod watching");
        zombie.Hit(weapon, player, 1f, false, 1f, false);
        check(hits().pending() == 0 && drain().isEmpty(), "Something was noted after the last mod stopped");
        // nil is as false.
        FormulasTest.call(zombies, "watchHits", mod, true);
        FormulasTest.call(zombies, "watchHits", mod);
        check(!hits().watched(), "Watching with no answer did not stop it");
        FormulasTest.call(zombies, "watchHits", mod, true);
    }

    /** At most 16 events a frame, the oldest first; a ring of 64 written over from its oldest when the frames fall behind. */
    private static void capped(KahluaTable zombies, Object mod, IsoPlayer player) {
        var weapon = new HandWeapon(1f);
        var twenty = new ArrayList<IsoZombie>();
        for (int index = 0; index < 20; index++) twenty.add(zombie(100f));
        for (var each : twenty) each.Hit(weapon, player, 1f, false, 1f, false);
        int[] sizes = new int[2];
        for (int frame = 0; frame < 2; frame++) {
            LuaEventManager.raised.clear();
            GameApi.frame(GAME);
            sizes[frame] = LuaEventManager.raised.size();
            if (frame == 0) check(LuaEventManager.raised.get(0).get(1) == twenty.get(0) && LuaEventManager.raised.get(15).get(1) == twenty.get(15),
                "The first frame did not raise the oldest");
        }
        check(sizes[0] == ZombieHits.MAX_PER_FRAME && sizes[1] == 4, "The frames raised " + sizes[0] + ", " + sizes[1]);
        long overwritten = hits().overwritten();
        var hundred = new ArrayList<IsoZombie>();
        for (int index = 0; index < 100; index++) hundred.add(zombie(100f));
        for (var each : hundred) each.Hit(weapon, player, 1f, false, 1f, false);
        check(hits().pending() == ZombieHits.CAPACITY && hits().overwritten() == overwritten + 36, "The ring did not keep the newest 64");
        var events = drain();
        check(events.size() == 64 && events.get(0).get(0) == hundred.get(36) && events.get(63).get(0) == hundred.get(99),
            "The newest 64 were not raised oldest first");
    }

    /** A hit on another thread: the event is raised by the game's frame, on its thread. */
    private static void threads(KahluaTable zombies, Object mod, IsoPlayer player) throws Exception {
        var weapon = new HandWeapon(1f);
        var zombie = zombie(1e9f);
        var worker = new Thread(() -> { for (int round = 0; round < 10; round++) zombie.Hit(weapon, player, 1f, false, 1f, false); });
        worker.start();
        worker.join();
        LuaEventManager.raised.clear();
        GameApi.frame(GAME);
        check(LuaEventManager.raised.size() == 10 && LuaEventManager.lastThread == Thread.currentThread(),
            "Hits on another thread were not raised on the frame's thread: " + LuaEventManager.raised.size());
        drain();
        // Two threads at once, against the frame: what is noted stays whole.
        var writers = new Thread[2];
        for (int index = 0; index < writers.length; index++) {
            writers[index] = new Thread(() -> { for (int round = 0; round < 20000; round++) zombie.Hit(weapon, player, 1f, false, 1f, false); });
            writers[index].start();
        }
        while (writers[0].isAlive() || writers[1].isAlive()) {
            LuaEventManager.raised.clear();
            GameApi.frame(GAME);
            for (var raised : LuaEventManager.raised)
                check(raised.get(1) == zombie && raised.get(2) == player && raised.get(3) == weapon && raised.get(5).equals(1.0), "A torn event: " + raised);
        }
        for (var writer : writers) writer.join();
        drain();
    }

    /** A hook whose handler fails: the game's method goes on as it would, and the API keeps running. */
    private static void faults(KahluaTable zombies, Object mod, IsoPlayer player) {
        ApiHooks.setZombieHits(new ApiHooks.ZombieHits() {
            @Override public void hit(Object zombie, Object attacker, Object weapon, float damage) { throw new IllegalStateException("broken"); }
        });
        var zombie = zombie(10f);
        float dealt = zombie.Hit(new HandWeapon(1f), player, 2f, false, 1f, false);
        check(dealt == 2f && zombie.health == 8f, "A hook that failed stopped the game's method");
        check(drain().isEmpty(), "A failed hook raised an event");
        // The API takes the hook back as a mod asks.
        FormulasTest.call(zombies, "watchHits", mod, false);
        FormulasTest.call(zombies, "watchHits", mod, true);
        zombie.Hit(new HandWeapon(1f), player, 2f, false, 1f, false);
        check(drain().size() == 1, "The API did not take the hook back");
    }

    /** What the hook costs: with nobody watching (one volatile read), and watching. Printed. */
    private static void bench(KahluaTable zombies, Object mod, IsoPlayer player) {
        var weapon = new HandWeapon(1f);
        var zombie = zombie(1e9f);
        int rounds = 1_000_000;
        double[] took = new double[2];
        long bytes = 0;
        FormulasTest.call(zombies, "watchHits", mod, false);
        for (int warm = 0; warm < 2; warm++) {
            long start = System.nanoTime();
            for (int n = 0; n < rounds; n++) zombie.Hit(weapon, player, 1f, false, 1f, false);
            took[0] = (System.nanoTime() - start) / (double)rounds;
        }
        FormulasTest.call(zombies, "watchHits", mod, true);
        for (int warm = 0; warm < 2; warm++) {
            long before = allocated();
            long start = System.nanoTime();
            for (int n = 0; n < rounds; n++) zombie.Hit(weapon, player, 1f, false, 1f, false);
            took[1] = (System.nanoTime() - start) / (double)rounds;
            bytes = allocated() - before;
        }
        System.out.printf("zombie hits: a hit costs %.1f ns with nobody watching, %.1f ns noted; %d bytes allocated over %d noted hits%n",
            took[0], took[1], bytes, rounds);
        check(bytes < 16384, "The hook allocated " + bytes + " bytes over " + rounds + " hits");
        drain();
    }

    private static void arguments(KahluaTable zombies, Object mod) {
        rejects(zombies, "the first argument must be a handle", null, true);
        rejects(zombies, "the first argument must be a handle", "hits.mod", true);
        rejects(zombies, "on must be true or false", mod, "yes");
    }

    private static void rejects(Object table, String message, Object... arguments) {
        try { FormulasTest.call(table, "watchHits", arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError("watchHits accepted bad arguments: " + message);
    }

    /** A world left takes the watching with it: the mods watch again in the next one. */
    private static void worldLeft(KahluaTable api, KahluaTable zombies, Object mod) {
        FormulasTest.call(zombies, "watchHits", mod, true);
        check(hits().watched(), "The mod does not watch");
        IsoWorld.instance.setCell(new IsoCell());
        GameApi.frame(GAME);
        check(!hits().watched() && FormulasTest.call(zombies, "watchHits", mod, false).get(0) == Boolean.FALSE, "A world left kept the watching");
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
