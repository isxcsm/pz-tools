package pztools.bridge;

import java.lang.classfile.*;
import java.lang.classfile.instruction.FieldInstruction;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.classfile.instruction.LineNumber;
import java.lang.classfile.instruction.LoadInstruction;
import java.lang.classfile.instruction.ReturnInstruction;
import java.lang.classfile.instruction.StoreInstruction;
import java.lang.constant.*;
import java.lang.instrument.*;
import java.lang.reflect.AccessFlag;
import java.security.ProtectionDomain;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.function.BiConsumer;
import java.util.function.Predicate;

/**
 * The stable calls that the extension API's hooks put into game code (docs/design/extension-api.md). The payload that
 * runs the API sets the handlers, and a newer payload replaces them. Without a handler, and when a hook or a handler
 * fails, the game goes on as it would without the hook: the API never fails closed.
 */
public final class ApiHooks {
    /** Set by the payload. Called on the game's own thread. */
    public interface Handler {
        /** The game has made a new Lua environment ({@code LuaManager.init()}); mods load right after this. */
        void luaStarted(Class<?> luaManager) throws Exception;
    }

    /**
     * Set by the payload: the power networks. The square and object questions come on whatever thread the game asks
     * them on, tens of thousands of times a second; the generator calls on the game's thread.
     */
    public interface Power {
        /** Whether a network gives the square electricity. Asked only when the game says it has none. */
        boolean square(int x, int y, int z);

        /**
         * An object's power: an appliance ({@code ItemContainer.isObjectPowered}), a light switch's
         * ({@code IsoLightSwitch.hasElectricityAround}), a radio's or television's ({@code DeviceData.canBePoweredHere}),
         * the power a room's light gets from one of the room's switches (the switch's square, in
         * {@code LightingJNI.checkLights}), or the power that keeps food in a container cold (the container's square, in
         * {@code Food.updateAge}). {@code vanilla} is the game's answer, {@code generators} false when the game asks
         * about the grid alone.
         */
        boolean object(boolean vanilla, Object object, int kind, boolean generators);

        /** {@code IsoGenerator.setSurroundingElectricity()}: true when the API did it instead, for a generator in a network. */
        boolean generator(Object generator);

        /** {@code IsoGenerator.updateGenerator(square)}: something that uses power was switched, placed or taken there. */
        void consumerChanged(Object square);

        /** {@code IsoGenerator.update()}, before the game burns the hours since the generator last did. */
        default void generatorUpdate(Object generator) { }

        /**
         * {@code Food.updateAge}: the hours the food ages over since it last aged, chilled hours counted at the fridge
         * factor. {@code vanilla} is the game's, which counts every hour as the container has power now.
         */
        default double foodHours(double vanilla, Object food) { return vanilla; }
    }

    /** Set by the payload: the water networks. Asked on the thread that uses the fixture. */
    public interface Water {
        /**
         * Whether a fixture takes its water from another object ({@code IsoObject.usesExternalWaterSource}, as the game's
         * water questions read it): {@code vanilla}, or a water network supplies the fixture now.
         */
        boolean plumbed(boolean vanilla, Object fixture);

        /** The object the fixture takes its water from ({@code IsoObject.checkExternalFluidSource()}): {@code vanilla}, or the network's. */
        Object source(Object vanilla, Object fixture);

        /**
         * The sample a fixture's water comes through from its source container
         * ({@code IsoObject.createSampleAndPurifyWater}, which turns TaintedWater into Water): null for the game's, or
         * one in its place.
         */
        default Object sample(Object fixture, Object source, float amount) { return null; }

        /** Whether the fixture's water is tainted ({@code IsoObject.isTaintedWater()}): {@code vanilla}, or more. */
        default boolean tainted(boolean vanilla, Object fixture) { return vanilla; }
    }

    /** The kinds of {@link Power#object}. */
    public static final int APPLIANCE = 0, LIGHT_SWITCH = 1, DEVICE = 2, ROOM_LIGHT = 3, FOOD = 4;

