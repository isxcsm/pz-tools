package zombie.iso.fboRenderChunk;

import java.util.ArrayList;
import zombie.iso.IsoObject;

/**
 * Synthetic: the per-frame outline pass; the game draws an outlined object's sprite silhouette here. Its passes (behind
 * the player and not) go through the objects in their order; the objects drawn are noted, in order.
 */
public final class FBORenderObjectOutline {
    public static final FBORenderObjectOutline instance = new FBORenderObjectOutline();
    public int sprites;
    private final ArrayList<IsoObject> objectList = new ArrayList<>();
    public final ArrayList<IsoObject> drawn = new ArrayList<>();
    public void render(int player, IsoObject object) { renderObject(player, object); }

    /** The pass over these objects, as the game's over those it registered. */
    public void render(int player, java.util.List<IsoObject> objects) {
        objectList.clear();
        objectList.addAll(objects);
        drawn.clear();
        render(player, false);
    }

    private void render(int player, boolean behind) {
        for (IsoObject object : objectList) if (object.isOutlineHighlight(player)) renderObject(player, object);
    }

    private void renderObject(int player, IsoObject object) { sprites++; drawn.add(object); }
}
