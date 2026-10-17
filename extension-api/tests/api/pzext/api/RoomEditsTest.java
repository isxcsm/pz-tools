package pzext.api;

import java.io.File;
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.MethodModel;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
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
import zombie.debug.DebugType;
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
 * <p>The world's save and load are the synthetic meta grid's own {@code savePart} and {@code load(ByteBuffer)}, shaped as the
 * game's are and changed by the hooks as the game's are: the test saves the map's data and reads it back as a world does, and the
 * cases of a hook that is missing are classes changed on purpose, put through the boot layer's transform.
 */
final class RoomEditsTest {
    private static final String KEY = "60,60,0";
    /** The numbers of the rooms a cell of the map holds at 60,60 and 63,60 (from their first rectangle: y << 16 | x). */
    private static final long KITCHEN = 60L << 16 | 60, LIVING = 60L << 16 | 63, SECOND = 60L << 16 | 62;
    private static final String GRID = "zombie/iso/IsoMetaGrid";
    private static final ClassLoader GAME = RoomEditsTest.class.getClassLoader();

    private RoomEditsTest() { }

    static void run(KahluaTable api) throws Exception {
        rooms(api);
    }

    private static void rooms(KahluaTable api) throws Exception {
        for (String hook : new String[] { RoomEdits.SAVE_HOOK, RoomEdits.COUNT_HOOK, RoomEdits.ENTRIES_HOOK, "IsoMetaGrid.load:complaint" })
            check(Hooks.APPLIED.equals(Hooks.hookStatus().get(hook)), "The hook " + hook + " is " + Hooks.hookStatus().get(hook));
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
        // A second cell beside it, which the map has no rooms in.
        var beside = new IsoMetaCell(1, 0);
        var place = new MetaObject(64, 61, living);
        for (int x = 59; x <= 66; x++) for (int y = 59; y <= 63; y++) IsoWorld.instance.currentCell.load(x, y, 0);
        // A loaded square away from the building, which the editor need not work out again.
        var away = IsoWorld.instance.currentCell.load(90, 90, 0);
        var lit = new IsoLightSwitch(new IsoSprite("switch"));
        lit.roomId = 501;
        lit.square = IsoWorld.instance.currentCell.load(64, 62, 0);
        lit.square.objects.add(lit);
        BuildingRoomsEditor.getInstance().setLuaEditor(new Object());
        grid.setCells(0, 0, new IsoMetaCell[][] { { cell }, { beside } });
        DebugType.errors.clear();
        try {
            // No rooms set: the world's save and load have nothing of this API's to do.
            fill(cell, grid, KEY);
            check(saved(grid).equals(Map.of(KITCHEN, 2, LIVING, 1)), "Entries were made with no rooms set: " + saved(grid));
            check(complaints(grid, save(grid)).isEmpty() && !Files.exists(save.toPath().resolve(RoomEdits.FILE)), "A file was written with no rooms set");

            // The wall between them gone: one room. It is the kitchen (the first of the two it is as much of).
            double before = (double)FormulasTest.call(buildings, "version").get(0);
            var done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 6, 3))));
            check(Boolean.TRUE.equals(done.get(0)) && done.get(1) == null, "Two rooms were not made one: " + done);
            // The editor's work over the whole map is the building's: its squares, its cell numbered again, and no check of every cell.
            for (String hook : new String[] { "updateSquares:squares", "applyChanges:numbers", "applyChanges:check" })
                check(Hooks.APPLIED.equals(Hooks.hookStatus().get("BuildingRoomsEditor." + hook)),
                    "The editor's hook " + hook + " is " + Hooks.hookStatus().get("BuildingRoomsEditor." + hook));
            check(BuildingRoomsEditor.updated.contains(IsoWorld.instance.currentCell.getGridSquare(61, 61, 0))
                && BuildingRoomsEditor.updated.contains(IsoWorld.instance.currentCell.getGridSquare(66, 63, 0))
                && !BuildingRoomsEditor.updated.contains(away), "The editor did not work out the building's squares alone");
            check(BuildingRoomsEditor.renumbered.equals(java.util.Set.of(cell)) && BuildingRoomsEditor.everyCell == 0,
                "The editor went over every cell: " + BuildingRoomsEditor.renumbered.size() + " numbered, " + BuildingRoomsEditor.everyCell + " passes");
            // The lighting works out again the chunks of the building and those around it, not the one away from it; after the game
            // changed buildings of its own, every chunk, as the game does.
            for (String hook : new String[] { "buildingsChanged", "checkChangedBuildings:chunks", "checkChangedBuildings:done" })
                check(Hooks.APPLIED.equals(Hooks.hookStatus().get("LightingJNI." + hook)), "The lighting's hook " + hook + " is " + Hooks.hookStatus().get("LightingJNI." + hook));
            zombie.iso.LightingJNI.update();
            check(zombie.iso.LightingJNI.relit.contains(IsoWorld.instance.currentCell.getGridSquare(61, 61, 0).chunk)
                && !zombie.iso.LightingJNI.relit.contains(away.chunk), "The lighting did not work out the building's chunks alone");
            zombie.iso.LightingJNI.buildingsChanged();
            zombie.iso.LightingJNI.update();
            check(zombie.iso.LightingJNI.relit.contains(away.chunk), "The game's own change of buildings did not light every chunk again");
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
            grid.savePart(ByteBuffer.allocate(4096), 1, false);
            check(!Files.exists(save.toPath().resolve(RoomEdits.FILE)), "The file was written for the part of the world's save that is not the rooms'");
            save(grid);
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
            byte[] saved = save(grid);
            var entries = read(saved).get(0);
            check(entries.equals(Map.of(KITCHEN, 2, LIVING, 2)), "map_meta.bin got " + entries);
            check(read(save(grid)).get(0).equals(entries), "The entries are not the same again");
            // As the world loads: the game complains of nothing (the kitchen's flags are the room's, the living room's number has no room).
            one.lightsActive = false;
            check(complaints(grid, saved).isEmpty() && one.lightsActive, "The game complained of the map's own rooms, or did not read their flags: " + DebugType.errors);
            // Its other complaints are left as they are: an entry no room of the API's replaced, in this cell and in another, and a building's.
            var complained = complaints(grid, patched(saved, LIVING, 12345));
            check(complained.equals(List.of("invalid room metaID #12345 in cell 0,0 while reading map_meta.bin")), "The game's complaint was changed: " + complained);
            var stray = new RoomDef(900, "stray", 0, new BuildingDef(false));
            stray.metaId = LIVING;
            beside.roomList.add(stray);
            complained = complaints(grid, save(grid));
            beside.roomList.clear();
            check(complained.equals(List.of("invalid room metaID #" + LIVING + " in cell 1,0 while reading map_meta.bin")),
                "The game's complaint of another cell's entry was left out: " + complained);
            var lone = new BuildingDef(false);
            lone.metaId = LIVING;
            cell.buildings.add(lone);
            complained = complaints(grid, save(grid));
            cell.buildings.clear();
            check(complained.equals(List.of("invalid building metaID #" + LIVING + " in cell 0,0 while reading map_meta.bin")),
                "The game's complaint of a building's entry was left out: " + complained);

            // A world loaded again: the map's rooms come from the file, and the save does not change it (the file is not written again).
            Path filePath = save.toPath().resolve(RoomEdits.FILE);
            byte[] filed = Files.readAllBytes(filePath);
            Files.setLastModifiedTime(filePath, FileTime.fromMillis(1_000_000));
            edits.reset();
            saved = save(grid);
            check(read(saved).get(0).equals(entries) && complaints(grid, saved).isEmpty(), "The map's rooms were not kept in the file");
            check(java.util.Arrays.equals(filed, Files.readAllBytes(filePath)) && Files.getLastModifiedTime(filePath).toMillis() == 1_000_000,
                "A save wrote the file when the rooms did not change");
            check(!Files.exists(save.toPath().resolve(RoomEdits.FILE + ".new")), "A file was left half written");

            // The hooks of the world's save are not both in (the class is changed so that the entries are not in): no entries (a count
            // with no entries would break the file), and the entries the file holds are the cell's own.
            byte[] own = classBytes(GRID);
            changed(entriesGone(), own, RoomEdits.ENTRIES_HOOK);
            edits.reset();
            check(read(save(grid)).get(0).equals(Map.of(KITCHEN, 2)), "Entries were counted with the hook that writes them not in");
            // The world's save is not hooked at all: no rooms set.
            changed(ClassTransform.dropping(element -> element instanceof MethodModel method && method.methodName().equalsString("savePart")), own,
                RoomEdits.SAVE_HOOK, RoomEdits.COUNT_HOOK, RoomEdits.ENTRIES_HOOK);
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 3, 3)), room(0, null, rect(63, 60, 3, 3))));
            check(done.get(0) == null && String.valueOf(done.get(1)).contains(RoomEdits.SAVE_HOOK), "Rooms were set with the world's save not hooked: " + done);
            // The game's own class again: every hook is back.
            HookNoise.expecting(() -> transform().invoke(null, GRID, own, GAME));
            for (String hook : new String[] { RoomEdits.SAVE_HOOK, RoomEdits.COUNT_HOOK, RoomEdits.ENTRIES_HOOK })
                check(Hooks.APPLIED.equals(Hooks.hookStatus().get(hook)), "The hook " + hook + " did not come back: " + Hooks.hookStatus().get(hook));
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
            save(grid);
            file(save, 1, 1, 2);
            check(kept(save).equals(List.of(KITCHEN, LIVING)), "The map's rooms were not kept the second time: " + kept(save));
            // Both rooms have the map's numbers now: their own entries stand, and none is added.
            fill(cell, grid, KEY);
            check(saved(grid).equals(Map.of(KITCHEN, 2, LIVING, 2)), "The cell's entries are not its rooms' alone: " + saved(grid));

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
            entries = saved(grid);
            check(entries.equals(Map.of(KITCHEN, 2, SECOND, 3, LIVING, 3)), "map_meta.bin got " + entries + ", the living room had no entry after the wall moved");
            check(complaints(grid, save(grid)).isEmpty(), "The game complained as the wall moved: " + DebugType.errors);
            check(kept(save).equals(List.of(KITCHEN, LIVING)), "The map's rooms changed with the wall: " + kept(save));

            // The game loads the file again: its building is a map building; with only its own file, the game's building is its own.
            BuildingRoomsEditor.getInstance().load();
            check(!BuildingRoomsEditor.lastLoaded.def().isUserDefined(), "The building the game made from the API's file is one players built");
            check(new BREBuilding().def().isUserDefined(), "The editor's buildings stayed map buildings after the world loaded");

            // A world that saves nothing: no file.
            Core.noSave = true;
            Files.delete(save.toPath().resolve(RoomEdits.FILE));
            done = FormulasTest.call(buildings, "setRooms", KEY, list(room(0, null, rect(60, 60, 6, 3))));
            save(grid);
            check(Boolean.TRUE.equals(done.get(0)) && !Files.exists(save.toPath().resolve(RoomEdits.FILE)), "A world that saves nothing got a file");
            Core.noSave = false;
            // Without the API's file the game reads its own (a debug editor's rooms).
            Files.write(save.toPath().resolve("player_buildings.bin"), new byte[] { 1 });
            BuildingRoomsEditor.getInstance().load();
            check(PlayerRoomsFile.lastRead != null && PlayerRoomsFile.lastRead.getName().equals("player_buildings.bin"),
                "The game did not read its own file when the API had none: " + PlayerRoomsFile.lastRead);
            check(BuildingRoomsEditor.lastLoaded.def().isUserDefined(), "The building the game made from its own file is not what it makes");

            walls(api, buildings);
        } finally {
            Core.noSave = false;
            BuildingRoomsEditor.getInstance().setLuaEditor(null);
            grid.setCells(0, 0, new IsoMetaCell[0][0]);
            DebugType.errors.clear();
            BuildingDef now = grid.getRoomAt(60, 60, 0).building;
            grid.rooms.removeAll(now.rooms);
            grid.buildings.remove(now);
            grid.getRemovedBuildings().clear();
            lit.square.objects.remove(lit);
            edits.reset();
        }
    }

    /**
     * Rooms that follow the walls (watchWalls, its function setting the rooms told), the building one room of 6 by 3: a wall built
     * across it makes two, taken down one, built again two; each told once, the rooms set before the next change. Then, watched
     * again as the two rooms named: the wall between them taken down in part makes one, built again two (the rest of the wall is
     * the rooms' own, not a wall inside the one room), each with its name back.
     */
    private static void walls(KahluaTable api, KahluaTable buildings) {
        Object mod = FormulasTest.call(api, "client", "rooms.walls").get(0);
        var told = new ArrayList<Integer>();
        se.krka.kahlua.vm.JavaFunction follow = (frame, count) -> {
            var rooms = (KahluaTable)frame.get(1);
            told.add(rooms.len());
            var done = FormulasTest.call(buildings, "setRooms", frame.get(0), rooms);
            check(Boolean.TRUE.equals(done.get(0)), "The rooms told were not set: " + done);
            return 0;
        };
        var id = FormulasTest.call(buildings, "watchWalls", mod, KEY, follow).get(0);
        check(id instanceof Double, "The building was not watched");
        try {
            for (boolean standing : new boolean[] { true, false, true }) {
                for (int y = 60; y <= 62; y++) {
                    var square = IsoWorld.instance.currentCell.getGridSquare(63, y, 0);
                    square.westWall = standing;
                    square.RecalcProperties();
                }
                GameApi.frame(GAME);
                GameApi.frame(GAME);
            }
            check(told.equals(List.of(2, 1, 2)), "The rooms did not follow the walls after they were set: " + told);
            check(IsoWorld.instance.metaGrid.getRoomAt(60, 60, 0) != IsoWorld.instance.metaGrid.getRoomAt(64, 61, 0), "The rooms set are not two");
            FormulasTest.call(buildings, "unwatchWalls", mod, id);
            FormulasTest.call(buildings, "setRooms", KEY, list(room(0, "kitchen", rect(60, 60, 3, 3)), room(0, "bathroom", rect(63, 60, 3, 3))));
            id = FormulasTest.call(buildings, "watchWalls", mod, KEY, follow).get(0);
            var middle = IsoWorld.instance.currentCell.getGridSquare(63, 61, 0);
            for (boolean standing : new boolean[] { false, true }) {
                middle.westWall = standing;
                middle.RecalcProperties();
                GameApi.frame(GAME);
                GameApi.frame(GAME);
            }
            check(told.equals(List.of(2, 1, 2, 1, 2)), "A wall taken down in part and built again did not part the rooms again: " + told);
            check(IsoWorld.instance.metaGrid.getRoomAt(60, 60, 0).name.equals("kitchen") && IsoWorld.instance.metaGrid.getRoomAt(64, 61, 0).name.equals("bathroom"),
                "The rooms parted again did not get their names back: " + IsoWorld.instance.metaGrid.getRoomAt(64, 61, 0).name);
            // The editor used as the game uses it (no rooms being set) goes over the whole map, as the game's.
            BuildingRoomsEditor.getInstance().applyChanges(false);
            check(BuildingRoomsEditor.everyCell == 4 && BuildingRoomsEditor.renumbered.size() == 2
                && BuildingRoomsEditor.updated.contains(IsoWorld.instance.currentCell.getGridSquare(90, 90, 0)),
                "The editor's own use did not go over the whole map");
        } finally {
            FormulasTest.call(buildings, "unwatchWalls", mod, id);
            for (int y = 60; y <= 62; y++) IsoWorld.instance.currentCell.getGridSquare(63, y, 0).westWall = false;
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

    /** The grid's save of the map's data (part 0), through the game's own {@code savePart}, as the hooks change it. */
    private static byte[] save(zombie.iso.IsoMetaGrid grid) {
        var buffer = ByteBuffer.allocate(4096);
        grid.savePart(buffer, 0, false);
        buffer.flip();
        var bytes = new byte[buffer.remaining()];
        buffer.get(bytes);
        return bytes;
    }

    /**
     * What the game's save of the map's data holds, read as its {@code load} reads it: for each cell, the number of each of its rooms'
     * entries and its flags. The entries of the cell are the first, those of the cell beside it the second.
     */
    private static List<Map<Long, Integer>> read(byte[] bytes) {
        var buffer = ByteBuffer.wrap(bytes);
        check(buffer.get() == 'M' && buffer.get() == 'E' && buffer.get() == 'T' && buffer.get() == 'A', "map_meta.bin does not begin as the game's does");
        buffer.getInt();
        int minX = buffer.getInt(), minY = buffer.getInt(), maxX = buffer.getInt(), maxY = buffer.getInt();
        var cells = new ArrayList<Map<Long, Integer>>();
        for (int cell = (maxX - minX + 1) * (maxY - minY + 1); cell > 0; cell--) {
            var entries = new LinkedHashMap<Long, Integer>();
            for (int count = buffer.getInt(); count > 0; count--) {
                long id = buffer.getLong();
                check(entries.put(id, (int)buffer.getShort()) == null, "map_meta.bin has the number " + id + " twice");
            }
            for (int buildings = buffer.getInt(); buildings > 0; buildings--) buffer.position(buffer.position() + 8 + 1 + 4 + 1 + 1 + 4 + 4);
            cells.add(entries);
        }
        check(!buffer.hasRemaining(), "The entries are not as many as the counts say");
        return cells;
    }

    /** The cell's entries in a save of the grid. */
    private static Map<Long, Integer> saved(zombie.iso.IsoMetaGrid grid) { return read(save(grid)).get(0); }

    /** What the game complains of as it loads the map's data: the complaints of its {@code load}, in order. */
    private static List<String> complaints(zombie.iso.IsoMetaGrid grid, byte[] bytes) {
        DebugType.errors.clear();
        grid.load(ByteBuffer.wrap(bytes));
        var complained = new ArrayList<>(DebugType.errors);
        DebugType.errors.clear();
        return complained;
    }

    /** The save with the eight bytes of a number written as another (it must be there once). */
    private static byte[] patched(byte[] bytes, long from, long to) {
        var wanted = ByteBuffer.allocate(8).putLong(from).array();
        int at = -1;
        for (int index = 0; index + 8 <= bytes.length; index++)
            if (java.util.Arrays.equals(bytes, index, index + 8, wanted, 0, 8)) {
                check(at < 0, "The number " + from + " is in the save twice");
                at = index;
            }
        check(at >= 0, "The number " + from + " is not in the save");
        var result = bytes.clone();
        ByteBuffer.wrap(result).putLong(at, to);
        return result;
    }

    // ---- the grid's class changed on purpose, put through the boot layer as the game's classes are as they load ----

    private static java.lang.reflect.Method transform() throws Exception {
        var transform = Hooks.class.getDeclaredMethod("transform", String.class, byte[].class, ClassLoader.class);
        transform.setAccessible(true);
        return transform;
    }

    private static byte[] classBytes(String name) throws Exception {
        try (var input = GAME.getResourceAsStream(name + ".class")) { return input.readAllBytes(); }
    }

    /** The grid's class with {@code transform} applied, put through the boot layer: the hooks of {@code missing} do not fit it. */
    private static void changed(ClassTransform transform, byte[] own, String... missing) throws Exception {
        var files = ClassFile.of();
        byte[] changed = files.transformClass(files.parse(own), transform);
        HookNoise.expecting(() -> transform().invoke(null, GRID, changed, GAME), missing);
        for (String hook : missing) check(!Hooks.APPLIED.equals(Hooks.hookStatus().get(hook)), "The hook " + hook + " went in the changed class");
    }

    /** The grid's class asking the cell for its buildings in another way: the place where the entries are written is not there. */
    private static ClassTransform entriesGone() {
        return ClassTransform.transformingMethodBodies((builder, element) -> {
            if (element instanceof InvokeInstruction invoke && invoke.name().equalsString("getBuildingCount") && invoke.type().equalsString("(Z)I")) {
                builder.pop();
                builder.invokevirtual(invoke.owner().asSymbol(), "getBuildingCount", MethodTypeDesc.of(ConstantDescs.CD_int));
            } else builder.with(element);
        });
    }

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
