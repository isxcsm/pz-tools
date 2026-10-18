package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * An object match (docs/design.md, "Objects"): the conditions a table states, read once into plain arrays and handles, and asked of
 * each object without allocating. A condition that a table leaves out is not tested; the cheap ones are asked first.
 *
 * <p>Used on the game's thread only: the answer for the last class asked about is kept ({@code class} and {@code notClass} depend on
 * the class alone, and the objects of a square are mostly of few).
 */
final class ObjectMatch {
    /** The levels of bags in bags {@code holds} looks into, as a floor item is looked into. */
    static final int DEPTH = 8;
    private static final int MAX_NAMES = 512;
    private static final Pattern CLASS_NAME = Pattern.compile("[A-Za-z0-9_]{1,64}");
    private static final String[] PACKAGES = { "zombie.iso.objects.", "zombie.iso.", "zombie.vehicles.", "zombie.characters." };
    private static final String[] KEYS = { "class", "notClass", "sprite", "spritePrefix", "props", "propIn", "data", "noData", "container", "holds" };

    /**
     * The game's members a match reads, as handles called exactly, made once for an API: an object's properties and sprite, mod data
     * and containers, and an item container's items.
     */
    static final class Handles {
        private final Game game;
        private final ClassLoader loader;
        // IsoObject.getProperties(); PropertyContainer.has(String), get(String); IsoSprite.getName().
        private final MethodHandle properties, has, get, spriteName;
        // IsoObject.hasModData(), getModData(), getContainerCount(), getContainerByIndex(int); KahluaTable.rawget(Object).
        private final MethodHandle hasData, dataOf, rawget, containerCount, containerAt;
        // ItemContainer.getItems(); InventoryContainer.getInventory().
        private final MethodHandle itemsOf, inventoryOf;
        private final Class<?> bag;
        private final Map<String, Class<?>> classes = new HashMap<>();

        Handles(Game game, ClassLoader loader) throws ReflectiveOperationException {
            this.game = game;
            this.loader = loader;
            Class<?> object = game.objectType, container = game.container;
            MethodType objectOf = MethodType.methodType(Object.class, Object.class);
            Class<?> props = Game.type(loader, "zombie.core.properties.PropertyContainer");
            properties = Game.exact(object.getMethod("getProperties"), objectOf);
            has = Game.exact(props.getMethod("has", String.class), MethodType.methodType(boolean.class, Object.class, String.class));
            get = Game.exact(props.getMethod("get", String.class), MethodType.methodType(String.class, Object.class, String.class));
            spriteName = Game.exact(Game.type(loader, "zombie.iso.sprite.IsoSprite").getMethod("getName"),
                MethodType.methodType(String.class, Object.class));
            hasData = Game.exact(object.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
            dataOf = Game.exact(object.getMethod("getModData"), objectOf);
            rawget = Game.exact(Game.type(loader, "se.krka.kahlua.vm.KahluaTable").getMethod("rawget", Object.class),
                MethodType.methodType(Object.class, Object.class, Object.class));
            containerCount = Game.exact(object.getMethod("getContainerCount"), MethodType.methodType(int.class, Object.class));
            containerAt = Game.exact(object.getMethod("getContainerByIndex", int.class),
                MethodType.methodType(Object.class, Object.class, int.class));
            bag = Game.type(loader, "zombie.inventory.types.InventoryContainer");
            itemsOf = Game.exact(container.getMethod("getItems"), MethodType.methodType(List.class, Object.class));
            inventoryOf = Game.exact(bag.getMethod("getInventory"), objectOf);
        }

        /** The game's object class a name stands for, or null. */
        Class<?> objectClass(String name) {
            Class<?> found = classes.get(name);
            if (found != null) return found;
            if (!CLASS_NAME.matcher(name).matches()) return null;
            for (String prefix : PACKAGES) {
                try { found = Game.type(loader, prefix + name); }
                catch (ClassNotFoundException other) { continue; }
                if (game.objectType.isAssignableFrom(found)) { classes.put(name, found); return found; }
            }
            return null;
        }

        /** The mod data of the object, or null when it has none (a table is not made for it). */
        Object dataOf(Object object) throws Throwable {
            return (boolean)hasData.invokeExact(object) ? (Object)dataOf.invokeExact(object) : null;
        }

        Object rawget(Object table, Object key) throws Throwable { return (Object)rawget.invokeExact(table, key); }
    }

    /** A property whose value is one of some, or (with {@code absent}) none at all. */
    private record PropIn(String name, String[] values, boolean absent) { }

    private final Handles h;
    private final Class<?>[] classes, notClasses;
    private final String[] sprites, prefixes, props;
    private final PropIn[] propIn;
    private final String[] dataKeys;
    private final Object[] dataValues;
    private final String noData;
    private final boolean container;
    private final ItemMatch holds;
    private Class<?> lastClass;
    private boolean lastOk;

