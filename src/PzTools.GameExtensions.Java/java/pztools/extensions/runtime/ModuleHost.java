package pztools.extensions.runtime;

import pztools.extensions.api.*;
import pztools.extensions.api.internal.ClassArchive;
import java.io.*;
import java.lang.instrument.Instrumentation;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Refreshes closed deployment snapshots BETWEEN saves. WATCH never owns a module generation. */
public final class ModuleHost implements SaveModules {
    private record Definition(String id, String version, String jar, String namespace, String entry, VersionSupport support) { }
    private Path directory;
    private final Map<String, Loaded> loaded = new HashMap<>();
    private record Rejected(Definition definition, String digest, String reason) { }
    private final Map<String, Rejected> rejected = new HashMap<>();
    private final CheckpointRuntime runtime = new CheckpointRuntime(64L * 1024 * 1024);
    private ClassLoader boundGameLoader;
    private boolean closed, poisoned;
    public ModuleHost(Path directory) throws Exception { this.directory = directory.toAbsolutePath().normalize(); catalogue(); }

    private Map<String, Definition> catalogue() throws IOException {
        byte[] bytes;
        try (var input = Files.newInputStream(directory.resolve("catalog.tsv"), LinkOption.NOFOLLOW_LINKS)) {
            bytes = input.readNBytes(65537);
        }
        if (bytes.length > 65536) throw new IOException("Oversized extension catalogue");
        var definitions = new HashMap<String, Definition>();
        for (String line : new String(bytes, StandardCharsets.UTF_8).split("\\R")) {
            if (line.isBlank() || line.startsWith("#")) continue;
            String[] p = line.split("\t", -1);
            if (p.length != 10 || definitions.size() >= 64 || !p[0].matches("[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+")
                    || !p[1].matches("[0-9]+(?:[.][0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?")
                    || !p[2].matches("pztools\\.extensions\\.[A-Za-z0-9_.]+") || !p[3].startsWith(p[2] + ".")
                    || !p[3].matches("[A-Za-z0-9_.]+") || !p[4].matches("[a-z0-9-]+\\.jar"))
                throw new IOException("Invalid extension catalogue row");
            var range = new VersionSupport(p[5], p[6].equals("-") ? null : p[6], p[7].equals("-") ? null : p[7]);
            if (definitions.putIfAbsent(p[0], new Definition(p[0], p[1], p[4], p[2], p[3], range)) != null)
                throw new IOException("Duplicate module identity");
        }
        return definitions;
    }
    @Override public synchronized void relocate(Path next) throws Exception {
        requireIdle();
        directory = next.toAbsolutePath().normalize();
    }
    private void requireIdle() {
        if (closed || poisoned) throw new IllegalStateException("Extension host requires restart");
        if (!runtime.isIdle()) throw new IllegalStateException("A save still owns its module");
    }
    @Override public synchronized Resolution resolve(String id, Instrumentation instrumentation, ClassLoader gameClasses,
                                                      String gameVersion, boolean forceVersion) {
        if (closed || poisoned) return new Resolution(null, "module-restart-required");
        if (!runtime.isIdle()) return new Resolution(null, "module-update-busy");
        if (boundGameLoader != null && boundGameLoader != gameClasses) return new Resolution(null, "game-loader-changed");
        Loaded previous = loaded.get(id);
        SaveProvider candidate = null;
        try {
            Definition definition = catalogue().get(id);
            if (definition == null) { retire(id, previous); return new Resolution(null, "unknown-provider"); }
            if (!forceVersion && !definition.support.matches(gameVersion))
                return new Resolution(null, gameVersion == null ? "version-unknown" : "version-mismatch");
            // Read once: hash, manifest and loaded classes refer to the SAME bounded archive bytes.
            var archive = ClassArchive.read(directory.resolve(definition.jar));
            archive.require("PzTools-Extension-Api", Integer.toString(SaveProvider.API_MAJOR));
            Rejected rejection = rejected.get(id);
            if (rejection != null && rejection.definition.equals(definition) && rejection.digest.equals(archive.digest()))
                return new Resolution(null, rejection.reason);
            if (previous != null && previous.definition.equals(definition) && previous.digest.equals(archive.digest()))
                return new Resolution(previous, null);
            var loader = archive.loader(definition.namespace, ModuleHost.class.getClassLoader(), true);
            candidate = (SaveProvider)loader.loadClass(definition.entry).getConstructor().newInstance();
            if (!candidate.id().equals(id)) throw new IOException("Provider identity mismatch");
            if (previous != null && !previous.delegate.supportsReload())
                return new Resolution(null, "module-restart-required");
            // Constructors must not install hooks. Only initialize after the old generation is drained/retired.
            retire(id, previous);
            boundGameLoader = gameClasses;
            var support = candidate.initialize(instrumentation, gameClasses);
            if (!support.supported()) {
                disposeCandidate(candidate); candidate = null;
                rejected.put(id, new Rejected(definition, archive.digest(), support.reason()));
                return new Resolution(null, support.reason());
            }
            Loaded next = new Loaded(definition, archive.digest(), candidate);
            loaded.put(id, next); rejected.remove(id); candidate = null;
            return new Resolution(next, null);
        } catch (Exception | LinkageError failure) {
            System.err.println("[PzTools extensions] Update rejected for " + id + ": " + failure);
            if (candidate != null) {
                try { disposeCandidate(candidate); } catch (Exception cleanup) { poisoned = true; }
            }
            return new Resolution(null, poisoned ? "module-restart-required" : "module-update-unavailable");
        }
    }
    private void disposeCandidate(SaveProvider candidate) throws Exception {
        if (candidate.supportsReload()) candidate.close();
        else poisoned = true; // An initializer without a retirement contract cannot be assumed reversible.
    }
    private void retire(String id, Loaded previous) throws Exception {
        if (previous == null) return;
        if (!previous.delegate.supportsReload()) throw new IllegalStateException("Module requires restart");
        previous.retired = true;
        try { previous.delegate.close(); }
        catch (Exception | LinkageError failure) { poisoned = true; throw failure; }
        loaded.remove(id, previous);
    }
    @Override public synchronized SaveTask begin(SaveProvider provider, SaveProvider.Context context) throws Exception {
        requireIdle();
        if (!(provider instanceof Loaded current) || current.retired || loaded.get(provider.id()) != current)
            throw new IllegalStateException("Stale module generation");
        return runtime.begin(provider, context);
    }
    @Override public synchronized void close() throws Exception {
        if (closed) return;
        requireIdle();
        for (var entry : List.copyOf(loaded.entrySet())) retire(entry.getKey(), entry.getValue());
        runtime.close();
        if (!runtime.awaitTermination(5000)) { poisoned = true; throw new IOException("Extension executor did not retire"); }
        closed = true; loaded.clear(); rejected.clear(); boundGameLoader = null;
    }
    private static final class Loaded implements SaveProvider {
        final Definition definition;
        final String digest;
        final SaveProvider delegate;
        volatile boolean retired;
        Loaded(Definition definition, String digest, SaveProvider delegate) {
            this.definition = definition; this.digest = digest; this.delegate = delegate;
        }
        public String id() { return definition.id; }
        public Support inspect(Context context) {
            if (retired) return new Support(false, "module-generation-retired");
            if (!context.forceVersion() && !definition.support.matches(context.gameVersion()))
                return new Support(false, context.gameVersion() == null ? "version-unknown" : "version-mismatch");
            return delegate.inspect(context);
        }
        public boolean readyToCapture(Context context) throws Exception { return !retired && delegate.readyToCapture(context); }
        public PreparedSave capture(Context context, long maximumBytes) throws Exception {
            Support checked = inspect(context);
            if (!checked.supported()) throw new IllegalStateException(checked.reason());
            PreparedSave prepared = delegate.capture(context, maximumBytes);
            if (prepared instanceof CooperativeCapture plan) return new CooperativeCapture() {
                public boolean advance(long budget) throws Exception { return plan.advance(budget); }
                public void abort(Throwable failure) { plan.abort(failure); }
                public long retainedBytes() { return plan.retainedBytes(); }
                public void commit() throws Exception { plan.commit(); }
                public Completion completion() { return plan.completion(); }
                public String diagnostics() {
                    return "moduleVersion=" + definition.version + "; moduleSha256=" + digest + "; " + plan.diagnostics();
                }
                public void close() throws Exception { plan.close(); }
            };
            return new PreparedSave() {
                public long retainedBytes() { return prepared.retainedBytes(); }
                public void commit() throws Exception { prepared.commit(); }
                public Completion completion() { return prepared.completion(); }
                public String diagnostics() {
                    return "moduleVersion=" + definition.version + "; moduleSha256=" + digest + "; " + prepared.diagnostics();
                }
                public void close() throws Exception { prepared.close(); }
            };
        }
    }
}
