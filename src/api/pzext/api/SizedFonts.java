package pzext.api;

import java.io.File;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import pzext.boot.Boot;

/**
 * Text a mod draws in its own windows at a height in pixels ({@code PZExtAPI.text.font}, {@code fontHeight}, {@code measure}
 * and {@code draw}; docs/design.md, "Text at a height"). The game has each language's bitmap fonts made for every
 * font size option ({@code media/fonts/<language>/1x} to {@code 4x}, and for the smallest option the fonts' own folder) but loads
 * the option's alone. This lists the language's {@code Small}, {@code Medium} and {@code Large} of every option as the game's
 * {@code TextManager.Init} names them (its {@code fonts.txt}, folders and fallbacks, through the game's file system, so a font
 * mod is followed where the game would follow it), and draws a height with the one whose line is nearest, loaded as the game
 * loads its own when a height first asks for it. A height well above the tallest is drawn in the embedded font at that height.
 *
 * <p>Everything here runs on the game's main thread, as the mods' calls do. The fonts are listed again when the game makes its
 * own again (its {@code Small} is another object): the keys stay, their fonts are chosen again. Fonts this loaded are kept in the
 * bootstrap's kept objects for the next Lua environment and API; those the language can no longer choose are let go. The game's
 * own fonts are used where they are the one chosen, and never let go here.
 */
final class SizedFonts {
    /** The tallest line a mod may ask for, in pixels. */
    static final int MAX = 1024;
    /** How much taller than the tallest of the language's fonts a line must be to be drawn in the embedded font: an eighth. */
    static final double ABOVE = 1.125;
    static final String[] SLOTS = { "Small", "Medium", "Large" };
    /** The folder of each font size option, 1 to 5, as {@code TextManager.Init} has it: the smallest is the fonts' own folder. */
    static final String[] FOLDERS = { null, "1x", "2x", "3x", "4x" };
    private static final String KEPT = "extension-api-sized-fonts";
    // The game's distance-field fonts' edge: 0.125 / zoom (AtomUIText).
    private static final float SDF_EDGE = 0.125f;

    /** One of the language's fonts: its files as the game names them, its line's height, and the game's AngelCodeFont once loaded. */
    static final class Face {
        final String fnt, img, key;
        final boolean sdf;
        final int order;
        int height;
        // The AngelCodeFont, null until loaded; whether it is the game's own (never let go here); whether its pictures are in.
        Object font;
        boolean game, ready, dropped;
        // When this loaded it (System.nanoTime), for the log line once its pictures are in; 0 when it did not.
        long loadedAt;

        Face(String fnt, String img, String key, boolean sdf, int order) { this.fnt = fnt; this.img = img; this.key = key; this.sdf = sdf; this.order = order; }
    }

    /**
     * What a height is drawn with: a face at its own size, or, above the tallest, the embedded font at the height, and where that
     * cannot draw a text the tallest face zoomed to it. The height a mod lays its lines out with.
     */
    static final class Choice {
        Face face;
        boolean large;
        int height;
    }

    private final Object textManager, small, medium, large;
    // TextManager.getFontFromEnum; new AngelCodeFont(fnt, img), setSdf, getLineHeight, getWidth, drawString without and with a
    // zoom, isLoading, destroy.
    private final MethodHandle fontOf, make, setSdf, lineHeight, width, drawPlain, drawZoomed, loading, destroy;
    // AngelCodeFont.fntFile (private): the file a game's font was read from; null in a game without it (its fonts are not shared).
    private final Field fntFile;
    private final Constructor<?> fontsFile;
    private final Method readFonts, language, core, dyslexic;
    private final Field fileFnt, fileImg, fileType;
    private final Object fileSystem;
    private final MethodHandle getString;
    // TextManager.sdfShader; SDFShader.updateThreshold, updateShadow, updateOutline; IndieGL.StartShader, EndShader.
    private final Field sdfShader;
    private final MethodHandle threshold, shaderShadow, shaderOutline, startShader, endShader;

