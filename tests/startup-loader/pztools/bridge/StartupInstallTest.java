package pztools.bridge;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/**
 * The startup loader against a synthetic game: install, start the game from its folder, a broken install, a damaged
 * entry, another tool's service line, an earlier version's jar patch, uninstall and someone else's loader; and a game
 * the app's helper got into first. Arguments: the synthetic game's jar, the built bridge folder, the java to start the
 * game with, and the agent jar that stands in for the helper. Run with -ea.
 */
public final class StartupInstallTest {
    public static void main(String[] args) throws Exception {
        Path vanilla = Path.of(args[0]), bridge = Path.of(args[1]);
        String java = args[2];
        Path attachFirst = Path.of(args[3]);
        Path work = Files.createTempDirectory("pztools-startup-test");
        try {
            Path game = work.resolve("game"), root = work.resolve("root"), jar = game.resolve(StartupInstall.GAME_JAR);
            Path services = game.resolve(StartupInstall.SERVICES);
            Files.createDirectories(game);
            Files.createFile(game.resolve(StartupInstall.LAUNCHER));
            Files.copy(vanilla, jar);
            String vanillaDigest = StartupInstall.sha256(jar);

            expect(run(root, "status", game), "not-installed");
            String installed = run(root, "install", game, bridge);
            assert installed.startsWith("installed\t") : installed;
            String entry = installed.split("\t")[1];
            // No game file changes: the game's folder gets the loader's own files and a service line.
            assert StartupInstall.sha256(jar).equals(vanillaDigest) : "the install changed the game's jar";
            assert Files.readAllLines(services).equals(List.of(StartupInstall.PROVIDER)) : Files.readAllLines(services);
            for (String name : new String[] { StartupInstall.LOADER_ENTRY, StartupInstall.PROVIDER_ENTRY, "pztools/startup/install.properties" })
                assert Files.isRegularFile(game.resolve(name)) : name;
            // The status names the install folder, where the app writes what the resident extensions run.
            expect(run(root, "status", game), "installed\t" + entry + "\t" + root);
            expect(run(root, "install", game, bridge), "installed\t" + entry);
            // The extensions go with the bridge: the game runs them without the app.
            Path copied = root.resolve(installed.split("\t")[2]);
            try (var files = Files.list(bridge.resolve(StartupInstall.EXTENSIONS))) {
                for (Path file : files.toList())
                    assert StartupInstall.sha256(copied.resolve(StartupInstall.EXTENSIONS).resolve(file.getFileName())).equals(StartupInstall.sha256(file)) : file;
            }

            // The game loads the bootstrap at its log zip and gets the endpoint only after its property list.
            expect(start(java, game), "STARTUP-FIXTURE\t11\tfalse\ttrue\ttrue\t1.0");
            assert log(root).contains("loaded bridge-") : log(root);
            expect(run(root, "refresh", bridge), "unchanged");

            // The app was open as the game started, and its helper loaded the bootstrap before the loader ran: the game
            // still becomes one the loader started, and the endpoint still waits for the property list.
            String option = "BOOTSTRAP1:" + Base64.getEncoder().encodeToString(
                bridge.resolve("pztools-game-bridge.jar").toAbsolutePath().toString().getBytes(StandardCharsets.UTF_8));
            expect(start(java, game, "-javaagent:" + attachFirst + "=" + option,
                    bridge.resolve("pztools-game-bootstrap.jar").toString()), "STARTUP-FIXTURE\t11\tfalse\ttrue\ttrue\t1.0");
            assert log(root).contains("loaded bridge-") : log(root);

            // A broken install folder: the game starts as vanilla, its zip files work, and the loader says why.
            Files.delete(root.resolve("current"));
            expect(start(java, game), "STARTUP-FIXTURE\tnull\tfalse\tfalse\tfalse\tnull");
            assert log(root).contains("current file is not readable") : log(root);
            assert run(root, "refresh", bridge).startsWith("refreshed\tbridge-");
            expect(start(java, game), "STARTUP-FIXTURE\t11\tfalse\ttrue\ttrue\t1.0");

            // The loader's files went from the game's folder: reported, and the next install puts them back.
            StartupInstall.deleteTree(game.resolve("pztools"));
            expect(run(root, "status", game), "reverted");
            assert run(root, "install", game, bridge).startsWith("installed\t");
            expect(start(java, game), "STARTUP-FIXTURE\t11\tfalse\ttrue\ttrue\t1.0");

            // Another tool's service line stays through install and uninstall.
            Files.writeString(services, "com.example.OtherProvider\n" + StartupInstall.PROVIDER + "\n");
            expect(run(root, "uninstall", game), "uninstalled");
            assert Files.readAllLines(services).equals(List.of("com.example.OtherProvider")) : Files.readAllLines(services);
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
            expect(run(root, "status", game), "not-installed");
            expect(start(java, game), "STARTUP-FIXTURE\tnull\tfalse\tfalse\tfalse\tnull");

            // An earlier version patched the jar and kept the original: it reads as installed until a refresh, which
            // puts the game's own jar back and makes the entry; an install does the same.
            for (String command : new String[] { "refresh", "install" }) {
                String patched = earlierInstall(root, game, bridge, vanilla);
                expect(run(root, "status", game), "installed\t" + patched + "\t" + root);
                String result = command.equals("refresh") ? run(root, "refresh", bridge) : run(root, "install", game, bridge);
                assert result.startsWith(command.equals("refresh") ? "refreshed\t" : "installed\t") : result;
                assert StartupInstall.sha256(jar).equals(vanillaDigest) : command + " left the patched jar";
                assert !Files.exists(root.resolve(StartupInstall.ORIGINAL));
                assert run(root, "status", game).startsWith("installed\t");
                expect(start(java, game), "STARTUP-FIXTURE\t11\tfalse\ttrue\ttrue\t1.0");
                expect(run(root, "uninstall", game), "uninstalled");
            }
            // An earlier patch whose saved copy of the game's jar has gone: a refresh says so, rather than call itself done
            // and leave the patch in place. Steam's file check puts the game's jar back; then it uninstalls as usual.
            earlierInstall(root, game, bridge, vanilla);
            Files.delete(root.resolve(StartupInstall.ORIGINAL));
            try { run(root, "refresh", bridge); throw new AssertionError("refreshed without the game's own jar"); }
            catch (StartupInstall.Refused refused) { assert refused.code.equals("original-missing") : refused.code; }
            assert !Files.exists(game.resolve(StartupInstall.LOADER_ENTRY)) : "the entry was written over the patched jar";
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
            Path loader = zip.getPath(StartupInstall.LOADER_ENTRY);
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
        return start(java, game, null, null);
    }

    /**
     * As the game's launcher starts it: from its folder, with the folder and then the jar on the class path. Optionally
     * with an agent loaded before main, and a jar for it on the class path.
     */
    private static String start(String java, Path game, String agent, String classPath) throws Exception {
        var command = new ArrayList<String>(List.of(java, "--enable-native-access=ALL-UNNAMED"));
        if (agent != null) command.add(agent);
        command.addAll(List.of("-cp", "." + File.pathSeparator + StartupInstall.GAME_JAR
            + (classPath == null ? "" : File.pathSeparator + classPath), "zombie.gameStates.MainScreenState"));
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
}
