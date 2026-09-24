package zombie.characters;

import java.io.IOException;
import java.nio.file.*;
import zombie.GameWindow;
import zombie.ZomboidFileSystem;

public final class IsoPlayer {
    private static final IsoPlayer instance = new IsoPlayer();
    public String haloText;

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
