// Looks things up in the game's own classes, without the game: what a class has, who calls a method (or reads a field,
// or makes an object), what a method calls, and which methods hold a string (where a log line comes from).
//   java ../tools/PzJar.java find <regex>        members whose "class.name descriptor" matches
//   java ../tools/PzJar.java callers <regex>     methods that call, read, write or make what matches
//   java ../tools/PzJar.java calls <regex>       what the methods that match call, read, write or make
//   java ../tools/PzJar.java strings <regex>     methods with a string constant that matches, shown ("+" joins as {})
//   java ../tools/PzJar.java class <class> [-c]  the class's members (javap -p), its bytecode too with -c
// Options: --game <folder> (the Steam one by default), --jar <file> also index that jar (the classpath's other jars,
// e.g. pzopt's overrides), --limit <n> lines (200). Names are dotted (zombie.ui.UIManager.render ()V); a regex is found
// anywhere in the line, so "UIManager\.getFadeAlpha" is enough. Lambdas and method references count as calls of the
// method they are in (a lambda's body is its own lambda$... method, as the compiler made it).
// The index is built once for each version of the jars (their size and time), in %LOCALAPPDATA%\pzjar, in seconds.
// Runs on JDK 24 or newer (java.lang.classfile): the bundled one, artifacts/toolchains/jdk-25*.
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassModel;
import java.lang.classfile.CodeElement;
import java.lang.classfile.FieldModel;
import java.lang.classfile.MethodModel;
import java.lang.classfile.instruction.ConstantInstruction;
import java.lang.classfile.instruction.FieldInstruction;
import java.lang.classfile.instruction.InvokeDynamicInstruction;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.classfile.instruction.NewObjectInstruction;
import java.lang.reflect.AccessFlag;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;
import java.util.spi.ToolProvider;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public class PzJar {
    static final Path STEAM = Path.of("C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid");

    public static void main(String[] args) throws Exception {
        Path game = STEAM;
        List<Path> jars = new ArrayList<>();
        int limit = 200;
        List<String> rest = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--game" -> game = Path.of(args[++i]);
                case "--jar" -> jars.add(Path.of(args[++i]));
                case "--limit" -> limit = Integer.parseInt(args[++i]);
                default -> rest.add(args[i]);
            }
        }
        jars.add(0, game.resolve("projectzomboid.jar"));
        if (rest.size() < 2) {
            System.out.println("usage: PzJar.java find|callers|calls|strings <regex>, or class <class> [-c]");
            System.exit(2);
        }
        String what = rest.get(0), arg = rest.get(1);
        if (what.equals("class")) {
            List<String> javap = new ArrayList<>(List.of("-p", "-cp", String.join(java.io.File.pathSeparator,
                jars.stream().map(Path::toString).toList())));
            if (rest.contains("-c")) javap.add("-c");
            javap.add(arg);
            ToolProvider tool = ToolProvider.findFirst("javap").orElseThrow();
            System.exit(tool.run(System.out, System.err, javap.toArray(String[]::new)));
        }
        Path index = index(jars);
        Pattern pattern = Pattern.compile(arg);
        // members.txt: "class.name descriptor[ static]"; refs.txt: "caller<TAB>kind<TAB>target", the kind
        // call/get/put/new/str
        int shown = 0, found = 0;
        Set<String> seen = new LinkedHashSet<>();
        if (what.equals("find")) {
            try (BufferedReader in = Files.newBufferedReader(index.resolve("members.txt"))) {
                for (String line; (line = in.readLine()) != null; ) {
                    if (pattern.matcher(line).find()) { found++; if (shown++ < limit) System.out.println(line); }
                }
            }
        } else {
            int col = switch (what) {
                case "callers" -> 2;
                case "calls" -> 0;
                case "strings" -> 2;
                default -> { System.out.println("unknown: " + what); System.exit(2); yield 0; }
            };
            try (BufferedReader in = Files.newBufferedReader(index.resolve("refs.txt"))) {
                for (String line; (line = in.readLine()) != null; ) {
                    String[] f = line.split("\t", 3);
                    if (what.equals("strings") != f[1].equals("str")) continue;
                    if (!pattern.matcher(f[col]).find()) continue;
                    String out = switch (what) {
                        case "callers" -> f[0] + "   " + f[1] + " " + f[2];
                        case "calls" -> f[0] + "   " + f[1] + " " + f[2];
                        default -> f[0] + "   " + f[2];
                    };
                    if (!seen.add(out)) continue;
                    found++;
                    if (shown++ < limit) System.out.println(out);
                }
            }
        }
        if (found > limit) System.out.println("... " + (found - limit) + " more (--limit)");
        if (found == 0) System.out.println("nothing matches");
    }

    // The index of these jars, built when there is none for their versions.
    static Path index(List<Path> jars) throws IOException {
        StringBuilder key = new StringBuilder();
        for (Path jar : jars) {
            key.append(jar.getFileName().toString().replaceAll("\\W", "")).append('-').append(Files.size(jar))
                .append('-').append(Files.getLastModifiedTime(jar).toMillis() / 1000).append('_');
        }
        String local = System.getenv("LOCALAPPDATA");
        Path dir = Path.of(local != null ? local : System.getProperty("java.io.tmpdir"), "pzjar", key.toString());
        if (Files.exists(dir.resolve("refs.txt"))) return dir;
        Files.createDirectories(dir);
        long began = System.nanoTime();
        System.err.println("indexing " + jars + " ...");
        Path members = dir.resolve("members.tmp"), refs = dir.resolve("refs.tmp");
        int classes = 0;
        try (BufferedWriter m = Files.newBufferedWriter(members, StandardCharsets.UTF_8);
             BufferedWriter r = Files.newBufferedWriter(refs, StandardCharsets.UTF_8)) {
            for (Path jar : jars) {
                try (ZipFile zip = new ZipFile(jar.toFile())) {
                    for (Enumeration<? extends ZipEntry> e = zip.entries(); e.hasMoreElements(); ) {
                        ZipEntry entry = e.nextElement();
                        String name = entry.getName();
                        if (!name.endsWith(".class") || name.startsWith("META-INF/")) continue;
                        // a --jar's classes are marked with its name: pzopt's copies of game classes come first on the
                        // game's classpath, so where both are listed, the marked one is what runs
                        String tag = jar == jars.get(0) ? "" : " [" + jar.getFileName() + "]";
                        ClassModel cm;
                        try { cm = ClassFile.of().parse(zip.getInputStream(entry).readAllBytes()); }
                        catch (IllegalArgumentException bad) { continue; }
                        classes++;
                        write(cm, tag, m, r);
                    }
                }
            }
        }
        Files.move(members, dir.resolve("members.txt"), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        Files.move(refs, dir.resolve("refs.txt"), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        System.err.printf("indexed %d classes in %.1f s: %s%n", classes, (System.nanoTime() - began) / 1e9, dir);
        return dir;
    }

    static String dotted(String internal) { return internal.replace('/', '.'); }

    static void write(ClassModel cm, String tag, BufferedWriter m, BufferedWriter r) throws IOException {
        String owner = dotted(cm.thisClass().asInternalName());
        for (FieldModel f : cm.fields()) {
            boolean st = f.flags().has(AccessFlag.STATIC);
            m.write(owner + "." + f.fieldName().stringValue() + " " + f.fieldType().stringValue()
                + (st ? " static" : "") + tag + "\n");
        }
        for (MethodModel method : cm.methods()) {
            String self = owner + "." + method.methodName().stringValue() + " " + method.methodType().stringValue()
                + tag;
            boolean st = method.flags().has(AccessFlag.STATIC);
            m.write(owner + "." + method.methodName().stringValue() + " " + method.methodType().stringValue()
                + (st ? " static" : "") + tag + "\n");
            if (method.code().isEmpty()) continue;
            Set<String> lines = new LinkedHashSet<>();
            for (CodeElement e : method.code().get()) {
                switch (e) {
                    case InvokeInstruction ii -> lines.add("call\t" + dotted(ii.owner().asInternalName()) + "."
                        + ii.name().stringValue() + " " + ii.type().stringValue());
                    case FieldInstruction fi -> lines.add((fi.opcode().name().startsWith("GET") ? "get" : "put") + "\t"
                        + dotted(fi.owner().asInternalName()) + "." + fi.name().stringValue() + " "
                        + fi.type().stringValue());
                    case NewObjectInstruction ni -> lines.add("new\t" + dotted(ni.className().asInternalName()));
                    case InvokeDynamicInstruction di -> {
                        for (var a : di.bootstrapArgs()) {
                            if (a instanceof java.lang.constant.DirectMethodHandleDesc h) {
                                String target = h.owner().descriptorString().replaceAll("^L|;$", "").replace('/', '.');
                                lines.add("call\t" + target + "." + h.methodName() + " " + h.lookupDescriptor());
                            } else if (a instanceof String recipe) {
                                // a string joined with "+": its constant parts, each value it joins in as {}
                                lines.add("str\t\"" + escaped(recipe.replace("\u0001", "{}")) + "\"");
                            }
                        }
                    }
                    case ConstantInstruction ci when ci.constantValue() instanceof String s ->
                        lines.add("str\t\"" + escaped(s) + "\"");
                    default -> { }
                }
            }
            for (String line : lines) r.write(self + "\t" + line + "\n");
        }
    }

    // A string constant on one line: control characters and everything past ASCII as \\uXXXX (a lone surrogate too).
    static String escaped(String s) {
        StringBuilder out = new StringBuilder(s.length());
        for (char c : s.toCharArray()) {
            if (c == '\\') out.append("\\\\");
            else if (c == '\n') out.append("\\n");
            else if (c == '\t') out.append("\\t");
            else if (c < 0x20 || c > 0x7e) out.append(String.format("\\u%04x", (int) c));
            else out.append(c);
        }
        return out.toString();
    }
}
