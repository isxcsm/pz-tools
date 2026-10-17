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
import java.util.regex.Pattern;
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
 *
 * <p>The file is written as the world saves (the game writes map_meta.bin, whose entries are for the rooms as they are, in the same
 * call), so the two never disagree. map_meta.bin holds each room's flags under the room's number, which comes from its first
 * rectangle: the rooms set have numbers the map's own rooms have no entries under, and without the API the map's rooms would find
 * none (their zombies would spawn again). So each cell's entries are followed by entries for the map's own rooms that were
 * replaced, with the flags of the new room over most of each; the map's rooms are kept at the end of the file (after what the game
 * reads), for the saves that follow a load. As the world loads with the API, the game's complaints of those entries are left out.
 */
final class RoomEdits implements Hooks.Rooms {
    /** The hook that makes the editor's buildings map buildings (see Hooks): without it the game drops them. */
    static final String HOOK = "BREBuilding.<init>";
    /** The hook that has the game read the API's file (see Hooks): without it rooms set would not come back. */
    static final String LOAD_HOOK = "PlayerRoomsFile.load";
    /** The hook that has the game ask for the file at the world's save (see Hooks): without it rooms set would not be kept. */
    static final String SAVE_HOOK = "IsoMetaGrid.savePart:saving";
    /** The two hooks that give map_meta.bin its entries for the map's own rooms: one without the other would break the file. */
    static final String COUNT_HOOK = "IsoMetaGrid.savePart:rooms", ENTRIES_HOOK = "IsoMetaGrid.savePart:entries";
    static final String FILE = Hooks.ROOMS_FILE;
    private static final String CALL = "PZExtAPI.buildings.setRooms";
    /** The most rectangles one call takes: a bound on its work, not a rule of play. */
    static final int MAX_RECTS = 4096;
    private static final byte[] MAGIC = { 'P', 'R', 'B', 'G' };
    private static final int FORMAT = 1;
    // What follows the file the game reads: the block of the map's own rooms, then its size, then this mark (the end of the file
    // says whether there is one).
    private static final byte[] KEPT_MARK = { 'P', 'X', 'O', 'R' };
    private static final Pattern COMPLAINT = Pattern.compile("invalid room metaID #(-?\\d+) in cell (-?\\d+),(-?\\d+) while reading map_meta\\.bin");
    // The most squares of a replaced room looked at to say which new room holds most of it.
    private static final int MOST_SQUARES = 4096;
    // The building's own state, which the editor's new building would not have (its key is the door keys' number).
    private static final String[] KEPT = { "seen", "hasBeenVisited", "stash", "lootRespawnHour", "alarmed", "alarmDecay", "zone",
        "food", "items", "itemTypes", "table", "keySpawned", "keyId", "collapseRectX", "collapseRectY", "collapseRectX2", "collapseRectY2" };

    private final Kahlua lua;
    private final Game game;
    private final Buildings buildings;
    private final Method instance, copyExisting, apply, copyFrom, rectsOf, emptyOutside, bounds, removedOf, buildingAt, roomIdOf;
    private final Method createRoom, removeRoom;
    private final Method core, noSave, saveFile, writeString, userDefinedOf;
    private final Method cellX, cellY, roofFixed;
    private final Field cellRooms, roomMetaId, roomExplored, roomLights, roomSpawned;
    private final Method containsMeta;
    private final Field editing, preEdit, luaEditor, breDef, breRooms, breRoom, roomName, roomLevel, roomObjects;
    private final Field metaX, metaY, metaDef, removedX, removedY, removedZ, gridBuildings, userDefined, defRooms, defOutside;
    private final Constructor<?> newRect;
    private final Object fileSystem;
    private final List<Field> kept = new ArrayList<>();

    /** A room of the map that a building lost to rooms set: its number in its cell's map_meta.bin, and where it was. */
    private record Original(int cellX, int cellY, long metaId, int level, List<Rect> rects) { }

