package pztools.api;

import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.Shape;
import java.awt.font.FontRenderContext;
import java.awt.font.GlyphVector;
import java.awt.geom.AffineTransform;
import java.awt.geom.Rectangle2D;
import java.awt.image.BufferedImage;
import java.awt.image.DataBufferByte;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.Writer;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Bakes one of the API's embedded fonts into a distance-field atlas (docs/design/extension-api.md, "The embedded font"). It runs
 * as a process of its own, started by {@link EmbeddedFont} with the game's Java runtime, headless: nothing of AWT runs in the
 * game's process, and the memory and the time it takes are not the game's.
 *
 * <p>Every character the font has is drawn once, large, without anti-aliasing; the distance from each pixel to the outline (an
 * exact Euclidean distance transform of the picture) is then sampled at the centre of each texel of the atlas, at the font's base
 * size. What it writes is the game's own AngelCode text format, read by the game's {@code AngelCodeFont}, and the atlas as raw
 * bytes, one channel; into a folder of its own that is renamed into place once complete, so that no half-written font is read.
 *
 * <pre>FontBaker &lt;font.ttf&gt; &lt;cache folder&gt; &lt;name&gt; &lt;size&gt; &lt;spread&gt;</pre>
 */
public final class FontBaker {
    /** Raised when what is baked changes, for the same font file and settings: part of the cache's key. */
    public static final int VERSION = 1;
    /** In the baked folder: the text format, and the atlas (width by height bytes, the top row first). */
    public static final String FNT = "font.fnt", ATLAS = "atlas.r8";
    // How many times larger than the base size each character is drawn to find its outline's distances.
    private static final int UPSCALE = 4;
    private static final int GAP = 1, WIDEST = 4096;

    private FontBaker() { }

    /** One character as baked: where it is in the atlas and how it sits on the line, in the base size's pixels. */
    record Glyph(int code, int glyph, int width, int height, int xoffset, int top, int advance, byte[] texels) { }

    public static void main(String[] arguments) {
        if (arguments.length != 5) {
            System.err.println("FontBaker <font.ttf> <cache folder> <name> <size> <spread>");
            System.exit(2);
        }
        try {
            long start = System.nanoTime();
            String summary = bake(Path.of(arguments[0]), Path.of(arguments[1]), arguments[2], Integer.parseInt(arguments[3]),
                Integer.parseInt(arguments[4]), Math.max(1, Math.min(4, Runtime.getRuntime().availableProcessors() / 2)));
            System.out.println(summary + " in " + (System.nanoTime() - start) / 1_000_000 + " ms");
        } catch (Throwable failure) {
            failure.printStackTrace();
            System.exit(1);
        }
    }

