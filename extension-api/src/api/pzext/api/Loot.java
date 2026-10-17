package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.*;
import java.util.function.Supplier;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.loot}: kinds of loot a mod defines (docs/design.md, "Loot kinds"). The game sorts every item it rolls
 * into a kind ({@code ItemPickerJava.getLootType}, a fixed chain of tests) and multiplies its chance by that kind's modifier,
 * which a sandbox option of the game sets ({@code getLootModifierFromType}). A mod's kind is named
 * {@code <handle name>:<id>}, holds the items of the full types the mod lists, and takes its modifier from a sandbox option
 * the mod names, read as the game rolls: so the mod's items are rolled as the game's own are, by the mod's option. A kind
 * may require boolean options of the sandbox (the parts of the mod its items belong to switched on): read as the game rolls
 * too, the items are rolled at 0 while one is off.
 *
 * <p>The hooks are asked for every item rolled, on whatever thread fills the container: an item no mod listed costs one
 * map lookup, a kind of the game's own another; neither allocates. The definitions belong to the Lua environment (the mods
 * define them as their Lua loads); like the moodles they are kept in the API table's metatable for a newer API to take over.
 */
final class Loot implements Hooks.Loot {
    private static final String AREA = "PZExtAPI.loot.";
    private static final String MIRROR = "loot", FORMAT = "pzext-loot 1", GENERATION = "lootGeneration", HANDOVER = "lootHandover";
    // Between the names of a list in the kept text, and between the lists of a kind's requirements.
    private static final char SEPARATOR = '\u001f', GROUPS = '\u001e';
    static final int MAX_ITEMS = 1024, MAX_NAME = 128, MAX_REQUIRES = 16;

    /** One mod's kind of loot: its items, its option, and the boolean options it requires (of each list, one on). */
    private record Kind(String owner, String id, String option, List<String> items, List<List<String>> requires) {
        String name() { return owner + ":" + id; }
    }

    /** What the modifier hook reads of a kind: its option, and its requirements as arrays. */
    private record Rule(String option, String[][] requires) { }

    private final Kahlua lua;
    private final Object meta;
    private final Networks.Owners owners;
    // SandboxOptions.instance, its getOptionByName(name); the classes of the game's number and boolean options, their getValue().
    private final Object sandbox;
    private final MethodHandle optionByName, numberValue, booleanValue;
    private final Class<?> numberOption, booleanOption;
    // By name: every mod's kinds.
    private final TreeMap<String, Kind> kinds = new TreeMap<>();
    // What the hooks read, rebuilt as a kind changes: the kind of each full type a mod listed, the rule of each kind.
    private volatile Map<String, String> typeKinds = Map.of();
    private volatile Map<String, Rule> rules = Map.of();
    private long generation;

    Loot(Kahlua lua, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.meta = meta;
        this.owners = owners;
        Class<?> options = Game.type(loader, "zombie.SandboxOptions");
        sandbox = options.getField("instance").get(null);
        optionByName = Game.exact(options.getMethod("getOptionByName", String.class), MethodType.methodType(Object.class, Object.class, String.class));
        numberOption = Game.type(loader, "zombie.SandboxOptions$DoubleSandboxOption");
        numberValue = Game.exact(numberOption.getMethod("getValue"), MethodType.methodType(double.class, Object.class));
        booleanOption = Game.type(loader, "zombie.SandboxOptions$BooleanSandboxOption");
        booleanValue = Game.exact(booleanOption.getMethod("getValue"), MethodType.methodType(boolean.class, Object.class));
        // The API this one replaces writes its definitions where this one finds them.
        if (lua.get(meta, HANDOVER) instanceof Supplier<?> earlier) {
            try { earlier.get(); }
            catch (RuntimeException | LinkageError failure) {
                System.err.println("[PZExt] loot: the earlier API did not hand its kinds over: " + failure);
            }
        }
        load(lua.get(meta, MIRROR));
    }

    /** Gives the game's loot kind questions to these kinds. Throws a LinkageError in a game whose bootstrap has no loot hooks. */
    void hook() { Hooks.setLoot(this); }

    /** Gives every loot kind question back to the game alone. */
    static void unhook() {
        try { Hooks.setLoot(null); } catch (LinkageError olderBootstrap) { }
    }

    /** No kinds run in the environment any more: the functions mods kept refuse to be called; the definitions stay for a later API. */
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

