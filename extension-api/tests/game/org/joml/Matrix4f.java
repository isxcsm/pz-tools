package org.joml;

/** Synthetic: a matrix, multiplied and read as the game's interface projection is; turned about a point (the last turn kept). */
public final class Matrix4f implements Matrix4fc {
    public static int turns;
    public static float lastTurn;

    public Matrix4f mul(Matrix4fc right, Matrix4f into) { return into; }

    public java.nio.FloatBuffer get(java.nio.FloatBuffer into) { return into; }

    public Matrix4f translate(float x, float y, float z) { return this; }

    public Matrix4f rotateZ(float angle) { turns++; lastTurn = angle; return this; }
}
