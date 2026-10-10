package pztools.api;

import java.lang.reflect.*;

/**
 * The game's Lua runtime (Kahlua), reached by reflection from {@code LuaManager}: the API is built without the
 * game. Used only on the game's thread, where the game itself uses these tables.
 */
final class Kahlua {
    /** A Lua function's body: arguments as Lua gives them (numbers are {@code Double}), results to return. */
    @FunctionalInterface interface Body { Object[] call(Object[] arguments) throws Exception; }

    private final Field env, platform, caller, thread;
    private final Class<?> tableType;
    private final Method newTable, rawset, rawget, setMetatable, getMetatable;
    private final Class<?> functionType;
    private final Method argument, push, pushNil;
    private final Method iterator, advance, key, value, pcall;
    // KahluaTable.rawget(int) as (Object, int)Object: the array part of a table, read without boxing the index.
    private final java.lang.invoke.MethodHandle rawgetAt, lengthOf;

    Kahlua(Class<?> luaManager) throws ReflectiveOperationException {
        ClassLoader loader = luaManager.getClassLoader();
        env = luaManager.getField("env");
        platform = luaManager.getField("platform");
        Class<?> table = tableType = Class.forName("se.krka.kahlua.vm.KahluaTable", false, loader);
        newTable = Class.forName("se.krka.kahlua.vm.Platform", false, loader).getMethod("newTable");
        rawset = table.getMethod("rawset", Object.class, Object.class);
        rawget = table.getMethod("rawget", Object.class);
        setMetatable = table.getMethod("setMetatable", table);
        getMetatable = table.getMethod("getMetatable");
        functionType = Class.forName("se.krka.kahlua.vm.JavaFunction", false, loader);
        Class<?> frame = Class.forName("se.krka.kahlua.vm.LuaCallFrame", false, loader);
        argument = frame.getMethod("get", int.class);
        push = frame.getMethod("push", Object.class);
        pushNil = frame.getMethod("pushNil");
        iterator = table.getMethod("iterator");
        Class<?> walker = Class.forName("se.krka.kahlua.vm.KahluaTableIterator", false, loader);
        advance = walker.getMethod("advance");
        key = walker.getMethod("getKey");
        value = walker.getMethod("getValue");
        caller = luaManager.getField("caller");
        thread = luaManager.getField("thread");
        pcall = Class.forName("se.krka.kahlua.integration.LuaCaller", false, loader).getMethod("pcall",
            Class.forName("se.krka.kahlua.vm.KahluaThread", false, loader), Object.class, Object[].class);
        rawgetAt = java.lang.invoke.MethodHandles.publicLookup().unreflect(table.getMethod("rawget", int.class))
            .asType(java.lang.invoke.MethodType.methodType(Object.class, Object.class, int.class));
        lengthOf = java.lang.invoke.MethodHandles.publicLookup().unreflect(table.getMethod("len"))
            .asType(java.lang.invoke.MethodType.methodType(int.class, Object.class));
    }

    /**
     * Calls a Lua function from Java, as the game calls the handlers of its events ({@code LuaManager.caller.pcall}): a fault in
     * it is caught by Lua, not thrown. The results are Lua's: the first is {@code true}, or {@code false} followed by the error.
     */
    Object[] call(Object function, Object... arguments) throws ReflectiveOperationException {
        return (Object[])pcall.invoke(caller.get(null), thread.get(null), function, arguments);
    }

    /** The value at {@code index} (1 up) of a table's array part, or null: without boxing the index. */
    Object at(Object table, int index) throws Throwable { return (Object)rawgetAt.invokeExact(table, index); }

    /** The length of a table's array part ({@code #table}). */
    int length(Object table) throws Throwable { return (int)lengthOf.invokeExact(table); }

    /** The global table, or null before the game made one. */
    Object environment() throws ReflectiveOperationException { return env.get(null); }

    Object table() throws ReflectiveOperationException { return newTable.invoke(platform.get(null)); }

    boolean isTable(Object value) { return tableType.isInstance(value); }

    Object get(Object table, Object key) throws ReflectiveOperationException { return rawget.invoke(table, key); }

    void set(Object table, Object key, Object value) throws ReflectiveOperationException { rawset.invoke(table, key, value); }

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
        for (int index = 0; index < values.size(); index++) set(result, (double)(index + 1), values.get(index));
        return result;
    }

    /** A Lua function. An exception from the body becomes a Lua error in the caller, with the body's message. */
    Object function(String name, Body body) {
        InvocationHandler handler = (proxy, method, arguments) -> switch (method.getName()) {
            case "call" -> call(body, arguments[0], (Integer)arguments[1]);
            case "toString" -> name;
            case "hashCode" -> System.identityHashCode(proxy);
            case "equals" -> proxy == arguments[0];
            default -> throw new UnsupportedOperationException(method.getName());
        };
        return Proxy.newProxyInstance(functionType.getClassLoader(), new Class<?>[] { functionType }, handler);
    }

    private int call(Body body, Object frame, int count) {
        try {
            Object[] arguments = new Object[count];
            for (int index = 0; index < count; index++) arguments[index] = argument.invoke(frame, index);
            Object[] results = body.call(arguments);
            for (Object result : results) {
                if (result == null) pushNil.invoke(frame);
                else push.invoke(frame, result);
            }
            return results.length;
        } catch (RuntimeException callerError) {
            throw callerError;
        } catch (InvocationTargetException failure) {
            throw new IllegalStateException("PZToolsAPI: the game failed: " + failure.getCause(), failure.getCause());
        } catch (Exception failure) {
            throw new IllegalStateException("PZToolsAPI: " + failure, failure);
        }
    }
}
