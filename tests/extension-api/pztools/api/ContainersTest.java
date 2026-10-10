package pztools.api;

import java.util.ArrayList;
import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.iso.IsoCell;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.objects.IsoThumpable;
import zombie.iso.sprite.IsoSprite;

/**
 * {@code buildings.containers} and {@code containersNear}, against the synthetic game's house (a kitchen, a basement and a bedroom that
 * is not loaded) and shack: the flat list, the filters, the stamp that tells what changed, and what a walk costs.
 */
final class ContainersTest {
    private static final String HOUSE = "11,11,-1", SHACK = "20,20,0";
    private final List<IsoObject> placed = new ArrayList<>();

    private ContainersTest() { }

    static void run(KahluaTable buildings) {
        var test = new ContainersTest();
        try { test.all(buildings); }
        finally { test.remove(); }
    }

    private IsoCell cell() { return IsoWorld.instance.currentCell; }

    /** An object on a square holding containers of the types, each with items. */
    private <T extends IsoObject> T put(T object, int x, int y, int z, Object... containers) {
        object.square = cell().getGridSquare(x, y, z);
        object.square.objects.add(object);
        for (int index = 0; index < containers.length; index += 2) {
            var container = new ItemContainer(object);
            container.type = (String)containers[index];
            for (int item = 0; item < (Integer)containers[index + 1]; item++) container.items.add(new InventoryItem("Item", 1f));
            object.containers.add(container);
        }
        placed.add(object);
        return object;
    }

    private void remove() { for (IsoObject object : placed) object.square.objects.remove(object); placed.clear(); }

