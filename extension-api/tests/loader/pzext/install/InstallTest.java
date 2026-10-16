package pzext.install;

import java.io.File;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.jar.JarEntry;
import java.util.jar.JarOutputStream;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import pzext.loader.Launcher;
import pzext.loader.Trust;

/**
 * The install and the loader against a synthetic game: install, start the game from its folder (the boot layer loads,
 * the API is in its Lua), a broken install, the loader's files gone, another tool's service line, uninstall. The game
 * starts with the class path its launcher file gives, as the real launcher does, so the launcher file's forms are
 * tested too: the plain one (with {@code .}), pzopt's AOT form (without {@code .}, with a jar of stale copies of the
 * loose loader classes first), a file Steam reset, another tool's entry, a file the install cannot edit. Arguments: the
 * synthetic game's jar, the release folder, the java to start the game with. Run with -ea.
 */
public final class InstallTest {
    private static final String LOADED = "PZEXT-FIXTURE\t1\t1.0", VANILLA = "PZEXT-FIXTURE\tnull\tnull";
    private static final String JSON = Launcher.FILE, ENTRY = Install.LAUNCH_JAR;
    /** The launcher file as the game ships it, with a decoy class path in a section that is not the game's. */
    private static final String PLAIN = "{\n\t\"mainClass\": \"zombie/gameStates/MainScreenState\",\n\t\"classpath\": [\n\t\t\".\",\n\t\t\"projectzomboid.jar\"\n\t],\n"
        + "\t\"vmArgs\": [\n\t\t\"-Xmx1g\"\n\t],\n\t\"windows\": {\n\t\t\"6.1\": {\"classpath\": [\"decoy.jar\"]}\n\t}\n}\n";
    private static final String PLAIN_LISTED = PLAIN.replace("\t\t\"projectzomboid.jar\"\n", "\t\t\"projectzomboid.jar\",\n\t\t\"" + ENTRY + "\"\n");

