package zombie.characters;

import zombie.audio.parameters.ParameterZombieState;
import zombie.characters.BodyDamage.BodyPartType;
import zombie.inventory.types.HandWeapon;
import zombie.iso.IsoMovingObject;

/** Synthetic: a zombie that bites, has a voice and falls. */
public class IsoZombie extends IsoGameCharacter {
    public final ParameterZombieState parameterZombieState = new ParameterZombieState(this);
    public IsoMovingObject target;
    /** Whether it crawls, the part of the last hit (the game keeps one, chosen by chance: the test chooses), and whether hits do not hurt it. */
    public boolean crawling, immortal;
    public BodyPartType lastHitPart;
    public BodyPartType nextHitPart = BodyPartType.Torso_Upper;
    /** The hits the game's own method took, whatever the hook did. */
    public int hits;
    public long vocalEvent;
    /** The falls it landed from. */
    public int falls;
    private final BaseCharacterSoundEmitter emitter = new BaseCharacterSoundEmitter();

    /** Its outfit, its number in the population, the square it last set out for, and whether it left the world. */
    public String outfitName;
    public int persistentId;
    public int pathX = Integer.MIN_VALUE, pathY = Integer.MIN_VALUE;
    public boolean removed;

    /** Like the game's: the zombie leaves the world (its object is kept for another) and its number goes. */
    public void removeFromWorld() {
        removed = true;
        persistentId = 0;
    }

    public String getOutfitName() { return outfitName; }

    public void pathToLocation(int x, int y, int z) { pathX = x; pathY = y; }

    public BaseCharacterSoundEmitter getEmitter() { return emitter; }

    public boolean isCrawling() { return crawling; }

    /**
     * The zombie's own hit, shaped as the game's: a zombie that cannot be hurt and a missing attacker return at once, the part is
     * chosen and kept, and the character's hit works the damage out, applies it and returns it.
     */
    @Override public float Hit(HandWeapon weapon, IsoGameCharacter attacker, float damage, boolean stagger, float knockback, boolean remote) {
        if (immortal) return 0f;
        BodyPartType part = nextHitPart;
        lastHitPart = part;
        float dealt = super.Hit(weapon, attacker, damage, stagger, knockback, remote);
        hits++;
        return dealt;
    }

    public String getVoiceSoundName() { return "MaleZombieCombined"; }

    /** The zombie's own landing (the game's does not call the character's). */
    @Override protected void handleLandingImpact(FallDamage damage) { falls++; }

    /** The radius a server tells its clients a zombie's sound is heard over. */
    public enum ZombieSound {
        Burned(10), DeadCloseKilled(10), DeadNotCloseKilled(10), Hurt(10), Idle(15), Lunge(40), MAX(-1);

        private final int radius;

        ZombieSound(int radius) { this.radius = radius; }

        public int radius() { return radius; }
    }
}
