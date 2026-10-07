package pztools.bridge;

import java.lang.classfile.*;
import java.lang.classfile.instruction.FieldInstruction;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.classfile.instruction.LineNumber;
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
    // One report per hook and handler: a fault in a call the game makes 40,000 times a second must not flood its log.
    private static final boolean[] reported = new boolean[7];

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
            }) },
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
                && invoke.name().equalsString("getSourceGrid"), FOOD) },
        "zombie/iso/IsoObject", new Site[] {
            // The water questions' reads of usesExternalWaterSource are hooked too; see plumbing.
            Site.atReturns("checkExternalFluidSource", "()Lzombie/iso/IsoObject;", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "waterSource", MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                    ConstantDescs.CD_Object));
                code.checkcast(owner);
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
                catch (Throwable problem) { report(name, problem); return null; }
            }
        };
        // Stays registered, so that the hooks survive another agent's retransformation (see AgentEntry.ensureGameHook).
        instrumentation.addTransformer(transformer, true);
        var loaded = new ArrayList<Class<?>>();
        for (Class<?> type : instrumentation.getAllLoadedClasses())
            if (SITES.containsKey(type.getName().replace('.', '/')) && instrumentation.isModifiableClass(type)) loaded.add(type);
        if (loaded.isEmpty()) return;
        try { instrumentation.retransformClasses(loaded.toArray(Class<?>[]::new)); }
        catch (Throwable problem) { report("retransform", problem); }
    }

    /** The hooked class, or null when the class has no hooks. Throws when the class is not shaped as expected. */
    static byte[] transform(String name, byte[] bytes, ClassLoader loader) {
        Site[] sites = SITES.get(name);
        if (sites == null) return null;
        var cf = AgentEntry.classFile(loader);
        var model = cf.parse(bytes);
        ClassDesc owner = model.thisClass().asSymbol();
        ClassTransform transform = ClassTransform.ACCEPT_ALL;
        for (Site site : sites) {
            var methods = model.methods().stream().filter(site::matches).toList();
            if (methods.size() != 1)
                throw new IllegalArgumentException("Expected exactly one " + name + "." + site.method() + site.type());
            // The hook reads the method's arguments at its end: the method must not reuse their slots.
            for (CodeElement element : methods.get(0).code().orElseThrow())
                if (element instanceof StoreInstruction store && store.slot() < site.argumentSlots())
                    throw new IllegalArgumentException(name + "." + site.method() + " reuses its argument slot " + store.slot());
            if (site.object() != null) {
                int found = 0;
                CodeElement previous = null;
                for (CodeElement element : methods.get(0).code().orElseThrow()) {
                    if (element instanceof LineNumber) continue;
                    if (previous != null && site.object().test(previous) && Site.haveElectricity(element)) found++;
                    previous = element;
                }
                if (found != 1)
                    throw new IllegalArgumentException("Expected one square power question in " + name + "." + site.method() + ", found " + found);
            }
            transform = transform.andThen(ClassTransform.transformingMethodBodies(site::matches, site.code(owner)));
        }
        if ("zombie/iso/IsoObject".equals(name)) transform = transform.andThen(plumbing(model, owner));
        if ("zombie/iso/IsoGridSquare".equals(name))
            for (String axis : new String[] { "x", "y", "z" })
                if (model.fields().stream().noneMatch(field -> field.fieldName().equalsString(axis)
                        && field.fieldType().equalsString("I") && !field.flags().has(AccessFlag.STATIC)))
                    throw new IllegalArgumentException("Expected the field IsoGridSquare." + axis);
        return cf.transformClass(model, transform);
    }

    /**
     * Where a hook goes in one method: before each return, with the return value on the stack; at its start; or after
     * the one place where the method asks a square about power for an object ({@code object} gets the square from the
     * object on the stack, and {@code IsoGridSquare.haveElectricity()} follows at once).
     */
    private record Site(String method, String type, boolean returns, int argumentSlots, BiConsumer<CodeBuilder, ClassDesc> emit,
            Predicate<CodeElement> object, int kind) {
        static Site atReturns(String method, String type, int argumentSlots, BiConsumer<CodeBuilder, ClassDesc> emit) {
            return new Site(method, type, true, argumentSlots, emit, null, 0);
        }

        static Site atStart(String method, String type, BiConsumer<CodeBuilder, ClassDesc> emit) {
            return new Site(method, type, false, 0, emit, null, 0);
        }

        static Site square(String method, String type, Predicate<CodeElement> object, int kind) {
            return new Site(method, type, false, 0, null, object, kind);
        }

        static boolean haveElectricity(CodeElement element) {
            return element instanceof InvokeInstruction invoke && invoke.owner().asInternalName().equals("zombie/iso/IsoGridSquare")
                && invoke.name().equalsString("haveElectricity") && invoke.type().equalsString("()Z");
        }

        boolean matches(MethodModel model) {
            return model.methodName().equalsString(method) && model.methodType().equalsString(type);
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
        synchronized (reported) { Arrays.fill(reported, 0, 5, false); }
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
        synchronized (reported) { reported[5] = false; reported[6] = false; }
        water = next;
    }

    /** Put after each read of {@code IsoObject.usesExternalWaterSource} in the object's water questions. */
    public static boolean waterPlumbed(boolean vanilla, Object fixture) {
        if (vanilla) return true;
        Water current = water;
        if (current == null) return false;
        try { return current.plumbed(false, fixture); }
        catch (Throwable problem) { reportOnce(5, "waterPlumbed", problem); return false; }
    }

    /** Put before each return of {@code IsoObject.checkExternalFluidSource()}. */
    public static Object waterSource(Object vanilla, Object fixture) {
        Water current = water;
        if (current == null) return vanilla;
        try { return current.source(vanilla, fixture); }
        catch (Throwable problem) { reportOnce(6, "waterSource", problem); return vanilla; }
    }

    /** Put before each return of {@code IsoGridSquare.haveElectricity()}. */
    public static boolean squarePowered(boolean vanilla, int x, int y, int z) {
        if (vanilla) return true;
        Power current = power;
        if (current == null) return false;
        try { return current.square(x, y, z); }
        catch (Throwable problem) { reportOnce(0, "square", problem); return false; }
    }

    /** Put before each return of the object questions; see {@link Power#object}. */
    public static boolean objectPowered(boolean vanilla, Object object, int kind, boolean generators) {
        Power current = power;
        if (current == null) return vanilla;
        try { return current.object(vanilla, object, kind, generators); }
        catch (Throwable problem) { reportOnce(1, "object", problem); return vanilla; }
    }

    /** Put at the start of {@code IsoGenerator.setSurroundingElectricity()}: true returns at once. */
    public static boolean generatorSurrounding(Object generator) {
        Power current = power;
        if (current == null) return false;
        try { return current.generator(generator); }
        catch (Throwable problem) { reportOnce(2, "generator", problem); return false; }
    }

    /** Put at the start of {@code IsoGenerator.updateGenerator(square)}. */
    public static void consumerChanged(Object square) {
        Power current = power;
        if (current == null) return;
        try { current.consumerChanged(square); }
        catch (Throwable problem) { reportOnce(3, "consumerChanged", problem); }
    }

    /** Put at the start of {@code IsoGenerator.update()}. */
    public static void generatorUpdate(Object generator) {
        Power current = power;
        if (current == null) return;
        try { current.generatorUpdate(generator); }
        catch (Throwable problem) { reportOnce(4, "generatorUpdate", problem); }
    }

    private static void reportOnce(int hook, String name, Throwable problem) {
        synchronized (reported) {
            if (reported[hook]) return;
            reported[hook] = true;
        }
        report(name, problem);
    }

    // To the game's console log; the game goes on as if the hook were not there.
    private static void report(String where, Throwable problem) { System.err.println("[PzTools API] " + where + ": " + problem); }
}
