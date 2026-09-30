package pztools.extensions.screen;

import java.util.*;

/** No game and no graphics context: the shader text transform, and the install/restore logic over a scripted driver. */
public final class ScreenGradeTest {
    private static final String VANILLA = """
        #version 330
        uniform sampler2D DIFFUSE;
        uniform float NightValue;
        uniform float Exterior;
        uniform float NightVisionGoggles;
        uniform float DrunkFactor;
        uniform float BlurFactor;
        in vec2 vUV;
        float max(float a, float b);
        void main()
        {
            gl_FragColor = vec4(texture2D(DIFFUSE, vUV).rgb, 1.0);
        }
        /* LASTMAIN
        void main() { gl_FragColor = vec4(1.0); }
        */
        // void main() { }
        """;

    public static void main(String[] args) throws Throwable {
        shaderText(); parameters(); installAndRestore(); gameRecompiles(); failuresLeaveTheOriginal(); stoppedFromAnotherThread(); provider();
        System.out.println("PASS screen grade: shader wrapping, presets, install/restore, game recompile, failure isolation, retirement");
    }

    private static void shaderText() {
        var request = new GradeParameters.Request("cinematic", 0.5, true, 1, 0.8);
        GradeShader.Result graded = GradeShader.transform(VANILLA, GradeParameters.of(request, GradeParameters.WINTER));
        String text = graded.source();
        check(text.startsWith("#version 330\n#define main pzt_base_main\n"), "the rename directly follows the version line");
        check(text.contains(VANILLA.substring(VANILLA.indexOf("uniform sampler2D"))), "the original is kept word for word, comments included");
        check(text.indexOf("#undef main") > text.indexOf("// void main() { }"), "the new entry point comes after everything original");
        check(count(text, "void main()") == 4, "one appended entry point beside the original and its two commented ones");
        check(text.contains("pzt_base_main();") && text.contains("gl_FragColor.rgb = NightVisionGoggles > 0.5 ? pzt_before : pzt_unit(pzt_c);"),
            "runs the original first and leaves night vision alone");
        check(graded.clarity() && graded.nightAware() && graded.outdoorsAware(), "every optional part applies to the game's own shader");
        check(text.contains("if (DrunkFactor > 0.0 || BlurFactor > 0.0) pzt_detail = 0.0;"), "no sharpening of a deliberately blurred view");
        check(text.contains("pzt_season *= 1.0 - pzt_unit(NightValue);") && text.contains("pzt_season *= pzt_unit(Exterior);"), "seasons colour daylight outdoors only");
        // The game's shader hides the built-in max() and clamp() behind its own; the appended code must not call either.
        String appended = text.substring(text.indexOf("#undef main"));
        check(!appended.contains("max(") && !appended.contains("clamp("), "appended code avoids functions the game redefines");
        check(appended.contains("0.50000"), "strength is a constant in the text");

        // A shader from a mod: different output, older version, none of the game's uniforms.
        String modded = "#version 120\nvarying vec2 uv;\nvoid main() { gl_FragColor = vec4(1.0); }";
        GradeShader.Result plain = GradeShader.transform(modded, GradeParameters.of(request, GradeParameters.WINTER));
        check(!plain.clarity() && !plain.nightAware() && !plain.outdoorsAware(), "unknown shaders get the colour grade without the parts that need the game's inputs");
        check(!plain.source().contains("textureSize") && !plain.source().contains("NightValue"), "nothing undeclared is referenced");
        String modern = "#version 330\nlayout(location = 0) out vec4 fragColour;\nvoid main(void) { fragColour = vec4(1.0); }\n";
        check(GradeShader.transform(modern, GradeParameters.of(request, 0)).source().contains("fragColour.rgb = pzt_unit(pzt_c);"), "a declared output is used by its name");
        check(!GradeShader.transform(modern, GradeParameters.of(request, 0)).source().contains("pzt_season"), "an unknown season adds no seasonal code");

        for (String rejected : new String[] { "", "#version 330\nfloat helper() { return 1.0; }", "#version 330\nout vec4 a;\nout vec4 b;\nvoid main() { }",
                "#version 330\nvoid main() { }", GradeShader.transform(VANILLA, GradeParameters.of(request, 0)).source() })
            try { GradeShader.transform(rejected, GradeParameters.of(request, 0)); throw new AssertionError("accepted: " + rejected); }
            catch (IllegalArgumentException expected) { }
        check(GradeShader.definesMain(VANILLA) && !GradeShader.definesMain("/* void main() {} */ float f();"), "only a live entry point counts");
    }

