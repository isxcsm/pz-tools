import pztools.extensions.api.VersionSupport;
import java.nio.file.*;

/** The same policy vectors are used by .NET. No game or timing assumptions. */
public final class VersionSupportTest {
    public static void main(String[] args) throws Exception {
        int count = 0;
        for (String line : Files.readAllLines(Path.of(args[0]))) {
            String[] p = line.split("\\|", -1);
            boolean result = new VersionSupport(p[0], p[1].equals("-") ? null : p[1], p[2].equals("-") ? null : p[2])
                .matches(p[3].equals("-") ? null : p[3]);
            if (result != Boolean.parseBoolean(p[4])) throw new AssertionError(line);
            count++;
        }
        System.out.println("PASS: " + count + " shared version-range cases");
        String[] vehicle = Files.readAllLines(Path.of(args[1])).stream()
            .filter(line -> line.startsWith("pztools.vehicle-drivetrain\t"))
            .findFirst().orElseThrow().split("\t", -1);
        var support = new VersionSupport(vehicle[5], vehicle[6], vehicle[7]);
        if (!support.equals(new VersionSupport("Major", "42", "42")))
            throw new AssertionError("Vehicle catalogue must declare only major 42");
        for (String version : new String[] { "42.0", "42.19.9", "42.20.4", "42.21-unstable", "42.9999" })
            if (!support.matches(version)) throw new AssertionError("Rejected vehicle version " + version);
        for (String version : new String[] { "41.78", "43.0", null })
            if (support.matches(version)) throw new AssertionError("Admitted vehicle version " + version);
        System.out.println("PASS: shared vehicle catalogue declares and admits only major 42");
    }
}
