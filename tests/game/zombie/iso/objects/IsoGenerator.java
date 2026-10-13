package zombie.iso.objects;

import java.util.HashMap;
import zombie.GameTime;
import zombie.SandboxOptions;
import zombie.iso.IsoChunk;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.sprite.IsoSprite;

/**
 * Synthetic: like the game's, a running generator powers the squares within its radius, through their chunks, and burns
 * fuel hour by hour when it updates.
 */
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
    private int lastHour;
    public IsoGenerator(IsoSprite sprite) { super(sprite); }
    public boolean isActivated() { return activated; }
    public float getFuel() { return fuel; }
    public int getCondition() { return condition; }
    public void setFuel(float value) { fuel = Math.max(0, value); }
    public void setCondition(int value) { condition = Math.max(0, Math.min(100, value)); }
    /** The item it is picked up as, whose script gives its wear (ScriptManager). */
    public String itemType = "Base.Generator";
    public String getGeneratorItemType() { return itemType; }
    // Like the game's: scaled by the sandbox's generator fuel rate.
    public float getTotalPowerUsing() { return (float)(totalPowerUsing * SandboxOptions.instance.generatorFuelConsumption.getValue()); }
    public int consumptionSets;
    public void setTotalPowerUsing(float value) { totalPowerUsing = value; consumptionSets++; }
    public int itemsPowered() { return itemsPowered.size(); }
    public int lastHour() { return lastHour; }
    public void setActivated(boolean on) {
        if (on == activated) return;
        if (on) lastHour = (int)GameTime.getInstance().getWorldAgeHours();
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
    /** Like the game's: burns the hours since it last did, and stops in the hour its fuel runs out. */
    public void update() {
        if (!activated) return;
        int now = (int)GameTime.getInstance().getWorldAgeHours();
        if (now == lastHour) return;
        float burned = 0;
        for (int hour = 0; hour < now - lastHour; hour++) {
            burned += getTotalPowerUsing();
            if (fuel - burned <= 0) break;
        }
        fuel -= burned;
        if (fuel <= 0) { setActivated(false); fuel = 0; }
        lastHour = now;
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