    private ObjectMatch(Handles h, Class<?>[] classes, Class<?>[] notClasses, String[] sprites, String[] prefixes, String[] props,
            PropIn[] propIn, String[] dataKeys, Object[] dataValues, String noData, boolean container, ItemMatch holds) {
        this.h = h; this.classes = classes; this.notClasses = notClasses; this.sprites = sprites; this.prefixes = prefixes;
        this.props = props; this.propIn = propIn; this.dataKeys = dataKeys; this.dataValues = dataValues; this.noData = noData;
        this.container = container; this.holds = holds;
    }

    /** Reads a match table; a key that is not a match's, or a value of the wrong kind, is the mod's error, named with {@code call}. */
    static ObjectMatch read(Handles h, Kahlua lua, Game game, Object table, String call) throws ReflectiveOperationException {
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": match must be a table");
        for (var entry : lua.entries(table)) {
            if (!(entry.getKey() instanceof String key) || !List.of(KEYS).contains(key))
                throw new IllegalArgumentException(call + ": match." + entry.getKey() + " is not a match key (" + String.join(", ", KEYS) + ")");
        }
        Class<?>[] classes = classes(h, lua, table, "class", call), notClasses = classes(h, lua, table, "notClass", call);
        String[] sprites = names(lua, table, "sprite", call), prefixes = names(lua, table, "spritePrefix", call), props = names(lua, table, "props", call);
        PropIn[] propIn = propIn(lua, table, call);
        String[] dataKeys = null;
        Object[] dataValues = null;
        Object data = lua.get(table, "data");
        if (data instanceof String key) {
            dataKeys = new String[] { key };
            dataValues = new Object[1];
        } else if (data != null) {
            if (!lua.isTable(data)) throw new IllegalArgumentException(call + ": match.data must be a key or { key = value }");
            var pairs = lua.entries(data);
            if (pairs.isEmpty()) throw new IllegalArgumentException(call + ": match.data must name at least one key");
            dataKeys = new String[pairs.size()];
            dataValues = new Object[pairs.size()];
            int at = 0;
            for (var pair : pairs) {
                if (!(pair.getKey() instanceof String key) || !(pair.getValue() instanceof Double || pair.getValue() instanceof String
                        || pair.getValue() instanceof Boolean))
                    throw new IllegalArgumentException(call + ": match.data must be a key or { key = value } with a number, string or boolean value");
                dataKeys[at] = key;
                dataValues[at++] = pair.getValue();
            }
        }
        Object noData = lua.get(table, "noData");
        if (noData != null && !(noData instanceof String)) throw new IllegalArgumentException(call + ": match.noData must be a mod data key");
        Object container = lua.get(table, "container");
        if (container != null && !(container instanceof Boolean)) throw new IllegalArgumentException(call + ": match.container must be true or false");
        Object held = lua.get(table, "holds");
        ItemMatch holds = held == null ? null : ItemMatch.read(lua, game, held, call + " (match.holds)");
        return new ObjectMatch(h, classes, notClasses, sprites, prefixes, props, propIn, dataKeys, dataValues, (String)noData,
            Boolean.TRUE.equals(container), holds);
    }

