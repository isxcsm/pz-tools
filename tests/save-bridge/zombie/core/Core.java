package zombie.core;
public final class Core {
    private static final Core instance = new Core();
    public static Core getInstance() { return instance; }
    public boolean isNoSave() { return zombie.GameWindow.mode.equals("no-save"); }
    public String getGameMode() { return "Sandbox"; }
}
