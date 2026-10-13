package zombie.iso;

/** Synthetic: each local player's part of the screen, in the interface's pixels, as the test sets it. */
public final class IsoCamera {
    public static final int[] left = new int[4], top = new int[4], width = { 1600, 1600, 1600, 1600 }, height = { 900, 900, 900, 900 };

    /** The frame being drawn: here, for the player a test says. */
    public static final FrameState frameState = new FrameState();
    public static final class FrameState { public int playerIndex; }

    private IsoCamera() { }

    public static int getScreenLeft(int player) { return left[player]; }
    public static int getScreenTop(int player) { return top[player]; }
    public static int getScreenWidth(int player) { return width[player]; }
    public static int getScreenHeight(int player) { return height[player]; }
}
