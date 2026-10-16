package pzopt;

import org.lwjgl.opengl.GL20;

/** Synthetic: PZ Optimization's own shader compile and link, which its passes use without the game's ShaderUnit. */
public final class AmbientOcclusion {
    /** The fragment shader of a pass (the vertex one is left out here). */
    static int link(String vert, String frag) {
        return compile(35632, frag);
    }

    private static int compile(int type, String source) {
        int shader = GL20.glCreateShader(type);
        GL20.glShaderSource(shader, source);
        GL20.glCompileShader(shader);
        return GL20.glGetShaderi(shader, 35713) != 0 ? shader : 0;
    }
}
