package zombie.iso;

/** Synthetic: what the map has of a cell once its data is read (a cell with none has no header): the zombie intensity of its chunks. */
public final class LotHeader {
    // 32 by 32 chunks, row by row.
    final byte[] zombieIntensity = new byte[1024];

    public void setZombieIntensity(int chunk, byte value) { zombieIntensity[chunk] = value; }

    /** As the game's: the intensity the map gives the chunk, or -1 for a cell with no header or a chunk outside it. */
    public static int getZombieIntensityForChunk(LotHeader header, int x, int y) {
        if (x < 0 || y < 0 || x >= 32 || y >= 32 || header == null) return -1;
        return header.zombieIntensity[y * 32 + x] & 0xFF;
    }
}
