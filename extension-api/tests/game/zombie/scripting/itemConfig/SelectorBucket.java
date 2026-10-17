package zombie.scripting.itemConfig;

import zombie.scripting.itemConfig.script.SelectorBucketScript;

/** Synthetic: a bucket of an item's config, which reads the number of the buckets under it as it resolves (none: null, as the game makes it). */
public class SelectorBucket {
    private final SelectorBucket[] children;
    private final int[] selectorIds;
    private final Randomizer randomizer;

    public SelectorBucket(int[] selectorIds, SelectorBucketScript script, SelectorBucket[] children, Randomizer randomizer) {
        this.selectorIds = selectorIds;
        this.children = children;
        this.randomizer = randomizer;
    }

    public boolean Resolve() {
        for (int i = 0; i < children.length; i++)
            if (children[i].Resolve()) return true;
        return randomizer != null;
    }
}
