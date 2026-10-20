package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.Arrays;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.function.Consumer;

/**
 * {@code PZExtAPI.draw.rects} and {@code draw.quads}: many rectangles, or many quads of one picture, drawn by one call from a flat
 * array of numbers (docs/design.md, "Drawing many shapes"), for the interface that draws hundreds of them each frame
 * (a ring of dashes, a graph, a grid) and would call {@code drawRect} or {@code DrawTexture} for each. {@code draw.keep},
 * {@code draw.clear} and {@code draw.play}: a window's own draws (pictures and rectangles, texts in the game's fonts and in those
 * {@code text.font} made, lines and clips), kept by a mod as it makes them (a drawing recorded) on a tape that belongs to a Lua table of
 * the mod's, and played back by one call.
 *
 * <p>The shapes are drawn as the game draws them from a window's {@code prerender}, {@code render} or {@code postrender}: a rectangle
 * as {@code UIElement.DrawTextureScaledColor} does ({@code SpriteRenderer.renderi} with no texture at the element's place plus its
 * scroll), a quad as {@code UIElement.DrawTexture} with the four corners does. What a call costs more than the shapes is the element's
 * place, asked once instead of once for each rectangle, and no Lua call for any of them: the numbers are read from the array through
 * a handle that is a constant, and nothing is allocated.
 */
final class Quads {
    /** The numbers a shape takes in its array. */
    static final int RECT = 8, QUAD = 12;
    /**
     * A tape's kinds of draws: a picture scaled and coloured (a rectangle without one), tiled, scaled keeping its aspect; a text in a
     * font {@code text.font} made; a text in one of the game's fonts from its left, its centre, its right, untrimmed; a clip set, taken
     * off, painted back; a line. {@link #KINDS}, the last, is told to the mods ({@code draw.kinds}).
     */
    static final int SCALED = 1, TILED = 2, ASPECT = 3, FACE = 4, TEXT = 5, CENTRE = 6, RIGHT = 7, UNTRIMMED = 8, CLIP = 9, UNCLIP = 10,
        RECLIP = 11, LINE = 12, KINDS = 12;
    /** The most draws a tape keeps. */
    static final int TAPE_MAX = 65536;
    /** The most shapes a call draws. */
    static final int MAX = 16384;
    /** The game keeps a rectangle that starts below this many pixels off the screen (UIElement does the same). */
    private static final int BOTTOM = 4096;
    private static final String AREA = "PZExtAPI.draw.";

    private final Kahlua lua;
    private final Class<?> element, texture, font;
    // UIElement.isVisible(), getAbsoluteX(), getAbsoluteY(), getXScroll(), getYScroll(); the element's javaObject in a Lua window.
    private final MethodHandle visible, absoluteX, absoluteY, scrollX, scrollY;
    // UIElement.DrawTexture(texture, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a).
    private final MethodHandle drawQuad;
    // UIElement.DrawTextureScaledCol, DrawTextureTiled, DrawTextureScaledAspect (texture, x, y, w, h, r, g, b, a): what a tape draws.
    private final MethodHandle drawScaled, drawTiled, drawAspect;
    // UIElement.DrawText, DrawTextCentre, DrawTextRight, DrawTextUntrimmed (font, text, x, y, r, g, b, a).
    private final MethodHandle drawText, drawCentre, drawRight, drawUntrimmed;
    // UIElement.setStencilRect(x, y, w, h), clearStencilRect(), repaintStencilRect(x, y, w, h).
    private final MethodHandle clip, unclip, reclip;
    // UIElement.DrawLine(texture, x, y, x2, y2, thickness, r, g, b, a).
    private final MethodHandle drawLine;
    // SpriteRenderer.instance and renderi(texture, x, y, w, h, r, g, b, a, consumer).
    private final Object sprites;
    private final MethodHandle renderRect;

