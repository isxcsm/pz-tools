package pztools.extensions.vehicle;

import pztools.extensions.api.*;
import java.lang.instrument.Instrumentation;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Synthetic control/retirement provider. It never accesses game fields or alters physics. */
public final class VehicleDrivetrainProvider implements ContinuousProvider, pztools.extensions.runtime.FrameListener {
    private final String fixtureGeneration = UUID.randomUUID().toString().replace("-", "");
    private final AtomicInteger callbacks = new AtomicInteger(), frames = new AtomicInteger(), lateFrames = new AtomicInteger();
    private volatile boolean active;
    private volatile String setting = "";
    private VehicleHooks.Retirement retirement;
    public String id() { return "pztools.vehicle-drivetrain"; }
    public Support initialize(Instrumentation instrumentation, ClassLoader loader) { return new Support(true, null); }
    public void validateConfig(Map<String, String> config) {
        if ("true".equals(config.get("fixture_reject"))) throw new IllegalArgumentException("fixture-rejected");
    }
    public synchronized void activate(Context context, Map<String, String> config) {
        context.requireGameThread(); setting = config.getOrDefault("fixture_value", "");
        VehicleHooks.register(this, (controller, mode, speed) -> { callbacks.incrementAndGet(); return VehicleHooks.VANILLA; });
        if (!context.worldValid().get()) { retirement = VehicleHooks.unregister(this); return; }
        active = true;
    }
    // Per-frame work is owed only to an active generation.
    public void gameFrame() { if (active) frames.incrementAndGet(); else lateFrames.incrementAndGet(); }
    public void updateConfig(Map<String, String> config) { setting = config.getOrDefault("fixture_value", ""); }
    public synchronized void deactivate() {
        active = false;
        if (retirement == null) retirement = VehicleHooks.unregister(this);
    }
    public void close() throws Exception { deactivate(); if (retirement != null) retirement.await(5000); }
    public String diagnostics() {
        return "fixtureGeneration=" + fixtureGeneration + ";fixtureActive=" + active
            + ";fixtureValue=" + setting + ";fixtureCallbacks=" + callbacks.get()
            + ";fixtureFrames=" + frames.get() + ";fixtureLateFrames=" + lateFrames.get();
    }
}
