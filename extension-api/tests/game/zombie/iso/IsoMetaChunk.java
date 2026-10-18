package zombie.iso;

/** Synthetic: a chunk of the map (8 by 8 squares), which has the zombie intensity the map gives it, 0 to 255. */
public final class IsoMetaChunk {
    private byte zombieIntensity;

    public void setZombieIntensity(byte value) { zombieIntensity = value; }

    public int getUnadjustedZombieIntensity() { return zombieIntensity & 0xFF; }
}
