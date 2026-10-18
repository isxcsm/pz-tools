package pzext.api;

import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import pzext.api.ItemCalls.Calls;

/**
 * An item match (docs/design.md, "Items"), compiled once and kept weakly by the Lua table it was read from: a table used
 * again costs a map probe. A table changed after its first use is not read again. The match holds nothing of the table
 * (the cache would then never let it go), only what it read: the types, the game's tags, the mod data keys and the character.
 *
 * <p>The keys: {@code type} (a list of full types), {@code tag} (a list of tags: the game's {@code ItemTag} objects, their
 * constants' names such as {@code "SCREWDRIVER"}, or their registered names such as {@code "base:screwdriver"}; the item has one of
 * them, as {@code InventoryItem.hasTag} says), {@code data} (a mod data key it has, or a table of key = value it has all of),
 * {@code dataPrefix} (a table of key = prefix: the string value is the prefix or starts with it followed by {@code #}),
 * {@code notBroken}, {@code notFavorite} (true tests; false is not tested), {@code notEquippedBy} (a character: the item is neither
 * worn nor in a hand, {@code isEquipped}, nor on the hotbar, {@code isAttachedItem}). An item must meet all that are given.
 */
final class ItemMatch {
    private static final String KEYS = "type, tag, data, dataPrefix, notBroken, notEquippedBy, notFavorite";
    /** More types than this are looked up in a set; fewer, in the array (a few string compares beat a hash). */
    private static final int LINEAR = 6;
    private static final ItemMatch ALL = new ItemMatch();
    // Match by the table's identity (a Lua table has no equals of its own); the entry goes with the table.
    private static final WeakHashMap<Object, ItemMatch> CACHE = new WeakHashMap<>();

    private String[] types;
    private HashSet<String> typeSet;
    private Object[] tags;
    // data: keys, and the value each must have (null: any value); dataPrefix: keys and the prefix each value must have.
    private Object[] dataKeys, dataValues, prefixKeys;
    private String[] prefixes;
    private boolean notBroken, notFavorite;
    private Object notEquippedBy;

    private ItemMatch() { }

