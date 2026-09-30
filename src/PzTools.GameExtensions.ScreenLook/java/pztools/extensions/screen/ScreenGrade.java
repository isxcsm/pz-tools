package pztools.extensions.screen;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.invoke.VarHandle;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.IntBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Puts a colour grade on the game's final screen shader while it is wanted, and takes it off again.
 *
 * <p>The game draws the finished frame through one shader program. This class builds a second
 * program from the very shaders the game compiled (read back from the graphics driver, so
 * whatever the game or a mod loaded is what gets extended), with the fragment shader's entry
 * point wrapped by {@link GradeShader}. It then lets the game's own shader object point at that
 * program and has the game look its uniforms up again, exactly as the game does after compiling
 * a shader itself. The original program is kept untouched, so taking the grade off is switching
 * back, not rebuilding.
 *
 * <p>No game file is written and no game class is changed. All graphics calls run on the game's
 * render thread through the game's own queue. Every failure leaves or restores the original
 * program; the worst outcome of a fault here is the ungraded picture.
 */
public final class ScreenGrade {
    /** The game calls needed, resolved once. A game update that changes them makes the grade unavailable, nothing else. */
    public interface Platform {
        /** The screen shader's program object, or null while the game has none. Render thread. */
        Object program() throws Throwable;
        int programId(Object program) throws Throwable;
        boolean compiled(Object program) throws Throwable;
        /**
         * Points the game's shader object at a program, files it under that number where the game's drawing
         * looks programs up, and has the game look its uniforms up again. Render thread.
         */
        void adopt(Object program, int id) throws Throwable;
        /** Takes a number that is going away out of the game's program register, if it is filed there for this program. Render thread. */
        void forget(Object program, int id) throws Throwable;
        /** The game's current season number, or 0 when it cannot be told. Game thread. */
        int season() throws Throwable;
        /** Runs the task on the render thread, some time soon. Any thread. */
        void onRenderThread(Runnable task) throws Throwable;
        Graphics graphics();
    }

    /** The handful of driver calls used; an interface so the logic can be tested without a graphics context. */
    public interface Graphics {
        int[] attachedShaders(int program) throws Throwable;
        boolean fragment(int shader) throws Throwable;
        String source(int shader) throws Throwable;
        /** A compiled fragment shader, or 0 with {@link #lastLog()} saying why not. */
        int compileFragment(String source) throws Throwable;
        /** A linked program with the same attribute locations as {@code like}, or 0. */
        int link(int[] shaders, int like) throws Throwable;
        boolean alive(int program) throws Throwable;
        void deleteProgram(int program) throws Throwable;
        void deleteShader(int shader) throws Throwable;
        String lastLog();
    }

    private final Platform platform;
    private final AtomicBoolean busy = new AtomicBoolean();
    // Render thread only.
    private Object program;
    private int baseId, gradedId;
    private String gradedSource;
    // Game thread writes, render thread reads.
    private volatile GradeParameters.Request wanted = GradeParameters.Request.OFF;
    private volatile int season;
    private volatile boolean stopped;
    private volatile String state = "off";
    private volatile long nextAttemptNanos;
    private volatile String failedFor, appliedKey, detail = "";
    private volatile int installedIdSeen;
    private volatile Object lastProgram;
    // Game thread only.
    private int frames;

    public ScreenGrade(Platform platform) { this.platform = platform; }

    public String state() { return state; }

