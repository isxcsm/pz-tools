package pztools.bridge.runtime;

import java.net.*;
import java.nio.*;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.locks.LockSupport;
import java.lang.instrument.Instrumentation;

/** One bounded observation stream independent of the save session. Never runs on the game thread. */
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
            ByteBuffer input = ByteBuffer.allocate(1);
            while (true) {
                int read = channel.read(input);
                if (read != 0) return; // EOF or unsolicited data ends this read-only subscription.
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