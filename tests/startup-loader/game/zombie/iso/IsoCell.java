package zombie.iso;

import java.util.ArrayList;
import java.util.HashMap;
import zombie.characters.IsoZombie;

/** Synthetic: the loaded squares only, in their chunks. */
public final class IsoCell {
    public final HashMap<String, IsoGridSquare> squares = new HashMap<>();
    public final HashMap<String, IsoChunk> chunks = new HashMap<>();
    /** The zombies the cell holds. */
    public final ArrayList<IsoZombie> zombieList = new ArrayList<>();
    /** Set by a test: the cell cannot say its zombies. */
    public boolean brokenZombieList;
    // A dense index of the squares within a box, for the tests that load tens of thousands; none until asked for.
    private IsoGridSquare[] dense;
    private int denseSize, denseFloors;
    public ArrayList<IsoZombie> getZombieList() {
        if (brokenZombieList) throw new IllegalStateException("the zombie list is broken");
        return zombieList;
    }
    /** Squares from 0 up to size in x and y and floors in z are found without building a key. */
    public void dense(int size, int floors) { dense = new IsoGridSquare[size * size * floors]; denseSize = size; denseFloors = floors; }
    public IsoGridSquare getGridSquare(int x, int y, int z) {
        if (dense != null && x >= 0 && y >= 0 && z >= 0 && x < denseSize && y < denseSize && z < denseFloors)
            return dense[(z * denseSize + y) * denseSize + x];
        return squares.get(x + "," + y + "," + z);
    }
    public IsoChunk getChunk(int wx, int wy) { return chunks.get(wx + "," + wy); }
    public IsoGridSquare load(int x, int y, int z) {
        return squares.computeIfAbsent(x + "," + y + "," + z, ignored -> {
            var square = new IsoGridSquare(x, y, z);
            square.cell = this;
            if (dense != null && x >= 0 && y >= 0 && z >= 0 && x < denseSize && y < denseSize && z < denseFloors)
                dense[(z * denseSize + y) * denseSize + x] = square;
            int wx = Math.floorDiv(x, IsoChunk.SIZE), wy = Math.floorDiv(y, IsoChunk.SIZE);
            square.chunk = chunks.computeIfAbsent(wx + "," + wy, key -> new IsoChunk(wx, wy));
            return square;
        });
    }
}
