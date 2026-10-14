package zombie.iso.objects;

import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoZombie;
import zombie.iso.IsoObject;

/** Synthetic: a corpse, whose container the trait multiplier of the game does not reach. */
public class IsoDeadBody extends IsoObject {
    public IsoDeadBody() { super(null); }

    /** Like the game's: the character's modData is copied, deep, and then it leaves the world. */
    public IsoDeadBody(IsoGameCharacter character) {
        super(null);
        if (character.hasModData()) modData = copy(character.getModData());
        if (character instanceof IsoZombie zombie) zombie.removeFromWorld();
    }

    private static KahluaTable copy(KahluaTable from) {
        KahluaTable to = LuaManager.platform.newTable();
        var walk = from.iterator();
        while (walk.advance()) to.rawset(walk.getKey(), walk.getValue() instanceof KahluaTable table ? copy(table) : walk.getValue());
        return to;
    }
}
