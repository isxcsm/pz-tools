package zombie.tileDepth;

import org.lwjgl.opengl.GL20;
import zombie.core.opengl.Shader;
import zombie.core.textures.TextureDraw;

/** Synthetic: a tile shader, as the game's: its uniforms set each time it starts drawing. */
public class CutawayAttachedShader extends Shader {
    @Override public int getID() { return 9; }

    public void startRenderThread(TextureDraw draw) {
        GL20.glUniform1i(GL20.glGetUniformLocation(getID(), "DIFFUSE"), 0);
    }
}
