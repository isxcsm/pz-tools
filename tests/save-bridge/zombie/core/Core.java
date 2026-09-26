package zombie.core;
public final class Core {
    public static boolean exiting;
    private static final Core instance = new Core();
    public static Core getInstance() { return instance; }
    public boolean isNoSave() { return zombie.GameWindow.mode.equals("no-save"); }
    public String getGameMode() { return "Sandbox"; }
}
