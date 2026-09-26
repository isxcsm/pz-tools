package zombie.characters;
import zombie.scripting.objects.CharacterTrait;
public class IsoGameCharacter { public boolean sunday,fast; public boolean hasTrait(CharacterTrait trait) { return trait==CharacterTrait.SUNDAY_DRIVER?sunday:fast; } }