    // While rooms are set: the building's part of the editor's work over the whole map (Hooks.Rooms): its box and its outside
    // squares', with a square around it, on its levels and one above and below: { minX, minY, maxX, maxY, minZ, maxZ }. Null
    // between sets: the editor does it all, as the game's.
    private volatile int[] updating;
    // The editor's numbering of one cell's buildings and rooms, and a cell of the map: null in a game without them (the editor
    // then numbers every cell, as the game's).
    private final Method renumber, cellData;
    // The chunks the lighting works out again after buildings changed (Hooks.Rooms.relights): those of the buildings given
    // rooms since, with a chunk around them, as { minX, minY, maxX, maxY } in chunks; all of them (whole) once the game changed
    // buildings of its own. Cleared as the lighting has gone through them. A chunk's place, or null in a game without it.
    private final List<int[]> relighting = new ArrayList<>();
    private boolean relightAll, relightAsked;
    private final Field chunkX, chunkY;

    // The map's own rooms that rooms set replaced, by cell; of the meta grid `world`. Read from the file as a world is first asked about.
    private final Map<Long, List<Original>> replacedRooms = new HashMap<>();
    private Object world;
    // Whether the API's file is the world's (it was there as the world loaded, or rooms were set in it): it is written as the world saves.
    private boolean active;
    // The file as last read or written, so that a save changes it only when the rooms did.
    private byte[] written;
    // The extra entries counted for the cell the save is at, for the entries that follow.
    private Object pendingCell;
    private long[] pendingIds;
    private short[] pendingFlags;
    private Boolean extrasIn;

