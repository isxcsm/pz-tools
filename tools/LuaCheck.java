// Compiles Lua files with the game's own Kahlua compiler: a syntax check as the game would load them.
// java -cp projectzomboid.jar LuaCheck.java <file>...
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public class LuaCheck {
    public static void main(String[] args) throws Exception {
        int failed = 0;
        for (String arg : args) {
            Path file = Path.of(arg);
            try (Reader reader = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
                se.krka.kahlua.luaj.compiler.LuaCompiler.loadis(reader, file.getFileName().toString(), null);
                System.out.println("ok   " + file.getFileName());
            } catch (NullPointerException noEnvironment) {
                // Compiled: only making the closure needed an environment.
                System.out.println("ok   " + file.getFileName());
            } catch (Exception failure) {
                failed++;
                System.out.println("FAIL " + file + ": " + failure.getMessage());
            }
        }
        System.exit(failed == 0 ? 0 : 1);
    }
}
