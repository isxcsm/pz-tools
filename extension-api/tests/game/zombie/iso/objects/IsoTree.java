package zombie.iso.objects;

import zombie.characters.IsoGameCharacter;
import zombie.iso.IsoMovingObject;
import zombie.iso.IsoObject;

/** Synthetic: a tree slows whoever walks through it by its size, a ranger less. */
public class IsoTree extends IsoObject {
    public int size = 1;
    public IsoTree() { super(null); }

    public float getSlowFactor(IsoMovingObject mover) {
        float bonus = 1.0f;
        if (mover instanceof IsoGameCharacter character && character.ranger) bonus = 1.5f;
        if (size == 1 || size == 2) return 0.8f * bonus;
        if (size == 3 || size == 4) return 0.5f * bonus;
        return bonus;
    }
}
