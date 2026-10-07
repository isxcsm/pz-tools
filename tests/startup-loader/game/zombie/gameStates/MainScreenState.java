package zombie.gameStates;

import java.net.URI;
import java.nio.file.FileSystem;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;

/**
 * Synthetic game entry for the startup loader test. Mirrors the order that matters: the log zip, the property list,
 * then GameWindow.
 */
public final class MainScreenState {
    public static void main(String[] args) throws Exception {
        // The game zips its last logs first (ZipLogs.addZipFile): the JDK lists the installed file system providers,
        // which is when the loader starts. A provider that broke that list would fail here.
        Path zip = Files.createTempFile("startup-fixture", ".zip");
        Files.delete(zip);
        try (FileSystem logs = FileSystems.newFileSystem(URI.create("jar:" + zip.toUri()), Map.of("create", "true"))) {
            Files.writeString(logs.getPath("log.txt"), "log");
        }
        Files.delete(zip);
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
