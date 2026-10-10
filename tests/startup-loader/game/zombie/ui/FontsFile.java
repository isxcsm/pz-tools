package zombie.ui;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;

/**
 * Synthetic: the game's reader of {@code fonts.txt}. A font a line: its name, then {@code fnt=}, {@code img=} and {@code type=}
 * (the game's file is a script of blocks; what it gives is the same). A later file's font replaces an earlier one's of that name.
 */
public final class FontsFile {
    /** Reads the file at that path into the fonts; false when there is none. */
    public boolean read(String path, HashMap<String, FontsFileFont> fonts) {
        Path file = Path.of(path);
        if (!Files.isRegularFile(file)) return false;
        try {
            for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
                String[] words = line.trim().split(" +");
                if (words[0].isEmpty()) continue;
                var font = new FontsFileFont();
                font.id = words[0];
                for (int index = 1; index < words.length; index++) {
                    String[] pair = words[index].split("=", 2);
                    switch (pair[0]) {
                        case "fnt" -> font.fnt = pair[1];
                        case "img" -> font.img = pair[1];
                        case "type" -> font.type = pair[1];
                        default -> throw new IllegalArgumentException("Unknown field " + pair[0] + " in " + path);
                    }
                }
                fonts.put(font.id, font);
            }
            return true;
        } catch (IOException failure) { return false; }
    }
}
