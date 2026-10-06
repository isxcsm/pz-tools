package pztools.bridge.runtime.api;

import java.util.*;
import se.krka.kahlua.vm.*;
import zombie.Lua.LuaManager;
import zombie.iso.*;
import zombie.iso.SpriteDetails.IsoFlagType;
import zombie.iso.objects.IsoLightSwitch;
import zombie.iso.sprite.IsoSprite;

/**
 * The extension API as a Lua mod sees it, against the synthetic game of the startup loader test: the table, the facts
 * about buildings, the mods' handles, and a newer payload taking the table over.
 */
public final class GameApiTest {
    private GameApiTest() { }

    public static void main(String[] args) throws Exception {
        world();
        LuaManager.init();
        GameApi.register(LuaManager.class);
        KahluaTable api = (KahluaTable)LuaManager.env.rawget(GameApi.GLOBAL);
        check(api != null && api.rawget("version").equals(1.0), "The API table or its version is missing");
        KahluaTable buildings = (KahluaTable)api.rawget("buildings");
        at(buildings);
        rooms(buildings);
        objects(buildings);
        near(buildings);
        callerErrors(buildings);
        clients(api);
        takeover(api, buildings);
        System.out.println("PASS: the extension API reports buildings and their objects, and a newer payload takes its table over");
    }

    // A map building: a basement, a kitchen and a bedroom above it. A player-built shack. Another building's room.
    private static final String KEY = "11,11,-1";
    private static IsoGridSquare square(int x, int y, int z) { return IsoWorld.instance.cell.load(x, y, z); }

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
        square(11, 11, 0).objects.add(powered("fridge", 0.08f));
        var sink = new IsoObject(new IsoSprite("sink"));
        sink.sprite.properties.flags.add(IsoFlagType.waterPiped);
        square(12, 11, 0).objects.add(sink);
        square(10, 10, 0).objects.add(new IsoObject(new IsoSprite("chair")));
        // On the kitchen's south wall, so on the square beyond it, lighting the kitchen.
        var kitchenSwitch = new IsoLightSwitch(new IsoSprite("kitchen switch"));
        kitchenSwitch.roomId = 1;
        square(11, 13, 0).objects.add(kitchenSwitch);
        square(15, 11, 0).objects.add(powered("street light", 0.002f));
        // Two squares from the house, outside, but lighting the shack: it belongs to the shack, not to the house's surroundings.
        var shackSwitch = new IsoLightSwitch(new IsoSprite("shack switch"));
        shackSwitch.roomId = 99;
        square(15, 12, 0).objects.add(shackSwitch);
        square(20, 20, 0).objects.add(powered("shack fridge", 0.08f));
    }

    private static void room(IsoMetaGrid grid, RoomDef room, int x, int y, int w, int h) {
        room.rects.add(new RoomDef.RoomRect(x, y, w, h));
        grid.rooms.add(room);
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
        check(call(buildings, "near", KEY, 2.0).get(1).equals(false), "The bedroom level's unloaded surroundings were reported complete");
        var shack = call(buildings, "near", "20,20,0", 1.0);
        check(sprites(shack.get(0)).isEmpty() && shack.get(1).equals(true), "The shack's loaded surroundings were misreported");
        // Diagonal steps count as one: a corner of the house is within two of (15, 14).
        square(15, 14, 0).objects.add(powered("corner light", 0.002f));
        check(sprites(call(buildings, "near", KEY, 2.0).get(0)).equals(Set.of("street light", "corner light")), "A diagonal step was miscounted");
        square(15, 14, 0).objects.clear();
        boolean[] marked = new boolean[25];
        marked[12] = true;
        boolean[] ring = Buildings.dilate(marked, 5, 5, 1);
        int count = 0;
        for (boolean value : ring) if (value) count++;
        check(count == 9 && ring[6] && ring[18] && !ring[0], "Dilation is not a square");
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
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("PZToolsAPI.client"), expected.getMessage()); }
    }

    private static void takeover(KahluaTable api, KahluaTable buildings) throws Exception {
        Object handle = call(api, "client", "example.mod").get(0), at = buildings.rawget("at");
        // A newer payload registers into the environment the game already has: the tables mods hold stay valid.
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
            check(expected.getMessage().startsWith("PZToolsAPI.buildings." + name + ": ") && expected.getMessage().contains(message),
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