    /** Bakes the font into {@code folder/name}; what it did, in a line. A folder of that name already there is kept. */
    static String bake(Path ttf, Path folder, String name, int size, int spread, int threads) throws Exception {
        if (!name.matches("[a-z]+-[0-9a-f]{16}-v[0-9]+-[0-9]+-[0-9]+")) throw new IllegalArgumentException("Bad cache name " + name);
        if (size < 8 || size > 256 || spread < 1 || spread > size) throw new IllegalArgumentException("Bad size or spread");
        byte[] bytes = Files.readAllBytes(ttf);
        Tables tables = Tables.read(bytes);
        Font base = Font.createFont(Font.TRUETYPE_FONT, new ByteArrayInputStream(bytes));
        Font large = base.deriveFont((float)size * UPSCALE);
        var context = new FontRenderContext(new AffineTransform(), false, true);
        var codes = new ArrayList<Integer>();
        for (int code = 0x20; code <= 0xFFFF; code++)
            if ((code < 0xD800 || code > 0xDFFF) && large.canDisplay(code)) codes.add(code);
        Glyph[] found = new Glyph[codes.size()];
        var next = new AtomicInteger();
        var pool = Executors.newFixedThreadPool(Math.max(1, threads));
        try {
            var work = new ArrayList<Future<?>>();
            for (int thread = 0; thread < Math.max(1, threads); thread++) work.add(pool.submit(() -> {
                var raster = new Raster();
                for (int index; (index = next.getAndIncrement()) < found.length;)
                    found[index] = glyph(large, context, codes.get(index), size, spread, raster);
                return null;
            }));
            for (var done : work) done.get();
        } finally { pool.shutdownNow(); }
        // A character the font draws as its missing glyph (a box) is left out: the game's font draws a text that has one.
        Glyph[] glyphs = Arrays.stream(found).filter(Objects::nonNull).toArray(Glyph[]::new);
        int[] place = pack(glyphs);
        int width = place[place.length - 2], height = place[place.length - 1];
        byte[] atlas = new byte[width * height];
        for (int index = 0; index < glyphs.length; index++) {
            Glyph glyph = glyphs[index];
            for (int row = 0; row < glyph.height(); row++)
                System.arraycopy(glyph.texels(), row * glyph.width(), atlas, (place[index * 2 + 1] + row) * width + place[index * 2], glyph.width());
        }
        int ascent = (int)Math.round(tables.winAscent * (double)size / tables.unitsPerEm);
        int line = (int)Math.round((tables.winAscent + tables.winDescent) * (double)size / tables.unitsPerEm);
        Files.createDirectories(folder);
        Path part = Files.createTempDirectory(folder, name + ".part-");
        try {
            Files.write(part.resolve(ATLAS), atlas);
            try (Writer out = Files.newBufferedWriter(part.resolve(FNT), StandardCharsets.UTF_8)) {
                out.write("info face=\"" + base.getFontName(Locale.ENGLISH).replace('"', '\'') + "\" size=" + size
                    + " bold=0 italic=0 charset=\"\" unicode=1 stretchH=100 smooth=1 aa=1 padding=" + spread + "," + spread + "," + spread + "," + spread
                    + " spacing=0,0\n");
                out.write("common lineHeight=" + line + " base=" + ascent + " scaleW=" + width + " scaleH=" + height + " pages=1 packed=0\n");
                // The game's reader passes over this line; EmbeddedFont reads it.
                out.write("pztools version=" + VERSION + " size=" + size + " spread=" + spread + " lineHeight=" + line + " base=" + ascent
                    + " width=" + width + " height=" + height + " glyphs=" + glyphs.length + "\n");
                out.write("chars count=" + glyphs.length + "\n");
                for (int index = 0; index < glyphs.length; index++) {
                    Glyph glyph = glyphs[index];
                    out.write("char id=" + glyph.code() + " x=" + place[index * 2] + " y=" + place[index * 2 + 1] + " width=" + glyph.width()
                        + " height=" + glyph.height() + " xoffset=" + glyph.xoffset() + " yoffset=" + (ascent + glyph.top()) + " xadvance="
                        + glyph.advance() + " page=0 chnl=15\n");
                }
                var kerning = kerning(tables, glyphs, size);
                out.write("kernings count=" + kerning.size() + "\n");
                for (String pair : kerning) out.write(pair);
            }
            try { Files.move(part, folder.resolve(name), StandardCopyOption.ATOMIC_MOVE); }
            catch (FileSystemException another) {
                // Another game baked it first (the same bytes): Windows refuses to move onto a folder that is there.
                if (!Files.isDirectory(folder.resolve(name))) throw another;
            }
        } finally { deleteTree(part); }
        // The pack's earlier bakes (another font file, another version of the baker), and parts a bake that died left.
        String pack = name.substring(0, name.indexOf('-') + 1);
        long hour = System.currentTimeMillis() - 3_600_000;
        try (var entries = Files.newDirectoryStream(folder, pack + "*")) {
            for (Path other : entries) {
                String file = other.getFileName().toString();
                if (file.equals(name) || !Files.isDirectory(other, LinkOption.NOFOLLOW_LINKS)) continue;
                if (file.contains(".part-") && Files.getLastModifiedTime(other).toMillis() > hour) continue;
                deleteTree(other);
            }
        }
        return name + ": " + glyphs.length + " characters, atlas " + width + " x " + height;
    }

    /** One character: its outline drawn {@link #UPSCALE} times larger, and the distances sampled at the base size's texels. */
    private static Glyph glyph(Font large, FontRenderContext context, int code, int size, int spread, Raster raster) {
        GlyphVector vector = large.createGlyphVector(context, Character.toString(code));
        int id = vector.getGlyphCode(0);
        if (id == 0 || id == large.getMissingGlyphCode()) return null;
        int advance = (int)Math.round(vector.getGlyphMetrics(0).getAdvanceX() / UPSCALE);
        Shape outline = vector.getGlyphOutline(0);
        Rectangle2D bounds = outline.getBounds2D();
        if (bounds.isEmpty()) return new Glyph(code, id, 0, 0, 0, 0, advance, new byte[0]);
        int left = (int)Math.floor(bounds.getMinX() / UPSCALE) - spread, right = (int)Math.ceil(bounds.getMaxX() / UPSCALE) + spread;
        int top = (int)Math.floor(bounds.getMinY() / UPSCALE) - spread, bottom = (int)Math.ceil(bounds.getMaxY() / UPSCALE) + spread;
        int width = right - left, height = bottom - top;
        int wide = width * UPSCALE, high = height * UPSCALE;
        boolean[] inside = raster.draw(outline, -left * UPSCALE, -top * UPSCALE, wide, high);
        float[] signed = raster.distances(inside, wide, high);
        byte[] texels = new byte[width * height];
        double range = 2.0 * spread * UPSCALE;
        int half = UPSCALE / 2;
        for (int row = 0; row < height; row++)
            for (int column = 0; column < width; column++) {
                // The texel's centre lies between four pixels of the large picture.
                int x = column * UPSCALE + half, y = row * UPSCALE + half;
                double distance = (signed[(y - 1) * wide + x - 1] + signed[(y - 1) * wide + x] + signed[y * wide + x - 1] + signed[y * wide + x]) / 4;
                double value = 0.5 - distance / range;
                texels[row * width + column] = (byte)Math.max(0, Math.min(255, (int)Math.round(value * 255)));
            }
        return new Glyph(code, id, width, height, left, top, advance, texels);
    }

