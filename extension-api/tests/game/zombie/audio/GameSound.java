package zombie.audio;

/** Synthetic: a sound of the game's sound scripts, as far as its clips' volume reads it (the master its volume is under). */
public final class GameSound {
    public enum MasterVolume { Primary, Ambient, Music, VehicleEngine }

    public String name;
    public MasterVolume master = MasterVolume.Primary;
}
