package zombie.inventory.types;

import java.util.HashMap;
import zombie.characters.IsoGameCharacter;
import zombie.inventory.InventoryItem;

/** Synthetic: a weapon, which weighs more with parts attached, a magazine in it and a round chambered. */
public class HandWeapon extends InventoryItem {
    private final HashMap<String, WeaponPart> attachments = new HashMap<>();
    public boolean containsClip, roundChambered;
    public String magazineType;
    public HandWeapon(float actualWeight) { super("Weapon", actualWeight); }

    public void setContainsClip(boolean value) { containsClip = value; }
    public void setRoundChambered(boolean value) { roundChambered = value; }
    public void setMagazineType(String type) { magazineType = type; }

    public void clearAllWeaponParts() { attachments.clear(); }
    public void clearWeaponPart(WeaponPart part) { attachments.values().remove(part); }
    public void clearWeaponPart(String type) { attachments.remove(type); }
    public void setWeaponPart(String type, WeaponPart part) { attachments.put(type, part); }
    public void attachWeaponPart(IsoGameCharacter character, WeaponPart part, boolean sync) { attachments.put(part.fullType, part); }

    @Override public float getActualWeight() {
        float weight = super.getActualWeight();
        for (WeaponPart part : attachments.values()) weight += part.weightModifier;
        return weight;
    }

    /** A magazine and a round count a kilo each, so that the test sees them. */
    @Override public float getContentsWeight() {
        float weight = super.getContentsWeight();
        if (roundChambered) weight += 1f;
        if (containsClip && magazineType != null) weight += 1f;
        return weight;
    }
}
