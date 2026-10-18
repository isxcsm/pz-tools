package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.lang.reflect.Method;
import java.util.List;

/**
 * What the item queries ({@link ItemMatch}, {@link Items}) call of the game, as handles that are constants of the compiled code
 * (called exactly: nothing boxed, no argument array), made once from the classes of the game's loader. The one game a process
 * has: like {@link Kahlua}, it refuses a second loader.
 */
final class ItemCalls {
    // The loader the handles are made from: set before Calls is first used.
    private static ClassLoader seed;
    private static volatile boolean ready;

    private ItemCalls() { }

    static final class Calls {
        static final Class<?> ITEM, BAG, CONTAINER, OBJECT, CHARACTER, TAG;
        // InventoryItem: getFullType, hasTag(ItemTag), isBroken, isFavorite, hasModData, getModData.
        static final MethodHandle FULL_TYPE, HAS_TAG, BROKEN, FAVORITE, HAS_DATA, DATA;
        // KahluaTable.rawget(Object), rawset(int, Object).
        static final MethodHandle RAWGET, RAWSET_AT;
        // IsoGameCharacter: isEquipped(item) (worn or in a hand), isAttachedItem(item) (on the hotbar), getInventory().
        static final MethodHandle EQUIPPED, ATTACHED, INVENTORY;
        // ItemContainer.getItems(); InventoryContainer.getInventory(); IsoObject.getContainerCount(), getContainerByIndex(int).
        static final MethodHandle ITEMS, BAG_INVENTORY, CONTAINER_COUNT, CONTAINER_AT;
        // ItemTag.get(ResourceLocation) and ResourceLocation.of(String): how the game finds a registered tag.
        static final Method TAG_GET, LOCATION_OF;

        static {
            try {
                ClassLoader loader = seed;
                ITEM = Game.type(loader, "zombie.inventory.InventoryItem");
                BAG = Game.type(loader, "zombie.inventory.types.InventoryContainer");
                CONTAINER = Game.type(loader, "zombie.inventory.ItemContainer");
                OBJECT = Game.type(loader, "zombie.iso.IsoObject");
                CHARACTER = Game.type(loader, "zombie.characters.IsoGameCharacter");
                TAG = Game.type(loader, "zombie.scripting.objects.ItemTag");
                Class<?> location = Game.type(loader, "zombie.scripting.objects.ResourceLocation");
                Class<?> table = Game.type(loader, "se.krka.kahlua.vm.KahluaTable");
                MethodType onObject = MethodType.methodType(Object.class, Object.class);
                MethodType test = MethodType.methodType(boolean.class, Object.class);
                MethodType testWith = MethodType.methodType(boolean.class, Object.class, Object.class);
                FULL_TYPE = Game.exact(ITEM.getMethod("getFullType"), MethodType.methodType(String.class, Object.class));
                HAS_TAG = Game.exact(ITEM.getMethod("hasTag", TAG), testWith);
                BROKEN = Game.exact(ITEM.getMethod("isBroken"), test);
                FAVORITE = Game.exact(ITEM.getMethod("isFavorite"), test);
                HAS_DATA = Game.exact(ITEM.getMethod("hasModData"), test);
                DATA = Game.exact(ITEM.getMethod("getModData"), onObject);
                RAWGET = Game.exact(table.getMethod("rawget", Object.class), MethodType.methodType(Object.class, Object.class, Object.class));
                RAWSET_AT = Game.exact(table.getMethod("rawset", int.class, Object.class),
                    MethodType.methodType(void.class, Object.class, int.class, Object.class));
                EQUIPPED = Game.exact(CHARACTER.getMethod("isEquipped", ITEM), testWith);
                ATTACHED = Game.exact(CHARACTER.getMethod("isAttachedItem", ITEM), testWith);
                INVENTORY = Game.exact(CHARACTER.getMethod("getInventory"), onObject);
                ITEMS = Game.exact(CONTAINER.getMethod("getItems"), MethodType.methodType(List.class, Object.class));
                BAG_INVENTORY = Game.exact(BAG.getMethod("getInventory"), onObject);
                CONTAINER_COUNT = Game.exact(OBJECT.getMethod("getContainerCount"), MethodType.methodType(int.class, Object.class));
                CONTAINER_AT = Game.exact(OBJECT.getMethod("getContainerByIndex", int.class), MethodType.methodType(Object.class, Object.class, int.class));
                TAG_GET = TAG.getMethod("get", location);
                LOCATION_OF = location.getMethod("of", String.class);
            } catch (ReflectiveOperationException failure) {
                throw new ExceptionInInitializerError(failure);
            }
        }
    }

    /** Makes the handles from this loader's game; throws when they cannot be made, or another game's are in use. */
    static void prepare(ClassLoader loader) throws ReflectiveOperationException {
        if (ready && seed == loader) return;
        synchronized (ItemCalls.class) { if (seed == null) seed = loader; }
        if (seed != loader) throw new ReflectiveOperationException("the item queries cannot be made: another game's classes are already in use");
        try { Calls.ITEM.getName(); }
        catch (ExceptionInInitializerError | NoClassDefFoundError unreadable) {
            throw new ReflectiveOperationException("the item queries cannot be made", unreadable.getCause() != null ? unreadable.getCause() : unreadable);
        }
        ready = true;
    }
}
