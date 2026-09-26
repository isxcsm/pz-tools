package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import pztools.extensions.seamless.SeamlessSaveProvider;
import java.lang.instrument.*;
import java.lang.reflect.*;
import java.lang.invoke.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Version-bound adapter: original capture, bounded file writes and acknowledged native/database completion. */
public final class Build4220Adapter implements SeamlessSaveProvider.GameAdapter {
    private static final Map<String, String> GAME_CLASSES = Map.of(
        "zombie/GameWindow", "21666fb045fe1bd49d2fabdf196618952b5eda72985be49750c796c7e812087a",
        "zombie/savefile/PlayerDB", "e70b081832b1d77b10df9d774a82d3062c306c2b9b3bef8b8f6f8bf87a53aea8",
        "zombie/vehicles/VehiclesDB2", "f908628f3a94a018cc4666ef14bdb01326eeb90ca27f55d7b744d215a7a9f9ba",
        "zombie/core/logger/ExceptionLogger", "80d6a61b482409fdce589b324cc70d31901ad0278acebe94844c27a5084ed3f4",
        "zombie/iso/IsoCell", "6f55ff3bae344124c9ec0a29fa93198190901da04574e9b9cafa44b9aa962b1f",
        "zombie/iso/IsoChunk", "68431ace471b30c842ff7c2a6e706d8ba48d7a84ae07f876484153c0d62a794b",
        "zombie/iso/IsoChunkMap", "8a640e4756d98f6cafd77e6d36a7b9042ea844744af3f0bb2cda257726d3b61c",
        "zombie/vehicles/VirtualVehicleManager", "91849135296db0246ec51fd5eb3e3e890f4436c78b48dcc37e1ff573cdbd271e");
    private static final Map<String, String> NATIVE_CLASSES = Map.of(
        "zombie/MapCollisionData", "5ca2fd344cc34094ef218f657d516defa3f09e4f07e73a61bf45d43ee3cf3cae",
        "zombie/MapCollisionData$MCDThread", "3a1e6698ca64baa7b08c899286954970e56b978b241167ab62acf2403bb29961",
        "zombie/popman/ZombiePopulationManager", "d78514c622b513e5c43b5f6ab2f523f8a6bd64ae4f6efdde16d590351624072e");
    private static final Map<String, String> BACKGROUND_CLASSES = Map.of(
        "zombie/iso/ChunkSaveWorker", "b85359ec4a90030f4da9f048947fe69c7eccde341c2ff852e51be2e017dc90c5",
        "zombie/iso/WorldStreamer", "da146ac8919e31902d805070f029a0276091892a06f36f38027780bb20d8f001");
    private final SaveSignals signals = new SaveSignals();
    private final AtomicReference<Throwable> transformationFailure = new AtomicReference<>();
    private Method allowPlayers, getPlayers, updatePlayers, updateVehicles;
    private Field vehicles;
    private CaptureReadiness readiness;
    private InteractionReadiness interaction;
    private final CaptureTimings timings = new CaptureTimings();
    private OwnedChunkWrites writes;
    private OwnedNativeSave nativeSave;
    private pztools.extensions.seamless.VersionedSaveEntry entry;
    private volatile boolean initialized;
    private ClassFileTransformer transformer;
    @Override public SaveProvider.Support initialize(Instrumentation instrumentation, ClassLoader loader) throws Exception {
        if (initialized) return new SaveProvider.Support(transformationFailure.get() == null, "game-code-changed");
        if (instrumentation == null || Runtime.version().feature() != 25 || !instrumentation.isRetransformClassesSupported())
            return new SaveProvider.Support(false, "unsupported-runtime");
        Map<String, byte[]> resources = new HashMap<>();
        for (var e : java.util.stream.Stream.of(GAME_CLASSES, NATIVE_CLASSES, BACKGROUND_CLASSES).flatMap(m -> m.entrySet().stream()).toList()) {
            try (var input = loader.getResourceAsStream(e.getKey() + ".class")) {
                if (input == null) return new SaveProvider.Support(false, "unsupported-game-build");
                byte[] bytes = input.readNBytes(4 * 1024 * 1024 + 1);
                if (!HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(e.getValue()))
                    return new SaveProvider.Support(false, "unsupported-game-build");
                resources.put(e.getKey(), bytes);
            }
        }
        if (Class.forName(GameHooks.class.getName(), false, loader) != GameHooks.class
                || Class.forName(PrivateMethodLinkage.class.getName(), false, loader) != PrivateMethodLinkage.class)
            return new SaveProvider.Support(false, "unsupported-game-loader");
        Class<?> playerDb = Class.forName("zombie.savefile.PlayerDB", false, loader);
        Class<?> vehicleDb = Class.forName("zombie.vehicles.VehiclesDB2", false, loader);
        Class<?> logger = Class.forName("zombie.core.logger.ExceptionLogger", false, loader);
        allowPlayers = playerDb.getMethod("isAllow"); getPlayers = playerDb.getMethod("getInstance");
        updatePlayers = playerDb.getMethod("updateMain"); updateVehicles = vehicleDb.getMethod("updateMain");
        vehicles = vehicleDb.getField("instance"); readiness = new CaptureReadiness(loader); interaction = new InteractionReadiness(loader);
        writes = new OwnedChunkWrites(new GameChunkAccess(loader));
        nativeSave = new OwnedNativeSave(loader);
        Class<?> nativeWorker = Class.forName("zombie.MapCollisionData$MCDThread", false, loader);
        Set<Class<?>> observers = Set.of(playerDb, vehicleDb, logger);
        var targets = new ArrayList<>(observers);
        targets.add(nativeWorker);
        var guardMethods = new ArrayList<>(PrivateSaveGraph.SOURCES);
        guardMethods.add(PrivateSaveGraph.WRITE);
        guardMethods.add(new PrivateSaveGraph.MethodRef("zombie/iso/IsoChunk", "SafeRead", "(IILjava/nio/ByteBuffer;)Ljava/nio/ByteBuffer;"));
        guardMethods.add(new PrivateSaveGraph.MethodRef("zombie/MapCollisionData", "stop", "()V"));
        guardMethods.add(new PrivateSaveGraph.MethodRef("zombie/MapCollisionData$MCDThread", "runInner", "()V"));
        for (String name : List.of("beginSaveRealZombies", "endSaveRealZombies", "save", "processPendingSaveCells"))
            guardMethods.add(new PrivateSaveGraph.MethodRef("zombie/popman/ZombiePopulationManager", name, "()V"));
        Map<PrivateSaveGraph.MethodRef, byte[]> fingerprints = new HashMap<>();
        for (var method : guardMethods) {
            Class<?> target = Class.forName(method.owner().replace('/', '.'), false, loader);
            if (!targets.contains(target)) targets.add(target);
            fingerprints.put(method, PrivateSaveGraph.methodFingerprint(loader, resources.get(method.owner()), method));
        }
        for (Class<?> type : targets) if (!instrumentation.isModifiableClass(type)) return new SaveProvider.Support(false, "unmodifiable-game-class");
        Map<String, byte[]> captured = new ConcurrentHashMap<>();
        Set<Class<?>> observed = ConcurrentHashMap.newKeySet();
        transformer = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader owner, String name, Class<?> type, ProtectionDomain domain, byte[] bytes) {
                if (owner != loader || !targets.contains(type)) return null;
                try {
                    for (var method : guardMethods) if (method.owner().equals(name))
                        if (!Arrays.equals(fingerprints.get(method), PrivateSaveGraph.methodFingerprint(loader, bytes, method)))
                            throw new IllegalStateException("Another transformation changed the private save contract: " + method.name());
                    if (type == nativeWorker) {
                        byte[] result = NativeSaveObservation.transform(bytes, loader);
                        observed.add(type); return result;
                    }
                    if (observers.contains(type)) {
                        byte[] result = DatabaseObservationBytecode.transform(name, bytes, loader);
                        observed.add(type); return result;
                    }

                    if (!initialized && PrivateSaveGraph.SOURCES.stream().anyMatch(ref -> ref.owner().equals(name))) captured.put(name, bytes.clone());
                    return null; // Inspection only: NONE of the game's save/read/write bodies are replaced.
                } catch (Throwable failure) {
                    transformationFailure.compareAndSet(null, failure); signals.failActive(failure); return null;
                }
            }
        };
        signals.register();
        try { nativeSave.register(); } catch (RuntimeException failure) { signals.unregister(); throw failure; }
        try {
            instrumentation.addTransformer(transformer, true);
            instrumentation.retransformClasses(targets.toArray(Class<?>[]::new));
            if (observed.size() != observers.size() + 1 || transformationFailure.get() != null || captured.size() != PrivateSaveGraph.SOURCES.size())
                throw new IllegalStateException("Private save source or observers unavailable", transformationFailure.get());
            MethodHandle sink = MethodHandles.lookup().findVirtual(OwnedChunkWrites.class, "write",
                MethodType.methodType(void.class, int.class, int.class, java.nio.ByteBuffer.class)).bindTo(writes);
            entry = PrivateSaveGraph.create(loader, captured, sink, timings, nativeSave);
            initialized = true; captured.clear(); return new SaveProvider.Support(true, null);
        } catch (Throwable failure) {
            instrumentation.removeTransformer(transformer); signals.unregister(); nativeSave.unregister(); writes.close();
            // Only observer instrumentation needs restoring; the copied source methods never changed.
            var restored = new ArrayList<>(observers); restored.add(nativeWorker);
            instrumentation.retransformClasses(restored.toArray(Class<?>[]::new));
            return new SaveProvider.Support(false, "unsupported-private-save-layout");
        }
    }
    @Override public SaveProvider.Support inspect(SaveProvider.Context context) {
        context.requireGameThread();
        return new SaveProvider.Support(initialized && transformationFailure.get() == null && signals.observationFailure() == null,
            initialized ? "game-code-changed" : "adapter-not-initialized");
    }
    @Override public boolean readyToCapture(SaveProvider.Context context) throws Exception {
        context.requireGameThread(); return interaction.ready() && readiness.ready();
    }
    @Override public SaveProvider.PreparedSave capture(SaveProvider.Context context, long maximumBytes) throws Exception {
        context.requireGameThread();
        if (!inspect(context).supported()) throw new IllegalStateException("Private save adapter unavailable");
        boolean includePlayers = (boolean)allowPlayers.invoke(null);
        Object playerStore = includePlayers ? getPlayers.invoke(null) : null;
        Object vehicleStore = Objects.requireNonNull(vehicles.get(null), "Vehicle store unavailable");
        var batch = signals.begin(context, includePlayers, readiness.databaseWorker());
        timings.start();
        try {
            batch.nativeWork = nativeSave.begin(context, batch::fail);
            batch.chunks = writes.begin(context, maximumBytes, batch::fail);
            entry.saveForBackup(); // Explicit private entry, NOT GameWindow.save(true).
            if (includePlayers) updatePlayers.invoke(playerStore);
            updateVehicles.invoke(vehicleStore);
        } catch (Throwable failure) {
            batch.fail(failure instanceof InvocationTargetException invocation ? invocation.getCause() : failure);
        } finally {
            try { batch.detail = timings.finish(); }
            catch (Throwable unavailable) { batch.detail = "timing-unavailable"; }
            finally { batch.arm(); }
        }
        return batch;
    }
}
