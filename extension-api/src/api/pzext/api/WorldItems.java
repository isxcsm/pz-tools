package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.List;
import pzext.boot.Hooks;

/**
 * What the game takes of the items in the world by itself (docs/design.md, "World items"), for a mod whose
 * items must not be lost without it knowing.
 *
 * <p>A fire: {@code IsoGridSquare.BurnWalls} empties every container of a burnt object and takes the containers away. Before
 * each is emptied, the Lua event {@link #EVENT}{@code (container, object)} is raised on the game's thread, the items still in it.
 *
 * <p>The sandbox's world item removal ({@code HoursForWorldItemRemoval} with {@code WorldItemRemovalList}) leaves a floor item
 * out of its square as the square loads, unless the item's own flag ({@code isIgnoreRemoveSandbox}, set by the game's placing
 * of an item, not by a drop) keeps it. An item whose mod data has {@link #KEEP} (any value), or a bag that holds one at any
 * depth, is kept as well. The question comes on the thread that loads the chunk, only for an item the removal would take, and
 * reads nothing but the item and what it holds, which nothing else reaches yet.
 */
final class WorldItems implements Hooks.WorldItems {
    static final String EVENT = "OnPZExtContainerBurning";
    static final String KEEP = "PZExtKeep";
    // Bags in bags, as deep as a floor item is looked into.
    private static final int DEPTH = 8;

    private final Game game;
    private final Class<?> bag;
    // IsoWorldInventoryObject.getItem(); InventoryItem.hasModData(), getModData(); KahluaTable.rawget(key);
    // InventoryContainer.getInventory(); ItemContainer.getItems(), getParent().
    private final MethodHandle item, hasData, data, rawget, inventory, items, parent;

    WorldItems(Game game, ClassLoader loader) throws ReflectiveOperationException {
        this.game = game;
        Class<?> floor = Game.type(loader, "zombie.iso.objects.IsoWorldInventoryObject");
        Class<?> inventoryItem = Game.type(loader, "zombie.inventory.InventoryItem");
        Class<?> container = Game.type(loader, "zombie.inventory.ItemContainer");
        bag = Game.type(loader, "zombie.inventory.types.InventoryContainer");
        MethodType objectOf = MethodType.methodType(Object.class, Object.class);
        item = Game.exact(floor.getMethod("getItem"), objectOf);
        hasData = Game.exact(inventoryItem.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        data = Game.exact(inventoryItem.getMethod("getModData"), objectOf);
        rawget = Game.exact(Game.type(loader, "se.krka.kahlua.vm.KahluaTable").getMethod("rawget", Object.class),
            MethodType.methodType(Object.class, Object.class, Object.class));
        inventory = Game.exact(bag.getMethod("getInventory"), objectOf);
        items = Game.exact(container.getMethod("getItems"), MethodType.methodType(List.class, Object.class));
        parent = Game.exact(container.getMethod("getParent"), objectOf);
    }

    /** Makes the event known to the game and takes the hooks. Throws a LinkageError with a bootstrap from before them. */
    void hook() throws ReflectiveOperationException {
        game.addEvent(EVENT);
        Hooks.setWorldItems(this);
    }

    /** The hooks leave the game's answers. */
    static void unhook() {
        try { Hooks.setWorldItems(null); } catch (LinkageError olderBootstrap) { }
    }

    @Override public void burning(Object container) throws Throwable {
        if (container == null) return;
        game.raise(EVENT, container, (Object)parent.invokeExact(container));
    }

    @Override public boolean kept(boolean vanilla, Object worldItem) throws Throwable {
        if (vanilla || worldItem == null) return vanilla;
        return keeps((Object)item.invokeExact(worldItem), DEPTH);
    }

    /** Whether the item has the mark, or holds one that has it. */
    private boolean keeps(Object thing, int depth) throws Throwable {
        if (thing == null) return false;
        if ((boolean)hasData.invokeExact(thing) && (Object)rawget.invokeExact((Object)data.invokeExact(thing), (Object)KEEP) != null) return true;
        if (depth == 0 || !bag.isInstance(thing)) return false;
        Object held = (Object)inventory.invokeExact(thing);
        if (held == null) return false;
        List<?> list = (List<?>)items.invokeExact(held);
        for (int index = 0, size = list.size(); index < size; index++)
            if (keeps(list.get(index), depth - 1)) return true;
        return false;
    }
}
