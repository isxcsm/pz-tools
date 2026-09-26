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
    }
}