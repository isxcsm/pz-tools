package pztools.bridge.runtime.api;

import java.lang.reflect.*;

/**
 * The game's Lua runtime (Kahlua), reached by reflection from {@code LuaManager}: the payload is built without the
 * game. Used only on the game's thread, where the game itself uses these tables.
 */
final class Kahlua {
    /** A Lua function's body: arguments as Lua gives them (numbers are {@code Double}), results to return. */
    @FunctionalInterface interface Body { Object[] call(Object[] arguments) throws Exception; }

    private final Field env, platform;
    private final Class<?> tableType;
    private final Method newTable, rawset, rawget, setMetatable, getMetatable;
    private final Class<?> functionType;
    private final Method argument, push, pushNil;

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
    }

    /** The global table, or null before the game made one. */
    Object environment() throws ReflectiveOperationException { return env.get(null); }

    Object table() throws ReflectiveOperationException { return newTable.invoke(platform.get(null)); }

    boolean isTable(Object value) { return tableType.isInstance(value); }

    Object get(Object table, Object key) throws ReflectiveOperationException { return rawget.invoke(table, key); }

    void set(Object table, Object key, Object value) throws ReflectiveOperationException { rawset.invoke(table, key, value); }

    Object metatable(Object table) throws ReflectiveOperationException { return getMetatable.invoke(table); }

    void setMetatable(Object table, Object metatable) throws ReflectiveOperationException { setMetatable.invoke(table, metatable); }

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
