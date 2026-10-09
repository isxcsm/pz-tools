package zombie.iso.weather;

import org.lwjgl.opengl.GL20;
import zombie.core.opengl.Shader;
import zombie.core.opengl.ShaderProgram;
import zombie.core.textures.TextureDraw;

/** Synthetic: the screen pass, as the game's: its uniforms found when it compiles, set when it draws. */
public final class WeatherShader extends Shader {
    private int nightValue;

    public void onCompileSuccess(ShaderProgram program) {
        int id = getID();
        nightValue = GL20.glGetUniformLocation(id, "NightValue");
    }

    public void startMainThread(TextureDraw draw, int playerIndex) {
        if (playerIndex < 0 || playerIndex >= 4) return;
    }

    public void startRenderThread(TextureDraw draw) {
        GL20.glUniform1f(nightValue, 0.5f);
    }
}