    /**
     * Game thread, once per frame. Cheap when nothing changed: two volatile reads and an integer
     * comparison. Anything that touches graphics is handed to the render thread.
     */
    public void frame(GradeParameters.Request request) {
        if (stopped) return;
        wanted = request;
        // The season changes a few times a year; looking once a second is plenty.
        if ((frames++ & 63) == 0 && request.seasonal()) {
            try { season = platform.season(); } catch (Throwable unknown) { season = 0; }
        }
        if (busy.get()) return;
        String key = request + "/" + season;
        String current = state;
        boolean installed = current.equals("on");
        if (request.idle() && !installed && !current.startsWith("failed")) { state = "off"; return; }
        // No screen shader yet (still loading): look again a couple of times a second, not every frame.
        if (current.equals("waiting") && (frames & 31) != 0) return;
        // In place and unchanged. Every so often the render thread confirms it, in case the game swapped its shader object.
        if (installed && key.equals(appliedKey) && !replacedByGame() && (frames & 1023) != 0) return;
        if (!request.idle() && key.equals(failedFor)) {
            // The same request on the same shader failed; asking again every frame would only stutter.
            if (System.nanoTime() < nextAttemptNanos) return;
        }
        if (!busy.compareAndSet(false, true)) return;
        final String target = key;
        try {
            platform.onRenderThread(() -> {
                try { reconcile(target); }
                finally { busy.set(false); }
            });
        } catch (Throwable failure) {
            busy.set(false);
            fail(target, "queue:" + failure.getClass().getSimpleName());
        }
    }

    /** Whether the game has put another program in place of ours (it recompiled its shader). */
    private boolean replacedByGame() {
        Object current = lastProgram;
        if (current == null) return false;
        try { return platform.programId(current) != installedIdSeen; }
        catch (Throwable unknown) { return false; }
    }

    /**
     * Any thread, never blocks: the grade must not outlive the activation that asked for it. The
     * actual switch back happens on the render thread shortly after.
     */
    public void stop() {
        stopped = true;
        wanted = GradeParameters.Request.OFF;
        try { platform.onRenderThread(this::remove); }
        catch (Throwable unavailable) { state = "stopped-unrestored"; }
    }

    // ---- Render thread ----

    private void reconcile(String key) {
        GradeParameters.Request request = wanted;
        try {
            if (stopped || request.idle()) { remove(); if (!stopped) { state = "off"; appliedKey = null; } return; }
            Object current = platform.program();
            if (current == null || !platform.compiled(current)) { state = "waiting"; return; }
            Graphics gl = platform.graphics();
            int currentId = platform.programId(current);
            if (program != current || currentId != gradedId) {
                // First time, or the game built itself a new program. Ours went with the old one.
                if (gradedId != 0 && baseId != 0 && baseId != currentId && gl.alive(baseId)) { platform.forget(program, baseId); gl.deleteProgram(baseId); }
                program = current; baseId = currentId; gradedId = 0; gradedSource = null;
            }
            // Always derived from the original, never from an earlier grade.
            int[] shaders = gl.attachedShaders(baseId);
            int entry = 0; String original = null;
            for (int shader : shaders) {
                if (!gl.fragment(shader)) continue;
                String text = gl.source(shader);
                if (text != null && GradeShader.definesMain(text)) {
                    if (entry != 0) throw new IllegalArgumentException("several-entry-points");
                    entry = shader; original = text;
                }
            }
            if (entry == 0) throw new IllegalArgumentException("entry-shader-not-found");
            GradeShader.Result graded = GradeShader.transform(original, GradeParameters.of(request, season));
            if (gradedId != 0 && graded.source().equals(gradedSource)) { installed(current, key, graded); return; }

            int fragment = gl.compileFragment(graded.source());
            if (fragment == 0) throw new IllegalStateException("compile:" + brief(gl.lastLog()));
            int next;
            try {
                int[] parts = new int[shaders.length];
                for (int i = 0; i < shaders.length; i++) parts[i] = shaders[i] == entry ? fragment : shaders[i];
                next = gl.link(parts, baseId);
            } finally { gl.deleteShader(fragment); } // Stays alive for as long as a program holds it.
            if (next == 0) throw new IllegalStateException("link:" + brief(gl.lastLog()));

            int previous = gradedId;
            try { platform.adopt(current, next); }
            catch (Throwable rejected) {
                // Back to a program the game is known to work with, before anything is drawn with the new one.
                platform.adopt(current, previous != 0 ? previous : baseId);
                platform.forget(current, next);
                gl.deleteProgram(next);
                throw rejected;
            }
            gradedId = next; gradedSource = graded.source();
            if (previous != 0) { platform.forget(current, previous); gl.deleteProgram(previous); }
            installed(current, key, graded);
            if (stopped) remove();
        } catch (Throwable failure) {
            String reason = failure instanceof IllegalArgumentException || failure instanceof IllegalStateException
                ? String.valueOf(failure.getMessage()) : failure.getClass().getSimpleName();
            fail(key, reason);
        }
    }