    public static void main(String[] args) throws Exception {
        Path vanilla = Path.of(args[0]), release = Path.of(args[1]);
        String java = args[2];
        Path work = Files.createTempDirectory("pzext-install-test");
        try {
            launcherText();
            pzext.boot.BootGateTest.run();
            TrustTest.run(work.resolve("trust"));
            // The install folder is under a shared folder the install makes, as ProgramData's PZExtAPI.
            Path game = work.resolve("game"), shared = work.resolve("shared"), root = shared.resolve("s-test"), jar = game.resolve(Install.GAME_JAR);
            Path services = game.resolve(Install.SERVICES), launcher = game.resolve(JSON);
            Files.createDirectories(game);
            Files.createFile(game.resolve(Install.LAUNCHER));
            Files.copy(vanilla, jar);
            Files.writeString(launcher, PLAIN);
            String vanillaDigest = Install.sha256(jar);

            expect(run(root, release, "status", game), "not-installed");
            expect(start(java, game), VANILLA);
            String installed = run(root, release, "install", game);
            assert installed.startsWith("installed\tapi-") : installed;
            assert installed.endsWith("\tlauncher=listed") : installed;
            String version = installed.split("\t")[1];
            // No game file changes: the game's folder gets the loader's own files and a service line, and the launcher
            // file one more class path entry, as text.
            assert Install.sha256(jar).equals(vanillaDigest) : "the install changed the game's jar";
            assert Files.readAllLines(services).equals(List.of(Install.PROVIDER)) : Files.readAllLines(services);
            for (String name : new String[] { Install.LOADER_ENTRY, Install.PROVIDER_ENTRY, Install.LAUNCHER_ENTRY, Install.SETTINGS, Install.LAUNCH_JAR })
                assert Files.isRegularFile(game.resolve(name)) : name;
            expect(Files.readString(launcher), PLAIN_LISTED);
            expect(run(root, release, "status", game), "installed\t" + version + "\t" + root + "\tlauncher=listed");
            // The same release again is the same version folder, and leaves the launcher file be.
            expect(run(root, release, "install", game), installed);
            expect(Files.readString(launcher), PLAIN_LISTED);
            // The fonts go with it: the API finds them in its version folder.
            try (var files = Files.list(release.resolve(Install.FONTS))) {
                for (Path file : files.toList())
                    assert Install.sha256(root.resolve(version).resolve(Install.FONTS).resolve(file.getFileName())).equals(Install.sha256(file)) : file;
            }

            // The game loads the boot layer at its log zip; its Lua gets PZExtAPI. Both providers (the folder's, with ".",
            // and the jar's) are created in this process, and the process boots once.
            expect(start(java, game), LOADED);
            boots(root, version);
            // Which hooks the game has, for whoever installed the API.
            String status = Files.readString(root.resolve("api.tsv"), StandardCharsets.UTF_8);
            assert status.startsWith("PZEXT-API\t1\npid\t") : status;

            // The files the game writes are there and empty-or-written; the version folder's files are what the settings vouch for.
            assert Files.isRegularFile(root.resolve("loader.log")) && Files.isRegularFile(root.resolve("api.tsv"));
            String settings = Files.readString(game.resolve(Install.SETTINGS), StandardCharsets.ISO_8859_1);
            assert settings.contains("\nversion=" + version + "\n") && settings.contains("\nsha256." + Install.BOOT + "=" + Install.sha256(root.resolve(version).resolve(Install.BOOT)) + "\n") : settings;
            assert !Files.exists(root.resolve("current")) : "a current file is no longer part of the install";

            // A file of the install folder changed after the install (the boot jar, the API, the native library, a font): the
            // loader refuses it before loading anything, the game starts as vanilla with its zip files working, and the
            // log says which. The install puts the file back.
            Path fontFile;
            try (var fonts = Files.list(root.resolve(version).resolve(Install.FONTS))) { fontFile = fonts.sorted().findFirst().orElseThrow(); }
            for (Path changed : new Path[] { root.resolve(version).resolve(Install.BOOT), root.resolve(version).resolve("pzext-api.jar"),
                root.resolve(version).resolve("pzext-loader.dll"), fontFile }) {
                byte[] original = Files.readAllBytes(changed);
                Files.write(changed, Arrays.copyOf(original, original.length + 1));
                expect(start(java, game), VANILLA);
                assert log(root).contains(root.resolve(version).relativize(changed).toString().replace('\\', '/') + " does not match the install") : log(root);
                assert !log(root).contains("launcher:") : log(root);
                assert run(root, release, "install", game).startsWith("installed\t");
                assert Arrays.equals(Files.readAllBytes(changed), original) : "the install left " + changed + " changed";
                expect(start(java, game), LOADED);
            }
            // A file gone, and a settings file that vouches for nothing.
            Files.delete(root.resolve(version).resolve("pzext-api.jar"));
            expect(start(java, game), VANILLA);
            assert log(root).contains("missing pzext-api.jar") : log(root);
            assert run(root, release, "install", game).startsWith("installed\t");
            expect(start(java, game), LOADED);
            Path settingsFile = game.resolve(Install.SETTINGS);
            byte[] settingsBytes = Files.readAllBytes(settingsFile);
            Files.writeString(settingsFile, settings.replaceAll("(?m)^sha256\\..*\\R", ""), StandardCharsets.ISO_8859_1);
            expect(start(java, game, ".", Install.GAME_JAR), VANILLA);
            assert log(root).contains("do not vouch for") : log(root);
            Files.write(settingsFile, settingsBytes);
            expect(start(java, game), LOADED);

            // An install folder another account may write is not trusted: not the version folder, not the install folder, not
            // the shared folder above it. Here an entry that lets the Users group write stands for the other account.
            var users = FileSystems.getDefault().getUserPrincipalLookupService().lookupPrincipalByName("BUILTIN\\Users");
            for (Path folder : new Path[] { root.resolve(version), root, shared }) {
                var view = Files.getFileAttributeView(folder, AclFileAttributeView.class);
                var before = view.getAcl();
                var open = new ArrayList<>(before);
                open.add(AclEntry.newBuilder().setType(AclEntryType.ALLOW).setPrincipal(users)
                    .setPermissions(AclEntryPermission.WRITE_DATA, AclEntryPermission.APPEND_DATA).build());
                view.setAcl(open);
                expect(start(java, game), VANILLA);
                assert log(root).contains("the install folder is not trusted: ") && log(root).contains("may be changed by BUILTIN\\Users") : log(root);
                assert !log(root).contains("launcher:") : log(root);
                view.setAcl(before);
                expect(start(java, game), LOADED);
            }
            // The install does not trust it either. A folder one of the trusted accounts made gets the right list again, in place.
            for (Path folder : new Path[] { root, shared }) {
                var view = Files.getFileAttributeView(folder, AclFileAttributeView.class);
                var open = new ArrayList<>(view.getAcl());
                open.add(AclEntry.newBuilder().setType(AclEntryType.ALLOW).setPrincipal(users)
                    .setPermissions(AclEntryPermission.WRITE_DATA).build());
                view.setAcl(open);
                expect(start(java, game), VANILLA);
                String again = run(root, release, "install", game);
                assert again.startsWith("installed	") : again;
                assert Trust.problem(root, Trust.with(EXTRA)) == null && Trust.problem(shared, Trust.with(EXTRA)) == null;
                try (var aside = Files.list(folder.getParent())) {
                    assert aside.noneMatch(path -> path.getFileName().toString().contains(".untrusted-")) : "a folder was set aside for " + folder;
                }
                expect(start(java, game), LOADED);
            }
            // A version folder whose files were changed, with the list of another account's making, is copied again.
            Path versionFolder = root.resolve(version);
            var versionView = Files.getFileAttributeView(versionFolder.resolve(Install.BOOT), AclFileAttributeView.class);
            var openFile = new ArrayList<>(versionView.getAcl());
            openFile.add(AclEntry.newBuilder().setType(AclEntryType.ALLOW).setPrincipal(users).setPermissions(AclEntryPermission.WRITE_DATA).build());
            versionView.setAcl(openFile);
            assert Trust.problem(versionFolder.resolve(Install.BOOT), Trust.with(EXTRA)) != null;
            assert run(root, release, "install", game).startsWith("installed	");
            assert Trust.problem(versionFolder.resolve(Install.BOOT), Trust.with(EXTRA)) == null : "the file kept the list of another account";
            expect(start(java, game), LOADED);
            // What stands in the install folder's place and is not a folder of the install's own (a file) is moved aside, whole.
            expect(run(root, release, "uninstall", game), "uninstalled");
            Files.writeString(root, "not a folder");
            assert run(root, release, "install", game).startsWith("installed	");
            try (var aside = Files.list(shared)) {
                assert aside.anyMatch(path -> path.getFileName().toString().startsWith("s-test.untrusted-")) : "the file was not set aside";
            }
            expect(start(java, game), LOADED);
            // A folder of the same name that is a link is no install folder either; nothing is written through it.
            Path elsewhere = Files.createDirectory(work.resolve("elsewhere"));
            expect(run(root, release, "uninstall", game), "uninstalled");
            if (System.getProperty("os.name").startsWith("Windows")) {
                new ProcessBuilder("cmd", "/c", "mklink", "/J", root.toString(), elsewhere.toString()).redirectErrorStream(true).start().getInputStream().readAllBytes();
                assert Trust.isLink(root) : "no junction made";
                String linked = run(root, release, "install", game);
                assert linked.startsWith("installed\t") && !Trust.isLink(root) : linked;
                assert Files.list(elsewhere).findAny().isEmpty() : "the install wrote through a link";
                expect(start(java, game), LOADED);
            }
            // Without the right to own the files (here: no account trusted but the administrators', and this process is not
            // one of them) the install is refused before it touches anything. An elevated run has the right, and no refusal.
            if (!Trust.administrators().contains(Folders.principals()[1])) {
                expect(run(root, release, "uninstall", game), "uninstalled");
                try { Install.run(new String[] { "install", game.toString() }, root, release, new String[0]); throw new AssertionError("installed without the right to own the files"); }
                catch (Install.Refused refused) { assert refused.code.equals("not-administrator") : refused.code; }
                assert !Files.exists(game.resolve(Install.SERVICES)) && !Files.exists(game.resolve("pzext")) : "a refused install left files";
                assert run(root, release, "install", game).startsWith("installed\t");
            }
            expect(start(java, game), LOADED);

            // The launcher file as pzopt's AOT step leaves it: no "." and its own jar first, which holds copies of the
            // loose loader classes made when the folder was the way to start it, and no services list. The jar's
            // provider is the only one found, and boots the game.
            Path aot = game.resolve("pzopt/aot/pzopt.jar");
            staleJar(aot, game);
            Files.writeString(launcher, aotForm(PLAIN_LISTED));
            expect(start(java, game), LOADED);
            boots(root, version);
            // A rewrite that came before the install: the entry is added after the game's jar and pzopt's stay first.
            Files.writeString(launcher, aotForm(PLAIN));
            installed = run(root, release, "install", game);
            assert installed.endsWith("\tlauncher=listed") : installed;
            expect(Files.readString(launcher), aotForm(PLAIN).replace("\t\t\"projectzomboid.jar\"\n", "\t\t\"projectzomboid.jar\",\n\t\t\"" + ENTRY + "\"\n"));
            expect(start(java, game), LOADED);
            boots(root, version);

            // Steam's verify or update put the plain file back: the folder's loader boots the game and puts the entry
            // back, so the next rewrite of the class path by pzopt keeps it.
            Files.writeString(launcher, PLAIN);
            expect(run(root, release, "status", game), "installed\t" + version + "\t" + root + "\tlauncher=absent");
            expect(start(java, game), LOADED);
            boots(root, version);
            expect(Files.readString(launcher), PLAIN_LISTED);
            assert !log(root).contains("launcher: ") || log(root).contains("launcher: the class path entry was missing; added") : log(root);
            Files.writeString(launcher, aotForm(Files.readString(launcher)));
            expect(start(java, game), LOADED);
            boots(root, version);
            // Another tool's entry after ours stays through the healing, and through uninstall.
            Files.writeString(launcher, PLAIN.replace("\t\t\"projectzomboid.jar\"\n", "\t\t\"projectzomboid.jar\",\n\t\t\"pztools/startup.jar\"\n"));
            expect(start(java, game), LOADED);
            expect(Files.readString(launcher), PLAIN.replace("\t\t\"projectzomboid.jar\"\n", "\t\t\"projectzomboid.jar\",\n\t\t\"pztools/startup.jar\",\n\t\t\"" + ENTRY + "\"\n"));
            expect(run(root, release, "uninstall", game), "uninstalled");
            expect(Files.readString(launcher), PLAIN.replace("\t\t\"projectzomboid.jar\"\n", "\t\t\"projectzomboid.jar\",\n\t\t\"pztools/startup.jar\"\n"));
            assert !Files.exists(game.resolve("pzext")) : "uninstall left the loader's files";
            Install.deleteTree(game.resolve("pzopt"));
            Files.writeString(launcher, PLAIN);
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
            expect(Files.readString(launcher), PLAIN);
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
            expect(Files.readString(launcher), PLAIN);
            expect(run(root, release, "status", game), "not-installed");
            expect(start(java, game), VANILLA);

            // A launcher file the install cannot edit (no class path list) or no launcher file: the folder's loader serves,
            // status says what is so, and the file is not touched.
            Files.writeString(launcher, "{ \"mainClass\": \"x\" }\n");
            installed = run(root, release, "install", game);
            assert installed.endsWith("\tlauncher=unreadable") : installed;
            expect(Files.readString(launcher), "{ \"mainClass\": \"x\" }\n");
            Files.writeString(launcher, "not json at all");
            expect(start(java, game, ".", Install.GAME_JAR), LOADED);
            expect(Files.readString(launcher), "not json at all");
            expect(run(root, release, "uninstall", game), "uninstalled");
            Files.delete(launcher);
            installed = run(root, release, "install", game);
            assert installed.endsWith("\tlauncher=none") : installed;
            expect(start(java, game, ".", Install.GAME_JAR), LOADED);
            assert !Files.exists(launcher) : "the loader made a launcher file";
            expect(run(root, release, "uninstall", game), "uninstalled");
            assert !Files.exists(launcher);
            Files.writeString(launcher, PLAIN);

            // A release that lacks a file is refused before anything changes.
            Path partial = work.resolve("partial");
            Files.createDirectories(partial);
            Files.copy(release.resolve(Install.BOOT), partial.resolve(Install.BOOT));
            try { run(root, partial, "install", game); throw new AssertionError("installed a partial release"); }
            catch (Install.Refused refused) { assert refused.code.equals("release-incomplete") : refused.code; }
            assert !Files.exists(game.resolve(Install.SERVICES));
            expect(Files.readString(launcher), PLAIN);

            try { run(root, release, "status", work.resolve("missing")); throw new AssertionError("found a game in an empty folder"); }
            catch (Install.Refused refused) { assert refused.code.equals("game-not-found") : refused.code; }
            System.out.println("InstallTest passed");
        } finally { Install.deleteTree(work); }
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

    /** What pzopt's AOT step does to the class path: its jar first, "." and any earlier jar of its own dropped, the rest kept. */
    private static String aotForm(String plain) {
        return plain.replace("\t\t\".\",\n", "").replace("\t\"classpath\": [\n", "\t\"classpath\": [\n\t\t\"pzopt/aot/pzopt.jar\",\n");
    }

    /** pzopt's jar: copies of the folder's loose classes (and nothing else, no services list), made before the folder was left out. */
    private static void staleJar(Path target, Path game) throws Exception {
        Files.createDirectories(target.getParent());
        try (OutputStream out = Files.newOutputStream(target); var jar = new JarOutputStream(out)) {
            for (String name : new String[] { Install.LOADER_ENTRY, Install.PROVIDER_ENTRY, Install.LAUNCHER_ENTRY }) {
                jar.putNextEntry(new JarEntry(name));
                jar.write(Files.readAllBytes(game.resolve(name)));
                jar.closeEntry();
            }
        }
    }

    /** The accounts the tests trust besides the administrators: they do not run elevated, so they own what the install makes. */
    static final String[] EXTRA = extra();

    private static String[] extra() {
        try {
            var names = new LinkedHashSet<String>();
            for (var principal : Folders.principals()) names.add(principal.getName());
            return names.toArray(String[]::new);
        } catch (Exception failure) { throw new ExceptionInInitializerError(failure); }
    }

    private static String run(Path root, Path release, String command, Path game) throws Exception {
        return Install.run(new String[] { command, game.toString() }, root, release, EXTRA);
    }

    /** As the game's launcher starts it: from its folder, with the class path its launcher file gives. */
    private static String start(String java, Path game) throws Exception {
        Path launcher = game.resolve(JSON);
        var entries = new ArrayList<String>();
        if (Files.isRegularFile(launcher)) {
            Matcher list = Pattern.compile("\"classpath\"\\s*:\\s*\\[([^\\]]*)\\]").matcher(Files.readString(launcher));
            assert list.find() : "no class path in the launcher file";
            Matcher entry = Pattern.compile("\"([^\"]*)\"").matcher(list.group(1));
            while (entry.find()) entries.add(entry.group(1));
        } else { entries.add("."); entries.add(Install.GAME_JAR); }
        return start(java, game, entries.toArray(String[]::new));
    }

    private static String start(String java, Path game, String... classpath) throws Exception {
        var command = List.of(java, "--enable-native-access=ALL-UNNAMED", "-cp", String.join(File.pathSeparator, classpath),
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

    /** The process booted once: the log's first line says loaded, and no later copy of the loader tried again. */
    private static void boots(Path root, String version) throws Exception {
        String log = log(root);
        assert log.lines().findFirst().orElse("").contains(" loaded " + version) : log;
        assert !log.contains("did not load") && !log.contains("failed:") : log;
    }

    private static void expect(String actual, String expected) {
        assert actual.equals(expected) : "expected <" + expected + "> but was <" + actual + ">";
    }
}