    RoomEdits(Kahlua lua, Game game, Buildings buildings, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.buildings = buildings;
        Class<?> editor = Game.type(loader, "zombie.buildingRooms.BuildingRoomsEditor");
        Class<?> bre = Game.type(loader, "zombie.buildingRooms.BREBuilding"), breRoomType = Game.type(loader, "zombie.buildingRooms.BRERoom");
        Class<?> def = Game.type(loader, "zombie.iso.BuildingDef"), room = Game.type(loader, "zombie.iso.RoomDef");
        Class<?> rect = Game.type(loader, "zombie.iso.RoomDef$RoomRect"), meta = Game.type(loader, "zombie.iso.MetaObject");
        Class<?> grid = Game.type(loader, "zombie.iso.IsoMetaGrid"), removed = Game.type(loader, "zombie.buildingRooms.RemovedBuilding");
        Class<?> cell = Game.type(loader, "zombie.iso.IsoMetaCell");
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
        cellX = cell.getMethod("getX");
        cellY = cell.getMethod("getY");
        cellRooms = cell.getField("roomByMetaId");
        containsMeta = cellRooms.getType().getMethod("contains", long.class);
        roomMetaId = Game.accessible(room.getDeclaredField("metaId"));
        roomExplored = Game.accessible(room.getDeclaredField("explored"));
        roomLights = Game.accessible(room.getDeclaredField("lightsActive"));
        roomSpawned = Game.accessible(room.getDeclaredField("doneSpawn"));
        roofFixed = room.getMethod("isRoofFixed");
        Method one = null, data = null;
        try {
            one = Game.accessible(editor.getDeclaredMethod("recalculateBuildingAndRoomIDs", cell));
            data = grid.getMethod("getCellData", int.class, int.class);
        } catch (ReflectiveOperationException | RuntimeException missing) { one = null; }
        renumber = one;
        cellData = data;
        Field x = null, y = null;
        try {
            Class<?> chunk = Game.type(loader, "zombie.iso.IsoChunk");
            x = chunk.getField("wx");
            y = chunk.getField("wy");
        } catch (ReflectiveOperationException | RuntimeException missing) { x = null; }
        chunkX = x;
        chunkY = y;
        // The game asks this API at the world's save and load.
        try { Hooks.setRooms(this); }
        catch (LinkageError olderBootstrap) { }
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
        for (String name : new String[] { HOOK, LOAD_HOOK, SAVE_HOOK }) {
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
        // The map's own rooms the building loses (those of a building the editor made already are not the map's).
        List<Original> lost = remade ? List.of() : originalsOf(found);
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
        // The editor's buildings are map buildings while it makes this one (see Hooks.playersBuilt).
        updating = box(found);
        Hooks.roomsScope(true);
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
            Hooks.roomsScope(false);
            updating = null;
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
        // The file is written as the world saves; what it cannot hold is said now.
        String why = null;
        synchronized (this) {
            ensure(grid);
            for (Original original : lost) replacedRooms.computeIfAbsent(key(original.cellX(), original.cellY()), cell -> new ArrayList<>()).add(original);
            active = true;
            try { if (!(boolean)noSave.invoke(core.invoke(null))) encode(grid); }
            catch (IllegalStateException unfit) { why = unfit.getMessage(); }
        }
        return new Object[] { true, why };
    }

    /** The building's part of the editor's work (see updating). */
    private int[] box(Building found) throws ReflectiveOperationException {
        int[] box = { found.minX() - 1, found.minY() - 1, found.maxX() + 1, found.maxY() + 1, found.minLevel() - 1, found.maxLevel() + 1 };
        for (Object room : (List<?>)defOutside.get(found.def()))
            for (Rect rect : buildings.rects(room)) {
                box[0] = Math.min(box[0], rect.x() - 1);
                box[1] = Math.min(box[1], rect.y() - 1);
                box[2] = Math.max(box[2], rect.x() + rect.w());
                box[3] = Math.max(box[3], rect.y() + rect.h());
            }
        return box;
    }

    @Override public boolean squares(java.util.function.Consumer<Object> work) throws Throwable {
        int[] box = updating;
        if (box == null) return false;
        Object cells = game.cell();
        if (cells == null) return false;
        for (int z = box[4]; z <= box[5]; z++)
            for (int y = box[1]; y <= box[3]; y++)
                for (int x = box[0]; x <= box[2]; x++) {
                    Object square = game.square(cells, x, y, z);
                    if (square != null) work.accept(square);
                }
        return true;
    }

    @Override public boolean renumbered(Object editor) throws Throwable {
        int[] box = updating;
        Object grid = game.metaGrid();
        if (box == null || renumber == null || grid == null) return false;
        for (int x = Math.floorDiv(box[0], CELL); x <= Math.floorDiv(box[2], CELL); x++)
            for (int y = Math.floorDiv(box[1], CELL); y <= Math.floorDiv(box[3], CELL); y++) {
                Object cell = cellData.invoke(grid, x, y);
                if (cell != null) renumber.invoke(editor, cell);
            }
        return true;
    }

    @Override public boolean checks() { return updating == null; }

    @Override public synchronized void buildingsChanged() {
        int[] box = updating;
        if (box == null || chunkX == null) { relightAll = true; return; }
        int size = game.chunkSize;
        relighting.add(new int[] { Math.floorDiv(box[0], size) - 1, Math.floorDiv(box[1], size) - 1,
            Math.floorDiv(box[2], size) + 1, Math.floorDiv(box[3], size) + 1 });
    }

    @Override public synchronized boolean relights(Object chunk) throws Throwable {
        relightAsked = true;
        if (relightAll || relighting.isEmpty()) return true;
        int x = chunkX.getInt(chunk), y = chunkY.getInt(chunk);
        for (int[] box : relighting) if (x >= box[0] && y >= box[1] && x <= box[2] && y <= box[3]) return true;
        return false;
    }

    @Override public synchronized void relit() {
        if (!relightAsked) return;
        relightAsked = false;
        relightAll = false;
        relighting.clear();
    }

    /** The building's rooms as the map's own, to be kept for map_meta.bin (see the class). */
    private List<Original> originalsOf(Building found) throws ReflectiveOperationException {
        var result = new ArrayList<Original>();
        int x = Math.floorDiv(found.minX(), CELL), y = Math.floorDiv(found.minY(), CELL);
        for (Object room : found.rooms()) result.add(new Original(x, y, roomMetaId.getLong(room), buildings.level(room), buildings.rects(room)));
        return result;
    }

    private static final int CELL = 256;

    private static long key(int x, int y) { return (long)x << 32 | y & 0xFFFFFFFFL; }

    /** For tests: this is a new world (the file is read again). */
    synchronized void reset() { world = null; extrasIn = null; }

    // ---- the world's save and load (Hooks.Rooms) ----

    /** The meta grid this is about is the world's: else the map's own rooms are read from the file the world has. */
    private void ensure(Object grid) {
        if (grid == world) return;
        replacedRooms.clear();
        active = false;
        written = null;
        pendingCell = null;
        world = grid;
        try {
            File file = (File)saveFile.invoke(fileSystem, FILE);
            if (!file.isFile()) return;
            written = Files.readAllBytes(file.toPath());
            active = true;
            readKept(written);
        } catch (ReflectiveOperationException | IOException | RuntimeException unreadable) {
            replacedRooms.clear();
        }
    }

    private void readKept(byte[] bytes) {
        int end = bytes.length - 8;
        if (end < 0 || !Arrays.equals(bytes, bytes.length - 4, bytes.length, KEPT_MARK, 0, 4)) return;
        int size = ByteBuffer.wrap(bytes, end, 4).getInt();
        if (size < 2 || size > end) return;
        ByteBuffer block = ByteBuffer.wrap(bytes, end - size, size);
        for (int count = block.getShort() & 0xFFFF; count > 0; count--) {
            int x = block.getInt(), y = block.getInt(), level = block.get();
            long id = block.getLong();
            var rects = new ArrayList<Rect>();
            for (int rect = block.getShort() & 0xFFFF; rect > 0; rect--) rects.add(new Rect(block.getInt(), block.getInt(), block.getShort(), block.getShort()));
            replacedRooms.computeIfAbsent(key(x, y), cell -> new ArrayList<>()).add(new Original(x, y, id, level, List.copyOf(rects)));
        }
    }

    /** {@code IsoMetaGrid.savePart}, for the map's rooms: the file of the rooms set is written, when the world has one and it changed. */
    @Override public synchronized void saving() throws Throwable {
        Object grid = game.metaGrid();
        ensure(grid);
        if (!active || (boolean)noSave.invoke(core.invoke(null))) return;
        byte[] bytes = encode(grid);
        if (Arrays.equals(bytes, written)) return;
        write(bytes);
        written = bytes;
    }

    /** Whether the hooks that give the file's entries are both in: one alone would write a count that does not fit the entries. */
    private boolean extras() {
        if (extrasIn == null) {
            Map<String, String> status = Hooks.hookStatus();
            extrasIn = Hooks.APPLIED.equals(status.get(COUNT_HOOK)) && Hooks.APPLIED.equals(status.get(ENTRIES_HOOK));
        }
        return extrasIn;
    }

    @Override public synchronized int originals(Object cell) throws Throwable {
        pendingCell = null;
        if (!extras()) return 0;
        ensure(game.metaGrid());
        if (replacedRooms.isEmpty()) return 0;
        List<Original> here = replacedRooms.get(key((int)cellX.invoke(cell), (int)cellY.invoke(cell)));
        if (here == null) return 0;
        Object byId = cellRooms.get(cell);
        var ids = new long[here.size()];
        var flags = new short[here.size()];
        int count = 0;
        for (Original original : here) {
            // A room of the cell has the number already: its own entry stands.
            if ((boolean)containsMeta.invoke(byId, original.metaId())) continue;
            int bits = flagsOver(original);
            if (bits < 0) continue;
            ids[count] = original.metaId();
            flags[count++] = (short)bits;
        }
        if (count == 0) return 0;
        pendingCell = cell;
        pendingIds = Arrays.copyOf(ids, count);
        pendingFlags = Arrays.copyOf(flags, count);
        return count;
    }

    @Override public synchronized void entries(Object cell, ByteBuffer buffer) {
        if (pendingCell != cell) { pendingCell = null; return; }
        var block = ByteBuffer.allocate(pendingIds.length * 10).order(buffer.order());
        for (int index = 0; index < pendingIds.length; index++) block.putLong(pendingIds[index]).putShort(pendingFlags[index]);
        pendingCell = null;
        buffer.put(block.flip());
    }

    @Override public synchronized boolean replaced(Object complaint) throws Throwable {
        if (!(complaint instanceof String text)) return false;
        var match = COMPLAINT.matcher(text);
        if (!match.matches()) return false;
        ensure(game.metaGrid());
        if (replacedRooms.isEmpty()) return false;
        List<Original> here = replacedRooms.get(key(Integer.parseInt(match.group(2)), Integer.parseInt(match.group(3))));
        if (here == null) return false;
        long id = Long.parseLong(match.group(1));
        for (Original original : here) if (original.metaId() == id) return true;
        return false;
    }

    /**
     * The flags (as map_meta.bin has them) of the room that holds most of the squares of a replaced room now, or -1 when no room
     * has any (the first rooms asked, up to {@link #MOST_SQUARES} squares, on a tie the lowest number).
     */
    private int flagsOver(Original original) throws ReflectiveOperationException {
        var counts = new IdentityHashMap<Object, Integer>();
        int asked = 0;
        for (Rect rect : original.rects())
            for (int y = rect.y(); y < rect.y() + rect.h() && asked < MOST_SQUARES; y++)
                for (int x = rect.x(); x < rect.x() + rect.w() && asked++ < MOST_SQUARES; x++) {
                    Object room = buildings.roomOf(x, y, original.level());
                    if (room != null) counts.merge(room, 1, Integer::sum);
                }
        Object best = null;
        int most = 0;
        for (var entry : counts.entrySet()) {
            if (entry.getValue() < most) continue;
            if (entry.getValue() == most && best != null && buildings.roomId(entry.getKey()) > buildings.roomId(best)) continue;
            best = entry.getKey();
            most = entry.getValue();
        }
        if (best == null) return -1;
        int bits = roomExplored.getBoolean(best) ? 1 : 0;
        if (roomLights.getBoolean(best)) bits |= 2;
        if (roomSpawned.getBoolean(best)) bits |= 4;
        if ((boolean)roofFixed.invoke(best)) bits |= 8;
        return bits;
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
     * The save's API file as the game reads player_buildings.bin: the map buildings taken out (a square of each), then the buildings
     * put in their place (each found at such a square now); then, after what the game reads, the map's own rooms they replaced.
     * Throws an IllegalStateException saying why the file cannot be.
     */
    private byte[] encode(Object grid) {
        try {
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
            if (removed.size() > Short.MAX_VALUE || order.size() > Short.MAX_VALUE) throw new IllegalStateException("too many buildings for the game's file");
            var lost = new ArrayList<Original>();
            for (List<Original> cell : replacedRooms.values()) lost.addAll(cell);
            lost.sort(Comparator.comparingInt(Original::cellX).thenComparingInt(Original::cellY).thenComparingLong(Original::metaId));
            if (lost.size() > 0xFFFF) throw new IllegalStateException("too many rooms replaced for the file");
            int block = 2;
            for (Original original : lost) block += 4 + 4 + 1 + 8 + 2 + 12 * original.rects().size();
            bytes += lost.isEmpty() ? 0 : block + KEPT_MARK.length + 4;
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
            if (!lost.isEmpty()) {
                buffer.putShort((short)lost.size());
                for (Original original : lost) {
                    buffer.putInt(original.cellX()).putInt(original.cellY()).put((byte)original.level()).putLong(original.metaId());
                    buffer.putShort((short)original.rects().size());
                    for (Rect rect : original.rects()) buffer.putInt(rect.x()).putInt(rect.y()).putShort((short)rect.w()).putShort((short)rect.h());
                }
                buffer.putInt(block).put(KEPT_MARK);
            }
            return Arrays.copyOf(buffer.array(), buffer.position());
        } catch (ReflectiveOperationException | RuntimeException failure) {
            if (failure instanceof IllegalStateException unfit) throw unfit;
            throw new IllegalStateException("not written to the save: " + failure);
        }
    }

    /** The bytes to the save's API file: whole or not at all. */
    private void write(byte[] bytes) throws ReflectiveOperationException, IOException {
        Path file = ((File)saveFile.invoke(fileSystem, FILE)).toPath();
        Path temporary = file.resolveSibling(FILE + ".new");
        Files.write(temporary, bytes);
        try { Files.move(temporary, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); }
        catch (AtomicMoveNotSupportedException plain) { Files.move(temporary, file, StandardCopyOption.REPLACE_EXISTING); }
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