    private static void parameters() {
        var request = GradeParameters.Request.parse(Map.of("schema_version", "1", "preset", "vivid", "strength", "35", "seasonal", "true"));
        check(request.preset().equals("vivid") && Math.abs(request.strength() - 0.35) < 1e-9 && request.seasonal(), "parsed");
        var defaults = GradeParameters.Request.parse(Map.of());
        check(defaults.preset().equals("realistic") && Math.abs(defaults.strength() - 0.6) < 1e-9 && !defaults.seasonal() && !defaults.idle(), "defaults draw the realistic mood");
        check(new GradeParameters.Request("vivid", 0, false, 1, 0.8).idle() && !new GradeParameters.Request("vivid", 0, true, 1, 0.8).idle(),
            "zero strength draws nothing unless the seasonal part is on");
        check(GradeParameters.Request.OFF.idle(), "a retired module asks for nothing");
        for (var invalid : List.of(Map.of("preset", "neon"), Map.of("strength", "101"), Map.of("strength", "-1"), Map.of("seasonal", "yes"),
                Map.of("clarity_scale", "3"), Map.of("seasonal_amount", "2"), Map.of("schema_version", "2"), Map.of("steering_enabled", "true")))
            try { GradeParameters.Request.parse(invalid); throw new AssertionError("accepted: " + invalid); }
            catch (IllegalArgumentException expected) { }
        var summer = GradeParameters.of(new GradeParameters.Request("realistic", 1, true, 1, 0.8), GradeParameters.SUMMER);
        var late = GradeParameters.of(new GradeParameters.Request("realistic", 1, true, 1, 0.8), GradeParameters.LATE_SUMMER);
        check(Arrays.equals(summer.seasonTint(), late.seasonTint()) && summer.seasonAmount() == 0.8, "both summer phases look the same");
        check(GradeParameters.of(new GradeParameters.Request("realistic", 1, false, 1, 0.8), GradeParameters.SUMMER).seasonAmount() == 0, "no seasonal part unless asked for");
    }
    private static void installAndRestore() {
        var world = new World();
        var grade = new ScreenGrade(world);
        var on = new GradeParameters.Request("realistic", 0.6, false, 1, 0.8);
        grade.frame(GradeParameters.Request.OFF);
        check(world.queued.isEmpty() && grade.state().equals("off"), "off costs nothing");

        world.program = null;
        grade.frame(on); world.runQueued();
        check(grade.state().equals("waiting"), "waits while the game has no screen shader");
        world.program = new Object(); world.programId = world.original;
        for (int i = 0; i < 40 && !grade.state().equals("on"); i++) { grade.frame(on); world.runQueued(); }
        check(grade.state().equals("on") && world.programId != world.original, "installed once the shader exists");
        int first = world.programId;
        check(world.adopted.equals(List.of(first)), "the game re-reads its uniforms for the new program");
        check(world.registry.get(first) == world.program, "the new program is filed where the game's drawing looks it up, or nothing would be drawn");
        check(world.sources.get(world.programs.get(first).get(1)).contains("pzt_base_main"), "the entry shader is the graded one");
        check(world.programs.get(first).get(0).equals(world.programs.get(world.original).get(0)), "every other shader is shared with the original");
        check(world.programs.containsKey(world.original), "the original program is kept for switching back");
        check(world.shaders.size() == 2, "the temporary shader object is released after linking: " + world.shaders);

        for (int i = 0; i < 200; i++) { grade.frame(on); world.runQueued(); }
        check(world.compiles == 1 && world.programId == first, "nothing is rebuilt while nothing changes");

        var stronger = new GradeParameters.Request("vivid", 0.9, false, 1, 0.8);
        grade.frame(stronger); world.runQueued();
        check(grade.state().equals("on") && world.programId != first && !world.programs.containsKey(first), "a new setting replaces the grade and frees the old one");
        check(world.programs.size() == 2, "original plus one grade");
        check(!world.registry.containsKey(first) && world.registry.get(world.programId) == world.program, "the freed grade's number is no longer filed; the new one is");

        world.season = GradeParameters.AUTUMN;
        var seasonal = new GradeParameters.Request("vivid", 0.9, true, 1, 0.8);
        int before = world.compiles;
        for (int i = 0; i < 130; i++) { grade.frame(seasonal); world.runQueued(); }
        check(world.compiles == before + 1 && world.sources.get(world.programs.get(world.programId).get(1)).contains("pzt_season"), "the season is picked up within about a second");

        grade.frame(GradeParameters.Request.OFF); world.runQueued();
        check(grade.state().equals("off") && world.programId == world.original && world.programs.size() == 1, "switching off restores the original and frees the grade");
        check(world.adopted.get(world.adopted.size() - 1) == world.original, "the game re-reads its uniforms for its own program again");
        check(world.registry.keySet().equals(Set.of(world.original)), "only the game's own program stays filed: " + world.registry.keySet());
    }

