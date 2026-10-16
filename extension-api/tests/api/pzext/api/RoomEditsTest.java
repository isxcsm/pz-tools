package pzext.api;

import java.io.File;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import pzext.boot.Hooks;
import se.krka.kahlua.vm.KahluaTable;
import zombie.GameWindow;
import zombie.ZomboidFileSystem;
import zombie.buildingRooms.BREBuilding;
import zombie.buildingRooms.BuildingRoomsEditor;
import zombie.buildingRooms.PlayerRoomsFile;
import zombie.core.Core;
import zombie.iso.BuildingDef;
import zombie.iso.IsoMetaCell;
import zombie.iso.IsoWorld;
import zombie.iso.MetaObject;
import zombie.iso.RoomDef;
import zombie.iso.objects.IsoLightSwitch;
import zombie.iso.sprite.IsoSprite;

/**
 * {@code buildings.setRooms}, against the synthetic game's building editor: a map building's two rooms made one and two
 * again, the building's own state, the rooms' flags, the map's objects and the light switches kept, the save's file
 * written as the game reads it (as the world saves, with the map's own rooms kept after it), and what it refuses. And the hook
 * that makes the editor's buildings map buildings while rooms are set and loaded, and what map_meta.bin gets for the map's rooms
 * that were replaced.
 *
 * <p>The synthetic game's meta grid has no {@code savePart} or {@code load(ByteBuffer)} (its file belongs to the performance
 * work): the hooks in them are told applied here and called as the game's transformed code calls them; the transformed code
 * itself is checked against the game's own classes (the hook audit).
 */
final class RoomEditsTest {
    private static final String KEY = "60,60,0";
    /** The numbers of the rooms a cell of the map holds at 60,60 and 63,60 (from their first rectangle: y << 16 | x). */
    private static final long KITCHEN = 60L << 16 | 60, LIVING = 60L << 16 | 63, SECOND = 60L << 16 | 62;
    private static final String[] SAVE_HOOKS = { RoomEdits.SAVE_HOOK, RoomEdits.COUNT_HOOK, RoomEdits.ENTRIES_HOOK };

    private RoomEditsTest() { }

    static void run(KahluaTable api) throws Exception {
        var status = status();
        var earlier = new LinkedHashMap<String, String>();
        synchronized (status) {
            for (String hook : SAVE_HOOKS) { earlier.put(hook, status.get(hook)); status.put(hook, Hooks.APPLIED); }
        }
        try { rooms(api); }
        finally {
            Hooks.roomsLoaded();
            synchronized (status) {
                for (var entry : earlier.entrySet()) {
                    if (entry.getValue() == null) status.remove(entry.getKey());
                    else status.put(entry.getKey(), entry.getValue());
                }
            }
        }
    }

