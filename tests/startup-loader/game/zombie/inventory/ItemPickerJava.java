package zombie.inventory;

import java.util.Objects;
import zombie.characters.IsoGameCharacter;

/** Synthetic: the chance of an item in a container or on a corpse, and the modifiers of the kinds of loot. */
public class ItemPickerJava {
    public static float ammoLootModifier = 1.0f;
    public static float otherLootModifier = 1.0f;

    public static class ItemPickerItem {
        public String itemName = "Base.Item";
        public float chance = 0.05f;
    }

    public static float getLootModifierFromType(String type) {
        float other = otherLootModifier;
        if (Objects.equals(type, "Generator")) return 4.0f;
        if (Objects.equals(type, "Ammo")) return ammoLootModifier;
        return other;
    }

    public static float getLootModifier(String itemName) {
        return itemName.startsWith("Base.Bullets") ? getLootModifierFromType("Ammo") : getLootModifierFromType("Other");
    }

    public static float getActualSpawnChance(ItemPickerItem item, IsoGameCharacter character, ItemContainer container, float zombieDensity, boolean corpse) {
        float modifier = getLootModifier(item.itemName);
        if (modifier == 0.0f) return 0.0f;
        return item.chance * 100.0f * modifier + zombieDensity;
    }
}
