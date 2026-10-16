package pztools.bridge;

import java.io.File;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.FileTime;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.jar.JarOutputStream;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import pztools.launch.Launcher;
import pztools.launch.StartupLoader;

/**
 * The startup loader against a synthetic game: install, start the game from its folder, a broken install, a damaged
 * entry, another tool's service line, an earlier version's jar patch, uninstall and someone else's loader; and a game
 * the app's helper got into first. The game starts with the class path its launcher file gives, as the real launcher
 * does, so the launcher file's forms are tested too: the plain one (with {@code .}), PZ Optimize's AOT form (without
 * {@code .}, with a jar of stale copies of the loose loader classes first), a file Steam reset, PZ Extension API's
 * entry beside ours, a file the install cannot edit. Arguments: the synthetic game's jar, the built bridge folder, the
 * java to start the game with, and the agent jar that stands in for the helper. Run with -ea.
 */
public final class StartupInstallTest {
    private static final String JSON = Launcher.FILE, ENTRY = StartupInstall.LAUNCH_JAR, API_ENTRY = "pzext/pzext-launch.jar";
    /** The launcher file as the game ships it, with a decoy class path in a section that is not the game's. */
    private static final String PLAIN = "{\n\t\"mainClass\": \"zombie/gameStates/MainScreenState\",\n\t\"classpath\": [\n\t\t\".\",\n\t\t\"projectzomboid.jar\"\n\t],\n"
        + "\t\"vmArgs\": [\n\t\t\"-Xmx1g\"\n\t],\n\t\"windows\": {\n\t\t\"6.1\": {\"classpath\": [\"decoy.jar\"]}\n\t}\n}\n";
    private static final String PLAIN_LISTED = listed(PLAIN, ENTRY);

