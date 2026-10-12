package zombie.core.opengl;

/** Synthetic: a compiled program. */
public final class ShaderProgram {
    public final float[] colour = new float[4];
    public void setVector4(String name, float x, float y, float z, float w) {
        if ("u_color".equals(name)) { colour[0] = x; colour[1] = y; colour[2] = z; colour[3] = w; }
    }
}