    private static void rooms(KahluaTable api) throws Exception {
        check(Hooks.APPLIED.equals(Hooks.hookStatus().get(RoomEdits.HOOK)), "The editor's hook is " + Hooks.hookStatus().get(RoomEdits.HOOK));
        check(Hooks.APPLIED.equals(Hooks.hookStatus().get("BuildingRoomsEditor.load")), "The editor's load hook is " + Hooks.hookStatus().get("BuildingRoomsEditor.load"));
        // The editor's buildings are the game's unless rooms are being set or loaded.
        check(new BREBuilding().def().isUserDefined(), "The editor's buildings are not what the game makes them");
        // The game loads its rooms file's class as every world loads, before a mod could set rooms.
        new PlayerRoomsFile();
        var buildings = (KahluaTable)api.rawget("buildings");
        var grid = IsoWorld.instance.metaGrid;
        var save = Files.createTempDirectory("pzext-rooms").toFile();
        ZomboidFileSystem.save = save;
        var edits = (RoomEdits)field(Hooks.class, "rooms");
        edits.reset();
        // A map building of two rooms side by side: its key, an alarm, a switch lighting the kitchen, a zombie's place in the living room.
        var house = new BuildingDef(false);
        house.setKeyId(77);
        house.alarmed = true;
        var kitchen = room(grid, new RoomDef(501, "kitchen", 0, house), 60, 60, 3, 3);
        var living = room(grid, new RoomDef(502, "livingroom", 0, house), 63, 60, 3, 3);
        kitchen.lightsActive = true;
        living.explored = true;
        grid.buildings.add(house);
        var cell = new IsoMetaCell(0, 0);
        var place = new MetaObject(64, 61, living);
        for (int x = 59; x <= 66; x++) for (int y = 59; y <= 63; y++) IsoWorld.instance.currentCell.load(x, y, 0);
        var lit = new IsoLightSwitch(new IsoSprite("switch"));
        lit.roomId = 501;
        lit.square = IsoWorld.instance.currentCell.load(64, 62, 0);
        lit.square.objects.add(lit);
        BuildingRoomsEditor.getInstance().setLuaEditor(new Object());
        try {
            // No rooms set: the world's save and load have nothing of this API's to do.
            fill(cell, grid, KEY);
            check(Hooks.roomsOriginals(cell) == 0 && !Hooks.roomsReplaced(complaint(cell, LIVING)), "Entries were made with no rooms set");
            Hooks.roomsSaving(0);
            check(!Files.exists(save.toPath().resolve(RoomEdits.FILE)), "A file was written with no rooms set");

            // The wall between them gone: one room. It is the kitchen (the first of the two it is as much of).
            double before = (double)FormulasTest.call(buildings, "version").get(0);
            var done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 6, 3))));
            check(Boolean.TRUE.equals(done.get(0)) && done.get(1) == null, "Two rooms were not made one: " + done);
            check((double)FormulasTest.call(buildings, "version").get(0) > before, "The buildings' version did not change");
            var rooms = (KahluaTable)FormulasTest.call(buildings, "rooms", KEY).get(0);
            check(rooms.len() == 1 && ((KahluaTable)rooms.rawget(1.0)).rawget("name").equals("kitchen"), "The room was misnamed");
            RoomDef one = grid.getRoomAt(64, 61, 0);
            BuildingDef made = one.building;
            check(made != house && !made.isUserDefined() && made.getKeyId() == 77 && made.alarmed, "The building's own state was lost");
            check(one.lightsActive && grid.getRoomAt(60, 60, 0) == one, "The room's flags were not the kitchen's");
            check(place.def() == one && one.objects.contains(place), "The map's object was not moved to its room");
            check(lit.roomId == one.id, "The switch lights room " + lit.roomId + ", not " + one.id);
            check(grid.getRemovedBuildings().size() == 1, "The map building was not taken out once");
            check(BuildingRoomsEditor.windowCalls == 0 && BuildingRoomsEditor.getInstance().pending() == 0, "The editor's window was told");
            check(new BREBuilding().def().isUserDefined(), "The editor's buildings stayed map buildings after rooms were set");
            // The file is written as the world saves, not at once.
            check(!Files.exists(save.toPath().resolve(RoomEdits.FILE)), "The file was written before the world saved");
            Hooks.roomsSaving(1);
            check(!Files.exists(save.toPath().resolve(RoomEdits.FILE)), "The file was written for the part of the world's save that is not the rooms'");
            Hooks.roomsSaving(0);
            file(save, 1, 1, 1);
            check(kept(save).equals(List.of(KITCHEN, LIVING)), "The file does not keep the map's rooms: " + kept(save));
            // The API's own file, which the game reads in place of its own: none of the game's is written.
            check(!Files.exists(save.toPath().resolve("player_buildings.bin")), "The game's own rooms file was written");
            check(Hooks.APPLIED.equals(Hooks.hookStatus().get(RoomEdits.LOAD_HOOK)), "The load hook is " + Hooks.hookStatus().get(RoomEdits.LOAD_HOOK));
            // The game loads the editor's rooms: the file it reads is ours, and the building it makes from it is a map building.
            BuildingRoomsEditor.getInstance().load();
            check(PlayerRoomsFile.lastRead != null && PlayerRoomsFile.lastRead.getName().equals(RoomEdits.FILE), "The game read " + PlayerRoomsFile.lastRead);
            check(!BuildingRoomsEditor.lastLoaded.def().isUserDefined(), "The building the game made from the API's file is one players built");
            check(new BREBuilding().def().isUserDefined(), "The editor's buildings stayed map buildings after the world loaded");

            // map_meta.bin: the one room has the first number (the kitchen's), so the living room's number is the map's alone: it gets
            // an entry with the flags of the room over its squares, and the game's complaint of it is left out as the world loads.
            fill(cell, grid, KEY);
            check(Hooks.roomsOriginals(cell) == 1, "The map's living room had no entry: " + Hooks.roomsOriginals(cell));
            var entries = saved(cell);
            check(entries.equals(Map.of(KITCHEN, 2, LIVING, 2)), "map_meta.bin got " + entries);
            check(entries.size() == 2 && saved(cell).equals(entries), "The entries are not the same again");
            check(Hooks.roomsReplaced(complaint(cell, LIVING)) && Hooks.roomsReplaced(complaint(cell, KITCHEN)), "The game complains of the map's own rooms");
            check(!Hooks.roomsReplaced(complaint(cell, 12345)) && !Hooks.roomsReplaced(complaint(new IsoMetaCell(1, 0), LIVING))
                && !Hooks.roomsReplaced("invalid building metaID #" + LIVING + " in cell 0,0 while reading map_meta.bin")
                && !Hooks.roomsReplaced("something else") && !Hooks.roomsReplaced(null), "The game's other complaints were left out");

            // A world loaded again: the map's rooms come from the file, and the save does not change it.
            byte[] filed = Files.readAllBytes(save.toPath().resolve(RoomEdits.FILE));
            edits.reset();
            check(Hooks.roomsReplaced(complaint(cell, LIVING)) && saved(cell).equals(entries), "The map's rooms were not kept in the file");
            Hooks.roomsSaving(0);
            check(java.util.Arrays.equals(filed, Files.readAllBytes(save.toPath().resolve(RoomEdits.FILE))), "A save changed the file when the rooms did not");
            check(!Files.exists(save.toPath().resolve(RoomEdits.FILE + ".new")), "A file was left half written");

            // The hooks of the world's save are not both in: no entries (a count with no entries would break the file), and no rooms set.
            var statuses = status();
            synchronized (statuses) { statuses.put(RoomEdits.ENTRIES_HOOK, "expected one place"); }
            edits.reset();
            check(Hooks.roomsOriginals(cell) == 0, "Entries were counted with the hook that writes them not in");
            synchronized (statuses) { statuses.put(RoomEdits.ENTRIES_HOOK, Hooks.APPLIED); statuses.put(RoomEdits.SAVE_HOOK, "expected one place"); }
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 3, 3)), room(0, null, rect(63, 60, 3, 3))));
            check(done.get(0) == null && String.valueOf(done.get(1)).contains(RoomEdits.SAVE_HOOK), "Rooms were set with the world's save not hooked: " + done);
            synchronized (statuses) { statuses.put(RoomEdits.SAVE_HOOK, Hooks.APPLIED); }
            edits.reset();

            // A wall again: two rooms, one named. The building is the editor's: no second map building taken out.
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 3, 3)), room(0, "bathroom", rect(63, 60, 3, 3))));
            check(Boolean.TRUE.equals(done.get(0)), "One room was not made two: " + done);
            RoomDef west = grid.getRoomAt(60, 60, 0), east = grid.getRoomAt(64, 61, 0);
            check(west != east && west.name.equals("kitchen") && east.name.equals("bathroom") && east.lightsActive,
                "The rooms were misnamed, or did not take the room they were: " + west.name + " " + east.name);
            check(lit.roomId == east.id, "The switch does not light the room on its square");
            check(grid.getRemovedBuildings().size() == 1, "A building the editor made was taken out as a map building");
            check(east.building.getKeyId() == 77, "The building's key was lost the second time");
            Hooks.roomsSaving(0);
            file(save, 1, 1, 2);
            check(kept(save).equals(List.of(KITCHEN, LIVING)), "The map's rooms were not kept the second time: " + kept(save));
            // Both rooms have the map's numbers now: their own entries stand, and none is added.
            fill(cell, grid, KEY);
            check(Hooks.roomsOriginals(cell) == 0, "An entry was added for a number a room has");
            Hooks.roomsEntries(cell, ByteBuffer.allocate(0));
            check(saved(cell).size() == 2, "The cell's entries are not its rooms' alone");

            // The rooms it has: nothing done.
            before = (double)FormulasTest.call(buildings, "version").get(0);
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 3, 3)), room(0, null, rect(63, 60, 3, 3))));
            check(Boolean.TRUE.equals(done.get(0)) && (double)FormulasTest.call(buildings, "version").get(0) == before,
                "Rooms the building has were made again");

            // Refused: other squares, no building, a building players built, and rooms the game would not take.
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 7, 3))));
            check(done.get(0) == null && "the rooms are not the building's squares".equals(done.get(1)), "More squares were taken: " + done);
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 5, 3))));
            check(done.get(0) == null, "Fewer squares were taken: " + done);
            done = FormulasTest.call(buildings, "setRooms", "1,1,0", list(room(0, null, rect(1, 1, 1, 1))));
            check(done.get(0) == null && "no building has the key".equals(done.get(1)), "No building was given rooms");
            done = FormulasTest.call(buildings, "setRooms", "20,20,0", list(room(0, null, rect(20, 20, 2, 2))));
            check(done.get(0) == null && String.valueOf(done.get(1)).startsWith("a building players built"), "A player-built building was given rooms");
            rejects(buildings, "rooms overlap at 62,60,0", list(room(0, null, rect(60, 60, 3, 3)), room(0, null, rect(62, 60, 4, 3))));
            rejects(buildings, "room 1: level must be", list(room(40, null, rect(60, 60, 6, 3))));
            rejects(buildings, "name must be nil", list(room(0, "emptyoutside", rect(60, 60, 6, 3))));
            rejects(buildings, "rectangle 1: w must be", list(room(0, null, rect(60, 60, 0, 3))));
            rejects(buildings, "rooms must not be empty", list());
            rejects(buildings, "rooms must be a list", "kitchen");

            // Walls elsewhere: the west room two squares wide. The map's living room (the number the east room does not have now) is
            // over the east room only, whose flags it gets; the number the kitchen had is a room's again, and stands.
            east.explored = true;
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 2, 3)), room(0, null, rect(62, 60, 4, 3))));
            check(Boolean.TRUE.equals(done.get(0)), "The wall was not moved: " + done);
            west = grid.getRoomAt(60, 60, 0);
            east = grid.getRoomAt(64, 61, 0);
            check(east.explored && east.lightsActive && !west.explored && west.lightsActive, "The rooms did not take the rooms they were over most of");
            fill(cell, grid, KEY);
            check(Hooks.roomsOriginals(cell) == 1, "The living room had no entry after the wall moved");
            entries = saved(cell);
            check(entries.equals(Map.of(KITCHEN, 2, SECOND, 3, LIVING, 3)), "map_meta.bin got " + entries);
            // The rooms' squares have none of the map's rooms' flags to give (no room): no entry, and the count agrees.
            Hooks.roomsSaving(0);
            check(kept(save).equals(List.of(KITCHEN, LIVING)), "The map's rooms changed with the wall: " + kept(save));

            // The game loads the file again: its building is a map building; with only its own file, the game's building is its own.
            BuildingRoomsEditor.getInstance().load();
            check(!BuildingRoomsEditor.lastLoaded.def().isUserDefined(), "The building the game made from the API's file is one players built");
            check(new BREBuilding().def().isUserDefined(), "The editor's buildings stayed map buildings after the world loaded");

            // A world that saves nothing: no file.
            Core.noSave = true;
            Files.delete(save.toPath().resolve(RoomEdits.FILE));
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 6, 3))));
            Hooks.roomsSaving(0);
            check(Boolean.TRUE.equals(done.get(0)) && !Files.exists(save.toPath().resolve(RoomEdits.FILE)), "A world that saves nothing got a file");
            Core.noSave = false;
            // Without the API's file the game reads its own (a debug editor's rooms).
            Files.write(save.toPath().resolve("player_buildings.bin"), new byte[] { 1 });
            BuildingRoomsEditor.getInstance().load();
            check(PlayerRoomsFile.lastRead != null && PlayerRoomsFile.lastRead.getName().equals("player_buildings.bin"),
                "The game did not read its own file when the API had none: " + PlayerRoomsFile.lastRead);
            check(BuildingRoomsEditor.lastLoaded.def().isUserDefined(), "The building the game made from its own file is not what it makes");
        } finally {
            Core.noSave = false;
            BuildingRoomsEditor.getInstance().setLuaEditor(null);
            BuildingDef now = grid.getRoomAt(60, 60, 0).building;
            grid.rooms.removeAll(now.rooms);
            grid.buildings.remove(now);
            grid.getRemovedBuildings().clear();
            lit.square.objects.remove(lit);
            edits.reset();
        }
    }

    /** The file as the game reads it: its marks, the map buildings taken out, the buildings put in, and the first one's rooms. */
    private static void file(java.io.File save, int removed, int buildings, int rooms) throws Exception {
        var buffer = ByteBuffer.wrap(Files.readAllBytes(save.toPath().resolve(RoomEdits.FILE)));
        byte[] magic = new byte[4];
        buffer.get(magic);
        check(new String(magic).equals("PRBG") && buffer.getInt() == 1, "The file is not the game's");
        check(buffer.getShort() == removed, "The file takes out other map buildings");
        check(buffer.getInt() == 60 && buffer.getInt() == 60 && buffer.getInt() == 0, "The file takes out another square");
        check(buffer.getShort() == buildings, "The file puts in other buildings");
        check(buffer.getShort() == rooms, "The file's building has other rooms");
        check(buffer.get() == 0 && GameWindow.ReadString(buffer).equals("kitchen"), "The file's first room is misdescribed");
        int rects = buffer.getShort();
        check(rects == 1 && buffer.getInt() == 60 && buffer.getInt() == 60 && buffer.getShort() == (rooms == 1 ? 6 : 3)
            && buffer.getShort() == 3, "The file's first room's rectangle is misdescribed");
    }

    /** The numbers of the map's rooms the file keeps after what the game reads (in the order it keeps them), as a world loaded again reads them. */
    private static List<Long> kept(java.io.File save) throws Exception {
        byte[] bytes = Files.readAllBytes(save.toPath().resolve(RoomEdits.FILE));
        int end = bytes.length - 8;
        check(end > 0 && new String(bytes, bytes.length - 4, 4).equals("PXOR"), "The file does not end with the map's rooms");
        int size = ByteBuffer.wrap(bytes, end, 4).getInt();
        var block = ByteBuffer.wrap(bytes, end - size, size);
        var ids = new ArrayList<Long>();
        for (int count = block.getShort(); count > 0; count--) {
            check(block.getInt() == 0 && block.getInt() == 0 && block.get() == 0, "A room of the map is kept in another cell or level");
            ids.add(block.getLong());
            for (int rect = block.getShort(); rect > 0; rect--) { block.getInt(); block.getInt(); block.getShort(); block.getShort(); }
        }
        check(!block.hasRemaining(), "The map's rooms are not the size the file says");
        return ids;
    }

    /**
     * The cell as the game keeps it for the building at the key: its rooms with their numbers (from the first rectangle, relative to
     * the cell), as the editor puts them.
     */
    private static void fill(IsoMetaCell cell, zombie.iso.IsoMetaGrid grid, String key) {
        cell.roomList.clear();
        cell.roomByMetaId.remove(KITCHEN);
        cell.roomByMetaId.remove(LIVING);
        cell.roomByMetaId.remove(SECOND);
        BuildingDef def = grid.getBuildingAt(60, 60, 0);
        for (RoomDef room : grid.rooms) {
            if (room.building != def) continue;
            RoomDef.RoomRect rect = room.rects.get(0);
            room.metaId = (long)room.level << 32 | (long)(rect.y - cell.getY() * 256) << 16 | (rect.x - cell.getX() * 256);
            cell.roomList.add(room);
            cell.roomByMetaId.put(room.metaId, room);
        }
    }

    /**
     * The game's {@code savePart} of the cell, as the hooks change it (the count is the rooms' and the extra entries', the extra entries
     * follow the rooms'), read as the game's {@code load} reads it: the number of each entry and its flags. An entry with no room is one
     * whose complaint the API leaves out.
     */
    private static Map<Long, Integer> saved(IsoMetaCell cell) {
        var buffer = ByteBuffer.allocate(4096);
        buffer.putInt(cell.getRoomCount(true) + Hooks.roomsOriginals(cell));
        for (RoomDef room : cell.roomList) buffer.putLong(room.metaId).putShort((short)flags(room));
        Hooks.roomsEntries(cell, buffer);
        buffer.putInt(0);
        buffer.flip();
        var entries = new LinkedHashMap<Long, Integer>();
        for (int count = buffer.getInt(); count > 0; count--) {
            long id = buffer.getLong();
            int flags = buffer.getShort();
            check(entries.put(id, flags) == null, "map_meta.bin has the number " + id + " twice");
            if (!cell.roomByMetaId.contains(id))
                check(Hooks.roomsReplaced(complaint(cell, id)), "The game would complain of the entry " + id);
        }
        check(buffer.getInt() == 0 && !buffer.hasRemaining(), "The cell's entries are not as many as the count says");
        return entries;
    }

    private static int flags(RoomDef room) { return (room.explored ? 1 : 0) | (room.lightsActive ? 2 : 0) | (room.doneSpawn ? 4 : 0) | (room.roofFixed ? 8 : 0); }

    /** The game's complaint of an entry it has no room for. */
    private static String complaint(IsoMetaCell cell, long id) {
        return "invalid room metaID #" + id + " in cell " + cell.getX() + "," + cell.getY() + " while reading map_meta.bin";
    }

    @SuppressWarnings("unchecked")
    private static Map<String, String> status() throws Exception { return (Map<String, String>)field(Hooks.class, "status"); }

    private static Object field(Class<?> type, String name) throws Exception {
        var field = type.getDeclaredField(name);
        field.setAccessible(true);
        return field.get(null);
    }

    private static RoomDef room(zombie.iso.IsoMetaGrid grid, RoomDef room, int x, int y, int w, int h) {
        room.rects.add(new RoomDef.RoomRect(x, y, w, h));
        grid.rooms.add(room);
        return room;
    }

    private static KahluaTable room(int level, String name, KahluaTable... rects) {
        var room = zombie.Lua.LuaManager.platform.newTable();
        room.rawset("level", (double)level);
        if (name != null) room.rawset("name", name);
        room.rawset("rects", list((Object[])rects));
        return room;
    }

    private static KahluaTable rect(int x, int y, int w, int h) {
        var rect = zombie.Lua.LuaManager.platform.newTable();
        rect.rawset("x", (double)x); rect.rawset("y", (double)y); rect.rawset("w", (double)w); rect.rawset("h", (double)h);
        return rect;
    }

    private static KahluaTable list(Object... items) {
        var list = zombie.Lua.LuaManager.platform.newTable();
        for (int index = 0; index < items.length; index++) list.rawset((double)(index + 1), items[index]);
        return list;
    }

    private static void rejects(KahluaTable buildings, String message, Object rooms) {
        try { FormulasTest.call(buildings, "setRooms", KEY, rooms); }
        catch (RuntimeException thrown) {
            if (String.valueOf(thrown.getMessage()).contains(message)) return;
            throw new AssertionError("setRooms failed otherwise than \"" + message + "\": " + thrown.getMessage(), thrown);
        }
        throw new AssertionError("setRooms took bad rooms: " + message);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }

}
