package zombie.scripting.objects;

/** Synthetic: an item script, with the chance its condition lowers (ConditionLowerChanceOneIn). */
public class Item {
    private final int conditionLowerChance;
    public Item(int conditionLowerChance) { this.conditionLowerChance = conditionLowerChance; }
    public int getConditionLowerChance() { return conditionLowerChance; }
}
