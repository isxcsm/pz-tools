package pztools.extensions.screen;

import static org.lwjgl.glfw.GLFW.*;
import static org.lwjgl.opengl.GL11.*;
import static org.lwjgl.opengl.GL13.*;
import static org.lwjgl.opengl.GL15.*;
import static org.lwjgl.opengl.GL20.*;
import static org.lwjgl.opengl.GL30.*;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.lwjgl.BufferUtils;
import org.lwjgl.opengl.GL;

/**
 * Opt-in check against the installed game's shader files and this machine's graphics driver.
 * It starts no game: a hidden window gives a graphics context, the game's screen shader is
 * compiled the way the game assembles it, and the grade is built on top through the same driver
 * calls the extension uses. Nothing is written anywhere.
 *
 * <p>Usage: java -cp &lt;runtime jar&gt;;&lt;game jar&gt;;&lt;this&gt; ...VerifyInstalledScreenShader &lt;game directory&gt;
 */
public final class VerifyInstalledScreenShader {
    public static void main(String[] args) throws Throwable {
        Path game = Path.of(args[0]);
        Path shaders = game.resolve("media/shaders");
        // Reflection only; proves the game classes the extension reaches for are still there.
        ScreenGrade.resolve(VerifyInstalledScreenShader.class.getClassLoader());
        System.out.println("Game accessors (screen shader, render queue, season): resolved");

        if (!glfwInit()) throw new IllegalStateException("No window system");
        glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
        long window = glfwCreateWindow(64, 64, "pztools-shader-check", 0, 0);
        if (window == 0) throw new IllegalStateException("No graphics context");
        try {
            glfwMakeContextCurrent(window);
            GL.createCapabilities();
            System.out.println("Driver: " + glGetString(GL_RENDERER) + " / OpenGL " + glGetString(GL_VERSION));

            // The game inlines a header for each include and links the matching implementation as its own shader.
            String vertex = Files.readString(shaders.resolve("screen.vert"));
            var fragment = new StringBuilder();
            List<String> units = new ArrayList<>();
            for (String line : Files.readAllLines(shaders.resolve("screen.frag"))) {
                String trimmed = line.trim();
                if (trimmed.startsWith("#include")) {
                    String name = trimmed.substring(8).trim().replace("\"", "");
                    fragment.append(Files.readString(shaders.resolve(name + ".h"))).append('\n');
                    units.add(Files.readString(shaders.resolve(name + ".glsl")));
                } else fragment.append(line).append('\n');
            }
            int base = glCreateProgram();
            glAttachShader(base, compile(GL_VERTEX_SHADER, vertex));
            glAttachShader(base, compile(GL_FRAGMENT_SHADER, fragment.toString()));
            for (String unit : units) glAttachShader(base, compile(GL_FRAGMENT_SHADER, unit));
            glLinkProgram(base);
            if (glGetProgrami(base, GL_LINK_STATUS) == 0) throw new IllegalStateException("The game's own shader does not link here: " + glGetProgramInfoLog(base));
            Set<String> uniforms = uniforms(base);
            System.out.println("Original screen shader: linked, " + uniforms.size() + " active uniforms");

            var graphics = new ScreenGrade.DriverGraphics(VerifyInstalledScreenShader.class.getClassLoader());
            int[] attached = graphics.attachedShaders(base);
            int entry = 0; String original = null;
            for (int shader : attached)
                if (graphics.fragment(shader) && GradeShader.definesMain(graphics.source(shader))) { entry = shader; original = graphics.source(shader); }
            if (entry == 0) throw new IllegalStateException("Entry shader not found among " + attached.length + " attached shaders");

            float[] before = render(base, 1);
            System.out.printf("Reference pixel (mid grey, daylight, outdoors): %.3f %.3f %.3f%n", before[0], before[1], before[2]);
            int checked = 0;
            for (String preset : new String[] { "realistic", "vivid", "cinematic" })
                for (int season : new int[] { 0, GradeParameters.SPRING, GradeParameters.SUMMER, GradeParameters.AUTUMN, GradeParameters.WINTER }) {
                    var request = new GradeParameters.Request(preset, 1.0, season != 0, 1, 0.8);
                    GradeShader.Result graded = GradeShader.transform(original, GradeParameters.of(request, season));
                    int shader = graphics.compileFragment(graded.source());
                    if (shader == 0) throw new IllegalStateException(preset + "/" + season + " does not compile: " + graphics.lastLog());
                    int[] parts = attached.clone();
                    for (int i = 0; i < parts.length; i++) if (parts[i] == entry) parts[i] = shader;
                    int program = graphics.link(parts, base);
                    if (program == 0) throw new IllegalStateException(preset + "/" + season + " does not link: " + graphics.lastLog());
                    // The game sets its uniforms by name after a compile; every one it had must still be there.
                    Set<String> now = uniforms(program);
                    for (String name : uniforms) if (!now.contains(name)) throw new IllegalStateException(preset + "/" + season + " lost uniform " + name);
                    for (String name : new String[] { "aPos", "aUV", "aColor" })
                        if (glGetAttribLocation(program, name) != glGetAttribLocation(base, name)) throw new IllegalStateException("Attribute moved: " + name);
                    float[] after = render(program, 1);
                    float[] night = render(program, 0);
                    for (float value : after) if (!(value >= 0 && value <= 1)) throw new IllegalStateException("Invalid colour from " + preset);
                    double change = Math.abs(after[0] - before[0]) + Math.abs(after[1] - before[1]) + Math.abs(after[2] - before[2]);
                    if (change > 0.6) throw new IllegalStateException(preset + "/" + season + " changes a mid grey by " + change + ": too strong to be a grade");
                    if (!graded.clarity() || !graded.nightAware() || !graded.outdoorsAware()) throw new IllegalStateException("An optional part is missing on the game's own shader");
                    System.out.printf("  %-9s season %d: %.3f %.3f %.3f (indoors %.3f %.3f %.3f)%n", preset, season, after[0], after[1], after[2], night[0], night[1], night[2]);
                    graphics.deleteShader(shader); graphics.deleteProgram(program);
                    checked++;
                }
            System.out.println("VERIFIED (no game started): " + checked + " preset and season combinations compile, link, keep every uniform and attribute, and draw a valid colour");
        } finally { glfwDestroyWindow(window); glfwTerminate(); }
    }

