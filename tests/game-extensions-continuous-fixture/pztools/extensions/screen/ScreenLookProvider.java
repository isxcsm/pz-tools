package pztools.extensions.screen;

import pztools.extensions.api.*;
import pztools.extensions.runtime.FrameListener;
import java.lang.instrument.Instrumentation;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Synthetic second continuous module. It touches no game state; it only records what the host asks of it. */
public final class ScreenLookProvider implements ContinuousProvider, FrameListener {
    private final String generation = UUID.randomUUID().toString().replace("-", "");
    private final AtomicInteger frames = new AtomicInteger(), updates = new AtomicInteger();
    private volatile boolean active, failing;
    private volatile String setting = "";
    public String id() { return "pztools.screen-look"; }
    public Support initialize(Instrumentation instrumentation, ClassLoader loader) { return new Support(true, null); }
    public void validateConfig(Map<String, String> config) {
        if ("true".equals(config.get("fixture_reject"))) throw new IllegalArgumentException("fixture-rejected");
    }
    public void activate(Context context, Map<String, String> config) {
        context.requireGameThread(); apply(config); active = true;
    }
    public void updateConfig(Map<String, String> config) { updates.incrementAndGet(); apply(config); }
    private void apply(Map<String, String> config) {
        setting = config.getOrDefault("fixture_value", "");
        failing = "true".equals(config.get("fixture_fail"));
    }
    public void gameFrame() { if (active) frames.incrementAndGet(); }
    public String failureReason() { return active && failing ? "fixture-failed" : null; }
    public void deactivate() { active = false; }
    public void close() { deactivate(); }
    public String diagnostics() {
        return "lookGeneration=" + generation + ";lookActive=" + active + ";lookValue=" + setting
            + ";lookFrames=" + frames.get() + ";lookUpdates=" + updates.get();
    }
}
