package pztools.bridge.runtime.api;

import java.nio.ByteBuffer;
import java.util.*;
import pztools.bridge.ApiHooks;
import se.krka.kahlua.vm.*;
import zombie.GameTime;
import zombie.SandboxOptions;
import zombie.Lua.LuaEventManager;
import zombie.Lua.LuaManager;
import zombie.entity.components.fluids.FluidContainer;
import zombie.inventory.ItemContainer;
import zombie.inventory.types.Food;
import zombie.iso.*;
import zombie.iso.SpriteDetails.IsoFlagType;
import zombie.iso.objects.IsoGenerator;
import zombie.iso.objects.IsoLightSwitch;
import zombie.iso.objects.IsoRadio;
import zombie.iso.sprite.IsoSprite;

/**
 * The extension API as a Lua mod sees it, against the synthetic game of the startup loader test: the table, the facts
 * about buildings, the mods' handles, the power and water networks, and a newer payload taking the table over. The API's hooks
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
        sequence(api);
        children(api);
        switches(api);
        loadFactors(api);
        memberRooms(api);
        sources(api);
        water(api);
        food(api);
        takeover(api, buildings);
        System.out.println("PASS: the extension API reports buildings and their objects, runs power and water networks, switches them off and on, multiplies their loads, takes in single rooms, runs sources its mods switch, ages food by their supply, and a newer payload takes it over");
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

        // The first producer stops: no supply until the next one runs, which then carries the load.
        int checks = fridge.electricityChecks;
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
        rejects(networks, "define", "utility must be \"power\" or \"water\"", mod, "x", "gas", "sequential");
        rejects(networks, "define", "policy for power must be \"sequential\"", mod, "x", "power", "parallel");
        rejects(networks, "define", "policy for water must be \"fullest\"", mod, "x", "water", "sequential");
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

    /**
     * Under "sequential" one producer runs at a time. When it runs out, the next takes over from the hour it ran out,
     * also when its square was not loaded; the one switched on last carries the network; switched off, it stops it.
     * Each change is raised to Lua with the hour it happened.
     */
    private static void sequence(KahluaTable api) throws Exception {
        KahluaTable networks = (KahluaTable)api.rawget("networks");
        check(LuaEventManager.added.contains("OnPZToolsNetworkChange"), "The networks' event was not added");
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
        check(raised("supply", 100) && producer(networks) == 33.0 && !second.activated, "Switching the first on did not supply the network");
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
        var unloaded = IsoWorld.instance.cell.squares.remove("33,33,0");
        time.hours = 500;
        frame();
        int end = settledHour + (int)Math.ceil(settledFuel / settledPerHour);
        check(second.activated && second.lastHour() == end && producer(networks) == 34.0 && raised("producer", end),
            "The next did not take over from the hour an unloaded producer ran out: " + second.lastHour() + " for " + end);
        IsoWorld.instance.cell.squares.put("33,33,0", unloaded);
        first.update();
        frame();
        check(!first.activated && second.activated, "The first ran again after it loaded");
        // Switched off by the player: the network stops, and the API does not start another.
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
        call(networks, "remove", mod, "seq");
        frame();
        second.setActivated(false);
        // A world loaded with the first still running: the game makes up for the hours away as the first updates,
        // before a frame worked the network out. The second takes over from the hour the first ran out.
        time.hours = 600;
        first.fuel = 0.5f;
        first.setActivated(true);
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
        rejects(networks, "setParent", "third has producers", mod, "third", "main");
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
     * A network switched off has no supply, nor have its children; its producer keeps running without the load, which
     * still reads. Food in its fridge ages unchilled for the hours it was off, and a newer payload keeps the switch.
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
        // The parent off for ten hours: neither has supply, and the producer keeps running without the load.
        call(networks, "setEnabled", mod, "sub", true);
        time.hours = 2510;
        call(networks, "setEnabled", mod, "main", false);
        frame();
        main = state(networks, "main");
        check(main.rawget("supplied").equals(false) && state(networks, "sub").rawget("supplied").equals(false)
            && !square(11, 11, 0).haveElectricity() && !square(21, 21, 0).haveElectricity(), "A network switched off has supply");
        check(generator.isActivated() && near(generator.getTotalPowerUsing(), 0.02 * 0.1) && near((Double)main.rawget("load"), ownLoad + subLoad),
            "Switched off, the producer stopped, burned the load, or the load no longer reads");
        rejects(networks, "setEnabled", "on must be true or false", mod, "main", "yes");
        Object other = call(api, "client", "other.mod").get(0);
        rejects(networks, "setEnabled", "main belongs to another mod", other, "main", true);
        time.hours = 2520;
        call(networks, "setEnabled", mod, "main", true);
        frame();
        check(state(networks, "main").rawget("supplied").equals(true) && square(21, 21, 0).haveElectricity(), "Switched on again, no supply");
        time.hours = 2530;
        food.updateAge(false);
        check(near(food.age, (20 * 0.2 + 10) / 24), "Food aged chilled while the network was switched off: " + food.age * 24);
        // A newer payload keeps the switch, and counts a network it finds switched off as off before.
        call(networks, "setEnabled", mod, "main", false);
        GameApi.register(LuaManager.class);
        frame();
        check(state(networks, "main").rawget("enabled").equals(false) && !square(11, 11, 0).haveElectricity(), "A newer payload lost the switch");
        time.hours = 2540;
        food = aged(container, 2530);
        food.updateAge(false);
        check(near(food.age, 10 / 24.0), "Food aged chilled in a network a newer payload found switched off: " + food.age * 24);
        call(networks, "remove", mod, "sub");
        call(networks, "remove", mod, "main");
        frame();
        generator.setActivated(false);
    }

    /**
     * A load factor multiplies the load of a network and its children on its way to the producer: the state, the fuel
     * burned and the hours left follow it, a child's factor counts inside its parent's, and a newer payload keeps it.
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
        // A newer payload keeps the factors.
        GameApi.register(LuaManager.class);
        frame();
        check(state(networks, "main").rawget("loadFactor").equals(1.5) && state(networks, "sub").rawget("loadFactor").equals(2.0),
            "A newer payload lost the load factors");
        call(networks, "remove", mod, "sub");
        call(networks, "remove", mod, "main");
        frame();
        generator.setActivated(false);
    }

    /**
     * A network can take single rooms of a building instead of all of it: only their squares have power and only their
     * objects are its consumers. A room named again, or of a building it takes whole, changes nothing; a newer payload
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
        // A newer payload keeps the rooms.
        GameApi.register(LuaManager.class);
        frame();
        check(square(11, 11, -1).haveElectricity() && square(11, 11, 0).haveElectricity(), "A newer payload lost the rooms");
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
     * A source its mod runs carries the load like a generator: switched on by the mod it takes over, and the API switches
     * the generators off; when the mod says it can no longer run, the next producer takes over from the hour the mod
     * gives. Its extra load adds to the network's, and a newer payload keeps both.
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
        // A newer payload keeps the source switched on, and the extra load.
        GameApi.register(LuaManager.class);
        frame();
        state = state(networks, "solar");
        check(state.rawget("supplied").equals(true) && ((KahluaTable)state.rawget("producer")).rawget("source").equals("bank")
            && near((Double)state.rawget("ownLoad"), ownLoad + 0.5), "A newer payload lost the source or the extra load");
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
        // Dry: no supply, and the fixtures are the game's again.
        low.fluidContainer.amount = 0;
        high.fluidContainer.amount = 0;
        LuaEventManager.raised.clear();
        frame();
        check(state(networks, "pipes").rawget("supplied").equals(false) && !sink.getUsesExternalWaterSource()
            && raised("pipes", "supply", hours) && raised("annex", "supply", hours), "A dry network supplies water");
        // A failing hook gives the game's answers; a newer payload takes the networks over.
        high.fluidContainer.amount = 50;
        frame();
        ApiHooks.setWater(new ApiHooks.Water() {
            @Override public boolean plumbed(boolean vanilla, Object fixture) { throw new IllegalStateException("broken"); }
            @Override public Object source(Object vanilla, Object fixture) { throw new IllegalStateException("broken"); }
        });
        check(!sink.getUsesExternalWaterSource() && sink.getFluidAmount() == 0, "A failing hook did not give the game's answer");
        GameApi.register(LuaManager.class);
        frame();
        check(sink.getFluidAmount() == 50 && shed.getFluidAmount() == 50, "A newer payload did not take the water networks over");
        for (String id : List.of("annex", "pipes", "lights")) call(networks, "remove", mod, id);
        frame();
        check(!sink.getUsesExternalWaterSource() && !outside.getUsesExternalWaterSource(), "A removed network still supplies water");
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
        var unloaded = IsoWorld.instance.cell.squares.remove("34,33,0");
        time.hours = end + 50;
        frame();
        IsoWorld.instance.cell.squares.put("34,33,0", unloaded);
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
        return LuaEventManager.raised.stream().anyMatch(event -> event.equals(List.of("OnPZToolsNetworkChange", id, what, hour)));
    }

    /** The x of the producer in use, or NaN without supply. */
    private static double producer(KahluaTable networks) {
        var producer = (KahluaTable)((KahluaTable)call(networks, "state", "seq").get(0)).rawget("producer");
        return producer == null ? Double.NaN : (Double)producer.rawget("x");
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
