package zombie.inventory;

import java.util.HashSet;
import java.util.Set;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.ZomboidGlobals;
import zombie.characters.IsoGameCharacter;
import zombie.scripting.objects.ItemTag;
import zombie.scripting.objects.ItemType;

/** Synthetic: an item, weighed as the game weighs it: its own weight and what it holds, equipped or not. */
public class InventoryItem {
    public float actualWeight;
    public String displayCategory;
    public ItemType itemType = ItemType.NORMAL;
    public final Set<ItemTag> tags = new HashSet<>();
    public IsoGameCharacter equipParent;
    public ItemContainer container;
    /** What the item holds that is not an item: ammunition, a fluid. */
    public float contents;
    public int attachedSlot = -1;
    public boolean onGround;
    private KahluaTable modData;
    public InventoryItem(String displayCategory, float actualWeight) { this.displayCategory = displayCategory; this.actualWeight = actualWeight; }
    public String getDisplayCategory() { return displayCategory; }
    public float getActualWeight() { return actualWeight; }
    public float getContentsWeight() { return contents; }
    public float getUnequippedWeight() { return getActualWeight() + getContentsWeight(); }
    public float getEquippedWeight() { return (getActualWeight() + getContentsWeight()) * (float)ZomboidGlobals.equippedOrWornEncumbranceMultiplier; }
    public float getHotbarEquippedWeight() { return (getActualWeight() + getContentsWeight()) * 0.7f; }
    public boolean isItemType(ItemType type) { return itemType == type; }
    public boolean hasTag(ItemTag tag) { return tags.contains(tag); }
    public boolean hasTag(ItemTag... list) { for (ItemTag tag : list) if (hasTag(tag)) return true; return false; }
    public IsoGameCharacter getEquipParent() { return equipParent; }
    public int getAttachedSlot() { return attachedSlot; }
    public boolean isFakeEquipped(IsoGameCharacter character) { return false; }
    public ItemContainer getContainer() { return container; }
    public boolean hasModData() { return modData != null; }
    public KahluaTable getModData() {
        if (modData == null) modData = LuaManager.platform.newTable();
        return modData;
    }
}
