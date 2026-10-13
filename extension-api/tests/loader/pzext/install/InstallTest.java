package pzext.install;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/**
 * The install and the loader against a synthetic game: install, start the game from its folder (the boot layer loads,
 * the API is in its Lua), a broken install, the loader's files gone, another tool's service line, uninstall. Arguments:
 * the synthetic game's jar, the release folder, the java to start the game with. Run with -ea.
 */
public final class InstallTest {
    private static final String LOADED = "PZEXT-FIXTURE\t1\t1.0", VANILLA = "PZEXT-FIXTURE\tnull\tnull";

    public static void main(String[] args) throws Exception {
        Path vanilla = Path.of(args[0]), release = Path.of(args[1]);
        String java = args[2];
        Path work = Files.createTempDirectory("pzext-install-test");
        try {
            Path game = work.resolve("game"), root = work.resolve("root"), jar = game.resolve(Install.GAME_JAR);
            Path services = game.resolve(Install.SERVICES);
            Files.createDirectories(game);
            Files.createFile(game.resolve(Install.LAUNCHER));
            Files.copy(vanilla, jar);
            String vanillaDigest = Install.sha256(jar);

            expect(run(root, release, "status", game), "not-installed");
            expect(start(java, game), VANILLA);
            String installed = run(root, release, "install", game);
            assert installed.startsWith("installed\tapi-") : installed;
            String version = installed.split("\t")[1];
            // No game file changes: the game's folder gets the loader's own files and a service line.
            assert Install.sha256(jar).equals(vanillaDigest) : "the install changed the game's jar";
            assert Files.readAllLines(services).equals(List.of(Install.PROVIDER)) : Files.readAllLines(services);
            for (String name : new String[] { Install.LOADER_ENTRY, Install.PROVIDER_ENTRY, Install.SETTINGS })
                assert Files.isRegularFile(game.resolve(name)) : name;
            expect(run(root, release, "status", game), "installed\t" + version + "\t" + root);
            // The same release again is the same version folder.
            expect(run(root, release, "install", game), installed);
            // The fonts go with it: the API finds them in its version folder.
            try (var files = Files.list(release.resolve(Install.FONTS))) {
                for (Path file : files.toList())
                    assert Install.sha256(root.resolve(version).resolve(Install.FONTS).resolve(file.getFileName())).equals(Install.sha256(file)) : file;
            }

            // The game loads the boot layer at its log zip; its Lua gets PZExtAPI.
            expect(start(java, game), LOADED);
            assert log(root).contains("loaded " + version) : log(root);
            // Which hooks the game has, for whoever installed the API.
            String status = Files.readString(root.resolve("api.tsv"), StandardCharsets.UTF_8);
            assert status.startsWith("PZEXT-API\t1\npid\t") : status;

            // A broken install folder: the game starts as vanilla, its zip files work, and the loader says why.
            Files.delete(root.resolve(Install.CURRENT));
            expect(start(java, game), VANILLA);
            assert log(root).contains("current file is not readable") : log(root);
            assert run(root, release, "install", game).startsWith("installed\t");
            expect(start(java, game), LOADED);

            // The loader's files went from the game's folder: reported, and the next install puts them back.
            Install.deleteTree(game.resolve("pzext"));
            expect(run(root, release, "status", game), "reverted");
            assert run(root, release, "install", game).startsWith("installed\t");
            expect(start(java, game), LOADED);

            // Another tool's service line stays through install and uninstall.
            Files.writeString(services, "com.example.OtherProvider\n" + Install.PROVIDER + "\n");
            expect(run(root, release, "uninstall", game), "uninstalled");
            assert Files.readAllLines(services).equals(List.of("com.example.OtherProvider")) : Files.readAllLines(services);
            assert run(root, release, "install", game).startsWith("installed\t");
            assert Files.readAllLines(services).equals(List.of("com.example.OtherProvider", Install.PROVIDER)) : Files.readAllLines(services);
            expect(run(root, release, "uninstall", game), "uninstalled");
            Files.delete(services);

            // Uninstall leaves the game's folder as it was.
            assert run(root, release, "install", game).startsWith("installed\t");
            expect(run(root, release, "uninstall", game), "uninstalled");
            assert !Files.exists(root);
            for (String name : new String[] { "pzext", "META-INF" }) assert !Files.exists(game.resolve(name)) : name;
            assert Install.sha256(jar).equals(vanillaDigest);
            expect(run(root, release, "status", game), "not-installed");
            expect(start(java, game), VANILLA);

            // A release that lacks a file is refused before anything changes.
            Path partial = work.resolve("partial");
            Files.createDirectories(partial);
            Files.copy(release.resolve(Install.BOOT), partial.resolve(Install.BOOT));
            try { run(root, partial, "install", game); throw new AssertionError("installed a partial release"); }
            catch (Install.Refused refused) { assert refused.code.equals("release-incomplete") : refused.code; }
            assert !Files.exists(game.resolve(Install.SERVICES));

            try { run(root, release, "status", work.resolve("missing")); throw new AssertionError("found a game in an empty folder"); }
            catch (Install.Refused refused) { assert refused.code.equals("game-not-found") : refused.code; }
            System.out.println("InstallTest passed");
        } finally { Install.deleteTree(work); }
    }

    private static String run(Path root, Path release, String command, Path game) throws Exception {
        return Install.run(new String[] { command, game.toString() }, root, release);
    }

    /** As the game's launcher starts it: from its folder, with the folder and then the jar on the class path. */
    private static String start(String java, Path game) throws Exception {
        var command = List.of(java, "--enable-native-access=ALL-UNNAMED", "-cp", "." + File.pathSeparator + Install.GAME_JAR,
            "zombie.gameStates.MainScreenState");
        Process process = new ProcessBuilder(command).directory(game.toFile()).redirectError(ProcessBuilder.Redirect.DISCARD).start();
        String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8).strip();
        if (!process.waitFor(60, TimeUnit.SECONDS)) { process.destroyForcibly(); throw new AssertionError("game did not exit"); }
        assert process.exitValue() == 0 : "game exited with " + process.exitValue() + ": " + output;
        // The fixture's line is the last: the API may print its own lines before.
        String[] lines = output.split("\\R");
        return lines[lines.length - 1];
    }

    private static String log(Path root) throws Exception {
        return Files.readString(root.resolve("loader.log"), StandardCharsets.UTF_8);
    }

    private static void expect(String actual, String expected) {
        assert actual.equals(expected) : "expected <" + expected + "> but was <" + actual + ">";
    }
}
