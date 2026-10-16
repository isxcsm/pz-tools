package pzext.api;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.MethodModel;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import pzext.boot.Hooks;
import se.krka.kahlua.vm.*;
import zombie.GameTime;
import zombie.SandboxOptions;
import zombie.Lua.LuaEventManager;
import zombie.Lua.LuaManager;
import zombie.entity.GameEntityManager;
import zombie.entity.MetaEntity;
import zombie.entity.components.fluids.Fluid;
import zombie.entity.components.fluids.FluidContainer;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.inventory.types.InventoryContainer;
import zombie.inventory.types.Food;
import zombie.iso.*;
import zombie.iso.SpriteDetails.IsoFlagType;
import zombie.iso.areas.isoregion.IsoRegions;
import zombie.iso.areas.isoregion.regions.IsoWorldRegion;
import zombie.iso.objects.IsoGenerator;
import zombie.iso.objects.IsoLightSwitch;
import zombie.iso.objects.IsoRadio;
import zombie.iso.objects.IsoWorldInventoryObject;
import zombie.iso.sprite.IsoSprite;
import zombie.network.GameClient;
import zombie.world.moddata.ModData;

/**
 * The extension API as a Lua mod sees it, against a synthetic game (tests/game): the table, the facts
 * about buildings, the mods' handles, the power and water networks, and a newer API taking the table over. The API's hooks
 * are in the game's classes, put there by {@link pzext.boot.TestAgent} as the boot layer does.
 */
public final class GameApiTest {
    private GameApiTest() { }

    public static void main(String[] args) throws Exception {
        world();
        // As in the game: the API sets the handler, and the hook sets the API as the game's Lua starts.
        GameApi.start();
        LuaManager.init();
        KahluaTable api = (KahluaTable)LuaManager.env.rawget(GameApi.GLOBAL);
        check(api != null && api.rawget("version").equals(1.0), "The API table or its version is missing");
        FrameCostTest.run("nothing declared");
        KahluaTable buildings = (KahluaTable)api.rawget("buildings");
        at(buildings);
        rooms(buildings);
        objects(buildings);
        near(buildings);
        producers(buildings);
        ContainersTest.run(buildings);
        wallLamps(api, buildings);
        callerErrors(buildings);
        attached(buildings);
        clients(api);
        networks(api);
        // No roll of a generator away hits unless a test says so.
        PowerGrid.dice = bound -> bound - 1;
        sequence(api);
        generatorAway(api);
        savedState(api);
        generatorSwitches();
        worldItems();
        children(api);
        switches(api);
        loadFactors(api);
        gridFirst(api);
        memberRooms(api);
        farApart(api);
        cheapHooks(api);
        sources(api);
        service(api);
        switchedOff(api);
        marks(api);
        failedTakeover(api);
        handover(api);
        water(api);
        nearest(api);
        fluids(api);
        parents(api);
        rainKept(api);
        purify(api);
        reserves(api);
        mainsFirst(api);
        food(api);
        FormulasTest.run(api);
        ItemCountsTest.run(api);
        HiddenZombiesTest.run(api);
        SystemsTest.run(api);
        ZombieSoundsTest.run(api);
        MoodlesTest.run(api);
        TextsTest.run(api);
        ZombieQueriesTest.run(api);
        ZombieHitsTest.run(api);
        TimersTest.run(api);
        ChunkWatchesTest.run(api);
        QuadsTest.run(api);
        FloorDecalsTest.run(api);
        SquareWatchesTest.run(api);
        RoomEditsTest.run(api);
        ZombieHoldsTest.run(api);
        FontsTest.run();
        OutlinesTest.run();
        NetworkScaleTest.run(api);
        hooks(api);
        takeover(api, buildings);
        System.out.println("PASS: the extension API reports buildings and their objects, runs power and water networks, switches them off and on, multiplies their loads, takes in single rooms, runs sources its mods switch, ages food by their supply, shows the moodles mods define, draws the text mods show, tells the sounds zombies make and the hits they take, finds zombies by level, sight and state, lists containers, calls functions on timers and as chunks load, wraps and fits text, draws many shapes at once, lays pictures on floors, tells mods of the squares they watch, gives map buildings new rooms, marks zombies and holds them in areas, outlines models and vehicles, counts items through bags, says which hooks went in, and a newer API takes it over");
    }

    // A map building: a basement, a kitchen and a bedroom above it. A player-built shack. Another building's room.
    private static final String KEY = "11,11,-1";
    private static IsoGridSquare square(int x, int y, int z) { return IsoWorld.instance.currentCell.load(x, y, z); }

    private static void world() {
        var grid = IsoWorld.instance.metaGrid;
        var house = new BuildingDef(false);
        room(grid, new RoomDef(3, "basement", -1, house), 11, 11, 2, 2);
        room(grid, new RoomDef(1, "kitchen", 0, house), 10, 10, 4, 3);
        room(grid, new RoomDef(2, "bedroom", 1, house), 10, 10, 4, 3);
        var shack = new BuildingDef(true);
        room(grid, new RoomDef(99, "", 0, shack), 20, 20, 2, 2);
        // Loaded: the house's lower levels and their surroundings, and the shack. The bedroom is not loaded.
        for (int z = -1; z <= 0; z++) for (int x = 5; x <= 25; x++) for (int y = 5; y <= 25; y++) square(x, y, z);
        place(11, 11, 0, powered("fridge", 0.08f));
        var sink = new IsoObject(new IsoSprite("sink"));
        sink.sprite.properties.flags.add(IsoFlagType.waterPiped);
        place(12, 11, 0, sink);
        place(10, 10, 0, new IsoObject(new IsoSprite("chair")));
        // On the kitchen's south wall, so on the square beyond it, lighting the kitchen.
        var kitchenSwitch = new IsoLightSwitch(new IsoSprite("kitchen switch"));
        kitchenSwitch.roomId = 1;
        place(11, 13, 0, kitchenSwitch);
        place(15, 11, 0, powered("street light", 0.002f));
        // Two squares from the house, outside, but lighting the shack: it belongs to the shack, not to the house's surroundings.
        var shackSwitch = new IsoLightSwitch(new IsoSprite("shack switch"));
        shackSwitch.roomId = 99;
        place(15, 12, 0, shackSwitch);
        place(20, 20, 0, powered("shack fridge", 0.08f));
    }

    private static void room(IsoMetaGrid grid, RoomDef room, int x, int y, int w, int h) {
        room.rects.add(new RoomDef.RoomRect(x, y, w, h));
        grid.rooms.add(room);
    }

    private static <T extends IsoObject> T place(int x, int y, int z, T object) {
        object.square = square(x, y, z);
        object.square.objects.add(object);
        return object;
    }

    private static IsoObject powered(String sprite, float consumption) {
        var object = new IsoObject(new IsoSprite(sprite));
        object.powered = true; object.consumption = consumption;
        return object;
    }

    private static void at(KahluaTable buildings) {
        KahluaTable house = (KahluaTable)call(buildings, "at", 11.0, 11.0, 0.0).get(0);
        check(house != null && house.rawget("key").equals(KEY) && house.rawget("playerBuilt").equals(false)
            && house.rawget("minLevel").equals(-1.0) && house.rawget("maxLevel").equals(1.0)
            && house.rawget("minX").equals(10.0) && house.rawget("minY").equals(10.0)
            && house.rawget("maxX").equals(13.0) && house.rawget("maxY").equals(12.0)
            && house.rawget("room").equals("kitchen") && house.rawget("roomId").equals("1"), "The house was misdescribed");
        check(((KahluaTable)call(buildings, "at", 10.0, 12.0, 1.0).get(0)).rawget("key").equals(KEY),
            "Every level gives the same key");
        KahluaTable shack = (KahluaTable)call(buildings, "at", 21.0, 21.0, 0.0).get(0);
        check(shack.rawget("key").equals("20,20,0") && shack.rawget("playerBuilt").equals(true), "The shack was misdescribed");
        check(call(buildings, "at", 0.0, 0.0, 0.0).get(0) == null, "A square of no building has a building");
        check(call(buildings, "at", 11.0, 13.0, 0.0).get(0) == null, "The square beyond a wall is in the building");
    }

    private static void rooms(KahluaTable buildings) {
        KahluaTable rooms = (KahluaTable)call(buildings, "rooms", KEY).get(0);
        check(rooms.len() == 3, "Not every room was listed");
        var names = new HashSet<Object>();
        for (int index = 1; index <= 3; index++) {
            KahluaTable room = (KahluaTable)rooms.rawget((double)index);
            names.add(room.rawget("name") + "@" + room.rawget("level") + "#" + room.rawget("id"));
        }
        check(names.equals(Set.of("basement@-1.0#3", "kitchen@0.0#1", "bedroom@1.0#2")), "Rooms were misdescribed: " + names);
        KahluaTable kitchen = null;
        for (int index = 1; index <= 3; index++)
            if (((KahluaTable)rooms.rawget((double)index)).rawget("name").equals("kitchen")) kitchen = (KahluaTable)rooms.rawget((double)index);
        KahluaTable rect = (KahluaTable)((KahluaTable)kitchen.rawget("rects")).rawget(1.0);
        check(rect.rawget("x").equals(10.0) && rect.rawget("y").equals(10.0) && rect.rawget("w").equals(4.0)
            && rect.rawget("h").equals(3.0), "A room's rectangle was misdescribed");
        check(call(buildings, "rooms", "10,10,0").get(0) == null, "A square that is not the key named the building");
        check(call(buildings, "rooms", "not a key").get(0) == null, "A malformed key named a building");
    }

    private static void objects(KahluaTable buildings) {
        var all = call(buildings, "objects", KEY);
        check(sprites(all.get(0)).equals(Set.of("fridge", "sink", "kitchen switch")), "Wrong objects: " + sprites(all.get(0)));
        check(all.get(1).equals(false), "Unloaded squares were reported as complete");
        KahluaTable fridge = find(all.get(0), "fridge");
        check(fridge.rawget("room").equals("kitchen") && fridge.rawget("roomId").equals("1") && fridge.rawget("type").equals("IsoObject")
            && fridge.rawget("x").equals(11.0) && fridge.rawget("z").equals(0.0) && fridge.rawget("water") == null
            && Math.abs((Double)fridge.rawget("power") - 0.08) < 1e-6, "The fridge was misdescribed");
        KahluaTable lightSwitch = find(all.get(0), "kitchen switch");
        check(lightSwitch.rawget("room").equals("kitchen") && lightSwitch.rawget("type").equals("IsoLightSwitch")
            && lightSwitch.rawget("y").equals(13.0), "The switch beyond the wall was misdescribed");
        KahluaTable sink = find(all.get(0), "sink");
        check(sink.rawget("water").equals(true) && sink.rawget("power") == null, "The sink was misdescribed");
        check(sprites(call(buildings, "objects", KEY, "water").get(0)).equals(Set.of("sink")), "The water filter failed");
        check(sprites(call(buildings, "objects", KEY, "power").get(0)).equals(Set.of("fridge", "kitchen switch")), "The power filter failed");
        var shack = call(buildings, "objects", "20,20,0");
        check(sprites(shack.get(0)).equals(Set.of("shack fridge")) && shack.get(1).equals(true),
            "The shack's objects, all loaded, were misreported");
        var gone = call(buildings, "objects", "1,1,0");
        check(gone.get(0) == null && gone.get(1).equals(false), "A key of no building gave objects");
    }

    private static void near(KahluaTable buildings) {
        check(sprites(call(buildings, "near", KEY, 2.0).get(0)).equals(Set.of("street light")), "Two squares out, wrong objects");
        check(sprites(call(buildings, "near", KEY, 1.0).get(0)).isEmpty(), "One square out reached two");
        check(sprites(call(buildings, "near", KEY, 2.0, "water").get(0)).isEmpty(), "The water filter let a light through");
        // The bedroom level's surroundings have no squares in loaded chunks: open air, not unloaded.
        check(call(buildings, "near", KEY, 2.0).get(1).equals(true), "The air around the bedroom level was reported unloaded");
        var east = IsoWorld.instance.currentCell.getChunk(1, 1);
        east.loaded = false;
        check(call(buildings, "near", KEY, 2.0).get(1).equals(false), "An unloaded chunk's surroundings were reported complete");
        east.loaded = true;
        var shack = call(buildings, "near", "20,20,0", 1.0);
        check(sprites(shack.get(0)).isEmpty() && shack.get(1).equals(true), "The shack's loaded surroundings were misreported");
        // Diagonal steps count as one: a corner of the house is within two of (15, 14).
        place(15, 14, 0, powered("corner light", 0.002f));
        check(sprites(call(buildings, "near", KEY, 2.0).get(0)).equals(Set.of("street light", "corner light")), "A diagonal step was miscounted");
        square(15, 14, 0).objects.clear();
        boolean[] marked = new boolean[25];
        marked[12] = true;
        boolean[] ring = Buildings.dilate(marked, 5, 5, 1);
        int count = 0;
        for (boolean value : ring) if (value) count++;
        check(count == 9 && ring[6] && ring[18] && !ring[0], "Dilation is not a square");
    }

    /**
     * What could be a producer in and around a building: a generator in its kitchen and one two squares out, a barrel
     * beside them; not one three squares out, nor an empty-capacity tank, nor what is in another building.
     */
    private static void producers(KahluaTable buildings) {
        place(13, 12, 0, new IsoGenerator(new IsoSprite("kitchen generator")));
        place(15, 10, 0, new IsoGenerator(new IsoSprite("yard generator")));
        place(16, 10, 0, new IsoGenerator(new IsoSprite("far generator")));
        place(15, 11, 0, barrel(20));
        var dry = new IsoObject(new IsoSprite("no tank"));
        dry.fluidContainer = new FluidContainer(0, 0);
        place(14, 13, 0, dry);
        place(21, 21, 0, new IsoGenerator(new IsoSprite("shack generator")));
        var all = call(buildings, "producers", KEY, 2.0);
        check(sprites(all.get(0)).equals(Set.of("kitchen generator", "yard generator", "barrel")), "Wrong producers: " + sprites(all.get(0)));
        check(all.get(1).equals(true), "The air around the bedroom level was reported unloaded");
        IsoWorld.instance.currentCell.getChunk(1, 1).loaded = false;
        check(call(buildings, "producers", KEY, 2.0).get(1).equals(false), "An unloaded chunk's squares were reported complete");
        IsoWorld.instance.currentCell.getChunk(1, 1).loaded = true;
        check(sprites(call(buildings, "producers", KEY, 2.0, "power").get(0)).equals(Set.of("kitchen generator", "yard generator")),
            "The power filter let water through");
        check(sprites(call(buildings, "producers", KEY, 0.0, "water").get(0)).isEmpty(), "Zero tiles reached outside");
        var first = (KahluaTable)((KahluaTable)call(buildings, "producers", KEY, 0.0).get(0)).rawget(1.0);
        check("power".equals(first.rawget("utility")) && first.rawget("x").equals(13.0) && first.rawget("type").equals("IsoGenerator"),
            "A producer's entry is wrong");
        check(call(buildings, "producers", "1,1,0", 2.0).get(0) == null, "A key of no building gave producers");
        error(buildings, "producers", "tiles must be a whole number from 0 to 32", KEY, 33.0);
        for (int[] at : new int[][] { { 13, 12 }, { 15, 10 }, { 16, 10 }, { 15, 11 }, { 14, 13 }, { 21, 21 } }) {
            var square = square(at[0], at[1], 0);
            for (int index = square.objects.size() - 1; index >= 0; index--) {
                var object = square.objects.get(index);
                if (object instanceof IsoGenerator || object.fluidContainer != null) square.objects.remove(index);
            }
        }
    }

    /**
     * Rooms players built onto a map building, from the game's region data: enclosed and half roofed beside its rooms,
     * with what doors join to them, counted in the room they touch most; kept while the region data is the one the game
     * has (the buildings' version), seen again once the game swaps in new data. None for a building players built, and
     * nil where a space grows past what a room has.
     */
    private static void attached(KahluaTable buildings) {
        var grid = IsoWorld.instance.metaGrid;
        var barn = new BuildingDef(false);
        var hall = new RoomDef(700, "hall", 0, barn);
        var store = new RoomDef(701, "store", 0, barn);
        room(grid, hall, 200, 200, 4, 4);
        room(grid, store, 204, 200, 2, 4);
        String key = "200,200,0";
        // A shed against the store, a porch through a door from it, a closet beside the porch with no door to it, and a
        // yard north of the hall, fenced but hardly roofed.
        var shed = new IsoWorldRegion(true, 1f);
        var porch = new IsoWorldRegion(true, 0.6f);
        shed.joined.add(porch);
        porch.joined.add(shed);
        var closet = new IsoWorldRegion(true, 1f);
        var yard = new IsoWorldRegion(true, 0.2f);
        IsoRegions.set(shed, 206, 200, 2, 2, 0);
        IsoRegions.set(porch, 208, 200, 1, 2, 0);
        IsoRegions.set(closet, 209, 200, 1, 2, 0);
        IsoRegions.set(yard, 200, 196, 4, 4, 0);
        IsoRegions.swap();
        for (int x = 206; x <= 209; x++) for (int y = 200; y <= 201; y++) square(x, y, 0);
        double version = (Double)call(buildings, "version").get(0);
        check(call(buildings, "version").get(0).equals(version), "The version changed with nothing changed");
        // Described once a version, whatever asks: the rooms' rectangles are many calls into the game.
        call(buildings, "rooms", key);
        int asked = barn.asked;
        call(buildings, "rooms", key);
        call(buildings, "at", 201.0, 201.0, 0.0);
        call(buildings, "near", key, 2.0);
        call(buildings, "attached", key);
        check(barn.asked == asked, "The barn was described again with nothing changed");
        KahluaTable spaces = (KahluaTable)call(buildings, "attached", key).get(0);
        check(spaces != null && spaces.len() == 1, "Not one built-on room");
        KahluaTable space = (KahluaTable)spaces.rawget(1.0);
        check(space.rawget("level").equals(0.0) && space.rawget("host").equals("701") && space.rawget("count").equals(6.0)
            && space.rawget("extent").equals(3.0), "The shed and porch were misdescribed");
        KahluaTable rects = (KahluaTable)space.rawget("rects");
        KahluaTable rect = (KahluaTable)rects.rawget(1.0);
        check(rects.len() == 1 && rect.rawget("x").equals(206.0) && rect.rawget("y").equals(200.0) && rect.rawget("w").equals(3.0)
            && rect.rawget("h").equals(2.0), "The shed and porch are not one rectangle");
        place(207, 201, 0, powered("shed lamp", 0.01f));
        place(209, 201, 0, powered("closet lamp", 0.01f));
        var inside = call(buildings, "attachedObjects", key);
        check(sprites(inside.get(0)).equals(Set.of("shed lamp")) && inside.get(1).equals(true),
            "Wrong objects in the built-on rooms: " + sprites(inside.get(0)));
        KahluaTable lamp = find(inside.get(0), "shed lamp");
        check(lamp.rawget("roomId").equals("701") && lamp.rawget("room").equals("store"), "The shed's lamp is not in the store");
        check(sprites(call(buildings, "attachedObjects", key, "water").get(0)).isEmpty(), "The water filter let a lamp through");
        check(((KahluaTable)call(buildings, "attached", "20,20,0").get(0)).len() == 0, "The shack, built by a player, has built-on rooms");
        check(call(buildings, "attached", "1,1,0").get(0) == null, "A key of no building has built-on rooms");
        // The game reads only the region data its worker handed over: until it is swapped in, the shed is as it was.
        shed.roofed = 0.1f;
        check(((KahluaTable)call(buildings, "attached", key).get(0)).len() == 1, "Region data not swapped in was read");
        IsoRegions.swap();
        frame();
        check(!call(buildings, "version").get(0).equals(version), "The version stayed as the region data changed");
        call(buildings, "rooms", key);
        check(barn.asked == asked + 1, "The barn was not described again for the new version");
        check(((KahluaTable)call(buildings, "attached", key).get(0)).len() == 0, "A shed with its roof gone is still a room");
        // A hangar of 1600 squares against a silo is no room anyone built.
        var silo = new BuildingDef(false);
        var bins = new RoomDef(702, "silo", 0, silo);
        room(grid, bins, 300, 300, 2, 2);
        var hangar = new IsoWorldRegion(true, 1f);
        IsoRegions.set(hangar, 302, 280, 40, 40, 0);
        IsoRegions.swap();
        check(call(buildings, "attached", "300,300,0").get(0) == null, "A space larger than any room was taken for one");
        var none = call(buildings, "attachedObjects", "300,300,0");
        check(none.get(0) == null && none.get(1).equals(false), "A space larger than any room has objects");
        square(207, 201, 0).objects.clear();
        square(209, 201, 0).objects.clear();
        for (var region : new Object[][] { { 206, 200, 4, 2 }, { 200, 196, 4, 4 }, { 302, 280, 40, 40 } })
            IsoRegions.set(null, (int)region[0], (int)region[1], (int)region[2], (int)region[3], 0);
        IsoRegions.swap();
        grid.rooms.removeAll(List.of(hall, store, bins));
    }

