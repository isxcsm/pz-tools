package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * {@code PZToolsAPI.helicopter}: the game's helicopter (the one that flies over a world, {@code IsoWorld.helicopter}),
 * which Lua cannot reach. Its state is read once a frame, on the game's thread, and a change of it is raised as the Lua
 * event {@code OnPZToolsHelicopter(state, target, x, y)}.
 *
 * <p>The state is read, not hooked, because the game writes it in five places (when a target is set, in {@code changeState},
 * straight in {@code update} when the target is gone or dead, when a save loads and when a client is synced) and takes the
 * helicopter off in two ({@code deactivate} and {@code pickRandomTarget} with nobody to fly to). Reading it sees every write
 * and cannot be missed by a change in the shape of one method; the cost is a few field reads a frame, and an event comes at
 * the start of the frame after the change.
 */
final class Helicopters {
    static final String EVENT = "OnPZToolsHelicopter";
    /** The state the API reports while the helicopter is not flying. */
    static final String INACTIVE = "Inactive";
    private static final String AREA = "PZToolsAPI.helicopter.";

    private final Kahlua lua;
    private final Game game;
    // IsoWorld.instance and IsoWorld.helicopter.
    private final Field world, helicopter;
    // Helicopter.isActive(); the protected state (an enum of the game's) and Enum.name().
    private final MethodHandle active, state, name, target, x, y;
    // The helicopter and state the last frame saw; null before the first.
    private Object seen;
    private String last;

    Helicopters(Kahlua lua, Game game, ClassLoader loader) throws ReflectiveOperationException, IllegalAccessException {
        this.lua = lua;
        this.game = game;
        Class<?> worldType = Game.type(loader, "zombie.iso.IsoWorld"), type = Game.type(loader, "zombie.iso.Helicopter");
        world = worldType.getField("instance");
        helicopter = worldType.getField("helicopter");
        active = Game.exact(type.getMethod("isActive"), MethodType.methodType(boolean.class, Object.class));
        Field stateField = Game.accessible(type.getDeclaredField("state"));
        state = MethodHandles.lookup().unreflectGetter(stateField).asType(MethodType.methodType(Object.class, Object.class));
        Method enumName = Enum.class.getMethod("name");
        name = MethodHandles.publicLookup().unreflect(enumName).asType(MethodType.methodType(String.class, Object.class));
        target = MethodHandles.publicLookup().unreflectGetter(type.getField("target")).asType(MethodType.methodType(Object.class, Object.class));
        x = MethodHandles.publicLookup().unreflectGetter(type.getField("x")).asType(MethodType.methodType(float.class, Object.class));
        y = MethodHandles.publicLookup().unreflectGetter(type.getField("y")).asType(MethodType.methodType(float.class, Object.class));
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, and makes the event known to the game. */
    void register(Object table) throws ReflectiveOperationException {
        game.addEvent(EVENT);
        lua.set(table, "state", lua.function(AREA + "state", arguments -> {
            Object flying = helicopter();
            if (flying == null) return new Object[] { INACTIVE };
            try { return current(flying); }
            catch (Throwable failure) { throw Game.failed(Game.thrown(failure)); }
        }));
    }

    /** Each frame, on the game's thread: raises the event for a change since the last frame. */
    void frame() throws Throwable {
        Object flying = helicopter();
        if (flying == null) { seen = null; last = null; return; }
        String now = stateName(flying);
        // The first look at a helicopter is its state, not a change: a mod reads it with state() (a newer API taking over
        // while it hovers must not tell the mod that it started to).
        if (flying != seen || last == null) { seen = flying; last = now; return; }
        if (now.equals(last)) return;
        last = now;
        game.raise(EVENT, now, (Object)target.invokeExact(flying), (double)(float)x.invokeExact(flying), (double)(float)y.invokeExact(flying));
    }

    /** The state the helicopter has now, its target and its position: nothing but the state while it is not flying. */
    private Object[] current(Object flying) throws Throwable {
        String now = stateName(flying);
        if (INACTIVE.equals(now)) return new Object[] { now };
        return new Object[] { now, (Object)target.invokeExact(flying), (double)(float)x.invokeExact(flying), (double)(float)y.invokeExact(flying) };
    }

    private String stateName(Object flying) throws Throwable {
        if (!(boolean)active.invokeExact(flying)) return INACTIVE;
        Object value = (Object)state.invokeExact(flying);
        return value == null ? INACTIVE : (String)name.invokeExact(value);
    }

    /** The game's helicopter, or null without a world. */
    private Object helicopter() throws ReflectiveOperationException {
        Object current = world.get(null);
        return current == null ? null : helicopter.get(current);
    }
}
