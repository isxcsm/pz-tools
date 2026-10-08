package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.ref.WeakReference;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.locks.ReentrantLock;
import pztools.bridge.Tracked;

/**
 * The game's inventory as the formulas of the load reach it: what an item weighs on the character's body, what a
 * container may hold, how heavily a character is loaded. The classes, methods and fields are resolved once by
 * reflection (the API is built without the game) into method handles of exact types, so that a question the hooks ask
 * many times a frame boxes nothing and allocates nothing. What the questions read is the snapshot of the declarations
 * ({@link Formulas.Active}), passed in.
 *
 * <p><b>The weight is kept, not worked out.</b> Each list of items that was asked about has a {@link Kept}: the sum of what
 * its items weigh (as the formulas count them) and, for each item, the weight it was added into the sum with. The game's
 * lists are {@link Tracked} lists (see there), so every item that goes in or comes out is seen, and the sum changes by
 * what the item weighs: nothing is walked. A bag's weight is its own plus what its container's sum is times the bag's tags'
 * multiplier, so a change inside a bag changes the sum of the list the bag is in by the difference, and so on up (a list
 * knows the list its bag is in). What an item weighs changes in place too (food eaten, a bottle drunk from, a magazine
 * loaded); every write of a field its weight reads is signalled by the hooks, noted, and settled at the next question, when
 * the game is not in the middle of its own method. What is worn or held changes what a character's inventory weighs
 * (the weight of the item as equipped, or on the hotbar, instead of unequipped); that is told by the hands, the worn items
 * list's version and the items' own hotbar slot, and settled by working out again only the items it concerns.
 *
 * <p>A question about a list nothing has changed is a few field reads. A list the account cannot follow (an operation on it
 * that does not say which items it touched, a change of the declarations) is worked out again, once, at the next question.
 */
final class Inventory {
    private final Class<?> itemType, bagType, characterType, deadBodyType, fluidType;
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
    // What the kept weights follow. ItemContainer.items as a field (public, not final), the item's container, how the game counts
    // an item of a character's inventory, who is wearing and holding what, and whose item a fluid container is.
    private final MethodHandle itemsGet, itemsSet, containerOf, inventoryOf, attachedSlot, characterEquipped, fakeEquipped,
        equippedWeight, hotbarWeight, leftHand, rightHand, wornOf, wornList, wornItemOf, fluidOwner;
    private final Field wornItemsField;

