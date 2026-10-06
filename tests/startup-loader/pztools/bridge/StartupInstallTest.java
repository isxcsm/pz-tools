package pztools.bridge;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/**
 * The startup loader against a synthetic game: install, start the game from its patched jar, a broken install, a game
 * update, reinstall, uninstall and someone else's patch; and a game the app's helper got into first. Arguments: the
 * synthetic game's jar, the built bridge folder, the java to start the game with, and the agent jar that stands in for
 * the helper. Run with -ea.
 */
public final class StartupInstallTest {
    public static void main(String[] args) throws Exception {
        Path vanilla = Path.of(args[0]), bridge = Path.of(args[1]);
        String java = args[2];
        Path attachFirst = Path.of(args[3]);
        Path work = Files.createTempDirectory("pztools-startup-test");
        try {
            Path game = work.resolve("game"), root = work.resolve("root"), jar = game.resolve(StartupInstall.GAME_JAR);
            Files.createDirectories(game);
            Files.createFile(game.resolve(StartupInstall.LAUNCHER));
            Files.copy(vanilla, jar);
            String vanillaDigest = StartupInstall.sha256(jar);

            expect(run(root, "status", game), "not-installed");
            String installed = run(root, "install", game, bridge);
            assert installed.startsWith("installed\t") : installed;
            assert StartupInstall.hasLoader(jar);
            // The status names the install folder, where the app writes what the resident extensions run.
            expect(run(root, "status", game), "installed\t" + StartupInstall.sha256(jar) + "\t" + root);
            assert run(root, "install", game, bridge).equals("installed\t" + StartupInstall.sha256(jar)) : "a second install changes nothing";
            assert StartupInstall.sha256(root.resolve(StartupInstall.ORIGINAL)).equals(vanillaDigest);
            // The extensions go with the bridge: the game runs them without the app.
            Path copied = root.resolve(installed.split("\t")[2]);
            try (var files = Files.list(bridge.resolve(StartupInstall.EXTENSIONS))) {
                for (Path file : files.toList())
                    assert StartupInstall.sha256(copied.resolve(StartupInstall.EXTENSIONS).resolve(file.getFileName())).equals(StartupInstall.sha256(file)) : file;
            }

            // The game loads the bootstrap at once and gets the endpoint only after its property list.
            expect(start(java, jar), "STARTUP-FIXTURE\t11\tfalse\ttrue\ttrue\t1.0");
            assert log(root).contains("loaded bridge-") : log(root);
            expect(run(root, "refresh", bridge), "unchanged");

            // The app was open as the game started, and its helper loaded the bootstrap before the loader ran: the game
            // still becomes one the loader started, and the endpoint still waits for the property list.
            String option = "BOOTSTRAP1:" + Base64.getEncoder().encodeToString(
                bridge.resolve("pztools-game-bridge.jar").toAbsolutePath().toString().getBytes(StandardCharsets.UTF_8));
            expect(start(java, jar, "-javaagent:" + attachFirst + "=" + option,
                    bridge.resolve("pztools-game-bootstrap.jar").toString()), "STARTUP-FIXTURE	11	false	true	true	1.0");
            assert log(root).contains("loaded bridge-") : log(root);

            // A broken install: the game starts as vanilla and the loader says why.
            Files.delete(root.resolve("current"));
            expect(start(java, jar), "STARTUP-FIXTURE\tnull\tfalse\tfalse\tfalse\tnull");
            assert log(root).contains("current file is not readable") : log(root);
            assert run(root, "refresh", bridge).startsWith("refreshed\tbridge-");
            expect(start(java, jar), "STARTUP-FIXTURE\t11\tfalse\ttrue\ttrue\t1.0");

            // A game update replaces the jar: the game is vanilla again and a new install patches the new jar.
            Files.copy(vanilla, jar, StandardCopyOption.REPLACE_EXISTING);
            expect(run(root, "status", game), "reverted");
            assert run(root, "install", game, bridge).startsWith("installed\t");

            expect(run(root, "uninstall", game), "uninstalled");
            assert StartupInstall.sha256(jar).equals(vanillaDigest) : "uninstall puts the original back";
            assert !Files.exists(root);
            expect(run(root, "status", game), "not-installed");
            expect(start(java, jar), "STARTUP-FIXTURE\tnull\tfalse\tfalse\tfalse\tnull");

            // After an update, uninstall leaves the game's new jar alone.
            assert run(root, "install", game, bridge).startsWith("installed\t");
            Files.copy(vanilla, jar, StandardCopyOption.REPLACE_EXISTING);
            expect(run(root, "uninstall", game), "uninstalled");
            assert StartupInstall.sha256(jar).equals(vanillaDigest);

            // A patch this install has no record of is someone else's: reported, never overwritten or removed.
            assert run(root, "install", game, bridge).startsWith("installed\t");
            Files.delete(root.resolve(StartupInstall.RECORD));
            expect(run(root, "status", game), "foreign");
            try { run(root, "install", game, bridge); throw new AssertionError("installed over a foreign patch"); }
            catch (StartupInstall.Refused refused) { assert refused.code.equals("foreign-install") : refused.code; }
            try { run(root, "uninstall", game); throw new AssertionError("removed a foreign patch"); }
            catch (StartupInstall.Refused refused) { assert refused.code.equals("foreign-install") : refused.code; }

            try { run(root, "status", work.resolve("missing")); throw new AssertionError("found a game in an empty folder"); }
            catch (StartupInstall.Refused refused) { assert refused.code.equals("game-not-found") : refused.code; }
            System.out.println("StartupInstallTest passed");
        } finally { StartupInstall.deleteTree(work); }
    }

    private static String run(Path root, String command, Path... paths) throws Exception {
        String[] args = new String[paths.length + 1];
        args[0] = command;
        for (int index = 0; index < paths.length; index++) args[index + 1] = paths[index].toString();
        return StartupInstall.run(args, root);
    }

    private static String start(String java, Path jar) throws Exception {
        return start(java, jar, null, null);
    }

    /** With an agent loaded before main, and a jar for it on the class path. */
    private static String start(String java, Path jar, String agent, String classPath) throws Exception {
        var command = new ArrayList<String>(List.of(java, "--enable-native-access=ALL-UNNAMED"));
        if (agent != null) command.add(agent);
        command.addAll(List.of("-cp", jar + (classPath == null ? "" : File.pathSeparator + classPath), "zombie.gameStates.MainScreenState"));
        Process process = new ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.DISCARD).start();
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
