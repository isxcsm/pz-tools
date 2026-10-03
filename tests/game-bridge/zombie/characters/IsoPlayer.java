package zombie.characters;

import java.io.IOException;
import java.nio.file.*;
import zombie.GameWindow;
import zombie.ZomboidFileSystem;

public final class IsoPlayer {
    private static int nextId;
    private static IsoPlayer instance = new IsoPlayer();
    private final int id = ++nextId;
    public static int numPlayers = 1;
    public boolean dead;
    public boolean asleep;
    public boolean isAsleep() { return asleep; }
    public static void die() { instance.dead = true; }
    public static void respawn() { instance = new IsoPlayer(); }
    public String haloText;
    private float haloTimer;
    private int expiredSavingNotes;
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
    public float getHaloTimerCount() { return haloTimer; }

    public static void tickHalo() {
        if (instance.haloTimer <= 0) return;
        // Real halo clocks decrement 1.25 * GameTime multiplier per update.
        instance.haloTimer = Math.max(0, instance.haloTimer - 1.25f
            * (zombie.ui.UIManager.getSpeedControls().getCurrentGameSpeed() == 4 ? 20 : 1));
        if (instance.haloTimer == 0 && "Saving".equals(instance.haloText)) instance.expiredSavingNotes++;
    }

    public static void inspectHalo(Path path) throws IOException {
        Files.writeString(path, instance.haloText + "\n"
            + instance.haloTimer + "\n" + instance.id + "\n" + instance.expiredSavingNotes);
    }

    public void setHaloNote(String text, int r, int g, int b, float duration) throws IOException {
        if (Thread.currentThread() != GameWindow.gameThread) throw new IOException("Wrong notification thread");
        if (GameWindow.mode.equals("notice-error")) throw new IOException("Synthetic notification failure");
        haloText = text;
        haloTimer = duration;
        Files.writeString(Path.of(ZomboidFileSystem.instance.getCurrentSaveDir(), "notices.txt"),
            System.currentTimeMillis() + "\t" + text + "\t" + Thread.currentThread().getName()
                + "\t" + duration + "\t" + id + "\t" + (this == instance ? "current" : "stale") + "\n",
            StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }
}
