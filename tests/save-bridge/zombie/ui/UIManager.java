package zombie.ui;
/** Synthetic getter for runtime observation tests. */
public final class UIManager {
    private static final SpeedControls controls = new SpeedControls();
    public static SpeedControls getSpeedControls() { return controls; }
}