    private static int compile(int type, String source) {
        int shader = glCreateShader(type);
        glShaderSource(shader, source);
        glCompileShader(shader);
        if (glGetShaderi(shader, GL_COMPILE_STATUS) == 0) throw new IllegalStateException("The game's own shader does not compile here: " + glGetShaderInfoLog(shader));
        return shader;
    }

    private static Set<String> uniforms(int program) {
        Set<String> names = new HashSet<>();
        var size = BufferUtils.createIntBuffer(1); var type = BufferUtils.createIntBuffer(1);
        for (int i = 0; i < glGetProgrami(program, GL_ACTIVE_UNIFORMS); i++) names.add(glGetActiveUniform(program, i, size, type));
        return names;
    }

    /** Draws one mid-grey texel through the program at noon and reads the result back. */
    private static float[] render(int program, float exterior) {
        int texture = glGenTextures();
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, texture);
        ByteBuffer grey = BufferUtils.createByteBuffer(4 * 4 * 4);
        for (int i = 0; i < 16; i++) grey.put((byte)150).put((byte)120).put((byte)90).put((byte)255);
        grey.flip();
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, grey);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        int target = glGenTextures();
        glBindTexture(GL_TEXTURE_2D, target);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 8, 8, 0, GL_RGBA, GL_UNSIGNED_BYTE, (ByteBuffer)null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        int frame = glGenFramebuffers();
        glBindFramebuffer(GL_FRAMEBUFFER, frame);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
        glViewport(0, 0, 8, 8);
        glBindTexture(GL_TEXTURE_2D, texture);

        glUseProgram(program);
        set(program, "DIFFUSE", 0f, true);
        float[] identity = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        glUniformMatrix4fv(glGetUniformLocation(program, "ModelViewProjection"), false, identity);
        glUniform2f(glGetUniformLocation(program, "TextureSize"), 4, 4);
        glUniform3f(glGetUniformLocation(program, "Light"), 1, 1, 1);
        set(program, "bgl_RenderedTextureWidth", 8, false); set(program, "bgl_RenderedTextureHeight", 8, false);
        set(program, "Exterior", exterior, false);
        for (String zero : new String[] { "LightIntensity", "NightValue", "NightVisionGoggles", "DesaturationVal", "DrunkFactor", "BlurFactor", "Zoom", "timer", "timerWrap" })
            set(program, zero, 0, false);

        int array = glGenVertexArrays();
        glBindVertexArray(array);
        int buffer = glGenBuffers();
        glBindBuffer(GL_ARRAY_BUFFER, buffer);
        FloatBuffer vertices = BufferUtils.createFloatBuffer(4 * 8);
        float[][] corners = { { -1, -1, 0, 0 }, { 1, -1, 1, 0 }, { -1, 1, 0, 1 }, { 1, 1, 1, 1 } };
        for (float[] c : corners) vertices.put(c[0]).put(c[1]).put(c[2]).put(c[3]).put(1).put(1).put(1).put(1);
        vertices.flip();
        glBufferData(GL_ARRAY_BUFFER, vertices, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, false, 32, 0);
        glEnableVertexAttribArray(1); glVertexAttribPointer(1, 2, GL_FLOAT, false, 32, 8);
        glEnableVertexAttribArray(2); glVertexAttribPointer(2, 4, GL_FLOAT, false, 32, 16);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        FloatBuffer pixel = BufferUtils.createFloatBuffer(4);
        glReadPixels(4, 4, 1, 1, GL_RGBA, GL_FLOAT, pixel);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(frame); glDeleteTextures(texture); glDeleteTextures(target); glDeleteBuffers(buffer); glDeleteVertexArrays(array);
        glUseProgram(0);
        return new float[] { pixel.get(0), pixel.get(1), pixel.get(2) };
    }

    private static void set(int program, String name, float value, boolean integer) {
        int location = glGetUniformLocation(program, name);
        if (location < 0) return;
        if (integer) glUniform1i(location, (int)value); else glUniform1f(location, value);
    }
}
