package zombie.core.opengl;

import java.util.ArrayList;
import org.lwjgl.opengl.GL20;

/** Synthetic: loads a shader's source, as the game's does from media/shaders, and compiles it. */
public final class ShaderUnit {
    public static String text = "";
    /** The file {@link #compile} loads, and the shader it made. */
    public String fileName = "";
    public int glId;

    private String loadShaderFile(String fileName, ArrayList<String> included) {
        return text;
    }

    public String load(String fileName) { return loadShaderFile(fileName, new ArrayList<>()); }

    /** Like the game's: the source loaded, handed to the GL and compiled (whether it did is the GL's to say). */
    public boolean compile() {
        String source = loadShaderFile(fileName, new ArrayList<>());
        int id = GL20.glCreateShader(0);
        GL20.glShaderSource(id, source);
        GL20.glCompileShader(id);
        glId = id;
        return true;
    }
}
