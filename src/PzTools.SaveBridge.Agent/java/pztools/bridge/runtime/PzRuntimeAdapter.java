package pztools.bridge.runtime;

import java.lang.reflect.*;

/** All Build-42/Java-25 field knowledge lives here, not in scheduling or transport. */
final class PzRuntimeAdapter {
    private final Class<?> window, ingame;
    private final Method paused, currentSave, speedControls, speed, coreInstance, noSave, gameMode;
    private final Field states, current, worldInstance, cell, fsInstance, client, clientSave, server, exiting;
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
        boolean loaded = machine != null && ingame.isInstance(current.get(machine));
        mode = client.getBoolean(null) || clientSave.getBoolean(null) || server.getBoolean(null)
            ? "Networked" : "LocalSinglePlayer";
        Object core = coreInstance.invoke(null, none);
        String currentMode = (String)gameMode.invoke(core, none);
        if ((boolean)noSave.invoke(core, none) || "LastStand".equals(currentMode) || "Tutorial".equals(currentMode)) mode = "Unsupported";
        phase = exiting.getBoolean(null) ? "Unloading" : loaded ? nextCell == null ? "Loading" : "Ready" : "Menu";
        if (!phase.equals("Ready")) { path = null; worldCell = null; pause = "Unknown"; speedLevel = -1; return; }
        // The path may allocate and is looked up once per world, not on every frame.
        if (nextCell != worldCell || path == null) path = (String)currentSave.invoke(fsInstance.get(null), none);
        worldCell = nextCell;
        Object controls = speedControls.invoke(null, none);
        speedLevel = controls == null ? -1 : (int)speed.invoke(controls, none);
        pause = controls == null ? "Unknown" : (boolean)paused.invoke(null, none) ? "Paused" : "Running";
    }
}