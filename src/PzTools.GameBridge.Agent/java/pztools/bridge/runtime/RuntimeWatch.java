package pztools.bridge.runtime;

import java.net.*;
import java.nio.*;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.locks.LockSupport;
import java.lang.instrument.Instrumentation;

/**
 * One bounded observation stream independent of the save session. Never runs on the game thread. The app may say one
 * thing on it, once: which run of the app it is ({@code LEASE <run>}). While the stream is open it renews that run's
 * lease (see {@link Leases}), so what the run asked of the game lasts while it is connected and a while after.
 */
public final class RuntimeWatch {
    public static void run(String options, Instrumentation ignored) {
        String[] parts = options.split(":", -1);
        boolean owned = false;
        try (SocketChannel channel = SocketChannel.open()) {
            channel.socket().connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), Integer.parseInt(parts[0])), 5000);
            channel.configureBlocking(false);
            send(channel, "RUNTIME\t1\t" + ProcessHandle.current().pid() + "\t" + parts[1]);
            owned = RuntimeObserver.start();
            if (!owned) { send(channel, "ERROR\tbusy"); return; }
            ByteBuffer input = ByteBuffer.allocate(128);
            var line = new StringBuilder();
            String app = null;
            while (!pztools.bridge.AgentEntry.runtimeReloadRequested()) {
                int read = channel.read(input);
                if (read < 0) return;
                if (read > 0) {
                    input.flip();
                    while (input.hasRemaining()) {
                        char value = (char)(input.get() & 255);
                        if (value == '\n') {
                            String[] fields = line.toString().split("\t", -1);
                            line.setLength(0);
                            // Anything else, or a second one, ends this otherwise read-only subscription.
                            if (fields.length != 2 || !fields[0].equals("LEASE") || app != null || !Leases.validApp(fields[1])) return;
                            app = fields[1];
                        } else if (value != '\r') {
                            if (line.length() >= 64) return;
                            line.append(value);
                        }
                    }
                    input.clear();
                }
                if (app != null) Leases.renewApp(app);
                send(channel, RuntimeObserver.frame());
                Thread.sleep(250);
            }
        } catch (Exception failure) {
            // Client receives an unavailable/ended stream; never try saving as a recovery action.
        } finally { if (owned) RuntimeObserver.stop(); }
    }
    private static void send(SocketChannel channel, String text) throws Exception {
        if (text.length() > 65536) throw new IllegalArgumentException("Oversized runtime snapshot");
        ByteBuffer buffer = StandardCharsets.UTF_8.encode(text + "\n");
        long start = System.nanoTime();
        while (buffer.hasRemaining()) {
            if (channel.write(buffer) == 0) {
                if (System.nanoTime() - start > 2_000_000_000L) throw new java.io.IOException("Slow runtime consumer");
                LockSupport.parkNanos(1_000_000L);
            }
        }
    }
}