    Inventory(ClassLoader loader) throws ReflectiveOperationException, IllegalAccessException {
        itemType = Game.type(loader, "zombie.inventory.InventoryItem");
        bagType = Game.type(loader, "zombie.inventory.types.InventoryContainer");
        Class<?> container = Game.type(loader, "zombie.inventory.ItemContainer");
        characterType = Game.type(loader, "zombie.characters.IsoGameCharacter");
        deadBodyType = Game.type(loader, "zombie.iso.objects.IsoDeadBody");
        fluidType = Game.type(loader, "zombie.entity.components.fluids.FluidContainer");
        Class<?> object = Game.type(loader, "zombie.iso.IsoObject"), part = Game.type(loader, "zombie.vehicles.VehiclePart");
        Class<?> typeClass = Game.type(loader, "zombie.scripting.objects.ItemType"), tagClass = Game.type(loader, "zombie.scripting.objects.ItemTag");
        Class<?> location = Game.type(loader, "zombie.scripting.objects.ResourceLocation");
        Class<?> worn = Game.type(loader, "zombie.characters.WornItems.WornItems"), wornItem = Game.type(loader, "zombie.characters.WornItems.WornItem");
        MethodType onItem = MethodType.methodType(float.class, Object.class), onObject = MethodType.methodType(Object.class, Object.class);
        displayCategory = Game.exact(itemType.getMethod("getDisplayCategory"), MethodType.methodType(String.class, Object.class));
        unequippedWeight = Game.exact(itemType.getMethod("getUnequippedWeight"), onItem);
        actualWeight = Game.exact(itemType.getMethod("getActualWeight"), onItem);
        equippedWeight = Game.exact(itemType.getMethod("getEquippedWeight"), onItem);
        hotbarWeight = Game.exact(itemType.getMethod("getHotbarEquippedWeight"), onItem);
        equipParent = Game.exact(itemType.getMethod("getEquipParent"), onObject);
        itemHasModData = Game.exact(itemType.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        itemModData = Game.exact(itemType.getMethod("getModData"), onObject);
        isItemType = Game.exact(itemType.getMethod("isItemType", typeClass), MethodType.methodType(boolean.class, Object.class, Object.class));
        hasTag = Game.exact(itemType.getMethod("hasTag", tagClass), MethodType.methodType(boolean.class, Object.class, Object.class));
        containerOf = Game.exact(itemType.getMethod("getContainer"), onObject);
        attachedSlot = Game.exact(itemType.getMethod("getAttachedSlot"), MethodType.methodType(int.class, Object.class));
        fakeEquipped = Game.exact(itemType.getMethod("isFakeEquipped", characterType), MethodType.methodType(boolean.class, Object.class, Object.class));
        bagContainer = Game.exact(bagType.getMethod("getInventory"), onObject);
        bagReduction = Game.exact(bagType.getMethod("getWeightReduction"), MethodType.methodType(int.class, Object.class));
        items = Game.exact(container.getMethod("getItems"), MethodType.methodType(ArrayList.class, Object.class));
        itemsGet = MethodHandles.publicLookup().unreflectGetter(container.getField("items")).asType(onObject);
        itemsSet = MethodHandles.publicLookup().unreflectSetter(container.getField("items")).asType(MethodType.methodType(void.class, Object.class, Object.class));
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
        inventoryOf = Game.exact(characterType.getMethod("getInventory"), onObject);
        characterEquipped = Game.exact(characterType.getMethod("isEquipped", itemType), MethodType.methodType(boolean.class, Object.class, Object.class));
        leftHand = Game.exact(characterType.getMethod("getPrimaryHandItem"), onObject);
        rightHand = Game.exact(characterType.getMethod("getSecondaryHandItem"), onObject);
        wornOf = Game.exact(characterType.getMethod("getWornItems"), onObject);
        wornList = Game.exact(worn.getMethod("getItems"), onObject);
        wornItemOf = Game.exact(wornItem.getMethod("getItem"), onObject);
        wornItemsField = worn.getDeclaredField("items");
        fluidOwner = Game.exact(Game.type(loader, "zombie.entity.Component").getMethod("getGameEntity"), onObject);
        objectHasModData = Game.exact(object.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        objectModData = Game.exact(object.getMethod("getModData"), onObject);
        partHasModData = Game.exact(part.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        partModData = Game.exact(part.getMethod("getModData"), onObject);
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

    // ---- what is kept ----

    private static final Object[] NO_OBJECTS = {};

    /** How the game counts an item of a character's inventory. */
    private static final int UNEQUIPPED = 0, EQUIPPED = 1, HOTBAR = 2;

    /**
     * Everything kept about one {@link Tracked} list of items: the sum of what its items weigh and, per item (by identity),
     * the weight it was added to the sum with, so that taking it out takes away exactly that. An item in the list twice is
     * in it once with a count. The sum is a double of floats: each weight is a float, and a sum of them changes by exactly
     * what is added or taken away as long as the partial sums fit a double's 53 bits (weights from a thousandth to a thousand
     * and a few thousand items do); a change that would round is noticed and the list is worked out again instead, so the
     * sum is never a rounded one that a fresh pass would not give. All of it is guarded by {@link Inventory#lock}.
     */
    static final class Kept {
        final Inventory owner;
        final Tracked list;
        // What the entries were worked out under: the declarations, and the number the equipped weight is multiplied by.
        Object built;
        int epoch;
        double multiplier;
        // Not worked out yet, or to be worked out again.
        boolean stale = true;
        boolean building, inexact, loose;
        double sum;
        Object[] keys = new Object[8];
        float[] values = new float[8];
        int[] counts = new int[8];
        int distinct;
        // The list the bag this list belongs to is in, and the bag.
        Kept up;
        Object bag;
        // A character's inventory: whose, and what the character wore and held when the entries were worked out. The special
        // items are those that are not counted unequipped (worn, held, on the hotbar, a key ring).
        Object character, left, right, worn, wornList;
        int wornVersion;
        Object[] special = NO_OBJECTS;
        int specials;

        Kept(Inventory owner, Tracked list) {
            this.owner = owner;
            this.list = list;
        }

        private static int mix(Object item) {
            int hash = System.identityHashCode(item) * 0x9E3779B1;
            return hash ^ (hash >>> 15);
        }

        /** The slot of an item, or its complement where it would go. */
        int find(Object item) {
            int mask = keys.length - 1, slot = mix(item) & mask;
            while (true) {
                Object key = keys[slot];
                if (key == null) return ~slot;
                if (key == item) return slot;
                slot = (slot + 1) & mask;
            }
        }

        /** Adds to the sum; a result that is not exact marks the list to be worked out again. */
        void add(double change) {
            double before = sum, after = before + change, part = after - before;
            if ((before - (after - part)) + (change - part) != 0) inexact = true;
            sum = after;
        }

        /** An item went in with this weight (another of the same adds to its count). */
        void put(Object item, float value) {
            int slot = find(item);
            if (slot >= 0) {
                update(slot, value);
                counts[slot]++;
                add(value);
                return;
            }
            if ((distinct + 1) * 2 > keys.length) grow();
            slot = ~find(item);
            keys[slot] = item;
            values[slot] = value;
            counts[slot] = 1;
            distinct++;
            add(value);
        }

        /** The item weighs this now: the sum changes by the difference, as many times as it is in the list. */
        void update(int slot, float value) {
            float before = values[slot];
            if (before == value) return;
            values[slot] = value;
            add(((double)value - before) * counts[slot]);
        }

        /** One of the item went out: the weight it was added with, or NaN when it is not here. */
        float take(Object item) {
            int slot = find(item);
            if (slot < 0) return Float.NaN;
            float value = values[slot];
            add(-(double)value);
            if (--counts[slot] == 0) remove(slot);
            return value;
        }

        private void remove(int slot) {
            int mask = keys.length - 1, hole = slot, next = slot;
            keys[hole] = null;
            while (true) {
                next = (next + 1) & mask;
                Object key = keys[next];
                if (key == null) break;
                int home = mix(key) & mask;
                // The key can move into the hole unless its home lies between the hole and where it is.
                if (((next - home) & mask) >= ((next - hole) & mask)) {
                    keys[hole] = key;
                    values[hole] = values[next];
                    counts[hole] = counts[next];
                    keys[next] = null;
                    hole = next;
                }
            }
            distinct--;
        }

        private void grow() {
            Object[] oldKeys = keys;
            float[] oldValues = values;
            int[] oldCounts = counts;
            keys = new Object[oldKeys.length * 2];
            values = new float[keys.length];
            counts = new int[keys.length];
            for (int index = 0; index < oldKeys.length; index++) {
                if (oldKeys[index] == null) continue;
                int slot = ~find(oldKeys[index]);
                keys[slot] = oldKeys[index];
                values[slot] = oldValues[index];
                counts[slot] = oldCounts[index];
            }
        }

        void clear() {
            Arrays.fill(keys, null);
            distinct = 0;
            sum = 0;
            inexact = false;
            Arrays.fill(special, 0, specials, null);
            specials = 0;
        }

        /** Whether the item is one of the special ones, and whether it is to be. */
        void special(Object item, boolean on) {
            for (int index = 0; index < specials; index++) {
                if (special[index] != item) continue;
                if (!on) {
                    special[index] = special[--specials];
                    special[specials] = null;
                }
                return;
            }
            if (!on) return;
            if (specials == special.length) special = Arrays.copyOf(special, Math.max(8, specials * 2));
            special[specials++] = item;
        }
    }

    // Guards every Kept, the notes below and the counters. The game's own thread asks (and waits for the lock); a hook on any
    // thread only tries it, and when another thread holds it raises the epoch instead, which makes every list be worked out
    // again at its next question: a hook never waits for this lock, so it cannot hold up the game's own locks.
    private final ReentrantLock lock = new ReentrantLock();
    // Set once a list was asked about: until then no hook has anything to keep up.
    private volatile boolean anyKept;
    // Items whose weight may have changed since the last question: noted when the game wrote a field, settled at the next question.
    private Object[] pending = new Object[16];
    private int pendingSize;
    private volatile int pendingCount;
    private static final int MAX_PENDING = 4096;
    // Raised to make every list be worked out again (should the notes outgrow their bound).
    private volatile int epoch;
    // Lists that hold an item whose container field is another: a change in the item cannot be found through the container.
    private final ArrayList<WeakReference<Kept>> looseKept = new ArrayList<>();
    // True while this API reads the game: the writes its reads make (a fluid container working out its amount) are not changes.
    private boolean computing;
    // How many lists are known to hold an item whose container is another (read without the lock).
    private volatile int looseCount;
    /** Items looked at while working lists out, lists worked out, changes settled, and weights worked out for one item: for the tests. */
    long visits, rebuilds, settled, worked;

    /** The kept account of a container's items; created (and the list made a tracked one, in a game that started before the hooks) when asked. */
    private Kept keptOf(Object container) throws Throwable {
        Object list = (Object)itemsGet.invokeExact(container);
        if (list == null) return null;
        Tracked tracked;
        if (list instanceof Tracked already) tracked = already;
        else {
            // The container was made before the hooks went in: its list is replaced by a tracked copy.
            tracked = new Tracked(Tracked.ITEMS, container, (ArrayList<?>)list);
            itemsSet.invokeExact(container, (Object)tracked);
        }
        if (tracked.kept instanceof Kept kept && kept.owner == this) return kept;
        Kept created = new Kept(this, tracked);
        tracked.kept = created;
        anyKept = true;
        return created;
    }

    /** The kept account of a container's items if there is one, without making any. */
    private Kept existing(Object container) throws Throwable {
        return (Object)itemsGet.invokeExact(container) instanceof Tracked list && list.kept instanceof Kept kept && kept.owner == this ? kept : null;
    }

    private boolean live(Kept kept, Formulas.Active now) { return !kept.stale && kept.built == now && kept.epoch == epoch; }

    /** The list of worn items as a tracked one (a game that started before the hooks has a plain one). */
    private Tracked wornTracked(Object worn) throws Throwable {
        Object list = (Object)wornList.invokeExact(worn);
        if (list instanceof Tracked tracked) return tracked;
        if (list == null) return null;
        Tracked tracked = new Tracked(Tracked.WORN, worn, (java.util.List<?>)list);
        wornItemsField.setAccessible(true);
        wornItemsField.set(worn, tracked);
        return tracked;
    }

    /** Whether the character wears and holds what the account was worked out for. */
    private boolean sameEquip(Kept kept, Object character) throws Throwable {
        if (kept.left != (Object)leftHand.invokeExact(character) || kept.right != (Object)rightHand.invokeExact(character)) return false;
        Object worn = (Object)wornOf.invokeExact(character);
        if (kept.worn != worn) return false;
        if (worn == null) return true;
        Object list = (Object)wornList.invokeExact(worn);
        return kept.wornList == list && (!(list instanceof Tracked tracked) || kept.wornVersion == tracked.version);
    }

    private void stampEquip(Kept kept, Object character) throws Throwable {
        kept.left = (Object)leftHand.invokeExact(character);
        kept.right = (Object)rightHand.invokeExact(character);
        Object worn = kept.worn = (Object)wornOf.invokeExact(character);
        Tracked list = worn == null ? null : wornTracked(worn);
        kept.wornList = list;
        kept.wornVersion = list == null ? 0 : list.version;
    }

    // ---- the weight an item adds to its list ----

    /**
     * The bag's container's account, worked out if need be and made to know that its bag is in {@code parent} (a list that is
     * not worked out for a bag in a list is for a bag nobody holds: a question about a bag's weight).
     */
    private Kept inner(Formulas.Active now, Object bag, Kept parent) throws Throwable {
        Object container = (Object)bagContainer.invokeExact(bag);
        if (container == null) return null;
        Kept kept = keptOf(container);
        if (kept == null) return null;
        if (kept.character != null || kept.stale || kept.built != now || kept.epoch != epoch) {
            kept.character = null;
            rebuild(now, kept);
        }
        if (parent != null) {
            kept.up = parent;
            kept.bag = bag;
        }
        return kept;
    }

    /** An item's weight with nothing equipped, as the load counts it: a bag's own times its factor, plus its items' times its tags'. */
    private float plain(Formulas.Active now, Object item, Kept parent) throws Throwable {
        if (!bagType.isInstance(item)) return (float)unequippedWeight.invokeExact(item) * factor(now, item);
        Kept contents = inner(now, item, parent);
        float own = (float)actualWeight.invokeExact(item) * factor(now, item);
        return (float)(own + (contents == null ? 0 : contents.sum * tagFactor(now, item)));
    }

    /** What an item of a character's inventory weighs as the game counts it for the character: unequipped, equipped or on the hotbar. */
    private float body(Formulas.Active now, Kept kept, Object item) throws Throwable {
        Object character = kept.character;
        boolean equipped = (boolean)characterEquipped.invokeExact(character, item);
        int how;
        if ((int)attachedSlot.invokeExact(item) > -1 && !equipped) how = HOTBAR;
        else if (equipped || (boolean)fakeEquipped.invokeExact(item, character)) how = EQUIPPED;
        else how = UNEQUIPPED;
        kept.special(item, how != UNEQUIPPED);
        if (how == UNEQUIPPED) return plain(now, item, kept);
        float vanilla = how == EQUIPPED ? (float)equippedWeight.invokeExact(item) : (float)hotbarWeight.invokeExact(item);
        if (!bagType.isInstance(item)) {
            float factor = factor(now, item);
            return factor == 1f ? vanilla : vanilla * factor;
        }
        float unequipped = (float)unequippedWeight.invokeExact(item), whole = plain(now, item, kept);
        if (whole == unequipped) return vanilla;
        // The game counts an item on the hotbar a fixed part of its whole weight.
        if (how == HOTBAR) return unequipped == 0f ? vanilla : whole * (vanilla / unequipped);
        // The game takes the weight reduction of a worn bag off its items, not off the bag itself.
        float own = (float)actualWeight.invokeExact(item) * factor(now, item);
        int reduction = (int)bagReduction.invokeExact(item);
        float taken = reduction > 0 ? 1 - reduction / 100f : 1f;
        return own * (float)(double)equippedMultiplier.invokeExact() + (whole - own) * taken;
    }

    private float value(Formulas.Active now, Kept kept, Object item) throws Throwable {
        worked++;
        return kept.character == null ? plain(now, item, kept) : body(now, kept, item);
    }

    // ---- keeping the account ----

    /** Works the list out from its items, once. */
    private void rebuild(Formulas.Active now, Kept kept) throws Throwable {
        if (kept.building) throw new IllegalStateException("a container holds itself");
        boolean outer = computing;
        int seen = epoch;
        kept.building = true;
        computing = true;
        try {
            unlink(kept);
            kept.clear();
            if (kept.character != null) {
                stampEquip(kept, kept.character);
                kept.multiplier = (double)equippedMultiplier.invokeExact();
            }
            Tracked list = kept.list;
            for (int index = 0, size = list.size(); index < size; index++) {
                Object item = list.get(index);
                kept.put(item, value(now, kept, item));
                visits++;
            }
            // The sum of a pass in order is the one a fresh pass gives.
            kept.inexact = false;
            kept.built = now;
            kept.epoch = seen;
            kept.stale = false;
            rebuilds++;
        } catch (Throwable failure) {
            kept.stale = true;
            throw failure;
        } finally {
            kept.building = false;
            computing = outer;
        }
    }

    /** The bags in the list no longer count it as their list. */
    private void unlink(Kept kept) throws Throwable {
        for (Object key : kept.keys) if (key != null && bagType.isInstance(key)) unlink(kept, key);
    }

    private void unlink(Kept kept, Object bag) throws Throwable {
        Object container = (Object)bagContainer.invokeExact(bag);
        if (container != null && existing(container) instanceof Kept contents && contents.up == kept && contents.bag == bag) {
            contents.up = null;
            contents.bag = null;
        }
    }

    /** The list, and every list it is in through a bag, are to be worked out again at the next question. */
    private void invalidate(Kept kept) {
        for (Kept next; kept != null && !kept.stale; kept = next) {
            kept.stale = true;
            next = kept.up;
            kept.up = null;
        }
    }

    /** The sum of the list changed: the list its bag is in follows, up to the character's. */
    private void afterChange(Formulas.Active now, Kept kept, int depth) throws Throwable {
        if (kept.inexact) {
            kept.inexact = false;
            invalidate(kept);
            return;
        }
        Kept up = kept.up;
        if (up == null || up.stale || up.built != now || up.epoch != epoch) return;
        if (up.find(kept.bag) < 0 || depth > 64) { invalidate(up); return; }
        refresh(now, up, kept.bag, depth + 1);
    }

    /** Works out again what one item of the list weighs and changes the sum by the difference. */
    private void refresh(Formulas.Active now, Kept kept, Object item, int depth) throws Throwable {
        int slot = kept.find(item);
        if (slot < 0) return;
        kept.update(slot, value(now, kept, item));
        afterChange(now, kept, depth);
    }

    // ---- the game's changes ----

    /** An item went into a tracked list. */
    void added(Formulas.Active now, Tracked list, Object item) throws Throwable {
        if (!(list.kept instanceof Kept kept) || kept.owner != this) return;
        if (!lock.tryLock()) { epoch++; return; }
        try {
            if (!live(kept, now)) { invalidate(kept); return; }
            boolean outer = computing;
            computing = true;
            try {
                kept.put(item, value(now, kept, item));
                // An item that is in a list but whose container is another cannot be found from its container later.
                if (!kept.loose && (Object)containerOf.invokeExact(item) != list.owner) {
                    kept.loose = true;
                    looseKept.add(new WeakReference<>(kept));
                    looseCount = looseKept.size();
                }
                afterChange(now, kept, 0);
            } catch (Throwable failure) {
                invalidate(kept);
                throw failure;
            } finally { computing = outer; }
        } finally { lock.unlock(); }
    }

    /** An item came out of a tracked list. */
    void removed(Formulas.Active now, Tracked list, Object item) throws Throwable {
        if (!(list.kept instanceof Kept kept) || kept.owner != this) return;
        if (!lock.tryLock()) { epoch++; return; }
        try {
            if (!live(kept, now)) { invalidate(kept); return; }
            try {
                if (Float.isNaN(kept.take(item))) { invalidate(kept); return; }
                if (kept.find(item) < 0) {
                    kept.special(item, false);
                    if (bagType.isInstance(item)) unlink(kept, item);
                }
                afterChange(now, kept, 0);
            } catch (Throwable failure) {
                invalidate(kept);
                throw failure;
            }
        } finally { lock.unlock(); }
    }

    /** A tracked list was emptied. */
    void cleared(Formulas.Active now, Tracked list) throws Throwable {
        if (!(list.kept instanceof Kept kept) || kept.owner != this) return;
        if (!lock.tryLock()) { epoch++; return; }
        try {
            if (!live(kept, now)) { invalidate(kept); return; }
            try {
                unlink(kept);
                kept.clear();
                afterChange(now, kept, 0);
            } catch (Throwable failure) {
                invalidate(kept);
                throw failure;
            }
        } finally { lock.unlock(); }
    }

    /** A tracked list changed in a way that does not say which items: worked out again at the next question. */
    void changed(Tracked list) {
        if (!(list.kept instanceof Kept kept) || kept.owner != this) return;
        if (!lock.tryLock()) { epoch++; return; }
        try { invalidate(kept); }
        finally { lock.unlock(); }
    }

    /** The container is about to have another list of items. */
    void replacing(Object container) throws Throwable {
        if (!lock.tryLock()) { epoch++; return; }
        try {
            Kept kept = existing(container);
            if (kept != null) invalidate(kept);
        } finally { lock.unlock(); }
    }

    /** The game wrote a field that the item's weight reads: noted, and settled at the next question. */
    void weightChanged(Object item) throws Throwable {
        if (!anyKept || !itemType.isInstance(item)) return;
        // Most writes are of items nobody asked about (the world's, on any thread): they do not take the lock.
        Object container = (Object)containerOf.invokeExact(item);
        if ((container == null || existing(container) == null) && looseCount == 0) return;
        if (!lock.tryLock()) { epoch++; return; }
        try {
            if (computing) return;
            if (pendingSize > 0 && pending[pendingSize - 1] == item) return;
            if (pendingSize == pending.length) {
                if (pendingSize >= MAX_PENDING) {
                    // More changes than are worth following one by one: every list is worked out again when asked.
                    Arrays.fill(pending, null);
                    pendingSize = 0;
                    pendingCount = 0;
                    epoch++;
                    return;
                }
                pending = Arrays.copyOf(pending, pending.length * 2);
            }
            pending[pendingSize++] = item;
            pendingCount = pendingSize;
        } finally { lock.unlock(); }
    }

    /** A fluid container's amount may have changed: the weight of the item it belongs to. */
    void fluidChanged(Object fluid) throws Throwable {
        if (!anyKept || !fluidType.isInstance(fluid)) return;
        Object owner = (Object)fluidOwner.invokeExact(fluid);
        if (itemType.isInstance(owner)) weightChanged(owner);
    }

    /** Works out again the items the game wrote to since the last question. */
    private void settle(Formulas.Active now) throws Throwable {
        if (pendingSize == 0) return;
        boolean outer = computing;
        computing = true;
        try {
            for (int index = 0; index < pendingSize; index++) {
                Object item = pending[index];
                pending[index] = null;
                settled++;
                Object container = (Object)containerOf.invokeExact(item);
                Kept kept = container == null ? null : existing(container);
                if (kept != null && live(kept, now) && kept.find(item) >= 0) { refresh(now, kept, item, 0); continue; }
                // The container is not the item's list: lists known to hold items that were put in through the list itself.
                for (int at = looseKept.size() - 1; at >= 0; at--) {
                    Kept other = looseKept.get(at).get();
                    if (other == null) { looseKept.remove(at); looseCount = looseKept.size(); continue; }
                    if (live(other, now) && other.find(item) >= 0) refresh(now, other, item, 0);
                }
            }
        } finally {
            pendingSize = 0;
            pendingCount = 0;
            computing = outer;
        }
    }

    // ---- the questions ----

    /**
     * How heavy the character's inventory is as the load's formulas count it, or NaN when its list of items cannot be followed
     * (the game's own answer then). Nothing changed since the last time: a few field reads.
     */
    float total(Formulas.Active now, Object character) throws Throwable {
        Object container = (Object)inventoryOf.invokeExact(character);
        if (container == null) return Float.NaN;
        if ((Object)itemsGet.invokeExact(container) instanceof Tracked list && list.kept instanceof Kept kept && kept.owner == this
                && pendingCount == 0 && !kept.stale && kept.built == now && kept.epoch == epoch && kept.character == character
                && kept.multiplier == (double)equippedMultiplier.invokeExact() && sameEquip(kept, character))
            return (float)kept.sum;
        lock.lock();
        try {
            Kept kept = keptOf(container);
            if (kept == null) return Float.NaN;
            settle(now);
            if (kept.character != character) {
                kept.character = character;
                kept.stale = true;
            }
            if (kept.stale || kept.built != now || kept.epoch != epoch || kept.multiplier != (double)equippedMultiplier.invokeExact()) rebuild(now, kept);
            else if (!sameEquip(kept, character)) refreshEquip(now, kept, character);
            return (float)kept.sum;
        } finally { lock.unlock(); }
    }

    /** What the character wears and holds changed: the items it concerns are worked out again. */
    private void refreshEquip(Formulas.Active now, Kept kept, Object character) throws Throwable {
        boolean outer = computing;
        computing = true;
        try {
            Object worn = (Object)wornOf.invokeExact(character);
            Tracked list = worn == null ? null : wornTracked(worn);
            int size = list == null ? 0 : list.size();
            Object[] candidates = new Object[kept.specials + 2 + size];
            System.arraycopy(kept.special, 0, candidates, 0, kept.specials);
            candidates[kept.specials] = (Object)leftHand.invokeExact(character);
            candidates[kept.specials + 1] = (Object)rightHand.invokeExact(character);
            for (int index = 0; index < size; index++) candidates[kept.specials + 2 + index] = (Object)wornItemOf.invokeExact(list.get(index));
            stampEquip(kept, character);
            for (Object candidate : candidates) if (candidate != null) refresh(now, kept, candidate, 0);
        } finally { computing = outer; }
    }

    /** An item's weight with nothing equipped, as the load counts it. */
    float unequipped(Formulas.Active now, Object item) throws Throwable {
        lock.lock();
        try {
            settle(now);
            boolean outer = computing;
            computing = true;
            try { return plain(now, item, null); }
            finally { computing = outer; }
        } finally { lock.unlock(); }
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
        float whole = unequipped(now, item);
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
