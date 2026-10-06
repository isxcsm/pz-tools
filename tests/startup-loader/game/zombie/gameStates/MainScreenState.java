package zombie.gameStates;

import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;

/** Synthetic game entry for the startup loader test. Mirrors the order that matters: the property list, then GameWindow. */
public final class MainScreenState {
    public static void main(String[] args) throws Exception {
        // The game writes every system property to its log here; the control secret must not be among them yet.
        boolean endpointAtListing = System.getProperty("pztools.bridge.control.v1") != null;
        Class.forName("zombie.GameWindow");
        boolean endpointAfter = System.getProperty("pztools.bridge.control.v1") != null;
        // The game's Lua starts later than this in the game; here it starts before the bridge's payload can be ready,
        // which the extension API's hook waits for. Mods load right after, and find the API.
        LuaManager.init();
        Object api = LuaManager.env.rawget("PZToolsAPI");
        Object version = api instanceof KahluaTable table ? table.rawget("version") : null;
        // Loaded at the start, the bridge starts the controller that runs the extensions without the app.
        boolean resident = false;
        if (System.getProperty("pztools.bridge.bootstrap.api") != null)
            for (int wait = 0; wait < 100 && !(resident = Thread.getAllStackTraces().keySet().stream()
                    .anyMatch(thread -> thread.getName().equals("PzTools-resident-extensions"))); wait++) Thread.sleep(100);
        System.out.println("STARTUP-FIXTURE\t" + System.getProperty("pztools.bridge.bootstrap.api") + "\t"
            + endpointAtListing + "\t" + endpointAfter + "\t" + resident + "\t" + version);
    }
}
