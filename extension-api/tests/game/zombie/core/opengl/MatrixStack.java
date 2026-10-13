package zombie.core.opengl;

/** Synthetic: the game's matrix stack, never empty while the interface draws (a test may empty it). */
public final class MatrixStack {
    public boolean empty;
    private final org.joml.Matrix4f top = new org.joml.Matrix4f();

    public org.joml.Matrix4f peek() { return top; }

    public boolean isEmpty() { return empty; }
}
