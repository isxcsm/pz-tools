package zombie.scripting.objects;

/** Synthetic: an item script, with the chance its condition lowers (ConditionLowerChanceOneIn) and its full type. */
public class Item {
    private final int conditionLowerChance;
    private final String fullName;
    public Item(int conditionLowerChance) { this.conditionLowerChance = conditionLowerChance; fullName = "Base.Item"; }
    public Item(String fullName) { conditionLowerChance = 0; this.fullName = fullName; }
    public int getConditionLowerChance() { return conditionLowerChance; }
    public String getFullName() { return fullName; }
}
