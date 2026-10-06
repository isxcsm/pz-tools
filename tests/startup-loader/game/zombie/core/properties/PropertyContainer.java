package zombie.core.properties;

import java.util.EnumSet;
import zombie.iso.SpriteDetails.IsoFlagType;

/** Synthetic. */
public final class PropertyContainer {
    public final EnumSet<IsoFlagType> flags = EnumSet.noneOf(IsoFlagType.class);
    public boolean has(IsoFlagType flag) { return flags.contains(flag); }
}