    // The game's Small when the faces were listed; the faces by height (a loaded one first among those of one height); the tallest.
    private Object stamp;
    private Face[] faces = new Face[0];
    private int tallest;
    // The choice for each height, made when it is first asked for after the faces were listed.
    private final Choice[] choices = new Choice[MAX + 1];
    private boolean reported;

    SizedFonts(ClassLoader loader, Object textManager) throws ReflectiveOperationException {
        this.textManager = textManager;
        Class<?> uiFont = Game.type(loader, "zombie.ui.UIFont"), manager = Game.type(loader, "zombie.ui.TextManager");
        small = constant(uiFont, "Small");
        medium = constant(uiFont, "Medium");
        large = constant(uiFont, "Large");
        fontOf = Game.exact(manager.getMethod("getFontFromEnum", uiFont), MethodType.methodType(Object.class, Object.class, Object.class));
        Class<?> font = Game.type(loader, "zombie.core.fonts.AngelCodeFont");
        var lookup = MethodHandles.publicLookup();
        make = lookup.findConstructor(font, MethodType.methodType(void.class, String.class, String.class))
            .asType(MethodType.methodType(Object.class, String.class, String.class));
        setSdf = Game.exact(font.getMethod("setSdf", boolean.class), MethodType.methodType(void.class, Object.class, boolean.class));
        lineHeight = Game.exact(font.getMethod("getLineHeight"), MethodType.methodType(int.class, Object.class));
        width = Game.exact(font.getMethod("getWidth", String.class), MethodType.methodType(int.class, Object.class, String.class));
        drawPlain = Game.exact(font.getMethod("drawString", float.class, float.class, String.class, float.class, float.class, float.class, float.class),
            MethodType.methodType(void.class, Object.class, float.class, float.class, String.class, float.class, float.class, float.class, float.class));
        drawZoomed = Game.exact(font.getMethod("drawString", float.class, float.class, float.class, String.class, float.class, float.class, float.class,
            float.class), MethodType.methodType(void.class, Object.class, float.class, float.class, float.class, String.class, float.class, float.class,
            float.class, float.class));
        loading = Game.exact(font.getMethod("isLoading"), MethodType.methodType(boolean.class, Object.class));
        destroy = Game.exact(font.getMethod("destroy"), MethodType.methodType(void.class, Object.class));
        Field file;
        try { file = Game.accessible(font.getDeclaredField("fntFile")); }
        catch (NoSuchFieldException | RuntimeException unreadable) { file = null; }
        fntFile = file != null && file.getType() == File.class ? file : null;
        Class<?> fontsType = Game.type(loader, "zombie.ui.FontsFile"), entry = Game.type(loader, "zombie.ui.FontsFileFont");
        fontsFile = fontsType.getConstructor();
        readFonts = fontsType.getMethod("read", String.class, HashMap.class);
        fileFnt = entry.getField("fnt");
        fileImg = entry.getField("img");
        fileType = entry.getField("type");
        language = Game.type(loader, "zombie.core.Translator").getMethod("getLanguage");
        Class<?> coreType = Game.type(loader, "zombie.core.Core");
        core = coreType.getMethod("getInstance");
        Method option;
        try { option = coreType.getMethod("getOptionEnableDyslexicFont"); }
        catch (NoSuchMethodException none) { option = null; } // A game without the option: the usual fonts.
        dyslexic = option;
        Class<?> files = Game.type(loader, "zombie.ZomboidFileSystem");
        fileSystem = files.getField("instance").get(null);
        getString = Game.exact(files.getMethod("getString", String.class), MethodType.methodType(String.class, Object.class, String.class));
        sdfShader = manager.getField("sdfShader");
        Class<?> distance = Game.type(loader, "zombie.core.opengl.SDFShader"), shader = Game.type(loader, "zombie.core.opengl.Shader");
        threshold = Game.exact(distance.getMethod("updateThreshold", float.class), MethodType.methodType(void.class, Object.class, float.class));
        shaderShadow = Game.exact(distance.getMethod("updateShadow", float.class), MethodType.methodType(void.class, Object.class, float.class));
        shaderOutline = Game.exact(distance.getMethod("updateOutline", float.class, float.class, float.class, float.class, float.class),
            MethodType.methodType(void.class, Object.class, float.class, float.class, float.class, float.class, float.class));
        Class<?> indie = Game.type(loader, "zombie.IndieGL");
        startShader = Game.exact(indie.getMethod("StartShader", shader), MethodType.methodType(void.class, Object.class));
        endShader = Game.exact(indie.getMethod("EndShader"), MethodType.methodType(void.class));
    }

