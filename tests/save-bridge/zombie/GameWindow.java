package zombie;

import java.nio.file.*;
import java.io.IOException;

/** Synthetic target JVM. No game data or game libraries are used. */
public final class GameWindow {
    public static Thread gameThread;
    public static States states = new States();
    public static String mode;
    public static long ticks;
    private static int memoryOnlyState;
    public static final class States { public Object current = new zombie.gameStates.IngameState(); }

    public static boolean isIngameState() { return states.current instanceof zombie.gameStates.IngameState; }
    private static void logic() { ticks++; }

    public static void save(boolean flag) throws IOException {
        if (Thread.currentThread() != gameThread || !flag) throw new IOException("Wrong save invocation");
        if (mode.equals("throw")) throw new IOException("Synthetic save failure");
        var stamp = zombie.characters.IsoPlayer.getInstance().getModData();
        Files.writeString(Path.of(ZomboidFileSystem.instance.getCurrentSaveDir(), "recovery-stamp.txt"),
            stamp.rawget("pztools.recovery.id") + "\n" + stamp.rawget("pztools.recovery.primary") + "\n" + stamp.rawget("pztools.recovery.secondary"));
        Files.writeString(Path.of(ZomboidFileSystem.instance.getCurrentSaveDir(), "memory-only-state.txt"),
            Integer.toString(++memoryOnlyState));
        Files.writeString(Path.of(ZomboidFileSystem.instance.getCurrentSaveDir(), "calls.txt"),
            Thread.currentThread().getName() + "\n", StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        Files.writeString(Path.of(ZomboidFileSystem.instance.getCurrentSaveDir(), "save-ticks.txt"), Long.toString(ticks));
        Files.writeString(Path.of(ZomboidFileSystem.instance.getCurrentSaveDir(), "save-time.txt"), Long.toString(System.currentTimeMillis()));
    }

    private static boolean consumeSignal(Path path) {
        try { return Files.deleteIfExists(path); }
        // The .NET writer may still hold a Windows sharing lock on a test signal.
        // Retry next frame instead of terminating the synthetic game process.
        catch (IOException transientSignalWrite) { return false; }
    }

    public static void main(String[] args) throws Exception {
        ZomboidFileSystem.path = args[0];
        mode = args.length > 1 ? args[1] : "normal";
        if (mode.equals("menu")) states.current = new Object();
        if (mode.equals("dead-at-start")) zombie.characters.IsoPlayer.die();
        if (mode.equals("multiplayer")) zombie.network.GameClient.client = true;
        gameThread = Thread.currentThread();
        gameThread.setName("Synthetic-game-thread");
        // Resolve all guard classes before attaching, as the real game does.
        new zombie.iso.IsoWorld();
        zombie.core.Core.getInstance();
        System.out.println("READY");
        System.out.flush();
        while (true) {
            if (consumeSignal(Path.of(args[0], "die-player"))) zombie.characters.IsoPlayer.die();
            if (consumeSignal(Path.of(args[0], "respawn-player"))) zombie.characters.IsoPlayer.respawn();
            if (consumeSignal(Path.of(args[0], "ambiguous-players"))) zombie.characters.IsoPlayer.numPlayers = 2;
            if (consumeSignal(Path.of(args[0], "single-player"))) zombie.characters.IsoPlayer.numPlayers = 1;
            if (consumeSignal(Path.of(args[0], "fail-save"))) mode = "throw";
            if (consumeSignal(Path.of(args[0], "sleep-player"))) zombie.characters.IsoPlayer.getInstance().asleep = true;
            if (consumeSignal(Path.of(args[0], "wake-player"))) zombie.characters.IsoPlayer.getInstance().asleep = false;
            if (consumeSignal(Path.of(args[0], "pause-game"))) zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(0);
            if (consumeSignal(Path.of(args[0], "resume-game"))) zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(1);
            if (consumeSignal(Path.of(args[0], "fast-game"))) zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(4);
            if (consumeSignal(Path.of(args[0], "inspect-hook")))
                bridgefixture.Inspector.inspect(Path.of(args[0], "hook-state.txt"));
            if (consumeSignal(Path.of(args[0], "inspect-control"))) {
                String endpoint = System.getProperty("pztools.bridge.control.v1", "");
                Path staged = Path.of(args[0], "control-state.tmp");
                Files.writeString(staged, endpoint);
                Files.move(staged, Path.of(args[0], "control-state.txt"), StandardCopyOption.REPLACE_EXISTING);
            }
            if (Files.exists(Path.of(args[0], "leave-world"))) states.current = new Object();
            if (!mode.equals("stalled") || Files.exists(Path.of(args[0], "resume"))) logic();
            Thread.sleep(20);
        }
    }
}
