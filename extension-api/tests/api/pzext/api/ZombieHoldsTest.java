package pzext.api;

import java.util.List;
import pzext.boot.Hooks;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.WorldSoundManager;
import zombie.ai.states.ZombieIdleState;
import zombie.characters.IsoZombie;
import zombie.iso.IsoWorld;
import zombie.iso.objects.IsoDeadBody;
import zombie.popman.ZombiePopulationManager;
import zombie.world.moddata.ModData;

/**
 * {@code zombies.mark} and the rest, and {@code hold} and {@code release}, against the synthetic game: a mod's marks are its own,
 * the world keeps them by the zombie's number while it is virtual and gives them back, a corpse keeps a copy, the dead and the let
 * go are forgotten; an idle marked zombie wanders within the circle, one near it hears players and the area's sounds but not far
 * ones, one that went further is the game's, one of a dissolving hold goes as its chunk unloads while others stay virtual, and the
 * hooks answer as the game once nothing is held.
 */
final class ZombieHoldsTest {
    private ZombieHoldsTest() { }

    static void run(KahluaTable api) throws Exception {
        var zombies = (KahluaTable)api.rawget("zombies");
        Object mod = FormulasTest.call(api, "client", "holds.mod").get(0);
        Object other = FormulasTest.call(api, "client", "holds.other").get(0);
        for (String function : ZombieHolds.FUNCTIONS) check(zombies.rawget(function) != null, "zombies." + function + " is missing");
        ZombieHolds holds = GameApi.holds();
        check(holds != null, "The holds are missing");
        ModData.tables.remove(ZombieHolds.MARKS);
        var loaded = IsoWorld.instance.currentCell.zombieList;
        String[] labels = { "ZombieIdleState.execute", "WorldSoundManager.getBiggestSoundZomb", "ZombiePopulationManager.removeChunkFromWorld",
            "ZombiePopulationManager.registerZombie", "ZombiePopulationManager.releaseZombie", "ZombiePopulationManager.virtualizeZombie",
            "IsoZombie.removeFromWorld" };

        var held = zombie(105.5f, 100.5f, 1);
        var plain = zombie(105.5f, 100.5f, 2);
        // Nothing held: the game's own wander.
        ZombieIdleState.stepX = 30; ZombieIdleState.stepY = 0;
        ZombieIdleState.instance().execute(held);
        check(held.pathX == 135 && held.pathY == 100, "A zombie wandered otherwise with nothing held: " + held.pathX);

        // Marks: each mod's its own; the world keeps them by the zombie's number.
        FormulasTest.call(zombies, "mark", mod, held, "clear");
        FormulasTest.call(zombies, "mark", other, held, "theirs");
        check("clear".equals(markOf(zombies, mod, held)) && "theirs".equals(markOf(zombies, other, held)), "A mark was not kept");
        check(markOf(zombies, mod, plain) == null, "An unmarked zombie had a mark");
        var world = ModData.get(ZombieHolds.MARKS);
        check(world != null && world.rawget(1.0) instanceof KahluaTable kept && "theirs".equals(kept.rawget("holds.other")),
            "The world did not keep the marks");
        loaded.add(held); loaded.add(plain);
        var found = (KahluaTable)FormulasTest.call(zombies, "marked", mod, "clear").get(0);
        check(found.len() == 1 && found.rawget(1) == held, "marked listed " + found.len());

        FormulasTest.call(zombies, "hold", mod, "clear", table("x", 100.0, "y", 100.0, "radius", 10.0, "dissolve", true));
        // Held: a wander out of the circle is brought in along the line to the centre; one inside is left; an unmarked one is the game's.
        ZombieIdleState.instance().execute(held);
        check(held.pathX == 108 && held.pathY == 100, "A held zombie wandered out of its circle: " + held.pathX + "," + held.pathY);
        ZombieIdleState.stepX = 2;
        ZombieIdleState.instance().execute(held);
        check(held.pathX == 107, "A wander inside the circle was changed: " + held.pathX);
        ZombieIdleState.stepX = 30;
        ZombieIdleState.instance().execute(plain);
        check(plain.pathX == 135, "An unmarked zombie was held");
        // Where a zombie wanders and what it hears are asked on whatever thread the game updates it on (PZ Optimization's workers),
        // while Lua writes marks on the game's thread: from the Java-side snapshot alone. A marks table that fails when read says so.
        Object realMarks = held.getModData().rawget(ZombieHolds.MARKS);
        held.getModData().rawset(ZombieHolds.MARKS, java.lang.reflect.Proxy.newProxyInstance(KahluaTable.class.getClassLoader(),
            new Class<?>[] { KahluaTable.class }, (proxy, method, arguments) -> { throw new AssertionError("a hook read a Lua table: " + method); }));
        try {
            var worker = new Object() { int path; boolean heard; Throwable failure; };
            var thread = new Thread(() -> {
                try {
                    held.pathX = 0;
                    ZombieIdleState.instance().execute(held);
                    worker.path = held.pathX;
                } catch (Throwable failure) { worker.failure = failure; }
            });
            thread.start();
            thread.join();
            check(worker.failure == null && worker.path == 108, "A held zombie was not held on another thread: " + worker.path + " " + worker.failure);
        } finally {
            held.getModData().rawset(ZombieHolds.MARKS, realMarks);
        }
        check(holds.snapshots() == 1, "The marked zombies' snapshots: " + holds.snapshots());
        // Chased out past the margin (10 + 20): the game's again.
        var away = zombie(135.5f, 100.5f, 3);
        FormulasTest.call(zombies, "mark", mod, away, "clear");
        ZombieIdleState.instance().execute(away);
        check(away.pathX == 165, "A zombie past the margin was still held: " + away.pathX);

        // Sounds: a far alarm is not heard by a held zombie; a player's is, and one in the area; other zombies hear all.
        var sounds = WorldSoundManager.instance.soundList;
        var alarm = new WorldSoundManager.WorldSound(400, 100, 600, false);
        var near = new WorldSoundManager.WorldSound(110, 100, 50, false);
        var player = new WorldSoundManager.WorldSound(300, 100, 80, true);
        sounds.add(alarm); sounds.add(near);
        check(heard(held) == near, "A held zombie heard a far sound");
        check(heard(plain) == alarm, "An unmarked zombie did not hear the loudest");
        sounds.add(player);
        check(heard(held) == player, "A held zombie did not hear a player");
        check(heard(away) == alarm, "A zombie past the margin did not hear the loudest");

        // Virtual and back: the zombie's object loses its marks as it leaves; the zombie has them again when it comes back.
        var walker = zombie(50.5f, 50.5f, 4);
        FormulasTest.call(zombies, "mark", mod, walker, "walk");
        check(holds.snapshots() == 3, "The marked zombies' snapshots: " + holds.snapshots());
        walker.removeFromWorld();
        check(markOf(zombies, mod, walker) == null && holds.snapshots() == 2, "A zombie's object kept its marks after it left");
        var back = new IsoZombie();
        back.persistentId = ZombiePopulationManager.registerZombie(back, 4);
        check("walk".equals(markOf(zombies, mod, back)), "A zombie came back without its mark");
        var fresh = new IsoZombie();
        fresh.persistentId = ZombiePopulationManager.registerZombie(fresh, 0);
        check(markOf(zombies, mod, fresh) == null, "A new zombie came with a mark");

        // Unloading: a held zombie of a dissolving hold goes, and the world forgets it; another stays virtual and leaves its marks.
        var population = ZombiePopulationManager.instance;
        ZombiePopulationManager.virtual.clear(); ZombiePopulationManager.released.clear();
        population.onChunk.add(held); population.onChunk.add(plain); population.onChunk.add(away);
        population.removeChunkFromWorld(null);
        check(ZombiePopulationManager.released.equals(List.of(1, 3)) && ZombiePopulationManager.virtual.equals(List.of(2)),
            "Unloading kept " + ZombiePopulationManager.virtual + ", let go " + ZombiePopulationManager.released);
        check(world.rawget(1.0) == null && world.rawget(3.0) == null, "The world kept the marks of zombies let go");
        check(markOf(zombies, mod, held) == null, "A zombie let go kept its marks");
        // Walking out of the loaded area: one of a dissolving hold leaves the world; another stays virtual.
        var strayed = zombie(90.5f, 100.5f, 9);
        FormulasTest.call(zombies, "mark", mod, strayed, "clear");
        var passer = zombie(90.5f, 101.5f, 10);
        ZombiePopulationManager.virtual.clear(); ZombiePopulationManager.released.clear();
        population.virtualizeZombie(strayed);
        population.virtualizeZombie(passer);
        check(ZombiePopulationManager.virtual.equals(List.of(10))
            && strayed.removed && strayed.square == null && world.rawget(9.0) == null,
            "Walking out kept " + ZombiePopulationManager.virtual + ", let go " + ZombiePopulationManager.released);
        loaded.remove(held); loaded.remove(plain);

        // Death: as the game, the population lets the dead zombie go and its number is taken before the corpse is made; the
        // corpse keeps a copy, the world forgets the zombie.
        var victim = zombie(101.5f, 100.5f, 5);
        FormulasTest.call(zombies, "mark", mod, victim, "target");
        victim.dead = true;
        ZombiePopulationManager.releaseZombie(victim);
        victim.persistentId = 0;
        check(world.rawget(5.0) == null, "The world kept a dead zombie's marks");
        var body = new IsoDeadBody(victim);
        check("target".equals(markOf(zombies, mod, body)), "A corpse lost its zombie's mark");
        check(markOf(zombies, mod, victim) == null && world.rawget(5.0) == null, "A dead zombie's marks were kept");
        FormulasTest.call(zombies, "unmark", mod, body);
        check(markOf(zombies, mod, body) == null, "A corpse kept a mark taken off");

        // Unmarked: one mod's mark goes, another's stays, the world forgets a zombie with none.
        var both = zombie(60.5f, 60.5f, 7);
        FormulasTest.call(zombies, "mark", mod, both, "x");
        FormulasTest.call(zombies, "mark", other, both, "y");
        FormulasTest.call(zombies, "unmark", mod, both);
        check(markOf(zombies, mod, both) == null && "y".equals(markOf(zombies, other, both)) && world.rawget(7.0) != null, "Unmarking took the wrong mark");
        FormulasTest.call(zombies, "unmark", other, both);
        check(world.rawget(7.0) == null, "The world kept a zombie with no mark");

        // Forgotten: a key goes from the world, virtual zombies included, and from the loaded ones.
        var loose = zombie(70.5f, 70.5f, 6);
        FormulasTest.call(zombies, "mark", mod, loose, "walk");
        loaded.add(loose); loaded.add(back);
        FormulasTest.call(zombies, "forget", mod, "walk");
        check(markOf(zombies, mod, loose) == null && markOf(zombies, mod, back) == null && world.rawget(4.0) == null && world.rawget(6.0) == null,
            "A forgotten key stayed");
        check(holds.marksOf("holds.mod") == 0 && holds.markedInWorld() == 0,
            "The world's marks are miscounted: " + holds.marksOf("holds.mod") + ", " + holds.markedInWorld());
        loaded.remove(loose); loaded.remove(back);

        for (String label : labels) check(Hooks.APPLIED.equals(Hooks.hookStatus().get(label)), label + " is " + Hooks.hookStatus().get(label));
        // Refused: no handle, a bad radius, a bad key, something not a zombie.
        rejects(zombies, "hold", "first argument must be a handle", "nobody", "clear", table("x", 1.0, "y", 1.0, "radius", 5.0));
        rejects(zombies, "hold", "radius must be", mod, "clear", table("x", 1.0, "y", 1.0, "radius", 0.0));
        rejects(zombies, "mark", "key", mod, zombie(1f, 1f, 8), "no spaces");
        rejects(zombies, "mark", "a living zombie", mod, "zombie", "clear");
        rejects(zombies, "markOf", "a zombie or a corpse", mod, 5.0);

        // Released: the game's answers again.
        FormulasTest.call(zombies, "mark", mod, held, "clear");
        FormulasTest.call(zombies, "release", mod, "clear");
        ZombieIdleState.instance().execute(held);
        check(held.pathX == 135 && heard(held) == alarm, "A released zombie was still held");
        check(holds.holds().length == 0, "Holds were left after release");
        // handle:clear() takes a mod's holds; its marks stay.
        FormulasTest.call(zombies, "hold", mod, "again", table("x", 100.0, "y", 100.0, "radius", 10.0));
        FormulasTest.call(mod, "clear");
        check(holds.holds().length == 0, "A cleared handle still held zombies");
        check("clear".equals(markOf(zombies, mod, held)), "A cleared handle lost its marks");
        sounds.clear();
        ModData.tables.remove(ZombieHolds.MARKS);
        ZombieIdleState.stepX = 0; ZombieIdleState.stepY = 0;
    }

    private static Object markOf(KahluaTable zombies, Object mod, Object object) {
        return FormulasTest.call(zombies, "markOf", mod, object).get(0);
    }

    private static Object heard(IsoZombie zombie) {
        return WorldSoundManager.instance.getBiggestSoundZomb(0, 0, 0, true, zombie).sound;
    }

    private static IsoZombie zombie(float x, float y, int id) {
        var zombie = new IsoZombie();
        zombie.x = x; zombie.y = y;
        zombie.persistentId = id;
        zombie.square = IsoWorld.instance.currentCell.load((int)x, (int)y, 0);
        return zombie;
    }

    private static KahluaTable table(Object... pairs) {
        KahluaTable result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static void rejects(KahluaTable zombies, String function, String message, Object... arguments) {
        try { FormulasTest.call(zombies, function, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError("zombies." + function + " took bad arguments: " + message);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