    private static Object constant(Class<?> type, String name) {
        for (Object constant : type.getEnumConstants()) if (((Enum<?>)constant).name().equals(name)) return constant;
        throw new IllegalStateException("the game has no font " + name);
    }

    // ---- the calls ----

    /**
     * {@code text.font}: whether there is a font for the height; it is chosen and loaded now, so that the mod's first frame does
     * not wait for it. Above the tallest, the tallest is loaded too while the embedded font cannot draw ({@code own} null).
     */
    boolean prepare(int px, EmbeddedFont.Loaded own) throws Throwable {
        Choice choice = choice(px);
        if (choice == null) return false;
        if (choice.large && own == null) fallback(choice);
        return true;
    }

    /** {@code text.fontHeight}: the height of a line to lay out with, as {@code getFontHeight} is for the game's fonts; 0 for none. */
    int height(int px) throws Throwable {
        Choice choice = choice(px);
        return choice == null ? 0 : choice.height;
    }

    /**
     * {@code text.measure}: the width in pixels of the text as {@link #draw} draws it, as {@code MeasureStringX} is for the
     * game's fonts (a zoomed width rounded up). {@code own} is the embedded font when it can draw this frame, else null.
     * Allocates nothing.
     */
    int measure(int px, String text, EmbeddedFont.Loaded own) throws Throwable {
        Choice choice = choice(px);
        if (choice == null || text.isEmpty()) return 0;
        if (choice.large) {
            if (own != null && own.covers(text)) return zoomed((int)width.invokeExact(own.font, text), px / (double)own.lineHeight);
            Face face = fallback(choice);
            return face == null ? 0 : zoomed((int)width.invokeExact(face.font, text), px / (double)face.height);
        }
        Face face = choice.face;
        int measured = (int)width.invokeExact(face.font, text);
        return face.sdf ? zoomed(measured, px / (double)face.height) : measured;
    }

    private static int zoomed(int width, double zoom) { return (int)Math.ceil(width * zoom - 1e-6); }

    /**
     * {@code text.draw}: the text with its top left at {@code x}, {@code y} on the screen, in the font {@link #measure} measures
     * it with, through the game's drawing (so in the order and inside the clip of the window that draws it). A bitmap font at its
     * own size is drawn as the game's {@code DrawText} draws, the embedded font (and a distance-field one) inside the game's
     * shader. Nothing is drawn while the font's pictures are still loading. Allocates nothing.
     */
    void draw(int px, String text, double x, double y, float red, float green, float blue, float alpha, EmbeddedFont.Loaded own) throws Throwable {
        Choice choice = choice(px);
        if (choice == null || text.isEmpty()) return;
        if (choice.large && own != null && own.covers(text)) {
            float zoom = (float)(px / (double)own.lineHeight);
            shaded(own.font, x, y, zoom, text, red, green, blue, alpha, (float)(EmbeddedFont.EDGE / (2 * own.spread * zoom)));
            return;
        }
        Face face = choice.large ? fallback(choice) : choice.face;
        if (face == null || !ready(face)) return;
        if (!choice.large && !face.sdf) {
            drawPlain.invokeExact(face.font, (float)x, (float)y, text, red, green, blue, alpha);
            return;
        }
        float zoom = (float)(px / (double)face.height);
        if (face.sdf) shaded(face.font, x, y, zoom, text, red, green, blue, alpha, SDF_EDGE / zoom);
        else drawZoomed.invokeExact(face.font, (float)x, (float)y, zoom, text, red, green, blue, alpha);
    }

