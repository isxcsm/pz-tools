package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;

/**
 * The game's inventory as the formulas of the load reach it: what an item weighs on the character's body, what a
 * container may hold, how heavily a character is loaded. The classes, methods and fields are resolved once by
 * reflection (the API is built without the game) into method handles of exact types, so that a question the hooks ask
 * many times a frame boxes nothing and allocates nothing. What the questions read is the snapshot of the declarations
 * ({@link Formulas.Active}), passed in.
 */
final class Inventory {
    private final Class<?> itemType, bagType, characterType, deadBodyType;
    // InventoryItem, as (Object)...
    private final MethodHandle displayCategory, unequippedWeight, actualWeight, equipParent, itemHasModData, itemModData;
    // InventoryItem.isItemType(ItemType) and hasTag(ItemTag) as (Object, Object)boolean.
    private final MethodHandle isItemType, hasTag;
    // InventoryContainer: its container, and the part of its weight a worn bag takes away.
    private final MethodHandle bagContainer, bagReduction;
    // ItemContainer: its items, and the owners it can have.
    private final MethodHandle items, parent, containingItem, vehiclePart;
    // ItemContainer: the raw capacity, its type name, whether it is an occupied vehicle seat, its effective capacity.
    private final MethodHandle rawCapacity, containerKind, occupiedSeat, capacityFor, capacity, maxWeight;
    // IsoObject and VehiclePart: their modData.
    private final MethodHandle objectHasModData, objectModData, partHasModData, partModData;
    // KahluaTable.rawget(Object)
    private final MethodHandle rawget;
    // ZomboidGlobals.equippedOrWornEncumbranceMultiplier
    private final MethodHandle equippedMultiplier;
    // ItemType.get(location), ItemTag.get(location), ResourceLocation.of(id): how the game finds a registered name.
    private final Method itemTypeGet, itemTagGet, locationOf;

