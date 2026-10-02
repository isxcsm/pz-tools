package pztools.bridge.runtime;

import pztools.bridge.AgentEntry;
import pztools.extensions.api.*;
import java.util.UUID;

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
    private static Field worldInstance, worldCell;
    private static final String JVM_SESSION = RuntimeIdentity.processId();
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
            output.println("HELLO\t6\t" + ProcessHandle.current().pid() + "\t" + token);
            try {
                String line = readLimited(input);
                if (line == null) return;
                String[] command = line.split("\t", -1);
                // Profile recording control: answered at once, never queued for the game thread.
                if (ProfileControl.handles(command[0])) { output.println(ProfileControl.handle(command)); return; }
                // A note over the player: queued for the game thread, answered at once.
                if (GameNotices.handles(command[0])) { output.println(GameNotices.handle(command)); return; }
                boolean extension =(command[0].equals("PREPARE_SAVE") || command[0].equals("PREPARE_SAVE_ACTIVE"))
                    && command.length == 8 && (command[7].equals("force") || command[7].equals("normal"))
                    && command[6].length() <= 80 && command[6].matches("[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+");
                boolean active = (command[0].equals("SAVE_ACTIVE") || command[0].equals("PROBE_ACTIVE")) && command.length == 6
                    || extension && command[0].equals("PREPARE_SAVE_ACTIVE");
                RuntimeObserver.Ticket ticket = active ? RuntimeObserver.Ticket.parse(command[5]) : null;
                if ((active || extension) && !command[4].equals("off") && !NoticeLanguages.supports(command[4]))
                    throw new BridgeFailure("protocol", "Invalid notice language");
                boolean notice = command[0].equals("SAVE_COUNTDOWN");
                boolean validPlain = (command.length == 2 || command.length == 4)
                    && (command[0].equals("SAVE") || command[0].equals("PROBE"));
                boolean validNotice = notice && command.length == 5 && NoticeLanguages.supports(command[4]);
                boolean timed = command[0].equals("SAVE_AT") && command.length == 6
                    && (NoticeLanguages.supports(command[4]) || command[4].equals("off"));
                if (!validPlain && !validNotice && !timed && !extension && !active)
                    throw new BridgeFailure("protocol", "Invalid save/probe request");
                long scheduledMillis = timed || extension && !active ? Long.parseLong(command[5]) : 0;
                if (timed && scheduledMillis <= 0 || extension && scheduledMillis < 0
                        || (timed || extension) && scheduledMillis - System.currentTimeMillis() > 60000)
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
                if (ticket != null) RuntimeObserver.reserve(ticket);
                SaveModules resolvedModules = null;
                SaveModules.Resolution resolution = new SaveModules.Resolution(null, null);
                if (extension) {
                    try {
                        resolvedModules = AgentEntry.extensions();
                        resolution = resolvedModules.resolve(command[6], instrumentation, gameLoader, PzRuntimeAdapter.readVersion(gameLoader), command[7].equals("force"));
                    } catch (Exception | LinkageError unavailable) {
                        resolution = new SaveModules.Resolution(null, "module-unavailable");
                    }
                }
                request = new Request(!command[0].startsWith("PROBE"), expected, queueSeconds,
                    notice || (timed || extension || active) && !command[4].equals("off") ? command[4] : null, scheduledMillis, ticket);
                request.modules = resolvedModules; request.provider = resolution.provider();
                // Resolve the optional host capability before any capture is admitted.
                // Runtime and payload use sibling class loaders; resident SaveTask stays unchanged.
                if (resolvedModules != null) {
                    try {
                        request.cooperativeTask = Class.forName("pztools.extensions.runtime.CooperativeTask",
                            false, resolvedModules.getClass().getClassLoader());
                        request.advanceCapture = request.cooperativeTask.getMethod("advanceOnGameThread");
                    } catch (ClassNotFoundException olderHost) { request.cooperativeTask = null; }
                }
                request.requestedProvider = extension ? command[6] : null;
                request.fallbackReason = resolution.reason(); request.forceVersion = extension && command[7].equals("force");
                if (!pending.compareAndSet(null, request))
                    throw new BridgeFailure("busy", "Another bridge request is still pending or running");
                awaitStarted(request, input, socket);
                output.println("RUNNING");
                // Reserve transport time before the client's overall response deadline.
                int scheduledWait = (int)Math.max(0, Math.ceil((request.notBefore - System.nanoTime()) / 1_000_000_000.0));
                String result = awaitResult(request, input, socket, completionSeconds - queueSeconds - 15 + scheduledWait, output);
                if (request.result.isDone() || request.state.get() == 3) cleanup(instrumentation);
                output.println(result);
            } catch (Throwable exception) {
                output.println(error(exception instanceof RuntimeObserver.Deferred ? "runtime-deferred" : exception instanceof BridgeFailure failure ? failure.code : "bridge-failed",
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

    static void cancelObserver(String epoch) {
        Request request = pending.get();
        if (request != null && request.guard != null && request.guard.observer().equals(epoch) && request.cancelBeforeSave()) {
            request.started.complete(null);
            request.result.complete(error("runtime-deferred", "Runtime observer ended before saving"));
            pending.compareAndSet(request, null);
        }
    }

    private static synchronized void cleanup(Instrumentation instrumentation) throws Exception {
        if (!acquired) return;
        Request owned = pending.get();
        if (owned != null && owned.state.get() == 2 && !owned.result.isDone()) return;
        // The game-thread monitor is held through save(true). A disconnected client
        // cannot release ownership while that call is still running.
        pending.set(null);
        AgentEntry.release(owner);
        acquired = false;
    }

    private static String awaitResult(Request request, Reader input, Socket socket, int seconds, PrintWriter output) throws Exception {
        boolean saveStartedSent = false;
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds);
        socket.setSoTimeout(100);
        while (!request.result.isDone()) {
            if (!saveStartedSent && request.state.get() == 2) { output.println("SAVING"); saveStartedSent = true; }
            if (System.nanoTime() >= deadline) {
                if (request.cancelBeforeSave())
                    return error("queue-timeout", "Save preparation expired while waiting for countdown, interaction or workers; cancelled without saving");
                return error("completion-unknown", "The game call is still running. Do not retry until it finishes");
            }
            try {
                readControl(request, input);
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
                readControl(request, input);
            } catch (SocketTimeoutException ignored) { }
        }
    }

    private static void readControl(Request request, Reader input) throws Exception {
        int ch = input.read();
        if (ch == -1) throw new EOFException("Client disconnected");
        if (ch != 10) {
            if (ch != 13) request.control.append((char)ch);
            if (request.control.length() > 256) throw new BridgeFailure("protocol", "Oversized request control");
            return;
        }
        String line = request.control.toString(); request.control.setLength(0);
        if (request.guard == null || !line.equals("CANCEL\t" + request.guard.request()))
            throw new BridgeFailure("protocol", "Unexpected request control");
        // This CAS is the linearization point: once state==saving, a late cancel loses.
        if (request.cancelBeforeSave()) throw new RuntimeObserver.Deferred("runtime-reservation-cancelled");
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
        Class<?> worldType = gameClass("zombie.iso.IsoWorld");
        worldInstance = worldType.getField("instance");
        worldCell = worldType.getField("currentCell");
        if (!Modifier.isStatic(logic.getModifiers()) || logic.getReturnType() != void.class
                || !Modifier.isStatic(save.getModifiers()) || save.getReturnType() != void.class)
            throw new BridgeFailure("unsupported-game", "Game method signatures have changed");
        installed = true;
    }

    /** Game-loop dispatch: native serialization remains on this thread; completion waits never do. */
    public static synchronized void poll() {
        Request request = pending.get();
        if (request == null) return;
        try {
            if (request.state.get() == 2) {
                if (request.task != null) observeExtension(request);
                return;
            }
            boolean starting = request.state.compareAndSet(0, 1);
            if (!starting && request.state.get() != 1) return;
            if (starting) request.started.complete(null);
            if (starting && System.nanoTime() > request.expiresAt)
                throw new BridgeFailure("queue-timeout", "Request expired without saving");
            if (Thread.currentThread() != gameThread.get(null))
                throw new BridgeFailure("wrong-thread", "Refusing to save outside the game thread");
            long now = System.nanoTime();
            if (request.guard != null) request.notBefore = now + TimeUnit.MILLISECONDS.toNanos(request.guard.check());
            if (starting || now >= request.nextValidation) {
                validateWorld(request.expectedPath);
                request.nextValidation = now + TimeUnit.SECONDS.toNanos(1);
            }
            if (starting && request.save && request.language != null) {
                try { request.notice = new SaveNotice(gameLoader, request.language, request.notBefore); }
                catch (Exception exception) { request.noticeError = describe(exception); }
            }
            if (request.notice != null) {
                try { if (!request.notice.ready(System.nanoTime())) return; }
                catch (Exception exception) { request.noticeError = describe(exception); request.notice = null; }
            }
            if (System.nanoTime() < request.notBefore) return;
            String actual = request.context == null ? validateWorld(request.expectedPath) : request.saveDirectory;
            if (request.guard != null && request.guard.check() > 0) return;
            request.saveDirectory = actual;
            SaveProvider selected = request.provider;
            if (selected != null) {
                if (request.context == null) {
                    request.cell = currentCell();
                    request.context = new SaveProvider.Context(request.id, JVM_SESSION, RuntimeIdentity.worldId(request.cell),
                        Path.of(actual), Thread.currentThread(), gameLoader, new AtomicBoolean(true), PzRuntimeAdapter.readVersion(gameLoader), request.forceVersion);
                } else if (currentCell() != request.cell) {
                    request.context.worldValid().set(false);
                    throw new BridgeFailure("save-world-changed", "World changed while waiting to prepare a save");
                }
                var support = selected.inspect(request.context);
                if (!support.supported()) { request.fallbackReason = support.reason(); selected = null; }
                else if (!selected.readyToCapture(request.context)) return;
                actual = validateWorld(request.expectedPath);
                request.saveDirectory = actual;
                // A probe may race permission withdrawal. The guard and state CAS remain the admission boundary.
                if (request.guard != null && request.guard.check() > 0) return;
            }
            if (!request.state.compareAndSet(1, 2)) return;
            savingNotice(request);
            request.saveStarted = System.nanoTime();
            request.reportWorld = RuntimeIdentity.worldId(currentCell());
            request.actualProvider = selected == null ? "pztools.standard-save" : selected.id();
            publishExecution(request, "Running", request.fallbackReason);
            if (request.save) {
                try { RecoveryStamp.record(gameLoader); }
                catch (ReflectiveOperationException | RuntimeException failure) { request.recoveryError = describe(failure); }
            }
            if (selected != null) {
                // No catch-and-replay: begin() may already have changed world state.
                request.task = request.modules.begin(selected, request.context);
                request.captureNanos = System.nanoTime() - request.saveStarted;
                request.maximumSliceNanos = request.captureNanos;
                request.captureMillis = TimeUnit.NANOSECONDS.toMillis(request.captureNanos);
                publishExecution(request, "Running", request.fallbackReason);
                return;
            }
            if (request.save) save.invoke(null, true);
            request.captureMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - request.saveStarted);
            completeSuccess(request, "pztools.standard-save", "STANDARD_CALL_RETURNED",
                request.save ? "GameWindow.save(true) returned" : "Probe only; no save invoked");
        } catch (Throwable exception) {
            Throwable cause = exception instanceof InvocationTargetException invocation ? invocation.getCause() : exception;
            if (request.state.get() == 2 && (request.context == null || request.context.worldValid().get()))
                completeNotice(request, false);
            String failureCode = cause instanceof RuntimeObserver.Deferred ? "runtime-deferred" : cause instanceof BridgeFailure failure ? failure.code : "save-failed";
            if (request.task == null && request.saveStarted != 0) request.captureMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - request.saveStarted);
            publishExecution(request, "Failed", failureCode);
            request.result.complete(error(failureCode, describe(cause)));
        } finally {
            if (request.result.isDone()) {
                request.state.set(3); pending.compareAndSet(request, null);
                AgentEntry.release(owner); acquired = false;
            }
        }
    }

    private static void observeExtension(Request request) throws Exception {
        if (request.context.worldValid().get()) {
            try {
                if (currentCell() != request.cell) request.context.worldValid().set(false);
                if (System.nanoTime() >= request.nextValidation) {
                    validateWorld(request.expectedPath);
                    request.nextValidation = System.nanoTime() + TimeUnit.SECONDS.toNanos(1);
                }
            } catch (Exception worldEnded) { request.context.worldValid().set(false); }
        }
        SaveTask.Result result;
        long stepStarted = System.nanoTime();
        try {
            if (request.cooperativeTask != null && request.cooperativeTask.isInstance(request.task))
                request.advanceCapture.invoke(request.task);
            result = request.task.completed();
        }
        finally {
            long occupied = System.nanoTime() - stepStarted;
            request.captureNanos += occupied;
            request.maximumSliceNanos = Math.max(request.maximumSliceNanos, occupied);
            request.captureMillis = TimeUnit.NANOSECONDS.toMillis(request.captureNanos);
        }
        if (result == null) {
            if (request.context.worldValid().get()) savingNotice(request);
            return;
        }
        if (!request.context.worldValid().get())
            throw new BridgeFailure("save-world-changed", "World changed before save completion was confirmed");
        try { validateWorld(request.expectedPath); }
        catch (Exception worldEnded) {
            request.context.worldValid().set(false);
            throw new BridgeFailure("save-world-changed", "World ended before save completion");
        }
        if (!result.requestId().equals(request.id) || !result.sessionId().equals(JVM_SESSION)
                || !result.worldId().equals(request.context.worldId()))
            throw new BridgeFailure("extension-result-mismatch", "Unexpected save completion identity");
        if (result.failure() != null) throw new BridgeFailure("extension-save-failed", result.failure());
        if (result.cancelled()) throw new BridgeFailure("extension-save-cancelled", "Extension save did not commit");
        completeSuccess(request, request.provider.id(), result.completion().name(), "Extension save completed");
    }
    private static Object currentCell() throws ReflectiveOperationException {
        Object world = worldInstance.get(null);
        return world == null ? null : worldCell.get(world);
    }
    private static void completeSuccess(Request request, String provider, String completion, String message) {
        completeNotice(request, true);
        long elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - request.saveStarted);
        String detail = message + "; thread=" + Thread.currentThread().getName() + "; elapsedMs=" + elapsed
            + "; save=" + request.saveDirectory
            + (request.recoveryError == null ? "" : "; recovery-metadata-unavailable=" + request.recoveryError)
            + (request.noticeError == null ? "" : "; notice-unavailable=" + request.noticeError);
        publishExecution(request, "Succeeded", request.fallbackReason);
        if (request.requestedProvider == null) request.result.complete("OK\t" + encode(detail));
        else request.result.complete("SAVED\t" + provider + "\t" + completion + "\t" + encode(detail)
            + "\t" + (request.fallbackReason == null ? "-" : request.fallbackReason));
    }

    private static void publishExecution(Request request, String outcome, String reason) {
        if (request.requestedProvider == null || request.reportWorld == null || request.saveStarted == 0) return;
        SaveExecution.publish(new SaveExecution.Report(request.id, JVM_SESSION, request.reportWorld,
            request.requestedProvider, request.actualProvider, outcome, reason, request.task == null ? request.captureMillis
                : TimeUnit.NANOSECONDS.toMillis(request.maximumSliceNanos),
            TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - request.saveStarted)));
    }

    private static void savingNotice(Request request) {
        if (!request.save || request.notice == null) return;
        try { request.notice.saving(System.nanoTime()); }
        catch (Exception exception) { request.noticeError = describe(exception); request.notice = null; }
    }

    private static void completeNotice(Request request, boolean success) {
        if (!request.save || request.notice == null) return;
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
    private static String describe(Throwable exception) {
        // Preserve the throw site even for exceptions without a message.
        // Keep the wire/telemetry diagnostic bounded; a full stack trace can dwarf the result.
        if (exception instanceof BridgeFailure && exception.getCause() != null) exception = exception.getCause();
        var detail = new StringBuilder();
        for (int depth = 0; exception != null && depth < 4 && detail.length() < 512; depth++) {
            if (depth != 0) detail.append("; caused by ");
            detail.append(exception.getClass().getSimpleName());
            String message = exception.getMessage();
            if (message != null && !message.isBlank()) {
                detail.append(": ").append(message.substring(0, Math.min(160, message.length()))
                    .replace('\r', ' ').replace('\n', ' '));
            }
            StackTraceElement[] frames = exception.getStackTrace();
            for (int frame = 0; frame < Math.min(3, frames.length) && detail.length() < 512; frame++)
                detail.append(" at ").append(frames[frame]);
            Throwable cause = exception.getCause();
            if (cause == exception) break;
            exception = cause;
        }
        return detail.length() <= 512 ? detail.toString() : detail.substring(0, 509) + "...";
    }

    private static final class BridgeFailure extends Exception {
        final String code;
        BridgeFailure(String code, String message) { super(message); this.code = code; }
        BridgeFailure(String code, Throwable cause) { super(cause.getMessage(), cause); this.code = code; }
    }
    private static final class Request {
        final String id = UUID.randomUUID().toString();
        SaveModules modules;
        SaveProvider provider;
        volatile SaveTask task;
        Class<?> cooperativeTask;
        Method advanceCapture;
        SaveProvider.Context context;
        Object cell;
        String requestedProvider, fallbackReason, saveDirectory, recoveryError, reportWorld, actualProvider;
        long saveStarted, captureMillis, captureNanos, maximumSliceNanos;
        boolean forceVersion;

        final boolean save;
        final String expectedPath;
        final long expiresAt;
        final String language;
        long notBefore;
        final RuntimeObserver.Ticket guard;
        SaveNotice notice;
        String noticeError;
        long nextValidation;
        final StringBuilder control = new StringBuilder();
        final AtomicInteger state = new AtomicInteger(); // queued, countdown, saving, finished/cancelled
        final CompletableFuture<Void> started = new CompletableFuture<>();
        final CompletableFuture<String> result = new CompletableFuture<>();
        Request(boolean save, String expectedPath, int queueSeconds, String language, long scheduledMillis, RuntimeObserver.Ticket guard) {
            this.guard = guard;
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
