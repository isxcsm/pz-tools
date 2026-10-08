// Compiles Lua files with the game's own Kahlua compiler: a syntax check as the game would load them. Without
// arguments it checks every .lua file of the mod and the tests.
// java -cp projectzomboid.jar LuaCheck.java [<file>...]
//
// It also flags a name a file reads or writes as a global while the same file declares a local of that name: almost
// always a local used before its declaration (found in game: the research plan's iconSize was nil, so the window
// failed to open). A name the game really has as a global can be listed in ALLOWED.
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

public class LuaCheck {
    private static final int GETGLOBAL = 5, SETGLOBAL = 7;
    private static final Set<String> ALLOWED = Set.of();
    private static final Pattern ALIAS = Pattern.compile("\\blocal\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*\\1\\b");
    private static final Pattern LOCAL = Pattern.compile("\\blocal\\s+(?:function\\s+)?([A-Za-z_][A-Za-z0-9_]*(?:\\s*,\\s*[A-Za-z_][A-Za-z0-9_]*)*)");

    public static void main(String[] args) throws Exception {
        List<Path> files = new ArrayList<>();
        if (args.length == 0) {
            for (String root : new String[] { "OperationAcorn", "tests" }) {
                try (Stream<Path> walk = Files.walk(Path.of(root))) {
                    walk.filter(p -> p.toString().endsWith(".lua")).sorted().forEach(files::add);
                }
            }
        } else {
            for (String arg : args) files.add(Path.of(arg));
        }
        int failed = 0;
        var platform = new se.krka.kahlua.j2se.J2SEPlatform();
        for (Path file : files) {
            String source = Files.readString(file, StandardCharsets.UTF_8);
            se.krka.kahlua.vm.LuaClosure closure;
            try (Reader reader = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
                closure = se.krka.kahlua.luaj.compiler.LuaCompiler.loadis(reader, file.getFileName().toString(), platform.newTable());
            } catch (Exception failure) {
                failed++;
                System.out.println("FAIL " + file + ": " + failure.getMessage());
                continue;
            }
            Set<String> locals = new TreeSet<>();
            Matcher m = LOCAL.matcher(source);
            while (m.find()) for (String name : m.group(1).split("\\s*,\\s*")) locals.add(name.trim());
            // `local X = X` keeps a global in a local on purpose: reading the global there is right.
            Matcher alias = ALIAS.matcher(source);
            while (alias.find()) locals.remove(alias.group(1));
            Set<String> globals = new TreeSet<>();
            collect(closure.prototype, globals);
            List<String> suspicious = new ArrayList<>();
            for (String name : globals) if (locals.contains(name) && !ALLOWED.contains(name)) suspicious.add(name);
            if (suspicious.isEmpty()) {
                if (args.length > 0) System.out.println("ok   " + file.getFileName());
            } else {
                failed++;
                System.out.println("FAIL " + file + ": used as a global but declared local in the file (used before its declaration?): " + suspicious);
            }
        }
        System.out.println(files.size() + " files, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }

    // The names of the globals a function and the functions inside it read or write.
    private static void collect(se.krka.kahlua.vm.Prototype prototype, Set<String> into) {
        for (int instruction : prototype.code) {
            int op = instruction & 0x3F;
            if (op == GETGLOBAL || op == SETGLOBAL) {
                Object constant = prototype.constants[instruction >>> 14];
                if (constant instanceof String name) into.add(name);
            }
        }
        if (prototype.prototypes != null) for (var inner : prototype.prototypes) collect(inner, into);
    }
}
