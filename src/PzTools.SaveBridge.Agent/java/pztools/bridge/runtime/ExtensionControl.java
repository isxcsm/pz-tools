package pztools.bridge.runtime;

import pztools.bridge.AgentEntry;
import pztools.extensions.api.*;
import java.io.IOException;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Field;
import java.net.*;
import java.nio.*;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.LockSupport;
import java.util.function.LongSupplier;

/** Authenticated wire 1, independent of the save request and read-only WATCH slots. */
public final class ExtensionControl {
    private static final long LEASE_NANOS = TimeUnit.SECONDS.toNanos(5);
    private static final int MAX_LINE = 100_000;
    private ExtensionControl() { }
    public static void run(String options, Instrumentation instrumentation) {
        Session owner = null;
        try {
            String[] p = options.split(":", -1);
            if (p.length != 2 || !p[1].matches("[0-9a-f]{64}")) throw new IllegalArgumentException("Invalid extension session");
            try (SocketChannel channel = SocketChannel.open()) {
                channel.socket().connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), Integer.parseInt(p[0])), 5000);
                channel.configureBlocking(false);
                send(channel, "EXTENSIONS\t1\t" + ProcessHandle.current().pid() + "\t" + p[1]);
                owner = new Session(instrumentation, AgentEntry.ensureGameHook());
                if (!AgentEntry.acquireLifecycle(owner, owner::poll)) throw new IllegalStateException("Lifecycle already owned");
                ByteBuffer buffer = ByteBuffer.allocate(8192);
                var line = new StringBuilder();
                while (!AgentEntry.runtimeReloadRequested() && !owner.expired()) {
                    int read = channel.read(buffer);
                    if (read < 0) break;
                    if (read == 0) { LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(5)); continue; }
                    buffer.flip();
                    while (buffer.hasRemaining()) {
                        int value = buffer.get() & 255;
                        if (value == '\n') {
                            String reply = owner.command(line.toString()); line.setLength(0); send(channel, reply);
                        } else if (value != '\r') {
                            if (value < 32 && value != '\t' || value > 126 || line.length() >= MAX_LINE)
                                throw new IOException("Invalid extension frame");
                            line.append((char)value);
                        }
                    }
                    buffer.clear();
                }
            }
        } catch (Exception | LinkageError failure) {
            // Losing this authenticated channel revokes permission; it never starts or retries a save.
        } finally { if (owner != null) owner.close(); }
    }
    private record Cached(String request, String response) { }
    static final class Session {
        private final Instrumentation instrumentation;
        private final ClassLoader loader;
        private final PzRuntimeAdapter adapter;
        private final Field gameThread;
        private final LongSupplier clock;
        private final Callable<ContinuousModules> moduleHost;
        private final Map<String, Cached> completed = new HashMap<>();
        private volatile ContinuousModules modules;
        private volatile long deadline;
        private volatile boolean active = true;
        private volatile ContinuousProvider.Context context;
        private String epoch;
        Session(Instrumentation instrumentation, Class<?> window) throws Exception {
            this(instrumentation, window, System::nanoTime);
        }
        Session(Instrumentation instrumentation, Class<?> window, LongSupplier clock) throws Exception {
            this(instrumentation, window, clock, () -> (ContinuousModules)AgentEntry.extensions());
        }
        Session(Instrumentation instrumentation, Class<?> window, LongSupplier clock,
                Callable<ContinuousModules> moduleHost) throws Exception {
            this.instrumentation = instrumentation; loader = window.getClassLoader();
            this.moduleHost = moduleHost;
            this.clock = clock; deadline = clock.getAsLong() + LEASE_NANOS;
            adapter = new PzRuntimeAdapter(window); gameThread = window.getField("gameThread");
        }
        boolean expired() { return !active || clock.getAsLong() - deadline >= 0; }
        void poll() {
            ContinuousModules target = modules;
            if (expired()) { if (target != null) target.revoke("lease-expired"); return; }
            try {
                if (Thread.currentThread() != gameThread.get(null)) throw new IllegalStateException("Wrong game thread");
                adapter.read();
                if (!adapter.phase.equals("Ready") || !adapter.mode.equals("LocalSinglePlayer")) {
                    invalidateWorld(); if (target != null) target.tick(null); return;
                }
                ContinuousProvider.Context previous = context;
                if (previous == null || previous.worldIdentity() != adapter.worldCell) {
                    invalidateWorld();
                    // A newly loaded paused world must still revoke the old world's admission.
                    if (previous != null && target != null) target.revoke("world-changed");
                    context = new ContinuousProvider.Context(RuntimeIdentity.processId(), RuntimeIdentity.worldId(adapter.worldCell),
                        adapter.worldCell, Thread.currentThread(), loader, new AtomicBoolean(true));
                }
                if (target != null && adapter.pause.equals("Running")) target.tick(context);
            } catch (Throwable failure) {
                invalidateWorld(); if (target != null) target.revoke("runtime-unavailable");
            }
        }
        private void invalidateWorld() {
            ContinuousProvider.Context previous = context; context = null;
            if (previous != null) previous.worldValid().set(false);
        }
        String command(String line) throws Exception {
            if (expired()) throw new IOException("Extension lease expired");
            String[] p = line.split("\t", -1);
            if (p.length < 3 || !p[1].matches("[A-Za-z0-9_-]{1,80}") || !p[2].matches("[a-f0-9]{32}"))
                throw new IOException("Invalid extension command identity");
            if (epoch == null) epoch = p[2];
            if (!epoch.equals(p[2])) throw new IOException("Controller epoch changed");
            Cached cached = completed.get(p[1]);
            if (cached != null) {
                if (!cached.request.equals(line)) throw new IOException("Command identity reused");
                deadline = clock.getAsLong() + LEASE_NANOS; return cached.response;
            }
            ContinuousModules.Status result;
            boolean mutating = p[0].equals("APPLY") || p[0].equals("OFF");
            if (mutating && completed.size() >= 4096) throw new IOException("Reconnect before more configuration changes");
            if (p[0].equals("APPLY") && p.length == 10) {
                if (!p[3].matches("[a-f0-9]{32}") || !p[4].matches("[a-f0-9]{32}")
                        || !p[7].matches("[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+")
                        || !Set.of("normal", "force").contains(p[8])) throw new IOException("Invalid apply identity");
                long expected = Long.parseLong(p[5]), revision = Long.parseLong(p[6]);
                if (expected < -1 || revision < 0) throw new IOException("Invalid configuration revision");
                var config = parseConfig(p[9]);
                deadline = clock.getAsLong() + LEASE_NANOS;
                try {
                    ContinuousModules next = moduleHost.call(); modules = next;
                    result = next.apply(new ContinuousModules.Apply(p[3], p[4], expected, revision, p[7], p[8].equals("force"), config),
                        instrumentation, loader, PzRuntimeAdapter.readVersion(loader));
                } catch (Exception | LinkageError unavailable) {
                    var previous = modules == null ? disabled() : modules.status();
                    result = new ContinuousModules.Status(previous.state().equals("Disabled") ? "Unsupported" : previous.state(),
                        "host-update-unavailable", previous.processId(), previous.worldId(), previous.generation(),
                        previous.appliedRevision(), previous.moduleVersion(), previous.moduleSha256(), previous.diagnostics());
                }
            } else if (p.length == 3 && Set.of("STATUS", "PING", "OFF").contains(p[0])) {
                deadline = clock.getAsLong() + LEASE_NANOS;
                ContinuousModules target = modules;
                // A new controller must see the resident host's failure, not manufacture a clean Disabled state.
                // Commands run only after acquiring the lifecycle slot; a rejected owner never touches that host.
                if (target == null) modules = target = moduleHost.call();
                result = p[0].equals("OFF") ? target.deactivate("user-disabled") : target.status();
            } else throw new IOException("Unknown extension command");
            String response = wire(p[1], result);
            if (mutating) completed.put(p[1], new Cached(line, response));
            return response;
        }
        void close() {
            active = false; invalidateWorld();
            ContinuousModules target = modules;
            try { if (target != null) target.revoke("connection-ended"); }
            catch (Throwable ignored) { /* Still release the bootstrap slot and attempt full retirement. */ }
            finally { AgentEntry.releaseLifecycle(this); }
            try { if (target != null) target.deactivate("connection-ended"); }
            catch (Throwable ignored) { /* The closed owner cannot renew admission. */ }
            finally { completed.clear(); modules = null; }
        }
    }
    static Map<String, String> parseConfig(String encoded) throws IOException {
        byte[] bytes;
        try { bytes = Base64.getDecoder().decode(encoded); }
        catch (IllegalArgumentException bad) { throw new IOException("Invalid configuration encoding"); }
        if (bytes.length > 65536) throw new IOException("Oversized configuration");
        String text;
        try { text = StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString(); }
        catch (java.nio.charset.CharacterCodingException bad) { throw new IOException("Invalid configuration text"); }
        var result = new LinkedHashMap<String, String>();
        for (String line : text.split("\n", -1)) {
            if (line.isEmpty()) continue;
            String[] pair = line.split("\t", -1);
            if (pair.length != 2 || !pair[0].matches("[A-Za-z0-9_.-]{1,100}") || pair[1].length() > 4096
                    || pair[1].chars().anyMatch(c -> c < 32) || result.size() >= 128
                    || result.putIfAbsent(pair[0], pair[1]) != null) throw new IOException("Invalid configuration entry");
        }
        return Map.copyOf(result);
    }
    private static ContinuousModules.Status disabled() {
        return new ContinuousModules.Status("Disabled", null, RuntimeIdentity.processId(), null, null, -1, null, null, "");
    }
    static String wire(String command, ContinuousModules.Status s) {
        return String.join("\t", "STATE", command, s.state(), encoded(s.reason()), s.processId(), plain(s.worldId()),
            plain(s.generation()), Long.toString(s.appliedRevision()), plain(s.moduleVersion()), plain(s.moduleSha256()), encoded(s.diagnostics()));
    }
    private static String plain(String value) { return value == null || value.isEmpty() ? "-" : value; }
    private static String encoded(String value) { return value == null || value.isEmpty() ? "-" : Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)); }
    private static void send(SocketChannel channel, String line) throws IOException {
        ByteBuffer data = StandardCharsets.US_ASCII.encode(line + "\n");
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (data.hasRemaining()) if (channel.write(data) == 0) {
            if (System.nanoTime() - end >= 0) throw new IOException("Slow extension controller");
            LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(1));
        }
    }
}
