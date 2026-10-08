package zombie.characters.Moodles;

import zombie.characters.IsoGameCharacter;

/** Synthetic: the heavy load moodle asks how heavily the character is loaded, as the game's does. */
public class Moodle {
    public final IsoGameCharacter isoGameCharacter;
    /** The load over the most the character can carry, as the last update saw it. */
    public float ratio;
    public Moodle(IsoGameCharacter character) { this.isoGameCharacter = character; }

    public boolean Update() {
        float load = isoGameCharacter.getInventory().getCapacityWeight();
        float max = isoGameCharacter.getMaxWeight();
        ratio = load / max;
        return true;
    }
}
