package pztools.api;

import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.characters.IsoPlayer;
import zombie.core.textures.Texture;
import zombie.gameStates.GameLoadingState;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;
import zombie.scripting.objects.MoodleType;
import zombie.scripting.objects.Registries;
import zombie.scripting.objects.RegistryReset;
import zombie.scripting.objects.ResourceLocation;
import zombie.ui.MoodleTextureSet;
import zombie.ui.MoodlesUI;
import zombie.ui.UIManager;
import pztools.bridge.ApiHooks;

/**
 * The moodles a mod defines, against the synthetic game: the type registered once under the mod's name, added to the characters
 * and the moodle column made before it (so that every registered type can be asked of every character, as Moodle Framework asks
 * them), the level a mod sets shown through the game's own update and column (placed, tinted by kind, wiggled on a change), the
 * picture at the column's size, the levels by player, a world left, the registry reset, a newer API and a handler that fails.
 */
final class MoodlesTest {
    private static final ClassLoader GAME = MoodlesTest.class.getClassLoader();

    private MoodlesTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        try {
            var moodles = (KahluaTable)api.rawget("moodles");
            check(moodles != null, "The API has no moodles");
            // A player, its column, and a player of another machine, all made before any moodle is defined.
            var player = new IsoPlayer();
            IsoPlayer.players[0] = player;
            var remote = new IsoPlayer();
            var column = new MoodlesUI();
            column.setCharacter(player);
            UIManager.MoodleUI[0] = column;
            MoodlesUI.option = 0;
            GameApi.frame(GAME);
            int base = Registries.MOODLE_TYPE.values().size();
            Object mod = FormulasTest.call(api, "client", "moodle.mod").get(0);
            picture("media/ui/Sense_32.png", 32);
            Texture big = picture("media/ui/Sense_128.png", 128);

            // Defined: registered under the mod's name, in the characters and the column made before.
            List<Object> defined = FormulasTest.call(moodles, "define", mod, "Sense", table("kind", "good", "picture", "media/ui/Sense_{size}.png"));
            var sense = (MoodleType)defined.get(0);
            check("moodle.mod:Sense".equals(defined.get(1)), "The translation name is " + defined.get(1));
            check("moodle.mod:sense".equals(sense.toString()) && MoodleType.get(ResourceLocation.of("moodle.mod:sense")) == sense,
                "The type is not registered under the mod's name: " + sense);
            check(Registries.MOODLE_TYPE.values().size() == base + 1, "The registry has " + Registries.MOODLE_TYPE.values().size() + " types");
            for (MoodleType type : Registries.MOODLE_TYPE.values()) {
                player.getMoodles().getMoodleLevel(type);
                remote.getMoodles().getMoodleLevel(type);
            }
            check(column.data(sense) != null, "The column made before the moodle has no slot for it");
            player.getMoodles().Update();
            column.update();
            column.render();
            check(drawn(column, sense) == null, "A moodle at level 0 was drawn");

            // A level: shown through the game's update, placed and wiggled in the column, good, with its picture.
            FormulasTest.call(moodles, "set", mod, "Sense", 3.0);
            player.getMoodles().Update();
            remote.getMoodles().Update();
            check(player.getMoodles().getMoodleLevel(sense) == 3 && remote.getMoodles().getMoodleLevel(sense) == 0,
                "The level is not the local player's alone");
            check(player.getMoodles().getMoodleDisplayString(sense).equals("Moodles_moodle.mod:Sense_lvl3"), player.getMoodles().getMoodleDisplayString(sense));
            column.update();
            var slot = column.data(sense);
            check(slot.level == 3 && slot.oscillationLevel == 1f && slot.goodBadNeutral == 1 && slot.slotsPos != MoodlesUI.OFFSCREEN,
                "The column did not place the moodle as a good one that changed");
            check(player.getMoodles().getGoodBadNeutral(MoodleType.HUNGRY) == 2 && player.getMoodles().getGoodBadNeutral(MoodleType.FOOD_EATEN) == 1,
                "The game's own moodles changed kind");
            column.render();
            check(drawn(column, sense)[1] == Texture.FILES.get("media/ui/Sense_32.png"), "The picture of the size was not drawn");
            // The column's size changes with the player's option: the size's file, or the largest scaled to it.
            MoodlesUI.option = 2;
            column.render();
            Object[] at64 = drawn(column, sense);
            check(((Texture)at64[1]).source == big && (int)at64[2] == 64 && (int)at64[3] == 64, "The largest picture was not scaled to 64");
            int loads = Texture.loads;
            column.render();
            check(drawn(column, sense)[1] == at64[1] && Texture.loads == loads, "The picture was not kept");
            MoodlesUI.option = 5;
            column.render();
            check(drawn(column, sense)[1] == big, "The picture of 128 was not drawn");
            MoodlesUI.option = 0;
            // The same level again changes nothing; another level wiggles it.
            FormulasTest.call(moodles, "set", mod, "Sense", 3.0);
            player.getMoodles().Update();
            column.update();
            check(column.data(sense).oscillationLevel == 1f, "The column refreshed with nothing changed");
            FormulasTest.call(moodles, "set", mod, "Sense", 1.0);
            player.getMoodles().Update();
            column.update();
            check(slot.level == 1 && slot.oscillationLevel == 1f, "A new level did not wiggle the moodle");

            // By player: a second local player, made after the definition, has the type from the registry.
            var second = new IsoPlayer();
            IsoPlayer.players[1] = second;
            check(second.getMoodles().getMoodleLevel(sense) == 0, "A player made after the definition has no level");
            FormulasTest.call(moodles, "set", mod, "Sense", 2.0, 1.0);
            player.getMoodles().Update();
            second.getMoodles().Update();
            check(second.getMoodles().getMoodleLevel(sense) == 2 && player.getMoodles().getMoodleLevel(sense) == 1, "The level of one player changed another's");
            check((Double)FormulasTest.call(moodles, "level", mod, "Sense", 1.0).get(0) == 2.0
                && (Double)FormulasTest.call(moodles, "level", mod, "sense").get(0) == 1.0, "level() gave the wrong levels");
            var later = new MoodlesUI();
            check(later.data(sense) != null, "A column made after the definition has no slot for it");
            IsoPlayer.players[1] = null;
            // A dead player shows none, as the game's moodles.
            player.dead = true;
            player.getMoodles().Update();
            check(player.getMoodles().getMoodleLevel(sense) == 0, "A dead player showed the moodle");
            player.dead = false;
            player.getMoodles().Update();
            check(player.getMoodles().getMoodleLevel(sense) == 1, "The level did not come back");

            pictures(moodles, mod, player, column);
            defineAgain(api, moodles, mod, player, sense);
            rejects(api, moodles, mod);
            cost(player, sense, column);

            // A world left: the levels go; the definitions stay.
            FormulasTest.call(moodles, "set", mod, "Sense", 2.0);
            GameApi.frame(GAME);
            IsoWorld.instance.setCell(null);
            GameApi.frame(GAME);
            player.getMoodles().Update();
            check(player.getMoodles().getMoodleLevel(sense) == 0, "A level outlived the world");
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            FormulasTest.call(moodles, "set", mod, "Sense", 2.0);
            player.getMoodles().Update();
            check(player.getMoodles().getMoodleLevel(sense) == 2, "A definition did not outlive the world");

            // The game resets its registries as it leaves a world: the type is registered again and added to what was made.
            RegistryReset.resetAll();
            check(MoodleType.get(ResourceLocation.of("moodle.mod:sense")) == null, "The registry kept a mod's type");
            // Not while a world loads: its thread makes the player's moodles from the registry meanwhile.
            GameLoadingState.loader = new Thread(() -> { });
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            GameApi.frame(GAME);
            check(MoodleType.get(ResourceLocation.of("moodle.mod:sense")) == null, "The registry was changed while a world loaded");
            GameLoadingState.loader = null;
            GameApi.frame(GAME);
            var again = MoodleType.get(ResourceLocation.of("moodle.mod:sense"));
            check(again != null && again != sense, "The type was not registered again");
            for (MoodleType type : Registries.MOODLE_TYPE.values()) player.getMoodles().getMoodleLevel(type);
            check(column.data(again) != null, "The column has no slot for the type registered again");
            FormulasTest.call(moodles, "set", mod, "Sense", 4.0);
            player.getMoodles().Update();
            check(player.getMoodles().getMoodleLevel(again) == 4, "The type registered again shows no level");

            takeover(api, moodles, mod, player, again);
            failing(api, player, again, column);
            // Taken back while shown and the game paused (no update): the column still draws it, with its picture.
            column.update();
            FormulasTest.call(mod, "clear");
            column.render();
            check(drawn(column, again) != null && drawn(column, again)[1] == Texture.FILES.get("media/ui/Sense_32.png"),
                "A moodle taken back was not drawn by a column not updated since");
            rejects(moodles, "the mod has no moodle Sense", "set", mod, "Sense", 1.0);
            player.getMoodles().Update();
            check(player.getMoodles().getMoodleLevel(again) == 0, "A cleared moodle stayed");
            // Defined again in another case: the same type, and the id's case as first defined (the mod's text keys).
            List<Object> redefined = FormulasTest.call(moodles, "define", mod, "sense", table("kind", "good", "picture", "media/ui/Sense_{size}.png"));
            check(redefined.get(0) == again && "moodle.mod:Sense".equals(redefined.get(1)), "Defined again it was " + redefined);
            RegistryReset.resetAll();
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            var third = MoodleType.get(ResourceLocation.of("moodle.mod:sense"));
            check(third != null && "moodle.mod:Sense".equals(third.getTranslationName()), "Registered again, the id lost its case: " + third);
            FormulasTest.call(mod, "clear");
            // A type no one has a picture for (a newer API that kept nothing, another mod's) is the frame, not a failing column.
            var set = new MoodleTextureSet(64);
            check(ApiHooks.moodlePicture(set, MoodleType.register("native.mod:other"), null, column) == set.getBorder(),
                "A type no one has a picture for was not drawn as the frame");
        } finally {
            IsoWorld.instance.setCell(home);
            IsoPlayer.players[0] = null;
            IsoPlayer.players[1] = null;
            UIManager.MoodleUI[0] = null;
            MoodlesUI.option = 0;
            GameLoadingState.loader = null;
        }
    }

    /** One picture a level, a path without the size scaled, a picture the game has not read yet, and one that is not there. */
    private static void pictures(KahluaTable moodles, Object mod, IsoPlayer player, MoodlesUI column) throws Exception {
        Texture first = picture("media/ui/Calm1.png", 64), last = picture("media/ui/Calm2.png", 32);
        var calm = (MoodleType)FormulasTest.call(moodles, "define", mod, "Calm", table("kind", "neutral", "picture", table(1.0, "media/ui/Calm1.png",
            2.0, "media/ui/Calm2.png"))).get(0);
        FormulasTest.call(moodles, "set", mod, "Calm", 2.0);
        player.getMoodles().Update();
        column.update();
        check(column.data(calm).goodBadNeutral == 0, "A neutral moodle was not neutral");
        column.render();
        check(drawn(column, calm)[1] == last, "The second level's picture was not drawn");
        FormulasTest.call(moodles, "set", mod, "Calm", 4.0);
        player.getMoodles().Update();
        column.update();
        column.render();
        check(drawn(column, calm)[1] == last, "A level above the pictures given did not draw the last");
        FormulasTest.call(moodles, "set", mod, "Calm", 1.0);
        player.getMoodles().Update();
        column.update();
        column.render();
        Object[] scaled = drawn(column, calm);
        check(((Texture)scaled[1]).source == first && (int)scaled[2] == 32, "A picture of 64 was not drawn at 32");
        // Not read yet: drawn as it is, then scaled once its size is known.
        Texture late = picture("media/ui/Late.png", 64);
        late.ready = false;
        var slow = (MoodleType)FormulasTest.call(moodles, "define", mod, "Slow", table("kind", "bad", "picture", "media/ui/Late.png")).get(0);
        FormulasTest.call(moodles, "set", mod, "Slow", 1.0);
        player.getMoodles().Update();
        column.update();
        column.render();
        check(drawn(column, slow)[1] == late, "A picture not read yet was not drawn as it is");
        late.ready = true;
        column.render();
        check(((Texture)drawn(column, slow)[1]).source == late && (int)drawn(column, slow)[2] == 32, "A picture read since was not scaled");
        // Not there: the empty frame, and a line in the log once.
        var lost = (MoodleType)FormulasTest.call(moodles, "define", mod, "Lost", table("kind", "bad", "picture", "media/ui/Nothing_{size}.png")).get(0);
        FormulasTest.call(moodles, "set", mod, "Lost", 1.0);
        player.getMoodles().Update();
        column.update();
        column.render();
        Texture frame = (Texture)drawn(column, lost)[1];
        check(frame != null && frame.getName().endsWith("_Moodles_BGoutline.png"), "A moodle without a picture was not drawn as its frame");
        int loads = Texture.loads;
        column.render();
        check(Texture.loads == loads, "A picture that is not there was looked for again");
        // A file the game could not read never becomes ready: the frame, and not looked for again.
        picture("media/ui/Broken.png", 64).failed = true;
        var broken = (MoodleType)FormulasTest.call(moodles, "define", mod, "Broken", table("kind", "bad", "picture", "media/ui/Broken.png")).get(0);
        FormulasTest.call(moodles, "set", mod, "Broken", 1.0);
        player.getMoodles().Update();
        column.update();
        column.render();
        check(((Texture)drawn(column, broken)[1]).getName().endsWith("_Moodles_BGoutline.png"), "A picture the game could not read was not drawn as the frame");
        loads = Texture.loads;
        column.render();
        check(Texture.loads == loads, "A picture the game could not read was looked for again");
        // Not square: scaled by its long side and centred in the slot.
        Texture.FILES.put("media/ui/Wide.png", new Texture("media/ui/Wide.png", 64, 32));
        var wide = (MoodleType)FormulasTest.call(moodles, "define", mod, "Wide", table("kind", "bad", "picture", "media/ui/Wide.png")).get(0);
        FormulasTest.call(moodles, "set", mod, "Wide", 1.0);
        player.getMoodles().Update();
        column.update();
        column.render();
        Object[] centred = drawn(column, wide);
        check((int)centred[2] == 32 && (int)centred[3] == 16 && (float)centred[4] == 0f && (float)centred[5] == 8f,
            "A picture that is not square was not centred: " + centred[2] + "x" + centred[3] + " at " + centred[4] + "," + centred[5]);
        for (String id : new String[] { "Calm", "Slow", "Lost", "Broken", "Wide" }) FormulasTest.call(moodles, "set", mod, id, 0.0);
        player.getMoodles().Update();
        column.update();
    }

    /** Defined again: the same type (whatever the case of the id), with its new kind; another mod cannot take it. */
    private static void defineAgain(KahluaTable api, KahluaTable moodles, Object mod, IsoPlayer player, MoodleType sense) throws Exception {
        int size = Registries.MOODLE_TYPE.values().size();
        var again = FormulasTest.call(moodles, "define", mod, "sense", table("kind", "bad", "picture", "media/ui/Sense_{size}.png"));
        check(again.get(0) == sense && Registries.MOODLE_TYPE.values().size() == size, "Defined again, the moodle was registered again");
        check(player.getMoodles().getGoodBadNeutral(sense) == 2, "Defined again, the moodle kept its kind");
        FormulasTest.call(moodles, "define", mod, "Sense", table("kind", "good", "picture", "media/ui/Sense_{size}.png"));
        Object other = FormulasTest.call(api, "client", "Moodle.Mod").get(0);
        rejects(moodles, "is the mod moodle.mod's", "define", other, "sense", table("kind", "good", "picture", "a.png"));
        rejects(moodles, "the mod has no moodle Sense", "set", other, "Sense", 1.0);
    }

    private static void rejects(KahluaTable api, KahluaTable moodles, Object mod) throws Exception {
        rejects(moodles, "must be a handle", "define", "moodle.mod", "x", table("kind", "good", "picture", "a.png"));
        rejects(moodles, "id must be", "define", mod, "a b", table("kind", "good", "picture", "a.png"));
        rejects(moodles, "spec must be a table", "define", mod, "x", "a.png");
        rejects(moodles, "spec.kind must be", "define", mod, "x", table("kind", "great", "picture", "a.png"));
        rejects(moodles, "spec.kind must be", "define", mod, "x", table("picture", "a.png"));
        rejects(moodles, "spec.picture must be", "define", mod, "x", table("kind", "good"));
        rejects(moodles, "spec.picture must be", "define", mod, "x", table("kind", "good", "picture", table()));
        rejects(moodles, "spec.picture must be", "define", mod, "x", table("kind", "good", "picture", table(1.0, "a", 2.0, "b", 3.0, "c", 4.0, "d", 5.0, "e")));
        rejects(moodles, "spec.picture[2] must be", "define", mod, "x", table("kind", "good", "picture", table(1.0, "a", 2.0, 3.0)));
        rejects(moodles, "spec.picture must be paths", "define", mod, "x", table("kind", "good", "picture", "a\tb"));
        rejects(moodles, "spec has no field size", "define", mod, "x", table("kind", "good", "picture", "a.png", "size", 32.0));
        rejects(moodles, "level must be", "set", mod, "Sense", 5.0);
        rejects(moodles, "level must be", "set", mod, "Sense", 1.5);
        rejects(moodles, "playerIndex must be", "set", mod, "Sense", 1.0, 4.0);
        rejects(moodles, "the mod has no moodle Other", "set", mod, "Other", 1.0);
        rejects(moodles, "the mod has no moodle Other", "level", mod, "Other");
        int size = Registries.MOODLE_TYPE.values().size();
        // A handle named base would name the game's own moodles: refused before anything is looked up.
        Object base = FormulasTest.call(api, "client", "base").get(0);
        rejects(moodles, "a handle named base cannot define moodles", "define", base, "Endurance", table("kind", "good", "picture", "a.png"));
        rejects(moodles, "a handle named base cannot define moodles", "define", base, "x", table("kind", "good", "picture", "a.png"));
        var player = IsoPlayer.players[0];
        check(player.getMoodles().getGoodBadNeutral(MoodleType.ENDURANCE) == 2 && ApiHooks.moodleLevel(MoodleType.ENDURANCE, player) == -1,
            "A handle named base took a game's moodle over");
        // A type of a handle's name that another mod registered itself is not taken over.
        var native_ = MoodleType.register("native.mod:thing");
        Object nativeMod = FormulasTest.call(api, "client", "native.mod").get(0);
        rejects(moodles, "the game already has a moodle native.mod:thing that this API did not define", "define", nativeMod, "thing",
            table("kind", "good", "picture", "a.png"));
        check(ApiHooks.moodleLevel(native_, player) == -1 && player.getMoodles().getGoodBadNeutral(native_) == 2, "Another mod's type was taken over");
        check(Registries.MOODLE_TYPE.values().size() == size + 1, "A refused moodle was registered");
    }

    /**
     * The level hook runs once a tick for every moodle of every player: the game's types and the API's allocate nothing, and a
     * game's type still works its level out itself. The picture of a placed moodle allocates nothing once kept.
     */
    private static void cost(IsoPlayer player, MoodleType sense, MoodlesUI column) throws Exception {
        long bytes = 0, theirTime = 0, ourTime = 0, hiddenTime = 0;
        int sum = 0;
        MoodleType calm = MoodleType.get(ResourceLocation.of("moodle.mod:calm"));
        for (int round = 0; round < 3; round++) {
            sum = 0;
            long before = allocated(), start = System.nanoTime();
            for (int index = 0; index < 1_000_000; index++) sum += ApiHooks.moodleLevel(MoodleType.HUNGRY, player);
            long middle = System.nanoTime();
            for (int index = 0; index < 1_000_000; index++) sum += ApiHooks.moodleLevel(sense, player);
            long end = System.nanoTime();
            for (int index = 0; index < 1_000_000; index++) sum += ApiHooks.moodleLevel(calm, player);
            hiddenTime = System.nanoTime() - end;
            ourTime = end - middle;
            theirTime = middle - start;
            bytes = allocated() - before;
        }
        System.out.printf("moodles: the level hook: %.1f ns for a game's type, %.1f ns for an API type shown, %.1f ns for one at 0; %d bytes allocated by 3000000 calls%n",
            theirTime / 1e6, ourTime / 1e6, hiddenTime / 1e6, bytes);
        check(sum == 0 && bytes < 16384, "The level hook allocated " + bytes + " bytes, or answered wrong: " + sum);
        int worked = zombie.characters.Moodles.Moodle.worked;
        player.getMoodles().Update();
        int theirs = zombie.characters.Moodles.Moodle.worked - worked;
        check(theirs == 6, "The game worked out " + theirs + " moodles' levels itself; it has 6 types");
        var set = new MoodleTextureSet(32);
        Object picture = ApiHooks.moodlePicture(set, sense, null, column);
        for (int round = 0; round < 2; round++) {
            long before = allocated();
            for (int index = 0; index < 100000; index++) if (ApiHooks.moodlePicture(set, sense, null, column) != picture) throw new AssertionError("The picture changed");
            bytes = allocated() - before;
        }
        check(bytes < 16384, "The picture allocated " + bytes + " bytes in 100000 frames");
    }

    /** A newer API takes the definitions and levels over; a function a mod kept from before says the API was updated. */
    private static void takeover(KahluaTable api, KahluaTable moodles, Object mod, IsoPlayer player, MoodleType sense) throws Exception {
        FormulasTest.call(moodles, "set", mod, "Sense", 3.0);
        GameApi.frame(GAME);
        Object text = api.getMetatable().rawget("moodles");
        check(text instanceof String kept && kept.startsWith("pztools-moodles 1\n") && kept.contains("M\tmoodle.mod\tSense\tgood\t3,3,3,3\tmedia/ui/Sense_{size}.png"),
            "The moodles were not kept: " + text);
        Object set = moodles.rawget("set");
        // A level set since the last frame is taken over too.
        FormulasTest.call(moodles, "set", mod, "Sense", 2.0, 0.0);
        int size = Registries.MOODLE_TYPE.values().size();
        GameApi.register(LuaManager.class);
        check(api.rawget("moodles") == moodles && moodles.rawget("set") != set, "A newer API did not replace the functions in the same table");
        player.getMoodles().Update();
        check(player.getMoodles().getMoodleLevel(sense) == 2 && player.getMoodles().getGoodBadNeutral(sense) == 1, "A newer API lost a level or a kind");
        check(Registries.MOODLE_TYPE.values().size() == size, "A newer API registered the types again");
        try { FormulasTest.call(table("set", set), "set", mod, "Sense", 1.0); throw new AssertionError("A function kept from before the takeover ran"); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZToolsAPI.moodles.set: the API was updated"), expected.getMessage());
        }
        check(FormulasTest.call(moodles, "define", mod, "Sense", table("kind", "good", "picture", "media/ui/Sense_{size}.png")).get(0) == sense,
            "A newer API did not find the type in the registry");
    }

    /** A handler that fails gives the game's answers: the level the game works out (0 for a type it does not know), and the frame. */
    private static void failing(KahluaTable api, IsoPlayer player, MoodleType sense, MoodlesUI column) throws Exception {
        ApiHooks.setMoodles(new ApiHooks.Moodles() {
            @Override public int level(Object type, Object character) { throw new IllegalStateException("broken"); }
            @Override public int kind(int vanilla, Object type) { throw new IllegalStateException("broken"); }
            @Override public Object picture(Object set, Object type, Object ui) { throw new IllegalStateException("broken"); }
        });
        var set = new MoodleTextureSet(48);
        check(ApiHooks.moodlePicture(set, sense, null, column) == set.getBorder(), "A failing picture did not draw the frame");
        check(player.getMoodles().getGoodBadNeutral(sense) == 2, "A failing kind did not give the game's");
        player.getMoodles().Update();
        check(player.getMoodles().getMoodleLevel(sense) == 0, "A failing level did not give the game's");
        ApiHooks.setMoodles(null);
        check(ApiHooks.moodlePicture(set, sense, null, column) == set.getBorder(), "Without an API, a moodle with no picture was not its frame");
        // A newer API answers again, from what was kept.
        GameApi.register(LuaManager.class);
        player.getMoodles().Update();
        check(player.getMoodles().getMoodleLevel(sense) == 2, "The API did not answer again");
    }

    // ---- helpers ----

    private static Texture picture(String path, int size) {
        var texture = new Texture(path, size, size);
        Texture.FILES.put(path, texture);
        return texture;
    }

    /** What the column's last render drew for the type, or null. */
    private static Object[] drawn(MoodlesUI column, MoodleType type) {
        for (Object[] entry : column.drawn) if (entry[0] == type) return entry;
        return null;
    }

    private static KahluaTable table(Object... pairs) {
        var result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static void rejects(KahluaTable moodles, String message, String name, Object... arguments) {
        try { FormulasTest.call(moodles, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZToolsAPI.moodles." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