    /** A list of strings, or one string, under the key; null when it is left out. */
    private static String[] names(Kahlua lua, Object table, String key, String call) throws ReflectiveOperationException {
        Object value = lua.get(table, key);
        if (value == null) return null;
        if (value instanceof String single) return new String[] { single };
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": match." + key + " must be a list of strings");
        var found = new ArrayList<String>();
        for (Object entry = lua.get(value, 1.0); entry != null; entry = lua.get(value, (double)(found.size() + 1))) {
            if (!(entry instanceof String text)) throw new IllegalArgumentException(call + ": match." + key + " must be a list of strings");
            if (found.size() == MAX_NAMES) throw new IllegalArgumentException(call + ": match." + key + " may have at most " + MAX_NAMES + " names");
            found.add(text);
        }
        if (found.isEmpty()) throw new IllegalArgumentException(call + ": match." + key + " must name at least one");
        return found.toArray(new String[0]);
    }

    private static Class<?>[] classes(Handles h, Kahlua lua, Object table, String key, String call) throws ReflectiveOperationException {
        String[] named = names(lua, table, key, call);
        if (named == null) return null;
        var found = new Class<?>[named.length];
        for (int at = 0; at < named.length; at++) {
            found[at] = h.objectClass(named[at]);
            if (found[at] == null)
                throw new IllegalArgumentException(call + ": match." + key + " \"" + named[at] + "\" is not one of the game's object classes (such as \"IsoDoor\")");
        }
        return found;
    }

    private static PropIn[] propIn(Kahlua lua, Object table, String call) throws ReflectiveOperationException {
        Object value = lua.get(table, "propIn");
        if (value == null) return null;
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": match.propIn must be { Name = { \"a\", \"b\", false } }");
        var found = new ArrayList<PropIn>();
        for (var entry : lua.entries(value)) {
            if (!(entry.getKey() instanceof String name) || !lua.isTable(entry.getValue()))
                throw new IllegalArgumentException(call + ": match.propIn must be { Name = { \"a\", \"b\", false } }");
            var values = new ArrayList<String>();
            boolean absent = false;
            Object list = entry.getValue();
            for (int at = 1; lua.get(list, (double)at) != null; at++) {
                Object one = lua.get(list, (double)at);
                if (Boolean.FALSE.equals(one)) absent = true;
                else if (one instanceof String text) values.add(text);
                else if (one instanceof Double number && number == Math.rint(number) && Math.abs(number) < 1e15) values.add(Long.toString(number.longValue()));
                else throw new IllegalArgumentException(call + ": match.propIn." + name + " must list strings, and false for none");
            }
            if (values.isEmpty() && !absent) throw new IllegalArgumentException(call + ": match.propIn." + name + " must list at least one value");
            found.add(new PropIn(name, values.toArray(new String[0]), absent));
        }
        return found.isEmpty() ? null : found.toArray(new PropIn[0]);
    }

    /** Whether the object meets every condition. */
    boolean test(Object object) throws Throwable {
        if (classes != null || notClasses != null) {
            Class<?> type = object.getClass();
            if (type != lastClass) { lastOk = ofClass(type); lastClass = type; }
            if (!lastOk) return false;
        }
        if (container && (int)h.containerCount.invokeExact(object) == 0) return false;
        if (dataKeys != null && !hasData(object)) return false;
        if (noData != null) {
            Object data = h.dataOf(object);
            if (data != null && h.rawget(data, noData) != null) return false;
        }
        if (sprites != null || prefixes != null) {
            Object sprite = (Object)Reach.SPRITE_OF.invokeExact(object);
            String name = sprite == null ? null : (String)h.spriteName.invokeExact(sprite);
            if (name == null) return false;
            if (sprites != null && !contains(sprites, name)) return false;
            if (prefixes != null && !startsWith(prefixes, name)) return false;
        }
        if ((props != null || propIn != null) && !propertiesOk(object)) return false;
        return holds == null || holds(object);
    }

    private boolean ofClass(Class<?> type) {
        if (classes != null) {
            boolean any = false;
            for (Class<?> wanted : classes) if (wanted.isAssignableFrom(type)) { any = true; break; }
            if (!any) return false;
        }
        if (notClasses != null) for (Class<?> unwanted : notClasses) if (unwanted.isAssignableFrom(type)) return false;
        return true;
    }

    private static boolean contains(String[] names, String name) {
        for (String candidate : names) if (candidate.equals(name)) return true;
        return false;
    }

    private static boolean startsWith(String[] prefixes, String name) {
        for (String prefix : prefixes) if (name.startsWith(prefix)) return true;
        return false;
    }

    private boolean hasData(Object object) throws Throwable {
        Object data = h.dataOf(object);
        if (data == null) return false;
        for (int at = 0; at < dataKeys.length; at++) {
            Object held = h.rawget(data, dataKeys[at]), wanted = dataValues[at];
            if (held == null) return false;
            if (wanted == null) continue;
            if (wanted instanceof Double number ? !(held instanceof Number other && other.doubleValue() == number) : !wanted.equals(held)) return false;
        }
        return true;
    }

    private boolean propertiesOk(Object object) throws Throwable {
        Object all = (Object)h.properties.invokeExact(object);
        if (props != null) {
            if (all == null) return false;
            for (String name : props) if (!(boolean)h.has.invokeExact(all, name)) return false;
        }
        if (propIn != null) {
            for (PropIn wanted : propIn) {
                String value = all == null ? null : (String)h.get.invokeExact(all, wanted.name());
                if (value == null ? !wanted.absent() : !contains(wanted.values(), value)) return false;
            }
        }
        return true;
    }

    /** Whether a container of the object holds a matching item, in bags in bags as deep as {@link #DEPTH}. */
    private boolean holds(Object object) throws Throwable {
        for (int at = 0, count = (int)h.containerCount.invokeExact(object); at < count; at++) {
            Object one = (Object)h.containerAt.invokeExact(object, at);
            if (one != null && holdsIn(one, DEPTH)) return true;
        }
        return false;
    }

    private boolean holdsIn(Object container, int levels) throws Throwable {
        List<?> items = (List<?>)h.itemsOf.invokeExact(container);
        if (items == null) return false;
        for (int at = 0, size = items.size(); at < size; at++) {
            Object item = items.get(at);
            if (item == null) continue;
            if (holds.test(item)) return true;
            if (levels > 1 && h.bag.isInstance(item)) {
                Object inner = (Object)h.inventoryOf.invokeExact(item);
                if (inner != null && holdsIn(inner, levels - 1)) return true;
            }
        }
        return false;
    }
}
