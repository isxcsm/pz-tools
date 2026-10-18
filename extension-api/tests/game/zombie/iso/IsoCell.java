package zombie.iso;

import java.util.ArrayList;
import java.util.HashMap;
import zombie.characters.IsoZombie;

/** Synthetic: the loaded squares only, in their chunks. */
public final class IsoCell {
    /** Like the game's: the floor squares of the chunk level being drawn, in the order they are drawn. */
    public static final ArrayList<IsoGridSquare> SolidFloor = new ArrayList<>();

    /** Synthetic: what the game draws a player's view with; here nothing. */
    public static final class PerPlayerRender { }

    public final PositionMap<IsoGridSquare> squares = new PositionMap<>();
    public final PositionMap<IsoChunk> chunks = new PositionMap<>();
    /** The vehicles of the cell. */
    public final java.util.Set<zombie.vehicles.BaseVehicle> vehicles = new java.util.LinkedHashSet<>();
    public java.util.Set<zombie.vehicles.BaseVehicle> getVehicles() { return vehicles; }
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
        return squares.at(x, y, z);
    }
    public IsoChunk getChunk(int wx, int wy) { return chunks.at(wx, wy); }
    public IsoGridSquare load(int x, int y, int z) {
        IsoGridSquare known = squares.at(x, y, z);
        if (known != null) return known;
        return squares.computeIfAbsent(x + "," + y + "," + z, ignored -> {
            var square = new IsoGridSquare(x, y, z);
            square.cell = this;
            if (dense != null && x >= 0 && y >= 0 && z >= 0 && x < denseSize && y < denseSize && z < denseFloors)
                dense[(z * denseSize + y) * denseSize + x] = square;
            int wx = Math.floorDiv(x, IsoChunk.SIZE), wy = Math.floorDiv(y, IsoChunk.SIZE);
            IsoChunk held = chunks.at(wx, wy);
            square.chunk = held != null ? held : chunks.computeIfAbsent(wx + "," + wy, key -> {
                var chunk = new IsoChunk(wx, wy);
                chunk.cell = this;
                return chunk;
            });
            return square;
        });
    }
}
