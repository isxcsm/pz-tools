package zombie.characters;
import zombie.characters.Moodles.Moodles;
import zombie.scripting.objects.CharacterTrait;
public class IsoGameCharacter {
    public boolean sunday,fast;
    public Moodles moodles=new Moodles();
    public boolean hasTrait(CharacterTrait trait) { return trait==CharacterTrait.SUNDAY_DRIVER?sunday:fast; }
    public Moodles getMoodles() { return moodles; }
}
