package zombie.core;

import java.util.HashMap;
import java.util.Map;

/** Synthetic: the game's language (none until a test sets one) and its texts, by language and key. */
public final class Translator {
    public static Language language;
    /** The texts a test gives: language code -> key -> text. A key without one is its own text, as in the game. */
    public static final Map<String, Map<String, String>> texts = new HashMap<>();

    private Translator() { }

    public static Language getLanguage() { return language; }

    public static String getText(String key) {
        Map<String, String> table = texts.get(language == null ? "EN" : language.name());
        String text = table == null ? null : table.get(key);
        return text == null ? key : text;
    }
}