    private void installed(Object current, String key, GradeShader.Result graded) {
        lastProgram = current; installedIdSeen = gradedId; appliedKey = key; failedFor = null;
        state = "on";
        detail = (graded.clarity() ? "clarity" : "no-clarity") + (graded.nightAware() ? ",night" : "") + (graded.outdoorsAware() ? ",outdoors" : "");
    }
    /** Which optional parts the installed grade has; for diagnostics. */
    public String detail() { return detail; }

    private void fail(String key, String reason) {
        failedFor = key; nextAttemptNanos = System.nanoTime() + 30_000_000_000L;
        appliedKey = null;
        state = "failed:" + reason;
    }

    /** Switches the game back to its own program if ours is in place, and frees ours. Idempotent. */
    private void remove() {
        try {
            if (program == null || gradedId == 0) return;
            Graphics gl = platform.graphics();
            int currentId = platform.programId(program);
            if (currentId == gradedId) {
                platform.adopt(program, baseId);
                platform.forget(program, gradedId);
                gl.deleteProgram(gradedId);
            } else if (baseId != currentId && gl.alive(baseId)) {
                // The game replaced and freed ours already; the program it was built from is nobody's now.
                platform.forget(program, baseId);
                gl.deleteProgram(baseId);
            }
            if (stopped) state = "stopped";
        } catch (Throwable failure) {
            state = "failed:restore:" + failure.getClass().getSimpleName();
        } finally { gradedId = 0; gradedSource = null; lastProgram = null; program = null; baseId = 0; }
    }

    private static String brief(String log) {
        if (log == null) return "";
        String line = log.strip().replace('\r', ' ').replace('\n', ' ').replace(';', ',');
        return line.length() <= 120 ? line : line.substring(0, 120);
    }

    // ---- The game and the graphics library, by reflection ----

