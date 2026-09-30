package pztools.extensions.screen;

import java.lang.instrument.Instrumentation;
import java.util.Map;
import pztools.extensions.api.ContinuousProvider;
import pztools.extensions.runtime.FrameListener;

/**
 * The screen look as a module of its own: on means the grade is wanted, off means the game's
 * picture is its own again. It changes no game class and installs no hook; everything it does to
 * the game is one shader program, put in place and taken back by {@link ScreenGrade}.
 */
public final class ScreenLookProvider implements ContinuousProvider, FrameListener {
    private ScreenGrade.Platform platform;
    private volatile ScreenGrade grade;
    private volatile GradeParameters.Request request = GradeParameters.Request.OFF;

    @Override public String id() { return "pztools.screen-look"; }

    /** Looks the game's classes up and nothing more; a game that no longer has them is simply unsupported. */
    @Override public Support initialize(Instrumentation instrumentation, ClassLoader gameClasses) {
        try { platform = ScreenGrade.resolve(gameClasses); return new Support(true, null); }
        catch (ReflectiveOperationException | LinkageError changed) { return new Support(false, "screen-shader-contract-changed"); }
    }
    @Override public void validateConfig(Map<String, String> config) { GradeParameters.Request.parse(config); }
    // A colour grade resets nothing in the game, so there is no moment it has to wait for.
    @Override public synchronized void activate(Context context, Map<String, String> config) {
        context.requireGameThread();
        if (platform == null) throw new IllegalStateException("not-initialized");
        request = GradeParameters.Request.parse(config);
        grade = new ScreenGrade(platform);
    }
    @Override public void updateConfig(Map<String, String> config) { request = GradeParameters.Request.parse(config); }
    @Override public void gameFrame() { ScreenGrade current = grade; if (current != null) current.frame(request); }
    /**
     * A shader this driver or game version rejects is a fault of this module alone: the host turns
     * it off and says so, and the picture stays the game's own.
     */
    @Override public String failureReason() {
        ScreenGrade current = grade;
        String state = current == null ? null : current.state();
        return state != null && state.startsWith("failed:") ? state.substring("failed:".length()) : null;
    }
    @Override public String diagnostics() {
        ScreenGrade current = grade;
        return current == null ? "" : "screen=" + current.state() + ";screen_parts=" + current.detail();
    }
    @Override public void deactivate() { ScreenGrade current = grade; if (current != null) current.stop(); }
    @Override public void close() { deactivate(); grade = null; platform = null; }
}
