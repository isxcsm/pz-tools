package pztools.api;

import java.util.*;
import java.util.function.Supplier;
import pztools.bridge.ApiHooks;

/**
 * {@code PZToolsAPI.formulas}: the values mods declare for named hook points, which the hooks in the game's methods read
 * from plain fields (docs/design/extension-api.md, "Formulas"). A mod declares a value through its handle; the API
 * combines what every mod declared for a point by that point's rule and publishes the result as one immutable
 * snapshot, so a hook costs one volatile read and no allocation, and calls no Lua. Only the local player's character is
 * changed. Like the networks, the declarations are kept in the API table's metatable for a newer API to take over,
 * and are gone with the world they were made in.
 */
final class Formulas implements ApiHooks.Formulas {
    private static final String AREA = "PZToolsAPI.formulas.";
    // The key in the API's metatable, and the version of the text kept there.
    private static final String MIRROR = "formulas", FORMAT = "pztools-formulas 1";
    // In the API's metatable: which formulas run now, and what the next API calls to take them over.
    private static final String GENERATION = "formulasGeneration", HANDOVER = "formulasHandover";
    // Between the parts of a value in the kept text; a name a mod gives holds no control character.
    private static final char SEPARATOR = '\u001f';
    private static final int MAX_NAME = 128, MAX_ENTRIES = 256;
    private static final double MAX_MULTIPLIER = 100;

    /** What a point's value is, and how the values of several mods for it combine. */
    enum Shape {
        /** A number from 0 to 100; the values multiply. */
        MULTIPLIER,
        /** A number from 0 to 1, the part of a penalty taken away; what is left of the penalty multiplies. */
        REDUCTION,
        /** A number from -1000 to 1000; the values add. */
        NUMBER,
        /** A table of names and numbers from -0.9 to 100, a carrying efficiency each; the values of a name add. */
        EFFICIENCIES,
        /** A table of names and numbers from 0 to 100; the values of a name multiply. */
        MULTIPLIERS,
        /** A name, or a list of names; the lists join. */
        NAMES,
        /** A point whose hooks are not built yet: a number, a boolean, a string or a table is accepted and has no effect. */
        PLANNED
    }

    /** What the names in a table are: any text, or names the game registers. */
    enum Names { ANY, ITEM_TYPE, ITEM_TAG }

    /**
     * A hook point: its name, its value's shape, what its names are, the hooks (as {@code PZToolsAPI.hooks()} names them) it
     * needs, and whether it needs the game's inventory classes.
     */
    record Point(String name, Shape shape, Names names, List<String> hooks, boolean inventory) { }

    private static Point live(String name, Shape shape, String... hooks) { return new Point(name, shape, Names.ANY, List.of(hooks), false); }

    private static Point load(String name, Shape shape, Names names, String... hooks) { return new Point(name, shape, names, List.of(hooks), true); }

    private static Point planned(String name) { return new Point(name, Shape.PLANNED, Names.ANY, List.of(), false); }

    private static final String[] CARRIED = { "IsoGameCharacter.getInventoryWeight", "ItemContainer.hasRoomFor" },
        OVERLOAD = { "Moodle.Update:overload", "IsoPlayer.getPathSpeed:overload", "IsoGameCharacter.handleLandingImpact:overload" },
        LIFT = { "ItemContainer.getCapacity", "InventoryContainer.getCapacity", "InventoryContainer.getEffectiveCapacity" };