    /** Resolves everything up front; throws when the game no longer has what is needed. */
    public static Platform resolve(ClassLoader game) throws ReflectiveOperationException {
        Class<?> store = Class.forName("zombie.core.SceneShaderStore", false, game);
        Class<?> shader = Class.forName("zombie.core.opengl.Shader", false, game);
        Class<?> programType = Class.forName("zombie.core.opengl.ShaderProgram", false, game);
        Class<?> renderThread = Class.forName("zombie.core.opengl.RenderThread", false, game);
        Class<?> climate = Class.forName("zombie.iso.weather.ClimateManager", false, game);
        Class<?> seasonType = Class.forName("zombie.erosion.season.ErosionSeason", false, game);
        Class<?> registerType = Class.forName("zombie.core.opengl.ShaderPrograms", false, game);
        MethodHandles.Lookup lookup = MethodHandles.lookup();

        Field screen = store.getField("weatherShader");
        if (!Modifier.isStatic(screen.getModifiers()) || screen.getType() != shader) throw new NoSuchFieldException("SceneShaderStore.weatherShader");
        MethodHandle getProgram = handle(lookup, shader, "getShaderProgram", programType);
        MethodHandle isCompiled = handle(lookup, programType, "isCompiled", boolean.class);
        MethodHandle end = handle(lookup, programType, "End", void.class);
        MethodHandle relook = handle(lookup, programType, "onCompileSuccess", void.class);
        MethodHandle announce = handle(lookup, programType, "invokeProgramCompiledEvent", void.class);
        Field idField = programType.getDeclaredField("shaderId");
        if (idField.getType() != int.class || Modifier.isStatic(idField.getModifiers()) || Modifier.isFinal(idField.getModifiers()))
            throw new NoSuchFieldException("ShaderProgram.shaderId");
        VarHandle id = MethodHandles.privateLookupIn(programType, lookup).unreflectVarHandle(idField);
        Method queue = renderThread.getMethod("queueInvokeOnRenderContext", Runnable.class);
        if (!Modifier.isStatic(queue.getModifiers())) throw new NoSuchMethodException("RenderThread.queueInvokeOnRenderContext");
        MethodHandle enqueue = lookup.unreflect(queue);
        MethodHandle climateInstance = lookup.unreflect(staticMethod(climate, "getInstance", climate)).asType(MethodType.methodType(Object.class));
        MethodHandle getSeason = handle(lookup, climate, "getSeason", seasonType);
        MethodHandle seasonNumber = handle(lookup, seasonType, "getSeason", int.class);
        // The game draws a program only after finding it by number in this register: that is where the
        // screen's ModelViewProjection comes from (ShaderHelper.setModelViewProjection). ShaderProgram.compile
        // files each program it links; a program linked here must be filed the same way, or the screen quad is
        // drawn with no projection at all and the last picture stays on screen.
        MethodHandle registry = lookup.unreflect(staticMethod(registerType, "getInstance", registerType)).asType(MethodType.methodType(Object.class));
        MethodHandle register = lookup.unreflect(instanceMethod(registerType, "registerProgram", void.class, programType));
        MethodHandle filedUnder = lookup.unreflect(instanceMethod(registerType, "getProgramByID", programType, int.class));
        Field byNumber = registerType.getDeclaredField("programById");
        MethodHandle numbers = MethodHandles.privateLookupIn(registerType, lookup).unreflectGetter(byNumber);
        MethodHandle unfile = lookup.unreflect(byNumber.getType().getMethod("remove", int.class));
        // The game sends a program its ModelViewProjection only when the matrices differ from the last ones it sent
        // to that ShaderProgram object (VertexBufferObject.setModelViewProjection). Ours reuses the game's object,
        // whose remembered matrices already equal the screen's, which never change: without forgetting them the
        // new program never receives a projection at all. ShaderProgram.compile forgets them the same way.
        Field modelViewField = programType.getField("modelView"), projectionField = programType.getField("projection");
        if (modelViewField.getType() != projectionField.getType() || Modifier.isStatic(modelViewField.getModifiers())
            || Modifier.isStatic(projectionField.getModifiers())) throw new NoSuchFieldException("ShaderProgram.modelView/projection");
        MethodHandle modelView = lookup.unreflectGetter(modelViewField), projection = lookup.unreflectGetter(projectionField);
        Method zeroMethod = modelViewField.getType().getMethod("zero");
        if (Modifier.isStatic(zeroMethod.getModifiers())) throw new NoSuchMethodException("Matrix4f.zero");
        MethodHandle zero = lookup.unreflect(zeroMethod);
        Graphics graphics = new DriverGraphics(game);

        return new Platform() {
            @Override public Object program() throws Throwable {
                Object holder = screen.get(null);
                return holder == null ? null : (Object)getProgram.invoke(holder);
            }
            @Override public int programId(Object program) { return (int)id.get(program); }
            @Override public boolean compiled(Object program) throws Throwable { return (boolean)isCompiled.invoke(program); }
            @Override public void adopt(Object program, int programId) throws Throwable {
                id.set(program, programId);
                register.invoke(registry.invoke(), program);
                // All zeros is never a real transform, so the next draw sends the projection to this program.
                zero.invoke(modelView.invoke(program));
                zero.invoke(projection.invoke(program));
                try {
                    // What the game itself does after linking a shader: collect the uniforms, then tell the shader's owners.
                    relook.invoke(program);
                    announce.invoke(program);
                } finally { end.invoke(program); }
            }
            @Override public void forget(Object program, int programId) throws Throwable {
                Object programs = registry.invoke();
                // Only our own filing: the game may already have given the number to a program of its own.
                if ((Object)filedUnder.invoke(programs, programId) == program) unfile.invoke(numbers.invoke(programs), programId);
            }
            @Override public int season() throws Throwable {
                Object manager = (Object)climateInstance.invoke();
                Object current = manager == null ? null : (Object)getSeason.invoke(manager);
                return current == null ? 0 : (int)seasonNumber.invoke(current);
            }
            @Override public void onRenderThread(Runnable task) throws Throwable { enqueue.invoke(task); }
            @Override public Graphics graphics() { return graphics; }
        };
    }

