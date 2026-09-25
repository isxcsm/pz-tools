package pztools.bridge.runtime;

import pztools.bridge.AgentEntry;

import java.io.*;
import java.lang.classfile.*;
import java.lang.constant.*;
import java.lang.instrument.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.ProtectionDomain;
import java.util.Base64;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Game-thread save bridge. Game installation files are never rewritten. */
public final class SaveBridge {
    private static final AtomicReference<Request> pending = new AtomicReference<>();
    private static volatile boolean installed;
    private static Class<?> window;
    private static Method save;
    private static Field gameThread;
    private static ClassLoader gameLoader;
    private static boolean legacyRetired;
    private static final Object owner = new Object();
    private static boolean acquired;

    public static void run(String options, Instrumentation instrumentation) {
        String[] parts = options.split(":", -1);
        if (parts.length != 2 || !parts[1].matches("[0-9a-f]{64}"))
            throw new IllegalArgumentException("Invalid bridge connection");
        int port = Integer.parseInt(parts[0]);
        if (port < 1 || port > 65535) throw new IllegalArgumentException("Invalid port");
        serve(port, parts[1], instrumentation);
    }

    private static void serve(int port, String token, Instrumentation instrumentation) {
        Request request = null;
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 5000);
            socket.setSoTimeout(5000);
            var input = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
            var output = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8), true);
            output.println("HELLO\t4\t" + ProcessHandle.current().pid() + "\t" + token);
            try {
                String line = readLimited(input);
                if (line == null) return;
                String[] command = line.split("\t", -1);
                boolean notice = command[0].equals("SAVE_COUNTDOWN");
                boolean validPlain = (command.length == 2 || command.length == 4)
                    && (command[0].equals("SAVE") || command[0].equals("PROBE"));
                boolean validNotice = notice && command.length == 5
                    && NoticeLanguages.supports(command[4]);
                boolean timed = command[0].equals("SAVE_AT") && command.length == 6
                    && (NoticeLanguages.supports(command[4]) || command[4].equals("off"));
                if (!validPlain && !validNotice && !timed)
                    throw new BridgeFailure("protocol", "Invalid save/probe request");
                long scheduledMillis = timed ? Long.parseLong(command[5]) : 0;
                if (timed && (scheduledMillis <= 0 || scheduledMillis - System.currentTimeMillis() > 60000))
                    throw new BridgeFailure("protocol", "Scheduled save must be due within one minute");
                int queueSeconds = command.length >= 4 ? Integer.parseInt(command[2]) : 15;
                int completionSeconds = command.length >= 4 ? Integer.parseInt(command[3]) : 150;
                if (queueSeconds < 1 || queueSeconds > 60 || completionSeconds < 30 || completionSeconds > 600
                    || completionSeconds < queueSeconds + 20)
                    throw new BridgeFailure("protocol", "Invalid request timeouts");
                String expected = new String(Base64.getDecoder().decode(command[1]), StandardCharsets.UTF_8);
                if (!Path.of(expected).isAbsolute()) throw new BridgeFailure("protocol", "An absolute save path is required");
                if (!AgentEntry.acquire(owner, SaveBridge::poll))
                    throw new BridgeFailure("busy", "Another bridge session is still active");
                acquired = true;
                if (!legacyRetired) {
                    if (!LegacyBridgeRetirement.retire(instrumentation))
                        throw new BridgeFailure("busy", "An older bridge request is still running");
                    legacyRetired = true;
                }
                install(instrumentation);
                request = new Request(!command[0].equals("PROBE"), expected, queueSeconds,
                    notice || timed && !command[4].equals("off") ? command[4] : null, scheduledMillis);
                if (!pending.compareAndSet(null, request))
                    throw new BridgeFailure("busy", "Another bridge request is still pending or running");
                awaitStarted(request, input, socket);
                output.println("RUNNING");
                // Reserve transport time before the client's overall response deadline.
                int scheduledWait = (int)Math.max(0, Math.ceil((request.notBefore - System.nanoTime()) / 1_000_000_000.0));
                String result = awaitResult(request, input, socket, completionSeconds - queueSeconds - 15 + scheduledWait);
                if (request.result.isDone() || request.state.get() == 3) cleanup(instrumentation);
                output.println(result);
            } catch (Throwable exception) {
                output.println(error(exception instanceof BridgeFailure failure ? failure.code : "bridge-failed",
                    describe(exception)));
            }
        } catch (Throwable exception) {
            // No callback connection means no command is accepted and no save is queued.
            System.err.println("[PzTools save bridge] " + describe(exception));
        } finally {
            if (request != null) {
                request.cancelBeforeSave();
                if (request.state.get() == 3) pending.compareAndSet(request, null);
            }
            try { cleanup(instrumentation); }
            catch (Throwable exception) { System.err.println("[PzTools bridge cleanup] " + describe(exception)); }
        }
    }

    private static synchronized void cleanup(Instrumentation instrumentation) throws Exception {
        if (!acquired) return;
        // The game-thread monitor is held through save(true). A disconnected client
        // cannot release ownership while that call is still running.
        pending.set(null);
        AgentEntry.release(owner);
        acquired = false;
    }

    private static String awaitResult(Request request, Reader input, Socket socket, int seconds) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds);
        socket.setSoTimeout(100);
        while (!request.result.isDone()) {
            if (System.nanoTime() >= deadline) {
                if (request.cancelBeforeSave())
                    return error("queue-timeout", "Countdown expired; cancelled without saving");
                return error("completion-unknown", "The game call is still running. Do not retry until it finishes");
            }
            try {
                if (input.read() == -1) throw new EOFException("Client disconnected");
                throw new BridgeFailure("protocol", "Unexpected data after request");
            } catch (SocketTimeoutException ignored) { }
        }
        return request.result.get();
    }

    private static void awaitStarted(Request request, Reader input, Socket socket) throws Exception {
        socket.setSoTimeout(100);
        while (!request.started.isDone()) {
            if (System.nanoTime() >= request.expiresAt) {
                if (request.state.compareAndSet(0, 3))
                    throw new BridgeFailure("queue-timeout", "Game did not process the request; cancelled without saving");
                return; // The game won the race and has begun processing.
            }
            try {
                if (input.read() == -1) throw new EOFException("Client disconnected");
                throw new BridgeFailure("protocol", "Unexpected data after request");
            } catch (SocketTimeoutException ignored) { }
        }
    }

    private static synchronized void install(Instrumentation instrumentation) throws Exception {
        if (installed) return;
        if (Runtime.version().feature() != 25 || !instrumentation.isRetransformClassesSupported())
            throw new BridgeFailure("unsupported-runtime", "This save bridge requires Java 25 and class retransformation");
        window = AgentEntry.ensureGameHook();
        gameLoader = window.getClassLoader();
        if (Class.forName(AgentEntry.class.getName(), false, gameLoader) != AgentEntry.class)
            throw new BridgeFailure("unsupported-loader", "Game cannot access the bridge class");
        Method logic = window.getDeclaredMethod("logic");
        save = window.getMethod("save", boolean.class);
        gameThread = window.getField("gameThread");
        if (!Modifier.isStatic(logic.getModifiers()) || logic.getReturnType() != void.class
                || !Modifier.isStatic(save.getModifiers()) || save.getReturnType() != void.class)
            throw new BridgeFailure("unsupported-game", "Game method signatures have changed");
        installed = true;
    }

    /** Called at a game-loop boundary, including paused frames; never does network I/O. */
    public static synchronized void poll() {
        Request request = pending.get();
        if (request == null) return;
        boolean starting = request.state.compareAndSet(0, 1);
        if (!starting && request.state.get() != 1) return;
        if (starting) request.started.complete(null);
        try {
            if (starting && System.nanoTime() > request.expiresAt)
                throw new BridgeFailure("queue-timeout", "Request expired without saving");
            if (Thread.currentThread() != gameThread.get(null))
                throw new BridgeFailure("wrong-thread", "Refusing to save outside the game thread");
            long now = System.nanoTime();
            if (starting || now >= request.nextValidation) {
                validateWorld(request.expectedPath);
                request.nextValidation = now + TimeUnit.SECONDS.toNanos(1);
            }
            if (starting && request.language != null) {
                try { request.notice = new SaveNotice(gameLoader, request.language, request.notBefore); }
                catch (Exception exception) { request.noticeError = describe(exception); }
            }
            if (request.notice != null) {
                try { if (!request.notice.ready(System.nanoTime())) return; }
                catch (Exception exception) { request.noticeError = describe(exception); request.notice = null; }
            }
            if (System.nanoTime() < request.notBefore) return;
            // The player can leave or switch worlds during the countdown.
            String actual = validateWorld(request.expectedPath);
            if (!request.state.compareAndSet(1, 2)) return;
            long start = System.nanoTime();
            if (request.save) save.invoke(null, true);
            long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);
            completeNotice(request, true);
            // A returned call is not a promise that the game's own caught errors do not exist.
            request.result.complete("OK\t" + encode((request.save ? "GameWindow.save(true) returned" : "Probe only; no save invoked")
                + "; thread=" + Thread.currentThread().getName() + "; elapsedMs=" + elapsedMs + "; save=" + actual
                + (request.noticeError == null ? "" : "; notice-unavailable=" + request.noticeError)));
        } catch (Throwable exception) {
            Throwable cause = exception instanceof InvocationTargetException invocation ? invocation.getCause() : exception;
            // Do not touch the old player's UI after leaving or switching worlds.
            if (request.state.get() == 2) completeNotice(request, false);
            request.result.complete(error(cause instanceof BridgeFailure failure ? failure.code : "save-failed", describe(cause)));
        } finally {
            if (request.result.isDone()) {
                request.state.set(3);
                pending.compareAndSet(request, null);
            }
        }
    }

    private static void completeNotice(Request request, boolean success) {
        if (request.notice == null) return;
        try { request.notice.complete(success); }
        catch (Exception exception) { request.noticeError = describe(exception); }
    }

    private static String validateWorld(String expected) throws Exception {
        if (boolField("zombie.network.GameClient", "client") || boolField("zombie.network.GameClient", "clientSave")
                || boolField("zombie.network.GameServer", "server"))
            throw new BridgeFailure("multiplayer", "This save bridge supports local single-player saves only");
        Object states = window.getField("states").get(null);
        Object state = states.getClass().getField("current").get(states);
        if (!gameClass("zombie.gameStates.IngameState").isInstance(state))
            throw new BridgeFailure("not-in-world", "Load the selected save before requesting a save");
        Object world = gameClass("zombie.iso.IsoWorld").getField("instance").get(null);
        if (world == null || world.getClass().getField("currentCell").get(world) == null)
            throw new BridgeFailure("not-in-world", "No loaded world");
        Class<?> coreClass = gameClass("zombie.core.Core");
        Object core = coreClass.getMethod("getInstance").invoke(null);
        String mode = (String)coreClass.getMethod("getGameMode").invoke(core);
        if ((boolean)coreClass.getMethod("isNoSave").invoke(core) || "LastStand".equals(mode) || "Tutorial".equals(mode))
            throw new BridgeFailure("saving-disabled", "Saving is disabled in this game mode");
        Class<?> fs = gameClass("zombie.ZomboidFileSystem");
        String actual = (String)fs.getMethod("getCurrentSaveDir").invoke(fs.getField("instance").get(null));
        if (!Files.isSameFile(Path.of(expected), Path.of(actual)))
            throw new BridgeFailure("save-mismatch", "Selected save differs from the running game: " + actual);
        return actual;
    }

    private static Class<?> gameClass(String name) throws ClassNotFoundException { return Class.forName(name, false, gameLoader); }
    private static boolean boolField(String type, String field) throws ReflectiveOperationException {
        return gameClass(type).getField(field).getBoolean(null);
    }
    private static String readLimited(Reader reader) throws IOException {
        var line = new StringBuilder();
        for (int ch; (ch = reader.read()) != -1;) {
            if (ch == '\n') return line.toString();
            if (ch != '\r') line.append((char)ch);
            if (line.length() > 16384) throw new IOException("Oversized request");
        }
        return null;
    }
    private static String encode(String value) { return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)); }
    private static String error(String code, String message) { return "ERROR\t" + code + "\t" + encode(message); }
    private static String describe(Throwable exception) { return exception.getClass().getSimpleName() + ": " + exception.getMessage(); }
    private static final class BridgeFailure extends Exception {
        final String code;
        BridgeFailure(String code, String message) { super(message); this.code = code; }
    }
    private static final class Request {
        final boolean save;
        final String expectedPath;
        final long expiresAt;
        final String language;
        final long notBefore;
        SaveNotice notice;
        String noticeError;
        long nextValidation;
        final AtomicInteger state = new AtomicInteger(); // queued, countdown, saving, finished/cancelled
        final CompletableFuture<Void> started = new CompletableFuture<>();
        final CompletableFuture<String> result = new CompletableFuture<>();
        Request(boolean save, String expectedPath, int queueSeconds, String language, long scheduledMillis) {
            this.save = save; this.expectedPath = expectedPath;
            this.language = language;
            this.notBefore = scheduledMillis == 0 ? 0 : System.nanoTime()
                + TimeUnit.MILLISECONDS.toNanos(Math.max(0, scheduledMillis - System.currentTimeMillis()));
            this.expiresAt = System.nanoTime() + TimeUnit.SECONDS.toNanos(queueSeconds);
        }
        boolean cancelBeforeSave() {
            return state.compareAndSet(0, 3) || state.compareAndSet(1, 3);
        }
    }
}
