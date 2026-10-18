package pzext.api;

import java.lang.classfile.ClassFile;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.*;

/**
 * The game's Lua runtime (Kahlua), reached by reflection from {@code LuaManager}: the API is built without the
 * game. Used only on the game's thread, where the game itself uses these tables.
 *
 * <p>What a call into Lua or out of it does is done through method handles that are constants of the compiled code
 * ({@link Calls}), called exactly: no argument arrays, no boxed counts, nothing looked up by name. A function Lua calls is an
 * instance of one small class made at run time that implements the game's {@code JavaFunction} and hands the call to its body
 * (not a {@link Proxy}, which looks the method up by name and boxes the call's count on every call).
 */
final class Kahlua {
    /** A Lua function's body: arguments as Lua gives them (numbers are {@code Double}), results to return. */
    @FunctionalInterface interface Body { Object[] call(Object[] arguments) throws Exception; }

    // The game's LuaManager the handles in Calls are made from: set before Calls is first used, the one game a process has.
    private static Class<?> seed;

    /**
     * The calls that make and read tables and that a function's arguments and results go through, as handles called
     * exactly, and the class of every Lua function. Constants, so that the compiler inlines the calls: made once from the
     * game's classes, which are the same for every Kahlua of one API.
     */
    private static final class Calls {
        static final Class<?> OWNER = seed;
        static final MethodHandle RAWGET_AT, RAWSET_AT, LENGTH, RAWSET, RAWGET, NEW_TABLE, PLATFORM, ARGUMENT, PUSH, PUSH_NIL, MAKE_FUNCTION;

        static {
            try {
                ClassLoader loader = OWNER.getClassLoader();
                Class<?> table = Class.forName("se.krka.kahlua.vm.KahluaTable", false, loader);
                Class<?> platform = Class.forName("se.krka.kahlua.vm.Platform", false, loader);
                Class<?> function = Class.forName("se.krka.kahlua.vm.JavaFunction", false, loader);
                Class<?> frame = Class.forName("se.krka.kahlua.vm.LuaCallFrame", false, loader);
                var lookup = MethodHandles.publicLookup();
                RAWGET_AT = lookup.unreflect(table.getMethod("rawget", int.class))
                    .asType(MethodType.methodType(Object.class, Object.class, int.class));
                RAWSET_AT = lookup.unreflect(table.getMethod("rawset", int.class, Object.class))
                    .asType(MethodType.methodType(void.class, Object.class, int.class, Object.class));
                LENGTH = lookup.unreflect(table.getMethod("len")).asType(MethodType.methodType(int.class, Object.class));
                RAWSET = lookup.unreflect(table.getMethod("rawset", Object.class, Object.class))
                    .asType(MethodType.methodType(void.class, Object.class, Object.class, Object.class));
                RAWGET = lookup.unreflect(table.getMethod("rawget", Object.class))
                    .asType(MethodType.methodType(Object.class, Object.class, Object.class));
                NEW_TABLE = lookup.unreflect(platform.getMethod("newTable")).asType(MethodType.methodType(Object.class, Object.class));
                PLATFORM = lookup.unreflectGetter(OWNER.getField("platform")).asType(MethodType.methodType(Object.class));
                ARGUMENT = lookup.unreflect(frame.getMethod("get", int.class))
                    .asType(MethodType.methodType(Object.class, Object.class, int.class));
                PUSH = lookup.unreflect(frame.getMethod("push", Object.class))
                    .asType(MethodType.methodType(int.class, Object.class, Object.class));
                PUSH_NIL = lookup.unreflect(frame.getMethod("pushNil")).asType(MethodType.methodType(int.class, Object.class));
                MAKE_FUNCTION = generator(function, frame);
            } catch (ReflectiveOperationException failure) {
                throw new ExceptionInInitializerError(failure);
            }
        }
    }

    private final Field env, caller, thread;
    private final Class<?> tableType;
    private final Method setMetatable, getMetatable;
    private final Method iterator, advance, key, value, pcall;