    /** A distance-field font through the game's shader, as the API's titles and the game's AtomUIText draw: no shadow or outline. */
    private void shaded(Object font, double x, double y, float zoom, String text, float red, float green, float blue, float alpha, float edge) throws Throwable {
        Object shader = sdfShader.get(null);
        if (shader == null) return; // The game has not made it yet: a distance field drawn without it is a blur.
        threshold.invokeExact(shader, edge);
        shaderShadow.invokeExact(shader, 0f);
        shaderOutline.invokeExact(shader, 0f, 0f, 0f, 0f, 0f);
        startShader.invokeExact(shader);
        try { drawZoomed.invokeExact(font, (float)x, (float)y, zoom, text, red, green, blue, alpha); }
        finally { endShader.invokeExact(); }
    }

    /** Whether the face's pictures are in (the game loads them on its file thread); once they are, the answer is kept. */
    private boolean ready(Face face) throws Throwable {
        if (face.ready) return true;
        if ((boolean)loading.invokeExact(face.font)) return false;
        face.ready = true;
        if (face.loadedAt != 0)
            System.out.println("[PZExt] text: the pictures of " + face.fnt + " are in, " + (System.nanoTime() - face.loadedAt) / 1_000_000 + " ms after it was read");
        return true;
    }

    // ---- the choice ----

    /** The choice for a height, made when first asked for; the faces are listed again first when the game made its fonts again. */
    Choice choice(int px) throws Throwable {
        Object current = (Object)fontOf.invokeExact(textManager, small);
        if (current != stamp) list(current);
        Choice choice = choices[px];
        if (choice == null && faces.length > 0) choice = choices[px] = choose(px);
        return choice;
    }

    /**
     * The face nearest the height (of two as near, the smaller: it does not overflow what the mod laid out; of one height, a
     * loaded one), loaded; above the tallest by more than an eighth, the large choice of the height itself. Null when no face
     * can be read.
     */
    private Choice choose(int px) throws Throwable {
        while (faces.length > 0) {
            var choice = new Choice();
            if (px > tallest * ABOVE) {
                choice.large = true;
                choice.face = tallestFace();
                choice.height = px;
                return choice;
            }
            Face best = null;
            for (Face face : faces) if (best == null || Math.abs(face.height - px) < Math.abs(best.height - px)) best = face;
            if (!load(best)) continue;
            choice.face = best;
            choice.height = best.sdf ? px : best.height;
            return choice;
        }
        return null;
    }

    /** The face a large choice draws a text with that the embedded font cannot: the tallest, loaded now if it was not. */
    private Face fallback(Choice choice) throws Throwable {
        Face face = choice.face;
        while (face != null && (face.dropped || face.font == null)) {
            if (!face.dropped && load(face)) break;
            face = choice.face = tallestFace();
        }
        return face;
    }

    private Face tallestFace() {
        for (Face face : faces) if (face.height == tallest) return face;
        return null;
    }

