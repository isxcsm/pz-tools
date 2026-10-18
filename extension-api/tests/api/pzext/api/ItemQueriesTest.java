package pzext.api;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.characters.IsoPlayer;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.inventory.types.InventoryContainer;
import zombie.iso.IsoObject;
import zombie.iso.sprite.IsoSprite;
import zombie.scripting.objects.ItemTag;

/**
 * {@code PZExtAPI.items.find} and {@code items.types} against the synthetic game: the item match (type, tag in the three forms
 * mods name one, mod data, prefix, broken, favorite, worn, held and on the hotbar), the sources (a container, a bag, a character, a
 * world object with several containers), the depth and the limit, the match kept by its table, the names it refuses, and what
 * a walk costs.
 */
final class ItemQueriesTest {
    private ItemQueriesTest() { }

    static void run(KahluaTable api) throws Exception {
        KahluaTable items = (KahluaTable)api.rawget("items");
        check(items.rawget("find") != null && items.rawget("types") != null, "There is no PZExtAPI.items.find or types");
        var player = new IsoPlayer();
        player.inventory.items.clear();
        var clip = item("Base.Paperclip");
        player.inventory.AddItem(clip);
        var bag = new InventoryContainer("Bag", 1f, 30);
        bag.fullType = "Base.Bag";
        player.inventory.AddItem(bag);
        var clip2 = item("Base.Paperclip");
        bag.getInventory().AddItem(clip2);
        var pouch = new InventoryContainer("Pouch", 0.2f, 5);
        pouch.fullType = "Base.Pouch";
        bag.getInventory().AddItem(pouch);
        var clip3 = item("Base.Paperclip");
        pouch.getInventory().AddItem(clip3);
        var driver = item("Base.Screwdriver");
        driver.tags.add(ItemTag.SCREWDRIVER);
        pouch.getInventory().AddItem(driver);
        // Three bags deeper: the pouch is at depth 2 from the player's inventory, the clip in the last at depth 5.
        var inner = new InventoryContainer("Inner", 0.1f, 5);
        inner.fullType = "Base.Pouch";
        pouch.getInventory().AddItem(inner);
        var innerer = new InventoryContainer("Innerer", 0.1f, 5);
        innerer.fullType = "Base.Pouch";
        inner.getInventory().AddItem(innerer);
        var deepClip = item("Base.Paperclip");
        innerer.getInventory().AddItem(deepClip);

        // type, depth, the container each is in.
        List<Object> found = find(items, player.inventory, table("type", list("Base.Paperclip")), null);
        check(found.get(0) instanceof KahluaTable && found.size() == 2, "find does not give two lists");
        check(got(found.get(0)).equals(ids(clip, clip2, clip3)), "type: the clips to depth 3 are not the first, the bag's and the pouch's: " + got(found.get(0)));
        check(got(found.get(1)).equals(ids(player.inventory, bag.getInventory(), pouch.getInventory())),
            "type: the containers are not each clip's own: " + got(found.get(1)));
        check(got(find(items, player.inventory, table("type", list("Base.Paperclip")), table("depth", 5.0)).get(0))
            .equals(ids(clip, clip2, clip3, deepClip)), "depth 5 does not reach the deepest clip");
        check(got(find(items, player.inventory, table("type", list("Base.Paperclip")), table("depth", 0.0)).get(0)).equals(ids(clip)),
            "depth 0 looks into bags");
        check(got(find(items, player.inventory, table("type", list("Base.Paperclip")), table("depth", 1.0)).get(0)).equals(ids(clip, clip2)),
            "depth 1 does not stop in the bag's own items");
        check(got(find(items, player.inventory, table("type", list("Base.Paperclip")), table("limit", 2.0)).get(0)).equals(ids(clip, clip2)),
            "limit 2 gives another count");
        check(find(items, player.inventory, table("type", list("Base.Paperclip")), table("limit", 0.0)).get(0) instanceof KahluaTable none
            && none.len() == 0, "limit 0 gives items");
        check(got(find(items, player.inventory, table("type", list("Base.Pouch", "Base.Nothing")), null).get(0)).equals(ids(pouch, inner, innerer)),
            "bags are not matched as items, or not in the order own items then bags");
        check(got(find(items, player.inventory, null, table("depth", 0.0)).get(0)).equals(ids(clip, bag)), "a nil match does not give every item");
        check(got(find(items, player.inventory, table(), table("depth", 1.0)).get(0)).equals(ids(clip, bag, clip2, pouch)), "an empty match does not give every item");

        // tag: the object, the constant's name, the registered name, a plain one.
        for (Object name : new Object[] { ItemTag.SCREWDRIVER, "SCREWDRIVER", "base:screwdriver", "screwdriver", "Screwdriver" }) {
            check(got(find(items, player.inventory, table("tag", list(name)), null).get(0)).equals(ids(driver)), "tag " + name + " does not find the driver");
        }
        check(got(find(items, player.inventory, table("tag", list("KEY_RING", "SCREWDRIVER")), null).get(0)).equals(ids(driver)), "a tag of two does not find the driver");
        check(got(find(items, player.inventory, table("tag", "SCREWDRIVER"), null).get(0)).equals(ids(driver)), "a single tag name is not taken as a list");
        check(got(find(items, player.inventory, table("tag", list("KEY_RING")), null).get(0)).isEmpty(), "a tag nobody has finds something");
        check(got(find(items, player.inventory, table("type", list("Base.Paperclip"), "tag", list("SCREWDRIVER")), null).get(0)).isEmpty(),
            "type and tag together are not both required");

        // data: a key, key = value, a prefix.
        var marked = item("Base.Note");
        marked.getModData().rawset("Mission", "Find#3");
        marked.getModData().rawset("Count", 4.0);
        marked.getModData().rawset("Done", false);
        var plain = item("Base.Note");
        plain.getModData().rawset("Other", true);
        var bare = item("Base.Note");
        var near = item("Base.Note");
        near.getModData().rawset("Mission", "Find2");
        var whole = item("Base.Note");
        whole.getModData().rawset("Mission", "Find");
        for (var note : List.of(marked, plain, bare, near, whole)) pouch.getInventory().AddItem(note);
        check(got(find(items, pouch.getInventory(), table("data", "Mission"), null).get(0)).equals(ids(marked, near, whole)), "data: a key present is not any value");
        check(got(find(items, pouch.getInventory(), table("data", "Done"), null).get(0)).equals(ids(marked)), "data: a false value is not present");
        check(got(find(items, pouch.getInventory(), table("data", table("Mission", "Find#3")), null).get(0)).equals(ids(marked)), "data: key = value");
        check(got(find(items, pouch.getInventory(), table("data", table("Count", 4.0, "Mission", "Find#3")), null).get(0)).equals(ids(marked)), "data: two pairs");
        check(got(find(items, pouch.getInventory(), table("data", table("Count", 5.0)), null).get(0)).isEmpty(), "data: another number matches");
        check(got(find(items, pouch.getInventory(), table("data", table("Done", false)), null).get(0)).equals(ids(marked)), "data: key = false");
        check(got(find(items, pouch.getInventory(), table("dataPrefix", table("Mission", "Find")), null).get(0)).equals(ids(marked, whole)),
            "dataPrefix: the prefix itself or the prefix and # and more, not 'Find2'");
        check(got(find(items, pouch.getInventory(), table("dataPrefix", table("Mission", "Find#3")), null).get(0)).equals(ids(marked)), "dataPrefix: equal");
        check(got(find(items, pouch.getInventory(), table("dataPrefix", table("Count", "4")), null).get(0)).isEmpty(), "dataPrefix: a number is a string");
        pouch.getInventory().Remove(marked); pouch.getInventory().Remove(plain); pouch.getInventory().Remove(bare);
        pouch.getInventory().Remove(near); pouch.getInventory().Remove(whole);

        // notBroken, notFavorite, notEquippedBy.
        var worn = item("Base.Hat");
        var held = item("Base.Hat");
        var hung = item("Base.Hat");
        var carried = item("Base.Hat");
        for (var hat : List.of(worn, held, hung, carried)) player.inventory.AddItem(hat);
        player.wear(worn);
        player.setPrimaryHandItem(held);
        player.hotbar.add(hung);
        carried.setBroken(true);
        var hats = table("type", list("Base.Hat"));
        check(got(find(items, player.inventory, hats, null).get(0)).equals(ids(worn, held, hung, carried)), "hats are not all four");
        check(got(find(items, player.inventory, table("type", list("Base.Hat"), "notEquippedBy", player), null).get(0)).equals(ids(carried)),
            "notEquippedBy keeps a worn, held or hotbar hat");
        check(got(find(items, player.inventory, table("type", list("Base.Hat"), "notBroken", true), null).get(0)).equals(ids(worn, held, hung)), "notBroken keeps a broken one");
        check(got(find(items, player.inventory, table("type", list("Base.Hat"), "notBroken", false), null).get(0)).equals(ids(worn, held, hung, carried)),
            "notBroken = false is tested");
        worn.setFavorite(true);
        check(got(find(items, player.inventory, table("type", list("Base.Hat"), "notFavorite", true), null).get(0)).equals(ids(held, hung, carried)), "notFavorite keeps a favorite");
        for (var hat : List.of(worn, held, hung, carried)) player.inventory.Remove(hat);
        player.takeOff(worn);
        player.setPrimaryHandItem(null);
        player.hotbar.clear();

        // sources: a bag, a character, a world object with two containers, an item that is no bag, the refused.
        check(got(find(items, bag, table("type", list("Base.Paperclip")), null).get(0)).equals(ids(clip2, clip3, deepClip)), "a bag is not looked into as its container");
        check(got(find(items, player, table("type", list("Base.Paperclip")), null).get(0)).equals(ids(clip, clip2, clip3)), "a character is not its inventory");
        var shelf = new IsoObject(new IsoSprite("shelf"));
        var top = new ItemContainer(shelf);
        var low = new ItemContainer(shelf);
        shelf.containers.add(top);
        shelf.containers.add(null);
        shelf.containers.add(low);
        var shelved = item("Base.Paperclip");
        var shelvedBag = new InventoryContainer("Box", 1f, 10);
        var boxed = item("Base.Paperclip");
        top.AddItem(shelved);
        low.AddItem(shelvedBag);
        shelvedBag.getInventory().AddItem(boxed);
        found = find(items, shelf, table("type", list("Base.Paperclip")), null);
        check(got(found.get(0)).equals(ids(shelved, boxed)) && got(found.get(1)).equals(ids(top, shelvedBag.getInventory())),
            "a world object's containers are not all looked into: " + got(found.get(0)));
        check(got(find(items, shelf, table("type", list("Base.Paperclip")), table("limit", 1.0)).get(0)).equals(ids(shelved)), "limit does not stop across containers");
        check(got(find(items, shelf, table("type", list("Base.Paperclip")), table("depth", 0.0)).get(0)).equals(ids(shelved)), "depth 0 on an object looks into bags");
        check(got(find(items, clip, table("type", list("Base.Paperclip")), null).get(0)).isEmpty(), "an item that is no bag holds items");
        check(got(find(items, new IsoObject(new IsoSprite("wall")), null, null).get(0)).isEmpty(), "an object without containers holds items");

        // types
        KahluaTable types = (KahluaTable)FormulasTest.call(items, "types", player.inventory).get(0);
        check(strings(types).equals(List.of("Base.Paperclip", "Base.Bag", "Base.Pouch", "Base.Screwdriver")),
            "types are not each once in the order met, to depth 3: " + strings(types));
        types = (KahluaTable)FormulasTest.call(items, "types", player.inventory, table("depth", 0.0)).get(0);
        check(strings(types).equals(List.of("Base.Paperclip", "Base.Bag")), "types, depth 0: " + strings(types));
        types = (KahluaTable)FormulasTest.call(items, "types", player.inventory, table("skip", table("Base.Bag", true, "Base.Paperclip", 1.0))).get(0);
        check(strings(types).equals(List.of("Base.Pouch", "Base.Screwdriver")), "types, skip: " + strings(types));
        types = (KahluaTable)FormulasTest.call(items, "types", shelf).get(0);
        check(strings(types).equals(List.of("Base.Paperclip", "Base.Item")), "types of an object: " + strings(types));

        // The match is read once, by its table.
        KahluaTable once = table("type", list("Base.Paperclip"));
        check(got(find(items, player.inventory, once, null).get(0)).equals(ids(clip, clip2, clip3)), "the match was not read");
        once.rawset("type", list("Base.Screwdriver"));
        check(got(find(items, player.inventory, once, null).get(0)).equals(ids(clip, clip2, clip3)), "a table changed after its first use was read again");
        check(got(find(items, player.inventory, table("type", list("Base.Screwdriver")), null).get(0)).equals(ids(driver)), "a new table is not read");
        // ... and goes with the table.
        Field cacheField = ItemMatch.class.getDeclaredField("CACHE");
        cacheField.setAccessible(true);
        Map<?, ?> cache = (Map<?, ?>)cacheField.get(null);
        KahluaTable gone = table("type", list("Base.Nail"));
        find(items, player.inventory, gone, null);
        int with;
        synchronized (cache) { with = cache.size(); }
        gone = null;
        int without = with;
        for (int attempt = 0; attempt < 20 && without >= with; attempt++) {
            System.gc();
            Thread.sleep(20);
            synchronized (cache) { without = cache.size(); }
        }
        check(without < with, "a match is kept after its table is gone (" + with + " kept, " + without + " after)");

        // The names it refuses.
        Object[][] refused = {
            { player.inventory, table("kind", list("x")), null, "match has the key kind" },
            { player.inventory, table("type", list(1.0)), null, "type[1]" },
            { player.inventory, table("type", 3.0), null, "type" },
            { player.inventory, table("tag", list("NO_SUCH_TAG")), null, "no item tag" },
            { player.inventory, table("tag", list(3.0)), null, "tag[1]" },
            { player.inventory, table("data", list("Mission")), null, "not a string" },
            { player.inventory, table("data", table("Mission", table())), null, "data.Mission" },
            { player.inventory, table("dataPrefix", table("Mission", 3.0)), null, "dataPrefix.Mission" },
            { player.inventory, table("dataPrefix", "Mission"), null, "dataPrefix" },
            { player.inventory, table("notBroken", "yes"), null, "notBroken" },
            { player.inventory, table("notEquippedBy", "me"), null, "notEquippedBy" },
            { player.inventory, "type", null, "match must be a table" },
            { player.inventory, null, table("depth", 40.0), "depth" },
            { player.inventory, null, table("depth", 1.5), "depth" },
            { player.inventory, null, table("limit", -1.0), "limit" },
            { player.inventory, null, "deep", "options" },
            { "inventory", null, null, "source" },
            { null, null, null, "source" },
        };
        for (Object[] call : refused) {
            try {
                FormulasTest.call(items, "find", call[0], call[1], call[2]);
                throw new AssertionError("items.find took " + call[3]);
            } catch (IllegalArgumentException expected) {
                check(expected.getMessage().startsWith("PZExtAPI.items.find: ") && expected.getMessage().contains((String)call[3]),
                    "items.find refused " + call[3] + " with " + expected.getMessage());
            }
        }
        for (Object[] call : new Object[][] { { "x", null, "source" }, { player.inventory, table("skip", 3.0), "skip" },
                { player.inventory, table("depth", -1.0), "depth" }, { player.inventory, "x", "options" } }) {
            try {
                FormulasTest.call(items, "types", call[0], call[1]);
                throw new AssertionError("items.types took " + call[2]);
            } catch (IllegalArgumentException expected) {
                check(expected.getMessage().startsWith("PZExtAPI.items.types: ") && expected.getMessage().contains((String)call[2]),
                    "items.types refused " + call[2] + " with " + expected.getMessage());
            }
        }

        // What a walk allocates: the two lists of the answer and nothing per item that does not match.
        var many = new ItemContainer(null);
        for (int index = 0; index < 2000; index++) many.AddItem(item("Base.Nail"));
        KahluaTable noMatch = table("type", list("Base.Screwdriver"), "notBroken", true);
        find(items, many, noMatch, null);
        long bytes = Allocations.median(9, () -> { for (int round = 0; round < 20; round++) find(items, many, noMatch, null); });
        System.out.printf("items.find: %d bytes allocated for 20 walks over 2000 items with no match%n", bytes);
        check(bytes < 20 * 2000, "A walk over items that do not match allocates " + bytes + " bytes for 20 walks over 2000 items");

        cost(items, player);
        player.inventory.items.clear();
        System.out.println("PASS: items.find and items.types walk containers, bags and world objects by an item match read once");
    }

