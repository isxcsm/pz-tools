package pztools.bridge.runtime;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

/**
 * The answer lines of a request (BridgeSession): {@code OK <detail>} or {@code ERROR <code> <message>}, the texts in
 * base64 so that no tab or line break of theirs reaches the wire.
 */
final class Replies {
    private static final int MAXIMUM_MESSAGE = 512;

    private Replies() { }

    static String ok(String detail) { return "OK\t" + encode(detail); }

    static String error(String code, String message) {
        return "ERROR\t" + code.replace('\t', ' ') + "\t"
            + encode(message.length() > MAXIMUM_MESSAGE ? message.substring(0, MAXIMUM_MESSAGE) : message);
    }

    static String encode(String value) { return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)); }
}
