package zombie.characters;

import zombie.audio.parameters.ParameterZombieState;
import zombie.iso.IsoMovingObject;

/** Synthetic: a zombie that bites, has a voice and falls. */
public class IsoZombie extends IsoGameCharacter {
    public final ParameterZombieState parameterZombieState = new ParameterZombieState(this);
    public IsoMovingObject target;
    public long vocalEvent;
    /** The falls it landed from. */
    public int falls;
    private final BaseCharacterSoundEmitter emitter = new BaseCharacterSoundEmitter();

    public BaseCharacterSoundEmitter getEmitter() { return emitter; }

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