    Quads(Kahlua lua, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        element = Game.type(loader, "zombie.ui.UIElement");
        texture = Game.type(loader, "zombie.core.textures.Texture");
        font = Game.type(loader, "zombie.ui.UIFont");
        visible = Game.exact(element.getMethod("isVisible"), MethodType.methodType(Boolean.class, Object.class));
        absoluteX = Game.exact(element.getMethod("getAbsoluteX"), MethodType.methodType(Double.class, Object.class));
        absoluteY = Game.exact(element.getMethod("getAbsoluteY"), MethodType.methodType(Double.class, Object.class));
        scrollX = Game.exact(element.getMethod("getXScroll"), MethodType.methodType(Double.class, Object.class));
        scrollY = Game.exact(element.getMethod("getYScroll"), MethodType.methodType(Double.class, Object.class));
        MethodType quad = MethodType.methodType(void.class, Object.class, Object.class, double.class, double.class, double.class, double.class,
            double.class, double.class, double.class, double.class, double.class, double.class, double.class, double.class);
        drawQuad = Game.exact(element.getMethod("DrawTexture", texture, double.class, double.class, double.class, double.class, double.class,
            double.class, double.class, double.class, double.class, double.class, double.class, double.class), quad);
        MethodType eight = MethodType.methodType(void.class, Object.class, Object.class, double.class, double.class, double.class, double.class,
            double.class, double.class, double.class, double.class);
        drawScaled = Game.exact(element.getMethod("DrawTextureScaledCol", texture, double.class, double.class, double.class, double.class,
            double.class, double.class, double.class, double.class), eight);
        drawTiled = Game.exact(element.getMethod("DrawTextureTiled", texture, double.class, double.class, double.class, double.class,
            double.class, double.class, double.class, double.class), eight);
        drawAspect = Game.exact(element.getMethod("DrawTextureScaledAspect", texture, double.class, double.class, double.class, double.class,
            double.class, double.class, double.class, double.class), eight);
        MethodType text = MethodType.methodType(void.class, Object.class, Object.class, String.class, double.class, double.class, double.class,
            double.class, double.class, double.class);
        Class<?>[] textArguments = { font, String.class, double.class, double.class, double.class, double.class, double.class, double.class };
        drawText = Game.exact(element.getMethod("DrawText", textArguments), text);
        drawCentre = Game.exact(element.getMethod("DrawTextCentre", textArguments), text);
        drawRight = Game.exact(element.getMethod("DrawTextRight", textArguments), text);
        drawUntrimmed = Game.exact(element.getMethod("DrawTextUntrimmed", textArguments), text);
        MethodType four = MethodType.methodType(void.class, Object.class, double.class, double.class, double.class, double.class);
        clip = Game.exact(element.getMethod("setStencilRect", double.class, double.class, double.class, double.class), four);
        unclip = Game.exact(element.getMethod("clearStencilRect"), MethodType.methodType(void.class, Object.class));
        reclip = Game.exact(element.getMethod("repaintStencilRect", double.class, double.class, double.class, double.class), four);
        drawLine = Game.exact(element.getMethod("DrawLine", texture, double.class, double.class, double.class, double.class, float.class,
            double.class, double.class, double.class, double.class), MethodType.methodType(void.class, Object.class, Object.class, double.class,
            double.class, double.class, double.class, float.class, double.class, double.class, double.class, double.class));
        Class<?> renderer = Game.type(loader, "zombie.core.SpriteRenderer");
        sprites = renderer.getField("instance").get(null);
        renderRect = Game.exact(renderer.getMethod("renderi", texture, int.class, int.class, int.class, int.class, float.class, float.class, float.class,
            float.class, Consumer.class), MethodType.methodType(void.class, Object.class, Object.class, int.class, int.class, int.class, int.class,
            float.class, float.class, float.class, float.class, Object.class));
    }

    /** Sets this area's functions into its table, replacing those of an earlier API. */
    void register(Object table) throws ReflectiveOperationException {
        String rects = AREA + "rects", quads = AREA + "quads", keep = AREA + "keep", clear = AREA + "clear", play = AREA + "play";
        lua.set(table, "rects", lua.function(rects, arguments -> {
            try { drawRects(arguments, rects); }
            catch (RuntimeException | Error mine) { throw mine; }
            catch (Throwable failure) { throw Game.thrown(failure); }
            return Game.NONE;
        }));
        lua.set(table, "quads", lua.function(quads, arguments -> {
            try { drawQuads(arguments, quads); }
            catch (RuntimeException | Error mine) { throw mine; }
            catch (Throwable failure) { throw Game.thrown(failure); }
            return Game.NONE;
        }));
        lua.set(table, "keep", lua.function(keep, arguments -> {
            keep(arguments, keep);
            return Game.NONE;
        }));
        lua.set(table, "clear", lua.function(clear, arguments -> {
            Tape tape = tapes.get(owner(arguments, clear));
            if (tape != null) tape.clear();
            return Game.NONE;
        }));
        lua.set(table, "kinds", (double)KINDS);
        lua.set(table, "play", lua.function(play, arguments -> {
            try { return new Object[] { play(arguments, play) }; }
            catch (RuntimeException | Error mine) { throw mine; }
            catch (Throwable failure) { throw Game.thrown(failure); }
        }));
    }

