package org.lwjgl.opengl;

import java.util.HashMap;
import java.util.Map;

/** Synthetic: a program's uniforms, by name, and the values set to them. */
public final class GL20 {
    public static final Map<String, Integer> uniforms = new HashMap<>();
    public static final Map<Integer, Float> values = new HashMap<>();

    public static int glGetUniformLocation(int program, CharSequence name) {
        Integer location = uniforms.get(name.toString());
        return location == null ? -1 : location;
    }

    public static void glUniform1f(int location, float value) {
        if (location >= 0) values.put(location, value);
    }
}
