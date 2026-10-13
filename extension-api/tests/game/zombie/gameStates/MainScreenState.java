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
 * Synthetic game entry for the loader test. Mirrors the order that matters: the log zip, then GameWindow, then the Lua.
 * Prints {@code PZEXT-FIXTURE <boot layer contract> <PZExtAPI.version>}, "null" for either that is not there.
 */
public final class MainScreenState {
    public static void main(String[] args) throws Exception {
        // The game zips its last logs first (ZipLogs.addZipFile): the JDK lists the installed file system providers,
        // which is when the loader starts. A provider that broke that list would fail here.
        Path zip = Files.createTempFile("pzext-fixture", ".zip");
        Files.delete(zip);
        try (FileSystem logs = FileSystems.newFileSystem(URI.create("jar:" + zip.toUri()), Map.of("create", "true"))) {
            Files.writeString(logs.getPath("log.txt"), "log");
        }
        Files.delete(zip);
        Class.forName("zombie.GameWindow");
        // The game's Lua starts later than this in the game; here it starts before the API can be ready, which the hook
        // at the end of LuaManager.init waits for. Mods load right after, and find the API.
        LuaManager.init();
        Object api = LuaManager.env.rawget("PZExtAPI");
        Object version = api instanceof KahluaTable table ? table.rawget("version") : null;
        // The game runs on: long enough for the API to write which hooks it has.
        if (version != null) Thread.sleep(1500);
        System.out.println("PZEXT-FIXTURE\t" + System.getProperty("pzext.boot") + "\t" + version);
    }
}
