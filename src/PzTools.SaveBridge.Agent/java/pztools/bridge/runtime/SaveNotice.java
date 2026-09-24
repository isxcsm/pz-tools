package pztools.bridge.runtime;

import java.lang.reflect.Method;
import java.util.concurrent.TimeUnit;

/** Replaces the player's single halo note; never queues chat or runs a timer thread. */
final class SaveNotice {
    private final Object player;
    private final Method setHaloNote;
    private final String[] messages;
    private final long due;
    private int displayedSeconds = -1;

    SaveNotice(ClassLoader loader, String language, long notBefore) throws ReflectiveOperationException {
        Class<?> players = Class.forName("zombie.characters.IsoPlayer", false, loader);
        player = players.getMethod("getInstance").invoke(null);
        if (player == null) throw new IllegalStateException("No local player for save notification");
        setHaloNote = players.getMethod("setHaloNote", String.class, int.class, int.class, int.class, float.class);
        messages = NoticeLanguages.get(language);
        due = notBefore != 0 ? notBefore : System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
    }

    boolean ready(long now) throws ReflectiveOperationException {
        int seconds = (int)Math.max(0, Math.ceil((due - now) / 1_000_000_000.0));
        // No start message or extra render-frame delay at the scheduled boundary.
        if (seconds == 0) return true;
        if (seconds > 5) return false;
        if (seconds != displayedSeconds) {
            displayedSeconds = seconds;
            show(messages[0].replace("{0}", Integer.toString(seconds)), false);
        }
        return false;
    }

    void complete(boolean success) throws ReflectiveOperationException {
        show(messages[success ? 1 : 2], !success);
    }

    private void show(String text, boolean failed) throws ReflectiveOperationException {
        setHaloNote.invoke(player, text, failed ? 255 : 180, failed ? 110 : 230,
            failed ? 110 : 255, 180.0f);
    }
}
