package zombie.iso;

import java.util.HashMap;

/** Synthetic: the loaded squares only. */
public final class IsoCell {
    public final HashMap<String, IsoGridSquare> squares = new HashMap<>();
    public IsoGridSquare getGridSquare(int x, int y, int z) { return squares.get(x + "," + y + "," + z); }
    public IsoGridSquare load(int x, int y, int z) { return squares.computeIfAbsent(x + "," + y + "," + z, ignored -> new IsoGridSquare()); }
}
