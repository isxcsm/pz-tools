package pzext.api;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;
import zombie.ZomboidFileSystem;
import zombie.core.Core;
import zombie.core.Language;
import zombie.core.Translator;
import zombie.core.fonts.AngelCodeFont;
import zombie.characters.IsoPlayer;
import zombie.iso.IsoCamera;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;
import zombie.ui.TextManager;
import zombie.ui.UIFont;
import zombie.ui.UIManager;
import pzext.boot.Hooks;

/**
 * The text a mod shows, against the synthetic game: drawn by the game's own text drawing from the hook in the interface's drawing
 * (after the windows, before the tooltip), placed on each local player's part of the screen, zoomed, coloured, faded and moved by
 * its effects on the clock of the interface, the first font that has its characters, the distance-field shader around the fonts
 * made for it; titles in their styles, one after another on each screen; text typed with pauses, speed changes, colours and a
 * cursor, and fitted to a width on each screen; hidden, cleared, gone with the world, taken over by a
 * newer API; a drawing that fails leaves the interface drawn; and nothing is done, nor allocated, with nothing shown. Text a mod
 * draws in its own windows at a height: the language's font of the nearest size, read once, the game's own where it is the one,
 * the embedded font well above them, kept through the game making its fonts again.
 */
final class TextsTest {
    private static final double SECOND = 1e9;
    private static final long[] NOW = { 1_000_000_000_000L };

