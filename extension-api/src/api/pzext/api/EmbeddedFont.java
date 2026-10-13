package pzext.api;

import java.io.IOException;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import pzext.boot.Boot;

/**
 * The API's embedded font for large text (docs/design.md, "The embedded font"): Noto Sans SemiBold, the language's
 * pack, as a distance-field atlas that the game's own {@code AngelCodeFont} draws through the game's distance-field shader, so
 * that a title 216 pixels high is as sharp as one 33 high.
 *
 * <p>The packs are font files in the version folder ({@code fonts/pzext-font-<pack>.ttf}). A pack is baked once into the cache
 * under the game's user folder ({@code Zomboid/PZExt/fonts/<pack>-<file digest>-v<baker>-<size>-<spread>}) by a process of its
 * own, {@link FontBaker} on the game's Java runtime: nothing of AWT runs in the game. When a Lua environment starts (a loading
 * screen) the current language's bake is put in video memory once, one channel (the shader reads it as alpha through a swizzle),
 * and the copy in memory let go; from then on drawing it costs what the game's own distance-field text does. Until a bake is
 * there, the first start, large text is drawn with the game's font as before. Any failure leaves the game's font.
 */
final class EmbeddedFont {
    /** The distance, in texels, the atlas spans on each side of an edge: about an eighth of the base size, as in the game's own distance-field fonts. */
    static final int SPREAD = 8;

    /**
     * The base size a pack is baked at, in pixels to the em: 64, which keeps the gaps of dense Hangul syllables (뚫, 쐤) clean at 400
     * pixels; 60 for Traditional Chinese, whose 6,100 characters at 64 would need an atlas twice as tall (4096 x 16384).
     */
    static int size(String pack) { return "tc".equals(pack) ? 60 : 64; }
    /** The half width, in screen pixels, of the soft edge the shader draws: {@code threshold = EDGE / (2 * spread * zoom)}. */
    static final double EDGE = 0.75;
    static final String FOLDER = "fonts", CACHE = "PZExt" + java.io.File.separator + "fonts";
    private static final String KEPT = "extension-api-font";
    // OpenGL.
    private static final int TEXTURE_2D = 0x0DE1, TEXTURE_BINDING_2D = 0x8069, UNPACK_ALIGNMENT = 0x0CF5, UNPACK_ROW_LENGTH = 0x0CF2,
        UNPACK_SKIP_ROWS = 0x0CF3, UNPACK_SKIP_PIXELS = 0x0CF4, PIXEL_UNPACK_BUFFER = 0x88EC, PIXEL_UNPACK_BUFFER_BINDING = 0x88EF,
        RED = 0x1903, R8 = 0x8229, ALPHA = 0x1906, ALPHA8 = 0x803C, UNSIGNED_BYTE = 0x1401, ONE = 1, SWIZZLE_R = 0x8E42,
        SWIZZLE_G = 0x8E43, SWIZZLE_B = 0x8E44, SWIZZLE_A = 0x8E45;
    // The game's Texture flags: made like a frame buffer's (no picture kept in memory, no mipmaps), clamped at its edges.
    private static final int TEXTURE_FLAGS = 0x10 | 0x20;

    /** A pack in video memory, or on its way there: the game's font over it, a line's height and the spread at the base size. */
    static final class Loaded {
        final String name;
        /** The game's {@code AngelCodeFont}; its {@code chars} by character code. */
        final Object font;
        final Object[] chars;
        final int lineHeight, spread;
        /** Set once the atlas is in video memory: until then the game's font draws. */
        final AtomicBoolean ready;

        Loaded(String name, Object font, Object[] chars, int lineHeight, int spread, AtomicBoolean ready) {
            this.name = name; this.font = font; this.chars = chars; this.lineHeight = lineHeight; this.spread = spread; this.ready = ready;
        }

