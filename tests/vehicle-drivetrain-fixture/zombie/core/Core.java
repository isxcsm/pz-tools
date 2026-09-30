package zombie.core;

import java.util.HashMap;
import java.util.Map;

/** Synthetic key bindings; absent by default so the adapter uses the game's per-frame input. */
public final class Core {
    public static Core instance;
    public static zombie.ui.UITextEntryInterface currentTextEntryBox;
    public final Map<String,KeyBinding> bindings=new HashMap<>();
    public static Core getInstance() { return instance; }
    public KeyBinding getKeyBinding(String name) { return bindings.get(name); }
    public record KeyBinding(String name,int keyValue,int altKey,boolean shift,boolean ctrl,boolean alt) { }
}
