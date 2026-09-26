package zombie.core;
public final class Core {
    private static final Core instance = new Core();
    public static Core getInstance() { return instance; }
    public boolean isNoSave() { return false; }
}