    /**
     * The house's shell: a lamp on its outer wall stands outside, on the square beyond the wall, but is the house's, and
     * so is one standing against the wall and one on the roof (the room under it): listed with it, not near it, and
     * powered with it, as the squares themselves are. One a square further out stays outside.
     */
    private static void wallLamps(KahluaTable api, KahluaTable buildings) throws Exception {
        // On the kitchen's east wall, which is the west edge of the square beyond.
        var lamp = powered("wall lamp", 0.004f);
        lamp.sprite.properties.flags.add(IsoFlagType.attachedW);
        place(14, 11, 0, lamp);
        var standing = place(14, 12, 0, powered("standing lamp", 0.004f));
        var roofLamp = place(12, 11, 2, powered("roof lamp", 0.004f));
        var yard = place(16, 12, 0, powered("yard lamp", 0.004f));
        KahluaTable objects = (KahluaTable)call(buildings, "objects", KEY, "power").get(0);
        KahluaTable listed = find(objects, "wall lamp");
        check(listed != null && listed.rawget("room").equals("kitchen") && listed.rawget("x").equals(14.0),
            "A lamp on the outer wall is not the house's");
        check(find(objects, "standing lamp") != null && find(objects, "standing lamp").rawget("room").equals("kitchen")
            && find(objects, "roof lamp") != null && find(objects, "roof lamp").rawget("room").equals("bedroom")
            && !sprites(objects).contains("yard lamp"), "The house's shell is wrong: " + sprites(objects));
        var around = sprites(call(buildings, "near", KEY, 3.0).get(0));
        check(around.contains("yard lamp") && !around.contains("standing lamp"), "Wrong objects around the house: " + around);

        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "lamp.mod").get(0);
        var generator = place(7, 33, 0, new IsoGenerator(new IsoSprite("generator")));
        call(networks, "define", mod, "lamps", "power", "sequential");
        call(networks, "setProducers", mod, "lamps", list(at(7, 33, 0)));
        call(networks, "addBuilding", mod, "lamps", 11.0, 11.0, 0.0);
        generator.setActivated(true);
        frame();
        check(ItemContainer.isObjectPowered(lamp, true) && !ItemContainer.isObjectPowered(lamp, false)
            && ItemContainer.isObjectPowered(standing, true) && ItemContainer.isObjectPowered(roofLamp, true)
            && !ItemContainer.isObjectPowered(yard, true), "The house's shell has no power, or the yard has");
        check(Hooks.squarePowered(false, 14, 12, 0) && Hooks.squarePowered(false, 12, 11, 2) && !Hooks.squarePowered(false, 16, 12, 0),
            "The squares of the house's shell have no power, or one further out has");
        check(sprites(call(networks, "consumers", "lamps").get(0)).contains("wall lamp"), "The lamp on the outer wall is no consumer");
        call(networks, "exclude", mod, "lamps", 14.0, 11.0, 0.0, "wall lamp");
        frame();
        check(!ItemContainer.isObjectPowered(lamp, true), "An excluded lamp on the outer wall has power");
        call(networks, "remove", mod, "lamps");
        generator.setActivated(false);
        frame();
        square(14, 11, 0).objects.clear();
        square(14, 12, 0).objects.clear();
        square(12, 11, 2).objects.clear();
        square(16, 12, 0).objects.clear();
        square(7, 33, 0).objects.clear();
    }

    private static void callerErrors(KahluaTable buildings) {
        error(buildings, "at", "x must be a whole number", "a", 1.0, 0.0);
        error(buildings, "at", "z must be a whole number", 1.0, 1.0, 0.5);
        error(buildings, "near", "tiles must be a whole number from 0 to 32", KEY, 33.0);
        error(buildings, "objects", "filter must be nil", KEY, "gas");
        error(buildings, "rooms", "key must be a string", 1.0);
    }

    private static void clients(KahluaTable api) {
        KahluaTable first = (KahluaTable)call(api, "client", "example.mod").get(0);
        check(first.rawget("name").equals("example.mod") && call(api, "client", "example.mod").get(0) == first,
            "A mod got two handles for one name");
        Object clear = ((KahluaTable)first.getMetatable().rawget("__index")).rawget("clear");
        check(invoke(clear, first).isEmpty(), "Clearing a handle failed");
        try { invoke(clear, (Object)null); throw new AssertionError("clear without a handle was accepted"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("with a colon"), expected.getMessage()); }
        try { call(api, "client", "no spaces"); throw new AssertionError("A bad name was accepted"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("PZExtAPI.client"), expected.getMessage()); }
    }

    /**
     * A power network over the house: two generators outside it, the first in use. The house's squares and its
     * appliances get power from it, the generators power nothing around themselves, and objects are excluded from it
     * or added to it on their own.
     */
    private static void networks(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        check(networks != null, "The networks area is missing");
        for (int x = 5; x <= 35; x++) for (int y = 5; y <= 35; y++) square(x, y, 0);
        var radio = place(12, 10, 0, new IsoRadio(new IsoSprite("radio")));
        var freezer = place(12, 12, 0, powered("freezer a", 0.05f));
        var freezerEnd = place(13, 12, 0, powered("freezer b", 0.05f));
        freezer.gridParts.add(freezerEnd);
        freezerEnd.gridParts.add(freezer);
        IsoObject fridge = square(11, 11, 0).objects.get(0), light = square(15, 11, 0).objects.get(0);
        var kitchenSwitch = (IsoLightSwitch)square(11, 13, 0).objects.get(0);
        var first = place(30, 30, 0, new IsoGenerator(new IsoSprite("generator")));
        var second = place(31, 30, 0, new IsoGenerator(new IsoSprite("generator")));
        first.setActivated(true);
        check(square(28, 30, 0).haveElectricity() && !square(11, 11, 0).haveElectricity(), "The game's own generator range is wrong");

        Object mod = call(api, "client", "power.mod").get(0);
        check(call(networks, "define", mod, "grid", "power", "sequential").isEmpty(), "define returned something");
        call(networks, "setProducers", mod, "grid", list(at(30, 30, 0), at(31, 30, 0)));
        check(call(networks, "addBuilding", mod, "grid", 11.0, 11.0, 0.0).get(0).equals(true), "The house was not found");
        check(call(networks, "addBuilding", mod, "grid", 12.0, 11.0, -1.0).get(0).equals(true), "The basement was not found");
        frame();
        check(!square(28, 30, 0).haveElectricity() && first.itemsPowered() == 0, "A network's generator kept its own range");
        check(square(11, 11, 0).haveElectricity() && square(12, 12, -1).haveElectricity() && new IsoGridSquare(10, 10, 1).haveElectricity(),
            "A level of the house has no power");
        check(!square(8, 11, 0).haveElectricity() && !square(11, 14, 0).haveElectricity(), "A square outside the house has power");
        check(square(9, 11, 0).haveElectricity() && square(14, 13, 0).haveElectricity(), "A square against the house's wall has no power");
        KahluaTable state = (KahluaTable)call(networks, "state", "grid").get(0);
        check(state.rawget("supplied").equals(true) && state.rawget("owner").equals("power.mod")
            && ((KahluaTable)state.rawget("producer")).rawget("x").equals(30.0) && state.rawget("complete").equals(false),
            "The network's state is wrong");
        double load = 0.08 + 0.002 + 0.01 + 0.05 + 0.05;
        check(near((Double)state.rawget("load"), load), "The load is wrong: " + state.rawget("load"));
        check(near(first.getTotalPowerUsing(), (0.02 + load) * 0.1) && near(second.getTotalPowerUsing(), 0.02 * 0.1), "A producer burns the wrong amount");
        // Worked out again with nothing changed, the generators are left alone.
        int sets = first.consumptionSets;
        call(networks, "addBuilding", mod, "grid", 11.0, 11.0, 0.0);
        frame();
        check(first.consumptionSets == sets, "An unchanged consumption was set again");
        var consumers = call(networks, "consumers", "grid");
        check(sprites(consumers.get(0)).equals(Set.of("fridge", "kitchen switch", "radio", "freezer a", "freezer b"))
            && consumers.get(1).equals(false), "Wrong consumers: " + sprites(consumers.get(0)));
        check(ItemContainer.isObjectPowered(fridge, true) && !ItemContainer.isObjectPowered(fridge, false), "The fridge's power is wrong");
        check(kitchenSwitch.canSwitch() && radio.device.canBePoweredHere(), "The switch or the radio has no power");

        // Excluded: no power from the network, whatever its square has. Part of a two-square freezer excludes all of it.
        call(networks, "exclude", mod, "grid", 11.0, 11.0, 0.0, "fridge");
        call(networks, "exclude", mod, "grid", 13.0, 12.0, 0.0, "freezer b");
        call(networks, "exclude", mod, "grid", 11.0, 13.0, 0.0, "kitchen switch");
        frame();
        check(!ItemContainer.isObjectPowered(fridge, true) && !ItemContainer.isObjectPowered(freezer, true)
            && !kitchenSwitch.canSwitch(), "An excluded object has power");
        check(square(11, 11, 0).haveElectricity() && ItemContainer.isObjectPowered(radio, true), "Excluding objects cut the others");
        check(near(load(networks), 0.01), "Excluded objects still count: " + load(networks));
        // The game's own power still reaches an excluded object.
        var vanilla = place(12, 14, 0, new IsoGenerator(new IsoSprite("generator")));
        vanilla.setActivated(true);
        check(ItemContainer.isObjectPowered(fridge, true), "An excluded object lost the game's own power");
        vanilla.setActivated(false);
        call(networks, "exclude", mod, "grid", 12.0, 10.0, 0.0, "radio");
        frame();
        check(!radio.device.canBePoweredHere(), "An excluded radio has power");
        call(networks, "reset", mod, "grid", 12.0, 10.0, 0.0, "radio");
        // Added on its own: an object outside the house.
        check(!ItemContainer.isObjectPowered(light, true), "The street light has power before it was added");
        call(networks, "include", mod, "grid", 15.0, 11.0, 0.0, "street light");
        frame();
        check(ItemContainer.isObjectPowered(light, true) && !ItemContainer.isObjectPowered(light, false), "An added object has no power");
        check(near(load(networks), 0.012), "The added object does not count: " + load(networks));
        // One that uses nothing joining or leaving is told too: the load alone does not say the consumers changed.
        var sign = place(16, 11, 0, powered("sign", 0f));
        LuaEventManager.raised.clear();
        call(networks, "include", mod, "grid", 16.0, 11.0, 0.0, "sign");
        frame();
        check(raised("grid", "load", GameTime.getInstance().hours), "A consumer that uses nothing joined untold: " + LuaEventManager.raised);
        call(networks, "reset", mod, "grid", 16.0, 11.0, 0.0, "sign");
        frame();
        check(raised("grid", "load", GameTime.getInstance().hours), "A consumer that uses nothing left untold: " + LuaEventManager.raised);
        sign.square.objects.remove(sign);
        frame();
        // The game says when something that uses power changed.
        radio.consumption = 0.03f;
        IsoGenerator.updateGenerator(radio.square);
        frame();
        check(near(load(networks), 0.032), "A consumer's change was missed: " + load(networks));
        call(networks, "reset", mod, "grid", 11.0, 11.0, 0.0, "fridge");
        frame();
        check(ItemContainer.isObjectPowered(fridge, true) && near(load(networks), 0.112), "Reset did not give the fridge back");

        // A room's light: from a switch of the room, even one beyond the wall, outside the house; not an excluded one.
        var roomSwitches = List.of(kitchenSwitch);
        check(!LightingJNI.roomLit(roomSwitches), "An excluded switch lights its room");
        call(networks, "reset", mod, "grid", 11.0, 13.0, 0.0, "kitchen switch");
        frame();
        check(LightingJNI.roomLit(roomSwitches), "A switch beyond the wall does not light its room");
        call(networks, "exclude", mod, "grid", 11.0, 13.0, 0.0, "kitchen switch");
        var innerSwitch = place(13, 10, 0, new IsoLightSwitch(new IsoSprite("inner switch")));
        innerSwitch.roomId = 1;
        innerSwitch.powered = false;
        frame();
        check(LightingJNI.roomLit(List.of(innerSwitch)), "A switch in the room does not light it");
        call(networks, "exclude", mod, "grid", 13.0, 10.0, 0.0, "inner switch");
        frame();
        check(!LightingJNI.roomLit(List.of(innerSwitch)), "An excluded switch in the room lights it");
        // Food keeps cold in a fridge the network powers, not in an excluded one, whatever their squares have.
        var food = new Food(new ItemContainer(fridge));
        food.updateAge(false);
        check(food.chilled, "Food in a powered fridge is not chilled");
        var frozen = new Food(new ItemContainer(freezer));
        frozen.updateAge(false);
        check(!frozen.chilled && square(12, 12, 0).haveElectricity(), "Food in an excluded freezer is chilled");
        var outside = new Food(new ItemContainer(light));
        outside.updateAge(false);
        check(outside.chilled, "Food in an object added on its own is not chilled");

        // The first producer stops, and the second has no fuel: no supply until the next one runs, which then carries
        // the load.
        int checks = fridge.electricityChecks;
        second.fuel = 0;
        first.setActivated(false);
        frame();
        state = (KahluaTable)call(networks, "state", "grid").get(0);
        check(state.rawget("supplied").equals(false) && state.rawget("producer") == null && !square(11, 11, 0).haveElectricity()
            && !ItemContainer.isObjectPowered(light, true), "A network without a running producer has supply");
        call(networks, "reset", mod, "grid", 13.0, 10.0, 0.0, "inner switch");
        frame();
        food.updateAge(false);
        check(!LightingJNI.roomLit(List.of(innerSwitch)) && !food.chilled, "A room is lit or food chilled without supply");
        check(fridge.electricityChecks > checks, "The consumers were not told that the power went");
        second.fuel = 10;
        second.setActivated(true);
        frame();
        state = (KahluaTable)call(networks, "state", "grid").get(0);
        check(((KahluaTable)state.rawget("producer")).rawget("x").equals(31.0) && square(11, 11, 0).haveElectricity()
            && !square(33, 30, 0).haveElectricity(), "The second producer does not carry the network");
        check(near(second.getTotalPowerUsing(), (0.02 + 0.112) * 0.1) && near(first.getTotalPowerUsing(), 0.02 * 0.1), "The load moved wrongly");

        // A handler that fails gives the game's answers; a newer API takes the definitions over.
        Hooks.setPower(new Hooks.Power() {
            @Override public boolean square(int x, int y, int z) { throw new IllegalStateException("broken"); }
            @Override public boolean object(boolean vanilla, Object object, int kind, boolean generators) { throw new IllegalStateException("broken"); }
            @Override public boolean generator(Object generator) { throw new IllegalStateException("broken"); }
            @Override public void consumerChanged(Object square) { throw new IllegalStateException("broken"); }
        });
        check(!square(11, 11, 0).haveElectricity() && !ItemContainer.isObjectPowered(fridge, true), "A failing hook did not give the game's answer");
        second.setSurroundingElectricity();
        check(square(33, 30, 0).haveElectricity(), "A failing hook did not let the game do the generator's range");
        GameApi.register(LuaManager.class);
        frame();
        check(api.rawget("networks") == networks && square(11, 11, 0).haveElectricity() && !square(33, 30, 0).haveElectricity()
            && ItemContainer.isObjectPowered(light, true), "A newer API did not take the networks over");

        // Each network belongs to its mod.
        Object other = call(api, "client", "other.mod").get(0);
        rejects(networks, "define", "grid belongs to another mod", other, "grid", "power", "sequential");
        rejects(networks, "addBuilding", "grid belongs to another mod", other, "grid", 1.0, 1.0, 0.0);
        call(networks, "define", other, "second", "power", "sequential");
        rejects(networks, "setProducers", "31,30,0 is a producer of the network grid", other, "second", list(at(31, 30, 0)));
        rejects(networks, "define", "utility must be \"power\" or \"water\"", mod, "x", "gas", "sequential");
        rejects(networks, "define", "policy for power must be \"sequential\"", mod, "x", "power", "parallel");
        rejects(networks, "define", "policy for water must be \"fullest\" or \"nearest\"", mod, "x", "water", "sequential");
        rejects(networks, "define", "id must be 1 to 64", mod, "no spaces", "power", "sequential");
        rejects(networks, "define", "the first argument must be a handle", "power.mod", "x", "power", "sequential");
        rejects(networks, "exclude", "sprite must be a sprite name", mod, "grid", 1.0, 1.0, 0.0, "");
        rejects(networks, "setProducers", "producers[1]: x must be a whole number", mod, "grid", list(LuaManager.platform.newTable()));
        rejects(networks, "setProducers", "is listed twice", mod, "grid", list(at(1, 1, 0), at(1, 1, 0)));
        rejects(networks, "include", "there is no network nothing", mod, "nothing", 1.0, 1.0, 0.0, "lamp");
        check(call(networks, "state", "nothing").get(0) == null && call(networks, "consumers", "nothing").get(0) == null,
            "A network that does not exist has a state");
        // Every network's id, as defined: what a look in the game lists.
        KahluaTable ids = (KahluaTable)call(networks, "ids").get(0);
        boolean listed = false;
        for (int i = 1; i <= ids.len(); i++) listed |= "grid".equals(ids.rawget(i));
        check(listed, "The ids leave out a network");

        // Removed: the generators are the game's again. A mod's handle clears what it defined.
        check(call(networks, "remove", mod, "grid").get(0).equals(true) && call(networks, "remove", mod, "grid").get(0).equals(false),
            "remove reported wrongly");
        frame();
        check(square(33, 30, 0).haveElectricity() && !square(11, 11, 0).haveElectricity(), "A removed network's generator has no range");
        call(networks, "define", mod, "grid", "power", "sequential");
        invoke(((KahluaTable)((KahluaTable)mod).getMetatable().rawget("__index")).rawget("clear"), mod);
        check(call(networks, "state", "grid").get(0) == null && call(networks, "state", "second").get(0) != null,
            "Clearing a handle removed the wrong networks");
        // Leaving the world removes its networks.
        var world = IsoWorld.instance;
        var cell = world.currentCell;
        world.setCell(null);
        frame();
        world.setCell(cell);
        frame();
        check(call(networks, "state", "second").get(0) == null, "A world's networks outlived it");
        second.setActivated(false);
    }

    /**
     * Under "sequential" one producer runs at a time. When it runs out, the next takes over from the hour it ran out,
     * also when its square was not loaded; the one switched on last carries the network; switched off, it stops it.
     * Each change is raised to Lua with the hour it happened.
     */
    private static void sequence(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        check(LuaEventManager.added.contains("OnPZExtNetworkChange"), "The networks' event was not added");
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 100;
        var first = place(33, 33, 0, new IsoGenerator(new IsoSprite("generator")));
        var second = place(34, 33, 0, new IsoGenerator(new IsoSprite("generator")));
        first.fuel = 1;
        call(networks, "define", mod, "seq", "power", "sequential");
        call(networks, "setProducers", mod, "seq", list(at(33, 33, 0), at(34, 33, 0)));
        call(networks, "addBuilding", mod, "seq", 11.0, 11.0, 0.0);
        frame();
        LuaEventManager.raised.clear();
        first.setActivated(true);
        frame();
        // The second, off when the API first saw it, is on standby.
        check(raised("supply", 100) && producer(networks) == 33.0 && !second.activated && !outOfService(networks, "seq", 2),
            "Switching the first on did not supply the network, or the second is out of service");
        // It burns its share hour by hour; it runs out in hour 100 + ceil(1 / per hour), and the second carries on from then.
        double perHour = first.getTotalPowerUsing();
        int out = 100 + (int)Math.ceil(1 / perHour);
        first.update();
        time.hours = 200.5;
        first.update();
        check(!first.activated && first.fuel == 0, "The first did not run out");
        frame();
        check(second.activated && second.lastHour() == out && producer(networks) == 34.0 && raised("producer", out),
            "The second did not take over from hour " + out + ": " + second.lastHour() + ", " + LuaEventManager.raised);
        second.update();
        check(near(second.fuel, 10 - (200 - out) * second.getTotalPowerUsing()), "The second did not burn the hours since: " + second.fuel);
        // The one switched on last carries it; the other is switched off.
        first.fuel = 5;
        first.setActivated(true);
        frame();
        check(first.activated && !second.activated && producer(networks) == 33.0 && raised("producer", 200.5), "The one switched on last does not carry it");
        // Not loaded: once its fuel would have run out, the next takes over from that hour.
        first.update();
        var settledHour = first.lastHour();
        var settledFuel = first.fuel;
        var settledPerHour = first.getTotalPowerUsing();
        var unloaded = IsoWorld.instance.currentCell.squares.remove("33,33,0");
        time.hours = 500;
        frame();
        int end = settledHour + (int)Math.ceil(settledFuel / settledPerHour);
        check(second.activated && second.lastHour() == end && producer(networks) == 34.0 && raised("producer", end),
            "The next did not take over from the hour an unloaded producer ran out: " + second.lastHour() + " for " + end);
        IsoWorld.instance.currentCell.squares.put("33,33,0", unloaded);
        first.update();
        frame();
        check(!first.activated && second.activated, "The first ran again after it loaded");
        // Switched off by the player, with no other on standby that can run (the first is empty): the network stops.
        check(!outOfService(networks, "seq", 1) && first.fuel == 0, "The first, empty after it loaded, is out of service");
        second.setActivated(false);
        frame();
        check(!first.activated && !second.activated && Double.isNaN(producer(networks)) && raised("supply", 500), "Switching off did not stop the network");
        // The load changing is raised too.
        second.setActivated(true);
        frame();
        var radio = (IsoObject)square(12, 10, 0).objects.get(0);
        radio.consumption = 0.05f;
        IsoGenerator.updateGenerator(radio.square);
        frame();
        check(raised("load", 500), "A load change was not raised");
        // Refuelled and switched on: the first carries it, and the API switches the second off, on standby.
        time.hours = 600;
        first.fuel = 0.5f;
        first.setActivated(true);
        frame();
        check(producer(networks) == 33.0 && !second.activated && !outOfService(networks, "seq", 2), "The second is out of service");
        call(networks, "remove", mod, "seq");
        frame();
        // A world loaded with the first still running: the game makes up for the hours away as the first updates,
        // before a frame worked the network out. The second takes over from the hour the first ran out.
        double savedPerHour = first.getTotalPowerUsing();
        time.hours = 1000;
        call(networks, "define", mod, "seq", "power", "sequential");
        call(networks, "setProducers", mod, "seq", list(at(33, 33, 0), at(34, 33, 0)));
        call(networks, "addBuilding", mod, "seq", 11.0, 11.0, 0.0);
        LuaEventManager.raised.clear();
        first.update();
        frame();
        int ranOut = 600 + (int)Math.ceil(0.5 / savedPerHour);
        check(!first.activated && second.activated && second.lastHour() == ranOut && raised("supply", ranOut),
            "After a load the second did not take over from hour " + ranOut + ": " + second.lastHour());
        call(networks, "remove", mod, "seq");
        frame();
        second.setActivated(false);
    }

    /**
     * A generator running on a square that is not loaded is run hour by hour by the API: its fuel, its wear at its item's
     * chance, and at condition 20 or below a breakdown, which switches it off at condition 0 in that hour, without fire;
     * the next takes over from then. As its square loads, the generator takes what the API found, and the game burns no
     * hour twice. One still running there carries on, its fuel burned.
     */
    private static void generatorAway(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 2000;
        var worn = place(36, 33, 0, new IsoGenerator(new IsoSprite("generator")));
        var spare = place(37, 33, 0, new IsoGenerator(new IsoSprite("generator")));
        worn.condition = 25;
        worn.itemType = "Base.Generator_Yellow";
        call(networks, "define", mod, "seq", "power", "sequential");
        call(networks, "setProducers", mod, "seq", list(at(36, 33, 0), at(37, 33, 0)));
        call(networks, "addBuilding", mod, "seq", 11.0, 11.0, 0.0);
        worn.setActivated(true);
        frame();
        worn.update();
        float perHour = worn.getTotalPowerUsing(), fuel = worn.fuel;
        var bounds = new ArrayList<Integer>();
        // Every roll hits: it wears by 1 an hour, and at 20 it catches fire.
        PowerGrid.dice = bound -> { bounds.add(bound); return 0; };
        var squares = IsoWorld.instance.currentCell.squares;
        var away = squares.remove("36,33,0");
        LuaEventManager.raised.clear();
        time.hours = 2010.5;
        frame();
        check(spare.activated && spare.lastHour() == 2005 && producer(networks) == 37.0 && raised("producer", 2005) && bounds.contains(36),
            "The next did not take over from the hour the generator broke down away: " + spare.lastHour() + ", " + bounds);
        var state = (KahluaTable)((KahluaTable)state(networks, "seq").rawget("producers")).rawget(1.0);
        check(state.rawget("running").equals(false) && state.rawget("condition").equals(0.0)
            && near((Double)state.rawget("fuel"), fuel - 5 * perHour), "The state does not show the breakdown: " + state.rawget("condition"));
        // Loaded: it takes what was found, before the game's own update, and it is on standby, not out of service.
        squares.put("36,33,0", away);
        frame();
        worn.update();
        check(!worn.activated && worn.condition == 0 && near(worn.fuel, fuel - 5 * perHour) && worn.lastHour() == 2005 && spare.activated
            && !outOfService(networks, "seq", 1) && worn.getModData().rawget(PowerGrid.RUNNING) == null,
            "The loaded generator did not take its breakdown: " + worn.condition + ", " + worn.lastHour());
        // Still running there: it carries on, burning hour by hour from the hour the game last burned it up to.
        PowerGrid.dice = bound -> bound - 1;
        float spareFuel = spare.fuel;
        spare.update();
        float sparePerHour = spare.getTotalPowerUsing();
        var spareSquare = squares.remove("37,33,0");
        time.hours = 2013.5;
        frame();
        check(producer(networks) == 37.0, "A generator running away stopped");
        squares.put("37,33,0", spareSquare);
        frame();
        spare.update();
        check(spare.activated && spare.lastHour() == 2013 && near(spare.fuel, spareFuel - 8 * sparePerHour),
            "The loaded generator burned the hours away again: " + spare.fuel + " for " + (spareFuel - 8 * sparePerHour));
        call(networks, "remove", mod, "seq");
        frame();
        spare.setActivated(false);
    }

    /**
     * As the world is saved (OnSave), what the networks know goes into its ModData; loaded again, the networks its mods
     * define again know which producer is in use, also one whose square is not loaded, and how it was running.
     */
    private static void savedState(KahluaTable api) throws Exception {
        // The game's Events.OnSave, which the API adds a handler to as it registers.
        var handlers = new ArrayList<Object>();
        KahluaTable events = LuaManager.platform.newTable(), onSave = LuaManager.platform.newTable();
        onSave.rawset("Add", (JavaFunction)(frame, count) -> { handlers.add(frame.get(0)); return 0; });
        events.rawset("OnSave", onSave);
        LuaManager.env.rawset("Events", events);
        GameApi.register(LuaManager.class);
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        check(handlers.size() == 1, "The API added no OnSave handler: " + handlers.size());
        var time = GameTime.getInstance();
        time.hours = 3000;
        var far = place(38, 33, 0, new IsoGenerator(new IsoSprite("generator")));
        Runnable define = () -> {
            call(networks, "define", mod, "seq", "power", "sequential");
            call(networks, "setProducers", mod, "seq", list(at(38, 33, 0)));
            call(networks, "addBuilding", mod, "seq", 11.0, 11.0, 0.0);
        };
        define.run();
        far.setActivated(true);
        frame();
        far.update();
        var squares = IsoWorld.instance.currentCell.squares;
        var away = squares.remove("38,33,0");
        frame();
        invoke(handlers.get(0));
        check(ModData.get(Networks.SAVED) != null && ModData.get(Networks.SAVED).rawget("state") instanceof String,
            "The networks were not saved into the world's ModData");
        // The world loaded again, the generator's square still not loaded.
        var world = IsoWorld.instance;
        var cell = world.currentCell;
        world.setCell(null);
        frame();
        world.setCell(cell);
        frame();
        define.run();
        frame();
        check(producer(networks) == 38.0 && state(networks, "seq").rawget("supplied").equals(true),
            "A world loaded again does not know the producer in use far away: " + producer(networks));
        time.hours = 3005.5;
        frame();
        check(producer(networks) == 38.0, "The far producer stopped after the world was loaded again");
        squares.put("38,33,0", away);
        call(networks, "remove", mod, "seq");
        frame();
        far.setActivated(false);
        ModData.tables.remove(Networks.SAVED);
    }

    /**
     * A generator switched, by hand or out of fuel, is raised to Lua twice: before the game switches it, while its
     * squares have the power they had, and once they took the new. Switched to what it is already, nothing.
     */
    private static void generatorSwitches() {
        check(LuaEventManager.added.contains("OnPZExtGeneratorPower"), "The generators' event was not added");
        var generator = place(22, 8, 0, new IsoGenerator(new IsoSprite("generator")));
        var near = square(22, 10, 0);
        var seen = new ArrayList<String>();
        LuaEventManager.listener = event -> {
            if (event.get(0).equals("OnPZExtGeneratorPower") && event.get(1) == generator)
                seen.add(event.get(2) + "/" + event.get(3) + "/" + near.haveElectricity() + "/" + generator.activated);
        };
        try {
            generator.setActivated(true);
            check(seen.equals(List.of("true/false/false/false", "true/true/true/true")),
                "Switching on was not raised before and after: " + seen);
            seen.clear();
            generator.setActivated(true);
            check(seen.isEmpty(), "Switching on what runs was raised: " + seen);
            generator.fuel = 0.001f;
            generator.update();
            GameTime.getInstance().hours += 2;
            generator.update();
            check(!generator.activated && seen.equals(List.of("false/false/true/true", "false/true/false/false")),
                "Running out of fuel was not raised before and after: " + seen);
            GameTime.getInstance().hours -= 2;
        } finally {
            LuaEventManager.listener = null;
            LuaEventManager.raised.clear();
            generator.square.objects.remove(generator);
        }
    }

    /**
     * What the game takes of the world's items by itself. A fire empties each container of a burnt object: each is raised to
     * Lua before, with its object, the items still in it. The sandbox's world item removal keeps, besides what the game's own
     * flag keeps, a floor item whose mod data has PZExtKeep and a bag that holds one at any depth.
     */
    private static void worldItems() {
        check(LuaEventManager.added.contains("OnPZExtContainerBurning"), "The burning event was not added");
        var crate = place(24, 8, 0, new IsoObject(new IsoSprite("crate")));
        var container = new ItemContainer(crate);
        crate.containers.add(container);
        var paper = new InventoryItem("Literature", 0.1f);
        container.AddItem(paper);
        var seen = new ArrayList<String>();
        LuaEventManager.listener = event -> {
            if (event.get(0).equals("OnPZExtContainerBurning"))
                seen.add((event.get(1) == container) + "/" + (event.get(2) == crate) + "/" + container.contains(paper));
        };
        try {
            crate.square.BurnWalls(false, true);
            check(seen.equals(List.of("true/true/true")), "The burning was not raised before the items went: " + seen);
            check(crate.getContainerCount() == 0 && !container.contains(paper), "The fire did not empty the container");
        } finally {
            LuaEventManager.listener = null;
            LuaEventManager.raised.clear();
            crate.square.objects.remove(crate);
        }

        var square = square(24, 9, 0);
        var plain = new IsoWorldInventoryObject(new InventoryItem("Literature", 0.1f));
        var placed = new IsoWorldInventoryObject(new InventoryItem("Literature", 0.1f));
        placed.setIgnoreRemoveSandbox(true);
        var marked = new InventoryItem("Literature", 0.1f);
        marked.getModData().rawset("PZExtKeep", true);
        var kept = new IsoWorldInventoryObject(marked);
        var bag = new InventoryContainer("Container", 0.5f, 10);
        var inner = new InventoryContainer("Container", 0.2f, 5);
        var deep = new InventoryItem("Literature", 0.1f);
        deep.getModData().rawset("PZExtKeep", 1.0);
        inner.getInventory().AddItem(deep);
        bag.getInventory().AddItem(inner);
        var holding = new IsoWorldInventoryObject(bag);
        var other = new InventoryItem("Literature", 0.1f);
        other.getModData().rawset("Other", true);
        var unmarked = new IsoWorldInventoryObject(other);
        square.saved.addAll(List.of(plain, placed, kept, holding, unmarked));
        square.load(null, 0, false);
        var loaded = new ArrayList<IsoObject>();
        for (int index = 0; index < square.objects.size(); index++) loaded.add(square.objects.get(index));
        check(loaded.equals(List.of(placed, kept, holding)), "The removal kept the wrong floor items: " + loaded);
        for (IsoObject item : loaded) square.objects.remove(item);
    }

    /**
     * A child network takes its supply from its parent, whose producer carries both loads. The state tells each
     * producer as last seen and how long the fuel lasts at the load now.
     */
    private static void children(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        GameTime.getInstance().hours = 2000;
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        call(networks, "define", mod, "main", "power", "sequential");
        call(networks, "setProducers", mod, "main", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "main", 11.0, 11.0, 0.0);
        call(networks, "define", mod, "sub", "power", "sequential");
        call(networks, "addBuilding", mod, "sub", 20.0, 20.0, 0.0);
        call(networks, "setParent", mod, "sub", "main");
        frame();
        check(!square(21, 21, 0).haveElectricity() && !state(networks, "sub").rawget("supplied").equals(true), "A child has supply before its parent");
        // What a generator would burn at the load, also with nothing in use.
        KahluaTable idle = state(networks, "main");
        check(idle.rawget("hoursLeft") == null && near((Double)idle.rawget("fuelPerHour"), (0.02 + (Double)idle.rawget("load")) * 0.1),
            "The fuel an hour is wrong with nothing in use: " + idle.rawget("fuelPerHour"));
        LuaEventManager.raised.clear();
        generator.setActivated(true);
        frame();
        KahluaTable main = state(networks, "main"), sub = state(networks, "sub");
        check(sub.rawget("supplied").equals(true) && sub.rawget("parent").equals("main") && square(21, 21, 0).haveElectricity()
            && raised("sub", "supply", 2000) && raised("main", "supply", 2000), "The child has no supply with its parent: " + LuaEventManager.raised);
        LuaEventManager.raised.clear();
        double subLoad = (Double)sub.rawget("load"), ownLoad = (Double)main.rawget("ownLoad"), total = (Double)main.rawget("load");
        check(near(subLoad, 0.08) && near(total, ownLoad + subLoad), "The parent does not carry the child's load: " + total + ", " + ownLoad + ", " + subLoad);
        check(near(generator.getTotalPowerUsing(), (0.02 + total) * 0.1), "The producer does not burn both loads");
        check(near((Double)main.rawget("hoursLeft"), 6 / ((0.02 + total) * 0.1)) && main.rawget("hoursLeft").equals(sub.rawget("hoursLeft")),
            "Wrong hours left: " + main.rawget("hoursLeft"));
        check(near((Double)main.rawget("fuelPerHour"), (0.02 + total) * 0.1) && main.rawget("fuelPerHour").equals(sub.rawget("fuelPerHour")),
            "Wrong fuel an hour: " + main.rawget("fuelPerHour") + ", " + sub.rawget("fuelPerHour"));
        var producer = (KahluaTable)((KahluaTable)main.rawget("producers")).rawget(1.0);
        check(producer.rawget("x").equals(34.0) && producer.rawget("running").equals(true) && producer.rawget("fuel").equals(6.0)
            && producer.rawget("condition").equals(100.0), "A producer's state is wrong");
        // Nothing the API hears of changed: the networks are still worked out again once a second.
        generator.fuel = 3;
        Thread.sleep(1100);
        frame();
        producer = (KahluaTable)((KahluaTable)state(networks, "main").rawget("producers")).rawget(1.0);
        check(producer.rawget("fuel").equals(3.0), "The state was not worked out again after a second: " + producer.rawget("fuel"));
        // A tree of the mod's own networks of one utility; a child has no producers of its own.
        call(networks, "define", mod, "leaf", "power", "sequential");
        call(networks, "setParent", mod, "leaf", "sub");
        rejects(networks, "setParent", "leaf is a child of sub", mod, "sub", "leaf");
        rejects(networks, "setProducers", "sub is a child network", mod, "sub", list(at(33, 33, 0)));
        call(networks, "define", mod, "third", "power", "sequential");
        call(networks, "setProducers", mod, "third", list(at(33, 33, 0)));
        rejects(networks, "setParent", "third has producers; a child power network has none", mod, "third", "main");
        Object other = call(api, "client", "other.mod").get(0);
        call(networks, "define", other, "foreign", "power", "sequential");
        rejects(networks, "setParent", "main belongs to another mod", other, "foreign", "main");
        rejects(networks, "setParent", "there is no network none", mod, "sub", "none");
        // The parent removed: the child has no supply.
        call(networks, "remove", mod, "main");
        frame();
        sub = state(networks, "sub");
        check(sub.rawget("parent") == null && sub.rawget("supplied").equals(false) && !square(21, 21, 0).haveElectricity()
            && raised("sub", "supply", 2000), "The child kept its supply without its parent");
        for (String id : List.of("leaf", "sub", "third")) call(networks, "remove", mod, id);
        call(networks, "remove", other, "foreign");
        frame();
        generator.setActivated(false);
    }

    /**
     * A network switched off has no supply, nor have its children; the API switches its producer off, and its load still
     * reads. A child switched off leaves its parent's producer running. Food in its fridge ages unchilled for the hours
     * it was off, and a newer API keeps the switch.
     */
    private static void switches(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 2500;
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        IsoObject fridge = square(11, 11, 0).objects.get(0);
        var container = new ItemContainer(fridge);
        container.fridge = true;
        call(networks, "define", mod, "main", "power", "sequential");
        call(networks, "setProducers", mod, "main", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "main", 11.0, 11.0, 0.0);
        call(networks, "define", mod, "sub", "power", "sequential");
        call(networks, "addBuilding", mod, "sub", 20.0, 20.0, 0.0);
        call(networks, "setParent", mod, "sub", "main");
        generator.setActivated(true);
        frame();
        var food = aged(container, 2500);
        KahluaTable main = state(networks, "main"), sub = state(networks, "sub");
        check(main.rawget("enabled").equals(true) && sub.rawget("supplied").equals(true), "A network starts switched off");
        double ownLoad = (Double)main.rawget("ownLoad"), subLoad = (Double)sub.rawget("load");
        // The child off: the parent carries its own load alone.
        LuaEventManager.raised.clear();
        call(networks, "setEnabled", mod, "sub", false);
        frame();
        main = state(networks, "main");
        sub = state(networks, "sub");
        check(sub.rawget("enabled").equals(false) && sub.rawget("supplied").equals(false) && !square(21, 21, 0).haveElectricity()
            && sub.rawget("hoursLeft") == null && raised("sub", "supply", 2500), "A child switched off has supply");
        check(near((Double)sub.rawget("load"), subLoad) && near((Double)main.rawget("load"), ownLoad)
            && main.rawget("supplied").equals(true) && square(11, 11, 0).haveElectricity(), "The parent still carries the child switched off");
        check(near(generator.getTotalPowerUsing(), (0.02 + ownLoad) * 0.1), "The producer burns the load of a child switched off");
        // The parent off for ten hours: neither has supply, and the API switches its producer off, on standby.
        call(networks, "setEnabled", mod, "sub", true);
        time.hours = 2510;
        call(networks, "setEnabled", mod, "main", false);
        frame();
        main = state(networks, "main");
        check(main.rawget("supplied").equals(false) && state(networks, "sub").rawget("supplied").equals(false)
            && !square(11, 11, 0).haveElectricity() && !square(21, 21, 0).haveElectricity(), "A network switched off has supply");
        check(!generator.isActivated() && main.rawget("producer") == null && !outOfService(networks, "main", 1)
            && near((Double)main.rawget("load"), ownLoad + subLoad), "Switched off, the producer still runs, or the load no longer reads");
        rejects(networks, "setEnabled", "on must be true or false", mod, "main", "yes");
        Object other = call(api, "client", "other.mod").get(0);
        rejects(networks, "setEnabled", "main belongs to another mod", other, "main", true);
        time.hours = 2520;
        call(networks, "setEnabled", mod, "main", true);
        frame();
        check(state(networks, "main").rawget("supplied").equals(true) && square(21, 21, 0).haveElectricity() && generator.isActivated()
            && generator.lastHour() == 2520, "Switched on again, no supply, or its producer did not start again");
        time.hours = 2530;
        food.updateAge(false);
        check(near(food.age, (20 * 0.2 + 10) / 24), "Food aged chilled while the network was switched off: " + food.age * 24);
        // A newer API keeps the switch, and counts a network it finds switched off as off before.
        call(networks, "setEnabled", mod, "main", false);
        GameApi.register(LuaManager.class);
        frame();
        check(state(networks, "main").rawget("enabled").equals(false) && !square(11, 11, 0).haveElectricity(), "A newer API lost the switch");
        time.hours = 2540;
        food = aged(container, 2530);
        food.updateAge(false);
        check(near(food.age, 10 / 24.0), "Food aged chilled in a network a newer API found switched off: " + food.age * 24);
        call(networks, "remove", mod, "sub");
        call(networks, "remove", mod, "main");
        frame();
        generator.setActivated(false);
    }

    /**
     * A load factor multiplies the load of a network and its children on its way to the producer: the state, the fuel
     * burned and the hours left follow it, a child's factor counts inside its parent's, and a newer API keeps it.
     */
    private static void loadFactors(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        call(networks, "define", mod, "main", "power", "sequential");
        call(networks, "setProducers", mod, "main", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "main", 11.0, 11.0, 0.0);
        call(networks, "define", mod, "sub", "power", "sequential");
        call(networks, "addBuilding", mod, "sub", 20.0, 20.0, 0.0);
        call(networks, "setParent", mod, "sub", "main");
        generator.setActivated(true);
        frame();
        KahluaTable main = state(networks, "main");
        double ownLoad = (Double)main.rawget("ownLoad"), subLoad = (Double)state(networks, "sub").rawget("load");
        double hoursLeft = (Double)main.rawget("hoursLeft");
        check(main.rawget("loadFactor").equals(1.0) && near((Double)main.rawget("load"), ownLoad + subLoad), "A network starts with a load factor");
        LuaEventManager.raised.clear();
        call(networks, "setLoadFactor", mod, "main", 1.5);
        frame();
        main = state(networks, "main");
        double load = (ownLoad + subLoad) * 1.5;
        check(main.rawget("loadFactor").equals(1.5) && near((Double)main.rawget("load"), load) && near((Double)main.rawget("ownLoad"), ownLoad)
            && raised("main", "load", GameTime.getInstance().hours), "The load factor does not multiply the load");
        check(near(generator.getTotalPowerUsing(), (0.02 + load) * 0.1), "The producer does not burn the multiplied load");
        check((Double)main.rawget("hoursLeft") < hoursLeft, "The hours left do not follow the load factor");
        // A child's factor counts inside its parent's.
        call(networks, "setLoadFactor", mod, "sub", 2.0);
        frame();
        check(near((Double)state(networks, "sub").rawget("load"), subLoad * 2)
            && near((Double)state(networks, "main").rawget("load"), (ownLoad + subLoad * 2) * 1.5), "A child's load factor does not count in its parent");
        rejects(networks, "setLoadFactor", "factor must be a number from 0.0 to 100.0", mod, "main", -1.0);
        rejects(networks, "setLoadFactor", "factor must be a number from 0.0 to 100.0", mod, "main", "more");
        rejects(networks, "setLoadFactor", "factor must be a number from 0.0 to 100.0", mod, "main", 101.0);
        Object other = call(api, "client", "other.mod").get(0);
        rejects(networks, "setLoadFactor", "main belongs to another mod", other, "main", 1.0);
        call(networks, "define", mod, "pipes", "water", "fullest");
        rejects(networks, "setLoadFactor", "pipes carries water, which has no load", mod, "pipes", 1.0);
        call(networks, "remove", mod, "pipes");
        // A newer API keeps the factors.
        GameApi.register(LuaManager.class);
        frame();
        check(state(networks, "main").rawget("loadFactor").equals(1.5) && state(networks, "sub").rawget("loadFactor").equals(2.0),
            "A newer API lost the load factors");
        call(networks, "remove", mod, "sub");
        call(networks, "remove", mod, "main");
        frame();
        generator.setActivated(false);
    }

    /**
     * Under gridFirst the game's grid carries what it powers while it runs: the consumers on its squares leave the
     * network's load (the state tells what the grid carries) and those on a square it never powers stay; with the grid
     * shut off, the load comes back. A newer API keeps the switch.
     */
    private static void gridFirst(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        call(networks, "define", mod, "main", "power", "sequential");
        call(networks, "setProducers", mod, "main", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "main", 11.0, 11.0, 0.0);
        generator.setActivated(true);
        var options = SandboxOptions.instance;
        options.powerGrid = true;
        frame();
        KahluaTable main = state(networks, "main");
        double ownLoad = (Double)main.rawget("ownLoad");
        check(ownLoad > 0.08 && main.rawget("gridFirst").equals(false) && main.rawget("grid").equals(true)
            && near((Double)main.rawget("gridLoad"), 0), "Without gridFirst the grid carried a network's load");
        // The fridge's square is the grid's; the others never have its power.
        var off = new ArrayList<IsoGridSquare>();
        for (int z = -1; z <= 0; z++) for (int x = 5; x <= 25; x++) for (int y = 5; y <= 25; y++) {
            IsoGridSquare square = square(x, y, z);
            if (square != square(11, 11, 0)) { square.noPower = true; off.add(square); }
        }
        LuaEventManager.raised.clear();
        call(networks, "setGridFirst", mod, "main", true);
        frame();
        main = state(networks, "main");
        check(main.rawget("gridFirst").equals(true) && near((Double)main.rawget("ownLoad"), ownLoad - 0.08)
            && near((Double)main.rawget("gridLoad"), 0.08) && raised("main", "load", GameTime.getInstance().hours),
            "Under gridFirst the grid does not carry the fridge, or carries more");
        check(near(generator.getTotalPowerUsing(), (0.02 + ownLoad - 0.08) * 0.1), "The producer burns what the grid carries");
        // Shut off, the grid carries nothing (seen within a second).
        options.powerGrid = false;
        Thread.sleep(1100);
        frame();
        main = state(networks, "main");
        check(main.rawget("grid").equals(false) && near((Double)main.rawget("ownLoad"), ownLoad) && near((Double)main.rawget("gridLoad"), 0),
            "With the grid shut off the load did not come back");
        options.powerGrid = true;
        Thread.sleep(1100);
        frame();
        check(near((Double)state(networks, "main").rawget("gridLoad"), 0.08), "With the grid back the fridge is not its again");
        rejects(networks, "setGridFirst", "on must be true or false", mod, "main", "yes");
        Object other = call(api, "client", "other.mod").get(0);
        rejects(networks, "setGridFirst", "main belongs to another mod", other, "main", false);
        // A newer API keeps the switch.
        GameApi.register(LuaManager.class);
        frame();
        check(state(networks, "main").rawget("gridFirst").equals(true) && near((Double)state(networks, "main").rawget("gridLoad"), 0.08),
            "A newer API lost gridFirst");
        call(networks, "setGridFirst", mod, "main", false);
        frame();
        check(near((Double)state(networks, "main").rawget("ownLoad"), ownLoad) && near((Double)state(networks, "main").rawget("gridLoad"), 0),
            "Switched off, gridFirst still left the fridge to the grid");
        for (IsoGridSquare square : off) square.noPower = false;
        options.powerGrid = false;
        call(networks, "remove", mod, "main");
        frame();
        generator.setActivated(false);
    }

    /**
     * A network can take single rooms of a building instead of all of it: only their squares have power and only their
     * objects are its consumers. A room named again, or of a building it takes whole, changes nothing; a newer API
     * keeps them.
     */
    private static void memberRooms(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        call(networks, "define", mod, "flat", "power", "sequential");
        call(networks, "setProducers", mod, "flat", list(at(34, 33, 0)));
        check(call(networks, "addRoom", mod, "flat", 11.0, 11.0, 0.0).get(0).equals(true), "A room's square was not in a room");
        check(call(networks, "addRoom", mod, "flat", 0.0, 0.0, 0.0).get(0).equals(false), "A square of no room was in a room");
        generator.setActivated(true);
        frame();
        Object consumers = call(networks, "consumers", "flat").get(0);
        check(square(11, 11, 0).haveElectricity() && !square(11, 11, -1).haveElectricity() && !square(21, 21, 0).haveElectricity(),
            "Power reached past the kitchen, or not into it");
        check(sprites(consumers).contains("fridge") && !sprites(consumers).contains("shack fridge"), "The kitchen's consumers were wrong: " + sprites(consumers));
        double kitchen = (Double)state(networks, "flat").rawget("ownLoad");
        // The basement too, named by another of its squares; then without it again.
        call(networks, "addRoom", mod, "flat", 12.0, 12.0, -1.0);
        call(networks, "addRoom", mod, "flat", 11.0, 11.0, -1.0);
        frame();
        check(square(11, 11, -1).haveElectricity() && square(11, 11, 0).haveElectricity(), "A second room did not get power");
        check(near((Double)state(networks, "flat").rawget("ownLoad"), kitchen), "The basement changed the load");
        // A newer API keeps the rooms.
        GameApi.register(LuaManager.class);
        frame();
        check(square(11, 11, -1).haveElectricity() && square(11, 11, 0).haveElectricity(), "A newer API lost the rooms");
        check(call(networks, "removeRoom", mod, "flat", 12.0, 11.0, -1.0).get(0).equals(true), "Removing a room by another square failed");
        check(call(networks, "removeRoom", mod, "flat", 12.0, 11.0, -1.0).get(0).equals(false), "A room was removed twice");
        frame();
        check(!square(11, 11, -1).haveElectricity() && square(11, 11, 0).haveElectricity(), "The removed room kept power");
        // The whole building: a room of it named too changes nothing.
        call(networks, "addBuilding", mod, "flat", 11.0, 11.0, 0.0);
        frame();
        check(square(11, 11, -1).haveElectricity() && square(11, 11, 0).haveElectricity(), "The whole building lost a room");
        Object other = call(api, "client", "other.mod").get(0);
        rejects(networks, "addRoom", "flat belongs to another mod", other, "flat", 11.0, 11.0, 0.0);
        call(networks, "remove", mod, "flat");
        frame();
        generator.setActivated(false);
    }

    /**
     * A network's buildings can be any distance apart: one a million squares west and south of the house, on two levels,
     * is powered with it, and the squares between are not.
     */
    private static void farApart(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var grid = IsoWorld.instance.metaGrid;
        var far = new BuildingDef(false);
        var hall = new RoomDef(500, "hall", 0, far);
        var loft = new RoomDef(501, "loft", 1, far);
        room(grid, hall, -1_000_003, 1_000_005, 9, 3);
        room(grid, loft, -1_000_003, 1_000_005, 2, 2);
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        call(networks, "define", mod, "far", "power", "sequential");
        call(networks, "setProducers", mod, "far", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "far", 11.0, 11.0, 0.0);
        check(call(networks, "addBuilding", mod, "far", -1_000_000.0, 1_000_006.0, 0.0).get(0).equals(true), "The far building was not found");
        generator.setActivated(true);
        frame();
        check(state(networks, "far").rawget("supplied").equals(true), "The network with a far building has no supply");
        check(square(11, 11, 0).haveElectricity() && new IsoGridSquare(-1_000_003, 1_000_005, 0).haveElectricity()
            && new IsoGridSquare(-999_995, 1_000_007, 0).haveElectricity() && new IsoGridSquare(-1_000_002, 1_000_006, 1).haveElectricity(),
            "A square of one of the buildings has no power");
        check(!new IsoGridSquare(-1_000_005, 1_000_005, 0).haveElectricity() && !new IsoGridSquare(-999_993, 1_000_007, 0).haveElectricity()
            && !new IsoGridSquare(-999_990, 1_000_006, 1).haveElectricity() && !new IsoGridSquare(-500_000, 500_000, 0).haveElectricity()
            && !new IsoGridSquare(-1_000_000, 1_000_006, 2).haveElectricity(), "A square outside the buildings has power");
        // Its shell: against the hall's wall, and the hall's roof beside the loft.
        check(new IsoGridSquare(-1_000_004, 1_000_005, 0).haveElectricity() && new IsoGridSquare(-1_000_001, 1_000_006, 1).haveElectricity(),
            "A square of the far building's shell has no power");
        // A chunk of the hall loads: its load is worked out again, with nothing else changed.
        double before = (Double)state(networks, "far").rawget("load");
        place(-1_000_002, 1_000_006, 0, powered("hall lamp", 0.004f));
        Thread.sleep(1100);
        frame();
        check(near((Double)state(networks, "far").rawget("load"), before + 0.004),
            "The load was not worked out again as a chunk of the building loaded: " + state(networks, "far").rawget("load"));
        IsoWorld.instance.currentCell.squares.remove("-1000002,1000006,0");
        IsoWorld.instance.currentCell.chunks.remove(Math.floorDiv(-1_000_002, 8) + "," + Math.floorDiv(1_000_006, 8));
        call(networks, "remove", mod, "far");
        frame();
        generator.setActivated(false);
        grid.rooms.remove(hall);
        grid.rooms.remove(loft);
    }

    /**
     * The questions the game asks tens of thousands of times a second allocate nothing, with networks supplied and
     * rules in place: a square's, an object's that no rule names and that hangs on no wall, and a water question about
     * an object that takes no pipes.
     */
    private static void cheapHooks(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        call(networks, "define", mod, "hot", "power", "sequential");
        call(networks, "setProducers", mod, "hot", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "hot", 11.0, 11.0, 0.0);
        call(networks, "exclude", mod, "hot", 11.0, 11.0, 0.0, "fridge");
        call(networks, "define", mod, "hotWater", "water", "fullest");
        place(30, 38, 0, barrel(50));
        call(networks, "setProducers", mod, "hotWater", list(at(30, 38, 0)));
        call(networks, "addBuilding", mod, "hotWater", 11.0, 11.0, 0.0);
        call(networks, "exclude", mod, "hotWater", 12.0, 11.0, 0.0, "sink");
        generator.setActivated(true);
        frame();
        IsoObject chair = square(10, 10, 0).objects.get(0);
        check(Hooks.squarePowered(false, 11, 11, 0) && !Hooks.squarePowered(false, 40, 40, 0)
            && !Hooks.objectPowered(false, chair, Hooks.APPLIANCE, true) && Hooks.objectPowered(true, chair, Hooks.APPLIANCE, true)
            && !Hooks.waterPlumbed(false, chair) && state(networks, "hotWater").rawget("supplied").equals(true), "The networks do not run");
        var threads = (com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean();
        long allocated = 0;
        for (int round = 0; round < 3; round++) {
            long before = threads.getCurrentThreadAllocatedBytes();
            for (int index = 0; index < 10_000; index++) {
                Hooks.squarePowered(false, 11, 11, 0);
                Hooks.squarePowered(false, 40, 40, 0);
                Hooks.objectPowered(false, chair, Hooks.APPLIANCE, true);
                Hooks.objectPowered(true, chair, Hooks.APPLIANCE, true);
                Hooks.waterPlumbed(false, chair);
            }
            allocated = threads.getCurrentThreadAllocatedBytes() - before;
        }
        check(allocated < 10_000, "50,000 hot questions allocated " + allocated + " bytes");
        call(networks, "remove", mod, "hot");
        call(networks, "remove", mod, "hotWater");
        frame();
        generator.setActivated(false);
        square(30, 38, 0).objects.clear();
    }

    /**
     * A source its mod runs carries the load like a generator: switched on by the mod it takes over, and the API switches
     * the generators off; when the mod says it can no longer run, the next producer takes over from the hour the mod
     * gives. Its extra load adds to the network's, and a newer API keeps both.
     */
    private static void sources(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 3000;
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        KahluaTable bank = LuaManager.platform.newTable();
        bank.rawset("source", "bank");
        call(networks, "define", mod, "solar", "power", "sequential");
        call(networks, "setProducers", mod, "solar", list(bank, at(34, 33, 0)));
        call(networks, "addBuilding", mod, "solar", 11.0, 11.0, 0.0);
        frame();
        KahluaTable state = state(networks, "solar");
        KahluaTable listed = (KahluaTable)((KahluaTable)state.rawget("producers")).rawget(1.0);
        check(listed.rawget("source").equals("bank") && listed.rawget("running").equals(false) && listed.rawget("available").equals(false)
            && state.rawget("supplied").equals(false), "A new source ran, or was listed wrong");
        // Switched on by its mod: it carries the load.
        LuaEventManager.raised.clear();
        call(networks, "setSource", mod, "solar", "bank", true, true);
        frame();
        state = state(networks, "solar");
        check(state.rawget("supplied").equals(true) && ((KahluaTable)state.rawget("producer")).rawget("source").equals("bank")
            && state.rawget("hoursLeft") == null && !generator.activated && square(11, 11, 0).haveElectricity()
            && raised("solar", "supply", 3000), "The source switched on does not carry the network");
        check(near((Double)state.rawget("fuelPerHour"), (0.02 + (Double)state.rawget("load")) * 0.1),
            "A source carrying the load hides what a generator would burn: " + state.rawget("fuelPerHour"));
        // It ran out two hours ago: the generator takes over from then.
        time.hours = 3010;
        call(networks, "setSource", mod, "solar", "bank", false, null, 3008.0);
        frame();
        state = state(networks, "solar");
        check(generator.activated && generator.lastHour() == 3008 && ((KahluaTable)state.rawget("producer")).rawget("x").equals(34.0)
            && raised("solar", "producer", 3008), "The generator did not take over from the hour the source ran out: " + generator.lastHour());
        listed = (KahluaTable)((KahluaTable)state.rawget("producers")).rawget(1.0);
        check(listed.rawget("running").equals(false) && listed.rawget("available").equals(false), "The source still runs");
        // Charged again and switched on: it takes over, and the generator is switched off.
        call(networks, "setSource", mod, "solar", "bank", true, true);
        frame();
        check(!generator.activated && ((KahluaTable)state(networks, "solar").rawget("producer")).rawget("source").equals("bank"),
            "The source did not take over from the generator");
        // Extra load: added to the consumers'.
        double ownLoad = (Double)state(networks, "solar").rawget("ownLoad");
        call(networks, "setExtraLoad", mod, "solar", 0.5);
        frame();
        state = state(networks, "solar");
        check(near((Double)state.rawget("ownLoad"), ownLoad + 0.5) && state.rawget("extraLoad").equals(0.5)
            && near((Double)state.rawget("load"), ownLoad + 0.5), "The extra load was not added");
        // A newer API keeps the source switched on, and the extra load.
        GameApi.register(LuaManager.class);
        frame();
        state = state(networks, "solar");
        check(state.rawget("supplied").equals(true) && ((KahluaTable)state.rawget("producer")).rawget("source").equals("bank")
            && near((Double)state.rawget("ownLoad"), ownLoad + 0.5), "A newer API lost the source or the extra load");
        // Taken out of the producers while it carries the load: the generator takes over at once.
        call(networks, "setProducers", mod, "solar", list(at(34, 33, 0)));
        frame();
        state = state(networks, "solar");
        check(generator.activated && state.rawget("supplied").equals(true) && state.rawget("producer") != null
            && ((KahluaTable)state.rawget("producer")).rawget("x").equals(34.0), "A source taken out of the producers still carried the network");
        call(networks, "setProducers", mod, "solar", list(bank, at(34, 33, 0)));
        call(networks, "setSource", mod, "solar", "bank", true, true);
        frame();
        check(!generator.activated && ((KahluaTable)state(networks, "solar").rawget("producer")).rawget("source").equals("bank"),
            "The source listed again did not take over");
        // Switched off by its mod while it can run: the network stops, as when a player switches a generator off.
        call(networks, "setSource", mod, "solar", "bank", true, false);
        frame();
        check(state(networks, "solar").rawget("supplied").equals(false) && !generator.activated, "Switching the source off did not stop the network");
        rejects(networks, "setSource", "solar has no source tank", mod, "solar", "tank", true);
        rejects(networks, "setSource", "available must be true or false", mod, "solar", "bank", "yes");
        rejects(networks, "setSource", "a source that is not available cannot be switched on", mod, "solar", "bank", false, true);
        rejects(networks, "setSource", "hour must be a number or nil", mod, "solar", "bank", false, null, "now");
        rejects(networks, "setExtraLoad", "load must be a number from 0.0 to 1000.0", mod, "solar", -1.0);
        KahluaTable bad = LuaManager.platform.newTable();
        bad.rawset("source", "no spaces");
        rejects(networks, "setProducers", "producers[1].source must be", mod, "solar", list(bad));
        call(networks, "define", mod, "pipes", "water", "fullest");
        rejects(networks, "setProducers", "sources are for power", mod, "pipes", list(bank));
        call(networks, "remove", mod, "pipes");
        call(networks, "remove", mod, "solar");
        frame();
        generator.setActivated(false);
    }

    /**
     * Generators on standby and out of service under "sequential": every generator that is off is on standby, also one
     * first seen off, but one the API saw switched off by hand, which it never switches on, whether the one in use is
     * switched off, runs out, or a source stops. Switched on by hand, a generator carries the load and is in service
     * again. The mark is kept on the generator, so a world loaded again knows it, and a newer API takes it over,
     * also for a generator whose square is not loaded; one from before the marks gives none, and so standby.
     */
    private static void service(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 5000;
        IsoGenerator a = place(36, 40, 0, new IsoGenerator(new IsoSprite("generator"))), b = place(37, 40, 0, new IsoGenerator(new IsoSprite("generator"))),
            c = place(38, 40, 0, new IsoGenerator(new IsoSprite("generator")));
        Runnable define = () -> {
            call(networks, "define", mod, "svc", "power", "sequential");
            call(networks, "setProducers", mod, "svc", list(at(36, 40, 0), at(37, 40, 0), at(38, 40, 0)));
            call(networks, "addBuilding", mod, "svc", 11.0, 11.0, 0.0);
        };
        define.run();
        frame();
        // First seen off: on standby, all three; the first switched on by hand carries the network.
        a.setActivated(true);
        frame();
        for (int index = 1; index <= 3; index++) check(!outOfService(networks, "svc", index), "A generator first seen off is out of service");
        check(serving(networks) == 36.0 && !b.hasModData() && !c.hasModData(), "The first does not carry the network, or a mark was made");
        // The one in use switched off by hand: out of service, marked on the generator, and the next, first seen off,
        // takes over at once.
        LuaEventManager.raised.clear();
        a.setActivated(false);
        frame();
        check(b.activated && !a.activated && !c.activated && serving(networks) == 37.0 && b.lastHour() == 5000
            && raised("svc", "producer", 5000) && !raised("svc", "supply", 5000) && square(11, 11, 0).haveElectricity(),
            "Switching off the one in use did not hand the network to the next on standby: " + LuaEventManager.raised);
        KahluaTable entry = (KahluaTable)((KahluaTable)state(networks, "svc").rawget("producers")).rawget(1.0);
        check(entry.rawget("running").equals(false) && Boolean.TRUE.equals(entry.rawget("outOfService"))
            && Boolean.TRUE.equals(a.getModData().rawget(PowerGrid.OUT_OF_SERVICE)) && !outOfService(networks, "svc", 3),
            "The one switched off by hand is not out of service, or not marked");
        // The one in use runs out: the next on standby takes over from the hour it did, not the one switched off by
        // hand. The empty one stopped by itself and stays on standby.
        time.hours = 5010;
        b.fuel = 0.001f;
        b.update();
        LuaEventManager.raised.clear();
        frame();
        check(c.activated && !a.activated && !b.activated && serving(networks) == 38.0 && c.lastHour() == 5001 && raised("svc", "producer", 5001),
            "The next on standby did not take over when the one in use ran out: " + c.lastHour() + ", " + LuaEventManager.raised);
        check(!outOfService(networks, "svc", 2) && b.fuel == 0 && outOfService(networks, "svc", 1), "The generator that ran out is out of service");
        // Switched off by hand with no other on standby that can run: the network stops; the one out of service stays off.
        LuaEventManager.raised.clear();
        c.setActivated(false);
        frame();
        check(!a.activated && !b.activated && !c.activated && state(networks, "svc").rawget("supplied").equals(false)
            && raised("svc", "supply", 5010) && outOfService(networks, "svc", 3),
            "Switching off the last that could run did not stop the network, or started one out of service");
        // A source stopping starts none out of service either; refuelled, the one on standby takes over from it.
        KahluaTable bank = LuaManager.platform.newTable();
        bank.rawset("source", "bank");
        call(networks, "setProducers", mod, "svc", list(bank, at(36, 40, 0), at(37, 40, 0), at(38, 40, 0)));
        call(networks, "setSource", mod, "svc", "bank", true, true);
        frame();
        check(state(networks, "svc").rawget("supplied").equals(true) && Double.isNaN(serving(networks)), "The source does not carry the network");
        call(networks, "setSource", mod, "svc", "bank", false, null);
        frame();
        check(!a.activated && !b.activated && !c.activated && state(networks, "svc").rawget("supplied").equals(false),
            "A source stopping started a generator out of service, or one that cannot run");
        b.fuel = 5;
        time.hours = 5020;
        call(networks, "setSource", mod, "svc", "bank", true, true);
        frame();
        call(networks, "setSource", mod, "svc", "bank", false, null);
        frame();
        check(b.activated && !a.activated && !c.activated && serving(networks) == 37.0, "The one on standby did not take over from the source");
        // Switched on by hand, a generator out of service carries the network and is in service again: its mark goes,
        // and switched off by the API for the next switched on, it takes over when that one is switched off by hand.
        a.setActivated(true);
        frame();
        check(a.activated && !b.activated && serving(networks) == 36.0 && !outOfService(networks, "svc", 2)
            && a.getModData().rawget(PowerGrid.OUT_OF_SERVICE) == null, "Switched on by hand, it does not carry the network or kept its mark");
        c.setActivated(true);
        frame();
        check(c.activated && !a.activated && !outOfService(networks, "svc", 2) && !outOfService(networks, "svc", 4),
            "The one switched on last does not carry the network");
        c.setActivated(false);
        frame();
        check(a.activated && !b.activated && !c.activated && serving(networks) == 36.0 && outOfService(networks, "svc", 4),
            "The generator switched on by hand did not return to service");
        // A world loaded again: the networks are defined anew, and the marks on the generators tell out of service from
        // standby. The fuel of one out of service is not counted in the hours left.
        var world = IsoWorld.instance;
        var cell = world.currentCell;
        world.setCell(null);
        frame();
        world.setCell(cell);
        frame();
        define.run();
        frame();
        check(serving(networks) == 36.0 && a.activated && !outOfService(networks, "svc", 2) && outOfService(networks, "svc", 3),
            "A world loaded again lost which generators are out of service");
        KahluaTable loaded = state(networks, "svc");
        check(near((Double)loaded.rawget("hoursLeft"), (a.fuel + b.fuel) / (Double)loaded.rawget("fuelPerHour")),
            "The hours left count a generator out of service: " + loaded.rawget("hoursLeft"));
        a.setActivated(false);
        frame();
        check(b.activated && !a.activated && !c.activated && serving(networks) == 37.0, "After a load the one on standby did not take over");
        // A newer API takes the marks over, also of a generator whose square is not loaded.
        a.setActivated(true);
        frame();
        var squares = IsoWorld.instance.currentCell.squares;
        var away = squares.remove("38,40,0");
        GameApi.register(LuaManager.class);
        frame();
        check(outOfService(networks, "svc", 3) && !outOfService(networks, "svc", 2) && serving(networks) == 36.0,
            "A newer API lost the mark of a generator not loaded");
        squares.put("38,40,0", away);
        frame();
        a.setActivated(false);
        frame();
        check(b.activated && !a.activated && !c.activated && serving(networks) == 37.0, "After a newer API took over the one on standby did not take over");
        b.setActivated(false);
        frame();
        check(!a.activated && !b.activated && !c.activated && state(networks, "svc").rawget("supplied").equals(false),
            "After a newer API took over a generator out of service was started");
        // An API from before the marks hands over none: the marks on the generators tell, as at first sight.
        olderHandover(api);
        GameApi.register(LuaManager.class);
        frame();
        for (int index = 1; index <= 3; index++) check(outOfService(networks, "svc", index), "A handover without marks lost one out of service");
        check(Boolean.TRUE.equals(a.getModData().rawget(PowerGrid.OUT_OF_SERVICE)), "A handover without marks took a mark off a generator");
        c.setActivated(true);
        frame();
        c.setActivated(false);
        frame();
        check(!a.activated && !b.activated && !c.activated && state(networks, "svc").rawget("supplied").equals(false),
            "A generator out of service was started after an older handover");
        // Picked up: out of service no more; one placed there instead is new to the API, on standby, without a mark.
        square(36, 40, 0).objects.clear();
        Thread.sleep(1100);
        frame();
        check(!outOfService(networks, "svc", 1), "A generator taken away is still out of service");
        var placed = place(36, 40, 0, new IsoGenerator(new IsoSprite("generator")));
        c.setActivated(true);
        frame();
        c.setActivated(false);
        frame();
        check(placed.activated && !b.activated && !c.activated && serving(networks) == 36.0 && placed.getModData().rawget(PowerGrid.OUT_OF_SERVICE) == null,
            "A generator placed where one out of service stood did not take over");
        call(networks, "remove", mod, "svc");
        frame();
        placed.setActivated(false);
        for (int x = 36; x <= 38; x++) square(x, 40, 0).objects.clear();
    }

    /**
     * A power network switched off stops its generators: the API switches them off, on standby, and they burn nothing.
     * Switched on again, the one in use before starts, or the first on standby that can run if it cannot; never one out
     * of service (switched off by hand). One a player switches on meanwhile goes back off at once and starts first. A world loaded again and a
     * newer API keep which one starts first.
     */
    private static void switchedOff(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 6000;
        IsoGenerator d = place(36, 42, 0, new IsoGenerator(new IsoSprite("generator"))), e = place(37, 42, 0, new IsoGenerator(new IsoSprite("generator"))),
            f = place(38, 42, 0, new IsoGenerator(new IsoSprite("generator")));
        Runnable define = () -> {
            call(networks, "define", mod, "svc", "power", "sequential");
            call(networks, "setProducers", mod, "svc", list(at(36, 42, 0), at(37, 42, 0), at(38, 42, 0)));
            call(networks, "addBuilding", mod, "svc", 11.0, 11.0, 0.0);
        };
        define.run();
        frame();
        f.setActivated(true);
        frame();
        f.setActivated(false);
        frame();
        e.setActivated(true);
        frame();
        d.setActivated(true);
        frame();
        check(d.activated && !e.activated && !f.activated && !outOfService(networks, "svc", 2) && outOfService(networks, "svc", 3),
            "The network does not run, or the third is not out of service");
        // Switched off: the one in use is switched off, on standby, marked to start first, and burns nothing.
        LuaEventManager.raised.clear();
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        check(!d.activated && !e.activated && !f.activated && !outOfService(networks, "svc", 1) && !outOfService(networks, "svc", 2)
            && outOfService(networks, "svc", 3) && state(networks, "svc").rawget("producer") == null && raised("svc", "supply", 6000)
            && Double.valueOf(d.lastHour()).equals(d.getModData().rawget(PowerGrid.RESUME)), "Switching the network off did not stop its generator");
        float fuel = d.fuel;
        time.hours = 6010;
        d.update();
        check(d.fuel == fuel, "A generator of a network switched off burned fuel");
        // Switched on: it starts again, from now: "supply" at that hour, no "producer".
        LuaEventManager.raised.clear();
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(d.activated && !e.activated && !f.activated && d.lastHour() == 6010 && serving(networks) == 36.0
            && state(networks, "svc").rawget("supplied").equals(true) && d.getModData().rawget(PowerGrid.RESUME) == null
            && raised("svc", "supply", 6010) && !raised("svc", "producer", 6010),
            "Switching the network on did not start the one in use before: " + LuaEventManager.raised);
        // It can no longer run when the network is switched on: the first on standby that can starts instead.
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        d.fuel = 0;
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(e.activated && !d.activated && !f.activated && serving(networks) == 37.0, "The next on standby did not start for one that cannot run");
        // None on standby can run: the one out of service stays off, and the network has no supply.
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        e.fuel = 0;
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(!d.activated && !e.activated && !f.activated && state(networks, "svc").rawget("supplied").equals(false),
            "Switching the network on started a generator out of service");
        // Switched on by hand while the network is off: back off at once, on standby, and the one to start first.
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        f.setActivated(true);
        frame();
        check(!f.activated && !outOfService(networks, "svc", 3) && state(networks, "svc").rawget("supplied").equals(false)
            && Double.valueOf(f.lastHour()).equals(f.getModData().rawget(PowerGrid.RESUME)), "A generator switched on in a network switched off kept running");
        // A world loaded again, the network defined switched off: none starts until it is switched on, and then the
        // marked one, before the first in order.
        d.fuel = 5;
        var world = IsoWorld.instance;
        var cell = world.currentCell;
        world.setCell(null);
        frame();
        world.setCell(cell);
        frame();
        define.run();
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        check(!d.activated && !f.activated && !outOfService(networks, "svc", 1) && !outOfService(networks, "svc", 3),
            "A world loaded again put a generator out of service");
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(f.activated && !d.activated && !e.activated && serving(networks) == 38.0, "After a load, the one to start first did not");
        // A newer API keeps it too.
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        GameApi.register(LuaManager.class);
        frame();
        check(!f.activated && !d.activated, "A newer API started a generator of a network switched off");
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(f.activated && !d.activated && !e.activated && serving(networks) == 38.0, "After a newer API, the one to start first did not");
        // An API from before the marks, whose network lines end at the producer in use, hands over neither which to
        // start first nor that it stopped them: the mark on the generator tells.
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        olderHandover(api);
        GameApi.register(LuaManager.class);
        frame();
        check(!f.activated && !d.activated && state(networks, "svc").rawget("supplied").equals(false), "After an older handover a generator runs");
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(f.activated && !d.activated && !e.activated && serving(networks) == 38.0, "After an older handover, the one to start first did not");
        call(networks, "remove", mod, "svc");
        frame();
        f.setActivated(false);
        for (int x = 36; x <= 38; x++) square(x, 42, 0).objects.clear();
    }

    /**
     * The marks on generators: one seen running and then found off where the API did not see it (the game started
     * without it) is out of service, one that cannot run is not; the API's own switch-off takes the running mark off; a
     * switch on and off between two frames is seen; a multiplayer client writes no marks and switches nothing; a
     * generator that leaves the networks, or runs in none, loses its marks. A resume mark counts only for a network
     * switched off; one whose square is not loaded is waited for, or carries on if it still runs there. A source is
     * resumed too, also one its mod switched on while the network was off.
     */
    private static void marks(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 7000;
        IsoGenerator g1 = place(36, 44, 0, new IsoGenerator(new IsoSprite("generator"))), g2 = place(37, 44, 0, new IsoGenerator(new IsoSprite("generator"))),
            g3 = place(38, 44, 0, new IsoGenerator(new IsoSprite("generator")));
        Runnable define = () -> {
            call(networks, "define", mod, "svc", "power", "sequential");
            call(networks, "setProducers", mod, "svc", list(at(36, 44, 0), at(37, 44, 0), at(38, 44, 0)));
            call(networks, "addBuilding", mod, "svc", 11.0, 11.0, 0.0);
        };
        Runnable reload = () -> {
            var world = IsoWorld.instance;
            var cell = world.currentCell;
            world.setCell(null);
            frame();
            world.setCell(cell);
            frame();
        };
        define.run();
        frame();
        // Seen running, it is marked; switched off while the game ran without the API, it is out of service as the
        // world loads again.
        g1.setActivated(true);
        frame();
        check(Boolean.TRUE.equals(g1.getModData().rawget(PowerGrid.RUNNING)) && !g2.hasModData(), "A generator seen running is not marked");
        reload.run();
        g1.setActivated(false);
        define.run();
        frame();
        check(outOfService(networks, "svc", 1) && Boolean.TRUE.equals(g1.getModData().rawget(PowerGrid.OUT_OF_SERVICE))
            && g1.getModData().rawget(PowerGrid.RUNNING) == null, "A generator switched off without the API is not out of service");
        // One that stopped because it could not run stopped by itself: on standby.
        g2.setActivated(true);
        frame();
        reload.run();
        g2.fuel = 0;
        g2.setActivated(false);
        define.run();
        frame();
        check(!outOfService(networks, "svc", 2) && g2.getModData().rawget(PowerGrid.RUNNING) == null, "A generator that ran out is out of service");
        g2.fuel = 10;
        // The API's own switch-off takes the running mark off.
        g3.setActivated(true);
        frame();
        g2.setActivated(true);
        frame();
        check(g2.activated && !g3.activated && g3.getModData().rawget(PowerGrid.RUNNING) == null && !outOfService(networks, "svc", 3),
            "The API's switch-off left the running mark");
        // Switched on and off by hand between two frames: out of service.
        g3.setActivated(true);
        g3.update();
        g3.setActivated(false);
        frame();
        check(outOfService(networks, "svc", 3) && g2.activated, "A switch on and off between two frames was not seen");
        g3.setActivated(true);
        frame();
        check(g3.activated && !g2.activated && !outOfService(networks, "svc", 3), "Switched on by hand, it is not in service");
        // A multiplayer client: the server switches and marks; the client writes nothing and starts nothing.
        GameClient.client = true;
        try {
            g3.setActivated(false);
            frame();
            check(g3.getModData().rawget(PowerGrid.OUT_OF_SERVICE) == null && !g2.activated && !g1.activated,
                "A multiplayer client marked a generator or started one");
        } finally { GameClient.client = false; }
        g3.setActivated(true);
        frame();
        // Leaving the producers, a generator loses its marks; so does one switched on in no network.
        check(Boolean.TRUE.equals(g1.getModData().rawget(PowerGrid.OUT_OF_SERVICE)), "The first lost its mark");
        call(networks, "setProducers", mod, "svc", list(at(37, 44, 0), at(38, 44, 0)));
        frame();
        check(g1.getModData().rawget(PowerGrid.OUT_OF_SERVICE) == null, "A generator that left the producers kept its mark");
        g1.getModData().rawset(PowerGrid.OUT_OF_SERVICE, true);
        g1.setActivated(true);
        frame();
        check(g1.getModData().rawget(PowerGrid.OUT_OF_SERVICE) == null, "A generator switched on in no network kept its mark");
        g1.setActivated(false);
        call(networks, "setProducers", mod, "svc", list(at(36, 44, 0), at(37, 44, 0), at(38, 44, 0)));
        frame();
        check(!outOfService(networks, "svc", 1) && g3.activated, "The first, back in the producers, is out of service");
        // A resume mark counts only for a network switched off: defined switched on after a load, the mark goes, and
        // the first in order starts as the network is switched on again; with "supply" at that hour and no "producer".
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        check(Double.valueOf(g3.lastHour()).equals(g3.getModData().rawget(PowerGrid.RESUME)), "The third is not marked to start first");
        reload.run();
        define.run();
        frame();
        check(g3.getModData().rawget(PowerGrid.RESUME) == null && state(networks, "svc").rawget("supplied").equals(false),
            "A resume mark stayed on in a network switched on");
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        time.hours = 7010;
        LuaEventManager.raised.clear();
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(g1.activated && !g3.activated && raised("svc", "supply", 7010) && !raised("svc", "producer", 7010),
            "A resume mark read in a network switched on, or the wrong events: " + LuaEventManager.raised);
        // The one to start first not loaded, off there, and none other can start: the network waits for its square.
        for (IsoGenerator generator : List.of(g2, g3)) {
            generator.setActivated(true);
            frame();
            generator.setActivated(false);
            frame();
        }
        check(g1.activated && outOfService(networks, "svc", 2) && outOfService(networks, "svc", 3), "The others are not out of service");
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        var squares = IsoWorld.instance.currentCell.squares;
        var away = squares.remove("36,44,0");
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(state(networks, "svc").rawget("supplied").equals(false) && !g2.activated && !g3.activated, "Another started for one not loaded");
        time.hours = 7020;
        squares.put("36,44,0", away);
        // Nothing the API hears of changed: the next frame comes after a second.
        Thread.sleep(1100);
        LuaEventManager.raised.clear();
        frame();
        check(g1.activated && g1.lastHour() == 7020 && raised("svc", "supply", 7020) && g1.getModData().rawget(PowerGrid.RESUME) == null,
            "The one to start first did not start as its square loaded");
        // Running on a square that is not loaded as the network is switched off: it carries the network again.
        g1.update();
        away = squares.remove("36,44,0");
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(serving(networks) == 36.0 && state(networks, "svc").rawget("supplied").equals(true) && !g2.activated && !g3.activated,
            "The one running on a square not loaded does not carry the network again");
        squares.put("36,44,0", away);
        // Nothing the API hears of changed: the next frame comes after a second.
        Thread.sleep(1100);
        frame();
        check(g1.activated && serving(networks) == 36.0, "The one running stopped as its square loaded");
        // A source is the one to start first: switched off with the network, and on again with it.
        KahluaTable bank = LuaManager.platform.newTable();
        bank.rawset("source", "bank");
        call(networks, "setProducers", mod, "svc", list(at(36, 44, 0), bank));
        call(networks, "setSource", mod, "svc", "bank", true, true);
        frame();
        check(!g1.activated && Double.isNaN(serving(networks)) && state(networks, "svc").rawget("supplied").equals(true), "The source does not carry it");
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        KahluaTable listed = (KahluaTable)((KahluaTable)state(networks, "svc").rawget("producers")).rawget(2.0);
        check(listed.rawget("running").equals(false) && state(networks, "svc").rawget("supplied").equals(false), "The source runs in a network switched off");
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(!g1.activated && Double.isNaN(serving(networks)) && state(networks, "svc").rawget("supplied").equals(true), "The source was not resumed");
        // Switched on by its mod while the network is off: it is the one to start first.
        call(networks, "setSource", mod, "svc", "bank", false, null);
        frame();
        check(g1.activated, "The generator did not take over from the source");
        call(networks, "setEnabled", mod, "svc", false);
        frame();
        call(networks, "setSource", mod, "svc", "bank", true, true);
        frame();
        listed = (KahluaTable)((KahluaTable)state(networks, "svc").rawget("producers")).rawget(2.0);
        check(!g1.activated && listed.rawget("running").equals(false) && state(networks, "svc").rawget("supplied").equals(false),
            "A source switched on in a network switched off runs");
        call(networks, "setEnabled", mod, "svc", true);
        frame();
        check(!g1.activated && Double.isNaN(serving(networks)) && state(networks, "svc").rawget("supplied").equals(true),
            "The source switched on while the network was off did not start first");
        call(networks, "remove", mod, "svc");
        frame();
        for (int x = 36; x <= 38; x++) square(x, 44, 0).objects.clear();
    }

    /** The handover of an API from before the marks: its E lines end at the condition, its N lines at the producer in use. */
    private static void olderHandover(KahluaTable api) {
        KahluaTable meta = api.getMetatable();
        @SuppressWarnings("unchecked") var handover = (java.util.function.Supplier<String>)meta.rawget("networksHandover");
        meta.rawset("networksHandover", (java.util.function.Supplier<String>)() -> {
            var lines = new ArrayList<String>();
            for (String line : handover.get().split("\n", -1)) {
                String[] fields = line.split("\t", -1);
                int keep = line.startsWith("E\t") ? 5 : line.startsWith("N\t") ? 8 : fields.length;
                lines.add(String.join("\t", Arrays.copyOf(fields, Math.min(keep, fields.length))));
            }
            return String.join("\n", lines);
        });
    }

    /** The x of the producer in use of the network "svc", or NaN without one or for a source. */
    private static double serving(KahluaTable networks) {
        var producer = (KahluaTable)state(networks, "svc").rawget("producer");
        return producer == null || producer.rawget("x") == null ? Double.NaN : (Double)producer.rawget("x");
    }

    /**
     * A newer API that fails to take the API over leaves the game as vanilla: the earlier API's networks no
     * longer run, so they answer nothing. A later API takes the definitions over.
     */
    private static void failedTakeover(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        call(networks, "define", mod, "held", "power", "sequential");
        call(networks, "setProducers", mod, "held", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "held", 11.0, 11.0, 0.0);
        generator.setActivated(true);
        frame();
        check(square(11, 11, 0).haveElectricity() && !square(32, 33, 0).haveElectricity(), "The network does not run");
        // Here the API cannot read the game's Lua at all.
        try { GameApi.register(String.class); throw new AssertionError("An API that cannot read the game's Lua took the API over"); }
        catch (ReflectiveOperationException expected) { }
        frame();
        check(!square(11, 11, 0).haveElectricity(), "A failed takeover left the earlier API's networks answering");
        generator.setSurroundingElectricity();
        check(square(32, 33, 0).haveElectricity(), "After a failed takeover the game does not power the generator's range");
        GameApi.register(LuaManager.class);
        frame();
        check(square(11, 11, 0).haveElectricity() && !square(32, 33, 0).haveElectricity(), "A later API did not take the networks over");
        call(networks, "remove", mod, "held");
        frame();
        generator.setActivated(false);
    }

    /**
     * A newer API takes over what the networks know besides their definitions: a producer running on a square that
     * is not loaded goes on carrying its network until its fuel would run out, a water producer that is not loaded
     * still holds what it was last seen to, and consumers that are not loaded still count. The definitions are written
     * where a newer API finds them once a frame, or as it takes over; a function a mod kept from before says that
     * the API was updated.
     */
    private static void handover(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks"), meta = api.getMetatable();
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 4000;
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 6;
        call(networks, "define", mod, "kept", "power", "sequential");
        call(networks, "setProducers", mod, "kept", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "kept", 11.0, 11.0, 0.0);
        place(30, 40, 0, barrel(40));
        call(networks, "define", mod, "keptWater", "water", "fullest");
        call(networks, "setProducers", mod, "keptWater", list(at(30, 40, 0)));
        generator.setActivated(true);
        frame();
        generator.update();
        int end = generator.lastHour() + (int)Math.ceil(generator.fuel / generator.getTotalPowerUsing());
        double load = (Double)state(networks, "kept").rawget("load");
        check(state(networks, "kept").rawget("supplied").equals(true) && near((Double)state(networks, "keptWater").rawget("amount"), 40),
            "The networks do not run");
        // Written once a frame, and not again for a call that changes nothing.
        Object written = meta.rawget("networks");
        check(written instanceof String text && text.contains("kept"), "The definitions were not written at the frame");
        call(networks, "addBuilding", mod, "kept", 11.0, 11.0, 0.0);
        frame();
        check(meta.rawget("networks") == written, "A call that changed nothing wrote the definitions again");
        call(networks, "define", mod, "late", "power", "sequential");
        check(meta.rawget("networks") == written, "The definitions were written at the call, not at the frame");
        // The producer's, the barrel's and the fridge's squares leave the world; a newer API takes over before a frame.
        var squares = IsoWorld.instance.currentCell.squares;
        var away = new LinkedHashMap<String, IsoGridSquare>();
        for (String key : List.of("34,33,0", "30,40,0", "11,11,0")) away.put(key, squares.remove(key));
        Object define = networks.rawget("define");
        LuaEventManager.raised.clear();
        GameApi.register(LuaManager.class);
        frame();
        KahluaTable kept = state(networks, "kept");
        check(kept.rawget("supplied").equals(true) && ((KahluaTable)kept.rawget("producer")).rawget("x").equals(34.0)
            && kept.rawget("hoursLeft") != null && new IsoGridSquare(11, 11, 0).haveElectricity(),
            "A newer API lost the producer running on a square that is not loaded");
        check(near((Double)kept.rawget("load"), load), "A newer API lost the load of consumers not loaded: " + kept.rawget("load") + " for " + load);
        check(state(networks, "keptWater").rawget("supplied").equals(true) && near((Double)state(networks, "keptWater").rawget("amount"), 40),
            "A newer API lost what a water producer not loaded holds");
        check(LuaEventManager.raised.isEmpty(), "A newer API changed the supply: " + LuaEventManager.raised);
        check(state(networks, "late") != null, "A newer API lost a definition made since the last frame");
        // The producer not loaded runs out at the hour its fuel would: the newer API knows when. (A definition
        // changes, so that the next frame works the networks out rather than waiting a second.)
        time.hours = end + 5;
        call(networks, "remove", mod, "late");
        frame();
        check(state(networks, "kept").rawget("supplied").equals(false) && raised("kept", "supply", end),
            "The producer not loaded did not run out at hour " + end + ": " + LuaEventManager.raised);
        // A function a mod kept from before the takeover.
        try { invoke(define, mod, "stale", "power", "sequential"); throw new AssertionError("A function kept from before the takeover ran"); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.networks.define: the API was updated"), expected.getMessage());
        }
        check(call(networks, "state", "stale").get(0) == null, "A function kept from before the takeover defined a network");
        squares.putAll(away);
        for (String id : List.of("kept", "keptWater")) call(networks, "remove", mod, id);
        frame();
        generator.setActivated(false);
        square(30, 40, 0).objects.clear();
    }

    /**
     * A water network over the house, with two barrels outside it. Its sink takes water from the fullest barrel that
     * holds some; the barrels answer for themselves, and what the world saves is the game's own flag.
     */
    private static void water(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "water.mod").get(0);
        double hours = GameTime.getInstance().hours;
        IsoObject sink = square(12, 11, 0).objects.get(0);
        IsoObject low = place(30, 32, 0, barrel(20)), high = place(31, 32, 0, barrel(60));
        check(!sink.getUsesExternalWaterSource() && sink.getFluidAmount() == 0, "The sink has water without a network");
        call(networks, "define", mod, "pipes", "water", "fullest");
        call(networks, "setProducers", mod, "pipes", list(at(30, 32, 0), at(31, 32, 0)));
        call(networks, "addBuilding", mod, "pipes", 11.0, 11.0, 0.0);
        LuaEventManager.raised.clear();
        frame();
        KahluaTable pipes = state(networks, "pipes");
        var first = (KahluaTable)((KahluaTable)pipes.rawget("producers")).rawget(1.0);
        check(pipes.rawget("supplied").equals(true) && pipes.rawget("amount").equals(80.0) && pipes.rawget("capacity").equals(200.0)
            && first.rawget("amount").equals(20.0) && first.rawget("capacity").equals(100.0) && pipes.rawget("load") == null
            && raised("pipes", "supply", hours), "The water network's state is wrong");
        check(sink.getUsesExternalWaterSource() && sink.getFluidAmount() == 60 && sink.getFluidCapacity() == 100,
            "The sink does not take from the fullest barrel: " + sink.getFluidAmount());
        check(sink.useFluid(45) == 45 && high.fluidContainer.amount == 15 && sink.getFluidAmount() == 20,
            "The sink did not draw from the fullest barrel, then move to the other");
        check(!low.getUsesExternalWaterSource() && low.getFluidAmount() == 20, "A barrel takes water from the network");
        var saved = ByteBuffer.allocate(1);
        sink.save(saved, false);
        check(saved.get(0) == 0, "The network changed the flag the world saves");
        check(!square(12, 11, 0).haveElectricity(), "A water network powers its building");
        check(sprites(call(networks, "consumers", "pipes").get(0)).equals(Set.of("sink")), "Wrong water consumers");
        // Excluded: the game's own answer. Added on its own: a fixture outside the house, but only one that takes pipes.
        call(networks, "exclude", mod, "pipes", 12.0, 11.0, 0.0, "sink");
        check(!sink.getUsesExternalWaterSource() && sink.getFluidAmount() == 0, "An excluded sink has water");
        call(networks, "reset", mod, "pipes", 12.0, 11.0, 0.0, "sink");
        var outside = place(15, 13, 0, new IsoObject(new IsoSprite("outside sink")));
        var crate = place(16, 13, 0, new IsoObject(new IsoSprite("crate")));
        outside.sprite.properties.flags.add(IsoFlagType.waterPiped);
        check(!outside.getUsesExternalWaterSource(), "A fixture outside the house has water before it was added");
        call(networks, "include", mod, "pipes", 15.0, 13.0, 0.0, "outside sink");
        call(networks, "include", mod, "pipes", 16.0, 13.0, 0.0, "crate");
        check(outside.getUsesExternalWaterSource() && outside.getFluidAmount() == 20 && !crate.getUsesExternalWaterSource()
            && sink.getFluidAmount() == 20, "Adding objects on their own went wrong");
        // A child: water from the barrels of the network at the top of its parents.
        var shed = place(21, 21, 0, new IsoObject(new IsoSprite("shed sink")));
        shed.sprite.properties.flags.add(IsoFlagType.waterPiped);
        call(networks, "define", mod, "annex", "water", "fullest");
        call(networks, "addBuilding", mod, "annex", 20.0, 20.0, 0.0);
        call(networks, "setParent", mod, "annex", "pipes");
        frame();
        KahluaTable annex = state(networks, "annex");
        check(annex.rawget("supplied").equals(true) && annex.rawget("amount").equals(35.0) && ((KahluaTable)annex.rawget("producers")).len() == 0
            && shed.getFluidAmount() == 20, "The child has no water from its parent");
        call(networks, "define", mod, "lights", "power", "sequential");
        rejects(networks, "setParent", "pipes carries water, not power", mod, "lights", "pipes");
        // A water child with a producer of its own: its fixtures draw from the fullest of its own and its parent's, the
        // parent's from its own alone; the state sums them all and lists its own.
        IsoObject tank = place(23, 20, 0, barrel(40));
        call(networks, "setProducers", mod, "annex", list(at(23, 20, 0)));
        frame();
        annex = state(networks, "annex");
        var own = (KahluaTable)((KahluaTable)annex.rawget("producers")).rawget(1.0);
        check(annex.rawget("amount").equals(75.0) && annex.rawget("capacity").equals(300.0) && ((KahluaTable)annex.rawget("producers")).len() == 1
            && own.rawget("x").equals(23.0) && own.rawget("amount").equals(40.0), "The child's own producer is not in its state");
        check(shed.getFluidAmount() == 40 && sink.getFluidAmount() == 20 && state(networks, "pipes").rawget("amount").equals(35.0),
            "The child's own producer is not drawn from, or the parent draws from it: " + shed.getFluidAmount() + ", " + sink.getFluidAmount());
        call(networks, "define", mod, "wing", "water", "fullest");
        call(networks, "setProducers", mod, "wing", list(at(24, 20, 0)));
        call(networks, "setParent", mod, "wing", "pipes");
        call(networks, "remove", mod, "wing");
        // Dry: no supply, and the fixtures are the game's again; a child with water of its own keeps it.
        low.fluidContainer.amount = 0;
        high.fluidContainer.amount = 0;
        LuaEventManager.raised.clear();
        frame();
        check(state(networks, "pipes").rawget("supplied").equals(false) && !sink.getUsesExternalWaterSource()
            && raised("pipes", "supply", hours) && !raised("annex", "supply", hours) && shed.getFluidAmount() == 40,
            "A dry network supplies water, or its child lost its own");
        // A parent switched off cuts its child, whatever the child holds.
        LuaEventManager.raised.clear();
        call(networks, "setEnabled", mod, "pipes", false);
        frame();
        check(state(networks, "annex").rawget("supplied").equals(false) && !shed.getUsesExternalWaterSource() && raised("annex", "supply", hours),
            "A child of a network switched off has water");
        call(networks, "setEnabled", mod, "pipes", true);
        frame();
        check(state(networks, "annex").rawget("supplied").equals(true), "A child lost its own water when its parent was switched on");
        LuaEventManager.raised.clear();
        tank.fluidContainer.amount = 0;
        // Changed, so that the next frame reads the producers rather than waiting a second. Named again alone, the
        // building would change nothing.
        call(networks, "removeBuilding", mod, "annex", 20.0, 20.0, 0.0);
        call(networks, "addBuilding", mod, "annex", 20.0, 20.0, 0.0);
        frame();
        check(state(networks, "annex").rawget("supplied").equals(false) && raised("annex", "supply", hours), "A dry child supplies water");
        // A failing hook gives the game's answers; a newer API takes the networks over.
        high.fluidContainer.amount = 50;
        frame();
        Hooks.setWater(new Hooks.Water() {
            @Override public boolean plumbed(boolean vanilla, Object fixture) { throw new IllegalStateException("broken"); }
            @Override public Object source(Object vanilla, Object fixture) { throw new IllegalStateException("broken"); }
        });
        check(!sink.getUsesExternalWaterSource() && sink.getFluidAmount() == 0, "A failing hook did not give the game's answer");
        GameApi.register(LuaManager.class);
        frame();
        check(sink.getFluidAmount() == 50 && shed.getFluidAmount() == 50, "A newer API did not take the water networks over");
        for (String id : List.of("annex", "pipes", "lights")) call(networks, "remove", mod, id);
        frame();
        check(!sink.getUsesExternalWaterSource() && !outside.getUsesExternalWaterSource(), "A removed network still supplies water");
    }

    /**
     * Under "nearest" a fixture takes its water from its own network's producers first, the fullest of them, and from
     * its parent's only once those are dry; a container at least 95 percent full gives first wherever it is, so that rain
     * is not lost. A mod's draw likewise: what is above 95 percent first, then the network's own, then its parent's.
     */
    private static void nearest(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "water.mod").get(0);
        IsoObject roof = place(40, 40, 0, barrel(80)), floor = place(41, 40, 0, barrel(20)), other = place(42, 40, 0, barrel(10));
        var tap = place(43, 41, 0, new IsoObject(new IsoSprite("tap")));
        tap.sprite.properties.flags.add(IsoFlagType.waterPiped);
        call(networks, "define", mod, "roof", "water", "nearest");
        call(networks, "setProducers", mod, "roof", list(at(40, 40, 0)));
        call(networks, "define", mod, "floor", "water", "nearest");
        call(networks, "setProducers", mod, "floor", list(at(41, 40, 0), at(42, 40, 0)));
        call(networks, "setParent", mod, "floor", "roof");
        call(networks, "include", mod, "floor", 43.0, 41.0, 0.0, "tap");
        frame();
        check(tap.getUsesExternalWaterSource() && tap.getFluidAmount() == 20,
            "The network's own fullest producer did not give first: " + tap.getFluidAmount());
        floor.fluidContainer.amount = 0;
        check(tap.getFluidAmount() == 10, "The network's other producer did not give next: " + tap.getFluidAmount());
        other.fluidContainer.amount = 0;
        check(tap.getFluidAmount() == 80, "The parent's producer did not give once the network's own were dry: " + tap.getFluidAmount());
        floor.fluidContainer.amount = 20;
        roof.fluidContainer.amount = 96;
        check(tap.getFluidAmount() == 96, "A container about to spill did not give first: " + tap.getFluidAmount());
        // A draw: the 1 above 95 percent first, then the network's own levelled, the parent's untouched.
        other.fluidContainer.amount = 10;
        var drawn = call(networks, "draw", mod, "floor", 30.0);
        check(near((Double)drawn.get(0), 30) && near(roof.fluidContainer.amount, 95) && near(floor.fluidContainer.amount, 0.5)
            && near(other.fluidContainer.amount, 0.5), "A nearest draw went wrong: " + roof.fluidContainer.amount + ", "
            + floor.fluidContainer.amount + ", " + other.fluidContainer.amount);
        drawn = call(networks, "draw", mod, "floor", 10.0);
        check(near((Double)drawn.get(0), 10) && near(roof.fluidContainer.amount, 86) && near(floor.fluidContainer.amount, 0)
            && near(other.fluidContainer.amount, 0), "A nearest draw did not go on to the parent's: " + roof.fluidContainer.amount);
        check(near(WaterGrid.nearest(new double[] { 50, 99, 30 }, new double[] { 100, 100, 100 }, new int[] { 1, 2, 0 }, 40)[1], 4)
            && near(WaterGrid.nearest(new double[] { 50, 99, 30 }, new double[] { 100, 100, 100 }, new int[] { 1, 2, 0 }, 40)[2], 30)
            && near(WaterGrid.nearest(new double[] { 50, 99, 30 }, new double[] { 100, 100, 100 }, new int[] { 1, 2, 0 }, 40)[0], 6),
            "The nearest shares are wrong");
        // Exactly 95 percent full counts as about to spill.
        roof.fluidContainer.amount = 95;
        floor.fluidContainer.amount = 20;
        other.fluidContainer.amount = 10;
        check(tap.getFluidAmount() == 95, "A container exactly 95 percent full did not give first: " + tap.getFluidAmount());
        roof.fluidContainer.amount = 80;
        // A child with no producers of its own, under the floor: the floor's first, then the roof's (three levels).
        var hallTap = place(44, 41, 0, new IsoObject(new IsoSprite("hall tap")));
        hallTap.sprite.properties.flags.add(IsoFlagType.waterPiped);
        call(networks, "define", mod, "hall", "water", "nearest");
        call(networks, "setParent", mod, "hall", "floor");
        call(networks, "include", mod, "hall", 44.0, 41.0, 0.0, "hall tap");
        // Under "fullest", in the same chain: the fullest of all, the parent's although its own holds some.
        var flatTap = place(45, 41, 0, new IsoObject(new IsoSprite("flat tap")));
        flatTap.sprite.properties.flags.add(IsoFlagType.waterPiped);
        IsoObject flatOwn = place(46, 40, 0, barrel(30));
        call(networks, "define", mod, "flat", "water", "fullest");
        call(networks, "setProducers", mod, "flat", list(at(46, 40, 0)));
        call(networks, "setParent", mod, "flat", "roof");
        call(networks, "include", mod, "flat", 45.0, 41.0, 0.0, "flat tap");
        frame();
        check(hallTap.getFluidAmount() == 20, "A child with no producers did not draw from its parent's first: " + hallTap.getFluidAmount());
        floor.fluidContainer.amount = 0;
        other.fluidContainer.amount = 0;
        check(hallTap.getFluidAmount() == 80, "A child with no producers did not go on to the top: " + hallTap.getFluidAmount());
        check(flatTap.getFluidAmount() == 80 && flatOwn.fluidContainer.amount == 30,
            "Under fullest, the parent's fuller barrel did not give first: " + flatTap.getFluidAmount());
        for (String id : List.of("flat", "hall", "floor", "roof")) call(networks, "remove", mod, id);
        frame();
        check(!tap.getUsesExternalWaterSource() && !hallTap.getUsesExternalWaterSource() && !flatTap.getUsesExternalWaterSource(),
            "A removed network still supplies water");
    }

    /**
     * A mod draws from and fills a water network's producers, the fullest first and the emptiest first. A loaded
     * container changes at once, as the game changes one; a producer whose square is not loaded is owed the change, from
     * what it held when last seen, in the world's ModData, and takes it as it loads, once only, also when the world kept
     * an older ModData.
     */
    private static void fluids(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "water.mod").get(0);
        IsoObject clean = place(30, 34, 0, barrel(60)), tainted = place(31, 34, 0, new IsoObject(new IsoSprite("barrel")));
        tainted.fluidContainer = new FluidContainer(100, 40, Fluid.TaintedWater);
        call(networks, "define", mod, "tanks", "water", "fullest");
        call(networks, "setProducers", mod, "tanks", list(at(30, 34, 0), at(31, 34, 0)));
        frame();
        // Loaded: the fullest gives until it is level with the other, then both; each fluid in proportion.
        LuaEventManager.raised.clear();
        var drawn = call(networks, "draw", mod, "tanks", 30.0);
        KahluaTable mix = (KahluaTable)drawn.get(1);
        check(near((Double)drawn.get(0), 30) && near((Double)mix.rawget("Water"), 25) && near((Double)mix.rawget("TaintedWater"), 5)
            && near(clean.fluidContainer.amount, 35) && near(tainted.fluidContainer.amount, 35), "A draw did not take from the fullest first: " + drawn);
        check(clean.syncs == 1 && tainted.syncs == 1 && LuaEventManager.raised.contains(List.of("OnWaterAmountChange", clean, 60f)),
            "A drawn container was not synced or its change not raised");
        // Not loaded: owed, from what it held when last seen.
        var unloaded = IsoWorld.instance.currentCell.squares.remove("31,34,0");
        drawn = call(networks, "draw", mod, "tanks", 20.0);
        mix = (KahluaTable)drawn.get(1);
        check(near((Double)drawn.get(0), 20) && near((Double)mix.rawget("Water"), 10) && near((Double)mix.rawget("TaintedWater"), 10)
            && near(clean.fluidContainer.amount, 25) && near(tainted.fluidContainer.amount, 35), "A draw from an unloaded producer went wrong: " + drawn);
        check(near((Double)call(networks, "fill", mod, "tanks", 30.0, "Water").get(0), 30) && near(clean.fluidContainer.amount, 40)
            && near(clean.fluidContainer.fluid(Fluid.Water), 40), "A fill did not go to the emptiest first");
        KahluaTable tanks = state(networks, "tanks");
        var owed = (KahluaTable)((KahluaTable)tanks.rawget("producers")).rawget(2.0);
        check(near((Double)owed.rawget("amount"), 40) && near((Double)owed.rawget("pending"), 5) && near((Double)tanks.rawget("amount"), 80)
            && ((KahluaTable)((KahluaTable)tanks.rawget("producers")).rawget(1.0)).rawget("pending").equals(0.0),
            "The state does not count what is owed: " + owed.rawget("amount") + ", " + owed.rawget("pending"));
        KahluaTable kept = ModData.get(PendingFluids.KEY);
        check(kept != null && ((KahluaTable)kept.rawget("deltas")).len() == 2, "What is owed is not in the world's ModData");
        rejects(networks, "fill", "fluid must name one of the game's fluids", mod, "tanks", 1.0, "Lava");
        rejects(networks, "draw", "amount must be a number from 0.0", mod, "tanks", -1.0);
        call(networks, "define", mod, "wires", "power", "sequential");
        rejects(networks, "draw", "wires carries power, not fluids", mod, "wires", 1.0);
        call(networks, "remove", mod, "wires");
        GameClient.client = true;
        rejects(networks, "draw", "a multiplayer client cannot change what producers hold", mod, "tanks", 1.0);
        GameClient.client = false;
        // A newer API owes the same.
        GameApi.register(LuaManager.class);
        check(near((Double)((KahluaTable)((KahluaTable)state(networks, "tanks").rawget("producers")).rawget(2.0)).rawget("pending"), 5),
            "A newer API lost what is owed");
        // Loaded again: it takes what it is owed at the next frame, and records the last change it took.
        Object before = kept.rawget("deltas");
        IsoWorld.instance.currentCell.squares.put("31,34,0", unloaded);
        frame();
        check(near(tainted.fluidContainer.amount, 40) && near(tainted.fluidContainer.fluid(Fluid.TaintedWater), 25)
            && near(tainted.fluidContainer.fluid(Fluid.Water), 15) && tainted.syncs == 2, "A loaded producer did not take what it was owed: "
            + tainted.fluidContainer.amount);
        check(((KahluaTable)kept.rawget("deltas")).len() == 0 && tainted.getModData().rawget(WaterGrid.APPLIED) instanceof Double,
            "What was taken is still owed, or not recorded");
        // A world that stopped before its ModData was saved owes it again: the producer takes nothing twice.
        KahluaTable older = LuaManager.platform.newTable();
        older.rawset("deltas", before);
        ModData.tables.put(PendingFluids.KEY, older);
        // The game stores its cell when a world starts, after it loaded the ModData.
        IsoWorld.instance.setCell(IsoWorld.instance.currentCell);
        frame();
        check(near(tainted.fluidContainer.amount, 40) && ((KahluaTable)ModData.get(PendingFluids.KEY).rawget("deltas")).len() == 0,
            "A change was taken twice: " + tainted.fluidContainer.amount);
        // And a change owed after such a world gets a number past the ones the producer took.
        IsoWorld.instance.currentCell.squares.remove("31,34,0");
        call(networks, "draw", mod, "tanks", 2.0);
        IsoWorld.instance.currentCell.squares.put("31,34,0", unloaded);
        frame();
        check(tainted.fluidContainer.amount < 40, "A change owed after an older ModData was not taken");
        // Such a world again, the square not loaded: the changes read from the ModData that the square took, as it was
        // last seen, are not owed. A fill owed then does not add to a fill of the same fluid read from it, and its
        // number is past the ones the square took, however little time has passed.
        float held = tainted.fluidContainer.amount + clean.fluidContainer.amount;
        KahluaTable reloaded = LuaManager.platform.newTable();
        reloaded.rawset("deltas", before);
        ModData.tables.put(PendingFluids.KEY, reloaded);
        // The game stores its cell when a world starts, after it loaded the ModData.
        IsoWorld.instance.setCell(IsoWorld.instance.currentCell);
        IsoWorld.instance.currentCell.squares.remove("31,34,0");
        var taken = (KahluaTable)((KahluaTable)state(networks, "tanks").rawget("producers")).rawget(2.0);
        check(near((Double)taken.rawget("pending"), 0) && near((Double)taken.rawget("amount"), tainted.fluidContainer.amount),
            "A square not loaded is owed changes it took: " + taken.rawget("pending") + ", " + taken.rawget("amount"));
        call(networks, "fill", mod, "tanks", 10.0, "Water");
        check(((KahluaTable)ModData.get(PendingFluids.KEY).rawget("deltas")).len() == 3, "A change was added to one the square took already");
        IsoWorld.instance.currentCell.squares.put("31,34,0", unloaded);
        frame();
        check(near(tainted.fluidContainer.amount + clean.fluidContainer.amount, held + 10),
            "A change read from an older ModData was taken again: " + tainted.fluidContainer.amount);
        // Several containers on a square: draws come from the fullest first, fills go to the emptiest first. Draws owed
        // one after the other add up to one change, and so do fills of one fluid; the square takes them as it would
        // take them one by one.
        IsoObject fuller = place(32, 34, 0, barrel(50)), emptier = place(32, 34, 0, barrel(10));
        call(networks, "define", mod, "pair", "water", "fullest");
        call(networks, "setProducers", mod, "pair", list(at(32, 34, 0)));
        frame();
        unloaded = IsoWorld.instance.currentCell.squares.remove("32,34,0");
        check(near((Double)call(networks, "draw", mod, "pair", 10.0).get(0), 10) && near((Double)call(networks, "draw", mod, "pair", 20.0).get(0), 20),
            "A draw from an unloaded square went wrong");
        var pairOwed = (KahluaTable)ModData.get(PendingFluids.KEY).rawget("deltas");
        check(pairOwed.len() == 1 && near((Double)((KahluaTable)pairOwed.rawget(1.0)).rawget("litres"), -30),
            "Two draws owed one after the other were not added up");
        IsoWorld.instance.currentCell.squares.put("32,34,0", unloaded);
        frame();
        check(near(fuller.fluidContainer.amount, 20) && near(emptier.fluidContainer.amount, 10), "The owed draw did not come from the fullest");
        unloaded = IsoWorld.instance.currentCell.squares.remove("32,34,0");
        call(networks, "fill", mod, "pair", 20.0, "Water");
        call(networks, "fill", mod, "pair", 30.0, "Water");
        pairOwed = (KahluaTable)ModData.get(PendingFluids.KEY).rawget("deltas");
        check(pairOwed.len() == 1 && near((Double)((KahluaTable)pairOwed.rawget(1.0)).rawget("litres"), 50),
            "Two fills owed one after the other were not added up");
        IsoWorld.instance.currentCell.squares.put("32,34,0", unloaded);
        frame();
        check(near(fuller.fluidContainer.amount, 40) && near(emptier.fluidContainer.amount, 40), "The owed fill did not go to the emptiest");
        // Its containers gone, a square drops what it is owed.
        unloaded = IsoWorld.instance.currentCell.squares.remove("32,34,0");
        call(networks, "fill", mod, "pair", 5.0, "Water");
        unloaded.objects.clear();
        IsoWorld.instance.currentCell.squares.put("32,34,0", unloaded);
        frame();
        check(((KahluaTable)ModData.get(PendingFluids.KEY).rawget("deltas")).len() == 0, "A square without containers kept what it was owed");
        // A producer never seen loaded takes nothing; nor does a network switched off.
        call(networks, "setProducers", mod, "pair", list(at(60, 60, 0)));
        check(call(networks, "draw", mod, "pair", 5.0).get(0).equals(0.0) && call(networks, "fill", mod, "pair", 5.0, "Water").get(0).equals(0.0),
            "A producer never seen took a draw or a fill");
        call(networks, "setEnabled", mod, "tanks", false);
        check(call(networks, "draw", mod, "tanks", 5.0).get(0).equals(0.0), "A network switched off gave water");
        for (String id : List.of("tanks", "pair")) call(networks, "remove", mod, id);
        frame();
    }

    /**
     * As in vanilla, water a fixture takes from a network is purified; a network that does not purify passes its
     * producer's taint on, in the fixture's water and in what the game says of it. A newer API keeps the switch.
     */
    private static void purify(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "water.mod").get(0);
        IsoObject sink = square(12, 11, 0).objects.get(0);
        var rain = place(30, 36, 0, new IsoObject(new IsoSprite("barrel")));
        rain.fluidContainer = new FluidContainer(100, 50, Fluid.TaintedWater);
        call(networks, "define", mod, "rain", "water", "fullest");
        call(networks, "setProducers", mod, "rain", list(at(30, 36, 0)));
        call(networks, "addBuilding", mod, "rain", 11.0, 11.0, 0.0);
        frame();
        var bottle = new FluidContainer(10, 0);
        check(state(networks, "rain").rawget("purify").equals(true) && !sink.isTaintedWater() && sink.transferFluidTo(bottle, 1) == 1
            && near(bottle.fluid(Fluid.Water), 1) && near(rain.fluidContainer.amount, 49), "A network does not purify its water by default");
        call(networks, "setPurify", mod, "rain", false);
        bottle = new FluidContainer(10, 0);
        check(state(networks, "rain").rawget("purify").equals(false) && sink.isTaintedWater() && sink.transferFluidTo(bottle, 1) == 1
            && near(bottle.fluid(Fluid.TaintedWater), 1) && near(bottle.fluid(Fluid.Water), 0), "A network that does not purify passed clean water");
        // A producer with clean water is clean either way.
        var clean = place(30, 36, 0, barrel(90));
        check(!sink.isTaintedWater(), "Clean water from a network that does not purify is tainted");
        clean.fluidContainer.amount = 0;
        // A newer API keeps the switch; on again, the water is purified.
        GameApi.register(LuaManager.class);
        frame();
        check(state(networks, "rain").rawget("purify").equals(false) && sink.isTaintedWater(), "A newer API lost the switch");
        call(networks, "setPurify", mod, "rain", true);
        check(!sink.isTaintedWater(), "Switched on again, the water is not purified");
        rejects(networks, "setPurify", "on must be true or false", mod, "rain", "no");
        call(networks, "define", mod, "wires", "power", "sequential");
        rejects(networks, "setPurify", "wires carries power, not water", mod, "wires", false);
        call(networks, "remove", mod, "wires");
        // A game without both of its hooks has no water that keeps its taint.
        var hooked = Hooks.class.getDeclaredField("purifyHooked");
        hooked.setAccessible(true);
        hooked.setBoolean(null, false);
        rejects(networks, "setPurify", "water that keeps its taint is not in this game", mod, "rain", false);
        hooked.setBoolean(null, true);
        call(networks, "remove", mod, "rain");
        frame();
    }

    /**
     * A fixture's own water (its reserve, as the game keeps a sink's) on a producer's square is the network's too: it
     * counts in the state, a draw or fill reaches it, and the network's other fixtures take from it. The fixture gives
     * its own while it has some and takes the network's once that is used up. A reserve takes no tainted fill.
     */
    private static void reserves(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "water.mod").get(0);
        IsoObject shed = null;
        var objects = square(21, 21, 0).objects;
        for (int index = 0; index < objects.size(); index++) if (objects.get(index).sprite.name.equals("shed sink")) shed = objects.get(index);
        var basin = place(20, 20, 0, new IsoObject(new IsoSprite("basin")));
        basin.sprite.properties.flags.add(IsoFlagType.waterPiped);
        basin.unmoved = true;
        basin.reserve = basin.reserveMax = 20;
        IsoObject tank = place(30, 44, 0, barrel(40));
        call(networks, "define", mod, "basin", "water", "fullest");
        call(networks, "setProducers", mod, "basin", list(at(20, 20, 0), at(30, 44, 0)));
        call(networks, "addBuilding", mod, "basin", 20.0, 20.0, 0.0);
        frame();
        KahluaTable state = state(networks, "basin");
        var own = (KahluaTable)((KahluaTable)state.rawget("producers")).rawget(1.0);
        check(state.rawget("amount").equals(60.0) && state.rawget("capacity").equals(120.0) && own.rawget("amount").equals(20.0)
            && own.rawget("capacity").equals(20.0) && ((KahluaTable)own.rawget("fluids")).rawget("Water").equals(20.0),
            "A fixture's own water is not the network's: " + state.rawget("amount"));
        // A bottle of something else by the basin is left out, and the square is not foreign for it.
        var bottle0 = place(20, 20, 0, new IsoObject(new IsoSprite("bottle")));
        bottle0.fluidContainer = new FluidContainer(1, 0.5f, Fluid.Petrol);
        call(networks, "removeBuilding", mod, "basin", 20.0, 20.0, 0.0);
        call(networks, "addBuilding", mod, "basin", 20.0, 20.0, 0.0);
        frame();
        own = (KahluaTable)((KahluaTable)state(networks, "basin").rawget("producers")).rawget(1.0);
        check(own.rawget("amount").equals(20.0) && own.rawget("foreign") == null && state(networks, "basin").rawget("amount").equals(60.0),
            "A bottle of petrol by the basin made its square foreign: " + own.rawget("amount"));
        bottle0.square.objects.remove(bottle0);
        // The basin gives its own; the shed takes the fullest store, the basin's (all of 20) before the barrel's.
        check(!basin.getUsesExternalWaterSource() && basin.getFluidAmount() == 20, "The basin does not give its own water");
        check(shed != null && shed.getUsesExternalWaterSource() && shed.getFluidAmount() == 20 && shed.useFluid(5) == 5
            && basin.reserve == 15, "The shed does not draw from the basin's own water");
        // Used up, the basin takes the network's.
        check(basin.useFluid(15) == 15 && basin.reserve == 0 && basin.getUsesExternalWaterSource() && basin.getFluidAmount() == 40,
            "An empty basin does not take the network's water");
        var bottle = new FluidContainer(10, 0);
        check(basin.transferFluidTo(bottle, 4) == 4 && near(tank.fluidContainer.amount, 36), "The basin's water did not come from the barrel");
        // A fill: tainted water passes the basin by; clean water reaches it too.
        call(networks, "fill", mod, "basin", 10.0, "TaintedWater");
        check(basin.reserve == 0 && near(tank.fluidContainer.amount, 46), "Tainted water went into the basin: " + basin.reserve);
        double filled = (double)call(networks, "fill", mod, "basin", 10.0, "Water").get(0);
        check(near(filled, 10) && basin.reserve > 0 && near(basin.reserve + tank.fluidContainer.amount, 56) && !basin.getUsesExternalWaterSource(),
            "A clean fill did not reach the basin: " + basin.reserve);
        // A draw takes from it as from a container.
        float before = basin.reserve;
        call(networks, "draw", mod, "basin", 50.0);
        check(basin.reserve < before && near(basin.reserve + tank.fluidContainer.amount, 6), "A draw did not reach the basin");
        call(networks, "remove", mod, "basin");
        basin.square.objects.remove(basin);
        tank.square.objects.remove(tank);
        frame();
    }

    /**
     * Under gridFirst a fixture the mains reach takes their water while they run, not the network's; once they are shut
     * off, or without gridFirst, it takes the network's. A newer API keeps the switch.
     */
    private static void mainsFirst(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "water.mod").get(0);
        var time = GameTime.getInstance();
        double hours = time.hours;
        IsoObject sink = square(12, 11, 0).objects.get(0);
        sink.mainsPiped = true;
        var tank = place(30, 37, 0, barrel(50));
        call(networks, "define", mod, "tank", "water", "fullest");
        call(networks, "setProducers", mod, "tank", list(at(30, 37, 0)));
        call(networks, "addBuilding", mod, "tank", 11.0, 11.0, 0.0);
        SandboxOptions.instance.waterShutModifier = 10;
        time.hours = 24;
        frame();
        KahluaTable tankState = state(networks, "tank");
        check(tankState.rawget("mains").equals(true) && tankState.rawget("gridFirst").equals(false) && sink.getFluidAmount() == 50,
            "Without gridFirst a fixture took the mains' water");
        call(networks, "setGridFirst", mod, "tank", true);
        frame();
        var bottle = new FluidContainer(10, 0);
        check(state(networks, "tank").rawget("gridFirst").equals(true) && sink.getFluidAmount() == 10000
            && sink.transferFluidTo(bottle, 2) == 2 && near(tank.fluidContainer.amount, 50),
            "Under gridFirst the network gave its water while the mains run");
        // A newer API keeps the switch.
        GameApi.register(LuaManager.class);
        frame();
        check(state(networks, "tank").rawget("gridFirst").equals(true) && sink.getFluidAmount() == 10000, "A newer API lost gridFirst");
        // The mains shut off: the network's water (seen within a second).
        time.hours = 24 * 11;
        Thread.sleep(1100);
        frame();
        check(state(networks, "tank").rawget("mains").equals(false) && sink.getFluidAmount() == 50,
            "With the mains shut off the network gave no water");
        call(networks, "remove", mod, "tank");
        tank.square.objects.remove(tank);
        sink.mainsPiped = false;
        SandboxOptions.instance.waterShutModifier = -1;
        time.hours = hours;
        frame();
    }

    /**
     * Food in a fridge of a network ages as chilled only for the hours the network had supply: the hours since it
     * last aged are split where the supply started and stopped, also where it ran out while its producer was not
     * loaded, and at the grid's shut-off.
     */
    private static void food(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "power.mod").get(0);
        var time = GameTime.getInstance();
        time.hours = 3000;
        var generator = (IsoGenerator)square(34, 33, 0).objects.get(0);
        generator.fuel = 10;
        IsoObject fridge = square(11, 11, 0).objects.get(0);
        var container = new ItemContainer(fridge);
        container.fridge = true;
        call(networks, "define", mod, "cold", "power", "sequential");
        call(networks, "setProducers", mod, "cold", list(at(34, 33, 0)));
        call(networks, "addBuilding", mod, "cold", 11.0, 11.0, 0.0);
        frame();
        var food = aged(container, 3000);
        time.hours = 3010;
        generator.setActivated(true);
        frame();
        time.hours = 3020;
        generator.setActivated(false);
        frame();
        time.hours = 3030;
        food.updateAge(false);
        check(near(food.age, (10 * 0.2 + 20) / 24), "Food did not age chilled for the hours of supply alone: " + food.age * 24);
        // With supply now, the hours before it started count unchilled.
        time.hours = 3040;
        generator.setActivated(true);
        frame();
        time.hours = 3050;
        food = aged(container, 3030);
        food.updateAge(false);
        check(near(food.age, (10 + 10 * 0.2) / 24), "Food with supply now aged chilled for all the hours: " + food.age * 24);
        // The grid had power until hour 3024.
        SandboxOptions.instance.elecShutModifier = 126;
        food = aged(container, 3000);
        food.updateAge(false);
        check(near(food.age, (34 * 0.2 + 16) / 24), "The grid's hours were not chilled: " + food.age * 24);
        SandboxOptions.instance.elecShutModifier = -1;
        // An excluded fridge, frozen food and a container that is not a fridge age as the game has it.
        call(networks, "exclude", mod, "cold", 11.0, 11.0, 0.0, "fridge");
        food = aged(container, 3000);
        food.updateAge(false);
        check(near(food.age, 50 / 24.0), "Food in an excluded fridge aged chilled: " + food.age * 24);
        call(networks, "reset", mod, "cold", 11.0, 11.0, 0.0, "fridge");
        food = aged(container, 3000);
        food.frozen = true;
        food.updateAge(false);
        check(food.age == 0, "Frozen food aged");
        var shelf = new ItemContainer(fridge);
        food = aged(shelf, 3000);
        food.updateAge(false);
        check(near(food.age, 50 / 24.0), "Food outside a fridge aged chilled");
        // Run out while its producer was not loaded: chilled until the hour the fuel ran out.
        generator.update();
        generator.fuel = 1;
        generator.update();
        double perHour = generator.getTotalPowerUsing();
        int end = 3050 + (int)Math.ceil(1 / perHour);
        food = aged(container, 3050);
        var unloaded = IsoWorld.instance.currentCell.squares.remove("34,33,0");
        time.hours = end + 50;
        frame();
        IsoWorld.instance.currentCell.squares.put("34,33,0", unloaded);
        food.updateAge(false);
        check(near(food.age, ((end - 3050) * 0.2 + 50) / 24), "Food was not chilled until the fuel ran out: " + food.age * 24 + " for " + end);
        call(networks, "remove", mod, "cold");
        frame();
        generator.setActivated(false);
    }

    private static Food aged(ItemContainer container, float lastAged) {
        var food = new Food(container);
        food.setLastAged(lastAged);
        return food;
    }

    /**
     * A water network with several parents draws from its own producers, then each parent's in turn with those above
     * that one, each network once; no loops, and a power network has one parent at most. A producer that holds a fluid
     * the network does not take (Water and TaintedWater unless its mod says) gives nothing, is filled with nothing, and
     * the state marks it.
     */
    private static void parents(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "water.mod").get(0);
        IsoObject own = place(60, 40, 0, barrel(10)), first = place(61, 40, 0, barrel(50)), second = place(62, 40, 0, barrel(70));
        var tap = place(63, 41, 0, new IsoObject(new IsoSprite("tap")));
        tap.sprite.properties.flags.add(IsoFlagType.waterPiped);
        call(networks, "define", mod, "storey", "water", "nearest");
        call(networks, "setProducers", mod, "storey", list(at(60, 40, 0)));
        call(networks, "define", mod, "above", "water", "nearest");
        call(networks, "setProducers", mod, "above", list(at(61, 40, 0)));
        call(networks, "define", mod, "across", "water", "nearest");
        call(networks, "setProducers", mod, "across", list(at(62, 40, 0)));
        call(networks, "setParents", mod, "storey", list("above", "across"));
        // "above" draws from "across" too: "storey" still reaches "across" once, after "above".
        call(networks, "setParents", mod, "above", list("across"));
        call(networks, "include", mod, "storey", 63.0, 41.0, 0.0, "tap");
        frame();
        KahluaTable storey = state(networks, "storey");
        check(tap.getFluidAmount() == 10 && storey.rawget("parent").equals("above") && ((KahluaTable)storey.rawget("parents")).len() == 2
            && near((Double)storey.rawget("amount"), 130), "Several parents went wrong: " + tap.getFluidAmount() + ", " + storey.rawget("amount"));
        own.fluidContainer.amount = 0;
        check(tap.getFluidAmount() == 50, "The first parent did not give next: " + tap.getFluidAmount());
        first.fluidContainer.amount = 0;
        check(tap.getFluidAmount() == 70, "The second parent did not give last: " + tap.getFluidAmount());
        rejects(networks, "setParents", "storey is a child of across", mod, "across", list("storey"));
        rejects(networks, "setParents", "above is listed twice", mod, "storey", list("above", "above"));
        call(networks, "define", mod, "mains", "power", "sequential");
        call(networks, "define", mod, "backup", "power", "sequential");
        call(networks, "define", mod, "flat", "power", "sequential");
        rejects(networks, "setParents", "flat carries power; a power network has one parent at most", mod, "flat", list("mains", "backup"));
        // A pour of petrol: that barrel gives nothing, and the network has no water left.
        second.fluidContainer.shares.put(Fluid.Petrol, 0.1f);
        // Changed, so that the next frame reads the producers again.
        call(networks, "addBuilding", mod, "storey", 0.0, 0.0, 0.0);
        frame();
        storey = state(networks, "storey");
        var across = (KahluaTable)((KahluaTable)state(networks, "across").rawget("producers")).rawget(1.0);
        check(!tap.getUsesExternalWaterSource() && storey.rawget("supplied").equals(false) && across.rawget("foreign").equals(true)
            && near((Double)storey.rawget("amount"), 0), "A producer holding petrol still gives: " + tap.getFluidAmount());
        check(near((Double)call(networks, "draw", mod, "storey", 5.0).get(0), 0), "A producer holding petrol was drawn from");
        rejects(networks, "fill", "storey does not take Petrol", mod, "storey", 1.0, "Petrol");
        rejects(networks, "setFluids", "fluids[1] must name one of the game's fluids", mod, "storey", list("Lava"));
        // A network that takes petrol too: it draws from that barrel again.
        call(networks, "setFluids", mod, "storey", list("Water", "TaintedWater", "Petrol"));
        frame();
        KahluaTable fluids = (KahluaTable)state(networks, "storey").rawget("fluids");
        check(tap.getFluidAmount() == 70 && fluids.len() == 3, "A network that takes petrol does not draw from it: " + tap.getFluidAmount());
        call(networks, "setFluids", mod, "storey", null);
        check(((KahluaTable)state(networks, "storey").rawget("fluids")).len() == 2, "Water alone was not taken back");
        // A newer API keeps the parents and the fluids.
        call(networks, "setFluids", mod, "storey", list("Water"));
        GameApi.register(LuaManager.class);
        storey = state(networks, "storey");
        check(((KahluaTable)storey.rawget("parents")).len() == 2 && ((KahluaTable)storey.rawget("fluids")).len() == 1,
            "A newer API lost the parents or the fluids");
        for (String id : List.of("storey", "above", "across", "mains", "backup", "flat")) call(networks, "remove", mod, id);
        frame();
        check(!tap.getUsesExternalWaterSource(), "A removed network still supplies water");
    }

    /**
     * A rain collector whose square is not loaded: the game keeps its container running in a meta entity at its
     * position, and the API reads, draws from and fills that container, owing it nothing. What was owed before it was
     * found goes into it at the next frame. Loaded again, the container is the object's once more.
     */
    private static void rainKept(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        Object mod = call(api, "client", "water.mod").get(0);
        IsoObject collector = place(70, 40, 0, barrel(20)), near = place(71, 40, 0, barrel(20));
        call(networks, "define", mod, "rain", "water", "fullest");
        call(networks, "setProducers", mod, "rain", list(at(70, 40, 0), at(71, 40, 0)));
        frame();
        var cells = IsoWorld.instance.currentCell.squares;
        // Unloaded before the game's meta entity is seen: a draw is owed, as for a barrel.
        var square = cells.remove("70,40,0");
        call(networks, "draw", mod, "rain", 10.0);
        check(near(collector.fluidContainer.amount, 20) && near(near.fluidContainer.amount, 15), "A draw before the meta entity was not owed");
        var meta = new MetaEntity(9, 70, 40, 0, collector.fluidContainer);
        GameEntityManager.keep(meta);
        call(networks, "addBuilding", mod, "rain", 0.0, 0.0, 0.0);
        frame();
        KahluaTable kept = ModData.get(PendingFluids.KEY);
        check(near(collector.fluidContainer.amount, 15) && ((KahluaTable)kept.rawget("deltas")).len() == 0,
            "What was owed did not go into the kept container: " + collector.fluidContainer.amount);
        // The game's rain while it is away shows in the state.
        collector.fluidContainer.addFluid(Fluid.TaintedWater, 30);
        call(networks, "addBuilding", mod, "rain", 0.0, 0.0, 0.0);
        frame();
        var far = (KahluaTable)((KahluaTable)state(networks, "rain").rawget("producers")).rawget(1.0);
        check(near((Double)far.rawget("amount"), 45) && near((Double)far.rawget("pending"), 0)
            && near((Double)state(networks, "rain").rawget("amount"), 60), "The rain far away is not seen: " + far.rawget("amount"));
        // Drawn and filled in the container itself: nothing owed, nothing synced.
        int syncs = collector.syncs;
        check(near((Double)call(networks, "draw", mod, "rain", 30.0).get(0), 30) && near(collector.fluidContainer.amount, 15)
            && near(near.fluidContainer.amount, 15), "A draw did not reach the kept container: " + collector.fluidContainer.amount);
        check(near((Double)call(networks, "fill", mod, "rain", 10.0, "Water").get(0), 10) && near(collector.fluidContainer.amount, 20)
            && ((KahluaTable)kept.rawget("deltas")).len() == 0 && collector.syncs == syncs, "A fill was owed, or the kept container synced");
        check(near((Double)((KahluaTable)((KahluaTable)state(networks, "rain").rawget("producers")).rawget(1.0)).rawget("amount"), 20),
            "The state does not follow the kept container");
        // Loaded again: the object has it back, and the stale entry is passed over.
        GameEntityManager.giveBack(meta);
        cells.put("70,40,0", square);
        call(networks, "draw", mod, "rain", 5.0);
        check(near(collector.fluidContainer.amount, 17.5) && near(near.fluidContainer.amount, 17.5) && collector.syncs == syncs + 1,
            "A loaded collector was not drawn from as before: " + collector.fluidContainer.amount);
        call(networks, "remove", mod, "rain");
        frame();
    }

    private static IsoObject barrel(float amount) {
        var barrel = new IsoObject(new IsoSprite("barrel"));
        barrel.fluidContainer = new FluidContainer(100, amount);
        return barrel;
    }

    private static KahluaTable state(KahluaTable networks, String id) { return (KahluaTable)call(networks, "state", id).get(0); }

    /** Whether the networks' event was raised for the network "seq" with that change and hour; clears what was raised. */
    private static boolean raised(String what, double hour) {
        boolean found = raised("seq", what, hour);
        LuaEventManager.raised.clear();
        return found;
    }

    private static boolean raised(String id, String what, double hour) {
        return LuaEventManager.raised.stream().anyMatch(event -> event.equals(List.of("OnPZExtNetworkChange", id, what, hour)));
    }

    /** Whether the network's producer at that index (from 1) is out of service, as its state says. */
    private static boolean outOfService(KahluaTable networks, String id, int index) {
        var producer = (KahluaTable)((KahluaTable)state(networks, id).rawget("producers")).rawget((double)index);
        return Boolean.TRUE.equals(producer.rawget("outOfService"));
    }

    /** The x of the producer in use, or NaN without supply. */
    private static double producer(KahluaTable networks) {
        var producer = (KahluaTable)((KahluaTable)call(networks, "state", "seq").get(0)).rawget("producer");
        return producer == null ? Double.NaN : (Double)producer.rawget("x");
    }

    /**
     * {@code PZExtAPI.hooks()} and the install folder's status file say which hooks went in. A class another mod has
     * changed loses only the hooks whose methods no longer fit: one method gone, or one whose new code cannot be built
     * (here, stack maps over a type the game cannot load); the class's other hooks still go in.
     */
    private static void hooks(KahluaTable api) throws Exception {
        var hooks = (KahluaTable)call(api, "hooks").get(0);
        for (String label : new String[] { "LuaManager.init", "IsoGridSquare.haveElectricity", "ItemContainer.isObjectPowered",
                "IsoObject.checkExternalFluidSource", "IsoObject.createSampleAndPurifyWater", "IsoObject.isTaintedWater",
                "IsoObject.waterQuestions", "Food.updateAge:power", "Food.updateAge:hours", "IsoGenerator.setSurroundingElectricity",
                "IsoGenerator.updateGenerator", "IsoGenerator.update", "IsoGenerator.setActivated", "IsoLightSwitch.hasElectricityAround",
                "DeviceData.canBePoweredHere", "LightingJNI.checkLights", "IsoGameCharacter.getClothingDiscomfortModifier",
                "IsoGameCharacter.addStiffness", "IsoGameCharacter.getFatiqueMultiplier", "Stats.add", "IsoGameCharacter.getInventoryWeight",
                "IsoGameCharacter.getMaxWeight", "IsoGameCharacter.handleLandingImpact:overload", "IsoGameCharacter.calculateBaseSpeed",
                "IsoGameCharacter.calculateCombatSpeed", "IsoPlayer.getPathSpeed:overload", "Moodle.Update:overload", "ItemContainer.hasRoomFor",
                "ItemContainer.getEffectiveCapacity", "ItemContainer.getCapacity", "InventoryContainer.getCapacity",
                "InventoryContainer.getEffectiveCapacity", "ItemContainer.items:tracked", "ItemContainer.emptyIt", "ItemContainer.setItems",
                "WornItems.items:tracked", "InventoryItem.writes:weight", "InventoryItem.addExtraItem", "Food.writes:weight",
                "HandWeapon.writes:weight", "HandWeapon.clearAllWeaponParts", "HandWeapon.clearWeaponPart:part", "HandWeapon.clearWeaponPart:name",
                "HandWeapon.setWeaponPart", "HandWeapon.attachWeaponPart", "InventoryContainer.writes:weight", "Moveable.writes:weight",
                "ItemStatsPacket.writes:weight", "FluidContainer.writes:amount", "ItemPickerJava.getActualSpawnChance",
                "ItemPickerJava.getLootModifierFromType", "LightingJNI.getLumaInverted", "LightingJNI.calculateVisionCone",
                "IsoTree.getSlowFactor", "IsoTree.isPlayerInsideARoom", "BREBuilding.<init>", "PlayerRoomsFile.load", "ZombieIdleState.execute", "WorldSoundManager.getBiggestSoundZomb",
                "ZombiePopulationManager.removeChunkFromWorld", "ZombiePopulationManager.registerZombie", "ZombiePopulationManager.releaseZombie", "ZombiePopulationManager.virtualizeZombie",
                "IsoZombie.removeFromWorld",
                "Thermoregulator.getCatchAColdDelta", "CorpseCount.getCorpseCount",
                "BodyDamage.GetBaseCorpseSickness", "BodyDamage.AddRandomDamageFromZombie", "BodyPart.generateZombieInfection",
                "IsoGameCharacter.handleLandingImpact:impact", "IsoGameCharacter.DoLand", "IsoGameCharacter.damageWhileInTrees",
                "IsoGameCharacter.addHole", "IsoPlayer.calculateInTreesSpeed", "IsoPlayer.getDeferredMovement",
                "IsoObject.couldBePoweredByGenerator", "IsoObject.getGeneratorPowerConsumption", "IsoObject.renderAttachedSprites",
                "IsoObject.isAnimating", "Helicopter.writes:flight", "IsoWorld.writes:currentCell", "Helicopter.events", "IsoWorld.change", "Moodle.Update:level", "Moodles.GoodBadNeutral",
                "Moodles.<init>", "MoodlesUI.render", "UIManager.render:text",
                "ParameterZombieState.setState", "ZombieVocalsManager$Slot.playSound", "IsoZombie.handleLandingImpact", "IsoZombie.Hit",
                "FBORenderObjectOutline.render", "FBORenderObjectOutline.renderObject", "ModelSlotRenderData.initModel:outline", "ModelSlotRenderData.renderVehicle",
                "ModelSlotRenderData.initModel:light", "IsoObjectModelDrawer.renderMain:still", "ModelInstance$PlayerData.updateLights",
                "IsoGridSquare.BurnWalls", "IsoGridSquare.load", "FBORenderCell.renderOneLevel", "IsoGridSquare.RecalcProperties",
                "InventoryItem.*:useDelta", "DrainableComboItem.*:useDelta", "CraftRecipeData.luaCallOnCreate",
                "InventoryItem.getName", "InventoryItem.getDisplayName", "Food.getName", "Clothing.getName", "Moveable.getName" })
            check(Hooks.APPLIED.equals(hooks.rawget(label)), label + " is " + hooks.rawget(label));
        check(Hooks.hookStatus().size() == 128, "The hooks are " + Hooks.hookStatus().keySet());
        check(Hooks.weightTracked(), "The hooks that follow the weight are not all in");

        Method transform = Hooks.class.getDeclaredMethod("transform", String.class, byte[].class, ClassLoader.class);
        transform.setAccessible(true);
        String generator = "zombie/iso/objects/IsoGenerator";
        ClassLoader game = GameApiTest.class.getClassLoader();
        byte[] changed = (byte[])transform.invoke(null, generator, generator(false, false), game);
        check(changed != null && Hooks.APPLIED.equals(Hooks.hookStatus().get("IsoGenerator.setSurroundingElectricity"))
            && Hooks.APPLIED.equals(Hooks.hookStatus().get("IsoGenerator.update"))
            && Hooks.hookStatus().get("IsoGenerator.updateGenerator").contains("found 0"),
            "A missing method cost the class's other hooks: " + Hooks.hookStatus());
        changed = (byte[])transform.invoke(null, generator, generator(true, true), game);
        check(changed != null && Hooks.APPLIED.equals(Hooks.hookStatus().get("IsoGenerator.setSurroundingElectricity"))
            && Hooks.APPLIED.equals(Hooks.hookStatus().get("IsoGenerator.updateGenerator"))
            && Hooks.hookStatus().get("IsoGenerator.update").startsWith("its code could not be built"),
            "A method that cannot be built cost the class's other hooks: " + Hooks.hookStatus());

        var folder = Files.createTempDirectory("pzext-api-status");
        GameApi.writeStatus(folder);
        String status = Files.readString(folder.resolve(GameApi.STATUS), StandardCharsets.UTF_8);
        check(status.startsWith("PZEXT-API\t1\npid\t" + ProcessHandle.current().pid() + "\n")
            && status.contains("\nhook\tIsoGenerator.update\t") && status.contains("\nhook\tIsoGenerator.updateGenerator\tapplied\n"),
            "The status file is wrong: " + status);
        // The game's own class again: every hook is back.
        try (var input = game.getResourceAsStream(generator + ".class")) { transform.invoke(null, generator, input.readAllBytes(), game); }
        check(Hooks.APPLIED.equals(Hooks.hookStatus().get("IsoGenerator.update")), "The hooks did not come back");
        GameApi.writeStatus(folder);
        check(Files.readString(folder.resolve(GameApi.STATUS), StandardCharsets.UTF_8).contains("\nhook\tIsoGenerator.update\tapplied\n"),
            "The status file was not written again when it changed");
        try (var files = Files.list(folder)) { for (var file : files.toList()) Files.delete(file); }
        Files.delete(folder);

        // Water that keeps its taint needs both of IsoObject's taint hooks, as the class is now.
        String object = "zombie/iso/IsoObject";
        byte[] own;
        try (var input = game.getResourceAsStream(object + ".class")) { own = input.readAllBytes(); }
        var files = ClassFile.of();
        byte[] untainted = files.transformClass(files.parse(own), ClassTransform.dropping(element ->
            element instanceof MethodModel method && method.methodName().equalsString("isTaintedWater")));
        check(transform.invoke(null, object, untainted, game) != null && !Hooks.waterPurifyHooked()
            && Hooks.APPLIED.equals(Hooks.hookStatus().get("IsoObject.createSampleAndPurifyWater")),
            "Water that keeps its taint was offered with one of its two hooks");
        transform.invoke(null, object, own, game);
        check(Hooks.waterPurifyHooked() && Hooks.APPLIED.equals(Hooks.hookStatus().get("IsoObject.isTaintedWater")),
            "The taint hooks did not come back");
    }

    /** A generator class as another mod might have it: without updateGenerator, or with an update the game cannot verify. */
    private static byte[] generator(boolean updateGenerator, boolean unresolvable) {
        var self = ClassDesc.of("zombie.iso.objects.IsoGenerator");
        var none = MethodTypeDesc.of(ConstantDescs.CD_void);
        // No stack maps in the input; the hook's rebuilt method needs them, over types that cannot be loaded.
        return ClassFile.of(ClassFile.StackMapsOption.DROP_STACK_MAPS).build(self, type -> {
            type.withMethodBody("setSurroundingElectricity", none, ClassFile.ACC_PUBLIC, code -> code.return_());
            if (updateGenerator)
                type.withMethodBody("updateGenerator", MethodTypeDesc.of(ConstantDescs.CD_void, ClassDesc.of("zombie.iso.IsoGridSquare")),
                    ClassFile.ACC_PUBLIC, code -> code.return_());
            type.withMethodBody("update", none, ClassFile.ACC_PUBLIC, code -> {
                if (!unresolvable) { code.return_(); return; }
                var second = code.newLabel();
                var join = code.newLabel();
                code.aload(0).ifnull(second);
                code.aconst_null().checkcast(ClassDesc.of("pzext.missing.First")).goto_(join);
                code.labelBinding(second);
                code.aconst_null().checkcast(ClassDesc.of("pzext.missing.Second"));
                code.labelBinding(join);
                code.astore(1).return_();
            });
        });
    }

    private static void frame() { GameApi.frame(GameApiTest.class.getClassLoader()); }

    private static double load(KahluaTable networks) {
        return (Double)((KahluaTable)call(networks, "state", "grid").get(0)).rawget("load");
    }

    private static boolean near(double value, double expected) { return Math.abs(value - expected) < 1e-5; }

    private static KahluaTable at(int x, int y, int z) {
        KahluaTable result = LuaManager.platform.newTable();
        result.rawset("x", (double)x); result.rawset("y", (double)y); result.rawset("z", (double)z);
        return result;
    }

    private static KahluaTable list(Object... items) {
        KahluaTable result = LuaManager.platform.newTable();
        for (int index = 0; index < items.length; index++) result.rawset((double)(index + 1), items[index]);
        return result;
    }

    private static void rejects(KahluaTable networks, String name, String message, Object... arguments) {
        try { call(networks, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.networks." + name + ": ") && expected.getMessage().contains(message),
                expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static void takeover(KahluaTable api, KahluaTable buildings) throws Exception {
        Object handle = call(api, "client", "example.mod").get(0), at = buildings.rawget("at");
        // A newer API registers into the environment the game already has: the tables mods hold stay valid.
        GameApi.register(LuaManager.class);
        check(LuaManager.env.rawget(GameApi.GLOBAL) == api && api.rawget("buildings") == buildings, "The tables were replaced");
        check(buildings.rawget("at") != at, "The functions were not replaced");
        check(call(api, "client", "example.mod").get(0) == handle, "A mod's handle was lost");
        check(((KahluaTable)call(buildings, "at", 11.0, 11.0, 0.0).get(0)).rawget("key").equals(KEY), "The new functions fail");
        // A global of that name that is not the API's is replaced. A new environment gets its own table.
        LuaManager.env.rawset(GameApi.GLOBAL, 5.0);
        GameApi.register(LuaManager.class);
        check(LuaManager.env.rawget(GameApi.GLOBAL) instanceof KahluaTable, "A foreign global was kept");
        LuaManager.init();
        GameApi.register(LuaManager.class);
        check(LuaManager.env.rawget(GameApi.GLOBAL) != api, "A new environment shared the old table");
    }

    private static List<Object> call(KahluaTable table, String name, Object... arguments) {
        return invoke(table.rawget(name), arguments);
    }

    private static List<Object> invoke(Object function, Object... arguments) {
        var frame = new LuaCallFrame(arguments);
        int count = ((JavaFunction)function).call(frame, arguments.length);
        check(count == frame.results.size(), "The result count is wrong");
        return frame.results;
    }

    private static void error(KahluaTable table, String name, String message, Object... arguments) {
        try { call(table, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.buildings." + name + ": ") && expected.getMessage().contains(message),
                expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments");
    }

    private static Set<Object> sprites(Object list) {
        var result = new HashSet<Object>();
        var table = (KahluaTable)list;
        for (int index = 1; index <= table.len(); index++) result.add(((KahluaTable)table.rawget((double)index)).rawget("sprite"));
        return result;
    }

    private static KahluaTable find(Object list, String sprite) {
        var table = (KahluaTable)list;
        for (int index = 1; index <= table.len(); index++) {
            var entry = (KahluaTable)table.rawget((double)index);
            if (entry.rawget("sprite").equals(sprite)) return entry;
        }
        throw new AssertionError("No " + sprite);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