    // The payload loads beside the game's start; the first Lua environment may be made before it is ready.
    private static final long HANDLER_WAIT_NANOS = TimeUnit.SECONDS.toNanos(10);
    private static final ClassDesc HOOKS = ClassDesc.of("pztools.bridge.ApiHooks");
    private static Handler handler;
    // A game the startup loader started, whose payload has not set the handler yet.
    private static boolean expected;
    private static volatile Power power;
    private static volatile Water water;
    // Where IsoObject reads usesExternalWaterSource for itself and keeps the game's flag: saving it, and finding the
    // game's own source (whose return the network's source replaces).
    private static final Set<String> PLUMBING_KEPT = Set.of("save", "checkExternalFluidSource");
    /** The handlers' calls, each reported once; a newer handler of its kind may report again. */
    private enum Call {
        SQUARE("square"), OBJECT("object"), GENERATOR("generator"), CONSUMER_CHANGED("consumerChanged"),
        GENERATOR_UPDATE("generatorUpdate"), FOOD_HOURS("foodHours"), WATER_PLUMBED("waterPlumbed", true),
        WATER_SOURCE("waterSource", true), WATER_SAMPLE("waterSample", true), WATER_TAINTED("waterTainted", true);

        final String label;
        final boolean water;

        Call(String label) { this(label, false); }
        Call(String label, boolean water) { this.label = label; this.water = water; }
    }

    // Guarded by itself. A fault in a call the game makes 40,000 times a second must not flood its log.
    private static final Set<Call> reported = EnumSet.noneOf(Call.class);
    private static final ClassDesc FLUID_CONTAINER = ClassDesc.of("zombie.entity.components.fluids.FluidContainer");
    // Whether IsoObject, as last transformed, has both hooks that keep a fixture's water tainted.
    private static volatile boolean purifyHooked;

    private ApiHooks() { }