        /** Whether the font has every character of the lines (spaces aside), and the cursor's when there is one. */
        boolean covers(String[] lines, boolean cursor, char cursorLetter) {
            if (cursor && (cursorLetter >= chars.length || chars[cursorLetter] == null)) return false;
            for (String line : lines)
                for (int index = 0; index < line.length(); index++) {
                    char letter = line.charAt(index);
                    if (letter <= ' ') continue;
                    if (letter >= chars.length || chars[letter] == null) return false;
                }
            return true;
        }

        /** Whether the font has every character of the text (spaces aside). Allocates nothing. */
        boolean covers(String text) {
            for (int index = 0; index < text.length(); index++) {
                char letter = text.charAt(index);
                if (letter <= ' ') continue;
                if (letter >= chars.length || chars[letter] == null) return false;
            }
            return true;
        }
    }

    // This API's: the pack loaded, and the bake running (one at a time).
    private static Loaded loaded;
    private static Process baking;
    private static String bakingName;
    private static boolean reported;

    private EmbeddedFont() { }

    /**
     * The pack of the game's language, loaded, or null: none for this language (Thai), no pack file, no bake yet (one is started),
     * or a failure, reported once in the game's log. On the game's thread, as a Lua environment starts.
     */
    static synchronized Loaded current(ClassLoader game) {
        try {
            Object language = Game.type(game, "zombie.core.Translator").getMethod("getLanguage").invoke(null);
            String pack = language == null ? null : pack((String)language.getClass().getMethod("name").invoke(language));
            if (pack == null) return null;
            Path home = Boot.home();
            Path ttf = home.resolve(FOLDER).resolve("pzext-font-" + pack + ".ttf");
            if (!Files.isRegularFile(ttf)) return null;
            String name = name(pack, ttf);
            if (loaded != null && loaded.name.equals(name)) return loaded;
            // A pack an earlier API put in video memory: the same font, kept.
            Map<String, Object> keptMap = Boot.kept();
            Object earlier;
            synchronized (keptMap) { earlier = keptMap.get(KEPT); }
            if (earlier instanceof Object[] kept && kept.length == 6 && name.equals(kept[0]) && kept[2] instanceof Object[] chars) {
                loaded = new Loaded(name, kept[1], chars, (Integer)kept[3], (Integer)kept[4], (AtomicBoolean)kept[5]);
                return loaded;
            }
            Object fileSystem = Game.type(game, "zombie.ZomboidFileSystem").getField("instance").get(null);
            Path cache = Path.of((String)fileSystem.getClass().getMethod("getCacheDir").invoke(fileSystem)).resolve(CACHE);
            if (!baked(cache, name)) {
                if (bake(Path.of(System.getProperty("java.home")), home.resolve(Boot.API_JAR), ttf, cache, name) != null)
                    System.out.println("[PZExt] text: baking the embedded font " + name + " in " + cache + "; the game's font draws large text until a Lua environment starts after it");
                return null;
            }
            long start = System.nanoTime();
            Loaded next = load(game, cache.resolve(name), name);
            System.out.println("[PZExt] text: the embedded font " + name + " read in " + (System.nanoTime() - start) / 100_000 / 10.0 + " ms");
            loaded = next;
            synchronized (keptMap) { keptMap.put(KEPT, new Object[] { name, next.font, next.chars, next.lineHeight, next.spread, next.ready }); }
            return next;
        } catch (Throwable failure) {
            if (failure instanceof VirtualMachineError fatal && !(fatal instanceof OutOfMemoryError)) throw fatal;
            if (!reported) System.err.println("[PZExt] text: the embedded font is not used: " + failure);
            reported = true;
            return null;
        }
    }

    /** The pack for a language of the game (its code, as {@code Translator.getLanguage().name()}); null for one with none. */
    static String pack(String language) {
        return switch (language.toUpperCase(Locale.ROOT)) {
            case "KO" -> "ko";
            case "JP" -> "ja";
            case "CN" -> "sc";
            case "CH" -> "tc";
            // Thai's script is not in the packs: the game's font draws it at every size.
            case "TH" -> null;
            default -> "latin";
        };
    }

