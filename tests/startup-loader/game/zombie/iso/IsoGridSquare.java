package zombie.iso;

import java.util.ArrayList;

/** Synthetic. The game's list type is its own, a java.util.List. */
public final class IsoGridSquare {
    public final ArrayList<IsoObject> objects = new ArrayList<>();
    public ArrayList<IsoObject> getObjects() { return objects; }
}