    /** The cost of a walk over a few thousand items in bags in bags, per item and per kind of match. */
    private static void cost(KahluaTable items, IsoPlayer player) throws Exception {
        player.inventory.items.clear();
        player.hotbar.clear();
        int total = 0;
        var bags = new ArrayList<InventoryContainer>();
        for (int bagIndex = 0; bagIndex < 12; bagIndex++) {
            var bag = new InventoryContainer("Bag", 1f, 30);
            bag.fullType = "Base.Bag";
            player.inventory.AddItem(bag);
            bags.add(bag);
            total++;
            ItemContainer parent = bag.getInventory();
            // each bag holds a chain of three more, each with items.
            for (int level = 0; level < 4; level++) {
                for (int index = 0; index < 60; index++) {
                    var thing = item(index % 7 == 0 ? "Base.Screwdriver" : "Base.Nail");
                    if (index % 5 == 0) thing.getModData().rawset("Mission", "Find#" + index);
                    if (index % 11 == 0) thing.setBroken(true);
                    parent.AddItem(thing);
                    total++;
                }
                var next = new InventoryContainer("Bag", 1f, 30);
                next.fullType = "Base.Bag";
                parent.AddItem(next);
                total++;
                parent = next.getInventory();
            }
        }
        for (int index = 0; index < 100; index++) { player.inventory.AddItem(item("Base.Nail")); total++; }
        var driver = item("Base.Screwdriver");
        driver.tags.add(ItemTag.SCREWDRIVER);
        player.inventory.AddItem(driver);
        total++;
        var cases = new Object[][] {
            { "everything (nil match)", null },
            { "type (1)", table("type", list("Base.Screwdriver")) },
            { "type (8)", table("type", list("A.1", "A.2", "A.3", "A.4", "A.5", "A.6", "A.7", "Base.Screwdriver")) },
            { "tag", table("tag", list("SCREWDRIVER")) },
            { "type, notBroken, notEquippedBy", table("type", list("Base.Nail"), "notBroken", true, "notEquippedBy", player) },
            { "data key", table("data", "Mission") },
            { "dataPrefix", table("dataPrefix", table("Mission", "Find")) },
        };
        for (Object[] each : cases) {
            Object match = each[1];
            int rounds = 300, hits = 0;
            for (int warm = 0; warm < 200; warm++) hits = ((KahluaTable)FormulasTest.call(items, "find", player, match, table("depth", 5.0)).get(0)).len();
            long started = System.nanoTime();
            for (int round = 0; round < rounds; round++) hits = ((KahluaTable)FormulasTest.call(items, "find", player, match, table("depth", 5.0)).get(0)).len();
            System.out.printf("items.find: %6.1f ns an item over %d items in %d bags, %-34s (%d found)%n",
                (System.nanoTime() - started) / (double)rounds / total, total, bags.size() * 5, each[0], hits);
        }
        int rounds = 300;
        for (int warm = 0; warm < 200; warm++) FormulasTest.call(items, "types", player, table("depth", 5.0));
        long started = System.nanoTime();
        for (int round = 0; round < rounds; round++) FormulasTest.call(items, "types", player, table("depth", 5.0));
        System.out.printf("items.types: %6.1f ns an item over %d items%n", (System.nanoTime() - started) / (double)rounds / total, total);
    }

    private static List<Object> find(KahluaTable items, Object source, Object match, Object options) {
        return FormulasTest.call(items, "find", source, match, options);
    }

    private static List<Object> got(Object list) {
        var result = new ArrayList<Object>();
        for (int index = 1; ; index++) {
            Object value = ((KahluaTable)list).rawget(index);
            if (value == null) return result;
            result.add(System.identityHashCode(value));
        }
    }

    private static List<Object> ids(Object... values) {
        var result = new ArrayList<Object>();
        for (Object value : values) result.add(System.identityHashCode(value));
        return result;
    }

    private static List<String> strings(KahluaTable list) {
        var result = new ArrayList<String>();
        for (int index = 1; list.rawget(index) != null; index++) result.add((String)list.rawget(index));
        return result;
    }

    private static InventoryItem item(String type) {
        var item = new InventoryItem("Tool", 0.1f);
        item.fullType = type;
        return item;
    }

    private static KahluaTable table(Object... pairs) {
        KahluaTable result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static KahluaTable list(Object... values) {
        KahluaTable result = LuaManager.platform.newTable();
        for (int index = 0; index < values.length; index++) result.rawset((double)(index + 1), values[index]);
        return result;
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
