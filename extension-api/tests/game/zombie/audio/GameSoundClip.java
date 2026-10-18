package zombie.audio;

/**
 * Synthetic: a clip of a sound, an FMOD event of the game's banks or a sound file (a mod's); its volume as the game works it
 * out (the script's volume times the player's own for the sound, 1 here).
 */
public final class GameSoundClip {
    public final GameSound gameSound;
    public String event;
    public String file;
    public float volume = 1f;

    public GameSoundClip(GameSound gameSound) { this.gameSound = gameSound; }

    public float getEffectiveVolume() { return volume * 1f; }

    public float getEffectiveVolumeInMenu() { return volume * 1f; }
}