    private static void gameRecompiles() {
        var world = new World();
        var grade = new ScreenGrade(world);
        var on = new GradeParameters.Request("realistic", 0.6, false, 1, 0.8);
        grade.frame(on); world.runQueued();
        int ours = world.programId, abandoned = world.original;
        // The game rebuilds its shader: it frees the program it was using (ours), unfiles it, and makes and files a new one.
        world.programs.remove(ours); world.registry.remove(ours);
        world.original = world.newProgram(world.vertex, world.newShader(World.ENTRY.replace("1.0)", "0.5)")));
        world.programId = world.original; world.registry.put(world.original, world.program);
        grade.frame(on); world.runQueued();
        check(grade.state().equals("on") && world.programId != world.original, "graded again on top of the game's new program");
        check(world.sources.get(world.programs.get(world.programId).get(1)).contains("0.5)"), "from the new source, not the old one");
        check(!world.programs.containsKey(abandoned), "the program nobody owns any more is freed");
        check(!world.registry.containsKey(abandoned) && world.registry.get(world.programId) == world.program, "and unfiled; the new grade is filed");
    }

    private static void failuresLeaveTheOriginal() {
        var on = new GradeParameters.Request("realistic", 0.6, false, 1, 0.8);
        var world = new World(); world.failCompile = true;
        var grade = new ScreenGrade(world);
        for (int i = 0; i < 500; i++) { grade.frame(on); world.runQueued(); }
        check(grade.state().startsWith("failed:compile:") && world.programId == world.original && world.compiles == 1, "a rejected shader is tried once, not every frame: " + grade.state());
        world.failCompile = false;
        grade.frame(new GradeParameters.Request("vivid", 0.6, false, 1, 0.8)); world.runQueued();
        check(grade.state().equals("on"), "a changed request is tried straight away");

        world = new World(); world.failLink = true; grade = new ScreenGrade(world);
        grade.frame(on); world.runQueued();
        check(grade.state().startsWith("failed:link:") && world.programId == world.original && world.shaders.size() == 2, "a link failure leaks nothing");

        // The game cannot take the new program (its uniform lookup throws): the original is put back before anything is drawn.
        world = new World(); world.failAdopt = true; grade = new ScreenGrade(world);
        grade.frame(on); world.runQueued();
        check(grade.state().startsWith("failed:") && world.programId == world.original && world.programs.size() == 1, "adoption failure restores the original: " + grade.state());
        check(world.registry.keySet().equals(Set.of(world.original)), "a rejected program is not left filed");

        world = new World(); world.sources.put(world.programs.get(world.original).get(1), "#version 330\nfloat unrelated();");
        grade = new ScreenGrade(world);
        grade.frame(on); world.runQueued();
        check(grade.state().equals("failed:entry-shader-not-found") && world.compiles == 0, "an unrecognised shader is left alone");
    }

    private static void stoppedFromAnotherThread() throws Exception {
        var world = new World();
        var grade = new ScreenGrade(world);
        var on = new GradeParameters.Request("realistic", 0.6, false, 1, 0.8);
        grade.frame(on); world.runQueued();
        Thread other = new Thread(grade::stop); other.start(); other.join();
        check(world.programId != world.original && world.queued.size() == 1, "stopping only queues the switch back; it touches no graphics off the render thread");
        world.runQueued();
        check(world.programId == world.original && world.programs.size() == 1 && grade.state().equals("stopped"), "restored on the render thread");
        check(world.registry.keySet().equals(Set.of(world.original)), "stopping unfiles the grade");
        grade.frame(on); world.runQueued();
        check(world.programId == world.original && world.queued.isEmpty(), "a stopped grade never installs again");
    }

