package zombie.core.opengl;

import zombie.ui.TextManager;

/** Synthetic: the game's distance-field text shader; its uniforms' updates are recorded with the text drawn. */
public class SDFShader extends Shader {
    public void updateThreshold(float threshold) { if (TextManager.record) TextManager.log("threshold", threshold); }
    public void updateShadow(float shadow) { if (TextManager.record) TextManager.log("shadow", shadow); }
    public void updateOutline(float thick, float r, float g, float b, float a) { if (TextManager.record) TextManager.log("outline", thick, r, g, b, a); }
}
