// STUB: replaced by perf/squares and perf/items at merge
package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;

/** An item match (docs/design.md, "Items"). The stub reads {@code type} only (a list of full types). */
final class ItemMatch {
    private final String[] types;
    private final MethodHandle fullType;

    private ItemMatch(String[] types, MethodHandle fullType) { this.types = types; this.fullType = fullType; }

    static ItemMatch read(Kahlua lua, Game game, Object table, String call) throws ReflectiveOperationException {
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": an item match must be a table");
        var types = new ArrayList<String>();
        Object list = lua.get(table, "type");
        if (list != null) {
            if (!lua.isTable(list)) throw new IllegalArgumentException(call + ": type must be a list");
            for (int at = 1; lua.get(list, (double)at) instanceof String text; at++) types.add(text);
        }
        Class<?> item = Game.type(game.objectType.getClassLoader(), "zombie.inventory.InventoryItem");
        return new ItemMatch(types.isEmpty() ? null : types.toArray(new String[0]),
            Game.exact(item.getMethod("getFullType"), MethodType.methodType(String.class, Object.class)));
    }

    boolean test(Object item) throws Throwable {
        if (types == null) return true;
        String type = (String)fullType.invokeExact(item);
        for (String wanted : types) if (wanted.equals(type)) return true;
        return false;
    }
}
