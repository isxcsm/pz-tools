package zombie.characters.BodyDamage;

import java.util.ArrayList;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoZombie;
import zombie.iso.CorpseCount;

/**
 * Synthetic: the parts of a body; a zombie's bite puts SetBitten(index, true) on one; the sickness from the corpses around
 * comes from the count of them.
 */
public class BodyDamage {
    private final IsoGameCharacter parentChar;
    private final ArrayList<BodyPart> bodyParts = new ArrayList<>();
    public BodyDamage(IsoGameCharacter parent) {
        this.parentChar = parent;
        for (int index = 0; index < BodyPartType.values().length; index++) bodyParts.add(new BodyPart(parent));
    }

    public IsoGameCharacter getParentChar() { return parentChar; }

    public ArrayList<BodyPart> getBodyParts() { return bodyParts; }

    public void SetBitten(int index, boolean bitten) { bodyParts.get(index).SetBitten(bitten); }

    public boolean AddRandomDamageFromZombie(IsoZombie zombie, String hitReaction, int index) {
        if (index < 0) index = 1;
        SetBitten(index, true);
        return true;
    }

    public float GetBaseCorpseSickness() {
        return getSicknessFromCorpsesRate(CorpseCount.instance.getCorpseCount(parentChar));
    }

    public static float getSicknessFromCorpsesRate(int corpses) {
        return corpses > 5 ? 0.01f * (corpses - 5) : 0.0f;
    }
}
