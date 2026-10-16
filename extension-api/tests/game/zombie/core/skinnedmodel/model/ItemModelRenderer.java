package zombie.core.skinnedmodel.model;

import zombie.core.ImmutableColor;
import zombie.core.textures.ColorInfo;
import zombie.inventory.InventoryItem;
import zombie.iso.IsoGridSquare;
import zombie.scripting.objects.ModelScript;

/**
 * Synthetic: an item drawn as a model (on the ground, in the world), lit by the square it stands on as the game's does: its light
 * is read from the square's corners where the model is, and becomes the model's ambient colour.
 */
public final class ItemModelRenderer {
    private static final ColorInfo tempColorInfo = new ColorInfo();
    public float x, y, z;
    /** The light the item was drawn with, as the game takes it for the model's ambient colour. */
    public float ambientR, ambientG, ambientB;

    /** The game's {@code renderMain}, which makes the model and sets the renderer up with {@code init}. */
    public void renderMain(InventoryItem item, IsoGridSquare square, IsoGridSquare lightSquare, float x, float y, float z) {
        init(item, square, lightSquare, x, y, z, new Model(), null, 1f, null, 1f, false, false);
    }

    private void init(InventoryItem item, IsoGridSquare square, IsoGridSquare lightSquare, float x, float y, float z, Model model,
            ModelScript script, float scale, ImmutableColor tint, float alpha, boolean flip, boolean mirror) {
        this.x = x;
        this.y = y;
        this.z = z;
        square.interpolateLight(tempColorInfo, this.x % 1f, this.y % 1f);
        ambientR = tempColorInfo.r;
        ambientG = tempColorInfo.g;
        ambientB = tempColorInfo.b;
    }
}