    /**
     * Reads the face's font as {@code TextManager.Init} reads the game's: {@code new AngelCodeFont(fnt, img)}, on this thread (the
     * text file), its pictures through the game's shared textures (read on the game's file thread, sent by its render thread), and
     * marked a distance-field font when {@code fonts.txt} says so. One the kept objects have is taken from there. A face that
     * cannot be read is dropped, reported once.
     */
    private boolean load(Face face) throws Throwable {
        if (face.font != null) return true;
        Map<String, Object> cache = cache();
        Object kept;
        synchronized (cache) { kept = cache.get(face.key); }
        if (kept == null) {
            long start = System.nanoTime();
            try {
                kept = (Object)make.invokeExact(face.fnt, face.img);
                setSdf.invokeExact(kept, face.sdf);
            } catch (Exception failure) {
                drop(face, failure);
                return false;
            }
            face.loadedAt = start;
            synchronized (cache) { cache.put(face.key, kept); }
            System.out.println("[PZExt] text: read " + face.fnt + " for text.font in " + (System.nanoTime() - start) / 100_000 / 10.0 + " ms");
        }
        face.font = kept;
        int measured = (int)lineHeight.invokeExact(kept);
        if (measured <= 0) {
            drop(face, new IllegalStateException("it has no line height"));
            return false;
        }
        if (measured != face.height) {
            // The text file's header said otherwise: the height is the game's, the tallest is measured again.
            face.height = measured;
            sort();
        }
        return true;
    }

    private void drop(Face face, Exception why) {
        if (!reported) System.err.println("[PZExt] text: " + face.fnt + " cannot be read: " + why);
        reported = true;
        face.dropped = true;
        face.font = null;
        var left = new ArrayList<Face>();
        for (Face other : faces) if (other != face) left.add(other);
        faces = left.toArray(new Face[0]);
        sort();
    }

    /** The faces by height, a loaded one first among those of one height, then in the game's order; the choices made again. */
    private void sort() {
        Arrays.sort(faces, Comparator.<Face>comparingInt(face -> face.height).thenComparing(face -> face.font == null).thenComparingInt(face -> face.order));
        tallest = 0;
        for (Face face : faces) tallest = Math.max(tallest, face.height);
        Arrays.fill(choices, null);
    }

    // ---- the language's fonts ----

    /**
     * Lists the language's Small, Medium and Large for each font size option, as {@code TextManager.Init} would name them were
     * the option that one: the same {@code fonts.txt} (the dyslexic one when that option is on and the language has it, else
     * English's with the language's over it), the same folders and fallbacks, read through the game's file system. A file named
     * twice is one face; one that is not there is left out. A face is the game's own font when the game has it loaded, else one
     * kept from before, else not loaded yet, with the height its text file's header gives. Kept fonts the list no longer has are
     * let go.
     */
    private void list(Object current) throws Throwable {
        stamp = current;
        faces = new Face[0];
        tallest = 0;
        Arrays.fill(choices, null);
        if (current == null) return; // The game has not made its fonts.
        Object languageValue = language.invoke(null);
        if (languageValue == null) return;
        String lang = (String)languageValue.getClass().getMethod("name").invoke(languageValue);
        var entries = new HashMap<String, Object>();
        if (dyslexic != null && Boolean.TRUE.equals(dyslexic.invoke(core.invoke(null))))
            readFonts.invoke(fontsFile.newInstance(), resolve("media/fonts/" + lang + "/fontsDyslexic.txt"), entries);
        if (entries.isEmpty()) {
            readFonts.invoke(fontsFile.newInstance(), resolve("media/fonts/EN/fonts.txt"), entries);
            if (!"EN".equals(lang)) readFonts.invoke(fontsFile.newInstance(), resolve("media/fonts/" + lang + "/fonts.txt"), entries);
        }
        Object[] game = { current, (Object)fontOf.invokeExact(textManager, medium), (Object)fontOf.invokeExact(textManager, large) };
        var found = new LinkedHashMap<String, Face>();
        Map<String, Object> cache = cache();
        int order = 0;
        for (String folder : FOLDERS)
            for (String slot : SLOTS) {
                Object entry = entries.get(slot);
                if (entry == null) continue;
                String fntName = (String)fileFnt.get(entry), imgName = (String)fileImg.get(entry), type = (String)fileType.get(entry);
                if (fntName == null) continue;
                String fnt = path(lang, folder, fntName), img = imgName == null ? null : path(lang, folder, imgName);
                boolean sdf = "sdf".equalsIgnoreCase(type);
                String file = resolve(fnt);
                String key = file + "|" + (img == null ? "" : resolve(img)) + "|" + sdf;
                if (found.containsKey(key) || !new File(file).isFile()) continue;
                var face = new Face(fnt, img, key, sdf, order++);
                for (Object loaded : game)
                    if (loaded != null && fntFile != null && new File(file).equals(fntFile.get(loaded))) {
                        face.font = loaded;
                        face.game = true;
                        break;
                    }
                if (face.font == null) synchronized (cache) { face.font = cache.get(key); }
                face.height = face.font != null ? (int)lineHeight.invokeExact(face.font) : header(Path.of(file));
                // A header without its line: the font is read to know it.
                if (face.height <= 0 && !load(face)) continue;
                found.put(key, face);
            }
        faces = found.values().toArray(new Face[0]);
        sort();
        // Fonts kept for another language, or for files the game no longer has, are let go.
        synchronized (cache) {
            for (var kept = cache.entrySet().iterator(); kept.hasNext();) {
                var entry = kept.next();
                if (found.containsKey(entry.getKey())) continue;
                kept.remove();
                try { destroy.invokeExact(entry.getValue()); }
                catch (Throwable failure) {
                    if (failure instanceof VirtualMachineError fatal) throw fatal;
                    System.err.println("[PZExt] text: a font kept for text.font was not let go: " + failure);
                }
            }
        }
    }

