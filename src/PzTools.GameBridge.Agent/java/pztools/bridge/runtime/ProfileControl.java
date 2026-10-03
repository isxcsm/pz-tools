package pztools.bridge.runtime;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.Base64;
import pztools.bridge.AgentEntry;

/**
 * Short start/stop/status commands on the ordinary request channel. The recording itself runs
 * inside the JVM between two commands, so no connection stays open and saving is never blocked
 * for longer than one command takes.
 */
final class ProfileControl {
    private static Thread monitor;
    // The app run that asked for the rolling recording: it keeps the recording only while that run holds its lease
    // (Leases), so an app that crashed or was killed does not leave the game recording, sampling Lua and with its timer
    // raised until it exits. The game follows the run, not its process, which it cannot even open: the app runs as
    // administrator and the game does not.
    private static String rollingOwner;
    private static boolean ownsFrameHook;
    // Whether the rolling recording marks frames, said again with each save.
    private static String rollingFrames = "frames";
    private ProfileControl() { }

    static boolean handles(String command) { return command.startsWith("PROFILE_"); }

    static synchronized String handle(String[] command) {
        releaseIdleNoticeHook();
        try {
            switch (command[0]) {
                case "PROFILE_START" -> {
                    if (command.length != 4 || !(command[2].equals("general") || command[2].equals("detailed")))
                        return error("protocol", "Invalid profile start request");
                    Path destination = path(command[1]);
                    int seconds = Integer.parseInt(command[3]);
                    Hook hook = hookFrames();
                    String status = ProfileRecorder.start(destination, command[2].equals("detailed"), seconds, hook.game());
                    startMonitor();
                    return ok(status + ";" + hook.frames());
                }
                // Keeps only the last stretch, for as long as the app wants it, until a save takes what it holds.
                case "PROFILE_ROLL_START" -> {
                    // Optional: the most the game may hold on disk, in megabytes (0 for the default), then the app run
                    // whose lease the rolling recording follows (see rollingOwner).
                    if (command.length < 3 || command.length > 5 || !(command[1].equals("general") || command[1].equals("detailed")))
                        return error("protocol", "Invalid rolling start request");
                    int seconds = Integer.parseInt(command[2]);
                    int megabytes = command.length >= 4 && Integer.parseInt(command[3]) > 0 ? Integer.parseInt(command[3])
                        : ProfileRecorder.DEFAULT_ROLLING_MEGABYTES;
                    String owner = command.length == 5 ? command[4] : null;
                    if (owner != null && !Leases.validApp(owner)) return error("protocol", "Invalid app run");
                    // The request is that run's own word: it holds its lease from now, whether or not its state stream
                    // has connected yet.
                    if (owner != null) Leases.renewApp(owner);
                    Hook hook = hookFrames();
                    String status = ProfileRecorder.startRolling(command[1].equals("detailed"), seconds, megabytes, hook.game());
                    rollingFrames = hook.frames();
                    rollingOwner = owner;
                    startMonitor();
                    return ok(status + ";" + rollingFrames);
                }
                case "PROFILE_ROLL_SAVE" -> {
                    if (command.length != 2) return error("protocol", "Invalid rolling save request");
                    return ok(ProfileRecorder.save(path(command[1])) + ";" + rollingFrames);
                }
                case "PROFILE_ROLL_STOP" -> {
                    if (command.length != 1) return error("protocol", "Invalid rolling stop request");
                    String status = ProfileRecorder.stopRolling();
                    rollingOwner = null;
                    if (!ProfileRecorder.active()) releaseFrameHook();
                    return ok(status);
                }
                case "PROFILE_STOP" -> {
                    if (command.length != 1) return error("protocol", "Invalid profile stop request");
                    String status = ProfileRecorder.stop();
                    // A rolling recording may still mark frames.
                    if (!ProfileRecorder.active()) releaseFrameHook();
                    return ok(status);
                }
                case "PROFILE_STATUS" -> {
                    if (command.length != 1) return error("protocol", "Invalid profile status request");
                    return ok(ProfileRecorder.status());
                }
                default -> { return error("protocol", "Unknown profile request"); }
            }
        } catch (IllegalStateException state) {
            return error(String.valueOf(state.getMessage()), "Profile recorder state: " + state.getMessage());
        } catch (Throwable failure) {
            return error("profile-failed", failure.getClass().getSimpleName() + (failure.getMessage() == null ? "" : ": " + failure.getMessage()));
        }
    }

    private record Hook(ClassLoader game, String frames) { }

