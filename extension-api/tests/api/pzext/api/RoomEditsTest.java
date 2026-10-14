package pzext.api;

import java.nio.ByteBuffer;
import java.nio.file.Files;
import pzext.boot.Hooks;
import se.krka.kahlua.vm.KahluaTable;
import zombie.GameWindow;
import zombie.ZomboidFileSystem;
import zombie.buildingRooms.BREBuilding;
import zombie.buildingRooms.BuildingRoomsEditor;
import zombie.core.Core;
import zombie.iso.BuildingDef;
import zombie.iso.IsoWorld;
import zombie.iso.MetaObject;
import zombie.iso.RoomDef;
import zombie.iso.objects.IsoLightSwitch;
import zombie.iso.sprite.IsoSprite;

/**
 * {@code buildings.setRooms}, against the synthetic game's building editor: a map building's two rooms made one and two
 * again, the building's own state, the rooms' flags, the map's objects and the light switches kept, the save's file
 * written as the game reads it, and what it refuses. And the hook that makes the editor's buildings map buildings.
 */
final class RoomEditsTest {
    private static final String KEY = "60,60,0";

    private RoomEditsTest() { }

    static void run(KahluaTable api) throws Exception {
        check(Hooks.APPLIED.equals(Hooks.hookStatus().get(RoomEdits.HOOK)), "The editor's hook is " + Hooks.hookStatus().get(RoomEdits.HOOK));
        check(!new BREBuilding().def().isUserDefined(), "The editor still makes buildings players built");
        var buildings = (KahluaTable)api.rawget("buildings");
        var grid = IsoWorld.instance.metaGrid;
        var save = Files.createTempDirectory("pzext-rooms").toFile();
        ZomboidFileSystem.save = save;
        // A map building of two rooms side by side: its key, an alarm, a switch lighting the kitchen, a zombie's place in the living room.
        var house = new BuildingDef(false);
        house.setKeyId(77);
        house.alarmed = true;
        var kitchen = room(grid, new RoomDef(501, "kitchen", 0, house), 60, 60, 3, 3);
        var living = room(grid, new RoomDef(502, "livingroom", 0, house), 63, 60, 3, 3);
        kitchen.lightsActive = true;
        living.explored = true;
        grid.buildings.add(house);
        var place = new MetaObject(64, 61, living);
        for (int x = 59; x <= 66; x++) for (int y = 59; y <= 63; y++) IsoWorld.instance.currentCell.load(x, y, 0);
        var lit = new IsoLightSwitch(new IsoSprite("switch"));
        lit.roomId = 501;
        lit.square = IsoWorld.instance.currentCell.load(64, 62, 0);
        lit.square.objects.add(lit);
        BuildingRoomsEditor.getInstance().setLuaEditor(new Object());
        try {
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
            file(save, 1, 1, 1);

            // A wall again: two rooms, one named. The building is the editor's: no second map building taken out.
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 3, 3)), room(0, "bathroom", rect(63, 60, 3, 3))));
            check(Boolean.TRUE.equals(done.get(0)), "One room was not made two: " + done);
            RoomDef west = grid.getRoomAt(60, 60, 0), east = grid.getRoomAt(64, 61, 0);
            check(west != east && west.name.equals("kitchen") && east.name.equals("bathroom") && east.lightsActive,
                "The rooms were misnamed, or did not take the room they were: " + west.name + " " + east.name);
            check(lit.roomId == east.id, "The switch does not light the room on its square");
            check(grid.getRemovedBuildings().size() == 1, "A building the editor made was taken out as a map building");
            check(east.building.getKeyId() == 77, "The building's key was lost the second time");
            file(save, 1, 1, 2);

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

            // A world that saves nothing: no file.
            Core.noSave = true;
            Files.delete(save.toPath().resolve(RoomEdits.FILE));
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 6, 3))));
            check(Boolean.TRUE.equals(done.get(0)) && !Files.exists(save.toPath().resolve(RoomEdits.FILE)), "A world that saves nothing got a file");
        } finally {
            Core.noSave = false;
            BuildingRoomsEditor.getInstance().setLuaEditor(null);
            BuildingDef now = grid.getRoomAt(60, 60, 0).building;
            grid.rooms.removeAll(now.rooms);
            grid.buildings.remove(now);
            grid.getRemovedBuildings().clear();
            lit.square.objects.remove(lit);
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
