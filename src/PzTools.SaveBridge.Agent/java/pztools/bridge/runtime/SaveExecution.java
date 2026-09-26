package pztools.bridge.runtime;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

/** One immutable execution report. No game references or growing history; wire encoding is off-thread. */
final class SaveExecution {
    record Report(String request, String process, String world, String requested, String provider,
                  String outcome, String reason, long captureMillis, long elapsedMillis) {
        String wire() {
            String text = String.join("|", "1", request.replace("-", ""), process, world, requested,
                provider, outcome, reason == null ? "-" : reason, Long.toString(captureMillis), Long.toString(elapsedMillis));
            return Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.UTF_8));
        }
    }
    private static volatile Report latest;
    static Report latest() { return latest; }
    static void publish(Report report) { latest = report; }
    private SaveExecution() { }
}