    private void all(KahluaTable buildings) {
        IsoObject shelf = put(new IsoObject(new IsoSprite("shelf")), 10, 10, 0, "shelves", 3);
        IsoObject counter = put(new IsoObject(new IsoSprite("counter")), 12, 10, 0, "counter", 0, "drawer", 2);
        IsoObject fridge = put(new IsoObject(new IsoSprite("cold")), 13, 11, 0, "fridge", 0);
        fridge.containers.get(0).explored = true;
        IsoObject built = put(new IsoThumpable(new IsoSprite("crate")), 10, 12, 0, "crate", 1);
        IsoObject marked = put(new IsoObject(new IsoSprite("crate")), 11, 12, 0, "crate", 1);
        ((KahluaTable)marked.getModData()).rawset("MyModKind", "box");
        IsoObject basement = put(new IsoObject(new IsoSprite("crate")), 11, 11, -1, "crate", 1);
        IsoObject street = put(new IsoObject(new IsoSprite("crate")), 16, 12, 0, "crate", 4);
        IsoObject hut = put(new IsoObject(new IsoSprite("crate")), 20, 21, 0, "crate", 2);

        // The whole house: every container of its loaded squares, 7 values each, with the counts of what matches.
        var house = call(buildings, "containers", HOUSE);
        var list = (KahluaTable)house.get(0);
        check(list != null && list.len() == 7 * 7, "The house's list has " + (list == null ? -1 : list.len()) + " values, not 49 (7 containers)");
        check(house.get(1) == Boolean.FALSE, "The bedroom is not loaded, but the list says it is complete");
        check((Double)house.get(3) == 7.0 && (Double)house.get(4) == 1.0, "The house has 7 containers and 1 opened, not " + house.get(3) + " and " + house.get(4));
        var stamp = (Double)house.get(2);
        check(stamp != null && stamp >= 1, "No stamp was given");
        // Squares are walked room by room, row by row, each container once with the square it stands on.
        int shelved = find(list, shelf.containers.get(0));
        check(at(list, shelved, shelf.containers.get(0), 10, 10, 0, "shelves", 3, false), "The shelf is wrong: " + row(list, shelved));
        check(find(list, counter.containers.get(0)) >= 0 && find(list, counter.containers.get(1)) >= 0, "The counter's two containers are not both listed");
        int opened = find(list, fridge.containers.get(0));
        check(at(list, opened, fridge.containers.get(0), 13, 11, 0, "fridge", 0, true), "The fridge is wrong: " + row(list, opened));
        check(at(list, find(list, basement.containers.get(0)), basement.containers.get(0), 11, 11, -1, "crate", 1, false), "The basement's crate is wrong");
        check(find(list, street.containers.get(0)) < 0 && find(list, hut.containers.get(0)) < 0, "A container of another building was in the house's");

        // A building whose squares are all loaded is complete.
        var shack = call(buildings, "containers", SHACK);
        check(shack.get(1) == Boolean.TRUE && ((KahluaTable)shack.get(0)).len() == 7 && (Double)shack.get(3) == 1.0, "The shack should be complete with one container");
        var nowhere = call(buildings, "containers", "1,1,0");
        check(nowhere.get(0) == null && nowhere.get(1) == Boolean.FALSE, "A key that names no building gave something");

        // The filters.
        var shelves = (KahluaTable)call(buildings, "containers", HOUSE, options("type", "shelves")).get(0);
        check(shelves.len() == 7 && shelves.rawget(1.0) == shelf.containers.get(0), "The type filter kept more than the shelf");
        var two = (KahluaTable)call(buildings, "containers", HOUSE, options("type", list("shelves", "drawer"))).get(0);
        check(two.len() == 14, "Two types should keep two containers, not " + two.len() / 7);
        var plain = call(buildings, "containers", HOUSE, options("skipClasses", list("IsoThumpable"), "skipData", "MyModKind"));
        check(((KahluaTable)plain.get(0)).len() == 5 * 7 && (Double)plain.get(3) == 5.0, "A player-built container and a marked one should have gone");
        check(find((KahluaTable)plain.get(0), built.containers.get(0)) < 0 && find((KahluaTable)plain.get(0), marked.containers.get(0)) < 0, "A skipped container was listed");
        // An unknown class, and arguments that are not names.
        error(buildings, "containers", "options.skipClasses \"Nothing\" is not one of the game's object classes", HOUSE, options("skipClasses", "Nothing"));
        error(buildings, "containers", "options.skipClasses \"../x\" is not a class name", HOUSE, options("skipClasses", "../x"));
        error(buildings, "containers", "options.type must be a name or a list of names", HOUSE, options("type", 1.0));
        error(buildings, "containers", "options.type must name at least one", HOUSE, options("type", list()));
        error(buildings, "containers", "options.since must be a stamp this call returned", HOUSE, options("since", 0.5));
        error(buildings, "containers", "options must be a table", HOUSE, 1.0);
        error(buildings, "containers", "key must be a string", 5.0);

        // Since a stamp: nothing changed, nothing listed; then what changed, and what is new.
        var same = call(buildings, "containers", HOUSE, options("since", stamp));
        check(((KahluaTable)same.get(0)).len() == 0 && (Double)same.get(3) == 7.0, "Nothing changed, yet a container was listed");
        var next = (Double)same.get(2);
        check(next > stamp, "The stamp did not advance");
        shelf.containers.get(0).items.add(new InventoryItem("Item", 1f));
        counter.containers.get(1).explored = true;
        var changed = call(buildings, "containers", HOUSE, options("since", next));
        var changes = (KahluaTable)changed.get(0);
        check(changes.len() == 14, "Two containers changed, " + changes.len() / 7 + " were listed");
        check(find(changes, shelf.containers.get(0)) >= 0 && find(changes, counter.containers.get(1)) >= 0, "The wrong containers were listed as changed");
        check(at(changes, find(changes, shelf.containers.get(0)), shelf.containers.get(0), 10, 10, 0, "shelves", 4, false), "A changed container did not say its count");
        check((Double)changed.get(4) == 2.0, "The opened count is not 2: " + changed.get(4));
        // A container that was not seen before is listed.
        IsoObject fresh = put(new IsoObject(new IsoSprite("shelf")), 11, 10, 0, "shelves", 0);
        var added = (KahluaTable)call(buildings, "containers", HOUSE, options("since", (Double)changed.get(2))).get(0);
        check(added.len() == 7 && added.rawget(1.0) == fresh.containers.get(0), "A new container was not listed");
        // A stamp of another question, an unknown one, or a world left: everything.
        check(((KahluaTable)call(buildings, "containers", HOUSE, options("since", (Double)changed.get(2), "type", "shelves")).get(0)).len() == 14,
            "A stamp of another question was used");
        check(((KahluaTable)call(buildings, "containers", HOUSE, options("since", 99999.0)).get(0)).len() == 8 * 7, "An unknown stamp was used");
        check(((KahluaTable)call(buildings, "containers", SHACK, options("since", stamp)).get(0)).len() == 7, "A stamp of another building was used");

        // A table passed as into is the list, its numbers replaced and the rest taken away.
        var into = new KahluaTableImpl();
        var first = call(buildings, "containers", HOUSE, options("into", into));
        check(first.get(0) == into && into.len() == 8 * 7, "The list was not the table passed");
        var again = call(buildings, "containers", HOUSE, options("into", into, "type", "shelves"));
        check(again.get(0) == into && into.len() == 14 && into.rawget(15.0) == null, "The table was not trimmed: " + into.len());

        // Around a point: a box, on a level, whatever building the squares belong to (or none).
        var around = call(buildings, "containersNear", 14.0, 11.0, 0.0, 3.0);
        var nearList = (KahluaTable)around.get(0);
        check(find(nearList, street.containers.get(0)) >= 0 && find(nearList, fridge.containers.get(0)) >= 0 && find(nearList, shelf.containers.get(0)) < 0,
            "The box around (14, 11) is wrong: " + nearList.len() / 7 + " containers");
        check(around.get(1) == Boolean.TRUE, "A box of loaded squares should be complete");
        var onLevel = (KahluaTable)call(buildings, "containersNear", 11.0, 11.0, -1.0, 2.0).get(0);
        check(onLevel.len() == 7 && onLevel.rawget(1.0) == basement.containers.get(0), "Another level gave the wrong containers");
        var edge = call(buildings, "containersNear", 4.0, 4.0, 0.0, 3.0);
        check(edge.get(1) == Boolean.FALSE, "A box that reaches squares not loaded should not be complete");
        var typed = (KahluaTable)call(buildings, "containersNear", 14.0, 11.0, 0.0, 8.0, options("type", "crate", "skipClasses", "IsoThumpable")).get(0);
        check(typed.len() == 2 * 7 && find(typed, marked.containers.get(0)) >= 0 && find(typed, street.containers.get(0)) >= 0,
            "The crates around (14, 11) are 2, not " + typed.len() / 7);
        error(buildings, "containersNear", "radius must be a whole number from 0 to 32", 0.0, 0.0, 0.0, 33.0);
        error(buildings, "containersNear", "z must be a whole number", 0.0, 0.0, 0.5, 3.0);

        // What a walk costs: the squares of a house, every container asked its type, count and whether it was opened.
        for (int round = 0; round < 300; round++) call(buildings, "containers", HOUSE, options("into", into));
        long bytes = allocated();
        long start = System.nanoTime();
        for (int round = 0; round < 1000; round++) call(buildings, "containers", HOUSE, options("into", into));
        long time = System.nanoTime() - start;
        bytes = allocated() - bytes;
        System.out.printf("buildings.containers over a house of 8 containers on 24 squares: %.1f us, %d bytes a call%n", time / 1000 / 1e3, bytes / 1000);
        check(time / 1000 < 2_000_000L, "buildings.containers is slow: " + time / 1000 + " ns");
    }

