package zombie.Lua;

import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.vm.KahluaTable;

/** Synthetic: like the game's, init() makes a new Lua environment, which mods then load into. */
public final class LuaManager {
    public static J2SEPlatform platform;
    public static KahluaTable env;
    public static void init() {
        platform = new J2SEPlatform();
        env = platform.newEnvironment();
    }
}
