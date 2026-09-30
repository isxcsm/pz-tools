package pztools.bridge.runtime;

import java.lang.reflect.*;

/** All Build-42/Java-25 field knowledge lives here, not in scheduling or transport. */
final class PzRuntimeAdapter {
    private final Class<?> window, ingame;
    private final Method paused, currentSave, speedControls, speed, coreInstance, noSave, gameMode;
    private final Field states, current, worldInstance, cell, fsInstance, client, clientSave, server, exiting;
    /** Optional: the states the game has yielded to run another state on top (debug tools). */
    private final Field yieldStack;
    private final Object[] none = new Object[0];
    String phase = "Unknown", pause = "Unknown", mode = "Unsupported", path;
    int speedLevel = -1;
    String gameVersion;
    private boolean versionRead;
    Object worldCell;

    PzRuntimeAdapter(Class<?> window) throws ReflectiveOperationException {
        this.window = window;
        ClassLoader loader = window.getClassLoader();
        ingame = Class.forName("zombie.gameStates.IngameState", false, loader);
        states = window.getField("states");
        current = states.getType().getField("current");
        Field stack = null;
        try { stack = states.getType().getDeclaredField("yieldStack"); stack.setAccessible(true); }
        catch (ReflectiveOperationException | RuntimeException unavailable) { /* Then a yielded game reads as before. */ }
        yieldStack = stack;
        Class<?> world = Class.forName("zombie.iso.IsoWorld", false, loader);
        worldInstance = world.getField("instance"); cell = world.getField("currentCell");
        Class<?> fs = Class.forName("zombie.ZomboidFileSystem", false, loader);
        fsInstance = fs.getField("instance"); currentSave = fs.getMethod("getCurrentSaveDir");
        Class<?> network = Class.forName("zombie.network.GameClient", false, loader);
        client = network.getField("client"); clientSave = network.getField("clientSave");
        server = Class.forName("zombie.network.GameServer", false, loader).getField("server");
        Class<?> core = Class.forName("zombie.core.Core", false, loader);
        exiting = core.getField("exiting"); coreInstance = core.getMethod("getInstance"); noSave = core.getMethod("isNoSave"); gameMode = core.getMethod("getGameMode");
        paused = Class.forName("zombie.GameTime", false, loader).getMethod("isGamePaused");
        speedControls = Class.forName("zombie.ui.UIManager", false, loader).getMethod("getSpeedControls");
        speed = Class.forName("zombie.ui.SpeedControls", false, loader).getMethod("getCurrentGameSpeed");
    }

    static String readVersion(ClassLoader loader) {
        try {
            Class<?> core = Class.forName("zombie.core.Core", false, loader);
            String value = (String)core.getMethod("getVersionNumber").invoke(core.getMethod("getInstance").invoke(null));
            return value != null && value.length() <= 80 && value.indexOf('\0') < 0 ? value : null;
        } catch (ReflectiveOperationException | RuntimeException unavailable) { return null; }
    }
    void read() throws ReflectiveOperationException {
        // Metadata failure must never invalidate pause/active-time observations.
        if (!versionRead) { gameVersion = readVersion(window.getClassLoader()); versionRead = true; }
        Object machine = states.get(null), world = worldInstance.get(null);
        Object nextCell = world == null ? null : cell.get(world);
        Object state = machine == null ? null : current.get(machine);
        boolean loaded = ingame.isInstance(state);
        // A debug tool (the chunk viewer, for example) yields the game and runs on top of it. The world
        // stays loaded and game time stands still: that is a pause, not the end of the world.
        boolean yielded = !loaded && nextCell != null && machine != null && yieldedFromGame(machine);
        mode = client.getBoolean(null) || clientSave.getBoolean(null) || server.getBoolean(null)
            ? "Networked" : "LocalSinglePlayer";
        Object core = coreInstance.invoke(null, none);
        String currentMode = (String)gameMode.invoke(core, none);
        if ((boolean)noSave.invoke(core, none) || "LastStand".equals(currentMode) || "Tutorial".equals(currentMode)) mode = "Unsupported";
        // A non-playing state is not necessarily the main menu: loading, startup and
        // unknown states must not be presented as an observed main screen. These final
        // game classes are identified without loading or initializing additional types.
        phase = exiting.getBoolean(null) ? "Unloading" : loaded || yielded ? nextCell == null ? "Loading" : "Ready"
            : state == null ? "Unknown" : switch (state.getClass().getName()) {
                case "zombie.gameStates.MainScreenState" -> "Menu";
                case "zombie.gameStates.GameLoadingState" -> "Loading";
                default -> "Unknown";
            };
        if (!phase.equals("Ready")) { path = null; worldCell = null; pause = "Unknown"; speedLevel = -1; return; }
        // The path may allocate and is looked up once per world, not on every frame.
        if (nextCell != worldCell || path == null) path = (String)currentSave.invoke(fsInstance.get(null), none);
        worldCell = nextCell;
        Object controls = speedControls.invoke(null, none);
        speedLevel = controls == null ? -1 : (int)speed.invoke(controls, none);
        pause = yielded ? "Paused" : controls == null ? "Unknown" : (boolean)paused.invoke(null, none) ? "Paused" : "Running";
    }

    private boolean yieldedFromGame(Object machine) throws ReflectiveOperationException {
        if (yieldStack == null || !(yieldStack.get(machine) instanceof java.util.List<?> yielded)) return false;
        for (Object state : yielded) if (ingame.isInstance(state)) return true;
        return false;
    }
}
