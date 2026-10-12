package zombie.characters.BodyDamage;

import zombie.characters.IsoPlayer;

/** Synthetic: how fast a cold is caught, from the player's thermoregulation. */
public class Thermoregulator {
    private final IsoPlayer player;
    /** The delta before the hypothermia moodle's level multiplies it. */
    public float skin;
    public Thermoregulator(IsoPlayer player) { this.player = player; }

    public float getCatchAColdDelta() {
        float delta = skin;
        if (player.hypothermia > 1) delta = delta * player.hypothermia;
        return delta;
    }
}