    /**
     * Frame boundaries come from the game-loop hook. If it cannot be installed the recording still
     * runs; it just has no frame graph.
     */
    private static Hook hookFrames() {
        String frames = "frames";
        ClassLoader game = null;
        try {
            Class<?> window = AgentEntry.ensureGameHook();
            game = window.getClassLoader();
            // The free slot only: a state observer's calls the relay itself, and is never replaced.
            if (!RuntimeObserver.running() && (ownsFrameHook || AgentEntry.observeIf(null, RELAY))) ownsFrameHook = true;
            // The recording holds the relay now; a note's own claim on it ends with it.
            noticeHook = false;
        } catch (Exception | LinkageError unavailable) { frames = "no-frames"; }
        return new Hook(game == null ? ClassLoader.getSystemClassLoader() : game, frames);
    }

    private static Path path(String encoded) { return Path.of(new String(Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8)); }

    // The relay this class puts in the per-frame slot; one instance, so it gives back only its own.
    private static final Runnable RELAY = ProfileFrames::tick;

    /**
     * RuntimeObserver gave up the per-frame slot, and with it whatever this class held: keep frame marks flowing if
     * a recording marks them. Asks the relay, not the recorder, so stopping the observer never loads the flight
     * recorder.
     */
    static synchronized void observerStopped() {
        ownsFrameHook = false;
        noticeHook = false;
        if (ProfileFrames.attached() && AgentEntry.observeIf(null, RELAY)) ownsFrameHook = true;
    }

    private static void releaseFrameHook() {
        // Only the relay itself: a state observer that took the slot since keeps it.
        if (ownsFrameHook) AgentEntry.observeIf(RELAY, null);
        ownsFrameHook = false;
        noticeHook = false;
    }

    // The per-frame relay also shows the app's notes over the player. With no state observer to call it, a note
    // installs it, and gives it back once the note had its time (unless a recording uses it), or at once when the
    // payload is being replaced: the bootstrap waits for the slot to be free.
    private static boolean noticeHook;
    private static long noticeHookSince;
    private static Thread noticeWatch;

    static synchronized void hookForNotice() {
        releaseIdleNoticeHook();
        if (RuntimeObserver.running() || ownsFrameHook || !AgentEntry.observeIf(null, RELAY)) return;
        ownsFrameHook = true;
        noticeHook = true;
        noticeHookSince = System.nanoTime();
        if (noticeWatch != null) return;
        noticeWatch = new Thread(() -> {
            try {
                while (true) {
                    Thread.sleep(200);
                    synchronized (ProfileControl.class) {
                        if (noticeHook && AgentEntry.runtimeReloadRequested()) releaseFrameHook();
                        releaseIdleNoticeHook();
                        if (!noticeHook) { noticeWatch = null; return; }
                    }
                }
            } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }, "PzTools-notice-relay");
        noticeWatch.setDaemon(true);
        noticeWatch.start();
    }

    private static void releaseIdleNoticeHook() {
        if (noticeHook && !ProfileFrames.attached() && System.nanoTime() - noticeHookSince > 10_000_000_000L) releaseFrameHook();
    }

    // A replaced payload must not leave its recording, sampler or frame callback behind: the
    // bootstrap waits for every callback of the old generation to go before loading the new one.
    // Whether it goes on is decided under this class's lock, where a recording starts: one started as the
    // monitor ends always gets a new one.
    private static void startMonitor() {
        if (monitor != null) return;
        monitor = new Thread(() -> {
            try {
                while (true) {
                    synchronized (ProfileControl.class) {
                        if (AgentEntry.runtimeReloadRequested()) {
                            ProfileRecorder.closeQuietly();
                            releaseFrameHook();
                            monitor = null;
                            return;
                        }
                        // The recording asked for ended at its maximum duration with no stop request (the recording
                        // program may be gone): it should no longer set the Lua sampler's pace, and with no rolling
                        // recording beside it, nothing should keep sampling the game or marking its frames.
                        ProfileRecorder.wrapUpIfEnded();
                        if (rollingOwner != null && !Leases.appHolds(rollingOwner)) {
                            ProfileRecorder.stopRolling();
                            rollingOwner = null;
                        }
                        if (!ProfileRecorder.active()) {
                            if (!noticeHook) releaseFrameHook();
                            monitor = null;
                            return;
                        }
                    }
                    Thread.sleep(100);
                }
            } catch (InterruptedException interrupted) {
                synchronized (ProfileControl.class) { monitor = null; }
                Thread.currentThread().interrupt();
            }
        }, "PzTools-profile-monitor");
        monitor.setDaemon(true);
        monitor.start();
    }


    static String ok(String detail) { return "OK\t" + encode(detail); }
    static String error(String code, String message) {
        return "ERROR\t" + code.replace('\t', ' ') + "\t" + encode(message.length() > 400 ? message.substring(0, 400) : message);
    }
    private static String encode(String value) { return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)); }
}
