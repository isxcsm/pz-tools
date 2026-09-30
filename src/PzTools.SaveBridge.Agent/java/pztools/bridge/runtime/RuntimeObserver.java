package pztools.bridge.runtime;

import pztools.bridge.AgentEntry;
import pztools.extensions.api.RuntimeIdentity;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;
import java.nio.charset.StandardCharsets;

/** One latest snapshot; no I/O, subscriber locks or serialization on the game thread. */
public final class RuntimeObserver {
    private static final String PROCESS = RuntimeIdentity.processId();
    private static volatile Context context;
    private static String id() { return UUID.randomUUID().toString().replace("-", ""); }

    public record Snapshot(String process, String observer, String world, long clock, long eligibility,
        long sequence, String phase, String pause, String mode, int speed, long activeMillis, String path, String gameVersion, LiveCharacter.Facts character, SaveExecution.Report execution) {
        String wire(long age) {
            String encoded = path == null ? "-" : Base64.getEncoder().encodeToString(path.getBytes(StandardCharsets.UTF_8));
            return String.join("\t", "STATE4", process, observer, world, Long.toString(clock),
                Long.toString(eligibility), Long.toString(sequence), phase, pause, mode,
                Integer.toString(speed), Long.toString(activeMillis), Long.toString(age), encoded,
                "runtime.snapshot.v1,runtime.active-clock.v1,save.guarded.v1,runtime.version.v1,runtime.character.v1,runtime.save-result.v1,runtime.sleep.v1", gameVersion == null ? "-" : Base64.getEncoder().encodeToString(gameVersion.getBytes(StandardCharsets.UTF_8)), character.life(), character.character() == null ? "-" : character.character(), character.death() == null ? "-" : character.death(), execution == null ? "-" : execution.wire(), character.sleep());
        }
    }
    /** A stopped generation is never mutated/reused by the next subscription. */
    private static final class Context {
        final PzRuntimeAdapter adapter;
        final LiveCharacter characterReader;
        LiveCharacter.Facts character = LiveCharacter.Facts.UNKNOWN;
        final String observer = id();
        final AtomicLong commandWatermark = new AtomicLong();
        volatile boolean active = true;
        volatile Snapshot snapshot;
        volatile long lastSample;
        String world = id(), phase = "Unknown", pause = "Unknown", mode = "Unsupported";
        Object lastCell;
        long clockEpoch, eligibility, sequence, activeNanos, lastTick, published;
        boolean wasRunning;
        Context(Class<?> window) throws Exception {
            adapter = new PzRuntimeAdapter(window);
            characterReader = new LiveCharacter(window.getClassLoader());
            lastSample = System.nanoTime(); published = lastSample;
            snapshot = exact();
        }
        Snapshot exact() {
            return new Snapshot(PROCESS, observer, world, clockEpoch, eligibility, sequence,
                phase, pause, mode, adapter.speedLevel, activeNanos / 1_000_000L,
                phase.equals("Ready") ? adapter.path : null, adapter.gameVersion, phase.equals("Ready") && mode.equals("LocalSinglePlayer") ? character : LiveCharacter.Facts.UNKNOWN, SaveExecution.latest());
        }
        void sample() {
            if (!active) return;
            long now = System.nanoTime();
            try {
                adapter.read();
                boolean ready = adapter.phase.equals("Ready") && adapter.mode.equals("LocalSinglePlayer");
                boolean newWorld = ready && adapter.worldCell != lastCell;
                if (newWorld) world = RuntimeIdentity.worldId(adapter.worldCell);
                LiveCharacter.Facts nextCharacter = ready ? characterReader.read(world) : LiveCharacter.observe(null, null, "Unknown");
                // Sleep that cannot be read only loses the sleep pause; it must not stop the clock.
                boolean running = ready && adapter.pause.equals("Running") && !nextCharacter.sleep().equals("Asleep");
                boolean gap = lastTick != 0 && (now - lastTick < 0 || now - lastTick > 2_000_000_000L);
                boolean changed = !adapter.phase.equals(phase) || !adapter.pause.equals(pause)
                    || !adapter.mode.equals(mode) || newWorld;
                if (newWorld) {
                    clockEpoch++; activeNanos = 0;
                }
                else if (gap) { clockEpoch++; activeNanos = 0; }
                else if (lastTick != 0 && wasRunning && running) activeNanos += now - lastTick;
                if (gap || newWorld || !running && wasRunning || !adapter.phase.equals(phase)) eligibility++;
                lastTick = now; lastSample = now;
                changed |= !nextCharacter.equals(character) || snapshot.execution() != SaveExecution.latest(); character = nextCharacter;
                if (ready) lastCell = adapter.worldCell;
                else if (adapter.phase.equals("Menu") || adapter.phase.equals("Unloading")) {
                    lastCell = null; RuntimeIdentity.forgetWorld();
                }
                wasRunning = running;
                phase = adapter.phase; pause = adapter.pause; mode = adapter.mode;
                if (changed || gap || now - published >= 100_000_000L) {
                    sequence++; snapshot = exact(); published = now;
                }
            } catch (Throwable failure) {
                wasRunning = false; lastTick = now; lastSample = now;
                boolean changed = !phase.equals("Unknown");
                if (changed) eligibility++;
                phase = "Unknown"; pause = "Unknown"; mode = "Unsupported";
                if (changed || now - published >= 100_000_000L) {
                    sequence++; snapshot = exact(); published = now;
                }
            }
        }
    }
    public static synchronized boolean start() throws Exception {
        if (context != null && context.active) return false;
        Context next = new Context(AgentEntry.ensureGameHook());
        context = next;
        // The per-frame slot is shared with an optional profile recording; its mark is one branch when idle.
        AgentEntry.observe(() -> { ProfileRecorder.frame(); next.sample(); });
        return true;
    }
    public static synchronized void stop() {
        Context previous = context;
        if (previous != null) {
            previous.active = false;
            LiveCharacter.disconnect();
            SaveBridge.cancelObserver(previous.observer);
        }
        AgentEntry.observe(null);
        context = null;
        ProfileControl.observerStopped();
    }
    static boolean running() { Context value = context; return value != null && value.active; }
    static String frame() {
        Context value = context;
        if (value == null || !value.active) throw new Deferred("runtime-unavailable");
        return value.snapshot.wire(Math.max(0, (System.nanoTime() - value.lastSample) / 1_000_000L));
    }
    public static Snapshot currentOnGameThread() {
        Context value = context;
        if (value == null || !value.active) throw new Deferred("runtime-unavailable");
        value.sample();
        if (value != context || !value.active || System.nanoTime() - value.lastSample > 2_000_000_000L)
            throw new Deferred("runtime-unavailable");
        return value.exact();
    }
    public static void reserve(Ticket ticket) {
        Context value = context;
        if (value == null || !value.active || !value.observer.equals(ticket.observer))
            throw new Deferred("runtime-epoch-changed");
        long previous;
        do {
            previous = value.commandWatermark.get();
            if (ticket.ordinal <= previous) throw new Deferred("runtime-request-replayed");
        } while (!value.commandWatermark.compareAndSet(previous, ticket.ordinal));
    }
    public record Ticket(String process, String observer, String world, long clock, long eligibility,
                         long due, long ordinal, String request, String character, String death) {
        static Ticket parse(String text) {
            if (text.length() > 1024) throw new IllegalArgumentException("Oversized runtime ticket");
            String[] p = text.split("\\|", -1);
            if (!(p.length == 9 && p[0].equals("1") || p.length == 11 && p[0].equals("2"))) throw new IllegalArgumentException("Unsupported runtime ticket");
            for (int i : new int[]{1,2,3,8})
                if (!p[i].matches("[0-9a-fA-F]{32}")) throw new IllegalArgumentException("Invalid ticket identity");
            Ticket result = new Ticket(p[1],p[2],p[3],Long.parseLong(p[4]),Long.parseLong(p[5]),
                Long.parseLong(p[6]),Long.parseLong(p[7]),p[8], p.length == 11 ? p[9] : null, p.length == 11 ? p[10] : null);
            if (result.clock < 0 || result.eligibility < 0 || result.due < 0 || result.ordinal <= 0 || result.death != null && (result.due != 0 || !result.character.matches("[0-9a-fA-F]{32}") || !result.death.matches("[0-9a-fA-F]{32}")))
                throw new IllegalArgumentException("Invalid ticket values");
            return result;
        }
        long check() {
            Snapshot s = currentOnGameThread();
            if (!s.process.equals(process) || !s.observer.equals(observer) || !s.world.equals(world)
                || death == null && (s.clock != clock || s.eligibility != eligibility)) throw new Deferred("runtime-epoch-changed");
            if (!s.phase.equals("Ready") || !s.mode.equals("LocalSinglePlayer")) throw new Deferred("runtime-world-unavailable");
            if (death != null) {
                if (!s.character.life().equals("Dead") || !character.equals(s.character.character()) || !death.equals(s.character.death()))
                    throw new Deferred("runtime-character-changed");
                return 0; // Death backups do not depend on the periodic active-time/pause clock.
            }
            if (!s.pause.equals("Running")) throw new Deferred("runtime-game-paused");
            if (s.character.sleep().equals("Asleep")) throw new Deferred("runtime-character-asleep");
            long remaining = due - s.activeMillis;
            if (remaining > 60_000) throw new Deferred("runtime-deadline-invalid");
            return Math.max(0, remaining);
        }
    }
    public static final class Deferred extends RuntimeException { public Deferred(String code) { super(code); } }
}