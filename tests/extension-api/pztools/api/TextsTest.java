package pztools.api;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;
import zombie.characters.IsoPlayer;
import zombie.iso.IsoCamera;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;
import zombie.ui.TextManager;
import zombie.ui.UIFont;
import zombie.ui.UIManager;
import pztools.bridge.ApiHooks;

/**
 * The text a mod shows, against the synthetic game: drawn by the game's own text drawing from the hook in the interface's drawing
 * (after the windows, before the tooltip), placed on each local player's part of the screen, zoomed, coloured, faded and moved by
 * its effects on the clock of the interface, the first font that has its characters, the distance-field shader around the fonts
 * made for it; titles in their styles, one after another on each screen; text typed with pauses, speed changes, colours and a
 * cursor, and fitted to a width on each screen; hidden, cleared, gone with the world, taken over by a
 * newer API; a drawing that fails leaves the interface drawn; and nothing is done, nor allocated, with nothing shown.
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
            check(ApiHooks.APPLIED.equals(FormulasTest.call(text, "status").get(0)), "The text hook is " + FormulasTest.call(text, "status").get(0));
            check(List.of("stamp", "discovery", "notice").equals(list(FormulasTest.call(text, "styles").get(0))), "The styles are wrong");
            useClock();
            Object mod = FormulasTest.call(api, "client", "text.mod").get(0), other = FormulasTest.call(api, "client", "other.mod").get(0);
            idle();
            shown(text, mod);
            timeline(text, mod, other);
            layout(text, mod);
            fonts(text, mod);
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
        double quest = (Double)FormulasTest.call(text, "title", mod, table("text", "Quest complete", "subtitle", "The well is clean")).get(0);
        double found = (Double)FormulasTest.call(text, "title", mod, table("text", "Search complete", "subtitle", "3 items", "style", "discovery")).get(0);
        render();
        check(draws().isEmpty(), "A stamp starts seen, or the second title did not wait");
        advance(0.22);
        render();
        Object[] title = last("Quest complete"), line = last("The well is clean");
        double zoom = 0.1 * 900 / 45, lineZoom = 0.045 * 900 / 45;
        drawn(title, UIFont.SdfBold, 800 - 14 * 20 * zoom / 2, 0.28 * 900 - 45 * zoom / 2, zoom, "Quest complete", 1, 1, 1, 1);
        check(line != null && line[1] == UIFont.SdfRegular && near(zoom(line), lineZoom)
            && near((Double)line[3], (0.28 + 0.1 / 2 + 0.1 * 0.25 + 0.045 / 2) * 900 - 45 * lineZoom / 2), "The line under the title is not under it");
        check(last("Search complete") == null, "The second title did not wait");
        // The stamp and its line go together, after 0.22 + 2.4 + 0.7 seconds.
        advance(3.0);
        render();
        check(last("Quest complete") != null && last("The well is clean") != null, "The stamp went early");
        advance(0.11);
        render();
        check(last("Quest complete") == null && last("The well is clean") == null && last("Search complete") == null, "The stamp outlived its time, or the next did not wait for it");
        check(!(Boolean)FormulasTest.call(text, "shown", mod, quest).get(0) && (Boolean)FormulasTest.call(text, "shown", mod, found).get(0), "shown is wrong");
        render();
        advance(0.6);
        render();
        Object[] search = last("Search complete");
        check(search != null && search[1] == UIFont.SdfRobertoSans && near((Double)search[6], 1) && near((Double)search[7], 0.8) && near((Double)search[8], 0.38),
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
            check(last("Second") != null && near((Double)last("Second")[3] - 450, 0.2 * 450 - 0.036 * 450 * 45 / 45 / 2), "The second title is not on its screen");
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
        rejects(text, "spec.enter must be one of \"none\", \"fade\", \"pop\", \"slam\", \"rise\", \"drop\", \"type\"", "show", mod, table("text", "x", "enter", "spin"));
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
        double key = (Double)FormulasTest.call(text, "title", mod, table("text", "Quest complete", "subtitle", "The well is clean", "hold", 100.0)).get(0);
        render();
        advance(1);
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
        var before = new StringBuilder("pztools-texts 1");
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
            check(expected.getMessage().startsWith("PZToolsAPI.text." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