    /** The cache's name for a pack: its file's digest, the baker's version, the size and the spread. */
    static String name(String pack, Path ttf) throws IOException {
        try {
            var digest = MessageDigest.getInstance("SHA-256");
            try (var input = Files.newInputStream(ttf)) {
                byte[] buffer = new byte[65536];
                for (int read; (read = input.read(buffer)) > 0;) digest.update(buffer, 0, read);
            }
            return pack + "-" + HexFormat.of().formatHex(digest.digest()).substring(0, 16) + "-v" + FontBaker.VERSION + "-" + size(pack) + "-" + SPREAD;
        } catch (java.security.NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    /** Whether the cache has the bake of that name: its folder is renamed into place only once complete. */
    static boolean baked(Path cache, String name) {
        Path folder = cache.resolve(name);
        return Files.isRegularFile(folder.resolve(FontBaker.FNT)) && Files.isRegularFile(folder.resolve(FontBaker.ATLAS));
    }

    /**
     * Starts the bake in a process of its own on this Java runtime ({@code javaw} on Windows: no console), unless one runs; its
     * output goes to {@code bake-<pack>.log} in the cache. The process, or null when one was running already.
     */
    static synchronized Process bake(Path javaHome, Path jar, Path ttf, Path cache, String name) throws IOException {
        if (baking != null && baking.isAlive()) return null;
        Files.createDirectories(cache);
        boolean windows = System.getProperty("os.name", "").startsWith("Windows");
        Path java = javaHome.resolve("bin").resolve(windows ? "javaw.exe" : "java");
        var builder = new ProcessBuilder(java.toString(), "-Djava.awt.headless=true", "-Xmx768m", "-XX:+UseSerialGC", "-cp", jar.toString(),
            FontBaker.class.getName(), ttf.toString(), cache.toString(), name, name.split("-")[3], Integer.toString(SPREAD));
        builder.redirectErrorStream(true);
        builder.redirectOutput(cache.resolve("bake-" + name.substring(0, name.indexOf('-')) + ".log").toFile());
        builder.redirectInput(ProcessBuilder.Redirect.from(new java.io.File(windows ? "NUL" : "/dev/null")));
        baking = builder.start();
        bakingName = name;
        Process started = baking;
        // A bake that hangs is ended: the next start tries again.
        var watch = new Thread(() -> {
            try { if (!started.waitFor(10, TimeUnit.MINUTES)) started.destroyForcibly(); }
            catch (InterruptedException stopped) { started.destroyForcibly(); }
        }, "PZExt-font-bake");
        watch.setDaemon(true);
        watch.start();
        return started;
    }

    /** The name of the bake running, or null (for the tests). */
    static synchronized String baking() { return baking != null && baking.isAlive() ? bakingName : null; }

    /**
     * Puts a bake in video memory: its atlas read into memory outside the heap, a texture of the game's made of one channel, the
     * picture sent on the render thread (with its swizzle), and the game's font made over it, from the text file. The memory
     * copy is let go once it is sent.
     */
    private static Loaded load(ClassLoader game, Path folder, String name) throws Throwable {
        Path fnt = folder.resolve(FontBaker.FNT);
        Map<String, Integer> header = header(fnt);
        int width = header.get("width"), height = header.get("height"), line = header.get("lineHeight"), spread = header.get("spread");
        if (width <= 0 || height <= 0 || line <= 0 || spread <= 0 || header.get("version") != FontBaker.VERSION) throw new IOException("Bad header in " + fnt);
        ByteBuffer pixels = ByteBuffer.allocateDirect(width * height);
        try (var channel = FileChannel.open(folder.resolve(FontBaker.ATLAS), StandardOpenOption.READ)) {
            if (channel.size() != (long)width * height) throw new IOException("The atlas is " + channel.size() + " bytes, not " + width + " x " + height);
            while (pixels.hasRemaining()) if (channel.read(pixels) < 0) throw new IOException("The atlas ended early");
        }
        pixels.flip();
        Class<?> textureType = Game.type(game, "zombie.core.textures.Texture"), fontType = Game.type(game, "zombie.core.fonts.AngelCodeFont");
        // The game makes the texture's storage on its render thread as it is made (TextureID.generateHwId); the picture follows.
        Object texture = textureType.getConstructor(int.class, int.class, int.class, int.class, int.class).newInstance(width, height, TEXTURE_FLAGS, RED, R8);
        Object id = textureType.getMethod("getTextureId").invoke(texture);
        var ready = new AtomicBoolean();
        Runnable upload = upload(game, id, pixels, width, height, ready);
        Game.type(game, "zombie.core.opengl.RenderThread").getMethod("queueInvokeOnRenderContext", Runnable.class).invoke(null, upload);
        Object font = fontType.getConstructor(String.class, textureType).newInstance(fnt.toString(), texture);
        fontType.getMethod("setSdf", boolean.class).invoke(font, true);
        Object[] chars = (Object[])fontType.getField("chars").get(font);
        return new Loaded(name, font, chars, line, spread, ready);
    }

    /** The {@code pzext} line of a baked text file. */
    static Map<String, Integer> header(Path fnt) throws IOException {
        try (var reader = Files.newBufferedReader(fnt, StandardCharsets.UTF_8)) {
            for (int count = 0; count < 8; count++) {
                String line = reader.readLine();
                if (line == null) break;
                if (!line.startsWith("pzext ")) continue;
                var values = new java.util.HashMap<String, Integer>();
                for (String field : line.substring("pzext ".length()).trim().split(" +")) {
                    int equals = field.indexOf('=');
                    if (equals > 0) values.put(field.substring(0, equals), Integer.parseInt(field.substring(equals + 1)));
                }
                for (String needed : new String[] { "version", "width", "height", "lineHeight", "spread" })
                    if (!values.containsKey(needed)) throw new IOException("No " + needed + " in " + fnt);
                return values;
            }
        }
        throw new IOException("No pzext line in " + fnt);
    }

    /**
     * What the render thread runs once: the picture into the texture the game made for it, one channel read as alpha (a swizzle,
     * OpenGL 3.3; an alpha texture where there is none), the GL state it touched put back. Sets {@code ready} when it worked.
     */
    private static Runnable upload(ClassLoader game, Object id, ByteBuffer pixels, int width, int height, AtomicBoolean ready) throws ReflectiveOperationException {
        Class<?> gl11 = Game.type(game, "org.lwjgl.opengl.GL11"), gl15 = Game.type(game, "org.lwjgl.opengl.GL15"), gl = Game.type(game, "org.lwjgl.opengl.GL");
        Class<?> idType = id.getClass();
        var lookup = java.lang.invoke.MethodHandles.publicLookup();
        MethodHandle getInteger = lookup.findStatic(gl11, "glGetInteger", MethodType.methodType(int.class, int.class));
        MethodHandle bindTexture = lookup.findStatic(gl11, "glBindTexture", MethodType.methodType(void.class, int.class, int.class));
        MethodHandle store = lookup.findStatic(gl11, "glPixelStorei", MethodType.methodType(void.class, int.class, int.class));
        MethodHandle parameter = lookup.findStatic(gl11, "glTexParameteri", MethodType.methodType(void.class, int.class, int.class, int.class));
        MethodHandle subImage = lookup.findStatic(gl11, "glTexSubImage2D", MethodType.methodType(void.class, int.class, int.class, int.class,
            int.class, int.class, int.class, int.class, int.class, ByteBuffer.class));
        MethodHandle image = lookup.findStatic(gl11, "glTexImage2D", MethodType.methodType(void.class, int.class, int.class, int.class,
            int.class, int.class, int.class, int.class, int.class, ByteBuffer.class));
        MethodHandle error = lookup.findStatic(gl11, "glGetError", MethodType.methodType(int.class));
        MethodHandle bindBuffer = lookup.findStatic(gl15, "glBindBuffer", MethodType.methodType(void.class, int.class, int.class));
        MethodHandle capabilities = lookup.findStatic(gl, "getCapabilities", MethodType.methodType(Game.type(game, "org.lwjgl.opengl.GLCapabilities")));
        Field version = Game.type(game, "org.lwjgl.opengl.GLCapabilities").getField("OpenGL33");
        Field swizzleExtension = Game.type(game, "org.lwjgl.opengl.GLCapabilities").getField("GL_ARB_texture_swizzle");
        MethodHandle textureId = lookup.findVirtual(idType, "getID", MethodType.methodType(int.class));
        ByteBuffer[] held = { pixels };
        return () -> {
            ByteBuffer data = held[0];
            held[0] = null;
            if (data == null) return;
            try {
                int texture = (int)textureId.invoke(id);
                if (texture <= 0) throw new IllegalStateException("the game made no texture");
                long start = System.nanoTime();
                for (int drained = 0; drained < 16 && (int)error.invoke() != 0; drained++) { } // Errors before this are not this one's.
                Object caps = capabilities.invoke();
                boolean swizzle = version.getBoolean(caps) || swizzleExtension.getBoolean(caps);
                int bound = (int)getInteger.invoke(TEXTURE_BINDING_2D), buffer = (int)getInteger.invoke(PIXEL_UNPACK_BUFFER_BINDING);
                int alignment = (int)getInteger.invoke(UNPACK_ALIGNMENT), rowLength = (int)getInteger.invoke(UNPACK_ROW_LENGTH);
                int skipRows = (int)getInteger.invoke(UNPACK_SKIP_ROWS), skipPixels = (int)getInteger.invoke(UNPACK_SKIP_PIXELS);
                try {
                    if (buffer != 0) bindBuffer.invoke(PIXEL_UNPACK_BUFFER, 0);
                    store.invoke(UNPACK_ALIGNMENT, 1);
                    store.invoke(UNPACK_ROW_LENGTH, 0);
                    store.invoke(UNPACK_SKIP_ROWS, 0);
                    store.invoke(UNPACK_SKIP_PIXELS, 0);
                    bindTexture.invoke(TEXTURE_2D, texture);
                    if (swizzle) {
                        subImage.invoke(TEXTURE_2D, 0, 0, 0, width, height, RED, UNSIGNED_BYTE, data);
                        parameter.invoke(TEXTURE_2D, SWIZZLE_R, ONE);
                        parameter.invoke(TEXTURE_2D, SWIZZLE_G, ONE);
                        parameter.invoke(TEXTURE_2D, SWIZZLE_B, ONE);
                        parameter.invoke(TEXTURE_2D, SWIZZLE_A, RED);
                    } else image.invoke(TEXTURE_2D, 0, ALPHA8, width, height, 0, ALPHA, UNSIGNED_BYTE, data);
                } finally {
                    bindTexture.invoke(TEXTURE_2D, bound);
                    store.invoke(UNPACK_ALIGNMENT, alignment);
                    store.invoke(UNPACK_ROW_LENGTH, rowLength);
                    store.invoke(UNPACK_SKIP_ROWS, skipRows);
                    store.invoke(UNPACK_SKIP_PIXELS, skipPixels);
                    if (buffer != 0) bindBuffer.invoke(PIXEL_UNPACK_BUFFER, buffer);
                }
                int failed = (int)error.invoke();
                if (failed != 0) throw new IllegalStateException("OpenGL error 0x" + Integer.toHexString(failed));
                ready.set(true);
                System.out.println("[PZExt] text: the embedded font is in video memory, " + width + " x " + height + " in one channel"
                    + (swizzle ? "" : " (an alpha texture: no swizzle)") + ", sent in " + (System.nanoTime() - start) / 100_000 / 10.0 + " ms on the render thread");
            } catch (Throwable failure) {
                System.err.println("[PZExt] text: the embedded font could not be put in video memory: " + failure);
            }
        };
    }
}
