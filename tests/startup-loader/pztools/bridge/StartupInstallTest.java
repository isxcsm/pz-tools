package pztools.bridge;

import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.concurrent.TimeUnit;

/**
 * The startup loader against a synthetic game: install, start the game from its patched jar, a broken install, a game
 * update, reinstall, uninstall and someone else's patch. Arguments: the synthetic game's jar, the built bridge folder,
 * the java to start the game with. Run with -ea.
 */
public final class StartupInstallTest {
    public static void main(String[] args) throws Exception {
        Path vanilla = Path.of(args[0]), bridge = Path.of(args[1]);
        String java = args[2];
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
            expect(run(root, "status", game), installed.split("\t")[0] + "\t" + StartupInstall.sha256(jar));
            assert run(root, "install", game, bridge).equals("installed\t" + StartupInstall.sha256(jar)) : "a second install changes nothing";
            assert StartupInstall.sha256(root.resolve(StartupInstall.ORIGINAL)).equals(vanillaDigest);

            // The game loads the bootstrap at once and gets the endpoint only after its property list.
            expect(start(java, jar), "STARTUP-FIXTURE\t11\tfalse\ttrue");
            assert log(root).contains("loaded bridge-") : log(root);
            expect(run(root, "refresh", bridge), "unchanged");

            // A broken install: the game starts as vanilla and the loader says why.
            Files.delete(root.resolve("current"));
            expect(start(java, jar), "STARTUP-FIXTURE\tnull\tfalse\tfalse");
            assert log(root).contains("current file is not readable") : log(root);
            assert run(root, "refresh", bridge).startsWith("refreshed\tbridge-");
            expect(start(java, jar), "STARTUP-FIXTURE\t11\tfalse\ttrue");

            // A game update replaces the jar: the game is vanilla again and a new install patches the new jar.
            Files.copy(vanilla, jar, StandardCopyOption.REPLACE_EXISTING);
            expect(run(root, "status", game), "reverted");
            assert run(root, "install", game, bridge).startsWith("installed\t");

            expect(run(root, "uninstall", game), "uninstalled");
            assert StartupInstall.sha256(jar).equals(vanillaDigest) : "uninstall puts the original back";
            assert !Files.exists(root);
            expect(run(root, "status", game), "not-installed");
            expect(start(java, jar), "STARTUP-FIXTURE\tnull\tfalse\tfalse");

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
        Process process = new ProcessBuilder(java, "--enable-native-access=ALL-UNNAMED", "-cp", jar.toString(),
            "zombie.gameStates.MainScreenState").redirectError(ProcessBuilder.Redirect.DISCARD).start();
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
