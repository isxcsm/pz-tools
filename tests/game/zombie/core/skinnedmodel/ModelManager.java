package zombie.core.skinnedmodel;

import zombie.iso.IsoMovingObject;

/** Synthetic. */
public final class ModelManager {
    /** What a model is drawn for: here, the object, the player and where it and the camera's character stand. */
    public static final class ModelSlot {
        public IsoMovingObject object;
        public int player;
        public float x, y, cameraX, cameraY;
    }
}
