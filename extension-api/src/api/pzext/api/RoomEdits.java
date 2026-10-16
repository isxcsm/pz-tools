package pzext.api;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.*;
import java.nio.ByteBuffer;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.*;
import pzext.api.Buildings.Building;
import pzext.api.Buildings.Rect;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.buildings.setRooms}: new rooms for a map building over the squares it has (docs/design.md, "Rooms
 * set"). The game has no call for it but its building editor (a debug tool, {@code zombie.buildingRooms}): the rooms
 * are made as the editor makes them, which takes the building out of the map and puts the new one in, rooms, lights
 * and squares worked out anew; and they are written to the save in the format of its {@code player_buildings.bin}, which
 * the game reads back as the world loads, before the map's own data on rooms (map_meta.bin), whose flags it then keeps. What the
 * editor leaves behind is mended here: the building's own state (its key, its alarm, what was seen), the flags of each
 * room (taken from the old room it shares most squares with), the map's objects in the rooms, and the rooms light
 * switches light. The file is the API's own ({@link Hooks#ROOMS_FILE}, in the format of player_buildings.bin), which the
 * game reads in place of its own through a hook: without the API the save loads with the map's rooms as they were.
 */
final class RoomEdits {
    /** The hook that makes the editor's buildings map buildings (see Hooks): without it the game drops them. */
    static final String HOOK = "BREBuilding.<init>";
    /** The hook that has the game read the API's file (see Hooks): without it rooms set would not come back. */
    static final String LOAD_HOOK = "PlayerRoomsFile.load";
    static final String FILE = Hooks.ROOMS_FILE;
    private static final String CALL = "PZExtAPI.buildings.setRooms";
    /** The most rectangles one call takes: a bound on its work, not a rule of play. */
    static final int MAX_RECTS = 4096;
    private static final byte[] MAGIC = { 'P', 'R', 'B', 'G' };
    private static final int FORMAT = 1;
    // The building's own state, which the editor's new building would not have (its key is the door keys' number).
    private static final String[] KEPT = { "seen", "hasBeenVisited", "stash", "lootRespawnHour", "alarmed", "alarmDecay", "zone",
        "food", "items", "itemTypes", "table", "keySpawned", "keyId", "collapseRectX", "collapseRectY", "collapseRectX2", "collapseRectY2" };

    private final Kahlua lua;
    private final Game game;
    private final Buildings buildings;
    private final Method instance, copyExisting, apply, copyFrom, rectsOf, emptyOutside, bounds, removedOf, buildingAt, roomIdOf;
    private final Method createRoom, removeRoom;
    private final Method core, noSave, saveFile, writeString, userDefinedOf;
    private final Field editing, preEdit, luaEditor, breDef, breRooms, breRoom, roomName, roomLevel, roomObjects;
    private final Field metaX, metaY, metaDef, removedX, removedY, removedZ, gridBuildings, userDefined, defRooms, defOutside;
    private final Constructor<?> newRect;
    private final Object fileSystem;
    private final List<Field> kept = new ArrayList<>();

    RoomEdits(Kahlua lua, Game game, Buildings buildings, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.buildings = buildings;
        Class<?> editor = Game.type(loader, "zombie.buildingRooms.BuildingRoomsEditor");
        Class<?> bre = Game.type(loader, "zombie.buildingRooms.BREBuilding"), breRoomType = Game.type(loader, "zombie.buildingRooms.BRERoom");
        Class<?> def = Game.type(loader, "zombie.iso.BuildingDef"), room = Game.type(loader, "zombie.iso.RoomDef");
        Class<?> rect = Game.type(loader, "zombie.iso.RoomDef$RoomRect"), meta = Game.type(loader, "zombie.iso.MetaObject");
        Class<?> grid = Game.type(loader, "zombie.iso.IsoMetaGrid"), removed = Game.type(loader, "zombie.buildingRooms.RemovedBuilding");
        instance = editor.getMethod("getInstance");
        copyExisting = editor.getMethod("copyExistingBuilding", def);
        apply = editor.getMethod("applyChanges", boolean.class);
        editing = Game.accessible(editor.getDeclaredField("buildings"));
        preEdit = Game.accessible(editor.getDeclaredField("preEditBuildings"));
        luaEditor = Game.accessible(editor.getDeclaredField("luaEditor"));
        breDef = Game.accessible(bre.getDeclaredField("buildingDef"));
        breRooms = Game.accessible(bre.getDeclaredField("rooms"));
        breRoom = Game.accessible(breRoomType.getDeclaredField("roomDef"));
        createRoom = bre.getMethod("createRoom", int.class);
        removeRoom = bre.getMethod("removeRoom", breRoomType);
        copyFrom = room.getMethod("copyFrom", room);
        rectsOf = room.getMethod("getRects");
        emptyOutside = room.getMethod("isEmptyOutside");
        bounds = room.getMethod("CalculateBounds");
        roomIdOf = room.getMethod("getID");
        roomName = room.getField("name");
        roomLevel = room.getField("level");
        roomObjects = room.getField("objects");
        newRect = rect.getConstructor(int.class, int.class, int.class, int.class);
        metaX = Game.accessible(meta.getDeclaredField("x"));
        metaY = Game.accessible(meta.getDeclaredField("y"));
        metaDef = Game.accessible(meta.getDeclaredField("def"));
        removedOf = grid.getMethod("getRemovedBuildings");
        buildingAt = grid.getMethod("getBuildingAt", int.class, int.class, int.class);
        gridBuildings = grid.getField("buildings");
        removedX = removed.getField("x"); removedY = removed.getField("y"); removedZ = removed.getField("z");
        userDefined = Game.accessible(def.getDeclaredField("userDefined"));
        userDefinedOf = def.getMethod("isUserDefined");
        defRooms = def.getField("rooms");
        defOutside = def.getField("emptyoutside");
        for (String name : KEPT) {
            // A field this game does not have is left: the rest are still kept.
            try { kept.add(Game.accessible(def.getDeclaredField(name))); }
            catch (NoSuchFieldException missing) { }
        }
        Class<?> coreType = Game.type(loader, "zombie.core.Core");
        core = coreType.getMethod("getInstance");
        noSave = coreType.getMethod("isNoSave");
        Class<?> files = Game.type(loader, "zombie.ZomboidFileSystem");
        fileSystem = files.getField("instance").get(null);
        saveFile = files.getMethod("getFileInCurrentSave", String.class);
        writeString = Game.type(loader, "zombie.GameWindow").getMethod("WriteString", ByteBuffer.class, String.class);
    }

    /** A room as a mod asks for it: its level, its name (null: the old room's), and its squares as rectangles. */
    record Wanted(int level, String name, List<Rect> rects) { }

    /**
     * {@code setRooms(key, rooms)}: true when the building has the rooms (it had them already, or was given them); or nil
     * and why not. A second result says why rooms set were not written to the save (they last until the world is left).
     */
    Object[] set(String key, Object list) throws ReflectiveOperationException {
        List<Wanted> wanted = parse(list);
        Building found = buildings.resolve(key);
        if (found == null) return refused("no building has the key");
        if ((boolean)userDefinedOf.invoke(found.def())) return refused("a building players built: the game makes its rooms from its walls");
        for (String name : new String[] { HOOK, LOAD_HOOK }) {
            String hook;
            try { hook = Hooks.hookStatus().getOrDefault(name, Hooks.NOT_LOADED); }
            catch (LinkageError olderBootstrap) { hook = "this game's bootstrap is older; restart the game"; }
            if (!Hooks.APPLIED.equals(hook)) return refused("the hook " + name + " is not in (" + hook + ")");
        }
        // The building's squares, each with its room; and the rooms asked for over them, which must be the same squares.
        var old = new HashMap<Long, Object>();
        var size = new IdentityHashMap<Object, Integer>();
        for (Object room : found.rooms()) {
            int z = buildings.level(room);
            for (Rect rect : buildings.rects(room))
                for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                    for (int x = rect.x(); x < rect.x() + rect.w(); x++)
                        if (old.put(square(x, y, z), room) == null) size.merge(room, 1, Integer::sum);
        }
        var now = new HashMap<Long, Integer>();
        for (int index = 0; index < wanted.size(); index++) {
            Wanted room = wanted.get(index);
            for (Rect rect : room.rects())
                for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                    for (int x = rect.x(); x < rect.x() + rect.w(); x++) {
                        if (now.put(square(x, y, room.level()), index) != null)
                            throw new IllegalArgumentException(CALL + ": rooms overlap at " + x + "," + y + "," + room.level());
                        if (now.size() > old.size()) return refused("the rooms are not the building's squares");
                    }
        }
        if (!now.keySet().equals(old.keySet())) return refused("the rooms are not the building's squares");
        // Each new room is the old room it shares most squares with: its flags, and its name unless one is given.
        Object[] from = new Object[wanted.size()];
        int[] shared = new int[wanted.size()], squares = new int[wanted.size()];
        var overlaps = new ArrayList<IdentityHashMap<Object, Integer>>();
        for (int index = 0; index < wanted.size(); index++) overlaps.add(new IdentityHashMap<>());
        for (var entry : now.entrySet()) {
            squares[entry.getValue()]++;
            overlaps.get(entry.getValue()).merge(old.get(entry.getKey()), 1, Integer::sum);
        }
        String[] names = new String[wanted.size()];
        for (int index = 0; index < wanted.size(); index++) {
            for (Object room : found.rooms()) {
                int count = overlaps.get(index).getOrDefault(room, 0);
                if (count > shared[index]) { shared[index] = count; from[index] = room; }
            }
            names[index] = wanted.get(index).name() != null ? wanted.get(index).name() : (String)roomName.get(from[index]);
        }
        boolean same = wanted.size() == found.rooms().size();
        for (int index = 0; same && index < wanted.size(); index++)
            same = shared[index] == squares[index] && shared[index] == size.get(from[index]) && names[index].equals(roomName.get(from[index]));
        if (same) return new Object[] { true };

        Object grid = game.metaGrid();
        @SuppressWarnings("unchecked") List<Object> removed = (List<Object>)removedOf.invoke(grid);
        // A building the editor made already: the map's own was taken out (that entry is in the list), and the editor
        // would add an entry for this one too, which only grows the file.
        boolean remade = false;
        for (Object entry : removed)
            remade |= old.containsKey(square(removedX.getInt(entry), removedY.getInt(entry), removedZ.getInt(entry)));
        int removedBefore = removed.size();
        var oldById = new HashMap<Long, Object>();
        for (Object room : found.rooms()) oldById.put((long)roomIdOf.invoke(room), room);

        Object editor = instance.invoke(null);
        @SuppressWarnings("unchecked") List<Object> editorBuildings = (List<Object>)editing.get(editor);
        @SuppressWarnings("unchecked") List<Object> editorBefore = (List<Object>)preEdit.get(editor);
        var keptBuildings = new ArrayList<>(editorBuildings);
        var keptBefore = new ArrayList<>(editorBefore);
        Object keptLua = luaEditor.get(editor);
        Object made;
        Object[] rooms = new Object[wanted.size()];
        try {
            // The editor as its debug window leaves it, for this building alone, and with no window to tell.
            editorBuildings.clear();
            editorBefore.clear();
            luaEditor.set(editor, null);
            Object bre = copyExisting.invoke(editor, found.def());
            editorBefore.add(found.def());
            // The editor's own calls: each keeps its building's rooms (BuildingDef.rooms) with the editor's.
            for (Object editorRoom : new ArrayList<>((List<?>)breRooms.get(bre)))
                if (!(boolean)emptyOutside.invoke(breRoom.get(editorRoom))) removeRoom.invoke(bre, editorRoom);
            for (int index = 0; index < wanted.size(); index++) {
                Object editorRoom = createRoom.invoke(bre, wanted.get(index).level());
                Object room = breRoom.get(editorRoom);
                copyFrom.invoke(room, from[index]);
                @SuppressWarnings("unchecked") List<Object> rects = (List<Object>)rectsOf.invoke(room);
                rects.clear();
                for (Rect rect : wanted.get(index).rects()) rects.add(newRect.newInstance(rect.x(), rect.y(), rect.w(), rect.h()));
                roomName.set(room, names[index]);
                roomLevel.setInt(room, wanted.get(index).level());
                bounds.invoke(room);
                rooms[index] = room;
            }
            made = breDef.get(bre);
            apply.invoke(editor, false);
        } finally {
            editorBuildings.clear();
            editorBuildings.addAll(keptBuildings);
            editorBefore.clear();
            editorBefore.addAll(keptBefore);
            luaEditor.set(editor, keptLua);
        }
        if (!((List<?>)gridBuildings.get(grid)).contains(made)) {
            buildings.changed();
            return refused("the game did not take the rooms");
        }
        if (remade) while (removed.size() > removedBefore) removed.remove(removed.size() - 1);
        userDefined.setBoolean(made, false);
        for (Field field : kept) field.set(made, field.get(found.def()));
        // The map's objects of the old rooms (where zombies stand as the building is first seen), each in its new room.
        for (Object room : found.rooms()) {
            int z = buildings.level(room);
            for (Object object : (List<?>)roomObjects.get(room)) {
                Integer index = now.get(square(metaX.getInt(object), metaY.getInt(object), z));
                if (index == null) continue;
                metaDef.set(object, rooms[index]);
                @SuppressWarnings("unchecked") List<Object> objects = (List<Object>)roomObjects.get(rooms[index]);
                objects.add(object);
            }
        }
        buildings.changed();
        switches(found, oldById, from, rooms, made);
        return new Object[] { true, save(grid) };
    }

    /**
     * Light switches keep the room they light by its number, which the rooms set changed: each that lit a room of the
     * building lights the new room on its square, else the new room its old one became most of.
     */
    private void switches(Building found, Map<Long, Object> oldById, Object[] from, Object[] rooms, Object made)
            throws ReflectiveOperationException {
        Object cells = game.cell();
        if (cells == null) return;
        for (int z = found.minLevel(); z <= found.maxLevel(); z++)
            for (int y = found.minY() - 1; y <= found.maxY() + 1; y++)
                for (int x = found.minX() - 1; x <= found.maxX() + 1; x++) {
                    Object loaded = game.square(cells, x, y, z);
                    if (loaded == null) continue;
                    for (Object object : game.objectsOn(loaded)) {
                        if (!game.lightSwitch.isInstance(object)) continue;
                        Object lit = oldById.get(game.switchRoom(object));
                        if (lit == null) continue;
                        Object room = buildings.roomOf(x, y, z);
                        if (room == null || buildings.defOf(room) != made) {
                            room = null;
                            for (int index = 0; index < from.length && room == null; index++) if (from[index] == lit) room = rooms[index];
                        }
                        if (room != null) game.setSwitchRoom(object, (long)roomIdOf.invoke(room));
                    }
                }
    }

    /**
     * Writes the rooms set to the save's API file, as the game reads player_buildings.bin: the map buildings taken out (a square
     * of each), then the buildings put in their place (each found at such a square now). Null when written or the game
     * saves nothing; else why not.
     */
    private String save(Object grid) {
        try {
            if ((boolean)noSave.invoke(core.invoke(null))) return null;
            List<?> removed = (List<?>)removedOf.invoke(grid);
            var defs = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
            var order = new ArrayList<Object>();
            int bytes = MAGIC.length + 4 + 2 + removed.size() * 12 + 2;
            for (Object entry : removed) {
                Object def = buildingAt.invoke(grid, removedX.getInt(entry), removedY.getInt(entry), removedZ.getInt(entry));
                if (def == null || !defs.add(def)) continue;
                order.add(def);
                bytes += 2;
                for (Object room : rooms(def)) bytes += 1 + 2 + 4 * ((String)roomName.get(room)).length() + 2 + 12 * buildings.rects(room).size();
            }
            if (removed.size() > Short.MAX_VALUE || order.size() > Short.MAX_VALUE) return "too many buildings for the game's file";
            ByteBuffer buffer = ByteBuffer.allocate(bytes);
            buffer.put(MAGIC).putInt(FORMAT).putShort((short)removed.size());
            for (Object entry : removed) buffer.putInt(removedX.getInt(entry)).putInt(removedY.getInt(entry)).putInt(removedZ.getInt(entry));
            buffer.putShort((short)order.size());
            for (Object def : order) {
                List<Object> rooms = rooms(def);
                buffer.putShort((short)rooms.size());
                for (Object room : rooms) {
                    buffer.put((byte)buildings.level(room));
                    writeString.invoke(null, buffer, roomName.get(room));
                    List<Rect> rects = buildings.rects(room);
                    buffer.putShort((short)rects.size());
                    for (Rect rect : rects) buffer.putInt(rect.x()).putInt(rect.y()).putShort((short)rect.w()).putShort((short)rect.h());
                }
            }
            Path file = ((File)saveFile.invoke(fileSystem, FILE)).toPath();
            Path written = file.resolveSibling(FILE + ".new");
            Files.write(written, Arrays.copyOf(buffer.array(), buffer.position()));
            try { Files.move(written, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); }
            catch (AtomicMoveNotSupportedException plain) { Files.move(written, file, StandardCopyOption.REPLACE_EXISTING); }
            return null;
        } catch (ReflectiveOperationException | IOException | RuntimeException failure) {
            return "not written to the save: " + failure;
        }
    }

    /** A building's rooms as the file has them: its rooms, then its outside squares (the game tells them apart by name). */
    private List<Object> rooms(Object def) throws ReflectiveOperationException {
        var result = new ArrayList<Object>((List<?>)defRooms.get(def));
        result.addAll((List<?>)defOutside.get(def));
        return result;
    }

    private List<Wanted> parse(Object list) throws ReflectiveOperationException {
        if (!lua.isTable(list)) throw new IllegalArgumentException(CALL + ": rooms must be a list of rooms");
        var result = new ArrayList<Wanted>();
        int total = 0;
        try {
            int count = lua.length(list);
            if (count == 0) throw new IllegalArgumentException(CALL + ": rooms must not be empty");
            for (int index = 1; index <= count; index++) {
                Object room = lua.at(list, index);
                String at = CALL + ": room " + index;
                if (!lua.isTable(room)) throw new IllegalArgumentException(at + " must be a table");
                int level = whole(lua.get(room, "level"), at + ": level", -32, 31);
                Object name = lua.get(room, "name");
                if (name != null && (!(name instanceof String text) || text.isEmpty() || text.length() > 64 || text.equals("emptyoutside")))
                    throw new IllegalArgumentException(at + ": name must be nil or 1 to 64 characters, not \"emptyoutside\"");
                Object rects = lua.get(room, "rects");
                if (!lua.isTable(rects) || lua.length(rects) == 0) throw new IllegalArgumentException(at + ": rects must be a list of rectangles");
                var rectangles = new ArrayList<Rect>();
                for (int each = 1; each <= lua.length(rects); each++) {
                    if (++total > MAX_RECTS) throw new IllegalArgumentException(CALL + ": more than " + MAX_RECTS + " rectangles");
                    Object rect = lua.at(rects, each);
                    String of = at + ": rectangle " + each;
                    if (!lua.isTable(rect)) throw new IllegalArgumentException(of + " must be a table");
                    rectangles.add(new Rect(whole(lua.get(rect, "x"), of + ": x", Integer.MIN_VALUE / 2, Integer.MAX_VALUE / 2),
                        whole(lua.get(rect, "y"), of + ": y", Integer.MIN_VALUE / 2, Integer.MAX_VALUE / 2),
                        whole(lua.get(rect, "w"), of + ": w", 1, Short.MAX_VALUE), whole(lua.get(rect, "h"), of + ": h", 1, Short.MAX_VALUE)));
                }
                result.add(new Wanted(level, (String)name, List.copyOf(rectangles)));
            }
        } catch (RuntimeException | Error thrown) {
            throw thrown;
        } catch (Throwable failure) {
            throw Game.thrown(failure);
        }
        return result;
    }

    private static int whole(Object value, String name, int min, int max) {
        if (!(value instanceof Number number) || number.doubleValue() != Math.rint(number.doubleValue())
                || number.doubleValue() < min || number.doubleValue() > max)
            throw new IllegalArgumentException(name + " must be a whole number from " + min + " to " + max);
        return (int)number.doubleValue();
    }

    private static long square(int x, int y, int z) {
        return (z & 0xFFFFL) << 48 | (y & 0xFFFFFFL) << 24 | x & 0xFFFFFFL;
    }

    private static Object[] refused(String why) { return new Object[] { null, why }; }
}
