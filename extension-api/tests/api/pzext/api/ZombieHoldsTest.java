package pzext.api;

import pzext.boot.Hooks;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.WorldSoundManager;
import zombie.ai.states.ZombieIdleState;
import zombie.characters.IsoZombie;
import zombie.popman.ZombiePopulationManager;

/**
 * {@code zombies.hold} and {@code release}, against the synthetic game: an idle zombie of the outfit wanders within the circle, one
 * near it hears players and the area's sounds but not far ones, one that went further is the game's, one of a dissolving hold goes
 * as its chunk unloads while others stay virtual, and the hooks answer as the game once nothing is held.
 */
final class ZombieHoldsTest {
    private ZombieHoldsTest() { }

    static void run(KahluaTable api) throws Exception {
        var zombies = (KahluaTable)api.rawget("zombies");
        Object mod = FormulasTest.call(api, "client", "holds.mod").get(0);
        check(GameApi.holds() != null && zombies.rawget("hold") != null, "zombies.hold is missing");
        String[] labels = { "ZombieIdleState.execute", "WorldSoundManager.getBiggestSoundZomb", "ZombiePopulationManager.removeChunkFromWorld" };

        var held = zombie("OA_Clear", 105.5f, 100.5f, 1);
        var other = zombie("Police", 105.5f, 100.5f, 2);
        // Nothing held: the game's own wander.
        ZombieIdleState.stepX = 30; ZombieIdleState.stepY = 0;
        ZombieIdleState.instance().execute(held);
        check(held.pathX == 135 && held.pathY == 100, "A zombie wandered otherwise with nothing held: " + held.pathX);

        FormulasTest.call(zombies, "hold", mod, "clear", table("outfit", "OA_Clear", "x", 100.0, "y", 100.0, "radius", 10.0, "dissolve", true));
        // Held: a wander out of the circle is brought in along the line to the centre; one inside is left; another outfit is the game's.
        ZombieIdleState.instance().execute(held);
        check(held.pathX == 108 && held.pathY == 100, "A held zombie wandered out of its circle: " + held.pathX + "," + held.pathY);
        ZombieIdleState.stepX = 2;
        ZombieIdleState.instance().execute(held);
        check(held.pathX == 107, "A wander inside the circle was changed: " + held.pathX);
        ZombieIdleState.stepX = 30;
        ZombieIdleState.instance().execute(other);
        check(other.pathX == 135, "A zombie of another outfit was held");
        // Chased out past the margin (10 + 20): the game's again.
        var away = zombie("OA_Clear", 135.5f, 100.5f, 3);
        ZombieIdleState.instance().execute(away);
        check(away.pathX == 165, "A zombie past the margin was still held: " + away.pathX);

        // Sounds: a far alarm is not heard by a held zombie; a player's is, and one in the area; other zombies hear all.
        var sounds = WorldSoundManager.instance.soundList;
        var alarm = new WorldSoundManager.WorldSound(400, 100, 600, false);
        var near = new WorldSoundManager.WorldSound(110, 100, 50, false);
        var player = new WorldSoundManager.WorldSound(300, 100, 80, true);
        sounds.add(alarm); sounds.add(near);
        check(heard(held) == near, "A held zombie heard a far sound");
        check(heard(other) == alarm, "A zombie of another outfit did not hear the loudest");
        sounds.add(player);
        check(heard(held) == player, "A held zombie did not hear a player");
        check(heard(away) == alarm, "A zombie past the margin did not hear the loudest");

        // Unloading: a held zombie of a dissolving hold goes; another stays virtual.
        var population = ZombiePopulationManager.instance;
        ZombiePopulationManager.virtual.clear(); ZombiePopulationManager.released.clear();
        population.onChunk.add(held); population.onChunk.add(other); population.onChunk.add(away);
        population.removeChunkFromWorld(null);
        check(ZombiePopulationManager.released.equals(java.util.List.of(1, 3)) && ZombiePopulationManager.virtual.equals(java.util.List.of(2)),
            "Unloading kept " + ZombiePopulationManager.virtual + ", let go " + ZombiePopulationManager.released);

        for (String label : labels) check(Hooks.APPLIED.equals(Hooks.hookStatus().get(label)), label + " is " + Hooks.hookStatus().get(label));
        // Refused: no handle, a bad radius, a missing outfit.
        rejects(zombies, "first argument must be a handle", "nobody", "clear", table("outfit", "A", "x", 1.0, "y", 1.0, "radius", 5.0));
        rejects(zombies, "radius must be", mod, "clear", table("outfit", "A", "x", 1.0, "y", 1.0, "radius", 0.0));
        rejects(zombies, "outfit must be", mod, "clear", table("x", 1.0, "y", 1.0, "radius", 5.0));

        // Released: the game's answers again, and the hooks are let go.
        FormulasTest.call(zombies, "release", mod, "clear");
        ZombieIdleState.instance().execute(held);
        check(held.pathX == 135 && heard(held) == alarm, "A released zombie was still held");
        check(GameApi.holds().holds().isEmpty(), "Holds were left after release");
        // handle:clear() takes a mod's holds.
        FormulasTest.call(zombies, "hold", mod, "again", table("outfit", "OA_Clear", "x", 100.0, "y", 100.0, "radius", 10.0));
        FormulasTest.call(mod, "clear");
        check(GameApi.holds().holds().isEmpty(), "A cleared handle still held zombies");
        sounds.clear();
        ZombieIdleState.stepX = 0; ZombieIdleState.stepY = 0;
    }

    private static Object heard(IsoZombie zombie) {
        return WorldSoundManager.instance.getBiggestSoundZomb(0, 0, 0, true, zombie).sound;
    }

    private static IsoZombie zombie(String outfit, float x, float y, int id) {
        var zombie = new IsoZombie();
        zombie.outfitName = outfit;
        zombie.x = x; zombie.y = y;
        zombie.persistentId = id;
        return zombie;
    }

    private static KahluaTable table(Object... pairs) {
        KahluaTable result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static void rejects(KahluaTable zombies, String message, Object... arguments) {
        try { FormulasTest.call(zombies, "hold", arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError("zombies.hold took bad arguments: " + message);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
