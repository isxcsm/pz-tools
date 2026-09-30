package pztools.extensions.screen;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Turns the game's final screen shader into the same shader followed by a colour grade.
 *
 * <p>Nothing of the original is rewritten. Its entry point is renamed through the preprocessor,
 * and a new entry point is appended that runs the original and then adjusts the colour it
 * produced. The original therefore keeps doing everything it does (night, weather, drunkenness,
 * night vision), and a screen shader replaced by a mod is graded the same way as the game's own.
 *
 * <p>Pure text in, text out: no game and no graphics context are needed to run or test this.
 */
public final class GradeShader {
    /** Present in every graded source; a source that already has it is never graded twice. */
    public static final String BASE_MAIN = "pzt_base_main";
    private static final Pattern MAIN = Pattern.compile("\\bvoid\\s+main\\s*\\(");
    private static final Pattern VERSION = Pattern.compile("(?m)^[ \\t]*#[ \\t]*version[ \\t]+(\\d+)[^\\n]*\\n?");
    private static final Pattern OUTPUT = Pattern.compile("\\bout\\s+(?:(?:highp|mediump|lowp)\\s+)?vec4\\s+([A-Za-z_]\\w*)\\s*;");

    public record Result(String source, boolean clarity, boolean nightAware, boolean outdoorsAware) { }

    private GradeShader() { }

    /** Whether this shader source is the one that holds the entry point. */
    public static boolean definesMain(String source) { return MAIN.matcher(stripComments(source)).find(); }