    static final List<Point> POINTS = List.of(
        live("body.discomfortMultiplier", Shape.MULTIPLIER, "IsoGameCharacter.getClothingDiscomfortModifier"),
        live("body.stiffnessMultiplier", Shape.MULTIPLIER, "IsoGameCharacter.addStiffness"),
        live("body.fatigueMultiplier", Shape.MULTIPLIER, "IsoGameCharacter.getFatiqueMultiplier"),
        live("body.enduranceDrainMultiplier", Shape.MULTIPLIER, "Stats.add"),
        live("body.poisonMultiplier", Shape.MULTIPLIER, "Stats.add"),
        load("carry.categoryEfficiency", Shape.EFFICIENCIES, Names.ANY, CARRIED),
        load("carry.itemEfficiency", Shape.EFFICIENCIES, Names.ITEM_TYPE, CARRIED),
        load("carry.containerTagMultiplier", Shape.MULTIPLIERS, Names.ITEM_TAG, CARRIED),
        live("capacity.maxWeightAdd", Shape.NUMBER, "IsoGameCharacter.getMaxWeight"),
        load("capacity.effectiveMultiplier", Shape.MULTIPLIER, Names.ANY, "ItemContainer.getEffectiveCapacity"),
        load("capacity.characterLimitAdd", Shape.NUMBER, Names.ANY, "ItemContainer.getEffectiveCapacity"),
        load("capacity.modDataKey", Shape.NAMES, Names.ANY, LIFT),
        load("overload.compress", Shape.REDUCTION, Names.ANY, OVERLOAD),
        live("move.runPenaltyReduction", Shape.REDUCTION, "IsoGameCharacter.calculateBaseSpeed"),
        live("move.combatPenaltyReduction", Shape.REDUCTION, "IsoGameCharacter.calculateCombatSpeed"),
        planned("move.walkMultiplier"), planned("move.treeSlowMultiplier"), planned("move.treeScratchChance"),
        planned("body.coldMultiplier"), planned("body.corpseCountMultiplier"), planned("body.corpseSicknessMultiplier"),
        planned("body.holeChance"), planned("infection.woundChance"), planned("infection.biteShield"),
        planned("fall.landingRemap"), planned("fall.impactMultiplier"), planned("loot.spawnMultiplier"),
        planned("loot.ammoMultiplier"), planned("vision.darknessRestore"), planned("vision.coneAdd"),
        planned("vision.hiddenZombieFix"));

    private static final Map<String, Point> BY_NAME = new LinkedHashMap<>();

    static { for (Point point : POINTS) BY_NAME.put(point.name(), point); }

    /**
     * What the hooks read: the declarations combined by each point's rule, worked out once when a declaration changes
     * and never changed after that, so that a hook reads it as it is. 1 (a multiplier) and 0 (an addition, a
     * reduction) leave the game's answer as it is.
     */
    static final class Active {
        private static final Object[] NO_OBJECTS = {};
        private static final float[] NO_FLOATS = {};
        private static final String[] NO_NAMES = {};
        double discomfort = 1, stiffness = 1, fatigue = 1, endurance = 1, poison = 1;
        // The load: whether any weight formula is declared; the efficiency of a display category; of item types and the tags
        // of bags, resolved to the game's own objects, with a number each.
        boolean carry;
        Map<String, Float> category = Map.of();
        Object[] typeObjects = NO_OBJECTS, tagObjects = NO_OBJECTS;
        float[] typeEfficiency = NO_FLOATS, tagMultiplier = NO_FLOATS;
        int maxWeightAdd, characterLimitAdd;
        double effectiveMultiplier = 1;
        String[] dataKeys = NO_NAMES;
        float compress, runReduction, combatReduction;
    }

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    private final Players players;
    // The game's inventory classes; null, with the reason, in a game whose inventory this API cannot read.
    private final Inventory inventory;
    private final String inventoryProblem;
    // The CharacterStat constants Stats.add is asked about.
    private final Object enduranceStat, poisonStat;
    // By mod, then point; what the mod declared: a Double, a Map of names to Doubles or a List of names.
    private final TreeMap<String, TreeMap<String, Object>> declared = new TreeMap<>();
    private volatile Active active = new Active();
    // The game's cell when the last frame ran: a world was left when it goes.
    private Object world;
    // Set when a declaration changed since the kept text was written; the next frame, or a newer API, writes it.
    private boolean dirty;
    // This environment's formulas as GENERATION numbers them; 0 until register.
    private long generation;