    /** The game's UIElement a call names: the element itself, or a Lua window (its {@code javaObject}). */
    private Object element(Object value, String call) throws ReflectiveOperationException {
        Object found = lua.isTable(value) ? lua.get(value, "javaObject") : value;
        if (!element.isInstance(found)) throw new IllegalArgumentException(call + ": element must be a window of the game's interface (or its javaObject)");
        return found;
    }

    /** The number of shapes: {@code count} when given, else as many as the array holds. */
    private int shapes(Object[] arguments, int index, Object list, int stride, String call) throws Throwable {
        if (!lua.isTable(list)) throw new IllegalArgumentException(call + ": list must be a table of numbers");
        int available = lua.length(list) / stride;
        Object value = index < arguments.length ? arguments[index] : null;
        int count = value == null ? available : Arguments.integer(arguments, index, call, "count", 0, MAX);
        if (count > available) throw new IllegalArgumentException(call + ": count is " + count + " but the list holds only " + available + " shapes of " + stride + " numbers");
        if (count > MAX) throw new IllegalArgumentException(call + ": at most " + MAX + " shapes a call");
        return count;
    }

    // The numbers of the call being drawn, read from the array once (and checked) before anything is drawn: a bad number draws nothing,
    // rather than part of the shapes. Grown to the largest call; the game's thread alone uses it.
    private double[] numbers = new double[RECT * 64];

    /** Reads the first {@code length} numbers of the list into {@link #numbers}; a Lua error names the place of one that is not a number. */
    private double[] read(Object list, int length, String call) throws Throwable {
        if (numbers.length < length) numbers = new double[Math.max(length, numbers.length * 2)];
        double[] into = numbers;
        for (int index = 0; index < length; index++) {
            if (!(lua.at(list, index + 1) instanceof Double value) || !Double.isFinite(value))
                throw new IllegalArgumentException(call + ": list[" + (index + 1) + "] must be a number");
            into[index] = value;
        }
        return into;
    }

    /**
     * {@code draw.rects(element, list, count)}: {@code count} rectangles (as many as the list holds when it is left out) from
     * {@code list}: {@code x, y, w, h, r, g, b, a} for each (the position as {@code drawRect} takes it, in the element's own
     * pixels; the colour parts 0 to 1).
     */
    private void drawRects(Object[] arguments, String call) throws Throwable {
        Object window = element(arguments.length > 0 ? arguments[0] : null, call);
        Object list = arguments.length > 1 ? arguments[1] : null;
        int count = shapes(arguments, 2, list, RECT, call);
        if (count == 0) return;
        double[] values = read(list, count * RECT, call);
        if (!Boolean.TRUE.equals((Boolean)visible.invokeExact(window))) return;
        double left = (double)(Double)absoluteX.invokeExact(window) + (double)(Double)scrollX.invokeExact(window);
        double top = (double)(Double)absoluteY.invokeExact(window);
        double scroll = (double)(Double)scrollY.invokeExact(window);
        for (int shape = 0, at = 0; shape < count; shape++, at += RECT) {
            int x = (int)(values[at] + left), y = (int)(values[at + 1] + top + scroll), w = (int)values[at + 2], h = (int)values[at + 3];
            if (y + h < 0 || y > BOTTOM) continue;
            renderRect.invokeExact(sprites, (Object)null, x, y, w, h, (float)values[at + 4], (float)values[at + 5], (float)values[at + 6],
                (float)values[at + 7], (Object)null);
        }
    }

    /**
     * {@code draw.quads(element, texture, list, count)}: {@code count} quads of the picture from {@code list}: the four corners
     * ({@code x1, y1, x2, y2, x3, y3, x4, y4}, in the screen's pixels, as {@code UIElement.DrawTexture} takes them) and {@code r, g, b, a}.
     */
    private void drawQuads(Object[] arguments, String call) throws Throwable {
        Object window = element(arguments.length > 0 ? arguments[0] : null, call);
        Object picture = arguments.length > 1 ? arguments[1] : null;
        if (!texture.isInstance(picture)) throw new IllegalArgumentException(call + ": texture must be a texture, such as getTexture(\"media/ui/...\")");
        Object list = arguments.length > 2 ? arguments[2] : null;
        int count = shapes(arguments, 3, list, QUAD, call);
        if (count == 0) return;
        double[] values = read(list, count * QUAD, call);
        for (int shape = 0, at = 0; shape < count; shape++, at += QUAD)
            drawQuad.invokeExact(window, picture, values[at], values[at + 1], values[at + 2], values[at + 3], values[at + 4], values[at + 5],
                values[at + 6], values[at + 7], values[at + 8], values[at + 9], values[at + 10], values[at + 11]);
    }