    Inventory(ClassLoader loader) throws ReflectiveOperationException, IllegalAccessException {
        itemType = Game.type(loader, "zombie.inventory.InventoryItem");
        bagType = Game.type(loader, "zombie.inventory.types.InventoryContainer");
        Class<?> container = Game.type(loader, "zombie.inventory.ItemContainer");
        characterType = Game.type(loader, "zombie.characters.IsoGameCharacter");
        deadBodyType = Game.type(loader, "zombie.iso.objects.IsoDeadBody");
        Class<?> object = Game.type(loader, "zombie.iso.IsoObject"), part = Game.type(loader, "zombie.vehicles.VehiclePart");
        Class<?> typeClass = Game.type(loader, "zombie.scripting.objects.ItemType"), tagClass = Game.type(loader, "zombie.scripting.objects.ItemTag");
        Class<?> location = Game.type(loader, "zombie.scripting.objects.ResourceLocation");
        MethodType onItem = MethodType.methodType(float.class, Object.class);
        displayCategory = Game.exact(itemType.getMethod("getDisplayCategory"), MethodType.methodType(String.class, Object.class));
        unequippedWeight = Game.exact(itemType.getMethod("getUnequippedWeight"), onItem);
        actualWeight = Game.exact(itemType.getMethod("getActualWeight"), onItem);
        equipParent = Game.exact(itemType.getMethod("getEquipParent"), MethodType.methodType(Object.class, Object.class));
        itemHasModData = Game.exact(itemType.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        itemModData = Game.exact(itemType.getMethod("getModData"), MethodType.methodType(Object.class, Object.class));
        isItemType = Game.exact(itemType.getMethod("isItemType", typeClass), MethodType.methodType(boolean.class, Object.class, Object.class));
        hasTag = Game.exact(itemType.getMethod("hasTag", tagClass), MethodType.methodType(boolean.class, Object.class, Object.class));
        bagContainer = Game.exact(bagType.getMethod("getInventory"), MethodType.methodType(Object.class, Object.class));
        bagReduction = Game.exact(bagType.getMethod("getWeightReduction"), MethodType.methodType(int.class, Object.class));
        items = Game.exact(container.getMethod("getItems"), MethodType.methodType(ArrayList.class, Object.class));
        parent = getter(container.getField("parent"));
        containingItem = getter(container.getField("containingItem"));
        vehiclePart = getter(container.getField("vehiclePart"));
        rawCapacity = MethodHandles.publicLookup().unreflectGetter(container.getField("capacity")).asType(MethodType.methodType(int.class, Object.class));
        containerKind = getter(container.getField("type")).asType(MethodType.methodType(String.class, Object.class));
        occupiedSeat = Game.exact(container.getMethod("isOccupiedVehicleSeat"), MethodType.methodType(boolean.class, Object.class));
        capacityFor = Game.exact(container.getMethod("getEffectiveCapacity", characterType),
            MethodType.methodType(int.class, Object.class, Object.class));
        capacity = Game.exact(container.getMethod("getCapacity"), MethodType.methodType(int.class, Object.class));
        maxWeight = Game.exact(container.getMethod("getMaxWeight"), onItem);
        objectHasModData = Game.exact(object.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        objectModData = Game.exact(object.getMethod("getModData"), MethodType.methodType(Object.class, Object.class));
        partHasModData = Game.exact(part.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        partModData = Game.exact(part.getMethod("getModData"), MethodType.methodType(Object.class, Object.class));
        Class<?> table = Game.type(loader, "se.krka.kahlua.vm.KahluaTable");
        rawget = Game.exact(table.getMethod("rawget", Object.class), MethodType.methodType(Object.class, Object.class, Object.class));
        Field multiplier = Game.type(loader, "zombie.ZomboidGlobals").getField("equippedOrWornEncumbranceMultiplier");
        equippedMultiplier = MethodHandles.publicLookup().unreflectGetter(multiplier);
        itemTypeGet = typeClass.getMethod("get", location);
        itemTagGet = tagClass.getMethod("get", location);
        locationOf = location.getMethod("of", String.class);
    }

    private static MethodHandle getter(Field field) throws IllegalAccessException {
        return MethodHandles.publicLookup().unreflectGetter(field).asType(MethodType.methodType(Object.class, Object.class));
    }

    // ---- names the game registers ----

    /** The game's item type of this name ({@code base:moveable}), or null. */
    Object itemTypeNamed(String name) { return registered(itemTypeGet, name); }

    /** The game's item tag of this name ({@code base:keyring}), or null. */
    Object itemTagNamed(String name) { return registered(itemTagGet, name); }

    private Object registered(Method lookup, String name) {
        try { return lookup.invoke(null, locationOf.invoke(null, name)); }
        catch (ReflectiveOperationException | RuntimeException unknown) { return null; }
    }

    boolean isItem(Object value) { return itemType.isInstance(value); }

    // ---- what an item weighs on the body ----

    /** The item's efficiencies added up: what its category and its type declare. */
    private double efficiency(Formulas.Active now, Object item) throws Throwable {
        double sum = 0;
        if (!now.category.isEmpty()) {
            String category = (String)displayCategory.invokeExact(item);
            Float declared = category == null ? null : now.category.get(category);
            if (declared != null) sum += declared;
        }
        for (int index = 0; index < now.typeObjects.length; index++)
            if ((boolean)isItemType.invokeExact(item, now.typeObjects[index])) sum += now.typeEfficiency[index];
        return sum;
    }

    /** What the item's own weight is multiplied by: 1 over 1 plus its efficiencies (1 for none). */
    float factor(Formulas.Active now, Object item) throws Throwable {
        double sum = efficiency(now, item);
        return sum == 0 ? 1f : (float)(1 / (1 + Math.max(sum, -0.9)));
    }

    /** What a bag's contents are multiplied by: the product of the declarations of the tags it has. */
    private float tagFactor(Formulas.Active now, Object bag) throws Throwable {
        float result = 1f;
        for (int index = 0; index < now.tagObjects.length; index++)
            if ((boolean)hasTag.invokeExact(bag, now.tagObjects[index])) result *= now.tagMultiplier[index];
        return result;
    }

    /** What a bag weighed the last time it was worked out, and what that was worked out from. */
    private record Memo(Object bag, Object declarations, int plainBits, int contents, float whole) { }

    private static final int MEMOS = 128;
    // A direct-mapped table by the bag's identity: a bag that collides with another is worked out again, nothing is evicted by size.
    private final Memo[] memos = new Memo[MEMOS];
    /** How many bags were worked out from their items (not found in the table), for the tests. */
    long walks;

    /**
     * What stands for the items of a bag, its nested bags' included: their identities and their number. A bag whose items are
     * added to, taken out, moved or swapped has another one (to the chance of a hash collision, 1 in 2^32), whichever way the
     * game or a mod did it, so it needs no signal from the game; a weight that changed in place shows in the game's own total.
     */
    private int contents(ArrayList<?> inside) throws Throwable {
        int print = inside.size();
        for (int index = 0; index < inside.size(); index++) {
            Object item = inside.get(index);
            print = print * 31 + System.identityHashCode(item);
            if (bagType.isInstance(item)) print = print * 31 + contents((ArrayList<?>)items.invokeExact(bagContainer.invokeExact(item)));
        }
        return print;
    }

    /**
     * A bag's weight with nothing equipped: its own times its factor, and its items' (unequipped) times its tags'. It is kept
     * for as long as the game's own weight of the bag ({@code plain}), the bag's items and the declarations are as they were, so
     * a bag nobody touched costs a pass over its items' identities, not a factor for each.
     */
    private float bagWeight(Formulas.Active now, Object bag, float plain) throws Throwable {
        ArrayList<?> inside = (ArrayList<?>)items.invokeExact(bagContainer.invokeExact(bag));
        int print = contents(inside), bits = Float.floatToRawIntBits(plain);
        int slot = (System.identityHashCode(bag) * 0x9E3779B1) >>> 25;
        Memo kept = memos[slot];
        if (kept != null && kept.bag == bag && kept.declarations == now && kept.plainBits == bits && kept.contents == print) return kept.whole;
        walks++;
        float result = (float)actualWeight.invokeExact(bag) * factor(now, bag);
        float contents = 0;
        for (int index = 0; index < inside.size(); index++) contents += unequipped(now, inside.get(index));
        float whole = result + contents * tagFactor(now, bag);
        memos[slot] = new Memo(bag, now, bits, print, whole);
        return whole;
    }

    /** An item's weight with nothing equipped, as the load counts it. */
    float unequipped(Formulas.Active now, Object item) throws Throwable {
        if (bagType.isInstance(item)) return bagWeight(now, item, (float)unequippedWeight.invokeExact(item));
        return (float)unequippedWeight.invokeExact(item) * factor(now, item);
    }

    /** The weight the load counts for an item of the character's inventory ({@code kind} is how the game counts it, {@code vanilla} its answer). */
    float carried(Formulas.Active now, Object item, float vanilla, int kind) throws Throwable {
        if (!bagType.isInstance(item)) {
            float factor = factor(now, item);
            return factor == 1f ? vanilla : vanilla * factor;
        }
        float plain = (float)unequippedWeight.invokeExact(item), whole = bagWeight(now, item, plain);
        if (whole == plain) return vanilla;
        switch (kind) {
            case 0: return whole;
            // The game takes the weight reduction of a worn bag off its items, not off the bag itself.
            case 1: {
                float own = (float)actualWeight.invokeExact(item) * factor(now, item);
                int reduction = (int)bagReduction.invokeExact(item);
                float kept = reduction > 0 ? 1 - reduction / 100f : 1f;
                return own * (float)(double)equippedMultiplier.invokeExact() + (whole - own) * kept;
            }
            // The game counts an item on the hotbar a fixed part of its whole weight.
            default: return plain == 0f ? vanilla : whole * (vanilla / plain);
        }
    }

    /**
     * The weight an item adds when the game asks whether it fits in a container, for the character whose body it
     * would be on; {@code vanilla} is the game's, the item's weight with nothing equipped.
     */
    float incoming(Formulas.Active now, Object item, float vanilla, Object container, boolean viaBag, Players players) throws Throwable {
        Object character = viaBag ? wornBy(container) : characterOf(container);
        if (character == null || !players.local(character)) return vanilla;
        if (!bagType.isInstance(item)) {
            float factor = factor(now, item);
            return factor == 1f ? vanilla : vanilla * factor;
        }
        float whole = bagWeight(now, item, vanilla);
        return whole == vanilla ? vanilla : whole;
    }

    /** The character whose inventory the container is, or null. */
    Object characterOf(Object container) throws Throwable {
        Object owner = (Object)parent.invokeExact(container);
        return characterType.isInstance(owner) ? owner : null;
    }

    /** The character wearing the bag the container belongs to, or null. */
    private Object wornBy(Object container) throws Throwable {
        Object bag = (Object)containingItem.invokeExact(container);
        return bag == null ? null : (Object)equipParent.invokeExact(bag);
    }

    // ---- what a container may hold ----

    /**
     * A container's effective capacity with the formulas of the load: the character's own inventory takes the
     * additional limit of {@code capacity.characterLimitAdd}; the containers the game's own trait multiplier reaches
     * (not a character's, not a corpse's, not the floor) take {@code capacity.effectiveMultiplier}, except a bag, which a
     * bag's own kit sizes.
     */
    int effectiveCapacity(Formulas.Active now, int vanilla, Object container, Object asker, Players players) throws Throwable {
        Object owner = (Object)parent.invokeExact(container);
        if (characterType.isInstance(owner)) {
            return now.characterLimitAdd == 0 || !players.local(owner) ? vanilla : vanilla + now.characterLimitAdd;
        }
        if (now.effectiveMultiplier == 1 || asker == null || !players.local(asker) || deadBodyType.isInstance(owner)
                || "floor".equals((String)containerKind.invokeExact(container)) || (Object)containingItem.invokeExact(container) != null)
            return vanilla;
        return (int)Math.floor(vanilla * now.effectiveMultiplier + 1e-6);
    }

    /**
     * The capacity of a container that declares a key in the modData of what holds it (the object it stands in, the item
     * it is in, the vehicle part it is in): its raw capacity plus the keys' numbers, with none of the game's limits.
     * Any other container keeps the game's answer. -1 for a container that declares none.
     */
    int lifted(String[] keys, Object container) throws Throwable {
        double add = 0;
        boolean declared = false;
        Object owner = (Object)parent.invokeExact(container);
        if (owner != null && (boolean)objectHasModData.invokeExact(owner)) {
            Object table = (Object)objectModData.invokeExact(owner);
            for (String key : keys) if ((Object)rawget.invokeExact(table, (Object)key) instanceof Number value) { declared = true; add += value.doubleValue(); }
        }
        Object item = (Object)containingItem.invokeExact(container);
        if (item != null && (boolean)itemHasModData.invokeExact(item)) {
            Object table = (Object)itemModData.invokeExact(item);
            for (String key : keys) if ((Object)rawget.invokeExact(table, (Object)key) instanceof Number value) { declared = true; add += value.doubleValue(); }
        }
        Object part = (Object)vehiclePart.invokeExact(container);
        if (part != null && (boolean)partHasModData.invokeExact(part)) {
            Object table = (Object)partModData.invokeExact(part);
            for (String key : keys) if ((Object)rawget.invokeExact(table, (Object)key) instanceof Number value) { declared = true; add += value.doubleValue(); }
        }
        if (!declared) return -1;
        int raw = (int)rawCapacity.invokeExact(container);
        // As the game does for a seat someone sits in.
        if ((boolean)occupiedSeat.invokeExact(container)) raw /= 4;
        return (int)Math.max(0, Math.min(Integer.MAX_VALUE / 2, raw + Math.round(add)));
    }

    /** Whether the bag item declares one of the keys in its modData. */
    private boolean declares(String[] keys, Object item) throws Throwable {
        if (!(boolean)itemHasModData.invokeExact(item)) return false;
        Object table = (Object)itemModData.invokeExact(item);
        for (String key : keys) if ((Object)rawget.invokeExact(table, (Object)key) instanceof Number) return true;
        return false;
    }

    /** A bag that declares a key has the capacity of its container, which the game clamps to what a bag can be; -1 otherwise. */
    int bagCapacity(String[] keys, Object bag) throws Throwable {
        return declares(keys, bag) ? (int)capacity.invokeExact((Object)bagContainer.invokeExact(bag)) : -1;
    }

    int bagEffectiveCapacity(String[] keys, Object bag, Object asker) throws Throwable {
        return declares(keys, bag) ? (int)capacityFor.invokeExact((Object)bagContainer.invokeExact(bag), asker) : -1;
    }

    // ---- how heavily a character is loaded ----

    /**
     * What a character's load is when its excess over the most it can carry counts for the part the formula leaves:
     * {@code max + (load - max)(1 - compress)}. Only the character's own inventory; a load within its maximum is as it is.
     */
    float compressed(Formulas.Active now, Object container, float load, Players players) throws Throwable {
        Object character = characterOf(container);
        if (character == null || !players.local(character)) return load;
        float max = (float)maxWeight.invokeExact(container);
        return load <= max ? load : max + (load - max) * (1 - now.compress);
    }
}
