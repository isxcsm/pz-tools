package zombie.core.skinnedmodel.model;

import java.util.ArrayList;
import zombie.core.skinnedmodel.ModelManager;
import zombie.core.skinnedmodel.shader.Shader;
import zombie.core.textures.ColorInfo;
import zombie.iso.IsoMovingObject;

/** Synthetic: what a model slot draws this frame, filled on the main thread, drawn on the render thread. */
public final class ModelSlotRenderData {
    public static Shader solidColor, solidColorStatic;
    private int playerIndex;
    private float camCharacterX, camCharacterY;
    public IsoMovingObject object;
    public final ArrayList<ModelInstanceRenderData> modelData = new ArrayList<>();
    public float x, y;
    public boolean renderToTexture;
    private boolean characterOutline;
    private final ColorInfo outlineColor = new ColorInfo();
    private boolean outlineBehindPlayer;
    public int vehicleDraws;
    /** Like the game's for a vehicle: its light, read from the square it stands on (a test sets it). */
    public final ColorInfo ambient = new ColorInfo();
    public zombie.iso.IsoGridSquare lightSquare;

    public void initModel(ModelManager.ModelSlot slot) {
        object = slot.object;
        playerIndex = slot.player;
        x = slot.x; y = slot.y;
        camCharacterX = slot.cameraX; camCharacterY = slot.cameraY;
        characterOutline = false;
        if (lightSquare != null) lightSquare.interpolateLight(ambient, 0.25f, 0.75f);
        if (object == null) return;
    }

    public void render() { renderVehicle(); }
    private void renderVehicle() { vehicleDraws++; }

    public boolean outlined() { return characterOutline; }
    public boolean behind() { return outlineBehindPlayer; }
    public ColorInfo outlineColour() { return outlineColor; }
}