    /** Refuses a call into kinds that a newer API took over, or that stopped: the mod kept the function. */
    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        lua.set(meta, HANDOVER, (Supplier<String>)this::handover);
        function(table, "define", (call, arguments) -> {
            String owner = owner(arguments, call);
            String id = Arguments.name(arguments, 1, call, "id");
            Object spec = arguments.length > 2 ? arguments[2] : null;
            if (!lua.isTable(spec))
                throw new IllegalArgumentException(call + ": spec must be a table, such as { option = \"MyMod.PartsLoot\", items = { \"MyMod.Part\" } }");
            String option = null;
            List<String> items = null;
            List<List<String>> requires = List.of();
            for (var entry : lua.entries(spec)) {
                if ("option".equals(entry.getKey())) option = option(entry.getValue(), call);
                else if ("items".equals(entry.getKey())) items = items(entry.getValue(), call);
                else if ("requires".equals(entry.getKey())) requires = requires(entry.getValue(), call);
                else throw new IllegalArgumentException(call + ": spec has no field " + entry.getKey() + "; it takes option, items and requires");
            }
            if (option == null) throw new IllegalArgumentException(call + ": spec.option must name a number option of the sandbox, such as MyMod.PartsLoot");
            if (items == null) throw new IllegalArgumentException(call + ": spec.items must be a list of the items' full types, such as { \"MyMod.Part\" }");
            var kind = new Kind(owner, id, option, items, requires);
            for (String item : items) {
                String other = typeKinds.get(item);
                if (other != null && !kinds.get(other).owner().equals(owner))
                    throw new IllegalArgumentException(call + ": " + item + " is in the mod " + kinds.get(other).owner() + "'s kind " + other);
            }
            // The mod's own item in another of its kinds moves to this one.
            for (var other : List.copyOf(kinds.values()))
                if (other.owner().equals(owner) && !other.id().equals(id) && !Collections.disjoint(other.items(), items)) {
                    var left = new ArrayList<>(other.items());
                    left.removeAll(items);
                    kinds.put(other.name(), new Kind(owner, other.id(), other.option(), List.copyOf(left), other.requires()));
                }
            kinds.put(kind.name(), kind);
            publish();
            return new Object[] { kind.name() };
        });
        function(table, "kindOf", (call, arguments) -> {
            String item = Arguments.string(arguments, 0, call, "fullType");
            return new Object[] { typeKinds.get(item) };
        });
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
        return owner;
    }

    private static boolean isText(Object value) {
        return value instanceof String text && !text.isEmpty() && text.length() <= MAX_NAME && text.chars().noneMatch(Character::isISOControl);
    }

    /**
     * Refuses a name the sandbox has no option of the class by (a mod's options are the game's from the mod's load, before its
     * Lua), saying what the spec's field wants.
     */
    private void sandboxOption(String name, Class<?> type, String field, String wanted, String call) throws ReflectiveOperationException {
        Object option;
        try { option = (Object)optionByName.invokeExact(sandbox, name); }
        catch (Throwable failure) { throw Game.thrown(failure); }
        if (option == null)
            throw new IllegalArgumentException(call + ": " + field + ": the sandbox has no option " + name + " (a mod's sandbox-options.txt names it Page.Name)");
        if (!type.isInstance(option)) throw new IllegalArgumentException(call + ": " + field + ": the sandbox option " + name + " is not " + wanted);
    }

    /** The name of a number option of the sandbox. */
    private String option(Object value, String call) throws ReflectiveOperationException {
        if (!isText(value)) throw new IllegalArgumentException(call + ": spec.option must name a number option of the sandbox, such as MyMod.PartsLoot");
        sandboxOption((String)value, numberOption, "spec.option", "a number option (type double), as the game's loot options are", call);
        return (String)value;
    }

    /**
     * The boolean options a kind requires: a list whose every entry is on, an entry being an option's name or a list of names one
     * of which is on, such as { "MyMod.EnableWater", { "MyMod.EnablePumps", "MyMod.EnableSprinklers" } }.
     */
    private List<List<String>> requires(Object value, String call) throws ReflectiveOperationException {
        String usage = call + ": spec.requires must be a list of up to " + MAX_REQUIRES + " boolean options of the sandbox, each a name or a list of"
            + " names one of which is on, such as { \"MyMod.EnableWater\", { \"MyMod.EnablePumps\", \"MyMod.EnableSprinklers\" } }";
        if (!lua.isTable(value)) throw new IllegalArgumentException(usage);
        var result = new ArrayList<List<String>>();
        for (int index = 1;; index++) {
            Object entry = lua.get(value, (double)index);
            if (entry == null) break;
            var group = new ArrayList<String>();
            if (isText(entry)) group.add((String)entry);
            else if (lua.isTable(entry))
                for (int inner = 1;; inner++) {
                    Object name = lua.get(entry, (double)inner);
                    if (name == null) break;
                    if (!isText(name) || group.size() >= MAX_REQUIRES) throw new IllegalArgumentException(usage);
                    group.add((String)name);
                }
            if (group.isEmpty() || result.size() >= MAX_REQUIRES) throw new IllegalArgumentException(usage);
            for (String name : group) sandboxOption(name, booleanOption, "spec.requires", "a boolean option", call);
            result.add(List.copyOf(group));
        }
        return List.copyOf(result);
    }

    /** A list of full types (Module.Name), checked for their form: items load with their scripts. */
    private List<String> items(Object value, String call) throws ReflectiveOperationException {
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": spec.items must be a list of the items' full types, such as { \"MyMod.Part\" }");
        var result = new LinkedHashSet<String>();
        for (int index = 1;; index++) {
            Object item = lua.get(value, (double)index);
            if (item == null) break;
            if (!isText(item) || ((String)item).indexOf('.') <= 0 || ((String)item).indexOf('.') == ((String)item).length() - 1)
                throw new IllegalArgumentException(call + ": spec.items[" + index + "] is not an item's full type (such as Base.PetrolCan)");
            result.add((String)item);
            if (result.size() > MAX_ITEMS) throw new IllegalArgumentException(call + ": spec.items has more than " + MAX_ITEMS + " items");
        }
        return List.copyOf(result);
    }

    /** {@code handle:clear()}: removes the mod's kinds; their items are the game's kinds again. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        if (kinds.values().removeIf(kind -> kind.owner().equals(owner))) publish();
    }

    /** Works the kinds out into the maps the hooks read, and keeps them for a newer API. */
    private void publish() throws ReflectiveOperationException {
        var types = new HashMap<String, String>();
        var next = new HashMap<String, Rule>();
        for (Kind kind : kinds.values()) {
            next.put(kind.name(), new Rule(kind.option(), kind.requires().stream().map(group -> group.toArray(String[]::new)).toArray(String[][]::new)));
            for (String item : kind.items()) types.put(item, kind.name());
        }
        typeKinds = Map.copyOf(types);
        rules = Map.copyOf(next);
        write();
    }

    // ---- kept for a newer API ----

    private void write() throws ReflectiveOperationException {
        var text = new StringBuilder(FORMAT);
        for (Kind kind : kinds.values()) {
            var requires = kind.requires().stream().map(group -> String.join(String.valueOf(SEPARATOR), group)).toList();
            text.append("\nK\t").append(kind.owner()).append('\t').append(kind.id()).append('\t').append(kind.option()).append('\t')
                .append(String.join(String.valueOf(SEPARATOR), kind.items())).append('\t').append(String.join(String.valueOf(GROUPS), requires));
        }
        lua.set(meta, MIRROR, text.toString());
    }

    private String handover() {
        try {
            write();
            return (String)lua.get(meta, MIRROR);
        } catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    /** The kinds an earlier API kept, if any. */
    private void load(Object kept) throws ReflectiveOperationException {
        if (!(kept instanceof String text)) return;
        String[] lines = text.split("\n");
        if (!FORMAT.equals(lines[0])) {
            System.err.println("[PZExt] loot: the kinds kept are in another format; the mods define them again");
            return;
        }
        for (int index = 1; index < lines.length; index++) {
            String[] fields = lines[index].split("\t", -1);
            if (fields.length != 6 || !"K".equals(fields[0])) throw new IllegalStateException("Unknown line in the kept loot kinds: " + lines[index]);
            var items = fields[4].isEmpty() ? List.<String>of() : List.of(fields[4].split(String.valueOf(SEPARATOR)));
            var requires = new ArrayList<List<String>>();
            if (!fields[5].isEmpty())
                for (String group : fields[5].split(String.valueOf(GROUPS))) requires.add(List.of(group.split(String.valueOf(SEPARATOR))));
            var kind = new Kind(fields[1], fields[2], fields[3], items, List.copyOf(requires));
            kinds.put(kind.name(), kind);
        }
        publish();
    }

    // ---- the hooks ----

    @Override public String type(String vanilla, String fullType) {
        if (fullType == null) return vanilla;
        String kind = typeKinds.get(fullType);
        return kind != null ? kind : vanilla;
    }

    @Override public float modifier(String type) {
        Rule rule = type == null ? null : rules.get(type);
        if (rule == null) return Float.NaN;
        try {
            // Read as the game rolls, so that the sandbox's values now count (the game's custom options are made again with its
            // mods). An option gone (its mod's options not loaded): the game's answer, its modifier of other loot.
            for (String[] group : rule.requires()) {
                boolean on = false;
                for (String name : group) {
                    Object option = (Object)optionByName.invokeExact(sandbox, name);
                    if (!booleanOption.isInstance(option)) return Float.NaN;
                    if ((boolean)booleanValue.invokeExact(option)) { on = true; break; }
                }
                if (!on) return 0f;
            }
            Object option = (Object)optionByName.invokeExact(sandbox, rule.option());
            return numberOption.isInstance(option) ? (float)(double)numberValue.invokeExact(option) : Float.NaN;
        } catch (Throwable failure) { throw Loot.<RuntimeException>sneaky(failure); }
    }

    @SuppressWarnings("unchecked")
    private static <T extends Throwable> T sneaky(Throwable failure) throws T { throw (T)failure; }
}
