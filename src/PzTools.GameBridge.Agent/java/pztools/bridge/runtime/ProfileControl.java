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
                    // An optional fourth field: the most the game may hold on disk, in megabytes.
                    if (command.length < 3 || command.length > 4 || !(command[1].equals("general") || command[1].equals("detailed")))
                        return error("protocol", "Invalid rolling start request");
                    int seconds = Integer.parseInt(command[2]);
                    int megabytes = command.length == 4 ? Integer.parseInt(command[3]) : ProfileRecorder.DEFAULT_ROLLING_MEGABYTES;
                    Hook hook = hookFrames();
                    String status = ProfileRecorder.startRolling(command[1].equals("detailed"), seconds, megabytes, hook.game());
                    rollingFrames = hook.frames();
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
                    if (!ProfileRecorder.active()) releaseFrameHook();
                    return ok(status);
                }
                case "PROFILE_STOP" -> {
                    if (command.length != 1) return error("protocol", "Invalid profile stop request");
                    String status = ProfileRecorder.stop();
                    releaseFrameHook();
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
            if (!RuntimeObserver.running()) { AgentEntry.observe(ProfileFrames::tick); ownsFrameHook = true; }
            // The recording holds the relay now; a note's own claim on it ends with it.
            noticeHook = false;
        } catch (Exception | LinkageError unavailable) { frames = "no-frames"; }
        return new Hook(game == null ? ClassLoader.getSystemClassLoader() : game, frames);
    }

    private static Path path(String encoded) { return Path.of(new String(Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8)); }

    /**
     * RuntimeObserver gave up the per-frame slot; keep frame marks flowing if a recording marks them. Asks the relay,
     * not the recorder, so stopping the observer never loads the flight recorder.
     */
    static synchronized void observerStopped() {
        if (ProfileFrames.attached()) { AgentEntry.observe(ProfileFrames::tick); ownsFrameHook = true; }
    }

    private static void releaseFrameHook() {
        if (ownsFrameHook && !RuntimeObserver.running()) AgentEntry.observe(null);
        ownsFrameHook = false;
        noticeHook = false;
    }

    // The per-frame relay also shows the app's notes over the player. With no state observer to call it, a note
    // installs it, and the next command after the note had its time takes it away again (unless a recording uses it).
    private static boolean noticeHook;
    private static long noticeHookSince;

    static synchronized void hookForNotice() {
        releaseIdleNoticeHook();
        if (RuntimeObserver.running() || ownsFrameHook) return;
        AgentEntry.observe(ProfileFrames::tick);
        ownsFrameHook = true;
        noticeHook = true;
        noticeHookSince = System.nanoTime();
    }

    private static void releaseIdleNoticeHook() {
        if (noticeHook && !ProfileFrames.attached() && System.nanoTime() - noticeHookSince > 10_000_000_000L) releaseFrameHook();
    }

    // A replaced payload must not leave its recording, sampler or frame callback behind: the
    // bootstrap waits for every callback of the old generation to go before loading the new one.
    private static void startMonitor() {
        if (monitor != null && monitor.isAlive()) return;
        monitor = new Thread(() -> {
            try {
                while (ProfileRecorder.active()) {
                    if (AgentEntry.runtimeReloadRequested()) {
                        synchronized (ProfileControl.class) { ProfileRecorder.closeQuietly(); releaseFrameHook(); }
                        return;
                    }
                    // Ended at its maximum duration with no stop request (the recording program may be
                    // gone): nothing should keep sampling the game or marking its frames.
                    if (!ProfileRecorder.running()) {
                        synchronized (ProfileControl.class) { ProfileRecorder.wrapUpIfEnded(); releaseFrameHook(); }
                        return;
                    }
                    Thread.sleep(100);
                }
            } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
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
