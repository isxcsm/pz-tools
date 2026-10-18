package pzext.api;

import java.lang.reflect.Method;

/**
 * A room as a mod names it in a query: the game's {@code IsoRoom}, its {@code RoomDef}, or its id as {@code buildings} gives it (a
 * string of the long id). Read into the {@code RoomDef}, which the meta grid keeps for loaded and unloaded squares alike.
 */
final class RoomRefs {
    private final Game game;
    private final Class<?> def, room;
    private final Method roomDef, byId;

    RoomRefs(Game game, ClassLoader loader) throws ReflectiveOperationException {
        this.game = game;
        def = Game.type(loader, "zombie.iso.RoomDef");
        room = Game.type(loader, "zombie.iso.areas.IsoRoom");
        roomDef = room.getMethod("getRoomDef");
        byId = Game.type(loader, "zombie.iso.IsoMetaGrid").getMethod("getRoomDefByID", long.class);
    }

    /** Whether the value is something that names a room. */
    boolean isRoom(Object value) {
        return def.isInstance(value) || room.isInstance(value) || value instanceof String text && isId(text);
    }

    private static boolean isId(String text) {
        if (text.isEmpty() || text.length() > 19) return false;
        for (int at = 0; at < text.length(); at++) {
            char c = text.charAt(at);
            if (c < '0' || c > '9' && !(at == 0 && c == '-' && text.length() > 1)) return false;
        }
        return true;
    }

    /** The room's definition, or null when the value names no room the map has now. */
    Object resolve(Object value) throws ReflectiveOperationException {
        if (def.isInstance(value)) return value;
        if (room.isInstance(value)) return roomDef.invoke(value);
        if (!(value instanceof String text) || !isId(text)) return null;
        Object grid = game.metaGrid();
        if (grid == null) return null;
        try { return byId.invoke(grid, Long.parseLong(text)); }
        catch (NumberFormatException tooLarge) { return null; }
    }
}
