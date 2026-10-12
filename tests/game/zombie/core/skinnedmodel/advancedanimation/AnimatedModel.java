package zombie.core.skinnedmodel.advancedanimation;

import java.nio.FloatBuffer;
import zombie.core.skinnedmodel.model.Model;

/** Synthetic. */
public class AnimatedModel {
    /** One model of what is drawn, and its bones (none for a static model). */
    public static class AnimatedModelInstanceRenderData {
        public Model model;
        public FloatBuffer matrixPalette;
    }
}
