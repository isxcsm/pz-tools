package zombie;
import java.io.*;
public final class GameWindow {
    public static Runnable onSave;
    private static int before, after;
    public static boolean fail;
    public static int[] stages() { return new int[] {before, after}; }
    public static void save(boolean full) throws IOException {
        if (!full) throw new IOException("Full save required");
        before++;
        if (onSave != null) onSave.run();
        zombie.savefile.SavefileThumbnail.create();
        try (var out = new DataOutputStream(new ByteArrayOutputStream())) {
            zombie.iso.IsoWorld.instance.currentCell.save(out, full);
        }
        zombie.MapCollisionData.instance.save();
        if (fail) throw new IOException("Synthetic original save failure");
        after++;
    }
}
