package zombie.characters;

import java.io.IOException;
import java.nio.file.*;
import zombie.GameWindow;
import zombie.ZomboidFileSystem;

public final class IsoPlayer {
    private static IsoPlayer instance = new IsoPlayer();
    public static int numPlayers = 1;
    public boolean dead;
    public static void die() { instance.dead = true; }
    public static void respawn() { instance = new IsoPlayer(); }
    public String haloText;
    private final SavedTable data = new SavedTable();
    public boolean isDead() { return dead; }
    public SavedTable getModData() { return data; }
    public SavedItem getPrimaryHandItem() { return new SavedItem(777); }
    public SavedItem getSecondaryHandItem() { return new SavedItem(888); }
    public static final class SavedItem {
        private final int id;
        SavedItem(int id) { this.id = id; }
        public int getID() { return id; }
    }
    public static final class SavedTable {
        private final java.util.HashMap<Object,Object> values = new java.util.HashMap<>();
        public Object rawget(Object key) { return values.get(key); }
        public void rawset(Object key, Object value) { values.put(key,value); }
    }

    public static IsoPlayer getInstance() { return instance; }

    public void setHaloNote(String text, int r, int g, int b, float duration) throws IOException {
        if (Thread.currentThread() != GameWindow.gameThread) throw new IOException("Wrong notification thread");
        if (GameWindow.mode.equals("notice-error")) throw new IOException("Synthetic notification failure");
        haloText = text;
        Files.writeString(Path.of(ZomboidFileSystem.instance.getCurrentSaveDir(), "notices.txt"),
            System.currentTimeMillis() + "\t" + text + "\t" + Thread.currentThread().getName() + "\n",
            StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }
}
