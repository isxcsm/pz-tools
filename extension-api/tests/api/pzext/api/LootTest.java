package pzext.api;

import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.SandboxOptions;
import zombie.inventory.ItemPickerJava;
import zombie.scripting.itemConfig.Randomizer;
import zombie.scripting.itemConfig.SelectorBucket;
import zombie.scripting.objects.Item;
import pzext.boot.Hooks;

/**
 * The kinds of loot a mod defines, against the synthetic game: an item listed is of the mod's kind, rolled by the mod's sandbox
 * option as the game rolls its own kinds by theirs; the game's own items and kinds stay the game's; the option read as the game
 * rolls; another mod's item refused, the mod's own moved; what is refused; clear; a newer API; a handler that fails; no allocation.
 * And the config of an item the loot spawns (its script's ItemConfig), which the game's own bucket with none under it broke.
 */
final class LootTest {
    private LootTest() { }

    static void run(KahluaTable api) throws Exception {
        // An item's config: a bucket with none under it resolves (the game gives it none and reads their number).
        var leaf = new SelectorBucket(new int[0], null, null, new Randomizer());
        check(Hooks.APPLIED.equals(Hooks.hookStatus().get("SelectorBucket.<init>:children")), "The hook of the configs' buckets is "
            + Hooks.hookStatus().get("SelectorBucket.<init>:children"));
        check(new SelectorBucket(new int[0], null, new SelectorBucket[] { leaf }, null).Resolve(), "A config with a bucket with none under it failed");

        var loot = (KahluaTable)api.rawget("loot");
        check(loot != null, "The API has no loot");
        var parts = new SandboxOptions.DoubleSandboxOption(0.6);
        SandboxOptions.instance.optionByName.put("LootMod.PartsLoot", parts);
        SandboxOptions.instance.optionByName.put("LootMod.Rare", new SandboxOptions.DoubleSandboxOption(0.2));
        SandboxOptions.instance.optionByName.put("LootMod.Switch", new SandboxOptions.BooleanSandboxOption(true));
        Object mod = FormulasTest.call(api, "client", "LootMod").get(0), other = FormulasTest.call(api, "client", "OtherMod").get(0);
        var item = new ItemPickerJava.ItemPickerItem();
        item.itemName = "LootMod.Part";
        check(ItemPickerJava.getLootType(new Item("LootMod.Part")).equals("Other"), "An item no mod listed is not the game's kind");
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 5), "The chance changed with nothing defined");

        // Defined: the item is of the mod's kind, and its chance goes with the mod's option, read as the game rolls.
        var name = FormulasTest.call(loot, "define", mod, "Parts", table("option", "LootMod.PartsLoot", "items", list("LootMod.Part", "LootMod.Wire"))).get(0);
        check("LootMod:Parts".equals(name), "The kind is named " + name);
        check(ItemPickerJava.getLootType(new Item("LootMod.Part")).equals("LootMod:Parts")
            && ItemPickerJava.getLootType(new Item("LootMod.Wire")).equals("LootMod:Parts"), "The items are not of the mod's kind");
        check("LootMod:Parts".equals(FormulasTest.call(loot, "kindOf", "LootMod.Wire").get(0)) && FormulasTest.call(loot, "kindOf", "Base.Axe").get(0) == null,
            "kindOf does not say the mod's kind alone");
        check(near(ItemPickerJava.getLootModifierFromType("LootMod:Parts"), 0.6), "The kind's modifier is not the option's");
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 3), "The chance did not go with the mod's option");
        parts.setValue(2.0);
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 10), "The option's value now was not read");
        parts.setValue(0.0);
        check(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false) == 0f, "An option at 0 did not keep the item out, as the game's do");
        parts.setValue(0.6);
        // The game's own items and kinds are the game's.
        check(ItemPickerJava.getLootType(new Item("Base.Generator")).equals("Generator") && ItemPickerJava.getLootModifierFromType("Generator") == 4f
            && ItemPickerJava.getLootModifierFromType("Other") == 1f && ItemPickerJava.getLootModifierFromType("Ammo") == 1f, "The game's kinds changed");

        // Another mod cannot take the item; the mod's own moves between its kinds.
        rejects(loot, "is in the mod LootMod's kind LootMod:Parts", "define", other, "Grab", table("option", "LootMod.Rare", "items", list("LootMod.Part")));
        FormulasTest.call(loot, "define", mod, "Rare", table("option", "LootMod.Rare", "items", list("LootMod.Wire")));
        check(ItemPickerJava.getLootType(new Item("LootMod.Wire")).equals("LootMod:Rare") && near(ItemPickerJava.getLootModifier("LootMod.Wire"), 0.2)
            && ItemPickerJava.getLootType(new Item("LootMod.Part")).equals("LootMod:Parts"), "The mod's item did not move to its other kind");
        // Defined again: the items it lists now.
        FormulasTest.call(loot, "define", mod, "Parts", table("option", "LootMod.PartsLoot", "items", list("LootMod.Part", "LootMod.Bolt")));
        check(ItemPickerJava.getLootType(new Item("LootMod.Bolt")).equals("LootMod:Parts") && ItemPickerJava.getLootType(new Item("LootMod.Wire")).equals("LootMod:Rare"),
            "Defined again, the kind does not hold what it lists now");

        // Required options: every entry on, one of a list; read as the game rolls; at 0 while one is off.
        var water = new SandboxOptions.BooleanSandboxOption(true);
        var pumps = new SandboxOptions.BooleanSandboxOption(false);
        var sprinklers = new SandboxOptions.BooleanSandboxOption(true);
        SandboxOptions.instance.optionByName.put("LootMod.Water", water);
        SandboxOptions.instance.optionByName.put("LootMod.Pumps", pumps);
        SandboxOptions.instance.optionByName.put("LootMod.Sprinklers", sprinklers);
        FormulasTest.call(loot, "define", mod, "Parts", table("option", "LootMod.PartsLoot", "items", list("LootMod.Part", "LootMod.Bolt"),
            "requires", list("LootMod.Water", list("LootMod.Pumps", "LootMod.Sprinklers"))));
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 3), "A kind whose requirements are on was not rolled by its option");
        sprinklers.setValue(false);
        check(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false) == 0f && ItemPickerJava.getLootModifierFromType("LootMod:Parts") == 0f,
            "A kind none of a list of whose requirements is on was rolled");
        pumps.setValue(true);
        check(near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 3), "One of a list on did not do");
        water.setValue(false);
        check(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false) == 0f, "A kind with a requirement off was rolled");
        water.setValue(true);
        check(((String)api.getMetatable().rawget("loot")).contains("LootMod.Bolt\tLootMod.Water\u001eLootMod.Pumps\u001fLootMod.Sprinklers"),
            "The requirements were not kept: " + api.getMetatable().rawget("loot"));
        rejects(loot, "spec.requires: the sandbox option LootMod.Rare is not a boolean option", "define", mod, "Parts",
            table("option", "LootMod.PartsLoot", "items", list("LootMod.Part"), "requires", list("LootMod.Rare")));
        rejects(loot, "spec.requires must be a list", "define", mod, "Parts",
            table("option", "LootMod.PartsLoot", "items", list("LootMod.Part"), "requires", list(list())));
        rejects(loot, "spec.requires: the sandbox has no option LootMod.None", "define", mod, "Parts",
            table("option", "LootMod.PartsLoot", "items", list("LootMod.Part"), "requires", list(list("LootMod.Water", "LootMod.None"))));

        // What is refused.
        rejects(loot, "has no option LootMod.Nothing", "define", mod, "Gone", table("option", "LootMod.Nothing", "items", list("LootMod.Gone")));
        rejects(loot, "is not a number option", "define", mod, "Gone", table("option", "LootMod.Switch", "items", list("LootMod.Gone")));
        rejects(loot, "is not an item's full type", "define", mod, "Gone", table("option", "LootMod.Rare", "items", list("Gone")));
        rejects(loot, "has no field chance", "define", mod, "Gone", table("option", "LootMod.Rare", "items", list("LootMod.Gone"), "chance", 1.0));
        rejects(loot, "spec.items must be", "define", mod, "Gone", table("option", "LootMod.Rare"));
        rejects(loot, "the first argument must be a handle", "define", "LootMod", "Gone", table("option", "LootMod.Rare", "items", list("LootMod.Gone")));

        // An option gone (its mod's options not loaded): the game's modifier of other loot.
        SandboxOptions.instance.optionByName.remove("LootMod.Rare");
        check(ItemPickerJava.getLootModifier("LootMod.Wire") == 1f, "A kind whose option is gone did not roll as other loot");
        SandboxOptions.instance.optionByName.put("LootMod.Rare", new SandboxOptions.DoubleSandboxOption(0.2));

        cheap(item);
        takeover(api, loot, mod);
        failing(item);

        // Cleared: the items are the game's kinds again.
        FormulasTest.call(mod, "clear");
        check(ItemPickerJava.getLootType(new Item("LootMod.Part")).equals("Other") && FormulasTest.call(loot, "kindOf", "LootMod.Part").get(0) == null,
            "Cleared, the item kept the mod's kind");
        for (String option : new String[] { "LootMod.PartsLoot", "LootMod.Rare", "LootMod.Switch", "LootMod.Water", "LootMod.Pumps", "LootMod.Sprinklers" }) SandboxOptions.instance.optionByName.remove(option);
    }

    /** Asked for every item rolled: nothing allocated, for a listed item or another. */
    private static void cheap(ItemPickerJava.ItemPickerItem item) {
        var listed = new Item("LootMod.Part");
        var game = new Item("Base.Axe");
        for (int index = 0; index < 1000; index++) { ItemPickerJava.getLootType(listed); ItemPickerJava.getLootModifierFromType("LootMod:Parts"); }
        long before = allocated();
        for (int index = 0; index < 100000; index++) {
            Hooks.lootType("Other", listed.getFullName());
            Hooks.lootType("Other", game.getFullName());
            Hooks.lootModifier("LootMod:Parts");
            Hooks.lootModifier("Other");
        }
        long bytes = allocated() - before;
        check(bytes < 16384, "The loot hooks allocated " + bytes + " bytes in 100000 rolls");
    }

    /** A newer API takes the kinds over; a function a mod kept from before says the API was updated. */
    private static void takeover(KahluaTable api, KahluaTable loot, Object mod) throws Exception {
        Object text = api.getMetatable().rawget("loot");
        check(text instanceof String kept && kept.startsWith("pzext-loot 1\n") && kept.contains("K\tLootMod\tParts\tLootMod.PartsLoot\tLootMod.Part\u001fLootMod.Bolt"),
            "The kinds were not kept: " + text);
        Object define = loot.rawget("define");
        GameApi.register(LuaManager.class);
        check(api.rawget("loot") == loot && loot.rawget("define") != define, "A newer API did not replace the functions in the same table");
        check(ItemPickerJava.getLootType(new Item("LootMod.Part")).equals("LootMod:Parts") && near(ItemPickerJava.getLootModifier("LootMod.Wire"), 0.2),
            "A newer API lost a kind");
        try { FormulasTest.call(table("define", define), "define", mod, "Parts", table()); throw new AssertionError("A function kept from before the takeover ran"); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.loot.define: the API was updated"), expected.getMessage());
        }
    }

    /** A handler that fails gives the game's answers; a newer API answers again. */
    private static void failing(ItemPickerJava.ItemPickerItem item) throws Exception {
        Hooks.setLoot(new Hooks.Loot() {
            @Override public String type(String vanilla, String fullType) { throw new IllegalStateException("broken"); }
            @Override public float modifier(String type) { throw new IllegalStateException("broken"); }
        });
        check(ItemPickerJava.getLootType(new Item("LootMod.Part")).equals("Other") && near(ItemPickerJava.getActualSpawnChance(item, null, null, 0f, false), 5),
            "A failing handler did not give the game's answers");
        Hooks.setLoot(null);
        check(ItemPickerJava.getLootType(new Item("LootMod.Part")).equals("Other"), "Without an API, the item was not the game's kind");
        GameApi.register(LuaManager.class);
        check(ItemPickerJava.getLootType(new Item("LootMod.Part")).equals("LootMod:Parts"), "The API did not answer again");
    }

    // ---- helpers ----

    private static KahluaTable table(Object... pairs) {
        var result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static KahluaTable list(Object... items) {
        var result = LuaManager.platform.newTable();
        for (int index = 0; index < items.length; index++) result.rawset((double)(index + 1), items[index]);
        return result;
    }

    private static void rejects(KahluaTable loot, String message, String name, Object... arguments) {
        try { FormulasTest.call(loot, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.loot." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static boolean near(double value, double expected) { return Math.abs(value - expected) < 1e-5; }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