    /**
     * The draws kept for one Lua table: their kinds, pictures (null for a rectangle; a text's font), eight numbers each and a text's
     * words (a line's thickness), grown as they come.
     */
    private static final class Tape {
        int count;
        int[] kinds = new int[16];
        Object[] pictures = new Object[16];
        Object[] words = new Object[16];
        double[] numbers = new double[16 * RECT];

        void clear() {
            Arrays.fill(pictures, 0, count, null);
            Arrays.fill(words, 0, count, null);
            count = 0;
        }

        void add(int kind, Object picture, double[] eight, Object more) {
            if (count == kinds.length) {
                int size = kinds.length * 2;
                kinds = Arrays.copyOf(kinds, size);
                pictures = Arrays.copyOf(pictures, size);
                words = Arrays.copyOf(words, size);
                numbers = Arrays.copyOf(numbers, size * RECT);
            }
            kinds[count] = kind;
            pictures[count] = picture;
            words[count] = more;
            System.arraycopy(eight, 0, numbers, count * RECT, RECT);
            count++;
        }
    }

    /** The tapes, by the Lua table each belongs to: gone with it. A newer API starts with none (its play says so). */
    private final Map<Object, Tape> tapes = new WeakHashMap<>();
    // The eight numbers of the draw being kept, checked before it is.
    private final double[] eight = new double[RECT];

    /** The Lua table a tape call names. */
    private Object owner(Object[] arguments, String call) {
        Object owner = arguments.length > 0 ? arguments[0] : null;
        if (!lua.isTable(owner)) throw new IllegalArgumentException(call + ": tape must be a table");
        return owner;
    }

    /**
     * {@code draw.keep(tape, kind, picture, x, y, w, h, r, g, b, a, more)}: one draw more on the tape of the Lua table {@code tape}
     * (made at its first): its kind ({@link #SCALED} to {@link #LINE}), then {@code x, y, w, h} in the element's own pixels and
     * {@code r, g, b, a}, with: a picture (a rectangle: {@code false}, kind 1), tiled, scaled keeping its aspect; a text in a font
     * {@code text.font} made (4): {@code false} for the picture, {@code w} the font's key and the words as {@code more}; a text in one of
     * the game's fonts (5 from its left, 6 centred, 7 from its right, 8 untrimmed): the font for the picture, the words as {@code more};
     * a clip set (9) or painted back (11) at {@code x, y, w, h}, or taken off (10), {@code false} for the picture; a line (12) from
     * {@code x, y} to {@code w, h}, its picture or {@code false}, its thickness as {@code more}.
     */
    private void keep(Object[] arguments, String call) {
        Object owner = owner(arguments, call);
        Object kind = arguments.length > 1 ? arguments[1] : null;
        if (!(kind instanceof Double value) || value != Math.rint(value) || value < SCALED || value > KINDS)
            throw new IllegalArgumentException(call + ": kind must be a whole number from 1 to " + KINDS);
        int k = (int)(double)value;
        Object picture = arguments.length > 2 ? arguments[2] : null;
        Object more = arguments.length > 11 ? arguments[11] : null;
        boolean none = k == SCALED || k == LINE || k == FACE || k >= CLIP;
        if (Boolean.FALSE.equals(picture) && none) picture = null;
        if (k <= ASPECT || k == LINE) {
            if (picture == null ? !none : !texture.isInstance(picture))
                throw new IllegalArgumentException(call + ": picture must be a texture" + (none ? " or false" : ""));
        } else if (k >= TEXT && k <= UNTRIMMED) {
            if (!font.isInstance(picture)) throw new IllegalArgumentException(call + ": picture must be one of the game's fonts (UIFont)");
        } else if (picture != null) throw new IllegalArgumentException(call + ": picture must be false");
        if (k >= FACE && k <= UNTRIMMED && !(more instanceof String))
            throw new IllegalArgumentException(call + ": more must be the text, a string");
        if (k == LINE && !(more instanceof Double thick && Double.isFinite(thick)))
            throw new IllegalArgumentException(call + ": more must be the line's thickness, a number");
        if (k < FACE || k > UNTRIMMED && k != LINE) more = null;
        for (int index = 0; index < RECT; index++) {
            Object number = 3 + index < arguments.length ? arguments[3 + index] : null;
            if (!(number instanceof Double n) || !Double.isFinite(n))
                throw new IllegalArgumentException(call + ": " + NAMES[index] + " must be a number");
            eight[index] = n;
        }
        if (k == FACE && (eight[2] != Math.rint(eight[2]) || eight[2] < 1 || eight[2] > SizedFonts.MAX))
            throw new IllegalArgumentException(call + ": w must be a font's key, what text.font returned");
        Tape tape = tapes.computeIfAbsent(owner, any -> new Tape());
        if (tape.count >= TAPE_MAX) throw new IllegalArgumentException(call + ": a tape keeps at most " + TAPE_MAX + " draws");
        tape.add(k, picture, eight, more);
    }