    private static void provider() throws Exception {
        var module = new ScreenLookProvider();
        check(module.id().equals("pztools.screen-look"), "module identity");
        module.validateConfig(Map.of("preset", "cinematic", "strength", "80"));
        try { module.validateConfig(Map.of("preset", "neon")); throw new AssertionError("invalid configuration accepted"); }
        catch (IllegalArgumentException expected) { }
        // A class loader without the game's classes: the module is unsupported there, and says so without throwing.
        var support = module.initialize(null, ScreenGradeTest.class.getClassLoader());
        check(!support.supported() && support.reason().equals("screen-shader-contract-changed"), "a game without the expected classes is unsupported");
        check(module.failureReason() == null && module.diagnostics().isEmpty(), "nothing to report before activation");
        module.gameFrame(); module.deactivate(); module.close();
    }

    /** A scripted game and driver: programs are lists of shader ids, shaders are source text. */
    private static final class World implements ScreenGrade.Platform, ScreenGrade.Graphics {
        static final String ENTRY = VANILLA;
        final Map<Integer, List<Integer>> programs = new HashMap<>();
        final Map<Integer, String> sources = new HashMap<>();
        final Set<Integer> shaders = new HashSet<>();
        final Set<Integer> vertexShaders = new HashSet<>();
        final ArrayDeque<Runnable> queued = new ArrayDeque<>();
        final List<Integer> adopted = new ArrayList<>();
        // The game's program register (ShaderPrograms): drawing finds a program, and its projection, only here.
        final Map<Integer, Object> registry = new HashMap<>();
        Object program = new Object();
        int next = 100, programId, original, season, compiles, vertex;
        boolean failCompile, failLink, failAdopt;
        String log = "";
        World() {
            vertex = newShader("#version 330\nvoid main() { }"); vertexShaders.add(vertex);
            original = newProgram(vertex, newShader(ENTRY)); programId = original;
            registry.put(original, program);
        }
        int newShader(String source) { int id = next++; shaders.add(id); sources.put(id, source); return id; }
        int newProgram(int... parts) { int id = next++; var list = new ArrayList<Integer>(); for (int part : parts) list.add(part); programs.put(id, list); return id; }
        void runQueued() { while (!queued.isEmpty()) queued.poll().run(); }

        @Override public Object program() { return program; }
        @Override public int programId(Object current) { return programId; }
        @Override public boolean compiled(Object current) { return true; }
        @Override public void adopt(Object current, int id) {
            if (failAdopt && id != original) throw new IllegalStateException("uniform lookup failed");
            if (!programs.containsKey(id)) throw new AssertionError("adopting a freed program");
            programId = id; adopted.add(id);
            registry.put(id, current);
        }
        @Override public void forget(Object current, int id) { if (registry.get(id) == current) registry.remove(id); }
        @Override public int season() { return season; }
        @Override public void onRenderThread(Runnable task) { queued.add(task); }
        @Override public ScreenGrade.Graphics graphics() { return this; }

        @Override public int[] attachedShaders(int id) { return programs.get(id).stream().mapToInt(Integer::intValue).toArray(); }
        @Override public boolean fragment(int shader) { return !vertexShaders.contains(shader); }
        @Override public String source(int shader) { return sources.get(shader); }
        @Override public int compileFragment(String source) { compiles++; if (failCompile) { log = "0(1) : error C0000: syntax error"; return 0; } return newShader(source); }
        @Override public int link(int[] parts, int like) { if (failLink) { log = "unresolved"; return 0; } return newProgram(parts); }
        @Override public boolean alive(int id) { return programs.containsKey(id); }
        @Override public void deleteProgram(int id) { programs.remove(id); }
        // As in the driver, a shader lives on while a program holds it; the test only tracks unattached ones.
        @Override public void deleteShader(int shader) { shaders.remove(shader); }
        @Override public String lastLog() { return log; }
    }

    private static int count(String text, String part) { int n = 0; for (int i = text.indexOf(part); i >= 0; i = text.indexOf(part, i + 1)) n++; return n; }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
