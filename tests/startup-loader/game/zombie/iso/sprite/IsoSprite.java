package zombie.iso.sprite;

import zombie.core.properties.PropertyContainer;

/** Synthetic. */
public final class IsoSprite {
    public final String name;
    public final PropertyContainer properties = new PropertyContainer();
    public IsoSprite(String name) { this.name = name; }
    public String getName() { return name; }
    public PropertyContainer getProperties() { return properties; }
}
