package zombie.inventory;

import java.util.ArrayList;
import zombie.characters.IsoGameCharacter;
import zombie.inventory.types.InventoryContainer;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.objects.IsoDeadBody;
import zombie.vehicles.VehiclePart;

/**
 * Synthetic: like the game's, an appliance has power when its square has, if generators are asked about; and a container
 * has a capacity the game clamps (100, 50 for an item's, 1000 for a vehicle's), a trait multiplier for the effective
 * one, and room for an item when its weight and the load are within it.
 */
public final class ItemContainer {
    public IsoObject parent;
    public boolean fridge, freezer;
    public int capacity = 50;
    public String type = "";
    public final ArrayList<InventoryItem> items = new ArrayList<>();
    public InventoryItem containingItem;
    public VehiclePart vehiclePart;
    public InventoryContainer inventoryContainer;
    public boolean vehicleSeat, seatOccupied;
    public ItemContainer(IsoObject parent) { this.parent = parent; }
    public boolean isFridge() { return fridge; }
    public boolean isFreezer() { return freezer; }
    public IsoObject getParent() { return parent; }
    public IsoGridSquare getSourceGrid() { return parent == null ? null : parent.getSquare(); }
    public static boolean isObjectPowered(IsoObject object, boolean generators) {
        if (object == null || object.getSquare() == null) return false;
        return generators && object.getSquare().haveElectricity();
    }

    public ArrayList<InventoryItem> getItems() { return items; }
    public InventoryItem getContainingItem() { return containingItem; }
    public VehiclePart getVehiclePart() { return vehiclePart; }
    public String getType() { return type; }
    public boolean isOccupiedVehicleSeat() { return vehicleSeat && seatOccupied; }
    public boolean contains(InventoryItem item) { return items.contains(item); }

    public float getContentsWeight() {
        float total = 0.0f;
        for (int index = 0; index < items.size(); index++) total += items.get(index).getUnequippedWeight();
        return total;
    }

    public float getCapacityWeight() {
        IsoObject owner = parent;
        if (owner instanceof IsoGameCharacter character) return character.getInventoryWeight();
        return getContentsWeight();
    }

    public float getMaxWeight() {
        IsoObject owner = parent;
        if (owner instanceof IsoGameCharacter character) return character.getMaxWeight();
        return getCapacity();
    }

    public int getCapacity() {
        int value = capacity;
        if (isOccupiedVehicleSeat()) value = value / 4;
        if (getVehiclePart() != null) return Math.min(value, 1000);
        if (containingItem != null && containingItem instanceof InventoryItem) return Math.min(value, 50);
        return Math.min(value, 100);
    }

    public int getEffectiveCapacity(IsoGameCharacter character) {
        int value = getCapacity();
        if (character != null && !(parent instanceof IsoGameCharacter) && !(parent instanceof IsoDeadBody) && !"floor".equals(getType())) {
            if (character.organized) return (int)Math.max(value * 1.3f, value + 1);
            if (character.disorganized) return (int)Math.max(value * 0.7f, 1.0f);
        }
        return value;
    }

    /** Whether the item fits, as the game asks it of a container: against the carrier's inventory when the container is a worn bag. */
    public boolean hasRoomFor(IsoGameCharacter character, InventoryItem item) {
        if (containingItem != null && containingItem.getEquipParent() != null && containingItem.getEquipParent().getInventory() != null
                && !containingItem.getEquipParent().getInventory().contains(item)) {
            if (character != null && containingItem.getEquipParent().getInventory().getCapacityWeight() + item.getUnequippedWeight()
                    <= containingItem.getEquipParent().getInventory().getEffectiveCapacity(character))
                return hasRoomFor(character, item.getUnequippedWeight());
            return false;
        }
        if (worldItem && item.onGround) return hasRoomFor(character, item.getUnequippedWeight(), 0.0f);
        return hasRoomFor(character, item.getUnequippedWeight());
    }

    /** Set on a container that is an item lying in the world, for the test. */
    public boolean worldItem;

    public boolean hasRoomFor(IsoGameCharacter character, float weight) { return hasRoomFor(character, weight, weight); }

    public boolean hasRoomFor(IsoGameCharacter character, float weight, float unused) {
        return getCapacityWeight() + weight <= getEffectiveCapacity(character);
    }
}