    /**
     * Where the game looks for a font's file for a language and a folder ({@code TextManager.getFontFilePath}): the language's
     * folder for the option, then the language's own folder, then English's two, then the fonts' folder, then {@code media}. A
     * path the game's file system has is taken; the last is taken as it is.
     */
    private String path(String lang, String folder, String name) throws Throwable {
        String path;
        if (folder != null && has(path = "media/fonts/" + lang + "/" + folder + "/" + name)) return path;
        if (has(path = "media/fonts/" + lang + "/" + name)) return path;
        if (!"EN".equals(lang)) {
            if (folder != null && has(path = "media/fonts/EN/" + folder + "/" + name)) return path;
            if (has(path = "media/fonts/EN/" + name)) return path;
        }
        if (has(path = "media/fonts/" + name)) return path;
        return "media/" + name;
    }

    /** As the game asks: the file system gives back the very string it was given for a path it does not have. */
    private boolean has(String path) throws Throwable { return (String)getString.invokeExact(fileSystem, path) != path; }

    private String resolve(String path) throws Throwable { return (String)getString.invokeExact(fileSystem, path); }

    /** The {@code lineHeight} of a font's text file's {@code common} line (its first lines), or 0. */
    static int header(Path fnt) {
        try (var reader = Files.newBufferedReader(fnt, StandardCharsets.ISO_8859_1)) {
            for (int count = 0; count < 4; count++) {
                String line = reader.readLine();
                if (line == null) break;
                if (!line.startsWith("common ")) continue;
                for (String field : line.split(" +"))
                    if (field.startsWith("lineHeight=")) return Integer.parseInt(field.substring(11));
            }
        } catch (java.io.IOException | NumberFormatException unreadable) { }
        return 0;
    }

    /** The fonts this loaded, by file: in the bootstrap's kept objects, so that a later Lua environment or API reads none again. */
    @SuppressWarnings("unchecked")
    private static Map<String, Object> cache() {
        Map<String, Object> kept = Boot.kept();
        synchronized (kept) {
            if (kept.get(KEPT) instanceof Map<?, ?> map) return (Map<String, Object>)map;
            var made = new HashMap<String, Object>();
            kept.put(KEPT, made);
            return made;
        }
    }

    /** The faces as listed now, for the tests. */
    Face[] faces() { return faces.clone(); }
}
