package pzext.api;

import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import zombie.ai.states.AttackState;
import zombie.ai.states.LungeState;
import zombie.ai.states.WalkTowardState;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoZombie;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;

/**
 * {@code zombies.near} with options, against the synthetic game: the levels, who sees a zombie, who it hunts, its state and whether it
 * crawls narrow the zombies; a zombie says what the game says of it; a table the mod passes is filled again; a call without options
 * is the one it always was.
 */
final class ZombieQueriesTest {
    private ZombieQueriesTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        try {
            var cell = new IsoCell();
            IsoWorld.instance.setCell(cell);
            var player = new IsoPlayer();
            player.x = 10.5f; player.y = 10.5f;
            IsoPlayer.players[0] = player;
            GameApi.frame(ZombieQueriesTest.class.getClassLoader());
            var area = (KahluaTable)api.rawget("zombies");
            levels(area, cell);
            seen(area, cell, player);
            hunting(area, cell, player);
            states(area, cell);
            crawling(area, cell);
            reuse(area, cell, player);
            arguments(area, cell, player);
            cost(area, cell, player);
        } finally {
            IsoWorld.instance.setCell(home);
            IsoPlayer.players[0] = null;
        }
    }

    private static IsoZombie zombie(IsoCell cell, float x, float y, float z) {
        var zombie = new IsoZombie();
        zombie.x = x; zombie.y = y; zombie.z = z;
        cell.zombieList.add(zombie);
        return zombie;
    }

    private static KahluaTable options(Object... pairs) {
        var table = new KahluaTableImpl();
        for (int index = 0; index < pairs.length; index += 2) table.rawset(pairs[index], pairs[index + 1]);
        return table;
    }

    private static KahluaTable list(Object... values) {
        var table = new KahluaTableImpl();
        for (int index = 0; index < values.length; index++) table.rawset((double)(index + 1), values[index]);
        return table;
    }

    /** {@code near(10, 10, z, radius, limit, options)}: the count and the zombies of the list, nearest first. */
    private static List<Object> near(KahluaTable area, Object z, double radius, double limit, KahluaTable options) {
        return FormulasTest.call(area, "near", 10.0, 10.0, z, radius, limit, options);
    }

    private static KahluaTable entry(List<Object> result, int index) { return (KahluaTable)((KahluaTable)result.get(1)).rawget((double)index); }

    private static void levels(KahluaTable area, IsoCell cell) {
        cell.zombieList.clear();
        var ground = zombie(cell, 12f, 10f, 0f);
        var above = zombie(cell, 11f, 10f, 1f);
        var below = zombie(cell, 14f, 10f, -1f);
        zombie(cell, 13f, 10f, 2f);
        // The level of the call alone, as before; the options' levels in place of it (with no z at all).
        check((Double)near(area, 0.0, 20, 8, null).get(0) == 1.0, "A call without options did not keep to its level");
        var several = near(area, null, 20, 8, options("levels", list(0.0, 1.0, -1.0)));
        check((Double)several.get(0) == 3.0 && entry(several, 1).rawget("zombie") == above && entry(several, 2).rawget("zombie") == ground
            && entry(several, 3).rawget("zombie") == below, "Three levels gave " + several.get(0));
        check((Double)entry(several, 1).rawget("z") == 1.0 && (Double)entry(several, 3).rawget("z") == -1.0, "A zombie did not say its own level");
        // The call's z is not asked for when the options name levels, and is not looked at.
        check((Double)near(area, 0.0, 20, 8, options("levels", list(2.0))).get(0) == 1.0, "The options' levels did not replace the call's z");
        rejects(area, "z must be a whole number", 0.0, 0.0, null, 5.0, 8.0, options("hunting", true));
        rejects(area, "options.levels must be a list of whole numbers", 0.0, 0.0, 0.0, 5.0, 8.0, options("levels", 1.0));
        rejects(area, "options.levels must name at least one level", 0.0, 0.0, 0.0, 5.0, 8.0, options("levels", list()));
        rejects(area, "options.levels entry must be a whole number from -64 to 64", 0.0, 0.0, 0.0, 5.0, 8.0, options("levels", list(0.5)));
        Object[] many = new Object[17];
        java.util.Arrays.fill(many, 0.0);
        rejects(area, "at most 16 levels", 0.0, 0.0, 0.0, 5.0, 8.0, options("levels", list(many)));
        cell.zombieList.clear();
    }

    private static void seen(KahluaTable area, IsoCell cell, IsoPlayer player) {
        cell.zombieList.clear();
        var visible = zombie(cell, 12f, 10f, 0f);
        var hidden = zombie(cell, 14f, 10f, 0f);
        visible.isVisibleToPlayer[0] = true;
        hidden.isVisibleToPlayer[0] = false;
        // Each says whether the game shows it to the player; none was asked to be kept or left out.
        var both = near(area, 0.0, 20, 8, options("seenBy", player));
        check((Double)both.get(0) == 2.0 && entry(both, 1).rawget("seen") == Boolean.TRUE && entry(both, 2).rawget("seen") == Boolean.FALSE,
            "The zombies did not say whether they were seen");
        var only = near(area, 0.0, 20, 8, options("seenBy", player, "seen", true));
        check((Double)only.get(0) == 1.0 && entry(only, 1).rawget("zombie") == visible, "Only the seen zombie should have been kept");
        var others = near(area, 0.0, 20, 8, options("seenBy", player, "seen", false));
        check((Double)others.get(0) == 1.0 && entry(others, 1).rawget("zombie") == hidden, "Only the unseen zombie should have been kept");
        // Without seenBy there is nothing to say of who sees it.
        check(entry(near(area, 0.0, 20, 8, options("hunting", false)), 1).rawget("seen") == null, "A zombie said who sees it without being asked");
        rejects(area, "options.seen needs options.seenBy", 0.0, 0.0, 0.0, 5.0, 8.0, options("seen", true));
        rejects(area, "options.seenBy must be a player of this machine", 0.0, 0.0, 0.0, 5.0, 8.0, options("seenBy", new IsoPlayer()));
        rejects(area, "options.seen must be true or false", 0.0, 0.0, 0.0, 5.0, 8.0, options("seenBy", player, "seen", "yes"));
        cell.zombieList.clear();
    }

    private static void hunting(KahluaTable area, IsoCell cell, IsoPlayer player) {
        cell.zombieList.clear();
        var chasing = zombie(cell, 12f, 10f, 0f);
        var other = zombie(cell, 13f, 10f, 0f);
        var idle = zombie(cell, 14f, 10f, 0f);
        chasing.target = player;
        other.target = new IsoPlayer();
        var mine = near(area, 0.0, 20, 8, options("targeting", player));
        check((Double)mine.get(0) == 1.0 && entry(mine, 1).rawget("zombie") == chasing, "Only the zombie hunting the player should have been kept");
        var hunters = near(area, 0.0, 20, 8, options("hunting", true));
        check((Double)hunters.get(0) == 2.0, "Two zombies have a target, not " + hunters.get(0));
        var free = near(area, 0.0, 20, 8, options("hunting", false));
        check((Double)free.get(0) == 1.0 && entry(free, 1).rawget("zombie") == idle && entry(free, 1).rawget("hunting") == Boolean.FALSE,
            "Only the zombie with no target should have been kept");
        check(entry(hunters, 1).rawget("hunting") == Boolean.TRUE, "A hunting zombie did not say so");
        rejects(area, "options.targeting must be a character", 0.0, 0.0, 0.0, 5.0, 8.0, options("targeting", "player"));
        rejects(area, "options.hunting must be true or false", 0.0, 0.0, 0.0, 5.0, 8.0, options("hunting", 1.0));
        cell.zombieList.clear();
    }

    private static void states(KahluaTable area, IsoCell cell) {
        cell.zombieList.clear();
        var lunging = zombie(cell, 12f, 10f, 0f);
        var attacking = zombie(cell, 13f, 10f, 0f);
        var walking = zombie(cell, 14f, 10f, 0f);
        zombie(cell, 15f, 10f, 0f);
        lunging.setCurrentState(LungeState.instance());
        attacking.setCurrentState(AttackState.instance());
        walking.setCurrentState(WalkTowardState.instance());
        var lunge = near(area, 0.0, 20, 8, options("state", "LungeState"));
        check((Double)lunge.get(0) == 1.0 && entry(lunge, 1).rawget("zombie") == lunging && "LungeState".equals(entry(lunge, 1).rawget("state")),
            "The zombie in LungeState was not the one kept");
        // The ending is optional, and a list is any of them.
        check((Double)near(area, 0.0, 20, 8, options("state", "Lunge")).get(0) == 1.0, "A name without State was not understood");
        var either = near(area, 0.0, 20, 8, options("state", list("Lunge", "AttackState")));
        check((Double)either.get(0) == 2.0 && entry(either, 1).rawget("zombie") == lunging && entry(either, 2).rawget("zombie") == attacking,
            "A list of two states did not keep the two");
        // Each says its state's name, and nil for none.
        var all = near(area, 0.0, 20, 8, options("hunting", false));
        check("WalkTowardState".equals(entry(all, 3).rawget("state")) && entry(all, 4).rawget("state") == null, "The zombies did not say their states");
        rejects(area, "is not one of the game's zombie states", 0.0, 0.0, 0.0, 5.0, 8.0, options("state", "Sleeping"));
        rejects(area, "is not one of the game's zombie states", 0.0, 0.0, 0.0, 5.0, 8.0, options("state", "../Lunge"));
        rejects(area, "options.state must be a name or a list of names", 0.0, 0.0, 0.0, 5.0, 8.0, options("state", 1.0));
        rejects(area, "options.state must be a name or a list of names", 0.0, 0.0, 0.0, 5.0, 8.0, options("state", list(1.0)));
        rejects(area, "options.state must name at least one state", 0.0, 0.0, 0.0, 5.0, 8.0, options("state", list()));
        cell.zombieList.clear();
    }

    private static void crawling(KahluaTable area, IsoCell cell) {
        cell.zombieList.clear();
        var crawler = zombie(cell, 12f, 10f, 0f);
        zombie(cell, 13f, 10f, 0f);
        crawler.crawling = true;
        var found = near(area, 0.0, 20, 8, options("crawling", true));
        check((Double)found.get(0) == 1.0 && entry(found, 1).rawget("zombie") == crawler && entry(found, 1).rawget("crawling") == Boolean.TRUE, "The crawler was not kept");
        var walkers = near(area, 0.0, 20, 8, options("crawling", false));
        check((Double)walkers.get(0) == 1.0 && entry(walkers, 1).rawget("crawling") == Boolean.FALSE, "The walker was not kept");
        // Everything together: the filters and the levels narrow, they do not add.
        var narrow = near(area, null, 20, 8, options("levels", list(0.0), "crawling", true, "hunting", false));
        check((Double)narrow.get(0) == 1.0, "The filters together should keep one");
        check((Double)near(area, null, 20, 8, options("levels", list(1.0), "crawling", true)).get(0) == 0.0, "Another level should keep none");
        cell.zombieList.clear();
    }

    /** A table passed as {@code into} is the list: its entries are used again, and what a longer earlier call left is taken away. */
    private static void reuse(KahluaTable area, IsoCell cell, IsoPlayer player) {
        cell.zombieList.clear();
        for (int index = 0; index < 4; index++) zombie(cell, 12f + index, 10f, 0f);
        var into = new KahluaTableImpl();
        var first = near(area, 0.0, 20, 8, options("into", into));
        check(first.get(1) == into && ((KahluaTable)first.get(1)).len() == 4, "The list was not the table passed");
        Object entry = into.rawget(1.0), last = into.rawget(4.0);
        cell.zombieList.remove(3);
        cell.zombieList.remove(2);
        var second = near(area, 0.0, 20, 8, options("into", into));
        check(second.get(1) == into && into.len() == 2 && (Double)second.get(0) == 2.0, "The table was not trimmed: " + into.len());
        check(into.rawget(1.0) == entry && into.rawget(4.0) == null && last != null, "The entries were not used again");
        // No world: nothing, and the table emptied.
        IsoCell current = IsoWorld.instance.currentCell;
        IsoWorld.instance.setCell(null);
        var nowhere = near(area, 0.0, 20, 8, options("into", into));
        IsoWorld.instance.setCell(current);
        check((Double)nowhere.get(0) == 0.0 && into.len() == 0, "Without a world the table kept its zombies");
        cell.zombieList.clear();
    }

    private static void arguments(KahluaTable area, IsoCell cell, IsoPlayer player) {
        rejects(area, "options must be a table", 0.0, 0.0, 0.0, 5.0, 8.0, 1.0);
        rejects(area, "options.into must be a table", 0.0, 0.0, 0.0, 5.0, 8.0, options("into", 1.0));
        // A limit of 0 is only the count, with options too.
        cell.zombieList.clear();
        zombie(cell, 12f, 10f, 0f).crawling = true;
        var counted = near(area, 0.0, 20, 0, options("crawling", true));
        check((Double)counted.get(0) == 1.0 && ((KahluaTable)counted.get(1)).len() == 0, "A limit of 0 should be the count alone");
        cell.zombieList.clear();
    }

    /** The pass with options over 10000 zombies makes nothing for a zombie that is not wanted, and little for the call. */
    private static void cost(KahluaTable area, IsoCell cell, IsoPlayer player) {
        cell.zombieList.clear();
        var random = new java.util.Random(7);
        for (int index = 0; index < 10000; index++) {
            var zombie = zombie(cell, 10f + random.nextInt(2001) - 1000, 10f + random.nextInt(2001) - 1000, 0f);
            zombie.crawling = index % 7 == 0;
            zombie.isVisibleToPlayer[0] = index % 3 == 0;
            if (index % 5 == 0) zombie.setCurrentState(LungeState.instance());
        }
        var query = options("levels", list(-1.0, 0.0, 1.0), "seenBy", player, "seen", true, "crawling", false, "state", list("Lunge", "Attack"), "hunting", false);
        var into = new KahluaTableImpl();
        query.rawset("into", into);
        // The count alone (no entry is made): what the pass costs for the zombies, none of which is made anything of.
        for (int warm = 0; warm < 300; warm++) near(area, null, 1000, 0, query);
        long bytes = allocated();
        long start = System.nanoTime();
        for (int round = 0; round < 500; round++) near(area, null, 1000, 0, query);
        long time = System.nanoTime() - start;
        bytes = allocated() - bytes;
        for (int warm = 0; warm < 300; warm++) near(area, null, 1000, 8, query);
        long start8 = System.nanoTime();
        for (int round = 0; round < 500; round++) near(area, null, 1000, 8, query);
        long time8 = System.nanoTime() - start8;
        System.out.printf("zombies.near with options over 10000 zombies: %.1f us a call and %d bytes (the nearest 8: %.1f us)%n", time / 500 / 1e3, bytes / 500, time8 / 500 / 1e3);
        check(bytes / 500 < 2048, "A pass with options over 10000 zombies allocated " + bytes / 500 + " bytes a call");
        check(time / 500 < 6_000_000L && time8 / 500 < 6_000_000L, "zombies.near with options is slow: " + time / 500 + " ns");
        cell.zombieList.clear();
    }

    private static void rejects(Object table, String message, Object... arguments) {
        try { FormulasTest.call(table, "near", arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError("near accepted bad arguments: " + message);
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
