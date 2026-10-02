package zombie.characters.Moodles;
import zombie.scripting.objects.MoodleType;
public final class Moodles {
    public int drunk;
    public int getMoodleLevel(MoodleType type) { return type==MoodleType.DRUNK?drunk:0; }
}
