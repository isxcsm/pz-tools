package pztools.bridge.runtime;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.Base64;
import pztools.bridge.AgentEntry;

import static pztools.bridge.runtime.Replies.error;
import static pztools.bridge.runtime.Replies.ok;

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
    // The same for the recording asked for, which otherwise runs to its maximum (up to half an hour) after its app went.
    private static String recordOwner;
    // Whether the rolling recording marks frames, said again with each save.
    private static String rollingFrames = "frames";
    private ProfileControl() { }

    static boolean handles(String command) { return command.startsWith("PROFILE_"); }

    static synchronized String handle(String[] command) {
        try {
            switch (command[0]) {
                case "PROFILE_START" -> {
                    // Optional last: the app run whose lease the recording follows, as the rolling one does.
                    if (command.length < 4 || command.length > 5 || !(command[2].equals("general") || command[2].equals("detailed")))
                        return error("protocol", "Invalid profile start request");
                    String owner = command.length == 5 ? command[4] : null;
                    if (owner != null && !Leases.validApp(owner)) return error("protocol", "Invalid app run");
                    if (owner != null) Leases.renewApp(owner);
                    Path destination = path(command[1]);
                    int seconds = Integer.parseInt(command[3]);
                    Hook hook = hookFrames();
                    String status = ProfileRecorder.start(destination, command[2].equals("detailed"), seconds, hook.game());
                    recordOwner = owner;
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
                    releaseFramesIfIdle();
                    return ok(status);
                }
                case "PROFILE_STOP" -> {
                    if (command.length != 1) return error("protocol", "Invalid profile stop request");
                    recordOwner = null;
                    String status = ProfileRecorder.stop();
                    // A rolling recording may still mark frames.
                    releaseFramesIfIdle();
                    return ok(status);
                }
                case "PROFILE_STATUS" -> {
                    if (command.length != 1) return error("protocol", "Invalid profile status request");
                    return ok(ProfileRecorder.status());
                }
                default -> { return error("protocol", "Unknown profile request"); }
            }
        } catch (IllegalStateException state) {
            releaseFramesIfIdle();
            return error(String.valueOf(state.getMessage()), "Profile recorder state: " + state.getMessage());
        } catch (Throwable failure) {
            releaseFramesIfIdle();
            return error("profile-failed", failure.getClass().getSimpleName() + (failure.getMessage() == null ? "" : ": " + failure.getMessage()));
        }
    }

    private record Hook(ClassLoader game, String frames) { }

    /**
     * Frame boundaries come from the game-loop hook, through the frame router's profiler job, held while a recording
     * runs. If it cannot be installed the recording still runs; it just has no frame graph.
     */
    private static Hook hookFrames() {
        String frames = "frames";
        ClassLoader game = null;
        try {
            Class<?> window = AgentEntry.ensureGameHook();
            game = window.getClassLoader();
            if (!Frames.add(Frames.Job.PROFILE, ProfileFrames.class, ProfileFrames::tick)) frames = "no-frames";
        } catch (Exception | LinkageError unavailable) { frames = "no-frames"; }
        return new Hook(game == null ? ClassLoader.getSystemClassLoader() : game, frames);
    }

    private static Path path(String encoded) { return Path.of(new String(Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8)); }

    private static void releaseFrameHook() { Frames.remove(Frames.Job.PROFILE, ProfileFrames.class); }

    /** Gives back the profiler job unless a recording runs: after a stop, or a start that failed. */
    private static void releaseFramesIfIdle() {
        boolean active;
        try { active = ProfileRecorder.active(); }
        catch (Throwable unavailable) { active = false; } // The recorder cannot even load: nothing records.
        if (!active) releaseFrameHook();
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
                        // The recording asked for, by an app that has gone: no one will stop it or take its file.
                        if (recordOwner != null && !Leases.appHolds(recordOwner)) {
                            recordOwner = null;
                            // Ended already (at its maximum), or failing to stop: either way nothing more to do here.
                            try { ProfileRecorder.stop(); } catch (Exception ended) { }
                        }
                        if (!ProfileRecorder.active()) {
                            releaseFrameHook();
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
}
