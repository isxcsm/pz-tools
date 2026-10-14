package zombie;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/** Synthetic: its loading matters to the startup loader test; and it writes strings to the game's files, as the game's. */
public final class GameWindow {
    public static void WriteString(ByteBuffer buffer, String text) {
        byte[] bytes = text == null ? new byte[0] : text.getBytes(StandardCharsets.UTF_8);
        buffer.putShort((short)bytes.length);
        buffer.put(bytes);
    }

    public static String ReadString(ByteBuffer buffer) {
        byte[] bytes = new byte[buffer.getShort()];
        buffer.get(bytes);
        return new String(bytes, StandardCharsets.UTF_8);
    }
}