    public static void main(String[] args) throws Exception {
        Path vanilla = Path.of(args[0]), bridge = Path.of(args[1]);
        // What the synthetic game prints once the startup loader loaded this build's bootstrap, whose API the payload names.
        String api;
        try (var payload = new JarFile(bridge.resolve("pztools-game-bridge.jar").toFile())) {
            api = payload.getManifest().getMainAttributes().getValue("PzTools-Bootstrap-Api");
        }
        String loaded = "STARTUP-FIXTURE\t" + api + "\tfalse\ttrue\ttrue";
        String java = args[2];
        Path attachFirst = Path.of(args[3]);
        Path work = Files.createTempDirectory("pztools-startup-test");
        try {
            Path game = work.resolve("game"), root = work.resolve("root"), jar = game.resolve(StartupInstall.GAME_JAR);
            Path services = game.resolve(StartupInstall.SERVICES), launcher = game.resolve(JSON);
            launcherText();
            Files.createDirectories(game);
            Files.createFile(game.resolve(StartupInstall.LAUNCHER));
            Files.copy(vanilla, jar);
            Files.writeString(launcher, PLAIN);
            String vanillaDigest = StartupInstall.sha256(jar);

            expect(run(root, "status", game), "not-installed");
            String installed = run(root, "install", game, bridge);
            assert installed.startsWith("installed\t") : installed;
            String entry = installed.split("\t")[1];
            // No game class changes: the game's folder gets the loader's own files and a service line, and the launcher
            // file one more class path entry, as text.
            assert StartupInstall.sha256(jar).equals(vanillaDigest) : "the install changed the game's jar";
            assert Files.readAllLines(services).equals(List.of(StartupInstall.PROVIDER)) : Files.readAllLines(services);
            for (String name : new String[] { StartupInstall.SHIM[0], StartupInstall.SHIM[1], StartupInstall.SETTINGS, StartupInstall.LAUNCH_JAR })
                assert Files.isRegularFile(game.resolve(name)) : name;
            // The only loose files are the shim and its settings; the loader itself is in the jar.
            try (var loose = Files.list(game.resolve("pztools/startup"))) {
                assert loose.map(path -> path.getFileName().toString()).sorted().toList().equals(List.of("BootProvider$Jar.class", "BootProvider.class", "install.properties"))
                    : "loose files other than the shim";
            }
            expect(Files.readString(launcher), PLAIN_LISTED);
            // The jar holds the same loader under another package name, with its own services list and settings.
            try (var launch = new JarFile(game.resolve(StartupInstall.LAUNCH_JAR).toFile())) {
                for (String name : StartupInstall.LAUNCH_CLASSES) assert launch.getEntry(name) != null : name;
                assert launch.getEntry(StartupInstall.LAUNCH_SETTINGS) != null;
                expect(new String(launch.getInputStream(launch.getEntry(StartupInstall.SERVICES)).readAllBytes(), StandardCharsets.UTF_8),
                    StartupInstall.LAUNCH_PROVIDER + "\n");
            }
            // The status names the install folder, where the app writes what the resident extensions run, and what the
            // launcher file says of the jar's entry.
            expect(run(root, "status", game), "installed\t" + entry + "\t" + root + "\tlauncher=listed");
            // The same install again leaves the launcher file be.
            expect(run(root, "install", game, bridge), "installed\t" + entry);
            expect(Files.readString(launcher), PLAIN_LISTED);
            // The extensions go with the bridge: the game runs them without the app.
            Path copied = root.resolve(installed.split("\t")[2]);
            try (var files = Files.list(bridge.resolve(StartupInstall.EXTENSIONS))) {
                for (Path file : files.toList())
                    assert StartupInstall.sha256(copied.resolve(StartupInstall.EXTENSIONS).resolve(file.getFileName())).equals(StartupInstall.sha256(file)) : file;
            }

            // The game loads the bootstrap at its log zip and gets the endpoint only after its property list. Both
            // providers (the folder's, with ".", and the jar's) are created in this process, and the process boots once.
            expect(start(java, game), loaded);
            boots(root);
            expect(run(root, "refresh", bridge), "unchanged");
            expect(Files.readString(launcher), PLAIN_LISTED);

            // The app was open as the game started, and its helper loaded the bootstrap before the loader ran: the game
            // still becomes one the loader started, and the endpoint still waits for the property list.
            String option = "BOOTSTRAP1:" + Base64.getEncoder().encodeToString(
                bridge.resolve("pztools-game-bridge.jar").toAbsolutePath().toString().getBytes(StandardCharsets.UTF_8));
            expect(start(java, game, "-javaagent:" + attachFirst + "=" + option,
                    bridge.resolve("pztools-game-bootstrap.jar").toString()), loaded);
            assert log(root).contains("loaded bridge-") : log(root);

            // A broken install folder: the game starts as vanilla, its zip files work, and the loader says why.
            Files.delete(root.resolve("current"));
            expect(start(java, game), "STARTUP-FIXTURE\tnull\tfalse\tfalse\tfalse");
            assert log(root).contains("current file is not readable") : log(root);
            assert run(root, "refresh", bridge).startsWith("refreshed\tbridge-");
            expect(start(java, game), loaded);

            // The loader's files went from the game's folder: reported, and the next install puts them back.
            StartupInstall.deleteTree(game.resolve("pztools"));
            expect(run(root, "status", game), "reverted");
            assert run(root, "install", game, bridge).startsWith("installed\t");
            expect(start(java, game), loaded);

            // The jar damaged: not the one the shim's settings name (the shim would not run it), so reverted; a refresh writes it
            // again. Gone: reverted, and the next install puts it back.
            byte[] launchJar = Files.readAllBytes(game.resolve(StartupInstall.LAUNCH_JAR));
            Files.writeString(game.resolve(StartupInstall.LAUNCH_JAR), "damaged");
            expect(run(root, "status", game), "reverted");
            assert run(root, "refresh", bridge).startsWith("refreshed\t");
            assert Arrays.equals(Files.readAllBytes(game.resolve(StartupInstall.LAUNCH_JAR)), launchJar) : "refresh left the damaged jar";
            Files.delete(game.resolve(StartupInstall.LAUNCH_JAR));
            expect(run(root, "status", game), "reverted");
            assert run(root, "install", game, bridge).startsWith("installed\t");
            assert Arrays.equals(Files.readAllBytes(game.resolve(StartupInstall.LAUNCH_JAR)), launchJar) : "install left the jar out";
            expect(start(java, game), loaded);
            expect(Files.readString(launcher), PLAIN_LISTED);

            // The launcher file as PZ Optimize's AOT step leaves it: no "." and its own jar first, which holds copies of the
            // loose loader classes made when the folder was the way to start it, and no services list. The jar's provider
            // is the only one found, and boots the game.
            Path aot = game.resolve("pzopt/aot/pzopt.jar");
            staleJar(aot, game);
            Files.writeString(launcher, aotForm(PLAIN_LISTED));
            expect(start(java, game), loaded);
            boots(root);
            // A rewrite that came before the install: the entry is added after the game's jar, pzopt's stays first, and
            // the game starts from it.
            Files.writeString(launcher, aotForm(PLAIN));
            assert run(root, "install", game, bridge).startsWith("installed\t");
            expect(Files.readString(launcher), listed(aotForm(PLAIN), ENTRY));
            expect(run(root, "status", game), "installed\t" + entry + "\t" + root + "\tlauncher=listed");
            expect(start(java, game), loaded);
            boots(root);

            // Steam's file check put the plain file back: status says the entry is absent, and a refresh puts it back; or
            // the game starts through the folder and its loader does.
            Files.writeString(launcher, PLAIN);
            expect(run(root, "status", game), "installed\t" + entry + "\t" + root + "\tlauncher=absent");
            assert run(root, "refresh", bridge).startsWith("refreshed\t");
            expect(Files.readString(launcher), PLAIN_LISTED);
            expect(run(root, "refresh", bridge), "unchanged");
            Files.writeString(launcher, PLAIN);
            expect(start(java, game), loaded);
            boots(root);
            expect(Files.readString(launcher), PLAIN_LISTED);
            assert log(root).contains("launcher: the class path entry was missing; added") : log(root);
            // ... and a pzopt rewrite after that keeps the entry.
            Files.writeString(launcher, aotForm(Files.readString(launcher)));
            expect(start(java, game), loaded);
            boots(root);
            assert !log(root).contains("launcher:") : log(root);

            // PZ Extension API's entry beside ours: both stay in the list through the loader's healing, and through an
            // uninstall that takes only ours. Its guard is its own: a process its loader booted already boots ours too.
            String withApi = listed(PLAIN, API_ENTRY);
            Files.writeString(launcher, withApi);
            expect(start(java, game), loaded);
            expect(Files.readString(launcher), listed(withApi, ENTRY));
            expect(launch(java, game, List.of("-D" + "pzext.loader.started=loader.log"), classpath(game)), loaded);
            boots(root);
            assert !StartupLoader.GUARD.equals("pzext.loader.started") : "the guard is the API's";
            assert run(root, "install", game, bridge).startsWith("installed\t");
            expect(Files.readString(launcher), listed(withApi, ENTRY));
            expect(run(root, "uninstall", game), "uninstalled");
            expect(Files.readString(launcher), withApi);
            assert !Files.exists(game.resolve("pztools")) : "uninstall left the loader's files";
            StartupInstall.deleteTree(game.resolve("pzopt"));
            Files.writeString(launcher, PLAIN);
            assert run(root, "install", game, bridge).startsWith("installed\t");
            expect(start(java, game), loaded);

            // Another tool's service line stays through install and uninstall.
            Files.writeString(services, "com.example.OtherProvider\n" + StartupInstall.PROVIDER + "\n");
            expect(run(root, "uninstall", game), "uninstalled");
            assert Files.readAllLines(services).equals(List.of("com.example.OtherProvider")) : Files.readAllLines(services);
            expect(Files.readString(launcher), PLAIN);
            assert run(root, "install", game, bridge).startsWith("installed\t");
            assert Files.readAllLines(services).equals(List.of("com.example.OtherProvider", StartupInstall.PROVIDER)) : Files.readAllLines(services);
            expect(run(root, "uninstall", game), "uninstalled");
            Files.delete(services);

            // Uninstall leaves the game's folder as it was.
            assert run(root, "install", game, bridge).startsWith("installed\t");
            expect(run(root, "uninstall", game), "uninstalled");
            assert !Files.exists(root);
            for (String name : new String[] { "pztools", "META-INF" }) assert !Files.exists(game.resolve(name)) : name;
            assert StartupInstall.sha256(jar).equals(vanillaDigest);
            expect(Files.readString(launcher), PLAIN);
            expect(run(root, "status", game), "not-installed");
            expect(start(java, game), "STARTUP-FIXTURE\tnull\tfalse\tfalse\tfalse");

            // A launcher file the install cannot edit (no class path list), or none: the folder's loader serves, status says
            // what is so, and the file is not touched.
            Files.writeString(launcher, "{ \"mainClass\": \"x\" }\n");
            assert run(root, "install", game, bridge).startsWith("installed\t");
            assert run(root, "status", game).endsWith("\tlauncher=unreadable") : run(root, "status", game);
            expect(Files.readString(launcher), "{ \"mainClass\": \"x\" }\n");
            Files.writeString(launcher, "not json at all");
            expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR)), loaded);
            expect(Files.readString(launcher), "not json at all");
            expect(run(root, "uninstall", game), "uninstalled");
            expect(Files.readString(launcher), "not json at all");
            Files.delete(launcher);
            assert run(root, "install", game, bridge).startsWith("installed\t");
            assert run(root, "status", game).endsWith("\tlauncher=none") : run(root, "status", game);
            expect(start(java, game), loaded);
            assert !Files.exists(launcher) : "the loader made a launcher file";
            expect(run(root, "uninstall", game), "uninstalled");
            assert !Files.exists(launcher);
            Files.writeString(launcher, PLAIN);

            shim(work, game, root, bridge, java, loaded, launcher, services);
            Files.writeString(launcher, PLAIN);

            // An earlier version patched the jar and kept the original: it reads as installed until a refresh, which
            // puts the game's own jar back and makes the entry; an install does the same.
            for (String command : new String[] { "refresh", "install" }) {
                String patched = earlierInstall(root, game, bridge, vanilla);
                expect(run(root, "status", game), "installed\t" + patched + "\t" + root + "\tlauncher=listed");
                String result = command.equals("refresh") ? run(root, "refresh", bridge) : run(root, "install", game, bridge);
                assert result.startsWith(command.equals("refresh") ? "refreshed\t" : "installed\t") : result;
                assert StartupInstall.sha256(jar).equals(vanillaDigest) : command + " left the patched jar";
                assert !Files.exists(root.resolve(StartupInstall.ORIGINAL));
                assert run(root, "status", game).startsWith("installed\t");
                expect(start(java, game), loaded);
                expect(run(root, "uninstall", game), "uninstalled");
            }
            // An earlier patch whose saved copy of the game's jar has gone: a refresh says so, rather than call itself done
            // and leave the patch in place. Steam's file check puts the game's jar back; then it uninstalls as usual.
            earlierInstall(root, game, bridge, vanilla);
            Files.delete(root.resolve(StartupInstall.ORIGINAL));
            try { run(root, "refresh", bridge); throw new AssertionError("refreshed without the game's own jar"); }
            catch (StartupInstall.Refused refused) { assert refused.code.equals("original-missing") : refused.code; }
            assert !Files.exists(game.resolve(StartupInstall.SHIM[0])) : "the entry was written over the patched jar";
            Files.copy(vanilla, jar, StandardCopyOption.REPLACE_EXISTING);
            expect(run(root, "uninstall", game), "uninstalled");
            // An earlier patch a game update has since replaced: uninstall leaves the new jar alone.
            earlierInstall(root, game, bridge, vanilla);
            Files.copy(vanilla, jar, StandardCopyOption.REPLACE_EXISTING);
            expect(run(root, "status", game), "reverted");
            expect(run(root, "uninstall", game), "uninstalled");
            assert StartupInstall.sha256(jar).equals(vanillaDigest);

            // The install folder went, and its entry stayed in the game's folder: the entry is this install's own, which
            // an install takes over and an uninstall removes.
            assert run(root, "install", game, bridge).startsWith("installed\t");
            StartupInstall.deleteTree(root);
            expect(run(root, "status", game), "not-installed");
            assert run(root, "install", game, bridge).startsWith("installed\t");
            StartupInstall.deleteTree(root);
            expect(run(root, "uninstall", game), "not-installed");
            for (String name : new String[] { "pztools", "META-INF" }) assert !Files.exists(game.resolve(name)) : name;

            // A patch in the jar this install has no record of: reported, never overwritten or removed.
            earlierInstall(root, game, bridge, vanilla);
            StartupInstall.deleteTree(root);
            expect(run(root, "status", game), "foreign");
            try { run(root, "install", game, bridge); throw new AssertionError("installed over a foreign loader"); }
            catch (StartupInstall.Refused refused) { assert refused.code.equals("foreign-install") : refused.code; }
            try { run(root, "uninstall", game); throw new AssertionError("removed a foreign loader"); }
            catch (StartupInstall.Refused refused) { assert refused.code.equals("foreign-install") : refused.code; }

            try { run(root, "status", work.resolve("missing")); throw new AssertionError("found a game in an empty folder"); }
            catch (StartupInstall.Refused refused) { assert refused.code.equals("game-not-found") : refused.code; }
            System.out.println("StartupInstallTest passed");
        } finally { StartupInstall.deleteTree(work); }
    }

    /**
     * What an earlier version left: the loader class in the game's jar, the original beside the record, in an install
     * folder made as installs make it.
     */
    private static String earlierInstall(Path root, Path game, Path bridge, Path vanilla) throws Exception {
        Path jar = game.resolve(StartupInstall.GAME_JAR);
        if (!Files.exists(root.resolve(StartupInstall.RECORD))) run(root, "install", game, bridge);
        StartupInstall.deleteTree(game.resolve("pztools"));
        StartupInstall.deleteTree(game.resolve("META-INF"));
        Files.copy(vanilla, root.resolve(StartupInstall.ORIGINAL), StandardCopyOption.REPLACE_EXISTING);
        Files.copy(vanilla, jar, StandardCopyOption.REPLACE_EXISTING);
        try (FileSystem zip = FileSystems.newFileSystem(jar)) {
            Path loader = zip.getPath(StartupInstall.PATCHED_LOADER_ENTRY);
            Files.createDirectories(loader.getParent());
            Files.write(loader, new byte[] { 1 });
        }
        String patched = StartupInstall.sha256(jar);
        Files.writeString(root.resolve(StartupInstall.RECORD), "game_jar\t" + jar + "\noriginal_sha256\t"
            + StartupInstall.sha256(vanilla) + "\npatched_sha256\t" + patched + "\n");
        return patched;
    }

    private static String run(Path root, String command, Path... paths) throws Exception {
        String[] args = new String[paths.length + 1];
        args[0] = command;
        for (int index = 0; index < paths.length; index++) args[index + 1] = paths[index].toString();
        return StartupInstall.run(args, root);
    }

    private static String start(String java, Path game) throws Exception {
        return launch(java, game, List.of(), classpath(game));
    }

    /**
     * As the game's launcher starts it: from its folder, with the class path its launcher file gives. Optionally with an
     * agent loaded before main, and a jar for it on the class path.
     */
    private static String start(String java, Path game, String agent, String classPath) throws Exception {
        var entries = new ArrayList<>(classpath(game));
        if (classPath != null) entries.add(classPath);
        return launch(java, game, List.of(agent), entries);
    }

    /** The class path of the launcher file (the game's own when there is none). */
    private static List<String> classpath(Path game) throws Exception {
        Path launcher = game.resolve(JSON);
        var entries = new ArrayList<String>();
        if (Files.isRegularFile(launcher)) {
            Matcher list = Pattern.compile("\"classpath\"\\s*:\\s*\\[([^\\]]*)\\]").matcher(Files.readString(launcher));
            if (list.find()) {
                Matcher entry = Pattern.compile("\"([^\"]*)\"").matcher(list.group(1));
                while (entry.find()) entries.add(entry.group(1));
                return entries;
            }
        }
        return List.of(".", StartupInstall.GAME_JAR);
    }

    private static String launch(String java, Path game, List<String> options, List<String> classpath) throws Exception {
        var command = new ArrayList<String>(List.of(java, "--enable-native-access=ALL-UNNAMED"));
        command.addAll(options);
        command.addAll(List.of("-cp", String.join(File.pathSeparator, classpath), "zombie.gameStates.MainScreenState"));
        Process process = new ProcessBuilder(command).directory(game.toFile()).redirectError(ProcessBuilder.Redirect.DISCARD).start();
        String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8).strip();
        if (!process.waitFor(60, TimeUnit.SECONDS)) { process.destroyForcibly(); throw new AssertionError("game did not exit"); }
        assert process.exitValue() == 0 : "game exited with " + process.exitValue() + ": " + output;
        return output;
    }

    private static String log(Path root) throws Exception {
        return Files.readString(root.resolve("startup.log"), StandardCharsets.UTF_8);
    }

    private static void expect(String actual, String expected) {
        assert actual.equals(expected) : "expected <" + expected + "> but was <" + actual + ">";
    }

    /**
     * The SHA-256 of the shim's built class files, pinned. They are the only loose class files in the game's folder and
     * must be the same in every release (docs/design/startup-loader.md): changing the shim, or the way it is compiled, is a
     * decision with consequences for every player who runs a tool that copies the folder's loose classes (PZ Optimize), and
     * it takes a new pin here, with the reason in the commit.
     */
    private static final Map<String, String> SHIM_PINS = Map.of(
        "pztools/startup/BootProvider.class", "aa7c10d6c822630d4a3b14f02dfc0b318b465d258b1a6f348b45d29592f66f87",
        "pztools/startup/BootProvider$Jar.class", "975de7d8f1765c1f835d76cde61045e5a8f4db050dce80434c42145e49561e95");

    /**
     * The frozen shim: its bytes are the pinned ones, a newer installer leaves them (and their modification time) alone, the
     * classes of an earlier layout are removed, the shim hands off to the jar (exactly one boot) where the jar is not on the
     * class path and stands aside where it is, and a jar that is missing or damaged leaves a vanilla game. Starts and ends
     * uninstalled.
     */
    private static void shim(Path work, Path game, Path root, Path bridge, String java, String loaded, Path launcher, Path services) throws Exception {
        String vanilla = "STARTUP-FIXTURE\tnull\tfalse\tfalse\tfalse";
        for (String name : StartupInstall.SHIM) {
            String pin = SHIM_PINS.get(name);
            assert pin != null : name;
            expect(StartupInstall.sha256(StartupInstall.ownClass(name)), pin);
        }
        assert SHIM_PINS.size() == StartupInstall.SHIM.length;

        // An install of the layout before the shim: its loose classes (other bytes) and the same service line, beside another
        // tool's. Install replaces the provider, removes the rest, and leaves the service lines be.
        Files.createDirectories(game.resolve("pztools/startup"));
        for (String name : new String[] { "StartupLoader", "Launcher", "BootProvider" })
            Files.write(game.resolve("pztools/startup/" + name + ".class"), new byte[] { 9, 9 });
        Files.writeString(game.resolve(StartupInstall.SETTINGS), "root=x\ngame=y\n");
        Files.createDirectories(services.getParent());
        Files.writeString(services, "com.example.OtherProvider\n" + StartupInstall.PROVIDER + "\n");
        String first = run(root, "install", game, bridge);
        assert first.startsWith("installed\t") : first;
        for (String name : StartupInstall.RETIRED) assert !Files.exists(game.resolve(name)) : name + " of the earlier layout stayed";
        for (String name : StartupInstall.SHIM) assert Arrays.equals(Files.readAllBytes(game.resolve(name)), StartupInstall.ownClass(name)) : name;
        assert Files.readAllLines(services).equals(List.of("com.example.OtherProvider", StartupInstall.PROVIDER)) : Files.readAllLines(services);
        // (The other tool's class does not exist here, which would fail the game's provider list: the game starts without its line.)
        Files.writeString(services, StartupInstall.PROVIDER + "\n");
        expect(launch(java, game, List.of(), classpath(game)), loaded);
        boots(root);

        // A newer installer (another launch jar: a loader class of other bytes) leaves the shim and the services file as they
        // were, same bytes and same modification time. The settings beside the shim follow the jar's digest. Its jar is
        // never run here: its changed class is not one.
        Path[] frozen = { game.resolve(StartupInstall.SHIM[0]), game.resolve(StartupInstall.SHIM[1]), services };
        FileTime old = FileTime.from(Instant.parse("2001-01-01T00:00:00Z"));
        var before = new ArrayList<byte[]>();
        for (Path file : frozen) { Files.setLastModifiedTime(file, old); before.add(Files.readAllBytes(file)); }
        Path jarFile = game.resolve(StartupInstall.LAUNCH_JAR), looseFile = game.resolve(StartupInstall.SETTINGS);
        byte[] jarBefore = Files.readAllBytes(jarFile);
        Path newer = Files.createDirectories(work.resolve("newer-installer")).resolve("pztools-game-bridge.jar");
        Files.copy(bridge.resolve("pztools-game-bridge.jar"), newer);
        try (FileSystem zip = FileSystems.newFileSystem(newer)) {
            Files.write(zip.getPath("pztools/launch/BootProvider.class"), new byte[] { 7, 7, 7 });
        }
        String second;
        try (var loader = new java.net.URLClassLoader(new java.net.URL[] { newer.toUri().toURL() }, ClassLoader.getPlatformClassLoader())) {
            var run = loader.loadClass("pztools.bridge.StartupInstall").getDeclaredMethod("run", String[].class, Path.class);
            run.setAccessible(true);
            second = (String) run.invoke(null, new String[] { "install", game.toString(), bridge.toString() }, root);
        }
        assert second.startsWith("installed\t") : second;
        for (int index = 0; index < frozen.length; index++) {
            assert Arrays.equals(Files.readAllBytes(frozen[index]), before.get(index)) : frozen[index] + " changed";
            assert Files.getLastModifiedTime(frozen[index]).equals(old) : frozen[index] + " was touched";
        }
        byte[] jarAfter = Files.readAllBytes(jarFile);
        assert !Arrays.equals(jarBefore, jarAfter) : "the jar did not follow the newer installer";
        assert Files.readString(looseFile).contains("\nsha256=" + StartupInstall.sha256(jarAfter) + "\n");
        assert run(root, "status", game).startsWith("installed\t");
        // The installer of this build puts its own jar back, and still leaves the shim be; the same install again touches nothing.
        assert run(root, "install", game, bridge).startsWith("installed\t");
        assert Arrays.equals(Files.readAllBytes(jarFile), jarBefore);
        for (Path file : new Path[] { jarFile, looseFile }) Files.setLastModifiedTime(file, old);
        assert run(root, "install", game, bridge).startsWith("installed\t");
        for (Path file : new Path[] { jarFile, looseFile, frozen[0], frozen[1], frozen[2] })
            assert Files.getLastModifiedTime(file).equals(old) : file + " was rewritten by an install of the same build";
        expect(launch(java, game, List.of(), classpath(game)), loaded);
        boots(root);

        // The launcher file is plain again (a Steam verify): the jar is not on the class path, so only the shim can start the
        // loader. It hands off after checking the jar; the process boots once, and the loader lists the jar again.
        Files.writeString(launcher, PLAIN);
        expect(launch(java, game, List.of(), classpath(game)), loaded);
        boots(root);
        expect(Files.readString(launcher), PLAIN_LISTED);
        assert log(root).contains("launcher: the class path entry was missing; added") : log(root);
        // The same where the game's folder and its jar are all there is (no launcher file at all).
        Files.writeString(launcher, PLAIN);
        expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR)), loaded);
        boots(root);
        // The jar on the class path as well as the folder: its own provider starts the loader, the shim stands aside. One boot.
        Files.writeString(launcher, PLAIN_LISTED);
        expect(launch(java, game, List.of(), classpath(game)), loaded);
        boots(root);
        // PZ Optimize's form (no folder, its jar first): the jar is the only provider and boots the game; the shim is not in play.
        Files.writeString(launcher, aotForm(PLAIN_LISTED));
        expect(launch(java, game, List.of(), classpath(game)), loaded);
        boots(root);
        assert !log(root).contains("failed:") : log(root);

        // PZ Extension API's loader has booted this process: its guard is its own, and this one boots as well, once. The other
        // way round, a process this loader booted already boots nothing again, and nothing is thrown.
        Files.writeString(launcher, PLAIN);
        expect(launch(java, game, List.of("-Dpzext.loader.started=loader.log"), List.of(".", StartupInstall.GAME_JAR)), loaded);
        boots(root);
        Files.writeString(launcher, PLAIN);
        expect(launch(java, game, List.of("-D" + StartupLoader.GUARD + "=startup.log"), List.of(".", StartupInstall.GAME_JAR)), vanilla);
        expect(Files.readString(launcher), PLAIN);

        // The jar is missing, damaged or not the installed one: a vanilla game, its zip files working, one line in the log,
        // and the launcher file as it was.
        byte[] jarGood = Files.readAllBytes(jarFile);
        Files.delete(jarFile);
        expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR)), vanilla);
        assert log(root).contains("the launch jar is missing") : log(root);
        // ... also where the class path lists it (the JVM ignores an entry that is not there) ...
        clearLog(root);
        expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR, StartupInstall.LAUNCH_JAR)), vanilla);
        assert log(root).contains("the launch jar is missing") : log(root);
        // ... and where only the jar's entry is left of the class path.
        Files.writeString(launcher, aotForm(PLAIN_LISTED));
        expect(launch(java, game, List.of(), classpath(game)), vanilla);
        Files.writeString(launcher, PLAIN);
        for (byte[] damaged : new byte[][] { Arrays.copyOf(jarGood, jarGood.length / 2), Arrays.copyOf(jarGood, jarGood.length + 1), new byte[0],
                "not a jar".getBytes(StandardCharsets.UTF_8) }) {
            Files.write(jarFile, damaged);
            clearLog(root);
            expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR)), vanilla);
            assert log(root).contains("the launch jar does not match the install") : log(root);
            expect(Files.readString(launcher), PLAIN);
        }
        // The right jar with the shim's settings gone, unreadable or for another jar: nothing runs either.
        Files.write(jarFile, jarGood);
        byte[] looseGood = Files.readAllBytes(looseFile);
        Files.write(looseFile, "root=x\n".getBytes(StandardCharsets.ISO_8859_1));
        expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR)), vanilla);
        Files.delete(looseFile);
        expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR)), vanilla);
        Files.write(looseFile, StartupInstall.looseSettings(root, new byte[0]));
        clearLog(root);
        expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR)), vanilla);
        assert log(root).contains("does not match the install") : log(root);
        expect(Files.readString(launcher), PLAIN);
        // Put right again, it boots.
        Files.write(looseFile, looseGood);
        expect(launch(java, game, List.of(), List.of(".", StartupInstall.GAME_JAR)), loaded);
        boots(root);

        // The shim found in another tool's jar (not in the game's folder) does nothing, whatever it finds around it.
        Path bare = Files.createDirectories(work.resolve("bare-game"));
        Files.copy(game.resolve(StartupInstall.GAME_JAR), bare.resolve(StartupInstall.GAME_JAR));
        Path copy = bare.resolve("other-tool.jar");
        try (OutputStream out = Files.newOutputStream(copy); var jar = new JarOutputStream(out)) {
            for (String name : StartupInstall.SHIM) { jar.putNextEntry(new JarEntry(name)); jar.write(StartupInstall.ownClass(name)); jar.closeEntry(); }
            jar.putNextEntry(new JarEntry(StartupInstall.SERVICES));
            jar.write((StartupInstall.PROVIDER + "\n").getBytes(StandardCharsets.UTF_8));
            jar.closeEntry();
        }
        expect(launch(java, bare, List.of(), List.of(copy.toString(), StartupInstall.GAME_JAR)), vanilla);
        expect(run(root, "uninstall", game), "uninstalled");
    }

    /** Empties the loader's log, so a line found afterwards is from the run after. */
    private static void clearLog(Path root) throws Exception {
        Files.writeString(root.resolve("startup.log"), "");
    }

    /** The process booted once: the log's first line says loaded, and no later copy of the loader tried again. */
    private static void boots(Path root) throws Exception {
        String log = log(root);
        assert log.lines().findFirst().orElse("").contains(" loaded bridge-") : log;
        assert log.lines().filter(line -> line.contains(" loaded ")).count() == 1 : log;
        assert !log.contains("did not load") && !log.contains("failed:") : log;
    }

    /** The class path list with one more entry at its end, laid out as the entry before it (the form PLAIN and aotForm have). */
    private static String listed(String json, String entry) {
        String result = json.replaceFirst("(\\t\\t\"[^\"]*\")\\n(\\t\\],\\n\\t\"vmArgs\")","$1,\n\t\t\"" + entry + "\"\n$2");
        assert !result.equals(json) : json;
        return result;
    }

    /** What PZ Optimize's AOT step does to the class path: its jar first, "." and any earlier jar of its own dropped, the rest kept. */
    private static String aotForm(String plain) {
        return plain.replace("\t\t\".\",\n", "").replace("\t\"classpath\": [\n", "\t\"classpath\": [\n\t\t\"pzopt/aot/pzopt.jar\",\n");
    }

    /**
     * pzopt's jar: copies of the folder's loose classes (and nothing else, no services list), made before the folder was left
     * out: the shim, and the classes of an install before the shim, which nothing refers to any more.
     */
    private static void staleJar(Path target, Path game) throws Exception {
        Files.createDirectories(target.getParent());
        try (OutputStream out = Files.newOutputStream(target); var jar = new JarOutputStream(out)) {
            for (String name : StartupInstall.SHIM) {
                jar.putNextEntry(new JarEntry(name));
                jar.write(Files.readAllBytes(game.resolve(name)));
                jar.closeEntry();
            }
            for (String name : StartupInstall.RETIRED) {
                jar.putNextEntry(new JarEntry(name));
                jar.write(new byte[] { 1, 2, 3 });
                jar.closeEntry();
            }
        }
    }

    /** The text edits of the class path list, by form: layouts kept, other lines kept, the entry in and out. */
    private static void launcherText() {
        String[][] cases = {
            { "{\"classpath\":[\".\",\"a.jar\"]}", "{\"classpath\":[\".\",\"a.jar\",\"x.jar\"]}" },
            { "{ \"classpath\" : [ \".\", \"a.jar\" ], \"b\": 1 }", "{ \"classpath\" : [ \".\", \"a.jar\", \"x.jar\" ], \"b\": 1 }" },
            { "{\r\n  \"classpath\": [\r\n    \"a.jar\"\r\n  ]\r\n}\r\n", "{\r\n  \"classpath\": [\r\n    \"a.jar\",\r\n    \"x.jar\"\r\n  ]\r\n}\r\n" },
            { "{\"classpath\": []}", "{\"classpath\": [\"x.jar\"]}" },
            { "// c\n{\"vmArgs\": [\"classpath\"], \"x\": {\"classpath\": [\"no\"]},\n \"classpath\": [ /* c */ \"a\\\\b.jar\" ] // end\n}",
              "// c\n{\"vmArgs\": [\"classpath\"], \"x\": {\"classpath\": [\"no\"]},\n \"classpath\": [ /* c */ \"a\\\\b.jar\", \"x.jar\" ] // end\n}" },
        };
        for (String[] pair : cases) {
            Launcher list = Launcher.parse(pair[0]);
            assert list != null : pair[0];
            assert !list.contains("x.jar") && list.with("x.jar").equals(pair[1]) : list.with("x.jar") + " for " + pair[0];
            Launcher added = Launcher.parse(pair[1]);
            assert added.contains("x.jar") && added.with("x.jar").equals(pair[1]);
            assert added.without("x.jar").equals(pair[0]) : added.without("x.jar") + " for " + pair[1];
            assert list.without("x.jar").equals(pair[0]);
        }
        // Removing from the front and the middle takes the comma and white space with the entry.
        assert Launcher.parse("{\"classpath\": [\"x.jar\", \"a\", \"b\"]}").without("x.jar").equals("{\"classpath\": [\"a\", \"b\"]}");
        assert Launcher.parse("{\"classpath\": [\"a\", \"x.jar\", \"b\"]}").without("x.jar").equals("{\"classpath\": [\"a\", \"b\"]}");
        assert Launcher.parse("{\"classpath\": [\"x.jar\"]}").without("x.jar").equals("{\"classpath\": []}");
        // No list, or a list of something else: nothing to edit.
        for (String text : new String[] { "{}", "{\"classpath\": \"a\"}", "{\"classpath\": [1]}", "{\"classpath\": [\"a\" \"b\"]}", "{\"classpath\": [\"a\"", "" })
            assert Launcher.parse(text) == null : text;
    }
}