    // ---- reading the list ----

    private static boolean at(KahluaTable list, int index, Object container, double x, double y, double z, String type, double count, boolean opened) {
        if (index < 0) return false;
        int base = index * 7;
        return list.rawget((double)(base + 1)) == container && list.rawget((double)(base + 2)).equals(x) && list.rawget((double)(base + 3)).equals(y)
            && list.rawget((double)(base + 4)).equals(z) && type.equals(list.rawget((double)(base + 5))) && list.rawget((double)(base + 6)).equals(count)
            && list.rawget((double)(base + 7)).equals(opened);
    }

    private static String row(KahluaTable list, int index) {
        var text = new StringBuilder();
        for (int value = 1; value <= 7; value++) text.append(list.rawget((double)(index * 7 + value))).append(' ');
        return text.toString();
    }

    /** The index (from 0) of the container in the list, or -1. */
    private static int find(KahluaTable list, Object container) {
        for (int index = 0; index * 7 < list.len(); index++) if (list.rawget((double)(index * 7 + 1)) == container) return index;
        return -1;
    }

    private static KahluaTable options(Object... pairs) {
        var table = new KahluaTableImpl();
        for (int index = 0; index < pairs.length; index += 2) table.rawset(pairs[index], pairs[index + 1]);
        return table;
    }

    private static KahluaTable list(Object... values) {
        var table = new KahluaTableImpl();
        for (int index = 0; index < values.length; index++) table.rawset((double)(index + 1), values[index]);
        return table;
    }

    private static List<Object> call(KahluaTable table, String name, Object... arguments) { return FormulasTest.call(table, name, arguments); }

    private static void error(KahluaTable table, String name, String message, Object... arguments) {
        try { call(table, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZToolsAPI.buildings." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
