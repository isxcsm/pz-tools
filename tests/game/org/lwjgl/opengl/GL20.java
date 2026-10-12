package org.lwjgl.opengl;

import java.util.HashMap;
import java.util.Map;

/** Synthetic: a program's uniforms, by name, and the values set to them. */
public final class GL20 {
    public static final Map<String, Integer> uniforms = new HashMap<>();
    public static final Map<Integer, Float> values = new HashMap<>();
    public static final Map<Integer, Integer> integers = new HashMap<>();
    public static final Map<Integer, float[]> vectors = new HashMap<>();

    /** The linked programs of the context, and the programs bound in turn. */
    public static final java.util.Set<Integer> programs = new java.util.HashSet<>();
    public static final java.util.List<Integer> used = new java.util.ArrayList<>();

    public static boolean glIsProgram(int program) { return programs.contains(program); }

    public static int glGetProgrami(int program, int name) { return programs.contains(program) || linked.contains(program) ? 1 : 0; }

    public static void glUseProgram(int program) { used.add(program); current = program; }

    /** The program bound; the programs made here, and those linked; whether shaders compile and programs link. */
    public static int current, made = 1000;
    public static final java.util.Set<Integer> linked = new java.util.HashSet<>();
    public static boolean compiles = true;
    public static int glCreateShader(int type) { return ++made; }
    public static void glShaderSource(int shader, CharSequence source) { }
    public static void glCompileShader(int shader) { }
    public static int glGetShaderi(int shader, int name) { return compiles ? 1 : 0; }
    public static String glGetShaderInfoLog(int shader) { return "synthetic: it does not compile"; }
    public static int glCreateProgram() { return ++made; }
    public static void glAttachShader(int program, int shader) { }
    public static void glBindAttribLocation(int program, int index, CharSequence name) { }
    public static void glLinkProgram(int program) { linked.add(program); }
    public static String glGetProgramInfoLog(int program) { return ""; }
    public static void glUniform2f(int location, float x, float y) { if (location >= 0) vectors.put(location, new float[] { x, y }); }
    public static void glUniform4f(int location, float x, float y, float z, float w) {
        if (location >= 0) vectors.put(location, new float[] { x, y, z, w });
    }
    public static void glUniformMatrix4fv(int location, boolean transpose, java.nio.FloatBuffer value) { }

    /** Each attribute's array (from its place when it was set) and stride; the attributes enabled. */
    public static final Map<Integer, java.nio.FloatBuffer> pointers = new HashMap<>();
    public static final Map<Integer, Integer> strides = new HashMap<>();
    public static final java.util.Set<Integer> enabled = new java.util.HashSet<>();
    public static void glVertexAttribPointer(int index, int size, int type, boolean normalized, int stride, java.nio.FloatBuffer pointer) {
        pointers.put(index, pointer.duplicate());
        strides.put(index, stride);
    }
    public static void glEnableVertexAttribArray(int index) { enabled.add(index); }
    public static void glDisableVertexAttribArray(int index) { enabled.remove(index); }

    public static int glGetUniformLocation(int program, CharSequence name) {
        Integer location = uniforms.get(name.toString());
        return location == null ? -1 : location;
    }

    public static void glUniform1f(int location, float value) {
        if (location >= 0) values.put(location, value);
    }

    public static void glUniform1i(int location, int value) {
        if (location >= 0) integers.put(location, value);
    }

    public static void glUniform3f(int location, float x, float y, float z) {
        if (location >= 0) vectors.put(location, new float[] { x, y, z });
    }
}
