package zombie.world.moddata;

import java.util.HashMap;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;

/** Synthetic: the world's global ModData, which the world saves; {@code tables} is what a save would keep. */
public final class ModData {
    public static final HashMap<String, KahluaTable> tables = new HashMap<>();
    public static KahluaTable get(String tag) { return tables.get(tag); }
    public static KahluaTable getOrCreate(String tag) { return tables.computeIfAbsent(tag, unused -> LuaManager.platform.newTable()); }
}