    Kahlua(Class<?> luaManager) throws ReflectiveOperationException {
        synchronized (Kahlua.class) { if (seed == null) seed = luaManager; }
        try {
            if (Calls.OWNER != luaManager) throw new ReflectiveOperationException("the game's Lua cannot be called: another game's Lua is already in use");
        } catch (ExceptionInInitializerError | NoClassDefFoundError unreadable) {
            throw new ReflectiveOperationException("the game's Lua cannot be called", unreadable.getCause() != null ? unreadable.getCause() : unreadable);
        }
        ClassLoader loader = luaManager.getClassLoader();
        env = luaManager.getField("env");
        Class<?> table = tableType = Class.forName("se.krka.kahlua.vm.KahluaTable", false, loader);
        setMetatable = table.getMethod("setMetatable", table);
        getMetatable = table.getMethod("getMetatable");
        iterator = table.getMethod("iterator");
        Class<?> walker = Class.forName("se.krka.kahlua.vm.KahluaTableIterator", false, loader);
        advance = walker.getMethod("advance");
        key = walker.getMethod("getKey");
        value = walker.getMethod("getValue");
        caller = luaManager.getField("caller");
        thread = luaManager.getField("thread");
        pcall = Class.forName("se.krka.kahlua.integration.LuaCaller", false, loader).getMethod("pcall",
            Class.forName("se.krka.kahlua.vm.KahluaThread", false, loader), Object.class, Object[].class);
    }

