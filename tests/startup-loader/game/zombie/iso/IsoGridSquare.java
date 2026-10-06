package zombie.iso;

import zombie.iso.objects.IsoGenerator;
import zombie.util.list.PZArrayList;

/** Synthetic: like the game's, a square has generator power when a generator's range in its chunk covers it. */
public final class IsoGridSquare {
    public int x, y, z;
    public IsoChunk chunk;
    public final PZArrayList<IsoObject> objects = new PZArrayList<>();
    public IsoGridSquare(int x, int y, int z) { this.x = x; this.y = y; this.z = z; }
    public PZArrayList<IsoObject> getObjects() { return objects; }
    public IsoGenerator getGenerator() {
        for (int index = 0; index < objects.size(); index++) if (objects.get(index) instanceof IsoGenerator generator) return generator;
        return null;
    }
    public boolean haveElectricity() { return chunk != null && chunk.isGeneratorPoweringSquare(x, y, z); }
}
