package pztools.extensions.runtime;

import pztools.extensions.api.VersionSupport;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.regex.Pattern;

/**
 * The deployed extension catalogue ({@code catalog.tsv}), read and checked in one place. The host reads it
 * when it loads and on every request, so a module is always loaded by the row it was validated against.
 * A row that breaks a rule, or names a capability this host does not run, rejects the whole file.
 */
final class Catalogue {
    static final String SAVE = "save.prepare.v1";
    /** Run for as long as they are on. {@code vehicle.drivetrain.v1} is the earlier name of {@code continuous.v1}. */
    static final Set<String> CONTINUOUS = Set.of("continuous.v1", "vehicle.drivetrain.v1");
    private static final int MAXIMUM_BYTES = 65536, MAXIMUM_ROWS = 64;
    private static final Pattern ID = Pattern.compile("[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+");
    private static final Pattern VERSION = Pattern.compile("[0-9]+(?:[.][0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?");
    private static final Pattern NAMESPACE = Pattern.compile("pztools\\.extensions\\.[A-Za-z0-9_.]+");
    private static final Pattern CLASS = Pattern.compile("[A-Za-z0-9_.]+");
    private static final Pattern JAR = Pattern.compile("[a-z0-9-]+\\.jar");

    /** A module's identity, archive, admitted game versions and capability. Title and description are the app's. */
    record Definition(String id, String version, String namespace, String entry, String jar, VersionSupport support, String capability) {
        boolean continuous() { return CONTINUOUS.contains(capability); }
    }
    private Catalogue() { }

    static boolean validId(String id) { return id != null && id.length() <= 80 && ID.matcher(id).matches(); }

    /** Every row by module id. Throws when the file cannot be read or any row is invalid. */
    static Map<String, Definition> read(Path directory) throws IOException {
        byte[] bytes;
        try (var input = Files.newInputStream(directory.resolve("catalog.tsv"), LinkOption.NOFOLLOW_LINKS)) {
            bytes = input.readNBytes(MAXIMUM_BYTES + 1);
        }
        if (bytes.length > MAXIMUM_BYTES) throw new IOException("Oversized extension catalogue");
        var definitions = new HashMap<String, Definition>();
        for (String line : new String(bytes, StandardCharsets.UTF_8).split("\\R")) {
            if (line.isBlank() || line.startsWith("#")) continue;
            String[] p = line.split("\t", -1);
            if ((p.length != 10 && p.length != 11) || definitions.size() >= MAXIMUM_ROWS || !validId(p[0])
                    || !VERSION.matcher(p[1]).matches() || !NAMESPACE.matcher(p[2]).matches()
                    || !p[3].startsWith(p[2] + ".") || !CLASS.matcher(p[3]).matches() || !JAR.matcher(p[4]).matches())
                throw new IOException("Invalid extension catalogue row");
            VersionSupport range;
            try { range = new VersionSupport(p[5], p[6].equals("-") ? null : p[6], p[7].equals("-") ? null : p[7]); }
            catch (IllegalArgumentException invalid) { throw new IOException("Invalid extension version range", invalid); }
            String capability = p.length == 10 ? SAVE : p[10];
            if (!capability.equals(SAVE) && !CONTINUOUS.contains(capability)) throw new IOException("Unknown extension capability");
            if (definitions.putIfAbsent(p[0], new Definition(p[0], p[1], p[2], p[3], p[4], range, capability)) != null)
                throw new IOException("Duplicate module identity");
        }
        return definitions;
    }
}