    /**
     * The match the table says, read once. A missing table (nil) matches every item; anything else that is not a table is the
     * calling mod's error, as is a key or a value this vocabulary does not have.
     */
    static ItemMatch read(Kahlua lua, Game game, Object table, String call) throws ReflectiveOperationException {
        if (table == null) return ALL;
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": match must be a table (or nil for every item)");
        ItemCalls.prepare(game.container.getClassLoader());
        synchronized (CACHE) {
            ItemMatch kept = CACHE.get(table);
            if (kept != null) return kept;
        }
        ItemMatch match = new ItemMatch();
        try {
            for (Map.Entry<Object, Object> entry : lua.entries(table)) {
                Object key = entry.getKey(), value = entry.getValue();
                if (!(key instanceof String name)) throw new IllegalArgumentException(call + ": match has the key " + key + "; the keys are " + KEYS);
                match.set(lua, name, value, call);
            }
        } catch (ReflectiveOperationException | RuntimeException refused) {
            throw refused;
        } catch (Throwable failure) {
            throw Game.thrown(failure);
        }
        synchronized (CACHE) { CACHE.put(table, match); }
        return match;
    }

    private void set(Kahlua lua, String name, Object value, String call) throws Throwable {
        switch (name) {
            case "type" -> {
                List<Object> list = list(lua, value, call, "type", "a list of full types (\"Base.Paperclip\")");
                types = new String[list.size()];
                for (int index = 0; index < types.length; index++) {
                    if (!(list.get(index) instanceof String type) || type.isEmpty())
                        throw new IllegalArgumentException(call + ": type[" + (index + 1) + "] must be a full type (\"Base.Paperclip\")");
                    types[index] = type;
                }
                if (types.length > LINEAR) typeSet = new HashSet<>(List.of(types));
            }
            case "tag" -> {
                List<Object> list = list(lua, value, call, "tag", "a list of item tags (ItemTag.SCREWDRIVER, \"SCREWDRIVER\" or \"base:screwdriver\")");
                tags = new Object[list.size()];
                for (int index = 0; index < tags.length; index++) tags[index] = tag(list.get(index), call, index + 1);
            }
            case "data" -> {
                if (value instanceof String || value instanceof Double) {
                    dataKeys = new Object[] { value };
                    dataValues = new Object[1];
                } else {
                    List<Map.Entry<Object, Object>> pairs = pairs(lua, value, call, "data", "a mod data key, or a table of key = value");
                    dataKeys = new Object[pairs.size()];
                    dataValues = new Object[pairs.size()];
                    for (int index = 0; index < dataKeys.length; index++) {
                        Object wanted = pairs.get(index).getValue();
                        if (!(wanted instanceof String || wanted instanceof Double || wanted instanceof Boolean))
                            throw new IllegalArgumentException(call + ": data." + pairs.get(index).getKey() + " must be a string, a number or a boolean");
                        dataKeys[index] = pairs.get(index).getKey();
                        dataValues[index] = wanted;
                    }
                }
            }
            case "dataPrefix" -> {
                List<Map.Entry<Object, Object>> pairs = pairs(lua, value, call, "dataPrefix", "a table of key = prefix");
                prefixKeys = new Object[pairs.size()];
                prefixes = new String[pairs.size()];
                for (int index = 0; index < prefixKeys.length; index++) {
                    if (!(pairs.get(index).getValue() instanceof String prefix))
                        throw new IllegalArgumentException(call + ": dataPrefix." + pairs.get(index).getKey() + " must be a string");
                    prefixKeys[index] = pairs.get(index).getKey();
                    prefixes[index] = prefix;
                }
            }
            case "notBroken" -> notBroken = bool(value, call, name);
            case "notFavorite" -> notFavorite = bool(value, call, name);
            case "notEquippedBy" -> {
                if (!Calls.CHARACTER.isInstance(value)) throw new IllegalArgumentException(call + ": notEquippedBy must be a character");
                notEquippedBy = value;
            }
            default -> throw new IllegalArgumentException(call + ": match has the key " + name + "; the keys are " + KEYS);
        }
    }

    private static boolean bool(Object value, String call, String name) {
        if (!(value instanceof Boolean flag)) throw new IllegalArgumentException(call + ": " + name + " must be true or false");
        return flag;
    }

    private static List<Object> list(Kahlua lua, Object value, String call, String name, String what) throws Throwable {
        if (value instanceof String single) return List.of(single);
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": " + name + " must be " + what);
        int size = lua.length(value);
        var result = new ArrayList<Object>(size);
        for (int index = 1; index <= size; index++) result.add(lua.at(value, index));
        return result;
    }

    /** A table's entries, its keys strings or numbers (a list given for a table of pairs is refused, not read as keys 1, 2, ...). */
    private static List<Map.Entry<Object, Object>> pairs(Kahlua lua, Object value, String call, String name, String what)
            throws ReflectiveOperationException {
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": " + name + " must be " + what);
        List<Map.Entry<Object, Object>> entries = lua.entries(value);
        for (Map.Entry<Object, Object> entry : entries)
            if (!(entry.getKey() instanceof String))
                throw new IllegalArgumentException(call + ": " + name + " must be " + what + "; its key " + entry.getKey() + " is not a string");
        return entries;
    }

    /** The game's tag a mod named: the object itself, a constant's name ({@code SCREWDRIVER}) or a registered name ({@code base:screwdriver}). */
    private static Object tag(Object named, String call, int at) {
        if (Calls.TAG.isInstance(named)) return named;
        if (!(named instanceof String text) || text.isEmpty())
            throw new IllegalArgumentException(call + ": tag[" + at + "] must be an item tag (ItemTag.SCREWDRIVER, \"SCREWDRIVER\" or \"base:screwdriver\")");
        Object found = null;
        if (text.indexOf(':') < 0) {
            try {
                Field constant = Calls.TAG.getField(text);
                if (Modifier.isStatic(constant.getModifiers()) && constant.getType() == Calls.TAG) found = constant.get(null);
            } catch (ReflectiveOperationException | RuntimeException unknown) { }
        }
        if (found == null) {
            try { found = Calls.TAG_GET.invoke(null, Calls.LOCATION_OF.invoke(null, text)); }
            catch (ReflectiveOperationException | RuntimeException unknown) { }
        }
        if (found == null) throw new IllegalArgumentException(call + ": the game has no item tag " + text);
        return found;
    }

    /** Whether the item (never null) meets every condition: the cheap and selective ones first. */
    boolean test(Object item) throws Throwable {
        String[] types = this.types;
        if (types != null) {
            String type = (String)Calls.FULL_TYPE.invokeExact(item);
            if (typeSet != null) {
                if (!typeSet.contains(type)) return false;
            } else {
                boolean found = false;
                for (int index = 0; index < types.length; index++)
                    if (types[index].equals(type)) { found = true; break; }
                if (!found) return false;
            }
        }
        Object[] tags = this.tags;
        if (tags != null) {
            boolean found = false;
            for (int index = 0; index < tags.length; index++)
                if ((boolean)Calls.HAS_TAG.invokeExact(item, tags[index])) { found = true; break; }
            if (!found) return false;
        }
        if (notBroken && (boolean)Calls.BROKEN.invokeExact(item)) return false;
        if (notFavorite && (boolean)Calls.FAVORITE.invokeExact(item)) return false;
        if (dataKeys != null || prefixKeys != null) {
            if (!(boolean)Calls.HAS_DATA.invokeExact(item)) return false;
            Object data = (Object)Calls.DATA.invokeExact(item);
            if (dataKeys != null) {
                for (int index = 0; index < dataKeys.length; index++) {
                    Object value = (Object)Calls.RAWGET.invokeExact(data, dataKeys[index]);
                    if (value == null || dataValues[index] != null && !dataValues[index].equals(value)) return false;
                }
            }
            if (prefixKeys != null) {
                for (int index = 0; index < prefixKeys.length; index++) {
                    if (!((Object)Calls.RAWGET.invokeExact(data, prefixKeys[index]) instanceof String value)) return false;
                    String prefix = prefixes[index];
                    if (!value.equals(prefix) && !(value.length() > prefix.length() && value.charAt(prefix.length()) == '#' && value.startsWith(prefix)))
                        return false;
                }
            }
        }
        Object by = notEquippedBy;
        if (by != null && ((boolean)Calls.EQUIPPED.invokeExact(by, item) || (boolean)Calls.ATTACHED.invokeExact(by, item))) return false;
        return true;
    }
}
