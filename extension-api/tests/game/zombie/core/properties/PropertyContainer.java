package zombie.core.properties;

import java.util.EnumSet;
import zombie.iso.SpriteDetails.IsoFlagType;

/** Synthetic. */
public final class PropertyContainer {
    public final EnumSet<IsoFlagType> flags = EnumSet.noneOf(IsoFlagType.class);
    public boolean has(IsoFlagType flag) { return flags.contains(flag); }
    /** The sprite properties by name, with their values. */
    public final java.util.Map<String, String> named = new java.util.HashMap<>();
    public boolean has(String name) { return named.containsKey(name); }
    public String get(String name) { return named.get(name); }
    public int surface = -1;
    public boolean isSurfaceOffset() { return surface >= 0; }
    public int getSurface() { return Math.max(0, surface); }
}
