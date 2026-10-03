package zombie.Lua;

import se.krka.kahlua.vm.*;

/**
 * Synthetic: the game thread is always inside one mod function called from one event handler, which the file's
 * top-level code called; like the game's, that code is named after the file's full path.
 */
public final class LuaManager {
    public static KahluaThread thread = new KahluaThread();
    static {
        Coroutine coroutine = new Coroutine();
        String file = "C:/Users/someone/Zomboid/mods/ExampleMod/media/lua/client/Example.lua";
        coroutine.frames[0] = frame(file, file, 1);
        coroutine.frames[1] = frame("OnTick", file, 10);
        coroutine.frames[2] = frame("heavyWork", file, 42);
        coroutine.top = 3;
        thread.currentCoroutine = coroutine;
    }
    private static LuaCallFrame frame(String name, String file, int line) {
        Prototype prototype = new Prototype();
        prototype.name = name; prototype.filename = file; prototype.file = "Example"; prototype.lines = new int[] { line, line };
        LuaClosure closure = new LuaClosure();
        closure.prototype = prototype;
        LuaCallFrame frame = new LuaCallFrame();
        frame.closure = closure; frame.pc = 1;
        return frame;
    }
}