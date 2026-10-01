package pztools.extensions.runtime;

import pztools.extensions.api.*;
import pztools.extensions.api.internal.ClassArchive;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.*;

/**
 * One continuous module's slot: its generation, configuration and revision. The host keeps one
 * slot per module, so modules are applied, updated, faulted and retired independently of each
 * other. Independent of CheckpointRuntime. No lifecycle lock crosses a game callback.
 */
final class ContinuousRuntime {
    /** Capabilities that run for as long as they are on, as opposed to once per save. */
    static final Set<String> CAPABILITIES = Set.of("vehicle.drivetrain.v1");
    private record Definition(String id, String version, String namespace, String entry, String jar, VersionSupport support) { }
    private final Object operations = new Object();
    private final AtomicReference<Generation> current = new AtomicReference<>();
    private volatile ContinuousModules.Status report = empty("Disabled", null);
    private boolean poisoned, closed;
    private Path directory;
    ContinuousRuntime(Path directory) { this.directory = directory; }
    void relocate(Path next) { synchronized (operations) { directory = next; } }
    /** Whether this slot holds a generation or a fault that must stay visible. */
    boolean occupied() { return current.get() != null || poisoned; }
    private static ContinuousModules.Status empty(String state, String reason) {
        return new ContinuousModules.Status(state, reason, RuntimeIdentity.processId(), null, null, -1, null, null, "");
    }
    private static final class Generation {
        final ContinuousProvider provider; final Definition definition; final String digest;
        final String id = UUID.randomUUID().toString().replace("-", "");
        final AtomicBoolean valid = new AtomicBoolean(true);
        final String world; final ClassLoader loader;
        volatile ContinuousModules.Apply pending;
        /** What the provider was last given; an identical request is acknowledged without disturbing it. */
        volatile Map<String, String> applied;
        volatile ContinuousProvider.Context context;
        volatile boolean activated, revoked;
        volatile long revision = -1;
        int callbacks;
        Generation(ContinuousProvider provider, Definition definition, String digest,
                   ContinuousModules.Apply request, ClassLoader loader) {
            this.provider = provider; this.definition = definition; this.digest = digest;
            world = request.worldId(); this.loader = loader; pending = request;
        }
        synchronized boolean acquire() { if (revoked) return false; callbacks++; return true; }
        synchronized void release() { callbacks--; notifyAll(); }
        void revoke() {
            synchronized (this) { revoked = true; valid.set(false); pending = null; }
            provider.deactivate();
        }
        synchronized void await() throws InterruptedException, TimeoutException {
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (callbacks != 0) {
                long left = deadline - System.nanoTime();
                if (left <= 0) throw new TimeoutException("Continuous lifecycle callback still in flight");
                TimeUnit.NANOSECONDS.timedWait(this, left);
            }
        }
        ContinuousModules.Status status(String state, String reason) {
            return new ContinuousModules.Status(state, reason, RuntimeIdentity.processId(), world, id,
                revision, definition.version, digest, "");
        }
    }
    ContinuousModules.Status apply(ContinuousModules.Apply request, Instrumentation instrumentation,
                                   ClassLoader loader, String version) {
        synchronized (operations) {
            if (poisoned || closed) return report;
            if (!request.processId().equals(RuntimeIdentity.processId())) return rejected("process-changed");
            if (!request.worldId().matches("[a-f0-9]{32}") || request.revision() < 0
                    || request.expectedRevision() != report.appliedRevision()) return rejected("revision-conflict");
            ContinuousProvider candidate = null;
            try {
                Definition definition = definition(request.moduleId());
                if (!request.forceVersion() && !definition.support.matches(version)) return rejected("version-mismatch");
                var archive = ClassArchive.read(directory.resolve(definition.jar));
                archive.require("PzTools-Extension-Api", Integer.toString(ExtensionApi.HOST_ABI));
                Generation old = current.get();
                if (old != null && !old.revoked && old.loader == loader && old.world.equals(request.worldId())
                        && old.definition.equals(definition) && old.digest.equals(archive.digest())) {
                    old.provider.validateConfig(request.config());
                    synchronized (old) {
                        if (old.revoked || request.expectedRevision() != old.revision || request.revision() <= old.revision)
                            return rejected("revision-conflict");
                        // The settings revision is shared by every module. A change to another module
                        // arrives here as a new revision of the same configuration: nothing to apply,
                        // nothing to wait for, and the provider's state is left alone.
                        if (old.activated && old.pending == null && request.config().equals(old.applied)) {
                            old.revision = request.revision(); report = old.status("Active", null); return report;
                        }
                        old.pending = request; report = old.status("Pending", "safe-boundary"); return report;
                    }
                }
                var moduleLoader = archive.loader(definition.namespace, getClass().getClassLoader(), true);
                candidate = (ContinuousProvider)moduleLoader.loadClass(definition.entry).getConstructor().newInstance();
                if (!candidate.id().equals(definition.id)) throw new IllegalArgumentException("Module identity mismatch");
                candidate.validateConfig(request.config());
                // Borrow only the old transformer's pre-hook input, never its module-owned callback implementation.
                var preflight = candidate.preflight(instrumentation, loader,
                    old == null ? type -> null : old.provider::capturePreflightInput);
                if (!preflight.supported()) {
                    candidate.close(); candidate = null;
                    return rejected("update-rejected:preflight:" + preflight.reason());
                }
                // Preflight is a snapshot, not a lock over future transformers; installation must check again.
                if (!retireCurrent("module-update")) { candidate.close(); return report; }
                var support = candidate.initialize(instrumentation, loader);
                if (!support.supported()) {
                    candidate.close(); candidate = null;
                    report = empty("Unsupported", support.reason()); return report;
                }
                var next = new Generation(candidate, definition, archive.digest(), request, loader);
                candidate = null;
                // Initialize the report before tick can activate this generation and acknowledge it.
                report = next.status("Pending", "safe-boundary");
                current.set(next);
                return report;
            } catch (Exception | LinkageError failure) {
                if (candidate != null) try { candidate.deactivate(); candidate.close(); }
                catch (Exception | LinkageError cleanup) { poisoned = true; report = empty("RestartRequired", "candidate-retirement-failed"); }
                return poisoned ? report : rejected("update-rejected:" + failure.getClass().getSimpleName());
            }
        }
    }
    private ContinuousModules.Status rejected(String reason) {
        var previous = report;
        return new ContinuousModules.Status(previous.state().equals("Disabled") ? "Unsupported" : previous.state(), reason,
            previous.processId(), previous.worldId(), previous.generation(), previous.appliedRevision(),
            previous.moduleVersion(), previous.moduleSha256(), "");
    }
    private Definition definition(String id) throws Exception {
        byte[] bytes;
        try (var stream = Files.newInputStream(directory.resolve("catalog.tsv"), LinkOption.NOFOLLOW_LINKS)) {
            bytes = stream.readNBytes(65537);
        }
        if (bytes.length > 65536) throw new IllegalArgumentException("Oversized catalogue");
        Definition selected = null; Set<String> ids = new HashSet<>();
        for (String line : new String(bytes, StandardCharsets.UTF_8).split("\\R")) {
            if (line.isBlank() || line.startsWith("#")) continue;
            String[] p = line.split("\t", -1);
            if ((p.length != 10 && p.length != 11) || !ids.add(p[0]) || ids.size() > 64)
                throw new IllegalArgumentException("Invalid catalogue");
            if (!p[0].equals(id)) continue;
            if (p.length != 11 || !CAPABILITIES.contains(p[10])
                    || !p[2].matches("pztools\\.extensions\\.[A-Za-z0-9_.]+")
                    || !p[3].startsWith(p[2] + ".") || !p[3].matches("[A-Za-z0-9_.]+")
                    || !p[4].matches("[a-z0-9-]+\\.jar")) throw new IllegalArgumentException("Unsupported continuous capability");
            selected = new Definition(p[0], p[1], p[2], p[3], p[4],
                new VersionSupport(p[5], p[6].equals("-") ? null : p[6], p[7].equals("-") ? null : p[7]));
        }
        if (selected == null) throw new IllegalArgumentException("Unknown continuous module");
        return selected;
    }
    void tick(ContinuousProvider.Context context) {
        Generation g = current.get();
        if (g == null || g.revoked) return;
        if (context == null || !context.worldValid().get() || !g.world.equals(context.worldId())
                || g.loader != context.gameClasses()) { revokeGeneration(g, "world-unavailable"); return; }
        String providerFailure = failureReason(g);
        if (providerFailure != null) { revokeFault(g, providerFailure); return; }
        if (!g.acquire()) return;
        try {
            context.requireGameThread();
            var pending = g.pending;
            if (pending == null || !g.provider.readyToActivate(context, pending.config())) {
                // A change that waits for a safe moment must not stall the active configuration's per-frame work.
                if (g.activated && g.provider instanceof FrameListener listener) {
                    listener.gameFrame();
                    // Revoked while the frame ran: whatever it created is withdrawn again.
                    if (g.revoked) g.provider.deactivate();
                }
                return;
            }
            if (g.context == null) g.context = new ContinuousProvider.Context(context.processId(), context.worldId(),
                context.worldIdentity(), context.gameThread(), context.gameClasses(), g.valid);
            if (!g.activated) { g.provider.activate(g.context, pending.config()); g.activated = true; }
            else g.provider.updateConfig(pending.config());
            synchronized (g) {
                if (!g.revoked) {
                    g.revision = pending.revision(); g.applied = pending.config();
                    if (g.pending == pending) { g.pending = null; report = g.status("Active", null); }
                    // A newer request may still be waiting, but this callback's configuration is already applied.
                    else report = g.status("Pending", "safe-boundary");
                }
            }
            if (g.revoked) g.provider.deactivate();
        } catch (Throwable failure) { revokeFault(g, "activation-failed:" + failure.getClass().getSimpleName()); }
        finally { g.release(); }
    }
    private void revokeFault(Generation g, String reason) {
        try { g.revoke(); } catch (Throwable ignored) { g.valid.set(false); }
        if (current.get() == g) report = g.status("FaultedPassThrough", reason);
    }
    private static String failureReason(Generation g) {
        // Only the module that owns the vehicle hook answers for a fault in it.
        if (VehicleHooks.failure(g.provider) != null) return "vehicle-callback-failed";
        try {
            String value = g.provider.failureReason();
            return value == null ? null : "provider-failed:" + value.substring(0, Math.min(256, value.length()));
        } catch (Throwable failure) { return "provider-health-check-failed"; }
    }
    void revoke(String reason) {
        Generation g = current.get();
        if (g == null) return;
        revokeGeneration(g, reason);
    }
    private void revokeGeneration(Generation g, String reason) {
        try { g.revoke(); if (current.get() == g) report = g.status("Disabled", reason); }
        catch (Throwable failure) { if (current.get() == g) report = g.status("RestartRequired", "revoke-failed"); }
    }
    ContinuousModules.Status deactivate(String reason) {
        synchronized (operations) { retireCurrent(reason); return report; }
    }
    private boolean retireCurrent(String reason) {
        Generation g = current.getAndSet(null);
        if (g == null) return !poisoned;
        try {
            g.revoke(); g.await();
            // Activation may have entered just before revoke; repeat after lifecycle drain.
            g.provider.deactivate(); g.provider.close();
            report = empty("Disabled", reason); return true;
        } catch (Throwable failure) {
            poisoned = true; report = g.status("RestartRequired", "retirement-failed"); return false;
        }
    }
    ContinuousModules.Status status() {
        Generation g = current.get();
        if (g != null && !g.revoked) {
            String failure = failureReason(g);
            if (failure != null) revokeFault(g, failure);
        }
        var result = report;
        String diagnostics = "";
        if (g != null) try {
            String value = g.provider.diagnostics();
            if (value != null) diagnostics = value.substring(0, Math.min(4096, value.length()));
        } catch (Throwable ignored) { diagnostics = "diagnostics-unavailable"; }
        return new ContinuousModules.Status(result.state(), result.reason(), result.processId(), result.worldId(),
            result.generation(), result.appliedRevision(), result.moduleVersion(), result.moduleSha256(), diagnostics);
    }
    void close() throws Exception {
        synchronized (operations) {
            closed = true;
            if (!retireCurrent("host-retired")) throw new IllegalStateException("Continuous module requires restart");
        }
    }
}
