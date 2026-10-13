package zombie.characters;

/** Synthetic: the slots that play the nearest zombies' voices, each started as the game's slot starts it. */
public final class ZombieVocalsManager {
    private ZombieVocalsManager() { }

    public static final class Slot {
        IsoZombie character;
        boolean playing;

        /** The game's own: a zombie that has no voice playing has one started. */
        public void playSound(IsoZombie zombie) {
            if (character != null && character != zombie && character.vocalEvent != 0L) {
                character.getEmitter().stopSoundLocal(character.vocalEvent);
                character.vocalEvent = 0L;
            }
            character = zombie;
            playing = true;
            if (character.vocalEvent == 0L) {
                String name = zombie.getVoiceSoundName();
                zombie.vocalEvent = zombie.getEmitter().playVocals(name);
            }
        }
    }
}
