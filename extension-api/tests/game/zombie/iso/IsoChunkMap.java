package zombie.iso;

/**
 * Synthetic: how many chunks wide the loaded area is, and how many squares wide a chunk; a player's chunks, from the chunk at its
 * corner (the cell's lowest).
 */
public final class IsoChunkMap {
    public static final int CHUNK_SIZE_IN_SQUARES = 8;
    public static int chunkGridWidth = 13;
    private final IsoCell cell;
    public final int minX, minY, width, height;

    public IsoChunkMap(IsoCell cell) {
        this.cell = cell;
        int x0 = Integer.MAX_VALUE, y0 = Integer.MAX_VALUE, x1 = Integer.MIN_VALUE, y1 = Integer.MIN_VALUE;
        for (IsoChunk chunk : cell.chunks.values()) {
            x0 = Math.min(x0, chunk.wx); y0 = Math.min(y0, chunk.wy);
            x1 = Math.max(x1, chunk.wx); y1 = Math.max(y1, chunk.wy);
        }
        minX = x0; minY = y0;
        width = x1 < x0 ? 0 : x1 - x0 + 1;
        height = y1 < y0 ? 0 : y1 - y0 + 1;
    }

    /** As the game's: the chunk at x, y of the map's grid, or null. */
    public IsoChunk getChunk(int x, int y) { return cell.getChunk(minX + x, minY + y); }
}