    /** Rows of characters, tallest first, in an atlas 4096 wide at most and as short as they fit: each one's x and y, then the atlas's size. */
    static int[] pack(Glyph[] glyphs) {
        long area = 0;
        for (Glyph glyph : glyphs) area += (long)(glyph.width() + GAP) * (glyph.height() + GAP);
        int width = 256;
        while (width < WIDEST && (long)width * width < area * 1.15) width *= 2;
        Integer[] order = new Integer[glyphs.length];
        for (int index = 0; index < order.length; index++) order[index] = index;
        Arrays.sort(order, (a, b) -> glyphs[b].height() != glyphs[a].height() ? glyphs[b].height() - glyphs[a].height() : glyphs[a].code() - glyphs[b].code());
        int[] place = new int[glyphs.length * 2 + 2];
        int x = 0, y = 0, row = 0;
        for (int index : order) {
            Glyph glyph = glyphs[index];
            if (x + glyph.width() > width) { x = 0; y += row + GAP; row = 0; }
            place[index * 2] = x;
            place[index * 2 + 1] = y;
            x += glyph.width() + GAP;
            row = Math.max(row, glyph.height());
        }
        int height = 1;
        while (height < y + row) height *= 2;
        place[glyphs.length * 2] = width;
        place[glyphs.length * 2 + 1] = height;
        return place;
    }

    /** The font's pair kerning between the characters baked, in the base size's pixels (pairs that round to 0 left out). */
    private static List<String> kerning(Tables tables, Glyph[] glyphs, int size) {
        var byGlyph = new HashMap<Integer, Integer>();
        for (Glyph glyph : glyphs) byGlyph.putIfAbsent(glyph.glyph(), glyph.code());
        var lines = new ArrayList<String>();
        for (var pair : tables.kerning.entrySet()) {
            Integer first = byGlyph.get(pair.getKey() >>> 16), second = byGlyph.get(pair.getKey() & 0xFFFF);
            if (first == null || second == null) continue;
            int amount = (int)Math.round(pair.getValue() * (double)size / tables.unitsPerEm);
            if (amount != 0) lines.add("kerning first=" + first + " second=" + second + " amount=" + amount + "\n");
        }
        Collections.sort(lines);
        return lines;
    }

