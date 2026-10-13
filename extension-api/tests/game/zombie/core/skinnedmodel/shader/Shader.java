package zombie.core.skinnedmodel.shader;

import org.lwjgl.opengl.GL20;

/** Synthetic: a model shader, as the game's: its program bound when it starts. */
public final class Shader {
    public final String name;
    public final boolean isStatic;
    public final zombie.core.opengl.ShaderProgram program = new zombie.core.opengl.ShaderProgram();
    public org.joml.Matrix4f transform;
    public java.nio.FloatBuffer palette;
    public Shader() { this("synthetic", false, false); }
    public Shader(String name, boolean isStatic, boolean instanced) { this.name = name; this.isStatic = isStatic; }
    public zombie.core.opengl.ShaderProgram getShaderProgram() { return program; }
    public void setTransformMatrix(org.joml.Matrix4f matrix, boolean transpose) { transform = matrix; }
    public void setMatrixPalette(java.nio.FloatBuffer bones, boolean transpose) { palette = bones; }
    public void End() { }
    public int getID() { return 11; }

    public void Start() {
        GL20.glUniform1i(GL20.glGetUniformLocation(getID(), "DIFFUSE"), 0);
    }
}