    private static Method staticMethod(Class<?> type, String name, Class<?> result) throws NoSuchMethodException {
        Method method = type.getMethod(name);
        if (!Modifier.isStatic(method.getModifiers()) || method.getReturnType() != result) throw new NoSuchMethodException(type.getName() + "." + name);
        return method;
    }
    private static Method instanceMethod(Class<?> type, String name, Class<?> result, Class<?> parameter) throws NoSuchMethodException {
        Method method = type.getMethod(name, parameter);
        if (Modifier.isStatic(method.getModifiers()) || method.getReturnType() != result) throw new NoSuchMethodException(type.getName() + "." + name);
        return method;
    }
    private static MethodHandle handle(MethodHandles.Lookup lookup, Class<?> type, String name, Class<?> result) throws ReflectiveOperationException {
        Method method;
        try { method = type.getMethod(name); } catch (NoSuchMethodException hidden) { method = type.getDeclaredMethod(name); }
        if (method.getReturnType() != result || Modifier.isStatic(method.getModifiers())) throw new NoSuchMethodException(type.getName() + "." + name);
        return MethodHandles.privateLookupIn(method.getDeclaringClass(), lookup).unreflect(method);
    }

    /** The driver through the graphics library the game ships; only valid on a thread that owns the context. */
    static final class DriverGraphics implements Graphics {
        private static final int FRAGMENT_SHADER = 0x8B30, SHADER_TYPE = 0x8B4F, COMPILE_STATUS = 0x8B81, LINK_STATUS = 0x8B82,
            ATTACHED_SHADERS = 0x8B85, ACTIVE_ATTRIBUTES = 0x8B89;
        private final MethodHandle createShader, shaderSource, compileShader, getShaderi, shaderLog, createProgram, attachShader,
            bindAttribute, linkProgram, getProgrami, programLog, deleteShader, deleteProgram, attached, getSource, activeAttribute,
            attributeLocation, isProgram;
        private String log = "";

        DriverGraphics(ClassLoader game) throws ReflectiveOperationException {
            Class<?> gl = Class.forName("org.lwjgl.opengl.GL20", false, game);
            MethodHandles.Lookup lookup = MethodHandles.publicLookup();
            createShader = lookup.findStatic(gl, "glCreateShader", MethodType.methodType(int.class, int.class));
            shaderSource = lookup.findStatic(gl, "glShaderSource", MethodType.methodType(void.class, int.class, CharSequence.class));
            compileShader = lookup.findStatic(gl, "glCompileShader", MethodType.methodType(void.class, int.class));
            getShaderi = lookup.findStatic(gl, "glGetShaderi", MethodType.methodType(int.class, int.class, int.class));
            shaderLog = lookup.findStatic(gl, "glGetShaderInfoLog", MethodType.methodType(String.class, int.class));
            createProgram = lookup.findStatic(gl, "glCreateProgram", MethodType.methodType(int.class));
            attachShader = lookup.findStatic(gl, "glAttachShader", MethodType.methodType(void.class, int.class, int.class));
            bindAttribute = lookup.findStatic(gl, "glBindAttribLocation", MethodType.methodType(void.class, int.class, int.class, CharSequence.class));
            linkProgram = lookup.findStatic(gl, "glLinkProgram", MethodType.methodType(void.class, int.class));
            getProgrami = lookup.findStatic(gl, "glGetProgrami", MethodType.methodType(int.class, int.class, int.class));
            programLog = lookup.findStatic(gl, "glGetProgramInfoLog", MethodType.methodType(String.class, int.class));
            deleteShader = lookup.findStatic(gl, "glDeleteShader", MethodType.methodType(void.class, int.class));
            deleteProgram = lookup.findStatic(gl, "glDeleteProgram", MethodType.methodType(void.class, int.class));
            attached = lookup.findStatic(gl, "glGetAttachedShaders", MethodType.methodType(void.class, int.class, int[].class, int[].class));
            getSource = lookup.findStatic(gl, "glGetShaderSource", MethodType.methodType(String.class, int.class));
            activeAttribute = lookup.findStatic(gl, "glGetActiveAttrib", MethodType.methodType(String.class, int.class, int.class, IntBuffer.class, IntBuffer.class));
            attributeLocation = lookup.findStatic(gl, "glGetAttribLocation", MethodType.methodType(int.class, int.class, CharSequence.class));
            isProgram = lookup.findStatic(gl, "glIsProgram", MethodType.methodType(boolean.class, int.class));
        }