    private static final String[] NAMES = { "x", "y", "w", "h", "r", "g", "b", "a" };

    /**
     * {@code draw.play(element, tape, count, start)}: draws {@code count} of the tape's draws from its draw {@code start} (1 when left
     * out; all from there when {@code count} is) in the element, as its {@code DrawTextureScaledCol}, {@code DrawTextureTiled},
     * {@code DrawTextureScaledAspect}, {@code DrawText} (and its others), {@code setStencilRect} (and its others) and {@code DrawLine}
     * draw them, and a text in a font {@code text.font} made as {@code text.draw} does at the element's place, in order. Returns the number of draws the tape holds, or false for a table this API
     * keeps no tape of (never kept, or kept by an API a newer one took over from): nothing is drawn then.
     */
    private Object play(Object[] arguments, String call) throws Throwable {
        Object window = element(arguments.length > 0 ? arguments[0] : null, call);
        Object owner = arguments.length > 1 ? arguments[1] : null;
        if (!lua.isTable(owner)) throw new IllegalArgumentException(call + ": tape must be a table");
        Tape tape = tapes.get(owner);
        if (tape == null) return Boolean.FALSE;
        int start = arguments.length > 3 && arguments[3] != null ? Arguments.integer(arguments, 3, call, "start", 1, TAPE_MAX + 1) : 1;
        int available = Math.max(0, tape.count - (start - 1));
        Object value = arguments.length > 2 ? arguments[2] : null;
        int count = value == null ? available : Arguments.integer(arguments, 2, call, "count", 0, TAPE_MAX);
        if (count > available) throw new IllegalArgumentException(call + ": count is " + count + " but the tape holds only " + available + " draws from draw " + start);
        if (count > 0 && Boolean.TRUE.equals((Boolean)visible.invokeExact(window))) {
            int[] kinds = tape.kinds;
            Object[] pictures = tape.pictures, words = tape.words;
            double[] values = tape.numbers;
            double left = Double.NaN, top = 0;
            for (int draw = start - 1, end = draw + count; draw < end; draw++) {
                int at = draw * RECT;
                Object picture = pictures[draw];
                double x = values[at], y = values[at + 1], w = values[at + 2], h = values[at + 3];
                double r = values[at + 4], g = values[at + 5], b = values[at + 6], a = values[at + 7];
                switch (kinds[draw]) {
                    case SCALED -> drawScaled.invokeExact(window, picture, x, y, w, h, r, g, b, a);
                    case TILED -> drawTiled.invokeExact(window, picture, x, y, w, h, r, g, b, a);
                    case ASPECT -> drawAspect.invokeExact(window, picture, x, y, w, h, r, g, b, a);
                    case FACE -> {
                        // (at the screen's pixels: the element's place and scroll, asked once for the call)
                        Texts texts = GameApi.texts();
                        if (texts == null) break;
                        if (Double.isNaN(left)) {
                            left = (double)(Double)absoluteX.invokeExact(window) + (double)(Double)scrollX.invokeExact(window);
                            top = (double)(Double)absoluteY.invokeExact(window) + (double)(Double)scrollY.invokeExact(window);
                        }
                        texts.drawSized((int)w, (String)words[draw], left + x, top + y, (float)r, (float)g, (float)b, (float)a);
                    }
                    case TEXT -> drawText.invokeExact(window, picture, (String)words[draw], x, y, r, g, b, a);
                    case CENTRE -> drawCentre.invokeExact(window, picture, (String)words[draw], x, y, r, g, b, a);
                    case RIGHT -> drawRight.invokeExact(window, picture, (String)words[draw], x, y, r, g, b, a);
                    case UNTRIMMED -> drawUntrimmed.invokeExact(window, picture, (String)words[draw], x, y, r, g, b, a);
                    case CLIP -> clip.invokeExact(window, x, y, w, h);
                    case UNCLIP -> unclip.invokeExact(window);
                    case RECLIP -> reclip.invokeExact(window, x, y, w, h);
                    default -> drawLine.invokeExact(window, picture, x, y, w, h, (float)(double)(Double)words[draw], r, g, b, a);
                }
            }
        }
        return (double)tape.count;
    }
}
