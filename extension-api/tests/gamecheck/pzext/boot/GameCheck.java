package pzext.boot;

import java.io.IOException;
import java.io.InputStream;
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassModel;
import java.lang.classfile.FieldModel;
import java.lang.classfile.MethodModel;
import java.lang.reflect.AccessFlag;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * The API against a real game's own classes, without starting it: each hook is put into the class the game runs (the first
 * on the launcher file's class path, so a class another tool replaces is checked as it replaces it) and says whether it fits;
 * and the synthetic game the tests run (tests/game) is held to the real one: a member it shares by name with the real class
 * must have the real one's type and staticness, or the tests pass on a game that is not there. The differences the synthetic
 * game means (known.txt: a game type it gives as Object, a helper of its own that shares a game method's name) are counted, not
 * failed; one listed there that no longer differs is stale and fails, so the list stays true.
 *
 *     java -cp <classes>;pzext-boot.jar pzext.boot.GameCheck <game folder> [<synthetic game classes> <known.txt>]
 *
 * Prints what does not fit and a summary; exits 1 when a hook does not go in or a shared member differs unlisted.
 */
public final class GameCheck {
    private GameCheck() { }

    public static void main(String[] arguments) throws Exception {
        Path game = Path.of(arguments[0]);
        var loader = new URLClassLoader(classPath(game).toArray(URL[]::new), ClassLoader.getPlatformClassLoader());
        int failed = hooks(loader);
        if (arguments.length > 2) failed += synthetic(loader, Path.of(arguments[1]), Path.of(arguments[2]));
        System.out.println(failed == 0 ? "PASS: the game at " + game + " takes every hook, and the synthetic game is shaped as it is"
            : "FAIL: " + failed + " problem(s) with the game at " + game);
        System.exit(failed == 0 ? 0 : 1);
    }

    /** The launcher file's class path (ProjectZomboid64.json), in order, as files in the game's folder. */
    static List<URL> classPath(Path game) throws IOException {
        String launcher = Files.readString(game.resolve("ProjectZomboid64.json"));
        var list = Pattern.compile("\"classpath\"\\s*:\\s*\\[(.*?)]", Pattern.DOTALL).matcher(launcher);
        if (!list.find()) throw new IllegalStateException("no class path in " + game.resolve("ProjectZomboid64.json"));
        var urls = new ArrayList<URL>();
        var entry = Pattern.compile("\"([^\"]+)\"").matcher(list.group(1));
        while (entry.find()) {
            Path path = game.resolve(entry.group(1));
            if (Files.exists(path)) urls.add(path.toUri().toURL());
        }
        urls.add(game.toUri().toURL());
        return urls;
    }

    private static byte[] read(ClassLoader loader, String name) throws IOException {
        try (InputStream in = loader.getResourceAsStream(name + ".class")) { return in == null ? null : in.readAllBytes(); }
    }

    /** Puts every hook into its class as the game has it; the ones that do not go in, with why. */
    private static int hooks(ClassLoader loader) throws IOException {
        int absent = 0;
        for (String name : new TreeSet<>(Hooks.hookedClasses())) {
            byte[] bytes = read(loader, name);
            if (bytes == null) { System.out.println("no class " + name + " in the game"); absent++; continue; }
            Hooks.transform(name, bytes, loader);
        }
        int failed = absent;
        byte[] window = read(loader, "zombie/GameWindow");
        try { FrameHook.transformWindow(window, loader); }
        catch (RuntimeException problem) { System.out.println("the frame hook: " + problem.getMessage()); failed++; }
        Map<String, String> status = Hooks.hookStatus();
        int applied = 0;
        for (var hook : status.entrySet()) {
            if (Hooks.APPLIED.equals(hook.getValue())) applied++;
            else if (!Hooks.NOT_LOADED.equals(hook.getValue())) { System.out.println("no hook " + hook.getKey() + ": " + hook.getValue()); failed++; }
        }
        System.out.println("hooks: " + applied + " of " + status.size() + " go in (and the frame hook" + (failed > absent ? " or not" : "") + ")");
        return failed;
    }

    /**
     * The synthetic game's classes held to the real ones: a member shared by name must match (a method: one real method of the
     * name with its type; static or not alike). A member the real class lacks is the synthetic game's own (counted, not a problem).
     */
    private static int synthetic(ClassLoader loader, Path classes, Path knownFile) throws IOException {
        var known = new TreeSet<String>();
        for (String line : Files.readAllLines(knownFile)) if (!line.isBlank() && !line.startsWith("#")) known.add(line.trim());
        var differing = new TreeSet<String>();
        var files = new ArrayList<Path>();
        try (Stream<Path> walk = Files.walk(classes)) { walk.filter(p -> p.toString().endsWith(".class")).forEach(files::add); }
        int failed = 0, own = 0, ownClasses = 0, checked = 0;
        var cf = ClassFile.of();
        for (Path file : files) {
            String name = classes.relativize(file).toString().replace('\\', '/').replaceAll("\\.class$", "");
            if (!name.startsWith("zombie/") && !name.startsWith("se/") && !name.startsWith("fmod/") && !name.startsWith("org/")) continue;
            byte[] realBytes = read(loader, name);
            if (realBytes == null) { ownClasses++; continue; }
            ClassModel fake = cf.parse(Files.readAllBytes(file)), real = cf.parse(realBytes);
            var methods = new TreeMap<String, List<MethodModel>>();
            for (MethodModel m : real.methods()) methods.computeIfAbsent(m.methodName().stringValue(), k -> new ArrayList<>()).add(m);
            for (MethodModel m : fake.methods()) {
                String method = m.methodName().stringValue();
                if (method.equals("<clinit>") || m.flags().has(AccessFlag.SYNTHETIC) || m.flags().has(AccessFlag.PRIVATE)) continue;
                var same = methods.get(method);
                if (same == null) { own++; continue; }
                String type = m.methodType().stringValue();
                MethodModel match = same.stream().filter(r -> r.methodType().stringValue().equals(type)).findFirst().orElse(null);
                checked++;
                if (match == null) {
                    // Constructors and overloads: the synthetic game may add its own; only a name with no real type of it is told.
                    if (method.equals("<init>") || same.size() > 1) { own++; checked--; continue; }
                    String key = name + "." + method + type;
                    differing.add(key);
                    if (!known.contains(key)) { System.out.println("synthetic " + key + ": the game's is " + same.get(0).methodType().stringValue()); failed++; }
                } else if (m.flags().has(AccessFlag.STATIC) != match.flags().has(AccessFlag.STATIC)) {
                    String key = name + "." + method + type;
                    differing.add(key);
                    if (!known.contains(key)) {
                        System.out.println("synthetic " + key + ": static " + m.flags().has(AccessFlag.STATIC) + ", the game's " + match.flags().has(AccessFlag.STATIC));
                        failed++;
                    }
                }
            }
            var fields = new TreeMap<String, FieldModel>();
            for (FieldModel f : real.fields()) fields.put(f.fieldName().stringValue(), f);
            for (FieldModel f : fake.fields()) {
                if (f.flags().has(AccessFlag.SYNTHETIC) || f.flags().has(AccessFlag.PRIVATE)) continue;
                FieldModel match = fields.get(f.fieldName().stringValue());
                if (match == null) { own++; continue; }
                checked++;
                if (!match.fieldType().stringValue().equals(f.fieldType().stringValue())
                        || match.flags().has(AccessFlag.STATIC) != f.flags().has(AccessFlag.STATIC)) {
                    String key = name + "." + f.fieldName().stringValue() + " " + f.fieldType().stringValue() + (f.flags().has(AccessFlag.STATIC) ? " static" : "");
                    differing.add(key);
                    if (!known.contains(key)) {
                        System.out.println("synthetic " + key + ": the game's is " + match.fieldType().stringValue()
                            + (match.flags().has(AccessFlag.STATIC) ? " static" : ""));
                        failed++;
                    }
                }
            }
        }
        for (String stale : known) if (!differing.contains(stale)) { System.out.println("known.txt lists " + stale + ", which no longer differs: drop it"); failed++; }
        System.out.println("synthetic game: " + checked + " members held to the game's (" + (differing.size()) + " differing, " + known.size()
            + " of them listed), " + own + " of its own, " + ownClasses + " classes the game has not");
        return failed;
    }
}