    /**
     * The class every Lua function is an instance of, made once for the game's {@code JavaFunction}: it holds the
     * {@link Target} it hands the call to, and says the function's name as its text, as a proxy of the interface did. A hidden
     * class of this package, so that nothing else can reach it; the handle makes an instance of it.
     */
    private static MethodHandle generator(Class<?> functionType, Class<?> frameType) throws ReflectiveOperationException {
        ClassDesc self = ClassDesc.of(Kahlua.class.getPackageName(), "KahluaFunction");
        ClassDesc target = Target.class.describeConstable().orElseThrow(), frame = frameType.describeConstable().orElseThrow();
        byte[] code = ClassFile.of().build(self, builder -> {
            builder.withFlags(ClassFile.ACC_FINAL | ClassFile.ACC_SUPER);
            builder.withInterfaceSymbols(functionType.describeConstable().orElseThrow());
            builder.withField("target", target, ClassFile.ACC_PRIVATE | ClassFile.ACC_FINAL);
            builder.withMethodBody(ConstantDescs.INIT_NAME, MethodTypeDesc.of(ConstantDescs.CD_void, target), ClassFile.ACC_PUBLIC,
                body -> body.aload(0).invokespecial(ConstantDescs.CD_Object, ConstantDescs.INIT_NAME, ConstantDescs.MTD_void)
                    .aload(0).aload(1).putfield(self, "target", target).return_());
            builder.withMethodBody("call", MethodTypeDesc.of(ConstantDescs.CD_int, frame, ConstantDescs.CD_int), ClassFile.ACC_PUBLIC,
                body -> body.aload(0).getfield(self, "target", target).aload(1).iload(2)
                    .invokevirtual(target, "call", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_Object, ConstantDescs.CD_int)).ireturn());
            builder.withMethodBody("toString", MethodTypeDesc.of(ConstantDescs.CD_String), ClassFile.ACC_PUBLIC,
                body -> body.aload(0).getfield(self, "target", target).getfield(target, "name", ConstantDescs.CD_String).areturn());
        });
        MethodHandles.Lookup hidden = MethodHandles.lookup().defineHiddenClass(code, true);
        return hidden.findConstructor(hidden.lookupClass(), MethodType.methodType(void.class, Target.class))
            .asType(MethodType.methodType(Object.class, Target.class));
    }

    /**
     * Calls a Lua function from Java, as the game calls the handlers of its events ({@code LuaManager.caller.pcall}): a fault in
     * it is caught by Lua, not thrown. The results are Lua's: the first is {@code true}, or {@code false} followed by the error.
     */
    Object[] call(Object function, Object... arguments) throws ReflectiveOperationException {
        return (Object[])pcall.invoke(caller.get(null), thread.get(null), function, arguments);
    }

    /** The value at {@code index} (1 up) of a table's array part, or null: without boxing the index. */
    Object at(Object table, int index) throws Throwable { return (Object)Calls.RAWGET_AT.invokeExact(table, index); }

    /** Sets the value at {@code index} of a table, without boxing the index (null takes the entry away). */
    void setAt(Object table, int index, Object value) throws ReflectiveOperationException {
        try { Calls.RAWSET_AT.invokeExact(table, index, value); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** As {@link #at}, for a caller that handles only reflective failures. */
    Object getAt(Object table, int index) throws ReflectiveOperationException {
        try { return (Object)Calls.RAWGET_AT.invokeExact(table, index); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** The length of a table's array part ({@code #table}). */
    int length(Object table) throws Throwable { return (int)Calls.LENGTH.invokeExact(table); }

    /** The global table, or null before the game made one. */
    Object environment() throws ReflectiveOperationException { return env.get(null); }

    Object table() throws ReflectiveOperationException {
        try { return (Object)Calls.NEW_TABLE.invokeExact((Object)Calls.PLATFORM.invokeExact()); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    boolean isTable(Object value) { return tableType.isInstance(value); }

    Object get(Object table, Object key) throws ReflectiveOperationException {
        try { return (Object)Calls.RAWGET.invokeExact(table, key); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    void set(Object table, Object key, Object value) throws ReflectiveOperationException {
        try { Calls.RAWSET.invokeExact(table, key, value); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    Object metatable(Object table) throws ReflectiveOperationException { return getMetatable.invoke(table); }

    void setMetatable(Object table, Object metatable) throws ReflectiveOperationException { setMetatable.invoke(table, metatable); }

    /** A table's entries (keys as Lua gives them: numbers are {@code Double}), in the table's own order. */
    java.util.List<java.util.Map.Entry<Object, Object>> entries(Object table) throws ReflectiveOperationException {
        var result = new java.util.ArrayList<java.util.Map.Entry<Object, Object>>();
        Object walk = iterator.invoke(table);
        while ((boolean)advance.invoke(walk)) result.add(java.util.Map.entry(key.invoke(walk), value.invoke(walk)));
        return result;
    }

    /** A Lua array (keys 1..n). */
    Object list(java.util.List<?> values) throws ReflectiveOperationException {
        Object result = table();
        for (int index = 0; index < values.size(); index++) setAt(result, index + 1, values.get(index));
        return result;
    }

    /** A Lua function. An exception from the body becomes a Lua error in the caller, with the body's message. */
    Object function(String name, Body body) {
        try { return (Object)Calls.MAKE_FUNCTION.invokeExact(new Target(name, body)); }
        catch (Throwable failure) { throw new IllegalStateException("PZExtAPI: " + failure, failure); }
    }

    /** What a Lua function does when called: reads its arguments, runs the body, pushes the results. */
    static final class Target {
        final String name;
        private final Body body;

        Target(String name, Body body) { this.name = name; this.body = body; }

        int call(Object frame, int count) {
            try {
                Object[] arguments = new Object[count];
                for (int index = 0; index < count; index++) arguments[index] = (Object)Calls.ARGUMENT.invokeExact(frame, index);
                Object[] results = body.call(arguments);
                for (Object result : results) {
                    int pushed = result == null ? (int)Calls.PUSH_NIL.invokeExact(frame) : (int)Calls.PUSH.invokeExact(frame, result);
                }
                return results.length;
            } catch (RuntimeException callerError) {
                throw callerError;
            } catch (InvocationTargetException failure) {
                throw new IllegalStateException("PZExtAPI: the game failed: " + failure.getCause(), failure.getCause());
            } catch (Exception failure) {
                throw new IllegalStateException("PZExtAPI: " + failure, failure);
            } catch (Error failure) {
                throw failure;
            } catch (Throwable failure) {
                throw new IllegalStateException("PZExtAPI: " + failure, failure);
            }
        }
    }
}
