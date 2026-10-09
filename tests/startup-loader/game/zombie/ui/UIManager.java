package zombie.ui;

/** Synthetic: the moodle column of each local player, by player index. */
public final class UIManager {
    public static final MoodlesUI[] MoodleUI = new MoodlesUI[4];

    private UIManager() { }

    public static MoodlesUI getMoodleUI(double index) { return MoodleUI[(int)index]; }

    public static void setMoodleUI(double index, MoodlesUI column) { MoodleUI[(int)index] = column; }
}
