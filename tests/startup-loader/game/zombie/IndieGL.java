package zombie;

import zombie.core.opengl.Shader;
import zombie.ui.TextManager;

/** Synthetic: the game's GL state calls; a shader started and ended is recorded with the text drawn. */
public final class IndieGL {
    private IndieGL() { }

    public static void StartShader(Shader shader) { if (TextManager.record) TextManager.log("start", shader); }
    public static void EndShader() { if (TextManager.record) TextManager.log("end"); }
}
