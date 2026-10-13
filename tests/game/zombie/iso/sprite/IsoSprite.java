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

    /** What render drew, in order: the sprite, the object, x, y, z, the direction, the offsets, r, g, b, a and the prepare flag. */
    public static final java.util.ArrayList<Object[]> drawn = new java.util.ArrayList<>();
    /** Whether render keeps what it drew (the cost measurements turn it off). */
    public static boolean recording = true;

    /** Like the game's: draws the sprite as part of the object at x, y, z (here: what it was asked is kept). */
    public final void render(zombie.iso.IsoObject object, float x, float y, float z, zombie.iso.IsoDirections dir, float offsetX, float offsetY,
            zombie.core.textures.ColorInfo colour, boolean prepare) {
        if (recording) drawn.add(new Object[] { this, object, x, y, z, dir, offsetX, offsetY, colour.r, colour.g, colour.b, colour.a, prepare,
            zombie.IndieGL.depthMask });
    }
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
