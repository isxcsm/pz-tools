package zombie.ui;

import java.nio.file.*;

/** Synthetic getter for runtime observation tests, and the game's Lua debugger. */
public final class UIManager {
    private static final SpeedControls controls = new SpeedControls();
    public static SpeedControls getSpeedControls() { return controls; }

    /**
     * Like the game's: a Lua error with Break On Error on stops the game thread here, in a loop that draws only the
     * debugger, until the player resumes. The fixture's signal directory stands in for the Lua file.
     */
    public static void debugBreakpoint(String file, long line) throws InterruptedException {
        while (Files.exists(Path.of(file, "hold-debugger"))) Thread.sleep(20);
    }
}
