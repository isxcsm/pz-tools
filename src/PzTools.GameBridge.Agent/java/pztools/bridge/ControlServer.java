package pztools.bridge;

import java.io.*;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Method;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.*;

/**
 * The control listener on 127.0.0.1 (docs/design/game-bridge.md#attaching): one thread takes one connection at a time,
 * checks it, loads the payload it names and starts the session it asks for on a thread of its own. One session of each
 * kind runs at a time. The kinds are the payload's: any name the helper passes on is handed to the payload's entry.
 */
final class ControlServer {
    // Guarded by the class: the kinds with a session running.
    private static final Set<String> running = new HashSet<>();
    private static volatile long requests;

    private ControlServer() { }

    static void start(ServerSocket server, String secret, Instrumentation instrumentation) {
        Thread control = new Thread(() -> serve(server, secret, instrumentation), "PzTools-bridge-control");
        control.setDaemon(true);
        control.start();
    }

    static synchronized boolean running(String kind) { return running.contains(kind); }

    static synchronized boolean idle() { return running.isEmpty(); }

    static long requests() { return requests; }

    private static void serve(ServerSocket server, String secret, Instrumentation instrumentation) {
        while (!server.isClosed()) {
            try (Socket socket = server.accept()) {
                socket.setSoTimeout(2000);
                var input = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                var output = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8), true);
                String line = readLimited(input);
                String[] parts = line == null ? new String[0] : line.split("\\t", -1);
                // A fifth field names the kind; none is a request. The bootstrap's own kinds cannot be asked for.
                if ((parts.length != 4 && !(parts.length == 5 && parts[4].matches("[A-Z]{1,16}")
                        && !parts[4].equals(Payload.REQUEST) && !parts[4].equals(Payload.STARTUP)))
                        || !MessageDigest.isEqual(secret.getBytes(StandardCharsets.US_ASCII), parts[0].getBytes(StandardCharsets.US_ASCII))) {
                    output.println("REJECTED");
                    continue;
                }
                int port = Integer.parseInt(parts[1]);
                Path requestedPayload = Path.of(new String(Base64.getDecoder().decode(parts[3]), StandardCharsets.UTF_8));
                if (port < 1 || port > 65535 || !parts[2].matches("[0-9a-f]{64}")
                        || !requestedPayload.isAbsolute()) {
                    output.println("RESTART_REQUIRED");
                    continue;
                }
                String kind = parts.length == 5 ? parts[4] : Payload.REQUEST;
                output.println(accept(kind, parts[1] + ":" + parts[2], requestedPayload.normalize(), instrumentation));
            } catch (Throwable failure) {
                // Invalid/abandoned control clients cannot enqueue a save. No retry of an accepted request. Whatever went
                // wrong with one connection, the listener goes on with the next.
                if (server.isClosed()) return;
            }
        }
    }

    /** ACCEPTED once the session runs; otherwise why not, and nothing was started. */
    private static String accept(String kind, String options, Path requestedPayload, Instrumentation instrumentation) {
        Method entry;
        try { entry = Payload.prepare(requestedPayload); }
        catch (Payload.Busy busy) { return "BUSY"; }
        // A jar that is not a payload, or one that does not link (a LinkageError as much as a missing class).
        catch (Throwable incompatible) { return "PAYLOAD_UNAVAILABLE"; }
        // A payload loaded for this session brings its own startup work, which the session may take over.
        Payload.startup(instrumentation);
        synchronized (ControlServer.class) { if (!running.add(kind)) return "BUSY"; }
        try {
            Runnable session = Payload.session(entry, kind, options, instrumentation);
            if (session == null) { finished(kind); return "REJECTED"; }
            Thread worker = new Thread(() -> run(kind, session), "PzTools-" + kind.toLowerCase(Locale.ROOT));
            worker.setDaemon(true);
            worker.start();
            return "ACCEPTED";
        } catch (Throwable failure) {
            finished(kind);
            return "PAYLOAD_UNAVAILABLE";
        }
    }

    private static void run(String kind, Runnable session) {
        try {
            if (kind.equals(Payload.REQUEST)) requests++;
            session.run();
        } catch (Throwable failure) {
            System.err.println("[PzTools bridge session] " + failure);
        } finally { finished(kind); }
    }

    private static synchronized void finished(String kind) { running.remove(kind); }

    private static String readLimited(Reader input) throws IOException {
        var line = new StringBuilder();
        for (int value; (value = input.read()) != -1;) {
            if (value == '\n') return line.toString();
            if (value != '\r') line.append((char)value);
            if (line.length() > 32768) throw new IOException("Oversized control request");
        }
        return null;
    }
}
