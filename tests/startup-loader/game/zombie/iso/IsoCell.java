package zombie.iso;

import java.util.HashMap;

/** Synthetic: the loaded squares only, in their chunks. */
public final class IsoCell {
    public final HashMap<String, IsoGridSquare> squares = new HashMap<>();
    public final HashMap<String, IsoChunk> chunks = new HashMap<>();
    public IsoGridSquare getGridSquare(int x, int y, int z) { return squares.get(x + "," + y + "," + z); }
    public IsoChunk getChunk(int wx, int wy) { return chunks.get(wx + "," + wy); }
    public IsoGridSquare load(int x, int y, int z) {
        return squares.computeIfAbsent(x + "," + y + "," + z, ignored -> {
            var square = new IsoGridSquare(x, y, z);
            int wx = Math.floorDiv(x, IsoChunk.SIZE), wy = Math.floorDiv(y, IsoChunk.SIZE);
            square.chunk = chunks.computeIfAbsent(wx + "," + wy, key -> new IsoChunk(wx, wy));
            return square;
        });
    }
}
