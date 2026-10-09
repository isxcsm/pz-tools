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

    /** Synthetic: where the game draws a point of the world (an isometric square 64 by 32, the origin at 500, 300, a floor 96 up). */
    public static final class GlobalObject {
        public static float isoToScreenX(int player, float x, float y, float z) { return 500f + (x - y) * 32f; }
        public static float isoToScreenY(int player, float x, float y, float z) { return 300f + (x + y) * 16f - z * 96f; }
    }
}
