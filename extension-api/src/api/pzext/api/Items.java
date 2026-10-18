package pzext.api;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import pzext.api.ItemCalls.Calls;

/**
 * {@code PZExtAPI.items.find} and {@code items.types} (docs/design.md, "Items"): the items of a container, a bag or a world
 * object that meet an {@link ItemMatch}, and the distinct full types in them, walked in Java through handles, with no Lua table
 * per item: only the lists that are the answer.
 *
 * <p>A container's own items come first, in the game's order, then those of the bags in it, bag after bag, each as deep as
 * {@code depth} says (0: the source's own items only). A character is taken for its inventory.
 */
final class Items {
    static final int DEFAULT_DEPTH = 3, MAX_DEPTH = 32;
    private static final String AREA = "PZExtAPI.items.";
    // In the API's metatable: which API runs the functions now.
    private static final String GENERATION = "itemQueriesGeneration";
    private static final String SOURCE = "source must be an item container, a bag, a character or a world object";

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private long generation;

    Items(Kahlua lua, Game game, Object meta, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        ItemCalls.prepare(loader);
    }

    /** The functions an earlier API gave refuse to be called from now on. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
    }

    /** Sets {@code find} and {@code types} into the items table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        String find = AREA + "find", types = AREA + "types";
        lua.set(table, "find", lua.function(find, arguments -> {
            current(find);
            try { return find(arguments, find); }
            catch (IllegalArgumentException refused) { throw refused; }
            catch (Throwable failure) { throw Game.failed(Game.thrown(failure)); }
        }));
        lua.set(table, "types", lua.function(types, arguments -> {
            current(types);
            try { return types(arguments, types); }
            catch (IllegalArgumentException refused) { throw refused; }
            catch (Throwable failure) { throw Game.failed(Game.thrown(failure)); }
        }));
    }

    /** What a walk does with an item: true to go on. */
    private interface Sink { boolean item(Object item, Object container) throws Throwable; }

    private Object[] find(Object[] arguments, String call) throws Throwable {
        Object source = arguments.length > 0 ? arguments[0] : null;
        ItemMatch match = ItemMatch.read(lua, game, arguments.length > 1 ? arguments[1] : null, call);
        Object options = arguments.length > 2 ? arguments[2] : null;
        int depth = depth(options, call), limit = limit(options, call);
        var found = new ArrayList<Object>();
        var holders = new ArrayList<Object>();
        if (limit != 0) {
            walk(source, depth, call, (item, container) -> {
                if (!match.test(item)) return true;
                found.add(item);
                holders.add(container);
                return found.size() < limit;
            });
        }
        return new Object[] { list(found), list(holders) };
    }

    private Object[] types(Object[] arguments, String call) throws Throwable {
        Object source = arguments.length > 0 ? arguments[0] : null;
        Object options = arguments.length > 1 ? arguments[1] : null;
        int depth = depth(options, call);
        Object skip = options == null ? null : lua.get(options, "skip");
        if (skip != null && !lua.isTable(skip)) throw new IllegalArgumentException(call + ": skip must be a table whose keys are the types to leave out");
        var seen = new HashSet<String>();
        var types = new ArrayList<Object>();
        walk(source, depth, call, (item, container) -> {
            String type = (String)Calls.FULL_TYPE.invokeExact(item);
            if (type == null || !seen.add(type)) return true;
            if (skip == null || (Object)Calls.RAWGET.invokeExact(skip, (Object)type) == null) types.add(type);
            return true;
        });
        return new Object[] { list(types) };
    }

    private int depth(Object options, String call) throws ReflectiveOperationException {
        checkOptions(options, call);
        Object value = options == null ? null : lua.get(options, "depth");
        return value == null ? DEFAULT_DEPTH : Arguments.integer(new Object[] { value }, 0, call, "depth", 0, MAX_DEPTH);
    }

    private int limit(Object options, String call) throws ReflectiveOperationException {
        Object value = options == null ? null : lua.get(options, "limit");
        return value == null ? Integer.MAX_VALUE : Arguments.integer(new Object[] { value }, 0, call, "limit", 0, Integer.MAX_VALUE);
    }

    private void checkOptions(Object options, String call) {
        if (options != null && !lua.isTable(options)) throw new IllegalArgumentException(call + ": options must be a table (or nil)");
    }

    /** A Lua list (keys 1..n) of the values, without boxing the keys. */
    private Object list(List<Object> values) throws Throwable {
        Object result = lua.table();
        for (int index = 0, size = values.size(); index < size; index++) Calls.RAWSET_AT.invokeExact(result, index + 1, values.get(index));
        return result;
    }

    /** Walks what the source holds. */
    private void walk(Object source, int depth, String call, Sink sink) throws Throwable {
        if (Calls.CONTAINER.isInstance(source)) {
            inside(source, depth, sink);
        } else if (Calls.BAG.isInstance(source)) {
            Object held = (Object)Calls.BAG_INVENTORY.invokeExact(source);
            if (held != null) inside(held, depth, sink);
        } else if (Calls.ITEM.isInstance(source)) {
            // An item that is no bag holds nothing.
        } else if (Calls.CHARACTER.isInstance(source)) {
            Object held = (Object)Calls.INVENTORY.invokeExact(source);
            if (held != null) inside(held, depth, sink);
        } else if (Calls.OBJECT.isInstance(source)) {
            for (int index = 0, count = (int)Calls.CONTAINER_COUNT.invokeExact(source); index < count; index++) {
                Object held = (Object)Calls.CONTAINER_AT.invokeExact(source, index);
                if (held != null && !inside(held, depth, sink)) return;
            }
        } else {
            throw new IllegalArgumentException(call + ": " + SOURCE);
        }
    }

    /** The container's own items, then each bag's, as deep as {@code depth}; false when the sink had enough. */
    private boolean inside(Object container, int depth, Sink sink) throws Throwable {
        List<?> items = (List<?>)Calls.ITEMS.invokeExact(container);
        if (items == null) return true;
        for (int index = 0; index < items.size(); index++) {
            Object item = items.get(index);
            if (item != null && !sink.item(item, container)) return false;
        }
        if (depth == 0) return true;
        for (int index = 0; index < items.size(); index++) {
            Object item = items.get(index);
            if (!Calls.BAG.isInstance(item)) continue;
            Object held = (Object)Calls.BAG_INVENTORY.invokeExact(item);
            // A bag that holds itself is looked into once, not to the depth.
            if (held != null && held != container && !inside(held, depth - 1, sink)) return false;
        }
        return true;
    }
}
