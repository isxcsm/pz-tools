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
    private ProfileControl() { }

    static boolean handles(String command) { return command.startsWith("PROFILE_"); }

    static synchronized String handle(String[] command) {
        try {
            switch (command[0]) {
                case "PROFILE_START" -> {
                    if (command.length != 4 || !(command[2].equals("general") || command[2].equals("detailed")))
                        return error("protocol", "Invalid profile start request");
                    Path destination = Path.of(new String(Base64.getDecoder().decode(command[1]), StandardCharsets.UTF_8));
                    int seconds = Integer.parseInt(command[3]);
                    // Frame boundaries come from the game-loop hook. If it cannot be installed the
                    // recording still runs; it just has no frame graph.
                    String frames = "frames";
                    ClassLoader game = null;
                    try {
                        Class<?> window = AgentEntry.ensureGameHook();
                        game = window.getClassLoader();
                        if (!RuntimeObserver.running()) { AgentEntry.observe(ProfileRecorder::frame); ownsFrameHook = true; }
                    } catch (Exception | LinkageError unavailable) { frames = "no-frames"; }
                    if (game == null) game = ClassLoader.getSystemClassLoader();
                    String status = ProfileRecorder.start(destination, command[2].equals("detailed"), seconds, game);
                    startMonitor();
                    return ok(status + ";" + frames);
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

    /** RuntimeObserver took over or gave up the per-frame slot; keep frame marks flowing either way. */
    static synchronized void observerStopped() {
        if (ProfileRecorder.active()) { AgentEntry.observe(ProfileRecorder::frame); ownsFrameHook = true; }
    }

    private static void releaseFrameHook() {
        if (ownsFrameHook && !RuntimeObserver.running()) AgentEntry.observe(null);
        ownsFrameHook = false;
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
                    Thread.sleep(100);
                }
            } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }, "PzTools-profile-monitor");
        monitor.setDaemon(true);
        monitor.start();
    }

    private static String ok(String detail) { return "OK\t" + encode(detail); }
    private static String error(String code, String message) {
        return "ERROR\t" + code.replace('\t', ' ') + "\t" + encode(message.length() > 400 ? message.substring(0, 400) : message);
    }
    private static String encode(String value) { return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)); }
}