    Formulas(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        players = new Players(loader);
        Inventory reachable = null;
        String problem = null;
        try { reachable = new Inventory(loader); }
        catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) {
            problem = "the game's inventory could not be read: " + unreadable;
            System.err.println("[PzTools API] formulas: " + problem);
        }
        inventory = reachable;
        inventoryProblem = problem;
        Class<?> stat = Game.type(loader, "zombie.characters.CharacterStat");
        enduranceStat = stat.getField("ENDURANCE").get(null);
        poisonStat = stat.getField("POISON").get(null);
        // The API this one replaces writes its declarations where this one finds them.
        if (lua.get(meta, HANDOVER) instanceof Supplier<?> earlier) {
            try { earlier.get(); }
            catch (RuntimeException | LinkageError failure) {
                System.err.println("[PzTools API] formulas: the earlier API did not hand them over: " + failure);
            }
        }
        load(lua.get(meta, MIRROR));
        dirty = false;
        publish();
    }

    /** Gives the game's questions to these formulas. Throws a LinkageError in a game whose bootstrap has no formula hooks. */
    void hook() { ApiHooks.setFormulas(this); }

    /** Gives every formula question back to the game alone. */
    static void unhook() {
        try { ApiHooks.setFormulas(null); } catch (LinkageError olderBootstrap) { }
    }

    /**
     * No formulas run in the environment any more: an API could not take them over. The functions mods kept refuse to be
     * called, as they do after a takeover; the declarations stay for a later API.
     */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    // ---- the Lua surface ----

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Exception; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            current(call);
            return body.call(call, arguments);
        }));
    }

    /** Refuses a call into formulas that a newer API took over, or that stopped: the mod kept the function. */
    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZToolsAPI");
    }

    /**
     * Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be
     * called: a mod that kept one would declare to formulas that no longer run.
     */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        lua.set(meta, HANDOVER, (Supplier<String>)this::handover);
        function(table, "set", (call, arguments) -> {
            String owner = owner(arguments, call);
            Point point = point(arguments, 1, call);
            Object value = arguments.length > 2 ? arguments[2] : null;
            declare(owner, point, value == null ? null : parse(point, value, call));
            return new Object[0];
        });
        function(table, "get", (call, arguments) -> {
            Point point = point(arguments, 0, call);
            return new Object[] { toLua(point, combined(point)) };
        });
        function(table, "declared", (call, arguments) -> {
            String owner = owner(arguments, call);
            Point point = point(arguments, 1, call);
            var values = declared.get(owner);
            return new Object[] { toLua(point, values == null ? null : values.get(point.name())) };
        });
        function(table, "efficiency", (call, arguments) -> {
            Object item = item(arguments, call);
            try { return new Object[] { (double)inventory.factor(active, item) }; }
            catch (Throwable failure) { throw Game.failed(Game.thrown(failure)); }
        });
        function(table, "weight", (call, arguments) -> {
            Object item = item(arguments, call);
            try { return new Object[] { (double)inventory.unequipped(active, item) }; }
            catch (Throwable failure) { throw Game.failed(Game.thrown(failure)); }
        });
        function(table, "points", (call, arguments) -> {
            Object result = lua.table();
            Map<String, String> hooks = hooks();
            for (Point point : POINTS) lua.set(result, point.name(), status(point, hooks));
            return new Object[] { result };
        });
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZToolsAPI.client");
        return owner;
    }

    private Object item(Object[] arguments, String call) {
        if (inventory == null) throw new IllegalArgumentException(call + ": " + inventoryProblem);
        Object item = arguments.length > 0 ? arguments[0] : null;
        if (!inventory.isItem(item)) throw new IllegalArgumentException(call + ": item must be an inventory item");
        return item;
    }

    private static Point point(Object[] arguments, int index, String call) {
        String name = Arguments.string(arguments, index, call, "point");
        Point point = BY_NAME.get(name);
        if (point == null)
            throw new IllegalArgumentException(call + ": there is no point " + name + "; PZToolsAPI.formulas.points() lists them");
        return point;
    }

    /** The value a mod gave, checked and made plain: a Double, a Map of names to Doubles, a List of names; null for none (planned). */
    private Object parse(Point point, Object value, String call) throws ReflectiveOperationException {
        String name = point.name();
        switch (point.shape()) {
            case MULTIPLIER: return Arguments.number(new Object[] { value }, 0, call, name, 0, MAX_MULTIPLIER);
            case REDUCTION: return Arguments.number(new Object[] { value }, 0, call, name, 0, 1);
            case NUMBER: return Arguments.number(new Object[] { value }, 0, call, name, -1000, 1000);
            case EFFICIENCIES: return entries(point, value, call, -0.9, MAX_MULTIPLIER);
            case MULTIPLIERS: return entries(point, value, call, 0, MAX_MULTIPLIER);
            case NAMES: return names(point, value, call);
            default:
                if (!(value instanceof Number || value instanceof Boolean || value instanceof String || lua.isTable(value)))
                    throw new IllegalArgumentException(call + ": " + name + " must be a number, a boolean, a string or a table");
                return null;
        }
    }

    /** A table of names to numbers within the bounds, as a map in the table's order. */
    private Map<String, Double> entries(Point point, Object value, String call, double min, double max) throws ReflectiveOperationException {
        if (!lua.isTable(value))
            throw new IllegalArgumentException(call + ": " + point.name() + " must be a table of names to numbers from " + min + " to " + max);
        var result = new TreeMap<String, Double>();
        for (var entry : lua.entries(value)) {
            if (!(entry.getKey() instanceof String key) || !isText(key))
                throw new IllegalArgumentException(call + ": " + point.name() + " must be named by strings of 1 to " + MAX_NAME
                    + " characters without control characters");
            if (!(entry.getValue() instanceof Number number) || !(number.doubleValue() >= min && number.doubleValue() <= max))
                throw new IllegalArgumentException(call + ": " + point.name() + "[" + key + "] must be a number from " + min + " to " + max);
            if (point.names() != Names.ANY) {
                if (inventory == null) throw new IllegalArgumentException(call + ": " + point.name() + ": " + inventoryProblem);
                if ((point.names() == Names.ITEM_TYPE ? inventory.itemTypeNamed(key) : inventory.itemTagNamed(key)) == null)
                    throw new IllegalArgumentException(call + ": " + point.name() + "[" + key + "] is not an item "
                        + (point.names() == Names.ITEM_TYPE ? "type" : "tag") + " the game has (such as "
                        + (point.names() == Names.ITEM_TYPE ? "base:moveable" : "base:keyring") + ")");
            }
            result.put(key, number.doubleValue());
            if (result.size() > MAX_ENTRIES)
                throw new IllegalArgumentException(call + ": " + point.name() + " has more than " + MAX_ENTRIES + " entries");
        }
        return result;
    }

    /** A name or a list of names, as a list. */
    private List<String> names(Point point, Object value, String call) throws ReflectiveOperationException {
        var result = new ArrayList<String>();
        if (value instanceof String text) result.add(text);
        else if (lua.isTable(value)) {
            for (int index = 1;; index++) {
                Object item = lua.get(value, (double)index);
                if (item == null) break;
                if (!(item instanceof String text))
                    throw new IllegalArgumentException(call + ": " + point.name() + "[" + index + "] must be a string");
                result.add(text);
                if (result.size() > MAX_ENTRIES)
                    throw new IllegalArgumentException(call + ": " + point.name() + " has more than " + MAX_ENTRIES + " names");
            }
        } else throw new IllegalArgumentException(call + ": " + point.name() + " must be a string or a list of strings");
        for (String text : result)
            if (!isText(text)) throw new IllegalArgumentException(call + ": " + point.name() + " must be names of 1 to " + MAX_NAME
                + " characters without control characters");
        return List.copyOf(new LinkedHashSet<>(result));
    }

    private static boolean isText(String text) {
        return !text.isEmpty() && text.length() <= MAX_NAME && text.chars().noneMatch(Character::isISOControl);
    }

    /** A value as Lua sees it: a number, a table of names to numbers, a list of names; nil for none. */
    @SuppressWarnings("unchecked")
    private Object toLua(Point point, Object value) throws ReflectiveOperationException {
        if (value == null) return null;
        if (value instanceof Double number) return number;
        Object result = lua.table();
        if (value instanceof Map<?, ?> map) for (var entry : ((Map<String, Double>)map).entrySet()) lua.set(result, entry.getKey(), entry.getValue());
        else return lua.list((List<String>)value);
        return result;
    }

    // ---- what is declared ----

    /** A mod's declaration of a point; null takes it back. */
    private void declare(String owner, Point point, Object value) {
        if (point.shape() == Shape.PLANNED) return;
        var values = declared.computeIfAbsent(owner, key -> new TreeMap<>());
        Object before = value == null ? values.remove(point.name()) : values.put(point.name(), value);
        if (values.isEmpty()) declared.remove(owner);
        if (Objects.equals(before, value)) return;
        dirty = true;
        publish();
    }

    /** {@code handle:clear()}: removes everything the mod declared. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        if (declared.remove(owner) != null) { dirty = true; publish(); }
    }

    /** Each frame, on the game's thread. */
    void frame() {
        try {
            Object cell = game.cell();
            // The world the formulas were declared in was left; the mods declare them again in the next one.
            if (world != null && cell != world && !declared.isEmpty()) { declared.clear(); dirty = true; publish(); }
            world = cell;
            if (dirty) write();
        } catch (Throwable failure) {
            // Once: a fault that recurs each frame must not flood the game's log. The hooks keep answering.
            if (!reported) System.err.println("[PzTools API] formulas: " + failure);
            reported = true;
        }
    }

    private boolean reported;

    /** The value every mod's declarations of the point make together, or null when no mod declared it. */
    private Object combined(Point point) {
        switch (point.shape()) {
            case MULTIPLIER, REDUCTION, NUMBER -> {
                Double result = null;
                for (var values : declared.values()) {
                    if (!(values.get(point.name()) instanceof Double value)) continue;
                    result = result == null ? value : combine(point.shape(), result, value);
                }
                return result;
            }
            case EFFICIENCIES, MULTIPLIERS -> {
                var result = new TreeMap<String, Double>();
                for (var values : declared.values())
                    if (values.get(point.name()) instanceof Map<?, ?> map)
                        for (var entry : map.entrySet()) {
                            String key = (String)entry.getKey();
                            double value = (Double)entry.getValue();
                            result.merge(key, value, (first, second) -> point.shape() == Shape.EFFICIENCIES ? first + second : first * second);
                        }
                return result.isEmpty() ? null : result;
            }
            case NAMES -> {
                var result = new LinkedHashSet<String>();
                for (var values : declared.values()) if (values.get(point.name()) instanceof List<?> list) for (Object item : list) result.add((String)item);
                return result.isEmpty() ? null : List.copyOf(result);
            }
            default -> { return null; }
        }
    }

    /** Two values of one point: multipliers multiply, reductions leave what is left of the penalty multiplied, numbers add. */
    private static double combine(Shape shape, double first, double second) {
        return switch (shape) {
            case MULTIPLIER -> first * second;
            case REDUCTION -> 1 - (1 - first) * (1 - second);
            default -> first + second;
        };
    }

    private double number(String name, double none) {
        return combined(BY_NAME.get(name)) instanceof Double value ? value : none;
    }

    @SuppressWarnings("unchecked")
    private Map<String, Double> table(String name) {
        return combined(BY_NAME.get(name)) instanceof Map<?, ?> map ? (Map<String, Double>)map : Map.of();
    }

    /** Works the declarations out into the snapshot the hooks read. */
    private void publish() {
        var next = new Active();
        next.discomfort = number("body.discomfortMultiplier", 1);
        next.stiffness = number("body.stiffnessMultiplier", 1);
        next.fatigue = number("body.fatigueMultiplier", 1);
        next.endurance = number("body.enduranceDrainMultiplier", 1);
        next.poison = number("body.poisonMultiplier", 1);
        next.maxWeightAdd = (int)Math.round(number("capacity.maxWeightAdd", 0));
        next.effectiveMultiplier = number("capacity.effectiveMultiplier", 1);
        next.characterLimitAdd = (int)Math.round(number("capacity.characterLimitAdd", 0));
        next.compress = (float)number("overload.compress", 0);
        next.runReduction = (float)number("move.runPenaltyReduction", 0);
        next.combatReduction = (float)number("move.combatPenaltyReduction", 0);
        if (combined(BY_NAME.get("capacity.modDataKey")) instanceof List<?> keys) next.dataKeys = keys.toArray(String[]::new);
        if (inventory != null) {
            var category = new HashMap<String, Float>();
            for (var entry : table("carry.categoryEfficiency").entrySet()) category.put(entry.getKey(), entry.getValue().floatValue());
            next.category = category;
            var types = table("carry.itemEfficiency");
            var tags = table("carry.containerTagMultiplier");
            var typeObjects = new ArrayList<Object>(); var typeEfficiency = new ArrayList<Float>();
            for (var entry : types.entrySet()) {
                Object type = inventory.itemTypeNamed(entry.getKey());
                if (type != null) { typeObjects.add(type); typeEfficiency.add(entry.getValue().floatValue()); }
            }
            var tagObjects = new ArrayList<Object>(); var tagMultiplier = new ArrayList<Float>();
            for (var entry : tags.entrySet()) {
                Object tag = inventory.itemTagNamed(entry.getKey());
                if (tag != null) { tagObjects.add(tag); tagMultiplier.add(entry.getValue().floatValue()); }
            }
            next.typeObjects = typeObjects.toArray();
            next.typeEfficiency = floats(typeEfficiency);
            next.tagObjects = tagObjects.toArray();
            next.tagMultiplier = floats(tagMultiplier);
            next.carry = !category.isEmpty() || next.typeObjects.length > 0 || next.tagObjects.length > 0;
        }
        active = next;
    }

    private static float[] floats(List<Float> values) {
        float[] result = new float[values.size()];
        for (int index = 0; index < result.length; index++) result[index] = values.get(index);
        return result;
    }

    /** A point's state as {@code PZToolsAPI.hooks()} words it: applied when every hook it needs is, else what is wrong. */
    private String status(Point point, Map<String, String> hooks) {
        if (point.shape() == Shape.PLANNED) return "planned";
        if (point.inventory() && inventory == null) return "unavailable: " + inventoryProblem;
        int applied = 0;
        String first = null;
        for (String label : point.hooks()) {
            String state = hooks.getOrDefault(label, "no hook in this game; restart it to get this one");
            if (ApiHooks.APPLIED.equals(state)) { applied++; continue; }
            if (first == null) first = label + ": " + state;
        }
        if (first == null) return ApiHooks.APPLIED;
        if (applied > 0) return "partial: " + first;
        return first.substring(first.indexOf(": ") + 2);
    }

    private static Map<String, String> hooks() {
        try { return ApiHooks.hookStatus(); }
        catch (LinkageError olderBootstrap) { return Map.of(); }
    }

    // ---- kept for a newer API ----

    /** Keeps the declarations where a newer API finds them. */
    private void write() throws ReflectiveOperationException {
        var text = new StringBuilder(FORMAT).append('\n');
        for (var mod : declared.entrySet())
            for (var value : mod.getValue().entrySet()) {
                text.append("V\t").append(mod.getKey()).append('\t').append(value.getKey()).append('\t');
                switch (value.getValue()) {
                    case Double number -> text.append("n:").append(number);
                    case Map<?, ?> map -> {
                        text.append("t:");
                        boolean separate = false;
                        for (var entry : map.entrySet()) {
                            if (separate) text.append(SEPARATOR);
                            text.append(entry.getKey()).append(SEPARATOR).append(entry.getValue());
                            separate = true;
                        }
                    }
                    case List<?> list -> text.append("l:").append(String.join(String.valueOf(SEPARATOR), list.stream().map(String.class::cast).toList()));
                    default -> throw new IllegalStateException("Not a value: " + value.getValue());
                }
                text.append('\n');
            }
        lua.set(meta, MIRROR, text.toString());
        dirty = false;
    }

    /** Called by a newer API as it takes over (see {@link #HANDOVER}), on the game's thread: writes the declarations. */
    private String handover() {
        try {
            write();
            return (String)lua.get(meta, MIRROR);
        } catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    /** The declarations an earlier API kept, if any. */
    private void load(Object kept) {
        if (!(kept instanceof String text)) return;
        String[] lines = text.split("\n");
        if (!FORMAT.equals(lines[0])) {
            System.err.println("[PzTools API] formulas: the declarations kept are in another format; the mods declare them again");
            return;
        }
        for (int index = 1; index < lines.length; index++) {
            String[] fields = lines[index].split("\t", 4);
            if (!"V".equals(fields[0]) || fields.length < 4) throw new IllegalStateException("Unknown line in the kept formulas: " + lines[index]);
            Point point = BY_NAME.get(fields[2]);
            // A point this API no longer has: a newer or an older one's.
            if (point == null || point.shape() == Shape.PLANNED) continue;
            String payload = fields[3].substring(2);
            Object value;
            switch (fields[3].charAt(0)) {
                case 'n' -> value = Double.parseDouble(payload);
                case 't' -> {
                    var map = new TreeMap<String, Double>();
                    String[] parts = payload.split(String.valueOf(SEPARATOR), -1);
                    for (int part = 0; part + 1 < parts.length; part += 2) map.put(parts[part], Double.parseDouble(parts[part + 1]));
                    value = map;
                }
                case 'l' -> value = List.copyOf(Arrays.asList(payload.split(String.valueOf(SEPARATOR), -1)));
                default -> throw new IllegalStateException("Unknown value in the kept formulas: " + lines[index]);
            }
            declared.computeIfAbsent(fields[1], key -> new TreeMap<>()).put(point.name(), value);
        }
    }

    // ---- the hooks ----

    @Override public float discomfort(float vanilla, Object character) {
        double multiplier = active.discomfort;
        if (multiplier == 1 || !players.local(character)) return vanilla;
        return (float)(vanilla * multiplier);
    }

    @Override public float stiffness(float amount, Object character) {
        double multiplier = active.stiffness;
        // What the muscles recover is not what the strain adds.
        if (multiplier == 1 || amount <= 0 || !players.local(character)) return amount;
        return (float)(amount * multiplier);
    }

    @Override public double fatigue(double vanilla, Object character) {
        double multiplier = active.fatigue;
        if (multiplier == 1 || !players.local(character)) return vanilla;
        return vanilla * multiplier;
    }

    @Override public float carried(Object item, float vanilla, Object character, int kind) {
        Active now = active;
        if (!now.carry || !players.local(character)) return vanilla;
        try { return inventory.carried(now, item, vanilla, kind); }
        catch (Throwable failure) { throw Formulas.<RuntimeException>sneaky(failure); }
    }

    @Override public float incoming(Object item, float vanilla, Object container, boolean viaBag) {
        Active now = active;
        if (!now.carry) return vanilla;
        try { return inventory.incoming(now, item, vanilla, container, viaBag, players); }
        catch (Throwable failure) { throw Formulas.<RuntimeException>sneaky(failure); }
    }

    @Override public int maxWeight(int vanilla, Object character) {
        int add = active.maxWeightAdd;
        return add == 0 || !players.local(character) ? vanilla : vanilla + add;
    }

    @Override public int effectiveCapacity(int vanilla, Object container, Object character) {
        Active now = active;
        if (now.characterLimitAdd == 0 && now.effectiveMultiplier == 1) return vanilla;
        try { return inventory.effectiveCapacity(now, vanilla, container, character, players); }
        catch (Throwable failure) { throw Formulas.<RuntimeException>sneaky(failure); }
    }

    @Override public int capacity(int vanilla, Object container) {
        String[] keys = active.dataKeys;
        if (keys.length == 0) return vanilla;
        try {
            int lifted = inventory.lifted(keys, container);
            return lifted < 0 ? vanilla : lifted;
        } catch (Throwable failure) { throw Formulas.<RuntimeException>sneaky(failure); }
    }

    @Override public int bagCapacity(int vanilla, Object bag) {
        String[] keys = active.dataKeys;
        if (keys.length == 0) return vanilla;
        try {
            int lifted = inventory.bagCapacity(keys, bag);
            return lifted < 0 ? vanilla : lifted;
        } catch (Throwable failure) { throw Formulas.<RuntimeException>sneaky(failure); }
    }

    @Override public int bagEffectiveCapacity(int vanilla, Object bag, Object character) {
        String[] keys = active.dataKeys;
        if (keys.length == 0) return vanilla;
        try {
            int lifted = inventory.bagEffectiveCapacity(keys, bag, character);
            return lifted < 0 ? vanilla : lifted;
        } catch (Throwable failure) { throw Formulas.<RuntimeException>sneaky(failure); }
    }

    @Override public float overload(Object container, float weight) {
        Active now = active;
        if (now.compress == 0f) return weight;
        try { return inventory.compressed(now, container, weight, players); }
        catch (Throwable failure) { throw Formulas.<RuntimeException>sneaky(failure); }
    }

    @Override public float runPenalty(float vanilla, Object character) {
        float reduction = active.runReduction;
        // Only a penalty (below 1) is reduced.
        if (reduction == 0f || vanilla >= 1f || !players.local(character)) return vanilla;
        return 1f - (1f - vanilla) * (1f - reduction);
    }

    @Override public float combatPenalty(float vanilla, Object character) {
        float reduction = active.combatReduction;
        if (reduction == 0f || vanilla >= 1f || !players.local(character)) return vanilla;
        return 1f - (1f - vanilla) * (1f - reduction);
    }

    /**
     * Throws what a method handle of the game threw as it is, without declaring it: the hooks do not declare checked
     * exceptions, and the bootstrap that calls them reports a fault and answers as the game does. Nothing is wrapped, so
     * the hook allocates nothing for it either.
     */
    @SuppressWarnings("unchecked")
    private static <E extends Throwable> E sneaky(Throwable failure) throws E { throw (E)failure; }

    @Override public float statDelta(float delta, Object stats, Object stat) {
        Active now = active;
        try {
            // What drains endurance, or what poisons: a change in that direction, to the stats of a player here.
            if (delta < 0) {
                if (now.endurance == 1 || stat != enduranceStat || !players.ownsStats(stats)) return delta;
                return (float)(delta * now.endurance);
            }
            if (delta > 0) {
                if (now.poison == 1 || stat != poisonStat || !players.ownsStats(stats)) return delta;
                return (float)(delta * now.poison);
            }
        } catch (Throwable failure) { throw Formulas.<RuntimeException>sneaky(failure); }
        return delta;
    }
}
