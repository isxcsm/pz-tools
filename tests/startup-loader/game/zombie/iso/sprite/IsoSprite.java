package zombie.iso.sprite;

import zombie.core.properties.PropertyContainer;

/** Synthetic: a sprite, and an animation of {@code frames} frames stepped as the game steps one. */
public final class IsoSprite {
    public final String name;
    public final PropertyContainer properties = new PropertyContainer();
    public int frames = 4;
    /** How many times an instance was stepped; a failing sprite throws instead. */
    public int steps;
    public boolean failing;
    public IsoSprite(String name) { this.name = name; }
    public String getName() { return name; }
    public PropertyContainer getProperties() { return properties; }

    /** Like the game's: the instance's frame moves by its speed (a frame's time being 1 here) and loops. */
    public void update(IsoSpriteInstance instance) {
        if (failing) throw new IllegalStateException("the synthetic sprite failed");
        steps++;
        instance.frame += instance.animFrameIncrease;
        if ((int)instance.frame >= frames) instance.frame = 0;
    }
}
