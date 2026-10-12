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

    public static int glGetProgrami(int program, int name) { return programs.contains(program) ? 1 : 0; }

    public static void glUseProgram(int program) { used.add(program); }

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
