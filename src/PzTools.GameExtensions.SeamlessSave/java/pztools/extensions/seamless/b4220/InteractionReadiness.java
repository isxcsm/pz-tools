package pztools.extensions.seamless.b4220;

import java.lang.invoke.*;
import java.lang.reflect.Field;

/** Read-only, game-thread probe. Never clears, recreates or completes a user's drag. */
final class InteractionReadiness {
    private final Field environment;
    private final Class<?> tableType;
    private final MethodHandle rawget;
    InteractionReadiness(ClassLoader loader) throws ReflectiveOperationException {
        Class<?> lua = Class.forName("zombie.Lua.LuaManager", false, loader);
        tableType = Class.forName("se.krka.kahlua.vm.KahluaTable", false, loader);
        environment = lua.getField("env");
        var lookup = MethodHandles.publicLookup();
        rawget = lookup.unreflect(tableType.getMethod("rawget", Object.class))
            .asType(MethodType.methodType(Object.class, Object.class, Object.class));

    }
    boolean ready() throws Exception {
        try {

            Object env = environment.get(null);
            if (!tableType.isInstance(env)) return false;
            Object drag = (Object)rawget.invokeExact(env, (Object)"ISMouseDrag");
            // Some game UIs do not load the inventory pane. There is then no inventory drag table.
            if (drag == null) return true;
            if (!tableType.isInstance(drag)) return false;
            return (Object)rawget.invokeExact(drag, (Object)"dragging") == null
                && (Object)rawget.invokeExact(drag, (Object)"draggingFocus") == null;
        } catch (Throwable failure) {
            if (failure instanceof Exception exception) throw exception;
            throw (Error)failure;
        }
    }
}
