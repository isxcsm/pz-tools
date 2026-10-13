package zombie.core.skinnedmodel.model;

import java.util.HashSet;
import java.util.Set;
import zombie.iso.IsoObject;

/** Synthetic: the objects whose model animates (a door opening). */
public final class IsoObjectAnimations {
    private static final IsoObjectAnimations INSTANCE = new IsoObjectAnimations();
    public final Set<IsoObject> animating = new HashSet<>();
    public static IsoObjectAnimations getInstance() { return INSTANCE; }
    public Object getAnimationPlayer(IsoObject object) { return animating.contains(object) ? object : null; }
}