        @Override public int[] attachedShaders(int program) throws Throwable {
            int count = (int)getProgrami.invokeExact(program, ATTACHED_SHADERS);
            if (count <= 0 || count > 64) return new int[0];
            int[] actual = new int[1], shaders = new int[count];
            attached.invokeExact(program, actual, shaders);
            return actual[0] == count ? shaders : java.util.Arrays.copyOf(shaders, Math.max(0, Math.min(count, actual[0])));
        }
        @Override public boolean fragment(int shader) throws Throwable { return (int)getShaderi.invokeExact(shader, SHADER_TYPE) == FRAGMENT_SHADER; }
        @Override public String source(int shader) throws Throwable { return (String)getSource.invokeExact(shader); }
        @Override public int compileFragment(String source) throws Throwable {
            int shader = (int)createShader.invokeExact(FRAGMENT_SHADER);
            if (shader == 0) { log = "no shader object"; return 0; }
            shaderSource.invokeExact(shader, (CharSequence)source);
            compileShader.invokeExact(shader);
            if ((int)getShaderi.invokeExact(shader, COMPILE_STATUS) != 0) return shader;
            log = (String)shaderLog.invokeExact(shader);
            deleteShader.invokeExact(shader);
            return 0;
        }
        @Override public int link(int[] shaders, int like) throws Throwable {
            int program = (int)createProgram.invokeExact();
            if (program == 0) { log = "no program object"; return 0; }
            for (int shader : shaders) attachShader.invokeExact(program, shader);
            // The game's vertex data is laid out for the original program; keep every attribute where it was.
            int attributes = (int)getProgrami.invokeExact(like, ACTIVE_ATTRIBUTES);
            IntBuffer size = buffer(), type = buffer();
            List<String> names = new ArrayList<>();
            for (int index = 0; index < attributes && index < 64; index++) {
                String name = (String)activeAttribute.invokeExact(like, index, size, type);
                if (name != null && !name.isEmpty() && !name.startsWith("gl_")) names.add(name);
            }
            for (String name : names) {
                int location = (int)attributeLocation.invokeExact(like, (CharSequence)name);
                if (location >= 0) bindAttribute.invokeExact(program, location, (CharSequence)name);
            }
            linkProgram.invokeExact(program);
            if ((int)getProgrami.invokeExact(program, LINK_STATUS) != 0) return program;
            log = (String)programLog.invokeExact(program);
            deleteProgram.invokeExact(program);
            return 0;
        }
        @Override public boolean alive(int program) throws Throwable { return program != 0 && (boolean)isProgram.invokeExact(program); }
        @Override public void deleteProgram(int program) throws Throwable { if (program != 0) deleteProgram.invokeExact(program); }
        @Override public void deleteShader(int shader) throws Throwable { if (shader != 0) deleteShader.invokeExact(shader); }
        @Override public String lastLog() { return log; }
        private static IntBuffer buffer() { return ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder()).asIntBuffer(); }
    }
}
