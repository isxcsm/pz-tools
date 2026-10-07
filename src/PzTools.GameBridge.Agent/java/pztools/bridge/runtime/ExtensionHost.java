package pztools.bridge.runtime;

import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import pztools.bridge.AgentEntry;
import pztools.extensions.api.ContinuousModules;
import pztools.extensions.api.SaveModules;
import pztools.extensions.api.internal.ClassArchive;

/**
 * The extension runtime's host (docs/design/module-reload.md#extension-runtime): loaded from the runtime jar in the
 * extensions folder, replaced when that jar changes, and kept by the bootstrap so that it outlives a payload switch.
 * Extension control and an extension's save reach it through {@link #current()}.
 */
final class ExtensionHost {
    static final String FOLDER = "extensions", RUNTIME = "pztools-extension-runtime.jar";
    private static final String HOST = "pztools.extensions.runtime.ModuleHost";
    private static final String KEPT_HOST = "extension-host", KEPT_DIGEST = "extension-host-sha256";
    // The extension files as the startup loader's install copies them (StartupInstall.copyBridge).
    private static final String COPIED = "[A-Za-z0-9._-]+";
    // In a game the startup loader started: the install's copy of the extensions, which outlives the app's folder.
    private static volatile Path installed;

    private ExtensionHost() { }

    /** The install's bridge folder, in a game the startup loader started. */
    static void install(Path bridge) { installed = bridge.resolve(FOLDER); }

    /** The host, made again when its runtime jar changed; moved with the extensions folder when it did not. */
    static SaveModules current() throws Exception {
        Map<String, Object> kept = AgentEntry.kept();
        synchronized (kept) {
            Path directory = directory();
            var archive = ClassArchive.read(directory.resolve(RUNTIME));
            // The extension API the game loaded at its start, not the one this payload was built with.
            archive.require("PzTools-Extension-Api", Integer.toString(ExtensionControl.residentHostAbi()));
            var host = (SaveModules)kept.get(KEPT_HOST);
            if (host != null && archive.digest().equals(kept.get(KEPT_DIGEST))) {
                host.relocate(directory);
                return host;
            }
            var loader = archive.loader("pztools.extensions.runtime", AgentEntry.class.getClassLoader(), true);
            var next = (SaveModules)loader.loadClass(HOST).getConstructor(Path.class).newInstance(directory);
            try { if (host != null) host.close(); }
            catch (Exception failedRetirement) { next.close(); throw failedRetirement; }
            kept.put(KEPT_HOST, next);
            kept.put(KEPT_DIGEST, archive.digest());
            return next;
        }
    }

    /** The host as extension control speaks to it. */
    static ContinuousModules continuous() throws Exception { return (ContinuousModules)current(); }

    /**
     * The extensions beside the payload loaded now. In a game the startup loader started, the install's copy instead
     * while the payload's folder holds the same files, or once that folder has gone: the app's folder lasts only as
     * long as that version of the app, and an update deletes it.
     */
    static Path directory() throws IOException {
        Path own = AgentEntry.payloadPath().getParent().resolve(FOLDER), copy = installed;
        if (copy == null || copy.equals(own) || !Files.isRegularFile(copy.resolve(RUNTIME), LinkOption.NOFOLLOW_LINKS)) return own;
        return !Files.isDirectory(own) || sameFiles(copy, own) ? copy : own;
    }

    /** The same extension files, byte for byte. */
    static boolean sameFiles(Path first, Path second) throws IOException {
        Map<String, Path> one = files(first), other = files(second);
        if (!one.keySet().equals(other.keySet())) return false;
        for (var file : one.entrySet()) if (Files.mismatch(file.getValue(), other.get(file.getKey())) != -1) return false;
        return true;
    }

    private static Map<String, Path> files(Path folder) throws IOException {
        var files = new TreeMap<String, Path>();
        try (var entries = Files.list(folder)) {
            for (Path file : entries.toList()) {
                String name = file.getFileName().toString();
                if (name.matches(COPIED) && Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) files.put(name, file);
            }
        }
        return files;
    }
}
