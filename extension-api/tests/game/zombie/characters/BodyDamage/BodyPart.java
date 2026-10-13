package zombie.characters.BodyDamage;

import zombie.characters.IsoGameCharacter;

/** Synthetic: a bite sets the infection of a part, as the game's does; a wound may roll for one. */
public class BodyPart {
    private final IsoGameCharacter parentChar;
    private boolean bitten, isInfected, isFakeInfected;
    /** How many times a wound rolled for an infection. */
    public int infectionRolls;
    public BodyPart(IsoGameCharacter parent) { this.parentChar = parent; }

    public IsoGameCharacter getParentChar() { return parentChar; }

    public boolean bitten() { return bitten; }

    public boolean IsInfected() { return isInfected; }

    public void SetInfected(boolean value) { isInfected = value; }

    public boolean IsFakeInfected() { return isFakeInfected; }

    public void SetFakeInfected(boolean value) { isFakeInfected = value; }

    public void SetBitten(boolean value) {
        bitten = value;
        if (value) {
            isInfected = true;
            isFakeInfected = false;
        }
    }

    public void generateZombieInfection(int chance) {
        infectionRolls++;
        if (chance > 0) isInfected = true;
    }

    public void setScratched(boolean scratched, boolean fake) {
        if (scratched && !fake) generateZombieInfection(7);
    }
}
