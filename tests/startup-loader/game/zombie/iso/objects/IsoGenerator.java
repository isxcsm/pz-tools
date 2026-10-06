package zombie.iso.objects;

import java.util.HashMap;
import zombie.iso.IsoChunk;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.sprite.IsoSprite;

/** Synthetic: like the game's, a running generator powers the squares within its radius, through their chunks. */
public class IsoGenerator extends IsoObject {
    private static final float GeneratorBasePowerConsumption = 0.02f;
    private static int generatorChunkRange = 1;
    private static int generatorRadius = 4;
    public static int updates;
    public float fuel = 10;
    public boolean activated;
    public int condition = 100;
    private final HashMap<String, String> itemsPowered = new HashMap<>();
    private float totalPowerUsing;
    public IsoGenerator(IsoSprite sprite) { super(sprite); }
    public boolean isActivated() { return activated; }
    public float getFuel() { return fuel; }
    public int getCondition() { return condition; }
    public float getTotalPowerUsing() { return totalPowerUsing; }
    public void setTotalPowerUsing(float value) { totalPowerUsing = value; }
    public int itemsPowered() { return itemsPowered.size(); }
    public void setActivated(boolean on) {
        if (on == activated) return;
        activated = on;
        setSurroundingElectricity();
    }
    public void setSurroundingElectricity() {
        itemsPowered.clear();
        totalPowerUsing = GeneratorBasePowerConsumption;
        IsoGridSquare at = getSquare();
        if (at == null || at.chunk == null) return;
        for (int dx = -generatorChunkRange; dx <= generatorChunkRange; dx++)
            for (int dy = -generatorChunkRange; dy <= generatorChunkRange; dy++) {
                IsoChunk chunk = IsoWorld.instance.getCell().getChunk(at.chunk.wx + dx, at.chunk.wy + dy);
                if (chunk == null) continue;
                if (activated) chunk.addGeneratorPos(at.x, at.y, at.z);
                else chunk.removeGeneratorPos(at.x, at.y, at.z);
            }
        itemsPowered.put("vanilla", "range");
    }
    /** Something that uses power changed on the square. */
    public static void updateGenerator(IsoGridSquare square) {
        if (square == null) return;
        updates++;
    }
    public static boolean isPoweringSquare(int generatorX, int generatorY, int generatorZ, int x, int y, int z) {
        int dx = x - generatorX, dy = y - generatorY;
        return z == generatorZ && dx * dx + dy * dy <= generatorRadius * generatorRadius;
    }
}
