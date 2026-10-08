// Runs the mod's Lua unit tests outside the game, on the game's own Kahlua VM (the same number rules, the same
// string and table libraries). The game itself is not there: tests/unit/harness.lua stubs the few game functions
// the tested modules touch.
//   java -cp projectzomboid.jar tools/LuaTest.java [test name filter]
// Run it from the repository root. Exit code 0 when every test passed.
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaCallFrame;
import se.krka.kahlua.vm.Platform;

public class LuaTest {
    static final Path GAME = Path.of("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid");

    public static void main(String[] args) throws Exception {
        Platform platform = se.krka.kahlua.j2se.J2SEPlatform.getInstance();
        KahluaTable env = platform.newTable();
        env.rawset("_G", env);
        se.krka.kahlua.j2se.MathLib.register(platform, env);
        se.krka.kahlua.stdlib.BaseLib.register(env);
        se.krka.kahlua.stdlib.RandomLib.register(platform, env);
        se.krka.kahlua.stdlib.StringLib.register(platform, env);
        se.krka.kahlua.stdlib.CoroutineLib.register(platform, env);
        se.krka.kahlua.stdlib.OsLib.register(platform, env);
        se.krka.kahlua.stdlib.TableLib.register(platform, env);
        se.krka.kahlua.luaj.compiler.LuaCompiler.register(env);
        KahluaThread thread = new KahluaThread(System.out, platform, env);
        thread.debugOwnerThread = Thread.currentThread();
        se.krka.kahlua.vm.KahluaUtil.setupLibraryText(env, thread, GAME.resolve("stdlib.lua").toFile());

        // readfile(path): the file's text, or nil when it is not there.
        env.rawset("readfile", (JavaFunction) (LuaCallFrame frame, int n) -> {
            Path path = Path.of((String) frame.get(0));
            try { return frame.push(Files.readString(path, StandardCharsets.UTF_8)); }
            catch (Exception missing) { return frame.pushNil(); }
        });
        // listfiles(dir): the names of the files in it, as a table (1..n), sorted.
        env.rawset("listfiles", (JavaFunction) (LuaCallFrame frame, int n) -> {
            KahluaTable list = platform.newTable();
            try (var files = Files.list(Path.of((String) frame.get(0)))) {
                int i = 1;
                for (Path p : files.sorted().toList()) list.rawset((double) i++, p.getFileName().toString());
            } catch (Exception missing) { }
            return frame.push(list);
        });
        env.rawset("TEST_FILTER", args.length > 0 ? args[0] : "");

        String harness = Files.readString(Path.of("tests/unit/harness.lua"), StandardCharsets.UTF_8);
        Object closure = se.krka.kahlua.luaj.compiler.LuaCompiler.loadstring(harness, "harness.lua", env);
        Object[] result = thread.pcall(closure, new Object[0]);
        if (result.length > 0 && Boolean.FALSE.equals(result[0])) {
            System.out.println("harness failed: " + (result.length > 1 ? result[1] : "?"));
            if (result.length > 2) System.out.println(result[2]);
            System.exit(2);
        }
        Object failed = env.rawget("TEST_FAILED");
        System.exit(failed instanceof Double d && d == 0 ? 0 : 1);
    }
}