    private static void deleteTree(Path root) {
        if (!Files.exists(root, LinkOption.NOFOLLOW_LINKS)) return;
        try (var walk = Files.walk(root)) {
            for (Path path : walk.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
        } catch (IOException | RuntimeException left) { /* A later bake cleans it up. */ }
    }

    /** A thread's picture and work space, kept from one character to the next. */
    private static final class Raster {
        private BufferedImage image;

        /** The outline drawn without anti-aliasing: whether each pixel's centre is inside it. */
        boolean[] draw(Shape outline, double dx, double dy, int width, int height) {
            if (image == null || image.getWidth() < width || image.getHeight() < height)
                image = new BufferedImage(Math.max(width, image == null ? 0 : image.getWidth()), Math.max(height, image == null ? 0 : image.getHeight()), BufferedImage.TYPE_BYTE_GRAY);
            Graphics2D graphics = image.createGraphics();
            try {
                graphics.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_OFF);
                graphics.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);
                graphics.setColor(java.awt.Color.BLACK);
                graphics.fillRect(0, 0, width, height);
                graphics.setColor(java.awt.Color.WHITE);
                graphics.translate(dx, dy);
                graphics.fill(outline);
            } finally { graphics.dispose(); }
            byte[] pixels = ((DataBufferByte)image.getRaster().getDataBuffer()).getData();
            int stride = image.getWidth();
            boolean[] inside = new boolean[width * height];
            for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) inside[y * width + x] = pixels[y * stride + x] != 0;
            return inside;
        }

        /** The signed distance of each pixel to the outline, in pixels: negative inside, from the edge between pixels. */
        float[] distances(boolean[] inside, int width, int height) {
            int count = width * height;
            if (inner.length < count) { inner = new double[count]; outer = new double[count]; }
            for (int index = 0; index < count; index++) {
                inner[index] = inside[index] ? 0 : FAR;
                outer[index] = inside[index] ? FAR : 0;
            }
            transform(inner, width, height);
            transform(outer, width, height);
            float[] signed = new float[count];
            for (int index = 0; index < count; index++)
                signed[index] = (float)(inside[index] ? -(Math.sqrt(outer[index]) - 0.5) : Math.sqrt(inner[index]) - 0.5);
            return signed;
        }

        private static final double FAR = 1e20;
        private double[] inner = new double[0], outer = new double[0], column = new double[0], out = new double[0], envelope = new double[0];
        private int[] parabolas = new int[0];

        /** Felzenszwalb and Huttenlocher's squared Euclidean distance transform, by columns and then by rows, in place. */
        private void transform(double[] grid, int width, int height) {
            int longest = Math.max(width, height);
            if (column.length < longest) {
                column = new double[longest]; out = new double[longest]; envelope = new double[longest + 1]; parabolas = new int[longest];
            }
            for (int x = 0; x < width; x++) {
                for (int y = 0; y < height; y++) column[y] = grid[y * width + x];
                line(height);
                for (int y = 0; y < height; y++) grid[y * width + x] = out[y];
            }
            for (int y = 0; y < height; y++) {
                System.arraycopy(grid, y * width, column, 0, width);
                line(width);
                System.arraycopy(out, 0, grid, y * width, width);
            }
        }

        /** The lower envelope of the parabolas rooted at each value of {@link #column}, into {@link #out}. */
        private void line(int length) {
            double[] f = column, z = envelope;
            int[] v = parabolas;
            int k = 0;
            v[0] = 0;
            z[0] = Double.NEGATIVE_INFINITY;
            z[1] = Double.POSITIVE_INFINITY;
            for (int q = 1; q < length; q++) {
                double s = ((f[q] + (double)q * q) - (f[v[k]] + (double)v[k] * v[k])) / (2.0 * q - 2.0 * v[k]);
                while (s <= z[k]) {
                    k--;
                    s = ((f[q] + (double)q * q) - (f[v[k]] + (double)v[k] * v[k])) / (2.0 * q - 2.0 * v[k]);
                }
                k++;
                v[k] = q;
                z[k] = s;
                z[k + 1] = Double.POSITIVE_INFINITY;
            }
            k = 0;
            for (int q = 0; q < length; q++) {
                while (z[k + 1] < q) k++;
                double d = q - v[k];
                out[q] = d * d + f[v[k]];
            }
        }
    }

    /** What the baker reads of the font file itself: its units per em, its Windows ascent and descent, and its legacy kern pairs. */
    static final class Tables {
        int unitsPerEm = 1000, winAscent, winDescent;
        /** Kerning by (left glyph << 16 | right glyph), in font units; the subtables added up. */
        final Map<Integer, Integer> kerning = new HashMap<>();

        static Tables read(byte[] bytes) throws IOException {
            var tables = new Tables();
            ByteBuffer data = ByteBuffer.wrap(bytes);
            int count = Short.toUnsignedInt(data.getShort(4));
            for (int index = 0; index < count; index++) {
                int entry = 12 + index * 16;
                String tag = new String(bytes, entry, 4, StandardCharsets.US_ASCII);
                int offset = data.getInt(entry + 8), length = data.getInt(entry + 12);
                if (offset < 0 || length < 0 || (long)offset + length > bytes.length) throw new IOException("Bad table " + tag);
                switch (tag) {
                    case "head" -> tables.unitsPerEm = Short.toUnsignedInt(data.getShort(offset + 18));
                    case "OS/2" -> {
                        tables.winAscent = Short.toUnsignedInt(data.getShort(offset + 74));
                        tables.winDescent = Short.toUnsignedInt(data.getShort(offset + 76));
                    }
                    case "kern" -> {
                        int subtables = Short.toUnsignedInt(data.getShort(offset + 2)), at = offset + 4;
                        for (int table = 0; table < subtables; table++) {
                            int size = Short.toUnsignedInt(data.getShort(at + 2)), coverage = Short.toUnsignedInt(data.getShort(at + 4));
                            // Format 0, horizontal, not minimum or cross-stream.
                            if ((coverage >>> 8) == 0 && (coverage & 0x7) == 1) {
                                int pairs = Short.toUnsignedInt(data.getShort(at + 6));
                                for (int pair = 0; pair < pairs; pair++) {
                                    int record = at + 14 + pair * 6;
                                    int key = Short.toUnsignedInt(data.getShort(record)) << 16 | Short.toUnsignedInt(data.getShort(record + 2));
                                    tables.kerning.merge(key, (int)data.getShort(record + 4), Integer::sum);
                                }
                                // The length of a large subtable does not fit its 16 bits: go by its pairs.
                                at += 14 + pairs * 6;
                            } else at += size;
                        }
                    }
                    default -> { }
                }
            }
            if (tables.winAscent + tables.winDescent <= 0) throw new IOException("The font has no Windows ascent and descent");
            return tables;
        }
    }
}