    /**
     * @throws IllegalArgumentException with a short reason when the source is not one this can
     *         safely extend; the caller then leaves the game's shader exactly as it is
     */
    public static Result transform(String source, GradeParameters p) {
        if (source == null || source.isEmpty() || source.length() > 1_000_000) throw new IllegalArgumentException("no-source");
        String clean = stripComments(source);
        if (clean.contains(BASE_MAIN) || clean.contains("pzt_")) throw new IllegalArgumentException("already-graded");
        if (!MAIN.matcher(clean).find()) throw new IllegalArgumentException("no-entry-point");

        int version = 110, insertAt = 0;
        Matcher versionLine = VERSION.matcher(clean);
        if (versionLine.find()) { version = Integer.parseInt(versionLine.group(1)); insertAt = versionLine.end(); }

        // The colour the original writes: a declared output, or the built-in one of older shader versions.
        String output = null;
        Matcher outputs = OUTPUT.matcher(clean);
        int declared = 0;
        while (outputs.find()) { declared++; output = outputs.group(1); }
        if (declared > 1) throw new IllegalArgumentException("several-outputs");
        if (declared == 0) {
            if (!clean.contains("gl_FragColor")) throw new IllegalArgumentException("no-colour-output");
            output = "gl_FragColor";
        }

        boolean night = declares(clean, "float", "NightValue"), outdoors = declares(clean, "float", "Exterior");
        boolean goggles = declares(clean, "float", "NightVisionGoggles");
        // Sharpening reads neighbouring pixels of the scene, which needs the game's own sampler and coordinates.
        boolean clarity = p.clarity() > 0 && version >= 130 && declares(clean, "sampler2D", "DIFFUSE")
            && Pattern.compile("\\b(?:in|varying)\\s+vec2\\s+vUV\\b").matcher(clean).find();
        boolean blurred = declares(clean, "float", "DrunkFactor") && declares(clean, "float", "BlurFactor");

        var code = new StringBuilder(2048);
        code.append("\n#undef main\n");
        code.append("// PZ Tools screen grade, appended at run time. The game's files are unchanged.\n");
        code.append("const vec3 pzt_luma = vec3(0.2126, 0.7152, 0.0722);\n");
        // The game's shader declares its own max() and clamp(), which hides the built-in ones for
        // every other argument type. Limits are therefore written with abs() alone.
        code.append("float pzt_unit(float v) { return 0.5 * (abs(v) - abs(v - 1.0) + 1.0); }\n");
        code.append("vec3 pzt_unit(vec3 v) { return 0.5 * (abs(v) - abs(v - vec3(1.0)) + vec3(1.0)); }\n");
        code.append("vec3 pzt_positive(vec3 v) { return 0.5 * (v + abs(v)); }\n");
        code.append("vec3 pzt_grade(vec3 c) {\n");
        code.append("    float l = dot(c, pzt_luma);\n");
        code.append("    c += ").append(GradeParameters.literal(p.shadowTint())).append(" * (1.0 - smoothstep(0.0, 0.45, l)) + ")
            .append(GradeParameters.literal(p.highlightTint())).append(" * smoothstep(0.55, 1.0, l);\n");
        code.append("    c = (c - vec3(").append(GradeParameters.literal(p.pivot())).append(")) * ")
            .append(GradeParameters.literal(p.contrast())).append(" + vec3(").append(GradeParameters.literal(p.pivot())).append(");\n");
        code.append("    c *= mix(").append(GradeParameters.literal(p.shadowGain())).append(", 1.0, smoothstep(0.0, 0.30, l));\n");
        code.append("    c = mix(vec3(dot(c, pzt_luma)), c, ").append(GradeParameters.literal(p.saturation())).append(");\n");
        code.append("    c = c / (vec3(1.0) + ").append(GradeParameters.literal(p.highlightRoll())).append(" * pzt_positive(c - vec3(0.75)));\n");
        code.append("    return c;\n}\n");
        code.append("void main() {\n");
        code.append("    ").append(BASE_MAIN).append("();\n");
        code.append("    vec3 pzt_before = pzt_unit(").append(output).append(".rgb);\n");
        code.append("    vec3 pzt_c = pzt_before;\n");
        if (clarity) {
            code.append("    vec2 pzt_px = 1.0 / vec2(textureSize(DIFFUSE, 0));\n");
            code.append("    float pzt_around = dot(texture(DIFFUSE, vUV + vec2(pzt_px.x, 0.0)).rgb + texture(DIFFUSE, vUV - vec2(pzt_px.x, 0.0)).rgb\n");
            code.append("        + texture(DIFFUSE, vUV + vec2(0.0, pzt_px.y)).rgb + texture(DIFFUSE, vUV - vec2(0.0, pzt_px.y)).rgb, pzt_luma) * 0.25;\n");
            code.append("    float pzt_detail = 0.16 * pzt_unit((dot(texture(DIFFUSE, vUV).rgb, pzt_luma) - pzt_around) / 0.16 + 0.5) - 0.08;\n");
            // A drunk or blurred view is blurred on purpose; sharpening would undo it.
            if (blurred) code.append("    if (DrunkFactor > 0.0 || BlurFactor > 0.0) pzt_detail = 0.0;\n");
            code.append("    pzt_c += vec3(pzt_detail * ").append(GradeParameters.literal(p.clarity())).append(");\n");
        }
        if (p.seasonAmount() > 0) {
            // A season colours daylight outdoors. Night and interiors keep the game's own mood.
            code.append("    float pzt_season = ").append(GradeParameters.literal(p.seasonAmount())).append(';');
            if (night) code.append(" pzt_season *= 1.0 - pzt_unit(NightValue);");
            if (outdoors) code.append(" pzt_season *= pzt_unit(Exterior);");
            code.append("\n    vec3 pzt_tinted = mix(vec3(dot(pzt_c, pzt_luma)), pzt_c, ").append(GradeParameters.literal(p.seasonSaturation()))
                .append(") * ").append(GradeParameters.literal(p.seasonTint())).append(";\n");
            code.append("    pzt_c = mix(pzt_c, pzt_tinted, pzt_season);\n");
        }
        code.append("    float pzt_amount = ").append(GradeParameters.literal(p.strength())).append(';');
        // Nights are already dark; a full-strength grade would crush them.
        if (night) code.append(" pzt_amount *= 1.0 - 0.4 * pzt_unit(NightValue);");
        code.append("\n    pzt_c = mix(pzt_c, pzt_grade(pzt_c), pzt_amount);\n");
        // Night vision is a picture of its own; it is left exactly as the game draws it.
        code.append("    ").append(output).append(".rgb = ");
        if (goggles) code.append("NightVisionGoggles > 0.5 ? pzt_before : ");
        code.append("pzt_unit(pzt_c);\n}\n");

        String graded = source.substring(0, insertAt) + "#define main " + BASE_MAIN + "\n" + source.substring(insertAt)
            + (source.endsWith("\n") ? "" : "\n") + code;
        return new Result(graded, clarity, night, outdoors);
    }

    private static boolean declares(String clean, String type, String name) {
        return Pattern.compile("\\buniform\\s+" + type + "\\s+" + name + "\\b").matcher(clean).find();
    }

    /** Comments become spaces, line breaks stay: positions in the result match the original. */
    static String stripComments(String source) {
        var out = new StringBuilder(source.length());
        for (int i = 0; i < source.length(); i++) {
            char c = source.charAt(i);
            if (c == '/' && i + 1 < source.length() && source.charAt(i + 1) == '/') {
                while (i < source.length() && source.charAt(i) != '\n') { out.append(' '); i++; }
                if (i < source.length()) out.append('\n');
            } else if (c == '/' && i + 1 < source.length() && source.charAt(i + 1) == '*') {
                int end = source.indexOf("*/", i + 2);
                int stop = end < 0 ? source.length() : end + 2;
                for (; i < stop; i++) out.append(source.charAt(i) == '\n' ? '\n' : ' ');
                i--;
            } else out.append(c);
        }
        return out.toString();
    }
}
