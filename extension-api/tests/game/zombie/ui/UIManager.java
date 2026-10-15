package zombie.ui;

/**
 * Synthetic: the moodle column of each local player, by player index; and the drawing of the interface, shaped as the game's:
 * its windows, then the tooltip (asked for twice: whether there is one, and to draw it).
 */
public final class UIManager {
    public static final MoodlesUI[] MoodleUI = new MoodlesUI[4];
    public static ObjectTooltip toolTip = new ObjectTooltip();
    public static boolean showPausedMessage = true;

    private UIManager() { }

    public static MoodlesUI getMoodleUI(double index) { return MoodleUI[(int)index]; }

    public static void setMoodleUI(double index, MoodlesUI column) { MoodleUI[(int)index] = column; }

    public static ObjectTooltip getToolTip() { return toolTip; }

    public static boolean isShowPausedMessage() { return showPausedMessage; }

    public static void setShowPausedMessage(boolean on) { showPausedMessage = on; }

    public static void render() {
        if (TextManager.record) TextManager.log("windows");
        if (getToolTip() != null) getToolTip().render();
        if (TextManager.record) TextManager.log("post");
    }
}
