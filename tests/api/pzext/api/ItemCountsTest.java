package pzext.api;

import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import zombie.characters.IsoPlayer;
import zombie.inventory.InventoryItem;
import zombie.inventory.types.InventoryContainer;
import zombie.scripting.objects.ItemTag;

/**
 * {@code PZExtAPI.items.count} against the synthetic game: items of a type or with a tag in a character's inventory and its
 * bags at any depth, kept up item by item by the inventory hooks (a question after a change counts nothing again), worked out
 * again when a list changes in a way that does not say how, and the names it refuses.
 */
final class ItemCountsTest {
    private ItemCountsTest() { }

    static void run(KahluaTable api) throws Exception {
        KahluaTable items = (KahluaTable)api.rawget("items");
        check(items != null, "There is no PZExtAPI.items");
        Formulas formulas = formulasObject();
        var player = new IsoPlayer();
        player.inventory.items.clear();
        var clip = put(player.inventory.getItems(), "Base.Paperclip");
        var bag = new InventoryContainer("Bag", 1f, 30);
        player.inventory.AddItem(bag);
        var pouch = new InventoryContainer("Pouch", 0.2f, 5);
        bag.getInventory().AddItem(pouch);
        bag.getInventory().AddItem(item("Base.Paperclip"));
        pouch.getInventory().AddItem(item("Base.Paperclip"));
        var driver = item("Base.Screwdriver");
        driver.tags.add(ItemTag.SCREWDRIVER);
        pouch.getInventory().AddItem(driver);

        check(count(items, player, "Base.Paperclip") == 3, "The clips in the inventory, the bag and the pouch in it are not 3");
        check(count(items, player, "base:screwdriver") == 1, "The screwdriver in the pouch was not counted by its tag");
        check(count(items, bag.getInventory(), "Base.Paperclip") == 2, "A container is not counted with its own bags");

        // Kept up: a change and the next question count nothing again.
        long recounts = formulas.itemRecounts();
        var spare = item("Base.Paperclip");
        pouch.getInventory().AddItem(spare);
        player.inventory.Remove(clip);
        check(count(items, player, "Base.Paperclip") == 3 && formulas.itemRecounts() == recounts,
            "An item in and another out were not kept up item by item: " + (formulas.itemRecounts() - recounts) + " lists counted again");
        bag.getInventory().Remove(pouch);
        check(count(items, player, "Base.Paperclip") == 1 && count(items, player, "base:screwdriver") == 0,
            "A bag taken out still counts");
        player.inventory.AddItem(pouch);
        check(count(items, player, "Base.Paperclip") == 3, "A bag put in does not count");

        // A change that does not say which items: counted again at the next question.
        bag.getInventory().getItems().removeIf(item -> item.fullType.equals("Base.Paperclip"));
        check(count(items, player, "Base.Paperclip") == 2, "A list changed without saying how kept its old count");
        bag.getInventory().removeAllItems();
        check(count(items, player, "Base.Paperclip") == 2, "An emptied bag kept a count");

        // A new name counts every list again once.
        recounts = formulas.itemRecounts();
        check(count(items, player, "Base.Nail") == 0 && formulas.itemRecounts() > recounts, "A new name did not count the lists again");

        for (Object[] refused : new Object[][] {
                { player, "base:nosuchtag" }, { player, "Paperclip" }, { player, "Base." }, { "player", "Base.Paperclip" } }) {
            try {
                FormulasTest.call(items, "count", refused);
                throw new AssertionError("items.count took " + refused[0] + ", " + refused[1]);
            } catch (RuntimeException expected) { }
        }

        // Cost: a question when nothing changed.
        long started = System.nanoTime();
        int rounds = 100_000, sum = 0;
        for (int round = 0; round < rounds; round++) sum += count(items, player, "Base.Paperclip");
        System.out.printf("items.count: %.0f ns a question over an inventory with two bags (nothing changed)%n",
            (System.nanoTime() - started) / (double)rounds);
        check(sum == rounds * 2, "The count changed on its own");
        player.inventory.items.clear();
        System.out.println("PASS: items.count counts by type and tag through bags, kept up by the inventory hooks");
    }

    private static InventoryItem item(String type) {
        var item = new InventoryItem("Tool", 0.1f);
        item.fullType = type;
        return item;
    }

    private static InventoryItem put(List<InventoryItem> list, String type) {
        var item = item(type);
        list.add(item);
        return item;
    }

    private static int count(KahluaTable items, Object owner, String name) {
        return ((Double)FormulasTest.call(items, "count", owner, name).get(0)).intValue();
    }

    private static Formulas formulasObject() throws Exception {
        var field = GameApi.class.getDeclaredField("formulas");
        field.setAccessible(true);
        return (Formulas)field.get(null);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