    private TextsTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        IsoPlayer[] before = IsoPlayer.players.clone();
        Arrays.fill(IsoPlayer.players, null);
        IsoPlayer.players[0] = new IsoPlayer();
        try {
            var text = (KahluaTable)api.rawget("text");
            check(text != null, "The API has no text");
            UIManager.getToolTip();
            check(Hooks.APPLIED.equals(FormulasTest.call(text, "status").get(0)), "The text hook is " + FormulasTest.call(text, "status").get(0));
            check(List.of("stamp", "discovery", "notice", "unveil", "dust", "bleed", "sink", "type", "pulse", "brief").equals(list(FormulasTest.call(text, "styles").get(0))), "The styles are wrong");
            useClock();
            Object mod = FormulasTest.call(api, "client", "text.mod").get(0), other = FormulasTest.call(api, "client", "other.mod").get(0);
            idle();
            shown(text, mod);
            timeline(text, mod, other);
            moves(text, mod, other);
            layout(text, mod);
            fonts(text, mod);
            embedded(text, mod);
            TextFitsTest.run(text);
            sized(text, mod);
            effects(text, mod);
            typing(text, mod);
            titles(text, mod);
            screens(text, mod);
            world(text, mod, other);
            rejects(api, text, mod);
            failing(text, mod);
            cost(text, mod);
            typingCost(text, mod);
            takeover(api, text, mod);
            takeoverTyped(api, text, mod);
            LooksTest.run(text, mod);
            DustTest.run(api, text, mod);
            System.out.println("PASS: text a mod shows is drawn with the interface, zoomed, faded and moved on each player's screen; titles follow one another; text types, fits a width and carries colours");
        } finally {
            System.arraycopy(before, 0, IsoPlayer.players, 0, before.length);
            IsoWorld.instance.setCell(home);
            GameApi.frame(TextsTest.class.getClassLoader());
            TextManager.record = true;
            TextManager.fail = false;
            TextManager.calls.clear();
            Arrays.fill(IsoCamera.left, 0);
            Arrays.fill(IsoCamera.top, 0);
            Arrays.fill(IsoCamera.width, 1600);
            Arrays.fill(IsoCamera.height, 900);
        }
    }

    private static void useClock() { GameApi.texts().clock = () -> NOW[0]; }

    private static void advance(double seconds) { NOW[0] += Math.round(seconds * SECOND); }

    /** Nothing shown: the interface is drawn as it was, the hook draws nothing and allocates nothing. */
    private static void idle() {
        TextManager.calls.clear();
        UIManager.render();
        check(names().equals(List.of("windows", "tooltip", "post")), "The interface was not drawn as it was: " + names());
        TextManager.record = false;
        int drawn = TextManager.drawn;
        // The median of 5 rounds: one round alone may count the JIT's move of the measuring loop to C2 (see Allocations).
        long bytes = Allocations.median(5, () -> { for (int frame = 0; frame < 100_000; frame++) UIManager.render(); });
        TextManager.record = true;
        check(TextManager.drawn == drawn && bytes < 1024, "With nothing shown the drawing drew " + (TextManager.drawn - drawn) + " and allocated " + bytes + " bytes");
    }

    /** A text: drawn once the windows are, before the tooltip; centred, zoomed and coloured as asked; gone after its hold. */
    private static void shown(KahluaTable text, Object mod) {
        double key = (Double)FormulasTest.call(text, "show", mod, table("text", "Hello", "scale", 2.0, "color", list(1.0, 0.5, 0.25, 1.0), "hold", 1.0)).get(0);
        check(key >= 1 && (Boolean)FormulasTest.call(text, "shown", mod, key).get(0), "show gave no key");
        render();
        check(names().equals(List.of("windows", "text", "tooltip", "post")), "The text was not drawn between the windows and the tooltip: " + names());
        // Large is 33 high and 15 a character: 150 by 66 at zoom 2, centred on the screen of 1600 by 900.
        Object[] hello = draws().get(0);
        drawn(hello, UIFont.Large, 725, 417, 2, "Hello", 1, 0.5, 0.25, 1);
        advance(0.99);
        render();
        check(draws().size() == 1, "The text went before its hold was over");
        advance(0.01);
        render();
        check(draws().isEmpty() && !(Boolean)FormulasTest.call(text, "shown", mod, key).get(0), "The text outlived its hold");
    }

    /**
     * Moved: to its new place and strength over the time asked, easing out, from where it is on its way when moved again; at once
     * when it is not on the screen yet; only by its mod; a field it does not take is an error.
     */
    private static void moves(KahluaTable text, Object mod, Object other) {
        double key = (Double)FormulasTest.call(text, "show", mod, table("text", "Move")).get(0);
        render();
        // Large is 33 high and 15 a character: 60 by 33, centred on the screen of 1600 by 900.
        drawn(draws().get(0), UIFont.Large, 770, 433.5, 1, "Move", 1, 1, 1, 1);
        check(!(Boolean)FormulasTest.call(text, "move", other, key, table("y", 0.25)).get(0)
            && !(Boolean)FormulasTest.call(text, "move", mod, 999.0, table("y", 0.25)).get(0), "Another mod's text, or one that is not there, was moved");
        check((Boolean)FormulasTest.call(text, "move", mod, key, table("y", 0.25, "alpha", 0.5, "time", 1.0)).get(0), "move found no text");
        render();
        drawn(draws().get(0), UIFont.Large, 770, 433.5, 1, "Move", 1, 1, 1, 1);
        // Halfway: eased out, 1 - 0.5^3 of the way.
        advance(0.5);
        render();
        drawn(draws().get(0), UIFont.Large, 770, 433.5 + (208.5 - 433.5) * 0.875, 1, "Move", 1, 1, 1, 1 - 0.5 * 0.875);
        // Moved again from there: to the right, the rest as it was put.
        double fromY = 433.5 + (208.5 - 433.5) * 0.875;
        FormulasTest.call(text, "move", mod, key, table("x", 0.75, "time", 0.5));
        advance(0.5);
        render();
        drawn(draws().get(0), UIFont.Large, 1170, 208.5, 1, "Move", 1, 1, 1, 0.5);
        check(fromY > 208.5, "The second move did not start on the way");
        // At once.
        FormulasTest.call(text, "move", mod, key, table("y", 0.5, "time", 0.0));
        render();
        drawn(draws().get(0), UIFont.Large, 1170, 433.5, 1, "Move", 1, 1, 1, 0.5);
        FormulasTest.call(text, "hide", mod, key, true);
        check(!(Boolean)FormulasTest.call(text, "move", mod, key, table("y", 0.25)).get(0), "A hidden text was moved");
        // Not on the screen yet (its delay is not over, nor was it drawn): there at once when it comes.
        double later = (Double)FormulasTest.call(text, "show", mod, table("text", "Move", "delay", 1.0)).get(0);
        FormulasTest.call(text, "move", mod, later, table("y", 0.25, "time", 5.0));
        render();
        advance(1);
        render();
        drawn(draws().get(0), UIFont.Large, 770, 208.5, 1, "Move", 1, 1, 1, 1);
        rejects(text, "spec has no field size", "move", mod, later, table("size", 0.1));
        rejects(text, "spec.time must be", "move", mod, later, table("time", 31.0));
        rejects(text, "spec.cursor goes with", "move", mod, later, table("cursor", true));
        rejects(text, "spec must be a table", "move", mod, later);
        FormulasTest.call(text, "hide", mod, later, true);
    }

    /** Fading in and out on the clock; the clock starts as it is first drawn; hidden, at once or as it leaves; only by its mod. */
    private static void timeline(KahluaTable text, Object mod, Object other) {
        FormulasTest.call(text, "show", mod, table("text", "Fade", "enter", "fade", "enterTime", 0.5, "hold", 1.0, "leave", "fade", "leaveTime", 0.5));
        // Not drawn for a while (a loading screen): its time starts when it is first drawn.
        advance(10);
        render();
        check(draws().isEmpty(), "A text fading in was drawn at alpha 0");
        advance(0.25);
        render();
        check(near(alpha(draws().get(0)), 0.5), "Halfway in, the alpha is " + alpha(draws().get(0)));
        advance(0.75);
        render();
        check(near(alpha(draws().get(0)), 1), "Held, the alpha is " + alpha(draws().get(0)));
        advance(0.75);
        render();
        check(near(alpha(draws().get(0)), 0.5), "Halfway out, the alpha is " + alpha(draws().get(0)));
        advance(0.25);
        render();
        check(draws().isEmpty(), "The text did not go");

        double held = (Double)FormulasTest.call(text, "show", mod, table("text", "Held", "leave", "fade", "leaveTime", 0.4)).get(0);
        render();
        advance(100);
        render();
        check(draws().size() == 1, "A text without a hold went");
        check(!(Boolean)FormulasTest.call(text, "hide", other, held).get(0) && !(Boolean)FormulasTest.call(text, "hide", mod, 999.0).get(0),
            "Another mod's text, or one that is not there, was hidden");
        check((Boolean)FormulasTest.call(text, "hide", mod, held).get(0), "hide found no text");
        advance(0.2);
        render();
        check(near(alpha(draws().get(0)), 0.5), "Hidden, it did not leave as its effect says: " + alpha(draws().get(0)));
        advance(0.2);
        render();
        check(draws().isEmpty(), "A hidden text stayed");
        double cut = (Double)FormulasTest.call(text, "show", mod, table("text", "Cut", "leave", "fade", "leaveTime", 5.0)).get(0);
        render();
        FormulasTest.call(text, "hide", mod, cut, true);
        render();
        check(draws().isEmpty(), "A text hidden at once was drawn");
        // One hidden before it was ever drawn goes at once.
        double never = (Double)FormulasTest.call(text, "show", mod, table("text", "Never", "leave", "fade", "leaveTime", 5.0)).get(0);
        FormulasTest.call(text, "hide", mod, never);
        render();
        check(draws().isEmpty(), "A text hidden before it was drawn was drawn");
    }

    /** Lines, alignment, a size as a share of the screen's height, a shadow and an outline. */
    private static void layout(KahluaTable text, Object mod) {
        double key = (Double)FormulasTest.call(text, "show", mod, table("text", "A\n\nBB", "align", "left", "x", 0.1, "y", 0.5)).get(0);
        render();
        var lines = draws();
        // Three lines of 33 centred on 450: the empty one is not drawn.
        check(lines.size() == 2, "The lines drawn are " + lines.size());
        drawn(lines.get(0), UIFont.Large, 160, 400.5, 1, "A", 1, 1, 1, 1);
        drawn(lines.get(1), UIFont.Large, 160, 466.5, 1, "BB", 1, 1, 1, 1);
        FormulasTest.call(text, "hide", mod, key, true);
        key = (Double)FormulasTest.call(text, "show", mod, table("text", "A\nBB", "align", "right", "x", 0.9)).get(0);
        render();
        lines = draws();
        check(near((Double)lines.get(0)[2], 1425) && near((Double)lines.get(1)[2], 1410), "Right-aligned lines end elsewhere");
        FormulasTest.call(text, "hide", mod, key, true);

        key = (Double)FormulasTest.call(text, "show", mod, table("text", "Big", "size", 0.1)).get(0);
        render();
        double zoom = 0.1 * 900 / 33;
        drawn(draws().get(0), UIFont.Large, 800 - 45 * zoom / 2, 450 - 45, zoom, "Big", 1, 1, 1, 1);
        FormulasTest.call(text, "hide", mod, key, true);

        key = (Double)FormulasTest.call(text, "show", mod, table("text", "S", "shadow", true, "outline", 2.0, "outlineColor", table("r", 0.0, "g", 0.0, "b", 0.0, "a", 0.5),
            "color", list(1.0, 1.0, 1.0, 0.8))).get(0);
        render();
        var copies = draws();
        check(copies.size() == 10, "A shadow and an outline are not 1 and 8 copies: " + copies.size());
        double x = 800 - 7.5, y = 450 - 16.5;
        drawn(copies.get(0), UIFont.Large, x + 1, y + 1, 1, "S", 0, 0, 0, 0.8 * 0.55);
        for (int index = 1; index <= 8; index++) {
            Object[] outline = copies.get(index);
            check(Math.abs((Double)outline[2] - x) == 2 || Math.abs((Double)outline[3] - y) == 2, "An outline copy is not 2 pixels off");
            check(near(alpha(outline), 0.5) && (Double)outline[6] == 0, "An outline copy has the wrong colour");
        }
        drawn(copies.get(9), UIFont.Large, x, y, 1, "S", 1, 1, 1, 0.8);
        FormulasTest.call(text, "hide", mod, key, true);
    }

    /** The first font of a list that has every character; the distance-field shader around a font made for it. */
    private static void fonts(KahluaTable text, Object mod) {
        double key = (Double)FormulasTest.call(text, "show", mod, table("text", "Quest", "font", list("SdfBold", "Large"))).get(0);
        render();
        check(names().equals(List.of("windows", "threshold", "shadow", "outline", "start", "text", "end", "tooltip", "post")),
            "The distance-field font was not drawn in its shader: " + names());
        check(draws().get(0)[1] == UIFont.SdfBold && near((Float)call("threshold")[1], 0.125) && near((Float)call("outline")[1], 0),
            "The shader's edge or outline is wrong");
        FormulasTest.call(text, "hide", mod, key, true);
        key = (Double)FormulasTest.call(text, "show", mod, table("font", list("SdfBold", "Large"), "text", "수색 완료")).get(0);
        render();
        check(draws().get(0)[1] == UIFont.Large && call("start") == null, "Hangul was not drawn in the font that has it, without the shader");
        FormulasTest.call(text, "hide", mod, key, true);
        key = (Double)FormulasTest.call(text, "show", mod, table("text", "ЖИВ", "font", list("Massive", "SdfBold", "Large"))).get(0);
        render();
        check(draws().get(0)[1] == UIFont.SdfBold, "Cyrillic was not drawn in the first font that has it");
        FormulasTest.call(text, "hide", mod, key, true);
        // None has them: the last.
        key = (Double)FormulasTest.call(text, "show", mod, table("text", "수", "font", list("Massive", "SdfBold"))).get(0);
        render();
        check(draws().get(0)[1] == UIFont.SdfBold, "With no font that has the text, the last was not used");
        FormulasTest.call(text, "hide", mod, key, true);
        // The font size option makes the fonts again: measured again.
        key = (Double)FormulasTest.call(text, "show", mod, table("text", "Re")).get(0);
        render();
        double first = (Double)draws().get(0)[2];
        TextManager.instance.fonts.put(UIFont.Large, new zombie.core.fonts.AngelCodeFont(0xD7A3, 40, 20, false));
        render();
        check(near(first, 800 - 15) && near((Double)draws().get(0)[2], 800 - 20) && near((Double)draws().get(0)[3], 430), "A new font was not measured again");
        TextManager.instance.reset();
        FormulasTest.call(text, "hide", mod, key, true);
    }

    /**
     * The embedded font: it draws a line taller than the game's font the text's list picked is made at (Large 33, Medium 24), when it has every
     * character and the game's font for the text is not a distance-field one; inside the shader, with the edge for its spread; it
     * measures and breaks the rows; the game's font draws at or below 33, with a character the embedded font lacks, before the
     * atlas is in video memory, and without it. Allocates nothing as it draws.
     */
    private static void embedded(KahluaTable text, Object mod) {
        var face = new zombie.core.fonts.AngelCodeFont(0xD7A3, 90, 50, true);
        face.chars['똠'] = null;
        var ready = new java.util.concurrent.atomic.AtomicBoolean(true);
        Texts texts = GameApi.texts();
        texts.embedded = new EmbeddedFont.Loaded("test", face, face.chars, 90, 8, ready);
        try {
            // A tenth of the screen (90 of 900): the embedded font at zoom 1, 2 characters of 50, in the shader with its edge.
            double key = (Double)FormulasTest.call(text, "show", mod, table("text", "수색", "font", list("SdfBold", "Large"), "size", 0.1)).get(0);
            render();
            check(names().equals(List.of("windows", "threshold", "shadow", "outline", "start", "text", "end", "tooltip", "post")),
                "The embedded font was not drawn in the shader: " + names());
            Object[] draw = draws().get(0);
            check(draw[1] == face && near((Double)draw[2], 750) && near((Double)draw[3], 405) && near(zoom(draw), 1) && "수색".equals(draw[5]),
                "The embedded font drew " + Arrays.toString(draw));
            check(near((Float)call("threshold")[1], 0.75 / 16), "The embedded font's edge is " + call("threshold")[1]);
            FormulasTest.call(text, "hide", mod, key, true);
            // 27 high, and 33 (the tallest of Small, Medium and Large): the game's font, zoomed, outside the shader.
            for (Object[] spec : new Object[][] { { "size", 0.03 }, { "scale", 1.0 } }) {
                key = (Double)FormulasTest.call(text, "show", mod, table("text", "수색", "font", list("SdfBold", "Large"), spec[0], spec[1])).get(0);
                render();
                check(draws().get(0)[1] == UIFont.Large && call("start") == null, "A line of " + spec[0] + " " + spec[1] + " was not the game's font");
                FormulasTest.call(text, "hide", mod, key, true);
            }
            // Medium (24) asked for 28.8 (a notice's line in Korean): the embedded font, not Medium zoomed; at 21.6, Medium.
            key = (Double)FormulasTest.call(text, "show", mod, table("text", "수색", "font", list("SdfBold", "Medium"), "size", 0.032)).get(0);
            render();
            check(draws().get(0)[1] == face && near(zoom(draws().get(0)), 28.8 / 90), "A zoomed Medium was not the embedded font: " + Arrays.toString(draws().get(0)));
            FormulasTest.call(text, "hide", mod, key, true);
            key = (Double)FormulasTest.call(text, "show", mod, table("text", "수색", "font", list("SdfBold", "Medium"), "size", 0.024)).get(0);
            render();
            check(draws().get(0)[1] == UIFont.Medium, "Medium at below its size was not the game's font");
            FormulasTest.call(text, "hide", mod, key, true);
            // A zoom of 1.1 on Large: 36.3 high, the embedded font at 36.3 / 90.
            key = (Double)FormulasTest.call(text, "show", mod, table("text", "수색", "scale", 1.1)).get(0);
            render();
            check(draws().get(0)[1] == face && near(zoom(draws().get(0)), 36.3 / 90), "A zoomed Large was not the embedded font: " + Arrays.toString(draws().get(0)));
            FormulasTest.call(text, "hide", mod, key, true);
            // A character it lacks: the game's font draws the whole text, no character left out.
            key = (Double)FormulasTest.call(text, "show", mod, table("text", "똠방", "size", 0.1)).get(0);
            render();
            check(draws().get(0)[1] == UIFont.Large && "똠방".equals(draws().get(0)[5]), "A character the embedded font lacks was not drawn by the game's");
            FormulasTest.call(text, "hide", mod, key, true);
            // Latin in a list with the game's distance-field font: that font, sharp already.
            key = (Double)FormulasTest.call(text, "show", mod, table("text", "Quest", "font", list("SdfBold", "Large"), "size", 0.1)).get(0);
            render();
            check(draws().get(0)[1] == UIFont.SdfBold, "The game's distance-field font gave way to the embedded font");
            FormulasTest.call(text, "hide", mod, key, true);
            // Rows fitted to a width are measured in the embedded font: 8 characters of 50 do not fit 320 pixels.
            key = (Double)FormulasTest.call(text, "show", mod, table("text", "수색 완료 수색", "size", 0.1, "width", 0.2, "markup", true)).get(0);
            render();
            check(draws().size() == 2 && draws().get(0)[1] == face && "수색 완료".equals(draws().get(0)[5]) && near((Double)draws().get(0)[2], 675)
                && near((Double)draws().get(0)[3], 360) && "수색".equals(draws().get(1)[5]) && near((Double)draws().get(1)[3], 450),
                "The rows were not broken in the embedded font: " + draws().stream().map(Arrays::toString).toList());
            // It allocates nothing as it draws, and costs what the game's font does (the same strings, the same calls).
            long[] time = new long[2];
            long bytes = 0;
            TextManager.record = false;
            try {
                for (int round = 0; round < 2; round++) {
                    ready.set(round == 0);
                    int which = round;
                    long measured = Allocations.median(5, () -> {
                        long clock = System.nanoTime();
                        for (int frame = 0; frame < 100_000; frame++) UIManager.render();
                        time[which] = System.nanoTime() - clock;
                    });
                    if (round == 0) bytes = measured;
                }
            } finally { TextManager.record = true; ready.set(true); }
            System.out.printf("text: two rows fitted to a width cost %.0f ns a frame to place in the embedded font, %.0f ns in the game's; %d bytes allocated over 100000 frames%n",
                time[0] / 1e5, time[1] / 1e5, bytes);
            check(bytes < 4096, "Drawing in the embedded font allocated " + bytes + " bytes");
            FormulasTest.call(text, "hide", mod, key, true);
            // The first frame of a large title in the embedded font: the characters looked up once, the lines measured once.
            key = (Double)FormulasTest.call(text, "title", mod, table("text", "임무 완료", "subtitle", "우물이 깨끗해졌다", "hold", 100.0, "style", "stamp")).get(0);
            TextManager.record = false;
            long first = System.nanoTime();
            UIManager.render();
            first = System.nanoTime() - first;
            long next = System.nanoTime();
            UIManager.render();
            next = System.nanoTime() - next;
            TextManager.record = true;
            System.out.printf("text: a Korean stamp title's first frame in the embedded font took %.1f us to place, the next %.1f us%n", first / 1e3, next / 1e3);
            FormulasTest.call(text, "hide", mod, key, true);
            // Not in video memory yet: the game's font.
            ready.set(false);
            key = (Double)FormulasTest.call(text, "show", mod, table("text", "수색", "size", 0.1)).get(0);
            render();
            check(draws().get(0)[1] == UIFont.Large, "The embedded font drew before it was in video memory");
            ready.set(true);
            render();
            check(draws().get(0)[1] == face, "The embedded font did not take over once in video memory");
            FormulasTest.call(text, "hide", mod, key, true);
        } finally { texts.embedded = null; }
        double key = (Double)FormulasTest.call(text, "show", mod, table("text", "수색", "size", 0.1)).get(0);
        render();
        check(draws().get(0)[1] == UIFont.Large, "Without the embedded font, the game's did not draw");
        FormulasTest.call(text, "hide", mod, key, true);
    }

    /**
     * Text at a height (text.font, fontHeight, measure, draw): the language's fonts of every font size option, named as the game
     * names them (its folders and their fallbacks, through its file system), the nearest chosen and read once, the game's own used
     * where it is the one, a height well above the tallest drawn in the embedded font (or the tallest zoomed where that cannot),
     * a font still loading its pictures not drawn, the keys kept as the game makes its fonts again and the language changes, the
     * fonts of a language no longer used let go, and measuring and drawing allocating nothing.
     */
    private static void sized(KahluaTable text, Object mod) throws Exception {
        Path root = Files.createTempDirectory("pzext-sized-fonts");
        Texts texts = GameApi.texts();
        ClassLoader loader = TextsTest.class.getClassLoader();
        check(texts.sized != null, "text.font has no fonts in the synthetic game");
        try {
            // Korean's fonts, by option: the smallest in the fonts' folder itself, then 1x to 4x, as the game ships them; English's.
            int[][] korean = { { 16, 23, 26 }, { 19, 29, 33 }, { 26, 33, 40 }, { 33, 40, 45 }, { 38, 45, 45 } };
            int[][] english = { { 16, 23, 26 }, { 19, 29, 33 }, { 26, 33, 40 }, { 33, 40, 45 }, { 38, 45, 50 } };
            String[] slots = { "Small", "Medium", "Large" }, folders = { "", "1x/", "2x/", "3x/", "4x/" };
            write(root, "media/fonts/EN/fonts.txt", "Small fnt=zomboidSmall.fnt\nMedium fnt=zomboidMedium.fnt\nLarge fnt=zomboidLarge.fnt\n");
            write(root, "media/fonts/KO/fonts.txt", "Small fnt=zomboidSmallKorean.fnt\nMedium fnt=zomboidMediumKorean.fnt\nLarge fnt=zomboidLargeKorean.fnt\n");
            for (int folder = 0; folder < 5; folder++)
                for (int slot = 0; slot < 3; slot++) {
                    fnt(root, (folder == 0 ? "media/fonts/" : "media/fonts/KO/" + folders[folder]) + "zomboid" + slots[slot] + "Korean.fnt", korean[folder][slot]);
                    fnt(root, (folder == 0 ? "media/fonts/" : "media/fonts/EN/" + folders[folder]) + "zomboid" + slots[slot] + ".fnt", english[folder][slot]);
                }
            var files = new HashMap<>(ZomboidFileSystem.FILES);
            Translator.language = new Language("KO");
            // The game at the font size option 2 (a 1080-pixel screen on auto): the 1x folder's fonts are its own.
            game("media/fonts/KO/1x/zomboid%sKorean.fnt");
            var gameSmall = (AngelCodeFont)TextManager.instance.fonts.get(UIFont.Small);
            var gameMedium = (AngelCodeFont)TextManager.instance.fonts.get(UIFont.Medium);
            int made = AngelCodeFont.made;

            // 20 pixels: the game's own Small (19), read no more, drawn as DrawText draws it (no zoom) where it is asked.
            check(sizedKey(text, mod, 20) == 20 && sizedKey(text, mod, 20.3) == 20, "text.font gave another key for 20 pixels");
            check(sizedHeight(text, mod, 20) == 19 && sizedWidth(text, mod, 20, "가나다") == 27, "20 pixels is not the 19 of the game's Small");
            TextFitsTest.keyed(text, mod, 20.0, 27);
            Object[] drawn = sizedDraw(text, mod, 20, "가나다", 100.5, 40.25).get(0);
            check(drawn[1] == gameSmall && zoom(drawn) == 0 && near((Double)drawn[2], 100.5) && near((Double)drawn[3], 40.25) && "가나다".equals(drawn[5])
                && near((Double)drawn[6], 1) && near((Double)drawn[7], 0.5) && near((Double)drawn[8], 0.25) && near((Double)drawn[9], 1),
                "20 pixels was not drawn in the game's Small at its size: " + Arrays.toString(drawn));
            check(AngelCodeFont.made == made, "The game's own font was read again");
            // 25: 26, the smallest option's Large (in the fonts' folder: Korean has no folder of its own for it), read once.
            check(sizedHeight(text, mod, 25) == 26 && AngelCodeFont.made == made + 1, "25 pixels is not 26, read once");
            var rootLarge = (AngelCodeFont)sizedDraw(text, mod, 25, "가", 0, 0).get(0)[1];
            check(file(rootLarge).endsWith("/media/fonts/zomboidLargeKorean.fnt") && sizedWidth(text, mod, 25, "가") == 13, "26 is not the fonts' folder's Large: " + file(rootLarge));
            check(sizedKey(text, mod, 25) == 25 && AngelCodeFont.made == made + 1, "Asking for 25 again read a font");
            // 30 and 31: the game's Medium (29); between 29 and 33, the smaller.
            check(sizedHeight(text, mod, 30) == 29 && sizedHeight(text, mod, 31) == 29 && sizedDraw(text, mod, 31, "가", 0, 0).get(0)[1] == gameMedium,
                "30 and 31 pixels are not the game's Medium");
            // 48: under an eighth above the tallest (45): 3x's Large, at its size.
            check(sizedHeight(text, mod, 48) == 45, "48 pixels is not 45");
            drawn = sizedDraw(text, mod, 48, "가", 0, 0).get(0);
            check(file(drawn[1]).endsWith("/KO/3x/zomboidLargeKorean.fnt") && zoom(drawn) == 0, "48 pixels was not 3x's Large at its size: " + Arrays.toString(drawn));

            // 60: the height itself. Without the embedded font, the tallest zoomed to it, outside the shader.
            texts.embedded = null;
            GameApi.frame(loader);
            made = AngelCodeFont.made;
            check(sizedKey(text, mod, 60) == 60 && sizedHeight(text, mod, 60) == 60 && AngelCodeFont.made == made, "60 pixels is not its own height");
            check(sizedWidth(text, mod, 60, "가나") == 59, "60 pixels in the tallest zoomed is " + sizedWidth(text, mod, 60, "가나") + " wide");
            List<Object[]> calls = sizedDraw(text, mod, 60, "가나", 10, 20);
            check(calls.size() == 1 && file(calls.get(0)[1]).endsWith("/KO/3x/zomboidLargeKorean.fnt") && near(zoom(calls.get(0)), 60 / 45.0),
                "60 pixels was not the tallest zoomed: " + Arrays.toString(calls.get(0)));
            // With it: the embedded font at 60 / 90 in the shader with its edge; a character it lacks, the tallest zoomed.
            var face = new AngelCodeFont(0xD7A3, 90, 50, true);
            face.chars['똠'] = null;
            var ready = new java.util.concurrent.atomic.AtomicBoolean(true);
            texts.embedded = new EmbeddedFont.Loaded("test", face, face.chars, 90, 8, ready);
            GameApi.frame(loader);
            check(sizedWidth(text, mod, 60, "수색") == 67 && sizedWidth(text, mod, 60, "똠방") == 59, "60 pixels was not measured in the embedded font");
            calls = sizedDraw(text, mod, 60, "수색", 10, 20);
            check(names(calls).equals(List.of("threshold", "shadow", "outline", "start", "text", "end")) && calls.get(4)[1] == face
                && near(zoom(calls.get(4)), 60 / 90.0) && near((Float)calls.get(0)[1], 0.75 / (2 * 8 * (60 / 90.0))) && near((Double)calls.get(4)[2], 10),
                "60 pixels was not drawn in the embedded font: " + names(calls));
            calls = sizedDraw(text, mod, 60, "똠방", 10, 20);
            check(calls.size() == 1 && file(calls.get(0)[1]).endsWith("/KO/3x/zomboidLargeKorean.fnt"), "A character the embedded font lacks was not the tallest's");
            // Its atlas gone or come: the choice follows at the next frame, not between a measure and a draw.
            ready.set(false);
            check(sizedWidth(text, mod, 60, "수색") == 67, "The choice changed within a frame");
            GameApi.frame(loader);
            check(sizedWidth(text, mod, 60, "수색") == 59, "An embedded font not in video memory measured");
            ready.set(true);
            GameApi.frame(loader);
            check(sizedWidth(text, mod, 60, "수색") == 67 && sizedHeight(text, mod, 60) == 60, "The embedded font did not take over");

            // A font still loading its pictures is measured but not drawn; once they are in, it is.
            AngelCodeFont.loadingNew = true;
            made = AngelCodeFont.made;
            check(sizedKey(text, mod, 38) == 38 && AngelCodeFont.made == made + 1, "38 pixels read no font");
            AngelCodeFont.loadingNew = false;
            AngelCodeFont loading = AngelCodeFont.lastMade;
            check(sizedDraw(text, mod, 38, "가나", 0, 0).isEmpty() && sizedWidth(text, mod, 38, "가나") == 38, "A font still loading was drawn, or not measured");
            loading.loading = false;
            check(sizedDraw(text, mod, 38, "가나", 0, 0).get(0)[1] == loading, "A font whose pictures came was not drawn");

            // The game makes its fonts again (the option 3): the keys stay; 20 is 1x's Small, read now; 33 is the game's new Medium.
            game("media/fonts/KO/2x/zomboid%sKorean.fnt");
            made = AngelCodeFont.made;
            check(sizedHeight(text, mod, 20) == 19 && AngelCodeFont.made == made + 1, "20 pixels was not read again once the game's fonts changed");
            drawn = sizedDraw(text, mod, 20, "가", 0, 0).get(0);
            check(drawn[1] != gameSmall && file(drawn[1]).endsWith("/KO/1x/zomboidSmallKorean.fnt"), "20 pixels still drew the game's font it made again");
            check(sizedDraw(text, mod, 33, "가", 0, 0).get(0)[1] == TextManager.instance.fonts.get(UIFont.Medium), "33 pixels is not the game's new Medium");
            check(!gameSmall.destroyed && !rootLarge.destroyed, "A font was let go while the language could still use it");

            // English with the dyslexic font: its fontsDyslexic.txt, its one folder; Korean's fonts let go, the game's own not.
            write(root, "media/fonts/EN/fontsDyslexic.txt", "Small fnt=zomboidSmallDyslexic.fnt\nMedium fnt=zomboidMediumDyslexic.fnt\nLarge fnt=zomboidLargeDyslexic.fnt\n");
            fnt(root, "media/fonts/EN/zomboidSmallDyslexic.fnt", 17);
            fnt(root, "media/fonts/EN/zomboidMediumDyslexic.fnt", 24);
            fnt(root, "media/fonts/EN/zomboidLargeDyslexic.fnt", 27);
            Core.dyslexicFont = true;
            Translator.language = new Language("EN");
            game("media/fonts/EN/zomboid%sDyslexic.fnt");
            check(sizedHeight(text, mod, 20) == 17 && texts.sized.faces().length == 3, "The dyslexic fonts were not English's three");
            check(rootLarge.destroyed && loading.destroyed && !gameSmall.destroyed, "Korean's fonts were not let go, or the game's was");
            Core.dyslexicFont = false;

            // A language with its fonts in the fonts' folder alone: the same files for every option, the closest of them.
            write(root, "media/fonts/ZZ/fonts.txt", "Small fnt=zz.fnt\nMedium fnt=zz.fnt\nLarge fnt=zzLarge.fnt\n");
            fnt(root, "media/fonts/zz.fnt", 16);
            fnt(root, "media/fonts/zzLarge.fnt", 26);
            Translator.language = new Language("ZZ");
            game("media/fonts/zz.fnt", "media/fonts/zz.fnt", "media/fonts/zzLarge.fnt");
            texts.embedded = null;
            GameApi.frame(loader);
            check(sizedHeight(text, mod, 18) == 16 && texts.sized.faces().length == 2, "A language without folders did not have its two fonts");
            check(sizedHeight(text, mod, 40) == 40 && sizedWidth(text, mod, 40, "가") == 20, "40 pixels was not the tallest (26) zoomed");

            // No fonts at all: no key, no height, no width, nothing drawn.
            ZomboidFileSystem.FILES.clear();
            TextManager.instance.fonts.put(UIFont.Small, new AngelCodeFont(0xD7A3, 18, 8, false));
            check(sizedKey(text, mod, 20) == 0 && sizedHeight(text, mod, 20) == 0 && sizedWidth(text, mod, 20, "가") == 0
                && sizedDraw(text, mod, 20, "가", 0, 0).isEmpty(), "A language without fonts gave one");

            rejects(text, "px must be a number from 1 to 1024", "font", mod, 0.5);
            rejects(text, "px must be a number from 1 to 1024", "font", mod, 1025.0);
            rejects(text, "px must be a number from 1 to 1024", "font", mod, "20");
            rejects(text, "the first argument must be a handle", "font", table("name", "text.mod"), 20.0);
            rejects(text, "key must be what text.font returned", "measure", mod, 20.5, "x");
            rejects(text, "key must be what text.font returned", "fontHeight", mod, 0.0);
            rejects(text, "text must be a string", "measure", mod, 20.0, 5.0);
            rejects(text, "text must be a string", "draw", mod, 20.0, null, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0);
            rejects(text, "y must be a number", "draw", mod, 20.0, "x", 0.0, Double.NaN, 1.0, 1.0, 1.0, 1.0);
            rejects(text, "a must be a number from 0 to 1", "draw", mod, 20.0, "x", 0.0, 0.0, 1.0, 1.0, 1.0, 2.0);
            rejects(text, "r must be a number from 0 to 1", "draw", mod, 20.0, "x", 0.0, 0.0);

            // Korean again at the option 2: measuring and drawing allocate nothing, at a font's size, zoomed, and in the embedded font.
            ZomboidFileSystem.FILES.putAll(files);
            Translator.language = new Language("KO");
            game("media/fonts/KO/1x/zomboid%sKorean.fnt");
            texts.embedded = new EmbeddedFont.Loaded("test", face, face.chars, 90, 8, ready);
            GameApi.frame(loader);
            SizedFonts sized = texts.sized;
            EmbeddedFont.Loaded own = texts.embedded;
            try {
                check(sized.prepare(20, own) && sized.prepare(60, own), "The heights to time had no font");
                // The fonts read and their pictures found in before the count: the tallest, for the character the embedded font lacks.
                sized.draw(20, "가나다", 10, 10, 1, 1, 1, 1, own);
                sized.draw(60, "똠방", 10, 10, 1, 1, 1, 1, own);
            } catch (Throwable failure) { throw new AssertionError(failure); }
            TextManager.record = false;
            long[] time = new long[1];
            int rounds = 100_000;
            long bytes;
            try {
                bytes = Allocations.median(5, () -> {
                    long clock = System.nanoTime();
                    try {
                        for (int round = 0; round < rounds; round++) {
                            sized.draw(20, "가나다", 10, 10, 1, 1, 1, 1, own);
                            sized.measure(20, "가나다", own);
                            sized.draw(60, "수색", 10, 10, 1, 1, 1, 1, own);
                            sized.measure(60, "수색", own);
                            sized.draw(60, "똠방", 10, 10, 1, 1, 1, 1, own);
                        }
                    } catch (Throwable failure) { throw new AssertionError(failure); }
                    time[0] = System.nanoTime() - clock;
                });
            } finally { TextManager.record = true; }
            System.out.printf("text: text.draw and text.measure cost %.0f ns a pair to place at a font's size, about as much zoomed and in the embedded font;"
                + " %d bytes allocated over %d rounds of five calls%n", time[0] / (double)rounds / 2.5, bytes, rounds);
            check(bytes < 1024, "Measuring and drawing at a height allocated " + bytes + " bytes");
        } finally {
            Translator.language = null;
            Core.dyslexicFont = false;
            AngelCodeFont.loadingNew = false;
            ZomboidFileSystem.FILES.clear();
            TextManager.instance.reset();
            texts.embedded = null;
            GameApi.frame(loader);
            try (var walk = Files.walk(root)) { for (Path path : walk.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
    }

    /** The game's Small, Medium and Large made again from these files ({@code %s} the font's name), as the game does as it starts. */
    private static void game(String pattern) throws IOException {
        game(String.format(pattern, "Small"), String.format(pattern, "Medium"), String.format(pattern, "Large"));
    }

    private static void game(String small, String medium, String large) throws IOException {
        TextManager.instance.fonts.put(UIFont.Small, new AngelCodeFont(small, null));
        TextManager.instance.fonts.put(UIFont.Medium, new AngelCodeFont(medium, null));
        TextManager.instance.fonts.put(UIFont.Large, new AngelCodeFont(large, null));
    }

    /** A file of the game's, there for its file system by its path. */
    private static void write(Path root, String path, String content) throws IOException {
        Path file = root.resolve(path);
        Files.createDirectories(file.getParent());
        Files.writeString(file, content);
        ZomboidFileSystem.FILES.put(path.toLowerCase(Locale.ENGLISH), file.toString());
    }

    /** A font's text file: its line's height, every character to Hangul's last, each half its line wide. */
    private static void fnt(Path root, String path, int height) throws IOException {
        write(root, path, "info face=\"test\" size=" + height + "\ncommon lineHeight=" + height + " base=" + height * 3 / 4 + "\npzext-test last=" + 0xD7A3
            + " advance=" + height / 2 + "\n");
    }

    private static String file(Object font) { return ((AngelCodeFont)font).path.replace('\\', '/'); }

    private static double sizedKey(KahluaTable text, Object mod, double px) {
        Object key = FormulasTest.call(text, "font", mod, px).get(0);
        return key == null ? 0 : (Double)key;
    }

    private static int sizedHeight(KahluaTable text, Object mod, double key) {
        Object height = FormulasTest.call(text, "fontHeight", mod, key).get(0);
        return height == null ? 0 : ((Double)height).intValue();
    }

    private static int sizedWidth(KahluaTable text, Object mod, double key, String words) {
        return ((Double)FormulasTest.call(text, "measure", mod, key, words).get(0)).intValue();
    }

    /** What text.draw drew, in white-orange (1, 0.5, 0.25, 1). */
    private static List<Object[]> sizedDraw(KahluaTable text, Object mod, double key, String words, double x, double y) {
        TextManager.calls.clear();
        FormulasTest.call(text, "draw", mod, key, words, x, y, 1.0, 0.5, 0.25, 1.0);
        return new ArrayList<>(TextManager.calls);
    }

    private static List<String> names(List<Object[]> calls) {
        var names = new ArrayList<String>();
        for (Object[] call : calls) names.add((String)call[0]);
        return names;
    }

    /** The effects, at known moments. */
    private static void effects(KahluaTable text, Object mod) {
        FormulasTest.call(text, "show", mod, table("text", "Slam", "enter", "slam", "enterTime", 0.2, "hold", 0.0, "leave", "grow", "leaveTime", 1.0));
        render();
        check(draws().isEmpty(), "A slam starts seen");
        advance(0.1);
        render();
        check(near(zoom(draws().get(0)), 1 + 1.5 * 0.75) && near(alpha(draws().get(0)), 1), "Halfway, the slam is at " + zoom(draws().get(0)));
        advance(0.1);
        render();
        check(near(zoom(draws().get(0)), 1), "The slam did not land at its size");
        advance(0.5);
        render();
        check(near(zoom(draws().get(0)), 1.15) && near(alpha(draws().get(0)), 0.5), "Halfway out, the growth is " + zoom(draws().get(0)));
        advance(0.5);
        render();
        check(draws().isEmpty(), "The slam did not go");

        // Settling: at its size throughout; halfway, half seen and above its place by 1/8 (cubic out) of 0.3 lines; in place at the end.
        FormulasTest.call(text, "show", mod, table("text", "Settle", "enter", "settle", "enterTime", 1.0, "hold", 0.0, "leave", "fade", "leaveTime", 0.2));
        render();
        advance(0.5);
        render();
        double half = (Double)draws().get(0)[3];
        check(near(zoom(draws().get(0)), 1) && near(alpha(draws().get(0)), 0.5), "Halfway, the settle is at " + zoom(draws().get(0)));
        advance(0.5);
        render();
        double placed = (Double)draws().get(0)[3];
        check(near(zoom(draws().get(0)), 1) && placed > half,"The settle did not come down into place: " + half + " to " + placed);
        advance(0.3);
        render();
        check(draws().isEmpty(), "The settle did not go");

        double key = (Double)FormulasTest.call(text, "show", mod, table("text", "Rise", "enter", "rise", "enterTime", 1.0, "leave", "rise", "leaveTime", 1.0)).get(0);
        render();
        advance(0.5);
        render();
        double eased = 1 - 0.125;
        check(near((Double)draws().get(0)[3], 450 - 16.5 + 0.75 * (1 - eased) * 33) && near(alpha(draws().get(0)), eased),
            "Halfway, the rise is at " + draws().get(0)[3]);
        advance(0.5);
        render();
        check(near((Double)draws().get(0)[3], 433.5), "The rise did not end in its place");
        FormulasTest.call(text, "hide", mod, key);
        advance(0.5);
        render();
        check(near((Double)draws().get(0)[3], 433.5 - 0.5 * 0.5 * 33) && near(alpha(draws().get(0)), 0.5), "Leaving, the text did not rise");
        advance(0.5);
        render();

        // Hidden halfway in, it leaves from where it was.
        key = (Double)FormulasTest.call(text, "show", mod, table("text", "Pop", "enter", "pop", "enterTime", 1.0, "leave", "fade", "leaveTime", 1.0)).get(0);
        render();
        advance(0.25);
        FormulasTest.call(text, "hide", mod, key);
        render();
        double at = zoom(draws().get(0));
        advance(0.5);
        render();
        check(near(zoom(draws().get(0)), at) && near(alpha(draws().get(0)), 0.5 * 0.5), "A text hidden as it came did not leave from where it was");
        advance(0.5);
        render();
        check(draws().isEmpty(), "The pop did not go");
    }

    /** Typing: characters at their times, the hold counted from the last; markup pauses and speeds; a cursor that blinks; colours. */
    private static void typing(KahluaTable text, Object mod) {
        // 10 characters a second: the first at once, then one every 0.1 s; the row is placed by its whole width (75), so nothing moves.
        double key = showing(text, mod, "text", "Hello", "enter", "type", "speed", 10.0, "hold", 1.0);
        render();
        drawn(draws().get(0), UIFont.Large, 762.5, 433.5, 1, "H", 1, 1, 1, 1);
        check(draws().size() == 1, "More than the first character came on at once");
        advance(0.25);
        render();
        drawn(draws().get(0), UIFont.Large, 762.5, 433.5, 1, "Hel", 1, 1, 1, 1);
        advance(0.2);
        render();
        drawn(draws().get(0), UIFont.Large, 762.5, 433.5, 1, "Hello", 1, 1, 1, 1);
        // Typing takes 0.5 s, the hold starts then: the text goes at 1.5 s.
        advance(1.0);
        render();
        check(draws().size() == 1, "The hold did not start when typing was over");
        advance(0.1);
        render();
        check(draws().isEmpty() && !(Boolean)FormulasTest.call(text, "shown", mod, key).get(0), "A typed text outlived its hold");

        // The default is 30 characters a second.
        showing(text, mod, "text", "Slow down", "enter", "type");
        render();
        advance(0.07);
        render();
        check("Slo".equals(draws().get(0)[5]), "The default speed is not 30 a second: " + draws().get(0)[5]);
        FormulasTest.call(mod, "clear");

        // Hidden while typing: it leaves with what had come on.
        key = showing(text, mod, "text", "Hello", "enter", "type", "speed", 10.0, "leave", "fade", "leaveTime", 1.0);
        render();
        advance(0.15);
        FormulasTest.call(text, "hide", mod, key);
        render();
        advance(0.2);
        render();
        check("He".equals(draws().get(0)[5]) && near(alpha(draws().get(0)), 1 - 0.2 * 0.2 * (3 - 2 * 0.2)), "A typed text hidden midway did not leave as it was: " + draws().get(0)[5]);
        FormulasTest.call(mod, "clear");

        // Markup: a pause is added to the gap after the character before it, {s:2} slows what follows.
        // A at 0, B at 1.1 (after 0.1 and a pause of 1), C at 1.2, D at 1.7 (2 a second); typing takes 2.2 s.
        key = showing(text, mod, "text", "A{p:1}B{s:2}CD", "markup", true, "enter", "type", "speed", 10.0, "hold", 1.0);
        render();
        advance(0.5);
        render();
        check("A".equals(draws().get(0)[5]), "The pause did not hold the text back: " + draws().get(0)[5]);
        advance(0.65);
        render();
        check("AB".equals(draws().get(0)[5]), "The text did not go on after its pause: " + draws().get(0)[5]);
        advance(0.1);
        render();
        check("ABC".equals(draws().get(0)[5]), "The speed change came late: " + draws().get(0)[5]);
        advance(0.4);
        render();
        check("ABC".equals(draws().get(0)[5]), "The slower speed was not slower: " + draws().get(0)[5]);
        advance(0.2);
        render();
        drawn(draws().get(0), UIFont.Large, 770, 433.5, 1, "ABCD", 1, 1, 1, 1);
        advance(1.3);
        render();
        check(draws().size() == 1, "The hold did not start when the last character's turn was over");
        advance(0.2);
        render();
        check(draws().isEmpty(), "A typed text with markup outlived its hold");
        // {s} goes back to the text's own speed; a pause at the end belongs to the typing (the hold starts after it).
        key = showing(text, mod, "text", "{s:1}A{s}B{p:2}", "markup", true, "enter", "type", "speed", 10.0, "hold", 1.0);
        render();
        advance(0.95);
        render();
        check("A".equals(draws().get(0)[5]), "A slow character came early: " + draws().get(0)[5]);
        advance(0.1);
        render();
        check("AB".equals(draws().get(0)[5]), "{s} did not go back to the text's speed: " + draws().get(0)[5]);
        // A takes 1 s, B 0.1, the pause 2: typing is over at 3.1 s and the text goes at 4.1.
        advance(2.9);
        render();
        check(draws().size() == 1, "A pause at the end did not delay the hold");
        advance(0.2);
        render();
        check(draws().isEmpty(), "The hold was not counted from the end of the pause at the end");

        // Markup without typing: the pauses and speeds mean nothing, the colours and the braces do.
        showing(text, mod, "text", "a{p:3}b{s:5}c{{d}}", "markup", true);
        render();
        drawn(draws().get(0), UIFont.Large, 755, 433.5, 1, "abc{d}", 1, 1, 1, 1);
        FormulasTest.call(mod, "clear");
        // Without markup = true the braces are the text.
        showing(text, mod, "text", "a{p:3}b", "enter", "type", "speed", 1000.0);
        render();
        advance(0.1);
        render();
        check("a{p:3}b".equals(draws().get(0)[5]), "Braces were read without markup: " + draws().get(0)[5]);
        FormulasTest.call(mod, "clear");

        // Colours: one string for each run, placed by the whole row (6 characters, 90 wide).
        showing(text, mod, "text", "ab{c:FF8000}cd{/c}ef", "markup", true, "color", list(1.0, 1.0, 1.0, 0.5));
        render();
        var runs = draws();
        check(runs.size() == 3, "A row with a colour is not 3 runs: " + runs.size());
        drawn(runs.get(0), UIFont.Large, 755, 433.5, 1, "ab", 1, 1, 1, 0.5);
        drawn(runs.get(1), UIFont.Large, 785, 433.5, 1, "cd", 1, 128 / 255.0, 0, 0.5);
        drawn(runs.get(2), UIFont.Large, 815, 433.5, 1, "ef", 1, 1, 1, 0.5);
        FormulasTest.call(mod, "clear");

        // Colours while typing: the run being typed is cut where the typing is, in its own colour, and does not move.
        showing(text, mod, "text", "ab{c:00FF00}cd{/c}", "markup", true, "enter", "type", "speed", 10.0);
        render();
        advance(0.25);
        render();
        runs = draws();
        check(runs.size() == 2, "A typed row with a colour is not 2 runs yet: " + runs.size());
        drawn(runs.get(0), UIFont.Large, 770, 433.5, 1, "ab", 1, 1, 1, 1);
        drawn(runs.get(1), UIFont.Large, 800, 433.5, 1, "c", 0, 1, 0, 1);
        FormulasTest.call(mod, "clear");

        // The cursor is an underscore after the last character that came on: on while characters come, blinking while it waits.
        showing(text, mod, "text", "Hi", "enter", "type", "speed", 10.0, "cursor", true, "hold", 5.0);
        render();
        drawn(draws().get(0), UIFont.Large, 785, 433.5, 1, "H", 1, 1, 1, 1);
        drawn(draws().get(1), UIFont.Large, 800, 433.5, 1, "_", 1, 1, 1, 1);
        advance(0.15);
        render();
        drawn(draws().get(1), UIFont.Large, 815, 433.5, 1, "_", 1, 1, 1, 1);
        // 0.5 s after the last character it goes off, and 0.5 s later it is on again.
        advance(0.5);
        render();
        check(draws().size() == 1 && "Hi".equals(draws().get(0)[5]), "The cursor did not blink off: " + draws().size());
        advance(0.5);
        render();
        check(draws().size() == 2 && "_".equals(draws().get(1)[5]), "The cursor did not blink on");
        // Taken away by a move (the text stays where it is).
        double typed = (Double)FormulasTest.call(text, "show", mod, table("text", "Hi", "enter", "type", "speed", 10.0, "cursor", true, "y", 0.1)).get(0);
        render();
        check(last("_") != null, "The second text has no cursor");
        FormulasTest.call(text, "move", mod, typed, table("cursor", false));
        render();
        check(draws().size() == 3, "The moved text kept its cursor: " + draws().size());
        FormulasTest.call(mod, "clear");
        // Before the first character (a pause first) it is at the start.
        showing(text, mod, "text", "{p:1}Hi", "markup", true, "enter", "type", "speed", 10.0, "cursor", true, "align", "left", "x", 0.1);
        render();
        check(draws().size() == 1 && "_".equals(draws().get(0)[5]) && near((Double)draws().get(0)[2], 160), "The cursor is not at the start before the first character");
        FormulasTest.call(mod, "clear");

        // Rows fitted to a width: breaks at spaces; each row centred on its own width; the rows laid out as a block.
        // 0.1 of 1600 is 160, 10 characters of 15: "aaaa bbbb" fits (135), the next word does not.
        key = showing(text, mod, "text", "aaaa bbbb cccc dd", "width", 0.1);
        render();
        runs = draws();
        check(runs.size() == 2, "The text was not broken in two rows: " + runs.size());
        drawn(runs.get(0), UIFont.Large, 732.5, 417, 1, "aaaa bbbb", 1, 1, 1, 1);
        drawn(runs.get(1), UIFont.Large, 747.5, 450, 1, "cccc dd", 1, 1, 1, 1);
        FormulasTest.call(text, "hide", mod, key, true);
        // A line of its own stays; a word wider than the width is broken by characters; an empty line stays.
        showing(text, mod, "text", "ab cd\n\nabcdefghijklmnopqrstuvwxyz", "width", 0.1, "align", "left", "x", 0.0);
        render();
        runs = draws();
        check(runs.size() == 4 && "ab cd".equals(runs.get(0)[5]) && "abcdefghij".equals(runs.get(1)[5]) && "klmnopqrst".equals(runs.get(2)[5])
            && "uvwxyz".equals(runs.get(3)[5]), "Lines and a long word were not broken as they should: " + runs.size());
        // Five rows of 33 centred on 450: the empty one has a place.
        check(near((Double)runs.get(0)[3], 450 - 82.5) && near((Double)runs.get(1)[3], 450 - 82.5 + 66) && near((Double)runs.get(3)[3], 450 - 82.5 + 132),
            "The rows are not placed as a block");
        FormulasTest.call(mod, "clear");
        // The width is that of the text at its own size: a size of 0.1 (zoom 2.727) leaves room for 3 characters.
        showing(text, mod, "text", "abcdef ghi", "width", 0.1, "size", 0.1);
        render();
        runs = draws();
        check(runs.size() == 3 && "abc".equals(runs.get(0)[5]) && "def".equals(runs.get(1)[5]) && "ghi".equals(runs.get(2)[5]),
            "A sized text was not broken for its zoom: " + runs.size());
        FormulasTest.call(mod, "clear");
        // Wrapped and typed: the rows are those of the whole text, so what is typed stays where it will be.
        showing(text, mod, "text", "aaaa bbbb cccc dd", "width", 0.1, "enter", "type", "speed", 10.0, "cursor", true);
        render();
        advance(0.25);
        render();
        drawn(draws().get(0), UIFont.Large, 732.5, 417, 1, "aaa", 1, 1, 1, 1);
        check(near((Double)draws().get(1)[2], 732.5 + 45) && "_".equals(draws().get(1)[5]), "The cursor is not after the third character");
        advance(0.8);
        render();
        // 11 characters by 1.05 s: the space after the second word was typed, and the first letter of the third word.
        runs = draws();
        check(runs.size() == 3 && "aaaa bbbb".equals(runs.get(0)[5]) && "c".equals(runs.get(1)[5]), "The second row did not start with the third word: " + runs.size());
        drawn(runs.get(1), UIFont.Large, 747.5, 450, 1, "c", 1, 1, 1, 1);
        check(near((Double)runs.get(2)[2], 747.5 + 15), "The cursor did not go on to the next row");
        FormulasTest.call(mod, "clear");

        // Fitted for each screen: split screen halves of 1600 and 800 wide break the text where each has room.
        IsoPlayer.players[1] = new IsoPlayer();
        IsoCamera.width[1] = 800;
        IsoCamera.left[1] = 800;
        try {
            showing(text, mod, "text", "ab cd ef gh", "width", 0.2);
            render();
            runs = draws();
            check(runs.size() == 3 && "ab cd ef gh".equals(runs.get(0)[5]) && "ab cd ef".equals(runs.get(1)[5]) && "gh".equals(runs.get(2)[5]),
                "The text was not fitted to each screen: " + runs.size());
            render();
            check(draws().size() == 3, "The rows of a screen were lost between frames");
        } finally {
            IsoPlayer.players[1] = null;
            IsoCamera.width[1] = 1600;
            IsoCamera.left[1] = 0;
        }
        FormulasTest.call(mod, "clear");
        // A new font is fitted again.
        showing(text, mod, "text", "aaaa bbbb cccc dd", "width", 0.1);
        render();
        TextManager.instance.fonts.put(UIFont.Large, new zombie.core.fonts.AngelCodeFont(0xD7A3, 33, 20, false));
        render();
        check(draws().size() == 3 && "aaaa".equals(draws().get(0)[5]), "A new font did not make a new fit: " + draws().size());
        TextManager.instance.reset();
        FormulasTest.call(mod, "clear");
        // Han has no spaces: a row may break beside its characters.
        showing(text, mod, "text", "一二三四五六", "width", 0.05);
        render();
        check(draws().size() == 2 && "一二三四五".equals(draws().get(0)[5]) && "六".equals(draws().get(1)[5]),
            "Han was not broken between characters: " + draws().size());
        FormulasTest.call(mod, "clear");
    }

    /** What typing, colours and rows cost once the characters are there: nothing allocated. */
    private static void typingCost(KahluaTable text, Object mod) {
        showing(text, mod, "text", "ab{c:FF8000}cd{/c} ef gh ij kl", "markup", true, "width", 0.1, "enter", "type", "speed", 100.0, "cursor", true, "hold", 1000.0);
        render();
        // Every prefix is made once, as its character comes on.
        for (int step = 0; step < 40; step++) {
            advance(0.011);
            render();
        }
        advance(1);
        render();
        advance(0.2);
        render();
        TextManager.record = false;
        long bytes;
        try {
            // Frames on both sides of the cursor's blinks: 1 s of the clock for each hundred.
            bytes = Allocations.median(5, () -> {
                for (int frame = 0; frame < 100_000; frame++) {
                    if (frame % 100 == 0) advance(0.1);
                    UIManager.render();
                }
            });
        } finally { TextManager.record = true; }
        check(bytes < 4096, "A typed text with colours and rows allocated " + bytes + " bytes in 100,000 frames");
        FormulasTest.call(mod, "clear");
    }

    private static double showing(KahluaTable text, Object mod, Object... pairs) {
        return (Double)FormulasTest.call(text, "show", mod, table(pairs)).get(0);
    }

    /** Titles: their styles, one after another, at once when asked, and a full queue. */
    private static void titles(KahluaTable text, Object mod) {
        double quest = (Double)FormulasTest.call(text, "title", mod, table("text", "Quest complete", "subtitle", "The well is clean", "style", "stamp")).get(0);
        double found = (Double)FormulasTest.call(text, "title", mod, table("text", "Search complete", "subtitle", "3 items", "style", "discovery")).get(0);
        render();
        check(draws().isEmpty(), "A stamp starts seen, or the second title did not wait");
        // (Its picture is never made here, the render thread not running: the text is drawn as it is.)
        advance(1.2);
        zombie.core.SpriteRenderer.shaded.clear();
        render();
        Object[] title = last("Quest complete"), line = last("The well is clean");
        // One black backdrop for the title and its line, in one layer, come in over 1.2 s: the box (0.3 over it, reaching to the
        // line's bottom at 0.28 of 900) and four rings of eight quads round it, shaded to nothing at the outside (2.6 lines to the sides).
        var quads = new ArrayList<>(zombie.core.SpriteRenderer.shaded);
        Object[] box = quads.isEmpty() ? null : quads.get(0);
        boolean black = true, outsideClear = true;
        double leftmost = Double.POSITIVE_INFINITY;
        for (Object[] quad : quads) {
            black &= (Float)quad[13] == 0f;
            leftmost = Math.min(leftmost, (Double)quad[1]);
        }
        for (int index = quads.size() - 8; index >= 0 && index < quads.size(); index++) outsideClear &= Math.min(Math.min((Float)quad(quads, index)[9], (Float)quad(quads, index)[10]), Math.min((Float)quad(quads, index)[11], (Float)quad(quads, index)[12])) < 1e-6f;
        check(quads.size() == 33 && black && outsideClear && near((Float)box[9], 0.3) && near((Float)box[11], 0.3) && near((Double)box[6], 0.28 * 900)
            && near((Double)box[1] - leftmost, 2.6 * 90), "The title's backdrop is wrong: " + quads.size() + " quads");
        double zoom = 0.1 * 900 / 45, lineZoom = 0.045 * 900 / 45;
        drawn(title, UIFont.SdfBold, 800 - 14 * 20 * zoom / 2, 0.16 * 900 - 45 * zoom / 2, zoom, "Quest complete", 0.9, 0.89, 0.86, 1);
        check(line != null && line[1] == UIFont.SdfRegular && near(zoom(line), lineZoom)
            && near((Double)line[3], (0.16 + 0.1 / 2 + 0.1 * 0.25 + 0.045 / 2) * 900 - 45 * lineZoom / 2), "The line under the title is not under it");
        check(last("Search complete") == null, "The second title did not wait");
        // The stamp and its line go together, after 0.75 + 5 + 6 seconds (its hold from when its line is in at 0.15 + 0.6; the line
        // 0.4 s after the title, for 5.6).
        advance(8.8);
        render();
        check(last("Quest complete") != null && last("The well is clean") != null, "The stamp went early");
        advance(1.96);
        render();
        check(last("Quest complete") == null && last("The well is clean") == null && last("Search complete") == null, "The stamp outlived its time, or the next did not wait for it");
        check(!(Boolean)FormulasTest.call(text, "shown", mod, quest).get(0) && (Boolean)FormulasTest.call(text, "shown", mod, found).get(0), "shown is wrong");
        render();
        advance(0.6);
        render();
        Object[] search = last("Search complete");
        check(search != null && search[1] == UIFont.SdfBold && near((Double)search[6], 1) && near((Double)search[7], 0.8) && near((Double)search[8], 0.38),
            "The discovery is not amber in its own font");

        // Now: the title on the screen leaves quickly, and this one follows.
        double danger = (Double)FormulasTest.call(text, "title", mod, table("text", "Run", "style", "notice", "now", true, "color", list(1.0, 0.3, 0.2, 1.0))).get(0);
        advance(0.1);
        render();
        check(last("Search complete") != null && last("Run") == null, "The title on the screen did not leave first");
        advance(0.2);
        render();
        check(last("Search complete") == null, "The title on the screen did not leave quickly");
        render();
        advance(0.35);
        render();
        Object[] run = last("Run");
        check(run != null && near((Double)run[6], 1) && near((Double)run[7], 0.3), "The title asked for now did not follow, in its colour");
        FormulasTest.call(text, "hide", mod, danger, true);

        // A brief title is in a queue of its own: it does not wait for a title. Another brief one waits for it, but not for its ash
        // (a flare's leave of 3.5 s after 0.45 + 3, its ash 3.5 s more).
        double stage = (Double)FormulasTest.call(text, "title", mod, table("text", "Stage 7", "style", "dust")).get(0);
        double bonus = (Double)FormulasTest.call(text, "title", mod, table("text", "+340 credits", "style", "brief")).get(0);
        double fitted = (Double)FormulasTest.call(text, "title", mod, table("text", "Bag: 30", "style", "brief")).get(0);
        render();
        advance(0.5);
        render();
        Object[] brief = last("+340 credits");
        check(last("Stage 7") != null && brief != null && brief[1] == UIFont.SdfRegular && near((Double)brief[3], 0.8 * 900 - 45 * (0.036 * 900 / 45) / 2),
            "A brief title waited for a title, or is not low on the screen in its font");
        check(last("Bag: 30") == null, "A brief title did not wait for the one before it");
        advance(6.6);
        render();
        render();
        advance(0.3);
        render();
        check((Boolean)FormulasTest.call(text, "shown", mod, bonus).get(0) && last("Bag: 30") != null,
            "A brief title's ash held its queue, or it went before its ash");
        advance(3.6);
        render();
        check(!(Boolean)FormulasTest.call(text, "shown", mod, bonus).get(0), "A brief title outlived its ash");
        for (double key : new double[] { stage, fitted }) FormulasTest.call(text, "hide", mod, key, true);
        render();

        // Hangul: the language's font.
        double hangul = (Double)FormulasTest.call(text, "title", mod, table("text", "수색 완료", "style", "discovery")).get(0);
        render();
        advance(0.6);
        render();
        check(last("수색 완료")[1] == UIFont.Large, "A Hangul title is not in the language's font");
        // A full queue: the oldest waiting goes.
        var keys = new ArrayList<Double>();
        for (int index = 0; index < Texts.MAX_WAITING + 1; index++)
            keys.add((Double)FormulasTest.call(text, "title", mod, table("text", "T" + index)).get(0));
        check(!(Boolean)FormulasTest.call(text, "shown", mod, keys.get(0)).get(0) && (Boolean)FormulasTest.call(text, "shown", mod, keys.get(1)).get(0),
            "A full queue did not let the oldest waiting go");
        FormulasTest.call(text, "hide", mod, hangul, true);
        for (double key : keys) FormulasTest.call(text, "hide", mod, key, true);
        render();
        check(draws().isEmpty(), "Hidden titles were drawn");
    }

    /** Split screen: each local player's part; a text for one player on that one alone; titles queued on each; the main menu. */
    private static void screens(KahluaTable text, Object mod) {
        IsoPlayer.players[1] = new IsoPlayer();
        IsoCamera.height[0] = IsoCamera.height[1] = 450;
        IsoCamera.top[1] = 450;
        try {
            double both = (Double)FormulasTest.call(text, "show", mod, table("text", "Both")).get(0);
            double one = (Double)FormulasTest.call(text, "show", mod, table("text", "One", "player", 1.0)).get(0);
            render();
            var draws = draws();
            check(draws.size() == 3 && near((Double)draws.get(0)[3], 225 - 16.5) && near((Double)draws.get(2)[3], 675 - 16.5)
                && "One".equals(draws.get(2)[5]), "The texts are not on the players' screens: " + draws.size());
            FormulasTest.call(text, "hide", mod, both, true);
            FormulasTest.call(text, "hide", mod, one, true);
            double title = (Double)FormulasTest.call(text, "title", mod, table("text", "Shared", "style", "notice")).get(0);
            double own = (Double)FormulasTest.call(text, "title", mod, table("text", "Second", "style", "notice", "player", 1.0)).get(0);
            render();
            advance(0.35);
            render();
            draws = draws();
            check(draws.stream().filter(drawn -> "Shared".equals(drawn[5])).count() == 4 && last("Second") == null,
                "A title for every player is not on both screens, or the second did not wait on its own: " + draws.size());
            FormulasTest.call(text, "hide", mod, title, true);
            render();
            advance(0.35);
            render();
            check(last("Second") != null && near((Double)last("Second")[3] - 450, 0.16 * 450 - 0.04 * 450 * 45 / 45 / 2), "The second title is not on its screen");
            FormulasTest.call(text, "hide", mod, own, true);
        } finally {
            IsoPlayer.players[1] = null;
            IsoCamera.height[0] = IsoCamera.height[1] = 900;
            IsoCamera.top[1] = 0;
        }
        // No local player (the main menu): the whole screen.
        IsoPlayer player = IsoPlayer.players[0];
        IsoPlayer.players[0] = null;
        try {
            double key = (Double)FormulasTest.call(text, "show", mod, table("text", "Menu")).get(0);
            render();
            check(draws().size() == 1 && near((Double)draws().get(0)[3], 500 - 16.5), "Without a player the text is not on the whole screen");
            FormulasTest.call(text, "hide", mod, key, true);
        } finally { IsoPlayer.players[0] = player; }
    }

    /** A world left takes its texts; clear takes a mod's. */
    private static void world(KahluaTable text, Object mod, Object other) {
        ClassLoader game = TextsTest.class.getClassLoader();
        double mine = (Double)FormulasTest.call(text, "show", mod, table("text", "Mine")).get(0);
        double theirs = (Double)FormulasTest.call(text, "show", other, table("text", "Theirs")).get(0);
        render();
        check(draws().size() == 2, "Two mods' texts were not both drawn");
        FormulasTest.call(mod, "clear");
        render();
        check(draws().size() == 1 && "Theirs".equals(draws().get(0)[5]) && !(Boolean)FormulasTest.call(text, "shown", mod, mine).get(0),
            "clear did not take the mod's text alone");
        GameApi.frame(game);
        IsoWorld.instance.setCell(new IsoCell());
        GameApi.frame(game);
        render();
        check(draws().isEmpty() && !(Boolean)FormulasTest.call(text, "shown", other, theirs).get(0), "A text outlived its world");
        double kept = (Double)FormulasTest.call(text, "show", mod, table("text", "Kept")).get(0);
        GameApi.frame(game);
        render();
        check(draws().size() == 1 && (Boolean)FormulasTest.call(text, "shown", mod, kept).get(0), "A text of the new world went");
        FormulasTest.call(text, "hide", mod, kept, true);
    }

    private static void rejects(KahluaTable api, KahluaTable text, Object mod) {
        rejects(text, "spec.text must be", "show", mod, table("font", "Large"));
        rejects(text, "spec has no field colour", "show", mod, table("text", "x", "colour", list(1.0, 1.0, 1.0)));
        rejects(text, "the game has no font Comic", "show", mod, table("text", "x", "font", "Comic"));
        rejects(text, "spec.color must be a table", "show", mod, table("text", "x", "color", list(2.0, 0.0, 0.0)));
        rejects(text, "at most 8", "show", mod, table("text", "1\n2\n3\n4\n5\n6\n7\n8\n9"));
        rejects(text, "spec.enter must be one of", "show", mod, table("text", "x", "enter", "spin"));
        rejects(text, "spec.player must be a player index", "show", mod, table("text", "x", "player", 4.0));
        rejects(text, "spec.size must be a number from", "show", mod, table("text", "x", "size", 2.0));
        rejects(text, "the first argument must be a handle", "show", table("name", "text.mod"), table("text", "x"));
        rejects(text, "spec.style must be one of stamp, discovery, notice", "title", mod, table("text", "x", "style", "loud"));
        rejects(text, "spec has no field font", "title", mod, table("text", "x", "font", "Large"));
        rejects(text, "key must be", "hide", mod, "a");
        rejects(text, "spec.markup must be true or false", "show", mod, table("text", "x", "markup", "yes"));
        rejects(text, "spec.width must be a number from 0.05 to 1", "show", mod, table("text", "x", "width", 2.0));
        rejects(text, "spec.speed must be a number from 1 to 1000", "show", mod, table("text", "x", "enter", "type", "speed", 0.5));
        rejects(text, "spec.speed and spec.cursor go with spec.enter = \"type\"", "show", mod, table("text", "x", "speed", 10.0));
        rejects(text, "spec.speed and spec.cursor go with spec.enter = \"type\"", "show", mod, table("text", "x", "cursor", true));
        rejects(text, "spec.enterTime does not go with enter = \"type\"", "show", mod, table("text", "x", "enter", "type", "enterTime", 1.0));
        rejects(text, "spec.enter must be one of \"none\", \"fade\", \"pop\", \"slam\", \"settle\", \"rise\", \"drop\", \"type\"", "show", mod, table("text", "x", "enter", "spin"));
        String[][] markup = {
            { "a{p:abc}", "{p:abc} must be {p:seconds}" }, { "a{p:31}", "{p:31} must be {p:seconds}, from 0 to 30" }, { "a{p}", "{p} must be {p:seconds}" },
            { "a{p:-1}", "{p:-1} must be {p:seconds}" }, { "a{s:0}", "{s:0} must be {s:characters a second}" },
            { "a{s:2000}", "{s:2000} must be {s:characters a second}" }, { "a{c:12}", "{c:12} must be {c:RRGGBB}" },
            { "a{c:FF0000}b{c:00FF00}", "inside a colour that is not closed" }, { "a{/c}", "{/c} with no {c:RRGGBB} before it" },
            { "a{c:FF0000}b", "a {c:RRGGBB} that is not closed with {/c}" }, { "a{x}", "{x} is not {p:seconds}" },
            { "a}b", "a } with no { before it" }, { "a{b", "a { with no } after it" }, { "{p:1}", "no characters are left once the markup is read" },
            { "a{p:30}b{p:30}c{p:30}d{p:30}e{p:30}f{p:30}g{p:30}h{p:30}i{p:30}j{p:30}k{p:30}l", "seconds to type; at most 300" } };
        for (String[] bad : markup)
            rejects(text, bad[1], "show", mod, table("text", bad[0], "markup", true, "enter", "type", "speed", 1000.0));
        rejects(text, "takes 400 seconds to type; at most 300", "show", mod, table("text", "x".repeat(400), "enter", "type", "speed", 1.0));
        rejects(text, "has 9 lines; at most 8", "show", mod, table("text", "1\n2\n3\n4\n5\n6\n7\n8\n{p:1}9", "markup", true));
        var keys = new ArrayList<Double>();
        for (int index = 0; index < Texts.MAX_PER_MOD; index++) keys.add((Double)FormulasTest.call(text, "show", mod, table("text", "n" + index)).get(0));
        rejects(text, "at most " + Texts.MAX_PER_MOD, "show", mod, table("text", "one more"));
        Object busy = FormulasTest.call(api, "client", "busy.mod").get(0);
        check(FormulasTest.call(text, "show", busy, table("text", "another mod's")).get(0) != null, "One mod's texts held another's back");
        FormulasTest.call(mod, "clear");
        FormulasTest.call(busy, "clear");
    }

    /** A drawing that fails: the hook reports it and the interface is drawn all the same; drawing again once it works. */
    private static void failing(KahluaTable text, Object mod) {
        double key = (Double)FormulasTest.call(text, "show", mod, table("text", "Fails")).get(0);
        TextManager.fail = true;
        try { render(); } finally { TextManager.fail = false; }
        check(names().equals(List.of("windows", "tooltip", "post")), "A failing drawing cost the interface: " + names());
        render();
        check(draws().size() == 1, "The text was not drawn again once it could be");
        FormulasTest.call(text, "hide", mod, key, true);
    }

    /** What a frame costs with a title and its line on the screen: no allocation. */
    private static void cost(KahluaTable text, Object mod) {
        double key = (Double)FormulasTest.call(text, "title", mod, table("text", "Search complete", "subtitle", "3 items", "hold", 100.0, "style", "discovery")).get(0);
        render();
        advance(2.5);
        render();
        check(draws().size() == 12, "The title and its line are not drawn with their copies: " + draws().size());
        TextManager.record = false;
        long bytes;
        long[] time = new long[1];
        int frames = 100_000;
        try {
            // The median of 5 rounds (see Allocations); the time is the last round's.
            bytes = Allocations.median(5, () -> {
                long clock = System.nanoTime();
                for (int frame = 0; frame < frames; frame++) UIManager.render();
                time[0] = System.nanoTime() - clock;
            });
        } finally { TextManager.record = true; }
        System.out.printf("text: a title with its line (12 strings) costs %.0f ns a frame to place, allocating %d bytes over %d frames%n",
            time[0] / (double)frames, bytes, frames);
        check(bytes < 4096, "Drawing a title allocated " + bytes + " bytes");
        FormulasTest.call(text, "hide", mod, key, true);
    }

    /** A newer API takes what is shown over, at the moment it was at; the functions a mod kept refuse. */
    private static void takeover(KahluaTable api, KahluaTable text, Object mod) throws Exception {
        Object kept = text.rawget("show");
        double key = (Double)FormulasTest.call(text, "show", mod, table("text", "Kept", "enter", "fade", "enterTime", 2.0)).get(0);
        render();
        advance(1);
        GameApi.frame(TextsTest.class.getClassLoader());
        GameApi.register(LuaManager.class);
        useClock();
        render();
        check(draws().size() == 1 && near(alpha(draws().get(0)), 0.5), "The newer API did not take the text over where it was");
        check((Boolean)FormulasTest.call(text, "shown", mod, key).get(0), "The newer API does not know the text");
        double next = (Double)FormulasTest.call(text, "show", mod, table("text", "Next")).get(0);
        check(next > key, "The newer API gave a key again");
        try {
            var frame = new LuaCallFrame(mod, table("text", "x"));
            ((JavaFunction)kept).call(frame, 2);
            throw new AssertionError("A function of the replaced API was called");
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains("the API was updated"), expected.getMessage());
        }
        FormulasTest.call(mod, "clear");
        render();
        check(draws().isEmpty(), "clear left a text taken over");
    }

    /** A typed text goes on typing under a newer API, which reads its markup again; a text kept before typing is shown as it was. */
    private static void takeoverTyped(KahluaTable api, KahluaTable text, Object mod) throws Exception {
        ClassLoader game = TextsTest.class.getClassLoader();
        // T at 0, y at 0.1, then a pause of 1 s: p at 1.2, e at 1.3, d at 1.4.
        double key = showing(text, mod, "text", "Ty{p:1}ped", "markup", true, "enter", "type", "speed", 10.0, "hold", 100.0);
        render();
        advance(0.25);
        render();
        check("Ty".equals(draws().get(0)[5]), "The text was not typed: " + draws().get(0)[5]);
        GameApi.frame(game);
        GameApi.register(LuaManager.class);
        useClock();
        render();
        drawn(draws().get(0), UIFont.Large, 800 - 5 * 15 / 2.0, 433.5, 1, "Ty", 1, 1, 1, 1);
        check((Boolean)FormulasTest.call(text, "shown", mod, key).get(0), "The newer API does not know the typed text");
        advance(1.0);
        render();
        check("Typ".equals(draws().get(0)[5]), "The newer API did not go on typing after the pause: " + draws().get(0)[5]);
        advance(0.2);
        render();
        check("Typed".equals(draws().get(0)[5]), "The newer API did not finish typing: " + draws().get(0)[5]);
        FormulasTest.call(mod, "clear");

        // What the API before typing kept has the fields up to hidden alone.
        showing(text, mod, "text", "Old", "enter", "fade", "enterTime", 2.0);
        render();
        advance(1);
        GameApi.frame(game);
        KahluaTable meta = api.getMetatable();
        String[] kept = ((String)meta.rawget("texts")).split("\n");
        var before = new StringBuilder("pzext-texts 1");
        for (int row = 1; row < kept.length; row++) {
            String[] fields = kept[row].split("\t", -1);
            before.append('\n').append("T".equals(fields[0]) ? String.join("\t", Arrays.copyOf(fields, 31)) : kept[row]);
        }
        meta.rawset("texts", before.toString());
        meta.rawset("textsHandover", null);
        GameApi.register(LuaManager.class);
        useClock();
        render();
        check(draws().size() == 1 && "Old".equals(draws().get(0)[5]) && near(alpha(draws().get(0)), 0.5), "A text kept before typing was not taken over");
        FormulasTest.call(mod, "clear");
        render();
        check(draws().isEmpty(), "clear left a text taken over");
    }

    // ---- helpers ----

    private static void render() {
        TextManager.calls.clear();
        UIManager.render();
    }

    private static List<String> names() {
        var names = new ArrayList<String>();
        for (Object[] call : TextManager.calls) names.add((String)call[0]);
        return names;
    }

    private static List<Object[]> draws() {
        var draws = new ArrayList<Object[]>();
        for (Object[] call : TextManager.calls) if ("text".equals(call[0])) draws.add(call);
        return draws;
    }

    /** The last string drawn of these words (the text itself: its shadow and outline come before it), or null. */
    private static Object[] last(String words) {
        Object[] found = null;
        for (Object[] call : draws()) if (words.equals(call[5])) found = call;
        return found;
    }

    private static Object[] call(String name) {
        for (Object[] call : TextManager.calls) if (name.equals(call[0])) return call;
        return null;
    }

    private static double alpha(Object[] draw) { return (Double)draw[9]; }

    private static double zoom(Object[] draw) { return (Double)draw[4]; }

    private static Object[] quad(List<Object[]> quads, int index) { return quads.get(index); }

    private static void drawn(Object[] draw, UIFont font, double x, double y, double zoom, String words, double r, double g, double b, double a) {
        check(draw[1] == font && near((Double)draw[2], x) && near((Double)draw[3], y) && near((Double)draw[4], zoom) && words.equals(draw[5])
            && near((Double)draw[6], r) && near((Double)draw[7], g) && near((Double)draw[8], b) && near((Double)draw[9], a),
            "Drawn " + Arrays.toString(draw) + ", expected " + font + " at " + x + ", " + y + " zoom " + zoom + " " + words + " " + r + "," + g + "," + b + "," + a);
    }

    private static boolean near(double value, double expected) { return Math.abs(value - expected) < 1e-4; }

    private static KahluaTable table(Object... pairs) {
        var result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static KahluaTable list(Object... values) {
        var result = LuaManager.platform.newTable();
        for (int index = 0; index < values.length; index++) result.rawset((double)(index + 1), values[index]);
        return result;
    }

    private static List<Object> list(Object table) {
        var result = new ArrayList<Object>();
        var lua = (KahluaTable)table;
        for (int index = 1; lua.rawget((double)index) != null; index++) result.add(lua.rawget((double)index));
        return result;
    }

    private static void rejects(KahluaTable text, String message, String name, Object... arguments) {
        try { FormulasTest.call(text, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.text." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
