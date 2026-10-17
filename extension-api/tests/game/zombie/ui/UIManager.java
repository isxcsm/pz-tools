package zombie.ui;

/**
 * Synthetic: the moodle column of each local player, by player index; and the drawing of the interface, shaped as the game's:
 * its windows, then the tooltip (asked for twice: whether there is one, and to draw it), then ("post") the paused message and
 * the black over each player's screen; the black's strength on each.
 */
public final class UIManager {
    public static final MoodlesUI[] MoodleUI = new MoodlesUI[4];
    public static ObjectTooltip toolTip = new ObjectTooltip();
    /** The black over each player's screen (sleep fades it to 1). */
    public static final float[] fade = new float[4];

    private UIManager() { }

    public static float getFadeAlpha(double player) { return fade[(int)player]; }

    public static MoodlesUI getMoodleUI(double index) { return MoodleUI[(int)index]; }

    public static void setMoodleUI(double index, MoodlesUI column) { MoodleUI[(int)index] = column; }

    public static ObjectTooltip getToolTip() { return toolTip; }

    public static void render() {
        if (TextManager.record) TextManager.log("windows");
        if (getToolTip() != null) getToolTip().render();
        if (TextManager.record) TextManager.log("post");
    }
}
