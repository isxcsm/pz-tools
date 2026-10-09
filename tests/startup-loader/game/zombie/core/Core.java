package zombie.core;

/** Synthetic: the screen's height. */
public final class Core {
    private static final Core INSTANCE = new Core();
    public static Core getInstance() { return INSTANCE; }
    public int getScreenHeight() { return 1000; }
}
