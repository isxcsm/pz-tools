package zombie.scripting;

import java.util.Map;
import zombie.scripting.objects.Item;

/** Synthetic: the item scripts, as the API reads a generator's wear from them. */
public class ScriptManager {
    public static final ScriptManager instance = new ScriptManager();
    private final Map<String, Item> items = Map.of("Base.Generator", new Item(30), "Base.Generator_Yellow", new Item(36));
    public Item getItem(String type) { return items.get(type); }
}
