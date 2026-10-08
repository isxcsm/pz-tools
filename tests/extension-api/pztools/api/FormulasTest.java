package pztools.api;

import java.util.List;
import se.krka.kahlua.vm.*;
import zombie.characters.CharacterStat;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoPlayer;
import zombie.characters.BodyDamage.BodyPartType;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;
import zombie.Lua.LuaManager;
import pztools.bridge.ApiHooks;

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
        combining(api, formulas, player);
        faults(api, formulas, player);
        world(api, formulas, player);
        takeover(api, formulas, player);
        IsoPlayer.players[0] = null;
    }

    private static void points(KahluaTable formulas) {
        var points = (KahluaTable)call(formulas, "points").get(0);
        for (String applied : new String[] { "body.discomfortMultiplier", "body.stiffnessMultiplier", "body.fatigueMultiplier",
                "body.enduranceDrainMultiplier", "body.poisonMultiplier" })
            check(ApiHooks.APPLIED.equals(points.rawget(applied)), applied + " is " + points.rawget(applied));
        check("planned".equals(points.rawget("loot.spawnMultiplier")), "A point not built yet is " + points.rawget("loot.spawnMultiplier"));
        check(Formulas.POINTS.size() == 29, "The points are " + Formulas.POINTS.size());
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
        // A point whose hooks are not built yet takes a value and keeps nothing.
        call(formulas, "set", mod, "loot.spawnMultiplier", 1.5);
        check(call(formulas, "get", "loot.spawnMultiplier").get(0) == null, "A point not built yet kept a value");
        rejects(formulas, "set", "must be a number, a boolean, a string or a table", mod, "loot.spawnMultiplier", new Object());
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
        ApiHooks.setFormulas(null);
        check(player.getClothingDiscomfortModifier() == 3f, "Without a handler the game's answer changed");
        GameApi.register(LuaManager.class);
        check(player.getClothingDiscomfortModifier() == 1.5f, "A newer API did not take the formulas back");
        call(mod, "clear");
    }

    /** The declarations belong to the world they were made in. */
    private static void world(KahluaTable api, KahluaTable formulas, IsoPlayer player) throws Exception {
        Object mod = call(api, "client", "world.mod").get(0);
        player.clothingDiscomfortModifier = 2f;
        IsoCell home = IsoWorld.instance.cell;
        GameApi.frame(FormulasTest.class.getClassLoader());
        call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        check(player.getClothingDiscomfortModifier() == 1f, "The formula does not apply");
        // The player leaves the world: no cell, then another.
        IsoWorld.instance.cell = null;
        GameApi.frame(FormulasTest.class.getClassLoader());
        check(player.getClothingDiscomfortModifier() == 2f && call(formulas, "get", "body.discomfortMultiplier").get(0) == null,
            "A formula outlived the world it was declared in");
        IsoWorld.instance.cell = new IsoCell();
        GameApi.frame(FormulasTest.class.getClassLoader());
        // Declared in the new world, before its first frame: kept.
        call(formulas, "set", mod, "body.discomfortMultiplier", 0.5);
        GameApi.frame(FormulasTest.class.getClassLoader());
        check(player.getClothingDiscomfortModifier() == 1f, "A formula declared in a new world was dropped");
        IsoWorld.instance.cell = null;
        GameApi.frame(FormulasTest.class.getClassLoader());
        IsoWorld.instance.cell = home;
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

    private static List<Object> call(Object table, String name, Object... arguments) {
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

    private static List<Object> invoke(Object function, Object... arguments) {
        var frame = new LuaCallFrame(arguments);
        int count = ((JavaFunction)function).call(frame, arguments.length);
        check(count == frame.results.size(), "The result count is wrong");
        return frame.results;
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
