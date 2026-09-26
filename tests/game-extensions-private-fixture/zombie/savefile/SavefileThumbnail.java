package zombie.savefile;
/** A render callback models an observable UI side effect; it is not the actual game UI. */
public final class SavefileThumbnail {
    public static int renders;
    public static Runnable onRender;
    public static void create() { renders++; if (onRender != null) onRender.run(); }
}
