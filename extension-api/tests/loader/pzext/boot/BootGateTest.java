package pzext.boot;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;

/**
 * What the boot layer holds of the install: it starts only with the digest of the API's jar, loads a jar only if its
 * bytes have that digest, and looks at the jar again only when the developer's switch is on. Called by
 * {@code pzext.install.InstallTest} (this is in the boot layer's package to reach what is package-private).
 */
public final class BootGateTest {
    private BootGateTest() { }

    public static void run() throws Exception {
        byte[] filled = new byte[32];
        Arrays.fill(filled, (byte) 0xab);
        String digest = HexFormat.of().formatHex(filled), other = HexFormat.of().formatHex(new byte[] { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
            17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 });
        String home = Base64.getEncoder().encodeToString("C:\\ProgramData\\PZExtAPI\\s-x\\api-0".getBytes(StandardCharsets.UTF_8));
        // The loader's arguments: the version folder and the digest. Without the digest, or with a damaged one, no start.
        String[] parsed = Boot.parse(home + "," + digest);
        assert parsed[0].equals("C:\\ProgramData\\PZExtAPI\\s-x\\api-0") && parsed[1].equals(digest) : String.join("|", parsed);
        for (String bad : new String[] { null, "", home, home + ",", home + ",abc", home + "," + digest.toUpperCase(), home + "," + digest + ",x", "," + digest.substring(1) }) {
            try { Boot.parse(bad); throw new AssertionError("started with <" + bad + ">"); }
            catch (IllegalStateException refused) { assert refused.getMessage().contains("digest") : refused.getMessage(); }
        }
        // A start refused leaves nothing behind: a good one still starts (the arguments are parsed before any state is set).
        assert Boot.apiDigest() == null : "the digest is set by a start only";

        // The jar the host read is the one the install vouched for.
        Host.verify(digest, digest, false);
        try { Host.verify(other, digest, false); throw new AssertionError("loaded a jar that does not match"); }
        catch (IOException mismatch) { assert mismatch.getMessage().contains("does not match the install") : mismatch.getMessage(); }
        // The developer's reload is exempt; a boot layer started by hand (the tests) has nothing to compare.
        Host.verify(other, digest, true);
        Host.verify(other, null, false);

        // The jar is read when no API runs yet and never after it was refused; once an API runs only the developer's reload reads it again.
        assert Host.wanted(false, false, false);
        assert !Host.wanted(false, true, false) && !Host.wanted(false, true, true);
        assert !Host.wanted(true, false, false) : "a release looked at its jar again";
        assert Host.wanted(true, false, true) : "the developer's reload did not look again";
        assert !Host.wanted(true, true, true);
        // The switch is off in this process, as in every game that does not set it.
        assert !"1".equals(System.getenv(Host.DEV_RELOAD)) : "run this test without " + Host.DEV_RELOAD;
        System.out.println("BootGateTest passed");
    }
}
