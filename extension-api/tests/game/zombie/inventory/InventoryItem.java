package zombie.inventory;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.ZomboidGlobals;
import zombie.characters.IsoGameCharacter;
import zombie.entity.components.fluids.FluidContainer;
import zombie.scripting.objects.ItemTag;
import zombie.scripting.objects.ItemType;

/**
 * Synthetic: an item, weighed as the game weighs it: its own weight and what it holds (ammunition, a fluid), equipped or
 * not. It has the fields the game's weight reads, and the setters write them, as the game's do.
 */
public class InventoryItem {
    public float actualWeight;
    public String displayCategory;
    public ItemType itemType = ItemType.NORMAL;
    public final Set<ItemTag> tags = new HashSet<>();
    public IsoGameCharacter equipParent;
    public ItemContainer container;
    public Object ammoType;
    public int currentAmmoCount;
    public boolean customWeight, cooked, burnt;
    public ArrayList<String> extraItems;
    public String fullType = "Base.Item", name = "Item", replaceOnUse, replaceOnUseFullType;
    public Object scriptItem;
    public FluidContainer fluid;
    public int attachedSlot = -1;
    public boolean onGround, customName;
    private KahluaTable modData;
    // the item's own use delta (a drainable has one of its own that shadows it, as in the game)
    private float useDelta = 1f;
    public InventoryItem(String displayCategory, float actualWeight) { this.displayCategory = displayCategory; this.actualWeight = actualWeight; }
    public String getDisplayCategory() { return displayCategory; }
    public void setDisplayCategory(String category) { displayCategory = category; }
    public void setItemType(ItemType type) { itemType = type; }
    public float getActualWeight() { return actualWeight; }
    public void setActualWeight(float weight) { actualWeight = weight; }
    public void setCustomWeight(boolean custom) { customWeight = custom; }
    public void setAmmoType(Object type) { ammoType = type; }
    public void setCurrentAmmoCount(int count) { currentAmmoCount = count; }
    public void setCooked(boolean value) { cooked = value; }
    public void setBurnt(boolean value) { burnt = value; }
    public void setName(String value) { name = value; }
    public String getName() { return name; }
    public boolean isCustomName() { return customName; }
    public void setCustomName(boolean value) { customName = value; }
    public float getUseDelta() { return useDelta; }
    public void setUseDelta(float value) { useDelta = value; }
    public void setType(String type) { fullType = "Base." + type; }
    public void setScriptItem(Object value) { scriptItem = value; }
    public void setReplaceOnUse(String value) { replaceOnUse = value; replaceOnUseFullType = "Base." + value; }
    public void setAttachedSlot(int slot) { attachedSlot = slot; }
    public void addExtraItem(String type) {
        if (extraItems == null) extraItems = new ArrayList<>();
        extraItems.add(type);
    }
    /** What the item holds that is not an item: ammunition (a tenth of a kilo each), a fluid (a kilo a litre). */
    public float getContentsWeight() { return currentAmmoCount * 0.1f + (fluid == null ? 0f : fluid.getAmount()); }
    public float getUnequippedWeight() { return getActualWeight() + getContentsWeight(); }
    public float getEquippedWeight() { return (getActualWeight() + getContentsWeight()) * (float)ZomboidGlobals.equippedOrWornEncumbranceMultiplier; }
    public float getHotbarEquippedWeight() { return (getActualWeight() + getContentsWeight()) * 0.7f; }
    public boolean isItemType(ItemType type) { return itemType == type; }
    public boolean hasTag(ItemTag tag) { return tags.contains(tag); }
    public String getFullType() { return fullType; }
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

    /** Puts a fluid container in the item, as the game's items have one as a component. */
    public void setFluid(FluidContainer value) {
        fluid = value;
        if (value != null) value.owner = this;
        // The game's items have their components from the moment they are made; a write the hooks see stands for that here.
        setCurrentAmmoCount(currentAmmoCount);
    }
}
