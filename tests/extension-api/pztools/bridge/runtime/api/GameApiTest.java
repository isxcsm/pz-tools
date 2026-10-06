package pztools.bridge.runtime.api;

import java.util.*;
import pztools.bridge.ApiHooks;
import se.krka.kahlua.vm.*;
import zombie.Lua.LuaManager;
import zombie.inventory.ItemContainer;
import zombie.iso.*;
import zombie.iso.SpriteDetails.IsoFlagType;
import zombie.iso.objects.IsoGenerator;
import zombie.iso.objects.IsoLightSwitch;
import zombie.iso.objects.IsoRadio;
import zombie.iso.sprite.IsoSprite;

/**
 * The extension API as a Lua mod sees it, against the synthetic game of the startup loader test: the table, the facts
 * about buildings, the mods' handles, the power networks, and a newer payload taking the table over. The API's hooks
 * are in the game's classes, put there by {@link pztools.bridge.ApiTestAgent} as the startup loader's bootstrap does.
 */
public final class GameApiTest {
    private GameApiTest() { }

    public static void main(String[] args) throws Exception {
        world();
        // As in the game: the payload sets the handler, and the hook sets the API as the game's Lua starts.
        GameApi.start();
        LuaManager.init();
        KahluaTable api = (KahluaTable)LuaManager.env.rawget(GameApi.GLOBAL);
        check(api != null && api.rawget("version").equals(1.0), "The API table or its version is missing");
        KahluaTable buildings = (KahluaTable)api.rawget("buildings");
        at(buildings);
        rooms(buildings);
        objects(buildings);
        near(buildings);
        callerErrors(buildings);
        clients(api);
        networks(api);
        takeover(api, buildings);
        System.out.println("PASS: the extension API reports buildings and their objects, runs power networks, and a newer payload takes it over");
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
        check(call(buildings, "near", KEY, 2.0).get(1).equals(false), "The bedroom level's unloaded surroundings were reported complete");
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
        check(!square(9, 11, 0).haveElectricity() && !square(11, 13, 0).haveElectricity(), "A square outside the house has power");
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
        // The game says when something that uses power changed.
        radio.consumption = 0.03f;
        IsoGenerator.updateGenerator(radio.square);
        frame();
        check(near(load(networks), 0.032), "A consumer's change was missed: " + load(networks));
        call(networks, "reset", mod, "grid", 11.0, 11.0, 0.0, "fridge");
        frame();
        check(ItemContainer.isObjectPowered(fridge, true) && near(load(networks), 0.112), "Reset did not give the fridge back");

        // The first producer stops: no supply until the next one runs, which then carries the load.
        int checks = fridge.electricityChecks;
        first.setActivated(false);
        frame();
        state = (KahluaTable)call(networks, "state", "grid").get(0);
        check(state.rawget("supplied").equals(false) && state.rawget("producer") == null && !square(11, 11, 0).haveElectricity()
            && !ItemContainer.isObjectPowered(light, true), "A network without a running producer has supply");
        check(fridge.electricityChecks > checks, "The consumers were not told that the power went");
        second.setActivated(true);
        frame();
        state = (KahluaTable)call(networks, "state", "grid").get(0);
        check(((KahluaTable)state.rawget("producer")).rawget("x").equals(31.0) && square(11, 11, 0).haveElectricity()
            && !square(33, 30, 0).haveElectricity(), "The second producer does not carry the network");
        check(near(second.getTotalPowerUsing(), (0.02 + 0.112) * 0.1) && near(first.getTotalPowerUsing(), 0.02 * 0.1), "The load moved wrongly");

        // A handler that fails gives the game's answers; a newer payload takes the definitions over.
        ApiHooks.setPower(new ApiHooks.Power() {
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
            && ItemContainer.isObjectPowered(light, true), "A newer payload did not take the networks over");

        // Each network belongs to its mod.
        Object other = call(api, "client", "other.mod").get(0);
        rejects(networks, "define", "grid belongs to another mod", other, "grid", "power", "sequential");
        rejects(networks, "addBuilding", "grid belongs to another mod", other, "grid", 1.0, 1.0, 0.0);
        call(networks, "define", other, "second", "power", "sequential");
        rejects(networks, "setProducers", "31,30,0 is a producer of the network grid", other, "second", list(at(31, 30, 0)));
        rejects(networks, "define", "utility must be \"power\"", mod, "water", "water", "fullest");
        rejects(networks, "define", "policy must be \"sequential\"", mod, "x", "power", "parallel");
        rejects(networks, "define", "id must be 1 to 64", mod, "no spaces", "power", "sequential");
        rejects(networks, "define", "the first argument must be a handle", "power.mod", "x", "power", "sequential");
        rejects(networks, "exclude", "sprite must be a sprite name", mod, "grid", 1.0, 1.0, 0.0, "");
        rejects(networks, "setProducers", "producers[1]: x must be a whole number", mod, "grid", list(LuaManager.platform.newTable()));
        rejects(networks, "setProducers", "is listed twice", mod, "grid", list(at(1, 1, 0), at(1, 1, 0)));
        rejects(networks, "include", "there is no network nothing", mod, "nothing", 1.0, 1.0, 0.0, "lamp");
        check(call(networks, "state", "nothing").get(0) == null && call(networks, "consumers", "nothing").get(0) == null,
            "A network that does not exist has a state");

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
        IsoWorld.instance = null;
        frame();
        IsoWorld.instance = world;
        frame();
        check(call(networks, "state", "second").get(0) == null, "A world's networks outlived it");
        second.setActivated(false);
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
            check(expected.getMessage().startsWith("PZToolsAPI.networks." + name + ": ") && expected.getMessage().contains(message),
                expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
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
