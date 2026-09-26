package pztools.bridge.runtime;

import java.util.HashMap;
import java.util.Map;

/** Shares the exact catalog embedded in the app and worker; accepts no arbitrary message text. */
final class NoticeLanguages {
    private static final Map<String, String[]> LANGUAGES = load();

    static boolean supports(String language) { return LANGUAGES.containsKey(language); }

    static String[] get(String language) {
        String[] messages = LANGUAGES.get(language);
        if (messages == null) throw new IllegalArgumentException("Unsupported notice language");
        return messages;
    }

    private static Map<String, String[]> load() {
        var result = new HashMap<String, String[]>();
        // The stable bootstrap snapshots classes only. Compile the shared catalog
        // into a payload class so already-running games need no bootstrap upgrade.
        for (String line : NoticeLanguageData.ROWS) {
            String[] fields = line.split("\t", -1);
            if (fields.length != 10) throw new IllegalStateException("Invalid language catalog");
            result.put(fields[1], new String[] { fields[6], fields[7], fields[8], fields[9] });
        }
        result.put("ko", result.get("ko-KR"));
        result.put("en", result.get("en-US"));
        return Map.copyOf(result);
    }
}
