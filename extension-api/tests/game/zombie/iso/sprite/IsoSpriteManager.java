package zombie.iso.sprite;

import java.util.HashMap;

/** Synthetic: the sprites the game knows by name, as a test adds them. */
public final class IsoSpriteManager {
    public static final IsoSpriteManager instance = new IsoSpriteManager();
    public final HashMap<String, IsoSprite> namedMap = new HashMap<>();
}