    /** The game classes the hooks go into, and what goes in. */
    private static final Map<String, Site[]> SITES = Map.of(
        "zombie/Lua/LuaManager", new Site[] {
            Site.atReturns("init", "()V", 0, (code, owner) -> {
                code.ldc(owner);
                code.invokestatic(HOOKS, "luaStarted", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Class));
            }) },
        "zombie/iso/IsoGridSquare", new Site[] {
            Site.atReturns("haveElectricity", "()Z", 1, (code, owner) -> {
                for (String axis : new String[] { "x", "y", "z" }) { code.aload(0); code.getfield(owner, axis, ConstantDescs.CD_int); }
                code.invokestatic(HOOKS, "squarePowered", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean,
                    ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_int));
            }).reading("x", "y", "z") },
        "zombie/inventory/ItemContainer", new Site[] {
            Site.atReturns("isObjectPowered", "(Lzombie/iso/IsoObject;Z)Z", 2, (code, owner) -> {
                code.aload(0); code.iconst_0(); code.iload(1); objectPowered(code);
            }) },
        "zombie/iso/objects/IsoLightSwitch", new Site[] {
            Site.atReturns("hasElectricityAround", "()Z", 1, (code, owner) -> {
                code.aload(0); code.iconst_1(); code.iconst_1(); objectPowered(code);
            }) },
        "zombie/radio/devices/DeviceData", new Site[] {
            Site.atReturns("canBePoweredHere", "()Z", 1, (code, owner) -> {
                code.aload(0); code.iconst_2(); code.iconst_1(); objectPowered(code);
            }) },
        "zombie/iso/LightingJNI", new Site[] {
            // switch.square.haveElectricity(), for each switch of a room whose light is checked.
            Site.square("checkLights", "()V", element -> element instanceof FieldInstruction field
                && field.opcode() == Opcode.GETFIELD && field.owner().asInternalName().equals("zombie/iso/objects/IsoLightSwitch")
                && field.name().equalsString("square"), ROOM_LIGHT) },
        "zombie/inventory/types/Food", new Site[] {
            // container.getSourceGrid().haveElectricity(), for food in a fridge or freezer.
            Site.square("updateAge", "(Z)V", element -> element instanceof InvokeInstruction invoke
                && invoke.owner().asInternalName().equals("zombie/inventory/ItemContainer")
                && invoke.name().equalsString("getSourceGrid"), FOOD).named("power"),
            // age + hours * this.getFoodRotSpeed() / 24: the hours, then this, are on the stack.
            Site.before("updateAge", "(Z)V", (second, first, element) -> element instanceof InvokeInstruction invoke
                && invoke.name().equalsString("getFoodRotSpeed") && invoke.type().equalsString("()F")
                && first instanceof LoadInstruction self && self.slot() == 0 && self.typeKind() == TypeKind.REFERENCE
                && second instanceof LoadInstruction hours && hours.typeKind() == TypeKind.DOUBLE, (code, owner) -> {
                    code.pop();
                    code.aload(0);
                    code.invokestatic(HOOKS, "foodHours", MethodTypeDesc.of(ConstantDescs.CD_double, ConstantDescs.CD_double,
                        ConstantDescs.CD_Object));
                    code.aload(0);
                }).named("hours") },
        "zombie/iso/IsoObject", new Site[] {
            // The water questions' reads of usesExternalWaterSource are hooked too; see plumbing.
            Site.atReturns("checkExternalFluidSource", "()Lzombie/iso/IsoObject;", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "waterSource", MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                    ConstantDescs.CD_Object));
                code.checkcast(owner);
            }),
            // At the start: the method reassigns its amount. A sample from the API is returned in place of the game's.
            Site.atStart("createSampleAndPurifyWater",
                "(Lzombie/entity/components/fluids/FluidContainer;F)Lzombie/entity/components/fluids/FluidContainer;", (code, owner) -> {
                    Label vanilla = code.newLabel();
                    code.aload(0); code.aload(1); code.fload(2);
                    code.invokestatic(HOOKS, "waterSample", MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                        ConstantDescs.CD_Object, ConstantDescs.CD_float));
                    code.dup();
                    code.ifnull(vanilla);
                    code.checkcast(FLUID_CONTAINER);
                    code.areturn();
                    code.labelBinding(vanilla);
                    code.pop();
                }),
            Site.atReturns("isTaintedWater", "()Z", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "waterTainted", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean,
                    ConstantDescs.CD_Object));
            }) },
        "zombie/iso/objects/IsoGenerator", new Site[] {
            Site.atStart("setSurroundingElectricity", "()V", (code, owner) -> {
                Label vanilla = code.newLabel();
                code.aload(0);
                code.invokestatic(HOOKS, "generatorSurrounding", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_Object));
                code.ifeq(vanilla);
                code.return_();
                code.labelBinding(vanilla);
            }),
            Site.atStart("updateGenerator", "(Lzombie/iso/IsoGridSquare;)V", (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "consumerChanged", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object));
            }),
            Site.atStart("update", "()V", (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "generatorUpdate", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object));
            }) });

    private static void objectPowered(CodeBuilder code) {
        code.invokestatic(HOOKS, "objectPowered", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean,
            ConstantDescs.CD_Object, ConstantDescs.CD_int, ConstantDescs.CD_boolean));
    }

    /**
     * In a game the startup loader started, before the game loads its Lua and its world: the hooks go in as the classes
     * load. A class the game loaded already (the app's helper got in first) is transformed again.
     */
    static void install(Instrumentation instrumentation) {
        synchronized (ApiHooks.class) { expected = true; }
        ClassFileTransformer transformer = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (name == null || !SITES.containsKey(name)) return null;
                try { return ApiHooks.transform(name, bytes, loader); }
                catch (Throwable problem) { failed(name, String.valueOf(problem)); return null; }
            }
        };
        // Stays registered, so that the hooks survive another agent's retransformation (see AgentEntry.ensureGameHook).
        instrumentation.addTransformer(transformer, true);
        var loaded = new ArrayList<Class<?>>();
        for (Class<?> type : instrumentation.getAllLoadedClasses())
            if (SITES.containsKey(type.getName().replace('.', '/')) && instrumentation.isModifiableClass(type)) loaded.add(type);
        if (loaded.isEmpty()) return;
        try { instrumentation.retransformClasses(loaded.toArray(Class<?>[]::new)); }
        catch (Throwable problem) {
            for (Class<?> type : loaded) failed(type.getName().replace('.', '/'), "the loaded class could not be changed: " + problem);
        }
    }

    /** Every hook of the class, when the class could not be read or changed at all. */
    private static void failed(String name, String problem) {
        for (Site site : SITES.get(name)) record(site.label(name), problem);
        if ("zombie/iso/IsoObject".equals(name)) { record(PLUMBING, problem); purifyHooked = false; }
    }

    /**
     * The hooked class, or null when none of its hooks fits. Each hook is checked and put in on its own: a method another
     * mod has changed loses its own hook only, and {@link #hookStatus} says which and why.
     */
    static byte[] transform(String name, byte[] bytes, ClassLoader loader) {
        Site[] sites = SITES.get(name);
        if (sites == null) return null;
        var cf = GameHook.classFile(loader);
        var model = cf.parse(bytes);
        ClassDesc owner = model.thisClass().asSymbol();
        var parts = new LinkedHashMap<String, ClassTransform>();
        for (Site site : sites) {
            String problem = site.problem(name, model);
            if (problem == null) parts.put(site.label(name), ClassTransform.transformingMethodBodies(site::matches, site.code(owner)));
            else record(site.label(name), problem);
        }
        if ("zombie/iso/IsoObject".equals(name)) {
            try { parts.put(PLUMBING, plumbing(model, owner)); }
            catch (IllegalArgumentException unfit) { record(PLUMBING, unfit.getMessage()); }
        }
        // The class is built with every fitting hook at once; should that fail (new stack maps that cannot be made, say),
        // the hooks go in one at a time and only the ones the class takes stay.
        byte[] result = null;
        var kept = new LinkedHashMap<String, ClassTransform>();
        try {
            if (!parts.isEmpty()) result = cf.transformClass(model, combine(parts.values()));
            kept.putAll(parts);
        } catch (RuntimeException together) {
            for (var part : parts.entrySet()) {
                var trial = new ArrayList<>(kept.values());
                trial.add(part.getValue());
                try {
                    result = cf.transformClass(model, combine(trial));
                    kept.put(part.getKey(), part.getValue());
                } catch (RuntimeException alone) { record(part.getKey(), "its code could not be built: " + alone.getMessage()); }
            }
        }
        for (String label : kept.keySet()) record(label, APPLIED);
        // The class as it is now: a later transform (another agent's, say) may keep one of the two hooks, or neither.
        if ("zombie/iso/IsoObject".equals(name)) purifyHooked = kept.containsKey(PURIFY) && kept.containsKey(TAINTED);
        return kept.isEmpty() ? null : result;
    }

    private static ClassTransform combine(Collection<ClassTransform> parts) {
        ClassTransform transform = ClassTransform.ACCEPT_ALL;
        for (ClassTransform part : parts) transform = transform.andThen(part);
        return transform;
    }

    // ---- what went in ----

    /** A hook's state in {@link #hookStatus}; anything else is why it did not go in. */
    public static final String APPLIED = "applied", NOT_LOADED = "not-loaded";
    private static final String PLUMBING = "IsoObject.waterQuestions", PURIFY = "IsoObject.createSampleAndPurifyWater",
        TAINTED = "IsoObject.isTaintedWater";
    // Guarded by itself. By label: applied, or why not; a class that has not loaded yet is not in it.
    private static final Map<String, String> status = new HashMap<>();

    private static void record(String label, String state) {
        synchronized (status) { status.put(label, state); }
        if (!APPLIED.equals(state)) System.err.println("[PzTools API] no hook in " + label + ": " + state);
    }

    /**
     * Every hook the API puts into the game, by game class and method ({@code IsoGridSquare.haveElectricity}): applied,
     * not-loaded (its class has not loaded yet; most load with the first world), or why it did not go in. A question
     * whose hook is missing gets the game's own answer.
     */
    public static Map<String, String> hookStatus() {
        var all = new TreeMap<String, String>();
        for (var entry : SITES.entrySet())
            for (Site site : entry.getValue()) all.put(site.label(entry.getKey()), NOT_LOADED);
        all.put(PLUMBING, NOT_LOADED);
        synchronized (status) { all.putAll(status); }
        return all;
    }

    /** An instruction, with the two before it (line numbers skipped; null at the method's start). */
    @FunctionalInterface private interface Window { boolean test(CodeElement second, CodeElement first, CodeElement element); }

    /**
     * Where a hook goes in one method: before each return, with the return value on the stack; at its start; after
     * the one place where the method asks a square about power for an object ({@code object} gets the square from the
     * object on the stack, and {@code IsoGridSquare.haveElectricity()} follows at once); or before the one instruction
     * {@code at} names.
     */
    private record Site(String method, String type, boolean returns, int argumentSlots, BiConsumer<CodeBuilder, ClassDesc> emit,
            Predicate<CodeElement> object, int kind, Window at, String part, List<String> fields) {
        static Site atReturns(String method, String type, int argumentSlots, BiConsumer<CodeBuilder, ClassDesc> emit) {
            return new Site(method, type, true, argumentSlots, emit, null, 0, null, null, List.of());
        }

        static Site atStart(String method, String type, BiConsumer<CodeBuilder, ClassDesc> emit) {
            return new Site(method, type, false, 0, emit, null, 0, null, null, List.of());
        }

        static Site square(String method, String type, Predicate<CodeElement> object, int kind) {
            return new Site(method, type, false, 0, null, object, kind, null, null, List.of());
        }

        static Site before(String method, String type, Window at, BiConsumer<CodeBuilder, ClassDesc> emit) {
            return new Site(method, type, false, 0, emit, null, 0, at, null, List.of());
        }

        /** Told apart from another hook in the same method by {@code part}. */
        Site named(String part) { return new Site(method, type, returns, argumentSlots, emit, object, kind, at, part, fields); }

        /** The hook reads these instance int fields of the class. */
        Site reading(String... names) { return new Site(method, type, returns, argumentSlots, emit, object, kind, at, part, List.of(names)); }

        static boolean haveElectricity(CodeElement element) {
            return element instanceof InvokeInstruction invoke && invoke.owner().asInternalName().equals("zombie/iso/IsoGridSquare")
                && invoke.name().equalsString("haveElectricity") && invoke.type().equalsString("()Z");
        }

        boolean matches(MethodModel model) {
            return model.methodName().equalsString(method) && model.methodType().equalsString(type);
        }

        /** {@code IsoGridSquare.haveElectricity}, or {@code Food.updateAge:hours} for one of two hooks in a method. */
        String label(String className) {
            return className.substring(className.lastIndexOf('/') + 1) + "." + method + (part == null ? "" : ":" + part);
        }

        /** Why the hook does not fit the class as it is, or null. */
        String problem(String className, ClassModel model) {
            var methods = model.methods().stream().filter(this::matches).toList();
            if (methods.size() != 1) return "expected one " + method + type + ", found " + methods.size();
            var code = methods.get(0).code().orElse(null);
            if (code == null) return method + " has no code";
            // The hook reads the method's arguments at its end: the method must not reuse their slots.
            for (CodeElement element : code)
                if (element instanceof StoreInstruction store && store.slot() < argumentSlots)
                    return method + " reuses its argument slot " + store.slot();
            for (String name : fields)
                if (model.fields().stream().noneMatch(field -> field.fieldName().equalsString(name)
                        && field.fieldType().equalsString("I") && !field.flags().has(AccessFlag.STATIC)))
                    return "expected the field " + className.substring(className.lastIndexOf('/') + 1) + "." + name;
            if (object != null) {
                int found = 0;
                CodeElement previous = null;
                for (CodeElement element : code) {
                    if (element instanceof LineNumber) continue;
                    if (previous != null && object.test(previous) && haveElectricity(element)) found++;
                    previous = element;
                }
                if (found != 1) return "expected one square power question in " + method + ", found " + found;
            }
            if (at != null) {
                int found = 0;
                CodeElement second = null, first = null;
                for (CodeElement element : code) {
                    if (element instanceof LineNumber) continue;
                    if (at.test(second, first, element)) found++;
                    second = first;
                    first = element;
                }
                if (found != 1) return "expected one place for the hook in " + method + ", found " + found;
            }
            return null;
        }

        CodeTransform code(ClassDesc owner) {
            if (object != null) return CodeTransform.ofStateful(() -> new CodeTransform() {
                // The instruction that gets the square, held until the next one shows whether the square is asked.
                private CodeElement held;
                private final List<CodeElement> lines = new ArrayList<>();

                @Override public void accept(CodeBuilder builder, CodeElement element) {
                    if (held != null) {
                        if (element instanceof LineNumber) { lines.add(element); return; }
                        if (haveElectricity(element)) {
                            // object -> object, object -> object, square -> object, answer -> answer, object -> hook
                            builder.dup();
                            builder.with(held);
                            lines.forEach(builder::with);
                            builder.with(element);
                            builder.swap();
                            builder.loadConstant(kind);
                            builder.iconst_1();
                            objectPowered(builder);
                            held = null;
                            lines.clear();
                            return;
                        }
                        flush(builder);
                    }
                    if (object.test(element)) held = element;
                    else builder.with(element);
                }

                @Override public void atEnd(CodeBuilder builder) { if (held != null) flush(builder); }

                private void flush(CodeBuilder builder) {
                    builder.with(held);
                    lines.forEach(builder::with);
                    held = null;
                    lines.clear();
                }
            });
            if (at != null) return CodeTransform.ofStateful(() -> new CodeTransform() {
                private CodeElement second, first;

                @Override public void accept(CodeBuilder builder, CodeElement element) {
                    if (!(element instanceof LineNumber)) {
                        if (at.test(second, first, element)) emit.accept(builder, owner);
                        second = first;
                        first = element;
                    }
                    builder.with(element);
                }
            });
            if (returns) return (builder, element) -> {
                if (element instanceof ReturnInstruction) emit.accept(builder, owner);
                builder.with(element);
            };
            return CodeTransform.ofStateful(() -> new CodeTransform() {
                @Override public void atStart(CodeBuilder builder) { emit.accept(builder, owner); }
                @Override public void accept(CodeBuilder builder, CodeElement element) { builder.with(element); }
            });
        }
    }

    /** Sets the handler, replacing an earlier payload's; null when the payload cannot run the API. */
    public static void set(Handler next) {
        synchronized (ApiHooks.class) {
            handler = next;
            expected = false;
            ApiHooks.class.notifyAll();
        }
    }

    /**
     * Every read of {@code usesExternalWaterSource} in the object's water questions passes the flag and the object to
     * {@link #waterPlumbed}. Saving the object keeps the game's own flag.
     */
    private static ClassTransform plumbing(ClassModel model, ClassDesc owner) {
        Predicate<CodeElement> read = element -> element instanceof FieldInstruction field && field.opcode() == Opcode.GETFIELD
            && field.owner().asSymbol().equals(owner) && field.name().equalsString("usesExternalWaterSource");
        Predicate<MethodModel> asks = method -> !PLUMBING_KEPT.contains(method.methodName().stringValue());
        long reads = model.methods().stream().filter(asks).flatMap(method -> method.code().stream())
            .flatMap(code -> code.elementStream()).filter(read).count();
        if (reads == 0) throw new IllegalArgumentException("Expected the water questions to read IsoObject.usesExternalWaterSource");
        return ClassTransform.transformingMethodBodies(asks, (builder, element) -> {
            if (!read.test(element)) { builder.with(element); return; }
            // object -> object, object -> object, flag -> flag, object -> hook
            builder.dup();
            builder.with(element);
            builder.swap();
            builder.invokestatic(HOOKS, "waterPlumbed", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean,
                ConstantDescs.CD_Object));
        });
    }

    /** Sets the power networks, replacing an earlier payload's; null gives every power question to the game alone. */
    public static void setPower(Power next) {
        synchronized (reported) { reported.removeIf(call -> !call.water); }
        power = next;
    }

    /** Put at the end of {@code LuaManager.init()}. */
    public static void luaStarted(Class<?> luaManager) {
        Handler current;
        synchronized (ApiHooks.class) {
            long deadline = System.nanoTime() + HANDLER_WAIT_NANOS;
            try {
                for (long left; handler == null && expected && (left = deadline - System.nanoTime()) > 0;)
                    TimeUnit.NANOSECONDS.timedWait(ApiHooks.class, left);
            } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            // Waited once: should the payload never come, later environments do not wait again.
            expected = false;
            current = handler;
        }
        if (current == null) return;
        try { current.luaStarted(luaManager); }
        catch (Throwable problem) { report("luaStarted", problem); }
    }

    /** Sets the water networks, replacing an earlier payload's; null gives every water question to the game alone. */
    public static void setWater(Water next) {
        synchronized (reported) { reported.removeIf(call -> call.water); }
        water = next;
    }

    /** Put after each read of {@code IsoObject.usesExternalWaterSource} in the object's water questions. */
    public static boolean waterPlumbed(boolean vanilla, Object fixture) {
        if (vanilla) return true;
        Water current = water;
        if (current == null) return false;
        try { return current.plumbed(false, fixture); }
        catch (Throwable problem) { reportOnce(Call.WATER_PLUMBED, problem); return false; }
    }

    /** Put before each return of {@code IsoObject.checkExternalFluidSource()}. */
    public static Object waterSource(Object vanilla, Object fixture) {
        Water current = water;
        if (current == null) return vanilla;
        try { return current.source(vanilla, fixture); }
        catch (Throwable problem) { reportOnce(Call.WATER_SOURCE, problem); return vanilla; }
    }

    /** Put at the start of {@code IsoObject.createSampleAndPurifyWater(source, amount)}: a sample it gives is returned at once. */
    public static Object waterSample(Object fixture, Object source, float amount) {
        Water current = water;
        if (current == null) return null;
        try { return current.sample(fixture, source, amount); }
        catch (Throwable problem) { reportOnce(Call.WATER_SAMPLE, problem); return null; }
    }

    /** Put before each return of {@code IsoObject.isTaintedWater()}. */
    public static boolean waterTainted(boolean vanilla, Object fixture) {
        if (vanilla) return true;
        Water current = water;
        if (current == null) return false;
        try { return current.tainted(false, fixture); }
        catch (Throwable problem) { reportOnce(Call.WATER_TAINTED, problem); return false; }
    }

    /** Whether the game's purification of a fixture's water has its hooks: IsoObject loaded with them. */
    public static boolean waterPurifyHooked() { return purifyHooked; }

    /** Put before each return of {@code IsoGridSquare.haveElectricity()}. */
    public static boolean squarePowered(boolean vanilla, int x, int y, int z) {
        if (vanilla) return true;
        Power current = power;
        if (current == null) return false;
        try { return current.square(x, y, z); }
        catch (Throwable problem) { reportOnce(Call.SQUARE, problem); return false; }
    }

    /** Put before each return of the object questions; see {@link Power#object}. */
    public static boolean objectPowered(boolean vanilla, Object object, int kind, boolean generators) {
        Power current = power;
        if (current == null) return vanilla;
        try { return current.object(vanilla, object, kind, generators); }
        catch (Throwable problem) { reportOnce(Call.OBJECT, problem); return vanilla; }
    }

    /** Put at the start of {@code IsoGenerator.setSurroundingElectricity()}: true returns at once. */
    public static boolean generatorSurrounding(Object generator) {
        Power current = power;
        if (current == null) return false;
        try { return current.generator(generator); }
        catch (Throwable problem) { reportOnce(Call.GENERATOR, problem); return false; }
    }

    /** Put at the start of {@code IsoGenerator.updateGenerator(square)}. */
    public static void consumerChanged(Object square) {
        Power current = power;
        if (current == null) return;
        try { current.consumerChanged(square); }
        catch (Throwable problem) { reportOnce(Call.CONSUMER_CHANGED, problem); }
    }

    /** Put at the start of {@code IsoGenerator.update()}. */
    public static void generatorUpdate(Object generator) {
        Power current = power;
        if (current == null) return;
        try { current.generatorUpdate(generator); }
        catch (Throwable problem) { reportOnce(Call.GENERATOR_UPDATE, problem); }
    }

    /** Put before {@code Food.updateAge} reads the food's rot speed, with the hours it ages over on the stack. */
    public static double foodHours(double vanilla, Object food) {
        Power current = power;
        if (current == null) return vanilla;
        try { return current.foodHours(vanilla, food); }
        catch (Throwable problem) { reportOnce(Call.FOOD_HOURS, problem); return vanilla; }
    }

    private static void reportOnce(Call call, Throwable problem) {
        synchronized (reported) { if (!reported.add(call)) return; }
        report(call.label, problem);
    }

    // To the game's console log; the game goes on as if the hook were not there.
    private static void report(String where, Throwable problem) { System.err.println("[PzTools API] " + where + ": " + problem); }
}
