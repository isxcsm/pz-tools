package pzext.install;

import java.io.File;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.util.*;
import java.time.Instant;
import java.util.concurrent.TimeUnit;
import java.util.jar.JarEntry;
import java.util.jar.JarOutputStream;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import pzext.launch.Launcher;
import pzext.launch.Trust;

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
            for (String name : new String[] { Install.SHIM[0], Install.SHIM[1], Install.SETTINGS, Install.LAUNCH_JAR })
                assert Files.isRegularFile(game.resolve(name)) : name;
            // The only loose files are the shim and its settings; the loader itself is in the jar.
            try (var loose = Files.list(game.resolve("pzext/loader"))) {
                assert loose.map(path -> path.getFileName().toString()).sorted().toList().equals(List.of("BootProvider$Jar.class", "BootProvider.class", "install.properties"))
                    : "loose files other than the shim";
            }
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
            String settings = new String(jarEntry(game.resolve(Install.LAUNCH_JAR), Install.LAUNCH_SETTINGS), StandardCharsets.ISO_8859_1);
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
            // A jar whose settings vouch for nothing, as the installer would have written it (the shim's digest is the
            // jar's): the loader refuses it.
            Path jarFile = game.resolve(Install.LAUNCH_JAR), settingsFile = game.resolve(Install.SETTINGS);
            byte[] jarBytes = Files.readAllBytes(jarFile), settingsBytes = Files.readAllBytes(settingsFile);
            byte[] bare = Install.launchJar(settings.replaceAll("(?m)^sha256\\..*\\R", "").getBytes(StandardCharsets.ISO_8859_1));
            Files.write(jarFile, bare);
            Files.write(settingsFile, Install.looseSettings(root, bare));
            expect(start(java, game, ".", Install.GAME_JAR), VANILLA);
            assert log(root).contains("do not vouch for") : log(root);
            Files.write(jarFile, jarBytes);
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

            shim(work, game, root, release, java, launcher, services);
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

    /**
     * pzopt's jar: copies of the folder's loose classes (and nothing else, no services list), made before the folder was
     * left out: the shim, and the classes of an install before the shim, which nothing refers to any more.
     */
    private static void staleJar(Path target, Path game) throws Exception {
        Files.createDirectories(target.getParent());
        try (OutputStream out = Files.newOutputStream(target); var jar = new JarOutputStream(out)) {
            for (String name : Install.SHIM) {
                jar.putNextEntry(new JarEntry(name));
                jar.write(Files.readAllBytes(game.resolve(name)));
                jar.closeEntry();
            }
            for (String name : Install.RETIRED) {
                jar.putNextEntry(new JarEntry(name));
                jar.write(new byte[] { 1, 2, 3 });
                jar.closeEntry();
            }
        }
    }

    private static byte[] jarEntry(Path jar, String name) throws Exception {
        try (var zip = new java.util.zip.ZipFile(jar.toFile())) { return zip.getInputStream(zip.getEntry(name)).readAllBytes(); }
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
        return launch(java, game, List.of(), List.of(classpath));
    }

    /** The game started in {@code game} with these JVM options and class path. */
    private static String launch(String java, Path game, List<String> options, List<String> classpath) throws Exception {
        var command = new ArrayList<String>(List.of(java, "--enable-native-access=ALL-UNNAMED"));
        command.addAll(options);
        command.addAll(List.of("-cp", String.join(File.pathSeparator, classpath), "zombie.gameStates.MainScreenState"));
        Process process = new ProcessBuilder(command).directory(game.toFile()).redirectError(ProcessBuilder.Redirect.DISCARD).start();
        String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8).strip();
        if (!process.waitFor(60, TimeUnit.SECONDS)) { process.destroyForcibly(); throw new AssertionError("game did not exit"); }
        assert process.exitValue() == 0 : "game exited with " + process.exitValue() + ": " + output;
        // The fixture's line is the last: the API may print its own lines before.
        String[] lines = output.split("\\R");
        return lines[lines.length - 1];
    }

    /** Empties the loader's log, so a line found afterwards is from the run after. */
    private static void clearLog(Path root) throws Exception {
        Files.writeString(root.resolve("loader.log"), "");
    }

    private static String log(Path root) throws Exception {
        return Files.readString(root.resolve("loader.log"), StandardCharsets.UTF_8);
    }

    /** The process booted once: the log's first line says loaded, and no later copy of the loader tried again. */
    private static void boots(Path root, String version) throws Exception {
        String log = log(root);
        assert log.lines().findFirst().orElse("").contains(" loaded " + version) : log;
        assert log.lines().filter(line -> line.contains(" loaded ")).count() == 1 : log;
        assert !log.contains("did not load") && !log.contains("failed:") : log;
    }

    /**
     * The SHA-256 of the shim's built class files, pinned. They are the only loose class files in the game's folder and
     * must be the same in every release (docs/loader.md): changing the shim, or the way it is compiled, is a decision with
     * consequences for every player who runs a tool that copies the folder's loose classes (PZ Optimize), and it takes a new
     * pin here, with the reason in the commit.
     */
    private static final Map<String, String> SHIM_PINS = Map.of(
        "pzext/loader/BootProvider.class", "58ea7fd5cbd02057a846e25238e0dab7b0488010c860a70b58d6a2d55df56950",
        "pzext/loader/BootProvider$Jar.class", "497ac46693bcbbc9afe52d16344b9442318d8af7b45e31eda6cc1f6a53a09d11");

    /**
     * The frozen shim: its bytes are the pinned ones, a newer release leaves them (and their modification time) alone, the
     * classes of an earlier layout are removed, the shim hands off to the jar (exactly one boot) where the jar is not on the
     * class path and stands aside where it is, and a jar that is missing or damaged leaves a vanilla game. Starts and ends
     * uninstalled.
     */
    private static void shim(Path work, Path game, Path root, Path release, String java, Path launcher, Path services) throws Exception {
        for (String name : Install.SHIM) {
            String pin = SHIM_PINS.get(name);
            assert pin != null : name;
            expect(Install.sha256(Install.ownResource(name)), pin);
        }
        assert SHIM_PINS.size() == Install.SHIM.length;

        // An install of the layout before the shim: its loose classes (more of them, other bytes) and the same service line,
        // beside another tool's. Install replaces the provider, removes the rest, and leaves the service lines be.
        Files.createDirectories(game.resolve("pzext/loader"));
        for (String name : new String[] { "Loader", "Launcher", "Trust", "BootProvider" })
            Files.write(game.resolve("pzext/loader/" + name + ".class"), new byte[] { 9, 9 });
        Files.writeString(game.resolve(Install.SETTINGS), "root=x\nversion=api-0000000000000000\n");
        Files.createDirectories(game.resolve(Install.SERVICES).getParent());
        Files.writeString(services, "com.example.OtherProvider\n" + Install.PROVIDER + "\n");
        String first = run(root, release, "install", game);
        assert first.startsWith("installed\tapi-") : first;
        String version = first.split("\t")[1];
        for (String name : Install.RETIRED) assert !Files.exists(game.resolve(name)) : name + " of the earlier layout stayed";
        for (String name : Install.SHIM) assert Arrays.equals(Files.readAllBytes(game.resolve(name)), Install.ownResource(name)) : name;
        assert Files.readAllLines(services).equals(List.of("com.example.OtherProvider", Install.PROVIDER)) : Files.readAllLines(services);
        // (The other tool's class does not exist here, which would fail the game's provider list: the game starts without its line.)
        Files.writeString(services, Install.PROVIDER + "\n");
        expect(start(java, game), LOADED);
        boots(root, version);

        // A newer release (another version folder, another jar) leaves the shim and the services file as they were: same
        // bytes, same modification time. The settings beside the shim follow the jar's digest.
        Path[] frozen = { game.resolve(Install.SHIM[0]), game.resolve(Install.SHIM[1]), services };
        FileTime old = FileTime.from(Instant.parse("2001-01-01T00:00:00Z"));
        var before = new ArrayList<byte[]>();
        for (Path file : frozen) { Files.setLastModifiedTime(file, old); before.add(Files.readAllBytes(file)); }
        Path jarFile = game.resolve(Install.LAUNCH_JAR), looseFile = game.resolve(Install.SETTINGS);
        byte[] jarBefore = Files.readAllBytes(jarFile);
        Path newer = work.resolve("newer-release");
        try (var files = Files.walk(release)) {
            for (Path file : files.toList()) {
                Path target = newer.resolve(release.relativize(file).toString());
                if (Files.isDirectory(file)) Files.createDirectories(target); else Files.copy(file, target);
            }
        }
        try (var fonts = Files.list(release.resolve(Install.FONTS))) {
            Files.copy(fonts.sorted().findFirst().orElseThrow(), newer.resolve(Install.FONTS).resolve("extra-test.ttf"));
        }
        String second = run(root, newer, "install", game);
        String newVersion = second.split("\t")[1];
        assert !newVersion.equals(version) : "the newer release is the same version";
        for (int index = 0; index < frozen.length; index++) {
            assert Arrays.equals(Files.readAllBytes(frozen[index]), before.get(index)) : frozen[index] + " changed";
            assert Files.getLastModifiedTime(frozen[index]).equals(old) : frozen[index] + " was touched";
        }
        byte[] jarAfter = Files.readAllBytes(jarFile);
        assert !Arrays.equals(jarBefore, jarAfter) : "the jar did not follow the new version";
        assert new String(jarEntry(jarFile, Install.LAUNCH_SETTINGS), StandardCharsets.ISO_8859_1).contains("\nversion=" + newVersion + "\n");
        assert Files.readString(looseFile).contains("\nsha256=" + Install.sha256(jarAfter) + "\n");
        expect(run(root, newer, "status", game), "installed\t" + newVersion + "\t" + root + "\tlauncher=listed");
        expect(start(java, game), LOADED);
        boots(root, newVersion);
        // The same release again touches nothing it wrote before.
        for (Path file : new Path[] { jarFile, looseFile }) Files.setLastModifiedTime(file, old);
        expect(run(root, newer, "install", game), second);
        for (Path file : new Path[] { jarFile, looseFile, frozen[0], frozen[1], frozen[2] })
            assert Files.getLastModifiedTime(file).equals(old) : file + " was rewritten by an install of the same release";

        // The launcher file is plain again (a Steam verify): the jar is not on the class path, so only the shim can start the
        // loader. It hands off after checking the jar; the process boots once, and the loader lists the jar again.
        Files.writeString(launcher, PLAIN);
        expect(start(java, game), LOADED);
        boots(root, newVersion);
        expect(Files.readString(launcher), PLAIN_LISTED);
        assert log(root).contains("launcher: the class path entry was missing; added") : log(root);
        // The same where the game's folder and its jar are all there is (no launcher file at all).
        Files.writeString(launcher, PLAIN);
        expect(start(java, game, ".", Install.GAME_JAR), LOADED);
        boots(root, newVersion);
        // The jar on the class path as well as the folder: its own provider starts the loader, the shim stands aside. One boot.
        Files.writeString(launcher, PLAIN_LISTED);
        expect(start(java, game), LOADED);
        boots(root, newVersion);
        // PZ Optimize's form (no folder, its jar first): the jar is the only provider and boots the game; the shim is not in play.
        Files.writeString(launcher, aotForm(PLAIN_LISTED));
        expect(start(java, game), LOADED);
        boots(root, newVersion);
        assert !log(root).contains("failed:") : log(root);

        // Another tool's loader has booted this process: it has a guard of its own, and this one boots as well, once. The
        // other way round, a process this loader booted already boots nothing again, and nothing is thrown.
        Files.writeString(launcher, PLAIN);
        expect(launch(java, game, List.of("-Dpztools.startup.loader.started=startup.log"), List.of(".", Install.GAME_JAR)), LOADED);
        boots(root, newVersion);
        Files.writeString(launcher, PLAIN);
        expect(launch(java, game, List.of("-D" + pzext.launch.Loader.GUARD + "=loader.log"), List.of(".", Install.GAME_JAR)), VANILLA);
        expect(Files.readString(launcher), PLAIN);

        // The jar is missing, damaged or not the installed one: a vanilla game, its zip files working, one line in the log,
        // and the launcher file as it was.
        byte[] jarGood = Files.readAllBytes(jarFile);
        Files.delete(jarFile);
        expect(start(java, game, ".", Install.GAME_JAR), VANILLA);
        assert log(root).contains("the launch jar is missing") : log(root);
        // ... also where the class path lists it (the JVM ignores an entry that is not there) ...
        clearLog(root);
        expect(launch(java, game, List.of(), List.of(".", Install.GAME_JAR, Install.LAUNCH_JAR)), VANILLA);
        assert log(root).contains("the launch jar is missing") : log(root);
        // ... and where only the jar's entry is left of the class path.
        Files.writeString(launcher, aotForm(PLAIN_LISTED));
        expect(start(java, game), VANILLA);
        Files.writeString(launcher, PLAIN);
        for (byte[] damaged : new byte[][] { Arrays.copyOf(jarGood, jarGood.length / 2), Arrays.copyOf(jarGood, jarGood.length + 1), new byte[0],
                "not a jar".getBytes(StandardCharsets.UTF_8) }) {
            Files.write(jarFile, damaged);
            clearLog(root);
            expect(start(java, game, ".", Install.GAME_JAR), VANILLA);
            assert log(root).contains("the launch jar does not match the install") : log(root);
            expect(Files.readString(launcher), PLAIN);
        }
        // The right jar with the shim's settings gone, unreadable or for another jar: nothing runs either.
        Files.write(jarFile, jarGood);
        byte[] looseGood = Files.readAllBytes(looseFile);
        Files.write(looseFile, "root=x\n".getBytes(StandardCharsets.ISO_8859_1));
        expect(start(java, game, ".", Install.GAME_JAR), VANILLA);
        Files.delete(looseFile);
        expect(start(java, game, ".", Install.GAME_JAR), VANILLA);
        Files.write(looseFile, Install.looseSettings(root, new byte[0]));
        clearLog(root);
        expect(start(java, game, ".", Install.GAME_JAR), VANILLA);
        assert log(root).contains("does not match the install") : log(root);
        expect(Files.readString(launcher), PLAIN);
        // Put right again, it boots.
        Files.write(looseFile, looseGood);
        expect(start(java, game, ".", Install.GAME_JAR), LOADED);
        boots(root, newVersion);

        // The shim found in another tool's jar (not in the game's folder) does nothing, whatever it finds around it.
        Path bare = Files.createDirectories(work.resolve("bare-game"));
        Files.copy(game.resolve(Install.GAME_JAR), bare.resolve(Install.GAME_JAR));
        Path copy = bare.resolve("other-tool.jar");
        try (OutputStream out = Files.newOutputStream(copy); var jar = new JarOutputStream(out)) {
            for (String name : Install.SHIM) { jar.putNextEntry(new JarEntry(name)); jar.write(Install.ownResource(name)); jar.closeEntry(); }
            jar.putNextEntry(new JarEntry(Install.SERVICES));
            jar.write((Install.PROVIDER + "\n").getBytes(StandardCharsets.UTF_8));
            jar.closeEntry();
        }
        expect(launch(java, bare, List.of(), List.of(copy.toString(), Install.GAME_JAR)), VANILLA);
        expect(run(root, newer, "uninstall", game), "uninstalled");
    }

    private static void expect(String actual, String expected) {
        assert actual.equals(expected) : "expected <" + expected + "> but was <" + actual + ">";
    }
}
