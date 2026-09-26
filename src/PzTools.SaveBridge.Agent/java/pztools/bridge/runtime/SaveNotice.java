package pztools.bridge.runtime;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.concurrent.TimeUnit;

/** Replaces the player's single halo note; never queues chat or runs a timer thread. */
final class SaveNotice {
    private static final long REFRESH_NANOS = TimeUnit.MILLISECONDS.toNanos(500);
    private static final float HALO_DURATION = 180.0f;
    private final Object player;
    private final Method getPlayer;
    private final Method setHaloNote;
    private final Method haloTimer;
    private final Field worldInstance, worldCell, statesField, currentState;
    private final Object world, cell, state;
    private final String[] messages;
    private final long due;
    private int displayedSeconds = -1;
    private long nextSavingRefresh;
    private boolean detached;

    SaveNotice(ClassLoader loader, String language, long notBefore) throws ReflectiveOperationException {
        Class<?> players = Class.forName("zombie.characters.IsoPlayer", false, loader);
        getPlayer = players.getMethod("getInstance");
        player = getPlayer.invoke(null);
        if (player == null) throw new IllegalStateException("No local player for save notification");
        setHaloNote = players.getMethod("setHaloNote", String.class, int.class, int.class, int.class, float.class);
        haloTimer = players.getMethod("getHaloTimerCount");
        Class<?> worlds = Class.forName("zombie.iso.IsoWorld", false, loader);
        worldInstance = worlds.getField("instance");
        worldCell = worlds.getField("currentCell");
        world = worldInstance.get(null);
        cell = world == null ? null : worldCell.get(world);
        statesField = Class.forName("zombie.GameWindow", false, loader).getField("states");
        Object states = statesField.get(null);
        currentState = states.getClass().getField("current");
        state = currentState.get(states);
        messages = NoticeLanguages.get(language);
        due = notBefore != 0 ? notBefore : System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
    }

    boolean ready(long now) throws ReflectiveOperationException {
        int seconds = (int)Math.max(0, Math.ceil((due - now) / 1_000_000_000.0));
        // Admission, not the countdown boundary, starts the progress notice.
        if (seconds == 0) return true;
        if (seconds > 5) return false;
        if (seconds != displayedSeconds) {
            displayedSeconds = seconds;
            show(messages[0].replace("{0}", Integer.toString(seconds)), false);
        }
        return false;
    }

    void saving(long now) throws ReflectiveOperationException {
        if (!attached()) return;
        // The game decrements this clock using its speed multiplier, not real time.
        // Refresh early under fast-forward, before its last-quarter alpha fade.
        if (nextSavingRefresh != 0 && now < nextSavingRefresh
                && ((Number)haloTimer.invoke(player)).floatValue() > HALO_DURATION / 2) return;
        // Renew the existing halo while capture/commit proceeds over multiple frames.
        // This adds no timer thread, render-frame wait, or work to the capture timing.
        nextSavingRefresh = now + REFRESH_NANOS;
        show(messages[3], false);
    }

    void complete(boolean success) throws ReflectiveOperationException {
        show(messages[success ? 1 : 2], !success);
    }

    private void show(String text, boolean failed) throws ReflectiveOperationException {
        if (!attached()) return;
        setHaloNote.invoke(player, text, failed ? 255 : 180, failed ? 110 : 230,
            failed ? 110 : 255, HALO_DURATION);
    }

    private boolean attached() throws ReflectiveOperationException {
        // Never retarget an old request to a new world or a replacement character.
        // Latch detachment so briefly leaving and reentering cannot revive a notice.
        if (detached) return false;
        if (getPlayer.invoke(null) != player || worldInstance.get(null) != world || world == null
                || worldCell.get(world) != cell || cell == null
                || currentState.get(statesField.get(null)) != state) {
            detached = true;
            return false;
        }
        return true;
    }
}
